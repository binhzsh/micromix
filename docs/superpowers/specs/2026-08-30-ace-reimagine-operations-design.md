# ACE Reimagine Operations Design

**Date:** 2026-08-30
**Status:** implemented and deployed on `lts1` on 2026-08-31
**Scope:** Phase 1B server contracts and execution for ACE-Step reference
generation, Remix/Cover, Repaint, variations, and restart recovery. Native Mac
reattachment and controls are a subsequent phase.

## 1. Goal

Add source-aware creative generation to the durable Micromix gateway without
exposing ACE-Step's low-level API or duplicating Logic Pro editing features.
The result should let a later Mac client:

- use an existing audio asset as a global style reference;
- reinterpret a source song while retaining a selectable amount of its musical
  structure;
- replace an explicit section of a source song while preserving its context;
- request one to four reproducible alternatives; and
- recover useful work after a gateway or ACE worker restart.

This phase builds on the deployed input/output asset graph. Uploaded files remain
transient server working assets, while the Mac library remains authoritative.

## 2. Existing system and upstream support

The Micromix gateway currently exposes text/lyrics generation as
`POST /v1/jobs/generation`. Jobs are durable, but the generation adapter submits
only JSON, downloads only the first ACE result, and treats an unknown upstream
task as running indefinitely.

The pinned ACE-Step commit already supports:

- `reference_audio` multipart upload with `task_type=text2music`;
- `src_audio` multipart upload with `task_type=cover` or `repaint`;
- `audio_cover_strength` from `0.0` through `1.0`;
- repaint start/end positions and balanced repaint strength;
- `batch_size` and explicit comma-separated seeds; and
- multiple audio paths in a completed task result.

No ACE-Step revision or new model is required.

## 3. API design

Keep the existing text/lyrics endpoint backward compatible and add three typed
routes. All four routes continue to return the existing `JobRecord` with
`kind="generation"`.

### 3.1 Existing text/lyrics generation

`POST /v1/jobs/generation` keeps its current fields and adds:

```json
{
  "variation_count": 1
}
```

`variation_count` is an integer from 1 through 4 and defaults to 1. This also
corrects the current upstream waste where ACE defaults to two samples but the
gateway keeps only one.

### 3.2 Reference generation

`POST /v1/jobs/reference-generation`

```json
{
  "reference_asset_id": "asset-id",
  "prompt": "warm tape-saturated dream pop",
  "lyrics": "[Verse]\n...",
  "preset": "turbo",
  "duration_seconds": 30,
  "seed": 42,
  "bpm": 108,
  "key": "D Minor",
  "time_signature": "4",
  "variation_count": 2
}
```

This submits ACE `text2music` with the referenced asset in the multipart
`reference_audio` field. The reference controls global acoustic qualities such
as timbre, performance, and mix character; it is not treated as a timeline or
melodic source.

### 3.3 Remix/Cover

`POST /v1/jobs/remix`

```json
{
  "source_asset_id": "asset-id",
  "prompt": "heavy psychedelic rock with live drums",
  "lyrics": null,
  "preset": "quality",
  "seed": 84,
  "source_strength": 0.6,
  "variation_count": 2
}
```

This submits ACE `cover` with the asset in `src_audio`.
`source_strength` maps to `audio_cover_strength`, accepts `0.0...1.0`, and
defaults to `0.6`. Higher values retain more of the source melody, rhythm,
harmony, and arrangement; lower values permit a broader reinterpretation.

Duration is derived from the source and is not exposed as a Remix field. Lyrics
remain optional so the caller can preserve instrumental behavior or request a
new vocal interpretation without adding a separate workflow.

### 3.4 Repaint

`POST /v1/jobs/repaint`

```json
{
  "source_asset_id": "asset-id",
  "prompt": "replace with a restrained piano bridge",
  "lyrics": null,
  "preset": "quality",
  "seed": 126,
  "start_seconds": 32.0,
  "end_seconds": 44.0,
  "repaint_strength": 0.5,
  "variation_count": 2
}
```

The edited interval must be at least 3 seconds, no more than 90 seconds, and
have `end_seconds > start_seconds`. The gateway does not decode the source merely
to validate its total duration; ACE remains responsible for rejecting a range
outside the actual file. `repaint_strength` accepts `0.0...1.0`, defaults to
`0.5`, and uses ACE's balanced repaint mode. Crossfade and latent-mask controls
remain pinned internal defaults.

### 3.5 Shared validation

- Prompts are trimmed, nonblank, and at most 4,000 characters.
- Lyrics are optional and at most 50,000 characters.
- Presets remain `turbo` or `quality`.
- Seed, when supplied, is an integer from 0 through 4,294,967,295.
- `variation_count` accepts 1 through 4.
- Referenced asset IDs must exist and resolve beneath the configured asset root.
- Inputs must use an `audio/*` media type or `application/octet-stream`.
- Unknown assets return HTTP 404; invalid asset types or operation parameters
  return HTTP 422.

## 4. Durable job representation

No database schema migration or new `JobKind` is required. Every request creates
a generation job whose public parameters contain:

- `operation`: `text`, `reference`, `remix`, or `repaint`;
- every submitted creative control except the asset ID;
- `variation_count`; and
- an explicit `seeds` list containing one seed per requested variation.

The hidden parameter `_upstream_recovery_count` starts at zero. It is updated
atomically in `parameters_json` before a missing upstream task is resubmitted,
and is omitted from public responses like every other underscore-prefixed
internal parameter. This makes the one-resubmission limit durable across gateway
restarts without changing the schema.

Asset IDs are represented by durable job links instead of being duplicated in
parameters:

| Operation | Input link |
| --- | --- |
| Text generation | none |
| Reference generation | `input/reference/0` |
| Remix | `input/source/0` |
| Repaint | `input/source/0` |

Outputs use `output/result/<position>` with positions starting at zero. The
legacy singular `asset` property remains an alias for position zero.

If the caller supplies a seed, effective variation seeds are consecutive values
starting at that seed. Values wrap from `4,294,967,295` to zero. If no seed is
supplied, the gateway creates every seed with a cryptographically secure random
generator before persisting the job. Consequently a queued or resubmitted job
always has reproducible effective seeds.

The store adds one transactional create-with-inputs operation. It inserts the
job and all validated input links in one commit; the existing no-input
`create_job` behavior remains available through the same implementation. A
failed link insert rolls back the job, and dispatcher enqueueing happens only
after the transaction succeeds.

## 5. Adapter and worker data flow

The coordinator resolves named input links through `JobStore`; filesystem paths
remain internal and are never included in an API response.

The ACE adapter receives:

```python
async def submit(
    parameters: dict,
    *,
    reference_audio: Path | None = None,
    source_audio: Path | None = None,
) -> str
```

It submits multipart form data when either path is present and JSON otherwise.
Both forms explicitly set `batch_size=variation_count` and pass the complete
comma-separated seed list with `use_random_seed=false`. Operation mapping is:

| Micromix operation | ACE task | Audio field | Thinking |
| --- | --- | --- | --- |
| `text` | `text2music` | none | enabled |
| `reference` | `text2music` | `reference_audio` | enabled |
| `remix` | `cover` | `src_audio` | disabled/ignored |
| `repaint` | `repaint` | `src_audio` | disabled/ignored |

The existing ACE supervisor already proxies multipart bodies and therefore
requires no new route. It continues to own temporary upload cleanup.

Polling returns an ordered collection of completed audio payloads rather than a
single payload. The adapter downloads every path and reports an explicit
`missing` state when `/query_result` returns an empty result for an unknown task.
The coordinator writes collision-proof filenames (`result.wav` for one output,
`result-1.wav` through `result-N.wav` for multiple outputs) and registers them in
order. The store adds a transactional batch-output registration method; the
existing single-output method remains as a compatibility wrapper.

If any output download or registration fails, the job fails rather than exposing
a partially successful set as complete. Files and asset records already created
for that failed attempt are removed before retry or terminal failure.

## 6. Restart and cancellation behavior

Queued jobs continue normally after gateway restart. A running generation job
with an upstream ID is re-polled first:

- If ACE still knows the task, polling continues without duplicate submission.
- If ACE reports the task missing, the coordinator resubmits once using the
  durable input asset and recorded seeds, increments the durable hidden recovery
  counter, stores the replacement upstream ID, and resumes polling.
- A second missing response for the replacement task fails the job with a clear
  upstream-recovery error rather than looping forever.

This approach supports both an API-only restart, where ACE may still be running,
and a worker restart, where its temporary upload and in-memory task record are
gone.

Cancellation remains cooperative: a queued job becomes cancelled immediately;
a running ACE job may finish upstream, but Micromix discards its outputs when it
observes `cancel_requested`. Adding an ACE-specific cancellation route is outside
this phase.

## 7. Error handling

- Gateway validation errors are returned before queueing.
- GPU acquisition and release behavior remains unchanged.
- ACE HTTP or wrapped-response errors become terminal job errors.
- Missing input files after retention or manual deletion fail with an explicit
  `input asset file is unavailable` error.
- An ACE success response containing zero audio files fails the job.
- A completed batch with fewer or more files than `variation_count` fails rather
  than silently changing the requested contract.
- Safe filenames are generated by Micromix; upstream path components are never
  trusted.

## 8. Testing strategy

Implementation follows strict test-driven development on `lts1`.

### Contract tests

- Each endpoint accepts its valid minimal request and returns HTTP 202.
- Input links use the correct names and are visible on subsequent job reads.
- Missing or non-audio assets and invalid strengths, variation counts, or repaint
  intervals are rejected without queueing.
- Existing generation requests remain compatible and default to one variation.
- Effective seeds are persisted and stable across job reads.

### Adapter tests

- Text generation sends JSON with batch size one by default.
- Reference, Remix, and Repaint send the correct multipart file field and mapped
  operation parameters.
- Explicit seeds produce the exact comma-separated ACE seed payload.
- Polling downloads every result in order.
- Empty unknown results produce `missing`, while queued results remain `running`.

### Coordinator tests

- Named inputs resolve to the correct adapter arguments.
- Multiple outputs are stored with stable names and positions.
- Cancellation discards all batch outputs.
- A missing original task is resubmitted once with the same inputs and seeds.
- A missing replacement task terminates instead of looping.
- Partial batch failures clean up artifacts and fail the job.

### Verification

- Run the complete backend test suite in the isolated worktree.
- Rebuild and deploy only `micromix-api` unless supervisor behavior changes.
- Smoke-test asset upload and all three new submission routes against the live
  gateway without starting expensive inference.
- Run one short manual reference or Remix inference after deployment to verify
  multipart transfer and multiple output downloads. Audio quality remains a
  human listening decision.

## 9. Non-goals

- No Mac UI or SwiftData changes in this phase.
- No stem separation, tuning, tempo alignment, mixing, or mastering.
- No ACE Extract, Lego, Complete, LoRA, or low-level sampler controls.
- No server-side audio editor or waveform decoding dependency.
- No model or ACE-Step revision update.
- No public service, multi-user behavior, or permanent server library.

## 10. Delivery boundary

Phase 1B is complete when the three typed operations are durable, recoverable,
multi-output capable, deployed on `lts1`, and represented in the gateway README.
The following phase will consume these contracts from the Mac app, restore
pending jobs after launch, persist provenance in SwiftData, and expose the small
approved control set.

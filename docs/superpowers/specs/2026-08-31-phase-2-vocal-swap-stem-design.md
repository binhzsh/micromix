# Phase 2 Vocal Swap Stem Workflow Design

**Date:** 2026-08-31  
**Status:** approved for implementation  
**Scope:** add one private, durable vocal-conversion workflow: a prepared vocal
stem and selected private voice produce one Logic-ready converted vocal stem.

## Goal

Micromix Vocal Swap converts a vocal stem prepared in Logic Pro into the voice
chosen from the user's small private voice library. It returns an editable WAV
stem and preserves enough provenance to identify the source, target voice,
model revision, and effective conversion settings.

The simple user path is:

1. Import a vocal stem.
2. Select a private target voice.
3. Start Vocal Swap; observe durable progress and cancel if needed.
4. Open the returned WAV from Library in Logic Pro.

## Non-goals

- No full-song input, source separation, accompaniment upload, or automatic
  reference mix. Logic Pro remains responsible for source separation and final
  contextual mixing.
- No voice training or management UI. Voice models are prepared privately on
  `lts1` and exposed through a small read-only manifest.
- No model picker, pitch editor, formant controls, index controls, or other
  RVC/Applio tuning surface.
- No claim that a conversion backend is creatively acceptable before manual
  English/Vietnamese listening evaluation. This implementation provides the
  durable workflow and its operational contract; quality remains a release
  gate.

## Architecture

Add a `vocal-swap` service to the `lts1` Compose stack. It owns an
Applio/RVC-compatible conversion runtime and mounts a private ignored voice
library. The gateway remains the only public API and never exposes worker
paths, model files, or arbitrary backend arguments.

The voice-library manifest lives under ignored server data and contains only a
stable voice ID, display name, model revision, and enabled flag. The worker
reads the manifest and resolves the corresponding private model files. The
gateway obtains the enabled list through the worker and publishes it at
`GET /v1/voices`; the native app uses this only to populate a picker.

The gateway accepts `POST /v1/jobs/vocal-swap` with a previously uploaded
`source_asset_id` and `target_voice_id`. It validates that the asset is audio
and that the selected voice is currently enabled, creates a durable job with
one named `vocal` input, then submits the worker conversion. The worker writes
one WAV output; the gateway registers it as the named `converted_vocal` output
and retains the normal cancellation, restart recovery, checksum, and retention
behavior.

`JobKind` gains `vocal_swap`, but the public job representation remains the
existing generic shape: ordered input/output asset links, public parameters,
and one compatibility asset. This keeps `JobReattacher` operation-agnostic and
imports the converted stem exactly once without a client-side migration.

## API contract

The public request is intentionally narrow:

```json
{
  "source_asset_id": "asset-vocal",
  "target_voice_id": "private-voice-id"
}
```

`target_voice_id` is a stable manifest ID, never a filesystem path. The saved
job parameters include `operation: "vocal_swap"`, the target voice ID, target
voice display name, worker model revision, and fixed internal conversion
profile revision. The public job payload must not expose private model paths or
model hashes beyond the user-meaningful revision label.

`GET /v1/voices` returns only enabled voice records:

```json
{
  "voices": [
    {"id": "private-voice-id", "label": "Studio Voice", "revision": "rvc-v1"}
  ]
}
```

The gateway returns HTTP 422 for a missing/disabled voice or invalid source
asset. It returns the normal accepted `RemoteJob` response after durable job
creation. Gateway cancellation propagates once to the worker and stays
idempotent.

## Native app

Add a `Vocal Swap` mode alongside Generate, Reimagine, Analyze, Transcribe,
and Library. Its screen follows the existing source-first deck pattern:

- an audio-file picker with the current source-size and type validation;
- a compact target-voice picker populated from gateway capabilities;
- one primary `SWAP VOCAL` action and the shared running, elapsed, cancel,
  success, and error presentation; and
- a completion affordance that opens the imported Library result.

The app uploads the chosen stem, submits the durable swap job, immediately
tracks the accepted job, and relies on `JobReattacher` to import output and
provenance. If the app closes, startup recovery treats a vocal-swap job exactly
like any other pending job.

The local `VocalSwapViewModel` owns only source selection, chosen voice, and
job lifecycle. It snapshots the source asset and voice at submission so later
picker changes cannot alter the accepted job. It does not retain model
parameters or expose conversion internals.

## Failure behavior

- The app blocks submission until it has a valid vocal audio source and an
  enabled target voice.
- A voice removed after the picker loads is rejected by the gateway and shown
  as a readable error; no local library item is created.
- Upload, submission, cancellation, worker failure, checksum mismatch, and
  restart recovery reuse the existing durable-job behavior.
- A worker response with no output or an unexpected media type fails the job
  rather than importing an ambiguous asset.

## Verification

- Gateway model and route tests cover voice-list filtering, valid and invalid
  swap submission, durable input/parameter persistence, cancellation, and
  output registration.
- Worker adapter tests cover manifest resolution, fixed-profile request mapping,
  single-WAV output validation, and surfaced failures with a fake converter;
  they do not assert subjective audio quality.
- Swift API tests cover voice decoding, upload-plus-submit request bodies, and
  job provenance decoding.
- Vocal Swap ViewModel tests cover validation, immutable submission capture,
  cancellation, durable tracking, recovery import, and error presentation.
- Device-window tests keep the compact mode usable at the supported minimum
  size. Manual acceptance verifies the picker and result handoff are readable.

Manual listening evaluation remains separate: assess English and Vietnamese
vocal identity transfer, intelligibility, pitch/expression preservation,
artifacts, runtime, and Logic import before treating Vocal Swap as release
ready.

## Deferred

- Optional accompaniment preview mix.
- Automatic song-to-vocal separation.
- Voice creation/training, editing, deletion, or sharing.
- Vocal enhancement stages; these remain Phase 3 work.

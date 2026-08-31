# Phase 2 Private Vocal Foundation Design

## Purpose

Establish the private server-side foundation needed for Vocal Swap without
exposing an unproven voice-conversion workflow in Micromix. The foundation must
support a selected, locally owned voice model; optional automatic vocal
preparation; durable cancellation/recovery; and provenance sufficient to judge
an output later in Logic.

This is infrastructure for a single private user. It is not a public service,
sharing feature, model marketplace, or generic model playground.

## Scope

The first increment adds these server-only components:

1. A pinned RVC-based conversion worker, isolated in Docker and reachable only
   on the existing internal network.
2. A private voice-profile registry backed by a mounted, ignored model root.
   A profile identifies an installed model and index by stable ID, display name,
   and revision; no training or discovery UI is added.
3. A durable `vocal_conversion` job contract in the gateway. It accepts a
   source asset and selected profile ID, validates readiness, acquires the GPU,
   produces a WAV result, and records source/profile/revision/parameters in
   ordinary job provenance.
4. A narrow worker client seam with a fake-covered contract. The worker must
   refuse a missing profile instead of downloading models at request time.

Source separation, voice selection UI, automatic in-context mixes, and voice
training are deliberately out of this increment. Demucs-style preparation is
an independently evaluated follow-up: it must not be silently added as a
quality claim or substitute for Logic Stem Splitter.

## Runtime layout

```
macOS app (unchanged)
       |
micromix-api durable gateway
       |-- shared gateway asset root (source / output)
       |-- private voices model root (read-only profiles)
       `-- rvc-worker (internal HTTP; GPU routed)
```

The gateway remains the source of truth for files, job state, cancellation, and
output registration. The worker receives a source pathname in the mounted
asset root plus a resolved local profile path; it writes a temporary WAV under
the same scoped job directory. The gateway validates and imports that file as
the job output. No model or voice data is uploaded to a third party.

## Contract

`POST /v1/jobs/vocal-conversion` accepts:

- `source_asset_id`: an uploaded audio asset;
- `voice_profile_id`: a registry ID;
- `pitch_shift_semitones`: optional bounded musical adjustment (-24...24);
- `f0_method`: fixed, product-selected method with no expert UI surface.

The response is the existing durable `RemoteJob`. Parameters retain the
profile ID and immutable profile revision. The input link is named `source`.
The output link is named `converted-vocal`, is WAV, and is checksum-validated
before the job reaches `succeeded`.

The private registry is a single JSON manifest beneath the configured voice
model root. Missing or invalid profiles return a clear validation error. The
gateway never returns filesystem paths, model filenames, or model bytes.

## Reliability and resource handling

- Conversion uses the existing GPU router through the gateway; no worker may
  claim the GPU independently.
- The worker is restarted/released after a conversion if needed to avoid
  persistent VRAM pressure, following the existing worker policy.
- Cancellation is checked before submission and before output registration.
- A worker error becomes a durable failed job with the sanitized upstream
  message; partial temporary files are removed.
- A gateway restart can continue polling/recovering a submitted conversion
  through its upstream ID, just as generation does.

## Testing and acceptance boundaries

Automated tests cover request validation, private registry lookup, worker
payload construction, GPU acquisition/release, cancellation, output naming,
checksums, and provenance. A container health check proves the worker starts
without a user voice profile.

This increment does **not** claim conversion quality. Before exposing the
native Vocal Swap UI, manual evaluation must compare RVC conversion quality for
English and Vietnamese material, including intelligibility, pitch/expression,
identity transfer, tone preservation, artifacts, runtime, VRAM, and failure
recovery. A Voice Profile is usable only after the owner supplies an
authorized/private model and it clears that evaluation.

## Non-goals

- LoRA/style adapters or any generic training controls
- Public, multi-user, or remote model libraries
- Voice impersonation safeguards beyond private local storage and the user's
  responsibility for authorized models
- A DAW timeline, vocal editor, stem mixer, or manual pitch correction
- Automatic source separation before it has passed its own quality gate

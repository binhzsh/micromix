# Mac Job Reattachment and Provenance Design

**Date:** 2026-08-31  
**Status:** approved implementation design  
**Scope:** native macOS durable-job recovery and local provenance for the
deployed Phase 1B gateway. No backend or visual-redesign work.

## Goal

Closing Micromix must not orphan an accepted server job. When the app next opens,
it should resume each unfinished job, import every completed output before the
server retention window expires, and retain enough local information to answer:

- which gateway job produced this item;
- which operation and effective parameters were used;
- which source or reference assets fed the operation; and
- which remote asset was imported as this local file.

The local SwiftData library remains the source of truth for the user's work.
Gateway assets remain transient and are never treated as a second library.

## Non-goals

- No new ACE-Step endpoint, backend migration, or worker change.
- No new creative operation or low-level model controls.
- No attempt to restore a view model's transient editor state after relaunch.
- No automatic re-submission: the gateway already handles its own bounded
  upstream recovery, and a client must never duplicate a creative render.
- No full visual redesign. The existing Library screen receives compact
  selection-driven provenance controls only.

## Native data contract

`RemoteJob` expands to decode the deployed gateway response:

- upstream identifier, cancellation flag, and public parameter object;
- ordered `inputs` and `outputs` links; and
- existing singular `asset` compatibility alias.

`RemoteAssetLink` carries the stable link name, position, and asset. A small
lossless `JSONValue` type decodes public parameters without binding the client to
one operation schema.

`MicromixAPI` exposes submission, lookup, cancellation, and output download as
separate operations. Existing `generate` and `transcribe` convenience methods
remain source-compatible and may continue to use the same polling primitive.

## Local persistence

SwiftData gains two durable concepts.

1. `PendingJobRecord` stores a unique gateway job ID and local submission time.
   It is written immediately after HTTP 202 and removed only after all outputs
   are imported or after the remote job reaches a terminal non-success state.
2. `LibraryRecord` gains optional encoded provenance and a unique remote output
   asset ID. Provenance is a Codable value containing the gateway job ID,
   operation, public parameters, ordered input assets, and imported output
   asset. Optional fields preserve all pre-existing library entries.

The unique remote asset ID makes importing idempotent: a crash after writing the
file but before pending-job cleanup cannot create a second local result when the
app reattaches.

## Reattachment behavior

`JobReattacher` is a main-actor observable coordinator owned by the app. At
launch it reads every pending job ID and starts one polling task per ID.

- non-terminal job: poll again; keep the record and publish it as running;
- succeeded job: download each ordered output, verify its SHA-256, create a
  local `LibraryItem` per missing remote output, then remove the pending record;
- failed/cancelled: retain no incomplete import and remove the pending record;
- unavailable network or transient HTTP error: keep the record for the next
  launch/refresh and publish a recoverable status;
- HTTP 404 for the job: keep the record and surface that the server no longer
  knows it, rather than silently claiming success or re-submitting it.

The first native phase uses existing text generation and transcription calls;
Phase 1B source operations can adopt the same submission and reattachment API
when their controls land. The recovered-job model is intentionally operation
agnostic so that adoption requires no schema change.

## User-facing controls

The Library mode adds an unobtrusive provenance readout for the selected item:
operation, remote job suffix, output position, source/reference asset filenames,
and a compact effective-parameters summary. A `COPY PROVENANCE` action copies a
human-readable reproduction record. Items created before this phase display
`LOCAL / NO REMOTE PROVENANCE` without error.

The deck's status line reports reattachment progress or a recoverable pending
job count. Existing Generate and Transcribe controls retain their layout and
their explicit cancel behavior.

## Verification

Headless tests cover API decoding and multi-output download, durable pending-job
storage, exactly-once import across a simulated relaunch, terminal failure,
offline retention, and provenance formatting. The native suite remains the
automated acceptance boundary; the user manually verifies Library readability
and copy behavior.

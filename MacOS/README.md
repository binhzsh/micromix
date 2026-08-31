# micromix — macOS native app

Native macOS (SwiftUI) front-end for the Micromix local inference stack.

## Layout

This directory contains the Xcode/SwiftUI project within the Micromix monorepo.
The app talks to the `micromix-api` gateway on `lts1` over WireGuard.

## Backend it consumes

| Endpoint | Purpose |
| --- | --- |
| `GET /v1/health` | gateway, GPU, and worker health |
| `GET /v1/capabilities` | generation presets and transcription instruments |
| `POST /v1/jobs/generation` | ACE-Step music generation job |
| `POST /v1/jobs/transcription` | MuScriptor audio-to-MIDI job |
| `GET /v1/jobs/{id}` | poll durable job state |
| `GET /v1/assets/{id}` | download a completed result |

See root `README.md` for the full contract and `docker compose` instructions.

The current app implements all four modes: Generate, Analyze, Transcribe, and
Library. Generate and Transcribe submit durable jobs and poll them to a terminal
state before downloading the resulting asset. Analyze uses Apple's Music
Understanding framework on macOS 27 with an AVFoundation metadata fallback on
macOS 26. SwiftData is authoritative for library metadata, while generated WAV
and MIDI assets remain ordinary files under Application Support for playback
and use in other music tools.

The original macOS design specification and implementation plan under
`docs/superpowers/` are retained as historical design context. Their direct,
long-running HTTP contracts and JSON-manifest persistence model are superseded
by the durable gateway and SwiftData architecture described here and in the
root README.

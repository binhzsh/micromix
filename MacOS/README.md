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

Generate, Transcribe, Library, playback, and MIDI preview are implemented. The
durable job API, SwiftData catalog, and Music Understanding analysis are the
next MVP layer.

# micromix — macOS native app

Native macOS (SwiftUI) front-end for the Micromix local inference stack.

## Layout

This directory is a git **worktree** living on branch `native-macos-app`, nested
under the main `micromix` checkout (ignored by the parent repo via `.gitignore`).

Xcode/SwiftUI project lives here and talks to the local `micromix-api` wrapper
(`http://localhost:8902`).

## Backend it consumes

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | service health / upstream status |
| `POST /v1/audio/speech` | MiniMax-Music3 text → music generation |
| `POST /transcribe/midi` | MuScriptor audio → MIDI transcription |
| `GET /files/{filename}` | fetch written MIDI files |
| `GET /instruments` | supported instrument groups for the picker |

See root `README.md` for the full contract and `docker compose` instructions.

## Status

Scaffolding — no Xcode project yet.

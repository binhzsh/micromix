# Micromix — native macOS app

The SwiftUI app and local inference sidecar share this repository. All inference
runs on the Mac; the app connects to `http://127.0.0.1:8902`. No remote server,
WireGuard connection, or Docker stack is required.

## Current implementation

The app has five workspaces: Generate, Reimagine, Analyze, Transcribe, and
Library. Generate, Reimagine, and Transcribe submit jobs and download outputs.
Analyze uses Apple's Music Understanding framework on macOS 27 with an
AVFoundation metadata fallback on macOS 26. SwiftData holds authoritative
library metadata; downloaded WAV and MIDI assets live under Application Support.

The sidecar implements MiniMax Music 3 generation, Whisper-assisted Reimagine,
Basic Pitch transcription, MLX-RVC vocal conversion, and SAM-Audio separation.
Vocal Swap and stem separation do not yet have dedicated native workspaces.
Reference/remix use extracted lyrics and a style prompt; repaint splices a
newly generated segment. These are approximations, not full audio conditioning.

## Migration gaps

The migration is implemented in part and has not passed end-to-end acceptance:

- Local health decoding and saved `lts1` address migration are implemented.
  Models marked `unloaded` do not prevent connecting to a ready sidecar.
- Generate/Reimagine now expose only supported local controls and encode the
  canonical MiniMax preset. Each render returns one result. The backend rejects
  unsupported dedicated controls instead of silently ignoring them.
- Sidecar jobs and asset indexes are in memory. App reattachment cannot recover
  jobs after a sidecar restart; assets already imported into Library persist.
- Local model quality, English/Vietnamese vocals, and Logic import remain manual
  acceptance gates.

## Development

```bash
cd MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

See the [root README](../README.md) for local sidecar setup and the
[roadmap](../docs/MICROMIX_ROADMAP.md) for current progress and priorities.
Older server and durable-gateway plans are historical context only.

The current headless suite passes 79 tests. Manual acceptance is tracked in
[the local migration checklist](../docs/evaluations/local-migration.md).

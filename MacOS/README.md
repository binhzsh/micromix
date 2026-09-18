# Micromix — native macOS app

The SwiftUI app and local inference sidecar share this repository. All inference
runs on the Mac; the app connects to `http://127.0.0.1:8902`. No remote server,
WireGuard connection, or Docker stack is required.

## Current implementation

Seven workspaces: Generate, Reimagine, Analyze, Transcribe, Vocal Swap, Stem Split,
and Library. Source operations upload reusable audio, track durable jobs, support
cancellation and recovery, and import results with lineage into SwiftData.

Generate and Reimagine expose ACE Turbo/Quality, seeded variations, musical metadata,
English/Vietnamese intent and transformation strengths. Vocal Swap selects available
private voices and pitch shift; Stem Split accepts a target description and imports
both stems. Analyze uses Apple Music Understanding on macOS 27 with an AVFoundation
fallback on macOS 26. MIDI transcription uses local MuScriptor.

Real-model quality, native visual acceptance and Logic import remain manual gates.
See [model setup](../services/local-inference/MODELS.md).

## Development

```bash
cd MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

See the [root README](../README.md) for local sidecar setup and the
[roadmap](../docs/MICROMIX_ROADMAP.md) for current progress and priorities.
Older server and durable-gateway plans are historical context only.

Manual acceptance is tracked in
[the local migration checklist](../docs/evaluations/local-migration.md).

# Local migration verification — 2026-09-18

Status: local parity implementation and automated checks complete; installed model,
visual, listening and Logic acceptance pending.

## Automated evidence

- 37 Python tests pass: API contracts, controls, private voice revisions, adapter
  forwarding, durable storage, atomic output publication, cancellation, recovery,
  pre-commit process crashes, retention and streaming uploads.
- 80 native headless tests in 14 suites pass with DeviceWindowTests excluded because they include
  visual rendering. Model calls are mocked in adapter tests; runtime tests use real
  lightweight subprocesses. No weights downloaded or inference run.
- Independent runtime/API re-review found no blocking defects.

## Manual update and acceptance

Preserve wanted outputs from the old in-memory sidecar before upgrading. Do not
interrupt an active render. New SQLite-backed jobs survive subsequent restarts.

Install API and model libraries, then follow [model setup](../../services/local-inference/MODELS.md)
for weights, license access, private voices and exact import preflights:

```bash
cd services/local-inference
uv sync
cd ../..
bash scripts/setup-local-models.sh --engine all
```

Build the app:

```bash
cd MacOS
xcodegen generate
xcodebuild build -project Micromix.xcodeproj -scheme Micromix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/micromix-local-review
cd ..
```

When ready, restart the configured LaunchAgent (or stop/restart a manually run sidecar):

```bash
launchctl kickstart -k gui/$(id -u)/com.micromix.local-inference
bash scripts/smoke-test.sh
open /tmp/micromix-local-review/Build/Products/Debug/Micromix.app
```

1. Inspect all seven workspaces, controls, keyboard access and connection status.
2. Generate Turbo and Quality examples in English/Vietnamese, with fixed seeds and
   four variations. Check metadata intent, intelligibility and Vietnamese tones.
3. Compare reference influence and cover strength. Repaint a valid interval and
   inspect preserved surrounding audio and boundaries.
4. Transcribe WAV, MP3 and M4A with instrument filters and tempo on/off; import MIDI
   into Logic and inspect tracks/grid. Strict tempo detection can reject unstable beats.
5. Convert a prepared vocal with two private voices, pitch offsets and an optional
   index; inspect provenance. Split target/residual stems and listen to both.
6. Cancel queued/running work and restart during a job; confirm durable reattachment,
   retained inputs and terminal-state consistency. Save selected results to Library.
7. Record model revisions, runtime, memory, defects and usefulness before declaring
   quality parity accepted. Automatic full-song vocal preparation/mixing, Vocal
   Improve, Mashup and Complete remain future product work, not retired-server parity.

Agents stop before these manual gates under AGENTS.md. Library dependency resolution
was checked, but isolated runtime installation/import checks have not been executed.

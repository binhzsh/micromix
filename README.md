# Micromix

Micromix is a private native macOS music workstation companion. The Mac app
handles interaction, playback, local analysis, and its authoritative SwiftData
library; inference runs on-device through a local Apple Silicon (MLX) sidecar.
There is no remote inference server. All app and backend development, testing,
and inference run on the Mac; `lts1`, WireGuard, and Docker are retired from the
project architecture. Dependency and model downloads may require internet access.

## Progress (2026-09-18)

Server feature parity is implemented locally; real-model and listening acceptance
are still pending. Seven native workspaces cover Generate, Reimagine, Analyze,
Transcribe, Vocal Swap, Stem Split, and Library.

- ACE-Step XL Turbo/SFT restores audio-conditioned reference, cover and repaint,
  BPM/key/meter, English/Vietnamese language intent, strength, and 1–4 seeded variations.
- MuScriptor replaces Basic Pitch with instrument filtering and tempo-grid MIDI.
- MLX-RVC loads the selected private voice and optional index; SAM returns target
  and residual stems. MiniMax remains an optional basic text generator.
- SQLite preserves jobs, asset checksums, links, seeds and provenance. Interrupted
  jobs recover; cancellation terminates worker processes. One disposable worker
  runs at a time, releasing model memory on exit. Uploads are capped at 200 MiB;
  seven-day retention preserves active-job inputs.

See [model setup and exact runtime pins](services/local-inference/MODELS.md) and
[manual acceptance](docs/evaluations/local-migration.md). Dependency presence does
not prove weights, inference compatibility, or audio quality. The native SwiftData
library remains authoritative for saved results.

## Local inference stack

The loopback FastAPI sidecar serves `127.0.0.1:8902`. Install its dependencies
with `uv sync` in `services/local-inference`, then install isolated model libraries:

```bash
bash scripts/setup-local-models.sh --engine all
```

This installs libraries only. Follow the model setup document for weights and
MuScriptor license access. No server, Docker or remote inference is used.

## Running the sidecar

Install dependencies with `cd services/local-inference && uv sync` first.
An optional LaunchAgent (`com.micromix.local-inference`) starts the sidecar at
login and keeps it alive. Run the following from the repository root. The
checked-in plist contains absolute paths; adjust them if this checkout moves:

```bash
plist=services/local-inference/com.micromix.local-inference.plist
cp "$plist" ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$(basename "$plist")
```

Run manually instead with:

```bash
cd services/local-inference
uv sync && .venv/bin/python -m local_inference.main
```

Missing weights may download on first use; prepare models using the setup guide before manual acceptance.

## API

- `GET /v1/health`
- `GET /v1/capabilities`
- `POST /v1/jobs/generation`
- `POST /v1/jobs/reference-generation`
- `POST /v1/jobs/remix`
- `POST /v1/jobs/repaint`
- `POST /v1/jobs/transcription`
- `POST /v1/jobs/vocal-swap`
- `POST /v1/jobs/stem-split`
- `POST /v1/assets`
- `GET /v1/jobs`
- `GET /v1/jobs/{id}`
- `POST /v1/jobs/{id}/cancel`
- `GET /v1/assets/{id}`

Text generation:

```bash
curl -X POST http://localhost:8902/v1/jobs/generation \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"warm analog jazz trio","preset":"minimax-cover","duration_seconds":20}'
```

Source operations upload reusable audio first:

```bash
curl -X POST http://localhost:8902/v1/assets \
  -F 'audio_file=@source.wav;type=audio/wav'
```

Then submit, poll the returned job `id` until `state` is terminal, and
download `outputs[].asset.download_url` (the macOS client does this
automatically):

```bash
curl -X POST http://localhost:8902/v1/jobs/remix \
  -H 'Content-Type: application/json' \
  -d '{"source_asset_id":"<asset-id>","prompt":"heavy psychedelic rock","lyrics":"[instrumental]"}'
```

Smoke checks:

```bash
scripts/smoke-test.sh                     # health + capabilities
RUN_GENERATION=1 scripts/smoke-test.sh    # + a real 10-second generation job
scripts/smoke-transcribe.sh audio.wav     # audio-to-MIDI round trip
```

## Native development

```bash
cd MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

The default server URL is `127.0.0.1:8902`, stored by `SettingsStore`.

Logic Pro remains the finishing environment for separation, tuning, mixing,
mastering, and arrangement; Micromix does not duplicate those DAW workflows.

## Verification

Lightweight backend contract tests (no model downloads or inference):

```bash
cd services/local-inference
.venv/bin/python -m unittest discover -s tests -v
```

See [local migration acceptance](docs/evaluations/local-migration.md) for the
coordinated app/sidecar update and manual listening checklist. A running sidecar must restart to load these changes. Preserve wanted outputs
from the old in-memory service before the first upgrade; subsequent SQLite-backed
restarts retain jobs and asset indexes.

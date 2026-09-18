# Micromix

Micromix is a private native macOS music workstation companion. The Mac app
handles interaction, playback, local analysis, and its authoritative SwiftData
library; inference runs on-device through a local Apple Silicon (MLX) sidecar.
There is no remote inference server. All app and backend development, testing,
and inference run on the Mac; `lts1`, WireGuard, and Docker are retired from the
project architecture. Dependency and model downloads may require internet access.

## Progress (2026-09-18)

The local migration is underway, not yet an accepted end-to-end release.

- Built: five native workspaces (Generate, Reimagine, Analyze, Transcribe,
  Library), local sidecar routes, and local model integrations.
- Observed: the sidecar health endpoint responds as ready, with MiniMax loaded.
  This is a service check, not proof of successful generation or app integration.
- Fixed: native health decoding now reads local model status; saved `lts1`
  addresses migrate to loopback. Native requests and backend presets agree.
- Verified: 79 native tests and 3 lightweight local API contract tests pass.
- Remaining: decide restart recovery behavior, finish native vocal workflows,
  and validate models
  with English/Vietnamese audio and Logic import.

See [the roadmap](docs/MICROMIX_ROADMAP.md) for the implementation audit and next
steps. Older server plans and evaluation results are historical evidence only.

## Local inference stack

`services/local-inference` is a FastAPI sidecar serving `127.0.0.1:8902`
directly to the app. It runs MLX models on Apple Silicon:

- **MiniMax Music 3** (`mlx-community/MiniMax-Music3-mxfp8`) — text+lyrics
  song generation via `mlx-audio` (flow matching, 44.1 kHz stereo).
- **MLX-RVC** — vocal swap against `.safetensors`/`.pth` voice models in
  `services/local-inference/data/voice-models/`.
- **SAM-Audio** (`mlx-community/sam-audio-large`) — stem separation.
- **Basic Pitch** — audio-to-MIDI transcription (ONNX).
- **Whisper large-v3-turbo** — lyric extraction for reimagine operations.

Only the reimagine operations are approximations: the MLX MiniMax port has no
audio conditioning, so reference-generation/remix extract lyrics from the
source via STT and generate from the style prompt, and repaint splices a
generated segment into the source waveform with short crossfades.

Model caches live in `~/.cache/huggingface`; jobs and generated assets are
held in memory/disk under `services/local-inference/data/` (gitignored) and
are not durable across sidecar restarts. The Mac library remains
authoritative: it downloads completed assets and records lineage.

The native generation screens expose prompt/lyrics, seed, duration where
supported, and repaint range. Each render produces one result. Dedicated
BPM/key/meter/language, variation-count and transformation-strength controls
are unavailable; non-default unsupported API inputs return HTTP 422.
`minimax-cover` is the canonical preset; `turbo` and `quality` remain input
aliases and are recorded as `minimax-cover` in job provenance.

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

First inference downloads models lazily (the MiniMax weights are ~13 GB).

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
coordinated app/sidecar update and manual listening checklist. A running sidecar
must restart to load the new API contract; restarting currently loses job and
asset indexes, so preserve wanted outputs first.

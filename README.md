# Micromix

Micromix is a private native macOS music workstation companion. The Mac app
handles interaction, playback, local analysis, and its authoritative SwiftData
library; inference runs on-device through a local Apple Silicon (MLX) sidecar.
There is no remote inference server.

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

## Running the sidecar

A LaunchAgent (`com.micromix.local-inference`) starts the sidecar at login
and keeps it alive:

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
  -d '{"prompt":"warm analog jazz trio","preset":"turbo","duration_seconds":20}'
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

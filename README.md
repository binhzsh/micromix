# Micromix

Micromix is a private native macOS music workstation companion. The Mac app
handles interaction, playback, local analysis, and its authoritative SwiftData
library; `lts1` supplies heavyweight RTX 3090 inference through one durable API.

## MVP stack

- ACE-Step 1.5 XL Turbo (8 steps) and XL SFT/Quality (50 steps), plus its 4B
  language planner. Source and Hugging Face revisions are pinned in Compose.
- MuScriptor 0.3.0 for audio-to-MIDI.
- FastAPI + SQLite job gateway with cancellation, restart recovery, downloadable
  assets, SHA-256 metadata, and seven-day server retention.
- GPU-router integration. Both workers are cold at rest, load only after an
  acquire succeeds, and expose `/api/gpu/release` to return VRAM.
- SwiftUI macOS app with Generate, Analyze, Transcribe, and Library modes.
  Analyze uses Apple's Music Understanding framework on macOS 27 and an
  AVFoundation metadata fallback on macOS 26.

Only the gateway is published (`:8902`). ACE-Step and MuScriptor remain internal
to Docker networks.

## Server deployment

Run on `lts1` from `~/apps/micromix`:

```bash
docker compose up -d --build
curl http://localhost:8902/v1/health
curl http://localhost:8902/v1/capabilities
```

`HF_TOKEN` may be supplied in the ignored `.env`. Persistent locations default
to `/mnt/fast_pool/fast_models/micromix` for model caches and `./data` for jobs,
uploads, and results. Override them with `ACE_CACHE_ROOT`,
`MUSCRIPTOR_CACHE_ROOT`, and `MICROMIX_DATA_ROOT`.

The first inference downloads the three pinned ACE-Step repositories. This is
intentionally lazy so starting Compose does not claim the shared GPU.

## Durable API

- `GET /v1/health`
- `GET /v1/capabilities`
- `POST /v1/jobs/generation`
- `POST /v1/jobs/transcription`
- `GET /v1/jobs`
- `GET /v1/jobs/{id}`
- `POST /v1/jobs/{id}/cancel`
- `GET /v1/assets/{id}`

Generation example:

```bash
curl -X POST http://localhost:8902/v1/jobs/generation \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"warm analog jazz trio","preset":"turbo","duration_seconds":20}'
```

The submit response is HTTP 202. Poll its `id` until `state` is terminal, then
download `asset.download_url`. The macOS client performs this automatically.

## Native development

```bash
cd MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

The default server URL is stored by `SettingsStore`; use the WireGuard-reachable
`lts1` address when running on the MacBook Pro.

## GPU-router registry

The shared router must register `micromix-ace-step` (23,000 MiB) and
`micromix-muscriptor` (4,000 MiB) as `http-post` workers targeting their
`/api/gpu/release` endpoints on `shared_net`. Deployment verification checks
that both names appear in the router's `/status` response.

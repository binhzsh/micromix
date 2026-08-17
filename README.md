# micromix

Lightweight local inference layer for a native iOS/macOS workflow:

- **MiniMax-Music3** (text-to-music / full-track generation)
- **MuScriptor** (audio → MIDI transcription)

This repo is intentionally stripped down to inference + API surfaces so your
native app can call it directly.

## Quick run

1. Copy env:

```bash
cp .env.example .env
```

2. Fill `HF_TOKEN` (required for model downloads).

3. Start services:

```bash
docker compose up -d --build
```

4. Verify health:

```bash
curl http://localhost:8902/health
```

Expected keys:

- `minimax`: `ok` / `error` / `unreachable`
- `muscriptor`: `ok` / `error` / `unreachable`

## Services and ports

| Service | URL | Port | Notes |
| --- | --- | --- | --- |
| MiniMax-Music3 | `minimax-music3` (container) | `8900` | served by `sglang-omni`; endpoint is `/v1/audio/speech` |
| MuScriptor | `muscriptor` (container) | `8901` | native endpoint is `/transcribe/midi` |
| Wrapper API | `localhost:8902` | `8902` | this repo’s helper service for native app calls |

## Native API contract (`micromix-api`)

Base URL for local app: `http://localhost:8902`

- `GET /health`
- `POST /v1/audio/speech`
- `POST /transcribe/midi`
- `GET /files/{filename}`
- `GET /instruments`

### `POST /v1/audio/speech` (MiniMax-Music3 proxy)

Send JSON. This is a thin pass-through to MiniMax server with a default model.

Required:

- `input` (string): lyrics or text prompt

Recommended:

- `instructions` (string): style or prompt constraints
- `seed` (number): deterministic seed when supported
- `max_new_tokens` (number): generation budget
- `response_format` (string): default `wav`

Example:

```bash
curl -X POST http://localhost:8902/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Vintage jazz chorus in warm, smoky bar ambience with soft double kick",
    "instructions": "instrumental first, vocals at the end, high energy"
  }' \
  --output minimax.wav
```

### `POST /transcribe/midi` (MuScriptor proxy)

Uses multipart form fields:

- `audio_file` (file upload) — any readable audio format
- `instruments` (repeatable string field) optional
- `detect_tempo` optional: `best-effort` (default), `true`, `false`
- `return_file` optional bool; if `true`, the API writes `/data/midi/*.mid` and
  returns JSON with `path`.

Without `return_file`, response is `audio/midi` bytes directly.

Example:

```bash
curl -X POST http://localhost:8902/transcribe/midi \
  -F "audio_file=@/path/to/guitar_loop.wav" \
  -F "instruments=acoustic_guitar" \
  -F "instruments=drums" \
  --output result.mid
```

If you set `return_file=true`, response shape:

```json
{
  "status": "ok",
  "path": "/files/<filename>",
  "filename": "<filename>",
  "size_bytes": 12345
}
```

Then fetch:

```bash
curl http://localhost:8902/files/<filename> --output file.mid
```

### `GET /files/{filename}`

Serve files from `/data/midi` inside the wrapper container.

### `GET /instruments`

List MuScriptor supported instrument groups (`/transcribe/midi` field validator
compatibility check). Useful to present a picker in app UI.

## Reconcile with `maestro`

You don’t need to re-run the whole Maestro stack. Think of this as “phase 1”:
fast open model inference plus lightweight API.

| Capability | Maestro already had | New stack now | Gap / next |
|---|---|---|---|
| Generate full tracks from text | `musicgen` (ACE-Step) in web stack | **MiniMax-Music3** | MiniMax supports lyric/style-to-audio generation, but no `musicgen` project/job history system yet |
| Audio → MIDI | `basic-pitch`, manual workflows | **MuScriptor `/transcribe/midi`** | MuScriptor is strong transcription, but no project graph orchestration |
| Stem separation | `separator`, `audiosep` | not yet | can be ported from Maestro when ready |
| Vocal conversion (swap vocals) | `rvc`, `applio`, `gpt-sovits` | not yet | important for your “swap vocals” goal |
| Style transfer / mastering | `separator` + `musicgen` chains + `matchering` + `mixer` | not yet | reintroduce selective modules as needed |
| Job queue + cancellation + recovery | Maestro gateway + SQLite + polling contract | not yet | add if you want robust async workflows for long jobs |
| Native asset model | Maestro gateway + `/files`, `/jobs`, `/projects` | not yet | good candidate to re-use directly in app layer |

### Practical recommendation

- Start the new native app with:
  1. `/v1/audio/speech` for generation
  2. `/transcribe/midi` for audio transcription
- Keep Maestro’s job/project conventions documented in `maestro/docs/web-to-ios-handoff.md` in view.
- Add isolated Maestro services one-by-one (likely order: separator/audiosep → rvc/applio/gpt-sovits → mixer/matchering) when you’re ready to ship mix/mashup-style workflows.

## Notes

- MiniMax-Music3 and MuScriptor each run with their own GPU demands.
- MuScriptor requires accepting model terms on HF for `MuScriptor/*` repos and using `HF_TOKEN`.
- This service intentionally keeps endpoints simple; authentication and persisted job/state are not included yet.

# Micromix — Native macOS App Design

**Date:** 2026-08-19
**Status:** approved-in-chat, pending spec review

## 1. Purpose

Micromix is a native macOS (SwiftUI) front-end for the Micromix inference stack
running on the LTS1 server. The server is **pure inference** — no server-side
storage, no session state. The Mac app owns all local storage, the library of
results, and the entire user experience.

## 2. Product scope (v1)

Three user flows, all in one app:

1. **GENERATE** — text prompt (+ optional lyrics) → music via MiniMax-Music3
   (`POST /v1/audio/speech`), result saved locally as WAV/AIFF.
2. **TRANSCRIBE** — audio file (drop/select) → MIDI via MuScriptor
   (`POST /transcribe/midi`), result saved locally as `.mid`.
3. **LIBRARY** — persistent local library of all results with in-app playback:
   audio playback for generated songs, MIDI preview through a built-in synth.

Out of scope for v1: stems, mastering, multi-GPU job queueing UI, server-side
accounts, sharing/export bundles.

## 3. Backend contract (confirmed from `services/muscriptor-api/main.py`)

Base URL: `http://10.10.10.10:8902` (LTS1 over WireGuard), user-configurable.

| Endpoint | Semantics |
| --- | --- |
| `GET /health` | `{service, status, minimax, muscriptor}` — each `ok`/`error`/`unreachable`. Used for connection status LED. |
| `POST /v1/audio/speech` | JSON `{input, model?, response_format?, voice?, ...}`. **No streaming** (shim rejects `stream:true`). Returns audio bytes directly (`Content-Type` audio/*, `result.wav`). Timeout 1200 s. |
| `POST /transcribe/midi` | multipart: `audio_file`, `instruments[]` (form), `detect_tempo` (`best-effort` default), `return_file` (bool). With `return_file=false` → MIDI bytes; `return_file=true` → `{status, path, filename, size_bytes}` then `GET /files/{filename}`. |
| `GET /instruments` | `{...}` JSON — instrument list for the transcribe picker (cached; refreshed on app launch / manual refresh). |
| `GET /files/{filename}` | Fetch a written MIDI file. |

Key derived decisions:

- **Job model:** every operation is one long HTTP await (up to 20 min). No
  polling, no job IDs, no progress callbacks. The UI is a client-side
  elapsed-time display with cancel (task cancellation → `URLSession` cancel).
- **Transcribe always uses `return_file=false`** and takes MIDI bytes directly —
  one less round trip, no server storage dependency.
- **Generation result** arrives as raw bytes; the app writes them to local
  storage and derives metadata (duration, format) locally via AVFoundation.

## 4. Architecture

```
Micromix.xcodeproj (generated via xcodegen; no checked-in pbxproj)
└── Sources/
    ├── App/            MicromixApp, DeviceWindow (single-window chassis)
    ├── Theme/          TE design system: colors, typography, PanelButton,
    │                   Knob, DotMatrixScreen, LED, Switch components
    ├── Core/           MicromixAPI (URLSession async client), SettingsStore
    │                   (base URL), JobRunner (async job state machine)
    ├── Generate/       prompt/lyrics editor, generation flow
    ├── Transcribe/     drop zone + file picker, instrument picker, flow
    ├── Library/        LocalLibrary (JSON manifest + files), LibraryScreen
    └── Audio/          AudioPlayer (AVAudioPlayer), MidiPreview
                        (AVAudioEngine + AVAudioUnitSampler, GM soundfont)
```

**Concurrency:** Swift 6 strict concurrency; `@MainActor` view models;
`URLSession` async/await with a delegate for cancellation.

**Project tooling:** `xcodegen` (project.yml) + `swift` CLI; builds/tests via
`xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
App target only (no extensions). macOS 26+ (matches Xcode 27 toolchain).

### 4.1 Persistence (local storage only)

Library root: `~/Library/Application Support/Micromix/`

```
library.json          # manifest: array of LibraryItem
audio/<uuid>.wav      # generated audio
midi/<uuid>.mid       # transcribed MIDI
```

`LibraryItem` manifest record: `id (UUID)`, `kind (audio|midi)`, `title`,
`createdAt`, `prompt` (generation input) or `sourceFile` (transcription
source name), `durationSeconds?`, `instrumentTags?`, `relativePath`.

`library.json` is rewritten atomically (write temp + rename) on every change.
Files are written before the manifest entry is appended — crash-safe ordering.
Deletion removes the file then the manifest entry.

## 5. Design language — Teenage Engineering

Grounded in the user's reference (Eagle `MT03DPK954P4L`): a compact hardware
recorder — dark recessed screen panel (~60%) on a light off-white control deck
(~40%) inside a rounded chassis.

### 5.1 Layout

Single main window, "device panel" feel:

- Window min size ~900×640, resizable, single window.
- **Top: dark screen panel** (`#1A1A1A`, faint horizontal scan lines) — a
  dot-matrix-flavored display that always shows: current mode, job/now-playing
  state, waveform or status text, elapsed time.
- **Bottom: light control deck** (`#F0EFEA`) — mode switcher (GENERATE /
  TRANSCRIBE / LIBRARY as TE-style square mode buttons), the active mode's
  controls, transport, connection LEDs.

### 5.2 Colors

| Role | Value |
| --- | --- |
| Chassis / deck | `#F0EFEA` (warm off-white) |
| Screen | `#1A1A1A` near-black, scanline overlay |
| Ink (primary text) | `#1C1C1C` |
| Screen text | `#FFFFFF` (dot-matrix green `#9BE870` optional for readouts) |
| Function accents | TE orange `#FF5C00`, blue `#0090FF`, green `#00C853`, red `#E5352B` — used only for function (play=green, record/run=orange, error=red, active-mode=blue), never decoration |

### 5.3 Typography

- Technical labels: uppercase monospaced (SF Mono), small, letter-spaced,
  numbered (`1. GENERATE`, `2. TRANSCRIBE`, `3. LIBRARY`, `INPUT`, `OUTPUT`).
- Screen readouts: mono, large for elapsed time.
- Body/inputs: system sans (SF Pro) for editable text fields.

### 5.4 Controls

- **Mode buttons:** square-ish, hard 1–2 px border, flat fill, pressed state
  darkens; active mode shows blue accent dot/underline.
- **Primary action buttons (GENERATE / TRANSCRIBE):** large, orange fill,
  uppercase mono label — the "record" button of the deck.
- **Knobs:** circular with indicator line, used for numeric parameters where
  applicable (v1: none strictly needed — keep component in Theme for reuse).
- **LEDs:** small circles — connection (green/red per `/health`), job running
  (orange, blinking), error (red).
- **Dot-matrix screen:** SwiftUI Canvas/Text-based; waveform rendering via
  `AVAudioFile` -> downsampled amplitude buckets drawn on Canvas.
- Thin ruled separator lines between deck sections; screen-printed label
  aesthetic (no drop shadows inside the panel, shadows only on "physical"
  elements like the recessed screen).

## 6. Flow designs

### 6.1 GENERATE

Controls: prompt text field (multi-line), lyrics toggle + lyrics editor,
model preset (fixed `MiniMaxAI/MiniMax-Music3` in v1), format (WAV).
Primary button: orange `GENERATE`.

Flow: tap → screen switches to running state (elapsed timer, "GENERATING"),
button locks, cancel available. On response: bytes written to
`audio/<uuid>.wav`, manifest appended, screen shows result with inline play;
library updates.

### 6.2 TRANSCRIBE

Controls: drop zone / "SELECT AUDIO" button (wav/mp3/m4a/aif, ≤200 MiB),
instrument multi-picker populated from `/instruments` (cached), tempo detect
toggle (default on).

Flow: select file → screen shows source name + duration → orange `TRANSCRIBE`
→ multipart upload → MIDI bytes → save `midi/<uuid>.mid`, manifest append.
Result row links into Library; screen shows "TRANSCRIBED — n bars / tempo".

### 6.3 LIBRARY

Screen shows the list (dot-matrix table: index, title, kind, duration, date).
Deck shows transport: play/pause (audio: AVAudioPlayer; MIDI: sampler
preview), delete, reveal in Finder. Selecting a row loads it. Empty state:
"NO ITEMS".

## 7. Error handling

- **Connection:** `/health` polled every 15 s (and on demand). Unreachable →
  red connection LED + screen banner "SERVER UNREACHABLE — CHECK WIREGUARD".
  Generate/Transcribe disabled while down.
- **HTTP errors:** shim errors (400/408/413/503) surfaced on screen in red
  with the detail text (truncated), job state returns to idle.
- **Timeouts:** client timeout 1260 s (> server 1200 s) so server error wins.
- **Local failures:** file write failure → error state, nothing appended to
  manifest.

## 8. Testing

- **Unit:** `LocalLibrary` manifest CRUD + atomic write; `MicromixAPI` request
  building (JSON + multipart) with a stubbed URLProtocol; JobRunner state
  transitions.
- **Integration smoke:** `scripts/smoke-muscriptor.sh` style manual checks
  against the live server (not automated CI).
- **UI:** manual verification checklist (build + run via xcodebuild, visual
  review of the three modes against the TE reference).
- Build/test commands:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Micromix.xcodeproj -scheme Micromix build|test`

## 9. Milestones (implementation plan seeds)

1. Project scaffold (xcodegen, target, empty chassis window) + Theme system.
2. Core: MicromixAPI + SettingsStore + health LED.
3. Library: LocalLibrary + Library screen + audio playback.
4. Generate flow end-to-end.
5. Transcribe flow end-to-end + instrument picker.
6. MIDI preview synth.
7. Polish: screen states, errors, cancel, edge cases.

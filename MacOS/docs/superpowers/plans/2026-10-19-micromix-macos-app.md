# Micromix macOS App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS (SwiftUI) desktop app that fronts the Micromix inference stack over the `micromix-api` shim on port 8902, delivering three user flows (GENERATE / TRANSCRIBE / LIBRARY) in a Teenage-Engineering-styled single-window device panel.

**Architecture:** Swift 6 strict-concurrency SwiftUI app. One main window (`DeviceWindow`) with a dark dot-matrix screen panel on top and a light control deck below. A `MicromixAPI` async URLSession client wraps the shim contract. `JobRunner` drives each long HTTP op as a client-side async job with elapsed-time display and cancel. `LocalLibrary` persists results to `~/Library/Application Support/Micromix/` via a crash-safe atomic JSON manifest + data files.

**Tech Stack:** Swift 6 (Swift Testing for unit tests), SwiftUI, AVFoundation (audio playback + waveform), `xcodegen` (project.yml -> Xcode project), `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

**Spec:** [Design spec](../specs/2026-08-19-micromix-macos-app-design.md)

## Global Constraints

Copy these verbatim; every task's requirements implicitly include this section.

- Project is a git **worktree** on branch `native-macos-app`, nested under the main `micromix` checkout (ignored by parent repo). Do not write to the parent checkout.
- `Micromix.xcodeproj` is **generated via xcodegen** from `project.yml`. Do not hand-write or check in `.pbxproj` files.
- Build/test command:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project Micromix.xcodeproj -scheme Micromix build|test`
- macOS 26+ / Swift 6 strict concurrency; `@MainActor` view models; async/await `URLSession` with cancel.
- App target only; no extensions.
- Backend base URL default `http://localhost:8902`, user-configurable via SettingsStore.
- Backend contract (verified from `services/muscriptor-api/main.py`, port 8902):
  - `GET /health` -> `{"service":"micromix-api","status":"ok","minimax":"ok|error|unreachable","muscriptor":"..."}`
  - `POST /v1/audio/speech` -> JSON body with `input` required (or `lyrics` alias), `model`, `response_format`, **no streaming**. Returns raw audio bytes (`Content-Type` audio/*). Timeout 1200 s.
  - `POST /transcribe/midi` -> **multipart**: file field named **`audio_file`** (NOT `file`), form fields `instruments[]` (repeatable), `detect_tempo` (default `best-effort`), `return_file` (bool). With `return_file=false` -> raw MIDI bytes.
  - `GET /instruments` -> **`dict[str, list[str]]`** (grouped instrument families -> lists), NOT a flat list. Cache it; refresh on app launch / manual refresh.
  - `GET /files/{filename}` -> written MIDI file bytes.
- Transcribe always uses `return_file=false` and takes MIDI bytes directly.
- Generation result arrives as raw bytes; app writes locally and derives metadata (duration, format) locally via AVFoundation.
- Library root: `~/Library/Application Support/Micromix/` with `library.json` (manifest), `audio/<uuid>.wav`, `midi/<uuid>.mid`.
- `library.json` rewritten atomically (temp + rename) on every change. Files written before manifest entry appended. Deletion removes file then manifest entry.
- Design tokens: deck `#F0EFEA`, screen `#1A1A1A` + scanlines, ink `#1C1C1C`, screen text `#FFFFFF`, dot-matrix green `#9BE870`, accents TE orange `#FF5C00`, blue `#0090FF`, green `#00C853`, red `#E5352B`. Function-only accents (play=green, record/run=orange, error=red, active-mode=blue).
- Typography: uppercase monospaced (SF Mono) technical labels, letter-spaced; SF Pro for text fields.
- Client timeout 1260 s (> server 1200 s) so server error wins.
- `@MainActor` view models; Swift 6 strict concurrency.

---

### Task 1: Project scaffold + DeviceWindow chassis

**Files:**
- Create: `project.yml` (xcodegen input)
- Create: `MicromixApp.swift` (`sources/App/App.swift`), `DeviceWindow.swift`, `Theme/Palette.swift`, `Theme/Typography.swift`

**Interfaces:**
- Produces: `Palette` (static color constants), `Typography` (static font helpers), `DeviceWindow` (`convenient: NSWindow` with a device-panel `NSView`).

- [ ] **Step 1: Write `project.yml`** for xcodegen: app target `Micromix`, macOS deployment, Swift source dir `sources`, no extensions, explicit test scheme `Micromix` (unit tests via Swift Testing). Reference xcodegen schema (`xcodegen --help` / samples).
- [ ] **Step 2: Minimal `Arrangement.swift`** — `MicromixApp: NSApplicationDelegate`, `DeviceWindow` with a full-size `DevicePanelView` (container with top screen region + bottom deck region as two stacked `NSView` region containers). Runs and shows window.
- [ ] **Step 3: `Palette.swift`** — static color constants per Global Constraints colors.
- [ ] **Step 4: `Typography.swift`** — static fonts (SF Mono for labels, SF Pro for fields), `monoLabel(_:)` helper returning styled uppercase letterspaced.
- [ ] **Step 5: Build check** — run the build command; expect it to compile and the app `build` success. Manual launch shows dark top + light bottom.
- [ ] **Step 6: Commit.**

**Test note:** Task 1 is build-verified only (UI). Later tasks add unit tests.

---

### Task 2: Theme components (reusable TE widgets)

**Files:**
- Create: `Theme/PanelButton.swift`, `Theme/LED.swift`, `Theme/DotMatrixScreen.swift`, `Theme/Scanlines.swift`, `Theme/Knob.swift` (kept for reuse; not used in v1)

**Interfaces:**
- Consumes: `Palette`, `Typography` from Task 1.
- Produces: `PanelButton` (`struct` with `title`, `active` state, tap action), `LED` (`color` + `blink` from `Case.`), `DotMatrixScreen` (Canvas/Text-based dot-matrix drawing surface accepting a `content: String` and rendering rows on the `#1A1A1A` panel w/ scanlines).

- [ ] **Step 1:** Write `PanelButton` — hard 1.5-2? px border, flat fill, pressed darkens, active blue dot/underline. Tappable.
- [ ] **Step 2:** Write `LED` — small circle with `LEDColor` (green/red/orange), `blink()` animator.
- [ ] **Step 3:** Write `Scanlines.swift` overlays (`draw()`).
- [ ] **Step 4:** Write `DotMatrixScreen` — draws mono rows onto dark panel, supports big elapsed-time readout, waveform placeholder.
- [ ] **Step 5:** Write `Knob` (reusable; not wired in v1) with indicator line.
- [ ] **Step 6:** Build + commit.

---

### Task 3: Core — SettingsStore + MicromixAPI client

**Files:**
- Create: `Core/SettingsStore.swift`, `Core/MicromixAPI.swift`, `Core/Models.swift`
- Test: `Tests/Core/MicromixAPITests.swift`, `Tests/Core/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `Palette`/none.
- Produces:
  - `SettingsStore` — `var baseURL: String`, `func` load/save (JSON at Application Support).
  - `MicromixAPI` — `Actor`, init with `baseURL`; methods:
    - `func health() -> HealthStatus` (`struct HealthStatus { service,status,minimax,muscriptor : String }`)
    - `func generate(input:String, lyrics:String?, model, format) -> Data` (async, throws on non-2xx)
    - `func transcribe(Math data: Data, filename: String, instruments: [String], detectTempo:Bool) -> Data`
    - `func instruments() -> [String]` (flattens `dict<String,[String]>`)
    - `func` fetch bytes by URLPath.
- [ ] **Step 1:** Unit test (failing) for `SettingsStore.save/load` round-trips to temp dir JSON.
- [ ] **Step 2:** Implement `SettingsStore`.
- [ ] **Step 3:** Unit test (failing) for `MicromixAPI` request building using a stubbed `URLProtocol`: assert `generate` issues JSON body with `input`, `response_format=wav`, no stream; `health` GET path; `transcribe` multipart with repeatable `instruments[]` and file field name `audio_file`.
- [ ] **Step 4:** Implement `MicromixAPI` using `URLSession` with `URLSessionConfiguration` setting `protocolClasses` to the stub; `timeout = 1260s`; content handling `Data`.
- [ ] **Step 5:** Test `instruments()` flattens `dict` group lists.
- [ ] **Step 6:** Run test suite (build `test`), all pass, commit.

---

## Task 4: Library — LocalLibrary persistence

**Files:**
- Create: `Core/LocalLibrary.swift`, `Library/LibraryItem.swift`
- Test: `Tests/Core/LocalLibraryTests.swift`

**Interfaces:**
- Consumes: none.
- Produces:
  - `LibraryItem` struct: `id (UUID)`, `kind (.audio|.mid)` `title`, `createdAt`, `promptOrSource:String`, `durSeconds: Double?`, `relativePath`.
  - `LocalLibrary` — `@MainActor`, `load()`, `items: [LibraryItem]`, `add(item, data) async` (writes file under `audio/` or `midi/` then appends atomically), `remove(id)` async (removes file then manifest), `resolvedURL(for item)`.
  - Encoding: `library.json` array; atomic temp+rename.
- [ ] **Step 1:** Test (failing) for add + atomic rewrite + ordering (files before manifest).
- [ ] **Step 2:** Implement `LocalLibrary` with `FileManager` in App Support dir.
- [ ] **Step 3:** Test deletion removes manifest entry + file.
- [ ] **Step 4:** Test crash-safety: manifest missing file case handled.
- [ ] **Step 5:** Run tests GREEN, commit.

---

## Task 4: JobRunner state machine

**Files:**
- Create: `Core/JobRunner.swift`, `Core/Job.swift`
- Test: `Tests/Core/JobRunnerTests.swift`

**Interfaces:**
- Consumes: nothing (owns async job state).
- Produces:
  - `Job.Idle | Running | Done | Error | Cancelled`
  - `JobRunner` — `@MainActor`, `start(job: Job)`, `cancel()`, `status: Job`, `elapsed` tracking, completion callback.
- [ ] **Step 1:** Failing test for transitions: Idle->Running->Done; Elapsed bumps; Cancel from Running -> Cancelled.
- [ ] **Step 2:** Implement `Job` state enum + `JobRunner` async loop with Task/TaskGroup cancel.
- [ ] **Step 3:** Test error path -> Error state.
- [ ] **Step 4:** GREEN, commit.

---

## Task 5: Library screen + audio playback

**Files:**
- Create: `Library/LibraryScreen.swift`, `Audio/AudioPlayer.swift`
- Test: `Tests/Audio/AudioPlayerTests.swift` (light: creation + derived metadata)

**Interfaces:**
- Consumes: `LocalLibrary`, `DotMatrixScreen`.
- Produces: `LibraryScreen` (list view of items, row selection), `AudioPlayer` (wraps `AVAudioPlayer` play/pause/stop, `nowPlaying`).

- [ ] **Step 1:** Implement `AudioPlayer` (AVAudioPlayer) with state enum and metadata from `AVAudioFile`.
- [ ] **Step 2:** Implement `LibraryScreen` — dot-matrix table (index/title/kind/duration/date), deck transport buttons (play/pause, delete, reveal), empty-state `NO ITEMS`.
- [ ] **Step 3:** Wire into `DeviceWindow` host.
- [ ] **Step 4:** Build; unit-test metadata path; commit.

---

## Task 6: GENERATE flow end-to-end

**Files:**
- Create: `Generate/GenerateScreen.swift`, `Generate/GenerateViewModel.swift`
- Test: `Tests/Generate/GenerateViewModelTests.swift`

**Interfaces:**
- Consumes: `MicromixAPI` (generate), `JobRunner`, `LocalLibrary`, `DotMatrix`.
- Produces: `GenerateScreen` (prompt multi-line editor, lyrics toggle + editor, model preset fixed, format fixed WAV, orange GENERATE button). `GenerateViewModel` drives flow states: idle -> running (elapsed) -> done (bytes -> library) / error.

- [ ] **Step 1:** Failing test for ViewModel: from idle, tap generate -> Running; successful generate adds to library with `.wav`; error -> Error state.
- [ ] **Step 2:** Implement `GenerateViewModel` with `JobRunner`.
- [ ] **Step 3:** Implement `GenerateScreen` (deck controls + dotmatrix readout).
- [ ] **Step 4:** Wire into `DeviceWindow`; manual build check.
- [ ] **Step 5:** GREEN, commit.

---

## Task 7: TRANSCRIBE flow end-to-end

**Files:**
- Create: `Transcribe/TranscribeScreen.swift`, `Transcribe/TranscribeViewModel.swift`, `Transcribe/InstrumentPicker.swift`
- Test: `Tests/Transcribe/TranscribeViewModelTests.swift`

**Interfaces:**
- Consumes: `MicromixAPI` (instruments + transcribe), `JobRunner`, `LocalLibrary`.
- Produces: `TranscribeViewModel` — file drop zone + picker, instrument multi-picker from flattened instruments list, tempo toggle, flow states -> MIDI bytes saved as `.mid` + manifest.

- [ ] **Step 1:** Failing test for VM: file selected + instruments + tap -> Running -> success adds `.mid` to library.
- [ ] **Step 2:** Implement `TranscribeViewModel`.
- [ ] **Step 3:** Implement `InstrumentPicker` (from grouped `/instruments`).
- [ ] **Step 4:** Implement `TranscribeScreen` drop/pick UI; wire.
- [ ] **Step 5:** GREEN, commit.

---

## Task 8: MIDI preview synth

**Files:**
- Create: `Audio/MidiPreview.swift`
- Test: `Tests/Audio/MidiPreviewTests.swift` (light, no audio assert)

**Interfaces:**
- Consumes: `LocalLibrary`, MIDI files.
- Produces: `MidiPreview` wrapping `AVAudioEngine` + `AVAudioUnitSampler` with a bundled GM soundfont; play/stop.

- [ ] **Step 1:** Write `MidiPreview` — engine + nampler unit with soundfont; `play(url)` loads MIDI file, stop; state.
- [ ] **Step 2:** Unit test that it can init engine + build sampler (no audio assert).
- [ ] **Step 3:** Wire MIDI preview into Library transport (replacing generic player for `.mid`).
- [ ] **Step 4:** Build, commit.

---

## Task 9: Polish — error states, cancel, health LED, elapsed display

**Files:**
- Modify: `MicromixApp.swift`, `Theme/LED.swift`, `Core/MicromixAPI.swift`
- Create: `App/ConnectionMonitor.swift`

**Interfaces:**
- Consumes: `MicromixAPI.health`.
- Produces: `ConnectionMonitor` — routes `/health` every 15s and on demand, drives `LED` state + summary modals.

- [ ] **Step 1:** Implement `ConnectionMonitor` (periodic 15s `/health`, on-demand), drives LED + screen banner when unreachable; disables Generate/Transcribe.
- [ ] **Step 2:** Surface shim errors (400/408/413/503) on dot-screen red with detail; return to idle.
- [ ] **Step 3:** Wire cancel (JobRunner cancel) to all long jobs; ensure server-ec error wins (client 1260s > server 1200s).
- [ ] **Step 4:** Add elapsed display to all running states.
- [ ] **Step 5:** Build + run manual checklist; commit.

---

## Execution Handoff

Once implemented: subagent-driven development executes task-by-task with review; final whole-branch build/test verification before completion.
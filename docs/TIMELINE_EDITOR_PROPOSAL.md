# Proposal: Micromix native AI-cover production editor

**Status:** planning complete; implementation not started or authorized by this document.
**Planning baseline:** current uncommitted working tree, inspected 2026-11-12. User explicitly permitted planning without pulling or changing application code. This is not a clean/reproducible release revision.
**Tracking:** `PLAN.md` task 20 tracks this proposal. Existing tasks 12–13 remain open. The milestones below are proposed future work, not a second active implementation queue.

## 1. Product decision and definition of done

Build an **audio-first, native Mac production workspace**: generate/prepare assets, assemble and edit a complete AI cover, balance it, audition alternatives, save/recover the project, and export the finished song without leaving Micromix. Take the directness of a small Logic arrangement window, not Logic's entire feature set.

This expands the current roadmap's basic-arrangement/Logic-finishing boundary. Before implementation, explicitly approve the bounded scope below and reconcile `docs/MICROMIX_ROADMAP.md` and README. Do not silently treat their existing exclusions as already removed. Logic becomes an optional advanced handoff, not a required step for the supported cover workflow. This proposal does not establish that current separation or voice-conversion quality is acceptable.

### Supported cover workflow

1. Import a song, existing stems, or generated accompaniment into the Library/project.
2. Split stems and convert a vocal using existing local tools, or generate/reference/repaint an asset. Retain originals, alternatives, provenance and English/Vietnamese lyrics drafts.
3. Place accompaniment and vocals at known positions. Preserve shared source timing; expose uncertain latency/alignment and allow precise manual correction rather than guessing.
4. Drag, blade, trim, duplicate, rearrange and fade clips; audition takes; use a constant-tempo musical grid when useful without forcing audio onto it.
5. Balance gain/pan/mute/solo, make transitions and apply a small set of native finishing controls if needed.
6. Export a complete stereo song, optional time-aligned stems and a recoverable project. Reopen the project and revise it without re-running inference.

**Acceptance scenario:** a user completes one approved English and one Vietnamese cover entirely in Micromix, including an edit to the converted vocal, an alternative take, project reopen, and final export. The user judges intelligibility, artifacts, transitions and mix quality. Automated tests cannot close this gate.

### Bounded scope

| Essential for the editor | Later, only after the essential path works | Explicitly not in this proposal |
| --- | --- | --- |
| Multiple audio clips per track; Library/Finder drag-in; selection/move/trim/blade; duplicate/delete; undo/redo; snapping and zoom | Ripple editing, slip tool, transient snapping, elastic time/pitch and automatic alignment, after separate quality/design approval | Piano roll, notation, MIDI instruments/sequencing, recording studio and hardware input monitoring |
| Seconds and optional bars/beats; markers; loop region; sample-precise numeric edits | Tempo maps, advanced comping/take lanes and parameter automation | Video editing, plugin marketplace/AU hosting, arbitrary routing/buses/sidechains, full Logic project interchange |
| Track gain/pan/mute/solo; clip gain/fades; explicit crossfades; basic meters; safe export | Richer mixer or mastering assistant only if demonstrated necessary | Cloud inference, multi-user projects, agent/MCP editor control, new model infrastructure |
| In-context generation and vocal/stem workflows; explicit insert/replace; durable recovery | New model-dependent cleanup or vocal-improvement features after corpus evaluation | Claims of automatic professional mastering, transparent time stretching or perfect stem separation |
| Atomic save, autosave recovery, missing-media handling, project collection and stereo/stem export | Optional additional delivery formats after evaluation | Replacing the existing Library, job service, provenance system or app shell |

A compact EQ/compression/reverb/peak-safety strip is included in the final production milestone, not a general plugin rack. It may be omitted from a particular cover; defaults must not silently change its sound. If covers require detailed tuning, warping or cleanup beyond the supported controls, record that limitation rather than calling the workflow complete.

## 2. What exists today: reuse, do not rebuild

Source observations below refer to the inspected working tree, not runtime acceptance:

- `MacOS/sources/Timeline/TimelineEditor.swift:5–167`: persistent workspace UI, add-from-Library menu, numeric offset/source trims, sliders, ruler/seek, save/open and reference export. The colored bars are not draggable audio waveforms. The editor stops playback when deactivated.
- `TimelineModel.swift:5–40, 111–152`: `TimelineTrack` combines one Library asset and one placement. Runtime IDs are created afresh; the v1 document has no independent persistent track/clip IDs. There is no multiple-clip track representation.
- `TimelineModel.swift:189–239, 262–318`: edits invalidate and stop playback; audition rebuilds an `AVMutableComposition` for `AVPlayer`. Generation and seek revisions reject stale asynchronous operations. Reuse those correctness principles, not the stop/rebuild-on-every-mouse-move policy.
- `ArrangementDocument.swift:4–41, 45–78`: validated version-1 JSON, stable Library UUID references, atomic saves, dirty baseline and save/discard/cancel behavior. Missing media is retained rather than replaced by a guessed match.
- `ReferenceRenderer.swift:78–107` and existing renderer tests: bounded reference rendering, captured source snapshots, safe destination ownership and a 30-minute limit. Preserve these safety guarantees; it is not yet a general mix engine.
- `Audio/MiniWaveform.swift:4–35`: bounded file reads and peaks covering all frames/channels. Reuse correctness tests; a zoomable stereo timeline needs a multiresolution cache rather than rerunning whole-file extraction at every width.
- `Core/LocalLibrary.swift`, `RelatedAssets.swift`, `AssetAction.swift`, `JobRunner.swift`, `JobReattacher.swift`: authoritative SwiftData Library, existing provenance/action handoffs and guarded durable local jobs. Extend at these seams, not with a second asset database or job queue.
- Existing `Tests/Timeline/` covers timing, persistence/resolution/session and reference rendering; `Tests/Audio/PreviewExclusionTests.swift` and `WaveformCoverageTests.swift` cover shared playback and waveform edges. Expand these suites rather than replacing them.
- `MacOS/project.yml` targets macOS 26 and Swift 6. No older-OS compatibility layer is needed for this proposal.

The existing plan reports 278 tests / 39 suites for its latest headless run. That is historical evidence, not a test run performed for this proposal. Visual, listening, model quality and manual acceptance remain open.

## 3. Reference investigation: Palmier Pro

Palmier Pro is a **video editor**, not an audio DAW. Its public site describes an AI-integrated native Mac timeline. Its complete public source made binary reverse engineering unnecessary for this planning pass. No app was installed, launched, driven or benchmarked.

Source snapshot: [`palmier-io/palmier-pro`, `dfc810b561f1692947eb81bbb689e078923ebb59`](https://github.com/palmier-io/palmier-pro/tree/dfc810b561f1692947eb81bbb689e078923ebb59). Links below are pinned to that revision. Paths are under `Sources/PalmierPro/` unless specified.

| Source observation | Relevant evidence | Micromix application / limitation |
| --- | --- | --- |
| SwiftUI embeds an AppKit scroll/document view; canvas follows the visible rectangle and clip drawing is culled | [`Timeline/TimelineContainerView.swift:15–43`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Timeline/TimelineContainerView.swift#L15-L43), [`Timeline/TimelineView.swift:62–91, 740–778`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Timeline/TimelineView.swift#L62-L91) | Use a custom native timeline surface, not thousands of independent SwiftUI clip subtrees. Drawing culling does not prove indexed/sublinear model traversal or measured speed. |
| Input controller distinguishes razor/edge/move gestures; preview trim/move deltas are bounded to media | [`Timeline/TimelineInputController.swift:211–238, 464–519`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Timeline/TimelineInputController.swift#L211-L238) | Separate gesture previews from a single committed edit. Resolve collisions and source bounds before committing. |
| Snap engine supports clip edges, markers, playhead, beat points and sticky hysteresis | [`Timeline/SnapEngine.swift:20–108`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Timeline/SnapEngine.swift#L20-L108) | Use screen-space snap tolerance and stable priority; test model placement, not only the snap indicator. |
| Foundation UndoManager wraps named grouped transactions and inverse operations; some edits use timeline snapshots | [`Editor/EditorUndo.swift:3–55`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Editor/EditorUndo.swift#L3-L55), [`Editor/ViewModel/EditorViewModel+ClipMutations.swift:93–164`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Editor/ViewModel/EditorViewModel%2BClipMutations.swift#L93-L164) | Adopt one undo transaction per user operation; do not infer that Palmier has one uniform command-object architecture. |
| Peak extraction uses Accelerate with a bounded mono envelope; visual cache deduplicates work, limits concurrency to two and checks a disk cache | [`Audio/WaveformExtractor.swift:5–60`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Audio/WaveformExtractor.swift#L5-L60), [`Timeline/MediaVisualCache.swift:7–15, 82–98, 231–247`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Timeline/MediaVisualCache.swift#L82-L98) | Reuse the scheduling/cache concept, not its fixed-detail mono representation. Micromix needs channel-aware peaks and deep zoom. |
| Playback rebuilds use snapshots, caching, cancellation and generation/active-timeline checks | [`Preview/VideoEngine.swift:318–397`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Preview/VideoEngine.swift#L318-L397) | Preserve stale-work rejection. Video composition is not evidence of sample-accurate low-latency audio editing. |
| Generation creates timeline placeholders at captured positions; completion changes matching clip media/duration | [`Generation/Submission/MusicGenerationSubmission.swift:79–96`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Generation/Submission/MusicGenerationSubmission.swift#L79-L96), [`Editor/ViewModel/EditorViewModel+GeneratedClips.swift:20–78`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/Sources/PalmierPro/Editor/ViewModel/EditorViewModel%2BGeneratedClips.swift#L20-L78) | Learn in-context job placement, but require explicit insert/replace approval and handle deleted targets, changed projects, undo and different output lengths. Do not silently expand into neighboring clips. |

**License boundary:** the inspected root [`LICENSE`](https://github.com/palmier-io/palmier-pro/blob/dfc810b561f1692947eb81bbb689e078923ebb59/LICENSE) is GPL-3.0. Independently implement the behavior using Apple APIs; do not copy source/assets or add Palmier as a dependency by default. If reuse is later proposed, review applicable license obligations first. This is not a legal opinion.

**Unknowns:** source inspection did not establish Palmier's latency, memory use, accessibility, playback/export fidelity, or correctness after generation/undo/collision races. There was no binary/runtime analysis. No performance claim in this proposal is derived from marketing or a benchmark of Palmier. Logic is an interaction reference, not an inspected implementation.

## 4. Recommended architecture

### 4.1 Document and edit core first

Evolve the arrangement document to a versioned **project → tracks → clips** value model. Keep Library assets authoritative; timeline instances refer to them.

- Project: persistent UUID, schema version, title, fixed session rate, ordered tracks, optional constant BPM/meter, markers, loop range and mix settings.
- Track: persistent UUID, name/color/role, gain/pan/mute/solo, ordered clips, optional bounded native effects settings.
- Clip: persistent UUID, Library UUID, timeline start and source start/length in integer session frames, clip gain, envelope settings and alignment/provenance annotation. Source frame positions refer to the asset's continuous session-rate representation, not independently rounded native-frame cuts. Retain original native sample rate/frame count and conversion provenance at the asset level.
- Default session rate: 48 kHz; hardware rates are independent. Build a deterministic session-rate PCM proxy once per distinct asset revision using streaming conversion of the continuous source. For matching-rate PCM, an equivalent direct read is allowed. All instances/split halves read the same logical proxy frame sequence: do not restart a resampler at each clip boundary. Key proxies by source checksum, rate/channel policy and converter version; retain/recreate the exact representation for a saved project. Originals remain untouched. Use half-open ranges `[start, end)` and checked 64-bit arithmetic; derive adjacent split boundaries once. Mixed-rate split/render null tests are an M0 gate, not a deferred assumption.
- Quantize imported seconds/native positions once with documented rational rounding (at most half a session frame per independently imported boundary), then edit only in session frames. No repeated source/session rounding on move/split/save. Original native positions remain provenance, not a competing mutable edit timebase.
- Separate persisted edits from selection, zoom, hover, transport and job progress. Media resolution/cache state is not a dirty edit.
- Named edit operations (`MoveClips`, `TrimClip`, `SplitClips`, `InsertAssets`, `DeleteSelection`, `SetMix`, etc.) validate and apply atomically. Use value snapshots/inverses proportional to the edit and Foundation UndoManager. Avoid a framework or event-sourcing system.
- One drag/fader gesture equals one undo entry; Escape and failed validation restore the pre-gesture state. Persist after a committed operation, not each pointer event.

**Version-1 migration:** read the existing JSON unchanged, create one track and clip per old row, preserve Library UUID/title/offset/absolute trims and unresolved media. Quantize seconds once, report conversion tolerance, and assign stable project/track/clip IDs when writing the new version. Preserve the original file; Save As the new format on first migration. Do not support lossy write-back to v1. Unknown future schemas fail without modifying the file.

Before changing any schema, approve exact units, rounding, validation limits and migration fixtures. Source metadata must be resolved or explicitly unavailable; never fabricate a source sample rate for missing media. Retain legacy timing until it can be resolved.

### 4.2 Native interaction surface

Keep SwiftUI for the workspace, Library browser, toolbar, track controls and inspector. Embed an AppKit `NSScrollView`/custom `NSView` canvas through `NSViewRepresentable` for timeline drawing, input, autoscroll, cursor and hit testing.

- One shared time-to-screen transform for ruler, waveforms, hit tests, snapping, playhead, marquee and drop ghosts. Zoom around pointer/playhead; preserve the anchor while scrolling. Fixed track headers and ruler stay aligned with the scrolled content.
- Draw only visible tracks/time ranges using per-track sorted clip intervals. Cache reusable waveform paths/tiles; invalidate changed rectangles, not the full document on every transport tick.
- Separate static background/grid/clips from playhead/selection/gesture overlays. Display refresh follows the audio clock without publishing the entire project every frame.
- Start with Core Graphics/Accelerate and layer-backed overlays. Add Metal only if profiling identifies drawing as the bottleneck; do not build a custom GPU renderer preemptively.
- A custom canvas needs explicit accessibility elements/actions, keyboard focus and meaningful announcements. Retain exact numeric inspector controls for every time-based action. Accessibility is an implementation requirement, not a later cosmetic pass.

Suggested new responsibilities, names provisional: `TimelineProject`, `TimelineEdit`, `TimelineCanvas`, `TimelineInteractionController`, `TimelineGeometry`, `TimelineSnapEngine`, `WaveformCache`, `TimelineAudioEngine`, `TimelineRenderPlan`, `TimelineJobPlacement`. Preserve/refactor existing `ArrangementSession`, `TimelineCloseGuard`, `LocalLibrary` and preview coordination rather than running parallel systems.

### 4.3 Audio transport and render parity

**Recommendation:** a focused `AVAudioEngine` transport with scheduled player lanes/mixers, not AVPlayer composition rebuilds for interactive production. First prove it with a small headless prototype; do not migrate everything on assumption alone.

- An immutable render plan resolves clips into explicit source ranges, scheduled times, gain/pan/fades, routing and expected output duration. The same plan and DSP semantics drive real-time audition and offline export; use separate engine instances so export never steals the active playback engine.
- A serial control owner prepares schedules and graph changes. Background workers read/decode/resample into bounded buffers as needed. Schedule against one engine/host-time anchor, accounting for seek position and clips beginning before it; do not start independent players sequentially and assume synchronization.
- Begin with a bounded player-lane pool for simultaneously active clips, recycling outside the scheduling horizon. Node count follows active overlap, not total project clip count. Validate file-segment scheduling versus prepared PCM for fades/crossfades and exact boundaries in the prototype.
- Prefer native scheduling/mixers/effects. If sample-accurate envelope application requires prepared PCM, apply it off the real-time thread into bounded look-ahead buffers, not whole-song buffers. A custom render unit is a separately justified fallback, not the starting architecture.
- No filesystem reads, decoding, allocation, locks, actor hops, logging or SwiftData/UI work in app-owned real-time callbacks. Completion handlers only signal bounded state; dispatch control work safely. Do not stop a player directly from its completion callback.
- UI position derives from engine/player time with a display refresh adapter. Wall-clock timers are not the audio scheduler. Seek/schedule generations reject stale preparation/completion, including device changes and cancel/restart.
- Structural edits while playing become one committed new plan, applied at a defined safe boundary while preserving position. A short explicit reprepare is acceptable in the first slice; arbitrary graph rebuilds on each pointer move are not. Verify gain/mute smoothing and avoid promising click-free live edits until measured/heard.
- Continue using the existing exclusive-preview coordinator for Library, MIDI and timeline. Initially preserve stop-on-workspace-change; offer persistent timeline playback only after app-wide command/focus semantics are separately approved.
- Handle default-device changes, headphones removal, sleep/wake and format changes with visible transport state and a safe reprepare, not unexpected autoplay.

Apple primary references: [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine), [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode), [offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing). Their documentation establishes scheduled segments/buffers, separate player/node time domains, stop unscheduling, graph-change constraints and bounded offline rendering. It does not establish that our proposed scheduler is correct or fast; the prototype must prove that. Offline loops require cancellation, bounded no-progress retries, status handling, exact output length and effect-tail policy.

### 4.4 Waveforms, memory and local inference

- Session-rate proxies are disk-backed, streamed and shared across clip instances; never retain entire decoded songs in RAM. At float32 stereo/48 kHz they cost about 23 MB/minute per distinct asset, so account for free disk space, cap regenerable caches and show preparation progress. Missing/evicted proxies are regenerated before playback with visible readiness; disk exhaustion fails safely. Collected projects include their required proxies/converter identity when exact reconstruction cannot otherwise be guaranteed.
- Build multiresolution per-channel min/max peak pyramids once per asset revision. Optional RMS is secondary; represent stereo truthfully. Fetch detail tiles or samples at extreme zoom instead of retaining every raw sample.
- Cache key: content checksum or validated file identity/version, channel/layout/rate and extractor version. Do not key only by path or requested view width. Cache is disposable, size-bounded, evictable and never project truth.
- Deduplicate in-flight extraction, prioritize visible clips, cancel obsolete detail requests and start with at most two extractors. Limit memory/disk caches and decoded look-ahead independently. Missing peaks show a placeholder without blocking editing.
- Imported audio should use a staged file-based Library import path rather than reading large files into one `Data`; `LocalLibrary.add(bytes:)` remains useful for existing small outputs. Validate/copy off the main actor, commit Library records on its owner, and clean up failures.
- Local MLX inference shares unified memory and thermal headroom with audio. Keep the existing single disposable model worker; avoid concurrent extraction/export storms. Initially warn/allow pausing generation during demanding playback. Any concurrency policy must be supported by user-led measurements, not arbitrary CPU-priority settings.
- Baseline supports mono/stereo readable audio; reject unsupported multichannel layouts with a clear message until downmix policy is approved. Never silently discard channels. Preserve source files even if decoded proxies are used.

## 5. Exact editing semantics

| Action | Proposed behavior and edge cases |
| --- | --- |
| Select/move | Pointer tool selects; Shift toggles; marquee selects a range of clips. Drag preserves group spacing. Vertical drag changes track; Option-drag duplicates. A multi-selection move is all-or-nothing. Clamp the whole group at zero, not each member separately. |
| Library/Finder drop | Show destination/time ghost before commit. Library payload uses stable IDs; Finder import validates and stages through Library first. Multi-file drop defaults to one track per file at a shared start, preserving stem alignment. No accidental import from a cancelled drag. |
| Blade | Dedicated Blade tool and Split at Playhead command; split selected clips intersecting the cut. Keep the left ID, allocate a right ID, preserve exact coverage of the shared session-rate source representation, and reject boundary/zero-length cuts. Undo restores the original. A split alone must null against the uncut render, including mixed-rate sources. Do not add automatic fades to every split. |
| Trim | Edge drag adjusts source range and visible duration without stretching audio. Left trim changes timeline start and source start together; right trim keeps start fixed. Expand only within source bounds; expose exact numeric edits. Preview is transient until commit. |
| Snapping | Toggle plus temporary bypass; snap to clip edges, playhead, markers and optional musical grid. Screen-space tolerance with hysteresis and deterministic priority; exclude the moving group's own anchors. Report the snapped target. Free/sample edits remain available. |
| Overlap/collision | Default same-track overlap is rejected visibly or routed to a new track only by explicit user action. Intentional two-clip overlap uses an explicit crossfade operation. No silent ripple, overwrite or deletion. Validate the entire gesture and new generated-asset duration. |
| Duplicate/copy/paste/delete | Non-destructive instances referencing the same asset; paste at playhead with group offsets intact. Delete affects clips only, not Library media. Every action is one undo transaction. |
| Fades/crossfades | Draggable fade handles with numeric duration; nonnegative fades bounded to clip length. Equal-power crossfade is an explicit default, adjustable if correlated material causes a bump. Store an envelope's original curve domain separately from each clip's active segment: splitting partitions the same curve without restarting or rescaling it. Crossfades have a stable relationship/envelope identity; a split partitions participating segments while preserving their overlap sum. Trim clips the active domain; changing a fade handle is an explicit new envelope edit. Tests must show identical split/unsplit output inside fades/crossfades and undo restoration. Independent clips may overlap on different tracks and sum normally. |
| Track controls | Rename/reorder/color; gain, pan, mute/solo and clip gain. Define mono pan law/stereo balance, solo precedence and smoothing consistently in audition/export. No normalization of individual stems behind the user's back. |
| Grid and transport | Seconds always available. Optional constant BPM/meter/grid changes display/snapping only; audio remains time-anchored and is not warped on tempo change. Ruler seek, loop range, return-to-start, zoom-to-selection and keyboard nudge. |

Suggested shortcuts: Space play/pause, Escape cancel gesture, standard Cmd-Z/Shift-Cmd-Z and clipboard commands, Delete remove clips, Cmd-B split at playhead, arrow-key nudge with a documented fine/coarse modifier. Resolve conflicts against existing workspace commands before adopting tool-letter shortcuts. Do not intercept typing in prompts, lyrics or numeric fields.

## 6. AI tools inside the production workflow

Use an in-workspace operation inspector or sheet backed by existing view-model/service behavior. Do not require navigating away and losing edit context, but do not rewrite all generation forms before the first integration works.

1. Capture source asset(s), selected source/time range, project UUID, intended track/clip UUID, project revision and insertion mode when submitting. Existing job/provenance storage remains authoritative for execution; add only durable project-placement intent.
2. Whole-source operations can reuse existing contracts. For a region operation, create a non-destructive rendered input slice and store its source mapping. Repaint APIs may have whole-source timing semantics: verify them before translating clip-relative time to API input.
3. Progress/placeholders are session/job overlays, not playable fake media. Jobs survive workspace navigation/relaunch through existing recovery. Deleting or undoing an intended insertion detaches placement; cancellation is a separate explicit action.
4. Import completed outputs into Library first. Present alternatives and explicit **Insert at captured position**, **Replace selected clip**, **Add aligned stems**, or **Keep in Library**. Never silently overwrite the current clip or a newly opened project.
5. On acceptance, revalidate target identity/media, user edits since submission, duration/collision and known alignment. A changed/deleted target falls back to a visible pending result/Library, not guessed placement. One accepted placement is one undoable edit; undo never deletes a completed asset or reruns inference.
6. Persist an idempotent placement token so recovery cannot insert twice. Crash between Library import and project save must leave a recoverable result; document save and placement bookkeeping need reconciliation, not an assumed distributed transaction.
7. For vocal conversion/stem split, preserve available source timeline origin. If output padding/latency differs, show it as unverified; provide sample nudge and in-context audition. Optional correlation alignment is a later evaluated tool, not an automatic truth claim.

Start with **selected clip → Vocal Swap → audition result with accompaniment → accept alternative**. Add Stem Split, Generate/Reference and region Repaint after that single chain is reliable. Preserve corrected/raw lyrics and language intent in existing flows.

## 7. Persistence, media ownership and export

- Keep versioned atomic document writes and native save/discard/cancel close/quit guards. Add debounced autosave/recovery snapshots after committed edits, with schema validation and a visible recovery choice. Recovery never overwrites the last explicit save without consent.
- Linked mode resolves stable Library identity; unresolved clips remain visible and retain edits. Add explicit relink with identity/duration validation and confirmation, not filename guessing.
- Introduce project/media reference protection before relying on long-lived projects. At minimum block/warn on deletion of assets used by known projects and explain that unopened external documents cannot all be discovered. Offer **Collect Project** to copy required media plus checksums into a self-contained package for reliable archival. Undo/alternate takes must retain required media.
- A collected package has a versioned manifest mapping package asset IDs to original Library IDs, relative media/proxy paths, checksums, native format and provenance. On open, validate path containment/checksums/schema first, then stage import into the authoritative Library before resolving clips. Reuse a matching Library ID only when its content identity agrees; on an ID collision with different content, allocate a new Library ID and retain an explicit package-to-Library mapping. Never replace an existing asset. Missing/modified package media remains unresolved with an explicit repair choice. Failed import leaves the package and current project unchanged and cleans owned staging files. Persist remapped references in the opened project's new save, not by modifying the source package. This supports an empty/different Library without introducing a second authoritative asset database.
- Export captures an immutable document and stable source snapshots before work begins. Keep existing clone/copy fallback, disk-space warnings, cancellation cleanup and unique output-directory ownership. Never render against live changing files.
- First delivery: stereo 48 kHz WAV, with documented PCM encoding/dither, selected/full-project range and explicit effect-tail treatment. Offer aligned stems from a common zero with the same trim/offset/gain/fade semantics and clearly state pre/post-effects and master-processing policy.
- Preserve the old reference exporter and original-source bundle export until parity tests justify replacing their internals; label reference versus finished mix and original-source versus aligned-stem bundles distinctly.
- Mix safely in float with meters and a defined master headroom policy. Preserve relative balances. Keep the current conservative sample-peak-safe export as a fallback; true-peak/loudness claims require an implemented meter, oversampling/measurement and verification. No guessed LUFS or invisible per-track normalization.
- Return the exported mix to Library with project/source/operation provenance and retain an export manifest containing schema, timings, settings, source checksums and any unresolved warnings. Only claim reproducibility for included/resolved media and supported processing.

## 8. Delivery sequence and exit gates

Execute one approved milestone at a time. Estimates should be made after M0; source inspection alone is not enough to promise dates.

### M0 — Approve scope and prove the risky audio path
- Approve this product boundary, reconcile roadmap/README and reconcile Git before implementation. Retain existing manual gates; use a small approved synthetic/private fixture set.
- Headless prototype: synchronized two-source/then multi-lane playback plan, seek mid-clip, continuous 44.1→48 kHz proxy conversion, fades/crossfades, mute/gain changes and offline output using the same plan.
- Tiny fixtures prove exact silence/impulse positions, mixed-rate split/unsplit null results, split-inside-envelope parity, repeated split/move/save stability, bounded proxy/scheduling memory and stale-work rejection. User-led listening/device/performance checks validate the engine choice.
- **Exit:** choose native segment/buffer scheduling based on evidence; define schema/timebase/overlap rules and record limitations. If it fails, investigate narrowly rather than immediately introducing a third-party engine or custom real-time kernel.

### M1 — Multiple-clip document, commands and recovery
- Add stable track/clip/project IDs, validated frame-domain operations and v1 migration. Integrate undo/redo, atomic save, close guards, autosave recovery and missing media.
- Tests: schema fixtures/unknown versions; split conservation; move/trim/group invariants; undo/redo round trips; checked overflow; migration tolerance; cancelled/failed save; crash-recovery selection. Source files unchanged.
- **Exit:** a multi-clip arrangement survives save/reopen/undo without media or timing loss. No new canvas required yet; use minimal inspector/test harness.

### M2 — Responsive timeline and waveform foundation
- Native scroll/zoom canvas, ruler, track headers, selection, separate playhead overlay, stereo waveform pyramid/cache and accessible numeric inspector. Library/Finder drag import with ghosts and staged file ownership.
- Tests: coordinate round trips across zoom/scroll/Retina; visible-range queries; cache invalidation/channel coverage; cancel import; large-file streaming; hit-test and keyboard logic.
- **Exit:** user verifies navigation, waveform/source alignment, drop locations and keyboard/VoiceOver at 900×640, 980×700 and larger, with sidebars toggled. Performance remains a measured gate.

### M3 — Daily editing: drag, blade, trim and snap
- Implement gestures, group move, track changes, duplicate/copy/paste/delete, blade/playhead split, markers, snap/bypass/hysteresis and exact nudge. Add fades and explicit crossfade operations.
- Tests: half-open cut bounds, no zero clips, selection identity after split/undo, no source gaps/duplication, collisions, autoscroll and Escape rollback; one undo per gesture.
- **Exit:** user edits a full-length synthetic/stem arrangement without numeric-only workarounds; unsplit versus split/render null test passes for neutral processing.

### M4 — Production transport and basic balance
- Integrate the proven engine, loop/seek, shared preview ownership, track/clip gain, pan, mute/solo, meters and plan swaps. Cover device changes, sleep, rapid edits and stale callbacks.
- Tests: sample-positioned impulse/sine fixtures, seek/loop boundaries, pan law/solo, schedule cancellation and render-plan equivalence. No uncontrolled full-song decoding.
- **Exit:** user hears aligned playback and artifact-free transitions at supported load; record device/rate/buffer and CPU/memory results. UI correctness alone does not pass.

### M5 — One complete AI-cover chain in the editor
- **Quality dependency:** fake-job integration and synthetic editor tests may proceed after M4, but real full-song conversion/reference integration requires the accepted separation/conversion/alignment evidence from existing `PLAN.md` task 12 and the explicit design approval required by task 13. Otherwise keep that real-model portion blocked; only a separate user decision may revise the dependency. M6's finished-cover acceptance cannot bypass it.
- Integrate selected-vocal conversion and accompaniment audition first, then aligned stem insertion, generation alternatives and region repaint. Add durable placement intent, revision validation, explicit acceptance and idempotent recovery.
- Tests: destination deleted/edited, project switched/closed, job failure/cancel/restart/recovery, output-duration mismatch, multi-output selection and undo after completion. Existing API suites run if any contract changes.
- **Exit:** user completes the source → stems → converted vocal → edit → balanced audition chain locally without leaving the app. Model quality remains independently evaluated.

### M6 — Finish, collect and export
- Add the bounded native EQ/compression/reverb controls where needed, explicit peak-safety policy and audible bypass; prove latency/tail handling and persist settings. Add final mix/aligned stems, manifest, Library registration and Collect Project.
- Tests: live/offline agreement, effect bypass/settings round trip, output duration/tails, channel/sample-rate policy, clipping policy, dither policy, empty-Library package open, UUID/content collisions, package checksum/path validation, missing media, full destination, cancellation, source mutation and cleanup. Keep original reference export regressions.
- **Exit:** collected project opens without original Library paths; user accepts two complete covers and their exported WAVs. Optional Logic import confirms interoperability, not a dependency on Logic for completion.

### M7 — Performance, accessibility and resilience acceptance
- Test the agreed normal/stress fixtures, Instruments/Allocations/Time Profiler and Audio diagnostics with user-led runs. Correct the measured bottleneck, not speculative architecture.
- Verify keyboard-only, VoiceOver, focus/shortcuts, light/dark contrast, long sessions, project migration, recovery, device churn and inference contention.
- **Exit:** recorded target-Mac results satisfy the budgets below or the supported limits are reduced and documented. Only then mark the production editor accepted.

## 9. Performance targets and verification protocol

These are **proposed acceptance budgets**, not current benchmark results or a guarantee for every Mac. Record model/chip/RAM, macOS, app revision, audio interface, sample rate/buffer, source codec and inference state. Agree on the primary machine and fixtures in M0.

| Workload/metric | Initial target |
| --- | --- |
| Normal project | 10 minutes, 24 audio tracks, 500 clip instances, up to 16 simultaneously audible mono/stereo voices at 48 kHz; fixed budget of native effects to be chosen in M0 |
| Interaction | Sustained 60 Hz target; p95 timeline frame ≤16.7 ms during warm scroll/drag; no main-thread stall >50 ms from our media/cache work |
| Transport | Warm play/seek response p95 ≤100 ms; no audible glitches/dropouts during a 10-minute user-run normal-load pass; cold preparation reported separately |
| Editor working set | Target incremental editor memory ≤512 MiB over the app's measured baseline, excluding sidecar model memory; caches and decode pools have enforced caps |
| Warm project reopen | First usable timeline ≤1 second for the normal fixture; peaks/import may continue visibly in the background |
| Export | Faster than real time for the normal fixture without inference on the target Mac; memory bounded independently of duration; no UI blocking |
| Stress exploration | 64 tracks / 2,000 clips / longer files, with active overlap still bounded; establish supported limits rather than promise unlimited voices. Current 30-minute renderer cap stays until a separately tested increase is approved. |

Measure distributions across repeated warm/cold runs and retain fixtures/settings, not a single best number. UI latency and audio deadline safety are different metrics. Meters need bounded refresh; every clip must not publish at display rate. Require tests for cache/disk exhaustion and cancel/restart under pressure. Automatic performance or listening acceptance is prohibited by repository rules: provide the user a focused runbook and wait for results.

### Headless checks after implementation slices

Run focused Swift `Testing` suites first, then the full safe suite via a durable background task:

```bash
cd MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

If the sidecar contract changes, run its existing lightweight unittest suite via a separate background task. Do not start model downloads or real inference as part of headless checks. Inspect tests for desktop-sensitive behavior first.

### User-led acceptance runbook

From repository root, the user runs `bash scripts/micromix.sh rebuild` to build/launch Release (recheck script if modified), with existing local sidecar as needed. The agent must not launch/control the desktop or start heavy profiling/inference unattended.

1. Open agreed fixtures; record device/load; navigate and edit with mouse, keyboard and VoiceOver. Verify drag/trim/blade/snap/undo at multiple zooms and window sizes.
2. Audition known impulses/stereo fixtures, then a song; seek/loop/change balance and check transitions, synchronization and preview exclusion.
3. Exercise cancel/restart, navigate away, close/reopen, recover autosave, and restore/relink missing media. Verify no result inserts into the wrong project.
4. Run the normal/stress profiling cases and repeat with one approved local inference job; report Instruments traces, memory and any dropout timing. Do not commit private media/traces containing private identifiers.
5. Complete English/Vietnamese covers, collect/reopen projects and listen to exported mixes/stems. Compare audition/export; record model quality separately from editor defects.

## 10. Risks, decision gates and next bounded action

- **Scope creep:** implement M0–M4 as the editor foundation, then M5–M6 for the promised end-to-end outcome. Stopping after blade/drag is not completion of the user's goal.
- **Audio correctness:** mixed rates, split rounding, pan laws, envelope scheduling and effect latency can break parity. Synthetic sample-domain tests and the engine spike precede production migration.
- **Asset loss:** Library deletion, missing files and asynchronous jobs outlive an open canvas. Stable IDs, media ownership, collection and recovery are required, not optional polish.
- **Quality dependency:** current separation/conversion may fail real covers. Preserve tasks 12–13's quality gate; do not mask model artifacts with speculative mixing features or declare success from health checks.
- **Unified-memory contention:** measure on the actual Mac; keep inference, waveform work and export bounded and observable.
- **Reference uncertainty:** Palmier patterns are source observations, not proof of production behavior. Implement independently, verify locally and do not import its video/cloud architecture.

**Next action after approval:** reconcile the dirty checkout under repository rules, promote only M0 into `PLAN.md` as the active implementation task, update the canonical product scope, and build the tiny transport/render parity prototype. Do not start by rewriting the app shell or adding a blade button to the current one-asset-per-track model.

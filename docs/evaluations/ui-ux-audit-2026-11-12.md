# Micromix macOS UI/UX audit — 2026-11-12

## Scope and evidence

Source-based review of the complete native journey: launch/readiness → navigation → source selection → Generate/Reimagine/Analyze/Transcribe/Vocal Swap/Stem Split/GUIDE → job feedback and recovery → result audition and continuation → Library → timeline → export/Logic handoff. Reviewed current checkout `53704f7`, CodeGraph (reported current), screen implementations, view models, routing, theme tokens, and existing plans/tests. Two independent read-only reviews covered creative/transcription screens and guided/source-processing flows.

**No desktop interaction, screenshots, fresh tests, inference, listening, or Logic imports were performed.** Source-confirmed behavior is separated below from rendered-layout and usability risks requiring user-led validation. This is not a completed visual or real-model end-to-end acceptance pass. The dirty `PLAN.md` was preserved before replacement; the user explicitly authorized auditing this checkout without pulling.

## Overall assessment

The app already has most of the valuable building blocks. The next meaningful upgrade is a coherent, trustworthy path from input to a chosen result—not another top-level tool or a wholesale visual redesign. The current sidebar shell is newer than several entries in the previous plan; its interaction with older fixed-width forms is the most important layout concern.

### Existing functionality to retain

- Seven selectable workspaces plus GUIDE; sidebar navigation, workspace descriptions, keyboard shortcuts, collapsible sidebars, and a shared session inspector already exist.
- Seeded variations, musical metadata, English/Vietnamese vocal-language intent, and reference/remix/repaint already exist.
- Audio and MIDI previews, Library collections/search, alternatives/A-B comparison, lineage, related assets, bundle export, and durable job recovery already exist.
- Lyrics transcription already exists as an explicitly unverified local Whisper draft; do not implement ASR again.
- A simple multitrack timeline is explicitly approved in the current roadmap. It currently provides temporary numeric trimming/offsets and synchronized audition; do not misclassify the approved simple editor as forbidden, or expand it into a full DAW.

## Prioritized findings

### F1 — High: sidebar shell leaves too little space for fixed-width forms

**Evidence:** `MacOS/sources/App/DeviceWindow.swift:57–58,84,123,140` defaults both sidebars open, reserves 184 + 244 points and adds 48 points of canvas padding. `MicromixApp.swift:112–120` permits 900-point windows and defaults to 980. This leaves roughly 422/502 points of usable canvas at minimum/default widths before panel padding. Generate's metadata row alone specifies 120 + 72 + 92 + 72 + 235 points plus spacing (`GenerateScreen.swift:103–125`); engine/duration controls and Reimagine rows also use fixed horizontal layouts. GUIDE has seven choices in a non-wrapping HStack (`WorkflowGuide.swift:26–58`).

**Impact:** The source establishes incompatible width demands; exact clipping/compression, scroll friction and perceived hierarchy require visual confirmation.

**Upgrade:** Use available canvas width to choose stacked/adaptive forms and an overlay/collapsed inspector. Keep source, essential creative choices, primary action and results prominent; move seed and optional metadata into a clearly labelled advanced disclosure. Do not merely enlarge the minimum window. Preserve the warm hardware identity but reduce repeated headings and tiny labels.

### F2 — High: preview and continuation can refer to different variations

**Evidence:** `GenerateScreen.swift:158–173` and `ReimagineScreen.swift:183–198` preview the first audio result but give next actions the last result. Library already supports alternative selection and comparison.

**Upgrade:** Explicit selected-result identity, labelled alternatives, and a shared result surface. Preview, next action, export and Library reveal must all target that selection. Show useful output roles rather than only completion text.

### F3 — High: source handoffs can silently fail

**Evidence:** `Core/AssetAction.swift:178–204,219–250` navigates before calling `acceptSource`; destination models can refuse a source while busy (`ReimagineViewModel.swift:245–248`). The selection UI can therefore still show the previous source. Async selection in `TranscribeViewModel.swift:141–156` has no newest-request guard; a slower earlier selection can overwrite a later one.

**Upgrade:** Validate destination availability and file presence before navigation; publish loading/success/failure acknowledgement; preserve an active job and source on rejection. Use selection tokens and block submission during source replacement. Apply the pattern to other asynchronous source receivers after inspecting them, not by speculative rewrite.

### F4 — High: generation lyrics can discard musical direction

**Evidence:** `GenerateViewModel.swift:51–56,66–85` chooses nonempty lyrics as `effectiveInput` and submits that as the prompt even when the separate prompt editor contains musical direction. `GenerateScreen.swift:29–43` presents the prompt as optional alongside lyrics, implying both inputs matter.

**Upgrade:** Keep prompt and lyrics independent through request construction; retain a documented lyrics-only fallback compatible with existing engines. Add request-level regression coverage before changing behavior.

### F5 — High: standalone transcription has lifecycle gaps

**Evidence:** `TranscribeViewModel.swift:215–282` captures the durable ID only after submission and writes `phase` directly from its async closure. Cancel-before-accept and rapid restart can leave late jobs uncancelled or permit obsolete completions to overwrite state. The MIDI durable path returns on empty outputs without setting a terminal phase (`:228–241`). Existing `JobFlow` patterns already guard run identity in other tools.

**Upgrade:** Reuse the existing guarded lifecycle where practical; test delayed acceptance, cancellation, restart, missing output and failure for both MIDI and lyrics. Do not equate existing guided-cancellation fixes with complete standalone coverage.

### F6 — High: “READY” does not establish selected-workflow readiness

**Evidence:** `App/ConnectionMonitor.swift:79–87` stores model statuses separately from service connectivity. `DeviceWindow.swift:178–179,569–592` uses connectivity for ready/enabled state. Model marker readiness is not successful model loading. Voice catalog error/empty/offline distinctions already exist and should be retained.

**Upgrade:** A compact workflow-specific prerequisite summary with refresh, unavailable/unknown explanations, and links to local setup instructions. Gate confirmed missing prerequisites; do not treat uncertain status as a proven failure or claim inference was verified. Keep Library, previews, export and on-device Analyze usable without the sidecar.

### F7 — Medium: long-running work and background work are poorly legible

**Evidence:** Generate has honest indeterminate progress and elapsed time (`GenerateScreen.swift:144–151`); Reimagine, Transcribe and source processing mainly change the action label (`ReimagineScreen.swift:154–180`, `TranscribeScreen.swift:56–80`, `SourceProcessingScreen.swift:92–108`). Header status follows only the selected workspace except during recovery (`DeviceWindow.swift:154–175`); the session inspector repeats the selected status rather than exposing all active work (`:451–512`).

**Upgrade:** Reusable state presentation for selecting/uploading/waiting/running/recovering/cancelling/completed/failed when the API actually supports those distinctions. Show elapsed time without fabricated percentages or ETAs. Add a compact active/recovering-jobs summary with navigation and cancellation, reusing durable records rather than a second job store. Keep action/cancel feedback reachable in long forms.

### F8 — High: deletion is immediate and errors are swallowed

**Evidence:** `Library/LibraryScreen.swift:345–350` calls `try? library.remove` from DELETE without confirmation. `Core/LocalLibrary.swift:169–183` removes the audio file before deleting/saving its record. A database failure can leave the record pointing to a missing file.

**Upgrade:** Explicit destructive confirmation naming the item, visible errors and a recoverable deletion strategy. Preserve related results and accurately explain lineage effects. Do not silently broaden deletion to an entire family or add a schema migration without need.

### F9 — Medium: Library is crowded and selection is mouse-centric

**Evidence:** `LibraryScreen.swift:20–28,148–164` defines a fixed-column list limited to 190 points inside the shell's own ScrollView. Rows use `onTapGesture` (`:221`), the selected inspector uses a 278-point seek control and unwrapped action row (`:289–299`), and transport shrinks text as low as 0.68 × 11 points (`:307–407`). Provenance and related panels push transport down. No rename operation exists in `LocalLibrary`.

**Upgrade:** A flexible results list with native keyboard selection semantics, concise selected-asset actions, responsive transport, and collapsed technical detail. Add display-title rename without changing source files, IDs or provenance. Keep existing search/filter/A-B behavior; do not build a new organization system or file browser.

### F10 — Medium: visual tokens and custom semantics need accessibility work

**Evidence:** Theme tokens give white-on-orange primary text approximately 3.10:1, blue-on-deck 2.84:1 and green-on-deck 1.94:1 at full opacity (`Theme/Palette.swift`; standard relative-luminance calculation). The 14-point semibold primary button uses white on orange (`DeckControls.swift:65–84`), below a 4.5:1 normal-text target. Many labels are 8–11 points. `PanelToggleStyle` implements a Button without explicit checked-state semantics (`:32–58`). GUIDE's shared navigation label can announce “mode 8 of 7” because the guide is excluded from the count (`DeviceWindow.swift:370–371`). Workspace shortcuts are attached to sidebar views that are conditionally removed; native window buttons are hidden and their custom replacements live only in the collapsible sidebar (`:184–245,277,383`).

**Upgrade:** Accessible text-specific tokens, stronger contrast, readable labels, non-colour state cues, keyboard/focus and toggle-state checks. Keep window actions and shortcuts available with the sidebar hidden. **Unverified:** actual VoiceOver exposure, shortcut loss and focus behavior need headless semantic tests where feasible and user-led checks; do not assert runtime failures from source alone.

### F11 — Medium: guided output promises exceed actual output

**Evidence:** Guided Cover and split-first Vocal Swap return converted vocals, not a mixed song (`Guide/GuidedCover.swift:148–163,305`; `GuidedVocalSwap.swift:142–166,303`). The accompaniment exists separately. Static GUIDE promises “clean” vocals and analysis of “structure” (`WorkflowGuide.swift:129,176`), neither guaranteed by the implementation. Guided Remix marks analysis complete even when it yields only duration (`GuidedRemix.swift:160–165`; `Audio/LocalMusicAnalyzer.swift:27–48`).

**Upgrade:** Show the actual stage outcomes, converted vocal and available accompaniment as a pair, honest fallback/quality copy and an explicit Logic handoff. A balanced full-song reference is a valuable later upgrade, but only after separation/conversion quality and alignment pass user-led evaluation. Keep Guided Remix's prepared-source handoff explicit rather than pretending it rendered a remix.

### F12 — Medium: guided transcription and lyrics drafts lack a natural finish

**Evidence:** Guided Transcribe always uses all instruments and automatically routes the original source to Reimagine (`GuidedTranscribe.swift:120–126,145–161`; `MicromixApp.swift:50–54`). Standalone Transcribe already has MIDI/lyrics output choice, but its lyrics result is selectable read-only text (`TranscribeScreen.swift:30–53,86–103`) and the static MIDI heading remains in its default workspace description.

**Upgrade:** Default guided completion to saved/previewable MIDI with explicit optional remix continuation; offer optional instrument selection. For lyrics, expose Copy, a corrected-draft edit/save path and an explicit Use as Generate lyrics action, preserving the independent prompt and language. Retain the original ASR draft and draft-quality warning. Update workspace copy to explain both outputs.

### F13 — Medium: Repaint bounds and analysis handoffs need clearer validation

**Evidence:** Repaint shows START/END without units/source duration (`ReimagineScreen.swift:225–229`) and validates interval length/finiteness rather than complete source bounds (`ReimagineViewModel.swift:222–227`). Analyze always offers USE IN GENERATE after completion, although duration-only analysis supplies none of the metadata Generate consumes (`AnalyzeScreen.swift:44–57`; `GenerateViewModel.swift:129–148`).

**Upgrade:** Seconds and source duration beside in-bounds range controls; actionable errors before submit. Show precisely which derived fields will transfer and preserve user overrides; explain no-transfer cases.

### F14 — Medium, approved follow-up: timeline is still an ephemeral audition prototype

**Evidence:** `Timeline/TimelineEditor.swift:8,43,53–74` owns an in-memory model, explicitly discloses no save/export and offers numeric edits with unlabelled bars. `TimelineModel.swift` has no persistent session or rendered export. `TIMELINE_PLAN.md` records prior approval for a simple editor and explicitly leaves persistence/export/direct manipulation pending.

**Upgrade:** First add ruler/playhead and accessible, bounded trim/offset interactions. Then save/reopen small local arrangements referencing stable Library assets and provide an explicit rendered reference export that applies those edits; existing bundle export must not imply it does. Define missing-asset recovery and output safety tests before implementation. Keep source media unchanged; no mixer/plugin/automation expansion. User-led alignment, audio-quality and reopen/export acceptance remain mandatory.

## Prioritization and non-goals

1. Fix correctness/data-loss risks (F2–F5, F8) and truthful readiness before adding features.
2. Make the existing shell, forms, results and Library usable at the actual supported sizes; add consistent state and accessibility semantics.
3. Complete guided/transcription finishes and the already-approved small timeline increment.
4. Evaluate an assembled Vocal Swap reference only after quality gates; do not start Vocal Improve, Mashup, Complete or new model work solely because those entries remain on a historical roadmap.

## Required user-led acceptance

Use `PLAN.md` task 12 for exact build/run steps and the focused end-to-end checklist. Review at 900×640, default 980×700 and a larger window, with both sidebar states, system light/dark appearance, keyboard-only navigation and VoiceOver. Include English and Vietnamese, multi-variation outputs, MIDI and lyrics, missing prerequisites, failed/cancelled/recovered jobs, missing media, export and Logic import. No source-only audit can certify any of these rendered/audio outcomes.

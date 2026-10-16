# Micromix: Cohesive Workflow Design Plan

**Status:** Active — replaces all prior plans  
**Last updated:** 2026-10-16  
**Scope:** Chain the seven tools into one flowing app experience

---

## Current State

You have seven isolated workspaces that work independently:

| Workspace | Input | Output | Engine |
|-----------|-------|--------|--------|
| **Generate** | Text prompt + optional lyrics | 1–4 WAV variations | ACE-Step XL Turbo/SFT |
| **Reimagine** | Audio file + operation | WAV (reference/remix/repaint) | ACE-Step XL Turbo/SFT |
| **Analyze** | Audio file | BPM, key, meter (display only) | Apple Music Understanding |
| **Transcribe** | Audio file | MIDI file | MuScriptor |
| **Vocal Swap** | Audio file + voice model | WAV (converted vocal) | MLX-RVC |
| **Stem Split** | Audio file + description | 2 WAVs (target/residual) | SAM Audio |
| **Library** | — | Saved results, playback, provenance | SwiftData |

All inference runs locally via FastAPI sidecar at `127.0.0.1:8902`. Jobs are durable (SQLite), recoverable, and cancellable. The UI is clean, minimal, dot-matrix inspired.

---

## The Problem

These workspaces are **silos**. A user cannot:
- Send a generated result directly into Reimagine for remixing
- Send a stem-split vocal into Vocal Swap
- Send an analyzed file's detected BPM/key into Generate
- Chain transcription → stem split → vocal swap in one flow
- See relationships between related assets in Library

The app feels like seven separate tools, not one cohesive music workstation.

---

## The Solution: Asset-Centric Workflow Chains

Replace mode-switching with **asset-centric navigation**. Every output becomes a node. Every node offers **next actions**. The user stays in context, not in modes.

### Core Concepts

1. **Asset Node** — Any result (WAV, MIDI) with metadata, provenance, and available actions
2. **Next Actions** — Contextual operations available for an asset (remix this, split this, swap vocals on this, transcribe this)
3. **Quick Chain** — One-tap continuation that pre-fills the next operation
4. **Workflow Trail** — Visual lineage showing how an asset was created

### Workflow Map

```
Generate ──┬──► Reimagine (reference/remix/repaint)
           │
           └──► Stem Split ──┬──► Vocal Swap (on vocal stem)
                           │
                           └──► Reimagine (on instrumental)

Import ────► Analyze ──────► Generate (prefilled BPM/key)
     │
     └──────► Transcribe ──► Library (MIDI for DAW)

Any Audio ──► Stem Split ──┬──► Vocal Swap
                           └──► Reimagine (on isolated stem)
```

---

## Phase 1: Asset Actions Foundation

**Goal:** Every Library item and fresh result shows contextual next actions.

### Tasks

- [x] **1.1 Define AssetAction types**
  - `remix`, `repaint`, `stemSplit`, `vocalSwap`, `transcribe`, `analyze`, `referenceGenerate`
  - Each action knows its source asset ID and pre-fills target workspace
  - Landed in `MacOS/sources/Core/AssetAction.swift`

- [x] **1.2 Add actions to Library items**
  - Library row shows available actions as small icon buttons
  - Clicking an action switches to target workspace with pre-filled source
  - Landed via `router.availableActions(for:)` / `router.execute` in `LibraryScreen`

- [x] **1.3 Add actions to result screens**
  - Generate/Reimagine/Vocal Swap/Stem Split results show "Continue to..." chips
  - Single tap chains to next operation
  - Landed via `NextActionsRow`; Vocal Swap and Stem Split were completed 2026-10-16,
    with one chip row per output so both stem-split outputs are chainable

- [x] **1.4 Pre-fill target workspaces**
  - When navigating with a source asset, the target workspace:
    - Shows source filename
    - Pre-fills any derived metadata (BPM from analysis, etc.)
    - Ready to run immediately or adjust first
  - Landed via `acceptSource(_:)` on every workspace view model

---

## Phase 2: Smart Handoffs

**Goal:** Metadata flows automatically between operations.

### Tasks

- [x] **2.1 Analysis → Generation**
  - Analyze results populate Generate's BPM/key fields
  - Add "Use these settings" button in Analyze
  - Landed as "USE IN GENERATE" plus "USE IN REIMAGINE" chips in `AnalyzeScreen`

- [x] **2.2 Stem Split → Vocal Swap**
  - Stem Split producing "vocals" target offers direct "Swap Voice" action
  - Pre-fills the vocal stem as source
  - Landed via the target output's `SWAP VOICE` chip

- [x] **2.3 Any Audio → Reimagine**
  - All audio outputs can become Reimagine source
  - Operation selector (reference/remix/repaint) shown before switching
  - Landed via `USE AS REFERENCE` / `REMIX` / `REPAINT` chips on every audio result

- [x] **2.4 Generate → Reimagine**
  - Generated variations offer "Remix this" and "Repaint section" actions
  - Seed/variation metadata preserved in provenance

---

## Phase 3: Workflow Trail Visualization

**Goal:** Users see how an asset was created and what else was produced.

### Tasks

- [x] **3.1 Enhance Library provenance display**
  - Show parent job ID, source asset, operation chain
  - Collapsible trail: Source → Operation → Output
  - Landed 2026-10-16 as the SHOW TRAIL toggle in the provenance panel

- [x] **3.2 Group alternatives in Library**
  - Variations from same job shown as expandable group
  - Select any variation, see siblings
  - Landed as the PREV/NEXT/ALT-n alternatives row

- [x] **3.3 Add "Related" section**
  - For any asset, show:
    - Siblings (same job, other variations)
    - Parent (source asset)
    - Children (assets derived from this)
  - Landed 2026-10-16 as the RELATED ASSETS panel; lineage resolves from
    durable provenance (remote output ids, then sha256 checksums, since
    re-uploaded sources always receive a fresh sidecar id)

---

## Phase 4: Guided Workflows

**Goal:** Offer pre-built chains for common tasks.

### Tasks

- [x] **4.1 "Make a Cover" workflow**
  - Import song → Analyze → Stem Split → Vocal Swap → Library
  - Guided stepper UI showing progress
  - Landed 2026-10-16 as the GUIDE tab's COVER STUDIO: one source and voice
    choice, then durable stem-split → vocal-swap jobs run back to back (the
    vocal stem's registered asset feeds the swap without a re-upload), with a
    live stage stepper, cancellation, and result next-actions. Analyze stays a
    separate optional step; the stepper covers the transformation core.

- [x] **4.2 "Remix My Track" workflow**
  - Import → Analyze → Reimagine (with pre-filled metadata)
  - Optional: Stem Split first for isolated remixing
  - Landed 2026-10-16 as the GUIDE tab's REMIX STUDIO: optional split-first
    (delivers the instrumental residual) and optional on-device BPM/key read,
    then hands the source and direction to Reimagine via the router; the
    creative direction itself stays in Reimagine.

- [x] **4.3 "Transcribe and Remix" workflow**
  - Import → Transcribe (get MIDI) → Reimagine (use original audio)
  - Keep both MIDI and new audio
  - Landed 2026-10-16 as the GUIDE tab's TRANSCRIBE STUDIO: one source and a
    strict-tempo toggle, then a durable transcription job runs; the MIDI lands
    in the Library and the original audio is handed to Reimagine via the
    router, so both the notation and the remix source move forward together.

- [x] **4.4 "Vocal Swap Studio" workflow**
  - Import → optional Stem Split → Vocal Swap → Library
  - Landed 2026-10-16 as the GUIDE tab's VOCAL SWAP STUDIO: a SPLIT VOCALS
    FIRST toggle decides between an isolated-stem swap (the split's registered
    vocal asset feeds the swap without a re-upload) and a direct swap of the
    source; the skipped split stage shows as SKIPPED in the stepper. Voice,
    pitch, cancellation, and result next-actions match the other studios.

---

## Phase 5: In-Context Preview

**Goal:** Reduce mode-switching for auditioning.

### Tasks

- [x] **5.1 Inline player in result cards**
  - Every result row shows play/pause without opening full player
  - Landed 2026-10-16 as a shared `InlinePlayButton` chip on the Generate,
    Reimagine, Vocal Swap/Stem Split, and guided cover result rows; it loads
    the saved asset through the shared `AudioPlayer`, so only one stream plays
    at a time. Transcribe results are MIDI and keep using the Library preview.

- [x] **5.2 Compare alternatives**
  - Select multiple variations, A/B compare
  - Simple toggle between two playing sources
  - Landed 2026-10-16 in the Library ALTERNATIVES row: pin the selected
    variation into slots A and B, then a single A⇄B toggle switches playback
    between the two pinned sources through the shared AudioPlayer. Pins are
    validated against the current alternatives group, so stale pins from
    another job never appear.

- [x] **5.3 Waveform peek**
  - Show mini waveform in result rows
  - Visual confirmation before chaining
  - Landed 2026-10-16 as a WAVE column in the Library list: audio rows render
    a 24-bar mini waveform (computed off-main and cached per item); MIDI rows
    show a dash. The same waveform now sits beside the inline play chip on the
    Generate, Reimagine, Vocal Swap/Stem Split, and guided-studio result rows,
    so the shape is visible right where chaining decisions are made. Also
    gates the Phase 5.2 A/B compare pins to audio items so MIDI can never
    route through the audio player.

---

## Phase 6: Export & Handoff

**Goal:** Move finished assets into the DAW (Logic) without manual file hunting.

### Tasks

- [x] **6.1 Job bundle export**
  - One action gathers the asset, its job siblings, and any child assets into
    a single Finder folder with a provenance manifest
  - Landed 2026-10-16 as `LocalLibrary.exportBundle(for:)` plus an EXPORT
    button in the Library transport row: files are copied under
    `<library>/Exports/<jobid8>-<title> [ N]` with numbered, role-prefixed
    names and a manifest.txt (job, operation, source, per-file roles); the
    folder is revealed in Finder. Missing source files fail with a visible
    error. Covered by `BundleExportTests`.

- [x] **6.2 Bundle export carries parent sources**
  - Include the original (parent) assets so a Logic session kit holds the
    source alongside its stems
  - Landed 2026-10-16: `exportBundle(for:)` appends the resolved parent
    sources after siblings and children, so the selected result and its
    chains keep the leading numbers and the original lands as trailing
    reference material; a missing parent file is silently skipped like any
    other grouped entry. Covered by `BundleExportTests` (4 tests).

---

## Implementation Notes

### Architecture Changes

1. **Add `AssetAction` enum and router**
   - `MacOS/sources/Core/AssetAction.swift`
   - Maps asset + action → target workspace + prefill

2. **Extend ViewModels with `acceptSource()`**
   - Each workspace VM can receive a source asset from outside
   - Sets up UI state without starting job

3. **Add `WorkflowRouter`**
   - Centralized navigation logic
   - Handles chain prefill and mode switching

4. **Library enhancements**
   - Action buttons on rows
   - Related assets query
   - Grouped alternatives display

### No Breaking Changes

- Existing standalone workflows keep working
- Actions are additive, not replacements
- Library schema unchanged (provenance already stores job chain)

### Sidecar Compatibility

- No changes needed to `local-inference`
- All operations already supported
- Just calling existing endpoints in sequence

---

## Success Criteria

1. User can generate audio → remix it without re-selecting file
2. User can stem-split → vocal-swap in two taps
3. Library shows related assets and derivation trail
4. Analysis results pre-fill generation controls
5. No manual file hunting between operations

---

## Next Action

The full plan is implemented: Phases 1–5, all four guided workflows, and
Phases 6.1–6.2 (129 native tests in 23 suites pass; visual `DeviceWindowTests`
still excluded). The sidecar half was verified ready for the manual pass on
2026-10-16: its 39 lightweight tests pass, `/v1/health` reports ready with all
five model engines' dependencies present, and the running LaunchAgent process
predates no sidecar code change (started 2026-10-06, last sidecar commit
2026-09-18), so the app tests against current backend code.

The next implementation increment should be chosen after the user's manual
acceptance pass. Remaining candidates, in the order they were scouted:

1. MIDI audition in the Library — MIDI rows currently show a dash in WAVE and
   get no play chip; an `AVMIDIPlayer` path with the system DLS soundbank
   would let transcribe/split results be heard in place.
2. Export/import polish surfaced by real Logic imports (folder naming,
   manifest wording) once the user has run an actual handoff.
3. Any gaps from the user's testing notes.

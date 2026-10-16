# Micromix: Cohesive Workflow Design Plan

**Status:** Active — replaces all prior plans  
**Last updated:** 2026-10-15  
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

- [ ] **1.1 Define AssetAction types**
  - `remix`, `repaint`, `stemSplit`, `vocalSwap`, `transcribe`, `analyze`, `referenceGenerate`
  - Each action knows its source asset ID and pre-fills target workspace

- [ ] **1.2 Add actions to Library items**
  - Library row shows available actions as small icon buttons
  - Clicking an action switches to target workspace with pre-filled source

- [ ] **1.3 Add actions to result screens**
  - Generate/Reimagine/Vocal Swap/Stem Split results show "Continue to..." chips
  - Single tap chains to next operation

- [ ] **1.4 Pre-fill target workspaces**
  - When navigating with a source asset, the target workspace:
    - Shows source filename
    - Pre-fills any derived metadata (BPM from analysis, etc.)
    - Ready to run immediately or adjust first

---

## Phase 2: Smart Handoffs

**Goal:** Metadata flows automatically between operations.

### Tasks

- [ ] **2.1 Analysis → Generation**
  - Analyze results populate Generate's BPM/key fields
  - Add "Use these settings" button in Analyze

- [ ] **2.2 Stem Split → Vocal Swap**
  - Stem Split producing "vocals" target offers direct "Swap Voice" action
  - Pre-fills the vocal stem as source

- [ ] **2.3 Any Audio → Reimagine**
  - All audio outputs can become Reimagine source
  - Operation selector (reference/remix/repaint) shown before switching

- [ ] **2.4 Generate → Reimagine**
  - Generated variations offer "Remix this" and "Repaint section" actions
  - Seed/variation metadata preserved in provenance

---

## Phase 3: Workflow Trail Visualization

**Goal:** Users see how an asset was created and what else was produced.

### Tasks

- [ ] **3.1 Enhance Library provenance display**
  - Show parent job ID, source asset, operation chain
  - Collapsible trail: Source → Operation → Output

- [ ] **3.2 Group alternatives in Library**
  - Variations from same job shown as expandable group
  - Select any variation, see siblings

- [ ] **3.3 Add "Related" section**
  - For any asset, show:
    - Siblings (same job, other variations)
    - Parent (source asset)
    - Children (assets derived from this)

---

## Phase 4: Guided Workflows

**Goal:** Offer pre-built chains for common tasks.

### Tasks

- [ ] **4.1 "Make a Cover" workflow**
  - Import song → Analyze → Stem Split → Vocal Swap → Library
  - Guided stepper UI showing progress

- [ ] **4.2 "Remix My Track" workflow**
  - Import → Analyze → Reimagine (with pre-filled metadata)
  - Optional: Stem Split first for isolated remixing

- [ ] **4.3 "Transcribe and Remix" workflow**
  - Import → Transcribe (get MIDI) → Reimagine (use original audio)
  - Keep both MIDI and new audio

---

## Phase 5: In-Context Preview

**Goal:** Reduce mode-switching for auditioning.

### Tasks

- [ ] **5.1 Inline player in result cards**
  - Every result row shows play/pause without opening full player

- [ ] **5.2 Compare alternatives**
  - Select multiple variations, A/B compare
  - Simple toggle between two playing sources

- [ ] **5.3 Waveform peek**
  - Show mini waveform in result rows
  - Visual confirmation before chaining

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

Start Phase 1.1: Define `AssetAction` types and routing contract.

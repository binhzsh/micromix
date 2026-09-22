# Asset Workspace Implementation Plan

**Status:** Complete. Merged to `main` on 2026-09-18 (PR #3, commit `8d9ede7`).
Smart collections live in `MacOS/sources/Core/Models.swift`; the four audio
handoffs are wired through `DeckRegion` and `LibraryScreen`. Manual visual
acceptance remains part of the local-migration checklist.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS Library a local asset workspace with smart organization, preview and Finder controls, and direct handoffs into each audio workflow.

**Architecture:** Keep `LocalLibrary` and its app-support files authoritative. A pure collection classifier beside `LibraryItem` presents overlapping smart collections without moving files. A selected audio item's resolved URL flows through `DeckRegion`; transcription gets an async selector that preserves existing validation and local analysis.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit, Testing.

**Spec:** `docs/superpowers/specs/2026-09-18-mac-local-parity.md`

## Global Constraints

- The native macOS app and local sidecar remain the only product surfaces.
- Smart collections must not move or duplicate managed files.
- Only audio assets can enter Reimagine, Stem Split, Vocal Swap, or Transcribe.
- Automated verification is headless only.

---

### Task 1: Define smart collections and test classification

**Files:**
- Modify: `MacOS/sources/Core/Models.swift`
- Modify: `MacOS/Tests/Core/ProvenanceTests.swift`

**Interfaces:** Produces `LibraryCollection: String, CaseIterable, Identifiable, Sendable`, `func includes(_ item: LibraryItem) -> Bool`, and `LibraryItem.workspaceOperation: String?`.

- [x] **Step 1: Write failing tests** for generation, transformation, vocal/stem, MIDI, and type-exclusion cases.
- [x] **Step 2: Run the focused suite** with `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/ProvenanceTests`; expect a missing-symbol build failure.
- [x] **Step 3: Add the minimal classifier.** Match audio/MIDI kind first and normalized persisted provenance operation second.
- [x] **Step 4: Re-run the focused suite;** expect PASS.
- [x] **Step 5: Commit** with `feat(library): classify local assets into smart collections`.

### Task 2: Preserve transcription validation for managed Library assets

**Files:**
- Modify: `MacOS/sources/Transcribe/TranscribeViewModel.swift`
- Modify: `MacOS/sources/Transcribe/TranscribeScreen.swift`
- Modify: `MacOS/Tests/Transcribe/TranscribeViewModelTests.swift`

**Interfaces:** Consumes a `LocalLibrary`-resolved URL; produces `func select(url: URL) async -> Bool`.

- [x] **Step 1: Write a failing test** that calls `await vm.select(url: temporaryWAV)` and verifies its source name and selection.
- [x] **Step 2: Run** `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/TranscribeViewModelTests`; expect missing API failure.
- [x] **Step 3: Implement the selector.** Read off-main-actor using `readSource`, run `LocalMusicAnalyzer`, and reuse `select(name:bytes:analysis:)`. Route picker/drop through this same method.
- [x] **Step 4: Re-run the focused suite;** expect PASS.
- [x] **Step 5: Commit** with `feat(transcribe): accept managed library audio`.

### Task 3: Build the Library asset workspace and flow handoffs

**Files:**
- Modify: `MacOS/sources/Library/LibraryScreen.swift`
- Modify: `MacOS/sources/App/DeviceWindow.swift`

**Interfaces:** Consumes collection classification, `resolvedURL(for:)`, and the URL-based transcription selector. Produces `onReimagine`, `onStemSplit`, `onVocalSwap`, and `onTranscribe` closures accepting a `URL`.

- [x] **Step 1: Add smart collection and search state.** Filter the existing newest-first library items without mutating `LocalLibrary`.
- [x] **Step 2: Render only filtered items and preserve selected-item safety** when an active filter or search hides it.
- [x] **Step 3: Expand the selected-asset inspector.** Keep play, pause, stop, delete, provenance copy and Finder reveal; add an `OPEN` default-handler command and audio-only `REMIX`, `SPLIT`, `SWAP`, and `TRANSCRIBE` actions.
- [x] **Step 4: Wire the four actions in `DeckRegion`.** Assign existing source URLs before switching modes; await successful transcription selection before switching to its mode.
- [x] **Step 5: Run** `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -parallel-testing-enabled NO -skip-testing:MicromixTests/DeviceWindowTests`; expect all nonvisual suites to pass.
- [x] **Step 6: Commit** with `feat(library): add local asset workspace handoffs`.

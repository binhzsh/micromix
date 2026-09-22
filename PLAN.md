# PLAN: Unify Generate and Reimagine on one shared job-flow core

## Context
- Roadmap Phase 1 item 1: "Standardize source selection, creative direction,
  alternatives, progress, cancellation, and result presentation across Generate
  and Reimagine."
- Two divergent run patterns existed:
  - Generate/Transcribe: `JobRunner` + `lastItem` scalar, no `errorMessage`,
    no results list, no error UI.
  - Reimagine/SourceProcessing: ad-hoc `Task` + run-ID guard + `results: [LibraryItem]`
    + `errorMessage`.
- Concrete defects: Generate dropped alternatives (`items.first`) despite
  `variationCount` 1–4; Generate had no error surface; Reimagine had no elapsed
  progress.
- Decision: extract the Run/Phase enum shape (idle/running/done/error/cancelled)
  and the run-state machine into a shared `JobFlow` in `Core/`, adopt it in
  Generate, Reimagine and SourceProcessing. `JobRunner` stays for Transcribe
  (out of scope; follow-up).

## Tasks
- [x] 1. Add `MacOS/sources/Core/JobFlow.swift`: shared run state (`JobStatus`,
      elapsed ticker, `results`, `errorMessage`), accepted-job tracking,
      cancellation, stale-run guard, shared error formatting.
  - Status: done — builds clean; drives all three flows.
- [x] 2. Migrate `ReimagineViewModel` onto `JobFlow`; keep public surface
      (`phase`, `results`, `errorMessage`, `start()`, `cancel()`); `phase` is now
      the shared `JobStatus`.
  - Status: done — all 12 Reimagine tests pass.
- [x] 3. Migrate `SourceProcessingViewModel` onto `JobFlow` (same engine).
  - Status: done — all SourceProcessing tests pass.
- [x] 4. Migrate `GenerateViewModel` onto `JobFlow`; replace `lastItem` with
      `results`, add `errorMessage`, add post-submit stale-cancel guard.
  - Status: done — Generate tests pass, plus 2 new regression tests.
- [x] 5. Surface parity in UI: Generate and Reimagine show result count + error;
      Reimagine readout shows elapsed progress.
  - Status: done.
- [x] 6. Verify: `xcodegen generate` + full `xcodebuild test`.
  - Status: done — 90 tests / 15 suites pass (`** TEST SUCCEEDED **`).

## Verification
- `xcodebuild test` → 90 tests, 15 suites, TEST SUCCEEDED.
- New tests: "durable generation publishes every recovered alternative",
  "cancelling before acceptance cancels the job that arrives late".
- Residual: SourceKit-LSP findings are false positives (see `.pi/memory/tooling.md`).

## Log
- 2026-09-22: Plan created after reading both view models, screens, JobRunner,
  tests, and SourceProcessingScreen.
- 2026-09-22: JobFlow added and adopted by Reimagine, SourceProcessing, Generate.
  UI parity added. 90 tests pass. LSP proved broken workspace-wide and recorded.

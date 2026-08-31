# Mac Job Reattachment and Provenance Implementation Plan

> Execute on an isolated local worktree. Run the full headless Xcode test suite
> after every completed task. Do not automate the active desktop.

## Task 1: Expand the gateway model and API seams

**Files:** `MacOS/sources/Core/Models.swift`, `MicromixAPI.swift`,
`ServiceProtocols.swift`, `MacOS/Tests/Core/MicromixAPITests.swift`

1. Add failing decoding tests for parameters, ordered links, and multi-output
   download from a successful job response.
2. Add Codable `JSONValue`, `RemoteAssetLink`, and expanded `RemoteJob` fields.
3. Expose submit/get/cancel/download primitives while retaining current
   Generate/Transcribe protocol compatibility.
4. Run focused API tests, then the full suite.

## Task 2: Persist pending jobs and result provenance

**Files:** `Models.swift`, `LocalLibrary.swift`, `LocalLibraryTests.swift`

1. Add failing tests for pending-job round trip, idempotent remote-asset import,
   and legacy item compatibility.
2. Add SwiftData records and Codable provenance storage; expose pending jobs and
   atomic add-if-missing/import operations from `LocalLibrary`.
3. Run focused library tests and the full suite.

## Task 3: Reattach and import durable jobs

**Files:** new `MacOS/sources/Core/JobReattacher.swift`,
`ServiceProtocols.swift`, new `JobReattacherTests.swift`

1. Add failing tests for resumed success with multiple outputs, terminal error,
   offline retention, and duplicate/relaunch safety.
2. Implement a main-actor coordinator that polls persisted IDs, verifies output
   SHA-256 before import, and removes a pending record only on terminal handling.
3. Run focused coordinator tests and the full suite.

## Task 4: Wire submission and startup recovery

**Files:** `MicromixApp.swift`, `GenerateViewModel.swift`,
`TranscribeViewModel.swift`, relevant tests.

1. Add failing tests that an accepted job is persisted before waiting and is
   handed to the reattacher after launch.
2. Inject the coordinator through app/view-model composition; preserve existing
   synchronous-looking UI phases and cancellation semantics.
3. Run the full suite.

## Task 5: Add compact Library provenance controls

**Files:** `LibraryScreen.swift`, new/updated view tests where practical.

1. Show selected-item provenance with an accessible copy action and clear legacy
   fallback text.
2. Show a compact recovery status without changing the four-mode layout.
3. Build and run the complete headless suite.

## Task 6: Verify and integrate

1. `cd MacOS && xcodegen generate && xcodebuild test -project Micromix.xcodeproj
   -scheme Micromix -destination 'platform=macOS'`.
2. Inspect the diff, request review, commit narrowly, fast-forward merge, push,
   pull `--ff-only` on `lts1`, and verify hashes match while preserving root
   `AGENTS.md`.
3. Ask the user to manually check selected-item provenance, copy behavior, and
   a relaunch while a real server job remains in progress.

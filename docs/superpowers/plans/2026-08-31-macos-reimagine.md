# macOS Reimagine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the deployed Phase 1B reference, Remix/Cover, and Repaint operations in a durable fifth native macOS workflow.

**Architecture:** Organize the app as one AI music studio with five clear workspaces: `GENERATE` creates original material; `REIMAGINE` transforms a chosen audio source; `ANALYZE` inspects a source and offers preflight metadata; `TRANSCRIBE` converts source audio to MIDI; and `LIBRARY` is the shared asset, audition, and provenance hub. Add a focused `REIMAGINE` workspace that uploads a selected local audio file as a reusable remote asset, submits a typed durable job, and hands completion to the existing `JobReattacher`; the reattacher remains the sole importer, preserving source links and submitted parameters for every variation.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation/URLSession, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-30-micromix-inference-roadmap-design.md`

## Global Constraints

- Do not change the deployed API, Docker services, worker/model configuration, or introduce any DAW-like editor.
- Add a fifth `REIMAGINE` mode; preserve the simple existing `GENERATE` mode.
- Upload through `POST /v1/assets`, then submit exactly one of the reference, remix, or repaint endpoints.
- Expose only source audio, prompt/lyrics, preset, seed, one-to-four variations, BPM, key, time signature, remix strength, and repaint range/strength.
- Locally validate: seed `0...4_294_967_295`, duration `10...600`, BPM `30...300`, variations `1...4`, repaint interval `3...90` seconds.
- Persist the accepted job with `JobReattacher.track(_:)` before recovery; no view model imports results directly.
- Retain every input/output asset link in `LibraryProvenance`. Legacy items remain valid with unavailable provenance.
- Follow red-green-refactor and test headlessly before installing.

---

### Task 1: Studio information architecture and Reimagine screen contract

**Files:**
- Modify: `MacOS/sources/App/DeviceWindow.swift`
- Test: `MacOS/Tests/App/DeviceWindowTests.swift`

**Interfaces:**
- Defines `DeviceMode.reimagine = "REIMAGINE"` and the stable five-workspace order: Generate, Reimagine, Analyze, Transcribe, Library.
- Defines the screen's four ordered sections: source, operation, musical direction, and render.

- [ ] **Step 1: Write the failing workspace-order test**

```swift
@Test @MainActor func studioModesHavePurposefulOrder() {
    #expect(DeviceMode.allCases.map(\.rawValue) ==
        ["GENERATE", "REIMAGINE", "ANALYZE", "TRANSCRIBE", "LIBRARY"])
}
```

- [ ] **Step 2: Verify RED**

Run: `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/DeviceWindowTests/studioModesHavePurposefulOrder`

Expected: FAIL because the dedicated studio workspace does not exist.

- [ ] **Step 3: Define the screen hierarchy without duplicating other workspaces**

```swift
// SOURCE: file picker, selected-file summary, “Analyze source” affordance.
// OPERATION: Reference, Remix, Repaint selector with one sentence of help.
// MUSICAL DIRECTION: prompt/lyrics, preset, prefilled editable BPM/key/meter.
// RENDER: seed, variation count, operation-specific strength/range, Start/Cancel.
```

Keep `GENERATE` text-first, `ANALYZE` inspection-first, `TRANSCRIBE` conversion-first, and `LIBRARY` result-first. Reimagine must link to Analyze and Library rather than embedding analysis history, playback, or a second asset browser.

- [ ] **Step 4: Verify GREEN**

Run the focused `DeviceWindowTests`. Expected: PASS.

- [ ] **Step 5: Commit the information architecture**

```bash
git add MacOS/sources/App/DeviceWindow.swift MacOS/Tests/App/DeviceWindowTests.swift
git commit -m "feat(macos): define reimagine studio workspace"
```

---

### Task 2: Typed Reimagine API contract

**Files:**
- Modify: `MacOS/sources/Core/Models.swift`
- Modify: `MacOS/sources/Core/MicromixAPI.swift`
- Modify: `MacOS/sources/Core/ServiceProtocols.swift`
- Test: `MacOS/Tests/Core/MicromixAPITests.swift`

**Interfaces:**
- Produces `ReimagineOperation`, `ReimagineRequest`, `uploadAsset(data:filename:mediaType:)`, and `submitReimagine(_:)`.
- Produces `DurableReimagineSubmitting` so the view model is testable.

- [ ] **Step 1: Write failing request-shape tests**

```swift
@Test func referenceRequestPostsExactRouteAndBody() async throws {
    let request = ReimagineRequest.reference(
        prompt: "warm piano", lyrics: nil, preset: "turbo", seed: 42,
        variationCount: 2, durationSeconds: 45, bpm: 120, key: "C minor",
        timeSignature: "4", sourceAssetID: "asset-1"
    )
    let (api, recorder) = makeRecordingAPI()
    _ = try await api.submitReimagine(request)
    #expect(recorder.requests.last?.url?.path == "/v1/jobs/reference-generation")
    #expect(recorder.jsonBodies.last?["reference_asset_id"] as? String == "asset-1")
    #expect(recorder.jsonBodies.last?["variation_count"] as? Int == 2)
}
```

- [ ] **Step 2: Verify RED**

Run: `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/MicromixAPITests/referenceRequestPostsExactRouteAndBody`

Expected: compile failure because `ReimagineRequest` and `submitReimagine` do not exist.

- [ ] **Step 3: Add the smallest typed route encoder**

```swift
enum ReimagineOperation: String, Codable, Sendable { case reference, remix, repaint }

enum ReimagineRequest: Sendable {
    case reference(prompt: String, lyrics: String?, preset: String, seed: UInt32?,
                   variationCount: Int, durationSeconds: Double, bpm: Int?,
                   key: String?, timeSignature: String?, sourceAssetID: String)
    case remix(prompt: String, lyrics: String?, preset: String, seed: UInt32?,
               variationCount: Int, sourceStrength: Double, sourceAssetID: String)
    case repaint(prompt: String, lyrics: String?, preset: String, seed: UInt32?,
                 variationCount: Int, startSeconds: Double, endSeconds: Double,
                 repaintStrength: Double, sourceAssetID: String)
}
```

Encode each case through one private `pathAndBody(for:)` helper, upload files with multipart field `audio_file`, and decode the existing `RemoteAsset` response.

- [ ] **Step 4: Add repaint request test and verify GREEN**

```swift
@Test func repaintPostsSourceAndRange() async throws {
    let request = ReimagineRequest.repaint(
        prompt: "replace bridge", lyrics: nil, preset: "quality", seed: nil,
        variationCount: 1, startSeconds: 12, endSeconds: 24,
        repaintStrength: 0.5, sourceAssetID: "source-7"
    )
    let (api, recorder) = makeRecordingAPI()
    _ = try await api.submitReimagine(request)
    #expect(recorder.requests.last?.url?.path == "/v1/jobs/repaint")
    #expect(recorder.jsonBodies.last?["source_asset_id"] as? String == "source-7")
}
```

Run both focused tests. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MacOS/sources/Core/Models.swift MacOS/sources/Core/MicromixAPI.swift MacOS/sources/Core/ServiceProtocols.swift MacOS/Tests/Core/MicromixAPITests.swift
git commit -m "feat(macos): add reimagine API client"
```

### Task 3: Durable Reimagine view model and metadata prefill

**Files:**
- Create: `MacOS/sources/Reimagine/ReimagineViewModel.swift`
- Modify: `MacOS/sources/Analyze/AnalyzeViewModel.swift`
- Test: `MacOS/Tests/Reimagine/ReimagineViewModelTests.swift`

**Interfaces:**
- Consumes `DurableReimagineSubmitting`, `DurableJobCancelling`, `JobReattacher`, and one selected audio URL.
- Produces `start() -> Bool`, `cancel()`, published source/operation/controls/phase, and `prefill(from:)`.

- [ ] **Step 1: Write a failing track-before-recover test**

```swift
@Test @MainActor func acceptedJobTracksBeforeRecovery() async throws {
    let reattacher = RecordingReattacher()
    let model = ReimagineViewModel(api: AcceptedReimagineAPI(jobID: "job-1"), reattacher: reattacher)
    model.sourceURL = fixtureAudioURL
    model.prompt = "new chorus"
    #expect(model.start())
    try await eventually { await reattacher.events == ["track:job-1", "recover:job-1"] }
}
```

- [ ] **Step 2: Verify RED**

Run: `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/ReimagineViewModelTests/acceptedJobTracksBeforeRecovery`

Expected: compile failure because `ReimagineViewModel` does not exist.

- [ ] **Step 3: Implement the minimal durable flow**

```swift
@MainActor final class ReimagineViewModel: ObservableObject {
    @Published var operation: ReimagineOperation = .reference
    @Published var sourceURL: URL?
    @Published var prompt = ""
    @Published var seedText = ""
    @Published var variationCount = 2
    // start uploads, validates, submits, tracks, then recovers.
}
```

Capture request state in immutable locals before starting the job. Reject missing source/prompt, invalid seed/BPM, and invalid repaint range without network access. `prefill(from:)` copies non-nil local BPM/key only when their matching controls were not edited.

- [ ] **Step 4: Add validation and prefill tests; verify GREEN**

```swift
@Test @MainActor func repaintRejectsTwoSecondRangeLocally() {
    let model = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
    model.sourceURL = fixtureAudioURL
    model.prompt = "bridge"
    model.operation = .repaint
    model.startSeconds = 4
    model.endSeconds = 6
    #expect(model.start() == false)
    #expect(model.errorMessage == "REPAINT RANGE MUST BE 3–90 SECONDS")
}
```

Run focused Reimagine tests. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MacOS/sources/Reimagine/ReimagineViewModel.swift MacOS/sources/Analyze/AnalyzeViewModel.swift MacOS/Tests/Reimagine/ReimagineViewModelTests.swift
git commit -m "feat(macos): add durable reimagine workflow"
```

### Task 4: Wire the Reimagine screen through the app

**Files:**
- Create: `MacOS/sources/Reimagine/ReimagineScreen.swift`
- Modify: `MacOS/sources/App/DeviceWindow.swift`
- Modify: `MacOS/sources/App/MicromixApp.swift`
- Test: `MacOS/Tests/App/DeviceWindowTests.swift`

**Interfaces:**
- Adds `DeviceMode.reimagine = "REIMAGINE"` and one app-lifetime `ReimagineViewModel`.
- Renders source-picker, Reference/Remix/Repaint selection, shared controls, operation-specific range/strength, and Start/Cancel.

- [ ] **Step 1: Write the failing mode test**

```swift
@Test @MainActor func deviceModesIncludeDedicatedReimagine() {
    #expect(DeviceMode.allCases.map(\.rawValue) ==
        ["GENERATE", "REIMAGINE", "ANALYZE", "TRANSCRIBE", "LIBRARY"])
}
```

- [ ] **Step 2: Verify RED**

Run: `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/DeviceWindowTests/deviceModesIncludeDedicatedReimagine`

Expected: FAIL because there are only four modes.

- [ ] **Step 3: Wire the screen into both window regions**

```swift
case reimagine = "REIMAGINE"

case .reimagine:
    ReimagineScreen(viewModel: reimagine, serverAvailable: connection.isConnected)
```

Use existing `PanelButton`, `FileImporter`, typography, and palette primitives. Keep every control visible but disable Start while offline/running.

- [ ] **Step 4: Verify GREEN**

Run focused `DeviceWindowTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MacOS/sources/Reimagine/ReimagineScreen.swift MacOS/sources/App/DeviceWindow.swift MacOS/sources/App/MicromixApp.swift MacOS/Tests/App/DeviceWindowTests.swift
git commit -m "feat(macos): add reimagine mode"
```

### Task 5: Source and alternate provenance

**Files:**
- Modify: `MacOS/sources/Core/Models.swift`
- Modify: `MacOS/sources/Core/JobReattacher.swift`
- Modify: `MacOS/sources/Library/LibraryScreen.swift`
- Test: `MacOS/Tests/Core/ProvenanceTests.swift`
- Test: `MacOS/Tests/Core/JobReattacherTests.swift`

**Interfaces:**
- `LibraryProvenance` represents operation, submitted parameters, named remote inputs, and ordered output assets.
- Library provenance identifies source and transformation while remaining safe for old records.

- [ ] **Step 1: Write failing source-link test**

```swift
@Test func importedRemixKeepsSourceAndParameters() async throws {
    let job = remoteSucceededJob(
        parameters: ["operation": .string("remix"), "variation_count": .number(2)],
        inputs: [remoteLink(name: "source", assetID: "source-1")],
        outputs: [remoteLink(name: "variation", assetID: "output-1")]
    )
    let item = try await recoverOne(job)
    #expect(item.provenance?.operation == "remix")
    #expect(item.provenance?.inputAssets.first?.name == "source")
}
```

- [ ] **Step 2: Verify RED**

Run: `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/ProvenanceTests/importedRemixKeepsSourceAndParameters`

Expected: FAIL because the typed input projection is missing.

- [ ] **Step 3: Project linked assets and show them**

```swift
let provenance = LibraryProvenance(
    jobID: job.id, operation: job.operation ?? job.kind,
    parameters: job.parameters, inputAssets: job.inputs, outputAsset: output.asset
)
```

Show `SOURCE`, `OPERATION`, and submitted seed/variation fields in the existing provenance pane. Do not synthesize a false local parent record.

- [ ] **Step 4: Verify GREEN**

Run focused `ProvenanceTests` and `JobReattacherTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MacOS/sources/Core/Models.swift MacOS/sources/Core/JobReattacher.swift MacOS/sources/Library/LibraryScreen.swift MacOS/Tests/Core/ProvenanceTests.swift MacOS/Tests/Core/JobReattacherTests.swift
git commit -m "feat(macos): show reimagine provenance"
```

### Task 6: Full verification, install, and manual acceptance

**Files:**
- Modify: `docs/superpowers/plans/2026-08-31-macos-reimagine.md`

- [ ] **Step 1: Run the complete suite**

Run: `cd MacOS && xcodegen generate && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'`

Expected: all suites PASS.

- [ ] **Step 2: Build the Debug app**

Run: `cd MacOS && xcodebuild build -project Micromix.xcodeproj -scheme Micromix -configuration Debug -destination 'platform=macOS'`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install recoverably and verify**

```bash
mv /Applications/Micromix.app /Applications/Micromix.app.previous
ditto <derived-data-debug-Micromix.app> /Applications/Micromix.app
codesign --verify --deep --strict /Applications/Micromix.app
```

Expected: signature verification exits zero and preserves the prior bundle.

- [ ] **Step 4: Manual acceptance**

Choose `REIMAGINE`, import a short local WAV, submit one reference variation, then inspect Library provenance. Repeat with Remix or a valid 3–90 second Repaint range. Confirm an in-flight job survives quitting/reopening, every variation imports separately, and source/operation/parameters display.

- [ ] **Step 5: Mark completed tasks and commit**

```bash
git add docs/superpowers/plans/2026-08-31-macos-reimagine.md
git commit -m "docs: record macos reimagine verification"
```

## Self-review

- Tasks 1–5 cover a cohesive studio layout plus reference, Remix/Cover, Repaint, seeds, variations, BPM/key/time signature, local-analysis prefill, durable recovery, all-output import, and source provenance.
- Phase 2 voice conversion, specialized MuScriptor outputs, and Logic-overlapping tools are intentionally separate future phases, as defined by the roadmap.
- Placeholder scan completed: no deferred implementation markers remain.

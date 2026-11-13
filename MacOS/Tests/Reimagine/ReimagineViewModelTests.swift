import Foundation
import Testing
@testable import Micromix

/// Existing flow fixtures explicitly supply the legacy catalog contract.
private extension ReimagineViewModel {
    @MainActor @discardableResult
    func start() -> Bool {
        start(capabilities: GenerationPreset.legacyPresets.first { $0.id == preset }!)
    }
}

@MainActor
private final class AcceptedReimagineAPI: DurableReimagineSubmitting, DurableJobCancelling, @unchecked Sendable {
    private(set) var submittedRequests: [ReimagineRequest] = []
    private(set) var uploadedData: Data?
    private(set) var uploadedFilename: String?
    private(set) var uploadedMediaType: String?
    private(set) var cancelledJobIDs: [String] = []

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        uploadedData = data
        uploadedFilename = filename
        uploadedMediaType = mediaType
        return RemoteAsset(
            id: "source-1",
            filename: filename,
            mediaType: mediaType,
            sizeBytes: data.count,
            sha256: String(repeating: "0", count: 64),
            downloadUrl: "/v1/assets/source-1"
        )
    }

    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob {
        submittedRequests.append(request)
        return try JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"job-1","kind":"generation","state":"queued","parameters":{"operation":"reference"},"progress":null,"error":null}"#.utf8)
        )
    }

    func cancel(jobID: String) async throws {
        cancelledJobIDs.append(jobID)
    }
}

@MainActor
private final class RecordingReattacher: ReimagineJobReattaching {
    private(set) var events: [String] = []

    func track(_ job: RemoteJob) throws {
        events.append("track:\(job.id)")
    }

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        events.append("recover:\(id)")
        return []
    }
}

@MainActor
private final class NeverCalledReimagineAPI: DurableReimagineSubmitting, DurableJobCancelling, @unchecked Sendable {
    private(set) var callCount = 0

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        callCount += 1
        Issue.record("upload must not be called for invalid input")
        throw CancellationError()
    }

    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob {
        callCount += 1
        Issue.record("submit must not be called for invalid input")
        throw CancellationError()
    }

    func cancel(jobID: String) async throws {
        callCount += 1
        Issue.record("cancel must not be called for invalid input")
    }
}

@MainActor
private final class SuspendedUploadReimagineAPI: DurableReimagineSubmitting, DurableJobCancelling, @unchecked Sendable {
    private(set) var uploadStarted = false
    var releaseUpload = false
    private(set) var submittedRequest: ReimagineRequest?

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        uploadStarted = true
        while !releaseUpload {
            try Task.checkCancellation()
            await Task.yield()
        }
        return RemoteAsset(
            id: "source-1",
            filename: filename,
            mediaType: mediaType,
            sizeBytes: data.count,
            sha256: String(repeating: "0", count: 64),
            downloadUrl: "/v1/assets/source-1"
        )
    }

    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob {
        submittedRequest = request
        return try JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"job-1","kind":"generation","state":"queued","parameters":{"operation":"reference"},"progress":null,"error":null}"#.utf8)
        )
    }

    func cancel(jobID: String) async throws {}
}

@MainActor
private final class SuspendedRecoveryReattacher: ReimagineJobReattaching {
    private(set) var events: [String] = []

    func track(_ job: RemoteJob) throws {
        events.append("track:\(job.id)")
    }

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        events.append("recover:\(id)")
        while true {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
private final class RestartRaceReimagineAPI: DurableReimagineSubmitting, DurableJobCancelling, @unchecked Sendable {
    private(set) var uploadCount = 0
    private(set) var cancelledJobIDs: [String] = []
    private(set) var staleSubmissionFinished = false
    var releaseFirstUpload = false

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        uploadCount += 1
        let uploadNumber = uploadCount
        if uploadNumber == 1 {
            while !releaseFirstUpload {
                await Task.yield()
            }
        }
        return RemoteAsset(
            id: "source-\(uploadNumber)",
            filename: filename,
            mediaType: mediaType,
            sizeBytes: data.count,
            sha256: String(repeating: "0", count: 64),
            downloadUrl: "/v1/assets/source-\(uploadNumber)"
        )
    }

    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob {
        let sourceAssetID: String
        switch request {
        case let .reference(_, _, _, _, _, _, _, _, _, _, id),
             let .remix(_, _, _, _, _, _, id),
             let .repaint(_, _, _, _, _, _, _, _, id):
            sourceAssetID = id
        }
        let jobID = sourceAssetID == "source-1" ? "job-1" : "job-2"
        if jobID == "job-1" {
            staleSubmissionFinished = true
        }
        return try JSONDecoder().decode(
            RemoteJob.self,
            from: Data(
                """
                {"id":"\(jobID)","kind":"generation","state":"queued","parameters":{"operation":"reference"},"progress":null,"error":null}
                """.utf8
            )
        )
    }

    func cancel(jobID: String) async throws {
        cancelledJobIDs.append(jobID)
    }
}

@MainActor
private final class RestartRaceReattacher: ReimagineJobReattaching {
    private(set) var secondRecoveryStarted = false
    private(set) var staleRecoveryFinished = false
    var releaseSecondRecovery = false

    func track(_ job: RemoteJob) throws {}

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        if id == "job-1" {
            staleRecoveryFinished = true
            throw URLError(.cancelled)
        }
        secondRecoveryStarted = true
        while !releaseSecondRecovery {
            await Task.yield()
        }
        return []
    }
}

@MainActor
private final class URLCancelledReattacher: ReimagineJobReattaching {
    func track(_ job: RemoteJob) throws {}

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        throw URLError(.cancelled)
    }
}

private final class SourceReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMainThread: Bool?

    var wasReadOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMainThread
    }

    func read(_ url: URL) throws -> Data {
        lock.lock()
        recordedMainThread = Thread.isMainThread
        lock.unlock()
        return Data("off-main-fixture".utf8)
    }
}

@MainActor
@Suite("ReimagineViewModel")
struct ReimagineViewModelTests {
    @Test("reimagine explains missing source, direction and connectivity")
    func disabledReasons() {
        let model = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
        let screen = ReimagineScreen(viewModel: model)
        #expect(!screen.canStart)
        #expect(screen.unavailableReason == "Select an audio source first")
        model.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        #expect(!screen.canStart)
        #expect(screen.unavailableReason == "Enter a prompt first")
        model.prompt = "  new chorus  "
        #expect(screen.canStart)
        let offline = ReimagineScreen(viewModel: model, localInferenceAvailable: false)
        #expect(!offline.canStart)
        #expect(offline.unavailableReason == "Local inference is unavailable. Start the local sidecar and retry.")
    }

    @Test("text-only engines and removed capabilities never upload Reimagine sources")
    func capabilityGates() {
        let api = NeverCalledReimagineAPI()
        let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
        model.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        model.prompt = "jazz"
        model.preset = "minimax-cover"
        model.bpmText = "120"
        for operation in [ReimagineOperation.reference, .remix, .repaint] {
            model.operation = operation
            #expect(!ReimagineScreen(viewModel: model).canStart)
            #expect(!model.start())
        }
        #expect(model.bpmText == "120")
        #expect(api.callCount == 0)
        model.preset = "turbo"
        model.operation = .reference
        let unavailable = ReimagineScreen(viewModel: model, generationCatalog: .loaded([]))
        #expect(!unavailable.canStart)
        #expect(unavailable.unavailableReason.contains("No generation engines"))
    }

    @Test("advanced settings indicate every non-default value")
    func advancedSettingsIndication() {
        let model = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
        #expect(!model.hasAdvancedSettings)
        model.seedText = "42"
        #expect(model.hasAdvancedSettings)
        model.seedText = ""
        model.bpmText = "120"
        #expect(model.hasAdvancedSettings)
        model.bpmText = ""
        model.key = "Am"
        #expect(model.hasAdvancedSettings)
        model.key = ""
        model.timeSignature = "4/4"
        #expect(model.hasAdvancedSettings)
        model.timeSignature = ""
        model.vocalLanguage = .english
        #expect(model.hasAdvancedSettings)
        model.vocalLanguage = .automatic
        #expect(!model.hasAdvancedSettings)
    }

    @Test("accepted jobs are tracked before recovery begins")
    func acceptedJobTracksBeforeRecovery() async throws {
        let api = AcceptedReimagineAPI()
        let reattacher = RecordingReattacher()
        let model = ReimagineViewModel(api: api, reattacher: reattacher)
        model.sourceURL = try fixtureAudioURL()
        model.prompt = "new chorus"

        #expect(model.start())
        try await eventually { reattacher.events.count == 2 }

        #expect(reattacher.events == ["track:job-1", "recover:job-1"])
    }

    @Test("invalid controls are rejected before upload")
    func invalidControlsAreRejectedLocally() throws {
        let cases: [(String, (ReimagineViewModel) -> Void, String)] = [
            ("seed below range", { $0.seedText = "-1" }, "SEED MUST BE 0–4,294,967,295"),
            ("seed above range", { $0.seedText = "4294967296" }, "SEED MUST BE 0–4,294,967,295"),
            ("seed nonnumeric", { $0.seedText = "seed" }, "SEED MUST BE 0–4,294,967,295"),
            ("duration below range", { $0.durationSeconds = 9 }, "DURATION MUST BE 10–600 SECONDS"),
            ("duration above range", { $0.durationSeconds = 601 }, "DURATION MUST BE 10–600 SECONDS"),
            ("duration is not finite", { $0.durationSeconds = .infinity }, "DURATION MUST BE 10–600 SECONDS"),
            ("BPM below range", { $0.bpmText = "29" }, "BPM MUST BE 30–300"),
            ("BPM above range", { $0.bpmText = "301" }, "BPM MUST BE 30–300"),
            ("BPM nonnumeric", { $0.bpmText = "fast" }, "BPM MUST BE 30–300"),
            ("variation count below range", { $0.variationCount = 0 }, "VARIATIONS MUST BE 1–4"),
            ("variation count above range", { $0.variationCount = 5 }, "VARIATIONS MUST BE 1–4"),
            ("repaint too short", {
                $0.operation = .repaint
                $0.startSeconds = 4
                $0.endSeconds = 6
            }, "REPAINT RANGE MUST BE 3–90 SECONDS"),
            ("repaint too long", {
                $0.operation = .repaint
                $0.startSeconds = 4
                $0.endSeconds = 95
            }, "REPAINT RANGE MUST BE 3–90 SECONDS"),
            ("repaint reversed", {
                $0.operation = .repaint
                $0.startSeconds = 8
                $0.endSeconds = 4
            }, "REPAINT RANGE MUST BE 3–90 SECONDS"),
            ("repaint start is not finite", {
                $0.operation = .repaint
                $0.startSeconds = .nan
                $0.endSeconds = 12
            }, "REPAINT RANGE MUST BE 3–90 SECONDS"),
            ("repaint end is not finite", {
                $0.operation = .repaint
                $0.startSeconds = 4
                $0.endSeconds = .infinity
            }, "REPAINT RANGE MUST BE 3–90 SECONDS"),
        ]

        for (name, configure, expectedMessage) in cases {
            let api = NeverCalledReimagineAPI()
            let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
            model.sourceURL = try fixtureAudioURL()
            model.prompt = "bridge"
            configure(model)

            #expect(model.start() == false, Comment(rawValue: name))
            #expect(model.errorMessage == expectedMessage, Comment(rawValue: name))
            #expect(api.callCount == 0, Comment(rawValue: name))
        }
    }

    @Test("repaint validates source bounds and refreshes duration on source changes")
    func repaintSourceBounds() throws {
        let api = NeverCalledReimagineAPI()
        let model = ReimagineViewModel(
            api: api, reattacher: RecordingReattacher(),
            durationReader: { $0.lastPathComponent == "known.wav" ? 10 : nil }
        )
        model.sourceURL = URL(fileURLWithPath: "/tmp/known.wav")
        model.operation = .repaint
        model.prompt = "bridge"
        #expect(model.sourceDurationSeconds == 10)

        model.startSeconds = -1
        model.endSeconds = 3
        #expect(!model.start())
        #expect(model.errorMessage == "REPAINT START MUST BE AT OR AFTER 0 SECONDS")
        model.startSeconds = 7
        model.endSeconds = 10.1
        #expect(!model.start())
        #expect(model.errorMessage == "REPAINT END EXCEEDS SOURCE DURATION")
        #expect(api.callCount == 0)

        model.sourceURL = URL(fileURLWithPath: "/tmp/unknown.wav")
        #expect(model.sourceDurationSeconds == nil)
        model.sourceURL = nil
        #expect(model.sourceDurationSeconds == nil)
    }

    @Test("repaint accepts zero start and exact source end")
    func repaintInclusiveSourceBounds() async throws {
        let api = AcceptedReimagineAPI()
        let model = ReimagineViewModel(
            api: api, reattacher: RecordingReattacher(), durationReader: { _ in 10 }
        )
        model.sourceURL = try fixtureAudioURL()
        model.operation = .repaint
        model.prompt = "bridge"
        model.startSeconds = 0
        model.endSeconds = 10
        #expect(model.start())
        try await eventually { api.submittedRequests.count == 1 }
    }

    @Test("missing source and blank prompt are rejected before upload")
    func missingRequiredInputsAreRejectedLocally() throws {
        let missingSourceAPI = NeverCalledReimagineAPI()
        let missingSource = ReimagineViewModel(
            api: missingSourceAPI,
            reattacher: RecordingReattacher()
        )
        missingSource.prompt = "bridge"
        #expect(missingSource.start() == false)
        #expect(missingSource.errorMessage == "SELECT AN AUDIO FILE")
        #expect(missingSourceAPI.callCount == 0)

        let blankPromptAPI = NeverCalledReimagineAPI()
        let blankPrompt = ReimagineViewModel(
            api: blankPromptAPI,
            reattacher: RecordingReattacher()
        )
        blankPrompt.sourceURL = try fixtureAudioURL()
        blankPrompt.prompt = " \n\t "
        #expect(blankPrompt.start() == false)
        #expect(blankPrompt.errorMessage == "ENTER A PROMPT")
        #expect(blankPromptAPI.callCount == 0)
    }

    @Test("inclusive control boundaries are accepted")
    func inclusiveControlBoundariesAreAccepted() async throws {
        let sourceURL = try fixtureAudioURL()

        let referenceAPI = AcceptedReimagineAPI()
        let reference = ReimagineViewModel(
            api: referenceAPI,
            reattacher: RecordingReattacher()
        )
        reference.sourceURL = sourceURL
        reference.prompt = "lower boundaries"
        reference.seedText = "0"
        reference.variationCount = 1
        reference.durationSeconds = 10
        reference.bpmText = "30"

        #expect(reference.start())
        try await eventually { referenceAPI.submittedRequests.count == 1 }

        let repaintAPI = AcceptedReimagineAPI()
        let repaint = ReimagineViewModel(
            api: repaintAPI,
            reattacher: RecordingReattacher()
        )
        repaint.sourceURL = sourceURL
        repaint.operation = .repaint
        repaint.prompt = "upper repaint boundary"
        repaint.startSeconds = 5
        repaint.endSeconds = 95

        #expect(repaint.start())
        try await eventually { repaintAPI.submittedRequests.count == 1 }
    }

    @Test("each operation submits only its permitted typed controls")
    func operationsBuildTypedRequests() async throws {
        let sourceURL = try fixtureAudioURL()

        do {
            let api = AcceptedReimagineAPI()
            let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
            model.sourceURL = sourceURL
            model.prompt = "warm piano"
            model.lyrics = "hold the light"
            model.useLyrics = true
            model.preset = "quality"
            model.seedText = "4294967295"
            model.variationCount = 4
            model.durationSeconds = 600
            model.bpmText = "300"
            model.key = "C minor"
            model.timeSignature = "4"

            #expect(model.start())
            try await eventually { api.submittedRequests.count == 1 }

            guard case let .reference(
                prompt, lyrics, preset, seed, variationCount, durationSeconds,
                bpm, key, timeSignature, vocalLanguage, sourceAssetID
            ) = api.submittedRequests[0] else {
                Issue.record("expected a reference request")
                return
            }
            #expect(prompt == "warm piano")
            #expect(lyrics == "hold the light")
            #expect(preset == "quality")
            #expect(seed == 4_294_967_295)
            #expect(variationCount == 4)
            #expect(durationSeconds == 600)
            #expect(bpm == 300)
            #expect(key == "C minor")
            #expect(timeSignature == "4")
            #expect(vocalLanguage == .automatic)
            #expect(sourceAssetID == "source-1")
            #expect(api.uploadedData == Data("fixture-audio".utf8))
            #expect(api.uploadedFilename == sourceURL.lastPathComponent)
            #expect(api.uploadedMediaType == "audio/wav")
        }

        do {
            let api = AcceptedReimagineAPI()
            let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
            model.sourceURL = sourceURL
            model.operation = .remix
            model.prompt = "heavier drums"
            model.durationSeconds = 0
            model.bpmText = "invalid for remix"
            model.sourceStrength = 0.75

            #expect(model.start())
            try await eventually { api.submittedRequests.count == 1 }

            guard case let .remix(
                prompt, lyrics, preset, seed, variationCount, sourceStrength, sourceAssetID
            ) = api.submittedRequests[0] else {
                Issue.record("expected a remix request")
                return
            }
            #expect(prompt == "heavier drums")
            #expect(lyrics == nil)
            #expect(preset == "turbo")
            #expect(seed == nil)
            #expect(variationCount == 2)
            #expect(sourceStrength == 0.75)
            #expect(sourceAssetID == "source-1")
        }

        do {
            let api = AcceptedReimagineAPI()
            let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
            model.sourceURL = sourceURL
            model.operation = .repaint
            model.prompt = "replace bridge"
            model.startSeconds = 12
            model.endSeconds = 15
            model.repaintStrength = 0.6

            #expect(model.start())
            try await eventually { api.submittedRequests.count == 1 }

            guard case let .repaint(
                prompt, lyrics, preset, seed, variationCount, startSeconds,
                endSeconds, repaintStrength, sourceAssetID
            ) = api.submittedRequests[0] else {
                Issue.record("expected a repaint request")
                return
            }
            #expect(prompt == "replace bridge")
            #expect(lyrics == nil)
            #expect(preset == "turbo")
            #expect(seed == nil)
            #expect(variationCount == 2)
            #expect(startSeconds == 12)
            #expect(endSeconds == 15)
            #expect(repaintStrength == 0.6)
            #expect(sourceAssetID == "source-1")
        }
    }

    @Test("analysis prefills only untouched BPM and key controls")
    func prefillPreservesManualEdits() {
        let analysis = LocalMusicAnalysis(
            durationSeconds: 42,
            beatsPerMinute: 123.6,
            key: "D major",
            instruments: ["drums"]
        )

        let untouched = ReimagineViewModel(
            api: NeverCalledReimagineAPI(),
            reattacher: RecordingReattacher()
        )
        untouched.prefill(from: analysis)
        #expect(untouched.bpmText == "124")
        #expect(untouched.key == "D major")

        let edited = ReimagineViewModel(
            api: NeverCalledReimagineAPI(),
            reattacher: RecordingReattacher()
        )
        edited.bpmText = "90"
        edited.key = "F minor"
        edited.prefill(from: analysis)
        #expect(edited.bpmText == "90")
        #expect(edited.key == "F minor")

        let bpmOnlyEdited = ReimagineViewModel(
            api: NeverCalledReimagineAPI(),
            reattacher: RecordingReattacher()
        )
        bpmOnlyEdited.bpmText = "110"
        bpmOnlyEdited.prefill(from: analysis)
        #expect(bpmOnlyEdited.bpmText == "110")
        #expect(bpmOnlyEdited.key == "D major")

        let nilMetadata = LocalMusicAnalysis(
            durationSeconds: 42,
            beatsPerMinute: nil,
            key: nil,
            instruments: []
        )
        untouched.prefill(from: nilMetadata)
        #expect(untouched.bpmText == "124")
        #expect(untouched.key == "D major")
    }

    @Test("derived metadata refreshes untouched meter and language and ignores missing values")
    func derivedMetadataRefreshesUntouchedFields() {
        let model = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        func accept(_ metadata: DerivedMetadata) {
            model.acceptSource(AssetActionContext(sourceURL: source, action: .referenceGenerate, derivedMetadata: metadata))
        }

        accept(DerivedMetadata(timeSignature: "3", detectedLanguage: .english))
        #expect(model.timeSignature == "3")
        #expect(model.vocalLanguage == .english)
        accept(DerivedMetadata(timeSignature: "4", detectedLanguage: .vietnamese))
        #expect(model.timeSignature == "4")
        #expect(model.vocalLanguage == .vietnamese)
        accept(.empty)
        #expect(model.timeSignature == "4")
        #expect(model.vocalLanguage == .vietnamese)
    }

    @Test("derived metadata preserves independent explicit meter and language edits")
    func derivedMetadataPreservesManualEdits() {
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        let metadata = DerivedMetadata(timeSignature: "3", detectedLanguage: .english)
        func accept(_ model: ReimagineViewModel) {
            model.acceptSource(AssetActionContext(sourceURL: source, action: .referenceGenerate, derivedMetadata: metadata))
        }

        let meterEdited = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
        meterEdited.timeSignature = ""
        accept(meterEdited)
        #expect(meterEdited.timeSignature == "")
        #expect(meterEdited.vocalLanguage == .english)

        let languageEdited = ReimagineViewModel(api: NeverCalledReimagineAPI(), reattacher: RecordingReattacher())
        languageEdited.vocalLanguage = .automatic
        accept(languageEdited)
        #expect(languageEdited.timeSignature == "3")
        #expect(languageEdited.vocalLanguage == .automatic)

        languageEdited.timeSignature = "5"
        languageEdited.vocalLanguage = .vietnamese
        accept(languageEdited)
        #expect(languageEdited.timeSignature == "5")
        #expect(languageEdited.vocalLanguage == .vietnamese)
    }

    @Test("start captures immutable request state before asynchronous upload")
    func startCapturesRequestBeforeAsyncWork() async throws {
        let api = SuspendedUploadReimagineAPI()
        let model = ReimagineViewModel(api: api, reattacher: RecordingReattacher())
        model.sourceURL = try fixtureAudioURL()
        model.operation = .reference
        model.prompt = "original direction"
        model.durationSeconds = 45

        #expect(model.start())
        try await eventually { api.uploadStarted }

        model.operation = .repaint
        model.prompt = "mutated direction"
        model.startSeconds = 12
        model.endSeconds = 18
        api.releaseUpload = true
        try await eventually { api.submittedRequest != nil }

        guard case let .reference(prompt, _, _, _, _, durationSeconds, _, _, _, _, _)
            = api.submittedRequest else {
            Issue.record("expected the reference request captured by start()")
            return
        }
        #expect(prompt == "original direction")
        #expect(durationSeconds == 45)
    }

    @Test("cancel propagates to an accepted durable job")
    func cancelAcceptedJob() async throws {
        let api = AcceptedReimagineAPI()
        let reattacher = SuspendedRecoveryReattacher()
        let model = ReimagineViewModel(api: api, reattacher: reattacher)
        model.sourceURL = try fixtureAudioURL()
        model.prompt = "new chorus"

        #expect(model.start())
        try await eventually { reattacher.events == ["track:job-1", "recover:job-1"] }

        model.cancel()
        try await eventually { api.cancelledJobIDs == ["job-1"] }

        #expect(model.phase == .cancelled)
    }

    @Test("a cancelled run cannot overwrite an immediately restarted run")
    func cancelledRunCannotOverwriteRestart() async throws {
        let api = RestartRaceReimagineAPI()
        let reattacher = RestartRaceReattacher()
        let model = ReimagineViewModel(api: api, reattacher: reattacher)
        model.sourceURL = try fixtureAudioURL()
        model.prompt = "first run"

        #expect(model.start())
        try await eventually { api.uploadCount == 1 }
        model.cancel()

        model.prompt = "second run"
        #expect(model.start())
        try await eventually { reattacher.secondRecoveryStarted }

        api.releaseFirstUpload = true
        try await eventually { api.staleSubmissionFinished }
        let phaseAfterStaleCompletion = model.phase

        model.cancel()
        try await eventually { api.cancelledJobIDs.contains("job-2") }
        reattacher.releaseSecondRecovery = true

        #expect(phaseAfterStaleCompletion == .running)
        #expect(api.cancelledJobIDs.contains("job-2"))
    }

    @Test("URLSession cancellation is published as cancellation")
    func urlSessionCancellationIsNotAnError() async throws {
        let model = ReimagineViewModel(
            api: AcceptedReimagineAPI(),
            reattacher: URLCancelledReattacher()
        )
        model.sourceURL = try fixtureAudioURL()
        model.prompt = "new chorus"

        #expect(model.start())
        try await eventually { !model.isRunning }

        #expect(model.phase == .cancelled)
        #expect(model.errorMessage == nil)
    }

    @Test("source file reading runs outside the main actor")
    func sourceFileReadingIsOffMainActor() async throws {
        let api = AcceptedReimagineAPI()
        let probe = SourceReadProbe()
        let model = ReimagineViewModel(
            api: api,
            reattacher: RecordingReattacher(),
            sourceReader: probe.read
        )
        model.sourceURL = try fixtureAudioURL()
        model.prompt = "new chorus"

        #expect(model.start())
        try await eventually { api.submittedRequests.count == 1 }

        #expect(probe.wasReadOnMainThread == false)
    }

    @Test("Analyze preserves its source URL for a Reimagine handoff")
    func analyzePreservesSourceURL() throws {
        let sourceURL = try fixtureAudioURL()
        let analyze = AnalyzeViewModel()

        analyze.analyze(url: sourceURL)

        #expect(analyze.sourceURL == sourceURL)
    }

    private func fixtureAudioURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reimagine-\(UUID().uuidString).wav")
        try Data("fixture-audio".utf8).write(to: url)
        return url
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("condition was not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

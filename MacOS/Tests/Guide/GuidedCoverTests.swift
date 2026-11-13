import Foundation
import Testing
@testable import Micromix

@MainActor
private final class CoverAPI: DurableSourceProcessing {
    var uploads = 0
    var submitted: [String] = []
    var cancelled: [String] = []
    var responses: [RemoteJob] = []
    var holdSecondSubmit: CheckedContinuation<RemoteJob, Never>?
    var suspendSecondSubmit = false

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        uploads += 1
        return RemoteAsset(id: "upload-1", filename: filename, mediaType: mediaType,
                           sizeBytes: data.count, sha256: "source-sha", downloadUrl: "/v1/assets/upload-1")
    }

    func submitSourceProcessing(_ request: SourceProcessingRequest) async throws -> RemoteJob {
        switch request {
        case .vocalSwap(let source, let voice, let pitch):
            submitted.append("vocal-swap \(source) \(voice) \(pitch)")
        case .stemSplit(let source, let description):
            submitted.append("stem-split \(source) \(description)")
        }
        if suspendSecondSubmit && submitted.count == 2 {
            return await withCheckedContinuation { holdSecondSubmit = $0 }
        }
        return responses[submitted.count - 1]
    }

    func cancel(jobID: String) async throws { cancelled.append(jobID) }
}

@MainActor
private final class CoverRecovery: ReimagineJobReattaching {
    var tracked = 0
    var waiting = false
    var suspend = false
    var queue: [[LibraryItem]] = []
    var recovered: [String] = []

    func track(_ job: RemoteJob) throws { tracked += 1 }

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        recovered.append(id)
        if suspend {
            waiting = true
            try await Task.sleep(for: .seconds(60))
        }
        guard !queue.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return queue.removeFirst()
    }
}

@MainActor
@Suite("Guided cover flow")
struct GuidedCoverTests {
    @Test("a cover runs split then swap with the vocal stem's registered asset")
    func chainsSplitIntoSwap() async throws {
        let api = CoverAPI()
        api.responses = [job(id: "job-a", kind: "stem_split"), job(id: "job-b", kind: "vocal-swap")]
        let recovery = CoverRecovery()
        recovery.queue = [
            [outputItem(name: "target", remoteID: "as-target", jobID: "job-a"),
             outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")],
            [outputItem(name: "vocals", remoteID: "as-cover", jobID: "job-b", title: "vocal-swap.wav")],
        ]
        let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        model.pitchShift = 3

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted == ["stem-split upload-1 vocals", "vocal-swap as-target base 3"])
        #expect(recovery.tracked == 2)
        #expect(api.uploads == 1)
        #expect(model.results.map(\.title) == ["vocal-swap.wav"])
        #expect(model.accompaniment?.remoteOutputAssetID == "as-residual")
        #expect(model.state(of: .prepare) == .done)
        #expect(model.state(of: .splitVocals) == .done)
        #expect(model.state(of: .swapVoice) == .done)
        #expect(model.errorMessage == nil)
    }

    @Test("a split without accompaniment still returns the converted vocal")
    func completesWithoutAccompaniment() async {
        let api = CoverAPI()
        api.responses = [job(id: "split", kind: "stem_split"), job(id: "swap", kind: "vocal-swap")]
        let recovery = CoverRecovery()
        recovery.queue = [
            [outputItem(name: "target", remoteID: "vocal", jobID: "split")],
            [outputItem(name: "vocals", remoteID: "converted", jobID: "swap")],
        ]
        let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }
        #expect(model.results.first?.remoteOutputAssetID == "converted")
        #expect(model.accompaniment == nil)
        #expect(model.state(of: .swapVoice) == .done)
    }

    @Test("missing source or voice rejects the start without submitting")
    func validatesInputs() {
        let api = CoverAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = CoverRecovery()
        let model = GuidedCoverModel(api: api, reattacher: recovery)

        #expect(!model.start())
        #expect(model.errorMessage == "SELECT AN AUDIO FILE")
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        #expect(!model.start())
        #expect(model.errorMessage == "SELECT A VOICE MODEL")
        #expect(api.submitted.isEmpty)
        #expect(!model.isRunning)
    }

    @Test("a split without a vocal stem fails before the swap")
    func failsWithoutVocalStem() async {
        let api = CoverAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = CoverRecovery()
        recovery.queue = [[outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")]]
        let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted.count == 1)
        #expect(model.state(of: .prepare) == .done)
        #expect(model.state(of: .splitVocals) == .failed("Stem split did not return a vocal stem"))
        #expect(model.state(of: .swapVoice) == .pending)
        #expect(model.errorMessage == "Stem split did not return a vocal stem")
    }

    @Test("cancelling mid-recovery forwards cancellation to the accepted job")
    func cancelsAcceptedJob() async {
        let api = CoverAPI()
        api.responses = [job(id: "job-a", kind: "stem_split"), job(id: "job-b", kind: "vocal-swap")]
        let recovery = CoverRecovery()
        recovery.suspend = true
        recovery.queue = [[outputItem(name: "target", remoteID: "as-target", jobID: "job-a")]]
        let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"

        #expect(model.start())
        for _ in 0..<1000 where !recovery.waiting { await Task.yield() }
        model.cancel()
        for _ in 0..<1000 where api.cancelled.isEmpty { await Task.yield() }

        #expect(api.cancelled == ["job-a"])
        #expect(model.state(of: .splitVocals) == .cancelled)
        #expect(model.state(of: .swapVoice) == .pending)
        #expect(!model.isRunning)
        #expect(model.results.isEmpty)
    }

    @Test("cancelling the second submit never cancels the completed split")
    func cancelsSecondSubmit() async {
        let api = CoverAPI()
        api.responses = [job(id: "split", kind: "stem_split"), job(id: "swap", kind: "vocal-swap")]
        api.suspendSecondSubmit = true
        let recovery = CoverRecovery()
        recovery.queue = [[outputItem(name: "target", remoteID: "vocal", jobID: "split")], []]
        let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        #expect(model.start())
        for _ in 0..<10_000 where api.holdSecondSubmit == nil { await Task.yield() }
        guard let continuation = api.holdSecondSubmit else { Issue.record("swap submit did not start"); model.cancel(); return }
        model.cancel()
        continuation.resume(returning: api.responses[1])
        for _ in 0..<10_000 where api.cancelled.isEmpty || recovery.recovered.count < 2 { await Task.yield() }
        #expect(api.cancelled == ["swap"])
        #expect(recovery.recovered == ["split", "swap"])
        #expect(model.state(of: .splitVocals) == .done)
        #expect(model.state(of: .swapVoice) == .cancelled)
    }

    // MARK: - Builders

    private func job(id: String, kind: String) -> RemoteJob {
        try! JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"\#(id)","kind":"\#(kind)","state":"queued"}"#.utf8)
        )
    }

    private func outputItem(name: String, remoteID: String, jobID: String, title: String? = nil) -> LibraryItem {
        let asset = RemoteAsset(
            id: remoteID, filename: title ?? "\(name).wav", mediaType: "audio/wav",
            sizeBytes: 10, sha256: "sha-\(remoteID)", downloadUrl: "/v1/assets/\(remoteID)"
        )
        return LibraryItem(
            id: UUID(), kind: .audio, title: title ?? "\(name).wav", createdAt: .now,
            promptOrSource: "song.wav", durationSeconds: nil, relativePath: "audio/\(remoteID).wav",
            provenance: LibraryProvenance(
                jobID: jobID, operation: "stem_split", parameters: [:],
                inputs: [], output: RemoteAssetLink(name: name, position: 0, asset: asset)
            ),
            remoteOutputAssetID: remoteID
        )
    }
}

/// Holds each submission independently, including after its caller is cancelled.
@MainActor
private final class DelayedGuideAPI: DurableSourceProcessing, DurableTranscriptionSubmitting, DurableJobCancelling, DurableJobServicing {
    var submissions: [CheckedContinuation<RemoteJob, Never>] = []
    var cancelled: [String] = []
    var submitWasCancelled: [Bool] = []
    var failCancellation = false

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        RemoteAsset(id: "upload", filename: filename, mediaType: mediaType,
                    sizeBytes: data.count, sha256: "sha", downloadUrl: "/upload")
    }

    func submitSourceProcessing(_ request: SourceProcessingRequest) async throws -> RemoteJob {
        await hold()
    }

    func submitTranscription(audio: Data, filename: String, instruments: [String], detectTempo: Bool) async throws -> RemoteJob {
        await hold()
    }

    private func hold() async -> RemoteJob {
        let job = await withCheckedContinuation { submissions.append($0) }
        submitWasCancelled.append(Task.isCancelled)
        return job
    }

    func accept(_ index: Int, id: String) {
        let job = try! JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"\#(id)","kind":"stem_split","state":"queued"}"#.utf8))
        submissions[index].resume(returning: job)
    }

    func cancel(jobID: String) async throws {
        cancelled.append(jobID)
        if failCancellation { throw MicromixAPIError.unreachable() }
    }
    func job(id: String) async throws -> RemoteJob { throw MicromixAPIError.unreachable() }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

@MainActor
private final class DelayedGuideRecovery: ReimagineJobReattaching {
    var tracked: [String] = []
    var recovering: [String] = []
    var background: [String] = []
    func track(_ job: RemoteJob) throws { tracked.append(job.id) }
    func trackForBackground(_ job: RemoteJob) throws {
        tracked.append(job.id)
        background.append(job.id)
    }
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        recovering.append(id)
        try await Task.sleep(for: .seconds(60))
        return []
    }
}

@MainActor
@Suite("Guided in-flight cancellation")
struct GuidedSubmitCancellationTests {
    enum Flow: CaseIterable { case cover, remix, transcribe, vocalSwap }

    @Test("late acceptance exposes persistence failure and retries without losing cancellation")
    func lateAcceptancePersistenceFailure() async throws {
        let api = DelayedGuideAPI()
        api.failCancellation = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(directory: directory)
        var fail = true
        let recovery = JobReattacher(api: api, library: library, persistJob: { id in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try library.trackPendingJob(id: id)
        })
        let model = GuidedTranscribeModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        #expect(model.start())
        for _ in 0..<10_000 where api.submissions.isEmpty { await Task.yield() }
        guard !api.submissions.isEmpty else { Issue.record("submit did not start"); model.cancel(); return }
        model.cancel()
        api.accept(0, id: "late")
        for _ in 0..<10_000 where api.cancelled.isEmpty { await Task.yield() }
        #expect(api.cancelled == ["late"])
        #expect(!library.pendingJobIDs.contains("late"))
        guard case .unavailable(let message) = recovery.entries.first?.state else {
            Issue.record("missing persistence failure entry"); return
        }
        #expect(message.contains("not saved"))
        #expect(message.contains("Retry"))
        await recovery.cancelRecovery(id: "late")
        #expect(api.cancelled == ["late", "late"])
        guard case .unavailable(let cancelMessage) = recovery.entries.first?.state else {
            Issue.record("missing cancellation failure entry"); return
        }
        #expect(cancelMessage.contains("Cancellation failed"))
        #expect(cancelMessage.contains("not saved"))
        recovery.retryRecovery(id: "late")
        #expect(!library.pendingJobIDs.contains("late"))
        fail = false
        recovery.retryRecovery(id: "late")
        #expect(library.pendingJobIDs.contains("late"))
    }

    @Test("late acceptance is tracked and cancelled without replacing the restarted job", arguments: Flow.allCases)
    func lateAcceptanceAfterRestart(flow: Flow) async {
        let api = DelayedGuideAPI()
        let recovery = DelayedGuideRecovery()
        let start: () -> Bool
        let cancel: () -> Void
        let running: () -> Bool
        let cancelledStage: () -> Bool
        switch flow {
        case .cover:
            let model = GuidedCoverModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
            model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
            model.voiceModel = "base"
            start = { model.start() }; cancel = { model.cancel() }; running = { model.isRunning }
            cancelledStage = { model.state(of: .splitVocals) == .cancelled }
        case .remix:
            let model = GuidedRemixModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
            model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
            model.splitFirst = true
            start = { model.start() }; cancel = { model.cancel() }; running = { model.isRunning }
            cancelledStage = { model.state(of: .splitVocals) == .cancelled }
        case .transcribe:
            let model = GuidedTranscribeModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
            model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
            start = { model.start() }; cancel = { model.cancel() }; running = { model.isRunning }
            cancelledStage = { model.state(of: .transcribe) == .cancelled }
        case .vocalSwap:
            let model = GuidedVocalSwapModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
            model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
            model.voiceModel = "base"
            model.splitFirst = false
            start = { model.start() }; cancel = { model.cancel() }; running = { model.isRunning }
            cancelledStage = { model.state(of: .swapVoice) == .cancelled }
        }
        #expect(start())
        for _ in 0..<10_000 where api.submissions.count < 1 { await Task.yield() }
        guard api.submissions.count == 1 else { Issue.record("first submit did not start"); cancel(); return }
        cancel()
        #expect(cancelledStage())
        #expect(start())
        for _ in 0..<10_000 where api.submissions.count < 2 { await Task.yield() }
        guard api.submissions.count == 2 else {
            Issue.record("second submit did not start"); api.accept(0, id: "old"); cancel(); return
        }
        api.accept(1, id: "new")
        for _ in 0..<10_000 where recovery.recovering.isEmpty { await Task.yield() }
        #expect(recovery.recovering == ["new"])
        api.accept(0, id: "old")
        for _ in 0..<10_000 where !api.cancelled.contains("old") { await Task.yield() }
        #expect(running())
        cancel()
        for _ in 0..<10_000 where !api.cancelled.contains("new") { await Task.yield() }
        #expect(Set(api.cancelled) == Set(["old", "new"]))
        #expect(api.cancelled.count == 2)
        #expect(Set(recovery.tracked) == Set(["old", "new"]))
        #expect(recovery.background == ["old"])
        #expect(api.submitWasCancelled == [false, false])
        #expect(cancelledStage())
        #expect(!running())
    }
}
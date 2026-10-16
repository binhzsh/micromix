import Foundation
import Testing
@testable import Micromix

@MainActor
private final class SwapAPI: DurableSourceProcessing {
    var uploads = 0
    var submitted: [String] = []
    var cancelled: [String] = []
    var responses: [RemoteJob] = []

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
        return responses[submitted.count - 1]
    }

    func cancel(jobID: String) async throws { cancelled.append(jobID) }
}

@MainActor
private final class SwapRecovery: ReimagineJobReattaching {
    var tracked = 0
    var waiting = false
    var suspend = false
    var queue: [[LibraryItem]] = []

    func track(_ job: RemoteJob) throws { tracked += 1 }

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        if suspend {
            waiting = true
            try await Task.sleep(for: .seconds(60))
        }
        return queue.removeFirst()
    }
}

@MainActor
@Suite("Guided vocal swap flow")
struct GuidedVocalSwapTests {
    @Test("split-first runs split then swap with the vocal stem's registered asset")
    func chainsSplitIntoSwap() async throws {
        let api = SwapAPI()
        api.responses = [job(id: "job-a", kind: "stem_split"), job(id: "job-b", kind: "vocal-swap")]
        let recovery = SwapRecovery()
        recovery.queue = [
            [outputItem(name: "target", remoteID: "as-target", jobID: "job-a"),
             outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")],
            [outputItem(name: "vocals", remoteID: "as-swap", jobID: "job-b", title: "vocal-swap.wav")],
        ]
        let model = GuidedVocalSwapModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        model.pitchShift = 3
        model.splitFirst = true

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted == ["stem-split upload-1 vocals", "vocal-swap as-target base 3"])
        #expect(recovery.tracked == 2)
        #expect(api.uploads == 1)
        #expect(model.results.map(\.title) == ["vocal-swap.wav"])
        #expect(model.state(of: .prepare) == .done)
        #expect(model.state(of: .splitVocals) == .done)
        #expect(model.state(of: .swapVoice) == .done)
        #expect(model.errorMessage == nil)
    }

    @Test("direct swap skips the split and swaps the source asset as-is")
    func directSwapSkipsSplit() async throws {
        let api = SwapAPI()
        api.responses = [job(id: "job-b", kind: "vocal-swap")]
        let recovery = SwapRecovery()
        recovery.queue = [
            [outputItem(name: "vocals", remoteID: "as-swap", jobID: "job-b", title: "vocal-swap.wav")],
        ]
        let model = GuidedVocalSwapModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        model.splitFirst = false

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted == ["vocal-swap upload-1 base 0"])
        #expect(recovery.tracked == 1)
        #expect(api.uploads == 1)
        #expect(model.results.map(\.title) == ["vocal-swap.wav"])
        #expect(model.state(of: .prepare) == .done)
        #expect(model.state(of: .splitVocals) == .skipped)
        #expect(model.state(of: .swapVoice) == .done)
        #expect(model.errorMessage == nil)
    }

    @Test("missing source or voice rejects the start without submitting")
    func validatesInputs() {
        let api = SwapAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = SwapRecovery()
        let model = GuidedVocalSwapModel(api: api, reattacher: recovery)

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
        let api = SwapAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = SwapRecovery()
        recovery.queue = [[outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")]]
        let model = GuidedVocalSwapModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        model.splitFirst = true

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
        let api = SwapAPI()
        api.responses = [job(id: "job-a", kind: "stem_split"), job(id: "job-b", kind: "vocal-swap")]
        let recovery = SwapRecovery()
        recovery.suspend = true
        recovery.queue = [[outputItem(name: "target", remoteID: "as-target", jobID: "job-a")]]
        let model = GuidedVocalSwapModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.voiceModel = "base"
        model.splitFirst = true

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

import Foundation
import Testing
@testable import Micromix

@MainActor
private final class ProcessingAPI: DurableSourceProcessing {
    var submitted = false
    var cancelled: [String] = []
    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        RemoteAsset(id: "source", filename: filename, mediaType: mediaType, sizeBytes: data.count, sha256: "", downloadUrl: "")
    }
    func submitSourceProcessing(_ request: SourceProcessingRequest) async throws -> RemoteJob {
        submitted = true
        return try JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"job","kind":"stem_split","state":"queued"}"#.utf8))
    }
    func cancel(jobID: String) async throws { cancelled.append(jobID) }
}

@MainActor
private final class ProcessingRecovery: ReimagineJobReattaching {
    var tracked = false
    var waiting = false
    var suspend = false
    func track(_ job: RemoteJob) throws { tracked = true }
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        #expect(tracked)
        waiting = true
        if suspend { try await Task.sleep(for: .seconds(60)) }
        return ["target", "residual"].map {
            LibraryItem(id: UUID(), kind: .audio, title: $0, createdAt: Date(), promptOrSource: "source", durationSeconds: nil, relativePath: "audio/\($0).wav")
        }
    }
}

@MainActor
@Suite("Source processing workflows")
struct SourceProcessingViewModelTests {
    @Test("voice catalog only reports an empty library after a successful response")
    func voiceCatalogFailureStates() {
        let offline = VoiceCatalogState.unavailable
        let loading = VoiceCatalogState.loading
        let failed = VoiceCatalogState.failed
        let empty = VoiceCatalogState.loaded([])
        #expect(offline.message?.contains("unavailable") == true)
        #expect(loading.message?.contains("Loading") == true)
        #expect(failed.message?.contains("Could not load") == true)
        for state in [offline, loading, failed] {
            #expect(state.message?.contains("No local voice models found") == false)
            #expect(state.voices.isEmpty)
        }
        #expect(empty.message?.contains("No local voice models found") == true)
        #expect(VoiceCatalogState.loaded(["voice"]).message == nil)
        #expect(VoiceCatalogState.loaded(["voice"]).voices == ["voice"])
    }

    @Test("missing source, voice and description do not submit")
    func validation() {
        let api = ProcessingAPI()
        let recovery = ProcessingRecovery()
        let voice = SourceProcessingViewModel(operation: .vocalSwap, api: api, reattacher: recovery)
        #expect(!voice.start())
        voice.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        #expect(!voice.start())
        #expect(voice.errorMessage == "SELECT A VOICE MODEL")
        let split = SourceProcessingViewModel(operation: .stemSplit, api: api, reattacher: recovery)
        split.sourceURL = voice.sourceURL
        split.description = "  "
        #expect(!split.start())
        #expect(!api.submitted)
    }

    @Test("stem split tracks before recovery and retains both output results")
    func allResults() async throws {
        let api = ProcessingAPI()
        let recovery = ProcessingRecovery()
        let model = SourceProcessingViewModel(operation: .stemSplit, api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        model.description = "vocals"
        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }
        #expect(model.phase == .done)
        #expect(model.results.map(\.title) == ["target", "residual"])
    }

    @Test("cancel accepted job sends cancellation and prevents stale result")
    func cancellation() async {
        let api = ProcessingAPI()
        let recovery = ProcessingRecovery()
        recovery.suspend = true
        let model = SourceProcessingViewModel(operation: .vocalSwap, api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        model.voiceModel = "voice"
        #expect(model.start())
        for _ in 0..<1000 where !recovery.waiting { await Task.yield() }
        #expect(recovery.waiting)
        model.cancel()
        for _ in 0..<1000 where api.cancelled.isEmpty { await Task.yield() }
        #expect(api.cancelled == ["job"])
        #expect(model.phase == .cancelled)
        #expect(model.results.isEmpty)
    }
}

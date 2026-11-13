import Foundation
import Testing
@testable import Micromix

@MainActor
private final class NoopReimagineAPI: DurableReimagineSubmitting, DurableJobCancelling, @unchecked Sendable {
    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        RemoteAsset(id: "src", filename: filename, mediaType: mediaType, sizeBytes: data.count, sha256: String(repeating: "0", count: 64), downloadUrl: "/v1/assets/src")
    }

    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob {
        try JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"job-1","kind":"generation","state":"queued","parameters":{"operation":"reference"},"progress":null,"error":null}"#.utf8)
        )
    }

    func cancel(jobID: String) async throws {}
}

@MainActor
private final class NoopReattacher: ReimagineJobReattaching {
    func track(_ job: RemoteJob) throws {}
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] { [] }
}

private struct NoopSourceProcessingAPI: DurableSourceProcessing {
    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        RemoteAsset(id: "src", filename: filename, mediaType: mediaType, sizeBytes: data.count, sha256: String(repeating: "0", count: 64), downloadUrl: "/v1/assets/src")
    }

    func submitSourceProcessing(_ request: SourceProcessingRequest) async throws -> RemoteJob {
        try JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"job-1","kind":"stem_split","state":"queued"}"#.utf8)
        )
    }

    func cancel(jobID: String) async throws {}
}

@MainActor
private final class HandoffReceiver: AssetAccepting {
    var canAcceptSource = true
    var received: AssetActionContext?
    func acceptSource(_ context: AssetActionContext) { received = context }
}

@Suite("WorkflowRouter chaining")
@MainActor
struct WorkflowRouterTests {
    private func makeRouter() -> (WorkflowRouter, GenerateViewModel, ReimagineViewModel) {
        let generate = GenerateViewModel(api: FakeGenerateAPI(), library: FakeGenerateLibrary())
        let reimagine = ReimagineViewModel(api: NoopReimagineAPI(), reattacher: NoopReattacher())
        let router = WorkflowRouter(library: LocalLibrary(directory: nil), generate: generate, reimagine: reimagine)
        return (router, generate, reimagine)
    }

    @Test("lyrics handoff preserves independent musical direction and language")
    func lyricsHandoff() {
        let (router, generate, _) = makeRouter()
        generate.prompt = "dream pop"
        generate.vocalLanguage = .vietnamese
        var switched: DeviceMode?
        router.onSwitchMode = { switched = $0 }
        if case .failure = router.useGenerateLyrics("corrected\nwords") { Issue.record("Handoff failed") }
        #expect(generate.lyrics == "corrected\nwords")
        #expect(generate.useLyrics)
        #expect(generate.prompt == "dream pop")
        #expect(generate.vocalLanguage == .vietnamese)
        #expect(switched == .generate)
        switched = nil
        #expect(generate.start(capabilities: GenerationPreset.legacyPresets[0]))
        if case .success = router.useGenerateLyrics("must not replace") { Issue.record("Busy handoff must be rejected") }
        #expect(generate.lyrics == "corrected\nwords")
        #expect(generate.prompt == "dream pop")
        #expect(generate.vocalLanguage == .vietnamese)
        #expect(switched == nil)
        #expect(router.handoffError?.message.contains("busy") == true)
        generate.cancel()
    }

    @Test("lyrics cannot route to audio or MIDI workflows")
    func lyricsHaveNoActions() {
        let (router, _, _) = makeRouter()
        let item = LibraryItem(id: UUID(), kind: .lyrics, title: "Lyrics", createdAt: .now, promptOrSource: "song", durationSeconds: nil, relativePath: "lyrics/song.txt")
        var switched = false
        router.onSwitchMode = { _ in switched = true }
        #expect(router.availableActions(for: item).isEmpty)
        #expect(!LibraryCollection.audio.includes(item))
        #expect(!LibraryCollection.midi.includes(item))
        router.execute(.transcribe, on: item)
        #expect(!switched)
    }

    @Test("reimagineReference switches mode, sets reference operation, and prefills metadata")
    func reimagineReferenceRoutesAndPrefills() throws {
        let (router, _, reimagine) = makeRouter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        router.reimagineReference(
            url: url,
            derived: DerivedMetadata(beatsPerMinute: 124, key: "A minor")
        )
        #expect(reimagine.operation == .reference)
        #expect(reimagine.sourceURL == url)
        #expect(reimagine.bpmText == "124")
        #expect(reimagine.key == "A minor")
    }

    @Test("prefillGenerate fills only empty direction fields")
    func prefillGenerateRespectsEdits() {
        let (router, generate, _) = makeRouter()
        generate.key = "C"
        router.prefillGenerate(with: DerivedMetadata(beatsPerMinute: 92, key: "F minor"))
        #expect(generate.bpmText == "92")
        #expect(generate.key == "C")
    }

    @Test("Reimagine acceptSource switches operation and prefills derived metadata")
    func reimagineAcceptSourceSetsOperationAndMetadata() {
        let (_, _, reimagine) = makeRouter()
        reimagine.acceptSource(AssetActionContext(
            sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
            action: .remix,
            derivedMetadata: DerivedMetadata(timeSignature: "4")
        ))
        #expect(reimagine.operation == .remix)
        #expect(reimagine.timeSignature == "4")
    }

    @Test("busy and missing source handoffs preserve the receiver and do not navigate")
    func rejectedHandoffs() throws {
        let (router, _, _) = makeRouter()
        let receiver = HandoffReceiver()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = AssetActionContext(sourceURL: url, action: .remix)
        let previous = AssetActionContext(sourceURL: URL(fileURLWithPath: "/previous.wav"), action: .remix)
        receiver.acceptSource(previous)
        var switches = 0
        router.onSwitchMode = { _ in switches += 1 }

        receiver.canAcceptSource = false
        let busy = router.handoff(context, to: receiver, mode: .reimagine)
        if case .failure(let error) = busy { #expect(error.message.contains("busy")) }
        else { Issue.record("Busy handoff must be rejected") }
        #expect(router.handoffError?.message.contains("busy") == true)
        #expect(receiver.received?.sourceURL == previous.sourceURL && switches == 0)

        receiver.canAcceptSource = true
        let missing = router.handoff(context, to: receiver, mode: .reimagine)
        if case .failure(let error) = missing { #expect(error.message.contains("missing or unreadable")) }
        else { Issue.record("Missing source handoff must be rejected") }
        #expect(router.handoffError?.message.contains("missing or unreadable") == true)
        #expect(receiver.received?.sourceURL == previous.sourceURL && switches == 0)

        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let accepted = router.handoff(context, to: receiver, mode: .reimagine)
        if case .failure = accepted { Issue.record("Readable source handoff must be accepted") }
        #expect(receiver.received?.sourceURL == url && switches == 1)
        #expect(router.handoffError == nil)
    }

    @Test("stem-split and vocal-swap actions deliver the source to SourceProcessing flows")
    func routesSourceProcessingActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(directory: directory)
        let vocalSwap = SourceProcessingViewModel(operation: .vocalSwap, api: NoopSourceProcessingAPI(), reattacher: NoopReattacher())
        let stemSplit = SourceProcessingViewModel(operation: .stemSplit, api: NoopSourceProcessingAPI(), reattacher: NoopReattacher())
        let router = WorkflowRouter(library: library, vocalSwap: vocalSwap, stemSplit: stemSplit)
        var switched: [DeviceMode] = []
        router.onSwitchMode = { switched.append($0) }

        let item = LibraryItem(
            id: UUID(), kind: .audio, title: "song", createdAt: Date(),
            promptOrSource: "song", durationSeconds: nil, relativePath: "audio/song.wav"
        )
        let source = library.resolvedURL(for: item)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)
        router.execute(.stemSplit, on: item)
        router.execute(.vocalSwap, on: item)

        #expect(switched == [.stemSplit, .vocalSwap])
        let resolved = library.resolvedURL(for: item)
        #expect(stemSplit.sourceURL == resolved)
        #expect(vocalSwap.sourceURL == resolved)
    }
}

// MARK: - Minimal fakes (Generate side)

@MainActor
private final class FakeGenerateAPI: GenerateServicing, @unchecked Sendable {
    func generate(input: String, lyrics: String?, preset: String, durationSeconds: Double, options: GenerationOptions) async throws -> Data {
        Data("fake-audio".utf8)
    }
}

@MainActor
private final class FakeGenerateLibrary: LibraryStoring, @unchecked Sendable {
    func add(_ item: LibraryItem, bytes: Data) throws {}
}

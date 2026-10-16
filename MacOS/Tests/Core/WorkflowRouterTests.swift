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

@Suite("WorkflowRouter chaining")
@MainActor
struct WorkflowRouterTests {
    private func makeRouter() -> (WorkflowRouter, GenerateViewModel, ReimagineViewModel) {
        let generate = GenerateViewModel(api: FakeGenerateAPI(), library: FakeGenerateLibrary())
        let reimagine = ReimagineViewModel(api: NoopReimagineAPI(), reattacher: NoopReattacher())
        let router = WorkflowRouter(library: LocalLibrary(directory: nil), generate: generate, reimagine: reimagine)
        return (router, generate, reimagine)
    }

    @Test("reimagineReference switches mode, sets reference operation, and prefills metadata")
    func reimagineReferenceRoutesAndPrefills() {
        let (router, _, reimagine) = makeRouter()
        router.reimagineReference(
            url: URL(fileURLWithPath: "/tmp/loop.wav"),
            derived: DerivedMetadata(beatsPerMinute: 124, key: "A minor")
        )
        #expect(reimagine.operation == .reference)
        #expect(reimagine.sourceURL == URL(fileURLWithPath: "/tmp/loop.wav"))
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

import Foundation
import Testing
@testable import Micromix

@Suite("Library provenance")
struct ProvenanceTests {
    @Test("job alternatives stay grouped and ordered by output position")
    func groupsAlternativesByDurableJob() {
        let first = item(id: UUID(), jobID: "job-a", position: 1)
        let second = item(id: UUID(), jobID: "job-a", position: 0)
        let unrelated = item(id: UUID(), jobID: "job-b", position: 0)

        #expect([first, second, unrelated].alternatives(for: first) == [second, first])
        #expect([first, second, unrelated].alternatives(for: unrelated) == [unrelated])
    }

    @Test("alternative navigation follows render order and stops at the ends")
    func navigatesAlternativesWithinDurableJob() {
        let first = item(id: UUID(), jobID: "job-a", position: 0)
        let second = item(id: UUID(), jobID: "job-a", position: 1)
        let third = item(id: UUID(), jobID: "job-a", position: 2)
        let unrelated = item(id: UUID(), jobID: "job-b", position: 0)
        let items = [third, unrelated, first, second]

        #expect(items.nextAlternative(after: first) == second)
        #expect(items.previousAlternative(before: third) == second)
        #expect(items.previousAlternative(before: first) == nil)
        #expect(items.nextAlternative(after: third) == nil)
        #expect(items.nextAlternative(after: unrelated) == nil)
    }

    @Test("copy text includes reproducible job, input, output, and parameters")
    func copyTextIncludesReproductionDetails() {
        let asset = RemoteAsset(
            id: "asset-1",
            filename: "source.wav",
            mediaType: "audio/wav",
            sizeBytes: 12,
            sha256: "abc",
            downloadUrl: "/v1/assets/asset-1"
        )
        let provenance = LibraryProvenance(
            jobID: "job-12345678",
            operation: "generation",
            parameters: ["duration_seconds": .number(30), "preset": .string("turbo")],
            inputs: [RemoteAssetLink(name: "prompt-audio", position: 0, asset: asset)],
            output: RemoteAssetLink(name: "result", position: 1, asset: asset)
        )

        let text = provenance.copyText

        #expect(text.contains("Operation: generation"))
        #expect(text.contains("Job: job-12345678"))
        #expect(text.contains("Output: #2 result — source.wav"))
        #expect(text.contains("#1 prompt-audio — source.wav"))
        #expect(text.contains("duration_seconds: 30"))
        #expect(text.contains("preset: turbo"))
    }

    @Test("smart collections group generated, transformed, processing, and MIDI assets")
    func classifiesWorkspaceCollections() {
        let generated = item(id: UUID(), jobID: "job-generate", position: 0, operation: "generation")
        let remixed = item(id: UUID(), jobID: "job-remix", position: 0, operation: "remix")
        let vocal = item(id: UUID(), jobID: "job-vocal", position: 0, operation: "vocal_swap")
        let midi = LibraryItem(
            id: UUID(), kind: .midi, title: "score.mid", createdAt: .now,
            promptOrSource: "song.wav", durationSeconds: nil, relativePath: "midi/score.mid"
        )

        #expect(LibraryCollection.generated.includes(generated))
        #expect(LibraryCollection.transforms.includes(remixed))
        #expect(LibraryCollection.stemsAndVocals.includes(vocal))
        #expect(LibraryCollection.midi.includes(midi))
        #expect(!LibraryCollection.transforms.includes(midi))
    }

    private func item(id: UUID, jobID: String, position: Int, operation: String = "generation") -> LibraryItem {
        let asset = RemoteAsset(
            id: "asset-\(id.uuidString)", filename: "result.wav", mediaType: "audio/wav",
            sizeBytes: 12, sha256: "abc", downloadUrl: "/v1/assets/asset"
        )
        return LibraryItem(
            id: id, kind: .audio, title: "result.wav", createdAt: .now,
            promptOrSource: "test", durationSeconds: nil, relativePath: "audio/result.wav",
            provenance: LibraryProvenance(
                jobID: jobID, operation: operation, parameters: [:], inputs: [],
                output: RemoteAssetLink(name: "result", position: position, asset: asset)
            )
        )
    }
}

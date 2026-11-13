import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Library detail presentation")
struct LibraryDetailTests {
    @Test("unselected and filtered states explain how to see detail")
    func guidance() {
        #expect(LibraryScreen.emptyDetailGuidance(hasItems: false, hasMatches: false).contains("Save"))
        #expect(LibraryScreen.emptyDetailGuidance(hasItems: true, hasMatches: false).contains("filters"))
        #expect(LibraryScreen.emptyDetailGuidance(hasItems: true, hasMatches: true).contains("Select"))
    }

    @Test("missing and invalid metadata is not presented as known")
    func unknownMetadata() {
        let item = makeItem(provenance: nil, duration: .nan)
        let details = Dictionary(uniqueKeysWithValues: LibraryScreen.identityDetails(for: item).map { ($0.label, $0.value) })
        #expect(details["Role"] == "Unavailable")
        #expect(details["Source / prompt"] == "Unavailable")
        #expect(details["Job"] == "Unavailable")
        #expect(details["Duration"] == "Unavailable")
        #expect(details["Date"] != nil)
    }

    @Test("stem outputs are labeled as stems and remain navigable siblings")
    func stemRelationships() {
        let asset = RemoteAsset(id: "a", filename: "vocals.wav", mediaType: "audio/wav", sizeBytes: 1, sha256: "hash", downloadUrl: "")
        let output = RemoteAssetLink(name: "vocals", position: 0, asset: asset)
        let provenance = LibraryProvenance(jobID: "job", operation: "stem_split", parameters: [:], inputs: [], output: output)
        let first = makeItem(provenance: provenance, duration: 65)
        let second = makeItem(provenance: provenance, duration: nil)
        #expect(LibraryScreen.siblingLabel(for: first) == "STEM")
        #expect(RelatedAssetsResolver.related(for: first, in: [first, second]).siblings == [second])
        #expect(LibraryScreen.alternatives(for: first, in: [first, second]) == [first])
        let details = Dictionary(uniqueKeysWithValues: LibraryScreen.identityDetails(for: first).map { ($0.label, $0.value) })
        #expect(details["Role"] == "vocals")
        #expect(details["Job"] == "job")
        #expect(details["Duration"] == "1:05")
        #expect(LibraryScreen.siblingLabel(for: makeItem(provenance: nil, duration: nil)) == "SIBLING")
    }

    private func makeItem(provenance: LibraryProvenance?, duration: Double?) -> LibraryItem {
        LibraryItem(id: UUID(), kind: .audio, title: "Asset", createdAt: .now,
                    promptOrSource: "", durationSeconds: duration, relativePath: "audio/a.wav", provenance: provenance)
    }
}

import Foundation
import Testing
@testable import Micromix

@Suite("Related asset lineage")
struct RelatedAssetsTests {
    @Test("a chained upload matches its parent by output checksum")
    func linksParentByChecksum() {
        let parent = item(title: "song.wav", checksum: "parent-sha", jobID: "job-1")
        let child = item(
            title: "remix.wav",
            checksum: "child-sha",
            jobID: "job-2",
            inputs: [link(id: "fresh-upload-id", checksum: "parent-sha")]
        )
        #expect(RelatedAssetsResolver.related(for: child, in: [parent, child]).parents == [parent])
    }

    @Test("a reused remote asset id matches its parent without a checksum")
    func linksParentByRemoteAssetID() {
        let parent = item(title: "song.wav", checksum: "parent-sha", jobID: "job-1", remoteID: "asset-1")
        let child = item(
            title: "repaint.wav",
            checksum: "child-sha",
            jobID: "job-2",
            inputs: [link(id: "asset-1", checksum: "")]
        )
        #expect(RelatedAssetsResolver.related(for: child, in: [parent, child]).parents == [parent])
    }

    @Test("unrelated uploads produce no lineage in either direction")
    func ignoresUnrelatedAssets() {
        let parent = item(title: "song.wav", checksum: "parent-sha", jobID: "job-1")
        let other = item(
            title: "cover.wav",
            checksum: "child-sha",
            jobID: "job-2",
            inputs: [link(id: "fresh-upload-id", checksum: "different-sha")]
        )
        let related = RelatedAssetsResolver.related(for: other, in: [parent, other])
        #expect(related.parents.isEmpty)
        #expect(RelatedAssetsResolver.related(for: parent, in: [parent, other]).children.isEmpty)
    }

    @Test("children are items whose inputs match this item's output checksum")
    func findsChildrenByOutputChecksum() {
        let parent = item(title: "song.wav", checksum: "parent-sha", jobID: "job-1")
        let firstChild = item(
            title: "stem.wav", checksum: "stem-sha", jobID: "job-2",
            inputs: [link(id: "u1", checksum: "parent-sha")],
            createdAt: Date(timeIntervalSinceNow: -50)
        )
        let secondChild = item(
            title: "midi.mid", checksum: "", jobID: "job-3",
            inputs: [link(id: "u2", checksum: "parent-sha")],
            createdAt: Date(timeIntervalSinceNow: -10)
        )
        let children = RelatedAssetsResolver.related(for: parent, in: [parent, secondChild, firstChild]).children
        #expect(children.map(\.title) == ["midi.mid", "stem.wav"])
    }

    @Test("siblings share the job, exclude self, and stay in output order")
    func groupsSiblingsByJob() {
        let first = item(title: "target.wav", checksum: "s1", jobID: "job-9", position: 0)
        let second = item(title: "residual.wav", checksum: "s2", jobID: "job-9", position: 1)
        let unrelated = item(title: "other.wav", checksum: "s3", jobID: "job-10")

        let related = RelatedAssetsResolver.related(for: second, in: [second, unrelated, first])
        #expect(related.siblings == [first])
        #expect(related.parents.isEmpty)
        #expect(related.children.isEmpty)
    }

    @Test("legacy items without provenance stay unlinked")
    func leavesLegacyItemsUnlinked() {
        let legacy = LibraryItem(
            id: UUID(), kind: .audio, title: "legacy.wav", createdAt: .now,
            promptOrSource: "old", durationSeconds: nil, relativePath: "audio/legacy.wav"
        )
        let child = item(
            title: "remix.wav", checksum: "child-sha", jobID: "job-2",
            inputs: [link(id: "u", checksum: "")]
        )
        let related = RelatedAssetsResolver.related(for: child, in: [legacy, child])
        #expect(related.isEmpty)
        #expect(RelatedAssetsResolver.related(for: legacy, in: [legacy]).isEmpty)
    }

    @Test("duplicate inputs pointing at one parent are deduplicated")
    func deduplicatesRepeatedParents() {
        let parent = item(title: "song.wav", checksum: "parent-sha", jobID: "job-1")
        let child = item(
            title: "mashup.wav", checksum: "child-sha", jobID: "job-2",
            inputs: [
                link(id: "u1", checksum: "parent-sha"),
                link(id: "u2", checksum: "parent-sha"),
            ]
        )
        #expect(RelatedAssetsResolver.related(for: child, in: [parent, child]).parents == [parent])
    }

    @Test("local lyrics corrections link in both directions without provenance")
    func linksLocalCorrections() {
        let original = lyrics(title: "Original (Library ID: title)", source: "legacy")
        let correction = lyrics(title: "Correction", source: "Corrected from \(original.title) (Library ID: \(original.id.uuidString))")
        let items = [original, correction]
        #expect(RelatedAssetsResolver.related(for: correction, in: items).parents == [original])
        #expect(RelatedAssetsResolver.related(for: original, in: items).children == [correction])
    }

    @Test("invalid, missing, legacy and non-lyrics sources do not create local links")
    func ignoresInvalidCorrectionSources() {
        let original = lyrics(title: "Original", source: "legacy")
        let id = original.id.uuidString
        let sources = [
            "Corrected from Original (Library ID: not-a-uuid)",
            "Corrected from Original (Library ID: \(UUID().uuidString))",
            "Corrected from Original (Library ID: \(id)) trailing",
            "Old correction (Library ID: \(id))",
            "Corrected from Original (Library ID: \(id.lowercased()))",
            "legacy"
        ]
        let invalid = sources.map { lyrics(title: "Other", source: $0) }
        let audio = LibraryItem(id: UUID(), kind: .audio, title: "Audio", createdAt: .now,
                                promptOrSource: "Corrected from Original (Library ID: \(id))",
                                durationSeconds: nil, relativePath: "audio/test")
        let items = [original, audio] + invalid
        #expect(RelatedAssetsResolver.related(for: original, in: items).children.isEmpty)
        for item in invalid + [audio] {
            #expect(RelatedAssetsResolver.related(for: item, in: items).parents.isEmpty)
        }
        let audioSource = lyrics(title: "Correction", source: "Corrected from Audio (Library ID: \(audio.id.uuidString))")
        #expect(RelatedAssetsResolver.related(for: audioSource, in: [audio, audioSource]).isEmpty)
    }

    @Test("local correction and remote provenance links coexist")
    func preservesProvenanceLinks() {
        let remoteParent = item(title: "source", checksum: "sha", jobID: "parent")
        let original = lyrics(title: "Original", source: "legacy")
        let remoteChild = item(title: "correction", checksum: "other", jobID: "child",
                               inputs: [link(id: "upload", checksum: "sha")])
        let correction = LibraryItem(
            id: remoteChild.id, kind: .lyrics, title: remoteChild.title, createdAt: remoteChild.createdAt,
            promptOrSource: "Corrected from Original (Library ID: \(original.id.uuidString))",
            durationSeconds: nil, relativePath: "lyrics/test.txt", provenance: remoteChild.provenance,
            remoteOutputAssetID: remoteChild.remoteOutputAssetID
        )
        let parents = RelatedAssetsResolver.related(for: correction, in: [original, remoteParent, correction]).parents
        #expect(Set(parents.map(\.id)) == Set([original.id, remoteParent.id]))
    }

    private func lyrics(title: String, source: String) -> LibraryItem {
        LibraryItem(id: UUID(), kind: .lyrics, title: title, createdAt: .now,
                    promptOrSource: source, durationSeconds: nil, relativePath: "lyrics/test.txt")
    }

    // MARK: - Builders

    private func link(id: String, checksum: String) -> RemoteAssetLink {
        RemoteAssetLink(
            name: "source",
            position: 0,
            asset: RemoteAsset(
                id: id, filename: "upload.wav", mediaType: "audio/wav",
                sizeBytes: 10, sha256: checksum, downloadUrl: "/v1/assets/\(id)"
            )
        )
    }

    private func item(
        title: String,
        checksum: String,
        jobID: String,
        position: Int = 0,
        remoteID: String? = nil,
        inputs: [RemoteAssetLink] = [],
        createdAt: Date = .now
    ) -> LibraryItem {
        let outputAsset = RemoteAsset(
            id: "out-\(jobID)-\(position)", filename: title, mediaType: "audio/wav",
            sizeBytes: 42, sha256: checksum, downloadUrl: "/v1/assets/out"
        )
        return LibraryItem(
            id: UUID(), kind: .audio, title: title, createdAt: createdAt,
            promptOrSource: "test", durationSeconds: nil, relativePath: "audio/\(title)",
            provenance: LibraryProvenance(
                jobID: jobID, operation: "remix", parameters: [:], inputs: inputs,
                output: RemoteAssetLink(name: "result", position: position, asset: outputAsset)
            ),
            remoteOutputAssetID: remoteID ?? "out-\(jobID)-\(position)"
        )
    }
}
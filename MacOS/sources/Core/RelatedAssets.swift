import Foundation

/// Lineage for one library item: the assets it was created from, the other
/// outputs of its own job, and the assets later created from it.
struct RelatedAssets: Equatable, Sendable {
    var parents: [LibraryItem] = []
    var siblings: [LibraryItem] = []
    var children: [LibraryItem] = []

    var isEmpty: Bool {
        parents.isEmpty && siblings.isEmpty && children.isEmpty
    }
}

/// Resolves asset lineage from durable provenance alone, so the Library can
/// show a Source → Operation → Output trail without extra storage.
enum RelatedAssetsResolver {
    static func related(for item: LibraryItem, in items: [LibraryItem]) -> RelatedAssets {
        guard let provenance = item.provenance else { return RelatedAssets() }
        let others = items.filter { $0.id != item.id }

        var parents: [LibraryItem] = []
        for link in provenance.inputs {
            for candidate in others
            where isOutput(of: candidate, remoteAssetID: link.asset.id, checksum: link.asset.sha256) {
                if !parents.contains(where: { $0.id == candidate.id }) {
                    parents.append(candidate)
                }
            }
        }

        let siblings = others
            .filter { $0.provenance?.jobID == provenance.jobID }
            .sorted { ($0.provenance?.output.position ?? 0) < ($1.provenance?.output.position ?? 0) }

        let remoteOutputID = item.remoteOutputAssetID
        let outputChecksum = provenance.output.asset.sha256
        let children = others.filter { candidate in
            candidate.provenance?.inputs.contains { link in
                remoteOutputID == link.asset.id
                    || (!outputChecksum.isEmpty && link.asset.sha256 == outputChecksum)
            } == true
        }

        return RelatedAssets(
            parents: parents.sorted { $0.createdAt > $1.createdAt },
            siblings: siblings,
            children: children.sorted { $0.createdAt > $1.createdAt }
        )
    }

    /// Whether the candidate's saved output is the asset identified by a remote
    /// id or checksum. Re-uploaded sources always receive a fresh remote id on
    /// the sidecar, so checksum equality is the dependable signal; both sides
    /// must be non-empty because legacy fallback provenance stores "".
    private static func isOutput(of candidate: LibraryItem, remoteAssetID: String, checksum: String) -> Bool {
        candidate.remoteOutputAssetID == remoteAssetID
            || (!checksum.isEmpty && candidate.provenance.map { provenance in
                let outputChecksum = provenance.output.asset.sha256
                return !outputChecksum.isEmpty && outputChecksum == checksum
            } == true)
    }
}
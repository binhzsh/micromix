import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Bundle export")
struct BundleExportTests {
    private static let suiteDirectory: URL = {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("micromix-export-tests-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let directory = temporaryDirectory
            .appendingPathComponent("micromix-export-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private func withLibrary(
        _ body: (LocalLibrary) throws -> Void
    ) throws {
        try autoreleasepool {
            try body(LocalLibrary(directory: Self.suiteDirectory.appendingPathComponent(UUID().uuidString)))
        }
    }

    @Test("bundle copies job siblings and writes a provenance manifest")
    func copiesSiblingsWithManifest() throws {
        try withLibrary { lib in
            let parent = item(
                title: "source-song", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "jobid-source-77", operation: "generate", outputName: "result"
            )
            let target = item(
                title: "lead-vocal", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "jobid-split-01", operation: "stem_split", outputName: "target"
            )
            let residual = item(
                title: "backing", relativePath: "midi/\(UUID().uuidString).mid",
                jobID: "jobid-split-01", operation: "stem_split", outputName: "residual"
            )
            let unrelated = item(
                title: "elsewhere", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "jobid-other-99", operation: "generate", outputName: "result"
            )
            for entry in [parent, target, residual, unrelated] {
                try lib.add(entry, bytes: Data([0x52, 0x49, 0x46, 0x46]))
            }

            let folder = try lib.exportBundle(for: target)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            #expect(names.count == 3)
            #expect(names.contains { $0.hasSuffix(".wav") })
            #expect(names.contains { $0.hasSuffix(".mid") })
            #expect(names.contains("manifest.txt"))
            #expect(folder.lastPathComponent.contains("split-01"))

            let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.txt"), encoding: .utf8)
            #expect(manifest.contains("JOB split-01"))
            #expect(manifest.contains("OPERATION stem_split"))
            #expect(manifest.contains("01-target"))
            #expect(manifest.contains("02-residual"))
            #expect(!manifest.contains("elsewhere"))
            #expect(!names.contains { $0.contains("elsewhere") })
        }
    }

    @Test("re-exporting the same asset creates a fresh numbered folder")
    func reExportNumbered() throws {
        try withLibrary { lib in
            let entry = item(
                title: "cover", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "job-one", operation: "vocal_swap", outputName: "result"
            )
            try lib.add(entry, bytes: Data([0x01]))

            let first = try lib.exportBundle(for: entry)
            let second = try lib.exportBundle(for: entry)
            #expect(first != second)
            #expect(FileManager.default.fileExists(atPath: second.path))
        }
    }

    @Test("missing source file fails with a visible error")
    func missingFileFails() throws {
        try withLibrary { lib in
            let missing = item(
                title: "ghost", relativePath: "audio/never-written.wav",
                jobID: "job-missing", operation: "generate", outputName: "result"
            )
            #expect(throws: BundleExportError.self) {
                try lib.exportBundle(for: missing)
            }
        }
    }

    private func item(
        title: String, relativePath: String, jobID: String, operation: String, outputName: String
    ) -> LibraryItem {
        let asset = RemoteAsset(
            id: "as-\(outputName)-\(jobID)", filename: title, mediaType: "audio/wav",
            sizeBytes: 10, sha256: "sha-\(jobID)-\(outputName)", downloadUrl: "/v1/assets/x"
        )
        return LibraryItem(
            id: UUID(), kind: relativePath.hasSuffix(".mid") ? .midi : .audio,
            title: title, createdAt: .now, promptOrSource: "bundle test",
            durationSeconds: nil, relativePath: relativePath,
            provenance: LibraryProvenance(
                jobID: jobID, operation: operation, parameters: [:],
                inputs: [], output: RemoteAssetLink(name: outputName, position: 0, asset: asset)
            ),
            remoteOutputAssetID: asset.id
        )
    }
}

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
            #expect(names.count == 4)
            #expect(names.contains { $0.hasSuffix(".wav") })
            #expect(names.contains { $0.hasSuffix(".mid") })
            #expect(names.contains("manifest.txt"))
            #expect(folder.lastPathComponent.contains("split-01"))

            let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.txt"), encoding: .utf8)
            #expect(manifest.contains("JOB jobid-split-01"))
            #expect(manifest.contains("OPERATION stem_split"))
            #expect(manifest.contains("01-target"))
            #expect(manifest.contains("02-residual"))
            #expect(!manifest.contains("elsewhere"))
            #expect(!names.contains { $0.contains("elsewhere") })
        }
    }

    @Test("bundle includes parent sources alongside siblings and children")
    func copiesParentsWithBundle() throws {
        try withLibrary { lib in
            let parent = item(
                title: "source-song", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "jobid-source-77", operation: "generate", outputName: "result"
            )
            let target = item(
                title: "lead-vocal", relativePath: "audio/\(UUID().uuidString).wav",
                jobID: "jobid-split-01", operation: "stem_split", outputName: "target",
                inputs: [
                    RemoteAssetLink(
                        name: "source", position: 0,
                        asset: RemoteAsset(
                            id: parent.remoteOutputAssetID ?? "", filename: parent.title,
                            mediaType: "audio/wav", sizeBytes: 10,
                            sha256: "sha-jobid-source-77-result", downloadUrl: "/v1/assets/x"
                        )
                    )
                ]
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
            #expect(names.count == 5)
            #expect(names.contains { $0.contains("source-song") })

            let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.txt"), encoding: .utf8)
            #expect(manifest.contains("01-target"))
            #expect(manifest.contains("02-residual"))
            #expect(manifest.contains("03-result-source-song"))
            let jsonData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let json = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
            let records = try #require(json["entries"] as? [[String: Any]])
            let inputs = try #require(records.first?["inputs"] as? [[String: Any]])
            #expect(inputs.first?["status"] as? String == "bundled")
            #expect(inputs.first?["bundledLibraryItemID"] as? String == parent.id.uuidString)
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

    @Test("missing related files fail with an actionable error")
    func missingRelatedFileFails() throws {
        try withLibrary { lib in
            let target = item(title: "target", relativePath: "audio/target.wav", jobID: "shared", operation: "split", outputName: "target")
            let sibling = item(title: "missing sibling", relativePath: "audio/missing.wav", jobID: "shared", operation: "split", outputName: "other")
            try lib.add(target, bytes: Data([1]))
            try lib.add(sibling, bytes: Data([2]))
            try FileManager.default.removeItem(at: lib.resolvedURL(for: sibling))
            do {
                _ = try lib.exportBundle(for: target)
                Issue.record("Export should fail when a related file is missing")
            } catch {
                #expect(error.localizedDescription.contains("missing sibling"))
                #expect(error.localizedDescription.contains("Restore"))
            }
        }
    }

    @Test("manifest preserves structured provenance and flags unavailable inputs")
    func fullProvenanceAndUnavailableInput() throws {
        try withLibrary { lib in
            let source = RemoteAssetLink(name: "source", position: 2, asset: RemoteAsset(
                id: "original-id", filename: "original.wav", mediaType: "audio/wav",
                sizeBytes: 42, sha256: "original-hash", downloadUrl: "/source"
            ))
            let entry = item(title: "result", relativePath: "audio/result.wav", jobID: "full-job-id", operation: "remix", outputName: "mix", inputs: [source], parameters: ["nested": .object(["seed": .number(123)])])
            try lib.add(entry, bytes: Data([1]))
            let folder = try lib.exportBundle(for: entry)
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let records = try #require(json["entries"] as? [[String: Any]])
            let savedItem = try #require(records.first?["item"] as? [String: Any])
            let provenance = try #require(savedItem["provenance"] as? [String: Any])
            #expect(provenance["jobID"] as? String == "full-job-id")
            #expect(provenance["operation"] as? String == "remix")
            let parameters = try #require(provenance["parameters"] as? [String: Any])
            let nested = try #require(parameters["nested"] as? [String: Any])
            #expect(nested["seed"] as? Int == 123)
            let output = try #require(provenance["output"] as? [String: Any])
            let outputAsset = try #require(output["asset"] as? [String: Any])
            #expect(outputAsset["sha256"] as? String == "sha-full-job-id-mix")
            let inputs = try #require(records.first?["inputs"] as? [[String: Any]])
            #expect(inputs.first?["status"] as? String == "not_in_bundle")
            let text = try String(contentsOf: folder.appendingPathComponent("manifest.txt"), encoding: .utf8)
            #expect(text.contains("original.wav"))
            #expect(text.contains("does not guarantee complete reproduction"))
        }
    }

    private func item(
        title: String, relativePath: String, jobID: String, operation: String, outputName: String,
        inputs: [RemoteAssetLink] = [], parameters: [String: JSONValue] = [:]
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
                jobID: jobID, operation: operation, parameters: parameters,
                inputs: inputs, output: RemoteAssetLink(name: outputName, position: 0, asset: asset)
            ),
            remoteOutputAssetID: asset.id
        )
    }
}

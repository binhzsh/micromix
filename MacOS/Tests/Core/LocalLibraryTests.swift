import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("LocalLibrary persistence")
struct LocalLibraryTests {
    private static let suiteDirectory: URL = {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("micromix-library-tests-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let directory = temporaryDirectory
            .appendingPathComponent("micromix-library-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private func withLibrary(
        _ body: (LocalLibrary, URL) throws -> Void
    ) throws {
        let dir = Self.suiteDirectory.appendingPathComponent(UUID().uuidString)
        try autoreleasepool {
            try body(LocalLibrary(directory: dir), dir)
        }
    }

    @Test("add writes file and commits SwiftData metadata")
    func addOrdering() throws {
        try withLibrary { lib, dir in
            let item = LibraryItem(
                id: UUID(),
                kind: .audio,
                title: "Sunset",
                createdAt: Date(),
                promptOrSource: "lo-fi sunset beat",
                durationSeconds: 3.5,
                relativePath: "audio/\(UUID().uuidString).wav"
            )
            try lib.add(item, bytes: Data([0x52, 0x49, 0x46, 0x46]))

            #expect(FileManager.default.fileExists(atPath: lib.resolvedURL(for: item).path))
            #expect(lib.items.count == 1)

            let reloaded = LocalLibrary(directory: dir)
            #expect(reloaded.items.count == 1)
            #expect(reloaded.items[0].title == "Sunset")
        }
    }

    @Test("remove deletes file then manifest entry")
    func remove() throws {
        try withLibrary { lib, _ in
            let item = LibraryItem(
                id: UUID(),
                kind: .midi,
                title: "Loop",
                createdAt: Date(),
                promptOrSource: "source.wav",
                durationSeconds: nil,
                relativePath: "midi/\(UUID().uuidString).mid"
            )
            try lib.add(item, bytes: Data([0x4D, 0x54, 0x68, 0x64]))

            try lib.remove(id: item.id)
            #expect(lib.items.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: lib.resolvedURL(for: item).path))
        }
    }

    @Test("metadata with a missing file still loads")
    func missingFileTolerated() throws {
        try withLibrary { lib, dir in
            let item = LibraryItem(
                id: UUID(),
                kind: .audio,
                title: "Ghost",
                createdAt: Date(),
                promptOrSource: "x",
                durationSeconds: nil,
                relativePath: "audio/\(UUID().uuidString).wav"
            )
            try lib.add(item, bytes: Data([0x01]))
            // Simulate a file that was removed but the manifest still references it.
            try FileManager.default.removeItem(at: lib.resolvedURL(for: item))

            let reloaded = LocalLibrary(directory: dir)
            #expect(reloaded.items.count == 1) // load must not crash on missing file
        }
    }

    @Test("remove of a nonexistent id is a no-op")
    func removeUnknownId() throws {
        try withLibrary { lib, _ in
            try lib.remove(id: UUID())
            #expect(lib.items.isEmpty)
        }
    }

    @Test("pending remote jobs persist and remote output imports are idempotent")
    func durableRemoteImport() throws {
        try withLibrary { library, directory in
            try library.trackPendingJob(id: "remote-job")
            #expect(library.pendingJobIDs == ["remote-job"])
            #expect(LocalLibrary(directory: directory).pendingJobIDs == ["remote-job"])

            let item = LibraryItem(
                id: UUID(), kind: .audio, title: "Variation", createdAt: Date(),
                promptOrSource: "reference", durationSeconds: nil,
                relativePath: "audio/variation.wav"
            )
            let first = try library.importRemoteOutput(
                item, bytes: Data("wav".utf8), remoteAssetID: "output-1", jobID: "remote-job"
            )
            let second = try library.importRemoteOutput(
                item, bytes: Data("wav".utf8), remoteAssetID: "output-1", jobID: "remote-job"
            )
            #expect(first.id == second.id)
            #expect(library.items.count == 1)
            try library.removePendingJob(id: "remote-job")
            #expect(library.pendingJobIDs.isEmpty)
        }
    }
}

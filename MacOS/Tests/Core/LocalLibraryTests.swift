import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("LocalLibrary persistence")
struct LocalLibraryTests {

    private func makeLibrary() -> (LocalLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-library-\(UUID().uuidString)")
        let lib = LocalLibrary(directory: dir)
        return (lib, dir)
    }

    @Test("add writes file and commits SwiftData metadata")
    func addOrdering() throws {
        let (lib, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

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

        // File must exist.
        #expect(FileManager.default.fileExists(atPath: lib.resolvedURL(for: item).path))
        #expect(lib.items.count == 1)

        let reloaded = LocalLibrary(directory: dir)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].title == "Sunset")
    }

    @Test("remove deletes file then manifest entry")
    func remove() throws {
        let (lib, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

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

    @Test("metadata with a missing file still loads")
    func missingFileTolerated() throws {
        let (lib, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

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

    @Test("remove of a nonexistent id is a no-op")
    func removeUnknownId() throws {
        let (lib, dir) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        try lib.remove(id: UUID())
        #expect(lib.items.isEmpty)
    }
}

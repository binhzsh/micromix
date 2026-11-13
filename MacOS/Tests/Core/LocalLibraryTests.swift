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

    @Test("corrected lyrics persist separately from the raw draft")
    func correctedLyrics() throws {
        try withLibrary { library, directory in
            let original = LibraryItem(id: UUID(), kind: .lyrics, title: "ASR", createdAt: .now,
                promptOrSource: "song.wav", durationSeconds: nil, relativePath: "lyrics/raw.txt")
            try library.add(original, bytes: Data("raw words".utf8))
            let corrected = try library.saveLyricsCorrection(of: original, text: "corrected words\n")
            let reopened = LocalLibrary(directory: directory)
            #expect(reopened.items.contains(where: { $0.id == original.id }))
            #expect(reopened.items.contains(where: { $0.id == corrected.id }))
            #expect(try String(contentsOf: reopened.resolvedURL(for: original), encoding: .utf8) == "raw words")
            #expect(try String(contentsOf: reopened.resolvedURL(for: corrected), encoding: .utf8) == "corrected words\n")
            #expect(corrected.promptOrSource.contains(original.id.uuidString))
            #expect(corrected.provenance == nil && corrected.remoteOutputAssetID == nil)
            var copied = ""
            LibraryScreen.copyLyrics(try String(contentsOf: reopened.resolvedURL(for: corrected), encoding: .utf8)) { copied = $0 }
            #expect(copied == "corrected words\n")
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

    @Test("failed add does not persist on a later save")
    func addSaveFailure() throws {
        try withLibrary { library, directory in
            let existing = LibraryItem(id: UUID(), kind: .audio, title: "Existing", createdAt: .now,
                                       promptOrSource: "", durationSeconds: nil, relativePath: "audio/existing.wav")
            let failed = LibraryItem(id: UUID(), kind: .audio, title: "Failed", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "audio/failed.wav")
            let later = LibraryItem(id: UUID(), kind: .audio, title: "Later", createdAt: .now,
                                    promptOrSource: "", durationSeconds: nil, relativePath: "audio/later.wav")
            let existingBytes = Data("existing".utf8)
            try library.add(existing, bytes: existingBytes)
            struct SaveFailure: Error {}
            #expect(throws: SaveFailure.self) {
                try library.add(failed, bytes: Data("failed".utf8), save: { _ in throw SaveFailure() })
            }
            #expect(!FileManager.default.fileExists(atPath: library.resolvedURL(for: failed).path))
            try library.add(later, bytes: Data("later".utf8))
            let reopened = LocalLibrary(directory: directory)
            #expect(Set(reopened.items.map(\.id)) == Set([existing.id, later.id]))
            #expect(try Data(contentsOf: reopened.resolvedURL(for: existing)) == existingBytes)
            #expect(!FileManager.default.fileExists(atPath: reopened.resolvedURL(for: failed).path))
        }
    }

    @Test("rename persists only the display title and rolls back failures")
    func rename() throws {
        try withLibrary { lib, dir in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Original title", createdAt: .now,
                                   promptOrSource: "source", durationSeconds: 2, relativePath: "audio/original.wav")
            let bytes = Data([1, 2, 3])
            try lib.add(item, bytes: bytes)
            #expect(LibraryScreen.matches(item, collection: .audio, searchText: " ORIGINAL TITLE "))
            try lib.rename(id: item.id, title: "  New title  ")
            let renamed = try #require(lib.items.first)
            #expect(!LibraryScreen.matches(renamed, collection: .audio, searchText: "original title"))
            #expect(LibraryScreen.matches(renamed, collection: .audio, searchText: " NEW TITLE "))
            #expect(!LibraryScreen.matches(renamed, collection: .midi, searchText: "new title"))
            #expect(renamed.id == item.id)
            #expect(renamed.title == "New title")
            #expect(renamed.relativePath == item.relativePath)
            #expect(renamed.promptOrSource == item.promptOrSource)
            #expect(try Data(contentsOf: lib.resolvedURL(for: renamed)) == bytes)
            #expect(LocalLibrary(directory: dir).items.first?.title == "New title")
            #expect(throws: LocalLibrary.RenameError.self) { try lib.rename(id: item.id, title: "  ") }
            struct SaveFailure: Error {}
            #expect(throws: SaveFailure.self) {
                try lib.rename(id: item.id, title: "Not saved", save: { _ in throw SaveFailure() })
            }
            #expect(lib.items.first?.title == "New title")
            #expect(LocalLibrary(directory: dir).items.first?.title == "New title")
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

    @Test("deleting a record preserves a file shared by another item")
    func removeSharedFile() throws {
        try withLibrary { library, directory in
            let first = LibraryItem(id: UUID(), kind: .audio, title: "First", createdAt: .now,
                                    promptOrSource: "", durationSeconds: nil, relativePath: "audio/shared.wav")
            let second = LibraryItem(id: UUID(), kind: .audio, title: "Second", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "audio/shared.wav")
            let bytes = Data("audio".utf8)
            try library.add(first, bytes: bytes)
            try library.add(second, bytes: bytes)
            try library.remove(id: first.id)
            #expect(library.items.map(\.id) == [second.id])
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == bytes)
            #expect(LocalLibrary(directory: directory).items.map(\.id) == [second.id])
        }
    }

    @Test("staging move failure preserves item and file")
    func removeFileFailure() throws {
        try withLibrary { library, directory in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Keep", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/keep.wav")
            let bytes = Data("audio".utf8)
            try library.add(item, bytes: bytes)
            #expect(throws: (any Error).self) {
                try library.remove(id: item.id, moveFile: { _, _ in throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(library.items.map(\.id) == [item.id])
            #expect(try Data(contentsOf: library.resolvedURL(for: item)) == bytes)
            #expect(LocalLibrary(directory: directory).items.map(\.id) == [item.id])
        }
    }

    @Test("save failure restores file and rolls back record deletion")
    func removeSaveFailure() throws {
        try withLibrary { library, directory in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Keep", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/keep.wav")
            let bytes = Data("audio".utf8)
            try library.add(item, bytes: bytes)
            #expect(throws: (any Error).self) {
                try library.remove(id: item.id, save: { _ in throw CocoaError(.fileWriteUnknown) })
            }
            #expect(library.items.map(\.id) == [item.id])
            #expect(try Data(contentsOf: library.resolvedURL(for: item)) == bytes)
            #expect(LocalLibrary(directory: directory).items.map(\.id) == [item.id])
            try library.remove(id: item.id)
            #expect(library.items.isEmpty)
        }
    }

    @Test("failed restoration retains staged file and reports its path")
    func removeRestoreFailure() throws {
        try withLibrary { library, directory in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Keep", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/keep.wav")
            let bytes = Data("audio".utf8)
            try library.add(item, bytes: bytes)
            var stagedURL: URL?
            do {
                try library.remove(id: item.id, moveFile: { source, destination in
                    if stagedURL != nil { throw CocoaError(.fileWriteNoPermission) }
                    #expect(source.deletingLastPathComponent() == destination.deletingLastPathComponent())
                    try FileManager.default.moveItem(at: source, to: destination)
                    stagedURL = destination
                }, save: { _ in throw CocoaError(.fileWriteUnknown) })
                Issue.record("Expected restoration failure")
            } catch {
                let staged = try #require(stagedURL)
                #expect(error.localizedDescription.contains(staged.path))
                #expect(try Data(contentsOf: staged) == bytes)
            }
            #expect(library.items.map(\.id) == [item.id])
            #expect(throws: (any Error).self) { try library.remove(id: item.id) }
            #expect(try Data(contentsOf: try #require(stagedURL)) == bytes)
            library.retryDeletionRecovery()
            #expect(library.deletionRecoveryIssues.isEmpty)
            #expect(try Data(contentsOf: library.resolvedURL(for: item)) == bytes)
            #expect(LocalLibrary(directory: directory).items.map(\.id) == [item.id])
        }
    }

    @Test("canonical path variants protect shared files during deletion and recovery")
    func sharedPathVariants() throws {
        try withLibrary { library, directory in
            let first = LibraryItem(id: UUID(), kind: .audio, title: "First", createdAt: .now,
                                    promptOrSource: "", durationSeconds: nil, relativePath: "audio/shared.wav")
            let second = LibraryItem(id: UUID(), kind: .audio, title: "Second", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "audio/./shared.wav")
            let bytes = Data("audio".utf8)
            try library.add(first, bytes: bytes)
            try library.add(second, bytes: bytes)
            try library.remove(id: first.id)
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == bytes)

            let token = UUID()
            let journalDirectory = directory.appendingPathComponent(".deletion-journal")
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let journal = ["id": first.id.uuidString, "relativePath": first.relativePath, "token": token.uuidString]
            try JSONEncoder().encode(journal).write(to: journalDirectory.appendingPathComponent("\(token.uuidString).json"))
            let staged = library.resolvedURL(for: first).deletingLastPathComponent()
                .appendingPathComponent(".micromix-recovery-\(token.uuidString)")
            try FileManager.default.moveItem(at: library.resolvedURL(for: first), to: staged)
            #expect(throws: (any Error).self) { try library.remove(id: second.id) }
            library.retryDeletionRecovery()
            #expect(library.deletionRecoveryIssues.isEmpty)
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == bytes)
        }
    }

    @Test("case aliases preserve shared and staged files on case-insensitive volumes")
    func sharedCaseAliases() throws {
        try withLibrary { library, directory in
            let first = LibraryItem(id: UUID(), kind: .audio, title: "First", createdAt: .now,
                                    promptOrSource: "", durationSeconds: nil, relativePath: "audio/Shared.wav")
            let second = LibraryItem(id: UUID(), kind: .audio, title: "Second", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "audio/shared.wav")
            let bytes = Data("audio".utf8)
            try library.add(first, bytes: bytes)
            // Exercise aliases only when the actual test volume supports them.
            guard FileManager.default.fileExists(atPath: library.resolvedURL(for: second).path) else { return }
            try library.add(second, bytes: bytes)
            try library.remove(id: first.id)
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == bytes)

            let token = UUID()
            let journalDirectory = directory.appendingPathComponent(".deletion-journal")
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let journal = ["id": first.id.uuidString, "relativePath": first.relativePath, "token": token.uuidString]
            let journalURL = journalDirectory.appendingPathComponent("\(token.uuidString).json")
            try JSONEncoder().encode(journal).write(to: journalURL)
            let staged = library.resolvedURL(for: first).deletingLastPathComponent()
                .appendingPathComponent(".micromix-recovery-\(token.uuidString)")
            try FileManager.default.moveItem(at: library.resolvedURL(for: first), to: staged)
            #expect(throws: (any Error).self) { try library.remove(id: second.id) }
            #expect(FileManager.default.fileExists(atPath: journalURL.path))
            #expect(try Data(contentsOf: staged) == bytes)
            library.retryDeletionRecovery()
            #expect(library.deletionRecoveryIssues.isEmpty)
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == bytes)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
        }
    }

    @Test("distinct case variants remain separate on case-sensitive volumes")
    func distinctCaseVariants() throws {
        try withLibrary { library, _ in
            let first = LibraryItem(id: UUID(), kind: .audio, title: "First", createdAt: .now,
                                    promptOrSource: "", durationSeconds: nil, relativePath: "audio/Shared.wav")
            let second = LibraryItem(id: UUID(), kind: .audio, title: "Second", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "audio/shared.wav")
            try library.add(first, bytes: Data([1]))
            guard !FileManager.default.fileExists(atPath: library.resolvedURL(for: second).path) else { return }
            try library.add(second, bytes: Data([2]))
            try library.remove(id: first.id)
            #expect(!FileManager.default.fileExists(atPath: library.resolvedURL(for: first).path))
            #expect(try Data(contentsOf: library.resolvedURL(for: second)) == Data([2]))
        }
    }

    @Test("remove rejects directories without staging them")
    func removeDirectory() throws {
        try withLibrary { library, _ in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Directory", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/file.wav")
            try library.add(item, bytes: Data([1]))
            let url = library.resolvedURL(for: item)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let child = url.appendingPathComponent("keep")
            try Data([2]).write(to: child)
            #expect(throws: (any Error).self) { try library.remove(id: item.id) }
            #expect(library.items.map(\.id) == [item.id])
            #expect(try Data(contentsOf: child) == Data([2]))
        }
    }

    @Test("startup restores an interrupted staged deletion")
    func interruptedDeletionRecovery() throws {
        try withLibrary { library, directory in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Keep", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/keep.wav")
            let bytes = Data("audio".utf8)
            try library.add(item, bytes: bytes)
            let token = UUID()
            let journalDirectory = directory.appendingPathComponent(".deletion-journal")
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let journal = ["id": item.id.uuidString, "relativePath": item.relativePath, "token": token.uuidString]
            try JSONEncoder().encode(journal).write(to: journalDirectory.appendingPathComponent("\(token.uuidString).json"))
            let staged = library.resolvedURL(for: item).deletingLastPathComponent()
                .appendingPathComponent(".micromix-recovery-\(token.uuidString)")
            try FileManager.default.moveItem(at: library.resolvedURL(for: item), to: staged)
            let reopened = LocalLibrary(directory: directory)
            #expect(reopened.items.map(\.id) == [item.id])
            #expect(try Data(contentsOf: reopened.resolvedURL(for: item)) == bytes)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(reopened.deletionRecoveryIssues.isEmpty)
        }
    }

    @Test("cleanup failure reports committed deletion and can be retried")
    func cleanupFailureRecovery() throws {
        try withLibrary { library, directory in
            let item = LibraryItem(id: UUID(), kind: .audio, title: "Delete", createdAt: .now,
                                   promptOrSource: "", durationSeconds: nil, relativePath: "audio/delete.wav")
            try library.add(item, bytes: Data("audio".utf8))
            #expect(throws: (any Error).self) {
                try library.remove(id: item.id, removeStagedFile: { _ in throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(library.items.isEmpty)
            #expect(!library.deletionRecoveryIssues.isEmpty)
            let reopened = LocalLibrary(directory: directory)
            #expect(reopened.deletionRecoveryIssues.isEmpty)
            #expect(reopened.items.isEmpty)
            library.retryDeletionRecovery()
            #expect(library.deletionRecoveryIssues.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: library.resolvedURL(for: item).path))
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

    @Test("failed pending job removal survives a later save and can be retried")
    func pendingRemovalSaveFailure() throws {
        try withLibrary { library, directory in
            try library.trackPendingJob(id: "keep", submittedAt: Date(timeIntervalSince1970: 1))
            #expect(throws: (any Error).self) {
                try library.removePendingJob(id: "keep", save: { _ in throw CocoaError(.fileWriteUnknown) })
            }
            #expect(library.pendingJobIDs == ["keep"])
            #expect(LocalLibrary(directory: directory).pendingJobIDs == ["keep"])

            try library.trackPendingJob(id: "later", submittedAt: Date(timeIntervalSince1970: 2))
            #expect(library.pendingJobIDs == ["keep", "later"])
            #expect(LocalLibrary(directory: directory).pendingJobIDs == ["keep", "later"])

            try library.removePendingJob(id: "keep")
            #expect(library.pendingJobIDs == ["later"])
            #expect(LocalLibrary(directory: directory).pendingJobIDs == ["later"])
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

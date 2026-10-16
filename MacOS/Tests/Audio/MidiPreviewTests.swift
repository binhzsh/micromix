import Foundation
import Testing
@testable import Micromix

/// Light construction test for `MidiPreview`: builds the previewer and asserts
/// its initial idle state without driving real audio hardware.
@MainActor
@Suite("MidiPreview")
struct MidiPreviewTests {

    @Test("constructs in the idle state")
    func constructsIdle() throws {
        let preview = MidiPreview()
        #expect(preview.state == .idle)
        #expect(!preview.isPlaying)
        #expect(preview.currentItem == nil)
    }

    @Test("stop on an idle preview is a safe no-op")
    func stopIsSafeWhenIdle() throws {
        let preview = MidiPreview()
        preview.stop()
        #expect(preview.state == .idle)
    }

    @Test("natural MIDI completion returns to idle")
    func naturalCompletion() async throws {
        let url = try makeMidiFile(noteTicks: 96)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = LibraryItem(
            id: UUID(),
            kind: .midi,
            title: "Preview",
            createdAt: Date(),
            promptOrSource: "test",
            durationSeconds: nil,
            relativePath: "midi/test.mid"
        )
        let preview = MidiPreview()

        #expect(preview.load(url: url, item: item))
        preview.play()
        #expect(preview.state == .playing)

        try await Task.sleep(for: .milliseconds(800))
        #expect(preview.state == .idle)
    }

    @Test("shouldResume is true only for the paused same item")
    func shouldResumeOnlyForPausedSameItem() throws {
        let url = try makeMidiFile(noteTicks: 384)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = MidiPreview()
        let item = LibraryItem(
            id: UUID(), kind: .midi, title: "Preview", createdAt: Date(),
            promptOrSource: "test", durationSeconds: nil, relativePath: "midi/test.mid"
        )
        let other = LibraryItem(
            id: UUID(), kind: .midi, title: "Other", createdAt: Date(),
            promptOrSource: "test", durationSeconds: nil, relativePath: "midi/other.mid"
        )

        // Idle: never resume.
        #expect(!preview.shouldResume(for: item))

        #expect(preview.load(url: url, item: item))
        // Loaded but not started: still not a resume.
        #expect(!preview.shouldResume(for: item))

        preview.play()
        // While playing, a play request is not a resume.
        #expect(!preview.shouldResume(for: item))

        preview.pause()
        // Paused on the same item: the resume case.
        #expect(preview.shouldResume(for: item))
        #expect(!preview.shouldResume(for: other))

        preview.stop()
        #expect(!preview.shouldResume(for: item))
    }

    @Test("toggle alternates playing and paused")
    func toggleAlternatesStates() throws {
        let url = try makeMidiFile(noteTicks: 384)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = MidiPreview()
        let item = LibraryItem(
            id: UUID(), kind: .midi, title: "Preview", createdAt: Date(),
            promptOrSource: "test", durationSeconds: nil, relativePath: "midi/test.mid"
        )
        #expect(preview.load(url: url, item: item))

        preview.toggle()
        #expect(preview.state == .playing)

        preview.toggle()
        #expect(preview.state == .paused)

        // Resume through the paused state keeps the same item loaded.
        preview.toggle()
        #expect(preview.state == .playing)
        #expect(preview.currentItem?.id == item.id)
    }

    @Test("play invokes the onStart hook")
    func playInvokesOnStart() throws {
        let url = try makeMidiFile(noteTicks: 384)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = MidiPreview()
        let item = LibraryItem(
            id: UUID(), kind: .midi, title: "Preview", createdAt: Date(),
            promptOrSource: "test", durationSeconds: nil, relativePath: "midi/test.mid"
        )
        #expect(preview.load(url: url, item: item))

        final class HookBox: @unchecked Sendable {
            var fired = false
        }
        let hook = HookBox()
        preview.onStart = { hook.fired = true }
        preview.play()
        #expect(hook.fired)
    }

    /// Minimal single-note Standard MIDI File. `noteTicks` controls the note
    /// length (96 ticks = 1 quarter = 0.5 s at the embedded 500 000 µs tempo).
    private func makeMidiFile(noteTicks: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-midi-\(UUID().uuidString).mid")
        let delta = Self.variableLengthQuantity(UInt32(noteTicks))
        try Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x60,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, UInt8(7 + 4 + delta.count + 3 + 4),
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0x90, 0x3C, 0x40,
        ] + delta + [
            0x80, 0x3C, 0x40,
            0x00, 0xFF, 0x2F, 0x00,
        ]).write(to: url)
        return url
    }

    private static func variableLengthQuantity(_ value: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return bytes
    }
}

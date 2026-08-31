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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-midi-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x60,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x13,
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0x90, 0x3C, 0x40,
            0x60, 0x80, 0x3C, 0x40,
            0x00, 0xFF, 0x2F, 0x00,
        ]).write(to: url)
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
}

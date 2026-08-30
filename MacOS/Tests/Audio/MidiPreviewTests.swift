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
}
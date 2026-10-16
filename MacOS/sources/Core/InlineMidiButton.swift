import SwiftUI

/// Inline play/pause chip for MIDI result rows. Loads the item into the shared
/// MidiPreview (General-MIDI software synth) and toggles playback in place, so
/// transcribed notation can be auditioned right on the result row.
struct InlineMidiButton: View {
    @ObservedObject var midiPreview: MidiPreview
    let item: LibraryItem
    let library: LocalLibrary

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Typography.monoLabel(isPlaying ? "PAUSE" : "PLAY", size: 9)
            }
            .foregroundColor(isPlaying ? Palette.accentGreen : Palette.ink.opacity(0.76))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                isPlaying ? Palette.accentGreen : Palette.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause \(item.title)" : "Play \(item.title)")
    }

    private var isPlaying: Bool {
        midiPreview.currentItem?.id == item.id && midiPreview.state == .playing
    }

    private func toggle() {
        if midiPreview.shouldResume(for: item) {
            midiPreview.play()
        } else if midiPreview.currentItem?.id != item.id {
            if midiPreview.load(url: library.resolvedURL(for: item), item: item) {
                midiPreview.play()
            }
        }
    }
}

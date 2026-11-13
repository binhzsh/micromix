import SwiftUI

/// Inline play/pause chip for a result row (Phase 5.1). Loads the item's audio
/// into the shared AudioPlayer and toggles playback in place, so auditioning a
/// fresh result never requires opening the full Library player.
struct InlinePlayButton: View {
    @ObservedObject var player: AudioPlayer
    let item: LibraryItem
    let library: LocalLibrary
    var resolveItem: (() -> LibraryItem?)? = nil
    var onUnavailable: (() -> Void)? = nil

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Typography.monoLabel(isPlaying ? "PAUSE" : "PLAY", size: 9)
            }
            .foregroundColor(isPlaying ? Palette.textGreen : Palette.ink.opacity(0.76))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                isPlaying ? Palette.textGreen : Palette.boundary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause \(item.title)" : "Play \(item.title)")
    }

    private var isPlaying: Bool {
        player.currentItem?.id == item.id && player.state == .playing
    }

    private func toggle() {
        guard let target = resolveItem.map({ $0() }) ?? (resolveItem == nil ? item : nil) else {
            onUnavailable?()
            return
        }
        if player.currentItem?.id != target.id {
            guard player.load(url: library.resolvedURL(for: target), item: target) != nil else {
                onUnavailable?()
                return
            }
        }
        player.toggle()
    }
}

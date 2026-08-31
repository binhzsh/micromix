import SwiftUI

/// LIBRARY mode: a dot-matrix list of saved results with transport controls
/// on the deck (play/pause, delete, reveal in Finder) and an empty state.
struct LibraryScreen: View {
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @Binding var selectedID: UUID?

    private let columns = [
        GridItem(.fixed(44), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.fixed(52), alignment: .leading),
        GridItem(.fixed(52), alignment: .trailing),
        GridItem(.flexible(minimum: 64), alignment: .trailing),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            listOrEmpty
            Spacer(minLength: 0)
            transport
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Typography.monoLabel("LIBRARY — \(library.items.count) ITEM\(library.items.count == 1 ? "" : "S")", size: 11)
                .foregroundColor(Palette.ink.opacity(0.6))
            Spacer()
        }
    }

    @ViewBuilder private var listOrEmpty: some View {
        if library.items.isEmpty {
            Typography.monoLabel("NO ITEMS", size: 12)
                .foregroundColor(Palette.ink.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
        } else {
            table
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                headerRow
                Divider().overlay(Palette.divider)
                ForEach(Array(library.items.enumerated()), id: \.element.id) { index, item in
                    row(index: index + 1, item: item)
                    Divider().overlay(Palette.divider.opacity(0.6))
                }
            }
            .background(Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.divider, lineWidth: 1))
        }
        .frame(maxHeight: 190)
    }

    private var headerRow: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            col("")
            col("TITLE")
            col("TYPE")
            col("LEN")
            col("DATE")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(index: Int, item: LibraryItem) -> some View {
        let selected = item.id == selectedID
        return LazyVGrid(columns: columns, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.55))
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.ink)
                .lineLimit(1)
            Text(item.kind == .audio ? "WAV" : "MID")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(item.kind == .audio ? Palette.accentGreen : Palette.accentBlue)
            Text(item.durationSeconds.map { Self.formatDuration($0) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.7))
            Text(item.createdAt, style: .date)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.6))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Palette.accentBlue.opacity(0.10) : Color.clear)
        .onTapGesture {
            midiPreview.stop()
            selectedID = item.id
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            button("PLAY", color: Palette.accentGreen, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                let url = library.resolvedURL(for: item)
                if item.kind == .audio {
                    midiPreview.stop()
                    if player.load(url: url, item: item) != nil {
                        player.play()
                    }
                } else {
                    player.stop()
                    if midiPreview.load(url: url, item: item) {
                        midiPreview.play()
                    }
                }
            }
            button("PAUSE", color: Palette.ink, disabled: !player.isPlaying && !midiPreview.isPlaying) {
                if player.isPlaying { player.pause() }
                if midiPreview.isPlaying { midiPreview.stop() }
            }
            button("STOP", color: Palette.ink, disabled: !player.isPlaying && !midiPreview.isPlaying) {
                if player.isPlaying { player.stop() }
                if midiPreview.isPlaying { midiPreview.stop() }
            }
            button("DELETE", color: Palette.accentRed, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                if player.currentItem?.id == item.id { player.stop() }
                if midiPreview.currentItem?.id == item.id { midiPreview.stop() }
                try? library.remove(id: item.id)
            }
            button("REVEAL", color: Palette.accentBlue, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                NSWorkspace.shared.activateFileViewerSelecting([library.resolvedURL(for: item)])
            }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, color: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(disabled ? Palette.ink.opacity(0.3) : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.deck)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(disabled ? Palette.divider : color, lineWidth: 1.5)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    private func col(_ text: String) -> some View {
        Typography.monoLabel(text, size: 10)
            .foregroundColor(Palette.ink.opacity(0.5))
    }

    private var selectedItem: LibraryItem? {
        library.items.first { $0.id == selectedID }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

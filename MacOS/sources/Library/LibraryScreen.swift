import AppKit
import SwiftUI

/// LIBRARY mode: a dot-matrix list of saved results with transport controls
/// on the deck (play/pause, delete, reveal in Finder) and an empty state.
struct LibraryScreen: View {
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @Binding var selectedID: UUID?
    var onGenerate: () -> Void = {}
    var onTranscribe: () -> Void = {}

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
            provenance
            transport
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Typography.monoLabel("LIBRARY — \(library.items.count) ITEM\(library.items.count == 1 ? "" : "S")", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))
            Spacer()
        }
    }

    @ViewBuilder private var listOrEmpty: some View {
        if library.items.isEmpty {
            DeckPanel {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(Palette.accentBlue)
                    Typography.monoLabel("NO TRACKS YET", size: 13)
                        .foregroundColor(Palette.ink)
                    Text("Generate a new piece or transcribe audio to build your private library.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.66))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        emptyAction("GENERATE", color: Palette.accentOrange, action: onGenerate)
                        emptyAction("TRANSCRIBE", color: Palette.accentBlue, action: onTranscribe)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
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
                .foregroundColor(Palette.ink.opacity(0.68))
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
                .foregroundColor(Palette.ink.opacity(0.68))
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
            button("COPY PROVENANCE", color: Palette.accentOrange, disabled: selectedItem?.provenance == nil) {
                guard let copyText = selectedItem?.provenance?.copyText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, color: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(disabled ? Palette.ink.opacity(0.46) : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.deck)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(disabled ? Palette.ink.opacity(0.22) : color, lineWidth: 1.5)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    private func col(_ text: String) -> some View {
        Typography.monoLabel(text, size: 10)
            .foregroundColor(Palette.ink.opacity(0.64))
    }

    private func emptyAction(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Typography.monoLabel(title, size: 10)
                .foregroundColor(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var selectedItem: LibraryItem? {
        library.items.first { $0.id == selectedID }
    }

    @ViewBuilder private var provenance: some View {
        if let item = selectedItem {
            DeckPanel {
                VStack(alignment: .leading, spacing: 4) {
                    Typography.monoLabel("PROVENANCE", size: 10)
                        .foregroundColor(Palette.ink.opacity(0.64))
                    if alternatives(for: item).count > 1 {
                        HStack(spacing: 5) {
                            Typography.monoLabel("ALTERNATIVES", size: 9)
                                .foregroundColor(Palette.ink.opacity(0.64))
                            ForEach(alternatives(for: item)) { alternative in
                                Button("ALT \((alternative.provenance?.output.position ?? 0) + 1)") {
                                    player.stop()
                                    midiPreview.stop()
                                    selectedID = alternative.id
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(alternative.id == item.id ? Palette.accentOrange : Palette.ink.opacity(0.68))
                            }
                        }
                    }
                    if let provenance = item.provenance {
                        Text("OPERATION: \(provenance.operation ?? item.kind.rawValue.uppercased()) · JOB \(provenance.jobID.suffix(8)) · OUTPUT #\(provenance.output.position + 1)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Palette.ink)
                        Text("SOURCE: \(provenance.inputs.sorted { $0.position < $1.position }.map { "\($0.name) — \($0.asset.filename)" }.joined(separator: ", ").ifEmpty("(none)"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.72))
                        Text("SUBMITTED: \(["seed", "variation_count"].compactMap { key in provenance.parameters[key].map { "\(key)=\($0.displayText)" } }.joined(separator: ", ").ifEmpty("(not specified)"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.72))
                        Text("PARAMETERS: \(provenance.parameters.keys.sorted().map { "\($0)=\(provenance.parameters[$0]!.displayText)" }.joined(separator: ", ").ifEmpty("(none)"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.72))
                            .lineLimit(2)
                    } else {
                        Text("PROVENANCE UNAVAILABLE FOR THIS LEGACY ITEM")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.60))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func alternatives(for item: LibraryItem) -> [LibraryItem] {
        library.items.alternatives(for: item)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

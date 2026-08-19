import SwiftUI

/// TRANSCRIBE mode: drop zone / "SELECT AUDIO", instrument picker, tempo
/// detect toggle, and the orange TRANSCRIBE action. Screen readouts (elapsed,
/// TRANSCRIBING, result/error) are rendered by `DeviceWindow` via
/// `DotMatrixScreen`; this view owns the deck inputs and fires the flow.
struct TranscribeScreen: View {
    @ObservedObject var viewModel: TranscribeViewModel
    let instruments: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Typography.monoLabel("2. TRANSCRIBE — AUDIO TO MIDI", size: 11)
                .foregroundColor(Palette.ink.opacity(0.6))

            // Audio selection / drop zone
            selectionZone

            // Instrument picker
            InstrumentPicker(viewModel: viewModel, instruments: instruments)

            // Tempo detect toggle + fixed size note
            Toggle(isOn: $viewModel.detectTempo) {
                Typography.monoLabel("DETECT TEMPO", size: 11)
                    .foregroundColor(Palette.ink)
            }
            .toggleStyle(.switch)
            .disabled(viewModel.isBlocked)

            // Primary action
            Button(action: { viewModel.start() }) {
                Text(viewModel.phase == .running ? "TRANSCRIBING…" : "TRANSCRIBE")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(viewModel.phase == .running ? Palette.ink.opacity(0.6) : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(viewModel.phase == .running ? Palette.ink.opacity(0.18) : Palette.accentOrange)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Palette.ink.opacity(0.85), lineWidth: 1.5)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(viewModel.isBlocked)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Audio selection (pick + drag-drop)

    @ViewBuilder private var selectionZone: some View {
        let selected = viewModel.hasSelection
        VStack(alignment: .leading, spacing: 6) {
            Typography.monoLabel("INPUT AUDIO", size: 10)
                .foregroundColor(Palette.ink.opacity(0.5))

            HStack(spacing: 8) {
                Text(selected
                        ? viewModel.sourceName
                        : "SELECT AN AUDIO FILE")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(selected ? Palette.accentBlue : Palette.ink.opacity(0.6))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { self.pick() }) {
                    Text(selected ? "REPLACE" : "SELECT AUDIO")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.deck)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.divider, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.isBlocked)
            }
            .padding(10)
            .background(Palette.deck)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Palette.accentBlue : Palette.divider, lineWidth: 1.5)
            )
        }
    }

    /// Present an `NSOpenPanel` restricted to audio files and read the selection.
    private func pick() {
        guard !viewModel.isBlocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["wav", "mp3", "m4a", "aif", "aiff"]
        guard panel.runModal() == .OK else { return }
        guard let url = panel.url else { return }
        handleDrop([url])
    }

    /// Read and register any dropped / selected audio file (<= 200 MiB).
    private func handleDrop(_ urls: [URL]) {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.selection = nil
            return
        }
        // Enforce the shim's 200 MiB upload cap.
        if data.count > 200 * 1024 * 1024 {
            viewModel.selection = nil
            return
        }
        let name = url.lastPathComponent ?? "input.wav"
        viewModel.select(name: name, bytes: data)
    }
}
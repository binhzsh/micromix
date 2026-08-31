import SwiftUI
import UniformTypeIdentifiers

struct AnalyzeScreen: View {
    @ObservedObject var viewModel: AnalyzeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Typography.monoLabel("2. ANALYZE — ON-DEVICE MUSIC UNDERSTANDING", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))

            Text("RHYTHM, KEY, STRUCTURE AND INSTRUMENT ACTIVITY STAY ON THIS MAC.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.68))

            sourcePanel
                .dropDestination(for: URL.self) { urls, _ in
                    return analyze(urls.first)
                }

            if viewModel.isRunning {
                DeckPanel {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Typography.monoLabel("ANALYZING AUDIO…", size: 11)
                            .foregroundColor(Palette.ink.opacity(0.72))
                    }
                }
            } else if let analysis = viewModel.analysis {
                DeckPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Typography.monoLabel("ANALYSIS COMPLETE", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.68))
                        Text(analysis.compactDescription)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.accentBlue)
                            .textSelection(.enabled)
                    }
                }
            } else if let error = viewModel.error {
                DeckPanel {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.accentRed)
                }
            } else {
                outputPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePanel: some View {
        Button(action: pick) {
            DeckPanel(borderColor: viewModel.sourceName.isEmpty ? Palette.divider : Palette.accentBlue) {
                HStack(spacing: 14) {
                    waveform
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.sourceName.isEmpty ? "SELECT OR DROP AUDIO" : viewModel.sourceName)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(viewModel.sourceName.isEmpty ? Palette.ink : Palette.accentBlue)
                            .lineLimit(1)
                        Typography.monoLabel("WAV, AIFF, MP3, M4A  •  ON-DEVICE", size: 9)
                            .foregroundColor(Palette.ink.opacity(0.64))
                    }
                    Spacer(minLength: 8)
                    Typography.monoLabel(viewModel.sourceName.isEmpty ? "CHOOSE" : "REPLACE", size: 10)
                        .foregroundColor(Palette.ink)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRunning)
        .accessibilityHint("Choose an audio file to analyze, or drop one here")
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([8.0, 18.0, 12.0, 24.0, 16.0, 10.0], id: \.self) { height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.accentBlue)
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 32, height: 28)
    }

    private var outputPreview: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 10) {
                Typography.monoLabel("OUTPUT PREVIEW", size: 10)
                    .foregroundColor(Palette.ink.opacity(0.68))
                HStack(spacing: 8) {
                    previewChip("RHYTHM")
                    previewChip("KEY")
                    previewChip("STRUCTURE")
                    previewChip("INSTRUMENTS")
                }
                Text("Choose an audio file to reveal musical structure without uploading it.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.64))
            }
        }
    }

    private func previewChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(Palette.ink.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.deck)
            .border(Palette.divider, width: 1)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        _ = analyze(panel.url)
    }

    private func analyze(_ url: URL?) -> Bool {
        guard let url, !viewModel.isRunning else { return false }
        viewModel.analyze(url: url)
        return true
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct AnalyzeScreen: View {
    @ObservedObject var viewModel: AnalyzeViewModel
    var router: WorkflowRouter? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze — on-device music understanding").font(Typography.heading)
                .foregroundColor(Palette.ink.opacity(0.76))

            Text(AnalyzeViewModel.capabilityDescription(
                supportsMusicUnderstanding: AnalyzeViewModel.supportsMusicUnderstanding
            ))
                .font(Typography.help)
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
                        Typography.monoLabel(
                            AnalyzeViewModel.supportsMusicUnderstanding ? "ANALYSIS COMPLETE" : "DURATION ONLY — ANALYSIS COMPLETE",
                            size: 10
                        )
                            .foregroundColor(Palette.ink.opacity(0.68))
                        Text(analysis.compactDescription)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.textBlue)
                            .textSelection(.enabled)
                        if let router, let url = viewModel.sourceURL {
                            let fields = [analysis.beatsPerMinute == nil ? nil : "BPM", analysis.key == nil ? nil : "key"].compactMap { $0 }
                            Text(fields.isEmpty
                                 ? "No BPM or key available to transfer. Reimagine can still use the source audio."
                                 : "Available metadata: \(fields.joined(separator: " and ")). Existing destination edits are preserved. Generate does not receive the audio.")
                                .font(.caption)
                                .foregroundColor(Palette.ink.opacity(0.68))
                            HStack(spacing: 7) {
                                Typography.monoLabel("NEXT ACTIONS", size: 9)
                                    .foregroundColor(Palette.ink.opacity(0.64))
                                chainedAction("USE IN REIMAGINE", color: Palette.textOrange) {
                                    router.reimagineReference(url: url, derived: DerivedMetadata(from: analysis))
                                }
                                if !fields.isEmpty {
                                    chainedAction("USE IN GENERATE", color: Palette.textOrange) {
                                        router.prefillGenerate(with: DerivedMetadata(from: analysis))
                                    }
                                }
                            }
                        }
                    }
                }
            } else if let error = viewModel.error {
                DeckPanel {
                    Text(error)
                        .font(Typography.help)
                        .foregroundColor(Palette.textRed)
                }
            } else {
                outputPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePanel: some View {
        SourceChooser(name: viewModel.sourceName.isEmpty ? nil : viewModel.sourceName,
                      hint: "WAV, AIFF, MP3 or M4A. Choose or drop audio for on-device analysis.",
                      accessibilityHint: "Choose an audio file to analyze, or drop one here",
                      isDisabled: viewModel.isRunning, choose: pick)
    }

    private var outputPreview: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 10) {
                Typography.monoLabel("OUTPUT PREVIEW", size: 10)
                    .foregroundColor(Palette.ink.opacity(0.68))
                HStack(spacing: 8) {
                    previewChip("DURATION")
                    if AnalyzeViewModel.supportsMusicUnderstanding {
                        previewChip("RHYTHM")
                        previewChip("KEY")
                        previewChip("INSTRUMENTS")
                    }
                }
                Text("Choose an audio file to analyze it without uploading it.")
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.64))
            }
        }
    }

    private func chainedAction(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Typography.monoLabel(title, size: 9)
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
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

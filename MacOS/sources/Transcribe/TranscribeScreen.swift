import SwiftUI
import UniformTypeIdentifiers

struct TranscribeScreen: View {
    @ObservedObject var viewModel: TranscribeViewModel
    let instruments: [String]
    var serverAvailable: Bool = true

    private var canTranscribe: Bool {
        viewModel.hasSelection && !viewModel.isBlocked && serverAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Typography.monoLabel("3. TRANSCRIBE — AUDIO TO MIDI", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))

            selectionZone
                .dropDestination(for: URL.self) { urls, _ in
                    handleDrop(urls)
                    return !urls.isEmpty
                }

            InstrumentPicker(viewModel: viewModel, instruments: instruments)

            DeckPanel {
                Toggle(isOn: $viewModel.detectTempo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Typography.monoLabel("DETECT TEMPO", size: 11)
                            .foregroundColor(Palette.ink)
                        Typography.monoLabel("ALIGN MIDI EVENTS TO THE TRACK GRID", size: 9)
                            .foregroundColor(Palette.ink.opacity(0.62))
                    }
                }
                .toggleStyle(PanelToggleStyle())
                .disabled(viewModel.isBlocked)
            }

            HStack(spacing: 8) {
                PrimaryActionButton(
                    title: viewModel.isRunning ? "TRANSCRIBING…" : "TRANSCRIBE",
                    isEnabled: canTranscribe,
                    action: { _ = viewModel.start() }
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint(canTranscribe ? "Convert the selected audio to MIDI" : "Select audio and connect to the server first")

                if viewModel.isRunning {
                    Button(action: viewModel.cancel) {
                        Typography.monoLabel("CANCEL", size: 11)
                            .foregroundColor(Palette.accentRed)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.accentRed, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionZone: some View {
        let selected = viewModel.hasSelection
        return VStack(alignment: .leading, spacing: 6) {
            Typography.monoLabel("INPUT AUDIO", size: 10)
                .foregroundColor(Palette.ink.opacity(0.68))

            Button(action: pick) {
                DeckPanel(borderColor: selected ? Palette.accentBlue : Palette.divider) {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "waveform.badge.checkmark" : "waveform")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(selected ? Palette.accentBlue : Palette.ink.opacity(0.62))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(selected ? viewModel.sourceName : "SELECT OR DROP AUDIO")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(selected ? Palette.accentBlue : Palette.ink)
                                .lineLimit(1)
                            Typography.monoLabel("WAV, AIFF, MP3, M4A  •  MAX 200 MB", size: 9)
                                .foregroundColor(Palette.ink.opacity(0.62))
                        }

                        Spacer(minLength: 8)
                        Typography.monoLabel(selected ? "REPLACE" : "CHOOSE", size: 10)
                            .foregroundColor(Palette.ink)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBlocked)

            if let analysis = viewModel.selection?.analysis {
                Typography.monoLabel(analysis.compactDescription, size: 10)
                    .foregroundColor(Palette.ink.opacity(0.68))
                    .lineLimit(1)
            }
        }
    }

    private func pick() {
        guard !viewModel.isBlocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleDrop([url])
    }

    private func handleDrop(_ urls: [URL]) {
        guard let url = urls.first else { return }
        Task {
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try TranscribeViewModel.readSource(at: url)
                }.value
            } catch let error as TranscribeViewModel.SourceReadError {
                viewModel.rejectSource(error)
                return
            } catch {
                viewModel.rejectSource(.unreadable)
                return
            }
            let analysis = try? await LocalMusicAnalyzer.analyze(url: url)
            _ = viewModel.select(name: url.lastPathComponent, bytes: data, analysis: analysis)
        }
    }
}

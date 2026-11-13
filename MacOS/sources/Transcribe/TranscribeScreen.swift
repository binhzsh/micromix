import SwiftUI
import UniformTypeIdentifiers

struct TranscribeScreen: View {
    @ObservedObject var viewModel: TranscribeViewModel
    @State private var showsInstrumentFilter = false
    let instruments: [String]
    var instrumentCatalog: VoiceCatalogState? = nil
    var onRefreshCatalog: () -> Void = {}
    var localInferenceAvailable: Bool = true
    var modelStatuses: [String: String] = [:]
    var router: WorkflowRouter? = nil
    var midiPreview: MidiPreview? = nil
    var library: LocalLibrary? = nil
    var onShowInLibrary: (LibraryItem) -> Void = { _ in }

    static var heading: String {
        "\(DeviceMode.transcribe.displayIndex). TRANSCRIBE — MIDI & LYRICS"
    }

    private var canTranscribe: Bool {
        viewModel.hasSelection && !viewModel.isBlocked && localInferenceAvailable
            && !WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [viewModel.output == .midi ? "muscriptor" : "whisper"])
    }

    private var transcribeDisabledReason: String {
        if viewModel.isRunning { return "Transcription is in progress." }
        if viewModel.isLoadingSource { return "Wait for the audio to finish loading." }
        if !viewModel.hasSelection { return "Select an audio source first." }
        return WorkflowReadiness.description(connected: localInferenceAvailable, statuses: modelStatuses,
                                             models: [viewModel.output == .midi ? "muscriptor" : "whisper"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.output == .midi ? "\(DeviceMode.transcribe.displayIndex). Transcribe — MIDI & lyrics" : "\(DeviceMode.transcribe.displayIndex). Transcribe — lyrics draft")
                .font(Typography.heading)
                .foregroundColor(Palette.ink)

            Text("Turn audio into MIDI notes or an unverified sung-lyrics draft. Review and correct lyrics in Library before using them.")
                .font(.caption).foregroundColor(Palette.ink.opacity(0.7))

            selectionZone
                .dropDestination(for: URL.self) { urls, _ in
                    handleDrop(urls)
                    return !urls.isEmpty
                }

            Picker("Output", selection: $viewModel.output) {
                ForEach(TranscribeViewModel.Output.allCases, id: \.self) { output in
                    Text(output.rawValue).tag(output)
                }
            }.pickerStyle(.segmented).disabled(viewModel.isBlocked)

            if viewModel.output == .midi {
                DeckPanel {
                    Toggle(isOn: $viewModel.detectTempo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Typography.monoLabel("DETECT TEMPO", size: 11)
                                .foregroundColor(Palette.ink)
                            Text("Align MIDI events to the track grid")
                                .font(Typography.help)
                                .foregroundColor(Palette.ink.opacity(0.76))
                        }
                    }
                    .toggleStyle(PanelToggleStyle())
                    .disabled(viewModel.isBlocked)
                }
            } else {
                Text("MLX Whisper produces a draft; review and correct the lyrics.")
                    .font(.caption).foregroundColor(Palette.ink.opacity(0.7))
            }

            HStack(spacing: 8) {
                PrimaryActionButton(
                    title: viewModel.isRunning ? "TRANSCRIBING…" : (viewModel.phase.workflowStatus.offersRetry ? "RETRY TRANSCRIPTION" : "TRANSCRIBE"),
                    isEnabled: canTranscribe,
                    action: { _ = viewModel.start() }
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint(canTranscribe ? "Transcribe the selected audio" : WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [viewModel.output == .midi ? "muscriptor" : "whisper"]) && localInferenceAvailable ? WorkflowReadiness.description(connected: true, statuses: modelStatuses, models: [viewModel.output == .midi ? "muscriptor" : "whisper"]) : "Select audio and start local inference first")

                if viewModel.isRunning {
                    Button(action: viewModel.cancel) {
                        Typography.monoLabel("CANCEL", size: 11)
                            .foregroundColor(Palette.textRed)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.textRed, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !canTranscribe {
                Text(transcribeDisabledReason).font(.caption).foregroundColor(Palette.ink.opacity(0.75))
            }
            WorkflowStatusView(status: viewModel.phase.workflowStatus, elapsed: viewModel.elapsed)
            if viewModel.output == .midi {
                DisclosureGroup(isExpanded: $showsInstrumentFilter) {
                    InstrumentPicker(viewModel: viewModel, instruments: instruments, catalog: instrumentCatalog, onRefresh: onRefreshCatalog)
                        .padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Instrument filter (optional)")
                        Text(InstrumentPicker.selectionSummary(viewModel.instruments))
                            .font(.caption)
                            .foregroundColor(Palette.ink.opacity(0.7))
                    }
                }
                .disabled(viewModel.isBlocked)
            }
            if viewModel.phase == .done, let latest = viewModel.lastItem {
                if latest.kind == .lyrics, let library {
                    Text((try? String(contentsOf: library.resolvedURL(for: latest), encoding: .utf8)) ?? "Lyrics file is missing or unreadable.")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Review and correct in Library") { onShowInLibrary(latest) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if latest.kind == .midi, let midiPreview, let library {
                        InlineMidiButton(midiPreview: midiPreview, item: latest, library: library)
                    }
                    if let router {
                        NextActionsRow(router: router, item: latest)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            SourceChooser(name: viewModel.hasSelection ? viewModel.sourceName : nil,
                          hint: "WAV, AIFF, MP3 or M4A · Maximum 200 MB · Drop audio here",
                          accessibilityHint: "Choose audio to transcribe, or drop one here",
                          isDisabled: viewModel.isBlocked, isLoading: viewModel.isLoadingSource,
                          choose: pick)
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
            _ = await viewModel.select(url: url)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// A verified capabilities response is the only evidence that the voice library is empty.
enum VoiceCatalogState: Equatable {
    case unavailable
    case loading
    case failed
    case loaded([String])

    var voices: [String] {
        if case .loaded(let voices) = self { return voices }
        return []
    }

    var message: String? {
        switch self {
        case .unavailable: "Local inference is unavailable. Start the local sidecar to load voices."
        case .loading: "Loading local voice models…"
        case .failed: "Could not load local voice models. Try again."
        case .loaded(let voices): voices.isEmpty ? "No local voice models found. Install a voice model, then refresh." : nil
        }
    }
}

struct VoiceCatalogNotice: View {
    let state: VoiceCatalogState
    let onRefresh: () -> Void

    var body: some View {
        if let message = state.message {
            Text(message).foregroundStyle(.secondary)
        }
        Button("REFRESH VOICES", action: onRefresh)
    }
}

struct SourceProcessingScreen: View {
    @ObservedObject var viewModel: SourceProcessingViewModel
    var voices: [String] = []
    var localInferenceAvailable = true
    var modelStatuses: [String: String] = [:]
    var voiceCatalog: VoiceCatalogState? = nil
    var onRefreshVoices: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var midiPreview: MidiPreview? = nil
    var library: LocalLibrary? = nil
    @State private var isImporting = false
    @State private var importError: String?

    private var catalog: VoiceCatalogState {
        voiceCatalog ?? (localInferenceAvailable ? .loading : .unavailable)
    }

    private var canStart: Bool {
        let direction = viewModel.operation == .vocalSwap ? viewModel.voiceModel : viewModel.description
        return localInferenceAvailable && !WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [viewModel.operation == .vocalSwap ? "mlx_rvc" : "sam_audio"]) && !viewModel.isRunning && viewModel.sourceURL != nil
            && !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (viewModel.operation != .vocalSwap || catalog.voices.contains(direction))
    }

    private var disabledReason: String {
        if viewModel.isRunning { return "Processing is in progress." }
        if viewModel.sourceURL == nil { return "Select an audio source first." }
        let model = viewModel.operation == .vocalSwap ? "mlx_rvc" : "sam_audio"
        if !localInferenceAvailable || WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [model]) {
            return WorkflowReadiness.description(connected: localInferenceAvailable, statuses: modelStatuses, models: [model])
        }
        if viewModel.operation == .vocalSwap { return "Select an available voice model." }
        return "Describe the sound to extract."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceChooser(name: viewModel.sourceURL?.lastPathComponent,
                          hint: viewModel.operation == .vocalSwap ? "Choose audio containing vocals to convert." : "Choose audio containing the sound to extract.",
                          accessibilityHint: "Choose source audio for processing",
                          isDisabled: viewModel.isRunning, error: importError,
                          choose: { isImporting = true })
            DeckPanel {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.operation == .vocalSwap {
                        if !catalog.voices.isEmpty {
                            Picker("VOICE MODEL", selection: $viewModel.voiceModel) {
                                Text("Select a voice").tag("")
                                ForEach(catalog.voices, id: \.self) { Text($0).tag($0) }
                            }
                            Stepper("PITCH  \(viewModel.pitchShift) SEMITONES", value: $viewModel.pitchShift, in: -24...24)
                        }
                        VoiceCatalogNotice(state: catalog, onRefresh: onRefreshVoices)
                    } else {
                        TextField("Describe the sound to extract, e.g. lead vocals", text: $viewModel.description)
                        Text("Saves the extracted sound and the remaining audio to Library.")
                            .font(Typography.help)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .disabled(viewModel.isRunning)
            }
            VStack(alignment: .leading, spacing: 8) {
                PrimaryActionButton(title: viewModel.isRunning ? "PROCESSING…" : (viewModel.phase.offersRetry ? "RETRY \(viewModel.operation.rawValue)" : viewModel.operation.rawValue),
                                    isEnabled: canStart,
                                    action: { viewModel.start() })
                if !canStart {
                    Text(disabledReason).font(Typography.help).foregroundColor(Palette.ink.opacity(0.75))
                }
                if viewModel.isRunning { Button("CANCEL", action: viewModel.cancel) }
                Button("OPEN LIBRARY", action: onOpenLibrary)
            }
            WorkflowStatusView(status: viewModel.phase, elapsed: viewModel.elapsed)
            if viewModel.phase == .done {
                Text("Saved \(viewModel.results.count) output(s) to Library.")
                ForEach(viewModel.results) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(Typography.label)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        if item.kind == .audio, let library {
                            MiniWaveform(item: item, library: library)
                        }
                        if item.kind == .audio, let player, let library {
                            InlinePlayButton(player: player, item: item, library: library)
                        }
                        if item.kind == .midi, let midiPreview, let library {
                            InlineMidiButton(midiPreview: midiPreview, item: item, library: library)
                        }
                        if let router {
                            // One row per output: stem-split returns a target and a
                            // residual whose useful chains differ (swap the vocal,
                            // remix the residual), so the latest result is not enough.
                            NextActionsRow(router: router, item: item)
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                guard !viewModel.isRunning else { return }
                importError = nil
                viewModel.sourceURL = url
            case .failure(let error):
                importError = "Could not select audio: \(error.localizedDescription). Choose another file."
            }
        }
    }
}

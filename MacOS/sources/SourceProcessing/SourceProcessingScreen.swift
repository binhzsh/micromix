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
    var voiceCatalog: VoiceCatalogState? = nil
    var onRefreshVoices: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var midiPreview: MidiPreview? = nil
    var library: LocalLibrary? = nil
    @State private var isImporting = false

    private var catalog: VoiceCatalogState {
        voiceCatalog ?? (localInferenceAvailable ? .loading : .unavailable)
    }

    private var canStart: Bool {
        let direction = viewModel.operation == .vocalSwap ? viewModel.voiceModel : viewModel.description
        return localInferenceAvailable && !viewModel.isRunning && viewModel.sourceURL != nil
            && !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (viewModel.operation != .vocalSwap || catalog.voices.contains(direction))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeckPanel {
                HStack {
                    Typography.monoLabel("SOURCE", size: 11)
                    Button(viewModel.sourceURL?.lastPathComponent ?? "SELECT AUDIO") { isImporting = true }
                    Spacer()
                }
                .disabled(viewModel.isRunning)
            }
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
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .disabled(viewModel.isRunning)
            }
            HStack {
                PrimaryActionButton(title: viewModel.isRunning ? "PROCESSING…" : viewModel.operation.rawValue,
                                    isEnabled: canStart,
                                    action: { viewModel.start() })
                if viewModel.isRunning { Button("CANCEL", action: viewModel.cancel) }
                Button("OPEN LIBRARY", action: onOpenLibrary)
            }
            if let error = viewModel.errorMessage { Text(error).foregroundStyle(Palette.accentRed) }
            if viewModel.phase == .done {
                Text("Saved \(viewModel.results.count) output(s) to Library.")
                ForEach(viewModel.results) { item in
                    HStack(alignment: .center, spacing: 8) {
                        Typography.monoLabel(item.title, size: 9)
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
            if case .success(let url) = result { viewModel.sourceURL = url }
        }
    }
}

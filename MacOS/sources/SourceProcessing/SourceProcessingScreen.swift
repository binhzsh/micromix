import SwiftUI
import UniformTypeIdentifiers

struct SourceProcessingScreen: View {
    @ObservedObject var viewModel: SourceProcessingViewModel
    var voices: [String] = []
    var serverAvailable = true
    var onOpenLibrary: () -> Void = {}
    @State private var isImporting = false

    private var canStart: Bool {
        let direction = viewModel.operation == .vocalSwap ? viewModel.voiceModel : viewModel.description
        return serverAvailable && !viewModel.isRunning && viewModel.sourceURL != nil
            && !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        Picker("VOICE MODEL", selection: $viewModel.voiceModel) {
                            Text("Select a voice").tag("")
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                        }
                        Stepper("PITCH  \(viewModel.pitchShift) SEMITONES", value: $viewModel.pitchShift, in: -24...24)
                        if voices.isEmpty {
                            Text("No local voice models found. Install a voice model and refresh.")
                                .foregroundStyle(.secondary)
                        }
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
            if viewModel.phase == .done { Text("Saved \(viewModel.results.count) output(s) to Library.") }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { viewModel.sourceURL = url }
        }
    }
}

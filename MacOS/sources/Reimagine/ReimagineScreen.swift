import SwiftUI
import UniformTypeIdentifiers

/// REIMAGINE mode: source-first controls for reference generation, full-track
/// remixing, and bounded repainting.
struct ReimagineScreen: View {
    @ObservedObject var viewModel: ReimagineViewModel
    var localInferenceAvailable: Bool = true
    var modelStatuses: [String: String] = [:]
    var generationCatalog: GenerationCatalogState = .loaded(GenerationPreset.legacyPresets)
    var analysisAvailable: Bool = true
    var onAnalyzeSource: (URL) -> Void = { _ in }
    var onOpenLibrary: () -> Void = {}
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var library: LocalLibrary? = nil
    var onShowInLibrary: (LibraryItem) -> Void = { _ in }

    @State private var isImporting = false
    @State private var showAdvanced = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceSection
            operationSection
            directionSection
            renderSection
        }
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: selectSource
        )
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceChooser(name: viewModel.sourceURL?.lastPathComponent,
                          hint: "Choose audio as the basis for your new track.",
                          accessibilityHint: "Choose an audio file to reimagine",
                          isDisabled: viewModel.isRunning, error: importError,
                          choose: { isImporting = true })
            Button("ANALYZE SOURCE") {
                guard let sourceURL = viewModel.sourceURL else { return }
                onAnalyzeSource(sourceURL)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Palette.ink.opacity(0.58))
            .disabled(viewModel.sourceURL == nil || viewModel.isRunning || !analysisAvailable)
            if viewModel.sourceURL != nil && !analysisAvailable {
                Text("On-device analysis is unavailable.")
                    .font(.caption).foregroundColor(Palette.ink.opacity(0.75))
            }
        }
    }

    private var operationSection: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("OPERATION")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(operations, id: \.rawValue) { operation in
                            operationButton(operation)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(operations, id: \.rawValue) { operation in
                            operationButton(operation)
                        }
                    }
                }
                Text(operationHelp)
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.76))
            }
        }
    }

    private var directionSection: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("MUSICAL DIRECTION")
                    compactTextField("PROMPT", text: $viewModel.prompt)
                    compactTextField("LYRICS", text: $viewModel.lyrics)
                        .disabled(!viewModel.useLyrics)
                    Toggle(isOn: $viewModel.useLyrics) {
                        Typography.monoLabel("USE LYRICS", size: 9)
                            .foregroundColor(Palette.ink.opacity(0.72))
                    }
                        .toggleStyle(PanelToggleStyle())
                        .frame(width: 138)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("PRESET")
                    HStack {
                        ForEach(generationCatalog.presets(for: viewModel.operation.capabilityOperation)) { preset in
                            presetButton(preset.label.uppercased(), value: preset.id)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        compactTextField("SEED", text: $viewModel.seedText, width: 142)
                        compactTextField("BPM", text: $viewModel.bpmText, width: 78)
                            .disabled(viewModel.operation != .reference)
                        compactTextField("KEY", text: $viewModel.key, width: 88)
                            .disabled(viewModel.operation != .reference)
                        compactTextField("METER", text: $viewModel.timeSignature, width: 88)
                            .disabled(viewModel.operation != .reference)
                        if viewModel.operation == .reference {
                            Picker("Vocal language", selection: $viewModel.vocalLanguage) {
                                ForEach(VocalLanguage.allCases) { language in
                                    Text(language.label).tag(language)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                } label: {
                    Text(viewModel.hasAdvancedSettings ? "Advanced settings · customized" : "Advanced settings")
                }
            }
            .disabled(viewModel.isRunning)
        }
    }

    private var renderSection: some View {
        let canCancel = viewModel.isRunning
        return DeckPanel {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("RENDER")
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) { renderControls }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 10) { renderControls }
                    }
                }
                .disabled(viewModel.isRunning)

                VStack(alignment: .leading, spacing: 8) {
                    PrimaryActionButton(
                        title: viewModel.isRunning ? "REIMAGINING…" : (viewModel.phase.offersRetry ? "RETRY REIMAGINING" : "START REIMAGINING"),
                        isEnabled: canStart,
                        action: {
                            guard canStart, let preset = generationCatalog.preset(id: viewModel.preset) else { return }
                            _ = viewModel.start(capabilities: preset)
                        }
                    )
                    .accessibilityHint(canStart ? "Starts the Reimagine render" : unavailableReason)
                    if !canStart && !viewModel.isRunning {
                        Text(unavailableReason).font(Typography.body(12)).foregroundColor(Palette.ink.opacity(0.76))
                    }

                    Button("CANCEL", action: viewModel.cancel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(canCancel ? Palette.textRed : Palette.ink.opacity(0.52))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(canCancel ? Palette.textRed : Palette.divider, lineWidth: 1.5)
                        )
                        .buttonStyle(.plain)
                        .disabled(!canCancel)

                    Button("OPEN LIBRARY", action: onOpenLibrary)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.72))
                        .buttonStyle(.borderless)
                }

                if viewModel.operation == .repaint, viewModel.sourceURL != nil {
                    Text(viewModel.sourceDurationSeconds.map {
                        "Source duration: \(String(format: "%.2f", $0)) seconds. Repaint range: 3–90 seconds."
                    } ?? "Source duration unavailable; the repaint range cannot be checked against the source.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.72))
                }
                WorkflowStatusView(status: viewModel.phase, elapsed: viewModel.elapsed)
                if viewModel.phase == .done, let library {
                    SelectedResultSurface(results: viewModel.results, router: router, player: player,
                                          library: library, onShowInLibrary: onShowInLibrary)
                }
            }
        }
    }

    @ViewBuilder private var renderControls: some View {
        Stepper("VARIATIONS  \(viewModel.variationCount)", value: $viewModel.variationCount, in: 1...4)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Palette.ink.opacity(0.72))
            .fixedSize()
        operationControl
    }

    @ViewBuilder private var operationControl: some View {
        switch viewModel.operation {
        case .reference:
            VStack(alignment: .leading, spacing: 3) {
                Typography.monoLabel("DURATION  \(Int(viewModel.durationSeconds)) SEC", size: 9)
                Slider(value: $viewModel.durationSeconds, in: 10...600, step: 5)
                    .tint(Palette.textOrange)
                    .frame(width: 150)
            }
            .foregroundColor(Palette.ink.opacity(0.72))
        case .remix:
            VStack(alignment: .leading, spacing: 3) {
                Typography.monoLabel(
                    "SOURCE STRENGTH  \(String(format: "%.2f", viewModel.sourceStrength))",
                    size: 9
                )
                Slider(value: $viewModel.sourceStrength, in: 0...1, step: 0.05)
                    .tint(Palette.textOrange)
                    .frame(width: 150)
            }
            .foregroundColor(Palette.ink.opacity(0.72))
        case .repaint:
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Typography.monoLabel("START (SEC)", size: 9)
                    compactNumberField("START", value: $viewModel.startSeconds)
                        .accessibilityLabel("Repaint start in seconds")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Typography.monoLabel("END (SEC)", size: 9)
                    compactNumberField("END", value: $viewModel.endSeconds)
                        .accessibilityLabel("Repaint end in seconds")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Typography.monoLabel(
                        "STRENGTH  \(String(format: "%.2f", viewModel.repaintStrength))",
                        size: 9
                    )
                    Slider(value: $viewModel.repaintStrength, in: 0...1, step: 0.05)
                        .tint(Palette.textOrange)
                        .frame(width: 110)
                }
            }
            .foregroundColor(Palette.ink.opacity(0.72))
        }
    }

    private var requiredModel: String {
        WorkflowReadiness.generationModel(preset: viewModel.preset, catalog: generationCatalog)
    }

    var capabilityIssue: String? {
        generationCatalog.selectionIssue(id: viewModel.preset, operation: viewModel.operation.capabilityOperation)
            ?? viewModel.capabilityIssue(for: generationCatalog.preset(id: viewModel.preset))
    }

    var canStart: Bool {
        localInferenceAvailable
            && capabilityIssue == nil
            && !WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [requiredModel])
            && !viewModel.isRunning
            && viewModel.sourceURL != nil
            && !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var unavailableReason: String {
        if !localInferenceAvailable { return "Local inference is unavailable. Start the local sidecar and retry." }
        if let capabilityIssue { return capabilityIssue }
        if WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [requiredModel]) { return WorkflowReadiness.description(connected: true, statuses: modelStatuses, models: [requiredModel]) }
        if viewModel.isRunning { return "A Reimagine render is already running" }
        if viewModel.sourceURL == nil { return "Select an audio source first" }
        return "Enter a prompt first"
    }

    private var operationHelp: String {
        switch viewModel.operation {
        case .reference: "Use the source as musical guidance for a new track."
        case .remix: "Reshape the full source while preserving its identity."
        case .repaint: "Replace a selected time range inside the source."
        }
    }

    private var operations: [ReimagineOperation] {
        [.reference, .remix, .repaint]
    }

    private func operationButton(_ operation: ReimagineOperation) -> some View {
        let selected = viewModel.operation == operation
        return Button {
            viewModel.operation = operation
        } label: {
            VStack(spacing: 5) {
                Text(operation.rawValue.uppercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(selected ? Palette.screenText : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Rectangle()
                    .fill(selected ? Palette.textBlue : Color.clear)
                    .frame(width: 38, height: 3)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? Palette.ink : Palette.deck)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Palette.ink.opacity(0.85), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRunning)
        .accessibilityLabel("\(operation.rawValue.capitalized) operation")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected ? "Current operation" : "Selects this operation")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.capitalized)
            .font(Typography.heading)
            .foregroundColor(Palette.ink)
    }

    private func compactTextField(
        _ placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder.capitalized)
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.68))
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Typography.body())
                .foregroundColor(Palette.ink)
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.divider, lineWidth: 1))
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
    }

    private func compactNumberField(_ placeholder: String, value: Binding<Double>) -> some View {
        TextField(placeholder, value: value, format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.plain)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(Palette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.divider, lineWidth: 1))
            .frame(width: 62)
    }

    private func presetButton(_ title: String, value: String) -> some View {
        let selected = viewModel.preset == value
        return Button(title) { viewModel.preset = value }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(selected ? .white : Palette.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Palette.ink : Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.divider, lineWidth: 1))
            .buttonStyle(.plain)
    }

    private func selectSource(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importError = nil
            viewModel.sourceURL = url
        case .failure(let error):
            importError = "Could not select audio: \(error.localizedDescription). Choose another file."
        }
    }
}

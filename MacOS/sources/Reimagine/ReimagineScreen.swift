import SwiftUI
import UniformTypeIdentifiers

/// REIMAGINE mode: source-first controls for reference generation, full-track
/// remixing, and bounded repainting.
struct ReimagineScreen: View {
    @ObservedObject var viewModel: ReimagineViewModel
    var serverAvailable: Bool = true
    var analysisAvailable: Bool = true
    var onAnalyzeSource: (URL) -> Void = { _ in }
    var onOpenLibrary: () -> Void = {}

    @State private var isImporting = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                sourceSection
                operationSection
                directionSection
                renderSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: selectSource
        )
    }

    private var sourceSection: some View {
        DeckPanel(borderColor: viewModel.sourceURL == nil ? Palette.divider : Palette.accentBlue) {
            HStack(spacing: 10) {
                sectionLabel("SOURCE")
                    .frame(width: 92, alignment: .leading)

                Button(action: { isImporting = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.sourceURL == nil ? "waveform" : "waveform.badge.checkmark")
                        Text(viewModel.sourceURL?.lastPathComponent ?? "SELECT AUDIO")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(viewModel.sourceURL == nil ? "CHOOSE" : "REPLACE")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(viewModel.sourceURL == nil ? Palette.ink : Palette.accentBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.deck)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunning)
                .frame(maxWidth: .infinity)

                Button("ANALYZE SOURCE") {
                    guard let sourceURL = viewModel.sourceURL else { return }
                    onAnalyzeSource(sourceURL)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.58))
                .disabled(viewModel.sourceURL == nil || viewModel.isRunning || !analysisAvailable)
            }
        }
    }

    private var operationSection: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    sectionLabel("OPERATION")
                        .frame(width: 92, alignment: .leading)
                    ForEach(operations, id: \.rawValue) { operation in
                        operationButton(operation)
                    }
                }
                Text(operationHelp)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.64))
                    .padding(.leading, 102)
            }
        }
    }

    private var directionSection: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    sectionLabel("MUSICAL DIRECTION")
                        .frame(width: 124, alignment: .leading)
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

                HStack(spacing: 10) {
                    sectionLabel("PRESET")
                        .frame(width: 124, alignment: .leading)
                    presetButton("XL TURBO", value: "turbo")
                    presetButton("XL QUALITY", value: "quality")
                    compactTextField("BPM", text: $viewModel.bpmText, width: 78)
                    compactTextField("KEY", text: $viewModel.key, width: 88)
                    compactTextField("METER", text: $viewModel.timeSignature, width: 88)
                    if viewModel.operation == .reference {
                        Picker("Vocal language", selection: $viewModel.vocalLanguage) {
                            ForEach(VocalLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    Spacer(minLength: 0)
                }
            }
            .disabled(viewModel.isRunning)
        }
    }

    private var renderSection: some View {
        let canCancel = viewModel.isRunning
        return DeckPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    sectionLabel("RENDER")
                        .frame(width: 92, alignment: .leading)
                    compactTextField("SEED", text: $viewModel.seedText, width: 142)
                    Stepper("VARIATIONS  \(viewModel.variationCount)", value: $viewModel.variationCount, in: 1...4)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.72))
                    operationControl
                    Spacer(minLength: 0)
                }
                .disabled(viewModel.isRunning)

                HStack(spacing: 8) {
                    PrimaryActionButton(
                        title: viewModel.isRunning ? "REIMAGINING…" : "START REIMAGINING",
                        isEnabled: canStart,
                        action: { _ = viewModel.start() }
                    )
                    .accessibilityHint(canStart ? "Starts the Reimagine render" : unavailableReason)

                    Button("CANCEL", action: viewModel.cancel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(canCancel ? Palette.accentRed : Palette.ink.opacity(0.52))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(canCancel ? Palette.accentRed : Palette.divider, lineWidth: 1.5)
                        )
                        .buttonStyle(.plain)
                        .disabled(!canCancel)

                    Button("OPEN LIBRARY", action: onOpenLibrary)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.72))
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var operationControl: some View {
        switch viewModel.operation {
        case .reference:
            VStack(alignment: .leading, spacing: 3) {
                Typography.monoLabel("DURATION  \(Int(viewModel.durationSeconds)) SEC", size: 9)
                Slider(value: $viewModel.durationSeconds, in: 10...600, step: 5)
                    .tint(Palette.accentOrange)
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
                    .tint(Palette.accentOrange)
                    .frame(width: 150)
            }
            .foregroundColor(Palette.ink.opacity(0.72))
        case .repaint:
            HStack(spacing: 6) {
                compactNumberField("START", value: $viewModel.startSeconds)
                compactNumberField("END", value: $viewModel.endSeconds)
                VStack(alignment: .leading, spacing: 3) {
                    Typography.monoLabel(
                        "STRENGTH  \(String(format: "%.2f", viewModel.repaintStrength))",
                        size: 9
                    )
                    Slider(value: $viewModel.repaintStrength, in: 0...1, step: 0.05)
                        .tint(Palette.accentOrange)
                        .frame(width: 110)
                }
            }
            .foregroundColor(Palette.ink.opacity(0.72))
        }
    }

    private var canStart: Bool {
        serverAvailable
            && !viewModel.isRunning
            && viewModel.sourceURL != nil
            && !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unavailableReason: String {
        if !serverAvailable { return "Server connection is unavailable" }
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
                    .fill(selected ? Palette.accentBlue : Color.clear)
                    .frame(width: 38, height: 3)
            }
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
        Typography.monoLabel(title, size: 10)
            .foregroundColor(Palette.ink.opacity(0.72))
            .accessibilityLabel(title)
    }

    private func compactTextField(
        _ placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.46))
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
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
        guard case .success(let urls) = result, let url = urls.first else { return }
        viewModel.sourceURL = url
    }
}

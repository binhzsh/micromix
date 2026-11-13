import SwiftUI

/// GENERATE mode: bounded text and lyrics inputs, compact engine controls, and
/// a primary action whose visual state reflects whether generation is ready.
struct GenerateScreen: View {
    @ObservedObject var viewModel: GenerateViewModel
    var localInferenceAvailable: Bool = true
    var modelStatuses: [String: String] = [:]
    var generationCatalog: GenerationCatalogState = .loaded(GenerationPreset.legacyPresets)
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var library: LocalLibrary? = nil
    var onShowInLibrary: (LibraryItem) -> Void = { _ in }
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Generate — text or lyrics")
                .font(Typography.heading)
                .foregroundColor(Palette.ink)

                VStack(alignment: .leading, spacing: 12) {
                    DeckPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $viewModel.useLyrics) {
                                Typography.monoLabel("USE LYRICS", size: 11)
                                    .foregroundColor(Palette.ink)
                            }
                            .toggleStyle(PanelToggleStyle())
                            .disabled(viewModel.isBlocked)

                            HStack(alignment: .top, spacing: 10) {
                                editorGroup(
                                    label: viewModel.useLyrics ? "PROMPT (OPTIONAL)" : "PROMPT",
                                    text: $viewModel.prompt,
                                    placeholder: "Describe the track, mood, instruments or arrangement"
                                )

                                if viewModel.useLyrics {
                                    editorGroup(
                                        label: "LYRICS",
                                        text: $viewModel.lyrics,
                                        placeholder: "Paste lyrics or write verse / chorus sections"
                                    )
                                }
                            }
                        }
                    }

                    DeckPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 24) {
                                    generationControls
                                }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 12) {
                                    generationControls
                                }
                            }
                        }
                        .disabled(viewModel.isBlocked)
                    }

                    DeckPanel {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .bottom, spacing: 12) { advancedFields }
                                    .fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 12) { advancedFields }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Typography.monoLabel("VOCAL LANGUAGE", size: 10)
                                    .foregroundColor(Palette.ink.opacity(0.68))
                                Picker("Vocal language", selection: $viewModel.vocalLanguage) {
                                    ForEach(VocalLanguage.allCases) { language in
                                        Text(language.label).tag(language)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 235)
                            }
                            }
                        } label: {
                            Text(hasAdvancedSettings ? "Advanced settings · customized" : "Advanced settings")
                        }
                        .disabled(viewModel.isBlocked)
                    }

                }

            HStack(spacing: 8) {
                PrimaryActionButton(
                    title: viewModel.isRunning ? "GENERATING…" : (viewModel.phase.offersRetry ? "RETRY GENERATION" : "GENERATE"),
                    isEnabled: canGenerate,
                    action: {
                        guard canGenerate, let preset = generationCatalog.preset(id: viewModel.preset) else { return }
                        viewModel.start(capabilities: preset)
                    }
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint(canGenerate ? "Starts music generation" : unavailableReason)

                if viewModel.isRunning {
                    cancelButton
                }
            }
            if !canGenerate && !viewModel.isRunning {
                Text(unavailableReason).font(Typography.body(12)).foregroundColor(Palette.ink.opacity(0.76))
            }

            WorkflowStatusView(status: viewModel.phase, elapsed: viewModel.elapsed)
            if viewModel.phase == .done, let library {
                SelectedResultSurface(results: viewModel.results, router: router, player: player,
                                      library: library, onShowInLibrary: onShowInLibrary)
            }
        }
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    @ViewBuilder private var advancedFields: some View {
        compactField("SEED", text: $viewModel.seedText, width: 120)
        compactField("BPM", text: $viewModel.bpmText, width: 72)
        compactField("KEY", text: $viewModel.key, width: 92)
        compactField("METER", text: $viewModel.timeSignature, width: 72)
    }

    @ViewBuilder private var generationControls: some View {
                            VStack(alignment: .leading, spacing: 6) {
                                Typography.monoLabel("ENGINE", size: 10)
                                    .foregroundColor(Palette.ink.opacity(0.68))
                                HStack(spacing: 6) {
                                    ForEach(generationCatalog.presets(for: "generation")) { preset in
                                        let selected = viewModel.preset == preset.id
                                        Button {
                                            viewModel.preset = preset.id
                                        } label: {
                                            Text(preset.label.uppercased())
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundColor(selected ? .white : Palette.ink)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(selected ? Palette.ink : Palette.deck)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(selected ? Palette.ink : Palette.divider, lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(preset.label) engine")
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Typography.monoLabel("DURATION  \(Int(viewModel.durationSeconds)) SEC", size: 10)
                                    .foregroundColor(Palette.ink.opacity(0.68))
                                Slider(value: $viewModel.durationSeconds, in: 10...120, step: 5)
                                    .tint(Palette.textOrange)
                                    .frame(width: 180)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Typography.monoLabel("VARIATIONS", size: 10)
                                    .foregroundColor(Palette.ink.opacity(0.68))
                                Stepper("\(viewModel.variationCount)", value: $viewModel.variationCount, in: 1...4)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 84)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Typography.monoLabel("FORMAT", size: 10)
                                    .foregroundColor(Palette.ink.opacity(0.68))
                                Text(viewModel.format.uppercased())
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Palette.ink)
                                    .padding(.vertical, 6)
                            }
    }

    private var hasAdvancedSettings: Bool {
        !viewModel.seedText.isEmpty || !viewModel.bpmText.isEmpty || !viewModel.key.isEmpty
            || !viewModel.timeSignature.isEmpty || viewModel.vocalLanguage != .automatic
    }

    private var requiredModel: String {
        WorkflowReadiness.generationModel(preset: viewModel.preset, catalog: generationCatalog)
    }

    var capabilityIssue: String? {
        generationCatalog.selectionIssue(id: viewModel.preset, operation: "generation")
            ?? viewModel.capabilityIssue(for: generationCatalog.preset(id: viewModel.preset))
    }

    var canGenerate: Bool {
        !viewModel.effectiveInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isBlocked
            && localInferenceAvailable
            && capabilityIssue == nil
            && !WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [requiredModel])
    }

    var unavailableReason: String {
        if !localInferenceAvailable { return "Local inference is unavailable. Start the local sidecar and retry." }
        if let capabilityIssue { return capabilityIssue }
        if WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: [requiredModel]) { return WorkflowReadiness.description(connected: true, statuses: modelStatuses, models: [requiredModel]) }
        if viewModel.isBlocked { return "Generation is already running" }
        return "Enter a prompt or lyrics first"
    }

    private func editor(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat,
        idealHeight: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(Typography.body(13))
                .foregroundColor(Palette.ink)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Palette.deck)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.68))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.divider, lineWidth: 1))
        .disabled(viewModel.isBlocked)
    }

    private func editorGroup(
        label: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.capitalized)
                .font(Typography.label)
                .foregroundColor(Palette.ink)
            editor(
                text: text,
                placeholder: placeholder,
                minHeight: 58,
                idealHeight: 70,
                maxHeight: 88
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactField(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Typography.monoLabel(label, size: 10)
                .foregroundColor(Palette.ink.opacity(0.68))
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Palette.deck)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.divider, lineWidth: 1))
                .frame(width: width)
        }
    }

    private var cancelButton: some View {
        Button(action: { viewModel.cancel() }) {
            Text("CANCEL")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(Palette.textRed)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Palette.textRed, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

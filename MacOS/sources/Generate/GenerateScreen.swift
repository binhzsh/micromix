import SwiftUI

/// GENERATE mode: bounded text and lyrics inputs, compact engine controls, and
/// a primary action whose visual state reflects whether generation is ready.
struct GenerateScreen: View {
    @ObservedObject var viewModel: GenerateViewModel
    var serverAvailable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Typography.monoLabel("1. GENERATE — TEXT OR LYRICS", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))

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
                            label: "PROMPT",
                            text: $viewModel.prompt,
                            placeholder: "DESCRIBE THE TRACK, MOOD, INSTRUMENTS OR ARRANGEMENT"
                        )

                        if viewModel.useLyrics {
                            editorGroup(
                                label: "LYRICS",
                                text: $viewModel.lyrics,
                                placeholder: "PASTE LYRICS OR WRITE VERSE / CHORUS SECTIONS"
                            )
                        }
                    }
                }
            }

            DeckPanel {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Typography.monoLabel("ENGINE", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.68))
                        HStack(spacing: 6) {
                            ForEach(["turbo", "quality"], id: \.self) { preset in
                                let selected = viewModel.preset == preset
                                Button {
                                    viewModel.preset = preset
                                } label: {
                                    Text(preset == "turbo" ? "XL TURBO" : "XL QUALITY")
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
                                .accessibilityLabel(preset == "turbo" ? "XL Turbo engine" : "XL Quality engine")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Typography.monoLabel("DURATION  \(Int(viewModel.durationSeconds)) SEC", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.68))
                        Slider(value: $viewModel.durationSeconds, in: 10...120, step: 5)
                            .tint(Palette.accentOrange)
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
                    Spacer(minLength: 0)
                }
                .disabled(viewModel.isBlocked)
            }

            DeckPanel {
                HStack(alignment: .bottom, spacing: 12) {
                    compactField("SEED", text: $viewModel.seedText, width: 120)
                    compactField("BPM", text: $viewModel.bpmText, width: 72)
                    compactField("KEY", text: $viewModel.key, width: 92)
                    compactField("METER", text: $viewModel.timeSignature, width: 72)
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
                    Spacer(minLength: 0)
                }
                .disabled(viewModel.isBlocked)
            }

            HStack(spacing: 8) {
                PrimaryActionButton(
                    title: viewModel.isRunning ? "GENERATING…" : "GENERATE",
                    isEnabled: canGenerate,
                    action: { viewModel.start() }
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint(canGenerate ? "Starts music generation" : unavailableReason)

                if viewModel.isRunning {
                    cancelButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var canGenerate: Bool {
        !viewModel.effectiveInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isBlocked
            && serverAvailable
    }

    private var unavailableReason: String {
        if !serverAvailable { return "Server connection is unavailable" }
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.46))
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
            Typography.monoLabel(label, size: 10)
                .foregroundColor(Palette.ink.opacity(0.68))
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
                .foregroundColor(Palette.accentRed)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Palette.accentRed, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

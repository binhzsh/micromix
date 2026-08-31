import SwiftUI

/// GENERATE mode: the text/lyrics editor deck plus the orange GENERATE action.
/// Screen readouts (elapsed, GENERATING, result/error) are rendered by the
/// enclosing `DeviceWindow` via `DotMatrixScreen`; this view owns the deck
/// inputs and fires the flow through `GenerateViewModel`.
struct GenerateScreen: View {
    @ObservedObject var viewModel: GenerateViewModel
    /// Whether the server is reachable; disables the primary action when down.
    var serverAvailable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Typography.monoLabel("1. GENERATE — TEXT OR LYRICS", size: 11)
                .foregroundColor(Palette.ink.opacity(0.6))

            // Prompt editor
            VStack(alignment: .leading, spacing: 6) {
                Typography.monoLabel("PROMPT", size: 10)
                    .foregroundColor(Palette.ink.opacity(0.5))
                TextEditor(text: $viewModel.prompt)
                    .font(Typography.body(13))
                    .foregroundColor(Palette.ink)
                    .frame(minHeight: 64)
                    .padding(6)
                    .background(Palette.deck)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.divider, lineWidth: 1))
                    .disabled(viewModel.isBlocked)
            }

            // Lyrics toggle + editor
            Toggle(isOn: $viewModel.useLyrics) {
                Typography.monoLabel("USE LYRICS", size: 11)
                    .foregroundColor(Palette.ink)
            }
            .toggleStyle(.switch)
            .disabled(viewModel.isBlocked)

            if viewModel.useLyrics {
                VStack(alignment: .leading, spacing: 6) {
                    Typography.monoLabel("LYRICS", size: 10)
                        .foregroundColor(Palette.ink.opacity(0.5))
                    TextEditor(text: $viewModel.lyrics)
                        .font(Typography.body(13))
                        .foregroundColor(Palette.ink)
                        .frame(minHeight: 56)
                        .padding(6)
                        .background(Palette.deck)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.divider, lineWidth: 1))
                        .disabled(viewModel.isBlocked)
                }
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Typography.monoLabel("ENGINE", size: 10)
                        .foregroundColor(Palette.ink.opacity(0.5))
                    Picker("ENGINE", selection: $viewModel.preset) {
                        Text("XL TURBO").tag("turbo")
                        Text("XL QUALITY").tag("quality")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Typography.monoLabel("DURATION  \(Int(viewModel.durationSeconds)) SEC", size: 10)
                        .foregroundColor(Palette.ink.opacity(0.5))
                    Slider(value: $viewModel.durationSeconds, in: 10...120, step: 5)
                        .frame(width: 180)
                }
                preset("FORMAT", value: viewModel.format.uppercased())
            }
            .disabled(viewModel.isBlocked)

            // Primary action (+ cancel while running)
            HStack(spacing: 8) {
                Button(action: { viewModel.start() }) {
                    Text(viewModel.phase == .running ? "GENERATING…" : "GENERATE")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(viewModel.phase == .running ? Palette.ink.opacity(0.6) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(viewModel.phase == .running ? Palette.ink.opacity(0.18) : Palette.accentOrange)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Palette.ink.opacity(0.85), lineWidth: 1.5)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.isBlocked || !serverAvailable)

                if viewModel.isRunning {
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
                    .buttonStyle(PlainButtonStyle())
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preset(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Typography.monoLabel(label, size: 10)
                .foregroundColor(Palette.ink.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.8))
        }
    }
}

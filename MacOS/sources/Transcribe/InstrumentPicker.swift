import SwiftUI

/// Instrument multi-pick, populated from the flattened `/instruments` list.
/// Each row toggles a single instrument on the view model's selection.
struct InstrumentPicker: View {
    @ObservedObject var viewModel: TranscribeViewModel
    let instruments: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Typography.monoLabel("INSTRUMENTS", size: 10)
                .foregroundColor(Palette.ink.opacity(0.68))

            if instruments.isEmpty {
                Text("NO INSTRUMENTS — CHECK SERVER")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.64))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.divider, lineWidth: 1))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(instruments.enumerated()), id: \.element) { index, name in
                            row(name: name, selected: viewModel.instruments.contains(name))
                            Divider().overlay(Palette.divider.opacity(0.5))
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(Palette.deck)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.divider, lineWidth: 1))
            }
        }
    }

    private func row(name: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? Palette.accentBlue : Color.clear)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(selected ? Palette.accentBlue : Palette.ink.opacity(0.48), lineWidth: 1.25)
                )
                .overlay {
                    if selected {
                        Text("✓")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
            Text(displayName(name))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(selected ? 1 : 0.72))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Palette.accentBlue.opacity(0.10) : Color.clear)
        .onTapGesture { viewModel.toggleInstrument(name) }
        .accessibilityLabel(displayName(name))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }

    private func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

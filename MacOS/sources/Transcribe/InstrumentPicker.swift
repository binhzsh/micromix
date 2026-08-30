import SwiftUI

/// Instrument multi-pick, populated from the flattened `/instruments` list.
/// Each row toggles a single instrument on the view model's selection.
struct InstrumentPicker: View {
    @ObservedObject var viewModel: TranscribeViewModel
    let instruments: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Typography.monoLabel("INSTRUMENTS", size: 10)
                .foregroundColor(Palette.ink.opacity(0.5))

            if instruments.isEmpty {
                Text("NO INSTRUMENTS — CHECK SERVER")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.5))
                    .padding(8)
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
                .frame(maxHeight: 140)
            }
        }
    }

    private func row(name: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(selected ? "▪" : "▫")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(selected ? Palette.accentBlue : Palette.ink.opacity(0.4))
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(selected ? 1 : 0.6))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selected ? Palette.accentBlue.opacity(0.10) : Color.clear)
        .onTapGesture { viewModel.toggleInstrument(name) }
    }
}
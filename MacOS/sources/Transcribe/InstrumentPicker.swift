import SwiftUI

/// Instrument multi-pick, populated from the flattened `/instruments` list.
/// Each row toggles a single instrument on the view model's selection.
struct InstrumentPicker: View {
    @ObservedObject var viewModel: TranscribeViewModel
    let instruments: [String]
    var catalog: VoiceCatalogState? = nil
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Typography.monoLabel("INSTRUMENTS", size: 10)
                .foregroundColor(Palette.ink.opacity(0.68))

            if let message = Self.catalogMessage(catalog, hasItems: !instruments.isEmpty) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.64))
                    if catalog == .failed || catalog == .unavailable {
                        Button("Refresh catalog", action: onRefresh)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.divider, lineWidth: 1))
            }
            if !instruments.isEmpty {
                LazyVStack(spacing: 2) {
                    ForEach(instruments, id: \.self) { name in
                        row(name: name, selected: viewModel.instruments.contains(name))
                        Divider().overlay(Palette.divider.opacity(0.5))
                    }
                }
                .background(Palette.deck)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.divider, lineWidth: 1))
            }
        }
    }

    static func catalogMessage(_ catalog: VoiceCatalogState?, hasItems: Bool) -> String? {
        let cached = hasItems ? " — SHOWING CACHED INSTRUMENTS" : ""
        switch catalog {
        case .unavailable: return "LOCAL INFERENCE UNAVAILABLE" + cached
        case .loading: return "LOADING INSTRUMENT CATALOG…" + cached
        case .failed: return "INSTRUMENT CATALOG FETCH FAILED" + cached
        case .loaded, .none: return hasItems ? nil : "INSTRUMENT CATALOG IS EMPTY"
        }
    }

    static func selectionSummary(_ instruments: [String]) -> String {
        guard !instruments.isEmpty else { return "All instruments" }
        let names = instruments.map(displayName)
        let visible = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(visible) +\(names.count - 2)" : visible
    }

    private func row(name: String, selected: Bool) -> some View {
        Toggle(Self.displayName(name), isOn: Binding(
            get: { selected },
            set: { if $0 != selected { viewModel.toggleInstrument(name) } }
        ))
        .toggleStyle(.checkbox)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .disabled(viewModel.isBlocked)
    }

    private static func displayName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

import SwiftUI

/// The three user flows. Mode buttons on the deck switch between them.
enum DeviceMode: String, CaseIterable, Identifiable {
    case generate = "GENERATE"
    case transcribe = "TRANSCRIBE"
    case library = "LIBRARY"

    var id: String { rawValue }
}

/// Single-window device-panel chassis: a recessed dark screen panel (~60%)
/// on top and a light control deck (~40%) below, inside a rounded frame.
///
/// v1 scaffold wires the mode switcher; each mode's screen and deck content
/// are placeholder panels filled in by later tasks.
struct DeviceWindow: View {
    @Binding var selectedMode: DeviceMode

    var body: some View {
        VStack(spacing: 0) {
            ScreenRegion(mode: selectedMode)
            DeckRegion(selectedMode: $selectedMode)
        }
        .background(Palette.deck)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.ink.opacity(0.85), lineWidth: 1.5)
        )
        .padding(18)
        .background(LinearGradient(
            colors: [Palette.ink.opacity(0.35), Palette.ink.opacity(0.12)],
            startPoint: .top, endPoint: .bottom
        ))
    }
}

// MARK: - Screen region (top ~60%)

private struct ScreenRegion: View {
    let mode: DeviceMode

    var body: some View {
        ZStack {
            Palette.screen
            DotMatrixScreen(
                title: "MICROMIX",
                statusLine: statusLine,
                readout: "00:00"
            )
        }
        .overlay(ScanlinesOverlay())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .frame(height: 400)
    }

    private var statusLine: String {
        switch mode {
        case .generate: return "READY — ENTER PROMPT"
        case .transcribe: return "READY — SELECT AUDIO"
        case .library: return "NO ITEMS"
        }
    }
}

// MARK: - Deck region (bottom ~40%)

private struct DeckRegion: View {
    @Binding var selectedMode: DeviceMode

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Typography.monoLabel("1. GENERATE   2. TRANSCRIBE   3. LIBRARY", size: 11)
                .foregroundColor(Palette.ink.opacity(0.6))

            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(DeviceMode.allCases) { mode in
                    PanelButton(
                        title: mode.rawValue,
                        index: index(of: mode),
                        isActive: mode == selectedMode,
                        action: { selectedMode = mode }
                    )
                }
            }

            Text("MODE CONTROLS — PLACEHOLDER")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(Palette.ink.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .padding(16)
                .background(Palette.deck)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.divider, lineWidth: 1))

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.deck)
    }

    private func index(of mode: DeviceMode) -> Int {
        DeviceMode.allCases.firstIndex(of: mode) ?? 0
    }
}

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
/// Owns the three flows' view models and shared infra (audio/MIDI playback,
/// connection health), renders the active mode's screen + deck, and drives the
/// connection LED + error banners.
struct DeviceWindow: View {
    @State private var selectedMode: DeviceMode = .generate
    @State private var selectedID: UUID?

    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor

    /// Instruments for the transcribe picker (fetched at launch / refresh).
    @State private var instruments: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScreenRegion(mode: selectedMode, connection: connection)
            DeckRegion(
                mode: $selectedMode,
                generate: generate,
                transcribe: transcribe,
                library: library,
                player: player,
                midiPreview: midiPreview,
                connection: connection,
                instruments: $instruments,
                selectedID: $selectedID
            )
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
    @ObservedObject var connection: ConnectionMonitor

    var body: some View {
        ZStack {
            Palette.screen
            DotMatrixScreen(
                title: "MICROMIX",
                statusLine: statusLine,
                readout: "00:00",
                readoutColor: readoutColor
            )
        }
        .overlay(ScanlinesOverlay())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .frame(height: 400)
    }

    private var readoutColor: Color {
        connection.isConnected ? Palette.screenText : Palette.accentRed
    }

    private var statusLine: String {
        guard connection.isConnected else { return "SERVER UNREACHABLE — CHECK WIREGUARD" }
        switch mode {
        case .generate: return "READY — ENTER PROMPT"
        case .transcribe: return "READY — SELECT AUDIO"
        case .library: return "NO ITEMS"
        }
    }
}

// MARK: - Deck region (bottom ~40%)

private struct DeckRegion: View {
    @Binding var mode: DeviceMode
    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor

    @Binding var instruments: [String]
    @Binding var selectedID: UUID?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Typography.monoLabel("1. GENERATE   2. TRANSCRIBE   3. LIBRARY", size: 11)
                    .foregroundColor(Palette.ink.opacity(0.6))
                Spacer()
                connectionRow
            }

            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(DeviceMode.allCases) { m in
                    PanelButton(
                        title: m.rawValue,
                        index: index(of: m),
                        isActive: m == mode,
                        action: { mode = m }
                    )
                }
            }

            modeControls

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.deck)
    }

    // MARK: - Mode controls

    @ViewBuilder private var modeControls: some View {
        switch mode {
        case .generate:
            GenerateScreen(viewModel: generate)
        case .transcribe:
            TranscribeScreen(viewModel: transcribe, instruments: instruments)
        case .library:
            LibraryScreen(
                library: library,
                player: player,
                midiPreview: midiPreview,
                selectedID: $selectedID
            )
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 6) {
            LED(
                color: connection.isConnected ? .green : .red,
                blinking: !connection.isConnected
            )
            Text(connection.isConnected ? "LINK OK" : "NO LINK")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.6))
                .tracking(1.0)
        }
    }

    private func index(of mode: DeviceMode) -> Int {
        DeviceMode.allCases.firstIndex(of: mode) ?? 0
    }
}
import SwiftUI

/// The studio workspaces. Mode buttons on the deck switch between them.
enum DeviceMode: String, CaseIterable, Identifiable {
    case generate = "GENERATE"
    case reimagine = "REIMAGINE"
    case analyze = "ANALYZE"
    case transcribe = "TRANSCRIBE"
    case library = "LIBRARY"

    var id: String { rawValue }

    var displayIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

// REIMAGINE screen contract, in order:
// SOURCE (file picker, selected-file summary, Analyze source affordance),
// OPERATION (Reference, Remix, Repaint selector with one sentence of help),
// MUSICAL DIRECTION (prompt/lyrics, preset, editable BPM/key/meter),
// RENDER (seed, variation count, operation-specific strength/range, Start/Cancel).
// GENERATE remains text-first; ANALYZE inspection-first; TRANSCRIBE conversion-first;
// LIBRARY result-first. Reimagine links to Analyze and Library rather than embedding
// analysis history, playback, or a second asset browser.

/// Single-window device-panel chassis with a compact recessed status screen
/// above the light control deck, inside a rounded frame.
///
/// Owns the three flows' view models and shared infra (audio/MIDI playback,
/// connection health), renders the active mode's screen + deck, and drives the
/// connection LED + error banners.
struct DeviceWindow: View {
    @State private var selectedMode: DeviceMode = .generate
    @State private var selectedID: UUID?

    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var reimagine: ReimagineViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var analyze: AnalyzeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var reattacher: JobReattacher
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor

    var body: some View {
        VStack(spacing: 0) {
            ScreenRegion(
                mode: selectedMode,
                generate: generate,
                reimagine: reimagine,
                transcribe: transcribe,
                analyze: analyze,
                library: library,
                reattacher: reattacher,
                connection: connection
            )
            DeckRegion(
                mode: $selectedMode,
                generate: generate,
                reimagine: reimagine,
                transcribe: transcribe,
                analyze: analyze,
                library: library,
                player: player,
                midiPreview: midiPreview,
                connection: connection,
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

// MARK: - Screen region

private struct ScreenRegion: View {
    let mode: DeviceMode
    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var reimagine: ReimagineViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var analyze: AnalyzeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var reattacher: JobReattacher
    @ObservedObject var connection: ConnectionMonitor

    var body: some View {
        ZStack {
            Palette.screen
            DotMatrixScreen(
                title: "MICROMIX / \(mode.rawValue)",
                statusLine: statusLine,
                readout: readout,
                readoutColor: readoutColor
            )
        }
        .overlay(ScanlinesOverlay())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .frame(height: 200)
    }

    private var readoutColor: Color {
        if mode == .analyze || mode == .library { return Palette.screenText }
        return connection.isConnected ? Palette.screenText : Palette.accentRed
    }

    /// Live big readout: elapsed time while a job runs, result/error text after.
    private var readout: String {
        switch mode {
        case .generate:
            if generate.isRunning { return format(elapsed: generate.elapsed) }
            if case .error(let message) = generate.phase { return shorten(message) }
            if generate.phase == .done { return "GENERATED" }
            if generate.phase == .cancelled { return "CANCELLED" }
        case .reimagine:
            if reimagine.isRunning { return "REIMAGINING" }
            if let message = reimagine.errorMessage { return shorten(message) }
            if reimagine.phase == .done { return "REIMAGINED" }
            if reimagine.phase == .cancelled { return "CANCELLED" }
        case .analyze:
            if analyze.isRunning { return "ANALYZING" }
            if analyze.analysis != nil { return "UNDERSTOOD" }
            if let error = analyze.error { return shorten(error) }
        case .transcribe:
            if transcribe.isRunning { return format(elapsed: transcribe.elapsed) }
            if case .error(let message) = transcribe.phase { return shorten(message) }
            if transcribe.phase == .done { return "TRANSCRIBED" }
            if transcribe.phase == .cancelled { return "CANCELLED" }
        case .library:
            break
        }
        return "00:00"
    }

    private var statusLine: String {
        switch reattacher.status {
        case .recovering(let count), .pending(let count):
            return "RECOVERING — \(count) JOB\(count == 1 ? "" : "S")"
        case .unavailable(let count):
            return "RECOVERY PENDING — \(count) JOB\(count == 1 ? "" : "S")"
        case .missing(let count):
            return "REMOTE JOB UNAVAILABLE — \(count)"
        case .idle:
            break
        }
        switch mode {
        case .generate:
            guard connection.isConnected else { return "SERVER UNREACHABLE — CHECK WIREGUARD" }
            return generate.isRunning ? "GENERATING…" : "READY — ENTER PROMPT"
        case .reimagine:
            guard connection.isConnected else { return "SERVER UNREACHABLE — CHECK WIREGUARD" }
            if reimagine.isRunning { return "RENDERING VARIATIONS…" }
            return reimagine.sourceURL == nil ? "READY — SELECT A SOURCE" : "READY — SET DIRECTION"
        case .analyze:
            return analyze.isRunning ? "ANALYZING LOCALLY…" : "READY — SELECT AUDIO"
        case .transcribe:
            guard connection.isConnected else { return "SERVER UNREACHABLE — CHECK WIREGUARD" }
            return transcribe.isRunning ? "TRANSCRIBING…" : "READY — SELECT AUDIO"
        case .library: return "LIBRARY"
        }
    }

    private func format(elapsed: TimeInterval) -> String {
        let m = Int(elapsed) / 60
        let s = Int(elapsed) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func shorten(_ s: String) -> String {
        s.count > 42 ? String(s.prefix(41)) + "…" : s
    }
}

// MARK: - Deck region

private struct DeckRegion: View {
    @Binding var mode: DeviceMode
    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var reimagine: ReimagineViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var analyze: AnalyzeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor

    @Binding var selectedID: UUID?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Typography.monoLabel("MODE SELECT", size: 10)
                    .foregroundColor(Palette.ink.opacity(0.72))
                Spacer()
                connectionRow
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(DeviceMode.allCases) { m in
                    PanelButton(
                        title: m.rawValue,
                        index: m.displayIndex,
                        isActive: m == mode,
                        action: { mode = m }
                    )
                }
            }

            Divider().overlay(Palette.divider)

            modeControls
                .frame(maxWidth: 1_120, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.deck)
    }

    // MARK: - Mode controls

    @ViewBuilder private var modeControls: some View {
        switch mode {
        case .generate:
            GenerateScreen(viewModel: generate, serverAvailable: connection.isConnected)
        case .reimagine:
            ReimagineScreen(
                viewModel: reimagine,
                serverAvailable: connection.isConnected,
                analysisAvailable: !analyze.isRunning,
                onAnalyzeSource: { url in
                    guard !analyze.isRunning else { return }
                    analyze.analyze(url: url)
                    mode = .analyze
                },
                onOpenLibrary: { mode = .library }
            )
        case .analyze:
            AnalyzeScreen(viewModel: analyze)
        case .transcribe:
            TranscribeScreen(
                viewModel: transcribe,
                instruments: connection.instruments,
                serverAvailable: connection.isConnected
            )
        case .library:
            LibraryScreen(
                library: library,
                player: player,
                midiPreview: midiPreview,
                selectedID: $selectedID,
                onGenerate: { mode = .generate },
                onTranscribe: { mode = .transcribe }
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
                .foregroundColor(Palette.ink.opacity(0.72))
                .tracking(1.0)
        }
    }

}

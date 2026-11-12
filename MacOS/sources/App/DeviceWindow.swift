import AppKit
import SwiftUI

/// The focused tools available in the Micromix studio.
enum DeviceMode: String, CaseIterable, Identifiable {
    case generate = "GENERATE"
    case reimagine = "REIMAGINE"
    case analyze = "ANALYZE"
    case transcribe = "TRANSCRIBE"
    case vocalSwap = "VOCAL SWAP"
    case stemSplit = "STEM SPLIT"
    case library = "LIBRARY"
    case guide = "GUIDE"

    var id: String { rawValue }

    /// Workspaces that take part in numbered mode switching (⌘1…⌘7).
    var isSelectableMode: Bool { self != .guide }

    var displayIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    var symbolName: String {
        switch self {
        case .generate: "sparkles"
        case .reimagine: "waveform.badge.magnifyingglass"
        case .analyze: "chart.bar.xaxis"
        case .transcribe: "music.note.list"
        case .vocalSwap: "person.wave.2"
        case .stemSplit: "square.split.2x2"
        case .library: "rectangle.stack"
        case .guide: "questionmark.circle"
        }
    }

    var workspaceDescription: String {
        switch self {
        case .generate: "Create a new local music idea."
        case .reimagine: "Transform an existing audio source."
        case .analyze: "Inspect musical details from an audio source."
        case .transcribe: "Turn audio into editable MIDI."
        case .vocalSwap: "Convert a prepared vocal to a private voice."
        case .stemSplit: "Separate a source into useful stems."
        case .library: "Browse, compare, and continue every saved result."
        case .guide: "Follow an end-to-end creative workflow."
        }
    }
}

/// A cohesive workspace shell: tools stay visible in the left rail, each tool
/// renders in the central canvas, and shared session state remains available in
/// the inspector rather than being duplicated inside every workflow.
struct DeviceWindow: View {
    @State private var selectedMode: DeviceMode = .generate
    @State private var selectedID: UUID?
    @State private var isWorkspaceSidebarVisible = true
    @State private var isInspectorVisible = true

    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var reimagine: ReimagineViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var vocalSwap: SourceProcessingViewModel
    @ObservedObject var stemSplit: SourceProcessingViewModel
    @ObservedObject var analyze: AnalyzeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var reattacher: JobReattacher
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor
    @ObservedObject var router: WorkflowRouter
    @ObservedObject var cover: GuidedCoverModel
    @ObservedObject var remix: GuidedRemixModel
    @ObservedObject var transcribeStudio: GuidedTranscribeModel
    @ObservedObject var vocalSwapStudio: GuidedVocalSwapModel

    var body: some View {
        HStack(spacing: 0) {
            if isWorkspaceSidebarVisible {
                WorkspaceSidebar(
                    mode: $selectedMode,
                    connection: connection
                )
                .frame(width: 184)

                Divider().overlay(Palette.divider)
            }

            VStack(spacing: 0) {
                WorkspaceHeader(
                    mode: selectedMode,
                    status: sessionStatus,
                    isWorkspaceSidebarVisible: isWorkspaceSidebarVisible,
                    isInspectorVisible: isInspectorVisible,
                    onToggleWorkspaceSidebar: { isWorkspaceSidebarVisible.toggle() },
                    onToggleInspector: { isInspectorVisible.toggle() }
                )

                Divider().overlay(Palette.divider)

                ScrollView {
                    WorkspaceCanvas(
                        mode: $selectedMode,
                        generate: generate,
                        reimagine: reimagine,
                        transcribe: transcribe,
                        vocalSwap: vocalSwap,
                        stemSplit: stemSplit,
                        analyze: analyze,
                        library: library,
                        player: player,
                        midiPreview: midiPreview,
                        connection: connection,
                        router: router,
                        cover: cover,
                        remix: remix,
                        transcribeStudio: transcribeStudio,
                        vocalSwapStudio: vocalSwapStudio,
                        selectedID: $selectedID
                    )
                    .frame(maxWidth: 1_040, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
                }
                .background(Palette.deck)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorVisible {
                Divider().overlay(Palette.divider)

                SessionInspector(
                    mode: selectedMode,
                    status: sessionStatus,
                    library: library,
                    player: player,
                    connection: connection,
                    onOpenLibrary: { selectedMode = .library }
                )
                .frame(width: 244)
            }
        }
        .background(Palette.deck)
        .background(WindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            router.onSwitchMode = { newMode in
                selectedMode = newMode
            }
        }
    }

    private var sessionStatus: String {
        switch reattacher.status {
        case .recovering(let count), .pending(let count):
            return "RECOVERING \(count) JOB\(count == 1 ? "" : "S")"
        case .unavailable(let count):
            return "RECOVERY PENDING \(count) JOB\(count == 1 ? "" : "S")"
        case .missing(let count):
            return "LOCAL JOB UNAVAILABLE \(count)"
        case .idle:
            break
        }

        switch selectedMode {
        case .generate: return generate.isRunning ? "GENERATING" : readyStatus
        case .reimagine: return reimagine.isRunning ? "RENDERING" : readyStatus
        case .analyze: return analyze.statusLine
        case .transcribe: return transcribe.isRunning ? "TRANSCRIBING" : readyStatus
        case .vocalSwap, .stemSplit:
            let model = selectedMode == .vocalSwap ? vocalSwap : stemSplit
            return model.isRunning ? "PROCESSING" : readyStatus
        case .library: return "\(library.items.count) SAVED ASSET\(library.items.count == 1 ? "" : "S")"
        case .guide: return "WORKFLOW GUIDE"
        }
    }

    private var readyStatus: String {
        connection.isConnected ? "READY" : "LOCAL INFERENCE UNAVAILABLE"
    }
}


private struct WindowControls: View {
    var body: some View {
        HStack(spacing: 8) {
            WindowControlButton(label: "Close window", symbol: "xmark", color: Palette.accentRed) { window in
                window.performClose(nil)
            }
            WindowControlButton(label: "Minimize window", symbol: "minus", color: Color(hex: 0xE5AE35)) { window in
                window.miniaturize(nil)
            }
            WindowControlButton(label: "Maximize window", symbol: "arrow.up.left.and.arrow.down.right", color: Palette.accentGreen) { window in
                window.performZoom(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window controls")
    }
}

private struct WindowControlButton: View {
    let label: String
    let symbol: String
    let color: Color
    let action: (NSWindow) -> Void

    var body: some View {
        Button {
            if let window = NSApp.keyWindow {
                action(window)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(Palette.ink.opacity(0.78))
                .frame(width: 16, height: 16)
                .background(color)
                .clipShape(Circle())
                .overlay(Circle().stroke(Palette.ink.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Performs the standard macOS window action")
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
                window.standardWindowButton(button)?.isHidden = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}

private struct SidebarToggleButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Palette.ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundColor(Palette.ink.opacity(0.72))
        .accessibilityLabel(label)
    }
}

private struct WorkspaceSidebar: View {
    @Binding var mode: DeviceMode
    @ObservedObject var connection: ConnectionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WindowControls()
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 5) {
                Text("MICROMIX")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundColor(Palette.ink)
                Text("LOCAL MUSIC STUDIO")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundColor(Palette.ink.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider().overlay(Palette.divider)

            VStack(alignment: .leading, spacing: 5) {
                Text("WORKSPACES")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(Palette.ink.opacity(0.55))
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                ForEach(DeviceMode.allCases.filter(\.isSelectableMode)) { entry in
                    WorkspaceNavButton(mode: entry, isSelected: entry == mode) {
                        mode = entry
                    }
                }
            }

            Divider()
                .overlay(Palette.divider)
                .padding(.vertical, 14)

            Text("GUIDED FLOWS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(Palette.ink.opacity(0.55))
                .padding(.horizontal, 18)

            WorkspaceNavButton(mode: .guide, isSelected: mode == .guide) {
                mode = .guide
            }
            .keyboardShortcut("?", modifiers: [.command])

            Spacer(minLength: 16)

            HStack(spacing: 7) {
                Circle()
                    .fill(connection.isConnected ? Color.green : Palette.accentRed)
                    .frame(width: 7, height: 7)
                Text(connection.isConnected ? "LOCAL ENGINE ONLINE" : "ENGINE OFFLINE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.68))
            }
            .padding(18)
        }
        .background(Palette.deck.opacity(0.94))
    }
}

private struct WorkspaceNavButton: View {
    let mode: DeviceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(mode.rawValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                Spacer(minLength: 0)
                if mode.isSelectableMode {
                    Text("⌘\(mode.displayIndex)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(isSelected ? Palette.screenText.opacity(0.72) : Palette.ink.opacity(0.45))
                }
            }
            .foregroundColor(isSelected ? Palette.screenText : Palette.ink.opacity(0.82))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(isSelected ? Palette.ink : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .workspaceShortcut(for: mode)
        .accessibilityLabel("\(mode.rawValue), mode \(mode.displayIndex) of \(DeviceMode.allCases.filter(\.isSelectableMode).count)")
        .accessibilityHint(isSelected ? "Selected" : "Switches to \(mode.rawValue.lowercased())")
    }
}

private extension View {
    @ViewBuilder
    func workspaceShortcut(for mode: DeviceMode) -> some View {
        if mode.isSelectableMode {
            self.keyboardShortcut(KeyEquivalent(Character(String(mode.displayIndex))), modifiers: [.command])
        } else {
            self
        }
    }
}

private struct WorkspaceHeader: View {
    let mode: DeviceMode
    let status: String
    let isWorkspaceSidebarVisible: Bool
    let isInspectorVisible: Bool
    let onToggleWorkspaceSidebar: () -> Void
    let onToggleInspector: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SidebarToggleButton(
                label: isWorkspaceSidebarVisible ? "Collapse workspace sidebar" : "Show workspace sidebar",
                symbol: "sidebar.left",
                action: onToggleWorkspaceSidebar
            )

            Image(systemName: mode.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Palette.accentBlue)
                .frame(width: 30, height: 30)
                .background(Palette.ink.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.rawValue)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundColor(Palette.ink)
                Text(mode.workspaceDescription)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.ink.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer()

            Text(status)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(Palette.ink.opacity(0.68))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Palette.ink.opacity(0.07))
                .clipShape(Capsule())

            SidebarToggleButton(
                label: isInspectorVisible ? "Collapse session sidebar" : "Show session sidebar",
                symbol: "sidebar.right",
                action: onToggleInspector
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Palette.deck)
    }
}

private struct SessionInspector: View {
    let mode: DeviceMode
    let status: String
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var connection: ConnectionMonitor
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SESSION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundColor(Palette.ink.opacity(0.72))

            inspectorSection("CURRENT WORKSPACE") {
                Label(mode.rawValue, systemImage: mode.symbolName)
                Text(status)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(connection.isConnected ? Palette.ink.opacity(0.64) : Palette.accentRed)
            }

            inspectorSection("NOW PLAYING") {
                if let item = player.currentItem {
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                    if let duration = player.currentDuration {
                        Text(Self.durationString(duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.58))
                    }
                    Button(player.isPlaying ? "PAUSE" : "PLAY") {
                        player.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Select a saved result to preview it here.")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.ink.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            inspectorSection("LIBRARY") {
                Text("\(library.items.count) SAVED ASSET\(library.items.count == 1 ? "" : "S")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Button("OPEN LIBRARY", action: onOpenLibrary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Spacer()

            Text("Results stay available across every workspace. Continue a result from its next action or the Library.")
                .font(.system(size: 9))
                .foregroundColor(Palette.ink.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Palette.deck.opacity(0.94))
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundColor(Palette.ink.opacity(0.52))
            content()
        }
    }

    private static func durationString(_ duration: Double) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct WorkspaceCanvas: View {
    @Binding var mode: DeviceMode
    @ObservedObject var generate: GenerateViewModel
    @ObservedObject var reimagine: ReimagineViewModel
    @ObservedObject var transcribe: TranscribeViewModel
    @ObservedObject var vocalSwap: SourceProcessingViewModel
    @ObservedObject var stemSplit: SourceProcessingViewModel
    @ObservedObject var analyze: AnalyzeViewModel
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var connection: ConnectionMonitor
    @ObservedObject var router: WorkflowRouter
    @ObservedObject var cover: GuidedCoverModel
    @ObservedObject var remix: GuidedRemixModel
    @ObservedObject var transcribeStudio: GuidedTranscribeModel
    @ObservedObject var vocalSwapStudio: GuidedVocalSwapModel
    @Binding var selectedID: UUID?

    var body: some View {
        Group {
            switch mode {
            case .generate:
                GenerateScreen(viewModel: generate, localInferenceAvailable: connection.isConnected, router: router, player: player, library: library)
            case .reimagine:
                ReimagineScreen(
                    viewModel: reimagine,
                    localInferenceAvailable: connection.isConnected,
                    analysisAvailable: !analyze.isRunning,
                    onAnalyzeSource: { url in
                        guard !analyze.isRunning else { return }
                        analyze.analyze(url: url)
                        mode = .analyze
                    },
                    onOpenLibrary: { mode = .library },
                    router: router,
                    player: player,
                    library: library
                )
            case .analyze:
                AnalyzeScreen(viewModel: analyze, router: router)
            case .transcribe:
                TranscribeScreen(viewModel: transcribe, instruments: connection.instruments, localInferenceAvailable: connection.isConnected, router: router, midiPreview: midiPreview, library: library)
            case .vocalSwap, .stemSplit:
                SourceProcessingScreen(
                    viewModel: mode == .vocalSwap ? vocalSwap : stemSplit,
                    voices: connection.vocalModels,
                    localInferenceAvailable: connection.isConnected,
                    voiceCatalog: connection.voiceCatalog,
                    onRefreshVoices: { Task { await connection.refresh() } },
                    onOpenLibrary: { mode = .library },
                    router: router,
                    player: player,
                    midiPreview: midiPreview,
                    library: library
                )
            case .guide:
                WorkflowGuideView(
                    mode: $mode,
                    cover: cover,
                    remix: remix,
                    transcribeStudio: transcribeStudio,
                    vocalSwapStudio: vocalSwapStudio,
                    voices: connection.vocalModels,
                    localInferenceAvailable: connection.isConnected,
                    voiceCatalog: connection.voiceCatalog,
                    onRefreshVoices: { Task { await connection.refresh() } },
                    onOpenLibrary: { mode = .library },
                    onOpenReimagine: { mode = .reimagine },
                    router: router,
                    player: player,
                    midiPreview: midiPreview,
                    library: library
                )
            case .library:
                LibraryScreen(
                    library: library,
                    player: player,
                    midiPreview: midiPreview,
                    router: router,
                    selectedID: $selectedID,
                    onGenerate: { mode = .generate },
                    onStartTranscribe: { mode = .transcribe }
                )
            }
        }
    }
}

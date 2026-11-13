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
    case timeline = "TIMELINE"
    case guide = "GUIDE"

    var id: String { rawValue }

    /// Workspaces that take part in numbered mode switching (⌘1…⌘8).
    var isSelectableMode: Bool { self != .guide }

    var displayIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    var accessibilityName: String {
        isSelectableMode ? "\(rawValue), mode \(displayIndex) of \(Self.allCases.filter(\.isSelectableMode).count)" : rawValue
    }

    var shortcutKey: Character {
        isSelectableMode ? Character(String(displayIndex)) : "?"
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
        case .timeline: "waveform.path"
        case .guide: "questionmark.circle"
        }
    }

    var workspaceDescription: String {
        switch self {
        case .generate: "Create a new local music idea."
        case .reimagine: "Transform an existing audio source."
        case .analyze: "Inspect musical details from an audio source."
        case .transcribe: "Turn audio into MIDI or a lyrics draft."
        case .vocalSwap: "Convert a prepared vocal to a private voice."
        case .stemSplit: "Separate a source into useful stems."
        case .library: "Browse, compare, and continue every saved result."
        case .timeline: "Arrange and audition Library audio tracks."
        case .guide: "Follow an end-to-end creative workflow."
        }
    }
}

enum WorkspaceWindowAction {
    case close, minimize, zoom

    @MainActor
    func perform(on target: WorkspaceWindowActionTarget) {
        switch self {
        case .close: target.closeWorkspaceWindow()
        case .minimize: target.minimizeWorkspaceWindow()
        case .zoom: target.zoomWorkspaceWindow()
        }
    }
}

@MainActor
protocol WorkspaceWindowActionTarget {
    func closeWorkspaceWindow()
    func minimizeWorkspaceWindow()
    func zoomWorkspaceWindow()
}

extension NSWindow: WorkspaceWindowActionTarget {
    func closeWorkspaceWindow() { performClose(nil) }
    func minimizeWorkspaceWindow() { miniaturize(nil) }
    func zoomWorkspaceWindow() { performZoom(nil) }
}

enum WorkspaceLayout {
    static func windowControlsInHeader(sidebarVisible: Bool) -> Bool { !sidebarVisible }

    static func overlaysInspector(windowWidth: CGFloat, sidebarVisible: Bool) -> Bool {
        windowWidth - (sidebarVisible ? 185 : 0) - 245 < 640
    }
}

/// A cohesive workspace shell: tools stay visible in the left rail, each tool
/// renders in the central canvas, and shared session state remains available in
/// the inspector rather than being duplicated inside every workflow.
struct DeviceWindow: View {
    @State private var selectedMode: DeviceMode = .generate
    @State private var selectedGuideTab: WorkflowGuideView.GuideTab = .cover
    @State private var selectedID: UUID?
    @State private var isWorkspaceSidebarVisible = true
    @State private var isInspectorVisible = false

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

    private var workspaceCanvas: some View {
        WorkspaceCanvas(
            mode: $selectedMode,
            guideTab: $selectedGuideTab,
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
            selectedID: $selectedID,
            onOpenTimeline: { selectedMode = .timeline }
        )
        .frame(maxWidth: 1_040, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(24)
    }

    var body: some View {
        GeometryReader { geometry in
        let overlayInspector = WorkspaceLayout.overlaysInspector(
            windowWidth: geometry.size.width, sidebarVisible: isWorkspaceSidebarVisible
        )
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
                    onToggleInspector: { isInspectorVisible.toggle() },
                    onSelectMode: { selectedMode = $0 }
                )

                Divider().overlay(Palette.divider)

                if !activeWork.isEmpty || reattacher.status != .idle || !reattacher.entries.isEmpty {
                    ActiveWorkBar(
                        work: activeWork,
                        recovery: reattacher.status,
                        recoveryEntries: reattacher.entries,
                        windowHeight: geometry.size.height,
                        onForgetJob: { try reattacher.forgetMissingJob(id: $0) },
                        onRetryRecovery: { reattacher.retryFailedRecovery() },
                        onRetryJob: { reattacher.retryRecovery(id: $0) },
                        onCancelJob: { id in Task { await reattacher.cancelRecovery(id: id) } },
                        onDismissJob: { reattacher.dismissEntry(id: $0) },
                        onOpen: { destination in
                            destination.open(mode: &selectedMode, guideTab: &selectedGuideTab)
                        }
                    )
                    Divider().overlay(Palette.divider)
                }

                ZStack {
                    Group {
                        if selectedMode == .library {
                            workspaceCanvas
                        } else if selectedMode != .timeline {
                            ScrollView { workspaceCanvas }
                        }
                    }
                    TimelineEditor(library: library, audioPlayer: player, midiPreview: midiPreview, isActive: selectedMode == .timeline)
                        .opacity(selectedMode == .timeline ? 1 : 0)
                        .allowsHitTesting(selectedMode == .timeline)
                        .accessibilityHidden(selectedMode != .timeline)
                }
                .background(Palette.deck)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorVisible && !overlayInspector {
                Divider().overlay(Palette.divider)

                SessionInspector(
                    selectedID: selectedID, work: activeWork, library: library,
                    player: player, midiPreview: midiPreview,
                    onOpen: { $0.open(mode: &selectedMode, guideTab: &selectedGuideTab) },
                    onOpenLibrary: { selectedMode = .library }
                )
                .frame(width: 244)
            }
        }
        .overlay(alignment: .trailing) {
            if isInspectorVisible && overlayInspector {
                SessionInspector(
                    selectedID: selectedID, work: activeWork, library: library,
                    player: player, midiPreview: midiPreview,
                    onOpen: { $0.open(mode: &selectedMode, guideTab: &selectedGuideTab); isInspectorVisible = false },
                    onOpenLibrary: { selectedMode = .library; isInspectorVisible = false }
                )
                .frame(width: 244)
                .background(Palette.deck)
                .shadow(radius: 8)
                .padding(.top, 64)
            }
        }
        }
        .alert(item: $router.handoffError) { error in
            Alert(title: Text("Could not continue workflow"), message: Text(error.message), dismissButton: .default(Text("OK")))
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

    private var activeWork: [ActiveWorkspaceWork] {
        [
            .analyze(running: analyze.isRunning),
            .init(destination: .workspace(.generate), running: generate.isRunning, elapsed: generate.elapsed, cancel: generate.cancel),
            .init(destination: .workspace(.reimagine), running: reimagine.isRunning, elapsed: reimagine.elapsed, cancel: reimagine.cancel),
            .init(destination: .workspace(.transcribe), running: transcribe.isRunning, elapsed: transcribe.elapsed, cancel: transcribe.cancel),
            .init(destination: .workspace(.vocalSwap), running: vocalSwap.isRunning, elapsed: vocalSwap.elapsed, cancel: vocalSwap.cancel),
            .init(destination: .workspace(.stemSplit), running: stemSplit.isRunning, elapsed: stemSplit.elapsed, cancel: stemSplit.cancel),
            .init(destination: .guide(.studio), running: cover.isRunning, elapsed: cover.elapsed, cancel: cover.cancel),
            .init(destination: .guide(.remixStudio), running: remix.isRunning, elapsed: remix.elapsed, cancel: remix.cancel),
            .init(destination: .guide(.transcribeStudio), running: transcribeStudio.isRunning, elapsed: transcribeStudio.elapsed, cancel: transcribeStudio.cancel),
            .init(destination: .guide(.vocalSwapStudio), running: vocalSwapStudio.isRunning, elapsed: vocalSwapStudio.elapsed, cancel: vocalSwapStudio.cancel),
        ].filter(\.running)
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
        case .timeline: return "ARRANGEMENT"
        case .guide: return "WORKFLOW GUIDE"
        }
    }

    private var readyStatus: String {
        connection.isConnected ? "ENGINE CONNECTED" : "LOCAL INFERENCE UNAVAILABLE"
    }
}


enum ActiveWorkDestination: Hashable {
    case workspace(DeviceMode)
    case guide(WorkflowGuideView.GuideTab)

    var title: String {
        switch self {
        case .workspace(let mode): mode.rawValue
        case .guide(let tab): tab.rawValue
        }
    }

    func open(mode: inout DeviceMode, guideTab: inout WorkflowGuideView.GuideTab) {
        switch self {
        case .workspace(let destination): mode = destination
        case .guide(let destination): guideTab = destination; mode = .guide
        }
    }
}

struct ActiveWorkspaceWork: Identifiable {
    let destination: ActiveWorkDestination
    let running: Bool
    let elapsed: TimeInterval?
    let cancel: (() -> Void)?
    var id: ActiveWorkDestination { destination }

    static func analyze(running: Bool) -> Self {
        .init(destination: .workspace(.analyze), running: running, elapsed: nil, cancel: nil)
    }

    var description: String {
        guard let elapsed else { return "\(destination.title) — running" }
        return "\(destination.title) — running, \(Int(max(0, elapsed)))s elapsed"
    }
}

struct ActiveWorkBar: View {
    let work: [ActiveWorkspaceWork]
    let recovery: JobReattacher.Status
    var recoveryEntries: [JobReattacher.RecoveryEntry] = []
    var windowHeight: CGFloat = 640
    var onForgetJob: (String) throws -> Void = { _ in }
    @State private var jobToForget: JobReattacher.RecoveryEntry?
    @State private var forgetError: String?
    var onRetryRecovery: () -> Void = {}
    var onRetryJob: (String) -> Void = { _ in }
    var onCancelJob: (String) -> Void = { _ in }
    var onDismissJob: (String) -> Void = { _ in }
    let onOpen: (ActiveWorkDestination) -> Void

    static func destination(for entry: JobReattacher.RecoveryEntry) -> ActiveWorkDestination? {
        if case .completed(true) = entry.state { return .workspace(.library) }
        return nil
    }

    static func description(for entry: JobReattacher.RecoveryEntry) -> String {
        let state: String
        switch entry.state {
        case .recovering: state = "Recovering"
        case .cancellationFailed(let reason): state = "\(reason); recovery continues"
        case .unavailable(let reason): state = "Recovery unavailable: \(reason)"
        case .missing: state = "Not found in local service"
        case .cancelling: state = "Cancellation requested; awaiting confirmation"
        case .failed(let reason): state = "Failed: \(reason)"
        case .cancelled: state = "Cancelled"
        case .completed(let hasResults): state = hasResults ? "Results saved to Library" : "Completed; no saved results"
        }
        return "Job \(entry.id) — \(state)" + (destination(for: entry) == nil ? " · workspace unknown" : "")
    }

    static func recoveryDescription(_ status: JobReattacher.Status) -> String? {
        switch status {
        case .idle: nil
        case .recovering(let count): "Recovering \(count) saved job(s)"
        case .pending(let count): "\(count) saved job(s) pending recovery"
        case .unavailable(let count): "\(count) job(s) could not be recovered"
        case .missing(let count): "\(count) saved job(s) unavailable in the local service"
        }
    }

    static func canRetryRecovery(_ status: JobReattacher.Status) -> Bool {
        switch status {
        case .unavailable, .missing: true
        default: false
        }
    }

    static func maximumHeight(windowHeight: CGFloat) -> CGFloat {
        max(0, min(200, windowHeight * 0.25))
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(work) { item in
                HStack {
                    ProgressView().controlSize(.small)
                    Button(item.description) { onOpen(item.destination) }
                        .accessibilityHint("Open the workspace for this job")
                    Spacer(minLength: 8)
                    if let cancel = item.cancel {
                        Button("Cancel", action: cancel)
                            .accessibilityLabel("Cancel \(item.destination.title) job")
                    }
                }
            }
            ForEach(recoveryEntries) { entry in
                HStack {
                    Text(Self.description(for: entry)).font(.caption)
                    Spacer(minLength: 8)
                    if let destination = Self.destination(for: entry) {
                        Button("Open Library") { onOpen(destination) }
                    }
                    switch entry.state {
                    case .unavailable:
                        Button("Retry") { onRetryJob(entry.id) }
                        Button("Cancel job") { onCancelJob(entry.id) }
                    case .missing:
                        Button("Retry") { onRetryJob(entry.id) }
                        Button("Forget locally") { jobToForget = entry }
                    case .recovering, .cancellationFailed:
                        Button("Cancel job") { onCancelJob(entry.id) }
                    case .failed, .cancelled, .completed:
                        Button("Dismiss") { onDismissJob(entry.id) }
                    default: EmptyView()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        }
        .frame(maxHeight: Self.maximumHeight(windowHeight: windowHeight))
        .alert("Forget saved job locally?", isPresented: Binding(
            get: { jobToForget != nil }, set: { if !$0 { jobToForget = nil } }
        ), presenting: jobToForget) { entry in
            Button("Forget locally", role: .destructive) {
                do { try onForgetJob(entry.id) } catch { forgetError = error.localizedDescription }
            }
            Button("Keep", role: .cancel) { }
        } message: { entry in
            Text("Remove the saved recovery record for job \(entry.id)? This does not cancel the job in the local service. Its results will no longer be recovered automatically.")
        }
        .alert("Could not forget saved job", isPresented: Binding(
            get: { forgetError != nil }, set: { if !$0 { forgetError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(forgetError ?? "")
        }
    }
}

private struct WindowControls: View {
    var body: some View {
        HStack(spacing: 8) {
            WindowControlButton(label: "Close window", symbol: "xmark", color: Palette.accentRed, action: .close)
            WindowControlButton(label: "Minimize window", symbol: "minus", color: Color(hex: 0xE5AE35), action: .minimize)
            WindowControlButton(label: "Maximize window", symbol: "arrow.up.left.and.arrow.down.right", color: Palette.accentGreen, action: .zoom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window controls")
    }
}

private struct WindowControlButton: View {
    let label: String
    let symbol: String
    let color: Color
    let action: WorkspaceWindowAction

    var body: some View {
        Button {
            if let window = NSApp.keyWindow {
                action.perform(on: window)
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
        .accessibilityLabel(mode.accessibilityName)
        .accessibilityHint(isSelected ? "Selected" : "Switches to \(mode.rawValue.lowercased())")
    }
}

private extension View {
    @ViewBuilder
    func workspaceShortcut(for mode: DeviceMode) -> some View {
        self.keyboardShortcut(KeyEquivalent(mode.shortcutKey), modifiers: [.command])
    }
}

private struct WorkspaceHeader: View {
    let mode: DeviceMode
    let status: String
    let isWorkspaceSidebarVisible: Bool
    let isInspectorVisible: Bool
    let onToggleWorkspaceSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onSelectMode: (DeviceMode) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if WorkspaceLayout.windowControlsInHeader(sidebarVisible: isWorkspaceSidebarVisible) {
                WindowControls()
            }
            Menu {
                ForEach(DeviceMode.allCases) { entry in
                    Button(entry.rawValue) { onSelectMode(entry) }
                        .workspaceShortcut(for: entry)
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .help("Choose workspace")
            .accessibilityLabel("Choose workspace")
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
                    .font(Typography.help)
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

struct SessionInspector: View {
    let selectedID: UUID?
    let work: [ActiveWorkspaceWork]
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    let onOpen: (ActiveWorkDestination) -> Void
    let onOpenLibrary: () -> Void

    static func selectedItem(id: UUID?, items: [LibraryItem]) -> LibraryItem? {
        items.first { $0.id == id }
    }

    enum PreviewSelection: Equatable {
        case audio(LibraryItem)
        case midi(LibraryItem)
    }

    static func previewSelection(player: AudioPlayer, midiPreview: MidiPreview) -> PreviewSelection? {
        if player.isPlaying, let item = player.currentItem { return .audio(item) }
        if midiPreview.state != .idle, let item = midiPreview.currentItem { return .midi(item) }
        if let item = player.currentItem { return .audio(item) }
        if let item = midiPreview.currentItem { return .midi(item) }
        return nil
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("SESSION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundColor(Palette.ink.opacity(0.72))

            if !work.isEmpty {
                inspectorSection("ACTIVE WORK") {
                    ForEach(work) { item in
                        Button(item.description) { onOpen(item.destination) }
                            .buttonStyle(.link)
                    }
                }
            }

            if let selected = Self.selectedItem(id: selectedID, items: library.items) {
                inspectorSection("SELECTED IN LIBRARY") {
                    Text(selected.title).lineLimit(2)
                    Button("Open in Library", action: onOpenLibrary)
                        .buttonStyle(.link)
                }
            }

            if case .midi(let item) = Self.previewSelection(player: player, midiPreview: midiPreview) {
                inspectorSection(midiPreview.isPlaying ? "NOW PLAYING" : "MIDI PREVIEW") {
                    Text(item.title).lineLimit(2)
                }
            } else if case .audio(let item) = Self.previewSelection(player: player, midiPreview: midiPreview) {
                inspectorSection(player.isPlaying ? "NOW PLAYING" : "AUDIO PREVIEW") {
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
                }
            }

            if work.isEmpty && Self.selectedItem(id: selectedID, items: library.items) == nil
                && player.currentItem == nil && midiPreview.currentItem == nil {
                Text("No active work or preview. Open Library to explore saved results.")
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.72))
                Button("Open Library", action: onOpenLibrary).buttonStyle(.link)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        }
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
    @Binding var guideTab: WorkflowGuideView.GuideTab
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
    var onOpenTimeline: () -> Void

    private var requiredModels: [String]? {
        switch mode {
        case .generate: return [WorkflowReadiness.generationModel(preset: generate.preset)]
        case .reimagine: return [WorkflowReadiness.generationModel(preset: reimagine.preset)]
        case .transcribe: return [transcribe.output == .midi ? "muscriptor" : "whisper"]
        case .vocalSwap: return ["mlx_rvc"]
        case .stemSplit: return ["sam_audio"]
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let requiredModels {
                WorkflowReadinessView(connected: connection.isConnected, statuses: connection.modelStatuses, models: requiredModels)
            }
            switch mode {
            case .generate:
                GenerateScreen(viewModel: generate, localInferenceAvailable: connection.isConnected, modelStatuses: connection.modelStatuses, router: router, player: player, library: library,
                               onShowInLibrary: { item in selectedID = item.id; mode = .library })
            case .reimagine:
                ReimagineScreen(
                    viewModel: reimagine,
                    localInferenceAvailable: connection.isConnected,
                    modelStatuses: connection.modelStatuses,
                    analysisAvailable: !analyze.isRunning,
                    onAnalyzeSource: { url in
                        guard !analyze.isRunning else { return }
                        analyze.analyze(url: url)
                        mode = .analyze
                    },
                    onOpenLibrary: { mode = .library },
                    router: router,
                    player: player,
                    library: library,
                    onShowInLibrary: { item in selectedID = item.id; mode = .library }
                )
            case .analyze:
                AnalyzeScreen(viewModel: analyze, router: router)
            case .transcribe:
                TranscribeScreen(viewModel: transcribe, instruments: connection.instruments, instrumentCatalog: connection.instrumentCatalog, onRefreshCatalog: { Task { await connection.refresh() } }, localInferenceAvailable: connection.isConnected, modelStatuses: connection.modelStatuses, router: router, midiPreview: midiPreview, library: library, onShowInLibrary: { item in selectedID = item.id; mode = .library })
            case .vocalSwap, .stemSplit:
                SourceProcessingScreen(
                    viewModel: mode == .vocalSwap ? vocalSwap : stemSplit,
                    voices: connection.vocalModels,
                    localInferenceAvailable: connection.isConnected,
                    modelStatuses: connection.modelStatuses,
                    voiceCatalog: connection.voiceCatalog,
                    onRefreshVoices: { Task { await connection.refresh() } },
                    onOpenLibrary: { mode = .library },
                    router: router,
                    player: player,
                    midiPreview: midiPreview,
                    library: library
                )
            case .timeline:
                EmptyView()
            case .guide:
                WorkflowGuideView(
                    mode: $mode,
                    tab: $guideTab,
                    cover: cover,
                    remix: remix,
                    transcribeStudio: transcribeStudio,
                    vocalSwapStudio: vocalSwapStudio,
                    voices: connection.vocalModels,
                    instruments: connection.instruments,
                    localInferenceAvailable: connection.isConnected,
                    modelStatuses: connection.modelStatuses,
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
                    onStartTranscribe: { mode = .transcribe },
                    onOpenTimeline: onOpenTimeline
                )
            }
        }
    }
}

import SwiftUI

@main
@MainActor
struct MicromixApp: App {
    @State private var root = Self.makeRoot()

    static func makeRoot() -> AppRoot {
        let settings = SettingsStore()
        let api = MicromixAPI(baseURL: settings.baseURL)
        let library = LocalLibrary()
        let reattacher = JobReattacher(api: api, library: library)
        let monitor = ConnectionMonitor(api: api)

        let generate = GenerateViewModel(api: api, library: library, reattacher: reattacher)
        let reimagine = ReimagineViewModel(api: api, reattacher: reattacher)
        let transcribe = TranscribeViewModel(api: api, library: library, reattacher: reattacher)
        let analyze = AnalyzeViewModel()
        let vocalSwap = SourceProcessingViewModel(operation: .vocalSwap, api: api, reattacher: reattacher)
        let stemSplit = SourceProcessingViewModel(operation: .stemSplit, api: api, reattacher: reattacher)
        let cover = GuidedCoverModel(api: api, reattacher: reattacher)
        let remix = GuidedRemixModel(api: api, reattacher: reattacher)
        let transcribeStudio = GuidedTranscribeModel(api: api, reattacher: reattacher)
        let vocalSwapStudio = GuidedVocalSwapModel(api: api, reattacher: reattacher)

        // Workflow router for chaining operations
        let router = WorkflowRouter(
            library: library,
            generate: generate,
            reimagine: reimagine,
            transcribe: transcribe,
            vocalSwap: vocalSwap,
            stemSplit: stemSplit,
            analyze: analyze
        )

        // Guided remix hands its prepared source to Reimagine through the router.
        remix.onDeliver = { item, url, derived in
            if let item {
                router.execute(.remix, on: item, derived: derived)
            } else {
                router.reimagineRemix(url: url, derived: derived)
            }
        }

        // Guided transcribe studio hands the original audio to Reimagine as a
        // remix source once the MIDI lands in the Library.
        transcribeStudio.onDeliver = { url in
            router.reimagineRemix(url: url)
        }

        // Kick off a connection health check; the monitor polls every 15 s.
        monitor.start()
        // Fetch the transcribe instrument list once at launch.
        Task { await monitor.refreshInstruments() }
        reattacher.startRecovery()

        // Only one preview stream is audible at a time: starting audio stops
        // the MIDI synth and vice versa. Weak captures avoid a retain cycle
        // between the two app-lifetime players.
        let player = AudioPlayer()
        let midiPreview = MidiPreview()
        player.onStart = { [weak midiPreview] in midiPreview?.stop() }
        midiPreview.onStart = { [weak player] in player?.stop() }

        return AppRoot(
            generate: generate,
            reimagine: reimagine,
            transcribe: transcribe,
            vocalSwap: vocalSwap,
            stemSplit: stemSplit,
            analyze: analyze,
            library: library,
            reattacher: reattacher,
            player: player,
            midiPreview: midiPreview,
            connection: monitor,
            router: router,
            cover: cover,
            remix: remix,
            transcribeStudio: transcribeStudio,
            vocalSwapStudio: vocalSwapStudio
        )
    }

    var body: some Scene {
        WindowGroup {
            DeviceWindow(
                generate: root.generate,
                reimagine: root.reimagine,
                transcribe: root.transcribe,
                vocalSwap: root.vocalSwap,
                stemSplit: root.stemSplit,
                analyze: root.analyze,
                library: root.library,
                reattacher: root.reattacher,
                player: root.player,
                midiPreview: root.midiPreview,
                connection: root.connection,
                router: root.router,
                cover: root.cover,
                remix: root.remix,
                transcribeStudio: root.transcribeStudio,
                vocalSwapStudio: root.vocalSwapStudio
            )
            .frame(minWidth: 900, minHeight: 640)
            // The device face is a fixed light deck above a recessed dark screen,
            // drawn entirely from Palette tokens. Micromix does not follow the
            // system appearance, so window chrome, menus and file importers agree
            // with the deck instead of leaving its default-coloured text light on
            // the light deck when the Mac is in dark mode.
            .preferredColorScheme(.light)
        }
        .defaultSize(width: 980, height: 700)
    }
}

/// Composition root holding long-lived shared dependencies.
struct AppRoot: Sendable {
    let generate: GenerateViewModel
    let reimagine: ReimagineViewModel
    let transcribe: TranscribeViewModel
    let vocalSwap: SourceProcessingViewModel
    let stemSplit: SourceProcessingViewModel
    let analyze: AnalyzeViewModel
    let library: LocalLibrary
    let reattacher: JobReattacher
    let player: AudioPlayer
    let midiPreview: MidiPreview
    let connection: ConnectionMonitor
    let router: WorkflowRouter
    let cover: GuidedCoverModel
    let remix: GuidedRemixModel
    let transcribeStudio: GuidedTranscribeModel
    let vocalSwapStudio: GuidedVocalSwapModel
}

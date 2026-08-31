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
        let transcribe = TranscribeViewModel(api: api, library: library, reattacher: reattacher)
        let analyze = AnalyzeViewModel()

        // Kick off a connection health check; the monitor polls every 15 s.
        monitor.start()
        // Fetch the transcribe instrument list once at launch.
        Task { await monitor.refreshInstruments() }
        reattacher.startRecovery()

        return AppRoot(
            generate: generate,
            transcribe: transcribe,
            analyze: analyze,
            library: library,
            reattacher: reattacher,
            player: AudioPlayer(),
            midiPreview: MidiPreview(),
            connection: monitor
        )
    }

    var body: some Scene {
        WindowGroup {
            DeviceWindow(
                generate: root.generate,
                transcribe: root.transcribe,
                analyze: root.analyze,
                library: root.library,
                reattacher: root.reattacher,
                player: root.player,
                midiPreview: root.midiPreview,
                connection: root.connection
            )
            .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 980, height: 700)
    }
}

/// Composition root holding long-lived shared dependencies.
struct AppRoot: Sendable {
    let generate: GenerateViewModel
    let transcribe: TranscribeViewModel
    let analyze: AnalyzeViewModel
    let library: LocalLibrary
    let reattacher: JobReattacher
    let player: AudioPlayer
    let midiPreview: MidiPreview
    let connection: ConnectionMonitor
}

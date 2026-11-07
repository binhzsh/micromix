import Combine
import Foundation

@MainActor
final class AnalyzeViewModel: ObservableObject, AssetAccepting {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceName = ""
    @Published private(set) var analysis: LocalMusicAnalysis?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    static var supportsMusicUnderstanding: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27.0, *) { return true }
        #endif
        return false
    }

    static func capabilityDescription(supportsMusicUnderstanding: Bool) -> String {
        if supportsMusicUnderstanding {
            return "DURATION, RHYTHM, KEY AND INSTRUMENT ACTIVITY ARE ANALYZED ON THIS MAC WHEN AVAILABLE. STRUCTURE IS NOT SUPPORTED."
        }
        return "ONLY DURATION IS AVAILABLE ON THIS MAC. RHYTHM, KEY, INSTRUMENT ACTIVITY AND STRUCTURE ARE NOT SUPPORTED."
    }

    static func statusLine(isRunning: Bool, hasAnalysis: Bool, hasError: Bool) -> String {
        if isRunning { return "ANALYZING LOCALLY…" }
        if hasAnalysis { return "ANALYSIS COMPLETE — LOCAL" }
        if hasError { return "ANALYSIS FAILED — SELECT AUDIO" }
        return "READY — SELECT AUDIO"
    }

    var statusLine: String {
        Self.statusLine(isRunning: isRunning, hasAnalysis: analysis != nil, hasError: error != nil)
    }

    func analyze(url: URL) {
        guard !isRunning else { return }
        sourceURL = url
        sourceName = url.lastPathComponent
        analysis = nil
        error = nil
        isRunning = true
        Task {
            do {
                let result = try await LocalMusicAnalyzer.analyze(url: url)
                analysis = result
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }

    // MARK: - AssetAccepting

    var canAcceptSource: Bool { !isRunning }

    func acceptSource(_ context: AssetActionContext) {
        guard canAcceptSource else { return }
        analyze(url: context.sourceURL)
    }
}

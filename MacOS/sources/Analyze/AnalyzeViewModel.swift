import Combine
import Foundation

@MainActor
final class AnalyzeViewModel: ObservableObject {
    @Published private(set) var sourceName = ""
    @Published private(set) var analysis: LocalMusicAnalysis?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    func analyze(url: URL) {
        guard !isRunning else { return }
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
}

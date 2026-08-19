import Foundation
import Combine

/// Drives the GENERATE flow: prompt/lyrics editor state, job lifecycle
/// (via `JobRunner`), and persistence of the returned audio into `LocalLibrary`.
///
/// Test seams: `api` and `library` are injected as `Sendable` protocols so
/// fakes can stand in for the real actor / `@MainActor` store.
@MainActor
final class GenerateViewModel: ObservableObject {
    /// High-level flow phase surfaced to the UI.
    enum Phase: Equatable {
        case idle
        case running
        case done
        case cancelled
        case error(String)
    }

    // Editor state
    @Published var prompt: String = ""
    @Published var lyrics: String = ""
    @Published var useLyrics: Bool = false

    // Flow state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastItem: LibraryItem?

    /// Fixed v1 presets.
    let model = "MiniMaxAI/MiniMax-Music3"
    let format = "wav"

    private let api: any GenerateServicing
    private let library: any LibraryStoring
    private let runner = JobRunner()

    private var cancellables = Set<AnyCancellable>()

    init(api: any GenerateServicing, library: any LibraryStoring) {
        self.api = api
        self.library = library
        // Mirror JobRunner's published timings into this VM's published props.
        runner.$elapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.elapsed = $0 }
            .store(in: &cancellables)
    }

    /// A trimmed version of what will actually be sent to the model.
    var effectiveInput: String {
        if useLyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lyrics
        }
        return prompt
    }

    var isRunning: Bool { phase == .running }
    var isBlocked: Bool { isRunning }

    /// Start generation. Ignored (and returns false) if already running or the
    /// effective input is empty.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        let input = effectiveInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .error("ENTER PROMPT OR LYRICS")
            return false
        }

        let api = self.api
        let library = self.library
        let lyricsArg = useLyrics ? lyrics : nil
        let title = Self.title(from: input)
        phase = .running
        lastItem = nil

        runner.start(JobRunner.Job(name: "generate") {
            do {
                let data = try await api.generate(input: input, lyrics: lyricsArg)
                let item = LibraryItem(
                    id: UUID(),
                    kind: .audio,
                    title: title,
                    createdAt: Date(),
                    promptOrSource: input,
                    durationSeconds: nil,
                    relativePath: "audio/\(UUID().uuidString).wav"
                )
                try await MainActor.run { try library.add(item, bytes: data) }
                await MainActor.run { [item] in
                    self.lastItem = item
                    self.phase = .done
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                let message = (error as? MicromixAPIError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { self.phase = .error(message) }
            }
        })
        return true
    }

    /// Cancel the current generation.
    func cancel() {
        runner.cancel()
        if phase == .running {
            phase = .cancelled
        }
    }

    private static func title(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "GENERATED" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}

import Foundation
import Combine

/// Drives the GENERATE flow: prompt/lyrics editor state, job lifecycle
/// (via `JobRunner`), and persistence of the returned audio into `LocalLibrary`.
///
/// Test seams: `api` and `library` are injected as `Sendable` protocols so
/// fakes can stand in for the real actor / `@MainActor` store.
@MainActor
final class GenerateViewModel: ObservableObject {
    private actor SubmittedJobReference {
        private var id: String?
        func set(_ id: String) { self.id = id }
        func value() -> String? { id }
    }
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
    @Published var preset: String = "turbo"
    @Published var durationSeconds: Double = 30

    // Flow state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastItem: LibraryItem?

    let format = "wav"

    private let api: any GenerateServicing
    private let library: any LibraryStoring
    private let reattacher: JobReattacher?
    private let runner = JobRunner()

    private var cancellables = Set<AnyCancellable>()

    init(
        api: any GenerateServicing,
        library: any LibraryStoring,
        reattacher: JobReattacher? = nil
    ) {
        self.api = api
        self.library = library
        self.reattacher = reattacher
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
        let reattacher = self.reattacher
        let lyricsArg = useLyrics ? lyrics : nil
        let preset = self.preset
        let durationSeconds = self.durationSeconds
        let title = Self.title(from: input)
        let submittedJob = SubmittedJobReference()
        phase = .running
        lastItem = nil

        runner.start(JobRunner.Job(name: "generate", work: {
            do {
                if let submitter = api as? any DurableGenerationSubmitting, let reattacher {
                    let job = try await submitter.submitGeneration(
                        input: input,
                        lyrics: lyricsArg,
                        preset: preset,
                        durationSeconds: durationSeconds
                    )
                    await submittedJob.set(job.id)
                    try await reattacher.track(job)
                    let items = try await reattacher.recoverSubmittedJob(id: job.id)
                    guard let item = items.first else { return }
                    await MainActor.run {
                        self.lastItem = item
                        self.phase = .done
                    }
                    return
                }

                let data = try await api.generate(input: input, lyrics: lyricsArg, preset: preset, durationSeconds: durationSeconds)
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
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                let message = (error as? MicromixAPIError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { self.phase = .error(message) }
            }
        }, onCancel: {
            Task {
                guard let cancelling = api as? any DurableJobCancelling,
                      let id = await submittedJob.value() else { return }
                try? await cancelling.cancel(jobID: id)
            }
        }))
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

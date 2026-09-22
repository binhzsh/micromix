import Foundation
import Combine

/// Drives the GENERATE flow: prompt/lyrics editor state, durable job lifecycle
/// (via `JobFlow`), and persistence of the returned audio into `LocalLibrary`.
///
/// Test seams: `api` and `library` are injected as `Sendable` protocols so
/// fakes can stand in for the real actor / `@MainActor` store.
@MainActor
final class GenerateViewModel: ObservableObject {
    // Editor state
    @Published var prompt: String = ""
    @Published var lyrics: String = ""
    @Published var useLyrics: Bool = false
    @Published var preset: String = "turbo"
    @Published var durationSeconds: Double = 30
    @Published var seedText = ""
    @Published var variationCount = 1
    @Published var bpmText = ""
    @Published var key = ""
    @Published var timeSignature = ""
    @Published var vocalLanguage: VocalLanguage = .automatic

    var phase: JobStatus { flow.status }
    var elapsed: TimeInterval { flow.elapsed }
    var results: [LibraryItem] { flow.results }
    var errorMessage: String? { flow.errorMessage }

    let format = "wav"

    private let api: any GenerateServicing
    private let library: any LibraryStoring
    private let reattacher: JobReattacher?
    private let flow = JobFlow()
    private var cancellables = Set<AnyCancellable>()

    init(
        api: any GenerateServicing,
        library: any LibraryStoring,
        reattacher: JobReattacher? = nil
    ) {
        self.api = api
        self.library = library
        self.reattacher = reattacher
        flow.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// A trimmed version of what will actually be sent to the model.
    var effectiveInput: String {
        if useLyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lyrics
        }
        return prompt
    }

    var isRunning: Bool { flow.isRunning }
    var isBlocked: Bool { flow.isRunning }

    /// Start generation. Ignored (and returns false) if already running or the
    /// effective input is empty.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        let input = effectiveInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flow.reject("ENTER PROMPT OR LYRICS")
            return false
        }
        guard let options = generationOptions() else { return false }

        let api = self.api
        let library = self.library
        let reattacher = self.reattacher
        let lyricsArg = useLyrics ? lyrics : nil
        let preset = self.preset
        let durationSeconds = self.durationSeconds
        let title = Self.title(from: input)

        return flow.start { run in
            if let submitter = api as? any DurableGenerationSubmitting, let reattacher {
                let job = try await submitter.submitGeneration(
                    input: input,
                    lyrics: lyricsArg,
                    preset: preset,
                    durationSeconds: durationSeconds,
                    options: options
                )
                guard run.isCurrent() else {
                    Task { try? await (api as? any DurableJobCancelling)?.cancel(jobID: job.id) }
                    return []
                }
                run.accept(job.id)
                try await reattacher.track(job)
                return try await reattacher.recoverSubmittedJob(id: job.id)
            }

            let data = try await api.generate(
                input: input, lyrics: lyricsArg, preset: preset,
                durationSeconds: durationSeconds, options: options
            )
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
            return [item]
        }
    }

    /// Cancel the current generation and forward cancellation to its accepted
    /// durable job, when one exists.
    func cancel() {
        guard let acceptedJobID = flow.cancel() else { return }
        guard let cancelling = api as? any DurableJobCancelling else { return }
        Task { try? await cancelling.cancel(jobID: acceptedJobID) }
    }

    private static func title(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "GENERATED" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    /// Validate the creative controls, rejecting the run through `flow` when a
    /// value is out of range or malformed.
    private func generationOptions() -> GenerationOptions? {
        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: UInt32?
        if trimmedSeed.isEmpty {
            seed = nil
        } else if let parsed = UInt32(trimmedSeed) {
            seed = parsed
        } else {
            flow.reject("SEED MUST BE 0–4,294,967,295")
            return nil
        }
        guard (1...4).contains(variationCount) else {
            flow.reject("VARIATIONS MUST BE 1–4")
            return nil
        }
        let trimmedBPM = bpmText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bpm: Int?
        if trimmedBPM.isEmpty {
            bpm = nil
        } else if let parsed = Int(trimmedBPM), (30...300).contains(parsed) {
            bpm = parsed
        } else {
            flow.reject("BPM MUST BE 30–300")
            return nil
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTimeSignature = timeSignature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTimeSignature.isEmpty || ["2", "3", "4", "6"].contains(trimmedTimeSignature) else {
            flow.reject("METER MUST BE 2, 3, 4, OR 6")
            return nil
        }
        return GenerationOptions(
            seed: seed,
            variationCount: variationCount,
            bpm: bpm,
            key: trimmedKey.isEmpty ? nil : trimmedKey,
            timeSignature: trimmedTimeSignature.isEmpty ? nil : trimmedTimeSignature,
            vocalLanguage: vocalLanguage
        )
    }
}

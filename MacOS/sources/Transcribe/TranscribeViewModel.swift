import Foundation
import Combine
import UniformTypeIdentifiers

/// Drives the TRANSCRIBE flow: audio file selection, instrument selection,
/// tempo detection toggle, job lifecycle (via `JobRunner`), and persistence of
/// the returned MIDI into `LocalLibrary`.
///
/// Test seams: `api` and `library` are injected as `Sendable` protocols so
/// fakes can stand in for the real actor / `@MainActor` store (same pattern as
/// `GenerateViewModel`).
@MainActor
final class TranscribeViewModel: ObservableObject, AssetAccepting {
    enum LyricsError: LocalizedError {
        case unavailable, noResult, noMIDIResult
        var errorDescription: String? {
            switch self {
            case .unavailable: "Lyrics transcription requires the local durable job service."
            case .noResult: "Lyrics transcription returned no result."
            case .noMIDIResult: "MIDI transcription returned no result. Please retry."
            }
        }
    }
    enum SourceReadError: Error {
        case tooLarge
        case unreadable
    }

    nonisolated static var maximumSourceBytes: Int { 200 * 1024 * 1024 }

    /// High-level flow phase surfaced to the UI.
    enum Phase: Equatable {
        case idle
        case running
        case done
        case cancelled
        case error(String)
    }

    /// A selected local audio file, read into memory for upload.
    struct Selection: Sendable {
        let name: String
        let bytes: Data
        let analysis: LocalMusicAnalysis?
    }

    enum Output: String, CaseIterable {
        case midi = "MIDI"
        case lyrics = "LYRICS DRAFT"
    }

    // Selection state
    @Published var output: Output = .midi
    @Published var selection: Selection?
    @Published private(set) var isLoadingSource = false
    @Published var instruments: [String] = []
    @Published var detectTempo: Bool = true

    // Flow state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastItem: LibraryItem?

    /// Factory-name source for the manifest.
    var sourceName: String {
        selection?.name ?? ""
    }

    private let api: any TranscribeServicing
    private let library: any LibraryStoring
    private let reattacher: JobReattacher?
    private let runner = JobRunner()
    private var runID: UUID?
    private var acceptedJobID: String?
    private var sourceRequestID: UUID?
    private let sourceLoader: @Sendable (URL) async throws -> (Data, LocalMusicAnalysis?)

    private var cancellables = Set<AnyCancellable>()

    init(
        api: any TranscribeServicing,
        library: any LibraryStoring,
        reattacher: JobReattacher? = nil,
        sourceLoader: @escaping @Sendable (URL) async throws -> (Data, LocalMusicAnalysis?) = { url in
            let data = try await Task.detached(priority: .userInitiated) {
                try TranscribeViewModel.readSource(at: url)
            }.value
            return (data, try? await LocalMusicAnalyzer.analyze(url: url))
        }
    ) {
        self.sourceLoader = sourceLoader
        self.api = api
        self.library = library
        self.reattacher = reattacher
        // Mirror JobRunner's published timings into this VM's published props.
        runner.$elapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.elapsed = $0 }
            .store(in: &cancellables)
    }

    var isRunning: Bool { phase == .running }
    var isBlocked: Bool { isRunning || isLoadingSource }

    nonisolated static func readSource(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumSourceBytes {
            throw SourceReadError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        guard data.count <= maximumSourceBytes else {
            throw SourceReadError.tooLarge
        }
        return data
    }

    /// Set the source audio file. Ignored while a job is running.
    @discardableResult
    func select(name: String, bytes: Data, analysis: LocalMusicAnalysis? = nil) -> Bool {
        guard !isRunning else { return false }
        sourceRequestID = nil
        isLoadingSource = false
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .audio),
              !type.conforms(to: .midi) else {
            phase = .error("UNSUPPORTED AUDIO FILE")
            return false
        }
        guard !bytes.isEmpty else {
            phase = .error("COULD NOT READ AUDIO FILE")
            return false
        }
        guard bytes.count <= Self.maximumSourceBytes else {
            phase = .error("AUDIO FILE EXCEEDS 200 MB")
            return false
        }
        selection = Selection(name: name, bytes: bytes, analysis: analysis)
        phase = .idle
        return true
    }

    /// Read and validate an audio file selected from Finder, a drop, or the managed Library.
    @discardableResult
    func select(url: URL) async -> Bool {
        guard !isRunning else { return false }
        let requestID = UUID()
        sourceRequestID = requestID
        isLoadingSource = true
        do {
            let (data, analysis) = try await sourceLoader(url)
            guard sourceRequestID == requestID else { return false }
            return select(name: url.lastPathComponent, bytes: data, analysis: analysis)
        } catch {
            guard sourceRequestID == requestID else { return false }
            sourceRequestID = nil
            isLoadingSource = false
            rejectSource((error as? SourceReadError) ?? .unreadable)
            return false
        }
    }

    func rejectSource(_ error: SourceReadError) {
        guard !isRunning else { return }
        sourceRequestID = nil
        isLoadingSource = false
        switch error {
        case .tooLarge:
            phase = .error("AUDIO FILE EXCEEDS 200 MB")
        case .unreadable:
            phase = .error("COULD NOT READ AUDIO FILE")
        }
    }

    /// Clear the current selection.
    func clearSelection() {
        guard !isRunning else { return }
        sourceRequestID = nil
        isLoadingSource = false
        selection = nil
    }

    /// Toggle an instrument in the multi-picker.
    func toggleInstrument(_ instrument: String) {
        guard !isRunning else { return }
        if instruments.contains(instrument) {
            instruments.removeAll(where: { $0 == instrument })
        } else {
            instruments.append(instrument)
        }
    }

    var hasSelection: Bool { selection != nil }

    /// Start transcription. Returns false (no-op) if already running or no
    /// audio file is selected.
    @discardableResult
    func start() -> Bool {
        guard !isRunning, !isLoadingSource else { return false }
        guard let selection else {
            phase = .error("SELECT AN AUDIO FILE")
            return false
        }

        let api = self.api
        let library = self.library
        let reattacher = self.reattacher
        let filename = selection.name
        let audio = selection.bytes
        let instruments = self.instruments
        let detectTempo = self.detectTempo
        let output = self.output
        let title = Self.title(from: filename)
        let runID = UUID()
        self.runID = runID
        acceptedJobID = nil

        phase = .running
        lastItem = nil

        runner.start(JobRunner.Job(name: "transcribe", work: {
            do {
                if output == .lyrics {
                    guard let submitter = api as? any DurableLyricsSubmitting, let reattacher else {
                        throw LyricsError.unavailable
                    }
                    let job = try await Task { try await submitter.submitLyricsTranscription(audio: audio, filename: filename) }.value
                    guard await self.accept(job.id, for: runID) else {
                        defer { Task { try? await (api as? any DurableJobCancelling)?.cancel(jobID: job.id) } }
                        try await reattacher.trackForBackground(job)
                        return
                    }
                    try await reattacher.track(job)
                    let items = try await reattacher.recoverSubmittedJob(id: job.id)
                    guard let item = items.first else { throw LyricsError.noResult }
                    await self.complete(item, for: runID)
                    return
                }
                if let submitter = api as? any DurableTranscriptionSubmitting, let reattacher {
                    let job = try await Task {
                        try await submitter.submitTranscription(
                            audio: audio,
                            filename: filename,
                            instruments: instruments,
                            detectTempo: detectTempo
                        )
                    }.value
                    guard await self.accept(job.id, for: runID) else {
                        defer { Task { try? await (api as? any DurableJobCancelling)?.cancel(jobID: job.id) } }
                        try await reattacher.trackForBackground(job)
                        return
                    }
                    try await reattacher.track(job)
                    let items = try await reattacher.recoverSubmittedJob(id: job.id)
                    guard let item = items.first else { throw LyricsError.noMIDIResult }
                    await self.complete(item, for: runID)
                    return
                }

                let data = try await api.transcribe(audio: audio, filename: filename, instruments: instruments, detectTempo: detectTempo)
                let item = LibraryItem(
                    id: UUID(),
                    kind: .midi,
                    title: title,
                    createdAt: Date(),
                    promptOrSource: filename,
                    durationSeconds: nil,
                    relativePath: "midi/\(UUID().uuidString).mid"
                )
                try await MainActor.run {
                    guard self.runID == runID, !Task.isCancelled else { return }
                    try library.add(item, bytes: data)
                    self.complete(item, for: runID)
                }
            } catch is CancellationError {
                await self.finish(.cancelled, for: runID)
            } catch let urlError as URLError where urlError.code == .cancelled {
                await self.finish(.cancelled, for: runID)
            } catch {
                let message = (error as? MicromixAPIError)?.errorDescription
                    ?? error.localizedDescription
                await self.finish(.error(message), for: runID)
            }
        }))
        return true
    }

    private func accept(_ jobID: String, for run: UUID) -> Bool {
        guard runID == run, !Task.isCancelled else { return false }
        acceptedJobID = jobID
        return true
    }

    private func complete(_ item: LibraryItem, for run: UUID) {
        guard runID == run, !Task.isCancelled else { return }
        lastItem = item
        finish(.done, for: run)
    }

    private func finish(_ result: Phase, for run: UUID) {
        guard runID == run else { return }
        runID = nil
        acceptedJobID = nil
        phase = result
    }

    /// Cancel the current transcription, including an accepted durable job.
    func cancel() {
        let jobID = acceptedJobID
        runID = nil
        acceptedJobID = nil
        runner.cancel()
        if phase == .running { phase = .cancelled }
        if let jobID, let cancelling = api as? any DurableJobCancelling {
            Task { try? await cancelling.cancel(jobID: jobID) }
        }
    }

    // MARK: - AssetAccepting

    var canAcceptSource: Bool { !isBlocked }

    func acceptSource(_ context: AssetActionContext) {
        guard canAcceptSource else { return }
        let url = context.sourceURL
        Task {
            _ = await select(url: url)
        }
    }

    private static func title(from filename: String) -> String {
        guard !filename.isEmpty else { return "TRANSCRIBED" }
        return filename
    }
}

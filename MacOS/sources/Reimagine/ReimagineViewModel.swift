import Combine
import Foundation

@MainActor
protocol ReimagineJobReattaching: AnyObject {
    func track(_ job: RemoteJob) throws
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem]
}

extension JobReattacher: ReimagineJobReattaching {}

@MainActor
final class ReimagineViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case cancelled
        case error(String)
    }

    @Published var operation: ReimagineOperation = .reference
    @Published var sourceURL: URL?
    @Published var prompt = ""
    @Published var lyrics = ""
    @Published var useLyrics = false
    @Published var preset = "turbo"
    @Published var seedText = ""
    @Published var variationCount = 2
    @Published var durationSeconds: Double = 30
    @Published var bpmText = "" {
        didSet {
            if !isApplyingPrefill { bpmWasManuallyEdited = true }
        }
    }
    @Published var key = "" {
        didSet {
            if !isApplyingPrefill { keyWasManuallyEdited = true }
        }
    }
    @Published var timeSignature = ""
    @Published var sourceStrength: Double = 0.5
    @Published var startSeconds: Double = 0
    @Published var endSeconds: Double = 10
    @Published var repaintStrength: Double = 0.5
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var errorMessage: String?

    private let api: any DurableReimagineSubmitting
    private let canceller: any DurableJobCancelling
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?
    private var submittedJob: (runID: UUID, jobID: String)?
    private var isApplyingPrefill = false
    private var bpmWasManuallyEdited = false
    private var keyWasManuallyEdited = false

    init(
        api: any DurableReimagineSubmitting & DurableJobCancelling,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.api = api
        self.canceller = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
    }

    var isRunning: Bool { phase == .running }

    func prefill(from analysis: LocalMusicAnalysis) {
        isApplyingPrefill = true
        defer { isApplyingPrefill = false }
        if !bpmWasManuallyEdited, let beatsPerMinute = analysis.beatsPerMinute {
            bpmText = String(Int(beatsPerMinute.rounded()))
        }
        if !keyWasManuallyEdited, let analyzedKey = analysis.key {
            key = analyzedKey
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        guard let sourceURL else {
            fail("SELECT AN AUDIO FILE")
            return false
        }
        let operation = self.operation
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            fail("ENTER A PROMPT")
            return false
        }

        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: UInt32?
        if trimmedSeed.isEmpty {
            seed = nil
        } else if let parsed = UInt32(trimmedSeed) {
            seed = parsed
        } else {
            fail("SEED MUST BE 0–4,294,967,295")
            return false
        }
        guard (1...4).contains(variationCount) else {
            fail("VARIATIONS MUST BE 1–4")
            return false
        }

        let durationSeconds = self.durationSeconds
        let trimmedBPM = bpmText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bpm: Int?
        if operation == .reference {
            guard durationSeconds.isFinite, (10...600).contains(durationSeconds) else {
                fail("DURATION MUST BE 10–600 SECONDS")
                return false
            }
            if trimmedBPM.isEmpty {
                bpm = nil
            } else if let parsed = Int(trimmedBPM), (30...300).contains(parsed) {
                bpm = parsed
            } else {
                fail("BPM MUST BE 30–300")
                return false
            }
        } else {
            bpm = nil
        }

        let startSeconds = self.startSeconds
        let endSeconds = self.endSeconds
        if operation == .repaint {
            let interval = endSeconds - startSeconds
            guard startSeconds.isFinite, endSeconds.isFinite, (3...90).contains(interval) else {
                fail("REPAINT RANGE MUST BE 3–90 SECONDS")
                return false
            }
        }

        let api = self.api
        let canceller = self.canceller
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
        let lyrics = useLyrics ? self.lyrics : nil
        let preset = self.preset
        let variationCount = self.variationCount
        let key = Self.optionalTrimmed(self.key)
        let timeSignature = Self.optionalTrimmed(self.timeSignature)
        let sourceStrength = self.sourceStrength
        let repaintStrength = self.repaintStrength
        let runID = UUID()
        currentRunID = runID
        phase = .running
        errorMessage = nil
        results = []

        task = Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try sourceReader(sourceURL)
                }.value
                let asset = try await api.uploadAsset(
                    data: data,
                    filename: sourceURL.lastPathComponent,
                    mediaType: Self.mediaType(for: sourceURL)
                )
                let request: ReimagineRequest
                switch operation {
                case .reference:
                    request = .reference(
                        prompt: prompt,
                        lyrics: lyrics,
                        preset: preset,
                        seed: seed,
                        variationCount: variationCount,
                        durationSeconds: durationSeconds,
                        bpm: bpm,
                        key: key,
                        timeSignature: timeSignature,
                        sourceAssetID: asset.id
                    )
                case .remix:
                    request = .remix(
                        prompt: prompt,
                        lyrics: lyrics,
                        preset: preset,
                        seed: seed,
                        variationCount: variationCount,
                        sourceStrength: sourceStrength,
                        sourceAssetID: asset.id
                    )
                case .repaint:
                    request = .repaint(
                        prompt: prompt,
                        lyrics: lyrics,
                        preset: preset,
                        seed: seed,
                        variationCount: variationCount,
                        startSeconds: startSeconds,
                        endSeconds: endSeconds,
                        repaintStrength: repaintStrength,
                        sourceAssetID: asset.id
                    )
                }
                let job = try await api.submitReimagine(request)
                try reattacher.track(job)
                guard currentRunID == runID, !Task.isCancelled else {
                    Task { try? await canceller.cancel(jobID: job.id) }
                    return
                }
                submittedJob = (runID, job.id)
                let recovered = try await reattacher.recoverSubmittedJob(id: job.id)
                guard currentRunID == runID, !Task.isCancelled else { return }
                results = recovered
                submittedJob = nil
                currentRunID = nil
                task = nil
                phase = .done
            } catch {
                guard currentRunID == runID else { return }
                submittedJob = nil
                currentRunID = nil
                task = nil
                if Self.isCancellation(error) {
                    errorMessage = nil
                    phase = .cancelled
                } else {
                    let message = (error as? MicromixAPIError)?.errorDescription
                        ?? error.localizedDescription
                    fail(message)
                }
            }
        }
        return true
    }

    func cancel() {
        let cancelledRunID = currentRunID
        let acceptedJobID = submittedJob.flatMap { submitted in
            submitted.runID == cancelledRunID ? submitted.jobID : nil
        }
        currentRunID = nil
        submittedJob = nil
        task?.cancel()
        task = nil
        if isRunning {
            errorMessage = nil
            phase = .cancelled
        }
        if let acceptedJobID {
            Task { try? await canceller.cancel(jobID: acceptedJobID) }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .error(message)
    }

    private static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        default: "application/octet-stream"
        }
    }

    private static func optionalTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }
}

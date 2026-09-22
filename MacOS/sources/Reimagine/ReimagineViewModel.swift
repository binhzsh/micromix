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
    @Published var vocalLanguage: VocalLanguage = .automatic
    @Published var sourceStrength: Double = 0.5
    @Published var startSeconds: Double = 0
    @Published var endSeconds: Double = 10
    @Published var repaintStrength: Double = 0.5

    var phase: JobStatus { flow.status }
    var elapsed: TimeInterval { flow.elapsed }
    var results: [LibraryItem] { flow.results }
    var errorMessage: String? { flow.errorMessage }

    private let api: any DurableReimagineSubmitting
    private let canceller: any DurableJobCancelling
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data
    private let flow = JobFlow()
    private var cancellables = Set<AnyCancellable>()
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
        flow.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isRunning: Bool { flow.isRunning }

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
            flow.reject("SELECT AN AUDIO FILE")
            return false
        }
        let operation = self.operation
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            flow.reject("ENTER A PROMPT")
            return false
        }

        guard let settings = validatedSettings(for: operation) else { return false }
        let seed = settings.seed
        let bpm = settings.bpm
        let durationSeconds = self.durationSeconds
        let startSeconds = self.startSeconds
        let endSeconds = self.endSeconds

        let api = self.api
        let canceller = self.canceller
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
        let lyrics = useLyrics ? self.lyrics : nil
        let preset = self.preset
        let variationCount = self.variationCount
        let key = Self.optionalTrimmed(self.key)
        let timeSignature = Self.optionalTrimmed(self.timeSignature)
        let vocalLanguage = self.vocalLanguage
        let sourceStrength = self.sourceStrength
        let repaintStrength = self.repaintStrength

        return flow.start { run in
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
                    vocalLanguage: vocalLanguage,
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
            guard run.isCurrent() else {
                Task { try? await canceller.cancel(jobID: job.id) }
                return []
            }
            run.accept(job.id)
            try reattacher.track(job)
            return try await reattacher.recoverSubmittedJob(id: job.id)
        }
    }

    /// Numeric control validation shared by every operation. Rejects the run
    /// through `flow` and returns nil when a value is out of range.
    private func validatedSettings(for operation: ReimagineOperation) -> ValidatedSettings? {
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
        if operation == .reference {
            guard durationSeconds.isFinite, (10...600).contains(durationSeconds) else {
                flow.reject("DURATION MUST BE 10–600 SECONDS")
                return nil
            }
            if trimmedBPM.isEmpty {
                bpm = nil
            } else if let parsed = Int(trimmedBPM), (30...300).contains(parsed) {
                bpm = parsed
            } else {
                flow.reject("BPM MUST BE 30–300")
                return nil
            }
        } else {
            bpm = nil
        }

        if operation == .repaint {
            let interval = endSeconds - startSeconds
            guard startSeconds.isFinite, endSeconds.isFinite, (3...90).contains(interval) else {
                flow.reject("REPAINT RANGE MUST BE 3–90 SECONDS")
                return nil
            }
        }
        return ValidatedSettings(seed: seed, bpm: bpm)
    }

    private struct ValidatedSettings {
        let seed: UInt32?
        let bpm: Int?
    }

    func cancel() {
        if let acceptedJobID = flow.cancel() {
            Task { try? await canceller.cancel(jobID: acceptedJobID) }
        }
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
}

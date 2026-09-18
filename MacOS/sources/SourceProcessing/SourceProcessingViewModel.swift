import Combine
import Foundation

@MainActor
final class SourceProcessingViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, running, done, cancelled
        case error(String)
    }

    let operation: SourceProcessingOperation
    @Published var sourceURL: URL?
    @Published var voiceModel = ""
    @Published var description = ""
    @Published var pitchShift = 0
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var errorMessage: String?
    private let api: any DurableSourceProcessing
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?
    private var submittedJob: (runID: UUID, jobID: String)?

    init(operation: SourceProcessingOperation, api: any DurableSourceProcessing,
         reattacher: any ReimagineJobReattaching,
         sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.operation = operation
        self.api = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
    }

    var isRunning: Bool { phase == .running }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        guard let sourceURL else { fail("SELECT AN AUDIO FILE"); return false }
        let voiceModel = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .vocalSwap && voiceModel.isEmpty { fail("SELECT A VOICE MODEL"); return false }
        if operation == .stemSplit && description.isEmpty { fail("DESCRIBE THE SOUND TO EXTRACT"); return false }
        guard (-24...24).contains(pitchShift) else { fail("PITCH MUST BE −24 TO 24"); return false }
        let operation = self.operation
        let pitchShift = self.pitchShift
        let api = self.api
        let canceller = self.api
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
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
                try Task.checkCancellation()
                let request: SourceProcessingRequest
                switch operation {
                case .vocalSwap:
                    request = .vocalSwap(sourceAssetID: asset.id, voiceModel: voiceModel, pitchShift: pitchShift)
                case .stemSplit:
                    request = .stemSplit(sourceAssetID: asset.id, description: description)
                }
                let job = try await api.submitSourceProcessing(request)
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
            Task { try? await api.cancel(jobID: acceptedJobID) }
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

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }
}

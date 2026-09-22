import Combine
import Foundation

@MainActor
final class SourceProcessingViewModel: ObservableObject {
    let operation: SourceProcessingOperation
    @Published var sourceURL: URL?
    @Published var voiceModel = ""
    @Published var description = ""
    @Published var pitchShift = 0

    var phase: JobStatus { flow.status }
    var elapsed: TimeInterval { flow.elapsed }
    var results: [LibraryItem] { flow.results }
    var errorMessage: String? { flow.errorMessage }

    private let api: any DurableSourceProcessing
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data
    private let flow = JobFlow()
    private var cancellables = Set<AnyCancellable>()

    init(operation: SourceProcessingOperation, api: any DurableSourceProcessing,
         reattacher: any ReimagineJobReattaching,
         sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.operation = operation
        self.api = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
        flow.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isRunning: Bool { flow.isRunning }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        guard let sourceURL else { flow.reject("SELECT AN AUDIO FILE"); return false }
        let voiceModel = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if operation == .vocalSwap && voiceModel.isEmpty { flow.reject("SELECT A VOICE MODEL"); return false }
        if operation == .stemSplit && description.isEmpty { flow.reject("DESCRIBE THE SOUND TO EXTRACT"); return false }
        guard (-24...24).contains(pitchShift) else { flow.reject("PITCH MUST BE −24 TO 24"); return false }

        let operation = self.operation
        let pitchShift = self.pitchShift
        let api = self.api
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader

        return flow.start { run in
            let data = try await Task.detached(priority: .userInitiated) {
                try sourceReader(sourceURL)
            }.value
            let asset = try await api.uploadAsset(
                data: data,
                filename: sourceURL.lastPathComponent,
                mediaType: Self.mediaType(for: sourceURL)
            )
            let request: SourceProcessingRequest
            switch operation {
            case .vocalSwap:
                request = .vocalSwap(sourceAssetID: asset.id, voiceModel: voiceModel, pitchShift: pitchShift)
            case .stemSplit:
                request = .stemSplit(sourceAssetID: asset.id, description: description)
            }
            let job = try await api.submitSourceProcessing(request)
            guard run.isCurrent() else {
                Task { try? await api.cancel(jobID: job.id) }
                return []
            }
            run.accept(job.id)
            try reattacher.track(job)
            return try await reattacher.recoverSubmittedJob(id: job.id)
        }
    }

    func cancel() {
        if let acceptedJobID = flow.cancel() {
            Task { try? await api.cancel(jobID: acceptedJobID) }
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
}

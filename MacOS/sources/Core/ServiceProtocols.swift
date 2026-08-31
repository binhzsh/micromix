import Foundation

/// Thin seams so flows can be unit-tested with fakes while production code
/// uses the real `MicromixAPI` / `LocalLibrary`.
///
/// Both declared `Sendable`: a `@MainActor`/actor-isolated type is implicitly
/// Sendable, so capturing an `any` existential of these in a `JobRunner`
/// `@Sendable` work closure is allowed by Swift 6 strict concurrency.

/// Generates audio from a text/lyrics prompt.
protocol GenerateServicing: Sendable {
    func generate(input: String,
                  lyrics: String?,
                  preset: String,
                  durationSeconds: Double,
                  options: GenerationOptions) async throws -> Data
}

/// Transcribes audio into MIDI.
protocol TranscribeServicing: Sendable {
    func transcribe(audio: Data,
                    filename: String,
                    instruments: [String],
                    detectTempo: Bool) async throws -> Data
}

/// Persists a result item plus its bytes.
protocol LibraryStoring: Sendable {
    @MainActor func add(_ item: LibraryItem, bytes: Data) throws
}

/// Lookup and output retrieval used by durable-job recovery.
protocol DurableJobServicing: Sendable {
    func job(id: String) async throws -> RemoteJob
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset]
}

/// Submission seams used when the app must persist the accepted gateway ID
/// before it begins waiting for a result.
protocol DurableGenerationSubmitting: Sendable {
    func submitGeneration(
        input: String,
        lyrics: String?,
        preset: String,
        durationSeconds: Double,
        options: GenerationOptions
    ) async throws -> RemoteJob
}

protocol DurableTranscriptionSubmitting: Sendable {
    func submitTranscription(
        audio: Data,
        filename: String,
        instruments: [String],
        detectTempo: Bool
    ) async throws -> RemoteJob
}

/// Source upload and durable reimagine submission for recovery-capable flows.
protocol DurableReimagineSubmitting: Sendable {
    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset
    func submitReimagine(_ request: ReimagineRequest) async throws -> RemoteJob
}

protocol DurableJobCancelling: Sendable {
    func cancel(jobID: String) async throws
}

// MARK: - Production conformances

extension MicromixAPI: GenerateServicing {
}

extension MicromixAPI: TranscribeServicing {}

extension MicromixAPI: DurableJobServicing {}

extension MicromixAPI: DurableGenerationSubmitting {}

extension MicromixAPI: DurableTranscriptionSubmitting {}

extension MicromixAPI: DurableReimagineSubmitting {}

extension MicromixAPI: DurableJobCancelling {}

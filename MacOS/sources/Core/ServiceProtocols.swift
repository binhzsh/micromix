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
                  durationSeconds: Double) async throws -> Data
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

// MARK: - Production conformances

extension MicromixAPI: GenerateServicing {
}

extension MicromixAPI: TranscribeServicing {}

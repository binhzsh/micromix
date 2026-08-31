import Foundation

/// Health snapshot of the durable gateway and its local workers.
struct HealthStatus: Codable, Equatable, Sendable {
    struct Worker: Codable, Equatable, Sendable {
        let status: String
    }

    struct Workers: Codable, Equatable, Sendable {
        let aceStep: Worker
        let muscriptor: Worker
    }

    let service: String
    let status: String
    let database: String
    let workers: Workers
}

struct GenerationPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let model: String
    let inferenceSteps: Int
}

struct Capabilities: Codable, Equatable, Sendable {
    let generationPresets: [GenerationPreset]
    let transcriptionInstruments: [String]
}

struct RemoteAsset: Codable, Equatable, Sendable {
    let id: String
    let filename: String
    let mediaType: String
    let sizeBytes: Int
    let sha256: String
    let downloadUrl: String
}

struct RemoteJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let state: String
    let progress: Double?
    let progressDetail: String?
    let error: String?
    let asset: RemoteAsset?

    var isTerminal: Bool {
        ["succeeded", "failed", "cancelled"].contains(state)
    }
}

/// The kind of content a stored library item holds.
enum LibraryItemKind: String, Codable, Sendable {
    case audio
    case midi
}

/// A single persisted result in the local library.
struct LibraryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: LibraryItemKind
    let title: String
    let createdAt: Date
    /// Generation input or transcription source filename.
    let promptOrSource: String
    let durationSeconds: Double?
    /// Path relative to the library root, e.g. `audio/<uuid>.wav`.
    let relativePath: String
}

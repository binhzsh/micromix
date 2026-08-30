import Foundation

/// Health snapshot of the `micromix-api` shim and its two upstreams.
struct HealthStatus: Codable, Equatable, Sendable {
    let service: String
    let status: String
    let minimax: String
    let muscriptor: String
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

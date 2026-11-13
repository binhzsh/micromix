import Foundation

/// Portable references and timing only; media remains owned by the Library.
struct ArrangementDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Track: Codable, Equatable, Sendable {
        var libraryID: UUID
        var title: String
        var offset: Double
        var trimStart: Double
        /// Absolute position in the source, in seconds.
        var trimEnd: Double
    }

    var version: Int = currentVersion
    var tracks: [Track]

    func validate() throws {
        guard version == Self.currentVersion else { throw ArrangementError.unsupportedVersion(version) }
        for track in tracks {
            guard track.offset.isFinite, track.offset >= 0,
                  track.trimStart.isFinite, track.trimStart >= 0,
                  track.trimEnd.isFinite, track.trimEnd > track.trimStart else {
                throw ArrangementError.invalidTiming(track.title)
            }
        }
    }

    static func open(from url: URL) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try document.validate()
        return document
    }

    func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Tracks only persisted content; playback position and media resolution are not edits.
@MainActor
struct ArrangementSession {
    private(set) var baseline = ArrangementDocument(tracks: [])
    private(set) var url: URL?

    func isDirty(_ document: ArrangementDocument) -> Bool { document != baseline }

    enum Decision { case save, discard, cancel }
    static func mayProceed(_ decision: Decision, saveSucceeded: Bool = false) -> Bool {
        switch decision {
        case .save: saveSucceeded
        case .discard: true
        case .cancel: false
        }
    }

    static func mayClose(isDirty: Bool, choose: () -> Decision, save: () -> Bool) -> Bool {
        guard isDirty else { return true }
        let decision = choose()
        return mayProceed(decision, saveSucceeded: decision == .save && save())
    }

    mutating func save(_ document: ArrangementDocument, to destination: URL) throws {
        try document.save(to: destination)
        baseline = document
        url = destination
    }

    mutating func open(from source: URL, into model: TimelineModel, library: LocalLibrary) throws {
        let document = try ArrangementDocument.open(from: source)
        try model.load(document, from: library)
        baseline = document
        url = source
    }
}

enum ArrangementError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidTiming(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported arrangement version: \(version)."
        case .invalidTiming(let title): "Invalid arrangement timing for \(title)."
        }
    }
}

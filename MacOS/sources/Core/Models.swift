import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

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

struct RemoteAssetLink: Codable, Equatable, Sendable {
    let name: String
    let position: Int
    let asset: RemoteAsset
}

struct DownloadedRemoteAsset: Equatable, Sendable {
    let asset: RemoteAsset
    let data: Data
}

struct RemoteJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let state: String
    let parameters: [String: JSONValue]
    let progress: Double?
    let progressDetail: String?
    let error: String?
    let asset: RemoteAsset?
    let inputs: [RemoteAssetLink]
    let outputs: [RemoteAssetLink]

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, parameters, progress, progressDetail, error, asset, inputs, outputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(String.self, forKey: .state)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        progressDetail = try container.decodeIfPresent(String.self, forKey: .progressDetail)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        asset = try container.decodeIfPresent(RemoteAsset.self, forKey: .asset)
        inputs = try container.decodeIfPresent([RemoteAssetLink].self, forKey: .inputs) ?? []
        outputs = try container.decodeIfPresent([RemoteAssetLink].self, forKey: .outputs) ?? []
    }

    var operation: String? {
        guard case .string(let value) = parameters["operation"] else { return nil }
        return value
    }

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

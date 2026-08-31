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

extension JSONValue {
    var displayText: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        case .array(let values): "[" + values.map(\.displayText).joined(separator: ", ") + "]"
        case .object(let values): "{" + values.keys.sorted().map { "\($0): \(values[$0]!.displayText)" }.joined(separator: ", ") + "}"
        case .null: "null"
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

enum ReimagineOperation: String, Codable, Sendable {
    case reference
    case remix
    case repaint
}

enum ReimagineRequest: Sendable {
    case reference(
        prompt: String,
        lyrics: String?,
        preset: String,
        seed: UInt32?,
        variationCount: Int,
        durationSeconds: Double,
        bpm: Int?,
        key: String?,
        timeSignature: String?,
        sourceAssetID: String
    )
    case remix(
        prompt: String,
        lyrics: String?,
        preset: String,
        seed: UInt32?,
        variationCount: Int,
        sourceStrength: Double,
        sourceAssetID: String
    )
    case repaint(
        prompt: String,
        lyrics: String?,
        preset: String,
        seed: UInt32?,
        variationCount: Int,
        startSeconds: Double,
        endSeconds: Double,
        repaintStrength: Double,
        sourceAssetID: String
    )
}

struct RemoteAssetLink: Codable, Equatable, Sendable {
    let name: String
    let position: Int
    let asset: RemoteAsset
}

struct LibraryProvenance: Codable, Equatable, Sendable {
    let jobID: String
    let operation: String?
    let parameters: [String: JSONValue]
    let inputs: [RemoteAssetLink]
    let output: RemoteAssetLink
}

extension LibraryProvenance {
    var copyText: String {
        let parameterLines = parameters.keys.sorted().map { "\($0): \(parameters[$0]!.displayText)" }
        let inputLines = inputs.sorted { $0.position < $1.position }.map {
            "#\($0.position + 1) \($0.name) — \($0.asset.filename)"
        }
        return ([
            "Operation: \(operation ?? "\(output.asset.mediaType) export")",
            "Job: \(jobID)",
            "Output: #\(output.position + 1) \(output.name) — \(output.asset.filename)",
            "Inputs:",
        ] + (inputLines.isEmpty ? ["(none)"] : inputLines) + ["Parameters:"] +
        (parameterLines.isEmpty ? ["(none)"] : parameterLines)).joined(separator: "\n")
    }
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
    let upstreamID: String?
    let cancelRequested: Bool
    let error: String?
    let asset: RemoteAsset?
    let inputs: [RemoteAssetLink]
    let outputs: [RemoteAssetLink]

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, parameters, progress, error, asset, inputs, outputs
        case progressDetail
        case upstreamID = "upstreamId"
        case cancelRequested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(String.self, forKey: .state)
        parameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .parameters) ?? [:]
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        progressDetail = try container.decodeIfPresent(String.self, forKey: .progressDetail)
        upstreamID = try container.decodeIfPresent(String.self, forKey: .upstreamID)
        cancelRequested = try container.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
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
    /// Remote render information, absent for library items created before durable jobs.
    let provenance: LibraryProvenance?
    /// Stable remote output asset identity used to make recovery imports idempotent.
    let remoteOutputAssetID: String?

    init(
        id: UUID,
        kind: LibraryItemKind,
        title: String,
        createdAt: Date,
        promptOrSource: String,
        durationSeconds: Double?,
        relativePath: String,
        provenance: LibraryProvenance? = nil,
        remoteOutputAssetID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.promptOrSource = promptOrSource
        self.durationSeconds = durationSeconds
        self.relativePath = relativePath
        self.provenance = provenance
        self.remoteOutputAssetID = remoteOutputAssetID
    }
}

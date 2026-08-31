import Combine
import Foundation
import SwiftData

@Model
final class LibraryRecord {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var title: String
    var createdAt: Date
    var promptOrSource: String
    var durationSeconds: Double?
    var relativePath: String
    var provenanceData: Data?
    @Attribute(.unique) var remoteOutputAssetID: String?

    init(item: LibraryItem) {
        id = item.id
        kindRawValue = item.kind.rawValue
        title = item.title
        createdAt = item.createdAt
        promptOrSource = item.promptOrSource
        durationSeconds = item.durationSeconds
        relativePath = item.relativePath
        provenanceData = item.provenance.flatMap { try? JSONEncoder().encode($0) }
        remoteOutputAssetID = item.remoteOutputAssetID
    }

    var item: LibraryItem {
        LibraryItem(
            id: id,
            kind: LibraryItemKind(rawValue: kindRawValue) ?? .audio,
            title: title,
            createdAt: createdAt,
            promptOrSource: promptOrSource,
            durationSeconds: durationSeconds,
            relativePath: relativePath,
            provenance: provenanceData.flatMap { try? JSONDecoder().decode(LibraryProvenance.self, from: $0) },
            remoteOutputAssetID: remoteOutputAssetID
        )
    }
}

@Model
final class PendingJobRecord {
    @Attribute(.unique) var id: String
    var submittedAt: Date

    init(id: String, submittedAt: Date = .now) {
        self.id = id
        self.submittedAt = submittedAt
    }
}

/// SwiftData is authoritative for metadata; generated audio and MIDI remain as
/// ordinary files so Logic Pro and AVFoundation can consume them directly.
@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var pendingJobIDs: [String] = []

    let rootDirectory: URL
    private let container: ModelContainer
    private let context: ModelContext
    private let legacyManifestURL: URL

    init(directory: URL? = nil) {
        let root = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Micromix", isDirectory: true)
        rootDirectory = root
        legacyManifestURL = root.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let schema = Schema([LibraryRecord.self, PendingJobRecord.self])
        let configuration = ModelConfiguration(
            "MicromixLibrary",
            schema: schema,
            url: root.appendingPathComponent("library.store")
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to open the Micromix library: \(error)")
        }
        context = container.mainContext
        migrateLegacyManifestIfNeeded()
        reload()
    }

    func resolvedURL(for item: LibraryItem) -> URL {
        rootDirectory.appendingPathComponent(item.relativePath)
    }

    func add(_ item: LibraryItem, bytes: Data) throws {
        let fileURL = resolvedURL(for: item)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: fileURL, options: .atomic)
        context.insert(LibraryRecord(item: item))
        do {
            try context.save()
            reload()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func trackPendingJob(id: String, submittedAt: Date = .now) throws {
        guard pendingRecord(id: id) == nil else { return }
        context.insert(PendingJobRecord(id: id, submittedAt: submittedAt))
        try context.save()
        reload()
    }

    func removePendingJob(id: String) throws {
        guard let record = pendingRecord(id: id) else { return }
        context.delete(record)
        try context.save()
        reload()
    }

    func importRemoteOutput(
        _ item: LibraryItem,
        bytes: Data,
        remoteAssetID: String,
        jobID: String,
        provenance: LibraryProvenance? = nil
    ) throws -> LibraryItem {
        if let existing = libraryRecord(remoteAssetID: remoteAssetID) {
            return existing.item
        }

        let imported = LibraryItem(
            id: item.id,
            kind: item.kind,
            title: item.title,
            createdAt: item.createdAt,
            promptOrSource: item.promptOrSource,
            durationSeconds: item.durationSeconds,
            relativePath: item.relativePath,
            provenance: provenance ?? item.provenance ?? LibraryProvenance(
                jobID: jobID,
                operation: nil,
                parameters: [:],
                inputs: [],
                output: RemoteAssetLink(
                    name: "result",
                    position: 0,
                    asset: RemoteAsset(
                        id: remoteAssetID,
                        filename: item.title,
                        mediaType: item.kind == .audio ? "audio/wav" : "audio/midi",
                        sizeBytes: bytes.count,
                        sha256: "",
                        downloadUrl: ""
                    )
                )
            ),
            remoteOutputAssetID: remoteAssetID
        )
        try add(imported, bytes: bytes)
        return imported
    }

    func remove(id: UUID) throws {
        let targetID = id
        var descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        let item = record.item
        let fileURL = resolvedURL(for: item)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        context.delete(record)
        try context.save()
        reload()
    }

    private func reload() {
        let descriptor = FetchDescriptor<LibraryRecord>(
            sortBy: [SortDescriptor(\LibraryRecord.createdAt, order: .reverse)]
        )
        items = (try? context.fetch(descriptor).map(\.item)) ?? []
        let pendingDescriptor = FetchDescriptor<PendingJobRecord>(
            sortBy: [SortDescriptor(\PendingJobRecord.submittedAt)]
        )
        pendingJobIDs = (try? context.fetch(pendingDescriptor).map(\.id)) ?? []
    }

    private func pendingRecord(id: String) -> PendingJobRecord? {
        let targetID = id
        var descriptor = FetchDescriptor<PendingJobRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func libraryRecord(remoteAssetID: String) -> LibraryRecord? {
        let targetID = remoteAssetID
        var descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.remoteOutputAssetID == targetID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func migrateLegacyManifestIfNeeded() {
        guard (try? context.fetchCount(FetchDescriptor<LibraryRecord>())) == 0,
              let data = try? Data(contentsOf: legacyManifestURL)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacyItems = try? decoder.decode([LibraryItem].self, from: data) else { return }
        for item in legacyItems {
            context.insert(LibraryRecord(item: item))
        }
        try? context.save()
        try? FileManager.default.moveItem(
            at: legacyManifestURL,
            to: rootDirectory.appendingPathComponent("library.json.migrated")
        )
    }
}

extension LocalLibrary: LibraryStoring {}

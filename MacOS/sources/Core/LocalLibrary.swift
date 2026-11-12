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
                        mediaType: item.kind == .audio ? "audio/wav" : (item.kind == .midi ? "audio/midi" : "text/plain"),
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

    /// Copies the item together with its job siblings, any child assets, and
    /// the parent sources it was created from into one export folder with a
    /// provenance manifest, ready for a DAW import. Returns the folder URL.
    /// Parents come last so the kit leads with the selected result and its
    /// chains, then carries the original as reference material.
    func exportBundle(for item: LibraryItem) throws -> URL {
        let lineage = RelatedAssetsResolver.related(for: item, in: items)
        var grouped: [LibraryItem] = [item]
        for candidate in lineage.siblings + lineage.children + lineage.parents
        where !grouped.contains(where: { $0.id == candidate.id }) {
            grouped.append(candidate)
        }
        let missing = grouped.filter { !FileManager.default.fileExists(atPath: resolvedURL(for: $0).path) }
        guard missing.isEmpty else {
            let details = missing.map { "\($0.title) (\($0.relativePath))" }.joined(separator: ", ")
            throw BundleExportError(description: "Missing library files: \(details). Restore the files or remove the affected library items, then export again.")
        }

        let jobID = item.provenance?.jobID ?? item.id.uuidString
        let folderName = Self.sanitized("\(String(jobID.suffix(8)))-\(item.title)")
        let exportsRoot = rootDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)

        let destination = Self.unusedDirectory(named: folderName, in: exportsRoot)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            var lines = [
                "MICROMIX EXPORT — \(Self.timestamp())",
                "JOB \(jobID)\(item.provenance?.operation.map { " · OPERATION \($0)" } ?? "")",
                "SOURCE: \(item.promptOrSource.isEmpty ? "(none recorded)" : item.promptOrSource)",
                "Direct library relatives only. This bundle does not guarantee complete reproduction.",
                "Full available metadata and source availability: manifest.json",
                ""
            ]
            var entries: [BundleManifestEntry] = []
            for (index, entry) in grouped.enumerated() {
                let fileURL = resolvedURL(for: entry)
                let role = entry.provenance?.output.name ?? "result"
                let base = Self.sanitized("\(String(format: "%02d", index + 1))-\(role)-\(entry.title)")
                let name = fileURL.pathExtension.isEmpty ? base : "\(base).\(fileURL.pathExtension)"
                try FileManager.default.copyItem(at: fileURL, to: destination.appendingPathComponent(name))
                let inputs: [BundleInputAvailability] = entry.provenance?.inputs.map { link in
                    let match = grouped.first { candidate in
                        candidate.remoteOutputAssetID == link.asset.id && !link.asset.id.isEmpty
                            || (!link.asset.sha256.isEmpty && candidate.provenance?.output.asset.sha256 == link.asset.sha256)
                    }
                    return BundleInputAvailability(
                        input: link, status: match == nil ? "not_in_bundle" : "bundled",
                        bundledLibraryItemID: match?.id
                    )
                } ?? []
                entries.append(BundleManifestEntry(filename: name, item: entry, inputs: inputs))
                lines.append("\(name) — \(entry.provenance?.operation ?? entry.kind.rawValue.uppercased()) · \(role)")
                if entry.provenance == nil {
                    lines.append("  WARNING: provenance and original source availability are unknown.")
                } else if inputs.isEmpty {
                    lines.append("  Original source availability is unknown; no inputs were recorded.")
                }
                for input in inputs where input.bundledLibraryItemID == nil {
                    lines.append("  WARNING: original input not available in this bundle: \(input.input.asset.filename) (asset \(input.input.asset.id)). Locate and retain the original separately.")
                }
            }
            let manifest = BundleManifest(formatVersion: 1, entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: destination.appendingPathComponent("manifest.txt"), options: .atomic)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func unusedDirectory(named folderName: String, in exportsRoot: URL) -> URL {
        var destination = exportsRoot.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = exportsRoot.appendingPathComponent("\(folderName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return destination
    }

    private static func sanitized(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        let squeezed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.isEmpty ? "export" : String(squeezed.prefix(80))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
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

private struct BundleManifest: Encodable {
    let formatVersion: Int
    let scope = "direct library relatives only; complete reproduction is not guaranteed"
    let entries: [BundleManifestEntry]
}

private struct BundleManifestEntry: Encodable {
    let filename: String
    let item: LibraryItem
    let inputs: [BundleInputAvailability]
}

private struct BundleInputAvailability: Encodable {
    let input: RemoteAssetLink
    let status: String
    let bundledLibraryItemID: UUID?
}

extension LocalLibrary: LibraryStoring {}

/// Failure raised directly by the library export bundle, not by SwiftData.
struct BundleExportError: LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

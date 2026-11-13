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
        if let derivation = item.derivation {
            provenanceData = try? JSONEncoder().encode(LibraryMetadataEnvelope(
                formatVersion: 1, provenance: item.provenance, derivation: derivation))
        } else {
            provenanceData = item.provenance.flatMap { try? JSONEncoder().encode($0) }
        }
        remoteOutputAssetID = item.remoteOutputAssetID
    }

    var item: LibraryItem {
        let envelope = provenanceData.flatMap { try? JSONDecoder().decode(LibraryMetadataEnvelope.self, from: $0) }
        let supportedEnvelope = envelope.flatMap { $0.formatVersion == 1 ? $0 : nil }
        let legacyProvenance = provenanceData.flatMap { try? JSONDecoder().decode(LibraryProvenance.self, from: $0) }
        return LibraryItem(
            id: id,
            kind: LibraryItemKind(rawValue: kindRawValue) ?? .audio,
            title: title,
            createdAt: createdAt,
            promptOrSource: promptOrSource,
            durationSeconds: durationSeconds,
            relativePath: relativePath,
            provenance: supportedEnvelope?.provenance ?? legacyProvenance,
            remoteOutputAssetID: remoteOutputAssetID,
            derivation: supportedEnvelope?.derivation
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
private struct LibraryDeletionRecoveryError: LocalizedError {
    let backupURL: URL
    let underlying: Error

    var errorDescription: String? {
        "Could not restore the file: \(underlying.localizedDescription). Recover it from \(backupURL.path)."
    }
}

@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var pendingJobIDs: [String] = []
    @Published private(set) var deletionRecoveryIssues: [String] = []

    private struct DeletionJournal: Codable {
        let id: UUID
        let relativePath: String
        let token: UUID
    }

    private var deletionJournalDirectory: URL {
        rootDirectory.appendingPathComponent(".deletion-journal", isDirectory: true)
    }

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
        retryDeletionRecovery()
    }

    func resolvedURL(for item: LibraryItem) -> URL {
        rootDirectory.appendingPathComponent(item.relativePath)
    }

    func add(_ item: LibraryItem, bytes: Data) throws {
        try add(item, bytes: bytes, save: { try $0.save() })
    }

    func add(
        _ item: LibraryItem,
        bytes: Data,
        save: (ModelContext) throws -> Void
    ) throws {
        let fileURL = resolvedURL(for: item)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: fileURL, options: .atomic)
        let record = LibraryRecord(item: item)
        context.insert(record)
        do {
            try save(context)
            reload()
        } catch {
            context.delete(record)
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// Save a separate local correction; the original ASR output and its remote provenance stay untouched.
    @discardableResult
    func saveLyricsCorrection(of original: LibraryItem, text: String) throws -> LibraryItem {
        guard original.kind == .lyrics, items.contains(where: { $0.id == original.id }) else {
            throw RenameError.itemNotFound
        }
        let id = UUID()
        let correction = LibraryItem(
            id: id, kind: .lyrics, title: "Corrected — \(original.title)", createdAt: .now,
            promptOrSource: "Corrected from \(original.title)",
            durationSeconds: nil, relativePath: "lyrics/\(id.uuidString).txt",
            derivation: LibraryDerivation(operation: "lyrics-correction", parentLibraryItemIDs: [original.id])
        )
        try add(correction, bytes: Data(text.utf8))
        return correction
    }

    enum RenameError: LocalizedError {
        case emptyTitle, itemNotFound

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "Enter a title."
            case .itemNotFound: return "This Library item no longer exists."
            }
        }
    }

    func rename(id: UUID, title: String, save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RenameError.emptyTitle }
        let descriptor = FetchDescriptor<LibraryRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try context.fetch(descriptor).first else { throw RenameError.itemNotFound }
        record.title = title
        do {
            try save(context)
            reload()
        } catch {
            context.rollback()
            throw error
        }
    }

    func trackPendingJob(id: String, submittedAt: Date = .now) throws {
        guard pendingRecord(id: id) == nil else { return }
        let record = PendingJobRecord(id: id, submittedAt: submittedAt)
        context.insert(record)
        do {
            try context.save()
            reload()
        } catch {
            context.delete(record)
            throw error
        }
    }

    func removePendingJob(
        id: String,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard let record = pendingRecord(id: id) else { return }
        context.delete(record)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
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

    func remove(
        id: UUID,
        moveFile: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
        save: ((ModelContext) throws -> Void) = { try $0.save() },
        removeStagedFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let targetID = id
        var descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        let item = record.item
        let fileURL = resolvedURL(for: item).standardizedFileURL
        let identity = try canonicalLibraryURL(item.relativePath)
        let records = try context.fetch(FetchDescriptor<LibraryRecord>())
        let shared = try records.filter { $0.id != id }.contains {
            try sameLibraryFile(canonicalLibraryURL($0.relativePath), identity)
        }
        try ensureNoPendingDeletion(id: id, identity: identity)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if exists {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw NSError(domain: "Micromix.DeletionRecovery", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot delete a non-regular library file: \(fileURL.path)"])
            }
        }
        let hasFile = !shared && exists
        let journal = DeletionJournal(id: id, relativePath: item.relativePath, token: UUID())
        let backupURL = stagedURL(for: journal, original: fileURL)
        let journalURL = deletionJournalDirectory.appendingPathComponent("\(journal.token.uuidString).json")
        if hasFile {
            try FileManager.default.createDirectory(at: deletionJournalDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            do {
                try moveFile(fileURL, backupURL)
            } catch {
                try? FileManager.default.removeItem(at: journalURL)
                throw error
            }
        }
        context.delete(record)
        do {
            try save(context)
        } catch {
            context.rollback()
            if hasFile {
                do {
                    try moveFile(backupURL, fileURL)
                } catch {
                    throw LibraryDeletionRecoveryError(backupURL: backupURL, underlying: error)
                }
                do {
                    try FileManager.default.removeItem(at: journalURL)
                } catch {
                    deletionRecoveryIssues.append("File restored, but journal cleanup failed at \(journalURL.path): \(error.localizedDescription). Fix permissions and retry deletion recovery.")
                }
            }
            throw error
        }
        reload()
        if hasFile {
            do {
                try removeStagedFile(backupURL)
                try FileManager.default.removeItem(at: journalURL)
            } catch {
                deletionRecoveryIssues = ["Item deleted, but cleanup failed: \(error.localizedDescription). Staged file: \(backupURL.path). Use Retry deletion recovery."]
                throw NSError(domain: "Micromix.DeletionCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: deletionRecoveryIssues[0]])
            }
        }
    }

    private func canonicalLibraryURL(_ relativePath: String) throws -> URL {
        let url = rootDirectory.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard !relativePath.hasPrefix("/"), url.path.hasPrefix(root) else {
            throw NSError(domain: "Micromix.DeletionRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid library path: \(relativePath)"])
        }
        return url
    }

    /// Compare existing files by filesystem identity; staged or missing paths need
    /// the case rules of their containing volume instead of URL string equality.
    private func sameLibraryFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
        if lhs == rhs { return true }
        let fm = FileManager.default
        if fm.fileExists(atPath: lhs.path), fm.fileExists(atPath: rhs.path) {
            let left = try fm.attributesOfItem(atPath: lhs.path)
            let right = try fm.attributesOfItem(atPath: rhs.path)
            if let leftDevice = left[.systemNumber] as? NSNumber,
               let rightDevice = right[.systemNumber] as? NSNumber,
               let leftFile = left[.systemFileNumber] as? NSNumber,
               let rightFile = right[.systemFileNumber] as? NSNumber,
               leftDevice == rightDevice, leftFile == rightFile {
                return true
            }
        }

        func volume(for url: URL) throws -> (NSNumber, Bool) {
            var ancestor = url
            while !fm.fileExists(atPath: ancestor.path) {
                let parent = ancestor.deletingLastPathComponent()
                guard parent != ancestor else { throw CocoaError(.fileReadUnknown) }
                ancestor = parent
            }
            let attributes = try fm.attributesOfItem(atPath: ancestor.path)
            let values = try ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let caseSensitive = values.volumeSupportsCaseSensitiveNames else {
                throw CocoaError(.fileReadUnknown)
            }
            return (device, caseSensitive)
        }
        let leftVolume = try volume(for: lhs)
        let rightVolume = try volume(for: rhs)
        guard leftVolume.0 == rightVolume.0 else { return false }
        guard !leftVolume.1 && !rightVolume.1 else { return false }
        return lhs.path.compare(rhs.path, options: .caseInsensitive) == .orderedSame
    }

    private func ensureNoPendingDeletion(id: UUID, identity: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: deletionJournalDirectory.path) else { return }
        for entry in try fm.contentsOfDirectory(at: deletionJournalDirectory, includingPropertiesForKeys: nil)
        where entry.pathExtension == "json" {
            let journal = try JSONDecoder().decode(DeletionJournal.self, from: Data(contentsOf: entry))
            guard entry.lastPathComponent == "\(journal.token.uuidString).json" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let journalIdentity = try canonicalLibraryURL(journal.relativePath)
            let sameFile = try sameLibraryFile(journalIdentity, identity)
            guard journal.id != id && !sameFile else {
                throw NSError(domain: "Micromix.DeletionRecovery", code: 4, userInfo: [NSLocalizedDescriptionKey: "A deletion for this file needs recovery before it can be deleted. Use Retry deletion recovery."])
            }
        }
    }

    private func stagedURL(for journal: DeletionJournal, original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(".micromix-recovery-\(journal.token.uuidString)")
    }

    /// Reconcile only files identified by our journal; never overwrite an existing original.
    func retryDeletionRecovery() {
        let fm = FileManager.default
        deletionRecoveryIssues = []
        guard fm.fileExists(atPath: deletionJournalDirectory.path) else { return }
        do {
            // A failed metadata fetch must never be mistaken for an empty library.
            let records = try context.fetch(FetchDescriptor<LibraryRecord>())
            let entries = try fm.contentsOfDirectory(at: deletionJournalDirectory, includingPropertiesForKeys: nil)
            for entry in entries where entry.pathExtension == "json" {
                do {
                    let journal = try JSONDecoder().decode(DeletionJournal.self, from: Data(contentsOf: entry))
                    guard entry.lastPathComponent == "\(journal.token.uuidString).json" else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let original = rootDirectory.appendingPathComponent(journal.relativePath).standardizedFileURL
                    let identity = try canonicalLibraryURL(journal.relativePath)
                    let staged = stagedURL(for: journal, original: original)
                    if fm.fileExists(atPath: staged.path) {
                        let referenced = try records.contains { record in
                            if record.id == journal.id { return true }
                            return try sameLibraryFile(canonicalLibraryURL(record.relativePath), identity)
                        }
                        if referenced {
                            guard !fm.fileExists(atPath: original.path) else {
                                throw NSError(domain: "Micromix.DeletionRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Original already exists; preserve both files and recover manually from \(staged.path)"])
                            }
                            try fm.moveItem(at: staged, to: original)
                        } else {
                            try fm.removeItem(at: staged)
                        }
                    }
                    try fm.removeItem(at: entry)
                } catch {
                    deletionRecoveryIssues.append("Recovery journal \(entry.path): \(error.localizedDescription). Fix permissions or recover the staged file manually, then retry.")
                }
            }
        } catch {
            deletionRecoveryIssues.append("Cannot read deletion journals at \(deletionJournalDirectory.path): \(error.localizedDescription). Fix permissions and retry.")
        }
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

        let identity = item.provenance?.jobID ?? item.id.uuidString
        let folderName = Self.sanitized("\(String(identity.suffix(8)))-\(item.title)")
        let exportsRoot = rootDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)

        let destination = Self.unusedDirectory(named: folderName, in: exportsRoot)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            var lines = [
                "MICROMIX EXPORT — \(Self.timestamp())",
                item.provenance.map { "JOB \($0.jobID)\($0.operation.map { " · OPERATION \($0)" } ?? "")" }
                    ?? "LIBRARY ITEM \(item.id.uuidString)\(item.derivation.map { " · OPERATION \($0.operation)" } ?? "")",
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
                lines.append("\(name) — \(entry.provenance?.operation ?? entry.derivation?.operation ?? entry.kind.rawValue.uppercased()) · \(role)")
                if let derivation = entry.derivation {
                    for parentID in derivation.parentLibraryItemIDs {
                        let status = grouped.contains { $0.id == parentID } ? "bundled" : "not available in this bundle"
                        lines.append("  Local parent \(parentID.uuidString): \(status).")
                    }
                }
                if entry.provenance == nil && entry.derivation == nil {
                    lines.append("  WARNING: provenance and original source availability are unknown.")
                } else if inputs.isEmpty && entry.derivation == nil {
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

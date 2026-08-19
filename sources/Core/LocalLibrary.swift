import Foundation
import Combine

/// Manages persistence of generated audio / transcribed MIDI plus a JSON
/// manifest. Runs on the main actor; mutations are serialized.
///
/// Directory layout under the library root:
///   library.json   — array of `LibraryItem`
///   audio/<uuid>.wav
///   midi/<uuid>.mid
///
/// Crash-safety ordering: the data file is written first, then the manifest
/// entry is committed atomically (temp write + rename). Deletion removes the
/// file first, then rewrites the manifest.
@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    let rootDirectory: URL
    private let manifestURL: URL

    /// Create a library rooted at `directory` (defaults to App Support/Micromix).
    /// Tests inject a temp dir.
    init(directory: URL? = nil) {
        let root = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Micromix", isDirectory: true)
        self.rootDirectory = root
        self.manifestURL = root.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? Self.decoder.decode([LibraryItem].self, from: data)
        else { return }
        items = decoded
    }

    /// Absolute URL for a stored item's data file.
    func resolvedURL(for item: LibraryItem) -> URL {
        rootDirectory.appendingPathComponent(item.relativePath)
    }

    // MARK: - Mutating

    /// Writes `bytes` to disk first, then appends the manifest entry atomically.
    func add(_ item: LibraryItem, bytes: Data) throws {
        // 1. Write the data file.
        let fileURL = resolvedURL(for: item)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL)

        // 2. Append the manifest entry and commit atomically.
        items.append(item)
        try persistManifest()
    }

    /// Removes the data file, then rewrites the manifest without the entry.
    func remove(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        // 1. Delete the file first (best-effort: tolerate a missing file).
        let fileURL = resolvedURL(for: item)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        // 2. Remove the manifest entry and commit atomically.
        items.remove(at: index)
        try persistManifest()
    }

    /// Replaces library.json via a temp file + atomic rename.
    private func persistManifest() throws {
        let data = try Self.encoder.encode(items)
        let tempURL = rootDirectory.appendingPathComponent("library.json.tmp")
        try data.write(to: tempURL, options: .atomic)
        try FileManager.default.replaceItemAt(manifestURL, withItemAt: tempURL)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

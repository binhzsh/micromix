import Foundation
import Combine

/// User-configurable app settings. v1 holds the API base URL, persisted as
/// JSON under the Micromix application-support directory.
@MainActor
final class SettingsStore: ObservableObject {
    nonisolated static let defaultBaseURL = "http://10.10.10.10:8902"

    @Published var baseURL: String

    private let directory: URL
    private let fileURL: URL

    /// Create a store rooted at `directory`. Defaults to
    /// `~/Library/Application Support/Micromix/`. Tests inject a temp dir.
    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Micromix", isDirectory: true)

        // Create an immutable backing value so self is fully initialized
        // before calling load(). The stored default is only a fallback if
        // the file is absent.
        self.directory = base
        self.fileURL = base.appendingPathComponent("settings.json")
        self.baseURL = Self.defaultBaseURL
        load()
    }

    /// Persist the current baseURL atomically.
    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = ["baseURL": baseURL]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = json["baseURL"] as? String, !saved.isEmpty
        else { return }
        baseURL = saved
    }
}

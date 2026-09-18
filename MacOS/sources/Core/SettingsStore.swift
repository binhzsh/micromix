import Foundation
import Combine

/// Local inference settings persisted under the Micromix application-support directory.
@MainActor
final class SettingsStore: ObservableObject {
    nonisolated static let defaultBaseURL = "http://127.0.0.1:8902"

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
        if !Self.isLoopbackEndpoint(baseURL) {
            baseURL = Self.defaultBaseURL
        }
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
        guard Self.isLoopbackEndpoint(saved) else {
            baseURL = Self.defaultBaseURL
            try? save()
            return
        }
        baseURL = saved
    }

    private static func isLoopbackEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

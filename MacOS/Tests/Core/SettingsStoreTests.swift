import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("SettingsStore persistence")
struct SettingsStoreTests {

    @Test("save/load round-trips baseURL through JSON")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        #expect(store.baseURL == SettingsStore.defaultBaseURL)
        store.baseURL = "http://localhost:8903"
        try store.save()

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.baseURL == "http://localhost:8903")
    }

    @Test("saved non-loopback address is replaced with the loopback endpoint")
    func replacesExternalEndpoint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.baseURL = "http://10.10.10.10:8902"
        try store.save()

        let reloaded = SettingsStore(directory: dir)

        #expect(reloaded.baseURL == SettingsStore.defaultBaseURL)
        let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(payload?["baseURL"] == SettingsStore.defaultBaseURL)
    }

    @Test("saving a non-loopback endpoint stores the loopback endpoint instead")
    func saveNormalizesExternalEndpoint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.baseURL = "http://example.com:8902"

        try store.save()

        #expect(store.baseURL == SettingsStore.defaultBaseURL)
        let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(payload?["baseURL"] == SettingsStore.defaultBaseURL)
    }

    @Test("missing settings file yields the default")
    func missingDefaults() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        #expect(store.baseURL == SettingsStore.defaultBaseURL)
    }
}

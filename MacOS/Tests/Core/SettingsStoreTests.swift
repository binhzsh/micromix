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

    @Test("saved lts1 address migrates to local inference")
    func migratesLegacyServer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.baseURL = "http://10.10.10.10:8902"
        try store.save()
        #expect(SettingsStore(directory: dir).baseURL == "http://127.0.0.1:8902")
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

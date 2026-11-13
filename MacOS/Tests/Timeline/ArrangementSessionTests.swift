import Foundation
import Testing
@testable import Micromix

@Suite @MainActor struct ArrangementSessionTests {
    @Test func decisionsDoNotProceedAfterCancelOrFailedSave() {
        #expect(!ArrangementSession.mayProceed(.cancel))
        #expect(!ArrangementSession.mayProceed(.save, saveSucceeded: false))
        #expect(ArrangementSession.mayProceed(.save, saveSucceeded: true))
        #expect(ArrangementSession.mayProceed(.discard))
    }

    @Test func nativeCloseGuardHandlesCleanAndDirtyDecisions() {
        var choices = 0, saves = 0
        func check(_ dirty: Bool, _ decision: ArrangementSession.Decision, _ success: Bool) -> Bool {
            ArrangementSession.mayClose(isDirty: dirty, choose: { choices += 1; return decision }, save: { saves += 1; return success })
        }
        #expect(check(false, .cancel, false))
        #expect(choices == 0 && saves == 0)
        #expect(!check(true, .cancel, true))
        #expect(check(true, .discard, false))
        #expect(saves == 0)
        #expect(!check(true, .save, false))
        #expect(check(true, .save, true))
        #expect(saves == 2)
    }

    @Test func quitChecksOnlyRegisteredEditorsAndStopsOnRejection() {
        let registry = TimelineCloseRegistry()
        let first = UUID(), second = UUID()
        var firstCalls = 0
        registry.register(first) { firstCalls += 1; return true }
        registry.register(second) { false }
        #expect(!registry.mayQuit())
        registry.unregister(second)
        #expect(registry.mayQuit())
        #expect(firstCalls >= 1)
        registry.register(first) { false }
        #expect(!registry.mayQuit())
        registry.unregister(first)
        #expect(registry.mayQuit())
    }

    @Test func baselineChangesOnlyAfterSuccessfulSaveOrOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("arrangement.json")
        let document = ArrangementDocument(tracks: [.init(libraryID: UUID(), title: "Missing", offset: 1, trimStart: 0, trimEnd: 2)])
        var session = ArrangementSession()
        let model = TimelineModel()
        let library = LocalLibrary(directory: root.appendingPathComponent("library"))
        #expect(!session.isDirty(model.documentSnapshot))
        #expect(session.isDirty(document))
        #expect(throws: (any Error).self) { try session.save(document, to: root.appendingPathComponent("absent/file.json")) }
        #expect(session.isDirty(document) && session.url == nil)
        try session.save(document, to: url)
        #expect(!session.isDirty(document))
        try session.open(from: url, into: model, library: library)
        #expect(model.documentSnapshot == document && model.tracks[0].url == nil)
        #expect(!session.isDirty(model.documentSnapshot))
        model.remove(id: model.tracks[0].id)
        #expect(session.isDirty(model.documentSnapshot))
        let before = model.documentSnapshot
        let invalid = root.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try session.open(from: invalid, into: model, library: library) }
        #expect(model.documentSnapshot == before && session.url == url && session.isDirty(before))
    }
}

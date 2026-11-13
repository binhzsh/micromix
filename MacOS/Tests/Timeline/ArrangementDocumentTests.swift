import Foundation
import Testing
@testable import Micromix

@Suite struct ArrangementDocumentTests {
    @Test func roundTripPreservesOrderAndReferences() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let document = ArrangementDocument(tracks: [
            .init(libraryID: id, title: "Original title", offset: 2, trimStart: 1, trimEnd: 4),
            .init(libraryID: id, title: "Another instance", offset: 5, trimStart: 0, trimEnd: 1)
        ])
        try document.save(to: url)
        #expect(try ArrangementDocument.open(from: url) == document)
    }

    @Test func malformedAndUnsupportedDocumentsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not JSON".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ArrangementDocument.open(from: url) }
        try Data("{\"version\":2,\"tracks\":[]}".utf8).write(to: url)
        #expect(throws: ArrangementError.self) { try ArrangementDocument.open(from: url) }
    }

    @Test func invalidSaveDoesNotReplaceExistingDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = ArrangementDocument(tracks: [])
        try valid.save(to: url)
        let invalid = ArrangementDocument(tracks: [
            .init(libraryID: UUID(), title: "Bad", offset: -1, trimStart: 0, trimEnd: 1)
        ])
        #expect(throws: ArrangementError.self) { try invalid.save(to: url) }
        #expect(try ArrangementDocument.open(from: url) == valid)
    }
}

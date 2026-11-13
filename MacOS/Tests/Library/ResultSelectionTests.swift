import Foundation
import Testing
@testable import Micromix

@Suite("Result selection")
struct ResultSelectionTests {
    @Test("selection follows identity across reordering and missing results")
    func selectionIdentity() {
        let a = item("A"), b = item("B")
        var selection = ResultSelection()
        selection.reset(for: [a, b])
        #expect(selection.selected(in: [a, b])?.id == a.id)
        selection.select(b.id)
        #expect(selection.selected(in: [b, a])?.id == b.id)
        #expect(selection.selected(in: [a]) == nil)
        selection.reset(for: [a])
        #expect(selection.selected(in: [a])?.id == a.id)
        selection.reset(for: [])
        #expect(selection.selectedID == nil)
    }

    @Test("all result actions resolve the current available selection and reject stale closures")
    func actionTargets() {
        let a = item("A"), b = item("B")
        let results = [a, b]
        var selection = ResultSelection()
        selection.reset(for: results)
        let firstGeneration = selection.generation
        // Preview, continuation, export and reveal all use this same resolver.
        for _ in 0..<4 {
            #expect(selection.actionTarget(expectedID: a.id, generation: firstGeneration,
                                           results: results, available: { _ in true })?.id == a.id)
        }
        selection.select(b.id)
        let secondGeneration = selection.generation
        for _ in 0..<4 {
            #expect(selection.actionTarget(expectedID: a.id, generation: firstGeneration,
                                           results: results, available: { _ in true }) == nil)
            #expect(selection.actionTarget(expectedID: b.id, generation: secondGeneration,
                                           results: results, available: { _ in true })?.id == b.id)
            #expect(selection.actionTarget(expectedID: b.id, generation: secondGeneration,
                                           results: results, available: { _ in false }) == nil)
            #expect(selection.actionTarget(expectedID: b.id, generation: secondGeneration,
                                           results: [a], available: { _ in true }) == nil)
        }
        selection.select(a.id)
        #expect(selection.actionTarget(expectedID: a.id, generation: firstGeneration,
                                       results: results, available: { _ in true }) == nil)
        let beforeRerun = selection.generation
        selection.reset(for: results)
        #expect(selection.actionTarget(expectedID: a.id, generation: beforeRerun,
                                       results: results, available: { _ in true }) == nil)
    }

    private func item(_ title: String) -> LibraryItem {
        LibraryItem(id: UUID(), kind: .audio, title: title, createdAt: Date(),
                    promptOrSource: "test", durationSeconds: nil, relativePath: "audio/\(title).wav")
    }
}

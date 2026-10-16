import Foundation
import Testing
@testable import Micromix

@Suite("ABCompare")
struct ABCompareTests {
    @Test("compare toggle swaps to the other pinned item")
    func swapBetweenPins() {
        let a = item(named: "A")
        let b = item(named: "B")
        #expect(LibraryScreen.compareNext(currentID: a.id, a: a, b: b).id == b.id)
        #expect(LibraryScreen.compareNext(currentID: b.id, a: a, b: b).id == a.id)
    }

    @Test("compare toggle starts with A when nothing is loaded")
    func startWithA() {
        let a = item(named: "A")
        let b = item(named: "B")
        #expect(LibraryScreen.compareNext(currentID: nil, a: a, b: b).id == a.id)
    }

    @Test("compare toggle starts with A when an unrelated item is loaded")
    func unrelatedLoaded() {
        let a = item(named: "A")
        let b = item(named: "B")
        let other = item(named: "Other")
        #expect(LibraryScreen.compareNext(currentID: other.id, a: a, b: b).id == a.id)
    }

    @Test("loaded indicator covers both pinned slots")
    func loadedIndicator() {
        let a = item(named: "A")
        let b = item(named: "B")
        #expect(LibraryScreen.isCompareLoaded(a: a, b: b, loadedID: a.id))
        #expect(LibraryScreen.isCompareLoaded(a: a, b: b, loadedID: b.id))
        #expect(!LibraryScreen.isCompareLoaded(a: a, b: b, loadedID: nil))
        #expect(!LibraryScreen.isCompareLoaded(a: a, b: b, loadedID: UUID()))
    }

    private func item(named title: String) -> LibraryItem {
        LibraryItem(
            id: UUID(),
            kind: .audio,
            title: title,
            createdAt: Date(),
            promptOrSource: "test",
            durationSeconds: nil,
            relativePath: "audio/test.wav"
        )
    }
}

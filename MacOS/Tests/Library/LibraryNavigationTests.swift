import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Library navigation filters")
struct LibraryNavigationTests {
    @Test("navigation clears only filters that hide the target")
    func navigationFilters() {
        let target = LibraryItem(id: UUID(), kind: .audio, title: "Sunset", createdAt: .now,
                                 promptOrSource: "source", durationSeconds: nil, relativePath: "audio/sunset.wav")
        let cases: [(LibraryCollection, String, LibraryCollection, String)] = [
            (.audio, " SUNSET ", .audio, " SUNSET "),
            (.audio, "other", .audio, ""),
            (.midi, "sunset", .all, "sunset"),
            (.midi, "other", .all, ""),
            (.all, "  ", .all, "  ")
        ]
        for (collection, search, expectedCollection, expectedSearch) in cases {
            let filters = LibraryScreen.filtersForNavigation(to: target, collection: collection, searchText: search)
            #expect(filters.collection == expectedCollection)
            #expect(filters.searchText == expectedSearch)
            #expect(LibraryScreen.matches(target, collection: filters.collection, searchText: filters.searchText))
        }
    }
}

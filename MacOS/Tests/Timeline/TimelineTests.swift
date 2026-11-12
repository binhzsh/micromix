import Foundation
import Testing
@testable import Micromix

@Suite struct TimelineTests {
    private func track() -> TimelineTrack {
        TimelineTrack(title: "Audio", url: URL(fileURLWithPath: "/tmp/audio.wav"), sourceDuration: 10, trimEnd: 10)
    }

    @Test func validTiming() throws {
        var value = track()
        value.offset = 2
        value.trimStart = 1
        value.trimEnd = 9
        try value.validate()
    }

    @Test func rejectsInvalidTiming() {
        var value = track()
        value.offset = -1
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.trimStart = 10
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.trimEnd = 11
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.offset = .nan
        #expect(throws: TimelineError.self) { try value.validate() }
    }
}

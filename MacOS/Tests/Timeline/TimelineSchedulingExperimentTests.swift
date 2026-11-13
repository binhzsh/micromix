import Testing
@testable import Micromix

@Suite struct TimelineSchedulingExperimentTests {
    typealias Mixer = TimelineFramePrototype
    typealias Scheduler = TimelineSchedulingExperiment

    private func plan() throws -> Mixer {
        let fade = Mixer.Ramp(start: 0, end: 5, from: 0, to: 1)
        return try Mixer(clips: [
            .init(samples: [1, 1, 1, 1, 1, 1], sourceStart: 0, length: 6,
                  timelineStart: 2, gain: 1, muted: false, ramps: [fade]),
            .init(samples: [0.5, 0.5, 0.5], sourceStart: 0, length: 3,
                  timelineStart: 4, gain: 1, muted: false, ramps: [])
        ])
    }

    private func drain(_ scheduler: inout Scheduler) throws -> [Float] {
        var output: [Float] = []
        while let work = scheduler.next() {
            let samples = try scheduler.render(work)
            let accepted = scheduler.accept(work, samples: samples)
            output += try #require(accepted)
        }
        return output
    }

    @Test func offlineAndSimulatedPlaybackUseSamePlanAcrossBlocksAndSeek() throws {
        let mixer = try plan()
        var offline = try Scheduler(plan: mixer, blockSize: 3)
        var playback = try Scheduler(plan: mixer, blockSize: 2)
        let reference = try drain(&offline)
        let direct = try mixer.render(start: 0, count: Int(mixer.duration))
        #expect(reference == direct)
        #expect(try drain(&playback) == reference)
        try playback.seek(to: 3)
        #expect(try drain(&playback) == Array(reference[3...]))
        try playback.seek(to: mixer.duration)
        #expect(playback.next() == nil)
    }

    @Test func seekRejectsRenderedAndOutstandingStaleWork() throws {
        var scheduler = try Scheduler(plan: plan(), blockSize: 3)
        let oldWork = scheduler.next()
        let old = try #require(oldWork)
        let rendered = try scheduler.render(old)
        #expect(scheduler.next() == old)
        try scheduler.seek(to: 0)
        let currentWork = scheduler.next()
        let current = try #require(currentWork)
        #expect(scheduler.accept(old, samples: rendered) == nil)
        #expect(scheduler.position == 0)
        #expect(scheduler.accept(current, samples: []) == nil)
        let currentSamples = try scheduler.render(current)
        #expect(scheduler.accept(current, samples: currentSamples) == rendered)
        #expect(scheduler.accept(current, samples: rendered) == nil)
        #expect(scheduler.position == 3)
    }

    @Test func boundsAndFinalPartialBlock() throws {
        let mixer = try plan()
        #expect(throws: Scheduler.Failure.self) { try Scheduler(plan: mixer, blockSize: 0) }
        #expect(throws: Scheduler.Failure.self) {
            try Scheduler(plan: mixer, blockSize: Mixer.maximumBlockFrames + 1)
        }
        var scheduler = try Scheduler(plan: mixer, blockSize: 3)
        #expect(throws: Scheduler.Failure.self) { try scheduler.seek(to: -1) }
        #expect(throws: Scheduler.Failure.self) { try scheduler.seek(to: mixer.duration + 1) }
        try scheduler.seek(to: mixer.duration - 1)
        let lastWork = scheduler.next()
        let last = try #require(lastWork)
        #expect(last.count == 1)
        let samples = try scheduler.render(last)
        _ = scheduler.accept(last, samples: samples)
        #expect(scheduler.next() == nil)
        let empty = try Mixer(clips: [])
        var emptyScheduler = try Scheduler(plan: empty, blockSize: 1)
        #expect(emptyScheduler.next() == nil)
    }
}

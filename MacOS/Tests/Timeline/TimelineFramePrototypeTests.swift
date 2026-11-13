import Testing
@testable import Micromix

@Suite struct TimelineFramePrototypeTests {
    typealias Mixer = TimelineFramePrototype

    private func clip(_ samples: [Float], source: Int64 = 0, length: Int64, at: Int64 = 0,
                      gain: Float = 1, muted: Bool = false, ramps: [Mixer.Ramp] = []) -> Mixer.Clip {
        .init(samples: samples, sourceStart: source, length: length, timelineStart: at,
              gain: gain, muted: muted, ramps: ramps)
    }

    @Test func overlapGainMuteAndSeek() throws {
        let plan = try Mixer(clips: [
            clip([0, 1, 0, 0], length: 4, at: 2, gain: 0.5),
            clip([1, 1, 1], length: 3, at: 3, gain: 0.25),
            clip([10], length: 1, at: 3, muted: true)
        ])
        #expect(plan.duration == 6)
        let full = try plan.render(start: 0, count: 8)
        #expect(full == [0, 0, 0, 0.75, 0.25, 0.25, 0, 0])
        #expect(try plan.render(start: 3, count: 3) == Array(full[3..<6]))
        #expect(try plan.render(start: 0, count: 3) + plan.render(start: 3, count: 5) == full)
    }

    @Test func splitInsideFadePreservesSamples() throws {
        let pcm: [Float] = [1, 1, 1, 1, 1, 1]
        let fade = Mixer.Ramp(start: 0, end: 5, from: 0, to: 1)
        let whole = try Mixer(clips: [clip(pcm, length: 6, at: 2, ramps: [fade])])
        let split = try Mixer(clips: [clip(pcm, length: 3, at: 2, ramps: [fade]),
                                      clip(pcm, source: 3, length: 3, at: 5, ramps: [fade])])
        #expect(try whole.render(start: 0, count: 9) == split.render(start: 0, count: 9))
        #expect(try split.render(start: 5, count: 2) == whole.render(start: 5, count: 2))
    }

    @Test func opposingFadesAndValidation() throws {
        let up = Mixer.Ramp(start: 0, end: 4, from: 0, to: 1)
        let down = Mixer.Ramp(start: 0, end: 4, from: 1, to: 0)
        let plan = try Mixer(clips: [clip([1, 1, 1, 1, 1], length: 5, ramps: [up]),
                                     clip([1, 1, 1, 1, 1], length: 5, ramps: [down])])
        #expect(try plan.render(start: 0, count: 5) == [1, 1, 1, 1, 1])
        #expect(throws: Mixer.Failure.self) { try Mixer(clips: [clip([1], length: 2)]) }
        #expect(throws: Mixer.Failure.self) { try Mixer(clips: [clip([1], length: 1, at: .max)]) }
        #expect(throws: Mixer.Failure.self) { try plan.render(start: .max, count: 1) }
        #expect(throws: Mixer.Failure.self) { try plan.render(start: 0, count: Mixer.maximumBlockFrames + 1) }
    }
}

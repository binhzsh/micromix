import Foundation

/// Headless mono reference mixer. Inputs are already continuous session-rate PCM;
/// this is not a transport, decoder, resampler, or production export path.
struct TimelineFramePrototype {
    enum Failure: Error {
        case invalidClip, invalidRenderRange
    }

    /// Linear envelope in source-frame coordinates. Splits retain this original
    /// domain rather than restarting the fade. Values outside the domain clamp.
    struct Ramp {
        let start: Int64
        let end: Int64
        let from: Float
        let to: Float

        func value(at frame: Int64) -> Float {
            if frame <= start { return from }
            if frame >= end { return to }
            let progress = Float(Double(frame - start) / Double(end - start))
            return from + (to - from) * progress
        }
    }

    struct Clip {
        let samples: [Float]
        let sourceStart: Int64
        let length: Int64
        let timelineStart: Int64
        let gain: Float
        let muted: Bool
        let ramps: [Ramp]
    }

    private let clips: [Clip]
    let duration: Int64
    static let maximumBlockFrames = 65_536

    init(clips: [Clip]) throws {
        var duration: Int64 = 0
        for clip in clips {
            let (sourceEnd, sourceOverflow) = clip.sourceStart.addingReportingOverflow(clip.length)
            let (timelineEnd, timelineOverflow) = clip.timelineStart.addingReportingOverflow(clip.length)
            guard clip.sourceStart >= 0, clip.timelineStart >= 0, clip.length > 0,
                  !sourceOverflow, !timelineOverflow, sourceEnd <= Int64(clip.samples.count),
                  clip.gain.isFinite, clip.samples.allSatisfy(\.isFinite),
                  clip.ramps.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.from.isFinite && $0.to.isFinite })
            else { throw Failure.invalidClip }
            duration = max(duration, timelineEnd)
        }
        self.clips = clips
        self.duration = duration
    }

    /// Returns exactly `count` frames, including silence beyond the plan end.
    /// Stateless range rendering makes seeks and block boundaries deterministic.
    func render(start: Int64, count: Int) throws -> [Float] {
        guard start >= 0, count >= 0, count <= Self.maximumBlockFrames else {
            throw Failure.invalidRenderRange
        }
        let (end, overflow) = start.addingReportingOverflow(Int64(count))
        guard !overflow else { throw Failure.invalidRenderRange }
        var output = [Float](repeating: 0, count: count)
        for clip in clips where !clip.muted {
            let lower = max(start, clip.timelineStart)
            let upper = min(end, clip.timelineStart + clip.length)
            guard lower < upper else { continue }
            for frame in lower..<upper {
                let source = clip.sourceStart + (frame - clip.timelineStart)
                var amplitude = clip.gain
                for ramp in clip.ramps { amplitude *= ramp.value(at: source) }
                output[Int(frame - start)] += clip.samples[Int(source)] * amplitude
            }
        }
        return output
    }
}

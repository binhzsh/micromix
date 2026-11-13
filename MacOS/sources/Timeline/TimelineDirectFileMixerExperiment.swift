import Foundation

/// Single-consumer, headless offline experiment; files must already be mono 48 kHz PCM.
/// Memory is bounded by block size and region metadata, not timeline duration.
struct TimelineDirectFileMixerExperiment {
    enum Failure: Error { case invalidRegion, invalidRange }
    struct Region {
        let reader: TimelineFilePCMReader
        let sourceStart: Int64
        let length: Int64
        let timelineStart: Int64
        let gain: Float
        let muted: Bool
        let ramps: [TimelineFramePrototype.Ramp]
    }

    private let regions: [Region]
    init(regions: [Region]) throws {
        for region in regions {
            let (sourceEnd, sourceOverflow) = region.sourceStart.addingReportingOverflow(region.length)
            let (_, timelineOverflow) = region.timelineStart.addingReportingOverflow(region.length)
            guard region.sourceStart >= 0, region.timelineStart >= 0, region.length > 0,
                  !sourceOverflow, !timelineOverflow, sourceEnd <= region.reader.length,
                  region.gain.isFinite,
                  region.ramps.allSatisfy({ $0.start >= 0 && $0.end > $0.start && $0.from.isFinite && $0.to.isFinite })
            else { throw Failure.invalidRegion }
        }
        self.regions = regions
    }

    /// Emits exactly count frames, including silence outside regions. Errors from the
    /// reader or callback propagate; previously emitted blocks cannot be retracted.
    func render(start: Int64, count: Int64, blockSize: Int,
                write: ([Float]) throws -> Void) throws {
        let (end, overflow) = start.addingReportingOverflow(count)
        guard start >= 0, count >= 0, !overflow,
              (1...TimelineFilePCMReader.maximumBlockFrames).contains(blockSize) else {
            throw Failure.invalidRange
        }
        var position = start
        while position < end {
            let size = Int(min(Int64(blockSize), end - position))
            let blockEnd = position + Int64(size)
            var output = [Float](repeating: 0, count: size)
            for region in regions where !region.muted {
                let lower = max(position, region.timelineStart)
                let upper = min(blockEnd, region.timelineStart + region.length)
                guard lower < upper else { continue }
                let source = region.sourceStart + (lower - region.timelineStart)
                let samples = try region.reader.read(start: source, count: Int(upper - lower))
                for index in samples.indices {
                    var amplitude = region.gain
                    for ramp in region.ramps { amplitude *= ramp.value(at: source + Int64(index)) }
                    output[Int(lower - position) + index] += samples[index] * amplitude
                }
            }
            try write(output)
            position = blockEnd
        }
    }
}

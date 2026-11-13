import Foundation

/// Headless, single-consumer scheduling experiment. It neither plays audio nor
/// models a device clock; PCM in the shared reference plan remains in memory.
struct TimelineSchedulingExperiment {
    enum Failure: Error {
        case invalidBlockSize, invalidSeek
    }

    struct Work: Equatable {
        fileprivate let generation: UUID
        let start: Int64
        let count: Int
    }

    private let plan: TimelineFramePrototype
    private let blockSize: Int
    private var generation = UUID()
    private var pending: Work?
    private(set) var position: Int64 = 0

    init(plan: TimelineFramePrototype, blockSize: Int) throws {
        guard blockSize > 0, blockSize <= TimelineFramePrototype.maximumBlockFrames else {
            throw Failure.invalidBlockSize
        }
        self.plan = plan
        self.blockSize = blockSize
    }

    /// A seek invalidates even already-rendered work. The endpoint is allowed.
    mutating func seek(to frame: Int64) throws {
        guard frame >= 0, frame <= plan.duration else { throw Failure.invalidSeek }
        generation = UUID()
        pending = nil
        position = frame
    }

    /// Both offline and simulated playback consumers request the same ranges.
    /// Only one block can be outstanding per consumer.
    mutating func next() -> Work? {
        if let pending { return pending }
        guard position < plan.duration else { return nil }
        let count = Int(min(Int64(blockSize), plan.duration - position))
        let work = Work(generation: generation, start: position, count: count)
        pending = work
        return work
    }

    /// Rendering may happen before a seek; acceptance must happen afterwards on
    /// the scheduler's owning serial executor, not on an audio callback thread.
    func render(_ work: Work) throws -> [Float] {
        try plan.render(start: work.start, count: work.count)
    }

    mutating func accept(_ work: Work, samples: [Float]) -> [Float]? {
        guard work.generation == generation, pending == work, samples.count == work.count else {
            return nil
        }
        position += Int64(work.count)
        pending = nil
        return samples
    }
}

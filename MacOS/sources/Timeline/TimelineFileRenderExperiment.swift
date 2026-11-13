import AVFoundation

/// Headless M0 experiment, not a real-time scheduler or production media reader.
/// The source is a mono 48 kHz file read as Float32 in bounded, random-access blocks.
final class TimelineFilePCMReader {
    enum Failure: Error { case unsupportedFormat, invalidRange, shortRead }
    static let maximumBlockFrames = 16_384
    private let file: AVAudioFile
    var length: Int64 { file.length }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 48_000 else {
            throw Failure.unsupportedFormat
        }
    }

    func read(start: Int64, count: Int) throws -> [Float] {
        guard start >= 0, start <= length, count >= 0, count <= Self.maximumBlockFrames,
              Int64(count) <= length - start else { throw Failure.invalidRange }
        guard count > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(count)) else {
            throw Failure.shortRead
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength == count, let samples = buffer.floatChannelData?[0] else {
            throw Failure.shortRead
        }
        return Array(UnsafeBufferPointer(start: samples, count: count))
    }
}

/// Schedules bounded mono file regions on separate players at absolute frames.
/// Output is delivered in bounded blocks; no audio hardware is opened.
enum TimelineFileRenderExperiment {
    enum Failure: Error { case invalidRange, setup, render }

    struct Region {
        let reader: TimelineFilePCMReader
        let sourceStart: Int64
        let count: Int
        let timelineStart: Int64
        let gain: Float
        let muted: Bool
    }

    static func render(reader: TimelineFilePCMReader, sourceStart: Int64, count: Int,
                       timelineStart: Int64, duration: Int, blockSize: Int,
                       write: ([Float]) throws -> Void) throws {
        try render(regions: [Region(reader: reader, sourceStart: sourceStart, count: count,
                                    timelineStart: timelineStart, gain: 1, muted: false)],
                   duration: duration, blockSize: blockSize, write: write)
    }

    static func render(regions: [Region], duration: Int, blockSize: Int,
                       write: ([Float]) throws -> Void) throws {
        guard duration >= 0, (1...TimelineFilePCMReader.maximumBlockFrames).contains(blockSize),
              regions.allSatisfy({ region in
                  region.timelineStart >= 0 && region.timelineStart <= Int64(duration) &&
                  region.count >= 0 && Int64(region.count) <= Int64(duration) - region.timelineStart &&
                  region.gain.isFinite && region.gain >= 0 && region.gain <= 1
              }) else { throw Failure.invalidRange }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockSize)) else {
            throw Failure.setup
        }
        let engine = AVAudioEngine()
        var players: [AVAudioPlayerNode] = []
        for region in regions {
            let samples = try region.reader.read(start: region.sourceStart, count: region.count)
            let player = AVAudioPlayerNode()
            player.volume = region.muted ? 0 : region.gain
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            if region.count > 0 {
                guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(region.count)),
                      let channel = input.floatChannelData?[0] else { throw Failure.setup }
                input.frameLength = AVAudioFrameCount(region.count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: region.count) }
                player.scheduleBuffer(input, at: AVAudioTime(sampleTime: region.timelineStart, atRate: 48_000))
            }
            players.append(player)
        }
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: AVAudioFrameCount(blockSize))
        try engine.start()
        defer { players.forEach { $0.stop() }; engine.stop(); engine.disableManualRenderingMode() }
        players.forEach { $0.play() }
        var remaining = duration
        while remaining > 0 {
            let requested = AVAudioFrameCount(min(remaining, blockSize))
            let status = try engine.renderOffline(requested, to: output)
            guard status == .success, output.frameLength > 0,
                  let channel = output.floatChannelData?[0] else { throw Failure.render }
            let rendered = Int(output.frameLength)
            try write(Array(UnsafeBufferPointer(start: channel, count: rendered)))
            remaining -= rendered
        }
    }
}

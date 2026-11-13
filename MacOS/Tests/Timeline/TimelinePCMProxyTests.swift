import AVFoundation
import Foundation
import Testing
@testable import Micromix

@Suite struct TimelinePCMProxyTests {
    private func proxy(_ source: [Float], block: Int, readLimit: Int) throws -> [Float] {
        var position = 0
        var result: [Float] = []
        try TimelinePCMProxy.convert(blockFrames: block) { requested in
            let count = min(requested, readLimit, source.count - position)
            defer { position += count }
            return Array(source[position..<(position + count)])
        } write: { samples in
            #expect(samples.count <= block)
            result.append(contentsOf: samples)
        }
        return result
    }

    // Independent whole-input conversion: one input buffer and enough output capacity
    // to include the resampler tail, rather than the proxy's bounded streaming loop.
    private func oneShot(_ source: [Float]) throws -> [Float] {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(1, source.count)))!
        input.frameLength = AVAudioFrameCount(source.count)
        if !source.isEmpty {
            source.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: source.count) }
        }
        let capacity = AVAudioFrameCount(ceil(Double(source.count) * 48_000 / 44_100) + 256)
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied, !source.isEmpty else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        var result = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        if status == .haveData {
            var drainError: NSError?
            let drained = converter.convert(to: output, error: &drainError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let drainError { throw drainError }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            #expect(drained == .endOfStream)
        } else {
            #expect(status == .endOfStream)
        }
        return result
    }

    @Test func impulsesMatchWholeInputConversionAcrossBoundariesAndTail() throws {
        for length in [0, 1, 2, 17, 84, 128, 441] {
            let positions = Set([0, 1, 82, 83, 126, 127, length - 2, length - 1].filter { $0 >= 0 && $0 < length })
            // Include silence for the empty input as well as impulses at read/output boundaries.
            for position in positions.isEmpty ? [-1] : positions.sorted() {
                var source = [Float](repeating: 0, count: length)
                if position >= 0 { source[position] = 1 }
                let expected = try oneShot(source)
                for (block, readLimit) in [(127, 83), (31, 7)] {
                    let actual = try proxy(source, block: block, readLimit: readLimit)
                    #expect(actual.count == expected.count, "length \(length), impulse \(position), block \(block)")
                    for (index, pair) in zip(actual, expected).enumerated() {
                        #expect(abs(pair.0 - pair.1) < 0.00001, "length \(length), impulse \(position), block \(block), frame \(index)")
                    }
                }
            }
        }
    }

    @Test func continuousConversionAndMixedRateSplitParity() throws {
        let source = (0..<4_410).map { Float(sin(Double($0) * 0.071)) * 0.3 }
        let converted = try proxy(source, block: 127, readLimit: 83)
        let otherBlocks = try proxy(source, block: 511, readLimit: 319)
        #expect(abs(converted.count - 4_800) <= 1)
        #expect(converted.count == otherBlocks.count)
        for (a, b) in zip(converted, otherBlocks) { #expect(abs(a - b) < 0.00001) }
        #expect(converted.contains { abs($0) > 0.1 })

        typealias Mixer = TimelineFramePrototype
        let native = (0..<converted.count).map { Float(cos(Double($0) * 0.037)) * 0.2 }
        let split = converted.count / 2
        let fade = Mixer.Ramp(start: 0, end: Int64(converted.count - 1), from: 0, to: 1)
        func clip(_ pcm: [Float], _ start: Int, _ length: Int, _ at: Int, _ ramps: [Mixer.Ramp] = []) -> Mixer.Clip {
            .init(samples: pcm, sourceStart: Int64(start), length: Int64(length), timelineStart: Int64(at),
                  gain: 1, muted: false, ramps: ramps)
        }
        let whole = try Mixer(clips: [clip(converted, 0, converted.count, 0, [fade]),
                                      clip(native, 0, native.count, 0)])
        let divided = try Mixer(clips: [clip(converted, 0, split, 0, [fade]),
                                        clip(converted, split, converted.count - split, split, [fade]),
                                        clip(native, 0, native.count, 0)])
        let expected = try whole.render(start: 0, count: converted.count)
        let actual = try divided.render(start: 0, count: split) + divided.render(start: Int64(split), count: converted.count - split)
        #expect(expected == actual)
    }

    @Test func rejectsInvalidInputAndBounds() throws {
        #expect(throws: TimelinePCMProxy.Failure.self) {
            try TimelinePCMProxy.convert(blockFrames: 0, read: { _ in [] }, write: { _ in })
        }
        #expect(throws: TimelinePCMProxy.Failure.self) {
            try TimelinePCMProxy.convert(blockFrames: 16, read: { _ in [.nan] }, write: { _ in })
        }
        #expect(throws: TimelinePCMProxy.Failure.self) {
            try TimelinePCMProxy.convert(blockFrames: 16, read: { n in [Float](repeating: 0, count: n + 1) }, write: { _ in })
        }
    }
}

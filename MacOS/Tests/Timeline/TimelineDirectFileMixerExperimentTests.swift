import AVFoundation
import Foundation
import Testing
@testable import Micromix

@Suite struct TimelineDirectFileMixerExperimentTests {
    typealias Mixer = TimelineDirectFileMixerExperiment

    private func fixture(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, value) in samples.enumerated() { channel[index] = value }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func longRegionsSeekSplitAndFadesMatchReference() throws {
        let samples = (0..<50_100).map { Float(($0 % 31) - 15) / 32 }
        let url = try fixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TimelineFilePCMReader(url: url)
        let fade = TimelineFramePrototype.Ramp(start: 100, end: 49_000, from: 0, to: 1)
        func region(_ source: Int64, _ length: Int64, _ at: Int64, _ gain: Float = 1, _ muted: Bool = false) -> Mixer.Region {
            .init(reader: reader, sourceStart: source, length: length, timelineStart: at, gain: gain, muted: muted, ramps: [fade])
        }
        let whole = [region(50, 49_500, 37), region(300, 30_000, 500, 0.3), region(0, 40_000, 0, 1, true)]
        let split = [region(50, 20_000, 37), region(20_050, 29_500, 20_037)] + Array(whole.dropFirst())
        let reference = try TimelineFramePrototype(clips: whole.map {
            .init(samples: samples, sourceStart: $0.sourceStart, length: $0.length, timelineStart: $0.timelineStart,
                  gain: $0.gain, muted: $0.muted, ramps: $0.ramps)
        })
        for regions in [whole, split] {
            let mixer = try Mixer(regions: regions)
            for (start, count, block) in [(Int64(0), 50_000, 997), (Int64(19_990), 2_100, 127), (Int64(49_500), 700, 16_384)] {
                let expected = try reference.render(start: start, count: count)
                var offset = 0
                try mixer.render(start: start, count: Int64(count), blockSize: block) { output in
                    #expect(output.count <= block)
                    for value in output {
                        #expect(abs(value - expected[offset]) < 0.000001)
                        offset += 1
                    }
                }
                #expect(offset == count)
            }
        }
    }

    @Test func validatesRangesAndOverflow() throws {
        let url = try fixture([0.5, 0.25])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TimelineFilePCMReader(url: url)
        func region(_ source: Int64, _ length: Int64, _ at: Int64, _ gain: Float = 1, _ ramps: [TimelineFramePrototype.Ramp] = []) -> Mixer.Region {
            .init(reader: reader, sourceStart: source, length: length, timelineStart: at, gain: gain, muted: true, ramps: ramps)
        }
        for invalid in [region(-1, 1, 0), region(1, 2, 0), region(.max, 1, 0), region(0, 1, .max),
                        region(0, 0, 0), region(0, 1, 0, .nan),
                        region(0, 1, 0, 1, [.init(start: 2, end: 2, from: 0, to: 1)])] {
            #expect(throws: Mixer.Failure.self) { try Mixer(regions: [invalid]) }
        }
        let mixer = try Mixer(regions: [])
        for (start, count, block) in [(Int64(-1), Int64(1), 1), (0, -1, 1), (.max, 1, 1), (0, 1, 0), (0, 1, 16_385)] {
            #expect(throws: Mixer.Failure.self) { try mixer.render(start: start, count: count, blockSize: block) { _ in } }
        }
        var called = false
        try mixer.render(start: .max, count: 0, blockSize: 1) { _ in called = true }
        #expect(!called)
    }
}

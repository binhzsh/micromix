import AVFoundation
import Foundation
import Testing
@testable import Micromix

@Suite struct TimelineFileRenderExperimentTests {
    private func fixture(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func boundedRandomReadsAndBounds() throws {
        let url = try fixture([0.1, 0.2, 0.3, 0.4, 0.5])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TimelineFilePCMReader(url: url)
        #expect(try reader.read(start: 2, count: 2) == [0.3, 0.4])
        #expect(try reader.read(start: 0, count: 1) == [0.1])
        #expect(try reader.read(start: 5, count: 0).isEmpty)
        #expect(throws: TimelineFilePCMReader.Failure.self) { try reader.read(start: 4, count: 2) }
        #expect(throws: TimelineFilePCMReader.Failure.self) { try reader.read(start: -1, count: 1) }
        #expect(throws: TimelineFilePCMReader.Failure.self) {
            try reader.read(start: 0, count: TimelineFilePCMReader.maximumBlockFrames + 1)
        }
    }

    @Test func overlappingTrimmedLanesMatchReference() throws {
        let sources: [[Float]] = [
            [0.9, 0, 0.4, 0, 0.2, 0],
            [0, 0.6, 0, -0.4, 0],
            [0.8, 0.8, 0.8, 0.8]
        ]
        let urls = try sources.map { try fixture($0) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let readers = try urls.map { try TimelineFilePCMReader(url: $0) }
        let regions = [
            TimelineFileRenderExperiment.Region(reader: readers[0], sourceStart: 1, count: 4, timelineStart: 2, gain: 0.5, muted: false),
            TimelineFileRenderExperiment.Region(reader: readers[1], sourceStart: 1, count: 3, timelineStart: 3, gain: 0.25, muted: false),
            TimelineFileRenderExperiment.Region(reader: readers[2], sourceStart: 0, count: 4, timelineStart: 1, gain: 1, muted: true)
        ]
        let clips = zip(sources, regions).map { samples, region in
            TimelineFramePrototype.Clip(samples: samples, sourceStart: region.sourceStart,
                                        length: Int64(region.count), timelineStart: region.timelineStart,
                                        gain: region.gain, muted: region.muted, ramps: [])
        }
        let reference = try TimelineFramePrototype(clips: clips)
        let expected = try reference.render(start: 0, count: 10)
        for blockSize in [2, 3, 8] {
            var actual: [Float] = []
            try TimelineFileRenderExperiment.render(regions: regions, duration: 10, blockSize: blockSize) {
                #expect($0.count <= blockSize)
                actual += $0
            }
            #expect(actual.count == expected.count)
            for (sample, target) in zip(actual, expected) { #expect(abs(sample - target) < 0.00001) }
        }
    }

    @Test func rejectsInvalidRegionParameters() throws {
        let url = try fixture([0.5, 0.25])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TimelineFilePCMReader(url: url)
        for region in [
            TimelineFileRenderExperiment.Region(reader: reader, sourceStart: 0, count: 2, timelineStart: 2, gain: 1, muted: false),
            TimelineFileRenderExperiment.Region(reader: reader, sourceStart: 0, count: 1, timelineStart: 0, gain: .nan, muted: false),
            TimelineFileRenderExperiment.Region(reader: reader, sourceStart: 0, count: 1, timelineStart: 0, gain: 1.5, muted: false)
        ] {
            #expect(throws: TimelineFileRenderExperiment.Failure.self) {
                try TimelineFileRenderExperiment.render(regions: [region], duration: 3, blockSize: 2) { _ in }
            }
        }
        let invalidSource = TimelineFileRenderExperiment.Region(reader: reader, sourceStart: 1, count: 2,
                                                                timelineStart: 0, gain: 1, muted: true)
        #expect(throws: TimelineFilePCMReader.Failure.self) {
            try TimelineFileRenderExperiment.render(regions: [invalidSource], duration: 3, blockSize: 2) { _ in }
        }
    }

    @Test func manualEngineRendersFileRegionAtExpectedFrames() throws {
        let url = try fixture([0.1, 0.25, -0.5, 0.75, 0.2])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try TimelineFilePCMReader(url: url)
        for blockSize in [2, 4] {
            var result: [Float] = []
            try TimelineFileRenderExperiment.render(reader: reader, sourceStart: 1, count: 3,
                                                    timelineStart: 3, duration: 9, blockSize: blockSize) {
                #expect($0.count <= blockSize)
                result += $0
            }
            let expected: [Float] = [0, 0, 0, 0.25, -0.5, 0.75, 0, 0, 0]
            #expect(result.count == expected.count)
            for (actual, target) in zip(result, expected) { #expect(abs(actual - target) < 0.00001) }
        }
    }
}

import AVFAudio
import Foundation
import Testing
@testable import Micromix

@Suite("Waveform peaks")
struct WaveformCoverageTests {
    private func withAudio(_ samples: [[Float]], _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(samples.count))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for channel in samples.indices {
            for frame in samples[channel].indices {
                buffer.floatChannelData![channel][frame] = samples[channel][frame]
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        try body(url)
    }

    @Test func coversRemainderAndAllChannels() throws {
        try withAudio([[0.1, 0, 0, 0, 0, 0, 0], [0, -0.8, 0, 0.4, 0, 0, -0.9]]) { url in
            let peaks = WaveformPeaks.computePeaks(for: url, count: 3)
            #expect(peaks.count == 3)
            #expect(abs(peaks[0] - 0.8) < 0.001)
            #expect(abs(peaks[1] - 0.4) < 0.001)
            #expect(abs(peaks[2] - 0.9) < 0.001)
        }
    }

    @Test func shortAudioAndInvalidCounts() throws {
        try withAudio([[0.2, -0.7]]) { url in
            let peaks = WaveformPeaks.computePeaks(for: url, count: 10)
            #expect(peaks.count == 2)
            #expect(abs(peaks[0] - 0.2) < 0.001)
            #expect(abs(peaks[1] - 0.7) < 0.001)
            #expect(WaveformPeaks.computePeaks(for: url, count: 0).isEmpty)
            #expect(WaveformPeaks.computePeaks(for: url, count: -1).isEmpty)
        }
    }

    @Test func readsBucketsAcrossChunks() throws {
        var samples = [Float](repeating: 0, count: 20_001)
        samples[16_500] = -0.75
        samples[20_000] = 0.95
        try withAudio([samples]) { url in
            let peaks = WaveformPeaks.computePeaks(for: url, count: 1)
            #expect(peaks.count == 1)
            #expect(abs(peaks[0] - 0.95) < 0.001)
        }
    }
}

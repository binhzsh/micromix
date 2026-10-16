import AVFAudio
import Foundation
import Testing
@testable import Micromix

@Suite("WaveformPeaks")
struct WaveformPeaksTests {
    @Test("peaks match the requested bar count and amplitude range")
    func peakCountAndRange() throws {
        let url = try makeSineWAV(duration: 0.2, frequency: 220)
        defer { try? FileManager.default.removeItem(at: url) }

        let peaks = WaveformPeaks.computePeaks(for: url, count: 16)
        #expect(peaks.count == 16)
        for peak in peaks {
            #expect(peak > 0)
            #expect(peak <= 1.001)
        }
    }

    @Test("louder audio produces larger peaks")
    func amplitudeReflected() throws {
        let quiet = try makeSineWAV(duration: 0.1, frequency: 220, amplitude: 0.2)
        let loud = try makeSineWAV(duration: 0.1, frequency: 220, amplitude: 0.9)
        defer {
            try? FileManager.default.removeItem(at: quiet)
            try? FileManager.default.removeItem(at: loud)
        }

        let quietPeaks = WaveformPeaks.computePeaks(for: quiet, count: 8)
        let loudPeaks = WaveformPeaks.computePeaks(for: loud, count: 8)
        let quietMax = quietPeaks.max() ?? 0
        let loudMax = loudPeaks.max() ?? 0
        #expect(loudMax > quietMax)
    }

    @Test("unreadable file yields no peaks")
    func unreadableFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        #expect(WaveformPeaks.computePeaks(for: missing, count: 8).isEmpty)
    }

    private func makeSineWAV(duration: Double, frequency: Double, amplitude: Float = 0.8) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-wave-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi
        for frame in 0..<Int(frames) {
            channel[frame] = amplitude * Float(sin(twoPi * frequency * Double(frame) / format.sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

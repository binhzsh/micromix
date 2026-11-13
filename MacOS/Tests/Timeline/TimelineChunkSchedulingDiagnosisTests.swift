import AVFoundation
import Testing
@testable import Micromix

@Suite struct TimelineChunkSchedulingDiagnosisTests {
    private func run(prefill: Bool, implicit: Bool) throws -> [Float] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4)
        try engine.start()
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        func schedule(_ start: Int) throws {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            input.frameLength = 4
            let samples = try #require(input.floatChannelData?[0])
            for i in 0..<4 { samples[i] = Float(start + i + 1) / 100 }
            player.scheduleBuffer(input, at: implicit ? nil : AVAudioTime(sampleTime: Int64(start), atRate: 48_000))
        }
        if prefill { for start in stride(from: 0, to: 16, by: 4) { try schedule(start) } }
        player.play()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        var result: [Float] = []
        for start in stride(from: 0, to: 16, by: 4) {
            if !prefill { try schedule(start) }
            let status = try engine.renderOffline(4, to: output)
            #expect(status == .success)
            let channel = try #require(output.floatChannelData?[0])
            result += Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        return result
    }

    @Test func diagnoseImmediateScheduling() throws {
        let expected = (1...16).map { Float($0) / 100 }
        for prefill in [false, true] {
            for implicit in [false, true] {
                for trial in 0..<4 {
                    let actual = try run(prefill: prefill, implicit: implicit)
                    print("CHUNK_DIAG prefill=\(prefill) implicit=\(implicit) trial=\(trial) output=\(actual)")
                    #expect(actual.count == expected.count)
                    // Late-schedule behavior is deliberately observational: it is timing-dependent.
                    if prefill { #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 }) }
                }
            }
        }
    }
}

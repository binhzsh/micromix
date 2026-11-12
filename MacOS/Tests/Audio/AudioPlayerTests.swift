import AVFAudio
import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("AudioPlayer")
struct AudioPlayerTests {
    @Test("natural playback completion returns to idle")
    func naturalCompletion() async throws {
        let url = try makeSilentWAV(duration: 0.05)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()

        #expect(player.load(url: url, item: item()) != nil)
        player.play()
        #expect(player.state == .playing)

        try await Task.sleep(for: .milliseconds(300))
        #expect(player.state == .idle)

        // Replaying a finished item is playable again (the chip's PLAY after
        // a natural completion must not be a dead click).
        player.play()
        #expect(player.state == .playing)
        player.stop()
    }

    @Test("failed load clears duration from the previous item")
    func failedLoadClearsDuration() throws {
        let url = try makeSilentWAV(duration: 0.05)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        #expect(player.load(url: url, item: item()) != nil)
        #expect(player.currentDuration != nil)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        #expect(player.load(url: missing, item: item()) == nil)
        #expect(player.currentDuration == nil)
    }

    @Test("seeking clamps and resumes from an idle or paused position")
    func seekAndResume() throws {
        let url = try makeSilentWAV(duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        let audio = item()
        #expect(player.load(url: url, item: audio) != nil)
        player.seek(to: 1)
        #expect(player.state == .paused)
        #expect(abs(player.currentTime - 1) < 0.01)
        #expect(player.shouldResume(for: audio))
        player.play()
        #expect(player.currentTime >= 1)
        player.pause()
        player.seek(to: -1)
        #expect(player.currentTime == 0)
        player.seek(to: 10)
        #expect(abs(player.currentTime - 2) < 0.01)
        player.seek(to: .nan)
        #expect(abs(player.currentTime - 2) < 0.01)
        player.stop()
        #expect(player.currentTime == 0)
        #expect(player.state == .idle)
    }

    private func makeSilentWAV(duration: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-audio-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func item() -> LibraryItem {
        LibraryItem(
            id: UUID(),
            kind: .audio,
            title: "Preview",
            createdAt: Date(),
            promptOrSource: "test",
            durationSeconds: nil,
            relativePath: "audio/test.wav"
        )
    }
}

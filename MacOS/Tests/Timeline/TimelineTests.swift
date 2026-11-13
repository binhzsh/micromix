import AVFoundation
import Foundation
import Testing
@testable import Micromix

@MainActor
private final class TimelineGate {
    var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }
    func releaseFirst() { continuations.removeFirst().resume() }
}

@Suite struct TimelineTests {
    @Test @MainActor func pauseCapturesActualTimeBeforeProgressPoll() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var player: AVPlayer?
        let model = TimelineModel(makePlayer: { item in
            let result = AVPlayer(playerItem: item)
            result.isMuted = true
            player = result
            return result
        })
        model.tracks = [TimelineTrack(title: "Test", url: url, sourceDuration: 10, trimEnd: 10)]
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        await player?.seek(to: CMTime(seconds: 3, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        model.pause()
        #expect(abs(model.position - 3) < 0.1)
        model.stop()
    }

    @Test @MainActor func stoppedPreparationCannotBlockOrClearNewPreparation() async {
        let gate = TimelineGate()
        let model = TimelineModel(beforePreparation: { await gate.wait() })
        let audio = AudioPlayer()
        let midi = MidiPreview()
        let first = Task { await model.play(stopping: audio, midiPreview: midi) }
        while gate.continuations.count < 1 { await Task.yield() }
        model.stop()
        #expect(!model.isPreparing)
        let second = Task { await model.play(stopping: audio, midiPreview: midi) }
        while gate.continuations.count < 2 { await Task.yield() }
        gate.releaseFirst()
        await first.value
        #expect(model.isPreparing)
        gate.releaseFirst()
        await second.value
        #expect(!model.isPreparing)
    }

    @Test @MainActor func pendingSeekSurvivesProgressAndPause() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let gate = TimelineGate()
        let model = TimelineModel(beforeSeek: { target in
            if target == 5 || target == 6 { await gate.wait() }
        }, makePlayer: { item in
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            return player
        })
        model.tracks = [TimelineTrack(title: "Test", url: url, sourceDuration: 10, trimEnd: 10)]
        let audio = AudioPlayer()
        let midi = MidiPreview()
        await model.play(stopping: audio, midiPreview: midi)
        model.seek(to: 5)
        while gate.continuations.isEmpty { await Task.yield() }
        model.seek(to: 6)
        while gate.continuations.count < 2 { await Task.yield() }
        gate.releaseFirst()
        await Task.yield()
        model.updateProgress()
        #expect(model.position == 6)
        model.pause()
        #expect(model.position == 6)
        gate.releaseFirst()
        model.stop()
    }
    private func track() -> TimelineTrack {
        TimelineTrack(title: "Audio", url: URL(fileURLWithPath: "/tmp/audio.wav"), sourceDuration: 10, trimEnd: 10)
    }

    @Test func validTiming() throws {
        var value = track()
        value.offset = 2
        value.trimStart = 1
        value.trimEnd = 9
        try value.validate()
    }

    @Test func boundedControls() throws {
        var value = track()
        value.setOffset(-4)
        value.setTrimStart(-3)
        value.setTrimEnd(20)
        #expect(value.offset == 0 && value.trimStart == 0 && value.trimEnd == 10)
        value.setTrimStart(20)
        value.setTrimEnd(-1)
        try value.validate()
        #expect(value.trimEnd <= value.sourceDuration && value.trimStart < value.trimEnd)
        let previous = value.offset
        value.setOffset(.nan)
        #expect(value.offset == previous)
    }

    @Test @MainActor func seekAndStopAreBounded() {
        let model = TimelineModel()
        var value = track()
        value.offset = 2
        value.trimStart = 1
        value.trimEnd = 9
        model.tracks = [value]
        #expect(model.duration == 10)
        model.seek(to: 20)
        #expect(model.position == 10)
        model.seek(to: -2)
        #expect(model.position == 0)
        model.seek(to: 4)
        model.pause()
        #expect(model.position == 4)
        model.stop()
        #expect(model.position == 0)
    }

    @Test @MainActor func preparationErrorsAreVisible() async {
        let model = TimelineModel()
        let audio = AudioPlayer()
        let midi = MidiPreview()
        await model.play(stopping: audio, midiPreview: midi)
        #expect(model.error?.contains("Add an audio track") == true)
        #expect(!model.isPreparing && !model.isPlaying)

        model.tracks = [track()]
        await model.play(stopping: audio, midiPreview: midi)
        #expect(model.error?.contains("Unable to play timeline") == true)
        #expect(!model.isPreparing && !model.isPlaying)
    }

    @Test @MainActor func compositionAlignsTrimmedTracksAndTransportResumes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var item: AVPlayerItem?
        var player: AVPlayer?
        let model = TimelineModel(makePlayer: { value in
            item = value
            let result = AVPlayer(playerItem: value)
            result.isMuted = true
            player = result
            return result
        })
        var first = TimelineTrack(title: "First", url: url, sourceDuration: 10, trimEnd: 6)
        first.trimStart = 1
        first.offset = 2
        var second = TimelineTrack(title: "Second", url: url, sourceDuration: 10, trimEnd: 9)
        second.trimStart = 4
        second.offset = 3
        model.tracks = [first, second]
        let audio = AudioPlayer()
        let midi = MidiPreview()
        model.seek(to: 4)
        await model.play(stopping: audio, midiPreview: midi)
        let composition = try #require(item?.asset as? AVComposition)
        let tracks = composition.tracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        for (track, expected) in zip(tracks, [(1.0, 2.0), (4.0, 3.0)]) {
            let segments = track.segments
            let segment = try #require(segments.first { !$0.isEmpty })
            #expect(abs(segment.timeMapping.source.start.seconds - expected.0) < 0.001)
            #expect(abs(segment.timeMapping.target.start.seconds - expected.1) < 0.001)
            #expect(abs(segment.timeMapping.target.duration.seconds - 5) < 0.001)
        }
        #expect(model.duration == 8 && model.isPlaying)
        model.seek(to: 5)
        #expect(model.position == 5)
        model.pause()
        #expect(!model.isPlaying && model.position == 5)
        await model.play(stopping: audio, midiPreview: midi)
        #expect(model.isPlaying && abs((player?.currentTime().seconds ?? -1) - 5) < 0.1)
        model.pause()
        model.seek(to: 6)
        await model.play(stopping: audio, midiPreview: midi)
        #expect(model.isPlaying && abs((player?.currentTime().seconds ?? -1) - 6) < 0.1)
        model.stop()
        #expect(!model.isPlaying && model.position == 0)
        await model.play(stopping: audio, midiPreview: midi)
        #expect(model.isPlaying && (player?.currentTime().seconds ?? -1) < 0.1)
        model.stop()
    }

    @Test @MainActor func runtimePlaybackFailureIsVisible() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var item: AVPlayerItem?
        let model = TimelineModel(makePlayer: { value in
            item = value
            let player = AVPlayer(playerItem: value)
            player.isMuted = true
            return player
        })
        model.tracks = [TimelineTrack(title: "Test", url: url, sourceDuration: 10, trimEnd: 10)]
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        #expect(model.isPlaying)
        let failure = NSError(domain: "TimelineTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic failure"])
        guard let item else {
            Issue.record("Expected a prepared player item")
            return
        }
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: failure])
        for _ in 0..<100 where model.error == nil { await Task.yield() }
        #expect(!model.isPlaying && model.position == 0)
        #expect(model.error == "Timeline playback failed: Synthetic failure")
    }

    @Test @MainActor func delayedOldNotificationsCannotInterruptRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let notifications = TimelineGate()
        let preparation = TimelineGate()
        var delayPreparation = false
        var delivered = 0
        var item: AVPlayerItem?
        let model = TimelineModel(beforePreparation: {
            if delayPreparation { await preparation.wait() }
        }, beforeNotificationDelivery: {
            await notifications.wait()
        }, afterNotificationDelivery: {
            delivered += 1
        }, makePlayer: { value in
            item = value
            let player = AVPlayer(playerItem: value)
            player.isMuted = true
            return player
        })
        model.tracks = [TimelineTrack(title: "Test", url: url, sourceDuration: 10, trimEnd: 10)]
        let audio = AudioPlayer()
        let midi = MidiPreview()
        await model.play(stopping: audio, midiPreview: midi)
        let oldItem = try #require(item)
        let failure = NSError(domain: "TimelineTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Old failure"])
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: failure])
        while notifications.continuations.count < 2 { await Task.yield() }
        model.stop()
        delayPreparation = true
        let restart = Task { await model.play(stopping: audio, midiPreview: midi) }
        while preparation.continuations.isEmpty { await Task.yield() }
        notifications.releaseFirst()
        while delivered < 1 { await Task.yield() }
        #expect(model.isPreparing && model.error == nil)
        preparation.releaseFirst()
        await restart.value
        #expect(model.isPlaying && item === oldItem)
        notifications.releaseFirst()
        while delivered < 2 { await Task.yield() }
        #expect(model.isPlaying && model.error == nil)
        model.stop()
    }

    @Test func rejectsInvalidTiming() {
        var value = track()
        value.offset = -1
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.trimStart = 10
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.trimEnd = 11
        #expect(throws: TimelineError.self) { try value.validate() }
        value = track()
        value.offset = .nan
        #expect(throws: TimelineError.self) { try value.validate() }
    }
}

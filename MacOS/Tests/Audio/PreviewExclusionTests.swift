import AVFAudio
import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Preview exclusion")
struct PreviewExclusionTests {
    private func files() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
        let wav = dir.appendingPathComponent("preview-\(UUID()).wav")
        let midi = dir.appendingPathComponent("preview-\(UUID()).mid")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
        buffer.frameLength = 480_000
        let file = try AVAudioFile(forWriting: wav, settings: format.settings)
        try file.write(from: buffer)
        // One long note, 96 ticks per quarter.
        try Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,0,96,
                  0x4d,0x54,0x72,0x6b,0,0,0,13,
                  0,0x90,60,64, 0x87,0x40,0x80,60,64, 0,0xff,0x2f,0]).write(to: midi)
        return (wav, midi)
    }

    private func item(_ kind: LibraryItemKind) -> LibraryItem {
        LibraryItem(id: UUID(), kind: kind, title: "Test", createdAt: Date(),
                    promptOrSource: "test", durationSeconds: nil, relativePath: "test")
    }

    @Test func eachStartStopsThePreviousStream() async throws {
        let (wav, mid) = try files()
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: mid) }
        let coordinator = PreviewCoordinator()
        let audio = AudioPlayer(coordinator: coordinator)
        let midi = MidiPreview(coordinator: coordinator)
        let timeline = TimelineModel()
        timeline.add(libraryID: UUID(), title: "test", url: wav)
        #expect(audio.load(url: wav, item: item(.audio)) != nil)
        #expect(midi.load(url: mid, item: item(.midi)))
        audio.play()
        midi.play()
        #expect(!audio.isPlaying && midi.isPlaying)
        audio.play()
        #expect(audio.isPlaying && !midi.isPlaying)
        await timeline.play(stopping: audio, midiPreview: midi)
        #expect(!audio.isPlaying && timeline.isPlaying)
        audio.play()
        #expect(audio.isPlaying && !timeline.isPlaying)
        #expect(midi.load(url: mid, item: item(.midi)))
        midi.play()
        await timeline.play(stopping: audio, midiPreview: midi)
        #expect(!midi.isPlaying && timeline.isPlaying)
        audio.play()
        #expect(audio.isPlaying && !timeline.isPlaying)
        #expect(midi.load(url: mid, item: item(.midi)))
        midi.play()
        #expect(midi.isPlaying && !audio.isPlaying)
        await timeline.play(stopping: audio, midiPreview: midi)
        #expect(timeline.isPlaying && !midi.isPlaying)
        #expect(midi.load(url: mid, item: item(.midi)))
        midi.play()
        #expect(midi.isPlaying && !timeline.isPlaying)
        midi.stop()
    }

    @Test func pausedMidiRemainsInspectorPreviewAfterAudioStops() throws {
        let (wav, mid) = try files()
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: mid) }
        let coordinator = PreviewCoordinator()
        let audio = AudioPlayer(coordinator: coordinator)
        let midi = MidiPreview(coordinator: coordinator)
        let audioItem = item(.audio)
        let midiItem = item(.midi)
        #expect(audio.load(url: wav, item: audioItem) != nil)
        #expect(midi.load(url: mid, item: midiItem))
        audio.play()
        midi.play()
        midi.pause()
        #expect(audio.currentItem == audioItem && audio.state == .idle)
        #expect(midi.state == .paused)
        #expect(SessionInspector.previewSelection(player: audio, midiPreview: midi) == .midi(midiItem))
        audio.play()
        #expect(SessionInspector.previewSelection(player: audio, midiPreview: midi) == .audio(audioItem))
        audio.stop()
        midi.stop()
    }

    @Test func failedTimelinePreparationPreservesExistingPreview() async throws {
        let (wav, mid) = try files()
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: mid) }
        for useMidi in [false, true] {
            let coordinator = PreviewCoordinator()
            let audio = AudioPlayer(coordinator: coordinator)
            let midi = MidiPreview(coordinator: coordinator)
            #expect(audio.load(url: wav, item: item(.audio)) != nil)
            #expect(midi.load(url: mid, item: item(.midi)))
            if useMidi { midi.play() } else { audio.play() }
            let timeline = TimelineModel()
            await timeline.play(stopping: audio, midiPreview: midi)
            #expect(timeline.error != nil)
            #expect(useMidi ? midi.isPlaying : audio.isPlaying)
            timeline.tracks = [TimelineTrack(title: "missing", url: wav.appendingPathExtension("missing"), sourceDuration: 1, trimEnd: 1)]
            await timeline.play(stopping: audio, midiPreview: midi)
            #expect(timeline.error != nil)
            #expect(useMidi ? midi.isPlaying : audio.isPlaying)
            audio.stop()
            midi.stop()
        }
    }

    @Test func latestSeekCompletesBeforePlayback() async throws {
        let (wav, mid) = try files()
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: mid) }
        let coordinator = PreviewCoordinator()
        let audio = AudioPlayer(coordinator: coordinator)
        let midi = MidiPreview(coordinator: coordinator)
        var continuation: CheckedContinuation<Void, Never>?
        var targets: [Double] = []
        let timeline = TimelineModel(beforeSeek: { target in
            targets.append(target)
            if targets.count == 1 {
                await withCheckedContinuation { continuation = $0 }
            }
        })
        timeline.add(libraryID: UUID(), title: "test", url: wav)
        let task = Task { await timeline.play(stopping: audio, midiPreview: midi) }
        while continuation == nil { await Task.yield() }
        timeline.seek(to: 4)
        #expect(!timeline.isPlaying)
        continuation?.resume()
        await task.value
        #expect(targets == [0, 4])
        #expect(timeline.isPlaying && timeline.position == 4)
        timeline.stop()
    }

    @Test func anotherStartInvalidatesPendingPreparation() async throws {
        let (wav, mid) = try files()
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: mid) }
        for (startMidi, afterPreparation) in [(false, false), (true, false), (false, true), (true, true)] {
            let coordinator = PreviewCoordinator()
            let audio = AudioPlayer(coordinator: coordinator)
            let midi = MidiPreview(coordinator: coordinator)
            var continuation: CheckedContinuation<Void, Never>?
            let suspend: @MainActor () async -> Void = {
                await withCheckedContinuation { continuation = $0 }
            }
            let timeline = TimelineModel(
                beforePreparation: { if !afterPreparation { await suspend() } },
                beforePlayback: { if afterPreparation { await suspend() } }
            )
            timeline.add(libraryID: UUID(), title: "test", url: wav)
            #expect(audio.load(url: wav, item: item(.audio)) != nil)
            #expect(midi.load(url: mid, item: item(.midi)))
            let task = Task { await timeline.play(stopping: audio, midiPreview: midi) }
            while continuation == nil { await Task.yield() }
            #expect(timeline.isPreparing)
            if startMidi { midi.play() } else { audio.play() }
            continuation?.resume()
            await task.value
            #expect(!timeline.isPreparing && !timeline.isPlaying)
            #expect(startMidi ? midi.isPlaying : audio.isPlaying)
            audio.stop()
            midi.stop()
        }
    }
}

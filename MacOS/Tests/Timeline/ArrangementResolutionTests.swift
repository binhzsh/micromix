import AVFoundation
import Foundation
import Testing
@testable import Micromix

@Suite @MainActor struct ArrangementResolutionTests {
    @Test func resolvesByIdentityAndRetainsInvalidSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalLibrary(directory: root)
        let source = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let id = UUID()
        let item = LibraryItem(id: id, kind: .audio, title: "Renamed", createdAt: .now,
                               promptOrSource: "", durationSeconds: nil, relativePath: "audio.wav")
        try library.add(item, bytes: Data(contentsOf: source))
        let unreadableID = UUID()
        let unreadable = LibraryItem(id: unreadableID, kind: .audio, title: "Broken", createdAt: .now,
                                     promptOrSource: "", durationSeconds: nil, relativePath: "broken.wav")
        try library.add(unreadable, bytes: Data("not audio".utf8))
        let document = ArrangementDocument(tracks: [
            .init(libraryID: id, title: "Snapshot", offset: 2, trimStart: 0, trimEnd: 0.5),
            .init(libraryID: UUID(), title: "Missing", offset: 0, trimStart: 0, trimEnd: 1),
            .init(libraryID: unreadableID, title: "Unreadable", offset: 0, trimStart: 0, trimEnd: 1),
            .init(libraryID: id, title: "Shortened", offset: 1, trimStart: 0, trimEnd: 2)
        ])
        let model = TimelineModel()
        try model.load(document, from: library)
        #expect(try model.arrangementDocument() == document)
        #expect(model.tracks[0].url == library.resolvedURL(for: item))
        #expect(model.tracks[1].url == nil && model.tracks[2].url == nil)
        #expect(throws: TimelineError.self) { try model.tracks[3].validate() }
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        #expect(!model.isPlaying && model.error != nil)
        model.tracks.removeSubrange(1...2)
        model.invalidate()
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        #expect(!model.isPlaying && model.error != nil)
        model.add(libraryID: id, title: item.title, url: library.resolvedURL(for: item))
        #expect(model.tracks.last?.libraryID == id)
        let before = try model.arrangementDocument()
        var invalid = document
        invalid.version = 99
        #expect(throws: ArrangementError.self) { try model.load(invalid, from: library) }
        #expect(try model.arrangementDocument() == before)

        let playable = ArrangementDocument(tracks: [document.tracks[0]])
        try model.load(playable, from: library)
        let sources = try model.referenceSources(from: library)
        #expect(sources.count == 1)
        #expect(sources[0].track == playable.tracks[0])
        #expect(sources[0].url == library.resolvedURL(for: item))
        #expect(try model.arrangementDocument() == playable)
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        #expect(model.isPlaying)
        model.pause()
        try FileManager.default.removeItem(at: library.resolvedURL(for: item))
        #expect(throws: TimelineError.self) { try model.referenceSources(from: library) }
        await model.play(stopping: AudioPlayer(), midiPreview: MidiPreview())
        #expect(!model.isPlaying && model.error != nil)
    }
}

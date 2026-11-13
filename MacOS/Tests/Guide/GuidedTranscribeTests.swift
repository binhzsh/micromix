import Foundation
import Testing
@testable import Micromix

@MainActor
private final class TranscriptionAPI: DurableTranscriptionSubmitting {
    var selections: [[String]] = []
    func submitTranscription(audio: Data, filename: String, instruments: [String], detectTempo: Bool) async throws -> RemoteJob {
        selections.append(instruments)
        return try JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"job","kind":"transcribe","state":"queued"}"#.utf8))
    }
}

@MainActor
private final class TranscriptionRecovery: ReimagineJobReattaching {
    var items: [LibraryItem] = []
    func track(_ job: RemoteJob) throws {}
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] { items }
}

@MainActor
@Suite("Guided transcription")
struct GuidedTranscribeTests {
    @Test("non-MIDI output is not reported as successful transcription")
    func rejectsNonMIDI() async {
        let api = TranscriptionAPI()
        let recovery = TranscriptionRecovery()
        recovery.items = [LibraryItem(id: UUID(), kind: .audio, title: "song.wav", createdAt: .now,
                                      promptOrSource: "song.wav", durationSeconds: nil, relativePath: "audio/song.wav")]
        let model = GuidedTranscribeModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        #expect(model.start())
        for _ in 0..<10_000 where model.isRunning { await Task.yield() }
        #expect(model.transcribedItem == nil)
        #expect(model.errorMessage == "Transcription produced no MIDI")
    }

    @Test("MIDI completion does not deliver until explicitly requested", arguments: [[], ["piano", "violin"]])
    func completionAndFilter(selection: [String]) async {
        let api = TranscriptionAPI()
        let recovery = TranscriptionRecovery()
        let midi = LibraryItem(id: UUID(), kind: .midi, title: "song.mid", createdAt: .now,
                               promptOrSource: "song.wav", durationSeconds: nil, relativePath: "midi/song.mid")
        recovery.items = [midi]
        let model = GuidedTranscribeModel(api: api, reattacher: recovery, sourceReader: { _ in Data([1]) })
        let source = URL(fileURLWithPath: "/tmp/song.wav")
        model.sourceURL = source
        model.instruments = Set(selection)
        var delivered: URL?
        model.onDeliver = { delivered = $0; return .success(()) }
        #expect(model.start())
        for _ in 0..<10_000 where model.isRunning { await Task.yield() }
        #expect(!model.isRunning)
        #expect(api.selections == [selection])
        #expect(model.transcribedItem == midi)
        #expect(delivered == nil)
        model.sourceURL = URL(fileURLWithPath: "/tmp/other.wav")
        var navigationCount = 0
        model.deliverForRemix { navigationCount += 1 }
        #expect(navigationCount == 1)
        #expect(delivered == source)
        #expect(model.deliveredSource == source.lastPathComponent)
        model.onDeliver = { _ in .failure(.init(message: "Reimagine is busy")) }
        model.deliverForRemix { navigationCount += 1 }
        #expect(navigationCount == 1)
        #expect(model.deliveredSource == nil)
        #expect(model.errorMessage == "Reimagine is busy")
        #expect(model.transcribedItem == midi)
        model.onDeliver = nil
        model.deliverForRemix { navigationCount += 1 }
        #expect(navigationCount == 1)
        #expect(model.errorMessage == "Reimagine is unavailable. Try again after reopening the app.")
        model.onDeliver = { _ in .success(()) }
        model.deliverForRemix { navigationCount += 1 }
        #expect(navigationCount == 2)
        #expect(model.deliveredSource == source.lastPathComponent)
        #expect(model.errorMessage == nil)
    }
}

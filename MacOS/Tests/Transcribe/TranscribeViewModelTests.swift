import Foundation
import Testing
@testable import Micromix

/// Fakes standing in for `MicromixAPI` / `LocalLibrary` in the TRANSCRIBE flow.
@MainActor
private final class FakeTranscriber: TranscribeServicing, @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data("fake-midi".utf8))
    var capturedFilename: String?
    var capturedInstruments: [String] = []
    var capturedDetectTempo: Bool?
    var delay: Duration = .zero

    func transcribe(audio: Data,
                    filename: String,
                    instruments: [String],
                    detectTempo: Bool) async throws -> Data {
        self.capturedFilename = filename
        self.capturedInstruments = instruments
        self.capturedDetectTempo = detectTempo
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }
}

@MainActor
private final class FakeLibrary: LibraryStoring, @unchecked Sendable {
    var saved: [(LibraryItem, Data)] = []

    func add(_ item: LibraryItem, bytes: Data) throws {
        saved.append((item, bytes))
    }
}

@MainActor
@Suite("TranscribeViewModel")
struct TranscribeViewModelTests {

    @Test("start() runs transcription and saves a .mid item")
    func transcribeFlow() async throws {
        let api = FakeTranscriber()
        let library = FakeLibrary()
        let vm = TranscribeViewModel(api: api, library: library)

        #expect(vm.select(name: "beat.wav", bytes: Data("audio".utf8)))
        vm.toggleInstrument("Piano")
        vm.toggleInstrument("Drums")

        let started = vm.start()
        #expect(started)
        #expect(vm.phase == .running)

        await waitUntil { vm.phase == .done }
        #expect(vm.phase == .done)
        #expect(api.capturedFilename == "beat.wav")
        #expect(api.capturedInstruments.sorted() == ["Drums", "Piano"].sorted())
        #expect(api.capturedDetectTempo == true)
        #expect(library.saved.count == 1)
        #expect(library.saved[0].0.kind == .midi)
        #expect(library.saved[0].0.relativePath.hasSuffix(".mid"))
        #expect(vm.lastItem != nil)
    }

    @Test("no selection errors without starting a job")
    func noSelection() throws {
        let api = FakeTranscriber()
        let library = FakeLibrary()
        let vm = TranscribeViewModel(api: api, library: library)

        let started = vm.start()
        #expect(!started)
        #expect("\(vm.phase)".contains("SELECT"))
        #expect(library.saved.isEmpty)
    }

    @Test("transcribe error surfaces error state and leaves library untouched")
    func errorFlow() async throws {
        let api = FakeTranscriber()
        api.result = .failure(MicromixAPIError(statusCode: 413, detail: "upload too large"))
        let library = FakeLibrary()
        let vm = TranscribeViewModel(api: api, library: library)
        vm.select(name: "big.wav", bytes: Data("audio".utf8))

        vm.start()
        await waitUntil { if case .error = vm.phase { return true } else { return false } }
        guard case .error(let msg) = vm.phase else {
            Issue.record("expected error, got \(vm.phase)")
            return
        }
        #expect(msg.contains("413"))
        #expect(library.saved.isEmpty)
    }

    @Test("instruments toggle in/out of the selection")
    func instrumentToggles() throws {
        let api = FakeTranscriber()
        let library = FakeLibrary()
        let vm = TranscribeViewModel(api: api, library: library)

        vm.toggleInstrument("Bass")
        vm.toggleInstrument("Piano")
        #expect(vm.instruments == ["Bass", "Piano"])

        vm.toggleInstrument("Bass")
        #expect(vm.instruments == ["Piano"])
    }

    // MARK: - helper

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
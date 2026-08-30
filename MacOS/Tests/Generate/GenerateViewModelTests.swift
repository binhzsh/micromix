import Foundation
import Testing
@testable import Micromix

/// Fakes standing in for `MicromixAPI` / `LocalLibrary` in the GENERATE flow.
@MainActor
private final class FakeGenerator: GenerateServicing, @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data("fake-audio".utf8))
    var capturedInput: String?
    var capturedLyrics: String?
    var delay: Duration = .zero

    func generate(input: String, lyrics: String?) async throws -> Data {
        self.capturedInput = input
        self.capturedLyrics = lyrics
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
@Suite("GenerateViewModel")
struct GenerateViewModelTests {

    @Test("start() from idle enters running then resolves to done with a .wav item")
    func generateFlow() async throws {
        let api = FakeGenerator()
        let library = FakeLibrary()
        let vm = GenerateViewModel(api: api, library: library)
        vm.prompt = "a chill lo-fi beat"
        #expect(vm.phase == .idle)

        let started = vm.start()
        #expect(started)
        #expect(vm.phase == .running)

        await waitUntil { vm.phase == .done }
        #expect(vm.phase == .done)
        #expect(api.capturedInput == "a chill lo-fi beat")
        #expect(library.saved.count == 1)
        #expect(library.saved[0].0.kind == .audio)
        #expect(library.saved[0].0.relativePath.hasSuffix(".wav"))
    }

    @Test("usegrams when useLyrics is on sends lyrics as input")
    func lyricsFlow() async throws {
        let api = FakeGenerator()
        let library = FakeLibrary()
        let vm = GenerateViewModel(api: api, library: library)
        vm.prompt = "prompt text"
        vm.lyrics = "la la la"
        vm.useLyrics = true

        vm.start()
        await waitUntil { vm.phase == .done }
        #expect(api.capturedInput == "la la la")
        #expect(api.capturedLyrics == "la la la")
    }

    @Test("generate error surfaces error state and leaves library untouched")
    func errorFlow() async throws {
        let api = FakeGenerator()
        api.result = .failure(MicromixAPIError(statusCode: 503, detail: "minimax down"))
        let library = FakeLibrary()
        let vm = GenerateViewModel(api: api, library: library)
        vm.prompt = "a prompt that will fail"

        vm.start()
        await waitUntil { if case .error = vm.phase { return true } else { return false } }
        guard case .error(let msg) = vm.phase else {
            Issue.record("expected error, got \(vm.phase)")
            return
        }
        #expect(msg.contains("503"))
        #expect(library.saved.isEmpty)
    }

    @Test("empty input sets error without starting a job")
    func emptyInput() throws {
        let api = FakeGenerator()
        let library = FakeLibrary()
        let vm = GenerateViewModel(api: api, library: library)
        vm.prompt = "   "

        let started = vm.start()
        #expect(!started)
        #expect("\(vm.phase)".contains("error"))
        #expect(library.saved.isEmpty)
    }

    // MARK: - helper

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

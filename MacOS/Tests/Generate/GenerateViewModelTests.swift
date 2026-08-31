import Foundation
import Testing
@testable import Micromix

/// Fakes standing in for `MicromixAPI` / `LocalLibrary` in the GENERATE flow.
@MainActor
private final class FakeGenerator: GenerateServicing, DurableGenerationSubmitting, DurableJobServicing, DurableJobCancelling, @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data("fake-audio".utf8))
    var capturedInput: String?
    var capturedLyrics: String?
    var capturedPreset: String?
    var capturedDuration: Double?
    var capturedOptions: GenerationOptions?
    var delay: Duration = .zero
    var submittedJob = try! JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"job-1\",\"kind\":\"generation\",\"state\":\"succeeded\",\"progress\":1,\"error\":null}".utf8))
    var outputs = [DownloadedRemoteAsset(asset: RemoteAsset(id: "out-1", filename: "result.wav", mediaType: "audio/wav", sizeBytes: 4, sha256: "75f56ac1ef945e2a21f45f004d29a52e618474d44dd8d36e318b3dba7c3b6de6", downloadUrl: "/v1/assets/out-1"), data: Data("wav!".utf8))]
    var cancelledJobID: String?

    func generate(input: String,
                  lyrics: String?,
                  preset: String,
                  durationSeconds: Double,
                  options: GenerationOptions) async throws -> Data {
        self.capturedInput = input
        self.capturedLyrics = lyrics
        self.capturedPreset = preset
        self.capturedDuration = durationSeconds
        self.capturedOptions = options
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }

    func submitGeneration(input: String, lyrics: String?, preset: String, durationSeconds: Double, options: GenerationOptions) async throws -> RemoteJob {
        capturedInput = input
        capturedLyrics = lyrics
        capturedPreset = preset
        capturedDuration = durationSeconds
        capturedOptions = options
        return submittedJob
    }

    func job(id: String) async throws -> RemoteJob { submittedJob }

    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { outputs }

    func cancel(jobID: String) async throws { cancelledJobID = jobID }
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
        vm.preset = "quality"
        vm.durationSeconds = 45
        #expect(vm.phase == .idle)

        let started = vm.start()
        #expect(started)
        #expect(vm.phase == .running)

        await waitUntil { vm.phase == .done }
        #expect(vm.phase == .done)
        #expect(api.capturedInput == "a chill lo-fi beat")
        #expect(api.capturedPreset == "quality")
        #expect(api.capturedDuration == 45)
        #expect(library.saved.count == 1)
        #expect(library.saved[0].0.kind == .audio)
        #expect(library.saved[0].0.relativePath.hasSuffix(".wav"))
    }

    @Test("generation options are captured with bilingual language intent")
    func generationOptionsFlow() async throws {
        let api = FakeGenerator()
        let library = FakeLibrary()
        let vm = GenerateViewModel(api: api, library: library)
        vm.prompt = "Vietnamese pop"
        vm.seedText = "42"
        vm.variationCount = 3
        vm.bpmText = "118"
        vm.key = "A minor"
        vm.timeSignature = "4"
        vm.vocalLanguage = .vietnamese

        #expect(vm.start())
        await waitUntil { vm.phase == .done }
        #expect(api.capturedOptions == GenerationOptions(
            seed: 42, variationCount: 3, bpm: 118, key: "A minor", timeSignature: "4", vocalLanguage: .vietnamese
        ))
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

    @Test("durable submission is recorded before its output is imported")
    func durableSubmissionFlow() async throws {
        let api = FakeGenerator()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        let reattacher = JobReattacher(api: api, library: library, pollInterval: .zero)
        let vm = GenerateViewModel(api: api, library: library, reattacher: reattacher)
        vm.prompt = "durable prompt"

        #expect(vm.start())
        await waitUntil { vm.phase == .done }

        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.count == 1)
        #expect(library.items.first?.remoteOutputAssetID == "out-1")
        #expect(library.items.first?.provenance?.jobID == "job-1")
    }

    @Test("cancelling a durable generation forwards its accepted job ID")
    func cancellingDurableGenerationForwardsJobID() async throws {
        let api = FakeGenerator()
        api.submittedJob = try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"job-1\",\"kind\":\"generation\",\"state\":\"running\",\"progress\":0,\"error\":null}".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        let vm = GenerateViewModel(
            api: api,
            library: library,
            reattacher: JobReattacher(api: api, library: library)
        )
        vm.prompt = "cancel me"

        #expect(vm.start())
        await waitUntil { api.capturedInput == "cancel me" }
        vm.cancel()
        await waitUntil { api.cancelledJobID == "job-1" }

        #expect(api.cancelledJobID == "job-1")
    }

    // MARK: - helper

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

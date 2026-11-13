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
private final class DurableTranscriber: TranscribeServicing, DurableTranscriptionSubmitting, DurableLyricsSubmitting, DurableJobServicing, DurableJobCancelling, @unchecked Sendable {
    var suspendFirst = false
    var releaseFirst = false
    var submissions = 0
    var cancelled: [String] = []
    var holdRecovery = false
    var releaseRecovery = false
    var recoveryStarted = false
    var failCancellation = false
    var returnOutput = false

    func transcribe(audio: Data, filename: String, instruments: [String], detectTempo: Bool) async throws -> Data {
        throw CancellationError()
    }
    func submitTranscription(audio: Data, filename: String, instruments: [String], detectTempo: Bool) async throws -> RemoteJob {
        try await submit(kind: "transcription")
    }
    func submitLyricsTranscription(audio: Data, filename: String) async throws -> RemoteJob {
        try await submit(kind: "lyrics-transcription")
    }
    private func submit(kind: String) async throws -> RemoteJob {
        submissions += 1
        let number = submissions
        if number == 1 && suspendFirst {
            while !releaseFirst {
                try Task.checkCancellation()
                await Task.yield()
            }
            try Task.checkCancellation()
        }
        return try makeJob(id: "job-\(number)", kind: kind, state: "succeeded")
    }
    private func makeJob(id: String, kind: String, state: String) throws -> RemoteJob {
        try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"\(kind)\",\"state\":\"\(state)\",\"progress\":1,\"error\":null}".utf8))
    }
    func job(id: String) async throws -> RemoteJob {
        if holdRecovery && id == "job-1" {
            recoveryStarted = true
            while !releaseRecovery { await Task.yield() }
        }
        return try makeJob(id: id, kind: "transcription", state: "succeeded")
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] {
        guard returnOutput && job.id == "job-1" else { return [] }
        let asset = RemoteAsset(id: "out-1", filename: "result.mid", mediaType: "audio/midi", sizeBytes: 3, sha256: "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed", downloadUrl: "/v1/assets/out-1")
        return [DownloadedRemoteAsset(asset: asset, data: Data("one".utf8))]
    }
    func cancel(jobID: String) async throws {
        try Task.checkCancellation()
        cancelled.append(jobID)
        if failCancellation { throw MicromixAPIError.unreachable() }
    }
}

private actor ControlledSourceLoader {
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]
    func load(_ url: URL) async throws -> (Data, LocalMusicAnalysis?) {
        let data = try await withCheckedThrowingContinuation { continuation in
            continuations[url.lastPathComponent] = continuation
        }
        return (data, nil)
    }
    func isWaiting(_ name: String) -> Bool { continuations[name] != nil }
    func complete(_ name: String, data: Data) {
        continuations.removeValue(forKey: name)?.resume(returning: data)
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

    @Test("instrument summary explains the all-instruments default and selections")
    func instrumentSummary() {
        #expect(InstrumentPicker.selectionSummary([]) == "All instruments")
        #expect(InstrumentPicker.selectionSummary(["acoustic_piano"]) == "Acoustic Piano")
        #expect(InstrumentPicker.selectionSummary(["piano", "bass", "drums"]) == "Piano, Bass +1")
        #expect(DeviceMode.transcribe.workspaceDescription.contains("lyrics"))
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

    @Test("unsupported source type surfaces an error without selecting it")
    func unsupportedSource() throws {
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary())

        let selected = vm.select(name: "notes.txt", bytes: Data("not audio".utf8))

        #expect(!selected)
        #expect(!vm.hasSelection)
        #expect("\(vm.phase)".contains("UNSUPPORTED"))
    }

    @Test("empty source surfaces a readable error without selecting it")
    func emptySource() throws {
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary())

        let selected = vm.select(name: "empty.wav", bytes: Data())

        #expect(!selected)
        #expect(!vm.hasSelection)
        #expect("\(vm.phase)".contains("READ"))
    }

    @Test("M4A source is accepted for server-side FFmpeg decoding")
    func m4aSource() throws {
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary())

        #expect(vm.select(name: "voice.m4a", bytes: Data([0x01])))
        #expect(vm.hasSelection)
        #expect(vm.sourceName == "voice.m4a")
    }

    @Test("managed audio URL uses the same validated selection path")
    func managedAudioURL() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-library-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary())

        #expect(await vm.select(url: url))
        #expect(vm.hasSelection)
        #expect(vm.sourceName == url.lastPathComponent)
    }

    @Test("MIDI is rejected as a non-waveform transcription source")
    func midiSource() throws {
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary())

        #expect(!vm.select(name: "notes.mid", bytes: Data([0x4D, 0x54, 0x68, 0x64])))
        #expect(!vm.hasSelection)
        #expect("\(vm.phase)".contains("UNSUPPORTED"))
    }

    @Test("oversized files are rejected before their contents are read")
    func oversizedSourcePreflight() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-large-\(UUID().uuidString).wav")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(TranscribeViewModel.maximumSourceBytes + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try TranscribeViewModel.readSource(at: url)
            Issue.record("Oversized source should be rejected")
        } catch TranscribeViewModel.SourceReadError.tooLarge {
            // Expected: the sparse file is rejected from metadata, without allocation.
        }
    }

    @Test("only the newest source read may replace the selection")
    func newestSourceWins() async throws {
        let loader = ControlledSourceLoader()
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary(), sourceLoader: { try await loader.load($0) })
        #expect(vm.select(name: "old.wav", bytes: Data("old".utf8)))
        let first = Task { await vm.select(url: URL(fileURLWithPath: "/tmp/first.wav")) }
        while !(await loader.isWaiting("first.wav")) { await Task.yield() }
        #expect(vm.isLoadingSource)
        #expect(!vm.start())
        let second = Task { await vm.select(url: URL(fileURLWithPath: "/tmp/second.wav")) }
        while !(await loader.isWaiting("second.wav")) { await Task.yield() }
        await loader.complete("second.wav", data: Data("second".utf8))
        #expect(await second.value)
        await loader.complete("first.wav", data: Data("first".utf8))
        #expect(!(await first.value))
        #expect(vm.sourceName == "second.wav")
        #expect(!vm.isLoadingSource)
    }

    @Test("an unreadable replacement preserves the previous source")
    func unreadableReplacementPreservesSource() async throws {
        let vm = TranscribeViewModel(api: FakeTranscriber(), library: FakeLibrary(), sourceLoader: { _ in throw TranscribeViewModel.SourceReadError.unreadable })
        #expect(vm.select(name: "old.wav", bytes: Data("old".utf8)))
        #expect(!(await vm.select(url: URL(fileURLWithPath: "/missing.wav"))))
        #expect(vm.sourceName == "old.wav")
        #expect(!vm.isLoadingSource)
        guard case .error = vm.phase else { Issue.record("expected an error"); return }
    }

    @Test("empty durable MIDI output is a retryable error")
    func emptyDurableMIDI() async throws {
        let api = DurableTranscriber()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(directory: directory)
        let vm = TranscribeViewModel(api: api, library: library, reattacher: JobReattacher(api: api, library: library, pollInterval: .zero))
        #expect(vm.select(name: "source.wav", bytes: Data("audio".utf8)))
        #expect(vm.start())
        await waitUntil { if case .error = vm.phase { return true }; return false }
        guard case let .error(message) = vm.phase else { Issue.record("expected error"); return }
        #expect(message.contains("without a result"))
        #expect(library.pendingJobIDs == ["job-1"])
        #expect(vm.lastItem == nil)
    }

    @Test("accepted jobs are cancelled and stale recovery cannot overwrite a restart", arguments: [TranscribeViewModel.Output.midi, .lyrics])
    func acceptedCancellation(output: TranscribeViewModel.Output) async throws {
        let api = DurableTranscriber()
        api.holdRecovery = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(directory: directory)
        let vm = TranscribeViewModel(api: api, library: library, reattacher: JobReattacher(api: api, library: library, pollInterval: .zero))
        vm.output = output
        #expect(vm.select(name: "source.wav", bytes: Data("audio".utf8)))
        #expect(vm.start())
        await waitUntil { api.recoveryStarted }
        #expect(api.recoveryStarted)
        vm.cancel()
        await waitUntil { api.cancelled.contains("job-1") }
        #expect(api.cancelled.contains("job-1"))
        #expect(vm.start())
        await waitUntil { if case .error = vm.phase { return true }; return false }
        let restartedPhase = vm.phase
        api.releaseRecovery = true
        await waitUntil { library.pendingJobIDs.contains("job-1") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.phase == restartedPhase)
    }

    @Test("late accepted jobs are cancelled without changing a restarted run", arguments: [TranscribeViewModel.Output.midi, .lyrics])
    func lateAcceptance(output: TranscribeViewModel.Output) async throws {
        let api = DurableTranscriber()
        api.suspendFirst = true
        api.holdRecovery = true
        api.failCancellation = true
        api.returnOutput = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(directory: directory)
        let vm = TranscribeViewModel(api: api, library: library, reattacher: JobReattacher(api: api, library: library, pollInterval: .zero))
        vm.output = output
        #expect(vm.select(name: "source.wav", bytes: Data("audio".utf8)))
        #expect(vm.start())
        await waitUntil { api.submissions == 1 }
        vm.cancel()
        #expect(vm.start())
        await waitUntil { api.submissions == 2 }
        await waitUntil { if case .error = vm.phase { return true }; return false }
        let restartedPhase = vm.phase
        api.releaseFirst = true
        await waitUntil { api.cancelled.contains("job-1") }
        #expect(api.cancelled.contains("job-1"))
        await waitUntil { api.recoveryStarted }
        #expect(library.pendingJobIDs.contains("job-1"))
        #expect(LocalLibrary(directory: directory).pendingJobIDs.contains("job-1"))
        api.releaseRecovery = true
        await waitUntil { library.items.count == 1 }
        #expect(library.items.count == 1)
        #expect(!library.pendingJobIDs.contains("job-1"))
        #expect(vm.phase == restartedPhase)
        #expect(vm.lastItem == nil)
    }

    // MARK: - helper

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

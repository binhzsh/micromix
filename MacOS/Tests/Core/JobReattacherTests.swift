import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Durable job reattachment")
struct JobReattacherTests {
    @Test("a completed remote job imports every output once and clears its pending record", arguments: ["generation", "vocal_swap", "stem_split"])
    func completedJobImportsOutputs(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let completed = try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"job-1\",\"kind\":\"\(kind)\",\"state\":\"succeeded\"}".utf8))
        let api = StubDurableJobs(job: completed, outputs: [
            DownloadedRemoteAsset(asset: Self.asset(id: "out-1", filename: "first.wav", bytes: 3, sha256: "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed"), data: Data("one".utf8)),
            DownloadedRemoteAsset(asset: Self.asset(id: "out-2", filename: "second.wav", bytes: 3, sha256: "3fc4ccfe745870e2c0d99f71f30ff0656c8dedd41cc1d7d3d376b0dbe685e2f3"), data: Data("two".utf8)),
        ])

        let reattacher = JobReattacher(api: api, library: library)
        await reattacher.recoverPendingJobs()

        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.map(\.remoteOutputAssetID) == ["out-2", "out-1"])
    }

    @Test("lyrics recovery persists distinct text and remains idempotent")
    func lyricsRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "lyrics-job")
        let job = try JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"lyrics-job","kind":"lyrics-transcription","state":"succeeded"}"#.utf8))
        let asset = RemoteAsset(id: "lyrics-output", filename: "lyrics.txt", mediaType: "text/plain", sizeBytes: 3, sha256: "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed", downloadUrl: "/v1/assets/lyrics-output")
        let reattacher = JobReattacher(api: StubDurableJobs(job: job, outputs: [DownloadedRemoteAsset(asset: asset, data: Data("one".utf8))]), library: library)
        await reattacher.recoverPendingJobs()
        #expect(library.pendingJobIDs.isEmpty)
        let item = try #require(library.items.first)
        #expect(item.kind == .lyrics)
        #expect(try String(contentsOf: library.resolvedURL(for: item), encoding: .utf8) == "one")
        #expect(LocalLibrary(directory: directory).items.first?.kind == .lyrics)
        _ = try await reattacher.recoverSubmittedJob(id: job.id)
        #expect(library.items.count == 1)
    }

    @Test("a lyrics job with no output remains pending")
    func lyricsMissingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "lyrics-job")
        let job = try JSONDecoder().decode(RemoteJob.self, from: Data(#"{"id":"lyrics-job","kind":"lyrics-transcription","state":"succeeded"}"#.utf8))
        let reattacher = JobReattacher(api: StubDurableJobs(job: job, outputs: []), library: library)
        await reattacher.recoverPendingJobs()
        #expect(library.pendingJobIDs == ["lyrics-job"])
        #expect(reattacher.status == .unavailable(1))
    }

    @Test("a terminal failure clears its pending record without creating a result")
    func terminalFailureCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let reattacher = JobReattacher(api: StubDurableJobs(job: Self.job(state: "failed"), outputs: []), library: library)

        await reattacher.recoverPendingJobs()

        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.isEmpty)
        #expect(reattacher.entries.first?.state == .failed("job failed"))
        #expect(ActiveWorkBar.destination(for: try #require(reattacher.entries.first)) == nil)
    }

    @Test("late accepted workspace job transfers to background recovery")
    func lateAcceptanceTransfersOwnership() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = StubDurableJobs(job: Self.job(state: "cancelled"), outputs: [])
        let reattacher = JobReattacher(api: api, library: library)
        let job = Self.job(state: "running")
        try reattacher.track(job)
        try reattacher.trackForBackground(job)
        for _ in 0..<100 where !library.pendingJobIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.pendingJobIDs.isEmpty)
        #expect(reattacher.entries.first?.state == .cancelled)
    }

    @Test("failed cancellation while polling does not offer recovery retry")
    func cancellationFailureWhilePolling() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let api = FailingCancellationJobs()
        let reattacher = JobReattacher(api: api, library: library)
        reattacher.startRecovery()
        await api.waitUntilStarted()
        await reattacher.cancelRecovery(id: "job-1")
        guard case .cancellationFailed = reattacher.entries.first?.state else {
            Issue.record("Expected cancellation failure with polling active")
            await api.finish()
            return
        }
        #expect(library.pendingJobIDs == ["job-1"])
        await api.finish()
    }

    @Test("terminal notices can be dismissed and are bounded")
    func terminalNoticesBounded() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = TerminalNoticeJobs()
        let reattacher = JobReattacher(api: api, library: library)
        for index in 0..<51 { try library.trackPendingJob(id: "job-\(index)") }
        await reattacher.recoverPendingJobs()
        #expect(reattacher.entries.count == 50)
        let id = try #require(reattacher.entries.first?.id)
        reattacher.dismissEntry(id: id)
        #expect(reattacher.entries.count == 49)
    }

    @Test("per-job cancellation retains the record until terminal confirmation")
    func cancellationWaitsForConfirmation() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let api = CancelRecoveryJobs()
        let reattacher = JobReattacher(api: api, library: library, pollInterval: .milliseconds(10))
        await reattacher.recoverPendingJobs()
        #expect(reattacher.entries.first?.state == .unavailable(MicromixAPIError.unreachable().localizedDescription))
        await reattacher.cancelRecovery(id: "job-1")
        #expect(library.pendingJobIDs == ["job-1"])
        #expect(await api.cancelledIDs == ["job-1"])
        await api.confirmCancellation()
        for _ in 0..<100 where !library.pendingJobIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.pendingJobIDs.isEmpty)
        #expect(reattacher.entries.first?.state == .cancelled)
    }

    @Test("successful cancellation of an unsaved job remains retryable")
    func cancellationOfUnpersistedJobRemainsRetryable() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = CancelRecoveryJobs()
        var canPersist = false
        let reattacher = JobReattacher(api: api, library: library, persistJob: { id in
            guard canPersist else { throw CocoaError(.fileWriteNoPermission) }
            try library.trackPendingJob(id: id)
        })
        #expect(throws: (any Error).self) { try reattacher.trackForBackground(Self.job(state: "running")) }
        await reattacher.cancelRecovery(id: "job-1")

        #expect(await api.cancelledIDs == ["job-1"])
        #expect(library.pendingJobIDs.isEmpty)
        #expect(reattacher.status == .unavailable(1))
        let entry = try #require(reattacher.entries.first)
        #expect(entry.id == "job-1")
        guard case .unavailable(let message) = entry.state else {
            Issue.record("Expected retryable state after cancellation request")
            return
        }
        #expect(message.contains("not confirmed"))
        #expect(message.contains("lost on quit"))

        reattacher.retryRecovery(id: "job-1")
        #expect(library.pendingJobIDs.isEmpty)
        guard case .unavailable = reattacher.entries.first?.state else {
            Issue.record("Expected retryable state after persistence failure")
            return
        }
        canPersist = true
        reattacher.retryRecovery(id: "job-1")
        #expect(library.pendingJobIDs == ["job-1"])
        #expect(reattacher.entries.first?.state == .recovering)
    }

    @Test("recovered navigation only opens Library when results exist")
    func recoveredNavigation() {
        let completed = JobReattacher.RecoveryEntry(id: "a", state: .completed(true))
        let unknown = JobReattacher.RecoveryEntry(id: "b", state: .recovering)
        #expect(ActiveWorkBar.destination(for: completed) == .workspace(.library))
        #expect(ActiveWorkBar.destination(for: unknown) == nil)
        #expect(ActiveWorkBar.description(for: unknown).contains("workspace unknown"))
    }

    @Test("a mismatched output checksum retains the pending job and imports nothing")
    func checksumMismatchRetainsJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let corrupt = DownloadedRemoteAsset(
            asset: RemoteAsset(id: "out-1", filename: "first.wav", mediaType: "audio/wav", sizeBytes: 3, sha256: "0000", downloadUrl: "/v1/assets/out-1"),
            data: Data("one".utf8)
        )

        await JobReattacher(api: StubDurableJobs(job: Self.job(state: "succeeded"), outputs: [corrupt]), library: library)
            .recoverPendingJobs()

        #expect(library.pendingJobIDs == ["job-1"])
        #expect(library.items.isEmpty)
    }

    @Test("a pending job keeps polling until it reaches a terminal success")
    func pendingJobPollsToSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let api = StubDurableJobs(
            jobs: [Self.job(state: "running"), Self.job(state: "succeeded")],
            outputs: [DownloadedRemoteAsset(asset: Self.asset(id: "out-1", filename: "first.wav", bytes: 3, sha256: "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed"), data: Data("one".utf8))]
        )

        await JobReattacher(api: api, library: library, pollInterval: .zero).recoverPendingJobs()

        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.count == 1)
    }

    @Test("a transient lookup failure retains the pending job for a later retry")
    func transientLookupFailureRetainsJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let reattacher = JobReattacher(api: StubDurableJobs(error: MicromixAPIError.unreachable()), library: library)

        await reattacher.recoverPendingJobs()

        #expect(library.pendingJobIDs == ["job-1"])
        #expect(reattacher.status == .unavailable(1))
    }

    @Test("retry recovers only failed saved work, not newly tracked workspace jobs")
    func retryDoesNotClaimLiveJobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let api = RetryDurableJobs()
        let reattacher = JobReattacher(api: api, library: library)
        await reattacher.recoverPendingJobs()
        #expect(reattacher.status == .unavailable(1))
        try library.trackPendingJob(id: "live-job")
        reattacher.retryFailedRecovery()
        for _ in 0..<100 where library.pendingJobIDs.contains("job-1") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.pendingJobIDs == ["live-job"])
        #expect(await api.requestedIDs() == ["job-1", "job-1"])
        #expect(reattacher.status == .idle)
    }

    @Test("direct workspace failure can be retried")
    func directFailureCanRetry() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let api = RetryDurableJobs()
        let reattacher = JobReattacher(api: api, library: library)
        do {
            _ = try await reattacher.recoverSubmittedJob(id: "job-1")
            Issue.record("Expected lookup failure")
        } catch { }
        #expect(reattacher.status == .unavailable(1))
        reattacher.retryFailedRecovery()
        for _ in 0..<100 where library.pendingJobIDs.contains("job-1") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.pendingJobIDs.isEmpty)
        #expect(await api.requestedIDs() == ["job-1", "job-1"])
        #expect(reattacher.status == .idle)
    }

    @Test("retry never claims an actively owned workspace job")
    func retrySkipsActiveDirectRecovery() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let api = SuspendedDurableJobs()
        let reattacher = JobReattacher(api: api, library: library)
        _ = try? await reattacher.recoverSubmittedJob(id: "job-1")
        #expect(reattacher.status == .unavailable(1))
        let task = Task { try await reattacher.recoverSubmittedJob(id: "job-1") }
        await api.waitUntilStarted()
        reattacher.retryFailedRecovery()
        await reattacher.cancelRecovery(id: "job-1")
        await Task.yield()
        #expect(await api.requestCount == 2)
        #expect(await api.cancelCount == 0)
        await api.finish()
        _ = try? await task.value
        #expect(library.pendingJobIDs.isEmpty)
    }

    @Test("a missing remote job remains pending and is surfaced distinctly")
    func missingRemoteJobRetainsRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let reattacher = JobReattacher(api: StubDurableJobs(error: MicromixAPIError(statusCode: 404, detail: "missing")), library: library)

        await reattacher.recoverPendingJobs()

        #expect(library.pendingJobIDs == ["job-1"])
        #expect(reattacher.status == .missing(1))
    }

    @Test("forgetting a missing job persists locally and leaves other jobs untouched")
    func forgetMissingJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "missing")
        let reattacher = JobReattacher(api: StubDurableJobs(error: MicromixAPIError(statusCode: 404, detail: "missing")), library: library)
        await reattacher.recoverPendingJobs()
        try library.trackPendingJob(id: "other")
        try reattacher.forgetMissingJob(id: "other")
        #expect(Set(library.pendingJobIDs) == ["missing", "other"])
        try reattacher.forgetMissingJob(id: "missing")
        #expect(library.pendingJobIDs == ["other"])
        #expect(LocalLibrary(directory: directory).pendingJobIDs == ["other"])
        #expect(reattacher.entries.isEmpty)
        #expect(reattacher.status == .idle)
    }

    @Test("forget rejects unavailable and active recovery jobs")
    func forgetRejectsNonmissingAndActive() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let api = FailingCancellationJobs()
        let reattacher = JobReattacher(api: api, library: library)
        reattacher.startRecovery()
        await api.waitUntilStarted()
        try reattacher.forgetMissingJob(id: "job-1")
        #expect(library.pendingJobIDs == ["job-1"])
        await api.finish()
        let otherLibrary = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try otherLibrary.trackPendingJob(id: "job-1")
        let unavailable = JobReattacher(api: StubDurableJobs(error: MicromixAPIError.unreachable()), library: otherLibrary)
        await unavailable.recoverPendingJobs()
        try unavailable.forgetMissingJob(id: "job-1")
        #expect(otherLibrary.pendingJobIDs == ["job-1"])
    }

    @Test("a missing output is not an eligible missing job")
    func missingOutputCannotBeForgotten() async throws {
        let library = LocalLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try library.trackPendingJob(id: "job-1")
        let reattacher = JobReattacher(api: MissingOutputJobs(), library: library)
        await reattacher.recoverPendingJobs()
        #expect(reattacher.status == .unavailable(1))
        try reattacher.forgetMissingJob(id: "job-1")
        #expect(library.pendingJobIDs == ["job-1"])
    }

    @Test("imported provenance preserves the gateway output link name and operation fallback")
    func provenancePreservesOutputLink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let job = try JSONDecoder().decode(RemoteJob.self, from: Data("""
        {"id":"job-1","kind":"transcription","state":"succeeded","progress":1,"error":null,
         "outputs":[{"name":"midi","position":3,"asset":{"id":"out-1","filename":"result.mid","mediaType":"audio/midi","sizeBytes":3,"sha256":"7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed","downloadUrl":"/v1/assets/out-1"}}]}
        """.utf8))
        let output = DownloadedRemoteAsset(asset: job.outputs[0].asset, data: Data("one".utf8))

        await JobReattacher(api: StubDurableJobs(job: job, outputs: [output]), library: library).recoverPendingJobs()

        #expect(library.items.first?.provenance?.operation == "transcription")
        #expect(library.items.first?.provenance?.output.name == "midi")
        #expect(library.items.first?.provenance?.output.position == 3)
    }

    @Test("imported remix keeps the named source link and submitted parameters")
    func importedRemixKeepsSourceAndParameters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-remix")
        let job = try JSONDecoder().decode(RemoteJob.self, from: Data("""
        {"id":"job-remix","kind":"generation","state":"succeeded","parameters":{"operation":"remix","seed":123,"variation_count":2},"progress":1,"error":null,
         "inputs":[{"name":"source","position":0,"asset":{"id":"source-1","filename":"source.wav","mediaType":"audio/wav","sizeBytes":4,"sha256":"source-hash","downloadUrl":"/v1/assets/source-1"}}],
         "outputs":[{"name":"variation","position":0,"asset":{"id":"output-1","filename":"variation.wav","mediaType":"audio/wav","sizeBytes":3,"sha256":"7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed","downloadUrl":"/v1/assets/output-1"}}]}
        """.utf8))
        let output = DownloadedRemoteAsset(asset: job.outputs[0].asset, data: Data("one".utf8))

        await JobReattacher(api: StubDurableJobs(job: job, outputs: [output]), library: library).recoverPendingJobs()

        let provenance = try #require(library.items.first?.provenance)
        #expect(provenance.operation == "remix")
        #expect(provenance.inputs == job.inputs)
        #expect(provenance.inputs.first?.name == "source")
        #expect(provenance.parameters["seed"] == .number(123))
        #expect(provenance.parameters["variation_count"] == .number(2))
    }

    @Test("a terminal failure surfaces the worker's reason instead of a generic description")
    func terminalFailureSurfacesWorkerReason() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let failed = try JSONDecoder().decode(RemoteJob.self, from: Data("""
        {"id":"job-1","kind":"generation","state":"failed","progress":1,
         "error":"Local worker exited with status 1: Library not loaded: @rpath/libavutil.57.dylib\\nTraceback (most recent call last):\\n  File \\"handler.py\\""}
        """.utf8))
        let reattacher = JobReattacher(api: StubDurableJobs(job: failed, outputs: []), library: library)

        var message: String?
        do {
            _ = try await reattacher.recoverSubmittedJob(id: "job-1")
        } catch {
            message = error.localizedDescription
        }

        #expect(message == "Local worker exited with status 1: Library not loaded: @rpath/libavutil.57.dylib")
        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.isEmpty)
    }

    @Test("a crash traceback is condensed to its first line and bounded")
    func failureSummaryIsReadable() {
        #expect(JobReattacher.summary(of: "\n  first reason  \nTraceback (most recent call last):") == "first reason")
        #expect(JobReattacher.summary(of: "   ") == "")
        let summary = JobReattacher.summary(of: String(repeating: "x", count: 500), limit: 10)
        #expect(summary == String(repeating: "x", count: 10) + "…")
    }

    @Test("a blank worker reason still produces a readable message")
    func blankWorkerReasonStaysReadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let failed = try JSONDecoder().decode(RemoteJob.self, from: Data("""
        {"id":"job-1","kind":"generation","state":"failed","progress":1,"error":"   "}
        """.utf8))
        let reattacher = JobReattacher(api: StubDurableJobs(job: failed, outputs: []), library: library)

        var message: String?
        do {
            _ = try await reattacher.recoverSubmittedJob(id: "job-1")
        } catch {
            message = error.localizedDescription
        }

        let reason = try #require(message)
        #expect(!reason.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private static func asset(id: String, filename: String, bytes: Int, sha256: String) -> RemoteAsset {
        RemoteAsset(id: id, filename: filename, mediaType: "audio/wav", sizeBytes: bytes, sha256: sha256, downloadUrl: "/v1/assets/\(id)")
    }

    private static func job(state: String) -> RemoteJob {
        try! JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"job-1\",\"kind\":\"generation\",\"state\":\"\(state)\",\"progress\":1,\"error\":null}".utf8))
    }
}

actor MissingOutputJobs: DurableJobServicing {
    func job(id: String) async throws -> RemoteJob {
        try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"succeeded\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] {
        throw MicromixAPIError(statusCode: 404, detail: "output missing")
    }
}

actor FailingCancellationJobs: DurableJobServicing, DurableJobCancelling {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func cancel(jobID: String) async throws { throw MicromixAPIError.unreachable() }
    func job(id: String) async throws -> RemoteJob {
        started = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { continuation = $0 }
        return try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"cancelled\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

actor TerminalNoticeJobs: DurableJobServicing {
    func job(id: String) async throws -> RemoteJob {
        try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"cancelled\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

actor CancelRecoveryJobs: DurableJobServicing, DurableJobCancelling {
    private(set) var cancelledIDs: [String] = []
    private var confirmed = false
    func confirmCancellation() { confirmed = true }
    func cancel(jobID: String) async throws { cancelledIDs.append(jobID) }
    func job(id: String) async throws -> RemoteJob {
        if cancelledIDs.isEmpty { throw MicromixAPIError.unreachable() }
        let state = confirmed ? "cancelled" : "running"
        return try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"\(state)\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

actor SuspendedDurableJobs: DurableJobServicing, DurableJobCancelling {
    private(set) var cancelCount = 0
    func cancel(jobID: String) async throws { cancelCount += 1 }
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    func waitUntilStarted() async {
        if requestCount > 1 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func job(id: String) async throws -> RemoteJob {
        requestCount += 1
        if requestCount == 1 { throw MicromixAPIError.unreachable() }
        started?.resume()
        started = nil
        await withCheckedContinuation { continuation = $0 }
        return try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"cancelled\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

actor RetryDurableJobs: DurableJobServicing {
    private var requests: [String] = []
    func requestedIDs() -> [String] { requests }
    func job(id: String) async throws -> RemoteJob {
        requests.append(id)
        if requests.count == 1 { throw MicromixAPIError.unreachable() }
        return try JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"\(id)\",\"kind\":\"generation\",\"state\":\"cancelled\"}".utf8))
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { [] }
}

actor StubDurableJobs: DurableJobServicing {
    var jobs: [RemoteJob]
    let downloaded: [DownloadedRemoteAsset]
    let lookupError: Error?

    init(job: RemoteJob, outputs: [DownloadedRemoteAsset]) {
        jobs = [job]
        downloaded = outputs
        lookupError = nil
    }

    init(jobs: [RemoteJob], outputs: [DownloadedRemoteAsset]) {
        self.jobs = jobs
        downloaded = outputs
        lookupError = nil
    }

    init(error: Error) {
        jobs = []
        downloaded = []
        lookupError = error
    }

    func job(id: String) async throws -> RemoteJob {
        if let lookupError { throw lookupError }
        guard !jobs.isEmpty else { throw MicromixAPIError.unreachable() }
        return jobs.count == 1 ? jobs[0] : jobs.removeFirst()
    }
    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] { downloaded }
}

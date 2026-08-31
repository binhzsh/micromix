import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("Durable job reattachment")
struct JobReattacherTests {
    @Test("a completed remote job imports every output once and clears its pending record")
    func completedJobImportsOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LocalLibrary(directory: directory)
        try library.trackPendingJob(id: "job-1")
        let api = StubDurableJobs(job: Self.job(state: "succeeded"), outputs: [
            DownloadedRemoteAsset(asset: Self.asset(id: "out-1", filename: "first.wav", bytes: 3, sha256: "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed"), data: Data("one".utf8)),
            DownloadedRemoteAsset(asset: Self.asset(id: "out-2", filename: "second.wav", bytes: 3, sha256: "3fc4ccfe745870e2c0d99f71f30ff0656c8dedd41cc1d7d3d376b0dbe685e2f3"), data: Data("two".utf8)),
        ])

        let reattacher = JobReattacher(api: api, library: library)
        await reattacher.recoverPendingJobs()

        #expect(library.pendingJobIDs.isEmpty)
        #expect(library.items.map(\.remoteOutputAssetID) == ["out-2", "out-1"])
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

    private static func asset(id: String, filename: String, bytes: Int, sha256: String) -> RemoteAsset {
        RemoteAsset(id: id, filename: filename, mediaType: "audio/wav", sizeBytes: bytes, sha256: sha256, downloadUrl: "/v1/assets/\(id)")
    }

    private static func job(state: String) -> RemoteJob {
        try! JSONDecoder().decode(RemoteJob.self, from: Data("{\"id\":\"job-1\",\"kind\":\"generation\",\"state\":\"\(state)\",\"progress\":1,\"error\":null}".utf8))
    }
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

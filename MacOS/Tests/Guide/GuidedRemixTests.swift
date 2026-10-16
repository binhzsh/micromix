import Foundation
import Testing
@testable import Micromix

@MainActor
private final class RemixAPI: DurableSourceProcessing {
    var uploads = 0
    var submitted: [String] = []
    var cancelled: [String] = []
    var responses: [RemoteJob] = []

    func uploadAsset(data: Data, filename: String, mediaType: String) async throws -> RemoteAsset {
        uploads += 1
        return RemoteAsset(id: "upload-1", filename: filename, mediaType: mediaType,
                           sizeBytes: data.count, sha256: "source-sha", downloadUrl: "/v1/assets/upload-1")
    }

    func submitSourceProcessing(_ request: SourceProcessingRequest) async throws -> RemoteJob {
        switch request {
        case .vocalSwap(let source, let voice, let pitch):
            submitted.append("vocal-swap \(source) \(voice) \(pitch)")
        case .stemSplit(let source, let description):
            submitted.append("stem-split \(source) \(description)")
        }
        return responses[submitted.count - 1]
    }

    func cancel(jobID: String) async throws { cancelled.append(jobID) }
}

@MainActor
private final class RemixRecovery: ReimagineJobReattaching {
    var tracked = 0
    var waiting = false
    var suspend = false
    var queue: [[LibraryItem]] = []

    func track(_ job: RemoteJob) throws { tracked += 1 }

    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        if suspend {
            waiting = true
            try await Task.sleep(for: .seconds(60))
        }
        return queue.removeFirst()
    }
}

@MainActor
@Suite("Guided remix flow")
struct GuidedRemixTests {
    @Test("split-first runs the split and delivers the instrumental with metadata")
    func splitFirstDeliversResidual() async {
        let api = RemixAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = RemixRecovery()
        let residual = outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")
        recovery.queue = [
            [outputItem(name: "target", remoteID: "as-target", jobID: "job-a"), residual]
        ]
        let model = GuidedRemixModel(
            api: api, reattacher: recovery, sourceReader: { _ in Data([1]) },
            metadataReader: { _ in DerivedMetadata(beatsPerMinute: 124, key: "A minor") }
        )
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.splitFirst = true
        model.analyzeFirst = true
        var delivered: (LibraryItem?, URL, DerivedMetadata?)?
        model.onDeliver = { delivered = ($0, $1, $2) }

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted == ["stem-split upload-1 vocals"])
        #expect(api.uploads == 1)
        #expect(delivered?.0 == residual)
        #expect(delivered?.2?.beatsPerMinute == 124)
        #expect(model.state(of: .splitVocals) == .done)
        #expect(model.state(of: .analyze) == .done)
        #expect(model.deliveredSource == "residual.wav")
        #expect(!model.isRunning)
    }

    @Test("analyze-only delivers the original file without any sidecar job")
    func analyzeOnlyDeliversOriginal() async {
        let api = RemixAPI()
        let recovery = RemixRecovery()
        let model = GuidedRemixModel(
            api: api, reattacher: recovery,
            metadataReader: { _ in DerivedMetadata(beatsPerMinute: 96) }
        )
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.splitFirst = false
        model.analyzeFirst = true
        var delivered: (LibraryItem?, URL, DerivedMetadata?)?
        model.onDeliver = { delivered = ($0, $1, $2) }

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted.isEmpty)
        #expect(api.uploads == 0)
        #expect(delivered?.0 == nil)
        #expect(delivered?.1 == URL(fileURLWithPath: "/tmp/song.wav"))
        #expect(delivered?.2?.beatsPerMinute == 96)
        #expect(model.state(of: .splitVocals) == .skipped)
        #expect(model.state(of: .analyze) == .done)
    }

    @Test("with both steps off the source is delivered immediately")
    func deliversImmediatelyWithoutStages() async {
        let api = RemixAPI()
        let recovery = RemixRecovery()
        let model = GuidedRemixModel(api: api, reattacher: recovery)
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.splitFirst = false
        model.analyzeFirst = false
        var delivered: (LibraryItem?, URL, DerivedMetadata?)?
        model.onDeliver = { delivered = ($0, $1, $2) }

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted.isEmpty)
        #expect(delivered?.1 == URL(fileURLWithPath: "/tmp/song.wav"))
        #expect(model.state(of: .splitVocals) == .skipped)
        #expect(model.state(of: .analyze) == .skipped)
    }

    @Test("a split without an instrumental stem fails before delivery")
    func failsWithoutResidual() async {
        let api = RemixAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = RemixRecovery()
        recovery.queue = [[outputItem(name: "target", remoteID: "as-target", jobID: "job-a")]]
        let model = GuidedRemixModel(
            api: api, reattacher: recovery, sourceReader: { _ in Data([1]) },
            metadataReader: { _ in DerivedMetadata() }
        )
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.splitFirst = true
        var delivered: (LibraryItem?, URL, DerivedMetadata?)?
        model.onDeliver = { delivered = ($0, $1, $2) }

        #expect(model.start())
        for _ in 0..<1000 where model.isRunning { await Task.yield() }

        #expect(api.submitted.count == 1)
        #expect(model.state(of: .splitVocals) == .failed("Stem split did not return an instrumental stem"))
        #expect(model.state(of: .analyze) == .pending)
        #expect(delivered == nil)
        #expect(model.errorMessage == "Stem split did not return an instrumental stem")
    }

    @Test("cancelling mid-recovery forwards cancellation and skips delivery")
    func cancelsAcceptedJob() async {
        let api = RemixAPI()
        api.responses = [job(id: "job-a", kind: "stem_split")]
        let recovery = RemixRecovery()
        recovery.suspend = true
        recovery.queue = [[outputItem(name: "residual", remoteID: "as-residual", jobID: "job-a")]]
        let model = GuidedRemixModel(
            api: api, reattacher: recovery, sourceReader: { _ in Data([1]) },
            metadataReader: { _ in DerivedMetadata() }
        )
        model.sourceURL = URL(fileURLWithPath: "/tmp/song.wav")
        model.splitFirst = true
        var delivered = false
        model.onDeliver = { _, _, _ in delivered = true }

        #expect(model.start())
        for _ in 0..<1000 where !recovery.waiting { await Task.yield() }
        model.cancel()
        for _ in 0..<1000 where api.cancelled.isEmpty { await Task.yield() }

        #expect(api.cancelled == ["job-a"])
        #expect(model.state(of: .splitVocals) == .cancelled)
        #expect(model.state(of: .analyze) == .pending)
        #expect(!model.isRunning)
        #expect(!delivered)
    }

    @Test("starting without a source rejects with a message")
    func validatesSource() {
        let api = RemixAPI()
        let recovery = RemixRecovery()
        let model = GuidedRemixModel(api: api, reattacher: recovery)

        #expect(!model.start())
        #expect(model.errorMessage == "SELECT AN AUDIO FILE")
        #expect(api.submitted.isEmpty)
    }

    // MARK: - Builders

    private func job(id: String, kind: String) -> RemoteJob {
        try! JSONDecoder().decode(
            RemoteJob.self,
            from: Data(#"{"id":"\#(id)","kind":"\#(kind)","state":"queued"}"#.utf8)
        )
    }

    private func outputItem(name: String, remoteID: String, jobID: String) -> LibraryItem {
        let asset = RemoteAsset(
            id: remoteID, filename: "\(name).wav", mediaType: "audio/wav",
            sizeBytes: 10, sha256: "sha-\(remoteID)", downloadUrl: "/v1/assets/\(remoteID)"
        )
        return LibraryItem(
            id: UUID(), kind: .audio, title: "\(name).wav", createdAt: .now,
            promptOrSource: "song.wav", durationSeconds: nil, relativePath: "audio/\(remoteID).wav",
            provenance: LibraryProvenance(
                jobID: jobID, operation: "stem_split", parameters: [:],
                inputs: [], output: RemoteAssetLink(name: name, position: 0, asset: asset)
            ),
            remoteOutputAssetID: remoteID
        )
    }
}
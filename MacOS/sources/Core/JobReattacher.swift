import CryptoKit
import Foundation

@MainActor
final class JobReattacher: ObservableObject {
    private enum ReattachmentError: Error {
        case checksumMismatch
        case terminalJob(String)
    }
    private enum RecoveryOutcome {
        case recovered
        case unavailable
        case missing
    }
    enum Status: Equatable {
        case idle
        case recovering(Int)
        case pending(Int)
        case unavailable(Int)
        case missing(Int)
    }

    @Published private(set) var status: Status = .idle

    private let api: any DurableJobServicing
    private let library: LocalLibrary
    private let pollInterval: Duration
    private var activeJobIDs = Set<String>()
    private var unavailableJobIDs = Set<String>()
    private var missingJobIDs = Set<String>()

    init(
        api: any DurableJobServicing,
        library: LocalLibrary,
        pollInterval: Duration = .seconds(1)
    ) {
        self.api = api
        self.library = library
        self.pollInterval = pollInterval
    }

    func recoverPendingJobs() async {
        let ids = library.pendingJobIDs
        guard !ids.isEmpty else {
            status = .idle
            return
        }
        status = .recovering(ids.count)
        var unavailable = 0
        var missing = 0
        for id in ids {
            switch await recover(id: id) {
            case .recovered: break
            case .unavailable: unavailable += 1
            case .missing: missing += 1
            }
        }
        status = missing > 0 ? .missing(missing) : (unavailable == 0 ? .idle : .unavailable(unavailable))
    }

    /// Begin an independent recovery task for every persisted job without
    /// blocking app launch. A later relaunch retries any unavailable jobs.
    func startRecovery() {
        for id in library.pendingJobIDs where activeJobIDs.insert(id).inserted {
            status = .recovering(activeJobIDs.count)
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.recover(id: id)
                self.activeJobIDs.remove(id)
                switch outcome {
                case .recovered:
                    self.unavailableJobIDs.remove(id)
                    self.missingJobIDs.remove(id)
                case .unavailable:
                    self.unavailableJobIDs.insert(id)
                    self.missingJobIDs.remove(id)
                case .missing:
                    self.missingJobIDs.insert(id)
                    self.unavailableJobIDs.remove(id)
                }
                self.status = !self.missingJobIDs.isEmpty ? .missing(self.missingJobIDs.count) : self.unavailableJobIDs.isEmpty
                    ? (self.activeJobIDs.isEmpty ? .idle : .recovering(self.activeJobIDs.count))
                    : .unavailable(self.unavailableJobIDs.count)
            }
        }
    }

    /// Persist an accepted job before waiting for its terminal state.
    func track(_ job: RemoteJob) throws {
        try library.trackPendingJob(id: job.id)
    }

    /// Recover one already-persisted job and return its imported library items.
    /// Errors deliberately leave the pending record intact for a later retry.
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        var job = try await api.job(id: id)
        while !job.isTerminal {
            try await Task.sleep(for: pollInterval)
            job = try await api.job(id: id)
        }
        guard job.state == "succeeded" else {
            try library.removePendingJob(id: id)
            throw ReattachmentError.terminalJob(job.error ?? "job \(job.state)")
        }
        let outputs = try await api.fetchOutputs(for: job)
        guard outputs.allSatisfy(Self.hasValidChecksum) else {
            throw ReattachmentError.checksumMismatch
        }
        let items = try outputs.map { try importOutput($0, from: job) }
        try library.removePendingJob(id: id)
        return items
    }

    private func recover(id: String) async -> RecoveryOutcome {
        do {
            _ = try await recoverSubmittedJob(id: id)
            return .recovered
        } catch is CancellationError {
            return .unavailable
        } catch ReattachmentError.terminalJob {
            return .recovered
        } catch let error as MicromixAPIError where error.statusCode == 404 {
            return .missing
        } catch {
            return .unavailable
        }
    }

    private func importOutput(_ output: DownloadedRemoteAsset, from job: RemoteJob) throws -> LibraryItem {
        let extensionName = output.asset.filename.split(separator: ".").last.map(String.init) ?? "wav"
        let kind: LibraryItemKind = output.asset.mediaType.contains("midi") ? .midi : .audio
        let item = LibraryItem(id: UUID(), kind: kind, title: output.asset.filename, createdAt: .now, promptOrSource: job.operation ?? job.kind, durationSeconds: nil, relativePath: "\(kind.rawValue)/\(UUID().uuidString).\(extensionName)")
        let outputLink = job.outputs.first(where: { $0.asset.id == output.asset.id })
            ?? RemoteAssetLink(name: "result", position: 0, asset: output.asset)
        let provenance = LibraryProvenance(jobID: job.id, operation: job.operation ?? job.kind, parameters: job.parameters, inputs: job.inputs, output: outputLink)
        return try library.importRemoteOutput(item, bytes: output.data, remoteAssetID: output.asset.id, jobID: job.id, provenance: provenance)
    }

    private static func hasValidChecksum(_ output: DownloadedRemoteAsset) -> Bool {
        let expected = output.asset.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
        let actual = SHA256.hash(data: output.data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }
}

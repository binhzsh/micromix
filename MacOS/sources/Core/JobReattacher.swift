import CryptoKit
import Foundation

@MainActor
final class JobReattacher: ObservableObject {
    private enum ReattachmentError: LocalizedError {
        case checksumMismatch
        case missingOutput
        case terminalJob(String)
        case alreadyRecovering
        case outputUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecovering:
                "This job is already being recovered"
            case .checksumMismatch:
                "A downloaded result failed its checksum and was not saved to Library"
            case .missingOutput:
                "The transcription job completed without a result. It will be retried on recovery."
            case .outputUnavailable(let reason):
                reason
            case .terminalJob(let reason):
                // `summary(of:)` returns "" when the worker reported nothing but
                // whitespace. Never hand the deck an empty description: an
                // unreadable message is what made the failure look silent.
                reason.isEmpty ? "The local service failed the job without a reason" : reason
            }
        }
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

    struct RecoveryEntry: Identifiable, Equatable {
        enum State: Equatable {
            case recovering, cancellationFailed(String), unavailable(String), missing, cancelling, failed(String), cancelled, completed(Bool)
        }
        let id: String
        var state: State
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var entries: [RecoveryEntry] = []
    private var backgroundJobIDs = Set<String>()
    private var workspaceJobIDs = Set<String>()
    private var cancellingJobIDs = Set<String>()
    private var unpersistedJobIDs = Set<String>()

    private func setEntry(_ id: String, _ state: RecoveryEntry.State) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].state = state
        } else {
            entries.append(RecoveryEntry(id: id, state: state))
        }
        // Terminal notices are informational; pending jobs are never evicted.
        let terminal = entries.filter { Self.isTerminal($0.state) }
        if terminal.count > 50 {
            let expired = Set(terminal.prefix(terminal.count - 50).map(\.id))
            entries.removeAll { expired.contains($0.id) }
        }
    }

    private static func isTerminal(_ state: RecoveryEntry.State) -> Bool {
        switch state {
        case .failed, .cancelled, .completed: true
        default: false
        }
    }

    func dismissEntry(id: String) {
        entries.removeAll { $0.id == id && Self.isTerminal($0.state) }
    }

    /// Remove only a saved job last confirmed missing, without contacting the service.
    func forgetMissingJob(id: String) throws {
        guard missingJobIDs.contains(id),
              entries.contains(where: { $0.id == id && $0.state == .missing }),
              library.pendingJobIDs.contains(id),
              !activeJobIDs.contains(id), !workspaceJobIDs.contains(id),
              !cancellingJobIDs.contains(id), !unpersistedJobIDs.contains(id) else { return }
        try library.removePendingJob(id: id)
        missingJobIDs.remove(id)
        entries.removeAll { $0.id == id }
        updateStatus()
    }

    private let api: any DurableJobServicing
    private let library: LocalLibrary
    private let pollInterval: Duration
    private let persistJob: (String) throws -> Void
    private var activeJobIDs = Set<String>()
    private var unavailableJobIDs = Set<String>()
    private var missingJobIDs = Set<String>()

    init(
        api: any DurableJobServicing,
        library: LocalLibrary,
        pollInterval: Duration = .seconds(1),
        persistJob: ((String) throws -> Void)? = nil
    ) {
        self.api = api
        self.library = library
        self.pollInterval = pollInterval
        self.persistJob = persistJob ?? { try library.trackPendingJob(id: $0) }
    }

    func recoverPendingJobs() async {
        let ids = library.pendingJobIDs
        guard !ids.isEmpty else {
            status = .idle
            return
        }
        status = .recovering(ids.count)
        for id in ids where !workspaceJobIDs.contains(id) && activeJobIDs.insert(id).inserted {
            backgroundJobIDs.insert(id)
            setEntry(id, .recovering)
            await finishRecovery(id: id)
        }
        updateStatus()
    }

    /// Begin an independent recovery task for every persisted job without
    /// blocking app launch. A later relaunch retries any unavailable jobs.
    func startRecovery() {
        for id in library.pendingJobIDs where !workspaceJobIDs.contains(id) && activeJobIDs.insert(id).inserted {
            backgroundJobIDs.insert(id)
            setEntry(id, .recovering)
            updateStatus()
            Task { [weak self] in await self?.finishRecovery(id: id) }
        }
    }

    /// Retry only jobs whose recovery failed, not jobs owned by live workspaces.
    func retryFailedRecovery() {
        let pending = Set(library.pendingJobIDs).union(unpersistedJobIDs)
        for id in unavailableJobIDs.union(missingJobIDs).intersection(pending) {
            retryRecovery(id: id)
        }
    }

    func retryRecovery(id: String) {
        guard (unavailableJobIDs.contains(id) || missingJobIDs.contains(id)),
              (library.pendingJobIDs.contains(id) || unpersistedJobIDs.contains(id)),
              !cancellingJobIDs.contains(id), !activeJobIDs.contains(id) else { return }
        if unpersistedJobIDs.contains(id) {
            do {
                try persistJob(id)
                unpersistedJobIDs.remove(id)
            } catch {
                reportPersistenceFailure(id: id, error: error)
                return
            }
        }
        guard activeJobIDs.insert(id).inserted else { return }
        unavailableJobIDs.remove(id)
        missingJobIDs.remove(id)
        backgroundJobIDs.insert(id)
        setEntry(id, .recovering)
        updateStatus()
        Task { [weak self] in await self?.finishRecovery(id: id) }
    }

    func cancelRecovery(id: String) async {
        guard entries.contains(where: { $0.id == id }),
              (library.pendingJobIDs.contains(id) || unpersistedJobIDs.contains(id)),
              (!activeJobIDs.contains(id) || backgroundJobIDs.contains(id)),
              cancellingJobIDs.insert(id).inserted else { return }
        setEntry(id, .cancelling)
        defer { cancellingJobIDs.remove(id) }
        do {
            guard let canceller = api as? any DurableJobCancelling else {
                throw MicromixAPIError.unreachable()
            }
            try await canceller.cancel(jobID: id)
            // A cancellation request is not a terminal confirmation.
            if unpersistedJobIDs.contains(id) {
                setEntry(id, .unavailable("Cancellation requested but not confirmed. Job is not saved and will be lost on quit. Retry to save and recover."))
            } else if !activeJobIDs.contains(id), library.pendingJobIDs.contains(id) {
                cancellingJobIDs.remove(id)
                retryRecovery(id: id)
            }
        } catch {
            if unpersistedJobIDs.contains(id) {
                setEntry(id, .unavailable("Job is not saved and will be lost on quit. Cancellation failed: \(error.localizedDescription). Retry to save and recover."))
            } else if library.pendingJobIDs.contains(id) {
                let message = "Cancellation request failed: \(error.localizedDescription)"
                setEntry(id, activeJobIDs.contains(id) ? .cancellationFailed(message) : .unavailable(message))
            }
        }
    }

    private func finishRecovery(id: String) async {
        let outcome = await recover(id: id)
        recordOutcome(outcome, id: id)
    }

    private func recordOutcome(_ outcome: RecoveryOutcome, id: String) {
        activeJobIDs.remove(id)
        backgroundJobIDs.remove(id)
        unavailableJobIDs.remove(id)
        missingJobIDs.remove(id)
        switch outcome {
        case .recovered: break
        case .unavailable: unavailableJobIDs.insert(id)
        case .missing: missingJobIDs.insert(id)
        }
        updateStatus()
    }

    private func updateStatus() {
        status = !missingJobIDs.isEmpty ? .missing(missingJobIDs.count) : !unavailableJobIDs.isEmpty
            ? .unavailable(unavailableJobIDs.count) : !activeJobIDs.isEmpty
            ? .recovering(activeJobIDs.count) : .idle
    }

    /// Persist an accepted job before waiting for its terminal state.
    func track(_ job: RemoteJob) throws {
        try library.trackPendingJob(id: job.id)
        workspaceJobIDs.insert(job.id)
    }

    /// Transfer an accepted job that no longer has a live workspace to recovery.
    func trackForBackground(_ job: RemoteJob) throws {
        do {
            try persistJob(job.id)
        } catch {
            reportPersistenceFailure(id: job.id, error: error)
            throw error
        }
        unpersistedJobIDs.remove(job.id)
        workspaceJobIDs.remove(job.id)
        startRecovery()
    }

    private func reportPersistenceFailure(id: String, error: Error) {
        unpersistedJobIDs.insert(id)
        unavailableJobIDs.insert(id)
        setEntry(id, .unavailable("Job is not saved and will be lost on quit: \(error.localizedDescription). Retry to save and recover."))
        updateStatus()
    }

    /// Recover one already-persisted job and return its imported library items.
    /// Errors deliberately leave the pending record intact for a later retry.
    func recoverSubmittedJob(id: String) async throws -> [LibraryItem] {
        guard activeJobIDs.insert(id).inserted else { throw ReattachmentError.alreadyRecovering }
        entries.removeAll { $0.id == id }
        unavailableJobIDs.remove(id)
        missingJobIDs.remove(id)
        updateStatus()
        do {
            let items = try await recoverJob(id: id)
            workspaceJobIDs.remove(id)
            recordOutcome(.recovered, id: id)
            return items
        } catch {
            workspaceJobIDs.remove(id)
            let result = outcome(for: error)
            switch result {
            case .missing: setEntry(id, .missing)
            case .unavailable: setEntry(id, .unavailable(error.localizedDescription))
            case .recovered: break
            }
            recordOutcome(result, id: id)
            throw error
        }
    }

    private func recoverJob(id: String) async throws -> [LibraryItem] {
        var job = try await api.job(id: id)
        while !job.isTerminal {
            try await Task.sleep(for: pollInterval)
            job = try await api.job(id: id)
        }
        guard job.state == "succeeded" else {
            try library.removePendingJob(id: id)
            let reason = Self.summary(of: job.error ?? "job \(job.state)")
            setEntry(id, job.state == "cancelled" ? .cancelled : .failed(reason.isEmpty ? "The local service failed the job without a reason" : reason))
            throw ReattachmentError.terminalJob(reason)
        }
        let outputs: [DownloadedRemoteAsset]
        do {
            outputs = try await api.fetchOutputs(for: job)
        } catch {
            // A missing output is not evidence that the job itself is missing.
            throw ReattachmentError.outputUnavailable(error.localizedDescription)
        }
        if ["lyrics-transcription", "transcription"].contains(job.kind) && outputs.isEmpty {
            throw ReattachmentError.missingOutput
        }
        guard outputs.allSatisfy(Self.hasValidChecksum) else {
            throw ReattachmentError.checksumMismatch
        }
        let items = try outputs.map { try importOutput($0, from: job) }
        try library.removePendingJob(id: id)
        if backgroundJobIDs.contains(id) { setEntry(id, .completed(!items.isEmpty)) }
        return items
    }

    private func recover(id: String) async -> RecoveryOutcome {
        do {
            _ = try await recoverJob(id: id)
            return .recovered
        } catch {
            let result = outcome(for: error)
            switch result {
            case .missing: setEntry(id, .missing)
            case .unavailable: setEntry(id, .unavailable(error.localizedDescription))
            case .recovered: break
            }
            return result
        }
    }

    private func outcome(for error: Error) -> RecoveryOutcome {
        if case ReattachmentError.terminalJob = error { return .recovered }
        if let error = error as? MicromixAPIError, error.statusCode == 404 { return .missing }
        return .unavailable
    }

    private func importOutput(_ output: DownloadedRemoteAsset, from job: RemoteJob) throws -> LibraryItem {
        let extensionName = output.asset.filename.split(separator: ".").last.map(String.init) ?? "wav"
        let kind: LibraryItemKind = job.kind == "lyrics-transcription" || output.asset.mediaType.lowercased().hasPrefix("text/") ? .lyrics : (output.asset.mediaType.contains("midi") ? .midi : .audio)
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

    /// A failed job carries the worker's trailing log, which for a crash is a
    /// multi-kilobyte native traceback. Keep the first meaningful line and bound
    /// its length so the deck reports a readable reason instead of nothing.
    static func summary(of detail: String, limit: Int = 200) -> String {
        let firstLine = detail
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return "" }
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

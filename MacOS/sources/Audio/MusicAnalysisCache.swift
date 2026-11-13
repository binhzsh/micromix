import CryptoKit
import Foundation

/// Recomputable local metadata, not a second Library or project database.
actor MusicAnalysisCache {
    static let shared = MusicAnalysisCache(directory:
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Micromix/MusicAnalysis", isDirectory: true))

    private struct Record: Codable {
        let sourceHash: String
        let analyzerID: String
        let analysis: LocalMusicAnalysis
    }

    private struct SharedSourceChanged: Error {
        let creatorURL: URL
    }

    private struct Pending {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LocalMusicAnalysis, Error>]
    }

    private let directory: URL
    private var pending: [String: Pending] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Lightweight diagnostics; no second source of request ownership.
    var pendingRequestCount: Int {
        pending.values.reduce(0) { $0 + $1.waiters.count }
    }

    func analyze(
        url: URL,
        analyzerID: String,
        using compute: @escaping @Sendable (URL) async throws -> LocalMusicAnalysis
    ) async throws -> LocalMusicAnalysis {
        try await analyze(url: url, analyzerID: analyzerID, retrySharedSourceFailure: true, using: compute)
    }

    private func analyze(
        url: URL, analyzerID: String, retrySharedSourceFailure: Bool,
        using compute: @escaping @Sendable (URL) async throws -> LocalMusicAnalysis
    ) async throws -> LocalMusicAnalysis {
        try Task.checkCancellation()
        let sourceHash = try await Self.fingerprint(url)
        let key = Self.digest(Data("\(analyzerID)\n\(sourceHash)".utf8))
        let recordURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        if let data = try? Data(contentsOf: recordURL),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.sourceHash == sourceHash, record.analyzerID == analyzerID {
            try await Self.validate(url, sourceHash: sourceHash)
            return record.analysis
        }

        let waiterID = UUID()
        let result: LocalMusicAnalysis
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if pending[key] != nil {
                        pending[key]?.waiters[waiterID] = continuation
                        return
                    }
                    let token = UUID()
                    let task = Task {
                        do {
                            let result = try await compute(url)
                            try await Self.validate(url, sourceHash: sourceHash)
                            finish(key: key, token: token, recordURL: recordURL,
                                   record: Record(sourceHash: sourceHash, analyzerID: analyzerID, analysis: result),
                                   outcome: .success(result))
                        } catch {
                            let failure: Error
                            if !Task.isCancelled, (try? await Self.fingerprint(url)) != sourceHash {
                                failure = SharedSourceChanged(creatorURL: url)
                            } else {
                                failure = error
                            }
                            finish(key: key, token: token, recordURL: recordURL,
                                   record: nil, outcome: .failure(failure))
                        }
                    }
                    pending[key] = Pending(token: token, task: task, waiters: [waiterID: continuation])
                }
            } onCancel: {
                Task { await self.cancel(key: key, waiterID: waiterID) }
            }
        } catch let failure as SharedSourceChanged {
            // A cancelled creator may lose its temporary source while another
            // caller still owns an unchanged copy. Retry that copy at most once.
            guard retrySharedSourceFailure, failure.creatorURL != url else {
                throw CocoaError(.fileReadUnknown)
            }
            try await Self.validate(url, sourceHash: sourceHash)
            return try await analyze(url: url, analyzerID: analyzerID,
                                     retrySharedSourceFailure: false, using: compute)
        }
        // A coalesced request may point at a different file with identical initial
        // content. Revalidate each caller, not just the computation's source URL.
        try await Self.validate(url, sourceHash: sourceHash)
        return result
    }

    private func cancel(key: String, waiterID: UUID) {
        guard var entry = pending[key], let waiter = entry.waiters.removeValue(forKey: waiterID) else { return }
        if entry.waiters.isEmpty {
            pending[key] = nil
            entry.task.cancel()
        } else {
            pending[key] = entry
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(key: String, token: UUID, recordURL: URL,
                        record: Record?, outcome: Result<LocalMusicAnalysis, Error>) {
        // An obsolete computation cannot publish after its last waiter left.
        guard let entry = pending[key], entry.token == token else { return }
        pending[key] = nil
        if let record, let data = try? JSONEncoder().encode(record) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: recordURL, options: .atomic)
        }
        for waiter in entry.waiters.values { waiter.resume(with: outcome) }
    }

    private nonisolated static func validate(_ url: URL, sourceHash: String) async throws {
        try Task.checkCancellation()
        guard try await fingerprint(url) == sourceHash else {
            throw CocoaError(.fileReadUnknown)
        }
        try Task.checkCancellation()
    }

    private nonisolated static func fingerprint(_ url: URL) async throws -> String {
        // Full-file I/O must not monopolize the cache actor or the main actor.
        // Only bounded chunks are retained; propagate cancellation to the reader.
        let task = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                try Task.checkCancellation()
                hash.update(data: block)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

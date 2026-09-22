import Combine
import Foundation

/// Shared run-state machine for one durable creative job (GENERATE, REIMAGINE,
/// VOCAL SWAP, STEM SPLIT).
///
/// Owns the things every flow previously re-implemented: published lifecycle
/// state, an elapsed-time ticker, the recovered alternatives, the error text,
/// the accepted durable job ID, and the stale-run guard that keeps a cancelled
/// run from overwriting an immediately restarted one.
///
/// Domain logic stays in the view models; they hand JobFlow a work closure and
/// read run state back out.
@MainActor
final class JobFlow: ObservableObject {
    @Published private(set) var status: JobStatus = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var token: UUID?
    private var acceptedJobID: String?

    var isRunning: Bool { status == .running }

    /// Handle passed to the work closure so it can record the durable job ID
    /// and check whether its run is still the active one.
    struct Run {
        let isCurrent: @MainActor () -> Bool
        let accept: @MainActor (String) -> Void
    }

    /// Start `work` unless a run is already active. `work` returns the
    /// recovered alternatives, or an empty array when it injected its own
    /// result (the non-durable Generate path).
    @discardableResult
    func start(
        _ work: @MainActor @escaping (Run) async throws -> [LibraryItem]
    ) -> Bool {
        guard !isRunning else { return false }
        let token = begin()
        let run = Run(
            isCurrent: { [weak self] in self?.token == token && !Task.isCancelled },
            accept: { [weak self] jobID in
                guard let self, self.token == token else { return }
                self.acceptedJobID = jobID
            }
        )
        task = Task { [weak self] in
            do {
                let items = try await work(run)
                self?.succeed(token, results: items)
            } catch {
                guard let self else { return }
                if Self.isCancellation(error) {
                    self.markCancelled(token)
                } else {
                    self.fail(token, message: Self.message(for: error))
                }
            }
        }
        return true
    }

    /// Cancel the active run. Returns the accepted durable job ID, when one was
    /// recorded, so the caller can forward cancellation to the API.
    @discardableResult
    func cancel() -> String? {
        let jobID = acceptedJobID
        task?.cancel()
        task = nil
        stopTicker()
        token = nil
        acceptedJobID = nil
        if status == .running {
            errorMessage = nil
            status = .cancelled
        }
        return jobID
    }

    /// Reject a start attempt before any work begins (invalid inputs).
    func reject(_ message: String) {
        errorMessage = message
        status = .error(message)
    }

    // MARK: - Run lifecycle

    private func begin() -> UUID {
        let token = UUID()
        self.token = token
        acceptedJobID = nil
        results = []
        errorMessage = nil
        status = .running
        startedAt = Date()
        elapsed = 0
        startTicker()
        return token
    }

    private func succeed(_ token: UUID, results: [LibraryItem]) {
        guard self.token == token else { return }
        finish(token)
        self.results = results
        status = .done
    }

    private func markCancelled(_ token: UUID) {
        guard self.token == token else { return }
        finish(token)
        errorMessage = nil
        status = .cancelled
    }

    private func fail(_ token: UUID, message: String) {
        guard self.token == token else { return }
        finish(token)
        errorMessage = message
        status = .error(message)
    }

    /// Drop the active run, capturing a final elapsed value so a quick job still
    /// reports a positive time.
    private func finish(_ token: UUID) {
        if let startedAt {
            elapsed = max(elapsed, Date().timeIntervalSince(startedAt))
        }
        stopTicker()
        self.token = nil
        acceptedJobID = nil
        task = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let start = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
    }

    // MARK: - Shared error handling

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    static func message(for error: Error) -> String {
        (error as? MicromixAPIError)?.errorDescription ?? error.localizedDescription
    }
}

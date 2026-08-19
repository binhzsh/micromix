import Foundation
import Combine

/// Drives one long-running async job (an HTTP op up to ~20 min) on the main
/// actor, tracking status and elapsed time. Cancellation propagates to the
/// underlying task via Swift concurrency cancellation.
@MainActor
final class JobRunner: ObservableObject {
    @Published private(set) var status: JobStatus = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startDate: Date?
    private var currentJob: Job?

    /// A job encapsulates its work plus an optional cancel hook (e.g. to
    /// cancel a specific URLSession task). The operation may throw; coöperating
    /// cancellation should throw `CancellationError`.
    struct Job {
        let name: String
        let work: @Sendable () async throws -> Void
        var onCancel: (@Sendable () -> Void)?

        init(name: String,
             work: @escaping @Sendable () async throws -> Void,
             onCancel: (@escaping @Sendable () -> Void) = {}) {
            self.name = name
            self.work = work
            self.onCancel = onCancel
        }
    }

    var isRunning: Bool { status == .running }

    /// Start `job`. If another job is running it is cancelled first.
    /// Returns immediately; the job runs in the background.
    func start(_ job: Job) {
        if isRunning { cancel() }

        status = .running
        elapsed = 0
        startDate = Date()
        currentJob = job
        startTicker()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await job.work()
                guard !Task.isCancelled else {
                    self.finish(.cancelled)
                    return
                }
                self.finish(.done)
            } catch is CancellationError {
                self.finish(.cancelled)
            } catch {
                self.finish(.error("\(job.name): \(error.localizedDescription)"))
            }
        }
    }

    /// Cancel the current job. Invokes the job's cancel hook and cancels the task.
    func cancel() {
        currentJob?.onCancel?()
        task?.cancel()
        task = nil
        if status == .running {
            finish(.cancelled)
        }
    }

    private func finish(_ state: JobStatus) {
        // Capture a final elapsed so a quick job still reports a positive time.
        if let start = startDate {
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }
        status = state
        ticker?.cancel()
        ticker = nil
        startDate = nil
        task = nil
        currentJob = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
}

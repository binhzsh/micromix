import Foundation
import Testing
@testable import Micromix

@MainActor
@Suite("JobRunner state machine")
struct JobRunnerTests {

    @Test("idle -> running -> done with elapsed tracking")
    func transitionsToDone() async throws {
        let runner = JobRunner()
        #expect(runner.status == .idle)

        let job = JobRunner.Job(name: "gen") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        runner.start(job)
        #expect(runner.status == .running)

        await waitUntil { runner.status == .done }
        #expect(runner.status == .done)
        #expect(runner.elapsed > 0)
    }

    @Test("cancel from running -> cancelled, cancel hook invoked")
    func cancel() async throws {
        let runner = JobRunner()
        let flag = FlagBox()

        let job = JobRunner.Job(name: "gen") {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } onCancel: {
            flag.set()
        }
        runner.start(job)
        #expect(runner.status == .running)

        runner.cancel()
        #expect(runner.status == .cancelled)
        #expect(flag.value)
    }

    @Test("thrown error -> error state with message")
    func errorPath() async throws {
        let runner = JobRunner()
        let job = JobRunner.Job(name: "gen") {
            throw MicromixAPIError(statusCode: 503, detail: "failed to call minimax")
        }
        runner.start(job)
        await waitUntil { if case .error = runner.status { return true }
                         return false }
        guard case .error(let msg) = runner.status else {
            Issue.record("expected error state, got \(runner.status)")
            return
        }
        #expect(msg.contains("failed to call minimax"))
    }

    @Test("URLSession cancellation (URLError.cancelled) lands in cancelled state")
    func urlErrorCancel() async throws {
        let runner = JobRunner()
        // A URLSession-backed request surfaces cancellation as URLError(.cancelled),
        // not CancellationError; the runner must classify it as cancelled.
        let job = JobRunner.Job(name: "gen") {
            throw URLError(.cancelled)
        }
        runner.start(job)
        await waitUntil { runner.status == .cancelled }
        #expect(runner.status == .cancelled)
    }

    @Test("restarting cancels the prior job without clobbering the new one")
    func restartRace() async throws {
        let runner = JobRunner()

        // A long-running first job that will be superseded.
        let first = JobRunner.Job(name: "first") {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        runner.start(first)
        #expect(runner.status == .running)

        // Start a second, shorter job while the first is still in flight.
        let second = JobRunner.Job(name: "second") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        runner.start(second)
        #expect(runner.status == .running)
        await waitUntil { runner.status == .done }

        // Wait past when the stale first task would have woken; the generation
        // guard must keep the new job's terminal state intact.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(runner.status == .done)
        // Cancelling the superseded task must still allow a fresh start.
        runner.start(JobRunner.Job(name: "third") {
            try await Task.sleep(nanoseconds: 20_000_000)
        })
        await waitUntil { runner.status == .done }
        #expect(runner.status == .done)
    }

    // MARK: - helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A Sendable box for observing whether a Sendable closure ran (cancel-hook
/// assertion), since the closure runs off the main actor.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var backing: Bool = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return backing
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        backing = true
    }
}

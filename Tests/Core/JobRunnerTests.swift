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

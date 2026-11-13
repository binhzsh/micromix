import Foundation
import Testing
@testable import Micromix

@Suite("Reusable native music analysis")
struct MusicAnalysisCacheTests {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            open = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitForRequests(_ count: Int, cache: MusicAnalysisCache) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await cache.pendingRequestCount != count {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private let result = LocalMusicAnalysis(
        durationSeconds: 12, beatsPerMinute: 100, key: "C major", instruments: ["piano"])

    @Test("content copies and concurrent requests share persisted analysis")
    func reuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        let copy = root.appendingPathComponent("copy.wav")
        try Data("audio fixture".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let directory = root.appendingPathComponent("cache")
        let cache = MusicAnalysisCache(directory: directory)
        let counter = Counter()
        let expected = result
        let compute: @Sendable (URL) async throws -> LocalMusicAnalysis = { _ in
            await counter.increment()
            await Task.yield()
            return expected
        }
        async let first = cache.analyze(url: source, analyzerID: "v1", using: compute)
        async let second = cache.analyze(url: copy, analyzerID: "v1", using: compute)
        #expect(try await first == expected)
        #expect(try await second == expected)
        #expect(await counter.value == 1)
        let reopened = MusicAnalysisCache(directory: directory)
        #expect(try await reopened.analyze(url: source, analyzerID: "v1", using: compute) == expected)
        #expect(await counter.value == 1)
    }

    @Test("content and analyzer identity invalidate results; corrupt cache recovers")
    func invalidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("before".utf8).write(to: source)
        let directory = root.appendingPathComponent("cache")
        let cache = MusicAnalysisCache(directory: directory)
        let counter = Counter()
        let expected = result
        let compute: @Sendable (URL) async throws -> LocalMusicAnalysis = { _ in
            await counter.increment()
            return expected
        }
        _ = try await cache.analyze(url: source, analyzerID: "v1", using: compute)
        try Data("after!".utf8).write(to: source)
        _ = try await cache.analyze(url: source, analyzerID: "v1", using: compute)
        _ = try await cache.analyze(url: source, analyzerID: "v2", using: compute)
        #expect(await counter.value == 3)
        for record in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try Data("corrupt".utf8).write(to: record)
        }
        _ = try await cache.analyze(url: source, analyzerID: "v2", using: compute)
        #expect(await counter.value == 4)
    }

    @Test("one cancelled waiter leaves shared work intact; a changed copy is rejected")
    func concurrentMutationAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        let copy = root.appendingPathComponent("copy.wav")
        try Data("before".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let cache = MusicAnalysisCache(directory: root.appendingPathComponent("cache"))
        let gate = Gate()
        let expected = result
        let compute: @Sendable (URL) async throws -> LocalMusicAnalysis = { _ in
            await gate.wait()
            return expected
        }
        let first = Task { try await cache.analyze(url: source, analyzerID: "v1", using: compute) }
        try await waitForRequests(1, cache: cache)
        let second = Task { try await cache.analyze(url: copy, analyzerID: "v1", using: compute) }
        try await waitForRequests(2, cache: cache)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await cache.pendingRequestCount == 1)
        try Data("after!".utf8).write(to: copy)
        await gate.release()
        await #expect(throws: CocoaError.self) { try await second.value }
        #expect(try await cache.analyze(url: source, analyzerID: "v1") { _ in
            Issue.record("unchanged source should reuse valid persisted analysis")
            return expected
        } == expected)
    }

    @Test("unchanged copy recovers if a cancelled creator loses its source")
    func creatorSourceRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        let copy = root.appendingPathComponent("copy.wav")
        try Data("fixture".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let cache = MusicAnalysisCache(directory: root.appendingPathComponent("cache"))
        let gate = Gate()
        let counter = Counter()
        let expected = result
        let compute: @Sendable (URL) async throws -> LocalMusicAnalysis = { _ in
            await counter.increment()
            await gate.wait()
            return expected
        }
        let first = Task { try await cache.analyze(url: source, analyzerID: "v1", using: compute) }
        try await waitForRequests(1, cache: cache)
        let second = Task { try await cache.analyze(url: copy, analyzerID: "v1", using: compute) }
        try await waitForRequests(2, cache: cache)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try FileManager.default.removeItem(at: source)
        await gate.release()
        #expect(try await second.value == expected)
        #expect(await counter.value == 2)
    }

    @Test("last cancelled waiter returns promptly and obsolete work cannot publish")
    func lastWaiterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("fixture".utf8).write(to: source)
        let cache = MusicAnalysisCache(directory: root.appendingPathComponent("cache"))
        let gate = Gate()
        let expected = result
        let first = Task {
            try await cache.analyze(url: source, analyzerID: "v1") { _ in
                await gate.wait() // deliberately ignores cancellation, like some native APIs
                return expected
            }
        }
        try await waitForRequests(1, cache: cache)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await cache.pendingRequestCount == 0)
        let replacement = LocalMusicAnalysis(durationSeconds: 20, beatsPerMinute: nil, key: nil, instruments: [])
        #expect(try await cache.analyze(url: source, analyzerID: "v1") { _ in replacement } == replacement)
        await gate.release()
        #expect(try await cache.analyze(url: source, analyzerID: "v1") { _ in expected } == replacement)
    }

    @Test("failed and source-mutated analysis are not cached")
    func failureRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try Data("before".utf8).write(to: source)
        let cache = MusicAnalysisCache(directory: root.appendingPathComponent("cache"))
        let expected = result
        await #expect(throws: CocoaError.self) {
            try await cache.analyze(url: source, analyzerID: "v1") { _ in
                throw CocoaError(.fileReadUnknown)
            }
        }
        await #expect(throws: CocoaError.self) {
            try await cache.analyze(url: source, analyzerID: "v1") { url in
                try Data("after!".utf8).write(to: url)
                return expected
            }
        }
        #expect(try await cache.analyze(url: source, analyzerID: "v1") { _ in expected } == expected)
    }
}

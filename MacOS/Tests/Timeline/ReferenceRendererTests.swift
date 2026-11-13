import AVFoundation
import Darwin
import Foundation
import Testing
@testable import Micromix

@Suite struct ReferenceRendererTests {
    private func makeAudio(_ url: URL, rate: Double = 48_000, channels: AVAudioChannelCount = 1, samples: [[Float]]) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<Int(channels) { for i in samples[c].indices { buffer.floatChannelData![c][i] = samples[c][i] } }
        try file.write(from: buffer)
    }

    @Test func trimOffsetOverlapAndPeak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
        try makeAudio(a, samples: [[0.1, 0.4, 0.4, 0.1]])
        try makeAudio(b, channels: 2, samples: [[0.8, 0.8], [0.2, 0.2]])
        let t1 = ArrangementDocument.Track(libraryID: UUID(), title: "a", offset: 1/48_000, trimStart: 1/48_000, trimEnd: 3/48_000)
        let t2 = ArrangementDocument.Track(libraryID: UUID(), title: "b", offset: 2/48_000, trimStart: 0, trimEnd: 2/48_000)
        let output = try ReferenceRenderer.render([.init(track: t1, url: a), .init(track: t2, url: b)], in: root)
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == 4)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4)!
        try file.read(into: buffer)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        let gain = Float(pow(10.0, -1.0/20.0) / 1.2)
        #expect(abs(l[0]) < 0.0001)
        #expect(abs(l[1] - 0.4 * gain) < 0.0001)
        #expect(abs(l[2] - 1.2 * gain) < 0.0001)
        #expect(abs(r[2] - 0.6 * gain) < 0.0001)
        #expect(abs(l[3] - 0.8 * gain) < 0.0001)
        let manifest = try JSONDecoder().decode(ReferenceRenderer.Manifest.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(manifest.version == 1 && manifest.tracks.map(\.libraryID) == [t1.libraryID, t2.libraryID])
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func longSparseOverlapAcrossChunks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
        try makeAudio(a, samples: [Array(repeating: 0.6, count: 5_000)])
        try makeAudio(b, channels: 2, samples: [Array(repeating: 0.6, count: 5_000), Array(repeating: 0.1, count: 5_000)])
        let offset = 60 * 48_000 + 4090
        let t1 = ArrangementDocument.Track(libraryID: UUID(), title: "a", offset: Double(offset) / 48_000, trimStart: 0, trimEnd: 5_000 / 48_000)
        let t2 = ArrangementDocument.Track(libraryID: UUID(), title: "b", offset: Double(offset + 3) / 48_000, trimStart: 0, trimEnd: 5_000 / 48_000)
        let output = try ReferenceRenderer.render([.init(track: t1, url: a), .init(track: t2, url: b)], in: root)
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == offset + 5_003)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 12)!
        file.framePosition = AVAudioFramePosition(offset - 2)
        try file.read(into: buffer, frameCount: 12)
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        let gain = Float(pow(10.0, -1.0 / 20.0) / 1.2)
        #expect(left[0] == 0 && right[1] == 0)
        #expect(abs(left[2] - 0.6 * gain) < 0.0001)
        #expect(abs(left[5] - 1.2 * gain) < 0.0001)
        #expect(abs(right[5] - 0.7 * gain) < 0.0001)
        #expect(abs(left[11] - 1.2 * gain) < 0.0001)
        let manifest = try JSONDecoder().decode(ReferenceRenderer.Manifest.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(abs(manifest.peakGain - Double(gain)) < 0.0001)
    }

    @Test func resampledTrimCrossesChunkBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, rate: 44_100, samples: [Array(repeating: 0.25, count: 8_820)])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 4093 / 48_000, trimStart: 0.05, trimEnd: 0.15)
        let output = try ReferenceRenderer.render([.init(track: track, url: source)], in: root)
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == 4093 + 4800)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 12)!
        file.framePosition = 4090
        try file.read(into: buffer)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        #expect(l[2] == 0 && r[2] == 0)
        for i in 3..<12 { #expect(abs(l[i] - 0.25) < 0.005 && abs(r[i] - 0.25) < 0.005) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["manifest.json", "reference.wav"])
    }

    @Test func compressedStereoConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: 0.2, count: 44_100)
            buffer.floatChannelData![1].update(repeating: 0.1, count: 44_100)
            try writer.write(from: buffer)
        }
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "aac", offset: 0, trimStart: 0.2, trimEnd: 0.8)
        let output = try ReferenceRenderer.render([.init(track: track, url: source)], in: root)
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == 28_800)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
        file.framePosition = 10_000
        try file.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][0] - 0.2) < 0.03)
        #expect(abs(buffer.floatChannelData![1][0] - 0.1) < 0.03)
    }

    @Test func lateCompressedTrimIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("late.m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: 0.2, count: 44_100)
            for _ in 0..<10 { try writer.write(from: buffer) }
        }
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "late", offset: 0, trimStart: 9.1, trimEnd: 9.11)
        let output = try ReferenceRenderer.render([.init(track: track, url: source)], in: root) { staging in
            let staged = try AVAudioFile(forReading: staging.appendingPathComponent(".decoded-0.caf"))
            #expect(staged.length == 480)
        }
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        try file.read(into: buffer)
        #expect(file.length == 480)
        #expect(abs(buffer.floatChannelData![0][200] - 0.2) < 0.03)
    }

    @Test func copyFallbackSharesSnapshotAndRetainsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.2, count: 200)])
        let original = try Data(contentsOf: source)
        let id = UUID()
        let first = ArrangementDocument.Track(libraryID: id, title: "first", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        let second = ArrangementDocument.Track(libraryID: id, title: "second", offset: 100 / 48_000, trimStart: 100 / 48_000, trimEnd: 200 / 48_000)
        var clones = 0
        let output = try ReferenceRenderer.render([.init(track: first, url: source), .init(track: second, url: source)], in: root, clone: { _, _ in
            clones += 1
            return EXDEV
        })
        #expect(clones == 1)
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["manifest.json", "reference.wav"])
        let audio = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 200)!
        try audio.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][150] - 0.2) < 0.0001)
    }

    @Test func cloneStorageFailureIsExplicitAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.2, count: 100)])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        #expect(throws: ReferenceRenderer.SnapshotStorageError.self) {
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root, clone: { _, _ in ENOSPC })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }

    @Test func mutationDuringFallbackCopyAbortsAndRetainsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.2, count: 100)])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        var mutated = false
        #expect(throws: ReferenceRenderer.RenderError.sourceChanged) {
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root, clone: { _, _ in EXDEV }, duringCopy: { _ in
                if !mutated {
                    mutated = true
                    try makeAudio(source, samples: [Array(repeating: 0.4, count: 100)])
                }
            })
        }
        #expect(mutated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
        #expect(try AVAudioFile(forReading: source).length == 100)
    }

    @Test func mutationDuringCaptureAbortsAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.2, count: 100)])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        #expect(throws: ReferenceRenderer.RenderError.sourceChanged) {
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root, duringCapture: { _ in
                try makeAudio(source, samples: [Array(repeating: 0.4, count: 100)])
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }

    @Test func repeatedSourceUsesOneCaptureAcrossDifferentTrims() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.2, count: 200)])
        let first = ArrangementDocument.Track(libraryID: UUID(), title: "first", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        let second = ArrangementDocument.Track(libraryID: UUID(), title: "second", offset: 100 / 48_000, trimStart: 100 / 48_000, trimEnd: 200 / 48_000)
        var captures = 0
        var decoded = 0
        let output = try ReferenceRenderer.render([.init(track: first, url: source), .init(track: second, url: source)], in: root, duringCapture: { _ in
            captures += 1
        }, afterSource: { _ in
            decoded += 1
            if decoded == 1 { try makeAudio(source, samples: [Array(repeating: 0.7, count: 200)]) }
        })
        #expect(captures == 1)
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 200)!
        try file.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][50] - 0.2) < 0.0001)
        #expect(abs(buffer.floatChannelData![0][150] - 0.2) < 0.0001)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["manifest.json", "reference.wav"])
    }

    @Test func snapshotsNativeRateBeforeBothPasses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [Array(repeating: 0.5, count: 100)])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 100 / 48_000)
        let output = try ReferenceRenderer.render([.init(track: track, url: source)], in: root) { _ in
            try FileManager.default.removeItem(at: source)
            try makeAudio(source, samples: [Array(repeating: 0.9, count: 100)])
        }
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
        try file.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][50] - 0.5) < 0.0001)
    }

    @Test func lateTrimStagesOnlySelectedFramesAndPreservesTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        var samples = Array(repeating: Float(0), count: 441_000)
        for i in 396_900..<samples.count { samples[i] = 0.3 }
        try makeAudio(source, rate: 44_100, samples: [samples])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "late", offset: 3 / 48_000, trimStart: 9.1, trimEnd: 9.11)
        let output = try ReferenceRenderer.render([.init(track: track, url: source)], in: root) { staging in
            let staged = try AVAudioFile(forReading: staging.appendingPathComponent(".decoded-0.caf"))
            #expect(staged.length == 480)
        }
        let file = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == 483)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 483)!
        try file.read(into: buffer)
        #expect(buffer.floatChannelData![0][2] == 0)
        #expect(abs(buffer.floatChannelData![0][3] - 0.3) < 0.005)
        #expect(abs(buffer.floatChannelData![0][482] - 0.3) < 0.005)
    }

    @Test func resampledLateTrimMatchesFullTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let samples = (0..<132_300).map { Float(sin(Double($0) * 0.13) * 0.3) }
        try makeAudio(source, rate: 44_100, samples: [samples])
        let full = ArrangementDocument.Track(libraryID: UUID(), title: "full", offset: 0, trimStart: 0, trimEnd: 3)
        let start = 120_013
        let trimmed = ArrangementDocument.Track(libraryID: UUID(), title: "trim", offset: 0, trimStart: Double(start) / 48_000, trimEnd: Double(start + 500) / 48_000)
        let wholeURL = try ReferenceRenderer.render([.init(track: full, url: source)], in: root)
        let trimURL = try ReferenceRenderer.render([.init(track: trimmed, url: source)], in: root)
        let whole = try AVAudioFile(forReading: wholeURL.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let part = try AVAudioFile(forReading: trimURL.appendingPathComponent("reference.wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
        let a = AVAudioPCMBuffer(pcmFormat: whole.processingFormat, frameCapacity: 500)!
        let b = AVAudioPCMBuffer(pcmFormat: part.processingFormat, frameCapacity: 500)!
        whole.framePosition = AVAudioFramePosition(start)
        try whole.read(into: a)
        try part.read(into: b)
        #expect(part.length == 500)
        for i in 0..<500 { #expect(abs(a.floatChannelData![0][i] - b.floatChannelData![0][i]) < 0.0001) }
    }

    @Test func cancellationAfterPeakCleansSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [[0.5, 0.5]])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 2 / 48_000)
        let task = Task {
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }

    @Test func failureAfterPeakCleansSnapshot() throws {
        enum Injected: Error { case failure }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [[0.5, 0.5]])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 2 / 48_000)
        #expect(throws: Injected.self) {
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root) { _ in throw Injected.failure }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }

    @Test func rejectsMultichannelInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        do {
            let writer = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
            buffer.frameLength = 2
            try writer.write(from: buffer)
        }
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 1 / 48_000)
        do {
            _ = try ReferenceRenderer.render([.init(track: track, url: source)], in: root)
            Issue.record("Expected unsupported format")
        } catch ReferenceRenderer.RenderError.unsupportedFormat {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.caf"])
    }

    @Test func cancellationCleansOwnedStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, samples: [[0.5, 0.5]])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "source", offset: 0, trimStart: 0, trimEnd: 1/48_000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ReferenceRenderer.render([.init(track: track, url: source)], in: root)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }

    @Test func failureCleansOwnedStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try makeAudio(source, rate: 44_100, samples: [[0.5, 0.5]])
        let track = ArrangementDocument.Track(libraryID: UUID(), title: "bad", offset: 0, trimStart: 0, trimEnd: 1)
        #expect(throws: (any Error).self) { try ReferenceRenderer.render([.init(track: track, url: source)], in: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source.wav"])
    }
}

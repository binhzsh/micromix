import AVFoundation
import Foundation
import Darwin

/// Offline reference: decode mono/stereo sources and mix at 48 kHz without per-track gain.
struct ReferenceRenderer {
    struct Source: Sendable {
        let track: ArrangementDocument.Track
        let url: URL
    }

    struct Manifest: Codable {
        struct Entry: Codable {
            let libraryID: UUID
            let title: String
            let sourceURL: URL
            let offset: Double
            let trimStart: Double
            let trimEnd: Double
        }
        let version: Int
        let sampleRate: Int
        let channels: Int
        let peakGain: Double
        let tracks: [Entry]
    }

    enum RenderError: Error, Equatable {
        case empty, unsupportedFormat, invalidTiming, tooLong, invalidSamples, sourceChanged
    }

    struct SnapshotStorageError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "Could not store a temporary source snapshot: \(underlying.localizedDescription). Check destination storage and permissions."
        }
    }

    struct CleanupError: LocalizedError {
        let original: Error
        let cleanup: Error
        let staging: URL
        var errorDescription: String? {
            "Export failed: \(original.localizedDescription). Could not remove temporary folder at \(staging.path): \(cleanup.localizedDescription)"
        }
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct FileVersion: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// Creates a unique output directory via same-parent rename. Never replaces a caller's files.
    static func render(_ sources: [Source], in parent: URL,
                       afterPeak: ((URL) throws -> Void)? = nil,
                       duringCapture: ((URL) throws -> Void)? = nil,
                       afterSource: ((URL) throws -> Void)? = nil,
                       clone: (URL, URL) -> Int32 = { source, destination in
                           clonefile(source.path, destination.path, 0) == 0 ? 0 : errno
                       },
                       duringCopy: ((URL) throws -> Void)? = nil) throws -> URL {
        guard !sources.isEmpty else { throw RenderError.empty }
        try ArrangementDocument(tracks: sources.map(\.track)).validate()
        let fm = FileManager.default
        let id = UUID().uuidString
        let staging = parent.appendingPathComponent(".reference-\(id).tmp", isDirectory: true)
        let destination = parent.appendingPathComponent("Reference-\(id)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
        // Keep the existing duration limit while bounding audio buffers independently of it.
        let maxFrames = 48_000 * 60 * 30
        let chunkSize = 4096
        var inputs: [(file: AVAudioFile, start: AVAudioFramePosition, offset: Int, count: Int, mono: Bool)] = []
        var totalFrames = 0
        var snapshots: [URL: URL] = [:]
        var snapshotsByIdentity: [FileIdentity: URL] = [:]
        for source in sources {
            try Task.checkCancellation()
            let key = source.url.standardizedFileURL.resolvingSymlinksInPath()
            let snapshot: URL
            if let existing = snapshots[key] {
                snapshot = existing
            } else {
                let before = try FileVersion(key)
                let identity = FileIdentity(device: before.device, inode: before.inode)
                if let existing = snapshotsByIdentity[identity] {
                    snapshot = existing
                } else {
                    snapshot = staging.appendingPathComponent(".source-\(snapshotsByIdentity.count).\(key.pathExtension)")
                    // A clone is cheap; on other volumes retain one bounded-memory full
                    // source copy until all selected trims have been decoded.
                    let cloneError = clone(key, snapshot)
                    if cloneError != 0 {
                        guard [EXDEV, ENOTSUP, EINVAL, ENOSYS].contains(cloneError) else {
                            throw SnapshotStorageError(underlying: POSIXError(POSIXErrorCode(rawValue: cloneError) ?? .EIO))
                        }
                        let input: FileHandle
                        let output: FileHandle
                        do {
                            input = try FileHandle(forReadingFrom: key)
                            let fd = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        } catch { throw SnapshotStorageError(underlying: error) }
                        defer { try? input.close(); try? output.close() }
                        while true {
                            try Task.checkCancellation()
                            let data: Data
                            do { data = try input.read(upToCount: 256 * 1024) ?? Data() }
                            catch { throw SnapshotStorageError(underlying: error) }
                            if data.isEmpty { break }
                            do { try output.write(contentsOf: data) }
                            catch { throw SnapshotStorageError(underlying: error) }
                            try duringCopy?(key)
                        }
                        try Task.checkCancellation()
                        do { try output.close() }
                        catch { throw SnapshotStorageError(underlying: error) }
                    }
                    try duringCapture?(key)
                    guard (try? FileVersion(key)) == before else { throw RenderError.sourceChanged }
                    snapshotsByIdentity[identity] = snapshot
                }
                snapshots[key] = snapshot
            }
            let file = try AVAudioFile(forReading: snapshot, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  (1...2).contains(format.channelCount) else {
                throw RenderError.unsupportedFormat
            }
            let t = source.track
            let startDouble = (t.trimStart * 48_000).rounded()
            let endDouble = (t.trimEnd * 48_000).rounded()
            let offsetDouble = (t.offset * 48_000).rounded()
            guard startDouble.isFinite, endDouble.isFinite, offsetDouble.isFinite,
                  startDouble >= 0, endDouble > startDouble,
                  t.trimEnd <= Double(file.length) / format.sampleRate + 0.5 / 48_000,
                  offsetDouble <= Double(maxFrames),
                  endDouble - startDouble <= Double(maxFrames),
                  offsetDouble + endDouble - startDouble <= Double(maxFrames) else { throw RenderError.invalidTiming }
            let start = AVAudioFramePosition(startDouble)
            let count = Int(endDouble - startDouble)
            let offset = Int(offsetDouble)
            totalFrames = max(totalFrames, offset + count)
            let convertedURL = staging.appendingPathComponent(".decoded-\(inputs.count).caf")
            if format.sampleRate == 48_000 {
                // Even native-rate PCM must be copied: the source can change between passes.
                file.framePosition = start
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize)) else { throw RenderError.unsupportedFormat }
                let writer = try AVAudioFile(forWriting: convertedURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                var remaining = count
                while remaining > 0 {
                    try Task.checkCancellation()
                    let requested = min(remaining, chunkSize)
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
                    guard Int(buffer.frameLength) == requested else { throw RenderError.invalidTiming }
                    try writer.write(from: buffer)
                    remaining -= requested
                }
            } else {
                // Convert sequentially, once, so the resampler retains its filter state
                // across mix chunks and both peak/write passes see identical samples.
                // Seek to an exact whole-second conversion boundary with one second of
                // preroll. This bounds work independent of the source trim endpoint and
                // preserves the absolute 48 kHz frame grid for integral sample rates.
                guard format.sampleRate.rounded() == format.sampleRate else { throw RenderError.unsupportedFormat }
                let seekSeconds = max(0, Int(startDouble / 48_000) - 1)
                file.framePosition = AVAudioFramePosition(Double(seekSeconds) * format.sampleRate)
                let discard = Int(startDouble) - seekSeconds * 48_000
                let convertedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: format.channelCount, interleaved: false)!
                guard let converter = AVAudioConverter(from: format, to: convertedFormat),
                      let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize)),
                      let convertedBuffer = AVAudioPCMBuffer(pcmFormat: convertedFormat, frameCapacity: AVAudioFrameCount(chunkSize)) else {
                    throw RenderError.unsupportedFormat
                }
                do {
                    let writer = try AVAudioFile(forWriting: convertedURL, settings: convertedFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    var written = 0
                    var skipped = 0
                    var readError: Error?
                    while written < count {
                        try Task.checkCancellation()
                        var conversionError: NSError?
                        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
                            do {
                                guard file.framePosition < file.length else {
                                    inputStatus.pointee = .endOfStream
                                    return nil
                                }
                                try file.read(into: sourceBuffer, frameCount: AVAudioFrameCount(chunkSize))
                                inputStatus.pointee = sourceBuffer.frameLength == 0 ? .endOfStream : .haveData
                                return sourceBuffer.frameLength == 0 ? nil : sourceBuffer
                            } catch {
                                readError = error
                                inputStatus.pointee = .endOfStream
                                return nil
                            }
                        }
                        if let readError { throw readError }
                        if let conversionError { throw conversionError }
                        let produced = Int(convertedBuffer.frameLength)
                        let skip = min(produced, discard - skipped)
                        skipped += skip
                        let available = min(produced - skip, count - written)
                        if available > 0 {
                            guard let channels = convertedBuffer.floatChannelData else { throw RenderError.unsupportedFormat }
                            if skip > 0 {
                                for channel in 0..<Int(format.channelCount) {
                                    memmove(channels[channel], channels[channel].advanced(by: skip), available * MemoryLayout<Float>.size)
                                }
                            }
                            convertedBuffer.frameLength = AVAudioFrameCount(available)
                            try writer.write(from: convertedBuffer)
                            written += available
                        }
                        if status == .endOfStream || status == .error || (produced == 0 && status != .inputRanDry) {
                            break
                        }
                    }
                    guard written == count else { throw RenderError.invalidTiming }
                }
            }
            let decoded = try AVAudioFile(forReading: convertedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            inputs.append((decoded, 0, offset, count, format.channelCount == 1))
            try afterSource?(source.url)
        }
        // Only decoded trims are needed for the two mixing passes.
        for snapshot in snapshotsByIdentity.values { try fm.removeItem(at: snapshot) }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        guard let mix = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunkSize)),
              let mixed = mix.floatChannelData else { throw RenderError.unsupportedFormat }

        // Both passes use the same source order and chunk boundaries: first measure the
        // global peak, then remix and write with the resulting constant gain.
        func process(output: AVAudioFile?, gain: Float) throws -> Float {
            var peak: Float = 0
            var position = 0
            while position < totalFrames {
                try Task.checkCancellation()
                let n = min(chunkSize, totalFrames - position)
                mix.frameLength = AVAudioFrameCount(n)
                for channel in 0..<2 { mixed[channel].update(repeating: 0, count: n) }
                for input in inputs {
                    try Task.checkCancellation()
                    let begin = max(position, input.offset)
                    let end = min(position + n, input.offset + input.count)
                    guard begin < end else { continue }
                    let requested = end - begin
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.file.processingFormat, frameCapacity: AVAudioFrameCount(requested)) else { throw RenderError.unsupportedFormat }
                    input.file.framePosition = input.start + AVAudioFramePosition(begin - input.offset)
                    try input.file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
                    guard Int(buffer.frameLength) == requested, let channels = buffer.floatChannelData else { throw RenderError.unsupportedFormat }
                    for i in 0..<requested {
                        let l = channels[0][i]
                        let r = input.mono ? l : channels[1][i]
                        guard l.isFinite, r.isFinite else { throw RenderError.invalidSamples }
                        let index = begin - position + i
                        mixed[0][index] += l
                        mixed[1][index] += r
                        guard mixed[0][index].isFinite, mixed[1][index].isFinite else { throw RenderError.invalidSamples }
                    }
                }
                for i in 0..<n {
                    peak = max(peak, abs(mixed[0][i]), abs(mixed[1][i]))
                    mixed[0][i] *= gain
                    mixed[1][i] *= gain
                }
                if let output { try output.write(from: mix) }
                position += n
            }
            return peak
        }
        let peak = try process(output: nil, gain: 1)
        try afterPeak?(staging)
        try Task.checkCancellation()
        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        let gain: Float = peak > ceiling ? ceiling / peak : 1
        let outputURL = staging.appendingPathComponent("reference.wav")
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            _ = try process(output: output, gain: gain)
        }
        for index in inputs.indices {
            let temporary = staging.appendingPathComponent(".decoded-\(index).caf")
            if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        }
        let manifest = Manifest(version: 1, sampleRate: 48_000, channels: 2, peakGain: Double(gain), tracks: sources.map {
            Manifest.Entry(libraryID: $0.track.libraryID, title: $0.track.title, sourceURL: $0.url, offset: $0.track.offset, trimStart: $0.track.trimStart, trimEnd: $0.track.trimEnd)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        return destination
        } catch {
            let original = error
            do { try fm.removeItem(at: staging) }
            catch { throw CleanupError(original: original, cleanup: error, staging: staging) }
            throw original
        }
    }
}

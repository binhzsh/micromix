import AVFoundation

/// Standalone mono Float32 proxy experiment. One converter processes the entire
/// source, including its tail; callers persist each output block before returning.
struct TimelinePCMProxy {
    enum Failure: Error {
        case invalidBlockSize, invalidInput, conversionFailed, stalled
    }

    static let maximumBlockFrames = 16_384

    /// `read` returns at most the requested frames and an empty array only at EOF.
    /// Neither callback may retain or modify the converter's buffers.
    static func convert(blockFrames: Int, read: (Int) throws -> [Float],
                        write: ([Float]) throws -> Void) throws {
        guard (1...maximumBlockFrames).contains(blockFrames) else { throw Failure.invalidBlockSize }
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(blockFrames))
        else { throw Failure.conversionFailed }

        var ended = false
        var callbackError: Error?
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                if ended || callbackError != nil {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let limit = min(Int(requested), blockFrames)
                    let samples = try read(limit)
                    guard samples.count <= limit, samples.allSatisfy(\.isFinite) else {
                        throw Failure.invalidInput
                    }
                    if samples.isEmpty {
                        ended = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                        frameCapacity: AVAudioFrameCount(samples.count)),
                          let channel = buffer.floatChannelData?[0] else { throw Failure.conversionFailed }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    callbackError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let callbackError { throw callbackError }
            if let error { throw error }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                try write(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            switch status {
            case .endOfStream: return
            case .error: throw Failure.conversionFailed
            case .inputRanDry: throw Failure.stalled
            case .haveData:
                if output.frameLength == 0 { throw Failure.stalled }
            @unknown default: throw Failure.conversionFailed
            }
        }
    }
}

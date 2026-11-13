import AVFAudio
import SwiftUI

/// Downsamples an audio file into `count` amplitude peaks for waveform
/// display. Runs off the main thread; callers should hop via `Task.detached`.
enum WaveformPeaks {
    static func computePeaks(for url: URL, count: Int) -> [CGFloat] {
        guard count > 0, let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameLength = file.length
        guard frameLength > 0 else { return [] }
        let bucketCount = Int(min(frameLength, Int64(count)))
        let baseSize = frameLength / Int64(bucketCount)
        let remainder = frameLength % Int64(bucketCount)
        let format = file.processingFormat
        let chunkSize: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else { return [] }
        var peaks: [CGFloat] = []
        peaks.reserveCapacity(bucketCount)
        for bucket in 0..<bucketCount {
            var remaining = baseSize + (Int64(bucket) < remainder ? 1 : 0)
            var peak: Float = 0
            while remaining > 0 {
                let requested = AVAudioFrameCount(min(remaining, Int64(chunkSize)))
                guard (try? file.read(into: buffer, frameCount: requested)) != nil,
                      buffer.frameLength > 0, let channels = buffer.floatChannelData else { return [] }
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(channels[channel][index * buffer.stride]))
                    }
                }
                remaining -= Int64(buffer.frameLength)
            }
            peaks.append(CGFloat(peak))
        }
        return peaks
    }
}

/// Mini waveform peek (Phase 5.3): a row of bars derived from the item's
/// audio, so the user can visually confirm an asset before chaining it.
struct MiniWaveform: View {
    let item: LibraryItem
    let library: LocalLibrary
    var barCount = 24
    var fillsWidth = false

    @State private var peaks: [CGFloat]?

    private var barWidth: CGFloat { barCount > 12 ? 2 : 3 }

    var body: some View {
        Group {
            if let peaks {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                        Capsule()
                            .fill(Palette.ink.opacity(0.55))
                            .frame(width: fillsWidth ? nil : barWidth, height: max(2, min(peak, 1) * 18))
                            .frame(maxWidth: fillsWidth ? .infinity : nil)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<barCount, id: \.self) { _ in
                        Capsule()
                            .fill(Palette.ink.opacity(0.16))
                            .frame(width: fillsWidth ? nil : barWidth, height: 2)
                            .frame(maxWidth: fillsWidth ? .infinity : nil)
                    }
                }
            }
        }
        .frame(height: 20, alignment: .center)
        .task(id: item.id) {
            peaks = nil
            guard item.kind == .audio else { return }
            let url = library.resolvedURL(for: item)
            let count = barCount
            let computed = await Task.detached(priority: .utility) {
                WaveformPeaks.computePeaks(for: url, count: count)
            }.value
            guard !Task.isCancelled else { return }
            peaks = computed
        }
        .accessibilityLabel("Waveform preview of \(item.title)")
    }
}

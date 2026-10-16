import AVFAudio
import SwiftUI

/// Downsamples an audio file into `count` amplitude peaks for waveform
/// display. Runs off the main thread; callers should hop via `Task.detached`.
enum WaveformPeaks {
    static func computePeaks(for url: URL, count: Int) -> [CGFloat] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameLength = AVAudioFramePosition(file.length)
        guard frameLength > 0 else { return [] }
        let hop = max(1, frameLength / AVAudioFramePosition(count))
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hop)) else { return [] }
        var peaks: [CGFloat] = []
        peaks.reserveCapacity(count)
        var position: AVAudioFramePosition = 0
        while position < frameLength, peaks.count < count {
            let framesToRead = min(AVAudioFrameCount(hop), AVAudioFrameCount(frameLength - position))
            file.framePosition = position
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: framesToRead)) != nil,
                  buffer.frameLength > 0 else { break }
            var peak: Float = 0
            if let channel = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channel[index]))
                }
            }
            peaks.append(CGFloat(peak))
            position += Int64(framesToRead)
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

    @State private var peaks: [CGFloat]?

    private var barWidth: CGFloat { barCount > 12 ? 2 : 3 }

    var body: some View {
        Group {
            if let peaks {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                        Capsule()
                            .fill(Palette.ink.opacity(0.55))
                            .frame(width: barWidth, height: max(2, min(peak, 1) * 18))
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<barCount, id: \.self) { _ in
                        Capsule()
                            .fill(Palette.ink.opacity(0.16))
                            .frame(width: barWidth, height: 2)
                    }
                }
            }
        }
        .frame(height: 20, alignment: .center)
        .task(id: item.id) {
            guard item.kind == .audio else { return }
            let url = library.resolvedURL(for: item)
            let count = barCount
            let computed = await Task.detached(priority: .utility) {
                WaveformPeaks.computePeaks(for: url, count: count)
            }.value
            peaks = computed.isEmpty ? [] : computed
        }
        .accessibilityLabel("Waveform preview of \(item.title)")
    }
}

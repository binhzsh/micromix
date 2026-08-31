import AVFoundation
import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

struct LocalMusicAnalysis: Equatable, Sendable {
    let durationSeconds: Double
    let beatsPerMinute: Double?
    let key: String?
    let instruments: [String]

    var compactDescription: String {
        var parts = [String(format: "%.1f SEC", durationSeconds)]
        if let beatsPerMinute { parts.append("\(Int(beatsPerMinute.rounded())) BPM") }
        if let key { parts.append(key.uppercased()) }
        if !instruments.isEmpty { parts.append(instruments.map { $0.uppercased() }.joined(separator: "+")) }
        return parts.joined(separator: "  •  ")
    }
}

enum LocalMusicAnalyzer {
    static func analyze(url: URL) async throws -> LocalMusicAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        #if canImport(MusicUnderstanding)
        if #available(macOS 27.0, *) {
            let session = try await MusicUnderstandingSession(asset: asset)
            let result = try await session.analyze(
                for: [.rhythm, .key, .instrumentActivity]
            )
            let signature = result.key?.ranges.first?.value
            let key = signature.map { "\($0.tonic.rawValue) \($0.mode.rawValue)" }
            let instruments = result.instrumentActivity?.ranges
                .filter { !$0.value.isEmpty }
                .map(\.key.rawValue)
                .sorted() ?? []
            return LocalMusicAnalysis(
                durationSeconds: duration,
                beatsPerMinute: result.rhythm?.beatsPerMinute.map(Double.init),
                key: key,
                instruments: instruments
            )
        }
        #endif

        return LocalMusicAnalysis(
            durationSeconds: duration,
            beatsPerMinute: nil,
            key: nil,
            instruments: []
        )
    }
}

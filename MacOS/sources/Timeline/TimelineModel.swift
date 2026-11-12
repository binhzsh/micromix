import AVFoundation
import Combine
import Foundation

struct TimelineTrack: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let sourceDuration: Double
    var offset: Double = 0
    var trimStart: Double = 0
    /// Absolute end position in the source, not the amount removed from its end.
    var trimEnd: Double

    func validate() throws {
        guard sourceDuration.isFinite, sourceDuration > 0,
              offset.isFinite, offset >= 0,
              trimStart.isFinite, trimStart >= 0,
              trimEnd.isFinite, trimEnd <= sourceDuration,
              trimStart < trimEnd else {
            throw TimelineError.invalidTrack(title)
        }
    }
}

enum TimelineError: LocalizedError {
    case empty
    case invalidTrack(String)
    case noAudio(String)

    var errorDescription: String? {
        switch self {
        case .empty: "Add an audio track before playing."
        case .invalidTrack(let title): "Invalid timing for \(title). Use a nonnegative offset and a trim range within the source duration."
        case .noAudio(let title): "Could not read an audio track from \(title)."
        }
    }
}

private final class TimelineObservers: @unchecked Sendable {
    var end: NSObjectProtocol?
    var failure: NSObjectProtocol?

    func remove() {
        if let end { NotificationCenter.default.removeObserver(end) }
        if let failure { NotificationCenter.default.removeObserver(failure) }
        end = nil
        failure = nil
    }

    deinit { remove() }
}

@MainActor
final class TimelineModel: ObservableObject {
    @Published var tracks: [TimelineTrack] = []
    @Published var error: String?
    @Published private(set) var isPlaying = false
    private var player: AVPlayer?
    private let observers = TimelineObservers()
    private var needsRebuild = true
    private var generation = 0
    @Published private(set) var isPreparing = false

    func add(title: String, url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let track = TimelineTrack(title: title, url: url, sourceDuration: duration, trimEnd: duration)
            try track.validate()
            invalidate()
            tracks.append(track)
            error = nil
        } catch {
            self.error = "Unable to add \(title): \(error.localizedDescription)"
        }
    }

    func remove(id: UUID) {
        invalidate()
        tracks.removeAll { $0.id == id }
    }

    func invalidate() {
        stop()
        needsRebuild = true
        error = nil
    }

    func play(stopping audioPlayer: AudioPlayer, midiPreview: MidiPreview) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        let token = generation
        do {
            if needsRebuild {
                guard !tracks.isEmpty else { throw TimelineError.empty }
                let composition = AVMutableComposition()
                for track in tracks {
                    try track.validate()
                    let asset = AVURLAsset(url: track.url)
                    let sources = try await asset.loadTracks(withMediaType: .audio)
                    guard generation == token else { return }
                    guard let source = sources.first,
                          let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw TimelineError.noAudio(track.title)
                    }
                    try destination.insertTimeRange(
                        CMTimeRange(start: CMTime(seconds: track.trimStart, preferredTimescale: 60000),
                                    duration: CMTime(seconds: track.trimEnd - track.trimStart, preferredTimescale: 60000)),
                        of: source, at: CMTime(seconds: track.offset, preferredTimescale: 60000)
                    )
                }
                let item = AVPlayerItem(asset: composition)
                observers.remove()
                observers.end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.stop() }
                }
                observers.failure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                    let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Unknown playback error."
                    Task { @MainActor in
                        self?.stop()
                        self?.error = "Timeline playback failed: \(message)"
                    }
                }
                player = AVPlayer(playerItem: item)
                needsRebuild = false
            }
            audioPlayer.stop()
            midiPreview.stop()
            player?.play()
            isPlaying = true
            error = nil
        } catch {
            guard generation == token else { return }
            stop()
            self.error = "Unable to play timeline: \(error.localizedDescription)"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        generation += 1
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
    }

}

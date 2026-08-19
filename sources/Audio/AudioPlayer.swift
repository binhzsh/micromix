import Foundation
import AVFAudio
import Combine

/// Wraps `AVAudioPlayer` for playback of generated audio results.
///
/// Runs on the main actor; playback duration is derived locally via
/// `AVAudioFile` so the manifest can carry a real duration.
@MainActor
final class AudioPlayer: ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
    }

    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentItem: LibraryItem?
    @Published private(set) var currentDuration: Double?

    private var player: AVAudioPlayer?

    /// Load audio at `url` for playback. Returns derived duration (seconds),
    /// or nil if the file cannot be opened.
    @discardableResult
    func load(url: URL, item: LibraryItem) -> Double? {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            self.currentItem = item
            self.state = .idle
            let duration = Self.duration(of: url) ?? player.duration
            self.currentDuration = duration
            return duration
        } catch {
            self.currentItem = nil
            self.state = .idle
            return nil
        }
    }

    func toggle() {
        switch state {
        case .playing: pause()
        default: play()
        }
    }

    func play() {
        guard let player else { return }
        player.prepareToPlay()
        player.play()
        state = .playing
    }

    func pause() {
        player?.pause()
        state = .paused
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        state = .idle
    }

    var isPlaying: Bool { state == .playing }

    /// Derive audio duration from a file using AVFoundation metadata.
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameLength = Double(file.length)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return frameLength / sampleRate
    }
}

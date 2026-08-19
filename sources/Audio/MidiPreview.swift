import Foundation
import AVFAudio
import Combine

/// MIDI preview for transcribed `.mid` results.
///
/// `AVAudioPlayer` plays MIDI through the system General-MIDI handler, so a
/// dedicated sampler engine is unnecessary. Runs on the main actor; wraps the
/// same player surface as `AudioPlayer` (load/play/pause/stop + state).
@MainActor
final class MidiPreview: ObservableObject {
    enum PreviewState: Equatable {
        case idle
        case playing
        case paused
    }

    @Published private(set) var state: PreviewState = .idle
    @Published private(set) var currentItem: LibraryItem?

    private var player: AVAudioPlayer?

    /// Load a MIDI result at `url` for preview.
    @discardableResult
    func load(url: URL, item: LibraryItem) -> Bool {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            self.currentItem = item
            self.state = .idle
            return true
        } catch {
            self.currentItem = nil
            self.state = .idle
            return false
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
        player = nil
        currentItem = nil
        state = .idle
    }

    var isPlaying: Bool { state == .playing }
}
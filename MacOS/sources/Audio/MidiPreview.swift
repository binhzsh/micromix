import Foundation
import AVFoundation
import Combine

/// MIDI preview for transcribed `.mid` results.
///
/// Uses `AVMIDIPlayer`, which plays a Standard MIDI File through Apple's built-in
/// General-MIDI software synthesiser (a `MusicPlayer`/`AVAudioUnitSampler`
/// backend), giving real MIDI preview without shipping a soundfont.
///
/// Note: `AVAudioUnitSampler`'s `loadMIDIFile(from:)` is unavailable on the
/// macOS 26 SDK, so `AVMIDIPlayer` is the supported path for file-based MIDI
/// preview. This matches the design intent of "MIDI preview through a built-in
/// synth" (spec §4 / Task 8). Runs on the main actor.
@MainActor
final class MidiPreview: ObservableObject {
    enum PreviewState: Equatable {
        case idle
        case playing
        case paused
    }

    @Published private(set) var state: PreviewState = .idle
    @Published private(set) var currentItem: LibraryItem?

    private var player: AVMIDIPlayer?
    private var pausedAt: TimeInterval?
    /// Rises on every load/stop/pause. AVMIDIPlayer's play completion fires
    /// when playback stops as well as when it finishes, so a completion from a
    /// superseded playback must be recognized as stale and ignored.
    private var generation = 0

    /// Invoked whenever a preview is about to sound; the composition root stops
    /// the audio player with it so only one stream is audible at a time.
    var onStart: (@MainActor () -> Void)?

    /// Whether pressing play for `item` should resume a paused preview rather
    /// than load the file again (which would restart from the top).
    func shouldResume(for item: LibraryItem) -> Bool {
        currentItem?.id == item.id && state == .paused
    }

    /// Load a MIDI result at `url` for preview. Returns false if the file can't
    /// be opened (e.g. corrupt or unsupported).
    @discardableResult
    func load(url: URL, item: LibraryItem) -> Bool {
        stop()
        do {
            let player = try AVMIDIPlayer(contentsOf: url, soundBankURL: nil)
            player.prepareToPlay()
            self.player = player
            self.currentItem = item
            self.state = .idle
            return true
        } catch {
            self.player = nil
            self.currentItem = nil
            self.state = .idle
            return false
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
        onStart?()
        if let pausedAt {
            player.currentPosition = pausedAt
            self.pausedAt = nil
        } else if state == .idle {
            // Replaying a finished preview restarts from the top; resuming a
            // paused one keeps its position via `pausedAt` above.
            player.currentPosition = 0
        }
        generation += 1
        let token = generation
        player.play { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.pausedAt = nil
                self.state = .idle
            }
        }
        state = .playing
    }

    func pause() {
        guard let player else { return }
        pausedAt = player.currentPosition
        // Bump the generation so the stopped playback's completion (which
        // AVMIDIPlayer fires on stop) cannot overwrite `.paused` with `.idle`.
        generation += 1
        player.stop()
        state = .paused
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        pausedAt = nil
        currentItem = nil
        state = .idle
    }

    var isPlaying: Bool { state == .playing }
}

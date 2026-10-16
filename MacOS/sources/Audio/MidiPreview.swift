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
        }
        player.play { [weak self] in
            Task { @MainActor in
                self?.state = .idle
            }
        }
        state = .playing
    }

    func pause() {
        guard let player else { return }
        pausedAt = player.currentPosition
        player.stop()
        state = .paused
    }

    func stop() {
        player?.stop()
        player = nil
        pausedAt = nil
        currentItem = nil
        state = .idle
    }

    var isPlaying: Bool { state == .playing }
}

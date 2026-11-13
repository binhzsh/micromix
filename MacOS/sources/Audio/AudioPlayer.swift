import Foundation
import AVFAudio
import Combine

private final class AudioPlayerCompletionDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let didFinish: @Sendable () -> Void

    init(didFinish: @escaping @Sendable () -> Void) {
        self.didFinish = didFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish()
    }
}

/// Coordinates ownership, including a timeline that is still preparing.
@MainActor
final class PreviewCoordinator {
    private weak var owner: AnyObject?
    private var stopOwner: (@MainActor () -> Void)?
    private var revision = 0

    func reserve() -> Int {
        revision += 1
        return revision
    }

    func isCurrent(_ reservation: Int) -> Bool { revision == reservation }

    func commit(_ reservation: Int, owner newOwner: AnyObject, stop: @escaping @MainActor () -> Void) -> Bool {
        guard isCurrent(reservation) else { return false }
        if owner !== newOwner { stopOwner?() }
        owner = newOwner
        stopOwner = stop
        return true
    }

    func claim(_ newOwner: AnyObject, stop: @escaping @MainActor () -> Void) {
        revision += 1
        if owner !== newOwner { stopOwner?() }
        owner = newOwner
        stopOwner = stop
    }
}

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
    @Published private(set) var currentTime: Double = 0

    /// Invoked whenever playback is about to sound.
    var onStart: (@MainActor () -> Void)?

    let coordinator: PreviewCoordinator

    init(coordinator: PreviewCoordinator = PreviewCoordinator()) {
        self.coordinator = coordinator
    }

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private lazy var completionDelegate = AudioPlayerCompletionDelegate { [weak self] in
        Task { @MainActor in
            self?.progressTask?.cancel()
            self?.currentTime = self?.currentDuration ?? 0
            self?.state = .idle
        }
    }

    /// Whether pressing play for `item` should resume a paused playback rather
    /// than load the file again (which would restart from the top).
    func shouldResume(for item: LibraryItem) -> Bool {
        currentItem?.id == item.id && state == .paused
    }

    /// Load audio at `url` for playback. Returns derived duration (seconds),
    /// or nil if the file cannot be opened.
    @discardableResult
    func load(url: URL, item: LibraryItem) -> Double? {
        progressTask?.cancel()
        currentTime = 0
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = completionDelegate
            self.player = player
            self.currentItem = item
            self.state = .idle
            let duration = Self.duration(of: url) ?? player.duration
            self.currentDuration = duration
            return duration
        } catch {
            self.player = nil
            self.currentItem = nil
            self.currentDuration = nil
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
        coordinator.claim(self) { [weak self] in self?.stop() }
        onStart?()
        if state == .idle {
            // Replaying a finished (or freshly loaded) item starts from the
            // top; resuming a paused one keeps its currentTime.
            player.currentTime = 0
        }
        player.prepareToPlay()
        player.play()
        state = .playing
        currentTime = player.currentTime
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
            }
        }
    }

    func pause() {
        guard let player else { return }
        player.pause()
        progressTask?.cancel()
        currentTime = player.currentTime
        state = .paused
    }

    /// Seeking an idle item makes it paused, so play resumes at the chosen position.
    func seek(to time: Double) {
        guard let player, time.isFinite else { return }
        player.currentTime = min(max(time, 0), player.duration)
        currentTime = player.currentTime
        if state == .idle { state = .paused }
    }

    func stop() {
        progressTask?.cancel()
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
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

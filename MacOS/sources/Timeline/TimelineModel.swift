import AVFoundation
import Combine
import Foundation

struct TimelineTrack: Identifiable {
    let id = UUID()
    var libraryID: UUID = UUID()
    let title: String
    let url: URL?
    let sourceDuration: Double
    var offset: Double = 0
    var trimStart: Double = 0
    /// Absolute end position in the source, not the amount removed from its end.
    var trimEnd: Double

    mutating func setOffset(_ value: Double) {
        guard value.isFinite else { return }
        offset = max(0, value)
    }

    mutating func setTrimStart(_ value: Double) {
        guard value.isFinite else { return }
        trimStart = min(max(0, value), max(0, trimEnd - min(0.001, sourceDuration)))
    }

    mutating func setTrimEnd(_ value: Double) {
        guard value.isFinite else { return }
        trimEnd = min(sourceDuration, max(trimStart + min(0.001, sourceDuration), value))
    }

    func validate() throws {
        guard url != nil else { throw TimelineError.unresolvedTrack(title) }
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
    case unresolvedTrack(String)
    case noAudio(String)

    var errorDescription: String? {
        switch self {
        case .empty: "Add an audio track before playing."
        case .invalidTrack(let title): "Invalid timing for \(title). Use a nonnegative offset and a trim range within the source duration."
        case .unresolvedTrack(let title): "Missing or unreadable Library audio for \(title)."
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
    @Published private(set) var position: Double = 0
    var duration: Double {
        tracks.map { $0.offset + max(0, $0.trimEnd - $0.trimStart) }.filter(\.isFinite).max() ?? 0
    }
    private var progressTask: Task<Void, Never>?
    private var player: AVPlayer?
    private let observers = TimelineObservers()
    private var needsRebuild = true
    private var generation = 0
    @Published private(set) var isPreparing = false
    private let beforePreparation: @MainActor () async -> Void
    private let beforePlayback: @MainActor () async -> Void
    private let beforeSeek: @MainActor (Double) async -> Void
    private let beforeNotificationDelivery: @MainActor () async -> Void
    private let afterNotificationDelivery: @MainActor () -> Void
    private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
    private var seekRevision = 0
    private var seekPending = false

    init(beforePreparation: @escaping @MainActor () async -> Void = {},
         beforePlayback: @escaping @MainActor () async -> Void = {},
         beforeSeek: @escaping @MainActor (Double) async -> Void = { _ in },
         beforeNotificationDelivery: @escaping @MainActor () async -> Void = {},
         afterNotificationDelivery: @escaping @MainActor () -> Void = {},
         makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) }) {
        self.beforePreparation = beforePreparation
        self.beforePlayback = beforePlayback
        self.beforeSeek = beforeSeek
        self.beforeNotificationDelivery = beforeNotificationDelivery
        self.afterNotificationDelivery = afterNotificationDelivery
        self.makePlayer = makePlayer
    }

    func add(libraryID: UUID, title: String, url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let track = TimelineTrack(libraryID: libraryID, title: title, url: url, sourceDuration: duration, trimEnd: duration)
            try track.validate()
            invalidate()
            tracks.append(track)
            error = nil
        } catch {
            self.error = "Unable to add \(title): \(error.localizedDescription)"
        }
    }

    /// Resolve by stable identity only. Missing media and out-of-range trims remain in the document.
    func load(_ document: ArrangementDocument, from library: LocalLibrary) throws {
        try document.validate()
        let resolved = document.tracks.map { saved in
            let item = library.items.first { $0.id == saved.libraryID && $0.kind == .audio }
            let candidate = item.map { library.resolvedURL(for: $0) }
            let file = candidate.flatMap { try? AVAudioFile(forReading: $0) }
            let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            return TimelineTrack(libraryID: saved.libraryID, title: saved.title,
                                 url: file == nil ? nil : candidate, sourceDuration: duration,
                                 offset: saved.offset, trimStart: saved.trimStart, trimEnd: saved.trimEnd)
        }
        invalidate()
        tracks = resolved
    }

    var documentSnapshot: ArrangementDocument {
        ArrangementDocument(tracks: tracks.map {
            .init(libraryID: $0.libraryID, title: $0.title, offset: $0.offset,
                  trimStart: $0.trimStart, trimEnd: $0.trimEnd)
        })
    }

    func arrangementDocument() throws -> ArrangementDocument {
        let document = documentSnapshot
        try document.validate()
        return document
    }

    /// Capture current timing and resolve stable Library identities at export time.
    func referenceSources(from library: LocalLibrary) throws -> [ReferenceRenderer.Source] {
        let document = try arrangementDocument()
        guard !document.tracks.isEmpty else { throw TimelineError.empty }
        return try document.tracks.map { track in
            guard let item = library.items.first(where: { $0.id == track.libraryID && $0.kind == .audio }) else {
                throw TimelineError.unresolvedTrack(track.title)
            }
            let url = library.resolvedURL(for: item)
            guard let file = try? AVAudioFile(forReading: url) else { throw TimelineError.unresolvedTrack(track.title) }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration.isFinite, track.trimEnd <= duration else { throw TimelineError.invalidTrack(track.title) }
            return ReferenceRenderer.Source(track: track, url: url)
        }
    }

    /// Re-resolve the saved identities without replacing the timing or dirty baseline.
    func retryResolution(from library: LocalLibrary) throws {
        try load(arrangementDocument(), from: library)
    }

    func fitTrimToSource(id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }),
              tracks[index].url != nil, tracks[index].sourceDuration > 0 else { return }
        invalidate()
        let duration = tracks[index].sourceDuration
        tracks[index].trimStart = min(tracks[index].trimStart, max(0, duration - min(0.001, duration)))
        tracks[index].trimEnd = min(tracks[index].trimEnd, duration)
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
        let coordinator = audioPlayer.coordinator
        let reservation = coordinator.reserve()
        isPreparing = true
        generation += 1
        let token = generation
        defer {
            if generation == token { isPreparing = false }
        }
        await beforePreparation()
        guard generation == token else { return }
        do {
            guard !tracks.isEmpty else { throw TimelineError.empty }
            for track in tracks {
                try track.validate()
                guard let url = track.url, let file = try? AVAudioFile(forReading: url) else {
                    throw TimelineError.unresolvedTrack(track.title)
                }
                let currentDuration = Double(file.length) / file.processingFormat.sampleRate
                guard currentDuration.isFinite, track.trimEnd <= currentDuration else {
                    throw TimelineError.invalidTrack(track.title)
                }
            }
            if needsRebuild {
                let composition = AVMutableComposition()
                for track in tracks {
                    guard let url = track.url else { throw TimelineError.unresolvedTrack(track.title) }
                    let asset = AVURLAsset(url: url)
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
                player = makePlayer(item)
                needsRebuild = false
            }
            guard let item = player?.currentItem else { return }
            observers.remove()
            observers.end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item else { return }
                    await self.beforeNotificationDelivery()
                    defer { self.afterNotificationDelivery() }
                    guard self.generation == token, self.player?.currentItem === item else { return }
                    self.stop()
                }
            }
            observers.failure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Unknown playback error."
                Task { @MainActor in
                    guard let self, let item else { return }
                    await self.beforeNotificationDelivery()
                    defer { self.afterNotificationDelivery() }
                    guard self.generation == token, self.player?.currentItem === item else { return }
                    self.stop()
                    self.error = "Timeline playback failed: \(message)"
                }
            }
            await beforePlayback()
            // Serialize seeks while preparing; a newer position must complete before playback.
            while true {
                guard generation == token, coordinator.isCurrent(reservation) else { return }
                let revision = seekRevision
                let target = position
                await beforeSeek(target)
                guard generation == token, coordinator.isCurrent(reservation) else { return }
                await player?.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                guard generation == token, coordinator.isCurrent(reservation) else { return }
                if revision == seekRevision {
                    seekPending = false
                    break
                }
            }
            guard coordinator.commit(reservation, owner: self, stop: { [weak self] in self?.stop() }) else { return }
            player?.play()
            isPlaying = true
            progressTask?.cancel()
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.updateProgress()
                }
            }
            error = nil
        } catch {
            guard generation == token, coordinator.isCurrent(reservation) else { return }
            stop()
            self.error = "Unable to play timeline: \(error.localizedDescription)"
        }
    }

    func updateProgress() {
        let time = player?.currentTime().seconds ?? 0
        if time.isFinite && !seekPending { position = min(max(0, time), duration) }
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        position = min(max(0, time), duration)
        seekRevision += 1
        seekPending = true
        if !isPreparing, let player {
            let revision = seekRevision
            let token = generation
            let target = position
            Task { [weak self] in
                guard let self else { return }
                await self.beforeSeek(target)
                guard self.generation == token, self.seekRevision == revision else { return }
                await player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                guard self.generation == token, self.seekRevision == revision else { return }
                self.seekPending = false
            }
        }
    }

    func pause() {
        generation += 1
        isPreparing = false
        progressTask?.cancel()
        player?.pause()
        if !seekPending, let time = player?.currentTime().seconds, time.isFinite {
            position = min(max(0, time), duration)
        }
        isPlaying = false
    }

    func stop() {
        generation += 1
        isPreparing = false
        seekRevision += 1
        seekPending = false
        progressTask?.cancel()
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.seek(to: .zero)
        position = 0
        isPlaying = false
    }

}

import Foundation
import Combine
import UniformTypeIdentifiers

/// Drives the TRANSCRIBE flow: audio file selection, instrument selection,
/// tempo detection toggle, job lifecycle (via `JobRunner`), and persistence of
/// the returned MIDI into `LocalLibrary`.
///
/// Test seams: `api` and `library` are injected as `Sendable` protocols so
/// fakes can stand in for the real actor / `@MainActor` store (same pattern as
/// `GenerateViewModel`).
@MainActor
final class TranscribeViewModel: ObservableObject {
    enum SourceReadError: Error {
        case tooLarge
        case unreadable
    }

    nonisolated static var maximumSourceBytes: Int { 200 * 1024 * 1024 }

    /// High-level flow phase surfaced to the UI.
    enum Phase: Equatable {
        case idle
        case running
        case done
        case cancelled
        case error(String)
    }

    /// A selected local audio file, read into memory for upload.
    struct Selection: Sendable {
        let name: String
        let bytes: Data
        let analysis: LocalMusicAnalysis?
    }

    // Selection state
    @Published var selection: Selection?
    @Published var instruments: [String] = []
    @Published var detectTempo: Bool = true

    // Flow state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastItem: LibraryItem?

    /// Factory-name source for the manifest.
    var sourceName: String {
        selection?.name ?? ""
    }

    private let api: any TranscribeServicing
    private let library: any LibraryStoring
    private let runner = JobRunner()

    private var cancellables = Set<AnyCancellable>()

    init(api: any TranscribeServicing, library: any LibraryStoring) {
        self.api = api
        self.library = library
        // Mirror JobRunner's published timings into this VM's published props.
        runner.$elapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.elapsed = $0 }
            .store(in: &cancellables)
    }

    var isRunning: Bool { phase == .running }
    var isBlocked: Bool { isRunning }

    nonisolated static func readSource(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumSourceBytes {
            throw SourceReadError.tooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        guard data.count <= maximumSourceBytes else {
            throw SourceReadError.tooLarge
        }
        return data
    }

    /// Set the source audio file. Ignored while a job is running.
    @discardableResult
    func select(name: String, bytes: Data, analysis: LocalMusicAnalysis? = nil) -> Bool {
        guard !isRunning else { return false }
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .audio),
              !type.conforms(to: .midi) else {
            selection = nil
            phase = .error("UNSUPPORTED AUDIO FILE")
            return false
        }
        guard !bytes.isEmpty else {
            selection = nil
            phase = .error("COULD NOT READ AUDIO FILE")
            return false
        }
        guard bytes.count <= Self.maximumSourceBytes else {
            selection = nil
            phase = .error("AUDIO FILE EXCEEDS 200 MB")
            return false
        }
        selection = Selection(name: name, bytes: bytes, analysis: analysis)
        phase = .idle
        return true
    }

    func rejectSource(_ error: SourceReadError) {
        guard !isRunning else { return }
        selection = nil
        switch error {
        case .tooLarge:
            phase = .error("AUDIO FILE EXCEEDS 200 MB")
        case .unreadable:
            phase = .error("COULD NOT READ AUDIO FILE")
        }
    }

    /// Clear the current selection.
    func clearSelection() {
        guard !isRunning else { return }
        selection = nil
    }

    /// Toggle an instrument in the multi-picker.
    func toggleInstrument(_ instrument: String) {
        guard !isRunning else { return }
        if instruments.contains(instrument) {
            instruments.removeAll(where: { $0 == instrument })
        } else {
            instruments.append(instrument)
        }
    }

    var hasSelection: Bool { selection != nil }

    /// Start transcription. Returns false (no-op) if already running or no
    /// audio file is selected.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        guard let selection else {
            phase = .error("SELECT AN AUDIO FILE")
            return false
        }

        let api = self.api
        let library = self.library
        let filename = selection.name
        let audio = selection.bytes
        let instruments = self.instruments
        let detectTempo = self.detectTempo
        let title = Self.title(from: filename)

        phase = .running
        lastItem = nil

        runner.start(JobRunner.Job(name: "transcribe") {
            do {
                let data = try await api.transcribe(
                    audio: audio,
                    filename: filename,
                    instruments: instruments,
                    detectTempo: detectTempo
                )
                let item = LibraryItem(
                    id: UUID(),
                    kind: .midi,
                    title: title,
                    createdAt: Date(),
                    promptOrSource: filename,
                    durationSeconds: nil,
                    relativePath: "midi/\(UUID().uuidString).mid"
                )
                try await MainActor.run { try library.add(item, bytes: data) }
                await MainActor.run { [item] in
                    self.lastItem = item
                    self.phase = .done
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .cancelled }
            } catch let urlError as URLError where urlError.code == .cancelled {
                await MainActor.run { self.phase = .cancelled }
            } catch {
                let message = (error as? MicromixAPIError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { self.phase = .error(message) }
            }
        })
        return true
    }

    /// Cancel the current transcription.
    func cancel() {
        runner.cancel()
        if phase == .running {
            phase = .cancelled
        }
    }

    private static func title(from filename: String) -> String {
        guard !filename.isEmpty else { return "TRANSCRIBED" }
        return filename
    }
}

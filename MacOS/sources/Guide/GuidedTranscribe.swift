import Foundation
import SwiftUI

/// Guided "TRANSCRIBE AND REMIX" run: transcribes the song to MIDI, keeps the
/// MIDI in the Library, then hands the original audio to Reimagine as a remix
/// source so both the notation and the new audio move forward together.
@MainActor
final class GuidedTranscribeModel: ObservableObject {
    enum Stage: String, CaseIterable, Identifiable {
        case transcribe = "TRANSCRIBE"

        var id: String { rawValue }
    }

    @Published var sourceURL: URL?
    @Published var detectTempo = false
    @Published private(set) var states: [Stage: GuidedStageState] = [:]
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var transcribedItem: LibraryItem?
    /// Set once the original audio was handed to Reimagine.
    @Published private(set) var deliveredSource: String?

    /// Called with the original source URL when transcription succeeds.
    var onDeliver: ((URL) -> Void)?

    private let api: any DurableTranscriptionSubmitting
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var runID: UUID?
    private var acceptedJobID: String?
    private var cancelRequested = false

    init(
        api: any DurableTranscriptionSubmitting,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.api = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
    }

    var canStart: Bool { !isRunning && sourceURL != nil }

    @discardableResult
    func start() -> Bool {
        guard canStart else {
            errorMessage = "SELECT AN AUDIO FILE"
            return false
        }
        guard task == nil else { return false }

        let sourceURL = self.sourceURL!
        let detectTempo = self.detectTempo
        let token = UUID()
        runID = token
        acceptedJobID = nil
        cancelRequested = false
        errorMessage = nil
        transcribedItem = nil
        deliveredSource = nil
        states = [.transcribe: .pending]
        isRunning = true
        startedAt = Date()
        elapsed = 0
        startTicker()

        let api = self.api
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
        task = Task { [weak self] in
            await self?.run(
                token: token, sourceURL: sourceURL, detectTempo: detectTempo,
                api: api, reattacher: reattacher, sourceReader: sourceReader
            )
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        task?.cancel()
        task = nil
        stopTicker()
        if let acceptedJobID, let cancelling = api as? any DurableJobCancelling {
            Task { try? await cancelling.cancel(jobID: acceptedJobID) }
        }
        if let running = Stage.allCases.first(where: { state(of: $0) == .running }) {
            set(running, .cancelled)
        }
        isRunning = false
    }

    func state(of stage: Stage) -> GuidedStageState {
        states[stage] ?? .pending
    }

    // MARK: - Run

    private func run(
        token: UUID,
        sourceURL: URL,
        detectTempo: Bool,
        api: any DurableTranscriptionSubmitting,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data
    ) async {
        do {
            set(.transcribe, .running)
            let data = try await Task.detached(priority: .userInitiated) {
                try sourceReader(sourceURL)
            }.value
            let job = try await api.submitTranscription(
                audio: data,
                filename: sourceURL.lastPathComponent,
                instruments: [],
                detectTempo: detectTempo
            )
            acceptedJobID = job.id
            try requireCurrent(token)
            try reattacher.track(job)
            let items = try await reattacher.recoverSubmittedJob(id: job.id)
            guard let item = items.first else {
                throw GuidedFlowError(description: "Transcription produced no MIDI")
            }
            transcribedItem = item
            set(.transcribe, .done)
            finish(token: token, sourceURL: sourceURL)
        } catch {
            handle(error, token: token)
        }
    }

    private func requireCurrent(_ token: UUID) throws {
        guard runID == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func finish(token: UUID, sourceURL: URL) {
        guard token == runID else { return }
        if let startedAt {
            elapsed = max(elapsed, Date().timeIntervalSince(startedAt))
        }
        stopTicker()
        task = nil
        isRunning = false
        deliveredSource = sourceURL.lastPathComponent
        runID = nil
        acceptedJobID = nil
        onDeliver?(sourceURL)
    }

    private func handle(_ error: Error, token: UUID) {
        guard token == runID else { return }
        stopTicker()
        task = nil
        isRunning = false
        if Self.isCancellation(error) || cancelRequested {
            if let running = Stage.allCases.first(where: { state(of: $0) == .running }) {
                set(running, .cancelled)
            }
        } else {
            let message = Self.message(for: error)
            if let running = Stage.allCases.first(where: { state(of: $0) == .running }) {
                set(running, .failed(message))
            }
            errorMessage = message
        }
        runID = nil
        acceptedJobID = nil
    }

    private func set(_ stage: Stage, _ state: GuidedStageState) {
        states[stage] = state
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let start = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func message(for error: Error) -> String {
        (error as? MicromixAPIError)?.errorDescription ?? error.localizedDescription
    }
}

/// TRANSCRIBE STUDIO tab: MIDI into the Library, then the original audio is
/// handed to Reimagine as a remix source.
struct GuidedTranscribeView: View {
    @ObservedObject var model: GuidedTranscribeModel
    var localInferenceAvailable = true
    var onOpenReimagine: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var midiPreview: MidiPreview? = nil
    var library: LocalLibrary? = nil
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeckPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Typography.monoLabel("ONE SONG IN — MIDI PLUS A REMIX START", size: 11)
                            .foregroundColor(Palette.ink)
                        Spacer()
                    }
                    Text("Transcribes every instrument to MIDI and saves it to Library, then opens Reimagine with the original audio loaded for a remix. The notation and the new audio move forward together.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.66))
                }
            }
            DeckPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Typography.monoLabel("SOURCE", size: 11)
                        Button(model.sourceURL?.lastPathComponent ?? "SELECT AUDIO") { isImporting = true }
                        Spacer()
                    }
                    .disabled(model.isRunning)
                    Toggle("STRICT TEMPO GRID — REJECTS UNSTEADY RECORDINGS", isOn: $model.detectTempo)
                        .toggleStyle(PanelToggleStyle())
                        .disabled(model.isRunning)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                PrimaryActionButton(
                    title: model.isRunning ? "TRANSCRIBING…" : "TRANSCRIBE & PREPARE REMIX",
                    isEnabled: model.canStart && localInferenceAvailable,
                    action: { model.start() }
                )
                if model.isRunning { Button("CANCEL", action: model.cancel) }
                Button("OPEN REIMAGINE", action: onOpenReimagine)
                Button("OPEN LIBRARY", action: onOpenLibrary)
            }
            stepper
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.accentRed)
            }
            if let item = model.transcribedItem {
                HStack(spacing: 8) {
                    if let midiPreview, let library {
                        InlineMidiButton(midiPreview: midiPreview, item: item, library: library)
                    }
                    Text("MIDI SAVED — \(item.title).")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.accentGreen)
                }
            }
            if let delivered = model.deliveredSource {
                Text("READY IN REIMAGINE — \(delivered). Adjust the direction and render there.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Palette.accentGreen)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { model.sourceURL = url }
        }
    }

    private var stepper: some View {
        DeckPanel {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Typography.monoLabel("PROGRESS", size: 10)
                        .foregroundColor(Palette.ink.opacity(0.64))
                    Spacer()
                    if model.isRunning {
                        Typography.monoLabel("\(Int(model.elapsed))s", size: 10)
                            .foregroundColor(Palette.accentBlue)
                    }
                }
                ForEach(GuidedTranscribeModel.Stage.allCases) { stage in
                    stageRow(stage)
                }
            }
        }
    }

    private func stageRow(_ stage: GuidedTranscribeModel.Stage) -> some View {
        let state = model.state(of: stage)
        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Self.color(for: state))
                .frame(width: 12)
            Typography.monoLabel(stage.rawValue, size: 10)
                .foregroundColor(Palette.ink.opacity(state == .pending ? 0.55 : 0.9))
            Spacer(minLength: 0)
            Typography.monoLabel(Self.statusText(for: state), size: 9)
                .foregroundColor(Self.color(for: state))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private static func statusText(for state: GuidedStageState) -> String {
        switch state {
        case .pending: "QUEUED"
        case .running: "RUNNING…"
        case .done: "DONE"
        case .skipped: "SKIPPED"
        case .failed(let message): "FAILED — \(message)"
        case .cancelled: "CANCELLED"
        }
    }

    private static func color(for state: GuidedStageState) -> Color {
        switch state {
        case .pending: Palette.ink.opacity(0.5)
        case .running: Palette.accentBlue
        case .done: Palette.accentGreen
        case .skipped: Palette.ink.opacity(0.42)
        case .failed: Palette.accentRed
        case .cancelled: Palette.ink.opacity(0.6)
        }
    }

    private static func symbol(for state: GuidedStageState) -> String {
        switch state {
        case .pending: "circle.dotted"
        case .running: "circle.dotted"
        case .done: "checkmark.circle"
        case .skipped: "circle.dashed"
        case .failed: "xmark.circle"
        case .cancelled: "minus.circle"
        }
    }
}
import Combine
import Foundation
import SwiftUI

/// Guided "VOCAL SWAP STUDIO" run: optionally isolates the vocal stem, then
/// converts the vocal to the selected private voice.
///
/// With "split first" on, a stem-split job isolates the vocal and its
/// registered output asset feeds the swap directly, so the vocal audio is
/// never re-uploaded. With it off, the source audio is swapped as-is. Every
/// output lands in the Library through durable recovery; this model only
/// tracks stage progress, cancellation, and errors.
@MainActor
final class GuidedVocalSwapModel: ObservableObject {
    enum Stage: String, CaseIterable, Identifiable {
        case prepare = "PREPARE"
        case splitVocals = "SPLIT VOCALS"
        case swapVoice = "SWAP VOICE"

        var id: String { rawValue }
    }

    @Published var sourceURL: URL?
    @Published var voiceModel = ""
    @Published var pitchShift = 0
    @Published var splitFirst = true
    @Published private(set) var states: [Stage: GuidedStageState] = [:]
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var accompaniment: LibraryItem?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false

    private let api: any DurableSourceProcessing
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var runID: UUID?
    private var acceptedJobID: String?
    private var cancelRequested = false

    init(
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.api = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
    }

    var canStart: Bool {
        !isRunning && sourceURL != nil
            && !voiceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (-24...24).contains(pitchShift)
    }

    @discardableResult
    func start() -> Bool {
        guard canStart else {
            if sourceURL == nil { errorMessage = "SELECT AN AUDIO FILE" }
            else if voiceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "SELECT A VOICE MODEL"
            } else { errorMessage = "PITCH MUST BE −24 TO 24" }
            return false
        }
        guard task == nil else { return false }

        let sourceURL = self.sourceURL!
        let voiceModel = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let pitchShift = self.pitchShift
        let splitFirst = self.splitFirst
        let token = UUID()
        runID = token
        acceptedJobID = nil
        cancelRequested = false
        results = []
        accompaniment = nil
        errorMessage = nil
        states = [:]
        isRunning = true
        startedAt = Date()
        elapsed = 0
        startTicker()

        let api = self.api
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
        task = Task { [weak self] in
            await self?.run(token: token, sourceURL: sourceURL, voiceModel: voiceModel,
                            pitchShift: pitchShift, splitFirst: splitFirst,
                            api: api, reattacher: reattacher, sourceReader: sourceReader)
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        task?.cancel()
        task = nil
        stopTicker()
        if let acceptedJobID {
            let api = self.api
            Task { try? await api.cancel(jobID: acceptedJobID) }
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
        voiceModel: String,
        pitchShift: Int,
        splitFirst: Bool,
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data
    ) async {
        do {
            try requireCurrent(token)
            set(.prepare, .running)
            let data = try await Task.detached(priority: .userInitiated) {
                try sourceReader(sourceURL)
            }.value
            try requireCurrent(token)
            let asset = try await api.uploadAsset(
                data: data,
                filename: sourceURL.lastPathComponent,
                mediaType: Self.mediaType(for: sourceURL)
            )
            try requireCurrent(token)
            set(.prepare, .done)

            var swapSource = asset.id
            var accompaniment: LibraryItem?
            if splitFirst {
                set(.splitVocals, .running)
                let split = try await submit(
                    .stemSplit(sourceAssetID: asset.id, description: "vocals"),
                    token: token, api: api, reattacher: reattacher
                )
                guard let vocal = split.first(where: { $0.provenance?.output.name == "target" }),
                      let vocalAssetID = vocal.remoteOutputAssetID else {
                    throw GuidedFlowError(description: "Stem split did not return a vocal stem")
                }
                accompaniment = split.first(where: { $0.provenance?.output.name == "residual" && $0.kind == .audio })
                set(.splitVocals, .done)
                swapSource = vocalAssetID
            } else {
                set(.splitVocals, .skipped)
            }

            set(.swapVoice, .running)
            let converted = try await submit(
                .vocalSwap(sourceAssetID: swapSource, voiceModel: voiceModel, pitchShift: pitchShift),
                token: token, api: api, reattacher: reattacher
            )
            set(.swapVoice, .done)
            succeed(token: token, results: converted, accompaniment: accompaniment)
        } catch {
            handle(error, token: token)
        }
    }

    /// Submit one durable job, remember it for cancellation, and block on
    /// recovery until its outputs are imported into the Library.
    private func submit(
        _ request: SourceProcessingRequest,
        token: UUID,
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching
    ) async throws -> [LibraryItem] {
        try requireCurrent(token)
        // The request must outlive cancellation so a late acceptance is observable.
        let job = try await Task { try await api.submitSourceProcessing(request) }.value
        guard runID == token, !Task.isCancelled else {
            // Keep recovery possible even if the cancellation request fails.
            defer { Task { try? await api.cancel(jobID: job.id) } }
            try reattacher.trackForBackground(job)
            throw CancellationError()
        }
        acceptedJobID = job.id
        try reattacher.track(job)
        let items = try await reattacher.recoverSubmittedJob(id: job.id)
        try requireCurrent(token)
        acceptedJobID = nil
        return items
    }

    private func requireCurrent(_ token: UUID) throws {
        guard runID == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func succeed(token: UUID, results: [LibraryItem], accompaniment: LibraryItem?) {
        guard token == runID else { return }
        if let startedAt {
            elapsed = max(elapsed, Date().timeIntervalSince(startedAt))
        }
        stopTicker()
        task = nil
        isRunning = false
        self.results = results
        self.accompaniment = accompaniment
        runID = nil
        acceptedJobID = nil
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

    private static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        default: "application/octet-stream"
        }
    }
}

/// VOCAL SWAP STUDIO tab: the guided vocal-swap stepper. Optional split, voice,
/// and pitch on top; live stage progress in the middle; results below.
struct GuidedVocalSwapView: View {
    @ObservedObject var model: GuidedVocalSwapModel
    var voices: [String] = []
    var localInferenceAvailable = true
    var modelStatuses: [String: String] = [:]
    var voiceCatalog: VoiceCatalogState? = nil
    var onRefreshVoices: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var library: LocalLibrary? = nil
    @State private var isImporting = false

    private var catalog: VoiceCatalogState {
        voiceCatalog ?? (localInferenceAvailable ? .loading : .unavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowReadinessView(connected: localInferenceAvailable, statuses: modelStatuses, models: model.splitFirst ? ["sam_audio", "mlx_rvc"] : ["mlx_rvc"])
            DeckPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Convert a performance to a new voice").font(Typography.heading)
                            .foregroundColor(Palette.ink)
                        Spacer()
                    }
                    Text("Optionally separates vocals first, then converts them to the selected private voice. Separation and conversion quality vary; lyrics may not remain intelligible. Import converted vocals and any available accompaniment into Logic as separate tracks; no mix is assembled here.")
                        .font(Typography.help)
                        .foregroundColor(Palette.ink.opacity(0.75))
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
                    Toggle("SPLIT VOCALS FIRST — ISOLATE THE STEM BEFORE SWAPPING", isOn: $model.splitFirst)
                        .toggleStyle(PanelToggleStyle())
                        .disabled(model.isRunning)
                    if !catalog.voices.isEmpty {
                        Picker("VOICE MODEL", selection: $model.voiceModel) {
                            Text("Select a voice").tag("")
                            ForEach(catalog.voices, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(model.isRunning)
                        Stepper("PITCH  \(model.pitchShift) SEMITONES", value: $model.pitchShift, in: -24...24)
                            .disabled(model.isRunning)
                    }
                    VoiceCatalogNotice(state: catalog, onRefresh: onRefreshVoices)
                        .disabled(model.isRunning)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                PrimaryActionButton(
                    title: model.isRunning ? "SWAPPING…" : "START VOCAL SWAP",
                    isEnabled: model.canStart && localInferenceAvailable && !WorkflowReadiness.hasConfirmedMissing(statuses: modelStatuses, models: model.splitFirst ? ["sam_audio", "mlx_rvc"] : ["mlx_rvc"]) && catalog.voices.contains(model.voiceModel),
                    action: { model.start() }
                )
                if model.isRunning { Button("CANCEL", action: model.cancel) }
                Button("OPEN LIBRARY", action: onOpenLibrary)
            }
            stepper
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.textRed)
            }
            if !model.results.isEmpty {
                Text(model.accompaniment == nil
                     ? "Converted output saved to Library. No accompaniment is available from this run; no mix was assembled."
                     : "Related tracks saved to Library. Import both into Logic as separate tracks and check alignment; no mix was assembled.")
                ForEach(model.results + (model.accompaniment.map { [$0] } ?? [])) { item in
                    HStack(alignment: .center, spacing: 8) {
                        Typography.monoLabel("\(item.id == model.accompaniment?.id ? "ACCOMPANIMENT" : "CONVERTED OUTPUT") — \(item.title)", size: 9)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        if item.kind == .audio, let library {
                            MiniWaveform(item: item, library: library)
                        }
                        if item.kind == .audio, let player, let library {
                            InlinePlayButton(player: player, item: item, library: library)
                        }
                        if let router {
                            NextActionsRow(router: router, item: item)
                        }
                    }
                }
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
                            .foregroundColor(Palette.textBlue)
                    }
                }
                ForEach(GuidedVocalSwapModel.Stage.allCases) { stage in
                    stageRow(stage)
                }
            }
        }
    }

    private func stageRow(_ stage: GuidedVocalSwapModel.Stage) -> some View {
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
        case .running: Palette.textBlue
        case .done: Palette.textGreen
        case .skipped: Palette.ink.opacity(0.42)
        case .failed: Palette.textRed
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

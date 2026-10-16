import Foundation
import SwiftUI

/// Guided "REMIX MY TRACK" run: prepares a Reimagine remix in one gesture.
///
/// Optionally splits the vocals first (remixing the instrumental stem instead
/// of the full mix), optionally reads BPM/key on-device, then hands the chosen
/// source and direction to Reimagine via the workflow router. The remix itself
/// stays in Reimagine because its direction (prompt, strength) is creative
/// input, not setup.
@MainActor
final class GuidedRemixModel: ObservableObject {
    enum Stage: String, CaseIterable, Identifiable {
        case splitVocals = "SPLIT VOCALS"
        case analyze = "ANALYZE"

        var id: String { rawValue }
    }

    @Published var sourceURL: URL?
    @Published var splitFirst = false
    @Published var analyzeFirst = true
    @Published private(set) var states: [Stage: GuidedStageState] = [:]
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    /// Set once the source was handed to Reimagine; names the prepared source.
    @Published private(set) var deliveredSource: String?
    /// The prepared source item (the split's instrumental residual) so the
    /// studio can audition it in place before jumping to Reimagine.
    @Published private(set) var deliveredItem: LibraryItem?

    /// Called with (source item if the split produced one, fallback URL,
    /// derived metadata) when the run finishes.
    var onDeliver: ((LibraryItem?, URL, DerivedMetadata?) -> Void)?

    private let api: any DurableSourceProcessing
    private let reattacher: any ReimagineJobReattaching
    private let sourceReader: @Sendable (URL) throws -> Data
    private let metadataReader: @Sendable (URL) async throws -> DerivedMetadata

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var runID: UUID?
    private var acceptedJobID: String?
    private var cancelRequested = false

    init(
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        metadataReader: @escaping @Sendable (URL) async throws -> DerivedMetadata = {
            DerivedMetadata(from: try await LocalMusicAnalyzer.analyze(url: $0))
        }
    ) {
        self.api = api
        self.reattacher = reattacher
        self.sourceReader = sourceReader
        self.metadataReader = metadataReader
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
        let splitFirst = self.splitFirst
        let analyzeFirst = self.analyzeFirst
        let token = UUID()
        runID = token
        acceptedJobID = nil
        cancelRequested = false
        errorMessage = nil
        deliveredSource = nil
        deliveredItem = nil
        states = [:]
        set(.splitVocals, splitFirst ? .pending : .skipped)
        set(.analyze, analyzeFirst ? .pending : .skipped)
        isRunning = true
        startedAt = Date()
        elapsed = 0
        startTicker()

        let api = self.api
        let reattacher = self.reattacher
        let sourceReader = self.sourceReader
        let metadataReader = self.metadataReader
        task = Task { [weak self] in
            await self?.run(
                token: token, sourceURL: sourceURL, splitFirst: splitFirst,
                analyzeFirst: analyzeFirst, api: api, reattacher: reattacher,
                sourceReader: sourceReader, metadataReader: metadataReader
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
        splitFirst: Bool,
        analyzeFirst: Bool,
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching,
        sourceReader: @escaping @Sendable (URL) throws -> Data,
        metadataReader: @escaping @Sendable (URL) async throws -> DerivedMetadata
    ) async {
        var item: LibraryItem?
        var derived: DerivedMetadata?
        do {
            if splitFirst {
                set(.splitVocals, .running)
                let data = try await Task.detached(priority: .userInitiated) {
                    try sourceReader(sourceURL)
                }.value
                let asset = try await api.uploadAsset(
                    data: data,
                    filename: sourceURL.lastPathComponent,
                    mediaType: Self.mediaType(for: sourceURL)
                )
                let split = try await submit(
                    .stemSplit(sourceAssetID: asset.id, description: "vocals"),
                    token: token, api: api, reattacher: reattacher
                )
                guard let residual = split.first(where: { $0.provenance?.output.name == "residual" }) else {
                    throw GuidedFlowError(description: "Stem split did not return an instrumental stem")
                }
                item = residual
                set(.splitVocals, .done)
            }

            if analyzeFirst {
                set(.analyze, .running)
                derived = try await metadataReader(sourceURL)
                try requireCurrent(token)
                set(.analyze, .done)
            }

            finish(token: token, item: item, sourceURL: sourceURL, derived: derived)
        } catch {
            handle(error, token: token)
        }
    }

    private func submit(
        _ request: SourceProcessingRequest,
        token: UUID,
        api: any DurableSourceProcessing,
        reattacher: any ReimagineJobReattaching
    ) async throws -> [LibraryItem] {
        let job = try await api.submitSourceProcessing(request)
        acceptedJobID = job.id
        try requireCurrent(token)
        try reattacher.track(job)
        return try await reattacher.recoverSubmittedJob(id: job.id)
    }

    private func requireCurrent(_ token: UUID) throws {
        guard runID == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func finish(token: UUID, item: LibraryItem?, sourceURL: URL, derived: DerivedMetadata?) {
        guard token == runID else { return }
        if let startedAt {
            elapsed = max(elapsed, Date().timeIntervalSince(startedAt))
        }
        stopTicker()
        task = nil
        isRunning = false
        deliveredSource = item?.title ?? sourceURL.lastPathComponent
        deliveredItem = item
        runID = nil
        acceptedJobID = nil
        onDeliver?(item, sourceURL, derived)
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

/// REMIX STUDIO tab: optional vocal split and analysis, then a handoff to
/// Reimagine with the source and musical direction pre-filled.
struct GuidedRemixView: View {
    @ObservedObject var model: GuidedRemixModel
    var localInferenceAvailable = true
    var onOpenReimagine: () -> Void = {}
    var player: AudioPlayer? = nil
    var library: LocalLibrary? = nil
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeckPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Typography.monoLabel("ONE SONG IN — READY TO REMIX", size: 11)
                            .foregroundColor(Palette.ink)
                        Spacer()
                    }
                    Text("Prepares the remix in Reimagine: optionally splits the vocals first so you remix the instrumental, reads BPM and key on-device, then opens Reimagine with everything pre-filled. The remix direction stays yours.")
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
                    Toggle("SPLIT VOCALS FIRST — REMIX THE INSTRUMENTAL", isOn: $model.splitFirst)
                        .toggleStyle(PanelToggleStyle())
                        .disabled(model.isRunning)
                    Toggle("ANALYZE BPM / KEY", isOn: $model.analyzeFirst)
                        .toggleStyle(PanelToggleStyle())
                        .disabled(model.isRunning)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                PrimaryActionButton(
                    title: model.isRunning ? "PREPARING…" : "PREPARE REMIX",
                    isEnabled: model.canStart && localInferenceAvailable,
                    action: { model.start() }
                )
                if model.isRunning { Button("CANCEL", action: model.cancel) }
                Button("OPEN REIMAGINE", action: onOpenReimagine)
            }
            stepper
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.accentRed)
            }
            if let delivered = model.deliveredSource {
                HStack(spacing: 8) {
                    if let item = model.deliveredItem, let player, let library {
                        InlinePlayButton(player: player, item: item, library: library)
                    }
                    Text("READY IN REIMAGINE — \(delivered). Adjust the direction and render there.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.accentGreen)
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
                            .foregroundColor(Palette.accentBlue)
                    }
                }
                ForEach(GuidedRemixModel.Stage.allCases) { stage in
                    stageRow(stage)
                }
            }
        }
    }

    private func stageRow(_ stage: GuidedRemixModel.Stage) -> some View {
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
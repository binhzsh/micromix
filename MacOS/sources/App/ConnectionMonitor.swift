import Foundation
import Combine

/// Polls `MicromixAPI.health()` every 15 s (and on demand) and publishes a
/// connection snapshot the UI uses to drive the connection LED and to disable
/// GENERATE/TRANSCRIBE while local inference is unavailable.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published var connected: Bool = false
    @Published private(set) var modelStatuses: [String: String] = [:]
    @Published var lastError: String?
    /// Instruments for the transcribe picker, fetched at launch / refresh.
    @Published private(set) var instruments: [String] = []
    @Published private(set) var vocalModels: [String] = []
    private enum CapabilitiesState { case loading, loaded, failed }
    @Published private var capabilitiesState: CapabilitiesState = .loading

    var instrumentCatalog: VoiceCatalogState {
        guard isConnected else { return .unavailable }
        switch capabilitiesState {
        case .loading: return .loading
        case .failed: return .failed
        case .loaded: return .loaded(instruments)
        }
    }

    var voiceCatalog: VoiceCatalogState {
        guard isConnected else { return .unavailable }
        switch capabilitiesState {
        case .loading: return .loading
        case .failed: return .failed
        case .loaded: return .loaded(vocalModels)
        }
    }

    /// Poll interval per the design spec.
    static let pollInterval: TimeInterval = 15

    private let api: MicromixAPI
    private var poller: Task<Void, Never>?
    private var healthGeneration = 0
    private var capabilitiesGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init(api: MicromixAPI) {
        self.api = api
    }

    /// Start the periodic poller (idempotent).
    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self else { return }
                await refresh()
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    /// Load the instrument list from `/v1/capabilities` (best-effort; the picker
    /// degrades to an empty state if local inference is unavailable).
    func refreshInstruments() async {
        capabilitiesGeneration += 1
        let generation = capabilitiesGeneration
        capabilitiesState = .loading
        do {
            let capabilities = try await api.capabilities()
            guard generation == capabilitiesGeneration else { return }
            instruments = capabilities.transcriptionInstruments
            vocalModels = capabilities.vocalModels
            capabilitiesState = .loaded
        } catch {
            guard generation == capabilitiesGeneration else { return }
            instruments = []
            vocalModels = []
            capabilitiesState = .failed
        }
    }

    /// Perform one immediate health check.
    func refresh() async {
        healthGeneration += 1
        let generation = healthGeneration
        do {
            let health = try await api.health()
            guard generation == healthGeneration else { return }
            let wasConnected = connected
            let isReady = health.status == "ready"
            if !isReady || !wasConnected {
                capabilitiesGeneration += 1
                capabilitiesState = .loading
            }
            connected = isReady
            modelStatuses = health.models
            lastError = connected ? nil : "Local inference is \(health.status)"
            if connected { await refreshInstruments() }
        } catch {
            guard generation == healthGeneration else { return }
            capabilitiesGeneration += 1
            capabilitiesState = .loading
            connected = false
            modelStatuses = [:]
            let message = (error as? MicromixAPIError)?.errorDescription
                ?? error.localizedDescription
            lastError = message
        }
    }

    var isConnected: Bool { connected }
}

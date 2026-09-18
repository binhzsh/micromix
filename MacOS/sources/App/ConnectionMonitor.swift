import Foundation
import Combine

/// Polls `MicromixAPI.health()` every 15 s (and on demand) and publishes a
/// connection snapshot the UI uses to drive the connection LED and to disable
/// GENERATE/TRANSCRIBE while the server is unreachable.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published var connected: Bool = false
    @Published private(set) var modelStatuses: [String: String] = [:]
    @Published var lastError: String?
    /// Instruments for the transcribe picker, fetched at launch / refresh.
    @Published private(set) var instruments: [String] = []

    /// Poll interval per the design spec.
    static let pollInterval: TimeInterval = 15

    private let api: MicromixAPI
    private var poller: Task<Void, Never>?
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
    /// degrades to an empty state if the server is down).
    func refreshInstruments() async {
        do {
            instruments = try await api.instruments()
        } catch {
            instruments = []
        }
    }

    /// Perform one immediate health check.
    func refresh() async {
        do {
            let health = try await api.health()
            connected = health.status == "ready"
            modelStatuses = health.models
            lastError = connected ? nil : "Local inference is \(health.status)"
        } catch {
            connected = false
            modelStatuses = [:]
            let message = (error as? MicromixAPIError)?.errorDescription
                ?? error.localizedDescription
            lastError = message
        }
    }

    var isConnected: Bool { connected }
}

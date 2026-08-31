import Foundation
import Combine

/// Polls `MicromixAPI.health()` every 15 s (and on demand) and publishes a
/// connection snapshot the UI uses to drive the connection LED and to disable
/// GENERATE/TRANSCRIBE while the server is unreachable.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published var connected: Bool = false
    @Published private(set) var aceStepOK: Bool = false
    @Published private(set) var muscriptorOK: Bool = false
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

    /// Load the instrument list from `/instruments` (best-effort; the picker
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
            connected = true
            aceStepOK = health.workers.aceStep.status != "unreachable"
            muscriptorOK = health.workers.muscriptor.status != "unreachable"
            lastError = nil
        } catch {
            connected = false
            aceStepOK = false
            muscriptorOK = false
            let message = (error as? MicromixAPIError)?.errorDescription
                ?? error.localizedDescription
            lastError = message
        }
    }

    var isConnected: Bool { connected }
}

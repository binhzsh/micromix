import Foundation

/// A failed catalog is not an empty catalog and neither implies ready weights.
enum GenerationCatalogState: Equatable, Sendable {
    case unavailable
    case loading
    case failed
    case loaded([GenerationPreset])

    func preset(id: String) -> GenerationPreset? {
        guard case .loaded(let presets) = self else { return nil }
        return presets.first { $0.id == id }
    }

    func presets(for operation: String) -> [GenerationPreset] {
        guard case .loaded(let presets) = self else { return [] }
        return presets.filter { $0.supportedOperations.contains(operation) }
    }

    func selectionIssue(id: String, operation: String) -> String? {
        switch self {
        case .unavailable: return "Local inference is unavailable. Start the local sidecar and retry."
        case .loading: return "Loading engine capabilities…"
        case .failed: return "Engine capabilities could not be loaded. Refresh the engine connection and retry."
        case .loaded(let presets):
            if presets.isEmpty { return "No generation engines are advertised by the local sidecar." }
            guard let preset = preset(id: id) else { return "The selected engine is no longer advertised. Choose an available engine; your settings were kept." }
            guard preset.supportedOperations.contains(operation) else { return "\(preset.label) does not support this operation. Choose a supported engine." }
            return nil
        }
    }
}

extension ReimagineOperation {
    var capabilityOperation: String {
        switch self {
        case .reference: "reference-generation"
        case .remix: "remix"
        case .repaint: "repaint"
        }
    }
}

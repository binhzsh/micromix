import SwiftUI

/// Health markers describe installed components, not successful model loading or inference.
struct WorkflowReadiness {
    static func hasConfirmedMissing(statuses: [String: String], models: [String]) -> Bool {
        models.contains { model in
            switch statuses[model] {
            case "weights_missing": return ["muscriptor", "whisper", "minimax_music3", "mlx_rvc", "sam_audio"].contains(model)
            case "unavailable": return ["ace_step", "muscriptor", "whisper"].contains(model)
            default: return false
            }
        }
    }

    static func description(connected: Bool, statuses: [String: String], models: [String]) -> String {
        guard !models.isEmpty else { return "No inference model is required for this preparation step; the studio currently requires an engine connection." }
        guard connected else { return "Local inference is unavailable. Local Library, playback and on-device Analyze remain available." }
        let details = models.map { model in
            let name: String
            switch model {
            case "ace_step": name = "ACE-Step"
            case "minimax_music3": name = "MiniMax Music"
            case "muscriptor": name = "Muscriptor MIDI"
            case "whisper": name = "Whisper lyrics"
            case "mlx_rvc": name = "Voice conversion"
            case "sam_audio": name = "Stem separation"
            default: name = model
            }
            switch statuses[model] {
            case "ready": return "\(name): components detected"
            case "weights_missing" where model == "ace_step": return "\(name): some preset or planner weights missing; selected preset status unknown"
            case "weights_missing": return "\(name): weights missing"
            case "unavailable" where ["minimax_music3", "mlx_rvc", "sam_audio"].contains(model): return "\(name): shared MLX runtime check failed; this engine's status is unknown"
            case "unavailable": return "\(name): runtime unavailable"
            default: return "\(name): prerequisite status unknown"
            }
        }
        let missing = hasConfirmedMissing(statuses: statuses, models: models)
        return details.joined(separator: "; ") + (missing ? ". Submission is disabled; see services/local-inference/MODELS.md for local setup." : ".") + " Markers do not verify model loading, inference or output quality."
    }

    static func generationModel(preset: String) -> String {
        switch preset {
        case "turbo", "quality": return "ace_step"
        case "minimax-cover": return "minimax_music3"
        default: return "Unknown preset (\(preset))"
        }
    }
}

struct WorkflowReadinessView: View {
    let connected: Bool
    let statuses: [String: String]
    let models: [String]

    var body: some View {
        Text(WorkflowReadiness.description(connected: connected, statuses: statuses, models: models))
            .font(Typography.help)
            .foregroundColor(Palette.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

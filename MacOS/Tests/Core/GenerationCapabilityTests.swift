import Foundation
import Testing
@testable import Micromix

@Suite("Generation capability routing")
struct GenerationCapabilityTests {
    private func decode(_ json: String) throws -> GenerationPreset {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GenerationPreset.self, from: Data(json.utf8))
    }

    @Test("modern declarations override known legacy assumptions")
    func explicitCapabilities() throws {
        let preset = try decode(#"{"id":"turbo","label":"Restricted","model":"local","inference_steps":8,"operations":["generation"],"max_duration_seconds":25,"max_variations":1,"musical_metadata":false,"health_model":"selected_turbo"}"#)
        #expect(preset.supportedOperations == ["generation"])
        #expect(preset.durationLimit == 25)
        #expect(preset.variationLimit == 1)
        #expect(!preset.supportsMusicalMetadata)
        #expect(preset.readinessModel == "selected_turbo")
        #expect(preset.settingsIssue(operation: "remix", duration: nil, variations: 1, hasMetadata: false) != nil)
        #expect(preset.settingsIssue(operation: "generation", duration: 30, variations: 1, hasMetadata: false)?.contains("25 seconds") == true)
        #expect(preset.settingsIssue(operation: "generation", duration: 20, variations: 2, hasMetadata: false) != nil)
        #expect(preset.settingsIssue(operation: "generation", duration: 20, variations: 1, hasMetadata: true) != nil)
        #expect(preset.settingsIssue(operation: "generation", duration: 20, variations: 1, hasMetadata: false) == nil)
        let catalog = GenerationCatalogState.loaded([preset])
        #expect(WorkflowReadiness.generationModel(preset: "turbo", catalog: catalog) == "selected_turbo")
        #expect(WorkflowReadiness.hasConfirmedMissing(statuses: [preset.readinessModel: "weights_missing"], models: [preset.readinessModel]))
        #expect(WorkflowReadiness.hasConfirmedMissing(statuses: [preset.readinessModel: "unavailable"], models: [preset.readinessModel]))
    }

    @Test("old known presets have bounded compatibility; unknown models fail closed")
    func legacyAndUnknown() throws {
        let turbo = try decode(#"{"id":"turbo","label":"Turbo","model":"old","inference_steps":8}"#)
        #expect(turbo.supportedOperations.contains("remix"))
        #expect(turbo.variationLimit == 4)
        #expect(turbo.supportsMusicalMetadata)
        let minimax = try decode(#"{"id":"minimax-cover","label":"MiniMax","model":"old","inference_steps":30}"#)
        #expect(minimax.supportedOperations == ["generation"])
        #expect(minimax.durationLimit == 360)
        #expect(!minimax.supportsMusicalMetadata)
        let unknown = try decode(#"{"id":"new","label":"New","model":"new","inference_steps":8}"#)
        #expect(unknown.supportedOperations.isEmpty)
        #expect(unknown.settingsIssue(operation: "generation", duration: 30, variations: 1, hasMetadata: false) != nil)
        let disabled = try decode(#"{"id":"turbo","label":"Disabled","model":"old","inference_steps":8,"operations":[]}"#)
        #expect(disabled.supportedOperations.isEmpty)
        let partial = try decode(#"{"id":"turbo","label":"Partial","model":"old","inference_steps":8,"operations":["generation"]}"#)
        #expect(!partial.supportsMusicalMetadata)
        #expect(partial.variationLimit == 0)
        #expect(partial.settingsIssue(operation: "generation", duration: 30, variations: 1, hasMetadata: false)?.contains("incomplete") == true)
    }

    @Test("catalog states and operation filtering never substitute an engine")
    func catalogStates() {
        for state in [GenerationCatalogState.unavailable, .loading, .failed, .loaded([])] {
            #expect(state.presets(for: "generation").isEmpty)
            #expect(state.selectionIssue(id: "turbo", operation: "generation") != nil)
        }
        let catalog = GenerationCatalogState.loaded(GenerationPreset.legacyPresets)
        #expect(catalog.presets(for: "generation").count == 3)
        #expect(catalog.presets(for: "remix").map(\.id) == ["turbo", "quality"])
        #expect(catalog.selectionIssue(id: "minimax-cover", operation: "remix") != nil)
        #expect(catalog.selectionIssue(id: "missing", operation: "generation")?.contains("settings were kept") == true)
        #expect(ReimagineOperation.reference.capabilityOperation == "reference-generation")
    }
}

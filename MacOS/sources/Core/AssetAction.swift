import Foundation

/// Actions that can be performed on an audio/MIDI asset to chain workflows.
/// Each action knows how to route to its target workspace with pre-filled context.
enum AssetAction: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }
    /// Send to Reimagine as reference audio for generation
    case referenceGenerate
    /// Send to Reimagine for remix/cover operation
    case remix
    /// Send to Reimagine for repaint operation
    case repaint
    /// Send to Stem Split for source separation
    case stemSplit
    /// Send to Vocal Swap for voice conversion (requires vocal stem)
    case vocalSwap
    /// Send to Transcribe for MIDI conversion
    case transcribe
    /// Send to Analyze for BPM/key detection
    case analyze
    
    var label: String {
        switch self {
        case .referenceGenerate: return "USE AS REFERENCE"
        case .remix: return "REMIX"
        case .repaint: return "REPAINT"
        case .stemSplit: return "SPLIT STEMS"
        case .vocalSwap: return "SWAP VOICE"
        case .transcribe: return "TRANSCRIBE"
        case .analyze: return "ANALYZE"
        }
    }
    
    var icon: String {
        switch self {
        case .referenceGenerate: return "arrow.triangle.2.circlepath"
        case .remix: return "wand.and.stars"
        case .repaint: return "paintbrush"
        case .stemSplit: return "square.split.2x1"
        case .vocalSwap: return "person.wave.2"
        case .transcribe: return "music.note"
        case .analyze: return "waveform"
        }
    }
    
    /// The target workspace mode for this action
    var targetMode: DeviceMode {
        switch self {
        case .referenceGenerate, .remix, .repaint:
            return .reimagine
        case .stemSplit:
            return .stemSplit
        case .vocalSwap:
            return .vocalSwap
        case .transcribe:
            return .transcribe
        case .analyze:
            return .analyze
        }
    }
    
    /// Whether this action requires a specific source type
    var requiresAudio: Bool {
        switch self {
        case .transcribe:
            // MIDI cannot be transcribed
            return true
        case .referenceGenerate, .remix, .repaint, .stemSplit, .vocalSwap, .analyze:
            return true
        }
    }
    
    /// Available actions for a given asset kind
    static func available(for kind: LibraryItemKind) -> [AssetAction] {
        switch kind {
        case .audio:
            return allCases
        case .midi:
            // MIDI files can only be analyzed (for metadata) or used as reference
            // (if we add MIDI-to-audio generation in future)
            return [.analyze]
        }
    }
}

/// Context passed when routing to a workspace with a source asset
struct AssetActionContext: Sendable {
    let sourceItem: LibraryItem
    let sourceURL: URL  // Resolved file URL from LocalLibrary
    let action: AssetAction
    /// Optional pre-filled values derived from source analysis
    let derivedMetadata: DerivedMetadata?
    
    init(sourceItem: LibraryItem, sourceURL: URL, action: AssetAction, derivedMetadata: DerivedMetadata? = nil) {
        self.sourceItem = sourceItem
        self.sourceURL = sourceURL
        self.action = action
        self.derivedMetadata = derivedMetadata
    }
}

/// Metadata that can be derived from one operation and pre-filled into another
struct DerivedMetadata: Sendable {
    let beatsPerMinute: Double?
    let key: String?
    let timeSignature: String?
    let detectedLanguage: VocalLanguage?
    
    init(
        beatsPerMinute: Double? = nil,
        key: String? = nil,
        timeSignature: String? = nil,
        detectedLanguage: VocalLanguage? = nil
    ) {
        self.beatsPerMinute = beatsPerMinute
        self.key = key
        self.timeSignature = timeSignature
        self.detectedLanguage = detectedLanguage
    }
    
    static let empty = DerivedMetadata()
}

/// Protocol for view models that can accept a source asset for chaining
@MainActor
protocol AssetAccepting: AnyObject {
    /// Called when navigating to this workspace with a source asset
    /// Should pre-fill UI state but NOT start the job
    func acceptSource(_ context: AssetActionContext)
    
    /// Whether this VM is currently able to accept a new source
    var canAcceptSource: Bool { get }
}

/// Central router for workflow chaining
@MainActor
final class WorkflowRouter: ObservableObject {
    private weak var generate: GenerateViewModel?
    private weak var reimagine: ReimagineViewModel?
    private weak var transcribe: TranscribeViewModel?
    private weak var vocalSwap: SourceProcessingViewModel?
    private weak var stemSplit: SourceProcessingViewModel?
    private weak var analyze: AnalyzeViewModel?
    private let library: LocalLibrary

    /// Callback to switch the active device mode
    var onSwitchMode: ((DeviceMode) -> Void)?

    init(
        library: LocalLibrary,
        generate: GenerateViewModel? = nil,
        reimagine: ReimagineViewModel? = nil,
        transcribe: TranscribeViewModel? = nil,
        vocalSwap: SourceProcessingViewModel? = nil,
        stemSplit: SourceProcessingViewModel? = nil,
        analyze: AnalyzeViewModel? = nil
    ) {
        self.library = library
        self.generate = generate
        self.reimagine = reimagine
        self.transcribe = transcribe
        self.vocalSwap = vocalSwap
        self.stemSplit = stemSplit
        self.analyze = analyze
    }

    /// Execute an action on a source asset
    func execute(_ action: AssetAction, on item: LibraryItem, derived: DerivedMetadata? = nil) {
        let sourceURL = library.resolvedURL(for: item)
        let context = AssetActionContext(
            sourceItem: item,
            sourceURL: sourceURL,
            action: action,
            derivedMetadata: derived
        )
        let targetMode = action.targetMode

        // Switch to target mode first
        onSwitchMode?(targetMode)

        // Then deliver the context to the appropriate VM
        switch action {
        case .referenceGenerate:
            reimagine?.acceptSource(context)
        case .remix:
            reimagine?.acceptSource(context)
        case .repaint:
            reimagine?.acceptSource(context)
        case .stemSplit:
            stemSplit?.acceptSource(context)
        case .vocalSwap:
            vocalSwap?.acceptSource(context)
        case .transcribe:
            transcribe?.acceptSource(context)
        case .analyze:
            analyze?.acceptSource(context)
        }
    }

    /// Get available actions for a library item
    func availableActions(for item: LibraryItem) -> [AssetAction] {
        AssetAction.available(for: item.kind)
    }
}

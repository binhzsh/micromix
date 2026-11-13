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
        case .lyrics:
            return []
        case .midi:
            // MIDI files can only be analyzed (for metadata) or used as reference
            // (if we add MIDI-to-audio generation in future)
            return [.analyze]
        }
    }
}

/// Context passed when routing to a workspace with a source asset
struct AssetActionContext: Sendable {
    let sourceItem: LibraryItem?
    let sourceURL: URL  // Resolved file URL from LocalLibrary
    let action: AssetAction
    /// Optional pre-filled values derived from source analysis
    let derivedMetadata: DerivedMetadata?
    
    init(sourceItem: LibraryItem? = nil, sourceURL: URL, action: AssetAction, derivedMetadata: DerivedMetadata? = nil) {
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
    let durationSeconds: Double?

    init(
        beatsPerMinute: Double? = nil,
        key: String? = nil,
        timeSignature: String? = nil,
        detectedLanguage: VocalLanguage? = nil,
        durationSeconds: Double? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.beatsPerMinute = beatsPerMinute
        self.key = key
        self.timeSignature = timeSignature
        self.detectedLanguage = detectedLanguage
    }
    
    static let empty = DerivedMetadata()
    
    /// Musical direction learned by the on-device analyzer.
    init(from analysis: LocalMusicAnalysis) {
        self.init(
            beatsPerMinute: analysis.beatsPerMinute,
            key: analysis.key,
            durationSeconds: analysis.durationSeconds
        )
    }
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

    @Published var handoffError: HandoffError?

    struct HandoffError: Identifiable, Error {
        let id = UUID()
        let message: String
    }

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
    @discardableResult
    func execute(_ action: AssetAction, on item: LibraryItem, derived: DerivedMetadata? = nil) -> Result<Void, HandoffError> {
        guard AssetAction.available(for: item.kind).contains(action) else {
            let error = HandoffError(message: "This action is not available for the selected item. Choose a compatible source.")
            handoffError = error
            return .failure(error)
        }
        let context = AssetActionContext(
            sourceItem: item, sourceURL: library.resolvedURL(for: item),
            action: action, derivedMetadata: derived
        )
        let receiver: (any AssetAccepting)?
        switch action {
        case .referenceGenerate, .remix, .repaint: receiver = reimagine
        case .stemSplit: receiver = stemSplit
        case .vocalSwap: receiver = vocalSwap
        case .transcribe: receiver = transcribe
        case .analyze: receiver = analyze
        }
        return handoff(context, to: receiver, mode: action.targetMode)
    }

    /// A receiver acknowledges a handoff synchronously; it may load the source
    /// asynchronously and report subsequent read errors in its own workspace.
    @discardableResult
    func handoff(_ context: AssetActionContext, to receiver: (any AssetAccepting)?, mode: DeviceMode, requiresFile: Bool = true) -> Result<Void, HandoffError> {
        guard let receiver else {
            let error = HandoffError(message: "\(mode.rawValue) is unavailable. Try again after reopening the app.")
            handoffError = error
            return .failure(error)
        }
        guard receiver.canAcceptSource else {
            let error = HandoffError(message: "\(mode.rawValue) is busy. Wait for or cancel its current work, then try again.")
            handoffError = error
            return .failure(error)
        }
        if requiresFile {
            var isDirectory: ObjCBool = false
            let path = context.sourceURL.path
            guard context.sourceURL.isFileURL,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
                let error = HandoffError(message: "The source file is missing or unreadable. Restore it or choose another source, then try again.")
                handoffError = error
                return .failure(error)
            }
        }
        handoffError = nil
        receiver.acceptSource(context)
        onSwitchMode?(mode)
        return .success(())
    }

    /// Explicitly replace only Generate's lyrics, leaving its prompt and language intact.
    @discardableResult
    func useGenerateLyrics(_ text: String) -> Result<Void, HandoffError> {
        guard let generate else {
            let error = HandoffError(message: "Generate is unavailable. Try again after reopening the app.")
            handoffError = error
            return .failure(error)
        }
        guard generate.canAcceptSource else {
            let error = HandoffError(message: "Generate is busy. Wait for or cancel its current work, then try again.")
            handoffError = error
            return .failure(error)
        }
        generate.lyrics = text
        generate.useLyrics = true
        handoffError = nil
        onSwitchMode?(.generate)
        return .success(())
    }

    /// Get available actions for a library item
    func availableActions(for item: LibraryItem) -> [AssetAction] {
        AssetAction.available(for: item.kind)
    }
    
    /// Route an analyzed file into Reimagine reference generation with its
    /// derived BPM/key pre-filled. The source has no LibraryItem yet, so the
    /// context carries the resolved URL only.
    func reimagineReference(url: URL, derived: DerivedMetadata? = nil) {
        let context = AssetActionContext(
            sourceURL: url,
            action: .referenceGenerate,
            derivedMetadata: derived
        )
        handoff(context, to: reimagine, mode: .reimagine)
    }

    /// Route an audio file into Reimagine remix with optional derived metadata
    /// pre-filled; the source has no LibraryItem yet.
    @discardableResult
    func reimagineRemix(url: URL, derived: DerivedMetadata? = nil) -> Result<Void, HandoffError> {
        let context = AssetActionContext(
            sourceURL: url,
            action: .remix,
            derivedMetadata: derived
        )
        return handoff(context, to: reimagine, mode: .reimagine)
    }
    
    /// Pre-fill Generate's musical direction from an analysis without a source
    /// file; text-to-music generation takes no audio reference.
    func prefillGenerate(with derived: DerivedMetadata) {
        let context = AssetActionContext(
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            action: .referenceGenerate,
            derivedMetadata: derived
        )
        handoff(context, to: generate, mode: .generate, requiresFile: false)
    }
}

import SwiftUI

/// End-to-end workflow guide shown from the GUIDE deck button.
///
/// Static walkthroughs explain the flows; the COVER STUDIO tab actually runs
/// the guided AI-cover chain (source → stem split → vocal swap) through its
/// own view model.
struct WorkflowGuideView: View {
    @Binding var mode: DeviceMode
    @Binding var tab: GuideTab
    var cover: GuidedCoverModel? = nil
    var remix: GuidedRemixModel? = nil
    var transcribeStudio: GuidedTranscribeModel? = nil
    var vocalSwapStudio: GuidedVocalSwapModel? = nil
    var voices: [String] = []
    var instruments: [String] = []
    var localInferenceAvailable = true
    var modelStatuses: [String: String] = [:]
    var voiceCatalog: VoiceCatalogState? = nil
    var onRefreshVoices: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var onOpenReimagine: () -> Void = {}
    var router: WorkflowRouter? = nil
    var player: AudioPlayer? = nil
    var midiPreview: MidiPreview? = nil
    var library: LocalLibrary? = nil

    enum GuideTab: String, CaseIterable, Identifiable {
        case cover = "AI COVER"
        case reimagine = "REIMAGINE"
        case fromScratch = "FROM SCRATCH"
        case studio = "COVER STUDIO"
        case remixStudio = "REMIX STUDIO"
        case transcribeStudio = "TRANSCRIBE STUDIO"
        case vocalSwapStudio = "VOCAL SWAP STUDIO"

        var id: String { rawValue }
        var isWalkthrough: Bool {
            switch self {
            case .cover, .reimagine, .fromScratch: true
            default: false
            }
        }
        var kindDescription: String {
            isWalkthrough ? "Walkthrough — instructions and links; steps run separately." : "Guided studio — run the available steps here."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Guide destination", selection: $tab) {
                Section("Walkthroughs") {
                    ForEach([GuideTab.cover, .reimagine, .fromScratch]) { entry in
                        Text(entry.rawValue).tag(entry)
                    }
                }
                Section("Executable studios") {
                    ForEach([GuideTab.studio, .remixStudio, .transcribeStudio, .vocalSwapStudio]) { entry in
                        Text(entry.rawValue).tag(entry)
                    }
                }
            }
            .pickerStyle(.menu)

            Text(tab.kindDescription)
                .font(Typography.help)
                .foregroundColor(Palette.ink.opacity(0.72))

            if let models = requiredModels {
                WorkflowReadinessView(connected: localInferenceAvailable, statuses: modelStatuses, models: models)
            }

            Group {
                switch tab {
                case .cover: coverFlow
                case .reimagine: reimagineFlow
                case .fromScratch: fromScratchFlow
                case .studio:
                    if let cover {
                        GuidedCoverView(
                            model: cover,
                            voices: voices,
                            localInferenceAvailable: localInferenceAvailable,
                            modelStatuses: modelStatuses,
                            voiceCatalog: voiceCatalog,
                            onRefreshVoices: onRefreshVoices,
                            onOpenLibrary: onOpenLibrary,
                            router: router,
                            player: player,
                            library: library
                        )
                    }
                case .remixStudio:
                    if let remix {
                        GuidedRemixView(
                            model: remix,
                            localInferenceAvailable: localInferenceAvailable,
                            modelStatuses: modelStatuses,
                            onOpenReimagine: onOpenReimagine,
                            player: player,
                            library: library
                        )
                    }
                case .transcribeStudio:
                    if let transcribeStudio {
                        GuidedTranscribeView(
                            model: transcribeStudio,
                            localInferenceAvailable: localInferenceAvailable,
                            modelStatuses: modelStatuses,
                            instruments: instruments,
                            onOpenReimagine: onOpenReimagine,
                            onOpenLibrary: onOpenLibrary,
                            midiPreview: midiPreview,
                            library: library
                        )
                    }
                case .vocalSwapStudio:
                    if let vocalSwapStudio {
                        GuidedVocalSwapView(
                            model: vocalSwapStudio,
                            voices: voices,
                            localInferenceAvailable: localInferenceAvailable,
                            modelStatuses: modelStatuses,
                            voiceCatalog: voiceCatalog,
                            onRefreshVoices: onRefreshVoices,
                            onOpenLibrary: onOpenLibrary,
                            router: router,
                            player: player,
                            library: library
                        )
                    }
                }
            }
        }
    }

    private var requiredModels: [String]? {
        switch tab {
        case .studio: return ["sam_audio", "mlx_rvc"]
        case .transcribeStudio: return ["muscriptor"]
        default: return nil
        }
    }

    // MARK: - AI Cover walkthrough

    private var coverFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideIntro(
                title: "Make an AI cover",
                detail: "Try creating a new version with different vocals and style. Results vary; everything runs locally on this Mac."
            )

            GuideStep(
                number: 1,
                title: "Get the vocals out of the song",
                detail: "Load the original song in STEM SPLIT and describe what to keep — for example “vocals”. The result may include a vocal track and accompaniment; separation quality varies."
            ) {
                ModeChip(title: "STEM SPLIT") { mode = .stemSplit }
            }

            GuideStep(
                number: 2,
                title: "Sing it in a different voice",
                detail: "Load the vocal track in VOCAL SWAP, pick a voice model, adjust the pitch offset if needed, and render.\nConversion attempts to change the voice while retaining the performance; lyrics and intelligibility may change, so listen and check the result."
            ) {
                ModeChip(title: "VOCAL SWAP") { mode = .vocalSwap }
            }

            GuideStep(
                number: 3,
                title: "Reimagine the song around it",
                detail: "In REIMAGINE, load the original song (or the new vocal track) as the source. Choose REMIX and describe\nthe new style — for example “lo-fi jazz, slow, brushed drums”. Pick a preset and render variations."
            ) {
                ModeChip(title: "REIMAGINE") { mode = .reimagine }
            }

            GuideStep(
                number: 4,
                title: "Keep what you like",
                detail: "Listen to the results, save the ones you want to LIBRARY, and hand them to Logic. Use STEM SPLIT on your\nown result any time to pull stems out of it."
            ) {
                ModeChip(title: "LIBRARY") { mode = .library }
            }

            GuideNote(
                text: "TIP — Same seed keeps results comparable between renders. Change the prompt for a new direction; change the seed for a new take on the same direction."
            )
        }
    }

    // MARK: - Reimagine walkthrough

    private var reimagineFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideIntro(
                title: "Reimagine a song",
                detail: "Three ways to change an existing recording. Pick the operation that matches how much of the original\nyou want to keep."
            )

            GuideStep(
                number: 1,
                title: "Select the source",
                detail: "Choose any audio file (WAV, AIFF, M4A, MP3). Use ANALYZE first to check available metadata; it may return duration only."
            ) {
                HStack(spacing: 8) {
                    ModeChip(title: "REIMAGINE") { mode = .reimagine }
                    ModeChip(title: "ANALYZE") { mode = .analyze }
                }
            }

            GuideStep(
                number: 2,
                title: "Choose an operation",
                detail: "REFERENCE uses the source to guide a new render. REMIX attempts to retain source material while changing its character. REPAINT targets a selected interval; check the output for unwanted changes."
            ) {
                ModeChip(title: "REIMAGINE") { mode = .reimagine }
            }

            GuideStep(
                number: 3,
                title: "Set the musical direction",
                detail: "Describe the target style in the prompt (and lyrics if it has vocals). Set BPM, key and meter — leave\nthem empty to follow the source. Pick a preset: Turbo for fast takes, Quality for final renders."
            ) {
                EmptyView()
            }

            GuideStep(
                number: 4,
                title: "Render and compare",
                detail: "Set a seed and render several variations. Listen side by side with the source, then save the keeper\nto LIBRARY."
            ) {
                ModeChip(title: "LIBRARY") { mode = .library }
            }
        }
    }

    // MARK: - From scratch walkthrough

    private var fromScratchFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideIntro(
                title: "Start from scratch",
                detail: "No source needed. Generate a track from text, then shape it."
            )

            GuideStep(
                number: 1,
                title: "Describe the track",
                detail: "In GENERATE, write the style and mood — for example “warm lo-fi drums and electric piano,\ninstrumental”. Add lyrics if you want vocals, pick a language, preset and duration."
            ) {
                ModeChip(title: "GENERATE") { mode = .generate }
            }

            GuideStep(
                number: 2,
                title: "Render variations",
                detail: "Render several variations with the same seed family. Turbo is fast enough to explore; re-render a\ndirection you like in Quality."
            ) {
                EmptyView()
            }

            GuideStep(
                number: 3,
                title: "Shape the result",
                detail: "Anything you generate can become a source: REIMAGINE it for a new style, TRANSCRIBE it to MIDI for\nLogic, or STEM SPLIT it into parts."
            ) {
                HStack(spacing: 8) {
                    ModeChip(title: "REIMAGINE") { mode = .reimagine }
                    ModeChip(title: "TRANSCRIBE") { mode = .transcribe }
                    ModeChip(title: "STEM SPLIT") { mode = .stemSplit }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct GuideIntro: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typography.heading)
                .foregroundColor(Palette.ink)
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(Palette.ink.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GuideStep<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.deck)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.ink))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typography.label)
                    .foregroundColor(Palette.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.deck)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Palette.ink.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Small clickable chip that switches the deck to a workspace mid-guide.
private struct ModeChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("OPEN \(title) →")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(Palette.textBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Palette.textBlue, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Switches to the \(title.lowercased()) workspace")
    }
}

private struct GuideNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.help)
            .foregroundColor(Palette.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.divider.opacity(0.4))
    }
}

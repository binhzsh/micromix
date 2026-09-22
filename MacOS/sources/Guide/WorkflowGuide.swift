import SwiftUI

/// End-to-end workflow guide shown from the GUIDE deck button.
///
/// Static, self-contained: no view models or network access. The cover
/// walkthrough uses the real mode buttons so a user can follow it while
/// switching workspaces.
struct WorkflowGuideView: View {
    @Binding var mode: DeviceMode
    @State private var tab: GuideTab = .cover

    enum GuideTab: String, CaseIterable, Identifiable {
        case cover = "AI COVER"
        case reimagine = "REIMAGINE"
        case fromScratch = "FROM SCRATCH"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(GuideTab.allCases) { entry in
                    Button(entry.rawValue) { tab = entry }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.0)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tab == entry ? Palette.ink : Color.clear)
                        .foregroundColor(tab == entry ? Palette.deck : Palette.ink)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Palette.ink.opacity(0.85), lineWidth: 1.5)
                        )
                }
                Spacer()
            }

            ScrollView {
                switch tab {
                case .cover: coverFlow
                case .reimagine: reimagineFlow
                case .fromScratch: fromScratchFlow
                }
            }
        }
    }

    // MARK: - AI Cover walkthrough

    private var coverFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideIntro(
                title: "MAKE AN AI COVER",
                detail: "Turn a song into a new version with different vocals and a new style. Everything runs locally on this Mac."
            )

            GuideStep(
                number: 1,
                title: "GET THE VOCALS OUT OF THE SONG",
                detail: "Load the original song in STEM SPLIT and describe what to keep — for example “vocals”. The result is a clean\nvocal track plus everything else (the accompaniment)."
            ) {
                ModeChip(title: "STEM SPLIT") { mode = .stemSplit }
            }

            GuideStep(
                number: 2,
                title: "SING IT IN A DIFFERENT VOICE",
                detail: "Load the vocal track in VOCAL SWAP, pick a voice model, adjust the pitch offset if needed, and render.\nThe output keeps the lyrics but changes the voice."
            ) {
                ModeChip(title: "VOCAL SWAP") { mode = .vocalSwap }
            }

            GuideStep(
                number: 3,
                title: "REIMAGINE THE SONG AROUND IT",
                detail: "In REIMAGINE, load the original song (or the new vocal track) as the source. Choose REMIX and describe\nthe new style — for example “lo-fi jazz, slow, brushed drums”. Pick a preset and render variations."
            ) {
                ModeChip(title: "REIMAGINE") { mode = .reimagine }
            }

            GuideStep(
                number: 4,
                title: "KEEP WHAT YOU LIKE",
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
                title: "REIMAGINE A SONG",
                detail: "Three ways to change an existing recording. Pick the operation that matches how much of the original\nyou want to keep."
            )

            GuideStep(
                number: 1,
                title: "SELECT THE SOURCE",
                detail: "Choose any audio file (WAV, AIFF, M4A, MP3). Use ANALYZE first if you want key, tempo and structure\nread out before you commit."
            ) {
                HStack(spacing: 8) {
                    ModeChip(title: "REIMAGINE") { mode = .reimagine }
                    ModeChip(title: "ANALYZE") { mode = .analyze }
                }
            }

            GuideStep(
                number: 2,
                title: "CHOOSE AN OPERATION",
                detail: "REFERENCE — the source strongly guides a new render. REMIX — keep the song’s material but change its\ncharacter. REPAINT — replace only a selected time interval and preserve everything around it."
            ) {
                ModeChip(title: "REIMAGINE") { mode = .reimagine }
            }

            GuideStep(
                number: 3,
                title: "SET THE MUSICAL DIRECTION",
                detail: "Describe the target style in the prompt (and lyrics if it has vocals). Set BPM, key and meter — leave\nthem empty to follow the source. Pick a preset: Turbo for fast takes, Quality for final renders."
            ) {
                EmptyView()
            }

            GuideStep(
                number: 4,
                title: "RENDER AND COMPARE",
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
                title: "START FROM SCRATCH",
                detail: "No source needed. Generate a track from text, then shape it."
            )

            GuideStep(
                number: 1,
                title: "DESCRIBE THE TRACK",
                detail: "In GENERATE, write the style and mood — for example “warm lo-fi drums and electric piano,\ninstrumental”. Add lyrics if you want vocals, pick a language, preset and duration."
            ) {
                ModeChip(title: "GENERATE") { mode = .generate }
            }

            GuideStep(
                number: 2,
                title: "RENDER VARIATIONS",
                detail: "Render several variations with the same seed family. Turbo is fast enough to explore; re-render a\ndirection you like in Quality."
            ) {
                EmptyView()
            }

            GuideStep(
                number: 3,
                title: "SHAPE THE RESULT",
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
            Typography.monoLabel(title, size: 13)
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
                Typography.monoLabel(title, size: 11)
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
                .foregroundColor(Palette.accentBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Palette.accentBlue.opacity(0.6), lineWidth: 1)
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
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Palette.ink.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.divider.opacity(0.4))
    }
}

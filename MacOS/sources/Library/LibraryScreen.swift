import AppKit
import SwiftUI

/// LIBRARY mode: a dot-matrix list of saved results with transport controls
/// on the deck (play/pause, delete, reveal in Finder) and an empty state.
struct LibraryScreen: View {
    @ObservedObject var library: LocalLibrary
    @ObservedObject var player: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @ObservedObject var router: WorkflowRouter
    @Binding var selectedID: UUID?
    var onGenerate: () -> Void = {}
    var onStartTranscribe: () -> Void = {}
    @State private var collection: LibraryCollection = .all
    @State private var searchText = ""
    @State private var showsTrail = false
    @State private var compareA: LibraryItem?
    @State private var compareB: LibraryItem?
    @State private var exportStatus: String?

    private let columns = [
        GridItem(.fixed(44), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.fixed(52), alignment: .leading),
        GridItem(.fixed(64), alignment: .leading),
        GridItem(.fixed(52), alignment: .leading),
        GridItem(.flexible(minimum: 64), alignment: .trailing),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            organization
            listOrEmpty
            assetInspector
            provenance
            related
            transport
            if let exportStatus {
                Text(exportStatus)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onChange(of: collection) { _, _ in clearHiddenSelection() }
        .onChange(of: searchText) { _, _ in clearHiddenSelection() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Typography.monoLabel("LIBRARY — \(displayedItems.count) OF \(library.items.count) ASSET\(library.items.count == 1 ? "" : "S")", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))
            Spacer()
        }
    }

    private var organization: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibraryCollection.allCases) { option in
                        collectionButton(option)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.ink.opacity(0.6))
                TextField("SEARCH TITLE, SOURCE, OR OPERATION", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink)
                if !searchText.isEmpty {
                    Button("CLEAR") { searchText = "" }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.accentBlue)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.divider, lineWidth: 1))
        }
    }

    private func collectionButton(_ option: LibraryCollection) -> some View {
        let active = collection == option
        return Button(option.label) { collection = option }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(active ? Palette.deck : Palette.ink.opacity(0.76))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(active ? Palette.accentBlue : Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Palette.accentBlue : Palette.divider, lineWidth: 1))
    }

    @ViewBuilder private var listOrEmpty: some View {
        if library.items.isEmpty {
            DeckPanel {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(Palette.accentBlue)
                    Typography.monoLabel("NO TRACKS YET", size: 13)
                        .foregroundColor(Palette.ink)
                    Text("Generate a new piece or transcribe audio to build your private library.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.66))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        emptyAction("GENERATE", color: Palette.accentOrange, action: onGenerate)
                        emptyAction("TRANSCRIBE", color: Palette.accentBlue, action: onStartTranscribe)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        } else if displayedItems.isEmpty {
            DeckPanel {
                VStack(spacing: 8) {
                    Typography.monoLabel("NO MATCHING ASSETS", size: 12)
                        .foregroundColor(Palette.ink)
                    Text("Choose another collection or clear the search to see your saved files.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.66))
                    Button("CLEAR FILTERS") {
                        collection = .all
                        searchText = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.accentBlue)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }
        } else {
            table
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                headerRow
                Divider().overlay(Palette.divider)
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    row(index: index + 1, item: item)
                    Divider().overlay(Palette.divider.opacity(0.6))
                }
            }
            .background(Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.divider, lineWidth: 1))
        }
        .frame(maxHeight: 190)
    }

    private var headerRow: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            col("")
            col("TITLE")
            col("TYPE")
            col("WAVE")
            col("LEN")
            col("DATE")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(index: Int, item: LibraryItem) -> some View {
        let selected = item.id == selectedID
        let sounding = (player.currentItem?.id == item.id && player.isPlaying)
            || (midiPreview.currentItem?.id == item.id && midiPreview.isPlaying)
        return LazyVGrid(columns: columns, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.68))
            HStack(spacing: 5) {
                if sounding {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.accentGreen)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
            }
            Text(item.kind == .audio ? "WAV" : "MID")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(item.kind == .audio ? Palette.accentGreen : Palette.accentBlue)
            if item.kind == .audio {
                MiniWaveform(item: item, library: library)
            } else {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.4))
            }
            Text(item.durationSeconds.map { Self.formatDuration($0) } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.7))
            Text(item.createdAt, style: .date)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.68))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Palette.accentBlue.opacity(0.10) : Color.clear)
        .onTapGesture {
            midiPreview.stop()
            selectedID = item.id
        }
    }

    @ViewBuilder private var assetInspector: some View {
        if let item = selectedItem {
            DeckPanel {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Typography.monoLabel("SELECTED ASSET", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        Spacer()
                        Typography.monoLabel(item.kind == .audio ? "AUDIO" : "MIDI", size: 10)
                            .foregroundColor(item.kind == .audio ? Palette.accentGreen : Palette.accentBlue)
                    }
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                    Text(item.relativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.64))
                        .lineLimit(1)
                    if item.kind == .audio {
                        HStack(spacing: 7) {
                            ForEach(router.availableActions(for: item)) { action in
                                actionButton(action.label, color: actionColor(for: action)) {
                                    router.execute(action, on: item)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            button("PLAY", color: Palette.accentGreen, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                let url = library.resolvedURL(for: item)
                if item.kind == .audio {
                    midiPreview.stop()
                    if player.load(url: url, item: item) != nil {
                        player.play()
                    }
                } else {
                    player.stop()
                    if midiPreview.shouldResume(for: item) {
                        midiPreview.play()
                    } else if midiPreview.load(url: url, item: item) {
                        midiPreview.play()
                    }
                }
            }
            button("PAUSE", color: Palette.ink, disabled: !player.isPlaying && !midiPreview.isPlaying) {
                if player.isPlaying { player.pause() }
                if midiPreview.isPlaying { midiPreview.stop() }
            }
            button("STOP", color: Palette.ink, disabled: !player.isPlaying && !midiPreview.isPlaying) {
                if player.isPlaying { player.stop() }
                if midiPreview.isPlaying { midiPreview.stop() }
            }
            button("DELETE", color: Palette.accentRed, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                if player.currentItem?.id == item.id { player.stop() }
                if midiPreview.currentItem?.id == item.id { midiPreview.stop() }
                try? library.remove(id: item.id)
            }
            button("REVEAL", color: Palette.accentBlue, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                NSWorkspace.shared.activateFileViewerSelecting([library.resolvedURL(for: item)])
            }
            button("OPEN", color: Palette.accentBlue, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                NSWorkspace.shared.open(library.resolvedURL(for: item))
            }
            button("EXPORT", color: Palette.accentOrange, disabled: selectedItem == nil) {
                guard let item = selectedItem else { return }
                do {
                    let url = try library.exportBundle(for: item)
                    exportStatus = "EXPORTED — \(url.path)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    exportStatus = "EXPORT FAILED — \(error.localizedDescription)"
                }
            }
            button("COPY PROVENANCE", color: Palette.accentOrange, disabled: selectedItem?.provenance == nil) {
                guard let copyText = selectedItem?.provenance?.copyText else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, color: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(disabled ? Palette.ink.opacity(0.46) : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.deck)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(disabled ? Palette.ink.opacity(0.22) : color, lineWidth: 1.5)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Typography.monoLabel(title, size: 9)
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func actionColor(for action: AssetAction) -> Color {
        switch action {
        case .referenceGenerate:
            return Palette.accentOrange
        case .remix, .repaint:
            return Palette.accentOrange
        case .stemSplit:
            return Palette.accentBlue
        case .vocalSwap:
            return Palette.accentGreen
        case .transcribe:
            return Palette.accentBlue
        case .analyze:
            return Palette.accentBlue
        }
    }

    private func col(_ text: String) -> some View {
        Typography.monoLabel(text, size: 10)
            .foregroundColor(Palette.ink.opacity(0.64))
    }

    private func emptyAction(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Typography.monoLabel(title, size: 10)
                .foregroundColor(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var selectedItem: LibraryItem? {
        library.items.first { $0.id == selectedID }
    }

    private var displayedItems: [LibraryItem] {
        library.items.filter { item in
            collection.includes(item) && searchMatches(item)
        }
    }

    private func searchMatches(_ item: LibraryItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return [item.title, item.promptOrSource, item.relativePath, item.workspaceOperation ?? ""]
            .contains { $0.lowercased().contains(query) }
    }

    private func clearHiddenSelection() {
        guard let selectedID,
              !displayedItems.contains(where: { $0.id == selectedID }) else { return }
        player.stop()
        midiPreview.stop()
        self.selectedID = nil
    }

    @ViewBuilder private var provenance: some View {
        if let item = selectedItem {
            DeckPanel {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Typography.monoLabel("PROVENANCE", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        Spacer()
                        if item.provenance != nil {
                            Button(showsTrail ? "HIDE TRAIL" : "SHOW TRAIL") { showsTrail.toggle() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(Palette.accentBlue)
                        }
                    }
                    if alternatives(for: item).count > 1 {
                        HStack(spacing: 5) {
                            Typography.monoLabel("ALTERNATIVES", size: 9)
                                .foregroundColor(Palette.ink.opacity(0.64))
                            Button("PREV") {
                                guard let alternative = library.items.previousAlternative(before: item) else { return }
                                select(alternative)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.68))
                            .disabled(library.items.previousAlternative(before: item) == nil)
                            ForEach(alternatives(for: item)) { alternative in
                                Button("ALT \((alternative.provenance?.output.position ?? 0) + 1)") {
                                    select(alternative)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(alternative.id == item.id ? Palette.accentOrange : Palette.ink.opacity(0.68))
                            }
                            Button("NEXT") {
                                guard let alternative = library.items.nextAlternative(after: item) else { return }
                                select(alternative)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.68))
                            .disabled(library.items.nextAlternative(after: item) == nil)
                            abCompareControls(for: item, group: alternatives(for: item))
                        }
                    }
                    if let provenance = item.provenance {
                        if showsTrail {
                            trail(for: item, provenance: provenance)
                        } else {
                            Text("OPERATION: \(provenance.operation ?? item.kind.rawValue.uppercased()) · JOB \(provenance.jobID.suffix(8)) · OUTPUT #\(provenance.output.position + 1)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.ink)
                            Text("SOURCE: \(provenance.inputs.sorted { $0.position < $1.position }.map { "\($0.name) — \($0.asset.filename)" }.joined(separator: ", ").ifEmpty("(none)"))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Palette.ink.opacity(0.72))
                        }
                        Text("SUBMITTED: \(["seed", "variation_count"].compactMap { key in provenance.parameters[key].map { "\(key)=\($0.displayText)" } }.joined(separator: ", ").ifEmpty("(not specified)"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.72))
                        Text("PARAMETERS: \(provenance.parameters.keys.sorted().map { "\($0)=\(provenance.parameters[$0]!.displayText)" }.joined(separator: ", ").ifEmpty("(none)"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.72))
                            .lineLimit(2)
                    } else {
                        Text("PROVENANCE UNAVAILABLE FOR THIS LEGACY ITEM")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.60))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Collapsible Source → Operation → Output chain for the selected asset.
    private func trail(for item: LibraryItem, provenance: LibraryProvenance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let inputs = provenance.inputs.sorted { $0.position < $1.position }
            if inputs.isEmpty {
                trailStage("SOURCE", "(none)")
            } else {
                ForEach(Array(inputs.enumerated()), id: \.offset) { _, link in
                    trailStage("SOURCE", "\(link.name) — \(link.asset.filename)")
                }
            }
            trailArrow
            trailStage(
                "OPERATION",
                "\(provenance.operation ?? item.kind.rawValue.uppercased()) · JOB \(provenance.jobID.suffix(8))"
            )
            trailArrow
            trailStage(
                "OUTPUT",
                "#\(provenance.output.position + 1) \(provenance.output.name) — \(provenance.output.asset.filename)"
            )
        }
    }

    private func trailStage(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Typography.monoLabel(label, size: 9)
                .foregroundColor(Palette.ink.opacity(0.6))
                .frame(width: 64, alignment: .leading)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.86))
                .lineLimit(1)
        }
    }

    private var trailArrow: some View {
        Typography.monoLabel("▼", size: 8)
            .foregroundColor(Palette.ink.opacity(0.34))
            .frame(width: 64, alignment: .leading)
    }

    /// Siblings, parents, and children of the selected asset, resolved from
    /// durable provenance. Selecting a row navigates to that asset.
    @ViewBuilder private var related: some View {
        if let item = selectedItem {
            let related = RelatedAssetsResolver.related(for: item, in: library.items)
            if !related.isEmpty {
                DeckPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        Typography.monoLabel("RELATED ASSETS", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(related.parents) { relationRow("PARENT", $0) }
                                ForEach(related.siblings) { relationRow("SIBLING", $0) }
                                ForEach(related.children) { relationRow("CHILD", $0) }
                            }
                        }
                        .frame(maxHeight: 96)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func relationRow(_ relation: String, _ item: LibraryItem) -> some View {
        Button {
            select(item)
        } label: {
            HStack(spacing: 8) {
                Typography.monoLabel(relation, size: 9)
                    .foregroundColor(relationColor(relation))
                    .frame(width: 50, alignment: .leading)
                Text(item.title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Typography.monoLabel(item.kind == .audio ? "WAV" : "MID", size: 9)
                    .foregroundColor(item.kind == .audio ? Palette.accentGreen : Palette.accentBlue)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Palette.ink.opacity(0.45))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func relationColor(_ relation: String) -> Color {
        switch relation {
        case "PARENT": return Palette.accentOrange
        case "SIBLING": return Palette.accentBlue
        default: return Palette.accentGreen
        }
    }

    private func alternatives(for item: LibraryItem) -> [LibraryItem] {
        library.items.alternatives(for: item)
    }

    /// A/B compare controls (Phase 5.2): pin the selected item into one of two
    /// slots, then toggle playback between the pinned alternatives. Pins are
    /// validated against the current alternatives group, so stale pins from a
    /// different job simply disappear until re-pinned.
    @ViewBuilder private func abCompareControls(for item: LibraryItem, group: [LibraryItem]) -> some View {
        // A/B compare feeds the shared AudioPlayer, which only plays audio;
        // MIDI alternatives keep using the MIDI preview instead.
        if item.kind == .audio {
            let pinnedA = compareA.flatMap { pinned in group.first { $0.id == pinned.id } }
            let pinnedB = compareB.flatMap { pinned in group.first { $0.id == pinned.id } }
            Button("A") { compareA = item }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(pinnedA?.id == item.id ? Palette.accentOrange : Palette.ink.opacity(0.68))
                .accessibilityLabel("Pin this alternative as A")
            Button("B") { compareB = item }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(pinnedB?.id == item.id ? Palette.accentOrange : Palette.ink.opacity(0.68))
                .accessibilityLabel("Pin this alternative as B")
            if let a = pinnedA, let b = pinnedB, a.id != b.id {
                Button("A⇄B") { toggleCompare(a: a, b: b) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Self.isCompareLoaded(a: a, b: b, loadedID: player.currentItem?.id)
                        ? Palette.accentGreen : Palette.ink.opacity(0.68))
                    .accessibilityLabel("Toggle playback between the two pinned alternatives")
            }
        }
    }

    /// Decides which pinned item a compare toggle should play next. Pure so it
    /// can be tested headlessly: swaps to the other slot when one is loaded,
    /// otherwise starts with A.
    static func compareNext(currentID: UUID?, a: LibraryItem, b: LibraryItem) -> LibraryItem {
        currentID == a.id ? b : a
    }

    private func toggleCompare(a: LibraryItem, b: LibraryItem) {
        let next = Self.compareNext(currentID: player.currentItem?.id, a: a, b: b)
        player.load(url: library.resolvedURL(for: next), item: next)
        player.play()
    }

    static func isCompareLoaded(a: LibraryItem, b: LibraryItem, loadedID: UUID?) -> Bool {
        loadedID == a.id || loadedID == b.id
    }

    private func select(_ item: LibraryItem) {
        player.stop()
        midiPreview.stop()
        selectedID = item.id
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

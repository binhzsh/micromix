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
    var onOpenTimeline: () -> Void = {}
    @State private var collection: LibraryCollection = .all
    @State private var searchText = ""
    @State private var showsTrail = false
    @State private var compareA: LibraryItem?
    @State private var compareB: LibraryItem?
    @State private var exportStatus: String?
    @State private var deletionCandidate: LibraryItem?
    @State private var deletionError: String?
    @State private var renameCandidate: LibraryItem?
    @State private var renameTitle = ""
    @State private var renameError: String?
    @State private var lyricsEditingItem: LibraryItem?
    @State private var lyricsDraft = ""
    @State private var lyricsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            organization
            if !library.deletionRecoveryIssues.isEmpty {
                VStack(alignment: .leading) {
                    ForEach(library.deletionRecoveryIssues, id: \.self) { issue in
                        Text(issue).textSelection(.enabled)
                    }
                    Button("Retry deletion recovery") { library.retryDeletionRecovery() }
                }
            }
            listOrEmpty
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if selectedItem != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        assetInspector
                        transport
                        provenance
                        related
                        if let exportStatus {
                            Text(exportStatus).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(Self.emptyDetailGuidance(hasItems: !library.items.isEmpty, hasMatches: !displayedItems.isEmpty))
                    .font(Typography.help)
                    .foregroundColor(Palette.ink.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $lyricsEditingItem) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("Correct lyrics draft").font(.headline)
                Text("Saving creates a separate corrected draft; the original remains unchanged.")
                TextEditor(text: $lyricsDraft).frame(minHeight: 240)
                HStack {
                    Button("Cancel") { lyricsEditingItem = nil }
                    Spacer()
                    Button("Save corrected draft") {
                        do {
                            let corrected = try library.saveLyricsCorrection(of: item, text: lyricsDraft)
                            collection = .all
                            searchText = ""
                            selectedID = corrected.id
                            lyricsEditingItem = nil
                        } catch { lyricsError = error.localizedDescription }
                    }
                }
                if let lyricsError { Text(lyricsError).foregroundStyle(.red).textSelection(.enabled) }
            }.padding().frame(minWidth: 480, minHeight: 360)
        }
        .confirmationDialog(
            "Delete \(deletionCandidate?.title ?? "this asset")?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: { _ in
            Text("Deletes this Library item and its file. Related and derived items remain, but their provenance may refer to a missing source.")
        }
        .alert("Deletion failed", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .alert("Rename asset", isPresented: Binding(
            get: { renameCandidate != nil },
            set: { if !$0 { renameCandidate = nil } }
        ), presenting: renameCandidate) { item in
            TextField("Display title", text: $renameTitle)
            Button("Save") {
                do {
                    try library.rename(id: item.id, title: renameTitle)
                    clearHiddenSelection()
                } catch { renameError = error.localizedDescription }
                renameCandidate = nil
            }
            Button("Cancel", role: .cancel) { renameCandidate = nil }
        } message: { _ in
            Text("Only the display title changes; the file and provenance stay unchanged.")
        }
        .alert("Rename failed", isPresented: Binding(
            get: { renameError != nil }, set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: { Text(renameError ?? "") }
        .onChange(of: selectedID) { oldID, newID in
            if oldID != newID { player.stop(); midiPreview.stop() }
        }
        .onChange(of: collection) { _, _ in clearHiddenSelection() }
        .onChange(of: searchText) { _, _ in clearHiddenSelection() }
    }

    static func copyLyrics(_ text: String, write: (String) -> Void) {
        write(text)
    }

    private func delete(_ item: LibraryItem) {
        do {
            try library.remove(id: item.id)
            if player.currentItem?.id == item.id { player.stop() }
            if midiPreview.currentItem?.id == item.id { midiPreview.stop() }
            if selectedID == item.id { selectedID = nil }
            if compareA?.id == item.id { compareA = nil }
            if compareB?.id == item.id { compareB = nil }
        } catch {
            deletionError = "\(error.localizedDescription) Check file permissions and available storage, then try again."
            if !library.items.contains(where: { $0.id == item.id }) {
                if player.currentItem?.id == item.id { player.stop() }
                if midiPreview.currentItem?.id == item.id { midiPreview.stop() }
                if selectedID == item.id { selectedID = nil }
                if compareA?.id == item.id { compareA = nil }
                if compareB?.id == item.id { compareB = nil }
            }
        }
        deletionCandidate = nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Typography.monoLabel("LIBRARY — \(displayedItems.count) OF \(library.items.count) ASSET\(library.items.count == 1 ? "" : "S")", size: 11)
                .foregroundColor(Palette.ink.opacity(0.76))
            Spacer()
            Button("OPEN TIMELINE") { onOpenTimeline() }
                .disabled(!library.items.contains { $0.kind == .audio })
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
                TextField("Search title, source, or operation", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.ink)
                if !searchText.isEmpty {
                    Button("CLEAR") { searchText = "" }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.textBlue)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.boundary, lineWidth: 1))
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
            .background(active ? Palette.textBlue : Palette.deck)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Palette.textBlue : Palette.boundary, lineWidth: 1))
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
                        .font(Typography.help)
                        .foregroundColor(Palette.ink.opacity(0.66))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        emptyAction("GENERATE", color: Palette.textOrange, action: onGenerate)
                        emptyAction("TRANSCRIBE", color: Palette.textBlue, action: onStartTranscribe)
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
                        .font(Typography.help)
                        .foregroundColor(Palette.ink.opacity(0.66))
                    Button("CLEAR FILTERS") {
                        collection = .all
                        searchText = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.textBlue)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }
        } else {
            table
        }
    }

    private var table: some View {
        List(selection: $selectedID) {
            ForEach(displayedItems) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).lineLimit(1)
                        Text("\(item.kind.shortLabel) · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if (player.currentItem?.id == item.id && player.isPlaying)
                        || (midiPreview.currentItem?.id == item.id && midiPreview.isPlaying) {
                        Image(systemName: "speaker.wave.2.fill").accessibilityLabel("Playing")
                    }
                    Text(item.durationSeconds.map { Self.formatDuration($0) } ?? "—")
                        .font(.caption.monospacedDigit())
                }
                .tag(item.id)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel("Library assets")
    }

    @ViewBuilder private var assetInspector: some View {
        if let item = selectedItem {
            DeckPanel {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Typography.monoLabel("SELECTED ASSET", size: 10)
                            .foregroundColor(Palette.ink.opacity(0.64))
                        Spacer()
                        Typography.monoLabel(item.kind.rawValue.uppercased(), size: 10)
                            .foregroundColor(item.kind == .audio ? Palette.textGreen : Palette.textBlue)
                    }
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                    ForEach(Self.identityDetails(for: item), id: \.label) { detail in
                        Text("\(detail.label): \(detail.value)")
                            .font(Typography.help)
                            .foregroundColor(Palette.ink.opacity(0.76))
                            .textSelection(.enabled)
                    }
                    Text(item.relativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.64))
                        .lineLimit(1)
                    if item.kind == .lyrics {
                        Text("Unverified lyrics draft — review before use.").font(Typography.help)
                        if let text = try? String(contentsOf: library.resolvedURL(for: item), encoding: .utf8) {
                            ScrollView {
                                Text(text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 180)
                            HStack {
                                Button("Copy") {
                                    Self.copyLyrics(text) { value in
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(value, forType: .string)
                                    }
                                }
                                Button("Edit / save corrected draft") {
                                    lyricsError = nil
                                    lyricsDraft = text
                                    lyricsEditingItem = item
                                }
                                Button("Use as Generate lyrics") { router.useGenerateLyrics(text) }
                            }
                        } else {
                            Text("Lyrics file is missing or unreadable.")
                        }
                    }
                    if item.kind == .audio {
                        HStack(spacing: 8) {
                            Button(player.currentItem?.id == item.id && player.isPlaying ? "PAUSE" : "PLAY") {
                                if player.currentItem?.id == item.id && player.isPlaying {
                                    player.pause()
                                } else {
                                    midiPreview.stop()
                                    if player.shouldResume(for: item) {
                                        player.play()
                                    } else if player.load(url: library.resolvedURL(for: item), item: item) != nil {
                                        player.play()
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            ZStack {
                                MiniWaveform(item: item, library: library, barCount: 80, fillsWidth: true)
                                Slider(value: Binding(
                                    get: {
                                        guard player.currentItem?.id == item.id, let duration = player.currentDuration, duration > 0 else { return 0 }
                                        return min(max(player.currentTime / duration, 0), 1)
                                    },
                                    set: { fraction in
                                        if player.currentItem?.id != item.id {
                                            midiPreview.stop()
                                            guard player.load(url: library.resolvedURL(for: item), item: item) != nil else { return }
                                        }
                                        if let duration = player.currentDuration { player.seek(to: fraction * duration) }
                                    }
                                ), in: 0...1)
                                .accessibilityLabel("Seek \(item.title)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        Menu("Continue with…") {
                            ForEach(router.availableActions(for: item)) { action in
                                Button(action.label) { router.execute(action, on: item) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transport: some View {
        HStack {
            Button("Play") {
                guard let item = selectedItem else { return }
                let url = library.resolvedURL(for: item)
                if item.kind == .audio {
                    midiPreview.stop()
                    if player.shouldResume(for: item) { player.play() }
                    else if player.load(url: url, item: item) != nil { player.play() }
                } else if item.kind == .midi {
                    player.stop()
                    if midiPreview.shouldResume(for: item) { midiPreview.play() }
                    else if midiPreview.load(url: url, item: item) { midiPreview.play() }
                }
            }
            .disabled(selectedItem == nil || selectedItem?.kind == .lyrics)
            Button("Pause") {
                if player.isPlaying { player.pause() }
                if midiPreview.isPlaying { midiPreview.pause() }
            }
            .disabled(!player.isPlaying && !midiPreview.isPlaying)
            Button("Stop") { player.stop(); midiPreview.stop() }
                .disabled(player.state == .idle && midiPreview.state == .idle)
            Spacer()
            Menu("More actions") {
                Button("Rename…") {
                    guard let item = selectedItem else { return }
                    renameTitle = item.title
                    renameCandidate = item
                }
                Button("Reveal in Finder") {
                    guard let item = selectedItem else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([library.resolvedURL(for: item)])
                }
                Button("Open") {
                    guard let item = selectedItem else { return }
                    NSWorkspace.shared.open(library.resolvedURL(for: item))
                }
                Button("Export bundle") {
                    guard let item = selectedItem else { return }
                    do {
                        let url = try library.exportBundle(for: item)
                        exportStatus = "Exported: \(url.path)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch { exportStatus = "Export failed: \(error.localizedDescription)" }
                }
                Button("Copy provenance") {
                    guard let copyText = selectedItem?.provenance?.copyText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
                .disabled(selectedItem?.provenance == nil)
                Divider()
                Button("Delete…", role: .destructive) { deletionCandidate = selectedItem }
            }
            .disabled(selectedItem == nil)
        }
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
            Self.matches(item, collection: collection, searchText: searchText)
        }
    }

    static func emptyDetailGuidance(hasItems: Bool, hasMatches: Bool) -> String {
        if !hasItems { return "Save an asset to see its details here." }
        if !hasMatches { return "Clear filters to select an asset and see its details." }
        return "Select an asset in the list to see its details and actions."
    }

    static func identityDetails(for item: LibraryItem) -> [(label: String, value: String)] {
        func known(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Unavailable" : trimmed
        }
        let provenance = item.provenance
        let inputs = provenance?.inputs.sorted { $0.position < $1.position }
            .map { "\($0.name) — \($0.asset.filename)" }.joined(separator: ", ")
        let source = (inputs?.isEmpty == false) ? inputs : item.promptOrSource
        let duration = item.durationSeconds.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? formatDuration($0) : nil }
        return [
            ("Role", known(provenance?.output.name)),
            ("Source / prompt", known(source)),
            ("Job", known(provenance?.jobID)),
            ("Date", item.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Duration", duration ?? "Unavailable")
        ]
    }

    static func siblingLabel(for item: LibraryItem) -> String {
        item.workspaceOperation == "stem_split" ? "STEM" : "SIBLING"
    }

    static func matches(_ item: LibraryItem, collection: LibraryCollection, searchText: String) -> Bool {
        guard collection.includes(item) else { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return [item.title, item.promptOrSource, item.relativePath, item.workspaceOperation ?? ""]
            .contains { $0.lowercased().contains(query) }
    }

    /// Keep each filter that admits the navigation target; clear only blockers.
    static func filtersForNavigation(to item: LibraryItem, collection: LibraryCollection, searchText: String)
        -> (collection: LibraryCollection, searchText: String) {
        let visibleCollection: LibraryCollection = collection.includes(item) ? collection : .all
        let visibleSearch = matches(item, collection: .all, searchText: searchText) ? searchText : ""
        return (visibleCollection, visibleSearch)
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
                    }
                    if alternatives(for: item).count > 1 {
                        ScrollView(.horizontal) {
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
                                .foregroundColor(alternative.id == item.id ? Palette.textOrange : Palette.ink.opacity(0.68))
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
                    }
                    DisclosureGroup("Provenance") {
                    if let provenance = item.provenance {
                        Button(showsTrail ? "Hide trail" : "Show trail") { showsTrail.toggle() }
                        if showsTrail {
                            trail(for: item, provenance: provenance)
                        } else {
                            Text("OPERATION: \(provenance.operation ?? item.kind.rawValue.uppercased()) · JOB \(provenance.jobID.suffix(8)) · OUTPUT #\(provenance.output.position + 1)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.ink)
                            Text("Source: \(provenance.inputs.sorted { $0.position < $1.position }.map { "\($0.name) — \($0.asset.filename)" }.joined(separator: ", ").ifEmpty("(none)"))")
                                .font(Typography.help)
                                .foregroundColor(Palette.ink.opacity(0.72))
                        }
                        Text("Submitted: \(["seed", "variation_count"].compactMap { key in provenance.parameters[key].map { "\(key)=\($0.displayText)" } }.joined(separator: ", ").ifEmpty("(not specified)"))")
                            .font(Typography.help)
                            .foregroundColor(Palette.ink.opacity(0.72))
                        Text("Parameters: \(provenance.parameters.keys.sorted().map { "\($0)=\(provenance.parameters[$0]!.displayText)" }.joined(separator: ", ").ifEmpty("(none)"))")
                            .font(Typography.help)
                            .foregroundColor(Palette.ink.opacity(0.72))
                            .lineLimit(2)
                    } else if item.kind == .lyrics && item.promptOrSource.hasPrefix("Corrected from ") {
                        Text("Local correction · \(item.promptOrSource)")
                            .font(.caption).textSelection(.enabled)
                    } else {
                        Text("Provenance is unavailable for this legacy item.")
                            .font(Typography.help)
                            .foregroundColor(Palette.ink.opacity(0.72))
                    }
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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(related.parents) { relationRow("SOURCE", $0) }
                            ForEach(related.siblings) { relationRow(Self.siblingLabel(for: item), $0) }
                            ForEach(related.children) { relationRow("DERIVED", $0) }
                        }
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
                    .frame(width: 65, alignment: .leading)
                VStack(alignment: .leading) {
                    Text(item.title)
                    if relation == "STEM", let role = item.provenance?.output.name, !role.isEmpty {
                        Text("Role: \(role)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink)
                .lineLimit(1)
                Spacer(minLength: 0)
                Typography.monoLabel(item.kind.shortLabel, size: 9)
                    .foregroundColor(item.kind == .audio ? Palette.textGreen : Palette.textBlue)
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
        case "SOURCE": return Palette.textOrange
        case "SIBLING", "STEM": return Palette.textBlue
        default: return Palette.textGreen
        }
    }

    static func alternatives(for item: LibraryItem, in items: [LibraryItem]) -> [LibraryItem] {
        item.workspaceOperation == "stem_split" ? [item] : items.alternatives(for: item)
    }

    private func alternatives(for item: LibraryItem) -> [LibraryItem] {
        Self.alternatives(for: item, in: library.items)
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
                .foregroundColor(pinnedA?.id == item.id ? Palette.textOrange : Palette.ink.opacity(0.68))
                .accessibilityLabel("Pin this alternative as A")
            Button("B") { compareB = item }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(pinnedB?.id == item.id ? Palette.textOrange : Palette.ink.opacity(0.68))
                .accessibilityLabel("Pin this alternative as B")
            if let a = pinnedA, let b = pinnedB, a.id != b.id {
                Button("A⇄B") { toggleCompare(a: a, b: b) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Self.isCompareLoaded(a: a, b: b, loadedID: player.currentItem?.id)
                        ? Palette.textGreen : Palette.ink.opacity(0.68))
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
        let filters = Self.filtersForNavigation(to: item, collection: collection, searchText: searchText)
        collection = filters.collection
        searchText = filters.searchText
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

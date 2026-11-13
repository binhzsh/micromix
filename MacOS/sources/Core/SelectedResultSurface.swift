import SwiftUI

/// Resolves selection by identity, never by the current order of alternatives.
struct ResultSelection {
    private(set) var selectedID: UUID?
    private(set) var generation = UUID()

    mutating func select(_ id: UUID?) {
        guard selectedID != id else { return }
        generation = UUID()
        selectedID = id
    }

    mutating func reset(for results: [LibraryItem]) {
        generation = UUID()
        selectedID = results.first?.id
    }

    func actionTarget(expectedID: UUID, generation: UUID, results: [LibraryItem],
                      available: (LibraryItem) -> Bool) -> LibraryItem? {
        guard self.generation == generation, selectedID == expectedID,
              let item = selected(in: results), available(item) else { return nil }
        return item
    }

    func selected(in results: [LibraryItem]) -> LibraryItem? {
        results.first { $0.id == selectedID }
    }

    static func role(for item: LibraryItem) -> String {
        item.provenance?.output.name ?? item.kind.shortLabel
    }
}

/// Shared completion surface. Every action resolves the same selected identity.
struct SelectedResultSurface: View {
    let results: [LibraryItem]
    let router: WorkflowRouter?
    let player: AudioPlayer?
    @ObservedObject var library: LocalLibrary
    var onShowInLibrary: (LibraryItem) -> Void
    @State private var selection = ResultSelection()
    @State private var exportStatus: String?

    private var selected: LibraryItem? { selection.selected(in: results) }
    private var available: LibraryItem? {
        guard let selected else { return nil }
        return actionTarget(id: selected.id, generation: selection.generation)
    }

    private func actionTarget(id: UUID, generation: UUID) -> LibraryItem? {
        selection.actionTarget(expectedID: id, generation: generation, results: results) { item in
            var isDirectory: ObjCBool = false
            return library.items.contains(where: { $0.id == item.id }) &&
                FileManager.default.fileExists(atPath: library.resolvedURL(for: item).path, isDirectory: &isDirectory) &&
                !isDirectory.boolValue
        }
    }

    private func unavailable(id: UUID, generation: UUID) {
        guard selection.selectedID == id, selection.generation == generation else { return }
        if player?.currentItem?.id == id { player?.stop() }
        exportStatus = "This result or its file is unavailable. Select another result or run again."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Completed · Saved \(results.count) result(s) to Library")
            if results.isEmpty {
                Text("No saved results are available. Try again.")
            } else {
                Picker("Selected result", selection: Binding(
                    get: { selection.selectedID }, set: { selection.select($0) }
                )) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        Text("Alternative \(index + 1) · \(Self.label(item))").tag(Optional(item.id))
                    }
                }
                if let selected {
                    Text("\(Self.label(selected)) · Library / \(selected.relativePath)")
                    if let item = available {
                        let generation = selection.generation
                        let resolve = { actionTarget(id: item.id, generation: generation) }
                        if let player, item.kind == .audio {
                            HStack {
                                MiniWaveform(item: item, library: library)
                                InlinePlayButton(player: player, item: item, library: library,
                                                 resolveItem: resolve, onUnavailable: { unavailable(id: item.id, generation: generation) })
                            }
                        }
                        if let router {
                            NextActionsRow(router: router, item: item, resolveItem: resolve,
                                           onUnavailable: { unavailable(id: item.id, generation: generation) })
                        }
                        HStack {
                            Button("EXPORT BUNDLE") {
                                guard let target = resolve() else { unavailable(id: item.id, generation: generation); return }
                                export(target)
                            }
                            Button("SHOW IN LIBRARY") {
                                guard let target = resolve() else { unavailable(id: item.id, generation: generation); return }
                                onShowInLibrary(target)
                            }
                        }
                    } else {
                        Text("This result or its file is unavailable. Select another result or run again.")
                    }
                }
            }
            if let exportStatus { Text(exportStatus).textSelection(.enabled) }
        }
        .font(Typography.help)
        .foregroundStyle(Palette.ink.opacity(0.72))
        .onAppear { selection.reset(for: results) }
        .onChange(of: results) { _, newResults in
            if let id = selection.selectedID, player?.currentItem?.id == id { player?.stop() }
            selection.reset(for: newResults)
            exportStatus = nil
        }
        .onChange(of: library.items) { _, _ in
            if let id = selection.selectedID, available == nil, player?.currentItem?.id == id {
                player?.stop()
            }
        }
        .onChange(of: selection.selectedID) { oldID, newID in
            if oldID != newID, let oldID, player?.currentItem?.id == oldID { player?.stop() }
            exportStatus = nil
        }
        .onDisappear {
            if let selectedID = selection.selectedID, player?.currentItem?.id == selectedID { player?.stop() }
        }
    }

    private static func label(_ item: LibraryItem) -> String {
        "\(ResultSelection.role(for: item)) · \(item.title)"
    }

    private func export(_ item: LibraryItem) {
        guard available?.id == item.id else {
            exportStatus = "EXPORT FAILED — Result is unavailable."
            return
        }
        do {
            let url = try library.exportBundle(for: item)
            exportStatus = "EXPORTED — \(url.path)"
        } catch {
            exportStatus = "EXPORT FAILED — \(error.localizedDescription)"
        }
    }
}

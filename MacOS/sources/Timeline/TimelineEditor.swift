import AppKit
import SwiftUI

/// Arrangement editor. Source files are never modified.
struct TimelineEditor: View {
    @ObservedObject var library: LocalLibrary
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    var isActive = true
    @StateObject private var timeline = TimelineModel()
    @State private var session = ArrangementSession()
    @State private var pendingAction: PendingAction?
    @State private var documentError: String?
    @State private var exportTask: Task<URL, Error>?
    @State private var exportStatus: String?

    private enum PendingAction { case open }

    private var timelineDuration: Double {
        max(1, timeline.tracks.map { track in
            let end = track.offset + max(0, track.trimEnd - track.trimStart)
            return end.isFinite ? end : 0
        }.max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TIMELINE").font(.headline)
                Spacer()
                Button("Open…") { request(.open) }
                Button("Save") { _ = save() }
                Button("Save As…") { _ = save(asNew: true) }
                Button("Export Reference…") { exportReference() }.disabled(exportTask != nil)
            }
            HStack {
                Menu("Add audio track") {
                    ForEach(library.items.filter { $0.kind == .audio }) { item in
                        Button(item.title) {
                            timeline.add(libraryID: item.id, title: item.title, url: library.resolvedURL(for: item))
                        }
                    }
                }
                Button(timeline.isPlaying ? "Pause" : "Play") {
                    if timeline.isPlaying {
                        timeline.pause()
                    } else {
                        Task { await timeline.play(stopping: audioPlayer, midiPreview: midiPreview) }
                    }
                }
                .disabled(timeline.isPreparing)
                Button("Stop") { timeline.stop() }
            }
            Text("\(session.url?.lastPathComponent ?? "Untitled")\(session.isDirty(timeline.documentSnapshot) ? " — Unsaved changes" : " — No unsaved changes"). Times are in seconds; trim end is a position in the original audio. Saving does not export audio.")
                .font(.caption)
            if exportTask != nil {
                HStack {
                    ProgressView("Rendering reference…")
                    Button("Cancel Export") { exportTask?.cancel() }
                }
            }
            if let exportStatus { Text(exportStatus).font(.caption).textSelection(.enabled) }
            if let documentError {
                Text(documentError).foregroundStyle(.red).textSelection(.enabled)
            }
            if timeline.isPreparing {
                ProgressView("Preparing timeline…")
            }
            if let error = timeline.error {
                Text(error).foregroundStyle(.red).accessibilityLabel("Timeline error: \(error)")
            }
            if timeline.tracks.isEmpty {
                Text("Add audio from the library to start.").foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(0..<5) { tick in
                    Text("\(timelineDuration * Double(tick) / 4, specifier: "%.1f") s")
                    if tick < 4 { Spacer(minLength: 0) }
                }
            }.font(.caption.monospacedDigit()).accessibilityLabel("Timeline ruler in seconds")
            HStack {
                Slider(value: Binding(get: { timeline.position }, set: { timeline.seek(to: $0) }), in: 0...timelineDuration)
                    .accessibilityLabel("Timeline position in seconds")
                Text("Position \(timeline.position, specifier: "%.2f") s").monospacedDigit()
            }
            .font(.caption)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach($timeline.tracks) { $track in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(track.title).frame(minWidth: 100, alignment: .leading)
                                timeField("Offset", value: Binding(get: { track.offset }, set: { timeline.invalidate(); track.setOffset($0) }))
                                timeField("Trim start", value: Binding(get: { track.trimStart }, set: { timeline.invalidate(); track.setTrimStart($0) }))
                                timeField("Trim end", value: Binding(get: { track.trimEnd }, set: { timeline.invalidate(); track.setTrimEnd($0) }))
                                Text("/ \(track.sourceDuration, specifier: "%.2f") s").font(.caption)
                                Button("Remove") { timeline.remove(id: track.id) }
                            }
                            if (try? track.validate()) == nil {
                                HStack {
                                    Text(track.url == nil ? "Missing or unreadable Library audio. Restore the original item and retry, or remove this track." : "Source is shorter than the saved trim. Fit the trim or remove this track.")
                                        .foregroundStyle(.red)
                                    if track.url == nil {
                                        Button("Retry resolution") {
                                            do { try timeline.retryResolution(from: library) }
                                            catch { documentError = error.localizedDescription }
                                        }
                                    } else {
                                        Button("Fit trim") { timeline.fitTrimToSource(id: track.id) }
                                    }
                                }.font(.caption)
                            }
                            GeometryReader { geometry in
                                let start = track.offset.isFinite ? max(0, track.offset) : 0
                                let length = (track.trimEnd - track.trimStart).isFinite ? max(0, track.trimEnd - track.trimStart) : 0
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.65))
                                        .frame(width: geometry.size.width * min(1, length / timelineDuration))
                                        .offset(x: geometry.size.width * min(1, start / timelineDuration))
                                    Rectangle().fill(Color.primary)
                                        .frame(width: 2)
                                        .offset(x: geometry.size.width * min(1, timeline.position / timelineDuration))
                                }
                            }
                            .frame(height: 18)
                            .accessibilityLabel("\(track.title), offset \(track.offset) seconds, source range \(track.trimStart) to \(track.trimEnd) seconds")
                            HStack {
                                Text("Offset")
                                Slider(value: Binding(get: { track.offset }, set: { timeline.invalidate(); track.setOffset($0) }), in: 0...max(timelineDuration, track.offset + 1))
                                    .accessibilityLabel("\(track.title) offset in seconds")
                                Text("Trim start")
                                Slider(value: Binding(get: { track.trimStart }, set: { timeline.invalidate(); track.setTrimStart($0) }), in: 0...track.sourceDuration)
                                    .accessibilityLabel("\(track.title) trim start in seconds")
                                Text("Trim end")
                                Slider(value: Binding(get: { track.trimEnd }, set: { timeline.invalidate(); track.setTrimEnd($0) }), in: 0...track.sourceDuration)
                                    .accessibilityLabel("\(track.title) trim end in seconds")
                            }.font(.caption)
                            .disabled(track.sourceDuration <= 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .background(TimelineWindowGuard(canClose: confirmNativeClose))
        .confirmationDialog("Save changes to this arrangement?", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible, presenting: pendingAction) { action in
            Button("Save") { decide(.save, action: action) }
            Button("Discard", role: .destructive) { decide(.discard, action: action) }
            Button("Cancel", role: .cancel) { decide(.cancel, action: action) }
        } message: { _ in
            Text("Unsaved timeline edits will be lost if you discard them.")
        }
        .onReceive(audioPlayer.$state) { state in
            if state == .playing { timeline.stop() }
        }
        .onReceive(midiPreview.$state) { state in
            if state == .playing { timeline.stop() }
        }
        .onChange(of: isActive) { _, active in
            if !active { timeline.stop() }
        }
        .onDisappear { timeline.stop(); exportTask?.cancel() }
    }

    private func exportReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for a new reference export directory."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let sources = try timeline.referenceSources(from: library)
            exportStatus = nil
            documentError = nil
            let task = Task.detached(priority: .userInitiated) {
                try ReferenceRenderer.render(sources, in: parent)
            }
            exportTask = task
            Task { @MainActor in
                do {
                    let output = try await task.value
                    exportStatus = "Reference exported: \(output.path)"
                } catch is CancellationError {
                    exportStatus = "Reference export cancelled."
                } catch {
                    documentError = "Unable to export reference: \(error.localizedDescription)"
                }
                exportTask = nil
            }
        } catch {
            documentError = "Unable to export reference: \(error.localizedDescription)"
        }
    }

    private func confirmNativeClose() -> Bool {
        ArrangementSession.mayClose(isDirty: session.isDirty(timeline.documentSnapshot), choose: {
            let alert = NSAlert()
            alert.messageText = "Save changes to this arrangement?"
            alert.informativeText = "Unsaved timeline edits will be lost if you discard them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .save
            case .alertSecondButtonReturn: return .discard
            default: return .cancel
            }
        }, save: { save() })
    }

    private func request(_ action: PendingAction) {
        if session.isDirty(timeline.documentSnapshot) { pendingAction = action }
        else { perform(action) }
    }

    private func decide(_ decision: ArrangementSession.Decision, action: PendingAction) {
        let saved = decision == .save ? save() : false
        if ArrangementSession.mayProceed(decision, saveSucceeded: saved) { perform(action) }
        else { pendingAction = nil }
    }

    private func perform(_ action: PendingAction) {
        pendingAction = nil
        switch action {
        case .open:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try session.open(from: url, into: timeline, library: library)
                documentError = nil
            } catch { documentError = "Unable to open arrangement: \(error.localizedDescription)" }
        }
    }

    @discardableResult private func save(asNew: Bool = false) -> Bool {
        var destination = asNew ? nil : session.url
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Arrangement.json"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        do {
            try session.save(timeline.arrangementDocument(), to: destination!)
            documentError = nil
            return true
        } catch {
            documentError = "Unable to save arrangement: \(error.localizedDescription)"
            return false
        }
    }

    private func timeField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            .frame(width: 85)
        }
    }
}

import SwiftUI

/// Standalone, in-memory audition editor. Source files are never modified.
struct TimelineEditor: View {
    @ObservedObject var library: LocalLibrary
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var midiPreview: MidiPreview
    @StateObject private var timeline = TimelineModel()
    @Environment(\.dismiss) private var dismiss

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
                Button("Close") { dismiss() }
            }
            HStack {
                Menu("Add audio track") {
                    ForEach(library.items.filter { $0.kind == .audio }) { item in
                        Button(item.title) {
                            timeline.add(title: item.title, url: library.resolvedURL(for: item))
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
            Text("Times are in seconds. Trim end is a position in the original audio. Edits are temporary and are not exported or saved.")
                .font(.caption)
            if let error = timeline.error {
                Text(error).foregroundStyle(.red).accessibilityLabel("Timeline error: \(error)")
            }
            if timeline.tracks.isEmpty {
                Text("Add audio from the library to start.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach($timeline.tracks) { $track in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(track.title).frame(minWidth: 100, alignment: .leading)
                                timeField("Offset", value: $track.offset)
                                timeField("Trim start", value: $track.trimStart)
                                timeField("Trim end", value: $track.trimEnd)
                                Text("/ \(track.sourceDuration, specifier: "%.2f") s").font(.caption)
                                Button("Remove") { timeline.remove(id: track.id) }
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
                                }
                            }
                            .frame(height: 18)
                            .accessibilityLabel("\(track.title), offset \(track.offset) seconds, source range \(track.trimStart) to \(track.trimEnd) seconds")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .onReceive(audioPlayer.$state) { state in
            if state == .playing { timeline.stop() }
        }
        .onReceive(midiPreview.$state) { state in
            if state == .playing { timeline.stop() }
        }
        .onDisappear { timeline.stop() }
    }

    private func timeField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption)
            TextField(title, value: Binding(
                get: { value.wrappedValue },
                set: { timeline.invalidate(); value.wrappedValue = $0 }
            ), format: .number.precision(.fractionLength(0...3)))
            .frame(width: 85)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct AnalyzeScreen: View {
    @ObservedObject var viewModel: AnalyzeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Typography.monoLabel("2. ANALYZE — ON-DEVICE MUSIC UNDERSTANDING", size: 11)
                .foregroundColor(Palette.ink.opacity(0.6))
            Text("RHYTHM, KEY, STRUCTURE AND INSTRUMENT ACTIVITY STAY ON THIS MAC.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.ink.opacity(0.55))

            Button(action: pick) {
                Text(viewModel.sourceName.isEmpty ? "SELECT AUDIO" : viewModel.sourceName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.accentBlue, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRunning)

            if viewModel.isRunning {
                ProgressView().controlSize(.small)
            } else if let analysis = viewModel.analysis {
                Text(analysis.compactDescription)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.accentBlue)
                    .textSelection(.enabled)
            } else if let error = viewModel.error {
                Text(error).foregroundColor(Palette.accentRed)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.analyze(url: url)
    }
}

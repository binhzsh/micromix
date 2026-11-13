import SwiftUI

/// Presentation only: each workflow owns importing, validation and drop handling.
struct SourceChooser: View {
    let name: String?
    let hint: String
    let accessibilityHint: String
    var isDisabled = false
    var isLoading = false
    var error: String? = nil
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source audio")
                .font(Typography.heading)
                .foregroundColor(Palette.ink)
            Button(action: choose) {
                DeckPanel(borderColor: name == nil ? Palette.divider : Palette.textBlue) {
                    HStack(spacing: 12) {
                        Image(systemName: name == nil ? "waveform" : "waveform.badge.checkmark")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(name == nil ? Palette.ink.opacity(0.62) : Palette.textBlue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name ?? "SELECT AUDIO")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(name == nil ? Palette.ink : Palette.textBlue)
                                .lineLimit(1)
                            Text(hint).font(Typography.help)
                                .foregroundColor(Palette.ink.opacity(0.76))
                        }
                        Spacer(minLength: 8)
                        Typography.monoLabel(name == nil ? "CHOOSE" : "REPLACE", size: 10)
                            .foregroundColor(Palette.ink)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityHint(accessibilityHint)
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading selected audio…").font(.caption)
                }.foregroundColor(Palette.ink.opacity(0.68))
            }
            if let error {
                Text(error).font(.caption).foregroundColor(Palette.textRed)
            }
        }
    }
}

import SwiftUI

/// Hard-edged, flat TE-style square mode button.
///
/// - Hard 2px border and flat fill.
/// - Active state uses an inverted face plus a strong blue function marker.
struct PanelButton: View {
    let title: String
    let index: Int
    var isActive: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text("\(index). \(title.uppercased())")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(isActive ? Palette.screenText : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Rectangle()
                    .fill(isActive ? Palette.accentBlue : Color.clear)
                    .frame(width: 38, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isActive ? Palette.ink : Palette.deck)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Palette.ink.opacity(0.85), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [.command])
        .accessibilityLabel("\(title), mode \(index) of 4")
        .accessibilityHint(isActive ? "Selected" : "Switches to \(title.lowercased())")
    }
}

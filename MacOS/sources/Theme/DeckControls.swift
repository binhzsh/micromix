import SwiftUI

/// A lightly recessed control group that keeps each mode's content bounded.
struct DeckPanel<Content: View>: View {
    private let content: Content
    private let borderColor: Color

    init(borderColor: Color = Palette.divider, @ViewBuilder content: () -> Content) {
        self.borderColor = borderColor
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

/// Hardware-style switch shared by the Generate and Transcribe decks.
struct PanelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(configuration.isOn ? Palette.ink : Palette.ink.opacity(0.16))
                        .frame(width: 42, height: 22)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(configuration.isOn ? Palette.accentOrange : Palette.deck)
                        .frame(width: 16, height: 16)
                        .padding(3)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Palette.ink.opacity(0.72), lineWidth: 1)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Consistent enabled, running, and unavailable treatment for major actions.
struct PrimaryActionButton: View {
    let title: String
    let isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(isEnabled ? .white : Palette.ink.opacity(0.42))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isEnabled ? Palette.accentOrange : Palette.ink.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isEnabled ? Palette.ink.opacity(0.85) : Palette.divider, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

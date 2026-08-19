import SwiftUI

/// Hard-edged, flat TE-style square mode button.
///
/// - Hard 2px border, flat fill, darkens on press.
/// - Active state shows a small blue accent dot + underline.
struct PanelButton: View {
    let title: String
    let index: Int
    var isActive: Bool = false
    var action: () -> Void = {}

    @State private var pressed = false

    var body: some View {
        Button(action: {
            pressed = true
            action()
        }) {
            VStack(spacing: 8) {
                Text("\(index). \(title.uppercased())")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 4) {
                    Circle()
                        .fill(isActive ? Palette.accentBlue : Color.clear)
                        .frame(width: 7, height: 7)
                    Rectangle()
                        .fill(isActive ? Palette.accentBlue : Color.clear)
                        .frame(width: 22, height: 2)
                }
                .frame(height: 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Palette.deck)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Palette.ink.opacity(pressed ? 1.0 : 0.8), lineWidth: 2)
            )
            .brightness(pressed ? -0.12 : 0)
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

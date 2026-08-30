import SwiftUI

/// Small functional status LED.
///
/// Colors are function-only (see `LEDColor`): green = connected/play,
/// orange = job running (blinks), red = error/disconnected.
enum LEDColor {
    case green
    case orange
    case red

    var color: Color {
        switch self {
        case .green: return Palette.accentGreen
        case .orange: return Palette.accentOrange
        case .red: return Palette.accentRed
        }
    }
}

struct LED: View {
    let color: LEDColor
    var blinking: Bool = false

    @State private var on = true

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 9, height: 9)
            .opacity(blinking ? (on ? 1 : 0.15) : 1)
            .overlay(
                Circle().stroke(Color.black.opacity(0.25), lineWidth: 1)
            )
            .animation(
                .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                value: on
            )
            .onAppear {
                if blinking { on.toggle() }
            }
    }
}

import SwiftUI

/// Circular rotary knob with an indicator line. Kept in the theme for reuse;
/// not wired to any parameter in v1 (no numeric knobs are strictly needed).
struct Knob: View {
    var value: Double = 0.5   // 0...1
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.ink.opacity(0.08))
                .overlay(Circle().stroke(Palette.ink.opacity(0.8), lineWidth: 1.5))

            // Indicator line
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.ink)
                .frame(width: 2.5, height: size * 0.34)
                .offset(y: -size * 0.09)
                .rotationEffect(.degrees(rotationDegrees))
        }
        .frame(width: size, height: size)
    }

    private var rotationDegrees: Double {
        -135 + (value * 270)
    }
}

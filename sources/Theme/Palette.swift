import SwiftUI

/// Design tokens for the Teenage-Engineering-styled Micromix device.
///
/// Colors follow the approved spec: a warm off-white control deck, a
/// near-black recessed screen, and function-only accent colors (never
/// used for decoration).
enum Palette {
    /// Light control deck / chassis background.
    static let deck = Color(hex: 0xF0EFEA)
    /// Near-black dot-matrix screen panel.
    static let screen = Color(hex: 0x1A1A1A)
    /// Primary text on the light deck.
    static let ink = Color(hex: 0x1C1C1C)
    /// Text on the dark screen.
    static let screenText = Color(hex: 0xFFFFFF)
    /// Dot-matrix green readouts.
    static let matrixGreen = Color(hex: 0x9BE870)
    /// TE orange — record / run / primary action.
    static let accentOrange = Color(hex: 0xFF5C00)
    /// TE blue — active mode indicator.
    static let accentBlue = Color(hex: 0x0090FF)
    /// TE green — play / connected.
    static let accentGreen = Color(hex: 0x00C853)
    /// TE red — error / disconnected.
    static let accentRed = Color(hex: 0xE5352B)

    /// Subtle divider used between deck sections (thin ruled line).
    static let divider = Color(hex: 0xD8D5CC)
}

extension Color {
    /// Initialize from a 24-bit RGB hex value (e.g. `0xFF5C00`).
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

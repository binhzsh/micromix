import SwiftUI

/// Typography helpers for the Micromix device.
///
/// Per the spec: technical labels are uppercase monospaced (SF Mono),
/// letter-spaced and numbered; editable input fields use SF Pro.
enum Typography {
    /// Technical uppercase monospaced label, letter-spaced.
    static func monoLabel(_ text: String, size: CGFloat = 12) -> Text {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .kerning(1.2)
    }

    /// Large monospaced readout for the dot-matrix screen (elapsed time).
    static func monoReadout(size: CGFloat = 34) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Body / input text font (SF Pro system sans).
    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size)
    }
}

import SwiftUI

/// Typography helpers for the Micromix device.
///
/// Compact technical labels retain the device's monospaced identity;
/// headings, instructions, and editable input use the system sans.
enum Typography {
    /// Compact hardware labels stay legible even when a caller requests tiny type.
    static let minimumLabelSize: CGFloat = 10
    static let labelTracking: CGFloat = 0.4

    static func monoLabel(_ text: String, size: CGFloat = 12) -> Text {
        Text(text.uppercased())
            .font(.system(size: max(size, minimumLabelSize), weight: .medium, design: .monospaced))
            .tracking(labelTracking)
    }

    static let heading: Font = .system(size: 14, weight: .semibold)
    static let label: Font = .system(size: 12, weight: .medium)
    static let help: Font = .system(size: 12)

    /// Large monospaced readout for the dot-matrix screen (elapsed time).
    static func monoReadout(size: CGFloat = 34) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Body / input text font (SF Pro system sans).
    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size)
    }
}

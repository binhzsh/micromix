import Foundation
import Testing
@testable import Micromix

@Suite("Semantic palette contrast")
struct PaletteContrastTests {
    private func luminance(_ hex: UInt32) -> Double {
        func linear(_ value: UInt32) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((hex >> 16) & 255)
            + 0.7152 * linear((hex >> 8) & 255)
            + 0.0722 * linear(hex & 255)
    }

    private func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
        let a = luminance(foreground)
        let b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func blend(_ foreground: UInt32, over background: UInt32, opacity: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let front = Double((foreground >> shift) & 255)
            let back = Double((background >> shift) & 255)
            return UInt32((front * opacity + back * (1 - opacity)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    @Test("text and control boundary tokens contrast against deck and raised panels")
    func semanticColors() {
        // DeckPanel overlays 24% white on the deck; instrument selection overlays 10% blue.
        let panel = blend(0xFFFFFF, over: Palette.deckHex, opacity: 0.24)
        let selectedRow = blend(0x0090FF, over: Palette.deckHex, opacity: 0.10)
        for background: UInt32 in [Palette.deckHex, panel, selectedRow, 0xFFFFFF] {
            for foreground in [Palette.textOrangeHex, Palette.textBlueHex, Palette.textGreenHex, Palette.textRedHex] {
                #expect(contrast(foreground, background) >= 4.5)
            }
            #expect(contrast(Palette.boundaryHex, background) >= 3)
        }
        // Enabled primary button retains the orange brand fill with dark text.
        #expect(contrast(0x1C1C1C, 0xFF5C00) >= 4.5)
        // Instrument selection uses a white checkmark on the semantic blue fill.
        #expect(contrast(0xFFFFFF, Palette.textBlueHex) >= 4.5)
    }
}

import AppKit
import SwiftUI
import Testing
@testable import Micromix

@MainActor
@Suite("Transcribe layout regressions")
struct TranscribeLayoutTests {
    @Test("compact viewport shows the primary action with the instrument filter collapsed")
    func compactViewportWithLongCatalog() throws {
        let catalog = (0..<200).map { "Instrument \($0)" }
        let empty = try render(catalog: [], viewport: true)
        let long = try render(catalog: catalog, viewport: true)

        // The enabled action is the only large orange surface on this screen.
        // Count its pixels inside the initial viewport, not the scrollable content.
        let emptyOrange = orangePixels(empty)
        let longOrange = orangePixels(long)
        #expect(longOrange > 1_000, "The primary action is not visible in the compact viewport")
        #expect(longOrange == emptyOrange, "The catalog changed the initial action layout")

        // A collapsed filter must not render any catalog rows, even for a long list.
        let fullEmpty = try render(catalog: [], viewport: false)
        let fullLong = try render(catalog: catalog, viewport: false)
        #expect(longOrange == orangePixels(fullLong), "The primary action is clipped by the compact viewport")
        #expect(fullLong.tiffRepresentation == fullEmpty.tiffRepresentation,
                "Instrument catalog content appeared before the optional filter was expanded")
    }

    private func render(catalog: [String], viewport: Bool) throws -> NSBitmapImageRep {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-transcribe-layout-\(UUID().uuidString)")
        let model = TranscribeViewModel(
            api: MicromixAPI(baseURL: "http://127.0.0.1:1"),
            library: LocalLibrary(directory: directory)
        )
        model.selection = .init(name: "source.wav", bytes: Data([0]), analysis: nil)
        let screen = TranscribeScreen(viewModel: model, instruments: catalog)
        let view: AnyView = viewport
            ? AnyView(screen.frame(width: 600).fixedSize(horizontal: false, vertical: true)
                .frame(width: 600, height: 380, alignment: .top).clipped())
            : AnyView(screen.frame(width: 600).fixedSize(horizontal: false, vertical: true))
        let renderer = ImageRenderer(content: view.background(Palette.deck))
        renderer.scale = 1
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            Issue.record("Transcribe workspace did not render")
            throw CocoaError(.fileReadCorruptFile)
        }
        return bitmap
    }

    private func orangePixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.9 && color.greenComponent > 0.25
                    && color.greenComponent < 0.48 && color.blueComponent < 0.2
                    && color.alphaComponent > 0.9 {
                    count += 1
                }
            }
        }
        return count
    }
}

import AppKit
import SwiftUI
import Testing
@testable import Micromix

@MainActor
@Suite("Device window regressions")
struct DeviceWindowTests {
    @Test("mode controls are numbered one through four")
    func oneBasedModeNumbers() {
        #expect(DeviceMode.allCases.map(\.displayIndex) == [1, 2, 3, 4])
    }

    @Test("lyrics layout keeps the primary action visible at the default window size")
    func lyricsActionVisible() throws {
        let count = try orangePixelCount(width: 980, height: 700, populated: true)
        #expect(count > 1_000)
    }

    @Test("lyrics layout keeps the primary action visible at the minimum window size")
    func lyricsActionVisibleAtMinimumSize() throws {
        let count = try orangePixelCount(width: 900, height: 640, populated: true)
        #expect(count > 1_000)
    }

    @Test("empty generation input does not present an enabled orange action")
    func emptyGenerateActionIsVisuallyDisabled() throws {
        #expect(try orangePixelCount(width: 980, height: 700, populated: false) < 500)
    }

    private func orangePixelCount(width: CGFloat, height: CGFloat, populated: Bool) throws -> Int {
        let bitmap = try renderBitmap(width: width, height: height, populated: populated)
        return pixelCount(in: bitmap) { color in
            color.redComponent > 0.9
                && color.greenComponent > 0.25
                && color.greenComponent < 0.48
                && color.blueComponent < 0.2
                && color.alphaComponent > 0.9
        }
    }

    private func renderBitmap(width: CGFloat, height: CGFloat, populated: Bool) throws -> NSBitmapImageRep {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-layout-\(UUID().uuidString)")

        let api = MicromixAPI(baseURL: "http://127.0.0.1:1")
        let library = LocalLibrary(directory: directory)
        let generate = GenerateViewModel(api: api, library: library)
        if populated {
            generate.prompt = "A compact test groove"
            generate.useLyrics = true
            generate.lyrics = "[Verse]\nHeadless layout regression"
        }
        let connection = ConnectionMonitor(api: api)
        connection.connected = true

        let view = DeviceWindow(
            generate: generate,
            transcribe: TranscribeViewModel(api: api, library: library),
            analyze: AnalyzeViewModel(),
            library: library,
            reattacher: JobReattacher(api: api, library: library),
            player: AudioPlayer(),
            midiPreview: MidiPreview(),
            connection: connection
        )
        .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            Issue.record("DeviceWindow did not render")
            throw CocoaError(.fileReadCorruptFile)
        }
        return bitmap
    }

    private func pixelCount(
        in bitmap: NSBitmapImageRep,
        matching predicate: (NSColor) -> Bool
    ) -> Int {
        var matchingPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if predicate(color) {
                    matchingPixels += 1
                }
            }
        }
        return matchingPixels
    }
}

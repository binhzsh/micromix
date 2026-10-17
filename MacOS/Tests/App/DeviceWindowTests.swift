import AppKit
import SwiftUI
import Testing
@testable import Micromix

@MainActor
@Suite("Device window regressions")
struct DeviceWindowTests {
    @Test("studio modes are ordered and numbered one through seven")
    func studioModeOrderAndNumbers() {
        let selectable = DeviceMode.allCases.filter(\.isSelectableMode)
        #expect(selectable.map(\.rawValue) == [
            "GENERATE", "REIMAGINE", "ANALYZE", "TRANSCRIBE", "VOCAL SWAP", "STEM SPLIT", "LIBRARY",
        ])
        #expect(selectable.map(\.displayIndex) == [1, 2, 3, 4, 5, 6, 7])
        #expect(DeviceMode.allCases.contains(.guide))
    }

    @Test("lyrics layout keeps the primary action visible at the default window size")
    func lyricsActionVisible() throws {
        let count = try orangePixelCount(width: 980, height: 700, populated: true)
        #expect(count > 1_000)
    }

    @Test("lyrics layout keeps the primary action visible at the minimum window size")
    func lyricsActionVisibleAtMinimumSize() throws {
        let count = try orangePixelCount(width: 900, height: 640, populated: true)
        #expect(count > 1_000, "count=\(count)")
    }

    @Test("empty generation input does not present an enabled orange action")
    func emptyGenerateActionIsVisuallyDisabled() throws {
        #expect(try orangePixelCount(width: 980, height: 700, populated: false) < 500)
    }

    @Test("Reimagine keeps render controls adjacent to musical direction on tall decks")
    func reimagineRenderControlsDoNotDriftToDeckBottom() throws {
        let bottommostOrange = try reimagineOrangeMaximumY(
            localInferenceAvailable: true,
            width: 940,
            height: 900
        )

        #expect(
            bottommostOrange < 560,
            "The render action drifted to the bottom of the deck instead of following musical direction"
        )
    }

    @Test("deck panels render default-coloured labels dark whatever the host appearance is")
    func deckPanelContentIgnoresAHostDarkAppearance() throws {
        // VOCAL SWAP and STEM SPLIT draw their source label and helper text with
        // SwiftUI's default colours. The deck is a fixed light surface, so those
        // must stay dark even on a dark-mode Mac, where they previously rendered
        // white on white and were unreadable.
        let probe = DeckPanel {
            VStack(alignment: .leading, spacing: 8) {
                Typography.monoLabel("SOURCE", size: 11)
                Text("Saves the extracted sound and the remaining audio to Library.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 320, height: 90)
        // The deck sits on the device's opaque light chassis; render it that way
        // so glyph pixels are fully composited.
        .background(Palette.deck)

        let darkHost = try renderDeck(probe, appearance: .dark)
        let lightHost = try renderDeck(probe, appearance: .light)

        #expect(darkPixelCount(in: darkHost) > 150, "dark-host deck text was not dark")
        #expect(darkPixelCount(in: darkHost) == darkPixelCount(in: lightHost))
    }

    private func renderDeck(_ view: some View, appearance: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, appearance))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            Issue.record("deck panel did not render")
            throw CocoaError(.fileReadCorruptFile)
        }
        return bitmap
    }

    /// Counts deck text: the ink labels and the dimmed helper copy, both of which
    /// are well below the light deck and panel surfaces.
    private func darkPixelCount(in bitmap: NSBitmapImageRep) -> Int {
        pixelCount(in: bitmap) { color in
            let luminance = 0.2126 * color.redComponent
                + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent
            return luminance < 0.6 && color.alphaComponent > 0.9
        }
    }

    private func reimagineOrangeMaximumY(
        localInferenceAvailable: Bool,
        width: CGFloat,
        height: CGFloat
    ) throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("micromix-reimagine-flow-\(UUID().uuidString)")
        let api = MicromixAPI(baseURL: "http://127.0.0.1:1")
        let library = LocalLibrary(directory: directory)
        let reattacher = JobReattacher(api: api, library: library)
        let reimagine = ReimagineViewModel(api: api, reattacher: reattacher)
        reimagine.sourceURL = URL(fileURLWithPath: "/tmp/source.wav")
        reimagine.prompt = "Turn this source into a compact synth groove"
        let view = ReimagineScreen(
            viewModel: reimagine,
            localInferenceAvailable: localInferenceAvailable
        )
        .frame(width: width, height: height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            Issue.record("Reimagine workspace did not render")
            throw CocoaError(.fileReadCorruptFile)
        }

        return maximumY(in: bitmap) { color in
            color.redComponent > 0.9
                && color.greenComponent > 0.25
                && color.greenComponent < 0.48
                && color.blueComponent < 0.2
                && color.alphaComponent > 0.9
        }
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
        let reattacher = JobReattacher(api: api, library: library)
        if populated {
            generate.prompt = "A compact test groove"
            generate.useLyrics = true
            generate.lyrics = "[Verse]\nHeadless layout regression"
        }
        let connection = ConnectionMonitor(api: api)
        connection.connected = true
        let router = WorkflowRouter(
            library: library,
            generate: generate,
            reimagine: ReimagineViewModel(api: api, reattacher: reattacher),
            transcribe: TranscribeViewModel(api: api, library: library),
            vocalSwap: SourceProcessingViewModel(operation: .vocalSwap, api: api, reattacher: reattacher),
            stemSplit: SourceProcessingViewModel(operation: .stemSplit, api: api, reattacher: reattacher),
            analyze: AnalyzeViewModel()
        )

        let view = DeviceWindow(
            generate: generate,
            reimagine: ReimagineViewModel(api: api, reattacher: reattacher),
            transcribe: TranscribeViewModel(api: api, library: library),
            vocalSwap: SourceProcessingViewModel(operation: .vocalSwap, api: api, reattacher: reattacher),
            stemSplit: SourceProcessingViewModel(operation: .stemSplit, api: api, reattacher: reattacher),
            analyze: AnalyzeViewModel(),
            library: library,
            reattacher: reattacher,
            player: AudioPlayer(),
            midiPreview: MidiPreview(),
            connection: connection,
            router: router,
            cover: GuidedCoverModel(api: api, reattacher: reattacher),
            remix: GuidedRemixModel(api: api, reattacher: reattacher),
            transcribeStudio: GuidedTranscribeModel(api: api, reattacher: reattacher),
            vocalSwapStudio: GuidedVocalSwapModel(api: api, reattacher: reattacher)
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

    private func maximumY(
        in bitmap: NSBitmapImageRep,
        matching predicate: (NSColor) -> Bool
    ) -> Int {
        var maximumY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if predicate(color) {
                    maximumY = max(maximumY, y)
                }
            }
        }
        return maximumY
    }
}

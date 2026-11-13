import AppKit
import SwiftUI
import Testing
@testable import Micromix

@MainActor
@Suite("Device window regressions")
struct DeviceWindowTests {
    @Test("inspector resolves only an existing Library selection")
    func inspectorSelection() {
        let id = UUID()
        let item = LibraryItem(id: id, kind: .audio, title: "Selected", createdAt: Date(), promptOrSource: "", durationSeconds: nil, relativePath: "audio/example.wav")
        #expect(SessionInspector.selectedItem(id: id, items: [item]) == item)
        #expect(SessionInspector.selectedItem(id: nil, items: [item]) == nil)
        #expect(SessionInspector.selectedItem(id: UUID(), items: [item]) == nil)
    }

    @Test("guide describes walkthroughs separately from executable studios")
    func guideKinds() {
        for tab in WorkflowGuideView.GuideTab.allCases {
            let expected = [WorkflowGuideView.GuideTab.cover, .reimagine, .fromScratch].contains(tab)
            #expect(tab.isWalkthrough == expected)
            #expect(tab.kindDescription.contains(expected ? "steps run separately" : "run the available steps here"))
        }
    }

    @Test("active work identifies its workspace and elapsed time without invented progress")
    func activeWorkDescription() {
        let item = ActiveWorkspaceWork(destination: .workspace(.transcribe), running: true, elapsed: 12.8, cancel: {})
        #expect(item.id == .workspace(.transcribe))
        #expect(item.description == "TRANSCRIBE — running, 12s elapsed")
    }

    @Test("active analysis opens Analyze without an invented timer or cancellation")
    func activeAnalysis() {
        let work = [ActiveWorkspaceWork.analyze(running: true), .analyze(running: false)].filter(\.running)
        #expect(work.count == 1)
        let item = work[0]
        #expect(item.description == "ANALYZE — running")
        #expect(item.cancel == nil)
        var mode = DeviceMode.generate
        var tab = WorkflowGuideView.GuideTab.cover
        item.destination.open(mode: &mode, guideTab: &tab)
        #expect(mode == .analyze)
    }

    @Test("guided work opens its own studio and cancels only its own job")
    func guidedWorkActions() {
        let tabs: [WorkflowGuideView.GuideTab] = [.studio, .remixStudio, .transcribeStudio, .vocalSwapStudio]
        var cancelled: [WorkflowGuideView.GuideTab] = []
        let work = tabs.map { tab in
            ActiveWorkspaceWork(destination: .guide(tab), running: true, elapsed: 1, cancel: { cancelled.append(tab) })
        }
        #expect(Set(work.map(\.id)).count == 4)
        for (index, item) in work.enumerated() {
            var mode = DeviceMode.generate
            var selectedTab = WorkflowGuideView.GuideTab.cover
            item.destination.open(mode: &mode, guideTab: &selectedTab)
            #expect(mode == .guide)
            #expect(selectedTab == tabs[index])
            item.cancel?()
            #expect(cancelled == Array(tabs.prefix(index + 1)))
        }
    }

    @Test("instrument catalog status remains visible alongside cached items")
    func instrumentCatalogStatus() {
        for state in [VoiceCatalogState.loading, .failed, .unavailable] {
            #expect(InstrumentPicker.catalogMessage(state, hasItems: true)?.contains("CACHED") == true)
            #expect(InstrumentPicker.catalogMessage(state, hasItems: false)?.contains("CACHED") == false)
        }
        #expect(InstrumentPicker.catalogMessage(.loaded([]), hasItems: true) == nil)
        #expect(InstrumentPicker.catalogMessage(.loaded([]), hasItems: false) == "INSTRUMENT CATALOG IS EMPTY")
    }

    @Test("recovery feedback distinguishes ongoing and unavailable saved jobs")
    func recoveryFeedback() {
        #expect(ActiveWorkBar.recoveryDescription(.idle) == nil)
        #expect(ActiveWorkBar.recoveryDescription(.recovering(2)) == "Recovering 2 saved job(s)")
        #expect(ActiveWorkBar.recoveryDescription(.pending(1)) == "1 saved job(s) pending recovery")
        #expect(ActiveWorkBar.recoveryDescription(.unavailable(1))?.contains("could not be recovered") == true)
        #expect(ActiveWorkBar.canRetryRecovery(.unavailable(1)))
        #expect(ActiveWorkBar.canRetryRecovery(.missing(1)))
        #expect(!ActiveWorkBar.canRetryRecovery(.recovering(1)))
        #expect(ActiveWorkBar.recoveryDescription(.missing(1))?.contains("unavailable in the local service") == true)
    }

    @Test("active work viewport stays bounded at small and large window heights")
    func activeWorkViewportHeight() {
        #expect(ActiveWorkBar.maximumHeight(windowHeight: 640) == 160)
        #expect(ActiveWorkBar.maximumHeight(windowHeight: 700) == 175)
        #expect(ActiveWorkBar.maximumHeight(windowHeight: 1200) == 200)
        #expect(ActiveWorkBar.maximumHeight(windowHeight: 0) == 0)
    }

    @Test("inspector overlays only when the remaining canvas is narrow")
    func inspectorLayout() {
        #expect(WorkspaceLayout.overlaysInspector(windowWidth: 900, sidebarVisible: true))
        #expect(WorkspaceLayout.overlaysInspector(windowWidth: 980, sidebarVisible: true))
        #expect(!WorkspaceLayout.overlaysInspector(windowWidth: 900, sidebarVisible: false))
        #expect(!WorkspaceLayout.overlaysInspector(windowWidth: 1_200, sidebarVisible: true))
    }

    @Test("persistent workspace menu assigns every mode its command shortcut")
    func workspaceShortcuts() {
        let expected: [(DeviceMode, Character)] = [
            (.generate, "1"), (.reimagine, "2"), (.analyze, "3"),
            (.transcribe, "4"), (.vocalSwap, "5"), (.stemSplit, "6"),
            (.library, "7"), (.timeline, "8"), (.guide, "?"),
        ]
        #expect(DeviceMode.allCases.count == expected.count)
        for (mode, key) in expected {
            #expect(mode.shortcutKey == key)
        }
        #expect(Set(DeviceMode.allCases.map(\.shortcutKey)).count == expected.count)
    }

    @Test("guide has an unnumbered accessibility name")
    func guideAccessibilityName() {
        #expect(DeviceMode.guide.accessibilityName == "GUIDE")
        #expect(DeviceMode.library.accessibilityName == "LIBRARY, mode 7 of 8")
    }

    @Test("window controls move to the persistent header when the sidebar is hidden")
    func windowControlsPlacement() {
        #expect(WorkspaceLayout.windowControlsInHeader(sidebarVisible: false))
        #expect(!WorkspaceLayout.windowControlsInHeader(sidebarVisible: true))
    }

    @Test("window actions dispatch to the corresponding native operation")
    func windowActionDispatch() {
        let target = WindowActionSpy()
        WorkspaceWindowAction.close.perform(on: target)
        WorkspaceWindowAction.minimize.perform(on: target)
        WorkspaceWindowAction.zoom.perform(on: target)
        #expect(target.calls == ["close", "minimize", "zoom"])
    }

    private final class WindowActionSpy: WorkspaceWindowActionTarget {
        var calls: [String] = []
        func closeWorkspaceWindow() { calls.append("close") }
        func minimizeWorkspaceWindow() { calls.append("minimize") }
        func zoomWorkspaceWindow() { calls.append("zoom") }
    }

    @Test("studio modes are ordered and numbered one through eight")
    func studioModeOrderAndNumbers() {
        let selectable = DeviceMode.allCases.filter(\.isSelectableMode)
        #expect(selectable.map(\.rawValue) == [
            "GENERATE", "REIMAGINE", "ANALYZE", "TRANSCRIBE", "VOCAL SWAP", "STEM SPLIT", "LIBRARY", "TIMELINE",
        ])
        #expect(selectable.map(\.displayIndex) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(DeviceMode.allCases.contains(.guide))
    }

    @Test("mode accessibility descriptions use the selectable mode count")
    func modeAccessibilityDescriptions() {
        let selectable = DeviceMode.allCases.filter(\.isSelectableMode)
        for mode in selectable {
            let button = PanelButton(title: mode.rawValue, index: mode.displayIndex)
            #expect(button.accessibilityDescription == "\(mode.rawValue), mode \(mode.displayIndex) of 8")
        }
    }

    @Test("transcribe heading matches its mode number")
    func transcribeHeadingNumber() {
        #expect(TranscribeScreen.heading == "4. TRANSCRIBE — MIDI & LYRICS")
        #expect(TranscribeScreen.heading.hasPrefix("\(DeviceMode.transcribe.displayIndex). "))
    }

    @Test("studio shell renders persistent workspace structure at the default window size")
    func studioShellStructureAtDefaultSize() throws {
        let bitmap = try renderBitmap(width: 980, height: 700, populated: true)
        #expect(darkPixelCount(in: bitmap) > 1_000)
    }

    @Test("studio shell keeps persistent workspace structure at the compact window size")
    func studioShellStructureAtCompactSize() throws {
        let bitmap = try renderBitmap(width: 900, height: 640, populated: true)
        #expect(darkPixelCount(in: bitmap) > 1_000)
    }

    @Test("empty generation input does not present an enabled orange action")
    func emptyGenerateActionIsVisuallyDisabled() throws {
        #expect(try orangePixelCount(width: 980, height: 700, populated: false) < 500)
    }

    @Test("Reimagine keeps render controls adjacent to musical direction on tall decks")
    func reimagineRenderControlsDoNotDriftToDeckBottom() throws {
        let standard = try reimagineOrangeMaximumY(localInferenceAvailable: true, width: 940, height: 700)
        let tall = try reimagineOrangeMaximumY(localInferenceAvailable: true, width: 940, height: 900)
        let taller = try reimagineOrangeMaximumY(localInferenceAvailable: true, width: 940, height: 1_200)
        let disabled = try reimagineOrangeMaximumY(localInferenceAvailable: false, width: 940, height: 700)

        // The source chooser and adaptive form have intrinsic height; their exact
        // pixel positions can change. Extra deck height must not move the action.
        #expect(standard > disabled, "The enabled render action should add orange below the other controls")
        #expect(standard > 0 && standard < 640, "The render action should be visible on a standard deck")
        #expect(tall == standard, "Render action moved from \(standard) to \(tall) on a taller deck")
        #expect(taller == tall, "Render action moved from \(tall) to \(taller) on an even taller deck")
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

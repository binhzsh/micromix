import Testing
@testable import Micromix

@Suite("Local music analysis")
struct LocalMusicAnalyzerTests {
    @Test("summary combines locally extracted musical attributes")
    func compactDescription() {
        let result = LocalMusicAnalysis(
            durationSeconds: 61.25,
            beatsPerMinute: 119.7,
            key: "cSharp minor",
            instruments: ["drum", "vocal"]
        )

        #expect(result.compactDescription == "61.2 SEC  •  120 BPM  •  CSHARP MINOR  •  DRUM+VOCAL")
    }
}

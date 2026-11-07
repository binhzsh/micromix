import Testing
@testable import Micromix

@Suite("Local music analysis")
struct LocalMusicAnalyzerTests {
    @Test("capabilities accurately describe both analyzer paths")
    @MainActor
    func capabilities() {
        let fallback = AnalyzeViewModel.capabilityDescription(supportsMusicUnderstanding: false)
        #expect(fallback.contains("ONLY DURATION"))
        #expect(fallback.contains("STRUCTURE ARE NOT SUPPORTED"))
        let enhanced = AnalyzeViewModel.capabilityDescription(supportsMusicUnderstanding: true)
        #expect(enhanced.contains("RHYTHM, KEY AND INSTRUMENT ACTIVITY"))
        #expect(enhanced.contains("WHEN AVAILABLE"))
        #expect(enhanced.contains("STRUCTURE IS NOT SUPPORTED"))
    }

    @Test("analysis status reflects progress, success and failure")
    @MainActor
    func status() {
        #expect(AnalyzeViewModel.statusLine(isRunning: false, hasAnalysis: false, hasError: false) == "READY — SELECT AUDIO")
        #expect(AnalyzeViewModel.statusLine(isRunning: true, hasAnalysis: false, hasError: false) == "ANALYZING LOCALLY…")
        #expect(AnalyzeViewModel.statusLine(isRunning: false, hasAnalysis: true, hasError: false) == "ANALYSIS COMPLETE — LOCAL")
        #expect(AnalyzeViewModel.statusLine(isRunning: false, hasAnalysis: false, hasError: true) == "ANALYSIS FAILED — SELECT AUDIO")
    }

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

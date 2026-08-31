import Testing
@testable import Micromix

@Suite("Library provenance")
struct ProvenanceTests {
    @Test("copy text includes reproducible job, input, output, and parameters")
    func copyTextIncludesReproductionDetails() {
        let asset = RemoteAsset(
            id: "asset-1",
            filename: "source.wav",
            mediaType: "audio/wav",
            sizeBytes: 12,
            sha256: "abc",
            downloadUrl: "/v1/assets/asset-1"
        )
        let provenance = LibraryProvenance(
            jobID: "job-12345678",
            operation: "generation",
            parameters: ["duration_seconds": .number(30), "preset": .string("turbo")],
            inputs: [RemoteAssetLink(name: "prompt-audio", position: 0, asset: asset)],
            output: RemoteAssetLink(name: "result", position: 1, asset: asset)
        )

        let text = provenance.copyText

        #expect(text.contains("Operation: generation"))
        #expect(text.contains("Job: job-12345678"))
        #expect(text.contains("Output: #2 result — source.wav"))
        #expect(text.contains("#1 prompt-audio — source.wav"))
        #expect(text.contains("duration_seconds: 30"))
        #expect(text.contains("preset: turbo"))
    }
}

import Testing
@testable import Micromix

@Suite("Typography tokens")
struct TypographyTests {
    @Test("compact labels have a readable size and restrained spacing")
    func compactLabels() {
        #expect(Typography.minimumLabelSize >= 10)
        #expect(Typography.labelTracking <= 0.5)
    }
}

import Foundation
import Testing

@Suite("App icon")
struct AppIconTests {
    @Test("application bundle advertises the Micromix icon")
    func bundleAdvertisesMicromixIcon() {
        let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String

        #expect(iconName == "Micromix")
    }
}

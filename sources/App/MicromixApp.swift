import SwiftUI

@main
struct MicromixApp: App {
    @State private var selectedMode: DeviceMode = .generate

    var body: some Scene {
        WindowGroup {
            DeviceWindow(selectedMode: $selectedMode)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 980, height: 700)
    }
}

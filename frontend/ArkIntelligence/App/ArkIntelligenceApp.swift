import SwiftUI
import AppKit

@main
struct ArkIntelligenceApp: App {
    @State private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
    }
}

import SwiftUI

@main
struct ArkIntelligenceApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
    }
}

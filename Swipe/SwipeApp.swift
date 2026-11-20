import SwiftUI

@main
struct SwipeApp: App {
    @StateObject private var engine = DictationEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .onOpenURL { url in
                    engine.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        engine.refreshPermissions()
                    }
                }
        }
    }
}

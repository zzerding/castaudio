import SwiftUI

@main
struct CastAudioApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

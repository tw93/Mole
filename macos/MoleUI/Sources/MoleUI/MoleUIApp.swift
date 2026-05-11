import MoleUICore
import SwiftUI

@main
struct MoleUIApp: App {
    var body: some Scene {
        WindowGroup {
            MoleRootView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

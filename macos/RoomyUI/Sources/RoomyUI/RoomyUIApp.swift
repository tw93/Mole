import RoomyUICore
import SwiftUI

@main
struct RoomyUIApp: App {
    var body: some Scene {
        WindowGroup {
            RoomyRootView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("MoleMenuBar: applicationDidFinishLaunching called")

        // DON'T hide the dock icon for debugging - we want to see console output
        // NSApp.setActivationPolicy(.accessory)
        print("MoleMenuBar: Keeping dock icon visible for debugging")

        // Create the status item with FIXED length first to test
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        NSLog("MoleMenuBar: Created status item with fixed length")

        if let button = statusItem?.button {
            button.title = "🔍 Mole"
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            NSLog("MoleMenuBar: Set button title with icon")
        } else {
            NSLog("MoleMenuBar: ERROR - statusItem.button is nil!")
        }

        // Create and setup the menu bar controller
        if statusItem != nil {
            menuBarController = MenuBarController(statusItem: statusItem!)
            menuBarController?.setup()
            NSLog("MoleMenuBar: Menu bar controller created and setup complete")
        } else {
            NSLog("MoleMenuBar: ERROR - statusItem is nil!")
        }
    }

    @objc func statusBarButtonClicked() {
        menuBarController?.toggleMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.cleanup()
    }
}

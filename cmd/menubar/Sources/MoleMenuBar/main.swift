import AppKit

// Minimal entry point — hand off to AppDelegate for menu bar setup.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

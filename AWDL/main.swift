import Cocoa

// Explicit entry point — required when not using @NSApplicationMain or storyboard.
// Sets up NSApplication, assigns our AppDelegate, then starts the run loop.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

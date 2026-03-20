import AppKit

// Manual AppKit bootstrap keeps lifecycle control in AppDelegate instead of SwiftUI scenes.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

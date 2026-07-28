import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { EDevAppDelegate() }
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

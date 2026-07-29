import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { MTermAppDelegate() }
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

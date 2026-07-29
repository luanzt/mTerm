import AppKit
import SwiftUI

@MainActor
final class EDevAppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = WorkspaceStore()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let content = WorkspaceView()
            .environmentObject(workspace)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "EDev"
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView: content)
        // Do NOT let SwiftUI content drive the window size. Each SwiftTerm pane
        // reports an intrinsic width (~its column count), so by default adding a
        // second pane side-by-side doubles the hosting view's minimum width and
        // AppKit grows the window to fit — an animated resize that sweeps every
        // pane's size and storms the shells with SIGWINCH. With no sizing options
        // the window stays user-controlled and a split just divides existing space.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        workspace.toggleSidebar()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "b")
        toggleSidebarItem.keyEquivalentModifierMask = .command
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        NSApp.mainMenu = mainMenu
    }
}

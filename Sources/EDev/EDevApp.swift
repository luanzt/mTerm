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
            .frame(minWidth: 980, minHeight: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "EDev"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: content)
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

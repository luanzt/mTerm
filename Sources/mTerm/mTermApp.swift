import AppKit
import SwiftUI

@MainActor
final class MTermAppDelegate: NSObject, NSApplicationDelegate {
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
        window.title = "mTerm"
        // Keep the title for Window menu / Mission Control, but don't draw it in
        // the titlebar — the header stays clean.
        window.titleVisibility = .hidden
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
        installTitlebarToggle(in: window)
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

    @objc private func focusPane(_ sender: NSMenuItem) {
        workspace.focusGridPane(at: sender.tag)
    }

    /// Pin the sidebar toggle to the trailing edge of the window titlebar (next
    /// to the "MTerm" title, flush against the window's right edge).
    private func installTitlebarToggle(in window: NSWindow) {
        let button = SidebarToggleButton()
            .environmentObject(workspace)
        let hosting = NSHostingView(rootView: button)
        hosting.frame = NSRect(x: 0, y: 0, width: 36, height: 28)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hosting
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application — macOS does not synthesize this menu because mTerm builds
        // its NSMenu tree manually. In particular, the standard ⌘Q shortcut only
        // exists when an item targeting NSApplication.terminate(_:) is present.
        let applicationMenu = NSMenu(title: "mTerm")
        applicationMenu.addItem(
            NSMenuItem(title: "About mTerm",
                       action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                       keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Hide mTerm", #selector(NSApplication.hide(_:)), "h"))

        let hideOthers = menuItem(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(
            NSMenuItem(title: "Show All",
                       action: #selector(NSApplication.unhideAllApplications(_:)),
                       keyEquivalent: ""))
        applicationMenu.addItem(.separator())

        let quitItem = menuItem("Quit mTerm", #selector(NSApplication.terminate(_:)), "q")
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        addSubmenu(applicationMenu, to: mainMenu)

        // Edit — Copy / Paste / Select All route through the responder chain
        // (nil target) to the focused terminal view, which implements them.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(menuItem("Paste", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Select All", #selector(NSText.selectAll(_:)), "a"))
        addSubmenu(editMenu, to: mainMenu)

        // View — Toggle Sidebar (⌘B).
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "b")
        toggleSidebarItem.keyEquivalentModifierMask = .command
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        addSubmenu(viewMenu, to: mainMenu)

        // Panes — quick-switch ⌘1…⌘6 to the Nth pane in the grid (max 6 panes).
        let panesMenu = NSMenu(title: "Panes")
        for n in 1...6 {
            let item = NSMenuItem(title: "Pane \(n)",
                                  action: #selector(focusPane(_:)),
                                  keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = .command
            item.tag = n - 1
            item.target = self
            panesMenu.addItem(item)
        }
        addSubmenu(panesMenu, to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    /// A menu item with a ⌘-key equivalent and a `nil` target so the action
    /// dispatches down the responder chain.
    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        return item
    }

    private func addSubmenu(_ menu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }
}

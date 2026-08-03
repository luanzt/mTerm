import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class MTermAppDelegate: NSObject, NSApplicationDelegate {
    private let workspace = WorkspaceStore()
    private let settings = AppSettings()
    private let terminalProcesses = TerminalProcessRegistry()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private lazy var agentNotifications = AgentNotificationCoordinator()
    private var cancellables: Set<AnyCancellable> = []
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        agentNotifications.start()
        agentNotifications.onOpenSession = { [weak self] sessionID in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            workspace.openInActivePane(sessionID)
        }
        workspace.onClaudeAttention = { [weak self] session, kind in
            self?.agentNotifications.deliver(.claude(kind), from: session)
        }
        workspace.onCodexAttention = { [weak self] session in
            self?.agentNotifications.deliver(.codex, from: session)
        }
        workspace.onCloseSession = { [weak self] sessionID in
            self?.terminalProcesses.terminate(sessionID)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let content = WorkspaceView()
            .environmentObject(workspace)
            .environmentObject(settings)
            .environmentObject(terminalProcesses)

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

        // Ask for macOS notification permission in context, the first time this
        // installation actually launches Claude or Codex inside mTerm.
        workspace.$claudeSessionIDs
            .combineLatest(workspace.$codexSessionIDs)
            .filter { !$0.isEmpty || !$1.isEmpty }
            .first()
            .sink { [weak self] _, _ in
                self?.agentNotifications.prepareAuthorization()
            }
            .store(in: &cancellables)

        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        agentNotifications.applicationDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminalProcesses.terminateAll(force: true)
        // Release every SwiftTerm view so its PTY descriptors and observers are
        // dismantled before the process exits.
        window?.contentView = nil
        settingsWindow?.contentView = nil
        return .terminateNow
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        workspace.toggleSidebar()
    }

    @objc private func focusPane(_ sender: NSMenuItem) {
        workspace.focusGridPane(at: sender.tag)
    }

    @objc private func createOpenSession(_ sender: NSMenuItem) {
        workspace.createOpenSessionFromFocusedPane(
            asNewPane: sender.keyEquivalentModifierMask.contains(.shift)
                || settings.opensNewTerminalsInSplit)
    }

    @objc private func createWorkspaceSession(_ sender: NSMenuItem) {
        workspace.createWorkspaceSessionFromFocusedPane(
            asNewPane: sender.keyEquivalentModifierMask.contains(.shift)
                || settings.opensNewTerminalsInSplit)
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let applicationVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: applicationVersion ?? "",
            // The package uses the marketing version as CFBundleVersion too.
            // Suppress that duplicate build value so AppKit renders only
            // "Version 1.1.7", not "Version 1.1.7 (1.1.7)".
            .version: "",
        ])
    }

    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            return
        }

        let content = SettingsView()
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSRunningApplication.current.activate(options: [.activateAllWindows])
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
        let aboutItem = NSMenuItem(
            title: "About mTerm",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = self
        applicationMenu.addItem(aboutItem)
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        checkForUpdatesItem.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Check for Updates")
        checkForUpdatesItem.target = updaterController
        applicationMenu.addItem(checkForUpdatesItem)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ",")
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
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

        // File — keyboard terminal creation targets the focused pane. Shift asks
        // for another pane; a full six-pane grid replaces the focused pane.
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(terminalCreationItem(
            "New Terminal",
            #selector(createOpenSession(_:)),
            "n"))
        fileMenu.addItem(terminalCreationItem(
            "New Terminal in Split Pane",
            #selector(createOpenSession(_:)),
            "n",
            modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(terminalCreationItem(
            "New Workspace Terminal",
            #selector(createWorkspaceSession(_:)),
            "t"))
        fileMenu.addItem(terminalCreationItem(
            "New Workspace Terminal in Split Pane",
            #selector(createWorkspaceSession(_:)),
            "t",
            modifiers: [.command, .shift]))
        addSubmenu(fileMenu, to: mainMenu)

        // Edit — Copy / Paste route through the responder chain (nil target) to
        // the focused terminal view, which implements them.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(menuItem("Paste", #selector(NSText.paste(_:)), "v"))
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

    private func terminalCreationItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func addSubmenu(_ menu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }
}

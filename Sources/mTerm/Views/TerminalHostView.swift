import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: SessionRecord
    let isVisible: Bool
    let isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = terminalFont
        terminal.caretColor = .white
        terminal.wantsLayer = true
        // Match the deck's near-black (#0A0C0F) so the terminal blends into the
        // pane body instead of sitting on a pure-black rectangle.
        terminal.layer?.backgroundColor = NSColor(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0F / 255, alpha: 1).cgColor
        context.coordinator.terminal = terminal

        // Start the shell the first time the view has a real (non-zero) size, so
        // the PTY's initial winsize matches the pane and no startup resize occurs
        // (a startup resize makes prompts like powerlevel10k reprint a duplicate
        // line). We drive this off the view's own frame-change notification rather
        // than updateNSView, because SwiftUI does not reliably call updateNSView
        // again once layout assigns the real frame — e.g. when a pane is created by
        // replacing another pane's content — which would leave the shell unstarted
        // and the terminal blank.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments = session.command.isEmpty ? ["-l"] : ["-lc", session.command]
        let directory = session.workingDirectory
        context.coordinator.startShell = { term in
            term.startProcess(executable: shell, args: arguments, currentDirectory: directory)
        }

        terminal.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: terminal,
            queue: .main
        ) { [weak coordinator = context.coordinator, weak terminal] _ in
            guard let coordinator, let terminal else { return }
            coordinator.startShellIfReady(terminal)
        }

        return terminal
    }

    private var terminalFont: NSFont {
        ["MesloLGS NF", "MesloLGS NF Regular", "MesloLGSNF-Regular"]
            .lazy
            .compactMap { NSFont(name: $0, size: 14) }
            .first ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        nsView.isHidden = !isVisible
        // Backup path in case the frame was already real before the observer was
        // installed; the coordinator guards against starting twice.
        context.coordinator.startShellIfReady(nsView)

        // Give keyboard focus to the selected pane's terminal so typing works
        // right after picking a session in the sidebar — without stealing focus
        // while the user is already typing in it (skip when it is already first
        // responder).
        if isFocused, isVisible, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
        if coordinator.didStartProcess {
            nsView.terminate()
        }
    }

    final class Coordinator {
        var terminal: LocalProcessTerminalView?
        var didStartProcess = false
        var frameObserver: NSObjectProtocol?
        var startShell: ((LocalProcessTerminalView) -> Void)?

        func startShellIfReady(_ terminal: LocalProcessTerminalView) {
            guard !didStartProcess,
                  terminal.frame.width > 1, terminal.frame.height > 1 else { return }
            didStartProcess = true
            startShell?(terminal)
        }
    }
}

import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: SessionRecord
    let isVisible: Bool
    let isFocused: Bool
    /// Reports the pane's foreground command (via shell integration): the command
    /// basename while one runs, or nil when the prompt goes idle.
    var onForeground: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = terminalFont
        terminal.caretColor = NSColor(hex: MTermTheme.terminalCaret)
        terminal.wantsLayer = true
        // Match the deck's near-black (#0A0C0F) so the terminal blends into the
        // pane body instead of sitting on a pure-black rectangle.
        terminal.layer?.backgroundColor = NSColor(hex: MTermTheme.terminalBackground).cgColor
        // SwiftTerm's default foreground is a ~54% gray and its default ANSI
        // palette is muted; install our bright foreground + vibrant palette so
        // output isn't washed-out gray. (Colors live in MTermTheme.)
        terminal.nativeForegroundColor = NSColor(hex: MTermTheme.terminalForeground)
        terminal.nativeBackgroundColor = NSColor(hex: MTermTheme.terminalBackground)
        terminal.installColors(MTermTheme.ansiPalette.map { SwiftTerm.Color(hex: $0) })
        context.coordinator.terminal = terminal

        // Listen for the shell-integration marker (OSC 633). SwiftTerm checks
        // registered handlers before its built-in OSC switch, so this needs no
        // fork change. The handler runs off SwiftTerm's feed, so hop to main.
        let report = onForeground
        terminal.getTerminal().registerOscHandler(code: ShellIntegration.oscCode) { payload in
            switch ShellIntegration.parse(payload) {
            case .run(let command): DispatchQueue.main.async { report(command) }
            case .idle:             DispatchQueue.main.async { report(nil) }
            case nil:               break
            }
        }

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
        // Inject the zsh shell-integration ZDOTDIR (no-op for non-zsh shells) so
        // the pane reports its foreground command. Start from the app's own
        // environment, ensuring TERM is set for the pty.
        var base = ProcessInfo.processInfo.environment
        base["TERM"] = "xterm-256color"
        let environment = ShellIntegration.childEnvironment(shell: shell, base: base)
        context.coordinator.startShell = { term in
            term.startProcess(executable: shell,
                              args: arguments,
                              environment: environment,
                              currentDirectory: directory)
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

    // MARK: Coordinator

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

private extension NSColor {
    /// 24-bit RGB hex literal, e.g. `NSColor(hex: 0x34D399)`.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

private extension SwiftTerm.Color {
    /// 24-bit RGB hex literal mapped into SwiftTerm's 16-bit-per-channel space.
    convenience init(hex: UInt32) {
        self.init(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257)
    }
}

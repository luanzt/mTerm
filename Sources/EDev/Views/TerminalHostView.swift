import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: SessionRecord
    let isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = terminalFont
        terminal.caretColor = .white
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.terminal = terminal
        // Do NOT start the shell yet: the view is still .zero here (SwiftTerm's
        // default 80x25). Starting now and then getting the real frame would
        // resize the PTY, and prompts like powerlevel10k reprint on that startup
        // SIGWINCH, leaving a stray duplicate prompt line. We wait until the view
        // has its real size (updateNSView) so the shell starts at the right size.
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

        // Start the shell once, only after the view has a real (non-zero) size,
        // so the PTY's initial winsize matches the pane and no startup resize
        // occurs.
        if !context.coordinator.didStartProcess,
           nsView.frame.width > 1, nsView.frame.height > 1 {
            context.coordinator.didStartProcess = true
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let arguments = session.command.isEmpty ? ["-l"] : ["-lc", session.command]
            nsView.startProcess(
                executable: shell,
                args: arguments,
                currentDirectory: session.workingDirectory)
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if coordinator.didStartProcess {
            nsView.terminate()
        }
    }

    final class Coordinator {
        var terminal: LocalProcessTerminalView?
        var didStartProcess = false
    }
}

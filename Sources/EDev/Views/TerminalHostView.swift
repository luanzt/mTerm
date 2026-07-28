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
        terminal.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.black.cgColor

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments = session.command.isEmpty ? ["-l"] : ["-lc", session.command]
        terminal.startProcess(
            executable: shell,
            args: arguments,
            currentDirectory: session.workingDirectory)
        context.coordinator.terminal = terminal
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        nsView.isHidden = !isVisible
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    final class Coordinator {
        var terminal: LocalProcessTerminalView?
    }
}

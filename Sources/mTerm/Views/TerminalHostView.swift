import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: SessionRecord
    let isVisible: Bool
    let isFocused: Bool
    let fontName: String
    let fontSize: Double
    let ansiColors: [UInt32]
    /// Reports the pane's foreground command (via shell integration): the command
    /// basename while one runs, or nil when the prompt goes idle.
    var onForeground: (String?) -> Void = { _ in }
    /// Reports standard OSC 0/2 terminal-title updates. WorkspaceStore accepts
    /// them only while Claude or Codex is the pane's foreground command.
    var onTitleChange: (String) -> Void = { _ in }
    /// Reports standard OSC 7 current-directory updates so the pane header and
    /// sidebar can follow the directory of the live shell.
    var onWorkingDirectoryChange: (String?) -> Void = { _ in }
    /// Reports a trusted Claude Code Notification-hook event received by this
    /// pane's PTY through mTerm's private OSC 777 payload.
    var onClaudeAttention: (ClaudeIntegration.AttentionKind) -> Void = { _ in }
    /// Reports Codex's built-in OSC 9 notification only while Codex is the
    /// foreground process in this pane.
    var onCodexAttention: () -> Void = {}
    /// Reports a submitted response while Claude/Codex owns the terminal. This
    /// is used only for the sidebar's transient working indicator.
    var onAgentInputSubmitted: () -> Void = {}
    /// Selects the owning pane when Finder drops one or more files directly on
    /// its AppKit-backed terminal view.
    var onFileDrop: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = FileDroppableTerminalView(frame: .zero)
        // SwiftTerm installs a standalone NSScroller along the trailing edge.
        // mTerm keeps scrollback available through the terminal's own
        // wheel/trackpad handling, but hides the persistent gray indicator so
        // the pane body stays visually clean.
        terminal.subviews
            .compactMap { $0 as? NSScroller }
            .forEach { $0.isHidden = true }
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
        terminal.installColors(ansiColors.map { SwiftTerm.Color(hex: $0) })
        // Give OSC 8 labels the same lavender used by Claude's other links.
        // Command-hover reveals the link with a stronger blue + underline.
        terminal.linkForegroundColor = NSColor(hex: MTermTheme.terminalLinkForeground)
        terminal.linkHighlightColor = NSColor(hex: MTermTheme.terminalLinkHighlight)
        terminal.linkHighlightMode = .hoverWithModifier
        context.coordinator.terminal = terminal
        context.coordinator.appliedFontName = fontName
        context.coordinator.appliedFontSize = fontSize
        context.coordinator.appliedANSIColors = ansiColors
        context.coordinator.onTerminalTitle = onTitleChange
        context.coordinator.onWorkingDirectoryChange = onWorkingDirectoryChange
        context.coordinator.onAgentInputSubmitted = onAgentInputSubmitted
        context.coordinator.onFileDrop = onFileDrop
        terminal.onFileDrop = { [weak coordinator = context.coordinator, weak terminal] urls in
            DispatchQueue.main.async {
                guard let coordinator, let terminal else { return }
                coordinator.receiveDroppedFiles(urls, in: terminal)
            }
        }
        terminal.processDelegate = context.coordinator
        context.coordinator.keyDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak terminal] event in
            guard let terminal,
                  terminal.window?.firstResponder === terminal else {
                return event
            }
            if TerminalKeyboardInput.isAgentSubmission(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                foregroundCommand: context.coordinator.foregroundCommand
            ) {
                context.coordinator.onAgentInputSubmitted()
            }
            guard let input = TerminalKeyboardInput.shiftEnter(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) else { return event }
            terminal.send(input)
            return nil
        }

        // Listen for the shell-integration marker (OSC 633). SwiftTerm checks
        // registered handlers before its built-in OSC switch, so this needs no
        // fork change. The handler runs off SwiftTerm's feed, so hop to main.
        let report = onForeground
        terminal.getTerminal().registerOscHandler(code: ShellIntegration.oscCode) { payload in
            switch ShellIntegration.parse(payload) {
            case .run(let command):
                context.coordinator.foregroundCommand = command
                DispatchQueue.main.async { report(command) }
            case .idle:
                context.coordinator.foregroundCommand = nil
                DispatchQueue.main.async { report(nil) }
            case nil:               break
            }
        }
        let reportAttention = onClaudeAttention
        terminal.getTerminal().registerOscHandler(code: ClaudeIntegration.oscCode) { payload in
            guard let kind = ClaudeIntegration.parse(payload) else { return }
            DispatchQueue.main.async { reportAttention(kind) }
        }
        let reportCodexAttention = onCodexAttention
        terminal.getTerminal().registerOscHandler(code: CodexIntegration.oscCode) { payload in
            guard CodexIntegration.shouldReportAttention(
                payload,
                foregroundCommand: context.coordinator.foregroundCommand
            ) else {
                return
            }
            DispatchQueue.main.async { reportCodexAttention() }
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
        // Start from the app's environment, replace any inherited terminal
        // identity with mTerm's, and advertise true-color + OSC 8 hyperlink
        // support. This lets capable CLIs render compact clickable labels instead
        // of fallback text such as "#2761 (https://…)".
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let base = ShellIntegration.terminalBaseEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            appVersion: appVersion)
        // Inject the zsh shell-integration ZDOTDIR (no-op for non-zsh shells) so
        // the pane reports its foreground command.
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
        NSFont(name: fontName, size: CGFloat(fontSize))
            ?? NSFont.monospacedSystemFont(
                ofSize: CGFloat(fontSize),
                weight: .regular)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        nsView.isHidden = !isVisible
        context.coordinator.onTerminalTitle = onTitleChange
        context.coordinator.onWorkingDirectoryChange = onWorkingDirectoryChange
        context.coordinator.onAgentInputSubmitted = onAgentInputSubmitted
        context.coordinator.onFileDrop = onFileDrop
        if context.coordinator.appliedFontName != fontName
            || context.coordinator.appliedFontSize != fontSize {
            nsView.font = terminalFont
            context.coordinator.appliedFontName = fontName
            context.coordinator.appliedFontSize = fontSize
        }
        if context.coordinator.appliedANSIColors != ansiColors {
            nsView.installColors(ansiColors.map { SwiftTerm.Color(hex: $0) })
            context.coordinator.appliedANSIColors = ansiColors
        }
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
        coordinator.cancelPendingTitleUpdate()
        nsView.processDelegate = nil
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
        if let monitor = coordinator.keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.keyDownMonitor = nil
        }
        if coordinator.didStartProcess {
            nsView.terminate()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var terminal: LocalProcessTerminalView?
        var didStartProcess = false
        var frameObserver: NSObjectProtocol?
        var keyDownMonitor: Any?
        var startShell: ((LocalProcessTerminalView) -> Void)?
        var foregroundCommand: String?
        var appliedFontName: String?
        var appliedFontSize: Double?
        var appliedANSIColors: [UInt32]?
        var onTerminalTitle: (String) -> Void = { _ in }
        var onWorkingDirectoryChange: (String?) -> Void = { _ in }
        var onAgentInputSubmitted: () -> Void = {}
        var onFileDrop: () -> Void = {}
        private var pendingTitleUpdate: DispatchWorkItem?

        func startShellIfReady(_ terminal: LocalProcessTerminalView) {
            guard !didStartProcess,
                  terminal.frame.width > 1, terminal.frame.height > 1 else { return }
            didStartProcess = true
            startShell?(terminal)
        }

        func sizeChanged(
            source: LocalProcessTerminalView,
            newCols: Int,
            newRows: Int
        ) {}

        func receiveDroppedFiles(
            _ urls: [URL],
            in terminal: LocalProcessTerminalView
        ) {
            guard !urls.isEmpty else { return }
            onFileDrop()
            terminal.window?.makeFirstResponder(terminal)
            let bracketedPaste = terminal.getTerminal().bracketedPasteMode
            for chunk in TerminalFileDrop.terminalInputChunks(
                for: urls,
                bracketedPaste: bracketedPaste
            ) {
                terminal.send(chunk)
            }
        }

        func setTerminalTitle(
            source: LocalProcessTerminalView,
            title: String
        ) {
            // Claude may animate a spinner in the terminal title while a turn is
            // active. Debounce on the main queue so only a stable conversation
            // title reaches SwiftUI.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pendingTitleUpdate?.cancel()
                let update = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    pendingTitleUpdate = nil
                    onTerminalTitle(title)
                }
                pendingTitleUpdate = update
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.35,
                    execute: update)
            }
        }

        func hostCurrentDirectoryUpdate(
            source: TerminalView,
            directory: String?
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.onWorkingDirectoryChange(directory)
            }
        }

        func processTerminated(
            source: TerminalView,
            exitCode: Int32?
        ) {}

        func cancelPendingTitleUpdate() {
            pendingTitleUpdate?.cancel()
            pendingTitleUpdate = nil
        }
    }
}

enum TerminalKeyboardInput {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// LF is the terminal input produced by Ctrl+J. Agent TUIs use it to insert
    /// a newline without submitting, while an ordinary Return remains CR.
    static func shiftEnter(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> [UInt8]? {
        guard returnKeyCodes.contains(keyCode),
              modifierFlags.contains(.shift),
              modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        return [0x0A]
    }

    /// A plain Return submits the current prompt/approval in Claude and Codex.
    /// Modifier-assisted Returns are editor/navigation gestures and must not
    /// make an idle agent look busy.
    static func isAgentSubmission(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        foregroundCommand: String?
    ) -> Bool {
        guard foregroundCommand == "claude" || foregroundCommand == "codex",
              returnKeyCodes.contains(keyCode) else { return false }
        return modifierFlags
            .intersection([.shift, .command, .control, .option])
            .isEmpty
    }
}

/// SwiftUI drop modifiers above an `NSViewRepresentable` do not reliably receive
/// Finder drags because AppKit routes the dragging session to the embedded view.
/// Register the real SwiftTerm view as the destination instead.
final class FileDroppableTerminalView: LocalProcessTerminalView {
    var onFileDrop: ([URL]) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFileDrop(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        Self.fileURLs(from: sender.draggingPasteboard)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]
        return objects?.map { $0 as URL }.filter(\.isFileURL) ?? []
    }
}

enum TerminalFileDrop {
    /// Produces shell arguments but deliberately no newline, so dropping a file
    /// fills the current command line without executing it.
    static func shellInput(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return urls.map { shellEscape($0.path) }.joined(separator: " ") + " "
    }

    /// Programs such as Codex and Claude enable bracketed-paste mode so they can
    /// distinguish pasted paths from ordinary typing. Emit one paste event per
    /// file: image-aware TUIs can attach several images independently, while
    /// shells still receive the same escaped paths and trailing spaces.
    static func terminalInputChunks(for urls: [URL], bracketedPaste: Bool) -> [[UInt8]] {
        guard !urls.isEmpty else { return [] }
        guard bracketedPaste else {
            return [Array(shellInput(for: urls).utf8)]
        }

        return urls.map { url in
            EscapeSequences.bracketedPasteStart
                + Array(shellInput(for: [url]).utf8)
                + EscapeSequences.bracketedPasteEnd
        }
    }

    /// Mirrors iTerm2's default dropped-filename style: keep ordinary paths
    /// visually clean and prefix only shell-significant characters with `\`.
    static func shellEscape(_ value: String) -> String {
        let escapable = "\\ ()\"&'!$<>;|*?[]#`\t{}^+=@~\r\n"
        return escapable.reduce(value) { result, character in
            let literal = String(character)
            return result.replacingOccurrences(of: literal, with: "\\" + literal)
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

import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: SessionRecord
    let isVisible: Bool
    let isFocused: Bool
    let searchController: TerminalSearchController
    /// Streams this session to paired remote clients and applies their grid.
    let remoteControl: RemoteControl
    let isFindBarOpen: Bool
    let fontName: String
    let fontSize: Double
    let ansiColors: [UInt32]
    /// Drives the terminal's foreground/background/cursor colors from the
    /// active theme. Passed in (rather than read statically) so SwiftUI re-runs
    /// updateNSView when the user switches theme.
    let themeID: MTermThemeID
    /// Exact agent conversation to resume after this pane's newly started
    /// interactive shell reports its first idle prompt.
    let restorationIntent: AgentResumeDescriptor?
    /// Reports the pane's foreground command (via shell integration): the command
    /// basename while one runs, or nil when the prompt goes idle.
    var onForeground: (String?) -> Void = { _ in }
    /// Reports standard OSC 0/2 terminal-title updates. WorkspaceStore accepts
    /// them only while Claude, Codex, or OMP is the pane's foreground command.
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
    /// Reports a submitted Claude response. Codex activity is reported by its
    /// TUI-owned terminal-title run state instead of inferred keyboard input.
    var onAgentInputSubmitted: () -> Void = {}
    /// Clears the transient working indicator when the user interrupts a turn.
    var onAgentWorkInterrupted: () -> Void = {}
    /// Transitions the store's pending restore state immediately before the
    /// one-shot command is sent to the shell.
    var onRestorationLaunched: () -> Void = {}
    /// Reports the authoritative UUID emitted by Claude's SessionStart hook.
    var onClaudeSessionIdentity: (UUID) -> Void = { _ in }
    /// Selects the owning pane when Finder drops one or more files directly on
    /// its AppKit-backed terminal view.
    var onFileDrop: () -> Void = {}
    /// Registers the PTY shell with app-owned lifecycle cleanup.
    var onProcessStarted: (pid_t) -> Void = { _ in }
    /// Cleans up any remaining process in this terminal's Unix session.
    var onProcessTeardown: () -> Void = {}

    /// Foreground commands whose TUI owns the normal-buffer transcript.
    static let agentCommands: Set<String> = ["claude", "codex", "omp"]

    func makeCoordinator() -> Coordinator {
        Coordinator(restorationIntent: restorationIntent)
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
        terminal.wantsLayer = true
        Self.applyThemeColors(to: terminal)
        // SwiftTerm's default ANSI palette is muted; install our vibrant palette
        // so output isn't washed out. (Colors live in MTermTheme.)
        terminal.installColors(ansiColors.map { SwiftTerm.Color(hex: $0) })
        terminal.linkHighlightMode = .hoverWithModifier
        context.coordinator.terminal = terminal
        searchController.terminalView = terminal
        remoteControl.register(terminal, for: session.id)
        context.coordinator.unregisterRemote = { [weak remoteControl, weak terminal, id = session.id] in
            MainActor.assumeIsolated {
                guard let remoteControl, let terminal else { return }
                remoteControl.unregister(terminal, for: id)
            }
        }
        context.coordinator.appliedFontName = fontName
        context.coordinator.appliedFontSize = fontSize
        context.coordinator.appliedThemeID = themeID
        context.coordinator.appliedANSIColors = ansiColors
        context.coordinator.onTerminalTitle = onTitleChange
        context.coordinator.onWorkingDirectoryChange = onWorkingDirectoryChange
        context.coordinator.onAgentInputSubmitted = onAgentInputSubmitted
        context.coordinator.onAgentWorkInterrupted = onAgentWorkInterrupted
        context.coordinator.onRestorationLaunched = onRestorationLaunched
        context.coordinator.onClaudeSessionIdentity = onClaudeSessionIdentity
        context.coordinator.onFileDrop = onFileDrop
        context.coordinator.onProcessTeardown = onProcessTeardown
        terminal.onFileDrop = { [weak coordinator = context.coordinator, weak terminal] urls in
            DispatchQueue.main.async {
                guard let coordinator, let terminal else { return }
                coordinator.receiveDroppedFiles(urls, in: terminal)
            }
        }
        terminal.onImagePaste = { [weak coordinator = context.coordinator, weak terminal] pasteboard in
            guard let coordinator, let terminal else { return false }
            return coordinator.receiveImagePaste(pasteboard, in: terminal)
        }
        terminal.processDelegate = context.coordinator
        // Defer the child PTY winsize while a pane divider is being dragged, then
        // flush the final size once on release. Driven by NotificationCenter (not
        // a SwiftUI binding) so toggling it mid-drag never feeds back into pane
        // layout and trips a SwiftUI AttributeGraph cycle. Window live-resize is
        // handled directly on the view (see FileDroppableTerminalView).
        context.coordinator.observePaneResize(for: terminal)
        context.coordinator.keyDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak terminal] event in
            guard let terminal,
                  terminal.window?.firstResponder === terminal else {
                return event
            }
            // Typing on the Mac takes the pane back from a remote client before
            // the key reaches the PTY at the restored size.
            terminal.noteLocalInteraction()
            let foregroundCommand = context.coordinator.foregroundCommand
            if TerminalKeyboardInput.isAgentSubmission(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                foregroundCommand: foregroundCommand,
                isAgentInputMode: terminal.getTerminal().bracketedPasteMode,
                isClaudeResponseExpected: context.coordinator.isClaudeResponseExpected,
                agentActivationUptime: context.coordinator.agentActivationUptime,
                eventUptime: event.timestamp
            ) {
                context.coordinator.isClaudeResponseExpected = false
                context.coordinator.onAgentInputSubmitted()
            } else if TerminalKeyboardInput.isAgentInterruption(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                foregroundCommand: context.coordinator.foregroundCommand
            ) {
                context.coordinator.isClaudeResponseExpected = false
                context.coordinator.onAgentWorkInterrupted()
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
                context.coordinator.isClaudeResponseExpected = false
                context.coordinator.lastOMPTerminalTitleUpdate = nil
                if Self.agentCommands.contains(command) {
                    context.coordinator.agentActivationUptime = ProcessInfo.processInfo.systemUptime
                } else {
                    context.coordinator.agentActivationUptime = nil
                }
                context.coordinator.foregroundCommand = command
                DispatchQueue.main.async {
                    // Rewrap normal-buffer output while a foreground program owns
                    // the pane (e.g. Metro/yarn logs) so shrinking then widening
                    // does not leave lines clipped. The shell prompt keeps reflow
                    // off (`.idle`) so powerlevel10k does not duplicate its prompt
                    // on resize; alt-screen TUIs are unaffected because their
                    // buffer has no scrollback (reflow stays disabled there).
                    context.coordinator.terminal?.getTerminal().reflowOnResize = true
                    report(command)
                }
            case .idle:
                context.coordinator.foregroundCommand = nil
                context.coordinator.lastOMPTerminalTitleUpdate = nil
                context.coordinator.agentActivationUptime = nil
                context.coordinator.isClaudeResponseExpected = false
                DispatchQueue.main.async {
                    context.coordinator.terminal?.getTerminal().reflowOnResize = false
                    report(nil)
                    guard let input = context.coordinator.restoreCommandCoordinator
                        .takeCommandOnFirstShellIdle() else { return }
                    context.coordinator.onRestorationLaunched()
                    context.coordinator.terminal?.send(input)
                }
            case nil:               break
            }
        }
        let reportAttention = onClaudeAttention
        let reportClaudeTurnStarted = onAgentInputSubmitted
        let reportClaudeTurnCompleted = onAgentWorkInterrupted
        terminal.getTerminal().registerOscHandler(code: ClaudeIntegration.oscCode) { payload in
            if let sessionID = ClaudeIntegration.sessionID(
                from: payload,
                foregroundCommand: context.coordinator.foregroundCommand
            ) {
                DispatchQueue.main.async {
                    context.coordinator.onClaudeSessionIdentity(sessionID)
                }
            } else if let kind = ClaudeIntegration.parse(payload) {
                DispatchQueue.main.async {
                    context.coordinator.isClaudeResponseExpected = kind.expectsUserResponse
                    reportAttention(kind)
                }
            } else if context.coordinator.foregroundCommand == "claude",
                      ClaudeIntegration.isTurnStarted(payload) {
                DispatchQueue.main.async {
                    context.coordinator.isClaudeResponseExpected = false
                    reportClaudeTurnStarted()
                }
            } else if context.coordinator.foregroundCommand == "claude",
                      ClaudeIntegration.isTurnCompleted(payload) {
                DispatchQueue.main.async {
                    context.coordinator.isClaudeResponseExpected = false
                    reportClaudeTurnCompleted()
                }
            }
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
        let arguments = ["-l"]
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
            var isDirectory: ObjCBool = false
            let directoryExists = FileManager.default.fileExists(
                atPath: directory,
                isDirectory: &isDirectory)
            let launchDirectory = directoryExists && isDirectory.boolValue
                ? directory
                : FileManager.default.homeDirectoryForCurrentUser.path
            term.startProcess(executable: shell,
                              args: arguments,
                              environment: environment,
                              currentDirectory: launchDirectory)
            onProcessStarted(term.process.shellPid)
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
        context.coordinator.onAgentWorkInterrupted = onAgentWorkInterrupted
        context.coordinator.onRestorationLaunched = onRestorationLaunched
        context.coordinator.onClaudeSessionIdentity = onClaudeSessionIdentity
        context.coordinator.onFileDrop = onFileDrop
        context.coordinator.onProcessTeardown = onProcessTeardown
        if context.coordinator.appliedFontName != fontName
            || context.coordinator.appliedFontSize != fontSize {
            nsView.font = terminalFont
            context.coordinator.appliedFontName = fontName
            context.coordinator.appliedFontSize = fontSize
            (nsView as? FileDroppableTerminalView)?.cellSizeDidChange()
        }
        if context.coordinator.appliedANSIColors != ansiColors {
            nsView.installColors(ansiColors.map { SwiftTerm.Color(hex: $0) })
            context.coordinator.appliedANSIColors = ansiColors
        }
        if context.coordinator.appliedThemeID != themeID {
            Self.applyThemeColors(to: nsView)
            context.coordinator.appliedThemeID = themeID
        }
        // Backup path in case the frame was already real before the observer was
        // installed; the coordinator guards against starting twice.
        context.coordinator.startShellIfReady(nsView)

        // Give keyboard focus to the selected pane's terminal so typing works
        // right after picking a session in the sidebar — without stealing focus
        // while the user is already typing in it (skip when it is already first
        // responder).
        // While the find bar owns keyboard focus, do not yank first responder
        // back to the terminal; the normal re-render restores it on close.
        if isFocused, isVisible, !isFindBarOpen,
           let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    static func applyThemeColors(to terminal: LocalProcessTerminalView) {
        terminal.caretColor = NSColor(hex: MTermTheme.terminalCaret)
        terminal.nativeForegroundColor = NSColor(hex: MTermTheme.terminalForeground)
        terminal.nativeBackgroundColor = NSColor(hex: MTermTheme.terminalBackground)
        terminal.layer?.backgroundColor = NSColor(hex: MTermTheme.terminalBackground).cgColor
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.cancelPendingTitleUpdate()
        nsView.processDelegate = nil
        coordinator.unregisterRemote()
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
        coordinator.paneResizeObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        coordinator.paneResizeObservers = []
        if let monitor = coordinator.keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.keyDownMonitor = nil
        }
        if coordinator.didStartProcess {
            coordinator.onProcessTeardown()
            nsView.terminate()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let restoreCommandCoordinator: TerminalRestoreCommandCoordinator
        var terminal: LocalProcessTerminalView?
        var didStartProcess = false
        var frameObserver: NSObjectProtocol?
        var unregisterRemote: () -> Void = {}
        var keyDownMonitor: Any?
        var startShell: ((LocalProcessTerminalView) -> Void)?
        var foregroundCommand: String?
        var agentActivationUptime: TimeInterval?
        var isClaudeResponseExpected = false
        var appliedFontName: String?
        var appliedFontSize: Double?
        var appliedANSIColors: [UInt32]?
        var appliedThemeID: MTermThemeID?
        var paneResizeObservers: [NSObjectProtocol] = []
        var onTerminalTitle: (String) -> Void = { _ in }
        var onWorkingDirectoryChange: (String?) -> Void = { _ in }
        var onAgentInputSubmitted: () -> Void = {}
        var onAgentWorkInterrupted: () -> Void = {}
        var onRestorationLaunched: () -> Void = {}
        var onClaudeSessionIdentity: (UUID) -> Void = { _ in }
        var onFileDrop: () -> Void = {}
        var onProcessTeardown: () -> Void = {}
        private var pendingTitleUpdate: DispatchWorkItem?
        /// OMP animates its working separator every 80 ms. Keep the last parsed
        /// semantic update so spinner-frame-only title changes never redraw SwiftUI.
        var lastOMPTerminalTitleUpdate: OMPIntegration.TerminalTitleUpdate?

        init(restorationIntent: AgentResumeDescriptor?) {
            restoreCommandCoordinator = TerminalRestoreCommandCoordinator(
                intent: restorationIntent)
            super.init()
        }

        func startShellIfReady(_ terminal: LocalProcessTerminalView) {
            guard !didStartProcess,
                  terminal.frame.width > 1, terminal.frame.height > 1 else { return }
            didStartProcess = true
            startShell?(terminal)
        }

        /// Subscribe this terminal to pane-divider drag notifications so it defers
        /// child PTY winsize updates for the duration of the drag and flushes the
        /// final size once on release.
        func observePaneResize(for terminal: LocalProcessTerminalView) {
            // queue: nil delivers synchronously on the posting (main) thread, so
            // deferral is armed before the drag's first resize reaches the PTY.
            let center = NotificationCenter.default
            let began = center.addObserver(
                forName: .mtermPaneResizeBegan, object: nil, queue: nil
            ) { [weak terminal] _ in
                terminal?.defersProcessWindowSizeUpdates = true
            }
            let ended = center.addObserver(
                forName: .mtermPaneResizeEnded, object: nil, queue: nil
            ) { [weak terminal] _ in
                terminal?.defersProcessWindowSizeUpdates = false
            }
            paneResizeObservers = [began, ended]
        }

        /// Runs once the new winsize reaches the PTY. Agent TUIs answer that
        /// SIGWINCH by clearing scrollback (ED3) and replaying the transcript;
        /// SwiftTerm keeps a scrolled-back viewport pinned through the replay,
        /// stranding it at the top of history. The row being read is erased by
        /// the replay anyway, so follow the bottom instead.
        func sizeChanged(
            source: LocalProcessTerminalView,
            newCols: Int,
            newRows: Int
        ) {
            guard let foregroundCommand,
                  TerminalHostView.agentCommands.contains(foregroundCommand) else { return }
            source.scroll(toPosition: 1)
        }

        func receiveDroppedFiles(
            _ urls: [URL],
            in terminal: LocalProcessTerminalView
        ) {
            guard !urls.isEmpty else { return }
            onFileDrop()
            terminal.window?.makeFirstResponder(terminal)
            for chunk in TerminalFileDrop.terminalInputChunks(
                for: urls,
                bracketedPaste: terminal.getTerminal().bracketedPasteMode,
                foregroundCommand: foregroundCommand
            ) {
                terminal.send(chunk)
            }
        }

        func receiveImagePaste(
            _ pasteboard: NSPasteboard,
            in terminal: LocalProcessTerminalView
        ) -> Bool {
            guard TerminalImagePaste.shouldHandle(
                pasteboard,
                foregroundCommand: foregroundCommand
            ) else {
                return false
            }
            guard let imageURL = TerminalImagePaste.materializeImage(from: pasteboard) else {
                // The paste is still consumed: delegating to SwiftTerm here
                // would forward the stale file URL or string that just failed.
                return true
            }
            terminal.window?.makeFirstResponder(terminal)
            // Route the materialized image through the same channel as a file
            // drop: OMP receives the raw bracketed path it tests exactly, while
            // Codex receives the shell-escaped path in its composer just as a
            // dropped image file would.
            for chunk in TerminalFileDrop.terminalInputChunks(
                for: [imageURL],
                bracketedPaste: terminal.getTerminal().bracketedPasteMode,
                foregroundCommand: foregroundCommand
            ) {
                terminal.send(chunk)
            }
            return true
        }

        func setTerminalTitle(
            source: LocalProcessTerminalView,
            title: String
        ) {
            // Codex's mTerm-scoped title and OMP's native title contain stable,
            // TUI-owned run state. Deliver transitions in feed order so a queued
            // working update cannot land after the TUI becomes idle.
            if foregroundCommand == "codex" {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    pendingTitleUpdate?.cancel()
                    pendingTitleUpdate = nil
                    onTerminalTitle(title)
                }
                return
            }
            if foregroundCommand == "omp" {
                guard let update = OMPIntegration.parseTerminalTitle(title),
                      update != lastOMPTerminalTitleUpdate else { return }
                lastOMPTerminalTitleUpdate = update
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    pendingTitleUpdate?.cancel()
                    pendingTitleUpdate = nil
                    onTerminalTitle(title)
                }
                return
            }
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
        ) {
            onProcessTeardown()
        }

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

    /// Claude uses its official `UserPromptSubmit` hook for top-level prompts,
    /// but Return also resumes work after a trusted permission/input event.
    static func isAgentSubmission(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        foregroundCommand: String?,
        isAgentInputMode: Bool = true,
        isClaudeResponseExpected: Bool = false,
        agentActivationUptime: TimeInterval? = nil,
        eventUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let isSubmissionOwner = foregroundCommand == "claude" && isClaudeResponseExpected
        guard isSubmissionOwner,
              isAgentInputMode,
              returnKeyCodes.contains(keyCode) else { return false }
        // Require the input mode enabled by the TUI so the shell Return that
        // launches it cannot be reinterpreted as a submitted prompt.
        // Keep a short transition guard as well because local event monitors and
        // PTY output can be delivered in either order on a fast launch.
        if let agentActivationUptime,
           eventUptime - agentActivationUptime < 0.25 {
            return false
        }
        return modifierFlags
            .intersection([.shift, .command, .control, .option])
            .isEmpty
    }

    /// Claude, Codex, and OMP use Escape or Ctrl-C to interrupt an active turn.
    /// That transition can remain inside the TUI, so shell foreground tracking
    /// and lifecycle channels do not reliably observe it.
    static func isAgentInterruption(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        foregroundCommand: String?
    ) -> Bool {
        guard ["claude", "codex", "omp"].contains(foregroundCommand) else {
            return false
        }

        let modifiers = modifierFlags.intersection([.shift, .command, .control, .option])
        if keyCode == 53 { // Escape
            return modifiers.isEmpty
        }
        return keyCode == 8 && modifiers == .control // Ctrl-C
    }
}

/// SwiftUI drop modifiers above an `NSViewRepresentable` do not reliably receive
/// Finder drags because AppKit routes the dragging session to the embedded view.
/// Register the real SwiftTerm view as the destination instead.
final class FileDroppableTerminalView: LocalProcessTerminalView {
    var onFileDrop: ([URL]) -> Void = { _ in }
    var onImagePaste: (NSPasteboard) -> Bool = { _ in false }
    /// Receives every PTY output chunk after the local emulator consumed it,
    /// so a snapshot taken between chunks never misses or repeats bytes.
    var onOutput: (ArraySlice<UInt8>) -> Void = { _ in }
    /// Called before local keyboard/mouse input reaches a remote-pinned grid.
    var onLocalInteraction: () -> Void = {}
    /// Called whenever the emulator's columns or rows change, from any cause
    /// (pane layout, window resize, font, pin).
    var onGridChange: () -> Void = {}
    private(set) var isCursorHidden = false
    /// Normal-buffer cursor when the alternate screen was entered; DECSC
    /// saved it there and `?1049l` restores it. SwiftTerm keeps the normal
    /// buffer internal while the alternate screen is active.
    private(set) var normalCursorAtAlternateSwitch: (x: Int, y: Int)?
    /// The size SwiftUI/AppKit last asked for; restored when the pin ends.
    private var requestedSize: NSSize = .zero
    private var reportedGrid = (cols: 0, rows: 0)

    /// While set, the terminal grid follows a remote client instead of the pane
    /// frame. Applying it resizes the emulator and the child PTY synchronously.
    var pinnedGrid: RemoteGrid? {
        didSet {
            guard pinnedGrid != oldValue else { return }
            clipHostIfPinned()
            setFrameSize(requestedSize)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        requestedSize = frame.size
        reportedGrid = (getTerminal().cols, getTerminal().rows)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        requestedSize = frame.size
        reportedGrid = (getTerminal().cols, getTerminal().rows)
        registerForDraggedTypes([.fileURL])
    }

    override func setFrameSize(_ newSize: NSSize) {
        requestedSize = newSize
        defer { reportGridChangeIfNeeded() }
        guard let pinnedGrid, let metrics = cellMetrics else {
            super.setFrameSize(newSize)
            return
        }
        // Half a cell of slack keeps SwiftTerm's floor(size / cell) on the
        // pinned grid despite floating-point rounding.
        let pinned = NSSize(
            width: metrics.cell.width * (CGFloat(pinnedGrid.columns) + 0.5) + metrics.scrollerWidth,
            height: metrics.cell.height * (CGFloat(pinnedGrid.rows) + 0.5))
        if superview?.isFlipped == false {
            setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.maxY - pinned.height))
        }
        super.setFrameSize(pinned)
    }

    /// A font change alters the cell size: re-derive a pinned frame, and
    /// report the grid SwiftTerm recomputed for an unpinned one.
    func cellSizeDidChange() {
        if pinnedGrid != nil {
            setFrameSize(requestedSize)
        } else {
            reportGridChangeIfNeeded()
        }
    }

    private func reportGridChangeIfNeeded() {
        let terminal = getTerminal()
        let grid = (cols: terminal.cols, rows: terminal.rows)
        guard grid != reportedGrid else { return }
        reportedGrid = grid
        onGridChange()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // A pin applied before SwiftUI inserted the view (remote-created
        // sessions) had no host view to clip yet.
        clipHostIfPinned()
    }

    /// A pinned grid can exceed the pane; SwiftUI shape clipping does not
    /// reliably clip AppKit-backed views, so clip at the host view.
    private func clipHostIfPinned() {
        guard pinnedGrid != nil, let superview else { return }
        superview.wantsLayer = true
        superview.layer?.masksToBounds = true
    }

    override func bufferActivated(source: Terminal) {
        // Entering the alternate screen copies the normal cursor into it.
        normalCursorAtAlternateSwitch = source.isCurrentBufferAlternate
            ? (source.buffer.x, source.buffer.y)
            : nil
        super.bufferActivated(source: source)
    }

    /// SwiftTerm keeps its cell size internal; `getOptimalFrameSize()` is
    /// exactly cell × grid plus the width reserved for a visible scroller.
    private var cellMetrics: (cell: CGSize, scrollerWidth: CGFloat)? {
        let terminal = getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        let scrollerWidth = subviews
            .compactMap { $0 as? NSScroller }
            .first { !$0.isHidden }
            .map { NSScroller.scrollerWidth(for: .regular, scrollerStyle: $0.scrollerStyle) } ?? 0
        let optimal = getOptimalFrameSize()
        return (CGSize(width: (optimal.width - scrollerWidth) / CGFloat(terminal.cols),
                       height: optimal.height / CGFloat(terminal.rows)),
                scrollerWidth)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput(slice)
    }

    override func showCursor(source: Terminal) {
        isCursorHidden = false
        super.showCursor(source: source)
    }

    override func hideCursor(source: Terminal) {
        isCursorHidden = true
        super.hideCursor(source: source)
    }

    /// Local typing or clicking takes the session back from a remote client
    /// before the input is delivered at the restored size.
    func noteLocalInteraction() {
        guard pinnedGrid != nil else { return }
        onLocalInteraction()
    }

    override func mouseDown(with event: NSEvent) {
        noteLocalInteraction()
        super.mouseDown(with: event)
    }

    /// Coalesce the child PTY winsize during a window live-resize the same way a
    /// pane-divider drag does: hold intermediate sizes, flush the final one on end.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        defersProcessWindowSizeUpdates = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        defersProcessWindowSizeUpdates = false
    }

    override func paste(_ sender: Any) {
        noteLocalInteraction()
        guard !onImagePaste(.general) else { return }
        super.paste(sender)
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
        noteLocalInteraction()
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

enum TerminalImagePaste {
    private static let supportedFileExtensions: Set<String> = [
        "gif", "jpeg", "jpg", "png", "webp",
    ]

    static func shouldHandle(
        _ pasteboard: NSPasteboard,
        foregroundCommand: String?
    ) -> Bool {
        // SwiftTerm's native paste only forwards clipboard *text*, so a copied
        // bitmap reaches neither OMP nor Codex. Claude reads the OS clipboard
        // itself, so it keeps native paste; OMP and Codex need mTerm to
        // materialize the image and hand over its path.
        (foregroundCommand == "omp" || foregroundCommand == "codex")
            && hasImage(in: pasteboard)
    }

    /// Finder also advertises a generated icon bitmap for copied files. When
    /// file URLs exist, trust their extensions so a non-image file never
    /// attaches its generic Finder icon.
    static func hasImage(in pasteboard: NSPasteboard) -> Bool {
        let fileURLs = FileDroppableTerminalView.fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs.contains(where: isImageFile)
        }
        return clipboardImage(from: pasteboard) != nil
    }

    /// Snapshot the clipboard pixels into an app-owned file before handing the
    /// path to a TUI. Screenshot tools may advertise transient file URLs that
    /// disappear before the foreground process can open them.
    static func materializeImage(from pasteboard: NSPasteboard) -> URL? {
        let fileImage = FileDroppableTerminalView.fileURLs(from: pasteboard)
            .first(where: isImageFile)
            .flatMap { NSImage(contentsOf: $0) }
        guard let pngData = pngData(from: fileImage ?? clipboardImage(from: pasteboard)) else {
            return nil
        }

        let fileName = "mterm-paste-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID()).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    private static func clipboardImage(from pasteboard: NSPasteboard) -> NSImage? {
        let imageTypes = NSImage.imageTypes
            .map { NSPasteboard.PasteboardType($0) }
            .filter { type in type != NSPasteboard.PasteboardType.fileURL }
        guard let type = pasteboard.availableType(from: imageTypes),
              let data = pasteboard.data(forType: type) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func pngData(from image: NSImage?) -> Data? {
        guard let image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

enum TerminalFileDrop {
    /// Produces shell arguments but deliberately no newline, so dropping a file
    /// fills the current command line without executing it.
    static func shellInput(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return urls.map { shellEscape($0.path) }.joined(separator: " ") + " "
    }

    /// OMP detects attachments from a bracketed paste of the raw path. Force
    /// that framing for its safe image paths even before mode 2004 is observed,
    /// and omit shell escaping or trailing whitespace so OMP can test the exact
    /// path. Other programs retain mTerm's shell-oriented behavior.
    static func terminalInputChunks(
        for urls: [URL],
        bracketedPaste: Bool,
        foregroundCommand: String?
    ) -> [[UInt8]] {
        guard !urls.isEmpty else { return [] }
        let bracketOtherFiles = bracketedPaste || foregroundCommand == "omp"
        var chunks: [[UInt8]] = []
        var pendingOtherFiles: [URL] = []

        func appendPendingOtherFiles() {
            guard !pendingOtherFiles.isEmpty else { return }
            if bracketOtherFiles {
                chunks.append(contentsOf: pendingOtherFiles.map { url in
                    EscapeSequences.bracketedPasteStart
                        + Array(shellInput(for: [url]).utf8)
                        + EscapeSequences.bracketedPasteEnd
                })
            } else {
                chunks.append(Array(shellInput(for: pendingOtherFiles).utf8))
            }
            pendingOtherFiles.removeAll(keepingCapacity: true)
        }

        for url in urls {
            guard foregroundCommand == "omp", canPasteImagePathRaw(url) else {
                pendingOtherFiles.append(url)
                continue
            }
            appendPendingOtherFiles()
            chunks.append(
                EscapeSequences.bracketedPasteStart
                    + Array(url.path.utf8)
                    + EscapeSequences.bracketedPasteEnd
            )
        }
        appendPendingOtherFiles()
        return chunks
    }

    private static func canPasteImagePathRaw(_ url: URL) -> Bool {
        guard TerminalImagePaste.isImageFile(url) else { return false }
        let unsafeCharacters = CharacterSet(charactersIn: "\"'`$;&|<>(){}[]*?!#\\")
        return url.path.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20
                && scalar.value != 0x7F
                && !unsafeCharacters.contains(scalar)
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

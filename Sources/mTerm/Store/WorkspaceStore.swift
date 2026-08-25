import AppKit
import Combine
import CoreGraphics
import Foundation

extension Notification.Name {
    /// Posted when a pane-divider drag begins. Terminals start deferring child PTY
    /// winsize updates so the drag does not storm the shell with SIGWINCH.
    static let mtermPaneResizeBegan = Notification.Name("mterm.paneResizeBegan")
    /// Posted when a pane-divider drag ends. Terminals flush the final deferred
    /// winsize to their child exactly once.
    static let mtermPaneResizeEnded = Notification.Name("mterm.paneResizeEnded")
}

@MainActor
final class WorkspaceStore: ObservableObject {
    typealias CodexTitleLookup = @Sendable (UUID) async -> String?
    typealias CodexThreadIDLookup = @Sendable (String, String) async -> UUID?

    @Published private(set) var sessions: [SessionRecord] {
        didSet { durableStateDidChange() }
    }
    @Published private(set) var workspaces: [WorkspaceFolder]
    @Published var selectedSessionID: SessionRecord.ID? {
        didSet { durableStateDidChange() }
    }
    @Published var draggedSessionID: SessionRecord.ID?
    /// Non-nil only when a visible pane header initiated the current session
    /// drag. Sidebar drags keep their existing open/replace semantics.
    @Published private(set) var draggedPaneSessionID: SessionRecord.ID?
    @Published var draggedWorkspaceID: WorkspaceFolder.ID?
    @Published var isSidebarVisible = true {
        didSet { durableStateDidChange() }
    }
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: []) {
        didSet { durableStateDidChange() }
    }
    /// True while the user is dragging a pane divider. Deliberately NOT
    /// `@Published`: terminals defer the child PTY winsize via a NotificationCenter
    /// event (see `beginPaneResize`/`endPaneResize`) rather than a SwiftUI binding,
    /// so mutating it mid-drag cannot feed back into pane layout and trip a SwiftUI
    /// AttributeGraph cycle. It only gates the begin/end transitions.
    private(set) var isResizingPanes = false
    /// Session shown in the pane the cursor most recently hovered. Used as the
    /// target pane when opening a session or creating a terminal from the sidebar.
    @Published var hoveredSessionID: SessionRecord.ID?
    /// The pane whose find bar is currently shown, or nil when no find bar is
    /// open. Set by ⌘F (`showFind`), cleared by Esc/close (`closeFind`) and by
    /// closing/hiding the target pane.
    @Published var findSessionID: SessionRecord.ID?
    /// Sessions whose pane currently has `claude` as its foreground command,
    /// reported via shell integration (see `setForeground`). Drives the agent
    /// icon swap in the sidebar and pane header.
    @Published private(set) var claudeSessionIDs: Set<SessionRecord.ID> = []
    /// Sessions whose foreground command is the Codex CLI. Drives the agent
    /// icon in the sidebar and pane header, requests notification permission in
    /// context, and clears on close.
    @Published private(set) var codexSessionIDs: Set<SessionRecord.ID> = []
    /// Agent sessions currently processing a submitted response. Claude lifecycle
    /// hooks and Codex's TUI-owned `run-state` title drive this state; attention,
    /// interruption, and foreground exit provide authoritative clear boundaries.
    @Published private(set) var agentWorkingSessionIDs: Set<SessionRecord.ID> = []
    /// Validated OSC 0/2 titles emitted by active Claude/Codex processes. Kept
    /// separately so each session's stable "Terminal N" title is restored when
    /// shell integration reports that the pane is idle again.
    @Published private(set) var agentSessionTitles: [SessionRecord.ID: String] = [:]
    /// User-renamed sessions always display their stable title instead of an
    /// agent-supplied transient OSC title.
    private var manuallyRenamedSessionIDs: Set<SessionRecord.ID> = [] {
        didSet { durableStateDidChange() }
    }

    /// Grid to return to when un-maximizing. Non-nil exactly while one pane is
    /// maximized (see `toggleMaximize`). Not `@Published`: it always changes in
    /// lockstep with `grid`, which already drives view updates.
    private var savedGrid: PaneGrid? {
        didSet { durableStateDidChange() }
    }

    private var sessionSequence = 0 {
        didSet { durableStateDidChange() }
    }
    private let sessionsKey = "edev.workspace.sessions"
    private let workspacesKey = "edev.workspace.folders"
    private let defaults: UserDefaults
    private let snapshotStore: WorkspaceSnapshotStore?
    private let codexTitleLookup: CodexTitleLookup
    private let codexThreadIDLookup: CodexThreadIDLookup
    private var allowsSnapshotWrites: Bool
    private var isHydratingSnapshot = true
    private var agentResumeDescriptors: [SessionRecord.ID: AgentResumeDescriptor] = [:] {
        didSet { durableStateDidChange() }
    }
    private var agentRestorationPhases: [SessionRecord.ID: AgentRestorationPhase] = [:]
    private var dragEndMonitor: Any?
    private var codexTitleResolutionTasks: [SessionRecord.ID: Task<Void, Never>] = [:]
    private var codexThreadIDs: [SessionRecord.ID: UUID] = [:]
    private var codexLocatorResolutionTasks: [SessionRecord.ID: Task<Void, Never>] = [:]
    private var codexLocatorNames: [SessionRecord.ID: String] = [:]

    /// App-level side effects stay outside the store; the store resolves the
    /// session before forwarding a trusted agent attention event.
    var onClaudeAttention: ((SessionRecord, ClaudeIntegration.AttentionKind) -> Void)?
    var onCodexAttention: ((SessionRecord) -> Void)?
    var onCloseSession: ((SessionRecord.ID) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        snapshotStore: WorkspaceSnapshotStore? = nil,
        codexTitleLookup: @escaping CodexTitleLookup = {
            await CodexThreadTitleResolver.title(for: $0)
        },
        codexThreadIDLookup: @escaping CodexThreadIDLookup = { name, directory in
            await CodexThreadTitleResolver.threadID(
                forExactName: name,
                workingDirectory: directory)
        }
    ) {
        self.defaults = defaults
        self.snapshotStore = snapshotStore
        self.codexTitleLookup = codexTitleLookup
        self.codexThreadIDLookup = codexThreadIDLookup
        defaults.removeObject(forKey: sessionsKey)   // clear any stale saved state
        let restoredWorkspaces = Self.decode(
            [WorkspaceFolder].self,
            from: defaults,
            key: workspacesKey) ?? []
        workspaces = restoredWorkspaces
        defaults.removeObject(forKey: "edev.workspace.history")

        let hadSnapshotFile = snapshotStore?.containsStoredSnapshot ?? false
        let restoredSnapshot = snapshotStore?.load()?.validated(
            validWorkspaceIDs: Set(restoredWorkspaces.map(\.id)),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        allowsSnapshotWrites = !hadSnapshotFile || restoredSnapshot != nil

        if let restoredSnapshot {
            sessions = restoredSnapshot.sessions.map(\.sessionRecord)
            selectedSessionID = restoredSnapshot.selectedSessionID
            grid = restoredSnapshot.grid.repaired(
                validSessionIDs: sessions.map(\.id),
                fallbackID: restoredSnapshot.selectedSessionID ?? sessions.first?.id)
            savedGrid = restoredSnapshot.savedGrid?.repaired(
                validSessionIDs: sessions.map(\.id),
                fallbackID: nil)
            isSidebarVisible = restoredSnapshot.isSidebarVisible
            sessionSequence = restoredSnapshot.sessionSequence
            manuallyRenamedSessionIDs = Set(
                restoredSnapshot.sessions
                    .filter(\.wasManuallyRenamed)
                    .map(\.id))
            agentResumeDescriptors = Dictionary(
                uniqueKeysWithValues: restoredSnapshot.sessions.compactMap { session in
                    session.activeAgent.map { (session.id, $0) }
                })
            agentRestorationPhases = Dictionary(
                uniqueKeysWithValues: agentResumeDescriptors.keys.map {
                    ($0, AgentRestorationPhase.pending)
                })
        } else {
            sessions = [SessionRecord.shell()]
            selectedSessionID = sessions.first?.id
            grid = selectedSessionID.map(PaneGrid.single) ?? PaneGrid(columns: [])
        }
        isHydratingSnapshot = false
    }

    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var displayedSessions: [SessionRecord] {
        grid.paneIDs.compactMap { id in sessions.first { $0.id == id } }
    }

    func createSession(asNewPane: Bool = false) {
        let session = makeSession()
        addSession(session, asNewPane: asNewPane, replacingPane: focusedPaneSessionID)
    }

    /// ⌘N / ⇧⌘N: create an ungrouped terminal in OPEN SESSIONS. Keyboard
    /// commands always target the focused pane, never the pane merely under the
    /// mouse. A split falls back to replacing that focused pane at the six-pane
    /// limit.
    func createOpenSessionFromFocusedPane(asNewPane: Bool = false) {
        let session = makeSession()
        addSession(session, asNewPane: asNewPane, replacingPane: focusedPaneSessionID)
    }

    /// ⌘T / ⇧⌘T: create another terminal for the workspace owning the focused
    /// pane. There is no project to infer from an ungrouped OPEN SESSIONS pane,
    /// so that case is intentionally a no-op.
    func createWorkspaceSessionFromFocusedPane(asNewPane: Bool = false) {
        guard let focusedID = focusedPaneSessionID,
              let focusedSession = session(for: focusedID),
              let workspaceID = focusedSession.workspaceID,
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return
        }
        let session = makeSession(
            workingDirectory: workspace.path,
            workspaceID: workspace.id)
        addSession(session, asNewPane: asNewPane, replacingPane: focusedID)
    }

    func beginDragging(_ sessionID: SessionRecord.ID) {
        finishDragging()
        draggedSessionID = sessionID
        installDragEndMonitor()
    }

    func beginDraggingPane(_ sessionID: SessionRecord.ID) {
        guard !isMaximized, grid.paneIDs.contains(sessionID) else { return }
        finishDragging()
        draggedSessionID = sessionID
        draggedPaneSessionID = sessionID
        installDragEndMonitor()
    }

    func beginDraggingWorkspace(_ workspaceID: WorkspaceFolder.ID) {
        finishDragging()
        draggedWorkspaceID = workspaceID
        installDragEndMonitor()
    }

    private func installDragEndMonitor() {
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .keyDown]
        ) { [weak self] event in
            let didReleaseMouse = event.type == .leftMouseUp
            let didPressEscape = event.type == .keyDown && event.keyCode == 53
            guard didReleaseMouse || didPressEscape else { return event }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.finishDragging()
            }
            return event
        }
    }

    func finishDragging() {
        if let dragEndMonitor {
            NSEvent.removeMonitor(dragEndMonitor)
            self.dragEndMonitor = nil
        }
        draggedSessionID = nil
        draggedPaneSessionID = nil
        draggedWorkspaceID = nil
    }

    /// Reorders a workspace folder relative to another. `insertAfter` decides
    /// whether the dragged folder lands below the target rather than above it.
    func moveWorkspace(_ id: WorkspaceFolder.ID,
                       relativeTo targetID: WorkspaceFolder.ID,
                       insertAfter: Bool) {
        guard id != targetID,
              let source = workspaces.firstIndex(where: { $0.id == id }),
              let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        var destination = insertAfter ? targetIndex + 1 : targetIndex
        let item = workspaces.remove(at: source)
        if source < destination { destination -= 1 }
        destination = min(max(destination, 0), workspaces.count)
        workspaces.insert(item, at: destination)
        persist()
    }

    /// Changes only the label shown in mTerm. The folder's path and name on
    /// disk remain untouched.
    func renameWorkspace(_ id: WorkspaceFolder.ID, to rawName: String) {
        guard let normalized = Self.normalizedUserLabel(rawName),
              let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        workspaces[index].name = normalized
        persist()
    }

    /// Deletes a workspace and closes all terminals belonging to it.
    func removeWorkspace(_ id: WorkspaceFolder.ID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let workspaceSessions = sessions.filter { $0.workspaceID == id }
        for session in workspaceSessions {
            close(session)
        }
        workspaces.removeAll { $0.id == id }
        persist()
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.message = "Choose a repository or project folder."
        panel.prompt = "Open Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard !workspaces.contains(where: { $0.path == path }) else { return }
        workspaces.append(WorkspaceFolder(path: path))
        persist()
    }

    func createSession(in workspace: WorkspaceFolder, asNewPane: Bool = false) {
        let session = makeSession(workingDirectory: workspace.path, workspaceID: workspace.id)
        addSession(session, asNewPane: asNewPane, replacingPane: focusedPaneSessionID)
    }

    /// Creates a fresh shell beside an existing terminal, inheriting its live
    /// working directory and workspace grouping without duplicating the process.
    func createSessionInSameDirectory(as sourceID: SessionRecord.ID) {
        guard let source = session(for: sourceID) else { return }
        let session = makeSession(
            workingDirectory: source.workingDirectory,
            workspaceID: source.workspaceID)
        let target = grid.paneIDs.contains(sourceID) ? sourceID : activePaneSessionID
        addSession(session, asNewPane: true, replacingPane: target)
    }

    func close(_ session: SessionRecord) {
        guard let index = sessions.firstIndex(of: session) else { return }
        onCloseSession?(session.id)
        savedGrid = nil
        claudeSessionIDs.remove(session.id)
        codexSessionIDs.remove(session.id)
        agentWorkingSessionIDs.remove(session.id)
        agentSessionTitles.removeValue(forKey: session.id)
        manuallyRenamedSessionIDs.remove(session.id)
        agentResumeDescriptors.removeValue(forKey: session.id)
        agentRestorationPhases.removeValue(forKey: session.id)
        if findSessionID == session.id { findSessionID = nil }
        cancelCodexTitleResolution(for: session.id)
        cancelCodexLocatorResolution(for: session.id)
        sessions.remove(at: index)
        grid.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.indices.contains(index)
                ? sessions[index].id : sessions.last?.id
        }
        if grid.isEmpty, let fallback = selectedSessionID {
            grid = PaneGrid.single(fallback)
        }
        if let sel = selectedSessionID, !grid.paneIDs.contains(sel),
           let firstInGrid = grid.paneIDs.first {
            selectedSessionID = firstInGrid
        }
        persist()
    }

    /// Removes `session` from the visible grid without ending it. The session
    /// stays alive in the sidebar and can be reopened; only its pane disappears.
    func hide(_ session: SessionRecord) {
        guard grid.paneIDs.contains(session.id) else { return }
        savedGrid = nil
        grid.remove(session.id)
        if let selected = selectedSessionID, !grid.paneIDs.contains(selected) {
            selectedSessionID = grid.paneIDs.first ?? selectedSessionID
        }
        if findSessionID == session.id { findSessionID = nil }
    }

    /// Opens the find bar on the focused pane. A no-op when nothing is selected.
    func showFind() {
        guard let selectedSessionID else { return }
        findSessionID = selectedSessionID
    }

    /// Closes the find bar for `id` (ignored if a different pane owns it).
    func closeFind(_ id: SessionRecord.ID) {
        if findSessionID == id { findSessionID = nil }
    }

    /// Reorder a session relative to another **within the same section** (both
    /// loose "open sessions", or both children of the same workspace folder).
    /// `insertAfter` drops the dragged session below the target rather than above.
    /// Cross-section drags are ignored so a reorder never yanks a session out of
    /// its folder.
    func moveSession(_ id: SessionRecord.ID,
                     relativeTo targetID: SessionRecord.ID,
                     insertAfter: Bool) {
        guard id != targetID,
              let source = sessions.firstIndex(where: { $0.id == id }),
              let target = sessions.firstIndex(where: { $0.id == targetID }),
              sessions[source].workspaceID == sessions[target].workspaceID else {
            return
        }
        var destination = insertAfter ? target + 1 : target
        let item = sessions.remove(at: source)
        if source < destination { destination -= 1 }
        destination = min(max(destination, 0), sessions.count)
        sessions.insert(item, at: destination)
    }

    /// Quick-switch: focus the Nth pane currently in the grid (0-based, in visual
    /// order left-to-right then top-to-bottom). No-op when out of range. Setting
    /// the selection is enough — `TerminalHostView` moves the keyboard focus.
    func focusGridPane(at index: Int) {
        let ids = grid.paneIDs
        guard ids.indices.contains(index) else { return }
        selectedSessionID = ids[index]
    }

    /// The user-facing ⌘-number assigned to a visible pane. This uses the same
    /// visual ordering as `focusGridPane(at:)`, so the header badge always
    /// describes the shortcut that will actually focus the pane.
    func shortcutNumber(for id: SessionRecord.ID) -> Int? {
        grid.paneIDs.firstIndex(of: id).map { $0 + 1 }
    }

    /// Reported by shell integration when a pane's foreground command changes.
    /// `"claude"` or `"codex"` marks the row with the matching agent icon; any
    /// other command (or `nil` for an idle prompt) clears it. Publishes only on
    /// an actual change.
    func setForeground(_ id: SessionRecord.ID, command: String?) {
        // A new shell command starts a fresh title scope. This also restores the
        // stable title on `precmd` idle after Ctrl-C, `/exit`, or normal exit.
        agentSessionTitles.removeValue(forKey: id)
        if command != "codex" {
            cancelCodexTitleResolution(for: id)
            cancelCodexLocatorResolution(for: id)
        }

        let isClaude = command == "claude"
        if isClaude, !claudeSessionIDs.contains(id) {
            claudeSessionIDs.insert(id)
        } else if !isClaude, claudeSessionIDs.contains(id) {
            claudeSessionIDs.remove(id)
        }

        let isCodex = command == "codex"
        if isCodex, !codexSessionIDs.contains(id) {
            codexSessionIDs.insert(id)
        } else if !isCodex, codexSessionIDs.contains(id) {
            codexSessionIDs.remove(id)
        }

        // Starting an interactive agent does not imply it already has a prompt
        // to process. Submission is reported separately from TerminalHostView.
        agentWorkingSessionIDs.remove(id)
        updateAgentRestorationState(for: id, foregroundCommand: command)
    }

    /// Starts (or resumes) Claude's work through its `UserPromptSubmit` hook.
    /// Codex activity comes from its TUI-owned `run-state` title instead of key
    /// inference, so local commands and approval interactions cannot stick it on.
    func reportAgentInputSubmitted(_ id: SessionRecord.ID) {
        guard claudeSessionIDs.contains(id) else { return }
        agentWorkingSessionIDs.insert(id)
    }

    /// Escape and Ctrl-C interrupt an in-flight Claude/Codex turn and return the
    /// TUI to user input without necessarily producing an attention event.
    func reportAgentWorkInterrupted(_ id: SessionRecord.ID) {
        guard claudeSessionIDs.contains(id) || codexSessionIDs.contains(id) else { return }
        agentWorkingSessionIDs.remove(id)
    }

    func setAgentTitle(_ id: SessionRecord.ID, title rawTitle: String) {
        guard session(for: id) != nil else { return }

        let isClaude = claudeSessionIDs.contains(id)
        let isCodex = codexSessionIDs.contains(id)
        guard isClaude || isCodex else { return }

        var scopedTitle = rawTitle
        if isCodex,
           let update = CodexIntegration.parseTerminalTitle(rawTitle) {
            if update.isWorking {
                agentWorkingSessionIDs.insert(id)
            } else {
                agentWorkingSessionIDs.remove(id)
            }
            guard let conversationTitle = update.conversationTitle else { return }
            scopedTitle = conversationTitle
        }

        if isCodex,
           let threadID = CodexThreadTitleResolver.threadID(from: scopedTitle) {
            recordCodexLocator(for: id, locator: .threadID(threadID))
            cancelCodexLocatorResolution(for: id)
            if !manuallyRenamedSessionIDs.contains(id) {
                resolveCodexTitle(for: id, threadID: threadID)
            }
            return
        }

        guard let title = AgentSessionTitle.normalize(
            scopedTitle,
            strippingLeadingDecoration: isClaude) else {
            return
        }
        if isCodex {
            // Display normalization may collapse whitespace or truncate a long
            // title. Resume identity must instead preserve the exact validated
            // Codex name emitted by the TUI.
            resolveCodexLocator(for: id, exactName: scopedTitle)
            // A real OSC title is a manual `/rename`/`--name` value and wins
            // over any in-flight automatic-title metadata lookup.
            cancelCodexTitleResolution(for: id)
        }
        guard !manuallyRenamedSessionIDs.contains(id),
              agentSessionTitles[id] != title else { return }
        agentSessionTitles[id] = title
    }

    func displayTitle(for session: SessionRecord) -> String {
        if manuallyRenamedSessionIDs.contains(session.id) {
            return session.title
        }
        return agentSessionTitles[session.id] ?? session.title
    }

    /// Rename the stable session title shared by the sidebar, pane header, and
    /// native notification subtitle. A user title takes precedence over future
    /// transient Claude/Codex terminal-title updates for this session.
    func renameSession(_ id: SessionRecord.ID, to rawTitle: String) {
        guard let normalized = Self.normalizedUserLabel(rawTitle),
              let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }

        sessions[index].title = normalized
        manuallyRenamedSessionIDs.insert(id)
        agentSessionTitles.removeValue(forKey: id)
        cancelCodexTitleResolution(for: id)
    }

    private static func normalizedUserLabel(_ rawValue: String) -> String? {
        guard !rawValue.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return nil
        }
        let normalized = rawValue
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(80))
    }

    /// Updates the live shell directory reported through OSC 7. Terminal
    /// programs report a file URL rather than a filesystem path; keep only valid
    /// absolute local paths so an unrelated OSC payload cannot replace the
    /// session's launch/current-directory state.
    func setWorkingDirectory(_ id: SessionRecord.ID, report: String?) {
        guard let path = Self.workingDirectoryPath(from: report),
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].workingDirectory != path else {
            return
        }
        sessions[index].workingDirectory = path
    }

    private static func workingDirectoryPath(from report: String?) -> String? {
        guard let report, !report.isEmpty else { return nil }

        let url: URL
        if report.hasPrefix("/") {
            url = URL(fileURLWithPath: report)
        } else {
            guard let reportedURL = URL(string: report),
                  reportedURL.isFileURL else {
                return nil
            }
            url = reportedURL
        }

        let path = url.standardizedFileURL.path
        return path.hasPrefix("/") ? path : nil
    }

    private func recordCodexLocator(
        for sessionID: SessionRecord.ID,
        locator: CodexResumeLocator
    ) {
        guard codexSessionIDs.contains(sessionID),
              session(for: sessionID) != nil else { return }
        agentRestorationPhases[sessionID] = .acknowledged
        agentResumeDescriptors[sessionID] = .codex(locator: locator)
    }

    private func resolveCodexLocator(
        for sessionID: SessionRecord.ID,
        exactName: String
    ) {
        guard let session = session(for: sessionID),
              codexSessionIDs.contains(sessionID) else { return }

        cancelCodexLocatorResolution(for: sessionID)
        codexLocatorNames[sessionID] = exactName
        if case .codex(.threadID) = agentResumeDescriptors[sessionID] {
            // `/rename` must not downgrade an exact UUID to a name. The metadata
            // lookup can still replace it if this title belongs to a switched
            // thread with a distinct UUID.
            agentRestorationPhases[sessionID] = .acknowledged
        } else {
            recordCodexLocator(for: sessionID, locator: .name(exactName))
        }

        let lookup = codexThreadIDLookup
        let workingDirectory = session.workingDirectory
        codexLocatorResolutionTasks[sessionID] = Task { [weak self] in
            let threadID = await lookup(exactName, workingDirectory)
            guard let self,
                  codexSessionIDs.contains(sessionID),
                  codexLocatorNames[sessionID] == exactName else { return }
            codexLocatorResolutionTasks[sessionID] = nil
            codexLocatorNames[sessionID] = nil
            guard let threadID else { return }
            recordCodexLocator(for: sessionID, locator: .threadID(threadID))
        }
    }

    private func cancelCodexLocatorResolution(for sessionID: SessionRecord.ID) {
        codexLocatorResolutionTasks.removeValue(forKey: sessionID)?.cancel()
        codexLocatorNames.removeValue(forKey: sessionID)
    }

    private func resolveCodexTitle(
        for sessionID: SessionRecord.ID,
        threadID: UUID
    ) {
        if codexThreadIDs[sessionID] != threadID {
            cancelCodexTitleResolution(for: sessionID)
            codexThreadIDs[sessionID] = threadID
        } else if codexTitleResolutionTasks[sessionID] != nil {
            return
        }

        let lookup = codexTitleLookup
        codexTitleResolutionTasks[sessionID] = Task { [weak self] in
            // A resumed thread resolves immediately. A new thread gets its
            // automatic title shortly after the first prompt, so retry with a
            // bounded backoff while Codex remains the foreground process.
            let delays: [UInt64] = [
                0,
                500_000_000,
                1_000_000_000,
                2_000_000_000,
                4_000_000_000,
                8_000_000_000,
                15_000_000_000,
                30_000_000_000,
                60_000_000_000,
            ]

            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard let self,
                      codexSessionIDs.contains(sessionID),
                      codexThreadIDs[sessionID] == threadID else {
                    return
                }
                guard let rawTitle = await lookup(threadID),
                      let title = AgentSessionTitle.normalize(rawTitle) else {
                    continue
                }
                guard codexSessionIDs.contains(sessionID),
                      codexThreadIDs[sessionID] == threadID else {
                    return
                }
                agentSessionTitles[sessionID] = title
                codexTitleResolutionTasks[sessionID] = nil
                return
            }

            if self?.codexThreadIDs[sessionID] == threadID {
                self?.codexTitleResolutionTasks[sessionID] = nil
            }
        }
    }

    private func cancelCodexTitleResolution(for sessionID: SessionRecord.ID) {
        codexTitleResolutionTasks.removeValue(forKey: sessionID)?.cancel()
        codexThreadIDs.removeValue(forKey: sessionID)
    }

    func reportClaudeAttention(
        _ id: SessionRecord.ID,
        kind: ClaudeIntegration.AttentionKind
    ) {
        guard let session = session(for: id) else { return }
        agentWorkingSessionIDs.remove(id)
        onClaudeAttention?(session, kind)
    }

    func reportCodexAttention(_ id: SessionRecord.ID) {
        guard let session = session(for: id) else { return }
        agentWorkingSessionIDs.remove(id)
        onCodexAttention?(session)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func session(for id: SessionRecord.ID) -> SessionRecord? {
        sessions.first { $0.id == id }
    }

    func openSingle(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        savedGrid = nil
        grid = PaneGrid.single(id)
        selectedSessionID = id
    }

    /// True while a single pane is maximized and a prior multi-pane layout is
    /// remembered. Drives the pane header's expand/restore icon.
    var isMaximized: Bool { savedGrid != nil }

    /// Pane header ⤢ button: maximize `id` to fill the deck (remembering the
    /// current grid), or, if already maximized, restore that remembered grid.
    func toggleMaximize(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if savedGrid != nil {
            restoreFromMaximize()
        } else {
            // Nothing to hide when there is only one pane already.
            guard grid.paneIDs.count > 1 else { return }
            savedGrid = grid
            grid = PaneGrid.single(id)
            selectedSessionID = id
        }
    }

    /// Keyboard maximize/restore targets the focused visible pane, matching the
    /// pane used by the other keyboard-driven workspace actions.
    func toggleFocusedPaneMaximize() {
        guard let id = focusedPaneSessionID else { return }
        toggleMaximize(id)
    }

    private func restoreFromMaximize() {
        guard var restored = savedGrid else { return }
        savedGrid = nil
        // A session may have been closed while maximized — drop those panes so
        // the restored layout never references a dead session.
        let live = Set(sessions.map(\.id))
        for paneID in restored.paneIDs where !live.contains(paneID) {
            restored.remove(paneID)
        }
        guard !restored.isEmpty else { return }   // nothing left; keep single view
        grid = restored
        if let selected = selectedSessionID, !restored.paneIDs.contains(selected) {
            selectedSessionID = restored.paneIDs.first
        }
    }

    /// The pane to target for sidebar actions: the pane under the cursor, else
    /// the focused pane, else the first pane. Nil only when the grid is empty.
    private var activePaneSessionID: SessionRecord.ID? {
        if let hovered = hoveredSessionID, grid.paneIDs.contains(hovered) { return hovered }
        if let selected = selectedSessionID, grid.paneIDs.contains(selected) { return selected }
        return grid.paneIDs.first
    }

    /// The keyboard target is the focused/selected visible pane. Falling back to
    /// the first pane only covers transient states before selection catches up.
    private var focusedPaneSessionID: SessionRecord.ID? {
        if let selected = selectedSessionID, grid.paneIDs.contains(selected) { return selected }
        return grid.paneIDs.first
    }

    private func addSession(_ session: SessionRecord,
                            asNewPane: Bool,
                            replacingPane target: SessionRecord.ID?) {
        sessions.append(session)
        if asNewPane {
            showInNewPane(session.id, fallbackTarget: target)
        } else {
            show(session.id, inPaneWith: target)
        }
        persist()
    }

    private func show(_ id: SessionRecord.ID,
                      inPaneWith target: SessionRecord.ID?) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        savedGrid = nil
        // Already visible in some pane: just focus it, don't move it (moving would
        // collapse its current pane).
        if grid.paneIDs.contains(id) { selectedSessionID = id; return }
        guard let target, grid.paneIDs.contains(target) else {
            openSingle(id)
            return
        }
        grid.place(id, onPaneWith: target, zone: .center)
        selectedSessionID = id
    }

    /// Show `id` as a **separate** pane without displacing the focused one: a new
    /// column on the right while under the column cap, otherwise a row split of the
    /// first single-pane column. Falls back to replacing the active pane when the
    /// grid is completely full, and to a single-pane view when the grid is empty.
    private func showInNewPane(_ id: SessionRecord.ID,
                               fallbackTarget: SessionRecord.ID? = nil) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        savedGrid = nil
        if grid.paneIDs.contains(id) { selectedSessionID = id; return }
        if grid.isEmpty { openSingle(id); return }
        if grid.addPane(id) {
            selectedSessionID = id
        } else {
            // Keyboard-created splits pass the focused pane explicitly; sidebar
            // actions pass their hover-aware active pane.
            show(id, inPaneWith: fallbackTarget ?? activePaneSessionID)
        }
    }

    /// Sidebar tap: open `id` in the focused pane without leaving the current
    /// multi-pane layout. Do not use the hover target here: once the pointer has
    /// moved into the sidebar, that value only describes a previously hovered
    /// pane and can disagree with the user's explicit focus selection.
    func openInActivePane(_ id: SessionRecord.ID) {
        show(id, inPaneWith: focusedPaneSessionID)
    }

    /// Sidebar Command-click: add a hidden session as another pane, or only
    /// focus it when it is already visible. `showInNewPane` retains the existing
    /// six-pane fallback and placement rules used by keyboard-created splits.
    func openInNewPane(_ id: SessionRecord.ID) {
        showInNewPane(id)
    }

    func allowedZones(forPaneWith id: SessionRecord.ID) -> Set<DropZone> {
        grid.allowedZones(forPaneWith: id)
    }

    func allowedZonesForMovingPane(
        _ dragged: SessionRecord.ID,
        onPaneWith target: SessionRecord.ID
    ) -> Set<DropZone> {
        grid.allowedZonesForMovingPane(dragged, onPaneWith: target)
    }

    func place(_ dragged: SessionRecord.ID,
               onPaneWith target: SessionRecord.ID,
               zone: DropZone) {
        guard sessions.contains(where: { $0.id == dragged }),
              sessions.contains(where: { $0.id == target }) else { return }
        savedGrid = nil
        grid.place(dragged, onPaneWith: target, zone: zone)
        if grid.paneIDs.contains(dragged) {
            selectedSessionID = dragged
        }
    }

    func movePane(
        _ dragged: SessionRecord.ID,
        onPaneWith target: SessionRecord.ID,
        zone: DropZone
    ) {
        guard !isMaximized,
              sessions.contains(where: { $0.id == dragged }),
              sessions.contains(where: { $0.id == target }) else { return }
        savedGrid = nil
        grid.movePane(dragged, onPaneWith: target, zone: zone)
        if grid.paneIDs.contains(dragged) {
            selectedSessionID = dragged
        }
    }

    func resizeColumn(pairLeadingIndex index: Int, leadingFraction fraction: CGFloat) {
        grid.resizeColumn(pairLeadingIndex: index, leadingFraction: fraction)
    }

    func resizeRow(columnIndex index: Int, topFraction fraction: CGFloat) {
        grid.resizeRow(columnIndex: index, topFraction: fraction)
    }

    /// Marks the start of a divider drag. Posts a synchronous notification so each
    /// terminal turns on `defersProcessWindowSizeUpdates` before the first frame
    /// changes, and returns `true` only on the transition into the resizing state
    /// so the caller can skip that first event's resize (belt-and-suspenders
    /// against a leaked intermediate SIGWINCH).
    @discardableResult
    func beginPaneResize() -> Bool {
        guard !isResizingPanes else { return false }
        isResizingPanes = true
        NotificationCenter.default.post(name: .mtermPaneResizeBegan, object: nil)
        return true
    }

    /// Marks the end of a divider drag. The notification lets each terminal flush
    /// the final deferred winsize to its child exactly once.
    func endPaneResize() {
        guard isResizingPanes else { return }
        isResizingPanes = false
        NotificationCenter.default.post(name: .mtermPaneResizeEnded, object: nil)
    }

    private func persist() {
        Self.encode(workspaces, to: defaults, key: workspacesKey)
    }

    func restorationIntent(for id: SessionRecord.ID) -> AgentResumeDescriptor? {
        agentResumeDescriptors[id]
    }

    func reportRestorationLaunched(_ id: SessionRecord.ID) {
        guard agentResumeDescriptors[id] != nil,
              agentRestorationPhases[id] == .pending else { return }
        agentRestorationPhases[id] = .launched
    }

    func reportClaudeSessionIdentity(
        _ id: SessionRecord.ID,
        sessionID: UUID
    ) {
        guard session(for: id) != nil,
              claudeSessionIDs.contains(id) else { return }
        agentRestorationPhases[id] = .acknowledged
        agentResumeDescriptors[id] = .claude(sessionID: sessionID)
    }

    func flushSnapshot() {
        guard allowsSnapshotWrites else { return }
        snapshotStore?.flush(makeSnapshot())
    }

    private func durableStateDidChange() {
        guard !isHydratingSnapshot, let snapshotStore else { return }
        allowsSnapshotWrites = true
        snapshotStore.schedule { [weak self] in self?.makeSnapshot() }
    }

    private func updateAgentRestorationState(
        for id: SessionRecord.ID,
        foregroundCommand: String?
    ) {
        guard let descriptor = agentResumeDescriptors[id] else {
            agentRestorationPhases.removeValue(forKey: id)
            return
        }

        let expectedCommand: String
        switch descriptor {
        case .claude:
            expectedCommand = "claude"
        case .codex:
            expectedCommand = "codex"
        }

        switch agentRestorationPhases[id] {
        case .pending:
            // The initial shell-idle marker is what triggers command injection.
            // It must not look like the restored agent exited.
            return
        case .launched:
            guard foregroundCommand == expectedCommand else {
                agentRestorationPhases[id] = .failed
                agentResumeDescriptors.removeValue(forKey: id)
                return
            }
        case .acknowledged:
            guard foregroundCommand == expectedCommand else {
                agentRestorationPhases.removeValue(forKey: id)
                agentResumeDescriptors.removeValue(forKey: id)
                return
            }
        case .failed:
            // Unreachable in practice: .failed is only ever assigned together
            // with descriptor removal (see the .launched arm above), so the
            // guard at the top of this function returns before we get here.
            // Retained for exhaustiveness without changing behavior.
            agentResumeDescriptors.removeValue(forKey: id)
        case nil:
            // A descriptor created by an identity event is marked acknowledged
            // in that same event. This only covers defensive legacy state.
            if foregroundCommand != expectedCommand {
                agentResumeDescriptors.removeValue(forKey: id)
            }
        }
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            schemaVersion: WorkspaceSnapshot.currentSchemaVersion,
            sessions: sessions.map { session in
                SessionSnapshot(
                    id: session.id,
                    stableTitle: session.title,
                    workingDirectory: session.workingDirectory,
                    workspaceID: session.workspaceID,
                    createdAt: session.createdAt,
                    wasManuallyRenamed: manuallyRenamedSessionIDs.contains(session.id),
                    activeAgent: agentResumeDescriptors[session.id])
            },
            grid: PaneGridSnapshot(grid),
            savedGrid: savedGrid.map(PaneGridSnapshot.init),
            selectedSessionID: selectedSessionID,
            isSidebarVisible: isSidebarVisible,
            sessionSequence: sessionSequence)
    }

    private func makeSession(workingDirectory: String? = nil,
                             workspaceID: WorkspaceFolder.ID? = nil) -> SessionRecord {
        // Monotonic sequence so numbers never repeat, even after a terminal is
        // closed — `sessions.count` would reuse a number and collide.
        sessionSequence += 1
        return SessionRecord.shell(title: "Terminal \(sessionSequence)",
                                   workingDirectory: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                   workspaceID: workspaceID)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

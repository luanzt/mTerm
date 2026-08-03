import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    typealias CodexTitleLookup = @Sendable (UUID) async -> String?

    @Published private(set) var sessions: [SessionRecord]
    @Published private(set) var workspaces: [WorkspaceFolder]
    @Published var selectedSessionID: SessionRecord.ID?
    @Published var draggedSessionID: SessionRecord.ID?
    /// Non-nil only when a visible pane header initiated the current session
    /// drag. Sidebar drags keep their existing open/replace semantics.
    @Published private(set) var draggedPaneSessionID: SessionRecord.ID?
    @Published var draggedWorkspaceID: WorkspaceFolder.ID?
    @Published var isSidebarVisible = true
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: [])
    /// Session shown in the pane the cursor most recently hovered. Used as the
    /// target pane when opening a session or creating a terminal from the sidebar.
    @Published var hoveredSessionID: SessionRecord.ID?
    /// Sessions whose pane currently has `claude` as its foreground command,
    /// reported via shell integration (see `setForeground`). Drives the agent
    /// icon swap in the sidebar and pane header.
    @Published private(set) var claudeSessionIDs: Set<SessionRecord.ID> = []
    /// Sessions whose foreground command is the Codex CLI. Drives the agent
    /// icon in the sidebar and pane header, requests notification permission in
    /// context, and clears on close.
    @Published private(set) var codexSessionIDs: Set<SessionRecord.ID> = []
    /// Agent sessions currently processing a submitted response. Attention events
    /// clear this state when Claude/Codex finishes or needs the user again. This
    /// drives only the sidebar spinner; pane headers remain visually unchanged.
    @Published private(set) var agentWorkingSessionIDs: Set<SessionRecord.ID> = []
    /// Validated OSC 0/2 titles emitted by active Claude/Codex processes. Kept
    /// separately so each session's stable "Terminal N" title is restored when
    /// shell integration reports that the pane is idle again.
    @Published private(set) var agentSessionTitles: [SessionRecord.ID: String] = [:]
    /// User-renamed sessions always display their stable title instead of an
    /// agent-supplied transient OSC title.
    private var manuallyRenamedSessionIDs: Set<SessionRecord.ID> = []

    /// Grid to return to when un-maximizing. Non-nil exactly while one pane is
    /// maximized (see `toggleMaximize`). Not `@Published`: it always changes in
    /// lockstep with `grid`, which already drives view updates.
    private var savedGrid: PaneGrid?

    private var sessionSequence = 0
    private let sessionsKey = "edev.workspace.sessions"
    private let workspacesKey = "edev.workspace.folders"
    private let defaults: UserDefaults
    private let codexTitleLookup: CodexTitleLookup
    private var dragEndMonitor: Any?
    private var codexTitleResolutionTasks: [SessionRecord.ID: Task<Void, Never>] = [:]
    private var codexThreadIDs: [SessionRecord.ID: UUID] = [:]

    /// App-level side effects stay outside the store; the store resolves the
    /// session before forwarding a trusted agent attention event.
    var onClaudeAttention: ((SessionRecord, ClaudeIntegration.AttentionKind) -> Void)?
    var onCodexAttention: ((SessionRecord) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        codexTitleLookup: @escaping CodexTitleLookup = {
            await CodexThreadTitleResolver.title(for: $0)
        }
    ) {
        self.defaults = defaults
        self.codexTitleLookup = codexTitleLookup
        sessions = [SessionRecord.shell()]
        defaults.removeObject(forKey: sessionsKey)   // dọn state cũ nếu có
        workspaces = Self.decode([WorkspaceFolder].self, from: defaults, key: workspacesKey) ?? []
        defaults.removeObject(forKey: "edev.workspace.history")
        selectedSessionID = sessions.first?.id
        grid = selectedSessionID.map(PaneGrid.single) ?? PaneGrid(columns: [])
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

    /// Removes a folder grouping without deleting anything on disk or ending
    /// its shell processes. Existing sessions become ungrouped Open Sessions.
    func removeWorkspace(_ id: WorkspaceFolder.ID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        workspaces.removeAll { $0.id == id }
        for index in sessions.indices where sessions[index].workspaceID == id {
            sessions[index].workspaceID = nil
        }
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
        savedGrid = nil
        claudeSessionIDs.remove(session.id)
        codexSessionIDs.remove(session.id)
        agentWorkingSessionIDs.remove(session.id)
        agentSessionTitles.removeValue(forKey: session.id)
        manuallyRenamedSessionIDs.remove(session.id)
        cancelCodexTitleResolution(for: session.id)
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
    }

    /// Starts (or resumes) an active agent's work. Claude reports this through
    /// its `UserPromptSubmit` hook; Codex uses validated keyboard submission.
    func reportAgentInputSubmitted(_ id: SessionRecord.ID) {
        guard claudeSessionIDs.contains(id) || codexSessionIDs.contains(id) else { return }
        agentWorkingSessionIDs.insert(id)
    }

    /// Escape and Ctrl-C interrupt an in-flight Claude/Codex turn and return the
    /// TUI to user input without necessarily producing an attention event.
    func reportAgentWorkInterrupted(_ id: SessionRecord.ID) {
        guard claudeSessionIDs.contains(id) || codexSessionIDs.contains(id) else { return }
        agentWorkingSessionIDs.remove(id)
    }

    func setAgentTitle(_ id: SessionRecord.ID, title rawTitle: String) {
        guard session(for: id) != nil,
              !manuallyRenamedSessionIDs.contains(id) else { return }

        if codexSessionIDs.contains(id),
           let threadID = CodexThreadTitleResolver.threadID(from: rawTitle) {
            resolveCodexTitle(for: id, threadID: threadID)
            return
        }

        guard claudeSessionIDs.contains(id) || codexSessionIDs.contains(id),
              let title = AgentSessionTitle.normalize(rawTitle),
              agentSessionTitles[id] != title else {
            return
        }
        if codexSessionIDs.contains(id) {
            // A real OSC title is a manual `/rename`/`--name` value and wins
            // over any in-flight automatic-title metadata lookup.
            cancelCodexTitleResolution(for: id)
        }
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

    private func persist() {
        Self.encode(workspaces, to: defaults, key: workspacesKey)
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

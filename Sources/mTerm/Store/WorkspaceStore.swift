import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord]
    @Published private(set) var workspaces: [WorkspaceFolder]
    @Published var selectedSessionID: SessionRecord.ID?
    @Published var draggedSessionID: SessionRecord.ID?
    @Published var draggedWorkspaceID: WorkspaceFolder.ID?
    @Published var isSidebarVisible = true
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: [])
    /// Session shown in the pane the cursor most recently hovered. Used as the
    /// target pane when opening a session or creating a terminal from the sidebar.
    @Published var hoveredSessionID: SessionRecord.ID?
    /// Sessions whose pane currently has `claude` as its foreground command,
    /// reported via shell integration (see `setForeground`). Drives the sidebar
    /// icon swap.
    @Published private(set) var claudeSessionIDs: Set<SessionRecord.ID> = []

    /// Grid to return to when un-maximizing. Non-nil exactly while one pane is
    /// maximized (see `toggleMaximize`). Not `@Published`: it always changes in
    /// lockstep with `grid`, which already drives view updates.
    private var savedGrid: PaneGrid?

    private var sessionSequence = 0
    private let sessionsKey = "edev.workspace.sessions"
    private let workspacesKey = "edev.workspace.folders"
    private let defaults: UserDefaults
    private var dragEndMonitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        sessions.append(session)
        if asNewPane { showInNewPane(session.id) } else { showInActivePane(session.id) }
        persist()
    }

    func beginDragging(_ sessionID: SessionRecord.ID) {
        finishDragging()
        draggedSessionID = sessionID
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
        sessions.append(session)
        if asNewPane { showInNewPane(session.id) } else { showInActivePane(session.id) }
        persist()
    }

    func close(_ session: SessionRecord) {
        guard let index = sessions.firstIndex(of: session) else { return }
        savedGrid = nil
        claudeSessionIDs.remove(session.id)
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

    /// Reported by shell integration when a pane's foreground command changes.
    /// `"claude"` marks the row; any other command (or `nil` for an idle prompt)
    /// clears it. Publishes only on an actual change.
    func setForeground(_ id: SessionRecord.ID, command: String?) {
        let isClaude = command == "claude"
        if isClaude, !claudeSessionIDs.contains(id) {
            claudeSessionIDs.insert(id)
        } else if !isClaude, claudeSessionIDs.contains(id) {
            claudeSessionIDs.remove(id)
        }
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

    /// Show `id` in the active pane (the pane under the cursor), replacing whatever
    /// it currently shows — instead of collapsing to a single view. Falls back to a
    /// single-pane view when the grid is empty.
    private func showInActivePane(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        savedGrid = nil
        // Already visible in some pane: just focus it, don't move it (moving would
        // collapse its current pane).
        if grid.paneIDs.contains(id) { selectedSessionID = id; return }
        guard let target = activePaneSessionID else { openSingle(id); return }
        grid.place(id, onPaneWith: target, zone: .center)
        selectedSessionID = id
    }

    /// Show `id` as a **separate** pane without displacing the focused one: a new
    /// column on the right while under the column cap, otherwise a row split of the
    /// first single-pane column. Falls back to replacing the active pane when the
    /// grid is completely full, and to a single-pane view when the grid is empty.
    private func showInNewPane(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        savedGrid = nil
        if grid.paneIDs.contains(id) { selectedSessionID = id; return }
        if grid.isEmpty { openSingle(id); return }
        if grid.addPane(id) {
            selectedSessionID = id
        } else {
            showInActivePane(id)   // grid full: fall back to replacing the active pane
        }
    }

    /// Sidebar tap: open `id` in the pane under the cursor without leaving the
    /// current multi-pane layout.
    func openInActivePane(_ id: SessionRecord.ID) {
        showInActivePane(id)
    }

    func allowedZones(forPaneWith id: SessionRecord.ID) -> Set<DropZone> {
        grid.allowedZones(forPaneWith: id)
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

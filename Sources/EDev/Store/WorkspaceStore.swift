import AppKit
import Combine
import CoreGraphics
import Foundation

enum TerminalDropPosition {
    case left
    case right
    case top
    case bottom
    case center

    var splitAxis: SplitAxis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }
}

enum SplitAxis: Equatable {
    case horizontal
    case vertical
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord]
    @Published private(set) var workspaces: [WorkspaceFolder]
    @Published var selectedSessionID: SessionRecord.ID?
    @Published var draggedSessionID: SessionRecord.ID?
    @Published var isSidebarVisible = true
    @Published private(set) var splitSessionIDs: [SessionRecord.ID] = []
    @Published private(set) var splitFraction: CGFloat = 0.5
    @Published private(set) var splitAxis: SplitAxis = .horizontal
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: [])

    private let sessionsKey = "edev.workspace.sessions"
    private let workspacesKey = "edev.workspace.folders"
    private let defaults: UserDefaults
    private var dragEndMonitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessions = Self.decode([SessionRecord].self, from: defaults, key: sessionsKey)
            ?? [SessionRecord.shell()]
        workspaces = Self.decode([WorkspaceFolder].self, from: defaults, key: workspacesKey) ?? []
        defaults.removeObject(forKey: "edev.workspace.history")
        selectedSessionID = sessions.first?.id
        grid = selectedSessionID.map(PaneGrid.single) ?? PaneGrid(columns: [])
    }

    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var displayedSessions: [SessionRecord] {
        let ids = splitSessionIDs.isEmpty ? [selectedSessionID].compactMap { $0 } : splitSessionIDs
        return ids.compactMap { id in sessions.first { $0.id == id } }
    }

    func createSession() {
        let session = makeSession()
        sessions.append(session)
        selectedSessionID = session.id
        persist()
    }

    func beginDragging(_ sessionID: SessionRecord.ID) {
        finishDragging()
        draggedSessionID = sessionID
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

    func createSession(in workspace: WorkspaceFolder) {
        let session = makeSession(workingDirectory: workspace.path, workspaceID: workspace.id)
        sessions.append(session)
        selectedSessionID = session.id
        persist()
    }

    func close(_ session: SessionRecord) {
        guard let index = sessions.firstIndex(of: session) else { return }
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
        splitSessionIDs.removeAll { $0 == session.id }
        if splitSessionIDs.count < 2 {
            splitSessionIDs = []
        }
        persist()
    }

    func move(_ sessionID: SessionRecord.ID, before destinationID: SessionRecord.ID) {
        guard sessionID != destinationID,
              let source = sessions.firstIndex(where: { $0.id == sessionID }),
              let destination = sessions.firstIndex(where: { $0.id == destinationID }) else {
            return
        }
        let item = sessions.remove(at: source)
        let adjustedDestination = source < destination ? destination - 1 : destination
        sessions.insert(item, at: adjustedDestination)
        persist()
    }

    func splitSelectedSession() {
        guard let selectedSession else { return }
        let session = SessionRecord.shell(title: "Terminal \(sessions.count + 1)",
                                           workingDirectory: selectedSession.workingDirectory,
                                           workspaceID: selectedSession.workspaceID)
        sessions.append(session)
        splitSessionIDs = [selectedSession.id, session.id]
        splitAxis = .horizontal
        selectedSessionID = session.id
        persist()
    }

    func place(_ sessionID: SessionRecord.ID,
               relativeTo targetID: SessionRecord.ID,
               at position: TerminalDropPosition) {
        guard sessionID != targetID,
              sessions.contains(where: { $0.id == sessionID }),
              sessions.contains(where: { $0.id == targetID }) else { return }

        guard let axis = position.splitAxis else {
            selectedSessionID = sessionID
            splitSessionIDs = []
            return
        }

        splitAxis = axis
        var ids = splitSessionIDs.isEmpty ? [targetID] : splitSessionIDs
        ids.removeAll { $0 == sessionID }
        guard let targetIndex = ids.firstIndex(of: targetID) else { return }
        let insertionIndex: Int
        switch position {
        case .left, .top:
            insertionIndex = targetIndex
        case .right, .bottom:
            insertionIndex = targetIndex + 1
        case .center:
            return
        }
        ids.insert(sessionID, at: insertionIndex)
        splitSessionIDs = ids
        selectedSessionID = sessionID
    }

    func focusOnly(_ session: SessionRecord) {
        selectedSessionID = session.id
        splitSessionIDs = []
    }

    func closeSplit() {
        splitSessionIDs = []
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func resizeSplit(to fraction: CGFloat) {
        splitFraction = min(max(fraction, 0.2), 0.8)
    }

    func session(for id: SessionRecord.ID) -> SessionRecord? {
        sessions.first { $0.id == id }
    }

    func openSingle(_ id: SessionRecord.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        grid = PaneGrid.single(id)
        selectedSessionID = id
    }

    func allowedZones(forPaneWith id: SessionRecord.ID) -> Set<DropZone> {
        grid.allowedZones(forPaneWith: id)
    }

    func place(_ dragged: SessionRecord.ID,
               onPaneWith target: SessionRecord.ID,
               zone: DropZone) {
        guard sessions.contains(where: { $0.id == dragged }),
              sessions.contains(where: { $0.id == target }) else { return }
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
        Self.encode(sessions, to: defaults, key: sessionsKey)
        Self.encode(workspaces, to: defaults, key: workspacesKey)
    }

    private func makeSession(workingDirectory: String? = nil,
                             workspaceID: WorkspaceFolder.ID? = nil) -> SessionRecord {
        SessionRecord.shell(title: "Terminal \(sessions.count + 1)",
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

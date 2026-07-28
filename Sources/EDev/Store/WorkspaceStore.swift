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
    @Published var isSidebarVisible = true
    @Published private(set) var grid: PaneGrid = PaneGrid(columns: [])

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

    func createSession() {
        let session = makeSession()
        sessions.append(session)
        openSingle(session.id)
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
        openSingle(session.id)
        persist()
    }

    func close(_ session: SessionRecord) {
        guard let index = sessions.firstIndex(of: session) else { return }
        sessions.remove(at: index)
        grid.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.indices.contains(index)
                ? sessions[index].id : sessions.last?.id
        }
        if grid.isEmpty, let fallback = selectedSessionID {
            grid = PaneGrid.single(fallback)
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

    func toggleSidebar() {
        isSidebarVisible.toggle()
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

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord]
    @Published private(set) var workspaces: [WorkspaceFolder]
    @Published var selectedSessionID: SessionRecord.ID?
    @Published var isSidebarVisible = true
    @Published private(set) var splitSessionIDs: [SessionRecord.ID] = []
    @Published private(set) var splitFraction: CGFloat = 0.5

    private let sessionsKey = "edev.workspace.sessions"
    private let workspacesKey = "edev.workspace.folders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessions = Self.decode([SessionRecord].self, from: defaults, key: sessionsKey)
            ?? [SessionRecord.shell()]
        workspaces = Self.decode([WorkspaceFolder].self, from: defaults, key: workspacesKey) ?? []
        defaults.removeObject(forKey: "edev.workspace.history")
        selectedSessionID = sessions.first?.id
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
        selectedSessionID = session.id
        persist()
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

import Foundation

struct SessionRecord: Codable, Hashable, Identifiable {
    enum Status: String, Codable {
        case running
        case exited
    }

    let id: UUID
    var title: String
    var command: String
    var workingDirectory: String
    var workspaceID: WorkspaceFolder.ID?
    var createdAt: Date
    var status: Status

    static func shell(
        title: String = "Terminal",
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        workspaceID: WorkspaceFolder.ID? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: UUID(),
            title: title,
            command: "",
            workingDirectory: workingDirectory,
            workspaceID: workspaceID,
            createdAt: .now,
            status: .running)
    }
}

struct WorkspaceFolder: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    let path: String

    init(path: String) {
        id = UUID()
        self.path = path
        name = URL(fileURLWithPath: path).lastPathComponent
    }
}

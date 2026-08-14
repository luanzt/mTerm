import CoreGraphics
import Foundation

struct WorkspaceSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessions: [SessionSnapshot]
    var grid: PaneGridSnapshot
    var savedGrid: PaneGridSnapshot?
    var selectedSessionID: UUID?
    var isSidebarVisible: Bool
    var sessionSequence: Int

    func validated(
        validWorkspaceIDs: Set<UUID>,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> WorkspaceSnapshot? {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }

        var seenSessionIDs = Set<UUID>()
        var repairedSessions: [SessionSnapshot] = []
        for var session in sessions where seenSessionIDs.insert(session.id).inserted {
            if let workspaceID = session.workspaceID,
               !validWorkspaceIDs.contains(workspaceID) {
                session.workspaceID = nil
            }
            var isDirectory: ObjCBool = false
            let directoryExists = fileManager.fileExists(
                atPath: session.workingDirectory,
                isDirectory: &isDirectory)
            if !directoryExists || !isDirectory.boolValue {
                session.workingDirectory = homeDirectory.path
            }
            if let activeAgent = session.activeAgent,
               TerminalSessionRestoration.command(for: activeAgent) == nil {
                session.activeAgent = nil
            }
            repairedSessions.append(session)
        }
        guard !repairedSessions.isEmpty else { return nil }

        let validSessionIDs = repairedSessions.map(\.id)
        let validSessionIDSet = Set(validSessionIDs)
        let fallbackID: UUID
        if let selectedSessionID, validSessionIDSet.contains(selectedSessionID) {
            fallbackID = selectedSessionID
        } else {
            fallbackID = validSessionIDs[0]
        }
        let repairedGrid = grid.repaired(
            validSessionIDs: validSessionIDs,
            fallbackID: fallbackID)
        let repairedSavedGrid = savedGrid.map {
            $0.repaired(validSessionIDs: validSessionIDs, fallbackID: nil)
        }.flatMap { candidate in
            candidate.paneIDs.count > 1 ? candidate : nil
        }
        let repairedSelection: UUID?
        if let selectedSessionID,
           repairedGrid.paneIDs.contains(selectedSessionID) {
            repairedSelection = selectedSessionID
        } else {
            repairedSelection = repairedGrid.paneIDs.first
        }

        return WorkspaceSnapshot(
            schemaVersion: schemaVersion,
            sessions: repairedSessions,
            grid: PaneGridSnapshot(repairedGrid),
            savedGrid: repairedSavedGrid.map(PaneGridSnapshot.init),
            selectedSessionID: repairedSelection,
            isSidebarVisible: isSidebarVisible,
            sessionSequence: max(sessionSequence, 0))
    }
}

struct SessionSnapshot: Codable, Equatable {
    var id: UUID
    var stableTitle: String
    var workingDirectory: String
    var workspaceID: UUID?
    var createdAt: Date
    var wasManuallyRenamed: Bool
    var activeAgent: AgentResumeDescriptor?

    var sessionRecord: SessionRecord {
        SessionRecord(
            id: id,
            title: stableTitle,
            command: "",
            workingDirectory: workingDirectory,
            workspaceID: workspaceID,
            createdAt: createdAt,
            status: .running)
    }
}

enum AgentResumeDescriptor: Codable, Equatable {
    case claude(sessionID: UUID)
    case codex(locator: CodexResumeLocator)

    private enum Kind: String, Codable {
        case claude
        case codex
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case sessionID
        case locator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .claude:
            self = .claude(sessionID: try container.decode(UUID.self, forKey: .sessionID))
        case .codex:
            self = .codex(locator: try container.decode(
                CodexResumeLocator.self,
                forKey: .locator))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claude(let sessionID):
            try container.encode(Kind.claude, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
        case .codex(let locator):
            try container.encode(Kind.codex, forKey: .kind)
            try container.encode(locator, forKey: .locator)
        }
    }
}

enum CodexResumeLocator: Codable, Equatable {
    case threadID(UUID)
    case name(String)

    private enum Kind: String, Codable {
        case threadID
        case name
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .threadID:
            self = .threadID(try container.decode(UUID.self, forKey: .threadID))
        case .name:
            self = .name(try container.decode(String.self, forKey: .name))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .threadID(let threadID):
            try container.encode(Kind.threadID, forKey: .kind)
            try container.encode(threadID, forKey: .threadID)
        case .name(let name):
            try container.encode(Kind.name, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

struct PaneGridSnapshot: Codable, Equatable {
    struct Column: Codable, Equatable {
        var panes: [UUID]
        var widthFraction: Double
        var rowFraction: Double
    }

    var columns: [Column]

    init(columns: [Column]) {
        self.columns = columns
    }

    init(_ grid: PaneGrid) {
        columns = grid.columns.map { column in
            Column(
                panes: column.panes,
                widthFraction: Double(column.widthFraction),
                rowFraction: Double(column.rowFraction))
        }
    }

    func repaired(
        validSessionIDs: [UUID],
        fallbackID: UUID?
    ) -> PaneGrid {
        let validIDs = Set(validSessionIDs)
        var seen = Set<UUID>()
        var repairedColumns: [GridColumn] = []

        for column in columns {
            let panes = column.panes.filter { id in
                validIDs.contains(id) && seen.insert(id).inserted
            }.prefix(2)
            guard !panes.isEmpty else { continue }

            let width = column.widthFraction.isFinite && column.widthFraction > 0
                ? column.widthFraction
                : 1
            let rawRow = column.rowFraction.isFinite ? column.rowFraction : 0.5
            repairedColumns.append(GridColumn(
                panes: Array(panes),
                widthFraction: CGFloat(width),
                rowFraction: CGFloat(min(max(rawRow, 0.2), 0.8))))
            if repairedColumns.count == PaneGrid.maxColumns { break }
        }

        guard !repairedColumns.isEmpty else {
            if let fallbackID, validIDs.contains(fallbackID) {
                return .single(fallbackID)
            }
            return PaneGrid(columns: [])
        }

        let totalWidth = repairedColumns.reduce(CGFloat.zero) {
            $0 + $1.widthFraction
        }
        let normalizedWidth = totalWidth.isFinite && totalWidth > 0
            ? totalWidth
            : CGFloat(repairedColumns.count)
        for index in repairedColumns.indices {
            repairedColumns[index].widthFraction /= normalizedWidth
        }
        return PaneGrid(columns: repairedColumns)
    }
}

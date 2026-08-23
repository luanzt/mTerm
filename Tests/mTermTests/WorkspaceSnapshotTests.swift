import CoreGraphics
import XCTest
@testable import mTerm

final class WorkspaceSnapshotTests: XCTestCase {
    func testJSONRoundTripPreservesEveryDurableFieldAndTaggedAgentCase() throws {
        let claudeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let codexID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let snapshot = WorkspaceSnapshot(
            schemaVersion: 1,
            sessions: [
                SessionSnapshot(
                    id: claudeID,
                    stableTitle: "Claude pane",
                    workingDirectory: "/tmp/claude",
                    workspaceID: workspaceID,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    wasManuallyRenamed: true,
                    activeAgent: .claude(sessionID: claudeID)),
                SessionSnapshot(
                    id: codexID,
                    stableTitle: "Codex pane",
                    workingDirectory: "/tmp/codex",
                    workspaceID: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    wasManuallyRenamed: false,
                    activeAgent: .codex(locator: .threadID(codexID))),
                SessionSnapshot(
                    id: workspaceID,
                    stableTitle: "Named Codex pane",
                    workingDirectory: "/tmp/named",
                    workspaceID: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_002),
                    wasManuallyRenamed: false,
                    activeAgent: .codex(locator: .name("Client API"))),
            ],
            grid: PaneGridSnapshot(columns: [
                .init(panes: [claudeID, codexID], widthFraction: 0.4, rowFraction: 0.65),
                .init(panes: [workspaceID], widthFraction: 0.6, rowFraction: 0.5),
            ]),
            savedGrid: PaneGridSnapshot(columns: [
                .init(panes: [claudeID], widthFraction: 0.5, rowFraction: 0.5),
                .init(panes: [codexID], widthFraction: 0.5, rowFraction: 0.5),
            ]),
            selectedSessionID: codexID,
            isSidebarVisible: false,
            sessionSequence: 9)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual((sessions[0]["activeAgent"] as? [String: Any])?["kind"] as? String, "claude")
        XCTAssertEqual((sessions[1]["activeAgent"] as? [String: Any])?["kind"] as? String, "codex")
        XCTAssertEqual(
            (((sessions[1]["activeAgent"] as? [String: Any])?["locator"] as? [String: Any])?["kind"] as? String),
            "threadID")
        XCTAssertEqual(
            (((sessions[2]["activeAgent"] as? [String: Any])?["locator"] as? [String: Any])?["kind"] as? String),
            "name")
    }

    func testSessionSnapshotRestoresFreshInteractiveShellRecord() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 123)
        let snapshot = SessionSnapshot(
            id: id,
            stableTitle: "Restored",
            workingDirectory: "/tmp/project",
            workspaceID: UUID(),
            createdAt: createdAt,
            wasManuallyRenamed: true,
            activeAgent: nil)

        let record = snapshot.sessionRecord

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.title, "Restored")
        XCTAssertEqual(record.workingDirectory, "/tmp/project")
        XCTAssertEqual(record.workspaceID, snapshot.workspaceID)
        XCTAssertEqual(record.createdAt, createdAt)
        XCTAssertEqual(record.status, .running)
    }

    func testGridSnapshotRoundTripPreservesRuntimeGeometry() {
        let a = UUID()
        let b = UUID()
        let grid = PaneGrid(columns: [
            GridColumn(panes: [a, b], widthFraction: 0.35, rowFraction: 0.7),
            GridColumn(panes: [UUID()], widthFraction: 0.65, rowFraction: 0.5),
        ])

        let restored = PaneGridSnapshot(grid).repaired(
            validSessionIDs: grid.paneIDs,
            fallbackID: a)

        XCTAssertEqual(restored.paneIDs, grid.paneIDs)
        XCTAssertEqual(restored.columns[0].widthFraction, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(restored.columns[0].rowFraction, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(restored.columns[1].widthFraction, 0.65, accuracy: 0.000_001)
    }

    func testGridRepairDropsOrphansDuplicatesEmptyColumnsAndExcessRows() {
        let a = UUID()
        let b = UUID()
        let orphan = UUID()
        let snapshot = PaneGridSnapshot(columns: [
            .init(
                panes: [a, orphan, b, UUID()],
                widthFraction: .infinity,
                rowFraction: 0.01),
            .init(panes: [a], widthFraction: -4, rowFraction: 2),
            .init(panes: [], widthFraction: 1, rowFraction: 0.5),
        ])

        let repaired = snapshot.repaired(validSessionIDs: [a, b], fallbackID: a)

        XCTAssertEqual(repaired.paneIDs, [a, b])
        XCTAssertEqual(repaired.columns.count, 1)
        XCTAssertEqual(repaired.columns[0].rowFraction, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(repaired.columns[0].widthFraction, 1, accuracy: 0.000_001)
        XCTAssertTrue(repaired.columns[0].widthFraction.isFinite)
    }

    func testGridRepairCapsColumnsAndFallsBackWhenNothingSurvives() {
        let ids = (0..<5).map { _ in UUID() }
        let snapshot = PaneGridSnapshot(columns: ids.map {
            .init(panes: [$0], widthFraction: 0.2, rowFraction: 0.5)
        })

        let capped = snapshot.repaired(validSessionIDs: ids, fallbackID: ids[0])
        let fallback = PaneGridSnapshot(columns: [
            .init(panes: [UUID()], widthFraction: 1, rowFraction: 0.5),
        ]).repaired(validSessionIDs: [ids[0]], fallbackID: ids[0])

        XCTAssertEqual(capped.columns.count, PaneGrid.maxColumns)
        XCTAssertEqual(capped.paneIDs, Array(ids.prefix(3)))
        XCTAssertEqual(fallback, PaneGrid.single(ids[0]))
    }

    func testGridRepairNormalizesFiniteWidthsWithoutOverflow() {
        let ids = (0..<3).map { _ in UUID() }
        let snapshot = PaneGridSnapshot(columns: [
            .init(panes: [ids[0]], widthFraction: Double.greatestFiniteMagnitude,
                  rowFraction: 0.5),
            .init(panes: [ids[1]], widthFraction: Double.greatestFiniteMagnitude,
                  rowFraction: 0.5),
            .init(panes: [ids[2]], widthFraction: Double.greatestFiniteMagnitude,
                  rowFraction: 0.5),
        ])

        let repaired = snapshot.repaired(validSessionIDs: ids, fallbackID: ids[0])

        XCTAssertEqual(
            repaired.columns.reduce(CGFloat.zero) { $0 + $1.widthFraction },
            1,
            accuracy: 0.000_001)
        XCTAssertTrue(repaired.columns.allSatisfy { $0.widthFraction.isFinite })
    }

    func testValidationRepairsSessionsDirectoriesWorkspaceReferencesAndSelection() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("mterm-snapshot-\(UUID().uuidString)", isDirectory: true)
        let validDirectory = root.appendingPathComponent("project", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try manager.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let a = UUID()
        let b = UUID()
        let orphan = UUID()
        let workspaceID = UUID()
        let missingWorkspaceID = UUID()
        let snapshot = WorkspaceSnapshot(
            schemaVersion: 1,
            sessions: [
                session(id: a, directory: validDirectory.path, workspaceID: workspaceID),
                session(id: b, directory: root.appendingPathComponent("missing").path,
                        workspaceID: missingWorkspaceID),
                session(id: a, directory: validDirectory.path, workspaceID: workspaceID),
            ],
            grid: PaneGridSnapshot(columns: [
                .init(panes: [orphan], widthFraction: 0.5, rowFraction: 0.5),
                .init(panes: [b], widthFraction: 0.5, rowFraction: 0.5),
            ]),
            savedGrid: PaneGridSnapshot(columns: [
                .init(panes: [a], widthFraction: 1, rowFraction: 0.5),
            ]),
            selectedSessionID: a,
            isSidebarVisible: false,
            sessionSequence: 4)

        let validated = try XCTUnwrap(snapshot.validated(
            validWorkspaceIDs: [workspaceID],
            homeDirectory: homeDirectory,
            fileManager: manager))

        XCTAssertEqual(validated.sessions.map(\.id), [a, b])
        XCTAssertEqual(validated.sessions[0].workspaceID, workspaceID)
        XCTAssertNil(validated.sessions[1].workspaceID)
        XCTAssertEqual(validated.sessions[1].workingDirectory, homeDirectory.path)
        XCTAssertEqual(validated.grid.columns.flatMap(\.panes), [b])
        XCTAssertEqual(validated.selectedSessionID, b)
        XCTAssertNil(validated.savedGrid)
        XCTAssertFalse(validated.isSidebarVisible)
        XCTAssertEqual(validated.sessionSequence, 4)
    }

    func testValidationRejectsUnsupportedSchemaAndEmptySessions() {
        var snapshot = WorkspaceSnapshot(
            schemaVersion: 99,
            sessions: [session(id: UUID(), directory: "/tmp")],
            grid: PaneGridSnapshot(columns: []),
            savedGrid: nil,
            selectedSessionID: nil,
            isSidebarVisible: true,
            sessionSequence: 0)

        XCTAssertNil(snapshot.validated(
            validWorkspaceIDs: [],
            homeDirectory: URL(fileURLWithPath: "/tmp")))

        snapshot.schemaVersion = WorkspaceSnapshot.currentSchemaVersion
        snapshot.sessions = []
        XCTAssertNil(snapshot.validated(
            validWorkspaceIDs: [],
            homeDirectory: URL(fileURLWithPath: "/tmp")))
    }

    func testValidationDropsAgentLocatorThatCannotProduceSafeResumeCommand() throws {
        let id = UUID()
        let snapshot = WorkspaceSnapshot(
            schemaVersion: WorkspaceSnapshot.currentSchemaVersion,
            sessions: [
                SessionSnapshot(
                    id: id,
                    stableTitle: "Terminal",
                    workingDirectory: "/tmp",
                    workspaceID: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    wasManuallyRenamed: false,
                    activeAgent: .codex(locator: .name("bad\nname"))),
            ],
            grid: PaneGridSnapshot(columns: [
                .init(panes: [id], widthFraction: 1, rowFraction: 0.5),
            ]),
            savedGrid: nil,
            selectedSessionID: id,
            isSidebarVisible: true,
            sessionSequence: 0)

        let validated = try XCTUnwrap(snapshot.validated(
            validWorkspaceIDs: [],
            homeDirectory: URL(fileURLWithPath: "/tmp")))

        XCTAssertNil(validated.sessions[0].activeAgent)
    }

    func testValidationDropsSavedGridWhenCurrentGridIsNotItsMaximizedPane() throws {
        let a = UUID()
        let b = UUID()
        var snapshot = WorkspaceSnapshot(
            schemaVersion: WorkspaceSnapshot.currentSchemaVersion,
            sessions: [
                session(id: a, directory: "/tmp"),
                session(id: b, directory: "/tmp"),
            ],
            grid: PaneGridSnapshot(columns: [
                .init(panes: [a], widthFraction: 0.5, rowFraction: 0.5),
                .init(panes: [b], widthFraction: 0.5, rowFraction: 0.5),
            ]),
            savedGrid: PaneGridSnapshot(columns: [
                .init(panes: [a], widthFraction: 0.5, rowFraction: 0.5),
                .init(panes: [b], widthFraction: 0.5, rowFraction: 0.5),
            ]),
            selectedSessionID: a,
            isSidebarVisible: true,
            sessionSequence: 2)

        var validated = try XCTUnwrap(snapshot.validated(
            validWorkspaceIDs: [],
            homeDirectory: URL(fileURLWithPath: "/tmp")))
        XCTAssertNil(validated.savedGrid)

        snapshot.grid = PaneGridSnapshot(columns: [
            .init(panes: [a], widthFraction: 1, rowFraction: 0.5),
        ])
        validated = try XCTUnwrap(snapshot.validated(
            validWorkspaceIDs: [],
            homeDirectory: URL(fileURLWithPath: "/tmp")))
        XCTAssertNotNil(validated.savedGrid)
    }

    private func session(
        id: UUID,
        directory: String,
        workspaceID: UUID? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            stableTitle: "Terminal",
            workingDirectory: directory,
            workspaceID: workspaceID,
            createdAt: Date(timeIntervalSince1970: 0),
            wasManuallyRenamed: false,
            activeAgent: nil)
    }
}

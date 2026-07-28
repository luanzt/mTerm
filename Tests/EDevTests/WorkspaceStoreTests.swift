import XCTest
@testable import EDev

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testCloseSelectsRemainingSession() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let closing = store.sessions[0]
        store.createSession()
        store.close(closing)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, store.sessions[0].id)
    }

    func testCloseRemovesPaneFromGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)
        XCTAssertEqual(store.grid.columns.count, 2)
        store.close(store.session(for: b)!)
        XCTAssertEqual(store.grid.columns.count, 1)
        XCTAssertFalse(store.grid.paneIDs.contains(b))
    }

    func testClosingSelectedKeepsSelectionInsideGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()               // b: background session, not in grid
        store.createSession()
        let c = store.sessions[2].id
        store.openSingle(a)
        store.place(c, onPaneWith: a, zone: .right)   // grid [a][c], selected c
        XCTAssertEqual(store.selectedSessionID, c)

        store.close(store.session(for: c)!)           // grid becomes [a]
        // selection must follow a displayed pane, not the background session
        XCTAssertNotNil(store.selectedSessionID)
        XCTAssertTrue(store.grid.paneIDs.contains(store.selectedSessionID!))
        XCTAssertEqual(store.selectedSessionID, a)
    }

    func testSessionsAreNotPersistedAcrossStoreInit() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1 = WorkspaceStore(defaults: defaults)
        store1.createSession()
        store1.createSession()
        XCTAssertEqual(store1.sessions.count, 3)

        let store2 = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store2.sessions.count, 1)          // fresh
        XCTAssertEqual(store2.grid.columns.count, 1)
    }

    func testToggleSidebarChangesVisibility() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)

        XCTAssertTrue(store.isSidebarVisible)
        store.toggleSidebar()
        XCTAssertFalse(store.isSidebarVisible)
    }

    func testWorkspaceSessionStartsInWorkspaceDirectory() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let workspace = WorkspaceFolder(path: "/tmp/example-repository")

        store.createSession(in: workspace)

        XCTAssertEqual(store.selectedSession?.workingDirectory, workspace.path)
        XCTAssertEqual(store.selectedSession?.workspaceID, workspace.id)
    }

    func testNewTerminalDoesNotBelongToAWorkspace() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)

        store.createSession()

        XCTAssertNil(store.selectedSession?.workspaceID)
    }

    func testStoreStartsWithSinglePaneGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertEqual(store.grid.columns.count, 1)
        XCTAssertEqual(store.grid.paneIDs, [store.sessions[0].id])
    }

    func testPlaceRightAddsColumnAndSelectsDragged() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = store.sessions[0].id
        store.createSession()
        let second = store.sessions[1].id
        store.openSingle(first)
        store.place(second, onPaneWith: first, zone: .right)
        XCTAssertEqual(store.grid.columns.count, 2)
        XCTAssertEqual(store.selectedSessionID, second)
    }

    func testAllowedZonesReflectGrid() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        XCTAssertEqual(store.allowedZones(forPaneWith: a),
                       [.center, .left, .right, .top, .bottom])
    }
}

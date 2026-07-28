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

    func testSplitCreatesAdjacentSessionInTheSameWorkingDirectory() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)
        let original = store.sessions[0]

        store.splitSelectedSession()

        XCTAssertEqual(store.displayedSessions.count, 2)
        XCTAssertEqual(store.displayedSessions[0].id, original.id)
        XCTAssertEqual(store.displayedSessions[1].workingDirectory, original.workingDirectory)
        XCTAssertEqual(store.selectedSessionID, store.displayedSessions[1].id)
    }

    func testSplitResizeIsClampedToUsableBounds() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = WorkspaceStore(defaults: defaults)

        store.resizeSplit(to: 0.01)
        XCTAssertEqual(store.splitFraction, 0.2)
        store.resizeSplit(to: 0.99)
        XCTAssertEqual(store.splitFraction, 0.8)
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

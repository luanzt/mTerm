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

    func testOpenInActivePaneReplacesHoveredPaneWithoutCollapsing() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.createSession()
        let c = store.sessions[2].id
        // Build two columns: [b][c]
        store.openSingle(b)
        store.place(c, onPaneWith: b, zone: .right)
        XCTAssertEqual(store.grid.columns.count, 2)

        // Hover the left column (b) and open background session a from the sidebar.
        store.hoveredSessionID = b
        store.openInActivePane(a)

        XCTAssertEqual(store.grid.columns.count, 2)          // did not collapse to single view
        XCTAssertTrue(store.grid.paneIDs.contains(a))        // a replaced b in the hovered pane
        XCTAssertTrue(store.grid.paneIDs.contains(c))        // other pane untouched
        XCTAssertFalse(store.grid.paneIDs.contains(b))
        XCTAssertEqual(store.grid.columns[0].panes, [a])     // left column now shows a
        XCTAssertEqual(store.selectedSessionID, a)
    }

    func testCreateSessionReplacesActivePaneNotSingleView() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)          // [a][b]
        store.hoveredSessionID = a

        store.createSession()                                // new terminal into hovered pane
        let created = store.selectedSessionID

        XCTAssertEqual(store.grid.columns.count, 2)          // still two panes
        XCTAssertTrue(store.grid.paneIDs.contains(b))        // other pane kept
        XCTAssertFalse(store.grid.paneIDs.contains(a))       // a replaced by the new terminal
        XCTAssertEqual(store.grid.columns[0].panes, [created!])
    }

    func testOpenInActivePaneFocusesAlreadyVisibleSession() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)          // [a][b]
        store.hoveredSessionID = a

        store.openInActivePane(b)                            // b already visible

        XCTAssertEqual(store.grid.columns.count, 2)          // unchanged layout
        XCTAssertEqual(store.grid.columns[0].panes, [a])
        XCTAssertEqual(store.grid.columns[1].panes, [b])
        XCTAssertEqual(store.selectedSessionID, b)           // just focused
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

    func testToggleMaximizeCollapsesThenRestoresLayout() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)      // grid [a][b]
        let twoColumn = store.grid
        XCTAssertFalse(store.isMaximized)

        store.toggleMaximize(a)                          // maximize a
        XCTAssertTrue(store.isMaximized)
        XCTAssertEqual(store.grid.paneIDs, [a])
        XCTAssertEqual(store.selectedSessionID, a)

        store.toggleMaximize(a)                          // restore
        XCTAssertFalse(store.isMaximized)
        XCTAssertEqual(store.grid, twoColumn)
    }

    func testToggleMaximizeNoOpWithSinglePane() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.toggleMaximize(a)                          // only one pane → nothing to hide
        XCTAssertFalse(store.isMaximized)
        XCTAssertEqual(store.grid.paneIDs, [a])
    }

    func testClosingWhileMaximizedEndsMaximizeState() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)      // grid [a][b]

        store.toggleMaximize(a)                          // maximize a, remembering [a][b]
        XCTAssertTrue(store.isMaximized)

        // Closing a session drops the remembered layout, so there is nothing to
        // restore to — the ⤢ button reverts to "maximize" and the grid stays [a].
        store.close(store.session(for: b)!)
        XCTAssertFalse(store.isMaximized)
        XCTAssertEqual(store.grid.paneIDs, [a])
    }
}

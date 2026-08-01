import XCTest
@testable import mTerm

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testRenameWorkspaceChangesOnlyDisplayNameAndPersists() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        defaults.set(
            try JSONEncoder().encode([folder]),
            forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)

        store.renameWorkspace(folder.id, to: "  Client   API  ")

        XCTAssertEqual(store.workspaces[0].name, "Client API")
        XCTAssertEqual(store.workspaces[0].path, "/tmp/example-workspace")

        let reloadedStore = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.workspaces[0].name, "Client API")
        XCTAssertEqual(reloadedStore.workspaces[0].path, "/tmp/example-workspace")
    }

    func testInvalidWorkspaceRenameLeavesNameUnchanged() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        defaults.set(
            try JSONEncoder().encode([folder]),
            forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)

        store.renameWorkspace(folder.id, to: "   \n   ")

        XCTAssertEqual(store.workspaces[0].name, "example-workspace")
    }

    func testRemoveWorkspaceDetachesSessionsWithoutClosingThem() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        defaults.set(
            try JSONEncoder().encode([folder]),
            forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)
        store.createSession(in: folder)
        let session = try XCTUnwrap(store.sessions.last)

        store.removeWorkspace(folder.id)

        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertEqual(store.session(for: session.id)?.workspaceID, nil)
        XCTAssertEqual(store.session(for: session.id)?.status, .running)
        XCTAssertTrue(store.grid.paneIDs.contains(session.id))
    }

    func testCreateSessionInSameDirectoryPreservesWorkspaceAndOpensSplit() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        defaults.set(
            try JSONEncoder().encode([folder]),
            forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)
        store.createSession(in: folder)
        let source = try XCTUnwrap(store.sessions.last)
        store.setWorkingDirectory(source.id, report: "file:///tmp/example-workspace/Sources")

        store.createSessionInSameDirectory(as: source.id)

        let created = try XCTUnwrap(store.sessions.last)
        XCTAssertNotEqual(created.id, source.id)
        XCTAssertEqual(created.workingDirectory, "/tmp/example-workspace/Sources")
        XCTAssertEqual(created.workspaceID, folder.id)
        XCTAssertTrue(store.grid.paneIDs.contains(source.id))
        XCTAssertTrue(store.grid.paneIDs.contains(created.id))
    }

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

    func testRenameSessionUpdatesStableAndDisplayedTitle() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.renameSession(session.id, to: "  API   server  ")

        XCTAssertEqual(store.session(for: session.id)?.title, "API server")
        XCTAssertEqual(
            store.session(for: session.id).map(store.displayTitle(for:)),
            "API server")
    }

    func testUserRenameOverridesAgentTitle() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]
        store.setForeground(session.id, command: "claude")
        store.setAgentTitle(session.id, title: "Agent conversation")

        store.renameSession(session.id, to: "My terminal")
        store.setAgentTitle(session.id, title: "Later agent title")

        XCTAssertEqual(
            store.session(for: session.id).map(store.displayTitle(for:)),
            "My terminal")
    }

    func testRenameSessionRejectsEmptyAndControlCharacterTitles() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.renameSession(session.id, to: "   ")
        store.renameSession(session.id, to: "bad\ntitle")

        XCTAssertEqual(store.session(for: session.id)?.title, session.title)
    }

    func testOpenInNewPaneAddsHiddenSessionWithoutReplacingVisiblePane() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let hidden = store.sessions[0].id
        store.createSession()
        let visible = store.sessions[1].id
        XCTAssertEqual(store.grid.paneIDs, [visible])

        store.openInNewPane(hidden)

        XCTAssertEqual(store.grid.paneIDs.count, 2)
        XCTAssertTrue(store.grid.paneIDs.contains(hidden))
        XCTAssertTrue(store.grid.paneIDs.contains(visible))
        XCTAssertEqual(store.selectedSessionID, hidden)
    }

    func testOpenInNewPaneFocusesAlreadyVisibleSessionWithoutChangingLayout() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openInNewPane(a)
        let layout = store.grid
        store.openInActivePane(b)

        store.openInNewPane(a)

        XCTAssertEqual(store.grid, layout)
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

    func testWorkingDirectoryFollowsTerminalOSC7Report() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sessionID = store.sessions[0].id

        store.setWorkingDirectory(
            sessionID,
            report: "file:///Users/test/Documents/Folder%20With%20Spaces")

        XCTAssertEqual(
            store.session(for: sessionID)?.workingDirectory,
            "/Users/test/Documents/Folder With Spaces")
    }

    func testWorkingDirectoryIgnoresInvalidTerminalReport() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.setWorkingDirectory(session.id, report: "https://example.com/not-a-directory")
        store.setWorkingDirectory(UUID(), report: "file:///tmp/unrelated-session")

        XCTAssertEqual(store.session(for: session.id)?.workingDirectory, session.workingDirectory)
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

    // MARK: moveSession

    func testMoveSessionReordersWithinOpenSessions() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.createSession()
        let c = store.sessions[2].id

        // Move a to after c: [a,b,c] -> [b,c,a]
        store.moveSession(a, relativeTo: c, insertAfter: true)
        XCTAssertEqual(store.sessions.map(\.id), [b, c, a])
    }

    func testMoveSessionInsertBefore() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.createSession()
        let c = store.sessions[2].id

        store.moveSession(c, relativeTo: a, insertAfter: false)   // [a,b,c] -> [c,a,b]
        XCTAssertEqual(store.sessions.map(\.id), [c, a, b])
    }

    func testMoveSessionIgnoredAcrossSections() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let loose = store.sessions[0].id
        let folder = WorkspaceFolder(path: "/tmp/repo")
        store.createSession(in: folder)
        let inFolder = store.sessions[1].id
        let before = store.sessions.map(\.id)

        // Different workspaceID -> no-op.
        store.moveSession(loose, relativeTo: inFolder, insertAfter: true)
        XCTAssertEqual(store.sessions.map(\.id), before)
    }

    // MARK: focusGridPane

    func testFocusGridPaneSelectsNthVisiblePane() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)   // grid [a][b]

        store.focusGridPane(at: 0)
        XCTAssertEqual(store.selectedSessionID, a)
        store.focusGridPane(at: 1)
        XCTAssertEqual(store.selectedSessionID, b)
    }

    func testFocusGridPaneOutOfRangeIsNoOp() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.focusGridPane(at: 5)                    // only one pane
        XCTAssertEqual(store.selectedSessionID, a)
    }

    func testShortcutNumberMatchesVisualPaneOrder() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id
        store.createSession()
        let b = store.sessions[1].id
        store.createSession()
        let c = store.sessions[2].id

        store.openSingle(a)
        store.place(b, onPaneWith: a, zone: .right)   // [a][b]
        store.place(c, onPaneWith: a, zone: .bottom)  // [a,c][b]

        XCTAssertEqual(store.shortcutNumber(for: a), 1)
        XCTAssertEqual(store.shortcutNumber(for: c), 2)
        XCTAssertEqual(store.shortcutNumber(for: b), 3)
    }

    func testShortcutNumberIsNilForHiddenSession() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.createSession()
        let hidden = store.sessions[0].id
        let visible = store.sessions[1].id

        XCTAssertNil(store.shortcutNumber(for: hidden))
        XCTAssertEqual(store.shortcutNumber(for: visible), 1)
    }

    // MARK: terminal creation shortcuts

    func testCommandNCreatesOpenSessionAndReplacesFocusedPaneNotHoveredPane() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let left = store.sessions[0].id
        store.createSession(asNewPane: true)
        let focused = store.sessions[1].id
        store.hoveredSessionID = left

        store.createOpenSessionFromFocusedPane()

        let created = store.sessions.last!
        XCTAssertNil(created.workspaceID)
        XCTAssertEqual(store.grid.paneIDs.count, 2)
        XCTAssertTrue(store.grid.paneIDs.contains(left))
        XCTAssertTrue(store.grid.paneIDs.contains(created.id))
        XCTAssertFalse(store.grid.paneIDs.contains(focused))
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testShiftCommandNCreatesOpenSessionInAnotherPane() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let original = store.sessions[0].id

        store.createOpenSessionFromFocusedPane(asNewPane: true)

        let created = store.sessions.last!
        XCTAssertNil(created.workspaceID)
        XCTAssertEqual(store.grid.paneIDs.count, 2)
        XCTAssertTrue(store.grid.paneIDs.contains(original))
        XCTAssertTrue(store.grid.paneIDs.contains(created.id))
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testShiftCommandNReplacesFocusedPaneWhenGridIsFull() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        for _ in 0..<5 {
            store.createSession(asNewPane: true)
        }
        XCTAssertEqual(store.grid.paneIDs.count, 6)

        store.focusGridPane(at: 1)
        let focused = store.selectedSessionID!
        store.hoveredSessionID = store.grid.paneIDs.last
        let panesBefore = Set(store.grid.paneIDs)

        store.createOpenSessionFromFocusedPane(asNewPane: true)

        let created = store.sessions.last!
        var expectedPanes = panesBefore
        expectedPanes.remove(focused)
        expectedPanes.insert(created.id)
        XCTAssertEqual(Set(store.grid.paneIDs), expectedPanes)
        XCTAssertEqual(store.grid.paneIDs.count, 6)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testCommandTCreatesSessionAtFocusedWorkspaceRootAndReplacesFocusedPane() throws {
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([folder]), forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)
        let openSession = store.sessions[0].id
        store.createSession(in: folder, asNewPane: true)
        let focused = store.selectedSessionID!
        store.setWorkingDirectory(focused, report: "/tmp/example-workspace/subdirectory")
        store.hoveredSessionID = openSession

        store.createWorkspaceSessionFromFocusedPane()

        let created = store.sessions.last!
        XCTAssertEqual(created.workspaceID, folder.id)
        XCTAssertEqual(created.workingDirectory, folder.path)
        XCTAssertEqual(store.grid.paneIDs.count, 2)
        XCTAssertTrue(store.grid.paneIDs.contains(openSession))
        XCTAssertTrue(store.grid.paneIDs.contains(created.id))
        XCTAssertFalse(store.grid.paneIDs.contains(focused))
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testShiftCommandTCreatesSessionInAnotherPane() throws {
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([folder]), forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)
        store.createSession(in: folder)
        let original = store.selectedSessionID!

        store.createWorkspaceSessionFromFocusedPane(asNewPane: true)

        let created = store.sessions.last!
        XCTAssertEqual(created.workspaceID, folder.id)
        XCTAssertEqual(store.grid.paneIDs.count, 2)
        XCTAssertTrue(store.grid.paneIDs.contains(original))
        XCTAssertTrue(store.grid.paneIDs.contains(created.id))
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testShiftCommandTReplacesFocusedPaneWhenGridIsFull() throws {
        let folder = WorkspaceFolder(path: "/tmp/example-workspace")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([folder]), forKey: "edev.workspace.folders")
        let store = WorkspaceStore(defaults: defaults)
        for _ in 0..<5 {
            store.createSession(in: folder, asNewPane: true)
        }
        XCTAssertEqual(store.grid.paneIDs.count, 6)

        store.focusGridPane(at: 2)
        let focused = store.selectedSessionID!
        store.hoveredSessionID = store.grid.paneIDs.last
        let panesBefore = Set(store.grid.paneIDs)

        store.createWorkspaceSessionFromFocusedPane(asNewPane: true)

        let created = store.sessions.last!
        var expectedPanes = panesBefore
        expectedPanes.remove(focused)
        expectedPanes.insert(created.id)
        XCTAssertEqual(created.workspaceID, folder.id)
        XCTAssertEqual(Set(store.grid.paneIDs), expectedPanes)
        XCTAssertEqual(store.grid.paneIDs.count, 6)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    func testCommandTIsNoOpWhenFocusedSessionIsNotInAWorkspace() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sessionsBefore = store.sessions
        let gridBefore = store.grid

        store.createWorkspaceSessionFromFocusedPane()

        XCTAssertEqual(store.sessions, sessionsBefore)
        XCTAssertEqual(store.grid, gridBefore)
    }

    // MARK: setForeground (shell integration icon state)

    func testSetForegroundTracksClaude() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = store.sessions[0].id

        store.setForeground(a, command: "claude")
        XCTAssertTrue(store.claudeSessionIDs.contains(a))

        store.setForeground(a, command: "git")        // other command clears it
        XCTAssertFalse(store.claudeSessionIDs.contains(a))

        store.setForeground(a, command: "claude")
        store.setForeground(a, command: nil)           // idle clears it
        XCTAssertFalse(store.claudeSessionIDs.contains(a))
    }

    func testSetForegroundTracksCodex() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let id = store.sessions[0].id

        store.setForeground(id, command: "codex")
        XCTAssertTrue(store.codexSessionIDs.contains(id))

        store.setForeground(id, command: "git")
        XCTAssertFalse(store.codexSessionIDs.contains(id))
    }

    func testAgentWorkingStateFollowsSubmissionAndAttention() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.reportAgentInputSubmitted(session.id)
        XCTAssertFalse(store.agentWorkingSessionIDs.contains(session.id))

        store.setForeground(session.id, command: "claude")
        store.reportAgentInputSubmitted(session.id)
        XCTAssertTrue(store.agentWorkingSessionIDs.contains(session.id))

        store.reportClaudeAttention(session.id, kind: .idlePrompt)
        XCTAssertFalse(store.agentWorkingSessionIDs.contains(session.id))

        store.setForeground(session.id, command: "codex")
        store.reportAgentInputSubmitted(session.id)
        XCTAssertTrue(store.agentWorkingSessionIDs.contains(session.id))

        store.reportCodexAttention(session.id)
        XCTAssertFalse(store.agentWorkingSessionIDs.contains(session.id))
    }

    func testAgentWorkingStateClearsWhenAgentExitsOrSessionCloses() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.setForeground(session.id, command: "codex")
        store.reportAgentInputSubmitted(session.id)
        store.setForeground(session.id, command: nil)
        XCTAssertFalse(store.agentWorkingSessionIDs.contains(session.id))

        store.setForeground(session.id, command: "claude")
        store.reportAgentInputSubmitted(session.id)
        store.close(session)
        XCTAssertFalse(store.agentWorkingSessionIDs.contains(session.id))
    }

    func testAgentTitleTemporarilyOverridesStableSessionTitle() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.setAgentTitle(session.id, title: "Ignored before agent starts")
        XCTAssertEqual(store.displayTitle(for: session), session.title)

        store.setForeground(session.id, command: "claude")
        store.setAgentTitle(session.id, title: "  Refactor   authentication  ")
        XCTAssertEqual(store.displayTitle(for: session), "Refactor authentication")
        XCTAssertEqual(store.session(for: session.id)?.title, session.title)

        store.setForeground(session.id, command: nil)
        XCTAssertEqual(store.displayTitle(for: session), session.title)

        store.setAgentTitle(session.id, title: "Delayed title after exit")
        XCTAssertEqual(store.displayTitle(for: session), session.title)
    }

    func testAgentTitleUpdatesForResumeAndClearsOnNextCommand() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]

        store.setForeground(session.id, command: "codex")
        store.setAgentTitle(session.id, title: "Initial prompt")
        store.setAgentTitle(session.id, title: "Resumed checkout refactor")
        XCTAssertEqual(store.displayTitle(for: session), "Resumed checkout refactor")

        store.setForeground(session.id, command: "git")
        XCTAssertEqual(store.displayTitle(for: session), session.title)
    }

    func testCodexUUIDResolvesAutomaticTitleWithoutDisplayingIdentifier() async {
        let threadID = UUID(uuidString: "019f9217-1cc5-72a2-8569-8f19f2d4f3b8")!
        let store = WorkspaceStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            codexTitleLookup: { receivedID in
                XCTAssertEqual(receivedID, threadID)
                return "Notifications hiện tại đang được xử lý như nào"
            })
        let session = store.sessions[0]

        store.setForeground(session.id, command: "codex")
        store.setAgentTitle(session.id, title: threadID.uuidString.lowercased())
        XCTAssertEqual(store.displayTitle(for: session), session.title)

        for _ in 0..<20 where store.displayTitle(for: session) == session.title {
            await Task.yield()
        }
        XCTAssertEqual(
            store.displayTitle(for: session),
            "Notifications hiện tại đang được xử lý như nào")
    }

    func testManualCodexTitleOverridesMetadataLookup() async {
        let threadID = UUID(uuidString: "019f9217-1cc5-72a2-8569-8f19f2d4f3b8")!
        let store = WorkspaceStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            codexTitleLookup: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return "Automatic title"
            })
        let session = store.sessions[0]

        store.setForeground(session.id, command: "codex")
        store.setAgentTitle(session.id, title: threadID.uuidString)
        store.setAgentTitle(session.id, title: "Renamed checkout refactor")
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(store.displayTitle(for: session), "Renamed checkout refactor")
    }

    func testCloseClearsClaudeState() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.createSession()
        let b = store.sessions[1].id
        store.setForeground(b, command: "claude")
        XCTAssertTrue(store.claudeSessionIDs.contains(b))
        store.close(store.session(for: b)!)
        XCTAssertFalse(store.claudeSessionIDs.contains(b))
    }

    func testCloseClearsCodexState() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]
        store.setForeground(session.id, command: "codex")
        store.setAgentTitle(session.id, title: "Fix launch crash")
        XCTAssertEqual(store.displayTitle(for: session), "Fix launch crash")

        store.close(session)

        XCTAssertFalse(store.codexSessionIDs.contains(session.id))
        XCTAssertEqual(store.displayTitle(for: session), session.title)
    }

    func testClaudeAttentionResolvesAndForwardsLiveSession() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]
        var received: (SessionRecord, ClaudeIntegration.AttentionKind)?
        store.onClaudeAttention = { received = ($0, $1) }

        store.reportClaudeAttention(session.id, kind: .permissionPrompt)

        XCTAssertEqual(received?.0, session)
        XCTAssertEqual(received?.1, .permissionPrompt)

        store.close(session)
        received = nil
        store.reportClaudeAttention(session.id, kind: .idlePrompt)
        XCTAssertNil(received)
    }

    func testCodexAttentionResolvesAndForwardsLiveSession() {
        let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = store.sessions[0]
        var received: SessionRecord?
        store.onCodexAttention = { received = $0 }

        store.reportCodexAttention(session.id)

        XCTAssertEqual(received, session)

        store.close(session)
        received = nil
        store.reportCodexAttention(session.id)
        XCTAssertNil(received)
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

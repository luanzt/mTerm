import XCTest
@testable import mTerm

@MainActor
final class WorkspaceSnapshotStoreTests: XCTestCase {
    func testDefaultURLUsesVersionedApplicationSupportFile() {
        let url = WorkspaceSnapshotStore.defaultFileURL

        XCTAssertEqual(url.lastPathComponent, "workspace-v1.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "mTerm")
    }

    func testFlushCreatesParentDirectoriesAndWritesDecodableSnapshot() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = WorkspaceSnapshotStore(fileURL: fixture.fileURL)

        store.flush(snapshot(sequence: 7))

        let data = try Data(contentsOf: fixture.fileURL)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.sessionSequence, 7)
    }

    func testDebounceWritesOnlyNewestScheduledSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = WorkspaceSnapshotStore(
            fileURL: fixture.fileURL,
            debounceInterval: 0.01)

        store.schedule { self.snapshot(sequence: 1) }
        store.schedule { self.snapshot(sequence: 2) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let data = try Data(contentsOf: fixture.fileURL)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.sessionSequence, 2)
    }

    func testFlushCancelsPendingWriteAndPersistsNewestSnapshotSynchronously() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = WorkspaceSnapshotStore(
            fileURL: fixture.fileURL,
            debounceInterval: 0.01)

        store.schedule { self.snapshot(sequence: 1) }
        store.flush(snapshot(sequence: 2))
        XCTAssertEqual(try loadSequence(from: fixture.fileURL), 2)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try loadSequence(from: fixture.fileURL), 2)
    }

    func testDiscardCancelsPendingWriteAndRemovesStoredSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = WorkspaceSnapshotStore(
            fileURL: fixture.fileURL,
            debounceInterval: 0.01)
        store.flush(snapshot(sequence: 1))
        store.schedule { self.snapshot(sequence: 2) }

        store.discard()

        XCTAssertFalse(store.containsStoredSnapshot)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.containsStoredSnapshot)
    }

    func testLoadReturnsSnapshotWrittenByAnotherStore() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        WorkspaceSnapshotStore(fileURL: fixture.fileURL)
            .flush(snapshot(sequence: 11))

        let loaded = WorkspaceSnapshotStore(fileURL: fixture.fileURL).load()

        XCTAssertEqual(loaded?.sessionSequence, 11)
    }

    func testMalformedJSONReturnsNilWithoutModifyingFile() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let malformed = Data("{ definitely not JSON".utf8)
        try malformed.write(to: fixture.fileURL)
        let store = WorkspaceSnapshotStore(fileURL: fixture.fileURL)

        XCTAssertNil(store.load())
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), malformed)
    }

    private func snapshot(sequence: Int) -> WorkspaceSnapshot {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        return WorkspaceSnapshot(
            schemaVersion: WorkspaceSnapshot.currentSchemaVersion,
            sessions: [
                SessionSnapshot(
                    id: id,
                    stableTitle: "Terminal 1",
                    workingDirectory: "/tmp",
                    workspaceID: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    wasManuallyRenamed: false,
                    activeAgent: nil),
            ],
            grid: PaneGridSnapshot(columns: [
                .init(panes: [id], widthFraction: 1, rowFraction: 0.5),
            ]),
            savedGrid: nil,
            selectedSessionID: id,
            isSidebarVisible: true,
            sessionSequence: sequence)
    }

    private func loadSequence(from fileURL: URL) throws -> Int {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder()
            .decode(WorkspaceSnapshot.self, from: data)
            .sessionSequence
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mterm-snapshot-store-\(UUID().uuidString)",
                                  isDirectory: true)
        return Fixture(
            root: root,
            fileURL: root.appendingPathComponent("nested/workspace-v1.json"))
    }

    private struct Fixture {
        let root: URL
        let fileURL: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

import XCTest
@testable import mTerm

final class RemoteAttachmentStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSafeNamesNeedNoQuotingAndCannotEscapeTheFolder() {
        XCTAssertEqual(RemoteAttachmentStore.safeName("Ảnh chụp màn hình 2026.PNG"), "Anh-chup-man-hinh-2026.PNG")
        XCTAssertEqual(RemoteAttachmentStore.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(RemoteAttachmentStore.safeName(".env"), "env")
        XCTAssertEqual(RemoteAttachmentStore.safeName("report (final) @v2.pdf"), "report-final-v2.pdf")
        XCTAssertEqual(RemoteAttachmentStore.safeName("/"), "attachment")
        XCTAssertEqual(RemoteAttachmentStore.safeName("ảnh"), "anh")
        let long = RemoteAttachmentStore.safeName(String(repeating: "a", count: 300) + ".jpeg")
        XCTAssertEqual(long.count, 100)
        XCTAssertTrue(long.hasSuffix(".jpeg"))
    }

    func testSaveKeepsEachUploadInItsOwnFolder() throws {
        let store = RemoteAttachmentStore(root: root)
        let first = try store.save(Data("one".utf8), named: "shot.png", id: UUID())
        let second = try store.save(Data("two".utf8), named: "shot.png", id: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
        XCTAssertFalse(first.path.contains(" "))
    }

    func testRemoveExpiredDropsOnlyOldUploads() throws {
        let store = RemoteAttachmentStore(root: root)
        let old = try store.save(Data("old".utf8), named: "old.png", id: UUID())
        let fresh = try store.save(Data("new".utf8), named: "new.png", id: UUID())
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: eightDaysAgo], ofItemAtPath: old.deletingLastPathComponent().path)

        store.removeExpired()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}

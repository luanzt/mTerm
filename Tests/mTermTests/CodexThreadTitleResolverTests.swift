import XCTest
@testable import mTerm

final class CodexThreadTitleResolverTests: XCTestCase {
    func testParsesOnlyBareThreadUUID() {
        let raw = "019f9217-1cc5-72a2-8569-8f19f2d4f3b8"
        XCTAssertEqual(
            CodexThreadTitleResolver.threadID(from: raw)?.uuidString.lowercased(),
            raw)
        XCTAssertNil(CodexThreadTitleResolver.threadID(from: "\(raw) | Ready"))
        XCTAssertNil(CodexThreadTitleResolver.threadID(from: "Fix notifications"))
    }

    func testReadsOnlyMatchingThreadMetadataAndPrefersName() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-title-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }

        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT);
        INSERT INTO threads VALUES
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', 'Automatic title', 'Manual name'),
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b9', 'Other private title', NULL);
        """)

        let matchingID = UUID(uuidString: "019f9217-1cc5-72a2-8569-8f19f2d4f3b8")!
        XCTAssertEqual(
            CodexThreadTitleResolver.readTitle(for: matchingID, codexHome: codexHome),
            "Manual name")
    }

    func testFallsBackToAutomaticTitleWhenThreadIsUnnamed() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-title-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }

        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT);
        INSERT INTO threads VALUES
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', 'Automatic title', NULL);
        """)

        let matchingID = UUID(uuidString: "019f9217-1cc5-72a2-8569-8f19f2d4f3b8")!
        XCTAssertEqual(
            CodexThreadTitleResolver.readTitle(for: matchingID, codexHome: codexHome),
            "Automatic title")
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CodexThreadTitleResolverTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self),
                ])
        }
    }
}

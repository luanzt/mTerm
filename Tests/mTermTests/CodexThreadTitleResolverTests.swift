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

    func testReadsUniqueThreadIDForExactNameAndWorkingDirectory() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-locator-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, cwd TEXT);
        INSERT INTO threads VALUES
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', 'Automatic', 'Client API', '/tmp/client'),
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b9', 'Other', 'Client API', '/tmp/other');
        """)

        XCTAssertEqual(
            CodexThreadTitleResolver.readThreadID(
                forExactName: "Client API",
                workingDirectory: "/tmp/client/../client",
                codexHome: codexHome)?.uuidString.lowercased(),
            "019f9217-1cc5-72a2-8569-8f19f2d4f3b8")
    }

    func testNameLookupReturnsNilWhenExactNameAndDirectoryAreAmbiguous() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-ambiguous-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, cwd TEXT);
        INSERT INTO threads VALUES
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', NULL, 'Same name', '/tmp/project'),
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b9', NULL, 'Same name', '/tmp/project');
        """)

        XCTAssertNil(CodexThreadTitleResolver.readThreadID(
            forExactName: "Same name",
            workingDirectory: "/tmp/project",
            codexHome: codexHome))
    }

    func testNameLookupRejectsWrongDirectoryBlankNameAndMalformedUUID() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-invalid-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, cwd TEXT);
        INSERT INTO threads VALUES
          ('not-a-uuid', NULL, 'Broken', '/tmp/project'),
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', NULL, '', '/tmp/project');
        """)

        XCTAssertNil(CodexThreadTitleResolver.readThreadID(
            forExactName: "Broken",
            workingDirectory: "/tmp/project",
            codexHome: codexHome))
        XCTAssertNil(CodexThreadTitleResolver.readThreadID(
            forExactName: "",
            workingDirectory: "/tmp/project",
            codexHome: codexHome))
        XCTAssertNil(CodexThreadTitleResolver.readThreadID(
            forExactName: "Broken",
            workingDirectory: "/tmp/other",
            codexHome: codexHome))
    }

    func testNameLookupReturnsNilForDatabaseWithoutCWDColumn() throws {
        let manager = FileManager.default
        let codexHome = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-old-schema-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: codexHome) }
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT);
        INSERT INTO threads VALUES
          ('019f9217-1cc5-72a2-8569-8f19f2d4f3b8', NULL, 'Legacy');
        """)

        XCTAssertNil(CodexThreadTitleResolver.readThreadID(
            forExactName: "Legacy",
            workingDirectory: "/tmp/project",
            codexHome: codexHome))
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

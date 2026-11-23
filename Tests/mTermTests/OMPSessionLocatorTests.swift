import XCTest
@testable import mTerm

final class OMPSessionLocatorTests: XCTestCase {
    func testFindsTheSessionFileAProcessHoldsOpenForWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mterm-omp-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/-Documents-app 3", isDirectory: true)
        let subagents = sessions.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = sessions.appendingPathComponent("main.jsonl")
        let subagent = subagents.appendingPathComponent("0-Explore.jsonl")
        let readOnly = sessions.appendingPathComponent("older.jsonl")
        try Data().write(to: readOnly)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3>>\"$1\" 4>>\"$2\" 5<\"$3\"; sleep 10",
                             "sh", subagent.path, main.path, readOnly.path]
        try process.run()
        defer { process.terminate() }

        var found: String?
        for _ in 0..<100 {
            found = OMPSessionLocator.sessionFile(openedBy: process.processIdentifier)
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       main.resolvingSymlinksInPath().path)
    }

    func testIgnoresNonSessionPaths() {
        XCTAssertFalse(OMPSessionLocator.isSessionFile("/tmp/log.jsonl"))
        XCTAssertFalse(OMPSessionLocator.isSessionFile("/x/sessions/a.json"))
        XCTAssertTrue(OMPSessionLocator.isSessionFile("/x/sessions/-app/a.jsonl"))
    }
}

import XCTest
@testable import mTerm

final class CodexIntegrationTests: XCTestCase {
    private func payload(_ text: String) -> ArraySlice<UInt8> {
        ArraySlice(Array(text.utf8))
    }

    func testAcceptsCodexOSC9Messages() {
        XCTAssertTrue(CodexIntegration.shouldReportAttention(
            payload("Agent turn complete"),
            foregroundCommand: "codex"))
        XCTAssertTrue(CodexIntegration.shouldReportAttention(
            payload("Approval requested: git push"),
            foregroundCommand: "codex"))
    }

    func testRejectsOSC9WhenCodexIsNotTheForegroundCommand() {
        for command in [nil, "claude", "git"] {
            XCTAssertFalse(CodexIntegration.shouldReportAttention(
                payload("Agent turn complete"),
                foregroundCommand: command))
        }
    }

    func testRejectsEmptyControlInvalidUTF8AndOversizedPayloads() {
        for invalid in [
            payload(""),
            payload("   "),
            ArraySlice([0x41, 0x07]),
            ArraySlice([0xFF, 0xFE]),
            payload(String(repeating: "x", count: 4_097)),
        ] {
            XCTAssertFalse(CodexIntegration.shouldReportAttention(
                invalid,
                foregroundCommand: "codex"))
        }
    }

    func testWritesExecutableShimWithPerInvocationOverrides() throws {
        XCTAssertTrue(CodexIntegration.writeFiles())
        let shim = CodexIntegration.shimDirectory.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shim.path))

        let contents = try String(contentsOf: shim, encoding: .utf8)
        XCTAssertTrue(contents.contains("tui.notifications=true"))
        XCTAssertTrue(contents.contains("tui.notification_method=\"osc9\""))
        XCTAssertTrue(contents.contains("tui.notification_condition=\"always\""))
        XCTAssertTrue(contents.contains("\"$@\""))
    }

    func testShimPreservesArgumentsAndLetsLaterUserConfigOverride() throws {
        XCTAssertTrue(CodexIntegration.writeFiles())
        let manager = FileManager.default
        let fakeBin = manager.temporaryDirectory
            .appendingPathComponent("mterm-codex-test-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fakeBin) }

        let fakeCodex = fakeBin.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf '%s\\n' "$@"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let shim = CodexIntegration.shimDirectory.appendingPathComponent("codex")
        let process = Process()
        let output = Pipe()
        process.executableURL = shim
        process.arguments = ["resume", "--last", "-c", "tui.notifications=false"]
        process.environment = [
            "PATH": "\(CodexIntegration.shimDirectory.path):\(fakeBin.path):/usr/bin:/bin",
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let arguments = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, [
            "-c", "tui.notifications=true",
            "-c", "tui.notification_method=\"osc9\"",
            "-c", "tui.notification_condition=\"always\"",
            "resume", "--last",
            "-c", "tui.notifications=false",
        ])
    }
}

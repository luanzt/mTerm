import XCTest
@testable import mTerm

final class ClaudeIntegrationTests: XCTestCase {
    private func payload(_ text: String) -> ArraySlice<UInt8> {
        ArraySlice(Array(text.utf8))
    }

    func testParsesPrivateAttentionPayloads() {
        for kind in ClaudeIntegration.AttentionKind.allCases {
            XCTAssertEqual(
                ClaudeIntegration.parse(payload(
                    "notify;\(ClaudeIntegration.payloadMarker);\(kind.rawValue)"
                )),
                kind)
        }
    }

    func testOnlyInteractiveAttentionKindsExpectAResponse() {
        XCTAssertTrue(ClaudeIntegration.AttentionKind.permissionPrompt.expectsUserResponse)
        XCTAssertTrue(ClaudeIntegration.AttentionKind.elicitationDialog.expectsUserResponse)
        XCTAssertTrue(ClaudeIntegration.AttentionKind.agentNeedsInput.expectsUserResponse)
        XCTAssertFalse(ClaudeIntegration.AttentionKind.idlePrompt.expectsUserResponse)
        XCTAssertFalse(ClaudeIntegration.AttentionKind.agentCompleted.expectsUserResponse)
    }

    func testRejectsUnknownSpoofedAndMalformedPayloads() {
        XCTAssertNil(ClaudeIntegration.parse(payload("notify;Other App;idle_prompt")))
        XCTAssertNil(ClaudeIntegration.parse(payload("notify;mTerm Claude;auth_success")))
        XCTAssertNil(ClaudeIntegration.parse(payload("mTerm Claude;idle_prompt")))
        XCTAssertNil(ClaudeIntegration.parse(payload("notify;mTerm Claude;idle_prompt;extra")))
        XCTAssertNil(ClaudeIntegration.parse(
            ArraySlice([0x6E, 0x6F, 0x74, 0x69, 0x66, 0x79, 0x07])))
        XCTAssertFalse(ClaudeIntegration.isTurnCompleted(payload(
            "state;Other App;turn_completed")))
        XCTAssertFalse(ClaudeIntegration.isTurnCompleted(payload(
            "notify;mTerm Claude;turn_completed")))
        XCTAssertFalse(ClaudeIntegration.isTurnStarted(payload(
            "state;Other App;turn_started")))
    }

    func testParsesPrivateTurnStatePayloads() {
        XCTAssertTrue(ClaudeIntegration.isTurnStarted(payload(
            ClaudeIntegration.turnStartedPayload)))
        XCTAssertTrue(ClaudeIntegration.isTurnCompleted(payload(
            ClaudeIntegration.turnCompletedPayload)))
        XCTAssertNil(ClaudeIntegration.parse(payload(
            ClaudeIntegration.turnStartedPayload)))
        XCTAssertNil(ClaudeIntegration.parse(payload(
            ClaudeIntegration.turnCompletedPayload)))
    }

    func testWritesValidPluginAndExecutableScripts() throws {
        XCTAssertTrue(ClaudeIntegration.writeFiles())

        let manifest = ClaudeIntegration.pluginDirectory
            .appendingPathComponent(".claude-plugin/plugin.json")
        let hooks = ClaudeIntegration.pluginDirectory
            .appendingPathComponent("hooks/hooks.json")
        let hookScript = ClaudeIntegration.pluginDirectory
            .appendingPathComponent("scripts/notify.sh")
        let shim = ClaudeIntegration.shimDirectory.appendingPathComponent("claude")

        for jsonURL in [manifest, hooks] {
            let data = try Data(contentsOf: jsonURL)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }

        let hooksText = try String(contentsOf: hooks, encoding: .utf8)
        for kind in ClaudeIntegration.AttentionKind.allCases {
            XCTAssertTrue(hooksText.contains("\"matcher\": \"\(kind.rawValue)\""))
        }
        XCTAssertTrue(hooksText.contains("\"Stop\""))
        XCTAssertTrue(hooksText.contains("\"UserPromptSubmit\""))
        XCTAssertTrue(hooksText.contains("\"turn_started\""))
        XCTAssertTrue(hooksText.contains("\"turn_completed\""))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hookScript.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shim.path))
    }

    func testHookScriptProducesAnAllowlistedOSC777Sequence() throws {
        XCTAssertTrue(ClaudeIntegration.writeFiles())
        let hook = ClaudeIntegration.pluginDirectory
            .appendingPathComponent("scripts/notify.sh")
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = hook
        process.arguments = [ClaudeIntegration.AttentionKind.permissionPrompt.rawValue]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(
            object["terminalSequence"],
            "\u{001B}]777;notify;mTerm Claude;permission_prompt\u{0007}")
    }

    func testStopHookProducesPrivateTurnCompletionSequence() throws {
        XCTAssertTrue(ClaudeIntegration.writeFiles())
        let hook = ClaudeIntegration.pluginDirectory
            .appendingPathComponent("scripts/notify.sh")
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = hook
        process.arguments = ["turn_completed"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(
            object["terminalSequence"],
            "\u{001B}]777;state;mTerm Claude;turn_completed\u{0007}")
    }

    func testPromptHookProducesPrivateTurnStartedSequence() throws {
        XCTAssertTrue(ClaudeIntegration.writeFiles())
        let hook = ClaudeIntegration.pluginDirectory
            .appendingPathComponent("scripts/notify.sh")
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = hook
        process.arguments = ["turn_started"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(
            object["terminalSequence"],
            "\u{001B}]777;state;mTerm Claude;turn_started\u{0007}")
    }
}

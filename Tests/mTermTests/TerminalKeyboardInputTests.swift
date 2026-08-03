import AppKit
import XCTest
@testable import mTerm

final class TerminalKeyboardInputTests: XCTestCase {
    func testShiftReturnProducesLineFeed() {
        XCTAssertEqual(
            TerminalKeyboardInput.shiftEnter(
                keyCode: 36,
                modifierFlags: .shift
            ),
            [0x0A]
        )
    }

    func testShiftKeypadEnterProducesLineFeed() {
        XCTAssertEqual(
            TerminalKeyboardInput.shiftEnter(
                keyCode: 76,
                modifierFlags: [.shift, .numericPad]
            ),
            [0x0A]
        )
    }

    func testPlainReturnKeepsSwiftTermDefaultHandling() {
        XCTAssertNil(
            TerminalKeyboardInput.shiftEnter(
                keyCode: 36,
                modifierFlags: []
            )
        )
    }

    func testOtherModifiedReturnKeepsSwiftTermDefaultHandling() {
        for modifiers: NSEvent.ModifierFlags in [
            [.shift, .command],
            [.shift, .control],
            [.shift, .option],
        ] {
            XCTAssertNil(
                TerminalKeyboardInput.shiftEnter(
                    keyCode: 36,
                    modifierFlags: modifiers
                )
            )
        }
    }

    func testShiftOnAnotherKeyKeepsSwiftTermDefaultHandling() {
        XCTAssertNil(
            TerminalKeyboardInput.shiftEnter(
                keyCode: 0,
                modifierFlags: .shift
            )
        )
    }

    func testPlainReturnSubmitsActiveAgentInput() {
        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "codex"))
        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 76,
            modifierFlags: .numericPad,
            foregroundCommand: "codex"))
    }

    func testCodexSlashCommandDoesNotSubmitAgentInput() {
        for inputLine in ["› /clear", "│ › /clear", "  /rename New title"] {
            XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
                keyCode: 36,
                modifierFlags: [],
                foregroundCommand: "codex",
                codexInputLine: inputLine))
        }

        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "codex",
            codexInputLine: "› please inspect /clear behavior"))
    }

    func testReturnDoesNotSubmitOutsideAgentOrWithEditingModifiers() {
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "git"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "claude"))
        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "claude",
            isClaudeResponseExpected: true))
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: .shift,
            foregroundCommand: "claude"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 0,
            modifierFlags: [],
            foregroundCommand: "codex"))
    }

    func testLaunchReturnDoesNotSubmitAgentInput() {
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "codex",
            isAgentInputMode: false))

        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "codex",
            isAgentInputMode: true,
            agentActivationUptime: 100,
            eventUptime: 100.1))

        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "codex",
            isAgentInputMode: true,
            agentActivationUptime: 100,
            eventUptime: 101))
    }

    func testEscapeAndControlCInterruptActiveAgent() {
        for command in ["claude", "codex"] {
            XCTAssertTrue(TerminalKeyboardInput.isAgentInterruption(
                keyCode: 53,
                modifierFlags: [],
                foregroundCommand: command))
            XCTAssertTrue(TerminalKeyboardInput.isAgentInterruption(
                keyCode: 8,
                modifierFlags: .control,
                foregroundCommand: command))
        }
    }

    func testInterruptionKeysAreRestrictedToActiveAgentAndExactModifiers() {
        XCTAssertFalse(TerminalKeyboardInput.isAgentInterruption(
            keyCode: 53,
            modifierFlags: [],
            foregroundCommand: "git"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentInterruption(
            keyCode: 53,
            modifierFlags: .command,
            foregroundCommand: "claude"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentInterruption(
            keyCode: 8,
            modifierFlags: [],
            foregroundCommand: "codex"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentInterruption(
            keyCode: 8,
            modifierFlags: [.control, .shift],
            foregroundCommand: "codex"))
    }
}

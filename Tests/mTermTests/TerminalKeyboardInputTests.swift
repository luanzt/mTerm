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
        for command in ["claude", "codex"] {
            XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
                keyCode: 36,
                modifierFlags: [],
                foregroundCommand: command))
        }
        XCTAssertTrue(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 76,
            modifierFlags: .numericPad,
            foregroundCommand: "codex"))
    }

    func testReturnDoesNotSubmitOutsideAgentOrWithEditingModifiers() {
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: [],
            foregroundCommand: "git"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 36,
            modifierFlags: .shift,
            foregroundCommand: "claude"))
        XCTAssertFalse(TerminalKeyboardInput.isAgentSubmission(
            keyCode: 0,
            modifierFlags: [],
            foregroundCommand: "codex"))
    }
}

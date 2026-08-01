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
}

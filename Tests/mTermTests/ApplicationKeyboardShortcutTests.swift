import AppKit
import XCTest
@testable import mTerm

final class ApplicationKeyboardShortcutTests: XCTestCase {
    func testOptionFTogglesPaneMaximize() throws {
        let event = try XCTUnwrap(keyEvent(keyCode: 3, modifiers: .option))

        XCTAssertTrue(ApplicationKeyboardShortcut.isTogglePaneMaximize(event))
    }

    func testOtherFModifiersRemainAvailable() throws {
        for modifiers: NSEvent.ModifierFlags in [
            [], .command, .control, .shift, [.option, .shift],
        ] {
            let event = try XCTUnwrap(keyEvent(keyCode: 3, modifiers: modifiers))
            XCTAssertFalse(ApplicationKeyboardShortcut.isTogglePaneMaximize(event))
        }
    }

    func testOptionOtherKeyRemainsAvailable() throws {
        let event = try XCTUnwrap(keyEvent(keyCode: 2, modifiers: .option))

        XCTAssertFalse(ApplicationKeyboardShortcut.isTogglePaneMaximize(event))
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: keyCode)
    }
}

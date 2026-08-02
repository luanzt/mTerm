import AppKit
import XCTest
@testable import mTerm

final class SessionSidebarClickActionTests: XCTestCase {
    func testSingleClickOpensActivePaneImmediately() {
        XCTAssertEqual(
            SessionSidebarClickAction.resolve(clickCount: 1, modifierFlags: []),
            .openActivePane)
    }

    func testCommandClickOpensNewPane() {
        XCTAssertEqual(
            SessionSidebarClickAction.resolve(clickCount: 1, modifierFlags: .command),
            .openNewPane)
    }

    func testSecondClickStartsRenameRegardlessOfModifiers() {
        for modifiers: NSEvent.ModifierFlags in [[], .command] {
            XCTAssertEqual(
                SessionSidebarClickAction.resolve(
                    clickCount: 2,
                    modifierFlags: modifiers),
                .rename)
        }
    }
}

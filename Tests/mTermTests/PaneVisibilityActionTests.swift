import AppKit
import XCTest
@testable import mTerm

final class PaneVisibilityActionTests: XCTestCase {
    func testHoveredCommandClickClosesSession() {
        XCTAssertEqual(
            PaneVisibilityAction.resolve(
                isHovering: true,
                modifierFlags: .command),
            .close)
    }

    func testPlainClickHidesPane() {
        XCTAssertEqual(
            PaneVisibilityAction.resolve(
                isHovering: true,
                modifierFlags: []),
            .hide)
    }

    func testCommandOutsideButtonDoesNotArmClose() {
        XCTAssertEqual(
            PaneVisibilityAction.resolve(
                isHovering: false,
                modifierFlags: .command),
            .hide)
    }
}

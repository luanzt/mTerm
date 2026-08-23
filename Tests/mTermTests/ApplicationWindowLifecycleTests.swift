import AppKit
import XCTest
@testable import mTerm

@MainActor
final class ApplicationWindowLifecycleTests: XCTestCase {
    func testOnlyExactMainWindowIsInterceptedForHide() {
        let main = NSWindow()
        let settings = NSWindow()

        XCTAssertTrue(ApplicationWindowLifecycle.shouldHide(
            candidate: main,
            mainWindow: main))
        XCTAssertFalse(ApplicationWindowLifecycle.shouldHide(
            candidate: settings,
            mainWindow: main))
    }

    func testMissingMainWindowNeverInterceptsClose() {
        XCTAssertFalse(ApplicationWindowLifecycle.shouldHide(
            candidate: NSWindow(),
            mainWindow: nil))
    }
}

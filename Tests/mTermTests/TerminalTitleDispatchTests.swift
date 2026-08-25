import CoreGraphics
import SwiftTerm
import XCTest
@testable import mTerm

final class TerminalTitleDispatchTests: XCTestCase {
    func testCodexRunStateTitleBypassesClaudeAnimationDebounce() {
        let coordinator = TerminalHostView.Coordinator(restorationIntent: nil)
        coordinator.foregroundCommand = "codex"
        let delivered = expectation(description: "Codex run state delivered immediately")
        coordinator.onTerminalTitle = { title in
            XCTAssertEqual(title, "codex | Ready | Fix auth")
            delivered.fulfill()
        }

        coordinator.setTerminalTitle(
            source: LocalProcessTerminalView(frame: .zero),
            title: "codex | Ready | Fix auth")

        wait(for: [delivered], timeout: 0.2)
    }
}

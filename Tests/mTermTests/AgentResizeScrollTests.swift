import AppKit
import SwiftTerm
import XCTest
@testable import mTerm

@MainActor
final class AgentResizeScrollTests: XCTestCase {
    private func scrolledBackTerminal() -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        for i in 0..<800 { view.feed(text: "line \(i)\r\n") }
        view.scrollUp(lines: 20)
        return view
    }

    private func lastVisibleLine(_ view: TerminalView) -> String? {
        let terminal = view.getTerminal()
        return (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .last { !$0.isEmpty }
    }

    /// Agent TUIs clear scrollback and replay the transcript after SIGWINCH;
    /// a viewport the user had scrolled back must land on the replay's tail,
    /// not the top of history.
    func testAgentReplayAfterResizeLandsAtBottom() {
        let view = scrolledBackTerminal()
        let coordinator = TerminalHostView.Coordinator(restorationIntent: nil)
        coordinator.foregroundCommand = "omp"

        coordinator.sizeChanged(source: view, newCols: 80, newRows: 24)
        view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        for i in 0..<800 { view.feed(text: "replay \(i)\r\n") }
        view.feed(text: "> prompt")

        XCTAssertEqual(view.scrollPosition, 1)
        XCTAssertEqual(lastVisibleLine(view), "> prompt")
    }

    func testShellResizeKeepsScrolledBackPosition() {
        let view = scrolledBackTerminal()
        let before = view.getTerminal().buffer.yDisp
        let coordinator = TerminalHostView.Coordinator(restorationIntent: nil)

        coordinator.sizeChanged(source: view, newCols: 80, newRows: 24)

        XCTAssertEqual(view.getTerminal().buffer.yDisp, before)
    }
}

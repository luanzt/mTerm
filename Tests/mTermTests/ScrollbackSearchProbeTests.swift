import AppKit
import SwiftTerm
import XCTest
@testable import mTerm

@MainActor
final class ScrollbackSearchProbeTests: XCTestCase {
    func testSearchFindsMatchPushedIntoScrollback() {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 400),
            font: nil)

        // Put the needle at the very top, then push it far into scrollback
        // (301 lines into a ~24-row view, so line 0 is well off-screen).
        view.feed(text: "NEEDLE unique-marker\r\n")
        for i in 0..<300 {
            view.feed(text: "filler line \(i)\r\n")
        }

        let yDispBefore = view.getTerminal().buffer.yDisp
        let found = view.findNext("unique-marker")
        let yDispAfter = view.getTerminal().buffer.yDisp
        let summary = view.searchMatchSummary("unique-marker")

        FileHandle.standardError.write(Data(
            "PROBE total=\(summary.total) index=\(summary.index) found=\(found) yDispBefore=\(yDispBefore) yDispAfter=\(yDispAfter)\n".utf8))

        XCTAssertEqual(summary.total, 1, "the scrolled-off needle must still be counted")
        XCTAssertTrue(found, "findNext must locate a match in scrollback")
    }
}

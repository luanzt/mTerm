import CoreGraphics
import XCTest
@testable import mTerm

final class ParkedPaneFramesTests: XCTestCase {
    private let deck = CGSize(width: 1200, height: 800)

    /// A session swapped out of its pane must not change PTY size: agent TUIs
    /// answer SIGWINCH by clearing and replaying scrollback.
    func testParkedSessionKeepsItsLastVisibleSizeOffScreen() {
        let frames = ParkedPaneFrames()
        let id = UUID()
        let visible = CGRect(x: 6, y: 6, width: 594, height: 788)

        XCTAssertEqual(frames.frame(for: id, visible: visible, deckSize: deck), visible)

        let parked = frames.frame(for: id, visible: nil, deckSize: deck)
        XCTAssertEqual(parked.size, visible.size)
        XCTAssertLessThan(parked.maxX, 0)
    }

    func testParkedSizeFollowsTheMostRecentVisibleFrame() {
        let frames = ParkedPaneFrames()
        let id = UUID()
        _ = frames.frame(for: id, visible: CGRect(x: 6, y: 6, width: 1188, height: 788), deckSize: deck)
        _ = frames.frame(for: id, visible: CGRect(x: 606, y: 6, width: 588, height: 388), deckSize: deck)

        XCTAssertEqual(frames.frame(for: id, visible: nil, deckSize: deck).size,
                       CGSize(width: 588, height: 388))
    }

    func testNeverVisibleSessionParksAtDeckSize() {
        let parked = ParkedPaneFrames().frame(for: UUID(), visible: nil, deckSize: deck)

        XCTAssertEqual(parked.size, deck)
        XCTAssertLessThan(parked.maxX, 0)
    }
}

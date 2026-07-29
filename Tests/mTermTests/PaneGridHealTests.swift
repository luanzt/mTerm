import XCTest
@testable import mTerm

/// A drag race at the UI layer can momentarily leave the grid with a pane id in
/// two places. `paneFrames` would then give that id a single rect (the last
/// column wins) and blank the earlier column. The grid must self-heal so this
/// inconsistent state can never survive a mutation.
final class PaneGridHealTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testDuplicatePaneIsHealedOnMutation() {
        // `a` appears in both column 0 and column 2 — the bad state.
        var g = PaneGrid(columns: [
            GridColumn(panes: [a, b], widthFraction: 0.33),
            GridColumn(panes: [c], widthFraction: 0.33),
            GridColumn(panes: [a], widthFraction: 0.34),
        ])

        g.place(d, onPaneWith: c, zone: .bottom)

        XCTAssertEqual(g.paneIDs.count, Set(g.paneIDs).count, "grid still has a duplicate id")
        XCTAssertEqual(g.paneIDs.filter { $0 == a }.count, 1, "`a` should appear exactly once")
    }

    func testHealingDropsColumnThatBecomesEmpty() {
        // column 2 holds only the duplicate `a`; healing must remove the column
        // and renormalize widths.
        var g = PaneGrid(columns: [
            GridColumn(panes: [a, b], widthFraction: 0.33),
            GridColumn(panes: [c], widthFraction: 0.33),
            GridColumn(panes: [a], widthFraction: 0.34),
        ])

        g.remove(d)   // no-op target, but still triggers invariant enforcement

        XCTAssertEqual(g.columns.count, 2, "empty column left by de-duplication not dropped")
        let sum = g.columns.reduce(0) { $0 + $1.widthFraction }
        XCTAssertEqual(sum, 1, accuracy: 0.0001, "widths not renormalized after healing")
    }
}

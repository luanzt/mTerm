import XCTest
@testable import EDev

final class PaneGridTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testSingleHasOneColumnOnePane() {
        let g = PaneGrid.single(a)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.paneIDs, [a])
    }

    func testAllowedZonesForSinglePane() {
        let g = PaneGrid.single(a)
        XCTAssertEqual(g.allowedZones(forPaneWith: a),
                       [.center, .left, .right, .top, .bottom])
    }

    func testAllowedZonesNoColumnAddWhenThreeColumns() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.place(c, onPaneWith: b, zone: .right)
        XCTAssertEqual(g.columns.count, 3)
        let zones = g.allowedZones(forPaneWith: c)
        XCTAssertFalse(zones.contains(.left))
        XCTAssertFalse(zones.contains(.right))
        XCTAssertTrue(zones.contains(.top))
    }

    func testAllowedZonesNoRowSplitWhenColumnHasTwoPanes() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        let zones = g.allowedZones(forPaneWith: a)
        XCTAssertFalse(zones.contains(.top))
        XCTAssertFalse(zones.contains(.bottom))
        XCTAssertTrue(zones.contains(.right))
    }

    func testPlaceRightCreatesSecondColumnWithEqualWidths() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        XCTAssertEqual(g.columns.count, 2)
        XCTAssertEqual(g.columns[0].panes, [a])
        XCTAssertEqual(g.columns[1].panes, [b])
        XCTAssertEqual(g.columns[0].widthFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(g.columns[1].widthFraction, 0.5, accuracy: 0.0001)
    }

    func testPlaceLeftInsertsBeforeTargetColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .left)
        XCTAssertEqual(g.columns[0].panes, [b])
        XCTAssertEqual(g.columns[1].panes, [a])
    }

    func testPlaceRightBlockedWhenThreeColumns() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.place(c, onPaneWith: b, zone: .right)
        g.place(d, onPaneWith: c, zone: .right)
        XCTAssertEqual(g.columns.count, 3)
        XCTAssertFalse(g.paneIDs.contains(d))
    }

    func testPlaceBottomSplitsColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].panes, [a, b])
    }

    func testPlaceTopInsertsAbove() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .top)
        XCTAssertEqual(g.columns[0].panes, [b, a])
    }

    func testPlaceBottomBlockedWhenColumnFull() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        g.place(c, onPaneWith: a, zone: .bottom)
        XCTAssertEqual(g.columns[0].panes, [a, b])
        XCTAssertFalse(g.paneIDs.contains(c))
    }

    func testPlaceCenterReplacesSession() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .center)
        XCTAssertEqual(g.paneIDs, [b])
    }

    func testPlaceCenterOnItselfIsNoOp() {
        var g = PaneGrid.single(a)
        g.place(a, onPaneWith: a, zone: .center)
        XCTAssertEqual(g.paneIDs, [a])
    }

    func testMoveRemovesFromOldColumnAndDropsEmptyColumn() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)   // [a][b]
        g.place(b, onPaneWith: a, zone: .bottom)  // move b under a -> [a,b]
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].panes, [a, b])
    }

    func testRemoveDropsEmptyColumnAndNormalizes() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)
        g.remove(b)
        XCTAssertEqual(g.columns.count, 1)
        XCTAssertEqual(g.columns[0].widthFraction, 1, accuracy: 0.0001)
    }

    func testResizeColumnClampsAndPreservesPairTotal() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .right)   // 0.5 / 0.5
        g.resizeColumn(pairLeadingIndex: 0, leadingFraction: 0.99)
        XCTAssertEqual(g.columns[0].widthFraction, 0.8, accuracy: 0.0001)
        XCTAssertEqual(g.columns[1].widthFraction, 0.2, accuracy: 0.0001)
    }

    func testResizeRowClamps() {
        var g = PaneGrid.single(a)
        g.place(b, onPaneWith: a, zone: .bottom)
        g.resizeRow(columnIndex: 0, topFraction: 0.01)
        XCTAssertEqual(g.columns[0].rowFraction, 0.2, accuracy: 0.0001)
    }
}

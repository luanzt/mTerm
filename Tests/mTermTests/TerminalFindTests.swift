import AppKit
import XCTest
@testable import mTerm

final class TerminalFindTests: XCTestCase {
    func testCounterHiddenForEmptyTerm() {
        XCTAssertNil(FindMatchCounter.text(term: "", index: 0, total: 0))
    }

    func testCounterShowsCurrentOverTotal() {
        XCTAssertEqual(FindMatchCounter.text(term: "foo", index: 2, total: 14), "2 / 14")
    }

    func testCounterShowsNoResultsWhenTotalZero() {
        XCTAssertEqual(FindMatchCounter.text(term: "foo", index: 0, total: 0), "No results")
    }

    func testPlainReturnSearchesForward() {
        XCTAssertEqual(FindDirection.fromReturn(modifierFlags: []), .next)
    }

    func testShiftReturnSearchesBackward() {
        XCTAssertEqual(FindDirection.fromReturn(modifierFlags: .shift), .previous)
    }
}

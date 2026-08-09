import XCTest
import SwiftUI
@testable import mTerm

final class ThemePaletteTests: XCTestCase {
    // Guard the default appearance: emerald must match the original constants.
    func testEmeraldPaletteMatchesLegacyConstants() {
        let p = MTermThemeID.emerald.palette
        XCTAssertEqual(p.terminalBackground, 0x0A0C0F)
        XCTAssertEqual(p.terminalForeground, 0xDCDCDC)
        XCTAssertEqual(p.terminalCaret, 0xFFFFFF)
        XCTAssertEqual(p.terminalLinkForeground, 0xA7ABF2)
        XCTAssertEqual(p.terminalLinkHighlight, 0x328EEE)
        XCTAssertEqual(p.deck, Color(hex: 0x0A0C0F))
        XCTAssertEqual(p.sidebar, Color(hex: 0x0F1216))
        XCTAssertEqual(p.header, Color(hex: 0x12151A))
        XCTAssertEqual(p.control, Color(hex: 0x181C22))
        XCTAssertEqual(p.border, Color(hex: 0x262B33))
        XCTAssertEqual(p.sidebarBorder, Color(hex: 0x1E222A))
        XCTAssertEqual(p.controlBorder, Color(hex: 0x2C313A))
        XCTAssertEqual(p.text, Color(hex: 0xE7EAF0))
        XCTAssertEqual(p.dim, Color(hex: 0x8A92A0))
        XCTAssertEqual(p.dim2, Color(hex: 0x565E6A))
        XCTAssertEqual(p.accent, Color(hex: 0x34D399))
        XCTAssertEqual(p.path, Color(hex: 0x7DD3FC))
        XCTAssertEqual(p.prompt, Color(hex: 0x6EE7B7))
    }

    func testCatalogHasSeventeenThemes() {
        XCTAssertEqual(MTermThemeID.allCases.count, 17)
        XCTAssertEqual(MTermThemeID.allCases.first, .emerald)
    }

    func testCurrentDefaultsToEmerald() {
        MTermTheme.current = MTermThemeID.emerald.palette
        XCTAssertEqual(MTermTheme.accent, Color(hex: 0x34D399))
        XCTAssertEqual(MTermTheme.terminalBackground, 0x0A0C0F)
    }
}

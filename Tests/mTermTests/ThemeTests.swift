import XCTest
@testable import mTerm

final class ThemeTests: XCTestCase {
    func testStatusLogoPathsRenderInsideTheirFrames() {
        let frame = CGRect(x: 10, y: 20, width: 48, height: 24)

        for path in [
            ClaudeLogo().path(in: frame),
            OpenAILogo().path(in: frame),
            TerminalChevronLogo().path(in: frame),
            TerminalUnderscoreLogo().path(in: frame),
        ] {
            let bounds = path.boundingRect
            XCTAssertFalse(bounds.isEmpty)
            XCTAssertGreaterThanOrEqual(bounds.minX, frame.minX)
            XCTAssertGreaterThanOrEqual(bounds.minY, frame.minY)
            XCTAssertLessThanOrEqual(bounds.maxX, frame.maxX)
            XCTAssertLessThanOrEqual(bounds.maxY, frame.maxY)
        }
    }

    func testTerminalColorsMatchITermDarkDefaults() {
        XCTAssertEqual(MTermTheme.terminalForeground, 0xDCDCDC)
        XCTAssertEqual(MTermTheme.terminalCaret, 0xFFFFFF)
        XCTAssertEqual(MTermTheme.terminalLinkForeground, 0xA7ABF2)
        XCTAssertEqual(MTermTheme.terminalLinkHighlight, 0x328EEE)
        XCTAssertEqual(MTermTheme.ansiPalette, [
            0x14191E,
            0xB43C2A,
            0x00C200,
            0xC7C400,
            0x2744C7,
            0xC040BE,
            0x00C5C7,
            0xC7C7C7,
            0x686868,
            0xDD7975,
            0x58E790,
            0xECE100,
            0xA7ABF2,
            0xE17EE1,
            0x60FDFF,
            0xFFFFFF,
        ])
    }
}

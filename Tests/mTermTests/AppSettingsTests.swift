import AppKit
import XCTest
@testable import mTerm

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsMatchCurrentTerminalAppearance() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.terminalFontSize, 14)
        XCTAssertEqual(settings.sidebarFontSize, 13)
        XCTAssertEqual(settings.sidebarWidth, 250)
        XCTAssertEqual(settings.newTerminalPlacement, .currentPane)
        XCTAssertEqual(settings.quitBehavior, .restorePanes)
        XCTAssertFalse(settings.opensNewTerminalsInSplit)
        XCTAssertEqual(settings.ansiColors, MTermTheme.ansiPalette)
        XCTAssertNotNil(NSFont(name: settings.terminalFontName, size: 14))
    }

    func testTypographyAndANSIColorsPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        let fontName = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName

        settings.terminalFontName = fontName
        settings.terminalFontSize = 17
        settings.sidebarFontSize = 15
        settings.sidebarWidth = 330
        settings.newTerminalPlacement = .newSplit
        settings.quitBehavior = .startClean
        settings.setANSIColor(0x123456, at: 4)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.terminalFontName, fontName)
        XCTAssertEqual(reloaded.terminalFontSize, 17)
        XCTAssertEqual(reloaded.sidebarFontSize, 15)
        XCTAssertEqual(reloaded.sidebarWidth, 330)
        XCTAssertEqual(reloaded.newTerminalPlacement, .newSplit)
        XCTAssertEqual(reloaded.quitBehavior, .startClean)
        XCTAssertTrue(reloaded.opensNewTerminalsInSplit)
        XCTAssertEqual(reloaded.ansiColors[4], 0x123456)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(100, forKey: "mterm.settings.terminalFontSize")
        defaults.set(2, forKey: "mterm.settings.sidebarFontSize")
        defaults.set(900, forKey: "mterm.settings.sidebarWidth")
        defaults.set([1, 2, 3], forKey: "mterm.settings.ansiColors")
        defaults.set("unsupported", forKey: "mterm.settings.newTerminalPlacement")
        defaults.set("unsupported", forKey: "mterm.settings.quitBehavior")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.terminalFontSize, AppSettings.defaultTerminalFontSize)
        XCTAssertEqual(settings.sidebarFontSize, AppSettings.defaultSidebarFontSize)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.defaultSidebarWidth)
        XCTAssertEqual(settings.ansiColors, MTermTheme.ansiPalette)
        XCTAssertEqual(settings.newTerminalPlacement, .currentPane)
        XCTAssertEqual(settings.quitBehavior, .restorePanes)
    }

    func testResetRestoresDefaultPaletteAndTypography() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        settings.terminalFontSize = 20
        settings.sidebarFontSize = 17
        settings.setANSIColor(0x123456, at: 0)

        settings.resetTypography()
        settings.resetANSIColors()

        XCTAssertEqual(settings.terminalFontSize, AppSettings.defaultTerminalFontSize)
        XCTAssertEqual(settings.sidebarFontSize, AppSettings.defaultSidebarFontSize)
        XCTAssertEqual(settings.ansiColors, MTermTheme.ansiPalette)
    }
}

import XCTest
@testable import mTerm

@MainActor
final class AppSettingsThemeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppSettingsThemeTests-\(UUID().uuidString)")!
    }

    func testDefaultThemeIsEmerald() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(s.themeID, .emerald)
    }

    func testSettingThemeUpdatesCurrentPaletteAndPersists() {
        let d = makeDefaults()
        let s = AppSettings(defaults: d)
        s.themeID = .dracula
        XCTAssertEqual(MTermTheme.current, MTermThemeID.dracula.palette)
        XCTAssertEqual(d.string(forKey: "mterm.settings.themeID"), "dracula")

        // Đọc lại từ defaults khôi phục đúng theme và cập nhật current.
        let s2 = AppSettings(defaults: d)
        XCTAssertEqual(s2.themeID, .dracula)
        XCTAssertEqual(MTermTheme.current, MTermThemeID.dracula.palette)
    }

    func testInvalidStoredThemeFallsBackToEmerald() {
        let d = makeDefaults()
        d.set("not-a-theme", forKey: "mterm.settings.themeID")
        let s = AppSettings(defaults: d)
        XCTAssertEqual(s.themeID, .emerald)
    }
}

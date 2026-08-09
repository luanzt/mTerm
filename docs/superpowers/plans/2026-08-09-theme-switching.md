# Theme Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cho phép người dùng đổi theme giao diện mTerm (17 bảng màu) qua một tab Appearance trong Settings, áp dụng live không tạo lại shell.

**Architecture:** Hướng A — giữ API `MTermTheme.foo`, chuyển các trường theo-theme sang `static var` đọc từ `MTermTheme.current: ThemePalette`. `AppSettings.themeID` (persist UserDefaults) điều khiển palette hiện hành; khi đổi, `objectWillChange` phát ra và các view observe `AppSettings` re-render với màu mới. `TerminalHostView` nhận `themeID` qua tham số để `updateNSView` áp màu terminal live.

**Tech Stack:** Swift, SwiftUI, AppKit, SwiftTerm (fork), SwiftPM, XCTest.

## Global Constraints

- Palette `emerald` phải khớp **đúng** các hằng số hiện tại trong `MTermTheme` để không đổi diện mạo mặc định.
- Không tạo lại SwiftTerm view hay tiến trình shell khi đổi theme (CLAUDE.md).
- Không đụng `ansiColors`, font, sidebar width khi đổi theme.
- Build/test bằng `swift build` / `swift test`, KHÔNG tin diagnostics của SourceKit.
- Commit trực tiếp lên `main` (không PR).

---

### Task 1: `ThemePalette`, `MTermThemeID` catalog, và `MTermTheme` runtime

**Files:**
- Modify: `Sources/mTerm/Views/Theme.swift`
- Test: `Tests/mTermTests/ThemePaletteTests.swift` (Create)

**Interfaces:**
- Produces:
  - `struct ThemePalette` với các stored property `Color`: `deck, terminal, sidebar, header, control, border, sidebarBorder, controlBorder, text, dim, dim2, accent, path, prompt, danger, glow, headerActive, rowHover, rowSelected`; và `UInt32`: `terminalForeground, terminalBackground, terminalCaret, terminalLinkForeground, terminalLinkHighlight`.
  - `static func ThemePalette.make(termHex:textHex:accentHex:borderHex:headHex:dimHex:dim2Hex:pathHex:promptHex:) -> ThemePalette`
  - `enum MTermThemeID: String, CaseIterable, Identifiable` cases: `emerald, ocean, dracula, nord, tokyo, solarized, gruvbox, rose, monokai, graphite, slate, catppuccin, amoled, ember, onyx, carbon, steel`; `var displayName: String`; `var palette: ThemePalette`.
  - `MTermTheme.current: ThemePalette` (var, default `MTermThemeID.emerald.palette`).
  - `MTermTheme.foo` (deck, accent, …, terminalBackground, …) trở thành `static var` đọc từ `current`.

- [ ] **Step 1: Viết test thất bại** — `Tests/mTermTests/ThemePaletteTests.swift`

```swift
import XCTest
import SwiftUI
@testable import mTerm

final class ThemePaletteTests: XCTestCase {
    // Bảo vệ diện mạo mặc định: emerald phải khớp hằng số gốc.
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
        // MTermTheme.current mặc định là emerald; MTermTheme.accent đọc từ current.
        MTermTheme.current = MTermThemeID.emerald.palette
        XCTAssertEqual(MTermTheme.accent, Color(hex: 0x34D399))
        XCTAssertEqual(MTermTheme.terminalBackground, 0x0A0C0F)
    }
}
```

- [ ] **Step 2: Chạy test để xác nhận fail** — `swift test --filter ThemePaletteTests` → FAIL (chưa có `ThemePalette`/`MTermThemeID`).

- [ ] **Step 3: Sửa `Theme.swift`**

Thêm `ThemePalette` + factory:

```swift
struct ThemePalette: Equatable {
    let deck, terminal, sidebar, header, control: Color
    let border, sidebarBorder, controlBorder: Color
    let text, dim, dim2: Color
    let accent, path, prompt, danger: Color
    let glow, headerActive, rowHover, rowSelected: Color
    let terminalForeground, terminalBackground, terminalCaret: UInt32
    let terminalLinkForeground, terminalLinkHighlight: UInt32

    /// Dựng palette từ 9 màu nền tảng của theme (mockup EDev.dc.html chỉ định
    /// nghĩa nhiêu đó). Các bề mặt phụ được gộp về `head`/`border`, hiệu ứng suy
    /// ra từ accent nhất quán với diện mạo hiện tại của app.
    static func make(
        termHex: UInt32, textHex: UInt32, accentHex: UInt32,
        borderHex: UInt32, headHex: UInt32,
        dimHex: UInt32, dim2Hex: UInt32,
        pathHex: UInt32, promptHex: UInt32
    ) -> ThemePalette {
        let accent = Color(hex: accentHex)
        return ThemePalette(
            deck: Color(hex: termHex), terminal: Color(hex: termHex),
            sidebar: Color(hex: headHex), header: Color(hex: headHex),
            control: Color(hex: headHex),
            border: Color(hex: borderHex), sidebarBorder: Color(hex: borderHex),
            controlBorder: Color(hex: borderHex),
            text: Color(hex: textHex), dim: Color(hex: dimHex),
            dim2: Color(hex: dim2Hex),
            accent: accent, path: Color(hex: pathHex),
            prompt: Color(hex: promptHex), danger: Color(hex: 0xF87171),
            glow: accent.opacity(0.14), headerActive: accent.opacity(0.10),
            rowHover: Color.white.opacity(0.05), rowSelected: accent.opacity(0.12),
            terminalForeground: 0xDCDCDC, terminalBackground: termHex,
            terminalCaret: accentHex, terminalLinkForeground: pathHex,
            terminalLinkHighlight: 0x328EEE)
    }
}
```

Thêm `MTermThemeID` (emerald dùng palette verbatim để khớp hằng số gốc; 16 theme còn lại dùng `make`):

```swift
enum MTermThemeID: String, CaseIterable, Identifiable {
    case emerald, ocean, dracula, nord, tokyo, solarized, gruvbox, rose
    case monokai, graphite, slate, catppuccin, amoled, ember, onyx, carbon, steel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emerald: "Emerald"
        case .ocean: "Ocean"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .tokyo: "Tokyo Night"
        case .solarized: "Solarized"
        case .gruvbox: "Gruvbox"
        case .rose: "Rosé Pine"
        case .monokai: "Monokai"
        case .graphite: "Graphite"
        case .slate: "Slate"
        case .catppuccin: "Catppuccin"
        case .amoled: "AMOLED"
        case .ember: "Ember"
        case .onyx: "Onyx"
        case .carbon: "Carbon"
        case .steel: "Steel"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .emerald:
            // Verbatim các hằng số gốc để giữ nguyên diện mạo mặc định.
            return ThemePalette(
                deck: Color(hex: 0x0A0C0F), terminal: Color(hex: 0x0A0C0F),
                sidebar: Color(hex: 0x0F1216), header: Color(hex: 0x12151A),
                control: Color(hex: 0x181C22),
                border: Color(hex: 0x262B33), sidebarBorder: Color(hex: 0x1E222A),
                controlBorder: Color(hex: 0x2C313A),
                text: Color(hex: 0xE7EAF0), dim: Color(hex: 0x8A92A0),
                dim2: Color(hex: 0x565E6A),
                accent: Color(hex: 0x34D399), path: Color(hex: 0x7DD3FC),
                prompt: Color(hex: 0x6EE7B7), danger: Color(hex: 0xF87171),
                glow: Color(hex: 0x34D399).opacity(0.14),
                headerActive: Color(hex: 0x34D399).opacity(0.10),
                rowHover: Color.white.opacity(0.05),
                rowSelected: Color(hex: 0x34D399).opacity(0.12),
                terminalForeground: 0xDCDCDC, terminalBackground: 0x0A0C0F,
                terminalCaret: 0xFFFFFF, terminalLinkForeground: 0xA7ABF2,
                terminalLinkHighlight: 0x328EEE)
        case .ocean:
            return .make(termHex: 0x070D17, textHex: 0xE6EDF7, accentHex: 0x38BDF8, borderHex: 0x17263F, headHex: 0x0B1524, dimHex: 0x7E8CA8, dim2Hex: 0x465067, pathHex: 0x7DD3FC, promptHex: 0x5EEAD4)
        case .dracula:
            return .make(termHex: 0x1E1F29, textHex: 0xF8F8F2, accentHex: 0xBD93F9, borderHex: 0x343746, headHex: 0x22232F, dimHex: 0x9AA0B5, dim2Hex: 0x5A5F74, pathHex: 0x8BE9FD, promptHex: 0x50FA7B)
        case .nord:
            return .make(termHex: 0x242933, textHex: 0xECEFF4, accentHex: 0x88C0D0, borderHex: 0x3B4252, headHex: 0x2A2F3B, dimHex: 0x9AA2B5, dim2Hex: 0x5C657A, pathHex: 0x8FBCBB, promptHex: 0xA3BE8C)
        case .tokyo:
            return .make(termHex: 0x1A1B26, textHex: 0xC0CAF5, accentHex: 0x7AA2F7, borderHex: 0x2A2E42, headHex: 0x1F2233, dimHex: 0x7982A9, dim2Hex: 0x4B5270, pathHex: 0x7DCFFF, promptHex: 0x9ECE6A)
        case .solarized:
            return .make(termHex: 0x002B36, textHex: 0xEEE8D5, accentHex: 0x2AA198, borderHex: 0x0C4753, headHex: 0x073642, dimHex: 0x93A1A1, dim2Hex: 0x586E75, pathHex: 0x268BD2, promptHex: 0x859900)
        case .gruvbox:
            return .make(termHex: 0x1D2021, textHex: 0xEBDBB2, accentHex: 0xFABD2F, borderHex: 0x3C3836, headHex: 0x282828, dimHex: 0xA89984, dim2Hex: 0x665C54, pathHex: 0x83A598, promptHex: 0xB8BB26)
        case .rose:
            return .make(termHex: 0x191724, textHex: 0xE0DEF4, accentHex: 0xEA9A97, borderHex: 0x2A2739, headHex: 0x1F1D2E, dimHex: 0x908CAA, dim2Hex: 0x57536B, pathHex: 0x9CCFD8, promptHex: 0x9CCFD8)
        case .monokai:
            return .make(termHex: 0x1E1F1C, textHex: 0xF8F8F2, accentHex: 0xA6E22E, borderHex: 0x3A3B36, headHex: 0x26271F, dimHex: 0xA6A69C, dim2Hex: 0x5F6058, pathHex: 0x66D9EF, promptHex: 0xA6E22E)
        case .graphite:
            return .make(termHex: 0x161616, textHex: 0xE6E6E6, accentHex: 0xB8BCC4, borderHex: 0x2E2E2E, headHex: 0x1E1E1E, dimHex: 0x9A9A9A, dim2Hex: 0x5C5C5C, pathHex: 0x93A1B3, promptHex: 0x9FB08F)
        case .slate:
            return .make(termHex: 0x111318, textHex: 0xE4E8EF, accentHex: 0x94A3B8, borderHex: 0x262B34, headHex: 0x171A21, dimHex: 0x8891A0, dim2Hex: 0x4C5563, pathHex: 0x7DD3FC, promptHex: 0xA7C0A0)
        case .catppuccin:
            return .make(termHex: 0x1E1E2E, textHex: 0xCDD6F4, accentHex: 0xCBA6F7, borderHex: 0x313244, headHex: 0x24243A, dimHex: 0x9399B2, dim2Hex: 0x585B70, pathHex: 0x89DCEB, promptHex: 0xA6E3A1)
        case .amoled:
            return .make(termHex: 0x000000, textHex: 0xEAEAEA, accentHex: 0x2DD4BF, borderHex: 0x1C1C1C, headHex: 0x0A0A0A, dimHex: 0x8A8A8A, dim2Hex: 0x4A4A4A, pathHex: 0x38BDF8, promptHex: 0x4ADE80)
        case .ember:
            return .make(termHex: 0x17110F, textHex: 0xF0E6DF, accentHex: 0xF97316, borderHex: 0x3A2A22, headHex: 0x211815, dimHex: 0xB39A8C, dim2Hex: 0x6E5648, pathHex: 0xFBBF24, promptHex: 0xFACC15)
        case .onyx:
            return .make(termHex: 0x0D0D0D, textHex: 0xE2E2E2, accentHex: 0xA1A1AA, borderHex: 0x242424, headHex: 0x151515, dimHex: 0x8F8F8F, dim2Hex: 0x525252, pathHex: 0x8A94A6, promptHex: 0x96A68C)
        case .carbon:
            return .make(termHex: 0x181613, textHex: 0xE8E3DC, accentHex: 0xB0A89B, borderHex: 0x302C27, headHex: 0x201D19, dimHex: 0x9C948A, dim2Hex: 0x5C554C, pathHex: 0x9AA39A, promptHex: 0xA3AD8F)
        case .steel:
            return .make(termHex: 0x0F1318, textHex: 0xDFE4EA, accentHex: 0x8EA0B5, borderHex: 0x252C36, headHex: 0x141922, dimHex: 0x8A919D, dim2Hex: 0x4F5763, pathHex: 0x8FB0C9, promptHex: 0x94AD9A)
        }
    }
}
```

Trong `enum MTermTheme`: thêm `static var current: ThemePalette = MTermThemeID.emerald.palette`, và đổi các trường theo-theme từ `static let` sang `static var … { current.… }`. Ví dụ:

```swift
enum MTermTheme {
    static var current: ThemePalette = MTermThemeID.emerald.palette

    // Surfaces
    static var deck: Color { current.deck }
    static var terminal: Color { current.terminal }
    static var sidebar: Color { current.sidebar }
    static var header: Color { current.header }
    static var control: Color { current.control }
    // Lines
    static var border: Color { current.border }
    static var sidebarBorder: Color { current.sidebarBorder }
    static var controlBorder: Color { current.controlBorder }
    // Text
    static var text: Color { current.text }
    static var dim: Color { current.dim }
    static var dim2: Color { current.dim2 }
    // Accents
    static var accent: Color { current.accent }
    static var path: Color { current.path }
    static var prompt: Color { current.prompt }
    static var danger: Color { current.danger }
    // Effects
    static var glow: Color { current.glow }
    static var headerActive: Color { current.headerActive }
    static var rowHover: Color { current.rowHover }
    static var rowSelected: Color { current.rowSelected }
    // Terminal (UInt32)
    static var terminalForeground: UInt32 { current.terminalForeground }
    static var terminalBackground: UInt32 { current.terminalBackground }
    static var terminalCaret: UInt32 { current.terminalCaret }
    static var terminalLinkForeground: UInt32 { current.terminalLinkForeground }
    static var terminalLinkHighlight: UInt32 { current.terminalLinkHighlight }

    // GIỮ NGUYÊN các trường không theo theme (static let):
    static let claude = Color(hex: 0xD97757)
    static let codexBackground = Color(hex: 0xFFFFFF)
    static let codexMark = Color(hex: 0x000000)
    static let terminalIconBackground = Color(hex: 0x2A3038)
    static let terminalIconChevron = Color(hex: 0x32D74B)
    static let terminalIconUnderscore = Color(hex: 0xFFFFFF)
    static let inactivePaneOpacity: Double = 0.92
    static let ansiPalette: [UInt32] = [ /* giữ nguyên 16 giá trị hiện có */ ]
}
```

- [ ] **Step 4: Chạy test** — `swift test --filter ThemePaletteTests` → PASS. Sau đó `swift build` để chắc toàn dự án còn biên dịch (các `static var` mới tương thích call site cũ).

- [ ] **Step 5: Commit**

```bash
git add Sources/mTerm/Views/Theme.swift Tests/mTermTests/ThemePaletteTests.swift
git commit -m "Add ThemePalette catalog and make MTermTheme runtime-switchable"
```

---

### Task 2: `AppSettings.themeID` (persist + cập nhật `MTermTheme.current`)

**Files:**
- Modify: `Sources/mTerm/Store/AppSettings.swift`
- Test: `Tests/mTermTests/AppSettingsThemeTests.swift` (Create)

**Interfaces:**
- Consumes: `MTermThemeID`, `MTermTheme.current` (Task 1).
- Produces: `AppSettings.themeID: MTermThemeID` (`@Published`, persist key `mterm.settings.themeID`); side-effect: gán `MTermTheme.current = themeID.palette` trong `didSet` và trong `init`.

- [ ] **Step 1: Viết test thất bại** — `Tests/mTermTests/AppSettingsThemeTests.swift`

```swift
import XCTest
@testable import mTerm

@MainActor
final class AppSettingsThemeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "AppSettingsThemeTests-\(UUID().uuidString)")!
        return d
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
```

- [ ] **Step 2: Chạy test để xác nhận fail** — `swift test --filter AppSettingsThemeTests` → FAIL (chưa có `themeID`).

- [ ] **Step 3: Sửa `AppSettings.swift`**

Thêm key vào `enum Key`:

```swift
static let themeID = "mterm.settings.themeID"
```

Thêm published property (đặt sau `newTerminalPlacement`):

```swift
@Published var themeID: MTermThemeID {
    didSet {
        defaults.set(themeID.rawValue, forKey: Key.themeID)
        MTermTheme.current = themeID.palette
    }
}
```

Trong `init`, sau khi khởi tạo các property khác, thêm (không dùng `didSet` khi gán trong init nên phải set `current` thủ công):

```swift
let storedTheme = defaults.string(forKey: Key.themeID)
    .flatMap(MTermThemeID.init(rawValue:)) ?? .emerald
themeID = storedTheme
MTermTheme.current = storedTheme.palette
```

- [ ] **Step 4: Chạy test** — `swift test --filter AppSettingsThemeTests` → PASS. Rồi `swift build`.

- [ ] **Step 5: Commit**

```bash
git add Sources/mTerm/Store/AppSettings.swift Tests/mTermTests/AppSettingsThemeTests.swift
git commit -m "Add persisted themeID to AppSettings driving MTermTheme.current"
```

---

### Task 3: Tab Appearance trong `SettingsView`

**Files:**
- Modify: `Sources/mTerm/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppSettings.themeID`, `MTermThemeID.allCases`, `.displayName`, `.palette` (Task 1–2).
- Produces: (UI only) không có ký hiệu cho task khác.

- [ ] **Step 1: Thêm tab vào `TabView`** — chèn trước `typography`:

```swift
appearance
    .tabItem { Label("Appearance", systemImage: "paintbrush") }
```

- [ ] **Step 2: Thêm computed `appearance`** trong `SettingsView`:

```swift
private var appearance: some View {
    VStack(alignment: .leading, spacing: 14) {
        Text("Theme")
            .font(.headline)
        Text("Theme đổi màu giao diện và nền/chữ/con trỏ terminal. Màu ANSI cấu hình riêng ở tab ANSI Colors.")
            .font(.callout)
            .foregroundStyle(.secondary)

        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(MTermThemeID.allCases) { theme in
                    ThemeSwatchButton(
                        theme: theme,
                        isSelected: settings.themeID == theme,
                        action: { settings.themeID = theme })
                }
            }
            .padding(.vertical, 4)
        }

        Spacer()
    }
    .padding(8)
}
```

- [ ] **Step 3: Thêm view con `ThemeSwatchButton`** (cuối file, ngoài `SettingsView`):

```swift
private struct ThemeSwatchButton: View {
    let theme: MTermThemeID
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(p.terminal)
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(p.accent)
                            .frame(width: 12, height: 3)
                        Circle()
                            .fill(p.accent)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border, lineWidth: 1))

                Text(theme.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? p.accent.opacity(0.14) : p.terminal.opacity(0.4)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? p.accent : p.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Build** — `swift build` → thành công. Chạy app `swift run mTerm`, mở Settings (`⌘,`) → tab Appearance hiện lưới 17 theme; click đổi theme thấy giao diện đổi màu live (sidebar/header/pane). (Kiểm tra thủ công vì là UI SwiftUI.)

- [ ] **Step 5: Commit**

```bash
git add Sources/mTerm/Views/SettingsView.swift
git commit -m "Add Appearance tab with theme swatch grid"
```

---

### Task 4: Áp màu terminal theo theme live

**Files:**
- Modify: `Sources/mTerm/Views/TerminalHostView.swift`
- Modify: `Sources/mTerm/Views/WorkspaceView.swift:993` (truyền `themeID`)

**Interfaces:**
- Consumes: `AppSettings.themeID`, `MTermTheme.terminal{Foreground,Background,Caret,LinkForeground,LinkHighlight}` (đọc từ `current`).
- Produces: `TerminalHostView` có thêm stored `let themeID: MTermThemeID`; `Coordinator.appliedThemeID: MTermThemeID?`.

- [ ] **Step 1: Thêm property vào `TerminalHostView`** — sau `let ansiColors: [UInt32]`:

```swift
/// Điều khiển màu nền/chữ/con trỏ/link của terminal theo theme hiện hành.
/// Truyền vào (thay vì đọc static) để SwiftUI gọi lại updateNSView khi đổi theme.
let themeID: MTermThemeID
```

- [ ] **Step 2: Thêm cache vào `Coordinator`** — cạnh `appliedANSIColors`:

```swift
var appliedThemeID: MTermThemeID?
```

- [ ] **Step 3: Áp trong `updateNSView`** — sau block `appliedANSIColors`:

```swift
if context.coordinator.appliedThemeID != themeID {
    nsView.caretColor = NSColor(hex: MTermTheme.terminalCaret)
    nsView.nativeForegroundColor = NSColor(hex: MTermTheme.terminalForeground)
    nsView.nativeBackgroundColor = NSColor(hex: MTermTheme.terminalBackground)
    nsView.layer?.backgroundColor = NSColor(hex: MTermTheme.terminalBackground).cgColor
    nsView.linkForegroundColor = NSColor(hex: MTermTheme.terminalLinkForeground)
    nsView.linkHighlightColor = NSColor(hex: MTermTheme.terminalLinkHighlight)
    context.coordinator.appliedThemeID = themeID
}
```

- [ ] **Step 4: Set cache ban đầu trong `makeNSView`** — sau `context.coordinator.appliedFontSize = fontSize` (dòng ~75):

```swift
context.coordinator.appliedThemeID = themeID
```

- [ ] **Step 5: Truyền `themeID` khi tạo view** — `WorkspaceView.swift`, trong `TerminalHostView(...)` sau `ansiColors: settings.ansiColors,`:

```swift
themeID: settings.themeID,
```

- [ ] **Step 6: Build & chạy** — `swift build`; `swift run mTerm`, đổi theme trong Settings → nền/chữ/con trỏ terminal của pane đang sống đổi màu ngay, KHÔNG reprint prompt / KHÔNG tạo lại shell. `swift test` chạy toàn bộ để chắc không hồi quy.

- [ ] **Step 7: Commit**

```bash
git add Sources/mTerm/Views/TerminalHostView.swift Sources/mTerm/Views/WorkspaceView.swift
git commit -m "Apply terminal colors from selected theme live"
```

---

## Self-Review

- **Spec coverage:** ThemePalette (T1), catalog 17 theme + emerald verbatim (T1), MTermTheme runtime (T1), AppSettings.themeID persist + current (T2), tab Appearance (T3), terminal live + không tạo lại shell (T4), ANSI độc lập (không đụng — mọi task), fallback emerald (T2). Đủ.
- **Placeholder:** `ansiPalette` giữ nguyên 16 giá trị hiện có (T1 note) — khi code phải copy đúng mảng gốc từ file cũ, không để trống.
- **Type consistency:** `MTermThemeID`, `ThemePalette`, `MTermTheme.current`, `themeID` dùng thống nhất giữa các task; `TerminalHostView.themeID` khớp giá trị truyền ở WorkspaceView.

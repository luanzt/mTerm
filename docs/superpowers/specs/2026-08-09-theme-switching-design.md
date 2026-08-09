# Thiết kế: Đổi theme trong Settings

## Bối cảnh

mTerm hiện dùng một bảng màu "Emerald" cố định lúc biên dịch (`MTermTheme` trong
`Sources/mTerm/Views/Theme.swift`), gồm các `static let` được đọc trực tiếp ở
~70 vị trí trong các view, và màu nền/chữ/con trỏ/link của terminal cũng suy ra
từ đó. Thiết kế tham chiếu `EDev.dc.html` (Claude Design project `EDev`) mô tả một
bảng chọn theme đổi qua lại 17 bảng màu bằng cách hoán CSS variables.

Yêu cầu người dùng: **thêm setting đổi theme**.

## Quyết định đã chốt

- **Vị trí:** một tab **Appearance** mới trong cửa sổ Settings (`⌘,`), bên cạnh
  General / Typography / ANSI Colors. Không thêm thanh THEME cố định vào cửa sổ chính.
- **ANSI độc lập:** đổi theme chỉ đổi màu chrome + nền/chữ/con trỏ/link terminal.
  16 màu ANSI vẫn là setting riêng của người dùng với nút reset riêng (không đổi
  theo theme). Đúng như mockup.
- **Kiến trúc (Hướng A):** giữ nguyên API `MTermTheme.foo`, chuyển từ giá trị cố
  định sang giá trị runtime đọc từ một palette hiện hành do `AppSettings` điều khiển.
  Vì gần như mọi view themed đã `@EnvironmentObject settings`, khi theme đổi thì
  `objectWillChange` của `AppSettings` kích hoạt re-render và view đọc màu mới.
  Đây là cùng cơ chế `ansiColors` đang dùng. Không dùng Hướng B (inject qua
  Environment) vì phải sửa ~70 call site.

## Ngoài phạm vi

Mockup còn có command palette `⌘K`, layout presets, và màu theo từng workspace.
Chúng **không** thuộc phạm vi lần này — chỉ làm phần đổi theme.

## Các thành phần

### 1. `ThemePalette` (struct mới, `Theme.swift`)

Một value type gói toàn bộ các trường màu **theo theme** mà `MTermTheme` hiện có:

- Surfaces: `deck`, `terminal`, `sidebar`, `header`, `control`
- Lines: `border`, `sidebarBorder`, `controlBorder`
- Text: `text`, `dim`, `dim2`
- Accents: `accent`, `path`, `prompt`, `danger`
- Effects: `glow`, `headerActive`, `rowHover`, `rowSelected`
- Terminal (`UInt32`): `terminalForeground`, `terminalBackground`, `terminalCaret`,
  `terminalLinkForeground`, `terminalLinkHighlight`

Các trường **không** theo theme vẫn là `static let` trên `MTermTheme` (giữ nguyên):
`claude`, `codexBackground`, `codexMark`, `terminalIconBackground`,
`terminalIconChevron`, `terminalIconUnderscore`, `inactivePaneOpacity`,
`ansiPalette` (reset default cho ANSI).

### 2. Catalog 17 theme

`enum MTermThemeID: String, CaseIterable, Identifiable` với các case:
`emerald, ocean, dracula, nord, tokyo, solarized, gruvbox, rose, monokai,
graphite, slate, catppuccin, amoled, ember, onyx, carbon, steel` (đúng thứ tự
`themeOrder` trong mockup). Mỗi case có `displayName`.

Một hàm/`static` map mỗi `MTermThemeID` → `ThemePalette`, dịch trực tiếp từ bảng
hex trong `EDev.dc.html`:

| Trường palette | Nguồn từ mockup |
| --- | --- |
| `terminal`, `deck`, `terminalBackground` | `term` |
| `text`, `terminalForeground` | `text` |
| `accent`, `terminalCaret` | `accent` |
| `border`, `sidebarBorder`, `controlBorder` | `border` |
| `sidebar`, `header`, `control` | `head` |
| `dim`, `dim2` | `dim`, `dim2` |
| `path` | `path` |
| `prompt` | `prompt` |
| `glow` | `glow` (rgba → Color + opacity) |
| `headerActive` | `headActive` |
| `danger` | giữ `0xF87171` (mockup dùng cố định) |
| `rowHover` | `Color.white.opacity(0.05)` (giữ như hiện tại) |
| `rowSelected` | `accent.opacity(0.12)` |
| `terminalLinkForeground` | dùng `path` của theme (UInt32) |
| `terminalLinkHighlight` | giữ cố định `0x328EEE` (iTerm2 dark link) |

Palette `emerald` phải khớp giá trị hằng hiện tại để không đổi diện mạo mặc định.

### 3. `MTermTheme` chuyển sang runtime (`Theme.swift`)

- Thêm `static var current: ThemePalette` (mặc định = palette `emerald`).
- Đổi mỗi trường theo-theme từ `static let X = …` sang
  `static var X: Color { current.X }` (và `UInt32` cho nhóm terminal).
- Giữ nguyên các `static let` không theo theme và `extension Color(hex:)`.

### 4. `AppSettings` (`Store/AppSettings.swift`)

- Thêm key `mterm.settings.themeID`.
- `@Published var themeID: MTermThemeID { didSet { persist + MTermTheme.current = palette(for: themeID) } }`.
- Load & validate trong `init` (giá trị hỏng → `.emerald`); **đặt
  `MTermTheme.current` ngay trong `init`** để palette đúng trước khi UI dựng lần đầu.
- (Tùy chọn) đưa vào `resetTypography` hay một reset riêng — mặc định KHÔNG reset
  theme khi reset typography; giữ đơn giản.

### 5. `SettingsView` (`Views/SettingsView.swift`)

- Thêm tab **Appearance** (`Label("Appearance", systemImage: "paintbrush")`),
  đặt trước Typography.
- Nội dung: `LazyVGrid` các ô theme. Mỗi ô là `Button` set `settings.themeID`:
  - swatch nhỏ: nền `palette.terminal`, một thanh + một chấm màu `palette.accent`;
  - tên theme (`displayName`);
  - ô đang chọn: viền `palette.accent`, nền accent mờ; ô khác: viền `border`.
- Mô tả ngắn: "Theme đổi màu giao diện và nền/chữ/con trỏ terminal. Màu ANSI được
  cấu hình riêng ở tab ANSI Colors."

### 6. Áp dụng live cho terminal (`Views/TerminalHostView.swift`)

`updateNSView` đã cache & áp font + ANSI theo `settings`. Bổ sung áp
`terminalForeground/Background/Caret/Link` từ `MTermTheme` (tức theme hiện hành),
so với giá trị đã cache trong coordinator, chỉ áp khi đổi. **Không** tạo lại view
hay tiến trình shell (ràng buộc trong CLAUDE.md). Để `updateNSView` chạy khi theme
đổi, view cần phụ thuộc vào `settings.themeID` (nó đã `@EnvironmentObject settings`
hoặc nhận qua binding — xác nhận khi code, thêm phụ thuộc nếu cần).

## Luồng dữ liệu

Người dùng chọn ô theme → `settings.themeID = …` → `didSet` đặt
`MTermTheme.current` + lưu UserDefaults + `objectWillChange` phát ra → mọi view
observe `AppSettings` re-render, đọc `MTermTheme.foo` ra màu mới; `TerminalHostView.
updateNSView` chạy và áp màu terminal mới cho view SwiftTerm đang sống.

## Xử lý lỗi / biên

- `themeID` lưu hỏng hoặc rỗng → fallback `.emerald`.
- Palette `emerald` phải bằng đúng hằng hiện tại (test bảo vệ diện mạo mặc định).
- Không đụng `ansiColors`, font, sidebar width khi đổi theme.

## Kiểm thử

- `AppSettings`: load `themeID` hợp lệ/không hợp lệ; `didSet` cập nhật
  `MTermTheme.current`; persist & đọc lại.
- Catalog: đủ 17 theme, `emerald` khớp hằng số gốc (chống hồi quy diện mạo mặc định),
  không theme nào thiếu trường (mọi trường màu khác `nil`/hợp lệ).
- Không cần UI test cho SwiftUI grid; kiểm thử logic ở tầng store/catalog.

## File thay đổi

- `Sources/mTerm/Views/Theme.swift` — thêm `ThemePalette`, catalog, `current`,
  đổi trường theme sang `static var`.
- `Sources/mTerm/Store/AppSettings.swift` — `themeID`, persist, cập nhật `current`.
- `Sources/mTerm/Views/SettingsView.swift` — tab Appearance.
- `Sources/mTerm/Views/TerminalHostView.swift` — áp màu terminal theo theme live.
- `Tests/mTermTests/…` — test AppSettings + catalog.

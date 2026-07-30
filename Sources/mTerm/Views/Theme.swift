import SwiftUI

/// Central palette for MTerm's "Emerald" dark reskin. Every view reads its colors
/// from here so the theme lives in one place. Values come from the design's
/// skin A (emerald accent over a neutral near-black background).
enum MTermTheme {
    // Surfaces
    static let deck = Color(hex: 0x0A0C0F)       // pane deck background
    static let terminal = Color(hex: 0x0A0C0F)   // terminal area / pane body
    static let sidebar = Color(hex: 0x0F1216)    // sidebar background
    static let header = Color(hex: 0x12151A)     // pane header (inactive)
    static let control = Color(hex: 0x181C22)    // "New terminal" pill

    // Lines
    static let border = Color(hex: 0x262B33)         // pane / control borders
    static let sidebarBorder = Color(hex: 0x1E222A)  // sidebar separators
    static let controlBorder = Color(hex: 0x2C313A)  // pill borders

    // Text
    static let text = Color(hex: 0xE7EAF0)   // primary
    static let dim = Color(hex: 0x8A92A0)    // secondary
    static let dim2 = Color(hex: 0x565E6A)   // tertiary / paths, captions

    // Accents
    static let accent = Color(hex: 0x34D399)  // emerald — focus, running dot
    static let path = Color(hex: 0x7DD3FC)    // cyan — working-dir paths
    static let prompt = Color(hex: 0x6EE7B7)  // shell prompt green
    static let danger = Color(hex: 0xF87171)  // close / exited
    static let claude = Color(hex: 0xD97757)  // Claude terracotta — running-claude icon bg
    static let codexBackground = Color(hex: 0xFFFFFF)  // Codex icon tile
    static let codexMark = Color(hex: 0x000000)        // OpenAI knot

    // Effects
    static let glow = Color(hex: 0x34D399).opacity(0.14)   // focused pane halo
    static let headerActive = accent.opacity(0.10)         // tint over header
    static let rowHover = Color.white.opacity(0.05)
    static let rowSelected = accent.opacity(0.12)

    /// Opacity applied to an unfocused pane — deliberately gentle so terminal
    /// text stays readable (the design's 0.88 dims a bit too hard for reading).
    static let inactivePaneOpacity: Double = 0.92

    // MARK: - Terminal (SwiftTerm) colors
    // Foreground, cursor, link, and ANSI 0–15 mirror iTerm2's dark defaults from
    // `plists/DefaultBookmark.plist`. Keep mTerm's background matched to its deck
    // so the embedded terminal does not appear as a differently colored rectangle.

    static let terminalForeground: UInt32 = 0xDCDCDC
    static let terminalBackground: UInt32 = 0x0A0C0F
    static let terminalCaret: UInt32 = 0xFFFFFF
    static let terminalLinkForeground: UInt32 = 0xA7ABF2  // ANSI bright blue
    static let terminalLinkHighlight: UInt32 = 0x328EEE    // iTerm2 dark link color

    // iTerm2 dark ANSI palette: 8 normal + 8 bright.
    static let ansiPalette: [UInt32] = [
        0x14191E,  // 0  black
        0xB43C2A,  // 1  red
        0x00C200,  // 2  green
        0xC7C400,  // 3  yellow
        0x2744C7,  // 4  blue
        0xC040BE,  // 5  magenta
        0x00C5C7,  // 6  cyan
        0xC7C7C7,  // 7  white
        0x686868,  // 8  bright black
        0xDD7975,  // 9  bright red
        0x58E790,  // 10 bright green
        0xECE100,  // 11 bright yellow
        0xA7ABF2,  // 12 bright blue
        0xE17EE1,  // 13 bright magenta
        0x60FDFF,  // 14 bright cyan
        0xFFFFFF,  // 15 bright white
    ]
}

extension Color {
    /// 24-bit RGB hex literal, e.g. `Color(hex: 0x34D399)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

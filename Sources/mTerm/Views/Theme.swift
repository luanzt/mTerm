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

    // Effects
    static let glow = Color(hex: 0x34D399).opacity(0.14)   // focused pane halo
    static let headerActive = accent.opacity(0.10)         // tint over header
    static let rowHover = Color.white.opacity(0.05)
    static let rowSelected = accent.opacity(0.12)

    /// Opacity applied to an unfocused pane — deliberately gentle so terminal
    /// text stays readable (the design's 0.88 dims a bit too hard for reading).
    static let inactivePaneOpacity: Double = 0.92

    // MARK: - Terminal (SwiftTerm) colors
    // 24-bit RGB. SwiftTerm's built-in default foreground is a ~54% gray
    // (Color(35389,…)), which makes plain output look washed-out; we override it
    // with a bright near-white and install a vibrant 16-color ANSI palette
    // (8 normal + 8 bright) tuned to the Emerald accent so program output pops.

    static let terminalForeground: UInt32 = 0xBBBEC2  // primary text (E7EAF0 dimmed ~19%)
    static let terminalBackground: UInt32 = 0x0A0C0F  // matches the pane deck
    static let terminalCaret: UInt32 = 0xBBBEC2

    // Vibrant palette (~15% desaturated from the pure Tailwind hues so colors
    // read calmer without going gray). 8 normal + 8 bright.
    static let ansiPalette: [UInt32] = [
        0x1B1E23,  // 0  black    (lifted so black-on-bg stays visible)
        0xEA7777,  // 1  red
        0x44CB9A,  // 2  green    (emerald accent)
        0xF2BF3B,  // 3  yellow
        0x69A3EC,  // 4  blue
        0xBC89EF,  // 5  magenta
        0x87D0F3,  // 6  cyan
        0xE7EAEF,  // 7  white
        0x575E68,  // 8  bright black
        0xF3A9A9,  // 9  bright red
        0x7AE1B8,  // 10 bright green
        0xF5D361,  // 11 bright yellow
        0x99C4F3,  // 12 bright blue
        0xD5B7F6,  // 13 bright magenta
        0xBFE4F8,  // 14 bright cyan
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

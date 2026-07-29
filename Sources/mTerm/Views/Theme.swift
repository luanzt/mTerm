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

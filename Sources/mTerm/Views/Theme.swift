import SwiftUI

/// A full color palette for the app chrome plus the terminal's foreground /
/// background / cursor / link colors. Every theme-dependent color lives here so
/// switching themes is a single assignment to `MTermTheme.current`.
struct ThemePalette: Equatable {
    let deck, terminal, sidebar, header, control: Color
    let border, sidebarBorder, controlBorder: Color
    let text, dim, dim2: Color
    let accent, path, prompt, danger: Color
    let glow, headerActive, rowHover, rowSelected: Color
    let terminalForeground, terminalBackground, terminalCaret: UInt32
    let terminalLinkForeground, terminalLinkHighlight: UInt32

    /// Build a palette from the nine base colors a theme defines (the mockup
    /// `EDev.dc.html` specifies only these). Secondary surfaces collapse onto
    /// `head`/`border`, and effects derive from the accent to stay consistent
    /// with the app's existing look.
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
            terminalCaret: accentHex, terminalLinkForeground: 0x61A3E8,
            terminalLinkHighlight: 0x328EEE)
    }
}

/// The user-selectable themes. `emerald` mirrors the app's original hard-coded
/// palette exactly; the rest are translated from the design mockup's swatches.
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
            // Verbatim of the original hard-coded constants so the default
            // appearance is unchanged.
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
                terminalCaret: 0xFFFFFF, terminalLinkForeground: 0x61A3E8,
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

/// Central palette for MTerm. The theme-dependent colors read from
/// `current`, which `AppSettings` swaps when the user picks a theme. Every view
/// reads its colors from here so the theme lives in one place.
enum MTermTheme {
    /// The active palette. `AppSettings` assigns this from the persisted theme.
    static var current: ThemePalette = MTermThemeID.emerald.palette

    // Surfaces
    static var deck: Color { current.deck }         // pane deck background
    static var terminal: Color { current.terminal } // terminal area / pane body
    static var sidebar: Color { current.sidebar }   // sidebar background
    static var header: Color { current.header }     // pane header (inactive)
    static var control: Color { current.control }   // "New terminal" pill

    // Lines
    static var border: Color { current.border }             // pane / control borders
    static var sidebarBorder: Color { current.sidebarBorder } // sidebar separators
    static var controlBorder: Color { current.controlBorder } // pill borders

    // Text
    static var text: Color { current.text }  // primary
    static var dim: Color { current.dim }    // secondary
    static var dim2: Color { current.dim2 }  // tertiary / paths, captions

    // Accents
    static var accent: Color { current.accent }  // focus and selection
    static var path: Color { current.path }      // working-dir paths
    static var prompt: Color { current.prompt }  // shell prompt
    static var danger: Color { current.danger }  // close / exited

    // Effects
    static var glow: Color { current.glow }                 // focused pane halo
    static var headerActive: Color { current.headerActive } // tint over header
    static var rowHover: Color { current.rowHover }
    static var rowSelected: Color { current.rowSelected }

    // MARK: - Terminal (SwiftTerm) colors
    static var terminalForeground: UInt32 { current.terminalForeground }
    static var terminalBackground: UInt32 { current.terminalBackground }
    static var terminalCaret: UInt32 { current.terminalCaret }
    static var terminalLinkForeground: UInt32 { current.terminalLinkForeground }
    static var terminalLinkHighlight: UInt32 { current.terminalLinkHighlight }

    // MARK: - Theme-independent colors

    static let claude = Color(hex: 0xD97757)  // Claude terracotta — running-claude icon bg
    static let codexBackground = Color(hex: 0xFFFFFF)  // Codex icon tile
    static let codexMark = Color(hex: 0x000000)        // OpenAI knot
    static let terminalIconBackground = Color(hex: 0x2A3038)
    static let terminalIconChevron = Color(hex: 0x32D74B)
    static let terminalIconUnderscore = Color(hex: 0xFFFFFF)

    /// Opacity applied to an unfocused pane — deliberately gentle so terminal
    /// text stays readable.
    static let inactivePaneOpacity: Double = 0.92

    /// iTerm2 dark ANSI palette: 8 normal + 8 bright. These are the reset
    /// defaults; `AppSettings.ansiColors` is the live user-selected palette.
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

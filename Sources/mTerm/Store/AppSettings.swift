import AppKit
import Combine
import Foundation

enum NewTerminalPlacement: String, CaseIterable, Identifiable {
    case currentPane
    case newSplit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentPane: "Current Pane"
        case .newSplit: "New Split"
        }
    }
}

enum QuitBehavior: String, CaseIterable, Identifiable {
    case restorePanes
    case startClean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restorePanes: "Restore Panes on Next Launch"
        case .startClean: "Start with a Clean Terminal"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let defaultTerminalFontSize = 14.0
    static let defaultSidebarFontSize = 13.0
    static let defaultSidebarWidth = 250.0
    static let terminalFontSizeRange = 9.0...28.0
    static let sidebarFontSizeRange = 10.0...18.0
    static let sidebarWidthRange = 180.0...420.0
    static let defaultScrollbackLines = 3_000
    static let scrollbackLinesRange = 500...10_000

    private enum Key {
        static let terminalFontName = "mterm.settings.terminalFontName"
        static let terminalFontSize = "mterm.settings.terminalFontSize"
        static let sidebarFontSize = "mterm.settings.sidebarFontSize"
        static let sidebarFontFamily = "mterm.settings.sidebarFontFamily"
        static let sidebarWidth = "mterm.settings.sidebarWidth"
        static let ansiColors = "mterm.settings.ansiColors"
        static let newTerminalPlacement = "mterm.settings.newTerminalPlacement"
        static let quitBehavior = "mterm.settings.quitBehavior"
        static let themeID = "mterm.settings.themeID"
        static let scrollbackLines = "mterm.settings.scrollbackLines"
    }

    private let defaults: UserDefaults

    @Published var terminalFontName: String {
        didSet { defaults.set(terminalFontName, forKey: Key.terminalFontName) }
    }

    @Published var terminalFontSize: Double {
        didSet {
            let clamped = min(max(terminalFontSize, Self.terminalFontSizeRange.lowerBound),
                              Self.terminalFontSizeRange.upperBound)
            if clamped != terminalFontSize {
                terminalFontSize = clamped
            } else {
                defaults.set(terminalFontSize, forKey: Key.terminalFontSize)
            }
        }
    }

    @Published var sidebarFontSize: Double {
        didSet {
            let clamped = min(max(sidebarFontSize, Self.sidebarFontSizeRange.lowerBound),
                              Self.sidebarFontSizeRange.upperBound)
            if clamped != sidebarFontSize {
                sidebarFontSize = clamped
            } else {
                defaults.set(sidebarFontSize, forKey: Key.sidebarFontSize)
            }
        }
    }

    /// Font family for sidebar text and pane-header titles; `nil` keeps the
    /// system interface font.
    @Published var sidebarFontFamily: String? {
        didSet {
            if let sidebarFontFamily {
                defaults.set(sidebarFontFamily, forKey: Key.sidebarFontFamily)
            } else {
                defaults.removeObject(forKey: Key.sidebarFontFamily)
            }
        }
    }

    @Published var sidebarWidth: Double {
        didSet {
            let clamped = min(max(sidebarWidth, Self.sidebarWidthRange.lowerBound),
                              Self.sidebarWidthRange.upperBound)
            if clamped != sidebarWidth {
                sidebarWidth = clamped
            } else {
                defaults.set(sidebarWidth, forKey: Key.sidebarWidth)
            }
        }
    }

    /// Lines of normal-buffer history each terminal pane keeps.
    @Published var scrollbackLines: Int {
        didSet {
            let clamped = min(max(scrollbackLines, Self.scrollbackLinesRange.lowerBound),
                              Self.scrollbackLinesRange.upperBound)
            if clamped != scrollbackLines {
                scrollbackLines = clamped
            } else {
                defaults.set(scrollbackLines, forKey: Key.scrollbackLines)
            }
        }
    }

    @Published private(set) var ansiColors: [UInt32]

    @Published var newTerminalPlacement: NewTerminalPlacement {
        didSet {
            defaults.set(newTerminalPlacement.rawValue, forKey: Key.newTerminalPlacement)
        }
    }

    @Published var quitBehavior: QuitBehavior {
        didSet {
            defaults.set(quitBehavior.rawValue, forKey: Key.quitBehavior)
        }
    }

    @Published var themeID: MTermThemeID {
        didSet {
            defaults.set(themeID.rawValue, forKey: Key.themeID)
            MTermTheme.current = themeID.palette
        }
    }

    var opensNewTerminalsInSplit: Bool { newTerminalPlacement == .newSplit }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let defaultFontName = Self.defaultTerminalFont.fontName
        let storedFontName = defaults.string(forKey: Key.terminalFontName)
        terminalFontName = storedFontName.flatMap { NSFont(name: $0, size: 14) == nil ? nil : $0 }
            ?? defaultFontName

        terminalFontSize = Self.loadedSize(
            defaults.object(forKey: Key.terminalFontSize),
            fallback: Self.defaultTerminalFontSize,
            range: Self.terminalFontSizeRange)
        sidebarFontSize = Self.loadedSize(
            defaults.object(forKey: Key.sidebarFontSize),
            fallback: Self.defaultSidebarFontSize,
            range: Self.sidebarFontSizeRange)
        sidebarFontFamily = defaults.string(forKey: Key.sidebarFontFamily).flatMap {
            NSFontManager.shared.availableMembers(ofFontFamily: $0) == nil ? nil : $0
        }
        sidebarWidth = Self.loadedSize(
            defaults.object(forKey: Key.sidebarWidth),
            fallback: Self.defaultSidebarWidth,
            range: Self.sidebarWidthRange)
        let storedScrollback = (defaults.object(forKey: Key.scrollbackLines) as? NSNumber)?.intValue
        scrollbackLines = storedScrollback.flatMap {
            Self.scrollbackLinesRange.contains($0) ? $0 : nil
        } ?? Self.defaultScrollbackLines

        let storedPalette = defaults.array(forKey: Key.ansiColors) as? [NSNumber]
        if let storedPalette, storedPalette.count == 16 {
            ansiColors = storedPalette.map(\.uint32Value)
        } else {
            ansiColors = MTermTheme.ansiPalette
        }

        newTerminalPlacement = defaults.string(forKey: Key.newTerminalPlacement)
            .flatMap(NewTerminalPlacement.init(rawValue:))
            ?? .currentPane

        quitBehavior = defaults.string(forKey: Key.quitBehavior)
            .flatMap(QuitBehavior.init(rawValue:))
            ?? .restorePanes

        let storedTheme = defaults.string(forKey: Key.themeID)
            .flatMap(MTermThemeID.init(rawValue:)) ?? .emerald
        themeID = storedTheme
        MTermTheme.current = storedTheme.palette
    }

    func terminalFont() -> NSFont {
        NSFont(name: terminalFontName, size: CGFloat(terminalFontSize))
            ?? NSFont.monospacedSystemFont(
                ofSize: CGFloat(terminalFontSize),
                weight: .regular)
    }

    /// The chosen sidebar family at `weight`, or `nil` for the system font.
    func sidebarFont(size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        guard let sidebarFontFamily else { return nil }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: sidebarFontFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
    }

    func setANSIColor(_ color: UInt32, at index: Int) {
        guard ansiColors.indices.contains(index) else { return }
        ansiColors[index] = color & 0x00FF_FFFF
        defaults.set(ansiColors.map(NSNumber.init(value:)), forKey: Key.ansiColors)
    }

    func resetANSIColors() {
        ansiColors = MTermTheme.ansiPalette
        defaults.removeObject(forKey: Key.ansiColors)
    }

    func resetTypography() {
        terminalFontName = Self.defaultTerminalFont.fontName
        terminalFontSize = Self.defaultTerminalFontSize
        sidebarFontSize = Self.defaultSidebarFontSize
        sidebarFontFamily = nil
    }

    private static var defaultTerminalFont: NSFont {
        ["MesloLGS NF", "MesloLGS NF Regular", "MesloLGSNF-Regular"]
            .lazy
            .compactMap { NSFont(name: $0, size: defaultTerminalFontSize) }
            .first
            ?? NSFont.monospacedSystemFont(
                ofSize: defaultTerminalFontSize,
                weight: .regular)
    }

    private static func loadedSize(
        _ storedValue: Any?,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let value = (storedValue as? NSNumber)?.doubleValue,
              range.contains(value) else {
            return fallback
        }
        return value
    }
}

struct TerminalFontChoice: Identifiable, Equatable {
    let id: String
    let familyName: String
}

enum TerminalFontCatalog {
    @MainActor
    static let choices: [TerminalFontChoice] = {
        var preferredByFamily: [String: (font: NSFont, score: Int)] = [:]

        let systemMonospaced = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let systemFamily = systemMonospaced.familyName
            ?? systemMonospaced.displayName
            ?? "System Monospaced"
        preferredByFamily[systemFamily] = (systemMonospaced, 0)

        for fontName in NSFontManager.shared.availableFonts {
            guard let font = NSFont(name: fontName, size: 14), font.isFixedPitch else {
                continue
            }
            let traits = font.fontDescriptor.symbolicTraits
            let score = (traits.contains(.bold) ? 1 : 0)
                + (traits.contains(.italic) ? 1 : 0)
            let family = font.familyName ?? font.displayName ?? font.fontName
            if preferredByFamily[family] == nil || score < preferredByFamily[family]!.score {
                preferredByFamily[family] = (font, score)
            }
        }

        return preferredByFamily
            .map { family, value in
                TerminalFontChoice(id: value.font.fontName, familyName: family)
            }
            .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }()
}

/// Families offered for the sidebar: those carrying Nerd Font icons, which
/// agents such as OMP put at the start of session titles.
enum SidebarFontCatalog {
    /// A Nerd Fonts Devicons glyph; plain fonts, including the system font,
    /// leave this private-use code point uncovered.
    private static let nerdFontProbe: Unicode.Scalar = "\u{E711}"

    @MainActor
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { family in
            guard let font = NSFont(
                descriptor: NSFontDescriptor(fontAttributes: [.family: family]),
                size: 13) else { return false }
            return font.coveredCharacterSet.contains(nerdFontProbe)
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

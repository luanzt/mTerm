import AppKit
import CoreText
import SwiftUI

/// Sidebar and pane-header text is always the system font. Agents such as OMP
/// prefix session titles with Nerd Font private-use icons the system font
/// lacks, so those glyphs cascade to a Nerd Font bundled with the app.
enum SidebarFont {
    private static let nerdFontFile = "JetBrainsMonoNerdFontMono-Regular"
    private static let nerdFontName = "JetBrainsMonoNFM-Regular"

    /// Makes the bundled Nerd Font available to this process. Call once at
    /// launch, before any sidebar text is drawn.
    static func registerNerdFont() {
        guard let url = resourceBundle?.url(forResource: nerdFontFile, withExtension: "ttf") else {
            assertionFailure("Bundled Nerd Font is missing")
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> Font {
        let system = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = system.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(name: nerdFontName, size: size)],
        ])
        return Font(NSFont(descriptor: descriptor, size: size) ?? system)
    }

    /// SwiftPM's resource bundle. `swift build` puts it beside the executable;
    /// scripts/package.sh copies it into the app's Contents/Resources.
    private static var resourceBundle: Bundle? {
        Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("mTerm_mTerm.bundle")) }
    }
}

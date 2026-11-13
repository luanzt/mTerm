// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mTerm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mTerm", targets: ["mTerm"]),
    ],
    dependencies: [
        // Fork of SwiftTerm with reflow made per-terminal configurable (off for
        // shell prompts, on for foreground programs), deferrable child PTY
        // resizes, configurable foreground/highlight colors for OSC 8 links,
        // manual selections that survive output while mouse tracking is off,
        // a saved cursor that survives lowering the scrollback limit, and
        // Sixel/iTerm2 images that erasing or printing over their cells removes.
        // The pinned revision is the tip of the fork's `mterm` branch. See the
        // dependency notes in CLAUDE.md before updating it.
        .package(url: "https://github.com/luanzt/SwiftTerm.git",
                 revision: "111c89d6c83a6338908d6287c0d31cc2f390e900"),
        .package(url: "https://github.com/sparkle-project/Sparkle",
                 exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "mTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // The Nerd Font that sidebar text falls back to (SidebarFont).
            resources: [.copy("Resources/JetBrainsMonoNerdFontMono-Regular.ttf")]),
        .testTarget(name: "mTermTests", dependencies: ["mTerm"]),
    ])

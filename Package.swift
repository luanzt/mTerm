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
        // and a saved cursor that survives lowering the scrollback limit.
        // The pinned revision is the tip of the fork's `mterm` branch. See the
        // dependency notes in CLAUDE.md before updating it.
        .package(url: "https://github.com/luanzt/SwiftTerm.git",
                 revision: "0dea75d0e94133b5055b807da662da7afbb655b1"),
        .package(url: "https://github.com/sparkle-project/Sparkle",
                 exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "mTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .testTarget(name: "mTermTests", dependencies: ["mTerm"]),
    ])

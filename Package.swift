// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mTerm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mTerm", targets: ["mTerm"]),
    ],
    dependencies: [
        // Fork of SwiftTerm with reflow-on-resize disabled (isReflowEnabled=false).
        // Upstream rewraps lines on resize, which makes zsh/powerlevel10k leave
        // duplicated prompt lines on every resize; the fork pins the exact upstream
        // revision we used plus that one-line change. See luanzt/SwiftTerm@edev-no-reflow.
        .package(url: "https://github.com/luanzt/SwiftTerm.git",
                 revision: "7d05ba66b6770a88fd48c3fa1cdfa5d3a1657848"),

    ],
    targets: [
        .executableTarget(
            name: "mTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        .testTarget(name: "mTermTests", dependencies: ["mTerm"]),
    ])

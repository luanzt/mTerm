// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EDev",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EDev", targets: ["EDev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "EDev",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        .testTarget(name: "EDevTests", dependencies: ["EDev"]),
    ])

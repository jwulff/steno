// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "steno", targets: ["Steno"])
    ],
    dependencies: [
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Steno",
            dependencies: [
                "SwiftTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/Steno"
        ),
        .testTarget(
            name: "StenoTests",
            dependencies: ["Steno"],
            path: "Tests/StenoTests"
        )
    ]
)

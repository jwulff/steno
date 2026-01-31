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
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", revision: "537133031bc2b2731048d00748c69700e1b48185"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Steno",
            dependencies: [
                "SwiftTUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift")
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

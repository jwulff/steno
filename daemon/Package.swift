// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StenoDaemon",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "steno-daemon", targets: ["StenoDaemon"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "StenoDaemon",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/StenoDaemon"
        ),
        .testTarget(
            name: "StenoDaemonTests",
            dependencies: ["StenoDaemon"],
            path: "Tests/StenoDaemonTests"
        )
    ]
)

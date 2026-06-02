// swift-tools-version: 6.2
// Steno macOS app — a native SwiftUI front-end to the steno-daemon.
//
// Zero external dependencies: SwiftUI, Network, and SQLite3 all ship in the
// macOS SDK. The app is a thin client of the daemon (same Unix socket + the
// same read-only SQLite the TUI uses) — it owns none of the capture or
// transcription logic.
//
// Two targets so the wire logic is unit-testable independent of the UI:
//   • StenoCore — protocol, framing, socket client, daemon launcher, SQLite
//     reader, and the observable app model. No SwiftUI.
//   • StenoApp  — the @main SwiftUI app: views, menu bar, design system.

import PackageDescription

let package = Package(
    name: "StenoApp",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "StenoApp", targets: ["StenoApp"])
    ],
    targets: [
        .target(
            name: "StenoCore",
            path: "Sources/StenoCore"
        ),
        .executableTarget(
            name: "StenoApp",
            dependencies: ["StenoCore"],
            path: "Sources/StenoApp"
        ),
        .testTarget(
            name: "StenoCoreTests",
            dependencies: ["StenoCore"],
            path: "Tests/StenoCoreTests"
        )
    ]
)

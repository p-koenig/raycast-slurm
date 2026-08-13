// swift-tools-version: 6.0
//
// SlurmKit — the UI-free core of SlurmBar.
//
// This package deliberately has no package dependencies (Swift Testing ships with the
// Swift 6 toolchain) so that the test suite runs with Command Line Tools alone — no full
// Xcode required until the App target. See macos/docs/ARCHITECTURE.md § "Testing & CI".
//
// NOTE for Command Line Tools-only machines: run the suite via
//   macos/scripts/test-slurmkit.sh
// rather than bare `swift test`. CLT ships Testing.framework outside the Xcode platform
// layout that SwiftPM knows about, and SwiftPM's synthesized test runner guards its
// Swift Testing entry point with `#if canImport(Testing)` — so bare `swift test` exits 0
// having executed *nothing*. The script supplies the search paths and fails loudly if no
// tests ran. On machines with Xcode installed it is a plain `swift test`.

import PackageDescription

let package = Package(
    name: "SlurmKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SlurmKit", targets: ["SlurmKit"])
    ],
    targets: [
        .target(
            name: "SlurmKit",
            path: "Sources/SlurmKit"
        ),
        .testTarget(
            name: "SlurmKitTests",
            dependencies: ["SlurmKit"],
            path: "Tests/SlurmKitTests"
        ),
    ]
)

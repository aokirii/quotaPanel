// swift-tools-version:5.9
import PackageDescription

// Portable core for the Linux/GNOME port of QuotaPanel.
//
// This package is deliberately independent of the macOS app: it has no
// SwiftUI/AppKit/Security/UserNotifications/Charts dependencies, so it builds
// with the open-source Swift toolchain on Linux. The macOS app is untouched.
//
//   QuotaPanelCore     — data models + the provider fetch engine (a library)
//   quotapanel-daemon  — polls enabled providers and writes status.json, which
//                        the GNOME Shell extension reads and renders.
let package = Package(
    name: "QuotaPanelCore",
    platforms: [
        // Also builds on macOS so the core can be exercised during development;
        // the shipping target is Linux.
        .macOS(.v13)
    ],
    products: [
        .library(name: "QuotaPanelCore", targets: ["QuotaPanelCore"]),
        .executable(name: "quotapanel-daemon", targets: ["quotapanel-daemon"]),
    ],
    targets: [
        .target(name: "QuotaPanelCore"),
        .executableTarget(
            name: "quotapanel-daemon",
            dependencies: ["QuotaPanelCore"]
        ),
    ]
)

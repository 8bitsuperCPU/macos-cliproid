// swift-tools-version: 6.2

import PackageDescription

// ClipRoid is a SwiftPM package with no .xcodeproj, matching the layout of ~/projects/nyx.
// Scripts/bundle.sh assembles the .app; SwiftPM only ever produces the bare executable.
//
// The target graph exists to keep one rule enforceable by the compiler:
// ClipRoidStore and ClipRoidPlatform cannot import each other. Nothing that touches a
// pasteboard is allowed to know a database exists, and nothing that touches the database
// is allowed to reach for AppKit. ClipRoidKit is the only place both are visible, which is
// what makes the whole capture pipeline testable against a fake pasteboard and a temp store.
let package = Package(
    name: "ClipRoid",
    platforms: [
        // Tahoe. Buys FoundationModels (§4.18 ships in v1, not v2) and lets ScreenCaptureKit
        // and Vision be used without availability guards. Revised up from the spec's 14.0.
        .macOS(.v26)
    ],
    products: [
        .executable(name: "ClipRoidApp", targets: ["ClipRoidApp"]),
        .library(name: "ClipRoidKit", targets: ["ClipRoidKit"]),
    ],
    targets: [
        // Pure domain. Foundation only — no AppKit, no CoreGraphics, no SQLite3.
        // Runs under `swift test` in milliseconds with no window server and no TCC prompts,
        // which is why the bulk of the test suite lives against this target.
        .target(
            name: "ClipRoidCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // CoreGraphics/ImageIO only, deliberately no AppKit, so thumbnail tests run headless.
        .target(
            name: "ClipRoidImaging",
            dependencies: ["ClipRoidCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // SQLite + on-disk blob store. Must not import ClipRoidPlatform.
        .target(
            name: "ClipRoidStore",
            dependencies: ["ClipRoidCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Thin adapters over the system. One file per ClipRoidCore capability protocol.
        // Almost none of it is unit-testable, which is the reason to keep it small.
        // Must not import ClipRoidStore.
        .target(
            name: "ClipRoidPlatform",
            dependencies: ["ClipRoidCore", "ClipRoidImaging"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("FoundationModels"),
            ]
        ),

        // Services and the AppEnvironment composition root. The only target that sees both
        // Store and Platform.
        .target(
            name: "ClipRoidKit",
            dependencies: ["ClipRoidCore", "ClipRoidStore", "ClipRoidPlatform", "ClipRoidImaging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "ClipRoidUI",
            dependencies: ["ClipRoidKit", "ClipRoidCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),

        // @main only. Must not be named main.swift.
        .executableTarget(
            name: "ClipRoidApp",
            dependencies: ["ClipRoidUI", "ClipRoidKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(name: "ClipRoidCoreTests", dependencies: ["ClipRoidCore"]),
        .testTarget(name: "ClipRoidImagingTests", dependencies: ["ClipRoidImaging"]),
        .testTarget(name: "ClipRoidStoreTests", dependencies: ["ClipRoidStore", "ClipRoidCore"]),
        .testTarget(name: "ClipRoidKitTests", dependencies: ["ClipRoidKit", "ClipRoidCore"]),
        .testTarget(name: "ClipRoidUITests", dependencies: ["ClipRoidUI"]),
    ]
)

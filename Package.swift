// swift-tools-version: 6.0
//
//  AtlasOSS — clean-room, local-first visual library for macOS.
//  P0 scope: data layer + CLI. P0.5 adds a minimal read-only SwiftUI viewer.
//
//  `AtlasCore` holds the on-disk library format, SQLite schema and import engine.
//  `atlasoss` is the thin CLI used for import / list / info / bench / verification.
//  `AtlasOSSApp` is the minimal SwiftUI viewer: sidebar of collections + thumbnail grid.
//
import PackageDescription

let package = Package(
    name: "AtlasOSS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "atlasoss", targets: ["atlasoss"]),
        .executable(name: "AtlasOSSApp", targets: ["AtlasOSSApp"]),
    ],
    targets: [
        .target(
            name: "AtlasCore",
            // Raw sqlite3 from the SDK — no third-party dependencies.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "atlasoss",
            dependencies: ["AtlasCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Minimal SwiftUI viewer (P0.5). Read-only: no import UI, no canvas.
        .executableTarget(
            name: "AtlasOSSApp",
            dependencies: ["AtlasCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-logic tests for the P1-A grid feel (density math, anchoring, selection).
        // No SwiftUI rendering — the executable target is linked only for its types.
        .testTarget(
            name: "AtlasOSSAppTests",
            dependencies: ["AtlasOSSApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

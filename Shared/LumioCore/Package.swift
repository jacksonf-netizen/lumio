// swift-tools-version: 6.0
// LumioCore: the code every Lumio app shares (Mac now, Android TV next). No user interface and no
// playback engine here; each app brings its own (see Mac/LumioMac).
//
//   IPTVCore      Models, Xtream client, EPG, database, repositories, server links, playback
//                 state machine. Foundation + GRDB only (no SwiftUI / AppKit / AVFoundation).
//   IPTVBridge    The JSON door the Android TV app (Kotlin) talks to the core through. Platform-
//                 neutral, so its tests run on the Mac too; the Android glue is in AndroidTV/core-bridge.
//   LumioUpdate   Update signatures (CryptoKit on Apple platforms, swift-crypto elsewhere) and,
//                 on the Mac, installing them; shared by the Mac app and its installer service.

import PackageDescription

let package = Package(
    name: "LumioCore",
    // macOS, and Android for the Android TV app (Docs/AndroidTV/plan.md). Android needs no entry
    // here; its minimum version comes from the build (API 28).
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IPTVCore", targets: ["IPTVCore"]),
        .library(name: "LumioUpdate", targets: ["LumioUpdate"]),
        .library(name: "IPTVBridge", targets: ["IPTVBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // CryptoKit's API where CryptoKit doesn't exist (Android). Not linked on Apple platforms.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.1"),
    ],
    targets: [
        .target(
            name: "LumioUpdate",
            dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android, .linux]))]
        ),
        .target(
            name: "IPTVCore",
            dependencies: ["LumioUpdate", .product(name: "GRDB", package: "GRDB.swift")],
            linkerSettings: [
                // System zlib, used to inflate gzipped XMLTV guides.
                .linkedLibrary("z"),
                // Android's log (logcat), used by `Log` there.
                .linkedLibrary("log", .when(platforms: [.android])),
            ]
        ),
        .target(
            name: "IPTVBridge",
            dependencies: ["IPTVCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "IPTVBridgeTests",
            dependencies: ["IPTVBridge", .product(name: "GRDB", package: "GRDB.swift"),
                           .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android, .linux]))],
            // Also read by the Android app's tests (AndroidTV/app/build.gradle.kts, androidTest assets).
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IPTVCoreTests",
            dependencies: ["IPTVCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LumioUpdateTests",
            dependencies: ["LumioUpdate", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android, .linux]))]
        ),
    ]
)

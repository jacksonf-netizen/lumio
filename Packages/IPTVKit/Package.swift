// swift-tools-version: 6.0
// IPTVKit: everything except the macOS app shell.
//
//   IPTVCore      Models, Xtream client, EPG, database, repositories, playback state machine.
//                 Foundation + GRDB only (no SwiftUI / AppKit / AVFoundation).
//   IPTVPlayback  Playback engine implementations (mpv, AVPlayer) behind `PlaybackEngine`.
//   IPTVUI        SwiftUI views and @Observable view models.
//   LumioUpdate   Update signatures and installing (Foundation + CryptoKit only), shared by the
//                 app and its installer service.

import PackageDescription

let package = Package(
    name: "IPTVKit",
    // macOS only for now.
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IPTVCore", targets: ["IPTVCore"]),
        .library(name: "IPTVPlayback", targets: ["IPTVPlayback"]),
        .library(name: "IPTVUI", targets: ["IPTVUI"]),
        .library(name: "LumioUpdate", targets: ["LumioUpdate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // libmpv + FFmpeg as prebuilt xcframeworks. LGPL product only; never use "MPVKit-GPL".
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
    ],
    targets: [
        .target(name: "LumioUpdate"),
        .target(
            name: "IPTVCore",
            dependencies: ["LumioUpdate", .product(name: "GRDB", package: "GRDB.swift")],
            // System zlib, used to inflate gzipped XMLTV guides.
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "IPTVPlayback",
            dependencies: ["IPTVCore", .product(name: "MPVKit", package: "MPVKit")]
        ),
        .target(
            name: "IPTVUI",
            dependencies: ["IPTVCore", "IPTVPlayback", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "IPTVCoreTests",
            dependencies: ["IPTVCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LumioUpdateTests",
            dependencies: ["LumioUpdate"]
        ),
        .testTarget(
            name: "IPTVPlaybackTests",
            dependencies: ["IPTVPlayback"]
        ),
    ]
)

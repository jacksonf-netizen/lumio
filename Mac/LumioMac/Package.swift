// swift-tools-version: 6.0
// LumioMac: the Mac app's own code. The logic it shares with the other apps is in
// Shared/LumioCore; the app shell (windows, menus, installer) is in Mac/App.
//
//   IPTVPlayback  Playback engine implementations (mpv, AVPlayer) behind `PlaybackEngine`.
//   IPTVUI        SwiftUI views and @Observable view models.

import PackageDescription

let package = Package(
    name: "LumioMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "IPTVPlayback", targets: ["IPTVPlayback"]),
        .library(name: "IPTVUI", targets: ["IPTVUI"]),
    ],
    dependencies: [
        .package(path: "../../Shared/LumioCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // libmpv + FFmpeg as prebuilt xcframeworks. LGPL product only; never use "MPVKit-GPL".
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "IPTVPlayback",
            dependencies: [.product(name: "IPTVCore", package: "LumioCore"), .product(name: "MPVKit", package: "MPVKit")]
        ),
        .target(
            name: "IPTVUI",
            dependencies: [.product(name: "IPTVCore", package: "LumioCore"), "IPTVPlayback",
                           .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "IPTVPlaybackTests",
            dependencies: ["IPTVPlayback"]
        ),
    ]
)

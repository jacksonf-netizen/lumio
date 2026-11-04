// swift-tools-version: 6.0
// LumioBridge: the shared core (Shared/LumioCore) built as one Android library, liblumiocore.so,
// with the functions the Android app calls through JNI.
//
// Phase 0 (test build): one hand-written JSON call. Phase 2 replaces it with swift-java.

import Foundation
import PackageDescription

// LUMIO_FULL_ICU=1 builds with Swift's full ICU data instead of Lumio's trimmed set (to compare).
let fullICU = ProcessInfo.processInfo.environment["LUMIO_FULL_ICU"] == "1"

let package = Package(
    name: "LumioBridge",
    products: [
        .library(name: "lumiocore", type: .dynamic, targets: ["LumioBridge"]),
    ],
    dependencies: [
        .package(path: "../../Shared/LumioCore"),
    ],
    targets: [
        // jni.h from the Android NDK.
        .target(name: "CJNI"),
        // Trimmed ICU data replacing Swift's full set (AndroidTV/Tools/build_icu_data.sh).
        .target(
            name: "LumioICUData",
            exclude: ["icudt76l-lumio.dat"],
            cSettings: [.define("LUMIO_ICU_DATA", to: "\"\(Context.packageDirectory)/Sources/LumioICUData/icudt76l-lumio.dat\"")]
        ),
        .target(
            name: "LumioBridge",
            dependencies: ["CJNI", .product(name: "IPTVCore", package: "LumioCore")] + (fullICU ? [] : ["LumioICUData"]),
            swiftSettings: [.swiftLanguageMode(.v5)],
            // With Swift's libraries linked in statically, the curl inside FoundationNetworking needs
            // the SDK's OpenSSL linked too (HTTPS).
            linkerSettings: [
                .linkedLibrary("ssl", .when(platforms: [.android])),
                .linkedLibrary("crypto", .when(platforms: [.android])),
            ]
        ),
    ]
)

# Android TV build environment. Source it before building or testing the Android app:
#
#   source AndroidTV/Tools/env.sh
#
# Versions installed on 2026-11-03 (see "Tooling on this Mac" in Docs/AndroidTV/plan.md). The Mac
# app keeps using Xcode's own Swift; only the Android build uses the open-source toolchain below,
# because the Swift SDK for Android must match its compiler exactly.

LUMIO_NDK_VERSION="30.0.16248370"   # NDK r30
if [ "$(uname)" = Darwin ]; then
    # Java 21 (Homebrew openjdk@21), for Gradle and the Android SDK tools.
    export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    # Android SDK: platform-tools (adb), emulator, platform 36, build-tools 36.1.0, NDK r30, and
    # the Google TV Android 12 image behind the Lumio_GoogleTV_12 emulator.
    export ANDROID_HOME="$HOME/Library/Android/sdk"
    # Open-source Swift 6.4.2, installed in ~/Library/Developer/Toolchains.
    export LUMIO_SWIFT="$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift"
    LUMIO_SWIFT_SDKS="$HOME/Library/org.swift.swiftpm/swift-sdks"
else
    # Linux (CI): Java, the Android SDK and Swift 6.4.2 are set up by the workflow, which sets
    # JAVA_HOME and ANDROID_HOME and puts `swift` on the PATH.
    export LUMIO_SWIFT="${LUMIO_SWIFT:-swift}"
    LUMIO_SWIFT_SDKS="$HOME/.swiftpm/swift-sdks"
fi
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$LUMIO_NDK_VERSION"
# The Swift SDK for Android matching that compiler, and where SwiftPM installs it.
export LUMIO_SWIFT_ANDROID_SDK="swift-6.4.2-RELEASE_android"
export LUMIO_SWIFT_SDK_DIR="$LUMIO_SWIFT_SDKS/$LUMIO_SWIFT_ANDROID_SDK.artifactbundle"
# Lowest Android version the app supports (Android 9).
export LUMIO_ANDROID_API=28

# The AndroidTV folder, as an absolute path (so builds work from any folder).
LUMIO_ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export LUMIO_ANDROID_DIR

export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"

# Android's name for each Swift CPU type (armv7, aarch64, x86_64).
lumio_android_abi() {
    case "$1" in
        armv7) echo armeabi-v7a ;;
        aarch64) echo arm64-v8a ;;
        x86_64) echo x86_64 ;;
        *) echo "unknown CPU type: $1" >&2; return 1 ;;
    esac
}

# Runs `swift build` for one Android CPU type, e.g. `lumio_swift_android armv7` or `aarch64`, with
# the SQLite from AndroidTV/Tools/build_sqlite.sh. Extra arguments go to `swift build`.
lumio_swift_android() {
    local abi sqlite
    abi="$(lumio_android_abi "$1")" || return 1
    sqlite="$LUMIO_ANDROID_DIR/build/sqlite/$abi"
    "$LUMIO_SWIFT" build --build-system swiftbuild --swift-sdk "$LUMIO_SWIFT_ANDROID_SDK" \
        --triple "$1-unknown-linux-android$LUMIO_ANDROID_API" \
        -Xcc -I"$sqlite/include" -Xlinker -L"$sqlite/lib" "${@:2}"
}

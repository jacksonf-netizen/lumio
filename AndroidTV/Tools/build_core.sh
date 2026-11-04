#!/bin/bash
# Builds the shared core for Android as liblumiocore.so (one per CPU type) and puts it, with the
# C++ runtime it needs, into AndroidTV/build/jniLibs, where Gradle packs it into the app.
#
#   AndroidTV/Tools/build_core.sh            # release build, both ARM CPU types
#   AndroidTV/Tools/build_core.sh debug aarch64
#
# Swift's own libraries are linked into liblumiocore.so (static stdlib), so the app ships one
# Swift file per CPU type. Needs SQLite built once (AndroidTV/Tools/build_sqlite.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
source AndroidTV/Tools/env.sh

CONFIG="${1:-release}"
shift || true
ARCHS=("$@")
[ $# -eq 0 ] && ARCHS=(armv7 aarch64)
OUT="$LUMIO_ANDROID_DIR/build/jniLibs"
[ -f "$LUMIO_ANDROID_DIR/core-bridge/Sources/LumioICUData/icudt76l-lumio.dat" ] || AndroidTV/Tools/build_icu_data.sh
STRIP="$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-strip)"

for arch in "${ARCHS[@]}"; do
    abi="$(lumio_android_abi "$arch")"
    scratch="$LUMIO_ANDROID_DIR/build/core-$arch"
    echo "==> liblumiocore.so for $abi ($CONFIG)"
    (cd AndroidTV/core-bridge && lumio_swift_android "$arch" -c "$CONFIG" --static-swift-stdlib \
        --scratch-path "$scratch" 2>&1 | grep -E "error:|warning: unable|Build complete" || true)
    built="$scratch/out/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}-android-$arch/liblumiocore.so"
    [ -f "$built" ] || { echo "Build failed: $built not found" >&2; exit 1; }
    case "$arch" in
        armv7) triple=arm-linux-androideabi ;;
        aarch64) triple=aarch64-linux-android ;;
        x86_64) triple=x86_64-linux-android ;;
    esac
    mkdir -p "$OUT/$abi"
    cp "$built" "$OUT/$abi/liblumiocore.so"
    cp "$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$triple/libc++_shared.so)" "$OUT/$abi/"
    if [ "$CONFIG" = release ]; then
        "$STRIP" --strip-unneeded "$OUT/$abi/liblumiocore.so" "$OUT/$abi/libc++_shared.so"
    fi
    ls -la "$OUT/$abi" | awk 'NR>1 {printf "    %-22s %6.1f MB\n", $9, $5/1048576}'
done

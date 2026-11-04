#!/bin/bash
# Builds the shared core's tests for Android and runs them on a connected device or emulator, so
# the same tests that run on the Mac also run on Android. They use Swift's own (full) ICU data; the
# app's trimmed set is checked by the test app's ICU checks (AndroidTV/Tools/build_icu_data.sh).
#
#   AndroidTV/Tools/run_core_tests.sh                 # 64-bit ARM (the emulator)
#   AndroidTV/Tools/run_core_tests.sh armv7           # 32-bit ARM (the onn HD stick)
#   AndroidTV/Tools/run_core_tests.sh aarch64 --filter CatalogSyncTests
#
# Needs SQLite built once (AndroidTV/Tools/build_sqlite.sh) and `adb devices` to list one device.
set -euo pipefail
cd "$(dirname "$0")/../.."
source AndroidTV/Tools/env.sh

ARCH="${1:-aarch64}"
shift || true
ABI="$(lumio_android_abi "$ARCH")"
SCRATCH="$LUMIO_ANDROID_DIR/build/core-tests-$ARCH"
PRODUCTS="$SCRATCH/out/Products/Debug-android-$ARCH"
DEVICE_DIR="/data/local/tmp/lumio-core-tests"
RUNTIME="$LUMIO_SWIFT_SDK_DIR/swift-android/swift-resources/usr/lib/swift-$ARCH/android"
case "$ARCH" in
    armv7) NDK_TRIPLE=arm-linux-androideabi ;;
    aarch64) NDK_TRIPLE=aarch64-linux-android ;;
    x86_64) NDK_TRIPLE=x86_64-linux-android ;;
esac
LIBCXX="$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so)"

echo "==> Building the core's tests for $ABI"
rm -f "$PRODUCTS"/*-test-runner
(cd Shared/LumioCore && lumio_swift_android "$ARCH" --build-tests --scratch-path "$SCRATCH" 2>&1 | grep -E "error:|Build complete" || true)
[ -f "$PRODUCTS/IPTVCoreTests-test-runner" ] || { echo "Build failed" >&2; exit 1; }

echo "==> Copying to the device"
adb shell "rm -rf $DEVICE_DIR && mkdir -p $DEVICE_DIR" > /dev/null
adb push "$RUNTIME"/*.so "$LIBCXX" "$PRODUCTS"/*-test-runner "$PRODUCTS"/*Tests.so "$DEVICE_DIR/" > /dev/null
for bundle in "$PRODUCTS"/*.bundle; do adb push "$bundle" "$DEVICE_DIR/" > /dev/null; done

status=0
for suite in IPTVCoreTests IPTVBridgeTests LumioUpdateTests; do
    echo "==> Running $suite on $ABI"
    adb shell "cd $DEVICE_DIR && LD_LIBRARY_PATH=. TMPDIR=$DEVICE_DIR/tmp HOME=$DEVICE_DIR sh -c 'mkdir -p tmp; ./$suite-test-runner --testing-library swift-testing $*'" || status=$?
done
exit $status

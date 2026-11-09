# Lumio for Android TV

The Android TV and Google TV app: a Gradle project with the screens (Kotlin, Compose for TV), the
player (Media3 / ExoPlayer) and the Android side of the bridge to the shared core. Everything that
isn't screens or Android-specific code lives in [`Shared/`](../Shared) and is compiled into the app
as `liblumiocore.so`, so the Mac and TV apps behave the same.

## Building

You need the Android SDK, NDK r30, Java 21, and the Swift toolchain and Swift SDK for Android.
`Tools/env.sh` points a terminal at them.

```bash
source AndroidTV/Tools/env.sh
AndroidTV/Tools/build_sqlite.sh
AndroidTV/Tools/build_core.sh debug aarch64
cd AndroidTV && ./gradlew :app:assembleDebug
```

Run `build_sqlite.sh` only once. `build_core.sh` with no arguments builds the release core for both
ARM CPU types. `Tools/run_core_tests.sh` runs the shared core's tests on a connected emulator or
device, and `Tools/make_release.sh` builds the signed release APK (needs the signing key in the
Keychain; see [Docs/Mac/development.md](../Docs/Mac/development.md)).

The plan, device targets, testing from the Mac (emulator and `adb` over Wi-Fi) and what each phase
added are in [Docs/AndroidTV/plan.md](../Docs/AndroidTV/plan.md).

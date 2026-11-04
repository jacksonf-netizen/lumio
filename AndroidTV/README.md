# Lumio for Android TV

The app itself isn't started yet. `Tools/env.sh` sets up a terminal for Android builds (Java, the
Android SDK and NDK, and the Swift toolchain and SDK for Android); run `source AndroidTV/Tools/env.sh`.

This folder will hold the Android TV app (a Gradle project): its screens, its
player (Media3 / ExoPlayer) and the Android side of the bridge to the shared core.

Everything that isn't screens or Android-specific code lives in [`Shared/`](../Shared), so the Mac
app and the Android TV app behave the same. The plan, targets and phases are in
[Docs/AndroidTV/plan.md](../Docs/AndroidTV/plan.md).

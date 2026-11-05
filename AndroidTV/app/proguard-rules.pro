# The shared core is reached through JNI: keep the native functions Kotlin calls, and the listener
# methods the C side looks up by name (AndroidTV/core-bridge/Sources/CJNI/cjni.c).
-keep class com.jackson.lumio.core.LumioCore { native <methods>; }
-keep class com.jackson.lumio.core.CoreListener { *; }

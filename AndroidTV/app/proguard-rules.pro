# The shared core calls nothing in Kotlin yet; Kotlin calls LumioCore.nativeCall, which R8 must keep.
-keep class com.jackson.lumio.LumioCore { native <methods>; }

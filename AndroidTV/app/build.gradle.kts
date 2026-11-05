import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

// The version is shared with the Mac app: version.properties at the top of the repository.
// 0.1.7 → versionCode 1007.
val sharedVersion = Properties().apply {
    rootDir.resolve("../version.properties").inputStream().use { load(it) }
}
val marketingVersion: String = sharedVersion.getProperty("MARKETING_VERSION")
val versionParts = marketingVersion.split(".").map { it.toInt() }

android {
    namespace = "com.jackson.lumio"
    compileSdk = 36

    defaultConfig {
        // Permanent once released: Android only updates an app with the same ID and signing key.
        applicationId = "com.jackson.lumio"
        minSdk = 28
        targetSdk = 36
        versionName = marketingVersion
        versionCode = versionParts[0] * 1_000_000 + versionParts[1] * 1_000 + versionParts[2]
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Phase 0 only: signed with the debug key so the test build installs. The real release
            // key comes in phase 6 (plan, "The APK signing key").
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        getByName("main") {
            // liblumiocore.so and libc++_shared.so from AndroidTV/Tools/build_core.sh.
            jniLibs.directories.add(rootDir.resolve("build/jniLibs").path)
        }
    }

    packaging {
        jniLibs {
            // Both CPU types ship in one APK (32-bit ARM for sticks like the onn HD, 64-bit ARM for
            // newer boxes), so the libraries are stored compressed: about 31 MB to download in
            // place of 77 MB. Android unpacks only the one the device uses.
            useLegacyPackaging = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.ui)
}

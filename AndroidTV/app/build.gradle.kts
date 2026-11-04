import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
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
    compileSdk = 37

    defaultConfig {
        // Permanent once released: Android only updates an app with the same ID and signing key.
        applicationId = "com.jackson.lumio"
        minSdk = 28
        targetSdk = 36
        versionName = marketingVersion
        versionCode = versionParts[0] * 1_000_000 + versionParts[1] * 1_000 + versionParts[2]
        ndk {
            // The CPU types the app ships for. CI's emulator is x86_64, so its test build passes
            // -PlumioAbis=x86_64 (with the core built for x86_64 by build_core.sh).
            val abis = (project.findProperty("lumioAbis") as String?)?.split(",") ?: listOf("armeabi-v7a", "arm64-v8a")
            abiFilters += abis
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Until phase 6: signed with the debug key so test builds install. The real release key
            // comes in phase 6 (plan, "The APK signing key").
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        getByName("main") {
            // liblumiocore.so and libc++_shared.so from AndroidTV/Tools/build_core.sh.
            jniLibs.directories.add(rootDir.resolve("build/jniLibs").path)
        }
        getByName("androidTest") {
            // The bridge's JSON fixtures, shared with the Swift tests so both sides agree on every field.
            assets.directories.add(rootDir.resolve("../Shared/LumioCore/Tests/IPTVBridgeTests/Fixtures").path)
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

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui)
    implementation(libs.tv.material)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
}

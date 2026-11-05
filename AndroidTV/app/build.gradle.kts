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
// -PlumioVersion=0.1.8 builds as another version (to test updating from one build to the next).
val marketingVersion: String = (project.findProperty("lumioVersion") as String?) ?: sharedVersion.getProperty("MARKETING_VERSION")

// AndroidTV/THIRD-PARTY-NOTICES.md ships inside the app (Settings → About shows it).
val noticesDir = layout.buildDirectory.dir("generated/notices")
val copyNotices by tasks.registering(Copy::class) {
    from(rootDir.resolve("THIRD-PARTY-NOTICES.md"))
    into(noticesDir)
}
tasks.named("preBuild") { dependsOn(copyNotices) }
val versionParts = marketingVersion.split(".").map { it.toInt() }

// Where releases are published and the key their signatures are checked with: the same settings
// as the Mac app's (UPDATE_REPOSITORY and UPDATE_PUBLIC_KEY in Mac/project.yml), read from there so
// the two can't differ.
fun macSetting(name: String): String {
    val line = rootDir.resolve("../Mac/project.yml").readLines().firstOrNull { it.trim().startsWith("$name:") } ?: return ""
    return line.substringAfter(":").trim().trim('"')
}

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
        buildConfigField("String", "UPDATE_REPOSITORY", "\"${macSetting("UPDATE_REPOSITORY")}\"")
        buildConfigField("String", "UPDATE_PUBLIC_KEY", "\"${macSetting("UPDATE_PUBLIC_KEY")}\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Built unsigned: AndroidTV/Tools/make_release.sh signs it with the release key from the
            // Keychain. Every update must carry the same key, or Android refuses to install it.
            signingConfig = null
        }
    }

    sourceSets {
        getByName("main") {
            // liblumiocore.so and libc++_shared.so from AndroidTV/Tools/build_core.sh.
            jniLibs.directories.add(rootDir.resolve("build/jniLibs").path)
            assets.directories.add(noticesDir.get().asFile.path)
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

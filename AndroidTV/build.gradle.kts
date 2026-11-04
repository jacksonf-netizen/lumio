buildscript {
    dependencies {
        // AGP 9 compiles Kotlin itself; this picks the Kotlin version it uses (libs.versions.toml).
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:${libs.versions.kotlin.get()}")
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

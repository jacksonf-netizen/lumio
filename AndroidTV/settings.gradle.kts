// Lumio for Android TV. The app's screens and player live in :app; the shared core is built by
// AndroidTV/Tools/build_core.sh into build/jniLibs and packed in from there.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "LumioAndroidTV"
include(":app")

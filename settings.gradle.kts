// -Ptrailmind.coreOnly=true builds/tests only the pure-Kotlin :core module, for machines or CI
// sandboxes without access to Google Maven (where the Android Gradle Plugin and SDK libs live).
val coreOnly = providers.gradleProperty("trailmind.coreOnly").orNull == "true"

pluginManagement {
    val coreOnlyBuild = providers.gradleProperty("trailmind.coreOnly").orNull == "true"
    repositories {
        if (!coreOnlyBuild) google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        // Android Gradle Plugin (Google Maven). If Android Studio reports this exact version as
        // unavailable, bump it to the latest stable AGP 9.x.
        id("com.android.application") version "9.0.0"
    }
}

dependencyResolutionManagement {
    repositories {
        if (!coreOnly) google()
        mavenCentral()
    }
}

rootProject.name = "TrailMind"

// Pure-Kotlin domain logic (GPX, geodesy, estimates, guidance). Builds and tests on any JVM.
include(":core")

if (!coreOnly) {
    include(":app")
}

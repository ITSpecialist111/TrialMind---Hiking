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
    // Wear OS companion (Galaxy Watch4 and later); talks to :app over Bluetooth, no Google Play services.
    include(":wear")
}

// AGP must share the root classloader with KGP, or KGP's Android support can't see AGP's classes.
// Skipped for -Ptrailmind.coreOnly=true builds, which have no access to Google Maven.
buildscript {
    if (providers.gradleProperty("trailmind.coreOnly").orNull != "true") {
        repositories {
            google()
            mavenCentral()
        }
        dependencies {
            // If this exact version is unavailable, bump it to the latest stable AGP 9.x.
            classpath("com.android.tools.build:gradle:9.0.0")
        }
    }
}

plugins {
    alias(libs.plugins.kotlin.jvm) apply false
}

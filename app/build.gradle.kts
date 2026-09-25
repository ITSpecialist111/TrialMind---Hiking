plugins {
    id("com.android.application")
}

android {
    namespace = "com.trailmind.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.trailmind.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        // Personal app: UI strings live in Kotlin for now.
        disable += setOf("SetTextI18n", "HardcodedText")
    }

    testOptions {
        unitTests.all { it.useJUnitPlatform() }
    }
}

// Deliberately no AndroidX/Play Services: the app uses only the Android framework plus :core,
// so it has no Google Play dependency and keeps a tiny, auditable dependency surface.
dependencies {
    implementation(project(":core"))
    // AGP's built-in Kotlin doesn't pick the kotlin-test JUnit variant automatically, so name it.
    testImplementation(libs.kotlin.test.junit5)
    testImplementation(libs.junit.jupiter.engine)
    testRuntimeOnly(libs.junit.platform.launcher)
}

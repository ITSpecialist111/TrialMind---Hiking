plugins {
    id("com.android.application")
}

android {
    namespace = "com.trailmind.wear"
    compileSdk = 36

    defaultConfig {
        // Wear OS companions share the phone app's id.
        applicationId = "com.trailmind.app"
        // Wear OS 3, the Galaxy Watch4's launch software.
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        disable += setOf("SetTextI18n", "HardcodedText")
    }
}

// No Google Play services. AndroidX only for the Wear ongoing-activity indicator.
dependencies {
    implementation(project(":core"))
    implementation(libs.androidx.core)
    implementation(libs.wear.ongoing)
}

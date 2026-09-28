plugins {
    id("com.android.application")
}

// The same Google Play upload key as the phone app (see app/build.gradle.kts): both upload to one listing.
val uploadStoreFile = providers.gradleProperty("trailmind.upload.storeFile").orNull
fun uploadProperty(name: String): String = providers.gradleProperty("trailmind.upload.$name").orNull
    ?: throw GradleException("trailmind.upload.storeFile is set, so trailmind.upload.$name is needed too.")

android {
    namespace = "com.trailmind.wear"
    compileSdk = 36

    defaultConfig {
        // Wear OS companions share the phone app's id.
        applicationId = "com.trailmind.app"
        // Wear OS 3, the Galaxy Watch4's launch software.
        minSdk = 30
        targetSdk = 36
        // Every upload to the Play listing needs its own version code, so the watch app has its own series.
        versionCode = 1_000_000 + providers.gradleProperty("trailmind.versionCode").get().toInt()
        versionName = providers.gradleProperty("trailmind.versionName").get()
    }

    signingConfigs {
        if (uploadStoreFile != null) create("upload") {
            storeFile = rootProject.file(uploadStoreFile)
            storePassword = uploadProperty("storePassword")
            keyAlias = uploadProperty("keyAlias")
            keyPassword = uploadProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            // Without an upload key, release builds use the debug key so they can be installed and tested.
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
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

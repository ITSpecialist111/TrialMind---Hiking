plugins {
    id("com.android.application")
}

// Google Play upload key (Play App Signing re-signs the app for users). Set trailmind.upload.storeFile,
// storePassword, keyAlias and keyPassword in ~/.gradle/gradle.properties or with -P. Never commit them.
val uploadStoreFile = providers.gradleProperty("trailmind.upload.storeFile").orNull
fun uploadProperty(name: String): String = providers.gradleProperty("trailmind.upload.$name").orNull
    ?: throw GradleException("trailmind.upload.storeFile is set, so trailmind.upload.$name is needed too.")

android {
    namespace = "com.trailmind.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.trailmind.app"
        minSdk = 26
        targetSdk = 36
        versionCode = providers.gradleProperty("trailmind.versionCode").get().toInt()
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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Without an upload key, release builds use the debug key so they can be installed and tested.
            // Google Play refuses debug-signed uploads.
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
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

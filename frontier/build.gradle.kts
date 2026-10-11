plugins {
    id("com.android.application")
}

// TrailMind Frontier: the same app, built from the :app sources and resources, installed under its own package
// (com.trailmind.frontier) so it can sit beside TrailMind on one phone. Everything that makes it different
// is switched on by the edition flag in the overlay manifest; see frontier/src/overlay and TrailMindApp.frontierEdition.
val uploadStoreFile = providers.gradleProperty("trailmind.upload.storeFile").orNull
fun uploadProperty(name: String): String = providers.gradleProperty("trailmind.upload.$name").orNull
    ?: throw GradleException("trailmind.upload.storeFile is set, so trailmind.upload.$name is needed too.")

android {
    // Same namespace as :app so the shared sources' package names and R class resolve unchanged.
    namespace = "com.trailmind.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.trailmind.frontier"
        minSdk = 26
        targetSdk = 36
        versionCode = providers.gradleProperty("trailmind.versionCode").get().toInt()
        versionName = providers.gradleProperty("trailmind.versionName").get() + "-frontier"
    }

    signingConfigs {
        if (uploadStoreFile != null) create("upload") {
            storeFile = rootProject.file(uploadStoreFile)
            storePassword = uploadProperty("storePassword")
            keyAlias = uploadProperty("keyAlias")
            keyPassword = uploadProperty("keyPassword")
        }
    }

    sourceSets {
        getByName("main") {
            manifest.srcFile("../app/src/main/AndroidManifest.xml")
            kotlin.directories.add("../app/src/main/kotlin")
            res.directories.add("../app/src/main/res")
        }
        // Frontier-only manifest additions and resources layer over the shared ones in every build type.
        listOf("debug", "release").forEach { type ->
            getByName(type) {
                manifest.srcFile("src/overlay/AndroidManifest.xml")
                res.directories.add("src/overlay/res")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "../app/proguard-rules.pro")
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

dependencies {
    implementation(project(":core"))
}


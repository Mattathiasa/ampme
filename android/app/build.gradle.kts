plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release keystore credentials come from environment variables so the keystore
// itself never lives in the repo. To sign a release build, export these before
// building (see README):
//
//   export KEYSTORE_PATH=/path/to/upload-keystore.jks
//   export KEYSTORE_PASSWORD=...
//   export KEY_ALIAS=...
//   export KEY_PASSWORD=...
//
// When they're absent, release builds fall back to the debug keystore so
// `flutter run --release` still works locally — but Play Store uploads will be
// rejected until the real keystore is configured.
// (Named release*: inside the signing config below, a bare `keyAlias` would
// resolve to the SigningConfig's own property, not this value.)
val releaseStorePath = System.getenv("KEYSTORE_PATH")
val releaseStorePassword = System.getenv("KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("KEY_ALIAS")
val releaseKeyPassword = System.getenv("KEY_PASSWORD")
val hasReleaseKeystore = !releaseStorePath.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.ampme.ampme"
    // All native plugins target compileSdk 35; pin at least that regardless of
    // the Flutter default so audio_session/just_audio resolve cleanly.
    compileSdk = maxOf(35, flutter.compileSdkVersion)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Public application ID (can differ from the Kotlin namespace).
        applicationId = "com.ampme.app"
        // minSdk is 23 — record 7.x (mic capture) requires 23; just_audio and
        // permission_handler only need 21. targetSdk 35 per the latest stable
        // Play requirements at time of writing.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // R8 minification + resource shrinking keep the APK lean. The
            // keep rules live in android/app/proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

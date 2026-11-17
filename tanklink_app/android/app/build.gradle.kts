import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release builds are signed with the upload key in android/key.properties
// (gitignored; see key.properties.example). Android only installs an update
// signed with the same key as the installed app, so keep that keystore and
// its passwords backed up. On a machine without the key, a test build can
// use the debug key: flutter build apk --android-project-arg=allowDebugSigning=true
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val allowDebugSigning = (project.findProperty("allowDebugSigning") as String?) == "true"

android {
    namespace = "com.tanklink.tanklink"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Never change: Android treats a new ID as a different app.
        applicationId = "com.tanklink.tanklink"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // From `version: X.Y.Z+N` in pubspec.yaml. N must grow every release.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                keystorePropertiesFile.exists() -> signingConfigs.getByName("release")
                allowDebugSigning -> signingConfigs.getByName("debug")
                else -> throw GradleException(
                    "Missing android/key.properties. Create the upload key " +
                        "(see android/key.properties.example), or pass " +
                        "-PallowDebugSigning=true for a test build."
                )
            }
            isMinifyEnabled = true
            isShrinkResources = true
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

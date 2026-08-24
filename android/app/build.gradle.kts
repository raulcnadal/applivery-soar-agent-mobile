plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.applivery.soar.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.applivery.soar.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // PKCS#10 CSR building for mTLS enrollment (MtlsIdentityPlugin.kt) — the
    // Android public SDK has no CSR builder at all (the java.security.cert
    // APIs cover parsing/validating certificates, not building a
    // CertificationRequest; `sun.security.*` internals aren't part of the
    // public SDK and may not exist on ART). Bouncy Castle's `bcpkix` is the
    // long-established, widely-audited standard for this specific gap on
    // Android — a case where depending on a well-tested library is the
    // responsible choice over hand-rolling ASN.1/DER encoding, unlike the
    // platform-channel code elsewhere in this repo which deliberately has no
    // dependencies.
    implementation("org.bouncycastle:bcpkix-jdk18on:1.78.1")
}

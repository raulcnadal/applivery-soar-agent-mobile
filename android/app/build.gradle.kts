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

    packaging {
        resources {
            // bcpkix-jdk18on, bcutil-jdk18on, bcprov-jdk18on, and jspecify all
            // ship an identical META-INF/versions/9/OSGI-INF/MANIFEST.MF (an
            // OSGi bundle manifest, irrelevant on Android), so the multi-release
            // jar merge step fails with a duplicate-path conflict unless it's
            // told which copy to keep. The content is unused at runtime either
            // way, so "first one wins" is safe here.
            pickFirsts += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
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

    // MtlsIdentityPlugin's mtlsRequest method channel handler runs the
    // actual HTTPS call on Dispatchers.IO so it never blocks Flutter's
    // platform-channel thread — not assumed to be transitively available
    // from the Flutter embedding (it isn't; the engine itself has no
    // coroutines dependency), so declared explicitly here.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // DeviceSecurityTelemetryPlugin's securityProviderUpToDate check
    // (com.google.android.gms.security.ProviderInstaller) — part of Google
    // Play services' "base" component. No google-services.json/Firebase
    // config needed; ProviderInstaller doesn't read any app-specific
    // configuration, unlike Play Integrity (Phase 3), which will need its
    // own separate dependency + Cloud Project linkage.
    implementation("com.google.android.gms:play-services-base:18.10.0")

    // Google Play Integrity API (Classic API request) — PlayIntegrityPlugin.kt,
    // mobile telemetry roadmap Phase 3. No google-services.json/Firebase
    // needed: the Cloud Project Number is supplied per-request
    // (IntegrityTokenRequest.setCloudProjectNumber), sourced from the
    // backend's admin-configured Settings > Google Play Integrity API
    // (playIntegrity.service.ts), not a build-time config file.
    implementation("com.google.android.play:integrity:1.6.0")
}

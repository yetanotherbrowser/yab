import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.testing.Test

plugins {
    id("com.android.application")
    kotlin("plugin.serialization")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "dev.yab.android"
    compileSdk = 37
    defaultConfig {
        applicationId = "dev.yab.android"
        minSdk = 29
        targetSdk = 37
        versionCode = (System.getenv("YAB_ANDROID_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("YAB_ANDROID_VERSION_NAME") ?: "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // The pinned LiteRT-LM runtime ships ARM64 and x86_64 JNI libraries.
        // Keep the default package installable only on architectures with that runtime.
        val requestedAbis = providers.gradleProperty("yabAbis").orElse("arm64-v8a,x86_64").get()
        val abis = requestedAbis.split(',').map(String::trim).filter(String::isNotEmpty)
        require(abis.isNotEmpty() && abis.all { it in setOf("arm64-v8a", "x86_64") }) { "Unsupported yabAbis" }
        ndk { abiFilters += abis }
        resValue("string", "app_name", System.getenv("YAB_TASK_NAME") ?: "Yab Android")
        resValue("string", "firebase_app_id", System.getenv("YAB_FIREBASE_APP_ID") ?: "")
        resValue("string", "firebase_api_key", System.getenv("YAB_FIREBASE_API_KEY") ?: "")
        resValue("string", "firebase_project_id", System.getenv("YAB_FIREBASE_PROJECT_ID") ?: "")
        resValue("string", "firebase_sender_id", System.getenv("YAB_FIREBASE_SENDER_ID") ?: "")
        manifestPlaceholders["yabReportsSite"] = System.getenv("YAB_REPORTS_SITE") ?: ""
    }
    buildFeatures { compose = true; buildConfig = true; resValues = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // Release signing comes only from the build environment; nothing secret lives in the tree.
    // YAB_ANDROID_KEYSTORE names the owner's release keystore (see RELEASE.md, "Release key").
    // Without it, -PyabTestSign=true signs the release build with this host's debug key so it can
    // be installed and smoke-tested; such an APK is not for distribution.
    val releaseKeystore = System.getenv("YAB_ANDROID_KEYSTORE")?.takeIf { it.isNotBlank() }
    val testSign = providers.gradleProperty("yabTestSign").orElse("false").get() == "true"
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("YAB_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("YAB_ANDROID_KEY_ALIAS") ?: "yab-release"
                keyPassword = System.getenv("YAB_ANDROID_KEY_PASSWORD") ?: System.getenv("YAB_ANDROID_KEYSTORE_PASSWORD")
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            enableUnitTestCoverage = true
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            resValue("string", "app_name", System.getenv("YAB_RELEASE_APP_NAME") ?: "Yab")
            signingConfig = when {
                releaseKeystore != null -> signingConfigs.getByName("release")
                testSign -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        // A downloaded APK is smaller with compressed native code (Android extracts it at install;
        // the libraries stay 16 KiB aligned inside). Play builds keep the default stored libraries.
        jniLibs.useLegacyPackaging = providers.gradleProperty("yabCompressNative").orElse("false").get() == "true"
    }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
dependencies {
    implementation(project(":core"))
    // UI 1.12.1 preserves hosted GeckoView's real framework Autofill structure.
    // androidx/androidx 65979faed8fd6d32d5ca9b9a123e33ed0834fbc2; Material3 stays 1.4.0.
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.mozilla.geckoview:geckoview:158.0.20261021001945")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.18.1")
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    implementation("com.google.firebase:firebase-messaging:26.0.1")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// The cross-platform test reads this external file at runtime. Its contents,
// rather than a previous job's environment or XML, must invalidate Test outputs.
tasks.withType<Test>().configureEach {
    val oracle = providers.environmentVariable("YAB_SHIELD_ORACLE")
    inputs.property("shieldOracleConfigured", oracle.isPresent)
    if (oracle.isPresent) inputs.file(oracle.get()).withPathSensitivity(PathSensitivity.NONE)
}


// Some checkouts do not carry the private chat-work fixture file
// (Android/parity/chat-work/fixtures.json), so its suite cannot run there.
// yabExcludeSuites lists suites to skip on such a checkout; an owner
// machine with the fixtures keeps running everything.
val excludedSuites = providers.gradleProperty("yabExcludeSuites").orElse("").get()
    .split(',').map(String::trim).filter(String::isNotEmpty)
if (excludedSuites.isNotEmpty()) {
    tasks.withType<Test>().configureEach {
        filter {
            excludedSuites.forEach { excludeTestsMatching("$it.*") }
        }
    }
}

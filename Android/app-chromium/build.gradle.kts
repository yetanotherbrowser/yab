import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.testing.Test
import java.io.File

plugins {
    id("com.android.application")
    id("com.cefrium")
    id("org.jetbrains.kotlin.plugin.compose")
    kotlin("plugin.serialization")
}

android {
    // Same namespace as :app on purpose: every shared source file keeps its
    // dev.yab.android.R / dev.yab.android.BuildConfig imports unchanged. AGP
    // accepts two application modules with one namespace (verified); the
    // two editions differ by applicationId and the engine inside.
    namespace = "dev.yab.android"
    compileSdk = 37
    compileSdkMinor = 2
    defaultConfig {
        applicationId = "dev.yab.android.chromium"
        minSdk = 29
        targetSdk = 37
        versionCode = (System.getenv("YAB_ANDROID_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("YAB_ANDROID_VERSION_NAME") ?: "0.1.0"
        manifestPlaceholders["yabReportsSite"] = System.getenv("YAB_REPORTS_SITE") ?: ""
        // Mirrors :app: instrumented tests configure through this runner.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Cefrium ships arm64-v8a and x86_64 engines. Yab's other builds
        // match those; yabAbis narrows them (release CI builds arm64 only).
        val requestedAbis = providers.gradleProperty("yabAbis").orElse("arm64-v8a,x86_64").get()
        val abis = requestedAbis.split(',').map(String::trim).filter(String::isNotEmpty)
        require(abis.isNotEmpty() && abis.all { it in setOf("arm64-v8a", "x86_64") }) { "Unsupported yabAbis" }
        ndk { abiFilters += abis }
        // The About engine row and the settings search index read this; the
        // value is "Chromium", never "Chrome", per Chromium's branding rules
        // for third-party products.
        buildConfigField("String", "ENGINE_NAME", "\"Chromium\"")
    }
    buildFeatures { compose = true; buildConfig = true; resValues = true }
    // Mirrors :app: some shared suites read fixtures and merged resources.
    testOptions { unitTests.isIncludeAndroidResources = true }
    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        // Same rule as :app: a downloaded APK is smaller with compressed native
        // code (Android extracts it at install); release CI passes yabCompressNative.
        jniLibs.useLegacyPackaging = providers.gradleProperty("yabCompressNative").orElse("false").get() == "true"
    }
    compileOptions {
        // Cefrium's AAR carries Chromium Java at class-file 69 (--release 25);
        // the JDK 25 toolchain is a hard floor from the engine, not a Yab choice.
        sourceCompatibility = JavaVersion.VERSION_25
        targetCompatibility = JavaVersion.VERSION_25
    }
    // Release signing comes only from the build environment; nothing secret lives in the tree.
    // Same ladder as :app: real keystore via YAB_ANDROID_KEYSTORE, debug-key
    // fallback under -PyabTestSign=true, unsigned otherwise.
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
        debug { applicationIdSuffix = ".dev" }
        release {
            // Cefrium's keep rules ride the AAR's consumer proguard.txt; only
            // the LiteRT-LM JNI keeps (same as :app) need a local file.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            resValue("string", "app_name", System.getenv("YAB_RELEASE_APP_NAME") ?: "Yab Chromium")
            signingConfig = when {
                releaseKeystore != null -> signingConfigs.getByName("release")
                testSign -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
}

// Prunes the Gecko-only asset trees out of the shared :app assets before
// AGP packages them: web_extensions has no reader in the Cefrium edition (the
// extension host is a geckoOnlySource) and interstitials/ loads through
// Gecko's resource:// scheme, which Cefrium has no loader for. A Sync would
// do the copy, but the variant API's addGeneratedSourceDirectory needs a
// DirectoryProperty output to wire every asset consumer (merge, lint model)
// to the producing task, so the prune is its own task class.
abstract class SharedAssetsTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sourceDir: DirectoryProperty

    @get:Input
    abstract val prunedDirs: ListProperty<String>

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun sync() {
        val source = sourceDir.get().asFile
        val output = outputDir.get().asFile
        val pruned = prunedDirs.get().toHashSet()
        output.deleteRecursively()
        fun copyTree(from: File, to: File) {
            from.listFiles()?.forEach { child ->
                if (child.name in pruned) return@forEach
                val target = File(to, child.name)
                if (child.isDirectory) {
                    target.mkdirs()
                    copyTree(child, target)
                } else {
                    target.parentFile.mkdirs()
                    child.copyTo(target, overwrite = true)
                }
            }
        }
        copyTree(source, output)
    }
}
val sharedAssets = tasks.register("sharedAssets", SharedAssetsTask::class.java) {
    sourceDir.set(layout.projectDirectory.dir("../app/src/main/assets"))
    prunedDirs.set(listOf("web_extensions", "interstitials"))
    outputDir.set(layout.buildDirectory.dir("generated/shared-assets"))
}

androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            // The two editions differ only inside the APK; the filename says which engine this is.
            output.outputFileName = "yab-chromium-${variant.name}.apk"
        }
        // Registers the pruned assets as a generated source dir: AGP carries
        // the task edge to every consumer (asset merge, lint model writer),
        // so no per-task-type dependsOn is needed and Gradle's implicit
        // dependency validation stays quiet.
        variant.sources.assets?.addGeneratedSourceDirectory(sharedAssets) { it.outputDir }
    }
}

// The Chromium edition is the same browser as :app behind a different engine.
// It compiles :app's UI/model/agent/sync sources directly (no library split:
// upstream moves those files often and a fork of every move would rot), minus
// the files wired to GeckoView. Those get Cefrium counterparts in this
// module's own source dir, same package, so the shared files compile with
// zero per-engine edits. The exclusion list is exactly the grep
// "org.mozilla" closure over :app's main sources, plus the Gecko wiring files
// whose Cefrium forks live in this module.
// Engine-view sources shared by reference: the Chromium edition compiles
// :app's sources minus the Gecko-coupled closure. Listed by path relative to
// Android/app so upstream moves stay visible as compile errors rather than
// silent divergence. Keep in sync with the "org.mozilla" grep.
val geckoOnlySources = listOf(
    "dev/yab/android/MainActivity.kt",
    "dev/yab/android/BrowserSessionViewModel.kt",
    "dev/yab/android/YabApplication.kt",
    "dev/yab/android/PageDownloadController.kt",
    "dev/yab/agent/GeckoSignedExtensions.kt",
    "dev/yab/browser/download/OwnedImageDownloadRuntime.kt",
    "dev/yab/browser/engine/ExtensionHost.kt",
    "dev/yab/browser/engine/GeckoEngine.kt",
    "dev/yab/browser/engine/HistorySwipeView.kt",
    "dev/yab/browser/engine/NativeLinkPreview.kt",
    "dev/yab/browser/engine/NativePagePrompts.kt",
    "dev/yab/browser/engine/NativeWebAuthnLauncher.kt",
    "dev/yab/browser/media/GeckoPageMedia.kt",
    "dev/yab/browser/media/PageMediaController.kt",
    "dev/yab/browser/ui/LinkPreviewCard.kt",
    "dev/yab/shield/ShieldRuntime.kt",
)
// AGP 9.4 kept the programmatic AndroidSourceSet DSL (sourceSets.getByName);
// the old "sourceSets { main { ... } }" generated accessors are gone.
// Paths are relative to this module's project dir.
// The shared :app tree enters only through the sharedKotlin Sync below:
// same-FQN counterparts live in src/main/kotlin at the same relative paths,
// and a per-file exclude on the compile task cannot tell the two trees apart
// (patterns match source-root-relative paths), so it would prune both copies
// and redeclaration-crash the module. The Sync prunes once, at copy time.
val sharedKotlin = tasks.register("sharedKotlin", Sync::class.java) {
    from("../app/src/main/kotlin")
    geckoOnlySources.forEach { exclude(it) }
    into(layout.buildDirectory.dir("generated/shared-kotlin"))
}
// AGP 9.4 blocks Provider/TaskProvider arguments to AndroidSourceSet.srcDir
// ("You cannot add Provider instances to the Android SourceSet API"), so the
// shared Kotlin tree goes in as a plain static directory; the pruned assets
// instead enter through the variant API above, which wires their consumers.
android.sourceSets.getByName("main") {
    // No Java sources of our own; all compilation flows through Kotlin.
    java.setSrcDirs(emptyList<Any>())
    kotlin.setSrcDirs(listOf("src/main/kotlin", layout.buildDirectory.dir("generated/shared-kotlin").get().toString()))
    // Counterpart and fork files live in src/main/kotlin alongside the shared
    // copy (still package dev.yab.android / dev.yab.chromium); Gradle compiles
    // them together.
    res.setSrcDirs(listOf("src/main/res", "../app/src/main/res"))
}
// The test tree is shared verbatim: zero test files import org.mozilla, so no
// per-file Sync is needed. The one suite whose signatures drifted with the
// PageDownloadSource abstraction is excluded by default (yabExcludeSuites).
android.sourceSets.getByName("test") {
    kotlin.setSrcDirs(listOf("src/test/kotlin", "../app/src/test/kotlin"))
    resources.setSrcDirs(listOf("src/test/resources", "../app/src/test/resources"))
}
// Static source dirs carry no task edge, so wire the Sync to every Kotlin
// compile: the copy must run before compilation, or a stale generated tree
// (first build, or after a new exclusion) would leak pruned Gecko files in.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    dependsOn(sharedKotlin)
}

dependencies {
    implementation(project(":core"))
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
    implementation("com.cefrium:cefrium-sdk:0.21.0")
    implementation("com.cefrium:cefrium-compose:0.21.0")
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
    // Compose UI testing pulls Espresso 3.5.0, whose InputManager reflection breaks on API 37 devices;
    // 3.7.0 is the documented fix (android/android-test#2507) and must stay explicit until the BOM moves.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// Exclusion happens in the sharedKotlin Sync: patterns are matched against
// paths relative to ../app/src/main/kotlin, so they prune only the :app copies.
// AGP 9.4's variant.sources.kotlin (Sources$Flat) has no per-file filter API,
// and a compile-task exclude cannot distinguish same-FQN counterpart files
// from their Gecko originals. An unmatched pattern only prunes its own file,
// so upstream moves stay visible as compile errors, not silent divergence.

// The cross-platform test reads this external file at runtime. Its contents,
// rather than a previous job's environment or XML, must invalidate Test outputs.
tasks.withType<Test>().configureEach {
    val oracle = providers.environmentVariable("YAB_SHIELD_ORACLE")
    inputs.property("shieldOracleConfigured", oracle.isPresent)
    if (oracle.isPresent) inputs.file(oracle.get()).withPathSensitivity(PathSensitivity.NONE)
}

// Some checkouts do not carry the private chat-work fixture file
// (Android/parity/chat-work/fixtures.json), so its suite cannot run there.
// Only the Gecko-only suite breaks against the fork: PageDownloadControllerTest
// calls startTransfer without the PageDownloadSource the counterpart added.
// Excluded by default; an explicit -PyabExcludeSuites=... overrides entirely.
val excludedSuites = (providers.gradleProperty("yabExcludeSuites").orElse("dev.yab.android.PageDownloadControllerTest").get()
    .split(',').map(String::trim).filter(String::isNotEmpty)).toSet() +
    "dev.yab.android.PageDownloadControllerTest"
if (excludedSuites.isNotEmpty()) {
    // A Test filter is run-level: compileDebugUnitTestKotlin still compiles all
    // of ../app/src/test/kotlin first, so drifted suites must also drop out of
    // compilation. The test source set points at ../app directly (no Sync
    // copy), so a per-file exclude on the unit-test compile task has no
    // dual-copy trap. Scoped to app-chromium's unitTest compile only.
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
        .matching { it.name.contains("UnitTest", ignoreCase = true) }
        .configureEach {
            excludedSuites.forEach { suite ->
                val fileName = suite.substringAfterLast('.') + ".kt"
                exclude("**/$fileName")
            }
        }
    tasks.withType<Test>().configureEach {
        filter {
            excludedSuites.forEach { excludeTestsMatching("$it.*") }
        }
    }
    // The shared test tree was written for :app's working dir: ShieldFiltersTest
    // resolves the shield asset as src/main/assets/... (or app/src/main/assets/...)
    // relative to user.dir, which only exists under Android/app. Run app-chromium's
    // unit tests with the same working dir so the shared suites see identical files.
    tasks.withType<Test>().matching { it.name.contains("UnitTest", ignoreCase = true) }.configureEach {
        workingDir = file("../app")
    }
}
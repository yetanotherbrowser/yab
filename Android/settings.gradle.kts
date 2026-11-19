pluginManagement {
    repositories {
        maven("https://maven.cefrium.com") {
            content { includeGroup("com.cefrium") }
        }
        google(); mavenCentral(); gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // Central first: most of the Cefrium graph's transitive edges are
        // Central-only (lottie, guava, okio, coroutines). Google mirrors some
        // but 404s others; keeping Central ahead cuts cross-repo misses on
        // the dense first-resolution burst after a cold CI cache.
        mavenCentral()
        google()
        maven("https://maven.mozilla.org/maven2/")
        maven("https://maven.cefrium.com") {
            content { includeGroup("com.cefrium") }
        }
    }
}
rootProject.name = "YabAndroid"
include(":app", ":core", ":app-chromium")


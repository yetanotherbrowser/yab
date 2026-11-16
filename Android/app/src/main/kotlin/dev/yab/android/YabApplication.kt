package dev.yab.android

import android.app.Application
import android.os.Looper
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import dev.yab.chromium.ChromeBootstrapPort
import dev.yab.chromium.ChromeEngineHost
import dev.yab.sync.AndroidSyncBridge
import dev.yab.notifications.AndroidNotificationSyncPort
import dev.yab.notifications.PushNotifications

class YabApplication : Application() {
    /** One device-local ReaderStyle publisher shared by every retained browser window. */
    val readerPreferences: dev.yab.browser.engine.ReaderPreferencesStore by lazy {
        dev.yab.browser.engine.ReaderPreferencesStore(java.io.File(filesDir, "reader-preferences.json"))
    }
    val runtime: GeckoRuntime by lazy(LazyThreadSafetyMode.NONE) {
        check(Application.getProcessName() == packageName) { "The browser runtime belongs to the main app process" }
        GeckoRuntime.create(this, GeckoRuntimeSettings.Builder()
            .consoleOutput(BuildConfig.DEBUG)
            .remoteDebuggingEnabled(BuildConfig.DEBUG)
            .forceUserScalableEnabled(true)
            .build()).also {
                if (BuildConfig.DEBUG) {
                    val previous = Thread.getDefaultUncaughtExceptionHandler()
                    Thread.setDefaultUncaughtExceptionHandler { thread, failure ->
                        // Exception messages can contain page data. Debug diagnostics
                        // retain only exception types and static source locations.
                        val frames = generateSequence(failure) { it.cause }.take(6).joinToString("\n") { cause ->
                            cause.javaClass.name + "\n" + cause.stackTrace.take(32).joinToString("\n")
                        }
                        android.util.Log.e("YabDebugCrash", frames)
                        if (previous != null) previous.uncaughtException(thread, failure)
                        else android.os.Process.killProcess(android.os.Process.myPid())
                    }
                }
            }
    }
    lateinit var sync: AndroidSyncBridge
        private set

    /**
     * The Chromium seam's first consumer, application-scoped. Null until the
     * fork APK is present; a build without it never opens the Chrome identity
     * registry nor installs a Chrome owner. Gecko keeps serving Android: this
     * host owns only the Chrome-side lifecycle and starts no engine by itself.
     *
     * The ownership supplier reads live bridge state, so the startup barrier
     * (AndroidChromeOwnerSource.prepare) must run before the first host call;
     * the engine-start flow that turns the presence check on owns that barrier.
     */
    val chromeHost: ChromeEngineHost? by lazy(LazyThreadSafetyMode.NONE) {
        check(Application.getProcessName() == packageName) { "The Chrome owner lifecycle belongs to the main app process" }
        if (!chromePortPresent()) null else ChromeEngineHost.create(
            dev.yab.chromium.AndroidChromeOwnerSource.registry(this),
            { dev.yab.chromium.AndroidChromeOwnerSource.ownershipOf(sync) },
            ::chromeBootstrapPort,
            { check(Looper.myLooper() == Looper.getMainLooper()) { "Chrome owner calls must stay on the main thread" } },
        )
    }

    /** Milestone 2 replaces this with the fork APK's bootstrap presence check. */
    private fun chromePortPresent(): Boolean = false

    private fun chromeBootstrapPort(): ChromeBootstrapPort =
        throw IllegalStateException("The Chromium fork APK's bootstrap is not linked into this build")

    override fun onCreate() {
        super.onCreate()
        // Gecko child services use this Application too; they own their native
        // process bootstrap and must never start another browser runtime or Sync.
        if (Application.getProcessName() != packageName) return
        sync = AndroidSyncBridge(this)
        PushNotifications.initialize(this, AndroidNotificationSyncPort(sync))
        EntrancesWidget.installShortcuts(this)
        dev.yab.update.AppUpdater.start(this)
    }
}

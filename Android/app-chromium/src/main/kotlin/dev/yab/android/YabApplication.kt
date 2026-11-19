package dev.yab.android

import android.app.Application
import com.cefrium.Cefrium
import dev.yab.sync.AndroidSyncBridge
import dev.yab.notifications.AndroidNotificationSyncPort
import dev.yab.notifications.PushNotifications

class YabApplication : Application() {
    /** One device-local ReaderStyle publisher shared by every retained browser window. */
    val readerPreferences: dev.yab.browser.engine.ReaderPreferencesStore by lazy {
        dev.yab.browser.engine.ReaderPreferencesStore(java.io.File(filesDir, "reader-preferences.json"))
    }
    lateinit var sync: AndroidSyncBridge
        private set

    override fun onCreate() {
        super.onCreate()
        // Cefrium's renderer processes use this Application too; they own their
        // native bootstrap and must never start the browser engine or Sync.
        if (Application.getProcessName() != packageName) return
        // Cefrium is a static-methods SDK, not a runtime object: setupProcess
        // patches the process for the renderer, initialize starts the engine.
        Cefrium.setupProcess(this)
        // Out-of-process GPU like stock Chrome: the engine boots --in-process-gpu
        // unless this flips before initialize() consumes the command line.
        Cefrium.setGpuProcessEnabled(true)
        if (!Cefrium.initialize(this)) {
            throw IllegalStateException("The Cefrium browser engine failed to start")
        }
        Cefrium.setRemoteDebuggingEnabled(BuildConfig.DEBUG)
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
        sync = AndroidSyncBridge(this)
        PushNotifications.initialize(this, AndroidNotificationSyncPort(sync))
        EntrancesWidget.installShortcuts(this)
        dev.yab.update.AppUpdater.start(this)
    }
}
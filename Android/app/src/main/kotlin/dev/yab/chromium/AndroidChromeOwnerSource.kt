package dev.yab.chromium

import android.content.Context
import dev.yab.sync.AndroidSyncBridge
import java.io.File

/** One atomic account/journal publication, confirmed against the bridge's immediate close lease. */
class AndroidChromeOwnerSource private constructor(private val sync: AndroidSyncBridge) {
    fun current(): ChromeSyncOwnership = ownership(sync)

    companion object {
        /** Null account/device snapshots map to the off state: only StandaloneLocal can be permitted, never Paired. */
        internal fun ownership(sync: AndroidSyncBridge): ChromeSyncOwnership {
            val image = sync.accountRecords.value
            return ChromeSyncOwnership(image.account, image.device, image.epoch, sync.nativeOwnerCurrent(image))
        }

        /** Required startup barrier, including the standalone case. It performs no network/login. */
        suspend fun prepare(sync: AndroidSyncBridge): AndroidChromeOwnerSource {
            sync.prepareNativeOwner()
            return AndroidChromeOwnerSource(sync)
        }
        /** No active engine switches here. A future Chrome engine owns both returned lifecycles. */
        fun registry(context: Context): ChromeIdentityRegistry = ChromeIdentityRegistry(FileChromeRegistryBytes(
            File(context.applicationContext.noBackupFilesDir, "ChromeNative/identities.json")))
    }
}

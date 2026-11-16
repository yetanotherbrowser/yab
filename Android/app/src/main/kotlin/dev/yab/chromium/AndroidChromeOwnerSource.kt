package dev.yab.chromium

import android.content.Context
import dev.yab.sync.AndroidSyncBridge
import java.io.File

/**
 * One atomic account/journal publication, confirmed against the bridge's immediate close lease.
 * The ownership read is a plain mapping over snapshot values (JVM-testable); only this
 * class's three constructors touch Android, so every seam consumer goes through them.
 */
class AndroidChromeOwnerSource private constructor(private val current: () -> ChromeSyncOwnership) {
    fun current(): ChromeSyncOwnership = current()

    companion object {
        /** Null account/device snapshots map to the off state: only StandaloneLocal can be permitted, never Paired. */
        internal fun ownership(image: AccountSnapshot, nativeCurrent: Boolean): ChromeSyncOwnership =
            ChromeSyncOwnership(image.account, image.device, image.epoch, nativeCurrent)

        /** The bridge-backed ownership read; the only AndroidSyncBridge binding outside [prepare]. */
        internal fun ownershipOf(sync: AndroidSyncBridge): ChromeSyncOwnership =
            sync.accountRecords.value.let { ownership(AccountSnapshot(it.account, it.device, it.epoch), sync.nativeOwnerCurrent(it)) }

        /** Required startup barrier, including the standalone case. It performs no network/login. */
        suspend fun prepare(sync: AndroidSyncBridge): AndroidChromeOwnerSource {
            sync.prepareNativeOwner()
            return AndroidChromeOwnerSource { ownershipOf(sync) }
        }

        /** No active engine switches here. A future Chrome engine owns both returned lifecycles. */
        fun registry(context: Context): ChromeIdentityRegistry = ChromeIdentityRegistry(FileChromeRegistryBytes(
            File(context.applicationContext.noBackupFilesDir, "ChromeNative/identities.json")))
    }
}

/** The bridge fields the ownership mapping reads; a value copy so the mapping runs off live state. */
data class AccountSnapshot(val account: String?, val device: String?, val epoch: Long)

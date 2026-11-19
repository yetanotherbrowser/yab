package dev.yab.browser.engine

import android.os.SystemClock
import dev.yab.browser.model.BrowserPageMemento
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import kotlinx.coroutines.CompletableDeferred

/**
 * Undo memory over Cefrium's opaque navigation state. Same bounded policy as the
 * Gecko edition: 7.5 s expiry, 8 MiB per state, 16 MiB and 32 entries total.
 * The bytes never serialize beyond this process; Cefrium restoreNavigationState
 * accepts them only in the same engine run.
 */
internal class CefriumClosedMemory(val engine: CefriumEngine, val tab: BrowserTab, val profile: WebsiteProfile,
    var state: ByteArray?, val expires: Long) : BrowserPageMemento {
    val drained = CompletableDeferred<Unit>()
    var released = false
    fun expired(now: Long = SystemClock.elapsedRealtime()) = now > expires
}

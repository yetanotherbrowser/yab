package org.chromium.chrome.browser.yab

import java.util.function.BooleanSupplier

/**
 * Test-only stand-in for the fork APK's real bootstrap class, under the exact
 * reviewed name so ChromeForkPresence's default Class.forName path resolves it
 * on the JVM. The real class is compiled by the fork build (engine-chromium/
 * adapter/YabChromeBootstrap.java); this fixture ships nowhere.
 */
internal object YabBootstrapInitMarker { var ran = false }

class YabChromeBootstrap private constructor() {
    companion object {
        init { YabBootstrapInitMarker.ran = true }

        @JvmStatic var savedCalls = 0
        @JvmStatic var freshCalls = 0
        @JvmStatic var revokeCalls = 0
        @JvmStatic var releaseCalls = 0
        @JvmStatic var acceptSaved = true
        @JvmStatic var lastAccount: String? = null
        @JvmStatic var lastEpoch: String? = null
        @JvmStatic var failure: RuntimeException? = null

        @JvmStatic fun activateSavedOwner(account: String, epoch: String, lease: BooleanSupplier): Boolean {
            savedCalls++; lastAccount = account; lastEpoch = epoch
            failure?.let { throw it }
            return acceptSaved && lease.asBoolean
        }

        @JvmStatic fun startNewOwner(account: String, epoch: String, lease: BooleanSupplier) {
            freshCalls++; lastAccount = account; lastEpoch = epoch
            failure?.let { throw it }
        }

        @JvmStatic fun revokeOwner() { revokeCalls++; failure?.let { throw it } }
        @JvmStatic fun releaseAfterTeardown() { releaseCalls++; failure?.let { throw it } }
    }
}
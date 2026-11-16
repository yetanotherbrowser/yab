package dev.yab.chromium

import org.junit.Assert.*
import org.junit.Test

class AndroidChromeOwnerSourceTest {
    @Test fun pairedSnapshotsMapToPairedOwnershipAndOffSnapshotsNeverDo() {
        val paired = AndroidChromeOwnerSource.ownership(AccountSnapshot("opaque/account-A", "device-A", 9), nativeCurrent = true)
        assertEquals(ChromeSyncOwnership("opaque/account-A", "device-A", 9, true), paired)
        assertTrue(paired.permits(ChromeOwnerSource.Paired("opaque/account-A")))
        // The off state: null account and device, only StandaloneLocal can be permitted.
        val off = AndroidChromeOwnerSource.ownership(AccountSnapshot(null, null, 3), nativeCurrent = true)
        assertEquals(ChromeSyncOwnership(null, null, 3, true), off)
        assertTrue(off.permits(ChromeOwnerSource.StandaloneLocal))
        assertFalse(off.permits(ChromeOwnerSource.Paired("opaque/account-A")))
        // A stale native gate flips availability without changing the recorded fields.
        val stale = AndroidChromeOwnerSource.ownership(AccountSnapshot("opaque/account-A", "device-A", 9), nativeCurrent = false)
        assertFalse(stale.permits(ChromeOwnerSource.Paired("opaque/account-A")))
        // The fields stay readable for callers that render or log the capture.
        assertEquals("opaque/account-A", stale.account); assertEquals("device-A", stale.device)
        assertEquals(9L, stale.epoch); assertFalse(stale.available)
    }
}
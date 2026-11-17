package dev.yab.chromium

import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.InvocationTargetException
import java.util.function.BooleanSupplier

/** Drifted stand-in: one reviewed static renamed, so port construction must fail loudly. */
internal object YabChromeBootstrapDrifted {
    @JvmStatic fun activateSaved(account: String, epoch: String, lease: BooleanSupplier): Boolean = true
    @JvmStatic fun startNewOwner(account: String, epoch: String, lease: BooleanSupplier) = Unit
    @JvmStatic fun revokeOwner() = Unit
    @JvmStatic fun releaseAfterTeardown() = Unit
}

class ChromeForkPresenceTest {
    private fun reset() {
        with(org.chromium.chrome.browser.yab.YabChromeBootstrap.Companion) {
            savedCalls = 0; freshCalls = 0; revokeCalls = 0; releaseCalls = 0
            acceptSaved = true; lastAccount = null; lastEpoch = null; failure = null
        }
    }

    private fun fixture() = org.chromium.chrome.browser.yab.YabChromeBootstrap.Companion

    @Test fun resolveLinksTheBootstrapClassWithoutInitializingIt() {
        reset()
        org.chromium.chrome.browser.yab.YabBootstrapInitMarker.ran = false
        val presence = ChromeForkPresence.resolve()
        assertNotNull(presence)
        assertEquals("org.chromium.chrome.browser.yab.YabChromeBootstrap", presence!!.bootstrapClass.name)
        // resolve links without initialize=true: the fixture's companion init has not run.
        assertFalse(org.chromium.chrome.browser.yab.YabBootstrapInitMarker.ran)
    }

    @Test fun resolveTreatsMissingClassAsAbsent() {
        assertNull(ChromeForkPresence.resolve { _ -> throw ClassNotFoundException("fork not on this build") })
    }

    @Test fun resolveTreatsLinkageFailureAsAbsent() {
        assertNull(ChromeForkPresence.resolve { _ -> throw NoClassDefFoundError("fork native library missing") })
    }

    @Test fun resolveLetsRealErrorsPropagate() {
        assertThrows(IllegalStateException::class.java) {
            ChromeForkPresence.resolve { _ -> throw IllegalStateException("verifier broke") }
        }
    }

    @Test fun resolveUsesTheReviewedClassName() {
        var seen: String? = null
        ChromeForkPresence.resolve { name -> seen = name; throw ClassNotFoundException("probe") }
        assertEquals(ChromeForkPresence.BOOTSTRAP_CLASS_NAME, seen)
    }

    @Test fun portBindsTheReviewedStaticsAndRoutesCalls() {
        reset()
        val port = YabChromeBootstrapPort(ChromeForkPresence.resolve()!!)
        assertTrue(port.activateSavedOwner("account-A", "epoch-1", BooleanSupplier { true }))
        with(fixture()) {
            assertEquals(1, savedCalls); assertEquals("account-A", lastAccount); assertEquals("epoch-1", lastEpoch)
        }
        port.startNewOwner("account-B", "epoch-2", BooleanSupplier { true })
        with(fixture()) { assertEquals(1, freshCalls); assertEquals("account-B", lastAccount) }
        port.revokeOwner()
        with(fixture()) { assertEquals(1, revokeCalls) }
        port.releaseAfterTeardown()
        with(fixture()) { assertEquals(1, releaseCalls) }
    }

    @Test fun portAnswersFalseWhenTheForkRefusesTheSavedOwner() {
        reset()
        fixture().acceptSaved = false
        val port = YabChromeBootstrapPort(ChromeForkPresence.resolve()!!)
        assertFalse(port.activateSavedOwner("account-A", "epoch-1", BooleanSupplier { true }))
        assertEquals(0, fixture().revokeCalls)
    }

    @Test fun portPropagatesTheForksOwnExceptionNotReflectionPlumbing() {
        reset()
        val failure = RuntimeException("fork refused")
        fixture().failure = failure
        val port = YabChromeBootstrapPort(ChromeForkPresence.resolve()!!)
        val routed = assertThrows(RuntimeException::class.java) { port.activateSavedOwner("a", "e", BooleanSupplier { true }) }
        assertSame(failure, routed)
    }

    @Test fun unwrapKeepsReflectionPlumbingOnlyWhenTheCauseIsMissing() {
        val naked = InvocationTargetException(null)
        assertSame(naked, unwrap(naked))
    }

    @Test fun portRefusesADriftedForkLoudlyAtConstruction() {
        val drifted = assertThrows(NoSuchMethodException::class.java) {
            YabChromeBootstrapPort(ChromeForkPresence.resolve { YabChromeBootstrapDrifted::class.java }!!)
        }
        assertTrue(drifted.message!!.contains("activateSavedOwner"))
    }

    @Test fun producerAcceptsTheReflectionPortEndToEnd() {
        reset()
        val registry = ChromeIdentityRegistry(object : ChromeRegistryBytes {
            var value: ByteArray? = null
            override fun read() = value?.copyOf()
            override fun replace(expectedSHA256: String?, bytes: ByteArray) { value = bytes.copyOf() }
            override fun close() = Unit
        })
        val account = ChromeOwnerSource.Paired("opaque/account-A")
        fun ownership() = ChromeSyncOwnership(account.account, "device", 4, true)
        val host = ChromeEngineHost.create(registry, ::ownership, { YabChromeBootstrapPort(ChromeForkPresence.resolve()!!) }) { }
        val owner = host.prepareNew(account)
        assertTrue(host.activate(owner))
        assertEquals(1, fixture().freshCalls)
        host.revoke(owner)
        assertEquals(1, fixture().revokeCalls)
        host.releaseAfterTeardown(owner)
        assertEquals(1, fixture().releaseCalls)
        registry.close()
    }

    @Test fun producerSeesTheForksThrowThroughThePort() {
        reset()
        val registry = ChromeIdentityRegistry(object : ChromeRegistryBytes {
            var value: ByteArray? = null
            override fun read() = value?.copyOf()
            override fun replace(expectedSHA256: String?, bytes: ByteArray) { value = bytes.copyOf() }
            override fun close() = Unit
        })
        val account = ChromeOwnerSource.Paired("opaque/account-A")
        fun ownership() = ChromeSyncOwnership(account.account, "device", 4, true)
        fixture().failure = IllegalStateException("fork start refused")
        val host = ChromeEngineHost.create(registry, ::ownership, { YabChromeBootstrapPort(ChromeForkPresence.resolve()!!) }) { }
        val owner = host.prepareNew(account)
        assertThrows(IllegalStateException::class.java) { host.activate(owner) }
        // The producer's throw path already sent revokeOwner: teardown ownership preserved.
        assertEquals(1, fixture().revokeCalls)
        registry.close()
    }
}
package dev.yab.chromium

import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import org.junit.Assert.*
import org.junit.Test
import java.util.function.BooleanSupplier

class ChromeEngineHostTest {
    private class Port : ChromeBootstrapPort {
        var savedCalls = 0; var freshCalls = 0; var revoked = false; var released = false
        var acceptSaved = true
        override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean {
            savedCalls++; return acceptSaved
        }
        override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) { freshCalls++ }
        override fun revokeOwner() { revoked = true }
        override fun releaseAfterTeardown() { released = true }
    }

    private class Bytes : ChromeRegistryBytes {
        var value: ByteArray? = null
        override fun read() = value?.copyOf()
        override fun replace(expectedSHA256: String?, bytes: ByteArray) { value = bytes.copyOf() }
        override fun close() = Unit
    }

    private val account = ChromeOwnerSource.Paired("opaque/non-uuid/account-A")
    private fun ownership(epoch: Long = 4) = ChromeSyncOwnership(account.account, "device-fixture", epoch, true)

    @Test fun everyLifecycleCallRunsTheMainThreadGateBeforeAnyOtherWork() {
        val registry = ChromeIdentityRegistry(Bytes())
        val port = Port()
        var gateCalls = 0
        var portFactoryCalls = 0
        val host = ChromeEngineHost.create(registry, ::ownership, { portFactoryCalls++; port }, { gateCalls++ })
        val owner = host.prepareNew(account)
        assertEquals(1, gateCalls)
        assertTrue(host.activate(owner))
        assertEquals(2, gateCalls)
        assertEquals(1, portFactoryCalls)
        host.tab(owner, BrowserTab("tab-1", createdAt = 1), WebsiteProfile("profile-1"), BooleanSupplier { true })
        assertEquals(3, gateCalls)
        host.ownershipChanged()
        assertEquals(4, gateCalls)
        host.revoke(owner)
        assertEquals(5, gateCalls)
        host.releaseAfterTeardown(owner)
        assertEquals(6, gateCalls)
        assertTrue(port.revoked && port.released)
        registry.close()
    }

    @Test fun gateRefusalBlocksTheCallBeforeAnyRegistryWrite() {
        val bytes = Bytes()
        val registry = ChromeIdentityRegistry(bytes)
        val port = Port()
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, { throw IllegalStateException("off Chromium UI thread") })
        assertThrows(IllegalStateException::class.java) { host.prepareNew(account) }
        // The gate ran before the producer: no owner was persisted and no port was touched.
        assertNull(bytes.value)
        assertEquals(0, port.freshCalls + port.savedCalls)
        registry.close()
    }

    @Test fun deadLeaseActivateRefusesWithoutTouchingTheNativePortAndClearsTheTicket() {
        val registry = ChromeIdentityRegistry(Bytes())
        val port = Port()
        var portFactoryCalls = 0
        var ownershipEpoch = 4L
        val host = ChromeEngineHost.create(registry, { ownership(ownershipEpoch) }, { portFactoryCalls++; port }, {})
        val owner = host.prepareNew(account)
        ownershipEpoch = 5
        assertFalse(host.activate(owner))
        // The factory ran for the attempt; the native port stayed untouched.
        assertEquals(1, portFactoryCalls)
        assertEquals(0, port.freshCalls + port.savedCalls)
        // The refused ticket was discarded: a fresh owner needs no teardown first.
        val next = host.prepareNew(account)
        assertTrue(host.activate(next))
        registry.close()
    }

    @Test fun refusedSavedOwnerActivationDiscardsTheTicketWithoutNativeRevocation() {
        val bytes = Bytes()
        ChromeIdentityRegistry(bytes).use { seed ->
            seed.publicIdentity(seed.beginNewOwner(account), "profile-1", "tab-1")
        }
        val registry = ChromeIdentityRegistry(bytes)
        val port = Port()
        port.acceptSaved = false
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, {})
        val owner = host.prepareSaved(account)
        assertNotNull(owner)
        assertFalse(host.activate(owner!!))
        assertEquals(1, port.savedCalls)
        // The producer discarded the ticket: no native owner was installed, so no revoke.
        assertFalse(port.revoked)
        val fresh = host.prepareNew(account)
        assertTrue(host.activate(fresh))
        assertEquals(1, port.freshCalls)
        registry.close()
    }

    @Test fun savedOwnerPathCompletesTheFullLifecycle() {
        val bytes = Bytes()
        ChromeIdentityRegistry(bytes).use { seed ->
            seed.publicIdentity(seed.beginNewOwner(account), "profile-1", "tab-1")
        }
        val registry = ChromeIdentityRegistry(bytes)
        val port = Port()
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, {})
        val owner = host.prepareSaved(account)
        assertNotNull(owner)
        assertTrue(host.activate(owner!!))
        assertEquals(1, port.savedCalls)
        host.revoke(owner)
        host.releaseAfterTeardown(owner)
        assertTrue(port.revoked && port.released)
        registry.close()
    }

    @Test fun cancelPreparedSkipsNativeTeardownAndFreesTheProducerSlot() {
        val registry = ChromeIdentityRegistry(Bytes())
        val port = Port()
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, {})
        val owner = host.prepareNew(account)
        host.cancelPrepared(owner)
        assertFalse(port.revoked || port.released)
        val next = host.prepareNew(account)
        assertTrue(host.activate(next))
        assertEquals(1, port.freshCalls)
        registry.close()
    }

    @Test fun secondActivateOnTheSameTicketFailsTheProducerCheckWithoutNewNativeWork() {
        val registry = ChromeIdentityRegistry(Bytes())
        val port = Port()
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, {})
        val owner = host.prepareNew(account)
        assertTrue(host.activate(owner))
        assertThrows(IllegalStateException::class.java) { host.activate(owner) }
        assertEquals(1, port.freshCalls)
        registry.close()
    }

    @Test fun tabActivationCarriesOwnershipAndPrivateBoundaries() {
        val registry = ChromeIdentityRegistry(Bytes())
        val port = Port()
        val host = ChromeEngineHost.create(registry, ::ownership, { port }, {})
        val owner = host.prepareNew(account)
        host.activate(owner)
        val tab = host.tab(owner, BrowserTab("tab-1", createdAt = 1), WebsiteProfile("profile-1"), BooleanSupplier { true })
        assertEquals(owner.identity.accountUUID, tab.identity.accountUUID)
        assertFalse(tab.identity.privateMode)
        val privateTab = host.tab(owner, BrowserTab("tab-2", isPrivate = true, createdAt = 1),
            WebsiteProfile("profile-2", isPrivate = true), BooleanSupplier { true })
        assertTrue(privateTab.identity.privateMode)
        assertTrue(privateTab.identity.inMemory)
        host.privateTabsDisposed(owner)
        registry.close()
    }
}
package dev.yab.chromium

import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import dev.yab.sync.AccountRecordsSnapshot
import dev.yab.sync.SyncIdentityLease
import dev.yab.sync.nativeAccountOwnerCurrent
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.function.BooleanSupplier

class ChromeOwnerProducerTest {
    private class Bytes : ChromeRegistryBytes {
        var value: ByteArray? = null
        var failWrite = false
        var afterWrite: (() -> Unit)? = null
        override fun read() = value?.copyOf()
        override fun replace(expectedSHA256: String?, bytes: ByteArray) {
            if (failWrite) throw IOException("owned fixture disk failure")
            check(value?.let { MessageDigest.getInstance("SHA-256").digest(it).joinToString("") { part -> "%02x".format(part) } } == expectedSHA256)
            value = bytes.copyOf(); afterWrite?.invoke()
        }
        override fun close() = Unit
    }
    private class Port(var saved: ChromeOwnerIdentity? = null) : ChromeBootstrapPort {
        var freshCalls = 0; var savedCalls = 0; var revoked = false; var released = false
        override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean {
            savedCalls++
            return lease.getAsBoolean() && saved?.let { it.accountUUID == accountUUID && it.ownerEpochUUID == expectedOwnerEpochUUID } == true
        }
        override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) {
            check(lease.getAsBoolean()); freshCalls++
        }
        override fun revokeOwner() { revoked = true }
        override fun releaseAfterTeardown() { check(revoked); released = true }
    }
    private val account = ChromeOwnerSource.Paired("opaque/non-uuid/account-A")
    private fun ownership(source: ChromeOwnerSource = account, epoch: Long = 4) = when (source) {
        ChromeOwnerSource.StandaloneLocal -> ChromeSyncOwnership(null, null, epoch, true)
        is ChromeOwnerSource.Paired -> ChromeSyncOwnership(source.account, "device-fixture", epoch, true)
    }
    private fun tab(id: String, privateMode: Boolean = false) = BrowserTab(id, isPrivate = privateMode, createdAt = 1)

    @Test fun durableOpaqueMappingsRestoreAcrossRegistryReopenWithoutUsingDeviceOrSyncEpochAsIdentity() {
        val directory = Files.createTempDirectory("chrome-native-identities-").toFile()
        val file = directory.resolve("identities.json")
        try {
            val (first, row) = ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                val first = registry.beginNewOwner(account)
                val row = registry.publicIdentity(first, "shared", "opaque-tab:1")
                assertEquals(row, registry.publicIdentity(first, "shared", "opaque-tab:1"))
                first to row
            }
            ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                assertEquals(first, registry.savedOwner(account))
                assertEquals(row, registry.publicIdentity(first, "shared", "opaque-tab:1"))
                val isolated = registry.publicIdentity(first, "space-opaque-id", "opaque-tab:2")
                assertNotEquals(row.namespaceUUID, isolated.namespaceUUID)
                val newGeneration = registry.beginNewOwner(account)
                assertEquals(first.accountUUID, newGeneration.accountUUID)
                assertNotEquals(first.ownerEpochUUID, newGeneration.ownerEpochUUID)
                assertEquals(row, registry.publicIdentity(newGeneration, "shared", "opaque-tab:1"))
                assertThrows(IllegalStateException::class.java) { registry.publicIdentity(first, "shared", "opaque-tab:3") }
            }
            assertFalse(file.readText().contains("device-fixture"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun standaloneTagCannotCollideWithAnOpaquePairedAccountOrReuseItsWebsiteJar() {
        ChromeIdentityRegistry(Bytes()).use { registry ->
            val local = registry.beginNewOwner(ChromeOwnerSource.StandaloneLocal)
            val paired = registry.beginNewOwner(ChromeOwnerSource.Paired("standalone"))
            assertNotEquals(local.accountUUID, paired.accountUUID)
            val one = registry.publicIdentity(local, "shared", "same-tab")
            val two = registry.publicIdentity(paired, "shared", "same-tab")
            assertNotEquals(one.namespaceUUID, two.namespaceUUID); assertNotEquals(one.tabUUID, two.tabUUID)
        }
    }

    @Test fun checksumCorruptionUnknownFormatAndOversizeArePreservedAndNeverBecomeNewOwners() {
        val storage = Bytes()
        ChromeIdentityRegistry(storage).use { it.beginNewOwner(account) }
        val valid = storage.value!!.copyOf()
        for (broken in listOf(valid.copyOf().apply { this[lastIndex / 2] = (this[lastIndex / 2].toInt() xor 1).toByte() },
            valid.toString(Charsets.UTF_8).replace("\"format\":1", "\"format\":99").toByteArray(), ByteArray(2 * 1024 * 1024 + 1))) {
            storage.value = broken
            assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
            assertArrayEquals(broken, storage.value)
        }
    }

    @Test fun oneRegistryWriterAndExternalByteChangeFailClosed() {
        val directory = Files.createTempDirectory("chrome-owner-lock-").toFile(); val file = directory.resolve("identities.json")
        try {
            ChromeIdentityRegistry(FileChromeRegistryBytes(file)).use { registry ->
                registry.beginNewOwner(account)
                assertThrows(Exception::class.java) { FileChromeRegistryBytes(file) }
                file.writeText("foreign-corruption")
                assertThrows(IllegalStateException::class.java) { registry.savedOwner(account) }
                assertEquals("foreign-corruption", file.readText())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun failedPersistenceCannotIssueActivationOrDiscardPriorSavedIdentity() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val old = registry.beginNewOwner(account); val original = storage.value!!.copyOf()
        storage.failWrite = true
        val producer = ChromeOwnerProducer(registry) { ownership() }
        assertThrows(IOException::class.java) { producer.prepareNew(account) }
        assertArrayEquals(original, storage.value); assertEquals(old, registry.savedOwner(account))
        val saved = producer.prepareSaved(account)!!
        // The activation records the ownership snapshot it was prepared under.
        assertEquals(ownership(), saved.captured)
        assertEquals(old, saved.identity); producer.cancelPrepared(saved); registry.close()
    }

    @Test fun savedBootstrapRequiresExactDurableEpochAndDoesNotAutomaticallyStartNewOwner() {
        val registry = ChromeIdentityRegistry(Bytes()); val original = registry.beginNewOwner(account)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val prepared = producer.prepareSaved(account)!!
        val wrongGeneration = registry.beginNewOwner(account)
        val port = Port(wrongGeneration)
        assertFalse(producer.activate(prepared, port))
        assertEquals(1, port.savedCalls); assertEquals(0, port.freshCalls)
        assertFalse(prepared.lease.getAsBoolean()); assertEquals(original.accountUUID, wrongGeneration.accountUUID)
        registry.close()
    }

    @Test fun accountDeviceEpochAndRemovalLeasesAreStickyAndRevokeBeforeReplacement() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        val owner = producer.prepareNew(account); val port = Port()
        assertTrue(producer.activate(owner, port))
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        current = current.copy(epoch = current.epoch + 1)
        producer.ownershipChanged(); assertTrue(port.revoked); assertFalse(owner.lease.getAsBoolean())
        current = ownership(); assertFalse(owner.lease.getAsBoolean())
        producer.releaseAfterTeardown(owner); assertTrue(port.released)
        for (replacement in listOf(ownership().copy(device = "another-device"), ownership().copy(account = "B"), ownership().copy(available = false))) {
            current = ownership(); val next = producer.prepareSaved(account)!!; assertTrue(producer.activate(next, Port(next.identity)))
            current = replacement; assertFalse(next.lease.getAsBoolean())
            producer.revoke(next); producer.releaseAfterTeardown(next)
        }
        registry.close()
    }

    @Test fun standaloneCannotActivateDuringPairedSessionOrWhenAtomicSourceIsUnavailable() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(ChromeOwnerSource.StandaloneLocal) }
        current = ownership(ChromeOwnerSource.StandaloneLocal).copy(available = false)
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(ChromeOwnerSource.StandaloneLocal) }
        current = ownership(ChromeOwnerSource.StandaloneLocal)
        val owner = producer.prepareNew(ChromeOwnerSource.StandaloneLocal)
        assertTrue(producer.activate(owner, Port())); current = ownership()
        assertFalse(owner.lease.getAsBoolean()); producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun accountChangeDuringIOCannotReachBootstrapAndLeavesNoPreparedTicket() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        storage.afterWrite = { current = current.copy(epoch = current.epoch + 1) }
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        storage.afterWrite = null
        val saved = producer.prepareSaved(account)!!; val port = Port(saved.identity)
        assertTrue(producer.activate(saved, port)); producer.revoke(saved); producer.releaseAfterTeardown(saved)
        registry.close()
    }

    @Test fun privateIDsNeverReachDiskAndAreFreshAfterActualPrivateDisposal() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        val before = storage.value!!.copyOf()
        val privateTab = tab("PRIVATE-TAB-SENTINEL", true); val privateProfile = WebsiteProfile("PRIVATE-PROFILE-SENTINEL", true)
        val first = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        assertTrue(first.identity.privateMode && first.identity.inMemory && first.lease.getAsBoolean())
        assertEquals(first.identity, producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true }).identity)
        assertArrayEquals(before, storage.value)
        assertFalse(storage.value!!.toString(Charsets.UTF_8).contains("PRIVATE-"))
        producer.privateTabsDisposed(owner)
        assertFalse(first.lease.getAsBoolean())
        val second = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        assertNotEquals(first.identity.tabUUID, second.identity.tabUUID); assertNotEquals(first.identity.namespaceUUID, second.identity.namespaceUUID)
        assertArrayEquals(before, storage.value)
        assertThrows(IllegalArgumentException::class.java) { producer.tab(owner, privateTab, WebsiteProfile("shared"), BooleanSupplier { true }) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun tabSourceChangedDuringMappingCannotProduceLiveNativeIdentity() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }; val owner = producer.prepareNew(account)
        assertTrue(producer.activate(owner, Port())); var current = true
        storage.afterWrite = { current = false }
        assertThrows(IllegalStateException::class.java) { producer.tab(owner, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { current }) }
        storage.afterWrite = null; current = true
        val mapped = producer.tab(owner, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { current })
        assertTrue(mapped.lease.getAsBoolean()); current = false; assertFalse(mapped.lease.getAsBoolean())
        current = true; assertFalse(mapped.lease.getAsBoolean())
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun leaseFailureBeforeNativeAcceptanceDiscardsTicketWithoutTouchingThePort() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        val owner = producer.prepareNew(account)
        current = current.copy(available = false)
        val port = Port()
        assertFalse(producer.activate(owner, port))
        assertEquals(0, port.savedCalls + port.freshCalls)
        assertFalse(owner.lease.getAsBoolean())
        // The discarded ticket is fully gone: the next owner needs no teardown.
        current = ownership()
        val next = producer.prepareNew(account)
        assertTrue(producer.activate(next, Port()))
        producer.revoke(next); producer.releaseAfterTeardown(next)
        registry.close()
    }

    @Test fun leaseFailureAfterNativeAcceptanceKeepsTicketForForcedTeardown() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        val owner = producer.prepareNew(account)
        val port = object : ChromeBootstrapPort {
            var revoked = false; var released = false
            override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier) = true
            override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) { current = current.copy(epoch = current.epoch + 1) }
            override fun revokeOwner() { revoked = true }
            override fun releaseAfterTeardown() { check(revoked); released = true }
        }
        assertFalse(producer.activate(owner, port))
        assertTrue(port.revoked); assertFalse(owner.lease.getAsBoolean())
        // The ticket stays current: the caller must finish teardown, not start another owner.
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        assertTrue(port.released)
        // Only after confirmed teardown may a new owner be prepared.
        val next = producer.prepareNew(account); assertTrue(producer.activate(next, Port()))
        producer.revoke(next); producer.releaseAfterTeardown(next)
        registry.close()
    }

    @Test fun throwingPortCallPreservesTeardownOwnershipAndSuppressesCleanupFailure() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account)
        val port = object : ChromeBootstrapPort {
            var revokeCalls = 0
            override fun activateSavedOwner(accountUUID: String, expectedOwnerEpochUUID: String, lease: BooleanSupplier): Boolean = throw IOException("native refused")
            override fun startNewOwner(accountUUID: String, ownerEpochUUID: String, lease: BooleanSupplier) = throw IOException("native refused")
            override fun revokeOwner() { revokeCalls++; if (revokeCalls == 1) throw IOException("cleanup refused") }
            override fun releaseAfterTeardown() = Unit
        }
        val failure = assertThrows(IOException::class.java) { producer.activate(owner, port) }
        assertEquals(1, port.revokeCalls)
        assertEquals(1, failure.suppressed.size)
        assertTrue(failure.suppressed[0] is IOException)
        assertFalse(owner.lease.getAsBoolean())
        // Teardown ownership is preserved: the caller still completes release, never a silent new owner.
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun cancelPreparedRejectsForeignTicketsAndThosePastActivation() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val foreignRegistry = ChromeIdentityRegistry(Bytes())
        val foreign = ChromeOwnerProducer(foreignRegistry) { ownership() }.prepareNew(account)
        assertThrows(IllegalStateException::class.java) { producer.cancelPrepared(foreign) }
        val saved = producer.prepareNew(account)
        producer.activate(saved, Port())
        assertThrows(IllegalStateException::class.java) { producer.cancelPrepared(saved) }
        producer.revoke(saved); producer.releaseAfterTeardown(saved)
        assertThrows(IllegalStateException::class.java) { producer.cancelPrepared(saved) }
        foreignRegistry.close()
        registry.close()
    }

    @Test fun wedgedOwnerBetweenRevokeAndTeardownNeverStartsAnotherOwner() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        val owner = producer.prepareNew(account); val port = Port()
        assertTrue(producer.activate(owner, port))
        current = current.copy(epoch = current.epoch + 1)
        producer.ownershipChanged()
        assertTrue(port.revoked); assertFalse(owner.lease.getAsBoolean())
        // Between revoke and confirmed teardown every prepare is refused: the wedged state is
        // fail-stuck by design, and only confirmed native destruction or process death clears it.
        assertThrows(IllegalStateException::class.java) { producer.prepareSaved(account) }
        assertThrows(IllegalStateException::class.java) { producer.prepareNew(account) }
        producer.releaseAfterTeardown(owner)
        val next = producer.prepareNew(account)
        assertTrue(producer.activate(next, Port()))
        producer.revoke(next); producer.releaseAfterTeardown(next)
        registry.close()
    }

    @Test fun savedOwnerSurvivesFullOwnerCycleWithoutPersistenceOfPrivateNamespaces() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        val publicTab = producer.tab(owner, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { true })
        val publicBytes = storage.value!!.copyOf()
        val privateTab = producer.tab(owner, tab("private-row", true), WebsiteProfile("private-shared", true), BooleanSupplier { true })
        assertArrayEquals(publicBytes, storage.value)
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        // A later owner reuses durable public mappings but never RAM-only private ones.
        val next = producer.prepareSaved(account)!!
        assertEquals(owner.identity, next.identity)
        assertTrue(producer.activate(next, Port(next.identity)))
        assertEquals(publicTab.identity, producer.tab(next, tab("public-row"), WebsiteProfile("shared"), BooleanSupplier { true }).identity)
        val freshPrivate = producer.tab(next, tab("private-row", true), WebsiteProfile("private-shared", true), BooleanSupplier { true })
        assertNotEquals(privateTab.identity.tabUUID, freshPrivate.identity.tabUUID)
        assertNotEquals(privateTab.identity.namespaceUUID, freshPrivate.identity.namespaceUUID)
        assertArrayEquals(publicBytes, storage.value)
        registry.close()
    }

    @Test fun boundedIdentifiersAcceptUnicodeAndRejectControlCharactersAndOversize() {
        val unicode = "ω-πλ-на-βrowser.域.example"
        boundedIdentifier(unicode)
        for (broken in listOf("", "line\nbreak", "carriage\rreturn", "bell\u0007", "del\u007f")) {
            assertThrows(IllegalArgumentException::class.java) { boundedIdentifier(broken) }
        }
        // 1024 bytes is the boundary: accepted at the limit, refused beyond it.
        boundedIdentifier("é".repeat(512))
        assertThrows(IllegalArgumentException::class.java) { boundedIdentifier("é".repeat(513)) }
        // Canonical UUIDs refuse the all-zero form and non-UUID spellings.
        assertThrows(IllegalArgumentException::class.java) { canonicalUUID("00000000-0000-0000-0000-000000000000") }
        assertThrows(IllegalArgumentException::class.java) { canonicalUUID("00000000000000000000000000000000000") }
        assertThrows(IllegalArgumentException::class.java) { canonicalUUID("not-a-uuid") }
        canonicalUUID(java.util.UUID.randomUUID().toString())
        // A source account with control characters is refused at construction, not persisted.
        assertThrows(IllegalArgumentException::class.java) { ChromeOwnerSource.Paired("bad\u0007account") }
        // Unicode accounts work end to end through the durable registry.
        val unicodeAccount = ChromeOwnerSource.Paired(unicode)
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry) { ownership(unicodeAccount) }
        val owner = producer.prepareNew(unicodeAccount)
        assertTrue(producer.activate(owner, Port()))
        val mapped = producer.tab(owner, tab(unicode), WebsiteProfile(unicode), BooleanSupplier { true })
        assertEquals(mapped.identity, producer.tab(owner, tab(unicode), WebsiteProfile(unicode), BooleanSupplier { true }).identity)
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun oversizePrivateMappingsAreRefusedWithoutDiscardingExistingPrivateTabs() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        val privateTab = tab("private-existing", true); val privateProfile = WebsiteProfile("private-shared", true)
        val first = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        // The cap protects the mapping tables: an unknown tab at the cap is refused,
        // while an already-mapped tab keeps its identity.
        repeat(CHROME_MAX_TABS_PER_OWNER - 1) { producer.tab(owner, tab("filler-$it", true), privateProfile, BooleanSupplier { true }) }
        val existing = producer.tab(owner, privateTab, privateProfile, BooleanSupplier { true })
        assertEquals(first.identity, existing.identity)
        assertThrows(IllegalStateException::class.java) { producer.tab(owner, tab("one-past-cap", true), privateProfile, BooleanSupplier { true }) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun oversizePrivateProfileNamespacesAreRefusedLikeTabs() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        // Distinct private profiles fill the RAM-only namespace table; distinct tabs keep it from
        // failing on the tab cap first.
        repeat(CHROME_MAX_PROFILES_PER_OWNER) { index ->
            producer.tab(owner, tab("cap-tab-$index", true), WebsiteProfile("cap-profile-$index", true), BooleanSupplier { true })
        }
        val lastProfile = WebsiteProfile("cap-profile-${CHROME_MAX_PROFILES_PER_OWNER - 1}", true)
        producer.tab(owner, tab("already-mapped-tab", true), lastProfile, BooleanSupplier { true })
        assertThrows(IllegalStateException::class.java) {
            producer.tab(owner, tab("one-past-cap", true), WebsiteProfile("one-past-cap-profile", true), BooleanSupplier { true })
        }
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun oversizePublicRegistryEntriesAreRefusedAndBytesUnchanged() {
        val storage = Bytes(); val registry = ChromeIdentityRegistry(storage)
        val producer = ChromeOwnerProducer(registry) { ownership() }
        val owner = producer.prepareNew(account); assertTrue(producer.activate(owner, Port()))
        repeat(CHROME_MAX_PROFILES_PER_OWNER) { producer.tab(owner, tab("tab-$it"), WebsiteProfile("profile-$it"), BooleanSupplier { true }) }
        val before = storage.value!!.copyOf()
        assertThrows(IllegalArgumentException::class.java) { producer.tab(owner, tab("one-more-tab"), WebsiteProfile("one-more-profile"), BooleanSupplier { true }) }
        assertArrayEquals(before, storage.value)
        producer.revoke(owner); producer.releaseAfterTeardown(owner); registry.close()
    }

    @Test fun atomicAccountPublicationRequiresImmediateIdentityAndCloseGateBeforeNativeUse() {
        val image = AccountRecordsSnapshot(account = "A", device = "device-A", epoch = 9, phase = "live")
        val lease = SyncIdentityLease("A", "device-A", 9)
        assertTrue(nativeAccountOwnerCurrent(image, image, lease, 9, false))
        // Network disconnection alone is not an account switch or permission to use another jar.
        assertTrue(nativeAccountOwnerCurrent(image, image.copy(phase = "waiting"), lease, 9, false))
        for (changed in listOf(image.copy(account = "B"), image.copy(device = "device-B"), image.copy(epoch = 10), image.copy(removed = true))) {
            assertFalse(nativeAccountOwnerCurrent(image, changed, lease, 9, false))
        }
        assertFalse(nativeAccountOwnerCurrent(image, image, lease.copy(device = "device-B"), 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, lease.copy(epoch = 10), 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, null, 9, false))
        assertFalse(nativeAccountOwnerCurrent(image, image, lease, 9, true))
        val standalone = AccountRecordsSnapshot(epoch = 11)
        assertTrue(nativeAccountOwnerCurrent(standalone, standalone, null, 11, false))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, null, 11, true))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, lease, 11, false))
        assertFalse(nativeAccountOwnerCurrent(standalone, standalone, null, 12, false))
    }

    @Test fun doubleActivationIsRefusedAndTheTicketStaysUsableOnce() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        val port = Port()
        assertTrue(producer.activate(owner, port))
        assertThrows(IllegalStateException::class.java) { producer.activate(owner, Port()) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun releaseWithoutRevocationIsRefusedAndReleaseAfterUnactivatedRevokeSkipsThePort() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        val port = Port()
        assertTrue(producer.activate(owner, port))
        // Teardown requires the revoke first: the native side is still live.
        assertThrows(IllegalStateException::class.java) { producer.releaseAfterTeardown(owner) }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        assertTrue(port.revoked)
        // A revoked-before-activation ticket has no port to release; the dead-lease refusal
        // discards it, and its port never hears a native call.
        val other = producer.prepareNew(account)
        producer.revoke(other)
        val bare = Port()
        assertFalse(producer.activate(other, bare))
        assertFalse(bare.revoked)
        registry.close()
    }

    @Test fun tabCallsAfterRevokeAreRefusedByTheEntryCheckBeforeMapping() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        assertTrue(producer.activate(owner, Port()))
        producer.revoke(owner)
        assertThrows(IllegalStateException::class.java) {
            producer.tab(owner, tab("public-row"), WebsiteProfile("shared")) { true }
        }
        producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun aDuplicateMintedUUIDIsRefusedInsteadOfReusingAnIdentity() {
        var first = true
        val minted = mutableListOf<String>()
        val registry = ChromeIdentityRegistry(Bytes()) { if (first) { first = false; "0d9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d" } else "1d9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d".also { minted.add(it) } }
        val owner = registry.beginNewOwner(account)
        // beginNewOwner minted two ids (account + generation); publicIdentity re-mints only
        // fresh ones. Forcing a collision: a registry whose mint repeats the account UUID.
        val repeating = ChromeIdentityRegistry(Bytes()) { "2d9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d" }
        assertThrows(IllegalStateException::class.java) { repeating.beginNewOwner(account) }
        repeating.close()
        registry.close()
    }

    @Test fun anOverfullPerOwnerEntryIsRefusedAtLoad() {
        val storage = Bytes()
        val profiles = (1..CHROME_MAX_PROFILES_PER_OWNER + 1).joinToString(",") { "\"p$it\":\"0d9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d\"" }
        val roguePayload = """{"entries":[{"kind":"standalone","account":"0e9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d","generation":"0f9f6b84-1111-4a66-9d1f-3f4e5a6b7c8d","profiles":{$profiles}}]}"""
        val envelope = "{\"format\":1,\"payload\":${jsonString(roguePayload)},\"sha256\":\"${digest(roguePayload.toByteArray())}\"}"
        storage.value = envelope.toByteArray()
        assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
    }

    @Test fun anUnknownOwnerKindIsRefusedAtLoadInsteadOfBecomingAnOwner() {
        val storage = Bytes()
        val roguePayload = """{"entries":[{"kind":"rogue","account":"a","generation":"b"}]}"""
        val envelope = "{\"format\":1,\"payload\":${jsonString(roguePayload)},\"sha256\":\"${digest(roguePayload.toByteArray())}\"}"
        storage.value = envelope.toByteArray()
        assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
        assertArrayEquals(envelope.toByteArray(), storage.value)
    }

    @Test fun aStandaloneEntryCarryingAnOpaqueAccountIsRefusedAtLoad() {
        val storage = Bytes()
        val roguePayload = """{"entries":[{"kind":"standalone","opaqueAccount":"x","account":"a","generation":"b"}]}"""
        val envelope = "{\"format\":1,\"payload\":${jsonString(roguePayload)},\"sha256\":\"${digest(roguePayload.toByteArray())}\"}"
        storage.value = envelope.toByteArray()
        assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
    }

    @Test fun aPairedEntryWithoutItsOpaqueAccountIsRefusedAtLoad() {
        val storage = Bytes()
        val roguePayload = """{"entries":[{"kind":"paired","account":"a","generation":"b"}]}"""
        val envelope = "{\"format\":1,\"payload\":${jsonString(roguePayload)},\"sha256\":\"${digest(roguePayload.toByteArray())}\"}"
        storage.value = envelope.toByteArray()
        assertThrows(Exception::class.java) { ChromeIdentityRegistry(storage) }
    }

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun jsonString(text: String) = "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    @Test fun ownershipChangedWithNoActiveOwnerOrLiveLeaseIsANoOpOrRevokes() {
        val registry = ChromeIdentityRegistry(Bytes()); var current = ownership()
        val producer = ChromeOwnerProducer(registry) { current }
        // No active owner: the collector fires and nothing happens.
        producer.ownershipChanged()
        val owner = producer.prepareNew(account)
        producer.activate(owner, Port())
        // The lease still holds: no revoke.
        producer.ownershipChanged()
        // The lease dies underneath the collector: revoke before teardown.
        current = current.copy(epoch = current.epoch + 1)
        producer.ownershipChanged()
        assertFalse(owner.lease.getAsBoolean())
        producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun aStaleSourceDuringTabMappingRefusesInsteadOfMapping() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        producer.activate(owner, Port())
        assertThrows(IllegalStateException::class.java) {
            producer.tab(owner, tab("public-row"), WebsiteProfile("shared")) { false }
        }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun revokeBeforeActivationHasNoPortToCallAndStillCycles() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        // Revoke before activate: owner.port is null, no native call, and the documented
        // dead-lease refusal discards the ticket instead of reaching the port.
        producer.revoke(owner)
        assertTrue(owner.revoked.get())
        val port = Port()
        assertFalse(producer.activate(owner, port))
        assertEquals(0, port.savedCalls + port.freshCalls)
        // The dead-lease refusal discarded the ticket: no teardown is owed on it.
        registry.close()
    }

    @Test fun aPublicTabWithAPrivateProfileIsRefusedBeforeAnyMapping() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        producer.activate(owner, Port())
        assertThrows(IllegalArgumentException::class.java) {
            producer.tab(owner, tab("public-row"), WebsiteProfile("shared", isPrivate = true)) { true }
        }
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun revokeReleaseAndDisposalRejectForeignOrOutOfOrderTickets() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        producer.cancelPrepared(owner)
        // A second owner is a foreign ticket to the first one's teardown entry points;
        // canceling the first left no active owner, so every teardown call on it fails its check.
        val other = producer.prepareNew(account)
        assertThrows(IllegalStateException::class.java) { producer.revoke(owner) }
        assertThrows(IllegalStateException::class.java) { producer.releaseAfterTeardown(owner) }
        assertThrows(IllegalStateException::class.java) { producer.privateTabsDisposed(owner) }
        // The live ticket still cycles cleanly after the refusals.
        producer.activate(other, Port())
        producer.revoke(other); producer.privateTabsDisposed(other); producer.releaseAfterTeardown(other)
        registry.close()
    }

    @Test fun syncOwnershipPermissionCoversEveryAccountDeviceAndAvailabilityArm() {
        val paired = ChromeOwnerSource.Paired("opaque/account-A")
        assertTrue(ChromeSyncOwnership("opaque/account-A", "device", 4, available = true).permits(paired))
        // A Paired owner is refused with a missing device, a different account, or no availability.
        assertFalse(ChromeSyncOwnership("opaque/account-A", null, 4, available = true).permits(paired))
        assertFalse(ChromeSyncOwnership("opaque/account-A", "", 4, available = true).permits(paired))
        assertFalse(ChromeSyncOwnership("other", "device", 4, available = true).permits(paired))
        assertFalse(ChromeSyncOwnership("opaque/account-A", "device", 4, available = false).permits(paired))
        assertTrue(ChromeSyncOwnership(null, null, 4, available = true).permits(ChromeOwnerSource.StandaloneLocal))
        assertFalse(ChromeSyncOwnership("opaque/account-A", null, 4, available = true).permits(ChromeOwnerSource.StandaloneLocal))
        assertFalse(ChromeSyncOwnership(null, "device", 4, available = true).permits(ChromeOwnerSource.StandaloneLocal))
        assertFalse(ChromeSyncOwnership(null, null, 4, available = false).permits(ChromeOwnerSource.StandaloneLocal))
    }

    @Test fun aThrowingOwnershipSupplierFailsTheLeaseClosedInsteadOfLeakingTheProducer() {
        val registry = ChromeIdentityRegistry(Bytes())
        var throwing = false
        val producer = ChromeOwnerProducer(registry, { if (throwing) throw IllegalStateException("sync snapshot vanished") else ownership() })
        val owner = producer.prepareNew(account)
        throwing = true
        assertFalse(owner.lease.getAsBoolean())
        // The revoked lease is sticky and never self-heals.
        throwing = false
        assertFalse(owner.lease.getAsBoolean())
        registry.close()
    }

    @Test fun savedOwnerLookupWhenOwnershipShiftsDuringIORefusesWithoutATicket() {
        val storage = Bytes()
        val registry = ChromeIdentityRegistry(storage)
        registry.beginNewOwner(account)
        // Ownership must be stable between the capture and the post-IO recheck; the second
        // supplier call simulates Sync mutating it inside that window.
        var calls = 0
        val producer = ChromeOwnerProducer(registry, { if (calls++ == 1) ownership(epoch = 5) else ownership() })
        assertThrows(Exception::class.java) { producer.prepareSaved(account) }
        // The refusal left no ticket: an explicit new owner can still be prepared.
        val owner = producer.prepareNew(account)
        producer.cancelPrepared(owner)
        registry.close()
    }

    @Test fun prepareSavedWithoutASavedOwnerReturnsNullAndLeavesNoTicket() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        assertNull(producer.prepareSaved(account))
        registry.close()
    }

    @Test fun aThrowingOwnershipSupplierDuringTabMappingFailsTheTabLeaseClosed() {
        val registry = ChromeIdentityRegistry(Bytes())
        val producer = ChromeOwnerProducer(registry, ::ownership)
        val owner = producer.prepareNew(account)
        val port = Port(); producer.activate(owner, port)
        var throwing = false
        val tabActivation = producer.tab(owner, tab("t", privateMode = true), WebsiteProfile("p", isPrivate = true), BooleanSupplier {
            if (throwing) throw IllegalStateException("native tab source vanished") else true })
        throwing = true
        assertFalse(tabActivation.lease.getAsBoolean())
        // The revoked lease is sticky: a recovered source does not resurrect it.
        throwing = false
        assertFalse(tabActivation.lease.getAsBoolean())
        producer.revoke(owner); producer.releaseAfterTeardown(owner)
        registry.close()
    }

    @Test fun fileBytesRefuseDirectoryRegistriesSymlinksAndSecondJVMWritersPerArm() {
        val directory = Files.createTempDirectory("chrome-file-bytes-").toFile()
        try {
            val file = directory.resolve("identities.json")
            // An existing regular file is accepted: the happy path owns read/replace.
            FileChromeRegistryBytes(file).use { bytes -> assertNull(bytes.read()) }
            // A directory in place of the registry file is refused.
            val nested = directory.resolve("as-directory"); nested.mkdirs()
            FileChromeRegistryBytes(nested).use { bytes -> assertThrows(IllegalStateException::class.java) { bytes.read() } }
            // The registry file itself becoming a symbolic link is refused on open and on read.
            val target = directory.resolve("elsewhere.json")
            val link = directory.resolve("as-link.json")
            Files.createSymbolicLink(link.toPath(), target.toPath())
            assertThrows(IllegalStateException::class.java) { FileChromeRegistryBytes(link) }
            // A symbolic link in place of the lock file is refused too.
            val lockTarget = directory.resolve("lock-target")
            val lockLink = directory.resolve("lock-link.json.lock")
            Files.createSymbolicLink(lockLink.toPath(), lockTarget.toPath())
            assertThrows(IllegalStateException::class.java) { FileChromeRegistryBytes(directory.resolve("lock-link.json")) }
            // A missing parent directory is created on open; a rooted parent that cannot be
            // created fails the directory check instead.
            val fresh = directory.resolve("fresh/sub/identities.json")
            FileChromeRegistryBytes(fresh).close()
            assertTrue(fresh.parentFile!!.isDirectory)
            assertThrows(IllegalStateException::class.java) { FileChromeRegistryBytes(File("/nonexistent-root/identities.json")) }
        } finally { directory.deleteRecursively() }
    }

    @Test fun aSecondProcessHoldingTheLockFileRefusesOpenWithTheWriterMessage() {
        val directory = Files.createTempDirectory("chrome-foreign-lock-").toFile()
        try {
            val file = directory.resolve("identities.json")
            val lockFile = File(file.parentFile, file.name + ".lock")
            // fcntl/flock taken by another process makes tryLock return null; python3 is the
            // portable holder on both macOS and Linux CI.
            val holder = ProcessBuilder("python3", "-c", """
                import fcntl, time
                f = open(r'${lockFile.absolutePath}', 'w')
                fcntl.flock(f.fileno(), fcntl.LOCK_EX)
                print('held', flush=True)
                time.sleep(60)
                """.trimIndent()).start()
            try {
                // The holder prints its marker only after the lock is taken; read it to close
                // the race instead of sleeping.
                holder.inputStream.bufferedReader().readLine()
                val refused = try { FileChromeRegistryBytes(file); null } catch (error: Exception) { error }
                assertNotNull(refused)
                assertTrue(refused is IOException)
                assertEquals("Local Chromium identities already have a writer", refused!!.message)
            } finally { holder.destroyForcibly() }
        } finally { directory.deleteRecursively() }
    }

    @Test fun closedFileBytesFailClosedOnReadAndReplace() {
        val directory = Files.createTempDirectory("chrome-file-closed-").toFile()
        try {
            val bytes = FileChromeRegistryBytes(directory.resolve("identities.json"))
            bytes.close()
            assertThrows(IllegalStateException::class.java) { bytes.read() }
            assertThrows(IllegalStateException::class.java) { bytes.replace(null, "{}".toByteArray()) }
            // Closing twice stays a no-op: releasing a dead lock is not an error path callers see.
            bytes.close()
        } finally { directory.deleteRecursively() }
    }

    @Test fun fileBytesReplaceRefusesOversizeAndForeignByteChanges() {
        val directory = Files.createTempDirectory("chrome-file-replace-").toFile()
        try {
            val file = directory.resolve("identities.json")
            FileChromeRegistryBytes(file).use { bytes ->
                bytes.replace(null, "{}".toByteArray())
                // The expected digest pins the current bytes: an existing file no longer
                // matches a null expectation, and a foreign byte change is refused.
                val digest = MessageDigest.getInstance("SHA-256").digest("{}".toByteArray()).joinToString("") { "%02x".format(it) }
                assertThrows(IllegalStateException::class.java) { bytes.replace(null, "x".toByteArray()) }
                file.writeText("tampered")
                assertThrows(IllegalStateException::class.java) { bytes.replace(digest, "x".toByteArray()) }
                // Size bounds are checked before the digest: check() throws, not require().
                assertThrows(IllegalStateException::class.java) { bytes.replace(digest, ByteArray(0)) }
                assertThrows(IllegalStateException::class.java) { bytes.replace(digest, ByteArray(2 * 1024 * 1024 + 1)) }
            }
        } finally { directory.deleteRecursively() }
    }
}

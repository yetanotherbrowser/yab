package dev.yab.browser.engine

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class CertificateExceptionsStoreTest {
    private fun store(dir: File = Files.createTempDirectory("certs").toFile(), write: (() -> Unit) -> Unit = { it() }) =
        CertificateExceptionsStore(File(dir, "certificate-exceptions.json"), write)

    private fun chain(vararg pems: String) = CertificateException.fingerprints(pems.toList())

    private fun ledger(dir: File): File = File(dir, "certificate-exceptions.json")

    private fun noLeftoverTempFiles(dir: File) =
        assertTrue(dir.list { _, name -> name.endsWith(".next") }.orEmpty().isEmpty())

    private fun thePardonsOnDisk(dir: File): Set<Pair<String, Int>> {
        val reopened = store(dir)
        return reopened.state.value.profiles.values.flatten()
            .map { it.host to it.port }.toSet()
    }

    @Test fun aPardonIsFoundForItsEndpointAndNoOther() {
        val store = store()
        store.remember("shared", "Example.COM", 443, chain("a"), now = 1_000)
        assertNotNull(store.pardon("shared", "example.com", 443, now = 2_000))
        assertNull(store.pardon("shared", "example.com", 8443, now = 2_000))
        assertNull(store.pardon("shared", "other.example.com", 443, now = 2_000))
        assertNull(store.pardon("space-one", "example.com", 443, now = 2_000))
    }

    @Test fun theHostIsKeptAsGivenWithoutBrackets() {
        val store = store()
        store.remember("shared", "[2001:db8::1]", 443, chain("a"), now = 1_000)
        assertEquals("2001:db8::1", store.pardon("shared", "2001:db8::1", 443, now = 2_000)?.host)
    }

    @Test fun aChangedChainAsksAgainEvenWhileThePardonLives() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        assertTrue(store.accepts("shared", "example.com", 443, chain("a"), now = 2_000))
        assertFalse(store.accepts("shared", "example.com", 443, chain("b"), now = 2_000))
    }

    @Test fun aPublicPardonRunsOutAfterAWeekAndALocalOneAfterAMonth() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        val week = 7L * 24 * 3600 * 1000
        assertNotNull(store.pardon("shared", "example.com", 443, now = 1_000 + week - 1))
        assertNull(store.pardon("shared", "example.com", 443, now = 1_000 + week))

        store.remember("shared", "router.local", 443, chain("a"), now = 1_000)
        val month = 30L * 24 * 3600 * 1000
        assertNotNull(store.pardon("shared", "router.local", 443, now = 1_000 + month - 1))
        assertNull(store.pardon("shared", "router.local", 443, now = 1_000 + month))
    }

    @Test fun aClockThatMovedBackKeepsThePardon() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("a"), now = 500)
        assertNotNull(store.pardon("shared", "example.com", 443, now = 100))
    }

    @Test fun rememberingAgainRefreshesTheDateAndKeepsOnePardonPerEndpoint() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        val week = 7L * 24 * 3600 * 1000
        store.remember("shared", "example.com", 443, chain("b"), now = 1_000 + week)
        assertNotNull(store.pardon("shared", "example.com", 443, now = 1_000 + week + week - 1))
        val all = store.state.value.profiles["shared"].orEmpty()
        assertEquals(1, all.size)
        assertEquals(chain("b"), all.first().chain)
    }

    @Test fun aSecondContinueUpdatesTheChainWithoutGrowingTheList() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("a"), now = 0)
        store.remember("shared", "example.com", 443, chain("b"), now = 10)
        val all = store.state.value.profiles["shared"].orEmpty()
        assertEquals(1, all.size)
        assertTrue(store.accepts("shared", "example.com", 443, chain("b"), now = 20))
    }

    @Test fun aPardonThatRanOutIsDroppedWhenTheNextOneIsKept() {
        val store = store()
        val week = 7L * 24 * 3600 * 1000
        store.remember("shared", "example.com", 443, chain("a"), now = 0)
        store.remember("shared", "other.example.com", 443, chain("b"), now = week + 10)
        val all = store.state.value.profiles["shared"].orEmpty()
        assertEquals(listOf("other.example.com"), all.map { it.host })
    }

    @Test fun invalidInputIsNotKept() {
        val store = store()
        store.remember("shared", "", 443, chain("a"))
        store.remember("shared", "example.com", 0, chain("a"))
        store.remember("shared", "example.com", 65536, chain("a"))
        store.remember("shared", "example.com", 443, emptyList())
        assertTrue(store.state.value.profiles["shared"].orEmpty().isEmpty())
    }

    @Test fun pardonsPersistAcrossStoreLivesAndKeepTheirProfile() {
        val dir = Files.createTempDirectory("certs").toFile()
        store(dir).remember("shared", "example.com", 443, chain("a"), now = 1_000)
        store(dir).remember("space-one", "other.example.com", 443, chain("b"), now = 1_000)
        val reopened = store(dir)
        assertNotNull(reopened.pardon("shared", "example.com", 443, now = 2_000))
        assertNotNull(reopened.pardon("space-one", "other.example.com", 443, now = 2_000))
        assertTrue(reopened.accepts("shared", "example.com", 443, chain("a"), now = 2_000))
    }

    @Test fun aPrivatePardonNeverReachesTheDisk() {
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir)
        store.remember("private", "example.com", 443, chain("a"), now = 1_000)
        // The pardon lives in memory only: the ledger knows nothing of it.
        assertNotNull(store.pardon("private", "example.com", 443, now = 2_000))
        val text = ledger(dir).takeIf { it.isFile }?.readText().orEmpty()
        assertFalse(text.contains("private"))
        assertNull(store(dir).pardon("private", "example.com", 443, now = 2_000))
    }

    @Test fun aPrivatePardonSurvivesAMixedPersist() {
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir)
        store.remember("private", "secret.example.com", 443, chain("a"), now = 1_000)
        store.remember("shared", "example.com", 443, chain("b"), now = 1_000)
        // The shared profile reaches the disk; the private one never does.
        val text = ledger(dir).readText()
        assertTrue(text.contains("shared"))
        assertFalse(text.contains("private"))
        assertFalse(text.contains("secret.example.com"))
        assertNotNull(store(dir).pardon("shared", "example.com", 443, now = 2_000))
        assertNull(store(dir).pardon("private", "secret.example.com", 443, now = 2_000))
    }

    @Test fun aPrivateProfileIsForgottenTogether() {
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir)
        store.remember("shared", "other.example.com", 443, chain("b"), now = 1_000)
        val privateStore = store(dir)
        privateStore.remember("private", "example.com", 443, chain("a"), now = 1_000)
        privateStore.forgetPrivate()
        assertNull(store(dir).pardon("private", "example.com", 443, now = 2_000))
        assertNotNull(store(dir).pardon("shared", "other.example.com", 443, now = 2_000))
    }

    @Test fun forgettingThePrivateKeyBehavesAsForgettingPrivatePardons() {
        val dir = Files.createTempDirectory("certs").toFile()
        store(dir).remember("shared", "other.example.com", 443, chain("b"), now = 1_000)
        store(dir).remember("private", "example.com", 443, chain("a"), now = 1_000)
        store(dir).forgetProfile("private")
        assertNull(store(dir).pardon("private", "example.com", 443, now = 2_000))
        assertNotNull(store(dir).pardon("shared", "other.example.com", 443, now = 2_000))
    }

    @Test fun aProfileMayDropItsOwnPardons() {
        val dir = Files.createTempDirectory("certs").toFile()
        store(dir).remember("space-one", "example.com", 443, chain("a"), now = 1_000)
        store(dir).remember("space-two", "other.example.com", 443, chain("b"), now = 1_000)
        store(dir).forgetProfile("space-one")
        assertNull(store(dir).pardon("space-one", "example.com", 443, now = 2_000))
        // What survived stays on disk, and the no-op forget is no failure.
        assertEquals(setOf("other.example.com" to 443), thePardonsOnDisk(dir))
        store(dir).forgetProfile("space-three")
        assertEquals(setOf("other.example.com" to 443), thePardonsOnDisk(dir))
    }

    @Test fun twoThreadsRememberingConcurrentlyKeepEveryPardon() {
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir)
        val start = java.util.concurrent.CountDownLatch(1)
        val threads = listOf(
            Thread {
                start.await()
                repeat(50) { i -> store.remember("shared", "a$i.example.com", 443, chain("x"), now = 1_000) }
            },
            Thread {
                start.await()
                repeat(50) { i -> store.remember("shared", "b$i.example.com", 443, chain("y"), now = 1_000) }
            },
        )
        threads.forEach { it.start() }
        start.countDown()
        threads.forEach { it.join() }
        assertEquals(100, store.state.value.profiles["shared"].orEmpty().size)
        assertEquals(100, thePardonsOnDisk(dir).size)
    }

    @Test fun anUnreadableFileStartsEmptyRatherThanRefusingEverything() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText("not json")
        val store = store(dir)
        assertTrue(store.state.value.profiles.isEmpty())
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        assertNotNull(store.pardon("shared", "example.com", 443, now = 2_000))
    }

    @Test fun aFileOfWrongTypesInsideReadsAsEmpty() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText("""{"schema":1,"profiles":{"shared":"oops"}}""")
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }

    @Test fun anEmptyFileReadsAsEmpty() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText("")
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }

    @Test fun anOversizedFileIsRefused() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText("x".repeat(2 * 1024 * 1024 + 1))
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }

    @Test fun aFileWithUnusablePardonsDropsThemButKeepsTheUsableOne() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText(
            "{\"schema\":1,\"profiles\":{\"shared\":[" +
                "{\"host\":\"\",\"port\":443,\"chain\":[\"a\"],\"at\":0}," +
                "{\"host\":\"example.com\",\"port\":0,\"chain\":[\"a\"],\"at\":0}," +
                "{\"host\":\"example.com\",\"port\":70000,\"chain\":[\"a\"],\"at\":0}," +
                "{\"host\":\"example.com\",\"port\":443,\"chain\":[],\"at\":0}," +
                "{\"host\":\"other.example.com\",\"port\":443,\"chain\":[\"b\"],\"at\":0}]}}")
        val opened = store(dir)
        assertEquals(setOf("other.example.com" to 443), opened.state.value.profiles.values.flatten().map { it.host to it.port }.toSet())
    }

    @Test fun aFileOfAnotherSchemaIsRefused() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText(
            "{\"schema\":2,\"profiles\":{\"shared\":[{\"host\":\"example.com\",\"port\":443,\"chain\":[\"a\"],\"at\":0}]}}")
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }

    @Test fun aFileWithTooManyProfilesIsRefused() {
        val dir = Files.createTempDirectory("certs").toFile()
        val profiles = (1..1001).joinToString(",") { index ->
            "\"space-$index\":[{\"host\":\"example.com\",\"port\":443,\"chain\":[\"a\"],\"at\":0}]"
        }
        File(dir, "certificate-exceptions.json").writeText("{\"schema\":1,\"profiles\":{$profiles}}")
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }

    @Test fun pardonsThatExpiredWhileAwayAreNotKept() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText(
            "{\"schema\":1,\"profiles\":{\"shared\":[{\"host\":\"example.com\",\"port\":443,\"chain\":[\"a\"],\"at\":0}]}}")
        val opened = store(dir)
        assertTrue(opened.state.value.profiles.isNotEmpty())
        val week = 7L * 24 * 3600 * 1000
        assertNull(opened.pardon("shared", "example.com", 443, now = week))
    }

    @Test fun aPardonTooBigForTheLedgerStillLivesInMemoryWithoutHalfWriting() {
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir)
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        val goodLedger = ledger(dir).readText()
        val huge = "pem-" + "x".repeat(3 * 1024 * 1024)
        store.remember("shared", "big.example.com", 443, listOf(huge), now = 1_000)
        assertNotNull(store.pardon("shared", "big.example.com", 443, now = 2_000))
        // The ledger on disk is the last good write, not a partial one.
        assertEquals(goodLedger, ledger(dir).readText())
        noLeftoverTempFiles(dir)
        // Reopening keeps only what the last good write held.
        assertEquals(setOf("example.com" to 443), thePardonsOnDisk(dir))
    }

    @Test fun writeFailuresAreSurvivedByTheInMemoryPardonAndTheLedger() {
        var broken = false
        val dir = Files.createTempDirectory("certs").toFile()
        val store = store(dir, write = { if (broken) throw java.io.IOException("disk full") else it() })
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        val goodLedger = ledger(dir).readText()
        broken = true
        store.remember("shared", "other.example.com", 443, chain("b"), now = 2_000)
        assertNotNull(store.pardon("shared", "other.example.com", 443, now = 3_000))
        // The ledger on disk is the last good write, and no temp file leaks.
        assertEquals(goodLedger, ledger(dir).readText())
        noLeftoverTempFiles(dir)
    }

    @Test fun aStoreWithoutAFileStillPardons() {
        val store = CertificateExceptionsStore()
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        assertNotNull(store.pardon("shared", "example.com", 443, now = 2_000))
    }

    @Test fun aFailureInsideAQueuedWriterEscapesNowhereAndKeepsThePardonInMemory() {
        // The ledger's parent is a regular file, so the write itself fails
        // once the queued block runs, on the writer's own thread.
        val dir = Files.createTempDirectory("certs").toFile()
        val blocker = File(dir, "blocker")
        blocker.writeText("not a directory")
        val escaped = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val writer = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable).apply { setUncaughtExceptionHandler { _, thrown -> escaped.set(thrown) } }
        }
        val store = CertificateExceptionsStore(File(blocker, "certificate-exceptions.json"), write = { writer.execute(it) })
        store.remember("shared", "example.com", 443, chain("a"), now = 1_000)
        writer.shutdown()
        assertTrue(writer.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS))
        // The failure stayed inside the queued block: the thread lived, and
        // the decision survives in memory.
        assertNull(escaped.get())
        assertNotNull(store.pardon("shared", "example.com", 443, now = 2_000))
        assertFalse(File(blocker, "certificate-exceptions.json").exists())
    }

    @Test fun pardonedHostsNameEachPardonedHostOnceRegardlessOfPort() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("pem-a"), now = 1_000)
        store.remember("shared", "example.com", 8443, chain("pem-b"), now = 1_000)
        store.remember("shared", "nas.local", 8767, chain("pem-a"), now = 1_000)
        assertEquals(setOf("example.com", "nas.local"), store.pardonedHosts("shared", now = 2_000))
    }

    @Test fun pardonedHostsSkipWhatRanOutAndOtherProfiles() {
        val store = store()
        val now = System.currentTimeMillis()
        val week = 7L * 24 * 3600 * 1000
        val month = 30L * 24 * 3600 * 1000
        store.remember("shared", "example.com", 443, chain("pem-a"), now = now - 1_000)
        store.remember("shared", "expired.example", 443, chain("pem-a"), now = now - week - 1_000)
        store.remember("shared", "nas.local", 443, chain("pem-a"), now = now - month - 1_000)
        store.remember("space-two", "other.example", 443, chain("pem-a"), now = now - 1_000)
        assertEquals(setOf("example.com"), store.pardonedHosts("shared"))
        assertEquals(setOf("other.example"), store.pardonedHosts("space-two"))
        assertEquals(setOf<String>(), store.pardonedHosts("unknown"))
    }

    @Test fun pardonedHostsGoOnceAProfileForgetsItsDecisions() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("pem-a"))
        assertEquals(setOf("example.com"), store.pardonedHosts("shared"))
        store.forgetProfile("shared")
        assertEquals(setOf<String>(), store.pardonedHosts("shared"))
    }

    @Test fun aFileOmittingTheProfilesReadsAsEmpty() {
        val dir = Files.createTempDirectory("certs").toFile()
        File(dir, "certificate-exceptions.json").writeText("{\"schema\":1}")
        assertTrue(store(dir).state.value.profiles.isEmpty())
    }
}
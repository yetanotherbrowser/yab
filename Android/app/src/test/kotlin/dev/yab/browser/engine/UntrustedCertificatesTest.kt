package dev.yab.browser.engine

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class UntrustedCertificatesTest {
    private fun store() = CertificateExceptionsStore(Files.createTempDirectory("certs").toFile().let { File(it, "certs.json") })
    private fun chain(vararg pems: String) = CertificateException.fingerprints(pems.toList())

    private fun payload(nonce: String, action: String, host: String, port: Int, chain: List<String> = emptyList()) =
        """{"nonce":"$nonce","action":"$action","host":"$host","port":$port,"chain":[${chain.joinToString(",") { "\"$it\"" }}]}"""

    private fun nonceOf(uri: String): String {
        val nonce = uri.substringAfter("nonce=").substringBefore("&")
        assertTrue("nonce is 32 hex chars: $nonce", Regex("[0-9a-f]{32}").matches(nonce))
        return nonce
    }

    @Test fun theInterstitialCarriesItsNonceAndTheFailedAddress() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com:8443/path", auto = false)
        assertTrue(uri.startsWith(UntrustedCertificates.INTERSTITIAL))
        nonceOf(uri)
        assertTrue(uri.contains("url=https%3A%2F%2Fexample.com%3A8443%2Fpath"))
        assertTrue(uri.endsWith("auto=0"))
        // A pardoned revisit asks the page to continue by itself.
        val autoUri = certificates.interstitialUri("shared", "https://example.com", auto = true)
        assertTrue(autoUri.endsWith("auto=1"))
    }

    private fun freshAsk(
        certificates: UntrustedCertificates,
        host: String = "example.com",
        port: Int = 443,
        action: String,
        chain: List<String>,
    ): UntrustedCertificates.Ask? {
        val uri = certificates.interstitialUri("shared", "https://$host${if (port != 443) ":$port" else ""}/", auto = false)
        return certificates.ask(payload(nonceOf(uri), action, host, port, chain))
    }

    @Test fun aSpentNonceNeverAsksAgain() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val message = payload(nonceOf(uri), "continue", "example.com", 443, listOf("pem"))
        assertNotNull(certificates.ask(message))
        assertNull(certificates.ask(message))
    }

    @Test fun missingFieldsFallBackToTheEndpointTheLoadNamed() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val ask = certificates.ask("""{"nonce":"${nonceOf(uri)}","action":"back"}""")
        assertNotNull(ask)
        assertEquals("example.com", ask?.host)
        assertEquals(443, ask?.port)
        assertTrue(ask?.chain?.isEmpty() == true)
    }

    @Test fun wrongShapeFieldsThatNameTheRightEndpointFallBackAndAsk() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        // The fields fall back to the endpoint the load named, so the ask stands.
        val ask = certificates.ask("""{"nonce":"$nonce","action":"continue","host":{"x":1},"port":"not-a-port"}""")
        assertNotNull(ask)
        assertEquals("example.com", ask?.host)
        assertEquals(443, ask?.port)
    }

    @Test fun aWrongShapeNonceIsRefusedAndBurnsNothing() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        assertNull(certificates.ask("""{"nonce":{"x":1},"action":"continue","host":"example.com","port":443}"""))
        assertNull(certificates.ask("""{"nonce":"wrong-shape","action":{"x":1},"host":"example.com","port":443}"""))
        // The live nonce is untouched by the malformed one.
        assertNotNull(certificates.ask(payload(nonceOf(uri), "continue", "example.com", 443)))
    }

    @Test fun aWrongShapeChainFallsBackToAnEmptyOneAndStillAsks() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        // The chain field falls back to an empty chain, so the ask stands and
        // spends the nonce, exactly as a chain-less ask does.
        val ask = certificates.ask("""{"nonce":"$nonce","action":"continue","host":"example.com","port":443,"chain":{"x":1}}""")
        assertNotNull(ask)
        assertTrue(ask?.chain?.isEmpty() == true)
        assertNull(certificates.ask(payload(nonce, "back", "example.com", 443)))
    }

    @Test fun aForeignOrMalformedAskIsRefused() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        assertNull(certificates.ask("not json"))
        assertNull(certificates.ask(null))
        assertNull(certificates.ask("""{"action":"continue"}"""))
        assertNull(certificates.ask(payload("deadbeef", "continue", "example.com", 443)))
    }

    @Test fun aForgedEndpointBehindALiveNonceBurnsIt() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        // A forged endpoint on a terminal action: refused, and the nonce burns,
        // so a probe cannot keep asking until one ask names the endpoint.
        assertNull(certificates.ask(payload(nonce, "continue", "other.example.com", 443)))
        assertNull(certificates.ask(payload(nonce, "continue", "example.com", 443)))
    }

    @Test fun aForgedEndpointOnAnAutoAskIsRefusedWithoutBurning() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        // A forged endpoint on an automatic ask just fails; the person can still
        // decide by hand afterwards.
        assertNull(certificates.ask(payload(nonce, "auto", "other.example.com", 443)))
        assertNotNull(certificates.ask(payload(nonce, "continue", "example.com", 443)))
    }

    @Test fun aDeniedAutoAskMayAskAgain() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        val denied = certificates.ask(payload(nonce, "auto", "example.com", 443, listOf("pem")))
        assertNotNull(denied)
        assertFalse(certificates.answer(denied!!))
        // The nonce lives on: the person's own continue still works.
        assertNotNull(certificates.ask(payload(nonce, "continue", "example.com", 443)))
    }

    @Test fun anAskForAnotherPortIsRefused() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        assertNull(certificates.ask(payload(nonceOf(uri), "continue", "example.com", 8443)))
    }

    @Test fun anAddressWithAnEmptyPortDefaultsToTheWebPort() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com:", auto = false)
        val ask = certificates.ask(payload(nonceOf(uri), "continue", "example.com", 443, listOf("pem")))
        assertNotNull(ask)
        assertEquals(443, ask?.port)
    }

    @Test fun aWebAddressWithoutAHostNamesNoEndpoint() {
        val certificates = UntrustedCertificates(store())
        // A web scheme with no host: the interstitial cannot stand for an endpoint.
        val uri = certificates.interstitialUri("shared", "http:/path", auto = false)
        assertTrue(uri.startsWith(UntrustedCertificates.INTERSTITIAL))
        // No pardon covers an endpoint nobody can name.
        assertFalse(certificates.pardoned("shared", "http:/path"))
    }

    @Test fun anUnknownActionIsRefusedWithoutSpendingTheNonce() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        val nonce = nonceOf(uri)
        assertNull(certificates.ask(payload(nonce, "delete-everything", "example.com", 443)))
        // The nonce is untouched by an action this bridge does not speak.
        assertNotNull(certificates.ask(payload(nonce, "continue", "example.com", 443)))
    }

    @Test fun aBracketedIpv6NameAsksAsItsBareForm() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "https://[2001:db8::1]/", auto = false)
        val ask = certificates.ask(payload(nonceOf(uri), "continue", "[2001:db8::1]", 443, listOf("pem")))
        assertNotNull(ask)
        assertEquals("2001:db8::1", ask?.host)
    }

    @Test fun goBackDeniesWithoutRecordingAnything() {
        val store = store()
        val certificates = UntrustedCertificates(store)
        val ask = freshAsk(certificates, action = "back", chain = listOf("pem"))
        assertNotNull(ask)
        assertFalse(certificates.answer(ask!!))
        assertTrue(store.state.value.profiles.isEmpty())
    }

    @Test fun continueRecordsTheEndpointAndAllowsTheLoad() {
        val store = store()
        val certificates = UntrustedCertificates(store)
        val ask = freshAsk(certificates, action = "continue", chain = listOf("pem-a", "pem-b"))
        assertTrue(certificates.answer(ask!!))
        assertNotNull(store.pardon("shared", "example.com", 443))
        assertTrue(store.accepts("shared", "example.com", 443, chain("pem-a", "pem-b")))
    }

    @Test fun autoAllowsOnlyWhileThePardonMatchesTheChainShown() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("pem-a"))
        val certificates = UntrustedCertificates(store)
        val matching = freshAsk(certificates, action = "auto", chain = listOf("pem-a"))
        assertTrue(certificates.answer(matching!!))
        val changed = freshAsk(certificates, action = "auto", chain = listOf("pem-b"))
        assertFalse(certificates.answer(changed!!))
    }

    @Test fun autoWithoutAnyPardonDenies() {
        val certificates = UntrustedCertificates(store())
        val ask = freshAsk(certificates, action = "auto", chain = listOf("pem-a"))
        assertFalse(certificates.answer(ask!!))
    }

    @Test fun aPardonCoversALaterLoadOfTheSameEndpoint() {
        val store = store()
        val certificates = UntrustedCertificates(store)
        val ask = freshAsk(certificates, action = "continue", chain = listOf("pem-a"))
        certificates.answer(ask!!)
        assertTrue(certificates.pardoned("shared", "https://example.com/"))
        assertFalse(certificates.pardoned("shared", "https://other.example.com/"))
        assertFalse(certificates.pardoned("shared", "https://example.com:8443/"))
        assertFalse(certificates.pardoned("shared", "ftp://example.com/"))
    }

    @Test fun anActionOutsideTheKnownSetIsDeniedEvenIfItSomehowAsks() {
        val certificates = UntrustedCertificates(store())
        val rogue = UntrustedCertificates.Ask(action = "delete-everything", profile = "shared", host = "example.com", port = 443, chain = emptyList())
        assertFalse(certificates.answer(rogue))
    }

    @Test fun anUnparseableFailedUrlStillYieldsAnInterstitial() {
        val certificates = UntrustedCertificates(store())
        val uri = certificates.interstitialUri("shared", "::not a url::", auto = false)
        // No endpoint could be named, so only a matching (empty) endpoint asks.
        assertNull(certificates.ask(payload(nonceOf(uri), "continue", "example.com", 443)))
    }

    @Test fun aPardonIsCheckedAgainstTheFailedUrlOnly() {
        val store = store()
        store.remember("shared", "example.com", 443, chain("pem-a"))
        val certificates = UntrustedCertificates(store)
        assertTrue(certificates.pardoned("shared", "https://example.com/x?y=1"))
        // Not a web address: no endpoint, no pardon.
        assertFalse(certificates.pardoned("shared", "file:///etc/passwd"))
        assertFalse(certificates.pardoned("shared", "::not a url::"))
        assertFalse(certificates.pardoned("shared", ""))
    }

    @Test fun aPunycodeHostIsPardonedAsGiven() {
        val store = store()
        store.remember("shared", "xn--ol-2za.example", 443, chain("pem-a"))
        val certificates = UntrustedCertificates(store)
        assertTrue(certificates.pardoned("shared", "https://xn--ol-2za.example/"))
    }

    @Test fun theEldestNonceIsDroppedWhenThePageOutlivesItsInterstitials() {
        val certificates = UntrustedCertificates(store())
        val first = nonceOf(certificates.interstitialUri("shared", "https://first.example.com", auto = false))
        repeat(32) { i -> nonceOf(certificates.interstitialUri("shared", "https://many$i.example.com", auto = false)) }
        // 33 pendings: the eldest is gone, the newest still answers.
        assertNull(certificates.ask(payload(first, "continue", "first.example.com", 443)))
        val last = nonceOf(certificates.interstitialUri("shared", "https://last.example.com", auto = false))
        val ask = certificates.ask(payload(last, "continue", "last.example.com", 443, listOf("pem")))
        assertNotNull(ask)
    }

    @Test fun respondAllowsAContinuingAskAndDeniesABackAsk() {
        val certificates = UntrustedCertificates(store())
        val continueUri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        assertEquals("allow", certificates.respond(payload(nonceOf(continueUri), "continue", "example.com", 443, listOf("pem"))))
        val backUri = certificates.interstitialUri("shared", "https://example.com", auto = false)
        assertEquals("deny", certificates.respond(payload(nonceOf(backUri), "back", "example.com", 443)))
    }

    @Test fun respondStaysOutOfConversationsThatAreNotItsOwn() {
        val certificates = UntrustedCertificates(store())
        assertNull(certificates.respond("hello"))
        assertNull(certificates.respond(null))
        assertNull(certificates.respond("""{"nonce":"deadbeef","action":"continue","host":"example.com","port":443}"""))
    }
}

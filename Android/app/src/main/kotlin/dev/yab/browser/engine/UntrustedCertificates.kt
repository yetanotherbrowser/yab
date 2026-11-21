package dev.yab.browser.engine

import java.net.URI
import java.net.URLEncoder
import java.security.SecureRandom
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The bridge between the untrusted-certificate interstitial document and the
 * browser. GeckoView grants error-page documents addCertException(), but no
 * public API reports or persists an override, so this coordinator issues a
 * one-time nonce per interstitial load, answers the document's window.prompt
 * with allow or deny by that nonce, and records the pardon the person granted
 * in [CertificateExceptionsStore].
 *
 * A nonce is spent by a terminal action, continuing or going back; a denied
 * automatic ask may ask again, so the person can still decide by hand.
 */
class UntrustedCertificates(private val store: CertificateExceptionsStore) {
    data class Ask(val action: String, val profile: String, val host: String, val port: Int, val chain: List<String>)

    private val json = Json { ignoreUnknownKeys = true }
    // Insertion order decides which waiting nonce goes first when the page
    // outlives the interstitials it kept: the eldest is dropped.
    private val pending = LinkedHashMap<String, Pending>()

    private data class Pending(val profile: String, val host: String, val port: Int)

    /** The URI the error page loads instead of the site, carrying the nonce. */
    fun interstitialUri(profile: String, failedUrl: String, auto: Boolean): String {
        val host = webHostOf(failedUrl) ?: ""
        val port = webPortOf(failedUrl)
        val nonce = newNonce()
        synchronized(pending) {
            if (pending.size >= MAX_PENDING) pending.remove(pending.keys.first())
            pending[nonce] = Pending(profile, host, port)
        }
        return INTERSTITIAL + "?nonce=" + encode(nonce) + "&url=" + encode(failedUrl) +
            "&auto=" + (if (auto) "1" else "0")
    }

    /** Whether an unexpired pardon covers this failed URL's endpoint. */
    fun pardoned(profile: String, failedUrl: String): Boolean {
        val host = webHostOf(failedUrl) ?: return false
        return store.pardon(profile, host, webPortOf(failedUrl)) != null
    }

    /**
     * A prompt message from the page. Null unless its nonce is live and the
     * endpoint it names is the endpoint it was loaded for, so no other page,
     * and no replay, can ask as this page does. A terminal action spends the
     * nonce; an automatic ask does not, so a denied one can be followed by
     * the person's own decision.
     */
    fun ask(message: String?): Ask? {
        val parsed = runCatching { json.parseToJsonElement(message ?: return null).jsonObject }.getOrNull() ?: return null
        val nonce = parsed["nonce"]?.textOrNull() ?: return null
        val action = parsed["action"]?.textOrNull() ?: return null
        if (action !in ACTIONS) return null
        val asked = synchronized(pending) {
            if (action == "auto") pending[nonce] else pending.remove(nonce)
        } ?: return null
        // location.hostname keeps IPv6 brackets; the endpoint never does.
        val host = CertificateException.hostName(parsed["host"]?.textOrNull() ?: asked.host)
        val port = parsed["port"]?.intOrNull() ?: asked.port
        // The endpoint must be the one the interstitial stood in for.
        if (host != asked.host || port != asked.port) return null
        val chain = parsed["chain"]?.strings() ?: emptyList()
        return Ask(action = action, profile = asked.profile, host = host, port = port, chain = chain)
    }

    /** The answer to the document's ask: allow, or deny and keep the warning. */
    fun answer(ask: Ask): Boolean = when (ask.action) {
        "back" -> false
        // A pardon checked at load time is honored only if the chain it was
        // granted for is the chain in front of us now.
        "auto" -> store.accepts(ask.profile, ask.host, ask.port, CertificateException.fingerprints(ask.chain))
        "continue" -> {
            store.remember(ask.profile, ask.host, ask.port, CertificateException.fingerprints(ask.chain))
            true
        }
        else -> false
    }

    /** The prompt channel in one step: allow or deny for the page's ask, or
     * null when the message is not this bridge's to answer. */
    fun respond(message: String?): String? = ask(message)?.let { if (answer(it)) "allow" else "deny" }

    private fun webHostOf(url: String): String? = runCatching {
        val uri = URI(url)
        if (uri.scheme in setOf("http", "https")) uri.host?.let(CertificateException::hostName) else null
    }.getOrNull()

    private fun webPortOf(url: String): Int = runCatching {
        val uri = URI(url)
        uri.port.takeIf { it > 0 } ?: 443
    }.getOrDefault(443)

    private fun newNonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { byte -> "%02x".format(byte) }
    }

    companion object {
        const val INTERSTITIAL = "resource://android/assets/interstitials/untrusted-certificate.html"
        private const val MAX_PENDING = 32
        private val ACTIONS = setOf("continue", "auto", "back")
        private fun encode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())
    }
}

/** The field is text, or the ask was not what this bridge speaks. */
private fun JsonElement?.textOrNull(): String? =
    runCatching { this?.jsonPrimitive?.content }.getOrNull()

private fun JsonElement?.intOrNull(): Int? =
    runCatching { this?.jsonPrimitive?.content?.toInt() }.getOrNull()

private fun JsonElement?.strings(): List<String> =
    runCatching { this?.jsonArray?.map { it.jsonPrimitive.content } }.getOrNull() ?: emptyList()

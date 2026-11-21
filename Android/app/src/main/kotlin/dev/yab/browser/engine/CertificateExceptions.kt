package dev.yab.browser.engine

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * An exception names the exact TLS endpoint and the complete chain the person
 * inspected. A replacement certificate needs another decision.
 *
 * The chain is kept as SHA-256 fingerprints, not raw bytes: GeckoView hands the
 * chain to the error-page document as PEM strings only, and the fingerprint is
 * what equality needs. Not part of equality: the grant date, which only runs
 * the pardon out.
 */
@Serializable
data class CertificateException(
    val host: String,
    val port: Int,
    val chain: List<String>,
    val at: Long = System.currentTimeMillis(),
) {
    /** Public endpoints are reconsidered after a week. Local devices,
     * which commonly use self-signed certificates, get thirty days. */
    fun expired(now: Long): Boolean = now - at >= lives()

    fun lives(): Long {
        val bare = if (host.contains(":")) "[$host]" else host
        return if (AddressKind.isLocal(bare)) LOCAL_LIVES_MS else PUBLIC_LIVES_MS
    }

    fun matches(host: String, port: Int): Boolean =
        this.host == hostName(host) && this.port == port

    /** The same endpoint showing another chain: a renewed certificate asks again. */
    fun chainMatches(chain: List<String>): Boolean = this.chain == chain

    companion object {
        const val PUBLIC_LIVES_MS = 7L * 24 * 3600 * 1000
        const val LOCAL_LIVES_MS = 30L * 24 * 3600 * 1000

        fun hostName(host: String): String {
            val lower = host.lowercase(Locale.ROOT)
            return if (lower.startsWith("[") && lower.endsWith("]")) lower.substring(1, lower.length - 1) else lower
        }

        /** PEM strings, as [FailedCertSecurityInfo.certChainStrings] reports them. */
        fun fingerprints(pems: List<String>): List<String> =
            pems.map { pem -> MessageDigest.getInstance("SHA-256").digest(pem.toByteArray(Charsets.UTF_8))
                .joinToString("") { byte -> "%02x".format(byte) } }
    }
}

/** How local a machine is: loopback, this network's names and addresses. */
object AddressKind {
    fun isLocal(host: String): Boolean {
        val bare = host.lowercase(Locale.ROOT)
        if (bare.isEmpty()) return false
        if (bare == "localhost" || bare.endsWith(".localhost") || bare.endsWith(".local") || bare.endsWith(".ts.net")) return true
        if (bare.startsWith("[")) {
            // Loopback, link-local fe80::/10, unique local fc00::/7.
            val inside = if (bare.length >= 2) bare.substring(1, bare.length - 1) else ""
            if (inside == "::1") return true
            val first = inside.split(":", limit = 2).firstOrNull()?.takeIf(String::isNotEmpty) ?: return false
            val hextet = first.toIntOrNull(16)?.takeIf { it in 0..0xFFFF } ?: return false
            return hextet and 0xFFC0 == 0xFE80 || hextet and 0xFE00 == 0xFC00
        }
        val parts = bare.split(".")
        val numbers = parts.mapNotNull { part -> part.toIntOrNull()?.takeIf { it in 0..255 } }
        if (parts.size == 4 && numbers.size == 4) {
            return when {
                numbers[0] == 0 || numbers[0] == 10 || numbers[0] == 127 -> true
                numbers[0] == 100 && numbers[1] in 64..127 -> true
                numbers[0] == 192 && numbers[1] == 168 -> true
                numbers[0] == 169 && numbers[1] == 254 -> true
                numbers[0] == 172 && numbers[1] in 16..31 -> true
                else -> false
            }
        }
        // A name with no dots at all is a machine on this network.
        return parts.size == 1
    }
}

data class CertificateExceptionsState(
    val profiles: Map<String, List<CertificateException>> = emptyMap(),
)

/**
 * TLS endpoints this device excused, by sign-in profile. GeckoView keeps no
 * public exception ledger, so Yab keeps its own: the Gecko-side exception is
 * applied as temporary on each visit and this store decides whether to offer
 * continuing past the warning.
 *
 * Private profiles keep pardons for the life of the store only, mirroring the
 * Mac's ephemeral data stores. A pardon lives a week on the public internet,
 * a month for a machine on this network, and always dies with a changed chain.
 */
class CertificateExceptionsStore(private val file: File? = null, private val write: (() -> Unit) -> Unit = { it() }) {
    @Serializable
    private data class Disk(
        val schema: Int = 1,
        val profiles: Map<String, List<ProfileException>> = emptyMap(),
    )

    @Serializable
    private data class ProfileException(
        val host: String,
        val port: Int,
        val chain: List<String>,
        // A record from before the date was kept: it counts from now,
        // quietly, rather than refusing the whole file and losing the rest.
        val at: Long = System.currentTimeMillis(),
    )

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    // The in-memory map is the working record; two threads editing it at once
    // could lose one profile's change, so every read-modify-write goes through
    // this lock.
    private val lock = Any()
    private val mutable = MutableStateFlow(load())
    val state = mutable.asStateFlow()

    /** An unexpired pardon for this exact endpoint, if any, excluding chain comparison. */
    fun pardon(profile: String, host: String, port: Int, now: Long = System.currentTimeMillis()): CertificateException? =
        live(profile, now).firstOrNull { it.matches(host, port) }

    /** True when the endpoint has an unexpired pardon whose chain is this chain. */
    fun accepts(profile: String, host: String, port: Int, chain: List<String>, now: Long = System.currentTimeMillis()): Boolean {
        val pardon = pardon(profile, host, port, now) ?: return false
        return pardon.chainMatches(chain)
    }

    /** A continuing decision, recorded: endpoint and chain together. */
    fun remember(profile: String, host: String, port: Int, chain: List<String>, now: Long = System.currentTimeMillis()) {
        if (host.isBlank() || port !in 1..65535 || chain.isEmpty()) return
        val exception = CertificateException(host = CertificateException.hostName(host), port = port, chain = chain, at = now)
        edit(profile, now) { saved -> (listOf(exception) + saved.filterNot { it.matches(host, port) }).take(MAX_PER_PROFILE) }
    }

    /** The moment a profile's private window closes: its pardons go with it. */
    fun forgetProfile(profile: String) {
        edit(profile, System.currentTimeMillis()) { _ -> emptyList() }
    }

    /** The hosts a profile has unexpired pardons for, each once, regardless of
     * port: revoking Gecko's override for a host takes every port of that
     * host with it, so which port a pardon named no longer matters here. */
    fun pardonedHosts(profile: String, now: Long = System.currentTimeMillis()): Set<String> =
        live(profile, now).mapTo(mutableSetOf()) { it.host }

    fun forgetPrivate() {
        synchronized(lock) {
            mutable.update { it.copy(profiles = it.profiles - PRIVATE_PROFILE) }
            persist(mutable.value.profiles)
        }
    }

    private fun live(profile: String, now: Long): List<CertificateException> =
        mutable.value.profiles[profileKey(profile)]?.filter { !it.expired(now) } ?: emptyList()

    private fun profileKey(profile: String): String = profile

    private fun edit(profile: String, now: Long, change: (List<CertificateException>) -> List<CertificateException>) {
        synchronized(lock) {
            val before = mutable.value
            val key = profileKey(profile)
            val saved = before.profiles[key] ?: emptyList()
            val next = change(saved)
            if (next == saved) return
            val kept = next.filter { !it.expired(now) }
            mutable.value = before.copy(profiles = if (kept.isEmpty()) before.profiles - key else before.profiles + (key to kept))
            persist(mutable.value.profiles)
        }
    }

    private fun load(): CertificateExceptionsState {
        val source = file ?: return CertificateExceptionsState()
        if (!source.exists()) return CertificateExceptionsState()
        return try {
            require(source.length() <= MAX_BYTES)
            val disk = json.decodeFromString<Disk>(source.readText())
            require(disk.schema == 1 && disk.profiles.size <= MAX_PROFILES)
            val profiles = disk.profiles.mapValues { (_, saved) ->
                saved.mapNotNull { entry ->
                    if (entry.host.isBlank() || entry.port !in 1..65535 || entry.chain.isEmpty()) null
                    else CertificateException(host = entry.host, port = entry.port, chain = entry.chain, at = entry.at)
                }
            }.filterValues { it.isNotEmpty() }
            CertificateExceptionsState(profiles = profiles)
        } catch (_: Exception) { CertificateExceptionsState() }
    }

    private fun persist(profiles: Map<String, List<CertificateException>>) {
        val target = file ?: return
        // The write often runs later on a queued writer's thread, where an
        // escaped failure would kill the app, so the catch sits inside the
        // queued block as well as around it: the decision survives in memory
        // and the next change writes again. The outer catch is for the
        // writer itself refusing the work, the inner one for the write.
        try {
            write {
                try {
                    // A private session's pardons live in memory only; nothing the
                    // person excused there belongs on disk.
                    val durable = profiles.filterKeys { it != PRIVATE_PROFILE }
                    val disk = Disk(profiles = durable.mapValues { (_, list) ->
                        list.map { ProfileException(host = it.host, port = it.port, chain = it.chain, at = it.at) }
                    })
                    val temporary = File(target.parentFile, "${target.name}.${UUID.randomUUID()}.next")
                    try {
                        target.parentFile?.mkdirs()
                        val text = json.encodeToString(disk)
                        require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
                        temporary.outputStream().use { stream -> stream.write(text.toByteArray(Charsets.UTF_8)); stream.fd.sync() }
                        Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                    } finally { temporary.delete() }
                } catch (_: Exception) { }
            }
        } catch (_: Exception) { }
    }

    private companion object {
        const val MAX_BYTES = 2 * 1024 * 1024
        const val MAX_PROFILES = 1_000
        const val MAX_PER_PROFILE = 500
        const val PRIVATE_PROFILE = "private"
    }
}

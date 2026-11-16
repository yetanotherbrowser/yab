package dev.yab.chromium

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.UUID

/** Sync account names are opaque. Standalone browsing has a distinct, tagged local owner. */
sealed interface ChromeOwnerSource {
    data object StandaloneLocal : ChromeOwnerSource
    data class Paired(val account: String) : ChromeOwnerSource {
        init { boundedIdentifier(account) }
    }
}

data class ChromeOwnerIdentity internal constructor(
    val source: ChromeOwnerSource, val accountUUID: String, val ownerEpochUUID: String,
)

data class ChromeNamespaceIdentity internal constructor(
    val accountUUID: String, val tabUUID: String, val namespaceUUID: String,
    val inMemory: Boolean, val privateMode: Boolean,
)

/** The sole writer of this registry holds its lock until close. Chrome owns its own snapshot. */
interface ChromeRegistryBytes : Closeable {
    fun read(): ByteArray?
    fun replace(expectedSHA256: String?, bytes: ByteArray)
}

class FileChromeRegistryBytes(file: File) : ChromeRegistryBytes {
    private val file = file.absoluteFile
    private val channel: FileChannel
    private val lock: FileLock
    private var closed = false

    init {
        val parent = this.file.parentFile ?: throw IOException("Registry directory is missing")
        check(parent.isDirectory || parent.mkdirs()) { "Cannot create the local Chromium identity directory" }
        check(!Files.isSymbolicLink(this.file.toPath())) { "Registry must be an app-owned regular file" }
        val lockFile = File(parent, "${this.file.name}.lock")
        check(!Files.isSymbolicLink(lockFile.toPath())) { "Registry lock must belong to this app" }
        channel = FileChannel.open(lockFile.toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE)
        lock = try { channel.tryLock() ?: throw IOException("Local Chromium identities already have a writer") }
        catch (overlap: java.nio.channels.OverlappingFileLockException) {
            // Same-JVM second writer: identical contract, one IOException type for callers.
            channel.close(); throw IOException("Local Chromium identities already have a writer")
        }
        catch (error: Exception) { channel.close(); throw error }
    }

    @Synchronized override fun read(): ByteArray? {
        check(!closed)
        check(!Files.isSymbolicLink(file.toPath())) { "Registry cannot become a symbolic link" }
        if (!file.exists()) return null
        check(file.isFile) { "Invalid local Chromium registry" }
        return file.inputStream().use { input ->
            val bytes = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(4096)
            while (true) {
                val count = input.read(chunk)
                if (count < 0) break
                check(bytes.size() + count <= MAX_REGISTRY_BYTES) { "Local Chromium registry is too large" }
                bytes.write(chunk, 0, count)
            }
            bytes.toByteArray()
        }
    }

    @Synchronized override fun replace(expectedSHA256: String?, bytes: ByteArray) {
        check(!closed && bytes.size in 1..MAX_REGISTRY_BYTES)
        check(read()?.let(::sha256) == expectedSHA256) { "Local Chromium registry changed outside its owner" }
        val temporary = File(file.parentFile, ".${file.name}.${UUID.randomUUID()}.pending")
        check(temporary.createNewFile())
        try {
            FileOutputStream(temporary).use { output -> output.write(bytes); output.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            FileChannel.open(file.parentFile!!.toPath(), StandardOpenOption.READ).use { it.force(true) }
        } finally { temporary.delete() }
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        try { lock.release() } finally { channel.close() }
    }
}

/**
 * Local UUID allocation, not Sync authentication. Corrupt/unknown bytes are preserved and refused.
 * Open/create this in noBackupFilesDir on an IO dispatcher, never a Chrome/native UI callback.
 */
class ChromeIdentityRegistry(
    private val storage: ChromeRegistryBytes,
    private val mintUUID: () -> String = { UUID.randomUUID().toString() },
) : Closeable {
    // Every operation re-reads and hashes the whole file under the caller's monitor.
    // Measured on desktop JVM: ~0.15ms per op at 20 entries, ~0.9ms at the 4096-tab cap
    // (231KB file); beginNewOwner at cap costs ~9ms with its durable rewrite.

    @Serializable private data class Entry(
        val kind: String, val opaqueAccount: String? = null, val account: String, val generation: String,
        val profiles: Map<String, String> = emptyMap(), val tabs: Map<String, String> = emptyMap(),
    )
    @Serializable private data class Payload(val entries: List<Entry> = emptyList())
    @Serializable private data class Envelope(val format: Int = 1, val payload: String, val sha256: String)
    private val json = Json { encodeDefaults = true }
    private var observed: String? = null
    private var payload: Payload
    private var closed = false

    init {
        try {
            val bytes = storage.read()
            observed = bytes?.let(::sha256)
            payload = if (bytes == null) Payload() else {
                require(bytes.size in 1..MAX_REGISTRY_BYTES)
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                val envelope = json.decodeFromString<Envelope>(text)
                require(envelope.format == 1 && sha256(envelope.payload.toByteArray()) == envelope.sha256)
                json.decodeFromString<Payload>(envelope.payload)
            }
            validate(payload)
        } catch (error: Exception) { storage.close(); throw error }
    }

    @Synchronized fun savedOwner(source: ChromeOwnerSource): ChromeOwnerIdentity? {
        checkCurrentBytes()
        return payload.entries.firstOrNull { it.source() == source }?.identity()
    }

    /** An explicit operation only. A failed restore must never call this as a fallback. */
    @Synchronized fun beginNewOwner(source: ChromeOwnerSource): ChromeOwnerIdentity {
        checkCurrentBytes()
        val existing = payload.entries.firstOrNull { it.source() == source }
        val occupied = allUUIDs(payload).toMutableSet()
        fun mint() = mintUUID().also { canonicalUUID(it); check(occupied.add(it)) { "Duplicate local identity" } }
        val entry = existing?.copy(generation = mint()) ?: Entry(
            kind = if (source is ChromeOwnerSource.Paired) "paired" else "standalone",
            opaqueAccount = (source as? ChromeOwnerSource.Paired)?.account, account = mint(), generation = mint(),
        )
        commit(Payload(payload.entries.filterNot { it.source() == source } + entry))
        return entry.identity()
    }

    @Synchronized fun publicIdentity(owner: ChromeOwnerIdentity, opaqueProfile: String, opaqueTab: String): ChromeNamespaceIdentity {
        boundedIdentifier(opaqueProfile); boundedIdentifier(opaqueTab); checkCurrentBytes()
        val entry = payload.entries.singleOrNull { it.source() == owner.source && it.identity() == owner }
            ?: error("This local Chromium owner generation is no longer current")
        val occupied = allUUIDs(payload).toMutableSet()
        fun mint() = mintUUID().also { canonicalUUID(it); check(occupied.add(it)) { "Duplicate local identity" } }
        val namespace = entry.profiles[opaqueProfile] ?: mint()
        val tab = entry.tabs[opaqueTab] ?: mint()
        val next = entry.copy(profiles = entry.profiles + (opaqueProfile to namespace), tabs = entry.tabs + (opaqueTab to tab))
        if (next != entry) commit(Payload(payload.entries.map { if (it === entry) next else it }))
        return ChromeNamespaceIdentity(entry.account, tab, namespace, inMemory = false, privateMode = false)
    }

    private fun Entry.source(): ChromeOwnerSource = when (kind) {
        "standalone" -> { require(opaqueAccount == null); ChromeOwnerSource.StandaloneLocal }
        "paired" -> ChromeOwnerSource.Paired(requireNotNull(opaqueAccount))
        else -> error("Unknown local Chromium owner kind")
    }
    private fun Entry.identity() = ChromeOwnerIdentity(source(), account, generation)
    private fun allUUIDs(value: Payload) = value.entries.flatMap { listOf(it.account, it.generation) + it.profiles.values + it.tabs.values }
    private fun validate(value: Payload) {
        require(value.entries.size <= 64)
        require(value.entries.map { it.source() }.distinct().size == value.entries.size)
        val ids = allUUIDs(value)
        ids.forEach(::canonicalUUID); require(ids.distinct().size == ids.size)
        value.entries.forEach { entry ->
            require(entry.profiles.size <= CHROME_MAX_PROFILES_PER_OWNER && entry.tabs.size <= CHROME_MAX_TABS_PER_OWNER)
            (entry.profiles.keys + entry.tabs.keys).forEach(::boundedIdentifier)
        }
    }
    private fun checkCurrentBytes() {
        check(!closed)
        check(storage.read()?.let(::sha256) == observed) { "Local Chromium identity bytes changed; refusing restore" }
    }
    private fun commit(next: Payload) {
        validate(next)
        val body = json.encodeToString(next)
        val bytes = json.encodeToString(Envelope(payload = body, sha256 = sha256(body.toByteArray()))).toByteArray()
        require(bytes.size <= MAX_REGISTRY_BYTES)
        storage.replace(observed, bytes)
        check(storage.read()?.contentEquals(bytes) == true) { "Local Chromium identities were not durably verified" }
        observed = sha256(bytes); payload = next
    }
    @Synchronized override fun close() { if (!closed) { closed = true; storage.close() } }
}

/** One namespace per browser profile; enforced in both the durable registry and RAM-only Private mappings. */
internal const val CHROME_MAX_PROFILES_PER_OWNER = 256
/** One namespace per browser tab; enforced in both the durable registry and RAM-only Private mappings. */
internal const val CHROME_MAX_TABS_PER_OWNER = 4096

private const val MAX_REGISTRY_BYTES = 2 * 1024 * 1024
internal fun boundedIdentifier(value: String) {
    require(value.isNotEmpty() && Charsets.UTF_8.newEncoder().canEncode(value) && value.toByteArray().size <= 1024 && value.none { it.code < 0x20 || it.code == 0x7f })
}
internal fun canonicalUUID(value: String) {
    require(UUID.fromString(value).toString() == value && value != "00000000-0000-0000-0000-000000000000")
}
private fun sha256(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }

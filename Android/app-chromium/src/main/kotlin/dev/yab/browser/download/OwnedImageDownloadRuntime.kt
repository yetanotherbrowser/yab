package dev.yab.browser.download

import androidx.annotation.MainThread
import dev.yab.android.PageDownloadOwner
import dev.yab.android.PageDownloadSource
import com.cefrium.CefriumBrowser
import java.io.FilterInputStream
import java.io.InputStream
import java.util.IdentityHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Actual pre-stream authority only. It never pretends that file bytes or progress have arrived. */
data class OwnedImagePreparation(val token: String, val owner: PageDownloadOwner)

/**
 * Cefrium has no session interception, so Gecko's WebResponse capture cannot be ported:
 * the forked CefriumEngine arms this runtime from a long-press context-menu image event
 * via offer(), and the bytes come from an OkHttp GET carrying that page profile's cookies.
 * All public methods are called on the main thread; the supplied scope belongs to the retained browser owner.
 */
@MainThread
class OwnedImageDownloadRuntime(private val scope: CoroutineScope) {
    private class Registration(val document: () -> String?, val url: () -> String?, val interactive: () -> Boolean)
    private class Transfer(val session: CefriumBrowser, val registration: Registration, val token: String,
        val image: String, val owner: PageDownloadOwner, val ownerCurrent: () -> Boolean,
        val deliver: (PageDownloadSource) -> Unit, val failure: (String) -> Unit, val deadline: Long) {
        var watch: Job? = null
        var input: InputStream? = null
        var delivered = false
    }
    private val sessions = IdentityHashMap<CefriumBrowser, Registration>()
    private var active: Transfer? = null
    private val mutablePreparation = MutableStateFlow<OwnedImagePreparation?>(null)
    val preparation = mutablePreparation.asStateFlow()
    private var closed = false
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    val ready: Boolean get() = !closed
    val hasActiveAttempt: Boolean get() = active != null

    /** Register a live CefriumBrowser so saveImage can validate its document against the owner. */
    fun offer(session: CefriumBrowser, imageUrl: String, document: String, interactive: Boolean) {
        if (closed) return
        sessions[session] = Registration({ document }, { imageUrl }, { interactive })
    }

    fun canSaveImage(session: CefriumBrowser): Boolean = ready && active == null && sessions[session]?.let {
        it.interactive() && it.document() != null
    } == true

    /** Must be called only after consuming the matching native context-menu image event and capturing its owner. */
    fun saveImage(session: CefriumBrowser, image: String, owner: PageDownloadOwner, ownerCurrent: () -> Boolean,
        deliver: (PageDownloadSource) -> Unit, failure: (String) -> Unit): Boolean {
        if (closed || active != null || !image.startsWith("http")) return false
        val registration = sessions[session] ?: return false
        if (!registration.interactive() || !ownerCurrent() || registration.document() != owner.document) return false
        val transfer = Transfer(session, registration, java.util.UUID.randomUUID().toString(), image, owner, ownerCurrent,
            deliver, failure, android.os.SystemClock.elapsedRealtime() + 30_000)
        active = transfer
        mutablePreparation.value = OwnedImagePreparation(transfer.token, owner)
        fetch(transfer)
        transfer.watch = scope.launch(Dispatchers.Main.immediate) {
            while (active === transfer) {
                if (!current(transfer)) { fail(transfer, null); return@launch }
                delay(100)
            }
        }
        return true
    }

    /** Navigation, account/epoch changes, Private lock, source hiding and engine disposal revoke pending authority. */
    fun invalidate(session: CefriumBrowser) {
        active?.takeIf { it.session === session }?.let { fail(it, null) }
        sessions.remove(session)
    }
    fun cancel(token: String? = null) { active?.takeIf { token == null || it.token == token }?.let { fail(it, null) } }
    fun preparationCurrent(value: OwnedImagePreparation): Boolean = active?.let {
        it.token == value.token && it.owner === value.owner && !it.delivered && current(it)
    } == true
    fun revalidate() { active?.takeUnless(::current)?.let { fail(it, null) } }
    fun close() {
        if (closed) return
        closed = true; active?.let { fail(it, null) }
        sessions.clear()
        client.dispatcher.executorService.shutdown()
    }

    private fun current(transfer: Transfer): Boolean = !closed && active === transfer &&
        sessions[transfer.session] === transfer.registration &&
        transfer.registration.document() == transfer.owner.document &&
        android.os.SystemClock.elapsedRealtime() < transfer.deadline &&
        runCatching(transfer.ownerCurrent).getOrDefault(false)

    private fun fetch(transfer: Transfer) {
        scope.launch(Dispatchers.Main.immediate) {
            try {
                val cookies = cookies(transfer.image, transfer.session)
                val response = withTimeout(30_000) {
                    withContext(Dispatchers.IO) { client.newCall(Request.Builder().url(transfer.image)
                        .header("Cookie", cookies)
                        .header("Accept", "image/*,*/*;q=0.8").build()).execute() }
                }
                try {
                    val mime = response.header("Content-Type")
                    if (!response.isSuccessful || response.body == null || !mime.isImage()) {
                        response.close()
                        fail(transfer, "This image couldn't be saved from this page. Open the image and try there."); return@launch
                    }
                    if (!current(transfer)) { response.close(); fail(transfer, null); return@launch }
                    val raw = requireNotNull(response.body).byteStream()
                    // OkHttp owns the connection until close; finishing the transfer on close mirrors Gecko's handed-off original channel.
                    val input = object : FilterInputStream(raw) {
                        override fun close() {
                            if (!transfer.delivered) return
                            transfer.delivered = false
                            try { super.close() } finally { finish(transfer) }
                        }
                    }
                    transfer.input = input
                    mutablePreparation.value = null
                    transfer.delivered = true
                    transfer.deliver(OkImageSource(transfer.image, mime, response.header("Content-Length")?.toLongOrNull(), input, response))
                } catch (cancelled: CancellationException) { response.close(); throw cancelled }
                catch (_: Exception) { response.close(); fail(transfer, "The image couldn't be saved from this page. Open the image and try there.") }
            } catch (cancelled: CancellationException) { fail(transfer, null); throw cancelled }
            catch (_: Exception) { fail(transfer, "The image request timed out. Try again from this page.") }
        }
    }

    /** Cefrium reads cookies per browser asynchronously; empty string when none apply. */
    private suspend fun cookies(url: String, session: CefriumBrowser): String {
        val list = withTimeout(5_000) { kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { continuation.resumeWith(Result.success(emptyList<CefriumBrowser.Cookie>())) }
            runCatching { session.getCookies(url) { cookies -> continuation.resumeWith(Result.success(cookies)) } }
                .onFailure { continuation.resumeWith(Result.success(emptyList())) }
        } }
        return list.joinToString("; ") { it.name + "=" + it.value }
    }

    private fun finish(transfer: Transfer) {
        if (active !== transfer) return
        active = null; transfer.watch?.cancel(); transfer.input = null
        mutablePreparation.value = null
    }
    private fun fail(transfer: Transfer, message: String?) {
        if (active !== transfer) return
        val show = message != null && current(transfer)
        val input = transfer.input; finish(transfer)
        closeInput(input)
        if (show) transfer.failure(requireNotNull(message))
    }
    private fun closeInput(input: InputStream?) { if (input != null) scope.launch(NonCancellable + Dispatchers.IO) { runCatching { input.close() } } }
    private fun String?.isImage(): Boolean = this != null && substringBefore(';').trim().startsWith("image/")
}

/** Backs the controller's transfer with the still-open OkHttp response body. */
private class OkImageSource(override val uri: String, private val contentType: String?, private val length: Long?,
    private val stream: InputStream, private val response: Response) : PageDownloadSource {
    override val mime: String? get() = contentType
    override val size: Long? get() = length?.takeIf { it >= 0 }
    override fun stream(timeoutMillis: Long): InputStream? = stream
    override fun close() { runCatching { response.close() } }
}

private suspend fun <T> withContextCompat(block: () -> T): T = kotlinx.coroutines.withContext(Dispatchers.IO) { block() }
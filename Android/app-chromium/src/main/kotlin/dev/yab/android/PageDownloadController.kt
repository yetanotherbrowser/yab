package dev.yab.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import androidx.core.content.ContextCompat
import java.io.File
import java.io.InputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A native session lease, never reconstructed from a URL after a transfer starts. */
data class PageDownloadOwner(val tab: String, val profile: String, val document: String, val privateOrigin: Boolean,
    val account: String?, val accountEpoch: Long, val native: Any)
enum class PageDownloadPhase { TRANSFERRING, READY, FAILED, CANCELLING, CANCELLED, EXPORTING, SAVED, SHARED }
data class PageDownloadState(val id: String? = null, val owner: PageDownloadOwner? = null, val phase: PageDownloadPhase = PageDownloadPhase.CANCELLED,
    val name: String = "", val mime: String = "application/octet-stream", val received: Long = 0, val total: Long? = null, val error: String? = null,
    val pictureUri: String? = null, val exportKind: PageDownloadExportKind? = null)
enum class PageDownloadExportKind { SAVE, SHARE, PICTURES }
data class PageDownloadExport(val token: String, val download: String, val file: File, val name: String, val mime: String, val kind: PageDownloadExportKind)

/** The retained ViewModel owns this transfer. Only the original engine response supplies bytes. */
class PageDownloadController internal constructor(
    private val folder: File,
    private val scope: CoroutineScope,
    private val sourceAlive: (PageDownloadOwner) -> Boolean,
    private val main: CoroutineDispatcher,
    private val io: CoroutineDispatcher,
    private val app: Context? = null,
    private val expireShared: (File, Long) -> Unit = PageDownloadFiles::expire,
    private val pictures: PictureLibrary? = app?.let(::MediaStorePictureLibrary),
) {
    constructor(context: Context, scope: CoroutineScope, sourceAlive: (PageDownloadOwner) -> Boolean) : this(
        File(context.applicationContext.cacheDir, "shared"), scope, sourceAlive, Dispatchers.Main.immediate, Dispatchers.IO, context.applicationContext)
    val id = UUID.randomUUID().toString()
    private val mutable = MutableStateFlow(PageDownloadState())
    val state = mutable.asStateFlow()
    private class Transfer(val id: String, val owner: PageDownloadOwner, val response: PageDownloadSource, val input: InputStream, val directory: File) {
        var job: Job? = null
        var failure: String? = null
        var file: File? = null
        var sharedInput = false
    }
    private var active: Transfer? = null
    private var monitor: Job? = null
    private var exporting: PageDownloadExport? = null
    private var exportJob: Job? = null
    private var closed = false
    init {
        PageDownloadRegistry.put(this)
        if (app != null) scope.launch(io) { PageDownloadFiles.prune(folder) }
    }

    fun start(response: PageDownloadSource, owner: PageDownloadOwner): Boolean {
        // The dialog must show TRANSFERRING immediately; Cefrium's source only
        // yields a stream after its own copy is complete, so resolution moves to
        // the first read on the io writer and never blocks the calling thread.
        return startTransfer(response, DeferredDownloadInput { response.stream(60_000) }, owner,
            DownloadNames.filename(response.uri, null), mimeType(response), lengthOf(response))
    }

    private fun mimeType(response: PageDownloadSource): String = response.mime?.substringBefore(';')
        ?.takeIf { it.matches(Regex("[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+")) } ?: "application/octet-stream"

    // Cefrium download items carry a decoded length; absent or encoded bodies report none.
    private fun lengthOf(response: PageDownloadSource): Long? = response.size?.takeIf { it >= 0 }

    /** Resolves the backing stream on first read, keeping the 60s timeout semantics off main. */
    private class DeferredDownloadInput(private val resolve: () -> InputStream?) : InputStream() {
        private var input: InputStream? = null
        private var failed = false
        private fun ready(): InputStream {
            if (failed) throw java.io.IOException("Download stream unavailable")
            return input ?: runCatching { resolve() }.getOrNull()?.also { input = it }
                ?: throw java.io.IOException("Download stream unavailable").also { failed = true }
        }
        override fun read(): Int = ready().read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = ready().read(b, off, len)
        override fun close() { input?.let { runCatching { it.close() } } }
    }

    internal fun startTransfer(response: PageDownloadSource, input: InputStream, owner: PageDownloadOwner, name: String, mime: String, total: Long?): Boolean {
        if (closed || mutable.value.phase !in setOf(PageDownloadPhase.CANCELLED, PageDownloadPhase.SAVED, PageDownloadPhase.SHARED) || !alive(owner)) {
            scope.launch(NonCancellable + io) { runCatching { response.close() } }; return false
        }
        val token = UUID.randomUUID().toString()
        val entry = Transfer(token, owner, response, input, File(folder, "download-$token"))
        active = entry
        PageDownloadFiles.hold(entry.directory)
        val safeName = DownloadNames.sanitize(name)
        mutable.value = PageDownloadState(token, owner, PageDownloadPhase.TRANSFERRING, safeName, mime, total = total)
        if (!startService(entry.id)) entry.failure = "Android could not keep this download running. Try again from the webpage."
        val work = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (entry.failure != null) error("Foreground transfer unavailable")
                val target = withContext(io) {
                    folder.mkdirs()
                    check(entry.directory.mkdir()) { "Download storage is unavailable" }
                    val destination = File(entry.directory, safeName)
                    check(destination.parentFile?.canonicalFile == entry.directory.canonicalFile) { "Invalid download name" }
                    var received = 0L
                    var publishedAt = 0L
                    input.use { source -> destination.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            ensureActive()
                            if (!withContext(main) { active === entry && alive(owner) }) throw CancellationException("Download source changed")
                            val count = source.read(buffer)
                            if (count < 0) break
                            require(entry.directory.usableSpace > count + 16L * 1024 * 1024) { "Storage is full" }
                            received += count
                            require(total == null || received <= total) { "Unexpected response length" }
                            output.write(buffer, 0, count)
                            val now = System.nanoTime()
                            if (now - publishedAt > 100_000_000) {
                                publishedAt = now
                                withContext(main) { if (active === entry) mutable.value = mutable.value.copy(received = received) }
                            }
                        }
                        require(total == null || received == total) { "Incomplete response" }
                        output.fd.sync()
                    } }
                    destination
                }
                ensureActive()
                if (active !== entry || !alive(owner)) throw CancellationException("Download source changed")
                entry.file = target
                mutable.value = mutable.value.copy(phase = PageDownloadPhase.READY, received = target.length())
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (mutable.value.phase != PageDownloadPhase.CANCELLING) entry.failure = entry.failure ?: "The file didn't finish. Try again from this webpage." }
        }
        entry.job = work
        work.invokeOnCompletion { failure ->
            // The writer has ended before any unlink. This also covers cancellation before start.
            scope.launch(NonCancellable + io) {
                runCatching { response.close() }
                val keep = withContext(main) { entry.sharedInput || active === entry && mutable.value.phase in setOf(PageDownloadPhase.READY, PageDownloadPhase.EXPORTING, PageDownloadPhase.SHARED) }
                if (!keep) PageDownloadFiles.remove(entry.directory)
                withContext(main) {
                    if (active === entry && mutable.value.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.CANCELLING)) {
                        mutable.value = mutable.value.copy(phase = if (entry.failure != null || failure != null && failure !is CancellationException) PageDownloadPhase.FAILED else PageDownloadPhase.CANCELLED,
                            error = entry.failure)
                    }
                    if (active === entry) stopService()
                }
            }
        }
        work.start()
        watch(entry)
        return true
    }
    private fun watch(entry: Transfer) {
        monitor?.cancel()
        monitor = scope.launch {
            while (active === entry && mutable.value.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED)) {
                revalidate(); delay(250)
            }
        }
    }

    fun isSourceAlive(): Boolean = state.value.owner?.let(::alive) == true
    private fun alive(owner: PageDownloadOwner): Boolean = !closed && runCatching { sourceAlive(owner) }.getOrDefault(false)
    fun revalidate() { active?.takeIf { mutable.value.phase != PageDownloadPhase.EXPORTING && !alive(it.owner) }?.let { cancel(it.id) } }
    fun cancel(download: String? = state.value.id) = stop(download, null)
    private fun stop(download: String?, failure: String?) {
        val entry = active?.takeIf { it.id == download } ?: return
        if (mutable.value.phase in setOf(PageDownloadPhase.SHARED, PageDownloadPhase.SAVED, PageDownloadPhase.CANCELLED, PageDownloadPhase.CANCELLING)) return
        entry.failure = failure
        exporting = null
        val writer = exportJob
        writer?.cancel(); exportJob = null
        mutable.value = mutable.value.copy(phase = PageDownloadPhase.CANCELLING)
        monitor?.cancel(); monitor = null
        scope.launch(NonCancellable + io) { runCatching { entry.response.close() } }
        if (entry.job?.isCompleted == false) entry.job?.cancel()
        else scope.launch(NonCancellable + io) {
            writer?.join()
            PageDownloadFiles.remove(entry.directory)
            withContext(main) { if (active === entry) { mutable.value = mutable.value.copy(phase = if (entry.failure != null) PageDownloadPhase.FAILED else PageDownloadPhase.CANCELLED, error = entry.failure); stopService() } }
        }
    }
    internal fun serviceFailed() {
        val entry = active?.takeIf { state.value.phase == PageDownloadPhase.TRANSFERRING } ?: return
        stop(entry.id, "Android could not keep this download running. Try again from the webpage.")
    }
    fun beginExport(download: String, kind: PageDownloadExportKind): PageDownloadExport? {
        val entry = active?.takeIf { it.id == download && alive(it.owner) && state.value.phase == PageDownloadPhase.READY } ?: return null
        if (kind == PageDownloadExportKind.PICTURES && (pictures == null || !PicturesExport.supports(state.value.mime))) return null
        val file = entry.file?.takeIf(File::isFile) ?: return null
        return PageDownloadExport(UUID.randomUUID().toString(), download, file, state.value.name, state.value.mime, kind).also {
            exporting = it; mutable.value = mutable.value.copy(phase = PageDownloadPhase.EXPORTING, exportKind = kind)
        }
    }
    fun currentExport(token: String, kind: PageDownloadExportKind): PageDownloadExport? = exporting?.takeIf { it.token == token && it.kind == kind }
    fun savePictures(download: String): Boolean {
        val library = pictures ?: return false
        val entry = active?.takeIf { it.id == download } ?: return false
        val export = beginExport(download, PageDownloadExportKind.PICTURES) ?: return false
        // Retain row ownership even if cancellation discards a withContext result on return to UI.
        val pending = AtomicReference<PendingPicture?>(null)
        exportJob = scope.launch {
            var committed = false
            var failure: Exception? = null
            var cleanupFailed = false
            try {
                val uri = withContext(io) {
                    PicturesExport.save(export.file, export.name, export.mime, library, onPending = pending::set) {
                        withContext(main) { exporting?.token == export.token && active === entry &&
                            state.value.phase == PageDownloadPhase.EXPORTING && alive(entry.owner) }
                    }
                }
                if (exporting?.token == export.token && active === entry && alive(entry.owner)) {
                    exporting = null
                    mutable.value = mutable.value.copy(phase = PageDownloadPhase.SAVED, pictureUri = uri, error = null, exportKind = null)
                    committed = true
                    runCatching { app?.let { android.widget.Toast.makeText(it, "Image saved to Pictures", android.widget.Toast.LENGTH_SHORT).show() } }
                    withContext(NonCancellable + io) { PageDownloadFiles.remove(export.file.parentFile!!) }
                } else throw CancellationException("Image source changed before final UI commit")
            } catch (error: Exception) {
                failure = error
            } finally {
                if (!committed) cleanupFailed = withContext(NonCancellable + io) { runCatching { pending.get()?.remove() }.isFailure }
                if (cleanupFailed) entry.failure = "Pictures could not remove an incomplete image."
            }
            if (!committed) {
                if (exporting?.token == export.token) {
                    exporting = null
                    if (cleanupFailed) {
                        mutable.value = mutable.value.copy(phase = PageDownloadPhase.FAILED, error = "Pictures could not remove an incomplete image.")
                    } else if (alive(entry.owner)) {
                        mutable.value = mutable.value.copy(phase = PageDownloadPhase.READY, exportKind = null, error = "The image could not be saved to Pictures. You can try again or use Save.")
                        watch(entry)
                    } else cancel(entry.id)
                }
            }
            if (failure is CancellationException) throw failure
        }
        return true
    }
    fun exportCancelled(token: String) {
        val export = exporting?.takeIf { it.token == token } ?: return
        if (state.value.id != export.download || state.value.phase != PageDownloadPhase.EXPORTING) return
        exporting = null
        if (isSourceAlive()) { mutable.value = mutable.value.copy(phase = PageDownloadPhase.READY); active?.let(::watch) }
        else cancel()
    }
    fun saveTo(token: String, uri: Uri?) {
        val export = currentExport(token, PageDownloadExportKind.SAVE) ?: return
        if (uri == null) { exportCancelled(token); return }
        val context = app ?: return
        exportJob = scope.launch {
            try {
                withContext(io) { export.file.inputStream().use { source ->
                    requireNotNull(context.contentResolver.openOutputStream(uri, "w")).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) { ensureActive(); val count = source.read(buffer); if (count < 0) break; output.write(buffer, 0, count) }
                        output.flush()
                    }
                } }
                if (exporting?.token == token) {
                    exporting = null
                    mutable.value = mutable.value.copy(phase = PageDownloadPhase.SAVED)
                    withContext(io) { PageDownloadFiles.remove(export.file.parentFile!!) }
                }
            } catch (error: Exception) {
                withContext(NonCancellable + io) { runCatching { DocumentsContract.deleteDocument(context.contentResolver, uri) } }
                if (exporting?.token == token) { exporting = null; mutable.value = mutable.value.copy(phase = PageDownloadPhase.FAILED, error = "The file could not be saved. Try again from this webpage.") }
                if (error is CancellationException) throw error
            }
        }
    }
    fun shareLaunched(token: String) {
        val export = currentExport(token, PageDownloadExportKind.SHARE) ?: return
        val entry = active?.takeIf { it.id == export.download && state.value.phase == PageDownloadPhase.EXPORTING } ?: return
        // The external share owns this input even after another response becomes active.
        entry.sharedInput = true
        mutable.value = mutable.value.copy(phase = PageDownloadPhase.SHARED)
        // FileProvider has no recipient-completion callback. Keep a bounded read lease.
        expireShared(export.file.parentFile!!, 60 * 60 * 1000L)
    }
    fun shareReturned(token: String) {
        val export = currentExport(token, PageDownloadExportKind.SHARE) ?: return
        exporting = null
        expireShared(export.file.parentFile!!, 5 * 60 * 1000L)
    }
    fun close() {
        if (closed) return
        if (state.value.phase != PageDownloadPhase.SHARED) cancel()
        closed = true; monitor?.cancel(); PageDownloadRegistry.remove(id); stopService()
    }
    private fun startService(download: String): Boolean {
        val context = app ?: return true
        return try { ContextCompat.startForegroundService(context, Intent(context, PageDownloadService::class.java)
            .putExtra(PageDownloadService.CONTROLLER, id).putExtra(PageDownloadService.DOWNLOAD, download)); true }
        catch (_: RuntimeException) { false }
    }
    private fun stopService() { app?.stopService(Intent(app, PageDownloadService::class.java)) }
}

internal object PageDownloadRegistry {
    private val controllers = ConcurrentHashMap<String, WeakReference<PageDownloadController>>()
    fun put(controller: PageDownloadController) { controllers[controller.id] = WeakReference(controller) }
    fun get(id: String?) = id?.let { controllers[it]?.get() }
    fun remove(id: String) { controllers.remove(id) }
    private val settled = setOf(PageDownloadPhase.CANCELLED, PageDownloadPhase.FAILED, PageDownloadPhase.SAVED, PageDownloadPhase.SHARED)
    /** A transfer, or a finished file still waiting for the person's Save or Share. */
    private fun inUse() = controllers.values.any { reference -> reference.get()?.state?.value?.phase?.let { it !in settled } == true }
    private val updateHold = dev.yab.update.UpdateHold { if (inUse()) "download" else null }
    init { dev.yab.update.UpdateHolds.add(updateHold) }
}

internal object PageDownloadFiles {
    private val held = ConcurrentHashMap.newKeySet<String>()
    private val name = Regex("download-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    fun hold(directory: File) { held.add(directory.absolutePath) }
    fun remove(directory: File) {
        if (name.matches(directory.name) && directory.parentFile?.name == "shared" && !java.nio.file.Files.isSymbolicLink(directory.toPath())) {
            directory.deleteRecursively(); held.remove(directory.absolutePath)
        }
    }
    fun expire(directory: File, after: Long) {
        Handler(Looper.getMainLooper()).postDelayed({ Thread({ remove(directory) }, "Yab download cleanup").start() }, after)
    }
    fun prune(folder: File) {
        folder.listFiles()?.filter { name.matches(it.name) && it.absolutePath !in held && System.currentTimeMillis() - it.lastModified() >= 60 * 60 * 1000L }?.forEach(::remove)
    }
}
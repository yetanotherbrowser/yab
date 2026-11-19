package dev.yab.browser.media

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.io.Closeable
import java.lang.ref.WeakReference
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** No page URLs or artwork cross into the service. Private state is never serialized. */
class PageMediaController(context: Context, pages: StateFlow<List<PageMediaState>>, scope: CoroutineScope,
    private val command: (MediaOwner, MediaCommand) -> Boolean,
    private val focus: (Int, (MediaOwner) -> Boolean) -> Unit,
    private val message: (String) -> Unit) : Closeable {
    private val app = context.applicationContext
    val id: String = UUID.randomUUID().toString()
    private val audio = app.getSystemService(AudioManager::class.java)
    private val policy = MutableStateFlow(true)
    private var visible = false
    private var closed = false
    private var serviceForeground = false
    private var serviceRequested = false
    private var heldFocus = false
    private var interrupted = false
    private var focusRegained = false
    private var source = emptyList<PageMediaState>()
    private val mutable = MutableStateFlow<PageMediaState?>(null)
    val state: StateFlow<PageMediaState?> = mutable
    private val holdForeground = MutableStateFlow(false)
    internal val interruptedPlayback: StateFlow<Boolean> = holdForeground
    private val handler = Handler(Looper.getMainLooper())
    // Cefrium pushes no native media-session events, so this controller never
    // touches the engine directly: the pages flow is Yab-side bookkeeping kept
    // by the engine, and the focus callback contract uses AudioManager's
    // AUDIOFOCUS_* constants instead of Gecko's MediaSession focus codes.
    private val focusRequest: AudioFocusRequest by lazy { AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
        .setOnAudioFocusChangeListener({ change ->
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> {
                    heldFocus = true
                    focusRegained = true
                    if (interrupted && source.any { mayResume(it.owner) }) {
                        focus(AudioManager.AUDIOFOCUS_GAIN, ::mayResume)
                        handler.postDelayed({
                            if (interrupted && source.none { it.playing }) {
                                interrupted = false; holdForeground.value = false
                                audio.abandonAudioFocusRequest(focusRequest); heldFocus = false
                            }
                        }, 5000)
                    } else {
                        interrupted = false; holdForeground.value = false
                        if (source.none { it.playing }) { audio.abandonAudioFocusRequest(focusRequest); heldFocus = false }
                    }
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    interrupted = true; focusRegained = false; holdForeground.value = true
                    focus(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) { true }
                }
                AudioManager.AUDIOFOCUS_LOSS -> {
                    heldFocus = false; interrupted = false; focusRegained = false; holdForeground.value = false
                    focus(AudioManager.AUDIOFOCUS_LOSS) { true }
                }
            }
        }, Handler(Looper.getMainLooper())).build() }
    private val observer: Job

    init {
        PageMediaRegistry.register(this)
        observer = scope.launch { combine(pages, policy) { all, _ -> all }.collect { all ->
            source = all
            val eligible = all.filter { it.mayExport(policy.value) }
            val previous = mutable.value?.owner
            val selected = eligible.filter { it.playing }.maxByOrNull { it.playedAtElapsed }
                ?: eligible.firstOrNull { it.owner == previous }
            mutable.value = selected?.systemMetadata()
            if (selected?.playing == true && !serviceRequested) {
                if (visible) startService()
                else if (!serviceForeground) {
                    command(selected.owner, MediaCommand(MediaAction.PAUSE))
                    message("Open Yab to start background playback")
                }
            }
            val audible = all.any { it.playing }
            if (audible && interrupted && heldFocus && focusRegained) { interrupted = false; holdForeground.value = false }
            if (audible && !heldFocus && !interrupted) {
                // Chromium's own AudioFocusDelegate owns the page's audio focus
                // here; a second GAIN request from this side makes the delegate
                // take a loss and suspend the page (seen on device). Chromium
                // pauses the page on real focus loss, the poll flips playing
                // back off, so bookkeeping alone is enough.
                heldFocus = true
            } else if (!audible && heldFocus && !interrupted) {
                heldFocus = false
            }
            if (selected == null) { serviceRequested = false; app.stopService(serviceIntent()) }
        } }
    }

    fun setPolicy(lockPrivate: Boolean) { policy.value = lockPrivate }
    fun setVisible(value: Boolean) { visible = value }
    private fun mayResume(owner: MediaOwner): Boolean = !owner.privateOrigin || !policy.value || visible
    private fun serviceIntent() = Intent(app, PageMediaService::class.java).putExtra(PageMediaService.CONTROLLER, id)
    private fun startService(commandOwner: MediaOwner? = null, action: MediaCommand? = null): Boolean {
        if (closed) return false
        return try {
            val intent = serviceIntent()
            if (commandOwner != null && action != null) PageMediaService.addCommand(intent, commandOwner, action)
            ContextCompat.startForegroundService(app, intent)
            serviceRequested = true
            true
        } catch (_: RuntimeException) {
            serviceRequested = false
            commandOwner?.let { command(it, MediaCommand(MediaAction.PAUSE)) }
            message("Open Yab to resume playback")
            false
        }
    }

    /** System transport commands must match the current native page and private policy. */
    fun transport(owner: MediaOwner, action: MediaCommand): Boolean {
        if (closed || mutable.value?.owner != owner || source.none { it.owner == owner && it.mayExport(policy.value) }) return false
        return startService(owner, action)
    }
    internal fun deliver(owner: MediaOwner, action: MediaCommand): Boolean = !closed && mutable.value?.owner == owner &&
        source.any { it.owner == owner && it.mayExport(policy.value) } && command(owner, action)
    internal fun foregroundService(active: Boolean) { serviceForeground = active; serviceRequested = active }
    internal fun serviceFailed() {
        serviceForeground = false; serviceRequested = false
        mutable.value?.let { command(it.owner, MediaCommand(MediaAction.PAUSE)) }
        message("Open Yab to resume playback")
    }
    internal fun serviceGone() { serviceForeground = false; serviceRequested = false }
    fun stopOwner(owner: MediaOwner) { if (source.any { it.owner == owner }) command(owner, MediaCommand(MediaAction.PAUSE)) }
    override fun close() {
        if (closed) return
        closed = true; observer.cancel(); mutable.value = null
        handler.removeCallbacksAndMessages(null); holdForeground.value = false
        audio.abandonAudioFocusRequest(focusRequest); heldFocus = false
        PageMediaRegistry.remove(id)
        app.stopService(serviceIntent())
    }
}

internal object PageMediaRegistry {
    private val values = mutableMapOf<String, WeakReference<PageMediaController>>()
    fun register(controller: PageMediaController) { values[controller.id] = WeakReference(controller) }
    fun get(id: String?): PageMediaController? = id?.let { values[it]?.get() }
    fun remove(id: String) { values.remove(id) }
}
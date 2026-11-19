package dev.yab.browser.engine

import com.cefrium.CefriumBrowser
import dev.yab.browser.media.MediaAction
import dev.yab.browser.media.MediaCommand
import dev.yab.browser.media.MediaOwner
import dev.yab.browser.media.PageMediaState
import dev.yab.browser.model.WebsiteProfile
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Cefrium exposes isPlayingAudio()/audio muting but no MediaSession metadata,
 * actions or position events. The state list carries the playing flag from the
 * browser plus pause/resume/mute commands, so PiP eligibility and the lock
 * Private rule keep working; titles and transport actions stay empty because
 * no honest source exists for them.
 */
internal class CefriumPageMedia(private val changed: (String, Boolean) -> Unit) {
    private data class Live(val browser: CefriumBrowser, val current: () -> Boolean,
        val document: () -> String, var state: PageMediaState)
    private val live = linkedMapOf<String, Live>()
    private val mutable = MutableStateFlow<List<PageMediaState>>(emptyList())
    val state: StateFlow<List<PageMediaState>> = mutable.asStateFlow()

    fun attach(id: String, browser: CefriumBrowser, profile: WebsiteProfile, document: () -> String,
               current: () -> Boolean) {
        val identity = UUID.randomUUID().toString()
        val owner = MediaOwner(id, document(), identity, profile.isPrivate)
        live[id] = Live(browser, current, document,
            PageMediaState(owner, actions = setOf(MediaAction.PLAY, MediaAction.PAUSE, MediaAction.STOP)))
        publish()
    }

    fun refresh(id: String) {
        val item = live[id] ?: return
        if (!item.current()) { forget(id); return }
        val playing = runCatching { item.browser.isPlayingAudio() }.getOrDefault(false)
        if (item.state.playing != playing) { item.state = item.state.copy(playing = playing); publish(); changed(id, playing) }
    }

    /** Cefrium has no playback event; the engine polls this for every live entry. */
    fun refreshAll() { live.keys.toList().forEach(::refresh) }

    fun playing(id: String): Boolean = live[id]?.state?.playing == true
    fun forget(id: String) { live.remove(id)?.let { changed(id, false) }; publish() }
    fun close() { live.keys.toList().forEach(::forget) }

    fun pausePrivate() {
        live.values.forEach { item ->
            if (!item.state.owner.privateOrigin) return@forEach
            if (item.state.playing) { item.state = item.state.copy(playing = false); changed(item.state.owner.tabId, false) }
        }
        publish()
    }

    fun command(owner: MediaOwner, command: MediaCommand, allowed: (MediaOwner) -> Boolean): Boolean {
        val item = live[owner.tabId]?.takeIf { it.state.owner == owner } ?: return false
        if (!allowed(owner)) return false
        val browser = item.browser
        when (command.action) {
            MediaAction.PLAY -> runCatching { browser.resumeMedia() }
            MediaAction.PAUSE -> runCatching { browser.suspendMedia() }
            MediaAction.STOP -> runCatching { browser.stopAllMedia() }
            else -> return false
        }
        return true
    }

    /** Loss focus pauses every allowed owner's audio; a gain is a no-op (pages resume themselves).
     * Codes match Gecko's MediaSession focus constants (0 gain, 1 transient loss,
     * 2 permanent loss), which the shared PageMediaController passes through. */
    fun focusChange(change: Int, allowed: (MediaOwner) -> Boolean) {
        live.values.map { it.state.owner }.filter(allowed).forEach { owner ->
            when (change) {
                1 /* transient loss */, 2 /* permanent loss */ ->
                    command(owner, MediaCommand(MediaAction.PAUSE), allowed)
                else -> Unit
            }
        }
    }

    private fun publish() { mutable.value = live.values.map { it.state } }
}

package dev.yab.browser.engine

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.cefrium.Cefrium
import com.cefrium.CefriumBrowser
import com.cefrium.CefriumChromeClient
import com.cefrium.CefriumContextMenu
import com.cefrium.CefriumDownloadClient
import com.cefrium.CefriumLoadError
import com.cefrium.CefriumNavigationClient
import com.cefrium.CefriumNavigationRequest
import com.cefrium.CefriumProfile
import com.cefrium.CefriumRendererTerminationStatus
import com.cefrium.CefriumSslError
import dev.yab.android.PageDownloadSource
import dev.yab.browser.download.OwnedImageDownloadRuntime
import dev.yab.browser.icons.AndroidSiteIcons
import dev.yab.browser.media.MediaCommand
import dev.yab.browser.media.MediaOwner
import dev.yab.browser.model.BrowserBackItem
import dev.yab.browser.model.BrowserEngine
import dev.yab.browser.model.BrowserFindDirection
import dev.yab.browser.model.BrowserFindQuery
import dev.yab.browser.model.BrowserFindResult
import dev.yab.browser.model.BrowserPageMemento
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.EnginePageState
import dev.yab.browser.model.FieldAnswerTarget
import dev.yab.browser.model.HistorySwipeDirection
import dev.yab.browser.model.NativeHistorySwipeTarget
import dev.yab.browser.model.ReaderPreferences
import dev.yab.browser.model.WebsiteProfile
import dev.yab.nativefeatures.PageTranslationPort
import dev.yab.nativefeatures.TranslationDocument
import dev.yab.nativefeatures.TranslationOwner
import dev.yab.nativefeatures.TranslationPage
import dev.yab.nativefeatures.TranslationSegment
import dev.yab.shield.ShieldController
import dev.yab.shield.ShieldPolicy
import dev.yab.shield.ShieldPopupRequest
import dev.yab.shield.shieldUrlHost
import dev.yab.update.UpdateHold
import dev.yab.update.UpdateHolds
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.lang.ref.WeakReference
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/**
 * One browser per tab on Cefrium profiles, behind the same BrowserEngine seam and
 * wiring surface as the Gecko edition. Where Cefrium lacks a capability the seam
 * default is returned with an honest comment, never a fake result.
 */
class CefriumEngine(private val context: Context, private val maxLiveSessions: Int = 6) : BrowserEngine {

    /** createWithSurface needs the live Activity; MA hands it over in onCreate and detach drops it. */
    var surfaceActivity: Activity? = null

    private data class Entry(
        val browser: CefriumBrowser,
        val profile: WebsiteProfile,
        var tab: BrowserTab,
        var page: EnginePageState = EnginePageState(),
        var document: String = UUID.randomUUID().toString(),
        var savedState: ByteArray? = null,
        var alive: Boolean = true,
        var permissions: Int = 0,
        var fullScreen: Boolean = false,
        var mediaAccessGranted: Boolean = false,
        var domPlaying: Boolean = false,
        var darkenApplied: Boolean? = null,
        var desktopApplied: Boolean? = null,
        val backHistory: NativeBackHistory = NativeBackHistory(),
        val recovery: NativePageRecovery = NativePageRecovery(),
        var recoveryOverride: NativePageRecovery? = null,
        var lastUsed: Long = SystemClock.uptimeMillis(),
        val thumbnailSession: String = UUID.randomUUID().toString(),
        var lastAnswer: String? = null,
    ) {
        val effectiveRecovery: NativePageRecovery get() = recoveryOverride ?: recovery
    }

    private data class Suspended(val tab: BrowserTab, val profile: WebsiteProfile, val state: ByteArray?, val page: EnginePageState)

    private val pages = linkedMapOf<String, Entry>()
    private val suspended = mutableMapOf<String, Suspended>()
    private val closedMemories = linkedSetOf<CefriumClosedMemory>()
    /** MA's AndroidView tag holds a tab id; the engine keeps only the live View per tab. */
    private val views = mutableMapOf<String, WeakReference<android.view.View>>()
    private var managedTabs = emptyMap<String, WebsiteProfile>()
    private val handler = Handler(Looper.getMainLooper())
    private val stateWriter = Executors.newSingleThreadExecutor()
    private val captureScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val snapshots = TabThumbnails(disk = PublicThumbnailDiskCache(File(context.cacheDir, "public-tab-pictures")),
        io = { stateWriter.execute(it) }, main = { handler.post(it) })
    private val nativeFrameBudget = NativeFrameBudget<Bitmap>()
    private val pendingStateDeletes = ConcurrentHashMap.newKeySet<String>()
    /** Live Cefrium transfers by download id, so onDownloadUpdated can reach the waiting source. */
    private val activeDownloads = ConcurrentHashMap<Int, CefriumDownloadItemSource>()
    private val clearingProfiles = ConcurrentHashMap.newKeySet<String>()
    private val dataClear = Mutex()
    private val pageMedia = CefriumPageMedia { id, playing ->
        pages[id]?.let { entry ->
            update(id, entry) { it.copy(playingMedia = playing || entry.domPlaying, safeToClear = it.safeToClear && !playing) }
        }
    }
    private var readerPreferences = ReaderPreferences()
    private var trackingProtection = true
    private var disposed = false
    private var foreground = true
    private var ownershipEpoch = 0L
    private var privateMediaPaused = false
    private var privateMediaRequiresLock = true
    private var visibleTabs: Set<String>? = null
    private var recoveryTabs: Set<String>? = null
    private var sessionBudget = maxLiveSessions.coerceAtLeast(1)
    private var pinnedSessions = PinnedSessions()
    private var ownedFind: FindOwner? = null
    private var ownedContextMenu: OwnedContextMenu? = null
    private var imageDownloads: OwnedImageDownloadRuntime? = null
    /** Tab ids with a save posted but not yet serialized; dispose flushes them. */
    private val pendingSaveTabs = mutableSetOf<String>()

    private data class FindOwner(val tab: String, val entry: Entry, val document: String,
        val query: BrowserFindQuery, val answer: (BrowserFindResult?) -> Unit)

    private data class OwnedContextMenu(val request: PageContextMenu, val entry: Entry, val document: String)

    /** Duck's controller owns the store; the engine re-applies its policy at every bind point. */
    var shield: ShieldController? = null

    /** A live external Activity result can only be delivered to the document that opened it. */
    class ExternalActivityOwner internal constructor(internal val tab: String, internal val session: CefriumBrowser,
        internal val document: String, val profileId: String, val isPrivate: Boolean)

    /** Wiring assigns; engine calls. Same shapes as the Gecko edition minus engine types. */
    var onState: (String, EnginePageState) -> Unit = { _, _ -> }
    var onNewTab: (String, String) -> Unit = { _, _ -> }
    var onError: (String) -> Unit = {}
    var onDownload: (PageDownloadSource) -> Unit = { it.close() }
    var onFullscreen: (Boolean) -> Unit = {}
    var onSessionCreated: (CefriumBrowser) -> Unit = {}
    var onSessionActivated: (CefriumBrowser) -> Unit = {}
    var onSessionClosed: (CefriumBrowser) -> Unit = {}
    var createWindow: (String, String) -> CefriumBrowser? = { _, _ -> null }
    var onCloseWindow: (String, String, WebsiteProfile) -> Boolean = { _, _, _ -> false }
    /** Synchronous answer like duck's ShieldController.checkPopup; the VM binds it directly. */
    var popupPolicy: (ShieldPopupRequest) -> Boolean = { true }
    var selected: String? = null
        private set
    var prompts: NativePagePrompts? = null
    var permissionRequest: (Array<String>, (Boolean) -> Unit) -> Unit = { _, answer -> answer(false) }
    /** The icon store stays an internal type; the function form keeps the setter callable from MA. */
    fun setSiteIcons(icons: Any?) { siteIcons = icons as? dev.yab.browser.icons.AndroidSiteIcons }
    internal var siteIcons: dev.yab.browser.icons.AndroidSiteIcons? = null
    val siteSettings = SiteSettingsStore(File(context.filesDir, "site-settings.json")) { stateWriter.execute(it) }
    private val mutableConnections = MutableStateFlow<Map<String, SiteConnection>>(emptyMap())
    val connections = mutableConnections.asStateFlow()
    private val mutableContextMenu = MutableStateFlow<PageContextMenu?>(null)
    val contextMenu = mutableContextMenu.asStateFlow()
    private val mutableLinkPreview = MutableStateFlow<CefriumLinkPreview?>(null)
    /** The peek sheet collects this; CefriumLinkPreview carries its own page state. */
    val linkPreview: StateFlow<CefriumLinkPreview?> get() = mutableLinkPreview.asStateFlow()
    val thumbnails get() = snapshots.state
    val media get() = pageMedia.state
    val liveSessionCount get() = pages.values.count { it.alive }
    fun hasLiveSession(id: String) = pages[id]?.alive == true

    /** Installing an update ends this process: a form, a Private page or playing media keeps it waiting. */
    private val updateHold = UpdateHold {
        pages.entries.firstNotNullOfOrNull { (id, entry) -> when {
            entry.profile.isPrivate -> "private"
            entry.page.hasFormEdits -> "form"
            entry.domPlaying || pageMedia.playing(id) -> "media"
            else -> null
        } }
    }

    data class PageText(val title: String, val url: String, val text: String, val geometry: PageViewportGeometry? = null)

    init {
        UpdateHolds.add(updateHold)
        // Cefrium has no media playback event, so the playing flag only flips
        // when something polls isPlayingAudio(); without this poll the shared
        // PageMediaController never learns audio is running and no media
        // notification appears. handler.removeCallbacksAndMessages in dispose
        // stops the loop.
        val poll = object : Runnable {
            override fun run() {
                if (disposed) return
                runCatching { pageMedia.refreshAll() }
                handler.postDelayed(this, 1000)
            }
        }
        handler.postDelayed(poll, 1000)
    }

    // ---------------------------------------------------------------- sessions

    /** WebsiteProfile -> CefriumProfile: private -> incognito, named -> get(id), shared default -> getDefault(). */
    private fun profileOf(profile: WebsiteProfile): CefriumProfile = when {
        profile.isPrivate -> CefriumProfile.incognito()
        profile.id == BrowserSpace.SHARED_PROFILE -> CefriumProfile.getDefault()
        else -> CefriumProfile.get(profile.id)
    }

    fun session(tab: BrowserTab, profile: WebsiteProfile, load: Boolean = true, open: Boolean = true): CefriumBrowser {
        check(!disposed) { "The browser engine is closed" }
        val previous = pages[tab.id]
        if (previous != null && previous.profile != profile) close(tab.id)
        pages[tab.id]?.let { it.tab = tab; return it.browser }
        val sleeping = suspended.remove(tab.id)?.takeIf { it.profile == profile }
        // createWithSurface keeps the engine owning the browser and populates
        // getSurfaceContainer() (FrameLayout) for MA's AndroidView; the bare
        // factory would leave the tab with nothing to compose. Background
        // browsers (link preview) keep the bare factory: no surface needed.
        val activity = surfaceActivity ?: error("Cefrium tabs need the Activity to host their surface")
        val browser = CefriumBrowser.createWithSurface(activity, profileOf(profile))
        val entry = Entry(browser, profile, tab, savedState = sleeping?.state,
            page = EnginePageState(url = tab.url, title = tab.title))
        pages[tab.id] = entry
        attachHandlers(tab.id, entry)
        applyShield(entry, tab.url)
        if (siteSettings.site(webHost(tab.url), profile.isPrivate).desktop) applyDesktop(entry, tab.url)
        onSessionCreated(browser)
        if (open) {
            if (sleeping?.state != null) runCatching { browser.restoreNavigationState(sleeping.state) }
                .onFailure { runCatching { browser.loadUrl(entry.tab.url) } }
            else if (!tab.isBlank) runCatching { browser.loadUrl(entry.tab.url) }
        }
        refreshActiveSessions()
        trimSessions()
        return browser
    }

    private fun attachHandlers(id: String, entry: Entry) {
        val browser = entry.browser
        browser.setNavigationClient(object : CefriumNavigationClient {
            override fun onLoadStart(ignored: CefriumBrowser, url: String) {
                if (pages[id] !== entry || !entry.alive) return
                dismissContextMenu(id)
                mutableConnections.value = mutableConnections.value - id
                entry.document = UUID.randomUUID().toString()
                entry.domPlaying = false
                // The media entry belongs to the browser, not the document; every
                // navigation drops and re-attaches it so the poll keeps watching
                // this tab (refresh() forgets entries whose current() dies with
                // the page).
                pageMedia.forget(id)
                pageMedia.attach(id, entry.browser, entry.profile, document = { entry.document.takeIf { pages[id] === entry && entry.alive } ?: "" },
                    current = { pages[id] === entry && entry.alive })
                entry.backHistory.invalidate()
                applyZoom(id, entry)
                applyShield(entry, url)
                update(id, entry) { it.copy(url = url, secure = false, loading = true, progress = 0f,
                    error = null, hasFormEdits = false, playingMedia = false, safeToClear = false,
                    frameUncertain = true, scrollY = 0f, userScrollY = 0f) }
            }
            override fun onUrlChanged(ignored: CefriumBrowser, url: String) {
                if (pages[id] !== entry || !entry.alive) return
                // A committed document drops the injected darken style; clearing
                // the memo makes the next update re-inject it exactly once.
                entry.darkenApplied = null
                applyDesktop(entry, url)
                applyShield(entry, url)
                publishConnections(id, entry, url)
                update(id, entry) { it.copy(url = url, error = null) }
            }
            override fun onLoadingStateChanged(ignored: CefriumBrowser, isLoading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
                if (pages[id] !== entry || !entry.alive) return
                captureBackHistory(id, entry)
                applyZoom(id, entry)
                update(id, entry) { it.copy(loading = isLoading, canGoBack = canGoBack, canGoForward = canGoForward,
                    progress = if (!isLoading) 1f else it.progress) }
                if (!isLoading) { entry.darkenApplied = null; entry.savedState = runCatching { browser.serializeNavigationState() }.getOrNull(); trimSessions() }
            }
            override fun onProgressChanged(ignored: CefriumBrowser, progress: Int) {
                update(id, entry) { it.copy(progress = progress / 100f) }
            }
            override fun onLoadError(ignored: CefriumBrowser, error: CefriumLoadError) {
                update(id, entry) { it.copy(loading = false, error = "This page couldn't load. Check the connection and try again.") }
            }
            override fun onRenderProcessTerminated(ignored: CefriumBrowser, status: CefriumRendererTerminationStatus, errorCode: Int) {
                pageLost(id, entry)
            }
            override fun onSslError(ignored: CefriumBrowser, error: CefriumSslError, callback: CefriumBrowser.SslErrorCallback) {
                // The shared UI has no exception flow; a failed cert never becomes "secure".
                callback.cancel()
                if (pages[id] === entry) update(id, entry) { it.copy(secure = false) }
            }
        })
        browser.setChromeClient(object : CefriumChromeClient {
            override fun onTitleChanged(ignored: CefriumBrowser, title: String) {
                update(id, entry) { it.copy(title = title) }
            }
            override fun onFullscreenChanged(ignored: CefriumBrowser, fullscreen: Boolean) {
                entry.fullScreen = fullscreen
                if (owns(browser)) onFullscreen(fullscreen)
            }
            override fun onMediaAccessChanged(ignored: CefriumBrowser, microphone: Boolean, camera: Boolean) {
                if (pages[id] !== entry || !entry.alive) return
                val recording = microphone || camera
                if (recording) entry.mediaAccessGranted = true
                update(id, entry) { it.copy(capturingMedia = recording, safeToClear = it.safeToClear && !recording) }
            }
            override fun onContextMenu(ignored: CefriumBrowser, menu: CefriumContextMenu): Boolean {
                if (!ownsInteractive(browser)) return true
                val link = safeContextUrl(menu.linkUrl)
                val image = if (menu.mediaType == CefriumContextMenu.MediaType.IMAGE) safeContextUrl(menu.sourceUrl) else null
                if (link == null && image == null) return true
                image?.let { offerImageDownload(entry, it) }
                val request = PageContextMenu(UUID.randomUUID().toString(), id, entry.profile.id, entry.profile.isPrivate,
                    link, image, (menu.selectionText ?: link ?: image.orEmpty()).take(512))
                ownedContextMenu = OwnedContextMenu(request, entry, entry.document)
                mutableContextMenu.value = request
                return true
            }
        })
        browser.setOnFindResultListener { active, total ->
            val owner = ownedFind ?: return@setOnFindResultListener
            if (owner.tab != id || pages[id] !== owner.entry || owner.entry.document != owner.document ||
                !owner.entry.alive || !owns(owner.entry.browser)) { clearFind(id); return@setOnFindResultListener }
            // Cefrium reports no wrapped flag; a wrap is indistinguishable from a plain match here.
            owner.answer(BrowserFindResult(active.coerceAtLeast(0), total.coerceAtLeast(-1), wrapped = false))
        }
        browser.setPopupHandler(object : CefriumBrowser.PopupHandler {
            override fun onOpenPopup(url: String, userGesture: Boolean): Boolean = false
            override fun onCreateWindow(opener: CefriumBrowser, url: String, userGesture: Boolean): Boolean {
                if (!owns(opener)) return false
                if (decidePopup(id, entry, url) && pages[id] === entry && entry.alive) {
                    val child = createWindow(id, url) ?: return true
                    child.setOnCloseWindowListener(ownerBrowser = opener) { closed ->
                        if (closed) onCloseWindow(id, id, entry.profile)
                    }
                }
                return true
            }
        })
        // Cefrium hands the decision point only a file path: onBeforeDownload's
        // callback allows into Cefrium's own download manager (allow(path)), it
        // exposes no byte stream. The engine streams the chosen destination file
        // into Yab's controller once Cefrium has produced it; sizes and mime come
        // from the DownloadItem (getTotalBytes/getMimeType, AAR-verified).
        browser.setDownloadClient(object : CefriumDownloadClient {
            override fun onBeforeDownload(origin: CefriumBrowser, item: CefriumBrowser.DownloadItem,
                callback: CefriumBrowser.BeforeDownloadCallback) {
                if (!ownsInteractive(origin)) { callback.cancel(); return }
                val rawName = item.suggestedName
                val name = if (rawName.isNullOrBlank()) "download" else rawName.filter { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }
                val target = File(context.cacheDir, "engine-downloads").resolve("${item.id}-$name")
                val started = CefriumManagedDownload(target, origin, item, ::ownsInteractive)
                if (!started.open()) { callback.cancel(); return }
                callback.allow(target.absolutePath)
                val source = CefriumDownloadItemSource(item, target, started)
                activeDownloads[item.id] = source
                try { onDownload(source) } catch (_: Exception) {
                    activeDownloads.remove(item.id)
                    runCatching { source.close() }; item.cancel()
                }
            }
            // The onBeforeDownload item is an immutable snapshot; the SDK hands
            // each update as a fresh DownloadItem here, so completion has to be
            // routed to the waiting source by id (AAR-verified onDownloadUpdated).
            override fun onDownloadUpdated(origin: CefriumBrowser, item: CefriumBrowser.DownloadItem) {
                val source = activeDownloads[item.id] ?: return
                when {
                    item.isComplete -> source.completed()
                    item.isCanceled || item.isInterrupted -> source.failed()
                    else -> return
                }
                activeDownloads.remove(item.id)
            }
        })
        // The SDK's isPlayingAudio() reads an internal CefriumMediaSession that
        // maybeCreateMediaSession() only builds when setMediaSessionEnabled(true)
        // ran (AAR-verified); without this the poll's playing flag can never flip.
        runCatching { browser.setMediaSessionEnabled(true) }
        pageMedia.attach(id, browser, entry.profile, document = { entry.document.takeIf { pages[id] === entry && entry.alive } ?: "" },
            current = { pages[id] === entry && entry.alive })
        // frog's prompts owns every dialog handler; one instance registers itself
        // once per browser and its ownership gate routes each prompt kind.
        prompts?.register(browser)
        attachImageDownload(id, entry)
    }

    private fun CefriumBrowser.setOnCloseWindowListener(ownerBrowser: CefriumBrowser, closed: (Boolean) -> Unit) {
        setPopupHandler(object : CefriumBrowser.PopupHandler {
            override fun onOpenPopup(url: String, userGesture: Boolean): Boolean = false
            override fun onCloseWindow(window: CefriumBrowser) { if (window === this@setOnCloseWindowListener) closed(true) }
        })
    }

    private fun decidePopup(id: String, entry: Entry, url: String): Boolean {
        if (!popupCurrent(id, entry)) return false
        return try {
            popupPolicy(ShieldPopupRequest(UUID.randomUUID().toString(), url, entry.page.url ?: entry.tab.url, entry.profile.isPrivate))
        } catch (_: Exception) { false } && popupCurrent(id, entry)
    }

    private fun popupCurrent(id: String, entry: Entry): Boolean =
        !disposed && pages[id] === entry && entry.alive && owns(entry.browser) &&
            visibleTabs?.contains(id) != false

    private fun publishConnections(id: String, entry: Entry, url: String?) {
        // Cefrium has no positive security event; secure is inferred from the https scheme
        // only, cert summary UI stays unavailable (sdk-mapping gap 7).
        val current = url ?: entry.page.url ?: return
        val secure = runCatching { URI(current).scheme?.lowercase() == "https" }.getOrDefault(false)
        mutableConnections.value = mutableConnections.value +
            (id to SiteConnection(secure = secure, exception = false, host = webHost(current).orEmpty(),
                origin = runCatching { URI(current).let { "${it.scheme}://${it.host}" } }.getOrNull(),
                securityMode = if (secure) 1 else 0, mixedActive = 0, mixedPassive = 0,
                subject = null, issuer = null, validFrom = null, validUntil = null, sha256 = null))
        update(id, entry) { it.copy(secure = secure) }
    }

    // ---------------------------------------------------------------- page state

    private fun update(id: String, owner: Entry? = null, change: (EnginePageState) -> EnginePageState) {
        val entry = pages[id] ?: return
        if (owner != null && owner !== entry) return
        entry.page = change(entry.page)
        revalidateLinkPreview()
        onState(id, entry.page)
    }

    private fun pageLost(id: String, entry: Entry) {
        if (pages[id] !== entry || !entry.alive) return
        dismissContextMenu(id)
        mutableConnections.value = mutableConnections.value - id
        pageMedia.forget(id)
        entry.alive = false
        onSessionClosed(entry.browser)
        if (entry.fullScreen && selected == id) { entry.fullScreen = false; onFullscreen(false) }
        entry.effectiveRecovery.stopped(away = !foreground || !shownForRecovery(id))
        update(id, entry) { it.copy(loading = false, safeToClear = false, capturingMedia = false,
            error = if (entry.effectiveRecovery.phase == NativePageRecovery.Phase.FAILED) "The page stopped. Reload to restore it." else null) }
        scheduleRecovery(id, entry)
    }

    private fun shownForRecovery(id: String): Boolean =
        (visibleTabs?.contains(id) ?: (selected == id)) && (recoveryTabs?.contains(id) ?: true)

    private fun recoveryEligible(id: String, entry: Entry) = !disposed && foreground && pages[id] === entry &&
        !entry.alive && entry.profile.id !in clearingProfiles && !(entry.profile.isPrivate && privateMediaPaused) &&
        shownForRecovery(id)

    private fun scheduleRecovery(id: String, entry: Entry) {
        val ticket = entry.effectiveRecovery.queue(recoveryEligible(id, entry)) ?: return
        val epoch = ownershipEpoch
        handler.post {
            if (disposed || pages[id] !== entry || ownershipEpoch != epoch) return@post
            if (!entry.effectiveRecovery.begin(ticket, recoveryEligible(id, entry))) return@post
            runCatching { recover(id) }.onFailure {
                val current = pages[id]
                if (current?.effectiveRecovery === entry.effectiveRecovery) {
                    current.effectiveRecovery.failed()
                    update(id, current) { it.copy(loading = false, error = "The page stopped. Reload to restore it.") }
                }
            }
        }
    }

    private fun recover(id: String): CefriumBrowser? {
        val old = pages[id] ?: return null
        if (old.alive) return old.browser
        val epoch = ownershipEpoch
        pages.remove(id)
        val tab = old.tab
        suspended[id] = Suspended(tab, old.profile, old.savedState, old.page)
        val result = session(tab, old.profile, load = false)
        val replacement = pages[id]?.takeIf { it.browser === result && it.profile == old.profile } ?: return null
        if (disposed || ownershipEpoch != epoch) return null
        replacement.recoveryOverride = old.effectiveRecovery
        update(id, replacement) { page -> page.copy(loading = true, error = null) }
        loadPage(id, replacement)
        if (selected == id) onSessionActivated(result)
        refreshActiveSessions()
        return result
    }

    private fun loadPage(id: String, entry: Entry) {
        val saved = entry.savedState
        if (saved != null) runCatching { entry.browser.restoreNavigationState(saved) }
            .onFailure { runCatching { entry.browser.loadUrl(entry.tab.url) } }
        else if (!entry.tab.isBlank) runCatching { entry.browser.loadUrl(entry.tab.url) }
        refreshActiveSessions()
    }

    private fun captureBackHistory(id: String, entry: Entry) {
        if (pages[id] !== entry || !entry.alive) return
        val entries = runCatching { entry.browser.getNavigationEntries() }.getOrNull() ?: return
        val copied = entries.map { NativeBackHistory.Page(it.url.orEmpty(), it.title.orEmpty()) }
        val current = entries.indexOfFirst { it.current }.takeIf { it >= 0 } ?: entries.lastIndex
        if (entry.backHistory.capture(copied, current)) update(id, entry) {
            it.copy(canGoBack = current > 0, canGoForward = current in 0 until copied.lastIndex)
        }
    }

    // ---------------------------------------------------------------- ownership / lifecycle

    fun tabId(browser: CefriumBrowser): String? = pages.entries.firstOrNull { it.value.browser === browser }?.key
    fun owns(browser: CefriumBrowser): Boolean = foreground && selected?.let { id -> pages[id]?.let {
        it.browser === browser && it.alive && !(it.profile.isPrivate && privateMediaPaused)
    } } == true
    fun ownsInteractive(browser: CefriumBrowser): Boolean =
        mutableLinkPreview.value == null && owns(browser) && (visibleTabs?.contains(tabId(browser)) != false)
    val interactiveSelected: String? get() = selected?.takeIf { id -> pages[id]?.browser?.let(::ownsInteractive) == true }

    fun captureExternalActivityOwner(): ExternalActivityOwner? = selected?.let { id ->
        pages[id]?.takeIf { owns(it.browser) }?.let {
            ExternalActivityOwner(id, it.browser, it.document, it.profile.id, it.profile.isPrivate)
        }
    }
    fun ownsExternalActivity(owner: ExternalActivityOwner): Boolean = selected == owner.tab &&
        pages[owner.tab]?.let { it.browser === owner.session && it.document == owner.document && owns(it.browser) } == true
    fun externalActivityAlive(owner: ExternalActivityOwner, allowLockedPrivate: Boolean = false): Boolean =
        !disposed && selected == owner.tab && pages[owner.tab]?.let {
            it.alive && it.browser === owner.session && it.document == owner.document &&
                (!it.profile.isPrivate || !privateMediaPaused || allowLockedPrivate)
        } == true

    fun exitFullscreen() { selected?.let { pages[it]?.browser?.let { browser -> runCatching { browser.exitFullscreen() } } } }

    fun background() {
        foreground = false
        ownedFind?.tab?.let(::clearFind)
        dismissContextMenu()
        prompts?.dismissForBackground()
        refreshActiveSessions()
        saveSessions()
    }

    fun foreground() {
        val returned = !foreground
        foreground = true
        sessionBudget = maxLiveSessions.coerceAtLeast(1)
        if (returned) pages.toList().filterNot { it.second.alive }.forEach { (id, entry) ->
            entry.effectiveRecovery.foregrounded()
            if (entry.effectiveRecovery.phase == NativePageRecovery.Phase.DEFERRED) update(id, entry) { it.copy(error = null) }
        }
        closedMemories.filter { it.expired() }.toList().forEach(::releaseUndo)
        refreshActiveSessions()
    }

    fun setVisibleTabs(ids: Set<String>, recoveryIds: Set<String> = ids) {
        visibleTabs = ids.toSet()
        recoveryTabs = recoveryIds.intersect(ids)
        ownedFind?.takeIf { it.tab !in ids }?.tab?.let(::clearFind)
        if (ownedContextMenu?.request?.tab !in ids) dismissContextMenu()
        refreshActiveSessions()
        trimSessions()
    }

    /** The seam toggle mirrors setTrackingProtection(false) in the VM; shield applyToBrowser owns the real per-browser state. */
    fun setTrackingProtection(enabled: Boolean) {
        trackingProtection = enabled
        pages.values.filter { it.alive }.forEach { applyShield(it) }
    }

    fun setPrivateMediaLock(enabled: Boolean) {
        privateMediaRequiresLock = enabled
        if (!enabled) privateMediaPaused = false
        if (enabled && !foreground) pausePrivateMedia() else refreshActiveSessions()
    }

    fun mediaCommand(owner: MediaOwner, command: MediaCommand): Boolean =
        pageMedia.command(owner, command) { !it.privateOrigin || !privateMediaPaused }

    fun mediaFocus(change: Int, allowed: (MediaOwner) -> Boolean) =
        pageMedia.focusChange(change) { owner -> allowed(owner) && (!owner.privateOrigin || !privateMediaPaused) }

    fun mediaBounds(owner: MediaOwner): android.graphics.Rect? = pages[owner.tabId]?.takeIf {
        it.document == owner.document && it.alive
    }?.let { views[owner.tabId]?.get() }?.let { view -> android.graphics.Rect().takeIf { view.getGlobalVisibleRect(it) } }

    fun bindView(tabId: String, view: android.view.View) {
        if (disposed) return
        views[tabId] = WeakReference(view)
        pages[tabId]?.let { entry ->
            view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                runCatching { entry.browser.setSize(view.width.coerceAtLeast(1), view.height.coerceAtLeast(1)) }
            }
            runCatching { entry.browser.setSize(view.width.coerceAtLeast(1), view.height.coerceAtLeast(1)) }
            scheduleCapture(tabId, entry)
        }
    }

    fun unbindView(tabId: String, view: android.view.View) {
        if (views[tabId]?.get() === view) views.remove(tabId)
    }

    internal fun setHistorySwipeConsumer(consumer: HistorySwipeConsumer?) {
        // Cefrium exposes no gesture-time history preview surface; the consumer is
        // accepted and never fed, the UI falls back to its non-preview swipe path.
        historySwipeConsumer = consumer
    }
    private var historySwipeConsumer: HistorySwipeConsumer? = null

    fun releaseViews() {
        views.clear()
        visibleTabs = emptySet()
        recoveryTabs = emptySet()
        refreshActiveSessions()
    }

    fun onTrimMemory(level: Int) {
        sessionBudget = when {
            level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> 2
            level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> 3
            else -> maxLiveSessions.coerceAtLeast(1)
        }
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) snapshots.clear()
        nativeFrameBudget.revokeAll()
        trimSessions()
    }

    private fun refreshActiveSessions() {
        pages.forEach { (id, entry) ->
            if (entry.alive) runCatching {
                entry.browser.setPageVisible(foreground && !(entry.profile.isPrivate && privateMediaPaused) &&
                    (visibleTabs?.contains(id) ?: (selected == id)))
            }
        }
        pages.filterValues { !it.alive }.toList().forEach { (id, entry) -> scheduleRecovery(id, entry) }
    }

    /** MA binds each live surface via bindView, so eviction only needs these runtime conditions. */
    private fun safeToEvict(id: String, entry: Entry): Boolean = entry.alive && selected != id &&
        visibleTabs?.contains(id) != true &&
        !entry.page.loading && !entry.fullScreen && entry.permissions == 0 && !entry.page.playingMedia &&
        !entry.page.capturingMedia && !entry.tab.hasDraft && !entry.tab.hasTask

    private fun trimSessions() {
        if (disposed || liveSessionCount <= sessionBudget) return
        val needed = liveSessionCount - sessionBudget
        pages.entries.filter { it.value.alive && safeToEvict(it.key, it.value) }
            .sortedBy { it.value.lastUsed }.take(needed).forEach { (id, entry) -> evict(id, entry) }
    }

    private fun evict(id: String, entry: Entry) {
        if (pages[id] !== entry || !safeToEvict(id, entry)) return
        entry.savedState = entry.savedState ?: runCatching { entry.browser.serializeNavigationState() }.getOrNull()
        dismissContextMenu(id)
        mutableConnections.value = mutableConnections.value - id
        suspended[id] = Suspended(entry.tab, entry.profile, entry.savedState, entry.page)
        pages.remove(id)
        views.remove(id)
        pageMedia.forget(id)
        entry.alive = false
        onSessionClosed(entry.browser)
        // The closed browser stays strongly held by the image runtime's session
        // map; drop its registration or every evicted tab leaks for the session.
        imageDownloads?.invalidate(entry.browser)
        runCatching { entry.browser.close() }
        trimSessions()
    }

    fun prepareWindow(tab: BrowserTab, profile: WebsiteProfile, select: Boolean): CefriumBrowser {
        if (select) {
            leaveFullscreen(tab.id)
            prompts?.dismiss()
            dismissContextMenu()
            selected = tab.id
        }
        val created = session(tab, profile, load = false, open = false)
        if (select) onSessionActivated(created)
        return created
    }

    private fun leaveFullscreen(next: String) {
        if (selected == next) return
        selected?.let { pages[it] }?.takeIf { it.fullScreen }?.let {
            it.fullScreen = false
            runCatching { it.browser.exitFullscreen() }
            onFullscreen(false)
        }
    }

    fun dispose() {
        background()
        prompts?.dismiss()
        pageMedia.close()
        closedMemories.toList().forEach(::releaseUndo)
        // background() posted saves that the callback wipe below would drop;
        // flush them while the sessions are still alive to serialize.
        val flushing = pages.values.filter { it.tab.id in pendingSaveTabs && it.alive }
        pendingSaveTabs.clear()
        flushing.forEach(::saveSession)
        val old = pages.values.toList()
        pages.clear()
        suspended.clear()
        views.clear()
        snapshots.close()
        disposed = true
        old.forEach {
            onSessionClosed(it.browser)
            if (it.alive) runCatching { it.browser.close() }
        }
        mutableConnections.value = emptyMap()
        siteSettings.forgetPrivate()
        captureScope.cancel()
        handler.removeCallbacksAndMessages(null)
        stateWriter.shutdown()
    }

    // ---------------------------------------------------------------- seam

    override fun activate(tab: BrowserTab, profile: WebsiteProfile) {
        // BrowserController only activates Private after its lock gate has opened.
        if (profile.isPrivate) privateMediaPaused = false
        leaveFullscreen(tab.id)
        if (selected != tab.id) prompts?.dismiss()
        if (selected != tab.id) dismissContextMenu()
        selected = tab.id
        pages[tab.id]?.takeIf { it.profile != profile }?.let { close(tab.id) }
        pages[tab.id]?.takeIf { !it.alive }?.let {
            scheduleRecovery(tab.id, it); refreshActiveSessions(); return
        }
        session(tab, profile).let { browser ->
            runCatching { browser.setPageVisible(true); browser.setFocus(true) }
            applyShield(pages[tab.id] ?: return)
            onSessionActivated(browser)
        }
        pages[tab.id]?.lastUsed = SystemClock.uptimeMillis()
        refreshActiveSessions()
        trimSessions()
    }

    override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {
        val stopped = pages[tab.id]?.takeIf { !it.alive }
        if (stopped != null && stopped.profile == profile) { recover(tab.id); pages[tab.id]?.let {
            runCatching { it.browser.loadUrl(url) }; entryOf(tab.id)?.let { e -> update(tab.id, e) { p -> p.copy(url = url, loading = true) } } }
            return
        }
        if (stopped != null) close(tab.id)
        pages[tab.id]?.effectiveRecovery?.reset()
        runCatching { session(tab, profile).loadUrl(url) }
    }

    private fun entryOf(id: String): Entry? = pages[id]

    override fun goBack(tabId: String) {
        val entry = pages[tabId] ?: return
        if (!entry.alive) recover(tabId)
        pages[tabId]?.takeIf { it.alive && runCatching { it.browser.canGoBack() }.getOrDefault(false) }
            ?.let { runCatching { it.browser.goBack() } }
    }

    override fun goForward(tabId: String) {
        val entry = pages[tabId] ?: return
        if (!entry.alive) recover(tabId)
        pages[tabId]?.takeIf { it.alive && runCatching { it.browser.canGoForward() }.getOrDefault(false) }
            ?.let { runCatching { it.browser.goForward() } }
    }

    override fun backItems(tabId: String): List<BrowserBackItem> {
        val entry = pages[tabId]?.takeIf { owns(it.browser) && !it.page.loading } ?: return emptyList()
        captureBackHistory(tabId, entry)
        return entry.backHistory.items(tabId, entry.document)
    }

    override fun goBackTo(tabId: String, item: BrowserBackItem): Boolean {
        val entry = pages[tabId]?.takeIf { owns(it.browser) && !it.page.loading } ?: return false
        val index = entry.backHistory.consume(tabId, entry.document, item) ?: return false
        prompts?.dismiss()
        update(tabId, entry) { it.copy(loading = true, safeToClear = false) }
        runCatching { entry.browser.goBackOrForward(-(index)) }
        return true
    }

    /** Native history swipe preview has no Cefrium counterpart; the UI falls back to its plain path. */
    override fun captureHistorySwipe(tabId: String, direction: HistorySwipeDirection): NativeHistorySwipeTarget? = null
    override fun historySwipeCurrent(target: NativeHistorySwipeTarget): Boolean = false

    /**
     * The UI only reaches commit through a captured target, so with no preview
     * surface the gesture degrades to the ordinary edge navigation the shared
     * UI already provides. A commit without a captured target would be a guess.
     */
    override fun commitHistorySwipe(target: NativeHistorySwipeTarget): Boolean = false

    override fun reload(tabId: String) {
        val entry = pages[tabId] ?: return
        entry.effectiveRecovery.reset()
        if (!entry.alive) recover(tabId) else runCatching { entry.browser.reload() }
    }

    override fun stop(tabId: String) {
        pages[tabId]?.let { runCatching { it.browser.stopLoading() } }
    }

    override fun close(tabId: String) {
        if (disposed) return
        dismissContextMenu(tabId)
        mutableConnections.value = mutableConnections.value - tabId
        val entry = pages.remove(tabId)
        entry?.effectiveRecovery?.invalidate()
        pageMedia.forget(tabId)
        val sleeping = suspended.remove(tabId)
        entry?.let {
            it.alive = false
            imageDownloads?.invalidate(it.browser)
            runCatching { it.browser.close() }
            onSessionClosed(it.browser)
        }
        if (entry?.profile?.isPrivate == false || sleeping?.profile?.isPrivate == false) {
            pendingStateDeletes.add(tabId)
            stateWriter.execute {
                val file = stateFile(tabId)
                android.util.AtomicFile(file).delete()
                if (!file.exists()) pendingStateDeletes.remove(tabId)
            }
        }
        views.remove(tabId)
        snapshots.remove(tabId)
        clearFind(tabId)
        if (mutableLinkPreview.value?.sourceTab == tabId) closeLinkPreview()
    }

    override fun reconcileTabs(spaces: List<BrowserSpace>) {
        if (disposed) return
        managedTabs = spaces.flatMap { space -> space.tabs.map { it.id to space.websiteProfile } }.toMap()
        pinnedSessions = PinnedSessions.of(spaces)
        val live = managedTabs.keys.toSet()
        pages.keys.filterNot { it in live }.forEach(::close)
        snapshots.reconcile(spaces.filterNot(BrowserSpace::isPrivate).flatMap { space ->
            space.tabs.filterNot(BrowserTab::isPrivate).map { ThumbnailOwner(it.id, space.websiteProfile.id, it.url) }
        })
    }

    override fun invalidateTransientOwnership() {
        ownershipEpoch++
        pages.values.forEach { it.effectiveRecovery.invalidate() }
        ownedFind?.tab?.let(::clearFind)
        closedMemories.toList().forEach(::releaseUndo)
        snapshots.invalidateOwnership()
        dismissContextMenu()
    }

    override fun captureForUndo(tab: BrowserTab, profile: WebsiteProfile): BrowserPageMemento? {
        if (disposed || profile.id in clearingProfiles) return null
        closedMemories.filter { it.expired() }.toList().forEach(::releaseUndo)
        val entry = pages[tab.id]?.takeIf { it.profile == profile && (it.page.url ?: it.tab.url) == tab.url }
        val sleeping = suspended[tab.id]?.takeIf { it.profile == profile && (it.page.url ?: it.tab.url) == tab.url }
        val state = entry?.savedState ?: entry?.let { runCatching { it.browser.serializeNavigationState() }.getOrNull() }
            ?: sleeping?.state ?: if (!profile.isPrivate) readState(tab.id, profile) else null ?: return null
        if ((state?.size ?: 0) > 8 * 1024 * 1024 || closedMemories.size >= 32 ||
            closedMemories.sumOf { it.state?.size?.toLong() ?: 0 } + (state?.size ?: 0) > 16L * 1024 * 1024) return null
        val memory = CefriumClosedMemory(this, tab, profile, state, SystemClock.elapsedRealtime() + 7_500)
        closedMemories += memory
        handler.postDelayed({ if (memory in closedMemories) releaseUndo(memory) }, 7_500)
        return memory
    }

    override suspend fun restoreForUndo(tab: BrowserTab, profile: WebsiteProfile, memory: BrowserPageMemento,
        isCurrent: () -> Boolean): Boolean {
        val saved = memory as? CefriumClosedMemory ?: return false
        if (saved.engine !== this || saved.released || saved !in closedMemories) return false
        withTimeoutOrNull(1_100) { saved.drained.await() }
        if (!isCurrent() || disposed || saved.released || saved !in closedMemories || saved.expired() ||
            saved.tab != tab || saved.profile != profile || profile.id in clearingProfiles ||
            pages.containsKey(tab.id) || suspended.containsKey(tab.id) || (profile.isPrivate && privateMediaPaused)) return false
        val state = saved.state ?: return false
        suspended[tab.id] = Suspended(tab, profile, state, EnginePageState(url = tab.url, title = tab.title))
        return true
    }

    override fun releaseUndo(memory: BrowserPageMemento) {
        val saved = memory as? CefriumClosedMemory ?: return
        if (saved.engine !== this || saved.released) return
        saved.released = true
        saved.state = null
        saved.drained.complete(Unit)
        closedMemories.remove(saved)
    }

    override fun endPrivateSession(profile: WebsiteProfile) {
        if (disposed || !profile.isPrivate || managedTabs.values.any { it == profile } ||
            pages.values.any { it.profile == profile } || suspended.values.any { it.profile == profile }) return
        closedMemories.filter { it.profile == profile }.toList().forEach(::releaseUndo)
    }

    override suspend fun clearWebsiteData(profileIds: Set<String>): Unit = dataClear.withLock {
        clearingProfiles.addAll(profileIds)
        try {
            withContext(Dispatchers.Main) {
                closedMemories.filter { it.profile.id in profileIds }.toList().forEach(::releaseUndo)
                snapshots.purgeProfiles(profileIds)
                for (profile in profileIds) {
                    pages.filterValues { it.profile.id == profile }.keys.toList().forEach(::close)
                    suspended.filterValues { it.profile.id == profile }.keys.toList().forEach(::close)
                    val native = if (profile == BrowserSpace.SHARED_PROFILE) CefriumProfile.getDefault()
                        else if (profile == BrowserSpace.PRIVATE_PROFILE) CefriumProfile.incognito()
                        else CefriumProfile.get(profile)
                    // Cefrium has no one-call profile wipe: cookies go first, then the
                    // site-data sweep, and a named profile loses its disk directory too.
                    runCatching { native.getCookieManager().removeAllCookies { } }
                    runCatching { native.getCookieManager().flush { } }
                    runCatching { native.listSiteData { origins -> origins.forEach { origin ->
                        runCatching { native.clearSiteData(origin.site, Runnable { }) } } } }
                    if (profile != BrowserSpace.SHARED_PROFILE && profile != BrowserSpace.PRIVATE_PROFILE)
                        runCatching { CefriumProfile.delete(profile) }
                }
                pages.values.forEach { runCatching { it.browser.clearCache() } }
            }
            val deleted = CompletableDeferred<Unit>()
            stateWriter.execute {
                try {
                    File(context.filesDir, "navigation").listFiles().orEmpty().filter { it.name.endsWith(".json") }.forEach { file ->
                        if (file.length() <= 8 * 1024 * 1024) {
                            val owner = runCatching { JSONObject(file.readText()).optString("profile") }.getOrNull()
                            if (owner in profileIds) android.util.AtomicFile(file).delete()
                        }
                    }
                    deleted.complete(Unit)
                } catch (error: Exception) { deleted.completeExceptionally(error) }
            }
            withContext(NonCancellable) { deleted.await() }
            siteIcons?.removeAll()
        } finally { clearingProfiles.removeAll(profileIds) }
    }

    override fun pausePrivateMedia() {
        privateMediaPaused = true
        dismissContextMenu()
        pages.values.filter { it.profile.isPrivate }.forEach { it.domPlaying = false }
        pageMedia.pausePrivate()
        pages.filterValues { it.profile.isPrivate && it.alive }.toList().forEach { (id, entry) ->
            runCatching {
                entry.browser.suspendMedia()
                entry.browser.stopAllMedia()
                entry.browser.setAudioMuted(true)
                entry.browser.setPageVisible(false)
            }
            if (entry.fullScreen) { runCatching { entry.browser.exitFullscreen() }; entry.fullScreen = false; if (selected == id) onFullscreen(false) }
        }
    }

    override fun setReader(tabId: String, enabled: Boolean): Boolean {
        // Cefrium hosts no reader mode and no extension bridge; the honest default is false.
        return false
    }

    override fun restyleReaders(preferences: ReaderPreferences) {
        readerPreferences = preferences.normalized()
        // No reader documents exist on Cefrium; nothing to restyle.
    }

    override fun find(tabId: String, query: BrowserFindQuery, direction: BrowserFindDirection,
        answer: (BrowserFindResult?) -> Unit): Boolean {
        val entry = pages[tabId]?.takeIf { owns(it.browser) && !it.page.loading && mutableLinkPreview.value == null } ?: return false
        if (query.text.length > 1024) return false
        val previous = ownedFind
        val repeat = direction != BrowserFindDirection.START && previous?.let {
            it.tab == tabId && it.entry === entry && it.document == entry.document && it.query == query
        } == true
        if (direction != BrowserFindDirection.START && !repeat) return false
        if (previous != null && previous.tab != tabId) clearFind(previous.tab)
        val owner = FindOwner(tabId, entry, entry.document, query, answer)
        ownedFind = owner
        if (query.text.isEmpty()) { answer(BrowserFindResult(0, 0)); return true }
        // find(search, forward, matchCase): wholeWord has no Cefrium knob and is dropped.
        runCatching { entry.browser.find(query.text, direction == BrowserFindDirection.PREVIOUS, query.matchCase, false) }
            .onFailure { clearFind(tabId) }
        return true
    }

    override fun clearFind(tabId: String) {
        val owner = ownedFind?.takeIf { it.tab == tabId } ?: return
        ownedFind = null
        pages[tabId]?.takeIf { it.alive }?.let { runCatching { it.browser.stopFinding(true) } }
        owner.answer(null)
    }

    override fun setZoom(tabId: String, factor: Double): Boolean {
        // Gecko applies zoom to any live page; chromium keeps the same liveness
        // gate so zoom works on backgrounded tabs of the same host too.
        val entry = pages[tabId]?.takeIf { it.alive } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        if (!factor.isFinite()) return false
        siteSettings.setZoom(host, entry.profile.isPrivate, factor)
        pages.forEach { (id, other) ->
            if (SiteSettingsStore.key(webHost(other.page.url ?: other.tab.url)) == SiteSettingsStore.key(host)) applyZoom(id, other)
        }
        return true
    }

    override fun setDesktop(tabId: String, enabled: Boolean): Boolean {
        val entry = pages[tabId]?.takeIf { it.alive && owns(it.browser) } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        siteSettings.setDesktop(host, entry.profile.isPrivate, enabled)
        applyDesktop(entry, entry.page.url ?: entry.tab.url)
        runCatching { entry.browser.reload() }
        return true
    }

    override suspend fun captureFieldAnswerTarget(tabId: String): FieldAnswerTarget? {
        // The answer-field port protocol rides Yab's WebExtension bridge, which
        // Cefrium cannot host; the feature degrades gracefully with null.
        return null
    }

    fun darken(tabId: String, enabled: Boolean) {
        val entry = pages[tabId] ?: return
        // Recomposition fires this on every browser.state emission during a load;
        // the injected script is idempotent but costs a renderer round trip.
        if (entry.darkenApplied == enabled) return
        entry.darkenApplied = enabled
        // Same injected CSS the Gecko bridge's page.js applies for "dark".
        val script = if (enabled) """
            (function(){document.getElementById('yab-dark-mode')?.remove();
            if(matchMedia('(prefers-color-scheme: dark)').matches)return;
            var s=document.createElement('style');s.id='yab-dark-mode';
            s.textContent="html{filter:invert(.9) hue-rotate(180deg);background:#eee}img,video,canvas,svg{filter:invert(1) hue-rotate(180deg)}";
            document.documentElement.append(s);})()
        """.trimIndent()
        else "(function(){document.getElementById('yab-dark-mode')?.remove();})()"
        runCatching { entry.browser.evaluateJavaScript(script) }
    }

    suspend fun readText(tab: BrowserTab, diagnostics: Boolean = false): PageText {
        val entry = pages[tab.id] ?: error("The page is not ready")
        val document = entry.document
        val url = entry.page.url ?: entry.tab.url
        if (!owns(entry.browser) || entry.page.loading) error("The page is not ready")
        return withContext(Dispatchers.Main.immediate) {
            val answer = CompletableDeferred<String?>()
            runCatching {
                entry.browser.evaluateJavaScript("(function(){return document.body ? document.body.innerText : ''})()",
                    android.webkit.ValueCallback { value -> answer.complete(value) })
            }.onFailure { answer.complete(null) }
            val text = withTimeoutOrNull(3_000) { answer.await() } ?: error("The page is not ready")
            check(pages[tab.id] === entry && entry.document == document && owns(entry.browser)) { "The page changed" }
            PageText(entry.page.title.orEmpty(), url, text ?: "")
        }
    }

    fun translationPort(): PageTranslationPort = object : PageTranslationPort {
        // Cefrium has no page bridge port; translation cannot collect a document
        // and every operation fails with the controller's own error handling.
        override val current get() = MutableStateFlow<TranslationPage?>(null).asStateFlow()
        override suspend fun collect(): TranslationDocument = error("This edition's engine has no page translation bridge")
        override fun isCurrent(owner: TranslationOwner): Boolean = false
        override suspend fun apply(owner: TranslationOwner, translated: List<TranslationSegment>) {}
        override suspend fun showOriginal(owner: TranslationOwner) {}
    }

    fun sitePreferences(tabId: String): SitePreferences =
        pages[tabId]?.let { siteSettings.site(webHost(it.page.url ?: it.tab.url), it.profile.isPrivate) } ?: SitePreferences()

    fun setSitePermission(tabId: String, kind: SitePermission, decision: SiteDecision?): Boolean {
        val entry = pages[tabId]?.takeIf { it.alive && owns(it.browser) } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        if (decision == null) siteSettings.forget(host, entry.profile.isPrivate, kind)
        else siteSettings.setDecision(host, entry.profile.isPrivate, kind, decision)
        return true
    }

    fun bindImageDownloads(runtime: OwnedImageDownloadRuntime) {
        check(imageDownloads == null || imageDownloads === runtime)
        imageDownloads = runtime
        pages.forEach { (id, entry) -> attachImageDownload(id, entry) }
    }

    private fun attachImageDownload(id: String, entry: Entry) {
        imageDownloads?.offer(entry.browser, "", "", true)
    }

    /** The long-press image url renews the runtime's registration at the moment the menu holds it. */
    private fun offerImageDownload(entry: Entry, image: String) {
        imageDownloads?.offer(entry.browser, image, entry.document, ownsInteractive(entry.browser))
    }

    private fun applyZoom(id: String, entry: Entry) {
        if (pages[id] !== entry || !entry.alive) return
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return
        val factor = siteSettings.site(host, entry.profile.isPrivate).zoom
        // Cefrium takes a zoom level: level = log(factor)/log(1.2), Chromium's convention.
        // Applied on every call like Gecko's bridge message: the live page must
        // see later zoom changes, not only the level captured at load time.
        val level = log(factor, 1.2)
        if (level.isFinite()) runCatching { entry.browser.setZoomLevel(level) }
    }

    private fun applyShield(entry: Entry, url: String? = entry.page.url ?: entry.tab.url) {
        // Cefrium downloads whole files into its own manager; per-site policy must
        // reach every live browser at the moments it can change: creation, url change,
        // activation and the seam toggle. No caller of the shield means EasyList alone.
        val controller = shield ?: return
        runCatching { ShieldController.applyToBrowser(entry.browser, controller.policies.state.value, shieldUrlHost(url)) }
    }

    private fun applyDesktop(entry: Entry, url: String?) {
        val desktop = siteSettings.site(webHost(url), entry.profile.isPrivate).desktop
        if (entry.desktopApplied == desktop) return
        // Cefrium has no viewport-mode split: a desktop UA string plus the page's
        // own responsive behavior is the whole capability.
        runCatching { entry.browser.setUserAgentOverride(if (desktop) DESKTOP_USER_AGENT else null) }
        entry.desktopApplied = desktop
    }

    // ---------------------------------------------------------------- context menu / link preview

    fun dismissContextMenu(tabId: String? = null) {
        mutableLinkPreview.value?.takeIf { tabId == null || it.sourceTab == tabId }?.let { closeLinkPreview(it.id) }
        if (tabId != null && ownedContextMenu?.request?.tab != tabId) return
        ownedContextMenu = null
        mutableContextMenu.value = null
    }

    fun openLinkPreview(requestId: String, authorityCurrent: () -> Boolean): Boolean {
        val held = ownedContextMenu?.takeIf { it.request.id == requestId } ?: return false
        val target = held.request.link?.takeIf(::linkPreviewWebUrl) ?: return false
        closeLinkPreview()
        val sourceUrl = held.entry.page.url
        fun current() = authorityCurrent() && !disposed && ownedContextMenu === held &&
            pages[held.request.tab] === held.entry && held.entry.document == held.document &&
            held.entry.page.url == sourceUrl && owns(held.entry.browser) &&
            visibleTabs?.contains(held.request.tab) != false
        if (!current()) return false
        val preview = CefriumLinkPreview(requestId, held.request.tab, target, held.request.isPrivate,
            profileOf(held.entry.profile), ::current) { closeLinkPreview(requestId) }
        mutableLinkPreview.value = preview
        return true
    }

    fun revalidateLinkPreview() { mutableLinkPreview.value?.current() }

    fun closeLinkPreview(id: String? = null) {
        val preview = mutableLinkPreview.value ?: return
        if (id != null && preview.id != id) return
        mutableLinkPreview.value = null
        preview.close()
    }

    fun commitLinkPreview(id: String): Boolean {
        val preview = mutableLinkPreview.value?.takeIf { it.id == id } ?: return false
        val held = ownedContextMenu?.takeIf { it.request.id == id } ?: run { closeLinkPreview(id); return false }
        if (!preview.consume()) { closeLinkPreview(id); return false }
        val target = preview.url
        dismissContextMenu()
        runCatching { held.entry.browser.loadUrl(target) }
        return true
    }

    /** Once-only action lease. The UI performs only the action the person picked after this succeeds. */
    fun takeContextMenu(id: String): PageContextMenu? {
        val pending = ownedContextMenu ?: return null
        if (pending.request.id != id) return null
        dismissContextMenu()
        return pending.request.takeIf { pages[it.tab] === pending.entry && pending.entry.document == pending.document &&
            ownsInteractive(pending.entry.browser) }
    }

    /** This capability is created only by consuming the native long-press entry. */
    class HeldImageDownload internal constructor(val image: String, val owner: ExternalActivityOwner)

    fun takeImageDownload(id: String): HeldImageDownload? {
        val pending = ownedContextMenu?.takeIf { it.request.id == id } ?: return null
        val image = pending.request.image ?: return null
        dismissContextMenu()
        if (pages[pending.request.tab] !== pending.entry || pending.entry.document != pending.document ||
            !ownsInteractive(pending.entry.browser)) return null
        return HeldImageDownload(image, ExternalActivityOwner(pending.request.tab, pending.entry.browser,
            pending.entry.document, pending.entry.profile.id, pending.entry.profile.isPrivate))
    }

    // ---------------------------------------------------------------- thumbnails

    fun requestThumbnail(tab: BrowserTab, profile: WebsiteProfile) {
        if (!disposed && !tab.isPrivate && !profile.isPrivate && managedTabs[tab.id] == profile)
            snapshots.request(ThumbnailOwner(tab.id, profile.id, tab.url))
    }

    /** captureBitmap is Cefrium's offscreen pixel path; public tab pictures use it like Gecko's view capture. */
    private fun scheduleCapture(id: String, entry: Entry) {
        if (entry.profile.isPrivate || !entry.alive || entry.page.loading) return
        val bound = views[id]?.get()
        if (bound != null && (bound.width <= 0 || bound.height <= 0)) return
        captureScope.launch {
            val answer = CompletableDeferred<Bitmap?>()
            runCatching { entry.browser.captureBitmap { bitmap -> answer.complete(bitmap) } }
                .onFailure { answer.complete(null) }
            val bitmap = withTimeoutOrNull(400) { answer.await() } ?: return@launch
            if (bitmap != null && pages[id] === entry && entry.alive && !entry.page.loading)
                snapshots.put(id, bitmap, entry.page.url ?: entry.tab.url, entry.profile.id, entry.document, entry.thumbnailSession)
            else bitmap?.recycle()
        }
    }

    /** View pixels for the page-swipe frame; Cefrium's captureBitmap may run offscreen. */
    suspend fun capturePagingFrame(tab: BrowserTab, profile: WebsiteProfile,
        sourceCurrent: () -> Boolean): PagingCaptureResult = withContext(Dispatchers.Main.immediate) {
        val entry = pages[tab.id] ?: return@withContext PagingCaptureResult(PagingCaptureOutcome.NOT_CURRENT)
        fun source() = !disposed && foreground && pages[tab.id] === entry && entry.alive &&
            entry.profile == profile && !entry.page.loading && ownsInteractive(entry.browser) &&
            !(profile.isPrivate && privateMediaPaused) && sourceCurrent()
        if (!source()) return@withContext PagingCaptureResult(PagingCaptureOutcome.NOT_CURRENT)
        // Cefrium captures the frame offscreen via captureBitmap; the bound view's
        // geometry gate still applies, and the shared lifetime decides what is kept.
        val view = views[tab.id]?.get()
        if (view != null && !PagingCaptureLifetime.permits(view.width, view.height))
            return@withContext PagingCaptureResult(PagingCaptureOutcome.DIMENSIONS_REFUSED)
        val answer = CompletableDeferred<Bitmap?>()
        runCatching { entry.browser.captureBitmap { bitmap -> answer.complete(bitmap) } }
            .onFailure { answer.complete(null) }
        val bitmap = withTimeoutOrNull(PagingCaptureLifetime.DEADLINE_MILLIS) { answer.await() }
            ?: return@withContext PagingCaptureResult(PagingCaptureOutcome.TIMED_OUT)
        if (bitmap == null) return@withContext PagingCaptureResult(PagingCaptureOutcome.CAPTURE_FAILED)
        if (!source()) { bitmap.recycle(); return@withContext PagingCaptureResult(PagingCaptureOutcome.REVOKED) }
        val frame = PagingFrame(bitmap, { source() }, { bitmap.recycle() })
        PagingCaptureResult(PagingCaptureOutcome.READY, frame)
    }

    fun rebindPrompts(next: NativePagePrompts?) {
        prompts?.dismiss()
        prompts = next
        pages.values.filter { it.alive }.forEach { next?.register(it.browser) }
    }

    // ---------------------------------------------------------------- persistence

    fun saveSessions() {
        // serializeNavigationState is a main-thread JNI whose cost grows with
        // history depth; posting one save per session keeps the pause path
        // responsive and the handler preserves per-session order.
        pages.values.filter { it.alive }.forEach { entry ->
            if (entry.profile.isPrivate) return@forEach
            if (pendingSaveTabs.add(entry.tab.id)) handler.post { saveSession(entry) }
        }
    }

    private fun saveSession(entry: Entry) {
        pendingSaveTabs.remove(entry.tab.id)
        if (disposed || pages[entry.tab.id] !== entry || !entry.alive) return
        val state = runCatching { entry.browser.serializeNavigationState() }.getOrNull() ?: return
        if (state.size <= 8 * 1024 * 1024) saveState(entry.tab.id, entry, state)
    }

    private fun readState(id: String, profile: WebsiteProfile): ByteArray? {
        if (profile.isPrivate || id in pendingStateDeletes || profile.id in clearingProfiles) return null
        val file = stateFile(id)
        if (!file.isFile || file.length() > 8 * 1024 * 1024) return null
        return runCatching {
            JSONObject(file.readText()).takeIf { it.optString("profile") == profile.id && it.optInt("schema") == 2 }
                ?.getString("state")
        }.getOrNull()?.let { runCatching { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }.getOrNull() }
    }

    private fun saveState(id: String, entry: Entry, state: ByteArray) {
        // The Base64 + JSON round trip scales with history depth; encode off main.
        stateWriter.execute {
            val text = JSONObject().put("schema", 2).put("profile", entry.profile.id)
                .put("state", android.util.Base64.encodeToString(state, android.util.Base64.DEFAULT)).toString()
            val atomic = android.util.AtomicFile(stateFile(id))
            val output = atomic.startWrite()
            try { output.write(text.toByteArray()); atomic.finishWrite(output) }
            catch (error: Exception) { atomic.failWrite(output) }
        }
    }

    private fun stateFile(id: String): File = File(context.filesDir, "navigation").apply { mkdirs() }
        .resolve("${UUID.nameUUIDFromBytes(id.toByteArray())}.json")

    private fun webHost(url: String?): String? = url?.let {
        runCatching { URI(it).takeIf { uri -> uri.scheme in setOf("http", "https") }?.host }.getOrNull()
    }

    private fun safeContextUrl(url: String?): String? = url?.takeIf { it.length <= 16_384 && !it.contains('\n') && !it.contains('\r') }
        ?.takeIf { runCatching { URI(it).let { uri -> uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null } }.getOrDefault(false) }

    private companion object {
        // A desktop UA without a viewport-mode knob: Cefrium only overrides the string.
        const val DESKTOP_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    }
}

/**
 * PageDownloadSource over Cefrium's download manager. onBeforeDownload's callback
 * exposes no stream, only a destination path (allow(path)), so Cefrium writes the
 * file itself and this source streams that file once it exists. uri/mime/size
 * come from the DownloadItem (getUrl/getMimeType/getTotalBytes, AAR-verified);
 * a zero totalBytes is reported as null: the length is unknown. The callback's
 * item is an immutable snapshot, so completion arrives through completed(),
 * driven by the engine's onDownloadUpdated routing, and stream(timeoutMillis)
 * waits on that latch instead of polling the snapshot.
 */
internal class CefriumDownloadItemSource(private val item: CefriumBrowser.DownloadItem,
    private val file: File, private val managed: CefriumManagedDownload) : PageDownloadSource {
    private val latch = CountDownLatch(1)
    @Volatile private var finished = false
    override val uri: String get() = item.url
    override val mime: String? get() = item.mimeType?.takeIf { it.isNotBlank() }
    override val size: Long? get() = item.totalBytes.takeIf { it > 0 }
    /** The engine calls this from onDownloadUpdated once Cefrium's own copy is done. */
    fun completed() { finished = true; latch.countDown() }
    /** Canceled or interrupted; the waiting stream must give up. */
    fun failed() { latch.countDown() }
    override fun stream(timeoutMillis: Long): InputStream? {
        if (managed.closed) return null
        if (!latch.await(timeoutMillis.coerceAtLeast(1_000), TimeUnit.MILLISECONDS)) return null
        if (managed.closed || !finished) return null
        return runCatching { file.inputStream() }.getOrNull()
    }
    override fun close() { managed.close() }
}

/**
 * One live Cefrium transfer per onBeforeDownload. close() stops Cefrium's own
 * copy so the transfer dies with the dialog that owned it.
 */
internal class CefriumManagedDownload internal constructor(val file: File, private val browser: CefriumBrowser,
    private val item: CefriumBrowser.DownloadItem,
    private val interactive: (CefriumBrowser) -> Boolean) : Closeable {
    private val main = Handler(Looper.getMainLooper())
    internal var closed = false
        private set
    init {
        file.parentFile?.mkdirs()
        file.delete()
    }
    fun open(): Boolean {
        // The parent directory existed before this transfer; a clean slate is required.
        return file.parentFile?.let { runCatching { it.isDirectory && it.canWrite() }.getOrDefault(false) } == true &&
            runCatching { file.createNewFile() }.getOrDefault(false)
    }
    override fun close() {
        if (closed) return
        closed = true
        main.post { runCatching { if (interactive(browser)) item.cancel() } }
    }
}
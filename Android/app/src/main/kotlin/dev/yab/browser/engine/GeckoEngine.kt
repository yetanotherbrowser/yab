package dev.yab.browser.engine

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import dev.yab.browser.model.BrowserEngine
import dev.yab.browser.model.BrowserBackItem
import dev.yab.browser.model.BrowserFindQuery
import dev.yab.browser.model.BrowserFindResult
import dev.yab.browser.model.BrowserFindDirection
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserPageMemento
import dev.yab.browser.model.EnginePageState
import dev.yab.browser.model.WebsiteProfile
import dev.yab.browser.model.FieldAnswerTarget
import dev.yab.browser.model.HistorySwipeDirection
import dev.yab.browser.model.NativeHistorySwipeTarget
import dev.yab.browser.model.ReaderPreferences
import dev.yab.browser.model.ReaderStylePayload
import dev.yab.browser.download.OwnedImageDownloadRuntime
import dev.yab.browser.icons.AndroidSiteIcons
import java.io.File
import java.lang.ref.WeakReference
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.WebExtension
import org.mozilla.geckoview.WebRequestError
import org.mozilla.geckoview.WebResponse
import dev.yab.browser.media.*
import dev.yab.nativefeatures.*
import dev.yab.shield.ShieldPopupRequest
import org.json.JSONArray

/** Containers own storage. A web page cannot choose another tab's native channel. */
internal enum class NativeFindStage { REQUEST, SUBMITTED, RESULT, DELIVERED, FAILURE, CLEAR }
internal data class NativeFindObservation(val stage: NativeFindStage, val ownerCurrent: Boolean,
    val entryCurrent: Boolean, val alive: Boolean, val documentCurrent: Boolean, val sessionOwned: Boolean,
    val queryMatches: Boolean? = null, val current: Int? = null, val total: Int? = null,
    val readiness: NativeFindReadiness? = null)
/** App-owned booleans only. The optional fixture observer reads no document or OS diagnostics. */
internal data class NativeFindReadiness(val privateProfile: Boolean, val privatePaused: Boolean,
    val foreground: Boolean, val sessionOpen: Boolean, val viewPresent: Boolean, val viewAttached: Boolean,
    val viewShown: Boolean, val viewFocused: Boolean, val viewSessionCurrent: Boolean,
    val viewHasSize: Boolean, val firstPaint: Boolean, val pageStopped: Boolean,
    val contentBound: Boolean, val bridgeConnected: Boolean)

class GeckoEngine(private val context: Context, val runtime: GeckoRuntime, private val maxLiveSessions: Int = 6) : BrowserEngine {
    private data class Entry(val session: GeckoSession, val profile: WebsiteProfile,
        var tab: BrowserTab, var page: EnginePageState = EnginePageState(), var port: WebExtension.Port? = null,
        var document: String = UUID.randomUUID().toString(), var savedState: String? = null, var alive: Boolean = true,
        var observed: Boolean = false, var editing: Boolean = false, var permissions: Int = 0, var fullScreen: Boolean = false,
        var mediaAccessGranted: Boolean = false, var domPlaying: Boolean = false,
        var contentDocument: String? = null,
        var iconObservation: Pair<String, String?>? = null,
        val thumbnailSession: String = UUID.randomUUID().toString(),
        var popupOrigin: PopupOrigin? = null,
        var popupCloseOwner: PopupCloseOwner? = null,
        val popupPermits: MutableList<PopupPermit> = mutableListOf(),
        val backHistory: NativeBackHistory = NativeBackHistory(),
        val historySwipe: NativeHistorySwipeRegistry = NativeHistorySwipeRegistry(),
        var historyIdentity: HistoryIdentitySnapshot? = null,
        var historyFirstPaint: Boolean = false, var historyPageStopped: Boolean = false,
        var historyImagesDisabled: Boolean = false, var historyViewportRevision: Long = 0,
        var historyCapturedRevision: Long = -1,
        var historyCaptureStage: String = "IDLE",
        var bridgeConnections: Int = 0, var bridgeMessages: Int = 0, var bridgeEvent: String = "created",
        var lastTextShape: String = "none",
        var lastTextRead: PageReadStage = PageReadStage.IDLE,
        var recovery: NativePageRecovery = NativePageRecovery(),
        var lastUsed: Long = SystemClock.uptimeMillis(), var eviction: String? = null, var evictionReady: Boolean = false,
        var capturePending: Boolean = false, var capturedAt: Long = 0,
        var captureStage: String = "idle")
    private data class Suspended(val tab: BrowserTab, val profile: WebsiteProfile, val state: String?, val page: EnginePageState)
    private class ClosedMemory(val engine: GeckoEngine, val tab: BrowserTab, val profile: WebsiteProfile,
        var state: String?, val expires: Long) : BrowserPageMemento {
        val drained = CompletableDeferred<Unit>()
        var released = false
        var restored: Suspended? = null
    }
    private data class Closing(val entry: Entry, val memory: ClosedMemory, val finish: () -> Unit)
    private val closedMemories = linkedSetOf<ClosedMemory>()
    private var managedTabs = emptyMap<String, WebsiteProfile>()
    private val closing = mutableMapOf<GeckoSession, Closing>()
    private data class PopupOrigin(val entry: Entry, val document: String, val page: String)
    private data class PopupCloseOwner(val opener: String, val profile: WebsiteProfile, val epoch: Long)
    private data class PopupPermit(val url: String, val document: String, val expires: Long)
    private data class PendingPopup(val tab: String, val finish: (Boolean) -> Unit)
    private val popupRequests = mutableMapOf<String, PendingPopup>()
    private val pages = linkedMapOf<String, Entry>()
    private var readerPreferences = ReaderPreferences()
    private val historyTouchChannels = mutableMapOf<String, OwnedHistoryTouchChannel>()
    private val historyTargets = mutableMapOf<NativeHistorySwipeTarget, Entry>()
    private var historySwipeConsumer: HistorySwipeConsumer? = null
    private data class HistoryKeyRequest(val entry: Entry, val document: String, val content: String,
        val port: WebExtension.Port, val answer: CompletableDeferred<HistoryNavigationKey?>)
    private val historyKeyRequests = mutableMapOf<String, HistoryKeyRequest>()
    private val historyCaptureScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var historyCaptureJob: Job? = null
    private var historyFrameOwner: Entry? = null
    private var historyFrames: HistoryFrameStore<BudgetedNativeFrame<Bitmap>>? = null
    private val historyPaintCallbacks = java.util.WeakHashMap<GeckoView, Pair<GeckoSession, Runnable>>()
    private val suspended = mutableMapOf<String, Suspended>()
    // Keep Private's RAM storage alive while an owned tab is suspended or retained for Undo.
    // Only native blank-load lifecycle delegates, never a bridge, view or web content.
    private class PrivateKeeper(val session: GeckoSession, val readiness: PrivateKeeperReadiness) {
        var blankStarted = false
        var timeout: Runnable? = null
    }
    private val privateKeepers = mutableMapOf<String, PrivateKeeper>()
    private var privateKeeperGeneration = 0L
    private var privateKeeperAcks = 0
    private var privateKeeperRejected = 0
    private var privateKeeperLast = "NONE"
    private var privateMediaPaused = false
    private var privateMediaRequiresLock = true
    private val pageMedia = GeckoPageMedia { id, playing -> pages[id]?.let { entry ->
        update(id, entry) { it.copy(playingMedia = playing || entry.domPlaying,
            safeToClear = it.safeToClear && !playing) }
    } }
    val media get() = pageMedia.state
    private val views = mutableMapOf<String, WeakReference<GeckoView>>()
    private val nativeFrameCaptureArbiter = NativeFrameCaptureArbiter()
    private val nativeFrameBudget = NativeFrameBudget<Bitmap>()
    private val pagingCaptureLifetime = PagingCaptureLifetime(nativeFrameCaptureArbiter)
    private var pagingCaptureAnswer: CompletableDeferred<PagingCaptureResult>? = null
    private var pagingFrame: PagingFrame? = null
    private val handler = Handler(Looper.getMainLooper())
    private val stateWriter = Executors.newSingleThreadExecutor()
    private val snapshots = TabThumbnails(disk = PublicThumbnailDiskCache(File(context.cacheDir, "public-tab-pictures")),
        io = { stateWriter.execute(it) }, main = { handler.post(it) })
    private val translationPage = MutableStateFlow<TranslationPage?>(null)
    val thumbnails get() = snapshots.state
    val liveSessionCount get() = pages.values.count { it.alive }
    fun hasLiveSession(id: String) = pages[id]?.alive == true
    private var visibleTabs: Set<String>? = null
    private var recoveryTabs: Set<String>? = null
    private var sessionBudget = maxLiveSessions.coerceAtLeast(1)
    private var pinnedSessions = PinnedSessions()
    /** Debug builds on an owned emulator: the same APK before and after, for an A/B of the rule. */
    private val pinsMaySleep = dev.yab.android.BuildConfig.DEBUG &&
        android.provider.Settings.Global.getInt(context.contentResolver, "yab_pins_sleep", 0) == 1
    private fun trace(what: String) { if (dev.yab.android.BuildConfig.DEBUG) android.util.Log.d("YabPages", what) }
    private var trackingProtection = true
    private var disposed = false
    private var ownershipEpoch = 0L
    private var fieldAnswerEpoch = 0L
    private var autofillEpoch = 0L
    private var privateAutofillEpoch = 0L
    private var integration: WebExtension? = null
    private data class TextRequest(val tab: String, val document: String, val port: WebExtension.Port, val answer: CompletableDeferred<PageText>, val diagnostics: Boolean)
    private val textRequests = mutableMapOf<String, TextRequest>()
    private data class DomRequest(val tab: String, val document: String, val port: WebExtension.Port, val answer: CompletableDeferred<JSONObject>)
    private val domRequests = mutableMapOf<String, DomRequest>()
    private class OwnedFind(val tab: String, val entry: Entry, val document: String,
        val query: BrowserFindQuery, val answer: (BrowserFindResult?) -> Unit)
    private var ownedFind: OwnedFind? = null
    /** Fixed enums/booleans/counts for an owned fixture; ordinary builds collect nothing. */
    internal var findObserver: ((NativeFindObservation) -> Unit)? = null
    /** Optional fixed history metadata for an owned fixture. No ordinary collection. */
    internal var historyCaptureObserver: ((NativeHistoryCaptureObservation) -> Unit)? = null
    var onState: (String, EnginePageState) -> Unit = { _, _ -> }
    var onNewTab: (String, String) -> Unit = { _, _ -> }
    var onError: (String) -> Unit = {}
    var onDownload: (WebResponse) -> Unit = { it.body?.close() }
    private var imageDownloads: OwnedImageDownloadRuntime? = null
    var selected: String? = null
        private set
    var prompts: NativePagePrompts? = null
    var permissionRequest: (Array<String>, (Boolean) -> Unit) -> Unit = { _, answer -> answer(false) }
    private var foreground = true
    val siteSettings = SiteSettingsStore(File(context.filesDir, "site-settings.json")) { stateWriter.execute(it) }
    private val mutableConnections = MutableStateFlow<Map<String, SiteConnection>>(emptyMap())
    val connections = mutableConnections.asStateFlow()
    private data class OwnedContextMenu(val request: PageContextMenu, val entry: Entry, val document: String)
    private var ownedContextMenu: OwnedContextMenu? = null
    private val mutableContextMenu = MutableStateFlow<PageContextMenu?>(null)
    val contextMenu = mutableContextMenu.asStateFlow()
    private val mutableLinkPreview = MutableStateFlow<NativeLinkPreview?>(null)
    val linkPreview = mutableLinkPreview.asStateFlow()
    private val pendingStateDeletes = ConcurrentHashMap.newKeySet<String>()
    private val clearingProfiles = ConcurrentHashMap.newKeySet<String>()
    private val dataClear = Mutex()
    var onSessionCreated: (GeckoSession) -> Unit = {}
    // Production opts in to the public RAM cache; engine fixtures make no icon requests by default.
    internal var siteIcons: AndroidSiteIcons? = null
    var onSessionActivated: (GeckoSession) -> Unit = {}
    var onSessionClosed: (GeckoSession) -> Unit = {}
    var createWindow: (String, String) -> GeckoSession? = { _, _ -> null }
    var onCloseWindow: (String, String, WebsiteProfile) -> Boolean = { _, _, _ -> false }
    var popupPolicy: (ShieldPopupRequest) -> GeckoResult<Boolean> = { GeckoResult.fromValue(true) }
    data class PageText(val title: String, val url: String, val text: String, val geometry: PageViewportGeometry? = null)

    /** Installing an update ends this process: a form, a Private page or playing media keeps it waiting. */
    private val updateHold = dev.yab.update.UpdateHold {
        pages.entries.firstNotNullOfOrNull { (id, entry) -> when {
            entry.profile.isPrivate -> "private"
            entry.page.hasFormEdits || entry.editing -> "form"
            entry.domPlaying || pageMedia.playing(id) || entry.page.capturingMedia -> "media"
            else -> null
        } }
    }

    init {
        dev.yab.update.UpdateHolds.add(updateHold)
        runtime.webExtensionController.ensureBuiltIn("resource://android/assets/web_extensions/yab/", "yab-native@browser.local")
            .accept(install@{ candidate ->
                val extension = candidate ?: run { onError("Page integration couldn't start"); return@install }
                check(extension.isBuiltIn && extension.id == "yab-native@browser.local")
                // This is our APK code, including the Private reader/translation bridge.
                // Third-party signed extensions retain their independent Private consent.
                runtime.webExtensionController.setAllowedInPrivateBrowsing(extension, true).accept(allowPrivate@{ candidate ->
                    val ready = candidate ?: run { onError("Private page integration couldn't start"); return@allowPrivate }
                    if (!disposed) {
                        integration = ready
                        pages.forEach { (id, entry) -> attachBridge(id, entry) }
                        mutableLinkPreview.value?.denyBridge(ready)
                    }
                }, { error -> onError("Private page integration couldn't start: ${error?.message ?: "runtime unavailable"}") })
            }, { error -> onError("Page integration couldn't start: ${error?.message ?: "runtime unavailable"}") })
    }

    /** No URLs or page text: useful when an actual native channel fails before its first reply. */
    fun bridgeStatus(id: String): String = pages[id]?.let { entry ->
        "installed=${integration != null},alive=${entry.alive},open=${entry.session.isOpen},selected=${selected == id},foreground=$foreground," +
            "privatePaused=${entry.profile.isPrivate && privateMediaPaused},connected=${entry.port != null}," +
            "connections=${entry.bridgeConnections},messages=${entry.bridgeMessages},event=${entry.bridgeEvent},textShape=${entry.lastTextShape}"
    } ?: "No native session"

    /** Finite owned-fixture projection, never a URL, document identifier or exception message. */
    fun textReadDiagnostics(id: String?): JSONObject {
        val key = id ?: return JSONObject().put("stage", "NO_SESSION")
        val entry = pages[key] ?: return JSONObject().put("stage", "NO_SESSION")
        val view = views[key]?.get()
        return JSONObject().put("stage", entry.lastTextRead.name).put("installed", integration != null)
            .put("connected", entry.port != null).put("contentDocumentKnown", entry.contentDocument != null)
            .put("connections", entry.bridgeConnections).put("messages", entry.bridgeMessages)
            .put("owned", owns(entry.session)).put("loading", entry.page.loading)
            .put("viewBound", view != null).put("viewAttached", view?.isAttachedToWindow == true)
            .put("viewSessionCurrent", view?.session === entry.session).put("visible", visibleTabs?.contains(key) != false)
    }

    /** Fixed stages and booleans only, without document, URL, account or image contents. */
    fun thumbnailStatus(id: String): String = pages[id]?.let { entry ->
        val view = views[id]?.get()
        "stage=${entry.captureStage},pending=${entry.capturePending},foreground=$foreground," +
            "alive=${entry.alive},loading=${entry.page.loading},private=${entry.profile.isPrivate}," +
            "selected=${selected == id},visible=${visibleTabs?.contains(id) != false}," +
            "bound=${view != null},attached=${view?.isAttachedToWindow == true},sameSession=${view?.session === entry.session}," +
            "sized=${view != null && view.width > 0 && view.height > 0}"
    } ?: "No native session"

    fun session(tab: BrowserTab, profile: WebsiteProfile, load: Boolean = true, open: Boolean = true): GeckoSession {
        check(!disposed) { "The browser engine is closed" }
        val previous = pages[tab.id]
        if (previous != null && previous.profile != profile) close(tab.id)
        pages[tab.id]?.let { it.tab = tab; return it.session }
        val sleeping = suspended.remove(tab.id)?.takeIf { it.profile == profile }
        val settings = GeckoSessionSettings.Builder().usePrivateMode(profile.isPrivate)
            .contextId(profile.id).useTrackingProtection(trackingProtection)
            .userAgentMode(if (siteSettings.site(webHost(tab.url), profile.isPrivate).desktop) GeckoSessionSettings.USER_AGENT_MODE_DESKTOP else GeckoSessionSettings.USER_AGENT_MODE_MOBILE)
            .viewportMode(if (siteSettings.site(webHost(tab.url), profile.isPrivate).desktop) GeckoSessionSettings.VIEWPORT_MODE_DESKTOP else GeckoSessionSettings.VIEWPORT_MODE_MOBILE)
            .suspendMediaWhenInactive(profile.isPrivate && privateMediaRequiresLock).build()
        val session = GeckoSession(settings)
        val entry = Entry(session, profile, tab, savedState = sleeping?.state,
            page = EnginePageState(url = tab.url, title = tab.title))
        pages[tab.id] = entry
        // A recording document must close immediately on Private lock. Open its
        // RAM-only keeper before the first page loads, while no cookie handoff
        // is at risk, rather than racing the last recording session's close.
        if (profile.isPrivate) keepPrivateProfile(profile)
        session.compositorScrollDelegate = object : GeckoSession.CompositorScrollDelegate {
            override fun onScrollChanged(s: GeckoSession, position: GeckoSession.ScrollPositionUpdate) {
                val view = views[tab.id]?.get() ?: return
                if (pages[tab.id] !== entry || entry.session !== s || !entry.alive || !ownsInteractive(s) ||
                    entry.page.loading || entry.contentDocument == null || view.session !== s ||
                    !view.isAttachedToWindow || !view.isShown) return
                val logical = compositedUserScroll(position.scrollY, position.zoom, view.resources.displayMetrics.density,
                    position.source == GeckoSession.ScrollPositionUpdate.SOURCE_USER_INTERACTION) ?: return
                update(tab.id, entry) { it.copy(scrollY = position.scrollY.coerceAtLeast(0f), userScrollY = logical) }
                entry.historyViewportRevision++
                scheduleHistoryCapture(tab.id, entry, scrollSettled = true)
            }
        }
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(s: GeckoSession, url: String?, permissions: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                if (pages[tab.id] !== entry || !entry.alive) return
                applyDesktop(entry, url)
                update(tab.id, entry) { it.copy(url = url, error = null) }
            }
            override fun onCanGoBack(s: GeckoSession, canGoBack: Boolean) { update(tab.id, entry) { it.copy(canGoBack = canGoBack) } }
            override fun onCanGoForward(s: GeckoSession, canGoForward: Boolean) { update(tab.id, entry) { it.copy(canGoForward = canGoForward) } }
            override fun onLoadRequest(s: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                if (pages[tab.id] !== entry || !entry.alive) return GeckoResult.fromValue(AllowOrDeny.DENY)
                val uri = Uri.parse(request.uri)
                if (request.target != GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW) applyDesktop(entry, request.uri)
                if (request.isDirectNavigation) entry.popupOrigin = null
                if (request.target == GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW && uri.scheme in setOf("http", "https", "about", "data", "blob", "moz-extension"))
                    return decidePopup(tab.id, entry, request.uri, remember = true)
                if (!request.isDirectNavigation && entry.popupOrigin != null && uri.scheme in setOf("http", "https"))
                    return decidePopup(tab.id, entry, request.uri, entry.popupOrigin)
                if (uri.scheme in setOf("http", "https", "about", "data", "blob", "moz-extension")) return GeckoResult.fromValue(AllowOrDeny.ALLOW)
                if (request.hasUserGesture && ownsInteractive(s)) {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        .onFailure { onError("No app can open this link") }
                }
                return GeckoResult.fromValue(AllowOrDeny.DENY)
            }
            override fun onNewSession(s: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                if (!owns(s)) return null
                val result = GeckoResult<GeckoSession>()
                val document = entry.document
                val epoch = ownershipEpoch
                val origin = PopupOrigin(entry, document, popupSource(entry))
                fun create(allowed: Boolean) {
                    if (!allowed || ownershipEpoch != epoch || !popupCurrent(tab.id, entry, document, null)) { result.complete(null); return }
                    val child = createWindow(tab.id, uri)
                    child?.let { created -> pages.values.firstOrNull { it.session === created && it.profile == entry.profile && it.tab.openerId == tab.id }?.let {
                        it.popupOrigin = origin
                        // Close belongs to this native window, including its later OAuth redirects.
                        // Recreating a tab's session never inherits this authority.
                        it.popupCloseOwner = PopupCloseOwner(tab.id, entry.profile, epoch)
                    } }
                    result.complete(child)
                }
                entry.popupPermits.removeAll { it.expires < SystemClock.uptimeMillis() }
                val permit = entry.popupPermits.firstOrNull { it.url == uri && it.document == document }
                    ?: entry.popupPermits.firstOrNull { it.url == uri }
                if (permit != null) { entry.popupPermits.remove(permit); create(permit.document == document) }
                else decidePopup(tab.id, entry, uri).accept({ decision -> create(decision == AllowOrDeny.ALLOW) }, { create(false) })
                return result
            }
            override fun onLoadError(s: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                update(tab.id, entry) { it.copy(loading = false, error = "This page couldn't load. Check the connection and try again.") }
                return null
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(s: GeckoSession, url: String) {
                if (pages[tab.id] !== entry || !entry.alive) return
                trace("start ${tab.place} $url")
                (views[tab.id]?.get() as? HistorySwipeView)?.revokeAutofill(cancelFramework = selected == tab.id)
                revokePagingFrame()
                dismissContextMenu(tab.id)
                mutableConnections.value = mutableConnections.value - tab.id
                if (selected == tab.id) prompts?.dismiss()
                cancelDocumentRequests(tab.id)
                entry.backHistory.invalidate()
                entry.historySwipe.invalidate()
                historyCaptureJob?.cancel(); historyCaptureJob = null
                if (historyFrameOwner === entry) historyFrames?.pageStarted()
                entry.historyIdentity = null; entry.historyFirstPaint = false; entry.historyPageStopped = false
                entry.historyImagesDisabled = false; entry.historyViewportRevision++
                entry.historyCaptureStage = "NEW_DOCUMENT"
                historyTargets.entries.removeAll { it.value === entry }
                historyTouchChannels.remove(tab.id)?.close()
                (views[tab.id]?.get() as? HistorySwipeView)?.historyDocumentStarted()
                entry.domPlaying = false
                pageMedia.forget(tab.id)
                entry.document = UUID.randomUUID().toString()
                entry.lastTextRead = PageReadStage.IDLE
                entry.eviction = null; entry.evictionReady = false; entry.observed = false; entry.editing = false
                entry.mediaAccessGranted = false
                entry.contentDocument = null
                entry.port = null
                snapshots.remove(tab.id)
                applyDesktop(entry, url)
                update(tab.id, entry) { it.copy(url = url, secure = false, loading = true, progress = 0f, error = null, hasFormEdits = false, playingMedia = false, safeToClear = false, frameUncertain = true, scrollY = 0f, userScrollY = 0f) }
            }
            override fun onProgressChange(s: GeckoSession, progress: Int) { update(tab.id, entry) { it.copy(progress = progress / 100f) } }
            override fun onPageStop(s: GeckoSession, success: Boolean) {
                if (pages[tab.id] !== entry || !entry.alive) return
                if (success && entry.page.loading && (entry.tab.isBlank || entry.page.url?.let {
                        Uri.parse(it).scheme in setOf("http", "https") } == true)) entry.recovery.succeeded()
                if (entry.page.url?.let { Uri.parse(it).scheme in setOf("http", "https") } == true) entry.popupOrigin = null
                update(tab.id, entry) { it.copy(loading = false, progress = if (success) 1f else it.progress) }
                entry.historyPageStopped = success
                scheduleHistoryCapture(tab.id, entry)
                applyZoom(tab.id, entry)
                scheduleCapture(tab.id, entry)
                trimSessions()
            }
            override fun onSecurityChange(s: GeckoSession, securityInfo: GeckoSession.ProgressDelegate.SecurityInformation) {
                if (pages[tab.id] !== entry || !entry.alive) return
                val certificate = securityInfo.certificate
                mutableConnections.value = mutableConnections.value + (tab.id to SiteConnection(
                    secure = securityInfo.isSecure, exception = securityInfo.isException,
                    // Gecko 158 can omit the nominally @NonNull host on plain HTTP/about pages.
                    host = securityInfo.host.orEmpty(), origin = securityInfo.origin, securityMode = securityInfo.securityMode,
                    mixedActive = securityInfo.mixedModeActive, mixedPassive = securityInfo.mixedModePassive,
                    subject = certificate?.subjectX500Principal?.name, issuer = certificate?.issuerX500Principal?.name,
                    validFrom = certificate?.notBefore?.time, validUntil = certificate?.notAfter?.time,
                    sha256 = certificate?.let { runCatching { MessageDigest.getInstance("SHA-256").digest(it.encoded).joinToString(":") { byte -> "%02X".format(byte) } }.getOrNull() },
                ))
                update(tab.id, entry) { it.copy(secure = securityInfo.isSecure) }
            }
            override fun onSessionStateChange(s: GeckoSession, state: GeckoSession.SessionState) {
                closing[s]?.takeIf { it.entry === entry }?.let { pending ->
                    val text = state.toString()
                    if (text != null && !pending.memory.released && text.length <= 8 * 1024 * 1024 &&
                        closedMemories.sumOf { it.state?.length?.toLong() ?: 0 } - (pending.memory.state?.length ?: 0) + text.length <= 16L * 1024 * 1024)
                        pending.memory.state = text
                    pending.finish()
                    return
                }
                if (pages[tab.id] !== entry || !entry.alive) return
                captureBackHistory(tab.id, entry, state, NativeHistoryCaptureSource.SESSION_STATE)
                entry.historyIdentity = state.toString()?.let(HistoryIdentitySnapshot::parse)
                if (historyFrameOwner === entry) historyFrames?.historyChanged(entry.session, entry.historyIdentity)
                scheduleHistoryCapture(tab.id, entry)
                entry.savedState = state.toString()
                if (!profile.isPrivate) saveState(tab.id, entry)
                if (entry.evictionReady && safeToEvict(tab.id, entry) && liveSessionCount > sessionBudget) evict(tab.id, entry)
            }
        }
        session.historyDelegate = object : GeckoSession.HistoryDelegate {
            override fun onHistoryStateChange(s: GeckoSession, history: GeckoSession.HistoryDelegate.HistoryList) {
                if (s === session) captureBackHistory(tab.id, entry, history, NativeHistoryCaptureSource.HISTORY_LIST)
            }
        }
        session.promptDelegate = prompts
        session.permissionDelegate = object : GeckoSession.PermissionDelegate {
            override fun onAndroidPermissionsRequest(s: GeckoSession, permissions: Array<out String>?, callback: GeckoSession.PermissionDelegate.Callback) {
                if (!ownsInteractive(s) || permissions == null) { callback.reject(); return }
                val document = entry.document
                entry.permissions++
                permissionRequest(permissions.map { it }.toTypedArray()) { granted ->
                    entry.permissions = (entry.permissions - 1).coerceAtLeast(0)
                    if (granted && ownsInteractive(s) && pages[tab.id] === entry && entry.document == document) callback.grant() else callback.reject()
                }
            }
            override fun onContentPermissionRequest(s: GeckoSession, permission: GeckoSession.PermissionDelegate.ContentPermission): GeckoResult<Int> {
                if (!ownsInteractive(s)) return GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
                val result = GeckoResult<Int>()
                val prompt = prompts
                if (prompt == null) return GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
                val question = when (val answer = ContentPermissionPolicy.answer(permission.permission, permission.uri, permission.thirdPartyOrigin)) {
                    ContentPermissionAnswer.Allow -> return GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW)
                    ContentPermissionAnswer.Deny -> return GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
                    is ContentPermissionAnswer.Ask -> answer
                }
                val document = entry.document
                entry.permissions++
                prompt.permission(s, question.title, question.message) { allowed ->
                    entry.permissions = (entry.permissions - 1).coerceAtLeast(0)
                    result.complete(if (allowed && ownsInteractive(s) && pages[tab.id] === entry && entry.document == document) GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW else GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
                }
                return result
            }
            override fun onMediaPermissionRequest(s: GeckoSession, uri: String, video: Array<out GeckoSession.PermissionDelegate.MediaSource>?, audio: Array<out GeckoSession.PermissionDelegate.MediaSource>?, callback: GeckoSession.PermissionDelegate.MediaCallback) {
                if (!ownsInteractive(s)) { callback.reject(); return }
                val kinds = buildSet {
                    if (!video.isNullOrEmpty()) add(SitePermission.CAMERA)
                    if (!audio.isNullOrEmpty()) add(SitePermission.MICROPHONE)
                }
                // A remembered top site's grant must never authorize a third-party frame.
                val host = webHost(entry.page.url ?: entry.tab.url) ?: webHost(uri)
                val sameSite = SiteSettingsStore.key(webHost(uri)) == SiteSettingsStore.key(host)
                val remembered = siteSettings.asked(host, profile.isPrivate, kinds)
                val decision = if (!sameSite && remembered == SiteDecision.ALLOWED) SiteDecision.ASK else remembered
                if (decision == SiteDecision.OFF) { callback.reject(); return }
                val document = entry.document
                val finish: (Boolean) -> Unit = { allowed ->
                    entry.permissions = (entry.permissions - 1).coerceAtLeast(0)
                    if (allowed && ownsInteractive(s) && pages[tab.id] === entry && entry.document == document &&
                        kinds.none { siteSettings.site(host, profile.isPrivate).permissions[it] == SiteDecision.OFF }) {
                        entry.mediaAccessGranted = true
                        update(tab.id, entry) { it.copy(capturingMedia = true, safeToClear = false) }
                        callback.grant(video?.firstOrNull(), audio?.firstOrNull())
                    }
                    else callback.reject()
                }
                entry.permissions++
                if (decision == SiteDecision.ALLOWED) finish(true)
                else {
                    val prompt = prompts
                    if (prompt == null) finish(false)
                    else prompt.permission(s, "Camera and microphone", "Allow $uri to use ${if (!video.isNullOrEmpty()) "your camera" else ""}${if (!video.isNullOrEmpty() && !audio.isNullOrEmpty()) " and " else ""}${if (!audio.isNullOrEmpty()) "your microphone" else ""}?", finish)
                }
            }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(s: GeckoSession, title: String?) { update(tab.id, entry) { it.copy(title = title) } }
            override fun onCloseRequest(s: GeckoSession) {
                if (disposed || pages[tab.id] !== entry || s !== entry.session || !entry.alive) return
                val owner = entry.popupCloseOwner ?: return
                entry.popupCloseOwner = null
                if (owner.epoch != ownershipEpoch || owner.profile != entry.profile) return
                // Background completion may remove its window, but may not steal focus.
                onCloseWindow(tab.id, owner.opener, owner.profile)
            }
            override fun onContextMenu(s: GeckoSession, screenX: Int, screenY: Int, element: GeckoSession.ContentDelegate.ContextElement) {
                if (!ownsInteractive(s)) return
                val link = safeContextUrl(element.linkUri)
                val image = element.srcUri.takeIf { element.type == GeckoSession.ContentDelegate.ContextElement.TYPE_IMAGE }?.let(::safeContextUrl)
                if (link == null && image == null) return
                val request = PageContextMenu(UUID.randomUUID().toString(), tab.id, profile.id, profile.isPrivate,
                    link, image, (element.title ?: element.linkText ?: element.altText ?: link ?: image.orEmpty()).take(512))
                ownedContextMenu = OwnedContextMenu(request, entry, entry.document)
                mutableContextMenu.value = request
            }
            override fun onCrash(s: GeckoSession) { pageLost(tab.id, entry) }
            override fun onKill(s: GeckoSession) { pageLost(tab.id, entry) }
            override fun onFullScreen(s: GeckoSession, fullScreen: Boolean) {
                entry.fullScreen = fullScreen
                if (owns(s)) onFullscreen(fullScreen)
            }
            override fun onExternalResponse(s: GeckoSession, response: WebResponse) {
                if (imageDownloads?.intercept(s, response) == true) return
                if (ownsInteractive(s)) onDownload(response) else response.body?.close()
            }
        }
        session.mediaDelegate = object : GeckoSession.MediaDelegate {
            override fun onRecordingStatusChanged(s: GeckoSession, devices: Array<out GeckoSession.MediaDelegate.RecordingDevice>) {
                if (pages[tab.id] !== entry || !entry.alive) return
                val recording = devices.any { it.status == GeckoSession.MediaDelegate.RecordingDevice.Status.RECORDING }
                update(tab.id, entry) { it.copy(capturingMedia = recording, safeToClear = it.safeToClear && !recording) }
            }
        }
        session.mediaSessionDelegate = pageMedia.delegate(tab.id, session, profile, { entry.document }) {
            pages[tab.id] === entry && entry.alive
        }
        attachBridge(tab.id, entry)
        attachImageDownload(tab.id, entry)
        onSessionCreated(session)
        if (open) session.open(runtime)
        if (!load) return session
        loadPage(tab.id, entry)
        return session
    }

    private fun loadPage(id: String, entry: Entry, verifyDestination: Boolean = false) {
        val session = entry.session
        val saved = entry.savedState ?: if (!entry.profile.isPrivate) readState(id, entry.profile) else null
        if (saved != null) runCatching {
            val restored = requireNotNull(GeckoSession.SessionState.fromString(saved))
            // A checkpoint from before a newly requested navigation cannot turn
            // process recovery into a load of its retired destination.
            if (verifyDestination) check(restored[restored.currentIndex].uri == entry.tab.url)
            captureBackHistory(id, entry, restored, NativeHistoryCaptureSource.RESTORE)
            session.restoreState(restored)
        }
            .onFailure { session.loadUri(entry.tab.url) }
        else session.loadUri(entry.tab.url)
        refreshActiveSessions()
        trimSessions()
    }

    var onFullscreen: (Boolean) -> Unit = {}
    fun tabId(session: GeckoSession): String? = pages.entries.firstOrNull { it.value.session === session }?.key
    fun exitFullscreen() { selected?.let { pages[it]?.session?.exitFullScreen() } }
    fun owns(session: GeckoSession): Boolean = foreground && selected?.let { pages[it]?.let { entry ->
        entry.session === session && entry.alive && !(entry.profile.isPrivate && privateMediaPaused)
    } } == true
    /** Native UI requires visibility. Page text may still be read behind an empty chat. */
    fun ownsInteractive(session: GeckoSession): Boolean = mutableLinkPreview.value == null && owns(session) && (visibleTabs?.contains(tabId(session)) != false)
    val interactiveSelected: String? get() = selected?.takeIf { id -> pages[id]?.session?.let(::ownsInteractive) == true }
    class ExternalActivityOwner internal constructor(internal val tab: String, internal val session: GeckoSession, internal val document: String)
    fun captureExternalActivityOwner(): ExternalActivityOwner? = selected?.let { id -> pages[id]?.takeIf { owns(it.session) }
        ?.let { ExternalActivityOwner(id, it.session, it.document) } }
    fun ownsExternalActivity(owner: ExternalActivityOwner): Boolean = selected == owner.tab &&
        pages[owner.tab]?.let { it.session === owner.session && it.document == owner.document && owns(it.session) } == true
    /** A transfer may outlive its screen, but cannot move to a new document or Private lifetime. */
    fun externalActivityAlive(owner: ExternalActivityOwner, allowLockedPrivate: Boolean = false): Boolean = !disposed && selected == owner.tab && pages[owner.tab]?.let {
        it.alive && it.session === owner.session && it.document == owner.document &&
            (!it.profile.isPrivate || !privateMediaPaused || allowLockedPrivate)
    } == true
    // A public Android dataset authentication Activity may return to this same
    // original form. Current foreground admission blocks delivery while away;
    // document/container/Private revocation separately invalidates its receipt.
    fun background() { revokePagingFrame(); clearHistoryFrames(); nativeFrameBudget.revokeAll(); historyTargets.clear(); fieldAnswerEpoch++; foreground = false; ownedFind?.tab?.let(::clearFind); dismissContextMenu(); popupRequests.values.toList().forEach { it.finish(false) }; prompts?.dismissForBackground(); textRequests.values.forEach { it.answer.cancel() }; textRequests.clear(); domRequests.values.forEach { it.answer.cancel() }; domRequests.clear(); refreshActiveSessions(); saveSessions() }
    fun foreground() {
        val returned = !foreground
        foreground = true; sessionBudget = maxLiveSessions.coerceAtLeast(1)
        if (returned) pages.toList().filterNot { it.second.alive }.forEach { (id, entry) ->
            entry.recovery.foregrounded()
            if (entry.recovery.phase == NativePageRecovery.Phase.DEFERRED)
                update(id, entry) { it.copy(error = null) }
        }
        closedMemories.filter { it.expires < SystemClock.elapsedRealtime() }.toList().forEach(::releaseUndo)
        refreshActiveSessions()
    }
    fun setVisibleTabs(ids: Set<String>, recoveryIds: Set<String> = ids) {
        val front = selected
        if (front != null && front !in ids && visibleTabs?.contains(front) != false) revokeAutofill()
        if (selected !in ids) revokePagingFrame()
        if (selected !in recoveryIds) clearHistoryFrames()
        visibleTabs = ids.toSet(); recoveryTabs = recoveryIds.intersect(ids)
        ownedFind?.takeIf { it.tab !in ids }?.tab?.let(::clearFind)
        if (ownedContextMenu?.request?.tab !in ids) dismissContextMenu()
        popupRequests.values.filter { it.tab !in ids }.toList().forEach { it.finish(false) }
        refreshActiveSessions(); trimSessions()
    }
    fun setTrackingProtection(enabled: Boolean) {
        trackingProtection = enabled
        pages.values.filter { it.alive }.forEach { it.session.settings.useTrackingProtection = enabled }
    }
    fun setPrivateMediaLock(enabled: Boolean) {
        privateMediaRequiresLock = enabled
        if (!enabled) privateMediaPaused = false
        pages.values.filter { it.alive && it.profile.isPrivate }.forEach {
            it.session.settings.suspendMediaWhenInactive = enabled
        }
        if (enabled && !foreground) pausePrivateMedia() else refreshActiveSessions()
    }
    fun mediaCommand(owner: MediaOwner, command: MediaCommand): Boolean = pageMedia.command(owner, command) {
        !it.privateOrigin || !privateMediaPaused
    }
    fun mediaFocus(change: Int, allowed: (MediaOwner) -> Boolean) = pageMedia.focusChange(change) {
        allowed(it) && (!it.privateOrigin || !privateMediaPaused)
    }
    fun mediaBounds(owner: MediaOwner): android.graphics.Rect? = pages[owner.tabId]?.takeIf {
        it.document == owner.document && it.alive
    }?.let { views[owner.tabId]?.get() }?.let { view -> android.graphics.Rect().takeIf { view.getGlobalVisibleRect(it) } }
    fun bindView(tabId: String, view: GeckoView) {
        val entry = pages[tabId] ?: return
        if (view.session !== entry.session) return
        val previousView = views[tabId]?.get()
        if (previousView !== view) {
            entry.historyFirstPaint = false
            if (previousView != null) { revokePagingFrame(); clearHistoryFrames() }
        }
        views[tabId] = WeakReference(view)
        if (previousView !== view || tabId == selected) chromeClipping.apply(tabId, view)
        (view as? HistorySwipeView)?.bindAutofill(entry) {
            val document = entry.document
            val ownership = ownershipEpoch
            val epoch = autofillEpoch
            val privateEpoch = privateAutofillEpoch
            val current = {
                !disposed && ownershipEpoch == ownership && autofillEpoch == epoch &&
                    (!entry.profile.isPrivate || privateAutofillEpoch == privateEpoch) &&
                    pages[tabId] === entry && entry.document == document && ownsInteractive(entry.session) &&
                    views[tabId]?.get() === view && view.session === entry.session &&
                    view.isAttachedToWindow && view.isShown
            }
            current.takeIf { it() }
        }
        // setSession installs GeckoView's uncover callback. Chain only AFTER that call,
        // and never wrap this View repeatedly during ordinary Compose updates.
        if (historyPaintCallbacks[view]?.first !== entry.session) {
            val original = entry.session.compositorController.firstPaintCallback
            val weak = WeakReference(view)
            val callback = Runnable {
                original?.run()
                handler.post {
                    val bound = weak.get()
                    if (bound != null && pages[tabId] === entry && entry.alive && views[tabId]?.get() === bound &&
                        bound.session === entry.session && bound.isAttachedToWindow) {
                        entry.historyFirstPaint = true
                        scheduleHistoryCapture(tabId, entry)
                    }
                }
            }
            historyPaintCallbacks[view] = entry.session to callback
            entry.session.compositorController.firstPaintCallback = callback
        }
        (view as? HistorySwipeView)?.bindHistory(historyTouchChannels[tabId], historySwipeConsumer)
        scheduleCapture(tabId, entry)
        scheduleHistoryCapture(tabId, entry)
    }
    fun unbindView(tabId: String, view: GeckoView) {
        (view as? HistorySwipeView)?.bindAutofill(null, null)
        if (views[tabId]?.get() === view) { revokePagingFrame(); clearHistoryFrames(); (view as? HistorySwipeView)?.bindHistory(null, null); views.remove(tabId) }
        historyPaintCallbacks.remove(view)
    }

    /** The bottom chrome's covered space, in this engine's own screen pixels.
     * A page's bottom-fixed elements stay above it (GeckoView's dynamic
     * toolbar pair; Chromium's browser controls take the same numbers). */
    private val chromeClipping = GeckoChromeClipping(
        { view, px -> (view as GeckoView).setDynamicToolbarMaxHeight(px) },
        { view, px -> (view as GeckoView).setVerticalClipping(px) })

    /** GeckoView wants the obscured height relative to the toolbar maximum.
     * Numbers come from the chrome layer in screen pixels; 0/0 clears. Each
     * report belongs to the pane that reported it (its tab id), never to
     * whichever pane happens to be selected. A pane without a front tab has
     * no engine view of its own; its numbers wait under the empty key. */
    fun setChromeClipping(owner: String?, obscuredPx: Int, maxPx: Int) {
        chromeClipping.update(owner ?: "", obscuredPx, maxPx, owner?.let { views[it]?.get() })
    }

    internal fun setHistorySwipeConsumer(consumer: HistorySwipeConsumer?) {
        if (consumer?.current() != true) clearHistoryFrames()
        historySwipeConsumer = consumer
        views.forEach { (id, reference) -> (reference.get() as? HistorySwipeView)?.bindHistory(historyTouchChannels[id], consumer) }
    }

    /** One exact native entry/document/isolated port. Only bounded enums/counts/nonces pass here. */
    private inner class OwnedHistoryTouchChannel(private val id: String, private val entry: Entry,
        private val port: WebExtension.Port, private val document: String, private val content: String) : HistoryTouchChannel {
        override val identity: Any = Any()
        private val observers = linkedSetOf<(HistoryTouchReceipt) -> Unit>()
        private var closed = false
        override fun current() = !closed && !disposed && pages[id] === entry && entry.alive && entry.port === port &&
            entry.document == document && entry.contentDocument == content && port.sender.session === entry.session && port.sender.isTopLevel
        override fun interactive() = current() && !entry.page.loading && ownsInteractive(entry.session) &&
            views[id]?.get()?.let { it.session === entry.session && it.isAttachedToWindow && it.isShown } == true
        private fun post(command: String, fill: (JSONObject) -> Unit = {}): Boolean {
            if (!current()) return false
            return try {
                val value = JSONObject().put("command", command).put("expectedDocument", content)
                fill(value); port.postMessage(value); true
            } catch (_: Exception) { false }
        }
        override fun sync() = post("history-sync")
        override fun arm(request: HistoryArmRequest) = interactive() && post("history-arm") {
            it.put("serial", request.serial).put("token", request.token).put("afterSequence", request.afterSequence)
        }
        override fun disarm(serial: Long) { post("history-disarm") { it.put("serial", serial) } }
        override fun observe(receive: (HistoryTouchReceipt) -> Unit): AutoCloseable {
            observers += receive
            return AutoCloseable { observers -= receive }
        }
        fun receive(value: JSONObject) {
            if (!current() || value.optString("documentID") != content) return
            fun integer(key: String): Long? = (value.opt(key) as? Number)?.toDouble()?.takeIf {
                it.isFinite() && it >= 0 && it <= HistorySwipePolicy.MAX_SEQUENCE && it % 1.0 == 0.0
            }?.toLong()
            val phase = when (value.optString("phase")) {
                "sync" -> HistoryTouchPhase.SYNC; "armed" -> HistoryTouchPhase.ARMED
                "start" -> HistoryTouchPhase.START; "change" -> HistoryTouchPhase.CHANGE
                "end" -> HistoryTouchPhase.END; "cancel" -> HistoryTouchPhase.CANCEL
                else -> return
            }
            val sequence = integer("sequence") ?: return
            val contacts = integer("contacts")?.takeIf { it in 0..10 }?.toInt() ?: return
            val serial = integer("serial") ?: return
            val token = (value.opt("token") as? String)?.takeIf { it.matches(Regex("[a-f0-9]{32}")) }
            if ((serial == 0L) != (token == null)) return
            val receipt = HistoryTouchReceipt(phase, sequence, contacts, serial, token,
                value.opt("accepted") as? Boolean ?: false, value.opt("held") as? Boolean ?: true)
            observers.toList().forEach { it(receipt) }
        }
        fun close() { closed = true; observers.clear() }
    }
    private fun revokePagingFrame() {
        pagingCaptureLifetime.invalidate()
        pagingFrame?.close(); pagingFrame = null
        pagingCaptureAnswer?.complete(PagingCaptureResult(PagingCaptureOutcome.REVOKED)); pagingCaptureAnswer = null
    }

    private fun clearHistoryFrames() {
        historyCaptureJob?.cancel(); historyCaptureJob = null
        historyKeyRequests.values.toList().forEach { it.answer.cancel() }; historyKeyRequests.clear()
        historyFrameOwner?.historyCapturedRevision = -1
        historyFrames?.clear(); historyFrames = null; historyFrameOwner = null
    }

    private suspend fun historyKey(id: String, entry: Entry): HistoryNavigationKey? {
        val port = entry.port ?: return null
        val content = entry.contentDocument ?: return null
        if (historyKeyRequests.isNotEmpty() || pages[id] !== entry || !entry.alive) return null
        val nonce = UUID.randomUUID().toString().replace("-", "")
        val pending = HistoryKeyRequest(entry, entry.document, content, port, CompletableDeferred())
        historyKeyRequests[nonce] = pending
        return try {
            port.postMessage(JSONObject().put("command", "history-key").put("expectedDocument", content).put("request", nonce))
            withTimeoutOrNull(400) { pending.answer.await() }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { null }
        finally { if (historyKeyRequests[nonce] === pending) historyKeyRequests.remove(nonce); pending.answer.cancel() }
    }

    /** One coalesced capture after owned initial paint/PageStop or settled compositor scroll.
     * The first-paint callback is only a compositor event, never a key/presentation fence.
     * A same-document change disqualifies all images for this visit, including A→B→A. */
    private fun scheduleHistoryCapture(id: String, entry: Entry, scrollSettled: Boolean = false) {
        if (selected != id || !entry.alive || entry.historyImagesDisabled || !entry.historyPageStopped ||
            !entry.historyFirstPaint || entry.historyIdentity == null || entry.contentDocument == null ||
            entry.historyCapturedRevision == entry.historyViewportRevision ||
            entry.page.loading || historySwipeConsumer?.current() != true) return
        if (historyCaptureJob?.isActive == true && !scrollSettled) return
        if (scrollSettled) historyCaptureJob?.cancel()
        historyCaptureJob = historyCaptureScope.launch {
            delay(if (scrollSettled) 250 else 80)
            val view = views[id]?.get() ?: return@launch
            val document = entry.document; val ownership = ownershipEpoch; val revision = entry.historyViewportRevision
            val width = view.width; val height = view.height
            fun current() = !disposed && ownershipEpoch == ownership && pages[id] === entry && entry.alive &&
                entry.document == document && !entry.historyImagesDisabled && entry.historyPageStopped && entry.historyFirstPaint &&
                entry.historyViewportRevision == revision && !entry.page.loading && ownsInteractive(entry.session) &&
                historySwipeConsumer?.current() == true && views[id]?.get() === view && view.session === entry.session &&
                view.isAttachedToWindow && view.isShown && view.width == width && view.height == height
            if (!current() || !PagingCaptureLifetime.permits(width, height)) return@launch
            val key = historyKey(id, entry)
            if (!current()) return@launch
            val candidate = HistoryPaintCandidate.create(entry.historyIdentity, key)
            if (candidate == null) {
                entry.historyImagesDisabled = true; entry.historyCaptureStage = "KEY_UNPROVEN"
                if (historyFrameOwner === entry) historyFrames?.clear()
                return@launch
            }
            if (historyFrameOwner !== entry) {
                historyFrames?.clear()
                historyFrameOwner = entry
                historyFrames = HistoryFrameStore(entry.session) { it.close() }
            }
            val store = historyFrames ?: return@launch
            // Release only this visit's previous owner reference before a replacement.
            store.removeCurrent(candidate.snapshot)
            var reservation = nativeFrameBudget.reserve()
            if (reservation == null) { store.evictOldest(); reservation = nativeFrameBudget.reserve() }
            val budget = reservation ?: run { entry.historyCaptureStage = "BUDGET_BUSY"; return@launch }
            val physical = nativeFrameCaptureArbiter.acquire()
                ?: run { budget.unpublishedFinished(); entry.historyCaptureStage = "NATIVE_BUSY"; return@launch }
            check(budget.startNative())
            entry.historyCaptureStage = "CAPTURING"
            val answer = CompletableDeferred<Bitmap?>()
            var received: Bitmap? = null
            var nativeReturned = false
            var released = false
            var published = false
            fun refused(bitmap: Bitmap?) {
                bitmap?.recycle(); budget.unpublishedFinished(); released = true
            }
            try {
                try { view.capturePixels().accept({ bitmap ->
                    // Public GeckoResult completion may run on any thread.
                    handler.post {
                        nativeFrameCaptureArbiter.finish(physical); nativeReturned = true
                        if (answer.isCompleted || !current()) { refused(bitmap); answer.complete(null) }
                        else { received = bitmap; answer.complete(bitmap) }
                    }
                }, { handler.post {
                    nativeFrameCaptureArbiter.finish(physical); nativeReturned = true
                    if (answer.isCompleted) { budget.unpublishedFinished(); released = true }
                    else answer.complete(null)
                } }) } catch (_: Exception) {
                    nativeFrameCaptureArbiter.finish(physical); nativeReturned = true; answer.complete(null)
                }
                val bitmap = withTimeoutOrNull(400) { answer.await() } ?: return@launch
                if (!current() || bitmap.width != width || bitmap.height != height ||
                    !HistoryFrameStore.permits(width, height, bitmap.allocationByteCount.toLong())) return@launch
                val after = historyKey(id, entry)
                if (!current() || !candidate.current(entry.historyIdentity, after)) {
                    entry.historyCaptureStage = "KEY_CHANGED"; return@launch
                }
                val frame = budget.publish(bitmap) ?: return@launch
                published = true
                if (!store.retain(entry.session, candidate.snapshot, width, height, bitmap.allocationByteCount.toLong(), frame)) frame.close()
                else if (!entry.profile.isPrivate) {
                    val adopted = snapshots.putFromPublished(id, bitmap, entry.page.url ?: entry.tab.url, entry.profile.id, document, entry.thumbnailSession)
                    if (adopted && snapshots.state.value[id]?.document == document) entry.capturedAt = SystemClock.uptimeMillis()
                }
                entry.historyCaptureStage = "RETAINED_INITIAL_DOCUMENT"
                entry.historyCapturedRevision = revision
            } finally {
                if (!answer.isCompleted) answer.cancel()
                if (!published && !released) {
                    if (nativeReturned) refused(received) else budget.revoke()
                }
            }
        }
    }

    /** Fixed finite diagnostics only. The opaque keys and raw SessionState never leave RAM. */
    internal fun historyPixelState(id: String): HistoryPixelState {
        val entry = pages[id]
        return HistoryPixelState(entry?.historyFirstPaint == true, entry?.historyPageStopped == true,
            entry?.historyImagesDisabled == true, if (historyFrameOwner === entry) historyFrames?.count ?: 0 else 0,
            nativeFrameBudget.slots, nativeFrameCaptureArbiter.busy, entry?.historyCaptureStage ?: "ABSENT")
    }

    /** Existing owned current pixels for actual native fixtures; no capture/export side effect. */
    internal fun currentHistoryPixels(id: String): Bitmap? {
        val entry = pages[id] ?: return null
        val snapshot = entry.historyIdentity ?: return null
        if (historyFrameOwner !== entry || !ownsInteractive(entry.session) || entry.historyImagesDisabled || entry.page.loading) return null
        val view = views[id]?.get() ?: return null
        return historyFrames?.frame(entry.session, snapshot.shown, view.width, view.height)?.valueIfCurrent()
    }

    /** Cached exact neighbor only, after a new nonce-bound native/Xray agreement. Never a
     * navigation, URL match, hidden preview, screenshot of another tab, or SPA image. */
    internal suspend fun historySwipePixels(target: NativeHistorySwipeTarget, sourceCurrent: () -> Boolean): HistorySwipePixels? = withContext(Dispatchers.Main.immediate) {
        val entry = historyTargets[target] ?: return@withContext null
        if (!sourceCurrent() || !historySwipeCurrent(target) || historyFrameOwner !== entry || entry.historyImagesDisabled) return@withContext null
        val view = views[entry.tab.id]?.get() ?: return@withContext null
        val width = view.width; val height = view.height
        val document = entry.document; val ownership = ownershipEpoch
        val port = entry.port; val content = entry.contentDocument
        val key = historyKey(entry.tab.id, entry)
        val candidate = HistoryPaintCandidate.create(entry.historyIdentity, key) ?: return@withContext null
        val neighbor = candidate.snapshot.neighbor(target.direction) ?: return@withContext null
        val frame = historyFrames?.frame(entry.session, neighbor, width, height) ?: return@withContext null
        fun current() = ownershipEpoch == ownership && entry.document == document && entry.port === port && entry.contentDocument == content && !entry.historyImagesDisabled &&
            sourceCurrent() && historySwipeCurrent(target) && views[entry.tab.id]?.get() === view && view.width == width && view.height == height &&
            entry.historyIdentity?.let(candidate.snapshot::samePosition) == true
        if (!current() || frame.valueIfCurrent() == null) return@withContext null
        HistorySwipePixels({ frame.valueIfCurrent() }, ::current)
    }

    /** Capture only this currently drawn selected native viewport. Caller authority is rechecked
     * synchronously at request, native completion and every later bitmap projection. */
    suspend fun capturePagingFrame(tab: BrowserTab, profile: WebsiteProfile,
        sourceCurrent: () -> Boolean): PagingCaptureResult = withContext(Dispatchers.Main.immediate) {
        val entry = pages[tab.id] ?: return@withContext PagingCaptureResult(PagingCaptureOutcome.NOT_CURRENT)
        val view = views[tab.id]?.get() ?: return@withContext PagingCaptureResult(PagingCaptureOutcome.VIEW_UNAVAILABLE)
        val document = entry.document
        val ownership = ownershipEpoch
        val width = view.width; val height = view.height
        fun source() = !disposed && foreground && ownershipEpoch == ownership && pages[tab.id] === entry &&
            entry.alive && entry.document == document && entry.profile == profile && entry.tab.id == tab.id &&
            (entry.page.url ?: entry.tab.url) == tab.url && !entry.page.loading && ownsInteractive(entry.session) &&
            !(profile.isPrivate && privateMediaPaused) && views[tab.id]?.get() === view && view.session === entry.session &&
            view.isAttachedToWindow && view.width == width && view.height == height && sourceCurrent()
        if (!source()) return@withContext PagingCaptureResult(PagingCaptureOutcome.NOT_CURRENT)
        // A cancelled GeckoResult does not promise that native pixel work was cancelled.
        // Keep one physical request outstanding even when its UI lease has been revoked.
        if (!PagingCaptureLifetime.permits(width, height)) return@withContext PagingCaptureResult(PagingCaptureOutcome.DIMENSIONS_REFUSED)
        // Readiness is checked by public capturePixels(); GeckoSession's getter is
        // package-private. Its failed GeckoResult follows the bounded failure path below.
        // Pager and retained history use the same two logical allocation reservations.
        // Eviction drops owner references, never recycles pixels still held by a renderer.
        var reservation = nativeFrameBudget.reserve()
        if (reservation == null) { historyFrames?.evictOldest(); reservation = nativeFrameBudget.reserve() }
        val budget = reservation ?: return@withContext PagingCaptureResult(PagingCaptureOutcome.UNAVAILABLE)
        if (!pagingCaptureLifetime.tryBeginNative()) { budget.unpublishedFinished(); return@withContext PagingCaptureResult(PagingCaptureOutcome.UNAVAILABLE) }
        check(budget.startNative())
        revokePagingFrame()
        val token = pagingCaptureLifetime.begin()
        val answer = CompletableDeferred<PagingCaptureResult>()
        pagingCaptureAnswer = answer
        fun current() = pagingCaptureLifetime.current(token) && source()
        var delivered = false
        try {
            try { view.capturePixels().accept({ bitmap -> handler.post {
                pagingCaptureLifetime.nativeFinished()
                if (bitmap == null) { budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.CAPTURE_FAILED)) }
                else if (!current() || answer.isCompleted) { bitmap.recycle(); budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.REVOKED)) }
                else if (bitmap.width != width || bitmap.height != height || bitmap.allocationByteCount.toLong() > PagingCaptureLifetime.MAX_BYTES) {
                    bitmap.recycle(); budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.DIMENSIONS_REFUSED))
                } else {
                    val pixels = budget.publish(bitmap)
                    if (pixels == null) { bitmap.recycle(); budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.REVOKED)); return@post }
                    val frame = PagingFrame(bitmap, { current() && pixels.valueIfCurrent() != null }, pixels::close)
                    pagingFrame = frame
                    answer.complete(PagingCaptureResult(PagingCaptureOutcome.READY, frame))
                }
            } }, { handler.post { pagingCaptureLifetime.nativeFinished(); budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.CAPTURE_FAILED)) } }) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { pagingCaptureLifetime.nativeFinished(); budget.unpublishedFinished(); answer.complete(PagingCaptureResult(PagingCaptureOutcome.CAPTURE_FAILED)) }
            val result = withTimeoutOrNull(PagingCaptureLifetime.DEADLINE_MILLIS) { answer.await() }
                ?: PagingCaptureResult(PagingCaptureOutcome.TIMED_OUT)
            if (result.frame != null && !current()) {
                result.frame.close()
                PagingCaptureResult(PagingCaptureOutcome.REVOKED)
            } else { delivered = result.frame != null; result }
        } finally {
            if (pagingCaptureAnswer === answer) {
                pagingCaptureAnswer = null
                // Cancelled/timed-out native work may complete later. Its unpublished pixels
                // will be recycled by the callback and can never become another owner's frame.
                if (!delivered && pagingCaptureLifetime.current(token)) {
                    budget.revoke()
                    pagingCaptureLifetime.invalidate(); pagingFrame?.close(); pagingFrame = null
                }
                if (!answer.isCompleted) answer.cancel()
            }
        }
    }
    /** An Activity may go away while its native sessions remain in the retained owner. */
    fun rebindPrompts(next: NativePagePrompts?) {
        prompts?.dismiss()
        prompts = next
        pages.values.filter { it.alive }.forEach { it.session.promptDelegate = next }
    }
    fun releaseViews() {
        revokePagingFrame()
        clearHistoryFrames(); nativeFrameBudget.revokeAll()
        setHistorySwipeConsumer(null)
        views.values.mapNotNull { it.get() }.distinct().forEach { it.releaseSession() }
        views.clear(); historyPaintCallbacks.clear()
        visibleTabs = emptySet()
        recoveryTabs = emptySet()
        refreshActiveSessions()
    }
    fun onTrimMemory(level: Int) {
        revokePagingFrame()
        clearHistoryFrames(); nativeFrameBudget.revokeAll()
        sessionBudget = when {
            level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> 2
            level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> 3
            else -> maxLiveSessions.coerceAtLeast(1)
        }
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) snapshots.clear()
        trimSessions()
    }
    private fun refreshActiveSessions() {
        pages.forEach { (id, entry) -> if (entry.alive) entry.session.setActive(foreground &&
            !(entry.profile.isPrivate && privateMediaPaused) && (visibleTabs?.contains(id) ?: (selected == id))) }
        pages.filterValues { !it.alive }.toList().forEach { (id, entry) -> scheduleRecovery(id, entry) }
        publishTranslationPage()
    }
    private fun publishTranslationPage() {
        val id = selected
        val entry = id?.let(pages::get)
        val url = entry?.page?.url
        translationPage.value = if (!disposed && id != null && entry != null && entry.alive && owns(entry.session) &&
            !entry.page.loading && !entry.page.readerEnabled && entry.port != null && entry.contentDocument != null &&
            url != null && translationHost(url) != null) TranslationPage(
                TranslationOwner(id, entry.document, entry.profile.isPrivate, entry.contentDocument), url) else null
    }
    private fun leaveFullscreen(next: String) {
        if (selected == next) return
        selected?.let { pages[it] }?.takeIf { it.fullScreen }?.let {
            it.fullScreen = false
            runCatching { it.session.exitFullScreen() }
            onFullscreen(false)
        }
    }
    fun prepareWindow(tab: BrowserTab, profile: WebsiteProfile, select: Boolean): GeckoSession {
        if (select) {
            ownedFind?.takeIf { it.tab != tab.id || it.entry.profile != profile }?.tab?.let(::clearFind)
            popupRequests.values.filter { it.tab != tab.id }.toList().forEach { it.finish(false) }
            leaveFullscreen(tab.id)
            prompts?.dismiss()
            dismissContextMenu()
            selected?.let { pages[it]?.session?.setActive(false) }
            selected = tab.id
        }
        val created = session(tab, profile, load = false, open = false)
        if (select) onSessionActivated(created)
        return created
    }
    fun dispose() {
        imageDownloads?.close(); imageDownloads = null
        background()
        prompts?.dismiss()
        popupRequests.values.toList().forEach { it.finish(false) }
        pageMedia.close()
        closedMemories.toList().forEach(::releaseUndo)
        val old = pages.values.toList()
        pages.clear()
        suspended.clear(); views.clear(); snapshots.close(); disposed = true
        publishTranslationPage()
        handler.removeCallbacksAndMessages(null)
        historyCaptureScope.cancel(); historyPaintCallbacks.clear()
        old.forEach { retireBridge(it); onSessionClosed(it.session); if (it.alive) it.session.close() }
        privateKeepers.toMap().forEach { (profile, keeper) -> retirePrivateKeeper(profile, keeper) }
        mutableConnections.value = emptyMap(); siteSettings.forgetPrivate()
        stateWriter.shutdown()
    }

    private fun update(id: String, owner: Entry? = null, change: (EnginePageState) -> EnginePageState) {
        val entry = pages[id] ?: return
        if (owner != null && owner !== entry) return
        entry.page = change(entry.page)
        revalidateLinkPreview()
        onState(id, entry.page)
        publishTranslationPage()
    }

    private fun popupSource(entry: Entry): String = entry.page.url?.takeIf { Uri.parse(it).scheme in setOf("http", "https") }
        ?: entry.popupOrigin?.page ?: entry.page.url ?: entry.tab.url
    private fun popupCurrent(id: String, entry: Entry, document: String, origin: PopupOrigin?): Boolean =
        !disposed && pages[id] === entry && entry.alive && entry.document == document && owns(entry.session) &&
            visibleTabs?.contains(id) != false && (origin == null || pages[origin.entry.tab.id] === origin.entry &&
            origin.entry.alive && origin.entry.document == origin.document && origin.entry.profile == entry.profile)

    private fun decidePopup(id: String, entry: Entry, url: String, origin: PopupOrigin? = null,
                            remember: Boolean = false): GeckoResult<AllowOrDeny> {
        val document = entry.document; val answer = GeckoResult<AllowOrDeny>()
        if (!popupCurrent(id, entry, document, origin)) return GeckoResult.fromValue(AllowOrDeny.DENY)
        val owner = UUID.randomUUID().toString(); var finished = false
        val timeout = Runnable { popupRequests[owner]?.finish?.invoke(false) }
        fun finish(allowed: Boolean) {
            if (finished) return
            finished = true; handler.removeCallbacks(timeout); popupRequests.remove(owner)
            val permitted = allowed && popupCurrent(id, entry, document, origin)
            if (permitted && remember) {
                entry.popupPermits.removeAll { it.expires < SystemClock.uptimeMillis() }
                while (entry.popupPermits.size >= 16) entry.popupPermits.removeAt(0)
                entry.popupPermits += PopupPermit(url, document, SystemClock.uptimeMillis() + 5_000)
            }
            answer.complete(if (permitted) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
        }
        popupRequests[owner] = PendingPopup(id, ::finish)
        handler.postDelayed(timeout, 2_500)
        try {
            popupPolicy(ShieldPopupRequest(owner, url, origin?.page ?: popupSource(entry), entry.profile.isPrivate))
                .accept({ allowed -> finish(allowed == true) }, { finish(false) })
        } catch (_: Exception) { finish(false) }
        return answer
    }

    private fun safeToEvict(id: String, entry: Entry): Boolean = entry.alive && selected != id &&
        (pinsMaySleep || !pinnedSessions.holds(id, selected, sessionBudget < maxLiveSessions.coerceAtLeast(1))) &&
        visibleTabs?.contains(id) != true && views[id]?.get()?.isAttachedToWindow != true &&
        !entry.page.loading && entry.page.safeToClear && !entry.page.hasFormEdits && !entry.editing &&
        !entry.page.frameUncertain && !entry.page.playingMedia && !entry.page.capturingMedia &&
        !entry.fullScreen && entry.permissions == 0 && prompts?.hasPending(entry.session) != true &&
        !entry.tab.hasDraft && !entry.tab.hasTask &&
        textRequests.values.none { it.tab == id } && domRequests.values.none { it.tab == id }

    private fun trimSessions() {
        if (disposed || liveSessionCount <= sessionBudget) return
        val pending = pages.values.count { it.eviction != null }
        val needed = (liveSessionCount - sessionBudget - pending).coerceAtLeast(0)
        pages.entries.filter { it.value.eviction == null && safeToEvict(it.key, it.value) }
            .sortedBy { it.value.lastUsed }.take(needed).forEach { (id, entry) ->
                val port = entry.port ?: return@forEach
                val token = UUID.randomUUID().toString()
                entry.eviction = token; entry.evictionReady = false
                runCatching { port.postMessage(JSONObject().put("command", "safety").put("request", token)) }
                    .onFailure { entry.eviction = null }
                handler.postDelayed({ if (pages[id] === entry && entry.eviction == token) {
                    entry.eviction = null; entry.evictionReady = false
                } }, 4000)
            }
    }
    private fun evict(id: String, entry: Entry) {
        if (pages[id] !== entry || entry.savedState == null || !safeToEvict(id, entry)) return
        trace("evict ${entry.tab.place} ${entry.tab.url}")
        if (entry.profile.isPrivate) {
            val profile = entry.profile
            val document = entry.document
            val content = entry.contentDocument
            val state = entry.savedState
            val tab = entry.tab
            val epoch = ownershipEpoch
            val token = entry.eviction ?: return
            val keeper = keepPrivateProfile(profile)
            val accepted = keeper.readiness.afterReady(id, SystemClock.elapsedRealtime(), current = {
                !disposed && privateKeepers[profile.id] === keeper && pages[id] === entry &&
                    keeper.session.isOpen && keeper.session.settings.usePrivateMode && keeper.session.settings.contextId == profile.id && entry.session.isOpen &&
                    ownershipEpoch == epoch && entry.profile == profile && entry.document == document &&
                    entry.contentDocument == content && entry.savedState == state && entry.tab == tab &&
                    entry.eviction == token && entry.evictionReady && liveSessionCount > sessionBudget && safeToEvict(id, entry)
            }, commit = { evictReady(id, entry) })
            if (!accepted) { entry.eviction = null; entry.evictionReady = false }
            return
        }
        evictReady(id, entry)
    }
    private fun evictReady(id: String, entry: Entry) {
        if (disposed || pages[id] !== entry || entry.savedState == null || !safeToEvict(id, entry)) return
        if (historyFrameOwner === entry) clearHistoryFrames()
        dismissContextMenu(id)
        mutableConnections.value = mutableConnections.value - id
        suspended[id] = Suspended(entry.tab, entry.profile, entry.savedState, entry.page)
        pages.remove(id); views.remove(id)
        pageMedia.forget(id)
        retireBridge(entry); entry.alive = false
        imageDownloads?.detach(entry.session)
        onSessionClosed(entry.session); entry.session.close()
        cancelDocumentRequests(id)
        trimSessions()
    }
    private fun keepPrivateProfile(profile: WebsiteProfile): PrivateKeeper {
        check(profile.isPrivate && !disposed)
        privateKeepers[profile.id]?.let { existing ->
            if (existing.session.isOpen) return existing
            retirePrivateKeeper(profile.id, existing)
        }
        val native = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(true)
            .contextId(profile.id).suspendMediaWhenInactive(true).build())
        val keeper = PrivateKeeper(native, PrivateKeeperReadiness(++privateKeeperGeneration, SystemClock.elapsedRealtime() + 4_000))
        privateKeepers[profile.id] = keeper
        privateKeeperLast = "OPENING"
        val generation = keeper.readiness.generation
        native.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(s: GeckoSession, url: String) {
                if (!disposed && privateKeepers[profile.id] === keeper && s === native && url == "about:blank") keeper.blankStarted = true
            }
            override fun onPageStop(s: GeckoSession, success: Boolean) {
                if (disposed || privateKeepers[profile.id] !== keeper || s !== native) return
                val ready = success && keeper.blankStarted && native.isOpen && native.settings.usePrivateMode &&
                    native.settings.contextId == profile.id
                if (!keeper.readiness.acknowledge(generation, ready, SystemClock.elapsedRealtime())) {
                    if (keeper.readiness.phase == PrivateKeeperReadiness.Phase.TIMED_OUT) {
                        privateKeeperRejected++; privateKeeperLast = "TIMED_OUT"; retirePrivateKeeper(profile.id, keeper)
                    }
                    return
                }
                keeper.timeout?.let(handler::removeCallbacks); keeper.timeout = null
                privateKeeperLast = keeper.readiness.phase.name
                if (keeper.readiness.phase == PrivateKeeperReadiness.Phase.READY) privateKeeperAcks++
                else { privateKeeperRejected++; retirePrivateKeeper(profile.id, keeper) }
            }
        }
        // This session cannot navigate to a web origin, request a popup, or obtain media.
        native.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(s: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> =
                GeckoResult.fromValue(if (!disposed && privateKeepers[profile.id] === keeper && s === native && request.uri == "about:blank") AllowOrDeny.ALLOW else AllowOrDeny.DENY)
        }
        native.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onCrash(s: GeckoSession) { stopped(s) }
            override fun onKill(s: GeckoSession) { stopped(s) }
            private fun stopped(s: GeckoSession) {
                if (!disposed && s === native && privateKeepers[profile.id] === keeper) {
                    privateKeeperLast = "FAILED"; privateKeeperRejected++; retirePrivateKeeper(profile.id, keeper)
                }
            }
        }
        val timeout = Runnable {
            if (!disposed && privateKeepers[profile.id] === keeper) {
                keeper.readiness.expire(SystemClock.elapsedRealtime())
                if (keeper.readiness.phase == PrivateKeeperReadiness.Phase.TIMED_OUT) {
                    privateKeeperRejected++; privateKeeperLast = "TIMED_OUT"
                    retirePrivateKeeper(profile.id, keeper)
                }
            }
        }
        keeper.timeout = timeout
        try { native.open(runtime); native.setActive(false); native.loadUri("about:blank"); handler.postDelayed(timeout, 4_000) }
        catch (_: Exception) {
            privateKeeperLast = "FAILED"; privateKeeperRejected++; retirePrivateKeeper(profile.id, keeper)
            // Lock/capturing paths must still close the recording native page immediately.
            // Eviction sees a revoked gate and keeps its original native page alive.
        }
        return keeper
    }
    private fun retirePrivateKeeper(profile: String, keeper: PrivateKeeper) {
        // A late old callback must not close a replacement keeper or reopen a jar.
        if (privateKeepers[profile] !== keeper) return
        privateKeepers.remove(profile)
        keeper.readiness.revoke()
        keeper.timeout?.let(handler::removeCallbacks); keeper.timeout = null
        if (keeper.session.isOpen) keeper.session.close()
    }
    /** Fixed lifecycle metadata only, never a profile, account, document, cookie or URL. */
    fun privateKeeperDiagnostics(): JSONObject = JSONObject().put("last", privateKeeperLast)
        .put("opening", privateKeepers.values.count { it.readiness.phase == PrivateKeeperReadiness.Phase.OPENING }.coerceIn(0, 32))
        .put("ready", privateKeepers.values.count { it.readiness.phase == PrivateKeeperReadiness.Phase.READY }.coerceIn(0, 32))
        .put("pending", privateKeepers.values.sumOf { it.readiness.pendingCount }.coerceIn(0, 1_000))
        .put("acknowledged", privateKeeperAcks.coerceIn(0, 1_000_000)).put("rejected", privateKeeperRejected.coerceIn(0, 1_000_000))
    private fun pageLost(id: String, entry: Entry) {
        revokePagingFrame()
        if (pages[id] !== entry || !entry.alive) return
        if (historyFrameOwner === entry) clearHistoryFrames()
        dismissContextMenu(id)
        mutableConnections.value = mutableConnections.value - id
        pageMedia.forget(id)
        entry.alive = false; entry.eviction = null; entry.evictionReady = false
        imageDownloads?.detach(entry.session)
        if (prompts?.hasPending(entry.session) == true) prompts?.dismiss()
        retireBridge(entry)
        cancelDocumentRequests(id)
        onSessionClosed(entry.session)
        if (entry.fullScreen && selected == id) { entry.fullScreen = false; onFullscreen(false) }
        entry.recovery.stopped(away = !foreground || !shownForRecovery(id))
        update(id, entry) { it.copy(loading = false, safeToClear = false, capturingMedia = false,
            error = if (entry.recovery.phase == NativePageRecovery.Phase.FAILED) "The page stopped. Reload to restore it." else null) }
        scheduleRecovery(id, entry)
    }
    private fun shownForRecovery(id: String): Boolean =
        (visibleTabs?.contains(id) ?: (selected == id)) && (recoveryTabs?.contains(id) ?: true)
    private fun recoveryEligible(id: String, entry: Entry) = !disposed && foreground && pages[id] === entry &&
        !entry.alive && entry.profile.id !in clearingProfiles && !(entry.profile.isPrivate && privateMediaPaused) &&
        shownForRecovery(id)

    private fun scheduleRecovery(id: String, entry: Entry) {
        val ticket = entry.recovery.queue(recoveryEligible(id, entry)) ?: return
        val epoch = ownershipEpoch; val document = entry.document; val tab = entry.tab
        handler.post {
            if (disposed || pages[id] !== entry || ownershipEpoch != epoch || entry.document != document ||
                entry.tab.url != tab.url || entry.profile.id in clearingProfiles) return@post
            if (!entry.recovery.begin(ticket, recoveryEligible(id, entry))) return@post
            runCatching { recover(id, automatically = true) }.onFailure {
                val current = pages[id]
                if (current?.recovery === entry.recovery) {
                    current.recovery.failed()
                    update(id, current) { it.copy(loading = false, error = "The page stopped. Reload to restore it.") }
                }
            }
        }
    }

    /** Finite native fixture state, independent of private page or process identifiers. */
    fun recoveryStatus(id: String): String = pages[id]?.recovery?.phase?.name ?: "ABSENT"

    private fun recover(id: String, automatically: Boolean = false, destination: BrowserTab? = null): GeckoSession? {
        val old = pages[id] ?: return null
        if (old.alive) return old.session
        val epoch = ownershipEpoch
        if (!automatically) old.recovery.reset()
        pages.remove(id)
        val tab = destination ?: old.tab
        if (destination == null) suspended[id] = Suspended(tab, old.profile, old.savedState, old.page)
        else suspended.remove(id)
        val result = session(tab, old.profile, load = false)
        // App-owned session-created callbacks may synchronously replace/revoke this
        // owner. A provisional blank session must not load its retired document.
        val replacement = pages[id]?.takeIf { it.session === result && it.profile == old.profile } ?: return null
        if (disposed || ownershipEpoch != epoch) return null
        replacement.recovery = old.recovery
        update(id, replacement) { page -> page.copy(loading = true, error = null) }
        if (pages[id] !== replacement || ownershipEpoch != epoch) return null
        if (destination == null) loadPage(id, replacement, verifyDestination = true) else result.loadUri(tab.url)
        if (selected == id) onSessionActivated(result)
        refreshActiveSessions()
        return result
    }
    private fun scheduleCapture(id: String, entry: Entry) {
        if (entry.profile.isPrivate || entry.capturePending || !entry.alive || entry.page.loading ||
            views[id]?.get() == null || SystemClock.uptimeMillis() - entry.capturedAt < 1500) return
        val document = entry.document
        val ownership = ownershipEpoch
        val scheduledAt = SystemClock.uptimeMillis()
        entry.capturePending = true
        entry.captureStage = "scheduled"
        handler.postDelayed({
            val view = views[id]?.get()
            fun current() = !disposed && ownershipEpoch == ownership && foreground && pages[id] === entry && entry.alive &&
                !entry.profile.isPrivate && entry.document == document && !entry.page.loading &&
                (visibleTabs?.contains(id) ?: (selected == id)) && view?.session === entry.session && view?.isAttachedToWindow == true
            if (!current() || view == null) { entry.capturePending = false; entry.captureStage = "not-current"; return@postDelayed }
            if (entry.capturedAt >= scheduledAt && snapshots.state.value[id]?.document == document) {
                entry.capturePending = false; entry.captureStage = "stored-from-history"; return@postDelayed
            }
            if (!PagingCaptureLifetime.permits(view.width, view.height)) { entry.capturePending = false; entry.captureStage = "dimensions-refused"; return@postDelayed }
            val budget = nativeFrameBudget.reserve()
            if (budget == null) { entry.capturePending = false; entry.captureStage = "budget-busy"; return@postDelayed }
            val physical = nativeFrameCaptureArbiter.acquire()
            if (physical == null) { budget.unpublishedFinished(); entry.capturePending = false; entry.captureStage = "native-busy"; return@postDelayed }
            check(budget.startNative())
            entry.captureStage = "pixels-requested"
            try { view.capturePixels().accept({ bitmap -> handler.post {
                nativeFrameCaptureArbiter.finish(physical)
                entry.capturePending = false
                if (bitmap == null) { budget.unpublishedFinished(); entry.captureStage = "pixels-empty"; return@post }
                if (!current() || !budget.current || bitmap.allocationByteCount.toLong() > PagingCaptureLifetime.MAX_BYTES) {
                    entry.captureStage = "pixels-stale"; bitmap.recycle(); budget.unpublishedFinished(); return@post
                }
                try {
                    entry.capturedAt = SystemClock.uptimeMillis()
                    snapshots.put(id, bitmap, entry.page.url ?: entry.tab.url, entry.profile.id, document, entry.thumbnailSession)
                    entry.captureStage = "stored"
                } finally {
                    if (bitmap.isRecycled) budget.unpublishedFinished()
                    else budget.publish(bitmap)?.close() // A tiny already-small published thumbnail is still weakly charged.
                }
            } }, { handler.post {
                nativeFrameCaptureArbiter.finish(physical); budget.unpublishedFinished()
                entry.capturePending = false; entry.captureStage = "pixels-rejected"
            } }) } catch (_: Exception) {
                nativeFrameCaptureArbiter.finish(physical); budget.unpublishedFinished()
                entry.capturePending = false; entry.captureStage = "pixels-rejected"
            }
        }, 350)
    }

    /** Revoke native authority first. Gecko owns the single remote disconnect.
     * Local Port.disconnect racing its queued remote close double-shuts EventDispatcher. */
    private fun retireBridge(entry: Entry) {
        val previous = entry.port
        entry.port = null
        previous?.let { runCatching { it.postMessage(JSONObject().put("command", "retire")) } }
    }

    private fun attachBridge(id: String, entry: Entry) {
        val extension = integration ?: return
        entry.session.webExtensionController.setMessageDelegate(extension, object : WebExtension.MessageDelegate {
            override fun onConnect(port: WebExtension.Port) {
                entry.bridgeConnections++
                if (pages[id] !== entry || !entry.alive || port.sender.session !== entry.session || !port.sender.isTopLevel) {
                    entry.bridgeEvent = "rejected:current=${pages[id] === entry},alive=${entry.alive},session=${port.sender.session === entry.session},top=${port.sender.isTopLevel}"
                    runCatching { port.postMessage(JSONObject().put("command", "retire")) }; return
                }
                historyTouchChannels.remove(id)?.close()
                (views[id]?.get() as? HistorySwipeView)?.bindHistory(null, historySwipeConsumer)
                retireBridge(entry)
                entry.port = port
                entry.bridgeEvent = "connected"
                port.setDelegate(object : WebExtension.PortDelegate {
                    override fun onPortMessage(message: Any, port: WebExtension.Port) {
                        if (pages[id] !== entry || entry.port !== port) return
                        val value = message as? JSONObject ?: return
                        entry.bridgeMessages++; entry.bridgeEvent = value.optString("kind").take(24)
                        when (value.optString("kind")) {
                            "state" -> {
                                if (value.optString("url") != entry.page.url) { entry.bridgeEvent = "state-url-mismatch"; return }
                                val firstDocument = entry.contentDocument == null
                                entry.contentDocument = value.optString("documentID").takeIf(String::isNotBlank)
                                if (firstDocument || historyTouchChannels[id] == null) entry.contentDocument?.let { content ->
                                    historyTouchChannels.remove(id)?.close()
                                    historyTouchChannels[id] = OwnedHistoryTouchChannel(id, entry, port, entry.document, content)
                                    (views[id]?.get() as? HistorySwipeView)?.bindHistory(historyTouchChannels[id], historySwipeConsumer)
                                }
                                observeSiteIcon(entry, value)
                                if (firstDocument) applyZoom(id, entry)
                                entry.observed = value.optBoolean("safeObservation", false)
                                entry.editing = value.optBoolean("editing", true)
                                val uncertain = value.optBoolean("frameUncertain", true)
                                entry.domPlaying = value.optBoolean("playing")
                                update(id, entry) { it.copy(
                                    readerAvailable = value.optBoolean("readerAvailable"), readerEnabled = value.optBoolean("readerEnabled"),
                                    hasFormEdits = value.optBoolean("dirty"), playingMedia = entry.domPlaying || pageMedia.playing(id), frameUncertain = uncertain,
                                    scrollY = value.optDouble("scrollY", 0.0).toFloat(), safeToClear = entry.observed && !uncertain && !entry.editing &&
                                        !value.optBoolean("dirty") && !entry.domPlaying && !pageMedia.playing(id) && !it.capturingMedia,
                                ) }
                                if (entry.eviction != null && value.optString("proof") == entry.eviction && safeToEvict(id, entry)) {
                                    entry.evictionReady = true
                                    entry.session.flushSessionState()
                                }
                                scheduleCapture(id, entry)
                                scheduleHistoryCapture(id, entry)
                                trimSessions()
                            }
                            "history-touch" -> historyTouchChannels[id]?.receive(value)
                            "history-key" -> {
                                val nonce = value.opt("request") as? String ?: return
                                val pending = historyKeyRequests[nonce] ?: return
                                if (pending.entry !== entry || pending.port !== port || pending.document != entry.document ||
                                    pending.content != entry.contentDocument || pending.content != value.optString("documentID") ||
                                    port.sender.session !== entry.session || !port.sender.isTopLevel) return
                                historyKeyRequests.remove(nonce)
                                val key = HistoryNavigationKey.read(value::opt)
                                if (key != null && !key.initialDocument) {
                                    entry.historyImagesDisabled = true
                                    if (historyFrameOwner === entry) historyFrames?.clear()
                                }
                                pending.answer.complete(key)
                            }
                            "history-key-invalidated" -> {
                                if (entry.contentDocument == value.optString("documentID") && port.sender.isTopLevel &&
                                    port.sender.session === entry.session) {
                                    entry.historyImagesDisabled = true; entry.historyCaptureStage = "SAME_DOCUMENT_CHANGE"
                                    historyCaptureJob?.cancel(); historyCaptureJob = null
                                    if (historyFrameOwner === entry) historyFrames?.clear()
                                }
                            }
                            "text" -> {
                                val key = value.optString("request")
                                val pending = textRequests.remove(key)
                                if (pending != null && pending.tab == id && pending.document == entry.document && pending.port === port) {
                                    if (pending.diagnostics) {
                                        val shape = value.optJSONObject("shape")
                                        fun count(key: String): String {
                                            val number = shape?.opt(key) as? Number ?: return "unknown"
                                            val finite = number.toDouble().takeIf { it.isFinite() } ?: return "unknown"
                                            return finite.coerceIn(0.0, 1_000_000.0).toLong().toString()
                                        }
                                        val ready = shape?.optString("readyState")?.takeIf { it in setOf("loading", "interactive", "complete") } ?: "unknown"
                                        val visibility = shape?.optString("visibility")?.takeIf { it in setOf("visible", "hidden", "prerender") } ?: "unknown"
                                        val body = (shape?.opt("hasBody") as? Boolean)?.toString() ?: "unknown"
                                        val documentCurrent = entry.contentDocument?.let { it == value.optString("documentID") }?.toString() ?: "unknown"
                                        // Only bounded counts, booleans and fixed enums are retained.
                                        // Never include a URL, title, document ID or page text in diagnostics.
                                        entry.lastTextShape = "shape=${shape != null},hasText=${value.has("text")},string=${value.opt("text") is String}," +
                                            "length=${value.optString("text").length.coerceAtMost(12_000)},urlCurrent=${value.optString("url") == entry.page.url}," +
                                            "titleCurrent=${value.optString("title") == entry.page.title},documentCurrent=$documentCurrent," +
                                            "body=$body,ready=$ready,visibility=$visibility,inner=${count("innerTextLength")},content=${count("textContentLength")}"
                                    }
                                    val geometry = if (pending.diagnostics) value.optJSONObject("shape")?.let { shape ->
                                        PageViewportGeometry.read(shape::opt)
                                    } else null
                                    pending.answer.complete(PageText(value.optString("title"), value.optString("url"), value.optString("text"), geometry))
                                }
                            }
                            "dom" -> {
                                val pending = domRequests.remove(value.optString("request"))
                                if (pending != null && pending.tab == id && pending.document == entry.document && pending.port === port) pending.answer.complete(value)
                            }
                        }
                    }
                    override fun onDisconnect(port: WebExtension.Port) {
                        if (entry.port === port) {
                            if (historyFrameOwner === entry) clearHistoryFrames()
                            historyTouchChannels.remove(id)?.close()
                            (views[id]?.get() as? HistorySwipeView)?.bindHistory(null, historySwipeConsumer)
                        }
                        if (entry.port === port) {
                            entry.port = null; entry.observed = false; entry.eviction = null; entry.evictionReady = false
                            entry.bridgeEvent = "disconnected"
                            update(id, entry) { it.copy(safeToClear = false, frameUncertain = true) }
                        }
                    }
                })
                // Establish liveness after both native delegates exist; an early content-side
                // report must not be our only opportunity to observe the document.
                port.postMessage(JSONObject().put("command", "safety").put("request", "attached"))
            }
        }, "yab")
    }

    private fun observeSiteIcon(entry: Entry, value: JSONObject) {
        val store = siteIcons ?: return
        val page = entry.page.url ?: return
        val document = entry.contentDocument ?: return
        if (disposed || !entry.alive || entry.page.loading || entry.profile.isPrivate || entry.tab.isPrivate ||
            value.optString("url") != page || value.optString("documentID") != document) return
        val declared = (value.opt("declaredIconHref") as? String)?.takeIf { it.length <= 4096 && it.isNotBlank() }
        val observation = document to declared
        if (entry.iconObservation == observation) return
        entry.iconObservation = observation
        store.read(page, declared, false)
    }

    override fun activate(tab: BrowserTab, profile: WebsiteProfile) {
        if (selected != tab.id || pages[tab.id]?.profile != profile) revokeAutofill()
        if (selected != tab.id || pages[tab.id]?.profile != profile) { historyTargets.clear(); clearHistoryFrames() }
        ownedFind?.takeIf { it.tab != tab.id || it.entry.profile != profile }?.tab?.let(::clearFind)
        // BrowserController only activates Private after its lock gate has opened.
        if (profile.isPrivate) privateMediaPaused = false
        popupRequests.values.filter { it.tab != tab.id }.toList().forEach { it.finish(false) }
        leaveFullscreen(tab.id)
        if (selected != tab.id) prompts?.dismiss()
        if (selected != tab.id) dismissContextMenu()
        selected?.let { pages[it]?.takeIf { it.alive }?.session?.setActive(false) }
        selected = tab.id
        pages[tab.id]?.takeIf { it.profile != profile }?.let { close(tab.id) }
        pages[tab.id]?.takeIf { !it.alive }?.let {
            scheduleRecovery(tab.id, it); refreshActiveSessions(); return
        }
        session(tab, profile).let { it.setActive(true); onSessionActivated(it) }
        pages[tab.id]?.lastUsed = SystemClock.uptimeMillis()
        refreshActiveSessions()
        trimSessions()
        // Unlock/activation can resume an existing Private Reader that was correctly
        // excluded from earlier global style changes. No Reader is entered here.
        restyleReaders(readerPreferences)
    }
    override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {
        val stopped = pages[tab.id]?.takeIf { !it.alive }
        if (stopped != null && stopped.profile == profile) { recover(tab.id, destination = tab.copy(url = url)); return }
        if (stopped != null) close(tab.id)
        pages[tab.id]?.recovery?.reset()
        session(tab, profile).loadUri(url)
    }
    override fun goBack(tabId: String) { recover(tabId)?.goBack() }
    private fun captureBackHistory(id: String, entry: Entry, history: GeckoSession.HistoryDelegate.HistoryList, source: NativeHistoryCaptureSource) {
        if (pages[id] !== entry || !entry.alive) return
        val copied = history.map { NativeBackHistory.Page(it.uri.orEmpty(), it.title.orEmpty()) }
        entry.historySwipe.update(copied.map { it.url to it.title }, history.currentIndex)
        if (entry.backHistory.capture(copied, history.currentIndex)) update(id, entry) {
            it.copy(canGoBack = history.currentIndex > 0, canGoForward = history.currentIndex in 0 until copied.lastIndex)
        }
        observeHistoryCapture(id, entry, null, NativeHistoryCaptureStage.HISTORY_UPDATED, source)
    }
    override fun backItems(tabId: String): List<BrowserBackItem> {
        val entry = pages[tabId]?.takeIf { owns(it.session) && !it.page.loading } ?: return emptyList()
        return entry.backHistory.items(tabId, entry.document)
    }
    override fun goBackTo(tabId: String, item: BrowserBackItem): Boolean {
        val entry = pages[tabId]?.takeIf { owns(it.session) && !it.page.loading } ?: return false
        val index = entry.backHistory.consume(tabId, entry.document, item) ?: return false
        prompts?.dismiss(); cancelDocumentRequests(tabId)
        update(tabId, entry) { it.copy(loading = true, safeToClear = false) }
        entry.session.gotoHistoryIndex(index)
        return true
    }
    override fun goForward(tabId: String) { recover(tabId)?.goForward() }
    private fun observeHistoryCapture(tabId: String, entry: Entry?, direction: HistorySwipeDirection?, stage: NativeHistoryCaptureStage,
        source: NativeHistoryCaptureSource? = null) {
        val receive = historyCaptureObserver ?: return
        receive(NativeHistoryCaptureObservation(stage, direction, entry != null, entry?.alive == true,
            selected == tabId, entry?.let { owns(it.session) } == true,
            entry?.let { ownsInteractive(it.session) } == true, entry?.page?.loading == true,
            entry?.historySwipe?.projection(), source))
    }
    override fun captureHistorySwipe(tabId: String, direction: HistorySwipeDirection): NativeHistorySwipeTarget? {
        historyTargets.clear()
        val entry = pages[tabId]?.takeIf { ownsInteractive(it.session) && !it.page.loading }
        if (entry == null) {
            observeHistoryCapture(tabId, pages[tabId], direction, NativeHistoryCaptureStage.ENTRY_REFUSED)
            return null
        }
        val target = entry.historySwipe.capture(entry.document, direction)?.also { historyTargets[it] = entry }
        observeHistoryCapture(tabId, entry, direction, if (target == null) NativeHistoryCaptureStage.NEIGHBOR_REFUSED else NativeHistoryCaptureStage.CAPTURED)
        return target
    }
    override fun historySwipeCurrent(target: NativeHistorySwipeTarget): Boolean {
        val entry = historyTargets[target] ?: return false
        return pages[entry.tab.id] === entry && entry.alive && ownsInteractive(entry.session) && !entry.page.loading &&
            entry.historySwipe.current(entry.document, target)
    }
    override fun commitHistorySwipe(target: NativeHistorySwipeTarget): Boolean {
        if (!historySwipeCurrent(target)) return false
        val entry = historyTargets.remove(target) ?: return false
        fun move(back: Boolean) {
            prompts?.dismiss(); cancelDocumentRequests(entry.tab.id)
            // Loading comes from the real native callback: stale canGoBack may
            // legitimately produce a no-op, which must not leave a fake spinner.
            if (back) entry.session.goBack() else entry.session.goForward()
        }
        return entry.historySwipe.commitRelative(entry.document, target, { move(true) }, { move(false) })
    }
    override fun reload(tabId: String) {
        val entry = pages[tabId] ?: return
        entry.recovery.reset()
        if (!entry.alive) recover(tabId) else entry.session.reload()
    }
    override fun stop(tabId: String) { pages[tabId]?.session?.stop() }
    override fun close(tabId: String) {
        (views[tabId]?.get() as? HistorySwipeView)?.revokeAutofill(cancelFramework = selected == tabId)
        revokePagingFrame()
        if (historyFrameOwner === pages[tabId]) clearHistoryFrames()
        historyTouchChannels.remove(tabId)?.close()
        pages[tabId]?.let { old -> historyTargets.entries.removeAll { it.value === old } }
        chromeClipping.forget(tabId)
        if (disposed) return
        dismissContextMenu(tabId)
        privateKeepers.values.forEach { it.readiness.cancel(tabId) }
        mutableConnections.value = mutableConnections.value - tabId
        val entry = pages.remove(tabId)
        entry?.recovery?.invalidate()
        pageMedia.forget(tabId)
        val sleeping = suspended.remove(tabId)
        if (entry != null && prompts?.hasPending(entry.session) == true) prompts?.dismiss()
        if (entry?.fullScreen == true && selected == tabId) onFullscreen(false)
        entry?.let {
            imageDownloads?.detach(it.session)
            retireBridge(it)
            val memory = closedMemories.lastOrNull { saved -> !saved.released && saved.tab.id == tabId && saved.profile == it.profile }
            if (it.alive) {
                onSessionClosed(it.session)
                // An inactive, safe document gets one bounded final flush. Recording/permissions
                // and playing media close immediately rather than retaining device access.
                if (memory != null && !it.page.capturingMedia && !it.mediaAccessGranted && it.permissions == 0 && !it.page.playingMedia) {
                    var finished = false
                    val timeout = Runnable { closing[it.session]?.finish?.invoke() }
                    fun finish() {
                        if (finished) return
                        finished = true; handler.removeCallbacks(timeout); closing.remove(it.session)
                        it.session.close(); memory.drained.complete(Unit)
                    }
                    closing[it.session] = Closing(it, memory, ::finish)
                    handler.postDelayed(timeout, 1_000)
                    it.session.settings.suspendMediaWhenInactive = true
                    it.session.setActive(false)
                } else { it.session.close(); memory?.drained?.complete(Unit) }
            } else memory?.drained?.complete(Unit)
            it.alive = false
        }
        if (entry == null) closedMemories.filter { it.tab.id == tabId }.forEach { it.drained.complete(Unit) }
        views.remove(tabId); snapshots.remove(tabId)
        if (entry?.profile?.isPrivate == false || sleeping?.profile?.isPrivate == false) {
            // Synchronous tombstone prevents an immediate activate/Undo reading queued old bytes.
            pendingStateDeletes.add(tabId)
            stateWriter.execute {
                val file = stateFile(tabId)
                android.util.AtomicFile(file).delete()
                if (!file.exists()) pendingStateDeletes.remove(tabId)
            }
        }
        cancelDocumentRequests(tabId)
        closeUnusedPrivateKeepers()
        publishTranslationPage()
    }
    override fun reconcileTabs(spaces: List<BrowserSpace>) {
        if (disposed) return
        managedTabs = spaces.flatMap { space -> space.tabs.map { it.id to space.websiteProfile } }.toMap()
        pinnedSessions = PinnedSessions.of(spaces)
        snapshots.reconcile(spaces.filterNot(BrowserSpace::isPrivate).flatMap { space ->
            space.tabs.filterNot(BrowserTab::isPrivate).map { ThumbnailOwner(it.id, space.websiteProfile.id, it.url) }
        })
    }
    fun requestThumbnail(tab: BrowserTab, profile: WebsiteProfile) {
        if (!disposed && !tab.isPrivate && !profile.isPrivate && managedTabs[tab.id] == profile)
            snapshots.request(ThumbnailOwner(tab.id, profile.id, tab.url))
    }
    override fun invalidateTransientOwnership() {
        revokeAutofill()
        revokePagingFrame()
        clearHistoryFrames(); nativeFrameBudget.revokeAll()
        historyTargets.clear()
        historyTouchChannels.values.forEach { it.close() }; historyTouchChannels.clear()
        views.values.forEach { (it.get() as? HistorySwipeView)?.historyDocumentStarted() }
        ownershipEpoch++
        privateKeepers.values.forEach { it.readiness.cancelPending() }
        popupRequests.values.toList().forEach { it.finish(false) }
        pages.values.forEach { it.popupCloseOwner = null; it.popupPermits.clear(); it.recovery.invalidate() }
        ownedFind?.tab?.let(::clearFind)
        imageDownloads?.cancel()
        closedMemories.toList().forEach(::releaseUndo)
        snapshots.invalidateOwnership()
    }
    override fun captureForUndo(tab: BrowserTab, profile: WebsiteProfile): BrowserPageMemento? {
        if (disposed || profile.id in clearingProfiles) return null
        closedMemories.filter { it.expires < SystemClock.elapsedRealtime() }.toList().forEach(::releaseUndo)
        val entry = pages[tab.id]?.takeIf { it.profile == profile && (it.page.url ?: it.tab.url) == tab.url }
        val sleeping = suspended[tab.id]?.takeIf { it.profile == profile && (it.page.url ?: it.tab.url) == tab.url }
        val state = entry?.savedState ?: sleeping?.state ?: if (!profile.isPrivate) readState(tab.id, profile) else null
        if ((state?.length ?: 0) > 8 * 1024 * 1024 || closedMemories.size >= 32 ||
            closedMemories.sumOf { it.state?.length?.toLong() ?: 0 } + (state?.length ?: 0) > 16L * 1024 * 1024) return null
        val memory = ClosedMemory(this, tab, profile, state, SystemClock.elapsedRealtime() + 7_500)
        closedMemories += memory
        if (entry == null || !entry.alive) memory.drained.complete(Unit)
        if (profile.isPrivate) keepPrivateProfile(profile)
        handler.postDelayed({ if (memory in closedMemories) releaseUndo(memory) }, 7_500)
        return memory
    }
    override suspend fun restoreForUndo(tab: BrowserTab, profile: WebsiteProfile, memory: BrowserPageMemento, isCurrent: () -> Boolean): Boolean {
        val saved = memory as? ClosedMemory ?: return false
        if (saved.engine !== this || saved.released || saved !in closedMemories) return false
        withTimeoutOrNull(1_100) { saved.drained.await() }
        if (!isCurrent() || disposed || saved.released || saved !in closedMemories || SystemClock.elapsedRealtime() > saved.expires ||
            saved.tab.id != tab.id || saved.tab.url != tab.url || saved.profile != profile || profile.id in clearingProfiles ||
            pages.containsKey(tab.id) || suspended.containsKey(tab.id) || (profile.isPrivate && privateMediaPaused)) return false
        val text = saved.state ?: return false
        val native = GeckoSession.SessionState.fromString(text) ?: return false
        if (runCatching { native[native.currentIndex].uri }.getOrNull() != tab.url) return false
        val restored = Suspended(tab, profile, text, EnginePageState(url = tab.url, title = tab.title))
        suspended[tab.id] = restored
        saved.restored = restored
        return true
    }
    override fun releaseUndo(memory: BrowserPageMemento) {
        val saved = memory as? ClosedMemory ?: return
        if (saved.engine !== this || saved.released) return
        saved.released = true
        closing.values.filter { it.memory === saved }.toList().forEach { it.finish() }
        if (saved.restored != null && suspended[saved.tab.id] === saved.restored && managedTabs[saved.tab.id] != saved.profile)
            suspended.remove(saved.tab.id)
        saved.state = null; saved.drained.complete(Unit); closedMemories.remove(saved)
        closeUnusedPrivateKeepers()
    }
    override fun endPrivateSession(profile: WebsiteProfile) {
        if (disposed || !profile.isPrivate || managedTabs.values.any { it == profile } ||
            pages.values.any { it.profile == profile } || suspended.values.any { it.profile == profile }) return
        revokePagingFrame()
        // releaseUndo synchronously finishes pending native closes and revokes the old
        // handle before waking a restore. Closing the final keeper then ends Gecko's jar.
        closedMemories.filter { it.profile == profile }.toList().forEach(::releaseUndo)
        closeUnusedPrivateKeepers()
    }
    private fun cancelDocumentRequests(tabId: String) {
        historyKeyRequests.filterValues { it.entry.tab.id == tabId }.keys.toList().forEach { historyKeyRequests.remove(it)?.answer?.cancel() }
        privateKeepers.values.forEach { it.readiness.cancel(tabId) }
        clearFind(tabId)
        pages[tabId]?.let { imageDownloads?.invalidate(it.session) }
        popupRequests.values.filter { it.tab == tabId }.toList().forEach { it.finish(false) }
        textRequests.filterValues { it.tab == tabId }.keys.toList().forEach { textRequests.remove(it)?.answer?.cancel() }
        domRequests.filterValues { it.tab == tabId }.keys.toList().forEach { domRequests.remove(it)?.answer?.cancel() }
    }
    override fun pausePrivateMedia() {
        revokeAutofill(privateOnly = true)
        revokePagingFrame()
        clearHistoryFrames(); nativeFrameBudget.revokeAll()
        fieldAnswerEpoch++
        ownedFind?.takeIf { it.entry.profile.isPrivate }?.tab?.let(::clearFind)
        privateMediaPaused = true
        dismissContextMenu()
        pages.values.filter { it.profile.isPrivate }.forEach { it.domPlaying = false }
        pageMedia.pausePrivate()
        publishTranslationPage()
        pages.filterValues { it.profile.isPrivate && it.alive }.toList().forEach { (id, entry) ->
            if (entry.fullScreen) { entry.session.exitFullScreen(); entry.fullScreen = false; if (selected == id) onFullscreen(false) }
            entry.session.setActive(false)
            // Playback suspension is native and covers frames. It does not stop getUserMedia.
            // Unload a capturing/pending-permission document rather than pretending JS pause
            // can revoke its device access. No state from this path is written to disk.
            if (!entry.mediaAccessGranted && !entry.page.capturingMedia && entry.permissions == 0) return@forEach
            keepPrivateProfile(entry.profile)
            if (prompts?.hasPending(entry.session) == true) prompts?.dismiss()
            val stopped = entry.page.copy(capturingMedia = false, playingMedia = false,
                safeToClear = false, frameUncertain = true)
            suspended[id] = Suspended(entry.tab, entry.profile, entry.savedState, stopped)
            pages.remove(id); views.remove(id); snapshots.remove(id)
            dismissContextMenu(id)
            mutableConnections.value = mutableConnections.value - id
            pageMedia.forget(id)
            entry.alive = false; entry.eviction = null; entry.evictionReady = false
            imageDownloads?.detach(entry.session)
            retireBridge(entry)
            cancelDocumentRequests(id)
            if (entry.fullScreen && selected == id) { entry.fullScreen = false; onFullscreen(false) }
            onSessionClosed(entry.session)
            entry.session.close()
            onState(id, stopped)
        }
    }
    private fun closeUnusedPrivateKeepers() {
        privateKeepers.keys.filter { profile -> pages.values.none { it.profile.id == profile } &&
            suspended.values.none { it.profile.id == profile } && closedMemories.none { it.profile.id == profile } }.forEach { profile -> privateKeepers[profile]?.let { retirePrivateKeeper(profile, it) } }
        if (pages.values.none { it.profile.isPrivate } && suspended.values.none { it.profile.isPrivate } && closedMemories.none { it.profile.isPrivate }) siteSettings.forgetPrivate()
    }
    /** Cancel the old OS proposal before a successor can supply a new structure. */
    private fun revokeAutofill(privateOnly: Boolean = false) {
        if (privateOnly) privateAutofillEpoch++ else autofillEpoch++
        views.forEach { (id, reference) ->
            if (!privateOnly || pages[id]?.profile?.isPrivate == true)
                (reference.get() as? HistorySwipeView)?.revokeAutofill(cancelFramework = selected == id)
        }
    }
    override suspend fun clearWebsiteData(profileIds: Set<String>) = dataClear.withLock {
        clearingProfiles.addAll(profileIds)
        try {
        withContext(Dispatchers.Main) {
            closedMemories.filter { it.profile.id in profileIds }.toList().forEach(::releaseUndo)
            snapshots.purgeProfiles(profileIds)
        }
        // Gecko context clearing is scoped; never clear unrelated spaces as a fallback.
        for (profile in profileIds) {
            withContext(Dispatchers.Main) {
                pages.filterValues { it.profile.id == profile }.keys.toList().forEach(::close)
                suspended.filterValues { it.profile.id == profile }.keys.toList().forEach(::close)
                runtime.storageController.clearDataForSessionContext(profile)
            }
        }
        // FIFO barrier also covers onSessionStateChange writes queued before close().
        // Dormant tabs from a prior process have files without a live Entry to close.
        val deleted = CompletableDeferred<Unit>()
        stateWriter.execute {
            try {
                File(context.filesDir, "navigation").listFiles().orEmpty().filter { it.name.endsWith(".json") }.forEach { file ->
                    if (file.length() <= 8 * 1024 * 1024) {
                        val owner = runCatching { JSONObject(file.readText()).optString("profile") }.getOrNull()
                        if (owner in profileIds) {
                            android.util.AtomicFile(file).delete()
                            check(!file.exists()) { "Navigation state could not be removed" }
                        }
                    }
                }
                deleted.complete(Unit)
            } catch (error: Exception) { deleted.completeExceptionally(error) }
        }
        withContext(NonCancellable) { deleted.await() }
        siteIcons?.removeAll()
        Unit
        } finally { clearingProfiles.removeAll(profileIds) }
    }
    override fun setReader(tabId: String, enabled: Boolean): Boolean {
        val entry = pages[tabId] ?: return false
        val session = entry.session
        val port = entry.port ?: return false
        val document = entry.contentDocument ?: return false
        val url = entry.page.url ?: entry.tab.url
        if (!entry.alive || entry.page.loading || !ownsInteractive(session)) return false
        val message = JSONObject().put("command", "reader").put("enabled", enabled)
            .put("expectedDocument", document).put("expectedURL", url)
        if (enabled) message.put("look", readerStyle(readerPreferences.payload)).put("margins", readerPreferences.look.margins)
        if (pages[tabId] !== entry || entry.session !== session || entry.port !== port ||
            entry.contentDocument != document || (entry.page.url ?: entry.tab.url) != url ||
            !entry.alive || entry.page.loading || !ownsInteractive(session)) return false
        port.postMessage(message)
        return true
    }
    /** Global ReaderStyle changes visit already-live Readers only, including nonfront ones.
     * This separate style channel deliberately does not change owns()/ownsInteractive(). */
    override fun restyleReaders(preferences: ReaderPreferences) {
        check(Looper.myLooper() == Looper.getMainLooper())
        readerPreferences = preferences.normalized()
        val look = readerPreferences.payload
        for ((id, entry) in pages.toList()) {
            if (!entry.alive || !entry.page.readerEnabled) continue
            val session = entry.session
            val profile = entry.profile
            val port = entry.port ?: continue
            val content = entry.contentDocument ?: continue
            val document = entry.document
            val url = entry.page.url ?: entry.tab.url
            val ownership = ownershipEpoch
            fun current() = !disposed && ownershipEpoch == ownership && pages[id] === entry && entry.alive &&
                entry.page.readerEnabled && !entry.page.loading && entry.session === session && session.isOpen &&
                managedTabs[id] == profile && entry.profile == profile && (!profile.isPrivate || !privateMediaPaused) &&
                session.settings.contextId == profile.id && session.settings.usePrivateMode == profile.isPrivate &&
                entry.port === port && port.sender.session === session && port.sender.isTopLevel &&
                entry.document == document && entry.contentDocument == content && (entry.page.url ?: entry.tab.url) == url
            if (!current()) continue
            val message = JSONObject().put("command", "reader-style").put("expectedDocument", content).put("expectedURL", url)
                .put("look", readerStyle(look)).put("margins", look.margins)
            if (current()) try { port.postMessage(message) }
            catch (_: Exception) { /* A retired native port must not stop styles for the other live Readers. */ }
        }
    }
    private fun readerStyle(value: ReaderStylePayload): JSONObject {
        fun ground(colors: dev.yab.browser.model.ReaderColors) = JSONObject()
            .put("bg", colors.background).put("ink", colors.text).put("dark", colors.dark)
        return JSONObject().put("mode", value.mode).put("day", ground(value.day)).put("night", ground(value.night))
            .put("font", value.font).put("weight", value.weight).put("size", value.size).put("line", value.line)
            .put("letter", value.letter).put("word", value.word).put("width", value.width).put("justify", value.justify)
    }
    override fun setZoom(tabId: String, factor: Double): Boolean {
        val entry = pages[tabId]?.takeIf { it.alive && owns(it.session) } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        if (!factor.isFinite()) return false
        siteSettings.setZoom(host, entry.profile.isPrivate, factor)
        pages.forEach { (id, other) -> if (SiteSettingsStore.key(webHost(other.page.url ?: other.tab.url)) == SiteSettingsStore.key(host)) applyZoom(id, other) }
        return true
    }
    override fun find(tabId: String, query: BrowserFindQuery, direction: BrowserFindDirection,
        answer: (BrowserFindResult?) -> Unit): Boolean {
        val entry = pages[tabId]?.takeIf { owns(it.session) && !it.page.loading && mutableLinkPreview.value == null } ?: return false
        if (query.text.length > 1024) return false
        val previous = ownedFind
        val repeat = direction != BrowserFindDirection.START && previous?.let {
            it.tab == tabId && it.entry === entry && it.document == entry.document && it.query == query
        } == true
        if (direction != BrowserFindDirection.START && !repeat) return false
        if (previous != null && previous.tab != tabId) clearFind(previous.tab)
        val owner = OwnedFind(tabId, entry, entry.document, query, answer)
        ownedFind = owner
        fun observe(stage: NativeFindStage, matches: Boolean? = null, current: Int? = null, total: Int? = null) {
            val receive = findObserver ?: return
            val view = views[tabId]?.get()
            receive(NativeFindObservation(stage, ownedFind === owner, pages[tabId] === entry,
                entry.alive, entry.document == owner.document, owns(entry.session), matches, current, total,
                NativeFindReadiness(entry.profile.isPrivate, privateMediaPaused, foreground, entry.session.isOpen,
                    view != null, view?.isAttachedToWindow == true, view?.isShown == true, view?.hasWindowFocus() == true,
                    view?.session === entry.session, view != null && view.width > 0 && view.height > 0,
                    entry.historyFirstPaint, entry.historyPageStopped, entry.contentDocument != null, entry.port != null)))
        }
        observe(NativeFindStage.REQUEST)
        val finder = entry.session.finder
        if (!repeat) finder.clear()
        if (query.text.isEmpty()) { answer(BrowserFindResult(0, 0)); return true }
        finder.setDisplayFlags(GeckoSession.FINDER_DISPLAY_HIGHLIGHT_ALL)
        var flags = if (direction == BrowserFindDirection.PREVIOUS) GeckoSession.FINDER_FIND_BACKWARDS else GeckoSession.FINDER_FIND_FORWARD
        if (query.matchCase) flags = flags or GeckoSession.FINDER_FIND_MATCH_CASE
        if (query.wholeWord) flags = flags or GeckoSession.FINDER_FIND_WHOLE_WORD
        observe(NativeFindStage.SUBMITTED)
        finder.find(if (repeat) null else query.text, flags).accept({ result ->
            observe(NativeFindStage.RESULT, result?.searchString == query.text, result?.current, result?.total)
            if (ownedFind === owner && pages[tabId] === entry && entry.alive && entry.document == owner.document && owns(entry.session)) {
                if (result == null || result.searchString != query.text) clearFind(tabId)
                else {
                    answer(BrowserFindResult(result.current.coerceAtLeast(0), result.total.coerceAtLeast(-1), result.wrapped))
                    observe(NativeFindStage.DELIVERED)
                }
            }
        }, { observe(NativeFindStage.FAILURE); if (ownedFind === owner) clearFind(tabId) })
        return true
    }

    override fun clearFind(tabId: String) {
        val owner = ownedFind?.takeIf { it.tab == tabId } ?: return
        findObserver?.invoke(NativeFindObservation(NativeFindStage.CLEAR, true, pages[tabId] === owner.entry,
            owner.entry.alive, owner.entry.document == owner.document, owns(owner.entry.session)))
        ownedFind = null
        if (owner.entry.alive) owner.entry.session.finder.clear()
        owner.answer(null)
    }
    override fun setDesktop(tabId: String, enabled: Boolean): Boolean {
        val entry = pages[tabId]?.takeIf { it.alive && owns(it.session) } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        siteSettings.setDesktop(host, entry.profile.isPrivate, enabled)
        applyDesktop(entry, entry.page.url ?: entry.tab.url)
        entry.session.reload()
        return true
    }

    fun sitePreferences(tabId: String): SitePreferences = pages[tabId]?.let { siteSettings.site(webHost(it.page.url ?: it.tab.url), it.profile.isPrivate) } ?: SitePreferences()
    fun setSitePermission(tabId: String, kind: SitePermission, decision: SiteDecision?): Boolean {
        val entry = pages[tabId]?.takeIf { it.alive && owns(it.session) } ?: return false
        val host = webHost(entry.page.url ?: entry.tab.url) ?: return false
        if (decision == null) siteSettings.forget(host, entry.profile.isPrivate, kind)
        else siteSettings.setDecision(host, entry.profile.isPrivate, kind, decision)
        return true
    }
    private fun applyDesktop(entry: Entry, url: String?) {
        val desktop = siteSettings.site(webHost(url), entry.profile.isPrivate).desktop
        entry.session.settings.userAgentMode = if (desktop) GeckoSessionSettings.USER_AGENT_MODE_DESKTOP else GeckoSessionSettings.USER_AGENT_MODE_MOBILE
        entry.session.settings.viewportMode = if (desktop) GeckoSessionSettings.VIEWPORT_MODE_DESKTOP else GeckoSessionSettings.VIEWPORT_MODE_MOBILE
    }
    private fun applyZoom(id: String, entry: Entry) {
        val port = entry.port ?: return
        val document = entry.contentDocument ?: return
        if (pages[id] !== entry || !entry.alive || entry.profile.isPrivate && privateMediaPaused) return
        port.postMessage(JSONObject().put("command", "zoom").put("expectedDocument", document)
            .put("factor", siteSettings.site(webHost(entry.page.url ?: entry.tab.url), entry.profile.isPrivate).zoom))
    }
    private fun webHost(url: String?): String? = url?.let { runCatching { URI(it).takeIf { uri -> uri.scheme in setOf("http", "https") }?.host }.getOrNull() }
    private fun safeContextUrl(url: String?): String? = url?.takeIf { it.length <= 16_384 && !it.contains('\n') && !it.contains('\r') }?.takeIf {
        runCatching { URI(it).let { uri -> uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null } }.getOrDefault(false)
    }
    fun dismissContextMenu(tabId: String? = null) {
        mutableLinkPreview.value?.takeIf { tabId == null || it.sourceTab == tabId }?.let { closeLinkPreview(it.id) }
        if (tabId != null && ownedContextMenu?.request?.tab != tabId) return
        ownedContextMenu = null; mutableContextMenu.value = null
    }
    /** No tab, history, extension-host registration, snapshot or state-file writer is involved. */
    fun openLinkPreview(requestId: String, authorityCurrent: () -> Boolean): Boolean {
        val held = ownedContextMenu?.takeIf { it.request.id == requestId } ?: return false
        val target = held.request.link?.takeIf(::linkPreviewWebUrl) ?: return false
        closeLinkPreview()
        val sourceUrl = held.entry.page.url
        fun current() = authorityCurrent() && !disposed && ownedContextMenu === held &&
            pages[held.request.tab] === held.entry && held.entry.document == held.document &&
            held.entry.page.url == sourceUrl && owns(held.entry.session) && visibleTabs?.contains(held.request.tab) != false
        if (!current()) return false
        val preview = NativeLinkPreview(requestId, held.request.tab, target, held.request.isPrivate,
            held.entry.session.settings, ::current, { closeLinkPreview(requestId) })
        mutableLinkPreview.value = preview
        integration?.let(preview::denyBridge)
        return try { preview.open(runtime); mutableLinkPreview.value === preview }
        catch (_: RuntimeException) { closeLinkPreview(requestId); false }
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
        val source = held.entry.session
        val target = preview.url
        dismissContextMenu()
        // Commit is normal source navigation, just as tapping the iOS context-menu preview.
        source.loadUri(target)
        return true
    }
    /** Once-only action lease. The UI performs only the action the person picked after this succeeds. */
    fun takeContextMenu(id: String): PageContextMenu? {
        val pending = ownedContextMenu ?: return null
        if (pending.request.id != id) return null
        dismissContextMenu()
        return pending.request.takeIf { pages[it.tab] === pending.entry && pending.entry.document == pending.document && ownsInteractive(pending.entry.session) }
    }

    /** This capability is created only by consuming Gecko's original native long-press entry. */
    class HeldImageDownload internal constructor(val image: String, val owner: ExternalActivityOwner)
    fun takeImageDownload(id: String): HeldImageDownload? {
        val pending = ownedContextMenu?.takeIf { it.request.id == id } ?: return null
        val image = pending.request.image ?: return null
        dismissContextMenu()
        if (pages[pending.request.tab] !== pending.entry || pending.entry.document != pending.document || !ownsInteractive(pending.entry.session)) return null
        return HeldImageDownload(image, ExternalActivityOwner(pending.request.tab, pending.entry.session, pending.document))
    }
    fun bindImageDownloads(value: OwnedImageDownloadRuntime) {
        check(imageDownloads == null || imageDownloads === value)
        imageDownloads = value
        pages.forEach { (id, entry) -> attachImageDownload(id, entry) }
    }
    private fun attachImageDownload(id: String, entry: Entry) {
        imageDownloads?.attach(entry.session,
            document = { entry.document.takeIf { pages[id] === entry && entry.alive } },
            url = { entry.page.url.takeIf { pages[id] === entry && entry.alive } },
            interactive = { pages[id] === entry && entry.alive && !entry.page.loading && ownsInteractive(entry.session) })
    }

    fun darken(tabId: String, enabled: Boolean) { send(tabId, "dark", "enabled", enabled) }
    private fun send(id: String, command: String, key: String? = null, value: Any? = null): Boolean {
        val port = pages[id]?.port ?: return false
        val message = JSONObject().put("command", command)
        if (key != null) message.put(key, value)
        port.postMessage(message)
        return true
    }
    suspend fun readText(tab: BrowserTab, diagnostics: Boolean = false): PageText {
        val entry = pages[tab.id] ?: error("The page is not ready")
        val document = entry.document
        return readOwnedPage(current = { pages[tab.id] === entry && entry.document == document && owns(entry.session) },
            connection = { entry.port?.takeIf { entry.contentDocument != null } }, stage = { entry.lastTextRead = it }, request = { port ->
                val key = UUID.randomUUID().toString()
                val answer = CompletableDeferred<PageText>()
                textRequests[key] = TextRequest(tab.id, document, port, answer, diagnostics)
                try {
                    port.postMessage(JSONObject().put("command", "text").put("request", key).apply { if (diagnostics) put("diagnostics", true) })
                    answer.await().also { check(entry.port === port) { "The page changed" } }
                } finally { textRequests.remove(key) }
            })
    }

    fun translationPort(): PageTranslationPort = object : PageTranslationPort {
        override val current get() = translationPage
        override suspend fun collect(): TranslationDocument {
            val id = selected ?: error("Open a page first")
            val entry = pages[id] ?: error("The page is not ready")
            check(owns(entry.session) && !entry.page.readerEnabled && !entry.page.loading) { "The page is not ready to translate" }
            val owner = TranslationOwner(id, entry.document, entry.profile.isPrivate, requireNotNull(entry.contentDocument) { "The page is not ready to translate" })
            val result = domRequest(owner, "translation-collect")
            val segments = result.optJSONArray("segments") ?: JSONArray()
            return TranslationDocument(owner, result.optString("title"), result.optString("language").takeIf { it.isNotBlank() && it != "null" },
                (0 until segments.length()).map { i -> val item = segments.getJSONObject(i); TranslationSegment(item.getString("id"), item.getString("text")) },
                entry.page.url, result.optBoolean("translated"), result.optString("targetLanguage").takeUnless { it.isBlank() || it == "null" })
        }
        override fun isCurrent(owner: TranslationOwner): Boolean = selected == owner.tabId && pages[owner.tabId]?.let {
            owns(it.session) && it.document == owner.document && it.contentDocument == owner.contentDocument &&
                it.profile.isPrivate == owner.privateOrigin && !it.page.readerEnabled && !it.page.loading
        } == true
        override suspend fun begin(owner: TranslationOwner, target: String) {
            check(isCurrent(owner)) { "The page changed" }
            domRequest(owner, "translation-begin", target = target)
        }
        override suspend fun changed(owner: TranslationOwner): Boolean {
            check(isCurrent(owner)) { "The page changed" }
            return domRequest(owner, "translation-changed").optBoolean("changed")
        }
        override suspend fun apply(owner: TranslationOwner, translated: List<TranslationSegment>) {
            check(isCurrent(owner)) { "The page changed" }
            val segments = JSONArray().apply { translated.forEach { put(JSONObject().put("id", it.id).put("text", it.text)) } }
            domRequest(owner, "translation-apply", segments)
        }
        override suspend fun showOriginal(owner: TranslationOwner) {
            check(isCurrent(owner)) { "The page changed" }
            domRequest(owner, "translation-original")
        }
    }
    override suspend fun captureFieldAnswerTarget(tabId: String): FieldAnswerTarget? {
        val entry = pages[tabId] ?: return null
        if (!ownsInteractive(entry.session) || entry.page.loading || entry.page.readerEnabled) return null
        val content = entry.contentDocument ?: return null
        val port = entry.port ?: return null
        val owner = TranslationOwner(tabId, entry.document, entry.profile.isPrivate, content)
        val ownership = ownershipEpoch; val epoch = fieldAnswerEpoch
        val token = UUID.randomUUID().toString()
        fun current() = !disposed && ownershipEpoch == ownership && fieldAnswerEpoch == epoch &&
            pages[tabId] === entry && entry.alive && entry.document == owner.document && entry.contentDocument == owner.contentDocument &&
            entry.port === port && ownsInteractive(entry.session) && !entry.page.loading && !entry.page.readerEnabled
        val response = try { domRequest(owner, "answer-capture", answerToken = token) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled } catch (_: Exception) { return null }
        if (!current() || !response.optBoolean("ready")) return null
        return object : FieldAnswerTarget {
            private var consumed = false
            override val ready get() = !consumed && current()
            override suspend fun insert(value: String): Boolean {
                if (!ready || value.length > 4096) return false
                consumed = true
                return try { domRequest(owner, "answer-insert", answerToken = token, answerValue = value).optBoolean("inserted") && current() }
                    catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled } catch (_: Exception) { false }
            }
            override fun revoke() {
                consumed = true
                if (current()) runCatching { port.postMessage(JSONObject().put("command", "answer-revoke")
                    .put("request", UUID.randomUUID().toString()).put("expectedDocument", owner.contentDocument).put("answerToken", token)) }
            }
        }
    }

    private suspend fun domRequest(owner: TranslationOwner, command: String, segments: JSONArray? = null, target: String? = null,
        answerToken: String? = null, answerValue: String? = null): JSONObject {
        val entry = pages[owner.tabId] ?: error("The page closed")
        check(owns(entry.session) && selected == owner.tabId && entry.document == owner.document &&
            entry.contentDocument == owner.contentDocument && entry.profile.isPrivate == owner.privateOrigin) { "The page changed" }
        val port = entry.port ?: error("The page is not ready")
        val key = UUID.randomUUID().toString()
        val answer = CompletableDeferred<JSONObject>()
        domRequests[key] = DomRequest(owner.tabId, owner.document, port, answer)
        return try {
            port.postMessage(JSONObject().put("command", command).put("request", key).put("expectedDocument", owner.contentDocument).apply {
                if (segments != null) put("segments", segments)
                if (target != null) put("target", target)
                if (answerToken != null) put("answerToken", answerToken)
                if (answerValue != null) put("answerValue", answerValue)
            })
            val response = withTimeoutOrNull(5000) { answer.await() } ?: error("The page did not answer")
            check(response.optString("documentID") == owner.contentDocument && response.optBoolean("ok")) { "The page changed" }
            check(pages[owner.tabId] === entry && owns(entry.session) && entry.document == owner.document) { "The page changed" }
            response
        } finally { domRequests.remove(key) }
    }

    private fun stateFile(id: String): File = File(context.filesDir, "navigation").apply { mkdirs() }.resolve("${UUID.nameUUIDFromBytes(id.toByteArray())}.json")
    fun saveSessions() {
        pages.values.filter { it.alive }.forEach { it.session.flushSessionState() }
    }
    private fun readState(id: String, profile: WebsiteProfile): String? {
        if (profile.isPrivate || id in pendingStateDeletes || profile.id in clearingProfiles) return null
        val file = stateFile(id)
        if (!file.isFile || file.length() > 8 * 1024 * 1024) return null
        return runCatching { JSONObject(file.readText()).takeIf { it.optString("profile") == profile.id && it.optInt("schema") == 1 }?.getString("state") }.getOrNull()
    }
    private fun saveState(id: String, entry: Entry) {
        if (entry.profile.isPrivate) return
        val saved = entry.savedState ?: return
        if (saved.length > 8 * 1024 * 1024) return
        val text = JSONObject().put("schema", 1).put("profile", entry.profile.id).put("state", saved).toString()
        stateWriter.execute { writeState(id, text) }
    }
    private fun writeState(id: String, text: String) {
        val atomic = android.util.AtomicFile(stateFile(id))
        val output = atomic.startWrite()
        try { output.write(text.toByteArray()); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output) }
    }
}

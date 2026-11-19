package dev.yab.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.yab.agent.*
import dev.yab.browser.engine.CefriumEngine
import dev.yab.browser.engine.NativePagePrompts
import dev.yab.browser.engine.PagingCaptureOutcome
import dev.yab.browser.engine.PagingCaptureResult
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserFieldEditorValues
import dev.yab.browser.media.PageMediaController
import dev.yab.nativefeatures.FileTranslationRules
import dev.yab.nativefeatures.PageTranslationController
import dev.yab.sync.BrowserSyncBinding
import dev.yab.shield.ShieldController
import dev.yab.shield.ShieldMacImport
import dev.yab.shield.shieldUrlHost
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.yield

/** One browser lifetime per Activity's retained ViewModelStore. Private data stays in RAM. */
class BrowserSessionViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as YabApplication
    private val sync = app.sync
    val readerPreferences = app.readerPreferences
    // Cefrium is a static-methods SDK; the engine initializes it via YabApplication, no runtime object is passed here.
    val engine = CefriumEngine(app)
    private val repository = FileBrowserRepository(File(app.filesDir, "browser.json"))
    val browser = BrowserController(repository, engine, viewModelScope, privateLocks = false,
        activityClock = dev.yab.browser.engine.AndroidTabClock(app)::now,
        activityRepository = FileTabActivityRepository(File(app.filesDir, "tab-activity.json")))
    internal val fieldEditorValues = BrowserFieldEditorValues()
    private val launchKeyboardStore = LaunchKeyboardStore(app)
    internal val launchKeyboard = LaunchKeyboardPresentation(LaunchKeyboardCache(launchKeyboardStore.read(), launchKeyboardStore::save))
    internal fun launchKeyboardSource(): LaunchKeyboardSource? {
        val state = browser.state.value
        if (state.loading) return null
        val identity = sync.accountRecords.value
        val lifetime = browser.settingsPresentationLifetime.value
        return LaunchKeyboardSource(identity.account, identity.device, identity.epoch, identity.removed,
            state.space?.id, state.space?.websiteProfile, state.tab?.id, state.tab?.url, state.surfaceEpoch,
            browser.historyPresentationLifetime.value, lifetime.generation, lifetime.privateBoundary, lifetime.active)
    }
    internal fun startLaunchKeyboard(owner: Any, asked: Boolean, allowed: Boolean) {
        if (uiOwner !== owner) return
        val identity = sync.accountRecords.value
        launchKeyboard.foreground(owner, asked, allowed, Triple(identity.account, identity.device, identity.epoch),
            launchKeyboardSource(), System.currentTimeMillis())
    }
    internal fun stopLaunchKeyboard(owner: Any, configurationChange: Boolean) {
        if (uiOwner !== owner) return
        val identity = sync.accountRecords.value
        if (launchKeyboard.observationsAllowed(owner)) launchKeyboard.cache.background(
            LaunchKeyboardFront.capture(browser.state.value, identity.account, identity.device), launchKeyboardSource(), System.currentTimeMillis(), configurationChange,
            browser.tabletToolbarRevision.value) {
                it is CefriumEngine.ExternalActivityOwner && engine.ownsExternalActivity(it)
            }
        launchKeyboard.background(owner, configurationChange)
    }
    // Logical journey survives Activity recreation. Native controls/attempts retain their own Host.
    private val mutableFirstRun = MutableStateFlow<FirstRunPresentation?>(null)
    internal val firstRun = mutableFirstRun.asStateFlow()
    internal val firstRunPreparation = FirstRunPreparation(::firstRunPreparationSource)
    internal fun firstRunAbsent() = mutableFirstRun.value == null
    private fun firstRunPreparationSource(): FirstRunPreparation.Source {
        val current = browser.state.value
        return FirstRunPreparation.Source(mutableFirstRun.value == null, current.loading, current.settings.welcomed,
            sync.identityLease(), sync.accountEpoch, tabletJoinSource(sync).available, firstRunEntryAvailable(sync))
    }
    /** User-requested local publication only. An old read result never creates a journey. */
    internal fun prepareFirstRunOwner(control: FirstRunPreparation.Control?) {
        val ticket = firstRunPreparation.begin(control) ?: return
        viewModelScope.launch {
            var failed = false
            try {
                if (!firstRunPreparation.beforeCall(ticket)) return@launch
                sync.prepareNativeOwner()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { firstRunPreparation.complete(ticket, failed) }
        }
    }
    internal fun firstRunCurrent(owner: FirstRunPresentation) = mutableFirstRun.value === owner
    internal fun beginFirstRun() {
        if (mutableFirstRun.value != null || browser.state.value.loading || browser.state.value.settings.welcomed) return
        val source = FirstRunJourneySource(tabletJoinSource(sync), sync.ui.value,
            native = { tabletJoinSource(sync) }, ui = { sync.ui.value }, entryAvailable = { firstRunEntryAvailable(sync) })
        val flow = source.create { sync.ui.value.code } ?: return
        firstRunPreparation.invalidate()
        mutableFirstRun.value = flow
    }
    internal fun retireFirstRun(owner: FirstRunPresentation) {
        if (mutableFirstRun.value !== owner) return
        firstRunPreparation.invalidate()
        owner.close(); mutableFirstRun.value = null
    }
    internal fun finishFirstRun(owner: FirstRunPresentation, completion: FirstRunPresentation.Completion): Boolean {
        if (mutableFirstRun.value !== owner || !completion.current { tabletJoinSource(sync) }) return false
        val current = browser.state.value
        if (current.loading || current.settings.welcomed || current.privateContentBlocked) return false
        browser.updateSettings(current.settings.copy(welcomed = true))
        if (completion.withoutMac) browser.openField(newTab = true)
        firstRunPreparation.invalidate()
        mutableFirstRun.value = null
        return true
    }
    // Cefrium's adblock is process-wide plus per-browser toggles; the controller keeps only policy state.
    val shield = ShieldController(app, viewModelScope)
    private val browserSync = BrowserSyncBinding(browser, sync, viewModelScope, repository)
    val macToday = dev.yab.sync.MacTodayController(browser, sync, viewModelScope)
    private var uiOwner: Any? = null
    private var uiStarted = false
    private var privateDownloadAway = false
    val models = LocalModelManager(app, viewModelScope)
    private val localAi = LiteRtLocalAiAdapter(models)
    val pageIdeas = PageIdeasController(localAi, viewModelScope)
    val agent = AgentRepository(FileChatPersistence(app), localAi, SyncProtocolTransport(sync))
    val parkedChats = ParkedChats(agent, viewModelScope)
    val downloads = PageDownloadController(app, viewModelScope, ::downloadSourceAlive)
    val imageDownloads = dev.yab.browser.download.OwnedImageDownloadRuntime(viewModelScope)
    val approvals = ApprovalController(sync)
    val reports = dev.yab.reports.AndroidReports(app, viewModelScope)
    // Cefrium hosts no signed extensions; the manager stays so the shared screen compiles, permanently empty.
    val extensionsManager = GeckoSignedExtensionManager(app,
        privateContext = { !extensionsAllowed() })
    val translator = PageTranslationController(engine.translationPort(),
        rules = FileTranslationRules(File(app.filesDir, "translation-rules.json")))

    /** A quick answer belongs to the retained session, including Activity recreation. */
    fun sendQuestion(chatId: String, words: String) {
        sendOwnedQuestion(chatId, words) { true }
    }
    fun sendPageIdea(chatId: String, words: String, isCurrent: () -> Boolean) {
        sendOwnedQuestion(chatId, words, isCurrent)
    }
    private fun sendOwnedQuestion(chatId: String, words: String, isCurrent: () -> Boolean) {
        val source = questionSource()
        viewModelScope.launch {
            if (agent.state.value.current?.id != chatId || questionSource() != source || !isCurrent()) return@launch
            agent.draft(words)
            if (agent.state.value.current?.id == chatId && questionSource() == source && isCurrent())
                agent.send(chatId = chatId, sourceCurrent = { questionSource() == source && isCurrent() })
            else agent.showError("Your conversation or Mac changed. Send the question again.")
        }
    }
    private fun questionSource(): List<Any?> = sync.connection.value.let { connection ->
        val preferences = agent.state.value.preferences
        listOf(connection.account, sync.accountEpoch, connection.selectedMac, connection.route(preferences.provider)?.id, preferences, agent.state.value.privateContext)
    }

    suspend fun capturePageSwipeFrame(lease: PageSwipeLease): PagingCaptureResult {
        val owner = uiOwner
        val account = sync.accountRecords.value
        fun current() = uiStarted && owner != null && uiOwner === owner &&
            browser.pageSwipeCurrent(lease) && sync.nativeOwnerCurrent(account)
        if (!current()) return PagingCaptureResult(PagingCaptureOutcome.NOT_CURRENT)
        return engine.capturePagingFrame(lease.front, lease.profile, ::current)
    }

    fun startDownload(response: PageDownloadSource): Boolean {
        val source = browser.state.value
        val tab = source.tab ?: run { response.close(); return false }
        val profile = source.space?.websiteProfile ?: run { response.close(); return false }
        val native = engine.captureExternalActivityOwner() ?: run { response.close(); return false }
        val account = sync.accountRecords.value
        if (!sync.nativeOwnerCurrent(account)) { response.close(); return false }
        val owner = PageDownloadOwner(tab.id, profile.id, native.document, tab.isPrivate,
            account.account, account.epoch, native)
        privateDownloadAway = false
        return downloads.start(response, owner).also { started ->
            if (!started) browser.message("Finish or cancel the current file before downloading another")
        }
    }
    fun saveHeldImage(requestId: String): Boolean {
        val current = browser.state.value
        val tab = current.tab ?: return false
        val profile = current.space?.websiteProfile ?: return false
        if (!uiStarted || current.surface != BrowserSurface.PAGE || current.privateContentBlocked ||
            downloads.state.value.phase !in setOf(PageDownloadPhase.CANCELLED, PageDownloadPhase.SAVED, PageDownloadPhase.SHARED)) return false
        val held = engine.takeImageDownload(requestId) ?: return false
        if (held.owner.tab != tab.id || !engine.ownsExternalActivity(held.owner)) return false
        val account = sync.accountRecords.value
        if (!sync.nativeOwnerCurrent(account)) return false
        val source = PageDownloadOwner(tab.id, profile.id, held.owner.document, tab.isPrivate,
            account.account, account.epoch, held.owner)
        privateDownloadAway = false // A new pending request cannot inherit an earlier Private transfer's background exception.
        // Cefrium has no intercepted response; the runtime fetches the image itself and hands over its PageDownloadSource.
        val started = imageDownloads.saveImage(held.owner.session, held.image, source, { downloadSourceAlive(source) },
            deliver = { response ->
                if (!downloadSourceAlive(source)) response.close()
                else { privateDownloadAway = false; downloads.start(response, source) }
            }, failure = browser::message)
        browser.message(if (started) "Saving image" else "This image couldn't be saved from this page. Open the image and try there.")
        return started
    }
    private fun downloadSourceAlive(owner: PageDownloadOwner): Boolean {
        val source = browser.state.value
        val account = sync.accountRecords.value
        return source.tab?.id == owner.tab && source.space?.websiteProfile?.id == owner.profile &&
            source.tab?.isPrivate == owner.privateOrigin && (!source.privateContentBlocked || owner.privateOrigin && privateDownloadAway) &&
            account.account == owner.account && account.epoch == owner.accountEpoch && sync.nativeOwnerCurrent(account) &&
            (owner.native as? CefriumEngine.ExternalActivityOwner)?.let { engine.externalActivityAlive(it, owner.privateOrigin && privateDownloadAway) } == true
    }

    fun openLinkPreview(requestId: String): Boolean {
        val source = browser.state.value
        val tab = source.tab ?: return false
        val profile = source.space?.websiteProfile ?: return false
        val account = sync.connection.value.account
        val epoch = sync.accountEpoch
        val owner = uiOwner
        return engine.openLinkPreview(requestId) {
            val current = browser.state.value
            uiStarted && uiOwner === owner && current.tab?.id == tab.id && current.tab?.isPrivate == tab.isPrivate &&
                current.space?.websiteProfile == profile && current.surface == BrowserSurface.PAGE && !current.privateContentBlocked &&
                sync.connection.value.account == account && sync.accountEpoch == epoch
        }
    }

    fun sendMessage(chatId: String, selection: ModelSelection) {
        viewModelScope.launch { agent.send(selection, chatId = chatId) }
    }
    fun setGlobalBlocking(enabled: Boolean) {
        viewModelScope.launch {
            try { shield.policies.setGlobal(enabled) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { browser.message("The blocking setting could not be saved. Try again.") }
        }
    }
    fun setSiteBlocking(tab: BrowserTab, enabled: Boolean) {
        val source = browser.state.value
        if (source.tab?.id != tab.id || source.tab?.url != tab.url || source.privateContentBlocked) return
        val profile = source.space?.websiteProfile ?: return
        val owner = engine.captureExternalActivityOwner() ?: return
        val host = shieldUrlHost(tab.url) ?: return
        viewModelScope.launch {
            try {
                val applied = shield.setSite(host, profile.isPrivate, enabled)
                val current = browser.state.value
                if (applied && current.tab?.id == tab.id && current.tab?.url == tab.url &&
                    current.space?.websiteProfile == profile && !current.privateContentBlocked && engine.ownsExternalActivity(owner)) engine.reload(tab.id)
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { browser.message("The blocking setting could not be applied. Try again.") }
        }
    }
    val media = PageMediaController(app, engine.media, viewModelScope, engine::mediaCommand, engine::mediaFocus, browser::message)

    init {
        // Registered before the incoming-link collector: pin the first loaded front,
        // never a replacement reached while Main was waiting for its native window.
        viewModelScope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            var forgetting: HistoryForgetting? = null
            browser.state.collect { state -> if (!state.loading) launchKeyboardSource()?.let { source ->
                val identity = sync.accountRecords.value
                launchKeyboard.cache.reconcile(LaunchKeyboardFront.capture(state, identity.account, identity.device), source,
                    erased = forgetting?.let { it != state.historyForgetting } == true, documentRevision = browser.tabletToolbarRevision.value)
                forgetting = state.historyForgetting
                launchKeyboard.loaded(source)
            } }
        }
        engine.restyleReaders(readerPreferences.snapshot())
        viewModelScope.launch { readerPreferences.state.collect { engine.restyleReaders(it) } }
        // Cefrium's adblock already covers tracking; the engine's ETP toggle is a no-op seam default.
        engine.setTrackingProtection(false)
        viewModelScope.launch {
            var previous = sync.accountRecords.value.let { listOf(it.account, it.epoch, it.device, it.removed) }
            sync.accountRecords.map { listOf(it.account, it.epoch, it.device, it.removed) }.distinctUntilChanged().collect { identity ->
                if (identity != previous) { previous = identity; browser.invalidateLocalOwnership() }
            }
        }
        viewModelScope.launch { agent.run() }
        viewModelScope.launch { approvals.observe() }
        viewModelScope.launch {
            sync.accountRecords.map { ShieldMacImport.project(it.records, it.account, it.removed) }
                .distinctUntilChanged().collect { shield.policies.importMac(it.enabled, it.paused) }
        }
        viewModelScope.launch {
            sync.accountRecords.map { dev.yab.reports.ReportPerson.project(it.records, it.account, it.removed) }
                .distinctUntilChanged().collect { reports.controller.person(it) }
        }
        engine.onState = browser::pageChanged
        engine.bindImageDownloads(imageDownloads)
        engine.popupPolicy = shield::checkPopup
        engine.onError = browser::message
        engine.onNewTab = { opener, url -> browser.openUrl(url, openerId = opener) }
        engine.createWindow = { opener, url -> browser.createEngineTab(url, openerId = opener)?.let { (tab, profile) ->
            engine.prepareWindow(tab, profile, select = true)
        } }
        engine.onCloseWindow = browser::closeEnginePopup
        viewModelScope.launch {
            combine(sync.arrivals, browser.state.map { it.loading }.distinctUntilChanged()) { arrivals, loading -> arrivals to loading }
                .collect { (arrivals, loading) -> if (!loading) arrivals.forEach { arrival ->
                    sync.takeArrival(arrival.id) { browser.openExternalUrl(it.url) }
                } }
        }
        viewModelScope.launch { sync.approvals.collect { approvals.replaceValidated(it) } }
        viewModelScope.launch {
            combine(browser.state, sync.accountRecords, sync.connection) { state, _, _ -> state }.collect { state ->
                // Account/Private revocation closes the native preview independently of Compose.
                engine.revalidateLinkPreview()
                if (privateDownloadAway && uiStarted && !state.privateContentBlocked) {
                    privateDownloadAway = false
                    // unlockPrivate publishes its model before native activate(). Let that
                    // synchronous Main call finish before testing the native session again.
                    yield()
                }
                downloads.revalidate()
                imageDownloads.revalidate()
            }
        }
        viewModelScope.launch { browser.state.map { it.settings.lockPrivate }.distinctUntilChanged().collect {
            engine.setPrivateMediaLock(it); media.setPolicy(it)
        } }
    }

    fun extensionsAllowed(): Boolean {
        if (!uiStarted || uiOwner == null) return false
        val state = browser.state.value
        return state.space?.isPrivate != true && !state.privateContentBlocked &&
            !(state.surface == BrowserSurface.FIELD && state.fieldPrivate)
    }

    /** The token is an Activity-independent identity, never the Activity itself. */
    fun attachUi(owner: Any, prompts: NativePagePrompts,
                 permissions: (Array<String>, (Boolean) -> Unit) -> Unit,
                 download: (PageDownloadSource) -> Unit, fullscreen: (Boolean) -> Unit) {
        uiOwner?.let(::detachUi)
        uiOwner = owner
        launchKeyboard.attach(owner)
        engine.rebindPrompts(prompts)
        engine.permissionRequest = permissions
        engine.onDownload = download
        engine.onFullscreen = fullscreen
    }

    fun startUi(owner: Any) {
        if (uiOwner !== owner) return
        uiStarted = true
        reports.foregrounded(false)
        shield.foreground()
        media.setVisible(true)
        browser.foregrounded(); engine.foreground(); sync.start()
    }

    fun stopUi(owner: Any) {
        if (uiOwner !== owner) return
        privateDownloadAway = downloads.state.value.owner?.let { transfer ->
            transfer.privateOrigin && (!browser.state.value.privateContentBlocked || privateDownloadAway) && downloadSourceAlive(transfer)
        } == true
        uiStarted = false
        reports.backgrounded()
        pageIdeas.cancel()
        shield.background()
        media.setVisible(false)
        engine.background(); browser.backgrounded(); sync.pause()
    }

    fun detachUi(owner: Any) {
        if (uiOwner !== owner) return
        engine.dismissContextMenu()
        uiStarted = false
        reports.backgrounded()
        pageIdeas.cancel()
        media.setVisible(false)
        extensionsManager.cancelPendingConsent()
        engine.exitFullscreen()
        engine.rebindPrompts(null)
        engine.releaseViews()
        engine.permissionRequest = { _, answer -> answer(false) }
        engine.onDownload = { it.close() }
        engine.onFullscreen = {}
        uiOwner = null
    }

    override fun onCleared() {
        firstRunPreparation.invalidate()
        mutableFirstRun.value?.close(); mutableFirstRun.value = null
        fieldEditorValues.close()
        uiOwner?.let(::detachUi)
        browserSync.close()
        macToday.close()
        parkedChats.close()
        downloads.close()
        imageDownloads.close()
        shield.close()
        reports.close()
        media.close()
        extensionsManager.close()
        engine.dispose()
        super.onCleared()
    }
}
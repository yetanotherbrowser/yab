package dev.yab.android

import android.app.role.RoleManager
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.util.Rational
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.withResumed
import androidx.lifecycle.Lifecycle
import dev.yab.agent.*
import dev.yab.browser.engine.GeckoEngine
import dev.yab.browser.engine.NativePagePrompts
import dev.yab.browser.engine.ExtensionHost
import dev.yab.browser.icons.AndroidSiteIcons
import dev.yab.browser.model.*
import dev.yab.browser.media.MediaOwner
import dev.yab.browser.media.PageMediaState
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.LocalBrowserChromeClipping
import dev.yab.browser.ui.pageTranslationMenu
import dev.yab.browser.ui.BrowserTabletPageAddressEntry
import dev.yab.browser.ui.BrowserTabletPageEnvironment
import dev.yab.browser.ui.BrowserTabletSidebarEntry
import dev.yab.browser.ui.BrowserTabletWorkspaceState
import dev.yab.browser.ui.BrowserTabletWorkspaceDrawingSource
import dev.yab.browser.ui.BrowserTabletWorkspaceDrawing
import dev.yab.browser.ui.BrowserTabletSidebarDrawingContext
import dev.yab.browser.ui.BrowserTabletToolbarEntry
import dev.yab.browser.ui.BrowserTabletGallerySource
import dev.yab.browser.ui.BrowserTabletNewTabRestingEntry
import dev.yab.browser.ui.BrowserTheme
import dev.yab.browser.ui.BrowserAccessibility
import dev.yab.browser.ui.BrowserSiteIconScope
import dev.yab.browser.ui.LocalBrowserSiteIcons
import dev.yab.nativefeatures.*
import dev.yab.notifications.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import org.mozilla.geckoview.GeckoView

class MainActivity : FragmentActivity() {
    private lateinit var browserSession: BrowserSessionViewModel
    private val browserUiOwner = Any()
    private lateinit var engine: GeckoEngine
    private lateinit var browser: BrowserController
    private lateinit var siteIcons: AndroidSiteIcons
    private lateinit var agent: AgentRepository
    private lateinit var models: LocalModelManager
    private lateinit var extensionsManager: GeckoSignedExtensionManager
    private lateinit var approvals: ApprovalController
    private var pendingAction by mutableStateOf<IncomingAction?>(null)
    private var incomingGeneration = 0L
    private var pageQuestion: kotlinx.coroutines.Job? = null
    private var pageQuestionDiagnosticEpoch = 0L
    internal var pageQuestionStage = PageQuestionStage.IDLE
        private set
    internal val pageQuestionActive get() = pageQuestion?.isActive == true
    private fun questionStage(value: PageQuestionStage) { if (BuildConfig.DEBUG) pageQuestionStage = value }
    private var nowEntrance: Job? = null
    private val privateAuthentication = PrivateAuthenticationAttempts()
    private var privateAuthenticationJob: Job? = null
    private var fullscreen by hardwareKeyTrackedState(mutableStateOf(false))
    private var pictureInPicture by hardwareKeyTrackedState(mutableStateOf(false))
    private var activityFocused by mutableStateOf(false)
    private var webPageAvailable = false
    private val projectPresentation = ChatProjectsPresentation()
    // Bounded state-only diagnostics for the owned native regression, never page/chat contents.
    internal var projectUiDiagnostics: (() -> Map<String, Boolean>)? = null
        private set
    private var hardwareKeyOwner: BrowserHardwareKeyHost? = null
    private var hardwareKeyAction: ((BrowserHardwareKey) -> Boolean)? = null
    private var hardwareHostGeneration by mutableLongStateOf(0L)
    private val hardwareKeysDown = mutableSetOf<Int>()
    private val interruptedHardwareKeys = mutableSetOf<Int>()
    private var pipOwner: MediaOwner? = null
    private var pipParameters: PictureInPictureParams? = null
    private lateinit var translator: PageTranslationController
    private lateinit var extensionHost: ExtensionHost
    private lateinit var webAuthn: dev.yab.browser.engine.NativeWebAuthnLauncher
    private var filesAnswer: ((List<android.net.Uri>) -> Unit)? = null
    private var filesOwnerTab: String? = null
    private var permissionsAnswer: ((Boolean) -> Unit)? = null
    private var requestedPermissions = emptySet<String>()
    private val filesPicker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { result ->
        val answer = filesAnswer
        val owner = filesOwnerTab
        filesAnswer = null; filesOwnerTab = null
        if (answer != null) lifecycleScope.launch {
            lifecycle.withResumed { }
            if (engine.selected != owner || engine.prompts?.awaitingFile != true) { answer(emptyList()); return@launch }
            if (result.isNotEmpty() && browser.state.value.privateContentBlocked) {
                val unlocked = BiometricApprovalGate(this@MainActivity).authenticate("Unlock your private tab to upload the file") != null
                browser.unlockPrivate(unlocked)
                if (!unlocked) { answer(emptyList()); return@launch }
            }
            answer(result)
        }
    }
    private val permissionsPicker = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val allowed = requestedPermissions.isNotEmpty() && requestedPermissions.all { result[it] == true }
        requestedPermissions = emptySet()
        permissionsAnswer?.invoke(allowed); permissionsAnswer = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        browserSession = ViewModelProvider(this)[BrowserSessionViewModel::class.java]
        engine = browserSession.engine
        siteIcons = AndroidSiteIcons.get(applicationContext)
        engine.siteIcons = siteIcons
        browser = browserSession.browser
        browser.invalidateWorkspaceWindow()
        extensionHost = browserSession.extensionHost
        models = browserSession.models
        agent = browserSession.agent
        approvals = browserSession.approvals
        extensionsManager = browserSession.extensionsManager
        translator = browserSession.translator
        val prompts = NativePagePrompts(this, { session ->
            engine.ownsInteractive(session) || (::extensionHost.isInitialized && extensionHost.popup.value === session && extensionsAllowed())
        }, canPresent = { webPageAvailable && projectPresentation.frame.value == null || (::extensionHost.isInitialized && extensionHost.popup.value != null && extensionsAllowed()) }) { types, answer ->
            filesAnswer?.invoke(emptyList()); filesOwnerTab = engine.selected; filesAnswer = answer; filesPicker.launch(types.ifEmpty { arrayOf("*/*") })
        }
        browserSession.attachUi(browserUiOwner, prompts, permissions = { permissions, answer ->
            if (!webPageAvailable || projectPresentation.frame.value != null) { answer(false); return@attachUi }
            permissionsAnswer?.invoke(false); requestedPermissions = permissions.toSet(); permissionsAnswer = answer; permissionsPicker.launch(permissions)
        }, download = { response ->
            if (webPageAvailable && projectPresentation.frame.value == null) browserSession.startDownload(response)
            else { response.body?.close(); browser.message("Return to the page to download this file") }
        }, fullscreen = { fullscreen = it })
        webAuthn = dev.yab.browser.engine.NativeWebAuthnLauncher(this, engine) {
            browser.state.value.let { webPageAvailable && projectPresentation.frame.value == null && engine.linkPreview.value == null && it.surface == BrowserSurface.PAGE && !it.privateContentBlocked && engine.interactiveSelected == it.tab?.id }
        }.also { it.attach() }
        if (savedInstanceState == null) pendingAction = incomingAction(intent)
        setContent {
            val themeState by browser.state.collectAsState()
            // One stable receiver for the chrome's clipping reports: the provider
            // below would otherwise rebuild the lambda on every state emission
            // and restart the chrome's effects on the fold's hot path.
            val chromeClip = remember(engine) {
                val report: (String?, dev.yab.browser.ui.BrowserChromeClipping) -> Unit =
                    { owner, clip -> engine.setChromeClipping(owner, clip.obscuredPx, clip.maxPx) }
                report
            }
            BrowserAccessibility { BrowserTheme(themeState.settings.appearance) {
                CompositionLocalProvider(LocalBrowserSiteIcons provides BrowserSiteIconScope(siteIcons,
                    themeState.space?.isPrivate != false || themeState.privateContentBlocked),
                    LocalBrowserChromeClipping provides chromeClip) { Content() }
            } }
        }
    }

    private fun firstRunAvailable(sync: dev.yab.sync.AndroidSyncBridge): Boolean =
        firstRunEntryAvailable(sync)
    private fun firstRunRole(): FirstRunPresentation.DefaultBrowser {
        val roles = getSystemService(RoleManager::class.java)
        return FirstRunPresentation.DefaultBrowser(roles?.isRoleAvailable(RoleManager.ROLE_BROWSER) == true,
            roles?.isRoleHeld(RoleManager.ROLE_BROWSER) == true)
    }
    private fun originalViewHaptic(view: android.view.View, event: FirstRunPresentation.Haptic) {
        view.performHapticFeedback(when (event) {
            FirstRunPresentation.Haptic.COPY -> android.view.HapticFeedbackConstants.CLOCK_TICK
            FirstRunPresentation.Haptic.JOINED -> if (Build.VERSION.SDK_INT >= 30) android.view.HapticFeedbackConstants.CONFIRM else android.view.HapticFeedbackConstants.CONTEXT_CLICK
            FirstRunPresentation.Haptic.CONFIRM -> android.view.HapticFeedbackConstants.CONTEXT_CLICK
        })
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun Content() {
        val state by browser.state.collectAsState()
        val projectFrame by projectPresentation.frame.collectAsState()
        val projectRevision by projectPresentation.revision.collectAsState()
        val projectCovered = projectFrame != null
        // Copy the value out of Compose's delegated State. Saved controls retain this render's value.
        val renderedProjectRevision = projectRevision
        fun projectUnderlayCurrent() = projectPresentation.revision.value == renderedProjectRevision && projectPresentation.frame.value == null
        val iconSpace = state.space
        val iconPages = iconSpace?.tabs?.map { it.url to it.isPrivate }
        LaunchedEffect(iconSpace?.id, iconSpace?.isPrivate, iconPages) {
            if (!state.loading && iconSpace != null && !iconSpace.isPrivate) { siteIcons.restoreKept(); siteIcons.prefetch(iconSpace) }
        }
        val darkWebsites = state.settings.darkenWebsites && (state.settings.appearance == BrowserAppearance.DARK || state.settings.appearance == BrowserAppearance.SYSTEM && isSystemInDarkTheme())
        val savedChats = rememberSaveable { mutableStateOf(false) }
        var chats by remember(savedChats) { hardwareKeyTrackedState(savedChats) }
        val savedTaskScreen = rememberSaveable { mutableStateOf(false) }
        var taskScreen by remember(savedTaskScreen) { hardwareKeyTrackedState(savedTaskScreen) }
        var taskFocus by rememberSaveable { mutableStateOf<String?>(null) }
        var page by remember { mutableStateOf<PageContext?>(null) }
        var syncSettings by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var extensions by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var voice by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var scanner by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var translating by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var pageOverlayMounted by remember { hardwareKeyTrackedState(mutableStateOf(false)) }
        var hardwareScreenCurrent by remember { mutableStateOf<(() -> Boolean)?>(null) }
        var pagingVisibility by remember(browser) { mutableStateOf<Pair<PageSwipeLease, Long?>?>(null) }
        var conversation by rememberSaveable { mutableStateOf<String?>(null) }
        var review by rememberSaveable { mutableStateOf<String?>(null) }
        val savedSharedPage = rememberSaveable { mutableStateOf<String?>(null) }
        var sharedPage by remember(savedSharedPage) { hardwareKeyTrackedState(savedSharedPage) }
        val validatedApprovals by (application as YabApplication).sync.approvals.collectAsState()
        val projectApprovalState by approvals.state.collectAsState()
        val projectApprovalFrame by approvals.trayPresentation.frame.collectAsState()
        fun projectApprovalUncovered(): Boolean {
            val review = approvals.state.value
            val drawn = approvals.trayPresentation.frame.value
            return review.busy == null && review.selected == null && review.receipts.isEmpty() &&
                (application as YabApplication).sync.approvals.value.none { it.id !in review.deferred } && drawn.content == null && !drawn.running
        }
        val projectApprovalCovered = !projectApprovalUncovered()
        val syncConnection by (application as YabApplication).sync.connection.collectAsState()
        val syncStatus by (application as YabApplication).sync.ui.collectAsState()
        val menuAccount by (application as YabApplication).sync.accountRecords.collectAsState()
        val menuAccountIdentity = Triple(menuAccount.account, menuAccount.device, menuAccount.epoch)
        val firstRun by browserSession.firstRun.collectAsState()
        val firstRunOwner = firstRun
        val firstRunState = firstRunOwner?.state?.collectAsState()?.value
        val firstRunNeeded = !state.loading && !state.settings.welcomed
        val firstRunWanted = firstRunNeeded && firstRunAvailable((application as YabApplication).sync)
        val firstRunShown = firstRunOwner != null || firstRunNeeded
        val browserOverlay = pageOverlayMounted || firstRunShown
        SideEffect {
            if (firstRunOwner == null && firstRunWanted) browserSession.beginFirstRun()
            else if (firstRunOwner != null && (state.settings.welcomed || firstRunState?.step == FirstRunPresentation.Step.FINISHED))
                browserSession.retireFirstRun(firstRunOwner)
        }
        val agentState by agent.state.collectAsState()
        val pageIdeasState by browserSession.pageIdeas.state.collectAsState()
        val parkedChat by browserSession.parkedChats.state.collectAsState()
        val downloadState by browserSession.downloads.state.collectAsState()
        val imagePreparation by browserSession.imageDownloads.preparation.collectAsState()
        val reportState by browserSession.reports.state.collectAsState()
        val activityLifecycle by lifecycle.currentStateFlow.collectAsState()
        val shieldPolicy by browserSession.shield.policies.state.collectAsState()
        val shieldStatus by browserSession.shield.state.collectAsState()
        val siteSettings by engine.siteSettings.state.collectAsState()
        val connections by engine.connections.collectAsState()
        val contextMenu by engine.contextMenu.collectAsState()
        val linkPreview by engine.linkPreview.collectAsState()
        LaunchedEffect(contextMenu?.id) { contextMenu?.takeIf { it.link != null }?.let { browserSession.openLinkPreview(it.id) } }
        val noPrompt = remember { kotlinx.coroutines.flow.MutableStateFlow(false) }
        val nativePrompt by (engine.prompts?.pending ?: noPrompt).collectAsState()
        fun askQuestion(words: String?, about: BrowserTab?, forceMac: Boolean, expectedMenu: PageMenuLease? = null) {
            val diagnosticEpoch = ++pageQuestionDiagnosticEpoch
            fun stage(value: PageQuestionStage) { if (pageQuestionDiagnosticEpoch == diagnosticEpoch) questionStage(value) }
            stage(PageQuestionStage.RECEIVED)
            val captured = browser.state.value
            if (captured.privateContentBlocked || captured.space?.isPrivate == true || captured.fieldPrivate || about?.isPrivate == true) { stage(PageQuestionStage.PRIVATE_REJECTED); return }
            if (words?.isBlank() == true) { stage(PageQuestionStage.WORDS_REJECTED); return }
            val source = incomingSource()
            val entrance = incomingGeneration
            val accountSource = (application as YabApplication).sync.accountRecords.value
            if (expectedMenu != null && (accountSource.removed || expectedMenu.account != accountSource.account ||
                expectedMenu.device != accountSource.device || expectedMenu.accountEpoch != accountSource.epoch ||
                expectedMenu.entrance != incomingGeneration || about == null || !expectedMenu.ownsSource(captured, about.url))) {
                stage(PageQuestionStage.ACCOUNT_CHANGED_BEFORE_READ); return
            }
            val account = accountSource.account
            val accountEpoch = accountSource.epoch
            val document = if (about == null) null else {
                (if (expectedMenu != null) expectedMenu.nativeOwner as? GeckoEngine.ExternalActivityOwner
                    else engine.captureExternalActivityOwner()) ?: run { stage(PageQuestionStage.OWNER_UNAVAILABLE); return }
            }
            fun originalMenuCurrent(): Boolean = expectedMenu?.let { menu ->
                val identity = (application as YabApplication).sync.accountRecords.value
                !identity.removed && identity.account == menu.account && identity.device == menu.device && identity.epoch == menu.accountEpoch &&
                    menu.entrance == incomingGeneration && about != null && menu.ownsSource(browser.state.value, about.url) &&
                    document != null && engine.ownsExternalActivity(document)
            } ?: true
            val uiSource = listOf(chats, taskScreen, syncSettings, extensions, sharedPage, conversation, review, voice, scanner, translating, fullscreen, pictureInPicture)
            val text = words?.trim()
            pageQuestion?.cancel()
            pageQuestion = lifecycleScope.launch {
                try {
                    stage(PageQuestionStage.LOADING_STORAGE)
                    agent.load()
                    if (!originalMenuCurrent()) { stage(PageQuestionStage.SOURCE_CHANGED_BEFORE_READ); return@launch }
                    if ((application as YabApplication).sync.let { it.connection.value.account != account || it.accountEpoch != accountEpoch }) { stage(PageQuestionStage.ACCOUNT_CHANGED_BEFORE_READ); return@launch }
                    if (incomingSource() != source) { stage(PageQuestionStage.SOURCE_CHANGED_BEFORE_READ); return@launch }
                    if (document?.let { !engine.ownsExternalActivity(it) } == true) { stage(PageQuestionStage.DOCUMENT_CHANGED_BEFORE_READ); return@launch }
                    val preferences = agent.state.value.preferences
                    val route = (application as YabApplication).sync.connection.value.let { listOf(it.selectedMac, it.route(preferences.provider)?.id) }
                    stage(PageQuestionStage.READING_PAGE)
                    val context = about?.let { tab -> engine.readText(tab).let { PageContext(it.title, it.url, it.text, false) } }
                    stage(PageQuestionStage.VALIDATING_PAGE)
                    val current = browser.state.value
                    if (!originalMenuCurrent()) { stage(PageQuestionStage.SOURCE_CHANGED); return@launch }
                    if (entrance != incomingGeneration) { stage(PageQuestionStage.ENTRANCE_CHANGED); return@launch }
                    if (incomingSource() != source) { stage(PageQuestionStage.SOURCE_CHANGED); return@launch }
                    if (current.fieldText != captured.fieldText) { stage(PageQuestionStage.FIELD_CHANGED); return@launch }
                    if (!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) { stage(PageQuestionStage.LIFECYCLE_HIDDEN); return@launch }
                    val connection = (application as YabApplication).sync.connection.value
                    if ((application as YabApplication).sync.accountEpoch != accountEpoch || connection.account != account) { stage(PageQuestionStage.ACCOUNT_CHANGED); return@launch }
                    if (listOf(connection.selectedMac, connection.route(preferences.provider)?.id) != route) { stage(PageQuestionStage.ROUTE_CHANGED); return@launch }
                    if (agent.state.value.preferences != preferences) { stage(PageQuestionStage.PREFERENCES_CHANGED); return@launch }
                    if (document?.let { !engine.ownsExternalActivity(it) } == true) { stage(PageQuestionStage.DOCUMENT_CHANGED); return@launch }
                    if (listOf(chats, taskScreen, syncSettings, extensions, sharedPage, conversation, review, voice, scanner, translating, fullscreen, pictureInPicture) != uiSource) { stage(PageQuestionStage.MODAL_CHANGED); return@launch }
                    if (about != null && (current.tab?.id != about.id || current.tab?.url != about.url)) { stage(PageQuestionStage.TAB_CHANGED); return@launch }
                    stage(PageQuestionStage.CREATING_CHAT)
                    agent.setPrivacy(false)
                    val chat = agent.newChat(context, ephemeral = text != null, forceMac = forceMac)
                    page = context; conversation = null; chats = true
                    if (text != null) browser.fieldText("")
                    browser.dismissSurface()
                    if (text != null) browserSession.sendQuestion(chat, text)
                    stage(if (text != null) PageQuestionStage.ANSWER_QUEUED else PageQuestionStage.CHAT_OPENED)
                } catch (cancelled: kotlinx.coroutines.CancellationException) { stage(PageQuestionStage.CANCELLED); throw cancelled }
                catch (_: Exception) {
                    stage(if (pageQuestionStage == PageQuestionStage.READING_PAGE) PageQuestionStage.PAGE_READ_FAILED else PageQuestionStage.FAILED)
                    browser.message("The page changed. Ask again from the current page.")
                }
            }
        }
        val taskSource = taskOrigin(state)
        SideEffect { (application as YabApplication).sync.updateTaskScope(taskSource) }
        val extensionState by extensionsManager.state.collectAsState()
        val extensionActions by extensionHost.rows.collectAsState()
        val extensionPopup by extensionHost.popup.collectAsState()
        val popupTitle by extensionHost.popupTitle.collectAsState()
        val thumbnails by engine.thumbnails.collectAsState()
        val mediaPages by engine.media.collectAsState()
        val workspaceWindowState by browser.workspaceWindow.collectAsState()
        val renderedWindowConfiguration = Configuration(LocalConfiguration.current)
        val windowSize = LocalWindowInfo.current.containerSize
        val windowDensity = LocalDensity.current.density.toDouble()
        val workspaceWindow = BrowserWorkspaceWindow(windowSize.width / windowDensity, windowSize.height / windowDensity)
        val windowConfiguration = workspaceWindowState.configuration
        SideEffect {
            // Compose refreshes its window cache before publishing this configuration.
            // Refuse a render captured before the Activity's new configuration reached its View.
            if (renderedWindowConfiguration == this@MainActivity.resources.configuration)
                browser.commitWorkspaceWindow(windowConfiguration, workspaceWindow)
        }
        val workspaceLayout = BrowserWorkspaceLayout(workspaceWindow.width.toInt(), workspaceWindow.height.toInt(), state.workspace != null, workspaceWindow)
        val wide = workspaceLayout.expanded
        val pageVisible = !projectCovered && (!chats || workspaceLayout.pageVisibleWithConversation)
        val mayPresentDownload = downloadState.owner?.let { owner ->
            state.tab?.id == owner.tab && state.space?.websiteProfile?.id == owner.profile &&
                pageVisible && state.surface == BrowserSurface.PAGE && !state.privateContentBlocked &&
                !taskScreen && !syncSettings && !extensions && sharedPage == null && extensionPopup == null &&
                !browserOverlay && contextMenu == null && !voice && !scanner && !translating &&
                !nativePrompt && reportState.question == null && validatedApprovals.isEmpty() && !fullscreen && !pictureInPicture &&
                activityLifecycle.isAtLeast(Lifecycle.State.RESUMED)
        } == true
        val streamDownloadDialog = mayPresentDownload && downloadState.phase in setOf(PageDownloadPhase.TRANSFERRING,
            PageDownloadPhase.READY, PageDownloadPhase.FAILED, PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
        val mayPresentImage = imagePreparation?.let { preparing ->
            state.tab?.id == preparing.owner.tab && state.space?.websiteProfile?.id == preparing.owner.profile &&
                browserSession.imageDownloads.preparationCurrent(preparing) && pageVisible && state.surface == BrowserSurface.PAGE && !state.privateContentBlocked &&
                !taskScreen && !syncSettings && !extensions && sharedPage == null && extensionPopup == null &&
                !browserOverlay && contextMenu == null && !voice && !scanner && !translating && !nativePrompt &&
                reportState.question == null && validatedApprovals.isEmpty() && !fullscreen && !pictureInPicture && activityLifecycle.isAtLeast(Lifecycle.State.RESUMED)
        } == true
        val downloadDialog = streamDownloadDialog || mayPresentImage
        val pageContextAllowed = pageVisible && !state.privateContentBlocked &&
            !taskScreen && !syncSettings && !extensions && sharedPage == null && extensionPopup == null &&
            !voice && !scanner && !translating && !nativePrompt && reportState.question == null &&
            !downloadDialog && validatedApprovals.isEmpty() && !fullscreen && !pictureInPicture &&
            activityLifecycle.isAtLeast(Lifecycle.State.RESUMED)
        val pagingContextAllowed = pageContextAllowed && contextMenu == null
        val mayShowHeldMenu = pagingContextAllowed && state.surface == BrowserSurface.PAGE && !browserOverlay
        val mayKeepHeldMenu = pageContextAllowed && state.surface == BrowserSurface.PAGE && !browserOverlay
        val historyInputAllowed = rememberUpdatedState(mayShowHeldMenu)
        val historySwipeHost = remember(browser) { dev.yab.browser.ui.BrowserHistorySwipeHostState(browser) { historyInputAllowed.value } }
        SideEffect { engine.setHistorySwipeConsumer(historySwipeHost) }
        DisposableEffect(engine, historySwipeHost) {
            onDispose { historySwipeHost.cancel(); engine.setHistorySwipeConsumer(null) }
        }
        LaunchedEffect(mayKeepHeldMenu) { if (!mayKeepHeldMenu) engine.dismissContextMenu() }
        PageDownloadDialog(browserSession.downloads, mayPresentDownload)
        dev.yab.browser.download.OwnedImageDownloadDialog(browserSession.imageDownloads, mayPresentImage)
        SideEffect {
            webPageAvailable = pageVisible && state.surface == BrowserSurface.PAGE && !state.privateContentBlocked &&
                !taskScreen && !syncSettings && !extensions && sharedPage == null && extensionPopup == null &&
                !browserOverlay && contextMenu == null && !voice && !scanner && !translating && reportState.question == null && !downloadDialog
        }
        LaunchedEffect(extensionState.installed) { extensionHost.reconcile(extensionState.installed.map { it.id }.toSet()) }
        LaunchedEffect(state.space?.isPrivate, state.fieldPrivate, state.privateContentBlocked) {
            if (!extensionsAllowed()) extensionHost.closePopup()
        }
        val darkChrome = state.settings.appearance == BrowserAppearance.DARK ||
            state.settings.appearance == BrowserAppearance.SYSTEM && isSystemInDarkTheme() ||
            state.space?.isPrivate == true && state.surface !in setOf(BrowserSurface.SETTINGS, BrowserSurface.HISTORY) && !syncSettings
        LaunchedEffect(darkChrome) {
            val bars = androidx.core.view.WindowInsetsControllerCompat(window, window.decorView)
            bars.isAppearanceLightStatusBars = !darkChrome
            bars.isAppearanceLightNavigationBars = !darkChrome
        }
        LaunchedEffect(fullscreen) {
            val bars = androidx.core.view.WindowInsetsControllerCompat(window, window.decorView)
            if (fullscreen) bars.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            else bars.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        }
        val pipMedia = mediaPages.firstOrNull { it.owner.tabId == state.tab?.id && it.playing && it.fullscreen && it.hasVideo &&
            it.mayExport(state.settings.lockPrivate) && !state.privateContentBlocked && state.surface == BrowserSurface.PAGE && fullscreen &&
            !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && extensionPopup == null && sharedPage == null }
        LaunchedEffect(pipMedia) { configurePictureInPicture(pipMedia) }
        val translationState by translator.state.collectAsState()
        val translationProjection by translator.menu.collectAsState()
        val translationTarget = LocalConfiguration.current.locales[0].toLanguageTag()
        val translationVisible = !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && extensionPopup == null && sharedPage == null &&
            !state.privateContentBlocked && state.surface == BrowserSurface.PAGE && state.settings.welcomed
        LaunchedEffect(translator, translationTarget, translationVisible) {
            translator.observe(translationTarget, translationVisible)
        }
        val mayShowTranslationPrompt by rememberUpdatedState(translationVisible && !browserOverlay && !pageOverlayMounted &&
            !downloadDialog && !voice && !scanner && !translating && !fullscreen && !pictureInPicture && contextMenu == null && !nativePrompt && reportState.question == null)
        val translationOriginal = if (!translationVisible) null else translationProjection?.takeIf {
            it.page == translationState && it.owner.tabId == state.tab?.id && it.url == state.tab?.url &&
                it.owner.privateOrigin == (state.space?.isPrivate == true || state.tab?.isPrivate == true)
        }
        val translationMenuUi = remember(translationOriginal, state.page.readerEnabled) {
            translationOriginal?.let { original ->
                fun promptIfNeeded() {
                    if (translator.menuDocumentCurrent(original) && mayShowTranslationPrompt &&
                        translator.state.value.phase in setOf(TranslationPhase.NEED_MODEL, TranslationPhase.FAILED)) translating = true
                }
                pageTranslationMenu(original,
                    onToggle = { lifecycleScope.launch { if (translator.toggleFromMenu(original)) promptIfNeeded() } },
                    onAlways = { lifecycleScope.launch { if (translator.alwaysFromMenu(original, translateNow = !state.page.readerEnabled)) promptIfNeeded() } })
            }
        }
        val ideasChat = agentState.current
        val ideasTab = state.tab
        val sync = (application as YabApplication).sync
        val ideasEligible = chats && !taskScreen && !syncSettings && !extensions && sharedPage == null &&
            !state.privateContentBlocked && state.space?.isPrivate != true && !state.fieldPrivate &&
            ideasChat?.let { !it.privateOrigin && it.owner == null && it.messages.isEmpty() && it.draft.isBlank() && it.delivery == DeliveryState.IDLE } == true &&
            ideasTab?.let { !it.isPrivate && !it.isBlank } == true && state.surface == BrowserSurface.PAGE && !state.page.loading && syncStatus.phase != "removed"
        val ideasNative = if (ideasEligible) engine.captureExternalActivityOwner() else null
        val ideasOwner = if (ideasNative != null && ideasTab != null) state.space?.websiteProfile?.let { profile ->
            PageIdeasOwner(syncConnection.account, sync.accountEpoch, ideasTab.id, profile.id, ideasNative.document, ideasTab.url, title = ideasTab.title)
        } else null
        val ideasEntrance = incomingGeneration
        val ideasPageCurrent: () -> Boolean = {
            val current = browser.state.value
            projectUnderlayCurrent() && ideasOwner != null && ideasNative != null && chats && !taskScreen && !syncSettings && !extensions && sharedPage == null &&
                incomingGeneration == ideasEntrance && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
                current.surface == BrowserSurface.PAGE && !current.privateContentBlocked && current.space?.isPrivate != true && !current.fieldPrivate &&
                current.tab?.id == ideasOwner.tab && current.tab?.url == ideasOwner.url && current.space?.websiteProfile?.id == ideasOwner.profile &&
                !current.page.loading && sync.connection.value.account == ideasOwner.account && sync.accountEpoch == ideasOwner.accountEpoch &&
                sync.ui.value.phase != "removed" && engine.ownsExternalActivity(ideasNative)
        }
        LaunchedEffect(ideasOwner, ideasChat?.id) {
            if (ideasOwner == null || ideasTab == null) browserSession.pageIdeas.cancel()
            else browserSession.pageIdeas.request(ideasOwner, isCurrent = {
                ideasPageCurrent() && agent.state.value.current?.let { it.id == ideasChat?.id && it.messages.isEmpty() && it.draft.isBlank() && it.owner == null && !it.privateOrigin } == true
            }, readPage = { engine.readText(ideasTab).let { PageContext(it.title, it.url, it.text) } })
        }
        DisposableEffect(browserSession.pageIdeas) { onDispose { browserSession.pageIdeas.cancel() } }
        LaunchedEffect(state.loading, pendingAction) {
            if (!state.loading) {
                val action = pendingAction ?: return@LaunchedEffect
                pendingAction = null
                if (!state.settings.welcomed) browser.updateSettings(state.settings.copy(welcomed = true))
                chats = false; taskScreen = false; taskFocus = null; syncSettings = false; extensions = false; page = null
                sharedPage = null; voice = false; scanner = false; translating = false
                when (action) {
                    is IncomingAction.Page -> browser.openExternalUrl(action.url)
                    is IncomingAction.SharedPage -> { publicSpace(); sharedPage = action.url }
                    is IncomingAction.Search -> { publicSpace(); browser.openField(privately = false); browser.fieldPrivacy(false); browser.fieldText(action.words) }
                    is IncomingAction.Join -> { (application as YabApplication).sync.join(action.code); syncSettings = true }
                    is IncomingAction.Review -> { publicSpace(); browser.dismissSurface(); agent.setPrivacy(false); review = action.id; chats = true }
                    is IncomingAction.Task -> { publicSpace(); taskFocus = action.id; taskScreen = true }
                    is IncomingAction.Now -> {
                        nowEntrance?.cancel()
                        val turn = incomingGeneration
                        val source = incomingSource()
                        val session = browserSession
                        nowEntrance = lifecycleScope.launch {
                            val sync = (application as YabApplication).sync
                            val url = try { sync.resolveNowLink(action.address) }
                            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                            catch (_: Exception) { null }
                            if (turn != incomingGeneration || browserSession !== session || incomingSource() != source || !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return@launch
                            if (url != null && !sync.isNowLinkCurrent(action.address, url)) return@launch
                            publicSpace()
                            if (url != null) browser.openExternalUrl(url)
                            else { browser.openField(privately = false); browser.message("This Now item is no longer available") }
                        }
                    }
                    IncomingAction.NewTab -> { publicSpace(); browser.openField(); browser.fieldPrivacy(false) }
                    IncomingAction.Ask -> { publicSpace(); browser.dismissSurface(); agent.setPrivacy(false); agent.newChat(); conversation = null; chats = true }
                    IncomingAction.Private -> browser.openField(privately = true)
                    IncomingAction.Scan -> scanner = true
                }
            }
        }
        LaunchedEffect(review, validatedApprovals) {
            review?.let { if (approvals.select(it)) review = null }
        }
        SideEffect {
            val privateContext = state.space?.isPrivate == true || state.surface == BrowserSurface.FIELD && state.fieldPrivate
            // Debug builds on an owned emulator may film Private: nothing else can check its frames.
            val filmed = BuildConfig.DEBUG && Settings.Global.getInt(contentResolver, "yab_capture_private", 0) == 1
            if ((privateContext || syncSettings) && !filmed) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        val mayAskForReports = state.settings.welcomed && !state.privateContentBlocked && state.space?.isPrivate != true &&
            !state.fieldPrivate && state.surface == BrowserSurface.PAGE && !chats && !projectCovered && !taskScreen && !syncSettings && !extensions &&
            !voice && !scanner && !translating && !fullscreen && !pictureInPicture && sharedPage == null && extensionPopup == null &&
            !nativePrompt && !browserOverlay && contextMenu == null && !downloadDialog && validatedApprovals.isEmpty() && activityLifecycle.isAtLeast(Lifecycle.State.RESUMED) &&
            (activityFocused || reportState.question != null)
        SideEffect { browserSession.reports.presentationAllowed(mayAskForReports) }
        if (mayAskForReports) dev.yab.reports.CrashReportQuestion(browserSession.reports.controller)
        LaunchedEffect(state.privateContentBlocked) {
            if (state.privateContentBlocked) { chats = false; taskScreen = false; taskFocus = null; page = null; voice = false; scanner = false; translating = false; agent.setPrivacy(false) }
        }
        BackHandler(chats || taskScreen || syncSettings || extensions || fullscreen || sharedPage != null) {
            if (sharedPage != null) sharedPage = null
            else if (fullscreen) { engine.exitFullscreen(); fullscreen = false }
            else { chats = false; taskScreen = false; taskFocus = null; syncSettings = false; extensions = false; review = null }
        }
        fun pageMenuEnvironmentCurrent(lease: PageMenuLease): Boolean {
            if (!projectUnderlayCurrent()) return false
            val identity = sync.accountRecords.value
            val native = lease.nativeOwner as? GeckoEngine.ExternalActivityOwner ?: return false
            if (lease.url == null) return false
            return !identity.removed && Triple(identity.account, identity.device, identity.epoch) ==
                Triple(lease.account, lease.device, lease.accountEpoch) && menuAccountIdentity ==
                Triple(lease.account, lease.device, lease.accountEpoch) && lease.entrance == incomingGeneration &&
                browser.workspaceWindow.value.let { it.geometry?.valid == true && it.generation == lease.windowGeneration } &&
                native.session.settings.contextId == lease.profile.id &&
                native.session.settings.usePrivateMode == lease.profile.isPrivate && engine.ownsExternalActivity(native) &&
                lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() &&
                !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                !fullscreen && !pictureInPicture && sharedPage == null && extensionPopup == null &&
                !nativePrompt && engine.contextMenu.value == null && !downloadDialog && validatedApprovals.isEmpty() && reportState.question == null
        }
        fun currentPageMenu(lease: PageMenuLease): Boolean = pageMenuEnvironmentCurrent(lease) &&
            lease.url?.let { lease.ownsSource(browser.state.value, it) } == true
        // Only the captured address handoff may retain the old menu's pixels over its Field.
        // The outgoing PAGE lease still cannot authorize an action on that surface.
        fun currentPageMenuField(lease: PageMenuLease, input: FieldInputLease): Boolean =
            pageMenuEnvironmentCurrent(lease) && browser.fieldInputCurrent(input) &&
                lease.url?.let { lease.ownsDrawnField(browser.state.value, input, it) } == true
        // Capture once in this render. The saved control never reacquires a native owner,
        // account, Activity entrance, configuration or registered-window generation.
        val addressSource = state
        val addressView = LocalView.current
        val addressWindow = window
        val addressDecor = addressWindow.decorView
        var addressPlacement by remember(addressView, addressDecor) { mutableStateOf<List<Any?>>(emptyList()) }
        var tabletDrawRoot by remember(addressView, addressDecor) { mutableStateOf<Pair<Long, TabletOmniboxRoot>?>(null) }
        val addressRoot = addressView.rootView
        val addressToken = addressView.windowToken
        val addressIntent = intent
        val addressEntrance = incomingGeneration
        val addressConfiguration = Configuration(resources.configuration)
        val addressFrame = tabletAddressWindowFrame(addressWindow)
        val addressViewSize = addressView.width to addressView.height
        val addressDecorSize = addressDecor.width to addressDecor.height
        val addressCovered = projectCovered || chats || taskScreen || syncSettings || extensions || voice || scanner || translating ||
            fullscreen || pictureInPicture || sharedPage != null || extensionPopup != null || nativePrompt ||
            browserOverlay || contextMenu != null || linkPreview != null || downloadDialog || validatedApprovals.isNotEmpty() || reportState.question != null
        val launchArrival by browserSession.launchKeyboard.arrival.collectAsState()
        val launchSource = browserSession.launchKeyboardSource()
        val launchCovered by rememberUpdatedState(addressCovered || firstRunShown || pendingAction != null || state.find != null)
        LaunchedEffect(launchArrival, launchSource, activityFocused, activityLifecycle, addressToken, addressViewSize, launchCovered) {
            val original = launchArrival ?: return@LaunchedEffect
            val source = launchSource ?: return@LaunchedEffect
            val presentation = browserSession.launchKeyboard
            if (!presentation.current(original, source)) { presentation.retire(original); return@LaunchedEffect }
            val front = LaunchKeyboardFront.capture(state, source.account, source.device)
            val situation = LaunchKeyboardPolicy.Situation(original.moment, state.settings.openKeyboardAtLaunch,
                original.asked, !state.settings.welcomed || firstRunShown,
                state.space?.isPrivate == true || state.tab?.isPrivate == true || state.privateContentBlocked,
                launchCovered || state.surface != BrowserSurface.PAGE, !state.emptyHome,
                presentation.cache.cold.scrollFor(front), presentation.cache.cold.ownedAway(front, original.awayMillis))
            if (!LaunchKeyboardPolicy.opens(situation) || source.removed || !source.active) {
                presentation.retire(original); return@LaunchedEffect
            }
            if (!activityFocused || !activityLifecycle.isAtLeast(Lifecycle.State.RESUMED) || addressToken == null ||
                !addressView.isAttachedToWindow || !addressView.isShown || addressViewSize.first <= 0 || addressViewSize.second <= 0) return@LaunchedEffect
            val originalSession = browserSession
            val originalIntent = addressIntent
            val originalEntrance = addressEntrance
            val originalConfiguration = addressConfiguration
            val originalFrame = addressFrame
            // Same normal main-turn ordering as Phone: entrances go first. No timer,
            // new PAGE capture, private switch, or authority acquired after suspension.
            kotlinx.coroutines.yield()
            presentation.consume(original, source, current = {
                browserSession === originalSession && browserSession.launchKeyboardSource() == source &&
                    intent === originalIntent && incomingGeneration == originalEntrance &&
                    resources.configuration == originalConfiguration && window === addressWindow && window.decorView === addressDecor &&
                    tabletAddressWindowFrame(addressWindow) == originalFrame && originalFrame.width() > 0 && originalFrame.height() > 0 &&
                    addressView.isAttachedToWindow && addressView.isShown && addressView.rootView === addressRoot &&
                    addressRoot === addressDecor && addressView.windowToken === addressToken && addressView.hasWindowFocus() && hasWindowFocus() &&
                    lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && !launchCovered &&
                    browser.state.value.let { !it.loading && it.settings.openKeyboardAtLaunch && it.settings.welcomed &&
                        it.surface == BrowserSurface.PAGE && !it.privateContentBlocked && it.space?.isPrivate != true && it.tab?.isPrivate != true }
            }, open = {
                // Nothing in the stack: a pin left in front gives way to the empty screen.
                if (browser.state.value.galleryTabs.size <= 1) browser.letGoFront()
                browser.openField(newTab = true, privately = false)
            })
        }
        // Welcome gone with no tab: search, as a launch with none has.
        var welcomeUp by remember { mutableStateOf(false) }
        LaunchedEffect(firstRunShown) {
            if (firstRunShown) welcomeUp = true
            else if (welcomeUp) {
                welcomeUp = false
                if (browser.state.value.let { it.emptyHome && it.settings.openKeyboardAtLaunch && it.surface == BrowserSurface.PAGE }) browser.openField()
            }
        }
        // Only a real current native document can replace RAM scroll knowledge.
        // The immutable cold cache remains the launch decision's input throughout.
        SideEffect {
            val page = state.tab?.id?.let(state.pageStates::get)
            val front = LaunchKeyboardFront.capture(state, menuAccount.account, menuAccount.device)
            val native = if (front != null && page != null && !launchCovered && state.surface == BrowserSurface.PAGE &&
                !page.frameUncertain && !page.loading && page.error == null && page.progress >= 1f && page.url == front.url && activityFocused && webPageAvailable &&
                addressView.isAttachedToWindow && addressView.hasWindowFocus()) engine.captureExternalActivityOwner() else null
            val scroll = page?.let { if (it.userScrollY > 0f) it.userScrollY.toDouble() else if (it.scrollY == 0f) 0.0 else null }
            if (front != null && native != null && scroll != null && native.tab == front.tab &&
                native.session.settings.contextId == front.profile && !native.session.settings.usePrivateMode && engine.ownsExternalActivity(native) && engine.ownsInteractive(native.session) &&
                browser.state.value === state && sync.accountRecords.value.let { it.account == menuAccount.account && it.device == menuAccount.device &&
                    it.epoch == menuAccount.epoch && !it.removed } && browserSession.launchKeyboard.observationsAllowed(browserUiOwner))
                launchSource?.let { browserSession.launchKeyboard.cache.observe(front, scroll, it, native, browser.tabletToolbarRevision.value) }
        }
        val (addressModel, addressAccount) = captureTabletAddressSource(addressSource,
            addressConfiguration.smallestScreenWidthDp, !addressCovered && renderedWindowConfiguration == addressConfiguration)
        val sidebarRevision by browser.tabletSidebarRevision.collectAsState()
        val sidebarModel = captureTabletSidebarSource(addressSource, addressConfiguration.smallestScreenWidthDp,
            !addressCovered && renderedWindowConfiguration == addressConfiguration, sidebarRevision)
        val addressNative = if (addressModel?.target is TabletPageTarget.Tab) engine.captureExternalActivityOwner() else null
        val addressNativeInteractive = addressNative?.let { engine.ownsExternalActivity(it) && engine.ownsInteractive(it.session) } == true
        // ExternalActivityOwner itself is a new object on each read. Its actual native
        // session/document tuple is stable across title, Keep and progress publications.
        val tabletPageEnvironment = remember(browserSession, browser, engine, addressModel,
            addressAccount.account, addressAccount.device, addressAccount.epoch, addressAccount.removed, projectRevision,
            addressView, addressRoot, addressWindow, addressDecor, addressToken, addressIntent, addressEntrance,
            addressConfiguration, addressFrame, addressViewSize, addressDecorSize, addressPlacement, workspaceWindowState.generation,
            addressNative?.tab, addressNative?.session, addressNative?.document, addressNativeInteractive, activityFocused, activityLifecycle, addressCovered) {
            val original = addressModel
            val native = addressNative
            val originalSession = browserSession
            val originalBrowser = browser
            val originalEngine = engine
            val originalWindow = workspaceWindowState
            if (original == null || original.target is TabletPageTarget.Tab && (native == null || !addressNativeInteractive)) null
            else BrowserTabletPageEnvironment {
                val transfer = originalSession.downloads.state.value
                val transferCovered = transfer.owner?.let { it.tab == addressSource.tab?.id && it.profile == original.profile.id } == true &&
                    transfer.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED,
                        PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
                val preparing = originalSession.imageDownloads.preparation.value
                browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                    window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                    addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                    addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                    addressViewSize.first > 0 && addressViewSize.second > 0 && addressDecorSize.first > 0 && addressDecorSize.second > 0 &&
                    (addressView.width to addressView.height) == addressViewSize && (addressDecor.width to addressDecor.height) == addressDecorSize &&
                    intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                    tabletAddressWindowFrame(addressWindow) == addressFrame && addressFrame.width() > 0 && addressFrame.height() > 0 &&
                    originalBrowser.workspaceWindow.value.let { it.registered && it.generation == originalWindow.generation &&
                        it.configuration == originalWindow.configuration && it.geometry == originalWindow.geometry && it.geometry?.valid == true } &&
                    projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() &&
                    !isFinishing && !isDestroyed && !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                    !fullscreen && !pictureInPicture && !browserOverlay && sharedPage == null && extensionHost.popup.value == null &&
                    engine.prompts?.pending?.value != true && originalEngine.contextMenu.value == null && originalEngine.linkPreview.value == null &&
                    !transferCovered && (preparing == null || !originalSession.imageDownloads.preparationCurrent(preparing)) &&
                    sync.approvals.value.isEmpty() && originalSession.reports.state.value.question == null &&
                    when (val target = original.target) {
                        is TabletPageTarget.Tab -> native != null && native.tab == target.id &&
                            native.session.settings.contextId == original.profile.id && native.session.settings.usePrivateMode == original.profile.isPrivate &&
                            originalEngine.ownsExternalActivity(native) && originalEngine.ownsInteractive(native.session)
                        TabletPageTarget.Empty -> addressSource.tab == null && addressSource.space?.currentTabId == null
                    }
            }
        }
        DisposableEffect(tabletPageEnvironment) { onDispose { tabletPageEnvironment?.retire() } }
        val tabletPageAddress = remember(browser, addressModel, tabletPageEnvironment) {
            val original = addressModel
            val environment = tabletPageEnvironment
            if (original == null || environment == null) null
            else BrowserTabletPageAddressEntry(browser, original, environment::current)
        }
        DisposableEffect(tabletPageAddress) { onDispose { tabletPageAddress?.retire() } }
        // Sidebar controls retain the original78 PAGE/native/account environment.
        val tabletSidebar = remember(browser, sidebarModel, sidebarRevision, tabletPageEnvironment) {
            val original = sidebarModel
            val environment = tabletPageEnvironment
            if (original == null || environment == null) null else BrowserTabletSidebarEntry(browser, original, environment)
        }
        DisposableEffect(tabletSidebar) { onDispose { tabletSidebar?.retire() } }
        val toolbarRevision by browser.tabletToolbarRevision.collectAsState()
        val tabletToolbar = remember(tabletSidebar, tabletPageEnvironment, toolbarRevision,
            addressNative?.tab, addressNative?.session, addressNative?.document) {
            val originalPage = sidebarModel
            val originalEntry = tabletSidebar
            val originalSource = addressSource
            val originalNative = addressNative
            val originalSession = browserSession
            val originalBrowser = browser
            val originalEngine = engine
            val originalWindow = workspaceWindowState
            if (originalPage == null || originalEntry == null) null else {
                // Retained menu/Gallery drawing only. PAGE admission still uses the strict
                // original78 environment, including browserOverlay. Each retained consumer
                // separately checks its exact source surface/epoch and opening identity.
                val retainedContext = {
                    val transfer = originalSession.downloads.state.value
                    val transferCovered = transfer.owner?.let { it.tab == originalSource.tab?.id && it.profile == originalPage.space.websiteProfile.id } == true &&
                        transfer.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED,
                            PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
                    val preparing = originalSession.imageDownloads.preparation.value
                    browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                        window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                        addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                        addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                        addressViewSize.first > 0 && addressViewSize.second > 0 && addressDecorSize.first > 0 && addressDecorSize.second > 0 &&
                        (addressView.width to addressView.height) == addressViewSize && (addressDecor.width to addressDecor.height) == addressDecorSize &&
                        intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                        tabletAddressWindowFrame(addressWindow) == addressFrame && addressFrame.width() > 0 && addressFrame.height() > 0 &&
                        originalBrowser.workspaceWindow.value == originalWindow && originalWindow.registered && originalWindow.geometry?.valid == true &&
                        originalBrowser.settingsPresentationLifetime.value.let {
                            it.active && it.generation == originalPage.foreground && it.privateBoundary == originalPage.privateBoundary
                        } && projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() &&
                        !isFinishing && !isDestroyed && !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                        !fullscreen && !pictureInPicture && sharedPage == null && extensionHost.popup.value == null &&
                        engine.prompts?.pending?.value != true && originalEngine.contextMenu.value == null && originalEngine.linkPreview.value == null &&
                        !transferCovered && (preparing == null || !originalSession.imageDownloads.preparationCurrent(preparing)) &&
                        sync.approvals.value.isEmpty() && originalSession.reports.state.value.question == null &&
                        originalSource.tab?.let { front -> originalNative != null && originalNative.tab == front.id &&
                            originalNative.session.settings.contextId == originalPage.space.websiteProfile.id &&
                            originalNative.session.settings.usePrivateMode == originalPage.space.websiteProfile.isPrivate &&
                            originalEngine.ownsExternalActivity(originalNative) } != false
                }
                val site = originalSource.tab?.takeIf { originalNative?.tab == it.id }?.let { front ->
                    PageMenuLease(addressAccount.account, addressAccount.epoch, front.id, originalPage.space.id,
                        originalPage.space.websiteProfile, checkNotNull(originalNative), originalSource.surfaceEpoch, 0,
                        addressAccount.device, addressEntrance, front.url, originalWindow.generation)
                }
                BrowserTabletToolbarEntry.capture(originalBrowser, originalEngine, originalEntry, originalSource,
                    toolbarRevision, site, retainedContext) { lease ->
                    retainedContext() && originalBrowser.historyPresentationLifetime.value == originalPage.sourceGeneration &&
                        currentPageMenu(lease)
                }
            }
        }
        DisposableEffect(tabletToolbar) { onDispose { tabletToolbar?.retire() } }
        // The drawing source is deliberately independent of coverage and metadata-only
        // Keep/title publications. Its layout lifetime cannot authorize a PAGE action.
        val tabletFramePreferences = remember(applicationContext) { getSharedPreferences("tablet-workspace", MODE_PRIVATE) }
        val tabletWorkspaceState = remember(browserSession, browser, engine, tabletFramePreferences) {
            BrowserTabletWorkspaceState(tabletFramePreferences.getBoolean("ipadPageFrame", true),
                initialSidebarWidth = tabletFramePreferences.getFloat("ipadSidebarWidth", 264f).toDouble(),
                initialSplitFraction = tabletFramePreferences.getFloat("ipadSplitFraction", .5f).toDouble(),
                persistDimensions = { width, fraction ->
                    tabletFramePreferences.edit().putFloat("ipadSidebarWidth", width.toFloat())
                        .putFloat("ipadSplitFraction", fraction.toFloat()).commit()
                }) { value ->
                tabletFramePreferences.edit().putBoolean("ipadPageFrame", value).commit()
            }
        }
        val tabletSourceGeneration by browser.historyPresentationLifetime.collectAsState()
        val tabletForeground by browser.settingsPresentationLifetime.collectAsState()
        // Retaining a view grants no action authority. Own IME and approval windows may
        // change focus/insets while the original account, namespace and window keep its draft.
        // Recreation can render a retained chat before this window's first layout.
        // A lifetime checked in that empty frame is retired permanently. The first
        // attached, sized frame therefore needs a fresh view owner. Positive IME
        // resizing keeps the same readiness and retains the cover's draft.
        val projectsViewReady = addressToken != null && addressView.isAttachedToWindow && addressView.isShown &&
            addressDecor.isAttachedToWindow && addressDecor.isShown && addressView.width > 0 && addressView.height > 0 &&
            addressDecor.width > 0 && addressDecor.height > 0
        val projectsView = remember(browserSession, browser, engine, projectsViewReady, addressAccount.account, addressAccount.device,
            addressAccount.epoch, addressAccount.removed, addressView, addressRoot, addressWindow, addressDecor, addressToken,
            addressIntent, addressEntrance, addressConfiguration, state.selectedSpaceId, state.space?.websiteProfile,
            tabletForeground.privateBoundary) {
            val originalSession = browserSession
            val originalBrowser = browser
            val originalEngine = engine
            val originalSpace = state.selectedSpaceId
            val originalProfile = state.space?.websiteProfile
            val originalBoundary = tabletForeground.privateBoundary
            ProjectUiLifetime {
                val current = originalBrowser.state.value
                browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                    originalProfile != null && !originalProfile.isPrivate && current.selectedSpaceId == originalSpace &&
                    current.space?.websiteProfile == originalProfile && !current.privateContentBlocked && !current.fieldIsPrivate &&
                    window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                    addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                    addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                    addressView.width > 0 && addressView.height > 0 && addressDecor.width > 0 && addressDecor.height > 0 &&
                    intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                    originalBrowser.settingsPresentationLifetime.value.privateBoundary == originalBoundary &&
                    sync.nativeOwnerCurrent(addressAccount) && !isFinishing && !isDestroyed
            }
        }
        DisposableEffect(projectsView) { onDispose { projectsView.retire() } }
        // Every action keeps the foreground/focus/foreign-cover generation of its own render.
        // A cancelled approval can return to the retained view with fresh controls only.
        // A lifetime observed while the window is unfocused is permanently retired.
        // Returning to RESUMED/focused must render fresh controls, just as losing
        // focus revokes the original ones; otherwise rotation can strand the chat.
        val projectsHost = remember(projectsView, tabletForeground, hardwareHostGeneration, activityFocused, activityLifecycle, chats,
            taskScreen, syncSettings, extensions, voice, scanner, translating, fullscreen, pictureInPicture,
            firstRunShown, pendingAction, sharedPage, extensionPopup, nativePrompt, contextMenu, linkPreview,
            validatedApprovals, projectApprovalState.presentationGeneration, projectApprovalFrame.content == null, projectApprovalFrame.running,
            projectApprovalCovered, reportState.question) {
            val originalGeneration = hardwareHostGeneration
            val originalChats = chats
            val originalForeground = tabletForeground
            val originalApprovalPresentation = projectApprovalState.presentationGeneration
            ProjectUiLifetime {
                projectsView.current() && hardwareHostGeneration == originalGeneration && chats == originalChats &&
                    browser.settingsPresentationLifetime.value == originalForeground && originalForeground.active &&
                    lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() &&
                    privateAuthenticationJob?.isActive != true && !taskScreen && !syncSettings && !extensions &&
                    !voice && !scanner && !translating && !fullscreen && !pictureInPicture && !firstRunShown &&
                    browser.state.value.settings.welcomed && pendingAction == null && sharedPage == null && extensionHost.popup.value == null &&
                    engine.prompts?.pending?.value != true && engine.contextMenu.value == null && engine.linkPreview.value == null &&
                    projectApprovalUncovered() && approvals.state.value.presentationGeneration == originalApprovalPresentation &&
                    browserSession.reports.state.value.question == null
            }
        }
        DisposableEffect(projectsHost) { onDispose { projectsHost.retire() } }
        LaunchedEffect(projectsView, projectsHost, projectFrame, agentState.connection, projectRevision, activityFocused, activityLifecycle) {
            projectPresentation.observe(agent.projects.value, agent.state.value.connection)
        }
        val ordinaryProjectChatCurrent = remember(projectsHost, projectRevision) {
            ProjectUiLifetime { projectsHost.current() && chats && projectUnderlayCurrent() }
        }
        DisposableEffect(ordinaryProjectChatCurrent) { onDispose { ordinaryProjectChatCurrent.retire() } }
        SideEffect {
            if (BuildConfig.DEBUG) projectUiDiagnostics = {
                mapOf("viewReady" to projectsViewReady, "viewRetired" to projectsView.retired, "hostRetired" to projectsHost.retired,
                    "chatRetired" to ordinaryProjectChatCurrent.retired, "chats" to chats,
                    "underlayCurrent" to projectUnderlayCurrent(), "focused" to hasWindowFocus(),
                    "resumed" to lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED),
                    "configurationCurrent" to (resources.configuration == addressConfiguration),
                    "windowCurrent" to (window === addressWindow && addressView.rootView === addressRoot &&
                        addressView.windowToken === addressToken && addressDecor.windowToken === addressToken),
                    "viewsShown" to (addressView.isShown && addressDecor.isShown),
                    "viewSized" to (addressView.width > 0 && addressView.height > 0),
                    "intentCurrent" to (intent === addressIntent && incomingGeneration == addressEntrance),
                    "accountCurrent" to sync.nativeOwnerCurrent(addressAccount),
                    "foregroundCurrent" to (browser.settingsPresentationLifetime.value == tabletForeground && tabletForeground.active),
                    "approvalUncovered" to projectApprovalUncovered())
            }
        }
        // The Field itself owns browserOverlay. Its terminal New Tab callback keeps
        // an original FIELD/native/account/window source instead of borrowing PAGE.
        val restingCovered = projectCovered || chats || taskScreen || syncSettings || extensions || voice || scanner || translating ||
            fullscreen || pictureInPicture || sharedPage != null || extensionPopup != null || nativePrompt ||
            contextMenu != null || linkPreview != null || downloadDialog || validatedApprovals.isNotEmpty() || reportState.question != null
        val hardwareRevision by browser.hardwareKeyRevision.collectAsState()
        // Native visibility settles after render; publish a fresh key registration when it does.
        var hardwareVisibilityGeneration by remember(browserSession, browser, engine) { mutableLongStateOf(0L) }
        val hardwareNative = state.tab?.let { engine.captureExternalActivityOwner() }
        val hardwareKeys = remember(browserSession, browser, engine, hardwareRevision, hardwareHostGeneration, hardwareVisibilityGeneration, tabletForeground,
            addressAccount.account, addressAccount.device, addressAccount.epoch, addressAccount.removed, projectRevision,
            addressView, addressRoot, addressWindow, addressDecor, addressToken, addressIntent, addressEntrance,
            addressConfiguration, addressFrame, addressViewSize, addressDecorSize, workspaceWindowState,
            renderedWindowConfiguration, hardwareNative?.tab, hardwareNative?.session, hardwareNative?.document,
            activityFocused, activityLifecycle, restingCovered, firstRunShown, pendingAction, hardwareScreenCurrent, browserOverlay) {
            val originalBrowser = browser
            val originalSession = browserSession
            val originalEngine = engine
            val originalSource = state
            val originalNative = hardwareNative
            val originalProfile = state.space?.websiteProfile
            val originalWindow = workspaceWindowState
            val originalLifetime = tabletForeground
            val originalHostGeneration = hardwareHostGeneration
            val originalVisibilityGeneration = hardwareVisibilityGeneration
            val originalScreen = hardwareScreenCurrent
            if (restingCovered || firstRunShown || pendingAction != null || originalScreen == null || !originalScreen() ||
                renderedWindowConfiguration != addressConfiguration || originalWindow.geometry != workspaceWindow ||
                state.surface != BrowserSurface.FIELD && browserOverlay ||
                state.tab != null && (originalNative == null || originalNative.tab != state.tab?.id)) null
            else {
                val originalContextCurrent: () -> Boolean = {
                    val transfer = originalSession.downloads.state.value
                    val transferCovered = transfer.owner?.let { it.tab == originalSource.tab?.id && it.profile == originalProfile?.id } == true &&
                        transfer.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED,
                            PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
                    val preparing = originalSession.imageDownloads.preparation.value
                    hardwareHostGeneration == originalHostGeneration &&
                        hardwareVisibilityGeneration == originalVisibilityGeneration &&
                        browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                        hardwareScreenCurrent === originalScreen && originalScreen() &&
                        window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                        addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                        addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                        addressViewSize.first > 0 && addressViewSize.second > 0 && addressDecorSize.first > 0 && addressDecorSize.second > 0 &&
                        (addressView.width to addressView.height) == addressViewSize && (addressDecor.width to addressDecor.height) == addressDecorSize &&
                        intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                        tabletAddressWindowFrame(addressWindow) == addressFrame && addressFrame.width() > 0 && addressFrame.height() > 0 &&
                        originalWindow.registered && originalWindow.geometry?.valid == true && originalBrowser.workspaceWindow.value == originalWindow &&
                        originalBrowser.settingsPresentationLifetime.value == originalLifetime && originalLifetime.active &&
                        projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() &&
                        !isFinishing && !isDestroyed && privateAuthenticationJob?.isActive != true &&
                        !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                        !fullscreen && !pictureInPicture && !firstRunShown && originalBrowser.state.value.settings.welcomed &&
                        pendingAction == null && sharedPage == null && extensionHost.popup.value == null &&
                        originalEngine.prompts?.pending?.value != true && originalEngine.contextMenu.value == null && originalEngine.linkPreview.value == null &&
                        !transferCovered && (preparing == null || !originalSession.imageDownloads.preparationCurrent(preparing)) &&
                        sync.approvals.value.isEmpty() && originalSession.reports.state.value.question == null &&
                        (originalSource.surface == BrowserSurface.FIELD || !browserOverlay)
                }
                val host = BrowserHardwareKeyHost(originalCurrent = {
                    originalContextCurrent() &&
                        if (originalSource.tab == null) originalNative == null && originalBrowser.state.value.space?.currentTabId == null
                        else originalNative != null && originalNative.session.settings.contextId == originalProfile?.id &&
                            originalNative.session.settings.usePrivateMode == originalProfile?.isPrivate && originalEngine.ownsExternalActivity(originalNative) &&
                            (originalSource.surface == BrowserSurface.FIELD || originalEngine.ownsInteractive(originalNative.session))
                }, originalContinuationCurrent = originalContextCurrent)
                host to BrowserHardwareKey.entries.associateWith { originalBrowser.captureHardwareKey(it, host) }
            }
        }
        SideEffect {
            val owner = hardwareKeys?.first
            if (hardwareKeyOwner !== owner) retireHardwareKeys()
            hardwareKeyOwner = owner
            val originalBrowser = browser
            hardwareKeyAction = hardwareKeys?.let { (_, commands) -> { key -> commands[key]?.let(originalBrowser::performHardwareKey) == true } }
        }
        DisposableEffect(hardwareKeys) { onDispose {
            hardwareKeys?.first?.retire()
            if (hardwareKeyOwner === hardwareKeys?.first) retireHardwareKeys()
        } }
        val restingNative = if (state.surface == BrowserSurface.FIELD && state.fieldIsNewTab && state.tab != null)
            engine.captureExternalActivityOwner() else null
        val tabletNewTabResting = remember(browserSession, browser, engine, state.surface, state.surfaceEpoch,
            state.selectedSpaceId, state.space?.websiteProfile, state.tab?.id, state.fieldIsNewTab, state.fieldIsPrivate,
            tabletSourceGeneration, tabletForeground, addressAccount.account, addressAccount.device, projectRevision,
            addressAccount.epoch, addressAccount.removed, addressView, addressRoot, addressWindow, addressDecor,
            addressToken, addressIntent, addressEntrance, addressConfiguration, addressFrame, addressViewSize,
            addressDecorSize, workspaceWindowState, renderedWindowConfiguration, restingNative?.tab,
            restingNative?.session, restingNative?.document, activityFocused, activityLifecycle, restingCovered) {
            val originalBrowser = browser
            val originalSession = browserSession
            val originalEngine = engine
            val originalNative = restingNative
            val originalTab = state.tab
            val originalProfile = state.space?.websiteProfile
            val originalWindow = workspaceWindowState
            val originalLifetime = tabletForeground
            val originalGeneration = tabletSourceGeneration
            if (restingCovered || renderedWindowConfiguration != addressConfiguration || originalWindow.geometry != workspaceWindow ||
                originalTab != null && (originalNative == null || originalNative.tab != originalTab.id)) null
            else BrowserTabletNewTabRestingEntry.capture(originalBrowser, tabletWorkspaceState,
                addressConfiguration.smallestScreenWidthDp) {
                val transfer = originalSession.downloads.state.value
                val transferCovered = transfer.owner?.let { it.tab == originalTab?.id && it.profile == originalProfile?.id } == true &&
                    transfer.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED,
                        PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
                val preparing = originalSession.imageDownloads.preparation.value
                browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                    window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                    addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                    addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                    addressViewSize.first > 0 && addressViewSize.second > 0 && addressDecorSize.first > 0 && addressDecorSize.second > 0 &&
                    (addressView.width to addressView.height) == addressViewSize && (addressDecor.width to addressDecor.height) == addressDecorSize &&
                    intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                    tabletAddressWindowFrame(addressWindow) == addressFrame && addressFrame.width() > 0 && addressFrame.height() > 0 &&
                    originalWindow.registered && originalWindow.geometry?.valid == true &&
                    originalBrowser.workspaceWindow.value == originalWindow &&
                    originalBrowser.settingsPresentationLifetime.value == originalLifetime && originalLifetime.active &&
                    originalBrowser.historyPresentationLifetime.value == originalGeneration && projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) &&
                    lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() && !isFinishing && !isDestroyed &&
                    !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                    !fullscreen && !pictureInPicture && sharedPage == null && extensionHost.popup.value == null &&
                    originalEngine.prompts?.pending?.value != true && originalEngine.contextMenu.value == null && originalEngine.linkPreview.value == null &&
                    !transferCovered && (preparing == null || !originalSession.imageDownloads.preparationCurrent(preparing)) &&
                    sync.approvals.value.isEmpty() && originalSession.reports.state.value.question == null &&
                    if (originalTab == null) originalNative == null && originalBrowser.state.value.space?.currentTabId == null
                    else originalNative != null && originalNative.session.settings.contextId == originalProfile?.id &&
                        originalNative.session.settings.usePrivateMode == originalProfile?.isPrivate && originalEngine.ownsExternalActivity(originalNative)
            }
        }
        DisposableEffect(tabletNewTabResting) { onDispose { tabletNewTabResting?.retire() } }
        val galleryFront = addressSource.tab?.takeIf { addressSource.surface == BrowserSurface.GALLERY &&
            it.isBlank && !it.isPrivate && addressSource.space?.isPrivate == false }
        val galleryNative = galleryFront?.let { engine.captureExternalActivityOwner() }
        val galleryFrontSource = remember(browserSession, browser, engine, galleryFront?.id, galleryFront?.url,
            addressSource.surface, addressSource.surfaceEpoch, addressSource.selectedSpaceId, addressSource.space?.websiteProfile,
            addressSource.loading, addressSource.privateContentBlocked, tabletSourceGeneration, tabletForeground,
            addressAccount.account, addressAccount.device, addressAccount.epoch, addressAccount.removed, projectRevision,
            addressView, addressRoot, addressWindow, addressDecor, addressToken, addressIntent, addressEntrance,
            addressConfiguration, addressFrame, addressViewSize, addressDecorSize, workspaceWindowState,
            renderedWindowConfiguration, galleryNative?.tab, galleryNative?.session, galleryNative?.document,
            activityFocused, activityLifecycle, addressCovered) {
            val originalSource = addressSource
            val originalNative = galleryNative
            val originalSession = browserSession
            val originalBrowser = browser
            val originalEngine = engine
            val originalWindow = workspaceWindowState
            val originalLifetime = tabletForeground
            val originalGeneration = tabletSourceGeneration
            val originalProfile = originalSource.space?.websiteProfile
            if (galleryFront == null || originalNative == null || originalNative.tab != galleryFront.id ||
                addressCovered || renderedWindowConfiguration != addressConfiguration || originalProfile == null) null
            else BrowserTabletGallerySource.captureGallery(originalBrowser, originalSource) {
                val transfer = originalSession.downloads.state.value
                val transferCovered = transfer.owner?.let { it.tab == galleryFront.id && it.profile == originalProfile.id } == true &&
                    transfer.phase in setOf(PageDownloadPhase.TRANSFERRING, PageDownloadPhase.READY, PageDownloadPhase.FAILED,
                        PageDownloadPhase.CANCELLING, PageDownloadPhase.EXPORTING)
                val preparing = originalSession.imageDownloads.preparation.value
                browserSession === originalSession && browser === originalBrowser && engine === originalEngine &&
                    window === addressWindow && addressWindow.decorView === addressDecor && addressView.rootView === addressRoot &&
                    addressToken != null && addressView.windowToken === addressToken && addressDecor.windowToken === addressToken &&
                    addressView.isAttachedToWindow && addressView.isShown && addressDecor.isAttachedToWindow && addressDecor.isShown &&
                    addressViewSize.first > 0 && addressViewSize.second > 0 && addressDecorSize.first > 0 && addressDecorSize.second > 0 &&
                    (addressView.width to addressView.height) == addressViewSize && (addressDecor.width to addressDecor.height) == addressDecorSize &&
                    intent === addressIntent && incomingGeneration == addressEntrance && resources.configuration == addressConfiguration &&
                    tabletAddressWindowFrame(addressWindow) == addressFrame && addressFrame.width() > 0 && addressFrame.height() > 0 &&
                    originalWindow.registered && originalWindow.geometry?.valid == true &&
                    originalBrowser.workspaceWindow.value == originalWindow &&
                    originalBrowser.settingsPresentationLifetime.value == originalLifetime && originalLifetime.active &&
                    originalBrowser.historyPresentationLifetime.value == originalGeneration && projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) &&
                    lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && hasWindowFocus() && !isFinishing && !isDestroyed &&
                    !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && !voice && !scanner && !translating &&
                    !fullscreen && !pictureInPicture && !browserOverlay && sharedPage == null && extensionHost.popup.value == null &&
                    originalEngine.prompts?.pending?.value != true && originalEngine.contextMenu.value == null && originalEngine.linkPreview.value == null &&
                    !transferCovered && (preparing == null || !originalSession.imageDownloads.preparationCurrent(preparing)) &&
                    sync.approvals.value.isEmpty() && originalSession.reports.state.value.question == null &&
                    originalNative.session.settings.contextId == originalProfile.id && !originalNative.session.settings.usePrivateMode &&
                    originalEngine.ownsExternalActivity(originalNative)
            }
        }
        DisposableEffect(galleryFrontSource) { onDispose { galleryFrontSource?.retire() } }
        val tabletDrawingContext = remember(browserSession, browser, engine, addressAccount.account, projectRevision,
            addressAccount.device, addressAccount.epoch, addressAccount.removed, tabletForeground.generation,
            tabletForeground.privateBoundary, addressIntent, addressEntrance, addressConfiguration,
            state.selectedSpaceId, state.space?.websiteProfile) { Any() }
        val tabletDrawingSources = remember(browserSession, browser, engine) { BrowserTabletWorkspaceDrawingSource() }
        val tabletFieldOverlay = state.surface == BrowserSurface.FIELD && !state.fieldIsPrivate
        val tabletDrawingSource = tabletDrawingSources.capture(tabletDrawingContext, tabletSourceGeneration, tabletFieldOverlay)
        val tabletDrawingPage = !state.loading && (state.settings.welcomed || firstRunShown) && !state.privateContentBlocked &&
            (state.surface == BrowserSurface.PAGE || tabletFieldOverlay) && state.space?.isPrivate == false && state.tab?.isPrivate != true &&
            !fullscreen && !chats && !projectCovered && !taskScreen && !syncSettings && !extensions && sharedPage == null && extensionPopup == null
        val drawingBrowser = browser
        val drawingSession = browserSession
        val drawingEngine = engine
        val drawingSourceGeneration = tabletSourceGeneration
        val drawingForeground = tabletForeground
        val tabletWorkspaceCandidate = if (!tabletDrawingPage) null else tabletWorkspaceState.capture(
            workspaceWindowState, addressConfiguration.smallestScreenWidthDp,
            WindowInsets.statusBars.getTop(LocalDensity.current) / windowDensity, state.workspace != null,
            tabletDrawingSource) {
                browser === drawingBrowser && browserSession === drawingSession && engine === drawingEngine &&
                    drawingBrowser.historyPresentationLifetime.value == drawingSourceGeneration &&
                    drawingBrowser.settingsPresentationLifetime.value.let { it.active && it.generation == drawingForeground.generation &&
                        it.privateBoundary == drawingForeground.privateBoundary } && projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount)
            }
        val acceptedTabletPresentation = tabletWorkspaceCandidate.takeIf {
            workspaceWindowState.geometry == workspaceWindow && renderedWindowConfiguration == addressConfiguration
        }
        val originalDrawRoot = tabletDrawRoot?.takeIf { it.first == windowConfiguration }?.second?.takeIf { it.valid }
        val tabletWorkspace = remember(acceptedTabletPresentation, originalDrawRoot) {
            if (acceptedTabletPresentation == null || originalDrawRoot == null) null
            else BrowserTabletWorkspaceDrawing(acceptedTabletPresentation, originalDrawRoot)
        }
        // Drawing-only context is captured in a render, never from an old click.
        // Native identity remains the original tuple even while Field hides its view.
        val drawingNative = if (tabletDrawingPage && state.tab != null)
            addressNative ?: engine.captureExternalActivityOwner() else null
        val drawingSpace = state.space
        val drawingTab = state.tab
        val sidebarScrollKey = remember(drawingSession, drawingBrowser, drawingEngine, drawingSpace?.id, projectRevision,
            drawingSpace?.websiteProfile, addressAccount.account, addressAccount.device, addressAccount.epoch,
            addressAccount.removed, drawingForeground.generation, drawingForeground.privateBoundary) { Any() }
        val tabletSidebarDrawing = remember(sidebarScrollKey, tabletDrawingSource, drawingSession, drawingBrowser, drawingEngine, drawingSpace?.id, drawingSpace?.currentTabId,
            drawingSpace?.websiteProfile, addressAccount.account, addressAccount.device, addressAccount.epoch,
            addressAccount.removed, drawingForeground.generation, drawingForeground.privateBoundary,
            addressIntent, addressEntrance, drawingTab?.id, drawingNative?.tab, drawingNative?.session, drawingNative?.document) {
            val originalSpace = drawingSpace
            val originalTab = drawingTab
            val originalNative = drawingNative
            if (originalSpace == null || originalSpace.isPrivate || originalTab?.isPrivate == true ||
                originalTab != null && (originalNative == null || originalNative.tab != originalTab.id) || originalTab == null && originalSpace.currentTabId != null) null
            else BrowserTabletSidebarDrawingContext(sidebarScrollKey) {
                tabletDrawingSources.current(tabletDrawingSource) && browserSession === drawingSession && browser === drawingBrowser && engine === drawingEngine &&
                    intent === addressIntent && incomingGeneration == addressEntrance && projectUnderlayCurrent() && sync.nativeOwnerCurrent(addressAccount) &&
                    drawingBrowser.settingsPresentationLifetime.value.let { it.active && it.generation == drawingForeground.generation &&
                        it.privateBoundary == drawingForeground.privateBoundary } &&
                    drawingBrowser.state.value.let { current -> !current.privateContentBlocked && current.space?.isPrivate == false &&
                        (current.surface != BrowserSurface.FIELD || !current.fieldIsPrivate) && current.selectedSpaceId == originalSpace.id &&
                        current.space?.websiteProfile == originalSpace.websiteProfile && current.space?.currentTabId == originalSpace.currentTabId &&
                        current.tab?.id == originalTab?.id &&
                        current.tab?.isPrivate != true && current.surface in setOf(BrowserSurface.PAGE, BrowserSurface.FIELD) } &&
                    if (originalTab == null) originalNative == null else originalNative != null &&
                        originalNative.session.settings.contextId == originalSpace.websiteProfile.id &&
                        !originalNative.session.settings.usePrivateMode && drawingEngine.ownsExternalActivity(originalNative)
            }
        }
        // Retain both sessions; only the same inset drawing projection controls whether
        // the companion paints. Full-window registration/canSplit are unchanged.
        val nativeWorkspaceLayout = tabletWorkspace?.frame?.pageLayout ?: workspaceLayout
        LaunchedEffect(state.tab?.id, state.workspace, state.surface, state.galleryClosing, state.privateContentBlocked, chats, taskScreen, syncSettings, extensions, extensionPopup, sharedPage, nativeWorkspaceLayout, fullscreen, reportState.question, streamDownloadDialog, pagingVisibility, mayShowHeldMenu, browserOverlay) {
            // Keep the original page active while its owned request awaits headers behind its Cancel dialog.
            // A real stream uses the existing download lifetime once headers have been verified.
            val nativeDraw = state.surface == BrowserSurface.PAGE || state.surface == BrowserSurface.GALLERY && state.galleryClosing
            var recoveryIds = emptySet<String>()
            val visible = if (reportState.question == null && !streamDownloadDialog && !taskScreen && !syncSettings && !extensions && extensionPopup == null && sharedPage == null && !state.privateContentBlocked && nativeDraw) {
                buildSet {
                    if (pageVisible) state.tab?.id?.let(::add)
                    if (nativeWorkspaceLayout.split && !fullscreen) state.workspace?.companion?.let(::add)
                    recoveryIds = toSet()
                    // Native neighbors may paint during a page swipe. Engine authority still
                    // belongs to selected; never activate previews beneath a covered Field.
                    if (pageVisible && state.surface == BrowserSurface.PAGE && mayShowHeldMenu && !browserOverlay) pagingVisibility?.let { (lease, fieldEpoch) ->
                        if (browser.pageSwipeCurrent(lease, fieldEpoch)) {
                            add(lease.front.id); lease.before?.id?.let(::add); lease.after?.id?.let(::add)
                        }
                    }
                }
            } else emptySet()
            engine.setVisibleTabs(visible, recoveryIds = recoveryIds)
            // Retained callbacks keep their old generation; only the next render captures new leases.
            hardwareVisibilityGeneration++
        }
        if (syncSettings) {
            SyncSettingsScreen((application as YabApplication).sync, BiometricApprovalGate(this), onBack = {
                syncSettings = false
            })
        } else if (extensions) {
            ExtensionScreen(extensionsManager, onOpenOptions = { url -> extensionHost.openOptionsUrl(url) }, onBack = { extensions = false }, actions = extensionActions, onAction = extensionHost::click)
        } else if (taskScreen && !state.privateContentBlocked) {
            TaskScreen((application as YabApplication).sync, taskSource, initialTaskId = taskFocus,
                onBack = { taskScreen = false; taskFocus = null },
                onOpenWebsite = { url -> taskScreen = false; taskFocus = null; browser.openExternalUrl(url) })
        } else {
            BrowserScreen(browser, fieldAgentName = agentState.preferences.provider.displayName,
                modifier = Modifier.then(if (firstRunShown || projectCovered) Modifier.clearAndSetSemantics {} else Modifier).onGloballyPositioned {
                    // A layout hint only requests a fresh render, including an initially
                    // empty page. It never replaces a saved action's captured authority.
                    addressPlacement = listOf(addressView.windowToken, addressView.isAttachedToWindow, addressView.isShown,
                        addressView.width, addressView.height, addressDecor.width, addressDecor.height)
                    // One actual root observation feeds both native/drawn projections.
                    // An old configuration callback cannot relabel its dimensions as new.
                    if (resources.configuration == addressConfiguration && browser.workspaceWindow.value.configuration == windowConfiguration) {
                        val origin = it.positionInWindow()
                        tabletDrawRoot = windowConfiguration to TabletOmniboxRoot(origin.x / windowDensity,
                            origin.y / windowDensity, it.size.width / windowDensity, it.size.height / windowDensity)
                    }
                },
                workspaceWindow = workspaceWindow,
                externalInputGeneration = renderedProjectRevision,
                externalInputCurrent = remember(renderedProjectRevision) { { projectPresentation.revision.value == renderedProjectRevision && projectPresentation.frame.value == null } },
                fieldEditorValues = browserSession.fieldEditorValues,
                readerPreferences = browserSession.readerPreferences,
                onHardwareKeysCurrent = { hardwareScreenCurrent = it },
                tabletPageAddress = tabletPageAddress,
                tabletWorkspace = tabletWorkspace,
                tabletSidebar = tabletSidebar,
                tabletSidebarDrawing = tabletSidebarDrawing,
                tabletToolbar = tabletToolbar,
                galleryFrontSource = galleryFrontSource,
                tabletNewTabResting = tabletNewTabResting,
                capturePageMenuLease = captureMenu@ { generation ->
                    val identity = sync.accountRecords.value
                    val source = browser.state.value
                    val tab = source.tab ?: return@captureMenu null
                    val space = source.space ?: return@captureMenu null
                    val native = engine.captureExternalActivityOwner() ?: return@captureMenu null
                    val lease = PageMenuLease(identity.account, identity.epoch, tab.id, space.id, space.websiteProfile,
                        native, source.surfaceEpoch, generation, identity.device, incomingGeneration, tab.url,
                        browser.workspaceWindow.value.generation)
                    lease.takeIf(::currentPageMenu)
                }, pageMenuCurrent = ::currentPageMenu, pageMenuFieldCurrent = ::currentPageMenuField,
                onMenuAsk = if (syncConnection.macs.isEmpty()) null else { lease, tab ->
                    if (currentPageMenu(lease)) askQuestion(null, tab, forceMac = true, expectedMenu = lease)
                }, onMenuOpenOnMac = if (syncConnection.macs.isEmpty()) null else menuMac@ { lease, tab ->
                    val account = lease.account ?: return@menuMac
                    val device = lease.device ?: return@menuMac
                    if (!currentPageMenu(lease) || lease.profile.isPrivate || !lease.ownsSource(browser.state.value, tab.url)) return@menuMac
                    val expected = dev.yab.sync.SyncIdentityLease(account, device, lease.accountEpoch)
                    lifecycleScope.launch {
                        if (!currentPageMenu(lease)) return@launch
                        try {
                            sync.openOnMac(tab.url, tab.title, lease.space, expected = expected)
                            if (currentPageMenu(lease)) browser.message("Sent to your Mac")
                        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                        catch (_: Exception) { if (currentPageMenu(lease)) browser.message("Could not send this page") }
                    }
                },
                reports = browserSession.reports.controller,
                macTodayContent = { space -> if (state.selectedSpaceId == space) dev.yab.sync.MacTodaySection(browserSession.macToday) },
                aiSettingsContent = { current ->
                    val picker = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
                        if (uri != null) lifecycleScope.launch { models.import(uri) }
                    }
                    dev.yab.agent.AiSettings(agent, models, onImport = { picker.launch(arrayOf("application/octet-stream", "*/*")) }, actionCurrent = current)
                },
                fieldChatsContent = { modifier, enabled ->
                    FieldChatsHost(browser, agent, sync.accountRecords, sync.connection, enabled && !projectCovered, modifier,
                        projectPresentation = projectPresentation, projectHostCurrent = projectsHost::current, projectViewCurrent = projectsView::current) { selected ->
                        page = selected.page; conversation = null; review = null
                        browser.dismissSurface(); chats = true
                    }
                },
                onOverlayChange = { pageOverlayMounted = it },
                pagingAllowed = pagingContextAllowed,
                capturePagingFrame = browserSession::capturePageSwipeFrame,
                onPagingVisibility = { lease, fieldEpoch ->
                    pagingVisibility = lease?.takeIf { browser.pageSwipeCurrent(it, fieldEpoch) }?.let { it to fieldEpoch }
                },
                sitePreferences = state.tab?.let { tab ->
                    val host = runCatching { java.net.URI(tab.url).takeIf { it.scheme in setOf("http", "https") }?.host }.getOrNull()
                    dev.yab.browser.engine.SiteSettingsStore.key(host)?.let { key ->
                        (if (tab.isPrivate) siteSettings.privateSites else siteSettings.sites)[key] ?: dev.yab.browser.engine.SitePreferences()
                    }
                },
                siteConnection = state.tab?.id?.let(connections::get),
                onSitePermissionChange = { kind, decision ->
                    state.tab?.takeIf { original -> browser.state.value.tab?.let { it.id == original.id && it.url == original.url } == true }
                        ?.let { engine.setSitePermission(it.id, kind, decision) }
                },
                conversationContent = if (chats && !state.privateContentBlocked) ({
                    if (state.space?.isPrivate != true) NotificationPermissionOnChatEntry()
                    androidx.compose.foundation.layout.Column(Modifier.fillMaxSize().systemBarsPadding()) {
                        AgentScreen(agent, privateContext = state.space?.isPrivate == true, page = page, initialConversationId = conversation,
                            modifier = Modifier.weight(1f), collectInScreen = false,
                            onSelectMac = sync::selectMac,
                            onPark = { if (browserSession.parkedChats.park()) chats = false },
                            projectCurrent = if (state.space?.isPrivate == false) ordinaryProjectChatCurrent::current else null,
                            newChatIdeas = {
                                val visibleIdeas = pageIdeasState.takeIf { it == browserSession.pageIdeas.visible(ideasOwner) } ?: PageIdeasState()
                                PageIdeasRows(visibleIdeas, onPick = { idea ->
                                    val owner = ideasOwner
                                    val chat = agent.state.value.current
                                    if (owner != null && chat != null && chat.id == ideasChat?.id && ideasPageCurrent()) {
                                        browserSession.pageIdeas.pick(owner, idea)?.let { browserSession.sendPageIdea(chat.id, it, ideasPageCurrent) }
                                    }
                                })
                            },
                            onOpenWebsite = { url -> chats = false; browser.openUrl(url) }, localModels = models,
                            approvals = approvals, authentication = BiometricApprovalGate(this@MainActivity),
                            onSend = browserSession::sendMessage, onRetry = browserSession::sendQuestion,
                            onOpenTasks = { chats = false; taskFocus = null; taskScreen = true })
                    }
                }) else null,
                parkedChatContent = if (parkedChat != null && !chats && !projectCovered && !state.privateContentBlocked &&
                    !voice && !scanner && !translating && !fullscreen && !pictureInPicture && !nativePrompt &&
                    reportState.question == null && contextMenu == null && validatedApprovals.isEmpty() && !downloadDialog) ({
                    parkedChat?.let { expected ->
                        browserSession.parkedChats.visible(expected, state.space?.isPrivate == true)?.let { held ->
                            browserSession.parkedChats.presentation(expected)?.let { travel ->
                                ParkedChatLine(held, travel, ownerCurrent = {
                                    val live = sync.accountRecords.value
                                    expected.account == live.account && expected.epoch == live.epoch &&
                                        !browser.state.value.privateContentBlocked &&
                                        browserSession.parkedChats.visible(expected, browser.state.value.space?.isPrivate == true) != null
                                }, onRestore = {
                                    if (browserSession.parkedChats.restore(expected, browser.state.value.space?.isPrivate == true)) {
                                        page = agent.state.value.current?.page; conversation = null; review = null; chats = true
                                    }
                                }, onLetGo = { browserSession.parkedChats.letGo(expected, browser.state.value.space?.isPrivate == true) })
                            }
                        }
                    }
                }) else null,
                fullscreen = fullscreen || pictureInPicture,
                blocksAdsEnabled = shieldPolicy.global,
                onBlocksAdsChange = browserSession::setGlobalBlocking,
                blockingStatus = if (shieldStatus.error != null) "The blocking settings could not be applied. Try again." else if (!shieldStatus.ready) "Starting protection…" else null,
                siteBlocking = dev.yab.shield.shieldUrlHost(state.tab?.url)?.let { shieldPolicy.enabled(it, state.space?.isPrivate == true) },
                onSiteBlockingChange = if (shieldPolicy.global) ({ enabled -> state.tab?.let { browserSession.setSiteBlocking(it, enabled) } }) else null,
                onAskQuestion = { words, tab -> askQuestion(words, tab, forceMac = false) },
                onNewChat = { agent.setPrivacy(false); page = null; conversation = null; browser.dismissSurface(); agent.newChat(); chats = true },
                onNewChatAboutPage = if (syncConnection.macs.isEmpty()) null else { tab -> askQuestion(null, tab, forceMac = true) },
                onOpenChats = { agent.setPrivacy(state.space?.isPrivate == true); page = null; conversation = null; browser.dismissSurface(); chats = true },
                onOpenOnMac = if (syncConnection.macs.isEmpty()) null else { tab -> lifecycleScope.launch {
                    if (!tab.isPrivate) runCatching { (application as YabApplication).sync.openOnMac(tab.url, tab.title, state.space?.id) }
                        .onSuccess { browser.message("Sent to your Mac") }.onFailure { browser.message(it.message ?: "Could not send this page") }
                } },
                onSyncSettings = { syncSettings = true },
                onExtensions = if (extensionsAllowed()) ({
                    if (extensionsAllowed()) { browser.dismissSurface(); extensions = true }
                }) else null,
                onVoiceSearch = { voice = true },
                onScanQr = { scanner = true },
                translationMenu = translationMenuUi,
                onOpenCredentialsSettings = { startActivity(Intent(Settings.ACTION_SETTINGS)) },
                onOpenSystemSettings = {
                    val roles = getSystemService(RoleManager::class.java)
                    if (roles.isRoleAvailable(RoleManager.ROLE_BROWSER) && !roles.isRoleHeld(RoleManager.ROLE_BROWSER)) {
                        startActivity(roles.createRequestRoleIntent(RoleManager.ROLE_BROWSER))
                    } else startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName")))
                },
                onUnlockPrivate = ::authenticatePrivate,
                thumbnail = { tab, modifier ->
                    val profile = state.space?.websiteProfile
                    val picture = thumbnails[tab.id]?.takeIf { !tab.isPrivate && it.url == tab.url && it.profileId == profile?.id }
                    LaunchedEffect(tab.id, tab.url, profile, picture == null) {
                        if (picture == null && profile != null) engine.requestThumbnail(tab, profile)
                    }
                    if (picture != null) Image(picture.bitmap.asImageBitmap(), contentDescription = "${tab.title} page preview", modifier = modifier, contentScale = ContentScale.Crop)
                    else androidx.compose.foundation.layout.Box(modifier)
                },
                pageContent = { tab, profile, modifier ->
                    val fieldCovered = state.surface in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES) &&
                        !(workspaceLayout.expanded && workspaceLayout.paneWidth >= 640)
                    val nativeAccessible = !firstRunShown && tab.id == state.tab?.id && pageVisible && !fieldCovered &&
                        state.surface !in setOf(BrowserSurface.SETTINGS, BrowserSurface.HISTORY, BrowserSurface.GALLERY)
                    AndroidView(modifier = modifier.fillMaxSize(), factory = { context ->
                        dev.yab.browser.engine.HistorySwipeView(context).apply {
                            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                            importantForAccessibility = if (nativeAccessible) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                            setSession(engine.session(tab, profile))
                            tag = tab.id
                            engine.bindView(tab.id, this)
                            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                                pipOwner?.let { owner -> engine.media.value.firstOrNull { it.owner == owner }?.let(::configurePictureInPicture) }
                            }
                        }
                    }, update = { view ->
                        val session = engine.session(tab, profile)
                        view.importantForAccessibility = if (nativeAccessible) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        val old = view.tag as? String
                        if (old != tab.id || view.session !== session) {
                            old?.let { engine.unbindView(it, view) }
                            view.releaseSession(); view.setSession(session); view.tag = tab.id
                        }
                        engine.bindView(tab.id, view)
                        engine.darken(tab.id, darkWebsites)
                    }, onReset = null, onRelease = { view -> (view.tag as? String)?.let { engine.unbindView(it, view) }; view.releaseSession() })
                })
        }
        if (projectCovered && !taskScreen && !syncSettings && !extensions) ChatProjectsCover(agent, projectPresentation,
            modifier = Modifier.fillMaxSize().systemBarsPadding(), actionCurrent = projectsHost::current, onOpenWebsite = { browser.openUrl(it) },
            approvals = approvals, authentication = BiometricApprovalGate(this@MainActivity), localModels = models)
        if (firstRunShown && !syncSettings && !state.privateContentBlocked) {
            val originalFlow = firstRunOwner
            val originalForeground = tabletForeground
            val originalWindowState = workspaceWindowState
            val firstRunHost = remember(originalFlow, browserSession, browser, addressView, addressRoot,
                addressWindow, addressDecor, addressToken, addressIntent, addressEntrance, addressConfiguration,
                originalWindowState.generation, originalWindowState.registered, originalWindowState.geometry,
                originalForeground, activityFocused, activityLifecycle, pageOverlayMounted, chats, taskScreen,
                syncSettings, extensions, voice, scanner, translating, fullscreen, pictureInPicture,
                sharedPage, extensionPopup, nativePrompt, contextMenu, linkPreview, downloadDialog,
                validatedApprovals, reportState.question) {
                val originalSession = browserSession
                val originalBrowser = browser
                val originalView = addressView
                val originalRoot = addressRoot
                val originalWindow = addressWindow
                val originalDecor = addressDecor
                val originalToken = addressToken
                val originalIntent = addressIntent
                val originalEntrance = addressEntrance
                val originalConfiguration = Configuration(addressConfiguration)
                val capturedForeground = originalForeground
                val capturedWindow = originalWindowState
                FirstRunPresentation.RenderedHost {
                    browserSession === originalSession && browser === originalBrowser &&
                        (if (originalFlow == null) originalSession.firstRunAbsent() else originalSession.firstRunCurrent(originalFlow)) && !isFinishing && !isDestroyed &&
                        intent === originalIntent && incomingGeneration == originalEntrance &&
                        resources.configuration == originalConfiguration && window === originalWindow &&
                        originalWindow.decorView === originalDecor && originalView.rootView === originalRoot &&
                        originalToken != null && originalView.windowToken === originalToken && originalDecor.windowToken === originalToken &&
                        originalView.isAttachedToWindow && originalView.isShown && originalView.width > 0 && originalView.height > 0 &&
                        originalDecor.isAttachedToWindow && originalDecor.isShown && originalDecor.hasWindowFocus() &&
                        lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                        capturedForeground.active && originalBrowser.settingsPresentationLifetime.value == capturedForeground &&
                        capturedWindow.registered && capturedWindow.geometry?.valid == true &&
                        originalBrowser.workspaceWindow.value == capturedWindow &&
                        !originalBrowser.state.value.privateContentBlocked &&
                        !pageOverlayMounted && !chats && !projectCovered && !taskScreen && !syncSettings && !extensions &&
                        !voice && !scanner && !translating && !fullscreen && !pictureInPicture && sharedPage == null &&
                        extensionHost.popup.value == null && engine.contextMenu.value == null && engine.linkPreview.value == null &&
                        engine.prompts?.pending?.value != true && sync.approvals.value.isEmpty() &&
                        browserSession.reports.state.value.question == null && !downloadDialog
                }
            }
            DisposableEffect(firstRunHost) { onDispose { firstRunHost.retire() } }
            val firstRunTablet = originalWindowState.registered && originalWindowState.geometry == workspaceWindow &&
                TabletJoinSuccessGeometry.eligible(workspaceWindow, addressConfiguration.smallestScreenWidthDp)
            if (originalFlow == null) {
                FirstRunPreparationScreen(browserSession.firstRunPreparation, firstRunHost, firstRunTablet,
                    retry = browserSession::prepareFirstRunOwner)
            } else {
                val firstRunMac = syncConnection.macs.firstOrNull()?.name.takeIf {
                    val identity = menuAccount.account
                    identity != null && syncConnection.account == identity && syncConnection.epoch == menuAccount.epoch &&
                        !menuAccount.removed && tabletJoinSource(sync).identity?.let { lease ->
                            lease.account == identity && lease.device == menuAccount.device && lease.epoch == menuAccount.epoch
                        } == true
                } ?: "your Mac"
                FirstRunScreen(originalFlow, firstRunHost, sync, firstRunTablet, workspaceWindow, state.spaces,
                    firstRunRole(), firstRunMac,
                    requestDefault = {
                        if (firstRunHost.current()) {
                            val roles = getSystemService(RoleManager::class.java)
                            if (roles?.isRoleAvailable(RoleManager.ROLE_BROWSER) == true && !roles.isRoleHeld(RoleManager.ROLE_BROWSER)) {
                                try { startActivity(roles.createRequestRoleIntent(RoleManager.ROLE_BROWSER)) }
                                catch (_: android.content.ActivityNotFoundException) { browser.message("Default browser settings are unavailable.") }
                                catch (_: SecurityException) { browser.message("Default browser settings are unavailable.") }
                            }
                        }
                    }, finish = { completion -> browserSession.finishFirstRun(originalFlow, completion) },
                    copy = { text -> if (firstRunHost.current()) getSystemService(android.content.ClipboardManager::class.java)
                        ?.setPrimaryClip(android.content.ClipData.newPlainText("Yab", text)) },
                    haptic = { event -> if (firstRunHost.current()) originalViewHaptic(addressView, event) })
            }
        }
        if (!chats && !state.privateContentBlocked && state.space?.isPrivate != true) ApprovalPrompt(approvals, BiometricApprovalGate(this), observeInScreen = false)
        if (voice && !state.privateContentBlocked) {
            val privateVoice = state.space?.isPrivate == true || state.fieldPrivate
            VoiceSearchDialog(privateContext = privateVoice, ownerKey = state.tab?.id.orEmpty(), onResult = { words ->
                voice = false; browser.openField(privately = privateVoice); browser.fieldText(words); browser.submitField()
            }, onDismiss = { voice = false })
        }
        if (scanner && !state.privateContentBlocked) QrScannerDialog(ownerKey = state.tab?.id.orEmpty(), onResult = { payload ->
            scanner = false
            val uri = android.net.Uri.parse(payload)
            if (uri.scheme == "yab" && uri.host == "join") {
                (application as YabApplication).sync.join(uri.lastPathSegment); syncSettings = true
            } else if (uri.scheme in setOf("http", "https")) browser.openUrl(payload)
            else { browser.openField(); browser.fieldText(payload) }
        }, onDismiss = { scanner = false })
        if (translating && !state.privateContentBlocked) TranslationDialog(translator, scope = lifecycleScope, onDismiss = { translating = false })
        contextMenu?.takeUnless { state.privateContentBlocked }?.let { request ->
            fun take(action: (dev.yab.browser.engine.PageContextMenu) -> Unit) {
                val current = browser.state.value
                if (current.tab?.id != request.tab || current.space?.websiteProfile?.id != request.profile || current.privateContentBlocked) {
                    engine.dismissContextMenu(); return
                }
                engine.takeContextMenu(request.id)?.let(action)
            }
            fun copyAddress(address: String) {
                getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("Link", address))
                browser.message("Link copied")
            }
            fun shareAddress(address: String) {
                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, address), "Share link"))
            }
            ModalBottomSheet(onDismissRequest = { engine.dismissContextMenu() }) {
                androidx.compose.foundation.layout.Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 20.dp, vertical = 12.dp)) {
                    linkPreview?.takeIf { it.id == request.id }?.let { preview ->
                        dev.yab.browser.ui.LinkPreviewCard(preview,
                            commit = { engine.commitLinkPreview(preview.id) },
                            released = { engine.closeLinkPreview(preview.id) })
                    }
                    Text(request.title.take(300), style = MaterialTheme.typography.titleMedium)
                    request.link?.let {
                        TextButton(onClick = { take { owner -> owner.link?.let { browser.openUrl(it, openerId = owner.tab, privately = owner.isPrivate) } } }) { Text("Open in New Tab") }
                        TextButton(onClick = { take { owner -> owner.link?.let { browser.openUrl(it, openerId = owner.tab, privately = owner.isPrivate, background = true) } } }) { Text("Open in Background Tab") }
                        TextButton(onClick = { take { owner -> owner.link?.let(::copyAddress) } }) { Text("Copy Link") }
                        TextButton(onClick = { take { owner -> owner.link?.let(::shareAddress) } }) { Text("Share Link") }
                    }
                    request.image?.let {
                        TextButton(onClick = { browserSession.saveHeldImage(request.id) }) { Text("Save Image") }
                        TextButton(onClick = { take { owner -> owner.image?.let { browser.openUrl(it, openerId = owner.tab, privately = owner.isPrivate) } } }) { Text("Open Image") }
                        TextButton(onClick = { take { owner -> owner.image?.let(::copyAddress) } }) { Text("Copy Image Address") }
                        TextButton(onClick = { take { owner -> owner.image?.let(::shareAddress) } }) { Text("Share Image Address") }
                    }
                }
            }
        }
        sharedPage?.let { url ->
            AlertDialog(onDismissRequest = { sharedPage = null }, title = { Text("Open in Yab") },
                text = { Text(url) },
                confirmButton = {
                    androidx.compose.foundation.layout.Column {
                        TextButton(onClick = { sharedPage = null; browser.openExternalUrl(url) }) { Text("Open") }
                        TextButton(onClick = {
                            if (browser.keepExternalUrl(url)) { sharedPage = null; browser.message("Kept for Later") }
                        }) { Text("Keep for Later") }
                    }
                }, dismissButton = { TextButton(onClick = { sharedPage = null }) { Text("Cancel") } })
        }
        extensionPopup?.let { session ->
            ModalBottomSheet(onDismissRequest = extensionHost::closePopup) {
                Text(popupTitle, style = MaterialTheme.typography.titleMedium)
                AndroidView(modifier = Modifier.fillMaxSize(), factory = { GeckoView(it).apply { setSession(session) } },
                    onReset = null, onRelease = { it.releaseSession() }, update = { if (it.session !== session) { it.releaseSession(); it.setSession(session) } })
            }
        }
    }

    /** Activity dispatch runs before either the native page or the Field takes the chord. */
    // Public framework Window.Callback override. AndroidX exposes it through its restricted
    // compat bridge; keep the normal framework dispatch for keys this app does not handle.
    @android.annotation.SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_UP && (hardwareKeysDown.remove(event.keyCode) || interruptedHardwareKeys.remove(event.keyCode))) return true
        if (event.action == KeyEvent.ACTION_DOWN) interruptedHardwareKeys.remove(event.keyCode)
        if (event.action == KeyEvent.ACTION_DOWN && event.keyCode in hardwareKeysDown) return true
        val input = when (event.keyCode) {
            KeyEvent.KEYCODE_T -> "t"
            KeyEvent.KEYCODE_L -> "l"
            KeyEvent.KEYCODE_W -> "w"
            KeyEvent.KEYCODE_R -> "r"
            KeyEvent.KEYCODE_LEFT_BRACKET -> "["
            KeyEvent.KEYCODE_RIGHT_BRACKET -> "]"
            KeyEvent.KEYCODE_F -> "f"
            KeyEvent.KEYCODE_TAB -> "\t"
            in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 -> (event.keyCode - KeyEvent.KEYCODE_1 + 1).toString()
            else -> null
        }
        val key = input?.let { BrowserHardwareKey.fromChord(it, event.isCtrlPressed, event.isMetaPressed,
            event.isShiftPressed, event.isAltPressed || event.isSymPressed || event.isFunctionPressed) }
            ?: return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN) {
            hardwareKeysDown += event.keyCode
            if (event.repeatCount == 0 && !event.isCanceled) hardwareKeyAction?.invoke(key)
        }
        // A recognized but currently refused command cannot fall through to page
        // scripts, text input or the system window action. Its UP is consumed too.
        return true
    }

    private fun retireHardwareKeys(interrupted: Boolean = false) {
        hardwareKeyOwner?.retire()
        hardwareKeyOwner = null
        hardwareKeyAction = null
        if (interrupted) {
            hardwareHostGeneration++
            interruptedHardwareKeys += hardwareKeysDown; hardwareKeysDown.clear()
        }
    }

    /** Keep the original saveable backing while revoking key callbacks before a local cover writes. */
    private fun <T> hardwareKeyTrackedState(source: MutableState<T>): MutableState<T> = object : MutableState<T> {
        override var value: T
            get() = source.value
            set(next) { if (source.value != next) { hardwareHostGeneration++; retireHardwareKeys(); source.value = next } }
        override fun component1(): T = value
        override fun component2(): (T) -> Unit = { value = it }
    }

    override fun onNewIntent(intent: Intent) {
        retireHardwareKeys(interrupted = true)
        super.onNewIntent(intent)
        if (::browserSession.isInitialized) browserSession.launchKeyboard.cancel(browserUiOwner)
        cancelPrivateAuthentication()
        incomingGeneration++; nowEntrance?.cancel(); nowEntrance = null; pageQuestion?.cancel(); pageQuestion = null
        setIntent(intent)
        pendingAction = incomingAction(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus) retireHardwareKeys(interrupted = true)
        super.onWindowFocusChanged(hasFocus)
        activityFocused = hasFocus
    }

    private fun configurePictureInPicture(media: PageMediaState?) {
        val supported = packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        val current = browser.state.value
        val eligible = media?.takeIf { supported && it.active && it.playing && it.fullscreen && it.hasVideo &&
            it.videoWidth > 0 && it.videoHeight > 0 && it.owner.tabId == current.tab?.id &&
            current.surface == BrowserSurface.PAGE && fullscreen &&
            it.mayExport(current.settings.lockPrivate) && !current.privateContentBlocked }
        pipOwner = eligible?.owner
        if (!supported) return
        val builder = PictureInPictureParams.Builder()
        if (eligible != null) {
            val width = eligible.videoWidth.coerceIn(1, 8192).toInt()
            val height = eligible.videoHeight.coerceIn(1, 8192).toInt()
            val ratio = width.toDouble() / height
            builder.setAspectRatio(if (ratio in (1.0 / 2.39)..2.39) Rational(width, height) else Rational(16, 9))
            engine.mediaBounds(eligible.owner)?.let(builder::setSourceRectHint)
        }
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(eligible != null)
        pipParameters = builder.build()
        runCatching { setPictureInPictureParams(requireNotNull(pipParameters)) }.onFailure {
            pipOwner = null; pipParameters = null
            browser.message("Picture in Picture is unavailable for this window")
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < 31 && pipOwner != null) pipParameters?.let { params ->
            runCatching { enterPictureInPictureMode(params) }.onFailure {
                pipOwner = null; browser.message("Picture in Picture is unavailable for this window")
            }
        }
    }

    override fun onPictureInPictureModeChanged(inPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(inPictureInPictureMode, newConfig)
        pictureInPicture = inPictureInPictureMode
    }

    private fun incomingAction(intent: Intent?): IncomingAction? {
        if (intent?.action == Intent.ACTION_SEND) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return null
            return IncomingAction.shared(text)
        }
        val url = intent?.data ?: return null
        return IncomingAction.parse(url.toString())
    }
    private fun publicSpace() {
        val state = browser.state.value
        if (state.space?.isPrivate == true) state.spaces.firstOrNull { !it.isPrivate }?.let { browser.selectSpace(it.id) }
    }
    private fun incomingSource(): List<Any?> = browser.state.value.let {
        listOf(it.selectedSpaceId, it.tab?.id, it.tab?.url, it.surface, it.fieldIsNewTab, it.fieldPrivate, it.privateLocked)
    }
    private fun tabletAddressWindowFrame(original: android.view.Window): Rect =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Rect(windowManager.currentWindowMetrics.bounds)
        else Rect().also { original.decorView.getWindowVisibleDisplayFrame(it) }
    private fun captureTabletAddressSource(rendered: BrowserState, smallestWidth: Int, available: Boolean):
        Pair<TabletPageEntryLease?, dev.yab.sync.AccountRecordsSnapshot> {
        val account = (application as YabApplication).sync.accountRecords.value
        val original = if (available && browser.state.value === rendered) browser.captureTabletPageEntry(smallestWidth) else null
        return original to account
    }
    private fun captureTabletSidebarSource(rendered: BrowserState, smallestWidth: Int, available: Boolean,
        revision: Long): TabletSidebarPageLease? = if (available && browser.state.value === rendered &&
            browser.tabletSidebarRevision.value == revision) browser.captureTabletSidebarPage(smallestWidth) else null
    private fun extensionsAllowed(): Boolean {
        return ::browserSession.isInitialized && browserSession.extensionsAllowed()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        retireHardwareKeys(interrupted = true)
        if (::browserSession.isInitialized) browserSession.launchKeyboard.cancel(browserUiOwner)
        if (::browser.isInitialized) browser.invalidateWorkspaceWindow()
        super.onConfigurationChanged(newConfig)
    }

    override fun onStart() {
        super.onStart()
        if (::browserSession.isInitialized) {
            browserSession.startUi(browserUiOwner)
            browserSession.startLaunchKeyboard(browserUiOwner, incomingAction(intent) != null,
                LaunchKeyboardPolicy.fixtureAllowed(LaunchKeyboardTestEnvironment.registered(), intent.getBooleanExtra(LaunchKeyboardTestEnvironment.EXTRA, false)))
        }
    }
    private fun cancelPrivateAuthentication() {
        privateAuthentication.invalidate()
        privateAuthenticationJob?.cancel(); privateAuthenticationJob = null
    }
    private fun authenticatePrivate(callback: (Boolean) -> Unit) {
        cancelPrivateAuthentication()
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) { callback(false); return }
        val sync = (application as YabApplication).sync
        fun owner() = sync.accountRecords.value.let {
            PrivateAuthenticationAttempts.Owner(it.account, it.device, it.epoch, it.removed)
        }
        val attempt = privateAuthentication.begin(owner()) ?: run { callback(false); return }
        privateAuthenticationJob = lifecycleScope.launch {
            val proof = try { BiometricApprovalGate(this@MainActivity).authenticate("Unlock your private tabs") }
            catch (cancelled: kotlinx.coroutines.CancellationException) { callback(false); throw cancelled }
            val current = privateAuthentication.consume(attempt, owner()) && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            // A stale/cancelled prompt may only release the captured UI's waiting pose.
            // The Controller's original source lease also guards this false callback.
            callback(current && proof != null)
        }
    }
    override fun onPause() { retireHardwareKeys(interrupted = true); if (::engine.isInitialized) engine.dismissContextMenu(); super.onPause() }
    override fun onStop() {
        retireHardwareKeys(interrupted = true)
        cancelPrivateAuthentication()
        if (::browserSession.isInitialized) browserSession.stopLaunchKeyboard(browserUiOwner, isChangingConfigurations)
        if (::browserSession.isInitialized) browserSession.stopUi(browserUiOwner)
        super.onStop()
    }
    override fun onDestroy() {
        retireHardwareKeys(interrupted = true)
        cancelPrivateAuthentication()
        incomingGeneration++; nowEntrance?.cancel(); nowEntrance = null
        filesAnswer?.invoke(emptyList()); filesAnswer = null; filesOwnerTab = null
        permissionsAnswer?.invoke(false); permissionsAnswer = null; requestedPermissions = emptySet()
        if (::webAuthn.isInitialized) webAuthn.close()
        if (::browserSession.isInitialized) browserSession.detachUi(browserUiOwner)
        super.onDestroy()
    }
    override fun onTrimMemory(level: Int) {
        if (::engine.isInitialized) engine.onTrimMemory(level)
        super.onTrimMemory(level)
    }
}

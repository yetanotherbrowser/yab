package dev.yab.browser.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import dev.yab.browser.model.*
import dev.yab.browser.engine.SitePreferences
import dev.yab.browser.engine.SiteConnection
import dev.yab.browser.engine.SitePermission
import dev.yab.browser.engine.SiteDecision
import dev.yab.browser.engine.SiteSettingsStore

/** Fresh rendered arguments, rather than a remembered lambda over a selected tab or callback.
 * The movable content has exactly one FIELD invocation in the chosen placement. */
private data class BrowserFieldEditorFrame(val state: BrowserState, val wide: Boolean,
    val presentation: BrowserFieldPresentation, val placement: BrowserFieldPlacementLease,
    val tablet: TabletOmniboxViewport?,
    val ask: ((String, BrowserTab?) -> Unit)?, val askPage: ((BrowserTab) -> Unit)?, val chats: (() -> Unit)?,
    val onMac: ((BrowserTab) -> Unit)?, val macToday: (@Composable (String) -> Unit)?,
    val unlock: ((Boolean) -> Unit) -> Unit, val chatContent: (@Composable (Modifier, Boolean) -> Unit)?,
    val editorValue: BrowserFieldEditorValue?, val agentName: String, val onNewChat: (() -> Unit)?)

/** One in-root toolbar menu, retaining its original PAGE, node and layout.
 * It is neither a replacement native owner nor an alternative to a model lease. */
private class BrowserTabletLocalMenu(val anchor: FieldAnchor, val frame: BrowserTabletFrameControl? = null,
    val workspace: WorkspaceActionLease? = null, private val originalCurrent: () -> Boolean) {
    private var retired = false
    fun current(): Boolean {
        if (retired) return false
        if (!originalCurrent()) { retired = true; return false }
        return true
    }
}

/** The engine surface is supplied by the host and keeps its identity outside recomposition. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BrowserScreen(
    controller: BrowserController,
    modifier: Modifier = Modifier,
    fullscreen: Boolean = false,
    onAskQuestion: ((String, BrowserTab?) -> Unit)? = null,
    fieldAgentName: String = "Claude",
    onNewChat: (() -> Unit)? = null,
    onNewChatAboutPage: ((BrowserTab) -> Unit)? = null,
    onOpenOnMac: ((BrowserTab) -> Unit)? = null,
    onOpenChats: (() -> Unit)? = null,
    onSyncSettings: (() -> Unit)? = null,
    onExtensions: (() -> Unit)? = null,
    onVoiceSearch: (() -> Unit)? = null,
    onScanQr: (() -> Unit)? = null,
    onTranslate: (() -> Unit)? = null,
    translationMenu: BrowserPageTranslationUi? = null,
    onOpenSystemSettings: (() -> Unit)? = null,
    onOpenCredentialsSettings: (() -> Unit)? = null,
    blocksAdsEnabled: Boolean? = null,
    onBlocksAdsChange: ((Boolean) -> Unit)? = null,
    siteBlocking: Boolean? = null,
    onSiteBlockingChange: ((Boolean) -> Unit)? = null,
    blockingStatus: String? = null,
    conversationContent: (@Composable () -> Unit)? = null,
    parkedChatContent: (@Composable () -> Unit)? = null,
    reports: dev.yab.reports.ReportsController? = null,
    onOverlayChange: ((Boolean) -> Unit)? = null,
    onHardwareKeysCurrent: ((() -> Boolean) -> Unit)? = null,
    pagingAllowed: Boolean = true,
    onPagingVisibility: ((PageSwipeLease?, Long?) -> Unit)? = null,
    capturePagingFrame: (suspend (PageSwipeLease) -> dev.yab.browser.engine.PagingCaptureResult)? = null,
    sitePreferences: SitePreferences? = null,
    siteConnection: SiteConnection? = null,
    onSitePermissionChange: ((SitePermission, SiteDecision?) -> Unit)? = null,
    macTodayContent: (@Composable (String) -> Unit)? = null,
    aiSettingsContent: (@Composable (actionCurrent: () -> Boolean) -> Unit)? = null,
    fieldChatsContent: (@Composable (Modifier, Boolean) -> Unit)? = null,
    capturePageMenuLease: ((Long) -> PageMenuLease?)? = null,
    pageMenuCurrent: ((PageMenuLease) -> Boolean)? = null,
    pageMenuFieldCurrent: ((PageMenuLease, FieldInputLease) -> Boolean)? = null,
    onMenuOpenOnMac: ((PageMenuLease, BrowserTab) -> Unit)? = null,
    onMenuAsk: ((PageMenuLease, BrowserTab) -> Unit)? = null,
    onUnlockPrivate: ((callback: (Boolean) -> Unit) -> Unit) = { it(false) },
    thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)? = null,
    workspaceWindow: BrowserWorkspaceWindow? = null,
    tabletPageAddress: BrowserTabletPageAddressEntry? = null,
    tabletWorkspace: BrowserTabletWorkspaceDrawing? = null,
    tabletSidebar: BrowserTabletSidebarEntry? = null,
    tabletSidebarDrawing: BrowserTabletSidebarDrawingContext? = null,
    fieldEditorValues: BrowserFieldEditorValues? = null,
    tabletToolbar: BrowserTabletToolbarEntry? = null,
    galleryFrontSource: BrowserTabletGallerySource? = null,
    tabletNewTabResting: BrowserTabletNewTabRestingEntry? = null,
    readerPreferences: dev.yab.browser.engine.ReaderPreferencesStore? = null,
    externalInputGeneration: Long = 0,
    externalInputCurrent: (() -> Boolean)? = null,
    pageContent: @Composable (BrowserTab, WebsiteProfile, Modifier) -> Unit,
) {
    val state by controller.state.collectAsState()
    val readerStyle = readerPreferences?.state?.collectAsState()?.value
    val workspaceProjection by controller.workspaceWindow.collectAsState()
    val fieldLifetime by controller.settingsPresentationLifetime.collectAsState()
    val fieldSourceGeneration by controller.historyPresentationLifetime.collectAsState()
    val externalInput = remember(controller, externalInputGeneration, externalInputCurrent) {
        BrowserScreenExternalInput(externalInputCurrent)
    }
    DisposableEffect(externalInput) { onDispose { externalInput.retire() } }
    val externalInputAvailable = externalInput.current()
    val workspaceEntry = rememberWorkspaceEntry(controller)
    val fieldInputFocus = remember(controller) { BrowserFieldInputFocus() }
    val localEditorValues = remember(controller) { BrowserFieldEditorValues() }
    DisposableEffect(localEditorValues) { onDispose { localEditorValues.close() } }
    val editorValues = fieldEditorValues ?: localEditorValues
    val fieldEditorOwner = BrowserFieldEditorOwner.from(state, fieldLifetime.privateBoundary)
    val fieldEditorValue = remember(controller, fieldEditorOwner, editorValues) {
        editorValues.retain(controller, fieldEditorOwner) {
            TextFieldValue(state.fieldText,
                if (state.fieldIsNewTab) TextRange(state.fieldText.length) else TextRange(0, state.fieldText.length))
        }
    }
    BrowserTheme(state.settings.appearance) {
        val hardwareCoverage = remember(controller) { BrowserHardwareKeyCoverage() }
        DisposableEffect(hardwareCoverage) { onDispose { hardwareCoverage.retire() } }
        val fieldEditor = remember(controller) { movableContentOf<BrowserFieldEditorFrame> { rendered ->
            BrowserField(rendered.state, controller, rendered.wide, rendered.ask, rendered.askPage, rendered.chats,
                rendered.onMac, rendered.macToday, fieldPresentation = rendered.presentation,
                onUnlockPrivate = rendered.unlock, fieldChatsContent = rendered.chatContent,
                tabletViewport = rendered.tablet, placement = rendered.placement, editorValue = rendered.editorValue, agentName = rendered.agentName,
                onNewChat = rendered.onNewChat, sheetAllowed = !rendered.wide)
        } }
        val privateAuthScope = rememberCoroutineScope()
        val privateAuthLifecycle = LocalLifecycleOwner.current.lifecycle
        var menu by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        var layoutLease by remember(controller) { mutableStateOf<WorkspaceActionLease?>(null) }
        var menuSession by remember(hardwareCoverage) { hardwareCoverage.state<BrowserPageMenuSession?>(null) }
        var readerPresentation by remember(hardwareCoverage) { hardwareCoverage.state<BrowserReaderPresentation?>(null) }
        val readerFrame = readerPresentation?.state?.collectAsState()?.value
        var readerDrawing by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        val readerCovered = readerFrame?.shown == true || readerDrawing
        DisposableEffect(controller) { onDispose { readerPresentation?.drop() } }
        var tabletSiteSession by remember(hardwareCoverage) { hardwareCoverage.state<BrowserPageMenuSession?>(null) }
        var tabletLocalMenu by remember(hardwareCoverage) { hardwareCoverage.state<BrowserTabletLocalMenu?>(null) }
        var toolbarCoverageGeneration by remember(controller) { mutableLongStateOf(0) }
        var tabletGallerySource by remember(controller) { mutableStateOf<BrowserTabletGallerySource?>(null) }
        val shownGallerySource = galleryFrontSource ?: tabletGallerySource
        DisposableEffect(shownGallerySource) { onDispose { shownGallerySource?.retire() } }
        if (galleryFrontSource != null && tabletGallerySource != null && tabletGallerySource !== galleryFrontSource) {
            val previous = tabletGallerySource
            SideEffect { previous?.retire(); if (tabletGallerySource === previous) tabletGallerySource = null }
        }
        var menuGeneration by remember(controller) { mutableLongStateOf(0) }
        var menuRoot by remember(controller) { mutableStateOf<SpacesRect?>(null) }
        var pageAddressRoot by remember(controller) { mutableStateOf<LayoutCoordinates?>(null) }
        var fieldRoot by remember(controller) { mutableStateOf<TabletOmniboxRoot?>(null) }
        val menuContext = LocalContext.current
        val menuText = rememberTextMeasurer()
        val menuDensity = LocalDensity.current
        val pageCornerView = LocalView.current
        var pageCornerSnapshot by remember(pageCornerView) { mutableStateOf<TabletWindowCornerSnapshot?>(null) }
        val externalMenuCurrent by rememberUpdatedState(pageMenuCurrent)
        val externalMenuFieldCurrent by rememberUpdatedState(pageMenuFieldCurrent)
        val menuReduced = LocalBrowserAccessibility.current.reduceMotion
        val menuAnimations = LocalPageMenuAnimationsEnabled.current ?: android.animation.ValueAnimator.areAnimatorsEnabled()
        var stackButton by remember(state.selectedSpaceId) { mutableStateOf<GalleryRect?>(null) }
        val finding = state.find != null
        var clearData by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        var chromeOverlay by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        var layouts by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        var fieldMounted by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        var settingsMounted by remember(hardwareCoverage) { hardwareCoverage.state(false) }
        val hardwareSurface by rememberUpdatedState(state.surface)
        val hardwareCoverageGeneration = hardwareCoverage.generation
        val hardwareLocalBlocked = menu || menuSession != null || readerCovered || clearData || chromeOverlay ||
            layouts || tabletLocalMenu != null || settingsMounted || fieldMounted && state.surface != BrowserSurface.FIELD
        val hardwareMounted = remember(hardwareCoverage, hardwareCoverageGeneration, externalInput) { booleanArrayOf(true) }
        val hardwareKeysCurrent = remember(hardwareCoverage, hardwareCoverageGeneration, externalInput) { {
            externalInput.current() && hardwareMounted[0] && hardwareCoverage.current(hardwareCoverageGeneration) && !hardwareLocalBlocked && !menu && menuSession == null &&
                readerPresentation?.state?.value?.shown != true && !readerDrawing && !clearData && !chromeOverlay &&
                !layouts && tabletLocalMenu == null && !settingsMounted &&
                (!fieldMounted || hardwareSurface == BrowserSurface.FIELD)
        } }
        SideEffect { onHardwareKeysCurrent?.invoke(hardwareKeysCurrent) }
        DisposableEffect(hardwareKeysCurrent) { onDispose { hardwareMounted[0] = false } }
        val menuBlocked by rememberUpdatedState(!externalInputAvailable || fullscreen || conversationContent != null || readerCovered || clearData || chromeOverlay || layouts || tabletLocalMenu != null || fieldMounted || settingsMounted)
        val menuCovered = menuSession != null
        fun menuSnapshot(source: BrowserState): PageMenuContentSnapshot? = source.tab?.let { tab ->
            PageMenuContentSnapshot(tab, source.page, sitePreferences?.copy(permissions = sitePreferences.permissions.toMap()),
                siteConnection, siteBlocking, blockingStatus, onSiteBlockingChange, onSitePermissionChange,
                readerThemeTitle = readerStyle?.theme?.title, translationMenu = translationMenu)
        }
        menuSession?.let { held ->
            if (held.entry.owned()) menuSnapshot(state)?.let { next ->
                SideEffect { held.update(next) { held.entry.owned() } }
            } else if (!held.entry.drawingOwned()) SideEffect {
                held.entry.presentation.revoke()
                if (menuSession === held) { menu = false; menuSession = null; menuGeneration++ }
            }
        }
        val overlayCallback by rememberUpdatedState(onOverlayChange)
        // Find replaces the page chrome; it keeps the native page visible and interactive.
        SideEffect { onOverlayChange?.invoke(menuCovered || readerCovered || clearData || chromeOverlay || layouts || fieldMounted || settingsMounted) }
        DisposableEffect(controller) { onDispose { controller.dismissFind(); overlayCallback?.invoke(false) } }
        LaunchedEffect(state.privateContentBlocked, state.surface, state.tab?.id, state.selectedSpaceId, state.tab?.url) {
            if (menuSession?.entry?.fieldHandoff?.owned() != true) {
                menuSession?.entry?.presentation?.revoke(); menuSession = null; menuGeneration++
                menu = false
            }
            clearData = false; chromeOverlay = false; layouts = false
            tabletLocalMenu = null
        }
        LaunchedEffect(workspaceProjection.generation) { layouts = false; layoutLease = null }
        LaunchedEffect(fullscreen, conversationContent != null) { if (fullscreen || conversationContent != null) controller.dismissFind() }
        BackHandler(externalInputAvailable && conversationContent == null && !fullscreen && (finding || state.surface != BrowserSurface.PAGE || state.page.canGoBack || state.tab?.openerId != null || state.privateContentBlocked)) {
            if (externalInput.current()) controller.back()
        }
        Surface(modifier.fillMaxSize().then(if (externalInputAvailable) Modifier else Modifier.clearAndSetSemantics {}).onGloballyPositioned { coordinates ->
            pageAddressRoot = coordinates
            val rect = coordinates.boundsInRoot()
            menuRoot = SpacesRect((rect.left / menuDensity.density).toDouble(), (rect.top / menuDensity.density).toDouble(),
                (rect.width / menuDensity.density).toDouble(), (rect.height / menuDensity.density).toDouble())
            val origin = coordinates.positionInWindow()
            fieldRoot = TabletOmniboxRoot(origin.x / menuDensity.density.toDouble(), origin.y / menuDensity.density.toDouble(),
                coordinates.size.width / menuDensity.density.toDouble(), coordinates.size.height / menuDensity.density.toDouble())
            pageCornerSnapshot = TabletWindowCornerSnapshot.capture(pageCornerView, workspaceProjection, requireNotNull(fieldRoot), menuDensity.density)
        }, color = MaterialTheme.colorScheme.background) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val windowHeight = maxHeight.value.toDouble()
                val fullWindow = workspaceWindow ?: if (workspaceProjection.registered)
                    workspaceProjection.geometry ?: BrowserWorkspaceWindow(0.0, 0.0)
                else BrowserWorkspaceWindow(maxWidth.value.toDouble(), maxHeight.value.toDouble())
                val fullLayout = BrowserWorkspaceLayout(maxWidth.value.toInt(), maxHeight.value.toInt(), state.workspace != null, fullWindow)
                // Main already accepted this exact measured root/frame for native visibility.
                val workspaceRoot = tabletWorkspace?.root
                val workspaceFrame = tabletWorkspace?.frame
                val tabletLayout = tabletWorkspace?.presentation
                val layout = workspaceFrame?.pageLayout ?: fullLayout
                val wide = fullLayout.expanded
                val smallestWidth = LocalConfiguration.current.smallestScreenWidthDp
                val tabletField = state.surface == BrowserSurface.FIELD && workspaceProjection.registered && workspaceProjection.geometry == fullWindow &&
                    BrowserTabletOmniboxGeometry.eligible(fullWindow, smallestWidth)
                val addressView = LocalView.current
                val addressRoot = pageAddressRoot
                val addressAvailable = externalInputAvailable && !state.loading && !state.privateContentBlocked && state.surface == BrowserSurface.PAGE && !finding &&
                    workspaceProjection.registered && workspaceProjection.geometry == fullWindow &&
                    BrowserTabletOmniboxGeometry.eligible(fullWindow, smallestWidth) && !fullscreen && conversationContent == null &&
                    menuSession == null && tabletLocalMenu == null && !readerCovered && !clearData && !chromeOverlay && !layouts && !fieldMounted && !settingsMounted
                val addressExternalCover by rememberUpdatedState(fullscreen || conversationContent != null || readerCovered)
                val addressControl = remember(tabletPageAddress, controller, addressView, addressRoot, menuRoot, menuDensity,
                    workspaceProjection.generation, menuGeneration, toolbarCoverageGeneration, addressAvailable, tabletWorkspace, externalInput) {
                    val entry = tabletPageAddress
                    val originalRoot = addressRoot
                    val originalFrame = menuRoot
                    val originalToken = addressView.windowToken
                    val originalScene = menuGeneration
                    val originalCoverage = toolbarCoverageGeneration
                    val originalLayout = tabletLayout
                    if (!addressAvailable || entry == null || originalRoot == null || originalFrame == null) null
                    else BrowserTabletPageAddressControl(entry) {
                        externalInput.current() && pageAddressRoot === originalRoot && originalRoot.isAttached && menuRoot == originalFrame &&
                            originalToken != null && addressView.windowToken === originalToken && addressView.isAttachedToWindow && addressView.isShown &&
                            originalLayout?.layoutCurrent() != false &&
                            !addressExternalCover && menuGeneration == originalScene && toolbarCoverageGeneration == originalCoverage &&
                            menuSession == null && tabletLocalMenu == null &&
                            !clearData && !chromeOverlay && !layouts && !fieldMounted && !settingsMounted
                    }
                }
                DisposableEffect(addressControl) { onDispose { addressControl?.retire() } }
                val sidebarControl = remember(tabletSidebar, tabletWorkspace, controller, addressView, addressRoot,
                    menuRoot, menuDensity, workspaceProjection.generation, menuGeneration, toolbarCoverageGeneration, addressAvailable, externalInput) {
                    val entry = tabletSidebar
                    val originalLayout = tabletLayout
                    val originalRoot = addressRoot
                    val originalFrame = menuRoot
                    val originalToken = addressView.windowToken
                    val originalScene = menuGeneration
                    val originalCoverage = toolbarCoverageGeneration
                    if (!addressAvailable || entry == null || originalLayout == null || workspaceFrame == null ||
                        originalRoot == null || originalFrame == null) null
                    else BrowserTabletSidebarControl(entry) {
                        externalInput.current() && originalLayout.current() && pageAddressRoot === originalRoot && originalRoot.isAttached &&
                            menuRoot == originalFrame && originalToken != null && addressView.windowToken === originalToken &&
                            addressView.isAttachedToWindow && addressView.isShown && !addressExternalCover &&
                            menuGeneration == originalScene && toolbarCoverageGeneration == originalCoverage &&
                            menuSession == null && tabletLocalMenu == null && !clearData && !chromeOverlay &&
                            !layouts && !fieldMounted && !settingsMounted
                    }
                }
                DisposableEffect(sidebarControl) { onDispose { sidebarControl?.retire() } }
                val resizeBegin = remember(tabletWorkspace, sidebarControl, tabletSidebar, externalInput, addressRoot,
                    menuRoot, addressView, menuGeneration, toolbarCoverageGeneration, addressAvailable) {
                    val originalLayout = tabletLayout
                    val entry = tabletSidebar
                    val originalRoot = addressRoot
                    val originalFrame = menuRoot
                    val originalToken = addressView.windowToken
                    val originalScene = menuGeneration
                    val originalCoverage = toolbarCoverageGeneration;
                    { sidebar: Boolean ->
                        if (sidebarControl?.current() != true || originalLayout == null || entry == null || originalRoot == null || originalFrame == null) null
                        else originalLayout.beginResize(sidebar) {
                            entry.current() && externalInput.current() && pageAddressRoot === originalRoot && originalRoot.isAttached &&
                                menuRoot == originalFrame && originalToken != null && addressView.windowToken === originalToken &&
                                addressView.isAttachedToWindow && addressView.isShown && !addressExternalCover &&
                                menuGeneration == originalScene && toolbarCoverageGeneration == originalCoverage &&
                                menuSession == null && tabletLocalMenu == null && !clearData && !chromeOverlay &&
                                !layouts && !fieldMounted && !settingsMounted
                        }
                    }
                }

                val toolbarControl = remember(tabletToolbar, tabletWorkspace, controller, addressView, addressRoot,
                    menuRoot, workspaceProjection.generation, menuGeneration, toolbarCoverageGeneration, addressAvailable, externalInput) {
                    val entry = tabletToolbar
                    val originalLayout = tabletLayout
                    val originalRoot = addressRoot
                    val originalFrame = menuRoot
                    val originalToken = addressView.windowToken
                    val originalScene = menuGeneration
                    val originalCoverage = toolbarCoverageGeneration
                    if (!addressAvailable || entry == null || originalLayout == null || workspaceFrame == null ||
                        originalRoot == null || originalFrame == null) null else BrowserTabletToolbarControl(entry) {
                        externalInput.current() && originalLayout.current() && pageAddressRoot === originalRoot && originalRoot.isAttached &&
                            menuRoot == originalFrame && originalToken != null && addressView.windowToken === originalToken &&
                            addressView.isAttachedToWindow && addressView.isShown && !addressExternalCover &&
                            menuGeneration == originalScene && toolbarCoverageGeneration == originalCoverage &&
                            menuSession == null && tabletLocalMenu == null &&
                            !clearData && !chromeOverlay && !layouts && !fieldMounted && !settingsMounted
                    }
                }
                DisposableEffect(toolbarControl) { onDispose { toolbarControl?.retire() } }
                val siteSource = remember(toolbarControl) { toolbarControl?.site() }
                // This original context may remain current through this one in-root
                // menu. The actionable toolbar control itself retires on coverage.
                val toolbarMenuCurrent = remember(tabletToolbar, tabletLayout, addressRoot, menuRoot,
                    addressView, menuGeneration, addressAvailable, externalInput) {
                    val entry = tabletToolbar; val originalLayout = tabletLayout
                    val originalRoot = addressRoot; val originalFrame = menuRoot
                    val token = addressView.windowToken; val generation = menuGeneration
                    if (!addressAvailable || entry == null || originalLayout == null || originalRoot == null || originalFrame == null) null
                    else ({ externalInput.current() && entry.current() && originalLayout.current() && pageAddressRoot === originalRoot &&
                        originalRoot.isAttached && menuRoot == originalFrame && token != null && addressView.windowToken === token &&
                        addressView.isAttachedToWindow && addressView.isShown && !addressExternalCover &&
                        menuGeneration == generation && menuSession == null && !clearData && !chromeOverlay && !layouts &&
                        !fieldMounted && !settingsMounted })
                }
                val frameControl = remember(tabletLayout, toolbarMenuCurrent) {
                    toolbarMenuCurrent?.let { original -> tabletLayout?.frameControl(original) }
                }
                val toolbarSplit = remember(toolbarControl, workspaceEntry, fullWindow.canSplit) {
                    if (fullWindow.canSplit && toolbarControl?.current() == true) workspaceEntry?.let { controller.captureWorkspaceActions(it) } else null
                }
                // Retained original content only. It never substitutes for an actionable
                // control; the context clears on account/space/profile/native/STOP boundaries.
                val sidebarPixels = remember(controller, tabletSidebarDrawing) { arrayOfNulls<BrowserTabletSidebarControl>(1) }
                if (sidebarControl != null && tabletSidebarDrawing?.current() == true) sidebarPixels[0] = sidebarControl
                val sidebarDrawingControl = sidebarControl ?: sidebarPixels[0]
                val sidebarDrawingCurrent = tabletSidebarDrawing?.current() == true
                val sidebarToggle = remember(tabletWorkspace, sidebarControl) {
                    val original = tabletLayout
                    val control = sidebarControl
                    if (original == null || control == null) null else original.toggleControl(control::current)
                }
                val toolbarMounted = toolbarControl != null && sidebarToggle != null && addressControl != null &&
                    addressRoot != null && workspaceFrame != null && workspaceRoot != null
                val toolbarDrawing = workspaceFrame != null && workspaceRoot != null && sidebarDrawingCurrent &&
                    !state.privateContentBlocked && state.space?.isPrivate == false && state.tab?.isPrivate != true &&
                    !fullscreen && conversationContent == null
                val fieldControls = remember(controller, state.surfaceEpoch, workspaceProjection.generation,
                    fieldLifetime.generation, fieldLifetime.privateBoundary, tabletField, externalInputGeneration, externalInput) { Any() }
                val fieldPlacement = remember(controller, state.surfaceEpoch, state.selectedSpaceId, state.tab?.id,
                    state.space?.websiteProfile, state.fieldIsNewTab, state.fieldIsPrivate, workspaceProjection.generation,
                    fieldLifetime, fieldSourceGeneration, tabletField, externalInputGeneration, externalInput) {
                    BrowserFieldPlacementLease.capture(controller, tabletField, fieldControls, externalInput::current)
                }
                DisposableEffect(fieldPlacement) { onDispose { fieldPlacement.retire() } }
                fun editor(retained: BrowserState, presentation: BrowserFieldPresentation, tablet: TabletOmniboxViewport? = null) =
                    BrowserFieldEditorFrame(retained, wide, presentation, fieldPlacement, tablet,
                        onAskQuestion, onNewChatAboutPage, onOpenChats, onOpenOnMac, macTodayContent, onUnlockPrivate, fieldChatsContent,
                        fieldEditorValue.takeIf { BrowserFieldEditorOwner.from(retained, fieldLifetime.privateBoundary) == fieldEditorOwner }, fieldAgentName, onNewChat)
                SideEffect { if (!workspaceProjection.registered) controller.resizeWorkspace(fullLayout.expanded) }
                val pair = state.workspace.takeIf { layout.split && !fullscreen && state.surface != BrowserSurface.GALLERY }
                val first = pair?.first?.let { id -> state.space?.tabs?.firstOrNull { it.id == id } }
                val second = pair?.second?.let { id -> state.space?.tabs?.firstOrNull { it.id == id } }
                if (state.loading) {
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                } else if (state.privateContentBlocked) {
                    Box(Modifier.fillMaxSize().then(if (readerCovered || settingsMounted || state.surface == BrowserSurface.SETTINGS) Modifier.clearAndSetSemantics {} else Modifier)) {
                    key(externalInput) { PrivateCover(onUnlock = {
                        val attempt = if (externalInput.current() && privateAuthLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) controller.capturePrivateUnlock() else null
                        if (attempt != null) runCatching { onUnlockPrivate { allowed -> privateAuthScope.launch {
                            if (externalInput.current() && privateAuthLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) controller.completePrivateUnlock(attempt, allowed)
                            else controller.cancelPrivateUnlock(attempt)
                        } } }.onFailure { controller.cancelPrivateUnlock(attempt) }
                    }, onLeave = {
                        if (externalInput.current() && controller.state.value.surfaceEpoch == state.surfaceEpoch && controller.state.value.privateContentBlocked)
                            state.spaces.firstOrNull { !it.isPrivate }?.let { controller.selectSpace(it.id) }
                    }) }
                    }
                } else {
                    val pane: @Composable (BrowserTab?, Boolean, Modifier) -> Unit = { tab, focused, paneModifier ->
                        val paneDensity = LocalDensity.current
                        var paneRoot by remember { mutableStateOf<SpacesRect?>(null) }
                        var rootPlate by remember(state.space?.isPrivate) { mutableStateOf<SpacesRect?>(null) }
                        val liftInput = remember { BrowserSpacesLiftInput() }
                            BoxWithConstraints(paneModifier.onGloballyPositioned { coordinates ->
                                val rect = coordinates.boundsInRoot()
                                paneRoot = SpacesRect((rect.left / paneDensity.density).toDouble(), (rect.top / paneDensity.density).toDouble(),
                                    (rect.width / paneDensity.density).toDouble(), (rect.height / paneDensity.density).toDouble())
                            }) {
                                val pageMenuSafeTop = WindowInsets.statusBars.getTop(paneDensity) / paneDensity.density.toDouble()
                                val chat = conversationContent.takeIf { focused && state.surface !in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES) }
                                val field = focused && state.surface in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES)
                                val fieldWidth = if (wide && maxWidth >= 640.dp) 320.0 else maxWidth.value.toDouble()
                                val fieldHeight = maxHeight.value.toDouble()
                                val fieldHost = rememberBrowserFieldHost(state, controller, focused && !fullscreen && !tabletField,
                                    fieldWidth, fieldHeight, rootPlate, stackButton, paneRoot, sheetAllowed = !wide)
                                val sidebar = !tabletField && (field || fieldHost != null) && wide && maxWidth >= 640.dp
                                val reserve = chat != null && wide && maxWidth >= 680.dp
                                val chatWidth = if (wide) minOf(360.dp, maxWidth) else maxWidth
                                val pageCovered = focused && (menuCovered || readerCovered || tabletLocalMenu != null) || settingsMounted || state.surface in setOf(BrowserSurface.SETTINGS, BrowserSurface.HISTORY, BrowserSurface.GALLERY) ||
                                    ((field || fieldHost != null) && !sidebar) || (chat != null && maxWidth <= chatWidth)
                                val pageModifier = if (pageCovered) Modifier.clearAndSetSemantics {} else Modifier
                                val canPresentPaging = externalInputAvailable && pagingAllowed && focused && !fullscreen && chat == null &&
                                    !menuCovered && tabletLocalMenu == null && !clearData && !chromeOverlay && !layouts && !settingsMounted
                                val pagingHost = rememberBrowserPageSwipeHost(state, controller, canPresentPaging,
                                    canPresentPaging && fieldHost == null && state.surface == BrowserSurface.PAGE,
                                    maxWidth.value.toDouble(), maxHeight.value.toDouble(), paneRoot, onPagingVisibility.takeIf { focused }, capturePagingFrame)
                                val spacesHost = rememberBrowserSpacesHostState(state, focused && !fullscreen, maxWidth.value.toDouble(), maxHeight.value.toDouble(),
                                    WindowInsets.statusBars.getTop(paneDensity) / paneDensity.density.toDouble() + 2,
                                    rootPlate, paneRoot, LocalBrowserAccessibility.current.reduceMotion, liftInput)
                                val stackSceneGeneration = menuGeneration
                                val menuWindowGeneration = workspaceProjection.generation
                                val menuLayout = tabletLayout
                                BrowserPane(state, tab, focused,
                                    pageModifier.fillMaxSize().padding(start = if (sidebar) 320.dp else 0.dp, end = if (reserve) chatWidth else 0.dp), controller, fullscreen,
                                    onMenu = openMenu@ {
                                        if (!externalInput.current() || controller.workspaceWindow.value.generation != menuWindowGeneration ||
                                            menuLayout?.layoutCurrent() == false) return@openMenu
                                        val old = menuSession
                                        if (old != null && old.entry.owned()) { menu = true; return@openMenu }
                                        val paneFrame = paneRoot ?: return@openMenu
                                        val rootFrame = menuRoot ?: return@openMenu
                                        val origin = rootPlate ?: return@openMenu
                                        val generation = ++menuGeneration
                                        val lease = capturePageMenuLease?.invoke(generation) ?: run {
                                            controller.message("Page menu isn't ready yet"); return@openMenu
                                        }
                                        val source = controller.state.value
                                        val snapshot = menuSnapshot(source) ?: return@openMenu
                                        if (lease.generation != generation || !lease.ownsSource(source, snapshot.tab.url) ||
                                            externalMenuCurrent?.invoke(lease) != true) return@openMenu
                                        val plate = PageMenuRect(origin.x - paneFrame.x, origin.y - paneFrame.y, origin.width, origin.height)
                                        if (!plate.valid() || paneFrame.width < 160 || paneFrame.height < 80) return@openMenu
                                        val safeTop = (pageMenuSafeTop - paneFrame.y).coerceAtLeast(0.0)
                                        fun titleWidth(words: String) = menuText.measure(words,
                                            androidx.compose.ui.text.TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-.3).sp))
                                            .size.width / paneDensity.density.toDouble()
                                        val geometry = BrowserPageMenuGeometry(paneFrame.width, paneFrame.height, safeTop, plate,
                                            menuBody = 600.0, hostTitleWidth = titleWidth(snapshot.tab.host), certificateTitleWidth = titleWidth("Certificate"))
                                        val originalReaderCurrent = externalMenuCurrent
                                        val originalReader = if (!snapshot.page.readerEnabled) null else readerPreferences?.let { store ->
                                            captureBrowserReaderPresentation(store, controller, lease, addressView) {
                                                externalInput.current() && menuGeneration == generation && menuLayout?.layoutCurrent() != false &&
                                                    originalReaderCurrent?.invoke(lease) == true
                                            }
                                        }
                                        lateinit var held: BrowserPageMenuSession
                                        held = makePageMenuSession(lease, geometry, paneFrame, rootFrame, snapshot, controller, menuContext,
                                            current = {
                                                externalInput.current() && menuGeneration == generation && menuLayout?.layoutCurrent() != false &&
                                                    !menuBlocked && paneRoot == paneFrame && menuRoot == rootFrame &&
                                                    rootPlate == origin && lease.ownsSource(controller.state.value, snapshot.tab.url) &&
                                                    externalMenuCurrent?.invoke(lease) == true
                                            }, closing = { expected -> if (menuSession === held && expected == lease && menuGeneration == generation) menu = false },
                                            released = { expected, _ -> if (menuSession === held && expected == lease && menuGeneration == generation) {
                                                menu = false; menuSession = null
                                            } }, reopened = { expected -> if (menuSession === held && expected == lease && menuGeneration == generation) menu = true },
                                            onAsk = onMenuAsk?.let { callback -> { capturedTab -> callback(lease, capturedTab) } },
                                            onTranslate = onTranslate, onMac = onMenuOpenOnMac, onExtensions = onExtensions,
                                            onReaderSettings = originalReader?.let { original -> {
                                                if (original.current()) {
                                                    addressView.performHapticFeedback(android.view.HapticFeedbackConstants.CONTEXT_CLICK)
                                                    readerPresentation?.drop(); readerPresentation = original
                                                }
                                            } },
                                            editAddress = if (externalMenuFieldCurrent == null) null else editAddress@ { row ->
                                                if (menuSession !== held || !held.entry.owned() || !row.valid()) return@editAddress false
                                                val requested = System.nanoTime()
                                                controller.openField(newTab = false, origin = FieldAnchor(
                                                    row.x + paneFrame.x, row.y + paneFrame.y, row.width, row.height))
                                                val input = controller.captureFieldInput() ?: return@editAddress false
                                                val handoff = BrowserPageMenuFieldHandoff(input, requested, menuReduced, menuAnimations) {
                                                    externalInput.current() && menuSession === held && menuGeneration == generation && !fullscreen && conversationContent == null &&
                                                        menuLayout?.layoutCurrent() != false &&
                                                        !clearData && !chromeOverlay && !layouts && paneRoot == paneFrame && menuRoot == rootFrame &&
                                                        rootPlate == origin && controller.fieldInputCurrent(input) &&
                                                        lease.ownsDrawnField(controller.state.value, input, snapshot.tab.url) &&
                                                        externalMenuFieldCurrent?.invoke(lease, input) == true
                                                }
                                                if (!handoff.owned()) return@editAddress false
                                                held.entry.fieldHandoff = handoff
                                                true
                                            })
                                        menuSession = held; menu = true
                                    }, onChats = onOpenChats, onVoice = onVoiceSearch,
                                    onScan = onScanQr, onChromeOverlay = { chromeOverlay = it },
                                    onStackFrame = { stackButton = it }, onPlateFrame = { rootPlate = it },
                                    onLiftMove = { if (externalInput.current()) liftInput.move(controller, it) else null },
                                    onLiftEnd = { epoch, dy, velocity -> if (externalInput.current()) liftInput.end(epoch, dy, velocity) },
                                    // A row chosen: the bar stands under the going sheet, the page's progress is on it.
                                    chromeAlpha = if (fieldHost != null && !(fieldHost.sheet != null && state.surface == BrowserSurface.PAGE) || tabletField && field) 0f else (1 - (spacesHost?.chromeVeil ?: 0.0)).toFloat(),
                                    stackSceneGeneration = stackSceneGeneration,
                                    menuWindowGeneration = menuWindowGeneration, menuLayout = menuLayout,
                                    tabletPage = workspaceFrame != null,
                                    tabletToolbarMounted = toolbarDrawing,
                                    stackActionsCurrent = { externalInput.current() && focused && !fullscreen && conversationContent == null &&
                                        menuGeneration == stackSceneGeneration && menuSession == null && !clearData &&
                                        !chromeOverlay && !layouts && !fieldMounted && !settingsMounted },
                                    pagingHost = pagingHost.takeIf { focused }, thumbnail = thumbnail, placement = fieldPlacement,
                                    inputOwner = externalInput, inputCurrent = externalInput::current, pageContent = pageContent)
                                if (chat != null) Surface(Modifier.align(Alignment.CenterEnd).width(chatWidth).fillMaxHeight(),
                                    color = MaterialTheme.colorScheme.background, shadowElevation = 8.dp) { chat() }
                                if (focused && chat == null && !fullscreen && state.surface == BrowserSurface.PAGE &&
                                    !menuCovered && !finding && !clearData && !chromeOverlay && !layouts) {
                                    parkedChatContent?.let { content ->
                                        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()
                                            .padding(horizontal = 24.dp, vertical = 88.dp)) { content() }
                                    }
                                }
                                // Phone RootView keeps Chrome/PageMenu below WorkspaceFieldLayer.
                                // Keep this call site stable across handoff: Field takes native input
                                // above the outgoing drawing, without reviving its old menu actions.
                                menuSession?.takeIf { focused && it !== tabletSiteSession && it.pane == paneRoot && it.entry.drawingOwned() }?.let { held ->
                                    BrowserPageMenuHost(held.entry, menu, held.geometry)
                                }
                                if (fieldHost != null) {
                                    // IME insets belong to the window; only its overlap with this pane moves its input.
                                    val imeTop = windowHeight - WindowInsets.ime.getBottom(paneDensity) / paneDensity.density.toDouble()
                                    val overlap = ((paneRoot?.y ?: 0.0) + fieldHeight - imeTop).coerceIn(0.0, fieldHeight)
                                    val pagingScene = pagingHost.scene
                                    val blankFade = pagingScene?.takeIf { it.fading && it.lease.after == null && it.fieldEpoch != null }?.fadeProgress ?: 1.0
                                    val handoff = menuSession?.entry?.fieldHandoff?.takeIf {
                                        it.input.epoch == fieldHost.lease.surfaceEpoch && it.owned()
                                    }
                                    val menuFieldFrame = menuSession?.entry?.presentation?.frame?.collectAsState()?.value
                                    Box(Modifier.width(fieldWidth.dp).fillMaxHeight().graphicsLayer { alpha = blankFade.toFloat() }) {
                                        BrowserFieldHost(state, controller, fieldHost, fieldWidth, fieldHeight, overlap,
                                            covered = !externalInputAvailable || chat != null || (menuCovered && handoff == null) || clearData || chromeOverlay || layouts,
                                            onMounted = { fieldMounted = it }, fromMenu = if (handoff != null) menuFieldFrame?.toField ?: 0.0 else 1.0,
                                            placement = fieldPlacement, focusOwner = fieldInputFocus,
                                            onFieldDestination = handoff?.let { expected -> { rect -> expected.measure(rect); Unit } }) { retained, presentation ->
                                            fieldEditor(editor(retained, presentation))
                                        }
                                    }
                                }
                                if (spacesHost != null) BrowserSpacesHost(state, controller, spacesHost, liftInput) { motion ->
                                    BrowserField(state, controller, wide, onAskQuestion, onNewChatAboutPage, onOpenChats, onOpenOnMac, macTodayContent, motion,
                                        onUnlockPrivate = onUnlockPrivate, fieldChatsContent = fieldChatsContent, placement = fieldPlacement, agentName = fieldAgentName,
                                        onNewChat = onNewChat, sheetAllowed = !wide)
                                }
                            }
                    }
                    // Only this PAGE drawing group is inset/clipped. The movable Field
                    // and all full-root overlays remain outside it.
                    Box(Modifier.fillMaxSize().then(if (workspaceFrame != null) Modifier.clipToBounds()
                        .testTag("browser.tablet.workspace") else Modifier)) {
                        if (workspaceFrame != null && workspaceRoot != null && sidebarDrawingControl != null && sidebarDrawingCurrent) {
                            val sidebar = workspaceFrame.sidebar
                            val drawingOnly = sidebar == null || sidebarControl == null || !addressAvailable
                            // Keep the same composition/scroll when only shown changes.
                            Box(Modifier.offset(x = (-workspaceRoot.x).dp, y = (workspaceFrame.top - workspaceRoot.y).dp)
                                .requiredWidth((sidebar?.width ?: 0.0).dp)
                                .requiredHeight((workspaceFrame.originalWindow.height - workspaceFrame.top).dp)
                                .clipToBounds().then(if (drawingOnly) Modifier.clearAndSetSemantics {} else Modifier)
                                .testTag("browser.tablet.workspace.sidebar")) {
                                key(tabletSidebarDrawing?.scrollKey) { BrowserTabletPublicSidebar(sidebarDrawingControl, drawingOnly = drawingOnly) }
                            }
                        }
                        val corners = pageCornerSnapshot?.takeIf { workspaceRoot != null &&
                            it.current(pageCornerView, workspaceProjection, workspaceRoot, menuDensity.density) }
                        val pageShape = workspaceFrame?.let { BrowserTabletConcentricShape(
                            TabletConcentricGeometry.page(it, corners?.bottomLeft, corners?.bottomRight)) }
                        val pagePlacement = if (workspaceFrame == null || workspaceRoot == null) Modifier.fillMaxSize() else
                            Modifier.offset(x = (workspaceFrame.page.x - workspaceRoot.x).dp,
                                y = (workspaceFrame.page.y - workspaceRoot.y).dp)
                                .requiredSize(workspaceFrame.page.width.dp, workspaceFrame.page.height.dp)
                                .tabletPageOutline(requireNotNull(pageShape), if (workspaceFrame.drawnSplit) 0f else workspaceFrame.pageStrokeWidth.toFloat(),
                                    MaterialTheme.colorScheme.onSurface.copy(alpha = .12f))
                                .testTag("browser.tablet.workspace.page")
                        Box(pagePlacement) {
                            if (first != null && second != null) {
                                if (layout.horizontal) Row(Modifier.fillMaxSize()) {
                                    val fraction = workspaceFrame?.effectiveSplitFraction?.toFloat() ?: .5f
                                    val gap = if (workspaceFrame == null) 1.dp else 8.dp
                                    val paneShape = RoundedCornerShape(10.dp)
                                    @Composable fun paneEdge(focused: Boolean) = if (workspaceFrame == null) Modifier else Modifier
                                        .clip(paneShape).border(if (focused) 1.5.dp else 1.dp,
                                            if (focused) Color(0xFF567DA8) else MaterialTheme.colorScheme.onSurface.copy(alpha = .1f), paneShape)
                                    pane(first, pair?.focused == first.id, Modifier.weight(fraction).fillMaxHeight().then(paneEdge(pair?.focused == first.id)))
                                    Spacer(Modifier.width(gap))
                                    pane(second, pair?.focused == second.id, Modifier.weight(1f - fraction).fillMaxHeight().then(paneEdge(pair?.focused == second.id)))
                                } else Column(Modifier.fillMaxSize()) {
                                    pane(first, pair?.focused == first.id, Modifier.weight(1f).fillMaxWidth())
                                    HorizontalDivider()
                                    pane(second, pair?.focused == second.id, Modifier.weight(1f).fillMaxWidth())
                                }
                            } else pane(state.tab, true, Modifier.fillMaxSize())
                        }
                    }
                    BrowserTabletResizeHandles(workspaceFrame, workspaceRoot, addressAvailable && sidebarControl != null,
                        resizeBegin, Modifier.matchParentSize())
                    if (toolbarMounted) {
                        val originalControl = requireNotNull(toolbarControl)
                        val originalRoot = requireNotNull(addressRoot)
                        val originalToggle = requireNotNull(sidebarToggle)
                        val originalFrame = requireNotNull(workspaceFrame)
                        val originalWorkspaceRoot = requireNotNull(workspaceRoot)
                        val source = siteSource
                        val sourceLayout = tabletLayout
                        val sourceFrame = menuRoot
                        val sourceToken = addressView.windowToken
                        val toolbarSafeTop = WindowInsets.statusBars.getTop(menuDensity) / menuDensity.density.toDouble()
                        val localCurrent = toolbarMenuCurrent
                        val frameAction = frameControl
                        val splitAction = toolbarSplit
                        BrowserTabletToolbar(originalControl, originalRoot, source != null,
                            onSite = openSite@ { anchor ->
                                if (source == null || sourceFrame == null || sourceLayout == null || !anchor.valid() ||
                                    !originalControl.current()) return@openSite false
                                val generation = menuGeneration + 1
                                val lease = source.bind(generation) ?: return@openSite false
                                val snapshot = menuSnapshot(controller.state.value) ?: return@openSite false
                                if (!lease.ownsSource(controller.state.value, snapshot.tab.url) || !source.current(lease)) return@openSite false
                                val plate = PageMenuRect(anchor.x - sourceFrame.x, anchor.y - sourceFrame.y, anchor.width, anchor.height)
                                if (!plate.valid() || sourceFrame.width < 160 || sourceFrame.height < 80) return@openSite false
                                fun titleWidth(words: String) = menuText.measure(words,
                                    androidx.compose.ui.text.TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-.3).sp))
                                    .size.width / menuDensity.density.toDouble()
                                val geometry = BrowserPageMenuGeometry(sourceFrame.width, sourceFrame.height,
                                    toolbarSafeTop, plate,
                                    menuBody = 600.0, hostTitleWidth = titleWidth(snapshot.tab.host), certificateTitleWidth = titleWidth("Certificate"))
                                menuGeneration = generation
                                lateinit var held: BrowserPageMenuSession
                                held = makePageMenuSession(lease, geometry, sourceFrame, sourceFrame, snapshot, controller, menuContext,
                                    current = {
                                        externalInput.current() && menuGeneration == generation && sourceLayout.layoutCurrent() && !menuBlocked &&
                                            pageAddressRoot === originalRoot && originalRoot.isAttached && menuRoot == sourceFrame &&
                                            sourceToken != null && addressView.windowToken === sourceToken && addressView.isAttachedToWindow && addressView.isShown &&
                                            lease.ownsSource(controller.state.value, snapshot.tab.url) && source.current(lease)
                                    }, closing = { expected -> if (menuSession === held && expected === lease && menuGeneration == generation) menu = false },
                                    released = { expected, _ -> if (menuSession === held && expected === lease && menuGeneration == generation) {
                                        menu = false; menuSession = null; tabletSiteSession = null
                                    } }, reopened = { expected -> if (menuSession === held && expected === lease && menuGeneration == generation) menu = true },
                                    onAsk = onMenuAsk?.let { callback -> { captured -> callback(lease, captured) } },
                                    onTranslate = onTranslate, onMac = onMenuOpenOnMac, onExtensions = onExtensions)
                                // This entry starts on the actual Site body. Existing Site/
                                // Certificate actions and guards are reused without a fake control.
                                val now = System.nanoTime()
                                held.entry.presentation.open(now, menuReduced, false)
                                if (!held.entry.presentation.navigate(PageMenuPage.SITE, now, menuReduced, false)) return@openSite false
                                tabletSiteSession = held; menuSession = held; menu = true
                                true
                            }, onGallery = { captured -> tabletGallerySource = captured },
                            splitAvailable = fullWindow.canSplit, splitEnabled = splitAction != null,
                            onSplit = openSplit@ { anchor ->
                                if (!originalControl.current() || localCurrent?.invoke() != true || splitAction == null ||
                                    !controller.workspaceActionsCurrent(splitAction)) return@openSplit false
                                toolbarCoverageGeneration++ // Revoke controls before own-menu coverage can conflate.
                                tabletLocalMenu = BrowserTabletLocalMenu(anchor, workspace = splitAction) {
                                    localCurrent() && controller.workspaceActionsCurrent(splitAction)
                                }; true
                            }, modifier = Modifier.align(Alignment.TopCenter)
                                .offset(y = (originalFrame.toolbar.y - originalWorkspaceRoot.y).dp),
                            sidebar = {
                                BrowserTabletToolbarSidebar(originalToggle, originalControl, originalRoot, openFrame@ { anchor ->
                                    if (!originalControl.current() || frameAction?.current() != true || localCurrent?.invoke() != true) return@openFrame false
                                    toolbarCoverageGeneration++
                                    tabletLocalMenu = BrowserTabletLocalMenu(anchor, frame = frameAction) {
                                        localCurrent() && frameAction.current()
                                    }; true
                                })
                            }, address = { addressModifier ->
                                BrowserTabletPageAddress(requireNotNull(addressControl), state.tab?.url?.let(HistoryPresentation::pretty),
                                    originalRoot, addressModifier, embedded = true)
                            })
                    }
                    if (toolbarDrawing && !toolbarMounted) {
                        BrowserTabletToolbarBackdrop(state, fullWindow.canSplit, Modifier.align(Alignment.TopCenter)
                            .offset(y = (requireNotNull(workspaceFrame).toolbar.y - requireNotNull(workspaceRoot).y).dp))
                    }
                    if (!toolbarDrawing && sidebarToggle != null && workspaceFrame != null && workspaceRoot != null) {
                        BrowserTabletSidebarToggle(sidebarToggle, Modifier.offset(x = (16.0 - workspaceRoot.x).dp,
                            y = (workspaceFrame.toolbar.y + 6.0 - workspaceRoot.y).dp))
                    }
                    if (!toolbarDrawing && addressAvailable && addressControl != null && addressRoot != null) {
                        BrowserTabletPageAddress(addressControl, state.tab?.url?.let(HistoryPresentation::pretty), addressRoot,
                            if (workspaceFrame == null || workspaceRoot == null) Modifier.align(Alignment.TopCenter).statusBarsPadding()
                            else Modifier.align(Alignment.TopCenter).offset(y = (workspaceFrame.toolbar.y - workspaceRoot.y).dp))
                    }
                    tabletSiteSession?.takeIf { menuSession === it && it.entry.drawingOwned() }?.let { held ->
                        BrowserTabletSitePopover(held, menu, controller, menuContext, onTranslate)
                    }
                    if (tabletField && !fullscreen && state.surface == BrowserSurface.FIELD && fieldRoot?.valid == true) {
                        val ownRoot = requireNotNull(fieldRoot)
                        val viewport = TabletOmniboxViewport(fullWindow, ownRoot,
                            WindowInsets.statusBars.getTop(menuDensity) / menuDensity.density.toDouble(),
                            WindowInsets.ime.getBottom(menuDensity) / menuDensity.density.toDouble())
                        val held = menuSession
                        val handoff = held?.entry?.fieldHandoff?.takeIf { it.input.epoch == state.surfaceEpoch && it.owned() }
                        BrowserTabletFieldHost(state, controller, fieldPlacement, viewport,
                            covered = !externalInputAvailable || conversationContent != null || (menuCovered && handoff == null) || clearData || chromeOverlay || layouts,
                            onMounted = { fieldMounted = it }, onHeader = handoff?.let { original ->
                                val originalPane = requireNotNull(held).pane
                                val report: (FieldRect) -> Unit = { rect -> original.measure(FieldRect(rect.x - originalPane.x,
                                    rect.y - originalPane.y, rect.width, rect.height)); Unit }
                                report
                            }, focusOwner = fieldInputFocus,
                            newTabResting = tabletNewTabResting.takeIf { tabletLocalMenu == null && !settingsMounted }) { retained, presentation, target -> fieldEditor(editor(retained, presentation, target)) }
                    }
                    if (!toolbarDrawing && tabletLocalMenu == null && fullWindow.canSplit && !fullscreen && !finding && conversationContent == null && state.surface == BrowserSurface.PAGE && state.space?.isPrivate != true) {
                        Box(Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(12.dp)) {
                            key(workspaceEntry, externalInput) {
                                FilledTonalIconButton(enabled = externalInputAvailable && workspaceEntry != null, onClick = {
                                    if (externalInput.current()) workspaceEntry?.let { original -> controller.captureWorkspaceActions(original)?.let { opened ->
                                        layoutLease = opened; layouts = true
                                    } }
                                }) { Icon(YabGlyphs.TabletSplitView, "Page Layout") }
                            }
                            val opened = layoutLease
                            fun admitted() = externalInput.current() && opened != null && layoutLease === opened && layouts && controller.workspaceActionsCurrent(opened)
                            DropdownMenu(layouts && opened != null && controller.workspaceActionsCurrent(opened), { layouts = false }) {
                                if (opened != null) key(opened) {
                                    DropdownMenuItem(text = { Text("Show Tabs") }, onClick = { if (admitted()) { layouts = false; controller.show(BrowserSurface.SPACES) } })
                                    DropdownMenuItem(text = { Text("New Tab Beside") }, onClick = { if (admitted()) { layouts = false; controller.newTabBeside(opened) } })
                                    if (state.workspace != null) {
                                        DropdownMenuItem(text = { Text("Full Spread") }, onClick = { if (admitted()) { layouts = false; controller.fullSpread(opened) } })
                                        DropdownMenuItem(text = { Text("Close Page") }, onClick = { if (admitted()) { layouts = false; controller.closeWorkspacePage(opened) } })
                                    }
                                }
                            }
                        }
                    }
                    when (state.surface) {
                        BrowserSurface.FIELD, BrowserSurface.SPACES -> Unit
                        BrowserSurface.GALLERY -> BrowserTabGallery(state, controller, thumbnail, onOpenChats, stackButton, shownGallerySource,
                            pageUnderStrip = workspaceFrame == null && !fullscreen)
                        BrowserSurface.HISTORY -> BrowserHistoryPanel(state, controller)
                        BrowserSurface.SETTINGS -> Unit
                        BrowserSurface.PAGE -> Unit
                    }
                    tabletLocalMenu?.let { original ->
                        if (!original.current()) SideEffect { if (tabletLocalMenu === original) tabletLocalMenu = null }
                        else key(original) {
                            fun close() { if (tabletLocalMenu === original) tabletLocalMenu = null }
                            fun admitted() = externalInput.current() && tabletLocalMenu === original && original.current()
                            fun perform(action: () -> Unit) { if (admitted()) { action(); close() } }
                            BackHandler { close() }
                            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .12f))
                                .clickable(onClick = ::close).clearAndSetSemantics {})
                            val root = menuRoot
                            if (root != null) {
                                val width = minOf(280.0, root.width)
                                val x = (original.anchor.x - root.x).coerceIn(0.0, (root.width - width).coerceAtLeast(0.0))
                                val y = (original.anchor.y + original.anchor.height - root.y).coerceIn(0.0, (root.height - 240.0).coerceAtLeast(0.0))
                                Surface(Modifier.offset(x.dp, y.dp).width(width.dp).testTag("browser.tablet.context-menu"),
                                    shape = RoundedCornerShape(16.dp), shadowElevation = 8.dp) {
                                    Column(Modifier.padding(vertical = 8.dp)) {
                                        original.frame?.let { frame ->
                                            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(enabled = admitted(),
                                                onClick = { perform { frame.perform() } }).padding(horizontal = 16.dp)
                                                .testTag("browser.tablet.frame"), verticalAlignment = Alignment.CenterVertically) {
                                                Text("Frame Page with Sidebar", Modifier.weight(1f))
                                                Checkbox(frame.framed, null)
                                            }
                                        }
                                        original.workspace?.let { opened ->
                                            DropdownMenuItem(text = { Text("Open Beside") }, onClick = { perform { controller.newTabBeside(opened) } })
                                            if (opened.entry.workspace != null) {
                                                DropdownMenuItem(text = { Text("Full Spread") }, onClick = { perform { controller.fullSpread(opened) } })
                                                DropdownMenuItem(text = { Text("Close Page") }, onClick = { perform { controller.closeWorkspacePage(opened) } })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                BrowserSettingsHost(state, controller, onMounted = { settingsMounted = it }) { settingsHost, settingsLease ->
                    BrowserSettingsPanel(state, controller, onSyncSettings, onExtensions, onOpenSystemSettings, onOpenCredentialsSettings,
                        onClearData = { clearData = true }, blocksAdsEnabled = blocksAdsEnabled, onBlocksAdsChange = onBlocksAdsChange,
                        blockingStatus = blockingStatus, reports = reports, aiSettings = aiSettingsContent, host = settingsHost, lease = settingsLease)
                }
                if (state.persistenceError != null) {
                    Text(state.persistenceError!!, Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(12.dp).background(MaterialTheme.colorScheme.errorContainer, RoundedCornerShape(16.dp)).padding(12.dp), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall)
                }
                val reducedMotion = LocalBrowserAccessibility.current.reduceMotion
                val toastDrop = with(LocalDensity.current) { 14.dp.roundToPx() }
                var lastMessage by remember(state.privateContentBlocked, state.selectedSpaceId, state.tab?.id) { mutableStateOf("") }
                SideEffect { state.message?.let { lastMessage = it } }
                AnimatedVisibility(state.message != null, modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 12.dp),
                    enter = if (reducedMotion) EnterTransition.None else fadeIn(tween(200)) + slideInVertically(BrowserMotion.toastIn()) { -toastDrop },
                    exit = if (reducedMotion) ExitTransition.None else fadeOut(BrowserMotion.toastOut()) + slideOutVertically(BrowserMotion.toastOut()) { -toastDrop }) {
                    Surface(shape = CircleShape, shadowElevation = 8.dp, color = MaterialTheme.colorScheme.surface) {
                        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(state.message ?: lastMessage, style = MaterialTheme.typography.bodyMedium)
                            if (state.undoAvailable) key(externalInput) { TextButton(onClick = { if (externalInput.current()) controller.undoClose() }) { Text("Undo") } }
                        }
                    }
                }
            }
        }
        readerPresentation?.let { original -> key(original) {
            BrowserReaderCard(original, onCoverage = { drawing -> if (readerPresentation === original) readerDrawing = drawing })
        } }
        if (clearData) key(externalInput) { AlertDialog(onDismissRequest = { clearData = false }, title = { Text("Clear History and Website Data?") }, text = { Text("Websites sign you out. Your tabs stay.") }, confirmButton = {
            TextButton(onClick = { if (externalInput.current()) { clearData = false; controller.clearHistoryAndData() } }) { Text("Clear History and Data", color = MaterialTheme.colorScheme.error) }
        }, dismissButton = { TextButton(onClick = { clearData = false }) { Text("Cancel") } }) }
    }
}

/** The first tap on a companion focuses it, matching iOS's native pane contract. */
@Composable
private fun BrowserPane(
    state: BrowserState, tab: BrowserTab?, focused: Boolean, modifier: Modifier,
    controller: BrowserController, fullscreen: Boolean, onMenu: () -> Unit,
    onChats: (() -> Unit)?, onVoice: (() -> Unit)?, onScan: (() -> Unit)?,
    onChromeOverlay: (Boolean) -> Unit,
    onStackFrame: (GalleryRect) -> Unit,
    onPlateFrame: (SpacesRect) -> Unit,
    onLiftMove: (Double) -> Long?, onLiftEnd: (Long, Double, Double) -> Unit,
    chromeAlpha: Float,
    stackSceneGeneration: Long, stackActionsCurrent: () -> Boolean,
    menuWindowGeneration: Long,
    menuLayout: BrowserTabletWorkspacePresentation?,
    tabletPage: Boolean,
    tabletToolbarMounted: Boolean,
    pagingHost: BrowserPageSwipeHostState?,
    thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?,
    placement: BrowserFieldPlacementLease, inputOwner: Any, inputCurrent: () -> Boolean,
    pageContent: @Composable (BrowserTab, WebsiteProfile, Modifier) -> Unit,
) {
    Box(modifier.clip(RoundedCornerShape(0.dp))) {
        val pageTop = if (fullscreen || tabletPage) 0.dp else WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        BrowserPageSwipeDeck(state, tab, pagingHost, Modifier.fillMaxSize(), page = pageContent, pageTop = pageTop,
            empty = {
                if (tabletPage) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
                else key(inputOwner) { BrowserEmptyHome(state, controller, inputCurrent, onLiftMove, onLiftEnd) }
            },
            blank = { blankModifier ->
                Box(blankModifier) {
                    if (tabletPage) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background))
                    else if (state.space?.isPrivate == true) Box(Modifier.fillMaxSize().background(Color(0xFF0E0D12)))
                    else BrowserTabGround(state.space, Modifier.fillMaxSize())
                }
            })
        val page = tab?.id?.let(state.pageStates::get)
        if (page?.error != null && focused && tab != null) key(inputOwner) { PageFailure(page.error, tab.host) { if (inputCurrent()) controller.reloadOrStop() } }
        if (focused) {
            if (!fullscreen) {
                if (state.find != null) key(inputOwner) { PageFindBar(state.find!!, controller, state.surfaceEpoch, inputCurrent, Modifier.align(Alignment.BottomCenter)) }
                else if (!tabletToolbarMounted && !state.emptyHomeBar) key(inputOwner) { BottomChrome(state, controller, onMenu, onChats, onVoice, onScan, onChromeOverlay, onStackFrame, onPlateFrame, onLiftMove, onLiftEnd, chromeAlpha, stackSceneGeneration, stackActionsCurrent, menuWindowGeneration, menuLayout, pagingHost, thumbnail, inputCurrent, paneOwner = tab?.id) }
            }
        } else if (tab != null) {
            key(inputOwner) { Box(Modifier.fillMaxSize().clickable { if (inputCurrent()) controller.selectTab(tab.id) }
                .semantics { contentDescription = "Use ${tab.title}" }) }
            if (!tabletToolbarMounted) Text(tab.title, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(24.dp)
                .background(MaterialTheme.colorScheme.surface, CircleShape).padding(12.dp), maxLines = 1)
        }
    }
}

@Composable
private fun PageFindBar(find: BrowserFindState, controller: BrowserController, focusRequest: Long, inputCurrent: () -> Boolean, modifier: Modifier = Modifier) {
    val focus = remember(find.tab) { FocusRequester() }
    var options by remember(find.tab) { mutableStateOf(false) }
    val canStep = !find.searching && !find.failed && find.query.text.isNotEmpty() && find.result.total != 0
    Surface(modifier.fillMaxWidth().navigationBarsPadding().imePadding(), color = MaterialTheme.colorScheme.surface,
        shadowElevation = 8.dp) {
        Column(Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { if (inputCurrent()) controller.dismissFind() }) { Icon(YabGlyphs.CrossMedium, "Close Find") }
                OutlinedTextField(find.query.text, { if (inputCurrent()) controller.find(it) }, Modifier.weight(1f).focusRequester(focus).testTag("browser.find.query"),
                    singleLine = true, label = { Text("Find on Page") },
                    trailingIcon = { if (find.query.text.isNotEmpty()) IconButton(onClick = { if (inputCurrent()) controller.find("") }) { Icon(YabGlyphs.CircleX, "Clear Find") } },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { if (inputCurrent()) controller.findNext() }))
                IconButton(onClick = { if (inputCurrent()) controller.findNext(true) }, enabled = canStep) { Icon(YabGlyphs.ChevronTopSmall, "Previous Match") }
                IconButton(onClick = { if (inputCurrent()) controller.findNext() }, enabled = canStep) { Icon(YabGlyphs.ChevronDownSmall, "Next Match") }
            }
            Row(Modifier.padding(start = 48.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(when {
                    find.failed -> "Find isn't available on this page"
                    find.query.text.isEmpty() -> ""
                    find.searching -> "Searching…"
                    find.result.total == 0 -> "No matches"
                    find.result.total < 0 -> "${find.result.current} of …"
                    else -> "${find.result.current} of ${find.result.total}"
                }, Modifier.weight(1f).testTag("browser.find.count"), style = MaterialTheme.typography.labelMedium)
                Box {
                    TextButton(onClick = { if (inputCurrent()) options = true }) { Text("Options") }
                    DropdownMenu(options, { options = false }) {
                        DropdownMenuItem(text = { Text("Match Case") }, leadingIcon = { Checkbox(find.query.matchCase, null) },
                            onClick = { if (inputCurrent()) { options = false; controller.findOptions(!find.query.matchCase, find.query.wholeWord) } })
                        DropdownMenuItem(text = { Text("Whole Words") }, leadingIcon = { Checkbox(find.query.wholeWord, null) },
                            onClick = { if (inputCurrent()) { options = false; controller.findOptions(find.query.matchCase, !find.query.wholeWord) } })
                    }
                }
            }
        }
    }
    LaunchedEffect(find.tab, focusRequest, inputCurrent) { if (inputCurrent()) focus.requestFocus() }
}

/** Original external cover authority, separate from retained Field/editor lifetime. */
private class BrowserScreenExternalInput(private val originalCurrent: (() -> Boolean)?) {
    private var retired = false
    fun retire() { retired = true }
    fun current(): Boolean {
        if (retired) return false
        if (originalCurrent != null && !runCatching(originalCurrent).getOrDefault(false)) retired = true
        return !retired
    }
}

/** Local cover writes revoke keys synchronously, including an ABA before recomposition. */
private class BrowserHardwareKeyCoverage {
    var generation by mutableLongStateOf(0L)
        private set
    private var retired = false
    fun current(original: Long): Boolean = !retired && generation == original
    fun retire() { retired = true }
    fun <T> state(initial: T): MutableState<T> {
        val source = mutableStateOf(initial)
        return object : MutableState<T> {
            override var value: T
                get() = source.value
                set(next) { if (source.value != next) { generation++; source.value = next } }
            override fun component1(): T = value
            override fun component2(): (T) -> Unit = { value = it }
        }
    }
}

@Composable
private fun PageFailure(error: String, host: String, retry: () -> Unit) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(YabGlyphs.WifiNoSignal, null, Modifier.size(44.dp))
            Text("Can't open page", Modifier.padding(top = 16.dp), style = MaterialTheme.typography.headlineSmall)
            Text(host, Modifier.padding(top = 8.dp), fontWeight = FontWeight.Medium)
            Text(error, Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = retry) { Text("Try Again") }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
private enum class ChromePanPart { PLATE, BACK, STACK }

@Composable
private fun BottomChrome(state: BrowserState, controller: BrowserController, onMenu: () -> Unit, onChats: (() -> Unit)?, onVoice: (() -> Unit)?, onScan: (() -> Unit)?, onOverlay: (Boolean) -> Unit,
    onStackFrame: (GalleryRect) -> Unit, onPlateFrame: (SpacesRect) -> Unit,
    onLiftMove: (Double) -> Long?, onLiftEnd: (Long, Double, Double) -> Unit,
    chromeAlpha: Float, stackSceneGeneration: Long, stackActionsCurrent: () -> Boolean,
    menuWindowGeneration: Long,
    menuLayout: BrowserTabletWorkspacePresentation?,
    pagingHost: BrowserPageSwipeHostState?, thumbnail: (@Composable (BrowserTab, Modifier) -> Unit)?, inputCurrent: () -> Boolean,
    paneOwner: String?) {
    var plusMenu by remember(state.tab?.id, state.tab?.url, state.surface, state.privateContentBlocked) { mutableStateOf(false) }
    var backMenu by remember(state.tab?.id, state.tab?.url, state.surface, state.privateContentBlocked) { mutableStateOf<Pair<String, List<BrowserBackItem>>?>(null) }
    val overlay by rememberUpdatedState(onOverlay)
    SideEffect { onOverlay(plusMenu || backMenu != null) }
    DisposableEffect(Unit) { onDispose { overlay(false) } }
    BackHandler(backMenu != null) { backMenu = null }
    val foldRule = remember(state.tab?.id) { BrowserChromeFold() }
    var folded by remember(foldRule) { mutableStateOf(false) }
    var observedUserScroll by remember(foldRule) { mutableStateOf(0f) }
    LaunchedEffect(foldRule, state.page.userScrollY, state.surface) {
        val changed = observedUserScroll != state.page.userScrollY
        observedUserScroll = state.page.userScrollY
        if (state.surface != BrowserSurface.PAGE) folded = foldRule.unfold()
        else if (changed) folded = foldRule.scrolled(state.page.userScrollY)
    }
    LaunchedEffect(folded) { if (folded) { plusMenu = false; backMenu = null } }
    val reduced = LocalBrowserAccessibility.current.reduceMotion
    val progress by animateFloatAsState(if (folded) 1f else 0f,
        animationSpec = BrowserMotion.chromeFold(reduced), label = "chromeFold")
    val glyphOpacity by animateFloatAsState(if (folded) 0f else 1f,
        animationSpec = tween(if (reduced || folded) 0 else 100, easing = BrowserMotion.easeOut), label = "chromeGlyphs")
    val words = browserChromeAddress(state.tab?.url)
    val stack = state.stackContents()
    val textMeasurer = rememberTextMeasurer()
    val labelStyle = LocalTextStyle.current
    val density = LocalDensity.current
    val liftMove by rememberUpdatedState(onLiftMove)
    val liftEnd by rememberUpdatedState(onLiftEnd)
    val pagingScene = pagingHost?.scene
    val stackAllTabs = rememberPrivateStackAllTabs(state, controller, stackSceneGeneration,
        !folded && pagingScene == null && chromeAlpha > .5f && !plusMenu && backMenu == null && stackActionsCurrent()) {
        !folded && pagingHost?.scene == null && plusMenu == false && backMenu == null && stackActionsCurrent()
    }
    val pagingGlyphs by animateFloatAsState(if (pagingScene == null) 1f else 0f,
        animationSpec = BrowserMotion.spring(.3f), label = "paging glyphs")
    fun Modifier.chromePan(part: ChromePanPart) = pointerInput(state.selectedSpaceId, state.tab?.id, folded, pagingHost, part) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val source = controller.state.value
            val capturedSwipe = controller.capturePageSwipe()
            val sourceTab = source.tab?.id; val sourceUrl = source.tab?.url; val sourceSpace = source.selectedSpaceId
            val sourceProfile = source.space?.websiteProfile; val sourceEpoch = source.surfaceEpoch
            val wasFolded = folded
            val start = down.position
            val tracker = VelocityTracker().apply { addPosition(down.uptimeMillis, start) }
            var axis = 0 // Across, plate lift, suppressed, stack flick.
            var openedEpoch: Long? = null
            var ended = false
            var dx = 0.0; var dy = 0.0
            fun current() = inputCurrent() && controller.state.value.let { now ->
                !now.privateContentBlocked && now.selectedSpaceId == sourceSpace && now.tab?.id == sourceTab &&
                    now.tab?.url == sourceUrl && now.space?.websiteProfile == sourceProfile &&
                    now.surfaceEpoch == (openedEpoch ?: sourceEpoch) && now.surface in setOf(BrowserSurface.PAGE, BrowserSurface.SPACES)
            }
            try {
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    // Compose encodes a cancelled stream as a consumed up-state.
                    // Check before this recognizer consumes its own movement/up.
                    if (!change.pressed && change.isConsumed) break
                    tracker.addPosition(change.uptimeMillis, change.position)
                    dx = (change.position.x - start.x) / density.density.toDouble()
                    dy = (change.position.y - start.y) / density.density.toDouble()
                    if (!current()) break
                    if (axis == 0 && maxOf(kotlin.math.abs(dx), kotlin.math.abs(dy)) > 7) {
                        axis = when {
                            wasFolded -> 3
                            kotlin.math.abs(dx) > kotlin.math.abs(dy) -> if (pagingHost?.begin(capturedSwipe) == true) 1 else 3
                            dy < 0 && part == ChromePanPart.PLATE -> 2
                            dy < 0 && part == ChromePanPart.STACK -> 4
                            else -> 3
                        }
                    }
                    if (axis != 0) change.consume()
                    if (change.pressed) {
                        if (axis == 1 && pagingHost?.move(dx) != true) break
                        if (axis == 2) openedEpoch = liftMove(dy) ?: openedEpoch
                    } else {
                        val speed = tracker.calculateVelocity()
                        val vy = speed.y / density.density.toDouble()
                        when {
                            axis == 1 -> pagingHost?.end(dx, speed.x / density.density.toDouble())
                            axis == 2 -> openedEpoch?.let { liftEnd(it, dy, vy) }
                            axis == 4 && dy < -45 -> controller.previousTab()
                            wasFolded && part == ChromePanPart.PLATE && axis != 0 && kotlin.math.abs(dy) >= kotlin.math.abs(dx) && (dy < -24 || vy < -300) -> controller.show(BrowserSurface.SPACES)
                        }
                        ended = true
                        break
                    }
                }
            } finally {
                if (!ended) {
                    if (axis == 1) pagingHost?.cancel()
                    openedEpoch?.let { liftEnd(it, dy, 0.0) }
                }
            }
        }
    }
    val chromeObserver = LocalBrowserChromeObserver.current
    val chromeClip = LocalBrowserChromeClipping.current
    val tappableBottom = WindowInsets.tappableElement.getBottom(density) / density.density
    val foldedWords = remember(words, textMeasurer, density, labelStyle) {
        with(density) { textMeasurer.measure(words, style = browserChromeLabelStyle(labelStyle, 13f),
            maxLines = 1, softWrap = false).size.width.toDp().value }
    }
    BoxWithConstraints(Modifier.fillMaxSize().graphicsLayer { alpha = chromeAlpha }
        .then(if (chromeAlpha < 0.5f) Modifier.clearAndSetSemantics {} else Modifier), contentAlignment = Alignment.BottomCenter) {
        val pose = BrowserChromePose(progress, maxWidth.value, foldedWords)
        val plateBottom = browserChromeBottom(pose.bottom, pose.plateHeight, tappableBottom)
        val controlsBottom = browserChromeBottom(28f, 48f, tappableBottom)
        // The engine reserves space for the fully unfolded chrome and clips
        // only the currently covered part; the fold moves the covered part,
        // never the reservation. The covered part is the plate's 48 dp touch
        // target, not the drawn capsule: the target stays mounted through the
        // fold, and a page element raised above the capsule would still lose
        // taps in the touch box's strip above it. from() reports the target's
        // top edge with the layout's own integer outset.
        val paneHeightPx = with(density) { maxHeight.roundToPx() }
        val clip = BrowserChromeClipping.from(plateBottom, pose.plateHeight, controlsBottom, 48f,
            density.density, paneHeightPx)
        // Keyed on the pane too: a front-tab switch with an unchanged pose must
        // still stamp the new pane, not wait for the next fold frame.
        LaunchedEffect(chromeClip, clip, paneOwner) { chromeClip?.invoke(paneOwner, clip) }
        val currentChromeClip by rememberUpdatedState(chromeClip)
        // The clear goes to the owner this effect ran for, the key captured at
        // start: on a front-tab switch the old pane's view is cleared before
        // the new pane is stamped, and on unmount the last owner is cleared.
        DisposableEffect(paneOwner) { onDispose { currentChromeClip?.invoke(paneOwner, BrowserChromeClipping.none) } }
        Box(Modifier.padding(start = 26.dp, end = 26.dp, top = 28.dp, bottom = controlsBottom.dp).fillMaxWidth().height(48.dp)) {
            Box(Modifier.align(Alignment.CenterStart).offset(x = pose.sideSlide.dp).size(48.dp).graphicsLayer {
                scaleX = pose.sideScale; scaleY = pose.sideScale
            }.then(if (folded) Modifier.clearAndSetSemantics {} else Modifier)) {
                val enabled = state.page.canGoBack || state.tab?.openerId != null
                // The empty page has nothing to go back from.
                val hasPage = !state.emptyHome
                // Alpha needs an offscreen group. Keep its shadow inside that
                // group while the original 48 dp button/anchor stays in place.
                Box(Modifier.requiredSize(72.dp).graphicsLayer {
                    compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen
                    alpha = if (hasPage) pose.sideOpacity else 0f
                }
                    .testTag("browser.chrome.back.fade"), contentAlignment = Alignment.Center) {
                Surface(Modifier.size(48.dp).testTag("browser.chrome.back").combinedClickable(enabled = hasPage && enabled && !folded && pagingScene == null,
                    onClick = { if (inputCurrent()) controller.back() }, onLongClick = {
                        if (inputCurrent()) state.tab?.let { backMenu = it.id to controller.backItems(); plusMenu = false }
                    }).chromePan(ChromePanPart.BACK), shape = CircleShape, color = MaterialTheme.colorScheme.surface, shadowElevation = 3.dp) {
                    Box(contentAlignment = Alignment.Center) { Icon(YabGlyphs.ChevronLeft, "Back", tint = LocalContentColor.current.copy(alpha = if (enabled) 1f else 0.38f)) }
                }
                }
                DropdownMenu(backMenu != null, { backMenu = null }) {
                    backMenu?.let { (owner, items) ->
                        for (item in items) DropdownMenuItem(text = {
                            Column {
                                Text(item.title.ifBlank { item.url }, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(runCatching { java.net.URI(item.url).host }.getOrNull() ?: item.url, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                            }
                        }, onClick = { if (inputCurrent()) { backMenu = null; controller.goBackTo(owner, item) } })
                        if (items.isNotEmpty()) HorizontalDivider()
                    }
                    DropdownMenuItem(text = { Text("All History") }, onClick = { if (inputCurrent()) { backMenu = null; controller.show(BrowserSurface.HISTORY) } })
                }
            }
            Box(Modifier.align(Alignment.CenterEnd).offset(x = -pose.sideSlide.dp).size(48.dp).graphicsLayer {
                scaleX = pose.sideScale; scaleY = pose.sideScale
            }.then(if (folded) Modifier.clearAndSetSemantics {} else Modifier)) {
                Box(Modifier.requiredSize(72.dp).graphicsLayer {
                    compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen
                    alpha = pose.sideOpacity
                }
                    .testTag("browser.chrome.stack.fade"), contentAlignment = Alignment.Center) {
                Surface(Modifier.size(48.dp).testTag("browser.chrome.stack").onGloballyPositioned { coordinates ->
                    val frame = coordinates.boundsInRoot()
                    onStackFrame(GalleryRect((frame.left / density.density).toDouble(), (frame.top / density.density).toDouble(),
                        (frame.width / density.density).toDouble(), (frame.height / density.density).toDouble()))
                }.combinedClickable(enabled = !folded && pagingScene == null, onClick = { if (inputCurrent()) { if (stack.front != null) controller.show(BrowserSurface.GALLERY) else controller.openField() } }, onLongClick = { if (inputCurrent()) plusMenu = true }).chromePan(ChromePanPart.STACK)
                    .semantics { if (stackAllTabs != null) customActions = listOf(stackAllTabs) }, shape = CircleShape, color = MaterialTheme.colorScheme.surface, shadowElevation = 3.dp) {
                    BrowserStackGlyph(listOfNotNull(stack.front, stack.back), thumbnail)
                }
                }
                DropdownMenu(plusMenu, { plusMenu = false }) {
                    DropdownMenuItem(text = { Text("New Tab") }, onClick = { if (inputCurrent()) { plusMenu = false; controller.openField() } })
                    DropdownMenuItem(text = { Text("New Private Tab") }, onClick = { if (inputCurrent()) { plusMenu = false; controller.openField(privately = true) } })
                    if (onChats != null) DropdownMenuItem(text = { Text("New Chat") }, onClick = { if (inputCurrent()) { plusMenu = false; onChats() } })
                    if (onVoice != null) DropdownMenuItem(text = { Text("Voice Search") }, onClick = { if (inputCurrent()) { plusMenu = false; onVoice() } })
                    if (onScan != null) DropdownMenuItem(text = { Text("Scan QR Code") }, onClick = { if (inputCurrent()) { plusMenu = false; onScan() } })
                    if (!stack.lone) listOfNotNull(stack.front, stack.back).forEach { tab -> DropdownMenuItem(text = { Text(tab.title, maxLines = 1) }, leadingIcon = { BrowserFavicon(tab, 20.dp) }, onClick = { if (inputCurrent()) { plusMenu = false; controller.selectTab(tab.id) } }) }
                    DropdownMenuItem(text = { Text("All Tabs \u00B7 ${stack.count}") }, onClick = { if (inputCurrent()) { plusMenu = false; controller.show(BrowserSurface.GALLERY) } })
                }
            }
        }
        // The drawn capsule stays inside one mounted 48 dp touch target throughout the fold.
        Box(Modifier.align(Alignment.BottomCenter).padding(bottom = plateBottom.dp)
            // Center alignment rounds the odd inner pixel upward. Use the other
            // integer half here so a 31px capsule keeps its exact 16dp edge gap.
            .offset(y = with(density) { ((48.dp.roundToPx() - pose.plateHeight.dp.roundToPx()) / 2).toDp() })
            .width(pose.plateWidth.dp).height(48.dp)
            .testTag("browser.chrome.plate")
            .combinedClickable(enabled = pagingScene == null, onClick = { if (inputCurrent()) controller.openField(newTab = state.emptyHome) }, onLongClick = { if (inputCurrent() && !state.emptyHome) controller.reader() })
            .chromePan(ChromePanPart.PLATE).semantics {
                if (pagingHost != null && !folded) customActions = listOf(
                    CustomAccessibilityAction("Next Tab") { inputCurrent() && pagingHost.step(1) },
                    CustomAccessibilityAction("Previous Tab") { inputCurrent() && pagingHost.step(-1) })
            }, contentAlignment = Alignment.Center) {
            Surface(Modifier.fillMaxWidth().height(pose.plateHeight.dp).testTag("browser.chrome.capsule").onGloballyPositioned { coordinates ->
                val rect = coordinates.boundsInRoot()
                onPlateFrame(SpacesRect((rect.left / density.density).toDouble(), (rect.top / density.density).toDouble(),
                    (rect.width / density.density).toDouble(), (rect.height / density.density).toDouble()))
                chromeObserver?.invoke(BrowserChromeFrame(System.nanoTime(), rect, density.density))
            },
                shape = CircleShape, color = MaterialTheme.colorScheme.surface, shadowElevation = 4.dp) {
                Box(contentAlignment = Alignment.Center) {
                    if (pagingScene != null && !folded) BrowserPageSwipeLabels(pagingScene, pose.labelSize,
                        Modifier.fillMaxWidth().padding(horizontal = 44.dp))
                    // The empty page: "+ New Tab", the plate is the way out of it.
                    else if (state.emptyHome) Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(YabGlyphs.PlusMedium, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("New Tab", fontSize = pose.labelSize.sp)
                    }
                    else BrowserChromeLabel(words, pose.labelSize,
                        Modifier.fillMaxWidth().padding(horizontal = (22f + 22f * (1f - progress)).dp))
                    if (!state.emptyHome) key(menuWindowGeneration, menuLayout?.revision) {
                        IconButton(onClick = { if (inputCurrent()) onMenu() }, enabled = !folded && pagingScene == null,
                            modifier = Modifier.align(Alignment.CenterStart).size(44.dp).alpha(glyphOpacity * pagingGlyphs)
                                .then(if (folded) Modifier.clearAndSetSemantics {} else Modifier)) { Icon(YabGlyphs.PlateLines, "Page menu", Modifier.size(20.dp)) }
                    }
                    if (!state.emptyHome) BrowserReloadControl(loading = state.page.loading, enabled = !folded && pagingScene == null,
                        onClick = { if (inputCurrent()) controller.reloadOrStop() },
                        modifier = Modifier.align(Alignment.CenterEnd).alpha(glyphOpacity * pagingGlyphs)
                            .then(if (folded) Modifier.clearAndSetSemantics {} else Modifier))
                }
            }
        }
    }
}

/** A saved semantic action belongs to this rendering, never a replacement Plus. */
private class PrivateStackAllTabsAction(private val activate: () -> Boolean) {
    private var live = true
    fun perform(): Boolean = live && activate()
    fun revoke() { live = false }
}

@Composable
private fun rememberPrivateStackAllTabs(source: BrowserState, controller: BrowserController,
    sceneGeneration: Long, enabled: Boolean, environmentCurrent: () -> Boolean): CustomAccessibilityAction? {
    val lifetime by controller.settingsPresentationLifetime.collectAsState()
    val sourceGeneration by controller.historyPresentationLifetime.collectAsState()
    val view = LocalView.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val window = view.windowToken
    val front = source.tab
    val offered = enabled && lifetime.active && !source.loading && !source.privateContentBlocked &&
        source.surface == BrowserSurface.PAGE && source.find == null && source.space?.isPrivate == true && front?.isPrivate == true &&
        source.privateFrontGalleryCards().singleOrNull()?.id == front.id && window != null
    val action = remember(controller, lifetime, sourceGeneration, sceneGeneration, source.surfaceEpoch,
        source.selectedSpaceId, source.space?.websiteProfile, front?.id, front?.url, front?.isPrivate,
        offered, view, lifecycle, window) {
        // Delegated collectAsState reads stay live. The saved action must instead
        // retain the values from this rendering, including before recomposition.
        val originalLifetime = lifetime
        val originalSourceGeneration = sourceGeneration
        if (!offered) null else PrivateStackAllTabsAction {
            val current = controller.state.value
            // These existing lifetimes only revoke this original PAGE snapshot.
            // Account replacement also advances its surfaceEpoch before publication.
            if (controller.settingsPresentationLifetime.value != originalLifetime || !originalLifetime.active ||
                controller.historyPresentationLifetime.value != originalSourceGeneration || !environmentCurrent() ||
                !view.isAttachedToWindow || !view.isShown || view.windowToken !== window || !view.hasWindowFocus() ||
                !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) || current.loading || current.privateContentBlocked ||
                current.surface != BrowserSurface.PAGE || current.find != null || current.surfaceEpoch != source.surfaceEpoch ||
                current.selectedSpaceId != source.selectedSpaceId || current.space?.websiteProfile != source.space?.websiteProfile ||
                current.space?.isPrivate != true || current.tab?.isPrivate != true || current.tab?.id != front?.id ||
                current.tab?.url != front?.url || current.privateFrontGalleryCards().singleOrNull()?.id != front?.id) false
            else { controller.show(BrowserSurface.GALLERY); true }
        }
    }
    DisposableEffect(action) { onDispose { action?.revoke() } }
    return action?.let { captured -> remember(captured) { CustomAccessibilityAction("Show All Tabs", captured::perform) } }
}

@Composable
private fun PrivateCover(onUnlock: () -> Unit, onLeave: () -> Unit) {
    Surface(Modifier.fillMaxSize(), color = Color(0xFF16171B), contentColor = Color.White) {
        Column(Modifier.padding(28.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(YabGlyphs.Lock, null, Modifier.size(52.dp), tint = Color(0xFF92939A))
            Text("Private is Locked", Modifier.padding(top = 20.dp), style = MaterialTheme.typography.headlineSmall)
            Button(onClick = onUnlock, modifier = Modifier.padding(top = 16.dp)) { Text("Unlock") }
            TextButton(onClick = onLeave) { Text("Return to Your Tabs", color = Color.White.copy(alpha = 0.75f)) }
        }
    }
}

@Composable
private fun PageTile(title: String, icon: ImageVector, enabled: Boolean = true, action: () -> Unit) {
    Column(Modifier.alpha(if (enabled) 1f else 0.38f).clip(RoundedCornerShape(16.dp)).clickable(enabled = enabled, onClick = action).padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, Modifier.size(24.dp)); Text(title, Modifier.padding(top = 6.dp), fontSize = 12.sp)
    }
}

@Composable
internal fun ActionRow(title: String, icon: ImageVector? = null, subtitle: String? = null, trailing: String? = null, danger: Boolean = false, action: (() -> Unit)? = null) {
    val ink = LocalBrowserRowInk.current
    val color = if (danger) MaterialTheme.colorScheme.error else ink ?: MaterialTheme.colorScheme.onSurface
    val secondary = ink?.copy(alpha = 0.65f) ?: MaterialTheme.colorScheme.onSurfaceVariant
    Row(Modifier.fillMaxWidth().then(if (action != null) Modifier.clickable(onClick = action) else Modifier).padding(horizontal = 12.dp, vertical = 13.dp).heightIn(min = 26.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, Modifier.size(22.dp), tint = color); Spacer(Modifier.width(14.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, color = color, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) Text(subtitle, color = secondary, style = MaterialTheme.typography.bodySmall)
        }
        if (trailing != null) Text(trailing, Modifier.padding(start = 10.dp), color = secondary, style = MaterialTheme.typography.bodyMedium)
        if (action != null) Icon(YabGlyphs.ChevronRight, null, Modifier.size(18.dp), tint = secondary)
    }
}

internal fun copyLink(context: Context, url: String) {
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Link", url))
}

internal fun shareLink(context: Context, url: String) {
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, url) }, null))
}

@Composable
internal fun PanelHeader(title: String, close: () -> Unit, back: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        if (back != null) IconButton(onClick = back) { Icon(YabGlyphs.ChevronLeft, "Back") }
        Text(title, Modifier.weight(1f).padding(start = if (back == null) 16.dp else 0.dp), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        IconButton(onClick = close) { Icon(YabGlyphs.CrossMedium, "Close") }
    }
}

@Composable
internal fun FullPanel(title: String, close: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.22f)).padding(8.dp).statusBarsPadding().navigationBarsPadding()) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxSize()) {
            Column { if (title.isNotEmpty()) PanelHeader(title, close); content() }
        }
    }
}


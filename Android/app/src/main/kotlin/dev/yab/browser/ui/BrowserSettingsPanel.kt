package dev.yab.browser.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import dev.yab.browser.model.*
import java.util.Locale

/** Replaces only a real row control when its original route authority changes. */
private val LocalSettingsRowActionOwner = staticCompositionLocalOf<(() -> Boolean)?> { null }

@Composable
internal fun BrowserSettingsPanel(
    state: BrowserState,
    controller: BrowserController,
    onSync: (() -> Unit)?,
    onExtensions: (() -> Unit)?,
    onSystemSettings: (() -> Unit)?,
    onCredentialsSettings: (() -> Unit)?,
    onClearData: () -> Unit,
    blocksAdsEnabled: Boolean? = null,
    onBlocksAdsChange: ((Boolean) -> Unit)? = null,
    blockingStatus: String? = null,
    chromiumForkPresent: Boolean? = null,
    reports: dev.yab.reports.ReportsController? = null,
    aiSettings: (@Composable (actionCurrent: () -> Boolean) -> Unit)? = null,
    host: BrowserSettingsHostState,
    lease: SettingsPresentationLease,
) {
    val frame by host.presentation.frame.collectAsState()
    val context = LocalContext.current
    val iconTitle = remember(frame.generation, frame.canBack) {
        runCatching { dev.yab.android.AppIcons(context).selected().singleOrNull()?.icon?.title }.getOrNull()
    }
    var query by remember { mutableStateOf("") }
    var searchSpot by remember { mutableStateOf<String?>(null) }
    val rootScroll = rememberScrollState()
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val reportState = reports?.state?.collectAsState()?.value
    val updater = dev.yab.update.AppUpdater.get(androidx.compose.ui.platform.LocalContext.current)
    val updateState by updater.state.collectAsState()
    val availability = SettingsSearchAvailability(sync = onSync != null, extensions = onExtensions != null,
        systemSettings = onSystemSettings != null, credentialsSettings = onCredentialsSettings != null,
        feedback = reports != null, reports = reportState?.available == true, ai = aiSettings != null,
        updates = updater.endpoint != null, chromium = chromiumForkPresent == true)
    val pages = SettingsSearchIndex.pages(state.settings, state.spaces, availability,
        emptyList(), dev.yab.android.BuildConfig.VERSION_NAME, dev.yab.android.BuildConfig.VERSION_CODE.toString())
    val capturedGeneration = frame.generation
    val top = frame.routes.lastOrNull { it.interactive }
    fun sheetCurrent() = controller.settingsActionsCurrent(lease) && host.lease === lease &&
        host.presentation.frame.value.generation == capturedGeneration && top?.let { host.presentation.routeCurrent(it.id) } == true
    fun close() { if (sheetCurrent()) host.close(controller) }
    val density = LocalDensity.current
    val viewport = LocalSettingsViewport.current
    var sheetHeight by remember { mutableDoubleStateOf(1.0) }
    var headerCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val headerCurrent by rememberUpdatedState { sheetCurrent() }
    val headerClose by rememberUpdatedState({ if (controller.settingsActionsCurrent(lease) && host.lease === lease) controller.dismissSettings(lease) })
    val statusTop = with(density) { WindowInsets.statusBars.getTop(this).toDp() }
    MaterialTheme(colorScheme = settingsColors()) {
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).onSizeChanged { sheetHeight = it.height / density.density.toDouble() }
        .then(if (viewport?.frame?.sheet?.tablet == true) Modifier.padding(bottom = (viewport.keyboardOverlapPx / density.density).dp)
            else Modifier.statusBarsPadding().padding(top = (60.dp - statusTop).coerceAtLeast(0.dp)).navigationBarsPadding().imePadding())) {
        Box(Modifier.fillMaxWidth().height(if (viewport?.frame?.sheet?.tablet == true) 56.dp else 54.dp).testTag("settings.header")
            .onGloballyPositioned { headerCoordinates = it }
            .settingsHeaderPull(host, sheetHeight, viewport?.frame, { headerCoordinates }, { headerCurrent() }, { headerClose() })) {
            Box(Modifier.fillMaxSize()) {
                Surface(Modifier.align(Alignment.CenterStart).padding(start = 12.dp).size(44.dp), shape = CircleShape,
                    color = MaterialTheme.colorScheme.surface, shadowElevation = 6.dp) {
                    IconButton(onClick = { if (sheetCurrent()) { if (frame.canBack) host.back() else close() } }) {
                        Box(Modifier.size(44.dp).semantics { contentDescription = if (frame.canBack) "Back" else "Close" }, contentAlignment = Alignment.Center) {
                            val page = frame.backButton.toFloat()
                            Icon(YabGlyphs.CrossMedium, null, Modifier.size(22.dp).graphicsLayer {
                                alpha = 1 - page; rotationZ = -90 * page; scaleX = 1 - .3f * page; scaleY = scaleX
                            })
                            Icon(YabGlyphs.ChevronLeft, null, Modifier.size(22.dp).graphicsLayer {
                                alpha = page; rotationZ = 90 * (1 - page); scaleX = .7f + .3f * page; scaleY = scaleX
                            })
                        }
                    }
                }
                if (!frame.canBack || frame.title == "App Icon") Text(frame.title, Modifier.align(Alignment.Center), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Box(Modifier.weight(1f)) { SettingsRouteDeck(host, lease, controller) { entry, actionCurrent ->
            val route = entry.title
            fun act(block: () -> Unit): () -> Unit = { if (actionCurrent()) block() }
            fun <T> change(block: (T) -> Unit): (T) -> Unit = { if (actionCurrent()) block(it) }
            fun open(match: SettingsSearchMatch) {
                if (!actionCurrent()) return
                keyboard?.hide(); focus.clearFocus()
                searchSpot = match.row?.spaceId?.let { SettingsRowId.space(it) } ?: match.row?.id
                when (match.page) {
                    SettingsPage.HISTORY -> controller.show(BrowserSurface.HISTORY)
                    SettingsPage.SYNC -> onSync?.invoke()
                    SettingsPage.EXTENSIONS -> onExtensions?.invoke()
                    else -> host.push(when (match.row?.id) {
                        SettingsRowId.AUTO_CLEAR, SettingsRowId.MAC_TABS -> "Today"
                        SettingsRowId.TAB_LOCK, SettingsRowId.PRIVATE_LOCK -> "Private Tabs"
                        "ai.aboutPage" -> "About a page"
                        "ai.agent" -> "Agent"
                        "ai.model" -> "On-device AI"
                        else -> match.page.title
                    })
                }
            }
            val destination = entry.destination
            if (destination is SettingsDestination.Space) {
                BrowserSettingsSpacePage(destination.id, state, controller, host, lease, actionCurrent)
            } else if (destination is SettingsDestination.Editor) {
                BrowserSettingsSpaceEditor(destination, entry, state, controller, host, lease, actionCurrent)
            } else {
            CompositionLocalProvider(LocalSettingsSearchSpot provides if (entry.interactive) searchSpot else null,
                LocalSettingsRowActionOwner provides actionCurrent) {
            Column(Modifier.fillMaxSize()) {
            if (route == "Settings") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 44.dp)
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = .84f), CircleShape).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(YabGlyphs.MagnifyingGlass, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    BasicTextField(query, change<String> { query = it }, Modifier.weight(1f).padding(vertical = 10.dp).testTag("settings.search")
                        .semantics { contentDescription = "Search Settings" }, singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary), decorationBox = { editor ->
                            Box { if (query.isEmpty()) Text("Search", fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant); editor() }
                        })
                    if (query.isNotEmpty()) IconButton(onClick = act { query = "" }, Modifier.size(28.dp)) { Icon(YabGlyphs.CircleX, "Clear search", Modifier.size(18.dp)) }
                }
                Column(Modifier.weight(1f).verticalScroll(rootScroll).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 40.dp),
                    verticalArrangement = Arrangement.spacedBy(22.dp)) {
                    val matches = if (query.isBlank()) {
                        val order = listOf(SettingsPage.GENERAL, SettingsPage.SEARCH, SettingsPage.APPEARANCE, SettingsPage.APP_ICON, SettingsPage.ENGINE, SettingsPage.TABS, SettingsPage.SYNC,
                            SettingsPage.AI, SettingsPage.SPACES, SettingsPage.HISTORY, SettingsPage.PASSWORDS, SettingsPage.AUTOFILL, SettingsPage.EXTENSIONS, SettingsPage.PRIVACY,
                            SettingsPage.ABOUT, SettingsPage.FEEDBACK)
                        order.filter { page -> pages.any { it.page == page } }.map { SettingsSearchMatch(it) }
                    } else SettingsSearchIndex.matches(query, pages)
                    if (matches.isEmpty()) {
                        Text("No settings found", Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(12.dp)
                            .testTag("settings.search.empty").semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        val groups = if (query.isNotBlank()) listOf(matches) else listOf(
                            matches.filter { it.page in setOf(SettingsPage.GENERAL, SettingsPage.SEARCH, SettingsPage.APPEARANCE, SettingsPage.APP_ICON, SettingsPage.ENGINE, SettingsPage.TABS, SettingsPage.SYNC) },
                            matches.filter { it.page in setOf(SettingsPage.AI, SettingsPage.SPACES, SettingsPage.HISTORY, SettingsPage.PASSWORDS, SettingsPage.AUTOFILL, SettingsPage.EXTENSIONS, SettingsPage.PRIVACY) },
                            matches.filter { it.page in setOf(SettingsPage.ABOUT, SettingsPage.FEEDBACK) })
                        groups.filter { it.isNotEmpty() }.forEach { group -> SettingsGroup {
                            group.forEach { match -> key(match.id) {
                                val subtitle = match.row?.title ?: when (match.page) {
                                    SettingsPage.APPEARANCE -> state.settings.appearance.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase)
                                    SettingsPage.APP_ICON -> iconTitle
                                    SettingsPage.ENGINE -> state.settings.engineKind.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase)
                                    SettingsPage.SYNC -> null
                                    else -> null
                                }
                                Box(Modifier.testTag("settings.search.result.${match.id}")) {
                                    SettingsActionRow(match.page.title, subtitle = subtitle, art = true, action = { open(match) })
                                }
                            } }
                        } }
                    }
                }
            } else if (route == "App Icon") {
                IndexedSetting(searchSpot?.takeIf { it.startsWith("appIcon.") } ?: "appIcon") { dev.yab.android.AppIconSettings(actionCurrent) }
            } else key(route) { Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                SettingsHero(route)
                when (route) {
                    "General" -> {
                        SettingsGroup {
                            IndexedSetting(SettingsRowId.DEFAULT_BROWSER) {
                                SettingsDefaultBrowserRow(onSystemSettings?.let { callback -> act { callback() } })
                            }
                            IndexedSetting(SettingsRowId.NOTIFICATIONS) {
                                Box {
                                    SettingsNotificationRow(actionCurrent) { controller.message("Notification settings aren't available.") }
                                    HorizontalDivider(Modifier.align(Alignment.TopStart).padding(start = 46.dp), thickness = .5.dp,
                                        color = if (MaterialTheme.colorScheme.background.luminance() < .2f) Color(0xFF545458).copy(alpha = .45f)
                                            else Color(0xFF3C3C43).copy(alpha = .16f))
                                }
                            }
                        }
                        SettingsSection("Swipe right anywhere on a page to go back, left to go forward. Off, use the screen's system Back gesture.") {
                            IndexedSetting(SettingsRowId.SWIPE_ANYWHERE) {
                                ToggleRow("Swipe from Anywhere", state.settings.swipeAnywhere, YabGlyphs.ChevronLeft) {
                                    if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(swipeAnywhere = it) }
                                }
                            }
                        }
                        SettingsSection("Yab opens ready to type. A page you were just reading stays in front.") {
                            IndexedSetting(SettingsRowId.LAUNCH_KEYBOARD) {
                                ToggleRow("Open Keyboard at Launch", state.settings.openKeyboardAtLaunch, YabGlyphs.MagnifyingGlass) {
                                    if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(openKeyboardAtLaunch = it) }
                                }
                            }
                        }
                    }
                    "Search" -> {
                        SettingsSection("Type an address to open a page, or words to search. This choice is kept on this device.") {
                            SearchEngine.entries.filter { it != SearchEngine.CUSTOM || BrowserAddress.validTemplate(state.settings.customSearchTemplate) }.forEach { engine ->
                                IndexedSetting(SettingsRowId.engine(engine)) { ChoiceRow(engine.title, state.settings.searchEngine == engine) { if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(searchEngine = engine) } } }
                            }
                        }
                    }
                    "Engine" -> {
                        SettingsSection("A new choice applies on the next app start.") {
                            IndexedSetting(SettingsRowId.ENGINE) { Column {
                                BrowserEngineKind.entries.forEach { kind ->
                                    ChoiceRow(kind.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase), state.settings.engineKind == kind) {
                                        if (actionCurrent()) dev.yab.chromium.ChromeEngineSelection(chromiumForkPresent == true)
                                            .choose(state.settings.engineKind, kind)?.let { chosen ->
                                                controller.updateSettings(lease) { current -> current.copy(engineKind = chosen) }
                                            }
                                    }
                                }
                            } }
                        }
                    }
                    "Appearance" -> {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            SettingsSection("System follows your device, light by day and dark at night if it is set so.") {
                                BrowserAppearance.entries.forEach { look -> IndexedSetting(SettingsRowId.appearance(look)) {
                                    ChoiceRow(look.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase), state.settings.appearance == look) {
                                        if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(appearance = look) }
                                    }
                                } }
                            }
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("WEBSITES", Modifier.padding(start = 8.dp), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            SettingsSection("Light websites become dark when Yab is dark. Websites with their own dark look keep it.") {
                                IndexedSetting(SettingsRowId.DARKEN_WEBSITES) { ToggleRow("Darken Websites", state.settings.darkenWebsites, YabGlyphs.Moon) {
                                    if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(darkenWebsites = it) }
                                } }
                            }
                        }
                    }
                    "AI", "About a page", "Everything else", "Agent", "On-device AI" -> aiSettings?.let { content ->
                        CompositionLocalProvider(dev.yab.agent.LocalAiSettingsNavigation provides dev.yab.agent.AiSettingsNavigation(route, { title -> if (actionCurrent()) host.push(title) })) {
                            IndexedSetting("ai") { content(actionCurrent) }
                        }
                    }
                    "Tabs" -> {
                        SettingsSection("Pins, kept tabs, folders and Today belong to their space.") {
                            IndexedSetting(SettingsRowId.TODAY) { SettingsActionRow("Today", YabGlyphs.SquareBehindSquare1, trailing = "This device's own", action = act { host.push("Today") }) }
                            IndexedSetting(SettingsRowId.TAB_LOCK) { SettingsActionRow("Private Tabs", YabGlyphs.Incognito,
                                trailing = "Not kept", action = act { host.push("Private Tabs") }) }
                        }
                    }
                    "Today" -> {
                        SettingsSection("Automatic Clear removes only inactive tabs created on this device with verified safe pages. The page in front, pins, kept tabs, drafts, media, tasks, shared and unverified pages stay. Undo is available for 6 seconds.") {
                            SettingsActionRow("Today", YabGlyphs.SquareBehindSquare1, trailing = "This device's own")
                            IndexedSetting(SettingsRowId.AUTO_CLEAR) { ToggleRow("Clear after 12 hours", state.settings.autoClearToday, YabGlyphs.Broom) { if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(autoClearToday = it) } } }
                        }
                        SettingsSection("See what is open on your Mac and open it here. Your Today stays this device's own.") { IndexedSetting(SettingsRowId.MAC_TABS) { ToggleRow("Your Mac's Tabs", state.settings.macTabs, YabGlyphs.Macbook) { if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(macTabs = it) } } } }
                    }
                    "Private Tabs" -> {
                        SettingsSection("Private tabs stay in memory on this device, with no history or sync.") {
                            SettingsActionRow("Private Tabs", YabGlyphs.Incognito, trailing = "Not kept")
                        }
                    }
                    "Spaces" -> {
                        SettingsGroup { state.spaces.filterNot(BrowserSpace::isPrivate).forEach { space ->
                            IndexedSetting(SettingsRowId.space(space.id)) {
                                SettingsActionRow(space.name, YabGlyphs.Window, subtitle = "${space.tabs.size} tabs" +
                                    if (state.selectedSpaceId == space.id) " · on screen" else "", trailing = SpaceSymbols.emoji(space.emoji),
                                    action = act { host.push(SettingsDestination.Space(space.id)) })
                            }
                        } }
                        IndexedSetting(SettingsRowId.ADD_SPACE) { TextButton(onClick = act { controller.createSettingsSpace(lease) }, Modifier.fillMaxWidth().heightIn(min = 44.dp)
                            .testTag("settings.spaces.add")) { Icon(YabGlyphs.PlusMedium, null, Modifier.size(16.dp)); Text("Add Space", Modifier.padding(start = 8.dp), fontSize = 17.sp) } }
                    }
                    "Privacy" -> {
                        blockingStatus?.let { SettingsNote(it) }
                        SettingsSection("Pages you open on this device go to History on your Mac for two weeks. Private tabs never do. Turning this off keeps your local history and stops sending new visits.") {
                            IndexedSetting(SettingsRowId.BLOCK_ADS) { ToggleRow("Block ads and trackers", blocksAdsEnabled ?: state.settings.blocksAds) {
                                if (actionCurrent()) {
                                    if (onBlocksAdsChange != null) onBlocksAdsChange(it) else controller.updateSettings(lease) { current -> current.copy(blocksAds = it) }
                                }
                            } }
                            IndexedSetting(SettingsRowId.SYNC_HISTORY) { ToggleRow("Sync History", state.settings.syncHistory) { if (actionCurrent()) controller.updateSettings(lease) { current -> current.copy(syncHistory = it) } } }
                        }
                        SettingsSection("Clears browsing history, cookies and website data in shared and separate sign-ins. Websites sign you out. Your tabs stay.") { IndexedSetting(SettingsRowId.CLEAR_DATA) { SettingsActionRow("Clear History and Website Data", YabGlyphs.Broom, action = act(onClearData)) } }
                    }
                    "Passwords" -> {
                        SettingsSection("Use your configured password manager on supported sign-in fields. Passwords are not stored in a Yab vault.") {
                            IndexedSetting(SettingsRowId.PASSWORD_PROVIDER) { SettingsActionRow("Passwords and Passkeys", YabGlyphs.Key1, subtitle = "Managed by Android") }
                            if (onCredentialsSettings != null) IndexedSetting(SettingsRowId.PASSWORD_SETTINGS) { SettingsActionRow("Open Android Settings", action = act { onCredentialsSettings() }) }
                        }
                    }
                    "Autofill" -> {
                        SettingsSection("Use your configured Android provider on supported forms. Yab does not keep a separate profile for filling whole forms.") {
                            IndexedSetting(SettingsRowId.AUTOFILL_PROVIDER) { SettingsActionRow("Autofill", YabGlyphs.CreditCard1, subtitle = "Managed by Android") }
                            if (onCredentialsSettings != null) IndexedSetting(SettingsRowId.AUTOFILL_SETTINGS) { SettingsActionRow("Open Android Settings", action = act { onCredentialsSettings() }) }
                        }
                    }
                    "About" -> {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            SettingsGroup { IndexedSetting(SettingsRowId.VERSION) {
                                SettingsActionRow("Yab", YabGlyphs.Globe, trailing = "${dev.yab.android.BuildConfig.VERSION_NAME} (${dev.yab.android.BuildConfig.VERSION_CODE})")
                            }
                            if (updater.endpoint != null) IndexedSetting(SettingsRowId.CHECK_UPDATES) {
                                SettingsActionRow("Check for Updates", trailing = updateState.words, action = act { updater.checkNow() })
                            } }
                            IndexedSetting(SettingsRowId.ABOUT_BROWSER) { SettingsNote("yet another browser. Tabs, chats and tasks with Yab on your Mac.") }
                        }
                        reports?.let { IndexedSetting(searchSpot?.takeIf { it == SettingsRowId.CRASHES || it == SettingsRowId.ACTIVITY } ?: "about.reports") { dev.yab.reports.ReportPreferences(it, actionCurrent) } }
                    }
                    "Send Feedback" -> reports?.let { IndexedSetting(searchSpot?.takeIf { it.startsWith("feedback.") } ?: "feedback") { dev.yab.reports.FeedbackForm(it, actionCurrent) } }
                }
                Spacer(Modifier.height(16.dp))
            } }
            }
            }
            }

        } }
    }
}
}

private val LocalSettingsSearchSpot = staticCompositionLocalOf<String?> { null }

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun IndexedSetting(id: String, content: @Composable () -> Unit) {
    val spot = LocalSettingsSearchSpot.current
    val requester = remember { BringIntoViewRequester() }
    LaunchedEffect(id, spot) {
        if (spot == id) { withFrameNanos { }; requester.bringIntoView() }
    }
    Box(Modifier.fillMaxWidth().bringIntoViewRequester(requester).testTag("settings.row.$id")) { content() }
}

@Composable
internal fun SettingsGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) { Column(content = content) }
}

@Composable
internal fun SettingsSection(note: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SettingsGroup(content)
        SettingsNote(note)
    }
}

@Composable
internal fun SettingsNote(text: String) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .2f
    Text(text, Modifier.padding(horizontal = 8.dp), fontSize = 13.sp, lineHeight = 18.2.sp,
        letterSpacing = (-.12).sp, color = if (dark) Color(0xFFEBEBF5) else Color(0xFF3C3C43))
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, icon: androidx.compose.ui.graphics.vector.ImageVector? = null, change: (Boolean) -> Unit) {
    val owner = LocalSettingsRowActionOwner.current
    key(owner) {
    Row(Modifier.fillMaxWidth().clickable { change(!checked) }.heightIn(min = 50.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            SettingsRowIcon(icon, MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.width(12.dp))
        }
        Text(title, Modifier.weight(1f), fontSize = 17.sp)
        SettingsSwitch(checked, change)
    }
    }
}

@Composable
private fun ChoiceRow(title: String, selected: Boolean, choose: () -> Unit) = SettingsChoiceRow(title, selected, choose)

@Composable
internal fun SettingsChoiceRow(title: String, selected: Boolean, choose: () -> Unit) {
    val line = MaterialTheme.colorScheme.onSurface.copy(alpha = .12f)
    Row(Modifier.fillMaxWidth().drawBehind { drawLine(line, androidx.compose.ui.geometry.Offset(12.dp.toPx(), size.height),
        androidx.compose.ui.geometry.Offset(size.width, size.height), .5.dp.toPx()) }.clickable(onClick = choose).heightIn(min = 50.dp).padding(horizontal = 12.dp).semantics { this.selected = selected }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontSize = 17.sp); if (selected) Icon(YabGlyphs.Checkmark1Small, "Selected", Modifier.size(18.dp))
    }
}

/** The iPhone's page glyphs (SettingsIndex.glyph), so every page has its own mark. */
private fun settingIcon(title: String) = when (title) {
    SettingsPage.GENERAL.title -> YabGlyphs.SettingsGear1
    SettingsPage.SEARCH.title -> YabGlyphs.MagnifyingGlass
    SettingsPage.APPEARANCE.title -> YabGlyphs.Moon
    SettingsPage.APP_ICON.title -> YabGlyphs.Apps
    SettingsPage.AI.title -> YabGlyphs.Sparkle
    SettingsPage.TABS.title -> YabGlyphs.SquareBehindSquare1
    SettingsPage.SPACES.title -> YabGlyphs.Window
    SettingsPage.HISTORY.title -> YabGlyphs.History
    SettingsPage.PASSWORDS.title -> YabGlyphs.Key1
    SettingsPage.AUTOFILL.title -> YabGlyphs.CreditCard1
    SettingsPage.PRIVACY.title -> YabGlyphs.Lock
    SettingsPage.FEEDBACK.title -> YabGlyphs.ChatBubble7
    SettingsPage.SYNC.title -> YabGlyphs.ArrowRotateClockwise
    SettingsPage.EXTENSIONS.title -> YabGlyphs.Plugin1
    SettingsPage.ABOUT.title -> YabGlyphs.CircleInfo
    else -> YabGlyphs.SettingsGear1
}

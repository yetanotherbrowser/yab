package dev.yab.browser.model

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One owner for selection, temporary surfaces, durable public state and engine commands. */
class BrowserController(
    private val repository: BrowserRepository,
    private val engine: BrowserEngine,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val activityClock: () -> TabActivityClock = { TabActivityClock(now(), System.nanoTime() / 1_000_000, null, TabActivityClock.processIdentity) },
    private val activityRepository: TabActivityRepository = MemoryTabActivityRepository(),
    /** Production has no lock: private is the eyes and the stack, as on the iPhone. */
    private val privateLocks: Boolean = true,
) {
    private val mutableState = MutableStateFlow(BrowserState())
    val state: StateFlow<BrowserState> = mutableState.asStateFlow()
    private val saves = Channel<BrowserSnapshot>(Channel.CONFLATED)
    private var canSave = false
    private val drafts = mutableMapOf<String, String>()
    private val recorded = mutableMapOf<String, String>()
    private data class Removed(val space: String, val index: Int, val tab: BrowserTab,
        val profile: WebsiteProfile, val wasFront: Boolean, val recentIndex: Int?,
        val memory: BrowserPageMemento?, val activity: TabActivity?)
    private data class Undo(val tabs: List<Removed>, val offered: TabActivityClock)
    private val activities = mutableMapOf<String, TabActivity>()
    private val activitySaves = Channel<Map<String, TabActivity>>(Channel.CONFLATED)
    private var undo: Undo? = null
    private var undoTimer: Job? = null
    private var messageTimer: Job? = null
    private var workspaceExpanded = false
        set(value) {
            if (field != value) externalRouteGeneration++
            field = value
        }
    private val mutableWorkspaceWindow = MutableStateFlow(WorkspaceWindowState())
    val workspaceWindow: StateFlow<WorkspaceWindowState> = mutableWorkspaceWindow.asStateFlow()
    private var workspaceMenu: WorkspaceActionLease? = null
    private var tabletPageEntry: TabletPageEntryLease? = null
    private var tabletSidebarPage: TabletSidebarPageLease? = null
    private val sidebarRevision = MutableStateFlow(0L)
    val tabletSidebarRevision: StateFlow<Long> = sidebarRevision.asStateFlow()
    private val toolbarRevision = MutableStateFlow(0L)
    val tabletToolbarRevision: StateFlow<Long> = toolbarRevision.asStateFlow()
    private var localOwnership = 0L
    // External-link followup only: nonfront spaces or layout ABA retire the route.
    private var externalRouteGeneration = 0L
    private val settingsLifetime = MutableStateFlow(SettingsPresentationLifetime())
    val settingsPresentationLifetime: StateFlow<SettingsPresentationLifetime> = settingsLifetime.asStateFlow()
    private val historyLifetime = MutableStateFlow(0L)
    val historyPresentationLifetime: StateFlow<Long> = historyLifetime.asStateFlow()
    private val historyRowSources = HistoryRowSources()
    internal val historyRowPresentationSources get() = historyRowSources.state
    private val settingsSpaceIdentities = mutableMapOf<String, Any>()
    private val mutableSettingsSpaceNavigation = MutableStateFlow<SettingsSpaceNavigation?>(null)
    internal val settingsSpaceNavigation: StateFlow<SettingsSpaceNavigation?> = mutableSettingsSpaceNavigation.asStateFlow()
    private var ordinarySpaceId: String? = null
    private var findGeneration = 0L
    private var pageSwipeGeneration = 0L
    private val mutableHardwareKeyRevision = MutableStateFlow(0L)
    val hardwareKeyRevision: StateFlow<Long> = mutableHardwareKeyRevision.asStateFlow()
    val hardwareKeyGeneration: Long get() = mutableHardwareKeyRevision.value
    private var hardwareKeyWelcomeBoundary = 0L

    init {
        scope.launch {
            for (snapshot in saves) {
                runCatching { repository.save(snapshot) }.onFailure {
                    mutableState.value = mutableState.value.copy(persistenceError = "Your changes couldn't be saved. ${it.message.orEmpty()}")
                }
            }
        }
        scope.launch {
            for (entries in activitySaves) runCatching { activityRepository.save(entries) }
        }
        scope.launch {
            val owner = localOwnership
            val loaded = runCatching { repository.load() }
            val recoveredActivity = runCatching { activityRepository.load() }.getOrDefault(emptyMap())
            currentCoroutineContext().ensureActive()
            if (owner == localOwnership) activities.putAll(recoveredActivity)
            canSave = loaded.isSuccess
            val initial = loaded.getOrNull() ?: emptySnapshot()
            val public = initial.spaces.filterNot(BrowserSpace::isPrivate).map { space ->
                val tabs = space.tabs.filterNot(BrowserTab::isPrivate)
                // Nothing in front stays nothing; a pin or a kept tab never steps forward by itself.
                space.copy(tabs = tabs, currentTabId = space.currentTabId?.takeIf { id -> tabs.any { it.id == id } }
                    ?: tabs.firstOrNull { it.place == TabPlace.TODAY }?.id)
            }.ifEmpty { emptySnapshot().spaces }
            mutableState.value = BrowserState(
                loading = false,
                spaces = public,
                selectedSpaceId = initial.selectedSpaceId.takeIf { id -> public.any { it.id == id } } ?: public.first().id,
                history = initial.history,
                settings = if (privateLocks) initial.settings else initial.settings.copy(lockPrivate = false),
                recency = initial.recency,
                historyForgetting = initial.historyForgetting,
                persistenceError = loaded.exceptionOrNull()?.let { "Your saved profile couldn't be opened. It has been kept intact. ${it.message.orEmpty()}" },
            )
            ordinarySpaceId = mutableState.value.selectedSpaceId
            reconcileLocalState()
            activate()
        }
    }

    private fun emptySnapshot(): BrowserSnapshot {
        val tab = BrowserTab(id = newId(), createdAt = now())
        val space = BrowserSpace(id = PERSONAL_SPACE, name = "Personal", color = 0xFFEEE9E2, tabs = listOf(tab), currentTabId = tab.id)
        return BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)
    }

    private fun update(persist: Boolean = false, continuation: (() -> Boolean)? = null, change: (BrowserState) -> BrowserState) {
        val before = mutableState.value
        var next = change(before)
        if (!privateLocks && next.settings.lockPrivate) next = next.copy(settings = next.settings.copy(lockPrivate = false))
        if (next.surface == BrowserSurface.FIELD && !next.fieldIsNewTab &&
            (next.tab?.id != next.fieldOriginTab || next.space?.id != next.fieldOriginSpace ||
                next.space?.websiteProfile != next.fieldOriginProfile || next.privateContentBlocked)) {
            // Revoke before publishing: an old Private address must not survive into a
            // public/locked Activity frame after selection, Sync or profile changes.
            next = next.copy(surface = BrowserSurface.PAGE, fieldText = "", fieldPrivate = false,
                fieldPagePrivate = false, fieldOriginTab = null, fieldOriginSpace = null, fieldOriginProfile = null)
        }
        val abandonedFind = next.find?.takeUnless { find ->
            next.surface == BrowserSurface.PAGE && !next.privateContentBlocked &&
                next.tab?.id == find.tab && next.tab?.url == find.url && next.space?.websiteProfile == find.profile
        }
        if (abandonedFind != null) { findGeneration++; next = next.copy(find = null) }
        // A return to the same id/URL after another surface/tab is a new gesture lifetime.
        if (historySwipeLease != null && (before.tab?.id != next.tab?.id || before.tab?.url != next.tab?.url ||
            before.tab?.isPrivate != next.tab?.isPrivate || before.selectedSpaceId != next.selectedSpaceId ||
            before.space?.websiteProfile != next.space?.websiteProfile || before.workspace != next.workspace ||
            before.surfaceEpoch != next.surfaceEpoch || next.surface != BrowserSurface.PAGE || next.privateContentBlocked ||
            next.loading || next.page.loading || next.find != null)) historySwipeLease = null
        privateUnlockLease?.let { if (!privateUnlockStateCurrent(it, next)) privateUnlockLease = null }
        fieldPrivateUnlockLease?.let { if (!fieldPrivateUnlockStateCurrent(it, next)) fieldPrivateUnlockLease = null }
        if (before.settings.lockPrivate != next.settings.lockPrivate) { fieldPrivateUnlockLease = null; privateUnlockLease = null }
        if (before.privateContentBlocked != next.privateContentBlocked)
            settingsLifetime.value = settingsLifetime.value.copy(generation = settingsLifetime.value.generation + 1, privateBoundary = settingsLifetime.value.privateBoundary + 1)
        // Invalidate before publishing. A same-turn profile/front/surface ABA may be
        // conflated by StateFlow, but no old History callback may become current again.
        if (before.loading != next.loading || before.surface != next.surface || before.surfaceEpoch != next.surfaceEpoch ||
            before.selectedSpaceId != next.selectedSpaceId || before.tab?.id != next.tab?.id ||
            before.tab?.url != next.tab?.url || before.tab?.isPrivate != next.tab?.isPrivate || before.space?.websiteProfile != next.space?.websiteProfile ||
            ((before.surface == BrowserSurface.FIELD || next.surface == BrowserSurface.FIELD) && before.fieldIsPrivate != next.fieldIsPrivate))
            historyLifetime.value += 1
        historyRowSources.reconcile(before.history, next.history)
        // Typed toolbar commands cannot change role after an unrendered page-state ABA.
        // This counter only revokes; original PAGE/native/window admission is separate.
        if (before.page.loading != next.page.loading || before.page.readerEnabled != next.page.readerEnabled ||
            before.page.canGoBack != next.page.canGoBack || before.page.canGoForward != next.page.canGoForward)
            toolbarRevision.value += 1
        // This selected public-space projection includes nonfront rows/folders and metadata.
        // Revoke before publication, so same-turn remove/readd or value ABA cannot revive
        // an old sidebar command. Unrelated spaces/history/page progress do not retire it.
        if (before.space?.takeUnless { it.isPrivate } != next.space?.takeUnless { it.isPrivate }) {
            sidebarRevision.value += 1
            tabletSidebarPage = null
        }
        // Revoke before StateFlow can conflate a tab/profile/Field/order ABA. Progress,
        // titles and ordinary Field typing do not replace a rendered keyboard owner.
        if (before.settings.welcomed != next.settings.welcomed) hardwareKeyWelcomeBoundary++
        if (hardwareKeyFactsChanged(before, next)) mutableHardwareKeyRevision.value += 1
        workspaceMenu?.let { held -> if (!workspaceEntryStateCurrent(held.entry, next) ||
            held.target?.let { target -> next.space?.tabs?.firstOrNull { it.id == target.id } != target } == true) workspaceMenu = null }
        tabletPageEntry?.let { if (!tabletPageEntryStateCurrent(it, next)) tabletPageEntry = null }
        tabletSidebarPage?.let { if (!tabletSidebarPageStateCurrent(it, next)) tabletSidebarPage = null }
        settingsSpaceIdentities.keys.removeAll { id -> next.spaces.none { it.id == id && !it.isPrivate } }
        if (before.spaces != next.spaces) externalRouteGeneration++
        mutableState.value = next
        if (continuation != null && !continuation()) return
        abandonedFind?.let { engine.clearFind(it.tab) }
        if (continuation != null && !continuation()) return
        if (before.spaces != mutableState.value.spaces) reconcileLocalState()
        if (continuation != null && !continuation()) return
        if (persist) persist()
    }

    private fun reconcileLocalState() {
        val spaces = mutableState.value.spaces
        activities.keys.toList().forEach { id ->
            val space = spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } }
            val tab = space?.tabs?.firstOrNull { it.id == id }
            val seen = activities[id]
            if (space == null || tab == null || seen == null || seen.space != space.id || seen.profile != space.websiteProfile.id || seen.url != tab.url || seen.activityAt != tab.lastActiveAt) activities.remove(id)
        }
        engine.reconcileTabs(spaces)
    }

    private fun observeActivity(id: String) {
        val space = mutableState.value.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        val tab = space.tabs.first { it.id == id }
        activities[id] = TabActivity(space.id, space.websiteProfile.id, tab.url, activityClock(), tab.lastActiveAt)
    }

    private fun persist() {
        val current = mutableState.value
        if (!canSave || current.loading) return
        publicSnapshot()?.let { saves.trySend(it) }
        val ids = current.spaces.filterNot(BrowserSpace::isPrivate).flatMap { it.tabs.filterNot(BrowserTab::isPrivate) }.mapTo(mutableSetOf(), BrowserTab::id)
        activitySaves.trySend(activities.filterKeys(ids::contains))
    }

    /** This is the same filtered boundary used for disk and the encrypted sync binding. */
    fun publicSnapshot(): BrowserSnapshot? {
        val current = mutableState.value
        if (current.loading) return null
        val public = current.spaces.filterNot(BrowserSpace::isPrivate).map { it.copy(tabs = it.tabs.filterNot(BrowserTab::isPrivate)) }
        if (public.isEmpty()) return null
        val ids = public.flatMap { it.tabs }.mapTo(mutableSetOf(), BrowserTab::id)
        return BrowserSnapshot(
            spaces = public,
            selectedSpaceId = current.selectedSpaceId.takeIf { id -> public.any { it.id == id } }
                ?: ordinarySpaceId?.takeIf { id -> public.any { it.id == id } } ?: public.first().id,
            history = current.history.filter { it.syncedKey == null },
            settings = current.settings,
            recency = current.recency.filterKeys { key -> public.any { it.id == key } }.mapValues { (_, recent) -> recent.filter(ids::contains) },
            historyForgetting = current.historyForgetting,
        )
    }

    /** Only public data is adopted; native private pages and this device's selection survive. */
    fun applySyncedSnapshot(snapshot: BrowserSnapshot) {
        val current = mutableState.value
        if (current.loading || snapshot.schema != 1) return
        if (undo?.tabs?.any { saved ->
            val owner = snapshot.spaces.firstOrNull { it.id == saved.space }
            !saved.profile.isPrivate && (owner == null || owner.websiteProfile != saved.profile || owner.tabs.any { it.id == saved.tab.id })
        } == true) invalidateUndo()
        val privateSpaces = current.spaces.filter(BrowserSpace::isPrivate)
        val privateIds = privateSpaces.mapTo(mutableSetOf(), BrowserSpace::id)
        val seenTabs = privateSpaces.flatMap { it.tabs }.mapTo(mutableSetOf(), BrowserTab::id)
        val public = snapshot.spaces.filter { !it.isPrivate && it.id !in privateIds }.distinctBy(BrowserSpace::id).map { incoming ->
            val tabs = incoming.tabs.filter { !it.isPrivate && seenTabs.add(it.id) }
            val old = current.spaces.firstOrNull { it.id == incoming.id }
            // Nothing in front keeps showing nothing: a tab a Mac opened waits in the stack.
            val selection = old?.currentTabId?.takeIf { id -> tabs.any { it.id == id } }
                ?: incoming.currentTabId?.takeIf { id -> tabs.any { it.id == id } }
                ?: if (old != null && old.currentTabId == null) null else tabs.firstOrNull { it.place == TabPlace.TODAY }?.id
            incoming.copy(tabs = tabs, currentTabId = selection)
        }
        if (public.isEmpty()) return
        val next = public + privateSpaces
        val valid = next.flatMap { it.tabs }.mapTo(mutableSetOf(), BrowserTab::id)
        val oldTabs = current.spaces.flatMap { space -> space.tabs.map { it.id to space.websiteProfile } }.toMap()
        val nextProfiles = next.flatMap { space -> space.tabs.map { it.id to space.websiteProfile } }.toMap()
        oldTabs.forEach { (id, profile) -> if (id !in valid || nextProfiles[id] != profile) engine.close(id) }
        val selected = current.selectedSpaceId.takeIf { id -> next.any { it.id == id } }
            ?: snapshot.selectedSpaceId.takeIf { id -> public.any { it.id == id } } ?: public.first().id
        update(persist = true) { it.copy(
            spaces = next, selectedSpaceId = selected, history = snapshot.history, settings = snapshot.settings, historyForgetting = snapshot.historyForgetting,
            pageStates = it.pageStates.filterKeys { id -> id in valid && oldTabs[id] == nextProfiles[id] },
            recency = snapshot.recency + it.recency.filterKeys { key -> privateSpaces.any { it.id == key } },
            workspace = it.workspace?.takeIf { pair -> next.firstOrNull { space -> space.id == selected && !space.isPrivate }?.let { space ->
                space.tabs.any { tab -> tab.id == pair.first } && space.tabs.any { tab -> tab.id == pair.second }
            } == true },
            privateLocked = if (snapshot.settings.lockPrivate && !it.settings.lockPrivate) true else it.privateLocked,
        ) }
        val tab = mutableState.value.tab
        val before = current.spaces.flatMap { it.tabs }.firstOrNull { it.id == tab?.id }
        if (tab != null && before?.url != tab.url && !mutableState.value.privateContentBlocked) {
            mutableState.value.space?.let {
                engine.activate(tab, it.websiteProfile)
                engine.navigate(tab, tab.url, it.websiteProfile)
            }
        } else activate()
        val updated = mutableState.value
        updated.workspace?.companion?.let { id ->
            val companion = updated.space?.tabs?.firstOrNull { it.id == id }
            val previous = current.spaces.flatMap { it.tabs }.firstOrNull { it.id == id }
            if (companion != null && companion.url != previous?.url && !updated.privateContentBlocked) {
                updated.space?.let { engine.navigate(companion, companion.url, it.websiteProfile) }
            }
        }
    }

    private fun editSpace(id: String, change: (BrowserSpace) -> BrowserSpace) {
        update(persist = true) { old -> old.copy(spaces = old.spaces.map { if (it.id == id) change(it) else it }) }
    }

    private fun activate() {
        val current = mutableState.value
        val space = current.space ?: return
        if (!space.isPrivate) ordinarySpaceId = space.id
        val tab = current.tab ?: return
        if (current.privateContentBlocked) return
        engine.activate(tab, space.websiteProfile)
    }

    fun message(words: String) {
        messageTimer?.cancel()
        update { it.copy(message = words) }
        messageTimer = scope.launch { delay(3_000); update { it.copy(message = null) } }
    }

    fun show(surface: BrowserSurface) {
        if (mutableState.value.loading) return
        if (surface != BrowserSurface.FIELD) rememberDraft()
        update { it.copy(surface = surface, surfaceEpoch = it.surfaceEpoch + 1, galleryClosing = false, settingsPage = null) }
    }

    fun openAbout() {
        if (mutableState.value.loading) return
        rememberDraft()
        update { it.copy(surface = BrowserSurface.SETTINGS, surfaceEpoch = it.surfaceEpoch + 1,
            galleryClosing = false, settingsPage = SettingsPage.ABOUT) }
    }

    fun dismissSurface() {
        rememberDraft()
        update { it.copy(surface = BrowserSurface.PAGE, galleryClosing = false, settingsPage = null, workspace = it.workspace?.copy(newPage = null)) }
    }

    /** Only the resting spaces generation that finished folding may release its surface. */
    fun dismissSpaces(expectedEpoch: Long): Boolean {
        val current = mutableState.value
        if (current.surface != BrowserSurface.SPACES || current.surfaceEpoch != expectedEpoch || current.privateContentBlocked) return false
        dismissSurface()
        return true
    }

    /** A delayed card animation cannot dismiss a newer gallery or another destination. */
    fun finishGallery(space: String, epoch: Long, chosen: String?): Boolean {
        val current = mutableState.value
        if (current.surface != BrowserSurface.GALLERY || current.surfaceEpoch != epoch || current.selectedSpaceId != space ||
            current.privateContentBlocked || chosen != null && current.tab?.id != chosen) return false
        dismissSurface()
        return true
    }

    /** A removed or navigated return target cannot strand this presentation with disabled cards. */
    fun cancelGalleryReturn(space: String, epoch: Long, chosen: BrowserTab, profile: WebsiteProfile): Boolean {
        val current = mutableState.value
        if (current.loading || current.surface != BrowserSurface.GALLERY || !current.galleryClosing ||
            current.surfaceEpoch != epoch || current.selectedSpaceId != space || current.privateContentBlocked) return false
        val valid = current.space?.websiteProfile == profile && current.tab?.let {
            it.id == chosen.id && it.url == chosen.url && it.isPrivate == chosen.isPrivate
        } == true && current.galleryTabs.any { it.id == chosen.id }
        if (valid) return false
        // A fresh epoch cancels the old UI jobs and reuses only the remaining actual tabs.
        show(BrowserSurface.GALLERY)
        return true
    }

    fun openField(newTab: Boolean = true, privately: Boolean = false, origin: FieldAnchor? = null,
        fromSpaces: Boolean = false, chats: Boolean = false) {
        val current = mutableState.value
        if (!newTab && current.privateContentBlocked) return
        if (current.space?.isPrivate == false) ordinarySpaceId = current.space?.id
        val pagePrivate = !newTab && (current.space?.isPrivate == true || current.tab?.isPrivate == true)
        val eyesPrivate = privately || (newTab && (current.space?.isPrivate == true || current.tab?.isPrivate == true))
        val isPrivate = eyesPrivate || pagePrivate
        val key = (if (newTab) NEW_TAB_DRAFT else current.tab?.id) ?: NEW_TAB_DRAFT
        update { it.copy(
            surface = BrowserSurface.FIELD, surfaceEpoch = it.surfaceEpoch + 1, galleryClosing = false, fieldIsNewTab = newTab, fieldPrivate = eyesPrivate, fieldPagePrivate = pagePrivate,
            fieldOriginTab = current.tab?.id, fieldOriginSpace = current.space?.id, fieldOriginProfile = current.space?.websiteProfile,
            fieldAnchor = origin?.takeIf(FieldAnchor::valid), fieldResting = false, fieldInPlace = fromSpaces,
            fieldFromSpaces = fromSpaces, fieldChats = chats, fieldGoesUp = false,
            fieldShowsAddress = !newTab && (isPrivate || drafts[key].isNullOrEmpty()) && current.tab?.url?.let(BrowserAddress::googleWords) == null,
            fieldText = if (newTab && isPrivate) "" else (if (isPrivate) "" else drafts[key].orEmpty()).ifEmpty { if (newTab) "" else current.tab?.url?.takeUnless { url -> url == "about:blank" }?.let(BrowserAddress::editText).orEmpty() },
        ) }
    }

    fun fieldText(text: String) { update { it.copy(fieldText = text, fieldShowsAddress = false) } }

    fun captureFieldInput(): FieldInputLease? = mutableState.value.takeIf {
        it.surface in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES) && !it.loading && !it.privateContentBlocked
    }?.let { FieldInputLease(localOwnership, it.surfaceEpoch, it.surface, it.selectedSpaceId, it.space?.websiteProfile,
        it.tab?.id, it.tab?.url, it.surface != BrowserSurface.FIELD || it.fieldIsNewTab,
        if (it.surface == BrowserSurface.FIELD) it.fieldIsPrivate else it.space?.isPrivate == true) }

    private fun fieldInputStateCurrent(lease: FieldInputLease, state: BrowserState): Boolean = state.let {
        localOwnership == lease.ownership && !it.loading && !it.privateContentBlocked && it.surface == lease.surface &&
            it.surfaceEpoch == lease.epoch && it.selectedSpaceId == lease.space && it.space?.websiteProfile == lease.profile &&
            it.tab?.id == lease.tab && (lease.newTab || it.tab?.url == lease.url) &&
            (it.surface != BrowserSurface.FIELD || it.fieldIsNewTab) == lease.newTab &&
            (if (it.surface == BrowserSurface.FIELD) it.fieldIsPrivate else it.space?.isPrivate == true) == lease.privately
    }

    fun fieldInputCurrent(lease: FieldInputLease): Boolean = fieldInputStateCurrent(lease, mutableState.value)

    fun fieldText(text: String, lease: FieldInputLease): Boolean {
        if (!fieldInputCurrent(lease)) return false
        // Selection-only callbacks keep the selected-address projection. Compare live text,
        // since multiple IME edits can arrive before the next composition.
        if (mutableState.value.fieldText != text) fieldText(text)
        return true
    }

    fun focusFieldInput(lease: FieldInputLease, origin: FieldAnchor?): Boolean {
        if (!fieldInputCurrent(lease)) return false
        if (lease.surface == BrowserSurface.SPACES) openField(origin = origin)
        else restField(lease.epoch, false)
        return true
    }

    fun captureFieldPresentation(): FieldPresentationLease? = mutableState.value.takeIf {
        it.surface == BrowserSurface.FIELD && !it.loading && !it.privateContentBlocked
    }?.let { FieldPresentationLease(localOwnership, it.surfaceEpoch) }

    fun fieldPresentationCurrent(lease: FieldPresentationLease): Boolean {
        val current = mutableState.value
        if (!fieldPresentationOwned(lease)) return false
        return when (current.surface) {
            BrowserSurface.FIELD, BrowserSurface.PAGE -> current.surfaceEpoch == lease.surfaceEpoch
            // A directly replacing settings sheet fades the old field underneath itself.
            BrowserSurface.SETTINGS -> current.surfaceEpoch == lease.surfaceEpoch + 1
            else -> false
        }
    }

    fun fieldPresentationOwned(lease: FieldPresentationLease): Boolean = mutableState.value.let {
        localOwnership == lease.ownership && !it.loading && !it.privateContentBlocked
    }

    fun captureSettingsPresentation(): SettingsPresentationLease? = mutableState.value.takeIf {
        it.surface == BrowserSurface.SETTINGS && settingsLifetime.value.active && !it.loading
    }?.let { SettingsPresentationLease(localOwnership, settingsLifetime.value.generation, it.surfaceEpoch, settingsLifetime.value.privateBoundary) }

    fun settingsPresentationOwned(lease: SettingsPresentationLease): Boolean = mutableState.value.let {
        lease.ownership == localOwnership && settingsLifetime.value.active && lease.foreground == settingsLifetime.value.generation &&
            lease.privateBoundary == settingsLifetime.value.privateBoundary && !it.loading
    }

    /** Only the sheet's own PAGE exit may keep its old pixels. Other overlays revoke them. */
    fun settingsPresentationCurrent(lease: SettingsPresentationLease): Boolean = mutableState.value.let {
        settingsPresentationOwned(lease) && it.surfaceEpoch == lease.surfaceEpoch &&
            it.surface in setOf(BrowserSurface.SETTINGS, BrowserSurface.PAGE)
    }

    fun settingsActionsCurrent(lease: SettingsPresentationLease): Boolean =
        settingsPresentationCurrent(lease) && mutableState.value.surface == BrowserSurface.SETTINGS

    /** A retained control mutates only its property in the latest preferences. Reject before
     * evaluating caller code, then recheck in case that synchronous transform revoked its source. */
    fun updateSettings(lease: SettingsPresentationLease, transform: (BrowserSettings) -> BrowserSettings): Boolean {
        if (!settingsActionsCurrent(lease)) return false
        val next = transform(mutableState.value.settings)
        if (!settingsActionsCurrent(lease)) return false
        updateSettings(next)
        return true
    }

    fun sameSettingsOwner(a: SettingsPresentationLease, b: SettingsPresentationLease): Boolean =
        a.ownership == b.ownership && a.foreground == b.foreground && settingsPresentationOwned(a) && settingsPresentationOwned(b)

    /** Preference state survives suspension. This predicate grants neither pixels nor actions. */
    fun settingsPresentationRetainable(lease: SettingsPresentationLease): Boolean = mutableState.value.let {
        lease.ownership == localOwnership && lease.privateBoundary == settingsLifetime.value.privateBoundary && !it.loading &&
            it.surface == BrowserSurface.SETTINGS && it.surfaceEpoch == lease.surfaceEpoch
    }

    fun sameSettingsSource(a: SettingsPresentationLease, b: SettingsPresentationLease): Boolean =
        a.ownership == b.ownership && a.surfaceEpoch == b.surfaceEpoch && settingsPresentationRetainable(a) && settingsPresentationRetainable(b)

    fun dismissSettings(lease: SettingsPresentationLease): Boolean {
        if (!settingsActionsCurrent(lease)) return false
        dismissSurface()
        return true
    }

    /** Source Settings Add Space selects the new space but keeps Settings in front. */
    internal fun createSettingsSpace(lease: SettingsPresentationLease): String? {
        if (!settingsActionsCurrent(lease)) return null
        val id = newId()
        val look = BrowserSpaceLook.from(null)
        val made = BrowserSpace(id, "Untitled", emoji = "🌐", color = look.primary, look = look.raw)
        ordinarySpaceId = id
        update(persist = true) { it.copy(spaces = it.spaces + made, selectedSpaceId = id,
            privateLocked = true, workspace = null) }
        // Selecting public from locked Private intentionally revokes the old lease. Only this
        // newly captured owner may carry the one-shot public route into a fresh safe host.
        val fresh = captureSettingsPresentation() ?: return null
        mutableSettingsSpaceNavigation.value = SettingsSpaceNavigation(fresh, id)
        return id
    }

    internal fun settingsSpaceNavigationCurrent(request: SettingsSpaceNavigation, lease: SettingsPresentationLease): Boolean =
        mutableSettingsSpaceNavigation.value === request && settingsActionsCurrent(request.lease) && settingsActionsCurrent(lease) &&
            sameSettingsOwner(request.lease, lease) && request.lease.surfaceEpoch == lease.surfaceEpoch &&
            mutableState.value.spaces.any { it.id == request.id && !it.isPrivate }

    internal fun consumeSettingsSpaceNavigation(request: SettingsSpaceNavigation, lease: SettingsPresentationLease): Boolean {
        if (!settingsSpaceNavigationCurrent(request, lease)) return false
        mutableSettingsSpaceNavigation.value = null
        return true
    }

    internal fun captureSettingsSpaceEdit(lease: SettingsPresentationLease, id: String,
        routeCurrent: () -> Boolean): SettingsSpaceEditLease? {
        if (!settingsActionsCurrent(lease) || !routeCurrent() || !settingsActionsCurrent(lease) || mutableState.value.spaces.none { it.id == id && !it.isPrivate }) return null
        return SettingsSpaceEditLease(lease, id, settingsSpaceIdentities.getOrPut(id) { Any() }, routeCurrent)
    }

    internal fun settingsSpaceEditCurrent(lease: SettingsSpaceEditLease): Boolean =
        settingsActionsCurrent(lease.settings) && settingsSpaceIdentities[lease.id] === lease.identity && lease.routeCurrent() &&
            settingsActionsCurrent(lease.settings) && settingsSpaceIdentities[lease.id] === lease.identity &&
            mutableState.value.spaces.any { it.id == lease.id && !it.isPrivate }

    internal fun commitSettingsSpace(lease: SettingsSpaceEditLease, draft: SettingsSpaceDraft): Boolean {
        if (draft.opened.id != lease.id || draft.opened.isPrivate || !settingsSpaceEditCurrent(lease)) return false
        if (!draft.dirty) return true
        update(persist = true) { current -> current.copy(spaces = current.spaces.map { space ->
            if (space.id != lease.id || space.isPrivate) space else {
                val paint = if (draft.lookChanged) {
                    val latest = BrowserSpaceLook.from(space.look, space.color)
                    // Repair only the required identity when an actual Look edit starts from
                    // a legacy/invalid paint; keep its unknown fields even without Sync.
                    val seeded = kotlinx.serialization.json.JsonObject(space.look.orEmpty() +
                        latest.raw.filterKeys { key -> key == "swatch" || key == "color" })
                    draft.look.mergingChanges(BrowserSpaceLook.from(draft.opened.look, draft.opened.color),
                        BrowserSpaceLook.from(seeded, space.color))
                } else null
                space.copy(name = if (draft.nameChanged) draft.name.trim().takeIf { it.isNotEmpty() } ?: space.name else space.name,
                    emoji = if (draft.emojiChanged && draft.emoji.isNotEmpty()) SpaceSymbols.wire(draft.emoji, space.emoji) else space.emoji,
                    look = paint?.raw ?: space.look, color = paint?.primary ?: space.color)
            }
        }) }
        return true
    }

    fun dismissField(expectedEpoch: Long): Boolean {
        if (mutableState.value.surface != BrowserSurface.FIELD || mutableState.value.surfaceEpoch != expectedEpoch) return false
        dismissSurface()
        return true
    }

    fun restField(expectedEpoch: Long, resting: Boolean = true): Boolean {
        val current = mutableState.value
        if (current.surface != BrowserSurface.FIELD || current.surfaceEpoch != expectedEpoch || current.privateContentBlocked) return false
        update { it.copy(fieldResting = resting) }
        return true
    }

    /** Bind the explicit Paste action to the actual address field's page, not later focus. */
    suspend fun captureFieldAnswerTarget(): FieldAnswerTarget? {
        val source = mutableState.value
        if (source.surface != BrowserSurface.FIELD || source.fieldIsNewTab || source.privateContentBlocked) return null
        val tab = source.tab ?: return null
        val profile = source.space?.websiteProfile ?: return null
        val ownership = localOwnership
        fun current(): Boolean = mutableState.value.let {
            localOwnership == ownership && it.surface == BrowserSurface.FIELD && it.surfaceEpoch == source.surfaceEpoch &&
                !it.fieldIsNewTab && !it.privateContentBlocked && it.tab?.id == tab.id && it.tab?.url == tab.url &&
                it.space?.websiteProfile == profile && it.fieldOriginTab == tab.id && it.fieldOriginProfile == profile
        }
        if (!current()) return null
        val native = engine.captureFieldAnswerTarget(tab.id) ?: return null
        if (!current()) { native.revoke(); return null }
        return object : FieldAnswerTarget {
            private var consumed = false
            override val ready get() = !consumed && current() && native.ready
            override suspend fun insert(value: String): Boolean {
                if (!ready || value.length > 4096) return false
                consumed = true
                return native.insert(value)
            }
            override fun revoke() { consumed = true; native.revoke() }
        }
    }

    private var fieldPrivateUnlockLease: FieldPrivateUnlockLease? = null
    private var privateUnlockLease: PrivateUnlockLease? = null

    fun capturePrivateUnlock(): PrivateUnlockLease? {
        privateUnlockLease = null
        val current = mutableState.value
        if (current.loading || current.surface != BrowserSurface.PAGE || !current.privateContentBlocked) return null
        val space = current.space ?: return null
        return PrivateUnlockLease(localOwnership, current.surfaceEpoch, space.id, space.websiteProfile, current.tab?.id, current.tab?.url)
            .also { privateUnlockLease = it }
    }

    private fun privateUnlockStateCurrent(lease: PrivateUnlockLease, state: BrowserState): Boolean = state.let {
        localOwnership == lease.ownership && !it.loading && it.surface == BrowserSurface.PAGE && it.privateContentBlocked &&
            it.surfaceEpoch == lease.epoch && it.selectedSpaceId == lease.space && it.space?.websiteProfile == lease.profile &&
            it.tab?.id == lease.tab && it.tab?.url == lease.url
    }

    fun privateUnlockCurrent(lease: PrivateUnlockLease): Boolean = privateUnlockLease === lease && privateUnlockStateCurrent(lease, mutableState.value)

    fun completePrivateUnlock(lease: PrivateUnlockLease, allowed: Boolean): Boolean {
        if (!privateUnlockCurrent(lease)) return false
        privateUnlockLease = null
        unlockPrivate(allowed)
        return true
    }

    fun cancelPrivateUnlock(lease: PrivateUnlockLease) { if (privateUnlockLease === lease) privateUnlockLease = null }

    fun captureFieldPrivateUnlock(): FieldPrivateUnlockLease? {
        fieldPrivateUnlockLease = null
        val current = mutableState.value
        if (current.surface != BrowserSurface.FIELD || !current.fieldIsPrivate || !current.settings.lockPrivate || !current.privateLocked) return null
        val input = captureFieldInput() ?: return null
        return FieldPrivateUnlockLease(input).also { fieldPrivateUnlockLease = it }
    }

    private fun fieldPrivateUnlockStateCurrent(lease: FieldPrivateUnlockLease, state: BrowserState): Boolean =
        fieldInputStateCurrent(lease.input, state) && state.let {
            it.surface == BrowserSurface.FIELD && it.fieldIsPrivate && it.settings.lockPrivate && it.privateLocked
        }

    fun fieldPrivateUnlockCurrent(lease: FieldPrivateUnlockLease): Boolean =
        fieldPrivateUnlockLease === lease && fieldPrivateUnlockStateCurrent(lease, mutableState.value)

    /** Consume before any state/engine callback. False authorization is consumed too. */
    fun completeFieldPrivateUnlock(lease: FieldPrivateUnlockLease, allowed: Boolean): Boolean {
        if (!fieldPrivateUnlockCurrent(lease)) return false
        fieldPrivateUnlockLease = null
        if (allowed) unlockPrivate(true)
        return true
    }

    fun cancelFieldPrivateUnlock(lease: FieldPrivateUnlockLease) {
        if (fieldPrivateUnlockLease === lease) fieldPrivateUnlockLease = null
    }

    fun fieldPrivacy(isPrivate: Boolean) {
        fieldPrivateUnlockLease = null
        val current = mutableState.value
        if (current.surface != BrowserSurface.FIELD) return
        if (!current.fieldIsNewTab && current.fieldPagePrivate) return
        val ordinary = if (!isPrivate && current.fieldIsNewTab && current.space?.isPrivate == true) ordinarySpace(current) else null
        update { it.copy(fieldPrivate = isPrivate, fieldText = "", fieldShowsAddress = false, selectedSpaceId = ordinary?.id ?: it.selectedSpaceId) }
        if (ordinary != null) { lockPrivate(); activate() }
    }

    private fun ordinarySpace(state: BrowserState): BrowserSpace? = state.space?.takeUnless(BrowserSpace::isPrivate)
        ?: state.spaces.firstOrNull { !it.isPrivate && it.id == ordinarySpaceId }
        ?: state.spaces.firstOrNull { !it.isPrivate }

    private fun rememberDraft() {
        val current = mutableState.value
        if (current.surface != BrowserSurface.FIELD || current.fieldIsPrivate) return
        val key = if (current.fieldIsNewTab) NEW_TAB_DRAFT else current.tab?.id ?: return
        val original = current.tab?.url?.let { if (current.fieldIsNewTab) it else BrowserAddress.editText(it) }
        val text = current.fieldText.takeUnless { it == original }.orEmpty()
        if (text.isBlank()) drafts.remove(key) else drafts[key] = text
    }

    fun submitField() {
        val current = mutableState.value
        if (!current.fieldIsNewTab && (current.tab?.id != current.fieldOriginTab || current.space?.id != current.fieldOriginSpace ||
            current.space?.websiteProfile != current.fieldOriginProfile || current.privateContentBlocked)) {
            update { it.copy(fieldText = "", surface = BrowserSurface.PAGE) }
            message("The page changed. Open the address again.")
            return
        }
        val url = BrowserAddress.url(current.fieldText, current.settings) ?: return
        (if (current.fieldIsNewTab) NEW_TAB_DRAFT else current.tab?.id)?.let(drafts::remove)
        val besidePlaceholder = current.workspace?.newPage == current.tab?.id && current.workspace?.newPage != null
        // The address standing as it was is the same page again: the sheet falls back to it.
        fieldLeavesUpward(!current.fieldShowsAddress)
        openUrl(url, newTab = (current.fieldIsNewTab || current.fieldPrivate) && !(besidePlaceholder && !current.fieldIsPrivate), privately = current.fieldIsPrivate)
        update { it.copy(fieldText = "", fieldPrivate = false, fieldPagePrivate = false, fieldOriginTab = null, fieldOriginSpace = null,
            fieldOriginProfile = null, surface = BrowserSurface.PAGE, workspace = it.workspace?.copy(newPage = null)) }
    }

    /** What was chosen opens something new. Private keeps falling, its dark on the sheet to the end. */
    fun fieldLeavesUpward(new: Boolean = true) {
        update { it.copy(fieldGoesUp = new && !it.fieldIsPrivate) }
    }

    /** A recent page under the sheet's field: a new tab, the words forgotten. */
    fun openFieldPage(url: String) {
        val current = mutableState.value
        if (current.surface != BrowserSurface.FIELD) return
        (if (current.fieldIsNewTab) NEW_TAB_DRAFT else current.tab?.id)?.let(drafts::remove)
        fieldLeavesUpward()
        openUrl(url, newTab = true, privately = false)
        update { it.copy(fieldText = "", fieldPrivate = false, fieldPagePrivate = false, fieldOriginTab = null, fieldOriginSpace = null,
            fieldOriginProfile = null, surface = BrowserSurface.PAGE, workspace = it.workspace?.copy(newPage = null)) }
    }

    /** The three dots' switch, as Settings' own row. */
    fun showMacTabs(on: Boolean) { updateSettings(mutableState.value.settings.copy(macTabs = on)) }

    fun openUrl(input: String, newTab: Boolean = true, privately: Boolean? = null, openerId: String? = null, background: Boolean = false) {
        val current = mutableState.value
        val url = BrowserAddress.url(input, current.settings) ?: return
        val isPrivate = privately ?: (current.space?.isPrivate == true)
        val target = if (isPrivate) ensurePrivateSpace() else ordinarySpace(current) ?: return
        val front = target.currentTab
        if (!newTab && front?.place == TabPlace.TODAY && front.isPrivate == isPrivate) {
            val tab = front.copy(url = url, title = titleFor(url), lastActiveAt = now())
            editSpace(target.id) { it.copy(tabs = it.tabs.map { old -> if (old.id == tab.id) tab else old }) }
            observeActivity(tab.id); persist()
            if (!mutableState.value.privateContentBlocked) { engine.activate(tab, target.websiteProfile); engine.navigate(tab, url, target.websiteProfile) }
        } else {
            val tab = BrowserTab(id = newId(), url = url, title = titleFor(url), isPrivate = isPrivate, openerId = openerId, createdAt = now())
            editSpace(target.id) {
                val index = if (background && openerId != null) it.tabs.indexOfFirst { tab -> tab.id == openerId }.let { at -> if (at < 0) 0 else at + 1 } else 0
                it.copy(tabs = it.tabs.toMutableList().apply { add(index, tab) }, currentTabId = if (background) it.currentTabId else tab.id)
            }
            observeActivity(tab.id); persist()
            if (!background) {
                selectTab(tab.id, activateEngine = false)
                if (!mutableState.value.privateContentBlocked) { engine.activate(tab, target.websiteProfile); engine.navigate(tab, url, target.websiteProfile) }
            } else message("Opened in Background")
        }
    }

    private fun titleFor(url: String): String = if (url == "about:blank") "New Tab" else runCatching { java.net.URI(url).host?.removePrefix("www.") }.getOrNull() ?: url

    fun openExternalUrl(url: String) {
        val current = mutableState.value
        val address = BrowserAddress.url(url, current.settings) ?: return
        val target = ordinarySpace(current) ?: return
        if (current.spaces.count { it.id == target.id } != 1 || target.isPrivate) return
        val lookup = current.copy(selectedSpaceId = target.id, spaces = current.spaces.map { space ->
            if (space.id == target.id) space.copy(folders = space.folders.map { it.copy(open = true) }) else space
        })
        val order = target.tabs.filter { it.place == TabPlace.PINNED } +
            lookup.pagingOrder().filter { it.place == TabPlace.KEPT } + target.tabs.filter { it.place == TabPlace.TODAY }
        // Exact production navigation address; fixture-only samePage folding is not used.
        val same = order.firstOrNull { !it.isPrivate && !it.isBlank && it.url == address }
        if (same == null) { openUrl(address, newTab = true, privately = false); return }
        if (current.spaces.sumOf { owner -> owner.tabs.count { it.id == same.id } } != 1) return
        val ownership = localOwnership
        val window = mutableWorkspaceWindow.value
        val originalExpanded = workspaceExpanded
        var expected = current
        var navigation = historyLifetime.value
        var lifetime = settingsLifetime.value
        var routeGeneration = externalRouteGeneration
        var hardwareRevision = mutableHardwareKeyRevision.value
        var findRevision = findGeneration
        fun originalRoute(): Boolean {
            val live = mutableState.value
            return localOwnership == ownership && mutableWorkspaceWindow.value == window && workspaceExpanded == originalExpanded &&
                historyLifetime.value == navigation && settingsLifetime.value == lifetime &&
                externalRouteGeneration == routeGeneration && mutableHardwareKeyRevision.value == hardwareRevision && findGeneration == findRevision &&
                live.loading == expected.loading && live.settings == expected.settings && live.spaces == expected.spaces && live.recency == expected.recency &&
                live.selectedSpaceId == expected.selectedSpaceId && live.surface == expected.surface && live.surfaceEpoch == expected.surfaceEpoch &&
                live.workspace == expected.workspace && live.privateLocked == expected.privateLocked && live.find == expected.find &&
                live.fieldIsNewTab == expected.fieldIsNewTab && live.fieldIsPrivate == expected.fieldIsPrivate &&
                live.fieldOriginTab == expected.fieldOriginTab && live.fieldOriginSpace == expected.fieldOriginSpace && live.fieldOriginProfile == expected.fieldOriginProfile &&
                ordinarySpace(live)?.let { it.id == target.id && it.websiteProfile == target.websiteProfile && !it.isPrivate } == true &&
                live.spaces.filter { it.id == target.id }.singleOrNull()?.let { owner ->
                    owner.websiteProfile == target.websiteProfile && owner.tabs.singleOrNull { it.id == same.id }?.let {
                        it.url == same.url && it.place == same.place && it.folderId == same.folderId && !it.isPrivate
                    } == true
                } == true && live.spaces.sumOf { owner -> owner.tabs.count { it.id == same.id } } == 1
        }
        // Predict only our own update before publication/callbacks. These are the same
        // Field/Find normalization and generation predicates used by update above.
        fun predict(raw: BrowserState) {
            val before = expected
            var next = raw
            if (next.surface == BrowserSurface.FIELD && !next.fieldIsNewTab &&
                (next.tab?.id != next.fieldOriginTab || next.space?.id != next.fieldOriginSpace ||
                    next.space?.websiteProfile != next.fieldOriginProfile || next.privateContentBlocked)) {
                next = next.copy(surface = BrowserSurface.PAGE, fieldText = "", fieldPrivate = false,
                    fieldPagePrivate = false, fieldOriginTab = null, fieldOriginSpace = null, fieldOriginProfile = null)
            }
            val abandonedFind = next.find?.takeUnless { find ->
                next.surface == BrowserSurface.PAGE && !next.privateContentBlocked &&
                    next.tab?.id == find.tab && next.tab?.url == find.url && next.space?.websiteProfile == find.profile
            }
            if (abandonedFind != null) { findRevision++; next = next.copy(find = null) }
            if (before.privateContentBlocked != next.privateContentBlocked)
                lifetime = lifetime.copy(generation = lifetime.generation + 1, privateBoundary = lifetime.privateBoundary + 1)
            if (before.loading != next.loading || before.surface != next.surface || before.surfaceEpoch != next.surfaceEpoch ||
                before.selectedSpaceId != next.selectedSpaceId || before.tab?.id != next.tab?.id ||
                before.tab?.url != next.tab?.url || before.tab?.isPrivate != next.tab?.isPrivate || before.space?.websiteProfile != next.space?.websiteProfile ||
                ((before.surface == BrowserSurface.FIELD || next.surface == BrowserSurface.FIELD) && before.fieldIsPrivate != next.fieldIsPrivate)) navigation++
            if (hardwareKeyFactsChanged(before, next)) hardwareRevision++
            if (before.spaces != next.spaces) routeGeneration++
            expected = next
        }
        fun ownUpdate(persist: Boolean = false, change: (BrowserState) -> BrowserState): Boolean {
            if (!originalRoute()) return false
            // Preserve progress, history and draft data under the already-proven
            // original identity. No new epoch or owner is acquired from this read.
            val raw = change(mutableState.value)
            predict(raw)
            update(persist = persist, continuation = ::originalRoute) { raw }
            return originalRoute()
        }
        // Reorder/reveal only the original destination's own lists and ancestors.
        var prepared = target
        if (same.place != TabPlace.PINNED) {
            var tabs = target.tabs
            if (same.place == TabPlace.TODAY || same.folderId == null) {
                val slots = tabs.indices.filter { tabs[it].place == same.place &&
                    (same.place != TabPlace.KEPT || tabs[it].folderId == null) }
                val rows = slots.map { tabs[it] }.toMutableList()
                val at = rows.indexOfFirst { it.id == same.id }
                if (at > 0) {
                    rows.add(0, rows.removeAt(at))
                    tabs = tabs.toMutableList().apply { slots.forEachIndexed { index, slot -> this[slot] = rows[index] } }
                }
            }
            val ancestors = mutableSetOf<String>()
            var parent = same.folderId.takeIf { same.place == TabPlace.KEPT }
            while (parent != null && ancestors.size < 20 && ancestors.add(parent)) {
                val id = parent
                parent = target.folders.firstOrNull { it.id == id }?.parentId
            }
            prepared = target.copy(tabs = tabs, folders = target.folders.map { if (it.id in ancestors) it.copy(open = true) else it })
        }
        if (prepared != target && !ownUpdate(persist = true) { state -> state.copy(spaces = state.spaces.map { if (it.id == target.id) prepared else it }) }) return
        if (!originalRoute()) return
        // Preserve lockPrivate's valid-source effects while guarding between its
        // clearFind/update and pause callbacks. The public legacy helper stays exact.
        fieldPrivateUnlockLease = null
        privateUnlockLease = null
        if (expected.settings.lockPrivate) {
            if (!ownUpdate { it.copy(privateLocked = true) }) return
            engine.pausePrivateMedia()
            if (!originalRoute()) return
        }
        val pair = expected.workspace
        val abandoned = pair?.newPage?.takeIf { it != same.id }
        if (abandoned != null) {
            val owner = expected.spaces.single { it.id == target.id }
            if (owner.tabs.count { it.id == abandoned && !it.isPrivate } != 1 ||
                expected.spaces.sumOf { space -> space.tabs.count { it.id == abandoned } } != 1) return
            engine.close(abandoned)
            if (!originalRoute()) return
            recorded.remove(abandoned); drafts.remove(abandoned)
        }
        val selectedSpace = expected.spaces.single { it.id == target.id }
        val nextPair = pair?.takeIf { candidate ->
            selectedSpace.tabs.any { it.id == candidate.first } && selectedSpace.tabs.any { it.id == candidate.second }
        }?.let {
            when {
                abandoned != null && same.id == it.first -> null
                !originalExpanded && same.id != it.focused -> null
                same.id == it.first || same.id == it.second -> it.copy(focused = same.id, newPage = it.newPage?.takeIf { page -> page == same.id })
                originalExpanded && it.focused == it.first -> it.copy(first = same.id, focused = same.id, newPage = null)
                originalExpanded -> it.copy(second = same.id, focused = same.id, newPage = null)
                else -> null
            }
        }
        val selectedAt = now()
        if (!originalRoute()) return
        if (!ownUpdate(persist = true) { state -> state.copy(selectedSpaceId = target.id, surface = BrowserSurface.PAGE, galleryClosing = false,
            spaces = state.spaces.map { owner -> owner.copy(
                tabs = owner.tabs.filterNot { it.id == abandoned }.map { if (it.id == same.id) it.copy(lastActiveAt = selectedAt) else it },
                currentTabId = if (owner.id == target.id) same.id else owner.currentTabId,
            ) },
            pageStates = if (abandoned == null) state.pageStates else state.pageStates - abandoned,
            recency = if (abandoned == null) state.recency else state.recency.mapValues { (_, rows) -> rows.filterNot { it == abandoned } },
            workspace = nextPair) }) return
        if (!ownUpdate(persist = true) { state -> state.copy(recency = state.recency +
                (target.id to (listOf(same.id) + state.recency[target.id].orEmpty().filterNot { it == same.id }))) }) return
        val selected = expected.spaces.single { it.id == target.id }.tabs.single { it.id == same.id }
        val observedAt = activityClock()
        if (!originalRoute()) return
        activities[same.id] = TabActivity(target.id, target.websiteProfile.id, selected.url, observedAt, selected.lastActiveAt)
        persist()
        if (!originalRoute()) return
        ordinarySpaceId = target.id
        // No global activate(): this final effect names only the captured chosen profile.
        engine.activate(selected, target.websiteProfile)
    }

    /** The share sheet can save a public address without opening a website. */
    fun keepExternalUrl(url: String): Boolean {
        val current = mutableState.value
        if (current.loading || !canSave) return false
        val address = runCatching { java.net.URI(url.trim()).normalize() }.getOrNull() ?: return false
        if (address.scheme?.lowercase() !in setOf("http", "https") || address.host.isNullOrBlank() || address.rawUserInfo != null) return false
        val target = current.space?.takeUnless(BrowserSpace::isPrivate) ?: current.spaces.firstOrNull { !it.isPrivate } ?: return false
        if (target.tabs.any { tab -> tab.place != TabPlace.TODAY && runCatching { java.net.URI(tab.url).normalize() == address }.getOrDefault(false) }) return true
        val text = address.toASCIIString()
        val tab = BrowserTab(id = newId(), url = text, title = titleFor(text), place = TabPlace.KEPT, createdAt = now())
        editSpace(target.id) { it.copy(tabs = it.tabs + tab) }
        return true
    }

    /** Gecko owns a popup's first navigation; only reserve its model and native namespace here. */
    fun createEngineTab(url: String, openerId: String? = null, background: Boolean = false, privately: Boolean? = null): Pair<BrowserTab, WebsiteProfile>? {
        val current = mutableState.value
        if (current.loading) return null
        val parsed = runCatching { java.net.URI(url) }.getOrNull() ?: return null
        if (url != "about:blank" && (parsed.scheme?.lowercase() !in setOf("http", "https") || parsed.host.isNullOrBlank())) return null
        val source = openerId?.let { id -> current.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } }
        if (openerId != null && source == null) return null
        val isPrivate = privately ?: source?.isPrivate ?: (current.space?.isPrivate == true)
        if (source?.isPrivate == true && !isPrivate) return null
        if (isPrivate && current.settings.lockPrivate && current.privateLocked) return null
        val target = if (isPrivate) ensurePrivateSpace() else source?.takeUnless(BrowserSpace::isPrivate)
            ?: current.space?.takeUnless(BrowserSpace::isPrivate) ?: current.spaces.firstOrNull { !it.isPrivate } ?: return null
        val tab = BrowserTab(newId(), url = parsed.toASCIIString(), title = titleFor(url), isPrivate = isPrivate, openerId = openerId, createdAt = now())
        editSpace(target.id) { space ->
            val index = if (background && openerId != null) (space.tabs.indexOfFirst { it.id == openerId } + 1).coerceIn(0, space.tabs.size) else 0
            space.copy(tabs = space.tabs.toMutableList().apply { add(index, tab) }, currentTabId = if (background) space.currentTabId else tab.id)
        }
        if (!background) {
            selectTab(tab.id, activateEngine = false)
        }
        return tab to target.websiteProfile
    }

    private fun ensurePrivateSpace(): BrowserSpace {
        mutableState.value.spaces.firstOrNull(BrowserSpace::isPrivate)?.let { return it }
        val privateSpace = BrowserSpace(id = PRIVATE_SPACE, name = "Private", color = 0xFF16171B, isPrivate = true)
        update { it.copy(spaces = it.spaces + privateSpace) }
        return privateSpace
    }

    fun selectSpace(id: String) {
        val target = mutableState.value.spaces.firstOrNull { it.id == id } ?: return
        if (!target.isPrivate) lockPrivate()
        // The plate's field stands on its page: another space leaves it a New Tab's.
        if (mutableState.value.let { it.surface == BrowserSurface.FIELD && !it.fieldIsNewTab && it.selectedSpaceId != id })
            update { it.copy(fieldIsNewTab = true, fieldText = "", fieldShowsAddress = false, fieldPagePrivate = false) }
        update(persist = true) { it.copy(selectedSpaceId = id, workspace = null, galleryClosing = false) }
        activate()
        if (mutableState.value.settings.autoClearToday) clearToday(automatic = true)
    }

    fun showPrivate() { selectSpace(ensurePrivateSpace().id) }

    fun unlockPrivate(allowed: Boolean) {
        if (!allowed) { message("Private is still locked."); return }
        update { it.copy(privateLocked = false) }
        activate()
    }

    fun lockPrivate() {
        fieldPrivateUnlockLease = null
        privateUnlockLease = null
        if (mutableState.value.settings.lockPrivate) {
            update { it.copy(privateLocked = true) }
            engine.pausePrivateMedia()
        }
    }

    fun backgrounded() { historyRowSources.clear(); settingsLifetime.value = settingsLifetime.value.copy(generation = settingsLifetime.value.generation + 1, active = false); fieldPrivateUnlockLease = null; privateUnlockLease = null; pageSwipeGeneration++; dismissFind(); rememberDraft(); lockPrivate(); persist() }
    fun foregrounded() {
        settingsLifetime.value = settingsLifetime.value.copy(active = true)
        mutableState.value.tab?.let { observeActivity(it.id); persist() }
        if (mutableState.value.settings.autoClearToday) clearToday(automatic = true)
    }

    fun selectTab(id: String) = selectTab(id, activateEngine = true)

    /** Activate the actual chosen page under its retained gallery picture. */
    fun selectGalleryTab(id: String, epoch: Long = mutableState.value.surfaceEpoch): Boolean {
        val current = mutableState.value
        if (current.surface != BrowserSurface.GALLERY || current.surfaceEpoch != epoch || current.privateContentBlocked || current.galleryTabs.none { it.id == id }) return false
        selectTab(id, activateEngine = true, surface = BrowserSurface.GALLERY)
        return mutableState.value.let { it.surface == BrowserSurface.GALLERY && it.surfaceEpoch == epoch && it.tab?.id == id }
    }

    private fun selectTab(id: String, activateEngine: Boolean, surface: BrowserSurface = BrowserSurface.PAGE) {
        val before = mutableState.value
        val space = before.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        val tab = space.tabs.first { it.id == id }
        if (!space.isPrivate) lockPrivate()
        val pair = before.workspace
        val abandoned = pair?.newPage?.takeIf { it != id }
        if (abandoned != null) {
            engine.close(abandoned); recorded.remove(abandoned); drafts.remove(abandoned)
        }
        val nextPair = pair?.takeIf { candidate -> !space.isPrivate && !tab.isPrivate &&
            space.tabs.any { it.id == candidate.first } && space.tabs.any { it.id == candidate.second } }?.let {
            when {
                abandoned != null && id == it.first -> null
                !workspaceExpanded && id != it.focused -> null
                id == it.first || id == it.second -> it.copy(focused = id, newPage = it.newPage?.takeIf { page -> page == id })
                workspaceExpanded && it.focused == it.first -> it.copy(first = id, focused = id, newPage = null)
                workspaceExpanded -> it.copy(second = id, focused = id, newPage = null)
                else -> null
            }
        }
        update(persist = true) { current -> current.copy(
            selectedSpaceId = space.id, surface = surface, galleryClosing = surface == BrowserSurface.GALLERY,
            spaces = current.spaces.map { item -> item.copy(
                tabs = item.tabs.filterNot { it.id == abandoned }.map { old -> if (old.id == id) old.copy(lastActiveAt = now()) else old },
                currentTabId = if (item.id == space.id) id else item.currentTabId,
            ) },
            pageStates = if (abandoned == null) current.pageStates else current.pageStates - abandoned,
            recency = if (abandoned == null) current.recency else current.recency.mapValues { (_, recent) -> recent.filterNot { it == abandoned } },
            workspace = nextPair,
        ) }
        touch(tab.id, space.id)
        observeActivity(tab.id); persist()
        if (activateEngine) activate()
    }

    private fun touch(id: String, space: String) {
        update(persist = true) { it.copy(recency = it.recency + (space to (listOf(id) + it.recency[space].orEmpty().filterNot { old -> old == id }))) }
    }

    fun switchBy(delta: Int) {
        val current = mutableState.value
        val tabs = current.space?.tabs.orEmpty()
        val index = tabs.indexOfFirst { it.id == current.tab?.id }
        tabs.getOrNull(index + delta)?.let { selectTab(it.id) }
    }

    fun capturePageSwipe(): PageSwipeLease? {
        val source = mutableState.value
        val front = source.tab ?: return null
        val profile = source.space?.websiteProfile ?: return null
        if (source.loading || source.privateContentBlocked || source.surface != BrowserSurface.PAGE ||
            source.find != null || source.workspace != null || front.isBlank) return null
        val order = source.pagingOrder()
        val index = order.indexOfFirst { it.id == front.id }
        if (index < 0) return null
        return PageSwipeLease(localOwnership, pageSwipeGeneration, source.surfaceEpoch, source.selectedSpaceId,
            profile, front, order.getOrNull(index - 1), order.getOrNull(index + 1))
    }

    fun pageSwipeCurrent(lease: PageSwipeLease, openedFieldEpoch: Long? = null): Boolean {
        val current = mutableState.value
        if (lease.ownership != localOwnership || lease.generation != pageSwipeGeneration || current.loading ||
            current.privateContentBlocked || current.workspace != null || current.find != null ||
            current.selectedSpaceId != lease.space || current.space?.websiteProfile != lease.profile ||
            current.tab?.id != lease.front.id || current.tab?.url != lease.front.url ||
            current.tab?.isPrivate != lease.front.isPrivate) return false
        if (openedFieldEpoch == null) {
            if (current.surface != BrowserSurface.PAGE || current.surfaceEpoch != lease.epoch) return false
        } else if (current.surfaceEpoch != openedFieldEpoch || current.surface !in setOf(BrowserSurface.FIELD, BrowserSurface.PAGE) ||
            current.surface == BrowserSurface.FIELD && (!current.fieldIsNewTab || current.fieldIsPrivate != lease.profile.isPrivate ||
                current.fieldOriginTab != lease.front.id || current.fieldOriginSpace != lease.space || current.fieldOriginProfile != lease.profile)) return false
        val order = current.pagingOrder()
        val index = order.indexOfFirst { it.id == lease.front.id }
        fun same(a: BrowserTab?, b: BrowserTab?) = a?.id == b?.id && a?.url == b?.url && a?.isPrivate == b?.isPrivate
        return index >= 0 && same(order.getOrNull(index - 1), lease.before) && same(order.getOrNull(index + 1), lease.after)
    }

    fun settlePageSwipe(lease: PageSwipeLease, direction: Int): Boolean {
        if (direction !in -1..1 || !pageSwipeCurrent(lease)) return false
        val target = when (direction) { -1 -> lease.before; 1 -> lease.after; else -> lease.front } ?: return false
        if (direction != 0) selectTab(target.id)
        return true
    }

    /** Presentation only: retain the departing native page during Reduce Motion's
     * crossfade after selection. This never authorizes an engine or input mutation. */
    fun pageSwipePresentationCurrent(lease: PageSwipeLease, direction: Int, openedFieldEpoch: Long? = null): Boolean {
        if (direction !in -1..1) return false
        if (direction == 1 && lease.after == null) return pageSwipeCurrent(lease, openedFieldEpoch)
        val current = mutableState.value
        val target = when (direction) { -1 -> lease.before; 1 -> lease.after; else -> lease.front } ?: return false
        if (lease.ownership != localOwnership || lease.generation != pageSwipeGeneration || current.loading ||
            current.privateContentBlocked || current.workspace != null || current.find != null ||
            current.surface != BrowserSurface.PAGE || current.surfaceEpoch != lease.epoch ||
            current.selectedSpaceId != lease.space || current.space?.websiteProfile != lease.profile ||
            current.tab?.id != target.id || current.tab?.url != target.url || current.tab?.isPrivate != target.isPrivate) return false
        return listOfNotNull(lease.front, lease.before, lease.after).all { captured ->
            current.space?.tabs?.any { it.id == captured.id && it.url == captured.url && it.isPrivate == captured.isPrivate } == true
        }
    }

    fun openPageSwipeField(lease: PageSwipeLease, origin: FieldAnchor?): Long? {
        if (lease.after != null || !pageSwipeCurrent(lease)) return null
        openField(origin = origin)
        if (!lease.profile.isPrivate) update { it.copy(fieldInPlace = true) }
        return mutableState.value.surfaceEpoch
    }

    // History swipe ownership is independent from neighboring-tab presentation.
    private var historySwipeLease: HistorySwipeLease? = null
    private var historySettingGeneration = 0L

    fun captureHistorySwipe(direction: HistorySwipeDirection): HistorySwipeLease? {
        historySwipeLease = null
        val current = mutableState.value
        val front = current.tab ?: return null
        val profile = current.space?.websiteProfile ?: return null
        if (current.loading || current.page.loading || current.page.readerEnabled || current.privateContentBlocked || current.find != null ||
            current.surface != BrowserSurface.PAGE || !current.settings.swipeAnywhere || front.isBlank) return null
        val opener = if (direction == HistorySwipeDirection.BACK && !current.page.canGoBack) front.openerId?.let { id ->
            current.space?.tabs?.firstOrNull { it.id == id && it.isPrivate == front.isPrivate }
        } else null
        val native = if (opener == null) engine.captureHistorySwipe(front.id, direction)?.takeIf { it.direction == direction } else null
        if (opener == null && native == null) return null
        return HistorySwipeLease(localOwnership, pageSwipeGeneration, historySettingGeneration, current.surfaceEpoch,
            current.selectedSpaceId, current.workspace, profile, front, direction, native, opener).also { historySwipeLease = it }
    }

    fun historySwipeCurrent(lease: HistorySwipeLease): Boolean {
        val current = mutableState.value
        if (historySwipeLease !== lease || lease.ownership != localOwnership || lease.background != pageSwipeGeneration ||
            lease.setting != historySettingGeneration || current.loading || current.page.loading || current.page.readerEnabled || current.privateContentBlocked ||
            current.find != null || current.surface != BrowserSurface.PAGE || current.surfaceEpoch != lease.epoch ||
            !current.settings.swipeAnywhere || current.workspace != lease.workspace || current.selectedSpaceId != lease.space ||
            current.space?.websiteProfile != lease.profile || current.tab?.id != lease.front.id ||
            current.tab?.url != lease.front.url || current.tab?.isPrivate != lease.front.isPrivate) return false
        val opener = lease.opener
        if (opener != null) return !current.page.canGoBack && current.tab?.openerId == opener.id &&
            current.space?.tabs?.any { it.id == opener.id && it.url == opener.url && it.isPrivate == opener.isPrivate } == true
        return lease.target?.let(engine::historySwipeCurrent) == true
    }

    fun cancelHistorySwipe(lease: HistorySwipeLease) { if (historySwipeLease === lease) historySwipeLease = null }

    fun commitHistorySwipe(lease: HistorySwipeLease): Boolean {
        if (!historySwipeCurrent(lease)) return false
        historySwipeLease = null // Consume before any engine or observer callback.
        val opener = lease.opener
        if (opener != null) {
            closeTab(lease.front.id)
            return localOwnership == lease.ownership && mutableState.value.tab?.id == opener.id
        }
        return lease.target?.let(engine::commitHistorySwipe) == true
    }

    fun previousTab() { mutableState.value.galleryTabs.firstOrNull { it.id != mutableState.value.tab?.id }?.let { selectTab(it.id) } }

    private fun hardwareKeyFactsChanged(before: BrowserState, next: BrowserState): Boolean {
        val beforePage = before.page
        val nextPage = next.page
        // Engine progress/scroll and Field typing keep the same structural references.
        // Only a candidate transition pays for the selected tab/order projections.
        if (before.spaces === next.spaces && before.workspace == next.workspace &&
            before.loading == next.loading && before.surface == next.surface && before.surfaceEpoch == next.surfaceEpoch &&
            before.selectedSpaceId == next.selectedSpaceId && before.privateLocked == next.privateLocked &&
            before.settings.lockPrivate == next.settings.lockPrivate && before.settings.welcomed == next.settings.welcomed &&
            before.fieldIsNewTab == next.fieldIsNewTab &&
            before.fieldIsPrivate == next.fieldIsPrivate && before.undoAvailable == next.undoAvailable &&
            beforePage.loading == nextPage.loading && beforePage.readerEnabled == nextPage.readerEnabled &&
            beforePage.canGoBack == nextPage.canGoBack && beforePage.canGoForward == nextPage.canGoForward) return false
        return before.hardwareKeyFacts() != next.hardwareKeyFacts()
    }

    private fun hardwareKeyAllowed(key: BrowserHardwareKey, current: BrowserState): Boolean {
        if (current.loading || current.privateContentBlocked) return false
        if (current.surface == BrowserSurface.FIELD) return key == BrowserHardwareKey.CLOSE_TAB
        if (current.surface != BrowserSurface.PAGE) return false
        val tab = current.tab
        if (tab != null && (tab.isPrivate != (current.space?.isPrivate == true) ||
                current.spaces.sumOf { owner -> owner.tabs.count { it.id == tab.id } } != 1)) return false
        val order = current.pagingOrder()
        if (order.map(BrowserTab::id).distinct().size != order.size) return false
        return when (key) {
            BrowserHardwareKey.NEW_TAB -> true
            BrowserHardwareKey.OPEN_LOCATION, BrowserHardwareKey.CLOSE_TAB, BrowserHardwareKey.RELOAD -> tab != null
            BrowserHardwareKey.REOPEN_TAB -> undo?.let { receipt ->
                current.undoAvailable && activityClock().since(receipt.offered)?.let { it <= UNDO_MILLIS } == true &&
                    receipt.tabs.none { it.tab.isPrivate && current.settings.lockPrivate && current.privateLocked }
            } == true
            BrowserHardwareKey.BACK -> tab != null && (current.page.readerEnabled || current.page.canGoBack ||
                tab.openerId?.takeUnless { it == tab.id }?.let { id -> current.space?.tabs?.singleOrNull {
                    it.id == id && it.isPrivate == tab.isPrivate
                } }?.let { hardwareKeyTargetCurrent(current, it) } == true)
            BrowserHardwareKey.FORWARD -> tab != null && current.page.canGoForward
            BrowserHardwareKey.FIND -> tab != null && !tab.isBlank
            BrowserHardwareKey.NEXT_TAB, BrowserHardwareKey.PREVIOUS_TAB -> tab != null && order.size > 1 &&
                order.getOrNull(order.indexOfFirst { it.id == tab.id } + if (key == BrowserHardwareKey.NEXT_TAB) 1 else -1)
                    ?.let { hardwareKeyTargetCurrent(current, it) } != false
            else -> key.tabNumber?.let { number ->
                order.getOrNull(if (number == 9) order.lastIndex else number - 1)?.let { hardwareKeyTargetCurrent(current, it) }
            } == true
        }
    }

    private fun hardwareKeyTargetCurrent(current: BrowserState, target: BrowserTab): Boolean {
        val owner = current.space ?: return false
        return target.isPrivate == owner.isPrivate && owner.tabs.singleOrNull { it.id == target.id }?.let {
            it.url == target.url && it.isPrivate == target.isPrivate
        } == true && current.spaces.sumOf { space -> space.tabs.count { it.id == target.id } } == 1
    }

    fun captureHardwareKey(key: BrowserHardwareKey, host: BrowserHardwareKeyHost): BrowserHardwareKeyLease? {
        val original = mutableState.value
        val revision = mutableHardwareKeyRevision.value
        val ownership = localOwnership
        val lifetime = settingsLifetime.value
        val originalUndo = undo
        val navigation = historyLifetime.value
        val window = mutableWorkspaceWindow.value
        val welcomeBoundary = hardwareKeyWelcomeBoundary
        if (!lifetime.active || !hardwareKeyAllowed(key, original) || !host.current() ||
            mutableState.value !== original || mutableHardwareKeyRevision.value != revision || localOwnership != ownership ||
            settingsLifetime.value != lifetime || undo !== originalUndo || historyLifetime.value != navigation ||
            mutableWorkspaceWindow.value != window || hardwareKeyWelcomeBoundary != welcomeBoundary) return null
        return BrowserHardwareKeyLease(this, key, host, revision, ownership, lifetime, original, originalUndo, navigation, window, welcomeBoundary)
    }

    fun hardwareKeyCurrent(lease: BrowserHardwareKeyLease): Boolean {
        if (lease.controller !== this || lease.retired || lease.consumed) return false
        fun factsCurrent() = lease.revision == mutableHardwareKeyRevision.value && lease.ownership == localOwnership &&
            settingsLifetime.value == lease.lifetime && lease.lifetime.active &&
            historyLifetime.value == lease.navigation && mutableWorkspaceWindow.value == lease.window &&
            hardwareKeyWelcomeBoundary == lease.welcomeBoundary &&
            lease.original.hardwareKeyFacts() == mutableState.value.hardwareKeyFacts() &&
            (lease.key != BrowserHardwareKey.REOPEN_TAB || undo === lease.undo) &&
            hardwareKeyAllowed(lease.key, mutableState.value)
        if (!factsCurrent() || !lease.host.current() || !factsCurrent()) { lease.retired = true; return false }
        return true
    }

    private fun hardwareKeyContinuationCurrent(lease: BrowserHardwareKeyLease, navigation: Long, front: BrowserTab?,
        afterClose: Boolean = false): Boolean {
        fun factsCurrent(): Boolean {
            val current = mutableState.value
            return lease.ownership == localOwnership && settingsLifetime.value == lease.lifetime && lease.lifetime.active &&
                mutableWorkspaceWindow.value == lease.window && historyLifetime.value == navigation &&
                hardwareKeyWelcomeBoundary == lease.welcomeBoundary &&
                !current.loading && !current.privateContentBlocked && current.surface == BrowserSurface.PAGE &&
                current.surfaceEpoch == lease.original.surfaceEpoch && current.selectedSpaceId == lease.original.selectedSpaceId &&
                current.space?.websiteProfile == lease.original.space?.websiteProfile &&
                (if (front == null) current.tab == null else current.tab?.let {
                    it.id == front.id && it.url == front.url && it.isPrivate == front.isPrivate
                } == true)
        }
        return factsCurrent() && (if (afterClose) lease.host.continuationCurrent() else lease.host.current()) && factsCurrent()
    }

    fun performHardwareKey(lease: BrowserHardwareKeyLease): Boolean {
        if (!hardwareKeyCurrent(lease)) return false
        lease.consumed = true // Before engine, repository or state observers can reenter.
        // Even an engine refusal or a Reload with no state publication needs a fresh
        // rendered key registration. The consumed callback never lends that revision.
        mutableHardwareKeyRevision.value += 1
        val original = lease.original
        return when (lease.key) {
            BrowserHardwareKey.NEW_TAB -> { openField(); true }
            BrowserHardwareKey.OPEN_LOCATION -> { openField(newTab = false); true }
            BrowserHardwareKey.CLOSE_TAB -> if (original.surface == BrowserSurface.FIELD) dismissField(original.surfaceEpoch)
                else { closeTab(checkNotNull(original.tab).id); true }
            BrowserHardwareKey.REOPEN_TAB -> { undoClose(); true }
            BrowserHardwareKey.RELOAD -> { engine.reload(checkNotNull(original.tab).id); true }
            BrowserHardwareKey.BACK -> when {
                original.page.readerEnabled -> engine.setReader(checkNotNull(original.tab).id, false)
                original.page.canGoBack -> { engine.goBack(checkNotNull(original.tab).id); true }
                else -> {
                    val tab = checkNotNull(original.tab)
                    val owner = checkNotNull(original.space)
                    val opener = checkNotNull(owner.tabs.singleOrNull { it.id == tab.openerId })
                    val remaining = owner.tabs.filterNot { it.id == tab.id }
                    val companion = original.workspace?.let { pair -> if (tab.id == pair.first) pair.second else pair.first }
                    val automaticFront = remaining.firstOrNull { it.id == companion } ?: heir(listOf(tab.id), owner)?.let { id -> remaining.firstOrNull { it.id == id } }
                    closeTab(tab.id)
                    // closeTab invokes the engine. Its own front removal advances this
                    // lifetime once; a reentrant account/selection/URL/cover ABA cannot
                    // lend the original opener id to a successor after that call.
                    if (!hardwareKeyContinuationCurrent(lease, lease.navigation + 1, automaticFront, afterClose = true) ||
                        !hardwareKeyTargetCurrent(mutableState.value, opener)) return false
                    selectTab(opener.id); true
                }
            }
            BrowserHardwareKey.FORWARD -> { engine.goForward(checkNotNull(original.tab).id); true }
            BrowserHardwareKey.FIND -> {
                val originalFindGeneration = findGeneration
                val expectedFindGeneration = originalFindGeneration + if (mutableState.value.find == null) 1 else 0
                if (mutableState.value.find == null) {
                    beginFind()
                }
                if (!hardwareKeyContinuationCurrent(lease, lease.navigation, original.tab) ||
                    findGeneration != expectedFindGeneration ||
                    mutableState.value.find?.let {
                        it.tab == original.tab?.id && it.url == original.tab?.url && it.profile == original.space?.websiteProfile
                    } != true) return false
                // Repeated Find focuses the existing bar without replacing its query.
                update { it.copy(surfaceEpoch = it.surfaceEpoch + 1) }
                true
            }
            else -> {
                val order = original.pagingOrder()
                val index = when (lease.key) {
                    BrowserHardwareKey.NEXT_TAB -> order.indexOfFirst { it.id == original.tab?.id } + 1
                    BrowserHardwareKey.PREVIOUS_TAB -> order.indexOfFirst { it.id == original.tab?.id } - 1
                    else -> checkNotNull(lease.key.tabNumber).let { if (it == 9) order.lastIndex else it - 1 }
                }
                val target = order.getOrNull(index) ?: return false
                if (!hardwareKeyTargetCurrent(mutableState.value, target)) return false
                selectTab(target.id); true
            }
        }
    }

    fun closeTab(id: String) {
        val current = mutableState.value
        val space = current.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        val index = space.tabs.indexOfFirst { it.id == id }
        val tab = space.tabs[index]
        invalidateUndo()
        val removed = removed(space, index, tab)
        removeTabs(listOf(removed))
        offerUndo(listOf(removed))
        activate()
    }

    /** Native window.close is limited to the engine's exact script-created popup. */
    fun closeEnginePopup(id: String, openerId: String, profile: WebsiteProfile): Boolean {
        val current = mutableState.value
        if (current.loading) return false
        val space = current.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return false
        val tab = space.tabs.first { it.id == id }
        if (id == openerId || tab.openerId != openerId || space.websiteProfile != profile || tab.isPrivate != profile.isPrivate) return false
        val opener = space.tabs.firstOrNull { it.id == openerId }
        val wasFront = current.tab?.id == id
        if (wasFront && opener != null && !current.privateContentBlocked) selectTab(opener.id, activateEngine = true, surface = current.surface)
        val remaining = mutableState.value.spaces.firstOrNull { it.id == space.id } ?: return true
        val index = remaining.tabs.indexOfFirst { it.id == id }
        if (index >= 0) {
            // An authentication callback is not a user close and must not offer Undo.
            removeTabs(listOf(Removed(space.id, index, tab, profile, false, null, null, activities[id])))
        }
        if (wasFront && opener == null) activate()
        return true
    }

    /** Closing a kept/pinned card removes only this device's open-page membership. */
    fun closeGalleryTab(id: String) {
        val current = mutableState.value
        val space = current.space ?: return
        val tab = space.tabs.firstOrNull { it.id == id } ?: return
        if (tab.place == TabPlace.TODAY) { closeTab(id); return }
        val recent = current.recency[space.id].orEmpty().filterNot { it == id }
        val other = current.workspace?.takeIf { it.first == id || it.second == id }?.let { if (it.first == id) it.second else it.first }
        val next = other ?: recent.firstOrNull { candidate -> space.tabs.any { it.id == candidate && it.id != id } }
            ?: heir(listOf(id), space)
        engine.close(id)
        update(persist = true) { it.copy(
            spaces = it.spaces.map { item -> if (item.id == space.id && item.currentTabId == id) item.copy(currentTabId = next) else item },
            recency = it.recency + (space.id to recent), pageStates = it.pageStates - id,
            workspace = it.workspace?.takeUnless { pair -> pair.first == id || pair.second == id },
        ) }
        activate()
    }

    private fun removeTabs(removed: List<Removed>) {
        val ids = removed.mapTo(mutableSetOf()) { it.tab.id }
        ids.forEach { engine.close(it); recorded.remove(it); drafts.remove(it) }
        update(persist = true) { old -> old.copy(
            spaces = old.spaces.map { space ->
                val tabs = space.tabs.filterNot { it.id in ids }
                val other = old.workspace?.takeIf { space.currentTabId in ids }?.let { pair ->
                    (if (space.currentTabId == pair.first) pair.second else pair.first).takeIf { candidate -> tabs.any { it.id == candidate } }
                }
                space.copy(tabs = tabs, currentTabId = if (space.currentTabId in ids) other ?: heir(ids, space) else space.currentTabId)
            },
            recency = old.recency.mapValues { (_, recent) -> recent.filterNot(ids::contains) },
            pageStates = old.pageStates.filterKeys { it !in ids },
            workspace = old.workspace?.takeUnless { it.first in ids || it.second in ids },
        ) }
        mutableState.value.let { now -> if (now.space?.isPrivate == true && now.space?.tabs?.isEmpty() == true && !privateLocks)
            ordinarySpace(now)?.let { public -> update { it.copy(selectedSpaceId = public.id) } } }
        // Like Phone's privateTabsNow, Undo may restore the card after this boundary,
        // but cannot resurrect the ended Private website-data session.
        removed.map { it.profile }.filter(WebsiteProfile::isPrivate).distinct().forEach { profile ->
            if (mutableState.value.spaces.none { it.websiteProfile == profile && it.tabs.isNotEmpty() })
                engine.endPrivateSession(profile)
        }
    }

    /** What takes a leaving tab's place in front: only ever a today's tab. A pin or a kept tab
     * never steps forward by itself, the page stands empty with New Tab on the plate. */
    private fun heir(leaving: Collection<String>, space: BrowserSpace): String? {
        val at = space.tabs.indexOfFirst { it.id in leaving }.coerceAtLeast(0)
        fun open(tab: BrowserTab) = tab.id !in leaving && tab.place == TabPlace.TODAY
        return (space.tabs.drop(at).firstOrNull(::open) ?: space.tabs.take(at).lastOrNull(::open))?.id
    }

    /** The tab in front lets go of the page and stays where it is kept. */
    fun letGoFront() {
        val current = mutableState.value
        val space = current.space ?: return
        val front = current.tab ?: return
        if (space.isPrivate || front.place == TabPlace.TODAY) return
        update(persist = true) { state -> state.copy(
            spaces = state.spaces.map { if (it.id == space.id) it.copy(currentTabId = heir(listOf(front.id), space)) else it },
            workspace = null) }
        activate()
    }

    private fun removed(space: BrowserSpace, index: Int, tab: BrowserTab) = Removed(space.id, index, tab,
        space.websiteProfile, space.currentTabId == tab.id,
        mutableState.value.recency[space.id]?.indexOf(tab.id)?.takeIf { it >= 0 },
        engine.captureForUndo(tab, space.websiteProfile), activities[tab.id])

    fun invalidateUndo() {
        undoTimer?.cancel()
        undo?.tabs?.forEach { it.memory?.let(engine::releaseUndo) }
        undo = null
        if (mutableState.value.undoAvailable) update { it.copy(undoAvailable = false, message = null) }
    }

    /** A Sync identity transition cannot lend old local proof to reused tab/profile identifiers. */
    fun invalidateLocalOwnership() {
        historyRowSources.clear()
        localOwnership++
        drafts.clear()
        update { it.copy(surface = if (it.surface in setOf(BrowserSurface.FIELD, BrowserSurface.SPACES, BrowserSurface.GALLERY)) BrowserSurface.PAGE else it.surface,
            surfaceEpoch = it.surfaceEpoch + 1, galleryClosing = false,
            fieldText = "", fieldShowsAddress = false, fieldIsNewTab = true, fieldPrivate = false, fieldPagePrivate = false,
            fieldOriginTab = null, fieldOriginSpace = null, fieldOriginProfile = null, fieldAnchor = null, fieldResting = false) }
        dismissFind()
        invalidateUndo()
        activities.clear()
        engine.invalidateTransientOwnership()
        engine.reconcileTabs(mutableState.value.spaces)
        persist()
    }

    private fun offerUndo(removed: List<Removed>) {
        if (removed.isEmpty()) return
        undoTimer?.cancel()
        undo = Undo(removed, activityClock())
        update { it.copy(undoAvailable = true, message = if (removed.size == 1) "Closed ${removed.single().tab.host}" else "${removed.size} Tabs Cleared") }
        undoTimer = scope.launch { delay(UNDO_MILLIS); invalidateUndo() }
    }

    fun undoClose() {
        val receipt = undo ?: return
        val age = activityClock().since(receipt.offered)
        if (age == null || age > UNDO_MILLIS) { invalidateUndo(); return }
        if (receipt.tabs.any { it.tab.isPrivate } && mutableState.value.settings.lockPrivate && mutableState.value.privateLocked) return
        undoTimer?.cancel()
        fun restoreRecords() {
        if (undo !== receipt) return
        if (receipt.tabs.any { it.tab.isPrivate } && mutableState.value.settings.lockPrivate && mutableState.value.privateLocked) { invalidateUndo(); return }
        undo = null
        val valid = receipt.tabs.filter { saved -> mutableState.value.spaces.any { it.id == saved.space && it.websiteProfile == saved.profile } }
        valid.forEach { saved -> saved.activity?.let { activities[saved.tab.id] = it } }
        update(persist = true) { current -> current.copy(spaces = current.spaces.map { space ->
            val tabs = space.tabs.toMutableList()
            valid.filter { it.space == space.id }.sortedBy(Removed::index).forEach { removed ->
                if (tabs.none { it.id == removed.tab.id }) tabs.add(removed.index.coerceIn(0, tabs.size), removed.tab)
            }
            space.copy(tabs = tabs, currentTabId = valid.firstOrNull { it.space == space.id && it.wasFront }?.tab?.id ?: space.currentTabId ?: tabs.firstOrNull()?.id)
        }, selectedSpaceId = valid.firstOrNull(Removed::wasFront)?.space ?: current.selectedSpaceId,
        recency = current.recency.toMutableMap().apply {
            valid.groupBy(Removed::space).forEach { (space, entries) ->
                val recent = get(space).orEmpty().toMutableList()
                entries.filter { it.recentIndex != null }.sortedBy { it.recentIndex }.forEach { saved ->
                    recent.remove(saved.tab.id); recent.add(saved.recentIndex!!.coerceIn(0, recent.size), saved.tab.id)
                }
                put(space, recent)
            }
        }, undoAvailable = false, message = null) }
        receipt.tabs.forEach { it.memory?.let(engine::releaseUndo) }
        activate()
        }
        if (receipt.tabs.none { it.memory != null }) restoreRecords()
        else scope.launch {
            try {
                for (saved in receipt.tabs) {
                    if (undo !== receipt) return@launch
                    val space = mutableState.value.spaces.firstOrNull { it.id == saved.space && it.websiteProfile == saved.profile }
                    if (space != null && (!space.isPrivate || !mutableState.value.privateLocked || !mutableState.value.settings.lockPrivate))
                        saved.memory?.let { engine.restoreForUndo(saved.tab, saved.profile, it) {
                            undo === receipt && mutableState.value.spaces.any { owner -> owner.id == saved.space && owner.websiteProfile == saved.profile } &&
                                (!saved.tab.isPrivate || !mutableState.value.settings.lockPrivate || !mutableState.value.privateLocked)
                        } }
                }
                restoreRecords()
            } finally { receipt.tabs.forEach { it.memory?.let(engine::releaseUndo) } }
        }
    }

    fun clearToday(automatic: Boolean = false) {
        val current = mutableState.value
        val space = current.space ?: return
        if (current.privateContentBlocked) return
        if (automatic && undo != null) return
        if (!automatic) invalidateUndo()
        val clock = activityClock()
        val removed = space.tabs.mapIndexedNotNull { index, tab ->
            val page = current.pageStates[tab.id]
            val activity = activities[tab.id]?.takeIf { it.space == space.id && it.profile == space.websiteProfile.id && it.url == tab.url }
            val age = activity?.clock?.let(clock::since)
            val protected = tab.place != TabPlace.TODAY || tab.id == space.currentTabId || tab.hasTask || tab.hasDraft ||
                drafts[tab.id]?.isNotBlank() == true || page?.playingMedia == true || page?.capturingMedia == true || page?.hasFormEdits == true || page?.loading == true
            val automaticUnsafe = automatic && (!tab.locallyCreated || tab.shared || page?.safeToClear != true || age == null || age < TWELVE_HOURS)
            if (!protected && !automaticUnsafe && (page == null || page.safeToClear)) removed(space, index, tab) else null
        }
        if (removed.isEmpty()) { if (!automatic) message("No inactive tabs to clear"); return }
        removeTabs(removed)
        offerUndo(removed)
    }

    fun keepTab(id: String) = setPlace(id, TabPlace.KEPT)
    fun unkeepTab(id: String) = setPlace(id, TabPlace.TODAY)
    fun pinTab(id: String) = setPinned(id, true)
    fun unpinTab(id: String) = setPinned(id, false)

    /** The existing public tab moves between the pin grid and Today; its page stays live. */
    private fun setPinned(id: String, pinned: Boolean) {
        val state = mutableState.value
        val space = state.spaces.singleOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        val tab = space.tabs.singleOrNull { it.id == id } ?: return
        if (state.privateContentBlocked || space.isPrivate || tab.isPrivate || (tab.place == TabPlace.PINNED) == pinned) return
        val moved = tab.copy(place = if (pinned) TabPlace.PINNED else TabPlace.TODAY, folderId = null)
        editSpace(space.id) { current ->
            if (current.tabs.singleOrNull { it.id == id } != tab) current else {
                val rest = current.tabs.filterNot { it.id == id }
                current.copy(tabs = if (pinned) rest + moved else listOf(moved) + rest,
                    keptOrder = current.keptOrder.filterNot { it == "tab:$id" })
            }
        }
    }

    fun toggleFolder(spaceId: String, folderId: String) {
        editSpace(spaceId) { space -> space.copy(folders = space.folders.map { if (it.id == folderId) it.copy(open = !it.open) else it }) }
    }
    private fun setPlace(id: String, place: TabPlace) {
        val space = mutableState.value.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        if (space.isPrivate) return
        val tab = space.tabs.first { it.id == id }
        val source = if (place == TabPlace.KEPT) TabPlace.TODAY else TabPlace.KEPT
        if (tab.isPrivate || tab.place != source) return
        // Phone removes the old tree row: Keep appends at root, Unkeep leads Today.
        val moved = tab.copy(place = place, folderId = null)
        editSpace(space.id) { current ->
            val rest = current.tabs.filterNot { it.id == id }
            val order = BrowserKeptTree.rows(current, includeClosed = true).map { it.key }.filterNot { it == "tab:$id" }
            current.copy(tabs = if (place == TabPlace.KEPT) rest + moved else listOf(moved) + rest,
                keptOrder = if (place == TabPlace.KEPT) order + "tab:$id" else order)
        }
    }

    fun moveTab(id: String, targetId: String) {
        val current = mutableState.value
        val source = current.spaces.firstOrNull { it.tabs.any { tab -> tab.id == id } } ?: return
        val target = current.spaces.firstOrNull { it.id == targetId && !it.isPrivate } ?: return
        val tab = source.tabs.first { it.id == id }
        if (source.isPrivate || source.id == target.id) return
        engine.close(id)
        update(persist = true) { it.copy(spaces = it.spaces.map { space -> when (space.id) {
            source.id -> space.copy(tabs = space.tabs.filterNot { item -> item.id == id }, currentTabId = space.currentTabId?.takeUnless { selected -> selected == id } ?: space.tabs.firstOrNull { item -> item.id != id }?.id)
            target.id -> space.copy(tabs = listOf(tab.copy(place = TabPlace.TODAY, folderId = null)) + space.tabs)
            else -> space
        } }, pageStates = it.pageStates - id, workspace = null) }
        message("Moved to ${target.name}")
        activate()
    }

    fun addSpace(name: String) {
        val value = name.trim().take(80)
        if (value.isEmpty()) return
        val space = BrowserSpace(id = newId(), name = value, color = 0xFFA8C3A0)
        update(persist = true) { it.copy(spaces = it.spaces + space, selectedSpaceId = space.id) }
        openField()
    }

    fun editSpace(id: String, name: String, emoji: String, color: Long) {
        if (name.isBlank()) return
        editSpace(id) { if (it.isPrivate) it else it.copy(name = name.trim().take(80), emoji = emoji.take(16), color = color) }
    }

    /** The UI asks first because active pages reload in a different cookie namespace. */
    fun changeSignIns(id: String, own: Boolean) {
        val space = mutableState.value.spaces.firstOrNull { it.id == id && !it.isPrivate } ?: return
        if (space.ownSignIns == own) return
        space.tabs.forEach { engine.close(it.id) }
        editSpace(id) { it.copy(ownSignIns = own) }
        update { it.copy(pageStates = it.pageStates.filterKeys { key -> space.tabs.none { it.id == key } }) }
        activate()
    }

    fun deleteSpace(id: String) {
        val current = mutableState.value
        val public = current.spaces.filterNot(BrowserSpace::isPrivate)
        val space = public.firstOrNull { it.id == id } ?: return
        if (public.size <= 1 || public.first().id == id) return
        space.tabs.forEach { engine.close(it.id) }
        // Whatever this space ever excused went with it, under the profile its
        // own sign-ins once used; forgetting a profile that never had one is
        // a no-op.
        engine.forgetWebsitePardons("space-" + space.id)
        update(persist = true) { it.copy(spaces = it.spaces.filterNot { item -> item.id == id }, selectedSpaceId = if (it.selectedSpaceId == id) public.first().id else it.selectedSpaceId, workspace = null) }
        activate()
    }

    fun updateSettings(settings: BrowserSettings) {
        if (settings.swipeAnywhere != mutableState.value.settings.swipeAnywhere) {
            historySettingGeneration++
            historySwipeLease = null
        }
        val changedLock = settings.lockPrivate != mutableState.value.settings.lockPrivate
        if (changedLock) { fieldPrivateUnlockLease = null; privateUnlockLease = null }
        update(persist = true) { it.copy(settings = settings, privateLocked = if (changedLock) true else it.privateLocked) }
        if (changedLock && settings.lockPrivate) engine.pausePrivateMedia()
    }

    fun captureHistoryPresentation(): HistoryPresentationLease? = mutableState.value.takeIf {
        !it.loading && it.surface == BrowserSurface.HISTORY && settingsLifetime.value.active
    }?.let { HistoryPresentationLease(localOwnership, settingsLifetime.value.generation,
        settingsLifetime.value.privateBoundary, historyLifetime.value, it.surfaceEpoch, it.selectedSpaceId, it.tab?.id, it.space?.websiteProfile) }

    fun historyActionsCurrent(lease: HistoryPresentationLease): Boolean = mutableState.value.let {
        !it.loading && it.surface == BrowserSurface.HISTORY && it.surfaceEpoch == lease.epoch &&
            lease.ownership == localOwnership && settingsLifetime.value.active &&
            lease.sourceGeneration == historyLifetime.value &&
            lease.foreground == settingsLifetime.value.generation && lease.privateBoundary == settingsLifetime.value.privateBoundary &&
            it.selectedSpaceId == lease.space && it.tab?.id == lease.front && it.space?.websiteProfile == lease.profile
    }

    fun dismissHistory(lease: HistoryPresentationLease): Boolean {
        if (!historyActionsCurrent(lease)) return false
        dismissSurface()
        return true
    }

    fun captureHistoryRow(lease: HistoryPresentationLease, visit: BrowserVisit): HistoryRowPresentationLease? {
        if (!historyActionsCurrent(lease) || mutableState.value.history.none { it == visit }) return null
        return HistoryRowPresentationLease(visit, lease, historyRowSources.capture(visit))
    }

    fun historyRowActionsCurrent(lease: HistoryRowPresentationLease): Boolean =
        historyActionsCurrent(lease.presentation) && historyRowSources.current(lease.visit, lease.source) &&
            mutableState.value.history.any { it == lease.visit }

    fun openHistoryRow(lease: HistoryRowPresentationLease): Boolean =
        historyRowActionsCurrent(lease) && openHistoryVisit(lease.presentation, lease.visit)

    fun deleteHistoryRow(lease: HistoryRowPresentationLease): Boolean =
        historyRowActionsCurrent(lease) && deleteHistoryVisit(lease.presentation, lease.visit)

    /** Like Phone openFromHistory: an existing public page, an empty non-pin, or a new
     * ordinary tab. History opened from Private never inherits its cookie namespace. */
    fun openHistoryVisit(lease: HistoryPresentationLease, visit: BrowserVisit): Boolean {
        if (!historyActionsCurrent(lease) || mutableState.value.history.none { it == visit }) return false
        val address = runCatching { java.net.URI(visit.url) }.getOrNull() ?: return false
        if (address.scheme?.lowercase() !in setOf("http", "https") || address.host.isNullOrBlank()) return false
        val current = mutableState.value
        val ordinary = current.space?.isPrivate != true
        val target = ordinarySpace(current) ?: return false
        if (ordinary) {
            val existing = target.tabs.firstOrNull { !it.isPrivate && HistoryPresentation.pretty(it.url) == HistoryPresentation.pretty(visit.url) }
            if (existing != null) { selectTab(existing.id); return true }
            val front = target.currentTab
            if (front != null && !front.isPrivate && front.isBlank && front.place != TabPlace.PINNED) {
                val page = front.copy(url = visit.url, title = visit.title.ifBlank { titleFor(visit.url) }, lastActiveAt = now())
                dismissSurface()
                editSpace(target.id) { it.copy(tabs = it.tabs.map { old -> if (old.id == page.id) page else old }) }
                observeActivity(page.id); persist()
                engine.activate(page, target.websiteProfile)
                engine.navigate(page, page.url, target.websiteProfile)
                return true
            }
        }
        val page = BrowserTab(id = newId(), url = visit.url, title = visit.title.ifBlank { titleFor(visit.url) }, createdAt = now())
        editSpace(target.id) { it.copy(tabs = listOf(page) + it.tabs, currentTabId = page.id) }
        selectTab(page.id, activateEngine = false)
        engine.activate(page, target.websiteProfile)
        engine.navigate(page, page.url, target.websiteProfile)
        return true
    }

    fun deleteHistoryVisit(lease: HistoryPresentationLease, visit: BrowserVisit): Boolean {
        if (!historyActionsCurrent(lease) || mutableState.value.history.none { it == visit }) return false
        deleteVisit(visit)
        return true
    }

    fun clearHistory(lease: HistoryPresentationLease, range: HistoryRange, zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): Boolean {
        if (!historyActionsCurrent(lease)) return false
        clearHistory(range.start(now(), zone))
        return true
    }

    fun deleteVisit(visit: BrowserVisit) {
        update(persist = true) { current ->
            val actual = current.history.firstOrNull { it.identity == visit.identity } ?: return@update current
            val forgetting = actual.syncedKey?.let { key -> current.historyForgetting.forget(key, actual.syncedAt ?: actual.visitedAt / 1000.0) } ?: current.historyForgetting
            current.copy(history = current.history.filterNot { it.identity == actual.identity }, historyForgetting = forgetting)
        }
    }
    fun deleteVisit(url: String) { mutableState.value.history.firstOrNull { it.url == url }?.let(::deleteVisit) }
    fun clearHistory(since: Long = 0L) {
        val at = now()
        update(persist = true) { current ->
            val forgetting = current.historyForgetting.clear(since / 1000.0, at / 1000.0 + 60).prune(at)
            current.copy(history = current.history.filter { visit ->
                if (visit.syncedKey == null) visit.visitedAt < since
                else !forgetting.hides(visit.syncedKey, visit.syncedAt ?: visit.visitedAt / 1000.0)
            }, historyForgetting = forgetting)
        }
    }

    fun clearHistoryAndData() {
        invalidateUndo()
        val profiles = mutableState.value.spaces.filterNot(BrowserSpace::isPrivate).mapTo(mutableSetOf()) { it.websiteProfile.id }
        scope.launch {
            runCatching { engine.clearWebsiteData(profiles) }.onSuccess {
                clearHistory()
                message("History and Data Cleared")
                activate()
            }.onFailure { message("Couldn't clear website data. Try again.") }
        }
    }

    fun pageChanged(tabId: String, page: EnginePageState) {
        val current = mutableState.value
        val space = current.spaces.firstOrNull { it.tabs.any { tab -> tab.id == tabId } } ?: return
        val tab = space.tabs.first { it.id == tabId }
        val url = page.url?.takeIf { it.startsWith("https://") || it.startsWith("http://") } ?: tab.url
        val title = page.title?.takeIf(String::isNotBlank) ?: tab.title
        update { it.copy(pageStates = it.pageStates + (tabId to page)) }
        if (url != tab.url || title != tab.title) editSpace(space.id) { it.copy(tabs = it.tabs.map { old -> if (old.id == tabId) old.copy(url = url, title = title) else old }) }
        if (url != tab.url) { observeActivity(tabId); persist() }
        if (!tab.isPrivate && !space.isPrivate && !page.loading && page.progress >= 1f && page.error == null && url != "about:blank" && recorded[tabId] != url) {
            recorded[tabId] = url
            update(persist = true) { state ->
                val previous = state.history.firstOrNull { it.syncedKey == null && it.url == url }
                state.copy(history = (listOf(BrowserVisit(url, title, now(), (previous?.count ?: 0) + 1)) + state.history.filterNot { it.syncedKey == null && it.url == url }).take(10_000))
            }
        }
    }

    fun pageActivity(tabId: String) {
        val space = mutableState.value.spaces.firstOrNull { it.tabs.any { tab -> tab.id == tabId } } ?: return
        editSpace(space.id) { it.copy(tabs = it.tabs.map { tab -> if (tab.id == tabId) tab.copy(lastActiveAt = now()) else tab }) }
        observeActivity(tabId); persist()
    }

    fun back(): Boolean {
        val current = mutableState.value
        if (current.find != null) { dismissFind(); return true }
        if (current.surface != BrowserSurface.PAGE) { dismissSurface(); return true }
        if (current.privateContentBlocked) { current.spaces.firstOrNull { !it.isPrivate }?.let { selectSpace(it.id) }; return true }
        val tab = current.tab ?: return false
        if (current.page.canGoBack) { engine.goBack(tab.id); return true }
        val opener = tab.openerId?.let { id -> current.space?.tabs?.firstOrNull { it.id == id } }
        if (opener != null) { closeTab(tab.id); selectTab(opener.id); return true }
        return false
    }

    fun forward() { mutableState.value.tab?.let { if (mutableState.value.page.canGoForward) engine.goForward(it.id) } }
    fun backItems(): List<BrowserBackItem> = mutableState.value.takeUnless { it.privateContentBlocked }?.tab?.let { engine.backItems(it.id) }.orEmpty()
    fun goBackTo(tabId: String, item: BrowserBackItem) {
        val current = mutableState.value
        if (current.privateContentBlocked || current.tab?.id != tabId || current.surface != BrowserSurface.PAGE) return
        if (!engine.goBackTo(tabId, item)) message("The page history changed. Open Back again.")
    }
    fun reloadOrStop() { mutableState.value.tab?.let { if (mutableState.value.page.loading) engine.stop(it.id) else engine.reload(it.id) } }
    fun reader() { mutableState.value.tab?.let { if (!engine.setReader(it.id, !mutableState.value.page.readerEnabled)) message("Reader isn't available on this page") } }
    fun beginFind(text: String = "") {
        val current = mutableState.value
        val tab = current.tab ?: return
        val profile = current.space?.websiteProfile ?: return
        if (current.privateContentBlocked || current.surface != BrowserSurface.PAGE || tab.isBlank) return
        dismissFind()
        update { it.copy(find = BrowserFindState(tab.id, profile, tab.url)) }
        runFind(BrowserFindQuery(text.take(1024)), BrowserFindDirection.START)
    }

    fun find(text: String) {
        val current = mutableState.value.find ?: run { beginFind(text); return }
        val query = current.query.copy(text = text.take(1024))
        if (query != current.query || current.failed) runFind(query, BrowserFindDirection.START)
    }

    fun findNext(backwards: Boolean = false) {
        val current = mutableState.value.find ?: return
        if (current.searching || current.failed || current.query.text.isEmpty() || current.result.total == 0) return
        runFind(current.query, if (backwards) BrowserFindDirection.PREVIOUS else BrowserFindDirection.NEXT)
    }

    fun findOptions(matchCase: Boolean, wholeWord: Boolean) {
        val current = mutableState.value.find ?: return
        val query = current.query.copy(matchCase = matchCase, wholeWord = wholeWord)
        if (query != current.query) runFind(query, BrowserFindDirection.START)
    }

    fun dismissFind() {
        val old = mutableState.value.find ?: return
        findGeneration++
        update { it.copy(find = null) }
        engine.clearFind(old.tab)
    }

    private fun runFind(query: BrowserFindQuery, direction: BrowserFindDirection) {
        val owner = mutableState.value.find ?: return
        val generation = ++findGeneration
        update { it.copy(find = owner.copy(query = query, searching = query.text.isNotEmpty(), failed = false)) }
        if (!engine.find(owner.tab, query, direction) { result ->
            if (generation == findGeneration && mutableState.value.find?.let { it.tab == owner.tab && it.profile == owner.profile && it.url == owner.url } == true) {
                if (result == null) dismissFind()
                else update { it.copy(find = it.find?.copy(result = result, searching = false)) }
            }
        }) {
            if (generation == findGeneration) {
                engine.clearFind(owner.tab)
                update { it.copy(find = it.find?.copy(searching = false, failed = true)) }
            }
        }
    }
    fun zoom(factor: Double) { mutableState.value.tab?.let { if (!engine.setZoom(it.id, factor)) message("Page zoom isn't available") } }
    fun desktop(enabled: Boolean) { mutableState.value.tab?.let { if (!engine.setDesktop(it.id, enabled)) message("Desktop mode isn't available") } }

    fun openBeside(tabId: String) {
        val current = mutableState.value
        val front = current.tab ?: return
        val other = current.space?.tabs?.firstOrNull { it.id == tabId } ?: return
        if (!workspaceSplitAllowed() || front.id == other.id || front.isPrivate || other.isPrivate || current.space?.isPrivate == true) return
        update { it.copy(workspace = BrowserWorkspace(front.id, other.id, other.id)) }
        selectTab(other.id)
    }

    /** Legacy headless callers cannot override a registered Activity's source. */
    fun resizeWorkspace(expanded: Boolean) { if (!mutableWorkspaceWindow.value.registered) workspaceExpanded = expanded }

    /** Call at Activity creation and before super.onConfigurationChanged, even for a coalesced ABA. */
    fun invalidateWorkspaceWindow() {
        val old = mutableWorkspaceWindow.value
        workspaceMenu = null
        tabletPageEntry = null
        mutableWorkspaceWindow.value = WorkspaceWindowState(true, old.configuration + 1, old.generation + 1)
    }

    /** A stale composition cannot revalidate a window invalidated by a later configuration. */
    fun commitWorkspaceWindow(configuration: Long, geometry: BrowserWorkspaceWindow): Boolean {
        val old = mutableWorkspaceWindow.value
        if (!old.registered || old.configuration != configuration) return false
        if (!geometry.valid) {
            if (old.geometry != null) {
                workspaceMenu = null
                tabletPageEntry = null
                mutableWorkspaceWindow.value = old.copy(generation = old.generation + 1, geometry = null)
            }
            return false
        }
        if (old.geometry != geometry) {
            workspaceMenu = null
            tabletPageEntry = null
            mutableWorkspaceWindow.value = old.copy(generation = old.generation + 1, geometry = geometry)
        }
        workspaceExpanded = geometry.expanded
        return true
    }

    private fun tabletPageTarget(current: BrowserState): TabletPageTarget? {
        val space = current.space ?: return null
        return current.tab?.let { TabletPageTarget.Tab(it.id, it.url, it.isPrivate) }
            ?: TabletPageTarget.Empty.takeIf { space.currentTabId == null }
    }

    private fun tabletPageEntryStateCurrent(lease: TabletPageEntryLease, current: BrowserState): Boolean =
        !current.loading && !current.privateContentBlocked && current.surface == BrowserSurface.PAGE && current.find == null &&
            current.surfaceEpoch == lease.surfaceEpoch && current.selectedSpaceId == lease.space &&
            current.space?.websiteProfile == lease.profile && current.space?.isPrivate == lease.privateSpace &&
            current.workspace == lease.workspace && tabletPageTarget(current) == lease.target

    /** Capture once for one rendered toolbar, shared by its controls. Metadata-only updates keep
     * the same capability; a changed target is retired before publication, even through an ABA. */
    fun captureTabletPageEntry(smallestScreenWidthDp: Int): TabletPageEntryLease? {
        val current = mutableState.value
        val window = mutableWorkspaceWindow.value
        val geometry = window.geometry
        val lifetime = settingsLifetime.value
        val target = tabletPageTarget(current)
        val space = current.space
        if (!window.registered || geometry == null || !BrowserTabletOmniboxGeometry.eligible(geometry, smallestScreenWidthDp) ||
            !lifetime.active || current.loading || current.privateContentBlocked || current.surface != BrowserSurface.PAGE ||
            current.find != null || target == null || space == null) {
            tabletPageEntry = null
            return null
        }
        tabletPageEntry?.takeIf { it.smallestScreenWidthDp == smallestScreenWidthDp && tabletPageEntryCurrent(it) }?.let { return it }
        return TabletPageEntryLease(localOwnership, lifetime.generation, lifetime.privateBoundary, historyLifetime.value,
            window.generation, smallestScreenWidthDp, current.surfaceEpoch, space.id, space.websiteProfile,
            space.isPrivate, target, current.workspace).also { tabletPageEntry = it }
    }

    fun tabletPageEntryCurrent(lease: TabletPageEntryLease): Boolean = tabletPageEntry === lease &&
        lease.ownership == localOwnership && settingsLifetime.value.let {
            it.active && it.generation == lease.foreground && it.privateBoundary == lease.privateBoundary
        } && historyLifetime.value == lease.sourceGeneration && mutableWorkspaceWindow.value.let {
            it.registered && it.generation == lease.windowGeneration && it.geometry?.let { geometry ->
                BrowserTabletOmniboxGeometry.eligible(geometry, lease.smallestScreenWidthDp)
            } == true
        } && tabletPageEntryStateCurrent(lease, mutableState.value)

    /** Local Field entry only. The caller must first check its captured Activity/account/native
     * boundary; an anchor supplies geometry, never authority or a replacement selected page. */
    fun openTabletAddress(lease: TabletPageEntryLease, origin: FieldAnchor? = null): Boolean {
        if (!tabletPageEntryCurrent(lease) || origin?.valid() == false) return false
        tabletPageEntry = null
        openField(newTab = lease.target == TabletPageTarget.Empty, origin = origin)
        return true
    }

    private fun tabletSidebarPageStateCurrent(lease: TabletSidebarPageLease, current: BrowserState): Boolean =
        !current.loading && !current.privateContentBlocked && current.surface == BrowserSurface.PAGE && current.find == null &&
            current.surfaceEpoch == lease.surfaceEpoch && current.selectedSpaceId == lease.space.id &&
            !lease.space.isPrivate && current.space == lease.space && current.tab?.isPrivate != true &&
            tabletPageTarget(current) == lease.target && current.workspace == lease.workspace

    /** Selected-public-space PAGE admission, including portrait. Full-window split
     * permission is deliberately separate from ordinary sidebar commands. */
    fun captureTabletSidebarPage(smallestScreenWidthDp: Int): TabletSidebarPageLease? {
        val current = mutableState.value
        val window = mutableWorkspaceWindow.value
        val lifetime = settingsLifetime.value
        val space = current.space
        val target = tabletPageTarget(current)
        if (!window.registered || window.geometry?.let { BrowserTabletOmniboxGeometry.eligible(it, smallestScreenWidthDp) } != true ||
            !lifetime.active || current.loading || current.privateContentBlocked || current.surface != BrowserSurface.PAGE ||
            current.find != null || space == null || space.isPrivate || current.tab?.isPrivate == true || target == null) {
            tabletSidebarPage = null
            return null
        }
        tabletSidebarPage?.takeIf { it.smallestScreenWidthDp == smallestScreenWidthDp && tabletSidebarPageCurrent(it) }?.let { return it }
        return TabletSidebarPageLease(localOwnership, lifetime.generation, lifetime.privateBoundary, historyLifetime.value,
            sidebarRevision.value, window.generation, smallestScreenWidthDp, current.surfaceEpoch, space, target,
            current.workspace).also { tabletSidebarPage = it }
    }

    fun tabletSidebarPageCurrent(lease: TabletSidebarPageLease): Boolean {
        val current = mutableState.value
        return tabletSidebarPage === lease && lease.ownership == localOwnership && sidebarRevision.value == lease.revision &&
            historyLifetime.value == lease.sourceGeneration && settingsLifetime.value.let {
                it.active && it.generation == lease.foreground && it.privateBoundary == lease.privateBoundary
            } && mutableWorkspaceWindow.value.let {
                it.registered && it.generation == lease.windowGeneration && it.geometry?.let { geometry ->
                    BrowserTabletOmniboxGeometry.eligible(geometry, lease.smallestScreenWidthDp)
                } == true
            } && tabletSidebarPageStateCurrent(lease, current)
    }

    fun captureTabletSidebarTab(page: TabletSidebarPageLease, tab: BrowserTab): TabletSidebarActionLease? =
        if (tabletSidebarPageCurrent(page) && !tab.isPrivate && page.space.tabs.filter { it.id == tab.id }.singleOrNull() == tab)
            TabletSidebarActionLease(page, TabletSidebarTarget.Tab(tab)) else null

    fun captureTabletSidebarFolder(page: TabletSidebarPageLease, folder: BrowserFolder): TabletSidebarActionLease? =
        if (tabletSidebarPageCurrent(page) && page.space.folders.filter { it.id == folder.id }.singleOrNull() == folder)
            TabletSidebarActionLease(page, TabletSidebarTarget.Folder(folder)) else null

    fun captureTabletSidebarClearToday(page: TabletSidebarPageLease): TabletSidebarActionLease? =
        if (tabletSidebarPageCurrent(page)) TabletSidebarActionLease(page, TabletSidebarTarget.ClearToday) else null

    fun captureTabletSidebarNewTab(page: TabletSidebarPageLease): TabletSidebarActionLease? =
        if (tabletSidebarPageCurrent(page)) TabletSidebarActionLease(page, TabletSidebarTarget.NewTab) else null

    fun tabletSidebarActionCurrent(lease: TabletSidebarActionLease): Boolean = !lease.consumed &&
        tabletSidebarPageCurrent(lease.page) && when (val target = lease.target) {
            is TabletSidebarTarget.Tab -> !target.tab.isPrivate &&
                lease.page.space.tabs.filter { it.id == target.tab.id }.singleOrNull() == target.tab
            is TabletSidebarTarget.Folder -> lease.page.space.folders.filter { it.id == target.folder.id }.singleOrNull() == target.folder
            TabletSidebarTarget.ClearToday, TabletSidebarTarget.NewTab -> true
        }

    fun selectTabletSidebarTab(lease: TabletSidebarActionLease): Boolean {
        val target = lease.target as? TabletSidebarTarget.Tab ?: return false
        if (!tabletSidebarActionCurrent(lease)) return false
        lease.consumed = true
        selectTab(target.tab.id)
        return true
    }

    fun toggleTabletSidebarFolder(lease: TabletSidebarActionLease): Boolean {
        val target = lease.target as? TabletSidebarTarget.Folder ?: return false
        if (!tabletSidebarActionCurrent(lease)) return false
        lease.consumed = true
        toggleFolder(lease.page.space.id, target.folder.id)
        return true
    }

    fun clearTabletSidebarToday(lease: TabletSidebarActionLease): Boolean {
        if (lease.target != TabletSidebarTarget.ClearToday || !tabletSidebarActionCurrent(lease)) return false
        lease.consumed = true
        clearToday()
        return true
    }

    fun newTabletSidebarTab(lease: TabletSidebarActionLease): Boolean {
        if (lease.target != TabletSidebarTarget.NewTab || !tabletSidebarActionCurrent(lease)) return false
        lease.consumed = true
        openField(newTab = true)
        return true
    }

    private fun workspaceSplitAllowed(): Boolean = if (mutableWorkspaceWindow.value.registered)
        settingsLifetime.value.active && mutableWorkspaceWindow.value.geometry?.canSplit == true && mutableState.value.let {
            !it.loading && !it.privateContentBlocked && it.find == null && it.space?.isPrivate == false && it.tab?.isPrivate == false &&
                it.surface in setOf(BrowserSurface.PAGE, BrowserSurface.FIELD, BrowserSurface.SPACES) &&
                (it.surface != BrowserSurface.FIELD || !it.fieldIsPrivate)
        } else workspaceExpanded

    fun captureWorkspaceEntry(): WorkspaceEntryLease? {
        val current = mutableState.value
        val space = current.space ?: return null
        val front = current.tab ?: return null
        val window = mutableWorkspaceWindow.value
        if (!window.registered || !workspaceSplitAllowed()) return null
        val lifetime = settingsLifetime.value
        return WorkspaceEntryLease(localOwnership, lifetime.generation, lifetime.privateBoundary, historyLifetime.value,
            window.generation, space.id, space.websiteProfile, front, current.surface, current.surfaceEpoch, current.workspace)
            .takeIf { workspaceEntryCurrent(it) }
    }

    private fun workspaceEntryStateCurrent(lease: WorkspaceEntryLease, current: BrowserState): Boolean =
        !current.loading && !current.privateContentBlocked && current.find == null &&
            (current.surface != BrowserSurface.FIELD || !current.fieldIsPrivate) &&
            current.surface in setOf(BrowserSurface.PAGE, BrowserSurface.FIELD, BrowserSurface.SPACES) &&
            current.surface == lease.surface && current.surfaceEpoch == lease.epoch &&
            current.selectedSpaceId == lease.space && current.space?.websiteProfile == lease.profile &&
            current.space?.isPrivate == false && !lease.front.isPrivate && current.tab?.let {
                it.id == lease.front.id && it.url == lease.front.url && it.isPrivate == lease.front.isPrivate
            } == true && current.workspace == lease.workspace

    fun workspaceEntryCurrent(lease: WorkspaceEntryLease): Boolean = workspaceSplitAllowed() &&
        mutableWorkspaceWindow.value.registered && mutableWorkspaceWindow.value.generation == lease.windowGeneration &&
        lease.owner == localOwnership && settingsLifetime.value.let { it.active && it.generation == lease.foreground && it.privateBoundary == lease.privateBoundary } &&
        historyLifetime.value == lease.sourceGeneration && workspaceEntryStateCurrent(lease, mutableState.value)

    fun captureWorkspaceActions(entry: WorkspaceEntryLease, target: BrowserTab? = null): WorkspaceActionLease? {
        if (!workspaceEntryCurrent(entry) || target?.let { it.isPrivate || mutableState.value.space?.tabs?.firstOrNull { row -> row.id == it.id } != it } == true) return null
        return WorkspaceActionLease(entry, target).also { workspaceMenu = it }
    }

    fun workspaceActionsCurrent(lease: WorkspaceActionLease): Boolean = workspaceMenu === lease &&
        workspaceEntryCurrent(lease.entry) && lease.target?.let { target -> mutableState.value.space?.tabs?.firstOrNull { it.id == target.id } == target } != false

    fun openBeside(tabId: String, lease: WorkspaceActionLease) {
        if (!workspaceActionsCurrent(lease) || lease.target?.id != tabId) return
        workspaceMenu = null; openBeside(tabId)
    }
    fun newTabBeside(lease: WorkspaceActionLease) { if (workspaceActionsCurrent(lease)) { workspaceMenu = null; newTabBeside() } }
    fun closeWorkspacePage(lease: WorkspaceActionLease) { if (workspaceActionsCurrent(lease)) { workspaceMenu = null; closeWorkspacePage() } }
    fun fullSpread(lease: WorkspaceActionLease) { if (workspaceActionsCurrent(lease)) { workspaceMenu = null; fullSpread() } }

    fun newTabBeside() {
        val current = mutableState.value
        val front = current.tab ?: return
        if (!workspaceSplitAllowed() || front.isPrivate || current.space?.isPrivate == true) return
        val tab = BrowserTab(id = newId(), createdAt = now())
        editSpace(current.selectedSpaceId) { it.copy(tabs = listOf(tab) + it.tabs, currentTabId = tab.id) }
        update { it.copy(workspace = BrowserWorkspace(front.id, tab.id, tab.id, newPage = tab.id)) }
        touch(tab.id, current.selectedSpaceId)
        activate()
        openField()
    }

    fun closeWorkspacePage() { if (workspaceSplitAllowed()) mutableState.value.tab?.id?.let(::closeTab) }

    fun fullSpread() { if (workspaceSplitAllowed()) update { it.copy(workspace = null) } }

    fun suggestions(query: String): List<BrowserSuggestion> {
        val current = mutableState.value
        if (query.isBlank() || current.fieldIsPrivate || (current.surface != BrowserSurface.FIELD && current.space?.isPrivate == true)) return emptyList()
        val text = query.trim().lowercase()
        val tabs = current.spaces.filterNot(BrowserSpace::isPrivate).flatMap { space ->
            space.tabs.filter { !it.isPrivate && !it.isBlank && (it.title.lowercase().contains(text) || it.url.lowercase().contains(text)) }
                .map { BrowserSuggestion(it.title, "${space.name} · ${it.host}", tabId = it.id, url = it.url) }
        }
        val open = tabs.mapTo(mutableSetOf(), BrowserSuggestion::url)
        val visits = current.history.filter { it.url !in open && (it.title.lowercase().contains(text) || it.url.lowercase().contains(text)) }
            .map { BrowserSuggestion(it.title, it.host, url = it.url) }
        return (tabs + visits).take(8)
    }

    companion object {
        const val PRIVATE_SPACE = "private"
        const val PERSONAL_SPACE = "00000000-0000-0000-0000-000000000001"
        const val NEW_TAB_DRAFT = "new-tab"
        const val UNDO_MILLIS = 6_000L
        const val TWELVE_HOURS = 43_200_000L
    }
}

data class BrowserSuggestion(val title: String, val subtitle: String, val tabId: String? = null, val url: String)

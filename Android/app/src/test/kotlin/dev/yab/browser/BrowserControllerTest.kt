package dev.yab.browser

import dev.yab.browser.model.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CompletableDeferred
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BrowserControllerTest {
    @Test fun keepAppendsAfterMixedRowsAndCloseUndoReturnsToItsOriginalRow() = runTest {
        val a = BrowserTab("a", "https://a.test", "Before", TabPlace.KEPT, createdAt = 1)
        val b = BrowserTab("b", "https://b.test", "After", TabPlace.KEPT, createdAt = 2)
        val today = BrowserTab("today", "https://today.test", "Today", createdAt = 3)
        val space = BrowserSpace("s", "Personal", tabs = listOf(a, b, today), currentTabId = a.id,
            folders = listOf(BrowserFolder("f", "Folder")), keptOrder = listOf("tab:a", "folder:f", "tab:b"))
        val browser = BrowserController(Repository(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)), Engine(), backgroundScope)
        runCurrent()
        fun keys() = BrowserKeptTree.rows(checkNotNull(browser.state.value.space)).map { it.key }
        browser.keepTab(today.id)
        assertEquals(listOf("tab:a", "folder:f", "tab:b", "tab:today"), keys())
        browser.unkeepTab(a.id); browser.keepTab(a.id)
        assertEquals(listOf("folder:f", "tab:b", "tab:today", "tab:a"), keys())
        browser.closeTab(b.id)
        assertEquals(listOf("folder:f", "tab:today", "tab:a"), keys())
        browser.undoClose()
        assertEquals(listOf("folder:f", "tab:b", "tab:today", "tab:a"), keys())
        browser.pinTab(b.id); browser.unpinTab(b.id); browser.keepTab(b.id)
        assertEquals(listOf("folder:f", "tab:today", "tab:a", "tab:b"), keys())
    }
    private class Repository(var value: BrowserSnapshot? = null, val broken: Boolean = false) : BrowserRepository {
        var writes = 0
        override suspend fun load(): BrowserSnapshot? { if (broken) error("corrupt bytes"); return value }
        override suspend fun save(snapshot: BrowserSnapshot) { value = snapshot; writes++ }
    }

    private class Engine : BrowserEngine {
        val navigated = mutableListOf<Pair<BrowserTab, WebsiteProfile>>()
        val activated = mutableListOf<Pair<BrowserTab, WebsiteProfile>>()
        val closed = mutableListOf<String>()
        val events = mutableListOf<String>()
        val endedPrivate = mutableListOf<WebsiteProfile>()
        val forgottenPardons = mutableListOf<String>()
        var onEndPrivate: ((WebsiteProfile) -> Unit)? = null
        var onActivate: (() -> Unit)? = null
        var back: String? = null
        var useMementos = false
        var restoreGate: CompletableDeferred<Unit>? = null
        private data class Memory(val tab: String, val profile: WebsiteProfile) : BrowserPageMemento
        val restored = mutableListOf<String>()
        val released = mutableListOf<BrowserPageMemento>()
        override fun captureForUndo(tab: BrowserTab, profile: WebsiteProfile): BrowserPageMemento? =
            if (useMementos) Memory(tab.id, profile) else null
        override suspend fun restoreForUndo(tab: BrowserTab, profile: WebsiteProfile, memory: BrowserPageMemento, isCurrent: () -> Boolean): Boolean {
            restoreGate?.await()
            if (!isCurrent() || memory != Memory(tab.id, profile)) return false
            restored += tab.id; events += "restore:${tab.id}"
            return true
        }
        override fun releaseUndo(memory: BrowserPageMemento) { released += memory }
        override fun activate(tab: BrowserTab, profile: WebsiteProfile) { activated += tab to profile; events += "activate:${tab.id}"; onActivate?.invoke() }
        override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) { navigated += tab to profile; events += "navigate:${tab.id}" }
        override fun goBack(tabId: String) { back = tabId }
        override fun goForward(tabId: String) {}
        override fun reload(tabId: String) {}
        override fun stop(tabId: String) {}
        override fun close(tabId: String) { closed += tabId }
        override fun endPrivateSession(profile: WebsiteProfile) {
            endedPrivate += profile; events += "end:${profile.id}"; onEndPrivate?.invoke(profile)
        }
        override fun forgetWebsitePardons(profile: String) { forgottenPardons += profile }
        override suspend fun clearWebsiteData(profileIds: Set<String>) {}
    }

    @Test fun privateStateNeverEntersSnapshotOrVisitsAndCannotActivateBeforeUnlock() = runTest {
        val repository = Repository()
        val engine = Engine()
        var id = 0
        val controller = BrowserController(repository, engine, backgroundScope, now = { 100L }, newId = { "id-${id++}" })
        runCurrent()
        controller.openUrl("https://private.example/secret", privately = true)
        val tab = controller.state.value.tab!!
        assertTrue(controller.state.value.privateContentBlocked)
        assertTrue(engine.navigated.isEmpty())
        controller.unlockPrivate(true)
        assertEquals(BrowserSpace.PRIVATE_PROFILE, engine.activated.last().second.id)
        controller.pageChanged(tab.id, EnginePageState(url = tab.url, title = "Secret", progress = 1f))
        runCurrent()
        assertTrue(controller.state.value.history.isEmpty())
        assertTrue(repository.value!!.spaces.none { it.isPrivate || it.tabs.any(BrowserTab::isPrivate) })
        assertFalse(repository.value!!.toString().contains("private.example"))
        controller.backgrounded()
        assertTrue(controller.state.value.privateContentBlocked)
    }

    @Test fun closingLastPrivateCardEndsSessionAfterRemovalAndUndoRetainsCardMetadata() = runTest {
        val engine = Engine()
        val controller = BrowserController(Repository(), engine, backgroundScope)
        runCurrent()
        controller.updateSettings(controller.state.value.settings.copy(lockPrivate = false))
        controller.openUrl("https://private.example/first", privately = true)
        val first = controller.state.value.tab!!
        controller.openUrl("https://private.example/second", privately = true)
        val second = controller.state.value.tab!!
        val profile = controller.state.value.space!!.websiteProfile
        engine.onEndPrivate = { ended ->
            assertEquals(profile, ended)
            assertTrue(controller.state.value.spaces.none { it.websiteProfile == ended && it.tabs.isNotEmpty() })
            assertTrue(engine.closed.containsAll(listOf(first.id, second.id)))
        }
        controller.closeTab(first.id)
        assertTrue(engine.endedPrivate.isEmpty())
        controller.closeTab(second.id)
        assertEquals(listOf(profile), engine.endedPrivate)
        controller.undoClose(); runCurrent()
        assertEquals(second, controller.state.value.tab)
        assertEquals(profile, engine.activated.last().second)
        assertFalse(controller.state.value.undoAvailable)
        assertEquals(listOf(profile), engine.endedPrivate)
    }

    @Test fun closingPublicCardDoesNotEndPrivateSession() = runTest {
        val engine = Engine()
        val controller = BrowserController(Repository(), engine, backgroundScope)
        runCurrent()
        val publicId = controller.state.value.tab!!.id
        controller.closeTab(publicId)
        assertTrue(engine.endedPrivate.isEmpty())
    }

    @Test fun publicExternalEntryDoesNotInheritPrivateCookies() = runTest {
        val repository = Repository()
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.openUrl("https://private.example", privately = true)
        controller.unlockPrivate(true)
        controller.openExternalUrl("https://public.example")
        assertFalse(controller.state.value.tab!!.isPrivate)
        assertEquals(BrowserSpace.SHARED_PROFILE, engine.navigated.last().second.id)
        assertFalse(engine.navigated.last().second.isPrivate)
    }

    @Test fun newTabEyesOffReturnsToLastOrdinarySpaceWhilePrivateAddressEyesOffStaysPrivate() = runTest {
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(BrowserTab("personal-tab", "https://personal.example", createdAt = 1)), currentTabId = "personal-tab")
        val work = BrowserSpace("work", "Work", ownSignIns = true, tabs = listOf(BrowserTab("work-tab", "https://work.example", createdAt = 1)), currentTabId = "work-tab")
        val repository = Repository(BrowserSnapshot(spaces = listOf(personal, work), selectedSpaceId = "work"))
        val engine = Engine()
        val browser = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        browser.openUrl("https://private.example/original", privately = true); browser.unlockPrivate(true)
        val privateId = browser.state.value.tab!!.id
        browser.openField()
        assertTrue(browser.state.value.fieldIsPrivate)
        browser.fieldPrivacy(false)
        assertFalse(browser.state.value.fieldIsPrivate)
        assertEquals("work", browser.state.value.space!!.id)
        browser.fieldText("https://ordinary.example/new"); browser.submitField()
        assertFalse(browser.state.value.tab!!.isPrivate)
        assertEquals("space-work", engine.navigated.last().second.id)
        assertNotEquals("work-tab", browser.state.value.tab!!.id)
        assertEquals("work", browser.publicSnapshot()!!.selectedSpaceId)

        browser.selectTab(privateId); browser.unlockPrivate(true)
        assertEquals("work", browser.publicSnapshot()!!.selectedSpaceId)
        browser.openField(newTab = false)
        assertFalse(browser.state.value.fieldPrivate)
        assertTrue(browser.state.value.fieldPagePrivate && browser.state.value.fieldIsPrivate)
        browser.fieldPrivacy(true); browser.fieldPrivacy(false)
        browser.fieldText("https://private.example/edited"); browser.submitField()
        assertEquals(privateId, browser.state.value.tab!!.id)
        assertTrue(engine.navigated.last().second.isPrivate)
        browser.pageChanged(privateId, EnginePageState(url = "https://private.example/edited", title = "Private", progress = 1f))
        assertTrue(browser.state.value.history.none { it.url.contains("private.example") })
        runCurrent()
        assertFalse(repository.value.toString().contains("private.example"))
        browser.openField(newTab = false); browser.fieldText("private unsent words"); browser.dismissSurface()
        browser.selectSpace("work"); browser.openField()
        assertFalse(browser.state.value.fieldText.contains("private unsent"))
    }

    @Test fun privateEyesFromAddressCreatesNewPrivateTabAndChangedAddressOwnerCancels() = runTest {
        val engine = Engine()
        val browser = BrowserController(Repository(), engine, backgroundScope)
        runCurrent()
        browser.openUrl("https://private.example/kept", privately = true); browser.unlockPrivate(true)
        val oldPrivate = browser.state.value.tab!!
        val ordinary = browser.state.value.spaces.first { !it.isPrivate }.id
        browser.selectSpace(ordinary)
        val public = browser.state.value.tab!!
        browser.openField(newTab = false); browser.fieldText(""); browser.fieldPrivacy(true)
        browser.fieldText("https://private.example/new"); browser.submitField()
        assertTrue(browser.state.value.tab!!.isPrivate)
        assertNotEquals(oldPrivate.id, browser.state.value.tab!!.id)
        assertEquals(oldPrivate.url, browser.state.value.space!!.tabs.first { it.id == oldPrivate.id }.url)
        assertEquals(public.url, browser.state.value.spaces.first { it.id == ordinary }.tabs.first { it.id == public.id }.url)

        browser.unlockPrivate(true); browser.openField(newTab = false)
        browser.fieldText("https://private.example/must-not-publish")
        browser.selectSpace(ordinary)
        val calls = engine.navigated.size
        browser.submitField()
        assertEquals(calls, engine.navigated.size)
        assertFalse(browser.state.value.spaces.filterNot(BrowserSpace::isPrivate).toString().contains("must-not-publish"))
        assertEquals("", browser.state.value.fieldText)
    }

    @Test fun keepExternalAddressSavesPubliclyWithoutOpeningOrChangingPrivateSelection() = runTest {
        val repository = Repository()
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        val publicSelection = controller.state.value.tab!!.id
        controller.openUrl("https://private.example/secret", privately = true)
        val privateSelection = controller.state.value.tab!!.id
        engine.activated.clear(); engine.navigated.clear(); engine.events.clear()
        assertTrue(controller.keepExternalUrl("https://later.example/story"))
        assertTrue(controller.keepExternalUrl("https://later.example/story"))
        assertEquals(privateSelection, controller.state.value.tab!!.id)
        assertTrue(controller.state.value.space!!.isPrivate)
        assertTrue(controller.state.value.history.isEmpty())
        assertTrue(engine.events.isEmpty())
        assertTrue(engine.activated.isEmpty())
        assertTrue(engine.navigated.isEmpty())
        val public = controller.state.value.spaces.first { !it.isPrivate }
        assertEquals(publicSelection, public.currentTabId)
        val saved = public.tabs.single { it.place == TabPlace.KEPT }
        assertEquals("https://later.example/story", saved.url)
        assertFalse(saved.isPrivate)
        assertFalse(controller.keepExternalUrl("javascript:alert(1)"))
        assertFalse(controller.keepExternalUrl("about:blank"))
        assertFalse(controller.keepExternalUrl("file:///tmp/secret"))
        runCurrent()
        assertFalse(repository.value.toString().contains("private.example"))

        val restored = BrowserController(Repository(repository.value), Engine(), backgroundScope)
        runCurrent()
        assertEquals(publicSelection, restored.state.value.tab!!.id)
        assertEquals(saved, restored.state.value.space!!.tabs.single { it.place == TabPlace.KEPT })
        assertTrue(restored.state.value.history.isEmpty())
        assertTrue(restored.state.value.spaces.none(BrowserSpace::isPrivate))
    }

    @Test fun keptNavigationCreatesTodayAndPreservesKeptAddress() = runTest {
        val kept = BrowserTab("kept", "https://kept.example", "Kept", place = TabPlace.KEPT, createdAt = 1L)
        val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Personal", tabs = listOf(kept), currentTabId = kept.id)), selectedSpaceId = "space"))
        val controller = BrowserController(repository, Engine(), backgroundScope)
        runCurrent()
        controller.openUrl("https://new.example", newTab = false)
        val tabs = controller.state.value.space!!.tabs
        assertEquals("https://kept.example", tabs.first { it.id == "kept" }.url)
        assertEquals(TabPlace.TODAY, controller.state.value.tab!!.place)
        assertEquals(2, tabs.size)
    }

    @Test fun automaticClearRequiresLocalNativeSafetyAndProtectsMediaDraftAndCurrent() = runTest {
        val old = 1L
        val tabs = listOf(
            BrowserTab("front", createdAt = old),
            BrowserTab("safe", "https://safe.example", createdAt = old),
            BrowserTab("unknown", "https://unknown.example", createdAt = old),
            BrowserTab("media", "https://media.example", createdAt = old),
            BrowserTab("shared", "https://shared.example", createdAt = old, shared = true),
            BrowserTab("draft", "https://draft.example", createdAt = old, hasDraft = true),
        )
        val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Personal", tabs = tabs, currentTabId = "front")), selectedSpaceId = "space"))
        val engine = Engine()
        var clock = TabActivityClock(1L, 1L, 7)
        val controller = BrowserController(repository, engine, backgroundScope, now = { clock.wall }, activityClock = { clock })
        runCurrent()
        tabs.forEach { controller.pageActivity(it.id) }
        clock = TabActivityClock(BrowserController.TWELVE_HOURS + 100L, BrowserController.TWELVE_HOURS + 100L, 7)
        controller.pageChanged("safe", EnginePageState(safeToClear = true))
        controller.pageChanged("shared", EnginePageState(safeToClear = true))
        controller.pageChanged("media", EnginePageState(playingMedia = true, safeToClear = true))
        controller.clearToday(automatic = true)
        assertEquals(listOf("safe"), engine.closed)
        assertEquals(listOf("front", "unknown", "media", "shared", "draft"), controller.state.value.space!!.tabs.map(BrowserTab::id))
        controller.undoClose()
        assertEquals(tabs.map(BrowserTab::id), controller.state.value.space!!.tabs.map(BrowserTab::id))
    }

    @Test fun undoRestoresNativeMemoryBeforeFrontAndRecencyAndRejectsInvalidatedAsyncOwner() = runTest {
        val tabs = listOf(BrowserTab("front", "https://front.example", createdAt = 1L), BrowserTab("other", "https://other.example", createdAt = 1L))
        val saved = BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Space", tabs = tabs, currentTabId = "front")), selectedSpaceId = "space", recency = mapOf("space" to listOf("front", "other")))
        val engine = Engine().apply { useMementos = true }
        val controller = BrowserController(Repository(saved), engine, backgroundScope)
        runCurrent()
        controller.closeTab("front")
        assertEquals("other", controller.state.value.tab!!.id)
        controller.undoClose(); runCurrent()
        assertEquals("front", controller.state.value.tab!!.id)
        assertEquals(listOf("front", "other"), controller.state.value.recency["space"])
        assertEquals(listOf("front"), engine.restored)
        assertTrue(engine.events.indexOf("restore:front") < engine.events.lastIndexOf("activate:front"))

        engine.restoreGate = CompletableDeferred()
        controller.closeTab("front"); controller.undoClose(); runCurrent()
        controller.applySyncedSnapshot(saved.copy(spaces = saved.spaces.map { it.copy(tabs = listOf(tabs[1]), currentTabId = "other", ownSignIns = true) }))
        engine.restoreGate!!.complete(Unit); runCurrent()
        assertEquals(listOf("other"), controller.state.value.space!!.tabs.map(BrowserTab::id))
        assertEquals(listOf("front"), engine.restored)
        assertFalse(controller.state.value.undoAvailable)
    }

    @Test fun wallJumpAndUnknownRecoveredAgeCannotAutomaticallyDeleteTabs() = runTest {
        val tabs = listOf(BrowserTab("front", createdAt = 1L), BrowserTab("old", "https://old.example", createdAt = 1L))
        val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Space", tabs = tabs, currentTabId = "front")), selectedSpaceId = "space"))
        var clock = TabActivityClock(100L, 100L, 1)
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope, now = { clock.wall }, activityClock = { clock })
        runCurrent()
        controller.pageChanged("old", EnginePageState(safeToClear = true))
        clock = clock.copy(wall = clock.wall + BrowserController.TWELVE_HOURS + 1)
        controller.clearToday(automatic = true)
        assertTrue(engine.closed.isEmpty())
        controller.pageActivity("old")
        clock = clock.copy(wall = clock.wall + BrowserController.TWELVE_HOURS, elapsed = clock.elapsed + 1)
        controller.clearToday(automatic = true)
        assertTrue("A wall-clock jump authorized a premature close", engine.closed.isEmpty())
    }

    @Test fun sameBootControllerRecoveryKeepsLocalAgeAndPrivateActivityNeverEntersDiskOrSync() = runTest {
        val folder = Files.createTempDirectory("yab-controller-age").toFile()
        try {
            val tabs = listOf(BrowserTab("front", createdAt = 1L), BrowserTab("old", "https://old.example", createdAt = 1L))
            val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Space", tabs = tabs, currentTabId = "front")), selectedSpaceId = "space"))
            val file = folder.resolve("activity.json")
            val local = MemoryTabActivityRepository()
            var clock = TabActivityClock(100L, 100L, 7)
            val first = BrowserController(repository, Engine(), backgroundScope, now = { clock.wall }, activityClock = { clock }, activityRepository = local)
            runCurrent()
            first.pageActivity("old"); runCurrent()
            assertEquals(clock, local.load().getValue("old").clock)
            clock = clock.copy(wall = clock.wall + BrowserController.TWELVE_HOURS, elapsed = clock.elapsed + BrowserController.TWELVE_HOURS)
            val engine = Engine()
            val recovered = BrowserController(repository, engine, backgroundScope, now = { clock.wall }, activityClock = { clock }, activityRepository = local)
            runCurrent()
            recovered.pageChanged("old", EnginePageState(safeToClear = true))
            recovered.clearToday(automatic = true)
            assertEquals(listOf("old"), engine.closed)
            recovered.openUrl("https://private-age-secret.invalid", privately = true)
            recovered.unlockPrivate(true)
            recovered.pageActivity(recovered.state.value.tab!!.id)
            runCurrent()
            assertFalse(recovered.publicSnapshot().toString().contains("private-age-secret"))
            assertFalse(local.load().values.any { it.url.contains("private-age-secret") })
            FileTabActivityRepository(file).save(local.load())
            assertFalse(file.readText().contains("private-age-secret"))
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }

    @Test fun nativeBackPrecedesOpenerAndOpenerCloseCanBeUndone() = runTest {
        val tabs = listOf(BrowserTab("child", "https://child.example", openerId = "parent", createdAt = 1L), BrowserTab("parent", "https://parent.example", createdAt = 1L))
        val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Personal", tabs = tabs, currentTabId = "child")), selectedSpaceId = "space"))
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.pageChanged("child", EnginePageState(canGoBack = true))
        assertTrue(controller.back())
        assertEquals("child", engine.back)
        assertEquals("child", controller.state.value.tab!!.id)
        controller.pageChanged("child", EnginePageState(canGoBack = false))
        assertTrue(controller.back())
        assertEquals("parent", controller.state.value.tab!!.id)
        assertEquals(listOf("child"), engine.closed)
        controller.undoClose()
        assertEquals(2, controller.state.value.space!!.tabs.size)
    }

    @Test fun corruptedProfileIsNotReplacedByAnEmptyProfile() = runTest {
        val repository = Repository(broken = true)
        val controller = BrowserController(repository, Engine(), backgroundScope)
        runCurrent()
        controller.openUrl("https://new.example")
        assertFalse("A broken profile cannot accept a durable share-sheet save", controller.keepExternalUrl("https://later.example"))
        runCurrent()
        assertEquals(0, repository.writes)
        assertNotNull(controller.state.value.persistenceError)
    }

    @Test fun separateSignInsUseDurableNamespaceAndSwitchDoesNotCopyCookies() = runTest {
        val repository = Repository()
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.addSpace("Work")
        val id = controller.state.value.space!!.id
        controller.changeSignIns(id, true)
        controller.openUrl("https://account.example")
        assertEquals("space-$id", engine.navigated.last().second.id)
        controller.changeSignIns(id, false)
        assertEquals(BrowserSpace.SHARED_PROFILE, engine.activated.last().second.id)
        runCurrent()
        assertFalse(repository.value!!.spaces.first { it.id == id }.ownSignIns)
    }

    @Test fun aDeletedSpaceForgetsItsPardonsWhateverItsSignInSetting() = runTest {
        val engine = Engine()
        val controller = BrowserController(Repository(), engine, backgroundScope)
        runCurrent()
        controller.addSpace("Work")
        val id = controller.state.value.space!!.id
        // The space once had its own sign-ins, then went back to shared: its
        // old profile's decisions still went with it when it was deleted.
        controller.changeSignIns(id, true)
        controller.changeSignIns(id, false)
        controller.deleteSpace(id)
        assertTrue(engine.forgottenPardons.contains("space-$id"))
        // A space that never had its own sign-ins forgets too, harmlessly.
        controller.addSpace("Later")
        val later = controller.state.value.space!!.id
        controller.deleteSpace(later)
        assertTrue(engine.forgottenPardons.contains("space-$later"))
    }

    @Test fun syncImportPreservesPrivateMemoryAndNeverExportsIt() = runTest {
        val repository = Repository()
        val engine = Engine()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.openUrl("https://private.example", privately = true)
        controller.unlockPrivate(true)
        val privateId = controller.state.value.tab!!.id
        val public = BrowserSpace(BrowserController.PERSONAL_SPACE, "From Mac", tabs = listOf(BrowserTab("remote", "https://public.example", createdAt = 1L)), currentTabId = "remote")
        controller.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(public), selectedSpaceId = public.id))
        assertEquals(privateId, controller.state.value.tab!!.id)
        assertTrue(controller.state.value.space!!.isPrivate)
        assertFalse(engine.closed.contains(privateId))
        assertEquals(listOf(public), controller.publicSnapshot()!!.spaces)
        assertFalse(controller.publicSnapshot().toString().contains("private.example"))
    }

    @Test fun newlySelectedRemoteTabBecomesNativeOwnerBeforeNavigation() = runTest {
        val engine = Engine()
        val controller = BrowserController(Repository(), engine, backgroundScope)
        runCurrent()
        val oldId = controller.state.value.tab!!.id
        engine.activated.clear()
        engine.navigated.clear()
        engine.events.clear()
        val remote = BrowserTab("remote", "https://remote.example", createdAt = 1L)
        val space = BrowserSpace("remote-space", "From Mac", ownSignIns = true, tabs = listOf(remote), currentTabId = remote.id)
        controller.applySyncedSnapshot(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id))
        assertTrue(engine.closed.contains(oldId))
        assertEquals(remote.id, controller.state.value.tab!!.id)
        assertEquals(listOf(remote to space.websiteProfile), engine.activated)
        assertEquals(listOf(remote to space.websiteProfile), engine.navigated)
        assertEquals(listOf("activate:remote", "navigate:remote"), engine.events)
    }

    @Test fun closingKeptGalleryCardOnlyDropsLocalOpenMembership() = runTest {
        val kept = BrowserTab("kept", "https://kept.example", place = TabPlace.KEPT, createdAt = 1L)
        val today = BrowserTab("today", "https://today.example", createdAt = 1L)
        val repository = Repository(BrowserSnapshot(spaces = listOf(BrowserSpace("space", "Personal", tabs = listOf(kept, today), currentTabId = "kept")), selectedSpaceId = "space", recency = mapOf("space" to listOf("kept", "today"))))
        val controller = BrowserController(repository, Engine(), backgroundScope)
        runCurrent()
        controller.closeGalleryTab("kept")
        assertEquals(listOf(kept.id, today.id), controller.state.value.space!!.tabs.map(BrowserTab::id))
        assertEquals(listOf(today.id), controller.state.value.galleryTabs.map(BrowserTab::id))
        assertEquals(today.id, controller.state.value.tab!!.id)
        assertFalse(controller.state.value.undoAvailable)
    }

    @Test fun enginePopupReservesFreshTabInOpenersNamespaceWithoutLoadingIt() = runTest {
        val opener = BrowserTab("opener", "https://work.example", createdAt = 1L)
        val work = BrowserSpace("work", "Work", ownSignIns = true, tabs = listOf(opener), currentTabId = opener.id)
        val other = BrowserSpace("other", "Personal", tabs = listOf(BrowserTab("front", createdAt = 1L)), currentTabId = "front")
        val engine = Engine()
        val repository = Repository(BrowserSnapshot(spaces = listOf(work, other), selectedSpaceId = other.id))
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        val activations = engine.activated.size
        val popup = controller.createEngineTab("https://work.example/child", opener.id, background = true)!!
        assertEquals(work.websiteProfile, popup.second)
        assertEquals(listOf(opener.id, popup.first.id), controller.state.value.spaces.first { it.id == work.id }.tabs.map(BrowserTab::id))
        assertEquals(other.id, controller.state.value.selectedSpaceId)
        assertEquals(activations, engine.activated.size)
        assertTrue(engine.navigated.isEmpty())
        assertNull(controller.createEngineTab("https://example.com", "removed-opener"))
        assertNull(controller.createEngineTab("javascript:alert(1)", opener.id))
        assertNull(controller.createEngineTab("moz-extension://extension/options.html", opener.id))
    }

    @Test fun enginePopupCannotEscapeOrUnlockPrivateOpener() = runTest {
        val engine = Engine()
        val repository = Repository()
        val controller = BrowserController(repository, engine, backgroundScope)
        runCurrent()
        controller.openUrl("https://private.example", privately = true)
        val opener = controller.state.value.tab!!
        assertNull(controller.createEngineTab("about:blank", opener.id))
        controller.unlockPrivate(true)
        assertNull(controller.createEngineTab("https://public.example", opener.id, privately = false))
        val activations = engine.activated.size
        val popup = controller.createEngineTab("about:blank", opener.id)!!
        assertTrue(popup.first.isPrivate)
        assertEquals(WebsiteProfile(BrowserSpace.PRIVATE_PROFILE, isPrivate = true), popup.second)
        assertEquals(popup.first.id, controller.state.value.tab!!.id)
        assertEquals(activations, engine.activated.size)
        runCurrent()
        assertFalse(repository.value.toString().contains(popup.first.id))
    }
    @Test fun gallerySelectionActivatesOnlyItsCurrentUnlockedSpaceWithoutDismissingGallery() = runTest {
        val first = BrowserTab("first", "https://fixture.example/first", createdAt = 1)
        val second = BrowserTab("second", "https://fixture.example/second", createdAt = 2)
        val foreign = BrowserTab("foreign", "https://other.example/page", createdAt = 3)
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(first, second), currentTabId = first.id)
        val other = BrowserSpace("other", "Other", ownSignIns = true, tabs = listOf(foreign), currentTabId = foreign.id)
        val engine = Engine()
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(personal, other), selectedSpaceId = personal.id)), engine, backgroundScope)
        runCurrent()
        controller.show(BrowserSurface.PAGE)
        val page = controller.state.value
        val initialActivations = engine.activated.size
        assertFalse(controller.selectGalleryTab(second.id))
        assertEquals(page, controller.state.value)
        assertEquals(initialActivations, engine.activated.size)
        controller.show(BrowserSurface.GALLERY)
        val gallery = controller.state.value
        for (id in listOf("missing", foreign.id)) {
            assertFalse(controller.selectGalleryTab(id))
            assertEquals(gallery, controller.state.value)
            assertEquals(initialActivations, engine.activated.size)
        }
        assertTrue(controller.selectGalleryTab(second.id))
        assertEquals(BrowserSurface.GALLERY, controller.state.value.surface)
        assertTrue(controller.state.value.galleryClosing)
        assertEquals(personal.id, controller.state.value.selectedSpaceId)
        assertEquals(second.id, controller.state.value.tab!!.id)
        assertEquals(second.id, engine.activated.last().first.id)
        assertEquals(personal.websiteProfile, engine.activated.last().second)
        assertTrue(engine.navigated.isEmpty())

        controller.openUrl("https://private.example/fixture", privately = true)
        controller.show(BrowserSurface.GALLERY)
        assertTrue(controller.state.value.privateContentBlocked)
        val locked = controller.state.value
        val calls = engine.activated.size
        assertFalse(controller.selectGalleryTab(locked.tab!!.id))
        assertFalse(controller.selectGalleryTab(first.id))
        assertEquals(locked, controller.state.value)
        assertEquals(calls, engine.activated.size)
    }
    @Test fun galleryActivationCannotOverwriteAReentrantForeignSurface() = runTest {
        val first = BrowserTab("first", "https://fixture.example/first", createdAt = 1)
        val second = BrowserTab("second", "https://fixture.example/second", createdAt = 2)
        val space = BrowserSpace("personal", "Personal", tabs = listOf(first, second), currentTabId = first.id)
        val engine = Engine()
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)), engine, backgroundScope)
        runCurrent()
        controller.show(BrowserSurface.GALLERY)
        engine.onActivate = { controller.show(BrowserSurface.SETTINGS) }
        assertFalse(controller.selectGalleryTab(second.id))
        assertEquals(second.id, engine.activated.last().first.id)
        assertEquals(BrowserSurface.SETTINGS, controller.state.value.surface)
        val current = controller.state.value
        assertFalse(controller.selectGalleryTab(first.id))
        assertEquals(current, controller.state.value)
    }
    @Test fun delayedGalleryCompletionRequiresTheSamePresentationAndChosenPage() = runTest {
        val first = BrowserTab("first", "https://fixture.example/first", createdAt = 1)
        val second = BrowserTab("second", "https://fixture.example/second", createdAt = 2)
        val space = BrowserSpace("personal", "Personal", tabs = listOf(first, second), currentTabId = first.id)
        val engine = Engine()
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)), engine, backgroundScope)
        runCurrent()
        controller.show(BrowserSurface.GALLERY)
        val oldEpoch = controller.state.value.surfaceEpoch
        assertTrue(controller.selectGalleryTab(second.id, oldEpoch))

        controller.show(BrowserSurface.SETTINGS)
        val settings = controller.state.value
        assertFalse(settings.galleryClosing)
        assertFalse(controller.finishGallery(space.id, oldEpoch, second.id))
        assertEquals(settings, controller.state.value)
        controller.show(BrowserSurface.GALLERY)
        val fresh = controller.state.value
        assertFalse(fresh.galleryClosing)
        assertNotEquals(oldEpoch, fresh.surfaceEpoch)
        val activations = engine.activated.size
        assertFalse(controller.selectGalleryTab(first.id, oldEpoch))
        assertFalse(controller.finishGallery(space.id, oldEpoch, second.id))
        assertEquals(fresh, controller.state.value)
        assertEquals(activations, engine.activated.size)

        assertTrue(controller.selectGalleryTab(first.id, fresh.surfaceEpoch))
        val selected = controller.state.value
        assertFalse(controller.finishGallery(space.id, fresh.surfaceEpoch, second.id))
        assertEquals(selected, controller.state.value)
        assertTrue(controller.finishGallery(space.id, fresh.surfaceEpoch, first.id))
        assertEquals(BrowserSurface.PAGE, controller.state.value.surface)
        assertFalse(controller.state.value.galleryClosing)
        assertEquals(first.id, controller.state.value.tab!!.id)
    }
    @Test fun delayedGalleryCompletionCannotCloseAnotherSpaceOrLockedPrivateGallery() = runTest {
        val first = BrowserTab("first", "https://fixture.example/first", createdAt = 1)
        val foreign = BrowserTab("foreign", "https://other.example/page", createdAt = 2)
        val personal = BrowserSpace("personal", "Personal", tabs = listOf(first), currentTabId = first.id)
        val other = BrowserSpace("other", "Other", ownSignIns = true, tabs = listOf(foreign), currentTabId = foreign.id)
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(personal, other), selectedSpaceId = personal.id)), Engine(), backgroundScope)
        runCurrent()
        controller.show(BrowserSurface.GALLERY)
        val epoch = controller.state.value.surfaceEpoch
        controller.selectSpace(other.id)
        val changedSpace = controller.state.value
        assertFalse(controller.finishGallery(personal.id, epoch, null))
        assertEquals(changedSpace, controller.state.value)
        assertTrue(controller.finishGallery(other.id, epoch, null))

        controller.openUrl("https://private.example/fixture", privately = true)
        controller.show(BrowserSurface.GALLERY)
        val locked = controller.state.value
        assertTrue(locked.privateContentBlocked)
        assertFalse(controller.finishGallery(locked.selectedSpaceId!!, locked.surfaceEpoch, locked.tab!!.id))
        assertEquals(locked, controller.state.value)
    }

    @Test fun identityRevocationClosesTheOldFieldAndCannotRestoreItsSavedDraft() = runTest {
        val tab = BrowserTab("account-page", "https://fixture.example/page", createdAt = 1)
        val space = BrowserSpace("personal", "Personal", tabs = listOf(tab), currentTabId = tab.id)
        val controller = BrowserController(Repository(BrowserSnapshot(spaces = listOf(space), selectedSpaceId = space.id)), Engine(), backgroundScope)
        runCurrent()
        controller.openField(newTab = false)
        controller.fieldText("the old identity draft")
        controller.dismissSurface()
        controller.openField(newTab = false)
        assertEquals("the old identity draft", controller.state.value.fieldText)
        val epoch = controller.state.value.surfaceEpoch
        controller.invalidateLocalOwnership()
        assertEquals(BrowserSurface.PAGE, controller.state.value.surface)
        assertTrue(controller.state.value.surfaceEpoch > epoch)
        assertEquals(tab.id, controller.state.value.tab?.id)
        assertTrue(controller.state.value.fieldText.isEmpty())
        controller.openField(newTab = false)
        assertEquals(tab.url, controller.state.value.fieldText)
        controller.show(BrowserSurface.SPACES)
        controller.invalidateLocalOwnership()
        assertEquals(BrowserSurface.PAGE, controller.state.value.surface)
    }
}

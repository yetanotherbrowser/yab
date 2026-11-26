package dev.yab.browser

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.browser.model.*
import dev.yab.browser.ui.BrowserScreen
import dev.yab.browser.ui.BrowserChromeClipping
import dev.yab.browser.ui.LocalBrowserChromeClipping
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The plate's own numbers reach the engine seam as the fold animates, and unmounting clears them. */
class BrowserChromeClippingDeviceTest {
    @get:Rule val compose = createComposeRule()

    private class Harness {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val tab = BrowserTab("clip-tab", "https://clip.test", createdAt = 1)
        val snapshot = BrowserSnapshot(spaces = listOf(BrowserSpace("clip-space", "Clip", tabs = listOf(tab), currentTabId = tab.id)), selectedSpaceId = "clip-space")
        val repository = object : BrowserRepository {
            override suspend fun load() = snapshot
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(repository, engine, scope)
        val reported = mutableListOf<Pair<String?, BrowserChromeClipping>>()
    }

    private fun composeHarness(harness: Harness, fullscreen: androidx.compose.runtime.MutableState<Boolean>) =
        compose.setContent {
            CompositionLocalProvider(LocalBrowserChromeClipping provides { owner, clip -> harness.reported.add(owner to clip) }) {
                BrowserScreen(controller = harness.browser, fullscreen = fullscreen.value) { _, _, modifier -> Box(modifier.fillMaxSize()) }
            }
        }

    @Test fun theFoldDrivesTheCoveredHeightPerFrameAndFullscreenClearsIt() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val harness = Harness()
        val browser = harness.browser
        val reported = harness.reported
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val fullscreen = mutableStateOf(false)
        try {
            compose.mainClock.autoAdvance = false
            composeHarness(harness, fullscreen)
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.waitUntil(10_000) { reported.isNotEmpty() }
            compose.mainClock.advanceTimeByFrame()
            // The unfolded plate: full reservation covered, named by its pane's tab.
            val open = reported.last().second
            assertTrue("The chrome never reported", reported.isNotEmpty())
            assertEquals("clip-tab", reported.last().first)
            assertEquals(open.maxPx, open.obscuredPx)
            assertTrue("The reservation is not a plate-sized number: ${open.maxPx}", open.maxPx >= (76f * density * 0.9f).toInt())

            // A user scroll folds the plate; each animation frame moves the covered height.
            val beforeFold = reported.size
            compose.runOnIdle { browser.pageChanged("clip-tab", browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
            compose.mainClock.advanceTimeByFrame()
            compose.mainClock.advanceTimeByFrame()
            val midFold = reported.drop(beforeFold).map { it.second }
            assertTrue("The fold reported no intermediate covered height", midFold.size >= 2)
            assertTrue("The fold never decreased the covered height",
                midFold.zipWithNext().any { (a, b) -> b.obscuredPx < a.obscuredPx && b.maxPx == a.maxPx })
            repeat(30) { compose.mainClock.advanceTimeByFrame() }
            val folded = reported.last().second
            assertTrue("The folded pill did not reclaim bottom space: ${folded.obscuredPx}",
                folded.obscuredPx < open.obscuredPx)
            assertTrue("The fold changed the reservation", folded.maxPx == open.maxPx)
            assertTrue("The covered part never dropped below the reservation",
                folded.obscuredPx < folded.maxPx)
            // The folded report covers the touch target, not just the drawn capsule:
            // capsule = plateBottom + 31 dp, touch target reaches 8.5 dp above that.
            val capsuleCovered = (16f * density).toInt() + (31f * density).toInt()
            assertTrue("The folded report lost the touch target's strip: ${folded.obscuredPx}",
                folded.obscuredPx > capsuleCovered)

            // Unfolding returns to the full reservation, without a spurious clear.
            val beforeUnfold = reported.size
            compose.runOnIdle { browser.pageChanged("clip-tab", browser.state.value.page.copy(scrollY = 100f, userScrollY = 100f)) }
            repeat(30) { compose.mainClock.advanceTimeByFrame() }
            assertEquals("Unfolding did not restore the full covered height", open, reported.last().second)
            assertFalse("Unfolding emitted a phantom clear",
                reported.drop(beforeUnfold).map { it.second }.any { it == BrowserChromeClipping.none })

            // Fullscreen unmounts the chrome: the engine is told nothing is covered.
            compose.runOnIdle { fullscreen.value = true }
            compose.mainClock.advanceTimeByFrame()
            compose.waitUntil(10_000) { reported.last().second == BrowserChromeClipping.none }
        } finally {
            compose.mainClock.autoAdvance = true
            harness.scope.cancel()
        }
    }

    /** The maintainer's tap test: in the strip above the folded capsule, a tap
     * opens the address field (the plate's touch target owns the strip), and
     * the report already covers the strip so the page knows it is covered. */
    @Test fun theTouchTargetsStripAboveTheFoldedCapsuleIsReportedAndClickable() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val harness = Harness()
        val browser = harness.browser
        val reported = harness.reported
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val fullscreen = mutableStateOf(false)
        try {
            compose.mainClock.autoAdvance = false
            composeHarness(harness, fullscreen)
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.waitUntil(10_000) { reported.isNotEmpty() }
            // Fold the plate, then settle the fold animation.
            compose.runOnIdle { browser.pageChanged("clip-tab", browser.state.value.page.copy(scrollY = 120f, userScrollY = 120f)) }
            repeat(30) { compose.mainClock.advanceTimeByFrame() }
            val folded = reported.last().second
            val capsuleCovered = (16f * density).toInt() + (31f * density).toInt()
            assertTrue("The folded report must cover the touch target", folded.obscuredPx > capsuleCovered)
            // A tap on the plate (the capsule's own test tag) opens the field.
            compose.onNodeWithTag("browser.chrome.plate").performClick()
            compose.waitUntil(10_000) { browser.state.value.surface == BrowserSurface.FIELD }
        } finally {
            compose.mainClock.autoAdvance = true
            harness.scope.cancel()
        }
    }
}

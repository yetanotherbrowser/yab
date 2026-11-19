package dev.yab.browser

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.agent.*
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Real Settings routes over an inert page engine, without accounts or external writes. */
class SettingsParityFixtureTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private fun shot(name: String) {
        compose.waitForIdle()
        android.os.SystemClock.sleep(500)
        val i = InstrumentationRegistry.getInstrumentation()
        val folder = File(i.targetContext.getExternalFilesDir(null), "instrumentation/catalog-fixtures").apply { mkdirs() }
        val bitmap = checkNotNull(i.uiAutomation.takeScreenshot())
        File(folder, "parity-$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        File(folder, "parity-$name.json").writeText("""{"kind":"production-component-fixture","reference":"iphone-0.1.13","screen":"$name","pageEngine":"inert","externalActions":false}""")
    }
    @Test fun aboutNamesTheEngineAndNoSwitchExistsAnywhere() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
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
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load(): BrowserSnapshot? = BrowserSnapshot(spaces = listOf(BrowserSpace("parity", "Personal")), selectedSpaceId = "parity", settings = BrowserSettings(appearance = BrowserAppearance.LIGHT))
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
        val agent = AgentRepository(object : ChatPersistence {
            override suspend fun load() = ChatSnapshot()
            override suspend fun save(snapshot: ChatSnapshot) = Unit
        }, UnavailableLocalAiAdapter(), DisconnectedRemoteTransport)
        runBlocking { agent.load() }
        try {
            compose.setContent {
                val state by browser.state.collectAsState()
                ParitySystemBars(state.settings.appearance)
                BrowserScreen(browser, onSyncSettings = {}, aiSettingsContent = { current -> AiSettings(agent, null, {}, current) },
                pageContent = { _, _, modifier -> Box(modifier) }) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
            compose.onNodeWithTag("settings.search").performTextInput("engine")
            compose.onNodeWithText("About").performClick()
            compose.onNodeWithText("Engine", substring = false).assertExists()
            compose.onNodeWithText("Gecko", substring = false).assertExists()
            shot("about.engine")
            compose.onNodeWithText("chromium").assertDoesNotExist()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithTag("settings.search").performTextClearance()
            compose.onNodeWithText("Chromium").assertDoesNotExist()
        } finally {
            scope.cancel()
        }
    }

    @Test fun settingsRootAndAppearanceUsePhoneDesignAndKeepNavigation() {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
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
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load(): BrowserSnapshot? = BrowserSnapshot(spaces = listOf(BrowserSpace("parity", "Personal")), selectedSpaceId = "parity", settings = BrowserSettings(appearance = BrowserAppearance.LIGHT, autoClearToday = true))
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, scope)
        val agent = AgentRepository(object : ChatPersistence {
            override suspend fun load() = ChatSnapshot()
            override suspend fun save(snapshot: ChatSnapshot) = Unit
        }, UnavailableLocalAiAdapter(), DisconnectedRemoteTransport)
        runBlocking { agent.load() }
        try {
            compose.setContent {
                val state by browser.state.collectAsState()
                ParitySystemBars(state.settings.appearance)
                BrowserScreen(browser, onSyncSettings = {}, aiSettingsContent = { current -> AiSettings(agent, null, {}, current) },
                pageContent = { _, _, modifier -> Box(modifier) }) }
            compose.waitUntil(10_000) { !browser.state.value.loading }
            compose.runOnIdle { browser.show(BrowserSurface.SETTINGS) }
            compose.onNodeWithTag("settings.search").assertExists()
            compose.onNodeWithText("App Icon").assertExists()
            shot("settings.1")
            compose.onNodeWithText("App Icon", substring = false).performClick()
            compose.onNodeWithTag("settings.appIcon.gallery").assertExists()
            shot("settings.page-appIcon")
            compose.onNodeWithTag("settings.appIcon.theme.dark").performClick()
            shot("settings.page-appIcon-dark-preview")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Appearance").performClick()
            compose.onNodeWithText("Darken Websites").assertExists()
            shot("settings.page-appearance")
            compose.onNodeWithText("Dark", useUnmergedTree = true).performClick()
            shot("settings.page-appearance-dark")
            compose.onNodeWithContentDescription("Back").performClick()
            shot("settings.1-dark")
            compose.onNodeWithText("General").performClick()
            compose.onNodeWithText("Swipe from Anywhere").assertExists()
            shot("settings.page-general-dark")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Tabs", substring = false).performClick()
            shot("settings.page-tabs-dark")
            compose.onNodeWithText("Today", substring = false).performClick()
            shot("settings.page-today-dark")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Private Tabs", substring = false).performClick()
            shot("settings.page-privateTabs-dark")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("AI", substring = false).performScrollTo().performClick()
            shot("settings.page-ai-dark")
            for ((title, key) in listOf("About a page" to "aboutPage", "Everything else" to "everythingElse", "Agent" to "agent")) {
                compose.onNodeWithText(title, substring = false).performClick()
                shot("settings.page-$key-dark")
                compose.onNodeWithContentDescription("Back").performClick()
            }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("App Icon", substring = false).performScrollTo().performClick()
            shot("settings.page-appIcon-dark")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Appearance").performClick()
            compose.onNodeWithText("Light", useUnmergedTree = true).performClick()
            compose.runOnIdle { assertEquals(BrowserAppearance.LIGHT, browser.state.value.settings.appearance) }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Tabs", substring = false).performClick()
            compose.onNodeWithText("Private Tabs", substring = false).assertExists()
            shot("settings.page-tabs")
            compose.onNodeWithText("Today", substring = false).performClick()
            compose.onNodeWithText("Clear after 12 hours", substring = false).assertExists()
            shot("settings.page-today")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Private Tabs", substring = false).performClick()
            compose.onNodeWithText("Lock Private Tabs", substring = false).assertExists()
            compose.onNodeWithText("Not kept", substring = false).assertExists()
            shot("settings.page-privateTabs")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("AI", substring = false).performScrollTo().performClick()
            compose.onNodeWithText("Everything else", substring = false).assertExists()
            shot("settings.page-ai")
            compose.onNodeWithText("About a page", substring = false).performClick()
            compose.onNodeWithText("Your Mac", substring = false).assertExists()
            shot("settings.page-aboutPage")
            compose.onNodeWithText("Your Mac", substring = false).performClick()
            compose.runOnIdle { assertEquals(PageAnswerMode.MAC, agent.state.value.preferences.pageAnswers) }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Everything else", substring = false).performClick()
            compose.onNodeWithText("On your Mac", substring = false).assertExists()
            shot("settings.page-everythingElse")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("Agent", substring = false).performClick()
            compose.onNodeWithText("Claude", substring = false).assertExists()
            compose.onNodeWithText("ChatGPT", substring = false).assertExists()
            compose.onNodeWithText("Cursor", substring = false).assertDoesNotExist()
            shot("settings.page-agent")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithTag("settings.search").performTextReplacement("appearance")
            compose.onNodeWithText("Appearance").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithTag("settings.search").assertTextContains("appearance")
        } finally { scope.cancel() }
    }
}

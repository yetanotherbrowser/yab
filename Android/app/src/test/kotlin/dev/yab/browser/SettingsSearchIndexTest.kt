package dev.yab.browser

import dev.yab.browser.model.*
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test

class SettingsSearchIndexTest {
    private val available = SettingsSearchAvailability(sync = true, extensions = true,
        systemSettings = true, credentialsSettings = true, feedback = true, reports = true)
    private val spaces = listOf(BrowserSpace("personal", "Personal"), BrowserSpace("work", "Research"),
        BrowserSpace("private", "Never expose this private name", isPrivate = true))
    private fun pages(settings: BrowserSettings = BrowserSettings(), availability: SettingsSearchAvailability = available) =
        SettingsSearchIndex.pages(settings, spaces, availability, listOf("Flat", "Watercolor Glass", "Red Enamel"), "0.1.0", "3")
    private fun matches(query: String, catalog: List<SettingsSearchPage> = pages()) = SettingsSearchIndex.matches(query, catalog, Locale.ENGLISH)

    @Test fun pageNamesWinAndExplicitHistoryOpensItsRealPageWithoutAnAction() {
        val result = matches("history")
        assertEquals(SettingsSearchMatch(SettingsPage.HISTORY), result.first())
        assertEquals(SettingsPage.APPEARANCE, matches("appearance").single().page)
        assertNull(matches("appearance").single().row)
        assertEquals(SettingsPage.TABS, matches("tabs").first().page)
        assertEquals(result.size, result.map { it.page }.toSet().size)
    }

    @Test fun firstActualRowWinsOverBroadKeywordsAndEveryTokenMustMatchAPrefix() {
        assertEquals(SettingsRowId.appearance(BrowserAppearance.DARK), matches("  DARK ").single().row?.id)
        assertEquals(SettingsRowId.DARKEN_WEBSITES, matches("web, dArK").single().row?.id)
        assertEquals(SettingsRowId.AUTO_CLEAR, matches("12 clear").single().row?.id)
        assertEquals(SettingsRowId.BLOCK_ADS, matches("ads").single().row?.id)
        assertEquals(SettingsRowId.CLEAR_DATA, matches("website data").single().row?.id)
        assertTrue(matches("ark").isEmpty())
        assertTrue(matches("dark unrelated").isEmpty())
    }

    @Test fun blankAndPunctuationOnlyQueriesDoNotPretendToBeSearchHits() {
        listOf("", "  \n", "---", "???", "notarealsetting").forEach { assertTrue(it, matches(it).isEmpty()) }
        assertEquals(listOf(SettingsPage.GENERAL, SettingsPage.SEARCH, SettingsPage.APPEARANCE, SettingsPage.APP_ICON), pages().take(4).map { it.page })
    }

    @Test fun rowValuesAndExistingNestedSpaceDestinationsAreIndexedButPrivateNamesAreNot() {
        val research = matches("research").single()
        assertEquals(SettingsPage.SPACES, research.page)
        assertEquals("work", research.row?.spaceId)
        assertEquals("Research", research.row?.title)
        val deletion = matches("delete space").single()
        assertEquals("work", deletion.row?.spaceId)
        assertEquals(SettingsRowId.space("work", "delete"), deletion.row?.id)
        assertEquals(SettingsRowId.space("personal", "signIns"), matches("sign ins").single().row?.id)
        assertTrue(pages().flatMap { it.rows }.none { it.spaceId == "private" || it.title.contains("Never expose") })
        assertTrue(matches("never expose").isEmpty())
    }

    @Test fun onlyReachableOptionalPagesAndActuallyVisibleReportSwitchesExist() {
        val hidden = pages(availability = SettingsSearchAvailability())
        assertFalse(hidden.any { it.page in setOf(SettingsPage.SYNC, SettingsPage.EXTENSIONS, SettingsPage.FEEDBACK) })
        assertTrue(matches("recovery", hidden).isEmpty())
        assertTrue(matches("xpi", hidden).isEmpty())
        assertTrue(matches("crash", hidden).isEmpty())
        assertTrue(matches("daily", hidden).isEmpty())
        assertTrue(hidden.flatMap { it.rows }.none { it.id in setOf(SettingsRowId.PASSWORD_SETTINGS, SettingsRowId.AUTOFILL_SETTINGS) })
        assertEquals(SettingsRowId.CRASHES, matches("crash").single().row?.id)
        assertEquals(SettingsRowId.ACTIVITY, matches("daily").single().row?.id)
        val recovery = matches("recovery").single()
        assertEquals(SettingsPage.SYNC, recovery.page)
        assertNull("A search must not fabricate a direct key reveal route", recovery.row)
    }

    @Test fun validCustomEngineAndRealIconChoicesUseTheirRenderedWords() {
        assertTrue(pages().first { it.page == SettingsPage.SEARCH }.rows.none { it.title == "Other" })
        val custom = pages(BrowserSettings(customSearchTemplate = "https://search.test/?q=%s"))
        assertEquals(SettingsRowId.engine(SearchEngine.CUSTOM), matches("other", custom).single().row?.id)
        val icon = matches("red enamel").single()
        assertEquals(SettingsPage.APP_ICON, icon.page); assertEquals("Red Enamel", icon.row?.title)
        assertEquals(SettingsRowId.VERSION, matches("version").single().row?.id)
    }

    @Test fun engineRowAppearsOnlyWithTheChromiumForkAndCarriesTheStoredChoice() {
        assertFalse(pages().any { it.page == SettingsPage.ENGINE })
        assertTrue(matches("chromium").isEmpty())
        assertTrue(matches("gecko").isEmpty())
        val withFork = available.copy(chromium = true)
        val catalog = pages(availability = withFork)
        assertEquals(listOf(SettingsPage.GENERAL, SettingsPage.SEARCH, SettingsPage.APPEARANCE, SettingsPage.APP_ICON, SettingsPage.ENGINE, SettingsPage.TABS),
            catalog.take(6).map { it.page })
        val gecko = matches("default engine", catalog).single()
        assertEquals(SettingsPage.ENGINE, gecko.page)
        assertEquals(SettingsRowId.ENGINE, gecko.row?.id)
        assertEquals("Gecko", gecko.row?.value)
        assertEquals(SettingsRowId.ENGINE, matches("gecko", catalog).single().row?.id)
        val chromiumChoice = pages(BrowserSettings(engineKind = BrowserEngineKind.CHROMIUM), withFork)
        assertEquals("Chromium", matches("default engine", chromiumChoice).single().row?.value)
        assertEquals(SettingsRowId.ENGINE, matches("chromium", chromiumChoice).single().row?.id)
        assertEquals(listOf(SettingsPage.ENGINE, SettingsPage.SEARCH), matches("engine", catalog).map { it.page })
    }

    @Test fun unicodeWordPrefixesWorkAndOrderingIsPagesBeforeRowsThenByPageTitle() {
        val unicode = SettingsSearchIndex.pages(BrowserSettings(), listOf(BrowserSpace("greek", "Σχολή")), available)
        assertEquals("greek", matches("ΣΧΟ", unicode).single().row?.spaceId)
        val hits = matches("android")
        assertEquals(listOf(SettingsPage.AUTOFILL, SettingsPage.GENERAL, SettingsPage.PASSWORDS), hits.map { it.page })
        assertTrue(hits.all { it.row != null })
        val ordered = matches("android", listOf(
            SettingsSearchPage(SettingsPage.PASSWORDS, listOf(SettingsSearchRow("passwords", "Managed by Android"))),
            SettingsSearchPage(SettingsPage.HISTORY, keywords = "android"),
            SettingsSearchPage(SettingsPage.AUTOFILL, listOf(SettingsSearchRow("autofill", "Managed by Android")))))
        assertEquals(listOf(SettingsPage.HISTORY, SettingsPage.AUTOFILL, SettingsPage.PASSWORDS), ordered.map { it.page })
        assertNull(ordered.first().row)
    }
}

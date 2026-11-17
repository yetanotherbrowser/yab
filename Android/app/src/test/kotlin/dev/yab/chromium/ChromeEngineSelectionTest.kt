package dev.yab.chromium

import dev.yab.browser.model.BrowserEngineKind
import dev.yab.browser.model.BrowserSettings
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class ChromeEngineSelectionTest {
    @Test fun geckoIsAlwaysChoosable() {
        val gate = ChromeEngineSelection(forkPresent = false)
        assertEquals(BrowserEngineKind.GECKO, gate.choose(BrowserEngineKind.CHROMIUM, BrowserEngineKind.GECKO))
    }

    @Test fun chromiumNeedsTheFork() {
        val gate = ChromeEngineSelection(forkPresent = false)
        assertNull(gate.choose(BrowserEngineKind.GECKO, BrowserEngineKind.CHROMIUM))
    }

    @Test fun chromiumIsChoosableWhenTheForkIsPresent() {
        val gate = ChromeEngineSelection(forkPresent = true)
        assertEquals(BrowserEngineKind.CHROMIUM, gate.choose(BrowserEngineKind.GECKO, BrowserEngineKind.CHROMIUM))
    }

    @Test fun aChoiceAlreadyInForceChangesNothing() {
        val gate = ChromeEngineSelection(forkPresent = true)
        assertNull(gate.choose(BrowserEngineKind.CHROMIUM, BrowserEngineKind.CHROMIUM))
        assertNull(gate.choose(BrowserEngineKind.GECKO, BrowserEngineKind.GECKO))
    }

    @Test fun aStoredChromiumChoiceDegradesToGeckoWithoutTheFork() {
        assertEquals(BrowserEngineKind.GECKO, ChromeEngineSelection(forkPresent = false).effective(BrowserEngineKind.CHROMIUM))
        assertEquals(BrowserEngineKind.CHROMIUM, ChromeEngineSelection(forkPresent = true).effective(BrowserEngineKind.CHROMIUM))
        assertEquals(BrowserEngineKind.GECKO, ChromeEngineSelection(forkPresent = false).effective(BrowserEngineKind.GECKO))
    }

    @Test fun preUpgradeCheckpointsDecodeAsGecko() {
        val preUpgrade = """{"appearance":"SYSTEM","searchEngine":"GOOGLE","customSearchTemplate":"","blocksAds":true,""" +
            """"darkenWebsites":false,"autoClearToday":false,"lockPrivate":true,"welcomed":false,"syncHistory":true,""" +
            """"macTabs":false,"swipeAnywhere":true,"openKeyboardAtLaunch":true}"""
        val settings = Json.decodeFromString<BrowserSettings>(preUpgrade)
        assertEquals(BrowserEngineKind.GECKO, settings.engineKind)
    }

    @Test fun aDefaultCheckpointOmitsTheEngineField() {
        val encoded = Json.encodeToString(BrowserSettings())
        assertFalse(encoded.contains("engineKind"))
        val explicit = Json.encodeToString(BrowserSettings(engineKind = BrowserEngineKind.CHROMIUM))
        assertTrue(explicit.contains("engineKind"))
    }
}

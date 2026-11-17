package dev.yab.chromium

import dev.yab.browser.model.BrowserEngineKind

/**
 * The engine-switch gate. A Chromium choice is accepted only while the fork is
 * present and the Chrome owner lifecycle is reachable; Gecko stays accepted
 * everywhere because it is the shipped default engine.
 *
 * Both engines are process-wide singletons (GeckoRuntime, Chrome browser
 * process), so a switch takes effect on the next app start, never mid-run:
 * [choose] validates and persists the choice, [effective] maps the stored
 * choice through presence at launch, and a fork that disappeared since the
 * choice was made falls back to Gecko instead of starting a broken launch.
 */
class ChromeEngineSelection(private val forkPresent: Boolean) {
    /** True when the choice changed; a refused Chromium choice never mutates the stored settings. */
    fun choose(current: BrowserEngineKind, wanted: BrowserEngineKind): BrowserEngineKind? {
        if (current == wanted) return null
        if (wanted == BrowserEngineKind.CHROMIUM && !forkPresent) return null
        return wanted
    }

    /** The engine this launch actually runs: a stored Chromium choice without the fork degrades to Gecko. */
    fun effective(stored: BrowserEngineKind): BrowserEngineKind =
        if (stored == BrowserEngineKind.CHROMIUM && !forkPresent) BrowserEngineKind.GECKO else stored
}

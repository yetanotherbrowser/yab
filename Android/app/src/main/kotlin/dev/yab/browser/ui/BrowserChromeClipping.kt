package dev.yab.browser.ui

import androidx.compose.runtime.staticCompositionLocalOf
import kotlin.math.roundToInt

/**
 * The bottom space the chrome covers, measured from the pane's bottom edge.
 * The covered part is the plate's mounted 48 dp touch target, whose top edge
 * sits above the drawn capsule, never the capsule alone. An engine clips that
 * space so a page's own bottom-fixed things (a site's tab bar, a chat field)
 * stay visible and tappable above the plate. The pair is engine-independent:
 * GeckoView turns it into its toolbar-relative number (Fenix contract), a
 * Chromium engine into its browser-controls offset.
 */
internal data class BrowserChromeClipping(val obscuredPx: Int, val maxPx: Int) {

    companion object {
        /** Nothing reserved and nothing covered (fullscreen, no chrome mounted). */
        val none = BrowserChromeClipping(0, 0)

        /**
         * The plate's covered height and the fully unfolded chrome's covered
         * height, both from the pane's bottom edge, in this device's px.
         * [plateBottomDp]/[plateHeightDp] are the drawn capsule's own numbers;
         * the covered part is the capsule's mounted 48 dp touch target, raised
         * above the capsule by half the difference, with the layout's own
         * integer px outset. [unfoldedBottomDp]/[unfoldedHeightDp] are the
         * fully unfolded plate's numbers.
         */
        fun from(plateBottomDp: Float, plateHeightDp: Float, unfoldedBottomDp: Float, unfoldedHeightDp: Float,
            density: Float, paneHeightPx: Int): BrowserChromeClipping {
            require(plateBottomDp.isFinite() && plateBottomDp >= 0f)
            require(plateHeightDp.isFinite() && plateHeightDp >= 0f)
            require(unfoldedBottomDp.isFinite() && unfoldedBottomDp >= 0f)
            require(unfoldedHeightDp.isFinite() && unfoldedHeightDp >= 0f)
            require(density.isFinite() && density > 0f)
            require(paneHeightPx >= 0)
            fun covered(bottom: Float, height: Float) =
                (bottom * density).roundToInt() + (height * density).roundToInt()
            val max = covered(unfoldedBottomDp, unfoldedHeightDp).coerceIn(0, paneHeightPx)
            val plateBottomPx = (plateBottomDp * density).roundToInt()
            val plateHeightPx = (plateHeightDp * density).roundToInt()
            // The mounted target is always 48 dp tall; the drawn capsule sits
            // centered in it, offset down by the integer half, as the plate's
            // own layout does. A drawing taller than the target covers alone.
            val targetPx = (48f * density).roundToInt()
            val outsetPx = ((targetPx - plateHeightPx) / 2).coerceAtLeast(0)
            val obscured = (plateBottomPx - outsetPx + maxOf(targetPx, plateHeightPx)).coerceIn(0, paneHeightPx)
            return BrowserChromeClipping(obscured, max)
        }
    }
}

/** Each report names the pane that owns it (its tab id): a split's panes
 * keep separate numbers, and a clear reaches only the reporting pane. */
internal val LocalBrowserChromeClipping = staticCompositionLocalOf<((owner: String?, clip: BrowserChromeClipping) -> Unit)?> { null }

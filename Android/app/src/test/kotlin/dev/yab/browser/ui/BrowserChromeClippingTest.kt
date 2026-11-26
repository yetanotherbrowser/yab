package dev.yab.browser.ui

import kotlin.math.roundToInt
import org.junit.Assert.*
import org.junit.Test

/** The numbers an engine reserves so a page's own bottom bar stays above Yab's plate. */
class BrowserChromeClippingTest {
    private val density = 2.75f

    /** The unfolded plate: 48 dp tall, 28 dp above the pane's bottom edge. */
    private val unfolded = BrowserChromeClipping((76 * density).toInt(), (76 * density).toInt())
    /** The folded capsule: 31 dp tall, 16 dp above the pane's bottom edge, but
     * its mounted 48 dp touch target reaches 55.5 dp up the pane. */
    private val folded = BrowserChromeClipping((55.5 * density).toInt(), (76 * density).toInt())

    @Test fun unfoldedChromeCoversExactlyItsReservation() {
        assertEquals(unfolded.maxPx, unfolded.obscuredPx)
        // The engine layer derives its toolbar-relative number from this pair.
        assertEquals(0, unfolded.obscuredPx - unfolded.maxPx)
    }

    @Test fun foldedPillCoversLessThanTheReservationItKeeps() {
        // The fold reclaims bottom space without shrinking the reservation:
        // the pair stays engine-independent, only the covered part moves.
        assertEquals(unfolded.maxPx, folded.maxPx)
        assertTrue(folded.obscuredPx < unfolded.obscuredPx)
        assertTrue(folded.obscuredPx - folded.maxPx < 0)
    }

    @Test fun missingChromeReservesNothingAndCoversNothing() {
        assertEquals(0, BrowserChromeClipping.none.obscuredPx)
        assertEquals(0, BrowserChromeClipping.none.maxPx)
    }

    @Test fun geometryMatchesThePlateNumbersAtTheDeviceDensity() {
        val clip = BrowserChromeClipping.from(plateBottomDp = 16f, plateHeightDp = 31f,
            unfoldedBottomDp = 28f, unfoldedHeightDp = 48f, density = 2.625f, paneHeightPx = 2220)
        // The drawn capsule covers 42 + 81 = 123, but the mounted 48 dp target
        // tops 22 px above it (the integer half of 126 - 81): 42 - 22 + 126,
        // 55.5 dp up the pane. The reservation stays 74 + 126 = 200.
        assertEquals(146, clip.obscuredPx)
        assertEquals(200, clip.maxPx)
        assertEquals(-54, clip.obscuredPx - clip.maxPx)
    }

    @Test fun theFoldedReportCoversTheTouchTargetsStripAboveTheCapsule() {
        // The plate's clickable target is 48 dp tall through the whole fold;
        // the drawn capsule is 31 dp. The report must cover the 8.5 dp strip
        // above the capsule, or a page's own bar loses taps there to the plate.
        val clip = BrowserChromeClipping.from(16f, 31f, 28f, 48f, 2.625f, 2220)
        val capsuleCoveredPx = (16f * 2.625f).roundToInt() + (31f * 2.625f).roundToInt()
        assertTrue("The report lost the touch box's strip: ${clip.obscuredPx} vs $capsuleCoveredPx",
            clip.obscuredPx > capsuleCoveredPx)
        assertEquals(((55.5f * 2.625f).roundToInt()), clip.obscuredPx)
    }

    @Test fun anOversizedPlateNeverClaimsMoreThanThePane() {
        val clip = BrowserChromeClipping.from(plateBottomDp = 20f, plateHeightDp = 4_000f,
            unfoldedBottomDp = 28f, unfoldedHeightDp = 48f, density = 2.625f, paneHeightPx = 2220)
        assertEquals(2220, clip.obscuredPx)
        assertEquals(200, clip.maxPx)
        assertTrue(clip.obscuredPx - clip.maxPx > 0)
    }

    @Test fun aFoldNeverReducesTheMaximumTheEngineReserved() {
        // The fold changes the covered height, never the reservation: the
        // engine keeps positioning bottom-fixed things for the full chrome.
        val unfoldedClip = BrowserChromeClipping.from(28f, 48f, 28f, 48f, 2.625f, 2220)
        val foldedClip = BrowserChromeClipping.from(16f, 31f, 28f, 48f, 2.625f, 2220)
        assertEquals(unfoldedClip.maxPx, foldedClip.maxPx)
        assertTrue(foldedClip.obscuredPx < unfoldedClip.obscuredPx)
    }

    @Test fun invalidGeometryIsRejectedInsteadOfSilentlyCoerced() {
        for (bottom in listOf(Float.NaN, -1f, Float.NEGATIVE_INFINITY)) {
            for (height in listOf(48f, Float.NaN)) {
                assertThrows(IllegalArgumentException::class.java) {
                    BrowserChromeClipping.from(bottom, height, 28f, 48f, 2.625f, 2220)
                }
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            BrowserChromeClipping.from(16f, 31f, 28f, 48f, 0f, 2220)
        }
        assertThrows(IllegalArgumentException::class.java) {
            BrowserChromeClipping.from(16f, 31f, 28f, 48f, 2.625f, -1)
        }
    }
}

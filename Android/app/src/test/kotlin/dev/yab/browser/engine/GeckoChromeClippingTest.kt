package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

/** The applier seam records exactly what a bound view would receive. */
class GeckoChromeClippingTest {
    private class Recorded {
        val maxes = mutableListOf<Pair<Any?, Int>>()
        val clippings = mutableListOf<Pair<Any?, Int>>()
        val applier = GeckoChromeClipping(
            { view, px -> maxes.add(view to px) },
            { view, px -> clippings.add(view to px) })
    }

    private val a = Any()
    private val b = Any()

    @Test fun theFullChromeReservationGoesToTheViewOnceAndTheCoveredPartOnEveryChange() {
        val f = Recorded()
        f.applier.update("t1", obscuredPx = 199, maxPx = 199, view = a)
        f.applier.update("t1", obscuredPx = 123, maxPx = 199, view = a)
        f.applier.update("t1", obscuredPx = 123, maxPx = 199, view = a)
        assertEquals(listOf(a to 199), f.maxes)
        assertEquals(listOf(a to 0, a to (123 - 199)), f.clippings)
    }

    @Test fun aClearResetsTheReservationAndSkipsAnUnchangedCoveredPart() {
        val f = Recorded()
        f.applier.update("t1", 199, 199, a)
        f.applier.update("t1", 0, 0, a)
        assertEquals(listOf(a to 199, a to 0), f.maxes)
        // The covered part already sits at zero on this view, so the clear's
        // only news is the reservation; the clipping channel stays quiet.
        assertEquals(listOf(a to 0), f.clippings)
    }

    @Test fun aClearFromAFoldedChromeAlsoZeroesTheCoveredPart() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.update("t1", 0, 0, a)
        assertEquals(listOf(a to 199, a to 0), f.maxes)
        assertEquals(listOf(a to (123 - 199), a to 0), f.clippings)
    }

    @Test fun aNewlyBoundViewGetsTheToolbarMaximumAgainThenKeepsReceivingCoveredChanges() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.apply("t1", b)
        f.applier.update("t1", 150, 199, b)
        assertEquals(listOf(a to 199, b to 199), f.maxes)
        assertEquals(listOf(a to (123 - 199), b to (123 - 199), b to (150 - 199)), f.clippings)
    }

    @Test fun aViewThatRebindsWithUnchangedNumbersIsToldNothing() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        val maxes = f.maxes.size; val clippings = f.clippings.size
        f.applier.apply("t1", a)
        assertEquals(maxes, f.maxes.size)
        assertEquals(clippings, f.clippings.size)
    }

    @Test fun withoutABoundViewNothingIsAppliedButTheNumbersAreKeptForTheNextBinding() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, null)
        assertTrue(f.maxes.isEmpty() && f.clippings.isEmpty())
        f.applier.apply("t1", a)
        assertEquals(listOf(a to 199), f.maxes)
        assertEquals(listOf(a to (123 - 199)), f.clippings)
    }

    @Test fun coveredSpaceAboveTheReservationNeverBecomesPositiveClipping() {
        val f = Recorded()
        f.applier.update("t1", obscuredPx = 900, maxPx = 400, view = a)
        assertEquals(listOf(a to 0), f.clippings)
    }

    @Test fun negativeNumbersAreRejectedBeforeTouchingTheEngine() {
        val f = Recorded()
        assertThrows(IllegalArgumentException::class.java) { f.applier.update("t1", -1, 400, a) }
        assertThrows(IllegalArgumentException::class.java) { f.applier.update("t1", 400, -1, a) }
        assertTrue(f.maxes.isEmpty() && f.clippings.isEmpty())
    }

    @Test fun theReportedPaneKeepsItsOwnNumbersAndTheOtherPaneIsNeverTouched() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.apply("t1", b)
        // Pane t2 reports its own numbers for its own view.
        f.applier.update("t2", 150, 199, b)
        // Pane t2 stamps its own max on b: it has no memory of pane t1's stamp.
        assertEquals(listOf(a to 199, b to 199, b to 199), f.maxes)
        assertEquals(listOf(a to (123 - 199), b to (123 - 199), b to (150 - 199)), f.clippings)
    }

    @Test fun aClearReachesOnlyTheReportingPaneNeverTheOtherPane() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.apply("t2", b)
        f.applier.update("t2", 150, 199, b)
        // Pane t1's chrome unmounts; its clear must reach t1's view, not t2's.
        f.applier.update("t1", 0, 0, a)
        assertEquals(listOf(a to 199, b to 199, a to 0), f.maxes)
        assertEquals(listOf(a to (123 - 199), b to (150 - 199), a to 0), f.clippings)
        // b's numbers survived the other pane's clear.
        assertTrue(f.maxes.none { it.first === b && it.second == 0 })
    }

    @Test fun aClearedPaneRemembersNothingButItsViewStaysClearedOnRebind() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.update("t1", 0, 0, a)
        f.applier.apply("t1", a)
        assertEquals(listOf(a to 199, a to 0), f.maxes)
        assertEquals(listOf(a to (123 - 199), a to 0), f.clippings)
    }

    @Test fun aViewThatBindsAfterTheReportGetsItsOwnPanesNumbersNotAnotherPanes() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        // A new view for t2 binds while t2 has no numbers of its own.
        f.applier.apply("t2", b)
        assertTrue(f.maxes.none { it.first === b })
        assertTrue(f.clippings.none { it.first === b })
    }

    @Test fun theTabIsGoneAndItsPaneEntryLeavesWithIt() {
        val f = Recorded()
        f.applier.update("t1", 123, 199, a)
        f.applier.forget("t1")
        // A later view binding finds no numbers to stamp.
        f.applier.apply("t1", b)
        assertTrue(f.maxes.none { it.first === b })
        assertTrue(f.clippings.none { it.first === b })
    }
}

package dev.yab.browser.engine

import java.lang.ref.WeakReference

/** One pane's chrome clipping, keyed by the pane that reported it. GeckoView
 * takes the toolbar maximum once per view and the covered height on every
 * change; the numbers come from the chrome layer in this view's screen
 * pixels. 0/0 clears the reporting pane's view and stays, so a view that
 * binds later re-stamps the clear instead of the last mounted numbers. Each
 * pane's view owns its numbers: a clear never touches the other pane, and a
 * view that binds after a report gets its own pane's current numbers, never
 * another pane's. Entries leave with their tab. Views are held weakly,
 * matching the engine's own view registry. */
internal class GeckoChromeClipping(
    private val setDynamicToolbarMaxHeight: (view: Any?, px: Int) -> Unit,
    private val setVerticalClipping: (view: Any?, px: Int) -> Unit
) {
    private class Pane {
        var obscuredPx = 0
        var maxPx = 0
        var appliedMaxPx = -1
        var appliedMaxView = WeakReference<Any?>(null)
        var appliedClippingPx = 0
        var appliedClippingView = WeakReference<Any?>(null)
    }

    private val panes = mutableMapOf<String, Pane>()

    /** The pane that owns this report, as the chrome layer identifies it. */
    fun update(owner: String, obscuredPx: Int, maxPx: Int, view: Any?) {
        require(obscuredPx >= 0 && maxPx >= 0)
        val pane = panes.getOrPut(owner) { Pane() }
        if (pane.obscuredPx == obscuredPx && pane.maxPx == maxPx) return
        pane.obscuredPx = obscuredPx; pane.maxPx = maxPx
        stamp(pane, view)
    }

    /** The tab is gone; its pane's numbers leave with it. */
    fun forget(owner: String) {
        panes.remove(owner)
    }

    /** A view that (re)binds gets its pane's current numbers again. */
    fun apply(owner: String, view: Any?) {
        val pane = panes[owner] ?: return
        stamp(pane, view)
    }

    private fun stamp(pane: Pane, view: Any?) {
        if (view == null) return
        if (pane.appliedMaxView.get() !== view || pane.maxPx != pane.appliedMaxPx) {
            setDynamicToolbarMaxHeight(view, pane.maxPx)
            pane.appliedMaxView = WeakReference(view); pane.appliedMaxPx = pane.maxPx
        }
        val clipping = (pane.obscuredPx - pane.maxPx).coerceAtMost(0)
        if (pane.appliedClippingView.get() !== view || clipping != pane.appliedClippingPx) {
            setVerticalClipping(view, clipping)
            pane.appliedClippingView = WeakReference(view); pane.appliedClippingPx = clipping
        }
    }
}
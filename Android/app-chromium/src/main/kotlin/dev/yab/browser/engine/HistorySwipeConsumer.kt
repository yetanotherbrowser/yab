package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection

// Cefrium cannot render history swipe previews; the engine installs a no-op consumer.
internal interface HistorySwipeConsumer {
    fun current(): Boolean
    fun begin(direction: HistorySwipeDirection, width: Float): Boolean
    fun move(distance: Float)
    fun end(distance: Float, velocity: Float, cancelled: Boolean)
}
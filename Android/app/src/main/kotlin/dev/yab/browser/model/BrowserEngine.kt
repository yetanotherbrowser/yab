package dev.yab.browser.model

/** Engine mutations keep the exact tab and website namespace captured by the caller. */
interface BrowserEngine {
    fun activate(tab: BrowserTab, profile: WebsiteProfile)
    fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile)
    fun goBack(tabId: String)
    fun backItems(tabId: String): List<BrowserBackItem> = emptyList()
    fun goBackTo(tabId: String, item: BrowserBackItem): Boolean = false
    fun goForward(tabId: String)
    fun captureHistorySwipe(tabId: String, direction: HistorySwipeDirection): NativeHistorySwipeTarget? = null
    fun historySwipeCurrent(target: NativeHistorySwipeTarget): Boolean = false
    fun commitHistorySwipe(target: NativeHistorySwipeTarget): Boolean = false
    fun reload(tabId: String)
    fun stop(tabId: String)
    fun close(tabId: String)
    /** Opaque, bounded, process-local native state. Implementations never serialize this token. */
    fun captureForUndo(tab: BrowserTab, profile: WebsiteProfile): BrowserPageMemento? = null
    suspend fun restoreForUndo(tab: BrowserTab, profile: WebsiteProfile, memory: BrowserPageMemento, isCurrent: () -> Boolean = { true }): Boolean = false
    fun releaseUndo(memory: BrowserPageMemento) {}
    /** Last logical Private tab closed: expire native Undo state from that RAM-only session. */
    fun endPrivateSession(profile: WebsiteProfile) {}
    /** A profile's website data erased: the endpoints it excused ask again. */
    fun forgetWebsitePardons(profile: String) {}
    fun reconcileTabs(spaces: List<BrowserSpace>) {}
    fun invalidateTransientOwnership() {}
    suspend fun clearWebsiteData(profileIds: Set<String>)
    fun pausePrivateMedia() {}
    fun setReader(tabId: String, enabled: Boolean): Boolean = false
    /** Presentation only. Never enters Reader or grants an action on a background document. */
    fun restyleReaders(preferences: ReaderPreferences) {}
    /** A null answer revokes the current document's find bar, never a different tab's search. */
    fun find(tabId: String, query: BrowserFindQuery, direction: BrowserFindDirection,
        answer: (BrowserFindResult?) -> Unit): Boolean = false
    fun clearFind(tabId: String) {}
    fun setZoom(tabId: String, factor: Double): Boolean = false
    fun setDesktop(tabId: String, enabled: Boolean): Boolean = false
    suspend fun captureFieldAnswerTarget(tabId: String): FieldAnswerTarget? = null
}

interface BrowserPageMemento

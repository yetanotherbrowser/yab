package dev.yab.browser.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.JsonObject

@Serializable enum class TabPlace { TODAY, KEPT, PINNED }
@Serializable enum class BrowserAppearance { SYSTEM, LIGHT, DARK }
enum class BrowserSurface { PAGE, FIELD, SPACES, GALLERY, HISTORY, SETTINGS }

@Serializable
data class BrowserTab(
    val id: String,
    val url: String = "about:blank",
    val title: String = "New Tab",
    val place: TabPlace = TabPlace.TODAY,
    val isPrivate: Boolean = false,
    val openerId: String? = null,
    val createdAt: Long,
    val lastActiveAt: Long = createdAt,
    val locallyCreated: Boolean = true,
    val shared: Boolean = false,
    val hasDraft: Boolean = false,
    val hasTask: Boolean = false,
    val folderId: String? = null,
) {
    val isBlank: Boolean get() = url == "about:blank"
    val host: String get() = runCatching { java.net.URI(url).host?.removePrefix("www.") }.getOrNull() ?: url
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BrowserSpace(
    val id: String,
    val name: String,
    val emoji: String = "",
    val color: Long = 0xFFEEE9E2,
    val ownSignIns: Boolean = false,
    val isPrivate: Boolean = false,
    val tabs: List<BrowserTab> = emptyList(),
    val currentTabId: String? = null,
    val folders: List<BrowserFolder> = emptyList(),
    // Omit the additive null default even in encodeDefaults profiles: old checkpoint hashes
    // and old profiles remain byte-compatible until a real paint record is present.
    @EncodeDefault(EncodeDefault.Mode.NEVER) val look: JsonObject? = null,
    // Local presentation of the existing mixed wire order. Never a new Sync field.
    @EncodeDefault(EncodeDefault.Mode.NEVER) val keptOrder: List<String> = emptyList(),
) {
    val currentTab: BrowserTab? get() = tabs.firstOrNull { it.id == currentTabId }
    val websiteProfile: WebsiteProfile get() = WebsiteProfile(
        id = if (isPrivate) PRIVATE_PROFILE else if (ownSignIns) "space-$id" else SHARED_PROFILE,
        isPrivate = isPrivate,
    )

    companion object {
        const val SHARED_PROFILE = "shared"
        const val PRIVATE_PROFILE = "private"
    }
}

data class WebsiteProfile(val id: String, val isPrivate: Boolean = false)

/** A native history identity is ephemeral and cannot be used to navigate another session. */
data class BrowserBackItem(val steps: Int, val url: String, val title: String, val token: String)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BrowserFolder(val id: String, val name: String, val parentId: String? = null, val open: Boolean = true,
    // The color given it on the Mac; old checkpoint hashes stay byte-compatible without one.
    @EncodeDefault(EncodeDefault.Mode.NEVER) val color: String? = null)

@Serializable
data class BrowserVisit(val url: String, val title: String, val visitedAt: Long, val count: Int = 1,
    val syncedKey: String? = null, val syncedAt: Double? = null, val syncedDevice: String? = null) {
    val host: String get() = runCatching { java.net.URI(url).host?.removePrefix("www.") }.getOrNull() ?: url
    val identity: String get() = syncedKey?.let { "synced:$it" } ?: "here:$url"
}

@Serializable
enum class SearchEngine(val title: String, val template: String) {
    GOOGLE("Google", "https://www.google.com/search?q=%s"),
    DUCKDUCKGO("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
    BING("Bing", "https://www.bing.com/search?q=%s"),
    ECOSIA("Ecosia", "https://www.ecosia.org/search?q=%s"),
    STARTPAGE("Startpage", "https://www.startpage.com/sp/search?query=%s"),
    KAGI("Kagi", "https://kagi.com/search?q=%s"),
    BRAVE("Brave Search", "https://search.brave.com/search?q=%s"),
    QWANT("Qwant", "https://www.qwant.com/?q=%s"),
    CUSTOM("Other", ""),
}

/** The browsing engine a window's pages run on. Gecko is the shipped default; Chromium needs the fork present. */
@Serializable
enum class BrowserEngineKind { GECKO, CHROMIUM }

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BrowserSettings(
    val appearance: BrowserAppearance = BrowserAppearance.SYSTEM,
    val searchEngine: SearchEngine = SearchEngine.GOOGLE,
    val customSearchTemplate: String = "",
    val blocksAds: Boolean = true,
    val darkenWebsites: Boolean = false,
    val autoClearToday: Boolean = false,
    val lockPrivate: Boolean = true,
    val welcomed: Boolean = false,
    val syncHistory: Boolean = true,
    val macTabs: Boolean = false,
    val swipeAnywhere: Boolean = true,
    // Preserve pre-upgrade checkpoint hashes; an explicit local false still persists.
    @EncodeDefault(EncodeDefault.Mode.NEVER) val openKeyboardAtLaunch: Boolean = true,
    // Absent means Gecko on every pre-upgrade checkpoint; a Chromium choice persists explicitly.
    @EncodeDefault(EncodeDefault.Mode.NEVER) val engineKind: BrowserEngineKind = BrowserEngineKind.GECKO,
)

@Serializable
data class BrowserSnapshot(
    val schema: Int = 1,
    val spaces: List<BrowserSpace>,
    val selectedSpaceId: String,
    val history: List<BrowserVisit> = emptyList(),
    val settings: BrowserSettings = BrowserSettings(),
    val recency: Map<String, List<String>> = emptyMap(),
    val historyForgetting: HistoryForgetting = HistoryForgetting(),
)

/** Native safety observations are not reconstructed from a URL or a timestamp. */
data class EnginePageState(
    val url: String? = null,
    val title: String? = null,
    val loading: Boolean = false,
    val progress: Float = 0f,
    val canGoBack: Boolean = false,
    val canGoForward: Boolean = false,
    val playingMedia: Boolean = false,
    val capturingMedia: Boolean = false,
    val hasFormEdits: Boolean = false,
    val safeToClear: Boolean = false,
    val readerAvailable: Boolean = false,
    val readerEnabled: Boolean = false,
    val secure: Boolean = false,
    val error: String? = null,
    val scrollY: Float = 0f,
    /** User-origin compositor offset in logical screen points, independent of DOM reports/restoration. */
    val userScrollY: Float = 0f,
    val frameUncertain: Boolean = true,
)

data class BrowserWorkspace(val first: String, val second: String, val focused: String, val newPage: String? = null) {
    val companion: String get() = if (focused == first) second else first
}

/** Process-local search UI. Queries and results never enter the public snapshot or Sync. */
data class BrowserFindQuery(val text: String = "", val matchCase: Boolean = false, val wholeWord: Boolean = false)
enum class BrowserFindDirection { START, NEXT, PREVIOUS }
data class BrowserFindResult(val current: Int, val total: Int, val wrapped: Boolean = false)
data class BrowserFindState(val tab: String, val profile: WebsiteProfile, val url: String,
    val query: BrowserFindQuery = BrowserFindQuery(), val result: BrowserFindResult = BrowserFindResult(0, 0),
    val searching: Boolean = false, val failed: Boolean = false)

/** Content bounds size the panes; only the full window admits the iOS landscape spread. */
data class BrowserWorkspaceLayout(val width: Int, val height: Int, val paired: Boolean,
    val window: BrowserWorkspaceWindow = BrowserWorkspaceWindow(width.toDouble(), height.toDouble())) {
    val expanded: Boolean get() = window.expanded
    val horizontal: Boolean get() = window.width > window.height
    val split: Boolean get() = window.canSplit && paired
    val paneWidth: Int get() = if (split && horizontal) (width - 1) / 2 else width
    // iOS reserves page space only when the active pane still has at least 320pt.
    val reservesConversation: Boolean get() = expanded && paneWidth >= 680
    val conversationWidth: Int get() = if (expanded) minOf(360, paneWidth) else paneWidth
    val pageVisibleWithConversation: Boolean get() = paneWidth > conversationWidth
}

data class BrowserState(
    val loading: Boolean = true,
    val spaces: List<BrowserSpace> = emptyList(),
    val selectedSpaceId: String = "",
    val history: List<BrowserVisit> = emptyList(),
    val settings: BrowserSettings = BrowserSettings(),
    val surface: BrowserSurface = BrowserSurface.PAGE,
    /** Process-local generation, never part of the public saved or synced snapshot. */
    val surfaceEpoch: Long = 0,
    /** Draw the selected native page beneath its retained returning card. RAM only. */
    val galleryClosing: Boolean = false,
    val settingsPage: SettingsPage? = null,
    val fieldText: String = "",
    val fieldShowsAddress: Boolean = false,
    val fieldIsNewTab: Boolean = true,
    val fieldPrivate: Boolean = false,
    val fieldPagePrivate: Boolean = false,
    val fieldOriginTab: String? = null,
    val fieldOriginSpace: String? = null,
    val fieldOriginProfile: WebsiteProfile? = null,
    val fieldAnchor: FieldAnchor? = null,
    val fieldResting: Boolean = false,
    /** The public New Tab page already landed under the field. RAM only. */
    val fieldInPlace: Boolean = false,
    /** The field came from the spaces standing: the sheet starts at the whole screen. RAM only. */
    val fieldFromSpaces: Boolean = false,
    /** The choice opens something new: the sheet leaves upward and becomes the page. RAM only. */
    val fieldGoesUp: Boolean = false,
    /** The field searches Chats, from their foot button. RAM only. */
    val fieldChats: Boolean = false,
    val privateLocked: Boolean = true,
    val pageStates: Map<String, EnginePageState> = emptyMap(),
    val recency: Map<String, List<String>> = emptyMap(),
    val workspace: BrowserWorkspace? = null,
    val message: String? = null,
    val undoAvailable: Boolean = false,
    val persistenceError: String? = null,
    val historyForgetting: HistoryForgetting = HistoryForgetting(),
    val find: BrowserFindState? = null,
) {
    val space: BrowserSpace? get() = spaces.firstOrNull { it.id == selectedSpaceId }
    val tab: BrowserTab? get() = space?.currentTab
    val page: EnginePageState get() = tab?.id?.let(pageStates::get) ?: EnginePageState()
    val privateContentBlocked: Boolean get() = space?.isPrivate == true && settings.lockPrivate && privateLocked
    /** Explicit eyes choose a new Private tab; editing a Private page always remains Private. */
    val fieldIsPrivate: Boolean get() = fieldPrivate || (!fieldIsNewTab && fieldPagePrivate)
    /** TabRecency.order: the tab in front, then what this device had in front since, pins and
     * kept tabs too, then today's never shown here. Kept and pinned tabs never opened stay out. */
    val galleryTabs: List<BrowserTab> get() {
        val order = recency[selectedSpaceId].orEmpty()
        val front = space?.currentTabId
        val tabs = space?.tabs.orEmpty().filter { !it.isBlank && (it.place == TabPlace.TODAY || it.id in order || it.id == front) }
        return tabs.sortedBy { tab -> if (tab.id == front) -1 else order.indexOf(tab.id).takeIf { it >= 0 } ?: Int.MAX_VALUE }
    }
    /** No page in front on an ordinary space (a blank tab is none): the empty screen. */
    val emptyHome: Boolean get() = !loading && space?.isPrivate != true && (tab == null || tab?.isBlank == true)
    /** And no tab waiting in the stack: All Tabs' own bar stands there, with nothing to show. */
    val emptyHomeBar: Boolean get() = emptyHome && galleryTabs.isEmpty()
}

/** The Android URL parser is deliberately kept out so this rule is shared by JVM tests. */
object BrowserAddress {
    /** Same Google-results address edit rule as Phone SearchEngine.googleWords. */
    fun googleWords(url: String): String? = runCatching {
        val parts = java.net.URI(url)
        if (parts.scheme?.lowercase(java.util.Locale.ROOT) !in setOf("http", "https") || parts.rawUserInfo != null || parts.path != "/search") return@runCatching null
        val host = parts.host?.lowercase(java.util.Locale.ROOT)?.removePrefix("www.") ?: return@runCatching null
        if (!Regex("google\\.(com|[a-z]{2}|(?:co|com)\\.[a-z]{2})").matches(host)) return@runCatching null
        val query = parts.rawQuery ?: return@runCatching null
        val words = query.split('&').filter { item ->
            java.net.URLDecoder.decode(item.substringBefore('='), "UTF-8") == "q"
        }
        if (words.size != 1 || !words.single().contains('=')) return@runCatching null
        java.net.URLDecoder.decode(words.single().substringAfter('='), "UTF-8").takeIf { it.isNotBlank() }
    }.getOrNull()

    fun editText(url: String): String = googleWords(url) ?: url

    fun url(input: String, settings: BrowserSettings): String? {
        val text = input.trim()
        if (text.isBlank()) return null
        val parsed = runCatching { java.net.URI(text) }.getOrNull()
        if (parsed?.scheme?.lowercase() in setOf("http", "https") && !parsed?.host.isNullOrBlank()) return parsed.toASCIIString()
        if (text == "about:blank") return text
        if (!text.any(Char::isWhitespace) && !text.contains("://") && !text.contains('@') &&
            (text.contains('.') || text.startsWith("localhost"))) {
            val web = runCatching { java.net.URI("https://$text") }.getOrNull()
            if (!web?.host.isNullOrBlank()) return web!!.toASCIIString()
        }
        val template = if (settings.searchEngine == SearchEngine.CUSTOM && validTemplate(settings.customSearchTemplate))
            settings.customSearchTemplate else settings.searchEngine.template.ifBlank { SearchEngine.GOOGLE.template }
        val escaped = java.net.URLEncoder.encode(text, "UTF-8").replace("+", "%20").replace("%7E", "~")
        return template.replace("%s", escaped)
    }

    fun validTemplate(template: String): Boolean {
        if (!template.contains("%s")) return false
        val a = runCatching { java.net.URI(template.replace("%s", "a")) }.getOrNull() ?: return false
        val b = runCatching { java.net.URI(template.replace("%s", "b")) }.getOrNull() ?: return false
        return a.scheme in setOf("http", "https") && !a.host.isNullOrEmpty() && a.scheme == b.scheme &&
            a.host == b.host && a.port == b.port && a.rawUserInfo == b.rawUserInfo
    }
}

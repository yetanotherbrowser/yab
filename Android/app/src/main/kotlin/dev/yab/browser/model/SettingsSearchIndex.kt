package dev.yab.browser.model

import java.text.Collator
import java.util.Locale

/** Only pages already reachable from the Android settings panel belong in this index. */
enum class SettingsPage(val title: String, internal val keywords: String) {
    GENERAL("General", "browser default links android swipe anywhere back forward gestures"),
    SEARCH("Search", "engine google web address url"),
    APPEARANCE("Appearance", "theme light dark system color colour look websites pages"),
    APP_ICON("App Icon", "icon icons home screen logo"),
    ENGINE("Engine", "gecko chromium default"),
    AI("AI", "answers ask chat chats model models on-device local agent claude chatgpt codex mac download"),
    TABS("Tabs", "today keep pins folders automatic clear"),
    SPACES("Spaces", "workspaces personal work emoji color colour sign ins cookies"),
    HISTORY("History", "visited pages recent browsing clear forget"),
    PASSWORDS("Passwords", "passkeys password credentials login"),
    AUTOFILL("Autofill", "forms fill addresses cards provider"),
    PRIVACY("Privacy", "private lock history cookies website data clear ads ad blocker trackers content blocking"),
    ABOUT("About", "version build"),
    FEEDBACK("Send Feedback", "report bug help"),
    SYNC("Sync", "mac devices recovery key code encrypted join account backup turn off leave"),
    EXTENSIONS("Extensions", "add-ons addons plugins firefox mozilla signed xpi"),
}

data class SettingsSearchAvailability(
    val sync: Boolean = false,
    val extensions: Boolean = false,
    val systemSettings: Boolean = false,
    val credentialsSettings: Boolean = false,
    val feedback: Boolean = false,
    val reports: Boolean = false,
    val ai: Boolean = false,
    val updates: Boolean = false,
    val chromium: Boolean = false,
)

data class SettingsSearchRow(val id: String, val title: String, val value: String? = null, val spaceId: String? = null)
data class SettingsSearchPage(val page: SettingsPage, val rows: List<SettingsSearchRow> = emptyList(), val keywords: String = page.keywords)
data class SettingsSearchMatch(val page: SettingsPage, val row: SettingsSearchRow? = null) {
    val id: String get() = "${page.name}.${row?.id ?: "page"}"
}

/** These IDs are shared with the actual Compose rows, never with a toggle/action dispatcher. */
object SettingsRowId {
    const val DEFAULT_BROWSER = "general.defaultBrowser"
    const val NOTIFICATIONS = "general.notifications"
    const val SWIPE_ANYWHERE = "general.swipeAnywhere"
    const val LAUNCH_KEYBOARD = "general.openKeyboardAtLaunch"
    const val APP_ICON = "appearance.appIcon"
    const val ENGINE = "engine.default"
    const val DARKEN_WEBSITES = "appearance.darkenWebsites"
    const val TODAY = "tabs.today"
    const val AUTO_CLEAR = "tabs.autoClear"
    const val MAC_TABS = "tabs.macTabs"
    const val TAB_LOCK = "tabs.lockPrivate"
    const val ADD_SPACE = "spaces.add"
    const val BLOCK_ADS = "privacy.blockAds"
    const val PRIVATE_LOCK = "privacy.lockPrivate"
    const val SYNC_HISTORY = "privacy.syncHistory"
    const val CLEAR_DATA = "privacy.clearData"
    const val PASSWORD_PROVIDER = "passwords.provider"
    const val PASSWORD_SETTINGS = "passwords.settings"
    const val AUTOFILL_PROVIDER = "autofill.provider"
    const val AUTOFILL_SETTINGS = "autofill.settings"
    const val VERSION = "about.version"
    const val CHECK_UPDATES = "about.update"
    const val ABOUT_BROWSER = "about.browser"
    const val CRASHES = "about.crashes"
    const val ACTIVITY = "about.activity"
    const val FEEDBACK_MESSAGE = "feedback.message"
    const val FEEDBACK_EMAIL = "feedback.email"
    const val FEEDBACK_SEND = "feedback.send"
    fun engine(value: SearchEngine) = "search.engine.${value.name}"
    fun appearance(value: BrowserAppearance) = "appearance.${value.name}"
    fun icon(title: String) = "appIcon.$title"
    fun space(id: String, field: String = "entry") = "spaces.$id.$field"
}

/** The iOS rule: all token prefixes match one page title, else its first real row, else keywords. */
object SettingsSearchIndex {
    fun pages(settings: BrowserSettings, spaces: List<BrowserSpace>, availability: SettingsSearchAvailability,
              appIcons: List<String> = emptyList(), version: String = "", build: String = ""): List<SettingsSearchPage> {
        fun row(id: String, title: String, value: String? = null) = SettingsSearchRow(id, title, value)
        val public = spaces.filterNot { it.isPrivate }
        val spaceRows = buildList {
            public.forEach { add(SettingsSearchRow(SettingsRowId.space(it.id), it.name, "${it.tabs.size} tabs", it.id)) }
            add(row(SettingsRowId.ADD_SPACE, "Add Space"))
            public.forEach { space ->
                fun field(id: String, title: String, value: String? = null) = SettingsSearchRow(SettingsRowId.space(space.id, id), title, value, space.id)
                add(field("name", "Name", space.name)); add(field("emoji", "Emoji", space.emoji))
                add(field("color", "Color")); add(field("signIns", "Sign-ins"))
                add(field("shared", "Shared")); add(field("own", "Its own"))
                if (public.size > 1 && public.first().id != space.id) add(field("delete", "Delete Space"))
            }
        }
        return buildList {
            add(SettingsSearchPage(SettingsPage.GENERAL, listOf(row(SettingsRowId.DEFAULT_BROWSER, "Default Browser", if (availability.systemSettings) "Choose Yab in Android settings" else "Managed by Android"),
                row(SettingsRowId.NOTIFICATIONS, "Notifications"), row(SettingsRowId.SWIPE_ANYWHERE, "Swipe from Anywhere"), row(SettingsRowId.LAUNCH_KEYBOARD, "Open Keyboard at Launch"))))
            add(SettingsSearchPage(SettingsPage.SEARCH, SearchEngine.entries.filter { it != SearchEngine.CUSTOM || BrowserAddress.validTemplate(settings.customSearchTemplate) }.map { row(SettingsRowId.engine(it), it.title) }))
            add(SettingsSearchPage(SettingsPage.APPEARANCE, BrowserAppearance.entries.map { row(SettingsRowId.appearance(it), it.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase)) } + row(SettingsRowId.DARKEN_WEBSITES, "Darken Websites")))
            add(SettingsSearchPage(SettingsPage.APP_ICON, appIcons.map { row(SettingsRowId.icon(it), it) }))
            // The row exists only while the Chromium fork is linked; a build without it never mentions Chromium.
            if (availability.chromium) add(SettingsSearchPage(SettingsPage.ENGINE,
                listOf(row(SettingsRowId.ENGINE, "Default Engine", settings.engineKind.name.lowercase(Locale.ROOT).replaceFirstChar(Char::titlecase)))))
            if (availability.ai) add(SettingsSearchPage(SettingsPage.AI, listOf(row("ai.aboutPage", "About a page"), row("ai.agent", "Agent on your Mac"), row("ai.model", "On-device AI"))))
            add(SettingsSearchPage(SettingsPage.TABS, listOf(row(SettingsRowId.TODAY, "Today", "This device's own"), row(SettingsRowId.AUTO_CLEAR, "Clear after 12 hours"), row(SettingsRowId.MAC_TABS, "Your Mac's Tabs"), row(SettingsRowId.TAB_LOCK, "Private Tabs"))))
            add(SettingsSearchPage(SettingsPage.SPACES, spaceRows))
            add(SettingsSearchPage(SettingsPage.HISTORY))
            add(SettingsSearchPage(SettingsPage.PASSWORDS, listOf(row(SettingsRowId.PASSWORD_PROVIDER, "Passwords and Passkeys", "Managed by Android")) +
                if (availability.credentialsSettings) listOf(row(SettingsRowId.PASSWORD_SETTINGS, "Open Android Settings")) else emptyList()))
            add(SettingsSearchPage(SettingsPage.AUTOFILL, listOf(row(SettingsRowId.AUTOFILL_PROVIDER, "Autofill", "Managed by Android")) +
                if (availability.credentialsSettings) listOf(row(SettingsRowId.AUTOFILL_SETTINGS, "Open Android Settings")) else emptyList()))
            add(SettingsSearchPage(SettingsPage.PRIVACY, listOf(row(SettingsRowId.BLOCK_ADS, "Block ads and trackers"), row(SettingsRowId.SYNC_HISTORY, "Sync History"), row(SettingsRowId.CLEAR_DATA, "Clear History and Website Data"))))
            add(SettingsSearchPage(SettingsPage.ABOUT, listOf(row(SettingsRowId.VERSION, "Version $version ($build)")) +
                (if (availability.updates) listOf(row(SettingsRowId.CHECK_UPDATES, "Check for Updates")) else emptyList()) +
                row(SettingsRowId.ABOUT_BROWSER, "Your browser", "Pages, spaces and conversations, on your devices.") +
                if (availability.reports) listOf(row(SettingsRowId.CRASHES, "Automatically send crash reports"), row(SettingsRowId.ACTIVITY, "Share daily activity")) else emptyList()))
            if (availability.feedback) add(SettingsSearchPage(SettingsPage.FEEDBACK, listOf(row(SettingsRowId.FEEDBACK_MESSAGE, "What happened?"), row(SettingsRowId.FEEDBACK_EMAIL, "Email for a reply (optional)"), row(SettingsRowId.FEEDBACK_SEND, "Send Feedback"))))
            // External pages have their own live contents and security gates. Only their safe page
            // destination/keywords are indexed here; a search never reveals a key or starts joining.
            if (availability.sync) add(SettingsSearchPage(SettingsPage.SYNC))
            if (availability.extensions) add(SettingsSearchPage(SettingsPage.EXTENSIONS))
        }
    }

    fun matches(query: String, pages: List<SettingsSearchPage>, locale: Locale = Locale.getDefault()): List<SettingsSearchMatch> {
        val tokens = words(query)
        if (tokens.isEmpty()) return emptyList()
        fun finds(text: String): Boolean {
            val candidates = words(text)
            return tokens.all { token -> candidates.any { it.startsWith(token) } }
        }
        val result = pages.mapNotNull { entry ->
            when {
                finds(entry.page.title) -> SettingsSearchMatch(entry.page)
                else -> entry.rows.firstOrNull { finds(it.title + " " + it.value.orEmpty()) }?.let { SettingsSearchMatch(entry.page, it) }
                    ?: SettingsSearchMatch(entry.page).takeIf { finds(entry.keywords) }
            }
        }
        val alphabet = Collator.getInstance(locale).apply { strength = Collator.SECONDARY }
        return result.sortedWith { left, right ->
            val leftExact = alphabet.compare(left.page.title, query) == 0
            val rightExact = alphabet.compare(right.page.title, query) == 0
            when {
                leftExact != rightExact -> if (leftExact) -1 else 1
                (left.row == null) != (right.row == null) -> if (left.row == null) -1 else 1
                else -> alphabet.compare(left.page.title, right.page.title)
            }
        }
    }

    private fun words(text: String): List<String> = text.lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{N}]+")).filter(String::isNotEmpty)
}

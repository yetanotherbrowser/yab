import AppKit

// Every row of Settings by name, so the search at the top of the sidebar
// finds the switch itself and not only the page it is on. A result is the page, and under it the rows on it that answered;
// choosing a row opens its page and brings the row into view.

/// One row somewhere in Settings: what it is called there, the other words
/// someone might look for it by, and the page it lives on. Its `id` is what
/// the row wears on the page, so the page can scroll to it.
struct SettingsItem: Identifiable, Hashable {
    let id: String
    let page: SettingsPage
    let title: String
    var words = ""
    /// Audited ownership, when known. Kept separate from the display title,
    /// persisted values and IDs; unreviewed settings do not default to global.
    var scope: SettingsScope? { SettingsScope.of(anchor: id) }
    /// The row some settings only show under another one: grain only with a
    /// color behind the page. While it isn't there, the row it waits
    /// beneath is the one brought into view.
    var within: String?
    var shown: @MainActor (Preferences) -> Bool = { _ in true }

    static func == (a: SettingsItem, b: SettingsItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Where the page should scroll to find it under the current settings.
    @MainActor
    func anchor(_ prefs: Preferences) -> String {
        shown(prefs) ? id : within ?? id
    }

    func score(_ query: String, bundle: Bundle = .main) -> Double? {
        SettingsMatch.score(query, title: SettingsWords.text(title, bundle: bundle), words: words + " " + title + " " + page.englishTitle + " " + SettingsWords.text(page.englishTitle, bundle: bundle))
    }

    /// Every row, the shortcuts with the keys they have now, so ⌥⌘Y finds
    /// History once it has been given it.
    @MainActor
    static var all: [SettingsItem] {
        fixed.filter { $0.id != "engine-default" || EngineRules.available }
            + Keymap.shared.index.filter { MailExperiment.enabled() || !$0.id.hasPrefix("key:mail") }
    }

    /// Also offered by General in the command field, as a setting destination.
    static let showYab = SettingsItem(id: "show-yab", page: .general, title: "Show Yab",
                                     words: "bring global shortcut hotkey")

    private static let fixed: [SettingsItem] = [
        SettingsItem(id: "peek-click", page: .tabs, title: "Peek links with", words: "shift option click modifier preview split"),
        SettingsItem(id: "peek-address", page: .appearance, title: "Show address bar in Peek", words: "peek preview url site address bar toolbar link"),
        SettingsItem(id: "link-routes-default", page: .spaces, title: "Default Space", words: "air traffic control recent fallback external links"),
        SettingsItem(id: "shield-lists", page: .privacy, title: "Filter lists", words: "ad blocker easylist privacy custom subscription update"),
        SettingsItem(id: "experimental-mail", page: .experimental, title: "Mail (Experimental)",
                     words: "experimental experiment labs beta mail email gmail imap smtp icloud zoho yahoo fastmail aol gmx yandex other mail account app password enable disable"),
        SettingsItem(id: "experimental-requests", page: .experimental, title: "Actions in the Field (Experimental)",
                     words: "experimental actions field omnibox request meeting return time off agent card preview"),
        SettingsItem(id: "experimental-menu-commands", page: .experimental, title: "More Commands in the Field (Experimental)",
                     words: "experimental commands command menu palette field omnibox actions search index catalog developer mode folders spaces windows exact names history suggestions enable disable"),
        SettingsItem(id: "experimental-switcher-strip", page: .experimental, title: "Recent Tabs Over the Page (Experimental)",
                     words: "experimental ctrl tab control tab recent tabs switcher row strip page blur card enable disable"),
        SettingsItem(id: "agents-row", page: .agents, title: "Agents in One Row",
                     words: "agents agent tabs routine routines terminal claude code codex hide sidebar row foot distracting quiet"),
        SettingsItem(id: "ai-instant-links", page: .whileYouBrowse, title: "Instant links",
                     words: "while you browse arc max shift return enter top result search comma multiple enable disable"),
        SettingsItem(id: "ai-link-previews", page: .whileYouBrowse, title: "Link previews",
                     words: "while you browse arc max 5 second hover summary shift links preview summaries enable disable"),
        // General
        showYab,
        SettingsItem(id: "live-folders", page: .liveFolders, title: "Live Folders",
                     words: "live folders smart tabs automatic github pull requests issues linear notion google drive figma youtube subscriptions feed turn on off enable disable"),
        SettingsItem(id: "live-folders-add", page: .liveFolders, title: "Add Live Folder",
                     words: "create new source github pull requests issues linear notion google drive figma youtube subscriptions"),
        SettingsItem(id: "live-folders-repo", page: .liveFolders, title: "Follow a GitHub Repository",
                     words: "repository repo github pull requests follow watch add owner"),
        SettingsItem(id: "default-browser", page: .general, title: "Default browser",
                     words: "make default links open from other apps mail slack",
                     within: "updates", shown: { _ in !Links.isDefault }),
        SettingsItem(id: "search-engine", page: .search, title: "Search with",
                     words: "search engine google duckduckgo ddg bing ecosia startpage kagi brave qwant custom default"),
        SettingsItem(id: "search-suggest", page: .search, title: "Suggest searches from your search engine",
                     words: "autocomplete suggestions google duckduckgo bing ecosia startpage kagi brave qwant",
                     within: "search-engine", shown: { $0.engine != .custom }),
        SettingsItem(id: "site-search", page: .search, title: "Sites",
                     words: "tab site search youtube github wikipedia chatgpt keyword alias shortcut opensearch arc scope add"),
        SettingsItem(id: "site-search-space", page: .search, title: "Keyboard shortcut",
                     words: "space or tab site search alias keyword shortcut start activate trigger chrome search engines"),
        SettingsItem(id: "quick-action:new-document", page: .search, title: "New document",
                     words: "quick action alias doc notion google docs create page shortcut"),
        SettingsItem(id: "quick-action:new-meeting", page: .search, title: "New meeting",
                     words: "quick action alias meet google meet create call shortcut"),
        SettingsItem(id: "warn-quit", page: .general, title: "Warn Before Quitting",
                     words: "warn confirm ask quit quitting close closing cmd q ⌘q accidentally"),
        SettingsItem(id: "reachable", page: .general, title: "Keep Mac Awake",
                     words: "awake sleep prevent idle power always on routines assistants bots remote reachable server login"),
        SettingsItem(id: "bring-in", page: .general, title: "Bring in from another browser",
                     words: "import move switch chrome arc dia brave edge tabs passwords extensions"),

        // Small Window
        SettingsItem(id: "small-links", page: .smallWindow, title: "Give links from other apps a small window",
                     words: "small little window arc links other apps mail slack messages open in yab peek"),
        SettingsItem(id: "small-key", page: .smallWindow, title: "Open a small window from any app",
                     words: "small little window arc hotkey shortcut global option command n new quick look anywhere"),

        // General, in builds with Chromium (`all`)
        SettingsItem(id: "engine-default", page: .general, title: "Default engine",
                     words: "engine chromium webkit chrome safari blink auto default new tabs memory general"),

        // General › Bring In
        SettingsItem(id: "bring-tabs", page: .bringIn, title: "Bring tabs in",
                     words: "import tabs pinned from another browser chrome arc dia brave edge profile"),
        SettingsItem(id: "import-passwords", page: .bringIn, title: "Bring passwords in",
                     words: "import passwords from another browser chrome arc dia brave edge"),
        SettingsItem(id: "import-cards", page: .bringIn, title: "Bring cards and addresses in",
                     words: "import cards credit card addresses autofill wallet from another browser chrome arc dia brave edge safari contacts"),
        SettingsItem(id: "import-firefox", page: .bringIn, title: "Bring in from Zen or Firefox",
                     words: "import zen firefox mozilla bookmarks history places profile passwords logins csv export"),
        SettingsItem(id: "import-bookmarks-file", page: .bringIn, title: "Bring bookmarks in from a file",
                     words: "import bookmarks html file export safari firefox netscape"),
        SettingsItem(id: "import-history-file", page: .bringIn, title: "Bring history in from a file",
                     words: "import history csv json file export safari visits"),
        SettingsItem(id: "other-history", page: .bringIn, title: "History from other browsers",
                     words: "history other browsers chrome arc dia brave edge read privacy suggestions habits usual tab agents stop"),
        SettingsItem(id: "import-extensions", page: .bringIn, title: "Bring extensions in",
                     words: "import extensions from another browser chrome arc dia brave edge"),

        // While You Browse
        SettingsItem(id: "tidy-tabs", page: .whileYouBrowse, title: "Tidy tabs",
                     words: "organize today tabs groups folders grouping arc max apple intelligence claude chatgpt"),
        SettingsItem(id: "tidy-titles", page: .whileYouBrowse, title: "Tidy tab titles",
                     words: "short names rename kept tabs arc max apple intelligence"),
        SettingsItem(id: "folder-names", page: .whileYouBrowse, title: "Folder names",
                     words: "tidy rename folders groups names"),
        SettingsItem(id: "tidy-downloads", page: .whileYouBrowse, title: "Tidy downloads",
                     words: "smart rename downloads downloaded files clear names arc max apple intelligence claude chatgpt"),

        // Agents
        SettingsItem(id: "bench", page: .agents, title: "Let agents use Yab",
                     words: "bench script socket automation testing developer drive"),
        SettingsItem(id: "agents-routines", page: .ai, title: "Routines",
                     words: "schedule every daily weekdays weekly monthly yearly month year recurring cron repeat routine automation add new suggested"),
        SettingsItem(id: "agents-messages", page: .agents, title: "Messages",
                     words: "sms text chats send one-time code two-factor 2fa verification imessage"),
        SettingsItem(id: "agents-elsewhere", page: .agents, title: "Ask on my other devices",
                     words: "iphone phone approve approval yes pay send handoff other mac sync face id touch id remote confirm"),
        SettingsItem(id: "agents-ask-sound", page: .agents, title: "Sound for questions",
                     words: "sound chime ding mute quiet silent alert notification question needs you"),
        SettingsItem(id: "agents-sites", page: .agents, title: "Sites",
                     words: "always never allow deny exceptions site rules post send upload without asking"),
        SettingsItem(id: "agents-pay", page: .agents, title: "Pay without asking up to",
                     words: "payment buy purchase checkout order limit threshold money spend card"),
        SettingsItem(id: "agents-asking", page: .agents, title: "Agents ask first",
                     words: "ask auto bypass permission mode confirm approve send pay delete upload sign in my tabs allow full access mac files terminal sandbox shell browser only"),
        SettingsItem(id: "ai-use", page: .ai, title: "AI in Yab",
                     words: "turn off ai disable ai no ai hide ai off when asked only on apple intelligence model claude chatgpt kill switch"),
        SettingsItem(id: "shortcuts-siri", page: .shortcuts, title: "Siri & App Intents",
                     words: "siri shortcuts app intents voice speech open tab"),
        SettingsItem(id: "dev-agents-allowed", page: .developers, title: "Let agents use Yab",
                     words: "outside agents claude code codex cli mcp yab command drive yab agents use yab bench"),
        SettingsItem(id: "agents-ask-opens", page: .ai, title: "Default view",
                     words: "asking about a page cmd j command j ask inline line field chat column open task default view"),
        SettingsItem(id: "agents-claude", page: .models, title: "Claude",
                     words: "claude code anthropic connect sign in plan subscription pro max skill mcp install"),
        SettingsItem(id: "agents-codex", page: .models, title: "ChatGPT",
                     words: "codex openai connect sign in plan subscription plus pro skill mcp install"),
        SettingsItem(id: "agents-cursor", page: .models, title: "Cursor",
                     words: "cursor plan subscription account connect login models"),
        SettingsItem(id: "agents-details", page: .agents, title: "How to Ask",
                     words: "disconnect remove how to ask connection details"),

        // Developers
        SettingsItem(id: "dev-offer", page: .developers, title: "Offer Developer Mode on local pages",
                     words: "developer mode localhost 127.0.0.1 test server port ask offer"),
        SettingsItem(id: "dev-side", page: .developers, title: "Developer Tools open",
                     words: "devtools inspector console dock bottom right left side"),
        SettingsItem(id: "dev-measure", page: .developers, title: "Measure in",
                     words: "rulers measure pixels rems units"),
        SettingsItem(id: "dev-json", page: .developers, title: "Show JSON as",
                     words: "json tree pretty print formatter viewer text as sent api response"),
        SettingsItem(id: "dev-servers", page: .developers, title: "Servers",
                     words: "developer mode localhost servers ports forget", shown: { _ in !DevSites.servers.isEmpty }),
        SettingsItem(id: "dev-command", page: .developers, title: "The yab command",
                     words: "yab cli command line terminal shell path install zshrc"),
        SettingsItem(id: "dev-claude", page: .developers, title: "Claude Code",
                     words: "skill mcp tools install add update remove claude code"),
        SettingsItem(id: "dev-codex", page: .developers, title: "Codex",
                     words: "skill mcp tools install add update remove codex openai"),
        SettingsItem(id: "dev-mcp", page: .developers, title: "Other MCP clients",
                     words: "mcp config json cursor zed windsurf vscode copy"),
        SettingsItem(id: "agents-memory", page: .ai, title: "Memory",
                     words: "memory remember notes about you"),
        SettingsItem(id: "agents-skills", page: .ai, title: "Skills",
                     words: "skills sites actions command j"),

        // AI › Models
        SettingsItem(id: "agents-model-tasks", page: .models, title: "Default model for tasks",
                     words: "model default tasks agent claude opus sonnet haiku fable gpt codex effort reasoning"),
        SettingsItem(id: "agents-model-commands", page: .models, title: "Default model for commands",
                     words: "model default commands selected text claude haiku gpt codex effort reasoning"),
        SettingsItem(id: "agents-model-drafts", page: .models, title: "Model for form drafts",
                     words: "model forms draft answers autofill claude sonnet effort"),
        SettingsItem(id: "agents-model-field", page: .models, title: "Reading the Field",
                     words: "model actions field omnibox jev typesafe openrouter system apple intelligence"),
        SettingsItem(id: "models-add", page: .models, title: "API Keys",
                     words: "api key keys anthropic openai openrouter jev typesafe own byok token add verify rotate"),
        SettingsItem(id: "models-mac", page: .models, title: "This Mac's model",
                     words: "apple intelligence on device foundation models local private"),
        SettingsItem(id: "models-lists", page: .models, title: "Models in lists",
                     words: "hide show models picker list manage"),

        // Agents › Memory
        SettingsItem(id: "agents-remember", page: .agentMemory, title: "Agents remember what they learn about you",
                     words: "memory remember forget notes on off switch"),
        SettingsItem(id: "memory-notes", page: .agentMemory, title: "Your notes",
                     words: "memory notes about you people companies sites projects concepts days read edit correct change",
                     within: "agents-remember", shown: { _ in !MemoryShelf.shared.notes.isEmpty }),
        SettingsItem(id: "memory-finder", page: .agentMemory, title: "Show notes in Finder",
                     words: "memory notes finder folder markdown files",
                     within: "agents-remember", shown: { _ in !MemoryShelf.shared.notes.isEmpty }),
        SettingsItem(id: "memory-forget", page: .agentMemory, title: "Forget everything",
                     words: "memory forget erase delete clear wipe notes reset",
                     within: "agents-remember", shown: { _ in !MemoryShelf.shared.notes.isEmpty }),

        // Agents › Skills
        SettingsItem(id: "skills-new", page: .agentSkills, title: "New Skill",
                     words: "skill skills new create make add write site"),
        SettingsItem(id: "skills-yours", page: .agentSkills, title: "Your skills",
                     words: "skills skill mine own edit change folder",
                     within: "skills-new", shown: { _ in !SkillShelf.shared.yours.isEmpty }),
        SettingsItem(id: "skills-built-in", page: .agentSkills, title: "Built-in skills",
                     words: "skills skill built in duplicate copy edit github gmail notion slack linear youtube"),

        // Appearance
        SettingsItem(id: "theme", page: .appearance, title: "Theme",
                     words: "appearance look light dark system mode night follow"),
        SettingsItem(id: "app-icon", page: .appearance, title: "App icon",
                     words: "dock icon default dev flat watercolor glass opal smoked chrome amber red enamel"),
        SettingsItem(id: "sidebar", page: .appearance, title: "Sidebar",
                     words: "tabs in a sidebar top vertical horizontal left right column side bar layout off"),
        SettingsItem(id: "sidebar-button", page: .appearance, title: "Show sidebar button",
                     words: "hide show sidebar toggle button toolbar narrow reload overflow"),
        SettingsItem(id: "tab-icons", page: .appearance, title: "Tab icons",
                     words: "letter favicon site icon glyph pinned"),
        SettingsItem(id: "space-dots", page: .appearance, title: "Spaces",
                     words: "space icons emoji dots dia foot switcher bottom sidebar cleaner"),
        SettingsItem(id: "density", page: .appearance, title: "Density",
                     words: "sidebar row height size compact comfortable roomy dense spacing pins tabs bigger smaller arc"),
        SettingsItem(id: "address-bar", page: .appearance, title: "Address bar",
                     words: "url bar toolbar top bar location site domain link copy back forward reload show hide hidden chrome safari"),
        SettingsItem(id: "field-size", page: .appearance, title: "Field",
                     words: "compact small little omnibox command bar address field search box size cmd-l cmd-t spotlight dropdown"),
        // A choice in Address bar's menu and two in the Fonts sheet: found,
        // they bring the row they live in into view.
        SettingsItem(id: "full-url", page: .appearance, title: "Full URL",
                     words: "show full url complete address path protocol toolbar location",
                     within: "address-bar", shown: { _ in false }),
        SettingsItem(id: "page-zoom", page: .websites, title: "Page size",
                     words: "default page zoom scale size larger smaller websites accessibility magnify aa"),
        SettingsItem(id: "page-font-size", page: .websites, title: "Font size",
                     words: "text size type typography webpage",
                     within: "page-fonts", shown: { _ in false }),
        SettingsItem(id: "page-fonts", page: .websites, title: "Fonts",
                     words: "customize standard serif sans fixed width monospace typeface typography restore defaults"),
        SettingsItem(id: "dark-pages", page: .websites, title: "Dark pages",
                     words: "dark night theme reader invert black dark reader mode websites brightness contrast warmth kept light"),
        SettingsItem(id: "reading-mode", page: .websites, title: "Reading mode",
                     words: "reading reader article themes"),
        SettingsItem(id: "site-notifications", page: .websites, title: "Notifications",
                     words: "site website notifications permission permissions allow deny block push remove reset"),
        SettingsItem(id: "reader-theme", page: .reading, title: "Reading mode theme",
                     words: "reading appearance reader themes original quiet paper bold calm focus colors sepia article"),
        SettingsItem(id: "reader-light", page: .reading, title: "Reading mode appearance",
                     words: "reading reader light dark match mac night"),
        SettingsItem(id: "reader-size", page: .reading, title: "Reading text size",
                     words: "reading mode reader text size font size larger smaller points aa"),
        SettingsItem(id: "reader-wide", page: .reading, title: "Wide page",
                     words: "reading mode reader wide page column width"),
        SettingsItem(id: "reader-font", page: .reading, title: "Reading font",
                     words: "reading mode reader font face typeface new york charter iowan palatino athelas georgia sf pro"),
        SettingsItem(id: "reader-customize", page: .reading, title: "Customize reading theme",
                     words: "reading mode reader customize bold text line spacing character word margins justify reset"),
        SettingsItem(id: "reader-colors", page: .reading, title: "Custom colors",
                     words: "reading mode reader custom colors background text theme"),
        SettingsItem(id: "page-minimum-font", page: .websites, title: "Minimum font size",
                     words: "small text accessibility readable websites",
                     within: "page-fonts", shown: { _ in false }),
        SettingsItem(id: "bookmarks-bar", page: .appearance, title: "Bookmarks bar",
                     words: "bookmarks bar favorites toolbar row top show hide new tab always never"),
        SettingsItem(id: "bookmarks-style", page: .appearance, title: "Bookmarks show",
                     words: "bookmarks bar icons only names folders favicons compact titles labels style",
                     shown: { $0.bookmarkBar == .always }),
        SettingsItem(id: "window", page: .appearance, title: "Window",
                     words: "backdrop background edge to edge card color site's match follow bar "
                         + Backdrop.allCases.map(\.title).joined(separator: " ")),
        SettingsItem(id: "color", page: .appearance, title: "Look",
                     words: "color colour gray backdrop swatch tint wallpaper your own custom picker field dot any grain noise texture paper film dial knob amount rough fine lightness space spaces each gradient multiple colors harmony linked add remove sidebar"),
        // The wave's step past its end, in Look's editor.
        SettingsItem(id: "glass", page: .appearance, title: "Glass",
                     words: "glass liquid transparency transparent desktop window frame see through clear frosted",
                     within: "color", shown: { _ in false }),
        // Under Look's color editor; with spaces on Spaces, where Look's row leads.
        SettingsItem(id: "browser-look", page: .appearance, title: "Match Arc or Chrome",
                     words: "import theme colors look spaces profiles another browser bring",
                     within: "color", shown: { _ in false }),

        // Tabs
        SettingsItem(id: "tidy", page: .tabs, title: "Close tabs you haven't opened in",
                     words: "archive auto close tidy clean up old stale arc"),
        SettingsItem(id: "agents-cleanup", page: .tabs, title: "Close agent tabs",
                     words: "agent ai clean up automatic cleanup temporary task tabs fifteen 15 minutes hour never unread keep"),
        SettingsItem(id: "switcher-reach", page: .tabs, title: "Recent tabs come from",
                     words: "ctrl tab control tab recent tabs switcher every all spaces this space workspace arc dia cycle",
                     shown: { $0.usesSpaces }),
        SettingsItem(id: "awake-sites", page: .tabs, title: "Always keep these sites awake",
                     words: "keep active never sleep suspend hibernate exceptions whatsapp slack discord gmail spotify memory saver reload discard ram"),
        // Chrome's Settings › Performance › Energy Saver (EnergySaver).
        SettingsItem(id: "energy-saver", page: .tabs, title: "Energy Saver",
                     words: "battery saver power saving low power mode energy battery life unplugged 20% frame rate fps smooth scrolling video performance chrome"),
        SettingsItem(id: "page-kept", page: .search, title: "On a Page",
                     words: "this page over a page field keep kept remove copy URL markdown link duplicate tab always actions float video translate reading mode mute actual size PDF fill sign tracking extensions buttons commands userscripts developer errors inspect element reload cache localhost developer mode hidden show add row priority order reorder"),
        SettingsItem(id: "field-fallbacks", page: .search, title: "While You Type",
                     words: "fallback commands below results raycast matches open tabs history bookmarks settings return"),
        SettingsItem(id: "field-sections", page: .search, title: "Before You Type",
                     words: "field new tab empty cmd t sections blocks hide customize order reorder now favorites recent tabs frequent quick actions reading mode"),
        SettingsItem(id: "frequent-reach", page: .search, title: "Frequent comes from",
                     words: "frequent field new tab spaces every all this space workspace", shown: { $0.usesSpaces }),
        SettingsItem(id: "suggestions", page: .search, title: "Suggestions",
                     words: "suggestions hints new tab empty field copied link meeting calendar habit usually now raycast"),
        SettingsItem(id: "spaces", page: .spaces, title: "Spaces",
                     words: "spaces profiles workspaces sets of tabs work personal arc switch control number sign ins cookies"),
        SettingsItem(id: "space-list", page: .spaces, title: "Order of spaces",
                     words: "reorder move drag place order control number"),
        SettingsItem(id: "add-space", page: .spaces, title: "Add Space",
                     words: "new create make space", shown: { $0.usesSpaces }),
        SettingsItem(id: "pins", page: .spaces, title: "Pins",
                     words: "pinned tabs pins in every space each space shared favorites essentials arc zen same everywhere",
                     shown: { $0.usesSpaces }),
        SettingsItem(id: "link-routes", page: .spaces, title: "Air Traffic Control",
                     words: "air traffic control flight control arc route routes links from other apps slack mail open always site space rules",
                     shown: { $0.usesSpaces && (BrowserWindows.shared.activeBrowser?.spaces.count ?? 0) > 1 }),
        SettingsItem(id: "boosts", page: .boosts, title: "Boosts",
                     words: "boosts userscripts user.js tampermonkey greasemonkey styles site changes customize site store claude agent"),
        SettingsItem(id: "boost-list", page: .boosts, title: "Turn boosts on or off",
                     words: "boosts userscripts list select delete turn on off enable disable order reorder drag history restore compare"),
        SettingsItem(id: "boosts-sign-ins", page: .boosts, title: "Boosts for each sign-in",
                     words: "boosts sign ins spaces separate profiles userscripts", within: "boosts",
                     shown: { _ in BrowserWindows.shared.activeBrowser.map { SignIns.split($0) } ?? false }),
        SettingsItem(id: "link-folders", page: .tabs, title: "⌘-clicking links makes folders",
                     words: "auto groups tab groups dia command click cmd middle click links folder group together opened from page"),
        SettingsItem(id: "folder-emoji", page: .tabs, title: "Add emoji to new folders",
                     words: "emoji icon folder tab groups dia mark sites ai name"),
        SettingsItem(id: "opt-shift-folders", page: .tabs, title: "⌥⇧-clicking a tab makes a folder",
                     words: "option shift alt click tab group dia folder together opens tab in group"),
        SettingsItem(id: "today-every-window", page: .tabs, title: "Today's tabs in every window",
                     words: "windows same tabs shared every window new window arc dia unpinned today consistent sync across windows"),
        SettingsItem(id: "meeting-folders", page: .tabs, title: "Group tabs for meetings",
                     words: "meeting call join calendar folder group tabs dia automatically time left zoom meet"),
        SettingsItem(id: "float-leave", page: .tabs, title: "Picture in Picture automatically",
                     words: "floating video call meet zoom teams pip picture in picture youtube netflix switch tabs leave another app background arc disable off"),
        SettingsItem(id: "float-snap", page: .tabs, title: "Snap Picture in Picture to edges",
                     words: "pip picture in picture video float window snap snapping edges corners free position placement magnet magnetic прилипание края углы пип"),
        SettingsItem(id: "player", page: .tabs, title: "Show media player",
                     words: "media player now playing music audio playback controls sidebar spaces hide hidden show off"),
        SettingsItem(id: "meetings", page: .tabs, title: "Your next meeting on a pinned calendar",
                     words: "meeting calendar google meet zoom teams join countdown event arc live calendar control command j"),

        // Extensions
        SettingsItem(id: "add-extension", page: .extensions, title: "Add an extension",
                     words: "install chrome web store link id paste url crx import bring from another browser chrome arc dia brave edge unpacked folder manifest developer local"),
        SettingsItem(id: "extensions-private", page: .extensions, title: "Allow in private tabs",
                     words: "extensions incognito private tabs shy allow run"),

        // Mail
        SettingsItem(id: "mail", page: .mail, title: "Mail",
                     words: "email gmail inbox google"),
        SettingsItem(id: "mail-accounts", page: .mail, title: "Mail accounts",
                     words: "gmail connect disconnect sign in google account add", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-all-accounts", page: .mail, title: "Show in All Accounts",
                     words: "unified inbox all inboxes combined accounts include exclude separate count badge spark",
                     shown: { _ in !MailArrival.shows && MailCenter.shared.accounts.count > 1 }),
        SettingsItem(id: "mail-pin", page: .mail, title: "Mail pin",
                     words: "pin envelope count door", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-default", page: .mail, title: "Default mail app",
                     words: "mailto mail links email client default handler other apps make default",
                     shown: { _ in !MailArrival.shows && !MailDefault.isDefault }),
        SettingsItem(id: "mail-notify", page: .mailNotify, title: "Notifications for new mail",
                     words: "notify notification banner alert new mail needs you everything inbox allow", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-needs", page: .mailInbox, title: "What needs you",
                     words: "needs you important asks question priority people everything sort", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-window", page: .mailInbox, title: "How far back",
                     words: "week month window archive older age connect first", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-ads", page: .mailInbox, title: "Ads and promos",
                     words: "ads promotions promos social marketing hide spam newsletters archive", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-pitches", page: .mailInbox, title: "Cold pitches",
                     words: "cold pitch sales outreach decline no thanks stranger reply ahead", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-people", page: .mailAgents, title: "People in memory",
                     words: "people memory contacts who person page signature how you write", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-badge", page: .mailNotify, title: "Count on the pin and the Dock",
                     words: "badge dock icon count unread needs you number pin", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-sorting", page: .mailInbox, title: "Sorting",
                     words: "sorting kinds invoices invitations shipping codes newsletters cold pitches label gmail phone goes to auto labels",
                     shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-splits", page: .mailInbox, title: "Splits",
                     words: "split splits vip team calendar receipts dev skip the inbox auto archive order hide empty lists your lists notify",
                     shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-splits-hide", page: .mailInbox, title: "Hide empty splits",
                     words: "split splits empty hide column tab", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-sense", page: .mailReading, title: "Sort and sum up on this Mac",
                     words: "sort split needs you apple intelligence summary gist on device", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-summaries", page: .mailReading, title: "Split summaries",
                     words: "split summary summaries line claude chatgpt codex ai what matters", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-pixels", page: .mailReading, title: "Block tracking pixels",
                     words: "tracking pixel privacy images read receipt opened", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-pdf-yab", page: .mailReading, title: "Open PDFs from Mail in Yab",
                     words: "pdf attachment file open preview sign fill contract tab", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-motion", page: .mailReading, title: "Mail animations",
                     words: "animations motion reduce still fly morph transitions fast speed", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-ahead", page: .mailWriting, title: "Write replies ahead",
                     words: "draft replies ahead claude chatgpt codex ai write", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-undo", page: .mailWriting, title: "Undo send",
                     words: "undo send delay seconds cancel", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-reads", page: .mailWriting, title: "Read statuses",
                     words: "read status receipt receipts opened open seen tracking pixel superhuman", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-hours", page: .mailCalendar, title: "Working hours for free slots",
                     words: "calendar free slots availability working hours schedule meeting time", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-slot-length", page: .mailCalendar, title: "Slot length",
                     words: "calendar free slots availability length minutes meeting", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-booking", page: .mailCalendar, title: "Booking link",
                     words: "calendly cal.com booking link schedule availability calendar", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-agents", page: .mailAgents, title: "Mail you hand to your AI",
                     words: "agents do it claude chatgpt codex tools draft consent read let", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-ahead-consent", page: .mailAgents, title: "Replies written ahead",
                     words: "draft replies ahead claude chatgpt codex ai write consent", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-agents-others", page: .mailAgents, title: "Mail tools in other apps",
                     words: "mcp yab mcp cursor zed windsurf other apps mail tools", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-memory", page: .mailAgents, title: "Let agents search all your mail",
                     words: "agents search index memory five years mail", shown: { _ in !MailArrival.shows }),
        SettingsItem(id: "mail-signature-replies", page: .mailWriting, title: "Signature in replies and forwards",
                     words: "signature signatures sign off replies forwards gmail", shown: { _ in !MailArrival.shows }),
        // Snippets
        SettingsItem(id: "snippets-list", page: .snippets, title: "Snippets",
                     words: "snippets templates canned replies text expansion semicolon"),
        SettingsItem(id: "snippets-semicolon", page: .snippets, title: "Type ; and a name in any box",
                     words: "snippets semicolon fields boxes pages expand"),
        SettingsItem(id: "snippets-offer", page: .snippets, title: "Offer to keep what you paste often",
                     words: "snippets paste pasted often offer save card"),
        // Passwords
        SettingsItem(id: "use-yab-passwords", page: .passwords, title: "Use Yab's passwords",
                     words: "default password manager built in own keychain fill save turn off"),
        SettingsItem(id: "connect-password-manager", page: .passwords, title: "Connect Password Manager",
                     words: "password manager connect 1password bitwarden nordpass proton pass dashlane lastpass apple passwords icloud extension unlock master password agents sign in"),
        SettingsItem(id: "your-passwords", page: .passwords, title: "Saved in Yab",
                     words: "keychain touch id see show manage accounts logins"),
        SettingsItem(id: "save-passwords", page: .passwords, title: "Offer to save passwords",
                     words: "remember ask save logins"),
        SettingsItem(id: "fill", page: .passwords, title: "Fill in passwords",
                     words: "autofill auto fill login sign in accounts"),
        SettingsItem(id: "prove", page: .passwords, title: "Ask for \(Vault.proof) before filling",
                     words: "touch id fingerprint password confirm lock protect autofill fill biometric"),
        SettingsItem(id: "passkeys", page: .passwords, title: "Offer passkeys",
                     words: "passkey webauthn touch id icloud"),
        SettingsItem(id: "codes-mail", page: .autofill, title: "One-time codes from your mail",
                     words: "one time code otp verification 2fa email mail gmail sign in"),
        SettingsItem(id: "codes-texts", page: .autofill, title: "One-time codes from Messages",
                     words: "one time code otp verification 2fa sms text messages imessage sign in"),
        SettingsItem(id: "codes-archive", page: .autofill, title: "Archive code mails after use",
                     words: "one time code otp archive inbox mail", shown: { _ in MailCenter.shared.connected }),
        SettingsItem(id: "never", page: .passwords, title: "Sites you turned down",
                     words: "never save refused blocked forget exceptions",
                     within: "save-passwords", shown: { _ in !Vault.never.isEmpty }),
        SettingsItem(id: "your-cards", page: .autofill, title: "You, your cards and addresses",
                     words: "profile me about linkedin credit debit card cards payment pay checkout addresses shipping billing autofill wallet manage"),
        SettingsItem(id: "bring-cards", page: .autofill, title: "Bring cards and addresses in",
                     words: "import cards credit card addresses from another browser chrome arc dia brave edge safari contacts"),
        SettingsItem(id: "save-cards", page: .autofill, title: "Offer to save cards and addresses",
                     words: "remember ask save credit card payment address shipping"),
        SettingsItem(id: "fill-cards", page: .autofill, title: "Fill in cards and addresses",
                     words: "autofill auto fill credit card payment checkout address shipping touch id"),
        SettingsItem(id: "fill-forms", page: .autofill, title: "Fill whole forms",
                     words: "autofill form forms profile linkedin twitter x company title registration sign up application luma answers"),
        SettingsItem(id: "draft-forms", page: .autofill, title: "Draft answers to questions with AI",
                     words: "draft answer questions form claude chatgpt codex ai write why"),

        // Downloads, in General
        SettingsItem(id: "save-to", page: .general, title: "Save downloads to",
                     words: "downloads folder location where directory change"),
        SettingsItem(id: "ask-where", page: .general, title: "Ask where to save each file",
                     words: "downloads prompt choose location every file"),
        SettingsItem(id: "upload-finder", page: .general, title: "Choose files to upload in Finder",
                     words: "upload attach file picker open panel finder recent system dialog"),

        // Sync, while it is on
        SettingsItem(id: "sync-devices", page: .sync, title: "Add a Device",
                     words: "sync iphone phone mac another device pair code join devices", shown: { _ in SyncCenter.shared.on }),
        SettingsItem(id: "sync-history", page: .sync, title: "History of the last two weeks",
                     words: "sync history visits iphone devices", shown: { _ in SyncCenter.shared.on }),
        SettingsItem(id: "sync-passwords", page: .sync, title: "Passwords, cards and addresses",
                     words: "sync passwords cards addresses two-factor iphone devices", shown: { _ in SyncCenter.shared.on }),
        SettingsItem(id: "sync-addons", page: .sync, title: "Extensions and plugins",
                     words: "sync extensions plugins boosts devices", shown: { _ in SyncCenter.shared.on }),

        // Privacy
        SettingsItem(id: "crashes", page: .privacy, title: "Automatically send crash reports",
                     words: "crash crashes quit unexpectedly diagnostics report sent to yab telemetry"),
        SettingsItem(id: "activity", page: .privacy, title: "Count me in anonymous usage stats",
                     words: "daily activity usage statistics analytics telemetry anonymous count active days sent to yab"),
        SettingsItem(id: "cache", page: .privacy, title: "Clear cache",
                     words: "cache data storage clear"),
        SettingsItem(id: "cookies", page: .privacy, title: "Cookies and sign-ins",
                     words: "cookies sign out log out website data clear"),
        SettingsItem(id: "shield", page: .privacy, title: "Block ads and trackers",
                     words: "ad blocker adblock ublock content blocking tracking shield"),
        SettingsItem(id: "safe-browsing", page: .privacy, title: "Warn before phishing sites",
                     words: "phishing safe browsing malware deceptive fake scam list warn"),

        // Privacy › History
        SettingsItem(id: "your-history-open", page: .history, title: "Your history",
                     words: "history visited pages see show open browse"),
        SettingsItem(id: "diary-text", page: .history, title: "Remember what pages say",
                     words: "history search text content index semantic remember"),
        SettingsItem(id: "history", page: .history, title: "Clear history",
                     words: "history visited addresses forget erase clear"),
        SettingsItem(id: "capture", page: .privacy, title: "Camera and microphone",
                     words: "permissions mic webcam video forget allowed refused"),

        // About
        SettingsItem(id: "updates", page: .general, title: "Check for updates",
                     words: "update version new release download restart relaunch"),
        SettingsItem(id: "feedback", page: .about, title: "Send feedback",
                     words: "feedback bug report problem contact"),
        SettingsItem(id: "community", page: .about, title: "Community",
                     words: "community chat group x twitter people join talk"),
        SettingsItem(id: "credits", page: .about, title: "Credits",
                     words: "credits thanks search office commun arc raycast inspiration"),
        SettingsItem(id: "thanks", page: .credits, title: "Search, Arc and Raycast",
                     words: "credits thanks search office commun arc raycast inspiration"),
        SettingsItem(id: "acknowledgements", page: .credits, title: "Acknowledgements",
                     words: "acknowledgements licenses open source notices third party"),
        SettingsItem(id: "invite", page: .about, title: "Invite Friends",
                     words: "invite friend friends share gift send link referral"),
        SettingsItem(id: "invite-message", page: .inviteFriends, title: "Message and link",
                     words: "invite message link copy send share text"),
        SettingsItem(id: "invite-icons", page: .inviteFriends, title: "Icons from friends",
                     words: "icons unlock wax seal friendship bracelet golden ticket yearbook rewards"),
        SettingsItem(id: "best-friend", page: .inviteFriends, title: "Best Friend",
                     words: "best friend bff charm halves"),
        SettingsItem(id: "best-color", page: .bestFriend, title: "Your half's color",
                     words: "charm half color colour mint lilac sky rose coral lemon indigo"),
        SettingsItem(id: "best-shares", page: .bestFriend, title: "Let them see when I'm in Yab",
                     words: "presence online open share best friend see"),
        SettingsItem(id: "best-icon", page: .bestFriend, title: "Show it in the icon",
                     words: "charm apart away gap dock icon effect"),
        SettingsItem(id: "best-message", page: .bestFriend, title: "Message to your best friend",
                     words: "best friend message link copy"),
        SettingsItem(id: "welcome", page: .about, title: "Welcome",
                     words: "intro introduction onboarding tour show again start"),
    ]
}

/// One line of the sidebar while it is searched: a page, or a row on one.
enum SettingsResult: Hashable {
    case page(SettingsPage)
    case item(SettingsItem)

    var page: SettingsPage {
        switch self {
        case .page(let page): return page
        case .item(let item): return item.page
        }
    }

    /// The pages that answered, best first, each followed by its rows that
    /// did, and which of all of them answered best, for Return to take.
    @MainActor
    static func search(_ query: String, bundle: Bundle = .main) -> (rows: [SettingsResult], best: SettingsResult?) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return (SettingsPage.sidebar.map(SettingsResult.page), nil) }

        var groups: [(page: SettingsPage, score: Double, own: Double?, items: [(SettingsItem, Double)])] = []
        let all = SettingsItem.all
        for page in SettingsPage.allCases where page.available {
            let own = page.found(query, bundle: bundle)
            let items = all
                .filter { $0.page == page }
                .compactMap { item in item.score(query, bundle: bundle).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }
            guard own != nil || !items.isEmpty else { continue }
            let score = max(own ?? 0, items.first?.1 ?? 0)
            groups.append((page, score, own, items))
        }
        // Stable for a tie, so the sidebar keeps its own order.
        groups = groups.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)

        var rows: [SettingsResult] = []
        var best: (SettingsResult, Double)?
        for group in groups {
            rows.append(.page(group.page))
            if let own = group.own, best == nil || own > best!.1 { best = (.page(group.page), own) }
            for (item, score) in group.items {
                rows.append(.item(item))
                // A row has to beat its page outright: "tabs" is the page.
                if best == nil || score > best!.1 { best = (.item(item), score) }
            }
        }
        return (rows, best?.0)
    }
}

/// How well some typed words name a thing, the way a launcher reads them:
/// each word has to begin a word of the title, or of the other words it
/// answers to, or at least run through the title in order, "apper" is
/// still Appearance. Nil when any word finds nothing.
enum SettingsMatch {
    static func score(_ query: String, title: String, words: String) -> Double? {
        Prepared(title: title, words: words).score(query)
    }

    /// A title and its words folded and split once, for a thing scored
    /// at every key (SettingsPage in the field).
    struct Prepared {
        let name: String
        let named: [String]
        let other: [String]
        let listed: [Substring]

        init(title: String, words: String) {
            name = SettingsMatch.fold(title)
            named = Wording.split(name).map(String.init)
            other = Wording.split(SettingsMatch.fold(words)).map(String.init)
            listed = words.lowercased().split(separator: " ")
        }

        func score(_ query: String) -> Double? {
            let query = SettingsMatch.fold(query)
            let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { return nil }

            // Keys, "⌥⌘Y" or "cmd y", are matched whole against the keys a row
            // lists, since the letters alone would find every Y there is.
            if let keys = Hotkey.typed(query) {
                // A key named is that keystroke and no other; modifiers alone,
                // "⌥⌘", are every keystroke that holds them.
                let keys = keys.lowercased()
                if Hotkey.isWhole(keys) { return listed.contains { $0 == keys } ? 5 : nil }
                return listed.contains { $0.contains(keys) } ? 3 : nil
            }
            var total = 0.0
            for token in tokens {
                if named.contains(where: { $0.hasPrefix(token) }) {
                    total += 3
                } else if token.count < 2 {
                    // One letter is only ever the start of a word in the name.
                    return nil
                } else if other.contains(where: { $0.hasPrefix(token) }) {
                    total += 2
                } else if token.count >= 3, name.contains(token) {
                    total += 1.5
                } else if token.count >= 3, SettingsMatch.runs(token, through: named) {
                    total += 1
                } else {
                    return nil
                }
            }
            var score = total / Double(tokens.count)
            // The title said from its start, "dark th" before "the dark one".
            if name.hasPrefix(query) { score += 2 }
            return score
        }
    }

    /// Lowercased, without accents, for "color" and "Color" and "cölor".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The letters in order through one word of the title, from its first
    /// letter: "apper" in Appearance, "dwnld" in Downloads. Not across
    /// words, where almost anything would run through a long title.
    fileprivate static func runs(_ token: String, through words: [String]) -> Bool {
        words.contains { word in
            guard word.first == token.first else { return false }
            var rest = Substring(token)
            for ch in word where ch == rest.first {
                rest = rest.dropFirst()
                if rest.isEmpty { return true }
            }
            return false
        }
    }
}

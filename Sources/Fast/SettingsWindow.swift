import AppKit
import Combine
import SwiftUI

// Settings, in a window of their own, the way a Mac app keeps them, and not
// a plate over the page. AppKit owns the frame: the title bar, the back and
// forward in the toolbar, the sidebar with its search. SwiftUI only fills the
// page on the right, as the system's grouped form, so every switch, menu and
// button is the one the rest of the Mac uses.

/// The pages down the sidebar, and the words each one answers to when the
/// search at the top of it is typed into.
///
/// Two kinds. The basics, how yab looks and
/// behaves, wear a gray glyph and are plain rows. A feature, a thing with a
/// life of its own, wears its color on a tile and opens with its name and
/// what it is for; a feature with more to it than fits on one page keeps
/// the rest a page further in, reached from a row that wears its tile.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, search, appearance, websites, tabs, sync, shortcuts
    case ai, mail, snippets, spaces, liveFolders, smallWindow, reading, passwords, autofill, privacy, extensions, boosts, developers
    case experimental, about, inviteFriends
    /// A page further in: never in the sidebar, which lights its parent.
    case bringIn, engine, history, models, commands, agents, assistants, siteButtons, whileYouBrowse, agentRoutines, agentMemory, agentSkills, credits, appIcon, bestFriend
    case mailInbox, mailNotify, mailReading, mailWriting, mailCalendar, mailAgents, mailBlocked

    var id: String { rawValue }

    /// The pages down the sidebar, in their groups: the basics, the
    /// features, and About on its own at the foot.
    static var sidebar: [SettingsPage] { allCases.filter { $0.parent == nil && $0.available } }

    var available: Bool {
        if self == .engine { return EngineRules.available }
        return top != .mail || MailExperiment.enabled()
    }

    /// The page a page further in is reached from.
    var parent: SettingsPage? {
        switch self {
        case .bringIn, .engine: return .general
        case .history: return .privacy
        case .credits: return .about
        case .appIcon: return .appearance
        case .reading: return .websites
        case .bestFriend: return .inviteFriends
        // AI is Raycast's: the models underneath, the two ways yab uses
        // them (commands on text, agents on tasks), and what agents keep.
        case .models, .commands, .agents, .assistants, .siteButtons, .whileYouBrowse, .agentRoutines, .agentMemory, .agentSkills: return .ai
        // Mail as AI is: the accounts on its page, the rest a page each.
        case .mailInbox, .mailNotify, .mailReading, .mailWriting, .mailCalendar, .mailAgents, .mailBlocked: return .mail
        default: return nil
        }
    }

    /// The page the sidebar lights while this one is showing.
    var top: SettingsPage { parent ?? self }

    /// 0 the basics, 1 the features, 2 About.
    var group: Int {
        switch top {
        case .general, .search, .appearance, .websites, .tabs, .sync, .shortcuts: return 0
        case .about, .inviteFriends: return 2
        default: return 1
        }
    }

    var title: String { SettingsWords.text(englishTitle) }

    /// Stable English text remains a search alias in every language.
    var englishTitle: String {
        switch self {
        case .general: return "General"
        case .search: return "Field"
        case .appearance: return "Appearance"
        case .websites: return "Websites"
        case .tabs: return "Tabs"
        case .spaces: return "Spaces"
        case .liveFolders: return "Live Folders"
        case .sync: return "Sync"
        case .mail: return "Mail"
        case .extensions: return "Extensions"
        case .engine: return "Engines for Sites"
        case .boosts: return "Boosts"
        case .ai: return "AI"
        case .models: return "Models"
        case .agents: return "Agents"
        case .assistants: return "Assistants"
        case .siteButtons: return "Buttons on Sites"
        case .whileYouBrowse: return "While You Browse"
        case .commands: return "Commands"
        case .smallWindow: return "Small Window"
        case .reading: return "Reading Mode"
        case .passwords: return "Passwords"
        case .autofill: return "Autofill"
        case .privacy: return "Privacy"
        case .shortcuts: return "Shortcuts"
        case .developers: return "Developers"
        case .experimental: return "Experimental"
        case .about: return "About"
        case .inviteFriends: return "Invite Friends"
        case .bestFriend: return "Best Friend"
        case .bringIn: return "Bring In"
        case .history: return "History"
        case .agentRoutines: return "Routines"
        case .agentMemory: return "Memory"
        case .agentSkills: return "Skills"
        case .credits: return "Credits"
        case .appIcon: return "App Icon"
        case .mailInbox: return "Inbox"
        case .mailNotify: return "Notifications"
        case .mailReading: return "Reading"
        case .mailWriting: return "Writing"
        case .snippets: return "Snippets"
        case .mailCalendar: return "Calendar"
        case .mailAgents: return "Agents"
        case .mailBlocked: return "Blocked"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .search: return "magnifyingglass"
        case .appearance: return "paintpalette"
        case .websites: return "globe"
        case .tabs: return "rectangle.split.3x1"
        case .spaces: return "square.2.layers.3d"
        case .liveFolders: return "folder"
        case .sync: return "arrow.triangle.2.circlepath"
        case .mail: return "envelope"
        case .extensions: return "puzzlepiece.extension"
        case .engine: return "square.2.layers.3d"
        case .boosts: return "wand.and.stars"
        case .ai: return "sparkles"
        case .models: return "cpu"
        case .agents: return "agent.face"
        case .assistants: return "point.3.connected.trianglepath.dotted"
        case .siteButtons: return "cursorarrow.click.2"
        case .whileYouBrowse: return "wand.and.stars"
        case .commands: return "character.cursor.ibeam"
        case .smallWindow: return "macwindow.on.rectangle"
        case .reading: return "book.open"
        case .passwords: return "key"
        case .autofill: return "creditcard"
        case .privacy: return "hand.raised"
        case .shortcuts: return "command"
        case .about: return "info.circle"
        case .inviteFriends: return "brand.blobplus"
        case .bestFriend: return "brand.charm"
        case .bringIn: return "globe"
        case .history: return "clock"
        case .agentRoutines: return "clock.arrow.circlepath"
        case .agentMemory: return "notes"
        case .agentSkills: return "script.ai"
        case .credits: return "heart"
        case .appIcon: return "app"
        case .developers: return "chevron.left.forwardslash.chevron.right"
        case .experimental: return "flask"
        case .mailInbox: return "tray.and.arrow.down"
        case .mailNotify: return "bell"
        case .mailReading: return "doc"
        case .mailWriting: return "character.cursor.ibeam"
        case .snippets: return "character.cursor.ibeam"
        case .mailCalendar: return "calendar"
        case .mailAgents: return "agent.face"
        case .mailBlocked: return "hand.raised"
        }
    }

    /// The color of a feature's tile; nil for a basic, whose glyph sits
    /// in a gray well.
    var tint: NSColor? {
        switch self {
        case .spaces: return .systemGreen
        case .liveFolders: return .systemOrange
        case .mail: return .systemBlue
        case .ai: return .systemPurple
        case .models: return .systemRed
        case .agents: return .systemBlue
        case .assistants: return NSColor(srgbRed: 34.0 / 255, green: 168.0 / 255, blue: 143.0 / 255, alpha: 1)
        case .siteButtons: return .systemIndigo
        case .whileYouBrowse: return .systemTeal
        case .commands: return .systemPurple
        case .smallWindow: return .systemPink
        case .reading: return .systemGreen
        case .passwords: return .systemGray
        case .autofill: return .systemGreen
        case .privacy: return .systemBlue
        case .extensions: return .systemIndigo
        case .engine: return .systemTeal
        case .boosts: return .systemPurple
        case .bringIn: return .systemGray
        case .history: return .systemOrange
        case .agentRoutines: return .systemPink
        case .agentMemory: return .systemBrown
        case .agentSkills: return .systemCyan
        case .credits: return .systemPink
        case .inviteFriends, .bestFriend: return .systemYellow
        // The tape a Developer Mode tab wears, as far as a tile goes.
        case .developers: return .systemOrange
        case .experimental: return .systemPurple
        case .mailInbox: return .systemBlue
        case .mailNotify: return .systemPink
        case .mailReading: return .systemGreen
        case .mailWriting: return .systemPurple
        case .snippets: return .systemYellow
        case .mailCalendar: return .systemRed
        case .mailAgents: return .systemBlue
        case .mailBlocked: return .systemGray
        default: return nil
        }
    }

    /// The one switch a feature's page is about, set across from the back
    /// and forward in the toolbar, where a feature is turned on and off:
    /// what it says to VoiceOver, and the setting it flips.
    @MainActor
    var master: (title: String, key: ReferenceWritableKeyPath<Preferences, Bool>)? {
        switch self {
        case .spaces: return ("Spaces", \.usesSpaces)
        case .liveFolders: return ("Live Folders", \.usesLiveFolders)
        case .mail: return nil
        case .agents: return ("Let agents use Yab", \.bench)
        case .agentMemory: return ("Agents remember what they learn about you", \.agentsRemember)
        default: return nil
        }
    }

    /// What a feature is for, in one line under its name at the top of
    /// its page. Nil where the page opens straight onto its rows.
    var blurb: String? {
        switch self {
        case .spaces: return "Separate tabs, pinned sites and sign-ins for work or personal browsing."
        case .boosts: return "Changes kept for sites, made by you, an agent or the Store."
        case .liveFolders: return "Automatically updated folders from your sites and feeds."
        case .sync: return "Sync spaces, tabs, bookmarks and settings across devices with end-to-end encryption."
        case .mail: return "Manage your mail in Yab. Mail is stored on this Mac."
        case .ai: return "Use your \(AgentSetupModel.list(AgentPlan.all.map(\.name))) subscriptions in Yab."
        case .models: return "Choose default models and connect subscriptions or API keys."
        case .agents: return "Manage agent permissions and browser access."
        case .assistants: return "Connect cloud assistants to your signed-in browser with your approval."
        case .siteButtons: return "Run agent actions from buttons on supported sites."
        case .whileYouBrowse: return "Rename tabs and downloads, organize folders and preview links with AI."
        case .commands: return "Improve, translate and ask about selected text."
        case .search: return "Customize search results and suggestions."
        case .smallWindow: return "Open links from other apps in a small window."
        case .reading: return "Read articles without distractions. Customize fonts, colors and spacing."
        case .passwords: return "Save and fill passwords with Yab or a connected password manager."
        case .autofill: return "Fill forms with saved profile details, cards and addresses."
        case .bringIn: return "Import browser data from Dia, Chrome, Arc, Brave, Edge, Zen or Firefox. Stored on this Mac."
        case .history: return "Find visited pages by title, address or page content."
        case .agentRoutines: return "Schedule recurring tasks and watch for replies. Requires Yab to be open."
        case .agentMemory: return "Review, edit or delete agent memory stored on this Mac."
        case .developers: return "Configure Developer Mode, the command line and agent tools."
        case .experimental: return "Try features that are still in development."
        case .agentSkills: return "Manage site instructions and actions available to agents."
        case .mailInbox: return "Choose which mail appears in your inbox and splits."
        case .mailNotify: return "Configure new mail alerts and unread counts."
        case .mailReading: return "Customize mail sorting, summaries and display."
        case .mailWriting: return "Configure draft replies, Undo send, read statuses and signatures."
        case .snippets: return "Insert saved text by typing ; and a snippet name."
        case .mailCalendar: return "Share available meeting times from your calendar."
        case .mailAgents: return "Manage agent access to your mail."
        case .mailBlocked: return "Send new mail from blocked senders to Trash on this Mac."
        case .credits: return "Open-source licenses and acknowledgments."
        case .inviteFriends: return "Invite friends to Yab and unlock exclusive app icons together."
        default: return nil
        }
    }

    private var keywords: String {
        switch self {
        case .experimental:
            return "experimental experiment labs beta mail email gmail enable disable"
        case .developers:
            return "developer developers dev mode localhost server port cli command line terminal path yab mcp skill claude code codex cursor zed windsurf inspector devtools measure rulers"
        case .mail:
            return "mail email gmail inbox google connect account sync reply draft archive snooze"
        case .general:
            return "default browser links other apps mail slack warn quit quitting confirm close import bring downloads save folder location ask where file files update updates version new release restart"
        case .search:
            return "field launcher command bar return fallback under words ask task now before you type matches search engine google duckduckgo bing ecosia startpage kagi brave qwant custom tab space site sites keyword alias keyboard shortcut youtube github wikipedia chatgpt opensearch suggestions scope quick action new document meeting shortcut"
        case .appearance:
            return "theme light dark system look style app icon dock layout address bar url toolbar top bar bookmarks bar sidebar vertical tabs tab icons letter favicon window backdrop background site match follow edge card color colour grain noise texture paper film wallpaper tint field dot lightness arc chrome"
        case .websites:
            return "websites pages sites page size zoom scale larger smaller aa fonts font size typeface serif sans fixed minimum dark pages dark reader night invert reading mode reader article"
        case .tabs:
            return "tabs sleep suspend memory close tidy archive old group search folder research"
        case .spaces:
            return "spaces profiles workspaces sets of tabs work personal arc switch control number sign ins cookies emoji color order reorder links other apps air traffic control flight control route routes always open site"
        case .liveFolders:
            return "live folders smart tabs automatic update github pull requests issues linear notion google drive figma youtube subscriptions feed enable disable"
        case .boosts:
            return "boosts boost userscripts userscript user.js tampermonkey greasemonkey greasy fork scripts styles site changes customize site store plugins stylesheet css claude agent change make look"
        case .engine:
            return "engine chromium webkit chrome safari blink opens in open in auto default memory sites rules protected video drm netflix apple pay"
        case .extensions:
            return "chrome web store add install unpacked folder manifest options reload remove new tab addons plugins"
        case .ai:
            return "ai artificial intelligence claude chatgpt openai anthropic codex models commands agents"
        case .models:
            return "models model plan plans subscription claude opus sonnet haiku fable gpt chatgpt codex effort reasoning default apple on device"
        case .agents:
            return "agents agent ai claude code codex mcp skill skills cli command terminal yab script bench socket automation"
        case .assistants:
            return "assistants cloud dots muse grok bot connect phone iphone approval code oauth"
        case .whileYouBrowse:
            return "while you browse tidy tab titles short names rename folder names folders downloads files rename arc max apple intelligence instant links link previews shift return hover summary"
        case .siteButtons:
            return "buttons on sites button do it with claude reply slack gmail github linear calendar amazon x twitter hide never offer"
        case .commands:
            return "commands ai improve writing rewrite grammar shorter longer translate selected text selection"
        case .reading:
            return "reading mode reader read article book themes theme original quiet paper bold calm focus light dark match mac text size font bold spacing line character word margins justify wide page custom colors sepia aa"
        case .smallWindow:
            return "small window little arc links other apps mail slack messages quick look peek hotkey shortcut option command n click open in yab"
        case .passwords:
            return "passwords keychain touch id save offer fill sign in login sign-in passkeys never accounts password manager 1password bitwarden nordpass proton pass dashlane lastpass apple unlock connect"
        case .autofill:
            return "autofill credit card cards payment addresses shipping billing profile you forms whole form fill draft answers claude contact card import bring"
        case .sync:
            return "sync icloud devices another mac iphone account recovery key code join encrypted end to end cloud backup extensions plugins"
        case .privacy:
            return "ad block ads blocker trackers tracking shield site camera microphone permissions history clear cookies sign out cache data website"
        case .shortcuts:
            return "shortcuts keys keyboard commands hotkeys remap rebind change record " + Shortcut.items.map(\.does).joined(separator: " ")
        case .about:
            return "version update updates check relaunch feedback bug report crash welcome intro onboarding daily activity privacy"
        case .bringIn:
            return "import bring move switch from another browser chrome arc dia brave edge tabs passwords extensions profile"
        case .history:
            return "history visited pages remember text clear forget"
        case .agentRoutines:
            return "routines routine schedule every daily weekdays weekly monthly yearly month year recurring watch reply replies"
        case .agentMemory:
            return "memory remember notes forget about me you people companies sites projects concepts days markdown get to know"
        case .agentSkills:
            return "skills skill sites site actions command j markdown new duplicate built in yours"
        case .appIcon:
            return "app icon dock default dev flat watercolor glass opal smoked chrome amber red enamel"
        case .inviteFriends:
            return "invite friend friends share gift send link referral icons unlock wax seal bracelet ticket yearbook best friend charm"
        case .bestFriend:
            return "best friend bff charm half halves color dock together presence"
        case .credits:
            return "credits thanks acknowledgements licenses open source search office commun arc raycast inspiration"
        case .mailInbox:
            return "mail inbox needs you sort how far back ads promos cold pitches splits vip team receipts"
        case .mailNotify:
            return "mail notifications notify banner alert new mail badge dock count"
        case .mailReading:
            return "mail reading sort sum up apple intelligence summaries tracking pixels animations"
        case .mailWriting:
            return "mail writing replies ahead undo send read statuses receipts signature signatures"
        case .snippets:
            return "snippets snippet templates canned replies text expansion replacement abbreviations semicolon paste hotkey"
        case .mailCalendar:
            return "mail calendar free slots working hours booking link calendly cal.com"
        case .mailAgents:
            return "mail agents claude codex tasks drafts search memory people"
        case .mailBlocked:
            return "mail blocked block sender unblock trash"
        }
    }

    /// How well the address field's words name this page, by the starts of
    /// words, "dark" finds Appearance there, but "a" finds nothing.
    ///
    /// A word for settings among others says which kind of place is meant
    /// and is left out of the match: "passwords settings" is this page,
    /// where "passwords" alone is the passwords themselves. Alone it names
    /// Settings, not one of its pages.
    func score(_ query: String) -> Double? {
        let query = Self.fieldQuery(query)
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
        let page = fieldScore(query)
        guard let row = fieldItem(query) else { return page }
        let score = SettingsMatch.score(query, title: row.title, words: row.words) ?? 0
        // An indexed row is a more precise destination than its page's aliases.
        return max(page ?? 0, score + 2)
    }

    /// General's app hotkey stays a setting, not a command that switches apps.
    func fieldItem(_ query: String) -> SettingsItem? {
        guard self == .general else { return nil }
        let item = SettingsItem.showYab
        return SettingsMatch.score(Self.fieldQuery(query), title: item.title, words: item.words) == nil ? nil : item
    }

    private static func fieldQuery(_ query: String) -> String {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        let rest = tokens.filter { token in
            token.count < 3 || !Self.called.contains { $0.hasPrefix(token) }
        }
        return tokens.count > 1 && !rest.isEmpty && rest.count < tokens.count ? rest.joined(separator: " ") : query
    }

    private func fieldScore(_ query: String) -> Double? {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
        let prepared = Self.prepared[self]
        if let score = prepared?.words.score(query) { return score }
        // The same abbreviated names as Settings search, below exact matches.
        return prepared?.settings.score(query).map { min(1, $0) }
    }

    /// Each page's title and words split once: the field scores every page
    /// at every key (docs/main-thread-budget.md).
    private static let prepared: [SettingsPage: (words: Wording.Prepared, settings: SettingsMatch.Prepared)] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, (Wording.Prepared(title: $0.title, words: $0.keywords),
                                                             SettingsMatch.Prepared(title: $0.title, words: $0.keywords))) })

    private static let called = ["settings", "preferences", "prefs"]

    /// How well the sidebar's search names this page itself, by its title
    /// or anything on it, before its rows are asked.
    func found(_ query: String, bundle: Bundle = .main) -> Double? {
        SettingsMatch.score(query, title: SettingsWords.text(englishTitle, bundle: bundle), words: keywords + " " + englishTitle)
    }
}

/// Which page is showing, the way back to the ones before it, and the search.
@MainActor
final class SettingsModel: ObservableObject {
    let shortcutFilters = ShortcutFilter.Selection()
    let engineSearch = EngineSearch()
    @Published private(set) var page: SettingsPage
    @Published var search = ""
    /// The row a search has picked out on the page: brought into view and
    /// washed gray while it is picked, and for a moment after it is taken.
    @Published var spot: SettingsItem?
    private var letGo: DispatchWorkItem?
    /// Whether the window is the key one, only then do the browser's
    /// notices show up here as well as over the page.
    @Published var key = false
    /// One extension's own page, over Extensions: its id while it is open.
    @Published private(set) var opened: String?
    /// A space just made from Settings: its row in the list is washed for
    /// a moment, so the eye finds where it went.
    @Published var madeSpace: UUID?
    /// Whose extensions Extensions lists, by a space signed in with them,
    /// when picked there; nil for the window's space's (ExtensionSignIns).
    @Published var extensionsSpace: UUID?
    /// Whose boosts Boosts lists, by a space signed in with them, when
    /// picked there; nil for the window's space's (BoostsSignIn).
    @Published var boostsSpace: UUID?

    /// Where back and forward go: a page, or an extension's page on it.
    private struct Place: Equatable {
        let page: SettingsPage
        var opened: String? = nil
    }
    private var history: [Place]
    private var place = 0
    /// How far down each place in back and forward was left, by its index:
    /// a new page opens at its top, back and forward come back to where it was.
    private var scrolled: [Int: CGFloat] = [:]

    init() {
        page = .general
        history = [Place(page: .general)]
    }

    /// The page someone elsewhere asked for, taken once: the extensions
    /// menu's "Manage Extensions…" writes it before opening. Settings
    /// itself never writes it, so ⌘, comes back to General.
    static func asked() -> SettingsPage? {
        defer { Store.settings.removeObject(forKey: askedKey) }
        return Store.settings.string(forKey: askedKey).flatMap(SettingsPage.init)
    }

    /// Asks for a page the next time the window is shown. Everything outside
    /// Settings that wants a page goes through here or `Browser.openSettings`.
    static func ask(_ page: SettingsPage) {
        Store.settings.set(page.rawValue, forKey: askedKey)
    }

    private static let askedKey = "settings.page"

    /// A row (`SettingsItem.id`) to bring into view and wash, the next
    /// time the window is shown, as a search's Return does.
    static func ask(row id: String) {
        Store.settings.set(id, forKey: rowKey)
    }

    static func askedRow() -> SettingsItem? {
        defer { Store.settings.removeObject(forKey: rowKey) }
        return Store.settings.string(forKey: rowKey).flatMap { id in SettingsItem.all.first { $0.id == id } }
    }

    private static let rowKey = "settings.row"

    /// The window opening again: on one page, nothing behind or ahead of it.
    func start(at next: SettingsPage) {
        shortcutFilters.clear()
        engineSearch.words = ""
        let next: SettingsPage = next.available ? next : .experimental
        search = ""
        spot = nil
        history = [Place(page: next)]
        place = 0
        scrolled = [:]
        page = next
        opened = nil
    }

    var canGoBack: Bool { place > 0 }
    var canGoForward: Bool { place < history.count - 1 }

    /// `keepingSearch` follows the sidebar to its first match while the
    /// query is still being typed, rather than wiping it.
    func go(_ next: SettingsPage, keepingSearch: Bool = false) {
        let next: SettingsPage = next.available ? next : .experimental
        // A shortcut opened from Settings search, an extension, or the
        // browser must not be hidden by the table's previous filters.
        if next == .shortcuts { shortcutFilters.clear() }
        if next == .engine { engineSearch.words = "" }
        if !keepingSearch {
            if !search.isEmpty { search = "" }
            if spot != nil { spot = nil }
        }
        guard next != page || opened != nil else { return }
        push(Place(page: next))
    }

    /// An extension's own page, from its row in Extensions.
    func open(extension id: String) {
        search = ""
        spot = nil
        push(Place(page: .extensions, opened: id))
    }

    /// One boost's or userscript's own page, from its row in Boosts.
    func open(boost id: String) {
        search = ""
        spot = nil
        push(Place(page: .boosts, opened: id))
    }

    /// A space's own page, or a new one's, from the list in Spaces.
    func open(space id: String) {
        search = ""
        spot = nil
        push(Place(page: .spaces, opened: id))
    }

    /// One thing's own page on a list page: a memory note by its path,
    /// a skill by its name.
    func open(_ page: SettingsPage, item: String) {
        search = ""
        spot = nil
        push(Place(page: page, opened: item))
    }

    /// Back to the list of spaces, a space just made or deleted dropped
    /// out of back and forward.
    func leaveSpace(_ id: String) {
        leave(id, to: .spaces)
    }

    /// Back to a list page, a thing just forgotten or deleted dropped out
    /// of back and forward.
    func leave(_ id: String, to list: SettingsPage) {
        var kept: [Place] = []
        for place in history.prefix(place + 1) where !(place.page == list && place.opened == id) && kept.last != place { kept.append(place) }
        if kept.last != Place(page: list) { kept.append(Place(page: list)) }
        history = kept
        place = kept.count - 1
        scrolled = [:]
        page = list
        opened = nil
    }

    /// Adding is done: its steps drop out of back and forward, and the
    /// window goes to what was added, one extension's page, or the list.
    func leaveAdding(to id: String? = nil) {
        while place > 0, history[place].opened?.hasPrefix("+add") == true { place -= 1 }
        history = Array(history.prefix(place + 1))
        scrolled = [:]
        if history[place] != Place(page: .extensions) { history.append(Place(page: .extensions)) }
        place = history.count - 1
        page = .extensions
        opened = nil
        if let id { push(Place(page: .extensions, opened: id)) }
    }

    private func push(_ next: Place) {
        keepScroll()
        scrolled = scrolled.filter { $0.key <= place }
        history = Array(history.prefix(place + 1)) + [next]
        place = history.count - 1
        page = next.page
        opened = next.opened
    }

    /// A line of the sidebar picked while searching, by typing, the arrows
    /// or a click. The page follows it; the search stays.
    func pick(_ result: SettingsResult) {
        letGo?.cancel()
        go(result.page, keepingSearch: true)
        if case .item(let item) = result { spot = item } else { spot = nil }
    }

    /// Return: the search is done with. Its row stays washed for a moment
    /// so the eye lands on it, then the page is only the page again.
    func take(_ result: SettingsResult) {
        go(result.page)
        guard case .item(let item) = result else { return }
        spot = item
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.search.isEmpty, self.spot == item else { return }
            self.spot = nil
        }
        letGo = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func travel(_ step: Int) {
        let to = place + step
        guard history.indices.contains(to) else { return }
        keepScroll()
        let before = SettingsWindow.shared.pageScrollNow
        place = to
        page = history[to].page.available ? history[to].page : .experimental
        opened = history[to].opened
        search = ""
        spot = nil
        SettingsWindow.shared.scrollPage(to: scrolled[to] ?? 0, leaving: before)
    }

    private func keepScroll() {
        if let y = SettingsWindow.shared.pageScrolled { scrolled[place] = y }
    }
}

extension Browser {
    /// Settings, brought up on one page through `tuning`, the way ⌘, does.
    func openSettings(_ page: SettingsPage) {
        SettingsModel.ask(page)
        tuning = true
    }

    /// Settings, on the page that holds this row, the row washed.
    func openSettings(row id: String) {
        guard let item = SettingsItem.all.first(where: { $0.id == id }) else { return }
        SettingsModel.ask(row: id)
        openSettings(item.page)
    }
}

/// The window itself. One of it, made the first time it is asked for and kept
/// after that, so it opens again where it was, on General unless a page
/// is asked for.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindow()

    private(set) var window: NSWindow?

    /// The page's own scroll: the widest in the pane beside the sidebar.
    private var pageScroll: NSScrollView? {
        guard let pane = split?.splitViewItems.last?.viewController.view ?? window?.contentView else { return nil }
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               scroll.frame.width > (best?.frame.width ?? 0) { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(pane)
        return best
    }

    /// How far down the page is, under the toolbar.
    var pageScrolled: CGFloat? {
        guard let scroll = pageScroll else { return nil }
        return scroll.contentView.bounds.minY + scroll.contentInsets.top
    }

    /// ./bench scroll's "go" and "travel": a page opened, or back and
    /// forward taken, the way the sidebar and the toolbar arrows do it.
    func benchGo(_ page: SettingsPage) { model?.go(page) }
    func benchTravel(_ step: Int) { model?.travel(step) }

    /// Where scrollPage last put the page, while it is still putting it there.
    private var placed: CGFloat?

    /// Back or forward: the page put where it was left before it is ever
    /// drawn. The page just switched to is laid out here and now, so its
    /// first frame is already there, never its top and then a jump. Its
    /// rows can arrive a beat later, so again until it gets there, unless
    /// someone scrolls in between.
    func scrollPage(to y: CGFloat, leaving before: NSScrollView?) {
        placed = nil
        window?.contentView?.layoutSubtreeIfNeeded()
        if let scroll = pageScroll, scroll !== before {
            place(scroll, at: y)
        } else {
            // Not switched yet: the page is put there on its first pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.pageScroll else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.place(scroll, at: y)
            }
        }
        for delay in [0.05, 0.12, 0.25, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let placed = self.placed, let scroll = self.pageScroll, let now = self.pageScrolled else { return }
                if abs(now - placed) > 1 || abs(now - y) < 1 { self.placed = nil; return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.place(scroll, at: y)
            }
        }
    }

    /// The page's scroll before back or forward switches it.
    var pageScrollNow: NSScrollView? { pageScroll }

    private func place(_ scroll: NSScrollView, at y: CGFloat) {
        let clip = scroll.contentView
        let top = scroll.contentInsets.top
        let foot = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height + top + scroll.contentInsets.bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(y, foot) - top))
        scroll.reflectScrolledClipView(clip)
        placed = pageScrolled
    }

    /// Settings' own corner: what is done here is said here, and only that.
    /// The browser's notices stay in the browser's windows.
    let toaster = Toaster()
    private(set) var model: SettingsModel?
    private var split: NSSplitViewController?
    private var navigation: NSToolbarItemGroup?
    private var shortcutToolbar: ShortcutFilterToolbar?
    private var engineToolbar: EngineToolbar?
    private var extensionToolbar: ExtensionToolbar?
    private var extensionPickerMenu: NSMenu?
    private var extensionPickerObserver: NSObjectProtocol?
    private var extensionPickerItems: [[String: Any]] = []
    private var watchExtensions: AnyCancellable?
    private weak var watchedExtensions: ChromiumExtensions?
    private var watchExtensionList: AnyCancellable?
    private var master: NSSwitch?
    /// The page's name in the toolbar, beside back and forward, shown once
    /// its hero's own name has scrolled up under the toolbar.
    private var heading: NSTextField?
    /// The page the heading was last set for: a new page starts at its
    /// top, its hero in view, so the heading goes.
    private var headingPage: SettingsPage?
    private var watch: AnyCancellable?
    private var watchPrefs: AnyCancellable?
    private var watchAgents: AnyCancellable?
    private var watchMail: AnyCancellable?
    private weak var browser: Browser?
    /// Set while the window is on its way out, so the browser hearing that
    /// it closed doesn't try to close it a second time.
    private var closing = false

    /// One column wide by design: the widest thing in it
    /// is a title beside a track of answers, and below this the rows stop
    /// lining up. So the width is fixed, and only the height is the reader's.
    /// Tall enough for the whole sidebar, every page, About and Send
    /// Feedback, without its list scrolling under the search.
    private static let size = NSSize(width: 760, height: 540)
    private static let smallest = NSSize(width: 760, height: 440)

    /// The page showing, or General while the window has never opened.
    var page: SettingsPage { model?.page ?? .general }

    func show(for browser: Browser) {
        show(nil, for: browser)
    }

    func showCommands(for browser: Browser) {
        show(.commands, for: browser)
    }

    func showAgents(for browser: Browser) {
        show(.agents, for: browser)
    }

    /// Settings, open on one page, or on the one asked for elsewhere, or
    /// General. Already open, it stays where it is unless a page is asked.
    func show(_ page: SettingsPage?, for browser: Browser) {
        self.browser = browser
        // Extensions lists the window's sign-in's again.
        if model?.extensionsSpace != nil { model?.extensionsSpace = nil }
        if model?.boostsSpace != nil { model?.boostsSpace = nil }
        let asked = SettingsModel.asked()
        let wanted = page ?? asked
        let open = window.map { $0.isVisible || $0.isMiniaturized } ?? false
        if window == nil { make(browser) }
        if !open { model?.start(at: wanted ?? .general) } else if let wanted { model?.go(wanted) }
        if let row = SettingsModel.askedRow() { model?.take(.item(row)) }
        // Set only when it changes: each write is a publish, and the whole
        // page is drawn again for it.
        if model?.search.isEmpty == false { model?.search = "" }
        // General's Open links in Yab names the app links go to now; found
        // here, off the main thread, rather than while drawing.
        DefaultBrowser.shared.refresh()
        updateNavigation()
        guard let window else { return }
        if !open { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A card left up when Settings closed comes back over it, rather
        // than its veil holding every click with no card to answer.
        SettingsCards.shared.refresh()
    }

    func showNewSpace(for browser: Browser) {
        show(.spaces, for: browser)
        model?.open(space: SpacePlace.new)
        updateNavigation()
    }

    /// A space's own page, from its menu in the tray.
    func showSpace(_ id: UUID, for browser: Browser) {
        show(.spaces, for: browser)
        model?.open(space: id.uuidString)
        updateNavigation()
    }

    /// An extension's own page, from outside Settings: the corner's Show
    /// while iCloud Passwords waits on Apple (Extensions.press).
    func showExtension(_ id: String, for browser: Browser) {
        show(.extensions, for: browser)
        model?.open(extension: id)
        updateNavigation()
    }

    /// Shortcuts, at one extension's commands, its first row brought into
    /// view and washed as a search's find is, or at the first extension's
    /// when `id` has none: chrome://extensions/shortcuts (ChromePages).
    func showCommands(of id: String?, for browser: Browser) {
        browser.openSettings(.shortcuts)
        show(.shortcuts, for: browser)
        updateNavigation()
        guard #available(macOS 15.4, *) else { return }
        let groups = Extensions.here.commandGroups()
        guard let entry = (groups.first { $0.item.id == id } ?? groups.first)?.commands.first else { return }
        let item = SettingsItem(id: "key:ext." + entry.id, page: .shortcuts, title: entry.title)
        commandsShown = item.id
        // Once the page is laid out: a window only just made has nothing
        // yet to bring into view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.model?.take(.item(item)) }
    }

    /// The row showCommands last brought into view, for the bench.
    private(set) var commandsShown: String?

    /// Where Settings is, for the bench: shown or not, the page, the thing
    /// opened on it, the row washed, and how far down the page is.
    var benchWhere: [String: Any] {
        ["shown": window?.isVisible == true, "page": page.rawValue, "opened": model?.opened ?? "",
         "spot": model?.spot?.id ?? "", "commands": commandsShown ?? "", "scrolled": Double(pageScrolled ?? 0), "masterHidden": master?.isHidden ?? true]
    }

    func showLiveFolder(_ nest: Nest, for browser: Browser) {
        show(.liveFolders, for: browser)
        model?.open(.liveFolders, item: nest.id.uuidString)
        updateNavigation()
    }

    /// Routines, with one open in its editor (a new one for nil), from the
    /// field's place or anywhere else outside Settings.
    func showRoutine(_ routine: Routine?, for browser: Browser, fresh: Bool = false) {
        show(.agentRoutines, for: browser)
        RoutineEditing.shared.edit(routine, fresh: fresh)
    }

    func hide() {
        guard !closing, let window, window.isVisible else { return }
        window.close()
    }

    /// ⌘F: to the search at the top of the sidebar.
    func focusSearch() {
        guard let window, let field = Self.searchField(in: split?.splitViewItems.first?.viewController.view) else { return }
        window.makeFirstResponder(field)
    }

    /// ./bench ui search: the words typed into the search, and what the
    /// sidebar and the page then show.
    func bench(search text: String) -> [String: Any] {
        model?.search = text
        return benchState()
    }

    /// ./bench ui adding: the add flow's button, or its choices, "press",
    /// "store", "folder", "browser:NAME", "link:TEXT", "tick:ID", "untick:ID".
    func bench(adding command: String) -> [String: Any] {
        guard #available(macOS 15.4, *), let model, let browser else { return [:] }
        let adding = ExtensionAdding.shared
        let (verb, rest) = command.firstIndex(of: ":").map { (String(command[..<$0]), String(command[command.index(after: $0)...])) } ?? (command, "")
        switch verb {
        case "toolbar-add", "toolbar-import":
            guard Store.testing else { return [:] }
            let id = verb == "toolbar-add" ? ExtensionToolbar.addID : ExtensionToolbar.importID
            guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == id }), item.isEnabled,
                  let action = item.action else { return ["error": "extension toolbar item unavailable"] }
            NSApp.sendAction(action, to: item.target, from: item)
        case "picker" where Store.testing:
            guard let window, let content = window.contentView,
                  let rect = Bench.spots["extension-add-source"], !rect.isEmpty else {
                return ["error": "From menu has not laid out"]
            }
            if let observer = extensionPickerObserver { NotificationCenter.default.removeObserver(observer) }
            extensionPickerMenu = nil
            extensionPickerItems = []
            extensionPickerObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu else { return }
                    self?.extensionPickerMenu = menu
                    self?.extensionPickerItems = menu.items.map { ["title": $0.title, "enabled": $0.isEnabled, "image": $0.image != nil] }
                }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let at = NSPoint(x: rect.midX, y: content.bounds.height - rect.midY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
                guard let self, let window else { return }
                let close = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.extensionPickerMenu?.cancelTracking()
                        self.extensionPickerMenu = nil
                        if let observer = self.extensionPickerObserver { NotificationCenter.default.removeObserver(observer) }
                        self.extensionPickerObserver = nil
                    }
                }
                RunLoop.main.add(close, forMode: .common)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "press":
            switch ExtensionAdd.step(model.opened) ?? .arrival {
            case .arrival: adding.go(model, browser)
            case .pick: if case .browser(let name) = adding.way { adding.bring(from: name, model) }
            case .review: adding.add(model)
            }
        case "store": adding.chosen = .store
        case "folder": adding.chosen = .folder
        case "folder-at" where Store.testing:
            adding.chosen = .folder
            adding.choose(folder: URL(fileURLWithPath: rest), model: model)
        case "browser": adding.chosen = .browser(rest)
        case "link": adding.link = rest
        case "tick", "untick": adding.tick(rest, verb == "tick", flight: ExtensionAdd.benchFlight)
        case "cancel":
            adding.dropCandidate()
            model.travel(-1)
        case "keep": adding.given.remove(rest)
        case "give": adding.given.insert(rest)
        default: break
        }
        var state = benchState()
        state["opened"] = model.opened ?? ""
        state["picked"] = Array(adding.picked)
        state["phase"] = String(describing: adding.phase)
        state["nativeProfile"] = adding.chromium?.profile ?? ""
        state["pickerItems"] = extensionPickerItems
        state["toolbar"] = window?.toolbar?.items.filter { ExtensionToolbar.identifiers.contains($0.itemIdentifier) }.map {
            ["id": $0.itemIdentifier.rawValue, "title": $0.title, "native": $0.view == nil,
             "bordered": $0.isBordered, "menu": $0 is NSMenuToolbarItem, "enabled": $0.isEnabled] as [String: Any]
        } ?? []
        state["candidate"] = adding.candidate?.id ?? ""
        state["problem"] = adding.error ?? ""
        state["extras"] = (adding.candidate?.extras ?? []).map { "\($0.key) \(adding.given.contains($0.key) ? "given" : "asked later") \($0.words)" }
        state["fresh"] = adding.fresh.mapValues { $0.map { "\($0.id) \($0.name)" } }
        return state
    }

    /// ./bench ui extension: an extension's own page, as its row's click opens it.
    func bench(extension id: String) -> [String: Any] {
        model?.open(extension: id)
        return benchState()
    }

    /// ./bench ui space: a space's page by its place, Add Space's, or the list.
    func bench(space: String, browser: Browser) {
        guard let model else { return }
        switch space {
        case "list": model.go(.spaces)
        case "new": model.open(space: SpacePlace.new)
        default:
            if let at = Int(space), browser.spaces.indices.contains(at) { model.open(space: browser.spaces[at].id.uuidString) }
        }
    }

    /// ./bench ui syncPage: Settings › Sync, "home" or a page further in.
    func bench(sync place: String) -> [String: Any] {
        guard let model else { return [:] }
        if place == "home" { model.go(.sync) } else { model.open(.sync, item: place) }
        var state = benchState()
        state["opened"] = model.opened ?? ""
        return state
    }

    /// The Add a Device page's real actions, for an isolated sync probe.
    func bench(syncDevice command: String) -> [String: Any] {
        guard Store.testing, let model else { return [:] }
        let adding = SyncDeviceAdding.shared
        switch command {
        case "approve": adding.approve()
        case "confirm": adding.confirm()
        case "new": adding.start()
        case "cancel": model.leave(SyncPlace.add, to: .sync)
        default:
            if command.hasPrefix("code:") { adding.edit(String(command.dropFirst(5))) }
        }
        return ["opened": model.opened ?? "", "code": adding.code,
                "invite": adding.invite?.code ?? "", "phase": adding.invite.map { String(describing: $0.phase) } ?? "none",
                "busy": adding.busy, "finished": adding.finished, "trouble": adding.trouble ?? ""]
    }

    /// ./bench ui memory: Settings › Agents › Memory, "list", or a note's
    /// page by its path as the page lists it ("people/jane-doe.md").
    func bench(memory: String) -> [String: Any] {
        guard let model else { return [:] }
        MemoryShelf.shared.reload()
        if memory == "list" { model.go(.agentMemory) } else { model.open(.agentMemory, item: memory) }
        var state = benchState()
        state["opened"] = model.opened ?? ""
        state["notes"] = MemoryShelf.shared.notes.map(\.path)
        return state
    }

    /// ./bench ui skill: Settings › Agents › Skills, "list", "new:NAME"
    /// (New Skill… answered with NAME), or a skill's page by its name.
    func bench(skill: String) -> [String: Any] {
        guard let model else { return [:] }
        SkillShelf.shared.reload()
        if skill == "list" {
            model.go(.agentSkills)
        } else if skill.hasPrefix("new:") {
            if let made = SkillShelf.shared.create(String(skill.dropFirst(4))) { model.open(.agentSkills, item: made) }
        } else {
            model.open(.agentSkills, item: skill.lowercased())
        }
        var state = benchState()
        state["opened"] = model.opened ?? ""
        state["skills"] = SkillShelf.shared.skills.map { ($0.own ? "yours " : "built in ") + $0.name }
        return state
    }

    /// ./bench keys alias: a page, from wherever Settings is.
    func bench(page: SettingsPage) {
        model?.go(page)
    }

    /// ./bench keys record: Shortcuts, with a row brought into view as a
    /// search for it would bring it.
    func bench(key action: Shortcut.Action) {
        guard let model, let item = Keymap.shared.index.first(where: { $0.id == "key:" + action.rawValue }) else { return }
        model.take(.item(item))
    }

    /// ./bench ui pick: the arrows and Return, as the search field takes them.
    func bench(pick key: String) -> [String: Any] {
        guard let model else { return [:] }
        let found = SettingsResult.search(model.search)
        let chosen: SettingsResult = model.spot.map { .item($0) } ?? .page(model.page)
        switch key {
        case "return": if found.rows.contains(chosen) { model.take(chosen) }
        default:
            let step = key == "up" ? -1 : 1
            let at = found.rows.firstIndex(of: chosen) ?? -1
            if !found.rows.isEmpty { model.pick(found.rows[min(max(at + step, 0), found.rows.count - 1)]) }
        }
        return benchState()
    }

    private func benchState() -> [String: Any] {
        guard let model else { return [:] }
        return [
            "rows": SettingsResult.search(model.search).rows.map { row -> String in
                switch row {
                case .page(let page): return page.title
                case .item(let item): return "  " + item.title
                }
            },
            "page": model.page.title,
            "spot": model.spot?.title ?? "",
            "anchors": SettingsAnchorsShown.shown,
            "window": window?.windowNumber ?? 0,
        ]
    }

    // MARK: - the window

    private func make(_ browser: Browser) {
        let model = SettingsModel()
        self.model = model

        let sidebar = NSHostingController(rootView: SettingsSidebar(model: model))
        let detail = NSHostingController(rootView: SettingsDetail(browser: browser, prefs: browser.prefs, model: model))
        sidebar.sizingOptions = []
        detail.sizingOptions = []

        let split = NSSplitViewController()
        split.view.frame = NSRect(origin: .zero, size: Self.size)
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 170
        side.maximumThickness = 210
        side.canCollapse = false
        split.addSplitViewItem(side)
        let page = NSSplitViewItem(viewController: detail)
        page.minimumThickness = 430
        split.addSplitViewItem(page)
        self.split = split
        // A card or a question dims the whole window, the sidebar too, and
        // holds it still; the card itself is in a window over it.
        let asking = SettingsQuestionHost(rootView: AnyView(SettingsVeil().ignoresSafeArea()))
        asking.sizingOptions = []
        asking.frame = split.view.bounds
        asking.autoresizingMask = [.width, .height]
        split.view.addSubview(asking, positioned: .above, relativeTo: nil)

        let window = SettingsFrame(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.title = model.page.title
        // The sidebar's selection says where you are; the title is kept for
        // the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.opensOnActiveSpace()
        shortcutToolbar = ShortcutFilterToolbar(selection: model.shortcutFilters, window: window)
        engineToolbar = EngineToolbar(search: model.engineSearch, window: window)
        extensionToolbar = ExtensionToolbar(add: { [weak self] in
            if #available(macOS 15.4, *) { self?.model?.open(extension: ExtensionAdd.Step.arrival.rawValue) }
        }, bring: { [weak self] in
            guard let browser = self?.browser else { return }
            if #available(macOS 15.4, *) { ChromiumExtensions.of(browser).importWebKitList(browser) }
        })
        if #available(macOS 15.4, *) {
            watchExtensionList = Extensions.listsChanged.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateNavigation() }
            }
        }
        let toolbar = NSToolbar(identifier: "SearchSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // Handing over a view controller sizes the window to its first frame;
        // the size wanted goes on after it and the toolbar.
        window.contentMinSize = Self.smallest
        window.contentMaxSize = NSSize(width: Self.size.width, height: .greatestFiniteMagnitude)
        window.setContentSize(Self.size)
        // A name of its own since the sidebar grew: a height kept under the
        // old one, 500, cut About off at the foot.
        window.setFrameAutosaveName(Store.world.map { "settings.2 (\($0))" } ?? "settings.2")
        let rooms = NSScreen.screens.map(\.visibleFrame)
        if !rooms.isEmpty {
            window.setFrame(WindowPlacing.fitting(window.frame, screens: rooms, fallback: NSScreen.main?.visibleFrame ?? rooms[0]), display: false)
        }
        split.splitView.setPosition(180, ofDividerAt: 0)
        self.window = window
        SettingsCards.shared.attach(to: window, browser: browser)

        watch = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateNavigation() }
        }
        watchPrefs = browser.prefs.relay.any.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateNavigation() }
        }
        watchAgents = AgentSetupModel.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateNavigation() }
        }
        watchMail = MailCenter.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateNavigation() }
        }
    }

    private func updateNavigation() {
        guard let model else { return }
        if !model.page.available { model.go(.experimental) }
        window?.title = model.page.title
        if headingPage != model.page {
            headingPage = model.page
            showHeading(nil)
        }
        // The pages with glass of their own in the toolbar have no hero.
        let nativeExtensions = model.page == .extensions && PageEngineFactory.chromiumEnabled
        let ownGlass = model.page == .shortcuts || model.page == .engine || nativeExtensions
        // A previously scrolled page's invisible heading must not keep
        // toolbar width that belongs to the page's search.
        if nativeExtensions {
            heading?.stringValue = SettingsWords.text(model.page.title)
            heading?.alphaValue = 1
            heading?.setAccessibilityElement(true)
        } else if ownGlass { heading?.stringValue = "" }
        if let toolbar = window?.toolbar {
            // Hiding the switch alone leaves its toolbar item's width behind.
            if ownGlass {
                if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == masterID }) {
                    toolbar.removeItem(at: index)
                }
            } else if !toolbar.items.contains(where: { $0.itemIdentifier == masterID }) {
                toolbar.insertItem(withItemIdentifier: masterID, at: toolbar.items.count)
            }
            shortcutToolbar?.attach(to: toolbar, visible: model.page == .shortcuts)
            engineToolbar?.attach(to: toolbar, visible: model.page == .engine)
            if let browser, #available(macOS 15.4, *) {
                let native = ChromiumExtensions.of(browser)
                if watchedExtensions !== native {
                    watchedExtensions = native
                    watchExtensions = native.objectWillChange.sink { [weak self] _ in
                        DispatchQueue.main.async { self?.updateNavigation() }
                    }
                }
                let list = model.page == .extensions && model.opened == nil && PageEngineFactory.chromiumEnabled
                extensionToolbar?.attach(to: toolbar, visible: list,
                    canImport: list && native.canImportWebKitList(browser), busy: native.busy)
            }
        }
        navigation?.subitems.first?.isEnabled = model.canGoBack
        navigation?.subitems.last?.isEnabled = model.canGoForward
        if let master {
            let about = model.page.master
            // Agents' switch only once there is one to pause.
            // Mail's, once there is mail to turn off.
            master.isHidden = (model.page == .spaces && model.opened == SpacePlace.new) || about == nil || (model.page.top == .ai && AgentSetupModel.shared.arriving)
                || (model.page == .mail && MailArrival.shows)
            if let about, let prefs = browser?.prefs {
                master.state = prefs[keyPath: about.key] ? .on : .off
                master.setAccessibilityLabel(SettingsWords.text(about.title))
                master.keyTip(SettingsWords.text(about.title))
            }
        }
    }

    /// Where a hero's name ends, down from the window's top: under the
    /// toolbar's foot, the name is gone from view and the toolbar says it.
    func heroTitle(_ title: String, bottom: CGFloat) {
        guard let window, let content = window.contentView else { return }
        let foot = content.bounds.height - window.contentLayoutRect.maxY
        showHeading(bottom < foot ? title : nil)
    }

    private func showHeading(_ title: String?) {
        guard let heading else { return }
        let shown = title != nil
        if let title, heading.stringValue != title { heading.stringValue = title }
        guard (heading.alphaValue > 0.5) != shown else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            heading.animator().alphaValue = shown ? 1 : 0
        }
        heading.setAccessibilityElement(shown)
    }

    @objc private func flipMaster(_ sender: NSSwitch) {
        guard let key = model?.page.master?.key, let prefs = browser?.prefs else { return }
        prefs[keyPath: key] = sender.state == .on
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        model?.travel(sender.selectedIndex == 0 ? -1 : 1)
    }

    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = searchField(in: child) { return found }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        SyncDeviceAdding.shared.stop()
        SettingsCards.shared.parentClosed()
        closing = true
        browser?.tuning = false
        closing = false
        // The page behind gets the keyboard back.
        Links.window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { model?.key = true }
    func windowDidResignKey(_ notification: Notification) { model?.key = false }
    /// The card's window keeps to Settings' middle and its screen.
    func windowDidMove(_ notification: Notification) { SettingsCards.shared.place() }
    func windowDidResize(_ notification: Notification) { SettingsCards.shared.place() }
    func windowDidChangeScreen(_ notification: Notification) { SettingsCards.shared.place() }
    func windowDidDeminiaturize(_ notification: Notification) { SettingsCards.shared.refresh() }

    /// Native controls exercised by the isolated Shortcuts probe.
    func beginToolbarSearch() -> NSSearchField? {
        guard Store.testing else { return nil }
        return model?.page == .engine ? engineToolbar?.search.begin() : shortcutToolbar?.beginSearch()
    }

    var shortcutFilterButton: NSButton? {
        guard Store.testing else { return nil }
        return shortcutToolbar?.menuButton(in: window?.contentView?.superview)
    }

    var engineAddButton: NSButton? {
        guard Store.testing else { return nil }
        return engineToolbar?.addButton(in: window?.contentView?.superview)
    }

    var toolbarState: [String: Any] {
        guard Store.testing else { return [:] }
        return (model?.page == .engine ? engineToolbar?.state : shortcutToolbar?.state) ?? [:]
    }

    // MARK: - NSToolbarDelegate

    private let separatorID = NSToolbarItem.Identifier("SearchSettingsSeparator")
    private let navigationID = NSToolbarItem.Identifier("SearchSettingsNavigation")
    private let masterID = NSToolbarItem.Identifier("SearchSettingsMaster")
    private let headingID = NSToolbarItem.Identifier("SearchSettingsHeading")
    /// What the switch keeps clear on its right, on top of the toolbar's own
    /// 8, so it ends where the page's groups do.
    private static let masterInset: CGFloat = 12

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [separatorID, navigationID, headingID, .flexibleSpace, masterID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + ShortcutFilterToolbar.identifiers + EngineToolbar.identifiers + ExtensionToolbar.identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if id == separatorID, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
        if let item = shortcutToolbar?.item(for: id) ?? engineToolbar?.item(for: id) ?? extensionToolbar?.item(for: id) { return item }
        if id == headingID {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.alphaValue = 0
            label.setAccessibilityElement(false)
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = label
            item.isBordered = false
            heading = label
            return item
        }
        if id == masterID {
            // Bare, not in a toolbar button's glass: a switch is its own control.
            let toggle = NSSwitch()
            // The rows' own size, so it sits in the toolbar rather than over it.
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(flipMaster(_:))
            toggle.isHidden = true
            // Its right edge on the page's own: the groups under it stand
            // 20 in from the window's edge, and the toolbar sets its last
            // item 8 in. The rest is kept clear beside the switch.
            let well = NSView()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: well.leadingAnchor),
                toggle.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -Self.masterInset),
                toggle.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                well.heightAnchor.constraint(equalTo: toggle.heightAnchor),
            ])
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = well
            item.isBordered = false
            master = toggle
            return item
        }
        guard id == navigationID,
              let back = Glyphs.image("chevron.left", size: 13),
              let forward = Glyphs.image("chevron.right", size: 13)
        else { return nil }
        back.accessibilityDescription = "Back"
        forward.accessibilityDescription = "Forward"
        let item = NSToolbarItemGroup(
            itemIdentifier: id,
            images: [back, forward],
            selectionMode: .momentary,
            labels: ["Back", "Forward"],
            target: self,
            action: #selector(navigate(_:))
        )
        item.isNavigational = true
        item.controlRepresentation = .expanded
        item.autovalidates = false
        navigation = item
        return item
    }
}

/// The settings window's keys: ⌘W and escape close it rather than reaching
/// the menu's Close Tab, ⌘F goes to the search, ⌘[ and ⌘] walk the pages.
/// Over the whole Settings window, there to be pressed only while a card
/// or a question of its own is up.
final class SettingsQuestionHost: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        SettingsCards.shared.up ? super.hitTest(point) : nil
    }
}

final class SettingsFrame: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Keymap.shared.matches(event, .closeTab) {
            performClose(nil)
            return true
        }
        if Keymap.shared.matches(event, .find) {
            SettingsWindow.shared.focusSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape in a search with something in it clears it, the field keeps
    /// that one, and otherwise closes the window.
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

// MARK: - the sidebar

struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(MailExperiment.key, store: Store.settings) private var mailExperiment = false

    private static let searchPadding: CGFloat = 8
    /// How far the pages have gone under the search, for their fade.
    @State private var ends = ColumnEnds()

    var body: some View {
        let rows = SettingsResult.search(model.search).rows.filter { mailExperiment || $0.page != .mail }
        GeometryReader { geometry in
            // The pages run the whole height, under the titlebar and the
            // search: they start below the search and go
            // under it as they scroll, dimmed and blurred there as the
            // browser's column rows go under its pins (ColumnEnds), so
            // they are still seen going. Drawn here rather than left to
            // the split view's accessory, whose edge macOS 27 rules with
            // a hard line.
            // The list ignores the top safe area; the search stays below
            // it. Derive their distance in this layout pass. Keeping two
            // measured coordinates in @State could mix different opening
            // layouts and leave a large inset until the window was resized.
            let under = geometry.safeAreaInsets.top + Self.searchPadding + GlassSearch.height
            ZStack(alignment: .top) {
                PageList(
                    rows: rows,
                    grouped: model.search.isEmpty,
                    top: under + 14,
                    ends: ends,
                    selection: Binding(
                        get: { model.sidebarChosen },
                        set: { model.pick($0) }
                    )
                )
                .mask { ColumnFade(ends: ends, top: under, foot: false) }
                .overlay { ColumnBlur(ends: ends, top: under, foot: false, grain: 0) }
                .overlay {
                    if rows.isEmpty {
                        Text("No results")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                // The words wait for the last page to fold away, and go at
                // once when one comes back.
                .animation(.easeOut(duration: 0.2).delay(rows.isEmpty ? 0.18 : 0), value: rows.isEmpty)
                .ignoresSafeArea(.container, edges: .vertical)

                GlassSearch(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, Self.searchPadding)
            }
        }
        .font(.system(size: 13))
        .onChange(of: model.search) { _, search in
            // Each key picks out what now answers best, as a launcher does;
            // the page on the right follows it.
            guard !search.isEmpty, let best = SettingsResult.search(search).best else { return }
            model.pick(best)
        }
    }
}

/// The search at the top of the sidebar: typing narrows the pages, the
/// arrows walk what answered and Return takes it.
private struct SidebarSearch: View {
    @ObservedObject var model: SettingsModel
    /// No bezel: the glass around it is the field.
    var bare = false

    var body: some View {
        SearchField(
            text: Binding(
                get: { model.search },
                set: { text in
                    model.search = text
                    if text.isEmpty { model.spot = nil }
                }
            ),
            submit: {
                let chosen = model.sidebarChosen
                if SettingsResult.search(model.search).rows.contains(chosen) { model.take(chosen) }
            },
            move: { step in
                let rows = SettingsResult.search(model.search).rows
                guard !rows.isEmpty else { return }
                let at = rows.firstIndex(of: model.sidebarChosen) ?? (step > 0 ? -1 : rows.count)
                model.pick(rows[min(max(at + step, 0), rows.count - 1)])
            },
            bare: bare
        )
        .frame(height: 22)
    }
}

/// The search as it floats over the list: a capsule of glass the pages
/// pass under, holding the mark, a bare field and its clear button. Not the
/// system's search field unbezeled: that one lays its text over its own
/// mark while it is being typed in.
private struct GlassSearch: View {
    static let height: CGFloat = 32

    @ObservedObject var model: SettingsModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 6) {
            Symbol("magnifyingglass", size: 12)
                .foregroundStyle(.secondary)
            SidebarSearch(model: model, bare: true)
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                    model.spot = nil
                } label: {
                    Symbol("xmark.circle.fill", size: 12)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SettingsWords.text("Clear"))
            }
        }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .background {
                if #available(macOS 26.0, *), !reduceTransparency {
                    Color.clear.glassEffect(.regular, in: .capsule)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
    }
}

extension SettingsModel {
    /// The line lit in the sidebar: a row a search picked out, or the page.
    var sidebarChosen: SettingsResult {
        if !search.isEmpty, let spot { return .item(spot) }
        return .page(search.isEmpty ? page.top : page)
    }
}

/// The system's search field, which a SwiftUI TextField can only imitate.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var submit: () -> Void
    /// The arrows walk the results without leaving the field.
    var move: (Int) -> Void
    var bare = false

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
            case #selector(NSResponder.moveDown(_:)):
                parent.move(1)
            case #selector(NSResponder.moveUp(_:)):
                parent.move(-1)
            // The system's search field clears itself on Escape; a bare one
            // is taught to, and closes the window once empty, as it does.
            case #selector(NSResponder.cancelOperation(_:)) where !parent.text.isEmpty && !(control is NSSearchField):
                (control as? NSTextField)?.stringValue = ""
                parent.text = ""
            default:
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = bare ? NSTextField() : NSSearchField()
        field.placeholderString = SettingsWords.text("Search")
        field.controlSize = .regular
        field.delegate = context.coordinator
        (field as? NSSearchField)?.sendsSearchStringImmediately = true
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if bare {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}

/// The pages as a real source list, keyboard, VoiceOver and the sidebar
/// icon size from System Settings all come with it. Only the selection is
/// painted by hand: gray, like the rest of yab, not the accent color.
/// While searching, the rows that answered hang under their page, set in
/// to where its name begins.
private struct PageList: NSViewRepresentable {
    let rows: [SettingsResult]
    /// The whole list, not a search's answers: the features and About each
    /// start a little way below the group before them.
    var grouped = false
    /// How far down the first row starts: under the titlebar and the
    /// search, which the list scrolls beneath.
    var top: CGFloat = 0
    /// Told how far the rows have gone under the search (ColumnScrolled's
    /// share, in tenths).
    var ends: ColumnEnds? = nil
    @Binding var selection: SettingsResult

    /// How far below the row before it a group starts: a little way, with
    /// no name over it, the gap alone says where one ends.
    static let gap: CGFloat = 14

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: PageList
        var updating = false
        /// Whether the list has been put at its top once it had a window.
        var placed = false
        /// The watch on scrolling, which moves rows out from under the pointer.
        var scrolled: Any?

        /// Every row's wash set by where the pointer is now.
        func repoint(_ table: NSTableView) {
            table.enumerateAvailableRowViews { view, _ in (view as? PageRowView)?.repoint() }
        }
        init(_ parent: PageList) { self.parent = parent }

        /// How far the rows have gone under the search, a fall's worth at
        /// most and in tenths, as ColumnScrolled tells the column's.
        @MainActor func measure(_ scroll: NSScrollView) {
            guard let ends = parent.ends else { return }
            let above = scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top
            let share = (min(1, max(0, above / ColumnEnds.fall)) * 10).rounded() / 10
            if ends.depth.above != share { ends.depth.above = share }
        }

        /// Two rows more than the pages: Send Feedback, last, where Chrome
        /// and Arc keep it, and the community's chat on X under it, scrolling
        /// with the rest rather than held at the foot. A search folds them
        /// away with the pages it doesn't name.
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count + 2 }

        /// Send Feedback or Community: a row that acts, not a page.
        func isFeedback(_ row: Int) -> Bool { row >= parent.rows.count }
        func isCommunity(_ row: Int) -> Bool { row == parent.rows.count + 1 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = PageRowView()
            view.lead = lead(row)
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if isFeedback(row), !parent.grouped { return 0.01 }
            return 28 + lead(row)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isFeedback(row) }

        /// The room above a row that begins a group of the sidebar.
        func lead(_ row: Int) -> CGFloat {
            if isFeedback(row) { return parent.grouped && !isCommunity(row) ? PageList.gap : 0 }
            guard parent.grouped, row > 0, parent.rows.indices.contains(row),
                  case .page(let page) = parent.rows[row],
                  case .page(let before) = parent.rows[row - 1],
                  page.group != before.group
            else { return 0 }
            return PageList.gap
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = PageCell()
            cell.title.lineBreakMode = .byTruncatingTail
            guard !isFeedback(row) else {
                cell.isHidden = !parent.grouped
                cell.setSelected(false)
                if isCommunity(row) {
                    cell.setAccessibilityLabel(SettingsWords.text("Community"))
                    cell.title.keyTip("Yab's community chat on X", side: .pointer)
                    return fill(cell, well: PenTile(symbol: "community", tint: PenArt.color(.credits)), icon: nil, tint: .labelColor, title: "Community", row: row)
                }
                cell.setAccessibilityLabel(SettingsWords.text("Send Feedback"))
                return fill(cell, well: PenTile(symbol: "feedback", tint: nil), icon: nil, tint: .labelColor, title: "Send Feedback", row: row)
            }
            cell.setSelected(parent.selection == parent.rows[row])
            guard case .page(let page) = parent.rows[row] else {
                guard case .item(let item) = parent.rows[row] else { return cell }
                cell.title.stringValue = SettingsWords.text(item.title)
                cell.title.keyTip(SettingsWords.text(item.title), side: .pointer)
                cell.title.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(cell.title)
                NSLayoutConstraint.activate([
                    cell.title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 28),
                    cell.title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    cell.title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
                ])
                return cell
            }
            // Drawn with a pen on paper, a feature's over a swipe of its color.
            if PenArt.has(page) {
                return fill(cell, well: PenTile(page: page), icon: nil, tint: .labelColor, title: page.title, row: row)
            }
            // A page without a drawing: a feature's glyph in ink on the pen's
            // paper; a basic's in the gray well.
            if let tint = page.tint {
                return fill(cell, well: PenTile(symbol: page.icon, tint: tint), icon: nil, tint: .labelColor, title: page.title, row: row)
            }
            let well: NSView = IconWell()
            // 14 across in the 20-point well.
            // The system's symbol stands in for any page without one of ours.
            let icon = Glyphs.image(page.icon, side: page.tint == nil ? 14 : 13)
                ?? NSImage(systemSymbolName: page.icon, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            return fill(cell, well: well, icon: icon, tint: page.tint == nil ? .labelColor : .white, title: page.title, row: row)
        }

        /// A glyph in its well and a name beside it, the way every page and
        /// Send Feedback are laid.
        private func fill(_ cell: PageCell, well: NSView, icon: NSImage?, tint: NSColor, title: String, row: Int) -> PageCell {
            let image = NSImageView()
            image.image = icon
            image.contentTintColor = tint
            image.setAccessibilityElement(false)
            let label = cell.title
            label.stringValue = SettingsWords.text(title)
            for view in [well, image, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            let centers = [
                well.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ]
            cell.centers = centers
            cell.lead = lead(row)
            NSLayoutConstraint.activate(centers + [
                well.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                well.widthAnchor.constraint(equalToConstant: 20),
                well.heightAnchor.constraint(equalToConstant: 20),
                image.centerXAnchor.constraint(equalTo: well.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            refresh(table)
            guard !updating, parent.rows.indices.contains(table.selectedRow) else { return }
            parent.selection = parent.rows[table.selectedRow]
        }

        func refresh(_ table: NSTableView) {
            for row in 0 ..< table.numberOfRows {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageCell)?
                    .setSelected(table.isRowSelected(row))
            }
        }

        /// The gaps between the groups, opened as the search empties and
        /// closed as it starts, with the rows folding in between.
        func regroup(_ table: NSTableView) {
            for row in 0 ..< table.numberOfRows {
                (table.rowView(atRow: row, makeIfNecessary: false) as? PageRowView)?.lead = lead(row)
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageCell)?.lead = lead(row)
            }
            for row in parent.rows.count ..< table.numberOfRows {
                table.view(atColumn: 0, row: row, makeIfNecessary: false)?.isHidden = !parent.grouped
            }
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< table.numberOfRows))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PageTable()
        let coordinator = context.coordinator
        table.takes = { coordinator.isFeedback($0) && coordinator.parent.grouped }
        // On Settings itself: the press may be the one that brings this
        // window forward, while the browser's is still the key one.
        table.pressed = { [weak table] row in
            if coordinator.isCommunity(row) { MainActor.assumeIsolated { Links.openFromSettings(Links.community) } } else { Links.writeFeedback(on: table?.window) }
        }
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowSizeStyle = .default
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel(SettingsWords.text("Settings pages"))
        let scroll = PageScroll()
        // Put at its top as soon as it is in a window, not at SwiftUI's
        // next update: with nothing else changing, none came, and Settings
        // opened with General under the search, the list 140 pt down,
        // until the window was resized (SettingsSidebarLayoutTests, 540 pt).
        scroll.attached = { [weak scroll] in
            guard let scroll else { return }
            coordinator.parent.place(scroll, coordinator)
        }
        scroll.documentView = table
        // No scroller: with "Show scroll bars: Always" (a mouse plugged in)
        // a legacy bar stood in the sidebar; the rows still scroll.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The room under the search is the clip view's own: given to the
        // scroll view, the older design (macOS 15) also takes it off the
        // clip's frame, and the rows stand that much further down.
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.scrolled = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak table] _ in
            MainActor.assumeIsolated {
                if let table { coordinator.repoint(table) }
                coordinator.measure(scroll)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let old = coordinator.parent.rows
        let regrouped = coordinator.parent.grouped != grouped
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.parent = self
        if scroll.contentView.contentInsets.top != top {
            // The rows keep their place under the search as its room
            // changes, which it does as the window is first laid out.
            let moved = top - scroll.contentView.contentInsets.top
            let y = scroll.contentView.bounds.minY - moved
            scroll.contentView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(y, -top)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        place(scroll, coordinator)
        if old != rows || table.numberOfRows != rows.count + 2 {
            // A search narrows the list rather than redrawing it: the pages
            // that stop matching fold away and the rest close up, so the eye
            // keeps the row it was on.
            if table.window != nil, table.numberOfRows == old.count + 1,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { _ in
                    table.beginUpdates()
                    for change in rows.difference(from: old) {
                        switch change {
                        case .remove(let offset, _, _):
                            table.removeRows(at: IndexSet(integer: offset), withAnimation: [.effectFade, .slideUp])
                        case .insert(let offset, _, _):
                            table.insertRows(at: IndexSet(integer: offset), withAnimation: [.effectFade, .slideDown])
                        }
                    }
                    table.endUpdates()
                } completionHandler: {
                    // The fold ends with the table keeping the rows it
                    // had in view where they were, a row under the search:
                    // the top again, and the row picked in view.
                    MainActor.assumeIsolated {
                        guard coordinator.parent.rows == rows else { return }
                        toTop(scroll)
                        if table.selectedRow >= 0 { reveal(table.selectedRow, in: scroll) }
                        coordinator.repoint(table)
                    }
                }
            } else {
                table.reloadData()
            }
        }
        if regrouped { coordinator.regroup(table) }
        // A new list starts from its top, below the search floating over
        // it; the row picked is then brought into view from there.
        let refilled = old != rows
        if refilled { toTop(scroll) }
        if let row = rows.firstIndex(of: selection) {
            if table.selectedRow != row || refilled {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                reveal(row, in: scroll)
            }
        } else if table.selectedRow != -1 {
            table.deselectAll(nil)
        }
        coordinator.refresh(table)
        coordinator.repoint(table)
    }
}

extension PageList {
    /// The list at its top, the first time it has a window.
    func place(_ scroll: NSScrollView, _ coordinator: Coordinator) {
        guard !coordinator.placed, scroll.window != nil, scroll.contentView.contentInsets.top == top else { return }
        coordinator.placed = true
        toTop(scroll)
        // Again once the window has settled: macOS 26 lays the sidebar
        // out after this and leaves the rows where they fell.
        DispatchQueue.main.async {
            let parent = coordinator.parent
            if let row = parent.rows.firstIndex(of: parent.selection) { parent.toTop(scroll); parent.reveal(row, in: scroll) } else { parent.toTop(scroll) }
        }
    }

    /// The list from its first row, just under the search.
    func toTop(_ scroll: NSScrollView) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentView.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The row brought into the part of the list nothing floats over: the
    /// table's own scrollRowToVisible takes the room under the search for
    /// seen.
    func reveal(_ row: Int, in scroll: NSScrollView) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let rect = table.rect(ofRow: row)
        let clip = scroll.contentView.bounds
        let insets = scroll.contentView.contentInsets
        let y: CGFloat
        if rect.minY < clip.minY + insets.top {
            y = rect.minY - insets.top
        } else if rect.maxY > clip.maxY - insets.bottom {
            y = rect.maxY - clip.height + insets.bottom
        } else {
            return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(y, -insets.top)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// The pages' scroll view, saying when it is put in a window.
private final class PageScroll: NSScrollView {
    var attached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attached?() }
    }
}

/// The pages' table, which takes a press on Send Feedback itself, as a
/// button does, on the release over the row it went down on: a row that
/// can't be selected sends the table no action.
private final class PageTable: NSTableView {
    /// Whether a row is one the table answers itself.
    var takes: ((Int) -> Bool)?
    var pressed: ((Int) -> Void)?
    private var down: Int?

    private func row(of event: NSEvent) -> Int {
        row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(of: event)
        guard row >= 0, takes?(row) == true else { return super.mouseDown(with: event) }
        down = row
    }

    override func mouseUp(with event: NSEvent) {
        guard let row = down else { return super.mouseUp(with: event) }
        down = nil
        if self.row(of: event) == row { pressed?(row) }
    }
}

private final class PageCell: NSTableCellView {
    // Not the cell's own textField outlet: a source list restyles that one
    // behind the selection's back.
    let title = NSTextField(labelWithString: "")
    /// What centers a page's glyph and name, set down by the gap above a
    /// row that begins a group.
    var centers: [NSLayoutConstraint] = []
    var lead: CGFloat = 0 {
        didSet {
            for center in centers { center.constant = lead / 2 }
        }
    }

    func setSelected(_ selected: Bool) {
        title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: selected ? .semibold : .regular)
    }
}

/// The small rounded square each page's symbol sits in, with a hairline that
/// fades from top to bottom.
final class IconWell: NSView {
    private let fill = CAShapeLayer()
    private let rim = CAGradientLayer()
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        ring.fillRule = .evenOdd
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rim.mask = ring
        layer?.addSublayer(fill)
        layer?.addSublayer(rim)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Shape layers avoid an AppKit bitmap backing store for every 22 pt
    // tile. Repainting those stores during the field's arrival waited on
    // the render server, even though the drawing itself was tiny.
    override func updateLayer() {
        let line: CGFloat = 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.path = CGPath.rounded(fill.bounds.insetBy(dx: line / 2, dy: line / 2), corner: 5)
        rim.frame = bounds
        ring.frame = rim.bounds
        let border = CGMutablePath()
        border.addRounded(ring.bounds, corner: 5)
        border.addRounded(ring.bounds.insetBy(dx: line, dy: line), corner: 5 - line)
        ring.path = border
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.fillColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            rim.colors = [NSColor.labelColor.withAlphaComponent(0.12).cgColor,
                          NSColor.labelColor.withAlphaComponent(0.025).cgColor]
        }
        CATransaction.commit()
    }
}

private final class PageRowView: NSTableRowView {
    /// The gap above the row that begins a group, left unpainted.
    var lead: CGFloat = 0 {
        didSet { if lead != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    private var pointed = false {
        didSet { if pointed != oldValue { needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet {
            // Selected before its cell is in, sometimes: no column to ask yet.
            if numberOfColumns > 0 { (view(atColumn: 0) as? PageCell)?.setSelected(isSelected) }
            needsDisplay = true
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// Where the pointer was as the window came up, until it moves.
    nonisolated(unsafe) static var parked: (window: ObjectIdentifier, at: NSPoint?)?
    /// Each time a window comes forward, the pointer is parked again.
    nonisolated(unsafe) static let unpark: Any = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in parked = nil }

    override func mouseEntered(with event: NSEvent) { repoint() }
    override func mouseExited(with event: NSEvent) { pointed = false }

    /// The wash follows where the pointer is, not the last enter or exit:
    /// a row that slides under a still pointer as a search folds the list,
    /// or scrolls out from under it, is told of only one of the two. Under
    /// the search floating over the list, no row is pointed at.
    func repoint() {
        guard let window, window.isKeyWindow, let scroll = enclosingScrollView else { pointed = false; return }
        // A pointer resting where the window came up isn't pointing at a
        // row: no wash till it moves, or a row the page isn't on reads as
        // lit beside the one that is (General under a parked pointer).
        _ = PageRowView.unpark
        let screen = NSEvent.mouseLocation
        if let parked = PageRowView.parked, parked.window == ObjectIdentifier(window) {
            if parked.at == screen { pointed = false; return }
            PageRowView.parked = (ObjectIdentifier(window), nil)
        } else if PageRowView.parked?.window != ObjectIdentifier(window) {
            PageRowView.parked = (ObjectIdentifier(window), screen)
            pointed = false
            return
        }
        let at = window.mouseLocationOutsideOfEventStream
        let clip = scroll.contentView
        var open = clip.bounds
        open.origin.y += scroll.contentView.contentInsets.top
        open.size.height -= scroll.contentView.contentInsets.top + scroll.contentView.contentInsets.bottom
        pointed = open.contains(clip.convert(at, from: nil)) && bounds.contains(convert(at, from: nil))
    }

    /// The selection in gray, or a lighter wash under the pointer, a source
    /// list has no hover of its own.
    override func drawBackground(in dirtyRect: NSRect) {
        var row = bounds
        row.size.height -= lead
        if isFlipped { row.origin.y += lead }
        let shape = NSBezierPath(roundedRect: row.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            shape.fill()
        } else if pointed {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            shape.fill()
        }
    }
}

// MARK: - the pieces a page is made of

// The same few shapes every settings page is made of. A row says what it
// is in a word or two and has its control across from it; what the row means
// in plain words goes under it, in its own line at the foot of the group,
// never squeezed in beside the switch.

/// A title, sometimes a line under it, and the control across from it.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail = ""
    var verbatimTitle = false
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, detail: String = "", bundle: Bundle = .main, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = SettingsWords.text(title, bundle: bundle)
        self.detail = SettingsWords.text(detail, bundle: bundle)
        self.trailing = trailing
    }

    /// A person's name or account is data even if it matches a table key.
    init(verbatim title: String, detail: String = "", bundle: Bundle = .main, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.verbatimTitle = true
        self.detail = SettingsWords.text(detail, bundle: bundle)
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if verbatimTitle { Text(title) } else { SettingsText(title, size: 13) }
                if !detail.isEmpty {
                    SettingsText(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }
}

/// On or off: the title, and the small system switch across from it. Laid
/// out by hand rather than as a Toggle's own label, so a long title wraps
/// beside the switch instead of pushing it off the row.
struct SettingsSwitch: View {
    let title: String
    @Binding var on: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._on = isOn
    }

    var body: some View {
        SettingsRow(title) {
            Toggle(SettingsText.plain(SettingsWords.text(title)), isOn: $on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// What the rows above it mean, in plain words, at the foot of a group.
struct SettingsNote: View {
    let text: String
    init(_ text: String, bundle: Bundle = .main) { self.text = SettingsWords.text(text, bundle: bundle) }

    var body: some View {
        SettingsText(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A feature's tile in SwiftUI, drawn with the pen as Settings' pages:
/// paper, a swipe of its color, its drawing or glyph in ink. A field
/// row's size draws it smaller on its paper, as the field's places.
struct FeatureTile: View {
    let icon: String
    let tint: NSColor
    var side: CGFloat = 28

    var body: some View {
        PenTileView(symbol: icon, tint: tint, side: side, art: side <= Omnibox.tile ? 0.78 : 1)
            .frame(width: side, height: side)
            .id("\(icon) \(tint)")
            .accessibilityHidden(true)
    }
}

/// A feature on a page: its tile, its name, what it does under it, and
/// across from them its control, or a chevron when the whole row opens a
/// page further in.
struct FeatureRow<Trailing: View>: View {
    let icon: String
    let tint: NSColor
    let title: String
    let detail: String
    var open: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, icon: String, tint: NSColor, detail: String, open: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = SettingsWords.text(title)
        self.icon = icon
        self.tint = tint
        self.detail = SettingsWords.text(detail)
        self.open = open
        self.trailing = trailing
    }

    /// The page a row opens, when it has a pen drawing to wear.
    var pen: SettingsPage?

    var body: some View {
        let row = HStack(alignment: .center, spacing: 10) {
            if let pen, PenArt.has(pen) {
                PenTileView(page: pen, side: 28).frame(width: 28, height: 28)
            } else {
                PenTileView(symbol: icon, tint: tint).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                SettingsText(title, size: 13)
                SettingsText(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        if let open {
            Button(action: open) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint(SettingsWords.format("Opens %@", [title]))
        } else {
            row
        }
    }
}

extension FeatureRow where Trailing == SettingsChevron {
    /// The row that opens a page further in, dressed as that page.
    init(_ page: SettingsPage, title: String? = nil, detail: String, model: SettingsModel) {
        self.init(title ?? page.title, icon: page.icon, tint: page.tint ?? .systemGray, detail: detail,
                  open: { model.go(page) }) { SettingsChevron() }
        pen = page
    }
}

extension FeatureRow {
    /// A page's row with a control of its own before the chevron: Mail's
    /// Agents, turned on right on the row.
    init<Control: View>(_ page: SettingsPage, detail: String, model: SettingsModel,
                        @ViewBuilder control: @escaping () -> Control)
        where Trailing == HStack<TupleView<(Control, SettingsChevron)>> {
        self.init(page.title, icon: page.icon, tint: page.tint ?? .systemGray, detail: detail,
                  open: { model.go(page) }) {
            HStack(spacing: 8) {
                control()
                SettingsChevron()
            }
        }
        pen = page
    }
}

/// One app thanked: its own icon, who made it, what it gave, and the
/// whole row opens its site.
struct CreditRow: View {
    let art: String
    let name: String
    let by: String
    let thanks: String
    let site: String

    var body: some View {
        Button {
            if let url = URL(string: site) { Links.openFromSettings(url) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                icon.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                        if by != name {
                            Text(by).foregroundStyle(.secondary)
                        }
                    }
                    Text(thanks)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Symbol("arrow.up.right", size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(name)'s site")
    }

    @ViewBuilder
    private var icon: some View {
        if let url = Bundle.main.url(forResource: art, withExtension: "png", subdirectory: "Credits"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            PenTileView(page: .credits, side: 36).frame(width: 36, height: 36)
        }
    }
}

/// Says the row goes further in.
struct SettingsChevron: View {
    var body: some View {
        Symbol("chevron.right", size: 11, weight: .semibold)
            .foregroundStyle(.tertiary)
    }
}

/// The top of a feature's page: its tile large, its name, and what it is
/// for, over the page's own background rather than in a group.
struct PageHero: View {
    let title: String
    let blurb: String?
    let icon: AnyView
    /// Whether the icon is a tile's size; a picture of the page's own
    /// (Reading Mode's page) keeps its own.
    var tile = true

    init(page: SettingsPage) {
        title = page.title
        blurb = page.blurb
        icon = AnyView(Group {
            if PenArt.has(page) {
                PenTileView(page: page)
            } else {
                PenTileView(symbol: page.icon, tint: page.tint, side: 56)
            }
        })
    }

    /// A page further in with a head of its own (Passwords' Connect pages):
    /// its icon, its name and its line, drawn as every page's.
    init<Icon: View>(title: String, detail: String, @ViewBuilder icon: () -> Icon) {
        self.title = title
        blurb = detail
        self.icon = AnyView(icon())
    }

    /// A page whose head is a picture of what it sets, in the tile's place,
    /// as App Icon's is the icons.
    init<Art: View>(page: SettingsPage, @ViewBuilder art: () -> Art) {
        title = page.title
        blurb = page.blurb
        icon = AnyView(art())
        tile = false
    }

    var body: some View {
        // A section's header, with nothing under it: the grouped form draws
        // a header on the page itself, where a row would get a card.
        Section {} header: {
            VStack(spacing: 0) {
                icon.frame(width: tile ? 56 : nil, height: tile ? 56 : nil)
                    .padding(.bottom, tile ? 12 : 16)
                Text(SettingsWords.text(title))
                    .font(.system(size: 22, weight: .bold))
                    // Once it is up under the toolbar, the toolbar says it.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        SettingsWindow.shared.heroTitle(title, bottom: bottom)
                    }
                if let blurb {
                    SettingsText(SettingsWords.text(blurb), size: 13)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                        .padding(.horizontal, 24)
                }
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            // Clear of the next group's own header, which sits close under.
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The row a search picked out, as the page knows it.
private struct SpotKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsSpot: String? {
        get { self[SpotKey.self] }
        set { self[SpotKey.self] = newValue }
    }
}

/// A list drawn in one form cell, its rows its own (Spaces, Live Folders):
/// Raycast's table, rows 44 tall with hairlines from the mark on, and a
/// little air above the first and below the last.
enum SettingsList {
    static let row: CGFloat = 44
    static let air: CGFloat = 4
}

/// Hover over a form row's whole cell, not just its words: the grouped form
/// sets each row about ten points in from the separators above and below,
/// and a plain onHover on the content stops short of them, so the pointer
/// on the line's top or bottom edge found the row cold. By a tracking area
/// behind the row, not SwiftUI's onHover: that goes to the frontmost view
/// under the pointer, the row itself, and one behind it never heard a thing.
private struct SettingsRowHover: ViewModifier {
    static let inset: CGFloat = 10 // design: the form's own inset above and below a row
    let change: (Bool) -> Void

    func body(content: Content) -> some View {
        content.background(RowHoverArea(change: change).padding(.vertical, -Self.inset))
    }
}

private struct RowHoverArea: NSViewRepresentable {
    let change: (Bool) -> Void

    func makeNSView(context: Context) -> RowHoverView { RowHoverView(change: change) }
    func updateNSView(_ view: RowHoverView, context: Context) { view.change = change }
}

/// Takes no press: the row, its drag and its minus keep theirs.
private final class RowHoverView: NSView {
    var change: (Bool) -> Void
    private var inside = false

    init(change: @escaping (Bool) -> Void) {
        self.change = change
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    /// A row taken away under the pointer hears no exit; a row brought back
    /// must not come up lit. Later, as this is during SwiftUI's update.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, inside else { return }
        inside = false
        let change = change
        DispatchQueue.main.async { change(false) }
    }

    private func set(_ on: Bool) {
        guard on != inside else { return }
        inside = on
        change(on)
    }
}

extension View {
    /// The row's hover, over its full cell height.
    func settingsRowHover(_ change: @escaping (Bool) -> Void) -> some View {
        modifier(SettingsRowHover(change: change))
    }
}

/// A row the search can find: named for the page to scroll to, and washed
/// gray, like the sidebar's selection, while it is the one picked out.
private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsSpot) private var spot

    func body(content: Content) -> some View {
        // Out to the row's edges less three points all round: the form sets
        // its rows ten in from the card at the sides and about as far above
        // and below, so the wash sits the same distance from the separator,
        // the card's edge and its corners, seven round inside its ten.
        // A Section or ForEach must remain a list of rows, so nothing is
        // stacked around it here; a row says its own detail.
        content
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .padding(.horizontal, -7)
                    .padding(.vertical, -7.5)
                    .opacity(spot == id ? 1 : 0)
                    .animation(.easeOut(duration: spot == id ? 0.12 : 0.5), value: spot == id)
            }
            .id(id)
            .containerValue(\.settingsAnchor, id)
            // Which rows are drawn now, for probes: a search result whose
            // row no page draws scrolls nowhere (feedback #1894).
            .onAppear { if Store.testing { SettingsAnchorsShown.ids[id, default: 0] += 1 } }
            .onDisappear { if Store.testing { SettingsAnchorsShown.ids[id, default: 1] -= 1 } }
    }
}

/// The anchors Settings draws now, counted by row, in a --test run only.
@MainActor
enum SettingsAnchorsShown {
    static var ids: [String: Int] = [:]
    static var shown: [String] { ids.filter { $0.value > 0 }.map(\.key).sorted() }
}

extension View {
    /// Marks a row by its `SettingsItem` id, so the sidebar's search can
    /// bring it into view.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(id: id))
    }

    /// The button at the end of a row, Check Now, Change…, Clear…, the
    /// same button the pages and panels press.
    func settingsButton(_ kind: ButtonKind = .secondary) -> some View {
        buttonStyle(.yab(kind, .regular))
    }
}

/// One capsule of glass with the choice sliding inside it: every answer the
/// same width, so the longest word decides what fits.
/// Given a `button` size, it stands beside that button as its twin: the
/// glass is the button's box, height and corner, and the choice is the
/// plate its keys sit on, at the same inset (KeyPlate).
struct GlassTrack<Option: Hashable>: View {
    let title: String
    let options: [(title: String, value: Option)]
    var labelSize: CGFloat = 12
    /// The button it stands beside; nil for a capsule.
    var button: ButtonSize? = nil
    /// An answer drawn at a size of its own: Page size's three Aa.
    var sizes: [Option: CGFloat] = [:]
    /// What an answer is called where its words don't say it, as its tip
    /// and to VoiceOver: "125%" for the large Aa.
    var names: [Option: String] = [:]
    /// Room on each side of every answer's words, for a track that takes
    /// its own width (`fixedSize`): the widest answer and this, each.
    var room: CGFloat = 0
    @Binding var selection: Option

    private var inset: CGFloat { button?.keyInset ?? 3 }
    /// The choice's height; the glass is one inset taller each way.
    private var height: CGFloat { button.map { $0.height - 2 * $0.keyInset } ?? 26 }
    private var inner: RoundedRectangle { RoundedRectangle(cornerRadius: button == nil ? height / 2 : Radius.small, style: .continuous) }
    private var outer: RoundedRectangle { RoundedRectangle(cornerRadius: button == nil ? height / 2 + inset : Radius.control, style: .continuous) }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let answer = Button { selection = option.value } label: {
                    ZStack {
                        // Every answer as wide as the widest, so a track
                        // sized to fit splits evenly with none cut short:
                        // sized by its own words, "ChatGPT app" ran into
                        // "Terminal" (register #408).
                        ForEach(options, id: \.value) { other in
                            label(other).hidden()
                        }
                        label(option)
                            .foregroundStyle(selection == option.value ? .primary : .secondary)
                    }
                        .padding(.horizontal, room)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .contentShape(inner)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
                if let name = names[option.value] {
                    answer.keyTip(SettingsWords.text(name)).accessibilityLabel(SettingsWords.text(name))
                } else {
                    answer
                }
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(max(options.count, 1))
                inner
                    .fill(scheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.94))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 2, y: 1)
                    .frame(width: width)
                    .offset(x: width * CGFloat(index))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(inset)
        .background {
            if #available(macOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular, in: outer)
            } else {
                outer.fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SettingsWords.text(title))
    }

    private func label(_ option: (title: String, value: Option)) -> some View {
        Text(SettingsWords.text(option.title))
            .font(.system(size: sizes[option.value] ?? labelSize, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A title and a menu across from it, for a choice that needs no picture.
struct MenuRow<Option: Hashable>: View {
    let title: String
    let options: [(title: String, value: Option)]
    @Binding var selection: Option

    init(_ title: String, options: [(title: String, value: Option)], selection: Binding<Option>) {
        self.title = title
        self.options = options
        self._selection = selection
    }

    var body: some View {
        SettingsRow(title) {
            DropMenu(SettingsWords.text(title), options: options.map { (SettingsWords.text($0.title), $0.value) }, selection: $selection)
                .fixedSize()
        }
    }
}

/// A menu row whose answers are pictures, the window's ways of sitting: the
/// chosen picture small beside its name in the row, and in the list each
/// as large as it was given, with a line saying what it does.
struct PictureMenu<Option: Hashable>: View {
    let title: String
    let options: [(title: String, value: Option, picture: NSImage)]
    /// The chosen picture's size in the row.
    let small: NSSize
    /// A line under an answer's name in the list, saying what it does.
    var notes: [Option: String] = [:]
    @Binding var selection: Option

    var body: some View {
        SettingsRow(title) {
            DropMenu(title, options: options.map { DropOption(title: SettingsWords.text($0.title), value: $0.value, picture: $0.picture, note: notes[$0.value]) },
                     selection: $selection, small: small)
                .fixedSize()
        }
    }
}

/// The results page of an engine of your own, under Search with. Kept as
/// it is typed; until it is a web address with `%s` for the words, the note
/// under it says so and Google is asked instead.
struct EngineField: View {
    @Binding var text: String
    /// What falls back in for one that doesn't hold up yet.
    var fallback = Engine.standard.title
    var anchor = "search-engine-custom"

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(SettingsWords.text("Address"), text: $text, prompt: Text("https://example.com/search?q=%s"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
            SettingsNote(
                trimmed.isEmpty || Engine.accepts(trimmed)
                    ? "Use %s for the search query."
                    : "Enter a web address containing %s for the search query. Until then, \(fallback)."
            )
        }
        .settingsAnchor(anchor)
    }
}

/// A title and a track of answers across from it.
struct ChoiceRow<Option: Hashable>: View {
    let title: String
    let options: [(title: String, value: Option)]
    var width: CGFloat = 220
    @Binding var selection: Option

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(SettingsWords.text(title)).frame(maxWidth: .infinity, alignment: .leading)
            GlassTrack(title: title, options: options, selection: $selection)
                .frame(width: width)
        }
    }
}

// MARK: - appearance

/// The window in small, as it will look: the backdrop, the tabs the way
/// they are held, and a page on it with a bar of its own color, so each
/// way of sitting the page is seen as a window rather than read as a word,
/// and the site's color shows what it takes from the site.
private struct WindowPicture: View {
    @ObservedObject var prefs: Preferences
    let mode: Backdrop
    @Environment(\.colorScheme) private var scheme

    /// The page's own bar: a site with a color to give, a blue no swatch
    /// is, so a frame of your color never reads as the bar's, a gray gone
    /// near black in a dark window least of all.
    static let bar = NSColor(srgbRed: 0x2B / 255.0, green: 0x63 / 255.0, blue: 0xE8 / 255.0, alpha: 1)

    var body: some View {
        let dark = scheme == .dark
        let swatch = prefs.swatch.color(dark: dark, custom: prefs.backdropColor)
        let paint: NSColor? = switch mode {
        case .none: nil
        case .color: swatch
        case .site: Self.bar
        }
        // Edge to edge the tabs wear the page's color; on a backdrop, the
        // backdrop, with the live tab a chip lifted off it.
        let tone = Tone(paint ?? Self.bar, lifted: paint != nil)
        let inset: CGFloat = paint == nil ? 0 : 4

        ZStack {
            if let paint {
                BackdropFill(color: Color(nsColor: paint), grain: prefs.grain,
                             colors: mode == .color ? SpacePaint(prefs).gradient(dark: dark) : [])
            } else {
                Color(nsColor: Self.bar)
            }
            if prefs.sidebar {
                if prefs.sideFlank == .right {
                    // The lights in the band across the top (HeadBand).
                    HStack(spacing: 0) {
                        page(corner: inset * 1.5)
                            .padding(EdgeInsets(top: 12, leading: inset, bottom: inset, trailing: 0))
                        column(tone, lit: false)
                            .padding(.top, 8)
                            .frame(width: 44)
                    }
                    .overlay(alignment: .topLeading) {
                        lights.padding(.leading, 5).padding(.top, 4).toned(tone) // design: where the column's own padding(5) puts them on the left
                    }
                } else {
                    HStack(spacing: 0) {
                        column(tone)
                            .frame(width: 44)
                        page(corner: inset * 1.5)
                            .padding(EdgeInsets(top: inset, leading: 0, bottom: inset, trailing: inset))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    strip(tone)
                        .frame(height: 16)
                    page(corner: inset * 1.5)
                        .padding(EdgeInsets(top: 0, leading: inset, bottom: inset, trailing: inset))
                }
            }
        }
        .frame(width: 132, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .animation(.snappy(duration: 0.22), value: prefs.swatch)
        .animation(.snappy(duration: 0.22), value: prefs.backdropColor)
        .animation(.snappy(duration: 0.22), value: prefs.sidebar)
        .animation(.snappy(duration: 0.22), value: prefs.sideFlank)
    }

    private var lights: some View {
        HStack(spacing: 2.5) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                Circle().fill($0).frame(width: 4, height: 4)
            }
        }
    }

    private func column(_ tone: Tone, lit: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            lights.padding(.bottom, 3)
                .opacity(lit ? 1 : 0)
            ForEach(0..<3) { i in
                Capsule().fill(i == 1 ? Palette.ink.opacity(0.75) : Palette.muted(on: tone).opacity(0.5))
                    .frame(width: [22, 26, 18][i], height: 2.5)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: 9, alignment: .leading)
                    .background {
                        if i == 1 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.wash(on: tone))
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .toned(tone)
    }

    private func strip(_ tone: Tone) -> some View {
        HStack(spacing: 3) {
            lights.padding(.trailing, 5)
            ForEach(0..<3) { i in
                Capsule().fill(i == 0 ? Palette.ink.opacity(0.75) : Palette.muted(on: tone).opacity(0.5))
                    .frame(width: 18, height: 2.5)
                    .padding(.horizontal, 5)
                    .frame(height: 10)
                    .background {
                        if i == 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.wash(on: tone))
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .toned(tone)
    }

    /// A page: a heading and a few lines, always light, so the window around
    /// it is the one thing that differs between the three. A bar over it
    /// only when the address bar is on, as the window shows it.
    private func page(corner: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if prefs.addressBar {
                Capsule().fill(Color.black.opacity(0.12))
                    .frame(width: 44, height: 4)
                    .frame(maxWidth: .infinity, minHeight: 11)
                    .background(Color(white: 0.94))
            }
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color.black.opacity(0.7)).frame(width: 40, height: 3.5)
                ForEach(0..<2) { i in
                    Capsule().fill(Color.black.opacity(0.2)).frame(width: [70, 54][i], height: 2.5)
                }
            }
            .padding(7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Edge to edge, a color, the site's color: a menu whose answers are the
/// window in small, the chosen one small beside its name in the row, as
/// Raycast shows its themes.
struct WindowMenu: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.colorScheme) private var scheme
    @State private var pictures = Pictures()

    var body: some View {
        PictureMenu(title: "Window", options: Backdrop.allCases.map { ($0.title, $0, picture($0)) },
                    small: NSSize(width: 30, height: 19),
                    notes: [.none: "The page fills the window",
                            .color: "Your color around the page",
                            .site: "The site\u{2019}s bar runs up into the window"],
                    selection: Binding(
                        get: { prefs.backdrop },
                        set: { Self.pick($0, in: prefs) }
                    ))
    }

    /// A mode picked, as the menu picks it (the bench's film too). A color
    /// asks for one, as Arc's: Appearance's Look opens on it at once (#459).
    static func pick(_ mode: Backdrop, in prefs: Preferences) {
        withAnimation(.snappy(duration: 0.22)) { prefs.backdrop = mode }
        if mode == .color { NotificationCenter.default.post(name: lookAsked, object: prefs) }
    }

    /// "A color" picked: the Look row under the menu opens its controls.
    static let lookAsked = Notification.Name("yab.settings.lookAsked")

    /// The window drawn once for what it shows, kept until that changes:
    /// the menu's pictures are asked for on every pass over the page. Half
    /// the size it is drawn at, so its lines stay sharp.
    private func picture(_ mode: Backdrop) -> NSImage {
        let key = [mode.rawValue, scheme == .dark ? "dark" : "light", prefs.swatch.rawValue, prefs.backdropColor.hex,
                   "\(prefs.grain)", "\(prefs.sidebar)", prefs.sideFlank.rawValue, "\(prefs.addressBar)", prefs.backdropColors.joined()].joined(separator: " ")
        if let kept = pictures.kept[key] { return kept }
        let renderer = ImageRenderer(content: WindowPicture(prefs: prefs, mode: mode).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: 66, height: 42)
        if pictures.kept.count > 24 { pictures.kept.removeAll() }
        pictures.kept[key] = image
        return image
    }

    private final class Pictures {
        var kept: [String: NSImage] = [:]
    }
}

/// What the address bar shows, or that there is none: the bar and how much
/// of the address it gives, as one choice.
enum AddressShow: Hashable {
    case hidden, site, full
}

// MARK: - the page

/// The corner's notice, at the top of Settings: its own view, so what comes
/// and goes here doesn't lay out the page under it. One that can be taken
/// back stands in the bottom corner with its Undo, as the windows' corner
/// has it, off the page's head (Memory › Days' Forget This Thread).
private struct SettingsNotice: View {
    @ObservedObject var toaster: Toaster
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let corner = toaster.undo != nil
        ZStack {
            if toaster.shown {
                NoticePlate(words: toaster.words, mark: toaster.mark, keys: toaster.keys,
                            undo: corner ? { toaster.undone() } : nil)
                    .padding(corner ? .bottom : .top, corner ? 20 : 8)
                    .padding(.trailing, corner ? 20 : 0)
                    .transition(still ? .opacity : .move(edge: corner ? .bottom : .top).combined(with: .opacity))
                    .id(toaster.words)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner ? .bottomTrailing : .top)
        .animation(still ? Motion.quick : Motion.arrive, value: toaster.shown)
        .animation(still ? Motion.quick : Motion.arrive, value: toaster.words)
    }
}

/// The pane beside the sidebar. Each page is a view of its own watching
/// only what it shows (SettingsCorePages and the pages' own files); this
/// keeps what lasts while the window is open and brings a found row into view.
private struct SettingsDetail: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel

    @State private var isDefault = Links.isDefault
    /// General's other browsers, counted once while the window is open.
    /// Held, not watched: a count coming in draws General's steps and its
    /// foot (GeneralSteps, BringInFoot), not the whole pane.
    @State private var bringing = Bringing()
    /// How much of the page shows under the toolbar (settingsPageHeight).
    @State private var pageHeight: CGFloat = 0
    @State private var bringsOpenTabs = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { scroller in
            form
                .onChange(of: model.spot) { _, spot in
                    guard let spot else { return }
                    // After the page it is on has been laid out, when that
                    // page has only just been switched to.
                    let anchor = spot.anchor(prefs)
                    DispatchQueue.main.async { scroller.scrollTo(anchor, anchor: .center) }
                }
        }
    }

    private var form: some View {
        SettingsWayIn(browser: browser, prefs: prefs, model: model, rows: rows)
        .environment(\.settingsSpot, model.spot?.anchor(prefs))
        .font(.system(size: 13))
        .controlSize(.regular)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { notice }
        // The page's cards, Add Site…, Connect, a snippet, stand in a
        // window of their own over Settings (SettingsCards).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = Links.isDefault
            DefaultBrowser.shared.refresh()
        }
    }

    private var rows: some View {
        pageRows
        .formStyle(.grouped)
        // Every page starts at its top: a sub-page such as Best Friend, an
        // extension's page, and the list after it. Keyed by both, or the
        // form kept the page before's scroll.
        .id("\(model.page)/\(model.opened ?? "")")
        // The form runs under the toolbar: what shows is its height less that.
        .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom } action: { pageHeight = $0 }
        .environment(\.settingsPageHeight, pageHeight)
    }

    @ViewBuilder private var pageRows: some View {
        // Hundreds of rows: a Form keeps them all alive, this list only
        // those in view.
        if model.page == .shortcuts {
            ShortcutsPage(selection: model.shortcutFilters)
        } else {
            formRows
        }
    }

    private var formRows: some View {
        ThreadForm {
            switch model.page {
            case .general: GeneralPage(browser: browser, prefs: prefs, model: model, bringing: bringing, isDefault: $isDefault)
            case .search: SearchPage(prefs: prefs)
            case .appearance: AppearancePage(browser: browser, prefs: prefs, model: model)
            case .websites: WebsitesPage(prefs: prefs, model: model)
            case .tabs: TabsPage(prefs: prefs)
            case .extensions: ExtensionsPage(browser: browser, model: model)
            case .engine: EnginePage(search: model.engineSearch)
            case .boosts: EmptyView() // Own arrival, list and detail (BoostsSettings).
            case .spaces: SpacesPage(browser: browser, prefs: prefs, model: model)
            case .liveFolders: EmptyView() // Own arrival, list and detail above.
            case .sync: SyncPage(model: model)
            case .mail: MailSettings(browser: browser, prefs: prefs, model: model)
            case .snippets: SnippetsPage()
            case .mailInbox, .mailNotify, .mailReading, .mailWriting, .mailCalendar, .mailAgents, .mailBlocked:
                MailSettingsPage(page: model.page, prefs: prefs, model: model)
            case .ai: AIPage(browser: browser, prefs: prefs, model: model)
            case .models: ModelsPage(browser: browser)
            case .agents: AgentsPage(browser: browser, prefs: prefs, model: model)
            case .assistants: AssistantsPage(browser: browser, model: model)
            case .siteButtons: SiteButtonsSettings(model: model)
            case .whileYouBrowse: WhileYouBrowsePage(prefs: prefs)
            case .commands: CommandSettingsPage(commands: browser.selectionCommands)
            case .smallWindow: SmallWindowPage(prefs: prefs)
            case .reading: ReadingModePage()
            case .passwords: PasswordsPage(browser: browser, prefs: prefs, model: model)
            case .autofill: AutofillPage(browser: browser, prefs: prefs)
            case .privacy: PrivacyPage(browser: browser, prefs: prefs, model: model)
            case .shortcuts: EmptyView() // Own lazy list (pageRows).
            case .about: AboutPage(browser: browser, model: model)
            case .bringIn: BringInPage(browser: browser, model: model, bringsOpenTabs: $bringsOpenTabs)
            case .history: HistoryPage(browser: browser, prefs: prefs)
            case .credits: CreditsPage(model: model)
            case .appIcon: AppIconPage(model: model)
            case .inviteFriends: InviteFriendsPage(model: model)
            case .bestFriend: BestFriendPage()
            case .agentRoutines: AgentRoutinesPage(browser: browser)
            case .agentMemory: AgentMemoryPage(browser: browser, prefs: prefs, model: model)
            case .agentSkills: AgentSkillsPage(model: model)
            case .developers: DevelopersPage(browser: browser, prefs: prefs)
            case .experimental: ExperimentalPage(prefs: prefs, model: model)
            }
        }
    }

    /// What was just done here, said here, in the same plate the page's
    /// corner wears. Never the browser's own notices: those are its windows'.
    private var notice: some View {
        SettingsNotice(toaster: SettingsWindow.shared.toaster)
    }
}

/// Which way the page opens: a feature's way in while it is off or empty,
/// or its rows. Its own view, so a mail or a sync coming in asks this again
/// and not the whole pane.
private struct SettingsWayIn<Rows: View>: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    let rows: Rows

    @ObservedObject private var agentSetup = AgentSetupModel.shared
    @ObservedObject private var memory = MemoryShelf.shared
    @ObservedObject private var sync = SyncCenter.shared
    @ObservedObject private var mail = MailCenter.shared
    @ObservedObject private var assistants = Assistants.shared
    @ObservedObject private var apiKeys = APIKeys.shared
    @ObservedObject private var geminiChoices = GeminiChoices.shared

    /// Settings › Mail is its way in: no account yet, or one just in.
    private var mailArriving: Bool { mail.accounts.isEmpty || mail.landed != nil }

    var body: some View {
        Group {
            // Adding an extension is an arrival, not a form: a column in the
            // middle of the pane.
            if model.page == .extensions {
                ExtensionsPane(browser: browser, model: model) { rows }
            } else if model.page == .boosts {
                BoostsSettings(browser: browser, prefs: prefs, model: model)
            } else if model.page == .liveFolders {
                LiveFoldersSettings(browser: browser, prefs: prefs, model: model)
            } else if geminiChoices.inSettings(model.page) {
                ArrivalFrame { GeminiArrival(browser: browser) }
            // Add Account's API keys: a page of their own in Models' place.
            } else if model.page == .models, let page = apiKeys.page, agentSetup.flow == nil {
                APIKeyPage(browser: browser, page: page)
                    .id(page.provider.rawValue + (page.replacing ?? ""))
            } else if model.page == .spaces, model.opened == nil, !prefs.usesSpaces {
                SpacesArrival(browser: browser, prefs: prefs)
            } else if model.page == .sync, model.opened == nil, !sync.on {
                SyncArrival()
            } else if model.page == .sync, model.opened == SyncPlace.add {
                SyncAddDevicePage(model: model)
            } else if model.page == .assistants {
                AssistantsPage(browser: browser, model: model)
            // No AI in yab without your own Claude Code or Codex: until one
            // is connected, AI is the way in (after the welcome, if it didn't).
            // A probe can still inspect Assistants and Buttons on Sites in an empty world.
            // Models connects each plan and configures the Field's reader,
            // so it remains available before any plan is connected.
            } else if model.page.top == .ai, agentSetup.arriving,
                      model.page != .agentMemory,
                      !(model.page == .ai && memory.hasRetainedContext),
                      // AI in Yab's switch stays reachable without a plan:
                      // once AI was turned down, or while the Mac's own
                      // model answers (#787), AI is its page, not Connect.
                      // A test world told an agent is there sees it too.
                      !(model.page == .ai && (prefs.aiUse != .on || FormModel.ready || (Store.testing && Agents.assumedInTests == true))),
                      !(Store.testing && [.assistants, .siteButtons].contains(model.page)),
                      // While You Browse names with this Mac's model: no plan needed.
                      model.page != .whileYouBrowse,
                      (model.page != .models || agentSetup.flow != nil) {
                AgentsIntro(browser: browser)

            // Mail, until an account is in, and once just after.
            } else if model.page == .mail, mailArriving {
                MailArrival(browser: browser, prefs: prefs)
            } else if model.page == .agentMemory, model.opened == nil, !memory.hasRetainedContext {
                MemoryArrival(browser: browser, prefs: prefs)
            } else {
                rows
            }
        }
    }
}

/// Another browser's look, to wear here: Arc's spaces' colors and grain,
/// or Chrome's profiles' colors. Shown only when one on this Mac has them.
/// With spaces on, each space brought from there wears its own again;
/// otherwise the window wears the first one's. `under`: at the foot of the
/// color editor, the dots and the button alone, the editor being the row.
/// Matched once, it is gone for good: the look is worn, no more offer.
struct BrowserLook: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    var under = false
    @ObservedObject private var finder = BrowserLookFinder.shared
    @AppStorage("browserLookMatched", store: Store.settings) private var matched = false

    var body: some View {
        if let found = finder.found, !matched {
            if under {
                HStack(spacing: 10) {
                    dots(found)
                    Spacer(minLength: 0)
                    Button("Match \(found.source.name)") { match(found.places) }
                        .buttonStyle(.yab(.secondary, .small))
                        .keyTip(detail(found))
                }
                .padding(.top, 12)
            } else {
                SettingsRow("From \(found.source.name)", detail: detail(found)) {
                    HStack(spacing: 10) {
                        dots(found)
                        Button("Match \(found.source.name)") { match(found.places) }.settingsButton()
                    }
                }
                .settingsAnchor("browser-look")
            }
        }
    }

    /// Its colors overlapping on the row's card; apart on the editor's
    /// glass, where no ring could be the color behind them.
    private func dots(_ found: BrowserLookFinder.Found) -> some View {
        HStack(spacing: under ? 4 : -4) {
            ForEach(found.places.prefix(5), id: \.id) { place in
                let paint = place.paint(prefs) ?? SpacePaint(prefs)
                BackdropFill(color: Color(nsColor: paint.color(dark: false)), grain: paint.grain, colors: paint.gradient(dark: false))
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                    .overlay {
                        if !under { Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2) }
                    }
            }
        }
    }

    private func detail(_ found: BrowserLookFinder.Found) -> String {
        let names = found.places.prefix(3).map(\.name).joined(separator: ", ")
        let first = found.places[0]
        return spaced ? "\(names), each in its own color and grain."
            : "Wear \(first.name)\u{2019}s color\((first.grain ?? 0) > 0 ? " and grain" : "") here."
    }

    /// Spaces that came from there, to wear their own again.
    private var spaced: Bool { prefs.usesSpaces && browser.spaces.contains { $0.origin != nil } }

    private func match(_ places: [TabImport.Place]) {
        defer { matched = true }
        if spaced {
            for place in places {
                guard let paint = place.paint(prefs), let space = browser.spaces.first(where: { $0.origin == place.id }) else { continue }
                browser.setSpacePaint(space.id, to: paint)
            }
        } else if let paint = places.first?.paint(prefs) {
            paint.wear(prefs)
        }
    }
}

/// The first browser on this Mac, in the order they are found, whose places
/// wear colors. Read once, off the main thread, every browser at once: one
/// slow to read doesn't hold up the rest.
@MainActor
final class BrowserLookFinder: ObservableObject {
    static let shared = BrowserLookFinder()
    typealias Found = (source: Chromium.Source, places: [TabImport.Place])
    @Published private(set) var found: Found?
    private var started = false

    /// `among`: the browsers to look in, the ones on this Mac unless named.
    func load(among named: [Chromium.Source]? = nil) {
        guard !started || named != nil else { return }
        started = true
        DispatchQueue.global(qos: .utility).async {
            let sources = named ?? Chromium.installed()
            var colored = [[TabImport.Place]](repeating: [], count: sources.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: sources.count) { at in
                let places = ((try? TabImport.places(in: sources[at])) ?? []).filter { $0.color != nil }
                lock.withLock { colored[at] = places }
            }
            let first = sources.indices.first { !colored[$0].isEmpty }
            DispatchQueue.main.async {
                if let first { self.found = (sources[first], colored[first]) }
            }
        }
    }
}

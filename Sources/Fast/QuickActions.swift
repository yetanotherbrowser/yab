import AppKit
import Combine
import Foundation

/// A named web destination in the field. Unlike a site scope, Return opens
/// this exact address and there are no words to put into a search template.
struct QuickAction: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var url: String
    var alias: String
    var shortcut = ""
    var enabled = true
    var custom = false

    var destination: URL? { URL(string: url) }
    var host: String { destination?.host()?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? "" }

    static let document = QuickAction(id: "new-document", name: "New document", url: "https://docs.new", alias: "doc")
    static let meeting = QuickAction(id: "new-meeting", name: "New meeting", url: "https://meet.new", alias: "meet")
    static let builtIn = [document, meeting]
}

/// Somewhere yab can open to make something new: an address its maker
/// documents, each one checked by hand (docs/quick-actions.md). Nothing
/// else is offered; a visited site's own /new path is never guessed.
struct Maker {
    /// What is made; the things made are counted under it.
    let id: String
    let product: String
    let url: String
    /// Where visits say the site is used, before anything made is seen.
    var sites: [(host: String, path: String?)] = []
    /// Its own icon's address, where its site's is someone else's: Google's
    /// editors share docs.google.com.
    var icon: String? = nil
    /// The action offered for it, when it isn't one of the two built in.
    var action: (id: String, name: String, alias: String)? = nil
    /// Words someone might type meaning this, besides the action's name.
    var words: [String] = []
    /// A page on the way to something being made. The maker's own button
    /// goes there as well as its .new address.
    var making: (URL) -> Bool = { _ in false }
    /// The page of a thing just made, told by its untitled name.
    var fresh: (URL, String) -> Bool = { _, _ in false }

    var host: String { URL(string: url).map(Maker.host) ?? "" }

    static func host(_ url: URL) -> String {
        (url.host() ?? "").lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    /// A title as the site names the thing, without the site's own name
    /// after it: "Untitled document - Google Docs" is "untitled document".
    static func bare(_ title: String) -> String {
        var text = title.lowercased()
        for cut in [" - ", " – ", " | "] {
            if let at = text.range(of: cut) { text = String(text[..<at.lowerBound]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func path(_ url: URL, _ pattern: String) -> Bool {
        url.path().range(of: pattern, options: .regularExpression) != nil
    }

    /// Google's editors: made through /create, fresh while untitled.
    private static func google(_ id: String, _ product: String, _ kind: String, untitled: Set<String>,
                               icon: String, sites: [(host: String, path: String?)],
                               action: (id: String, name: String, alias: String)? = nil,
                               words: [String] = []) -> Maker {
        let dotNew = id + ".new"
        return Maker(id: id, product: product, url: "https://" + dotNew, sites: sites, icon: icon, action: action, words: words,
                     making: { url in
                         host(url) == dotNew
                             || (host(url) == "docs.google.com" && path(url, "^/\(kind)(/u/[0-9]+)?/create"))
                     },
                     fresh: { url, title in
                         host(url) == "docs.google.com" && url.path().hasPrefix("/\(kind)/d/")
                             && untitled.contains(bare(title))
                     })
    }

    static let docs = google("docs", "Google Docs", "document",
                             untitled: ["untitled document"],
                             icon: "https://ssl.gstatic.com/docs/documents/images/kix-favicon-2023q4.ico",
                             sites: [("docs.google.com", "/document")])
    static let sheets = google("sheets", "Google Sheets", "spreadsheets",
                               untitled: ["untitled spreadsheet"],
                               icon: "https://ssl.gstatic.com/docs/spreadsheets/spreadsheets_2023q4.ico",
                               sites: [("sheets.google.com", nil), ("docs.google.com", "/spreadsheets")],
                               action: ("new-spreadsheet", "New spreadsheet", "sheet"),
                               words: ["spreadsheet", "sheet", "table", "excel"])
    static let slides = google("slides", "Google Slides", "presentation",
                               untitled: ["untitled presentation"],
                               icon: "https://ssl.gstatic.com/docs/presentations/images/favicon-2023q4.ico",
                               sites: [("slides.google.com", nil), ("docs.google.com", "/presentation")],
                               action: ("new-presentation", "New presentation", "slides"),
                               words: ["presentation", "slides", "deck"])
    static let notion = Maker(
        id: "notion", product: "Notion", url: "https://notion.new", sites: [("notion.so", nil)],
        words: ["notion", "page"],
        making: { host($0) == "notion.new" || (host($0) == "notion.so" && $0.path() == "/new") },
        fresh: { url, title in
            host(url) == "notion.so" && ["untitled", "new page"].contains(bare(title))
        })
    static let meet = Maker(
        id: "meet", product: "Google Meet", url: "https://meet.new", sites: [("meet.google.com", nil)],
        making: { host($0) == "meet.new" || (host($0) == "meet.google.com" && $0.path().hasPrefix("/new")) })
    /// Started as the host: zoom.new goes to /start, and a meeting you
    /// start is at /s/, one you join at /j/.
    static let zoom = Maker(
        id: "zoom", product: "Zoom", url: "https://zoom.new", sites: [("zoom.us", nil)],
        words: ["zoom"],
        making: { url in
            let host = host(url)
            return host == "zoom.new" || ((host == "zoom.us" || host.hasSuffix(".zoom.us"))
                && (url.path().hasPrefix("/start") || path(url, "^/s/[0-9]+") || path(url, "^/wc/[0-9]+/start")))
        })
    static let figma = Maker(
        id: "figma", product: "Figma", url: "https://figma.new", sites: [("figma.com", nil)],
        action: ("new-figma-file", "New Figma file", "figma"), words: ["figma", "design", "file"],
        making: { host($0) == "figma.new" || (host($0) == "figma.com" && $0.path().hasPrefix("/new")) },
        fresh: { url, title in
            host(url) == "figma.com" && path(url, "^/(design|file|board|slides)/") && bare(title).hasPrefix("untitled")
        })
    static let linear = Maker(
        id: "linear", product: "Linear", url: "https://linear.new", sites: [("linear.app", nil)],
        action: ("new-linear-issue", "New Linear issue", "issue"), words: ["linear", "issue", "ticket", "bug"],
        making: { host($0) == "linear.new" || (host($0) == "linear.app" && path($0, "/new/?$")) })
    static let repo = Maker(
        id: "repo", product: "GitHub", url: "https://repo.new", sites: [("github.com", nil)],
        action: ("new-repository", "New repository", "repo"), words: ["repository", "repo", "github"],
        making: { host($0) == "repo.new" || (host($0) == "github.com" && path($0, "^/new/?$")) })
    static let gist = Maker(
        id: "gist", product: "GitHub Gist", url: "https://gist.new", sites: [("gist.github.com", nil)],
        action: ("new-gist", "New gist", "gist"), words: ["gist", "snippet", "github"],
        making: { host($0) == "gist.new" })
    static let calendar = Maker(
        id: "calendar", product: "Google Calendar", url: "https://cal.new", sites: [("calendar.google.com", nil)],
        action: ("new-event", "New event", "event"), words: ["event", "calendar", "cal"],
        making: { host($0) == "cal.new" || (host($0) == "calendar.google.com" && path($0, "/r/eventedit")) })

    static let all = [docs, notion, sheets, slides, meet, zoom, figma, linear, repo, gist, calendar]
    /// Those with an action of their own to offer.
    static let offered = all.filter { $0.action != nil }

    static func of(url: String) -> Maker? {
        guard let url = URL(string: url) else { return nil }
        return all.first { $0.making(url) }
    }
}

struct QuickActionSuggestion: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var url: String
    var alias: String
    var replacing: String? = nil
}

@MainActor
final class QuickActions: ObservableObject {
    static let shared = QuickActions()

    /// The icon a Quick Action's row wears, by the name it is kept under:
    /// the product's own, Google Docs' for docs.new, whose address is only
    /// a door to it.
    static func site(of offer: Suggestion) -> String? {
        guard case .quickAction = offer.kind, let url = offer.url else { return nil }
        guard let maker = Maker.all.first(where: { $0.making(url) }) else { return Maker.host(url) }
        return maker.icon == nil ? maker.sites.first?.host ?? maker.host : "make." + maker.id
    }

    /// That icon asked for, once.
    static func fetchIcon(of offer: Suggestion) {
        guard let key = site(of: offer) else { return }
        if key.hasPrefix("make."), let maker = Maker.all.first(where: { "make." + $0.id == key }),
           let icon = maker.icon.flatMap(URL.init(string:)) {
            Favicons.shared.fetch(icon, as: key)
        } else {
            Favicons.shared.fetch(host: key)
        }
    }

    @Published private(set) var actions: [QuickAction]
    @Published private(set) var suggestions: [QuickActionSuggestion] = []
    private var personalized: Set<String>
    private var dismissed: Set<String>
    /// Things made lately, by which maker: what picks the provider of the
    /// two built in, and what an action is offered for.
    private var made: [Made]
    /// How many times each action's alias has been shown under the empty
    /// field after the same thing was made by hand. Twice, then never.
    private var hinted: [String: Int]
    private var hint: (id: String, since: Date, shown: Date?)?
    private var ran: (maker: String, at: Date)?
    private var fresh: Set<String> = []
    private var refreshed = Date.distantPast
    private var daily: Timer?
    private let history: History
    private let ephemeral: Bool

    struct Made: Codable, Equatable {
        var maker: String
        var date: Date
    }

    struct Saved: Codable {
        var actions: [QuickAction]
        var personalized: Set<String>
        var dismissed: Set<String>
        var made: [Made]?
        var hinted: [String: Int]?

        /// The sets sorted: a set lists its members in another order in
        /// each run, and sync compares the file across Macs.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(actions, forKey: .actions)
            try c.encode(personalized.sorted(), forKey: .personalized)
            try c.encode(dismissed.sorted(), forKey: .dismissed)
            try c.encodeIfPresent(made, forKey: .made)
            try c.encodeIfPresent(hinted, forKey: .hinted)
        }
    }

    private static var file: URL { Store.file("quick-actions.json") }

    /// The file again, as sync wrote it from another Mac (SyncCenter).
    func reload() {
        guard !ephemeral, let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        var actions = saved.actions
        for builtIn in QuickAction.builtIn where !actions.contains(where: { $0.id == builtIn.id }) { actions.append(builtIn) }
        if actions != self.actions { self.actions = actions }
        personalized = saved.personalized
        dismissed = saved.dismissed
        made = saved.made ?? made
        hinted = saved.hinted ?? hinted
    }

    init(history: History? = nil, stored: Data? = nil) {
        self.history = history ?? History.shared
        ephemeral = stored != nil
        let data = stored ?? (try? Data(contentsOf: Self.file))
        let saved = data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var actions = saved?.actions ?? QuickAction.builtIn
        for builtIn in QuickAction.builtIn where !actions.contains(where: { $0.id == builtIn.id }) {
            actions.append(builtIn)
        }
        // A site keyword kept before this feature belongs to that site.
        // The new built-ins are still usable by name, with an empty alias.
        if saved == nil {
            for index in actions.indices where Scopes.all.contains(where: {
                $0.aliases.contains(actions[index].alias) || $0.name.lowercased() == actions[index].alias
            }) {
                actions[index].alias = ""
            }
        }
        self.actions = actions
        personalized = saved?.personalized ?? []
        dismissed = saved?.dismissed ?? []
        made = saved?.made ?? []
        hinted = saved?.hinted ?? [:]
        refresh(from: self.history)
        // yab stays open for weeks: visits fade and what they suggest with
        // them, looked at again once a day rather than only at launch.
        guard !ephemeral else { return }
        daily = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.refreshed) >= 86_400 else { return }
                self.refresh(from: self.history)
            }
        }
        daily?.tolerance = 600
    }

    func action(_ id: String) -> QuickAction? { actions.first { $0.id == id } }

    func suggestion(_ id: String) -> QuickActionSuggestion? { suggestions.first { $0.id == id } }

    func action(for key: Hotkey) -> QuickAction? {
        actions.first { $0.enabled && !$0.shortcut.isEmpty && Hotkey(stored: $0.shortcut) == key }
    }

    // MARK: - the field

    /// Words that mean making something, whatever is made.
    static let making = ["new", "create"]

    private static let meaning: [String: [String]] = [
        QuickAction.document.id: ["document", "doc", "write", "note"],
        QuickAction.meeting.id: ["meeting", "meet", "call", "video"],
    ]

    /// Every word an action answers to: its name, its alias, what it makes
    /// and the maker it opens now.
    private func vocabulary(name: String, alias: String, id: String, url: String) -> [String] {
        var words = Self.making + name.lowercased().split(separator: " ").map(String.init)
        if !alias.isEmpty { words.append(alias) }
        words += Self.meaning[id] ?? []
        if let maker = Maker.of(url: url) {
            words += maker.words
            if let action = maker.action { words += action.name.lowercased().split(separator: " ").map(String.init) }
        }
        return words
    }

    /// Each word typed begins one of the action's words: "new sh" is New
    /// spreadsheet, "cre mee" New meeting. Words too short to mean
    /// anything alone, and a lone word shorter than three letters, don't.
    private static func answers(_ text: String, _ words: [String]) -> Bool {
        let typed = text.split(separator: " ").map(String.init)
        guard !typed.isEmpty, text.count >= 3, typed.allSatisfy({ $0.count >= 2 }) else { return false }
        return typed.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
    }

    func matches(_ query: String) -> [QuickAction] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count >= 2 else { return [] }
        let found = actions.filter { action in
            action.enabled && ((!action.alias.isEmpty && action.alias.hasPrefix(text))
                               || (text.count >= 3 && action.name.lowercased().hasPrefix(text))
                               || Self.answers(text, vocabulary(name: action.name, alias: action.alias, id: action.id, url: action.url)))
        }
        // The exact alias first, the rest in the order they are kept.
        return found.filter { $0.alias == text } + found.filter { $0.alias != text }
    }

    /// Actions history suggests but that aren't kept yet, named by the
    /// same words: one taken in the field is kept, alias and all.
    func offered(_ query: String) -> [QuickActionSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count >= 2 else { return [] }
        return suggestions.filter { suggestion in
            suggestion.replacing == nil
                && (suggestion.alias.hasPrefix(text)
                    || Self.answers(text, vocabulary(name: suggestion.name, alias: suggestion.alias, id: suggestion.id, url: suggestion.url)))
        }
    }

    /// An exact alias owns Return, even if history could finish the same
    /// letters as a URL. A partially typed title stays below history.
    func exact(_ query: String) -> QuickAction? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return actions.first { $0.enabled && !$0.alias.isEmpty && $0.alias == text }
    }

    // MARK: - editing

    func problem(with proposed: QuickAction, excluding id: String? = nil) -> String? {
        let name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give this action a name." }
        guard Self.validURL(proposed.url) else { return "Use a full https:// web address." }
        let alias = proposed.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !alias.isEmpty {
            guard alias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return "Aliases use letters, digits or - without spaces."
            }
            if let other = actions.first(where: { $0.id != id && $0.alias == alias }) { return "Already used by \(other.name)." }
            if let scope = Scopes.all.first(where: { $0.aliases.contains(alias) || $0.name.lowercased() == alias || $0.host == alias }) {
                return "Already used by \(scope.name) search."
            }
            if let place = FieldPlace.allCases.first(where: { $0.names.contains(alias) }) { return "Already used by \(place.title)." }
            if let command = Command.allCases.first(where: { $0.title.lowercased() == alias }) { return "Already used by \(command.title)." }
            if let owner = ExtensionCommands.aliasOwner(alias) { return "Already used by \(owner)." }
        }
        if let key = Hotkey(stored: proposed.shortcut), let message = shortcutProblem(key, excluding: id) { return message }
        return nil
    }

    func shortcutProblem(_ key: Hotkey, excluding id: String? = nil) -> String? {
        guard key.commands else {
            return "Quick Actions need Command, Option, Control or an F key so typing still reaches the page."
        }
        if let other = actions.first(where: { $0.id != id && Hotkey(stored: $0.shortcut) == key }) {
            return "Already used by \(other.name)."
        }
        if let clash = Keymap.shared.clash(key, for: nil, quickAction: id) {
            switch clash {
            case .refused(let message): return message
            case .taken(let message, _): return message
            }
        }
        for owner in BrowserWindows.shared.browsers {
            if let command = owner.selectionCommands.commands.first(where: { $0.enabled && Hotkey(stored: $0.shortcut) == key }) {
                return "Already used by \(command.name)."
            }
        }
        return nil
    }

    @discardableResult
    func put(_ value: QuickAction) -> String? {
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.url = value.url.trimmingCharacters(in: .whitespacesAndNewlines)
        value.alias = value.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let problem = problem(with: value, excluding: value.id) { return problem }
        let old = action(value.id)
        if let at = actions.firstIndex(where: { $0.id == value.id }) { actions[at] = value }
        else { actions.append(value) }
        if old?.url != value.url { personalized.insert(value.id) }
        persist()
        refresh(from: history)
        return nil
    }

    @discardableResult
    func setEnabled(_ id: String, _ enabled: Bool) -> String? {
        guard let at = actions.firstIndex(where: { $0.id == id }) else { return nil }
        if enabled, let key = Hotkey(stored: actions[at].shortcut),
           let problem = shortcutProblem(key, excluding: id) { return problem }
        actions[at].enabled = enabled
        persist()
        return nil
    }

    func remove(_ id: String) {
        guard let at = actions.firstIndex(where: { $0.id == id }) else { return }
        if actions[at].custom { actions.remove(at: at) }
        else { actions[at].enabled = false; personalized.insert(id) }
        persist()
        refresh(from: history)
    }

    func clearShortcut(_ id: String) {
        guard let at = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[at].shortcut = ""
        persist()
    }

    func accept(_ suggestion: QuickActionSuggestion) {
        if let id = suggestion.replacing, var action = action(id) {
            action.url = suggestion.url
            _ = put(action)
        } else {
            let value = QuickAction(id: suggestion.id, name: suggestion.name, url: suggestion.url,
                                    alias: availableAlias(suggestion.alias), custom: true)
            _ = put(value)
        }
        dismissed.insert(suggestion.id)
        persist()
        refresh(from: history)
    }

    func dismiss(_ suggestion: QuickActionSuggestion) {
        dismissed.insert(suggestion.id)
        persist()
        suggestions.removeAll { $0.id == suggestion.id }
    }

    private func availableAlias(_ preferred: String) -> String {
        guard !actions.contains(where: { $0.alias == preferred }),
              !Scopes.all.contains(where: { $0.aliases.contains(preferred) || $0.host == preferred }),
              !FieldPlace.allCases.contains(where: { $0.names.contains(preferred) }) else { return "" }
        return preferred
    }

    // MARK: - things made

    /// An action taken, from the field or its hotkey: what it makes next
    /// was asked for here, not made by hand on the site.
    func ran(_ url: URL) {
        if let maker = Maker.all.first(where: { $0.making(url) }) { ran = (maker.id, Date()) }
        hint = nil
    }

    /// A page of yours, asked for or landed on: something being made, or
    /// the untitled thing just made. Nothing from a private tab comes here.
    func noticed(_ url: URL, title: String = "", now: Date = Date()) {
        let starting = Maker.all.first { $0.making(url) }
        var found = starting
        if found == nil, !title.isEmpty, let maker = Maker.all.first(where: { $0.fresh(url, title) }) {
            // The same untitled page renamed again is still the one thing.
            guard fresh.insert(Address.pretty(url).lowercased()).inserted else { return }
            if fresh.count > 200 { fresh.removeAll() }
            found = maker
        }
        guard let maker = found else { return }
        // /create, then the document it made: one thing, seen twice.
        if let last = made.last(where: { $0.maker == maker.id }), now.timeIntervalSince(last.date) < 30 { return }
        made.append(Made(maker: maker.id, date: now))
        made.removeAll { now.timeIntervalSince($0.date) > 90 * 86_400 }
        if made.count > 400 { made.removeFirst(made.count - 400) }
        let byHand = !(ran.map { $0.maker == maker.id && now.timeIntervalSince($0.at) < 30 } ?? false)
        if byHand, let action = actions.first(where: { $0.enabled && !$0.alias.isEmpty && Maker.of(url: $0.url)?.id == maker.id }),
           hinted[action.id, default: 0] < 2 {
            hint = (action.id, now, nil)
        }
        persist()
        refresh(from: history, now: now)
    }

    func count(_ maker: String, days: Double = 60, now: Date = Date()) -> Int {
        made.filter { $0.maker == maker && now.timeIntervalSince($0.date) <= days * 86_400 }.count
    }

    /// The action whose alias the empty field says, a day at most after
    /// the thing was made by hand. Twice ever for each action.
    func hinting(now: Date = Date()) -> QuickAction? {
        guard let hint, now.timeIntervalSince(hint.since) < 86_400, hinted[hint.id, default: 0] < 2,
              let action = action(hint.id), action.enabled, !action.alias.isEmpty else { return nil }
        return action
    }

    /// Shown once per opening of the field: the list is asked again on
    /// every change, a minute apart is another time.
    func showedHint(_ id: String, now: Date = Date()) {
        guard var hint, hint.id == id else { return }
        if let shown = hint.shown, now.timeIntervalSince(shown) < 60 { return }
        hint.shown = now
        self.hint = hint
        hinted[id, default: 0] += 1
        persist()
    }

    // MARK: - what history suggests

    /// On launch, once a day, after a history import and after something
    /// is made. No work on each keystroke or ordinary visit. Only makers'
    /// documented addresses are candidates.
    func refresh(from history: History, now: Date = Date()) {
        refreshed = now
        let sites = Self.weighed.flatMap(\.sites)
        let places = history.places
        refreshTurn += 1
        // A small history is weighed at once (a new Mac, tests); a large
        // one off the main thread, where it took seconds at launch, after
        // an import and once a day (row 1165).
        guard places.count > History.cap else {
            return suggest(History.siteScores(places, sites: sites, now: now), now: now)
        }
        let turn = refreshTurn
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scores = History.siteScores(places, sites: sites, now: now)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshTurn == turn else { return }
                self.suggest(scores, now: now)
            }
        }
    }

    /// The makers whose sites history is weighed for, in the order their
    /// sites' scores come back.
    private static let weighed = [Maker.notion, Maker.docs] + Maker.offered.filter { $0.id != Maker.notion.id && $0.id != Maker.docs.id }
    /// The latest refresh: an older one's scores, arriving later, are dropped.
    private var refreshTurn = 0

    /// What the sites' scores suggest, `scores` in `weighed`'s sites' order.
    private func suggest(_ scores: [Double], now: Date) {
        var byMaker: [String: Double] = [:]
        var at = 0
        for maker in Self.weighed {
            byMaker[maker.id] = scores[at..<(at + maker.sites.count)].reduce(0, +)
            at += maker.sites.count
        }
        func used(_ maker: Maker) -> Double { byMaker[maker.id] ?? 0 }
        let notion = used(Maker.notion)
        let docs = used(Maker.docs)
        if !personalized.contains(QuickAction.document.id),
           let at = actions.firstIndex(where: { $0.id == QuickAction.document.id }) {
            // What was made says it best; visits only until enough is.
            let madeNotion = count(Maker.notion.id, now: now)
            let madeDocs = count(Maker.docs.id, now: now)
            let chosen: String = if madeNotion + madeDocs >= 3 {
                madeNotion > madeDocs ? Maker.notion.url : Maker.docs.url
            } else {
                notion >= 5 && notion >= docs * 2 ? Maker.notion.url : Maker.docs.url
            }
            if actions[at].url != chosen {
                actions[at].url = chosen
                persist()
            }
        }
        // A meeting joined says nothing of where you start one: only the
        // ones started count, and Meet stays unless Zoom clearly leads.
        if !personalized.contains(QuickAction.meeting.id),
           let at = actions.firstIndex(where: { $0.id == QuickAction.meeting.id }) {
            let zoom = count(Maker.zoom.id, now: now)
            let chosen = zoom >= 3 && zoom > count(Maker.meet.id, now: now) ? Maker.zoom.url : Maker.meet.url
            if actions[at].url != chosen {
                actions[at].url = chosen
                persist()
            }
        }
        var proposed: [QuickActionSuggestion] = []
        if let document = action(QuickAction.document.id), !personalized.contains(document.id) {
            if notion >= 5 && document.url != Maker.notion.url {
                proposed.append(.init(id: "use-notion", name: "Use Notion for New document", detail: "Suggested from your history", url: Maker.notion.url, alias: "", replacing: document.id))
            }
            if docs >= 5 && document.url != Maker.docs.url {
                proposed.append(.init(id: "use-google-docs", name: "Use Google Docs for New document", detail: "Suggested from your history", url: Maker.docs.url, alias: "", replacing: document.id))
            }
        }
        for maker in Maker.offered {
            guard let offer = maker.action, !actions.contains(where: { $0.id == offer.id || $0.url == maker.url }) else { continue }
            let lately = count(maker.id, days: 30, now: now)
            guard count(maker.id, now: now) >= 2 || used(maker) >= 5 else { continue }
            let detail = lately > 0 ? "\(maker.product) · you made \(lately) this month" : "\(maker.product) · from your history"
            proposed.append(.init(id: offer.id, name: offer.name, detail: detail, url: maker.url, alias: offer.alias))
        }
        let kept = proposed.filter { !dismissed.contains($0.id) }
        if suggestions != kept { suggestions = kept }
    }

    static func validURL(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }

    private func persist() {
        guard !ephemeral else { return }
        let saved = Saved(actions: actions, personalized: personalized, dismissed: dismissed, made: made, hinted: hinted)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }
}

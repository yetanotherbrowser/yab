import Foundation

/// A row under typed words: where Return goes, how it is drawn, and the word
/// the keyboard's key says for it.
struct WordRow: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        /// Switch to a tab already open.
        case tab(id: String)
        /// Open a site of Frequent (its tab in this space, if there is one).
        case site(key: String)
        case search
        /// One of Google's completions, searched as it reads.
        case searchFor(String)
        case open
        case ask
        case task
        /// Yab's own Settings.
        case settings
        /// Find on Page with the words: the page in front holds them.
        case findOnPage
        /// A page from History or a bookmark of the Mac's, opened as a site is.
        case place(url: String)
        /// One of Yab's menu actions (BrowserKey's token).
        case command(String)
    }

    /// What the row's icon is: a site's favicon, or one of the field's glyphs.
    enum Icon: Equatable, Sendable {
        case favicon(key: String, host: String?)
        case magnifier, sparkle, agent, globe, settings, clipboard, onPage
    }

    /// The keyboard's key, named after the row on top.
    enum Key: String, Sendable {
        case go, search, send
    }

    /// New Tab's groups, best group lowest.
    enum Group: String, Sendable {
        case tabs = "Tabs", sites = "Sites", web = "Web", claude = "Claude", yab = "Yab"
    }

    var action: Action
    var icon: Icon
    var title: String
    var subtitle: String
    var key: Key
    var group: Group

    /// Preserve scheme and port for history results instead of guessing HTTPS.
    var pageURL: URL? {
        if case let .place(url) = action { return URL(string: url) }
        return nil
    }

    var id: String {
        switch action {
        case let .tab(id): "tab:" + id
        case let .site(key): "site:" + key
        case .search: "search"
        case let .searchFor(phrase): "search:" + phrase
        case .open: "open"
        case .ask: "ask"
        case .task: "task"
        case .settings: "settings"
        case .findOnPage: "find"
        case let .place(url): "place:" + url
        case let .command(token): "command:" + token
        }
    }
}

/// Where the words were typed.
enum WordsPlace: Sendable, Equatable {
    /// The plate's field, about the page in front (⌘L): choosing replaces
    /// this tab.
    case page
    /// New Tab (⌘T): choosing opens a new tab.
    case newTab
    /// New Tab with the eyes shut: no history, only a search or an address.
    case privateTab
    /// The plate's field over a private tab: no history, no agent, only a
    /// search or an address, in this tab.
    case privatePage

    /// Choosing replaces the tab in front rather than opening one.
    var replacesTab: Bool { self == .page || self == .privatePage }
    /// No history, no chats, no agent: only where the words go.
    var isPrivate: Bool { self == .privateTab || self == .privatePage }
}

/// A tab the words may find.
struct TabCandidate: Equatable, Sendable {
    var id: String
    var title: String
    var site: String
    var icon: String
    var host: String?
    /// The folder it is in, if any: "in Onboarding v3".
    var folder: String?
    /// Its space's name.
    var space: String
    /// Its address, so a place in History open as this tab is the tab.
    var url: String? = nil
}

/// A site of Frequent the words may begin.
struct SiteCandidate: Equatable, Sendable {
    var key: String
    var name: String
    var host: String
}

extension Words {
    /// The rows for typed words, best first (drawn lowest, nearest the
    /// field): the prototype's fvRows and ftRows, with Settings and Private
    /// as the app adds them. At most four, Settings on top of them.
    /// Without `guesses` (Settings › Search › Guess from Your Words) a
    /// question or a task never leads: the search does, the agent's rows
    /// under it. `asks` and `tasks` say whether those rows are offered.
    static func rows(for typed: String, in place: WordsPlace, tabs: [TabCandidate] = [], sites: [SiteCandidate] = [],
                     places: [PlaceCandidate] = [], except: String? = nil, replaces: Bool = true, now: Date = Date(),
                     agent: String = "Claude", guesses: Bool = true, asks: Bool = true, tasks: Bool = true) -> [WordRow] {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let kind = read(text)
        let fromPage = place.replacesTab
        // Over a pin or a kept tab the page still opens as a new tab.
        let inThisTab = fromPage && replaces
        let search = WordRow(action: .search, icon: .magnifier, title: text,
                             subtitle: inThisTab ? "Search Google · in this tab" : "Search Google · new tab", key: .search, group: .web)
        let open = WordRow(action: .open, icon: .globe, title: text,
                           subtitle: inThisTab ? "Open in this tab" : "Open in a new tab", key: .go, group: .web)
        // Private keeps no history to offer and the agent reads none of it:
        // only where the words go.
        if place.isPrivate {
            return kind == .open ? [open, search] : [search]
        }
        let ask: WordRow? = !asks ? nil : WordRow(action: .ask, icon: .sparkle, title: text,
                          subtitle: fromPage ? "Ask \(agent) · about this page" : "Ask \(agent)", key: .go, group: .claude)
        let task: WordRow? = !tasks ? nil : WordRow(action: .task, icon: .agent, title: text,
                           subtitle: "Task for \(agent) · on your Mac" + (fromPage && pointsAtPage(text) ? ", with this page" : ""),
                           key: .send, group: .claude)
        let asked = ask.map { [$0] } ?? [], tasked = task.map { [$0] } ?? []
        let found = tabRows(text, tabs: tabs, except: except)
        var rows: [WordRow]
        switch kind {
        case .none: rows = []
        case .open: rows = [open, search]
        case .task where guesses && task != nil: rows = Array((tasked + found + asked + [search]).prefix(4))
        case .ask where guesses && ask != nil: rows = Array((asked + found + tasked + [search]).prefix(4))
        case .task, .ask: rows = Array(([search] + found + asked + tasked).prefix(4))
        case .search:
            let begun = fromPage ? [] : siteRows(text, sites: sites)
            // History and the Mac's bookmarks: a place whose address the
            // words begin before the search (Safari's top hit), a title's
            // match after Ask, two at most.
            let (strong, weak) = placeRows(text, places: places, tabs: tabs, shown: found + begun, sites: sites,
                                           except: except, now: now)
            rows = Array((found + begun + strong + [search] + asked + weak).prefix(4))
        }
        if wantsSettings(text) {
            rows.insert(WordRow(action: .settings, icon: .settings, title: "Settings", subtitle: "Yab on this \(DeviceWord.name)", key: .go, group: .yab), at: 0)
        }
        return rows
    }

    /// Open tabs whose title or site has the words in it: two letters or
    /// more, two tabs at most, never the tab in front.
    static func tabRows(_ text: String, tabs: [TabCandidate], except: String?) -> [WordRow] {
        let needle = text.lowercased()
        guard needle.count >= 2 else { return [] }
        return tabs.filter { $0.id != except && ($0.title + " " + $0.site).lowercased().contains(needle) }
            .prefix(2)
            .map { tab in
                let title = tab.title.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
                return WordRow(action: .tab(id: tab.id), icon: .favicon(key: tab.icon, host: tab.host), title: title,
                               subtitle: "\(tab.site) · \(tab.folder.map { "in " + $0 } ?? tab.space)", key: .go, group: .tabs)
            }
    }

    /// Places in History and the Mac's bookmarks for the words, best first,
    /// two at most: those whose address the words begin (strong) and the
    /// rest. A place open as a tab is that tab's row instead, unless the tab
    /// is already a row or is the one in front; the front page a site's row
    /// opens already is left out.
    static func placeRows(_ text: String, places: [PlaceCandidate], tabs: [TabCandidate], shown: [WordRow],
                          sites: [SiteCandidate], except: String?, now: Date) -> (strong: [WordRow], weak: [WordRow]) {
        guard !places.isEmpty else { return ([], []) }
        let open = Dictionary(tabs.compactMap { tab in tab.url.map { (HistoryList.key($0), tab) } }, uniquingKeysWith: { a, _ in a })
        let shownSites = Set(shown.compactMap { row -> String? in
            guard case let .site(key) = row.action, let site = sites.first(where: { $0.key == key }) else { return nil }
            return HistoryList.key(site.host.contains("://") ? site.host : "https://" + site.host)
        })
        var seen = Set(shown.map(\.id))
        var strong: [WordRow] = [], weak: [WordRow] = []
        for ranked in Places.ranked(text, places, now: now) where strong.count + weak.count < 2 {
            let place = ranked.place
            if shownSites.contains(place.key) { continue }
            let row: WordRow
            if let tab = open[place.key] {
                guard tab.id != except else { continue }
                let title = tab.title.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
                row = WordRow(action: .tab(id: tab.id), icon: .favicon(key: tab.icon, host: tab.host), title: title,
                              subtitle: "\(tab.site) · \(tab.folder.map { "in " + $0 } ?? tab.space)", key: .go, group: .tabs)
            } else {
                row = WordRow(action: .place(url: place.url), icon: .favicon(key: place.icon, host: place.host), title: place.name,
                              subtitle: "\(place.host) · \(place.bookmarked ? "Bookmark" : "History")", key: .go, group: .sites)
            }
            guard seen.insert(row.id).inserted else { continue }
            if ranked.strong { strong.append(row) } else { weak.append(row) }
        }
        return (strong, weak)
    }

    /// The site of Frequent the words begin, by name or host: one at most.
    static func siteRows(_ text: String, sites: [SiteCandidate]) -> [WordRow] {
        let needle = text.lowercased()
        guard needle.count >= 2 else { return [] }
        return sites.filter { $0.name.lowercased().hasPrefix(needle) || $0.host.hasPrefix(needle) }
            .prefix(1)
            .map { WordRow(action: .site(key: $0.key), icon: .favicon(key: $0.key, host: $0.host), title: $0.name,
                           subtitle: "\($0.host) · open in a new tab", key: .go, group: .sites) }
    }

    /// New Tab's groups in the order they stand, best group first (lowest):
    /// the groups in the order their first rows come, each group's rows best
    /// first.
    static func grouped(_ rows: [WordRow]) -> [WordGroup] {
        var out: [WordGroup] = []
        for (i, row) in rows.enumerated() {
            if let k = out.firstIndex(where: { $0.group == row.group }) {
                out[k].rows.append(IndexedRow(index: i, row: row))
            } else {
                out.append(WordGroup(group: row.group, rows: [IndexedRow(index: i, row: row)]))
            }
        }
        return out
    }
}

/// A row and where it stands among all the rows (0 is the best).
struct IndexedRow: Identifiable, Sendable {
    let index: Int
    let row: WordRow
    var id: String { row.id }
}

/// One of New Tab's groups of rows: TABS, SITES, WEB, CLAUDE, YAB.
struct WordGroup: Identifiable, Sendable {
    let group: WordRow.Group
    var rows: [IndexedRow]
    var id: String { group.rawValue }
}

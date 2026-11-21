import Combine
import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you would have typed to get here: no scheme, no www.
    let key: String
    let title: String
    /// Where it goes. Nil for what isn't a place: a thing to do, a page of
    /// settings.
    let url: URL?
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?
    /// The space whose row holds that tab, when it is not the one on screen.
    var space: UUID? = nil
    /// The ordinary destination paired with a remote tab's explicit jump.
    /// It belongs to the Space asking for it, even if the site has a rule.
    var opensHere = false
    /// Listed under Favorites in the empty field (FieldFavorites), whatever
    /// its kind.
    var favorite = false
    /// A contextual page action, including one kept under This Page.
    var pageRowID: String? = nil
    var pageHeading: String? = nil
    /// A place among your bookmarks, as the field offers them with the
    /// places you have been (History.keep(bookmarks:)).
    var bookmarked = false
    /// A row of Now handed to the agent: where its task stands ("On it"),
    /// so the row is drawn again when that changes (Omnibox).
    var handed: String? = nil
    /// A row of the empty field's Frequent, which shows its page's title as
    /// its key: the history's own key for that page, for Forget This Page.
    var frequent: String? = nil
    /// A page found in what you read (Diary), which shows its title as its
    /// key: when you were there, said at the row's end.
    var seen: Date? = nil
    /// A setting found on a page: preserve its row after the field is dismissed.
    var settingAnchor: String? = nil
    /// A site the search engine named for the words (Google's NAVIGATION
    /// result, SearchSuggestions): drawn as a known site, listed with the
    /// engine's words.
    var engine = false

    enum Kind: Equatable {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all, words, and an engine to ask.
        case search
        /// Words suggested by the chosen search engine.
        case suggested
        /// The address exactly as typed, somewhere not been before: the row
        /// that says Return goes there.
        case address
        /// Something the app does, found by its name.
        case command(Command)
        /// A page of settings, found by what is on it.
        case setting(SettingsPage)
        /// The words, a question for the agent, answered in the field
        /// (FieldAnswer) as ⌘J answers about a selection.
        case ask
        /// Words asked of the site the field is searching, before.
        case asked
        /// A sum the words make, worked out: the answer is the key.
        case sum
        /// One of the field's own places, Clipboard History or Emoji.
        case place(FieldPlace)
        /// Something copied, from the clipboard's history.
        case clip(UUID)
        /// A thing to do to the page ⌘L raised the field over.
        case page(String)
        /// What needs you now, found by an agent or left of getting started
        /// (see AgentHints), by its id.
        case hint(String)
        /// A named URL opened directly, rather than a site's Tab search.
        case quickAction(String)
        /// Words that read as a thing to do, for the agent to do in tabs of
        /// its own (AgentTask).
        case task
        /// A mail account by its address, "all" for every one: mail's
        /// space on it, as the column's chooser picks it (MailField).
        case mailAccount(String)
        /// Words that read as one thing to do somewhere known, with what
        /// is known of it beside the list (FieldRequest, Experimental): the
        /// window's requests by their place, best first.
        case request(Int)
        /// A site of Settings › Field's Fallback Commands searched for the
        /// words, by its id (Scope).
        case site(String)
        /// One of Yab's own places searched for the words (Settings ›
        /// Field's Fallback Commands): Mail, Files, History.
        case within(FieldPlace)
    }

    /// A place, as opposed to a thing to do: only these can finish what
    /// is being typed.
    var isPlace: Bool { kind == .visited || kind == .known }

    /// One of the rows under the words (Settings › Field's Under Your
    /// Words): the search, Ask, the task or a site searched.
    var isUnderWords: Bool {
        switch kind {
        case .search, .ask, .task, .site, .within: return true
        default: return false
        }
    }

    var id: String {
        switch kind {
        case .command(let command): return "do:" + command.rawValue
        case .setting(let page): return "set:" + page.rawValue
        // A destination and an explicit jump to its existing tab can share
        // an address and title. They remain separate keyboard selections.
        case .open: return tab.map { "tab:" + $0.uuidString } ?? key
        // One search row, whatever it is asking: its words change with every
        // key, and a row that is still the search should stay the same row.
        case .suggested: return "suggest:" + key
        case .search: return "ask"
        case .ask: return "question"
        case .sum: return "sum"
        case .place(let place): return "place:" + place.rawValue
        case .clip(let id): return "clip:" + id.uuidString
        case .page(let what): return "page:" + what
        case .hint(let id): return "hint:" + id
        case .quickAction(let id): return "quick:" + id
        case .task: return "task"
        case .request(let index): return "request:\(index)"
        case .mailAccount(let account): return "mail-account:" + account
        case .site(let id): return "site:" + id
        case .within(let place): return "within:" + place.rawValue
        default: return key
        }
    }
}

struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
    /// How many of those visits were asked for in the field, the address
    /// typed, or its row taken, rather than a link followed. A place you
    /// go to on purpose is what one letter means. Absent in files written
    /// before it was kept.
    var typed: Int?
    /// The visits made in each space, by its id, since these were kept; a
    /// visit brought in or from before has none (History.frequent).
    var spaces: [String: SpaceVisits]? = nil
}

/// A place's visits in one space.
struct SpaceVisits: Codable {
    var count: Int
    var last: Date
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    private static var profiles: [String: History] = [:]

    /// History belongs to a logical profile, as cookies and extensions do.
    /// The original file remains the original shared profile's history.
    static func profile(_ id: UUID) -> History {
        guard id != Space.firstID else { return shared }
        let file = Store.file("history-" + id.uuidString + ".json")
        if let kept = profiles[file.path] { return kept }
        let made = History(file: file)
        profiles[file.path] = made
        return made
    }

    static var current: History { BrowserWindows.shared.activeBrowser?.history ?? shared }
    static let anyIndexReady = PassthroughSubject<History, Never>()
    private static let writes = DispatchQueue(label: "yab.history", qos: .utility)
    /// Changed in place: an observer that read `oldValue` would copy the
    /// whole dictionary, tens of thousands of places brought in from
    /// another browser, on the main thread at every page load.
    private var visits: [String: Visit] = [:] {
        didSet {
            recentCache = nil
            // Something forgotten goes from Frequent at once; what is added
            // waits for tomorrow's list (frequent()).
            if visits.count < counted {
                frequentCache = nil
                spaceFrequent = [:]
                spaceKeys = nil
            }
            // Something forgotten leaves the field at once. Anything else,
            // a page loaded or a tab's title changing, keeps the last index
            // answering until the next is ready: dropping it emptied the
            // field's places for most of a second at every page load, and
            // the search took the top row.
            let shrank = visits.count < counted
            counted = visits.count
            objectWillChange.send()
            if shrank || visits.count <= History.cap { dropIndex() }
            indexed = false
            markSeen = nil
            entryMarked = []
            asked = nil
            indexGeneration += 1
            if visits.count > 500 { scheduleIndex() }
        }
    }
    /// The last few places, for the History menu, made once per change: the
    /// menu bar is laid out again on every change to the window, a key
    /// typed into the address field included, and sorting the whole history
    /// for it each time cost more than the rest of a key press.
    private var recentCache: [Trace]?
    /// How many places there were at the last change.
    private var counted = 0

    /// The newest few, for the History menu.
    func recent() -> [Trace] {
        if let recentCache { return recentCache }
        // One pass keeping the newest eight, not a sort of everything: a
        // history brought in from another browser is tens of thousands.
        var newest: [Visit] = []
        for visit in visits.values where visit.count > 0 && !(visit.title.isEmpty && !visit.key.contains("/")) {
            guard newest.count < 8 || visit.last > newest[newest.count - 1].last else { continue }
            let at = newest.firstIndex { visit.last > $0.last } ?? newest.count
            newest.insert(visit, at: at)
            if newest.count > 8 { newest.removeLast() }
        }
        let made = newest.compactMap { visit in
            URL(string: visit.url).map { Trace(key: visit.key, title: visit.title, url: $0, last: visit.last, count: visit.count) }
        }
        recentCache = made
        return made
    }
    /// The empty field's Frequent: the sites gone to most, often and
    /// lately, each by its page gone to most. Worked out once a day, so the
    /// rows keep their places while the hand learns them; again sooner only
    /// while there are too few, a history just brought in.
    private var frequentCache: (day: Date, visits: Int, list: [Trace])?
    /// The same for one space's own: its list and how many of its visits
    /// it was made from, which grow with no new place.
    private var spaceFrequent: [UUID: (day: Date, visits: Int, list: [Trace])] = [:]
    private var spaceCounted: [UUID: Int] = [:]
    /// The places each space has been to, gone through once and then kept
    /// up, so a space's list does not go through a whole history brought in
    /// from another browser every time it grows.
    private var spaceKeys: [UUID: Set<String>]?

    private func keys(in space: UUID) -> Set<String> {
        if let spaceKeys { return spaceKeys[space] ?? [] }
        var made: [UUID: Set<String>] = [:]
        for visit in visits.values {
            for id in (visit.spaces ?? [:]).keys {
                if let id = UUID(uuidString: id) { made[id, default: []].insert(visit.key) }
            }
        }
        spaceKeys = made
        return made[space] ?? []
    }

    /// Whether a site has been gone to in this space.
    func been(at url: URL, in space: UUID) -> Bool {
        guard url.host() != nil, let front = URL(string: "/", relativeTo: url)?.absoluteURL else { return false }
        return keys(in: space).contains(History.key(for: front))
    }

    /// A space's Frequent: as the whole history's, from the visits made in
    /// it, nothing brought in or from before spaces were counted.
    private func frequent(_ limit: Int, now: Date, in space: UUID) -> [Trace] {
        let day = Calendar.current.startOfDay(for: now)
        let counted = spaceCounted[space, default: 0]
        if let held = spaceFrequent[space], held.day == day, held.list.count >= 8 || held.visits == counted {
            return Array(held.list.prefix(limit))
        }
        var sites: [String: (score: Double, best: Visit, top: Double)] = [:]
        let id = space.uuidString
        for key in keys(in: space) {
            guard let visit = visits[key], let here = visit.spaces?[id], !visit.title.isEmpty, visit.url.hasPrefix("http") else { continue }
            let host = String(visit.key.prefix { $0 != "/" })
            guard !unfrequent.contains(host) else { continue }
            let score = History.frecency(Visit(url: visit.url, key: visit.key, title: visit.title, count: here.count, last: here.last), now: now)
            if var site = sites[host] {
                site.score += score
                if score > site.top { site.best = visit; site.top = score }
                sites[host] = site
            } else {
                sites[host] = (score, visit, score)
            }
        }
        let list = sites.values.filter { $0.score >= 1 }.sorted { $0.score > $1.score }.prefix(8).compactMap { site in
            URL(string: site.best.url).map { Trace(key: site.best.key, title: site.best.title, url: $0, last: site.best.last, count: site.best.count) }
        }
        spaceFrequent[space] = (day, counted, list)
        return Array(list.prefix(limit))
    }

    /// A site's key without its port: `localhost` for `localhost:3000`,
    /// `[fd00::1]` for `[fd00::1]:3000`.
    nonisolated static func bareHost(_ key: String) -> String {
        if key.hasPrefix("["), let end = key.firstIndex(of: "]") { return String(key[...end]) }
        return String(key.prefix { $0 != ":" && $0 != "/" })
    }

    /// Two places' visits in each space, added up.
    nonisolated private static func joined(_ a: [String: SpaceVisits]?, _ b: [String: SpaceVisits]?) -> [String: SpaceVisits]? {
        guard let b, !b.isEmpty else { return a }
        var all = a ?? [:]
        for (id, here) in b {
            let was = all[id]
            all[id] = SpaceVisits(count: (was?.count ?? 0) + here.count, last: max(was?.last ?? .distantPast, here.last))
        }
        return all
    }

    func frequent(_ limit: Int, now: Date = Date(), space: UUID? = nil) -> [Trace] {
        if let space { return frequent(limit, now: now, in: space) }
        let day = Calendar.current.startOfDay(for: now)
        if let held = frequentCache, held.day == day, held.list.count >= 8 || held.visits == visits.count {
            return Array(held.list.prefix(limit))
        }
        // A site by all its pages together, not by its best one: a mail
        // box read at a hundred addresses is one habit.
        var sites: [String: (score: Double, best: Visit, top: Double)] = [:]
        for visit in visits.values where visit.count > 0 && !visit.title.isEmpty && visit.url.hasPrefix("http") {
            let host = String(visit.key.prefix { $0 != "/" })
            guard !unfrequent.contains(host) else { continue }
            let score = History.frecency(visit, now: now)
            if var site = sites[host] {
                site.score += score
                if score > site.top { site.best = visit; site.top = score }
                sites[host] = site
            } else {
                sites[host] = (score, visit, score)
            }
        }
        let list = sites.values.filter { $0.score >= 1 }.sorted { $0.score > $1.score }.prefix(8).compactMap { site in
            URL(string: site.best.url).map { Trace(key: site.best.key, title: site.best.title, url: $0, last: site.best.last, count: site.best.count) }
        }
        frequentCache = (day, visits.count, list)
        return Array(list.prefix(limit))
    }

    /// Every place as the field matches it, made once for each change to
    /// the history and not on every keystroke: a history taken from
    /// another browser runs to tens of thousands.
    private var entries: [Entry] = []
    private var indexTime = Date.distantPast
    private var indexed = false
    private var hostGroups: [String: [Int]] = [:]
    /// The same groups in a list, each with the letters of its host
    /// (`letters`): words holding a letter a host lacks can't match it, and
    /// a list is walked without a dictionary's cost for each of tens of
    /// thousands of sites.
    private var hostList: [(letters: UInt64, members: [Int])] = []
    /// Addresses in lexical order, and each entry's position in that list.
    /// A path prefix finds its range by binary search; a missing path must
    /// not walk every page at a busy site on every subsequent key.
    private var addressOrder: [Int] = []
    private var addressPosition: [Int] = []
    private var titlePrefixes: [String: TitlePostings] = [:]
    private var indexGeneration = 0
    private var indexWork: DispatchWorkItem?
    let indexReady = PassthroughSubject<Void, Never>()
    /// No index to answer from yet, the first after launch or after a
    /// place was forgotten: Return waits for it. A rebuild after a visit
    /// answers from the last one meanwhile.
    var isIndexing: Bool { !indexed && visits.count > History.cap && !hasIndex }
    /// Whether `entries` hold an index, if an older one.
    private var hasIndex = false

    private func dropIndex() {
        entries.removeAll(keepingCapacity: true)
        hostGroups.removeAll(keepingCapacity: true)
        hostList.removeAll(keepingCapacity: true)
        addressOrder.removeAll(keepingCapacity: true)
        addressPosition.removeAll(keepingCapacity: true)
        titlePrefixes.removeAll(keepingCapacity: true)
        hasIndex = false
    }
    /// The last answer, for the same words asked again: the field asks
    /// twice for one key, for its list and for whether a clip is a place.
    private var asked: (needle: String, limit: Int, at: Date, offers: [Suggestion])?

    /// Your bookmarks, as the field offers them among places, by key: one
    /// you have been to is its visits and two more, as the iPhone's field
    /// counts one (Places.frecency); one you never went to is matched on
    /// its own (`marks`), its standing those two visits alone.
    private var marked: Set<String> = []
    private var marks: [Entry] = []
    private var markRevision: Int?
    /// Each bookmark's place in `entries`, -1 for one never been to: found
    /// once a change to either, not once a key.
    private var markSeen: [Int]?
    /// The letters in each bookmark's host and title (`History.letters`),
    /// the title the page's own once been to: one without every letter
    /// typed is passed over before it is matched.
    private var markHosts: [UInt64] = []
    private var markTitles: [UInt64] = []
    /// Whether each of `entries` is a bookmark, by where it is: read for
    /// every place matched, where hashing its key each time doubled a key.
    private var entryMarked: [Bool] = []

    private func markPlaces() -> [Int] {
        var at: [String: Int] = [:]
        entryMarked = []
        if !marked.isEmpty {
            entryMarked = [Bool](repeating: false, count: entries.count)
            for (place, entry) in entries.enumerated() where marked.contains(entry.visit.key) {
                at[entry.visit.key] = place
                entryMarked[place] = true
            }
        }
        let seen = marks.map { at[$0.visit.key] ?? -1 }
        markSeen = seen
        markHosts = marks.map { History.letters($0.host) }
        markTitles = marks.indices.map { History.letters(seen[$0] >= 0 ? entries[seen[$0]].title : marks[$0].title) }
        return seen
    }
    /// What a bookmark counts for, in visits.
    static let markWeight = 2.0
    /// Where `found` keeps a bookmark not been to: below every known site.
    private static let markBase = -1_000_000

    /// The bookmarks the field offers, read again only when they changed:
    /// the tree is walked once a change, not once a key.
    func keep(bookmarks nodes: [Bookmark], revision: Int) {
        guard revision != markRevision else { return }
        markRevision = revision
        var keys = Set<String>()
        var places: [Visit] = []
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if node.isFolder { walk(node.children ?? []); continue }
                guard let text = node.url, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                let key = History.key(for: url)
                guard !key.isEmpty, keys.insert(key).inserted else { continue }
                places.append(Visit(url: text, key: key, title: node.title, count: 0, last: .distantPast))
            }
        }
        walk(nodes)
        guard keys != marked || places.map(\.title) != marks.map(\.visit.title) else { return }
        marked = keys
        marks = places.map { Entry($0) }
        markSeen = nil
        asked = nil
    }

    private struct Entry {
        let visit: Visit
        /// The key up to its first slash, what follows the host's first
        /// dot, and whether it is a room inside a site.
        let host: String
        let tail: Substring?
        let room: Bool
        /// Whether the host is plain ASCII, as nearly every one is, so it
        /// can be looked through by its bytes.
        let ascii: Bool
        /// The whole key, path and all: its start is then compared by bytes.
        let asciiKey: Bool
        /// Normalized once while building the index, outside key handling.
        let title: String
        let asciiTitle: Bool
        let sortScore: Double

        init(_ visit: Visit, now: Date = Date()) {
            self.visit = visit
            let host = visit.key.split(separator: "/").first.map(String.init) ?? visit.key
            self.host = host
            tail = host.range(of: ".").map { host[$0.upperBound...] }
            room = visit.key.contains("/")
            ascii = host.utf8.allSatisfy { $0 < 0x80 }
            asciiKey = ascii && visit.key.utf8.allSatisfy { $0 < 0x80 }
            title = " " + Wording.split(visit.title.lowercased()).joined(separator: " ")
            asciiTitle = title.utf8.allSatisfy { $0 < 0x80 }
            sortScore = History.frecency(visit, now: now)
        }
    }

    private struct SearchIndex {
        let time: Date
        let entries: [Entry]
        let hosts: [String: [Int]]
        let hostList: [(letters: UInt64, members: [Int])]
        let addressOrder: [Int]
        let addressPosition: [Int]
        let titles: [String: TitlePostings]
    }

    private struct TitlePostings {
        var roots: [Int] = []
        var rooms: [Int] = []
        var count: Int { roots.count + rooms.count }
        mutating func append(_ at: Int, room: Bool) {
            if room { rooms.append(at) } else { roots.append(at) }
        }
    }

    private nonisolated static func makeIndex(_ visits: [Visit]) -> SearchIndex {
        let now = Date()
        var entries = visits.map { Entry($0, now: now) }
        entries.sort { $0.sortScore > $1.sortScore }
        var hosts: [String: [Int]] = [:]
        var titles: [String: TitlePostings] = [:]
        for (at, entry) in entries.enumerated() {
            hosts[entry.host, default: []].append(at)
            var prefixes = Set<String>()
            for word in entry.title.split(separator: " ") {
                for size in 1...min(3, word.count) {
                    prefixes.insert(String(word.prefix(size)))
                }
            }
            for prefix in prefixes { titles[prefix, default: TitlePostings()].append(at, room: entry.room) }
        }
        let hostList = hosts.map { (letters: History.letters($0.key), members: $0.value) }
        let addressOrder = entries.indices.sorted { entries[$0].visit.key < entries[$1].visit.key }
        var addressPosition = [Int](repeating: 0, count: entries.count)
        for (position, at) in addressOrder.enumerated() { addressPosition[at] = position }
        return SearchIndex(time: now, entries: entries, hosts: hosts, hostList: hostList,
                           addressOrder: addressOrder, addressPosition: addressPosition, titles: titles)
    }

    private func apply(_ index: SearchIndex) {
        indexTime = index.time
        entries = index.entries
        hostGroups = index.hosts
        hostList = index.hostList
        addressOrder = index.addressOrder
        addressPosition = index.addressPosition
        titlePrefixes = index.titles
        indexed = true
        hasIndex = true
        markSeen = nil
        asked = nil
    }

    /// The index made again a moment after the last change, off the main
    /// thread. The places are taken then, not at each change: a page load
    /// changes two, and listing tens of thousands of them for each was the
    /// main thread's work. Taking them is a reference to the dictionary;
    /// the list is made where the index is.
    private func scheduleIndex() {
        indexWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let generation = indexGeneration
            let snapshot = visits
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let index = MainBudget.chunk("history.index.build") { History.makeIndex(Array(snapshot.values)) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.indexGeneration == generation else { return }
                    MainBudget.chunk("history.index.apply") { self.apply(index) }
                    self.indexReady.send(())
                    Self.anyIndexReady.send(self)
                }
            }
        }
        indexWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// What is typed, as matching needs it, worked out once for all the
    /// places rather than once for each.
    private struct Needle {
        let text: String
        /// Plain ASCII, its bytes, or nil.
        let bytes: [UInt8]?
        /// Two letters or more: enough to match inside a host.
        let inside: Bool
        /// Each word, a space before it, to begin a word of a title.
        let words: [String]
        let wordBytes: [[UInt8]]?

        init(_ text: String) {
            self.text = text
            bytes = text.utf8.allSatisfy { $0 < 0x80 } ? Array(text.utf8) : nil
            let count = text.count
            inside = count >= 2
            // Titles are normalized by Wording.split: only letters, numbers
            // and spaces survive. An address or a punctuated word cannot
            // match them. Looking through a common title prefix anyway
            // walked thousands of pages for every key in a missing path.
            let canTitle = count >= 3 && text.allSatisfy { $0.isLetter || $0.isNumber || $0.isWhitespace }
            words = canTitle ? text.split(whereSeparator: \.isWhitespace).map { " " + $0 } : []
            wordBytes = bytes == nil ? nil : words.map { Array($0.utf8) }
        }
    }

    /// Whether the text holds the bytes, both plain ASCII: the same answer
    /// as `contains`, for a fraction of what it costs.
    private static func holds(_ text: String, _ part: [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { hay in
            guard hay.count >= part.count else { return false }
            return part.withUnsafeBytes { bytes in
                memmem(hay.baseAddress, hay.count, bytes.baseAddress, part.count) != nil
            }
        }
    }
    /// The write a change has scheduled and not yet made, so a flush can
    /// take its place rather than let it land later over newer rows.
    private var pendingSave: DispatchWorkItem?
    private let storage: URL?

    convenience init() { self.init(file: History.file) }

    init(file: URL) {
        storage = file
        load()
        if pendingPortKeys {
            pendingPortKeys = false
            save()
            // A site kept out of Frequent before a port was part of a place
            // was every server on its host: each keeps out now by its own
            // row. One kept out from now on is only that server.
            let spread = History.hiddenPorts(unfrequent, sites: visits.keys)
            if spread != unfrequent {
                unfrequent = spread
                if storage == History.file { Store.settings.set(unfrequent.sorted(), forKey: History.unfrequentKey) }
            }
        }
        counted = visits.count
        if visits.count > 500 { scheduleIndex() }
    }

    /// These places and no file, for tests.
    init(_ list: [Visit]) {
        storage = nil
        visits = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        counted = visits.count
        apply(History.makeIndex(Array(visits.values)))
    }

    // MARK: - writing

    /// A step of a sign-in no one goes back to, which says who signs in or
    /// carries a one-time code: a sign-in page with `login_hint`, an OAuth
    /// request (`client_id` and `redirect_uri`), the redirect bringing its
    /// `code` and `state`. Never in history, so never in sync: mail's own
    /// sign-in would carry the Gmail address there (docs/casa.md).
    static func signInStep(_ url: URL) -> Bool {
        let names = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased() })
        return names.contains("login_hint") || names.isSuperset(of: ["client_id", "redirect_uri"]) || names.isSuperset(of: ["code", "state"])
    }

    func record(_ url: URL, title: String, space: UUID? = nil) {
        MainBudget.chunk("history.record") { recordNow(url, title: title, space: space) }
    }

    private func recordNow(_ url: URL, title: String, space: UUID?) {
        guard url.scheme == "http" || url.scheme == "https", !History.signInStep(url) else { return }
        // A habit's place opened now is no habit for the rest of today.
        Noticing.shared.opened(url)
        let key = History.key(for: url)
        guard !key.isEmpty else { return }

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page,
        // and nobody types a domain meaning to land halfway down it.
        if url.host() != nil, key.contains("/") {
            let front = URL(string: "/", relativeTo: url)!.absoluteURL
            let root = History.key(for: front)
            var home = visits[root] ?? Visit(
                url: front.absoluteString, key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            History.count(&home, in: space)
            visits[root] = home
            noteSpace(space, root)
        }

        if var seen = visits[key] {
            seen.count += 1
            seen.last = Date()
            seen.url = url.absoluteString
            if !title.isEmpty { seen.title = title }
            History.count(&seen, in: space)
            visits[key] = seen
        } else {
            var fresh = Visit(
                url: url.absoluteString,
                key: key,
                title: title,
                count: 1,
                last: Date()
            )
            History.count(&fresh, in: space)
            visits[key] = fresh
        }
        noteSpace(space, key)
        save()
    }

    /// One more visit to this place, in this space.
    private static func count(_ visit: inout Visit, in space: UUID?) {
        guard let space else { return }
        let id = space.uuidString
        var spaces = visit.spaces ?? [:]
        spaces[id] = SpaceVisits(count: (spaces[id]?.count ?? 0) + 1, last: Date())
        visit.spaces = spaces
    }

    private func noteSpace(_ space: UUID?, _ key: String) {
        guard let space else { return }
        spaceKeys?[space, default: []].insert(key)
        spaceCounted[space, default: 0] += 1
    }

    /// A visit counted before its page had a title (Browser.noticeCommit):
    /// the title it has now.
    func retitle(_ url: URL, title: String) {
        let key = History.key(for: url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    /// Somewhere asked for in the field. The visit itself is counted when
    /// the page lands; this only says it was meant.
    func typedIn(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = History.key(for: url)
        guard !key.isEmpty else { return }
        var seen = visits[key] ?? Visit(url: url.absoluteString, key: key, title: "", count: 0, last: Date())
        seen.typed = (seen.typed ?? 0) + 1
        visits[key] = seen
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once, the day
    /// you switch, the field already knows you.
    func take(_ url: URL, title: String, count: Int, typed: Int = 0, last: Date) {
        History.merge(url, title: title, count: count, typed: typed, last: last, into: &visits)
    }

    nonisolated private static func merge(_ url: URL, title: String, count: Int, typed: Int, last: Date, into visits: inout [String: Visit]) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = History.key(for: url)
        guard !key.isEmpty else { return }
        if var seen = visits[key] {
            seen.count += count
            if typed > 0 { seen.typed = (seen.typed ?? 0) + typed }
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(
                url: url.absoluteString, key: key, title: title, count: count, last: last,
                typed: typed > 0 ? typed : nil
            )
        }
    }

    /// Another browser's places, keyed and folded together, ready to go in.
    struct Gathered {
        let visits: [String: Visit]
        var count: Int { visits.count }

        /// As the history page lists them, for the diary.
        var traces: [Trace] {
            visits.values.compactMap { visit in
                URL(string: visit.url).map { Trace(key: visit.key, title: visit.title, url: $0, last: visit.last, count: visit.count) }
            }
        }
    }

    /// The slow half of taking a whole other browser's history: thousands
    /// of addresses tidied into keys. Done off the main thread, so all that
    /// is left for it is one pass over a dictionary.
    nonisolated static func gather(_ places: [Chromium.Place]) -> Gathered {
        var visits: [String: Visit] = [:]
        for place in places { merge(place.url, title: place.title, count: place.count, typed: place.typed, last: place.last, into: &visits) }
        return Gathered(visits: visits)
    }

    /// The quick half. Merged into a copy and put back in one go, so the
    /// thousands of places are one change, not thousands.
    func take(_ gathered: Gathered) {
        var merged = visits
        History.take(gathered, into: &merged)
        visits = merged
        save()
        QuickActions.shared.refresh(from: self)
    }

    /// Another browser's counts are its whole count, so taking it again
    /// doesn't add them twice: a place known here keeps the larger of the
    /// two, the visits made here or the ones made there, and its latest.
    nonisolated static func take(_ gathered: Gathered, into visits: inout [String: Visit]) {
        for (key, place) in gathered.visits {
            if var seen = visits[key] {
                seen.count = max(seen.count, place.count)
                if let typed = place.typed { seen.typed = max(seen.typed ?? 0, typed) }
                if place.last > seen.last { seen.last = place.last }
                if seen.title.isEmpty { seen.title = place.title }
                visits[key] = seen
            } else {
                visits[key] = place
            }
        }
    }

    /// Places from a file someone exported, Safari's history, say. They only
    /// add to what is here: a place already known keeps its own count and
    /// title, and is only told of a later visit. A new one comes with at
    /// most `fileCount` visits, so a file can't outrank the places you go
    /// to yourself. Returns how many places were new.
    @discardableResult
    func add(_ gathered: Gathered) -> Int {
        var merged = visits
        let added = History.add(gathered, to: &merged)
        visits = merged
        save()
        QuickActions.shared.refresh(from: self)
        return added
    }

    /// Whether the person has been to this site (its registrable domain)
    /// before: a chat that read mail asks before going anywhere else
    /// (Bench.mailLeaves).
    func knows(site: String) -> Bool {
        visits.values.contains { visit in
            URL(string: visit.url)?.host().map { Vault.registrable($0.lowercased()) == site } ?? false
        }
    }

    /// A bounded, local signal for choosing documented Quick Action URLs.
    /// A path can distinguish Docs from Sheets and Slides on the same host.
    func siteScore(for host: String, path: String? = nil, now: Date = Date()) -> Double {
        History.siteScores(visits, sites: [(host, path)], now: now)[0]
    }

    /// Every place, as it is now: a reference, not a copy, until the next
    /// change. For work done with all of them off the main thread.
    var places: [String: Visit] { visits }

    /// Each site's score as `siteScore` gives it, all of them in one walk
    /// of the places. Quick Actions weigh a dozen sites: a walk per site
    /// parsed every address a dozen times, on the main thread, at launch
    /// and after an import (1.9 s for 300,000 places, row 1165). Only an
    /// address whose host is roughly one of theirs is parsed at all.
    nonisolated static func siteScores(_ visits: [String: Visit], sites: [(host: String, path: String?)], now: Date) -> [Double] {
        var scores = [Double](repeating: 0, count: sites.count)
        var wanted: [String: [Int]] = [:]
        for (index, site) in sites.enumerated() {
            wanted[site.host, default: []].append(index)
            wanted["www." + site.host, default: []].append(index)
        }
        guard !wanted.isEmpty else { return scores }
        for visit in visits.values {
            guard let rough = roughHost(visit.url), wanted[rough] != nil,
                  let url = URL(string: visit.url), let found = url.host()?.lowercased(),
                  let indices = wanted[found] else { continue }
            let path = url.path()
            let score = frecency(visit, now: now)
            for index in indices where sites[index].path.map({ path.hasPrefix($0) }) ?? true {
                scores[index] += score
            }
        }
        return scores
    }

    /// The host of an address as its letters stand, lowercased, without
    /// parsing it: between "://" (and any "user@") and the first of / ? # :.
    nonisolated static func roughHost(_ address: String) -> String? {
        guard let start = address.range(of: "://") else { return nil }
        var host = address[start.upperBound...]
        if let end = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { host = host[..<end] }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        return host.isEmpty ? nil : host.lowercased()
    }

    /// As many visits as a place from a file is taken to have, at most.
    nonisolated static let fileCount = 10

    nonisolated static func add(_ gathered: Gathered, to visits: inout [String: Visit]) -> Int {
        var added = 0
        for (key, place) in gathered.visits {
            if var seen = visits[key] {
                if place.last > seen.last { seen.last = place.last }
                if seen.title.isEmpty { seen.title = place.title }
                visits[key] = seen
            } else {
                var place = place
                place.count = min(place.count, fileCount)
                place.typed = nil
                visits[key] = place
                added += 1
            }
        }
        return added
    }

    /// A page's title usually lands a beat after the page does.
    /// What a page was called when last here, if it was.
    /// What the page was called when last here. The key leaves the query
    /// off, so every Google search is one row: its title is the last
    /// search's, and a new search opened in a tab read "cmux next - Google
    /// Search" while "cmux" loaded. A query that differs has no known name.
    func title(of url: URL) -> String? {
        guard let seen = visits[History.key(for: url)], !seen.title.isEmpty else { return nil }
        guard (url.query() ?? "") == (URL(string: seen.url)?.query() ?? "") else { return nil }
        return seen.title
    }

    func retitle(_ url: URL, _ title: String) {
        let key = History.key(for: url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        save()
        // The icons pages wore name the pages: they go with the visits, as
        // Chrome's favicons go with its history (Favicons.pageIcon).
        Favicons.shared.forgetPages()
    }

    /// In-memory visits for the omnibox performance bench. One assignment
    /// invalidates the search index once, even with thousands of pages.
    func seedBench(_ count: Int) {
        var seeded = visits.filter { !$0.key.hasPrefix("omnibox-bench.invalid/") }
        let now = Date()
        for index in 0..<max(0, min(count, 20_000)) {
            let key = "omnibox-bench.invalid/page-\(index)"
            seeded[key] = Visit(url: "https://\(key)", key: key,
                                title: "Omnibox bench page \(index)", count: 2,
                                last: now.addingTimeInterval(-Double(index)), typed: nil)
        }
        visits = seeded
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        let title: String
        let url: URL
        let last: Date
        let count: Int

        var id: String { key }
    }

    /// The pages last been to on these sites (a host or any of its own,
    /// "en.wikipedia.org" for "wikipedia.org"), newest first: what a site's
    /// search lists before anything is asked of it, as Arc's does. One pass,
    /// keeping the newest few, not a sort of everything.
    func pages(on hosts: [String], limit: Int) -> [Trace] {
        let hosts = hosts.map { $0.lowercased() }
        var newest: [Visit] = []
        for visit in visits.values where visit.count > 0 && !visit.title.isEmpty && visit.key.contains("/") {
            guard newest.count < limit || visit.last > newest[newest.count - 1].last,
                  let host = URL(string: visit.url)?.host()?.lowercased(),
                  hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
            let at = newest.firstIndex { visit.last > $0.last } ?? newest.count
            newest.insert(visit, at: at)
            if newest.count > limit { newest.removeLast() }
        }
        return newest.compactMap { visit in
            URL(string: visit.url).map { Trace(key: visit.key, title: visit.title, url: $0, last: visit.last, count: visit.count) }
        }
    }

    func everything(matching typed: String = "") -> [Trace] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return visits.values
            // Every visit to a page also credits its domain, so the address
            // field can offer the front door. Those credits have no title of
            // their own, and in a list of where you have been they are a second
            // copy of every line.
            .filter { !($0.title.isEmpty && !$0.key.contains("/")) }
            // Typed and never landed, a redirect went somewhere else.
            .filter { $0.count > 0 }
            .filter {
                needle.isEmpty
                    || $0.key.contains(needle)
                    || $0.title.lowercased().contains(needle)
            }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        title: visit.title,
                        url: $0,
                        last: visit.last,
                        count: visit.count
                    )
                }
            }
    }

    /// The places last been to since a moment, for sync (SyncShapes.visits).
    func visits(since: Date) -> [Visit] {
        visits.values.filter { $0.last >= since && $0.count > 0 }
    }

    /// Places another device has been, from sync: one new here counts as a
    /// visit, one known here keeps its count and takes the newer title.
    /// Being typed on another device is also intentional here. Nothing is
    /// ever taken away by sync.
    func adoptSynced(_ synced: [(url: URL, title: String, last: Date, typed: Bool)]) {
        var all = visits
        var changed = false
        for place in synced {
            let key = History.key(for: place.url)
            guard !key.isEmpty, place.url.scheme == "http" || place.url.scheme == "https" else { continue }
            if var seen = all[key] {
                let newer = place.last > seen.last
                let takeTitle = !place.title.isEmpty && (newer || seen.title.isEmpty) && place.title != seen.title
                let takeTyped = place.typed && (seen.typed ?? 0) < 1
                guard newer || takeTitle || takeTyped else { continue }
                seen.last = max(seen.last, place.last)
                if takeTitle { seen.title = place.title }
                if takeTyped { seen.typed = 1 }
                all[key] = seen
            } else {
                History.merge(place.url, title: place.title, count: 1, typed: place.typed ? 1 : 0, last: place.last, into: &all)
            }
            changed = true
        }
        guard changed else { return }
        visits = all
        save()
    }

    /// Places another device deleted from its history, by key and when:
    /// gone here too, or this Mac would send them back with its next flush.
    /// Kept where this Mac has been there since. Returns the addresses that
    /// went, for the diary.
    @discardableResult
    func dropSynced(_ cut: [(key: String, at: Date)]) -> [URL] {
        var all = visits
        var gone: [URL] = []
        for place in cut {
            guard let seen = all[place.key], seen.last <= place.at.addingTimeInterval(1) else { continue }
            all[place.key] = nil
            if let url = URL(string: seen.url) { gone.append(url) }
        }
        guard !gone.isEmpty else { return [] }
        visits = all
        save()
        return gone
    }

    /// Places deleted here by hand, and when, until sync has told the other
    /// devices (SyncShapes.cut). A place that leaves the two weeks, or the
    /// whole history cleared on this Mac, is not among them: those stay on
    /// the other devices.
    private(set) var cuts: [String: Date] = [:]

    /// The deletions sync has yet to tell, handed over once.
    func takeCuts() -> [String: Date] {
        defer { cuts = [:] }
        return cuts
    }

    /// Every place last been to since a moment.
    func forget(since: Date) {
        visits = visits.filter { $0.value.last < since }
        save()
        // Which pages were worn since is not written down: all of them.
        Favicons.shared.forgetPages()
    }

    /// Whether a place is in the history, not only among the bookmarks.
    func remembers(_ key: String) -> Bool { visits[key] != nil }

    func forget(_ key: String) {
        if visits[key] != nil { cuts[key] = Date() }
        visits[key] = nil
        save()
    }

    /// Several places forgotten at once, handed back for ⌘Z (`putBack`).
    func take(_ keys: [String]) -> [String: Visit] {
        var gone: [String: Visit] = [:]
        for key in keys { if let visit = visits[key] { gone[key] = visit } }
        guard !gone.isEmpty else { return [:] }
        let now = Date()
        for key in gone.keys { cuts[key] = now }
        visits = visits.filter { gone[$0.key] == nil }
        save()
        return gone
    }

    /// What `take` forgot, where nothing has come since in its place.
    func putBack(_ gone: [String: Visit]) {
        guard !gone.isEmpty else { return }
        var all = visits
        for (key, visit) in gone where all[key] == nil {
            all[key] = visit
            cuts[key] = nil
        }
        visits = all
        save()
    }

    /// The history's key for a page: what you would have typed to get there,
    /// the port too when it isn't the scheme's own. localhost:3000 and
    /// localhost:4000 are two servers, two places, as Arc lists them; the
    /// key had no port, so all of localhost was one row going to whichever
    /// server made it first. The same as sync's key (SyncVisit.key).
    nonisolated static func key(for url: URL) -> String {
        Address.pretty(url, port: ownPort(url) != nil).lowercased()
    }

    /// The port an address names that isn't its scheme's own: 3000 for
    /// localhost:3000, nil for https://example.com:443.
    nonisolated static func ownPort(_ url: URL) -> Int? {
        guard let port = url.port else { return nil }
        switch url.scheme?.lowercased() {
        case "http": return port == 80 ? nil : port
        case "https": return port == 443 ? nil : port
        default: return port
        }
    }

    /// Sites forgotten from the empty field's Frequent. A site there stands
    /// for all its pages, so forgetting the page it showed would only bring
    /// up the next one; it stays out, as a tile removed from Chrome's Most
    /// Visited does, and is still found by typing.
    /// The sites kept out of Frequent with, for each host kept out without
    /// a port, its servers on other ports: by every place's site, as
    /// Frequent groups them, since a server's pages can be kept without a
    /// row of its own.
    nonisolated static func hiddenPorts(_ hidden: Set<String>, sites keys: some Sequence<String>) -> Set<String> {
        guard !hidden.isEmpty else { return hidden }
        var all = hidden
        for key in keys {
            let site = String(key.prefix { $0 != "/" })
            if hidden.contains(History.bareHost(site)) { all.insert(site) }
        }
        return all
    }

    private(set) lazy var unfrequent: Set<String> = Set(storage == History.file ? Store.settings.stringArray(forKey: History.unfrequentKey) ?? [] : [])
    private static let unfrequentKey = "history.unfrequent"

    /// A Frequent row's page forgotten and its site kept out of Frequent.
    func forgetFrequent(_ key: String) {
        unfrequent.insert(String(key.prefix { $0 != "/" }))
        if storage == History.file { Store.settings.set(unfrequent.sorted(), forKey: History.unfrequentKey) }
        frequentCache = nil
        spaceFrequent = [:]
        if visits[key] != nil { forget(key) } else { objectWillChange.send() }
    }

    // MARK: - reading

    /// Best matches first. A place you have been always beats a place the app
    /// merely knows the name of, and among places you have been, one you go to
    /// often and recently beats one you saw once in March.
    func suggestions(for typed: String, limit: Int = 5, now: Date = Date()) -> [Suggestion] {
        MainBudget.chunk("history.suggest") { suggestionsNow(for: typed, limit: limit, now: now) }
    }

    private func suggestionsNow(for typed: String, limit: Int, now: Date) -> [Suggestion] {
        let needle = strip(typed)
        // An empty field proposes nothing. A list of guesses in front of
        // someone who has not yet said what they want is noise, and it is in
        // the way of the one thing they came here to do.
        guard !needle.isEmpty else { return [] }
        if let asked, asked.needle == needle, asked.limit == limit, abs(asked.at.timeIntervalSince(now)) < 1 {
            return asked.offers
        }
        if !indexed {
            if visits.count > History.cap {
                if indexWork == nil { scheduleIndex() }
                // The last index answers while the next is made.
                if !hasIndex { return [] }
            } else {
                apply(History.makeIndex(Array(visits.values)))
            }
        }

        let asked = Needle(needle)
        // What matched and how well: a place by where it is in `entries`,
        // one the field knows from the start by -1 - where it is in `known`.
        var found: [(score: Double, at: Int)] = []
        var bestScores: [Double] = []
        func add(_ score: Double, _ at: Int) {
            found.append((score, at))
            if limit > 0 {
                let position = bestScores.firstIndex { score > $0 } ?? bestScores.count
                if position < limit {
                    // A broken stored address cannot set the cutoff and
                    // hide usable rows below it. Validate only candidates
                    // entering the best few, not every place on each key.
                    if at >= 0, URL(string: entries[at].visit.url) == nil { return }
                    bestScores.insert(score, at: position)
                    if bestScores.count > limit { bestScores.removeLast() }
                }
            }
        }
        let seen = markSeen ?? markPlaces()
        // Groups are ordered by their score at indexTime. This is an upper
        // bound at `now`, including visits dated in the future and callers
        // asking about an earlier day. Once even a bookmark at this score
        // cannot enter the list, neither can anything later in the group.
        let scoreScale = exp(max(0, indexTime.timeIntervalSince(now)) / (86_400 * 30))
        func ruledOut(_ at: Int, rank: Double) -> Bool {
            guard limit > 0, bestScores.count == limit, let fifth = bestScores.last else { return false }
            return rank + 4 + entries[at].sortScore * scoreScale + History.markWeight + 1.5 < fifth
        }
        // Every page at a host has the same host match for an ordinary word.
        // Imported histories often have thousands of pages at one site.
        if let slash = needle.firstIndex(of: "/") {
            // Words with a slash match only from the start of an address
            // (a host holds no slash, nor does the part after its first
            // dot): only the pages at the host before the slash can. Every
            // place was looked through for each key, and with an imported
            // history of 600,000 that was most of a key (row 1165).
            if let group = hostGroups[String(needle[..<slash])] {
                func bound(pastPrefix: Bool) -> Int {
                    var low = 0, high = addressOrder.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        let key = entries[addressOrder[middle]].visit.key
                        if key < needle || (pastPrefix && key.hasPrefix(needle)) { low = middle + 1 }
                        else { high = middle }
                    }
                    return low
                }
                let range = bound(pastPrefix: false)..<bound(pastPrefix: true)
                if range.count < max(64, group.count / 8) {
                    // A rare path: score only its matches, not the many
                    // better-visited pages at this site which don't match.
                    for position in range {
                        let at = addressOrder[position]
                        add(10 + frecency(entries[at].visit, now: now) + mark(at) + (entries[at].room ? 0 : 1.5), at)
                    }
                } else {
                    // A broad prefix: the group's best pages come first.
                    // Checking an integer position avoids comparing the
                    // address again for every candidate.
                    for at in group {
                        if ruledOut(at, rank: 6) { break }
                        guard range.contains(addressPosition[at]) else { continue }
                        add(10 + frecency(entries[at].visit, now: now) + mark(at) + (entries[at].room ? 0 : 1.5), at)
                    }
                }
            }
        } else {
            // Every way of matching a host (its start, the start of what
            // follows its first dot, inside it) needs each letter typed in it.
            let needs = History.letters(needle)
            for (letters, group) in hostList where needs & ~letters == 0 {
                guard let first = group.first, !ruledOut(first, rank: 6),
                      let rank = History.rank(entries[first], asked) else { continue }
                for at in group {
                    if ruledOut(at, rank: rank) { break }
                    let entry = entries[at]
                    add(rank + 4 + frecency(entry.visit, now: now) + mark(at) + (entry.room ? 0 : 1.5), at)
                }
            }
        }

        // Bookmarks, matched as the places are: a handful to a few
        // thousand, looked through whole. One been to whose address
        // matches is that place's row, counted above; one found by its
        // title is counted here, by the page's own title and visits.
        // Ruled out by its letters alone: those typed (a host or a key
        // is matched only from its start or inside its host), and those
        // of every word for a title.
        let typedLetters = History.letters(needle)
        let wordLetters = asked.words.isEmpty ? 0 : History.letters(asked.words.joined())
        let hostOnly = !needle.contains("/")
        for at in marks.indices {
            let hostRuled = hostOnly && typedLetters & ~markHosts[at] != 0
            let titleRuled = asked.words.isEmpty || wordLetters & ~markTitles[at] != 0
            if hostRuled && titleRuled { continue }
            let entry = marks[at]
            let root = entry.room ? 0 : 1.5
            let place = seen[at]
            if place >= 0 {
                let visited = entries[place]
                guard !asked.words.isEmpty, History.rank(visited, asked) == nil,
                      History.titled(visited, asked) != nil else { continue }
                add(5 + frecency(visited.visit, now: now) + History.markWeight + root, place)
            } else if let rank = History.rank(entry, asked) {
                add(rank + 4 + History.markWeight + root, History.markBase - at)
            } else if History.titled(entry, asked) != nil {
                add(5 + History.markWeight + root, History.markBase - at)
            }
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for (at, known) in History.known.enumerated() where visits[known.0] == nil && !marked.contains(known.0) {
            guard let rank = History.rank(History.knownEntries[at], asked)
                ?? (known.1.lowercased().hasPrefix(needle) ? 2 : nil) else { continue }
            add(rank, -1 - at)
        }

        if !asked.words.isEmpty {
            var candidates: TitlePostings?
            for word in asked.words {
                let prefix = String(word.dropFirst().prefix(3))
                let pool = titlePrefixes[prefix] ?? TitlePostings()
                if candidates == nil || pool.count < candidates!.count { candidates = pool }
            }
            let roots = candidates?.roots ?? []
            let rooms = candidates?.rooms ?? []
            var rootAt = 0
            var roomAt = 0
            while rootAt < roots.count || roomAt < rooms.count {
                let rootScore = rootAt < roots.count
                    ? frecency(entries[roots[rootAt]].visit, now: now) + 1.5 : -.infinity
                let roomScore = roomAt < rooms.count
                    ? frecency(entries[rooms[roomAt]].visit, now: now) : -.infinity
                let at: Int
                let standing: Double
                if rootScore >= roomScore {
                    at = roots[rootAt]
                    standing = rootScore
                    rootAt += 1
                } else {
                    at = rooms[roomAt]
                    standing = roomScore
                    roomAt += 1
                }
                // Both lists are ordered by frequency. Once their best
                // remaining title is below the fifth row, none can enter it.
                if bestScores.count == limit, let last = bestScores.last,
                   5 + standing < last { break }
                let entry = entries[at]
                guard History.rank(entry, asked) == nil, History.titled(entry, asked) != nil else { continue }
                // A bookmark's title match is counted with the bookmarks.
                if mark(at) > 0 { continue }
                add(5 + standing, at)
            }
        }

        // Best first; of two as good, the shorter address, then the first
        // in the alphabet, so the same history always gives the same list.
        func key(_ at: Int) -> String {
            if at >= 0 { return entries[at].visit.key }
            if at <= History.markBase { return marks[History.markBase - at].visit.key }
            return History.known[-1 - at].0
        }
        func better(_ a: (score: Double, at: Int), _ b: (score: Double, at: Int)) -> Bool {
            if a.score != b.score { return a.score > b.score }
            let one = key(a.at), other = key(b.at)
            if one.count != other.count { return one.count < other.count }
            return one < other
        }
        func offer(_ at: Int) -> Suggestion? {
            if at >= 0 {
                // From an index made before the last change: the place as
                // it is now, and none if it has gone.
                guard let visit = indexed ? entries[at].visit : visits[entries[at].visit.key] else { return nil }
                return URL(string: visit.url).map {
                    Suggestion(key: visit.key, title: visit.title, url: $0, kind: .visited, bookmarked: marked.contains(visit.key))
                }
            }
            if at <= History.markBase {
                let visit = marks[History.markBase - at].visit
                return URL(string: visit.url).map { Suggestion(key: visit.key, title: visit.title, url: $0, kind: .visited, bookmarked: true) }
            }
            let known = History.known[-1 - at]
            return URL(string: "https://" + known.0).map { Suggestion(key: known.0, title: known.1, url: $0, kind: .known) }
        }
        // Only the best few are ever shown: they are picked out rather than
        // everything sorted, and only their addresses are read.
        var top: [(score: Double, at: Int)] = []
        for one in found {
            if top.count == limit, let last = top.last, !better(one, last) { continue }
            top.insert(one, at: top.firstIndex { better(one, $0) } ?? top.count)
            if top.count > limit { top.removeLast() }
        }
        var offers = top.compactMap { offer($0.at) }
        // An address kept that doesn't read as one: its row is passed over
        // and the next comes up, from all of them in order.
        if offers.count < top.count {
            offers = []
            for one in found.sorted(by: better) {
                guard offers.count < limit else { break }
                if let made = offer(one.at) { offers.append(made) }
            }
        }
        self.asked = (needle, limit, now, offers)
        return offers
    }

    /// What the field should draw grayed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        let lower = typed.lowercased()
        guard !lower.isEmpty else { return nil }
        // A single letter can finish a place the user deliberately chose.
        // A page inside a site needs two such choices; visits made by links
        // alone must not turn one letter into an arbitrary deep page. If the
        // most-visited page is ineligible, a familiar domain below it can
        // still finish the letter.
        let hit = options.first { offer in
            guard offer.isPlace, offer.key.hasPrefix(lower) else { return false }
            guard lower.count == 1 else { return true }
            switch offer.kind {
            case .visited:
                guard let visit = visits[offer.key] else { return false }
                if offer.key.contains("/") { return (visit.typed ?? 0) >= 2 }
                return (visit.typed ?? 0) > 0 || visit.count >= 3
            case .known:
                return History.known.filter { $0.0.hasPrefix(lower) }.count == 1
            default:
                return false
            }
        }
        guard let hit else { return nil }
        let rest = String(hit.key.dropFirst(lower.count))
        return rest.isEmpty ? nil : rest
    }

    /// Which letters a text holds, a bit for each of a to z, 0 to 9, dot
    /// and dash, and one for anything else: a text missing one bit of the
    /// words cannot hold them.
    nonisolated static func letters(_ text: String) -> UInt64 {
        var bits: UInt64 = 0
        for byte in text.utf8 {
            // Swift matches canonically equivalent spellings. Their UTF-8
            // letters can differ (é and e + accent), so a byte mask must not
            // rule either one out before String has compared them.
            if byte >= 0x80 { return .max }
            switch byte {
            case 0x61 ... 0x7A: bits |= 1 << UInt64(byte - 0x61)
            case 0x30 ... 0x39: bits |= 1 << UInt64(26 + byte - 0x30)
            case 0x2E: bits |= 1 << 36
            case 0x2D: bits |= 1 << 37
            case 0x20: break
            default: bits |= 1 << 38
            }
        }
        return bits
    }

    /// What being a bookmark adds to a place you have been.
    private func mark(_ at: Int) -> Double {
        at < entryMarked.count && entryMarked[at] ? History.markWeight : 0
    }

    /// Frecency, plus the same preference for a front door over a room inside
    /// it that the search uses.
    private func standing(_ visit: Visit, now: Date) -> Double {
        frecency(visit, now: now) + (visit.key.contains("/") ? 0 : 1.5)
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean, the middle of a path almost never is.
    private static func rank(_ entry: Entry, _ needle: Needle) -> Double? {
        if let bytes = needle.bytes, entry.asciiKey {
            // Both plain ASCII: the same answer as hasPrefix, by bytes.
            if entry.visit.key.utf8.starts(with: bytes) { return 6 }
            if let tail = entry.tail, tail.utf8.starts(with: bytes) { return 3 }
        } else {
            if entry.visit.key.hasPrefix(needle.text) { return 6 }
            // "hub" finding github.com, once the "git" has been skipped.
            if let tail = entry.tail, tail.hasPrefix(needle.text) { return 3 }
        }
        // Only from two letters up. A single letter matching anywhere inside
        // a name turns "x" into example.com and netflix.com, which is not what
        // anybody meant by it.
        guard needle.inside else { return nil }
        // Deliberately no match on the path. "blog" turning up six articles
        // from three sites is not an answer to anything.
        if let bytes = needle.bytes, entry.ascii { return holds(entry.host, bytes) ? 2 : nil }
        return entry.host.contains(needle.text) ? 2 : nil
    }

    /// The sites the field knows from the start, as places are matched.
    private static let knownEntries = known.map { Entry(Visit(url: "", key: $0.0, title: "", count: 0, last: .distantPast)) }

    /// By what the page was called, once three letters say enough: every
    /// word typed has to begin a word of the title, so "swift conc" finds
    /// the article on Swift concurrency and "on" finds nothing. Ranked under
    /// any match on the address, the address is what the field is for.
    private static func titled(_ entry: Entry, _ needle: Needle) -> Double? {
        guard !needle.words.isEmpty, !entry.visit.title.isEmpty else { return nil }
        if let words = needle.wordBytes, entry.asciiTitle {
            return words.allSatisfy { History.holds(entry.title, $0) } ? 1 : nil
        }
        return needle.words.allSatisfy { entry.title.contains($0) } ? 1 : nil
    }

    /// Often, and lately. A month-old visit counts for about a third of a
    /// fresh one, which is roughly how long a habit takes to stop being one.
    /// A visit asked for in the field counts three times over a link
    /// followed: it is where you meant to be.
    private func frecency(_ visit: Visit, now: Date) -> Double {
        History.frecency(visit, now: now)
    }

    nonisolated private static func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count + 2 * (visit.typed ?? 0)) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    // MARK: - the file

    /// Above this size, searches wait for the background index.
    static let cap = 2_000

    private static var folder: URL { Store.folder }
    private static var file: URL { Store.file("history.json") }

    private func load() {
        guard let storage, let data = try? Data(contentsOf: storage) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(storage)
            return
        }
        var loaded = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.last >= b.last ? a : b })
        if History.keyPorts(&loaded) { pendingPortKeys = true }
        visits = loaded
    }

    /// Set when `load` gave places their ports, to write them down once.
    private var pendingPortKeys = false

    /// Places kept before the key had a port (`key(for:)`), given theirs:
    /// a page at localhost:3000 comes under localhost:3000/…, and the one
    /// row every server on a host shared (all its pages' visits counted
    /// toward it) becomes a row for each port, counted by that port's
    /// pages, the visits to the row itself staying with the server it
    /// went to. Only addresses with a port of their own move. Whether
    /// anything did.
    @discardableResult
    nonisolated static func keyPorts(_ visits: inout [String: Visit]) -> Bool {
        var shared: [Visit] = []
        var moved: [Visit] = []
        for (key, visit) in visits {
            guard let url = URL(string: visit.url), ownPort(url) != nil else { continue }
            let now = History.key(for: url)
            guard now != key else { continue }
            visits[key] = nil
            if key.contains("/") { moved.append(visit) } else { shared.append(visit) }
        }
        guard !shared.isEmpty || !moved.isEmpty else { return false }
        func fold(_ visit: Visit, under key: String) {
            var visit = visit
            visit.key = key
            guard var seen = visits[key] else { visits[key] = visit; return }
            seen.count += visit.count
            if let typed = visit.typed { seen.typed = (seen.typed ?? 0) + typed }
            if visit.last > seen.last { seen.last = visit.last; seen.url = visit.url; if !visit.title.isEmpty { seen.title = visit.title } }
            if seen.title.isEmpty { seen.title = visit.title }
            seen.spaces = joined(seen.spaces, visit.spaces)
            visits[key] = seen
        }
        // Each port's pages, and what they add up to, by the row's key: in
        // all and in each space.
        var ports: [String: (count: Int, last: Date, url: String, spaces: [String: SpaceVisits]?)] = [:]
        for page in moved {
            guard let url = URL(string: page.url) else { continue }
            fold(page, under: History.key(for: url))
            let front = URL(string: "/", relativeTo: url)!.absoluteURL
            let root = History.key(for: front)
            let was = ports[root]
            ports[root] = ((was?.count ?? 0) + page.count, max(was?.last ?? .distantPast, page.last), front.absoluteString,
                           joined(was?.spaces, page.spaces))
        }
        // The row each host's servers shared: moved, when the address it
        // kept had a port, or left where it is, when it was the scheme's
        // own. Its visits are shared out, in all and in each space: each
        // port's row as many as its pages had, scaled down to the row's own
        // when the pages had more (counts brought in from another browser
        // never reached the row), and what is left, the visits to the row
        // itself, stays with the server it went to. The host counts for no
        // more than it did.
        var hosts = Set(ports.keys.map(History.bareHost))
        func split(_ host: String, _ row: Visit?, under own: String?) {
            let mine = ports.filter { History.bareHost($0.key) == host }
            guard var row, let own else {
                for (key, port) in mine {
                    fold(Visit(url: port.url, key: key, title: "", count: port.count, last: port.last, spaces: port.spaces), under: key)
                }
                return
            }
            let pages = mine.values.reduce(0) { $0 + $1.count }
            let budget = min(row.count, pages)
            var given = 0
            var left = row.spaces ?? [:]
            for (key, port) in mine.sorted(by: { $0.key < $1.key }) {
                let count = pages == 0 ? 0 : budget * port.count / pages
                given += count
                var spaces: [String: SpaceVisits] = [:]
                for (id, here) in port.spaces ?? [:] {
                    let share = min(pages == 0 ? 0 : here.count * budget / pages, left[id]?.count ?? 0)
                    guard share > 0 else { continue }
                    spaces[id] = SpaceVisits(count: share, last: here.last)
                    left[id]?.count -= share
                }
                guard count > 0 || key == own else { continue }
                fold(Visit(url: port.url, key: key, title: "", count: count, last: port.last, spaces: spaces.isEmpty ? nil : spaces), under: key)
            }
            row.count -= given
            left = left.filter { $0.value.count > 0 }
            row.spaces = left.isEmpty ? nil : left
            if own == host { visits[host] = nil }
            if row.count > 0 || (row.typed ?? 0) > 0 || own != host || visits[own] != nil { fold(row, under: own) }
        }
        for row in shared {
            guard let url = URL(string: row.url) else { continue }
            let own = History.key(for: url)
            let host = History.bareHost(own)
            hosts.remove(host)
            split(host, row, under: own)
        }
        for host in hosts { split(host, visits[host], under: visits[host] == nil ? nil : host) }
        return true
    }

    /// Coalesced writes keep every imported visit. Encoding and disk work
    /// run on one background queue, so a later deletion always wins.
    private func save() {
        guard storage != nil, pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingSave = nil
            persist()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func persist(then done: @escaping () -> Void = {}) {
        guard let storage else { done(); return }
        let snapshot = visits
        History.writes.async {
            defer { done() }
            guard let data = MainBudget.chunk("history.persist", { try? JSONEncoder().encode(Array(snapshot.values)) }) else { return }
            try? FileManager.default.createDirectory(
                at: storage.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: storage, options: .atomic)
        }
    }

    /// Wait for the current snapshot to reach disk, including earlier writes.
    /// A write still scheduled is dropped: this one carries its rows, and
    /// left alone it would land over whatever another reader of the file
    /// wrote in between (a second History on the same file, as tests make).
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await withCheckedContinuation { continuation in
            persist { continuation.resume() }
        }
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    /// The sites the field knows from the start, by host.
    static var knownHosts: [String] { known.map(\.0) }

    /// Each site's last visit, by host without "www.", for the kept icons
    /// to know which sites are long gone (Favicons.prune).
    func lastVisits() -> [String: Date] {
        var sites: [String: Date] = [:]
        for visit in visits.values {
            let host = String(visit.key.prefix { $0 != "/" })
            if visit.last > sites[host] ?? .distantPast { sites[host] = visit.last }
        }
        return sites
    }

    static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}

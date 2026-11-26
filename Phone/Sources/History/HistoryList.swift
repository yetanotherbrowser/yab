import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

// History's rules, kept apart from any view or store so they can be checked
// on their own (HistoryTests): which pages it lists, how they fall into
// days, what a search finds, what a Clear takes, and which places the field
// offers for typed words and in what order (the Mac's History.suggestions).

/// A place sync holds: a page a device went to in the last two weeks (the
/// Mac's visit records), with the device whose visit it last was.
struct SyncedPlace: Equatable, Sendable {
    /// Sync's key for the place (SyncVisit.key): host, a port of its own and
    /// path, lowercased.
    var key: String
    var url: String
    var title: String
    /// Seconds since 1970.
    var last: Double
    var typed: Bool
    /// The device that stamped `last`: a Mac's id, or this iPhone's own.
    var device: String?
}

/// A bookmark of the Mac's, as the field looks through them.
struct SyncedBookmark: Equatable, Sendable {
    var title: String
    var url: String
}

/// One page in History, newest first: a visit on this iPhone, or a place a
/// Mac went to that this iPhone hasn't been to since.
struct HistoryEntry: Identifiable, Equatable, Sendable {
    var url: String
    var title: String
    var host: String
    var icon: String
    var visitedAt: Date
    var count: Int
    var typed: Bool
    /// Where it came from when that isn't this iPhone: the Mac's name.
    var device: String?
    /// Sync's key for the place, when it came from sync.
    var syncedKey: String?

    var id: String { (syncedKey.map { "synced:" + $0 }) ?? ("here:" + url) }
    var isSynced: Bool { syncedKey != nil }
    /// Sync's key for the place (SyncVisit.key), the same on every device.
    var key: String { syncedKey ?? HistoryList.key(url) }
    /// What the row says: the title, or the address when the page had none.
    var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? HistoryList.bare(host) : title }
}

/// A day of History: Today, Yesterday, then dates.
struct HistoryDay: Identifiable, Equatable, Sendable {
    var start: Date
    var title: String
    var entries: [HistoryEntry]
    var id: Date { start }
}

/// What Clear takes: everything from a moment until now.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour, today, todayAndYesterday, allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: "Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .allTime: "All Time"
        }
    }

    /// Where the range begins; nil for all of it.
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3_600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .allTime: nil
        }
    }
}

/// Synced places taken out of History here. History in sync only ever adds
/// (a Mac keeps its own), so a place taken out stays out on this iPhone
/// until someone goes there again.
struct HistoryForgetting: Codable, Equatable, Sendable {
    /// A place by its key, and the `last` it had when it was taken out.
    var places: [String: Double] = [:]
    /// Spans cleared, seconds since 1970: a place last been to inside one stays out.
    var spans: [Span] = []

    struct Span: Codable, Equatable, Sendable {
        var from: Double
        var to: Double
    }

    /// A place taken out before ports were part of its key was saved
    /// without the port (`localhost/blog`), and stays out under its key now
    /// (`localhost:3000/blog`): that key was its row then, every port's.
    func hides(_ place: SyncedPlace) -> Bool {
        if let seen = places[place.key] ?? SyncVisit.portless(place.key).flatMap({ places[$0] }), place.last <= seen { return true }
        return spans.contains { place.last >= $0.from && place.last <= $0.to }
    }

    mutating func forget(_ key: String, last: Double) {
        places[key] = max(places[key] ?? 0, last)
    }

    mutating func clear(from: Double, to: Double) {
        var all = spans + [Span(from: from, to: to)]
        all.sort { $0.from < $1.from }
        var merged: [Span] = []
        for span in all {
            if let lastSpan = merged.last, span.from <= lastSpan.to { merged[merged.count - 1].to = max(lastSpan.to, span.to) }
            else { merged.append(span) }
        }
        spans = merged
    }

    /// Sync holds two weeks: what is older than that can't come back.
    mutating func prune(now: Date) {
        let floor = now.timeIntervalSince1970 - HistoryList.syncedDays * 86_400 - 86_400
        places = places.filter { $0.value >= floor }
        spans = spans.filter { $0.to >= floor }
    }
}

enum HistoryList {
    /// How far back this iPhone's visits go to the Mac: the Mac's two weeks
    /// (SyncShapes.historyDays, docs/sync.md).
    static let syncedDays: Double = 14

    /// Sync's key for an address (SyncVisit.key), or the address lowercased.
    static func key(_ address: String) -> String {
        URL(string: address).map(SyncVisit.key) ?? address.lowercased()
    }

    static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// This iPhone's visits and the places sync holds, newest first. A place
    /// this iPhone went to at the same time or later is its own row already;
    /// one the Mac went to later stands too, saying so. This iPhone's own
    /// records in sync never come back as someone else's.
    static func entries(local: [BrowserVisit], synced: [SyncedPlace], forgetting: HistoryForgetting = HistoryForgetting(),
                        ownDevice: String? = nil, name: (String?) -> String? = { _ in nil }) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        var latest: [String: Date] = [:]
        for visit in local where validDate(visit.visitedAt.timeIntervalSince1970) {
            out.append(HistoryEntry(url: visit.url, title: visit.title, host: bare(visit.host), icon: visit.icon,
                                    visitedAt: visit.visitedAt, count: visit.count, typed: false))
            let key = key(visit.url)
            latest[key] = max(latest[key] ?? .distantPast, visit.visitedAt)
        }
        for place in synced {
            if let ownDevice, place.device == ownDevice { continue }
            guard validDate(place.last), !forgetting.hides(place), let url = URL(string: place.url), SyncVisit.keeps(url) else { continue }
            let last = Date(timeIntervalSince1970: place.last)
            if let here = latest[place.key], here >= last.addingTimeInterval(-60) { continue }
            let host = url.host()?.lowercased() ?? place.key
            out.append(HistoryEntry(url: place.url, title: place.title, host: bare(host), icon: host, visitedAt: last,
                                    count: 1, typed: place.typed, device: name(place.device), syncedKey: place.key))
        }
        return out.sorted { $0.visitedAt != $1.visitedAt ? $0.visitedAt > $1.visitedAt : $0.id < $1.id }
    }

    /// Corrupt dates must not reach sorting or Calendar during launch.
    /// Accept calendar dates in years 1-9999, not arbitrary floating values.
    static func validDate(_ seconds: Double) -> Bool {
        seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
    }

    /// The pages whose title or address has every word typed, in any case
    /// and with or without accents.
    static func matching(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let hay = fold(entry.title + " " + (URL(string: entry.url).map(Address.pretty) ?? entry.url))
            return words.allSatisfy { hay.contains($0) }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The pages by the day they were last opened, newest day first. A page
    /// dated ahead of now (a Mac's clock running fast) counts as today's.
    static func days(_ entries: [HistoryEntry], now: Date, calendar: Calendar, locale: Locale = .current) -> [HistoryDay] {
        let today = calendar.startOfDay(for: now)
        var out: [HistoryDay] = []
        for entry in entries where validDate(entry.visitedAt.timeIntervalSince1970) {
            let start = min(calendar.startOfDay(for: entry.visitedAt), today)
            if let last = out.indices.last, out[last].start == start { out[last].entries.append(entry) }
            else { out.append(HistoryDay(start: start, title: title(start, now: now, calendar: calendar, locale: locale), entries: [entry])) }
        }
        return out
    }

    /// Today, Yesterday, then "Tuesday, October 7" (and the year when it isn't this one).
    static func title(_ day: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.wide).day()
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) { style = style.year() }
        return day.formatted(style)
    }

    /// The local visits a Clear of this range takes (by address), and the
    /// span of synced places it hides.
    static func cleared(_ range: HistoryRange, local: [BrowserVisit], now: Date, calendar: Calendar) -> (urls: Set<String>, from: Double, to: Double) {
        let start = range.start(now: now, calendar: calendar)
        let urls = Set(local.filter { start == nil || $0.visitedAt >= start! }.map(\.url))
        // To a minute ahead: a page opened as Clear is chosen goes too.
        return (urls, start?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 + 60)
    }

    // MARK: - what goes to the Mac

    /// A step of a sign-in no one goes back to (the Mac's History.signInStep):
    /// a sign-in page saying who signs in, an OAuth request, the redirect
    /// bringing its code. Never in sync.
    static func signInStep(_ url: URL) -> Bool {
        let names = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased() })
        return names.contains("login_hint") || names.isSuperset(of: ["client_id", "redirect_uri"]) || names.isSuperset(of: ["code", "state"])
    }

    /// Whether a visit on this iPhone goes to the Mac's history: a web page,
    /// no sign-in step or address with a password in it, in the last two weeks.
    static func syncs(_ url: URL, at date: Date, now: Date = Date()) -> Bool {
        SyncVisit.keeps(url) && !signInStep(url) && url.user == nil && url.password == nil
            && now.timeIntervalSince(date) <= syncedDays * 86_400
    }
}

// MARK: - places for typed words

/// A page the field may offer for typed words: one place in History (every
/// visit to it, here and on the Mac) or a bookmark of the Mac's.
struct PlaceCandidate: Equatable, Sendable {
    var key: String { didSet { search = PlaceSearch(key: key, title: title) } }
    var url: String
    var title: String { didSet { search = PlaceSearch(key: key, title: title) } }
    var host: String
    var icon: String
    var count: Int
    var typed: Bool
    var last: Date?
    var bookmarked: Bool
    /// The address and title as typed words are matched against them.
    private(set) var search: PlaceSearch

    init(key: String, url: String, title: String, host: String, icon: String, count: Int, typed: Bool, last: Date?,
         bookmarked: Bool) {
        self.key = key
        self.url = url
        self.title = title
        self.host = host
        self.icon = icon
        self.count = count
        self.typed = typed
        self.last = last
        self.bookmarked = bookmarked
        search = PlaceSearch(key: key, title: title)
    }

    var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title }
}

/// A place's address and title in the forms the typed words are matched
/// against, made once with the place. Made on every letter for each of a
/// Mac's weeks of places, folding the titles alone took most of a second
/// per letter (#1637).
struct PlaceSearch: Equatable, Sendable {
    /// The key, lowercased.
    let key: String
    /// Its host, and the host after its first label ("github.com" of "www.github.com").
    let host: String
    let tail: String?
    /// A site's front page: no path.
    let root: Bool
    /// The title folded, its words joined by single spaces after a leading
    /// one, so " word" finds a word's start; nil for no title.
    let title: String?

    init(key: String, title: String) {
        let lower = key.lowercased()
        self.key = lower
        let host = lower.split(separator: "/").first.map(String.init) ?? lower
        self.host = host
        tail = host.range(of: ".").map { String(host[$0.upperBound...]) }
        root = !lower.contains("/")
        self.title = title.isEmpty ? nil
            : " " + HistoryList.fold(title).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}

/// A place and how well it answers the words.
struct RankedPlace: Equatable, Sendable {
    var place: PlaceCandidate
    var score: Double
    /// The words begin its address: Safari's top hit, offered before the search.
    var strong: Bool
}

enum Places {
    /// Every place once, by sync's key: its visits added up, its newest
    /// address and title, a bookmark marked. Search results pages are left
    /// out: the search row and the engine's completions are those.
    static func candidates(history: [HistoryEntry], bookmarks: [SyncedBookmark]) -> [PlaceCandidate] {
        var out: [String: PlaceCandidate] = [:]
        var order: [String] = []
        for entry in history {
            guard let url = URL(string: entry.url), !isSearch(url) else { continue }
            let key = entry.key
            if var had = out[key] {
                had.count += entry.count
                had.typed = had.typed || entry.typed
                if entry.visitedAt > (had.last ?? .distantPast) {
                    had.last = entry.visitedAt
                    had.url = entry.url
                    if !entry.title.isEmpty { had.title = entry.title }
                }
                out[key] = had
            } else {
                order.append(key)
                out[key] = PlaceCandidate(key: key, url: entry.url, title: entry.title, host: entry.host, icon: entry.icon,
                                          count: entry.count, typed: entry.typed, last: entry.visitedAt, bookmarked: false)
            }
        }
        for mark in bookmarks {
            guard let url = URL(string: mark.url), SyncVisit.keeps(url), !isSearch(url) else { continue }
            let key = SyncVisit.key(url)
            if var had = out[key] {
                had.bookmarked = true
                if had.title.isEmpty { had.title = mark.title }
                out[key] = had
            } else {
                order.append(key)
                let host = HistoryList.bare(url.host()?.lowercased() ?? key)
                out[key] = PlaceCandidate(key: key, url: mark.url, title: mark.title, host: host, icon: url.host()?.lowercased() ?? host,
                                          count: 0, typed: false, last: nil, bookmarked: true)
            }
        }
        return order.compactMap { out[$0] }
    }

    /// A results page of one of the engines Yab searches with: its words are
    /// the search row's and the completions'.
    static func isSearch(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let names = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
        return engines.contains { engine in
            (host == engine.host || host.hasSuffix("." + engine.host) || engine.host.hasSuffix("." + host))
                && url.path() == engine.path && names.contains(engine.parameter)
        }
    }

    /// Each engine's host, results path and the parameter its words go in,
    /// read from its own search address.
    private static let engines: [(host: String, path: String, parameter: String)] = SearchEngine.allCases.compactMap { engine in
        let selection = SearchEngine.Selection(rawValue: engine.rawValue)
        guard engine != .custom, let url = selection.url(for: "yab"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased(),
              let parameter = parts.queryItems?.first(where: { $0.value == "yab" })?.name else { return nil }
        return (HistoryList.bare(host), parts.path, parameter)
    }

    /// Best first, as the Mac's field ranks history: a place whose address
    /// the words begin, then one whose host has them, then one whose title
    /// has every word (three letters or more) beginning one of its words.
    /// Among those, often and lately wins (frecency), a site's front page
    /// over a page inside it, then the shorter address.
    static func ranked(_ typed: String, _ candidates: [PlaceCandidate], now: Date = Date()) -> [RankedPlace] {
        let needle = strip(typed)
        // Two letters or more, as tabs: one letter matches half the web.
        guard needle.count >= 2 else { return [] }
        let words = needle.count >= 3 ? needle.split(whereSeparator: \.isWhitespace).map { HistoryList.fold(" " + $0) } : []
        let oneWord = !needle.contains(" ")
        var out: [RankedPlace] = []
        for place in candidates {
            let search = place.search
            var rank: Double?
            if search.key.hasPrefix(needle) { rank = 6 }
            else if let tail = search.tail, tail.hasPrefix(needle) { rank = 3 }
            else if oneWord, search.host.contains(needle) { rank = 2 }
            if let rank {
                out.append(RankedPlace(place: place, score: rank + 4 + standing(place, now: now), strong: rank >= 3))
            } else if !words.isEmpty, let title = search.title, words.allSatisfy({ title.contains($0) }) {
                out.append(RankedPlace(place: place, score: 5 + standing(place, now: now), strong: false))
            }
        }
        return out.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.place.key.count != b.place.key.count { return a.place.key.count < b.place.key.count }
            return a.place.key < b.place.key
        }
    }

    /// Frecency, and a site's front page over a page inside it.
    private static func standing(_ place: PlaceCandidate, now: Date) -> Double {
        frecency(place, now: now) + (place.search.root ? 1.5 : 0)
    }

    /// Often, and lately (the Mac's History.frecency): a month-old visit
    /// counts for about a third of a fresh one, a typed one three times, a
    /// bookmark as two visits.
    static func frecency(_ place: PlaceCandidate, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(place.last ?? now) / 86_400)
        let visits = Double(place.count + (place.typed ? 2 : 0))
        return visits * exp(-days / 30) + (place.bookmarked ? 2 : 0)
    }

    /// The words as an address is keyed: no scheme, no www., lowercased.
    static func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }
}

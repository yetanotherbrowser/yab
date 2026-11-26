import Foundation
import SQLite3

// What an agent may know of where you have been: the `history` tool.
//
// Without words, the sites you use, as onboarding sees them:
// thirty days of visits, here and in the Chromium browsers on this Mac
// brought in from (OtherHistory),
// grouped by site and ranked by how regularly you go (active days, then
// visits, so twenty days of three visits outrank one day of sixty), with
// weekday and weekend, whether you sign in there, and the parts of the site
// you use (google.com/maps is not google.com/search). Sign-in hosts, link
// shorteners and sites seen on one day only drop out as noise.
//
// With words, the pages themselves: the diary's full-text index over what
// pages said and were called, newest first; with a site, its pages.
//
// Read-only, on a queue of its own: the diary's file in WAL mode takes a
// reader beside its writer, and other browsers' files are read from a copy.

enum AgentHistory {
    struct Site {
        let host: String
        var visits = 0
        var days = Set<String>()
        var weekday = 0
        var weekend = 0
        var signIn = false
        var paths: [String: Int] = [:]
        var last = Date.distantPast

        var score: Double { Double(days.count) * log1p(Double(visits)) }
    }

    static let window = 30

    /// The table an agent reads first, in Markdown.
    static func sites(days: Int = window, limit: Int = 40, elsewhere: [AgentDevices.Visit] = []) -> String {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var all: [String: Site] = [:]
        var scanned = 0
        var sources: [String] = []
        let calendar = Calendar.current
        func add(_ url: URL, at: Date, signIn: Bool) {
            guard let host = url.host()?.lowercased(), !noise(host) else { return }
            let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            var site = all[key] ?? Site(host: key)
            site.visits += 1
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: at)
            site.days.insert("\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)")
            if parts.weekday == 1 || parts.weekday == 7 { site.weekend += 1 } else { site.weekday += 1 }
            if signIn { site.signIn = true }
            let first = "/" + (url.path.split(separator: "/").first.map(String.init) ?? "")
            site.paths[first, default: 0] += 1
            site.last = max(site.last, at)
            all[key] = site
            scanned += 1
        }
        let yab = diaryVisits(since: since)
        if !yab.isEmpty { sources.append("Yab") }
        for visit in yab { add(visit.url, at: visit.at, signIn: Diary.isSignIn(visit.url)) }
        for source in (AgentFixture.requested ? [] : OtherHistory.sources()) {
            let visits = chromiumVisits(source, since: since)
            guard !visits.isEmpty else { continue }
            sources.append(source.name)
            for visit in visits { add(visit.url, at: visit.at, signIn: visit.signIn) }
        }
        // Sync keeps a place's last visit only: one each, from its device.
        let away = elsewhere.filter { $0.at >= since }
        for device in Set(away.map(\.device)).sorted() { sources.append("Yab on \(device)") }
        for visit in away { add(visit.url, at: visit.at, signIn: Diary.isSignIn(visit.url)) }
        let ranked = all.values
            .filter { $0.visits >= 5 && !($0.days.count == 1 && $0.visits < 20) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.signIn && !$1.signIn) }
            .prefix(limit)
        var out = "# The sites the user uses\n\n"
        out += "_From the last \(days) days of browsing (\(scanned.formatted()) visits, from \(sources.isEmpty ? "no browser" : sources.joined(separator: ", ")))._\n\n"
        guard !ranked.isEmpty else { return out + "_Nothing yet: this looks like a fresh browser._\n" }
        out += "| Site | Active days | Visits | Weekday/Weekend | Signs in | Top areas |\n| --- | --- | --- | --- | --- | --- |\n"
        for site in ranked {
            let areas = site.paths.sorted { $0.value > $1.value }.prefix(3).map(\.key).joined(separator: " ")
            out += "| \(site.host) | \(site.days.count) | \(site.visits) | \(site.weekday)/\(site.weekend) | \(site.signIn ? "yes" : "") | \(areas) |\n"
        }
        out += "\nCall history with words to find pages, with a site to list its pages, or with device for what was opened on one."
        return out
    }

    /// Pages that say or are called what was asked, or a site's pages.
    static func pages(matching words: String?, host: String?, device: String? = nil, days: Int = 365, limit: Int = 40,
                      elsewhere: [AgentDevices.Visit] = []) -> String {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var rows: [(title: String, url: String, last: Date, device: String?)] = []
        // Another device's places: their titles and addresses, not their text.
        let terms = words.map(Diary.terms) ?? []
        let wanted = device?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        for visit in elsewhere where visit.at >= since {
            if !wanted.isEmpty, !visit.device.lowercased().contains(wanted) { continue }
            if let host, clean(visit.url.host() ?? "") != clean(host) { continue }
            let said = (visit.title + " " + visit.url.absoluteString).lowercased()
            if words?.isEmpty == false, terms.isEmpty || !terms.allSatisfy({ said.contains($0) }) { continue }
            rows.append((visit.title, visit.url.absoluteString, visit.at, visit.device))
        }
        if !wanted.isEmpty {
            guard !rows.isEmpty else {
                let known = Set(elsewhere.map(\.device)).sorted()
                return known.isEmpty ? "Nothing from another device: Sync is off, its History switch is, or nothing came yet."
                    : "Nothing opened on \(device ?? "") for that. Devices with history here: \(known.joined(separator: ", "))."
            }
            return lines(Array(rows.sorted { $0.last > $1.last }.prefix(limit)))
        }
        withDiary { db in
            var sql: String
            var args: [String] = []
            if let words, !words.trimmingCharacters(in: .whitespaces).isEmpty {
                let match = Diary.terms(words).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
                guard !match.isEmpty else { return }
                sql = """
                SELECT p.title, p.url, p.last FROM words w JOIN pages p ON p.key = w.key
                WHERE words MATCH ? AND p.last >= ? \(host == nil ? "" : "AND p.host = ?")
                GROUP BY p.key ORDER BY p.last DESC LIMIT \(limit)
                """
                args = [match]
            } else {
                sql = "SELECT title, url, last FROM pages WHERE last >= ? AND host = ? ORDER BY last DESC LIMIT \(limit)"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            for arg in args { sqlite3_bind_text(statement, index, arg, -1, transient); index += 1 }
            sqlite3_bind_double(statement, index, since.timeIntervalSince1970); index += 1
            if let host { sqlite3_bind_text(statement, index, clean(host), -1, transient) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let url = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                rows.append((title, url, Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), nil))
            }
        }
        guard !rows.isEmpty else { return "No pages in the history for that." }
        return lines(Array(rows.sorted { $0.last > $1.last }.prefix(limit)))
    }

    /// What they did, as the day's threads (docs/day-threads.md): those of
    /// the stretch `when` names ("this morning", "on Friday", "this week"),
    /// or of the last `days` whose words match `query`; each with its pages,
    /// their addresses and times, and what was done on them.
    static func threads(when: String?, query: String?, days: Int = 30, now: Date = Date(), diary: Diary = .shared) async -> String {
        let span = when.flatMap { DayThreads.span($0, now: now) } ?? query.flatMap { DayThreads.span($0, now: now) }
        let from = span?.from ?? now.addingTimeInterval(-Double(days) * 86_400)
        let to = span?.to ?? now.addingTimeInterval(60)
        var threads = await diary.threads(from: from, to: to)
        let terms = Diary.terms(span?.rest ?? query ?? "").filter { $0.count >= 3 && !DayThreads.common.contains($0) && !AskFromDay.askWords.contains($0) }
        if !terms.isEmpty {
            let matched = threads.filter { thread in
                let said = ([thread.name, thread.topic, thread.summary] + thread.pages.map { $0.title + " " + $0.url } + thread.did.map(\.words))
                    .joined(separator: " ").lowercased()
                return terms.contains { said.contains($0) }
            }
            // A stretch named and nothing in it matching: all of the stretch.
            if !matched.isEmpty || span == nil { threads = matched }
        }
        let named = span.map { " " + $0.label.replacingOccurrences(of: "From your ", with: "this ").lowercased() } ?? ""
        var out = "# What the user did in their browser\(named)\n\n"
        out += "_Pages grouped by what they were doing, in Yab on this Mac. Private tabs and pages an agent worked in are never kept. "
            + "When you write from this, say in one plain line what you left out, and give the pages you used as links with their times._\n"
        guard !threads.isEmpty else { return out + "\nNothing for that." }
        var day = ""
        for thread in threads.suffix(40) {
            if thread.day != day {
                day = thread.day
                out += "\n## \(Diary.day(named: day).map(MemoryShelf.dayTitle) ?? day)\n"
            }
            out += "- \(thread.when) · \(thread.told) (\(DayThreads.pages(thread.pages.count)))"
            out += thread.summary.isEmpty ? "\n" : ". \(thread.summary)\n"
            for page in thread.pages.prefix(10) {
                out += "  - \(MarkdownLink.title(page.title, host: page.host)) · \(page.url) · \(DayThreads.time(page.at))\n"
            }
            let did = thread.did.filter { !$0.words.hasPrefix("Read ") }
            if !did.isEmpty { out += "  - What they did: " + did.prefix(8).map { "\($0.time) \($0.words)" }.joined(separator: "; ") + "\n" }
        }
        return out
    }

    private static func lines(_ rows: [(title: String, url: String, last: Date, device: String?)]) -> String {
        let format = AppDates.formatter()
        format.dateFormat = "yyyy-MM-dd"
        return rows.map { row in
            let on = row.device.map { "  (on \($0))" } ?? ""
            return "\(format.string(from: row.last))  \(row.title.isEmpty ? "(untitled)" : row.title)\(on)\n  \(row.url)"
        }.joined(separator: "\n")
    }

    // MARK: - the sources

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Every host opened in `days`, here and in the other browsers whose
    /// history is read (OtherHistory), without www: where a row an
    /// agent suggests may lead. A year, since a plan you pay for and never
    /// use was still opened once, to sign up. Read off the main thread; kept
    /// ten minutes.
    static func knownHosts(days: Int = 365) -> Set<String> {
        known.lock()
        defer { known.unlock() }
        if let cached = knownCache, Date().timeIntervalSince(cached.at) < 600 { return cached.hosts }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        var hosts = Set(diaryVisits(since: since).compactMap { $0.url.host().map(clean) })
        for source in OtherHistory.sources() {
            hosts.formUnion(chromiumVisits(source, since: since).compactMap { $0.url.host().map(clean) })
        }
        knownCache = (Date(), hosts)
        return hosts
    }

    nonisolated(unsafe) private static var knownCache: (at: Date, hosts: Set<String>)?
    private static let known = NSLock()

    /// Another browser's history was let in or stopped: counted again.
    static func forget() {
        known.lock()
        knownCache = nil
        known.unlock()
    }

    /// The last time a service was opened here within `days`, on any host of
    /// its name (notion.so for notion.com), or nil: whether a subscription
    /// to it is used.
    static func lastVisit(to service: String, days: Int = 30) -> Date? {
        guard !Hints.brand(service).isEmpty else { return nil }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        return diaryVisits(since: since).filter { visit in
            Hints.uses(visit.url.host() ?? "", service)
        }.map(\.at).max()
    }

    /// The last visit to each of these services, by one read of the diary
    /// (Purchases: whether what is paid for is used). Slow: off the main
    /// thread only.
    static func lastVisits(to services: [String], days: Int) -> [String: Date] {
        let wanted = services.filter { !Hints.brand($0).isEmpty }
        guard !wanted.isEmpty else { return [:] }
        var out: [String: Date] = [:]
        for visit in diaryVisits(since: Date().addingTimeInterval(-Double(days) * 86_400)) {
            let host = visit.url.host() ?? ""
            for service in wanted where Hints.uses(host, service) && (out[service].map { visit.at > $0 } ?? true) {
                out[service] = visit.at
            }
        }
        return out
    }

    /// Every visit with its page's title. Startup's habit composition reads
    /// only Yab's diary; an explicit history action may include opted-in browsers.
    /// Slow: off the main thread only.
    static func visits(days: Int, includingOtherBrowsers: Bool = true) -> [Habits.Visit] {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        var out = diaryVisits(since: since).map { Habits.Visit(url: $0.url, at: $0.at, title: $0.title) }
        for source in (includingOtherBrowsers ? OtherHistory.sources() : []) {
            out += chromiumVisits(source, since: since).map { Habits.Visit(url: $0.url, at: $0.at, title: $0.title) }
        }
        return out
    }

    private static func clean(_ host: String) -> String {
        var host = host.lowercased()
        if let url = URL(string: host), let inside = url.host() { host = inside }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func noise(_ host: String) -> Bool {
        if host.isEmpty || host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost") { return true }
        if ["t.co", "l.facebook.com", "lm.facebook.com", "bit.ly", "youtu.be", "goo.gl"].contains(host) { return true }
        return ["accounts.", "account.", "auth.", "login.", "signin.", "sso.", "oauth.", "id."].contains { host.hasPrefix($0) }
    }

    private static func withDiary(_ work: (OpaquePointer) -> Void) {
        let file = Store.file("diary.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        work(db)
    }

    private static func diaryVisits(since: Date) -> [(url: URL, at: Date, title: String)] {
        var out: [(URL, Date, String)] = []
        withDiary { db in
            let sql = "SELECT p.url, v.at, p.title FROM visits v JOIN pages p ON p.key = v.key WHERE v.at >= ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)) else { continue }
                let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                out.append((url, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), title))
            }
        }
        return out
    }

    /// Every visit in another browser's profiles since then, read the way
    /// Yab reads its own: user navigation only (no subframes), http(s) only, and
    /// whether the page had a password field.
    private static func chromiumVisits(_ source: Chromium.Source, since: Date) -> [(url: URL, at: Date, signIn: Bool, title: String)] {
        var out: [(URL, Date, Bool, String)] = []
        let epoch = 11_644_473_600.0
        let from = Int64((since.timeIntervalSince1970 + epoch) * 1_000_000)
        for folder in source.profiles {
            let history = folder.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            guard let temp = try? Chromium.copyWithLog(history) else { continue }
            defer { Chromium.removeWithLog(temp) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            // content_annotations is newer than some profiles: without it, no sign-in column.
            for sql in [
                """
                SELECT u.url, v.visit_time, ca.password_state, u.title FROM visits v JOIN urls u ON u.id = v.url
                LEFT JOIN content_annotations ca ON ca.visit_id = v.id
                WHERE v.visit_time >= ? AND u.hidden = 0 AND (v.transition & 255) != 3
                  AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                """,
                """
                SELECT u.url, v.visit_time, 0, u.title FROM visits v JOIN urls u ON u.id = v.url
                WHERE v.visit_time >= ? AND u.hidden = 0 AND (v.transition & 255) != 3
                  AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                """,
            ] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, from)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)) else { continue }
                    let at = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1_000_000 - epoch)
                    let title = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
                    out.append((url, at, sqlite3_column_int(statement, 2) == 2, title))
                }
                break
            }
        }
        return out
    }
}

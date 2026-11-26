import AppKit
import Foundation
import SQLite3

// What you read, not only where you went. History (the JSON next door) is
// what the address field finishes from, and stays small and instant; this is
// what the history page lists and searches, every visit, and the words each
// page said, so a page can be found by what you remember of it.
//
// One SQLite file, one serial queue that owns it. Nothing here runs on the
// main thread but the calls that hand work to the queue.

final class Diary: @unchecked Sendable {
    static let shared = Diary(file: Diary.file)

    let queue = DispatchQueue(label: "yab.diary", qos: .utility)
    private let searchLock = NSLock()
    private var searchSerial: UInt64 = 0
    private var connection: SQLiteConnection?
    var db: OpaquePointer? { connection?.handle }

    /// The last visit each tab was written down at, so a page that moves on
    /// within a moment, a redirect, replaces it rather than joining it.
    private struct Last {
        var visit: Int64
        var key: String
        var at: Date
    }
    private var lasts: [UUID: Last] = [:]
    /// Pages whose sharing picture is being fetched, and who is waiting on it.
    private var looking: [String: [(String) -> Void]] = [:]
    /// Day threads (DiaryThreads.swift): the pass waiting for browsing to
    /// pause, what passes have cost, and the threads a name was asked for.
    let threadLock = NSLock()
    var threadPending: DispatchWorkItem?
    var threadStats = ThreadStats()
    var threadAsked = Set<Int64>()

    /// Where its SQLite file is: the store's, or a test's own.
    private let path: String

    private init(file: URL) {
        path = file.path
        queue.async { self.open() }
    }

    /// A diary of its own in another file, for tests: never the store's.
    static func scratch(_ file: URL) -> Diary { Diary(file: file) }

    // MARK: - the file

    private static var file: URL { Store.file("diary.sqlite") }
    static var shots: URL { Store.folder.appendingPathComponent("shots", isDirectory: true) }

    private func open() {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = SQLiteConnection(path: path, busyTimeout: 0)
        guard connection != nil else { return }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        // An earlier shape of the file is dropped rather than migrated: it
        // was never shipped.
        if meta("version") != "2" {
            exec("DROP TABLE IF EXISTS visits; DROP TABLE IF EXISTS trails; DROP TABLE IF EXISTS passages; DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS pages; DROP TABLE IF EXISTS words;")
            exec("DELETE FROM meta")
            setMeta("version", "2")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, key TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS visits_at ON visits(at);
        CREATE INDEX IF NOT EXISTS visits_key ON visits(key);
        CREATE TABLE IF NOT EXISTS pages(
          key TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', host TEXT NOT NULL,
          count INTEGER NOT NULL DEFAULT 0, last REAL NOT NULL, read REAL);
        CREATE INDEX IF NOT EXISTS pages_host ON pages(host);
        CREATE TABLE IF NOT EXISTS looks(key TEXT PRIMARY KEY, image TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS looks_image ON looks(image);
        CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(
          key UNINDEXED, kind UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2');
        """)
        makeThreads()
    }

    // MARK: - what a page is called

    /// One page, one key: the address without its scheme, its www, its
    /// fragment, or the parameters that only say where you came from. Two
    /// videos are two keys; the same article shared from two places is one.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let host = Diary.host(url)
        var path = parts.percentEncodedPath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let kept = (parts.queryItems ?? []).filter { !Diary.tracking($0.name) }
        parts.queryItems = kept.isEmpty ? nil : kept
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        return host + path + query
    }

    /// The address to hand someone: the page itself, without what only says
    /// who shared it and from where. Narrower than the key's list, since a
    /// copy has to still open the same page: `ref` is a branch on GitHub,
    /// `source` and `feature` can be the page's own. Otherwise untouched,
    /// fragment and encoding as they were.
    static func shareable(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.percentEncodedQueryItems else { return url }
        let decoded = parts.queryItems ?? []
        let kept = zip(items, decoded).filter { !Diary.sharing($0.1.name) }.map(\.0)
        guard kept.count < items.count else { return url }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    /// Names removed by the sharing cleaner, once each and in address order.
    static func sharingParameters(_ url: URL) -> [String] {
        var seen = Set<String>()
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).compactMap {
            sharing($0.name) && seen.insert($0.name.lowercased()).inserted ? $0.name : nil
        }
    }

    private static func sharing(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("utm_") { return true }
        return ["fbclid", "gclid", "dclid", "yclid", "msclkid", "igshid", "mc_cid", "mc_eid", "_ga", "_gl",
                "ref_src", "ref_url", "si"].contains(lower)
    }

    private static func tracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("utm_") { return true }
        return ["fbclid", "gclid", "dclid", "yclid", "msclkid", "igshid", "mc_cid", "mc_eid", "_ga", "_gl",
                "ref", "ref_src", "ref_url", "si", "feature", "share_id", "source", "campaign"].contains(lower)
    }

    /// The title without the unread count some sites hang on the front,
    /// "(340) YouTube" is YouTube.
    static func clean(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("("), let close = text.firstIndex(of: ")"),
              text[text.index(after: text.startIndex)..<close].allSatisfy({ $0.isNumber || $0 == "+" || $0 == "," }) {
            text = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// A page you sign in on, not one you go back to.
    static func isSignIn(_ url: URL) -> Bool {
        let host = Diary.host(url)
        let path = url.path().lowercased()
        if ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
            "auth.openai.com", "id.atlassian.com", "login.salesforce.com"].contains(host) { return true }
        if host.hasSuffix(".auth0.com") || host.hasSuffix(".okta.com") || host.hasPrefix("auth.") || host.hasPrefix("login.") || host.hasPrefix("sso.") { return true }
        for head in ["/login", "/signin", "/sign-in", "/sign_in", "/oauth", "/sso", "/auth/", "/session", "/logout", "/signout"] {
            if path == head.trimmingCharacters(in: CharacterSet(charactersIn: "/")) || path.hasPrefix(head) { return true }
        }
        return false
    }

    static func host(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - writing

    /// The first launch with a diary: everything the old history knew, once
    /// each at the last time it was seen. Nothing is lost by upgrading.
    /// `traces` is read on the main thread, and only that first time: the
    /// whole history, sorted, every launch, was work for nothing.
    func seed(_ traces: @escaping @MainActor () -> [History.Trace]) {
        queue.async {
            guard self.db != nil, self.meta("seeded") == nil else { return }
            DispatchQueue.main.async {
                let read = MainActor.assumeIsolated { traces() }
                self.queue.async {
                    guard self.meta("seeded") == nil else { return }
                    self.absorbNow(read)
                    self.setMeta("seeded", "1")
                }
            }
        }
    }

    /// Places that came from elsewhere, another browser's history, added
    /// where the diary has never heard of them.
    func absorb(_ traces: [History.Trace]) {
        queue.async { self.absorbNow(traces) }
    }

    /// Replace only the performance bench's pages, and report readiness
    /// after the serial SQLite queue has finished writing them.
    func seedBench(_ traces: [History.Trace], done: @escaping (Bool) -> Void) {
        queue.async {
            guard self.db != nil else { DispatchQueue.main.async { done(false) }; return }
            self.exec("DELETE FROM visits WHERE key LIKE 'omnibox-bench.invalid/%'")
            self.exec("DELETE FROM pages WHERE host = 'omnibox-bench.invalid'")
            self.exec("DELETE FROM words WHERE key LIKE 'omnibox-bench.invalid/%'")
            self.absorbNow(traces)
            DispatchQueue.main.async { done(true) }
        }
    }

    private func absorbNow(_ traces: [History.Trace]) {
        guard db != nil else { return }
        exec("BEGIN")
        for trace in traces where int("SELECT 1 FROM pages WHERE key = ?", [Diary.key(trace.url)]) == nil {
            guard !Diary.isSignIn(trace.url) else { continue }
            write(trace.url, title: trace.title, at: trace.last, count: max(1, trace.count))
        }
        exec("COMMIT")
    }

    func closed(_ tab: UUID) {
        queue.async { self.lasts[tab] = nil }
    }

    /// When each of these pages was last seen, for a list that says so,
    /// on the main thread; a page never written down has no entry.
    func lastSeen(_ urls: [URL], done: @escaping ([String: Date]) -> Void) {
        queue.async {
            var seen: [String: Date] = [:]
            if self.db != nil {
                for url in urls {
                    let key = Diary.key(url)
                    if let last = self.double("SELECT last FROM pages WHERE key = ?", [key]) {
                        seen[key] = Date(timeIntervalSince1970: last)
                    }
                }
            }
            DispatchQueue.main.async { done(seen) }
        }
    }

    /// A page landed in a tab, in a space. `quiet`: an agent's at work in
    /// it, a visit for History but never for your day's threads.
    func visit(_ url: URL, title: String, tab: UUID, space: UUID? = nil, quiet: Bool = false) {
        let now = Date()
        guard url.scheme == "http" || url.scheme == "https", !Diary.isSignIn(url) else { return }
        queue.async {
            guard self.db != nil else { return }
            let key = Diary.key(url)
            if let last = self.lasts[tab], now.timeIntervalSince(last.at) < 1.2, last.key != key {
                // Gone again within moments, a redirect, a page that sends
                // you on: the place you ended up is the visit.
                self.run("DELETE FROM visits WHERE id = ?", [last.visit])
                self.run("UPDATE pages SET count = count - 1 WHERE key = ?", [last.key])
                self.run("DELETE FROM pages WHERE key = ? AND count <= 0", [last.key])
                if self.int("SELECT 1 FROM pages WHERE key = ?", [last.key]) == nil {
                    self.run("DELETE FROM words WHERE key = ?", [last.key])
                }
            } else if let last = self.lasts[tab], last.key == key, now.timeIntervalSince(last.at) < 10 * 60 {
                // The same page again, a reload, a hash change: one visit.
                self.run("UPDATE visits SET at = ? WHERE id = ?", [now.timeIntervalSince1970, last.visit])
                self.run("UPDATE pages SET last = ? WHERE key = ?", [now.timeIntervalSince1970, key])
                self.lasts[tab]?.at = now
                return
            }
            let id = self.write(url, title: title, at: now, count: 1)
            self.run("UPDATE visits SET space = ?, quiet = ? WHERE id = ?", [space?.uuidString ?? "", quiet ? 1 : 0, id])
            self.lasts[tab] = Last(visit: id, key: key, at: now)
            self.threadSoon()
        }
    }

    @discardableResult
    func write(_ url: URL, title: String, at: Date, count: Int) -> Int64 {
        let key = Diary.key(url)
        let title = Diary.clean(title)
        run("INSERT INTO visits(key, at) VALUES(?, ?)", [key, at.timeIntervalSince1970])
        let id = sqlite3_last_insert_rowid(db)
        run("""
        INSERT INTO pages(key, url, title, host, count, last) VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET url = excluded.url, count = count + excluded.count,
          last = MAX(last, excluded.last), title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
        """, [key, url.absoluteString, title, Diary.host(url), count, at.timeIntervalSince1970])
        name(key, title: string("SELECT title FROM pages WHERE key = ?", [key]) ?? title, url: url)
        return id
    }

    func retitle(_ url: URL, _ title: String) {
        let title = Diary.clean(title)
        guard !title.isEmpty else { return }
        queue.async {
            guard self.db != nil else { return }
            let key = Diary.key(url)
            guard self.int("SELECT 1 FROM pages WHERE key = ?", [key]) != nil else { return }
            self.run("UPDATE pages SET title = ? WHERE key = ?", [title, key])
            self.name(key, title: title, url: url)
        }
    }

    /// The page's name and address, searchable from the first visit.
    private func name(_ key: String, title: String, url: URL) {
        run("DELETE FROM words WHERE key = ? AND kind = 0", [key])
        run("INSERT INTO words(key, kind, title, body) VALUES(?, 0, ?, ?)", [key, title, Address.pretty(url)])
    }

    /// Whether the words on this page are worth reading again now. A page
    /// read in the last few hours hasn't changed enough to matter.
    func wantsText(for url: URL, done: @escaping (Bool) -> Void) {
        let key = Diary.key(url)
        queue.async {
            let read = self.double("SELECT read FROM pages WHERE key = ?", [key])
            let fresh = read.map { Date().timeIntervalSince1970 - $0 < 6 * 3600 } ?? false
            DispatchQueue.main.async { done(!fresh) }
        }
    }

    /// What the page said, cut into passages a search can point into.
    func read(_ url: URL, text: String) {
        let key = Diary.key(url)
        queue.async {
            guard self.db != nil, self.int("SELECT 1 FROM pages WHERE key = ?", [key]) != nil else { return }
            self.exec("BEGIN")
            self.run("DELETE FROM words WHERE key = ? AND kind = 1", [key])
            for body in Diary.passages(of: text) {
                self.run("INSERT INTO words(key, kind, title, body) VALUES(?, 1, '', ?)", [key, body])
            }
            self.run("UPDATE pages SET read = ? WHERE key = ?", [Date().timeIntervalSince1970, key])
            self.exec("COMMIT")
        }
    }

    /// A page's text in passages of about a paragraph or two, the first dozen
    /// the top of a page is what it is about.
    static func passages(of text: String) -> [String] {
        let paragraphs = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 40 }
        var out: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.count + paragraph.count > 700, !current.isEmpty {
                out.append(current)
                current = ""
                if out.count == 12 { break }
            }
            current += (current.isEmpty ? "" : "\n") + String(paragraph.prefix(1400))
        }
        if !current.isEmpty, out.count < 12 { out.append(current) }
        return out
    }

    /// A picture of the page, small, for the row it belongs to.
    func keep(_ image: NSImage, for url: URL) {
        let key = Diary.key(url)
        queue.async {
            guard let jpeg = Diary.jpeg(image, width: 640) else { return }
            try? FileManager.default.createDirectory(at: Diary.shots, withIntermediateDirectories: true)
            try? jpeg.write(to: Diary.shot(key), options: .atomic)
        }
    }

    /// The pictures are a row's face on the history page, not a record: past
    /// `shotsLimit` the ones not taken again longest go, and those rows show
    /// their icon. Before, the folder only grew, a picture for every page
    /// ever seen (#685).
    static let shotsLimit = 150 * 1_000_000

    func trimShots(limit: Int = Diary.shotsLimit, then done: @escaping (Int) -> Void = { _ in }) {
        queue.async { done(Diary.trim(Diary.shots, to: limit)) }
    }

    /// Oldest first until the folder is under `limit` bytes; how many went.
    static func trim(_ folder: URL, to limit: Int) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var rows: [(url: URL, at: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0)
        }
        var total = rows.reduce(0) { $0 + $1.size }
        guard total > limit else { return 0 }
        rows.sort { $0.at < $1.at }
        var gone = 0
        for row in rows where total > limit {
            guard (try? FileManager.default.removeItem(at: row.url)) != nil else { continue }
            total -= row.size
            gone += 1
        }
        return gone
    }

    /// The last visit to each host the diary knows, nil without a diary.
    func lastVisits(then done: @escaping ([String: Date]?) -> Void) {
        queue.async {
            guard self.db != nil else { return DispatchQueue.main.async { done(nil) } }
            var out: [String: Date] = [:]
            for row in self.query("SELECT host, MAX(last) FROM pages GROUP BY host", []) {
                guard row.count == 2, let host = row[0] as? String, let at = row.double(1) else { continue }
                out[host] = Date(timeIntervalSince1970: at)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Whether the picture of this page is old enough to take again.
    func wantsShot(for url: URL) -> Bool {
        let file = Diary.shot(Diary.key(url))
        guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return true }
        return Date().timeIntervalSince(stamp) > 86_400
    }

    // MARK: - forgetting

    func forget(keys: [String], then done: (() -> Void)? = nil) {
        queue.async {
            self.drop(keys: keys)
            DispatchQueue.main.async { done?() }
        }
    }

    /// Pages forgotten so ⌘Z can bring them back: every row the diary had
    /// of them and their pictures, held until the undo is gone.
    struct Taken: @unchecked Sendable {
        var pages: [[Any?]] = []
        var visits: [[Any?]] = []
        var looks: [[Any?]] = []
        var words: [[Any?]] = []
        var files: [(URL, Data)] = []
        /// A thread forgotten whole (`take(thread:)`), and what was done on its pages.
        var threads: [[Any?]] = []
        var acts: [[Any?]] = []
        var count: Int { pages.count }
    }

    /// Forget these pages, handing back what they were (`giveBack`).
    func take(keys: [String], then done: @escaping (Taken) -> Void) {
        queue.async {
            var taken = Taken()
            if self.db != nil {
                for key in keys {
                    taken.pages += self.query("SELECT key, url, title, host, count, last, read FROM pages WHERE key = ?", [key]).map(\.values)
                    taken.visits += self.query("SELECT id, key, at, space, quiet, thread FROM visits WHERE key = ?", [key]).map(\.values)
                    taken.acts += self.query("SELECT key, at, kind, words FROM acts WHERE key = ?", [key]).map(\.values)
                    taken.looks += self.query("SELECT key, image FROM looks WHERE key = ?", [key]).map(\.values)
                    taken.words += self.query("SELECT key, kind, title, body FROM words WHERE key = ?", [key]).map(\.values)
                    for file in [Diary.shot(key), Diary.og(key)] {
                        if let data = try? Data(contentsOf: file) { taken.files.append((file, data)) }
                    }
                }
                self.drop(keys: keys)
            }
            DispatchQueue.main.async { done(taken) }
        }
    }

    /// What `take` forgot, as it was. A page seen again since keeps its
    /// new visits; the old ones join them.
    func giveBack(_ taken: Taken, then done: (() -> Void)? = nil) {
        queue.async {
            guard self.db != nil else { return DispatchQueue.main.async { done?() } }
            func args(_ row: [Any?]) -> [Any] { row.map { $0 ?? NSNull() } }
            // A page seen again since already has its words.
            let had = Set(taken.pages.compactMap { ($0.first ?? nil) as? String }.filter { self.int("SELECT 1 FROM pages WHERE key = ?", [$0]) != nil })
            self.exec("BEGIN")
            for row in taken.pages {
                self.run("""
                INSERT INTO pages(key, url, title, host, count, last, read) VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET count = count + excluded.count, last = MAX(last, excluded.last)
                """, args(row))
            }
            for row in taken.threads {
                self.run("INSERT OR IGNORE INTO threads(id, day, space, start, end, topic, name, done, summary, named, hue) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", args(row))
            }
            for row in taken.visits {
                self.run("INSERT OR IGNORE INTO visits(id, key, at, space, quiet, thread) VALUES(?, ?, ?, ?, COALESCE(?, 0), ?)", args(row))
            }
            for row in taken.acts {
                guard self.int("SELECT 1 FROM acts WHERE key = ? AND at = ? AND kind = ?", [row[0] ?? NSNull(), row[1] ?? NSNull(), row[2] ?? NSNull()]) == nil else { continue }
                self.run("INSERT INTO acts(key, at, kind, words) VALUES(?, ?, ?, ?)", args(row))
            }
            for row in taken.looks { self.run("INSERT OR REPLACE INTO looks(key, image) VALUES(?, ?)", args(row)) }
            for row in taken.words where !had.contains((row.first ?? nil) as? String ?? "") { self.run("INSERT INTO words(key, kind, title, body) VALUES(?, ?, ?, ?)", args(row)) }
            self.exec("COMMIT")
            for (file, data) in taken.files where !FileManager.default.fileExists(atPath: file.path) {
                try? data.write(to: file, options: .atomic)
            }
            DispatchQueue.main.async { done?() }
        }
    }

    /// Everything from one site. Hands back the addresses, so the address
    /// field's own history can forget them too.
    func forget(host: String, then done: @escaping ([URL]) -> Void) {
        queue.async {
            let keys = self.strings("SELECT key FROM pages WHERE host = ?", [host])
            let urls = self.strings("SELECT url FROM pages WHERE host = ?", [host]).compactMap(URL.init(string:))
            self.drop(keys: keys)
            DispatchQueue.main.async { done(urls) }
        }
    }

    /// Everything since a moment, the last hour, today. A page also seen
    /// before it stays, as it was then: its later visits go, and whatever
    /// was read or pictured of it since. A page seen only since goes whole.
    func forget(since: Date, then done: @escaping () -> Void) {
        queue.async {
            guard self.db != nil else { return DispatchQueue.main.async(execute: done) }
            let at = since.timeIntervalSince1970
            let touched = self.query("SELECT key, COUNT(*) FROM visits WHERE at >= ? GROUP BY key", [at])
            var gone: [String] = []
            self.exec("BEGIN")
            self.run("DELETE FROM visits WHERE at >= ?", [at])
            self.run("DELETE FROM acts WHERE at >= ?", [at])
            self.run("DELETE FROM threads WHERE end >= ?", [at])
            for row in touched {
                guard let key = row[0] as? String else { continue }
                guard let before = self.double("SELECT MAX(at) FROM visits WHERE key = ?", [key]) else {
                    gone.append(key)
                    continue
                }
                self.run("UPDATE pages SET last = ?, count = MAX(1, count - ?) WHERE key = ?", [before, row[1] as? Int64 ?? 0, key])
                if (self.double("SELECT read FROM pages WHERE key = ?", [key]) ?? 0) >= at {
                    self.run("DELETE FROM words WHERE key = ? AND kind = 1", [key])
                    self.run("UPDATE pages SET read = NULL WHERE key = ?", [key])
                }
                for file in [Diary.shot(key), Diary.og(key)] {
                    let made = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let made, made >= since { try? FileManager.default.removeItem(at: file) }
                }
            }
            self.exec("COMMIT")
            self.drop(keys: gone)
            self.lasts = self.lasts.filter { $0.value.at < since }
            self.rethreadNow(Date())
            DispatchQueue.main.async(execute: done)
        }
    }

    func forgetEverything() {
        queue.async {
            // Deleted means gone from the file too, freed pages and the log.
            self.exec("PRAGMA secure_delete=ON")
            self.exec("DELETE FROM visits; DELETE FROM pages; DELETE FROM words; DELETE FROM looks; DELETE FROM threads; DELETE FROM acts;")
            self.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            self.exec("PRAGMA secure_delete=OFF")
            self.lasts.removeAll()
            try? FileManager.default.removeItem(at: Diary.shots)
        }
    }

    func drop(keys: [String]) {
        guard db != nil, !keys.isEmpty else { return }
        exec("BEGIN")
        for key in keys {
            run("DELETE FROM acts WHERE key = ?", [key])
            run("DELETE FROM words WHERE key = ?", [key])
            run("DELETE FROM visits WHERE key = ?", [key])
            run("DELETE FROM pages WHERE key = ?", [key])
            run("DELETE FROM looks WHERE key = ?", [key])
            try? FileManager.default.removeItem(at: Diary.shot(key))
            try? FileManager.default.removeItem(at: Diary.og(key))
        }
        // A thread left with no visits is no thread; one left with a page
        // is let go at its day's next pass.
        exec("DELETE FROM threads WHERE id NOT IN (SELECT DISTINCT thread FROM visits WHERE thread IS NOT NULL)")
        exec("COMMIT")
        lasts = lasts.filter { !keys.contains($0.value.key) }
    }

    // MARK: - reading back: the list

    /// Pages, newest first, one row per page per day. `before` pages back,
    /// through the index on when: a page of rows costs the same however long
    /// the history is. A page whose day straddles the cut comes back once
    /// more with its earlier visits; the history page drops the second.
    /// `from`, `to` and `host` keep it to a span of time or one site, what
    /// the page's rail picks.
    func list(
        before: Double?, from: Double? = nil, to: Double? = nil, host: String? = nil,
        limit: Int = 60, done: @escaping ([[String: Any]]) -> Void
    ) {
        queue.async {
            guard self.db != nil else { return DispatchQueue.main.async { done([]) } }
            var scope = ""
            var args: [Any] = [min(before ?? .greatestFiniteMagnitude, to ?? .greatestFiniteMagnitude)]
            if let from { scope += " AND v.at >= ?"; args.append(from) }
            if let host { scope += " AND p.host = ?"; args.append(host) }
            let rows = self.query("""
            SELECT v.key, MAX(v.at), COUNT(*), p.url, p.title, p.host
            FROM visits v JOIN pages p ON p.key = v.key
            WHERE v.at < ?\(scope)
            GROUP BY v.key, date(v.at, 'unixepoch', 'localtime')
            ORDER BY MAX(v.at) DESC LIMIT ?
            """, args + [limit])
            let out = rows.map { self.item($0) }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// What the page's rail shows: how much there is in each span of time,
    /// and the sites you have gone to most this past month, each counted
    /// the way the list lists, a page once a day.
    func outline(done: @escaping ([String: Any]) -> Void) {
        queue.async {
            guard self.db != nil else { return DispatchQueue.main.async { done([:]) } }
            let perDay = "GROUP BY v.key, date(v.at, 'unixepoch', 'localtime')"
            func count(_ scope: String, _ args: [Any]) -> Int64 {
                self.int("SELECT COUNT(*) FROM (SELECT 1 FROM visits v JOIN pages p ON p.key = v.key WHERE 1\(scope) \(perDay))", args) ?? 0
            }
            let spans: [[String: Any]] = Diary.spans().filter(\.listed).map { span in
                let to = span.to?.timeIntervalSince1970
                var out: [String: Any] = [
                    "label": span.label,
                    "word": span.words[0],
                    "from": span.from.timeIntervalSince1970,
                    "n": count(" AND v.at >= ? AND v.at < ?", [span.from.timeIntervalSince1970, to ?? .greatestFiniteMagnitude]),
                ]
                if let to { out["to"] = to }
                return out
            }
            let month = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
            let sites: [[String: Any]] = self.strings("""
            SELECT p.host FROM visits v JOIN pages p ON p.key = v.key
            WHERE v.at >= ? AND p.host != '' GROUP BY p.host ORDER BY COUNT(*) DESC LIMIT 6
            """, [month]).map { ["host": $0, "n": count(" AND p.host = ?", [$0])] }
            let out: [String: Any] = [
                "all": count("", []),
                "hour": count(" AND v.at >= ?", [Date().addingTimeInterval(-3600).timeIntervalSince1970]),
                "spans": spans,
                "sites": sites,
                "since": (self.double("SELECT MIN(at) FROM visits", []) ?? 0) * 1000,
            ]
            DispatchQueue.main.async { done(out) }
        }
    }

    private func item(_ row: SQLiteRow) -> [String: Any] {
        let key = row[0] as? String ?? ""
        return [
            "key": key,
            "at": (row[1] as? Double ?? 0) * 1000,
            "count": row[2] as? Int64 ?? 1,
            "url": row[3] as? String ?? "",
            "title": row[4] as? String ?? "",
            "host": row[5] as? String ?? "",
            "shot": Diary.link(key),
        ]
    }

    // MARK: - reading back: search

    struct Filter {
        var from: Date?
        var to: Date?
        var host: String?
        var chips: [String] = []
        var words: String
    }

    /// The words, looked for in what pages are called and, once there are
    /// two of them, in what pages said. When and where narrow it down.
    /// What the words find, as lines for the agent answering a question
    /// in the field (SelectionCommands): the title, the address, the day
    /// and the passage. Never overtaken by the History place's searches,
    /// as `search` is.
    func found(_ words: String, limit: Int = 8) async -> String {
        await withCheckedContinuation { done in
            queue.async {
                let rows = (self.searchNow(words)["results"] as? [[String: Any]] ?? []).prefix(limit)
                let lines = rows.compactMap { row -> String? in
                    guard let url = row["url"] as? String, !url.isEmpty else { return nil }
                    let day = Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000).englishFormatted(date: .abbreviated, time: .omitted)
                    let passage = (row["passage"] as? String)?.replacingOccurrences(of: "\u{2}", with: "")
                        .replacingOccurrences(of: "\u{3}", with: "").replacingOccurrences(of: "\n", with: " ")
                    return "- \(row["title"] as? String ?? "") · \(url) · \(day)" + (passage.map { $0.isEmpty ? "" : " · \u{201C}\($0)\u{201D}" } ?? "")
                }
                done.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// What the words find, as rows (`search`'s keys), for the field's
    /// requests (FieldRequest): never overtaken by the History place's
    /// searches, as `search` is.
    func pages(_ words: String, limit: Int = 8) async -> [Hit] {
        await withCheckedContinuation { done in
            queue.async {
                let rows = (self.searchNow(words)["results"] as? [[String: Any]] ?? []).prefix(limit)
                done.resume(returning: rows.compactMap { row in
                    guard let url = row["url"] as? String, !url.isEmpty else { return nil }
                    let passage = (row["passage"] as? String).map {
                        $0.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
                            .replacingOccurrences(of: "\u{3}", with: "").replacingOccurrences(of: "\n", with: " ")
                    }
                    return Hit(key: row["key"] as? String ?? url, url: url, title: row["title"] as? String ?? "",
                               host: row["host"] as? String ?? "", at: Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000),
                               passage: passage?.isEmpty == false ? passage : nil)
                })
            }
        }
    }

    /// A page the words found.
    struct Hit: Sendable, Equatable {
        let key: String
        let url: String
        let title: String
        let host: String
        let at: Date
        let passage: String?
    }

    func search(_ typed: String, done: @escaping ([String: Any]) -> Void) {
        searchLock.lock()
        searchSerial &+= 1
        let serial = searchSerial
        searchLock.unlock()
        queue.async {
            self.searchLock.lock()
            let latest = serial == self.searchSerial
            self.searchLock.unlock()
            guard latest else { return }
            let result = self.searchNow(typed)
            DispatchQueue.main.async { done(result) }
        }
    }

    private func searchNow(_ typed: String) -> [String: Any] {
        guard db != nil else { return ["results": []] }
        let filter = self.filter(typed)
        let terms = Diary.terms(filter.words)
        // A description, as opposed to a name: enough words to read the
        // page's text for.
        let deep = terms.count >= 2

        var clauses: [String] = []
        var args: [Any] = []
        if let from = filter.from { clauses.append("p.last >= ?"); args.append(from.timeIntervalSince1970) }
        if let to = filter.to { clauses.append("p.last < ?"); args.append(to.timeIntervalSince1970) }
        if let host = filter.host { clauses.append("(p.host = ? OR p.host LIKE ?)"); args += [host, "%." + host] }
        let scope = clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND ")

        var rows: [SQLiteRow]
        if terms.isEmpty {
            // Only a when or a where: everything in it, newest first.
            rows = query("SELECT p.key, p.url, p.title, p.host, p.last, p.count, '', 0, 0 FROM pages p WHERE 1" + scope + " ORDER BY p.last DESC LIMIT 60", args)
        } else {
            let quoted = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
            let all = quoted.joined(separator: " AND ")
            let any = quoted.joined(separator: " OR ")
            let kinds = deep ? "" : " AND kind = 0"
            func hits(_ match: String) -> [SQLiteRow] {
                // The words first, on their own: FTS5 ranks only in a plain
                // query over its table. The pages join what it found.
                query("""
                SELECT p.key, p.url, p.title, p.host, p.last, p.count,
                  MAX(CASE WHEN w.kind = 1 THEN w.line ELSE '' END), MIN(w.rank), MIN(w.kind)
                FROM (
                  SELECT key, kind, bm25(words, 0, 0, 10.0, 1.0) AS rank,
                    snippet(words, 3, '\u{1}', '\u{2}', '…', 22) AS line
                  FROM words WHERE words MATCH ?\(kinds) ORDER BY rank LIMIT 400
                ) w JOIN pages p ON p.key = w.key
                WHERE 1\(scope) GROUP BY p.key ORDER BY MIN(w.rank) LIMIT 120
                """, [match] + args)
            }
            rows = hits(all)
            if terms.count > 1, rows.count < 8 {
                let seen = Set(rows.compactMap { $0[0] as? String })
                rows += hits(any).filter { !seen.contains($0[0] as? String ?? "") }
            }
        }

        let now = Date().timeIntervalSince1970
        var scored: [(Double, [String: Any])] = []
        for row in rows {
            let key = row[0] as? String ?? ""
            let title = row[2] as? String ?? ""
            let last = row[4] as? Double ?? 0
            let count = Double(row[5] as? Int64 ?? 1)
            let days = max(0, now - last) / 86_400
            var score = terms.isEmpty ? last : -(row[7] as? Double ?? 0)
            if !terms.isEmpty {
                // Named by its title from the first letter: what a short
                // query nearly always means.
                if let first = terms.first, title.lowercased().hasPrefix(first) { score += 3 }
                if (row[8] as? Int64) == 0 { score += 1 }
                score += 0.4 * log(1 + count) + 1.5 * exp(-days / 30)
            }
            var item: [String: Any] = [
                "key": key,
                "url": row[1] as? String ?? "",
                "title": title,
                "host": row[3] as? String ?? "",
                "at": last * 1000,
                "count": Int(count),
                "shot": Diary.link(key),
            ]
            if let snippet = row[6] as? String, !snippet.isEmpty { item["passage"] = snippet }
            scored.append((score, item))
        }
        scored.sort { $0.0 > $1.0 }
        return [
            "results": Array(scored.prefix(60).map(\.1)),
            "chips": filter.chips,
            "terms": terms,
        ]
    }

    // MARK: - the picture a page offers

    /// A page never seen here, opened behind, or before pictures were kept,
    /// or brought in from another browser, still has the picture it offers
    /// for sharing. `image` is its address when the page named it while it
    /// was open; otherwise the page is read again, its HTML only, with no
    /// cookies and no scripts: the site sees a stranger, not you. Once per
    /// page, a page that offers none is not asked again. Hands back the
    /// picture's link, or "" when there is none to be had.
    func look(key: String, url: URL, image: URL? = nil, done: @escaping (String) -> Void) {
        queue.async {
            let finish = { (link: String) in DispatchQueue.main.async { done(link) } }
            guard self.db != nil, !Diary.isSignIn(url) else { return finish("") }
            if FileManager.default.fileExists(atPath: Diary.og(key).path) { return finish(Diary.link(key)) }
            if image == nil, self.string("SELECT image FROM looks WHERE key = ?", [key]) != nil { return finish("") }
            self.looking[key, default: []].append(done)
            guard self.looking[key]?.count == 1 else { return }
            let answer = { (link: String) in
                self.queue.async {
                    let waiting = self.looking.removeValue(forKey: key) ?? []
                    DispatchQueue.main.async { waiting.forEach { $0(link) } }
                }
            }
            if let image { return self.fetch(image, for: key, then: answer) }
            var request = URLRequest(url: url)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            Diary.fetcher.dataTask(with: request) { data, response, _ in
                // A failure, offline, a timeout, a site turning strangers
                // away, is not remembered: another time it may answer.
                guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html")
                else { return answer("") }
                let html = String(decoding: data.prefix(1_500_000), as: UTF8.self)
                guard let found = Diary.sharingImage(in: html, of: http.url ?? url) else {
                    self.queue.async { self.run("INSERT OR REPLACE INTO looks(key, image) VALUES(?, '')", [key]) }
                    return answer("")
                }
                self.fetch(found, for: key, then: answer)
            }.resume()
        }
    }

    private func fetch(_ image: URL, for key: String, then done: @escaping (String) -> Void) {
        queue.async {
            // The same picture on a third page of one site is the site's, not
            // the page's, its logo, and says nothing about any of them.
            let address = image.absoluteString
            let others = self.strings("""
            SELECT l.key FROM looks l JOIN pages p ON p.key = l.key
            WHERE l.image = ? AND l.key != ? AND p.host = (SELECT host FROM pages WHERE key = ?)
            """, [address, key, key])
            self.run("INSERT OR REPLACE INTO looks(key, image) VALUES(?, ?)", [key, address])
            if others.count >= 2 {
                others.forEach { try? FileManager.default.removeItem(at: Diary.og($0)) }
                return done("")
            }
            Diary.fetcher.dataTask(with: image) { data, _, _ in
                // Too small to be a picture of anything, an icon, and the
                // card with the site's icon says that better.
                guard let data, data.count < 8_000_000, let picture = NSImage(data: data),
                      (picture.representations.first?.pixelsWide ?? 0) >= 400,
                      let jpeg = Diary.jpeg(picture, width: 640)
                else { return done("") }
                self.queue.async {
                    // Forgotten while it was on its way: not kept.
                    guard self.string("SELECT key FROM looks WHERE key = ?", [key]) != nil else { return done("") }
                    try? FileManager.default.createDirectory(at: Diary.shots, withIntermediateDirectories: true)
                    try? jpeg.write(to: Diary.og(key), options: .atomic)
                    done(Diary.link(key))
                }
            }.resume()
        }
    }

    /// Asks as a plain browser would, and remembers nothing it is told.
    private static let fetcher: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + Web.userAgentName,
        ]
        return URLSession(configuration: config)
    }()

    /// The sharing picture a page's HTML names, as an address.
    static func sharingImage(in html: String, of page: URL) -> URL? {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        let text = head as NSString
        var named: [String: String] = [:]
        for tag in metaTag.matches(in: head, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: tag.range) as NSString
            var name = "", content = ""
            for pair in attribute.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let quoted = pair.range(at: 2).location != NSNotFound ? pair.range(at: 2) : pair.range(at: 3)
                let value = tag.substring(with: quoted)
                switch tag.substring(with: pair.range(at: 1)).lowercased() {
                case "property", "name": name = value.lowercased()
                case "content": content = value
                default: break
                }
            }
            if !name.isEmpty, !content.isEmpty, named[name] == nil { named[name] = content }
        }
        for name in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            guard let raw = named[name] else { continue }
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
            if let url = URL(string: cleaned, relativeTo: page)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") {
                return url
            }
        }
        return nil
    }

    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: "([a-zA-Z:_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")

    // MARK: - words

    /// When and where, taken out of what was typed.
    private func filter(_ typed: String) -> Filter {
        var words = " " + typed.lowercased() + " "
        var filter = Filter(words: "")
        spanLoop: for (phrases, label, from, to, _) in Diary.spans() {
            for phrase in phrases where words.contains(" \(phrase) ") {
                words = words.replacingOccurrences(of: " \(phrase) ", with: " ")
                filter.from = from
                filter.to = to
                filter.chips.append(label)
                break spanLoop
            }
        }

        // "on github", "from github.com", "site:github.com"
        let tokens = words.split(separator: " ").map(String.init)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("site:"), token.count > 5 {
                filter.host = String(token.dropFirst(5))
            } else if ["on", "at", "from"].contains(token), index + 1 < tokens.count,
                      let host = knownHost(tokens[index + 1]) {
                filter.host = host
                index += 1
            } else {
                kept.append(token)
            }
            index += 1
        }
        if let host = filter.host { filter.chips.append(host) }
        filter.words = kept.joined(separator: " ")
        return filter
    }

    /// The spans of time words can name, from now. The listed ones are also
    /// the page's rail; the first word of each is how the rail asks for it.
    private static func spans() -> [(words: [String], label: String, from: Date, to: Date?, listed: Bool)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        let week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? day(-7)
        let month = calendar.dateInterval(of: .month, for: Date())?.start ?? day(-30)
        return [
            (["today"], "Today", today, nil, true),
            (["yesterday"], "Yesterday", day(-1), today, true),
            (["this week"], "This week", week, nil, true),
            (["last week"], "Last week", calendar.date(byAdding: .day, value: -7, to: week)!, week, true),
            (["this month"], "This month", month, nil, false),
            (["last month"], "Last month", calendar.date(byAdding: .month, value: -1, to: month)!, month, false),
            (["recently"], "Recently", day(-3), nil, false),
        ]
    }

    /// A word after "on" that names a site: a domain, or the first part of
    /// one you have actually been to.
    private func knownHost(_ word: String) -> String? {
        if word.contains(".") { return word.hasPrefix("www.") ? String(word.dropFirst(4)) : word }
        guard word.count >= 3 else { return nil }
        return string("SELECT host FROM pages WHERE host LIKE ? GROUP BY host ORDER BY SUM(count) DESC LIMIT 1", [word + ".%"])
    }

    /// Words that say nothing about which page: the ones a description is
    /// made of around its nouns.
    private static let stop: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "at", "by", "as", "and", "or", "but", "if", "so", "that", "this",
        "these", "those", "about", "with", "for", "from", "into", "over", "under", "up", "down", "out", "was", "is",
        "are", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "done", "can", "could",
        "should", "would", "will", "may", "might", "not", "no", "yes", "it", "its", "i", "me", "my", "we", "our",
        "you", "your", "he", "she", "they", "them", "their", "his", "her", "who", "what", "when", "where", "which",
        "why", "how", "some", "any", "all", "each", "one", "ones", "only", "just", "very", "more", "most", "also",
        "like", "than", "then", "there", "here", "thing", "things", "page", "article", "site", "post", "video",
        "read", "saw", "seen", "found", "turn", "get", "got", "use", "used", "make", "made", "said", "says",
    ]

    static func terms(_ words: String) -> [String] {
        let all = Wording.split(words.lowercased()).map(String.init).filter { !$0.isEmpty }
        // Little words are dropped only when there is something left.
        let kept = all.filter { $0.count >= 3 && !stop.contains($0) }
        return kept.isEmpty ? all : kept
    }

    // MARK: - little things

    static func shot(_ key: String) -> URL {
        // FNV-1a: stable from launch to launch, which hashValue is not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return shots.appendingPathComponent(String(hash, radix: 16) + ".jpg")
    }

    /// The picture's address for the history page, or nothing.
    /// The page's picture for the history page: what it looked like when you
    /// were on it, or else the one it offers for sharing.
    static func link(_ key: String) -> String {
        for file in [shot(key), og(key)] where FileManager.default.fileExists(atPath: file.path) {
            return "yab://shot/" + file.lastPathComponent
        }
        return ""
    }

    static func og(_ key: String) -> URL {
        shot(key).deletingPathExtension().appendingPathExtension("og.jpg")
    }

    private static func jpeg(_ image: NSImage, width: CGFloat) -> Data? {
        guard image.size.width > 0 else { return nil }
        let height = (image.size.height * width / image.size.width).rounded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(min(height, width * 0.66)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The top of the page, cropped: what you saw first is what you remember.
        let shown = NSRect(x: 0, y: CGFloat(rep.pixelsHigh) - height, width: width, height: height)
        image.draw(in: shown, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    // MARK: - SQL

    func meta(_ key: String) -> String? { string("SELECT v FROM meta WHERE k = ?", [key]) }
    func setMeta(_ key: String, _ value: String) { run("INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)", [key, value]) }

    func exec(_ sql: String) { _ = connection?.exec(sql) }

    func run(_ sql: String, _ args: [Any]) { _ = connection?.run(sql, args) }

    func query(_ sql: String, _ args: [Any]) -> [SQLiteRow] { connection?.query(sql, args) ?? [] }

    func string(_ sql: String, _ args: [Any]) -> String? { query(sql, args).first?.first as? String }
    func double(_ sql: String, _ args: [Any]) -> Double? { query(sql, args).first?.first as? Double }
    func int(_ sql: String, _ args: [Any]) -> Int64? { query(sql, args).first?.first as? Int64 }
    func strings(_ sql: String, _ args: [Any]) -> [String] { query(sql, args).compactMap { $0.first as? String } }
}

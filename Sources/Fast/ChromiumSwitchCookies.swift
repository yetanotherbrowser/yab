import CryptoKit
import Foundation
import WebKit
import YabCoreClient

/// A restart must distinguish a sign-out from a cookie that has never been
/// imported. Persist only fingerprints, never a second copy of sign-in values.
/// Each side holds what that jar really held when last read: a cookie Chromium
/// refused is on the WebKit side alone.
struct ChromiumSwitchCookieLedger: Codable, Equatable {
    var webKit: [String: String]
    var chromium: [String: String]
    /// The WebKit jar has been brought over once. It never is again.
    var imported: Bool?
    /// Chromium's copies that end with its helper, unlike its lasting ones.
    var session: [String]?

    init(webKit: [String: String], chromium: [String: String]) {
        self.webKit = webKit; self.chromium = chromium
    }

    /// "<value>:<cookie>": a short hash of the value alone, then of the whole
    /// cookie. The whole says whether a side changed; the value part says which
    /// value a side moved away from, so a renewal of it (a new expiry) is known
    /// for the old session it is. Ledgers before November 2026 hold the whole alone.
    static func fingerprint(_ cookie: ChromiumDRMCookie, encoder: JSONEncoder? = nil) -> String {
        let encoder = encoder ?? {
            let made = JSONEncoder()
            made.outputFormatting = [.sortedKeys]
            return made
        }()
        // All fields have a fixed Codable representation.
        let bytes = (try? encoder.encode(cookie)) ?? Data()
        return valuePrint(cookie.value) + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func valuePrint(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The whole cookie's part, in either format.
    static func whole(_ print: String?) -> String? {
        guard let print else { return nil }
        guard let colon = print.firstIndex(of: ":") else { return print }
        return String(print[print.index(after: colon)...])
    }

    /// The value's part, if the ledger has one.
    static func value(_ print: String?) -> String? {
        guard let print, let colon = print.firstIndex(of: ":") else { return nil }
        return String(print[..<colon])
    }

    static func fingerprint(_ cookies: [String: ChromiumDRMCookie]) -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return cookies.mapValues { fingerprint($0, encoder: encoder) }
    }

    static func file(profile: String, store: UUID?) -> URL {
        let identity = profile + ":" + (store?.uuidString ?? "default")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Store.file("engine-cookies").appendingPathComponent(name + ".json")
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// What the addresses of one host can see. A read by address leaves out a
/// cookie on another path, so only what the read covers can look deleted.
struct ChromiumCookieScope: Equatable {
    let host: String
    let paths: [String]

    init(host: String, paths: Set<String>) {
        self.host = host
        // Sorted so that a long list keeps "/" and the shortest ones.
        self.paths = Array(paths.union(["/"]).sorted().prefix(32))
    }

    var urls: [URL] {
        // https sees secure cookies and the rest; nothing is requested.
        paths.compactMap { path in
            var parts = URLComponents()
            parts.scheme = "https"; parts.host = host; parts.path = path
            return parts.url
        }
    }

    func covers(_ key: String) -> Bool {
        let parts = key.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, Self.domainMatches(host, String(parts[0])) else { return false }
        return paths.contains { Self.pathMatches($0, String(parts[1])) }
    }

    static func matches(host: String, key: String) -> Bool {
        guard let end = key.firstIndex(of: "\n") else { return false }
        return domainMatches(host, String(key[..<end]))
    }

    static func domainMatches(_ host: String, _ domain: String) -> Bool {
        guard domain.hasPrefix(".") else { return host == domain }
        let bare = domain.dropFirst()
        return host == bare || host.hasSuffix(domain)
    }

    static func pathMatches(_ path: String, _ cookie: String) -> Bool {
        guard path.hasPrefix(cookie) else { return false }
        return path == cookie || cookie.hasSuffix("/") || path.dropFirst(cookie.count).hasPrefix("/")
    }
}

/// The ledger with what reads it one host at a time.
struct ChromiumCookieBook {
    private(set) var ledger: ChromiumSwitchCookieLedger
    private var keysByDomain: [String: Set<String>] = [:]

    init(ledger: ChromiumSwitchCookieLedger = ChromiumSwitchCookieLedger(webKit: [:], chromium: [:])) {
        self.ledger = ledger
        for key in ledger.webKit.keys { index(key) }
        for key in ledger.chromium.keys { index(key) }
    }

    private mutating func index(_ key: String) {
        keysByDomain[Self.domain(of: key), default: []].insert(key)
    }

    private static func domain(of key: String) -> String {
        let domain = key.prefix { $0 != "\n" }
        return String(domain.hasPrefix(".") ? domain.dropFirst() : domain)
    }

    /// Every key on `host` or a domain above it.
    private func keys(for host: String) -> Set<String> {
        var found = Set<String>()
        var rest = Substring(host)
        while !rest.isEmpty {
            if let known = keysByDomain[String(rest)] { found.formUnion(known) }
            guard let dot = rest.firstIndex(of: ".") else { break }
            rest = rest[rest.index(after: dot)...]
        }
        return found
    }

    func scope(host: String, seen: Set<String>) -> ChromiumCookieScope {
        let keys = keys(for: host).filter { ChromiumCookieScope.matches(host: host, key: $0) }
        let known = keys.compactMap { key -> String? in
            let parts = key.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            return parts.count == 3 ? String(parts[1]) : nil
        }
        return ChromiumCookieScope(host: host, paths: seen.union(known))
    }

    func slice(_ scope: ChromiumCookieScope) -> ChromiumSwitchCookieLedger {
        let keys = keys(for: scope.host).filter(scope.covers)
        return ChromiumSwitchCookieLedger(webKit: ledger.webKit.filter { keys.contains($0.key) },
                                          chromium: ledger.chromium.filter { keys.contains($0.key) })
    }

    /// The print each cookie last had, in memory only: a cookie unchanged
    /// since its host was last read isn't encoded and hashed again. A host
    /// open on both engines is read every few seconds, nearly always as it was.
    private var prints: [String: [(cookie: ChromiumDRMCookie, print: String)]] = [:]
    /// How many prints were made rather than found, for tests.
    private(set) var printsMade = 0

    private let encoder: JSONEncoder = {
        let made = JSONEncoder()
        made.outputFormatting = [.sortedKeys]
        return made
    }()

    /// A cookie's print, made only if this cookie hasn't been printed as it is.
    mutating func fingerprint(_ cookie: ChromiumDRMCookie) -> String {
        if let known = prints[cookie.key]?.first(where: { $0.cookie == cookie }) { return known.print }
        let made = ChromiumSwitchCookieLedger.fingerprint(cookie, encoder: encoder)
        prints[cookie.key, default: []].append((cookie, made))
        printsMade += 1
        return made
    }

    /// What both jars hold now, in place of what the book held for this
    /// scope. True when that changed anything, so the ledger is saved only then.
    @discardableResult
    mutating func record(_ scope: ChromiumCookieScope, webKit: [String: ChromiumDRMCookie], chromium: [String: ChromiumDRMCookie]) -> Bool {
        let covered = keys(for: scope.host).filter(scope.covers)
        let webKitPrints = webKit.mapValues { fingerprint($0) }
        let chromiumPrints = chromium.mapValues { fingerprint($0) }
        var changed = false
        for key in covered.union(webKitPrints.keys) where ledger.webKit[key] != webKitPrints[key] {
            ledger.webKit[key] = webKitPrints[key]; changed = true
        }
        for key in covered.union(chromiumPrints.keys) where ledger.chromium[key] != chromiumPrints[key] {
            ledger.chromium[key] = chromiumPrints[key]; changed = true
        }
        var session = Set(ledger.session ?? [])
        session.subtract(covered)
        session.formUnion(chromium.filter { $0.value.expires == nil }.keys)
        let sessions = session.isEmpty ? nil : session.sorted()
        if sessions != ledger.session { ledger.session = sessions; changed = true }
        for key in covered.union(webKit.keys).union(chromium.keys) {
            let held = prints[key]?.filter { $0.cookie == webKit[key] || $0.cookie == chromium[key] } ?? []
            prints[key] = held.isEmpty ? nil : held
        }
        for key in webKit.keys { index(key) }
        for key in chromium.keys { index(key) }
        return changed
    }

    /// One import row: refused, it is on the WebKit side alone.
    mutating func note(_ row: ChromiumCookieImportRow, accepted: Bool) {
        let key = row.cookie.key
        ledger.webKit[key] = row.fingerprint
        if accepted {
            ledger.chromium[key] = row.fingerprint
            if row.cookie.expires == nil { ledger.session = (ledger.session ?? []) + [key] }
        }
        index(key)
    }

    mutating func finishImport() { ledger.imported = true }

    /// A new helper has the session cookies that reached its disk
    /// (persist_session_cookies; after a crash, not the last few seconds').
    /// Rather than forget them all, which of WebKit's go straight back:
    /// those both jars agreed on when last read, unchanged in WebKit since. A
    /// key the jars disagreed on is forgotten on both sides, Chromium's own
    /// value being gone. The rest stay known: a sign-out in either jar from now
    /// on is a change, never a cookie nobody has seen.
    func lostWithHelper(_ webKit: [ChromiumCookieImportRow]) -> (back: [ChromiumCookieImportRow], forget: [String]) {
        typealias Ledger = ChromiumSwitchCookieLedger
        let lost = Set(ledger.session ?? [])
        var back: [ChromiumCookieImportRow] = [], forget: [String] = []
        for key in lost where Ledger.whole(ledger.webKit[key]) != Ledger.whole(ledger.chromium[key]) { forget.append(key) }
        for row in webKit where lost.contains(row.cookie.key) && !forget.contains(row.cookie.key)
            && Ledger.whole(row.fingerprint) == Ledger.whole(ledger.webKit[row.cookie.key]) {
            back.append(row)
        }
        return (back, forget.sorted())
    }

    /// Both sides of these keys, as if never seen: the bootstrap rule decides them.
    mutating func forget(_ keys: [String]) {
        for key in keys { ledger.webKit[key] = nil; ledger.chromium[key] = nil; prints[key] = nil }
        if let session = ledger.session { ledger.session = session.filter { !keys.contains($0) } }
    }

    /// A cookie Chromium refused to take back: on the WebKit side alone.
    mutating func refused(_ key: String) {
        ledger.chromium[key] = nil
        if let session = ledger.session { ledger.session = session.filter { $0 != key } }
    }
}

/// A WebKit cookie ready for the import, made off the main thread.
struct ChromiumCookieImportRow: @unchecked Sendable {
    let cookie: ChromiumDRMCookie
    let fingerprint: String
    let payload: JSONValue

    static func rows(_ all: [HTTPCookie]) -> [ChromiumCookieImportRow] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return all.compactMap { cookie in
            guard !ChromiumDRMCookie.partitioned(cookie) else { return nil }
            let made = ChromiumDRMCookie(cookie)
            return ChromiumCookieImportRow(cookie: made, fingerprint: ChromiumSwitchCookieLedger.fingerprint(made, encoder: encoder), payload: made.chromium)
        }
    }
}

extension WKHTTPCookieStore {
    /// One address's cookies, without the jar: public on macOS 26, private
    /// before it, nil on a WebKit with neither.
    func cookies(for url: URL) async -> [HTTPCookie]? {
        typealias Read = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) (NSArray) -> Void) -> Void
        for name in ["getCookiesForURL:completionHandler:", "_getCookiesForURL:completionHandler:"] {
            let selector = NSSelectorFromString(name)
            guard responds(to: selector) else { continue }
            let read = unsafeBitCast(method(for: selector), to: Read.self)
            return await withCheckedContinuation { continuation in
                read(self, selector, url as NSURL) { cookies in continuation.resume(returning: cookies as? [HTTPCookie] ?? []) }
            }
        }
        return nil
    }
}

/// Which edits of the ledger reached the disk. One a save failed to write
/// (a full disk) stays owed, and the next read of any host saves again;
/// a ledger already written is not written again.
struct ChromiumLedgerSaves {
    private(set) var edits = 0
    private var written = 0
    var owed: Bool { written < edits }
    mutating func edited() { edits += 1 }
    /// The ledger as it was at `at` edits is on disk.
    mutating func wrote(_ at: Int) { written = max(written, at) }
}

/// The ledger's saves, one after another, each of the ledger as it is when
/// its turn comes: two at once could land older last, the disk then behind
/// with nothing owed.
@MainActor
final class ChromiumLedgerWriter {
    /// After a failed save, how long before a read that changed nothing tries
    /// again: a full disk isn't rewritten with the whole ledger every few
    /// seconds. A read that changed the ledger saves at once.
    static let rest: TimeInterval = 60

    private var saves = ChromiumLedgerSaves()
    private var writing: Task<Void, Error>?
    private var failedAt: Date?
    private let ledger: @MainActor () -> ChromiumSwitchCookieLedger?
    private let clock: () -> Date
    private let write: @Sendable (ChromiumSwitchCookieLedger) async throws -> Void

    /// `ledger` nil: its bridge is gone, and nothing is written, never an empty ledger.
    init(ledger: @escaping @MainActor () -> ChromiumSwitchCookieLedger?, clock: @escaping () -> Date = Date.init,
         write: @escaping @Sendable (ChromiumSwitchCookieLedger) async throws -> Void) {
        self.ledger = ledger; self.clock = clock; self.write = write
    }

    var owed: Bool { saves.owed }
    /// Owed, and not resting after a failure.
    var due: Bool { owed && (failedAt.map { clock().timeIntervalSince($0) >= Self.rest } ?? true) }
    func edited() { saves.edited() }

    func save() async throws {
        let previous = writing
        let turn = Task { @MainActor in
            _ = await previous?.result
            guard saves.owed, let snapshot = ledger() else { return }
            let at = saves.edits
            do { try await write(snapshot) } catch {
                failedAt = clock()
                throw error
            }
            failedAt = nil
            saves.wrote(at)
        }
        writing = turn
        try await turn.value
    }
}

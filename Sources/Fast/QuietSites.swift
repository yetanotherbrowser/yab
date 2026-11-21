import Foundation

// Sites the blocker has little to do on, and what it does there.
//
// WebKit checks every load a page makes against every rule of every list,
// on the web process's main thread, and the check grows with the address:
// 0.5 ms a load for the 160 000 rules, more for a long image address. A page
// that makes two thousand of them (mobbin.com's grid of screens, its srcset
// candidates and re-renders) loses a second to it, for nothing when all the
// lists ever stop there is a tracker or two.
//
// So a site is watched. On each of its pages the lists are on and what they
// block is noted, by address without its query. Once two pages in a row
// brought nothing new (the first page always does), and all of it is a
// handful, the site is quiet: its pages get a list of just those addresses
// instead of the blocking lists, which costs a load next to nothing and
// blocks what the lists blocked there, and keep the generic hiding, so the
// boxes a site leaves empty where its ads would go stay hidden. Every
// tenth page of a quiet site has the lists again, and anything new they
// block makes it an ordinary site once more. A site with more than a
// handful, or with hiding rules of its own, is never quiet.
//
// What a quiet site's pages go without: a block for a load the lists would
// stop that none of its watched pages made, until the next page with the
// lists sees it.

struct QuietSites: Codable, Equatable {
    struct Site: Codable, Equatable {
        /// Pages watched with the lists on.
        var visits = 0
        /// The watched page that last brought something new; the first
        /// page counts as new.
        var fresh = 1
        /// What the lists blocked, as `key` writes it.
        var keys: [String] = []
        var quiet = false
        /// Pages since it went quiet.
        var since = 0
        /// More than `most` blocked: a site the lists work on.
        var never = false
        var last: Double = 0
    }

    var sites: [String: Site] = [:]

    /// Watched pages with nothing new it takes to be quiet.
    static let needed = 2
    /// The most addresses a quiet site's list holds.
    static let most = Int(ProcessInfo.processInfo.environment["YAB_SHIELD_QUIET_MOST"] ?? "") ?? 12
    /// One page in this many of a quiet site has the lists again.
    static let every = 10
    /// Sites remembered, the least recently visited forgotten first.
    static let kept = 400

    /// A page of `host` is about to load: the addresses to block on it if
    /// the site is quiet, or nil for the lists, the page then watched.
    mutating func visit(_ host: String, now: Double) -> [String]? {
        var site = sites[host] ?? Site()
        site.last = now
        defer {
            sites[host] = site
            if sites.count > Self.kept, let oldest = sites.min(by: { $0.value.last < $1.value.last })?.key { sites[oldest] = nil }
        }
        if site.never { return nil }
        if !site.quiet, site.visits - site.fresh >= Self.needed {
            site.quiet = true
            site.since = 0
        }
        if site.quiet {
            site.since += 1
            if site.since % Self.every != 0 { return site.keys }
        }
        site.visits += 1
        return nil
    }

    /// The lists blocked `key` on a watched page of `host`. True when that
    /// changed what is known of the site.
    @discardableResult
    mutating func saw(_ key: String, on host: String) -> Bool {
        guard var site = sites[host], !site.never, !site.keys.contains(key) else { return false }
        site.keys.append(key)
        site.fresh = site.visits
        site.quiet = false
        if site.keys.count > Self.most {
            site.never = true
            site.keys = []
        }
        sites[host] = site
        return true
    }

    /// The lists blocked something on `host` that can't be written as a
    /// key: the site is never quiet.
    mutating func refuse(_ host: String) {
        guard var site = sites[host], !site.never else { return }
        site.never = true
        site.quiet = false
        site.keys = []
        sites[host] = site
    }

    /// A blocked load's address as it is remembered: host and path, no
    /// scheme, query or fragment. Nil for one too long or not plain ASCII,
    /// which a site then can't be quiet with.
    static func key(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let key = host + url.path(percentEncoded: true)
        guard key.count <= 400, key.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return key
    }

    /// A quiet site's list: each address blocked whatever its query, by any
    /// scheme. Anchored at the start, so a load is turned away at its first
    /// characters unless it is one of them.
    static func list(_ keys: [String]) -> String {
        let rules = keys.sorted().map { key in
            let filter = "^[a-z-]+://" + Filters.escape(key) + "([?#].*)?$"
            return "{\"trigger\":{\"url-filter\":\(Filters.quote(filter))},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// Whether `host` or a domain above it has hiding rules of its own, by
    /// its name or as an entity: "name.*" reaches name and one more label,
    /// as Filters.onEntity matches it.
    static func hides(_ host: String, in sites: Set<String>) -> Bool {
        var rest = Substring(host)
        while true {
            if sites.contains(String(rest)) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            if let last = rest.lastIndex(of: "."), sites.contains(rest[..<last] + ".*") { return true }
            rest = rest[rest.index(after: dot)...]
        }
    }
}

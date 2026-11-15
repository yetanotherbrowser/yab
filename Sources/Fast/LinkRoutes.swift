import Foundation

// Where a link from another app goes, when it has somewhere to go: a site
// kept to a space, the way Arc's Air Traffic Control keeps one. linear.app
// to Work, and a Linear link clicked in Slack opens in Work, signed in as
// Work is, whatever space is on screen.
//
// A route keeps its Space, and may explicitly skip Small Window for links
// from other apps. With no window choice it keeps the global behavior.
//
// A site is what was typed: linear.app is the site and every host under it;
// docs.google.com/spreadsheets is only the pages under that path. There is
// no order to them: the closest match wins, a path over a host, a longer
// host over a shorter one. A word or a * pattern is an exception for any
// matching address, taking priority over a site. Links from other apps,
// a new site explicitly opened from Cmd-T, and a link a page opens in a
// new tab (a Cmd-click, a middle click, target=_blank, a mail's link, a
// peek opened as a tab) follow the rules, as Arc's do; a plain click and
// same-tab address changes stay in the page's space. Only a rule moves a
// page's link: the fallback space is for links from other apps.
// Settings › Spaces lists them; the small
// window's space menu makes one for the page it shows.

struct LinkRoute: Codable, Equatable, Identifiable {
    /// A host, maybe with a path, or an address pattern: "*megatron*".
    var site: String
    var space: UUID
    /// Nil for old rules: keep the global Small Window behavior.
    var opensInMain: Bool? = nil
    var id: String { site }
    var pattern: Bool { site.contains("*") }

    var host: String { site.split(separator: "/", maxSplits: 1).first.map(String.init) ?? site }
    /// "" for the whole site, "/spreadsheets" for the pages under it.
    var path: String { String(site.dropFirst(host.count)) }
}

@MainActor
final class LinkRoutes: ObservableObject {
    static let shared = LinkRoutes()

    nonisolated static let key = "links.routes"
    nonisolated static let displayOrderKey = "links.routes.display-order"
    nonisolated static let defaultSpaceKey = "links.routes.default-space"
    /// A destination token, not a space or a remembered last-used UUID.
    /// Old clients ignore rules with this unknown destination; old fixed
    /// rules keep their unchanged encoding.
    nonisolated static let recentSpaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!
    /// Pages a small window kept into a space, for the suggestion.
    nonisolated static let keptKey = "links.routes.kept"
    /// Sites whose suggestion was waved away.
    nonisolated static let declinedKey = "links.routes.declined"

    @Published private(set) var defaultSpace: UUID?
    @Published private(set) var routes: [LinkRoute]
    @Published private(set) var displayOrder: [String]
    @Published private(set) var kept: [Kept]
    @Published private(set) var declined: Set<String>
    private let settings: UserDefaults

    var displayedRoutes: [LinkRoute] {
        let positions = Dictionary(displayOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return routes.enumerated().sorted { first, second in
            let firstPosition = positions[first.element.id] ?? (displayOrder.count + first.offset)
            let secondPosition = positions[second.element.id] ?? (displayOrder.count + second.offset)
            return firstPosition < secondPosition
        }.map(\.element)
    }

    struct Kept: Codable, Equatable {
        var site: String
        var space: UUID
        var at: Date
    }

    /// A site the small window has kept into one space often enough to
    /// offer keeping its links there.
    struct Suggestion: Equatable {
        var site: String
        var space: UUID
        var times: Int
    }

    /// Kept into the same space this many times in `window`, it is offered.
    nonisolated static let often = 3
    nonisolated static let window: TimeInterval = 7 * 24 * 3600

    init(settings: UserDefaults = Store.settings) {
        self.settings = settings
        defaultSpace = settings.string(forKey: Self.defaultSpaceKey).flatMap(UUID.init(uuidString:))
        routes = Self.decode([LinkRoute].self, Self.key, settings: settings) ?? []
        displayOrder = settings.stringArray(forKey: Self.displayOrderKey) ?? []
        kept = Self.decode([Kept].self, Self.keptKey, settings: settings) ?? []
        declined = Set(settings.stringArray(forKey: Self.declinedKey) ?? [])
    }

    // MARK: - finding

    /// The space a link from another app goes to, if a route takes it
    /// there, and that space is still there with spaces on.
    func space(for url: URL, in browser: Browser) -> UUID? {
        guard browser.spacesShown, browser.spaces.count > 1 else { return nil }
        return Self.destination(routes: routes, for: url, available: browser.spaces.map(\.id),
                                recent: browser.spaceID, fallback: nil)
    }

    /// External links alone use the optional fallback. The front space was
    /// captured with the request, before routing or delayed window work.
    func externalSpace(for url: URL, in browser: Browser, recent: UUID?) -> UUID? {
        guard browser.spacesShown, browser.spaces.count > 1 else { return nil }
        return Self.destination(routes: routes, for: url, available: browser.spaces.map(\.id),
                                recent: recent, fallback: browser.privateBrowsing ? nil : defaultSpace)
    }

    nonisolated static func destination(routes: [LinkRoute], for url: URL, available: [UUID],
                                        recent: UUID?, fallback: UUID?) -> UUID? {
        // A matched rule wins even if its destination was removed: an
        // unrelated fallback must not silently replace that rule.
        let rule = best(routes, for: url)
        let mayUseFallback = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let destination = rule?.space ?? (mayUseFallback ? fallback : nil)
        let resolved = destination == recentSpaceID ? recent : destination
        return resolved.flatMap { available.contains($0) ? $0 : nil }
    }

    /// Where a link a page opens in a new tab goes (Browser.routePageLink):
    /// another space, when a rule keeps its site there, or nil to stay in
    /// the page's own. A private page, an agent's or the chat's, and a
    /// small window's keep theirs.
    func pageLinkSpace(for url: URL, from source: Tab?, in browser: Browser) -> UUID? {
        guard browser.windowPurpose == .normal, browser.prefs.usesSpaces, browser.spaces.count > 1,
              let source, !source.shy, !source.bench, source.agent == nil,
              !browser.outside.contains(where: { $0 === source }) else { return nil }
        return Self.pageLinkDestination(routes: routes, for: url, available: browser.spaces.map(\.id), current: browser.spaceID)
    }

    /// A page's link: a matched rule's space, never the fallback, and
    /// nil when that is the space it is already in.
    nonisolated static func pageLinkDestination(routes: [LinkRoute], for url: URL, available: [UUID], current: UUID) -> UUID? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let destination = destination(routes: routes, for: url, available: available, recent: current, fallback: nil)
        return destination == current ? nil : destination
    }

    func setDefaultSpace(_ space: UUID?) {
        defaultSpace = space
        settings.set(space?.uuidString, forKey: Self.defaultSpaceKey)
    }

    /// Only the winning external rule may bypass Small Window. This does
    /// not choose a Space or change typed URLs, page links or Handoff.
    func opensInMain(for url: URL) -> Bool {
        Self.opensInMain(routes, for: url)
    }

    nonisolated static func opensInMain(_ routes: [LinkRoute], for url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return best(routes, for: url)?.opensInMain == true
    }

    /// Changes the window choice of an existing rule, never creates a
    /// destination or silently changes a site's Space.
    func setMainWindow(_ site: String, enabled: Bool) {
        guard let at = routes.firstIndex(where: { $0.site == site }) else { return }
        routes[at].opensInMain = enabled ? true : nil
        save()
    }

    /// The route for exactly this site, not a wider or narrower one.
    func route(site: String) -> LinkRoute? { routes.first { $0.site == site } }

    /// An address pattern takes priority over a site; the pattern with
    /// more literal characters wins. Sites keep their former precedence:
    /// the longer path, then the longer host.
    nonisolated static func best(_ routes: [LinkRoute], for url: URL) -> LinkRoute? {
        guard let host = url.host().map(bare), !host.isEmpty else { return nil }
        let path = url.path(percentEncoded: false).lowercased()
        let patternHost = url.host(percentEncoded: false).map(bare) ?? host
        let query = url.query(percentEncoded: false).map { "?" + $0.lowercased() } ?? ""
        // A site's root is the same address with or without its last slash:
        // both *.example.com and example.com/* can take it.
        let root = path.isEmpty || path == "/"
        let address = patternHost + (root ? "" : path) + query
        return routes
            .filter { route in
                if route.pattern {
                    return matches(route.site, address) || (root && matches(route.site, patternHost + "/" + query))
                }
                return (host == route.host || host.hasSuffix("." + route.host))
                    && (route.path.isEmpty || path == route.path || path.hasPrefix(route.path + "/"))
            }
            .max { a, b in priority(a) < priority(b) }
    }

    private nonisolated static func priority(_ route: LinkRoute) -> (Int, Int, Int) {
        route.pattern ? (1, route.site.filter { $0 != "*" }.count, 0) : (0, route.path.count, route.host.count)
    }

    /// A whole-address glob. Only * has a special meaning: any number of
    /// characters, including dots and slashes. User text never becomes a
    /// regular expression. Both inputs have already been normalized.
    nonisolated static func matches(_ glob: String, _ address: String) -> Bool {
        let pattern = Array(glob), text = Array(address)
        var p = 0, t = 0
        var star: Int?, retry = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                star = p
                p += 1
                retry = t
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let star {
                retry += 1
                t = retry
                p = star + 1
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    // MARK: - what a site is

    /// A host as a site: lowercased, without its www.
    nonisolated static func bare(_ host: String) -> String {
        let low = host.lowercased()
        return low.hasPrefix("www.") ? String(low.dropFirst(4)) : low
    }

    /// The site a page is on, its host, for the small window's menu.
    nonisolated static func site(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased().hasPrefix("http") == true,
              let host = url.host().map(bare), !host.isEmpty else { return nil }
        return host
    }

    /// What was typed: a site retains its former normalization. A word
    /// becomes *word*, and a glob keeps its query and trailing stars.
    /// Patterns use the same scheme-free, percent-decoded address as best.
    nonisolated static func site(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains("*") {
            let scheme = text.range(of: "://")
            if scheme != nil, let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty {
                // A copied URL uses the same authority as the matcher:
                // host only, without credentials, port or www. Decode each
                // component after parsing so an encoded # remains literal.
                text = bare(host) + (parts.percentEncodedPath.removingPercentEncoding ?? parts.path)
                    + (parts.percentEncodedQuery.map { "?" + ($0.removingPercentEncoding ?? $0) } ?? "")
                text = text.lowercased()
            } else {
                // Bare globs are free-form: retain wildcard positions and
                // literal punctuation, including query delimiters.
                if let scheme { text = String(text[scheme.upperBound...]) }
                text = String(text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                text = (text.removingPercentEncoding ?? text).lowercased()
                if text.hasPrefix("www.") { text.removeFirst(4) }
            }
            guard text.contains(where: { $0 != "*" }), !text.contains(where: \.isWhitespace) else { return nil }
            return text
        }
        if !text.contains("."), !text.contains("/"), text.lowercased() != "localhost",
           !text.contains(where: { ":?#@\\[]".contains($0) }) {
            return "*" + text.lowercased() + "*"
        }
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), let raw = parts.host, !raw.isEmpty else { return nil }
        let host = bare(raw)
        guard host.contains(".") || host == "localhost", !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        var path = parts.percentEncodedPath.removingPercentEncoding?.lowercased() ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    // MARK: - changing

    func move(_ site: String, to index: Int) {
        var order = displayedRoutes.map(\.id)
        guard let from = order.firstIndex(of: site) else { return }
        order.remove(at: from)
        order.insert(site, at: min(max(0, index), order.count))
        displayOrder = order
        settings.set(order, forKey: Self.displayOrderKey)
    }

    /// This site's links to `space`, in its place if it had a route.
    func set(_ site: String, to space: UUID) {
        if let at = routes.firstIndex(where: { $0.site == site }) {
            routes[at].space = space
        } else {
            routes.append(LinkRoute(site: site, space: space))
        }
        kept.removeAll { $0.site == site }
        save()
    }

    /// A rule edited: its text and space in the old one's place. Typed as
    /// another rule already there, the two become this one.
    func replace(_ old: String, with site: String, to space: UUID) {
        if routes.contains(where: { $0.site == old }) {
            displayOrder = displayedRoutes.map(\.id)
                .filter { $0 != site || $0 == old }
                .map { $0 == old ? site : $0 }
        }
        routes = Self.replacing(routes, old, with: site, to: space)
        kept.removeAll { $0.site == site }
        save()
    }

    nonisolated static func replacing(_ routes: [LinkRoute], _ old: String, with site: String,
                                      to space: UUID) -> [LinkRoute] {
        var routes = routes
        guard let at = routes.firstIndex(where: { $0.site == old }) else {
            // Removed while its card was up: added as any new rule is.
            if let same = routes.firstIndex(where: { $0.site == site }) {
                routes[same].space = space
            } else {
                routes.append(LinkRoute(site: site, space: space))
            }
            return routes
        }
        routes[at] = LinkRoute(site: site, space: space, opensInMain: routes[at].opensInMain)
        return routes.enumerated().filter { $0.offset == at || $0.element.site != site }.map(\.element)
    }

    func remove(_ site: String) {
        routes.removeAll { $0.site == site }
        save()
    }

    /// Every rule and the default space as they were (an agent's links.*
    /// change undone, NativeControl).
    func restore(_ back: [LinkRoute], defaultSpace fallback: UUID?) {
        routes = back
        setDefaultSpace(fallback)
        save()
    }

    /// A space deleted: its routes with it, and what was kept into it.
    func forget(space: UUID) {
        routes.removeAll { $0.space == space }
        kept.removeAll { $0.space == space }
        save()
    }

    /// A deleted space's routes, back with it (Browser.deleteSpace).
    func bringBack(_ back: [LinkRoute], kept more: [Kept]) {
        routes += back.filter { !routes.contains($0) }
        kept += more.filter { !kept.contains($0) }
        save()
    }

    /// How many sites a space's links come from, for its Delete note.
    func count(to space: UUID) -> Int { routes.filter { $0.space == space }.count }

    // MARK: - the suggestion

    /// A small window's page kept into a space: counted toward offering
    /// its site a route there, unless a route already takes it.
    func noteKept(_ url: URL?, into space: UUID) {
        guard let site = Self.site(of: url), let url, Self.best(routes, for: url) == nil else { return }
        let now = Date()
        kept.removeAll { now.timeIntervalSince($0.at) > Self.window }
        kept.append(Kept(site: site, space: space, at: now))
        // Enough to count with, and never a long list.
        if kept.count > 60 { kept.removeFirst(kept.count - 60) }
        save()
    }

    /// The one site to offer, if any: the one kept most often into one
    /// space this week, three times or more, not waved away, with a space
    /// still there to go to.
    func suggestion(in spaces: [Space]) -> Suggestion? {
        Self.suggestion(kept: kept, routes: routes, declined: declined, spaces: Set(spaces.map(\.id)), now: Date())
    }

    nonisolated static func suggestion(kept: [Kept], routes: [LinkRoute], declined: Set<String>,
                                       spaces: Set<UUID>, now: Date) -> Suggestion? {
        var counts: [String: [UUID: Int]] = [:]
        for item in kept where now.timeIntervalSince(item.at) <= window {
            counts[item.site, default: [:]][item.space, default: 0] += 1
        }
        return counts
            .compactMap { site, spaces -> Suggestion? in
                guard let top = spaces.max(by: { $0.value < $1.value }) else { return nil }
                return Suggestion(site: site, space: top.key, times: top.value)
            }
            .filter { item in
                item.times >= often && !declined.contains(item.site)
                    && !routes.contains { $0.site == item.site } && spaces.contains(item.space)
            }
            .max { ($0.times, $1.site) < ($1.times, $0.site) }
    }

    func decline(_ site: String) {
        declined.insert(site)
        save()
    }

    // MARK: - kept

    private func save() {
        displayOrder = displayedRoutes.map(\.id)
        settings.set(displayOrder, forKey: Self.displayOrderKey)
        Self.encode(routes, Self.key, settings: settings)
        Self.encode(kept, Self.keptKey, settings: settings)
        settings.set(declined.sorted(), forKey: Self.declinedKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String, settings: UserDefaults) -> T? {
        settings.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String, settings: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        settings.set(data, forKey: key)
    }
}

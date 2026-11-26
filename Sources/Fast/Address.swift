import Foundation

// What you type has to be a place. There is no search here, so this either
// hands back a URL or hands back nothing, and nothing is worth saying out
// loud, because the alternative is a browser that silently does something else
// with your keystrokes.
enum Address {
    /// Schemes the window can show itself. Anything else typed with a scheme,
    /// mailto:, a custom app link, is somebody else's job and gets refused
    /// here rather than opening a blank tab.
    private static let ours: Set<String> = ["http", "https", "file", "about", "data", "chrome", DiaryPage.scheme, ArtifactPages.scheme]

    /// Words a scheme is spelled with: tel:911 or javascript:1 is never a
    /// machine called tel.
    private static let schemes: Set<String> = ours.union([
        "javascript", "mailto", "tel", "sms", "ftp", "ws", "wss", "blob", "view-source",
        "facetime", "facetime-audio", "maps", "news", "webcal", "callto", "sip", "ssh", "git",
    ])

    /// Ports a machine on the network is reached at: the web's own and the
    /// ones a server picks for itself, 1024 and up. Below that, word:3 is a
    /// verse, a version, a ratio, not a server.
    private static func serves(_ port: Int) -> Bool {
        port >= 1024 || [80, 443].contains(port)
    }

    /// `names`: a bare name with a port, nas:5000, counts. It is the one
    /// kind of address that reads as words too, so the field that takes it
    /// still offers the search (isBareName).
    static func url(from typed: String) -> URL? { url(from: typed, names: true) }

    static func url(from typed: String, names: Bool) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A path on this Mac is a file, spaces
        // in its names and all. It is never sent off as a search.
        if let file = file(text) { return file }
        guard !text.contains(" ") else { return nil }

        // Written with a scheme, it is taken at its word.
        if let split = text.range(of: "://") {
            let scheme = text[..<split.lowerBound].lowercased()
            guard ours.contains(scheme) else { return nil }
            return ascii(URL(string: text))
        }
        if text.lowercased().hasPrefix("about:") || text.lowercased().hasPrefix("data:") {
            return URL(string: text)
        }

        // Everything else has to look like a host before it gets a scheme put
        // in front of it. "hello world" is not a website, and neither is "todo".
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !head.contains("@") else { return nil }   // an email address
        guard let (host, port) = split(head) else { return nil }
        // A port has to be one, 1 to 65535.
        let number = port.map { Int(UInt16($0) ?? 0) }
        if number == 0 { return nil }
        // A bare name with a server's port, nas:5000, a machine on this
        // network, is a place too, when it isn't a scheme's name.
        let machine = names && isName(host) && !schemes.contains(host) && number.map(serves) == true
        guard looksLikeHost(host) || machine else { return nil }

        // A local server almost never has a certificate, so https there is a
        // connection failure rather than a page. A device that answers only
        // https, a phone's or a router's page, gets there by LocalHTTPS.
        return ascii(URL(string: (isLocal(host) ? "http://" : "https://") + text))
    }

    /// What the field finished, read back as an address. History names a
    /// place without its scheme, and without a port that is the scheme's own
    /// (`History.key`), so the words alone lose them: `place`, the one they
    /// finished, gives a bare name its address and a server its scheme and
    /// port back.
    static func finished(_ words: String, place: URL?) -> URL? {
        guard let url = url(from: words) else { return place }
        func bare(_ host: String?) -> String? { host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
        guard let place, let port = place.port, url.port == nil || url.port == port, bare(url.host()) == bare(place.host()),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = place.scheme
        parts.host = place.host()
        parts.port = port
        return parts.url ?? url
    }

    /// A host typed as it reads, münchen.de, is kept as it is sent,
    /// xn--mnchen-3ya.de: Foundation encodes it in the address but hands
    /// host() back percent-encoded until the URL is made again from it.
    private static func ascii(_ url: URL?) -> URL? {
        guard let url, !url.absoluteString.isEmpty, url.host()?.contains("%") == true else { return url }
        return URL(string: url.absoluteString) ?? url
    }

    /// /Users/… or ~/…, whether or not it is there: a missing file is the
    /// page's own error, not a search for its path. //host is not a path.
    private static func file(_ text: String) -> URL? {
        var path = text
        if path == "~" || path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Taken as a place only by the bare name rule: the field goes there
    /// on Return and offers the search as well.
    static func isBareName(_ typed: String) -> Bool {
        url(from: typed, names: false) == nil && url(from: typed) != nil
    }

    /// The host and the port before the path. An IPv6 address comes in
    /// brackets, since its own colons aren't a port's.
    private static func split(_ head: Substring) -> (host: String, port: Substring?)? {
        if head.hasPrefix("[") {
            guard let close = head.firstIndex(of: "]") else { return nil }
            let rest = head[head.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            return (head[...close].lowercased(), rest.isEmpty ? nil : rest.dropFirst())
        }
        let parts = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return (parts[0].lowercased(), parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// This Mac, and the network it is on: localhost, the loopback and
    /// private and shared addresses, a .local or Tailscale name, a bare name.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        if host.hasPrefix("[") {
            // Loopback, link-local fe80::/10, unique local fc00::/7.
            let inside = host.dropFirst().dropLast()
            if inside == "::1" { return true }
            guard let first = inside.split(separator: ":", omittingEmptySubsequences: false).first,
                  let hextet = UInt16(first, radix: 16) else { return false }
            return hextet & 0xFFC0 == 0xFE80 || hextet & 0xFE00 == 0xFC00
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt8($0) }
        guard parts.count == 4, numbers.count == 4 else { return parts.count == 1 }
        switch (numbers[0], numbers[1]) {
        case (0, _), (10, _), (100, 64...127), (127, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }

    /// One label, a machine's name: letters, digits and hyphens, with a
    /// letter somewhere, so 8080:80 is not one.
    private static func isName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && !host.hasSuffix("-")
            && host.contains { $0.isLetter }
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" { return true }

        // An IPv6 address, in its brackets.
        if host.hasPrefix("["), host.hasSuffix("]") {
            let inside = host.dropFirst().dropLast()
            return inside.contains(":") && inside.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }

        // Four numbers is an address on the local network as often as not.
        let numbers = host.split(separator: ".", omittingEmptySubsequences: false)
        if numbers.count == 4, numbers.allSatisfy({ UInt8($0) != nil }) { return true }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ label in
            !label.isEmpty
                && !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }

        // The last label carries the weight: a dotted thing ending in letters is
        // a domain, a dotted thing ending in digits is a version number.
        let tld = labels[labels.count - 1]
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    /// What the tab says before the page has told us its title: the address,
    /// with the parts nobody reads taken off, the port too unless asked for.
    /// History keeps a port that isn't the scheme's own (History.key).
    static func pretty(_ url: URL) -> String { pretty(url, port: false) }

    static func pretty(_ url: URL, port: Bool, keepingWWW: Bool = false) -> String {
        guard let host = url.host() else { return url.absoluteString }
        var bare = !keepingWWW && host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // An IPv6 address keeps its brackets, or its colons read as a port's.
        if bare.contains(":") { bare = "[\(bare)]" }
        if port, let number = url.port { bare += ":\(number)" }
        let path = url.path()
        return path.isEmpty || path == "/" ? bare : bare + path
    }

    /// The address as it is read, in the field's rows and wherever a page is
    /// named by it: pretty, with its host decoded from punycode when that is
    /// safe (IDN). Never a key: History keeps pretty's xn-- form.
    static func shown(_ url: URL) -> String { IDN.shownAddress(pretty(url)) }

    /// What ⌘L puts in the field: the pretty address with nothing that
    /// takes you somewhere left off, the port, the query and the fragment
    /// stay, so Return on it, or an edit of it, is the same page and not
    /// its bare path, or localhost's other server.
    static func whole(_ url: URL) -> String {
        guard url.host() != nil else { return url.absoluteString }
        var text = IDN.shownAddress(pretty(url, port: true, keepingWWW: true))
        if let query = url.query(), !query.isEmpty { text += "?" + query }
        if let fragment = url.fragment(), !fragment.isEmpty { text += "#" + fragment }
        return text
    }
}

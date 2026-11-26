import Foundation

// Network filters (||host^, $options) and hosts files as WebKit rules (see Filters).

extension Filters {
    // MARK: - network rules

    /// A network filter as rules, each with where it goes. Most lines are
    /// one rule; one that names frames and other things beside is two,
    /// because a frame is told apart by where it loads, which WebKit can
    /// only say of a whole rule, and so is one that names no kind at all:
    /// every kind but the page, and pages in frames.
    static func network(_ line: String) -> [(Rule, Place)]? {
        var pattern = Substring(line)
        let exception = pattern.hasPrefix("@@")
        if exception { pattern = pattern.dropFirst(2) }
        // /regex/: WebKit's grammar is too small to carry one faithfully.
        if pattern.hasPrefix("/"), pattern.count > 2, pattern.hasSuffix("/") || pattern.contains("/$") { return nil }

        var options: [(name: String, value: String?)] = []
        if let dollar = optionsStart(pattern) {
            for token in pattern[pattern.index(after: dollar)...].split(separator: ",", omittingEmptySubsequences: false) {
                guard !token.isEmpty else { return nil }
                if let equals = token.firstIndex(of: "=") {
                    options.append((token[..<equals].lowercased(), String(token[token.index(after: equals)...])))
                } else {
                    options.append((token.lowercased(), nil))
                }
            }
            pattern = pattern[..<dollar]
        }

        var rule = Rule(action: exception ? .allow : .block, filter: "")
        var important = false
        var wanted = Set<String>()
        var unwanted = Set<String>()
        var frames: String?
        var whole = false
        var includes: [String] = []
        var excludes: [String] = []
        var documentOnly = false
        var webrtc = false
        var hiding: Place?
        var odd = 0

        for (name, value) in options {
            switch name {
            case "third-party", "3p", "~first-party", "~1p":
                guard rule.party != "first-party" else { return nil }
                rule.party = "third-party"
            case "first-party", "1p", "~third-party", "~3p":
                guard rule.party != "third-party" else { return nil }
                rule.party = "first-party"
            case "match-case":
                rule.caseSensitive = true
            case "important":
                important = true
            case "all":
                whole = true
            case "reason":
                continue // a note for people, it changes nothing
            case "domain", "from":
                guard let value else { return nil }
                for domain in value.split(separator: "|") {
                    if domain.hasPrefix("~") {
                        guard let clean = plainDomain(domain.dropFirst()) else { return nil }
                        excludes.append(clean)
                    } else if let clean = plainDomain(domain) {
                        includes.append(clean)
                    } else {
                        odd += 1 // left out below, unless it only narrows an exception to hiding
                    }
                }
            case "doc", "document":
                if exception { documentOnly = true } else { frames = frames == "child-frame" ? "any" : "top-frame" }
            case "subdocument", "frame":
                frames = frames == "top-frame" ? "any" : "child-frame"
            case "popup":
                wanted.insert("popup")
            case "generichide", "ghide":
                guard exception else { return nil }
                if hiding == nil { hiding = .unhide }
            case "elemhide", "ehide":
                guard exception else { return nil }
                hiding = .unhideAll
            default:
                if name.hasPrefix("~"), let type = kinds[String(name.dropFirst())] {
                    unwanted.formUnion(type)
                } else if let type = kinds[name] {
                    wanted.formUnion(type)
                } else if name == "webrtc" {
                    // WebKit has no such load. Beside other kinds it can be
                    // dropped, the rule only narrows; on its own, not.
                    webrtc = true
                } else if name == "~webrtc" {
                    continue // every kind WebKit has
                } else {
                    return nil // $redirect, $csp, $removeparam, $to, …
                }
            }
        }
        if webrtc, wanted.isEmpty, frames == nil { return nil }
        guard includes.isEmpty || excludes.isEmpty else { return nil }
        guard wanted.isEmpty || unwanted.isEmpty else { return nil }
        rule.ifDomain = Array(Set(includes)).sorted()
        rule.unlessDomain = Array(Set(excludes)).sorted()

        // @@||site^$generichide, @@*$ghide,domain=a.com|b.*: the page's
        // hiding off, which is decided by the page's own address, so the
        // pattern is matched against it at the end of the hiding list.
        // Sites WebKit can't name are dropped from the list, which only
        // leaves them hidden as before; with nothing else said, it stands.
        if let hiding {
            let said = options.filter { !["generichide", "ghide", "elemhide", "ehide", "domain", "from"].contains($0.name) }
            guard said.isEmpty, excludes.isEmpty else { return nil }
            if let host = pureHost(pattern), rule.ifDomain.isEmpty {
                rule.filter = ".*"
                rule.ifDomain = [host]
            } else if pattern.isEmpty || pattern == "*" {
                guard !rule.ifDomain.isEmpty else { return nil }
                rule.filter = ".*"
            } else {
                guard let filter = urlFilter(pattern), !everywhere(pattern) || !rule.ifDomain.isEmpty else { return nil }
                rule.filter = filter
            }
            // $elemhide reaches a site's own hiding rules only by the sites
            // it names.
            if hiding == .unhideAll, rule.ifDomain.isEmpty || rule.filter != ".*" { return nil }
            return [(rule, hiding)]
        }
        guard odd == 0 else { return nil }

        // @@||site^$document: nothing is blocked on that site's pages.
        if documentOnly {
            guard options.count == 1, rule.ifDomain.isEmpty, rule.unlessDomain.isEmpty,
                  let host = pureHost(pattern) else { return nil }
            rule.filter = ".*"
            rule.ifDomain = [host]
            return [(rule, .plain)]
        }

        if pattern.isEmpty || pattern == "*" || everywhere(pattern) {
            // Everything, narrowed only by what it is or where: fine on the
            // sites it names, a way to block the web otherwise. "|https://"
            // is everything too, said another way.
            guard !rule.ifDomain.isEmpty else { return nil }
            rule.filter = pattern.isEmpty || pattern == "*" ? ".*" : (urlFilter(pattern) ?? ".*")
        } else {
            guard let filter = urlFilter(pattern) else { return nil }
            rule.filter = filter
        }

        if !unwanted.isEmpty {
            wanted = Set(everything).subtracting(unwanted)
        }
        if whole {
            wanted = []
            frames = nil
        }
        let place: Place = important && !exception ? .important : .plain
        var made: [(Rule, Place)] = []
        if !wanted.isEmpty {
            var r = rule
            r.types = wanted.sorted()
            made.append((r, place))
        }
        if let frames {
            var r = rule
            r.types = ["document"]
            if frames != "any" { r.context = frames }
            made.append((r, place))
        }
        if made.isEmpty {
            if whole || (!exception && rule.party == "third-party" && pureHost(pattern) != nil) {
                // $all: the site's own pages too, as the badware lists mean
                // it. And a whole site's third-party loads: one rule, as a
                // page you open is never one.
                made.append((rule, place))
            } else {
                made += ofLoads(rule).map { ($0, place) }
            }
        }
        return made
    }

    /// A rule said of what a page loads and of pages in frames, never of
    /// the page itself: WebKit would otherwise refuse to open a page whose
    /// address matches, or take a page's hiding off for an exception that
    /// matches it. A whole site too, "||ads.example^" or a hosts line: a
    /// link that only passes through a tracker (a mail's click tracking, an
    /// ad's redirect) opens. uBlock stops such a page with a warning you
    /// can pass; WebKit has no warning, only a page that never opens. Only
    /// $doc and $all, what the badware lists write, stop the page itself.
    static func ofLoads(_ rule: Rule) -> [Rule] {
        var loads = rule
        loads.types = (everything + ["popup"]).sorted()
        var framed = rule
        framed.types = ["document"]
        framed.context = "child-frame"
        return [loads, framed]
    }

    /// Kinds of load in the lists' words, as WebKit names them. "object"
    /// was a plug-in, which WebKit loads as "other".
    private static let kinds: [String: Set<String>] = [
        "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"], "media": ["media"], "xmlhttprequest": ["fetch"], "xhr": ["fetch"],
        "websocket": ["websocket"], "ping": ["ping"], "beacon": ["ping"], "other": ["other"], "object": ["other"],
    ]
    /// What a page loads, frames and pop-ups aside: what "~image" leaves.
    private static let everything = ["script", "image", "svg-document", "style-sheet", "font", "media", "fetch", "websocket", "ping", "other"]

    /// A pattern every address matches, or every one of a scheme: "|",
    /// "|http", "|https://", "://". Without sites named it would reach the
    /// whole web, the way "*" would.
    static func everywhere(_ pattern: Substring) -> Bool {
        var rest = pattern.lowercased()[...]
        let anchored = rest.hasPrefix("|") && !rest.hasPrefix("||")
        if anchored { rest = rest.dropFirst() }
        while rest.last == "*" || rest.last == "^" { rest = rest.dropLast() }
        if rest.isEmpty { return true }
        let schemes = ["https://", "http://", "wss://", "ws://"]
        return anchored ? schemes.contains { $0.hasPrefix(rest) } : schemes.contains { $0.contains(rest) }
    }

    /// Where the options start: the last "$" followed by something that
    /// reads as options, not a "$" in an address.
    private static func optionsStart(_ pattern: Substring) -> Substring.Index? {
        guard let dollar = pattern.lastIndex(of: "$") else { return nil }
        let tail = pattern[pattern.index(after: dollar)...]
        guard let first = tail.first, first.isLetter || first == "~" || first.isNumber else { return nil }
        return dollar
    }

    /// An ABP pattern as a url-filter WebKit's grammar accepts, or nil.
    /// Worked on bytes: only ASCII gets this far.
    static func urlFilter(_ source: Substring) -> String? {
        guard source.utf8.allSatisfy({ $0 < 0x80 && $0 != 32 }) else { return nil }
        var pattern = Array(source.utf8)[...]
        var out: [UInt8] = []
        out.reserveCapacity(pattern.count * 2 + 24)
        var endAnchor = false
        let star = UInt8(ascii: "*"), caret = UInt8(ascii: "^"), bar = UInt8(ascii: "|")

        if pattern.starts(with: [bar, bar]) {
            pattern = pattern.dropFirst(2)
            let end = pattern.firstIndex(where: { "/^?*|:".utf8.contains($0) }) ?? pattern.endIndex
            let host = pattern[..<end].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            guard host.contains(UInt8(ascii: ".")), host.allSatisfy({ isHostByte($0) }) else { return nil }
            out += Array("^[a-z-]+://([^/]*\\.)?".utf8)
            escape(host[...], into: &out)
            pattern = pattern[end...]
            // Right after the host the separator can only be where the
            // path or the port starts.
            if pattern.first == caret {
                out += Array("[/:]".utf8)
                pattern = pattern.dropFirst()
            }
        } else if pattern.first == bar {
            out.append(caret)
            pattern = pattern.dropFirst()
        }
        if pattern.last == bar {
            endAnchor = true
            pattern = pattern.dropLast()
        }
        // A trailing * says nothing; a leading one neither, unanchored.
        if !endAnchor { while pattern.last == star { pattern = pattern.dropLast() } }
        if out.isEmpty { while pattern.first == star { pattern = pattern.dropFirst() } }
        guard !out.isEmpty || pattern.count >= 3 else { return nil }

        for index in pattern.indices {
            switch pattern[index] {
            case star:
                out += Array(".*".utf8)
            case caret:
                if index == pattern.index(before: pattern.endIndex) {
                    // Last: a separator, or the end of the address.
                    out += Array((endAnchor ? "[^a-zA-Z0-9_.%-]?" : "([^a-zA-Z0-9_.%-].*)?").utf8)
                    endAnchor = true
                } else {
                    out += Array("[^a-zA-Z0-9_.%-]".utf8)
                }
            default:
                escape(pattern[index...index], into: &out)
            }
        }
        if endAnchor { out.append(UInt8(ascii: "$")) }
        guard out.count <= 1024 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 46 || byte == 45 || byte == 95
    }

    private static let special = Set(".?+()[]{}$|\\^*".utf8)

    private static func escape(_ bytes: ArraySlice<UInt8>, into out: inout [UInt8]) {
        for byte in bytes {
            if special.contains(byte) { out.append(UInt8(ascii: "\\")) }
            out.append(byte)
        }
    }

    static func escape(_ text: String) -> String {
        var out: [UInt8] = []
        escape(Array(text.utf8)[...], into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Every address on `site` and its subdomains, as `||site^` reads.
    static func onSite(_ site: String) -> String {
        "^[a-z-]+://([^/]*\\.)?" + escape(site) + "[/:]"
    }

    /// `||example.com^` and nothing else: the site it names.
    private static func pureHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||"), pattern.hasSuffix("^") else { return nil }
        return plainDomain(pattern.dropFirst(2).dropLast())
    }

    /// A domain as WebKit takes it: lowercase ASCII, no wildcards, no
    /// uBO "example.*" that means every top-level domain.
    static func plainDomain(_ value: Substring) -> String? {
        let domain = value.lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return domain
    }

    /// The line a $badfilter line takes back: itself without that option.
    static func unbadfilter(_ line: String) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        let head = String(line[..<dollar])
        return options.isEmpty ? head : head + "$" + options.joined(separator: ",")
    }

    // MARK: - hosts files

    /// `0.0.0.0 ads.example.com`, as Peter Lowe's list writes them.
    static func hostsLine(_ line: String) -> String? {
        guard let first = line.first, first == "0" || first == "1" || first == ":" else { return nil }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, ["127.0.0.1", "0.0.0.0", "::1", "::"].contains(parts[0]) else { return nil }
        return String(parts[1])
    }

    static func hostRule(_ host: String) -> Rule? {
        guard let domain = plainDomain(Substring(host)), domain != "localhost.localdomain" else { return nil }
        return Rule(action: .block, filter: "^[a-z-]+://([^/]*\\.)?" + escape(domain) + "[/:]")
    }
}

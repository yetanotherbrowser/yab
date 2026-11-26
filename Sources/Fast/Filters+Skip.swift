import Foundation

// $urlskip rules, applied by Shield to a top document before it loads (see Filters).

extension Filters {
    // MARK: - urlskip

    /// A $urlskip rule (uBlock Origin's wiki, Static filter syntax,
    /// "urlskip"): for a click tracker's address, the steps that read the
    /// destination out of it, so the tracker is never asked. Kept only for
    /// a tab's top document (uBlock Origin skips frames, images and media
    /// too). uBlock Origin skips a page its lists let load; one they stop
    /// (strict blocking) it skips only for a rule that says -blocked, and
    /// otherwise names the destination on its block page for a click. Yab
    /// has no block page, so a tab goes there either way: what that click
    /// does, with the tracker still never asked.
    struct Skip: Codable, Hashable, Sendable {
        /// The addresses it is for, as a regular expression: the rule's
        /// pattern as Filters makes a url-filter of it, or its own /regex/.
        var pattern: String
        var caseSensitive = false
        /// $to: only an address whose host is one of these or under one,
        /// and none of `notTo`.
        var to: [String] = []
        var notTo: [String] = []
        /// The steps, as the rule writes them, a space between.
        var steps: String
        /// @@…$urlskip=steps: a skip with these steps is off where this
        /// matches.
        var exception = false
    }

    /// Where a line's options start, uBlock Origin's way (indexOfNetAnchor):
    /// the last "$" followed by an option's name, so a "$" inside a regular
    /// expression is passed over.
    private static let optionNames: Set<String> = [
        "1p", "3p", "_", "all", "badfilter", "beacon", "cname", "csp", "css", "denyallow", "doc", "document",
        "domain", "ehide", "elemhide", "empty", "first-party", "font", "frame", "from", "genericblock",
        "generichide", "ghide", "header", "image", "important", "inline-font", "inline-script", "ipaddress",
        "match-case", "media", "method", "mp4", "object", "other", "permissions", "ping", "popunder", "popup",
        "reason", "redirect", "redirect-rule", "removeparam", "replace", "script", "shide", "specifichide",
        "strict1p", "strict3p", "strict-first-party", "strict-third-party", "stylesheet", "subdocument",
        "third-party", "to", "top", "uritransform", "urlskip", "urltransform", "webrtc", "websocket", "xhr",
        "xmlhttprequest",
    ]

    /// A line with $urlskip among its options: whether it is an exception,
    /// its pattern, and its options as uBlock Origin splits them, a comma
    /// inside a value ("[mst]{0,2}") staying in it. Nil for anything else.
    static func skipParts(_ line: String) -> (exception: Bool, pattern: Substring, options: [(name: String, value: Substring?)])? {
        var body = Substring(line)
        let exception = body.hasPrefix("@@")
        if exception { body = body.dropFirst(2) }
        var anchor: Substring.Index?
        var search = body.endIndex
        while let dollar = body[..<search].lastIndex(of: "$") {
            var name = body[body.index(after: dollar)...]
            if name.first == "~" { name = name.dropFirst() }
            let end = name.firstIndex(where: { !($0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_")) }) ?? name.endIndex
            if optionNames.contains(String(name[..<end])) { anchor = dollar; break }
            search = dollar
        }
        guard let anchor else { return nil }
        let text = body[body.index(after: anchor)...]
        var options: [(name: String, value: Substring?)] = []
        var at = text.startIndex
        while at < text.endIndex {
            let stop = text[at...].firstIndex(where: { $0 == "=" || $0 == "," }) ?? text.endIndex
            let name = String(text[at..<stop])
            guard !name.isEmpty else { return nil }
            if stop < text.endIndex, text[stop] == "=" {
                let start = text.index(after: stop)
                let end = nextOption(text, from: start) ?? text.endIndex
                options.append((name, text[start..<end]))
                at = end < text.endIndex ? text.index(after: end) : end
            } else {
                options.append((name, nil))
                at = stop < text.endIndex ? text.index(after: stop) : stop
            }
        }
        guard options.contains(where: { $0.name == "urlskip" }) else { return nil }
        return (exception, body[..<anchor], options)
    }

    /// The comma that ends an option's value: the first one followed by
    /// another option (uBlock Origin's reNetOptionComma,
    /// /,(?:~?[13a-z-]+(?:=.*?)?|_+)(?:,|$)/).
    private static func nextOption(_ text: Substring, from start: Substring.Index) -> Substring.Index? {
        var at = start
        while let comma = text[at...].firstIndex(of: ",") {
            var rest = text[text.index(after: comma)...]
            if rest.first == "~" { rest = rest.dropFirst() }
            let word = rest.prefix { $0 == "1" || $0 == "3" || $0 == "-" || ($0 >= "a" && $0 <= "z") }
            let after = rest[word.endIndex...].first
            if !word.isEmpty, after == nil || after == "," || after == "=" { return comma }
            let bars = rest.prefix { $0 == "_" }
            let next = rest[bars.endIndex...].first
            if !bars.isEmpty, next == nil || next == "," { return comma }
            at = text.index(after: comma)
        }
        return nil
    }

    /// A $urlskip line as a Skip, or nil for one this can't honor exactly:
    /// one for other kinds of load than a page, one that names the sites it
    /// is on ($domain), $to written with an entity or a regular expression,
    /// a step uBlock Origin doesn't know.
    static func skipRule(_ line: String) -> Skip? {
        guard let parts = skipParts(line) else { return nil }
        var skip = Skip(pattern: "", steps: "", exception: parts.exception)
        for (name, value) in parts.options {
            switch name {
            case "urlskip":
                guard let value, !value.isEmpty else { return nil }
                skip.steps = String(value)
            case "doc", "document", "reason":
                continue
            case "1p", "first-party", "~3p", "~third-party":
                continue // a top document is its own first party
            case "match-case":
                skip.caseSensitive = true
            case "to":
                guard let value else { return nil }
                for entry in value.split(separator: "|", omittingEmptySubsequences: false) {
                    let negated = entry.hasPrefix("~")
                    let domain = (negated ? entry.dropFirst() : entry).lowercased()
                    guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix("."),
                          domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
                    else { return nil }
                    if negated { skip.notTo.append(domain) } else { skip.to.append(domain) }
                }
            default:
                return nil
            }
        }
        guard Skipper.steps(skip.steps) != nil else { return nil }
        let pattern = parts.pattern
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            let source = String(pattern.dropFirst().dropLast())
            guard (try? NSRegularExpression(pattern: source)) != nil else { return nil }
            skip.pattern = source
        } else if pattern.isEmpty || pattern == "*" || everywhere(pattern) {
            // Every address, fine only narrowed to the trackers it names.
            guard !skip.to.isEmpty else { return nil }
            skip.pattern = pattern.isEmpty || pattern == "*" ? ".*" : (urlFilter(pattern) ?? ".*")
        } else {
            guard let filter = urlFilter(pattern) else { return nil }
            skip.pattern = filter
        }
        return skip
    }

    /// The skips made ready to match: what a tab asks of the address its
    /// top document is about to load.
    final class Skipper: @unchecked Sendable {
        enum Step {
            case parameter(String), position(Int), hash, capture(NSRegularExpression)
            case https, base64, safeBase64, uriComponent, blocked
        }

        private struct Ready {
            let skip: Skip
            let pattern: NSRegularExpression
            let steps: [Step]
        }

        private let skips: [Ready]
        private let exceptions: [Ready]
        var count: Int { skips.count }

        init(_ all: [Skip]) {
            let ready = all.compactMap { skip -> Ready? in
                guard let pattern = try? NSRegularExpression(pattern: skip.pattern, options: skip.caseSensitive ? [] : [.caseInsensitive]),
                      let steps = Skipper.steps(skip.steps) else { return nil }
                return Ready(skip: skip, pattern: pattern, steps: steps)
            }
            skips = ready.filter { !$0.skip.exception }
            exceptions = ready.filter(\.skip.exception)
        }

        /// The steps of a rule, or nil if one of them is none uBlock Origin
        /// knows, which would end every attempt (urlskip.js).
        static func steps(_ text: String) -> [Step]? {
            var steps: [Step] = []
            for step in text.split(separator: " ") {
                if step == "#" { steps.append(.hash) }
                else if step == "+https" { steps.append(.https) }
                else if step == "-base64" { steps.append(.base64) }
                else if step == "-safebase64" { steps.append(.safeBase64) }
                else if step == "-uricomponent" { steps.append(.uriComponent) }
                else if step == "-blocked" { steps.append(.blocked) }
                else if step.hasPrefix("&") {
                    // parseInt: the digits it starts with.
                    guard let position = Int(step.dropFirst().prefix { $0.isASCII && $0.isNumber }), position >= 1 else { return nil }
                    steps.append(.position(position))
                } else if step.hasPrefix("/") {
                    // `step.slice(1, -1)`, compiled with no flags.
                    guard let capture = try? NSRegularExpression(pattern: String(step.dropFirst().dropLast())) else { return nil }
                    steps.append(.capture(capture))
                } else if step.hasPrefix("?") {
                    steps.append(.parameter(String(step.dropFirst())))
                } else {
                    return nil
                }
            }
            return steps.isEmpty ? nil : steps
        }

        /// Where `url` goes instead: the first skip whose pattern and $to
        /// match and whose every step works, as uBlock Origin takes them;
        /// nil when none does, or one would only come back to `url`.
        func destination(_ url: String) -> String? {
            guard url.utf8.count <= 8192, !skips.isEmpty else { return nil }
            let host = URL(string: url)?.host()?.lowercased() ?? ""
            let whole = NSRange(url.startIndex..., in: url)
            func matches(_ ready: Ready) -> Bool {
                let skip = ready.skip
                if !skip.to.isEmpty, !skip.to.contains(where: { Skipper.on(host, $0) }) { return false }
                if skip.notTo.contains(where: { Skipper.on(host, $0) }) { return false }
                return ready.pattern.firstMatch(in: url, range: whole) != nil
            }
            let off = Set(exceptions.filter(matches).map(\.skip.steps))
            for ready in skips where !off.contains(ready.skip.steps) && matches(ready) {
                guard let out = Skipper.run(url, ready.steps), out != url else { continue }
                return out
            }
            return nil
        }

        private static func on(_ host: String, _ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }

        /// uBlock Origin's urlSkip (src/js/urlskip.js), step for step. A
        /// step that fails ends it, and so does a result that is no http or
        /// https address.
        static func run(_ url: String, _ steps: [Step]) -> String? {
            var out = url
            for step in steps {
                let input = out
                switch step {
                case .hash:
                    out = input.firstIndex(of: "#").map { String(input[input.index(after: $0)...]) } ?? ""
                case .position(let position):
                    guard address(input) else { return nil }
                    let names = form(query(input)).map(\.name)
                    guard position <= names.count, let name = names[position - 1].removingPercentEncoding else { return nil }
                    out = name
                case .https:
                    var rest = Substring(input)
                    if rest.hasPrefix("https://") { rest = rest.dropFirst(8) } else if rest.hasPrefix("http://") { rest = rest.dropFirst(7) }
                    // /^[\w-]:\/\// rules out a scheme of one letter left.
                    if let first = rest.first, first.isASCII, first.isLetter || first.isNumber || first == "_" || first == "-",
                       rest.dropFirst().hasPrefix("://") { return nil }
                    out = "https://" + rest
                case .base64:
                    guard let decoded = atob(input) else { return nil }
                    out = decoded
                case .safeBase64:
                    let standard = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    guard let decoded = atob(standard) else { return nil }
                    out = decoded
                case .uriComponent:
                    guard let decoded = input.removingPercentEncoding else { return nil }
                    out = decoded
                case .blocked:
                    continue
                case .capture(let expression):
                    guard let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                          match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) else { return nil }
                    out = String(input[range])
                case .parameter(let name):
                    guard address(input), let value = form(query(input)).first(where: { $0.name == name })?.value else { return nil }
                    out = value.replacingOccurrences(of: " ", with: "%20")
                }
            }
            guard let final = URL(string: out), let scheme = final.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = final.host(), !host.isEmpty else { return nil }
            return out
        }

        /// `new URL(text)` would take it: an absolute address.
        private static func address(_ text: String) -> Bool {
            URL(string: text)?.scheme != nil
        }

        /// An address's query: after its first "?", up to its fragment.
        private static func query(_ text: String) -> Substring {
            let end = text.firstIndex(of: "#") ?? text.endIndex
            guard let mark = text[..<end].firstIndex(of: "?") else { return "" }
            return text[text.index(after: mark)..<end]
        }

        /// URLSearchParams' reading of a query (application/x-www-form-
        /// urlencoded): "+" a space, escapes decoded where they are escapes.
        private static func form(_ query: Substring) -> [(name: String, value: String)] {
            query.split(separator: "&").map { pair in
                let equals = pair.firstIndex(of: "=")
                let name = equals.map { pair[..<$0] } ?? pair
                let value = equals.map { pair[pair.index(after: $0)...] } ?? ""
                return (decode(name), decode(value))
            }
        }

        private static func decode(_ text: Substring) -> String {
            let bytes = Array(text.utf8)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var index = 0
            func hex(_ byte: UInt8) -> UInt8? {
                switch byte {
                case 48...57: return byte - 48
                case 65...70: return byte - 55
                case 97...102: return byte - 87
                default: return nil
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 37, index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                } else {
                    out.append(byte == 43 ? 32 : byte)
                    index += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// `atob`: forgiving base64, each byte one character (Latin-1).
        private static func atob(_ text: String) -> String? {
            var digits = Array(text.utf8.filter { ![9, 10, 12, 13, 32].contains($0) })
            if digits.count % 4 == 0 {
                if digits.last == 61 { digits.removeLast() }
                if digits.last == 61 { digits.removeLast() }
            }
            guard digits.count % 4 != 1 else { return nil }
            var bits: UInt32 = 0, count = 0
            var scalars = String.UnicodeScalarView()
            for byte in digits {
                let value: UInt8
                switch byte {
                case 65...90: value = byte - 65
                case 97...122: value = byte - 71
                case 48...57: value = byte + 4
                case 43: value = 62
                case 47: value = 63
                default: return nil
                }
                bits = bits << 6 | UInt32(value)
                count += 6
                if count >= 8 {
                    count -= 8
                    scalars.append(Unicode.Scalar(UInt8((bits >> UInt32(count)) & 0xff)))
                }
            }
            return String(scalars)
        }
    }
}

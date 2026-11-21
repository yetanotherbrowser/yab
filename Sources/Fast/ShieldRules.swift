import Foundation

// Filters' rules as the Chromium helper reads them (YabCore/src/shield_engine.h).
// WebKit enforces its own lists; a Chromium request is matched in the helper,
// and this writes what it needs: each url-filter back in the shape the lists
// wrote it, since WebKit's regular expressions are of a small fixed grammar.
enum ShieldRules {
    private static let host = "^[a-z-]+://([^/]*\\.)?"
    private static let separator = "[^a-zA-Z0-9_.%-]"

    struct Pattern: Equatable {
        var text: String
        var flags: Int
    }

    private enum Flag {
        static let host = 1, start = 2, end = 4, caseSensitive = 8, first = 16, third = 32, top = 64, child = 128
    }

    /// A url-filter Filters wrote, or nil for anything else. The bytes the
    /// helper reads as signs: * ^ and 1, 2, 3 below space.
    static func pattern(_ filter: String) -> Pattern? {
        var flags = 0
        var rest = Substring(filter)
        if rest == ".*" { return Pattern(text: "", flags: 0) }
        if rest.hasPrefix(host) {
            rest = rest.dropFirst(host.count)
            flags |= Flag.host
        } else if rest.first == "^" {
            rest = rest.dropFirst()
            flags |= Flag.start
        }
        var out = ""
        out.reserveCapacity(rest.utf8.count)
        while let next = rest.first {
            if rest.hasPrefix("(" + separator + ".*)?$"), rest.count == separator.count + 6 {
                out.append("\u{02}")
                rest = rest.dropFirst(rest.count)
            } else if rest.hasPrefix(separator + "?$"), rest.count == separator.count + 2 {
                out.append("\u{03}")
                rest = rest.dropFirst(rest.count)
            } else if rest.hasPrefix(separator) {
                out.append("^")
                rest = rest.dropFirst(separator.count)
            } else if rest.hasPrefix("[/:]") {
                out.append("\u{01}")
                rest = rest.dropFirst(4)
            } else if rest.hasPrefix(".*") {
                out.append("*")
                rest = rest.dropFirst(2)
            } else if next == "\\" {
                rest = rest.dropFirst()
                guard let literal = rest.first, literal != "*", literal != "^" else { return nil }
                out.append(literal)
                rest = rest.dropFirst()
            } else if next == "$", rest.count == 1 {
                flags |= Flag.end
                rest = rest.dropFirst()
            } else if ".?+()[]{}$|^*".contains(next) {
                return nil
            } else {
                out.append(next)
                rest = rest.dropFirst()
            }
        }
        return Pattern(text: out, flags: flags)
    }

    private static let kinds = ["script": 1, "image": 2, "svg-document": 2, "style-sheet": 4, "font": 8, "media": 16,
                                "fetch": 32, "websocket": 64, "ping": 128, "other": 256, "document": 512, "popup": 1024]

    private static func line(_ rule: Filters.Rule, _ group: String) -> String? {
        guard var made = pattern(rule.filter), !rule.ifDomain.isEmpty || !rule.unlessDomain.isEmpty || !made.text.isEmpty else { return nil }
        if rule.caseSensitive { made.flags |= Flag.caseSensitive }
        if rule.party == "first-party" { made.flags |= Flag.first }
        if rule.party == "third-party" { made.flags |= Flag.third }
        if rule.context == "top-frame" { made.flags |= Flag.top }
        if rule.context == "child-frame" { made.flags |= Flag.child }
        let kinds = rule.types.reduce(0) { $0 | (Self.kinds[$1] ?? 0) }
        let domains = rule.ifDomain.isEmpty ? (rule.unlessDomain.isEmpty ? "" : "~" + rule.unlessDomain.joined(separator: ",")) : rule.ifDomain.joined(separator: ",")
        return "N\t\(group)\t\(kinds)\t\(made.flags)\t\(domains)\t\(made.text)"
    }

    /// The site a hiding rule names, from Filters.onSite.
    static func site(_ filter: String) -> String? {
        guard filter.hasPrefix(host), filter.hasSuffix("[/:]") else { return nil }
        let name = filter.dropFirst(host.count).dropLast(4)
        // An entity (Filters.onEntity) is a pattern, not a site the helper can look up.
        guard !name.contains("[") else { return nil }
        return name.replacingOccurrences(of: "\\", with: "")
    }

    /// The whole file. Lines nobody can read in this form are left out; the
    /// count says how many, for the bench.
    static func text(_ rules: Filters.Rules) -> (text: String, left: Int) {
        var lines = ["YABSHIELD1"]
        lines.reserveCapacity(rules.count + 1)
        var left = 0
        func network(_ rule: Filters.Rule, _ group: String) {
            if let line = line(rule, group) { lines.append(line) } else { left += 1 }
        }
        for rule in rules.blocks {
            switch rule.action {
            case .hide(let selector):
                if let site = site(rule.filter) { lines.append("H\t\(site)\t\(selector)") } else { left += 1 }
            default: network(rule, "block")
            }
        }
        for rule in rules.exceptions { network(rule, "allow") }
        for rule in rules.important { network(rule, "important") }
        for rule in rules.generic {
            guard case .hide(let selector) = rule.action else { continue }
            lines.append(rule.unlessDomain.isEmpty ? "G\t\(selector)" : "S\t\(rule.unlessDomain.joined(separator: ","))\t\(selector)")
        }
        for rule in rules.unhide {
            guard let made = pattern(rule.filter) else { left += 1; continue }
            lines.append("U\t\(made.flags)\t\(rule.ifDomain.joined(separator: ","))\t\(made.text)")
        }
        return (lines.joined(separator: "\n") + "\n", left)
    }
}

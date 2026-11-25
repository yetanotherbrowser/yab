import Foundation

// Hiding rules (##, #@#) as WebKit css-display-none rules (see Filters).

extension Filters {
    // MARK: - cosmetic rules

    static func cosmeticMarker(_ line: String) -> Range<String.Index>? {
        // The earliest of them, and never inside an attribute selector.
        guard let hash = line.firstIndex(of: "#") else { return nil }
        if let bracket = line.firstIndex(of: "["), bracket < hash { return nil }
        for marker in ["##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#"] {
            if let range = line.range(of: marker), range.lowerBound == hash { return range }
        }
        return nil
    }

    /// Hiding rules, gathered first because an exception anywhere in the
    /// lists ("site#@#.ad") changes the rule for that selector everywhere.
    struct Hides {
        var everywhere = Set<String>()
        var sparing: [String: Set<String>] = [:]
        var only: [String: Set<String>] = [:]
        var order: [String] = []
        var spared: [String: Set<String>] = [:]
        var anywhereSpared = Set<String>()
        /// Sites with all their hiding off ($elemhide).
        var unhidden = Set<String>()

        /// Nil when the line is taken, or why it is not (Drop).
        mutating func take(_ line: String, _ marker: Range<String.Index>) -> String? {
            let kind = line[marker]
            guard kind == "##" || kind == "#@#" else {
                if kind == "#%#" || kind == "#@%#" {
                    return line[marker.upperBound...].hasPrefix("//scriptlet(") ? Drop.adguardScriptlet : Drop.adguardJS
                }
                return kind.contains("$") ? Drop.cssInjection : Drop.procedural
            }
            let selector = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if let problem = Filters.selectorProblem(selector) { return problem }
            let domains = line[..<marker.lowerBound]
            var includes: [String] = []
            var excludes: [String] = []
            for piece in domains.split(separator: ",") {
                let part = piece.trimmingCharacters(in: .whitespaces)
                if part.hasPrefix("~") {
                    // WebKit's unless-domain can't name an entity.
                    guard let clean = plainDomain(Substring(part.dropFirst())) else {
                        return entity(Substring(part.dropFirst())) != nil ? Drop.entityExclude : Drop.badDomain
                    }
                    excludes.append(clean)
                } else {
                    guard let clean = plainDomain(Substring(part)) ?? entity(Substring(part)) else { return Drop.badDomain }
                    includes.append(clean)
                }
            }
            if kind == "#@#" {
                // An exception with no site takes the selector away.
                guard excludes.isEmpty else { return Drop.exceptionExcluding }
                if includes.isEmpty { anywhereSpared.insert(selector) } else { spared[selector, default: []].formUnion(includes) }
                return nil
            }
            guard includes.isEmpty || excludes.isEmpty else { return Drop.mixedSites }
            if everywhere.contains(selector) == false, sparing[selector] == nil, only[selector] == nil { order.append(selector) }
            if !includes.isEmpty {
                only[selector, default: []].formUnion(includes)
            } else if !excludes.isEmpty {
                sparing[selector, default: []].formUnion(excludes)
            } else {
                everywhere.insert(selector)
            }
            return nil
        }

        /// The generic rules, the sites' own, how many of the sites' own
        /// were dropped whole, and the sites that kept some.
        func rules() -> (generic: [Rule], own: [Rule], dropped: Int, sites: Set<String>) {
            var generic: [Rule] = []
            var own: [Rule] = []
            var dropped = 0
            var named = Set<String>()
            for selector in order where !anywhereSpared.contains(selector) {
                let spare = spared[selector] ?? []
                if everywhere.contains(selector) || sparing[selector] != nil {
                    // Everywhere but where it is excepted. A generic rule
                    // with sites to spare is no longer in the stylesheet
                    // WebKit gives every page; it is matched per page, as a
                    // site's own rules are.
                    // An entity spared is left out: unless-domain can't
                    // name one, and before entities were read it was too.
                    let unless = (everywhere.contains(selector) ? spare : spare.union(sparing[selector] ?? [])).filter { !$0.hasSuffix(".*") }
                    generic.append(Rule(action: .hide(selector), filter: ".*", unlessDomain: unless.sorted()))
                } else if let sites = only[selector] {
                    // A site stays only if nothing spares it: not itself, not
                    // a domain above it, and not a part of it, since WebKit
                    // can't say "example.com but not shop.example.com" in
                    // one rule and the rule for the whole site would reach
                    // the part.
                    let off = spare.union(unhidden)
                    let left = sites.filter { site in !off.contains(where: { Filters.overlap(site, $0) }) }
                    // One rule a site, matched by the address of the page
                    // (and anything else loaded from the site), not a rule
                    // for every address with the site as a condition: WebKit
                    // gives every load of every page each rule whose
                    // url-filter matches before it looks at conditions, and
                    // ten thousand ".*" hiding rules held every script and
                    // image nytimes.com loads while it was being read, its
                    // HTML parsed in 1.4 s instead of 0.2.
                    if left.isEmpty { dropped += 1 }
                    for site in left.sorted() {
                        let filter = site.hasSuffix(".*") ? Filters.onEntity(String(site.dropLast(2))) : Filters.onSite(site)
                        own.append(Rule(action: .hide(selector), filter: filter))
                    }
                    named.formUnion(left)
                }
            }
            return (generic, own, dropped, named)
        }
    }

    /// A selector CSS can read, uBO's own additions ruled out. WebKit checks
    /// again when it compiles and drops what it can't parse, but those are
    /// best not counted against the cap.
    static func selector(_ selector: String) -> Bool {
        selectorProblem(selector) == nil
    }

    /// Why a selector is not one (Drop), or nil.
    static func selectorProblem(_ selector: String) -> String? {
        guard !selector.isEmpty, selector.count <= 1024 else { return Drop.badSelector }
        guard selector.allSatisfy(\.isASCII) else { return Drop.nonASCII }
        if selector.hasPrefix("+js(") { return Drop.scriptletMalformed }
        if selector.hasPrefix("^") { return Drop.htmlFiltering }
        if selector.hasPrefix("{") { return Drop.cssInjection }
        for token in [":has-text(", ":contains(", ":xpath(", ":upward(", ":nth-ancestor(", ":-abp-", ":matches-css",
                      ":matches-attr", ":matches-path", ":matches-prop", ":matches-media", ":min-text-length(",
                      ":watch-attr(", ":remove", ":style(", ":others(", ":if(", ":if-not("] where selector.contains(token) {
            return Drop.procedural
        }
        if selector.contains("{") || selector.contains("}") { return Drop.cssInjection }
        return nil
    }
}

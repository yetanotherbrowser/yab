import Foundation

// Filter lists, the ones uBlock Origin reads, turned into rules WebKit
// enforces itself (see Shield). Only what a WebKit rule says exactly is
// kept; everything else is left out rather than stretched to fit, because
// a rule that blocks a little more than its list meant is how a blocker
// breaks a checkout. Left out: scriptlets, redirects, $csp, $removeparam,
// regular expressions, procedural cosmetics, rules that name both sites to
// act on and sites to spare.
//
// WebKit is strict about what it reads. One url-filter it cannot parse (a
// disjunction, a {n} repetition, a character outside ASCII) or one domain
// with a capital in it fails the whole list, not the rule, so what is made
// here stays inside that grammar. An invalid CSS selector only costs its
// own rule.
//
// One more thing WebKit does its own way: an exception (ignore-previous-rules)
// only cancels the rules before it in the same list. Split into several
// lists, an exception would reach only the block rules that happened to
// land in its own, so every list carries all of them at its end, and the
// $important rules after those, where no exception reaches.
//
// The hiding rules for every site are a list of their own for the same
// reason turned around: a site that asks for them off ($generichide) is
// named at that list's end, where the exception reaches those rules and no
// block. And what a list doesn't say of a rule it says of all of them, the
// page itself included: a rule without kinds of load is given every kind
// but the page, so "/adv/" hides a banner and doesn't stop you opening a
// page under /adv/, "||tracker.example^" doesn't stop a mail's link that
// passes through it, and an exception without kinds doesn't turn a page's
// hiding off.

enum Filters {
    /// As many rules a list as WebKit takes (150 000), less a margin. Every
    /// load a page makes is matched against every list, in the web
    /// process's main thread, and each list ends with every exception
    /// (see above), so a list costs each load its own run over the address
    /// and its own copy of those 3 800 exceptions. In six lists of 40 000
    /// that was 0.8 ms a load, 1.15 ms for a long image address, on adhd;
    /// mobbin.com's screens make about two thousand such checks while their
    /// HTML is read, which held DOMContentLoaded at 2.8 s instead of 0.6.
    /// One list of blocks and one of generic hiding take a third less, and
    /// the one list compiles in 5 s off the main thread where six took 9.
    /// YAB_SHIELD_PERLIST at launch tries another size, for measuring.
    static let perList = Int(ProcessInfo.processInfo.environment["YAB_SHIELD_PERLIST"] ?? "") ?? 149_000
    /// Beyond this, the lists are left as they are: three lists, room for
    /// blocking to grow into a second one with the hiding for every site
    /// still given its own, and never less than the 240 000 rules six lists
    /// of 40 000 held. Every page's rules are looked through for every
    /// request, so more is not free.
    static let cap = max(perList * 3, 240_000)

    struct Rule: Hashable {
        enum Action: Hashable {
            case block
            case allow
            case hide(String)
        }

        var action: Action
        var filter: String
        var caseSensitive = false
        var types: [String] = []
        var party: String?
        var context: String?
        var ifDomain: [String] = []
        var unlessDomain: [String] = []

        /// The rule as WebKit reads it, written out by hand: this is done
        /// for a couple of hundred thousand rules, and JSONSerialization of
        /// as many dictionaries took seconds.
        var json: String {
            var trigger = "\"url-filter\":\(Filters.quote(filter))"
            if caseSensitive { trigger += ",\"url-filter-is-case-sensitive\":true" }
            if !types.isEmpty { trigger += ",\"resource-type\":\(Filters.quote(types))" }
            if let party { trigger += ",\"load-type\":[\"\(party)\"]" }
            if let context { trigger += ",\"load-context\":[\"\(context)\"]" }
            if !ifDomain.isEmpty { trigger += ",\"if-domain\":\(Filters.quote(ifDomain.map { "*" + $0 }))" }
            if !unlessDomain.isEmpty { trigger += ",\"unless-domain\":\(Filters.quote(unlessDomain.map { "*" + $0 }))" }
            let action: String
            switch self.action {
            case .block: action = "{\"type\":\"block\"}"
            case .allow: action = "{\"type\":\"ignore-previous-rules\"}"
            case .hide(let selector): action = "{\"type\":\"css-display-none\",\"selector\":\(Filters.quote(selector))}"
            }
            return "{\"trigger\":{\(trigger)},\"action\":\(action)}"
        }
    }

    /// What came out of the lists, sorted by where each rule has to stand.
    struct Rules {
        var blocks: [Rule] = []
        var exceptions: [Rule] = []
        var important: [Rule] = []
        /// Hiding rules for every site, or every site but a few, and the
        /// exceptions that end their list: the sites and pages that turn
        /// them off.
        var generic: [Rule] = []
        var unhide: [Rule] = []
        /// Lines that were rules of a kind left out, comments not counted.
        var skipped = 0
        /// The sites with hiding rules of their own: a page of one of them
        /// (or of a part of one) always gets the lists, never what Shield
        /// learned of the site.
        var hidingSites = Set<String>()
        /// $urlskip rules of the lists uBlock Origin trusts with them (its
        /// own): a click tracker's address and how its destination is read
        /// out of it. Not WebKit's to enforce; Shield applies them to a
        /// tab's top document before it loads (Skip).
        var skips: [Skip] = []

        var count: Int { blocks.count + exceptions.count + important.count + generic.count + unhide.count }
    }

    /// Where a rule made from a network line goes.
    enum Place: Hashable {
        case plain
        case important
        /// $generichide: the generic hiding rules off where it matches.
        case unhide
        /// $elemhide: all hiding off, the site's own rules too.
        case unhideAll
    }

    private struct PlacedRule: Hashable {
        var rule: Rule
        var place: Place
    }

    // MARK: - converting

    /// `trusted`: the texts, by index, whose $urlskip rules are taken.
    /// uBlock Origin takes them only from a list it trusts (its own), since
    /// a rule can send any address anywhere.
    static func convert(_ texts: [String], trusted: Set<Int> = []) -> Rules {
        // Lines cut on bytes rather than characters: a few megabytes of
        // text, and walking it character by character was most of the time.
        var lines: [String] = []
        var skipLines: [String] = []
        for (index, text) in texts.enumerated() {
            for line in text.utf8.split(separator: UInt8(ascii: "\n")) {
                guard let trimmed = trim(Substring(line)) else { continue }
                lines.append(trimmed)
                if trusted.contains(index), trimmed.contains("urlskip=") { skipLines.append(trimmed) }
            }
        }

        // $badfilter takes back the rule it repeats, in whichever list.
        var taken = Set<String>()
        for line in lines where line.contains("badfilter") {
            if let undone = unbadfilter(line) { taken.insert(undone) }
        }

        var rules = Rules()
        // An identical block after the exceptions still has work to do.
        // Deduplicate within its output group, not across rule precedence.
        var seen = Set<PlacedRule>()
        var hides = Hides()
        for line in lines {
            if line.hasPrefix("!") || line.hasPrefix("[") { continue }
            // A $urlskip line is a skip (above), never a block of its own.
            if line.contains("urlskip="), skipParts(line) != nil {
                rules.skipped += 1
                continue
            }
            if taken.contains(line) || line.contains("badfilter") {
                rules.skipped += 1
                continue
            }
            if let host = hostsLine(line) {
                // A hosts entry is the same whole-site rule as ||host^.
                // uBlock's $badfilter may name that form in another list.
                if taken.contains("||\(host.lowercased())^") {
                    rules.skipped += 1
                    continue
                }
                for rule in hostRule(host).map(ofLoads) ?? [] where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted {
                    rules.blocks.append(rule)
                }
                continue
            }
            if line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") && !line.hasPrefix("#?#") && !line.hasPrefix("#$#") {
                continue // a comment in a hosts file
            }
            if let marker = cosmeticMarker(line) {
                if !hides.take(line, marker) { rules.skipped += 1 }
                continue
            }
            guard let made = network(line) else {
                rules.skipped += 1
                continue
            }
            for (rule, place) in made {
                // $elemhide and $generichide emit the same generic-list
                // exception, but only the former removes site-owned hiding.
                if place == .unhideAll { hides.unhidden.formUnion(rule.ifDomain) }
                let group: Place = place == .unhideAll ? .unhide : place
                guard seen.insert(PlacedRule(rule: rule, place: group)).inserted else { continue }
                switch place {
                case .unhide, .unhideAll:
                    rules.unhide.append(rule)
                case .important:
                    rules.important.append(rule)
                case .plain:
                    if rule.action == .allow { rules.exceptions.append(rule) } else { rules.blocks.append(rule) }
                }
            }
        }
        // $badfilter takes these back too, by the same exact line.
        var skipSeen = Set<Skip>()
        for line in skipLines where !taken.contains(line) && !line.contains("badfilter") {
            if let skip = skipRule(line), skipSeen.insert(skip).inserted { rules.skips.append(skip) }
        }
        let (generic, own, dropped, sites) = hides.rules()
        rules.hidingSites = sites
        rules.skipped += dropped
        for rule in generic where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted { rules.generic.append(rule) }
        for rule in own where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted { rules.blocks.append(rule) }
        return rules
    }

    /// A line without the spaces, tabs and carriage return around it, or
    /// nil if nothing is left.
    private static func trim(_ line: Substring) -> String? {
        let bytes = line.utf8
        let blank: (UInt8) -> Bool = { $0 == 32 || $0 == 9 || $0 == 13 }
        guard let first = bytes.firstIndex(where: { !blank($0) }), let last = bytes.lastIndex(where: { !blank($0) }) else { return nil }
        return String(Substring(bytes[first...last]))
    }

    /// The rules as lists WebKit compiles one by one, and how many were
    /// left out to stay under the cap.
    struct Split {
        var lists: [String]
        var left: Int
        /// How many of the lists, at the end, hold only the generic hiding
        /// and the exceptions that reach it: what a quiet site keeps.
        var hiding = 0
    }

    /// The block and site hiding rules shared out, and after them, in every
    /// list, every exception, then every $important rule; then the generic
    /// hiding rules, each of their lists ended by the exceptions that reach
    /// a page's hiding. Select at most `cap / perList` full-sized lists first;
    /// unsafe action sets may need more, smaller lists, with the same rules.
    /// This adds matching work only for those sets. Over the selection cap, the
    /// rules read last are the ones left out, the lists being read in the
    /// order they are named, the most useful first, and generic hiding
    /// after blocking. Nil when the exceptions alone would crowd the lists,
    /// which is a list gone wrong rather than one to cut: the build before
    /// is kept.
    static func lists(_ rules: Rules, perList: Int = perList, cap: Int = cap) -> Split? {
        guard let plan = plan(rules, perList: perList, cap: cap) else { return nil }
        return Split(lists: plan.parts.map(\.json), left: plan.left, hiding: plan.hiding)
    }

    struct Part {
        var body: ArraySlice<Rule>
        var tail: [Rule]
        var json: String {
            "[" + (body + tail).map(\.json).joined(separator: ",") + "]"
        }
    }

    struct Plan {
        var parts: [Part]
        var left: Int
        var hiding: Int
    }

    /// Keep the rule slices until needed, rather than every list's JSON
    /// alongside WebKit's compiler. The iPhone compiles one part at a time.
    static func plan(_ rules: Rules, perList: Int = perList, cap: Int = cap) -> Plan? {
        let most = max(1, cap / perList)
        // Exceptions and $important rules end every list; past a quarter
        // of one, the lists would be mostly the same rules over and over.
        let limit = perList / 4
        guard rules.exceptions.count <= limit else { return nil }
        let important = rules.important.prefix(limit - rules.exceptions.count)
        // An exception with no kind of load is one for the whole page,
        // @@||site^$document, and turns its hiding off too.
        let whole = rules.exceptions.filter { $0.types.isEmpty }
        let unhide = rules.unhide.prefix(max(0, limit - whole.count))
        var left = rules.important.count - important.count + rules.unhide.count - unhide.count

        let tail = rules.exceptions + important
        let room = perList - tail.count
        var blocks = rules.blocks[...]
        let needed = blocks.isEmpty && important.isEmpty ? 0 : max(1, (blocks.count + room - 1) / room)
        if needed > most {
            left += blocks.count - most * room
            blocks = blocks.prefix(most * room)
        }
        let hidingTail = whole + unhide
        let hidingRoom = perList - hidingTail.count
        var generic = rules.generic[...]
        let spare = most - min(needed, most)
        if generic.count > spare * hidingRoom {
            left += generic.count - spare * hidingRoom
            generic = generic.prefix(spare * hidingRoom)
        }

        var parts: [Part] = []
        func share(_ body: ArraySlice<Rule>, room: Int, tail: [Rule]) -> Bool {
            // Any tail action may be distinct, including after an exception
            // clears WebKit's combining maps. Reserve all of them each time.
            guard tail.count <= UniversalActions.limit else { return false }
            var start = body.startIndex
            repeat {
                var actions = UniversalActions()
                var end = start
                while end < body.endIndex, end - start < room {
                    let rule = body[end]
                    guard actions.count + actions.cost(rule) + tail.count <= UniversalActions.limit else { break }
                    actions.append(rule)
                    end += 1
                }
                guard end > start || start == body.endIndex else { return false }
                if start < end || !tail.isEmpty { parts.append(Part(body: body[start..<end], tail: tail)) }
                start = end
            } while start < body.endIndex
            return true
        }
        if needed > 0, !share(blocks, room: room, tail: tail) { return nil }
        let blocking = parts.count
        if !generic.isEmpty, !share(generic, room: hidingRoom, tail: hidingTail) { return nil }
        return Plan(parts: parts, left: left, hiding: parts.count - blocking)
    }

    /// A conservative bound on distinct actions in any universal DFA root.
    /// WebKit requires fewer than UInt16.max, even below its rule-count cap.
    /// Conditions prevent combining; plain blocks share an action by flags,
    /// and plain CSS selectors share one by trigger, until an allow resets it.
    /// Source: WebKit ContentExtensionCompiler.cpp, serializeActions and
    /// addUniversalActionsToDFA, blob 576a1d54820fd497996d0bd512d1fd8403e768bd.
    struct UniversalActions {
        static let limit = Int(UInt16.max) - 1
        private(set) var count = 0
        private var blocks = Set<Rule>()
        private var hides = Set<Rule>()

        private func key(_ rule: Rule) -> Rule {
            var key = rule
            switch rule.action {
            case .block: key.filter = ""
            case .hide: key.action = .hide("")
            case .allow: break
            }
            return key
        }

        func cost(_ rule: Rule) -> Int {
            if rule.action == .allow || !rule.ifDomain.isEmpty || !rule.unlessDomain.isEmpty { return 1 }
            switch rule.action {
            case .block:
                // Counting even non-universal blocks is safe and stays small.
                return blocks.contains(key(rule)) ? 0 : 1
            case .hide:
                // onSite requires characters. URLFilterParser cannot put it
                // on the universal root. Other patterns are counted, even if
                // they too need characters, instead of guessing their regex.
                if rule.filter.hasPrefix("^[a-z-]+://") { return 0 }
                return hides.contains(key(rule)) ? 0 : 1
            case .allow: return 1
            }
        }

        mutating func append(_ rule: Rule) {
            count += cost(rule)
            if rule.action == .allow {
                blocks.removeAll(keepingCapacity: true)
                hides.removeAll(keepingCapacity: true)
            } else if rule.ifDomain.isEmpty && rule.unlessDomain.isEmpty {
                switch rule.action {
                case .block: blocks.insert(key(rule))
                case .hide where !rule.filter.hasPrefix("^[a-z-]+://"): hides.insert(key(rule))
                default: break
                }
            }
        }
    }

    // MARK: - JSON

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func quote(_ list: [String]) -> String {
        "[" + list.map { quote($0) }.joined(separator: ",") + "]"
    }
}

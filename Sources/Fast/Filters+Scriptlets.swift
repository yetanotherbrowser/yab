import Foundation

// Scriptlets (##+js, #@#+js) as the per-site table the page script reads (see Filters).

extension Filters {
    // MARK: - scriptlets

    /// The scriptlets the lists name for each site, as the page script
    /// (shield-scriptlets.js) reads them: calls, and for each host or
    /// entity the calls it runs. A negative entry -(i + 1) cancels call i
    /// there; `off` there runs none.
    struct Scriptlets: Equatable, Sendable {
        static let off = Int.min

        /// [canonical name, arguments…], each once, in the order first seen.
        var calls: [[String]] = []
        /// A lowercase host ("example.com") or entity ("example.*") to call
        /// indexes: the ones it runs first, ascending, then the ones it
        /// cancels. The same call can be at two indexes (ScriptletRules.table);
        /// the page runs it once.
        var hosts: [String: [Int]] = [:]

        var isEmpty: Bool { calls.isEmpty }

        /// The names the page script knows, and uBO's other names for them.
        /// Anything else is left out (Drop.scriptletUnsupported).
        static let names: [String: String] = [
            "aopr": "aopr", "abort-on-property-read": "aopr",
            "aopw": "aopw", "abort-on-property-write": "aopw",
            "acs": "acs", "abort-current-script": "acs", "acis": "acs", "abort-current-inline-script": "acs",
            "set": "set", "set-constant": "set",
            "aeld": "aeld", "addeventlistener-defuser": "aeld", "prevent-addeventlistener": "aeld",
            "nostif": "nostif", "no-settimeout-if": "nostif", "settimeout-defuser": "nostif", "prevent-settimeout": "nostif",
            "nowoif": "nowoif", "no-window-open-if": "nowoif", "window.open-defuser": "nowoif", "prevent-window-open": "nowoif",
        ]

        /// The table as one JSON object, its keys sorted so its digest
        /// stays put: {"v":2,"calls":"…","hosts":" key=0,1 … "}. The calls
        /// are one string, a call to a line, its name and arguments split by
        /// tabs; the hosts another, found with indexOf(" " + key + "=").
        /// Nothing in either is parsed until a site matches, and then only
        /// the calls it runs. A call or key that isn't `carriable` would
        /// break that format: the builder (ScriptletRules.table) leaves
        /// those out first.
        func table() -> String {
            let sites = " " + hosts.keys.sorted().map { key in
                let list = hosts[key] ?? []
                return key + "=" + (list.contains(Scriptlets.off) ? "*off" : list.map(String.init).joined(separator: ",")) + " "
            }.joined()
            let lines = calls.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            let json = "{\"v\":2,\"calls\":" + Filters.quote(lines) + ",\"hosts\":" + Filters.quote(sites) + "}"
            // Inside a script, as a literal, these two end a line in older engines.
            return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        /// Whether a call fits the table: tabs split its parts and newlines
        /// its calls, so no part may hold a control character.
        static func carriable(_ call: [String]) -> Bool {
            call.allSatisfy { part in !part.unicodeScalars.contains { $0.value < 0x20 } }
        }

        /// Whether a host or entity can be a key of the table: lowercase
        /// ASCII letters and digits, and . _ * - (^[a-z0-9._*-]+$).
        static func carriable(host: String) -> Bool {
            !host.isEmpty && host.utf8.allSatisfy { byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 46 || byte == 95 || byte == 42 || byte == 45
            }
        }

        /// The library as the page runs it: lines that are only a // comment
        /// and empty lines gone, indentation stripped. Safe for a library
        /// with no multi-line string or template literal in it.
        static func compact(_ library: String) -> String {
            library.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").compactMap { line in
                let code = line.drop { $0 == " " || $0 == "\t" }
                return code.isEmpty || code.hasPrefix("//") ? nil : String(code)
            }.joined(separator: "\n")
        }

        /// The library as served: shield-scriptlets.js with the click guard
        /// (shield-guard.js) inside at its marker, so the guard runs only
        /// where the table names the page's site, then compacted.
        static func library(_ scriptlets: String, clickGuard: String) -> String {
            compact(scriptlets.replacingOccurrences(of: "__YAB_GUARD__", with: clickGuard))
        }

        /// The page script: the library with Shield's off sites and the table
        /// in. OFF first: a list's argument could spell the other marker.
        static func page(_ library: String, table: String, off: String) -> String {
            library.replacingOccurrences(of: "__YAB_OFF__", with: off)
                .replacingOccurrences(of: "__YAB_TABLE__", with: table)
        }

        /// The call a "+js(…)" body says, or nil for a name the page script
        /// doesn't know.
        static func call(_ arguments: [String]) -> [String]? {
            guard var name = arguments.first?.lowercased() else { return nil }
            if name.hasSuffix(".js") { name = String(name.dropLast(3)) }
            guard let canonical = names[name] else { return nil }
            var rest = Array(arguments.dropFirst())
            while rest.last == "" { rest.removeLast() }
            return [canonical] + rest
        }

        /// A "+js(…)" body cut into its arguments, uBO's way (ASSUMED from
        /// its wiki): on commas, "\," a comma kept; an argument wholly in
        /// '…', "…" or `…` loses its quotes, and \" inside them is a quote;
        /// other backslashes stay, a regular expression's among them. An
        /// empty pair ('') stays as written: set reads it as the empty string.
        static func arguments(_ text: Substring) -> [String] {
            let chars = Array(text)
            let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
            guard chars.contains(where: { !blank($0) }) else { return [] }
            var out: [String] = []
            var at = 0
            while true {
                while at < chars.count, blank(chars[at]) { at += 1 }
                if at < chars.count, "\"'`".contains(chars[at]), let found = quoted(chars, from: at) {
                    out.append(found.value)
                    guard found.end < chars.count else { break }
                    at = found.end + 1
                    continue
                }
                var arg = ""
                while at < chars.count, chars[at] != "," {
                    if chars[at] == "\\", at + 1 < chars.count, chars[at + 1] == "," {
                        arg.append(",")
                        at += 2
                    } else {
                        arg.append(chars[at])
                        at += 1
                    }
                }
                out.append(arg.trimmingCharacters(in: .whitespaces))
                guard at < chars.count else { break }
                at += 1
            }
            return out
        }

        /// A quoted argument from `start`, and where the comma after it is
        /// (or the end), when nothing but blanks stands between.
        private static func quoted(_ chars: [Character], from start: Int) -> (value: String, end: Int)? {
            let quote = chars[start]
            var value = ""
            var at = start + 1
            while at < chars.count {
                if chars[at] == "\\", at + 1 < chars.count, chars[at + 1] == quote {
                    value.append(quote)
                    at += 2
                } else if chars[at] == quote {
                    at += 1
                    while at < chars.count, chars[at] == " " || chars[at] == "\t" { at += 1 }
                    guard at == chars.count || chars[at] == "," else { return nil }
                    return (value.isEmpty ? String([quote, quote]) : value, at)
                } else {
                    value.append(chars[at])
                    at += 1
                }
            }
            return nil
        }
    }

    /// ##+js and #@#+js lines, gathered first: an exception anywhere in the
    /// lists takes back a call made in any of them.
    struct ScriptletRules {
        var made: [(sites: [String], spared: [String], call: [String])] = []
        var excepted: [(sites: [String], call: [String]?)] = []
        private var offEverywhere = Set<[String]>()
        private var allOff = false

        static func claims(_ line: String, _ marker: Range<String.Index>) -> Bool {
            let kind = line[marker]
            guard kind == "##" || kind == "#@#" else { return false }
            return line[marker.upperBound...].drop(while: { $0 == " " }).hasPrefix("+js(")
        }

        /// Nil when the line is taken, or why it is not (Drop).
        mutating func take(_ line: String, _ marker: Range<String.Index>) -> String? {
            let body = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard body.hasSuffix(")") else { return Drop.scriptletMalformed }
            let arguments = Scriptlets.arguments(body.dropFirst(4).dropLast())
            var sites: [String] = []
            var spared: [String] = []
            for piece in line[..<marker.lowerBound].split(separator: ",") {
                let part = piece.trimmingCharacters(in: .whitespaces)
                if part.isEmpty || part == "*" { continue }
                let negated = part.hasPrefix("~")
                let name = Substring(negated ? String(part.dropFirst()) : part)
                guard let key = plainDomain(name) ?? entity(name) else { return Drop.badDomain }
                if negated { spared.append(key) } else { sites.append(key) }
            }
            if line[marker] == "#@#" {
                guard spared.isEmpty else { return Drop.exceptionExcluding }
                var call: [String]?
                if !arguments.isEmpty {
                    guard let known = Scriptlets.call(arguments) else { return Drop.scriptletUnsupported }
                    call = known
                }
                if sites.isEmpty {
                    if let call { offEverywhere.insert(call) } else { allOff = true }
                } else {
                    excepted.append((sites, call))
                }
                return nil
            }
            // On every page (or every page but a few) is how a rule that
            // breaks one site breaks them all: none of that yet.
            guard !sites.isEmpty else { return Drop.scriptletGeneric }
            guard !arguments.isEmpty else { return Drop.scriptletMalformed }
            guard let call = Scriptlets.call(arguments) else { return Drop.scriptletUnsupported }
            made.append((sites, spared, call))
            return nil
        }

        /// The table, and how many lines it left out by why (Drop): an
        /// exception for every site took back their calls, or a call or a
        /// site can't be carried by the table (`carriable`). A line with
        /// one site it can't name is left out whole, so a call is never run
        /// on a site its line meant to spare.
        func table() -> (Scriptlets, dropped: [String: Int]) {
            var lost: [String: Int] = [:]
            guard !allOff else { return (Scriptlets(), [Drop.scriptletExcepted: made.count]) }
            var out = Scriptlets()
            // The page takes a cancel at a key as meant for every line that
            // has the call, but a `~site` spares the site from its own line
            // only: a line that spares sites has a call of its own, shared
            // only with lines sparing the same ones.
            var index: [[[String]]: Int] = [:]
            var byCall: [[String]: [Int]] = [:]
            var lists: [String: Set<Int>] = [:]
            for rule in made {
                guard Scriptlets.carriable(rule.call) else {
                    lost[Drop.scriptletUnsafeArg, default: 0] += 1
                    continue
                }
                guard (rule.sites + rule.spared).allSatisfy(Scriptlets.carriable(host:)) else {
                    lost[Drop.scriptletBadHost, default: 0] += 1
                    continue
                }
                if offEverywhere.contains(rule.call) {
                    lost[Drop.scriptletExcepted, default: 0] += 1
                    continue
                }
                let key = [rule.call, Set(rule.spared).sorted()]
                let at: Int
                if let known = index[key] {
                    at = known
                } else {
                    at = out.calls.count
                    index[key] = at
                    byCall[rule.call, default: []].append(at)
                    out.calls.append(rule.call)
                }
                for site in rule.sites { lists[site, default: []].insert(at) }
                for site in rule.spared { lists[site, default: []].insert(-(at + 1)) }
            }
            guard !out.calls.isEmpty else { return (out, lost) }
            var off = Set<String>()
            for rule in excepted {
                guard rule.sites.allSatisfy(Scriptlets.carriable(host:)) else {
                    lost[Drop.scriptletBadHost, default: 0] += 1
                    continue
                }
                guard let call = rule.call else {
                    off.formUnion(rule.sites)
                    continue
                }
                // An exception for a call nothing makes says nothing.
                guard let indexes = byCall[call] else { continue }
                for site in rule.sites {
                    for at in indexes { lists[site, default: []].insert(-(at + 1)) }
                }
            }
            for (site, list) in lists {
                out.hosts[site] = list.filter { $0 >= 0 }.sorted() + list.filter { $0 < 0 }.sorted(by: >)
            }
            for site in off { out.hosts[site] = [Scriptlets.off] }
            return (out, lost)
        }
    }
}

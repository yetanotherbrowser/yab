import Foundation

// The lists' !#if blocks: which lines stand in Yab's WebKit (see Filters).

extension Filters {
    // MARK: - !#if

    /// The !#if words that hold in Yab's WebKit, uBO's names (its wiki,
    /// "Static filter syntax", "!#if"). Safari's, since WebKit is what
    /// enforces them; ext_ublock, since the lists are read as uBO reads
    /// them. No cap_html_filtering: Yab can't filter HTML before it is
    /// parsed. The iPhone adds env_mobile. Any other word is false.
    static let webKit: Set<String> = ["env_safari", "ext_ublock", "cap_user_stylesheet"]

    /// Which lines of one list stand: those outside any !#if, or inside
    /// ones whose test holds here, with !#else and nesting.
    struct Preparser {
        let env: Set<String>
        private var levels: [(outer: Bool, test: Bool)] = []

        init(env: Set<String>) { self.env = env }

        var open: Bool { levels.last.map { $0.outer && $0.test } ?? true }

        mutating func read(_ line: String) {
            if line.hasPrefix("!#if ") {
                levels.append((open, test(line.dropFirst(5))))
            } else if line.hasPrefix("!#else") {
                if let last = levels.popLast() { levels.append((last.outer, !last.test)) }
            } else if line.hasPrefix("!#endif") {
                _ = levels.popLast()
            }
        }

        /// The test of an !#if: words, !, &&, || and parentheses. One that
        /// doesn't read is false, so its lines are left out.
        func test(_ text: Substring) -> Bool {
            var tokens: [String] = []
            var at = text.startIndex
            while at < text.endIndex {
                let c = text[at]
                if c == " " || c == "\t" {
                    at = text.index(after: at)
                } else if c == "!" || c == "(" || c == ")" {
                    tokens.append(String(c))
                    at = text.index(after: at)
                } else if c == "&" || c == "|" {
                    let next = text.index(after: at)
                    guard next < text.endIndex, text[next] == c else { return false }
                    tokens.append(String([c, c]))
                    at = text.index(after: next)
                } else if c.isASCII, c.isLetter || c.isNumber || c == "_" {
                    let end = text[at...].firstIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) }) ?? text.endIndex
                    tokens.append(String(text[at..<end]))
                    at = end
                } else {
                    return false
                }
            }
            var position = 0
            guard let value = either(tokens, &position), position == tokens.count else { return false }
            return value
        }

        private func either(_ tokens: [String], _ at: inout Int) -> Bool? {
            guard var value = both(tokens, &at) else { return nil }
            while at < tokens.count, tokens[at] == "||" {
                at += 1
                guard let right = both(tokens, &at) else { return nil }
                value = value || right
            }
            return value
        }

        private func both(_ tokens: [String], _ at: inout Int) -> Bool? {
            guard var value = single(tokens, &at) else { return nil }
            while at < tokens.count, tokens[at] == "&&" {
                at += 1
                guard let right = single(tokens, &at) else { return nil }
                value = value && right
            }
            return value
        }

        private func single(_ tokens: [String], _ at: inout Int) -> Bool? {
            guard at < tokens.count else { return nil }
            let token = tokens[at]
            at += 1
            switch token {
            case "!":
                return single(tokens, &at).map { !$0 }
            case "(":
                guard let value = either(tokens, &at), at < tokens.count, tokens[at] == ")" else { return nil }
                at += 1
                return value
            case ")", "&&", "||":
                return nil
            default:
                return env.contains(token)
            }
        }
    }
}

import Foundation

// Memory of people (docs/mail.md, People in memory): for each person you write with
// often, a page in memory/people made from your mail on this Mac, read by
// agents as the rest of memory is and by the replies written ahead: who
// they are (the line under their name in their signature, else their
// domain) and how they write, how you write to them (how long, how you
// greet them, in which language), what is open between you (Promised and
// Waiting), and what it was read from.
//
// Once a day, after Sense, for people with more than three threads this
// month whom you write to as well. A page an agent keeps already keeps its
// own sections; only the mail's are written again. A Who you wrote
// yourself ("Changed by you") stays as you wrote it, and comes first.

enum MailPeople {
    /// More than this many threads with them this month: a page.
    static let threadsAfter = 3
    /// People read in one pass at most.
    static let most = 30
    /// The day the last pass ran, as "yyyy-MM-dd".
    static let dayKey = "mail.people.day"
    /// Under a Who the mail wrote; one without it is yours or an agent's.
    static let mailMark = "<!-- from mail -->"
    /// Over a Who you wrote, with the day.
    static let yoursMark = "Changed by you"
    /// Settings › Mail's switch.
    static let key = "mail.people"
    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? true }

    struct Facts: Equatable {
        var name: String
        var address: String
        var threads: Int
        var last: Date
        /// The line under their name in their signature: "Partner, North Ventures".
        var title: String?
        /// How they write: lines of their own words, and whether they greet.
        var theirLines: Int
        var theyGreet: Bool
        /// How you write to them: lines, the greeting you use.
        var yourLines: Int
        var youGreet: String?
    }

    /// Their page's name: "people/mark-chen", by their name, else the
    /// address's first part.
    static func page(name: String, address: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? String(address.split(separator: "@").first ?? "") : name
        return "people/" + base
    }

    // MARK: - reading the mail

    /// A mail's own words, its quote and signature cut, as lines with words.
    static func ownLines(_ text: String) -> [String] {
        let lines = MailSense.own(text).components(separatedBy: "\n")
        let cut = MailMemory.signatureStart(lines).map { Array(lines[..<$0]) } ?? lines
        return cut.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The greeting a mail opens with: "Hi Mark", "Hello"; nil for none.
    static func greeting(_ lines: [String]) -> String? {
        guard let first = lines.first else { return nil }
        let words = ["hi", "hey", "hello", "dear", "morning", "good morning"]
        let lower = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!: "))
        guard words.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") }) else { return nil }
        let said = first.trimmingCharacters(in: CharacterSet(charactersIn: ",.!: "))
        return said.count <= 30 ? said : nil
    }

    /// The line under their name in their signatures, the same in two of
    /// their mails at least: a title, a company.
    static func title(in texts: [String], name: String) -> String? {
        var seen: [String: Int] = [:]
        let first = name.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        for text in texts {
            let lines = MailSense.own(text).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let start = MailMemory.signatureStart(lines) else { continue }
            let under = lines[start...].dropFirst().filter { !$0.isEmpty }.prefix(4)
            for line in Set(under) {
                let lower = line.lowercased()
                // Not the name alone, a number, an address or a link.
                guard line.count >= 4, line.count <= 60, lower != name.lowercased(), lower != first,
                      line.rangeOfCharacter(from: .letters) != nil, !lower.contains("@"), !lower.contains("http"),
                      line.range(of: #"^[+\d\s().-]+$"#, options: .regularExpression) == nil else { continue }
                seen[line, default: 0] += 1
            }
        }
        return seen.filter { $0.value >= 2 }.max { ($0.value, -$0.key.count) < ($1.value, -$1.key.count) }?.key
    }

    /// How long, in words: "one line", "two lines", "a few lines", "long mails".
    static func length(_ lines: Int) -> String {
        switch lines {
        case ...1: return "one line"
        case 2: return "two lines"
        case 3...5: return "a few lines"
        default: return "long mails"
        }
    }

    /// What the store says of one person.
    static func facts(_ store: MailStore, name: String, address: String, threads: Int, last: Date) -> Facts {
        let theirs = store.messages(from: address, limit: 8).map { $0.text ?? $0.snippet }
        let mine = store.sent(to: address, limit: 8).map { $0.text ?? $0.snippet }
        let theirLines = theirs.map(ownLines)
        let myLines = mine.map(ownLines)
        let median = { (all: [[String]]) -> Int in
            let counts = all.map(\.count).sorted()
            return counts.isEmpty ? 0 : counts[counts.count / 2]
        }
        let greetings: [String] = myLines.compactMap(greeting)
        let usual = Dictionary(grouping: greetings, by: { $0 }).max { $0.value.count < $1.value.count }
        let theyGreet = theirLines.filter { greeting($0) != nil }.count * 2 > max(theirLines.count, 1)
        var youGreet: String?
        if let usual, usual.value.count * 2 >= max(myLines.count, 1) { youGreet = usual.key }
        return Facts(name: name, address: address, threads: threads, last: last, title: title(in: theirs, name: name),
                     theirLines: median(theirLines), theyGreet: theyGreet, yourLines: median(myLines), youGreet: youGreet)
    }

    // MARK: - the page

    /// "Partner, North Ventures. Writes two lines, no greeting."
    static func who(_ facts: Facts) -> String {
        let domain = facts.address.split(separator: "@").last.map(String.init) ?? ""
        let what = facts.title.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? "At \(domain)"
        return what + ". Writes \(length(facts.theirLines))" + (facts.theyGreet ? "." : ", no greeting.")
    }

    /// "Two lines or so, “Hi Mark”."
    static func how(_ facts: Facts) -> String {
        let long = length(facts.yourLines)
        let greet = facts.youGreet.map { "\u{201C}\($0)\u{201D}" } ?? "no greeting"
        let first = long.prefix(1).uppercased() + String(long.dropFirst())
        return first + " or so, \(greet)."
    }

    /// The page as it is in sections: a heading (nil for what is over the
    /// first) and what is under it.
    static func sections(_ text: String) -> [(heading: String?, body: String)] {
        var out: [(heading: String?, body: String)] = [(nil, "")]
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                out.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), ""))
            } else {
                out[out.count - 1].body += line + "\n"
            }
        }
        return out.map { ($0.heading, $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static let mine = ["Who", "How you write to them", "Open between you", "From mail"]

    /// The page written again from what the mail says now: the mail's
    /// sections new, a Who of yours or an agent's kept, the rest as it was.
    static func render(_ existing: String?, facts: Facts, open: [String], now: Date) -> String {
        let old = existing.map(sections) ?? []
        var top = "# " + (facts.name.isEmpty ? facts.address : facts.name)
        if let line = old.first?.body.split(separator: "\n").first, line.hasPrefix("# ") { top = String(line) }
        let kept = old.first { $0.heading == "Who" }
        var said: String = who(facts) + "\n" + mailMark
        if let kept, !kept.body.contains(mailMark), !kept.body.isEmpty { said = kept.body }
        var out: String = top + "\n\n## Who\n" + said
        out += "\n\n## How you write to them\n" + how(facts) + "\n"
        if !open.isEmpty { out += "\n## Open between you\n" + open.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        let day = ISO8601DateFormatter.string(from: facts.last, timeZone: .current, formatOptions: [.withFullDate])
        out += "\n## From mail\nFrom \(facts.threads) threads with \(facts.address), the last on \(day), mail on this Mac.\n"
        for section in old.dropFirst() where !mine.contains(section.heading ?? "") {
            out += "\n## " + (section.heading ?? "") + "\n" + section.body + "\n"
        }
        return out
    }

    /// Where a person's page is: by their name, else whichever page of
    /// people names their address.
    static func file(name: String, address: String) -> URL? {
        if let url = Memory.file(page(name: name, address: address)), FileManager.default.fileExists(atPath: url.path) { return url }
        let folder = Memory.folder.appendingPathComponent("people")
        let pages = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return pages.first { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").lowercased().contains(address.lowercased()) }
            ?? Memory.file(page(name: name, address: address))
    }

    // MARK: - the pass

    /// Once a day: a page for each person written with often this month.
    /// How many it wrote.
    @discardableResult
    static func run(_ store: MailStore, now: Date = Date(), force: Bool = false, open: (String) -> [String] = { _ in [] }) -> Int {
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let ran = dayKey + "." + store.me.lowercased()
        guard on, force || Store.settings.string(forKey: ran) != day else { return 0 }
        Store.settings.set(day, forKey: ran)
        var wrote = 0
        let people = store.senders(since: now.addingTimeInterval(-30 * 86_400))
            .filter { !$0.list && $0.threads > threadsAfter && !store.sent(to: $0.address, limit: 1).isEmpty }
            .sorted { $0.threads > $1.threads }
            .prefix(most)
        guard !people.isEmpty else { return 0 }
        Memory.prepare()
        for sender in people {
            let read = facts(store, name: sender.name, address: sender.address, threads: sender.threads, last: sender.last)
            guard let url = file(name: sender.name, address: sender.address) else { continue }
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let made = render(existing, facts: read, open: open(sender.address), now: now)
            guard made != existing, made.utf8.count <= Memory.fileLimit else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? made.write(to: url, atomically: true, encoding: .utf8)) != nil { wrote += 1 }
        }
        return wrote
    }

    // MARK: - the rail and the replies

    /// What the rail says of someone: Who, and where it came from.
    struct Card: Equatable, Sendable {
        var who: String
        /// "From 23 threads · in your memory", "Changed by you · Oct 5".
        var source: String
        var yours: Bool
    }

    static func card(name: String, address: String) -> Card? {
        guard let url = file(name: name, address: address), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return card(text)
    }

    /// The same, from a page's words.
    static func card(_ text: String) -> Card? {
        let all = sections(text)
        guard let who = all.first(where: { $0.heading == "Who" })?.body, !who.isEmpty else { return nil }
        let lines = who.components(separatedBy: "\n")
        let mark = "_" + yoursMark
        let kept: [String] = lines.filter { $0 != mailMark && !$0.hasPrefix(mark) }
        let said = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let changed = lines.first(where: { $0.hasPrefix("_" + yoursMark) }) {
            return Card(who: said, source: changed.trimmingCharacters(in: CharacterSet(charactersIn: "_")), yours: true)
        }
        let from = all.first { $0.heading == "From mail" }?.body ?? ""
        let threads = from.range(of: #"From (\d+) threads"#, options: .regularExpression)
            .flatMap { range in Int(from[range].split(separator: " ")[1]) }
        return Card(who: said, source: threads.map { "From \($0) threads · in your memory" } ?? "In your memory", yours: false)
    }

    /// Who, as you wrote it: first on the page, kept by every pass after.
    static func setWho(name: String, address: String, text: String, now: Date = Date()) {
        guard let url = file(name: name, address: address) else { return }
        Memory.prepare()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# " + (name.isEmpty ? address : name) + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? withWho(existing, text: text, now: now).write(to: url, atomically: true, encoding: .utf8)
    }

    /// A page with Who as you wrote it, over the day you did.
    static func withWho(_ existing: String, text: String, now: Date = Date()) -> String {
        let day = now.formatted(AppDates.dateTime.month(.abbreviated).day())
        let who = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n_\(yoursMark) · \(day)_"
        var all = sections(existing)
        if let at = all.firstIndex(where: { $0.heading == "Who" }) {
            all[at].body = who
        } else {
            all.insert(("Who", who), at: min(1, all.count))
        }
        var out = all.first?.body ?? ""
        for section in all.dropFirst() { out += "\n\n## " + (section.heading ?? "") + "\n" + section.body }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// What the replies written ahead are told of someone: Who and how you
    /// write to them, from their page; nil with no page.
    static func known(name: String, address: String) -> String? {
        guard let url = file(name: name, address: address), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return known(text)
    }

    static func known(_ text: String) -> String? {
        let all = sections(text)
        var parts: [String] = []
        for heading in ["Who", "How you write to them"] {
            guard let section = all.first(where: { $0.heading == heading }) else { continue }
            let body: String = section.body.replacingOccurrences(of: mailMark, with: "")
            parts.append(heading + ": " + body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

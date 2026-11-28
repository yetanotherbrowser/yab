import Foundation

// The day remembered as threads of what you were doing (docs/day-threads.md):
// a run of visits in one space that belong to one thing, "Compared Arc and
// Dia pricing · 6 pages · 10:20 to 11:40 AM", so ⌘T, agents and Memory ›
// Days can answer "what was I doing this morning".
//
// This file is the part that needs no window and no file: how visits are
// grouped, how a thread is named before a model has named it, how time words
// read, what a model's answer says. The diary keeps the threads beside its
// visits (DiaryThreads.swift); the model names them (ThreadNamer.swift).
//
// Grouping is on the diary's queue, never the main thread: a pass over a day
// of a few hundred visits is a few milliseconds of token sets.

enum DayThreads {
    /// A pause this long in one space starts a new thread.
    static let gap: TimeInterval = 20 * 60
    /// Fewer distinct pages than this is a page, not a thread.
    static let least = 2
    /// A dwell this long on a page is "Read" in what you did.
    static let reading: TimeInterval = 3 * 60

    /// One visit as grouping sees it.
    struct Visit: Sendable, Equatable {
        let id: Int64
        let key: String
        let at: Date
        let host: String
        let title: String
        let space: String
        /// What the page is about, in words: its title's, its site's and the
        /// diary's words for it, little and common words left out.
        let words: Set<String>
    }

    // MARK: - subject

    /// Words that say where, not what: a site's furniture, the big
    /// platforms everything is on.
    static let common: Set<String> = [
        "google", "docs", "sheets", "slides", "drive", "mail", "gmail", "inbox", "com", "www", "home", "new", "tab",
        "search", "results", "result", "untitled", "document", "spreadsheet", "login", "sign", "account", "dashboard",
        "welcome", "official", "website", "online", "free", "news", "github", "youtube", "reddit", "twitter", "twitch",
        "wikipedia", "amazon", "medium", "blog", "app", "web", "http", "https", "html", "index", "main", "edit", "view",
    ]

    /// The words a title, a host and a passage of the page say it is about.
    static func words(title: String, host: String, text: String = "") -> Set<String> {
        let named = MarkdownLink.title(title, host: host)
        // The site is matched as a site (`likeness`), not as a word too: a
        // site's every page would otherwise go back to its first thread.
        var out = Set(Diary.terms(named).filter(meaningful))
        if !text.isEmpty {
            // The page's own words: the few it says most.
            var counts: [String: Int] = [:]
            for word in Diary.terms(String(text.prefix(1500))) where meaningful(word) { counts[word, default: 0] += 1 }
            for (word, _) in counts.filter({ $0.value >= 2 }).sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(6) {
                out.insert(word)
            }
        }
        return out
    }

    static func meaningful(_ word: String) -> Bool {
        word.count >= 3 && !common.contains(word) && !word.allSatisfy(\.isNumber)
    }

    /// What a site calls itself: "dia.com" dia, "news.ycombinator.com"
    /// ycombinator, "docs.google.com" google.
    static func site(_ host: String) -> String? {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 1 else { return labels.first }
        labels.removeLast()
        if labels.count > 1, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(labels.last!) { labels.removeLast() }
        return labels.last
    }

    /// How much a visit belongs with a run of visits: the same site counts
    /// once, each word they share once more.
    static func likeness(_ visit: Visit, hosts: Set<String>, words: Set<String>) -> Int {
        (hosts.contains(visit.host) ? 1 : 0) + visit.words.intersection(words).count
    }

    // MARK: - grouping

    /// The visits, in time order, as threads: each a list of indices into
    /// `visits`, in time order, threads by their first visit. Visits in
    /// one space go together until a pause of `gap` or a change of subject;
    /// a page come back to later joins its old thread when the subject
    /// matches. Runs of fewer than `least` pages are left out.
    static func group(_ visits: [Visit]) -> [[Int]] {
        struct Run {
            var members: [Int] = []
            var hosts: Set<String> = []
            var words: Set<String> = []
            var keys: Set<String> = []
            var end = Date.distantPast
            let space: String
        }
        var runs: [Run] = []
        /// The run each space is in now.
        var current: [String: Int] = [:]
        let order = visits.indices.sorted { visits[$0].at < visits[$1].at }
        for index in order {
            let visit = visits[index]
            func join(_ at: Int) {
                runs[at].members.append(index)
                runs[at].hosts.insert(visit.host)
                runs[at].words.formUnion(visit.words)
                runs[at].keys.insert(visit.key)
                runs[at].end = max(runs[at].end, visit.at)
                current[visit.space] = at
            }
            if let at = current[visit.space] {
                let run = runs[at]
                let pause = visit.at.timeIntervalSince(run.end)
                if pause <= gap {
                    // Nothing to judge it by, or a page of the same: it goes on.
                    if visit.words.isEmpty || run.keys.contains(visit.key)
                        || likeness(visit, hosts: run.hosts, words: run.words) >= 1 {
                        join(at)
                        continue
                    }
                    // A first step off a lone page, the result a search led to,
                    // within a couple of minutes.
                    if run.members.count == 1, pause < 120 {
                        join(at)
                        continue
                    }
                }
            }
            // Come back to: an earlier thread of the day in this space with
            // this very page, or plainly the same subject.
            // The one it was in is among them: after a pause, its own page.
            let earlier = runs.indices.filter { runs[$0].space == visit.space }
            let best = earlier.map { at -> (Int, Int) in
                let run = runs[at]
                let score = run.keys.contains(visit.key) ? 10 : likeness(visit, hosts: run.hosts, words: run.words)
                return (at, score)
            }.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            if let best, best.1 >= 2 {
                join(best.0)
                continue
            }
            runs.append(Run(space: visit.space))
            join(runs.count - 1)
        }
        return runs.filter { run in run.keys.count >= least }
            .map { run in run.members.sorted { visits[$0].at < visits[$1].at } }
            .sorted { visits[$0[0]].at < visits[$1[0]].at }
    }

    // MARK: - names before a model's

    /// A thread's name with no model to ask: the title of the page it went
    /// back to most, without its site's name, cut at its first separator.
    static func fallbackName(_ pages: [(title: String, host: String)]) -> String {
        var counts: [String: (Int, Int)] = [:]
        for (order, page) in pages.enumerated() {
            let title = MarkdownLink.title(page.title, host: page.host).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let was = counts[title] ?? (0, order)
            counts[title] = (was.0 + 1, was.1)
        }
        let top = counts.max { a, b in a.value.0 != b.value.0 ? a.value.0 < b.value.0 : a.value.1 > b.value.1 }?.key
        guard var name = top else { return pages.first.map { site($0.host)?.capitalized ?? $0.host } ?? "Pages" }
        for mark in [" · ", " | ", " - ", " \u{2013} ", " \u{2014} ", ": "] {
            if let cut = name.range(of: mark), name.distance(from: name.startIndex, to: cut.lowerBound) >= 4 {
                name = String(name[..<cut.lowerBound])
                break
            }
        }
        if name.count > 48 { name = String(name.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" }
        return name
    }

    // MARK: - what a model says

    /// What a model says of a thread: a topic of two to four words for a
    /// list ("Arc and Dia pricing"), what you were doing ("Comparing Arc and
    /// Dia pricing"), the same done ("Compared…"), and one line of what
    /// happened.
    struct Naming: Sendable, Equatable {
        var topic: String
        var doing: String
        var done: String
        var line: String
    }

    /// The model's four lines, "Topic:", "Doing:", "Done:", "Line:", read;
    /// nil unless at least what you were doing is there and short.
    static func naming(_ said: String) -> Naming? {
        var found: [String: String] = [:]
        for raw in said.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " -*#")).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”*")))
            if ["topic", "doing", "done", "line"].contains(label), !value.isEmpty, found[label] == nil { found[label] = value }
        }
        func clean(_ text: String?) -> String? {
            guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            while text.hasSuffix(".") && !text.hasSuffix("..") { text.removeLast() }
            return text.replacingOccurrences(of: "\u{2014}", with: ",")
        }
        guard let doing = clean(found["doing"]), doing.count <= 64, doing.split(separator: " ").count <= 9 else { return nil }
        let topic = clean(found["topic"]).flatMap { $0.count <= 40 ? $0 : nil } ?? doing
        let done = clean(found["done"]).flatMap { $0.count <= 64 ? $0 : nil } ?? doing
        var line = found["line"]?.trimmingCharacters(in: .whitespaces) ?? ""
        line = line.replacingOccurrences(of: "\u{2014}", with: ",")
        if line.count > 160 { line = String(line.prefix(157)) + "…" }
        if !line.isEmpty, !line.hasSuffix("."), !line.hasSuffix("…"), !line.hasSuffix("!"), !line.hasSuffix("?") { line += "." }
        return Naming(topic: topic, doing: doing, done: done, line: line)
    }

    /// What every model is told, for every thread. It names no example:
    /// the Mac's model, whose answer takes its shape from `ThreadNaming`,
    /// copied the example names into threads about anything else (#1058).
    static let instructions = """
    You name what someone was doing in their web browser, from the pages of one stretch of their day and what they did on them. \
    Write in the pages' own language. No quotes, no dashes, no site names unless the site is the subject. \
    Never repeat passwords, codes, card numbers, addresses or anything private.
    """

    /// The four lines a model that answers in text writes, read by
    /// `naming(_:)`, with an example of each.
    static let lines = """
    Reply with exactly four lines and nothing else:
    Topic: two to four words, a noun phrase for a list (Arc and Dia pricing)
    Doing: what they were doing, starting with a verb ending in -ing, three to seven words (Comparing Arc and Dia pricing)
    Done: the same in the past tense (Compared Arc and Dia pricing)
    Line: one plain sentence of what happened or what they found, under 120 characters, only facts the pages show
    """

    /// The pages and acts of a thread, as the model is asked about them.
    static func prompt(pages: [(title: String, host: String, passage: String)], acts: [String]) -> String {
        var out = "Pages, in the order they were opened:\n"
        for page in pages.prefix(12) {
            out += "- \(MarkdownLink.title(page.title, host: page.host)) (\(page.host))"
            if !page.passage.isEmpty { out += ": " + String(page.passage.replacingOccurrences(of: "\n", with: " ").prefix(280)) }
            out += "\n"
        }
        if !acts.isEmpty { out += "\nWhat they did:\n" + acts.prefix(8).map { "- " + $0 }.joined(separator: "\n") + "\n" }
        return out
    }

    // MARK: - time words

    /// A stretch of time a question names, and the words that named it.
    struct Span: Sendable, Equatable {
        let from: Date
        let to: Date
        /// How the answer's sources are captioned: "From your morning",
        /// "Friday".
        let label: String
        /// The question without the time words.
        let rest: String

        /// The stretch as the live line says it: "this morning", "Friday".
        var words: String {
            label.hasPrefix("From your ") ? "this " + label.dropFirst(10)
                : label == "From today" ? "today" : label.hasPrefix("Yesterday") || label.hasPrefix("This") || label.hasPrefix("Last")
                    ? label.prefix(1).lowercased() + label.dropFirst() : label
        }
    }

    /// "this morning", "yesterday", "on Friday", "last week": the stretch
    /// the words name, from `now`. Nil when they name none.
    static func span(_ words: String, now: Date = Date(), calendar: Calendar = .current) -> Span? {
        let lower = " " + words.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ") + " "
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func at(_ base: Date, _ hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: base)! }
        func cut(_ phrase: String) -> String {
            lower.replacingOccurrences(of: " " + phrase + " ", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let parts: [(word: String, start: Int, end: Int)] = [("morning", 0, 12), ("afternoon", 12, 17), ("evening", 17, 24)]
        for part in parts {
            let phrases: [(String, Date, String)] = [("yesterday " + part.word, day(-1), "Yesterday " + part.word),
                                                     ("this " + part.word, today, "From your " + part.word),
                                                     (part.word == "evening" ? "tonight" : "this " + part.word, today, "From your " + part.word)]
            for (phrase, base, label) in phrases where lower.contains(" " + phrase + " ") {
                let end = at(base, part.end)
                return Span(from: at(base, part.start), to: base == today ? min(end, max(now, at(base, part.start))) : end,
                            label: label, rest: cut(phrase))
            }
        }
        for phrase in ["earlier today", "so far today", "today"] where lower.contains(" " + phrase + " ") {
            return Span(from: today, to: day(1), label: "From today", rest: cut(phrase))
        }
        for phrase in ["yesterday"] where lower.contains(" " + phrase + " ") {
            return Span(from: day(-1), to: today, label: "Yesterday", rest: cut(phrase))
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? day(-7)
        for phrase in ["last week", "previous week"] where lower.contains(" " + phrase + " ") {
            return Span(from: calendar.date(byAdding: .day, value: -7, to: week)!, to: week, label: "Last week", rest: cut(phrase))
        }
        for phrase in ["this week", "the week"] where lower.contains(" " + phrase + " ") {
            return Span(from: week, to: day(1), label: "This week", rest: cut(phrase))
        }
        // A day by its name: the last one, today's never ("on Friday" on a
        // Friday is a week ago only when said "last Friday").
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in names.enumerated() {
            for phrase in ["last \(name)", "on \(name)", name] where lower.contains(" " + phrase + " ") {
                let weekday = calendar.component(.weekday, from: now) - 1
                var back = (weekday - index + 7) % 7
                if back == 0 { back = phrase.hasPrefix("last") ? 7 : 0 }
                let start = day(-back)
                let label = name.prefix(1).uppercased() + name.dropFirst()
                return Span(from: start, to: calendar.date(byAdding: .day, value: 1, to: start)!, label: label, rest: cut(phrase))
            }
        }
        return nil
    }

    /// "Pick up where I left off", "where was I": the thread itself is the
    /// answer, offered to open again.
    static func picksUp(_ words: String) -> Bool {
        let lower = words.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return ["pick up where", "picking up where", "left off", "where was i", "continue where", "carry on where", "get back to where",
                "what was i working on", "what was i doing"].contains { lower.contains($0) }
    }

    // MARK: - saying it

    /// "10:20 to 11:40 AM", "11:40 AM to 12:30 PM", "2:00 PM to now".
    static func span(from start: Date, to end: Date, open: Bool, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "h:mm a"
        let first = format.string(from: start)
        if open { return first + " to now" }
        let last = format.string(from: end)
        if first.suffix(2) == last.suffix(2) { return String(first.dropLast(3)) + " to " + last }
        return first + " to " + last
    }

    /// "10:31 AM".
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "h:mm a"
        return format.string(from: date)
    }

    /// "6 pages", "1 page".
    static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }
}

/// A thread as it is read back: its pages and what was done on them.
struct DayThread: Sendable, Identifiable, Equatable {
    struct Page: Sendable, Equatable {
        let key: String
        let url: String
        let title: String
        let host: String
        /// Its first visit in the thread, and its last.
        let at: Date
        var visits: Int
        var last: Date
    }

    struct Act: Sendable, Equatable {
        enum Kind: String, Sendable { case read, selected, copied, added, sent, downloaded }
        let kind: Kind
        let at: Date
        /// Which page.
        let key: String
        /// What was copied or selected, a file's name, how many rows: never
        /// what was typed into a form.
        let words: String

        /// "Read Dia Pro · Plans and pricing", "Selected “$20 a month”".
        func line(title: String) -> String {
            switch kind {
            case .read: return "Read " + title
            case .selected: return "Selected \u{201C}\(words)\u{201D}"
            case .copied: return "Copied \u{201C}\(words)\u{201D}"
            case .added: return words.isEmpty ? "Added to " + title : words
            case .sent: return "Sent the form on " + title
            case .downloaded: return "Downloaded " + (words.isEmpty ? "a file" : words)
            }
        }
    }

    let id: Int64
    /// The day it is in, "2026-10-20".
    let day: String
    let space: String
    let start: Date
    let end: Date
    /// "Arc and Dia pricing".
    let topic: String
    /// "Comparing Arc and Dia pricing".
    let name: String
    /// "Compared Arc and Dia pricing".
    let done: String
    /// One line of what happened, or "".
    let summary: String
    /// 0 a name of its own pages' titles, 1 a model's, 2 yours.
    let named: Int
    /// Its place in the day, the first 0, for its color.
    let order: Int
    var pages: [Page]
    var acts: [Act]
    /// Still going: its last visit within `gap` of now.
    let open: Bool

    /// Every page's title for an act's line.
    func title(of key: String) -> String {
        pages.first { $0.key == key }.map { MarkdownLink.title($0.title, host: $0.host) } ?? ""
    }

    /// What you did, newest last, as fact lines: (time, words).
    var did: [(time: String, words: String)] {
        acts.sorted { $0.at < $1.at }.map { (DayThreads.time($0.at), $0.line(title: title(of: $0.key))) }
    }

    /// Its time, "10:20 to 11:40 AM".
    var when: String { DayThreads.span(from: start, to: end, open: open) }

    /// "Comparing" while it goes on, "Compared" once done: Memory's days
    /// say what you did; History, what you were doing.
    var told: String { open ? name : done }
}

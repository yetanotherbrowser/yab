import Foundation

// ⌘T's Ask, answered from your day (docs/day-threads.md): time words narrow
// the threads before the words are matched ("this morning", "on Friday"; the
// last 7 days with none), the threads and their pages go to the agent
// numbered, and the agent ends with the numbers it used. Those come back as
// source rows under the answer, the pages with the time you were there;
// "pick up where I left off" leads with the thread itself, Reopen 4 Pages
// as a Folder.

/// A row under an answer: a page it came from, or the thread to open again.
struct AnswerSource: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case page, folder }
    let id: String
    let kind: Kind
    /// "Dia Pro · Plans and pricing", "Reopen 4 Pages as a Folder".
    let title: String
    /// "dia.com", or for a sheet or a doc what it is: "Google Sheets".
    let place: String
    let host: String
    let urls: [URL]
    /// When you were there; none for the folder.
    let at: Date?
    /// The folder's name: the thread's.
    let name: String
}

enum AskFromDay {
    struct Context: Sendable {
        /// What the agent is handed, numbered.
        let text: String
        /// Each number's page.
        let pages: [Int: AnswerSource]
        /// Over the rows: "From your morning", "Friday, 4:15 to 6:50 PM".
        let caption: String
        /// "Pick up where I left off": the thread, first.
        let folder: AnswerSource?
        /// Its last page, under it when the agent names none.
        let lastPage: AnswerSource?
    }

    /// How many threads and pages go to the agent at most.
    static let threadsMost = 4
    static let pagesMost = 12

    static func context(for words: String, now: Date = Date(), diary: Diary = .shared) async -> Context? {
        let span = DayThreads.span(words, now: now)
        let from = span?.from ?? now.addingTimeInterval(-7 * 86_400)
        let to = span?.to ?? now.addingTimeInterval(60)
        let threads = await diary.threads(from: from, to: to)
        let rest = span?.rest ?? words
        let terms = Diary.terms(rest).filter { $0.count >= 3 && !DayThreads.common.contains($0) && !askWords.contains($0) }
        let picking = DayThreads.picksUp(words)
        func score(_ thread: DayThread) -> Int {
            let said = ([thread.name, thread.topic, thread.done, thread.summary] + thread.pages.map(\.title) + thread.did.map(\.words))
                .joined(separator: " ").lowercased()
            return terms.filter { said.contains($0) }.count
        }
        var chosen: [DayThread] = []
        var resumed: DayThread?
        if picking {
            // The last thing done in that stretch; with no time words, the
            // last one finished, not the one going on now.
            let done = threads.filter { !$0.open }
            resumed = (span == nil ? done : threads).max { $0.end < $1.end } ?? threads.max { $0.end < $1.end }
            if let resumed { chosen = [resumed] }
        } else {
            let scored = threads.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.end > $1.0.end }
            chosen = scored.prefix(threadsMost).map(\.0)
            // "What was I doing this morning": every thread of the stretch.
            if chosen.isEmpty, span != nil { chosen = Array(threads.suffix(6)) }
        }
        // Pages the words find that no chosen thread holds, in the stretch.
        var loose: [Diary.Hit] = []
        if !terms.isEmpty, !picking {
            let held = Set(chosen.flatMap { $0.pages.map(\.key) })
            loose = await diary.pages(terms.joined(separator: " "), limit: 8)
                .filter { !held.contains($0.key) && $0.at >= from && $0.at <= to }
        }
        guard !chosen.isEmpty || !loose.isEmpty else { return nil }

        var number = 0
        var pages: [Int: AnswerSource] = [:]
        var text = "What they did in their browser on this Mac, as threads of what they were doing, newest last. "
            + "Each page has a number in brackets."
        for thread in chosen.sorted(by: { $0.start < $1.start }) {
            let day = Diary.day(named: thread.day).map(MemoryShelf.dayTitle) ?? thread.day
            text += "\n\n## \(day), \(thread.when): \(thread.name) (\(DayThreads.pages(thread.pages.count)))"
            if !thread.summary.isEmpty { text += "\n" + thread.summary }
            for page in thread.pages.prefix(8) {
                number += 1
                let source = Self.source(page)
                pages[number] = source
                text += "\n[\(number)] \(source.title) · \(page.host) · \(DayThreads.time(page.last))"
            }
            let did = thread.did
            if !did.isEmpty {
                text += "\nWhat they did: " + did.prefix(8).map { "\($0.time) \($0.words)" }.joined(separator: "; ")
            }
        }
        if !loose.isEmpty {
            text += "\n\nOther pages from their history the words find:"
            for hit in loose.prefix(pagesMost - min(number, pagesMost - 4)) {
                number += 1
                let source = AnswerSource(id: "page.\(hit.key)", kind: .page, title: MarkdownLink.title(hit.title, host: hit.host),
                                          place: place(hit.host, hit.url), host: hit.host, urls: URL(string: hit.url).map { [$0] } ?? [],
                                          at: hit.at, name: "")
                pages[number] = source
                text += "\n[\(number)] \(source.title) · \(hit.host) · \(hit.at.englishFormatted(date: .abbreviated, time: .shortened))"
                    + (hit.passage.map { " · \u{201C}\($0)\u{201D}" } ?? "")
            }
        }
        text += "\n\nUse them only if the question is about something they did or read. "
            + "After the answer, on a line of its own, write Sources: and the numbers of the pages the answer came from, "
            + "like Sources: 1, 3. Write Sources: none when it came from none of them."

        var folder: AnswerSource?
        var lastPage: AnswerSource?
        var caption = span?.label ?? "From your history"
        if let resumed {
            // Where you stopped: the page you were on last.
            lastPage = resumed.pages.max { $0.last < $1.last }.map(Self.source)
            let urls = resumed.pages.prefix(12).compactMap { URL(string: $0.url) }
            folder = AnswerSource(id: "folder.\(resumed.id)", kind: .folder, title: "Reopen \(urls.count) Pages as a Folder", place: "",
                                  host: "", urls: urls, at: nil, name: resumed.name)
            let day = span?.label ?? dayWord(resumed.day, now: now)
            caption = day + ", " + resumed.when
        }
        return Context(text: text, pages: pages, caption: caption, folder: folder, lastPage: lastPage)
    }

    /// Words of a question that never name what it is about.
    static let askWords: Set<String> = ["cost", "costs", "doing", "looked", "look", "looking", "working", "pick", "left", "off",
                                        "where", "continue", "back", "remember", "tell", "show", "find", "again"]

    private static func source(_ page: DayThread.Page) -> AnswerSource {
        AnswerSource(id: "page.\(page.key)", kind: .page, title: MarkdownLink.title(page.title, host: page.host), place: place(page.host, page.url),
                     host: page.host, urls: URL(string: page.url).map { [$0] } ?? [], at: page.last, name: "")
    }

    /// What a page is beside its title: its site, or Google's app by name.
    static func place(_ host: String, _ link: String = "") -> String {
        switch host {
        case "docs.google.com":
            let path = URL(string: link)?.path ?? ""
            if path.hasPrefix("/spreadsheets") { return "Google Sheets" }
            if path.hasPrefix("/presentation") { return "Google Slides" }
            if path.hasPrefix("/forms") { return "Google Forms" }
            return "Google Docs"
        case "sheets.google.com": return "Google Sheets"
        case "mail.google.com": return "Gmail"
        default: return host
        }
    }

    /// "Today", "Yesterday", "Friday", "Oct 9".
    static func dayWord(_ day: String, now: Date = Date()) -> String {
        guard let date = Diary.day(named: day) else { return day }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = now.timeIntervalSince(date) < 6 * 86_400 ? "EEEE" : "MMM d"
        return format.string(from: date)
    }

    // MARK: - the agent's numbers

    /// The answer without its last "Sources:" line, and the numbers it
    /// named; nil numbers when it named none at all.
    static func cited(_ text: String) -> (answer: String, numbers: [Int]?) {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last, saysSources(last) else { return (text, nil) }
        lines.removeLast()
        let numbers = last.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        let answer = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, numbers)
    }

    /// A line saying "Sources:", under any Markdown around it.
    static func saysSources(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_>"))).lowercased()
        return bare.hasPrefix("sources:") || bare.hasPrefix("source:")
    }

    /// While it is written: a last line on its way to "Sources:" kept out
    /// of sight, so the numbers never flash under the answer.
    static func streaming(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let last = lines.last else { return text }
        let bare = last.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_>"))).lowercased()
        if !bare.isEmpty, "sources:".hasPrefix(bare) || bare.hasPrefix("sources:") || bare.hasPrefix("source:") {
            lines.removeLast()
            return lines.joined(separator: "\n")
        }
        return text
    }

    /// The rows the answer shows: the folder first when picking up, then
    /// the pages it named, in its order.
    static func rows(_ context: Context, numbers: [Int]?) -> [AnswerSource] {
        var out: [AnswerSource] = []
        if let folder = context.folder { out.append(folder) }
        var seen = Set<String>()
        for number in numbers ?? [] {
            guard let source = context.pages[number], seen.insert(source.id).inserted else { continue }
            out.append(source)
            if out.count >= 5 { break }
        }
        if context.folder != nil, out.count == 1, let last = context.lastPage { out.append(last) }
        return out
    }
}

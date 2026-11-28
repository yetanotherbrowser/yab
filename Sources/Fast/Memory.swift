import Foundation

// What agents know about you, kept between tasks.
//
// Plain Markdown in the browser's own folder, laid out so an agent can
// read it as plain files:
//
//     memory/USER.md          who you are, in a few lines: in every brief
//     memory/MEMORY.md        how to work for you, in a few lines: in every brief
//     memory/TAXONOMY.md      where each kind of thing is kept
//     memory/people/  companies/  projects/  sites/  concepts/  agent/  users/
//                             a page per subject: what is believed now, and why
//     memory/episodic/YYYY-MM-DD.md
//                             what each day's tasks noticed, only ever added to
//
// After a task, the agent that did it writes what is worth keeping into the
// day's episodic page, and nothing else (Agents.extractionPrompt). Every day
// or so, once enough has happened, a quiet pass reads the recent days and
// files what has become durable into the subject pages and the two briefs
// (Agents.dream). You can open, read, correct or delete any of it with a
// text editor, and nothing about you lives anywhere else.
//
// Search is words, not vectors: every paragraph scored by the query's words
// (BM25), a word matching on its first five letters too, "project" finds
// "projects", which is most of what stemming
// buys, for none of an embedding model's weight. Memory is small; reading
// all of it per query takes a millisecond or two.

enum Memory {
    static var folder: URL { Store.file("memory") }
    static var user: URL { folder.appendingPathComponent("USER.md") }
    static var operating: URL { folder.appendingPathComponent("MEMORY.md") }

    /// Past these, a write is refused rather than a file growing without end.
    static let fileLimit = 64 * 1024
    static let totalLimit = 4 * 1024 * 1024
    /// The two briefs go into every task's prompt: they stay short.
    static let briefLimit = 6000

    /// The folders a page may live in, as the taxonomy has them.
    static let kinds = ["users", "agent", "people", "companies", "sites", "projects", "concepts", "episodic"]

    /// Under what a task that read mail kept: a page, or a diary entry,
    /// sync leaves on this Mac (docs/casa.md, Sync).
    static let mailMark = "<!-- kept from mail -->"

    /// Written from Gmail's data: kept by a task that read mail, or a
    /// person's page mail wrote (MailPeople). Sync never sends it.
    static func fromMail(_ text: String) -> Bool {
        text.contains(mailMark) || text.contains(MailPeople.mailMark) || text.contains("\n## From mail\n")
    }

    /// A page a task that read mail can't write: a brief, or one that says
    /// something and syncs already. A diary day takes its entries.
    static func closedToMail(_ path: String, body: String) -> Bool {
        guard !path.hasPrefix("episodic/") else { return false }
        return path == "USER.md" || path == "MEMORY.md" || meaningful(body) && !fromMail(body)
    }

    /// A diary day as a task that didn't read mail sees it: what tasks that
    /// read mail kept is blank, the rest on the lines it was on.
    static func withoutMail(day text: String) -> String {
        guard text.contains(mailMark) else { return text }
        var out: [Substring] = [], entry: [Substring] = []
        func flush() {
            out += entry.contains { $0.contains(mailMark) } ? entry.map { _ in Substring("") } : entry
            entry = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { flush() }
            entry.append(line)
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// A page as a task sees it: one that didn't read mail (`mail` false)
    /// sees none of what mail wrote, so it can't carry it to a page that
    /// syncs. Nil when there is nothing for it.
    static func seen(_ path: String, _ body: String, mail: Bool) -> String? {
        guard !mail else { return body }
        if path.hasPrefix("episodic/") { return withoutMail(day: body) }
        return fromMail(body) ? nil : body
    }

    // MARK: - the files

    /// Every page, by its path inside the folder: "USER.md", "people/jane-doe.md".
    static func files() -> [String] {
        prepare()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            out.append(relative(url))
        }
        return out.sorted { a, b in
            let (x, y) = (order(a), order(b))
            // The days newest first; everything else in order.
            if x == "4", y == "4" { return a > b }
            return x == y ? a < b : x < y
        }
    }

    /// The briefs first, then the subject pages, then the days, newest first.
    private static func order(_ path: String) -> String {
        switch path {
        case "USER.md": return "0"
        case "MEMORY.md": return "1"
        case "TAXONOMY.md": return "2"
        default:
            return path.hasPrefix("episodic/") ? "4" : "3"
        }
    }

    private static func relative(_ url: URL) -> String {
        let root = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    /// A page an agent named, as a file inside the folder and nowhere else:
    /// "USER", "memory", "people/Jane Doe", "sites/github.com",
    /// "episodic/2026-09-24". A folder the taxonomy doesn't have is refused.
    static func file(_ name: String) -> URL? {
        var path = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("memory/") { path = String(path.dropFirst(7)) }
        if path.lowercased().hasSuffix(".md") { path = String(path.dropLast(3)) }
        let parts = path.split(separator: "/").map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        if parts.count == 1 {
            switch parts[0].lowercased() {
            case "user", "about", "me": return user
            case "memory", "agent": return operating
            case "taxonomy": return folder.appendingPathComponent("TAXONOMY.md")
            default: return nil
            }
        }
        let kind = parts[0].lowercased()
        guard kinds.contains(kind) else { return nil }
        let slug = String(parts[1].lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard !slug.isEmpty, slug.count <= 80, !slug.hasPrefix(".") else { return nil }
        return folder.appendingPathComponent(kind).appendingPathComponent(slug + ".md")
    }

    static func read(_ name: String, mail: Bool = true) -> String? {
        // The name as listed first, then as an agent would say it.
        guard let url = existing(name) ?? file(name), let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return seen(relative(url), body, mail: mail)
    }

    /// Every page a task may read (`seen`).
    static func files(mail: Bool) -> [String] {
        guard !mail else { return files() }
        return files().filter { path in
            path.hasPrefix("episodic/") || !((try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)).map(fromMail) ?? false)
        }
    }

    /// A path as `files()` lists it, for reading.
    private static func existing(_ path: String) -> URL? {
        let clean = path.hasPrefix("memory/") ? String(path.dropFirst(7)) : path
        guard !clean.contains(".."), files().contains(clean) else { return nil }
        return folder.appendingPathComponent(clean)
    }

    /// Adds to a page, or replaces a passage in it. Nil when written,
    /// otherwise why not.
    ///
    /// An episodic day takes whole blocks, appended as they are; any other
    /// page takes a line, as a list item, unless it is already there, or a
    /// block that starts with a heading or frontmatter.
    ///
    /// A task that read mail (`mail`) writes only what stays on this Mac,
    /// marked so sync leaves it (Memory.fromMail): a diary entry, a new
    /// page, or a page mail wrote. A page that syncs already, the briefs
    /// among them, it can't change: leaving that page out of sync would
    /// take it off the user's other Macs.
    static func write(_ name: String, text: String, replacing old: String?, mail: Bool = false) -> String? {
        guard let url = file(name) else {
            return "a page is USER, MEMORY, or a folder and a name: people/jane-doe, companies/acme, sites/github.com, projects/…, concepts/…, agent/…, episodic/YYYY-MM-DD"
        }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        prepare()
        var body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let day = url.deletingLastPathComponent().lastPathComponent == "episodic"
        if mail, closedToMail(relative(url), body: body) {
            return "this task read the user's mail, and \(relative(url)) syncs to their other devices: keep it on a new page, or in today's episodic entry, which stay on this Mac"
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mail, day, !text.isEmpty, !text.contains(mailMark) { text += "\n" + mailMark }
        if let old, !old.isEmpty {
            let times = body.components(separatedBy: old).count - 1
            guard times > 0 else { return "that passage isn't in \(relative(url)), read it first" }
            guard times == 1 else { return "that passage is in \(relative(url)) \(times) times, give a longer one" }
            body = body.replacingOccurrences(of: old, with: text)
        } else {
            guard !text.isEmpty else { return "nothing to remember" }
            // A new page gets a heading, unless what comes brings its own.
            if body.isEmpty, !(text.hasPrefix("---") || text.hasPrefix("# ")) {
                body = "# " + (day ? url.deletingPathExtension().lastPathComponent : title(url)) + "\n\n"
            }
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            if day || text.hasPrefix("#") || text.hasPrefix("---") || text.contains("\n") {
                if !body.isEmpty, !body.hasSuffix("\n\n") { body += "\n" }
                body += text + "\n"
            } else {
                let line = text.hasPrefix("-") ? text : "- " + text
                // Known already: nothing to add, and nothing wrong.
                if body.components(separatedBy: "\n").contains(line) { return nil }
                body += line + "\n"
            }
        }
        if mail, !day, !body.contains(mailMark) {
            if !body.hasSuffix("\n") { body += "\n" }
            body += "\n" + mailMark + "\n"
        }
        guard body.utf8.count <= fileLimit else { return "\(relative(url)) is full, tidy it with replacing" }
        let others = files().filter { $0 != relative(url) }.reduce(0) { $0 + ((try? Data(contentsOf: folder.appendingPathComponent($1)).count) ?? 0) }
        guard others + body.utf8.count <= totalLimit else { return "memory is full" }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func title(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Today's episodic page, by the name `write` takes.
    static var today: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return "episodic/" + format.string(from: Date())
    }

    /// The days an episodic page exists for, newest first, within `days`.
    static func recentDays(_ days: Int) -> [String] {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        return files().filter { path in
            guard path.hasPrefix("episodic/"), let date = format.date(from: String(path.dropFirst(9).dropLast(3))) else { return false }
            return date >= since
        }
    }

    // MARK: - a chat project's memory

    /// A chat project's own page, memory/projects/prj-….md (Projects):
    /// not in the shared brief or search, only in its chats' briefs.
    static func projectPage(_ path: String) -> Bool { path.hasPrefix("projects/" + Project.idPrefix) }

    static func projectFile(_ id: String) -> URL? { file("projects/" + id) }

    /// What a project remembers, a fact a line, oldest first.
    static func projectNotes(_ id: String) -> [String] {
        guard let url = projectFile(id), let body = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return body.components(separatedBy: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { return nil }
            let note = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return note.isEmpty ? nil : note
        }
    }

    /// One of a project's facts, gone from its page (its card's minus).
    @discardableResult
    static func forget(_ note: String, project id: String) -> Bool {
        guard let url = projectFile(id), let body = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = body.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- " + note }) else { return false }
        lines.remove(at: at)
        return (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// The whole page, gone with its project.
    static func eraseProject(_ id: String) {
        guard let url = projectFile(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - the brief

    /// What an agent is told of you before it starts: the two briefs, and the
    /// list of pages so it knows where to look.
    static func brief(limit: Int = briefLimit) -> String {
        var out = ""
        for (url, heading) in [(user, "About the user (USER.md)"), (operating, "How to work for them (MEMORY.md)")] {
            guard let body = try? String(contentsOf: url, encoding: .utf8), meaningful(body) else { continue }
            let clipped = body.count > limit / 2 ? String(body.prefix(limit / 2)) + "\n…" : body
            out += "\n\n## \(heading)\n\n" + clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pages = files().filter { !["USER.md", "MEMORY.md", "TAXONOMY.md"].contains($0) && !$0.hasPrefix("episodic/") && !projectPage($0) }
        if !pages.isEmpty {
            let shown = pages.prefix(80)
            out += "\n\n## Other memory pages (memory_read or memory_search)\n\n" + shown.joined(separator: ", ")
            if pages.count > shown.count { out += ", and \(pages.count - shown.count) more" }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a brief says anything past its seed.
    static func meaningful(_ body: String) -> Bool {
        body.components(separatedBy: "\n").contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("<!--")
        }
    }

    /// How many pages say something, the day's diary and the seeds aside.
    static var notes: Int {
        files().filter { path in
            guard path != "TAXONOMY.md", !path.hasPrefix("episodic/"),
                  let body = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return false }
            return meaningful(body)
        }.count
    }

    /// Whether anything is remembered yet.
    static var empty: Bool {
        files().allSatisfy { path in
            guard let body = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return true }
            return path == "TAXONOMY.md" || !meaningful(body)
        }
    }

    // MARK: - the folder's shape

    private static var prepared = false

    /// The seeds, once, and the flat files of the first memory, when there
    /// are any, moved into a day's page for the next pass to file.
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.appendingPathComponent("episodic"), withIntermediateDirectories: true)
        let flat = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !["USER.md", "MEMORY.md", "TAXONOMY.md"].contains($0.lastPathComponent) }
        // The first memory kept who you are in MEMORY.md: it is USER.md now.
        let marker = folder.appendingPathComponent(".layout")
        // Claimed first, and only once: a terminal and the browser starting
        // at the same moment don't both move the same notes.
        let claim = Darwin.open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if claim >= 0 {
            _ = Darwin.write(claim, "2\n", 2)
            Darwin.close(claim)
            // Nothing old is removed until what replaces it is written.
            if let old = try? String(contentsOf: operating, encoding: .utf8), meaningful(old), !fm.fileExists(atPath: user.path) {
                let moved = Seeds.user + "\n" + old.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
                if (try? moved.write(to: user, atomically: true, encoding: .utf8)) != nil { try? fm.removeItem(at: operating) }
            }
            var moved = ""
            var done: [URL] = []
            for url in flat {
                guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
                done.append(url)
                guard meaningful(body) else { continue }
                moved += "\n## From the earlier \(url.deletingPathExtension().lastPathComponent) notes\n\n"
                    + body.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
            var written = moved.isEmpty
            if !moved.isEmpty, let day = file(today) {
                let body = ((try? String(contentsOf: day, encoding: .utf8)) ?? "# \(day.deletingPathExtension().lastPathComponent)\n") + moved
                written = (try? body.write(to: day, atomically: true, encoding: .utf8)) != nil
            }
            if written { for url in done { try? fm.removeItem(at: url) } }
        }
        for (name, seed) in [("USER.md", Seeds.user), ("MEMORY.md", Seeds.operating), ("TAXONOMY.md", Seeds.taxonomy)] {
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try? seed.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Everything, gone: the folder, and its seeds put back; and what the
    /// notes page kept of Get to Know besides memory (KnowReport).
    static func forgetEverything() {
        let plan = ContextPrivacy.shared.preview()
        _ = ContextPrivacy.shared.clear(plan, choices: [:])
    }

    static func eraseFiles() -> Bool {
        do {
            for file in [folder, KnowReport.file] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { return false }
        prepared = false
        prepare()
        return !FileManager.default.fileExists(atPath: KnowReport.file.path) && empty
    }

    // MARK: - search

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// A word's stand-in when it is long: its first five letters.
    private static func stem(_ word: String) -> String {
        word.count > 5 ? String(word.prefix(5)) : word
    }

    struct Hit {
        let file: String
        let line: Int
        let text: String
        let score: Double
    }

    static func search(_ queries: [String], limit: Int = 8, mail: Bool = true) -> [Hit] {
        // Paragraphs, each with where it starts.
        var chunks: [(file: String, line: Int, text: String, stems: [String: Int], length: Int)] = []
        // A chat project's page is told only to the chats in it (Agents.brief).
        for path in files() where path != "TAXONOMY.md" && !projectPage(path) {
            guard let read = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8),
                  let body = seen(path, read, mail: mail) else { continue }
            var start = 1
            var current: [String] = []
            func flush() {
                let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let stems = words(text).map(stem)
                    chunks.append((path, start, text, Dictionary(stems.map { ($0, 1) }, uniquingKeysWith: +), stems.count))
                }
                current = []
            }
            for (n, line) in body.components(separatedBy: "\n").enumerated() {
                // A heading or a blank line ends a paragraph; so does a list
                // item, each of which is a note of its own.
                if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") || line.hasPrefix("- ") {
                    flush()
                }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("<!--") {
                    // Where it starts is its first line, not the blank one before it.
                    if current.isEmpty { start = n + 1 }
                    current.append(line)
                }
            }
            flush()
        }
        guard !chunks.isEmpty else { return [] }
        let count = Double(chunks.count)
        let average = max(1, Double(chunks.reduce(0) { $0 + $1.length }) / count)
        var seen: [String: Int] = [:]
        for chunk in chunks { for stem in chunk.stems.keys { seen[stem, default: 0] += 1 } }
        // Queries are OR-ed: a paragraph scores by the best of them.
        let asked = queries.map { Set(words($0).map(stem)) }.filter { !$0.isEmpty }
        var hits: [Hit] = []
        for chunk in chunks {
            var best = 0.0
            for terms in asked {
                var score = 0.0
                for term in terms {
                    guard let tf = chunk.stems[term].map(Double.init) else { continue }
                    let df = Double(seen[term] ?? 0)
                    let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                    score += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(chunk.length) / average))
                }
                best = max(best, score)
            }
            if best > 0 { hits.append(Hit(file: chunk.file, line: chunk.line, text: chunk.text, score: best)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}

// MARK: - the seeds

/// What an empty memory starts with: two briefs waiting to be written, and
/// the rules for where things go, which the agents read before filing.
enum Seeds {
    static let user = """
    # User Briefing
    <!-- Who the user is, in a few lines, loaded into every task. Kept current by the daily pass. -->

    """

    static let operating = """
    # Memory Briefing
    <!-- How to work for the user, in a few lines, loaded into every task. Kept current by the daily pass. -->

    """

    static let taxonomy = """
    # Where memory goes

    ## Rules that always hold

    - Everything lives under `memory/`, as plain Markdown the user can read and edit.
    - The subject pages and the episodic days are the source of truth. `USER.md` and `MEMORY.md`
      are summaries drawn from them, loaded into every task, so they stay short.
    - A subject page has frontmatter, then `## Current` (what is believed now) and `## History`
      (why: dated entries, each naming the episodic day it came from).
    - Episodic days (`episodic/YYYY-MM-DD.md`) are only ever added to: a timestamped heading,
      plain prose, one fact to a paragraph, and the task it came from.
    - Every fact has one home. Link to it from elsewhere rather than repeating it.
    - Never keep passwords, one-time codes, card numbers or other secrets.

    ## The two briefs

    `USER.md`: who the user is and what they want, in the long run. Name, work, the services and
    accounts they rely on and what for, stable preferences. Not: site procedures, one task's notes,
    a dossier.

    `MEMORY.md`: how an agent should work for them, on any task. Standing rules, defaults,
    conventions. Not: facts about the world, one site's quirks, one task's context.

    ## The folders

    - `users/<slug>.md`: the full page on the user, when `USER.md` is too small for it.
    - `people/<slug>.md`: other people in the user's life and work, one page each.
    - `companies/<slug>.md`: organizations, what they are to the user, their history together.
    - `sites/<host>.md`: one page per website: what the user uses it for, how it behaves, where
      things are, which account.
    - `projects/<slug>.md`: work in progress that lasts, its decisions and threads.
    - `concepts/<slug>.md`: ideas and lessons that apply across projects and sites.
    - `agent/<slug>.md`: longer operating rules, when `MEMORY.md` is too small for them.
    - `episodic/YYYY-MM-DD.md`: what each day's tasks noticed that may matter later, including
      things too early or too thin to file anywhere else.

    ## Deciding where something goes

    1. Will it still matter after this task? If not, don't keep it.
    2. Is it thin, one-off, or unsure? Put it in today's episodic day and stop.
    3. Did it change what is known about a subject? Update that subject's page too: add to
       `History` first, change `Current` only if the understanding changed.
    4. Is there a page for it already? Use it. Check names before making a new one.
    5. Does it matter at the start of every task? Then it belongs in `USER.md` or `MEMORY.md`.
    6. Fits nowhere? Put it in the nearest home and note the trouble here.
    """
}

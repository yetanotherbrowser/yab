import AppKit
import Foundation
import SwiftUI

// Snippets (docs/snippets.md, docs/mail.md Snippets): words kept to write
// again, one list for all of Yab on this Mac. Each
// works everywhere, in a page's box (PageSnippets) as in a mail, or in Mail
// only, where To, Cc, Bcc, a subject and files come with it. Each has a
// name, its words, To, Cc, Bcc, a subject, files, and how often it was used,
// the order they are offered in. ";" at a word's start in a mail's words, or
// ⌘;, puts one in where the caret is: {first_name}, {name}, {my_name} and
// {date} filled from the draft's first To chip and the account, To, Cc, Bcc
// and the subject only where the draft has none, its files copied into the
// draft (MailAttach), the use counted; ⌘Z in the words takes all of it back.
// {{…}} marks a place to fill by hand, and a mail with one left doesn't
// send. ⌘K's Save as Snippet keeps a mail's words, or the draft's.
//
// Kept in mail/snippets.noindex/snippets.json beside the accounts' stores
// rather than in one of them (out of Spotlight): shared by every account, a
// handful of small records read once and written whole when one changes,
// as Commands keep commands.json; no Disconnect takes them away. Their
// files are copies in the snippets folder beside it, <snippet>/<file>/
// <name>, so a snippet keeps its files whatever happens to
// the ones chosen.

/// A snippet: words kept to write again, with what they come with.
struct MailSnippet: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var body: String
    /// Whom it is to, as a header says them ("Anna <anna@fold.studio>,
    /// …"): put in only where the draft has none.
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    /// Its files, each a copy kept beside it (MailSnippets.place).
    var files: [File] = []
    /// How often it went into a mail, and when last: the order it is
    /// offered in.
    var uses = 0
    var used: Date?
    var made = Date()
    /// Only in a mail: never offered in a page's box. A snippet with whom
    /// it is to, a subject or files is one, as an older Yab kept them all.
    var mailOnly = false
    /// Its own key, as Hotkey keeps one ("" for none): typed into the box
    /// the caret is in (PageSnippets.take), or into a mail's words.
    var hotkey = ""

    struct File: Codable, Equatable, Hashable {
        /// The folder its copy is kept in.
        var id: String
        var name: String
        var mime: String
        var size: Int
    }

    init(id: String = UUID().uuidString.lowercased(), name: String, body: String, to: String = "", cc: String = "", bcc: String = "",
         subject: String = "", files: [File] = [], uses: Int = 0, used: Date? = nil, made: Date = Date(),
         mailOnly: Bool = false, hotkey: String = "") {
        self.id = id
        self.name = name
        self.body = body
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.files = files
        self.uses = uses
        self.used = used
        self.made = made
        self.mailOnly = mailOnly
        self.hotkey = hotkey
    }

    /// Read leniently: a field a later Yab added, or one an earlier left
    /// out, takes its default rather than losing the snippet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        cc = try c.decodeIfPresent(String.self, forKey: .cc) ?? ""
        bcc = try c.decodeIfPresent(String.self, forKey: .bcc) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
        used = try c.decodeIfPresent(Date.self, forKey: .used)
        made = try c.decodeIfPresent(Date.self, forKey: .made) ?? Date()
        mailOnly = try c.decodeIfPresent(Bool.self, forKey: .mailOnly) ?? MailSnippet.mailish(to: to, cc: cc, bcc: bcc, subject: subject, files: files)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? ""
    }

    /// Whether what it comes with only makes sense in a mail.
    static func mailish(to: String, cc: String, bcc: String, subject: String, files: [File]) -> Bool {
        ![to, cc, bcc, subject].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } || !files.isEmpty
    }

    /// Where it works, as Settings says it.
    var whereSaid: String { mailOnly ? "In Mail only" : "Everywhere" }

    /// Its first words, on one line, as a row says them.
    var gist: String {
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }

    /// Its files in words: "1 file", "2 files"; "" for none.
    var filesSaid: String { files.isEmpty ? "" : files.count == 1 ? "1 file" : "\(files.count) files" }
}

@MainActor
final class MailSnippets: ObservableObject {
    static let shared = MailSnippets()

    /// Every snippet, in the order they were made.
    @Published private(set) var all: [MailSnippet] = []
    /// mail/snippets.noindex/snippets.json; the files in the snippets
    /// folder beside it.
    let file: URL
    var folder: URL { file.deletingPathExtension() }

    /// Where Yab keeps them: beside the accounts' stores, in a folder
    /// Spotlight leaves out, so their words and files never turn up in a
    /// search of the Mac. An older Yab's mail/snippets.json and its
    /// mail/snippets move in the first time.
    nonisolated static var home: URL {
        let mail = MailStore.file(for: "x").deletingLastPathComponent()
        let folder = mail.appendingPathComponent("snippets.noindex", isDirectory: true)
        let file = folder.appendingPathComponent("snippets.json")
        let fm = FileManager.default
        let old = mail.appendingPathComponent("snippets.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: file.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: file)
        }
        MailStore.noIndex(from: mail.appendingPathComponent("snippets", isDirectory: true), to: file.deletingPathExtension())
        return file
    }

    init(file: URL = MailSnippets.home) {
        self.file = file
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: file) else { all = []; return }
        // Dates as Foundation keeps them, so they read back exactly.
        guard let read = try? JSONDecoder().decode([MailSnippet].self, from: data) else {
            // Set aside rather than written over at the next change.
            Store.quarantine(file)
            all = []
            return
        }
        all = read
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - finding them

    /// Most used first; of as many uses, the one used last; then by name.
    var ordered: [MailSnippet] {
        all.sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            if a.used != b.used { return (a.used ?? .distantPast) > (b.used ?? .distantPast) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func snippet(_ id: String) -> MailSnippet? { all.first { $0.id == id } }

    /// The one of this name, whatever its case.
    func named(_ name: String) -> MailSnippet? {
        let wanted = MailSnippets.folded(name)
        return wanted.isEmpty ? nil : all.first { MailSnippets.folded($0.name) == wanted }
    }

    /// Those whose name the words begin, or one of its words, in their
    /// order of use; those that only hold them after. All, for no words.
    /// `pages`: only those that work outside a mail.
    func matching(_ words: String, pages: Bool = false) -> [MailSnippet] {
        let needle = MailSnippets.folded(words)
        let list = pages ? ordered.filter { !$0.mailOnly } : ordered
        guard !needle.isEmpty else { return list }
        var starts: [MailSnippet] = [], holds: [MailSnippet] = []
        for snippet in list {
            let name = MailSnippets.folded(snippet.name)
            if name.hasPrefix(needle) || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) {
                starts.append(snippet)
            } else if name.contains(needle) {
                holds.append(snippet)
            }
        }
        return starts + holds
    }

    /// A name as the picker compares it: case and accents off, spaces
    /// trimmed.
    nonisolated static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: - keeping them

    /// A new one, its files copied beside it; one of the same name has its
    /// place taken, and keeps its uses.
    @discardableResult
    func add(name: String, body: String, to: String = "", cc: String = "", bcc: String = "", subject: String = "",
             files: [URL] = [], mailOnly: Bool? = nil, hotkey: String = "") -> MailSnippet {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var snippet = MailSnippet(name: name, body: body, to: to, cc: cc, bcc: bcc, subject: subject,
                                  mailOnly: mailOnly ?? MailSnippet.mailish(to: to, cc: cc, bcc: bcc, subject: subject, files: []) || !files.isEmpty,
                                  hotkey: hotkey)
        if let old = named(name) {
            snippet.id = old.id
            snippet.uses = old.uses
            snippet.used = old.used
            snippet.made = old.made
            if hotkey.isEmpty { snippet.hotkey = old.hotkey }
            drop(files: old.files, of: old.id)
        }
        snippet.files = take(files, into: snippet.id)
        if let at = all.firstIndex(where: { $0.id == snippet.id }) { all[at] = snippet } else { all.append(snippet) }
        save()
        return snippet
    }

    /// Changed in Settings: its words, its name, whom it is to, its
    /// subject, the files it keeps (those gone deleted) and any to add.
    func change(_ snippet: MailSnippet, adding urls: [URL] = []) {
        guard let at = all.firstIndex(where: { $0.id == snippet.id }) else { return }
        var now = snippet
        now.name = now.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everywhere, it comes with words alone: what only a mail takes goes.
        if !now.mailOnly {
            (now.to, now.cc, now.bcc, now.subject, now.files) = ("", "", "", "", [])
        }
        let kept = Set(now.files.map(\.id))
        drop(files: all[at].files.filter { !kept.contains($0.id) }, of: now.id)
        now.files += take(urls, into: now.id)
        all[at] = now
        save()
    }

    /// Deleted, its files with it.
    /// Another app's snippets as they would come in (SnippetSources.swift):
    /// one already here word for word is left unticked, and a name taken
    /// here or earlier in the list gets a number after it.
    func planned(_ found: [FoundSnippet]) -> [FoundSnippet] {
        var taken = Set(all.map { MailSnippets.folded($0.name) })
        return found.map { one in
            var one = one
            if let same = named(one.name), same.body == one.body, same.subject == one.subject {
                one.take = false
                one.note = "Already here"
                one.odd = false
                return one
            }
            let wanted = one.name
            var number = 2
            while taken.contains(MailSnippets.folded(one.name)) {
                one.name = wanted + String(number)
                number += 1
            }
            if one.name != wanted, !one.odd {
                one.note = ";\(wanted) is taken"
            }
            taken.insert(MailSnippets.folded(one.name))
            return one
        }
    }

    /// The ticked ones kept, written once; their ids, for the list to light.
    @discardableResult
    func bringIn(_ found: [FoundSnippet]) -> [String] {
        var taken = Set(all.map { MailSnippets.folded($0.name) })
        var ids: [String] = []
        for one in found where one.take {
            let wanted = one.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty, !one.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var name = wanted
            var number = 2
            while taken.contains(MailSnippets.folded(name)) {
                name = wanted + String(number)
                number += 1
            }
            taken.insert(MailSnippets.folded(name))
            let snippet = MailSnippet(name: name, body: one.body, to: one.to, cc: one.cc, bcc: one.bcc, subject: one.subject,
                                      mailOnly: MailSnippet.mailish(to: one.to, cc: one.cc, bcc: one.bcc, subject: one.subject, files: []))
            all.append(snippet)
            ids.append(snippet.id)
        }
        if !ids.isEmpty { save() }
        return ids
    }

    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(MailFiles.safe(id), isDirectory: true))
        save()
    }

    /// Deleted, and the way back for ⌘Z: the snippet where it stood, its
    /// files set aside meanwhile rather than gone.
    func removeUndoably(_ id: String) -> () -> Void {
        guard let at = all.firstIndex(where: { $0.id == id }) else { return {} }
        let snippet = all[at]
        let files = folder.appendingPathComponent(MailFiles.safe(id), isDirectory: true)
        let aside = FileManager.default.temporaryDirectory.appendingPathComponent("yab-snippet-" + UUID().uuidString, isDirectory: true)
        let kept = (try? FileManager.default.moveItem(at: files, to: aside)) != nil
        all.remove(at: at)
        save()
        return { [weak self] in
            guard let self, !all.contains(where: { $0.id == id }) else { return }
            if kept { try? FileManager.default.moveItem(at: aside, to: files) }
            all.insert(snippet, at: min(at, all.count))
            save()
        }
    }

    /// Put in a mail once more (`by` 1), or taken back out (-1).
    func used(_ id: String, by: Int = 1, at: Date = Date()) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].uses = max(0, all[index].uses + by)
        if by > 0 { all[index].used = at }
        save()
    }

    // MARK: - their files

    /// Where a file of a snippet is kept: a folder of its own, under its
    /// own name, as a draft's are (MailAttach.place).
    func place(_ file: MailSnippet.File, of snippet: String) -> URL {
        folder.appendingPathComponent(MailFiles.safe(snippet), isDirectory: true)
            .appendingPathComponent(MailFiles.safe(file.id), isDirectory: true)
            .appendingPathComponent(MailFiles.safe(file.name))
    }

    /// Its files' copies that are here, in order.
    func urls(of snippet: MailSnippet) -> [URL] {
        snippet.files.map { place($0, of: snippet.id) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Files copied in, a folder each; a folder, or what can't be read, left out.
    private func take(_ urls: [URL], into snippet: String) -> [MailSnippet.File] {
        urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]), values.isRegularFile == true else { return nil }
            var file = MailSnippet.File(id: String(UUID().uuidString.prefix(8)).lowercased(), name: url.lastPathComponent,
                                        mime: MailAttach.mime(url.lastPathComponent, values.contentType), size: 0)
            let into = place(file, of: snippet)
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: into)
                file.size = (try into.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            } catch {
                try? fm.removeItem(at: into.deletingLastPathComponent())
                return nil
            }
            return file
        }
    }

    private func drop(files: [MailSnippet.File], of snippet: String) {
        for file in files { try? FileManager.default.removeItem(at: place(file, of: snippet).deletingLastPathComponent()) }
    }
}

// MARK: - the words

extension MailSnippets {
    /// What a snippet's words may say, filled as it goes in.
    nonisolated static let variables = ["first_name", "name", "my_name", "date", "clipboard"]
    /// The ones that mean something outside a mail too.
    nonisolated static let everywhere = ["date", "clipboard"]

    /// A place to fill by hand, {{…}}, and a variable, {first_name}: the
    /// first is matched before the second, so {{first_name}} stays a place.
    private nonisolated static let marks = try! NSRegularExpression(pattern: "\\{\\{[^{}\\n]{1,80}\\}\\}|\\{(" + variables.joined(separator: "|") + ")\\}",
                                                                     options: [.caseInsensitive])
    private nonisolated static let places = try! NSRegularExpression(pattern: "\\{\\{[^{}\\n]{1,80}\\}\\}")

    /// The words as they go in: {first_name} and {name} from the person
    /// it is to (the draft's first To chip), {my_name} from the account,
    /// {date} today's, as `locale` writes a date ("October 1, 2026"). One
    /// with nothing to fill it becomes a place to fill by hand,
    /// {{first_name}}, which keeps the mail from going until it is.
    nonisolated static func fill(_ text: String, to person: MailPerson?, me: String, date: Date, clipboard: String? = nil,
                                 locale: Locale = AppDates.locale, zone: TimeZone = .current) -> String {
        let name = person?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let mine = me.trimmingCharacters(in: .whitespaces)
        let filled: [String: String] = ["first_name": first(of: name), "name": name, "my_name": mine,
                                        "date": said(date, locale: locale, zone: zone), "clipboard": clipboard ?? board(for: text)]
        return fill(text, with: filled, only: nil)
    }

    /// The words as they go into a page's box: {date} and {clipboard}
    /// filled; {first_name} and the rest are a mail's, left as written.
    nonisolated static func fillPage(_ text: String, date: Date, clipboard: String? = nil, locale: Locale = AppDates.locale,
                                     zone: TimeZone = .current) -> String {
        fill(text, with: ["date": said(date, locale: locale, zone: zone), "clipboard": clipboard ?? board(for: text)], only: Set(everywhere))
    }

    /// The clipboard, read only for words that ask for it.
    private nonisolated static func board(for text: String) -> String {
        text.range(of: "{clipboard}", options: .caseInsensitive) == nil ? "" : pasteboard()
    }

    /// A date as {date} says it: "October 1, 2026", as `locale` writes one.
    nonisolated static func said(_ date: Date, locale: Locale, zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = zone
        format.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
        return format.string(from: date)
    }

    /// The text on the clipboard now, for {clipboard}: none from a
    /// password manager's copy (Clips.concealed).
    nonisolated static func pasteboard() -> String {
        let board = NSPasteboard.general
        if Clips.concealed((board.types ?? []).map(\.rawValue)) { return "" }
        return board.string(forType: .string) ?? ""
    }

    /// Each variable in `only` (all, for nil) from `filled`; one with
    /// nothing to fill it becomes a place to fill by hand.
    private nonisolated static func fill(_ text: String, with filled: [String: String], only: Set<String>?) -> String {
        let whole = text as NSString
        var out = ""
        var at = 0
        for match in marks.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: at, length: match.range.location - at))
            at = match.range.location + match.range.length
            // A place to fill by hand stays as it is.
            guard match.range(at: 1).location != NSNotFound else {
                out += whole.substring(with: match.range)
                continue
            }
            let variable = whole.substring(with: match.range(at: 1)).lowercased()
            if let only, !only.contains(variable) {
                out += whole.substring(with: match.range)
                continue
            }
            let value = filled[variable] ?? ""
            out += value.isEmpty ? "{{" + variable + "}}" : value
        }
        return out + whole.substring(from: at)
    }

    /// A first name from a whole one: its first word, or what follows the
    /// comma of "Lindqvist, Anna".
    nonisolated static func first(of name: String) -> String {
        let given = name.contains(",") ? name.split(separator: ",", maxSplits: 1).last.map(String.init) ?? name : name
        return given.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    /// The places left to fill by hand, each once, in order: "{{date}}".
    nonisolated static func holes(_ text: String) -> [String] {
        let whole = text as NSString
        var out: [String] = []
        for match in places.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let one = whole.substring(with: match.range)
            if !out.contains(one) { out.append(one) }
        }
        return out
    }

    /// A draft's: in its subject and its words, not the mail it quotes.
    nonisolated static func holes(subject: String, body: String) -> [String] {
        var out = holes(subject)
        for one in holes(body) where !out.contains(one) { out.append(one) }
        return out
    }

    /// What the line over Send says while any is left: "Fill in {{date}}
    /// before sending"; nil for none.
    nonisolated static func line(_ holes: [String]) -> String? {
        switch holes.count {
        case 0: return nil
        case 1: return "Fill in \(holes[0]) before sending"
        case 2: return "Fill in \(holes[0]) and \(holes[1]) before sending"
        default: return "Fill in \(holes[0]), \(holes[1]) and \(holes.count - 2) more before sending"
        }
    }

    /// The first place to fill in the words (or in a part of them), to
    /// choose once they are in.
    nonisolated static func firstHole(_ text: String, in part: NSRange? = nil) -> NSRange? {
        let all = NSRange(location: 0, length: (text as NSString).length)
        return places.firstMatch(in: text, range: part.map { NSIntersectionRange($0, all) } ?? all)?.range
    }

    /// ";" at a word's start, and the name typed after it up to the caret:
    /// where it all stands (to be replaced), and the name. Nil when the
    /// caret isn't at the end of such a word, or ";" follows anything but
    /// a space, a line's start or the words' start. UTF-16, as text views count.
    nonisolated static func trigger(in text: String, caret: Int) -> (range: NSRange, words: String)? {
        let all = text as NSString
        guard caret >= 1, caret <= all.length else { return nil }
        let word = { (unit: unichar) -> Bool in
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
        // Mid-word: only at the end of the name.
        if caret < all.length, word(all.character(at: caret)) { return nil }
        var start = caret
        while start > 0, word(all.character(at: start - 1)) { start -= 1 }
        guard start >= 1, all.character(at: start - 1) == 0x3B else { return nil }
        let semicolon = start - 1
        if semicolon > 0, let before = Unicode.Scalar(all.character(at: semicolon - 1)),
           !CharacterSet.whitespacesAndNewlines.contains(before) { return nil }
        // A name is a few words' worth.
        guard caret - start <= 40 else { return nil }
        return (NSRange(location: semicolon, length: caret - semicolon), all.substring(with: NSRange(location: start, length: caret - start)))
    }

    /// A mail's own words, as a snippet keeps them: not the mail it
    /// quotes or forwards under them (MailMemory's reading of where that
    /// begins), nor its signature, nor blank lines at either end.
    nonisolated static func words(of message: MailMessage) -> String { own(MailCompose.words(of: message)) }

    /// Words as a snippet keeps them, a mail's or a draft's: up to the mail
    /// they quote or forward, without the signature, trimmed.
    nonisolated static func own(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let quote = MailMemory.quoteStart(lines) { lines = Array(lines[..<quote]) }
        if let forward = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == MailCompose.forwardLine }) {
            lines = Array(lines[..<forward])
        }
        if let signature = signatureStart(lines) { lines = Array(lines[..<signature]) }
        return trimmed(lines.joined(separator: "\n"))
    }

    /// Where a mail's signature begins: "-- ", a phone's "Sent from …",
    /// or the last sign-off ("Best,") with no more than a name and a title
    /// under it. Gentler than the memory's (MailMemory.signatureStart): a
    /// "Thanks!" the words end on is theirs.
    nonisolated static func signatureStart(_ lines: [String]) -> Int? {
        let bare = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        if let dashes = lines.firstIndex(where: { $0 == "-- " || $0.trimmingCharacters(in: .whitespaces) == "--" }), dashes > 0 { return dashes }
        let devices = ["sent from my ", "sent from mail for", "get outlook for", "sent via ", "envoyé de mon", "von meinem"]
        if let device = bare.indices.first(where: { n in n > 0 && bare[n].count < 60 && devices.contains { bare[n].lowercased().hasPrefix($0) } }) {
            return device
        }
        let filled = bare.indices.filter { !bare[$0].isEmpty }
        guard let last = filled.last else { return nil }
        for n in filled.suffix(3).reversed() where n > 0 {
            let line = bare[n].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!:;- "))
            guard MailMemory.signoffs.contains(line) else { continue }
            let under = filled.filter { $0 > n }
            return under.count <= 2 && under.allSatisfy({ bare[$0].count <= 40 }) && n < last ? n : nil
        }
        return nil
    }

    /// Without blank lines or spaces at either end.
    nonisolated static func trimmed(_ text: String) -> String {
        var lines = MailCompose.trailing(text).components(separatedBy: "\n")
        while let line = lines.first, line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// A subject as a snippet keeps it: without Re: and Fwd:.
    nonisolated static func bare(subject: String) -> String {
        var out = subject.trimmingCharacters(in: .whitespaces)
        while let colon = out.firstIndex(of: ":"),
              ["re", "fwd", "fw"].contains(out[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
            out = out[out.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// A name for words not named yet: the subject, or their first few words.
    nonisolated static func suggestedName(subject: String, body: String) -> String {
        let topic = bare(subject: subject)
        if !topic.isEmpty { return topic.count > 40 ? String(topic.prefix(39)) + "…" : topic }
        let words = body.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        return words.count > 40 ? String(words.prefix(39)) + "…" : words
    }
}

// MARK: - into a draft

/// What a snippet put into a draft, so ⌘Z takes it back and ⇧⌘Z puts it in
/// again: the draft's people and subject before and after, the files it
/// copied in, the snippet whose use it counted.
struct MailSnippetPut {
    let draft: String
    let snippet: String
    let before: (to: String, cc: String, bcc: String, subject: String)
    let after: (to: String, cc: String, bcc: String, subject: String)
    var files: [MailDraftFile]
}

extension MailDesk {
    /// A snippet into the draft, as ⌘; and ";" put it (MailSnippets): To,
    /// Cc, Bcc and the subject where the draft has none, its words where
    /// the caret is (over `typed`, ";" and its name), its variables filled
    /// from the draft's first To chip and the account, its files copied in;
    /// the use counted. The words go in through the text view itself, so ⌘Z
    /// there takes all of it back, the people and files with them; the
    /// caret on the first place left to fill, else after the words.
    func insert(_ snippet: MailSnippet, replacing typed: NSRange? = nil) {
        guard var now = draft, let engine = MailCenter.shared.engines[now.account] else { return }
        let before = (to: now.to, cc: now.cc, bcc: now.bcc, subject: now.subject)
        let empty = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if empty(now.to) { now.to = snippet.to }
        if empty(now.cc) { now.cc = snippet.cc }
        if empty(now.bcc) { now.bcc = snippet.bcc }
        if empty(now.subject) { now.subject = snippet.subject }
        let text = MailSnippets.fill(snippet.body, to: firstTo(now.to), me: engine.store.myName(), date: MailClock.now)
        let copies = MailAttach.take(MailSnippets.shared.urls(of: snippet), draft: now.id, store: engine.store)
        now.files += copies
        let put = MailSnippetPut(draft: now.id, snippet: snippet.id, before: before,
                                 after: (to: now.to, cc: now.cc, bcc: now.bcc, subject: now.subject), files: copies)
        chooseDraftChip(nil)
        why = ""
        draft = now
        MailSnippets.shared.used(snippet.id)
        guard let view = wordsView() else {
            // No words on screen to take them: after them, their marks kept
            // (MailDesk.insert, as free times go in).
            insert(now.body.isEmpty ? text : "\n" + text)
            return
        }
        let range = typed ?? view.selectedRange()
        view.breakUndoCoalescing()
        let undo = view.undoManager
        undo?.beginUndoGrouping()
        let span = MailDesk.put(text, in: view, over: range)
        undo?.registerUndo(withTarget: self) { desk in MainActor.assumeIsolated { desk.takeBack(put) } }
        undo?.setActionName("Insert Snippet")
        undo?.endUndoGrouping()
        view.breakUndoCoalescing()
        // Its words in the draft now (the text view said them): kept, with the files.
        save()
        // The caret on the first place to fill, else after the words; the
        // keyboard there once a field that had it has gone (handBack).
        let chosen = MailSnippets.firstHole(view.string, in: span) ?? NSRange(location: span.location + span.length, length: 0)
        view.setSelectedRange(chosen)
        view.scrollRangeToVisible(chosen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak view] in
            guard let view, view.window != nil else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(chosen)
        }
    }

    /// ⌘Z after a snippet went in: the draft's people and subject as they
    /// were, the files it brought gone with their copies, its use uncounted;
    /// ⇧⌘Z puts them back (`putBack`).
    func takeBack(_ put: MailSnippetPut) {
        if var now = draft, now.id == put.draft {
            now.to = put.before.to
            now.cc = put.before.cc
            now.bcc = put.before.bcc
            now.subject = put.before.subject
            let gone = Set(put.files.map(\.id))
            now.files.removeAll { gone.contains($0.id) }
            if let chosen = draftChip, gone.contains(chosen) { chooseDraftChip(nil) }
            draft = now
            if let engine = MailCenter.shared.engines[now.account] {
                for file in put.files { MailAttach.remove(file, draft: now.id, store: engine.store) }
            }
            storeDraft(now)
        }
        MailSnippets.shared.used(put.snippet, by: -1)
        wordsView()?.undoManager?.registerUndo(withTarget: self) { desk in MainActor.assumeIsolated { desk.putBack(put) } }
    }

    /// ⇧⌘Z after that: the people, the subject and the files again, copied
    /// from the snippet anew.
    func putBack(_ put: MailSnippetPut) {
        var put = put
        if var now = draft, now.id == put.draft, let engine = MailCenter.shared.engines[now.account] {
            now.to = put.after.to
            now.cc = put.after.cc
            now.bcc = put.after.bcc
            now.subject = put.after.subject
            let copies = MailSnippets.shared.snippet(put.snippet).map { MailAttach.take(MailSnippets.shared.urls(of: $0), draft: now.id, store: engine.store) } ?? []
            now.files += copies
            put.files = copies
            draft = now
            storeDraft(now)
        }
        MailSnippets.shared.used(put.snippet)
        wordsView()?.undoManager?.registerUndo(withTarget: self) { desk in MainActor.assumeIsolated { desk.takeBack(put) } }
    }

    /// Words put into a text view over `range` as a paste puts them,
    /// undone as one by ⌘Z: in a mail's words, with the blocks of the line
    /// they join (MailWordsView.insert); elsewhere in its own attributes.
    /// Where they stand once in.
    @discardableResult
    static func put(_ text: String, in view: NSTextView, over range: NSRange) -> NSRange {
        let length = (view.string as NSString).length
        let start = min(max(0, range.location), length)
        let range = NSRange(location: start, length: min(max(0, range.length), length - start))
        if let words = view as? MailWordsView {
            words.setSelectedRange(range)
            words.insert(text)
            return NSRange(location: start, length: max(0, words.selectedRange().location - start))
        }
        guard view.shouldChangeText(in: range, replacementString: text) else { return NSRange(location: start, length: 0) }
        view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: view.typingAttributes))
        view.didChangeText()
        return NSRange(location: start, length: (text as NSString).length)
    }

    /// The first person the draft is to, with the name you know them by
    /// when the chip has none.
    func firstTo(_ header: String) -> MailPerson? {
        guard var person = MailPerson.list(header).first else { return nil }
        if person.name.isEmpty { person.name = name(of: person.address) }
        return person
    }

    /// The words of the reply or the new mail on screen: the text view
    /// with the keyboard, else the letter in front's (MailWords hands it
    /// over), else the one that holds the draft's words.
    func wordsView() -> NSTextView? {
        if let focused = focusedWords { return focused }
        if let live = words, live.window != nil { return live }
        guard let root = mailWindow?.contentView else { return nil }
        var found: [MailWordsView] = []
        func walk(_ view: NSView) {
            if let words = view as? MailWordsView { found.append(words) }
            view.subviews.forEach(walk)
        }
        walk(root)
        let body = draft?.body
        return found.first { $0.string == body } ?? found.last
    }

    /// The draft's words when they have the keyboard: at every key, without
    /// a look through the window.
    var focusedWords: NSTextView? { mailWindow?.firstResponder as? MailWordsView }

    private var mailWindow: NSWindow? { MailMorph.shared.pane?.window ?? browser.flatMap { BrowserWindows.shared.window(for: $0) } }

    /// The draft in the store as it stands, its files with it.
    private func storeDraft(_ now: Draft) {
        guard let engine = MailCenter.shared.engines[now.account] else { return }
        engine.store.save(now.kept(over: engine.store.draft(now.id) ?? MailDraft(id: now.id, thread: now.thread)))
        MailCenter.shared.touch()
    }

    /// The places left to fill in the draft in front.
    var holes: [String] { draft?.holes ?? [] }

    // MARK: - saving one

    /// What Save as Snippet keeps from what is in front: the draft being
    /// written (its words without a signature, a new mail's subject, Cc,
    /// Bcc and its own files), or a mail (the arrows' one in an open thread, else the
    /// thread's last), its own words and its subject. Nil when there are no
    /// words to keep.
    func snippetSource(account: String = "", thread: String = "") -> (body: String, subject: String, cc: String, bcc: String, files: [URL])? {
        if let draft {
            let body = MailSnippets.own(draft.body)
            guard !body.isEmpty, let engine = MailCenter.shared.engines[draft.account] else { return nil }
            let own = draft.files.filter { !$0.original }.compactMap { MailAttach.place($0, draft: draft.id, store: engine.store) }
            return (body, draft.thread.isEmpty ? draft.subject : "", draft.cc, draft.bcc, own)
        }
        let row = open ?? chosen
        let account = account.isEmpty ? row?.account ?? "" : account
        let thread = thread.isEmpty ? row?.thread ?? "" : thread
        guard let store = MailCenter.shared.engines[account]?.store else { return nil }
        let all = store.messages(thread: thread)
        let shown = screen == .thread && open?.thread == thread ? focus : nil
        guard let message = shown.flatMap({ all.indices.contains($0) ? all[$0] : nil }) ?? all.last else { return nil }
        let body = MailSnippets.words(of: message)
        guard !body.isEmpty else { return nil }
        return (body, MailSnippets.bare(subject: message.subject), "", "", [])
    }

    /// ⌘K's Save as Snippet, named: kept, said in the corner, where nothing
    /// else shows it.
    func saveSnippet(named name: String, account: String = "", thread: String = "") {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let source = snippetSource(account: account, thread: thread) else { return }
        let replaced = MailSnippets.shared.named(name) != nil
        MailSnippets.shared.add(name: name, body: source.body, cc: source.cc, bcc: source.bcc, subject: source.subject, files: source.files)
        say((replaced ? "Replaced the snippet “" : "Saved as a snippet, “") + name + "”", mark: "doc")
    }
}

extension MailSnippets {
    /// What a snippet brings to a draft made for an agent (mail_draft's
    /// `snippet`), or to its reply when the person takes it: Cc and Bcc
    /// where the draft has none, its files copied in; the use counted once.
    func bring(_ snippet: MailSnippet, into draft: inout MailDraft, store: MailStore, counted: Bool = true) {
        if draft.cc.isEmpty { draft.cc = MailPerson.list(snippet.cc) }
        if draft.bcc.isEmpty { draft.bcc = MailPerson.list(snippet.bcc) }
        draft.files += MailAttach.take(urls(of: snippet), draft: draft.id, store: store)
        if counted { used(snippet.id) }
    }
}

extension MailDesk.Draft {
    /// The places left to fill by hand in its subject and words: it
    /// doesn't send while there is one (MailDesk.send).
    var holes: [String] { MailSnippets.holes(subject: subject, body: body) }
}

extension MailStore {
    /// The account's own name, as its mail goes out: the one kept for it
    /// (meta "name"), else the newest mail from it that says one.
    func myName() -> String {
        if let kept = value("name"), !kept.isEmpty { return kept }
        return newestName(from: me)
    }
}

// MARK: - ";" in the words

/// ";" typed at a word's start in a mail's words, and the name after it:
/// the snippets by that name in a small list under the caret, the first
/// lit. ↑ and ↓ light another, ↩ (or ⇥, or a click) puts the lit one in
/// over ";" and the name, esc leaves ";" as typed and the list away until
/// another ";" (MailDesk.take has the keys first). Read again at every
/// change and caret move in the words (MailWords' `moved`).
@MainActor
final class MailSnippetPicker: ObservableObject {
    static let shared = MailSnippetPicker()

    struct Call: Equatable {
        /// The draft it is in, and ";" with the name typed so far.
        let draft: String
        let range: NSRange
        let words: String
        /// The snippets by that name, in their order, and the lit one.
        let rows: [MailSnippet]
        var lit = 0
        /// Where ";" stands in the words' own view, top down, and how wide
        /// they are: the list hangs under it and stays inside them.
        let at: CGRect
        let width: CGFloat
    }

    @Published private(set) var call: Call?
    /// Where the ";" esc put away stands: no list for it again.
    private var dismissed: (draft: String, at: Int)?

    private init() {
        // The words gave up the keyboard (a click in To, a send, the draft
        // put away): the list goes with it.
        NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { note in
            guard note.object is MailWordsView else { return }
            MainActor.assumeIsolated { MailSnippetPicker.shared.set(nil) }
        }
    }

    /// The words changed, or the caret moved: the list for what is typed
    /// after ";" at the caret, or none.
    func look(in view: NSTextView?, draft: String?) {
        guard let view, let draft, view.window?.firstResponder === view, view.selectedRange().length == 0,
              let found = MailSnippets.trigger(in: view.string, caret: view.selectedRange().location) else {
            // Out of the word: the next ";" there has its list again.
            dismissed = nil
            return set(nil)
        }
        if let dismissed, dismissed.draft == draft, dismissed.at == found.range.location { return set(nil) }
        dismissed = nil
        let rows = Array(MailSnippets.shared.matching(found.words).prefix(5))
        guard !rows.isEmpty else { return set(nil) }
        let lit = call.map { old in old.range.location == found.range.location ? rows.firstIndex { $0.id == old.rows[min(old.lit, old.rows.count - 1)].id } ?? 0 : 0 } ?? 0
        set(Call(draft: draft, range: found.range, words: found.words, rows: rows, lit: lit, at: Self.place(of: found.range.location, in: view),
                 width: view.bounds.width))
    }

    /// ↑ or ↓: another lit, round from the last to the first.
    func move(_ by: Int) {
        guard var now = call, !now.rows.isEmpty else { return }
        now.lit = (now.lit + by + now.rows.count) % now.rows.count
        call = now
    }

    /// ↩, ⇥ or a click: the lit one (or this one) in over ";" and the name.
    func take(_ index: Int? = nil) {
        guard let now = call else { return }
        let row = now.rows[min(index ?? now.lit, now.rows.count - 1)]
        set(nil)
        MailDesk.shared.insert(row, replacing: now.range)
    }

    /// esc: the list away, ";" and the name left as typed.
    func dismiss() {
        if let now = call { dismissed = (now.draft, now.range.location) }
        set(nil)
    }

    fileprivate func set(_ new: Call?) {
        if new != call { call = new }
    }

    /// Where a character stands in a text view, in its own top-down points.
    static func place(of location: Int, in view: NSTextView) -> CGRect {
        guard let layout = view.layoutManager, let container = view.textContainer else { return .zero }
        let length = (view.string as NSString).length
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(location, max(0, length - 1)), length: length == 0 ? 0 : 1),
                                       actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        return rect
    }
}

/// The list under the caret: each snippet's name, what was typed of it
/// bolder, its first words after it, the lit one on a wash, as the To
/// field's people hang under it (MailSuggestions).
struct MailSnippetPickerView: View {
    let call: MailSnippetPicker.Call
    let take: (Int) -> Void

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(call.rows.enumerated()), id: \.element.id) { index, snippet in
                HStack(spacing: 10) {
                    Symbol("doc", size: 12)
                        .foregroundStyle(Palette.muted)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        name(snippet.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(snippet.gist)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !snippet.files.isEmpty {
                        Text(snippet.filesSaid)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(index == call.lit ? Omnibox.chosenFill : .clear))
                .contentShape(Rectangle())
                .onTapGesture { take(index) }
            }
        }
        .dropFrame(width: Self.width)
    }

    /// The name, what was typed of it bolder.
    private func name(_ said: String) -> Text {
        let needle = call.words
        guard !needle.isEmpty, let range = said.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .anchored])
            ?? said.range(of: " " + needle, options: [.caseInsensitive, .diacriticInsensitive]).map({ said.index(after: $0.lowerBound)..<$0.upperBound })
        else { return Text(said) }
        return Text(said[..<range.lowerBound]) + Text(said[range]).fontWeight(.semibold) + Text(said[range.upperBound...])
    }
}

/// The files a reply ready under a thread brings from its snippet (an
/// agent's, mail_draft's `snippet`), as quiet as the card's other words:
/// they go with it, so the card says so before it is sent as it is.
struct MailSnippetFilesLine: View {
    let snippet: String
    @ObservedObject private var snippets = MailSnippets.shared

    var body: some View {
        if let files = snippets.snippet(snippet)?.files, !files.isEmpty {
            HStack(spacing: 6) {
                Symbol("paperclip", size: 11)
                Text(files.map(\.name).joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .layoutPriority(-1)
        }
    }
}

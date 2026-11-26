import SwiftUI
import AppKit
import EventKit
import WebKit
import MailCore
import YabStore

// Every kind of request the field reads past the first few (FieldRequest):
// finding what you saw, Yab's own things, mail, the calendar, sites, the
// agent, answers and memory. Yab finds candidates in what it keeps on this
// Mac first (Candidates); the reader (Jev or the Mac's own model) picks among
// them; what is built here says where each value came from. The plan and
// the catalog: artifacts U4Q4nSmR and 2NWf9Q8U, docs/field-requests.md.

/// What Yab found for some words on this Mac, before any model is asked:
/// people, sites, open tabs, pages from the history's text, mail threads,
/// downloads, clips, agent answers, spaces and settings.
struct Candidates {
    var people: [MailDesk.Contact] = []
    var hosts: [String] = []
    var tabs: [Tab] = []
    var pages: [Diary.Hit] = []
    var threads: [MailDesk.Row] = []
    var files: [Keep] = []
    var clips: [Clips.Clip] = []
    var chats: [Chat] = []
    var spaces: [Space] = []
    var settings: [Setting] = []
    /// A role the words ask for ("my lawyer") and who it is in your mail
    /// (FieldRoles).
    var role: FieldRoles.Found?

    /// A setting and one of its values, as the field can set it.
    struct Setting {
        let id: String
        let label: String
        let value: NativeValue
    }

    /// Words that only hold a sentence together: never looked up.
    static let filler: Set<String> = [
        "the", "a", "an", "my", "our", "of", "to", "in", "on", "at", "for", "from", "with", "about", "that", "this",
        "where", "what", "which", "who", "when", "is", "was", "were", "did", "do", "i", "me", "it", "and", "or", "all",
        "tab", "tabs", "page", "mail", "email", "file", "link", "find", "open", "show", "go", "please", "showed",
    ]

    /// The words that carry meaning, in the words' own letters.
    static func content(_ words: String) -> [String] {
        words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !filler.contains($0) }
    }

    @MainActor
    static func gather(_ words: String, browser: Browser, people: [MailDesk.Contact], hosts: [String],
                       role: FieldRoles.Found? = nil) async -> Candidates {
        var found = Candidates(people: people, hosts: hosts, role: role)
        // Words typed wrong are looked up mended too: "lawers" as "lawyers".
        let typed = content(words)
        let mended = FieldRoles.mended(typed)
        let content = typed + typed.compactMap { mended[$0] }.filter { !typed.contains($0) }
        let tokens = RequestModel.tokens(words).filter { !filler.contains($0) }
        let matches: (String) -> Bool = { text in
            let text = text.lowercased()
            return tokens.contains { text.contains($0) }
        }
        // Open tabs whose title or site the words name, else the latest.
        let open = browser.tabs.filter { !$0.isBlank }
        let named = open.filter { matches($0.title + " " + ($0.address?.host() ?? "")) }
        found.tabs = Array((named.isEmpty ? open.sorted { $0.touched > $1.touched } : named).prefix(16))
        // Pages from the history's text: every meaningful word, then each
        // person's name the words found in the mail.
        if !content.isEmpty {
            found.pages = await Diary.shared.pages(content.joined(separator: " "), limit: 8)
            if found.pages.isEmpty, content.count > 1 {
                for word in content where found.pages.count < 8 {
                    for hit in await Diary.shared.pages(word, limit: 4) where !found.pages.contains(hit) { found.pages.append(hit) }
                }
            }
        }
        // Mail threads, from the local store only: from a person the words
        // name first (or the role they say: "my lawyer"), then each
        // meaningful word alone, a thread more words found ranking higher
        // ("snooze the deel mail till monday" is Deel's).
        if !content.isEmpty {
            let said = people.filter { person in
                let said = person.said.lowercased()
                return tokens.contains { $0.count >= 3 && (said.hasPrefix($0) || said.contains(" " + $0)) }
            }.prefix(2)
            let named = Array(said) + (role?.people ?? []).filter { !said.contains($0) }.prefix(3)
            let rest = content.filter { word in
                !named.contains { $0.said.lowercased().contains(word) } && !(role?.words.contains(mended[word] ?? word) ?? false)
            }
            var queries = named.map { MailDesk.search(rest.joined(separator: " "), who: MailDesk.Filter(rel: "from", name: $0.name, address: $0.address)) }
            queries += named.map { MailDesk.search("", who: MailDesk.Filter(rel: "from", name: $0.name, address: $0.address)) }
            queries += rest.map { MailDesk.search($0, who: nil) }
            var score: [String: Int] = [:]
            var rows: [String: MailDesk.Row] = [:]
            for (index, query) in queries.enumerated() {
                let stores = MailDesk.beside(query, account: "all")
                let found = await Task.detached { MailDesk.find(query, in: stores, limit: 6).rows }.value
                for row in found {
                    rows[row.id] = row
                    score[row.id, default: 0] += index < named.count * 2 ? 10 : 1
                }
            }
            found.threads = Array(rows.values.sorted { (score[$0.id] ?? 0, $0.at) > (score[$1.id] ?? 0, $1.at) }.prefix(8))
        }
        found.files = Array(browser.loot.kept.filter { matches($0.name + " " + ($0.was ?? "") + " " + ($0.page?.host() ?? "")) }
            .sorted { $0.date > $1.date }.prefix(6))
        if found.files.isEmpty { found.files = Array(browser.loot.kept.sorted { $0.date > $1.date }.prefix(4)) }
        found.clips = Array(Clips.shared.find(content.joined(separator: " ")).prefix(6))
        if found.clips.isEmpty { found.clips = Array(Clips.shared.items.prefix(4)) }
        let chats = Chats.shared.all.filter { $0.archived != true }
        found.chats = Array((chats.filter { matches($0.title) }.nilIfEmpty ?? chats.sorted { $0.updated > $1.updated }).prefix(6))
        found.spaces = browser.windowPurpose == .normal ? browser.spaces : []
        found.settings = settings(browser.prefs)
        return found
    }

    /// Every boolean and choice setting with each of its values, as a
    /// person would say it: "Density: Compact".
    @MainActor
    static func settings(_ prefs: Preferences) -> [Setting] {
        var out: [Setting] = []
        for setting in NativeSetting.all {
            if let values = (setting.schema["enum"] as? [String]) {
                for value in values { out.append(Setting(id: setting.id, label: "\(setting.title): \(value)", value: .string(value))) }
            } else if setting.schema["type"] as? String == "boolean" {
                out.append(Setting(id: setting.id, label: "\(setting.title): On", value: .bool(true)))
                out.append(Setting(id: setting.id, label: "\(setting.title): Off", value: .bool(false)))
            }
        }
        return out
    }

    /// The choice questions Jev is asked about these candidates, by name:
    /// each candidate's own id here, and the short label Jev reads. Jev
    /// sees only the labels, by their number (RequestModel.body).
    @MainActor
    func questions() -> [String: [(id: String, label: String)]] {
        var asked: [String: [(id: String, label: String)]] = [:]
        func short(_ text: String) -> String { text.count > 110 ? String(text.prefix(110)) + "…" : text }
        if !tabs.isEmpty {
            asked["tab"] = tabs.map { ($0.id.uuidString, short($0.title + " · " + ($0.address?.host() ?? ""))) }
            if tabs.count > 1 { asked["other_tab"] = asked["tab"] }
        }
        if !pages.isEmpty { asked["page"] = pages.map { ($0.url, short($0.title + " · " + $0.host + ($0.passage.map { " · " + $0 } ?? ""))) } }
        if !threads.isEmpty { asked["thread"] = threads.map { ($0.id, short($0.subject + " · from " + $0.who)) } }
        if !files.isEmpty { asked["file"] = files.map { ($0.path, short($0.name)) } }
        if !clips.isEmpty { asked["clip"] = clips.map { ($0.id.uuidString, short($0.title + " · copied in " + ($0.app ?? "an app"))) } }
        if !chats.isEmpty { asked["chat"] = chats.map { ($0.id, short($0.title)) } }
        if !spaces.isEmpty { asked["space"] = spaces.map { ($0.id.uuidString, $0.name) } }
        if !settings.isEmpty { asked["setting"] = settings.map { ($0.label, $0.label) } }
        return asked
    }

    /// What each question asks, for Jev.
    static let asking: [String: String] = [
        "tab": "Which of these open tabs do the words mean, if any?",
        "other_tab": "If the words name two tabs, which is the second one?",
        "page": "Which of these pages from the person's history do the words mean, if any?",
        "thread": "Which of these mail threads do the words mean, if any?",
        "file": "Which of these downloaded files do the words mean, if any?",
        "clip": "Which of these copied items do the words mean, if any?",
        "chat": "Which of these past agent answers do the words mean, if any?",
        "space": "Which of these spaces do the words name, if any?",
        "setting": "Which of these settings and values do the words ask for, if any?",
    ]
}

extension Array {
    fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}

// MARK: building

@MainActor
enum FieldActions {
    typealias Reading = RequestReader.Reading
    typealias Field = FieldRequest.Field

    /// The requests for a kind this file knows, best first; nil for the
    /// kinds RequestReader builds itself.
    static func build(_ reading: Reading, _ words: String, _ browser: Browser) -> [FieldRequest]? {
        let found = reading.found
        let picks = reading.picks
        switch reading.kind {
        // Finding what you saw
        case "find_tab": return ordered(found.tabs, first: picks["tab"]) { $0.id.uuidString }.map { tab(browser, $0) }
        case "find_page": return ordered(unique(found.pages), first: picks["page"]) { $0.url }.map { page(browser, $0) }
        case "open_deep":
            let pages = reading.host.map { host in found.pages.filter { $0.host.hasSuffix(host) || host.hasSuffix($0.host) } } ?? found.pages
            return ordered(pages.isEmpty ? found.pages : pages, first: picks["page"]) { $0.url }.map { page(browser, $0) }
        case "find_mail":
            // Nothing here for the words: Mail's own search for them, which
            // asks Gmail too, rather than no row.
            guard !found.threads.isEmpty else { return searchMail(words) }
            return ordered(found.threads, first: picks["thread"]) { $0.id }.map { thread($0) }
        case "find_file": return ordered(found.files, first: picks["file"]) { $0.path }.map { file(browser, $0) }
        case "find_clip": return ordered(found.clips, first: picks["clip"]) { $0.id.uuidString }.map { clip($0) }
        case "find_answer": return ordered(found.chats, first: picks["chat"]) { $0.id }.map { chat($0) }
        // Yab's own
        case "close_tabs": return closeTabs(browser, reading, words)
        case "move_tabs": return moveTabs(browser, reading, words)
        case "split": return split(browser, reading)
        case "space": return space(browser, reading)
        case "video":
            guard let tab = pickTab(reading) else { return [] }
            return [one("Float \u{201C}\(tab.title)\u{201D}", "Floating video", "pip", "Float Video") { $0.float(tab) }]
        case "mute":
            guard let tab = pickTab(reading) else { return [] }
            return [one("Mute \u{201C}\(tab.title)\u{201D}", "This window", "speaker.slash", "Mute Tab") { $0.toggleMute([tab]) }]
        case "setting": return setting(browser, reading)
        case "zoom": return zoom(browser, words)
        case "archive_tabs": return archiveTabs(browser)
        case "site_perm": return sitePermission(reading, words)
        // Mail
        case "reply", "forward", "remind", "snooze", "unsubscribe", "archive_mail", "invite_answer", "track":
            return mailAct(reading.kind, reading, words, browser)
        case "send_file": return sendFile(browser, reading)
        // Calendar
        case "focus": return focus(words)
        case "join": return join()
        case "free": return free(reading, browser)
        // Sites: an issue the words say is Linear's is Linear's, whatever
        // kind the reader called it.
        case "linear": return linear(words)
        case "issue" where words.lowercased().contains("linear"): return linear(words)
        case "new_doc": return newDoc(words)
        case "post": return post(words)
        // Agent and answers
        case "pay", "compare", "spend": return agentTask(reading.kind, reading, words)
        case "who": return who(reading)
        case "remember": return remember(reading, words)
        default: return nil
        }
    }

    /// One page per title on a site: the same page twice, under two
    /// addresses, is one row.
    static func unique(_ pages: [Diary.Hit]) -> [Diary.Hit] {
        var seen: Set<String> = []
        return pages.filter { seen.insert($0.title.lowercased() + "|" + $0.host).inserted }
    }

    /// The candidates with the reader's pick first.
    static func ordered<T>(_ list: [T], first: String?, id: (T) -> String) -> [T] {
        guard let first, let index = list.firstIndex(where: { id($0) == first }) else { return list }
        var out = list
        out.insert(out.remove(at: index), at: 0)
        return out
    }

    private static func pickTab(_ reading: Reading) -> Tab? {
        reading.found.tabs.first { $0.id.uuidString == reading.picks["tab"] } ?? reading.found.tabs.first
    }

    private static func one(_ title: String, _ site: String, _ symbol: String, _ button: String,
                            act: @escaping @MainActor (Browser) -> Void) -> FieldRequest {
        FieldRequest(title: title, site: site, symbol: symbol, tint: .systemPurple, route: .yab, fields: [], button: button, act: .perform(act))
    }

    private static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(AppDates.locale))
    }

    // MARK: finding

    private static func tab(_ browser: Browser, _ tab: Tab) -> FieldRequest {
        FieldRequest(title: tab.title.isEmpty ? (tab.address?.host() ?? "Tab") : tab.title, site: tab.address?.host() ?? "",
                     symbol: "macwindow", tint: .systemPurple, route: .yab,
                     fields: [Field(label: "Site", value: tab.address?.host() ?? "", source: "open tabs"),
                              Field(label: "Last seen", value: ago(tab.touched), source: "open tabs")],
                     button: "Switch to Tab", act: .perform { $0.select(tab) })
            .with(.tabs(closing: [], kept: [tab]))
    }

    private static func page(_ browser: Browser, _ hit: Diary.Hit) -> FieldRequest {
        let open = browser.tabs.first { $0.address?.absoluteString == hit.url }
        var fields = [Field(label: "Was", value: hit.at.englishFormatted(date: .abbreviated, time: .shortened), source: "history")]
        if let passage = hit.passage { fields.append(Field(label: "Found", value: "\u{201C}\(passage.prefix(140))\u{201D}", source: "page text")) }
        fields.append(Field(label: "Site", value: hit.host, source: open == nil ? "history" : "open now"))
        let url = URL(string: hit.url)
        return FieldRequest(title: hit.title.isEmpty ? hit.host : hit.title, site: hit.host, symbol: "clock.arrow.circlepath",
                            tint: .systemBlue, route: .yab, fields: fields, button: open == nil ? "Open" : "Switch to Tab",
                            act: .perform { browser in
                                if let open { browser.select(open) } else if let url { _ = browser.open(url, foreground: true) }
                            },
                            picture: FileManager.default.fileExists(atPath: Diary.shot(hit.key).path) ? Diary.shot(hit.key) : nil)
            .with(.page(hit, picture: FileManager.default.fileExists(atPath: Diary.shot(hit.key).path) ? Diary.shot(hit.key) : nil))
    }

    private static func thread(_ row: MailDesk.Row) -> FieldRequest {
        FieldRequest(title: row.subject.isEmpty ? "(no subject)" : row.subject, site: "Mail · " + row.who, symbol: "envelope",
                     tint: .systemRed, route: .yab,
                     fields: [Field(label: "From", value: row.whoFull.isEmpty ? row.who : row.whoFull, source: "mail"),
                              Field(label: "When", value: row.at.englishFormatted(date: .abbreviated, time: .shortened), source: "mail"),
                              Field(label: "Says", value: String(row.line.prefix(140)), source: "mail")],
                     button: "Open in Mail", act: .perform { browser in
                         browser.showMail()
                         MailDesk.shared.openThread(account: row.account, thread: row.thread)
                     })
            .with(.mail(row, note: nil))
    }

    private static func searchMail(_ words: String) -> [FieldRequest] {
        let typed = Candidates.content(words)
        let mended = FieldRoles.mended(typed)
        let asked = typed.map { mended[$0] ?? $0 }.joined(separator: " ")
        guard !asked.isEmpty else { return [] }
        return [FieldRequest(title: "Search Mail for \u{201C}\(asked)\u{201D}", site: "Mail", symbol: "magnifyingglass",
                             tint: .systemRed, route: .yab, fields: [], button: "Search Mail", act: .perform { browser in
                                 browser.showMail()
                                 MailSearch.shared.apply(words: asked, who: nil)
                                 MailDesk.shared.searchAll()
                             })]
    }

    private static func file(_ browser: Browser, _ keep: Keep) -> FieldRequest {
        var fields = [Field(label: "When", value: keep.date.englishFormatted(date: .abbreviated, time: .shortened), source: "downloads")]
        if let from = keep.page?.host() ?? keep.source?.host() { fields.append(Field(label: "From", value: from, source: "downloads")) }
        fields.append(Field(label: "Where", value: (keep.path as NSString).deletingLastPathComponent, source: "downloads"))
        return FieldRequest(title: keep.name, site: "Downloads", symbol: "arrow.down.circle", tint: .systemBlue, route: .yab,
                            fields: fields, button: "Open", act: .perform { $0.loot.open(keep) })
            .with(.file(keep))
    }

    private static func clip(_ clip: Clips.Clip) -> FieldRequest {
        let link = clip.kind == .link ? URL(string: clip.text) : nil
        return FieldRequest(title: clip.title, site: "Clipboard History", symbol: "clipboard", tint: .systemGray, route: .yab,
                            fields: [Field(label: "Copied", value: ago(clip.last) + (clip.app.map { " in " + $0 } ?? ""), source: "clipboard"),
                                     Field(label: "Text", value: String(clip.text.prefix(160)), source: "clipboard")],
                            button: link == nil ? "Paste" : "Open Link",
                            act: .perform { browser in
                                if let link { _ = browser.open(link, foreground: true) } else { browser.paste(clip) }
                            })
    }

    private static func chat(_ chat: Chat) -> FieldRequest {
        FieldRequest(title: chat.title, site: "Answer", symbol: "agent.face", tint: .systemPurple, route: .yab,
                     fields: [Field(label: "When", value: ago(chat.updated), source: "chats"),
                              Field(label: "Says", value: String(chat.preview.prefix(160)), source: "chats")],
                     button: "Open Answer", act: .perform { $0.showChat(chat.id) })
            .with(.answer(String(chat.preview.prefix(400))))
    }

    // MARK: Yab's own

    /// The open tabs the words' site or words name.
    private static func named(_ browser: Browser, _ reading: Reading, _ words: String) -> [Tab] {
        let content = Candidates.content(words).filter { !["close", "move", "youtube's"].contains($0) }
        return browser.tabs.filter { tab in
            guard !tab.isBlank, tab.pin == nil else { return false }
            let host = tab.address?.host()?.lowercased() ?? ""
            if let site = reading.host, host.hasSuffix(site) || site.hasSuffix(host) { return true }
            return content.contains { host.contains($0) || tab.title.lowercased().contains($0) }
        }
    }

    private static func list(_ tabs: [Tab]) -> [Field] {
        tabs.prefix(6).map { Field(label: "Tab", value: $0.title, source: $0.address?.host() ?? "") }
            + (tabs.count > 6 ? [Field(label: "", value: "and \(tabs.count - 6) more", source: "")] : [])
    }

    private static func closeTabs(_ browser: Browser, _ reading: Reading, _ words: String) -> [FieldRequest] {
        let going = named(browser, reading, words)
        guard !going.isEmpty else { return [] }
        let site = reading.host.map(Address.siteName) ?? "matching"
        return [FieldRequest(title: "Close \(going.count) \(site) tab\(going.count == 1 ? "" : "s")", site: "This window", symbol: "xmark.square",
                             tint: .systemPurple, route: .yab, fields: list(going), button: "Close \(going.count) Tab\(going.count == 1 ? "" : "s")",
                             act: .perform { browser in
                                 browser.shut(going)
                                 browser.toaster.pop("Closed \(going.count) tab\(going.count == 1 ? "" : "s")", mark: "xmark.square", undo: { browser.reopen() })
                             }).with(.tabs(closing: going, kept: []))]
    }

    private static func moveTabs(_ browser: Browser, _ reading: Reading, _ words: String) -> [FieldRequest] {
        // A folder of yours named: it goes whole, its folders with it.
        if let target = reading.found.spaces.first(where: { $0.id.uuidString == reading.picks["space"] }), target.id != browser.spaceID,
           let nest = browser.nests.filter({ $0.name.count > 1 && words.localizedCaseInsensitiveContains($0.name) }).max(by: { $0.name.count < $1.name.count }) {
            let tabs = browser.tabs(in: nest)
            var fields = list(tabs)
            fields.insert(Field(label: "Folder", value: nest.name, source: "yours"), at: 0)
            fields.insert(Field(label: "To", value: target.name, source: "spaces"), at: 0)
            return [FieldRequest(title: "Move \(nest.name) to \(target.name)", site: "Spaces", symbol: "folder", tint: .systemPurple, route: .yab,
                                 fields: fields, button: "Move", act: .perform { $0.moveFolder(nest, to: target.id) }).with(.moving(tabs, to: target.name))]
        }
        let going = named(browser, reading, words)
        guard !going.isEmpty, let target = reading.found.spaces.first(where: { $0.id.uuidString == reading.picks["space"] }),
              target.id != browser.spaceID else { return [] }
        var fields = list(going)
        fields.insert(Field(label: "To", value: target.name, source: "spaces"), at: 0)
        return [FieldRequest(title: "Move \(going.count) tab\(going.count == 1 ? "" : "s") to \(target.name)", site: "Spaces",
                             symbol: "rectangle.stack", tint: .systemPurple, route: .yab, fields: fields, button: "Move",
                             act: .perform { $0.moveTabs(going, to: target.id) }).with(.moving(going, to: target.name))]
    }

    private static func split(_ browser: Browser, _ reading: Reading) -> [FieldRequest] {
        let tabs = reading.found.tabs
        guard let first = tabs.first(where: { $0.id.uuidString == reading.picks["tab"] }),
              let second = tabs.first(where: { $0.id.uuidString == reading.picks["other_tab"] }), first !== second,
              browser.canCarry(second, beside: first) else { return [] }
        return [FieldRequest(title: "\(first.title) | \(second.title)", site: "Split View", symbol: "rectangle.split.2x1", tint: .systemPurple,
                             route: .yab, fields: [Field(label: "Left", value: first.title, source: "open tabs"),
                                                   Field(label: "Right", value: second.title, source: "open tabs")],
                             button: "Open in Split View", act: .perform { browser in
                                 browser.select(first)
                                 browser.split(second, with: first)
                             })]
    }

    private static func space(_ browser: Browser, _ reading: Reading) -> [FieldRequest] {
        guard let target = reading.found.spaces.first(where: { $0.id.uuidString == reading.picks["space"] }), target.id != browser.spaceID
        else { return [] }
        return [one("Space: \(target.name)", "Spaces", "rectangle.stack", "Switch Space") { $0.switchSpace(to: target.id) }]
    }

    private static func setting(_ browser: Browser, _ reading: Reading) -> [FieldRequest] {
        guard let label = reading.picks["setting"], let chosen = reading.found.settings.first(where: { $0.label == label }),
              let setting = NativeSetting.all.first(where: { $0.id == chosen.id }) else { return [] }
        // Already so: said, so the words don't look unread.
        if setting.read(browser.prefs) == chosen.value {
            return [FieldRequest(title: chosen.label, site: "Already set", symbol: "checkmark", tint: .systemPurple, route: .yab,
                                 fields: [], button: "Open Settings", act: .perform { SettingsWindow.shared.show(for: $0) })]
        }
        return [one(chosen.label, "Settings", "gearshape", "Set") { browser in try? setting.write(browser.prefs, chosen.value) }]
    }

    private static func zoom(_ browser: Browser, _ words: String) -> [FieldRequest] {
        guard let tab = browser.active, let host = tab.address?.host() else { return [] }
        let asked = words.range(of: #"\d{2,3}"#, options: .regularExpression).flatMap { Double(words[$0]) }.map { $0 / 100 }
        let smaller = ["smaller", "less"].contains { words.lowercased().contains($0) }
        let value = asked ?? (smaller ? 0.9 : 1.25)
        return [one("Zoom \(host) to \(Int((value * 100).rounded()))%", "This site", "plus.magnifyingglass", "Zoom") { _ in tab.magnify(to: value) }]
    }

    private static func archiveTabs(_ browser: Browser) -> [FieldRequest] {
        let week = Date().addingTimeInterval(-7 * 86400)
        let old = browser.tabs.filter { $0.pin == nil && !$0.isBlank && $0.touched < week && $0 !== browser.active }
        guard !old.isEmpty else { return [] }
        return [FieldRequest(title: "Put away \(old.count) tabs not opened for a week", site: "This window", symbol: "archivebox",
                             tint: .systemPurple, route: .yab, fields: list(old), button: "Put Away \(old.count)",
                             act: .perform { browser in
                                 guard let batch = browser.putAway(old) else { return }
                                 browser.tidied.append(batch)
                                 browser.tidier.show(old.count, batch: batch)
                             }).with(.tabs(closing: old, kept: []))]
    }

    private static func sitePermission(_ reading: Reading, _ words: String) -> [FieldRequest] {
        guard let host = reading.host else { return [] }
        let lower = words.lowercased()
        let microphone = lower.contains("mic")
        let kind: PageCapture = microphone ? .microphone : .camera
        let what = microphone ? "Microphone" : "Camera"
        let origin = "https://" + host
        return [one("\(what) for \(host): Allow", "Site settings", microphone ? "mic" : "camera", "Allow") { browser in
            Store.settings.set(true, forKey: Browser.captureKey(origin, kind))
            browser.toaster.pop("\(what) allowed for \(host)", mark: microphone ? "mic" : "camera")
        }]
    }

    // MARK: mail

    private static func mailAct(_ kind: String, _ reading: Reading, _ words: String, _ browser: Browser) -> [FieldRequest] {
        guard let row = reading.found.threads.first(where: { $0.id == reading.picks["thread"] }) ?? reading.found.threads.first else { return [] }
        let open: @MainActor (Browser) -> Void = { browser in
            browser.showMail()
            MailDesk.shared.openThread(account: row.account, thread: row.thread)
        }
        let after = RequestReader.saidAfter(words)
        let when = RequestReader.day(words.lowercased())
        var fields = [Field(label: "Thread", value: row.subject, source: "mail · " + row.who)]
        let title: String, button: String, symbol: String, act: @MainActor (Browser) -> Void
        var route = FieldRequest.Route.api
        switch kind {
        case "reply":
            if let after { fields.append(Field(label: "Says", value: after, source: "your words")) }
            title = "Reply to \(row.who)"; button = "Reply in Mail"; symbol = "arrowshape.turn.up.left"
            act = { browser in
                browser.showMail()
                MailDesk.shared.openThread(account: row.account, thread: row.thread, reply: true)
                if let after { MailDesk.shared.reply(after) }
            }
        case "forward":
            title = "Forward \u{201C}\(row.subject)\u{201D}"; button = "Forward in Mail"; symbol = "arrowshape.turn.up.right"
            act = { browser in
                browser.showMail()
                MailDesk.shared.openThread(account: row.account, thread: row.thread, forward: true)
            }
        case "remind":
            let at = when ?? Date().addingTimeInterval(3 * 86400)
            fields.append(Field(label: "Until", value: at.englishFormatted(date: .abbreviated, time: .shortened), source: when == nil ? "in 3 days" : "your words"))
            title = "Remind if \(row.who) is quiet"; button = "Set Reminder"; symbol = "bell"
            act = { browser in open(browser); MailDesk.shared.remindNoReply(at: at) }
        case "snooze":
            let at = when ?? Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date().addingTimeInterval(86400))!
            fields.append(Field(label: "Until", value: at.englishFormatted(date: .abbreviated, time: .shortened), source: when == nil ? "tomorrow" : "your words"))
            title = "Snooze \u{201C}\(row.subject)\u{201D}"; button = "Snooze"; symbol = "moon"
            act = { _ in MailDesk.shared.snooze(account: row.account, thread: row.thread, at: at, why: "Snoozed from the field") }
        case "unsubscribe":
            fields.append(Field(label: "Undo", value: "not possible once done", source: "", state: .check))
            title = "Unsubscribe from \(row.who)"; button = "Unsubscribe"; symbol = "envelope.badge.minus"
            act = { browser in open(browser); MailDesk.shared.unsubscribe() }
        case "archive_mail":
            title = "Archive \u{201C}\(row.subject)\u{201D}"; button = "Archive"; symbol = "archivebox"
            act = { _ in MailDesk.shared.done(account: row.account, thread: row.thread) }
        case "invite_answer":
            title = "Accept \u{201C}\(row.subject)\u{201D}"; button = "Accept"; symbol = "calendar.badge.checkmark"
            act = { browser in open(browser); MailDesk.shared.answer(.accepted) }
        default: // track: the shipping mail, read back
            fields.append(Field(label: "Latest", value: String(row.line.prefix(160)), source: "mail"))
            title = row.subject; button = "Open in Mail"; symbol = "shippingbox"; route = .ask
            act = open
        }
        let note: String? = switch kind {
        case "snooze": "Back in your inbox " + (when ?? Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date().addingTimeInterval(86400))!)
            .formatted(AppDates.dateTime.weekday(.wide).month().day().hour().minute())
        case "remind": "Reminds you " + (when ?? Date().addingTimeInterval(3 * 86400)).formatted(AppDates.dateTime.weekday(.wide).month().day()) + " if no reply comes"
        case "reply": after.map { "Your reply: \u{201C}\($0)\u{201D}" }
        case "unsubscribe": "Stops mail from \(row.who). It can't be undone."
        case "invite_answer": "Accepts, and \(row.who) gets the reply"
        default: nil
        }
        return [FieldRequest(title: title, site: "Mail", symbol: symbol, tint: .systemRed, route: route, fields: fields, button: button, act: .perform(act))
            .with(.mail(row, note: note))]
    }

    private static func sendFile(_ browser: Browser, _ reading: Reading) -> [FieldRequest] {
        guard let person = reading.person,
              let keep = reading.found.files.first(where: { $0.path == reading.picks["file"] }) ?? reading.found.files.first else { return [] }
        return [FieldRequest(title: "Send \(keep.name) to \(person.said)", site: "Mail", symbol: "paperclip", tint: .systemRed, route: .api,
                             fields: [Field(label: "To", value: person.said, source: "mail · \(person.threads) threads"),
                                      Field(label: "File", value: keep.name, source: "downloads"),
                                      Field(label: "Body", value: "yours to write, or ⌘J drafts it", state: .choose)],
                             button: "Write in Mail", act: .perform { browser in
                                 browser.showMail()
                                 var draft = MailDesk.fresh(person.address.contains("@") ? MailCenter.shared.accounts.first ?? "" : "")
                                 draft.to = person.address
                                 MailDesk.shared.compose(draft)
                                 MailDesk.shared.attach([keep.url])
                             }).with(.file(keep))]
    }

    // MARK: calendar

    private static func focus(_ words: String) -> [FieldRequest] {
        let lower = words.lowercased()
        let hours = lower.contains("two") || lower.contains("2 h") ? 2.0
            : lower.contains("three") ? 3.0 : 1.0
        let day = RequestReader.day(lower) ?? Date().addingTimeInterval(86400)
        let start = RequestReader.when(lower) ?? Calendar.current.date(bySettingHour: lower.contains("afternoon") ? 14 : 9,
                                                                      minute: 0, second: 0, of: day)!
        let end = start.addingTimeInterval(hours * 3600)
        return [FieldRequest(title: "Focus, \(start.formatted(AppDates.dateTime.weekday(.abbreviated).hour().minute()))–\(end.englishFormatted(date: .omitted, time: .shortened))",
                             site: "Calendar on this Mac", symbol: "calendar.badge.plus", tint: .systemBlue, route: .api,
                             fields: [Field(label: "When", value: start.englishFormatted(date: .abbreviated, time: .shortened) + ", \(Int(hours)) h", source: "your words"),
                                      Field(label: "Guests", value: "none", source: "")],
                             button: "Add Event", act: .perform { browser in
                                 Task { @MainActor in
                                     let store = EKEventStore()
                                     guard (try? await Meetings.requestAccess(store)) == true else { return }
                                     let event = EKEvent(eventStore: store)
                                     event.title = "Focus"
                                     event.startDate = start
                                     event.endDate = end
                                     event.calendar = store.defaultCalendarForNewEvents
                                     guard (try? store.save(event, span: .thisEvent)) != nil else { return }
                                     browser.toaster.pop("Focus added to your calendar", mark: "calendar", undo: { try? store.remove(event, span: .thisEvent) })
                                 }
                             }).with(.day(person: nil, label: "Focus", start: start))]
    }

    private static func join() -> [FieldRequest] {
        guard let meeting = Meetings.shared.next() else { return [] }
        return [FieldRequest(title: "Join \u{201C}\(meeting.title)\u{201D}", site: meeting.link?.host() ?? "Calendar", symbol: "video", tint: .systemGreen,
                             route: .yab, fields: [], button: "Join", act: .perform { $0.joinMeeting(meeting) })]
    }

    private static func free(_ reading: Reading, _ browser: Browser) -> [FieldRequest] {
        let slots = FreeSlots.text(browser)
        let who = reading.person.map { " with \($0.said)" } ?? ""
        return [FieldRequest(title: "Free times\(who)", site: "Your calendar", symbol: "calendar", tint: .systemBlue, route: .ask,
                             fields: [Field(label: "Free", value: slots ?? "reading your calendar…", source: "calendar"),
                                      Field(label: "Theirs", value: reading.person == nil ? "" : "only if shared with you", source: "", state: .check)],
                             button: "Copy Times", act: .copy(slots ?? "")).with(.answer(slots ?? "Reading your calendar…"))]
    }

    // MARK: sites

    private static func linear(_ words: String) -> [FieldRequest] {
        let title = RequestReader.saidAfter(words) ?? words
        let workspace = History.current.visits(since: .distantPast)
            .compactMap { URL(string: $0.url) }.first { $0.host() == "linear.app" }?.pathComponents.dropFirst().first
        var url = URLComponents(string: "https://linear.app/" + (workspace.map { $0 + "/" } ?? "") + "new")!
        url.queryItems = [URLQueryItem(name: "title", value: title)]
        return [FieldRequest(title: "New Linear issue", site: "Linear", symbol: "square.and.pencil", tint: .systemIndigo, route: .link,
                             fields: [Field(label: "Title", value: title, source: "your words"),
                                      Field(label: "Workspace", value: workspace ?? "yours", source: "history")],
                             button: "Open in Linear", act: .open(url.url!))
            .with(.form(site: "Linear", tint: .systemIndigo, team: workspace, title: title, lines: [], button: "Create issue"))]
    }

    private static func newDoc(_ words: String) -> [FieldRequest] {
        let lower = words.lowercased()
        let (name, link) = lower.contains("sheet") ? ("Sheet", "https://sheets.new")
            : lower.contains("slide") ? ("Slides", "https://slides.new") : ("Doc", "https://docs.new")
        return [FieldRequest(title: "New Google \(name)", site: "Google", symbol: "doc.badge.plus", tint: .systemBlue, route: .link,
                             fields: [], button: "Open", act: .open(URL(string: link)!))]
    }

    private static func post(_ words: String) -> [FieldRequest] {
        let text = RequestReader.saidAfter(words) ?? words
        var url = URLComponents(string: "https://x.com/intent/post")!
        url.queryItems = [URLQueryItem(name: "text", value: text)]
        return [FieldRequest(title: "New post on X", site: "X", symbol: "square.and.pencil", tint: .labelColor, route: .link,
                             fields: [Field(label: "Text", value: text, source: "your words, edit there")],
                             button: "Open Composer", act: .open(url.url!))
            .with(.form(site: "X", tint: .labelColor, team: nil, title: text, lines: [], button: "Post"))]
    }

    // MARK: the agent, answers, memory

    private static func agentTask(_ kind: String, _ reading: Reading, _ words: String) -> [FieldRequest] {
        let site = reading.host.map(Address.siteName)
        var fields = [Field(label: "Asked", value: words, source: "your words")]
        if let site, let host = reading.host { fields.append(Field(label: "Where", value: site, source: "you went there \(History.current.count(host: host)) times")) }
        let (title, button, plan): (String, String, [String])
        switch kind {
        case "pay":
            if let thread = reading.found.threads.first(where: { $0.id == reading.picks["thread"] }) {
                fields.append(Field(label: "Invoice", value: thread.subject, source: "mail · " + thread.who))
            }
            fields.append(Field(label: "Pay", value: "the last button is yours", state: .choose))
            title = "Pay" + (site.map { " on \($0)" } ?? ""); button = "Go to Payment"
            plan = ["Open the invoice's page", "Fill what is known", "Stop on Pay: that one is yours"]
        case "spend":
            fields.append(Field(label: "Receipts", value: "\(reading.found.threads.count) found in your mail", source: "mail"))
            title = "Add up" + (site.map { " \($0)" } ?? "") + " receipts"; button = "Add Up"
            plan = ["Read the receipts in your mail", "Add them up by month", "Answer with the sum and the list"]
        default:
            fields.append(Field(label: "Prices", value: "will check on the sites", state: .check))
            title = "Compare: " + words; button = "Run Task"
            plan = ["Look on the sites that sell it", "A table of the best", "Book or buy nothing"]
        }
        let note = (reading.host.map { "Do it on \($0). " } ?? "") + "Ask me only to sign in, to pay, or if the words can be read two ways; stop before anything that pays."
        let invoice = kind == "pay" ? reading.found.threads.first(where: { $0.id == reading.picks["thread"] }) : nil
        return [FieldRequest(title: title, site: site ?? "the web", symbol: "agent.face", tint: .systemPurple, route: .agent,
                             fields: fields, plan: plan, button: button, act: .task(words + "\n\n" + note), taskNote: note)
            .with(.steps(mail: invoice, steps: plan, yours: kind == "pay" ? plan.count - 1 : nil))]
    }

    private static func who(_ reading: Reading) -> [FieldRequest] {
        guard let person = reading.person else { return [] }
        let latest = reading.found.threads.first
        var fields = [Field(label: "Mail", value: "\(person.threads) threads · \(person.address)", source: "mail")]
        if let latest { fields.append(Field(label: "Last", value: "\u{201C}\(latest.subject)\u{201D}, " + ago(latest.at), source: "mail")) }
        return [FieldRequest(title: person.said, site: "Mail and memory", symbol: "person.crop.circle", tint: .systemGray, route: .ask,
                             fields: fields, button: "Copy", act: .copy("\(person.said) <\(person.address)>"))
            .with(.person(person, last: latest))]
    }

    private static func remember(_ reading: Reading, _ words: String) -> [FieldRequest] {
        guard let fact = RequestReader.saidAfter(words) ?? Optional(words) else { return [] }
        let page = reading.person.map { "people/" + $0.said.lowercased().replacingOccurrences(of: " ", with: "-") } ?? "MEMORY"
        return [FieldRequest(title: "Remember: \(fact)", site: reading.person?.said ?? "Memory", symbol: "brain", tint: .systemPurple, route: .yab,
                             fields: [Field(label: "In", value: page, source: "memory")], button: "Remember",
                             act: .perform { browser in
                                 let old = Memory.read(page)
                                 let error = Memory.write(page, text: (old.map { $0 + "\n" } ?? "") + "- " + fact, replacing: old)
                                 browser.toaster.pop(error == nil ? "Remembered" : "Couldn't remember: \(error!)", mark: "brain")
                             }).with(.memory(page: page, line: fact))]
    }
}

/// Free times in the next working days, read once and kept a minute.
@MainActor
enum FreeSlots {
    private static var said: (String, Date)?
    private static var reading = false

    static func text(_ browser: Browser) -> String? {
        if let said, Date().timeIntervalSince(said.1) < 60 { return said.0 }
        guard !reading else { return nil }
        reading = true
        Task { @MainActor [weak browser] in
            let now = Date()
            let busy = await Meetings.shared.busy(from: now, to: now.addingTimeInterval(7 * 86400)) ?? []
            let slots = MailSlots.suggested(MailSlots.free(busy: busy, from: now), now: now)
            said = (MailSlots.text(slots, now: now), Date())
            reading = false
            if let browser, case .request = browser.query.offers.first?.kind { browser.typed = browser.typed }
        }
        return nil
    }
}

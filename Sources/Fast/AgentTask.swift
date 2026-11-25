import AppKit
import SwiftUI

// A task for the agent in your own words (work/visualizations, "Agent Tasks
// in Words"). Three ways in, one line:
//
// ⌘J on a page raises the task line where the dock lives, or, as Settings ›
// AI › Agents may say, a chat about the page in the column (askInChat); ⌘J
// again on the line takes what it holds there, not sent. The line: what the agent
// will see lies over it as pills (this page, what is selected, tabs and
// files added with + Add), the site's own actions under it, and Run.
// The agent decides where the work belongs: what is
// about this page it does in this tab, as an action does; what needs other
// pages, in tabs of its own, and the task is followed in the chat column
// from the first one it opens (wentElsewhere).
//
// ⌘T takes a phrase with a verb as a task: "Task for Claude" is its first
// row, and ⇥ trades it with the search. Under any words the field offers
// three rows, the search, Ask (answered in the field, FieldAnswer) and the
// task, whichever the words read as on top. The selection's list ends in "Ask
// about this…", the same line with the words in it.
//
// A task in tabs of its own gathers the agent's tabs in a folder, which
// says how far along it is in words ("4 of 10", "Needs you", "Done"). Its
// chat in the column says what it is doing, then the answer: the pick, why,
// the comparison with each row's source, what was skipped; its field asks
// more. Done while you are elsewhere, the corner says so once, Show opens
// the chat, and Now keeps a row with the pick itself until it is opened.

/// Something the agent is given to see with the words.
struct TaskContext: Identifiable, Equatable {
    enum Kind: Equatable { case page, selection, tab, file, mail, item }
    let kind: Kind
    let title: String
    var url: URL?
    var tab: UUID?
    var text: String?
    /// What mail showed: an email, or a list (MailChat).
    var mail: MailRef?
    /// The thing on the page the pointer was on (SiteItems).
    var item: SiteItem?

    var id: String {
        switch kind {
        case .page: return "page"
        case .selection: return "selection"
        case .tab: return "tab:" + (tab?.uuidString ?? title)
        case .file: return "file:" + (url?.path ?? title)
        case .mail: return "mail:" + (mail?.id ?? title)
        case .item: return "item:" + (item?.key ?? title)
        }
    }

    static func mail(_ ref: MailRef) -> TaskContext {
        TaskContext(kind: .mail, title: ref.chip, mail: ref)
    }

    @MainActor static func page(_ tab: Tab) -> TaskContext {
        TaskContext(kind: .page, title: "This page", url: tab.address, tab: tab.id)
    }

    @MainActor static func tab(_ tab: Tab) -> TaskContext {
        TaskContext(kind: .tab, title: tab.label, url: tab.address, tab: tab.id)
    }

    static func selection(_ text: String) -> TaskContext {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let short = line.count > 36 ? String(line.prefix(34)).trimmingCharacters(in: .whitespaces) + "…" : line
        return TaskContext(kind: .selection, title: "“\(short)”", text: text)
    }

    static func file(_ url: URL) -> TaskContext {
        TaskContext(kind: .file, title: url.lastPathComponent, url: url)
    }

    static func item(_ item: SiteItem) -> TaskContext {
        TaskContext(kind: .item, title: item.chip, url: URL(string: item.link), text: item.sentence, item: item)
    }
}

// MARK: - the words

enum TaskWords {
    enum Strength { case strong, weak }

    /// An explicit address after Open is navigation, including in Ask follow-ups.
    /// Only the person's submitted words reach this parser, never model output.
    static func openingURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:please[,\s]+)?(?:(?:can|could)\s+you\s+)?open(?:\s+(?:a|the|new|website|site|page|tab|in))*\s+(\S+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let addressRange = Range(result.range(at: 1), in: text), let tailRange = Range(result.range(at: 2), in: text) else { return nil }
        let token = String(text[addressRange])
        let tail = text[tailRange].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard tail.isEmpty || token.hasSuffix(":") || tail.hasPrefix(":")
                || ["in a new tab", "in new tab", "please"].contains(tail) else { return nil }
        let address = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»<>"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        guard let url = Address.url(from: address, names: false), let host = url.host(), !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Route short native requests to an acting task.
    /// Explanations and proposals stay answers, even when they name a setting.
    static func nativeRequest(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !text.contains("://") else { return false }
        if ["dark mode", "light mode"].contains(text) { return true }
        if undoRequest(text) { return true }
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        let verbs: Set<String> = ["turn", "set", "enable", "disable", "change", "add", "connect", "reconnect", "disconnect", "create", "rename", "move", "pin", "unpin", "hide", "show", "make", "keep"]
        let asking = ["can", "could"].contains(first)
        guard verbs.contains(first) || (asking && words.dropFirst().contains(where: { verbs.contains($0) })) else { return false }
        // Every setting native_apply can change (NativeSetting.all), by the
        // words its row in Settings uses: one missing here was answered with
        // the steps to change it by hand (feedback #84).
        let subjects = ["profile", "sign-ins", "sign ins", "ctrl-tab", "ctrl tab", "recent tabs", "switcher", "theme", "dark", "light", "sidebar", "space", "spaces", "tabs", "tab", "font", "zoom", "gmail", "mail", "bookmark",
                        "setting", "search engine", "address bar", "full url", "background", "grain", "transparen", "peek", "player",
                        "picture in picture", "float", "developer", "devtools", "quit", "animation",
                        // Small Window and Air Traffic Control (links.*).
                        "small window", "window", "link", "domain", "site", "open in", "opens in",
                        // A site's own (site.*) and Reading Mode's.
                        "awake", "sleep", "chromium", "webkit", "reading", "reader", "tidy", "preview",
                        // Energy Saver (EnergySaver), as Chromium and macOS name it.
                        "energy saver", "battery saver", "power saving", "battery"]
        return subjects.contains { text.contains($0) }
    }

    static func undoRequest(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "undo" || text.hasPrefix("undo the last")
    }

    /// The verbs a task starts with, in the words people type.
    static let verbs: Set<String> = [
        "find", "compare", "book", "collect", "gather", "research", "summarize", "summarise", "check", "track",
        "list", "look", "get", "buy", "order", "reserve", "schedule", "plan", "write", "draft", "reply",
        "answer", "email", "make", "build", "pick", "choose", "recommend", "tell", "explain", "translate",
        "fill", "sign", "cancel", "unsubscribe", "watch", "remind", "download", "save", "organize", "sort",
        "clean", "review", "read", "go", "open", "show", "help", "figure", "work", "fix", "extract", "copy",
        "rewrite", "shorten", "turn", "convert", "calculate", "estimate", "monitor", "notify", "send", "post",
        "create", "add", "remove", "update", "change", "move", "export", "print",
    ]

    /// Whether the words read as a thing to do rather than an address or a
    /// search: a verb first and three words or more, strongly; five words
    /// or more without one, weakly, the search staying first then, as
    /// taking a search for a task costs more than the other way round.
    static func strength(_ text: String) -> Strength? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if nativeRequest(trimmed) { return .strong }
        var words = trimmed.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        // An address and then what to do with it ("https://… save this page
        // as pdf"): the words after it decide, as the task opens it.
        if words.count >= 4, words[0].contains("://"), !words.dropFirst().contains(where: { $0.contains("://") }) {
            words.removeFirst()
            let first = words[0].trimmingCharacters(in: .punctuationCharacters)
            return verbs.contains(first) ? .strong : nil
        }
        guard words.count >= 3, !trimmed.contains("://") else { return nil }
        // A word with a domain's dot in it is an address, or a site's name.
        if words.contains(where: { $0.range(of: #"^[a-z0-9-]+\.[a-z]{2,}(/.*)?$"#, options: .regularExpression) != nil }) { return nil }
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        if verbs.contains(first) { return .strong }
        return words.count >= 5 ? .weak : nil
    }

    /// The words a question starts with.
    static let asking: Set<String> = [
        "how", "what", "why", "who", "whom", "whose", "which", "when", "where", "is", "are", "was", "were",
        "can", "could", "does", "do", "did", "should", "would", "will", "whats", "what's", "how's",
    ]

    /// A question word first, with three words or a question mark. A mark
    /// alone or a how-to phrase still means a search, as on the iPhone.
    static func question(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard words.count >= 2, !trimmed.contains("://") else { return false }
        guard asking.contains(words[0].trimmingCharacters(in: .punctuationCharacters)),
              words[1].trimmingCharacters(in: .punctuationCharacters) != "to" else { return false }
        return words.count >= 3 || trimmed.hasSuffix("?")
    }

    /// Words that ask for something written into the page: its answer is
    /// a draft there, not a card beside it.
    static func writes(_ text: String) -> Bool {
        let first = text.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
        return ["reply", "answer", "respond", "write", "draft", "comment", "compose", "fill"].contains(first)
    }
}

// MARK: - starting one

extension Agents {
    /// Asked on a page to change the site for good ("hide Shorts", "always
    /// wider"): the boosts skill says how, so the agent reads it first.
    static let boostHint = "To make a site look or work differently every time, read skill('boosts') first."

    /// Whether an agent is there to ask at all.
    /// Gemini counts once signed in: its CLI alone can't take anything.
    /// Where a task would find it (AgentLaunch.here): files alone don't
    /// rule out a connected Claude or Codex on the login shell's PATH.
    static var installed: Bool {
        ["claude", "codex", "cursor"].contains { AgentLaunch.here($0) == true }
            || (GeminiSupport.toolsProven && GeminiAccount.shared.ready)
    }

    /// Whether an agent can take a task now: installed and signed in, to a
    /// plan or with a key. What isn't true of it isn't shown: no Ask rows,
    /// no buttons on sites, no chat to start; ⌘J says where to connect one.
    /// With AI in Yab Off (AIUse) none is: nothing goes to a model.
    static var ready: Bool {
        if let assumed = assumedInTests, Store.testing { return AIUse.allows(.asked) && assumed }
        return ready(asked: AIUse.allows(.asked), setup: .shared)
    }

    /// `ready` for a setup: AI asked for, and a task on a connected plan
    /// would start (AgentSetupModel.canTakeTasks, AgentLaunch).
    static func ready(asked: Bool, setup: AgentSetupModel) -> Bool {
        asked && setup.canTakeTasks()
    }

    /// A unit test's say on whether an agent is connected, for what only
    /// shows with one (FieldSelectionRowsTests); nil asks the Mac. Never
    /// read outside a test run.
    static var assumedInTests: Bool?

    /// Whether a plan was connected in Yab (Settings › AI's Connect, or
    /// Gemini signed in), not only signed in on this Mac by another app:
    /// the ChatGPT and Codex apps sign in a Codex Yab can use, so its rows
    /// show, but words lead to the search until a plan is connected here
    /// (feedback #280).
    static var connected: Bool {
        guard AIUse.allows(.asked) else { return false }
        if Store.testing, let assumed = connectedInTests ?? assumedInTests { return assumed }
        return AgentSetupModel.shared.anyConnected
    }

    /// A unit test's say on `connected`; nil follows assumedInTests.
    static var connectedInTests: Bool?

    /// Whose plan a new task goes to, as the rows say it: the Tasks
    /// default's, else yours.
    static var preferredName: String { AgentSetupModel.name(ModelDefaults.shared.pickNow(.tasks).cli) }

    /// Your words, with what you gave it to see. Asked on a page (`on`),
    /// it may work in that tab, or open tabs of its own when the words need
    /// other pages: it decides, and is followed in the column once it does
    /// (wentElsewhere). Asked from anywhere else, in tabs of its own,
    /// gathered in a folder, its answer in its chat, which the caller
    /// brings out if it should show now. `said` is what its chat shows as
    /// your message when the words are Yab's own (Do It's), with
    /// `carrying` over it, and `name` the folder's until the agent names it.
    /// `origin` is the window it was asked in, which everything of it
    /// keeps: its chat, its tabs, its notices (#1009). Nil only for one
    /// asked nowhere in particular (Settings' Connect), which takes the
    /// bound browser as before.
    @discardableResult
    func task(_ words: String, context: [TaskContext], on tab: Tab?, choice: ModelChoice? = nil,
              said: String? = nil, carrying: [String] = [], name: String? = nil, project: String? = nil,
              in origin: Browser? = nil) -> Session? {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let browser = origin ?? self.browser else { return nil }
        // "Every weekday at 10, tell me…": a routine on the tabs it was
        // asked about, not a task now.
        if let (when, rest) = Routines.phrase(words) {
            var tabs = tab.map { [$0] } ?? []
            tabs += context.compactMap { item in item.tab.flatMap(browser.chatTab) }
            Routines.shared.fromWords(rest, when: when, tabs: tabs, in: browser, project: Projects.shared.project(project)?.id)
            return nil
        }
        // On Gemini, chosen or Auto's for your Gemini (no plan with tools
        // here): no tools yet, so the page it was asked on is given as
        // words, and its answer opens in the column.
        let textOnly = (choice?.cli ?? ModelDefaults.shared.pick(.tasks).cli) == "gemini" && !GeminiSupport.toolsProven
        var context = context
        if textOnly, let tab, !tab.shy, !context.contains(.page(tab)) { context.append(.page(tab)) }
        let seen = Agents.given(context, browser: browser) + Agents.spaceLine(browser)
        if let tab, !textOnly {
            let url = tab.address?.absoluteString ?? ""
            let writing = TaskWords.writes(words)
            // Something to write is the page's: a draft in its own field.
            let prompt = writing ? """
            The user is looking at a page in their own tab \(Bench.short(tab)) (\(url)) and asked you to do this \
            there, in their own words: «\(words)». \(seen)Work in that tab; don't open another unless you must, \
            \(Agents.draftEnding)
            """ : """
            The user is looking at a page in their own tab \(Bench.short(tab)) (\(url)) and asked you, in their own \
            words: «\(words)». \(seen)
            Decide where the work belongs. What is about this page itself (reading it, clicking or filling in it) \
            you do in that tab. What needs other pages (finding, comparing, looking things up) you do in tabs of \
            your own: open them with `open`, several at once when you compare. Do not use another user tab \
            just because its URL or domain matches. \(Agents.closeTabsLine)
            \(Agents.boostHint)
            If you open tabs of your own, call `name` right away with two to four words for the task. \
            \(browser.prefs.agentsAsking == .bypass ? Agents.bypassLine : Agents.askFirstLine)
            When the work was on this page, finish with a short plain answer. When it took other pages, finish \
            with the answer in Markdown and nothing else: a first line `# ` with the pick or the result in a few \
            words; one or two sentences on why; and when you compared things, a table whose last column, Source, \
            holds a [site](url) link for each row.
            """
            let session = run(prompt: prompt, cli: choice?.cli, model: choice?.model, effort: choice?.effort, access: "browser", resume: nil,
                              project: Projects.shared.project(project)?.id)
            session.nativeOriginTab = tab.shy ? nil : tab.id
            session.nativeOriginSpace = browser.spaceID
            session.nativeWindowID = browser.windowID ?? BrowserWindows.primaryID
            if TaskWords.undoRequest(words) { session.nativeUndoChange = NativeControl.shared.latestUndoable(in: browser) }
            session.title = TaskLine.title(words)
            session.origin = .here
            session.saying.append(words)
            session.asked = [words]
            if writing { session.draft = Skills.Draft("draft: Draft in the page / Send") }
            // Asked for from the page itself: no "use this tab?" in between.
            tab.allowed.insert(session.id)
            tab.guest = session.id
            // The last answer at the page's foot is this one's to replace.
            tab.answer = nil
            Hints.shared.unoffer(tab.id)
            return session
        }
        // Tabs of yours it was pointed at are the agent's to work in too,
        // for what is about them: it decides, as on the line.
        let pointed = context.compactMap { item in item.kind == .selection ? nil : item.tab }
            .compactMap(browser.chatTab)
        // Words of theirs already given: a question they answer needs no
        // folder's name or tool first, only the answer (PageWords).
        let handed = PageWords.handed && pointed.contains { PageWords.cached($0) != nil }
            ? "\nWhen the words of their tabs given above answer it on their own, just answer from them, in a sentence or a "
                + "few short lines, without `name` or any tool. Otherwise:"
            : ""
        // A Gemini chat has no tools yet: your words and what you gave it
        // to see, without the tabs-and-tools brief it couldn't follow.
        let prompt = textOnly
            ? [seen.trimmingCharacters(in: .whitespacesAndNewlines), words].filter { !$0.isEmpty }.joined(separator: "\n\n")
            : Agents.newTabsPrompt(words, seen: seen, pointed: !pointed.isEmpty, handed: handed,
                                   bypass: browser.prefs.agentsAsking == .bypass)
        let session = run(prompt: prompt, cli: choice?.cli, model: choice?.model, effort: choice?.effort, access: "browser", resume: nil,
                              project: Projects.shared.project(project)?.id)
        // The tab it was pointed at is its target, before the page in front:
        // a chip of a tab other than the one shown is what the words mean.
        session.nativeOriginTab = pointed.first(where: { !$0.shy })?.id ?? browser.chatPage.flatMap { $0.shy ? nil : $0.id }
        session.nativeOriginSpace = browser.spaceID
        session.nativeWindowID = browser.windowID ?? BrowserWindows.primaryID
        if TaskWords.undoRequest(words) { session.nativeUndoChange = NativeControl.shared.latestUndoable(in: browser) }
        session.origin = .newTabs
        session.saying.append(said ?? words)
        if !carrying.isEmpty { session.carrying.append(carrying) }
        session.task = true
        session.asked = [said ?? words]
        session.title = name ?? TaskLine.title(words)
        session.progress = "Starting"
        for tab in pointed { tab.allowed.insert(session.id) }
        // No tabs of its own to follow: the answer is in its chat.
        if textOnly { browser.showChat(session.id) }
        return session
    }

    /// Bypass: the user chose never to be asked, so what they asked for is
    /// done without a question first, as Yab's own cards skip theirs. A
    /// payment is still asked about.
    static let bypassLine = "The user chose Bypass: don't stop to ask before what they asked for sends, books or deletes; do it. Before anything that pays, stop and ask with `ask`."
    /// The user's tabs are theirs to close: only when they ask, through
    /// Yab's own action, so Undo brings them back (docs/agent-asks.md).
    static let closeTabsLine = "When the user asks you to close their tabs (all of a site's, the duplicates, the ones they haven't used in a week), find them in `native_context`'s tabs (`url`, `duplicateOf`, `lastUsed`) and close them with `native_apply` `tabs.close`, all in one call; pinned and kept ones only if they named those. Never ask first, whatever the count (up to 50 per call; split a larger set into calls): closing is undoable. Then answer in plain words, like “Closed 9 YouTube tabs.”, with no list and no Undo of your own: Yab's corner notice and ⌘Z bring them back. `close` is only for tabs you opened."
    static let askFirstLine = "Before anything that pays, sends, books or deletes, stop and ask with `ask`, saying what would happen."

    /// A task in tabs of its own, as it is asked: your words, what it was
    /// given to see, and the answer's form. `pointed`: tabs of yours named.
    /// `handed`: what to do when the tabs' words given answer it alone.
    static func newTabsPrompt(_ words: String, seen: String, pointed: Bool, handed: String = "", bypass: Bool = false) -> String {
        """
        The user asked you in yab, in their own words: «\(words)». \(seen)\(handed)
        Open what you need with `open`, several at once when you compare. It uses tabs of your own even \
        when the same URL or domain is already open. Only inspect or work in an existing user tab when \
        the user explicitly refers to it or gives it as the task's target; a site name or URL alone is \
        not that request. Do not search the user's tabs by domain to choose where to work: their pins \
        and open tabs may hold unfinished work. \(Agents.closeTabsLine) Leave the user's other tabs as they are\(pointed ? ", except the ones named above: read them, and what is about them themselves (clicking or filling in them) do there" : "").
        Right away, call `name` with two to four words for the task. Once you know how many places or steps it \
        takes, call `name` again with `progress` too, like "4 of 10", nothing longer, and again as that moves.
        If the words can be read two ways and that changes the answer, ask once, at the start, with `ask` and two \
        or three choices; otherwise decide yourself and say what you chose in the answer. \(bypass ? Agents.bypassLine : Agents.askFirstLine) A site that walls you \
        off (a paywall, a captcha, a sign-in you can't do) is skipped, and you go on.
        Finish with the answer in Markdown and nothing else: a first line `# ` with the pick or the result in a \
        few words; one or two sentences on why; when you compared things, a table whose last column, Source, \
        holds a [site](url) link for each row; and a last line like `10 checked · 2 skipped: seriouseats.com \
        (paywall)`, leaving out a count that is zero (`10 checked`).
        """
    }

    /// A task asked for on a page opened a tab of its own: it went to look
    /// elsewhere, so from now on it is one in tabs of its own, its answer in
    /// the chat column rather than at the page's foot, and the column comes
    /// out if you are still on that page. A draft stays the page's.
    func wentElsewhere(_ id: String?) {
        guard let session = session(root(of: id)), session.origin == .here, !session.task, session.draft == nil,
              session.state.live, !session.quiet else { return }
        session.task = true
        objectWillChange.send()
        if let browser = window(of: id) ?? browser, browser.active?.guest == session.id { browser.showChat(session.id) }
    }

    /// Ask more, on the answer's page: the same task, only what the words
    /// change looked at again.
    /// `given`: what went with the words (ChatAttachment.said), said after
    /// them, not inside the quote of their own words. `about`: the tabs
    /// among it, which make the message theirs, not the earlier work's.
    func refine(_ session: Session, _ words: String, given: String = "", about tabs: [Tab] = []) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if !session.result.isEmpty { session.earlier = session.result }
        session.progress = "Updating"
        session.read = false
        session.asked.append(words)
        session.saying.append(words)
        // Without tabs, files, quotes and mail go in as they always did.
        let quoted = tabs.isEmpty ? given + words : words
        let prompt = !tabs.isEmpty ? Agents.aboutTabsPrompt(words, given: given, bypass: browser?.prefs.agentsAsking == .bypass) : """
        The user writes again after your last answer, in their own words: «\(quoted)». If that is a question, or \
        says they didn't follow, just answer it, as you would to someone beside you: one to three plain sentences \
        in their language, about what they asked, with no `# ` line, no counts, nothing repeated from before and \
        nothing about what you didn't do. If it changes the task, check again only what that needs, on the tabs \
        you already have open, opening more only if you must; then give the whole answer again in the same form, \
        its last line `~ ` and what changed in a few words, like `~ 2 dropped, they don't ship to Portugal`.
        """
        _ = run(prompt: prompt, cli: nil, access: "browser", resume: session.id)
        objectWillChange.send()
    }

    /// A message in a chat with tabs of theirs attached: about those tabs,
    /// not the work of the chat's earlier turns. Told only to refine that
    /// work "on the tabs you already have open", an agent asked to give
    /// people Full Access on an attached Figma members page went to the
    /// Notion page the chat began on and asked where to do it (2026-11-14).
    static func aboutTabsPrompt(_ words: String, given: String, bypass: Bool) -> String {
        """
        The user writes again in this chat, in their own words: «\(words)». \(given)
        Earlier turns of this chat may have been about other pages; this message is not. Work in the tab they \
        attached: read it, and click and fill in it, to do what they ask; open a tab of your own only for what \
        needs another site. \(bypass ? Agents.bypassLine : Agents.askFirstLine)
        Finish with a short plain answer in their language: what you did there, or plainly what stopped you.
        """
    }

    /// What it was given to see, in a sentence for the prompt.
    /// The space it was asked from, and what is open there: with two
    /// spaces or more, "Anya" in a space of work is the Anya of work
    /// (evals/space-hint). Memory and history are every space's; only this
    /// sentence tells them apart. YAB_SPACE_HINT=off leaves it out, for
    /// the eval's baseline.
    static func spaceLine(_ browser: Browser) -> String {
        guard browser.spacesShown, browser.spaces.count > 1,
              ProcessInfo.processInfo.environment["YAB_SPACE_HINT"] != "off" else { return "" }
        let others = browser.spaces.filter { $0.id != browser.spaceID }.map { "«\($0.name)»" }.joined(separator: ", ")
        // The person's own tabs only: no private one, no agent's.
        let titles = browser.tabs.filter { !$0.shy && !$0.bench && $0.agent == nil }
            .map { $0.label.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(8)
        let open = titles.isEmpty ? "" : "; open there: " + titles.map { "«\($0)»" }.joined(separator: ", ")
        return "They asked from their space «\(browser.space.name)» (their other spaces: \(others))\(open). When a person, " +
            "a project or a word could be read two ways, take the one that belongs to this space, by what is open here " +
            "and what you know of it, and say which you took; reach into another space's only when nothing here fits. "
    }

    static func given(_ context: [TaskContext], browser: Browser) -> String {
        var lines: [String] = []
        for item in context {
            switch item.kind {
            case .page:
                continue
            case .selection:
                if let text = item.text { lines.append("They selected this on the page: «\(text.prefix(4000))».") }
            case .tab:
                guard let id = item.tab, let tab = browser.chatTab(id), !tab.shy else { continue }
                lines.append("They gave you their tab \(Bench.short(tab)) (\(tab.address?.absoluteString ?? ""), \(tab.label)): what they ask is about it, "
                    + "and what is to be done on it you do there, not on another page. " + PageWords.said(tab))
            case .file:
                if let url = item.url, url.isFileURL {
                    lines.append("The user attached a file on this Mac: \(url.path). Give it to a page with `upload` when the task needs it.")
                }
            case .mail:
                if let ref = item.mail { lines.append(MailChat.sentence(ref)) }
            case .item:
                if let text = item.text { lines.append("They pointed at this on the page: \(text).") }
            }
        }
        if context.contains(where: { $0.kind == .mail }) { lines.append(MailChat.rules) }
        if let page = context.first(where: { $0.kind == .page }), let id = page.tab,
           let tab = browser.chatTab(id), !tab.shy, !context.isEmpty, lines.count < context.count {
            lines.insert("They were on their tab \(Bench.short(tab)) (\(tab.address?.absoluteString ?? "")) and gave it to you to read. " + PageWords.said(tab), at: 0)
        }
        return lines.isEmpty ? "" : lines.joined(separator: " ") + " "
    }

    /// A task in tabs of its own came to its end: the corner of the window
    /// it began in says so once, unless you are looking at it there, and Now
    /// keeps its pick.
    func taskEnded(_ session: Session, _ state: State) {
        guard let browser = window(of: session.id) ?? browser else { return }
        // A routine's run: quiet unless it asks to say so, and gone when
        // it found nothing (Routines.finished).
        if session.routine != nil {
            Routines.shared.finished(session, state, in: browser)
            Hints.shared.compose()
            return
        }
        // A boost it put on the page in front: the Keep card there says it.
        // Otherwise its answer is in its chat: seen only with that open,
        // not with one of its tabs in front.
        let chatOpen = browser.chatOpen && browser.chatShown == Agents.shared.root(of: session.id)
        let looking = browser.active.map { Boosts.shared.carded($0, by: session.id) } ?? false || chatOpen
        if state == .done {
            session.progress = nil
            if !looking {
                let pick = TaskAnswer.pick(session.result) ?? Folders.title(session.id)
                // Tabs it closed for you: the sidebar shows it, so the
                // answer's line offers their Undo, ⌘Z's step, not its chat.
                if let undo = NativeControl.shared.closeUndo(session: session.id, in: browser) {
                    browser.toaster.pop(pick, mark: "checkmark.circle", undo: undo, feedback: .success)
                } else {
                    browser.toaster.pop(pick, mark: "checkmark.circle", undo: { [weak browser] in
                        browser?.showChat(session.id)
                    }, act: "Show", feedback: .success)
                }
                AgentNotices.shared.browser = browser
                AgentNotices.shared.post(chat: session.id, title: "\(session.name) is done", body: pick)
            }
            // Its answer came while you were elsewhere: not read yet, though
            // its chat was opened before to answer what it asked.
            session.read = looking
            if looking { Hints.shared.opened(session.id, by: "looking") }
        } else if state == .failed, !looking {
            browser.toaster.pop("\(session.name) couldn’t finish", mark: "exclamationmark.triangle")
        }
        Hints.shared.compose()
    }

    /// A task in tabs of its own asks: the folder lifts, and the corner of
    /// the window it began in says so when you are elsewhere, with the way
    /// there. It is asked in its chat: Show opens that, where the question
    /// and its choices are, not the tab it stopped in.
    func taskAsks(_ tab: Tab, _ session: Session) {
        // Work out of sight asks nobody: its tab can't be brought forward.
        guard session.task, !session.sealed, let browser = window(of: session.id) ?? browser, browser.active !== tab else { return }
        if browser.chatOpen, browser.chatShown == Agents.shared.root(of: session.id) { return }
        browser.toaster.pop("\(session.name) needs you", mark: "agent.face", undo: { [weak browser] in
            browser?.showChat(session.id)
        }, act: "Show", feedback: .offer)
    }
}

// MARK: - the line

/// What asking about a page opens (Settings › AI › Agents).
enum AskOpens: String, CaseIterable {
    case line, chat

    /// The words Settings offers: a field on the page itself, as an
    /// editor's inline ask, or the chat beside it.
    var title: String { self == .line ? "Inline" : "Chat" }
}

/// The task line, on the one tab it is up on.
@MainActor
final class TaskLine: ObservableObject {
    static let shared = TaskLine()

    @Published private(set) var tab: UUID?
    @Published var words = ""
    @Published var context: [TaskContext] = []
    @Published var focusRequest = 0
    let attach = ChatAttach()
    lazy var away = ClickAway { [weak self] in self?.close() }

    /// The whole line owns Escape, including while the answer or page has
    /// focus. The text field's onExitCommand alone cannot cover that.
    func take(_ event: NSEvent, on tab: Tab?) -> Bool {
        guard let tab, self.tab == tab.id, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        close()
        return true
    }
    /// No agent connected: the line says where to get one, or answers on
    /// this Mac (here).
    @Published private(set) var alone = false
    /// Alone, with Apple's model here: asks go to it (MacAnswer).
    @Published private(set) var here = false
    /// This Mac's answer, as it comes.
    @Published private(set) var answer = ""
    @Published private(set) var answering = false
    /// Words that ask for a task, alone: an agent's work, not this Mac's.
    @Published private(set) var needsAgent = false
    private var asking: Task<Void, Never>?

    /// ⌘J on a page, or Ask about this… on what is selected: the line, or
    /// a chat about the page, as Settings › AI › Agents says. Asked again
    /// while the line is up, what it holds goes to a chat.
    func open(on tab: Tab, selection: String? = nil) {
        // Nothing to ask, or AI off: ⌘J and Ask About This aren't there.
        guard !tab.isBlank, AIUse.offers else { return }
        // A person asks: readiness is looked at where tasks run, now.
        AgentSetupModel.shared.asked()
        let alone = !Agents.ready
        // Mail's page is drawn by Yab over an empty one: the line is given
        // what mail shows instead, the open email or the list (MailChat),
        // and what it runs goes to the chat column. The search or the
        // field over the page goes first: one thing on the screen.
        let mail = MailPage.isMail(tab.address)
        if mail, let browser = TaskLine.browser(of: tab) {
            if MailDesk.shared.searching { MailSearch.shared.close() }
            if browser.fieldShowing { browser.editing = false }
        }
        if self.tab == tab.id, selection == nil { return alone ? close() : toChat(on: tab) }
        guard let browser = TaskLine.browser(of: tab) else { return }
        // A connected agent's shell/sign-in discovery may still be in
        // flight after relaunch. It controls sending, not the saved place
        // of the chat. Keep the setup line for a Mac with no connection.
        let column = browser.prefs.askOpens == .chat && (!alone || Agents.connected)
        self.alone = alone
        here = alone && !mail && FormModel.ready
        reset()
        // Settings › AI › Agents says the chat: in mail, a new one about
        // what mail shows, never the empty page under it.
        if column, mail {
            close()
            browser.chatAttach.set(MailChat.now(lines: true).map { [.mail($0)] } ?? [])
            browser.newChat()
            browser.moveChat(open: true)
            return
        }
        if column {
            close()
            browser.askInChat(about: tab, selection: selection)
            return
        }
        words = ""
        attach.menu = false
        if mail {
            context = MailChat.now(lines: true).map { [.mail($0)] } ?? []
            withAnimation(Motion.arrive) { self.tab = tab.id }
            return
        }
        // A private tab is nothing an agent sees: neither the page nor what
        // is selected on it goes with the task, which works in tabs of its
        // own (TaskLineView says so where the page's pill would be).
        context = tab.shy ? [] : [.page(tab)]
        PageWords.warm(tab)
        // The thing the pointer is on, a message or a thread, first.
        if !tab.shy, selection == nil, let item = SiteItems.shared.pointed[tab.id] {
            context.insert(.item(item), at: 0)
        }
        if !tab.shy, let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.append(.selection(selection))
        }
        withAnimation(Motion.arrive) { self.tab = tab.id }
    }

    func close() {
        guard tab != nil else { return }
        away.watch(false)
        attach.menu = false
        reset()
        withAnimation(Motion.depart) { tab = nil }
    }

    private func reset() {
        asking?.cancel()
        asking = nil
        answer = ""
        answering = false
        needsAgent = false
    }

    /// Alone, with the Mac's model: the words about the page, or what is
    /// selected on it, answered here at the line's foot.
    func askHere(on tab: Tab) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        reset()
        if TaskWords.strength(words) == .strong, !MacAnswer.readsOnly(words) {
            needsAgent = true
            return
        }
        answering = true
        let selection = context.first { $0.kind == .selection }?.text
        let given = context.contains { $0.kind == .page }
        asking = Task { [weak self] in
            let page = given ? await PageWords.read(tab) : ""
            do {
                try await MacAnswer.stream(words, page: page, selection: selection) { said in
                    guard !Task.isCancelled, self?.answering == true else { return }
                    self?.answer = said
                }
            } catch {
                if !Task.isCancelled { self?.answer = "This Mac couldn\u{2019}t answer that." }
            }
            if !Task.isCancelled { self?.answering = false }
        }
    }

    /// What the line holds, into a new chat's field in the column, not sent:
    /// the words, and the page and whatever else was given as its chips.
    /// The line goes at once, its words already in the field coming in: a
    /// line fading on the page's foot would stand over the column arriving,
    /// and be laid out where the page ends up while the page is carried.
    func toChat(on tab: Tab) {
        guard !alone else { return }
        guard let browser = TaskLine.browser(of: tab) else { return }
        let words = words
        let context = context
        // In one transaction: a change of it between two writes has
        // SwiftUI lay the whole window out there and then.
        browser.quietly {
            self.tab = nil
            browser.askInChat(about: tab, words: words, context: context)
        }
    }

    private static func browser(of tab: Tab) -> Browser? {
        BrowserWindows.shared.owner(of: tab.id)?.browser
            ?? BrowserWindows.shared.browsers.first { $0.chatTab(tab.id) === tab }
            ?? Agents.shared.browser
    }

    func run(on tab: Tab) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if here, !Agents.ready { return askHere(on: tab) }
        guard Agents.ready else {
            close()
            TaskLine.connect()
            return
        }
        let context = context
        // In mail, always the column: the agent reads mail with its tools
        // and browses in tabs of its own, unseen.
        if MailPage.isMail(tab.address), let browser = TaskLine.browser(of: tab) {
            let refs = context.compactMap(\.mail)
            let other = attachments.filter { $0.mail == nil }
            browser.quietly { self.tab = nil }
            attach.menu = false
            MailChat.start(words, refs: refs, with: other, in: browser, open: true)
            return
        }
        close()
        // Removing This page from the chips also removes it from what the
        // agent may use. A task with no page runs in its own tabs.
        let onPage = !tab.shy && context.contains { $0.tab == tab.id }
        let picked = ModelDefaults.shared.pickNow(.chats)
        let choice = ModelChoice(cli: picked.cli, model: picked.model, effort: picked.effort)
        let textOnly = picked.cli == "gemini" && !GeminiSupport.toolsProven
        let session = Agents.shared.task(words, context: context, on: onPage && !textOnly ? tab : nil, choice: choice,
                                         in: TaskLine.browser(of: tab))
        if textOnly, let session, let browser = TaskLine.browser(of: tab) { browser.showChat(session.id) }
    }

    /// A site action taken from under the line.
    func take(_ action: Skills.Action, on tab: Tab) {
        let item = context.first { $0.kind == .item }?.item
        close()
        Agents.shared.act(action, on: tab, item: action.pattern.hasPrefix("@") ? item : nil)
    }

    /// One of mail's own, taken from under the line: as D, or into the column.
    func take(_ action: MailChat.Action, on tab: Tab) {
        guard let browser = TaskLine.browser(of: tab) else { return }
        guard Agents.ready else { close(); TaskLine.connect(); return }
        browser.quietly { self.tab = nil }
        attach.menu = false
        MailChat.take(action, in: browser)
    }

    func add(_ other: Tab) {
        let item = TaskContext.tab(other)
        guard !context.contains(item) else { return }
        context.append(item)
    }

    var attachments: [ChatAttachment] {
        context.compactMap { item in
            switch item.kind {
            case .page, .tab: return item.tab.map(ChatAttachment.tab)
            case .selection: return item.text.map(ChatAttachment.quote)
            case .file: return item.url.map(ChatAttachment.file)
            case .mail: return item.mail.map(ChatAttachment.mail)
            case .item: return item.text.map(ChatAttachment.quote)
            }
        }
    }

    func toggle(_ other: Tab) {
        if let item = context.first(where: { $0.tab == other.id }) { drop(item) }
        else { add(other) }
    }

    func add(files: [URL]) {
        for url in files where url.isFileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ChatAttachment.most else { continue }
            let item = TaskContext.file(url)
            if !context.contains(item) { context.append(item) }
        }
    }

    func pick(in browser: Browser) {
        let current = tab
        browser.pickFiles(label: "Add to the task") { [weak self] urls in
            guard let self, self.tab == current else { return }
            self.add(files: urls)
            self.focusRequest += 1
        }
    }

    func screenshot(_ tab: Tab) {
        guard let page = tab.builtPage else { return }
        let current = self.tab
        let taken: @MainActor (NSImage?) -> Void = { [weak self] image in
            guard let self, self.tab == current, let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yab-" + ChatComposer.host(tab) + "-" + String(Int(Date().timeIntervalSince1970)) + ".png")
            guard (try? png.write(to: url)) != nil else { return }
            self.add(files: [url])
        }
        // WebKit keeps its own snapshot call; another engine draws through
        // the page seam (Chromium's view can't be read by AppKit).
        if let web = page.webKit {
            web.takeSnapshot(with: nil) { image, _ in MainActor.assumeIsolated { taken(image) } }
        } else {
            page.snapshot(PageShot()) { image, _ in taken(image) }
        }
    }

    func drop(_ item: TaskContext) { context.removeAll { $0 == item } }

    /// Other tabs that can be given, the last looked at first.
    func others(than tab: Tab, in browser: Browser) -> [Tab] {
        let given = Set(context.compactMap(\.tab))
        return browser.tabs.filter { $0.id != tab.id && !$0.isBlank && !$0.bench && !$0.shy && !given.contains($0.id) && $0.address != nil }
            .sorted { $0.touched > $1.touched }
            .prefix(8).map { $0 }
    }

    /// `bench ui task …`, for test runs.
    static func bench(_ command: String, in browser: Browser) -> [String: Any] {
        let line = shared
        // Whether yab is in front, and whether an agent is connected, are asked
        // of the app, not of a tab: a probe with no tab yet may set them.
        switch command {
        case "here", "away", "real": AgentFeed.pretend = command == "real" ? nil : command == "here"
        case "agents-ready", "agents-off", "agents-real": Agents.assumedInTests = command == "agents-real" ? nil : command == "agents-ready"
        default: break
        }
        guard let tab = browser.active else {
            return ["here", "away", "real", "agents-ready", "agents-off", "agents-real"].contains(command) ? [:] : ["error": "no tab"]
        }
        switch command {
        case "open": line.open(on: tab)
        case "chat": line.toChat(on: tab)
        case "line", "column": browser.prefs.askOpens = command == "line" ? .line : .chat
        case "run": line.run(on: tab)
        case "close": line.close()
        case "add": if let other = line.others(than: tab, in: browser).first { line.add(other) }
        case "swap": _ = browser.askOnTab()
        case "take": if let first = browser.query.offers.first { browser.take(first) }
        case "back": MailChat.backToMail(in: browser)
        case "here", "away", "real", "agents-ready", "agents-off", "agents-real": break
        case "showdraft":
            if let first = browser.chatID.flatMap({ Agents.shared.session(Agents.shared.root(of: $0))?.mailDrafts.first }) {
                MailChat.showDraft(first, in: browser)
            }
        case "dropmail":
            let chat = Chats.shared.chat(browser.chatID)
            if let offer = browser.chatAttach.current(chat: chat, browser: browser).first(where: { $0.mail != nil }) {
                browser.chatAttach.remove(offer, chat: chat, browser: browser)
            }
        default:
            // The column's Send, as its field would: with what it carries.
            if command.hasPrefix("send:") {
                let chat = Chats.shared.chat(browser.chatID)
                let items = browser.chatAttach.current(chat: chat, browser: browser)
                browser.chatAttach.clear(for: chat?.id)
                if let chat { Agents.shared.followUp(chat.id, String(command.dropFirst(5)), with: items) }
                else { ChatComposer.begin(String(command.dropFirst(5)), with: items, in: browser) }
            }
            if command.hasPrefix("follow:"), let url = URL(string: String(command.dropFirst(7))) { _ = MailChat.follow(url, in: browser) }
            if command.hasPrefix("showwork:") {
                let parts = command.dropFirst(9).split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { MailChat.showWork(parts[0], parts[1]) }
            }
            if command.hasPrefix("act:"), let action = MailChat.actions().first(where: { $0.id == String(command.dropFirst(4)) }) {
                line.take(action, on: tab)
            }
            if command.hasPrefix("select:") { line.open(on: tab, selection: String(command.dropFirst(7))) }
            if command.hasPrefix("words:") { line.words = String(command.dropFirst(6)) }
            if command.hasPrefix("more:"), let id = browser.chatID, let session = Agents.shared.session(id) {
                Agents.shared.refine(session, String(command.dropFirst(5)))
            }
            if command.hasPrefix("field:") {
                if !browser.fieldShowing { browser.newTab() }
                browser.typed = String(command.dropFirst(6))
            }
            // A task's folder's Mark as Read, by its name's start.
            if command.hasPrefix("markread:"),
               let folder = Folders.shared.folders.first(where: { Folders.title($0.id).hasPrefix(String(command.dropFirst(9))) }) {
                AgentFeed.shared.read(folder.members.compactMap { id in browser.tabs.first { $0.id == id } })
            }
        }
        return ["open": line.tab != nil, "words": line.words,
                // Where a task's answer is: the chat the column shows, the card at the page's foot.
                "column": browser.chatOpen ? browser.chatID ?? "" : "", "foot": tab.answer.map { String($0.text.prefix(200)) } ?? "",
                // The column's field: out, a new chat, what it carries, its words.
                "chatOpen": browser.chatOpen, "fresh": browser.chatFresh, "draft": browser.chatAttach.words,
                "attached": browser.chatAttach.current(chat: Chats.shared.chat(browser.chatID), browser: browser).map(\.id),
                "toast": browser.toaster.shown ? [browser.toaster.words, browser.toaster.act ?? ""] : [],
                "context": line.context.map(\.title),
                // In mail: the line's own actions, and an agent's tab in front.
                "mailActions": MailPage.isMail(tab.address) ? MailChat.actions().map(\.title) : [],
                "mailOff": MailChat.off, "lookedAt": MailChat.lookedAt(in: browser),
                "mailDrafts": browser.chatID.flatMap { Agents.shared.session(Agents.shared.root(of: $0))?.mailDrafts } ?? [],
                "rows": browser.fieldShowing ? browser.query.offers.prefix(4).map { "\($0.key) · \($0.title)" } : [],
                "tasks": Agents.shared.sessions.filter(\.task).map { session -> [String: Any] in
                    ["id": session.id, "title": Folders.title(session.id), "state": session.state.rawValue,
                     "progress": session.progress ?? "", "read": session.read, "answer": String(session.result.prefix(600))]
                },
                // Each agent's tab's end, and each folder's: a face, the tick
                // or nothing, and what is still unread.
                "ends": browser.tabs.filter { $0.worker != nil || $0.unread != nil || $0.answering != nil || $0.settled != nil }.map { tab -> [String: Any] in
                    ["id": Bench.short(tab), "title": tab.title, "face": tab.wearsFace, "unread": tab.unread.map { $0.failed ? "failed" : "done" } ?? "",
                     "front": browser.onScreen(tab.id)]
                },
                "folders": Folders.shared.folders.filter { $0.nest == nil }.map { folder -> [String: Any] in
                    ["id": folder.id, "title": Folders.title(folder.id), "unread": folder.unread, "stuck": folder.stuck,
                     "tip": FolderEnd.tip(folder, session: Agents.shared.session(folder.id))]
                }]
    }

    /// No agent yet: Settings › Agents, where Connect is.
    static func connect() {
        Agents.shared.browser?.openSettings(.agents)
    }

    /// The folder's name until the agent gives one: the words, short.
    static func title(_ words: String) -> String {
        let line = words.split(whereSeparator: \.isNewline).first.map(String.init) ?? words
        guard line.count > 40 else { return line }
        let cut = line.prefix(38)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}

/// The line at the page's foot, where the dock lives, in the page's light:
/// you are the one driving it.
struct TaskLineView: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var line = TaskLine.shared
    @ObservedObject private var attach = TaskLine.shared.attach
    @FocusState private var typing: Bool
    @State private var cardHeight: CGFloat = 0

    private var browser: Browser? { Agents.shared.browser }

    var body: some View {
        Group {
            if line.alone && !line.here { connect } else { card }
        }
        .frame(width: 480, alignment: .leading)
        .agentCardFrame()
        .background(ClickZone(away: line.away))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        .overlay(alignment: .bottomLeading) {
            if attach.menu, let browser {
                ChatAddMenu(browser: browser, chat: nil, attach: attach, line: line)
                    .background(ClickZone(away: line.away))
                    .padding(.leading, CardFrame.inset)
                    .padding(.bottom, cardHeight + 6)
            }
        }
        .padding(.bottom, 14) // design: the dock's own lift off the page's foot (AgentDock)
        .onAppear {
            line.away.within = { [weak tab] in tab?.builtPage?.window }
            line.away.watch(true)
            DispatchQueue.main.async { typing = true }
        }
        .onDisappear { line.away.watch(false) }
        .onChange(of: attach.menu) { _, open in if open { typing = false } }
        .onChange(of: line.focusRequest) { _, _ in typing = true }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            pills
            TextField(line.here ? "Ask about this page\u{2026}" : "Ask \(AgentSetupModel.name(ModelDefaults.shared.pickNow(.chats).cli))\u{2026}", text: $line.words, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...5)
                .focused($typing)
                .onSubmit { line.run(on: tab) }
                .onExitCommand { line.close() }
                .padding(.horizontal, 4)
                .frame(minHeight: ButtonSize.regular.height, alignment: .leading)
            if line.here { macAnswer }
            foot
        }
    }

    /// No agent and no model here: where to connect one, in the line's place.
    private var connect: some View {
        HStack(spacing: 10) {
            Text("Asking and tasks need Claude or ChatGPT.")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 4)
            Spacer(minLength: 8)
            Button { line.close(); TaskLine.connect() } label: {
                HStack(spacing: 6) {
                    Text("Connect")
                    KeyGlyphs(keys: "\u{21A9}", size: 12.5, tint: nil, rest: 0.6)
                }
            }
            .buttonStyle(.yab(.primary, .regular, glass: true))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($typing)
        .onKeyPress(.return) { line.close(); TaskLine.connect(); return .handled }
        .onExitCommand { line.close() }
    }

    /// This Mac's answer under the words, or why it is an agent's to do.
    @ViewBuilder private var macAnswer: some View {
        if line.needsAgent {
            HStack(spacing: 8) {
                Text("Tasks need Claude or ChatGPT.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button("Connect") { line.close(); TaskLine.connect() }
                    .buttonStyle(.yab(.secondary, .small))
                    .fixedSize()
            }
            .padding(.horizontal, 4)
        } else if !line.answer.isEmpty {
            ThreadScrollView {
                Text(AgentAnswer.rich(line.answer))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
    }

    private var pills: some View {
        HStack(spacing: 6) {
            ForEach(line.context) { item in
                ContextPill(item: item) { line.drop(item) }
            }
            if MailPage.isMail(tab.address), MailChat.off {
                // Where the email's chip would be: why it isn't.
                Button { if let browser { SettingsWindow.shared.show(.mail, for: browser) } } label: {
                    HStack(spacing: 6) {
                        Symbol("envelope", size: 11)
                        Text("Agents don’t read your mail")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
                .keyTip("Settings › Mail")
            }
            if tab.shy {
                // Where This page would be: why it isn't.
                HStack(spacing: 6) {
                    Symbol("incognito", size: 11)
                    Text("This private tab stays with you")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
            }
            if browser != nil, !line.here {
                Button { attach.menu.toggle() } label: { Text("+ Add") }
                .buttonStyle(.yab(attach.menu ? .secondary : .quiet, .small))
                .focusable(false)
                .background(ClickZone(away: attach.away))
                .fixedSize()
                .keyTip("Add a tab, a screenshot or a file")
            }
            Spacer(minLength: 0)
        }
    }

    private var foot: some View {
        // The site's own actions, or the way to a chat once words are typed;
        // in mail, mail's own (MailChat.actions).
        let mail = MailPage.isMail(tab.address)
        // About the thing pointed at first, then the page's.
        let pointed = line.context.first { $0.kind == .item }?.item
        let about = pointed.map { SiteItems.shared.actions(for: $0, on: tab) } ?? []
        let actions = mail ? [] : Array((about + Hints.shared.actions(on: tab)).prefix(2))
        let mailActions = mail && line.context.contains { $0.kind == .mail } ? MailChat.actions() : []
        let offers = line.words.isEmpty && (!actions.isEmpty || !mailActions.isEmpty)
        return HStack(spacing: 6) {
            if line.here {
                Text(line.answering ? "Answering on this Mac\u{2026}" : "On this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)
            } else if offers, !mailActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(mailActions) { action in
                        Button { line.take(action, on: tab) } label: {
                            HStack(spacing: 6) {
                                Text(action.title)
                                if let keys = action.keys, !keys.isEmpty {
                                    KeyGlyphs(keys: keys, size: 11.5, tint: nil, rest: 0.6)
                                }
                            }
                        }
                        .buttonStyle(.yab(.secondary, .small))
                        .fixedSize()
                    }
                }
            } else if !offers {
                Button { line.toChat(on: tab) } label: {
                    HStack(spacing: 6) {
                        Text("Open in Chat")
                        KeyGlyphs(keys: Keymap.shared.text(.agentAsk), size: 11.5, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.quiet, .small))
                .fixedSize()
                .keyTip("What you typed, to a chat beside the page")
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action.title) { line.take(action, on: tab) }
                            .buttonStyle(.yab(.secondary, .small))
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 8)
            Button { line.run(on: tab) } label: {
                HStack(spacing: 6) {
                    Text(line.here ? "Ask" : "Run")
                    KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                }
            }
            .buttonStyle(.yab(.primary, .regular, glass: true))
            .disabled(line.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.answering)
        }
    }
}

/// What the agent will see, a pill each; × takes one away.
private struct ContextPill: View {
    let item: TaskContext
    let drop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if item.kind == .mail {
                Symbol("envelope", size: 11)
                    .foregroundStyle(Palette.muted)
            } else if let host = item.url?.host(), let icon = Favicons.shared.cached(host) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(item.title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize()
            Button(action: drop) {
                Symbol("xmark", size: 8, weight: .bold)
                    .foregroundStyle(Palette.muted)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(hovering ? 1 : 0.5)
            .keyTip("Don't give it this")
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Palette.wash))
        .onHover { hovering = $0 }
    }
}

// MARK: - the answer's pick

/// What a task's answer leads with, for the corner, Now and a notice; the
/// answer itself is in the task's chat.
enum TaskAnswer {
    /// The pick, from the answer's first line.
    static func pick(_ answer: String) -> String? {
        for line in answer.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let bare = text.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
            guard bare.count > 70 else { return bare }
            // A long line leads with its first sentence, when that fits,
            // rather than cut where the room ends.
            if let first = bare.range(of: #"^.{8,69}?[.!?](?=\s|$)"#, options: .regularExpression) { return String(bare[first]) }
            return String(bare.prefix(68)) + "…"
        }
        return nil
    }

    /// The page a task's answer had before it moved to its chat
    /// (yab://task/<id>), in a tab kept from then: its session.
    static func oldPage(_ url: URL?) -> String? {
        guard url?.scheme == DiaryPage.scheme, url?.host() == "task", let last = url?.pathComponents.last, last != "/" else { return nil }
        return last
    }
}

extension Browser {
    /// The rows the agent adds under the words, after the search: Ask, then
    /// the task; with no agent, one row that connects one. Each names the
    /// plan it goes to: Ask the Commands default's (askInField), the task
    /// the Tasks default's.
    func agentRows() -> [Suggestion] {
        // When Asked, Off, or Hide AI Rows in Field: none (AIUse).
        guard AIUse.allows(.field), Agents.ready else { return [] }
        let asked = AgentSetupModel.name(ModelDefaults.shared.pickNow(.commands).cli)
        return [Suggestion(key: "Ask \(asked)", title: "answers here", url: nil, kind: .ask),
                Suggestion(key: "Task for \(Agents.preferredName)", title: "in its own tabs", url: nil, kind: .task)]
    }

    /// Which of the words' rows the words read as: a verb first, the task;
    /// a question, Ask; anything else (or no agent, or one signed in only
    /// by another app and never connected here), the search. ⇥ asks
    /// whatever leads (askOnTab).
    func wordsLead(_ text: String) -> Suggestion.Kind {
        guard AIUse.allows(.field), Agents.ready, Agents.connected else { return .search }
        if TaskWords.strength(text) == .strong { return .task }
        if TaskWords.question(text) { return .ask }
        return .search
    }

    /// The words' Ask row when ⇥ asks it: only plain words, nothing else
    /// ⇥ is for. No site or place the words name, no gray ending, no row
    /// walked to (the pointer resting on one is not a key), no row to finish
    /// the words with or walk to (an open tab, a page been to or kept, an
    /// address, a command): the list holds only the search, the engine's suggestions, the agent's
    /// rows and the clipboard. The field's end says so, naming
    /// Ask and its key.
    var tabAsks: Suggestion? {
        guard FieldUnder.shared.tabAsks, AIUse.allows(.field), !query.answering, query.scope == nil, query.offering == nil, query.place == nil, query.edit == nil,
              picked == nil, ending?.isEmpty != false,
              !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              query.offers.allSatisfy(Self.plainWords) else { return nil }
        return query.offers.first { $0.kind == .ask }
    }

    /// A row that leaves ⇥ to Ask: none of them is something ⇥ finishes
    /// the words with or is walked to for.
    nonisolated static func plainWords(_ offer: Suggestion) -> Bool {
        switch offer.kind {
        case .search, .suggested, .ask, .task, .asked, .clip, .site, .within: return true
        default: return false
        }
    }

    /// ⇥ with words typed: Ask answers them at once, whichever row is on
    /// top.
    func askOnTab() -> Bool {
        // Words still being composed (an input method's): its Tab.
        if InputMethod.composing() { return false }
        guard let ask = tabAsks else { return false }
        take(ask)
        return true
    }
}

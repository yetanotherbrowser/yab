import AppKit
import Combine
import SwiftUI

// A task that opens many tabs, its own and its subagents', gets one folder
// instead of a row each, the way Arc keeps a group of tabs: in the column,
// and on top.
//
// The folder is only a view over tabs that share a task: every tab whose
// agent is the task's session or one of its subagents'. There is none for a
// task on one tab once it is done; one asked for in words gets its folder
// while it works, and the moment a second tab opens, the first row becomes
// the folder where it stands (its mark the folder's, its title the task's
// name, a count), and nothing else in the list moves. While a folder holds
// one site besides its answer's page, its mark is that site's icon
// (Folders.site), the agent's face at its end. Your own tabs, a guest's
// included, never go in.
//
// Click it and it opens: the flap folds down over the agent's eyes and the
// tabs come out under it in turn, 30 ms apart; shut is one quicker move.
// When the task needs you the mark becomes the hand, the row lifts, and the
// tab that asks comes out under the folder, shut or not. Done, it ticks,
// and the count falls to what the task left for you. Each tab it left ticks
// until you come to it, and the folder until you have come to them all
// (AgentFeed); then the row's end is quiet. Fifteen minutes after you last
// looked, the folder and its tabs go (Agents.putAway), but never a tab you
// haven't come to yet. A tab you drag above the folder is yours from then on.
//
// Under it, subagents (the `subagent` and
// `subagent_wait` tools): a child session per objective, at most eight at
// once, each in its own tabs, told to conclude within the time its task
// gave it (twenty minutes unless it said otherwise) and stopped soon after, never asking the user anything, its report handed to
// its parent as a message.

// MARK: - subagents

extension Agents {
    static let subagentLimit = 8
    /// How long a subagent gets unless its task says: ten was too short
    /// for research across a few slow sites, most of a first live run's
    /// subagents stopped with the job half done.
    nonisolated static let subagentMinutes: Double = 20
    nonisolated static let subagentShortest: Double = 5
    nonisolated static let subagentLongest: Double = 45
    /// What each subagent was given, by its session.
    static var budgets: [String: Double] = [:]

    static func budget(_ session: Session) -> Double { budgets[session.id] ?? subagentMinutes }
    nonisolated static let profiles = ["default", "context_explorer", "code_explorer", "fork_self"]

    /// What a task yab runs is told about handing work out.
    static let delegating = """

    For work that splits into independent parts (comparing several products, reading many pages, \
    checking several sites), hand parts to subagents with `subagent` and collect them with \
    `subagent_wait`: each works in tabs of its own while you go on, at most 8 at once. Give each \
    one objective and everything it needs, since it can't see this conversation (fork_self can). \
    Profiles: default browses and acts; context_explorer only reads pages, cheap and safe for \
    research; code_explorer reads this Mac's files (only with full access); fork_self is a copy \
    of you that carries on from here. Before your final answer, collect every subagent you \
    started with `subagent_wait`: the answer rests on their findings, so don't give it before \
    they report. One that finishes while you aren't waiting on it tells you itself. A subagent \
    can't upload: when one reports a file to put on a page, call `upload` there yourself. `open` takes \
    several urls at once. When the task takes more than one tab, \
    its tabs sit in a folder in the user's tab list: call `name` once, early, with two to four \
    words for what the task is (Flights to Lisbon), or the folder shows your whole prompt.
    """

    /// What a subagent is told, whatever its task.
    static func directive(_ profile: String, minutes: Double = subagentMinutes) -> String {
        var text = """

        You are a subagent: another agent delegated one objective to you. Do only that objective, \
        nothing around it. You have \(Int(minutes)) minutes; conclude before then with what \
        you have. You can't ask the user anything: no handoff, and no yes for Send, Pay or Delete. \
        When something needs the user, stop and say so in your report; the parent takes it from \
        there. A file to put on a page (an icon, an attachment) is not the user's to do: leave that \
        tab open and report its tab, the ref of what attaches the file and the file's path; the \
        parent uploads it. Act only in tabs you open yourself; other tabs you may read. Close your \
        other tabs before you answer. Your last message is your report to the parent: the findings themselves, \
        concrete (names, numbers, links), no preamble.
        """
        switch profile {
        case "context_explorer":
            text += " You only read: open pages, snapshot, text and scroll them; don't click, type, press or run scripts."
        case "code_explorer":
            text += " Your objective is about code and files on this Mac: explore them from your working folder, reading rather than changing unless the objective says otherwise."
        case "fork_self":
            text += " Everything above this was your parent's conversation; from here you work on the objective below alone."
        default:
            break
        }
        return text
    }

    /// The task a session belongs to: itself, or the one at the top of its
    /// parents.
    func root(of id: String?) -> String? {
        var here = session(id)
        var steps = 0
        while let up = here?.parent, steps < 8, let found = session(up) {
            here = found
            steps += 1
        }
        return here?.id ?? id
    }

    /// Whether a task has a chat for the column: one yab runs, or one kept.
    /// An agent that came on its own, from a terminal, talks to you there:
    /// here it would be a chat of nothing, and a field it never reads. Nor
    /// has Yab's own quiet work one (the morning look), unless it was asked
    /// for in the field, or a kept plugin woke it (its answer's row opens it).
    func hasChat(_ id: String?) -> Bool {
        let top = root(of: id)
        if let found = session(top) { return found.agent != .external && (!found.quiet || found.origin == .field || found.boostOrigin != nil) }
        return Chats.shared.chat(top) != nil
    }

    /// One of Yab's own tasks out of sight (Get to Know, the morning look):
    /// its tabs sit in one shut folder at the end of the row that never
    /// opens, none of them ever the one in front.
    /// Its page held in its folder is too (KnowPage.hold), until it steps out.
    func sealed(_ tab: Tab) -> Bool {
        guard let agent = tab.agent ?? tab.answering else { return false }
        return sealed(agent)
    }

    /// The same for a task's folder, or any session of the task.
    func sealed(_ id: String?) -> Bool {
        guard let id else { return false }
        return session(root(of: id))?.sealed == true
    }

    func children(of id: String) -> [Session] {
        sessions.filter { $0.parent == id }
    }

    /// A task whose subagents are still out: its turn is over but it isn't,
    /// their reports each start another.
    func holding(_ session: Session) -> Bool {
        // Out, or back with a report the task hasn't had yet (it is handed
        // over a beat after the subagent ends).
        guard children(of: session.id).contains(where: { $0.state.live || !$0.reported }) else { return false }
        if session.now != "Waiting for subagents" { note(session, "Waiting for subagents") }
        return true
    }

    func spawn(from parent: String, prompt: String, profile: String, name: String?, minutes: Double? = nil) -> (Session?, String?) {
        guard remoteTaskOrigin(parent) == nil else { return (nil, RemoteTaskBoundary.unavailable) }
        guard let up = session(parent), up.parent == nil, up.agent != .external, up.state.live else {
            return (nil, "only a task Yab runs can start subagents")
        }
        // Out of sight, in its own shut folder: nobody to hand their tabs to.
        guard !up.sealed else { return (nil, "this task works alone: no subagents") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, "subagent needs a task") }
        guard Agents.profiles.contains(profile) else { return (nil, "profile is one of \(Agents.profiles.joined(separator: ", "))") }
        if profile == "code_explorer", !up.full { return (nil, "code_explorer needs full access, and this task has only the browser") }
        if profile == "fork_self", up.thread == nil { return (nil, "nothing to fork yet: try again after your first step") }
        // Codex can only carry on a thread, not branch it: a fork would write
        // into this task's own conversation.
        // Cursor and Gemini carry on a conversation by id too, so the same.
        if profile == "fork_self", up.agent != .claude {
            return (nil, "fork_self needs Claude Code; with \(AgentSetupModel.name(up.cli)), use default and put what it needs to know in the task")
        }
        let active = children(of: up.id).filter { $0.state.live }.count
        guard active < Agents.subagentLimit else {
            return (nil, "Too many active subagents (\(Agents.subagentLimit) at once). Wait for one with subagent_wait, then start the next.")
        }
        let words = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = run(prompt: prompt, cli: up.cli, model: up.model, effort: up.effort, access: up.full ? nil : "browser",
                       name: words?.isEmpty == false ? words : "Subagent \(children(of: up.id).count + 1)",
                       resume: nil, parent: up.id, profile: profile)
        Agents.budgets[made.id] = Agents.clamp(minutes)
        deadline(made)
        return (made, nil)
    }

    /// A follow-up for a subagent of this task, finished or not.
    func resume(_ id: String, from parent: String, prompt: String, minutes: Double? = nil) -> (Session?, String?) {
        guard remoteTaskOrigin(parent) == nil, remoteTaskOrigin(id) == nil else { return (nil, RemoteTaskBoundary.unavailable) }
        guard let sub = session(id), sub.parent == parent else { return (nil, "no subagent \(id) of this task") }
        guard let up = session(parent), up.state.live else { return (nil, "this task has ended") }
        if !sub.state.live {
            let active = children(of: parent).filter { $0.state.live }.count
            guard active < Agents.subagentLimit else {
                return (nil, "Too many active subagents (\(Agents.subagentLimit) at once). Wait for one with subagent_wait, then resume this one.")
            }
        }
        let made = run(prompt: prompt, cli: sub.cli, resume: sub.id)
        if let minutes { Agents.budgets[made.id] = Agents.clamp(minutes) }
        deadline(made)
        return (made, nil)
    }

    /// A time asked for, kept between the shortest and longest a subagent
    /// is given.
    static func clamp(_ minutes: Double?) -> Double {
        min(max(minutes ?? subagentMinutes, subagentShortest), subagentLongest)
    }

    /// Its time, then told to conclude; a minute and a half more, then
    /// stopped with what it has.
    private func deadline(_ session: Session) {
        let stamp = Date()
        session.looked = stamp
        let minutes = Agents.budget(session)
        let limit = minutes * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, session.looked == stamp, session.state.live else { return }
            _ = steer(session.id, "Time is up. Stop now: close your tabs and give your report with what you have.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit + 90) { [weak self] in
            guard let self, session.looked == stamp, session.state.live else { return }
            if session.result.isEmpty { session.result = "Stopped at the \(Int(minutes)) minute limit without a report." }
            _ = stop(session.id)
        }
    }

    /// A subagent is over: its tabs go, but for one you are looking at or
    /// one still asking for you, and its report goes to its task.
    func ended(sub session: Session) {
        AgentTabCleanup.shared.schedule(session, immediate: true)
        // A beat, for a parent already waiting on it to take the answer
        // itself (subagent_wait), so it isn't told twice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.report(session) }
    }

    private func report(_ session: Session) {
        guard !session.reported, let up = self.session(session.parent), up.state.live, !up.remembering else { return }
        session.reported = true
        let all = children(of: up.id)
        let over = all.filter { !$0.state.live }.count
        let model = session.model ?? (session.agent == .codex ? "codex" : "claude")
        // Said to the agent as a message of the person's, drawn in the chat
        // as the subagent's card (SubagentReport), never as your words.
        let text = SubagentReport.message(name: session.name, id: session.id, state: session.state.rawValue, model: model,
                                          over: over, all: all.count, answer: session.result)
        if up.agent == .codex {
            // Codex takes it after the turn it is in, or now, when its
            // turn was over and it was only waiting on its subagents.
            if up.process == nil { start(up, message: text) } else { up.queue.append(text) }
        } else if up.input != nil {
            send(up, text)
        } else {
            up.queue.append(text)
        }
    }

    /// What Done in a task's chat closes with it: the tabs its agents
    /// opened, the one in front of you too. Done is finished with them;
    /// ⌥ is the way to keep them.
    func leftovers(_ id: String) -> [Tab] {
        guard let browser = liveBrowsingWindow(of: id) else { return [] }
        return leftovers(id, among: browser.tabs)
    }

    /// The task's own tabs among `tabs`: never one of yours it worked in
    /// (asked on, pointed at, given by `open`, or shared with an assistant).
    func leftovers(_ id: String, among tabs: [Tab]) -> [Tab] {
        guard let root = root(of: id) else { return [] }
        return tabs.filter { $0.agent != nil && self.root(of: $0.agent) == root }
    }

    /// The browser holding `id`'s work tabs when acting from `browser`:
    /// its live browsing window, any open normal window holding its tabs,
    /// or the live normal fallback when the chat lives in a private window.
    func tabBrowser(of id: String, from browser: Browser) -> Browser {
        if let origin = browsingWindow(of: id) { return BrowserWindows.shared.live(origin) }
        if let holder = BrowserWindows.shared.browsers.first(where: { $0.windowPurpose != .privateOnly && !leftovers(id, among: $0.tabs).isEmpty }) {
            return holder
        }
        if browser.windowPurpose == .privateOnly, let fallback = self.browser.map({ BrowserWindows.shared.live($0) }) {
            return fallback
        }
        return browser
    }

    /// Done, pressed in a finished task's chat: the column goes, and the
    /// task's tabs with it unless ⌥ keeps them. Kept, a tab you were
    /// driving is handed back: there is nobody left to hand it to.
    func finish(_ id: String, in browser: Browser, keepingTabs: Bool) {
        let host = tabBrowser(of: id, from: browser)
        let tabs = leftovers(id, among: host.tabs)
        for tab in tabs { AgentFeed.shared.handBack(tab) }
        if !keepingTabs { host.close(tabs) }
        browser.moveChat(open: false)
    }

    /// Finished work is put away by one clock, with the same protections
    /// in every window and one last check after the page answers.
    func putAway(_ root: Session) {
        AgentTabCleanup.shared.schedule(root)
    }
}

// MARK: - the folders

@MainActor
final class Folders: ObservableObject {
    static let shared = Folders()

    private let emptiesFile: URL?
    /// Every space's empty folders, read from `emptiesFile` the first time:
    /// one shelf for every window (`init(sharing:)`).
    private let shelf: Shelf
    /// Another window's: its changes are the first window's too, for every
    /// view that watches the folders (KeptEverywhere.swift).
    private var forward: AnyCancellable?

    init(emptiesFile: URL? = Store.file("empty-folders.json"), forwardingTo first: Folders? = nil) {
        self.emptiesFile = emptiesFile
        shelf = Shelf()
        // Private windows keep their own shelf and no file, but the column
        // observes the same notification source as every other window.
        if let first {
            forward = objectWillChange.sink { [weak first] _ in first?.objectWillChange.send() }
        }
    }

    /// The folders of a window other than the first: its own rows, places,
    /// open task folders and names being typed, the same empty folders as
    /// the first window's, and a change told to whatever watches the
    /// first's, which the column of every window does.
    init(sharing first: Folders) {
        emptiesFile = first.emptiesFile
        shelf = first.shelf
        shelf.folders.append(Weak(self))
        forward = objectWillChange.sink { [weak first] _ in first?.objectWillChange.send() }
    }

    /// Every space's empty folders, and the folders that draw them.
    private final class Shelf {
        var bySpace: [UUID: [Nest]]?
        var folders: [Weak] = []
    }

    private struct Weak {
        weak var folders: Folders?
        init(_ folders: Folders) { self.folders = folders }
    }

    struct Folder: Identifiable, Equatable {
        /// The task's session, or for one of yours, its nest's key.
        let id: String
        let members: [Tab.ID]
        /// Members asking for you: out from under the folder, shut or not.
        let asking: Set<Tab.ID>
        /// One of yours, among the kept (Kept.swift); nil for a task's.
        var nest: Nest? = nil
        /// Yab's own work out of sight (Agents.sealed): shut for good, its
        /// tabs never shown, a click on it its chat.
        var sealed = false
        /// How many of its tabs a finished task left that you haven't come
        /// to yet, and whether one of them couldn't finish: the tick at the
        /// row's end, or the face looking down, until you have (AgentFeed).
        var unread = 0
        var stuck = false

        static func == (a: Folder, b: Folder) -> Bool {
            a.id == b.id && a.members == b.members && a.asking == b.asking && a.sealed == b.sealed
                && a.unread == b.unread && a.stuck == b.stuck
        }

        /// What the end of its row shows once its task is over: the tick
        /// while any of its tabs is unread, looking down while one that
        /// couldn't finish is, nothing once you've seen them all.
        var over: FacePose? {
            unread == 0 ? nil : stuck ? .stuck : .done
        }
    }

    /// Where a tab stands with respect to its task's folder, or to the
    /// folders of yours it is in.
    struct Place: Equatable {
        /// The folder it is right in: its task's, or the deepest of yours.
        let folder: String
        /// The folders above it whose own rows are drawn, from the top down:
        /// all it is in, but those inside a shut one. A row is drawn for each
        /// before the first tab that has it here (`slots`).
        var chain: [String] = []
        /// Those of `chain` drawn in its cell, above it: the folders it is
        /// the first tab of.
        var heads: [String] = []
        /// The first of a folder's tabs: the folder is drawn in its place.
        var head: Bool { !heads.isEmpty }
        /// Drawn as a row of its own under the folder: open, or asking.
        var shown: Bool
        /// Its turn in the unfold.
        var order: Int
        /// In the column's list even while tucked away: its folder is
        /// opening or shutting, and the row folds or unfolds in place. At
        /// rest a tucked row isn't in the list at all (SideBar).
        var listed = false
        /// On the last row an open task's folder shows while it holds back
        /// the rest: how many it holds back, said in a row of its own under
        /// this one ("3 more"), which lets them out.
        var more = 0
        /// How many folders its row is stepped in for, a mark's width each
        /// (`indent`): 1 in a task's folder or one of yours at the top, more
        /// in a folder in a folder; the tab on screen out under a shut
        /// folder, one more than that folder.
        var depth = 1
        /// Among the kept of a space folded under its name (`shut`): no
        /// folder's row is drawn for it, and it is drawn, if at all, as a
        /// row of its own under the name.
        var bare = false
    }

    /// How many of its tabs an open task's folder shows before the rest
    /// wait behind a row that says how many.
    nonisolated static let atOnce = 4

    /// The line under the kept tabs: a slot of its own among the rows, keyed
    /// with the folders' own rows, so the rows step aside for it as for a
    /// folder's (see `slots`).
    static let line = "line"
    /// The rows the line takes: its own, and New Tab's under it, where
    /// today's tabs start and a new one comes in.
    static let lineRows = 2
    static let newTab = "new-tab"

    /// As in Arc, the line heads today's tabs whenever there are any, kept
    /// tabs above it or not: Clear is on it, and New Tab under it.
    static func showsLine(_ tabs: [Tab], folded: Set<Tab.ID> = []) -> Bool {
        tabs.contains { $0.pin == nil && !$0.kept && !folded.contains($0.id) }
    }

    /// How far a folder's tabs step in under its row: their icons start at
    /// the folder mark's right edge, as Arc's do, so a tab's title keeps
    /// most of the row.
    static let indent: CGFloat = 15

    @Published private(set) var folders: [Folder] = []
    @Published private(set) var places: [Tab.ID: Place] = [:]
    @Published private(set) var open: Set<String> = []
    /// Some of today's tabs are open, so the line heads them.
    @Published private(set) var lined = false
    /// The space on screen is folded under its name (SpaceName), as Arc
    /// folds a space's pinned tabs: its kept tabs, its folders and the
    /// empty ones are out of sight, but the tab on screen and one asking,
    /// each drawn under the name as a row of its own. Today's stay.
    @Published private(set) var shut = false
    /// The kept tabs in no folder of yours out of sight under it. Those in
    /// one have their place (`Place.bare`).
    @Published private(set) var away: Set<Tab.ID> = []
    /// The space on screen has something to fold: kept tabs or folders.
    @Published private(set) var keeps = false
    /// The spaces folded under their names, as kept on this Mac.
    @Published private(set) var shutSpaces: Set<UUID> = Folders.readShut()
    /// The space folding or unfolding, its rows in the list meanwhile.
    private var spaceTurn: Int?
    /// Its kept tabs in no folder of yours while it folds or unfolds: given
    /// a place for that while (`place(of:)`), so their rows fold and unfold
    /// as a folder's do rather than come and go.
    @Published private(set) var turning: Set<Tab.ID> = []
    /// Folders of yours whose rows the folded space keeps out of sight.
    private var shutRows = 0
    /// Folders of yours with nothing in them yet, this space's: at the end
    /// of the kept, above the line, until a tab goes in (Kept.swift). A
    /// folder with tabs is held by its tabs; one without, by this list.
    @Published private(set) var empties: [Nest] = []
    /// Every space's empty folders, as kept on disk.
    private var emptyBySpace: [UUID: [Nest]] {
        get {
            if let read = shelf.bySpace { return read }
            let read = emptiesFile.map(Folders.readEmpties(from:)) ?? [:]
            shelf.bySpace = read
            return read
        }
        set { shelf.bySpace = newValue }
    }
    /// The folder of yours whose name is being typed, just made or Rename…
    @Published var naming: UUID?
    /// The last folder selected in this window's column, for ⌘I.
    @Published var focused: UUID?
    /// Rows put out of sight by a shut folder's minus, including opened
    /// tabs while focus is outside it. Kept by folder so list changes and
    /// unrelated selections cannot reveal them again.
    private var unpeekedFolders: Set<UUID> = []
    private var unpeekedAt: Tab.ID?
    /// Held here because opening a folder can replace its row between clicks.
    private var lastNestTap: (id: UUID, at: TimeInterval)?
    /// How many tabs are tucked away in shut folders: how far a drag may
    /// have to look past the slot it is over for where it lands.
    private var tucked = 0
    /// A folder of yours in the hand, carried whole: its tabs, the one on
    /// screen too, tucked under it for as long as it is held.
    private(set) var carried: String?
    /// The empty folders drawn at the end of a folder of yours with tabs,
    /// by its key: the ones right in it, each followed by those in it while
    /// it is open (`flat`).
    private(set) var trail: [String: [Nest]] = [:]
    /// The empty folders at the top of the kept that stand among it rather
    /// than at its end (Nest.stand), in the list's order, each with the rows
    /// it draws: itself and, while it is open, the empty ones in it. Down
    /// the column only: on top every empty folder is a pill at the kept's
    /// end, and a folded space shows none.
    private(set) var standing: [(nest: Nest, rows: [Nest])] = []
    /// The same by the run each stands above (`run`), as drawn at rest.
    private(set) var ahead: [String: [Nest]] = [:]
    /// The tabs a drag or a move has just put elsewhere in the row, told by
    /// Browser.move: an empty folder standing over one of them stays where
    /// it was rather than going with it (`resolve`).
    var moving: Set<Tab.ID> = []

    /// Empty folders for a neighboring space before it becomes current.
    func empties(in space: UUID) -> [Nest] { emptyBySpace[space] ?? [] }

    func carry(_ id: String?) {
        guard carried != id else { return }
        carried = id
        work()
    }
    /// Bumped whenever what `slots` reads changes, for what is worked out
    /// from it to know it still holds.
    private(set) var version = 0
    /// Folders opening or shutting, their tucked rows in the list meanwhile,
    /// and which turn of each it is, so a later one's end isn't cut short.
    private var folding: [String: Int] = [:]
    private var turns = 0
    /// Open task folders whose "N more" was clicked: every tab shown, until
    /// the folder is shut.
    private(set) var whole: Set<String> = []

    private var watching: [AnyCancellable] = []
    private var pending = false

    weak var browser: Browser? {
        didSet {
            guard let browser, browser !== oldValue else { return }
            let agents = Agents.shared
            watching = [
                agents.objectWillChange.sink { [weak self] _ in self?.soon() },
                browser.changes(\.tabs).sink { [weak self] _ in self?.soon() },
                browser.changes(\.activeID).sink { [weak self] id in
                    DispatchQueue.main.async { self?.looked(at: id) }
                    self?.soon()
                },
                // The tab on screen keeps its split partner shown (`lay`).
                browser.changes(\.pairs).sink { [weak self] _ in self?.soon() },
                // A kept tab opened or put down: under a shut folder it
                // comes out or goes in (`awake`).
                Tab.unopenedChanged.sink { [weak self, weak browser] tab in
                    guard tab.nest != nil, browser?.tabs.contains(where: { $0 === tab }) == true else { return }
                    self?.soon()
                },
                // Where a folded space's name is, or isn't (`isShut`): the
                // tabs across the top, or a second space made or the last
                // but one gone.
                browser.prefs.changes(\.sidebar).sink { [weak self] _ in self?.soon() },
                browser.prefs.changes(\.usesSpaces).sink { [weak self] _ in self?.soon() },
                browser.changes(\.spaces).sink { [weak self] _ in self?.soon() },
            ]
            // At once, not a turn later: the row is first drawn with its
            // folders and the line, not moved under them once they come.
            work()
        }
    }

    /// Worked out once the change has landed, and published only when a
    /// folder is made, fills, empties or asks: an agent's every step
    /// doesn't redraw the column.
    private func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending = false
            work()
        }
    }

    /// A tab kept or let go, filed or not: its row moved already, but a
    /// tab's own state changing doesn't reach the list's watch.
    func refresh() { work() }

    private func work(again: Bool = true) {
        guard let browser else { return }
        settle(browser)
        let tasks = Folders.tasks(in: browser.tabs, rowed: true)
        let yours = Folders.nests(in: browser.tabs)
        // Empty ones: this space's, less any a tab has since gone into.
        var empty = emptyBySpace[browser.spaceID] ?? []
        let held = Set(yours.compactMap(\.nest?.id))
        var changed = false
        if empty.contains(where: { held.contains($0.id) }) {
            // Held by its tabs now, it stands where they do.
            for nest in empty where held.contains(nest.id) { nest.stand = nil }
            empty.removeAll { held.contains($0.id) }
            changed = true
        }
        // An empty one in a folder of yours: in the one its tabs hold, read
        // from the session apart from the empties' file; and that folder
        // kept while the empty one is in it, as an empty one too, once the
        // last tab under it goes.
        let living = Dictionary(yours.compactMap { $0.nest.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        var index = 0
        while index < empty.count {
            let nest = empty[index]
            if let up = nest.parent, let same = living[up.id], same !== up { nest.parent = same }
            if let up = nest.parent, living[up.id] == nil, !empty.contains(where: { $0 === up }) {
                empty.append(up)
                changed = true
            }
            index += 1
        }
        if changed {
            emptyBySpace[browser.spaceID] = empty
            saveEmpties()
        }
        if empty.map(\.id) != empties.map(\.id) { empties = empty }
        let made = Folders.marked(yours + empty.map { Folder(id: $0.key, members: [], asking: [], nest: $0) } + tasks, among: browser.tabs)
        // A task's folder that is gone is shut for good. One in another
        // space isn't gone: it stays open or shut as it was left, as a
        // folder of yours does and as Arc keeps each folder (row 384).
        let kept = Folders.stillOpen(open, here: tasks) { Folders.tasks(in: browser.parkedTabs) }
        if kept != open { open = kept }
        whole.formIntersection(open)
        // The row put in order: worked out again now, in the same turn, so
        // the folders and places land with it. Left for the next turn, the
        // new tab was drawn loose for a frame, then jumped in.
        if gather(made, in: browser) {
            if again { work(again: false) }
            return
        }
        if unpeekedAt != browser.activeID {
            // Only picking a tab inside a hidden folder releases its minus.
            // Closing/creating/switching tabs elsewhere leaves it alone.
            if let tab = browser.active {
                unpeekedFolders.subtract(tab.nest?.chain.map(\.id) ?? [])
            }
            unpeekedAt = browser.activeID
        }
        let unpeeked = Set(browser.tabs.filter { tab in
            tab.nest?.chain.contains { unpeekedFolders.contains($0.id) } == true
        }.map(\.id))
        var (placed, hidden) = Folders.lay(made, isOpen: { Folders.isOpen($0, among: self.open) }, whole: whole,
                                           folding: Set(folding.keys), carried: carried, active: browser.activeID, unpeeked: unpeeked,
                                           awake: Folders.awake(in: browser.tabs),
                                           partner: { id in browser.pair(of: id).map { $0.first == id ? $0.second : $0.first } })
        let keeping = empty.contains { !$0.today } || browser.tabs.contains { $0.pin == nil && $0.kept }
        let folded = keeping && isShut(browser.spaceID, in: browser)
        var tucking: Set<Tab.ID> = []
        if folded {
            let asking = made.reduce(into: Set<Tab.ID>()) { $0.formUnion($1.asking) }
            let out = Folders.fold(&placed, tabs: browser.tabs, active: browser.activeID, asking: asking,
                                   partner: { id in browser.pair(of: id).map { $0.first == id ? $0.second : $0.first } }, listed: spaceTurn != nil)
            tucking = out.away
            hidden += out.hidden
        }
        // The tabs the agents' row stands for (AgentRow): out of sight as
        // a folded space's kept are, the one on screen and one asking too,
        // since the row is that tab then.
        if AgentRow.on {
            for tab in browser.tabs where placed[tab.id] == nil && AgentRow.holds(tab) && tucking.insert(tab.id).inserted { hidden += 1 }
        }
        tucked = hidden
        let turned = spaceTurn == nil ? [] : Set(browser.tabs.filter { $0.pin == nil && $0.kept && placed[$0.id] == nil }.map(\.id))
        if turned != turning { turning = turned }
        shutRows = folded ? made.filter { $0.nest.map { !$0.today } ?? false }.count : 0
        let line = Folders.showsLine(browser.tabs) || empty.contains { $0.ordinaryToday }
        let trails = Folders.trails(folded ? empty.filter(\.today) : empty, living: Set(living.keys), hiding: carried)
        // Where each empty one at the top stands now, put right after a
        // change to the row: the tab it stood above gone or moved away, it
        // stays under the one above (`Folders.resolve`).
        let heads = self.heads(browser.tabs)
        let headAt = Dictionary(heads.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var stood: [(nest: Nest, rows: [Nest])] = []
        var moved = false
        for nest in empty where nest.parent == nil && !nest.today {
            // With no kept tab in the row yet, as at a launch before the
            // session is read, there is nothing to stand over: kept as it
            // is, drawn at the end meanwhile, not forgotten.
            guard let stand = nest.stand, !heads.isEmpty else { continue }
            let next = Folders.resolve(stand, heads: heads, at: headAt, moved: moving).map { Folders.stand(before: $0, heads: heads, at: headAt) }
            if next != stand {
                nest.stand = next
                moved = true
            }
            guard next != nil, !folded, browser.prefs.sidebar else { continue }
            stood.append((nest, [nest] + (nest.open && nest.key != carried ? Folders.flat(empty, under: nest, hiding: carried) : [])))
        }
        moving = []
        if moved { saveEmpties() }
        let byRun = Dictionary(stood.compactMap { each -> (String, [Nest])? in
            guard let id = each.nest.stand?.before, let tab = browser.tabs.first(where: { $0.id == id }) else { return nil }
            return (run(tab), each.rows)
        }, uniquingKeysWith: { $0 + $1 })
        if stood.map(\.nest.id) != standing.map(\.nest.id) || stood.map(\.rows.count) != standing.map(\.rows.count)
            || byRun.mapValues({ $0.map(\.id) }) != ahead.mapValues({ $0.map(\.id) }) { version += 1 }
        standing = stood
        ahead = byRun
        if trails.mapValues({ $0.map(\.id) }) != trail.mapValues({ $0.map(\.id) }) { version += 1 }
        trail = trails
        if made != folders || placed != places || line != lined || folded != shut || tucking != away { version += 1 }
        if made != folders { folders = made }
        if placed != places { places = placed }
        if line != lined { lined = line }
        if tucking != away { away = tucking }
        if folded != shut { shut = folded }
        if keeping != keeps { keeps = keeping }
    }

    /// The kept of a space folded under its name, out of sight in `placed`:
    /// the tab on screen (its pair's other half too) and one asking stay,
    /// each a row of its own under the name, in no folder's; the rest go,
    /// listed meanwhile while the space folds or unfolds. What goes and has
    /// no place, in no folder of yours, and how many rows went.
    static func fold(_ placed: inout [Tab.ID: Place], tabs: [Tab], active: Tab.ID?, asking: Set<Tab.ID>,
                     partner: (Tab.ID) -> Tab.ID?, listed: Bool) -> (away: Set<Tab.ID>, hidden: Int) {
        var away: Set<Tab.ID> = []
        var hidden = 0
        for tab in tabs where tab.pin == nil && tab.kept {
            let seen = tab.id == active || asking.contains(tab.id) || (active != nil && partner(tab.id) == active)
            if var place = placed[tab.id] {
                if place.shown, !seen { hidden += 1 }
                if !place.shown, seen { hidden -= 1 }
                place.chain = []
                place.heads = []
                place.shown = seen
                place.listed = seen || listed
                place.more = 0
                // The one seen stands under the name; the others fold
                // where they were.
                if seen {
                    place.order = 0
                    place.depth = 0
                }
                place.bare = true
                placed[tab.id] = place
            } else if !seen {
                away.insert(tab.id)
                hidden += 1
            }
        }
        return (away, hidden)
    }

    /// The tasks' folders among `tabs`, in their order: the agents' tabs,
    /// and a page of yours a task was begun from. For the space on screen
    /// (`work`), and a space's row drawn before it comes (PagedSpace).
    /// `rowed`: in the column, where the agents' row stands for some of
    /// them (AgentRow), and those are in no folder.
    static func tasks(in tabs: [Tab], rowed: Bool = false) -> [Folder] {
        let agents = Agents.shared
        var theirs: [(root: String, id: Tab.ID, asking: Bool)] = []
        let row = rowed && AgentRow.on
        // A kept tab stays among your kept ones: a chat begun from it never
        // takes it into a task's folder, where gather listed it twice.
        for tab in tabs where tab.pin == nil && !tab.kept && (tab.bench || tab.began != nil || tab.answering != nil) {
            if row, AgentRow.holds(tab) { continue }
            guard let agent = tab.agent ?? tab.answering ?? tab.began, agent != Agents.script, let root = agents.root(of: agent) else { continue }
            // A sealed folder holds only the task's own tabs, and its own
            // page (Get to Know's notebook, first): a page of yours stays in sight.
            if tab.agent == nil, tab.answering == nil, agents.session(root)?.sealed == true { continue }
            theirs.append((root: root, id: tab.id, asking: tab.handoff != nil))
        }
        return Folders.form(theirs, task: { agents.session($0).map { $0.task && $0.state.live } ?? false }, sealed: { agents.session($0)?.sealed == true })
    }

    /// Yours among `tabs`, among the kept, and a search's among today's:
    /// one folder for each nest its tabs share, from its first tab, and one
    /// for each folder those are in, whose members are every tab under it.
    /// A folder comes before the folders in it.
    static func nests(in tabs: [Tab]) -> [Folder] {
        var nests: [Nest] = []
        var members: [UUID: [Tab.ID]] = [:]
        // Not one in from another space with you (a call, an agent's):
        // its folder is its home's, never drawn over this space's (row 1149).
        for tab in tabs where (tab.kept || tab.nest?.today == true) && tab.homeSpace == nil {
            guard let nest = tab.nest else { continue }
            for each in nest.chain {
                if members[each.id] == nil { nests.append(each) }
                members[each.id, default: []].append(tab.id)
            }
        }
        return nests.map { Folder(id: $0.key, members: members[$0.id] ?? [], asking: LiveFolders.callingOut($0, among: tabs), nest: $0) }
    }

    /// What finished tasks left in each folder that you haven't looked at
    /// yet, its tabs among `tabs`.
    static func marked(_ made: [Folder], among tabs: [Tab]) -> [Folder] {
        var marks: [Tab.ID: Bool] = [:]
        for tab in tabs { if let unread = tab.unread { marks[tab.id] = unread.failed } }
        guard !marks.isEmpty else { return made }
        return made.map { folder in
            guard !folder.sealed else { return folder }
            var folder = folder
            let left = folder.members.compactMap { marks[$0] }
            folder.unread = left.count
            folder.stuck = left.contains(true)
            return folder
        }
    }

    /// The tasks' folders, from their tabs in the row's order (the task each
    /// is one of, and whether it waits on you there): one from a task's
    /// second tab, or from its first for a task asked for in words while it
    /// works, whose answer's page leads, and for a sealed one, so that no
    /// plain row of it ever shows. Done, one tab is a row, not a folder of
    /// one (2026-10-14: a page a task had opened came down from the pins in
    /// a folder of its own). A sealed folder never asks: nobody is there to be
    /// asked.
    static func form(_ tabs: [(root: String, id: Tab.ID, asking: Bool)], task: (String) -> Bool, sealed: (String) -> Bool) -> [Folder] {
        var order: [String] = []
        var groups: [String: [(id: Tab.ID, asking: Bool)]] = [:]
        for tab in tabs {
            if groups[tab.root] == nil { order.append(tab.root) }
            groups[tab.root, default: []].append((id: tab.id, asking: tab.asking))
        }
        return order.compactMap { root -> Folder? in
            guard let members = groups[root] else { return nil }
            let shut = sealed(root)
            guard members.count >= 2 || shut || task(root) else { return nil }
            let asking = shut ? [] : Set(members.filter(\.asking).map(\.id))
            return Folder(id: root, members: members.map(\.id), asking: asking, sealed: shut)
        }
    }

    /// The tasks' folders left open: each of `open` still a task's folder,
    /// in the space on screen (`here`) or parked in another (`elsewhere`,
    /// read only when one isn't here). A task that is over, its tabs gone,
    /// is dropped for good, so its id never comes back open.
    static func stillOpen(_ open: Set<String>, here: [Folder], elsewhere: () -> [Folder]) -> Set<String> {
        let away = open.subtracting(here.map(\.id))
        guard !away.isEmpty else { return open }
        return open.subtracting(away.subtracting(elsewhere().map(\.id)))
    }

    /// Open, as `open` holds the tasks' and a folder of yours holds its own;
    /// a sealed one never, whatever asked for it.
    static func isOpen(_ folder: Folder, among open: Set<String>) -> Bool {
        !folder.sealed && (folder.nest?.open ?? open.contains(folder.id))
    }

    /// The one site a task's folder holds besides its answer's page, while
    /// nothing in it asks: the folder wears that site's icon, as a row of
    /// it would (2026-10-19: a task fetching files from Telegram showed
    /// the agent's folder where Telegram's icon was expected).
    static func site(_ folder: Folder, among tabs: [Tab]) -> Tab? {
        guard !folder.sealed, folder.nest == nil, folder.asking.isEmpty else { return nil }
        let sites = folder.members.compactMap { id in tabs.first { $0.id == id } }
        return sites.count == 1 ? sites.first : nil
    }

    /// What can't be: a pin kept, a tab that can't be kept kept, a folder
    /// round a tab under the line, the two halves of a pair on two sides of
    /// it. Put right quietly; whatever made it has already drawn.
    private func settle(_ browser: Browser) {
        var alone: [ObjectIdentifier: Int] = [:]
        // A folder in a folder only among your kept ones: a search's or one
        // of today's is in none and holds none; never in one in it, never
        // past five deep.
        var checked = Set<ObjectIdentifier>()
        // Not one in from another space with you (`home`): its folders are
        // its home's, put right there, never undone here.
        let own = browser.tabs.filter { $0.homeSpace == nil }
        for tab in own {
            guard let nest = tab.nest else { continue }
            for each in nest.chain.reversed() where checked.insert(ObjectIdentifier(each)).inserted {
                if each.today && !each.ordinaryToday { each.parent = nil }
                if let up = each.parent, up.today != each.today || up.within(each) { each.parent = nil }
            }
            if nest.depth > Nest.deepest {
                let chain = nest.chain
                chain[chain.count - Nest.deepest].parent = nil
            }
        }
        for tab in own {
            // By its address, not `isBlank`'s flag, a turn late for a tab
            // just sent somewhere (New Tab in Folder's).
            if tab.kept, tab.pin != nil || tab.shy || tab.bench || tab.address == nil { tab.kept = false }
            // Out of its live folder, however it went: yours now.
            if tab.live != nil, tab.nest?.live == nil || !tab.kept { LiveFolders.shared.takenOut(tab) }
            // A search's folder is today's: kept, a tab leaves it.
            if tab.kept, tab.nest?.today == true { tab.nest = nil }
            if !tab.kept, let nest = tab.nest, !nest.today || tab.pin != nil || tab.bench { tab.nest = nil }
            if let nest = tab.nest, nest.today, !nest.staysAlone { alone[ObjectIdentifier(nest), default: 0] += 1 }
        }
        // A search's folder down to one tab, its first closed or the rest
        // taken out: gone quietly, the tab where it was.
        if alone.values.contains(1) {
            for tab in own where tab.nest.map({ $0.today && alone[ObjectIdentifier($0)] == 1 }) == true { tab.nest = nil }
        }
        for pair in browser.pairs {
            guard let first = browser.tabs.first(where: { $0.id == pair.first }),
                  let second = browser.tabs.first(where: { $0.id == pair.second }) else { continue }
            if second.kept != first.kept { second.kept = first.kept }
            if second.nest !== first.nest { second.nest = first.nest }
        }
    }

    /// The row in its order: the kept first, each folder of yours one run of
    /// them where its first tab stands, then today's, and a task's folders
    /// last, each one run of tabs: a tab of yours that lands among a task's
    /// (a link opened from one of its pages, a row let go of there) goes just
    /// above them. True when the list was changed, and so will be worked out
    /// again.
    private func gather(_ made: [Folder], in browser: Browser) -> Bool {
        let loose = browser.tabs.filter { $0.pin == nil }
        let tasks = made.filter { $0.nest == nil }
        let inside = Set(tasks.flatMap(\.members))
        var kept: [Tab] = []
        var today: [Tab] = []
        var taken = Set<Tab.ID>()
        // A folder's run: its own tabs and its folders' runs, each where its
        // first tab stands among them.
        func run(_ nest: Nest, keeping: Bool = true) {
            var done = Set<UUID>()
            for member in loose where member.kept == keeping && !taken.contains(member.id) && (keeping || !inside.contains(member.id)) {
                guard let inner = member.nest, inner.within(nest) else { continue }
                if inner === nest {
                    if keeping { kept.append(member) } else { today.append(member) }
                    taken.insert(member.id)
                } else {
                    let chain = inner.chain
                    guard let at = chain.firstIndex(where: { $0 === nest }), at + 1 < chain.count else { continue }
                    if done.insert(chain[at + 1].id).inserted { run(chain[at + 1], keeping: keeping) }
                }
            }
        }
        for tab in loose where tab.kept && !taken.contains(tab.id) {
            guard let nest = tab.nest else {
                kept.append(tab)
                taken.insert(tab.id)
                continue
            }
            run(nest.chain.first ?? nest)
        }
        // Today's, a search's folder one run of them where its first tab
        // stands.
        for tab in loose where !tab.kept && !inside.contains(tab.id) && !taken.contains(tab.id) {
            guard let leaf = tab.nest, leaf.today else {
                today.append(tab)
                taken.insert(tab.id)
                continue
            }
            let nest = leaf.chain.first ?? leaf
            run(nest, keeping: false)
        }
        let byID = Dictionary(loose.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var listed = Set<Tab.ID>()
        let want = (kept.map(\.id) + today.map(\.id) + tasks.flatMap(\.members)).filter { listed.insert($0).inserted }
        // The shared pins before a space's own: one a call took into a space
        // with sign-ins of its own stands first there too (SharedPins.swift).
        let pins = browser.tabs.filter { $0.pin != nil }
        let led = pins.filter { $0.everywhere != nil } + pins.filter { $0.everywhere == nil }
        guard want != loose.map(\.id) || !led.elementsEqual(pins, by: { $0 === $1 }) else { return false }
        browser.lay(led + want.compactMap { byID[$0] })
        return true
    }

    // MARK: - drawn slots, for a drag

    /// What a held tab would be once let go: kept or not, and in which of
    /// your folders.
    struct Guise: Equatable {
        var kept: Bool
        var nest: UUID?
    }

    /// Where each loose tab is drawn, in rows (or pills on top) from the
    /// first: a folder's own slot, keyed by the folder, comes before its
    /// first tab, a tab tucked into one takes none, and the line's, keyed
    /// `line`, comes after the last kept tab. `out` is a tab counted as out
    /// of a task's folder, the one being dragged out of it; `held` is drawn
    /// as `guise` says rather than as it is. `joined`, down the column,
    /// where two tabs side by side (Split.swift) are one row: the second of
    /// a pair shares its first's slot.
    /// `moved`: tabs whose place in `order` is where the hand has them,
    /// with `held`; an empty folder standing above one stays put (`stands`).
    /// `kept`: tabs of today's drawn as kept, a folder of today's carried
    /// up among the kept whole (#440).
    func slots(_ order: [Tab], out: Tab.ID? = nil, joined: Bool = false, held: Tab.ID? = nil, as guise: Guise? = nil,
               moved: Set<Tab.ID> = [], kept keptAs: Set<Tab.ID> = [], today todayAs: Set<Tab.ID> = []) -> (tabs: [Tab.ID: Int], folders: [String: Int]) {
        var slot = 0
        var tabs: [Tab.ID: Int] = [:]
        var made: [String: Int] = [:]
        var last: Tab.ID?
        // The kept are a place of their own, tabs or not: the line comes
        // before the first of today's either way. Empty folders of yours
        // stand at its end, just above the line, but those in a folder with
        // tabs, which stand at the end of its run.
        // Those standing among the kept, before the run each stands over,
        // the first of it here (`run`, a held tab's as its guise has it).
        let stood = stands(in: order, skip: moved.union(held.map { [$0] } ?? [])) { $0.id == guise?.nest }
        let empty = block.filter { $0.id != guise?.nest } + stood.end
        let todayStood = todayAhead
        var begun: Set<String> = []
        var lined = false
        func line() {
            for nest in empty {
                made[nest.key] = slot
                slot += 1
            }
            made[Folders.line] = slot
            made[Folders.newTab] = slot + 1
            slot += Folders.lineRows
            lined = true
        }
        // The folders each tab is under as drawn here, whose rows come
        // before its own, and whether its own is drawn.
        let laid: [(keys: [String], shown: Bool, place: Bool)] = order.map { tab in
            let guised = tab.id == held ? guise : nil
            if let guised, let id = guised.nest {
                // Held over a folder of yours: drawn in it, open.
                return (self.nest(id)?.chain.map(\.key) ?? [Nest.key(id)], true, true)
            }
            if guised != nil, places[tab.id].map({ Nest.isKey($0.folder) }) ?? false { return ([], true, false) }
            if tab.id == out { return ([], true, false) }
            guard let place = places[tab.id] else { return ([], !away.contains(tab.id), false) }
            return (place.bare ? [] : place.chain.isEmpty ? [place.folder] : place.chain, place.shown, true)
        }
        // Where each folder's run ends here, for the empty folders in it.
        var ends: [String: Int] = [:]
        for (at, each) in laid.enumerated() { for key in each.keys { ends[key] = at } }
        for (at, tab) in order.enumerated() {
            defer { last = tab.id }
            let guised = tab.id == held ? guise : nil
            let isKept = guised?.kept ?? (!todayAs.contains(tab.id) && (tab.kept || keptAs.contains(tab.id)))
            if !isKept, !lined {
                line()
            }
            if !isKept, let empty = todayStood[tab.id] {
                for nest in empty { made[nest.key] = slot; slot += 1 }
            }
            let each = laid[at]
            // The pair is one row even inside a folder. Its second half
            // keeps the first half's slot, but still ends its folder's run.
            let sharedSlot: Int?
            if joined, let pair = browser?.pair(of: tab.id), pair.second == tab.id {
                sharedSlot = tabs[pair.first]
            } else {
                sharedSlot = nil
            }
            if !stood.before.isEmpty, isKept {
                let key = guised != nil ? each.keys.first ?? "tab:" + tab.id.uuidString : run(tab)
                if begun.insert(key).inserted, let nests = stood.before[key] {
                    for nest in nests {
                        made[nest.key] = slot
                        slot += 1
                    }
                }
            }
            guard each.place else {
                if let sharedSlot {
                    tabs[tab.id] = sharedSlot
                    continue
                }
                if joined, let last, let pair = browser?.pair(of: tab.id), pair.second == tab.id, pair.first == last {
                    tabs[tab.id] = slot - 1
                    continue
                }
                tabs[tab.id] = slot
                if each.shown { slot += 1 }
                continue
            }
            for key in each.keys where made[key] == nil {
                made[key] = slot
                slot += 1
            }
            tabs[tab.id] = sharedSlot ?? slot
            if each.shown, sharedSlot == nil { slot += 1 }
            if tab.id != out, let more = places[tab.id]?.more, more > 0 { slot += 1 }
            // The empty ones at the end of each folder that ends here, the
            // deepest first, while it is open and its row drawn.
            for key in each.keys.reversed() where ends[key] == at {
                guard let nests = trail[key], key != carried, folder(key)?.nest?.open == true else { continue }
                for nest in nests where nest.id != guise?.nest {
                    made[nest.key] = slot
                    slot += 1
                }
            }
        }
        if !lined, !todayBlock.isEmpty { line() }
        if !lined {
            for nest in empty {
                made[nest.key] = slot
                slot += 1
            }
            made[Folders.newTab] = slot
        }
        for nest in todayBlock { made[nest.key] = slot; slot += 1 }
        return (tabs, made)
    }

    /// The kept tabs in folders of yours that are open, as Arc's pinned
    /// tab is from its first click until its minus or ⌘W: opened since the
    /// launch and not put down (`Tab.unopened`). One asleep for memory is
    /// still open. These stay under a shut folder after focus moves away;
    /// restored links stay inside until opened (register 1451).
    static func awake(in tabs: [Tab]) -> Set<Tab.ID> {
        Set(tabs.lazy.filter { $0.nest != nil && $0.kept && !$0.gone && !$0.unopened && ($0.builtPage != nil || $0.asleep) }.map(\.id))
    }

    /// Where each folder's tab stands, and how many are tucked away: shown
    /// under its folder while it is open, for a task's the first `atOnce`
    /// unless the rest were let out; the tab you are on, its pair and any asking
    /// shown whatever, but in a folder carried whole; in a folder of yours
    /// shut, its opened tabs too (`awake`). The last shown row of
    /// a task's folder holding some back says how many. A sealed folder's
    /// tabs are never shown, nor listed, not even the one you are on.
    static func lay(_ made: [Folder], isOpen: (Folder) -> Bool, whole: Set<String>, folding: Set<String>,
                    carried: String? = nil, active: Tab.ID?, unpeeked: Set<Tab.ID> = [], awake: Set<Tab.ID> = [],
                    partner: (Tab.ID) -> Tab.ID? = { _ in nil }) -> (places: [Tab.ID: Place], tucked: Int) {
        var placed: [Tab.ID: Place] = [:]
        var hidden = 0
        let focusedPartner = active.flatMap(partner)
        for folder in made where folder.nest == nil {
            let open = !folder.sealed && isOpen(folder)
            let all = whole.contains(folder.id) || folder.members.count <= atOnce
            var turn = 0
            var last: Tab.ID?
            var held = 0
            for (at, id) in folder.members.enumerated() {
                let kept = !folder.sealed && (folder.asking.contains(id) || id == active || id == focusedPartner)
                let shown = folder.id != carried && (kept || open && (all || at < atOnce))
                placed[id] = Place(folder: folder.id, chain: [folder.id], heads: at == 0 ? [folder.id] : [], shown: shown, order: shown ? turn : 0,
                                   listed: shown || !folder.sealed && folding.contains(folder.id))
                if shown {
                    turn += 1
                    last = id
                } else {
                    hidden += 1
                    if open, folder.id != carried { held += 1 }
                }
            }
            if held > 0, let last { placed[last]?.more = held }
        }
        // Yours, a folder in a folder: each tab under the deepest folder
        // that holds it, and drawn in each above that, a row of each before
        // its first tab while every folder above that row is open.
        let yours = made.filter { $0.nest != nil && !$0.members.isEmpty }
        guard !yours.isEmpty else { return (placed, hidden) }
        let byKey = Dictionary(yours.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var deepest: [Tab.ID: Folder] = [:]
        var heads: [Tab.ID: [String]] = [:]
        var asking = Set<Tab.ID>()
        for folder in yours {
            asking.formUnion(folder.asking)
            if let first = folder.members.first { heads[first, default: []].append(folder.id) }
            let depth = folder.nest?.depth ?? 1
            for id in folder.members where (deepest[id]?.nest?.depth ?? 0) < depth { deepest[id] = folder }
        }
        // A folder's row is drawn while all it is in are open, and none of
        // them is in the hand.
        func drawn(_ key: String) -> Bool {
            guard let chain = byKey[key]?.nest?.chain else { return false }
            return chain.dropLast().allSatisfy { up in byKey[up.key].map { isOpen($0) && $0.id != carried } ?? false }
        }
        var turns: [String: Int] = [:]
        for folder in yours {
            for id in folder.members where deepest[id]?.id == folder.id {
                let chain = (folder.nest?.chain ?? []).compactMap { byKey[$0.key] }
                // Drawn rows, from the top down: to the first shut one, or
                // the one in the hand.
                var rows: [String] = []
                var open = true
                for up in chain {
                    rows.append(up.id)
                    if up.id == carried || !isOpen(up) {
                        open = false
                        break
                    }
                }
                let inHand = chain.contains { $0.id == carried }
                // The one on screen and its pair, unless the folder's minus
                // put them away (`unpeeked`).
                let peeking = !unpeeked.contains(id) && (id == active || id == focusedPartner)
                // Opened tabs stay too (register 1451), unless the minus put
                // that one away.
                let shown = !inHand && (open || asking.contains(id) || peeking || (awake.contains(id) && !unpeeked.contains(id)))
                let top = chain.first?.id ?? folder.id
                let turn = turns[top, default: 0]
                if shown { turns[top] = turn + 1 } else { hidden += 1 }
                placed[id] = Place(folder: folder.id, chain: rows, heads: (heads[id] ?? []).filter(drawn), shown: shown,
                                   order: shown ? turn : 0, listed: shown || chain.contains { folding.contains($0.id) },
                                   depth: rows.count)
            }
        }
        return (placed, hidden)
    }

    /// Where a held tab goes if let go now.
    struct Landing: Equatable {
        /// Its index among the loose tabs once moved.
        var index: Int
        /// The slot it is drawn in there.
        var slot: Int
        /// Taken out of its folder, and so yours.
        var out = false
        /// Above the line, and in which of your folders.
        var kept = false
        var nest: UUID?
        /// Over a shut folder of yours: let go, it goes into it. The rows
        /// stay as they were drawn for `index`.
        var into: UUID?

        var guise: Guise { Guise(kept: kept, nest: nest) }
    }

    /// Where the held tab is let go if the hand is `want` slots down the
    /// list as drawn (fractional: the middle of the held row, over the
    /// rows' first as 0). The place, among those it may go to, whose slot
    /// is nearest. Your tabs stay above a task's folders, the kept above the
    /// line, a folder of yours one run; a task's tab stays among its own, or
    /// comes out onto the folder's slot or above it, among yours. `lean`:
    /// how many folders deep the hand asks for, by how far it has gone
    /// sideways, for where in a folder, in the one it is in, or out of
    /// them all are the same slot: the end of an open folder.
    /// `current`: the landing as drawn now, whose rows a shut folder under
    /// the hand leaves where they are.
    func landing(_ held: Tab, want: Double, deep: Int? = nil, among loose: [Tab], joined: Bool = false, current: Landing? = nil, drawn: Int? = nil) -> Landing {
        guard let from = loose.firstIndex(where: { $0.id == held.id }) else { return Landing(index: 0, slot: 0) }
        // Where it is drawn now: said by the caller when it knows, the list
        // not being laid out again for every move of the hand.
        let now = drawn ?? slots(loose, joined: joined).tabs[held.id] ?? from
        guard want.isFinite else { return Landing(index: from, slot: now, kept: held.kept, nest: held.nest?.id) }
        var rest = loose
        rest.remove(at: from)
        let task = places[held.id].map { !Nest.isKey($0.folder) } ?? false
        // Folded under its name, the space takes nothing among its kept:
        // the one held from there may stay where it is, or go to today's.
        // A task's tab may be kept too: taken among the kept it comes out
        // of the task and is yours (`out`, Folders.keep), as Keep does; it
        // couldn't, and went back into its task's folder (2026-10-14 22:15).
        // Yab's own work out of sight never comes out.
        // An agent's tab is the agent's (`bench`) until it comes out to you,
        // which taking it among the kept does (Folders.keep adopts it).
        let keepable = !shut && (held.keepable || (task && held.bench && held.pin == nil && !held.shy && !held.isBlank))
            && !(task && Agents.shared.sealed(held))

        // Over one of your folders, shut, as the rows are drawn now: into
        // it, and nothing moves, so the folder stays under the hand.
        if keepable, folders.contains(where: { folder in folder.nest.map { (!$0.open || folder.members.isEmpty) && $0 !== held.nest } ?? false }) {
            let shown = current ?? Landing(index: from, slot: now, kept: held.kept, nest: held.nest?.id)
            var order = rest
            order.insert(held, at: min(max(0, shown.index), order.count))
            let heads = slots(order, out: shown.out ? held.id : nil, joined: joined, held: held.id, as: shown.guise).folders
            for folder in folders {
                guard let nest = folder.nest, !nest.open || folder.members.isEmpty, nest !== held.nest, let head = heads[folder.id] else { continue }
                // Anywhere over its row: the rows around it would otherwise
                // make way at its middle, and it would step away from under
                // the hand before the hand was in. Once in, a little more
                // room to stay in than to come in.
                let reach = shown.into == nest.id ? 0.6 : 0.5
                if want >= Double(head) - reach, want <= Double(head) + reach {
                    var into = shown
                    into.into = nest.id
                    return into
                }
            }
        }

        // Your rows end where a task's folder's tabs begin, the kept where
        // the first of today's does.
        let yours = rest.firstIndex { places[$0.id].map { !Nest.isKey($0.folder) } ?? false } ?? rest.count
        let keptIn = rest.prefix(while: \.kept).count
        // Only the places the hand could be near: every folder row and every
        // tucked-away tab can put a slot one further from its index.
        let reach = 3 + folders.count + tucked
        // A hand can travel well past the final row. Clamp both insertion
        // bounds before converting to Int or indexing the remaining tabs.
        let near = want.rounded()
        let low = Int(min(Double(yours), max(0, near - Double(reach))))
        let high = Int(min(Double(yours), max(Double(low), near + Double(reach))))
        var options: [Landing] = []
        for index in low...high {
            if index >= keptIn {
                // Among today's, a search's folder one run: never between two
                // of its tabs without going in, in at its ends while open.
                let before = index > keptIn ? rest[index - 1].nest.flatMap { $0.today ? $0 : nil } : nil
                let after = index < rest.count ? rest[index].nest.flatMap { $0.today ? $0 : nil } : nil
                if before == nil || before !== after {
                    options.append(Landing(index: index, slot: 0, out: task, kept: false))
                }
                if !task {
                    for nest in [before, after].compactMap({ $0 }) where nest.open || nest === held.nest {
                        if options.contains(where: { $0.index == index && $0.nest == nest.id }) { continue }
                        options.append(Landing(index: index, slot: 0, kept: false, nest: nest.id))
                    }
                }
            }
            guard keepable, index <= keptIn else { continue }
            let before = index > 0 ? rest[index - 1].nest?.chain ?? [] : []
            let after = index < keptIn ? rest[index].nest?.chain ?? [] : []
            // Never between two tabs of one folder without going in: what
            // lands between them is in every folder both are in, and may be
            // in any open one of those either is in, deeper.
            var common = 0
            while common < before.count, common < after.count, before[common] === after[common] { common += 1 }
            if common == 0 {
                options.append(Landing(index: index, slot: 0, out: task, kept: true))
            }
            let shared = max(0, common - 1)
            for nest in before.dropFirst(shared) + after.dropFirst(shared) where nest.chain.allSatisfy(\.open) || nest === held.nest {
                if options.contains(where: { $0.index == index && $0.nest == nest.id }) { continue }
                options.append(Landing(index: index, slot: 0, out: task, kept: true, nest: nest.id))
            }
        }
        if task, let place = places[held.id], let folder = folder(place.folder) {
            let others = rest.indices.filter { folder.members.contains(rest[$0].id) }
            if let first = others.first, let last = others.last {
                options += (first...(last + 1)).map { Landing(index: $0, slot: 0) }
            } else {
                options.append(Landing(index: from, slot: 0))
            }
        }
        if shut, held.kept {
            options.append(Landing(index: from, slot: 0, kept: true, nest: held.nest?.id))
        }

        // Where the held one would be drawn at each place depends only on
        // what is above it there: worked out once down the list, each place
        // then costs nothing (see `slots`, which this follows).
        var prefix: [(slot: Int, lined: Bool)] = []
        prefix.reserveCapacity(rest.count + 1)
        var first: [String: Int] = [:]
        var slot = 0, lined = false
        var last: Tab.ID?
        // Where each folder's run ends among the rest, for the empty ones
        // drawn at its end.
        var ends: [String: Int] = [:]
        for (at, tab) in rest.enumerated() { for key in places[tab.id]?.chain ?? [] { ends[key] = at } }
        // Empty folders standing among the kept, over the run each heads:
        // a tab let go at a run's head goes above the folder over it.
        let stood = stands(in: rest)
        let endRows = emptyRows + stood.end.count
        var standsOver: [Int: Int] = [:]
        var begun: Set<String> = []
        for (at, tab) in rest.enumerated() {
            prefix.append((slot, lined))
            defer { last = tab.id }
            if !tab.kept, !lined {
                slot += Folders.lineRows + endRows
                lined = true
            }
            if !stood.before.isEmpty, tab.kept, begun.insert(run(tab)).inserted, let nests = stood.before[run(tab)] {
                slot += nests.count
                standsOver[at] = nests.count
            }
            guard let place = places[tab.id] else {
                if joined, let last, let pair = browser?.pair(of: tab.id), pair.second == tab.id, pair.first == last { continue }
                if !away.contains(tab.id) { slot += 1 }
                continue
            }
            for key in place.bare ? [] : place.chain.isEmpty ? [place.folder] : place.chain where first[key] == nil {
                first[key] = at
                slot += 1
            }
            if place.shown { slot += 1 }
            if place.more > 0 { slot += 1 }
            for key in place.chain where ends[key] == at && key != carried && folder(key)?.nest?.open == true {
                slot += trail[key]?.count ?? 0
            }
        }
        prefix.append((slot, lined))
        let depths = Dictionary(folders.compactMap { $0.nest.map { ($0.id, $0.depth) } }, uniquingKeysWith: { a, _ in a })

        var best = Landing(index: from, slot: now, kept: held.kept, nest: held.nest?.id)
        var gap = Double.infinity
        for var option in options {
            // Never between the two of a pair drawn as one row: they would
            // only be put back together after it, and the row drawn a slot
            // off where it lands.
            if joined, option.index > 0, option.index < rest.count, let pair = browser?.pair(of: rest[option.index].id),
               pair.second == rest[option.index].id, pair.first == rest[option.index - 1].id { continue }
            let at = min(option.index, rest.count)
            let above = prefix[at]
            var slot = above.slot
            // The line under the kept, before it, if it is the first of
            // today's; a folder's own row, before it, if it is the first of
            // that folder's (a task's, when it stays in its own).
            if !option.kept, !above.lined { slot += Folders.lineRows + endRows }
            // Into the folder whose run starts here, at its head: under the
            // empty folder standing over that run, as `slots` draws it.
            if let over = standsOver[at], let id = option.nest, let top = self.nest(id)?.chain.first,
               at < rest.count, run(rest[at]) == top.key { slot += over }
            // Staying in its folder under a folded space: no folder's row.
            if let id = option.nest, !(shut && option.kept) {
                for key in self.nest(id)?.chain.map(\.key) ?? [Nest.key(id)] where (first[key] ?? Int.max) >= at { slot += 1 }
            } else if task, !option.out, let place = places[held.id], (first[place.folder] ?? Int.max) >= at {
                slot += 1
            }
            option.slot = slot
            let seen = Double(slot)
            let off = abs(seen - want)
            let same = option.kept == held.kept && option.nest == held.nest?.id && !option.out
            let bestSame = best.kept == held.kept && best.nest == held.nest?.id && !best.out
            var better = off < gap - 0.001
            if !better, abs(off - gap) <= 0.001 {
                // Among equals: as deep as the hand asks at a folder's end,
                // then what it already is, then the least move.
                let deepness = option.nest.flatMap { depths[$0] } ?? 0, bestDeepness = best.nest.flatMap { depths[$0] } ?? 0
                if let deep, option.index == best.index, deepness != bestDeepness, abs(deepness - deep) != abs(bestDeepness - deep) {
                    better = abs(deepness - deep) < abs(bestDeepness - deep)
                } else if same != bestSame {
                    better = same
                } else {
                    better = abs(option.index - from) < abs(best.index - from)
                }
            }
            if better {
                gap = off
                best = option
            }
        }
        return best
    }

    /// Where a folder of yours, carried whole (its tabs tucked under it),
    /// goes if let go now: an index among the kept tabs not its own, never
    /// in another folder's run but into it, never under the line; the
    /// folder it goes in there, if any, as deep as the hand asks (`deep`,
    /// as for a tab); and the slot its row is drawn in there. Over a shut
    /// folder of yours, into it, at the end of its run.
    struct NestLanding: Equatable {
        var index: Int
        var slot: Int
        var parent: UUID?
        var into: UUID?
    }

    /// `drawn`: the folders' rows as the column draws them now, for an
    /// empty one in the hand (ColumnDrag.emptyDrawn); worked out here
    /// without it. `joined`: the two of a pair are one row, as `slots`
    /// draws them; counted as two, every place under a pair was measured a
    /// row low, and let go just above Clear it went into a folder above
    /// (#1037).
    func nestLanding(_ nest: Nest, want: Double, deep: Int? = nil, among loose: [Tab], joined: Bool = false,
                     current: NestLanding? = nil, drawn: [String: Int]? = nil) -> NestLanding {
        // A folder of today's lands among the kept as one of them (#440).
        let today = nest.today ? Set(loose.filter { $0.nest?.within(nest) == true }.map(\.id)) : []
        let rest = loose.filter { $0.nest?.within(nest) != true }
        let keptIn = rest.prefix(while: \.kept).count
        let levels = browser?.levels(nest) ?? 1
        func fits(_ parent: Nest?) -> Bool {
            guard let parent else { return true }
            return !parent.within(nest) && !parent.today && parent.depth + levels <= Nest.deepest
        }
        // Over a shut folder's row as drawn now: its middle takes it in, its
        // top and bottom put it just above or below that folder's run, as
        // Arc's line between two folders, so it can go between two shut
        // ones (#1981). The rows are as the column draws them: the one in
        // the hand where it was last shown going, the rest making way.
        var only: (index: Int, parent: Nest?)?
        if let current {
            let members = loose.filter { $0.nest?.within(nest) == true }
            let heads: [String: Int]
            if members.isEmpty, let drawn {
                heads = drawn
            } else if members.isEmpty {
                // An empty one is a row of its own among the rest, not one of
                // its tabs': out of where it stood, into the slot it is shown
                // going to. Measured where it stood, the rows under the hand
                // were a row off from those drawn, and every place between
                // two shut folders was inside one (#1981).
                let base = slots(rest, joined: joined, kept: today).folders
                let own = base[nest.key]
                heads = base.filter { $0.key != nest.key }.mapValues { at in
                    let without = own.map { at > $0 ? at - 1 : at } ?? at
                    return without >= current.slot ? without + 1 : without
                }
            } else {
                var order = rest
                order.insert(contentsOf: members, at: min(max(0, current.index), keptIn))
                heads = slots(order, joined: joined, moved: Set(members.map(\.id)), kept: today).folders
            }
            for folder in folders {
                guard let other = folder.nest, other !== nest, !other.open || folder.members.isEmpty, !other.today, fits(other),
                      let head = heads[folder.id] else { continue }
                let off = want - Double(head)
                // An empty one, or one open with only folders right in it,
                // has no shut run to be above or below: its whole row takes
                // it, as a held tab's does.
                guard !other.open, let start = rest.prefix(keptIn).firstIndex(where: { $0.nest?.within(other) == true }),
                      let end = rest.prefix(keptIn).lastIndex(where: { $0.nest?.within(other) == true }) else {
                    let reach = current.into == other.id ? 0.6 : 0.4
                    if abs(off) <= reach {
                        var into = current
                        into.into = other.id
                        return into
                    }
                    continue
                }
                guard abs(off) <= 0.5 else { continue }
                // Once in, a little more room to stay in than to come in.
                if abs(off) <= (current.into == other.id ? 0.3 : 0.25) {
                    var into = current
                    into.into = other.id
                    return into
                }
                if fits(other.parent) { only = (off < 0 ? start : end + 1, other.parent) }
                break
            }
        }
        // The rows above each place, as `landing` counts them.
        var prefix: [Int] = []
        var first: [String: Int] = [:]
        var ends: [String: Int] = [:]
        for (at, tab) in rest.prefix(keptIn).enumerated() { for key in places[tab.id]?.chain ?? [] { ends[key] = at } }
        // The empty folders standing over a run, the one in the hand (an
        // empty one carried) not among them: let go at a run's head, it goes
        // above the ones there.
        let stood = stands(in: rest) { $0.key == self.carried }
        var standsOver: [Int: Int] = [:]
        var begun: Set<String> = []
        var slot = 0
        var seen: Set<Tab.ID> = []
        var last: Tab.ID?
        // The second of a pair drawn as one row: no row of its own, as in
        // `slots` (after the first, or anywhere after it in a folder).
        func second(_ tab: Tab, placed: Bool) -> Bool {
            guard joined, let pair = browser?.pair(of: tab.id), pair.second == tab.id else { return false }
            return placed ? seen.contains(pair.first) : pair.first == last
        }
        for (at, tab) in rest.prefix(keptIn).enumerated() {
            prefix.append(slot)
            defer { seen.insert(tab.id); last = tab.id }
            if !stood.before.isEmpty, begun.insert(run(tab)).inserted, let nests = stood.before[run(tab)] {
                slot += nests.count
                standsOver[at] = nests.count
            }
            guard let place = places[tab.id] else {
                if !away.contains(tab.id), !second(tab, placed: false) { slot += 1 }
                continue
            }
            for key in place.chain where first[key] == nil {
                first[key] = at
                slot += 1
            }
            if place.shown, !second(tab, placed: true) { slot += 1 }
            if place.more > 0 { slot += 1 }
            for key in place.chain where ends[key] == at && folder(key)?.nest?.open == true {
                slot += trail[key]?.filter { $0.key != carried }.count ?? 0
            }
        }
        prefix.append(slot)
        var best = NestLanding(index: 0, slot: 0, parent: nest.parent?.id)
        var gap = Double.infinity
        // Over a shut folder's top or bottom: the place just above or below
        // its run, among the folders it is in, wherever the nearest is.
        for index in 0...keptIn where only.map({ $0.index == index }) ?? true {
            // Never between the two of a pair drawn as one row.
            if joined, index > 0, index < keptIn, let pair = browser?.pair(of: rest[index].id),
               pair.second == rest[index].id, pair.first == rest[index - 1].id { continue }
            let before = index > 0 ? rest[index - 1].nest?.chain ?? [] : []
            let after = index < keptIn ? rest[index].nest?.chain ?? [] : []
            var common = 0
            while common < before.count, common < after.count, before[common] === after[common] { common += 1 }
            let from = max(0, common - 1)
            var parents: [Nest?] = common == 0 ? [nil] : []
            for each in before.dropFirst(from) + after.dropFirst(from) where each.chain.allSatisfy(\.open) && fits(each) {
                if !parents.contains(where: { $0 === each }) { parents.append(each) }
            }
            for parent in parents where only.map({ $0.parent === parent }) ?? true {
                var at = prefix[index]
                for up in parent?.chain ?? [] where (first[up.key] ?? Int.max) >= index { at += 1 }
                if let over = standsOver[index], let top = parent?.chain.first, index < keptIn, run(rest[index]) == top.key { at += over }
                let off = abs(Double(at) - want)
                var better = off < gap - 0.001
                if !better, abs(off - gap) <= 0.001, index == best.index {
                    let deepness = parent?.depth ?? 0
                    let bestDeepness = best.parent.flatMap { id in self.nest(id)?.depth } ?? 0
                    if let deep, deepness != bestDeepness {
                        better = abs(deepness - deep) < abs(bestDeepness - deep)
                    } else {
                        better = parent?.id == nest.parent?.id
                    }
                }
                if better {
                    gap = off
                    best = NestLanding(index: index, slot: at, parent: parent?.id)
                }
            }
        }
        if only != nil, !gap.isFinite {
            return nestLanding(nest, want: want, deep: deep, among: loose, joined: joined, current: nil)
        }
        return best
    }

    /// Where a folder of today's, carried whole, goes among today's if let
    /// go now: before which tab (nil: after the last), never between two of
    /// another folder's tabs or the two of a pair, and above a task's
    /// folders; and the slot its row is drawn in there.
    struct TodayLanding: Equatable {
        var before: Tab.ID?
        var slot: Int
    }

    func todayLanding(_ nest: Nest, want: Double, among loose: [Tab], joined: Bool = false) -> TodayLanding {
        let rest = loose.filter { $0.nest?.within(nest) != true }
        let drawn = slots(rest, joined: joined)
        let keptIn = rest.prefix(while: \.kept).count
        let yours = rest.firstIndex { places[$0.id].map { !Nest.isKey($0.folder) } ?? false } ?? rest.count
        // The row a tab starts: its first folder's, or its own.
        func head(_ tab: Tab) -> Int? {
            guard let place = places[tab.id], !place.bare else { return drawn.tabs[tab.id] }
            return drawn.folders[place.chain.first ?? place.folder] ?? drawn.tabs[tab.id]
        }
        let line = (drawn.folders[Folders.line] ?? 0) + Folders.lineRows
        let end = max(line, rest[keptIn...].compactMap { drawn.tabs[$0.id] }.max().map { $0 + 1 } ?? line)
        var best = TodayLanding(before: nil, slot: end)
        var gap = Double.infinity
        for index in keptIn...max(keptIn, yours) {
            if index > keptIn, index < rest.count {
                let above = rest[index - 1], below = rest[index]
                if let inside = above.nest?.chain.first, below.nest?.within(inside) == true { continue }
                if let pair = browser?.pair(of: below.id), pair.second == below.id, pair.first == above.id { continue }
            }
            let slot = index < rest.count ? head(rest[index]) ?? end : end
            let off = abs(Double(slot) - want)
            if off < gap {
                gap = off
                best = TodayLanding(before: index < rest.count ? rest[index].id : nil, slot: slot)
            }
        }
        return best
    }

    /// Whether a folder's own row is drawn: every folder it is in open, and
    /// none of them in the hand.
    func drawn(_ key: String) -> Bool {
        guard let chain = folder(key)?.nest?.chain else { return folder(key) != nil }
        return chain.dropLast().allSatisfy { $0.open && $0.key != carried }
    }

    /// A folder of yours in this row, by its id: one with tabs, or empty.
    func nest(_ id: UUID) -> Nest? {
        folders.first { $0.nest?.id == id }?.nest ?? empties.first { $0.id == id }
    }

    /// Where it stands among the rows; one of the kept out of sight under a
    /// folded space in no folder of yours, tucked away as in a shut one.
    func place(of tab: Tab) -> Place? {
        if let place = places[tab.id] { return place }
        guard away.contains(tab.id) || turning.contains(tab.id) else { return nil }
        let seen = !away.contains(tab.id)
        return Place(folder: "", shown: seen, order: 0, listed: seen || spaceTurn != nil, depth: 0, bare: true)
    }

    /// In a task's folder, not one of yours among the kept (Kept.swift).
    func theirs(_ tab: Tab) -> Bool {
        guard let place = places[tab.id] else { return false }
        return folder(place.folder)?.nest == nil
    }

    func folder(_ id: String) -> Folder? { folders.first { $0.id == id } }

    /// A shut folder of yours still showing a tab under it, the one on
    /// screen, its pair or one asking: drawn half open, as Arc's, three dots
    /// on its front.
    func peeks(_ nest: Nest) -> Bool {
        !nest.open && places.values.contains { $0.shown && $0.chain.last == nest.key }
    }

    /// The minus targets this folder's rows, including opened tabs while
    /// another folder owns focus. Pages stay loaded and selection stays put.
    func unpeek(_ nest: Nest) {
        guard let browser, peeks(nest) else { return }
        withAnimation(Folders.clock(opening: false)) {
            unpeekedAt = browser.activeID
            unpeekedFolders.insert(nest.id)
            work()
        }
    }

    /// An explicit pick also reveals a tab already active but hidden by minus.
    func picked(_ tab: Tab) {
        let before = unpeekedFolders
        unpeekedFolders.subtract(tab.nest?.chain.map(\.id) ?? [])
        if before != unpeekedFolders { work() }
    }

    func isOpen(_ id: String) -> Bool {
        if let folder = folder(id) { return Folders.isOpen(folder, among: open) }
        return open.contains(id)
    }

    /// Yab's own work out of sight: its folder, made or still to come, never
    /// opens.
    func sealed(_ id: String) -> Bool {
        folder(id)?.sealed == true || Agents.shared.sealed(id)
    }

    /// How many more rows (or pills) the list draws than it has tabs: one
    /// for each folder and each "N more", the line's two, less the tabs tucked
    /// away.
    var extra: Int {
        folders.count - shutRows - tucked + (lined ? Folders.lineRows : 0) + places.values.filter { $0.more > 0 }.count
    }

    /// The empty folders of `empty` right in `parent` (nil: at the top of
    /// the kept), each followed by those in it while it is open.
    static func flat(_ empty: [Nest], under parent: Nest?, depth: Int = 0, hiding: String? = nil) -> [Nest] {
        guard depth <= Nest.deepest else { return [] }
        // The one in the hand (`hiding`) carries those in it, folded under it.
        return empty.filter { $0.parent === parent }.flatMap { [$0] + ($0.open && $0.key != hiding ? flat(empty, under: $0, depth: depth + 1, hiding: hiding) : []) }
    }

    /// For each folder with tabs that has empty ones in it (`living`, by
    /// id), those drawn at the end of its run.
    static func trails(_ empty: [Nest], living: Set<UUID>, hiding: String? = nil) -> [String: [Nest]] {
        var out: [String: [Nest]] = [:]
        for nest in empty {
            guard let up = nest.parent, living.contains(up.id), out[up.key] == nil else { continue }
            out[up.key] = flat(empty, under: up, hiding: hiding)
        }
        return out
    }

    /// The empty folders drawn just above the line: those at the top of the
    /// kept, and those in them.
    var block: [Nest] {
        guard !shut else { return [] }
        let stood = Set(standing.map(\.nest.id))
        return Folders.flat(empties.filter { !$0.today && !stood.contains($0.id) }, under: nil, hiding: carried)
    }

    /// The empty folders' rows, drawn just above the line.
    private var emptyRows: Int { block.count }

    var todayBlock: [Nest] {
        Folders.flat(empties.filter { $0.ordinaryToday && todayAnchor($0) == nil }, under: nil, hiding: carried)
    }

    /// Empty Today folders can stand before a Today run, just as kept
    /// empty folders stand before a kept run. A departed anchor means end.
    private func todayAnchor(_ nest: Nest) -> Tab.ID? {
        guard let before = nest.stand?.before,
              let tab = browser?.tabs.first(where: { $0.id == before && !$0.kept && $0.pin == nil }) else { return nil }
        return tab.id
    }

    var todayAhead: [Tab.ID: [Nest]] {
        var out: [Tab.ID: [Nest]] = [:]
        for nest in empties where nest.ordinaryToday && nest.parent == nil {
            guard let anchor = todayAnchor(nest) else { continue }
            out[anchor, default: []] += [nest] + (nest.open && nest.key != carried ? Folders.flat(empties, under: nest, hiding: carried) : [])
        }
        return out
    }

    // MARK: - empty folders

    /// A run among the kept, as an empty folder stands above one: a folder
    /// of yours at the top of the kept, by its key, or a tab in none.
    func run(_ tab: Tab) -> String {
        tab.nest?.chain.first.map(\.key) ?? "tab:" + tab.id.uuidString
    }

    /// The kept tabs in `order` that head a row of their own or a folder's
    /// run, the places an empty folder can stand above; none in `skip`, and
    /// no second of a pair, which shares its first's row.
    func heads(_ order: [Tab], skip: Set<Tab.ID> = []) -> [Tab.ID] {
        var out: [Tab.ID] = []
        var last: Tab?
        for tab in order where tab.pin == nil && tab.kept && !skip.contains(tab.id) {
            defer { last = tab }
            if let last, let pair = browser?.pair(of: tab.id), pair.second == tab.id, pair.first == last.id { continue }
            if let top = tab.nest?.chain.first, let last, last.nest?.chain.first === top { continue }
            out.append(tab.id)
        }
        return out
    }

    /// The head an empty folder stands above now, nil for the kept's end:
    /// the one it stood above, unless that one moved away (`moved`, the
    /// tabs a drag or a move just put elsewhere) or went, when it is the
    /// head under the one it was under, as Arc's folder stays where it was
    /// put (feedback #384). Told nothing of what moved, the one it stood
    /// over is taken as moved when neither row beside it is the same.
    static func resolve(_ stand: Nest.Stand, heads: [UUID], at: [UUID: Int], moved: Set<UUID> = []) -> UUID? {
        func after(_ head: UUID?) -> UUID? {
            guard let head else { return heads.first }
            guard let index = at[head] else { return nil }
            return index + 1 < heads.count ? heads[index + 1] : nil
        }
        if let index = at[stand.before] {
            let above = index > 0 ? heads[index - 1] : nil
            let below = index + 1 < heads.count ? heads[index + 1] : nil
            if above == stand.after { return stand.before }
            if !moved.isEmpty, !moved.contains(stand.before) { return stand.before }
            if moved.isEmpty, below == stand.next { return stand.before }
            if stand.after == nil || stand.after.flatMap({ at[$0] }) != nil { return after(stand.after) }
            return stand.before
        }
        if stand.after == nil || stand.after.flatMap({ at[$0] }) != nil { return after(stand.after) }
        if let next = stand.next, at[next] != nil { return next }
        return nil
    }

    static func stand(before head: UUID, heads: [UUID], at: [UUID: Int]) -> Nest.Stand {
        let index = at[head] ?? 0
        return Nest.Stand(before: head, after: index > 0 ? heads[index - 1] : nil,
                          next: index + 1 < heads.count ? heads[index + 1] : nil)
    }

    /// Where each standing empty folder is drawn among `order`: by the run
    /// it stands above, or at the kept's end. One standing above a tab in
    /// `skip`, one held or a folder in the hand, stays under the head
    /// above, as it will once that is let go somewhere else. `hiding`: one
    /// not drawn here (a held tab going into it, or the one carried).
    func stands(in order: [Tab], skip: Set<Tab.ID> = [], hiding: (Nest) -> Bool = { _ in false }) -> (before: [String: [Nest]], end: [Nest]) {
        guard !standing.isEmpty else { return ([:], []) }
        let heads = self.heads(order, skip: skip)
        let at = Dictionary(heads.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var before: [String: [Nest]] = [:]
        var end: [Nest] = []
        for each in standing {
            let rows = each.rows.filter { !hiding($0) }
            guard !rows.isEmpty, let stand = each.nest.stand else { continue }
            if let head = Folders.resolve(stand, heads: heads, at: at, moved: skip), let tab = byID[head] {
                before[run(tab), default: []] += rows
            } else {
                end += rows
            }
        }
        return (before, end)
    }

    /// An empty folder at the top of the kept put just above `head` (a
    /// kept tab heading a row or a folder's run), first of any standing
    /// there; nil: at the kept's end, after the others there.
    func stand(_ nest: Nest, before head: Tab.ID?) {
        guard let browser else { return }
        let heads = self.heads(browser.tabs)
        let at = Dictionary(heads.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        nest.stand = head.flatMap { at[$0] != nil ? Folders.stand(before: $0, heads: heads, at: at) : nil }
        var list = emptyBySpace[browser.spaceID] ?? []
        guard let from = list.firstIndex(where: { $0 === nest }) else { return }
        list.remove(at: from)
        let to = nest.stand.flatMap { stand in list.firstIndex { $0.parent == nil && $0.stand?.before == stand.before } } ?? list.count
        list.insert(nest, at: to)
        emptyBySpace[browser.spaceID] = list
        saveEmpties()
        work()
    }

    /// The native empty-only block's explicit sibling gap. Recheck the
    /// complete current block so an anchor removed or changed during a drag
    /// cannot turn a before-sibling drop into an accidental append.
    @discardableResult
    func reorderEmptyBlock(_ nest: Nest, before anchor: UUID?, expected: [UUID]) -> Bool {
        guard let browser, !shut, !browser.tabs.contains(where: { $0.pin == nil && $0.kept }) else { return false }
        var list = emptyBySpace[browser.spaceID] ?? []
        guard list.count > 1, list.map(\.id) == expected, block.map(\.id) == expected,
              list.allSatisfy({ $0.parent == nil && $0.stand == nil && !$0.today }),
              !browser.tabs.contains(where: { tab in list.contains { tab.nest?.within($0) == true } }),
              let from = list.firstIndex(where: { $0 === nest }), anchor != nest.id else { return false }
        if let anchor, !list.contains(where: { $0.id == anchor }) { return false }
        list.remove(at: from)
        let to = anchor.flatMap { id in list.firstIndex { $0.id == id } } ?? list.count
        list.insert(nest, at: to)
        emptyBySpace[browser.spaceID] = list
        saveEmpties()
        work()
        return true
    }

    /// Where a tab put in `nest` goes among `kept` when the folder has no
    /// tab yet and stands among the kept: just above the run it stands over.
    func standIndex(for nest: Nest, in kept: [Tab]) -> Int? {
        guard let top = nest.chain.first, top.parent == nil, let head = top.stand?.before,
              empties.contains(where: { $0 === top }), !kept.contains(where: { $0.nest?.within(top) == true }) else { return nil }
        return kept.firstIndex { $0.id == head }
    }

    /// New Folder with nothing in it, at the end of the kept, or of the run
    /// of the folder of yours it is made in.
    @discardableResult
    func makeEmpty(named name: String = "New Folder", live: Live? = nil, in parent: Nest? = nil) -> Nest? {
        guard let browser else { return nil }
        let nest = Nest(name: name, open: true)
        nest.live = live
        nest.parent = parent
        emptyBySpace[browser.spaceID, default: []].append(nest)
        saveEmpties()
        work()
        return nest
    }

    /// A live folder whose last tab went: kept as an empty one, still live,
    /// for the next to come into.
    func keepEmpty(_ nest: Nest, space: UUID) {
        guard !(emptyBySpace[space] ?? []).contains(where: { $0 === nest }) else { return }
        emptyBySpace[space, default: []].append(nest)
        saveEmpties()
        work()
    }

    /// Empty folders gone with their folder to another space (Browser.moveFolder),
    /// or back: out of `from`'s list, at the end of `to`'s.
    func send(_ nests: [Nest], from: UUID, to: UUID) {
        guard !nests.isEmpty else { return }
        emptyBySpace[from]?.removeAll { nest in nests.contains { $0 === nest } }
        emptyBySpace[to, default: []] += nests.filter { nest in !(emptyBySpace[to] ?? []).contains { $0 === nest } }
        saveEmpties()
        work()
    }

    /// Remove Folder, an empty one, and the empty ones in it.
    func removeEmpty(_ nest: Nest) {
        guard let browser else { return }
        emptyBySpace[browser.spaceID]?.removeAll { $0.within(nest) }
        saveEmpties()
        work()
    }

    /// The empty folders as they were, for ⌘Z (WindowUndo.swift).
    func putEmpties(_ nests: [Nest]) {
        guard let browser, (emptyBySpace[browser.spaceID] ?? []).map(ObjectIdentifier.init) != nests.map(ObjectIdentifier.init) else { return }
        emptyBySpace[browser.spaceID] = nests
        saveEmpties()
        work()
    }

    /// An empty folder's name or state changed: written.
    func emptyChanged(_ nest: Nest) {
        if empties.contains(where: { $0 === nest }) { saveEmpties() }
    }

    private struct EmptyEntry: Codable {
        var id: String
        var name: String
        var open: Bool
        /// A live folder with nothing in it just now: still live.
        var live: Live? = nil
        var customMark: String? = nil
        var color: String? = nil
        var ordinaryToday: Bool? = nil
        /// The folders it is in, from the top down (Nest.path): another
        /// empty one, or one whose tabs hold it in the session.
        var path: [Session.Step]? = nil
        /// Where it stands among the kept (Nest.stand): nil at the end.
        var before: String? = nil
        var after: String? = nil
        var next: String? = nil
    }

    static func readEmpties(from emptiesFile: URL) -> [UUID: [Nest]] {
        guard let data = try? Data(contentsOf: emptiesFile),
              let all = try? JSONDecoder().decode([String: [EmptyEntry]].self, from: data) else { return [:] }
        var out: [UUID: [Nest]] = [:]
        for (space, entries) in all {
            guard let space = UUID(uuidString: space) else { continue }
            let nests = entries.map { entry in
                let nest = Nest(id: UUID(uuidString: entry.id) ?? UUID(), name: entry.name, open: entry.open)
                nest.live = entry.live
                nest.customMark = entry.customMark
                nest.color = entry.color
                nest.ordinaryToday = entry.ordinaryToday == true
                if let before = entry.before.flatMap(UUID.init(uuidString:)) {
                    nest.stand = Nest.Stand(before: before, after: entry.after.flatMap(UUID.init(uuidString:)),
                                            next: entry.next.flatMap(UUID.init(uuidString:)))
                }
                return nest
            }
            // In the folders their paths name: another of these by its id,
            // else one made for now, which the session's own takes over
            // once its tabs are read (`work`).
            var known = Dictionary(nests.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            for (nest, entry) in zip(nests, entries) where entry.path != nil {
                nest.file(in: entry.path, nests: &known)
                for each in nest.chain where nest.ordinaryToday { each.ordinaryToday = true }
            }
            out[space] = nests
        }
        return out
    }

    private func saveEmpties() {
        guard let emptiesFile else { return }
        var all: [String: [EmptyEntry]] = [:]
        for (space, nests) in emptyBySpace where !nests.isEmpty {
            all[space.uuidString] = nests.map {
                EmptyEntry(id: $0.id.uuidString, name: $0.name, open: $0.open, live: $0.live, customMark: $0.customMark, color: $0.color, ordinaryToday: $0.ordinaryToday ? true : nil, path: $0.path,
                           before: $0.stand?.before.uuidString, after: $0.stand?.after?.uuidString, next: $0.stand?.next?.uuidString)
            }
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: emptiesFile, options: .atomic)
        // The other windows' columns, the same empty folders.
        shelf.folders.removeAll { $0.folders == nil }
        for other in shelf.folders.compactMap(\.folders) + [Folders.shared] where other !== self && other.shelf === shelf { other.soon() }
    }

    /// Opened or shut. Its tucked rows are out of the column's list at rest,
    /// and a row put into a lazy list is drawn at once, as it ends: so they
    /// come into the list first, folded, and open a turn of the run loop
    /// later; shut, they fold first and leave the list once folded.
    /// `alongside`: what moves with it, on its clock, once its rows have
    /// changed: a row in a drag kept under the hand as they open above it.
    /// What a folder opening or shutting moves on.
    static func clock(opening: Bool) -> Animation {
        opening ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22) : .easeOut(duration: 0.14)
    }

    /// ⌥ with it: the folders in it open or shut with it, as Finder's
    /// outline does.
    func tap(_ nest: Nest) {
        // The press's own time, as Browser.tapTab reads it: the first
        // click's open or shut can hold the main thread past the
        // double-click interval in a long session, and the second click
        // then read as a new single, so a folder could not be named by a
        // double-click (feedback #1910).
        let event = NSApp.currentEvent
        let now = event.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } == true
            ? event!.timestamp : ProcessInfo.processInfo.systemUptime
        let second = lastNestTap.map { $0.id == nest.id && now - $0.at < NSEvent.doubleClickInterval } == true
        lastNestTap = second ? nil : (nest.id, now)
        toggle(nest.key, deep: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        if second { naming = nest.id }
    }

    /// Open All Inside or Close All Inside: the folder and every folder in
    /// it, open or shut, `open` what they all become.
    func openAll(_ nest: Nest, _ opening: Bool) {
        let inner = (browser?.nests ?? []).filter { $0 !== nest && $0.within(nest) }
        if opening { unpeekedFolders.subtract(([nest] + inner).map(\.id)) }
        if nest.open != opening {
            for each in inner where each.open != opening { each.open = opening }
            toggle(nest.key)
        } else if inner.contains(where: { $0.open != opening }) {
            withAnimation(Folders.clock(opening: opening)) {
                for each in inner {
                    each.open = opening
                    emptyChanged(each)
                }
                work()
            }
            if BrowserWindows.shared.browsers.count > 1 { browser?.writeSession(now: true) } else { browser?.rememberSession() }
        }
    }

    func toggle(_ id: String, deep: Bool = false, alongside: (() -> Void)? = nil) {
        // A sealed folder stays shut, whoever asks: a click, its menu, the
        // bench.
        guard !sealed(id) else { return }
        let nest = folder(id)?.nest
        // Opened or shut by hand, or once: no longer open just for being new.
        nest?.opened = false
        let opening = !(nest?.open ?? open.contains(id))
        turns += 1
        let turn = turns
        folding[id] = turn
        // ⌥: the folders in it go the same way, on the same clock.
        let inner = deep ? (nest.map { nest in (browser?.nests ?? []).filter { $0 !== nest && $0.within(nest) } } ?? []) : []
        for each in inner { folding[each.key] = turn }
        // What is below the folder moves on the same clock as its rows; the
        // rows themselves each keep their turn (FolderRowPlace).
        let change = { [self] in
            withAnimation(Folders.clock(opening: opening)) {
                if let nest {
                    nest.open = opening
                    if opening { unpeekedFolders.remove(nest.id) }
                    emptyChanged(nest)
                    for each in inner {
                        each.open = opening
                        if opening { unpeekedFolders.remove(each.id) }
                        emptyChanged(each)
                    }
                } else if opening {
                    open.insert(id)
                } else {
                    open.remove(id)
                    whole.remove(id)
                }
                work()
                alongside?()
            }
            // Every window of the space opens or shuts it (KeptEverywhere.swift).
            if nest?.today == false, BrowserWindows.shared.browsers.count > 1 { browser?.writeSession(now: true) }
            // Out of the list again once nothing moves: taking a long list
            // apart is a pass of its own, never one to have in a motion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, folding[id] == turn else { return }
                folding[id] = nil
                for each in inner where folding[each.key] == turn { folding[each.key] = nil }
                work()
            }
        }
        if opening {
            work()
            DispatchQueue.main.async(execute: change)
        } else {
            change()
        }
        if nest != nil {
            browser?.rememberSession()
        } else {
            Agents.shared.session(id)?.looked = Date()
        }
    }

    // MARK: - a space folded under its name

    /// Whether `space` is folded under its name: only where its name is
    /// there to unfold it: in the column, with spaces on.
    func isShut(_ space: UUID, in browser: Browser) -> Bool {
        shutSpaces.contains(space) && browser.prefs.sidebar && browser.namesSpaces
            && space != Space.mailID
    }

    /// The space's name clicked: its kept tabs fold away under it, or come
    /// back, on a folder's clock. Either way they are in the list as they
    /// are first, each with a place to fold in, and fold or open a turn of
    /// the run loop later; once still, the folded leave the list (see
    /// `toggle`).
    func toggleSpace() {
        guard let browser else { return }
        let id = browser.spaceID
        let opening = shutSpaces.contains(id)
        turns += 1
        let turn = turns
        spaceTurn = turn
        work()
        DispatchQueue.main.async { [self] in
            withAnimation(Folders.clock(opening: opening)) {
                if opening { shutSpaces.remove(id) } else { shutSpaces.insert(id) }
                work()
            }
            Folders.writeShut(shutSpaces)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, spaceTurn == turn else { return }
                spaceTurn = nil
                work()
            }
        }
    }

    /// Unfolded at once, for what is about to be made among the kept: a
    /// new folder, its name to be typed.
    func unfoldSpace() {
        guard let browser, shutSpaces.contains(browser.spaceID) else { return }
        shutSpaces.remove(browser.spaceID)
        Folders.writeShut(shutSpaces)
        work()
    }

    private static let shutKey = "spaces.folded"

    static func readShut() -> Set<UUID> {
        Set((Store.settings.stringArray(forKey: shutKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func writeShut(_ spaces: Set<UUID>) {
        if spaces.isEmpty {
            Store.settings.removeObject(forKey: shutKey)
        } else {
            Store.settings.set(spaces.map(\.uuidString).sorted(), forKey: shutKey)
        }
    }

    /// "N more" clicked: the folder's other tabs come out under the ones
    /// shown, in turn, as an opening folder's do: into the list first,
    /// folded, then out a turn of the run loop later (see `toggle`).
    func showAll(_ id: String) {
        guard open.contains(id), !whole.contains(id) else { return }
        turns += 1
        let turn = turns
        folding[id] = turn
        work()
        DispatchQueue.main.async { [self] in
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) {
                whole.insert(id)
                work()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, folding[id] == turn else { return }
                folding[id] = nil
                work()
            }
        }
    }

    /// On one of a task's tabs is looking at it. Gone from a search's
    /// folder that is open only because it was just started: it shuts.
    private func looked(at id: Tab.ID?) {
        let tab = id.flatMap { id in browser?.tabs.first { $0.id == id } }
        // A live folder's tab opened: what it says, seen.
        if let tab, var mark = tab.live, mark.seen != mark.words || mark.heard != mark.said {
            mark.seen = mark.words
            mark.heard = mark.said
            tab.live = mark
            work()
        }
        let nest = tab?.nest
        for folder in folders {
            guard let born = folder.nest, born.research, born.opened, born.open, born !== nest else { continue }
            born.opened = false
            toggle(born.key)
        }
        guard let id, let place = places[id], !Nest.isKey(place.folder) else { return }
        Agents.shared.session(place.folder)?.looked = Date()
    }

    // MARK: - a search's folders

    /// Just started from a results page (Research.swift): drawn open, the
    /// new tab under the results page.
    func born(_ nest: Nest) {
        work()
        watchIdle()
    }

    /// How long a search's folder is left alone before it shuts and its
    /// tabs sleep.
    nonisolated static let idle: TimeInterval = 20 * 60

    private var idleClock: Timer?

    /// Looked at once a minute while there are search folders.
    private func watchIdle() {
        guard idleClock == nil else { return }
        idleClock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fold() }
        }
    }

    /// Every search's folder left alone long enough: shut, its tabs asleep.
    /// The row is as it was; a click opens it with them where they were.
    func fold(now: Date = Date()) {
        guard let browser else { return }
        let nests = folders.compactMap { $0.nest }.filter { $0.today && !$0.ordinaryToday }
        if nests.isEmpty {
            idleClock?.invalidate()
            idleClock = nil
            return
        }
        for nest in nests where nest.open {
            let members = browser.tabs.filter { $0.nest === nest }
            guard !members.contains(where: { browser.onScreen($0.id) }),
                  let last = members.map(\.touched).max(), now.timeIntervalSince(last) >= Folders.idle else { continue }
            nest.opened = false
            toggle(nest.key)
            let asleep = members.filter { !$0.asleep }
            if browser.canSleep(asleep) { browser.sleep(asleep) }
        }
    }

    /// An agent's new tab goes after its task's others, so the folder
    /// stays one run.
    func file(_ tab: Tab, in browser: Browser) {
        let agents = Agents.shared
        guard let root = agents.root(of: tab.agent) else { return }
        let others = browser.tabs.filter { $0.id != tab.id && $0.pin == nil && $0.bench && $0.agent != nil && agents.root(of: $0.agent) == root }
        guard let last = others.last, let at = browser.tabs.firstIndex(where: { $0.id == last.id }),
              let here = browser.tabs.firstIndex(where: { $0.id == tab.id }), here != at + 1 else { return }
        browser.move(tab, to: here > at ? at + 1 : at)
    }

    /// A click on a task's folder: opened or shut. A sealed one never opens:
    /// its chat comes out instead, for what it does, when it has one (the
    /// morning look keeps none, and a click on it does nothing).
    static func tapped(_ folder: Folder, in browser: Browser) {
        guard folder.sealed else {
            shared.toggle(folder.id)
            return
        }
        if Agents.shared.hasChat(folder.id) { browser.showChat(folder.id) }
    }

    /// A folder's cross, or Close Tabs from its menu: its task stopped and
    /// its tabs closed. Asked first while the task is still at work, since
    /// that can't be taken back; done and waiting on nothing, it just goes.
    static func close(_ folder: Folder, in browser: Browser) {
        let shut = {
            _ = Agents.shared.stop(folder.id)
            for id in folder.members { if let tab = browser.tabs.first(where: { $0.id == id }) { browser.close(tab) } }
        }
        guard Agents.shared.session(folder.id)?.working == true else { return shut() }
        let count = folder.members.count
        let question = Question(title: "Stop this task?",
                                detail: "It is still working. \(count == 1 ? "Its tab closes" : "Its \(count) tabs close") with it.",
                                glyph: "xmark", yes: "Stop and Close", danger: true)
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            shut()
        }
    }

    /// Out of the task and into your tabs: it loses the face, joins your
    /// session and history, and isn't put away with the task's.
    func keep(_ tab: Tab) {
        // Nothing of a sealed task's comes out to you.
        guard !Agents.shared.sealed(tab) else { return }
        AgentFeed.shared.read(tab)
        AgentFeed.shared.handBack(tab)
        if tab.handoff != nil || !tab.choices.isEmpty { Agents.taken.insert(tab.id) }
        tab.handoff = nil
        tab.handoffDetail = nil
        tab.choices = []
        tab.agent = nil
        tab.adopt()
        work()
    }

    /// An explicit handover, persisted in the owning window's session.
    func keep(_ tabs: [Tab], in browser: Browser) {
        for tab in tabs where tab.agent != nil && !Agents.shared.sealed(tab) { keep(tab) }
        refresh()
        browser.writeSession(now: true)
    }

    /// The page you asked an agent to open (`show`): kept, where a new
    /// tab of yours goes, in the space whose sign-ins it carries, and in
    /// front of you. A tab of yours is only brought to the front.
    func show(_ tab: Tab, in browser: Browser) {
        if tab.bench {
            if tab.store !== Spaces.store(for: browser.spaceID),
               let home = browser.spaces.first(where: { Spaces.store(for: $0.id) === tab.store }) {
                browser.switchSpace(to: home.id)
            }
            keep(tab)
            browser.move(tab, to: min(browser.keptEnd, browser.tabs.count - 1))
        }
        browser.select(tab)
    }

    /// The task's name, as the folder shows it; a folder of yours, its own.
    static func title(_ id: String) -> String {
        if Nest.isKey(id) { return shared.folder(id)?.nest?.name ?? "Folder" }
        guard let session = Agents.shared.session(id) else { return "Agent" }
        return title(of: session)
    }

    /// A task's folder's name: Yab's own work goes by what it is for, fixed,
    /// whatever the agent calls itself; any other task by the name it gave,
    /// else its prompt's first line.
    static func title(of session: Agents.Session) -> String {
        if let words = own(session) { return words.title }
        if let title = session.title, !title.isEmpty { return title }
        let line = session.prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? session.name : line
    }

    /// What stops a sealed task, in its folder's menu.
    static func stopping(_ session: Agents.Session) -> String {
        own(session)?.stop ?? "Stop Task"
    }

    /// Yab's own work, in its words: Get to Know, and the morning look.
    private static func own(_ session: Agents.Session) -> (title: String, stop: String)? {
        if session.sealed, session.knowing { return ("Getting to know you", "Stop Getting to Know You") }
        if session.quiet, session.name == "Looking" { return ("Catching up", "Stop Catching Up") }
        return nil
    }
}

// MARK: - the mark

/// A task folder wearing its agent's
/// eyes at work and a raised hand when the task needs you. Open, its front
/// lets down and outward and carries the eyes with it (AgentFace, `folder`).
struct FolderMark: View {
    /// The tab whose agent the folder speaks for: the one asking, if one is.
    let tab: Tab?
    var open: Bool
    var size: CGFloat = 18
    /// Column drawing size, independent of its mark slot.
    var drawingSize: CGFloat? = nil
    var weight: CGFloat? = nil
    var tint: Color = Palette.ink
    /// At rest, one picture (StillFace).
    var still = false
    /// The one site a task works on (Folders.site): its icon in the
    /// folder's place, the agent's face staying at the row's end.
    var site: Tab? = nil

    var body: some View {
        if let site {
            FolderSiteMark(tab: site)
                .frame(width: size, height: size)
        } else if let tab {
            AgentFace(tab: tab, size: drawingSize ?? size, tint: tint, tip: false, folder: true, unfolded: open, still: still, weight: weight)
                .frame(width: size, height: size)
        } else if still {
            StillFace(pose: .seen, size: drawingSize ?? size, tint: tint, folder: true, unfolded: open, weight: weight)
                .frame(width: size, height: size)
        } else {
            Face(pose: .seen, size: drawingSize ?? size, tint: tint, folder: true, unfolded: open, weight: weight)
                .frame(width: size, height: size)
        }
    }
}

/// A site's own mark, kept up as its icon comes.
private struct FolderSiteMark: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Mark(icon: tab.displayIcon, letter: tab.monogram, size: SideBar.mark)
    }
}

// MARK: - in the column

/// A folder's own row: the mark, the task's name, the task's face. A click
/// opens or shuts it and never changes the page; a sealed one's shows its
/// chat, and resting on it says its step, never its pages.
struct FolderRow: View {
    @ObservedObject var browser: Browser
    let folder: Folders.Folder
    let open: Bool
    /// Where its tabs are, when not in the space on screen: a space's row
    /// drawn before it comes (PagedSpace).
    var among: [Tab]? = nil

    @ObservedObject private var agents = Agents.shared
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    /// In a cell of the AppKit column: where it stands is the page's to say.
    @Environment(\.columnHosted) private var hosted
    @State private var hovering = false

    private var session: Agents.Session? { agents.session(folder.id) }
    private var asking: Bool { !folder.asking.isEmpty }
    /// The cross is out: a sealed folder's tabs are Yab's, not yours to close.
    private var closing: Bool { hovering && !folder.sealed }
    /// The task's face: on its own tab if it has one there, else the first.
    private var face: Tab? {
        let row = among ?? browser.tabs
        let tabs = folder.members.compactMap { id in row.first { $0.id == id } }
        // Asking, the face is the hand of the tab that asks.
        return tabs.first { folder.asking.contains($0.id) } ?? tabs.first { $0.agent == folder.id } ?? tabs.first
    }
    /// The face at its end, muted at rest; the name is always in the
    /// space's deepest shade, a step heavier than a tab's, as Arc's are.
    private var color: Color {
        asking || hovering ? Palette.strong(on: tone) : Palette.muted(on: tone)
    }

    var body: some View {
        let _ = SpacePager.touched()
        HStack(spacing: 8) {
            FolderMark(tab: face, open: open && !folder.sealed, drawingSize: SideBar.folder, weight: SideBar.folderWeight, tint: color, site: Folders.site(folder, among: among ?? browser.tabs))
            FadingTitle(text: Folders.title(folder.id), font: .system(size: titleSize, weight: .medium), color: Palette.strong(on: tone), clear: 0, fade: 28)
                .equatable()
            FolderNeeds(folder: folder)
            // Under the pointer the cross takes the end, as a tab's does,
            // and the face steps left of it; with no face, the cross is
            // where it would be.
            HStack(spacing: TabEnd.beside - 15) {
                if !closing || FolderEnd.shows(folder) {
                    FolderEnd(folder: folder, face: face, tint: color)
                }
                if closing {
                    FolderCross { browser.glance.drop(); Folders.close(folder, in: browser) }
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, SideBar.endInset)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if hovering || asking {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(Palette.hover(on: tone))
            }
        }
        // Asking, it stands up a little off the column.
        .offset(y: asking ? -1 : 0)
        .shadow(color: .black.opacity(asking ? 0.08 : 0), radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .globalFrame(!hosted) { frame in
            // A space's page drawing it isn't where its preview comes out.
            guard among == nil, !hosted else { return }
            browser.glance.folderFrames[folder.id] = frame
        }
        .onTapGesture { Folders.tapped(folder, in: browser) }
        // Rested on, shut, its preview comes out beside the column; a
        // sealed one's pages are nobody's to see.
        .onHover { on in
            hovering = on
            if !folder.sealed { browser.glance.hoverFolder(folder.id, on) }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: asking)
        .steadyMenu(actions: true) { FolderMenu(folder: folder, browser: browser) }
        .pointerTip(FolderEnd.tip(folder, session: session))
    }
}

/// The end of a task's folder: the hand while it asks, its face while it
/// works, then the tick while it left tabs you haven't come to (looking
/// down where one couldn't finish), and nothing once you have.
struct FolderEnd: View {
    let folder: Folders.Folder
    let face: Tab?
    let tint: Color
    /// At rest, one picture (StillFace).
    var still = false
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        ZStack {
            if let face, !folder.asking.isEmpty || agents.session(folder.id)?.working == true {
                AgentFace(tab: face, tint: tint, still: still)
            } else if let pose = folder.over {
                Group {
                    if still { StillFace(pose: pose, size: 15, tint: tint) } else { Face(pose: pose, size: 15, tint: tint) }
                }
                    .transition(.opacity)
            }
        }
        .frame(width: 15, height: 15)
        .animation(Motion.quick, value: folder.over)
    }

    /// Something is drawn: the hand, the face, or the tick.
    static func shows(_ folder: Folders.Folder) -> Bool {
        !folder.asking.isEmpty || Agents.shared.session(folder.id)?.working == true || folder.over != nil
    }

    /// Its step in words, and once it is over, what is left to look at.
    static func tip(_ folder: Folders.Folder, session: Agents.Session?) -> String {
        guard let session else { return "" }
        let said = AgentDock.say(session.now, name: session.name)
        guard !session.state.live, folder.unread > 0 else { return said }
        return "\(said) · \(folder.unread == 1 ? "1 tab" : "\(folder.unread) tabs") not opened yet"
    }
}

/// Beside a folder's name: "Needs you" while a task asked in words waits
/// on you, else nothing. Working, done or stopped is the face's to show
/// (its eyes, the tick): words there only pushed the name out.
struct FolderNeeds: View {
    let folder: Folders.Folder
    @ObservedObject private var agents = Agents.shared
    @Environment(\.tone) private var tone

    static func words(_ folder: Folders.Folder, session: Agents.Session?) -> String? {
        guard let session, session.task, !folder.sealed, !folder.asking.isEmpty else { return nil }
        return "Needs you"
    }

    var body: some View {
        let session = agents.session(folder.id)
        if let words = FolderNeeds.words(folder, session: session) {
            Text(words)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(folder.asking.isEmpty ? Palette.faint(on: tone) : Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2), value: words)
        }
    }
}

/// The cross at a folder's end under the pointer: a tab's own (TabEnd),
/// drawn the same, its square only under the pointer, its reach the whole
/// height of the row. A download's card in the column's stack wears it
/// too, as Cancel (HoardStack).
struct FolderCross: View {
    let close: () -> Void
    var label = "Close Folder"
    @State private var pressed = false
    @State private var on = false
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: close) {
            // A tab's cross at the column's density (RowPlate).
            MinusCross(open: 1)
                .stroke(style: StrokeStyle(lineWidth: RowPlate.column.cross / 8, lineCap: .round))
                .frame(width: RowPlate.column.cross, height: RowPlate.column.cross)
                .foregroundStyle(on ? Palette.ink.opacity(0.75) : Palette.muted(on: tone))
                .frame(width: 15, height: 15)
                .background {
                    if on { RowPlate.column.square() }
                }
                .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
                .animation(pressed ? Press.down : Press.up, value: pressed)
                .frame(width: 20, height: SideBar.row)
                .contentShape(Rectangle())
                .frame(width: 15, height: 15)
        }
        .buttonStyle(Held(pressed: $pressed))
        .onHover { on = $0 }
        .keyTip(label)
        .accessibilityLabel(label)
    }
}

/// What a folder's right-click offers.
struct FolderMenu: View {
    let folder: Folders.Folder
    let browser: Browser

    var body: some View {
        if folder.sealed {
            sealed
        } else {
            let open = browser.folderBook.isOpen(folder.id)
            Button(open ? "Close Folder" : "Open Folder", mark: open ? "yab.folder.closed" : "yab.folder.open") { browser.folderBook.toggle(folder.id) }
            // A task's folder: its chat, in full (ChatColumn.swift).
            if folder.nest == nil, Agents.shared.hasChat(folder.id) {
                Button("Show Chat", mark: "yab.chat") { browser.showChat(folder.id) }
            }
            if folder.unread > 0 {
                Button("Mark as Read", mark: "yab.tabs.check") {
                    AgentFeed.shared.read(folder.members.compactMap { id in browser.tabs.first { $0.id == id } })
                }
            }
            Divider()
            if folder.nest == nil {
                let tabs = folder.members.compactMap { id in browser.tabs.first { $0.id == id && $0.agent != nil } }
                if !tabs.isEmpty {
                    Button("Keep \(tabs.count == 1 ? "Tab" : "\(tabs.count) Tabs") for Yourself", mark: "yab.person.left") {
                        browser.folderBook.keep(tabs, in: browser)
                    }
                }
            }
            if Agents.shared.session(folder.id)?.state.live == true {
                Button("Stop Task", mark: "stop") { _ = Agents.shared.stop(folder.id) }
            }
            Button("Close \(folder.members.count) Tabs", mark: "yab.tabs.x") { Folders.close(folder, in: browser) }
        }
    }

    /// Yab's own work out of sight: what it does, in its chat, and a way to
    /// stop it. Nothing that opens it or hands its tabs over.
    @ViewBuilder private var sealed: some View {
        let agents = Agents.shared
        let chat = agents.hasChat(folder.id)
        if chat {
            Button("Show Chat", mark: "yab.chat") { browser.showChat(folder.id) }
        }
        if let session = agents.session(folder.id), session.state.live {
            if chat { Divider() }
            Button(Folders.stopping(session), mark: "stop") { _ = agents.stop(folder.id) }
        }
    }
}

/// A row of a folder's: under it, stepped in to the mark's right edge, or
/// tucked away to nothing. The rows come down in turn, 30 ms apart, once
/// their room has begun to open; they go back up at once (the column drops
/// a tucked row's content, so nothing of it is left to fold). Each row
/// brings the gap under it, the list itself having none (SideBar), so a
/// row tucked away takes no room at all: a list's own spacing stayed under
/// every one of them, two points each, and a shut folder of fifty tabs stood
/// a hundred points taller than its row. No clip either: a row taken up or
/// stepping aside is drawn wherever the drag has it.
struct FolderRowPlace: ViewModifier {
    let place: Folders.Place?
    let gap: CGFloat

    func body(content: Content) -> some View {
        if let place {
            // The room opens with the folder, on its clock (Folders.toggle);
            // what fills it comes in turn.
            content
                .padding(.leading, CGFloat(place.depth) * Folders.indent)
                .animation(place.shown
                           ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22).delay(0.05 + Double(place.order) * 0.03)
                           : nil) {
                    $0.opacity(place.shown ? 1 : 0).offset(y: place.shown ? 0 : -6)
                }
                .frame(height: place.shown ? SideBar.row : 0, alignment: .top)
                .padding(.bottom, place.shown ? gap : 0)
                .allowsHitTesting(place.shown)
        } else {
            content.padding(.bottom, gap)
        }
    }
}

/// The row under an open task folder's fourth that holds back the rest:
/// "Show All", stepped in with the folder's rows. A click lets them out. No
/// count: a folder never says how many tabs it holds.
struct FolderMore: View {
    let folder: String
    let count: Int
    /// On top, a pill's width; down the column, the row's.
    var width: CGFloat? = nil
    @Environment(\.tone) private var tone

    var body: some View {
        Group {
            if let width {
                Button { Folders.shared.showAll(folder) } label: {
                    Text(width < 62 ? "All" : "Show All")
                        .font(.system(size: SidebarTypography.current - 1, weight: .medium))
                        .foregroundStyle(Palette.muted(on: tone))
                        .lineLimit(1)
                        .frame(width: width, height: SideBar.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button { Folders.shared.showAll(folder) } label: {
                    Text("Show All")
                }
                .buttonStyle(.yab(.quiet, .small))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(height: SideBar.row)
        .pointerTip("Show All Tabs")
        .transition(.opacity)
    }
}

// MARK: - on top

/// The folder as a pill in the row on top: the same mark, name and face.
/// Open, its tabs come out to its right in a wash. A sealed one is always
/// shut, as its row in the column is.
struct FolderPill: View {
    @ObservedObject var browser: Browser
    let folder: Folders.Folder
    let open: Bool
    let width: CGFloat
    /// Where its tabs are, when not in the space on screen: the next
    /// space's row coming up on top (StripComing).
    var among: [Tab]? = nil

    @ObservedObject private var agents = Agents.shared
    @Environment(\.tone) private var tone
    @State private var hovering = false

    private var asking: Bool { !folder.asking.isEmpty }
    private var face: Tab? {
        let row = among ?? browser.tabs
        let tabs = folder.members.compactMap { id in row.first { $0.id == id } }
        // Asking, the face is the hand of the tab that asks.
        return tabs.first { folder.asking.contains($0.id) } ?? tabs.first { $0.agent == folder.id } ?? tabs.first
    }
    /// Open, as the row says, but a sealed one never.
    private var unfolded: Bool { open && !folder.sealed }
    private var color: Color { asking || hovering || unfolded || compact ? Palette.strong(on: tone) : Palette.muted(on: tone) }
    private var compact: Bool { !unfolded && width < Metrics.tabTitled }
    /// Resting on a sealed one says its step in words: its pages aren't
    /// shown.
    private var tip: String {
        guard folder.sealed, let session = agents.session(folder.id) else { return "" }
        return AgentDock.say(session.now, name: session.name)
    }

    var body: some View {
        let _ = StripRenderMeter.folder()
        HStack(spacing: compact ? 2 : 6) {
            // Drawn into one picture with the next space's row, still.
            FolderMark(tab: face, open: unfolded, tint: color, still: among != nil, site: Folders.site(folder, among: among ?? browser.tabs))
            if compact {
                Text(String(Folders.title(folder.id).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
            }
            if !compact {
                FadingTitle(text: Folders.title(folder.id), font: .system(size: 12.5, weight: .medium), color: Palette.strong(on: tone), clear: 0, fade: 28)
                    .equatable()
                if !unfolded {
                    FolderNeeds(folder: folder)
                }
                if !unfolded {
                    FolderEnd(folder: folder, face: face, tint: color, still: among != nil)
                }
            }
        }
        .padding(.leading, compact ? 0 : 11)
        .padding(.trailing, compact ? 0 : 7)
        .padding(.vertical, 6)
        .frame(width: width, alignment: compact ? .center : .leading)
        .background {
            if hovering || asking {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                    .fill(Palette.hover(on: tone))
            }
        }
        .offset(y: asking ? -1 : 0)
        .shadow(color: .black.opacity(asking ? 0.08 : 0), radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            // The next space's row drawing it isn't where its preview comes out.
            guard among == nil else { return }
            browser.glance.folderFrames[folder.id] = frame
        }
        .onTapGesture { Folders.tapped(folder, in: browser) }
        .onHover { on in
            hovering = on
            if !folder.sealed { browser.glance.hoverFolder(folder.id, on) }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: asking)
        .steadyMenu(actions: true) { FolderMenu(folder: folder, browser: browser) }
        .pointerTip(tip)
    }
}

/// A folder's tab on top: to the folder's right in its wash while it is
/// open, or asking; otherwise folded to nothing.
struct FolderPillPlace: ViewModifier {
    let place: Folders.Place?
    let gap: CGFloat
    func body(content: Content) -> some View {
        if let place {
            content
                .animation(place.shown
                           ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22).delay(Double(place.order) * 0.03)
                           : .easeOut(duration: 0.1)) {
                    $0.opacity(place.shown ? 1 : 0)
                }
                .frame(maxWidth: place.shown ? nil : 0, alignment: .leading)
                .clipped()
                // Each pill brings the gap after it, the row having none: a
                // pill tucked away takes no room at all (see FolderRowPlace).
                .padding(.trailing, place.shown ? gap : 0)
                .allowsHitTesting(place.shown)
        } else {
            content.padding(.trailing, gap)
        }
    }
}

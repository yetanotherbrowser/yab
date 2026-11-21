import AppKit
import SwiftUI

// A few quiet rows under a new tab's field offer
// what to do next: an icon, a name, and in gray what it is about.
//
// Two kinds. What is left of getting started, each gone once done or put
// away with its ×. And what an agent found worth your while in the places
// you use: an offer waiting on an answer, a charge that failed, a flight
// tomorrow. Nothing is said when there is nothing, and nothing while it is
// being looked for; a new tab stays a new tab.
//
// The second kind comes from a quiet task, like the daily memory pass: once
// in the morning and after a long break, never on a timer, an agent looks at
// your history, decides which of the places you use are worth checking, reads
// them in tabs of its own without marking anything read or answering
// anything, and hands back what needs you through `suggest`, four rows on
// screen at most. A row opens the thing itself, in the tab you are on, at
// the words it is about.
//
// A row stays until the thing is dealt with, not until it is clicked: opened,
// it only loses half its color. The next look is told the rows still up and
// says which are done; those draw a tick and fold away the next time they
// are seen. A row can be put off (its menu), and one with a time rises and
// counts down as the time comes. Nothing reads your mail until you say so,
// from the row that offers it.

struct Hint: Identifiable, Equatable, Codable {
    enum Icon: Equatable, Codable {
        case face, symbol(String), site(String)
        /// One of Pictures' kinds, and the site it is about, if one.
        case picture(String, site: String?)
    }

    let id: String
    let icon: Icon
    var title: String
    var detail: String
    /// A page to open, or nil for something to do.
    var url: URL? = nil
    /// Getting started, or found by an agent.
    var setup = false
    /// A routine it offers to set, when and what: taking the row sets it.
    var routine: [String]? = nil
    /// Opened from its row, and when. It stays until the thing is done.
    var seen: Date? = nil
    /// When it matters: a meeting's start, a deadline, a trial's end.
    var due: Date? = nil
    /// Words on its page it is about, landed on when it opens.
    var quote: String? = nil
    /// A reply already written, put into the page when it opens.
    var draft: String? = nil
    /// A meeting's own link, offered as Join as it starts.
    var join: URL? = nil
    /// A subscription: the page it opens offers cancelling it.
    var cancel: Bool? = nil
    /// Dealt with: drawn going, with a tick, the next time it is seen.
    var done: Bool? = nil
    /// Who put it here: an agent's look, yab itself (a link copied, a
    /// meeting about to start) or your own habit. Nil in rows kept before
    /// it was said, which were all an agent's or getting started's.
    var source: Source? = nil
    /// A link's row: when it was copied, counted in its detail.
    var copied: Date? = nil
    /// A row of yab's own: what it is a kind of (Noticing.Kind), for
    /// Don't Show Things Like This.
    var kind: String? = nil
    /// A mail row: whose mail it is, which Don't Show Things Like This
    /// can turn off by itself.
    var sender: Sender? = nil
    /// From iPhone (SyncPhone): when the page changed on the iPhone, and
    /// the space it is in there, as sync names it.
    var phone: Date? = nil
    var space: String? = nil
    /// Its time is a day, not a time of day (a promise "by Friday"): its
    /// end never counts down to an hour nobody said.
    var day: Bool? = nil

    enum Source: String, Codable { case found, noticed, habit }

    struct Sender: Equatable, Codable, Hashable {
        var address: String
        var name: String
    }

    /// Worked out by yab on this Mac, not handed over by an agent.
    var local: Bool { source == .noticed || source == .habit }
}

@MainActor
final class Hints: ObservableObject {
    static let shared = Hints()

    /// Now, as the rows see it. A test run moves it on (`agent-clock`) to
    /// see times come, puts off end and rows age.
    static var offset: TimeInterval = 0
    static var now: Date { Date().addingTimeInterval(offset) }

    /// The last rows shown, kept so a new tab has them at once, before
    /// anything is worked out again.
    @Published private(set) var rows: [Hint] = Hints.cached
    /// Rows not yet seen on a new tab: they come in, the rest stand.
    @Published private(set) var arriving: Set<String> = []
    /// Something new came while you were elsewhere: New Tab wears a dot.
    @Published private(set) var waiting = false
    /// What came in and what went with a tick, newest last, for the bench.
    private(set) var journal: [String] = []
    /// Everything that would show but for the four, for the bench.
    private(set) var eligible: [String] = []

    /// A quiet look told no when it tried to ask the person something.
    func refusedQuiet(_ what: String) { note("quiet-refuse " + what) }

    private func note(_ line: String) {
        journal.append(line)
        if journal.count > 40 { journal.removeFirst(journal.count - 40) }
    }

    private static var cached: [Hint] {
        guard let data = Store.settings.data(forKey: "hints.rows") else { return [] }
        return (try? JSONDecoder().decode([Hint].self, from: data)) ?? []
    }

    /// Only an agent's rows and getting started's are kept: what yab
    /// noticed is about now, and worked out again at once.
    private func keepRows() {
        if let data = try? JSONEncoder().encode(rows.filter { !$0.local }) { store.set(data, forKey: "hints.rows") }
    }

    /// What an agent found and what is left of getting started, as the
    /// last look at the disk had them; what yab notices is laid in with
    /// them on every `compose`.
    private var agentFound: [Hint] = Hints.cached.filter { !$0.setup && !$0.local }
    private var agentSetup: [Hint] = Hints.cached.filter(\.setup)

    /// The whole queue as last composed, past the four a new tab shows:
    /// ⌘L over a page takes its own two from it.
    private(set) var queue: [Hint] = []

    /// Rows handed to the agent (Do It), each to the task doing it.
    private(set) var handed: [String: String] = [:]

    func hand(_ id: String, to session: String) {
        handed[id] = session
        compose()
    }

    /// Tasks of handed rows whose answer you opened (the row's ↩, its Done,
    /// their chat once over, or over in front of you). Not `session.read`,
    /// which a task's tabs settle by themselves as it ends.
    private(set) var answered: Set<String> = []
    /// What opened each, for the bench.
    private(set) var answeredBy: [String: String] = [:]

    func opened(_ session: String, by: String) {
        guard handed.values.contains(session), answered.insert(session).inserted else { return }
        answeredBy[session] = by
        compose()
    }

    /// Where the task a row was handed to stands: "On it" at work, "Needs
    /// you" while it asks in its chat, "Done" until its answer is opened,
    /// "Didn't finish" when it couldn't. Nothing once it was stopped.
    func handedWords(_ id: String) -> String? {
        guard let session = handedSession(id) else { return nil }
        if session.state.live { return session.asking != nil ? "Needs you" : "On it" }
        if session.state == .done { return answered.contains(session.id) ? nil : "Done" }
        return session.state == .failed ? "Didn’t finish" : nil
    }

    /// The task a row was handed to, while it has one.
    func handedSession(_ id: String) -> Agents.Session? {
        handed[id].flatMap { Agents.shared.session($0) }
    }

    /// A row handed over is the task's one row, start to end: done, it says
    /// the pick and when, and no second row of the task comes beside it
    /// (Noticing.taskRows). Its answer opened, the row it came from is done
    /// with too, and goes.
    private func handedLook(_ hints: [Hint], now: Date) -> [Hint] {
        hints.compactMap { hint in
            guard let session = handedSession(hint.id), session.state == .done else { return hint }
            if answered.contains(session.id) {
                handed[hint.id] = nil
                // Not from inside the merge: finishing composes again.
                DispatchQueue.main.async { if hint.local { Noticing.shared.hideToday(hint) } else { self.finish(hint) } }
                return nil
            }
            var done = hint
            done.title = TaskAnswer.pick(session.result) ?? hint.title
            done.detail = "Done " + Hints.ago(session.ended ?? now, now: now)
            return done
        }
    }

    /// A row by its id, wherever it is shown.
    func row(_ id: String) -> Hint? {
        rows.first { $0.id == id } ?? queue.first { $0.id == id }
    }

    /// Over a page (⌘L), two at most, and only what can't wait for a new
    /// tab: something due within ten minutes, a meeting above all, and a
    /// link just copied. The page's own action, if there is room, is the
    /// field's to add (Browser.quietRows).
    nonisolated static func overPage(_ queue: [Hint], now: Date) -> [Hint] {
        Array(queue.filter { hint in
            // A promise waits for the empty field: over a page it is noise.
            guard hint.done != true, !promise(hint) else { return false }
            if hint.copied != nil || hint.phone != nil { return true }
            guard let due = hint.due else { return false }
            let left = due.timeIntervalSince(now)
            return left <= 10 * 60 && left > -15 * 60
        }.prefix(2))
    }

    /// Settings › Tabs, Suggestions under the field: what yab notices
    /// itself (a link just copied, a meeting about to start) and your
    /// habits, with no agent and nothing sent anywhere. On unless turned off.
    var suggesting: Bool {
        get { store.object(forKey: "hints.noticing") as? Bool ?? true }
        set {
            objectWillChange.send()
            store.set(newValue, forKey: "hints.noticing")
            compose()
        }
    }
    /// The row a task it started is working for, with that task's session.
    @Published private(set) var working: [String: String] = [:]
    /// Tabs a row just sent somewhere an agent can act, and where: the pill
    /// at the page's foot, until the page is touched or left.
    @Published var offered: [UUID: String] = [:]
    /// What the pill offers on such a tab when its site has no skill for
    /// it: cancelling a subscription.
    @Published var extra: [UUID: Skills.Action] = [:]

    /// The pill's offer on a tab is over: the page moved on or was touched.
    func unoffer(_ tab: UUID) {
        offered[tab] = nil
        extra[tab] = nil
    }

    private var store: UserDefaults { Store.settings }
    private var finding = false
    nonisolated private static var file: URL { Store.file("hints.json") }
    nonisolated private static var rules: URL { Store.file("hints-rules.txt") }

    /// Whether an agent may look through the places you use for you.
    var watching: Bool {
        get { store.bool(forKey: "agents.watch") && BackgroundConsent.canStartMorning(settings: store) }
        set { store.set(newValue, forKey: "agents.watch"); if !newValue { BackgroundConsent.revokeMorning(settings: store) }; refresh() }
    }

    private var dismissed: Set<String> { Set(store.stringArray(forKey: "hints.dismissed") ?? []) }

    /// Rows a new tab has shown: what is new is what isn't in here.
    private var shown: Set<String> { Set(store.stringArray(forKey: "hints.shown") ?? []) }

    /// Ids kept in the order they came, the oldest let go past `limit`: one
    /// put away a year ago goes before one put away this morning, whatever
    /// its name.
    nonisolated static func remember(_ ids: [String], adding new: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        let new = new.filter { seen.insert($0).inserted }
        return Array((ids.filter { !seen.contains($0) } + new).suffix(limit))
    }

    private func add(_ ids: [String], to key: String, limit: Int) {
        store.set(Hints.remember(store.stringArray(forKey: key) ?? [], adding: ids, limit: limit), forKey: key)
    }

    // MARK: - what shows

    /// Worked out off the main thread: memory, the setup files and what was
    /// found are all on disk, and ~/.claude.json can be megabytes.
    func refresh() {
        guard !counting else { again = true; return }
        counting = true
        let watching = watching
        let dismissed = dismissed
        let now = Hints.now
        Task.detached(priority: .utility) {
            let empty = Memory.empty
            let command = AgentSetup.status().command
            let found = Hints.readFound(now: now) { AgentHistory.lastVisit(to: $0) }
            await MainActor.run {
                self.counting = false
                self.show(empty: empty, command: command, found: found, watching: watching, dismissed: dismissed)
                if self.again { self.again = false; self.refresh() }
            }
        }
    }

    private var counting = false
    private var again = false

    private func show(empty: Bool, command: Bool, found: [Hint], watching: Bool, dismissed: Set<String>) {
        // Passive CLI discovery reads install locations, never login scripts.
        guard let shell = Shell.cached else {
            if !finding {
                finding = true
                Task { _ = await Shell.find(resolvingLogin: false); refresh() }
            }
            compose()
            return
        }
        let agents = shell.claude != nil || shell.codex != nil
        guard store.bool(forKey: "bench"), agents else {
            agentFound = []
            agentSetup = []
            compose()
            return
        }
        // What an agent found, the nearest time first, then as it was handed.
        agentFound = found.filter { !dismissed.contains($0.id) }.map { hint in
            var hint = hint
            hint.source = .found
            return hint
        }
        // What is left of getting started. Get to Know at work, whoever
        // started it (the welcome, Settings, a form), is this row at work:
        // its step in words, never an offer of a second run. It stays for
        // as long as the run does, though its first notes fill memory.
        var setup: [Hint] = []
        let knowing = knowingRun
        if let knowing, working["setup.memory"] != knowing.id { working["setup.memory"] = knowing.id }
        // Get to Know and the morning look are background work: only with
        // AI in Yab On (AIUse).
        let background = AIUse.allows(.background, in: store)
        if (empty && background) || knowing != nil {
            setup.append(Hint(id: "setup.memory", icon: .picture("me", site: nil), title: "Get to know me",
                              detail: "Look me up where I'm signed in, out of sight: memory, my profile for forms, my addresses", setup: true))
        }
        if !watching, background {
            setup.append(Hint(id: "setup.watch", icon: .picture("routine", site: nil), title: "Keep an eye on things for me",
                              detail: "Mornings and after a break, check what I use and bring what needs me here", setup: true))
        }
        if !command {
            let names = [shell.claude.map { _ in "Claude Code" }, shell.codex.map { _ in "Codex" }].compactMap { $0 }
            setup.append(Hint(id: "setup.cli", icon: .picture("terminal", site: nil), title: "Use Yab from \(names.joined(separator: " and "))",
                              detail: "Connect it in Settings, then ask it for anything on the web", setup: true))
        }
        // A run under way shows even where the offer was put away: its ×
        // was for the offer, not for saying what is going on.
        agentSetup = setup.filter { !dismissed.contains($0.id) || ($0.id == "setup.memory" && knowing != nil) }
        compose()
    }

    /// Set up Yab's row that connects a plan, shown while there is nothing
    /// to ask (AIUse.connectOffered): its own row, as the iPhone's is.
    static let connectID = "setup.connect"
    static var connect: Hint {
        Hint(id: connectID, icon: .picture("ai", site: nil), title: "Connect Claude or ChatGPT",
             detail: "Ask and tasks", setup: true)
    }

    /// Get to Know at work, from wherever it was started.
    private var knowingRun: Agents.Session? { Agents.shared.sessions.first { Agents.getsToKnow($0) } }

    /// The rows as they stand now: an agent's as last read, and what yab
    /// notices itself worked out again, in one queue (Hints.order). Cheap,
    /// a merge of ten things on the main thread: the field calls it as it
    /// opens, so a link copied a second ago is there.
    func compose() {
        let now = Hints.now
        let dismissed = self.dismissed
        let noticed = suggesting ? Noticing.shared.rows(now: now).filter { !dismissed.contains($0.id) } : []
        // Yab for your phone, with or without an agent, until a phone syncs.
        let phone = PhoneBeta.waiting && !dismissed.contains(PhoneBeta.hintID) ? [PhoneBeta.hint] : []
        // Nothing to ask yet: the one way in that stays while AI hides
        // (AIUse.connectOffered), beside the iPhone's row.
        let connect = AIUse.connectOffered && !dismissed.contains(Hints.connectID) ? [Hints.connect] : []
        // An agent's row about a mail you have since answered or read goes
        // without a word: you know, you did it.
        let found = agentFound.filter { $0.done == true || !MailCenter.shared.settled($0.url) }
        let out = handedLook(Hints.order(found: found, noticed: noticed, setup: phone + connect + agentSetup, now: now), now: now)
        queue = out
        eligible = out.filter { $0.done != true }.map(\.id)
        // Four at most, not counting ones done and on their way out.
        var next: [Hint] = []
        var live = 0
        for hint in out {
            if hint.done == true { next.append(hint); continue }
            guard live < 4 else { continue }
            next.append(hint)
            live += 1
        }
        let seen = shown
        // Only what an agent found comes in: what yab noticed is about now,
        // not news.
        let new = Set(next.filter { $0.done != true && !$0.local && !seen.contains($0.id) }.map(\.id))
        if next != rows {
            let kept = rows.filter { !$0.local }
            rows = next
            if kept != next.filter({ !$0.local }) { keepRows() }
        }
        if new != arriving {
            if !new.isEmpty { note("arrive " + new.sorted().joined(separator: " ")) }
            arriving = new
        }
        // Found things only: getting started is no news.
        let news = next.contains { new.contains($0.id) && !$0.setup }
        let here = Agents.shared.browser?.askingNew ?? true
        let dot = news && !here
        if dot != waiting { waiting = dot }
    }

    /// A new tab has shown the rows: what came in is standing now.
    func saw() {
        guard !arriving.isEmpty || waiting else { return }
        let came = arriving
        waiting = false
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            add(came.sorted(), to: "hints.shown", limit: 300)
            arriving.subtract(came)
        }
    }

    func dismiss(_ hint: Hint) {
        // A mail row: its thread, until new mail comes in it.
        if hint.local, hint.sender != nil || Noticing.Kind.of(hint)?.isMail == true, hint.id != "mail.skipped" {
            return Noticing.shared.setAside(hint)
        }
        // Found things come and go: only the last couple of hundred are kept.
        add([hint.id], to: "hints.dismissed", limit: 200)
        // The look hears what you put away, so it doesn't bring it again
        // under another link.
        if !hint.local, !hint.setup {
            var site: String?
            if case .picture(_, let host?) = hint.icon { site = host }
            let now = Hints.now
            let kept = (store.array(forKey: "hints.removed") as? [[String: Any]] ?? [])
                .filter { now.timeIntervalSince1970 - (($0["at"] as? Double) ?? 0) < 14 * 86_400 }
            store.set(Array((kept + [["title": hint.title, "site": site ?? "", "at": now.timeIntervalSince1970]]).suffix(20)), forKey: "hints.removed")
        }
        rows.removeAll { $0.id == hint.id }
        keepRows()
        refresh()
    }

    /// A row done has drawn its tick: it goes for good.
    func settle(_ id: String) {
        note("settle " + id)
        Hints.change { $0.removeAll { $0.id == id } }
        if let hint = rows.first(where: { $0.id == id }) { dismiss(hint) }
    }

    // MARK: - taking one

    func take(_ hint: Hint, in browser: Browser) {
        guard hint.done != true else { return }
        if hint.local { return Noticing.shared.take(hint, in: browser) }
        if let routine = hint.routine, routine.count == 2 {
            switch Routines.shared.add(when: routine[0], prompt: routine[1]) {
            case .success: browser.announce("Routine set: \(hint.title)", mark: "checkmark", feedback: .success)
            case .failure(let trouble): browser.announce(trouble.said, mark: "exclamationmark.triangle")
            }
            dismiss(hint)
            return
        }
        if let url = hint.url, MailPage.isMail(url), browser.prefs.usesMail {
            // A mail's thread: over the page, or on mail's page in mail's
            // space (MailThreadPeek); opened, it stays a little paler.
            browser.close()
            browser.mailRow(url, hint: hint.id)
            let now = Hints.now
            Hints.change { all in
                if let index = all.firstIndex(where: { $0.id == hint.id }) { all[index].seen = now }
            }
            refresh()
            return
        }
        if let url = hint.url {
            // The thing itself: in the empty tab that asked, or, from ⌘T's
            // field over a page, in a tab of its own.
            let before = Set(browser.tabs.map(\.id))
            let blank = browser.active.flatMap { $0.isBlank ? $0 : nil }
            browser.take(Suggestion(key: url.host() ?? "", title: hint.title, url: url, kind: .address))
            if hint.setup {
                dismiss(hint)
                return
            }
            // Opened, not done: it stays, a little paler, until it is.
            let now = Hints.now
            Hints.change { all in
                if let index = all.firstIndex(where: { $0.id == hint.id }) { all[index].seen = now }
            }
            // The tab it opened in, not the page ⌘T's field was over: with no
            // empty tab asking, the row's page comes in a tab of its own, a
            // moment after the field lets go.
            Hints.opened(after: before, or: blank, in: browser) { [weak self] tab in
                guard let self, let tab else { return }
                if let quote = hint.quote { Landing.land(tab, on: quote, at: url) }
                // Written once, the first time the row is opened: a second
                // open would set a second agent typing into the same box.
                if let draft = hint.draft, hint.seen == nil {
                    Landing.loaded(tab, at: url) { Agents.shared.write(draft, on: tab) }
                } else if hint.cancel == true {
                    self.extra[tab.id] = Hints.cancelling
                    self.offered[tab.id] = url.absoluteString
                } else if !Skills.actions(for: url).isEmpty {
                    self.offered[tab.id] = url.absoluteString
                }
            }
            refresh()
            return
        }
        switch hint.id {
        case "setup.memory":
            // One run at a time, from anywhere: one under way is this row's.
            if let knowingRun { working[hint.id] = knowingRun.id } else { ContextConsent.request() }
        case "setup.watch":
            BackgroundConsent.enableMorning()
            watching = true
            if let session = Agents.shared.look(force: true) { working[hint.id] = session.id }
        case PhoneBeta.hintID:
            // The link, to scan or paste on the phone: a Mac can't open it.
            PhoneBeta.copy(PhoneBetaState.shared.phone, in: browser)
            return
        case Hints.connectID:
            // Settings › AI › Agents, where Connect is.
            browser.openSettings(.agents)
        case "setup.cli":
            // Connect signs in and shows how to ask: that is Settings' to do.
            browser.openSettings(.agents)
        default:
            break
        }
        refresh()
    }

    /// What the pill offers on a subscription's page.
    static let cancelling = Skills.Action(
        title: "Cancel subscription", pattern: "*",
        prompt: """
        This is the page of a subscription the user pays for and may want to stop. Find how to cancel it here \
        and go through its steps up to the last one. Turn down every offer to stay on the way (a discount, a \
        pause, a cheaper plan, a free month): taking one is a purchase. Stop before the button that finally cancels or confirms, \
        and tell the user in a line which button that is and what happens when they press it. Never press it \
        yourself, and change nothing else.
        """,
        skill: "")

    /// Not now: back at `until`.
    func putOff(_ hint: Hint, until: Date) {
        Hints.change { all in
            if let index = all.firstIndex(where: { $0.id == hint.id }) { all[index].snooze = until }
        }
        rows.removeAll { $0.id == hint.id }
        keepRows()
        refresh()
    }

    /// Dealt with, said by you: the tick and the fold at once.
    func finish(_ hint: Hint) {
        let now = Hints.now
        Hints.change { all in
            if let index = all.firstIndex(where: { $0.id == hint.id }) { all[index].done = now }
        }
        refresh()
    }

    /// Not this, nor anything like it: a line the next look reads. A row
    /// of yab's own turns off its kind, or with `person` its sender's mail
    /// (Noticing.never), and the look hears that too (brief).
    func never(_ hint: Hint, person: Bool = false) {
        if hint.local { return Noticing.shared.never(hint, person: person) }
        // Its kind and site with the words, so the look leaves out what is
        // like it, not only these words.
        var line = hint.title
        if case .picture(let kind, let site) = hint.icon {
            line = kind + (site.map { " from " + $0 } ?? "") + ", like: " + hint.title
        }
        let before = (try? String(contentsOf: Hints.rules, encoding: .utf8)) ?? ""
        let lines = (before.split(separator: "\n").map(String.init) + [line]).suffix(40)
        try? FileManager.default.createDirectory(at: Hints.rules.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: Hints.rules, atomically: true, encoding: .utf8)
        dismiss(hint)
    }

    /// When Later Today brings it back: five o'clock, or, past four, in three hours.
    nonisolated static func laterToday(from now: Date) -> Date {
        let five = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? now
        return five.timeIntervalSince(now) > 3600 ? five : now.addingTimeInterval(3 * 3600)
    }

    /// Nine the next morning; before five, still the night before, so this
    /// morning's nine.
    nonisolated static func tomorrowMorning(from now: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.component(.hour, from: now) < 5 ? now : calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// What the row says while its task runs: the task's current step, in
    /// words. Get to Know's row follows any run of it, not only its own.
    func step(_ hint: Hint) -> String? {
        let run = hint.id == "setup.memory" ? knowingRun : Agents.shared.session(working[hint.id])
        guard let run, run.state.live else { return nil }
        return AgentDock.say(run.now, name: run.name)
    }

    /// A task a row started is over: the row is itself again. And Get to
    /// Know over, with the morning look on and never run, is when the look
    /// runs first: it waited for this (Agents.lookWaits).
    func ended(_ session: String) {
        for (row, id) in working where id == session { working[row] = nil }
        // Get to Know's row goes with its run: the offer again only while
        // memory is still empty.
        if Agents.shared.session(session)?.knowing == true { refresh() }
        let looked = store.object(forKey: "agents.watched") as? Date
        guard let ended = Agents.shared.session(session),
              Hints.looksAfter(ended, watching: watching, looked: looked) else { return }
        let producer = ended.admission
        guard producer.authorityValid, let purpose = BackgroundConsent.permit(settings: store) else { return }
        // Once the run's own ending is through, its tabs closed.
        Task { @MainActor in
            guard producer.authorityValid, purpose.valid else { return }
            Agents.shared.look(force: true, backgroundPermit: purpose)
        }
    }

    /// Whether a task's end starts the first morning look: it was Get to
    /// Know (not a quiet pass), it is over, the look is on and has never
    /// run. Once a look has run, the next comes at its usual moments.
    static func looksAfter(_ ended: Agents.Session?, watching: Bool, looked: Date?) -> Bool {
        guard let ended, ended.knowing, !ended.quiet, ended.parent == nil, !ended.state.live else { return false }
        return watching && looked == nil
    }

    // MARK: - what an agent found

    struct Found: Codable, Equatable {
        let id: String
        var title: String
        var detail: String
        var url: String?
        var site: String?
        var kind: String?
        let at: Date
        /// A routine offered: when, and the task it would run.
        var when: String?
        var task: String?
        /// Last handed back by a look. One not handed back again goes a day after.
        var confirmed: Date?
        var seen: Date?
        /// Put off until then.
        var snooze: Date?
        var due: Date?
        var quote: String?
        var draft: String?
        var join: String?
        /// A subscription, "trial" or "renewal": yab decides when it shows.
        var subscription: String?
        /// A subscription's own site, whose use says whether it is used.
        var service: String?
        /// Dealt with, and when.
        var done: Date?
        /// The routine whose run found it, by name, for its row's words.
        var by: String?
    }

    nonisolated private static func load() -> [Found] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Found].self, from: data)) ?? []
    }

    @discardableResult
    nonisolated private static func save(_ all: [Found]) -> String? {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func change(_ work: (inout [Found]) -> Void) {
        var all = load()
        work(&all)
        save(all)
    }

    /// Whether it is still worth keeping at all, shown or not.
    nonisolated static func lasts(_ found: Found, now: Date) -> Bool {
        if let done = found.done { return now.timeIntervalSince(done) < 12 * 3600 }
        let looked = now.timeIntervalSince(found.confirmed ?? found.at) < 20 * 3600
        if let due = found.due {
            let meeting = found.join != nil || ["meeting", "calendar", "event", "call"].contains(found.kind ?? "")
            // A meeting is over a quarter hour in; a deadline gone by is
            // still owed, for as long as a look last said so.
            return meeting ? now < due.addingTimeInterval(15 * 60) : (now < due.addingTimeInterval(2 * 3600) || looked)
        }
        return looked
    }

    /// Whether it shows now. A trial the day before it ends; a renewal
    /// three days before, and only for a site not opened in a month: what
    /// you use is never brought up.
    nonisolated static func showing(_ found: Found, now: Date, lastVisit: (String) -> Date?) -> Bool {
        if let snooze = found.snooze, snooze > now { return false }
        guard let kind = found.subscription else { return true }
        // Without the day it charges there is no day before it: held.
        guard let due = found.due else { return false }
        let left = due.timeIntervalSince(now)
        if kind == "trial" { return left <= 36 * 3600 }
        // Used is the service's own site, never where the notice came: a
        // mail host is opened every day and would hold every renewal back.
        guard let host = found.service ?? found.site, !host.isEmpty else { return false }
        return left <= 3 * 86_400 && lastVisit(host) == nil
    }

    /// How long until it, for its detail, while that is under two hours.
    nonisolated static func until(_ due: Date, now: Date) -> String? {
        let left = due.timeIntervalSince(now)
        guard left < 2 * 3600, left > -15 * 60 else { return nil }
        if left <= 60 { return "now" }
        let minutes = Int((left / 60).rounded(.up))
        return minutes < 60 ? "in \(minutes)m" : minutes % 60 == 0 ? "in \(minutes / 60)h" : "in \(minutes / 60)h \(minutes % 60)m"
    }

    /// How long ago, in the fewest words: "12s ago", "3m ago".
    nonisolated static func ago(_ then: Date, now: Date) -> String {
        let seconds = max(1, Int(now.timeIntervalSince(then)))
        return seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
    }

    nonisolated private static func readFound(now: Date, lastVisit: (String) -> Date?) -> [Hint] {
        visible(load(), now: now, lastVisit: lastVisit)
    }

    /// What of everything kept shows now, and in what order.
    nonisolated static func visible(_ all: [Found], now: Date, lastVisit: (String) -> Date?) -> [Hint] {
        let hints: [Hint] = all.filter { lasts($0, now: now) && showing($0, now: now, lastVisit: lastVisit) }.map { item in
            let url = item.url.flatMap(URL.init(string:))
            let host = item.site ?? url?.host()
            let kind = item.kind.flatMap { Pictures.kinds[$0] != nil ? $0 : nil } ?? Pictures.kind(for: host)
            if let when = item.when, let task = item.task {
                return Hint(id: item.id, icon: .picture("routine", site: host), title: item.title, detail: item.detail, routine: [when, task],
                            done: item.done == nil ? nil : true)
            }
            var detail = item.detail
            if let by = item.by { detail = detail.isEmpty ? by : by + " · " + detail }
            if item.draft != nil { detail = detail.isEmpty ? "Reply drafted" : "Reply drafted · " + detail }
            if item.subscription == "renewal" { detail += detail.isEmpty ? "Not opened in a month" : ", not opened in a month" }
            return Hint(id: item.id, icon: .picture(kind, site: host), title: item.title, detail: detail, url: url,
                        seen: item.seen, due: item.due, quote: item.quote, draft: item.draft,
                        join: item.join.flatMap(URL.init(string:)), cancel: item.subscription == nil ? nil : true,
                        done: item.done == nil ? nil : true)
        }
        // What is close in time goes first, nearest first; the rest keep the
        // order they were handed in, most urgent first.
        // Coming within two hours, or begun a quarter hour ago at most: a
        // time long gone doesn't jump the queue ahead of one still to come.
        let soon = hints.filter { hint in
            hint.done != true && hint.due.map { $0.timeIntervalSince(now) < 2 * 3600 && $0.timeIntervalSince(now) > -15 * 60 } == true
        }
            .sorted { ($0.due ?? now) < ($1.due ?? now) }
        // A routine offered is a suggestion, not something owed: after the rest.
        let rest = hints.filter { hint in !soon.contains { $0.id == hint.id } }
        return soon + rest.filter { $0.routine == nil } + rest.filter { $0.routine != nil }
    }

    /// One queue, one order (PLAN-hints §7): what is due within two hours,
    /// an agent's and a meeting on the calendar alike, nearest first; a
    /// link just copied, whose moment is now or never; the rest of what an
    /// agent found, as it handed it over; a habit; a routine offered; then
    /// getting started. A meeting yab read off the calendar that an agent
    /// found too is one row, the agent's, its time and Join the calendar's.
    nonisolated static func order(found: [Hint], noticed: [Hint], setup: [Hint], now: Date) -> [Hint] {
        var found = found
        var mine: [Hint] = []
        for hint in noticed {
            if hint.source == .noticed, hint.due != nil, let index = found.firstIndex(where: { sameMeeting($0, hint) }) {
                found[index].due = hint.due
                if hint.join != nil { found[index].join = hint.join }
                continue
            }
            mine.append(hint)
        }
        func close(_ hint: Hint) -> Bool {
            // A day is never close: no countdown to an hour nobody said.
            guard hint.done != true, hint.day != true, let due = hint.due else { return false }
            let left = due.timeIntervalSince(now)
            // A promise's time of day counts down, but not past it.
            if promise(hint) { return left < 2 * 3600 && left > 0 }
            return left < 2 * 3600 && left > -15 * 60
        }
        // One row a thread: the agent's, which read it, over yab's own, the
        // promise's day lent to it.
        let threads = Set(found.compactMap { mailThread($0.url)?.thread })
        for hint in mine where promise(hint) {
            guard let thread = mailThread(hint.url)?.thread, threads.contains(thread),
                  let index = found.firstIndex(where: { mailThread($0.url)?.thread == thread }), found[index].due == nil else { continue }
            found[index].due = hint.due
            found[index].day = hint.day
        }
        mine.removeAll { hint in
            if hint.id.hasPrefix("mail.") { return threads.contains(String(hint.id.dropFirst("mail.".count))) }
            return promise(hint) && mailThread(hint.url).map { threads.contains($0.thread) } == true
        }
        let timed = (found + mine).filter(close).sorted { ($0.due ?? now) < ($1.due ?? now) }
        // A link just copied, and the page just in front on an iPhone: both
        // about this very minute.
        let copied = mine.filter { ($0.copied != nil || $0.phone != nil) && !close($0) }
        // What an agent found with a day in the next day and a half (a
        // dispute to answer tomorrow, a party tonight) goes before mail: a
        // reply can wait an hour, those can't.
        func soon(_ hint: Hint) -> Bool {
            guard hint.done != true, hint.routine == nil, let due = hint.due else { return false }
            return due.timeIntervalSince(now) < 36 * 3600 && due.timeIntervalSince(now) > -15 * 60
        }
        let rest = found.filter { !close($0) && !soon($0) }
        let pressing = found.filter { !close($0) && soon($0) }.sorted { ($0.due ?? now) < ($1.due ?? now) }
        let habits = mine.filter { $0.source == .habit && !close($0) }
        let tasks = mine.filter { $0.id.hasPrefix("task.") || $0.id.hasPrefix("wake.") }
        // Yours with a day in the next day and a half, or gone: before mail,
        // the latest first (a promise late two days before one due today).
        let owing = mine.filter { hint in
            guard hint.id.hasPrefix("promise.mine."), !close(hint), let due = hint.due else { return false }
            return due.timeIntervalSince(now) < 36 * 3600
        }.sorted { ($0.due ?? now) < ($1.due ?? now) }
        // A subscription you don't use, renewing by tomorrow (Purchases):
        // its day is near, so before mail.
        let renewals = mine.filter { $0.id.hasPrefix("renewal.") && !close($0) }
        // Mail that waits on you (Noticing.mail), with the agent's own finds.
        let mail = mine.filter { $0.id.hasPrefix("mail.") && !close($0) }
        // Yours with no day, and theirs gone late: after mail, oldest first.
        let owed = mine.filter { promise($0) && !close($0) && !owing.contains($0) }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return timed + tasks + copied + pressing + owing + renewals + mail + owed + rest.filter { $0.routine == nil } + habits
            + rest.filter { $0.routine != nil } + setup
    }

    /// A promise's row, either way (Promises).
    nonisolated static func promise(_ hint: Hint) -> Bool { hint.id.hasPrefix("promise.") }

    /// The rows that stand in the field's `room`, from the queue in its
    /// order: a promise only while it may (`may`, the budget), and one at
    /// most while anything else waits for the room. A promise passed over
    /// stays in the queue, first under Show All.
    nonisolated static func top(_ queue: [Hint], room: Int, may: (String) -> Bool) -> [Hint] {
        var out: [Hint] = []
        var promises = 0
        let others = queue.filter { !promise($0) }.count
        for hint in queue where out.count < room {
            if promise(hint) {
                guard may(hint.id) else { continue }
                let left = room - out.count
                // One promise at most while something else could stand.
                if promises >= 1 && others > out.count - promises && left > 0 { continue }
                promises += 1
            }
            out.append(hint)
        }
        return out
    }

    /// The tab a row's page came in: a new one since `before`, looked for
    /// over the next second (⌘T's field goes first, then the tab comes),
    /// or the one in front when it went in place.
    static func opened(after before: Set<UUID>, or blank: Tab?, in browser: Browser, tries: Int = 20, _ done: @escaping (Tab?) -> Void) {
        if let tab = browser.tabs.last(where: { !before.contains($0.id) }) { return done(tab) }
        // The empty tab that asked took the page itself.
        if let blank, !blank.isBlank { return done(blank) }
        guard tries > 0 else { return done(browser.active) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { opened(after: before, or: blank, in: browser, tries: tries - 1, done) }
    }

    /// The mail thread a row opens (yab://mail#thread=<account>|<id>), or nil.
    nonisolated static func mailThread(_ url: URL?) -> (account: String, thread: String)? {
        guard let url, url.scheme == "yab", url.host() == "mail",
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment, fragment.hasPrefix("thread=") else { return nil }
        let parts = fragment.dropFirst("thread=".count).split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Whether an agent's row and a meeting off the calendar are the same
    /// meeting: the same call, or much the same name within five minutes.
    nonisolated static func sameMeeting(_ found: Hint, _ meeting: Hint) -> Bool {
        // Two calls known: the same call or not, whatever they are called.
        let one = CallLink.key(found.join), two = CallLink.key(meeting.join)
        if let one, let two { return one == two }
        guard let a = found.due, let b = meeting.due, abs(a.timeIntervalSince(b)) <= 5 * 60 else { return false }
        let x = words(found.title), y = words(meeting.title)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        // The one name's every word in the other, and most of the other's:
        // "Prepare: Design sync" is "Design Sync", "Sync" is not "Design
        // Sync w/ Legal".
        let (small, large) = x.count <= y.count ? (x, y) : (y, x)
        return small.isSubset(of: large) && Double(small.count) / Double(large.count) >= 0.6
    }

    /// A title's words, lowercased, without the little ones that join them.
    nonisolated static func words(_ title: String) -> Set<String> {
        let little: Set<String> = ["w", "with", "and", "the", "a", "an", "of", "for", "to", "re"]
        return Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !little.contains($0) })
    }


    /// For the look: the rows still up, so it can say which are done, and
    /// the kinds of things you asked not to be shown.
    func brief() -> (live: String, rules: String, removed: String) {
        let now = Hints.now
        let live = Hints.load().filter { $0.done == nil && $0.when == nil && Hints.lasts($0, now: now) }.map { found in
            "- \(found.id): \(found.title) (\(found.url ?? found.site ?? "no link"))"
        }
        let rules = (((try? String(contentsOf: Hints.rules, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            + Noticing.shared.off.said).map { "- " + $0 }
        let removed = (store.array(forKey: "hints.removed") as? [[String: Any]] ?? [])
            .filter { now.timeIntervalSince1970 - (($0["at"] as? Double) ?? 0) < 14 * 86_400 }
            .compactMap { item -> String? in
                guard let title = item["title"] as? String else { return nil }
                let site = item["site"] as? String ?? ""
                return "- " + title + (site.isEmpty ? "" : " (\(site))")
            }
        return (live.joined(separator: "\n"), rules.joined(separator: "\n"), removed.joined(separator: "\n"))
    }

    /// An agent's findings: new ones, ones it handed back again, and the
    /// ids of rows it saw dealt with. Nil when kept.
    func keep(_ items: [[String: Any]], resolved: [String] = [], known: Set<String>? = nil, by routine: String? = nil, look: Bool = true) -> String? {
        let now = Hints.now
        let admitted = Hints.admit(items, known: known)
        let items = admitted.items
        if !admitted.refused.isEmpty { note("refuse " + admitted.refused.joined(separator: " ")) }
        let before = Hints.resolve(resolved, in: Hints.load(), now: now)
        // A routine offered once a week at most, and never one already set.
        var offered = false
        let lastOffer = store.object(forKey: "hints.routine-offered") as? Date ?? .distantPast
        // Six that need you, and the subscriptions found besides them.
        let kept: [Found] = items.prefix(12).compactMap { item in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let when = (item["when"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let task = (item["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let when, let task, !task.isEmpty {
                guard !offered, now.timeIntervalSince(lastOffer) > 7 * 86_400, Routines.schedule(when) != nil,
                      !Routines.shared.all.contains(where: { $0.prompt.lowercased() == task.lowercased() }) else { return nil }
                offered = true
                let id = "routine." + Hints.hash(task.lowercased())
                return Found(id: id, title: String(title.prefix(60)), detail: String((item["detail"] as? String ?? "").prefix(120)), url: nil,
                             site: item["site"] as? String, kind: "routine", at: now, when: when, task: task)
            }
            var found = Hints.found(item, title: title, before: before, now: now)
            found.by = routine
            return found
        }
        if let trouble = Hints.save(Hints.merge(kept, into: before, now: now)) { return trouble }
        if offered { store.set(now, forKey: "hints.routine-offered") }
        // A glance at new mail is not the morning's look: that still comes.
        if look { store.set(Date(), forKey: "agents.watched") }
        refresh()
        return nil
    }


    /// Rows the look saw dealt with, marked done now.
    nonisolated static func resolve(_ ids: [String], in all: [Found], now: Date) -> [Found] {
        all.map { found in
            var found = found
            if ids.contains(found.id), found.done == nil { found.done = now }
            return found
        }
    }

    /// One thing the agent handed over, as kept: the row it already is when
    /// handed back by its id or found again, keeping when it was opened and
    /// put off, or a new one.
    nonisolated static func found(_ item: [String: Any], title: String, before: [Found], now: Date) -> Found {
        let url = text(item["url"])
        // One handed back by its id is the same row; otherwise the same
        // thing found again keeps its name, so a × holds.
        let given = (item["id"] as? String).flatMap { id in before.contains { $0.id == id } ? id : nil }
        let id = given ?? "found." + hash(url.map(place) ?? title)
        var found = before.first { $0.id == id } ?? Found(id: id, title: title, detail: "", at: now)
        found.title = String(plain(title).prefix(60))
        found.detail = String(plain(item["detail"] as? String ?? "").prefix(120))
        found.url = url
        found.site = text(item["site"])
        found.kind = text(item["kind"])
        found.confirmed = now
        found.due = date(item["due"])
        found.quote = text(item["quote"]).map { String($0.prefix(200)) }
        found.draft = text(item["draft"]).map { String($0.prefix(4000)) }
        found.join = text(item["join"])
        found.subscription = text(item["subscription"]).flatMap { ["trial", "renewal"].contains($0) ? $0 : nil }
        found.service = text(item["service"]).map { host($0) }
        return found
    }

    /// What was handed over now, first, and what was kept before and still
    /// lasts after it, twenty at most.
    nonisolated static func merge(_ kept: [Found], into before: [Found], now: Date) -> [Found] {
        // The same thing twice in one hand counts once.
        var ids = Set<String>()
        let kept = kept.filter { ids.insert($0.id).inserted }
        let rest = before.filter { old in !ids.contains(old.id) && lasts(old, now: now) }
        return Array((kept + rest).prefix(20))
    }

    /// A row's words in yab's own manner: one line, and no long dash, a
    /// comma instead.
    nonisolated static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*[—–]\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Where a thing lives, the same however it was written: no scheme, no
    /// www, no slash at the end, no tracking parameters, and of a fragment
    /// only its last part, so Gmail's #inbox/ID and #all/ID are one thread.
    nonisolated static func place(_ address: String) -> String {
        guard var parts = URLComponents(string: address), let raw = parts.host else { return address }
        var path = parts.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let noise = ["fbclid", "gclid", "dclid", "yclid", "msclkid", "igshid", "mc_cid", "mc_eid", "_ga", "_gl", "ref", "ref_src", "si"]
        let kept = (parts.queryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !noise.contains(name)
        }
        parts.queryItems = kept.isEmpty ? nil : kept.sorted { $0.name < $1.name }
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        let tail = (parts.fragment ?? "").split(separator: "/").last.map { "#" + $0 } ?? ""
        return host(raw) + (path == "/" ? "" : path) + query + tail
    }

    /// A host as compared: lowercased, without www, whatever was given (a
    /// host, or a whole address).
    nonisolated static func host(_ text: String) -> String {
        var host = text.lowercased().trimmingCharacters(in: .whitespaces)
        if host.contains("/"), let inside = URL(string: host)?.host() { host = inside }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The name a site goes by, whatever host it is on: "notion" for
    /// notion.com, www.notion.so and app.notion.com, "bbc" for bbc.co.uk.
    /// An agent names a service's canonical domain; people open it wherever
    /// they do, and it is still the same thing they pay for.
    nonisolated static func brand(_ address: String) -> String {
        labels(address).last ?? host(address)
    }

    /// A host's own labels, the shared ending (com, co.uk, a dev wildcard)
    /// left off.
    nonisolated static func labels(_ address: String) -> [String] {
        var parts = host(address).split(separator: ".").map(String.init)
        guard parts.count > 1 else { return parts }
        let shared = ["localtest.me", "nip.io", "sslip.io", "lvh.me"]
        if let end = shared.first(where: { host(address).hasSuffix("." + $0) }) {
            parts.removeLast(end.split(separator: ".").count)
            return parts
        }
        parts.removeLast()
        if parts.count > 1, let second = parts.last, ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(second), second.count <= 3 {
            parts.removeLast()
        }
        return parts
    }

    /// Whether a host opened is the service of that name.
    nonisolated static func uses(_ opened: String, _ service: String) -> Bool {
        labels(opened).contains(brand(service))
    }

    /// Whether a row may lead there: a host the person has been to, or one
    /// under or over it. A message can't put a stranger's page on the new
    /// tab ("Verify your bank") by asking the agent reading it to.
    nonisolated static func known(_ address: String?, among hosts: Set<String>) -> Bool {
        guard let address, let url = URL(string: address), url.scheme != "yab", let raw = url.host() else { return true }
        let here = host(raw)
        return hosts.contains { there in here == there || here.hasSuffix("." + there) || there.hasSuffix("." + here) }
    }

    /// Of what an agent handed over, what may become rows: none leading to a
    /// place never visited, and a meeting's link only when it is a meeting's.
    nonisolated static func admit(_ items: [[String: Any]], known hosts: Set<String>?) -> (items: [[String: Any]], refused: [String]) {
        var refused: [String] = []
        let items: [[String: Any]] = items.compactMap { item in
            var item = item
            if let hosts, !known(item["url"] as? String, among: hosts) {
                refused.append((item["url"] as? String).flatMap { URL(string: $0)?.host() } ?? "?")
                return nil
            }
            if let join = item["join"] as? String, CallLink.key(URL(string: join)) == nil { item["join"] = nil }
            return item
        }
        return (items, refused)
    }

    nonisolated private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    nonisolated private static func hash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 36)
    }

    /// ISO 8601, with or without seconds, a zone or its fraction; without
    /// a zone, this Mac's.
    nonisolated static func date(_ value: Any?) -> Date? {
        guard let text = text(value) else { return nil }
        let full = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            full.formatOptions = options
            if let date = full.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - for the bench

    /// Everything the rows remember, gone: a test world starting its morning over.
    func forget() {
        forgetFound()
        for key in ["hints.dismissed", "hints.routine-offered", "agents.watched", "hints.today", "hints.removed"] { store.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: Hints.rules)
        Noticing.shared.forgetOff()
        Hints.offset = 0
        journal = []
    }

    /// Rows let go of without a trace, a test's own.
    func drop(_ ids: [String]) {
        Hints.change { $0.removeAll { ids.contains($0.id) } }
        refresh()
    }

    /// What agents found, gone with the history it came from: the rows and
    /// what is kept behind them, snippets of mail and drafts among it. What
    /// you said not to be shown stays; that is yours, not history.
    func forgetFound() {
        store.removeObject(forKey: "hints.rows")
        store.removeObject(forKey: "hints.shown")
        try? FileManager.default.removeItem(at: Hints.file)
        rows = []
        arriving = []
        waiting = false
        keepRows()
    }

    /// The rows as drawn and everything kept behind them, a --test run's.
    func state() -> [String: Any] {
        let now = Hints.now
        let stamp = ISO8601DateFormatter()
        func row(_ hint: Hint) -> [String: Any] {
            var out: [String: Any] = ["id": hint.id, "title": hint.title, "detail": HintList.detail(hint, now: now),
                                      "setup": hint.setup, "arriving": arriving.contains(hint.id)]
            if let source = hint.source { out["source"] = source.rawValue }

            if let url = hint.url { out["url"] = url.absoluteString }
            if let seen = hint.seen { out["seen"] = stamp.string(from: seen) }
            if let due = hint.due { out["due"] = stamp.string(from: due) }
            if hint.quote != nil { out["quote"] = hint.quote }
            if hint.draft != nil { out["draft"] = true }
            if hint.done == true { out["done"] = true }
            if HintList.joining(hint, now: now) { out["join"] = true }
            if hint.cancel == true { out["cancel"] = true }
            if hint.routine != nil { out["routine"] = hint.routine }
            if let step = step(hint) { out["step"] = step }
            return out
        }
        // Everything kept, as it is written down, dates as ISO 8601.
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .iso8601
        let kept = (try? coder.encode(Hints.load())).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        var out: [String: Any] = ["rows": rows.map(row), "kept": kept, "waiting": waiting, "now": stamp.string(from: now), "journal": journal,
                                  "eligible": eligible, "rules": brief().rules, "removed": brief().removed, "working": working,
                                  "off": Noticing.shared.hidden.map(\.id)]
        if let knowing = knowingRun { out["knowing"] = knowing.id }
        return out
    }
}

// MARK: - when to look

extension Agents {
    /// The first time yab is in front on a new morning, or after three
    /// hours away: the moments a person catches up anyway. Nil when it
    /// isn't time, it is off, or Get to Know is at work.
    @discardableResult
    func look(force: Bool = false, backgroundPermit: BackgroundPermit? = nil) -> Session? {
        guard let permit = backgroundPermit ?? BackgroundConsent.permit(), permit.valid,
              AgentSetupModel.shared.anyConnected else { return nil }
        let hints = Hints.shared
        // A look silent for ten minutes is stuck (a model that stopped
        // answering, seen in the eval for over a quarter of an hour): it is
        // let go of, or no look would ever start again until yab did.
        for stuck in sessions where stuck.quiet && Agents.looks.contains(stuck.name) && stuck.state.live
            && Date().timeIntervalSince(max(stuck.touched, stuck.began)) > 600 {
            _ = stop(stuck.id)
        }
        // Not beside Get to Know: two agents at once in a first minute, and
        // a look that would find a memory still being written. The first
        // look comes as it ends instead (Hints.ended).
        guard BackgroundConsent.canStartMorning(), hints.watching, Store.settings.bool(forKey: "bench"),
              !sessions.contains(where: { $0.quiet && Agents.looks.contains($0.name) && $0.state.live }),
              !Agents.lookWaits(for: sessions)
        else { return nil }
        if !force {
            let last = Store.settings.object(forKey: "agents.watched") as? Date ?? .distantPast
            let away = Store.settings.object(forKey: "agents.away") as? Date ?? .distantPast
            guard Agents.time(now: Date(), last: last, away: away) else { return nil }
        }
        Store.settings.set(Date(), forKey: "agents.watched")
        let brief = hints.brief()
        // Sealed, as Get to Know is: its tabs a shut folder, "Catching up",
        // nobody asked anything.
        return run(prompt: Agents.lookPrompt(live: brief.live, rules: brief.rules, removed: brief.removed, now: Hints.now, mailbox: MailCenter.shared.connected),
                   cli: nil, effort: "medium",
                   access: "browser", quiet: true, name: "Looking", sealed: true, resume: nil, backgroundPermit: permit)
    }

    /// The quiet passes that hand rows over: the look, and a glance at new mail.
    static let looks: Set<String> = ["Looking", "Glancing"]

    /// A person's new mail that waits on the user, as the Mac's model read
    /// it (MailCenter.noticed): a short look at those threads alone, so the
    /// row says what they want and carries a reply hours before the next
    /// look would. Once in half an hour at most, eight a day, each thread
    /// once for each new mail in it; never in place of the morning look.
    @discardableResult
    func glance(at notices: [Noticing.MailNotice], now: Date = Date()) -> Session? {
        let store = Store.settings
        guard let permit = BackgroundConsent.permit(mail: true, settings: store), store.bool(forKey: "bench"), MailCenter.shared.connected,
              AgentSetupModel.shared.anyConnected else { return nil }
        var glanced = store.dictionary(forKey: "agents.glanced") as? [String: Double] ?? [:]
        let fresh = notices.filter { $0.why == .waitingOnYou && (glanced[$0.thread] ?? 0) < $0.last.timeIntervalSince1970 }
        guard !fresh.isEmpty,
              !sessions.contains(where: { $0.quiet && Agents.looks.contains($0.name) && $0.state.live }),
              !Agents.lookWaits(for: sessions) else { return nil }
        let last = max(store.object(forKey: "agents.glance") as? Date ?? .distantPast, store.object(forKey: "agents.watched") as? Date ?? .distantPast)
        let day = (store.array(forKey: "agents.glances") as? [Double] ?? []).filter { now.timeIntervalSince1970 - $0 < 86_400 }
        guard Agents.mayGlance(now: now, last: last, today: day.count) else { return nil }
        store.set(now, forKey: "agents.glance")
        store.set(day + [now.timeIntervalSince1970], forKey: "agents.glances")
        for notice in fresh { glanced[notice.thread] = notice.last.timeIntervalSince1970 }
        if glanced.count > 300 {
            for (id, _) in glanced.sorted(by: { $0.value < $1.value }).prefix(glanced.count - 300) { glanced[id] = nil }
        }
        store.set(glanced, forKey: "agents.glanced")
        let brief = Hints.shared.brief()
        let threads = fresh.prefix(5).map { "- \($0.account)|\($0.thread): \($0.who) · \($0.subject)" }.joined(separator: "\n")
        return run(prompt: Agents.glancePrompt(threads: threads, rules: brief.rules, removed: brief.removed, now: now),
                   cli: nil, effort: "low", access: "browser", quiet: true, name: "Glancing", sealed: true, resume: nil, backgroundPermit: permit)
    }

    /// Whether a glance may start: half an hour after the last look or
    /// glance, and fewer than eight in the last day.
    nonisolated static func mayGlance(now: Date, last: Date, today: Int) -> Bool {
        now.timeIntervalSince(last) >= 1800 && today < 8
    }

    static func glancePrompt(threads: String, rules: String, removed: String = "", now: Date) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "EEEE yyyy-MM-dd HH:mm xxx"
        var prompt = """
        New mail came that may wait on the user. Nobody is watching this; don't talk to the user. It is \
        \(clock.string(from: now)) here.

        Read only these threads, each whole, with `mail_read` (reading there marks nothing read):
        \(threads)

        Then call `suggest` once. Each thread that still waits on the user after their own last word is an \
        item: `kind` reply; `title`, what they want and the step, in the language the mail is in, a comma or \
        a colon where a dash would go (Danny says autofill still fails); `detail`, one line of specifics; \
        `url` yab://mail#thread=<account>|<thread id>; `site`, the sender's host; `due` when it names a day; \
        and `draft`, the reply itself in the user's language and tone, when `memory_read` USER.md tells you \
        enough to answer as them. Each thread that waits on no one (answered already, an automatic alert, an \
        auto-reply, a sales pitch) goes in `quiet` as <account>|<thread id>. Rows already on the new tab are \
        left out: they stay as they are. Open no tab, send nothing, mark nothing read.
        """
        if !rules.isEmpty {
            prompt += "\n\nThe user asked not to be shown things like these; leave out anything of their kind:\n" + rules
        }
        if !removed.isEmpty {
            prompt += "\n\nThe user put these away lately; don't bring them back:\n" + removed
        }
        return prompt
    }

    /// Get to Know at work: a live run of it, not one of yab's own quiet
    /// passes (the profile from memory is quiet, and knowing too). The run
    /// Settings (knowingNow) and setUpMemory (knowingRun) mean.
    static func getsToKnow(_ session: Session) -> Bool {
        session.knowing && !session.quiet && session.parent == nil && session.state.live
    }

    /// Whether the morning look waits: Get to Know is at work.
    static func lookWaits(for sessions: [Session]) -> Bool {
        sessions.contains { getsToKnow($0) }
    }

    /// Whether coming back to yab now is a moment to look: the first time
    /// since five this morning, or after three hours away and three since
    /// the last look. Five, not midnight: a night owl at 1:00 is still in
    /// yesterday.
    nonisolated static func time(now: Date, last: Date, away: Date) -> Bool {
        let calendar = Calendar.current
        var morning = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now) ?? now
        if morning > now { morning = calendar.date(byAdding: .day, value: -1, to: morning) ?? morning }
        let newDay = last < morning
        let back = now.timeIntervalSince(away) >= 3 * 3600 && now.timeIntervalSince(last) >= 3 * 3600
        return newDay || back
    }

    static func lookPrompt(live: String, rules: String, removed: String = "", now: Date, mailbox: Bool = false) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "EEEE yyyy-MM-dd HH:mm xxx"
        var prompt = """
        Quietly check the places the user relies on for anything that needs them today, and hand back \
        what does with `suggest`: at most six things, most urgent first, and besides them any subscriptions \
        you find (below), which don't count among the six. Nobody is watching this; don't talk to the user. It is \
        \(clock.string(from: now)) here.

        1. Call `history` to see the sites they use and how regularly. Decide from it which are worth \
        checking now: their mail, calendar, work chat, the money and business dashboards they watch, \
        trips, deliveries, anything where something can be waiting on them. Skip what is only reading \
        or entertainment. `memory_read` USER.md for who they are and which accounts are which.
        2. Look at each in a tab of your own (read the site's skill first when a tool names one). Read \
        lists and previews: don't open a message unless you must to understand it, and never archive, \
        reply, accept or change anything. Leave every message as unread as you found it: the user must \
        still see as new what is new. Mail sites (Gmail, Outlook, Superhuman, any other) mark a message \
        read when it is opened, so open one only when its preview can't tell you whether it waits on \
        the user, note first whether it was unread, and if it was, mark it unread again before you \
        leave it (the site's Mark as unread, or its key: Shift+U in Gmail, Ctrl+U or U in Outlook, U in \
        Superhuman), then check in the list that it shows unread again. A meeting today is the exception: \
        open the event itself (a calendar's list rarely says what to prepare or where the call is), \
        and its `url` is the event, not the list. A place that wants you to sign in is skipped: never \
        sign in, hand off or ask, since nobody is there to answer.
        3. Keep only what asks something of them or will soon: a person waiting on their answer (a \
        question, a bug report, an offer with a date) where their own last word in the thread doesn't \
        already answer it, a payment that failed or is due, a meeting today with something to prepare, \
        a trip tomorrow, a delivery that needs them, and a notice whose date touches them (work in \
        their building, a plan that changes on a day). Not newsletters, not notifications for their \
        own sake, not an automatic alert answered with a button (a bank asking "was this you?"), not an \
        auto-reply, not a sales pitch, not what they have clearly already read and dealt with.
        4. Call `suggest` once, with the most urgent first: what has a time in the next few hours (a \
        meeting to prepare for, a deadline today) before what can wait until tomorrow. Each item: `kind`, what it is, for its picture \
        (mail, reply, money, failed, invoice, flight, stay, calendar, meeting, review, code, chat, shopping, \
        delivery, document, sign, reading, security, video); `title`, a few words on what it is \
        (Acme wants an answer by Friday); `detail`, one line with the specifics (Offer for the Q4 pilot, \
        $40k, Alex Kim); `url`, the thing itself (the message's or event's own link) so the user lands \
        on it; `site`, its host. Write titles and details plainly, a comma or a colon where a dash would \
        go, in the language the thing itself is in, whatever language this brief is in. And these, whenever they apply:
        - `quote`: a short passage copied word for word from the page `url` opens, the sentence the user \
        should see first (the question asked, the amount, the date), so Yab can open the page at it. \
        Copy it from that very page: a list and the thing's own page word the same thing differently.
        - `due`: whenever it has a date or a time, ISO 8601 with the zone: a meeting's start, the end \
        of the day it is asked for ("by Friday" is that Friday at 17:00), a trial's end. Yab moves it up \
        and counts down to it, so leave it out only when nothing says when.
        - `join`: for a meeting with a video call, its link, from the event itself (open the event if \
        the list doesn't show it); Yab offers it as Join as the meeting starts.
        - `draft`: for a message that wants a reply, when memory tells you enough to answer as the user, \
        the reply itself, in their language and tone, ready to send. Never put it on the site yourself.
        - `subscription`: "trial" for a free trial that will start charging, "renewal" for a paid plan \
        that renews, found in receipts and notices in their mail, with `due` the day it charges and the \
        amount in `detail`, `service` the service's own site (figma.com, not the mail it came in), and \
        `url` the page where it is managed or cancelled when the notice links \
        to one (the notice itself otherwise). Hand back every one you find: Yab decides when to show it.
        If nothing needs them, call `suggest` with no items.
        One of the items may instead offer a routine, when the history shows the user checking the same \
        thing by hand on a schedule (the Stripe dashboard most weekday mornings, one inbox label every \
        evening): `when` (weekdays 9:00, daily 18:30, mon,thu 8:15, monthly 1 9:00, first monday 9:00, every 2 weeks fri 17:00), `task` (what the routine would do, \
        as a request: Check Stripe for failed charges and tell me), `title` (Every weekday 9:00: check \
        Stripe), `detail` (why: you open it most mornings). Only on a clear pattern; Yab shows one a week \
        at most.
        5. Before you close your tabs, go back over every message you opened: each one that was unread when \
        you found it must show unread again in its list; mark it unread now if it doesn't. Then close your tabs.
        """
        // Once a week: the profile forms fill from, against the user's own
        // LinkedIn, only the keys that changed (docs/forms.md).
        let profile = Profile.load()
        if !profile.isEmpty, Date().timeIntervalSince(profile.updated ?? .distantPast) > 7 * 86400,
           Date().timeIntervalSince(Store.settings.object(forKey: "profile.checked") as? Date ?? .distantPast) > 7 * 86400 {
            Store.settings.set(now, forKey: "profile.checked")
            prompt += """


            Also, once this week: open the user's own LinkedIn profile (or their own site if they have no \
            LinkedIn) in a tab of your own and compare it with `profile`. If their company, title, headline or \
            location there differs, call `profile` with `set` for those keys only and `source` "LinkedIn". \
            Change nothing else, and close the tab.
            """
        }
        // Answers forms kept on their own since the last look: which to
        // keep for good and which were written for that one form.
        let answers = FormAnswers.unchecked().count
        if answers > 0 {
            prompt += """


            Also: forms the user sent kept \(answers) new \(answers == 1 ? "answer" : "answers") with nothing asked. \
            Call `form_answers` to see them, then once more with `drop` for those written for that one form only \
            or that look wrong, and `keep` for the rest. Decide from the words alone; don't open the sites.
            """
        }
        if !live.isEmpty {
            prompt += """


            These are already on the user's new tab from earlier looks:
            \(live)
            Check each where it lives. One dealt with (answered, paid, passed, cancelled, no longer asked) \
            goes in `suggest`'s `resolved`, by its id. One still waiting on them goes in `items` again with \
            its `id`, so it keeps its place; don't hand it back as new. Checking these is not the whole \
            look: go through each place for what came since as carefully as on a first look, new \
            messages above all.
            """
        }
        if mailbox {
            prompt += """


            Their mail is already on this Mac, sorted: call `mail_triage` for it and `mail_read` for a thread \
            you must understand, instead of opening their mail in a tab (reading it here marks nothing read). \
            Go through every thread under Needs you that a person wrote: read it whole, and hand back the ones \
            still waiting on the user after their own last word, with `url` yab://mail#thread=<account>|<thread id> \
            from `mail_triage`, a title that says what they want and the step (Danny says autofill still fails), \
            and a `draft` when memory tells you enough to answer as the user. A robot's notice with a date that \
            touches them belongs too. Every thread you read that waits on no one (answered already, an alert, \
            an auto-reply, a pitch) goes in `quiet` as <account>|<thread id>, so yab stops offering it.
            """
            if MailRecall.wanted { prompt += " For anything older, `mail_recall` searches five years of their mail by what it says." }
        }
        if !rules.isEmpty {
            prompt += """


            The user asked not to be shown things like these; leave out anything of their kind:
            \(rules)
            """
        }
        if !removed.isEmpty {
            prompt += """


            The user put these away lately; don't bring them back, under another link either:
            \(removed)
            """
        }
        return prompt
    }
}

// MARK: - the rows

/// Under a new tab's field: the same rows the field's own list has, on the
/// ground rather than on the card.
struct HintList: View {
    let browser: Browser
    @ObservedObject private var hints = Hints.shared
    @ObservedObject private var agents = Agents.shared
    @State private var hovered: String?

    /// Rows closing up after one goes, or making room for one coming.
    static let close = Animation.timingCurve(0.3, 0, 0.2, 1, duration: 0.3)

    var body: some View {
        // Times count down by the minute; nothing else here moves on its own.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let now = Hints.now
            let coming = hints.rows.filter { hints.arriving.contains($0.id) }.map(\.id)
            VStack(spacing: 0) {
                ForEach(hints.rows) { hint in
                    row(hint, now: now)
                        .modifier(ComingIn(index: coming.firstIndex(of: hint.id) ?? 0, fresh: hints.arriving.contains(hint.id)))
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .animation(HintList.close, value: hints.rows.map(\.id))
        }
        .onAppear { hints.refresh(); hints.saw() }
        .onChange(of: hints.arriving) { _, _ in hints.saw() }
        .onChange(of: hints.waiting) { _, _ in hints.saw() }
        // Get to Know started elsewhere, or over: its row comes or goes.
        .onChange(of: agents.sessions.first { Agents.getsToKnow($0) }?.id) { _, _ in hints.refresh() }
    }

    /// The gray line: how long until it, while that is close, and what the
    /// agent said.
    static func detail(_ hint: Hint, now: Date) -> String {
        if let copied = hint.copied {
            let ago = "Copied " + Hints.ago(copied, now: now)
            return hint.detail.isEmpty ? ago : ago + " · " + hint.detail
        }
        guard let due = hint.due, let until = Hints.until(due, now: now) else { return hint.detail }
        return hint.detail.isEmpty ? until : until + " · " + hint.detail
    }

    /// Where it stands, in a word or two, for the end of its row in the
    /// field: the long detail is the preview's. Nothing when there is no
    /// state to say.
    static func status(_ hint: Hint, now: Date) -> String {
        // Handed to the agent (Do It): its words while it works or asks.
        if let words = Hints.shared.handedWords(hint.id) { return words }
        if let copied = hint.copied { return "Copied " + Hints.ago(copied, now: now) }
        // A promise says its own day, in calendar days (Promises.words).
        if Hints.promise(hint) {
            let words = hint.detail.components(separatedBy: " · ").first { $0 != "Still on?" } ?? ""
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        // A renewal's title says its day already; its hour is nobody's.
        if hint.id.hasPrefix("renewal.") { return "" }
        if let due = hint.due, let until = Hints.until(due, now: now) { return until.prefix(1).uppercased() + until.dropFirst() }
        if hint.draft != nil { return "Reply ready" }
        guard let due = hint.due, hint.done != true else { return "" }
        let calendar = Calendar.current
        let time = due.englishFormatted(date: .omitted, time: .shortened)
        if calendar.isDate(due, inSameDayAs: now) { return "Due " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
            return "Due tomorrow"
        }
        return due < now ? "Overdue" : "Due " + due.formatted(AppDates.dateTime.month(.abbreviated).day())
    }

    /// A meeting in its last ten minutes, or begun a little ago.
    static func joining(_ hint: Hint, now: Date) -> Bool {
        guard hint.join != nil, let due = hint.due else { return false }
        let left = due.timeIntervalSince(now)
        return left <= 10 * 60 && left > -15 * 60
    }

    private func row(_ hint: Hint, now: Date) -> some View {
        let step = hints.step(hint)
        let done = hint.done == true
        return HStack(spacing: Omnibox.gap) {
            ZStack {
                mark(hint, working: step != nil)
                    .saturation(hint.seen == nil ? 1 : 0.25)
                    .opacity(done ? 0 : hint.seen == nil ? 1 : 0.75)
                if done { Tick { hints.settle(hint.id) } }
            }
            .frame(width: Omnibox.slot)
            Text(hint.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Text(step ?? HintList.detail(hint, now: now))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if HintList.joining(hint, now: now), let join = hint.join, !done {
                Button("Join") { browser.take(Suggestion(key: join.host() ?? "", title: hint.title, url: join, kind: .address)) }
                    .buttonStyle(.yab(.primary, .small))
            }
            // Its place kept beside Join, so Join stays put as it comes.
            let joins = HintList.joining(hint, now: now) && hint.join != nil
            if hovered == hint.id || joins, step == nil, !done {
                Button { hints.dismiss(hint) } label: {
                    Symbol("xmark", size: 10).foregroundStyle(Palette.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyTip(hint.local && Noticing.Kind.of(hint)?.isMail == true && hint.id != "mail.skipped" ? "Hide until new mail" : "Don't show this again")
                .opacity(hovered == hint.id ? 1 : 0)
                .allowsHitTesting(hovered == hint.id)
            }
        }
        // The highlight runs the field's full width, the marks still in
        // the field's column.
        .padding(.horizontal, Omnibox.gutter)
        .frame(height: 34)
        .background {
            if hovered == hint.id, !done {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.wash)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if step == nil { hints.take(hint, in: browser) } }
        .onHover { inside in hovered = inside ? hint.id : (hovered == hint.id ? nil : hovered) }
        .contextMenu { if !hint.setup, !done { menu(hint, now: now) } }
        .pointerTip(hint.seen.map { "Opened " + $0.englishFormatted(date: .omitted, time: .shortened) } ?? "")
    }

    /// The row's own menu, the system's. One of yab's own is about today:
    /// Not Today and Done are one, as in the field.
    @ViewBuilder
    private func menu(_ hint: Hint, now: Date) -> some View {
        if hint.local {
            Button("Open") { hints.take(hint, in: browser) }
            Button("Not Today") { Noticing.shared.hideToday(hint) }
            Button("Done") { Noticing.shared.hideToday(hint) }
            Divider()
            if hint.source == .habit {
                Button("Don't Suggest This") { hints.never(hint) }
            } else if let sender = hint.sender, let kind = Noticing.Kind.of(hint) {
                Menu("Don't Show Things Like This") {
                    Button("Mail from \(sender.name)") { hints.never(hint, person: true) }
                    Button(kind.title) { hints.never(hint) }
                }
            } else {
                Button("Don't Show Things Like This") { hints.never(hint) }
            }
        } else {
            found(hint, now: now)
        }
    }

    @ViewBuilder
    private func found(_ hint: Hint, now: Date) -> some View {
        let later = Hints.laterToday(from: now)
        Button("Open") { hints.take(hint, in: browser) }
        Button(later == now.addingTimeInterval(3 * 3600) ? "In 3 Hours" : "Later Today") { hints.putOff(hint, until: later) }
        Button("Tomorrow Morning") { hints.putOff(hint, until: Hints.tomorrowMorning(from: now)) }
        Button("Done") { hints.finish(hint) }
        Divider()
        Button("Don't Show Things Like This") { hints.never(hint) }
    }

    @ViewBuilder
    private func mark(_ hint: Hint, working: Bool) -> some View {
        switch hint.icon {
        case .face:
            Face(pose: working ? .read : .watch, size: Omnibox.mark + 2, tint: Palette.muted)
        case .symbol(let name):
            Symbol(name, size: Omnibox.mark).foregroundStyle(Palette.muted)
        case .picture(let kind, let site):
            HintPicture(kind: kind, site: site, size: Omnibox.mark + 6)
        case .site(let host):
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            Mark(icon: Favicons.shared.cached(host) ?? Favicons.shared.cached(bare),
                 letter: bare.first.map { String($0).uppercased() } ?? "",
                 size: (Omnibox.mark * Glyphs.scale).rounded())
        }
    }
}

/// On New Tab, in the column and by the row's plus: something an agent
/// found came while you were on a page. No number; gone once a new tab has
/// shown it. Its own view, so only it is drawn again when it changes.
struct NewsDot: View {
    @ObservedObject private var hints = Hints.shared
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Circle()
            .fill(Palette.ink)
            .frame(width: 5, height: 5)
            .scaleEffect(hints.waiting ? 1 : 0.01)
            .opacity(hints.waiting ? 1 : 0)
            .animation(still ? nil : .spring(duration: 0.3, bounce: 0.4), value: hints.waiting)
            .offset(x: 2, y: -1)
            .allowsHitTesting(false)
            .accessibilityHidden(!hints.waiting)
            .accessibilityLabel("Something new on a new tab")
    }
}

/// The row's plus, out of sight until the pointer is near, or while
/// something found waits on a new tab: then it stands, the dot on its corner.
/// A modifier of its own, so only it is drawn again when the dot changes.
struct PlusNews: ViewModifier {
    let nearby: Bool
    @ObservedObject private var hints = Hints.shared

    func body(content: Content) -> some View {
        let shown = nearby || hints.waiting
        content
            .overlay(alignment: .topTrailing) { NewsDot().offset(x: -4, y: 4) }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
    }
}

/// A row dealt with: a tick drawn where its picture was, then it goes.
private struct Tick: View {
    let gone: () -> Void
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 3.5, y: 9.5))
            path.addLine(to: CGPoint(x: 7.5, y: 13.5))
            path.addLine(to: CGPoint(x: 15, y: 5))
        }
        .trim(from: 0, to: drawn)
        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .frame(width: 18, height: 18)
        .task {
            withAnimation(.easeOut(duration: still ? 0 : 0.3)) { drawn = 1 }
            try? await Task.sleep(for: .seconds(still ? 0.3 : 0.55))
            gone()
        }
    }
}

// MARK: - an agent, for the page you are on

// What an agent can do on the page in front of you, from the skills for its
// site: draft a reply to a Gmail thread, review a pull request, plan an
// issue. ⌘J does the first, from anywhere on the page. Opened from a new
// tab's row, the page says so once, in a light
// pill at its foot; any other page says nothing, and the first time on a site
// with actions the corner tells the key, once.

extension Agents {
    /// Starts an action on a tab of yours: the agent works in it, as a
    /// guest you let in, and its dock comes on at the page's foot.
    @discardableResult
    func act(_ action: Skills.Action, on tab: Tab, item: SiteItem? = nil) -> Session {
        let url = tab.address?.absoluteString ?? ""
        let ending = action.draft == nil
            ? "and finish with a short plain answer."
            : Agents.draftEnding
        let skill = action.skill.isEmpty ? "" : "Read the \"\(action.skill)\" skill first. "
        // A button beside one thing on the page (SiteItems): that thing.
        let about = item.map { "It is about one thing on that page, \($0.sentence). " } ?? ""
        let prompt = """
        The user is looking at a page in their own tab \(Bench.short(tab)) (\(url)) and asked you, with one key, \
        to do this there: \(action.prompt) \(about)\(skill)Work in that tab; don't open \
        another unless you must, \(ending)
        """
        let session = run(prompt: prompt, cli: nil, access: "browser", resume: nil)
        session.draft = action.draft
        // Asked for from the page itself: no "use this tab?" in between.
        tab.allowed.insert(session.id)
        tab.guest = session.id
        Hints.shared.unoffer(tab.id)
        return session
    }

    /// A reply the morning's look already wrote, put into the page of a
    /// tab the row just opened, as ⌘J would draft one: never sent.
    @discardableResult
    func write(_ draft: String, on tab: Tab) -> Session {
        let skill = Skills.actions(for: tab.address).first { $0.draft != nil }?.skill ?? ""
        let action = Skills.Action(
            title: "Reply", pattern: "*",
            prompt: "A reply to what is open here is already written for the user, between <reply> and </reply>: "
                + "<reply>\(draft)</reply> Open the reply composer here and write exactly that text into it.",
            skill: skill, draft: Skills.Draft("draft: Reply drafted / Send"))
        return act(action, on: tab)
    }
}

extension Agents {
    /// How a task that leaves a draft ends: the draft in the page, and to
    /// the user only what they should know beside it.
    static let draftEnding = """
    and write the draft into the page's own field, where the user will read and send it; never send, post \
    or submit it yourself. Then finish with a few short notes for the user, a dash each: what you noticed and \
    left out of the draft, anything they should check before sending. Start with the first note, and don't \
    repeat the draft. If you couldn't put it in the page (no field, no permission), finish with the whole \
    draft between <draft> and </draft> instead, and a line on why.
    """
}

extension Hints {
    /// The actions for the tab in front, if any.
    /// None on a private tab: an agent can't read or act in one, so none
    /// is offered there.
    func actions(on tab: Tab?) -> [Skills.Action] {
        guard let tab, !tab.isBlank, !tab.shy, tab.worker == nil else { return [] }
        return (extra[tab.id].map { [$0] } ?? []) + Skills.actions(for: tab.address)
    }
}

/// ⌘J, in the Agent menu beside Take Over.
struct PageActionCommand: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var peek: PeekFront
    /// A plan connected or gone: the item comes and goes with it (AIUse.offers).
    @ObservedObject private var setup = AgentSetupModel.shared

    init(browser: Browser) {
        self.browser = browser
        self.peek = browser.peekFront
    }

    var body: some View {
        let tab = peek.page ?? browser.active
        // AI off, or nothing to ask: no item, and ⌘J is the page's.
        if browser.prefs.aiUse != .off, AIUse.offers {
            Button("Ask Agent…", action: ask)
            .shortcut(.agentAsk)
            .disabled(tab == nil || tab?.isBlank == true)
        }
    }

    func ask() {
        guard let tab = browser.chatPage, !tab.isBlank else { return }
        if peek.page != nil {
            // Native Peek has no inline task field. Keep the page visible
            // and ask about it in the existing chat column instead.
            TaskLine.shared.close()
            browser.askInChat(about: tab)
        } else {
            TaskLine.shared.open(on: tab)
        }
    }
}

/// A page action offered at the foot, with a real Skip beside the action.
/// Dismissing this offer leaves the new-tab row and ⌘J available.
struct PagePill: View {
    @ObservedObject var tab: Tab
    var embedded = false
    var sharedActions = false
    @ObservedObject private var hints = Hints.shared
    @Environment(\.accessibilityReduceMotion) private var still

    private var action: Skills.Action? {
        guard hints.offered[tab.id] != nil else { return nil }
        return hints.actions(on: tab).first
    }

    var body: some View {
        ZStack {
            if let action {
                pill(action)
                    .noticeFling(.bottom, token: tab.id.uuidString + action.title) {
                        if hints.offered[tab.id] != nil { hints.unoffer(tab.id) }
                    }
                    .onAppear { NoticeFeedback.offer.play() }
                    .transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.arrive, value: action?.title)
        .padding(.bottom, embedded ? 0 : 14)
    }

    private func pill(_ action: Skills.Action) -> some View {
        HStack(spacing: 6) {
            Face(pose: .watch, size: 15, tint: Palette.ink)
                .padding(.trailing, 2)
            Text("Suggested")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            if sharedActions {
                actions(action).hidden().allowsHitTesting(false)
            } else {
                actions(action)
            }
        }
        .padding(.leading, 12) // design: the face needs more room than the trailing action button inside this 36 pt offer
        .padding(.trailing, sharedActions ? 8 : 4)
        .frame(height: 36)
        .background { if !embedded { HUD.plate(Radius.control + 4, surface: .page) } }
        .opacity(sharedActions ? 0 : 1) // the persistent dock row draws the offer and buttons together
        .allowsHitTesting(!sharedActions)
        .fixedSize()
    }

    private func actions(_ action: Skills.Action) -> some View {
        // Offered by a thing addressed to you (SiteItems): Skip asks in
        // the corner whether to stop suggesting there.
        let site = action.pattern.hasPrefix("@") ? action.skill : nil
        return HStack(spacing: 6) {
            Button {
                hints.unoffer(tab.id)
                if let site { SiteItems.shared.skip(site, from: BrowserWindows.shared.owner(of: tab.id)?.browser) }
            } label: {
                HStack(spacing: 6) {
                    Text("Skip")
                    KeyGlyphs(keys: "esc", size: 12.5, tint: nil, rest: 0.6)
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
            Button { Agents.shared.act(action, on: tab, item: SiteItems.shared.item(offeredOn: tab, for: action)) } label: {
                HStack(spacing: 6) {
                    Text(action.title).lineLimit(1)
                    ShortcutGlyphs(.agentAsk, size: 12.5, tint: nil)
                        .opacity(0.6)
                }
            }
            .buttonStyle(.yab(.primary, .regular, glass: true))
        }
    }

    /// The page moved on, or you touched it: the pill goes. And the corner
    /// tells the key the first time a site with actions comes up.
    static func noticed(_ tab: Tab, _ hints: Hints) async {
        if let offered = hints.offered[tab.id], let here = tab.address?.absoluteString, !here.hasPrefix(offered), !offered.hasPrefix(here) {
            hints.unoffer(tab.id)
        }
        // Not while the foot offers one: it says the key itself, and the
        // corner saying it too put the same words on screen twice.
        if hints.offered[tab.id] == nil, let first = hints.actions(on: tab).first, !first.skill.isEmpty {
            let key = "actions.told." + first.skill
            if !Store.settings.bool(forKey: key) {
                Store.settings.set(true, forKey: key)
                let name = Agents.preferredName
                Agents.shared.browser?.toaster.pop("\(first.title) with \(name)", mark: "agent.face", keys: Keymap.shared.keys(.agentAsk)?.caps ?? [], feedback: .offer)
            }
        }
        // Until a click or a key of yours on the page.
        while hints.offered[tab.id] != nil, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.5))
            if AgentFeed.shared.touchedLately(tab) { hints.unoffer(tab.id) }
        }
    }
}

/// The page's one floating foot hosts work, handoff, results and suggestions.
/// Watching the tab itself brings the plate in when an agent arrives here.
/// Measure's dock (MeasureDock.swift) stands on the same foot, above the
/// agent's when both are out: the agent speaks first.
struct PageFoot: View {
    let availableWidth: CGFloat
    @ObservedObject var tab: Tab
    @ObservedObject var selection: SelectionCommands
    @ObservedObject private var line = TaskLine.shared
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var debugger = ExtensionDebugger.shared
    @Environment(\.accessibilityReduceMotion) private var still
    /// How tall the agent's side of the foot stands, its 14 off the foot
    /// with it: anything more is a plate Measure's dock stands on.
    @State private var agentHeight: CGFloat = 0

    var body: some View {
        // Not while the chat's column asks it instead.
        let asking = tab.handoff != nil && (tab.worker != nil || tab.permit != nil) && !AgentDock.askedInColumn(tab) && !Agents.inCorner(tab)
            && !Agents.choosingInCorner(tab)
        let stacked = agentHeight > 20
        let debugged = debugger.holders[tab.id] != nil
        ZStack(alignment: .bottom) {
            Group {
                if line.tab == tab.id {
                    TaskLineView(tab: tab)
                } else {
                    AgentDock(tab: tab, selection: selection, availableWidth: availableWidth)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { agentHeight = $0 }
            if tab.measuring {
                MeasureDock(tab: tab, model: tab.measureModel)
                    .padding(.bottom, stacked ? agentHeight + 8 : 14)
                    .transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else if debugged {
                // An extension driving the tab with chrome.debugger.
                ExtensionDebuggerDock(tab: tab)
                    .padding(.bottom, stacked ? agentHeight + 8 : 14)
                    .transition(still ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.arrive, value: debugged)
        .animation(still ? nil : Motion.reshape, value: stacked)
        .animation(Motion.arrive, value: tab.measuring)
        // Only a question makes room. A draft's line and an answer float
        // over the page as the dock does: a page given room has the window
        // wait on its process laying it out again, a fence Core Animation
        // holds every commit behind, up to seconds on a busy page.
        .onChange(of: asking, initial: true) { _, now in Agents.makeRoom(tab, now) }
    }
}

/// The agent's pointer over a page, for the same reason.
struct PagePointer: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.worker != nil { AgentPointer(tab: tab) }
    }
}

/// A row the first time it is shown: out of a blur, a few points low, one
/// after another. Standing already, when it has been seen before.
private struct ComingIn: ViewModifier {
    let index: Int
    let fresh: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        let here = shown || !fresh
        return content
            .blur(radius: here || still ? 0 : 6)
            .opacity(here ? 1 : 0)
            .offset(y: here || still ? 0 : 4)
            .onAppear {
                guard fresh, !shown else { return }
                withAnimation(.easeOut(duration: still ? 0.2 : 0.28).delay(Double(index) * 0.03)) { shown = true }
            }
    }
}

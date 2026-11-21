import AppKit

// What yab notices itself, for the rows under the empty field
// (PLAN-hints.md §4, §5): no agent, no network, no model, only rules and
// arithmetic on this Mac. Each source is a small function of what is
// already in memory, so the field reads a finished list as it opens and
// never waits a frame for it. Hints.compose lays these in with what an
// agent found, in one queue.
//
// Each row says in its gray detail why it is here, in words: "Copied 12s
// ago · Slack", "in 8m · On your calendar", "You open it most Mondays
// around 10 AM". Who noticed it doesn't matter to the person; why it is here
// now does.

/// A link just copied, in any app: where to, when, and in what app (nil
/// in yab itself). Only in memory.
struct CopiedLink: Equatable {
    let url: URL
    let at: Date
    let app: String?
}

@MainActor
final class Noticing {
    static let shared = Noticing()

    private init() {}

    private var browser: Browser? { Agents.shared.browser ?? Clips.shared.browser }

    /// Everything noticed that holds now, in no order: Hints.order sorts.
    func rows(now: Date) -> [Hint] {
        var out: [Hint] = []
        let front = browser?.active.flatMap { $0.isBlank ? nil : $0.address }
        if let copy = Clips.shared.copied,
           let row = Noticing.copied(copy, now: now, front: front, title: browser?.history.title(of: copy.url)) {
            out.append(row)
        }
        // The page just in front on an iPhone of the account (SyncPhone).
        if let page = SyncCenter.shared.phoneOffer(now: now, in: browser) { out.append(SyncPhones.hint(page)) }
        // Only when the Mac already lets yab read the calendars: never asked from here.
        let meetings = Meetings.shared
        if meetings.allowed { out += Noticing.meetings(meetings.list, now: now) }
        out += habitRows(now: now)
        out += taskRows(now: now)
        out += wakeRows(now: now)
        let off = self.off
        let aside = self.aside
        if !off.kinds.contains(Kind.mail) {
            let notices = MailCenter.shared.noticed(now: now).filter { notice in
                aside["mail." + notice.thread].map { notice.last.timeIntervalSince1970 > $0 + 1 } ?? true
            }
            out += Noticing.mail(notices, now: now)
            let archived = MailCenter.shared.archivedToday(now: now)
            if archived.count > 0 { out.append(Noticing.archived(archived.count, names: archived.splits.map { MailList.name($0) })) }
            for notice in notices { mailLast["mail." + notice.thread] = notice.last }
        }
        // What you promised and what you were promised, each on its day (Promises).
        if !off.kinds.contains(Kind.promises) { out = Noticing.oneRowAThread(out, promises: Promises.shared.rows(now: now)) }
        // A subscription you don't use, the day before it renews (Purchases).
        if !off.kinds.contains(Kind.renewal.rawValue) { out += Purchases.shared.rows(now: now) }
        return out.filter { !hiddenToday($0.id, now: now) && !off.hides($0) }
    }

    /// One row a thread: a promise's over the mail row of its thread (the
    /// promise is the sharper ask), but a bill or a deadline the mail
    /// names keeps its row; yours over theirs in one thread.
    nonisolated static func oneRowAThread(_ rows: [Hint], promises: [Hint]) -> [Hint] {
        func thread(_ hint: Hint) -> String? { Hints.mailThread(hint.url)?.thread }
        let money = Set(rows.filter { [Kind.mailDue.rawValue, Kind.mailPastDue.rawValue].contains($0.kind ?? "") }.compactMap(thread))
        var taken = Set<String>()
        var kept: [Hint] = []
        for promise in promises.sorted(by: { ($0.kind == Kind.promiseMine.rawValue ? 0 : 1) < ($1.kind == Kind.promiseMine.rawValue ? 0 : 1) }) {
            // Said on a site: no mail thread to share.
            guard let key = thread(promise) else { kept.append(promise); continue }
            guard !money.contains(key), taken.insert(key).inserted else { continue }
            kept.append(promise)
        }
        let rest = rows.filter { row in
            guard row.id.hasPrefix("mail."), let key = thread(row) else { return true }
            return !taken.contains(key)
        }
        return rest + kept
    }

    // MARK: - mail (docs/mail.md, Daily)

    /// A thread worth a row: who, what it wants, how long it has waited.
    struct MailNotice: Equatable {
        /// `promised`: what you promised them, its day near or gone (MailPromise).
        enum Why: Equatable { case due, waitingOnYou, noAnswer, pastDue, promised }
        var account: String
        var thread: String
        var who: String
        var host: String
        var subject: String
        var gist: String
        var last: Date
        var due: Date?
        var why: Why
        /// The sender's address, lowercased, for Don't Show Things Like This.
        var address: String = ""
        /// An answer in a thread you wrote in: said at once, before
        /// someone new.
        var conversation = false
    }

    /// At most three, most pressing first: something due, a bill past due,
    /// someone answering you, someone new asking, what you promised,
    /// someone not answering you. Each goes by itself, without a word, once
    /// you reply, read, archive or snooze it.
    nonisolated static func mail(_ notices: [MailNotice], now: Date) -> [Hint] {
        func rank(_ notice: MailNotice) -> Int {
            switch notice.why {
            case .due: 0
            case .pastDue: 1
            case .waitingOnYou: notice.conversation ? 2 : 3
            case .promised: 4
            case .noAnswer: 5
            }
        }
        // One ask sent to several (three clinics quoting one retainer) is
        // one row, its newest answer's, saying how many answered.
        var answers: [String: Int] = [:]
        var notices = notices
        for notice in notices where notice.why == .waitingOnYou { answers[Noticing.topic(notice), default: 0] += 1 }
        notices = notices.sorted { $0.last > $1.last }
        var said = Set<String>()
        notices.removeAll { $0.why == .waitingOnYou && !said.insert(Noticing.topic($0)).inserted }
        // People who wait on you, the newest first: an answer from tonight
        // before one the day before yesterday. The rest, the oldest first.
        let ordered = notices.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.why == .waitingOnYou ? a.last > b.last : a.last < b.last
        }
        return ordered.prefix(3).map { notice in
            let days = max(1, Int(now.timeIntervalSince(notice.last) / 86_400))
            let many = notice.why == .waitingOnYou ? answers[Noticing.topic(notice)] ?? 1 : 1
            let title: String, detail: String
            switch notice.why {
            case .due:
                title = notice.gist.isEmpty ? notice.subject : notice.gist
                detail = notice.who + " · " + (notice.due.map { Noticing.when($0, now: now) } ?? "soon")
            case .pastDue:
                title = notice.gist.isEmpty ? notice.subject : notice.gist
                detail = notice.who + " · past due"
            case .waitingOnYou:
                // What they said, as the Mac's model read it: "Danny says
                // autofill still shows NordPass locked".
                let gist = notice.gist.trimmingCharacters(in: .whitespaces)
                title = gist.isEmpty ? "\(notice.who) is waiting on your reply" : notice.who + " " + gist.prefix(1).lowercased() + gist.dropFirst()
                detail = Noticing.age(notice.last, now: now) + " · " + (many > 1 ? "\(many) replies · " : "") + notice.subject
            case .noAnswer:
                title = "\(notice.who) hasn’t answered"
                detail = "\(days)d · " + notice.subject
            case .promised:
                // The words are what you owe: "Mark is waiting on what you promised".
                title = "\(notice.who) is waiting on what you promised"
                detail = (notice.due.map { $0 < now ? MailPromise.when(MailPromised(message: "", thread: "", quote: "", person: "",
                                                                                 address: "", kind: .word, due: $0, at: notice.last), now: now)
                                               : Noticing.when($0, now: now) } ?? "soon") + " · " + notice.subject
            }
            var parts = URLComponents(string: "yab://mail")!
            parts.fragment = "thread=" + notice.account + "|" + notice.thread
            let kind: Kind = switch notice.why {
            case .due: .mailDue
            case .pastDue: .mailPastDue
            case .waitingOnYou: .mailWaiting
            case .noAnswer: .mailNoAnswer
            case .promised: .mailPromised
            }
            // Mail's pen picture, a reply's where someone waits on you,
            // with the account's site on its corner.
            let picture = notice.why == .waitingOnYou || notice.why == .promised ? "reply" : "mail"
            return Hint(id: "mail." + notice.thread, icon: .picture(picture, site: notice.host), title: title, detail: detail,
                        url: parts.url, due: notice.why == .due ? notice.due : nil, source: .noticed, kind: kind.rawValue,
                        sender: notice.address.isEmpty ? nil : Hint.Sender(address: notice.address, name: notice.who))
        }
    }

    /// What Skip the inbox archived today, in one row that opens all of it
    /// (Archived Today): "12 newsletters archived today".
    nonisolated static func archived(_ count: Int, names: [String]) -> Hint {
        var parts = URLComponents(string: "yab://mail")!
        parts.fragment = "list=" + MailSplits.skipped
        let detail = names.count == 1 ? names[0] + " skips the inbox" : names.joined(separator: ", ") + " skip the inbox"
        return Hint(id: "mail.skipped", icon: .symbol("archivebox"), title: MailSplits.archivedLine(count, names: names), detail: detail,
                    url: parts.url, source: .noticed)
    }

    /// What a thread is about, for telling one ask's answers apart from
    /// another's: its subject without Re: and Fwd:, in lower case.
    nonisolated static func topic(_ notice: MailNotice) -> String {
        MailCenter.bare(notice.subject).lowercased()
    }

    /// How long ago a mail came, in words: "3:43 AM" today, "yesterday",
    /// "4d".
    nonisolated static func age(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.englishFormatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) { return "yesterday" }
        return "\(max(1, Int(now.timeIntervalSince(date) / 86_400)))d"
    }

    /// "in 3h", "tomorrow", "Fri": when something is due, in words.
    nonisolated static func when(_ date: Date, now: Date) -> String {
        let hours = date.timeIntervalSince(now) / 3600
        if hours < 0 { return "was due \(Calendar.current.isDate(date, inSameDayAs: now) ? "today" : "earlier")" }
        if hours < 12 { return "in \(max(1, Int(hours)))h" }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow" }
        let format = AppDates.formatter()
        format.dateFormat = "EEE"
        return format.string(from: date)
    }

    // MARK: - tasks done

    /// A task asked for in words, done and its answer not opened yet: the
    /// pick itself, not only that it is done, for half a day.
    private func taskRows(now: Date) -> [Hint] {
        let handed = Set(Hints.shared.handed.values)
        return Agents.shared.sessions.filter { session in
            // A row handed over (Do It) says its own task's end itself.
            session.task && session.state == .done && !session.read && !handed.contains(session.id)
                && now.timeIntervalSince(session.ended ?? now) < 12 * 3600
                // A routine's findings are rows of their own: its answer adds one only without them.
                && (Routines.shared.finder(of: session.id)?.found ?? 0) == 0
        }.map { session in
            if let routine = Routines.shared.finder(of: session.id) {
                let pick = TaskAnswer.pick(session.result) ?? routine.name
                return Hint(id: "task." + session.id, icon: .face, title: pick,
                            detail: routine.name + " · " + Routines.stamp(session.ended ?? now, now: now), source: .noticed)
            }
            let title = Folders.title(session.id)
            // The pick, with the task's name before it unless it says it already.
            let first = title.split(separator: " ").first.map { String($0).lowercased() } ?? ""
            let pick = TaskAnswer.pick(session.result).map { $0.lowercased().hasPrefix(first) ? $0 : "\(title): \($0)" } ?? title
            return Hint(id: "task." + session.id, icon: .face, title: pick,
                        detail: "Done " + Hints.ago(session.ended ?? now, now: now), source: .noticed)
        }
    }

    /// A kept plugin's wake, answered and not opened yet: the plugin's name
    /// and the answer's first line, for half a day. Its task kept out of
    /// the tab row; the row opens its chat.
    private func wakeRows(now: Date) -> [Hint] {
        Agents.shared.sessions.filter { session in
            session.boostOrigin != nil && session.quiet && session.parent == nil && session.state == .done && !session.read
                && now.timeIntervalSince(session.ended ?? now) < 12 * 3600
        }.compactMap { session in
            Boosts.headline(session.result).map { line in
                Hint(id: "wake." + session.id, icon: .symbol("puzzlepiece.extension"), title: session.name + ": " + line,
                     detail: "Done " + Hints.ago(session.ended ?? now, now: now), source: .noticed)
            }
        }
    }

    /// A wake's answer, opened: its chat in the column, read.
    func show(woken session: Agents.Session, in browser: Browser) {
        session.read = true
        browser.keepChat(session.id)
        browser.showChat(session.id)
        Hints.shared.compose()
    }

    // MARK: - habits (§5)

    /// Today's habits as last counted, whatever the time; each shows only
    /// in its own window.
    private(set) var habits: [Habit] = []
    private var habitsAt = Date.distantPast
    private var counting = false
    /// Whose history is read changed (OtherHistory): today's habits go, and
    /// are counted again from what may be read now.
    func recountHabits() {
        habits = []
        habitsAt = .distantPast
        Hints.shared.compose()
    }

    /// Visits a test run handed over (hints-visits), in place of the history.
    var visits: [Habits.Visit]? {
        didSet { habitsAt = .distantPast }
    }

    /// A habit whose time it is, unless the place is open in a tab of
    /// yours already (pinned ones among them), you said not to suggest it,
    /// or it was taken or put away today.
    private func habitRows(now: Date) -> [Hint] {
        if now < habitsAt || !Calendar.current.isDate(habitsAt, inSameDayAs: now) {
            countHabits(now: now)
        }
        guard !habits.isEmpty, let browser else { return [] }
        let open = Set(browser.everyTab.compactMap { $0.address?.host().map(Hints.host) })
        let off = offList
        let calendar = Calendar.current
        return habits.filter { habit in
            !open.contains(habit.host) && !off.contains(habit.place) && !openedToday(habit.place, now: now)
                && habit.current(at: now, calendar: calendar)
        }.map { habit in
            Hint(id: "habit." + habit.place, icon: .site(habit.host), title: habit.title ?? habit.place, detail: habit.detail,
                 url: habit.url, source: .habit)
        }
    }

    /// Places opened in yab today, as they are opened: a habit kept stays
    /// kept for the day, even with its tab closed again, without reading
    /// the history for it.
    private var openedToday: (day: Date, places: Set<String>) = (.distantPast, [])

    func opened(_ url: URL) {
        guard let place = Habits.place(url) else { return }
        let day = Calendar.current.startOfDay(for: Hints.now)
        if openedToday.day != day { openedToday = (day, []) }
        guard openedToday.places.insert(place).inserted else { return }
        // A row standing for it goes the next time the field is composed.
        if habits.contains(where: { $0.place == place }) { Hints.shared.compose() }
    }

    private func openedToday(_ place: String, now: Date) -> Bool {
        openedToday.day == Calendar.current.startOfDay(for: now) && openedToday.places.contains(place)
    }

    /// Counted again off the main thread, once a day: habits are made of
    /// the days before today, which don't change, and what is opened today
    /// is followed as it happens (`opened`). Read Yab's diary only;
    /// startup must not open another browser's History.
    func countHabits(now: Date) {
        guard !counting else { return }
        counting = true
        habitsAt = now
        let given = visits
        Task.detached(priority: .utility) {
            let visits = given ?? AgentHistory.visits(days: Habits.history, includingOtherBrowsers: false)
            let found = Habits.find(visits: visits, now: now, calendar: .current)
            await MainActor.run {
                self.counting = false
                guard found != self.habits else { return }
                self.habits = found
                Hints.shared.compose()
            }
        }
    }

    /// Today's habits and why, for the bench.
    func state() -> [String: Any] {
        let now = Hints.now
        let calendar = Calendar.current
        func clock(_ minutes: Int) -> String {
            let value = ((minutes % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", value / 60, value % 60)
        }
        let list: [[String: Any]] = habits.map { habit in
            var out: [String: Any] = ["place": habit.place, "url": habit.url.absoluteString, "detail": habit.detail, "days": habit.days,
                                      "window": clock(habit.center - Habits.half) + "-" + clock(habit.center + Habits.half),
                                      "now": habit.current(at: now, calendar: calendar), "off": offList.contains(habit.place)]
            if let title = habit.title { out["title"] = title }
            if let weekday = habit.weekday { out["weekday"] = weekday }
            return out
        }
        return ["habits": list, "counted": ISO8601DateFormatter().string(from: habitsAt), "given": visits?.count ?? -1,
                "rows": rows(now: now).map(\.id)]
    }

    // MARK: - put away

    /// Rows taken, or put away for the day, and when.
    private var putAway: [String: Date] {
        get {
            (Store.settings.dictionary(forKey: "hints.today") as? [String: Double] ?? [:])
                .mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            let now = Hints.now
            // Only today's are worth keeping.
            let kept = newValue.filter { now.timeIntervalSince($0.value) < 86_400 }
            Store.settings.set(kept.mapValues(\.timeIntervalSince1970), forKey: "hints.today")
        }
    }

    private func hiddenToday(_ id: String, now: Date) -> Bool {
        guard let when = putAway[id] else { return false }
        return Calendar.current.isDate(when, inSameDayAs: now)
    }

    /// Not today, or done: back tomorrow, if it still holds. A copied link
    /// put away is gone with it.
    func hideToday(_ hint: Hint) {
        putAway[hint.id] = Hints.now
        if hint.copied != nil { Clips.shared.copied = nil }
        Hints.shared.compose()
    }

    // MARK: - Don't Show Things Like This

    /// What a row of yab's own is a kind of: what Don't Show Things Like
    /// This turns off, said in its menu, in Settings and to the look.
    enum Kind: String, CaseIterable {
        case mailDue = "mail.due", mailPastDue = "mail.pastDue", mailWaiting = "mail.waiting", mailNoAnswer = "mail.noAnswer"
        case mailPromised = "mail.promised"
        case mailSkipped = "mail.skipped", meeting, copied, task, wake, phone
        case promiseMine = "promise.mine", promiseTheirs = "promise.theirs"
        case renewal

        /// All of mail at once: Settings' switch, not a row's menu.
        static let mail = "mail"
        /// All of promises at once: Settings' switch.
        static let promises = "promise"

        nonisolated static func of(_ hint: Hint) -> Kind? {
            if let kind = hint.kind { return Kind(rawValue: kind) }
            let id = hint.id
            if id == "mail.skipped" { return .mailSkipped }
            if id.hasPrefix("noticed.meeting.") { return .meeting }
            if id.hasPrefix("noticed.copy.") { return .copied }
            if id.hasPrefix("task.") { return .task }
            if id.hasPrefix("wake.") { return .wake }
            if id.hasPrefix("noticed.phone.") { return .phone }
            return nil
        }

        var isMail: Bool { rawValue.hasPrefix("mail.") }
        var isPromise: Bool { rawValue.hasPrefix("promise.") }

        /// In a menu and in Settings.
        var title: String {
            switch self {
            case .mailDue: "Mail Due Soon"
            case .mailPastDue: "Bills Past Due"
            case .mailWaiting: "Anyone Waiting on Your Reply"
            case .mailNoAnswer: "Anyone Who Hasn’t Answered"
            case .mailPromised: "What You Promised"
            case .mailSkipped: "Mail Archived Today"
            case .meeting: "Meetings About to Start"
            case .copied: "Links You Copied"
            case .task: "Finished Tasks"
            case .wake: "Plugin Answers"
            case .phone: "Pages from Your iPhone"
            case .promiseMine: "What You Promised"
            case .promiseTheirs: "Promised to You"
            case .renewal: "Renewals You Don’t Use"
            }
        }

        /// To the look, so it doesn't bring the same in its own words; nil
        /// for what a look never brings.
        var said: String? {
            switch self {
            case .mailDue: "mail asking for something by a date soon"
            case .mailPastDue: "bills past due"
            case .mailWaiting: "mail where someone is waiting on the user's reply"
            case .mailNoAnswer: "mail the user sent that nobody has answered yet"
            case .mailPromised: "what the user promised in their own mail, its day near"
            case .meeting: "meetings about to start"
            case .promiseMine: "what the user promised others; yab keeps those itself"
            case .promiseTheirs: "what others promised the user; yab keeps those itself"
            case .renewal: "subscriptions about to renew that the user hasn't opened lately; yab keeps those itself"
            case .mailSkipped, .copied, .task, .wake, .phone: nil
            }
        }
    }

    /// Kinds and people turned off, for good, until Settings shows them again.
    struct Off: Codable, Equatable {
        var kinds: [String] = []
        var people: [Hint.Sender] = []

        func hides(_ hint: Hint) -> Bool {
            if let sender = hint.sender, people.contains(where: { $0.address == sender.address }) { return true }
            guard let kind = Kind.of(hint) else { return false }
            // What You Promised turned off before it was a promise's own kind.
            if kind == .promiseMine, kinds.contains(Kind.mailPromised.rawValue) { return true }
            return kinds.contains(kind.rawValue) || (kind.isMail && kinds.contains(Kind.mail))
                || (kind.isPromise && kinds.contains(Kind.promises))
        }

        /// For the look's prompt, a line each.
        var said: [String] {
            var out: [String] = kinds.contains(Kind.mail) ? ["mail of any kind: the user wants no mail suggested"] : []
            out += kinds.compactMap { Kind(rawValue: $0)?.said }
            out += people.map { "mail from \($0.address)" }
            return out
        }
    }

    var off: Off {
        get { Store.settings.data(forKey: "hints.off").flatMap { try? JSONDecoder().decode(Off.self, from: $0) } ?? Off() }
        set { Store.settings.set(try? JSONEncoder().encode(newValue), forKey: "hints.off") }
    }

    /// Mail by itself, Settings' switch: every kind of mail row at once.
    var mailOn: Bool {
        get { !off.kinds.contains(Kind.mail) }
        set {
            var off = self.off
            off.kinds.removeAll { $0 == Kind.mail }
            if !newValue { off.kinds.append(Kind.mail) }
            self.off = off
            Hints.shared.compose()
        }
    }

    /// Promises by themselves, Settings' switch: both ways at once.
    var promisesOn: Bool {
        get { !off.kinds.contains(Kind.promises) }
        set {
            var off = self.off
            off.kinds.removeAll { $0 == Kind.promises }
            if !newValue { off.kinds.append(Kind.promises) }
            self.off = off
            Hints.shared.compose()
        }
    }

    /// What is turned off, one line each for Settings: a kind, a person, a
    /// habit's place. Mail as a whole is the switch's.
    struct Hidden: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
    }

    var hidden: [Hidden] {
        let off = self.off
        return off.people.map { Hidden(id: "person:" + $0.address, title: "Mail from \($0.name)", detail: $0.address) }
            + off.kinds.compactMap { Kind(rawValue: $0) }.map { Hidden(id: "kind:" + $0.rawValue, title: $0.title, detail: "") }
            + offList.sorted().map { Hidden(id: "habit:" + $0, title: $0, detail: "A habit") }
    }

    /// Shown again, from Settings.
    func showAgain(_ id: String) {
        var off = self.off
        if id.hasPrefix("person:") { off.people.removeAll { "person:" + $0.address == id } }
        if id.hasPrefix("kind:") { off.kinds.removeAll { "kind:" + $0 == id } }
        self.off = off
        if id.hasPrefix("habit:") {
            offList.remove(String(id.dropFirst("habit:".count)))
            writeOffList()
        }
        Hints.shared.compose()
    }

    /// Not this, nor anything like it: the person's mail when `person`,
    /// otherwise the row's kind; a habit's place, by itself.
    func never(_ hint: Hint, person: Bool = false) {
        defer {
            if hint.copied != nil { Clips.shared.copied = nil }
            Hints.shared.compose()
        }
        if hint.source == .habit {
            offList.insert(String(hint.id.dropFirst("habit.".count)))
            writeOffList()
            return
        }
        var off = self.off
        if person, let sender = hint.sender {
            if !off.people.contains(where: { $0.address == sender.address }) { off.people.append(sender) }
        } else if let kind = Kind.of(hint) {
            if !off.kinds.contains(kind.rawValue) { off.kinds.append(kind.rawValue) }
        } else {
            return Hints.shared.dismiss(hint)
        }
        self.off = off
    }

    // MARK: - a mail row's ×

    /// The last mail of each thread a row was made of, as last worked out.
    private var mailLast: [String: Date] = [:]

    /// Threads whose row was put away with ×, and the time of their last
    /// mail then: the row comes back with the next mail in the thread.
    private var aside: [String: Double] {
        Store.settings.dictionary(forKey: "hints.mail-aside") as? [String: Double] ?? [:]
    }

    /// This thread, until it has new mail.
    func setAside(_ hint: Hint) {
        setAside(hint.id, last: mailLast[hint.id] ?? Hints.now)
    }

    /// A thread's row by its id, until mail newer than `last` comes in it.
    func setAside(_ id: String, last: Date) {
        var aside = self.aside
        aside[id] = last.timeIntervalSince1970
        // The oldest let go past three hundred.
        if aside.count > 300 {
            for (id, _) in aside.sorted(by: { $0.value < $1.value }).prefix(aside.count - 300) { aside[id] = nil }
        }
        Store.settings.set(aside, forKey: "hints.mail-aside")
        Hints.shared.compose()
    }

    /// Everything said not to show, gone: a test world starting over.
    func forgetOff() {
        Store.settings.removeObject(forKey: "hints.off")
        Store.settings.removeObject(forKey: "hints.mail-aside")
        offList = []
        try? FileManager.default.removeItem(at: Noticing.offFile)
    }

    private func writeOffList() {
        try? FileManager.default.createDirectory(at: Noticing.offFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? offList.sorted().joined(separator: "\n").write(to: Noticing.offFile, atomically: true, encoding: .utf8)
    }

    /// Places you said never to suggest as a habit: kept on this Mac only,
    /// never in an agent's prompt.
    nonisolated private static var offFile: URL { Store.file("hints-habits-off.txt") }
    private lazy var offList: Set<String> = Set(((try? String(contentsOf: Noticing.offFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init))

    // MARK: - a meeting soon (§4.3)

    /// A meeting on any of the Mac's calendars starting within the hour, or
    /// begun up to ten minutes ago, one you haven't said no to (Meetings
    /// leaves those out, and all-day and cancelled ones). Its detail counts
    /// down by itself ("in 35m · On your calendar"), and in its last ten
    /// minutes a call's link is offered as Join (HintList.joining).
    nonisolated static func meetings(_ list: [Meeting], now: Date) -> [Hint] {
        list.filter { $0.end > now && $0.start <= now.addingTimeInterval(3600) && $0.start > now.addingTimeInterval(-10 * 60) }
            .map { meeting in
                let call = CallLink.key(meeting.link) == nil ? nil : meeting.link
                return Hint(id: "noticed.meeting." + meeting.id, icon: .picture("meeting", site: nil),
                            title: meeting.title.isEmpty ? "Meeting" : meeting.title, detail: "On your calendar",
                            url: meeting.link, due: meeting.start, join: call, source: .noticed)
            }
    }

    // MARK: - a link just copied (§4.1)

    /// How long a copied link is offered: it is now or never.
    nonisolated static let copiedFor: TimeInterval = 90

    /// The row for a link copied less than a minute and a half ago, unless
    /// it is the page already in front of you. Its title is the page's, if
    /// this Mac has been there, or else its host and path; its detail the
    /// app it came from, or for a copy made in yab, the site.
    nonisolated static func copied(_ copy: CopiedLink, now: Date, front: URL?, title: String?) -> Hint? {
        let age = now.timeIntervalSince(copy.at)
        guard age < copiedFor, age > -5 else { return nil }
        if let front, Hints.place(front.absoluteString) == Hints.place(copy.url.absoluteString) { return nil }
        let host = Hints.host(copy.url.host() ?? "")
        return Hint(id: "noticed.copy." + Hints.place(copy.url.absoluteString), icon: .site(host),
                    title: title ?? Address.pretty(copy.url), detail: copy.app ?? host, url: copy.url,
                    source: .noticed, copied: copy.at)
    }

    // MARK: - taking one

    /// A tab of yours already at a row's page, which the row switches to
    /// rather than opening it again.
    func openTab(for hint: Hint) -> Tab? {
        guard let url = hint.url, let browser else { return nil }
        let place = Hints.place(url.absoluteString)
        return browser.tabs.first { $0.id != browser.activeID && $0.address.map { Hints.place($0.absoluteString) } == place }
    }

    /// A row of yab's own, taken: its page, in the empty tab that asked,
    /// or over a page (⌘L), in a tab of its own; or the tab already there.
    func take(_ hint: Hint, in browser: Browser) {
        if hint.id.hasPrefix("wake."), let session = Agents.shared.session(String(hint.id.dropFirst(5))) {
            browser.close()
            return show(woken: session, in: browser)
        }
        // A task's answer: its chat, in the column.
        if hint.id.hasPrefix("task."), let session = Agents.shared.session(String(hint.id.dropFirst(5))) {
            browser.close()
            session.read = true
            browser.showChat(session.id)
            Hints.shared.compose()
            return
        }
        // A page from an iPhone: the tab that already shows it, in the space
        // it is in there when this Mac has that one, as Open on Mac does.
        if hint.phone != nil, let url = hint.url {
            browser.close()
            // Once in front here it is no longer offered (PhoneFront.offered).
            _ = SyncOpen.show(url, space: hint.space, in: browser)
            Hints.shared.compose()
            return
        }
        // A copied link, once opened, has done its work.
        if hint.copied != nil { Clips.shared.copied = nil }
        // A habit, once kept, is kept for today.
        if hint.source == .habit { putAway[hint.id] = Hints.now }
        defer { Hints.shared.compose() }
        guard let url = hint.url else {
            // A meeting with nowhere to go: the calendar it is on.
            if hint.due != nil {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: .init())
            }
            return
        }
        // Mail's thread: over the page, or on mail's page in mail's space,
        // never a tab of its own (MailThreadPeek).
        if MailPage.isMail(url), browser.prefs.usesMail {
            browser.close()
            browser.mailRow(url, hint: hint.id)
        } else if let tab = openTab(for: hint) {
            browser.take(Suggestion(key: tab.label, title: "", url: url, kind: .open, tab: tab.id))
        } else if browser.askingNew {
            browser.take(Suggestion(key: url.host() ?? "", title: hint.title, url: url, kind: .address))
        } else {
            browser.close()
            browser.open(url, foreground: true)
        }
    }
}

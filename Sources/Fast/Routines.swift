import AppKit
import SyncKit

// Tasks that come back on their own: `yab every "weekdays 9:00" "…"`.
//
// A routine is a task and when to run it. They run while yab is open, as
// the morning's look does, never on a timer of the Mac's: a Mac asleep or a
// yab closed at nine runs the nine o'clock one the first time it is back
// that day, once. What a run finds for you comes to the new tab's rows, the
// way the morning's findings do, beside them rather than in their place.
//
// When: `daily 9:00`, `weekdays 18:30`, `weekends 10:00`, days by name
// (`mon,thu 8:15`), a day of the month (`monthly 1 9:00`, `on the 15th
// 10:00`, `monthly last 18:00`; the 31st is a shorter month's last day), a
// weekday of the month (`first monday 9:00`, `last friday 17:00`), gaps of
// days or weeks counted from the last run (`every 3 days 9:00`, `every 2
// weeks mon 9:00`), a date (`yearly oct 6 9:00`, Feb 29 on the 28th in
// other years), several times a day (`daily 9:00,18:00`), all on this Mac's
// local time; `hourly`, or `every 2h` / `every 30m` (a quarter of an
// hour at least). Or `on mail <split>`: once for each mail that comes to
// that split of mail (docs/mail.md, Routines on a split's mail), one mail a run, after Sense
// has placed it; set from the split's head, When Mail Comes….

struct Routine: Codable, Identifiable, Equatable {
    let id: String
    var when: String
    var prompt: String
    var last: Date?
    var said: String?
    var session: String?
    /// Gone after this, on its own: a watch for a reply.
    var until: Date? = nil
    /// Runs as yab's own quiet work, no tabs to see, only what it suggests.
    var quiet: Bool? = nil
    /// What the list calls it: its name.
    var title: String? = nil
    /// The pages it works in, by address: a tab of yours when it was set,
    /// opened again in a tab of its own on each run.
    var tabs: [String]? = nil
    /// Its own model, as a command keeps one ("claude" or "codex", its
    /// model and effort); nil for the default.
    var cli: String? = nil
    var model: String? = nil
    var effort: String? = nil
    /// What it may do: only read ("read", the default), ask before acting
    /// ("ask"), or as Settings › AI › Agents says ("agents").
    var may: String? = nil
    /// How it says it found something: only in ⌘T and its chat ("quiet",
    /// the default), with a notice when it finds something ("found"), or
    /// with a notice every run ("always").
    var tell: String? = nil
    /// A command of Settings › AI › Commands it runs on its pages.
    var command: String? = nil
    /// Turned off: kept, not run.
    var off: Bool? = nil
    /// The one chat its runs go into, each after the last.
    var chat: String? = nil
    /// How many things its last run found.
    var found: Int? = nil
    /// When that run ended.
    var ended: Date? = nil
    /// Keeps what it finds in a folder (LiveFolders, its `routine` source):
    /// each run hands the folder what belongs, instead of an answer.
    var folder: Bool? = nil
    /// The space its folder was made in: the one folder it keeps is there.
    var space: UUID? = nil
    /// `on mail`: mail that came before this isn't its to do; the threads
    /// it did ("account|thread"), the last hundred; how many times in a
    /// row you said yes to what it asked, and whether it asked once to run
    /// on its own.
    var mailSince: Date? = nil
    var mailDone: [String]? = nil
    var streak: Int? = nil
    var trustAsked: Bool? = nil
    /// The device that runs it (SyncCenter.device): with sync, every Mac
    /// has the routine and only this one runs it. Nil: whichever has it.
    var runsOn: String? = nil
    /// The chat project it lives in (Projects): its runs' chat is in it,
    /// told the project's instructions and memory.
    var project: String? = nil

    /// Whether this Mac is the one to run it.
    var runsHere: Bool { runsOn == nil || runsOn == SyncCenter.deviceID }

    /// What the list and the chat call it.
    var name: String { title ?? Self.name(from: prompt) }

    /// A name from a task's first words, when none was given.
    static func name(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let words = line.split(separator: " ")
        let short = words.prefix(6).joined(separator: " ")
        let clean = short.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
        let named = clean.prefix(1).uppercased() + clean.dropFirst()
        return words.count > 6 ? named + "…" : named
    }
}

@MainActor
final class Routines: ObservableObject {
    static let shared = Routines()

    @Published private(set) var all: [Routine] = []
    private(set) var lastProblem: String?
    private var timer: Timer?
    private var file: URL { Store.file("routines.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([Routine].self, from: data) { all = read }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
        NotificationCenter.default.post(name: Routines.changed, object: nil)
    }

    static let changed = Notification.Name("yab.routines.changed")

    /// The routines as sync says they are now (SyncShapes.routines): what
    /// each is and which Mac runs it from there, how its runs went from
    /// here. One new here waits a full period before its first run, as one
    /// made here does.
    func adopt(_ list: [Routine]) {
        let mine = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A plugin's routines are this Mac's own (SyncShapes.routines).
        let plugins = all.filter { $0.id.hasPrefix(SyncShapes.pluginRoutines) }
        let fresh = list.filter { !$0.id.hasPrefix(SyncShapes.pluginRoutines) }.map { routine -> Routine in
            var routine = routine
            if let here = mine[routine.id] {
                routine.last = here.last
                routine.said = here.said
                routine.session = here.session
                routine.chat = here.chat
                routine.found = here.found
                routine.ended = here.ended
                routine.mailSince = here.mailSince
                routine.mailDone = here.mailDone
            } else {
                routine.last = Date()
            }
            return routine
        } + plugins
        guard fresh != all else { return }
        all = fresh
        save()
        start()
    }

    /// Its project is gone: the routine runs on, on its own.
    func leave(project id: String) {
        var touched = false
        for index in all.indices where all[index].project == id {
            all[index].project = nil
            touched = true
        }
        if touched { save() }
    }

    /// Into a project or out of one, its chat with it.
    func move(_ id: String, to project: String?) {
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].project != project else { return }
        all[index].project = project
        save()
        if let chat = all[index].chat { Chats.shared.move([chat], to: project) }
    }

    // MARK: - keeping them

    /// A new one, or why it can't be. A title when the list should call it
    /// something shorter than its task: one Settings suggested.
    func add(when: String, prompt: String, title: String? = nil) -> Result<Routine, Trouble> {
        put(Routine(id: Self.newID(when + prompt), when: when, prompt: prompt, last: nil, title: title))
    }

    /// A new one or a changed one, as the editor has it, or why it can't
    /// be. Not due the moment it is made, nor the moment its time changes:
    /// its first run is its next time.
    @discardableResult
    func put(_ routine: Routine) -> Result<Routine, Trouble> {
        Self.check(when: routine.when, prompt: routine.prompt, command: routine.command).map { clean in
            var made = routine
            made.when = clean.when
            made.prompt = clean.prompt
            if let index = all.firstIndex(where: { $0.id == routine.id }) {
                // How its runs went is the list's, not the copy's: an editor
                // opened before a run would otherwise put back the run
                // before it, due again at once, its chat and its words lost.
                let kept = all[index]
                made.last = kept.when != made.when ? Date() : kept.last
                made.said = kept.said
                made.session = kept.session
                made.chat = kept.chat
                made.found = kept.found
                made.ended = kept.ended
                made.mailSince = made.mailSince ?? kept.mailSince
                made.mailDone = kept.mailDone
                made.streak = kept.streak
                made.trustAsked = kept.trustAsked
                all[index] = made
            } else {
                made.last = Date()
                if made.runsOn == nil { made.runsOn = SyncCenter.deviceID }
                all.append(made)
            }
            save()
            start()
            // A folder of yours given to it from the folder's menu: its now.
            let keptFolder = keeping.removeValue(forKey: made.id)
            if made.folder == true, let nest = keptFolder, nest.live == nil {
                nest.live = Live(source: "routine", host: made.id, show: [])
                Folders.shared.emptyChanged(nest)
                Folders.shared.refresh()
                Agents.shared.browser?.writeSession(now: true)
            }
            if let seed = repeating.removeValue(forKey: made.id), made.folder == true, let browser = seed.browser {
                keepChatTabs(seed.chat, in: made, browser: browser)
            }
            return made
        }
    }

    /// Turned off or on again; on again, its next time is its first.
    func turn(_ id: String, on: Bool) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].off = on ? nil : true
        if on { all[index].last = Date() }
        save()
        start()
    }

    /// Folders of yours waiting on the editor to keep them, by the routine
    /// being made for each (Keep Up to Date… in a folder's menu).
    private var keeping: [String: Nest] = [:]
    private final class RepeatSeed {
        let chat: Chat
        weak var browser: Browser?
        init(_ chat: Chat, browser: Browser) { self.chat = chat; self.browser = browser }
    }
    private var repeating: [String: RepeatSeed] = [:]

    /// Closing an unsaved editor leaves every source tab as it was.
    func cancelDraft(_ id: String) {
        keeping.removeValue(forKey: id)
        repeating.removeValue(forKey: id)
    }

    /// Keep Up to Date… on a folder of yours: the editor, filled in with its
    /// pages and a task that keeps it, the tick on; saved, the folder is
    /// that routine's, your tabs in it left as they are.
    func keepFolder(_ nest: Nest, in browser: Browser) {
        let tabs = browser.tabs.filter { $0.nest === nest }
        let titles = tabs.prefix(8).map { "«\($0.label)»" }.joined(separator: ", ")
        let prompt = "Keep this folder, \(nest.name), up to date: pages like the ones in it (\(titles)), the best first, and drop any that no longer fit. At each row, what to see at a glance."
        var routine = Routine(id: Self.newID(nest.id.uuidString), when: "daily 9:00", prompt: prompt, last: nil, title: nest.name)
        routine.tabs = Array(tabs.compactMap { $0.address?.absoluteString }.filter { $0.hasPrefix("http") }.prefix(6))
        routine.folder = true
        keeping[routine.id] = nest
        SettingsWindow.shared.showRoutine(routine, for: browser, fresh: true)
    }

    /// Its folder was made in this space.
    func placed(_ id: String, in space: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].space != space else { return }
        all[index].space = space
        save()
    }

    /// Its folder's Stop Updating: the folder stays a plain one of yours,
    /// and the routine, which would otherwise answer each run in its chat
    /// instead, is turned off.
    func stopKeeping(_ id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].folder = nil
        all[index].off = true
        save()
    }

    /// A copy, beside it, with a chat of its own to come.
    func duplicate(_ id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var copy = all[index]
        copy = Routine(id: Self.newID(copy.when + copy.prompt), when: copy.when, prompt: copy.prompt, last: Date(),
                       title: copy.name + " copy", tabs: copy.tabs, cli: copy.cli, model: copy.model, effort: copy.effort,
                       may: copy.may, tell: copy.tell, command: copy.command, folder: copy.folder)
        // Run by this Mac alone, as a new one is: with sync, not by each.
        copy.runsOn = SyncCenter.deviceID
        all.insert(copy, at: index + 1)
        save()
    }

    /// Its last run and end moved back, as if that much time had gone by
    /// since: a Mac asleep through its time, for the evals.
    func age(_ id: String, by seconds: TimeInterval) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        all[index].last = (all[index].last ?? Date()).addingTimeInterval(-seconds)
        all[index].ended = all[index].ended?.addingTimeInterval(-seconds)
        save()
        return true
    }

    nonisolated static func newID(_ seed: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (seed + "\(Date().timeIntervalSince1970)\(UInt64.random(in: 0...UInt64.max))").utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(String(hash, radix: 36).prefix(5))
    }

    /// Its when and task, cleaned, or why they can't be a routine. One that
    /// runs a command may leave its own words empty: the command's are used.
    nonisolated private static func check(when: String, prompt: String, command: String? = nil) -> Result<(when: String, prompt: String), Trouble> {
        let when = when.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || command != nil else { return .failure(Trouble("a routine needs a task")) }
        guard schedule(when) != nil else {
            return .failure(Trouble("can't read “\(when)”: say " + phrases))
        }
        return .success((when, prompt))
    }

    /// A thread watched for a reply, every two hours for a few days: what
    /// arrives comes to the new tab, and the watch ends with it.
    func watch(url: String, who: String, days: Double) -> Result<Routine, Trouble> {
        guard let link = URL(string: url), link.scheme?.hasPrefix("http") == true else { return .failure(Trouble("watch needs the thread's own address")) }
        let who = who.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "them" : who.trimmingCharacters(in: .whitespacesAndNewlines)
        let since = ISO8601DateFormatter().string(from: Date())
        let until = Date().addingTimeInterval(min(max(days, 1), 14) * 86_400)
        let id = String(String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36).suffix(5))
        let prompt = """
        Check whether \(who) has replied in \(link.absoluteString) since \(since). Read only: use the site's skill \
        and `fetch` where it can (no tab), don't mark anything read, don't answer. If a reply came, call `suggest` \
        with one item: kind "reply", title "\(who) replied", detail the reply's first line, url the thread; then \
        call `watch` with stop "\(id)". If nothing came, finish with one word.
        """
        let day = AppDates.string(from: until, dateStyle: .medium, timeStyle: .none)
        let made = Routine(id: id, when: "every 2h", prompt: prompt, last: Date(), until: until, quiet: true,
                           title: "Reply from \(who), until \(day)")
        all.append(made)
        save()
        start()
        return .success(made)
    }

    func remove(_ id: String) -> Bool {
        let before = all.count
        all.removeAll { $0.id == id || $0.id.hasPrefix(id) && id.count >= 3 }
        save()
        // Its folder, if it kept one, a plain folder of yours again: now
        // where it is up, else when its space comes back (LiveFolders.tick).
        LiveFolders.shared.settle()
        return all.count < before
    }

    struct Trouble: Error { let said: String; init(_ said: String) { self.said = said } }

    // MARK: - when

    /// The days a routine at a time of day runs on.
    enum Days: Equatable, Sendable {
        /// These weekdays (1 Sunday … 7 Saturday).
        case week(Set<Int>)
        /// Every so many days, counted from the day of its last run.
        case cycle(Int)
        /// These weekdays of every so many weeks, counted from the week
        /// (from Monday) of its last run.
        case weeks(Int, Set<Int>)
        /// This day of each month, 1 to 31, 0 the last; a day a shorter
        /// month hasn't is its last.
        case month(Int)
        /// The first to fifth of a weekday in each month, or -1 the last;
        /// a month without a fifth has none.
        case nth(Int, weekday: Int)
        /// Each year on this date; Feb 29 on Feb 28 in other years.
        case year(month: Int, day: Int)
    }

    enum Schedule: Equatable, Sendable {
        /// These days at these minutes of the day, earliest first.
        case days(Days, at: [Int])
        /// Every so many seconds.
        case every(TimeInterval)
        /// Once each time Yab opens.
        case opens
        /// Each mail that comes to this split of mail.
        case mail(String)
    }

    /// The words of a routine on a split's mail.
    nonisolated static func mailWhen(_ split: String) -> String { "on mail " + split }

    /// When this Yab opened: a routine run "on open" runs once after it.
    nonisolated static let opened = Date()

    /// The words every routine can be given, for what says them to people
    /// and agents.
    nonisolated static let phrases = "daily 9:00, weekdays 18:30, weekends 10:00, mon,thu 8:15, daily 9:00,18:00, "
        + "monthly 1 9:00 (or on the 1st 9:00, 15th 10:00), monthly last 18:00, first monday 9:00, last friday 17:00, "
        + "every 3 days 9:00, every 2 weeks mon 9:00, yearly oct 6 9:00, hourly, every 2h, every 30m, on open"

    nonisolated static func schedule(_ words: String) -> Schedule? {
        let parts = words.lowercased().split(separator: " ").map(String.init)
        if parts.count == 3, parts[0] == "on", parts[1] == "mail" { return .mail(parts[2]) }
        if parts == ["hourly"] { return .every(3600) }
        if parts == ["on", "open"] { return .opens }
        if parts.count == 2, parts[0] == "every", let unit = parts[1].last, let n = Double(parts[1].dropLast()), n > 0 {
            let seconds = unit == "h" ? n * 3600 : unit == "m" ? n * 60 : 0
            return seconds >= 900 ? .every(seconds) : nil
        }
        return calendar(words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// A when at the start of a command line's words, the most words that
    /// read as one, `every`'s own word allowed to lead (`yab every 3 days
    /// 9:00 …`), and the words after it; nil when none do.
    nonisolated static func leading(_ words: [String]) -> (when: String, rest: [String])? {
        for count in stride(from: min(words.count, 7), through: 1, by: -1) {
            let head = words.prefix(count).joined(separator: " ")
            for when in [head, "every " + head] where schedule(when) != nil {
                return (when, Array(words.dropFirst(count)))
            }
        }
        return nil
    }

    nonisolated private static let weekdayNames = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
    nonisolated private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// A minute of the day from "9:00" or "18:30".
    nonisolated private static func minute(_ clock: Substring) -> Int? {
        let clock = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard clock.count == 2, let h = clock[0], let m = clock[1], (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// "monday", "mondays", "mon": 2.
    nonisolated private static func weekday(_ word: String) -> Int? {
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        guard word.count >= 3, let day = weekdayNames[String(word.prefix(3))] else { return nil }
        let name = full[day - 1]
        return name.hasPrefix(word) || word == name + "s" ? day : nil
    }

    /// "oct", "october": 10.
    nonisolated private static func month(_ word: String) -> Int? {
        let full = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        guard word.count >= 3, let index = monthNames.firstIndex(of: String(word.prefix(3))) else { return nil }
        return full[index].hasPrefix(word) || word == "sept" ? index + 1 : nil
    }

    /// "1st", "22nd", and a bare "15" when `bare`: a day of the month.
    nonisolated private static func dayOfMonth(_ word: String, bare: Bool) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where word.hasSuffix(suffix) { digits = String(word.dropLast(2)) }
        guard digits != word || bare, let day = Int(digits), (1...31).contains(day) else { return nil }
        return day
    }

    /// "first", "2nd", "last": which of a weekday in a month.
    nonisolated private static func ordinal(_ word: String) -> Int? {
        let words = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "last": -1]
        return words[word]
    }

    /// Days at times of day, from the words left once `schedule` has read
    /// the old fixed ones: the times wherever they stand ("9:00",
    /// "9:00,18:00"), then how often in the words around them.
    nonisolated private static func calendar(_ parts: [String]) -> Schedule? {
        var minutes: [Int] = []
        var words: [String] = []
        for part in parts {
            if part.contains(":") {
                for piece in part.split(separator: ",") {
                    guard let at = minute(piece) else { return nil }
                    minutes.append(at)
                }
            } else if part != "," {
                words.append(part)
            }
        }
        guard !minutes.isEmpty else { return nil }
        let at = Array(Set(minutes)).sorted()
        let fillers: Set<String> = ["at", "and", "on", "the", "of", "in", "each"]
        var t = words.filter { !fillers.contains($0) }
        func days(_ words: ArraySlice<String>) -> Set<Int>? {
            let named = words.flatMap { $0.split(separator: ",") }.map { weekdayNames[String($0.prefix(3))] }
            guard !named.isEmpty, named.allSatisfy({ $0 != nil }) else { return nil }
            return Set(named.compactMap { $0 })
        }
        // Every so many days or weeks: "every 3 days", "every 2 weeks mon".
        if t.first == "every", t.count >= 3, let n = t[1] == "other" ? 2 : Int(t[1]), n >= 1 {
            if ["day", "days"].contains(t[2]), t.count == 3, n <= 365 { return .days(n == 1 ? .week(Set(1...7)) : .cycle(n), at: at) }
            if ["week", "weeks"].contains(t[2]), n <= 52, let set = days(t[3...]) { return .days(n == 1 ? .week(set) : .weeks(n, set), at: at) }
            return nil
        }
        if t.first == "every" { t.removeFirst() }
        var monthly = false, yearly = false
        t = t.filter { word in
            switch word {
            case "monthly", "month": monthly = true; return false
            case "yearly", "annually", "year": yearly = true; return false
            case "weekly", "week": return false
            default: return true
            }
        }
        guard !t.isEmpty else { return nil }
        if t.count == 1, !monthly, !yearly {
            switch t[0] {
            case "daily", "everyday", "day": return .days(.week(Set(1...7)), at: at)
            case "weekdays", "weekday": return .days(.week([2, 3, 4, 5, 6]), at: at)
            case "weekends", "weekend": return .days(.week([1, 7]), at: at)
            default: break
            }
        }
        // A date of the year: "oct 6", "6 october".
        if t.count == 2, !monthly {
            let pairs = [(t[0], t[1]), (t[1], t[0])]
            for (name, number) in pairs {
                guard let m = month(name), let d = dayOfMonth(number, bare: true) else { continue }
                let most = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
                return d <= most ? .days(.year(month: m, day: d), at: at) : nil
            }
        }
        guard !yearly else { return nil }
        // A weekday of the month: "first monday", "last fri".
        if t.count == 2, let n = ordinal(t[0]), let day = weekday(t[1]) { return .days(.nth(n, weekday: day), at: at) }
        // A day of the month: "1st", "monthly 15", "last day", "monthly last".
        if t == ["last", "day"] || monthly && t == ["last"] { return .days(.month(0), at: at) }
        if t.count == 1, let d = dayOfMonth(t[0], bare: monthly) { return .days(.month(d), at: at) }
        guard !monthly, let set = days(t[...]) else { return nil }
        return .days(.week(set), at: at)
    }

    /// The words a schedule is kept in, as the editor writes them:
    /// "weekdays 9:00", "monthly last 18:00", "every 2 weeks mon,thu 9:00".
    nonisolated static func words(_ schedule: Schedule) -> String {
        switch schedule {
        case .every(let seconds):
            if seconds == 3600 { return "hourly" }
            if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "every \(Int(seconds / 3600))h" }
            return "every \(Int(seconds / 60))m"
        case .opens: return "on open"
        case .mail(let split): return mailWhen(split)
        case .days(let days, let at):
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            func list(_ set: Set<Int>) -> String { set.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: ",") }
            let times = at.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) }.joined(separator: ",")
            let head: String
            switch days {
            case .week(let set):
                head = set.count == 7 ? "daily" : set == [2, 3, 4, 5, 6] ? "weekdays" : set == [1, 7] ? "weekends" : list(set)
            case .cycle(let n): head = "every \(n) days"
            case .weeks(let n, let set): head = "every \(n) weeks " + list(set)
            case .month(let d): head = "monthly " + (d == 0 ? "last" : "\(d)")
            case .nth(let n, let day): head = (n < 0 ? "last" : ["first", "second", "third", "fourth", "fifth"][n - 1]) + " " + names[day - 1]
            case .year(let m, let d): head = "yearly \(monthNames[m - 1]) \(d)"
            }
            return head + " " + times
        }
    }

    /// When, as the list says it: "Weekdays at 9:00 AM", "Every 2 hours",
    /// "Monthly on the 1st at 9:00 AM". Words it can't read are said as
    /// they were given.
    nonisolated static func say(_ when: String, locale: Locale = AppDates.locale) -> String {
        switch schedule(when) {
        case .every(let seconds):
            if seconds == 3600 { return "Every hour" }
            if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "Every \(Int(seconds / 3600)) hours" }
            return "Every \(Int(seconds / 60)) minutes"
        case .opens:
            return "When Yab opens"
        case .mail(let split):
            return "When mail comes to " + (MailSplits.builtIns.first { $0.id == split }?.title ?? "its split")
        case .days(let days, let at):
            return say(days) + " at " + list(at.map { clock($0, locale: locale) })
        case nil:
            return when
        }
    }

    /// "Every day", "Every 3 days", "Monthly on the last Friday".
    nonisolated static func say(_ days: Days) -> String {
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        switch days {
        case .week(let set): return say(days: set)
        case .cycle(let n): return "Every \(n) days"
        case .weeks(let n, let set):
            let on = set.count == 7 ? "every day" : set == [2, 3, 4, 5, 6] ? "weekdays" : set == [1, 7] ? "weekends" : say(days: set)
            return "Every \(n) weeks on " + on
        case .month(let d): return "Monthly on the " + (d == 0 ? "last day" : nth(d))
        case .nth(let n, let day):
            return "Monthly on the " + (n < 0 ? "last" : ["first", "second", "third", "fourth", "fifth"][n - 1]) + " " + weekdays[day - 1]
        case .year(let m, let d): return "Every year on \(months[m - 1]) \(d)"
        }
    }

    /// "1st", "22nd", "13th".
    nonisolated static func nth(_ day: Int) -> String {
        let tens = day % 100 / 10, ones = day % 10
        let suffix = tens == 1 ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th"
        return "\(day)" + suffix
    }

    /// "a", "a and b", "a, b and c".
    nonisolated private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// "Every day", "Weekdays", "Mondays and Thursdays".
    nonisolated static func say(days: Set<Int>) -> String {
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
        // The week from Monday, as a calendar's row reads.
        return list(days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] })
    }

    /// A minute of the day as this Mac writes a time: "9:00 AM", "18:30".
    nonisolated static func clock(_ minute: Int, locale: Locale = AppDates.locale) -> String {
        let format = DateFormatter()
        format.locale = locale
        format.dateStyle = .none
        format.timeStyle = .short
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        format.timeZone = calendar.timeZone
        let day = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        return format.string(from: day.addingTimeInterval(Double(minute * 60)))
    }

    /// The calendar routines keep: the Gregorian one, in this Mac's time
    /// zone, whatever calendar the Mac shows. Routines run on local time.
    nonisolated static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// A day as a count from 1970-01-01, for gaps of days and weeks that
    /// no change of clocks can bend.
    nonisolated static func dayNumber(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    /// Whether a routine on these days runs on this day; `anchor` is the
    /// day number its gaps of days and weeks count from.
    nonisolated static func runs(_ days: Days, year: Int, month: Int, day: Int, weekday: Int, length: Int, anchor: Int) -> Bool {
        switch days {
        case .week(let set): return set.contains(weekday)
        case .cycle(let n):
            let gap = dayNumber(year, month, day) - anchor
            return gap >= 0 && gap % n == 0
        case .weeks(let n, let set):
            guard set.contains(weekday) else { return false }
            // Mondays: a week's first day, as the editor's chips run.
            func monday(_ number: Int) -> Int { number - ((number + 3) % 7 + 7) % 7 }
            let gap = (monday(dayNumber(year, month, day)) - monday(anchor)) / 7
            return gap >= 0 && gap % n == 0
        case .month(let d): return d == 0 ? day == length : day == min(d, length)
        case .nth(let n, let wd):
            guard weekday == wd else { return false }
            return n < 0 ? day + 7 > length : (day - 1) / 7 + 1 == n
        case .year(let m, let d): return month == m && day == min(d, length)
        }
    }

    /// How many days away a routine's next day can be.
    nonisolated private static func reach(_ days: Days) -> Int {
        switch days {
        case .week: return 8
        case .cycle(let n): return n + 1
        case .weeks(let n, _): return 7 * n + 8
        case .month, .nth, .year: return 400
        }
    }

    /// The times a routine on these days runs on the days `step` away from
    /// `now`, nearest first, as long as `keep` says so.
    nonisolated private static func walk(_ days: Days, at: [Int], from now: Date, forward: Bool, anchor: Date?,
                                         calendar: Calendar, keep: (Date) -> Bool) -> Date? {
        let start = calendar.dateComponents([.year, .month, .day], from: anchor ?? now)
        let anchorDay = dayNumber(start.year ?? 1970, start.month ?? 1, start.day ?? 1)
        let times = forward ? at : at.reversed()
        for step in 0..<reach(days) {
            guard let moment = calendar.date(byAdding: .day, value: forward ? step : -step, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: moment)
            guard let year = parts.year, let month = parts.month, let day = parts.day, let weekday = parts.weekday,
                  let length = calendar.range(of: .day, in: .month, for: moment)?.count,
                  runs(days, year: year, month: month, day: day, weekday: weekday, length: length, anchor: anchorDay) else { continue }
            for minute in times {
                // A time the clocks skip (2:30 the night they go forward) is
                // run the moment after.
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: minute / 60, minute: minute % 60)),
                      keep(date) else { continue }
                return date
            }
        }
        return nil
    }

    /// The last time it should have run, up to now. Gaps of days and weeks
    /// count from its last run (`since`), or from now when it has none.
    nonisolated static func due(_ schedule: Schedule, before now: Date, since last: Date? = nil, calendar: Calendar = localCalendar) -> Date {
        switch schedule {
        case .opens:
            return opened
        case .mail:
            // Not a time: mail coming starts it (mailCame).
            return .distantPast
        case .every(let seconds):
            return now.addingTimeInterval(-seconds)
        case .days(let days, let at):
            return walk(days, at: at, from: now, forward: false, anchor: last, calendar: calendar) { $0 <= now } ?? .distantPast
        }
    }

    /// Whether a run is owed now: a time it should have run came since its
    /// last run, less than twenty hours ago. Missed by more, a Mac asleep or
    /// a Yab closed through it, the next time is the next one.
    nonisolated static func owed(_ schedule: Schedule, last: Date?, now: Date, calendar: Calendar = localCalendar) -> Bool {
        if case .mail = schedule { return false }
        let due = due(schedule, before: now, since: last, calendar: calendar)
        return (last ?? .distantPast) < due && now.timeIntervalSince(due) < 20 * 3600
    }

    // MARK: - running

    /// Looked at every minute while yab is open.
    func start() {
        guard timer == nil, !all.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Routines.shared.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.tick() }
    }

    func tick() {
        // Routines don't fire while AI in Yab is When Asked or Off (AIUse).
        guard let browser = Agents.shared.browser, browser.prefs.bench, AIUse.allows(.background), !Store.measuring else { return }
        let now = Date()
        // A watch past its days is over.
        if all.contains(where: { ($0.until ?? .distantFuture) < now }) {
            all.removeAll { ($0.until ?? .distantFuture) < now }
            save()
        }
        // Written only when something ran: a save tells sync, and every
        // page that shows the routines, that they changed.
        for index in all.indices where all[index].off != true && all[index].runsHere {
            guard let schedule = Self.schedule(all[index].when) else { continue }
            if case .mail = schedule { continue }
            guard Self.owed(schedule, last: all[index].last, now: now) else { continue }
            if let running = Agents.shared.session(all[index].session), running.state.live { continue }
            run(all[index])
        }
    }

    // MARK: - on mail

    /// Mail placed in its splits (after Sense): each routine on a split's
    /// mail that isn't at work takes the oldest mail come there since it
    /// was set that it hasn't done, one a run.
    func mailCame(now: Date = Date()) {
        guard Agents.installed, AIUse.allows(.background), all.contains(where: { $0.off != true && $0.when.hasPrefix("on mail ") }) else { return }
        var changed = false
        // With sync every Mac has it, and only the one it runs on takes the mail.
        for index in all.indices where all[index].off != true && all[index].runsHere {
            guard case .mail(let split)? = Self.schedule(all[index].when) else { continue }
            if let running = Agents.shared.session(all[index].session), running.state.live { continue }
            let since = all[index].mailSince ?? all[index].last ?? now
            let done = Set(all[index].mailDone ?? [])
            let rows = MailDesk.read(split: split, query: "", account: "all", limit: 30).rows
            guard let row = Self.nextMail(rows.map { (id: $0.id, at: $0.at, real: $0.real) }, since: since, done: done),
                  let found = rows.first(where: { $0.id == row }) else { continue }
            all[index].mailDone = Array(((all[index].mailDone ?? []) + [row]).suffix(100))
            changed = true
            let ref = MailRef(kind: .thread(account: found.account, thread: found.thread), title: found.subject, detail: found.whoFull)
            if let session = run(all[index], mail: ref) { MailChat.took([ref], by: session) }
        }
        if changed { save() }
    }

    /// Of a split's rows, the oldest come since the routine was set that it
    /// hasn't done: its id.
    nonisolated static func nextMail(_ rows: [(id: String, at: Date, real: Bool)], since: Date, done: Set<String>) -> String? {
        rows.filter { $0.real && $0.at > since && !done.contains($0.id) }.min { $0.at < $1.at }?.id
    }

    /// A routine on a split's mail, from its head: asking each time, or on
    /// its own. Changed, it keeps what it did and its streak.
    @discardableResult
    func onMail(split: String, title: String, words: String, asks: Bool, id: String? = nil) -> Result<Routine, Trouble> {
        var routine = id.flatMap { id in all.first { $0.id == id } }
            ?? Routine(id: Self.newID(split + words), when: Self.mailWhen(split), prompt: words, last: nil, title: title + " routine")
        routine.prompt = words
        routine.may = asks ? "ask" : "agents"
        if routine.mailSince == nil { routine.mailSince = Date() }
        return put(routine)
    }

    /// The routine on a split's mail, if it has one.
    func onMail(_ split: String) -> Routine? {
        all.first { $0.when == Self.mailWhen(split) }
    }

    /// You answered what a run asked: yes after yes, a routine that asks
    /// each time asks once, at the fifth, whether it may run on its own.
    func answered(_ id: String, yes: Bool) {
        guard let index = all.firstIndex(where: { $0.id == id }), case .mail? = Self.schedule(all[index].when),
              all[index].may == "ask" else { return }
        all[index].streak = yes ? (all[index].streak ?? 0) + 1 : 0
        save()
        guard (all[index].streak ?? 0) >= Self.trustAfter, all[index].trustAsked != true else { return }
        all[index].trustAsked = true
        save()
        let question = Question(title: "It did \(Self.trustAfter) in a row the way you said. Let it run on its own?",
                                detail: "Pay and Send always wait for you, whichever you pick.", glyph: "checkmark.seal",
                                yes: "Let It Run", no: "Keep Asking")
        Task { @MainActor in
            guard await Questions.shared.ask(question), let at = self.all.firstIndex(where: { $0.id == id }) else { return }
            self.all[at].may = "agents"
            self.save()
        }
    }

    /// Yeses in a row before it asks to run on its own.
    nonisolated static let trustAfter = 5

    /// Findings handed over by each run still going, by its session.
    private var handed: [String: Int] = [:]
    /// Tries from the editor, by session: a routine that isn't kept yet,
    /// whose folder its try still fills.
    private var trials: [String: Routine] = [:]

    /// The routine a session runs, kept or tried.
    func running(_ session: String?) -> Routine? {
        if let kept = finder(of: session) { return kept }
        return trials[Agents.shared.root(of: session) ?? ""]
    }

    /// Run Now, Update Now: once, now, unless a run of it is going.
    func runNow(_ routine: Routine) {
        if let running = Agents.shared.session(routine.session), running.state.live { return }
        run(routine)
    }

    /// Once, now. A routine's runs are one chat, each after the last, and
    /// each a task of its own in it: its tabs a folder in the column while
    /// it works, its answer a page first in that folder. Its agent starts
    /// each run afresh, told what it said the time before, so a routine
    /// run for months costs what one run does. A try from the editor
    /// (`trial`) runs the routine as it stands in a chat of its own and
    /// keeps nothing.
    @discardableResult
    func run(_ routine: Routine, trial: Bool = false, mail: MailRef? = nil) -> Agents.Session? {
        // One run at a time: asked again while one is going (a terminal's
        // `every run`, an agent), the one going is the answer, its count
        // of what it found kept.
        if !trial, let running = Agents.shared.session(all.first { $0.id == routine.id }?.session ?? routine.session), running.state.live {
            return running
        }
        do { try BoostContributions.charge(routine.id); lastProblem = nil }
        catch {
            lastProblem = error.localizedDescription
            if let index = all.firstIndex(where: { $0.id == routine.id }) { all[index].said = error.localizedDescription; save() }
            return nil
        }
        let agents = Agents.shared
        if routine.quiet == true {
            let session = agents.run(prompt: routine.prompt, cli: nil, effort: "low", access: "browser", quiet: true, name: "Watching", resume: nil)
            session.routine = routine.id
            session.boostOrigin = BoostContributions.pluginID(routine.id)
            if let index = all.firstIndex(where: { $0.id == routine.id }) {
                all[index].last = Date()
                all[index].session = session.id
                save()
            }
            return session
        }
        let resume = trial ? nil : routine.chat.flatMap { agents.session($0) ?? agents.revive($0) }
        let fresh = resume.map { !$0.state.live } ?? false
        let session = agents.run(prompt: prompt(for: routine, mail: mail), cli: routine.cli, model: routine.model, effort: routine.effort,
                                 access: "browser", resume: resume?.id, project: routine.project)
        // Its chat follows the routine into or out of a project.
        if !trial, session.project != routine.project {
            session.project = routine.project
            Chats.shared.move([session.id], to: routine.project)
        }
        // Carried on in its chat, not in its agent's own thread.
        if fresh, session === resume { session.thread = nil }
        session.routine = trial ? nil : routine.id
        session.boostOrigin = BoostContributions.pluginID(routine.id)
        if mail != nil { session.mail = true }
        if trial { trials[session.id] = routine }
        session.task = true
        session.origin = .newTabs
        session.title = routine.name
        session.read = false
        session.progress = "Starting"
        session.saying.append(routine.name + " · " + Self.stamp(Date()))
        handed[session.id] = 0
        // Its folder says so while it looks; no page of its own for it.
        if routine.folder == true, !trial, let browser = Agents.shared.browser { LiveFolders.shared.checking(routine, true, in: browser) }
        if !trial, let index = all.firstIndex(where: { $0.id == routine.id }) {
            all[index].last = Date()
            all[index].session = session.id
            all[index].chat = session.id
            save()
        }
        return session
    }

    /// What its agent is told, its own words first; on a split's mail, the
    /// mail that came.
    func prompt(for routine: Routine, mail: MailRef? = nil) -> String {
        let command = routine.command.flatMap { id in Agents.shared.browser?.selectionCommands.commands.first { $0.id == id } }
        let tabs = routine.tabs ?? []
        let since = (routine.ended ?? routine.last).map { "since " + Self.stamp($0) } ?? "since yesterday"
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "{since}", with: since)
                .replacingOccurrences(of: "{date}", with: AppDates.string(from: Date(), dateStyle: .full, timeStyle: .none))
                .replacingOccurrences(of: "{tabs}", with: tabs.joined(separator: ", "))
                .replacingOccurrences(of: "{memory}", with: String(((Memory.read("USER") ?? "") + "\n" + (Memory.read("memory") ?? "")).prefix(6_000)))
                .replacingOccurrences(of: "{language}", with: "English")
        }
        var lines: [String] = []
        if let command {
            let job = fill(command.prompt)
                .replacingOccurrences(of: "{selection}", with: "the page's text")
                .replacingOccurrences(of: "{page}", with: "the page's text")
                .replacingOccurrences(of: "{around}", with: "")
                .replacingOccurrences(of: "{url}", with: tabs.first ?? "")
                .replacingOccurrences(of: "{title}", with: "the page's title")
            let pages = tabs.isEmpty ? "the page the user named" : tabs.joined(separator: ", ")
            lines.append("This is a routine the user set to run \(Self.say(routine.when).lowercased()): the command \(SelectionCommand.menuTitle(command.name)) on \(pages). Open each in a tab of your own, read it with `text`, and do this with its text: «\(job)»")
            if !routine.prompt.isEmpty { lines.append("The user adds: «\(fill(routine.prompt))»") }
        } else {
            lines.append("This is a routine the user set to run \(Self.say(routine.when).lowercased()), in their own words: «\(fill(routine.prompt))»")
        }
        if !tabs.isEmpty, command == nil {
            lines.append("Work from these pages, each in a tab of your own, or with `fetch` and the site's skill where that needs no tab: \(tabs.joined(separator: ", ")).")
        }
        if let mail {
            lines.append("It runs now because this email came: " + MailChat.sentence(mail) + " Do it for this one email only.")
            // Whichever it may do, paying and sending wait for the person.
            lines.append("Before anything that pays or sends, stop and ask with `ask`, saying what would happen.")
        }
        switch routine.may ?? "read" {
        case "ask":
            lines.append("Before anything that sends, pays, books, deletes or changes something, stop and ask with `ask`, saying what would happen.")
        case "agents":
            break
        default:
            lines.append("Only read: click nothing that sends, pays, books, deletes or changes something, mark nothing read, answer nothing.")
        }
        if routine.folder == true {
            lines.append(folderWords(for: routine))
            return lines.joined(separator: "\n\n")
        }
        if let said = Self.previous(routine) {
            lines.append("Last time, \(since.dropFirst(6)), you told the user: «\(said)». Leave out what is unchanged since then.")
        }
        lines.append("""
        Hand each thing the user should see or act on to `suggest`: a title, one line of detail, and the url of \
        the thing itself (the thread, the issue, the pull request). Leave open, in your own tabs, only the pages \
        of what you found, four at most, and close the rest.
        Finish with the answer in Markdown and nothing else: a first line `# ` saying in a few words what needs \
        the user (`# Two things need you`), then a line or two for each. When there is nothing new, answer only \
        `Nothing new.` and close your tabs.
        """)
        return lines.joined(separator: "\n\n")
    }

    /// Most pages a routine's folder holds.
    static let folderMost = 20

    /// What a run that keeps a folder is told instead of answering: what the
    /// folder holds now, and to hand back all that belongs with
    /// `folder_update`.
    func folderWords(for routine: Routine) -> String {
        let held = Agents.shared.browser.map { LiveFolders.shared.held(by: routine, in: $0) } ?? []
        let now = held.isEmpty ? "It is empty so far." : "It holds now, one a line (address · title · its words):\n"
            + held.map { [$0.url, $0.title, $0.said].filter { !$0.isEmpty }.joined(separator: " · ") }.joined(separator: "\n")
        return """
        This routine keeps a folder of pages for the user, «\(routine.name)», in their browser. \(now)
        Find what belongs in it now, and check the pages it holds. Then call `folder_update` once, with every \
        page that belongs, best first, \(Self.folderMost) at most: its url, a short title, and `words`, one to four \
        words for the row's end, what the user wants to see at a glance: the value itself (a price, a date), \
        with its change only when it changed (`$3,800 · −$150`). "New" only on a page that came since the last \
        run, never on a first run, and never words for no change ("No change", "Same"). Set `loud` only on what \
        needs a look now: a new one, a change for the better. A page the folder holds \
        that no longer belongs: list it once more with `gone` true and `words` saying why ("Rented", "Over \
        $4,500", "Closed"); leave out ones already said gone. Don't call `suggest`. Close your tabs when done.
        Finish with one line saying what changed (`2 new, 1 cheaper, 1 gone`), or only `Nothing new.`
        """
    }

    /// Its last answer, a few lines of it, when it had one worth saying.
    private static func previous(_ routine: Routine) -> String? {
        guard let chat = routine.chat.flatMap({ Chats.shared.chat($0) }) else { return nil }
        let answer = chat.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !nothing(answer) else { return nil }
        return String(answer.prefix(800))
    }

    /// A run's answer that says there was nothing.
    nonisolated static func nothing(_ answer: String) -> Bool {
        let first = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        return first.isEmpty || first.hasPrefix("nothing new") || first.hasPrefix("nothing needs")
    }

    /// Things a run handed over with `suggest`, counted for its words.
    func suggested(_ count: Int, by session: String?) {
        guard let session, let root = Agents.shared.session(Agents.shared.root(of: session)), handed[root.id] != nil else { return }
        handed[root.id, default: 0] += count
    }

    /// Whether a finding came from a routine's run, and which: for its row's words.
    func finder(of session: String?) -> Routine? {
        guard let root = Agents.shared.session(Agents.shared.root(of: session)), let id = root.routine else { return nil }
        return all.first { $0.id == id }
    }

    /// A run is over. Found nothing: nothing stays, its tabs go now and it
    /// is read. Found something: its answer is in its chat, unread, and ⌘T
    /// has what it found; a notice only if the routine asks for one, Show
    /// opening the chat.
    func finished(_ session: Agents.Session, _ state: Agents.State, in browser: Browser) {
        let found = handed.removeValue(forKey: session.id) ?? 0
        let looking = browser.active.map { $0.agent == session.id } ?? false
            || browser.chatOpen && browser.chatShown == Agents.shared.root(of: session.id)
        let tried = trials.removeValue(forKey: session.id)
        let routine = session.routine.flatMap { id in all.first { $0.id == id } } ?? tried
        let tell = routine?.tell ?? "quiet"
        if let index = all.firstIndex(where: { $0.id == session.routine }) {
            all[index].found = state == .done ? found : nil
            all[index].ended = Date()
            let line = session.result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            all[index].said = String(line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression).prefix(140))
            save()
        }
        session.progress = nil
        let name = routine?.name ?? Folders.title(session.id)
        if let routine, routine.folder == true {
            return keptFolder(routine, session, state, found: found, looking: looking, in: browser)
        }
        guard state == .done else {
            if state == .failed, tell != "quiet", !looking { browser.toaster.pop("\(name) couldn’t finish", mark: "exclamationmark.triangle") }
            return
        }
        if found == 0, Self.nothing(session.result) {
            session.read = true
            for tab in Agents.shared.tabs(of: session) where tab.id != browser.activeID { browser.close(tab) }
            if tell == "always", !looking { browser.toaster.pop("\(name): nothing new", mark: SettingsPage.agentRoutines.icon) }
            return
        }
        session.read = looking
        guard tell != "quiet", !looking else { return }
        let words = found > 1 ? "\(name) found \(found) things" : TaskAnswer.pick(session.result).map { "\(name): \($0)" } ?? "\(name) found something"
        if browser.chatOpen {
            // The finding itself at the column's top, as a notice comes in
            // on the iPhone, its project's circle on it (ChatRoutineBanner).
            ChatBanners.shared.show(.init(chat: session.id, project: routine?.project ?? session.project, title: name,
                                          body: TaskAnswer.pick(session.result) ?? (found > 1 ? "Found \(found) things" : "Found something")))
        } else {
            browser.toaster.pop(words, mark: SettingsPage.agentRoutines.icon, undo: { [weak browser] in
                browser?.showChat(session.id)
            }, act: "Show", feedback: .success)
        }
        AgentNotices.shared.browser = browser
        AgentNotices.shared.post(chat: session.id, title: name, body: TaskAnswer.pick(session.result) ?? words)
    }

    /// A run that keeps a folder is over: the folder said it all. Its tabs
    /// closed, its chat read; a notice only as the routine asks,
    /// Show opening the first thing that needs a look.
    private func keptFolder(_ routine: Routine, _ session: Agents.Session, _ state: Agents.State, found: Int, looking: Bool,
                            in browser: Browser) {
        LiveFolders.shared.checking(routine, false, in: browser)
        session.read = true
        for tab in Agents.shared.tabs(of: session) where tab.id != browser.activeID && tab.nest?.live?.source != "routine" { browser.close(tab) }
        let tell = routine.tell ?? "quiet"
        guard !looking else { return }
        if state == .failed, tell != "quiet" {
            browser.toaster.pop("\(routine.name) couldn’t finish", mark: "exclamationmark.triangle")
            return
        }
        guard state == .done, tell == "always" || (tell == "found" && found > 0) else { return }
        let nest = LiveFolders.shared.folder(of: routine, in: browser)
        let first = browser.tabs.first { $0.nest === nest && $0.nest != nil && $0.live?.callsOut == true }
        let words = found == 0 ? "\(routine.name): nothing new" : found == 1 ? "\(routine.name): 1 new" : "\(routine.name): \(found) new"
        browser.toaster.pop(words, mark: "folder", undo: { [weak browser] in
            guard let browser else { return }
            if let nest { nest.open = true }
            if let first { browser.select(first) }
        }, act: first == nil ? nil : "Show", feedback: .success)
    }

    /// Its chat, in the column of the window in front.
    func openChat(_ routine: Routine) {
        guard let chat = routine.chat, let browser = Agents.shared.browser else { return }
        NSApp.activate()
        Links.window?.makeKeyAndOrderFront(nil)
        browser.keepChat(chat)
        browser.showChat(chat)
    }

    /// Its run is over: kept for the watches, whose runs aren't tasks.
    func ended(_ session: Agents.Session) {
        // Stopped, it never reached `finished`: its count goes too.
        if session.state == .stopped { handed[session.id] = nil }
        if !session.state.live, session.routine == nil { trials[session.id] = nil }
        if !session.state.live, let routine = session.routine.flatMap({ id in all.first { $0.id == id } }), routine.folder == true,
           let browser = Agents.shared.browser {
            LiveFolders.shared.checking(routine, false, in: browser)
        }
        guard session.routine != nil, !session.task, let index = all.firstIndex(where: { $0.id == session.routine }) else { return }
        let line = session.result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        all[index].said = String(line.prefix(140))
        all[index].ended = Date()
        save()
    }

    // MARK: - made from words and chats

    /// A task in words that starts with when to do it, "every weekday at 10
    /// tell me which of these wait on my review": the when, as `schedule`
    /// reads it, and the task. Nil when the words don't start so.
    nonisolated static func phrase(_ text: String) -> (when: String, task: String)? {
        let lower = text.lowercased()
        let dayNames: [(String, String)] = [
            ("monday", "mon"), ("tuesday", "tue"), ("wednesday", "wed"), ("thursday", "thu"), ("friday", "fri"), ("saturday", "sat"), ("sunday", "sun"),
        ]
        // How often, and the hour it implies when no time is said.
        var days: String?
        var hour = 9
        var rest = Substring(lower)
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: String(rest), range: NSRange(rest.startIndex..., in: rest)) else { return nil }
            let whole = String(rest)
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: whole) else { return "" }
                return String(whole[range])
            }
            rest = Substring(whole[whole.index(whole.startIndex, offsetBy: groups[0].count)...])
            return groups
        }
        if let got = take(#"(?:every|each)\s+(\d+)\s*(?:hours?|hrs?|h)\b"#) {
            guard let n = Int(got[1]), n >= 1, n <= 12 else { return nil }
            days = n == 1 ? "hourly" : "every \(n)h"
        } else if take(#"(?:every|each)\s+hour\b|hourly\b"#) != nil {
            days = "hourly"
        } else if take(#"(?:every|each)\s+(?:weekday|work\s?day)s?\b|(?:on\s+)?weekdays\b"#) != nil {
            days = "weekdays"
        } else if take(#"(?:every|each)\s+weekends?\b|(?:on\s+)?weekends\b"#) != nil {
            days = "weekends"; hour = 10
        } else if take(#"(?:every|each)\s+morning\b"#) != nil {
            days = "daily"
        } else if take(#"(?:every|each)\s+(?:evening|night)\b"#) != nil {
            days = "daily"; hour = 18
        } else if take(#"(?:every|each)\s+day\b|daily\b"#) != nil {
            days = "daily"
        } else {
            for (name, short) in dayNames {
                if take(#"(?:every|each|on)\s+"# + name + #"s?\b"#) != nil { days = short; break }
            }
        }
        guard let days else { return nil }
        var minute = hour * 60
        var timed = false
        if Self.schedule(days) == nil {
            if let got = take(#"\s*at\s*(\d{1,2})(?::|\.)?(\d{2})?\s*(am|pm|a\.m\.|p\.m\.)?"#) {
                guard var h = Int(got[1]), h < 24 else { return nil }
                let m = Int(got[2]) ?? 0
                let meridiem = got[3].replacingOccurrences(of: ".", with: "")
                if meridiem == "pm", h < 12 { h += 12 }
                if meridiem == "am", h == 12 { h = 0 }
                guard m < 60 else { return nil }
                minute = h * 60 + m
                timed = true
            }
        }
        let separated = rest.trimmingCharacters(in: .whitespaces).first.map { ",:;—-".contains($0) } ?? false
        let task = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:;—-")))
        guard task.count >= 3 else { return nil }
        // Meant as a when: a time said, set off by a comma, or a task that
        // starts with doing something; not "every day I read the news".
        let first = task.split(separator: " ").first.map(String.init) ?? ""
        guard timed || separated || TaskWords.verbs.contains(first) else { return nil }
        // The task in its own letters, as typed.
        let start = text.index(text.endIndex, offsetBy: -task.count)
        let when = Self.schedule(days) != nil ? days : days + " \(minute / 60):" + String(format: "%02d", minute % 60)
        guard Self.schedule(when) != nil else { return nil }
        return (when, String(text[start...]))
    }

    /// A routine from a task typed with its when, on the tab it was asked
    /// on: set, and said so in the corner, with the way to change it.
    func fromWords(_ task: String, when: String, tabs: [Tab], in browser: Browser, project: String? = nil) {
        var routine = Routine(id: Self.newID(task), when: when, prompt: task, last: nil, title: Routine.name(from: task))
        // Said in a project's field: its runs are chats in that project.
        routine.project = project
        var seen = Set<String>()
        let addresses = tabs.compactMap { $0.address }.filter { $0.scheme?.hasPrefix("http") == true }.map(\.absoluteString)
            .filter { seen.insert($0).inserted }
        if !addresses.isEmpty { routine.tabs = Array(addresses.prefix(4)) }
        guard case .success(let made) = put(routine) else { return }
        browser.toaster.pop("Routine set: \(Self.say(made.when).lowercased())", mark: SettingsPage.agentRoutines.icon, undo: { [weak browser] in
            guard let browser else { return }
            SettingsWindow.shared.showRoutine(made, for: browser)
        }, act: "Change")
    }

    /// A chat made a routine, from its answer's Repeat: its words, the sites
    /// its tabs were on, at this time of day from now on.
    func repeatChat(_ chat: Chat, asked: String, when: String, folder: Bool = false, in browser: Browser) {
        var routine = Routine(id: Self.newID(chat.id), when: when, prompt: asked, last: nil, title: chat.title)
        routine.tabs = Self.sites(of: chat)
        if folder, !chat.tabs.isEmpty { routine.folder = true }
        guard case .success(let made) = put(routine) else { return }
        // Its folder begins with what the chat found: the pages it opened.
        // A routine that keeps a folder turns Live Folders on, as saving one
        // in Settings does: off, its folder was never made, and each run was
        // told it couldn't be (evals/folders/repeat.py, 2026-10-17).
        if made.folder == true {
            browser.prefs.usesLiveFolders = true
            keepChatTabs(chat, in: made, browser: browser)
        }
        // Its card in the chat: when it runs, the next run, Pause.
        let next = Self.next(made, after: Date()).map { "Next: " + Self.stamp($0) }
        Agents.shared.card(ResultCard(kind: .routine, title: Self.say(made.when), detail: next, ref: made.id), in: chat.id)
        browser.toaster.pop("Repeats \(Self.say(made.when).lowercased())", mark: SettingsPage.agentRoutines.icon, undo: { [weak browser] in
            guard let browser else { return }
            SettingsWindow.shared.showRoutine(made, for: browser)
        }, act: "Change")
    }

    /// A chat's pages, as the first of a routine's folder.
    private func keepChatTabs(_ chat: Chat, in routine: Routine, browser: Browser) {
        let items = chat.tabs.prefix(Self.folderMost).compactMap { ref -> LiveItem? in
            guard let url = URL(string: ref.url), url.scheme?.hasPrefix("http") == true, let key = LiveFolder.page(url) else { return nil }
            return LiveItem(key: key, url: url, title: ref.title, group: "", words: nil, updated: nil)
        }
        // Only a completed source task can offer its original pages. The
        // folder's diff chooses which ones to adopt before ownership moves:
        // a duplicate key, or a page kept elsewhere, never leaks into today.
        var candidates = Set<UUID>()
        if ["done", "failed", "stopped"].contains(chat.state),
           Agents.shared.session(chat.id)?.state.live != true {
            let refs = Set(chat.tabs.map(\.id))
            let keys = Set(items.map(\.key))
            for tab in browser.tabs where refs.contains(tab.id.uuidString) && tab.pin == nil && !tab.kept &&
                Agents.shared.root(of: tab.agent) == chat.id && Agents.shared.session(tab.agent)?.state.live != true &&
                keys.contains(LiveFolder.page(tab.address) ?? "") {
                candidates.insert(tab.id)
            }
        }
        LiveFolders.shared.keep(routine, items, adoptingTaskTabs: candidates, in: browser)
    }

    /// The same, when a time of its own is wanted: the editor, filled in.
    func repeatChatCustom(_ chat: Chat, asked: String, folder: Bool = false, in browser: Browser) {
        var routine = Routine(id: Self.newID(chat.id), when: "weekdays 9:00", prompt: asked, last: nil, title: chat.title)
        routine.tabs = Self.sites(of: chat)
        if folder, !chat.tabs.isEmpty { routine.folder = true }
        repeating[routine.id] = RepeatSeed(chat, browser: browser)
        SettingsWindow.shared.showRoutine(routine, for: browser, fresh: true)
    }

    /// The sites a chat's tabs were on, three at most, each once.
    nonisolated static func sites(of chat: Chat) -> [String]? {
        var seen = Set<String>()
        let sites = chat.tabs.compactMap { ref -> String? in
            guard let url = URL(string: ref.url), url.scheme?.hasPrefix("http") == true, let host = url.host(), seen.insert(host).inserted else { return nil }
            return "https://" + host
        }
        return sites.isEmpty ? nil : Array(sites.prefix(3))
    }

    /// When a Repeat offers, at the hour a chat was had, on the half hour.
    nonisolated static func presets(at date: Date) -> [(title: String, value: String)] {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = max(6 * 60, min(22 * 60, (parts.hour ?? 9) * 60 + (parts.minute ?? 0) / 30 * 30))
        let clock = "\(minute / 60):" + String(format: "%02d", minute % 60)
        let day = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][(Calendar.current.component(.weekday, from: date) + 6) % 7]
        return ["weekdays " + clock, "daily " + clock, day + " " + clock, "hourly"].map { (say($0).replacingOccurrences(of: "Weekdays", with: "Every Weekday"), $0) }
    }

    // MARK: - in words

    /// "Mon 9:02", or "9:02" today, or "Nov 1, 9:02" more than a few days
    /// away: when, as a run's line says it.
    nonisolated static func stamp(_ date: Date, now: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = AppDates.locale
        let near = abs(date.timeIntervalSince(now)) < 6 * 86_400
        let thisYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        format.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : near ? "EEEjmm" : thisYear ? "MMMdjmm" : "yMMMdjmm")
        return format.string(from: date)
    }

    /// What its last run came to, for its row: "Ran at 9:02 · 2 things for you".
    nonisolated static func status(_ routine: Routine, live: Bool, now: Date = Date()) -> String {
        if routine.off == true { return "Off" }
        if live { return "Running now" }
        if let until = routine.until {
            return "Watching the thread until " + AppDates.string(from: until, dateStyle: .medium, timeStyle: .none)
        }
        if let ended = routine.ended {
            let what: String
            switch routine.found {
            case nil: what = failure(routine.said)
            case 0?: what = nothing(routine.said ?? "") ? "nothing new" : (routine.said ?? "done")
            case 1?: what = routine.folder == true ? "1 new" : "1 thing for you"
            case let count?: what = routine.folder == true ? "\(count) new" : "\(count) things for you"
            }
            return (routine.folder == true ? "Folder · " : "") + "Ran at \(stamp(ended, now: now)) · \(what)"
        }
        if routine.folder == true, let next = next(routine, after: now) { return "Folder · first run \(stamp(next, now: now))" }
        if let next = next(routine, after: now) { return "First run \(stamp(next, now: now))" }
        return say(routine.when)
    }

    /// A run that couldn't finish, and why in a few words when its last
    /// line says: a plan out of room or a sign-in gone runs into the same
    /// wall every time, and only these words say so.
    nonisolated static func failure(_ said: String?) -> String {
        guard let said, !said.trimmingCharacters(in: .whitespaces).isEmpty else { return "couldn’t finish" }
        switch ChatProblem(said, agent: "").kind {
        case .quota: return "couldn’t finish: plan out of room"
        case .signIn: return "couldn’t finish: sign in again"
        case .rateLimit, .service: return "couldn’t finish: service busy"
        case .network: return "couldn’t finish: connection dropped"
        case .modelUnavailable: return "couldn’t finish: model unavailable"
        default: return "couldn’t finish"
        }
    }

    /// When it runs next, when that can be said.
    nonisolated static func next(_ routine: Routine, after now: Date, calendar: Calendar = localCalendar) -> Date? {
        switch schedule(routine.when) {
        case .every(let seconds):
            return (routine.last ?? now).addingTimeInterval(seconds)
        case .days(let days, let at):
            return walk(days, at: at, from: now, forward: true, anchor: routine.last, calendar: calendar) { $0 > now }
        case .opens, .mail, nil:
            return nil
        }
    }

    /// "Next: Nov 1, 9:00 AM", for the editor's line under when.
    nonisolated static func nextWords(_ routine: Routine, after now: Date = Date(), locale: Locale = AppDates.locale) -> String? {
        guard let next = next(routine, after: now) else { return nil }
        let format = DateFormatter()
        format.locale = locale
        format.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(next, equalTo: now, toGranularity: .year) ? "MMMdjmm" : "yMMMdjmm")
        return "Next: " + format.string(from: next)
    }

    /// "Weekdays 9:00", "On the 1st 9:00", "Last Fri 17:00 +1": the words
    /// of a table's cell, its first time and how many more.
    nonisolated static func short(_ when: String, locale: Locale = AppDates.locale) -> String {
        guard case .days(let days, let at)? = schedule(when) else { return say(when, locale: locale).replacingOccurrences(of: " at ", with: " ") }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let head: String
        switch days {
        case .week(let set): head = say(days: set)
        case .cycle(let n): head = "Every \(n) days"
        case .weeks(let n, _): head = "Every \(n) weeks"
        case .month(let d): head = d == 0 ? "Last day" : "On the " + nth(d)
        case .nth(let n, let day): head = (n < 0 ? "Last" : nth(n)) + " " + names[day - 1]
        case .year(let m, let d): head = "\(months[m - 1]) \(d)"
        }
        return head + " " + clock(at.first ?? 0, locale: locale) + (at.count > 1 ? " +\(at.count - 1)" : "")
    }

    /// The times a row's cell offers: its own days at other times would be
    /// the editor's; here, how often, keeping the time it has.
    nonisolated static func quickTimes(_ when: String) -> [(title: String, value: String)] {
        let split = RoutineWhen.split(when)
        var out: [(String, String)] = []
        for key in ["daily", "weekdays", "weekends", "hourly", "every 2h", "every 4h", "on open"] {
            var parts = split
            parts.repeats = key
            let value = RoutineWhen.join(parts)
            out.append((short(value), value))
        }
        if !out.contains(where: { $0.1 == when }) { out.insert((short(when), when), at: 0) }
        return out
    }

    /// The sites it works on, for its marks.
    nonisolated static func hosts(_ routine: Routine) -> [String] {
        var seen = Set<String>()
        return (routine.tabs ?? []).compactMap { address in
            guard let host = URL(string: address)?.host() else { return nil }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return seen.insert(bare).inserted ? bare : nil
        }
    }
}

// MARK: - ideas

/// A routine Settings offers for a site you use: what the row says, when
/// it would run, and the task it would give the agent.
struct RoutineIdea: Identifiable, Equatable, Sendable {
    let id: String
    /// Where it looks, and whose use brings it up: a host and every host
    /// under it. None for the one offered to anyone.
    let sites: [String]
    let title: String
    let when: String
    let task: String

    /// The one a new Yab offers, with nothing in its history yet to go on.
    static let anyone = RoutineIdea(
        id: "brief", sites: [], title: "What needs me today", when: "weekdays 9:00",
        task: "Look through the places I use most, my mail, calendar and messages, and tell me what needs me today.")

    static let all: [RoutineIdea] = [
        RoutineIdea(id: "mail", sites: ["mail.google.com", "outlook.office.com", "outlook.live.com", "mail.yahoo.com", "app.fastmail.com"],
                    title: "Anything urgent in my mail", when: "weekdays 9:00",
                    task: "Check my mail for anything urgent: a question waiting on my answer, a deadline, a payment that failed. Mark nothing read and answer nothing."),
        RoutineIdea(id: "calendar", sites: ["calendar.google.com"],
                    title: "Tomorrow's meetings, and what to prepare", when: "weekdays 18:00",
                    task: "Look at tomorrow's calendar and tell me what to prepare for each meeting: a doc to read, a question to answer first."),
        RoutineIdea(id: "github", sites: ["github.com"],
                    title: "Pull requests waiting on me", when: "weekdays 10:00",
                    task: "Find the GitHub pull requests waiting on my review, and my own with new comments or failing checks."),
        RoutineIdea(id: "linear", sites: ["linear.app"],
                    title: "My Linear issues that moved", when: "weekdays 9:30",
                    task: "Look at the Linear issues assigned to me or made by me that changed since yesterday: new comments, a new status, a new blocker."),
        RoutineIdea(id: "slack", sites: ["slack.com"],
                    title: "Slack threads still waiting on me", when: "weekdays 17:00",
                    task: "Find today's Slack messages and threads that mention me or ask me something and that I haven't answered. Mark nothing read."),
        RoutineIdea(id: "notion", sites: ["notion.so", "notion.com"],
                    title: "Notion pages that mention me", when: "weekdays 11:00",
                    task: "Find the Notion pages and comments from the last day that mention me or were shared with me."),
        RoutineIdea(id: "hn", sites: ["news.ycombinator.com"],
                    title: "Hacker News worth my time", when: "daily 8:00",
                    task: "Read the Hacker News front page and pick the few stories I'd want to read, going by what I usually read."),
    ]

    /// The site its mark is drawn from.
    var site: String? { sites.first }

    func covers(_ host: String) -> Bool {
        let host = host.lowercased()
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The ones worth offering, most used first: a site opened at least
    /// five times in the month, none already set up or turned down, three
    /// at most. With no history to go on, the one for anyone.
    static func offered(visits: [String: Int], set: [Routine], declined: Set<String>, limit: Int = 3) -> [RoutineIdea] {
        let tasks = Set(set.map { $0.prompt.lowercased() })
        let open = { (idea: RoutineIdea) in !declined.contains(idea.id) && !tasks.contains(idea.task.lowercased()) }
        let used = all.map { idea in (idea, visits.reduce(0) { $0 + (idea.covers($1.key) ? $1.value : 0) }) }
            .filter { $0.1 >= 5 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        guard !used.isEmpty else { return open(anyone) && set.isEmpty ? [anyone] : [] }
        return Array(used.filter(open).prefix(limit))
    }
}

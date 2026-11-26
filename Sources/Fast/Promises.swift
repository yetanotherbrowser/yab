import Foundation
import MailCore

// Promises in Now (docs/promises.md): what you said you'd do, and what
// people said they'd do for you, as one row in Now on the day it is due,
// and never before. Read on this Mac (MailPromise); shown by rules that
// keep it quiet: a promise is a row only in its window (its day, its last
// two hours when a time was said, after its day when it is theirs and they
// have gone quiet), one at most in the field's two rows, two different
// ones a day at most, none that sat there three days untouched, and none
// at all once nobody has opened one for two weeks. A row goes by itself
// when the promise is kept.

@MainActor
final class Promises {
    static let shared = Promises()

    private init() {}

    // MARK: - what is open

    /// A promise as Now sees it: the mail's reading, and where it lives.
    struct Item: Equatable {
        var promise: MailPromised
        var account: String
        /// Their mail since its day: they spoke up, nothing to nudge.
        var heard = false
        /// Said on a site, not in mail: the page it was said on, and the
        /// site's name ("Slack").
        var page: URL? = nil
        var source: String? = nil

        var id: String { page == nil ? Promises.id(promise) : (promise.theirs ? "promise.theirs.web." : "promise.mine.web.") + promise.message }
    }

    /// Every account's open promises, both ways, with whether they spoke
    /// up after the day theirs named. The address field asks for these as
    /// it composes its first rows, so they are read through the store's
    /// WAL reader: a sync write never holds the click (row 857).
    func items(now: Date) -> [Item] {
        let said = web.filter { $0.promise.state == .open || $0.promise.state == .judgment }
        guard MailCenter.shared.connected else { return testing + said }
        var out: [Item] = said
        for engine in MailCenter.shared.engines.values {
            let store = engine.store.off
            for promise in store.promises(states: [.open, .judgment]) {
                var item = Item(promise: promise, account: engine.account)
                if promise.theirs, let due = promise.due, due < now {
                    item.heard = store.messages(thread: promise.thread)
                        .contains { $0.from.address.lowercased() == promise.address && $0.date > due }
                }
                out.append(item)
            }
        }
        return out + testing
    }

    /// Promises a test world hands over (bench `hints-promises` add).
    var testing: [Item] = []

    nonisolated static func id(_ promise: MailPromised) -> String {
        (promise.theirs ? "promise.theirs.mail." : "promise.mine.mail.") + promise.thread
    }

    // MARK: - its window

    /// How long after its day a promise stays: a week, then it is history.
    nonisolated static let after: TimeInterval = 7 * 86_400
    /// One with no day: from its third day to its fourteenth.
    nonisolated static let undatedFrom: TimeInterval = 3 * 86_400
    nonisolated static let undatedUntil: TimeInterval = 14 * 86_400
    /// Anything said longer ago than this is no longer a promise.
    nonisolated static let stale: TimeInterval = 21 * 86_400

    /// Whether a promise is a row in Now at all now: in its window, not a
    /// maybe, not stale. Its place in the field is the budget's.
    nonisolated static func due(_ item: Item, now: Date, calendar: Calendar = .current) -> Bool {
        let promise = item.promise
        guard promise.state == .open || promise.state == .judgment,
              now.timeIntervalSince(promise.at) < stale, now >= promise.at else { return false }
        guard let due = promise.due else {
            // No day: only a thing or an intro of yours, from its third day.
            guard !promise.theirs, promise.kind != .word else { return false }
            let age = now.timeIntervalSince(promise.at)
            return age >= undatedFrom && age < undatedUntil
        }
        if now.timeIntervalSince(due) > after { return false }
        if promise.theirs {
            // Theirs: once its day has gone and they have said nothing since.
            return due < now && !calendar.isDate(due, inSameDayAs: now) && !item.heard
        }
        if promise.timed { return due.timeIntervalSince(now) < 2 * 3600 }
        if promise.soft {
            // A week's: from the day before its end (Thursday for a Friday).
            let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: due)) ?? due
            return now >= from
        }
        return now >= calendar.startOfDay(for: due)
    }

    // MARK: - the row

    /// The rows Now has for promises now, before the budget picks which
    /// may stand in the field.
    func rows(now: Date) -> [Hint] {
        let attention = self.attention
        let not = notSaid
        return items(now: now).filter { item in
            Promises.due(item, now: now) && !not.contains(Promises.fingerprint(item.promise.quote))
                && attention[item.id].map { !$0.away(now: now) } ?? true
        }.map { item in
            Promises.hint(item, still: attention[item.id]?.ignored(now: now) ?? false, now: now)
        }
    }

    /// Open promises whose window hasn't come: theirs before their day,
    /// yours days ahead. Only in Now's place, under Promises.
    func upcoming(now: Date) -> [Hint] {
        items(now: now).filter { item in
            let promise = item.promise
            guard !Promises.due(item, now: now), let due = promise.due, due > now,
                  now.timeIntervalSince(promise.at) < Promises.stale else { return false }
            return attention[item.id].map { !$0.away(now: now) } ?? true
        }.map { Promises.hint($0, now: now) }
    }

    nonisolated static func hint(_ item: Item, still: Bool = false, now: Date) -> Hint {
        let promise = item.promise
        var parts = URLComponents(string: "yab://mail")!
        parts.fragment = "thread=" + item.account + "|" + promise.thread
        let host = item.page?.host() ?? promise.address.split(separator: "@").last.map(String.init)
        let words = Promises.words(promise, now: now)
        let detail = (still ? "Still on? · " : "") + words + " · " + (item.source ?? "Mail")
        return Hint(id: item.id, icon: .picture(promise.theirs ? "mail" : "reply", site: host), title: title(promise), detail: detail,
                    url: item.page ?? parts.url, due: promise.due, quote: promise.quote, source: .noticed,
                    kind: promise.theirs ? Noticing.Kind.promiseTheirs.rawValue : Noticing.Kind.promiseMine.rawValue,
                    sender: promise.address.isEmpty ? nil : Hint.Sender(address: promise.address, name: first(promise.person, promise.address)),
                    day: promise.due != nil && !promise.timed ? true : nil)
    }

    nonisolated static func first(_ person: String, _ address: String) -> String {
        let name = person.split(separator: " ").first.map(String.init) ?? ""
        if !name.isEmpty, !name.contains("@") { return name }
        return address.split(separator: "@").first.map(String.init) ?? address
    }

    // MARK: - its title

    /// The thing to do, from the words said: "I'll send you the deck by
    /// Friday" to Olya is "Send Olya the deck"; theirs "Mark owes you the
    /// term sheet". The words are kept as they are where the rules can't
    /// make a clean phrase of them.
    nonisolated static func title(_ promise: MailPromised) -> String {
        // Said on a site to a channel: no one's name to put in for "you".
        let name = promise.person.isEmpty && !promise.address.contains("@") ? "" : first(promise.person, promise.address)
        var words = promise.quote.replacingOccurrences(of: "’", with: "'")
        // Up to the promise: what comes before "I'll" is a greeting or a reason.
        let leads = ["I'll ", "I will ", "I'm going to ", "I am going to ", "We'll ", "We will ", "Will ", "Let me ", "I can ",
                     "i'll ", "i will ", "we'll ", "we will ", "will ", "let me ", "You'll have ", "you'll have ", "You will have ",
                     "You'll get ", "you'll get "]
        var thing = ""
        var gives = false
        for lead in leads {
            if let range = words.range(of: lead) {
                thing = String(words[range.upperBound...])
                gives = lead.lowercased().hasPrefix("you")
                break
            }
        }
        if thing.isEmpty { return fallback(promise, name) }
        words = thing
        // The day it names is the row's end, not its title.
        let days = #"\s*(,\s*)?\b(by|on|before|until|till|at|first thing|later|sometime)?\s*(tonight|today|tomorrow( morning)?|this (week|evening|afternoon|morning)|next week|early next week|end of (the )?(day|week|month)|eod|eow|(next )?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)|noon|\d{1,2}(:\d{2})?\s?(am|pm)|\d{1,2}:\d{2}|in (a couple of|a few|\d+) days)\b"#
        words = words.replacingOccurrences(of: days, with: "", options: [.regularExpression, .caseInsensitive])
        words = words.trimmingCharacters(in: CharacterSet(charactersIn: " .,!;:")).replacingOccurrences(of: "  ", with: " ")
        guard !words.isEmpty else { return fallback(promise, name) }
        if promise.theirs {
            // "I'll send you the contract" from Dana: what Dana owes you.
            let owed = words.replacingOccurrences(of: #"^(send|get|share|forward|have|bring|drop)( (you|over))?\s+"#, with: "",
                                                  options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+(and\s+)?(back\s+)?(to|over to) you$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"^(it|this|that)( over)?$"#, with: "an answer", options: [.regularExpression, .caseInsensitive])
            return clip("\(name) owes you " + (owed.isEmpty || owed == words && promise.kind == .word ? "an answer" : owed))
        }
        if gives {
            // "You'll have the numbers by Friday": send them the numbers.
            return clip(name.isEmpty ? "Send " + words : "Send \(name) " + words)
        }
        // "send you the deck": "send Olya the deck"; "intro you to Kenji": "Introduce Olya to Kenji".
        // To a channel: "share the deck with you" is "share the deck".
        words = name.isEmpty ? words.replacingOccurrences(of: #"\s*\b((with|to|for) )?you\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            : words.replacingOccurrences(of: #"\byou\b"#, with: name, options: .regularExpression)
        words = words.replacingOccurrences(of: #"^intro\b"#, with: "introduce", options: [.regularExpression, .caseInsensitive])
        words = words.replacingOccurrences(of: #"\byour\b"#, with: name + "'s", options: .regularExpression)
        return clip(words.prefix(1).uppercased() + words.dropFirst())
    }

    nonisolated private static func fallback(_ promise: MailPromised, _ name: String) -> String {
        if promise.theirs { return "\(name) owes you an answer" }
        switch promise.kind {
        case .file: return "Send \(name) what you promised"
        case .intro: return "Make the intro for \(name)"
        case .word: return "Get back to \(name)"
        }
    }

    nonisolated private static func clip(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    // MARK: - where it stands, in words

    /// Its end in the field, in a word or two: "Due today", "In 40m",
    /// "2 days late", "This week", "4 days ago". Calendar days, never a
    /// countdown to a time nobody said.
    nonisolated static func status(_ promise: MailPromised, now: Date, calendar: Calendar = .current) -> String {
        let words = Self.words(promise, now: now, calendar: calendar)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The same words as the detail starts with: "due today", "in 40m".
    nonisolated static func words(_ promise: MailPromised, now: Date, calendar: Calendar = .current) -> String {
        guard let due = promise.due else {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: promise.at), to: calendar.startOfDay(for: now)).day ?? 0
            return days < 1 ? "said today" : days == 1 ? "said yesterday" : "\(days) days ago"
        }
        let today = calendar.isDate(due, inSameDayAs: now)
        if promise.timed && due > now, let until = Hints.until(due, now: now) { return until }
        if due < now && !today {
            let late = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: now)).day ?? 1
            return late <= 1 ? "1 day late" : late >= 7 ? "a week late" : "\(late) days late"
        }
        if today {
            if promise.timed && due <= now { return "late" }
            let hour = calendar.component(.hour, from: due)
            return hour >= 20 ? "due tonight" : hour < 12 && !promise.timed ? "due this morning" : "due today"
        }
        if promise.soft { return "this week" }
        if calendar.isDate(due, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) { return "due tomorrow" }
        if due.timeIntervalSince(now) < 6 * 86_400 { return "due " + due.formatted(AppDates.dateTime.weekday(.abbreviated)) }
        return "due " + due.formatted(AppDates.dateTime.month(.abbreviated).day())
    }

    // MARK: - the budget (anti-nag)

    /// What a promise's row has been through: the days it stood in the
    /// field, when it was last dealt with, a nudge, a later.
    struct Seen: Codable, Equatable {
        /// Days ("2026-10-15") it stood in the field's two rows.
        var days: [String] = []
        /// Opened, done, handed to the agent or put off: dealt with.
        var acted: Double? = nil
        /// A nudge sent or written: their move for three days.
        var nudged: Double? = nil
        /// Put off until then.
        var until: Double? = nil

        /// Not a row now: put off, or nudged in the last three days.
        func away(now: Date) -> Bool {
            if let until, now.timeIntervalSince1970 < until { return true }
            if let nudged, now.timeIntervalSince1970 - nudged < 3 * 86_400 { return true }
            return false
        }

        /// Stood in the field three days or more since it was last dealt
        /// with: the field leaves it be, Show All asks "Still on?".
        func ignored(now: Date) -> Bool {
            let since = acted.map { Promises.day(Date(timeIntervalSince1970: $0)) } ?? ""
            return days.filter { $0 > since }.count >= 3
        }
    }

    nonisolated static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private(set) var attention: [String: Seen] {
        get { Store.settings.data(forKey: "promises.attention").flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:] }
        set {
            // A month is plenty: what is older is gone or history.
            let cut = Promises.day(Hints.now.addingTimeInterval(-30 * 86_400))
            let kept = newValue.filter { _, seen in
                (seen.days.last ?? "") >= cut || (seen.acted ?? 0) > Hints.now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
            }
            Store.settings.set(try? JSONEncoder().encode(kept), forKey: "promises.attention")
        }
    }

    /// When a promise row of any kind was last dealt with.
    private var lastActed: Double {
        get { Store.settings.double(forKey: "promises.acted") }
        set { Store.settings.set(newValue, forKey: "promises.acted") }
    }

    /// The field put these promise rows in its two rows today.
    func stood(_ ids: [String], now: Date) {
        guard !ids.isEmpty else { return }
        var all = attention
        let today = Promises.day(now)
        var changed = false
        for id in ids where !(all[id]?.days.contains(today) ?? false) {
            all[id, default: Seen()].days.append(today)
            changed = true
        }
        if changed { attention = all }
    }

    /// Dealt with by hand: opened, done, handed over, put off.
    func acted(_ id: String, now: Date? = nil) {
        let now = now ?? Hints.now
        var all = attention
        all[id, default: Seen()].acted = now.timeIntervalSince1970
        attention = all
        lastActed = now.timeIntervalSince1970
    }

    func nudged(_ id: String, now: Date? = nil) {
        let now = now ?? Hints.now
        var all = attention
        all[id, default: Seen()].nudged = now.timeIntervalSince1970
        all[id, default: Seen()].acted = now.timeIntervalSince1970
        attention = all
        lastActed = now.timeIntervalSince1970
    }

    func putOff(_ id: String, until: Date) {
        var all = attention
        all[id, default: Seen()].until = until.timeIntervalSince1970
        all[id, default: Seen()].acted = Hints.now.timeIntervalSince1970
        attention = all
        lastActed = Hints.now.timeIntervalSince1970
    }

    /// Which promise rows may stand in the field's two rows now: not one
    /// that sat there three days untouched, not a third different one
    /// today, and none while the whole of it has gone unused (rows stood on
    /// five days or more in the last two weeks and none was dealt with).
    func mayStand(now: Date) -> (String) -> Bool {
        let all = attention
        let today = Promises.day(now)
        let todays = Set(all.filter { $0.value.days.contains(today) }.map(\.key))
        let twoWeeks = Promises.day(now.addingTimeInterval(-14 * 86_400))
        let days = Set(all.values.flatMap { $0.days.filter { $0 >= twoWeeks } })
        let dormant = days.count >= 5 && lastActed < now.addingTimeInterval(-14 * 86_400).timeIntervalSince1970
        return { id in
            guard !dormant else { return false }
            if all[id]?.ignored(now: now) == true { return false }
            return todays.contains(id) || todays.count < 2
        }
    }

    // MARK: - not a promise

    /// Sentences said not to be promises, by their shape: never read as one
    /// again, here or anywhere.
    private var notSaid: Set<String> {
        Set(Store.settings.stringArray(forKey: "promises.not") ?? [])
    }

    /// A sentence's shape: lowercased, names and numbers out.
    nonisolated static func fingerprint(_ quote: String) -> String {
        quote.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}# ]"#, with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// Not a promise: closed for good, its shape remembered.
    func notAPromise(_ hint: Hint) {
        if let quote = hint.quote {
            var list = Store.settings.stringArray(forKey: "promises.not") ?? []
            let print = Promises.fingerprint(quote)
            if !list.contains(print) { list.append(print) }
            Store.settings.set(Array(list.suffix(300)), forKey: "promises.not")
        }
        set(hint, state: .not)
        acted(hint.id)
        Hints.shared.compose()
    }

    /// Done by hand: kept for good, here and in Mail's list.
    func done(_ hint: Hint) {
        set(hint, state: .done)
        acted(hint.id)
        Hints.shared.compose()
    }

    /// Every open promise behind a row (one row a thread) put in a state.
    private func set(_ hint: Hint, state: MailPromised.State) {
        if hint.id.contains(".web.") {
            var all = web
            for index in all.indices where all[index].id == hint.id { all[index].promise.state = state }
            web = all
            return
        }
        guard let (account, thread) = Hints.mailThread(hint.url).map({ ($0.account, $0.thread) }) else { return }
        let theirs = hint.id.hasPrefix("promise.theirs.")
        testing.removeAll { $0.account == account && $0.promise.thread == thread && $0.promise.theirs == theirs }
        guard let store = MailCenter.shared.engines[account]?.store else { return }
        for promise in store.promises(states: [.open, .judgment]) where promise.thread == thread && promise.theirs == theirs {
            store.setPromise(promise, state: state)
        }
    }

    // MARK: - said on sites

    /// Promises said on sites (what you sent, and what notifications brought
    /// you), kept on this Mac: the sentence, the place and its link, never
    /// the rest of a message. A month at most, three hundred at most.
    private(set) var web: [Item] {
        get {
            (Store.settings.data(forKey: "promises.web").flatMap { try? JSONDecoder().decode([Said].self, from: $0) } ?? []).map(\.item)
        }
        set {
            let cut = Hints.now.addingTimeInterval(-30 * 86_400)
            let kept = newValue.filter { $0.promise.at > cut }.suffix(300).map(Said.init)
            Store.settings.set(try? JSONEncoder().encode(Array(kept)), forKey: "promises.web")
        }
    }

    /// One promise said on a site, as kept.
    struct Said: Codable {
        var id: String, quote: String, person: String, address: String, kind: String, due: Double?, at: Double, state: String
        var theirs: Bool, soft: Bool, timed: Bool, page: String, source: String, place: String
        var heard: Bool? = nil

        init(_ item: Item) {
            let p = item.promise
            id = p.message; quote = p.quote; person = p.person; address = p.address; kind = p.kind.rawValue
            due = p.due?.timeIntervalSince1970; at = p.at.timeIntervalSince1970; state = p.state.rawValue
            theirs = p.theirs; soft = p.soft; timed = p.timed
            page = item.page?.absoluteString ?? ""; source = item.source ?? ""; place = p.thread
            heard = item.heard ? true : nil
        }

        var item: Item {
            let promise = MailPromised(message: id, thread: place, quote: quote, person: person, address: address,
                                       kind: MailPromised.Kind(rawValue: kind) ?? .word, due: due.map(Date.init(timeIntervalSince1970:)),
                                       at: Date(timeIntervalSince1970: at), state: MailPromised.State(rawValue: state) ?? .open,
                                       theirs: theirs, soft: soft, timed: timed)
            return Item(promise: promise, account: "web", heard: heard == true, page: URL(string: page), source: source.isEmpty ? nil : source)
        }
    }

    /// A site's name for a row's end: "Slack", "Linear", "GitHub".
    nonisolated static func site(_ host: String) -> String {
        let known = ["slack.com": "Slack", "linear.app": "Linear", "github.com": "GitHub", "notion.so": "Notion",
                     "docs.google.com": "Docs", "web.telegram.org": "Telegram", "web.whatsapp.com": "WhatsApp",
                     "discord.com": "Discord", "x.com": "X", "linkedin.com": "LinkedIn", "teams.microsoft.com": "Teams",
                     "figma.com": "Figma", "app.slack.com": "Slack", "mail.google.com": "Gmail"]
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // An address by its numbers (a page served on this Mac): as it is.
        if bare.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return bare }
        if let name = known[bare] { return name }
        if let name = known.first(where: { bare.hasSuffix("." + $0.key) })?.value { return name }
        let main = bare.split(separator: ".").dropLast().last.map(String.init) ?? bare
        return main.prefix(1).uppercased() + main.dropFirst()
    }

    /// The place a page is, for one row a place and for keeping: the
    /// site and its path (a channel, an issue, a pull request).
    nonisolated static func place(_ url: URL) -> String {
        (url.host() ?? "") + url.path()
    }

    /// A message you sent from a site's composer (sent.js): its promises
    /// kept, and the promises said there before it kept by it: a link or a
    /// file for a thing, any message for words.
    func sent(_ body: [String: Any], in tab: Tab) {
        guard Noticing.shared.promisesOn, let url = (body["url"] as? String).flatMap(URL.init(string:)) ?? tab.address,
              let host = url.host() else { return }
        let now = Hints.now
        let place = Promises.place(url)
        let carried = body["link"] as? Bool == true || body["file"] as? Bool == true
        var all = web
        var changed = false
        // What this message keeps of what was said here before.
        for index in all.indices where !all[index].promise.theirs && all[index].promise.thread == place
            && (all[index].promise.state == .open || all[index].promise.state == .judgment)
            && now.timeIntervalSince(all[index].promise.at) > 120 {
            if all[index].promise.kind == .word || carried {
                all[index].promise.state = .done
                changed = true
            }
        }
        let not = notSaid
        for sentence in body["said"] as? [String] ?? [] where !not.contains(Promises.fingerprint(sentence)) {
            guard let read = MailPromise.reading(sentence) else { continue }
            let due = MailPromise.when(in: sentence, at: now)
            let quote = sentence.count > 140 ? String(sentence.prefix(139)) + "…" : sentence
            let promise = MailPromised(message: UUID().uuidString, thread: place, quote: quote, person: "", address: host,
                                       kind: read.kind, due: due?.date, at: now, state: read.judgment ? .judgment : .open,
                                       soft: due?.soft ?? false, timed: due?.timed ?? false)
            all.append(Item(promise: promise, account: "web", page: url, source: Promises.site(host)))
            changed = true
        }
        if changed {
            web = all
            Hints.shared.compose()
        }
    }

    /// A site's notification: a promise someone made you in it ("I'll send
    /// the contract by Monday"), kept as theirs, the sender from its title.
    func heard(origin: URL, title: String, body: String) {
        guard Noticing.shared.promisesOn, let host = origin.host() else { return }
        let now = Hints.now
        let not = notSaid
        // "Dana Lee", "#design: Dana Lee", "Dana Lee (Slack)": the person.
        let person = title.components(separatedBy: ":").last?.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) ?? ""
        var all = web
        var changed = false
        // Anything from them here keeps quiet what they owe: they spoke up.
        for index in all.indices where all[index].promise.theirs && all[index].promise.person == person
            && all[index].promise.address == host && (all[index].promise.due.map { $0 < now } ?? false) {
            all[index].heard = true
            changed = true
        }
        for sentence in MailPromise.sentences(body) where !not.contains(Promises.fingerprint(sentence)) {
            guard !person.isEmpty, let read = MailPromise.theirReading(sentence) else { continue }
            let due = MailPromise.when(in: sentence, at: now)
            let promise = MailPromised(message: UUID().uuidString, thread: host + ":" + person, quote: sentence, person: person,
                                       address: host, kind: read.kind, due: due?.date, at: now, state: read.judgment ? .judgment : .open,
                                       theirs: true, soft: due?.soft ?? false, timed: due?.timed ?? false)
            all.append(Item(promise: promise, account: "web", page: origin, source: Promises.site(host)))
            changed = true
        }
        if changed {
            web = all
            Hints.shared.compose()
        }
    }

    // MARK: - bench

    func state(now: Date) -> [String: Any] {
        let stand = mayStand(now: now)
        let all = items(now: now) + web.filter { $0.promise.state != .open && $0.promise.state != .judgment }
        return ["items": all.map { item -> [String: Any] in
            ["id": item.id, "quote": item.promise.quote, "title": Promises.title(item.promise), "theirs": item.promise.theirs,
             "due": item.promise.due.map { ISO8601DateFormatter().string(from: $0) } ?? "", "window": Promises.due(item, now: now),
             "status": Promises.status(item.promise, now: now), "may": stand(item.id), "state": item.promise.state.rawValue,
             "source": item.source ?? "Mail", "page": item.page?.absoluteString ?? ""]
        }, "attention": attention.mapValues { ["days": $0.days, "acted": $0.acted ?? 0] }]
    }

    /// A test world starts over.
    func forget() {
        Store.settings.removeObject(forKey: "promises.attention")
        Store.settings.removeObject(forKey: "promises.acted")
        Store.settings.removeObject(forKey: "promises.not")
        Store.settings.removeObject(forKey: "promises.web")
        testing = []
    }
}

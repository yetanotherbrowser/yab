import Foundation

// Promises (docs/promises.md): what you promised in your own mail and what
// people promised you in theirs. Waiting is what you asked and nobody
// answered; a promise is a thing someone said they would do, for someone,
// in the first person and the future ("I'll send them by Friday", "Will
// intro you to Kenji tomorrow"), never a question, a plan ("I'll be in
// Berlin"), a wish ("we should grab coffee"), a maybe ("I'll try to") or a
// condition ("if you send the logo, I'll…"). Read on this Mac by rules
// alone; strict on the way in, since a row that isn't a promise costs more
// than one missed. Kept against the mail that said it, and closed by what
// came after in the thread from whoever promised: a file when a file was
// promised, a new person on the mail when an intro was, any mail
// otherwise; a later promise in the thread moves the one before it.

public struct MailPromised: Equatable, Sendable {
    /// What was promised: a file (numbers, a deck), an introduction, or
    /// words (a reply, a look).
    public enum Kind: String, Sendable { case file, intro, word }
    /// Open; done (closed by mail, or by hand); moved (a later promise in
    /// the thread took its place); a judgment call ("let me think about
    /// it"), shown only after a few days; not (said not to be a promise).
    public enum State: String, Sendable { case open, done, moved, judgment, not }

    /// The mail that said it, and which of its promises.
    public var message: String
    public var n: Int = 0
    public var thread: String
    /// The sentence, as it was written.
    public var quote: String
    /// Whom it was to (yours) or who said it (theirs).
    public var person: String
    public var address: String
    public var kind: Kind
    public var due: Date?
    /// When it was said.
    public var at: Date
    public var state: State = .open
    /// Said by them to you, not by you.
    public var theirs = false
    /// A span, not a day: "this week", "next week". Late from its end.
    public var soft = false
    /// A time of day was written ("by 11:30", "at 3pm").
    public var timed = false

    public init(message: String, n: Int = 0, thread: String, quote: String, person: String, address: String, kind: Kind,
                due: Date? = nil, at: Date, state: State = .open, theirs: Bool = false, soft: Bool = false, timed: Bool = false) {
        self.message = message
        self.n = n
        self.thread = thread
        self.quote = quote
        self.person = person
        self.address = address
        self.kind = kind
        self.due = due
        self.at = at
        self.state = state
        self.theirs = theirs
        self.soft = soft
        self.timed = timed
    }
}

public enum MailPromise {
    /// The list's id in the column, beside Waiting.
    public static let list = "promised"
    /// How far back mail is read.
    public static let days: TimeInterval = 14 * 86_400
    /// A judgment call is said only once this old.
    static let judgmentAfter: TimeInterval = 3 * 86_400

    // MARK: - reading a sentence

    /// Words split into sentences, short ones kept whole.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in flat.components(separatedBy: "\n") {
            var current = ""
            for char in line {
                current.append(char)
                if ".!?".contains(char) {
                    let one = current.trimmingCharacters(in: .whitespaces)
                    if !one.isEmpty { out.append(one) }
                    current = ""
                }
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { out.append(rest) }
        }
        return out
    }

    private static let starts = [
        "i'll ", "i will ", "i'm going to ", "i am going to ", "i shall ", "we'll ", "we will ",
        "will send", "will share", "will get ", "will follow up", "will intro", "will introduce", "will forward", "will loop",
        "will circle back", "will reply", "will review", "will update", "will have ", "will fix", "will finish", "will write",
        "let me send", "let me share", "let me check", "let me get back", "let me follow up", "let me look", "let me find",
        "let me dig", "let me loop", "let me think",
        "you'll have ", "you will have ", "you'll get ", "you will get ",
    ]
    /// Plans, nothing owed: being somewhere, having to, needing.
    private static let plans = ["i'll be ", "i will be ", "we'll be ", "we will be ", "i'll have to ", "i'll need ", "we'll need ",
                                "i'll miss ", "i'll pass", "i'll take that as", "will be out", "be out of office", "out of the office",
                                "keep this brief", "keep it brief", "keep this short", "keep it short", "we will need", "leave you be",
                                "take you off", "disappear", "stop reaching out", "won't bother", "make like"]
    /// Words that ask, or hang the promise on someone else.
    private static let asking = ["let me know", "if you ", "would you", "could you", "can you", "will you", "do you", "once you ",
                                 "when you ", "after you ", "unless ", "as soon as you", "if we ", "if i ", "if it ", "if they ",
                                 "if that", "if this", "provided ", "assuming ", "reply \"", "reply with", "reply and",
                                 "just reply", "reply yes", "reply no", "reply stop", "write back", "say the word", "if so", "if you'd", "if you're", "if interested",
                                 "would like", "interested"]
    /// A maybe is not a promise: "I'll try", "hopefully", "probably".
    private static let maybes = ["try to", "i'll try", "will try", "trying to", "hopefully", "hope to", "maybe", "probably", "might ",
                                 "should be able", "if possible", "if i can", "when i can", "at some point", "sometime", "some time",
                                 "one day", "eventually", "we'll see", "no promises", "not sure", "i think i'll", "possibly"]
    /// Saying no, or that it can't be done.
    private static let refusals = ["won't", "will not", "can't", "cannot", "unable", "not going to", "never ", "don't think"]
    /// What a company sends, said as a promise: a code, a receipt, a shipment.
    private static let robots = ["you'll receive", "you will receive", "we'll email you", "we will email you", "we'll notify",
                                 "we will notify", "will be shipped", "will be delivered", "verification code", "your order",
                                 "your subscription", "your account", "unsubscribe", "this email", "reply to this"]

    /// A sentence that promises something; nil, none. A judgment call when
    /// it promises no thing and names no day.
    public static func reading(_ sentence: String) -> (kind: MailPromised.Kind, judgment: Bool)? {
        let lower = " " + plain(sentence)
        guard !lower.hasSuffix("?"), lower.count < 260 else { return nil }
        for words in [asking, plans, maybes, refusals, robots] where words.contains(where: lower.contains) { return nil }
        guard starts.contains(where: { lower.contains(" " + $0) }) else { return nil }
        let kind = kind(lower)
        let vague = ["get back to you", "think about", "think it over", "circle back", "look into"].contains(where: lower.contains)
        return (kind, vague && kind == .word)
    }

    /// A sentence lowercased, its curly quotes straight, for the word lists.
    static func plain(_ sentence: String) -> String {
        sentence.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespaces)
    }

    public static func kind(_ lower: String) -> MailPromised.Kind {
        if ["intro ", "introduce", "connect you", "put you in touch"].contains(where: lower.contains) { return .intro }
        let sending = ["send", "share", "forward", "attach", "you'll have", "you will have", "you'll get", "you will get", "get you ",
                       "get the ", "back to you", "bring", "deliver"].contains(where: lower.contains)
        let thing = ["deck", "number", "file", "doc", "pdf", "notes", "slides", "invoice", "contract", "link", "draft", "sheet",
                     "figures", "report", "logo", "design", "mock", "proposal", "quote", "estimate", "recording", "screenshot",
                     "them", "it over"]
            .contains(where: lower.contains)
        return sending && thing ? .file : .word
    }

    /// Whether a sentence of theirs promises something to you: their own
    /// words, the first person, and you in it ("I'll send you the contract
    /// Monday", "You'll have it by Friday"), or a thing for you.
    public static func theirReading(_ sentence: String) -> (kind: MailPromised.Kind, judgment: Bool)? {
        guard let read = reading(sentence) else { return nil }
        let lower = " " + plain(sentence)
        let toYou = [" you", " your"].contains(where: lower.contains)
        guard toYou || read.kind != .word else { return nil }
        return read
    }

    // MARK: - the day it names

    /// The day a promise names, and how: a span ("this week"), a time of day.
    public struct Due: Equatable, Sendable {
        public var date: Date
        public var soft = false
        public var timed = false
    }

    /// The day a promise names, from the mail's own date.
    public static func due(in sentence: String, at: Date, calendar: Calendar = .current) -> Date? {
        when(in: sentence, at: at, calendar: calendar)?.date
    }

    /// The day a promise names, from the mail's own date: a time of day,
    /// tonight, today, tomorrow (its morning), a weekday, this week, next
    /// week, the end of the month, in a few days, or a date written out.
    /// A day without a time is due at its end of the working day.
    public static func when(in sentence: String, at: Date, calendar: Calendar = .current) -> Due? {
        let lower = plain(sentence)
        let start = calendar.startOfDay(for: at)
        func day(_ add: Int, hour: Int = 18, minute: Int = 0) -> Date? {
            calendar.date(byAdding: DateComponents(day: add, hour: hour, minute: minute), to: start)
        }
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let weekday = calendar.component(.weekday, from: start)
        // The day it falls on, before a time of day is read.
        var offset: Int? = nil
        var soft = false
        var hour = 18
        if has(#"\b(tonight|this evening)\b"#) { offset = 0; hour = 21 }
        else if has(#"\b(today|eod|end of (the )?day|this afternoon|this morning)\b"#) { offset = 0 }
        else if has(#"\b(day after tomorrow)\b"#) { offset = 2 }
        else if has(#"\btomorrow morning\b"#) { offset = 1; hour = 10 }
        else if has(#"\b(tomorrow|tmrw|tmr)\b"#) { offset = 1 }
        else if has(#"\bearly next week\b"#) { offset = (3 - weekday + 7) % 7 + 7; soft = true }
        else if has(#"\b(next week)\b"#) { offset = (6 - weekday + 7) % 7 + 7; soft = true }
        else if has(#"\b(end of (the )?week|this week|eow|by the weekend)\b"#) {
            offset = weekday == 7 || weekday == 1 ? (6 - weekday + 7) % 7 + 7 : (6 - weekday + 7) % 7; soft = true
        } else if has(#"\b(end of (the )?month|eom)\b"#) {
            let range = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            offset = range - calendar.component(.day, from: start); soft = true
        } else if let match = lower.range(of: #"\bin (\d{1,2}|a couple of|a few|two|three) days\b"#, options: .regularExpression) {
            let said = String(lower[match])
            let n = Int(said.filter(\.isNumber)) ?? (said.contains("couple") || said.contains("two") ? 2 : 3)
            offset = n; soft = !said.contains(where: \.isNumber)
        } else {
            let names: [(String, Int)] = [("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6),
                                          ("saturday", 7)]
            if let (_, wanted) = names.first(where: { has(#"\b"# + $0.0 + #"\b"#) }) {
                var ahead = (wanted - weekday + 7) % 7
                // The same day: today while it is still early, else next week's.
                if ahead == 0, calendar.component(.hour, from: at) >= 15 { ahead = 7 }
                if has(#"\bnext "# + names.first(where: { $0.1 == wanted })!.0) && ahead < 7 && ahead <= 2 { ahead += 7 }
                offset = ahead
            }
        }
        // A time of day written out: "by 11:30", "at 3pm", "by noon".
        var timed = false
        var minute = 0
        if let match = lower.range(of: #"\b(\d{1,2})(:(\d{2}))?\s?(am|pm)\b|\b(\d{1,2}):(\d{2})\b|\bnoon\b"#, options: .regularExpression) {
            let said = String(lower[match])
            if said == "noon" { hour = 12 } else {
                let digits = said.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if var h = digits.first, h <= 23 {
                    if said.hasSuffix("pm"), h < 12 { h += 12 }
                    if said.hasSuffix("am"), h == 12 { h = 0 }
                    hour = h
                    minute = digits.count > 1 ? min(59, digits[1]) : 0
                }
            }
            timed = true
            if offset == nil {
                // A time with no day: today, unless it has gone.
                offset = 0
                if let today = day(0, hour: hour, minute: minute), today < at { offset = 1 }
            }
        }
        if let offset, let date = day(offset, hour: hour, minute: minute) {
            return Due(date: date, soft: soft && !timed, timed: timed)
        }
        // A date written out ("by Oct 3"): the detector's own reading. "Before
        // Jan 4" it reads as a span from now to that day: the day is its end.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)),
           let found = match.date {
            let end = found.addingTimeInterval(max(0, match.duration))
            // A day the detector gave midnight means a day: its working end.
            let hourOf = calendar.component(.hour, from: end), minuteOf = calendar.component(.minute, from: end)
            let date = hourOf == 0 && minuteOf == 0 ? (calendar.date(byAdding: .hour, value: 18, to: calendar.startOfDay(for: end)) ?? end) : end
            if date > at.addingTimeInterval(-86_400), date < at.addingTimeInterval(60 * 86_400) { return Due(date: date) }
        }
        return nil
    }

    // MARK: - a mail

    /// The promises one mail of yours makes, in its own words (not the mail
    /// it quotes), to whom it says: a name it starts with, the one person
    /// it goes to, or the last one who wrote before it in the thread.
    public static func promises(in message: MailMessage, before: MailPerson? = nil) -> [MailPromised] {
        let words = message.text.map(MailSense.own) ?? MailSense.unquoted(message.snippet)
        let people = message.to + message.cc
        var out: [MailPromised] = []
        for sentence in sentences(words) {
            guard let read = reading(sentence) else { continue }
            let to = addressee(sentence, people: people, to: message.to, before: before)
            out.append(promised(sentence, read: read, message: message, n: out.count, person: to))
        }
        return out
    }

    /// The promises a mail of theirs makes to you, in their own words.
    public static func theirPromises(in message: MailMessage) -> [MailPromised] {
        let words = message.text.map(MailSense.own) ?? MailSense.unquoted(message.snippet)
        var out: [MailPromised] = []
        for sentence in sentences(words) {
            guard let read = theirReading(sentence) else { continue }
            var one = promised(sentence, read: read, message: message, n: out.count, person: message.from)
            one.theirs = true
            out.append(one)
        }
        return out
    }

    private static func promised(_ sentence: String, read: (kind: MailPromised.Kind, judgment: Bool), message: MailMessage, n: Int,
                                 person: MailPerson?) -> MailPromised {
        let quote = sentence.count > 140 ? String(sentence.prefix(139)) + "…" : sentence
        let due = when(in: sentence, at: message.date)
        return MailPromised(message: message.id, n: n, thread: message.thread, quote: quote, person: person?.said ?? "",
                            address: person?.address.lowercased() ?? "", kind: read.kind, due: due?.date, at: message.date,
                            state: read.judgment ? .judgment : .open, soft: due?.soft ?? false, timed: due?.timed ?? false)
    }

    /// Whom a sentence of yours is to: a recipient it names first ("Mark,
    /// I'll send…"), the one person the mail goes to, or the last one who
    /// wrote before it; the first recipient otherwise.
    static func addressee(_ sentence: String, people: [MailPerson], to: [MailPerson], before: MailPerson?) -> MailPerson? {
        let lower = plain(sentence)
        if let named = people.first(where: { person in
            let first = person.said.split(separator: " ").first.map { $0.lowercased() } ?? ""
            return first.count > 1 && (lower.hasPrefix(first + ",") || lower.hasPrefix(first + " ") || lower.contains(" " + first + ","))
        }) { return named }
        if to.count == 1 { return to[0] }
        if let before, people.contains(where: { $0.address.lowercased() == before.address.lowercased() }) { return before }
        return to.first
    }

    /// Whether what came after in its thread from whoever promised keeps a
    /// promise: a file for a file, a new person for an intro, any mail for
    /// words.
    public static func kept(_ promise: MailPromised, by later: [MailMessage], before people: Set<String>) -> Bool {
        let after = later.filter { $0.date > promise.at && $0.id != promise.message }
        switch promise.kind {
        case .file: return after.contains { ($0.files?.contains { !$0.inline } ?? false) || $0.attached == true || carries($0) }
        case .intro: return after.contains { mail in (mail.to + mail.cc).contains { !people.contains($0.address.lowercased()) } }
        case .word: return !after.isEmpty
        }
    }

    /// What was promised brought in the words themselves: numbers ("48,210",
    /// "$61.4k") or a link, in the mail's own words, not the mail it quotes.
    static func carries(_ mail: MailMessage) -> Bool {
        let own = mail.text.map(MailSense.own) ?? MailSense.unquoted(mail.snippet)
        if own.range(of: #"https?://"#, options: .regularExpression) != nil { return true }
        return own.range(of: #"\d{1,3}(,\d{3})+|\d+\.\d+|\$\s?\d|\d+\s?%|\d{3,}"#, options: .regularExpression) != nil
    }

    // MARK: - a store

    /// Mail of the last two weeks read again: new promises kept, open ones
    /// closed by what came after, a later promise in a thread moving the one
    /// before. Yours from Sent; theirs from people's mail in the inbox, never
    /// a list's or a robot's. Whether anything changed.
    @discardableResult
    public static func run(_ store: MailStore, now: Date = Date()) -> Bool {
        let me = store.me.lowercased()
        guard !me.isEmpty else { return false }
        let since = now.addingTimeInterval(-days)
        var found: [MailPromised] = []
        var byThread: [String: [MailMessage]] = [:]
        var seen = Set<String>()
        for thread in store.threads(label: "SENT", limit: 200) + store.threads(label: "INBOX", limit: 200)
        where thread.last > since && seen.insert(thread.id).inserted {
            let messages = store.messages(thread: thread.id).sorted { $0.date < $1.date }
            byThread[thread.id] = messages
            var last: MailPerson? = nil
            let conversation = messages.contains { $0.from.address.lowercased() == me }
            for message in messages {
                let from = message.from.address.lowercased()
                if from == me {
                    if message.date > since { found += promises(in: message, before: last) }
                } else {
                    last = message.from
                    // Theirs only in a conversation of yours: you wrote in the
                    // thread before they promised. A cold sequence's "reply yes
                    // and I'll send…" and a company's terms are no promises to you.
                    guard message.date > since, !message.labels.contains("SPAM"), conversation,
                          messages.contains(where: { $0.from.address.lowercased() == me && $0.date < message.date }),
                          MailSense.kind(message, bulk: message.listUnsubscribe, conversation: conversation) == .person else { continue }
                    found += theirPromises(in: message)
                }
            }
        }
        var changed = store.keepPromises(found)
        for promise in store.promises(states: [.open, .judgment]) {
            guard let messages = byThread[promise.thread] else { continue }
            // A later promise in the thread, from the same side, takes its place.
            if found.contains(where: { $0.thread == promise.thread && $0.theirs == promise.theirs && $0.at > promise.at }) {
                changed = store.setPromise(promise, state: .moved) || changed
                continue
            }
            let side = messages.filter { message in
                let from = message.from.address.lowercased()
                return promise.theirs ? from == promise.address : from == me
            }
            // What was in the thread before the promise: an intro adds someone new.
            let before = Set(messages.filter { $0.date <= promise.at }.flatMap { [$0.from] + $0.to + $0.cc }.map { $0.address.lowercased() })
            if kept(promise, by: side, before: before) {
                changed = store.setPromise(promise, state: .done) || changed
            }
        }
        return changed
    }

    /// The open ones a list shows, soonest due first, then oldest: a
    /// judgment call once it is a few days old. Yours unless `theirs`.
    public static func open(in store: MailStore, now: Date = Date(), theirs: Bool = false) -> [MailPromised] {
        store.promises(states: [.open, .judgment])
            .filter { $0.theirs == theirs && ($0.state == .open || now.timeIntervalSince($0.at) > judgmentAfter) }
            .sorted { ($0.due ?? .distantFuture, $0.at) < ($1.due ?? .distantFuture, $1.at) }
    }

    // MARK: - in words

    /// The list's end: "by Fri", "today", "tonight", "1d late", or how long
    /// ago it was said when it named no day ("5d"). Days are calendar days.
    public static func when(_ promise: MailPromised, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let due = promise.due else {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: promise.at), to: calendar.startOfDay(for: now)).day ?? 0
            return days < 1 ? "today" : "\(days)d"
        }
        let today = calendar.isDate(due, inSameDayAs: now)
        if due < now && !today {
            let late = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: now)).day ?? 1
            return "\(max(1, late))d late"
        }
        if today { return calendar.component(.hour, from: due) >= 20 ? "tonight" : "today" }
        if calendar.isDate(due, inSameDayAs: now.addingTimeInterval(86_400)) { return "by tomorrow" }
        var components = Locale.Components(locale: .current)
        if components.languageComponents.languageCode?.identifier != "en" {
            components.languageComponents.languageCode = .english
            components.languageComponents.script = nil
        }
        let dateTime = Date.FormatStyle.dateTime.locale(Locale(components: components))
        let weekday = due.formatted(dateTime.weekday(.abbreviated))
        return due.timeIntervalSince(now) < 6 * 86_400 ? "by " + weekday : "by " + due.formatted(dateTime.month(.abbreviated).day())
    }

    /// Late: its day has gone.
    public static func late(_ promise: MailPromised, now: Date = Date()) -> Bool {
        promise.due.map { $0 < now && !Calendar.current.isDate($0, inSameDayAs: now) } ?? false
    }
}

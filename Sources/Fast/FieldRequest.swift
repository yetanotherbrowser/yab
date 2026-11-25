import SwiftUI
import AppKit
import MailCore

// Words in the field that read as one thing to do somewhere known: a
// meeting, an issue, a mail, a return, time off, the theme. Experimental
// (Settings › Experimental › Actions in the Field). The field puts a row for
// it on top and, beside the list, what is already known of it and how it
// will be done (docs/field-requests.md). Nothing here is guessed: a value
// comes from the words, the mail, the calendar, the history or the open
// tabs, and what only the site knows says so.

/// One thing to do, read from the words.
struct FieldRequest {
    static let key = "experimental.requests"

    /// How it is done, said before Return: at once by Yab, the site's own
    /// form opened filled in, or the agent in tabs of its own.
    enum Route: Equatable {
        case yab, api, link, agent, ask

        /// The row's end, as a row says what kind it is.
        var word: String {
            switch self {
            case .yab: "Yab"
            case .api: "Mail"
            case .link: "Opens Filled In"
            case .agent: "Task"
            case .ask: "Answer"
            }
        }

        /// Under the preview: what happens after Return, and how long.
        var how: String {
            switch self {
            case .yab: "Yab does it at once."
            case .api: "Through your mail or this Mac's calendar, about a second."
            case .link: "Opens the site’s own form filled in. Its last button is yours."
            case .agent: "A task in tabs of its own, a folder in Today. It asks you only to sign in, to pay, or if the words read two ways."
            case .ask: "Nothing changes: Return copies it."
            }
        }
    }

    struct Field: Equatable, Identifiable {
        enum State: Equatable {
            /// Known, and where from.
            case known
            /// Only the site knows: the agent reads it there first.
            case check
            /// Yours to pick, on the site or in the words.
            case choose
            /// Known, but the words fit another one too.
            case doubt(String)
        }
        let label: String
        let value: String
        var source = ""
        var state = State.known
        var id: String { label }
    }

    /// What Return does.
    enum Act {
        case look(Look)
        case pin(UUID)
        case open(URL)
        case task(String)
        /// Anything else Yab does itself, done to the window.
        case perform(@MainActor (Browser) -> Void)
        /// An answer: Return copies it.
        case copy(String)
    }

    let title: String
    let site: String
    let symbol: String
    let tint: NSColor
    let route: Route
    var fields: [Field]
    var plan: [String] = []
    let button: String
    var act: Act
    /// The agent's part of the prompt: the site and what is known.
    var taskNote: String?
    /// Said under the preview when a model read the words (RequestModel).
    var readBy: String?
    /// A picture of it beside the list: a page's last look (Diary).
    var picture: URL?
    /// Found, but read not sure enough to lead: under the row Return takes.
    var under = false
    /// The thing itself, drawn beside the list (FieldRequestObjects).
    var object: RequestObject?

    func with(_ object: RequestObject) -> FieldRequest {
        var copy = self
        copy.object = object
        return copy
    }

    /// Whether there is anything to see beside the list before Return:
    /// values, a plan or a picture. A bare "Theme: Dark" is one row.
    var previewed: Bool { object != nil || !fields.isEmpty || !plan.isEmpty || picture != nil }

    init(title: String, site: String, symbol: String, tint: NSColor, route: Route, fields: [Field], plan: [String] = [],
         button: String, act: Act, taskNote: String? = nil, picture: URL? = nil) {
        self.title = title
        self.site = site
        self.symbol = symbol
        self.tint = tint
        self.route = route
        self.fields = fields
        self.plan = plan
        self.button = button
        self.act = act
        self.taskNote = taskNote
        self.picture = picture
    }

    /// What each window's field shows now, read on every key: one request,
    /// or what was found, best first.
    @MainActor static var shown: [ObjectIdentifier: [FieldRequest]] = [:]
}

// MARK: reading the words

@MainActor
enum RequestReader {
    /// What the words were read as: the kind, and the person and site
    /// picked from your mail and your history, by Jev or by the patterns.
    struct Reading {
        var kind: String
        var person: MailDesk.Contact?
        var host: String?
        /// The site as the words call it, "workday", when the patterns read it.
        var named: String?
        /// Jev's other picks, by question: a tab's id, a page's address, a
        /// thread, a file, a clip, a chat, a space, a setting.
        var picks: [String: String] = [:]
        /// What Yab found for the words before Jev was asked.
        var found = Candidates()
    }

    /// With a key, Jev reads the words once they rest and what it picked
    /// leads; until it answers, and without a key, the patterns read. When
    /// Jev says the words ask for nothing, there is no row.
    static func read(_ text: String, in browser: Browser) -> [FieldRequest] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 4 else { return [] }
        if let read = RequestModel.shared.answer(words) {
            // Jev may pick no site the words still name ("on clerk", out of
            // the dozen it was shown): the words' own then.
            let host = read.host ?? RequestModel.tokens(words).lazy.filter { $0.count >= 4 }.compactMap { History.current.host(named: $0) }.first
            // A setting the words spell out ("compact sidebar"), even when
            // Jev took them for a search: a word of it typed, in a few words.
            var kind = read.kind
            if kind == "none", let setting = read.picks["setting"] {
                let said = Set(Candidates.content(setting)), typed = Set(Candidates.content(words))
                if said.intersection(typed).count >= 1, typed.count <= 4 { kind = "setting" }
            }
            // Not sure enough to lead: no row (Jev answers with how sure);
            // what was found, a little less sure, under the search.
            let finding = kind.hasPrefix("find_") || kind == "open_deep"
            let unsure = read.confidence > 0 && read.confidence < 0.6 && kind == read.kind
            guard kind != "none", !unsure || read.confidence >= (finding ? 0.4 : 0.5) else { return [] }
            let reading = Reading(kind: kind, person: read.person, host: host, picks: read.picks, found: read.found)
            var requests = FieldActions.build(reading, words, browser) ?? build(reading, words, browser).map { [$0] } ?? []
            let model = read.model.replacingOccurrences(of: "typesafe/", with: "")
            for index in requests.indices {
                requests[index].under = unsure
                requests[index].readBy = "Read by \(model) in " + String(format: "%.1f", read.seconds) + " s"
                    + (read.confidence > 0 ? ", \(Int((read.confidence * 100).rounded()))% sure" : "")
            }
            return requests
        }
        RequestModel.shared.ask(words, browser: browser)
        return patterns(words).flatMap { build($0, words, browser) }.map { [$0] } ?? []
    }

    /// The patterns' reading: English words of a few shapes.
    static func patterns(_ words: String) -> Reading? {
        let lower = words.lowercased()
        if ["dark mode", "dark theme", "light mode", "light theme"].contains(lower) {
            return Reading(kind: "theme")
        }
        if lower.hasPrefix("pin ") { return Reading(kind: "pin") }
        if lower.range(of: #"\b(meeting|meet|call|sync|1:1)\b"#, options: .regularExpression) != nil,
           let name = match(#"\bwith ([a-z][a-z'-]+)"#, lower) {
            return Reading(kind: "meeting", person: MailDesk.shared.people(matching: name, limit: 1).first, named: name)
        }
        if lower.range(of: #"^(?:github )?issue "#, options: .regularExpression) != nil { return Reading(kind: "issue") }
        if let name = match(#"^(?:email|write to|mail) ([a-z][a-z'-]+)"#, lower) {
            return Reading(kind: "mail", person: MailDesk.shared.people(matching: name, limit: 1).first, named: name)
        }
        guard let verb = verbs.first(where: { lower.range(of: $0.value.pattern, options: .regularExpression) != nil }),
              let named = match(#"\b(?:on|in|at|from) ([a-z0-9][a-z0-9.-]+)\s*(?:,|$)"#, lower) ?? match(#"\b(?:on|in|at|from) ([a-z0-9][a-z0-9.-]+)\b"#, lower)
        else { return nil }
        return Reading(kind: verb.key, host: History.current.host(named: named), named: named)
    }

    static func build(_ reading: Reading, _ words: String, _ browser: Browser) -> FieldRequest? {
        let lower = words.lowercased()
        switch reading.kind {
        case "theme": return theme(lower)
        case "pin": return pin(lower, browser)
        case "meeting": return meeting(words, lower, reading, browser)
        case "issue": return issue(words, lower)
        case "mail": return mail(words, lower, reading)
        default:
            guard let verb = verbs[reading.kind] else { return nil }
            return task(words, verb, reading)
        }
    }

    // Yab's own

    private static func theme(_ lower: String) -> FieldRequest? {
        let look: Look = lower.contains("light") ? .light : .dark
        return FieldRequest(title: "Theme: \(look.title)", site: "Settings › Appearance", symbol: "circle.lefthalf.filled",
                            tint: .systemPurple, route: .yab, fields: [], button: "Switch to \(look.title)", act: .look(look))
    }

    private static func pin(_ lower: String, _ browser: Browser) -> FieldRequest? {
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !["pin", "tab", "the"].contains($0) }
        guard !words.isEmpty,
              let tab = browser.tabs.first(where: { tab in tab.pin == nil && words.contains { tab.title.lowercased().contains($0) } })
        else { return nil }
        return FieldRequest(title: "Pin \u{201C}\(tab.title)\u{201D}", site: "This window", symbol: "pin", tint: .systemPurple,
                            route: .yab, fields: [], button: "Pin Tab", act: .pin(tab.id))
    }

    // The site's own form, filled in

    private static func meeting(_ words: String, _ lower: String, _ reading: Reading, _ browser: Browser) -> FieldRequest? {
        let named = reading.named?.capitalized
        let guest = reading.person ?? reading.named.flatMap { MailDesk.shared.people(matching: $0, limit: 1).first }
        var fields: [FieldRequest.Field] = []
        let who = guest?.said ?? named ?? "someone"
        if let guest {
            let others = MailDesk.shared.people(matching: guest.said.split(separator: " ").first.map(String.init) ?? guest.said, limit: 3)
                .filter { $0.address != guest.address }.map(\.said)
            fields.append(.init(label: "With", value: guest.said, source: "Mail · \(guest.threads) threads",
                                state: others.isEmpty ? .known : .doubt(others.joined(separator: ", "))))
        } else {
            fields.append(.init(label: "With", value: who, source: "not in your mail", state: .choose))
        }
        let start = when(lower)
        if let start {
            fields.append(.init(label: "When", value: start.formatted(AppDates.dateTime.weekday(.abbreviated).month().day().hour().minute()) + ", 30 min",
                                source: FreeTimes.free(start, browser: browser)))
        } else {
            fields.append(.init(label: "When", value: "pick a time", source: "", state: .choose))
        }
        let topic = match(#"\b(?:about|regarding) (.+)$"#, words)
        if let topic { fields.append(.init(label: "About", value: topic, source: "your words")) }
        var items = [URLQueryItem(name: "text", value: topic.map { "Meeting: \($0)" } ?? "Meeting with \(who)")]
        if let start {
            let form = AppDates.formatter()
            form.dateFormat = "yyyyMMdd'T'HHmmss"
            items.append(URLQueryItem(name: "dates", value: form.string(from: start) + "/" + form.string(from: start.addingTimeInterval(1800))))
            items.append(URLQueryItem(name: "ctz", value: TimeZone.current.identifier))
        }
        if let guest { items.append(URLQueryItem(name: "add", value: guest.address)) }
        var url = URLComponents(string: "https://calendar.google.com/calendar/r/eventedit")!
        url.queryItems = items
        let request = FieldRequest(title: "Meeting with \(who)", site: "Google Calendar", symbol: "calendar",
                                   tint: .systemBlue, route: .link, fields: fields, button: "Open in Calendar", act: .open(url.url!))
        return start.map { request.with(.day(person: guest, label: "You + " + (who.split(separator: " ").first.map(String.init) ?? who), start: $0)) } ?? request
    }

    private static func issue(_ words: String, _ lower: String) -> FieldRequest? {
        guard let repo = match(#"^(?:github )?issue (?:in |for )?([a-z0-9._-]+)\s*[:,-]"#, lower),
              let colon = words.firstIndex(where: { ":,-".contains($0) }) else { return nil }
        let title = words[words.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard title.count >= 3, let path = History.current.repo(named: repo) else { return nil }
        var url = URLComponents(string: "https://github.com/\(path)/issues/new")!
        url.queryItems = [URLQueryItem(name: "title", value: title)]
        return FieldRequest(title: "New issue in \(path)", site: "GitHub", symbol: "exclamationmark.circle", tint: .labelColor,
                            route: .link, fields: [.init(label: "Repository", value: path, source: "your history"),
                                                   .init(label: "Title", value: title, source: "your words")],
                            button: "Open on GitHub", act: .open(url.url!))
            .with(.form(site: "GitHub", tint: .labelColor, team: path, title: title, lines: [], button: "Submit new issue"))
    }

    private static func mail(_ words: String, _ lower: String, _ reading: Reading) -> FieldRequest? {
        guard let person = reading.person else { return nil }
        let subject = match(#"\babout (.+)$"#, words)
        var url = URLComponents(string: "https://mail.google.com/mail/")!
        url.queryItems = [URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
                          URLQueryItem(name: "to", value: person.address), URLQueryItem(name: "su", value: subject ?? "")]
        var fields: [FieldRequest.Field] = [.init(label: "To", value: "\(person.said) · \(person.address)", source: "Mail · \(person.threads) threads")]
        if let subject { fields.append(.init(label: "Subject", value: subject, source: "your words")) }
        return FieldRequest(title: "Mail to \(person.said)", site: "Gmail", symbol: "envelope", tint: .systemRed,
                            route: .link, fields: fields, button: "Open in Gmail", act: .open(url.url!))
            .with(.form(site: "Gmail", tint: .systemRed, team: nil, title: subject ?? "New message",
                        lines: [("To", "\(person.said) · \(person.address)")], button: "Send"))
    }

    // The agent, on a site you go to

    struct Verb {
        let pattern: String
        let title: String
        let button: String
        let checks: [String]
        let plan: [String]
    }

    static let verbs: [String: Verb] = [
        "return": Verb(pattern: #"^return\b"#, title: "Return", button: "Start Return", checks: ["Return window", "Pickup", "Refund"],
                       plan: ["Open the order", "Start the return with your reason", "Take the first pickup", "Keep the label in Mail"]),
        "cancel": Verb(pattern: #"^cancel\b"#, title: "Cancel", button: "Go to Cancel", checks: ["Plan", "Ends"],
                       plan: ["Open your account", "Find the cancel page", "Stop on the last confirm: that one is yours"]),
        "time_off": Verb(pattern: #"^(?:request )?(?:time off|vacation|pto|leave)\b"#, title: "Request time off", button: "Request Time Off",
                         checks: ["Balance", "Approver"],
                         plan: ["Open the site (you may need to sign in)", "Read your balance first", "Fill the request", "Submit it"]),
        "reorder": Verb(pattern: #"^(?:reorder|order again)\b"#, title: "Order again", button: "Fill the Cart", checks: ["Price", "Delivery"],
                        plan: ["Open your last order", "Put it in the cart", "Stop before Place Order: that one is yours"]),
        "book": Verb(pattern: #"^(?:book|reserve)\b"#, title: "Book", button: "Find and Book", checks: ["Price", "Availability"],
                     plan: ["Look for what you asked", "Ask you if there is more than one", "Stop before paying"]),
        "check_in": Verb(pattern: #"^check in\b"#, title: "Check in", button: "Check In", checks: ["Seat", "Boarding pass"],
                         plan: ["Open your booking", "Check in", "Hand over anything only you can type", "Keep the boarding pass in Mail"]),
    ]

    private static func task(_ words: String, _ verb: Verb, _ reading: Reading) -> FieldRequest? {
        guard let host = reading.host else { return nil }
        // Called what you called it: "workday" is Workday, whatever its host.
        let site = reading.named.map { $0.contains(".") ? Address.siteName(host) : $0.prefix(1).uppercased() + $0.dropFirst() }
            ?? Address.siteName(host)
        var fields: [FieldRequest.Field] = [.init(label: "Asked", value: words, source: "your words")]
        fields.append(.init(label: "Where", value: site, source: "you went there \(History.current.count(host: host)) times"))
        for check in verb.checks { fields.append(.init(label: check, value: "will check on \(site)", state: .check)) }
        let note = "Do it on \(host). Ask me only to sign in, to pay, or if the words can be read two ways; stop before anything that pays."
        let yours = verb.plan.lastIndex { $0.contains("yours") || $0.lowercased().hasPrefix("stop") }
        return FieldRequest(title: "\(verb.title) on \(site)", site: site, symbol: "agent.face", tint: .systemPurple, route: .agent,
                            fields: fields, plan: verb.plan, button: verb.button, act: .task(words + "\n\n" + note), taskNote: note)
            .with(.steps(mail: nil, steps: ["\(Agents.preferredName) opens \(host)"] + verb.plan.dropFirst().map { $0 }, yours: yours))
    }

    // MARK: helpers

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func after(_ prefix: String, in text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }

    /// What the words say should be said or noted: after "that", "saying"
    /// or a colon. "reply to taro that thursday works" → "thursday works".
    static func saidAfter(_ words: String) -> String? {
        match(#"(?:\bthat\b|\bsaying\b|:)\s*(.{2,})$"#, words)
    }

    /// A day the words name, at 8 in the morning: "till monday", "by friday".
    static func day(_ lower: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let start: Date?
        if lower.contains("tomorrow") {
            start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        } else if lower.contains("next week") {
            start = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))
        } else if let index = days.firstIndex(where: { lower.contains($0) }) {
            var parts = DateComponents()
            parts.weekday = index + 1
            start = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        } else {
            start = nil
        }
        return start.flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
    }

    /// "thursday at 3", "tomorrow at 10:30", "friday 4pm": the next one.
    static func when(_ lower: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var day: Date?
        if lower.contains("tomorrow") {
            day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        } else if lower.contains("today") {
            day = calendar.startOfDay(for: now)
        } else if let index = days.firstIndex(where: { lower.contains($0) }) {
            var parts = DateComponents()
            parts.weekday = index + 1
            day = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        }
        guard let day else { return nil }
        // "at 3" first, then "7am": never the 1 of "1:1" or the 4 of "Q4".
        guard let hour = (match(#"\bat (\d{1,2})\b"#, lower) ?? match(#"\b(\d{1,2})(?::\d\d)?\s*(?:am|pm)\b"#, lower)).flatMap(Int.init),
              hour <= 23 else { return nil }
        let minute = match(#"\b(?:at )?\d{1,2}:(\d\d)\s*(?:am|pm)?\b"#, lower).flatMap(Int.init) ?? 0
        let pm = lower.range(of: #"\d\s*pm\b"#, options: .regularExpression) != nil
        let am = lower.range(of: #"\d\s*am\b"#, options: .regularExpression) != nil
        // "at 3" in working hours is the afternoon.
        let hour24 = pm && hour < 12 ? hour + 12 : (!am && hour < 8 ? hour + 12 : hour)
        return calendar.date(bySettingHour: hour24, minute: minute, second: 0, of: day)
    }
}

// MARK: the calendar, asked once per hour asked about

@MainActor
private enum FreeTimes {
    static var answers: [Date: String] = [:]
    static var asking: Set<Date> = []

    /// Whether you are free then, from your calendars (Meetings.busy); the
    /// field is drawn again when the answer comes.
    static func free(_ start: Date, browser: Browser) -> String {
        if let said = answers[start] { return said }
        if !asking.contains(start) {
            asking.insert(start)
            Task { @MainActor [weak browser] in
                let busy = await Meetings.shared.busy(from: start, to: start.addingTimeInterval(1800))
                answers[start] = busy.map { $0.isEmpty ? "you are free" : "you have \($0[0].title)" } ?? "calendar not connected"
                asking.remove(start)
                if let browser, case .request = browser.query.offers.first?.kind { browser.typed = browser.typed }
            }
        }
        return "checking your calendar"
    }
}

// MARK: the field

extension Browser {
    /// The request the chosen row is, if it is one.
    var chosenRequest: FieldRequest? {
        guard let current = query.current, query.offers.indices.contains(current),
              case .request(let index) = query.offers[current].kind else { return nil }
        return request(index)
    }

    /// The window's request by its row.
    func request(_ index: Int) -> FieldRequest? {
        let shown = FieldRequest.shown[ObjectIdentifier(self)] ?? []
        return shown.indices.contains(index) ? shown[index] : nil
    }

    /// Return on a request's row.
    func runRequest(_ index: Int) {
        guard let request = request(index) else { return }
        if case .copy(let text) = request.act {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            close()
            toaster.pop("Copied")
            return
        }
        close()
        switch request.act {
        case .perform(let act):
            act(self)
        case .copy:
            break
        case .look(let look):
            prefs.look = look
        case .pin(let id):
            if let tab = tabs.first(where: { $0.id == id }) { pin(tab) }
        case .open(let url):
            _ = open(url, foreground: true)
        case .task(let prompt):
            if Agents.ready {
                if let session = Agents.shared.task(prompt, context: [], on: nil, in: self) { showChat(session.id) }
            } else {
                TaskLine.connect()
            }
        }
    }
}

extension History {
    /// A repository you have been to on GitHub by its name: "owner/name".
    func repo(named name: String) -> String? {
        let found = visits(since: .distantPast).compactMap { visit -> (String, Int)? in
            guard let url = URL(string: visit.url), url.host()?.lowercased() == "github.com" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, parts[1].lowercased() == name else { return nil }
            return (parts[0] + "/" + parts[1], visit.count)
        }
        return Dictionary(found, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    /// The site you go to by that name, "amazon" or "workday": its host,
    /// the one most visited.
    func host(named name: String) -> String? {
        let found = visits(since: .distantPast).compactMap { visit -> (String, Int)? in
            guard let host = URL(string: visit.url)?.host()?.lowercased(), host.contains(name) else { return nil }
            return (host, visit.count)
        }
        return Dictionary(found, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    /// The sites you go to most, by host: what Jev may pick from.
    func hosts(_ limit: Int) -> [String] {
        let counts = visits(since: .distantPast).reduce(into: [String: Int]()) { counts, visit in
            if let host = URL(string: visit.url)?.host()?.lowercased() { counts[host, default: 0] += visit.count }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// How many times you went to a host.
    func count(host: String) -> Int {
        visits(since: .distantPast).filter { URL(string: $0.url)?.host()?.lowercased() == host }.reduce(0) { $0 + $1.count }
    }
}

extension Address {
    /// "www.amazon.com" as people say it: "Amazon".
    static func siteName(_ host: String) -> String {
        let parts = host.split(separator: ".").filter { !["www", "m", "app"].contains($0) }
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? Substring(host)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: beside the list

/// The chosen request, beside the list: what is known of it, where from,
/// and how it will be done.
struct RequestPreview: View {
    let request: FieldRequest

    var body: some View {
        if let object = request.object {
            RequestObjectView(object: object)
                .padding(.horizontal, Omnibox.gutter)
                .padding(.top, 16)
        } else {
            fieldsView
        }
    }

    private var fieldsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Omnibox.gap) {
                FieldMark(symbol: request.symbol, tint: request.tint)
                    .frame(width: Omnibox.slot)
                Text(request.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(request.fields) { field in
                    GridRow {
                        Text(field.label)
                            .foregroundStyle(Palette.muted)
                            .gridColumnAlignment(.leading)
                        value(field)
                        Text(field.source)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 13))
                }
            }
            if let picture = request.picture, let image = NSImage(contentsOf: picture) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 120, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            if !request.plan.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On Return, the agent will")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    ForEach(Array(request.plan.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            // What Return does is the foot's button; who read the words is
            // the bench's (RequestModel.said), not a line here.
        }
        .padding(.horizontal, Omnibox.gutter)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func value(_ field: FieldRequest.Field) -> some View {
        switch field.state {
        case .known:
            Text(field.value).foregroundStyle(Palette.ink).lineLimit(2)
        case .check:
            Text(field.value).italic().foregroundStyle(Palette.muted).lineLimit(1)
        case .choose:
            Text(field.value).foregroundStyle(Palette.muted).lineLimit(1)
        case .doubt(let others):
            VStack(alignment: .leading, spacing: 2) {
                Text(field.value).foregroundStyle(Palette.ink).lineLimit(1)
                Text("or \(others)?")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .lineLimit(1)
            }
        }
    }
}

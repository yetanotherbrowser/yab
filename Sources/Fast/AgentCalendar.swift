import Foundation
import MailCore

// What an agent may know of the user's calendar and how it adds to it: the
// `calendar` and `calendar_add` tools.
//
// Read: what Meetings.busy reads for invitations and free slots, each
// connected Google account's primary calendar and the Mac's calendars where
// macOS already lets Yab read them, never asked for here. A meeting of
// today's or tomorrow's says its call's link, as the tabs do.
//
// Free: `calendar_free`, the free time of the working days ahead in the
// working hours Settings › Mail › Calendar keeps, as ⇧⌘A's slots read it
// (MailSlots), from the same calendars.
//
// Add: Google gave Yab its calendar to read only (calendar.events.readonly),
// so a new event is Google Calendar's own event page, filled in (a repeat
// as its RRULE), opened in the agent's tab, and a change to one is that
// event's own edit page (`event`, as `calendar` names it). Save there is the
// user's account doing it, with Google's own question about emailing the
// guests.

enum AgentCalendar {
    struct Failure: Error { let text: String }

    /// "2026-10-15", or a moment on that day, as its midnight here.
    static func day(_ text: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        if let day = format.date(from: String(text.prefix(10))) { return Calendar.current.startOfDay(for: day) }
        return moment(text).map { Calendar.current.startOfDay(for: $0) }
    }

    /// ISO 8601 with its zone, or without one as the time on `zone`'s
    /// clock (here, unless said). Seconds and their fractions are optional
    /// either way. The zone is an offset (-06:00, Z) or a name: a space
    /// before it, or in brackets as RFC 9557 writes it
    /// (2026-12-03T07:30 America/Mexico_City, 2026-12-03T07:30[America/Bogota]).
    static func moment(_ text: String, zone: TimeZone = .current) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var zone = zone
        if text.hasSuffix("]"), let open = text.lastIndex(of: "[") {
            guard let named = TimeZone(identifier: String(text[text.index(after: open)..<text.index(before: text.endIndex)])) else { return nil }
            zone = named
            text = String(text[..<open])
        } else if let space = text.lastIndex(of: " "), !text[text.index(after: space)...].contains(":") {
            // A name after the time (America/Bogota, UTC); a misspelled one is
            // no time at all, rather than the wrong one.
            guard let named = TimeZone(identifier: String(text[text.index(after: space)...])) else { return nil }
            zone = named
            text = String(text[..<space]).trimmingCharacters(in: .whitespaces)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        for shape in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
                      "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            format.dateFormat = shape
            if let at = format.date(from: text) { return at }
        }
        return nil
    }

    static func describe(_ busy: [BusyTime]?, from: Date, days: Int, meetings: [Meeting]) -> String {
        guard let busy else {
            return "No calendar Yab can read. Google's comes with the account connected in Settings › Mail (its consent includes the calendar); the Mac's calendars once macOS lets Yab read them (System Settings › Privacy & Security › Calendars)."
        }
        let calendar = Calendar.current
        let dayName = DateFormatter()
        dayName.dateFormat = "EEEE yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var out = "# Calendar, \(days == 1 ? "one day" : "\(days) days") (\(TimeZone.current.identifier))\n"
        for offset in 0..<days {
            guard let start = calendar.date(byAdding: .day, value: offset, to: from),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            out += "\n## \(dayName.string(from: start))\n"
            // The same event can be in Google's calendar and the Mac's.
            var seen = Set<String>()
            let taken = busy.filter { $0.start < end && $0.end > start }.filter { seen.insert("\($0.title)|\($0.start)").inserted }
            guard !taken.isEmpty else { out += "Nothing.\n"; continue }
            for event in taken {
                let allDay = event.end.timeIntervalSince(event.start) >= 86_399 && calendar.startOfDay(for: event.start) == event.start
                let time = allDay ? "all day" : "\(clock.string(from: event.start))–\(clock.string(from: event.end))"
                let maybe = event.maybe ? " (not said yes to)" : ""
                let call = meetings.first { $0.title == event.title && abs($0.start.timeIntervalSince(event.start)) < 60 }?.link.map { " · call: \($0.absoluteString)" } ?? ""
                let id = eid(event.link).map { " · event: \($0)" } ?? ""
                out += "- \(time)  \(event.title.isEmpty ? "(no title)" : event.title)\(maybe)\(call)\(id)\n"
            }
        }
        return out + "\nFree time is what isn't listed; calendar_free gives it in working hours. To add an event, calendar_add; to change one, calendar_add with its event."
    }

    /// A Google event's id as its page names it (htmlLink's `eid`), the
    /// one its edit page takes; nil for one that isn't Google's.
    static func eid(_ link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let parts = URLComponents(string: text), parts.host?.hasSuffix("google.com") == true {
            if let eid = parts.queryItems?.first(where: { $0.name == "eid" })?.value, !eid.isEmpty { return eid }
            // calendar.google.com/calendar/r/eventedit/<eid>, or …/event/<eid>
            let path = parts.path.split(separator: "/").map(String.init)
            if let at = path.lastIndex(where: { $0 == "eventedit" || $0 == "event" }), at + 1 < path.count { return path[at + 1] }
            return nil
        }
        // Already an eid: base64url letters only.
        return text.range(of: "^[A-Za-z0-9_-]{8,}={0,2}$", options: .regularExpression) != nil ? text : nil
    }

    /// The free time of the next working days, in working hours (Settings ›
    /// Mail › Calendar, as ⇧⌘A reads them), each day's free stretches long
    /// enough for `minutes`, runs of slots said as one.
    static func free(_ busy: [BusyTime]?, from now: Date, days: Int, minutes: Int?, hours: MailSlots.Hours = MailSlots.hours) -> String {
        guard let busy else { return describe(nil, from: now, days: 1, meetings: []) }
        var asked = hours
        if let minutes { asked.length = max(5, min(minutes, 8 * 60)) }
        let slots = MailSlots.free(busy: busy, from: now, hours: asked, days: days)
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let dayName = DateFormatter()
        dayName.dateFormat = "EEEE yyyy-MM-dd"
        let calendar = Calendar.current
        let start = String(format: "%d:%02d", hours.start / 60, hours.start % 60), end = String(format: "%d:%02d", hours.end / 60, hours.end % 60)
        var out = "# Free time, \(asked.length) minutes or more, working hours \(start)–\(end) (\(TimeZone.current.identifier))\n"
        guard !slots.isEmpty else { return out + "\nNothing free in the next \(days) working days.\n" }
        var grouped: [(Date, [DateInterval])] = []
        for run in MailSlots.merged(slots) {
            let day = calendar.startOfDay(for: run.start)
            if grouped.last?.0 == day { grouped[grouped.count - 1].1.append(run) } else { grouped.append((day, [run])) }
        }
        for (day, runs) in grouped {
            out += "- \(dayName.string(from: day)): " + runs.map { "\(clock.string(from: $0.start))–\(clock.string(from: $0.end))" }.joined(separator: ", ") + "\n"
        }
        return out + "\nOnly the user's own calendars: others' free time isn't known, so offer them a few of these. Working hours and the slot length are Settings › Mail › Calendar's."
    }

    /// The Google account the event goes in: the one asked for when it is
    /// connected, else the first whose calendar Yab reads.
    static func account(_ request: [String: Any], accounts: [String]) -> String? {
        if let asked = (request["account"] as? String)?.lowercased(), !asked.isEmpty {
            return accounts.first { $0.lowercased() == asked }
        }
        return accounts.first
    }

    /// Google Calendar's own event page, filled in.
    static func page(_ request: [String: Any], accounts: [String]) -> Result<URL, Failure> {
        if let asked = request["event"] as? String, !asked.trimmingCharacters(in: .whitespaces).isEmpty {
            // An event there already: its own edit page, changed by hand there.
            guard let eid = eid(asked) else { return .failure(Failure(text: "event is an event as `calendar` names it (event: …)")) }
            var parts = URLComponents(string: "https://calendar.google.com/calendar/r/eventedit/" + eid)!
            if let account = account(request, accounts: accounts) { parts.queryItems = [URLQueryItem(name: "authuser", value: account)] }
            guard let url = parts.url else { return .failure(Failure(text: "Couldn't make the event's page")) }
            return .success(url)
        }
        let title = (request["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(Failure(text: "calendar_add needs a title")) }
        guard let start = (request["start"] as? String).flatMap({ moment($0) }) else {
            return .failure(Failure(text: "calendar_add needs start as 2026-10-15T09:00 (local), or with its zone: 2026-10-15T09:00-05:00 or 2026-10-15T09:00 America/Bogota"))
        }
        let end = (request["end"] as? String).flatMap({ moment($0) })
            ?? start.addingTimeInterval(Double(request["minutes"] as? Int ?? 30) * 60)
        guard end > start else { return .failure(Failure(text: "The end comes before the start")) }
        if let asked = request["account"] as? String, !asked.isEmpty, account(request, accounts: accounts) == nil {
            return .failure(Failure(text: "\(asked) isn't connected in Yab. Connected: \(accounts.isEmpty ? "none" : accounts.joined(separator: ", "))."))
        }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var parts = URLComponents(string: "https://calendar.google.com/calendar/r/eventedit")!
        var items = [URLQueryItem(name: "text", value: title), URLQueryItem(name: "dates", value: "\(utc.string(from: start))/\(utc.string(from: end))")]
        if let details = request["details"] as? String, !details.isEmpty { items.append(URLQueryItem(name: "details", value: details)) }
        if let location = request["location"] as? String, !location.isEmpty { items.append(URLQueryItem(name: "location", value: location)) }
        let guests = (request["guests"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") }
        if !guests.isEmpty { items.append(URLQueryItem(name: "add", value: guests.joined(separator: ","))) }
        if let rule = (request["recurrence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty {
            let said = rule.uppercased().hasPrefix("RRULE:") ? rule : "RRULE:" + rule
            guard said.uppercased().contains("FREQ=") else { return .failure(Failure(text: "recurrence is an RRULE: FREQ=WEEKLY;COUNT=10")) }
            items.append(URLQueryItem(name: "recur", value: said))
        }
        if let account = account(request, accounts: accounts) { items.append(URLQueryItem(name: "authuser", value: account)) }
        parts.queryItems = items
        guard let url = parts.url else { return .failure(Failure(text: "Couldn't make the event's page")) }
        return .success(url)
    }
}

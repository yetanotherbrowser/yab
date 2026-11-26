import Foundation

// Free slots in a mail (docs/mail.md, Calendar): ⇧⌘A in a reply or a new
// mail turns the field's rows into the free time of the next five working
// days, from your calendars (Meetings.busy), in your working hours and of
// the length Settings › Mail keeps. The slots chosen go into the words as
// text with your zone, "Tue 14:00–14:30, Wed 10:00–11:00 (CET)", slots
// side by side said as one, and your booking link after them when you keep
// one. Nothing is booked: they are words, for the person you write to.

public enum MailSlots {
    /// When you work and how long a slot is: minutes from midnight, and
    /// the days (Calendar's weekdays, 1 Sunday); nil days, the Mac's own
    /// weekend left out (Saturday and Sunday, or Friday and Saturday).
    public struct Hours: Equatable {
        public var start = 9 * 60
        public var end = 18 * 60
        public var length = 30
        public var days: Set<Int>? = nil
    }

    /// Settings › Mail's: `mail.slots.start` and `mail.slots.end` in
    /// minutes from midnight, `mail.slots.length` in minutes.
    public static var hours: Hours {
        let settings = Store.settings
        var hours = Hours()
        if let start = settings.object(forKey: "mail.slots.start") as? Int { hours.start = start }
        if let end = settings.object(forKey: "mail.slots.end") as? Int { hours.end = end }
        if let length = settings.object(forKey: "mail.slots.length") as? Int, lengths.contains(length) { hours.length = length }
        if hours.end <= hours.start { hours = Hours(length: hours.length) }
        return hours
    }

    /// The lengths Settings offers.
    public static let lengths = [15, 30, 45, 60, 90]

    /// A Calendly or Cal.com link kept in Settings › Mail (`mail.booking`),
    /// said after the slots; "" for none.
    public static var booking: String {
        (Store.settings.string(forKey: "mail.booking") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many working days ahead the slots reach.
    public static let reach = 5

    /// Every free slot of the working days from now on, `days` of them
    /// that still have room: from the start of working hours a slot's
    /// length at a time, by the wall clock (a change of time moves no
    /// slot), none begun already, none that touches what is busy.
    public static func free(busy: [BusyTime], from now: Date, hours: Hours = MailSlots.hours, days: Int = MailSlots.reach,
                     calendar: Calendar = .current) -> [DateInterval] {
        let length = TimeInterval(max(5, hours.length) * 60)
        var out: [DateInterval] = []
        var counted = 0
        var day = calendar.startOfDay(for: now)
        for _ in 0..<60 where counted < days {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day).map { calendar.startOfDay(for: $0) } ?? day.addingTimeInterval(86_400) }
            let working = hours.days.map { $0.contains(calendar.component(.weekday, from: day)) } ?? !calendar.isDateInWeekend(day)
            guard working,
                  let open = calendar.date(bySettingHour: hours.start / 60, minute: hours.start % 60, second: 0, of: day),
                  let close = hours.end >= 24 * 60 ? calendar.date(byAdding: .day, value: 1, to: day)
                      : calendar.date(bySettingHour: hours.end / 60, minute: hours.end % 60, second: 0, of: day)
            else { continue }
            // A day whose working hours are over isn't one of them.
            guard close.addingTimeInterval(-length) > now else { continue }
            counted += 1
            var at = open
            while at.addingTimeInterval(length) <= close {
                let slot = DateInterval(start: at, duration: length)
                if at > now, !busy.contains(where: { $0.start < slot.end && $0.end > slot.start && $0.end > $0.start }) {
                    out.append(slot)
                }
                at = at.addingTimeInterval(length)
            }
        }
        return out
    }

    /// The slots offered first: the first free one of each of the next
    /// three working days after today.
    public static func suggested(_ slots: [DateInterval], now: Date, calendar: Calendar = .current) -> [DateInterval] {
        var days = Set<Date>()
        return Array(slots.filter { slot in
            let day = calendar.startOfDay(for: slot.start)
            return !calendar.isDate(day, inSameDayAs: now) && days.insert(day).inserted
        }.prefix(3))
    }

    /// The slots as words to send: each run of them side by side as one,
    /// a day's name before each, "Tue 14:00–14:30, Wed 10:00–11:00 (CET)";
    /// the zone once at the end, or after each when a change of time falls
    /// between them; the date too when a day's name alone could be two
    /// days. The booking link on a line after them; it alone with none.
    public static func text(_ slots: [DateInterval], booking: String = "", now: Date, calendar: Calendar = .current) -> String {
        let runs = merged(slots)
        let zone = calendar.timeZone
        let zones = Set(runs.map { Self.said(zone, at: $0.start) })
        let names = runs.map { MailICS.format("EEE", zone).string(from: $0.start) }
        // A week or more ahead, or a name twice: the date says which.
        let far = runs.contains { $0.start.timeIntervalSince(now) > 6 * 86_400 } || Set(names).count < Set(runs.map { calendar.startOfDay(for: $0.start) }).count
        let day = MailICS.format(far ? "EEE MMM d" : "EEE", zone), hour = MailICS.format("H:mm", zone)
        // Not named `said`: Swift 6.3 (Xcode 26) reads the function's name as this.
        var times = runs.map { run -> String in
            let each = zones.count > 1 ? " (" + Self.said(zone, at: run.start) + ")" : ""
            return day.string(from: run.start) + " " + hour.string(from: run.start) + "–" + hour.string(from: run.end) + each
        }.joined(separator: ", ")
        if zones.count == 1, let one = zones.first, !one.isEmpty, !times.isEmpty { times += " (\(one))" }
        let link = booking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return times }
        return times.isEmpty ? "Book a time: " + link : times + "\nOr book a time: " + link
    }

    /// A zone as people write it after a time: its English abbreviation
    /// where a country of English has one ("EST", "CET", "BST", "IST",
    /// "AEST"), else its offset ("GMT+3"); for the moment given, so a
    /// change of time says the other.
    public static func said(_ zone: TimeZone, at date: Date) -> String {
        var offset = ""
        for locale in ["en_US", "en_GB", "en_AU", "en_IN"] {
            let format = MailICS.format("zzz", zone)
            format.locale = Locale(identifier: locale)
            let name = format.string(from: date)
            if offset.isEmpty { offset = name }
            if !name.hasPrefix("GMT+"), !name.hasPrefix("GMT-"), !name.hasPrefix("UTC") || name == "UTC" { return name }
        }
        // macOS 27's ICU says London's winter "GMT+0" in every English locale.
        return zone.secondsFromGMT(for: date) == 0 ? "GMT" : offset
    }

    /// Slots that touch said as one.
    public static func merged(_ slots: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, slot.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, slot.end))
            } else {
                out.append(slot)
            }
        }
        return out
    }
}

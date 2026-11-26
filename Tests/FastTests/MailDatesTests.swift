import Foundation
import Testing
@testable import Fast

// When a thread's mails say they were written (MailPane.said): days on the
// calendar, not spans of 24 hours, and a range said one way at both ends
// (a long thread's middle, MailFoldedStack).

struct MailDatesTests {
    private let calendar = Calendar.current

    private func at(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @MainActor @Test func mondayIsMondayOnWednesdayMorning() {
        let now = at(10, 7, 9)
        // 46 hours before, two days on the calendar: it said "yesterday".
        let monday = at(10, 5, 11)
        #expect(MailPane.said(monday, now: now) == monday.formatted(.dateTime.weekday(.abbreviated).locale(AppDates.locale)))
        #expect(MailPane.said(at(10, 6, 20), now: now) == "yesterday")
        #expect(MailPane.said(at(10, 6, 23), now: at(10, 7, 1)) == "yesterday")
        // A week back, its date.
        #expect(MailPane.said(at(9, 30, 10), now: now) == at(9, 30, 10).formatted(.dateTime.month(.abbreviated).day().locale(AppDates.locale)))
    }

    @MainActor @Test func aRangeIsSaidOneWay() {
        let now = at(10, 7, 9)
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(AppDates.locale)
        #expect(MailPane.saidRange(at(9, 30, 10), at(10, 1, 10), now: now) == at(9, 30, 10).formatted(day) + " to " + at(10, 1, 10).formatted(day))
        #expect(MailPane.saidRange(at(10, 5, 9), at(10, 5, 17), now: now) == MailPane.said(at(10, 5, 9), now: now))
    }
}

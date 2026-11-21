import SwiftUI

/// When a thing happened, said the way the lists say it: the box's places,
/// the bookmarks' page.

enum When {
    /// The words' language: Yab is English, so "2 days ago" and "5 October"
    /// are said in English on a German or French Mac too, not "vor 2 Tagen"
    /// beside "Moved or deleted" (a tester's downloads, 2026-10-12). Times of
    /// day keep the Mac's own format.
    static let words = Locale(identifier: "en_US")

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = words
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = AppDates.formatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = words
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

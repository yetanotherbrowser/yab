import Foundation
import SyncKit

/// Yab's date display is English. Native input services keep the system locale.
enum AppDates {
    static var locale: Locale { EnglishDates.locale }
    static var dateTime: Date.FormatStyle { .dateTime.locale(locale) }

    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter
    }

    static func string(from date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let format = formatter()
        format.dateStyle = dateStyle
        format.timeStyle = timeStyle
        return format.string(from: date)
    }
}

extension Date {
    func englishFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: AppDates.locale))
    }
}

extension ListFormatter {
    static func englishString(byJoining words: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = EnglishDates.locale
        return formatter.string(from: words) ?? words.joined(separator: ", ")
    }
}

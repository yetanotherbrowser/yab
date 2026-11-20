import Foundation
import Testing
@testable import Fast
@testable import MailCore

/// What an agent was given on 2026-10-14: the iPhone's history and tabs,
/// the calendar, and the settings it could not reach before.
struct AgentKnowsTests {
    @Test func anotherDevicesPlacesAreFoundAndSaidWhereTheyWereOpened() {
        let now = Date()
        let elsewhere = [
            AgentDevices.Visit(url: URL(string: "https://www.nytimes.com/2026/10/13/crossword.html")!, title: "The Crossword", at: now.addingTimeInterval(-3600), device: "Anna's iPhone (iPhone)"),
            AgentDevices.Visit(url: URL(string: "https://github.com/yab/yab/pull/12")!, title: "Fix sync", at: now.addingTimeInterval(-7200), device: "Studio"),
        ]
        let phone = AgentHistory.pages(matching: nil, host: nil, device: "iphone", elsewhere: elsewhere)
        #expect(phone.contains("The Crossword  (on Anna's iPhone (iPhone))"))
        #expect(!phone.contains("Fix sync"))
        let none = AgentHistory.pages(matching: nil, host: nil, device: "ipad", elsewhere: elsewhere)
        #expect(none.contains("Devices with history here: Anna's iPhone (iPhone), Studio"))
        #expect(AgentHistory.pages(matching: nil, host: nil, device: "iphone", elsewhere: []).hasPrefix("Nothing from another device"))
    }

    @Test func momentsReadWithAndWithoutTheirZone() throws {
        let local = try #require(AgentCalendar.moment("2026-10-15T09:00"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 10, 15, 9, 0])
        let zoned = try #require(AgentCalendar.moment("2026-10-15T09:00:00Z"))
        #expect(zoned.timeIntervalSince1970 == 1_792_054_800)
        #expect(AgentCalendar.moment("tomorrow at nine") == nil)
        #expect(AgentCalendar.day("2026-10-15") == Calendar.current.startOfDay(for: local))
    }

    /// calendar_add said "with its zone" and refused 2026-12-03T07:30-06:00
    /// (no seconds) and any zone given by name.
    @Test func momentsTakeTheirZoneAsAnOffsetOrByName() throws {
        let utc1330 = 1_796_304_600.0, utc1230 = 1_796_301_000.0
        for said in ["2026-12-03T07:30-06:00", "2026-12-03T07:30:00-06:00", "2026-12-03T07:30:00.000-06:00",
                     "2026-12-03T13:30Z", "2026-12-03T07:30 America/Mexico_City", "2026-12-03T07:30:00 America/Mexico_City",
                     "2026-12-03T07:30[America/Mexico_City]", "2026-12-03 07:30 America/Mexico_City"] {
            #expect(AgentCalendar.moment(said)?.timeIntervalSince1970 == utc1330, "\(said)")
            #expect(Mcp.localDate(said)?.timeIntervalSince1970 == utc1330, "\(said)")
        }
        // Bogotá keeps no summer time: an hour ahead of Mexico City in December.
        #expect(AgentCalendar.moment("2026-12-03T07:30 America/Bogota")?.timeIntervalSince1970 == utc1230)
        #expect(AgentCalendar.moment("2026-12-03T07:30 Nowhere/Atlantis") == nil)
        #expect(AgentCalendar.moment("2026-12-03T07:30+25:00") == nil)
        let url = try AgentCalendar.page(["title": "Run", "start": "2026-12-03T07:30-06:00", "minutes": 60], accounts: []).get()
        #expect(url.absoluteString.contains("dates=20261203T133000Z/20261203T143000Z"))
    }

    @Test func momentsWithoutAZoneAreOnTheClockTheyAreReadOn() throws {
        let bogota = try #require(TimeZone(identifier: "America/Bogota"))
        #expect(AgentCalendar.moment("2026-12-03T07:30", zone: bogota)?.timeIntervalSince1970 == 1_796_301_000)
        #expect(AgentCalendar.moment("2026-12-03T12:30 UTC")?.timeIntervalSince1970 == 1_796_301_000)
        #expect(AgentCalendar.moment("2026-12-03 07:30", zone: bogota)?.timeIntervalSince1970 == 1_796_301_000)
        // A date alone is a day for `calendar`, not a start for calendar_add.
        #expect(AgentCalendar.moment("2026-12-03") == nil)
        #expect(Mcp.localDate("2026-12-03", zone: bogota)?.timeIntervalSince1970 == 1_796_274_000)
    }

    @Test func anEventIsGoogleCalendarsOwnPageFilledIn() throws {
        let request: [String: Any] = ["title": "Coffee with Anna", "start": "2026-10-15T09:00:00Z", "minutes": 45,
                                      "guests": ["anna@fold.studio", "not an address"], "account": "Me@Gmail.com"]
        let url = try AgentCalendar.page(request, accounts: ["me@gmail.com", "work@yab.dev"]).get()
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "calendar.google.com" && url.path() == "/calendar/r/eventedit")
        #expect(items["text"] == "Coffee with Anna")
        #expect(items["dates"] == "20261015T090000Z/20261015T094500Z")
        #expect(items["add"] == "anna@fold.studio")
        #expect(items["authuser"] == "me@gmail.com")
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["title": "x", "start": "2026-10-15T09:00", "account": "else@x.com"], accounts: ["me@gmail.com"]).get() }
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["title": "x", "start": "2026-10-15T09:00", "end": "2026-10-15T08:00"], accounts: []).get() }
        #expect(throws: AgentCalendar.Failure.self) { try AgentCalendar.page(["start": "2026-10-15T09:00"], accounts: []).get() }
    }

    @Test func aDaySaysItsEventsAndTheCallsLink() throws {
        let day = try #require(AgentCalendar.day("2026-10-15"))
        let start = day.addingTimeInterval(10 * 3600), end = start.addingTimeInterval(1800)
        let busy = [BusyTime(title: "Standup", start: start, end: end, maybe: true), BusyTime(title: "Standup", start: start, end: end)]
        let call = Meeting(id: "1", title: "Standup", start: start, end: end, link: URL(string: "https://meet.google.com/abc-defg-hij"))
        let said = AgentCalendar.describe(busy, from: day, days: 2, meetings: [call])
        #expect(said.components(separatedBy: "Standup").count == 2)
        #expect(said.contains("10:00–10:30  Standup (not said yes to) · call: https://meet.google.com/abc-defg-hij"))
        #expect(said.contains("Nothing."))
        #expect(AgentCalendar.describe(nil, from: day, days: 1, meetings: []).hasPrefix("No calendar Yab can read"))
    }

    @MainActor @Test func mailAndSyncSettingsAreActionsAndPrivateOnesAreNot() throws {
        let ids = Set(NativeActions.descriptors.compactMap { $0["id"] as? String })
        for id in ["mail-undo", "mail-hours", "mail-badge", "mail-ads", "sync-history", "app-icon", "snippets-semicolon", "search-suggest", "small-key"] {
            #expect(ids.contains("settings.set." + id), "\(id)")
        }
        #expect(ids.contains("mail.set_notify") && ids.contains("mail.set_read_statuses"))
        for id in ["mail-people", "sync-passwords", "mail-agents", "mail-memory"] { #expect(!ids.contains("settings.set." + id), "\(id)") }
        let undo = try #require(NativeActions.descriptors.first { $0["id"] as? String == "settings.set.mail-undo" })
        try NativeActions.validate(["value": .number(10)], descriptor: undo)
        #expect(throws: NativeFailure.self) { try NativeActions.validate(["value": .number(7)], descriptor: undo) }
        let hours = try #require(NativeSetting.all.first { $0.id == "mail-hours" })
        #expect(throws: NativeFailure.self) { try hours.write(Preferences(), .string("18:00-09:00")) }
        let item = try #require(SettingsItem.all.first { $0.id == "mail-people" })
        #expect(NativeActions.classification(item) == "user_only")
    }
}

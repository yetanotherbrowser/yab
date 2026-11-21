import Foundation
@testable import SyncKit
import Testing
@testable import Fast

// Yab's dates are English whatever language the Mac is set to: the locale's
// language becomes English, its region and keywords stay.
struct EnglishDatesTests {
    @Test func displayListsKeepTheirEnglishConjunctions() {
        let words = ListFormatter.englishString(byJoining: ["Ada", "Ben", "Cora"])
        #expect(words.contains(" and "))
        #expect(words.contains("Ada") && words.contains("Ben") && words.contains("Cora"))
    }

    @Test func englishDisplayKeepsTheCurrentHourCalendarAndWeekPreferences() {
        let native = Locale(identifier: "zh_Hant_TW@calendar=japanese;fw=mon;hours=h23;numbers=arab")
        let english = EnglishDates.formattingLocale(for: native)
        #expect(english.language.languageCode?.identifier == "en")
        #expect(english.language.script == nil || english.language.script?.identifier == "Latn")
        #expect(english.region?.identifier == "TW")
        #expect(english.hourCycle == .zeroToTwentyThree)
        #expect(english.calendar.identifier == .japanese)
        #expect(english.firstDayOfWeek == .monday)
        #expect(english.numberingSystem.identifier == "arab")
    }

    @Test func anEnglishLocaleKeepsItsTwelveHourPreference() {
        let english = EnglishDates.formattingLocale(for: Locale(identifier: "en_GB@hours=h12"))
        #expect(english.language.languageCode?.identifier == "en")
        #expect(english.region?.identifier == "GB")
        #expect(english.hourCycle == .oneToTwelve)
    }

    @Test func startupLeavesTheSystemLocaleToNativeInputServices() throws {
        let name = "EnglishDatesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        EnglishDates.apply(system: "zh_TW", defaults: defaults, domain: name)
        #expect(defaults.persistentDomain(forName: name)?["AppleLocale"] == nil)
    }

    @Test func startupRemovesOnlyTheOldGeneratedOverride() throws {
        let name = "EnglishDatesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("en_TW", forKey: "AppleLocale")
        defaults.set(["zh-Hant-TW", "en-TW"], forKey: "AppleLanguages")
        defaults.set(true, forKey: "unrelated")
        EnglishDates.apply(system: "zh_TW", defaults: defaults, domain: name)
        #expect(defaults.persistentDomain(forName: name)?["AppleLocale"] == nil)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hant-TW", "en-TW"])
        #expect(defaults.bool(forKey: "unrelated"))
    }

    @Test(arguments: ["en_TW", "en_TW@calendar=japanese"])
    func startupRemovesTheOldOverrideAfterTheRegionChanges(_ stored: String) throws {
        let name = "EnglishDatesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(stored, forKey: "AppleLocale")
        EnglishDates.apply(system: "ja_JP", defaults: defaults, domain: name)
        #expect(defaults.persistentDomain(forName: name)?["AppleLocale"] == nil)
    }

    @Test(arguments: ["fr_FR", "en_US_POSIX", "en-GB"])
    func startupPreservesADifferentAppLocale(_ stored: String) throws {
        let name = "EnglishDatesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(stored, forKey: "AppleLocale")
        EnglishDates.apply(system: "zh_TW", defaults: defaults, domain: name)
        #expect(defaults.string(forKey: "AppleLocale") == stored)
    }

    @Test(.enabled(if: Calendar.current.identifier == .gregorian, "This display fixture uses a Gregorian October date"))
    func gregorianDisplayDatesStayEnglishWithoutChangingNativePreferences() throws {
        let before = UserDefaults.standard.string(forKey: "AppleLocale")
        let native = Locale.current
        let day = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                              year: 2026, month: 10, day: 15, hour: 12).date)
        let format = AppDates.formatter()
        format.dateFormat = "MMM"
        let words = [format.string(from: day), day.formatted(AppDates.dateTime.month(.abbreviated)),
                     day.englishFormatted(date: .abbreviated, time: .omitted),
                     AppDates.string(from: day, dateStyle: .medium, timeStyle: .none)]
        for word in words { #expect(word.contains("Oct"), "\(word)") }
        #expect(UserDefaults.standard.string(forKey: "AppleLocale") == before)
        #expect(Locale.current == native)
        #expect(AppDates.locale.region == native.region)
    }

    @Test func messagesKeepEnglishDatesAndRelativeTimes() {
        let now = Date()
        let recent = now.addingTimeInterval(-121 * 60)
        let older = now.addingTimeInterval(-3 * 86_400)

        #expect(AgentMessages.ago(recent) == "2 h ago")
        #expect(AgentMessages.ago(older) == AppDates.string(from: older, dateStyle: .medium, timeStyle: .none))
    }

    @Test func theLanguageBecomesEnglishAndTheRegionStays() {
        #expect(EnglishDates.identifier(system: "fr_FR") == "en_FR")
        #expect(EnglishDates.identifier(system: "de_DE") == "en_DE")
        #expect(EnglishDates.identifier(system: "sr_Latn_RS") == "en_RS")
        #expect(EnglishDates.identifier(system: "ja_JP@calendar=japanese") == "en_JP@calendar=japanese")
        #expect(EnglishDates.identifier(system: "uk") == "en")
    }

    @Test func anEnglishOneIsLeftAsItIs() {
        #expect(EnglishDates.identifier(system: "en_GB") == "en_GB")
        #expect(EnglishDates.identifier(system: "en_US@rg=gbzzzz") == "en_US@rg=gbzzzz")
        #expect(EnglishDates.identifier(system: nil) == nil)
        #expect(EnglishDates.identifier(system: "") == nil)
    }

    @Test func aGermanMacsDateReadsInEnglish() throws {
        let id = try #require(EnglishDates.identifier(system: "de_DE"))
        let day = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                              year: 2026, month: 10, day: 15).date)
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Locale(identifier: id))
        style.calendar = Calendar(identifier: .gregorian)
        let words = day.formatted(style)
        #expect(words.contains("Oct"), "\(words)")
        #expect(!words.contains("Okt"), "\(words)")
        #expect(Locale(identifier: id).region?.identifier == "DE")
    }
}

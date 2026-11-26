import Foundation

/// Yab speaks English, so its dates do too: "Oct 15", never "15 oct." on a
/// Mac or iPhone set to another language (a member card's date said so, 0.0.25).
/// Date formatters keep the user's region and calendar, without changing the
/// Mac's native input services or the languages requested by web pages.
public enum EnglishDates {
    private static var systemIdentifier: String? {
        CFPreferencesCopyValue("AppleLocale" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// English is a date-display policy, not the application's native locale.
    public static let locale = formattingLocale(for: .current)

    static func formattingLocale(for current: Locale) -> Locale {
        // Capturing the current locale's components keeps preferences such as
        // the 24-hour clock, which a locale built from its identifier can lose.
        var components = Locale.Components(locale: current)
        if components.languageComponents.languageCode?.identifier != "en" {
            components.languageComponents.languageCode = .english
            components.languageComponents.script = nil
        }
        return Locale(components: components)
    }

    /// Retire the Mac's old generated override before native input starts.
    /// An English app-wide AppleLocale can prevent ABC from switching back to
    /// Zhuyin with Caps Lock. The iPhone keeps its existing startup policy.
    public static func apply() {
        apply(system: systemIdentifier, defaults: .standard,
              domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    static func apply(system: String?, defaults: UserDefaults, domain: String) {
        guard let wanted = identifier(system: system) else { return }
        #if os(macOS)
        guard wanted != system,
              let stored = defaults.persistentDomain(forName: domain)?["AppleLocale"] as? String else { return }
        // The old override included only English, the region at the time, and optional ICU keywords.
        let base = stored.prefix { $0 != "@" }
        let region = Locale(identifier: String(base)).region
        if base == "en" || region.map({ base == "en_\($0.identifier)" }) == true {
            defaults.removeObject(forKey: "AppleLocale")
        }
        #else
        if defaults.string(forKey: "AppleLocale") != wanted { defaults.set(wanted, forKey: "AppleLocale") }
        #endif
    }

    /// The system's locale with English as its language: ru_RU is en_RU,
    /// sr_Latn_RS is en_RS, an English one stays as it is. Keywords after @
    /// (a calendar, a numbering) are kept.
    public static func identifier(system: String?) -> String? {
        guard let system, !system.isEmpty else { return nil }
        let parts = system.split(separator: "@", maxSplits: 1).map(String.init)
        let locale = Locale(identifier: parts[0])
        if locale.language.languageCode?.identifier == "en" { return system }
        let base = locale.region.map { "en_" + $0.identifier } ?? "en"
        return parts.count > 1 ? base + "@" + parts[1] : base
    }
}

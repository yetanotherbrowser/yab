import Foundation
import Observation
import SwiftUI
import UIKit

/// What the person chose in Settings, kept in UserDefaults. Other parts of
/// the app read it here (SettingsStore.shared): who answers questions about
/// a page, when notifications may come.
///
/// Test runs (a named world, XCTest) keep it in a suite of their own that
/// starts empty at every launch, so a named state never inherits the last
/// run's choices and the person's own settings are never touched.
@MainActor
@Observable
final class SettingsStore {
    static let shared: SettingsStore = {
        let store = SettingsStore(defaults: SettingsStore.launchDefaults(),
                                  supportsOnDeviceAnswers: LaunchOptions.current.isTestRun || OnDeviceModel.isDeviceEligible)
        store.appIcons.keepLegacySelection(PhoneAppIcon.current(UIApplication.shared.alternateIconName))
        return store
    }()
    static let websiteDarkeningChanged = Notification.Name("yab.website-darkening.changed")
    let appIcons: AppIconAccess
    let tablet: TabletLayoutPreferences

    // MARK: - the choices

    /// Mac settings supply the default, until the person chooses here.
    /// The account's imported settings are not written into local defaults.
    var searchSelection: SearchEngine.Selection {
        access(keyPath: \.searchSelection)
        return localSearch ?? importedSearch
    }

    var searchEngines: [SearchEngine] {
        SearchEngine.allCases.filter { $0 != .custom || SearchEngine.accepts(searchSelection.customTemplate) || SearchEngine.accepts(importedSearch.customTemplate) }
    }

    var customSearchSelection: SearchEngine.Selection {
        let custom = SearchEngine.accepts(searchSelection.customTemplate) ? searchSelection.customTemplate : importedSearch.customTemplate
        return SearchEngine.Selection(rawValue: SearchEngine.custom.rawValue, customTemplate: custom)
    }

    func chooseSearchEngine(_ engine: SearchEngine) {
        let custom = SearchEngine.accepts(searchSelection.customTemplate) ? searchSelection.customTemplate : importedSearch.customTemplate
        let next = SearchEngine.Selection(rawValue: engine.rawValue, customTemplate: custom)
        guard next.engine == engine else { return }
        withMutation(keyPath: \.searchSelection) { localSearch = next }
        write(engine.rawValue, Key.searchEngine)
        write(custom, Key.customSearch)
    }

    /// Read-only sync import. Unknown providers never masquerade as supported.
    func importSearchPreferences(engine: String?, customTemplate: String?) {
        let next = SearchEngine.Selection(rawValue: engine, customTemplate: customTemplate ?? "")
        guard next != importedSearch else { return }
        withMutation(keyPath: \.searchSelection) { importedSearch = next }
    }

    // MARK: - what the field offers

    /// Settings › Search › Guess from Your Words: a question leads with Ask
    /// and a task with the Mac's agent. Off, Return always searches. The
    /// Mac's Settings › Field supplies both this and the rows under the
    /// words until the person chooses here; what is chosen here stays here.
    var guessesFromWords: Bool {
        get { access(keyPath: \.guessesFromWords); return localGuesses ?? importedGuesses }
        set { withMutation(keyPath: \.guessesFromWords) { localGuesses = newValue }; write(newValue, Key.guessesFromWords) }
    }
    /// The Ask row under the words.
    var offersAsk: Bool {
        get { access(keyPath: \.offersAsk); return localAsk ?? importedAsk }
        set { withMutation(keyPath: \.offersAsk) { localAsk = newValue }; write(newValue, Key.offersAsk) }
    }
    /// The Task row under the words.
    var offersTask: Bool {
        get { access(keyPath: \.offersTask); return localTask ?? importedTask }
        set { withMutation(keyPath: \.offersTask) { localTask = newValue }; write(newValue, Key.offersTask) }
    }

    /// Read-only sync import of the Mac's "field.firstRow" (Return takes the
    /// top row, so nothing is guessed) and "field.under" (its fallback rows).
    func importFieldPreferences(firstRow: Bool?, rows: [String]?) {
        let guesses = firstRow != true
        let under = rows ?? ["search", "ask", "task"]
        withMutation(keyPath: \.guessesFromWords) { importedGuesses = guesses }
        withMutation(keyPath: \.offersAsk) { importedAsk = under.contains("ask") }
        withMutation(keyPath: \.offersTask) { importedTask = under.contains("task") }
    }

    // MARK: - the ad blocker

    /// Ads and trackers blocked on every page (Page/Shield). Yab on the
    /// Mac's switch is the default until the person chooses here, as with
    /// Search; what is chosen here stays on this iPhone.
    var blocksAds: Bool {
        get { access(keyPath: \.blocksAds); return localBlocksAds ?? importedBlocksAds }
        set { withMutation(keyPath: \.blocksAds) { localBlocksAds = newValue }; write(newValue, Key.blocksAds) }
    }

    /// A site Yab on the Mac has its blocker off for (its Site Controls or
    /// Settings, "shield.paused" in sync): off here too, unless this iPhone
    /// was told otherwise for the site (SiteSettings).
    func macPausesAds(on host: String?) -> Bool {
        access(keyPath: \.blocksAds)
        guard let key = SiteSettings.key(host) else { return false }
        return importedPausedSites.contains(key)
    }

    /// Read-only sync import of the Mac's "shield" and "shield.paused".
    func importShieldPreferences(enabled: Bool?, paused: [String]?) {
        let on = enabled ?? true
        let sites = Set((paused ?? []).compactMap { SiteSettings.key($0) })
        guard on != importedBlocksAds || sites != importedPausedSites else { return }
        withMutation(keyPath: \.blocksAds) {
            importedBlocksAds = on
            importedPausedSites = sites
        }
    }

    enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
    }

    /// Who answers a question about the page in front.
    enum PageAnswers: String, CaseIterable, Sendable {
        /// The model on this iPhone: at once, and the page never leaves it.
        case iPhone
        /// Claude on the Mac, with the person's sign-ins.
        case mac
    }

    /// The agent on the Mac, by the name of the plan people know it by.
    enum Agent: String, CaseIterable, Sendable {
        case claude, chatGPT

        var name: String {
            switch self {
            case .claude: "Claude"
            case .chatGPT: "ChatGPT"
            }
        }
    }

    /// What a locked iPhone may show of a task (the Lock Screen, the island).
    enum LockScreen: String, CaseIterable, Sendable {
        /// Amounts and recipients only after Face ID.
        case afterFaceID
        /// Never more than the task's name.
        case never
    }

    /// When Yab may notify. iOS is asked the first time a task needs the
    /// person, never before (no permission prompt comes by itself).
    enum Notifications: String, CaseIterable, Sendable {
        case needsYou, needsYouAndDone, off
    }

    var appearance: Appearance {
        get { access(keyPath: \.appearance); return values.appearance }
        set { withMutation(keyPath: \.appearance) { values.appearance = newValue }; write(newValue.rawValue, Key.appearance) }
    }
    /// Darken light websites while Yab is dark. A site's own dark theme wins.
    var darkenWebsites: Bool {
        get { access(keyPath: \.darkenWebsites); return values.darkenWebsites }
        set {
            guard newValue != values.darkenWebsites else { return }
            withMutation(keyPath: \.darkenWebsites) { values.darkenWebsites = newValue }
            write(newValue, Key.darkenWebsites)
            NotificationCenter.default.post(name: Self.websiteDarkeningChanged, object: self)
        }
    }
    var pageAnswers: PageAnswers {
        get { access(keyPath: \.pageAnswers); return values.pageAnswers }
        set { withMutation(keyPath: \.pageAnswers) { values.pageAnswers = newValue }; write(newValue.rawValue, Key.pageAnswers) }
    }
    var agent: Agent {
        get { access(keyPath: \.agent); return values.agent }
        set { withMutation(keyPath: \.agent) { values.agent = newValue }; write(newValue.rawValue, Key.agent) }
    }
    /// Paying, posting and canceling are signed by Face ID; off, by the passcode.
    var faceIDForYes: Bool {
        get { access(keyPath: \.faceIDForYes); return values.faceIDForYes }
        set { withMutation(keyPath: \.faceIDForYes) { values.faceIDForYes = newValue }; write(newValue, Key.faceIDForYes) }
    }
    var lockScreen: LockScreen {
        get { access(keyPath: \.lockScreen); return values.lockScreen }
        set { withMutation(keyPath: \.lockScreen) { values.lockScreen = newValue }; write(newValue.rawValue, Key.lockScreen) }
    }
    /// Private opens with Face ID.
    var privateLock: Bool {
        get { access(keyPath: \.privateLock); return values.privateLock }
        set { withMutation(keyPath: \.privateLock) { values.privateLock = newValue }; write(newValue, Key.privateLock) }
    }
    var notifications: Notifications {
        get { access(keyPath: \.notifications); return values.notifications }
        set { withMutation(keyPath: \.notifications) { values.notifications = newValue }; write(newValue.rawValue, Key.notifications) }
    }
    /// Only locally owned tabs with recent native safety proof qualify.
    var autoClearToday: Bool {
        get { access(keyPath: \.autoClearToday); return values.autoClearToday }
        set { withMutation(keyPath: \.autoClearToday) { values.autoClearToday = newValue }; write(newValue, Key.autoClearToday) }
    }
    /// Settings › Today › Your Mac's Tabs: each space's page shows the Mac's
    /// Today under this iPhone's (docs/iphone-mac-tabs.md). Off until turned on.
    var macTabs: Bool {
        get { access(keyPath: \.macTabs); return values.macTabs }
        set { withMutation(keyPath: \.macTabs) { values.macTabs = newValue }; write(newValue, Key.macTabs) }
    }
    /// Settings › Sync › History: pages opened here go to the Mac's history
    /// (its last two weeks, as the Mac's own switch sends its own).
    var syncHistory: Bool {
        get { access(keyPath: \.syncHistory); return values.syncHistory }
        set { withMutation(keyPath: \.syncHistory) { values.syncHistory = newValue }; write(newValue, Key.syncHistory) }
    }
    /// Settings › General › Swipe from Anywhere: a sideways swipe anywhere
    /// on a page goes back or forward; off, only from the screen's edges.
    /// On until turned off.
    var swipeAnywhere: Bool {
        get { access(keyPath: \.swipeAnywhere); return values.swipeAnywhere }
        set { withMutation(keyPath: \.swipeAnywhere) { values.swipeAnywhere = newValue }; write(newValue, Key.swipeAnywhere) }
    }
    /// Settings › General › Open Keyboard at Launch: Yab opens on New Tab's
    /// field with the keyboard up (Field/LaunchKeyboard).
    /// On until turned off.
    var openKeyboardAtLaunch: Bool {
        get { access(keyPath: \.openKeyboardAtLaunch); return values.openKeyboardAtLaunch }
        set { withMutation(keyPath: \.openKeyboardAtLaunch) { values.openKeyboardAtLaunch = newValue }; write(newValue, Key.openKeyboardAtLaunch) }
    }
    /// The welcome was answered: Not Now, or a Mac joined. It doesn't ask again.
    var welcomed: Bool {
        get { access(keyPath: \.welcomed); return values.welcomed }
        set { withMutation(keyPath: \.welcomed) { values.welcomed = newValue }; write(newValue, Key.welcomed) }
    }

    /// The first run's No Mac yet › Use Without a Mac: no code is made and
    /// nothing asks to join until Join Your Mac in Settings › Sync.
    var withoutMac: Bool {
        get { access(keyPath: \.withoutMac); return values.withoutMac }
        set { withMutation(keyPath: \.withoutMac) { values.withoutMac = newValue }; write(newValue, Key.withoutMac) }
    }

    /// Settings › Sync › Turn Off Sync on This iPhone: this iPhone left on
    /// purpose, so a Mac's key in iCloud Keychain doesn't bring it back in by
    /// itself at the next launch; joining again (a code, the Recovery Key)
    /// clears it.
    var syncTurnedOff: Bool {
        get { access(keyPath: \.syncTurnedOff); return values.syncTurnedOff }
        set { withMutation(keyPath: \.syncTurnedOff) { values.syncTurnedOff = newValue }; write(newValue, Key.syncTurnedOff) }
    }

    /// About › Automatically send crash reports: off until turned on; when
    /// off, Yab asks after a new crash (CrashReports).
    var sendCrashReports: Bool {
        get { access(keyPath: \.sendCrashReports); return values.sendCrashReports }
        set { withMutation(keyPath: \.sendCrashReports) { values.sendCrashReports = newValue }; write(newValue, Key.sendCrashReports) }
    }

    /// About › Share daily activity: on unless turned off (DailyActivity).
    var shareDailyActivity: Bool {
        get { access(keyPath: \.shareDailyActivity); return values.shareDailyActivity }
        set { withMutation(keyPath: \.shareDailyActivity) { values.shareDailyActivity = newValue }; write(newValue, Key.shareDailyActivity) }
    }

    /// The values themselves; the properties above say when they are read
    /// and changed, and write each change through to the defaults.
    private struct Values {
        var appearance: Appearance
        var darkenWebsites: Bool
        var pageAnswers: PageAnswers
        var agent: Agent
        var faceIDForYes: Bool
        var lockScreen: LockScreen
        var privateLock: Bool
        var notifications: Notifications
        var welcomed: Bool
        var withoutMac: Bool
        var syncTurnedOff: Bool
        var autoClearToday: Bool
        var macTabs: Bool
        var syncHistory: Bool
        var swipeAnywhere: Bool
        var openKeyboardAtLaunch: Bool
        var sendCrashReports: Bool
        var shareDailyActivity: Bool
    }

    enum Key {
        static let searchEngine = "settings.searchEngine"
        static let customSearch = "settings.customSearch"
        static let appearance = "settings.appearance"
        static let darkenWebsites = "settings.darkenWebsites"
        static let pageAnswers = "settings.pageAnswers"
        static let agent = "settings.agent"
        static let faceIDForYes = "settings.faceIDForYes"
        static let lockScreen = "settings.lockScreen"
        static let privateLock = "settings.privateLock"
        static let notifications = "settings.notifications"
        static let welcomed = "settings.welcomed"
        static let withoutMac = "settings.withoutMac"
        static let syncTurnedOff = "settings.syncTurnedOff"
        static let autoClearToday = "settings.autoClearToday"
        static let macTabs = "settings.macTabs"
        static let syncHistory = "settings.syncHistory"
        static let swipeAnywhere = "settings.swipeAnywhere"
        static let openKeyboardAtLaunch = "settings.openKeyboardAtLaunch"
        static let blocksAds = "settings.blocksAds"
        static let guessesFromWords = "settings.guessesFromWords"
        static let offersAsk = "settings.offersAsk"
        static let offersTask = "settings.offersTask"
        /// The Mac's keys, read where the reports are made.
        static let sendCrashReports = CrashReports.key
        static let shareDailyActivity = DailyActivity.key
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var values: Values
    @ObservationIgnored private var localSearch: SearchEngine.Selection?
    @ObservationIgnored private var importedSearch = SearchEngine.Selection.standard
    @ObservationIgnored private var localBlocksAds: Bool?
    /// On, as on the Mac, until the Mac's own switch says otherwise.
    @ObservationIgnored private var importedBlocksAds = true
    @ObservationIgnored private var importedPausedSites: Set<String> = []
    @ObservationIgnored private var localGuesses: Bool?
    @ObservationIgnored private var localAsk: Bool?
    @ObservationIgnored private var localTask: Bool?
    @ObservationIgnored private var importedGuesses = true
    @ObservationIgnored private var importedAsk = true
    @ObservationIgnored private var importedTask = true

    init(defaults: UserDefaults, supportsOnDeviceAnswers: Bool? = nil) {
        self.defaults = defaults
        tablet = TabletLayoutPreferences(defaults: defaults)
        appIcons = AppIconAccess(defaults: defaults)
        if let raw = defaults.string(forKey: Key.searchEngine) {
            localSearch = SearchEngine.Selection(rawValue: raw, customTemplate: defaults.string(forKey: Key.customSearch) ?? "")
        }
        if defaults.object(forKey: Key.blocksAds) != nil { localBlocksAds = defaults.bool(forKey: Key.blocksAds) }
        if defaults.object(forKey: Key.guessesFromWords) != nil { localGuesses = defaults.bool(forKey: Key.guessesFromWords) }
        if defaults.object(forKey: Key.offersAsk) != nil { localAsk = defaults.bool(forKey: Key.offersAsk) }
        if defaults.object(forKey: Key.offersTask) != nil { localTask = defaults.bool(forKey: Key.offersTask) }
        func read<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        values = Values(
            appearance: read(Key.appearance, Appearance.system),
            darkenWebsites: flag(Key.darkenWebsites, false),
            pageAnswers: read(Key.pageAnswers, (supportsOnDeviceAnswers ?? OnDeviceModel.isDeviceEligible) ? PageAnswers.iPhone : .mac),
            agent: read(Key.agent, Agent.claude),
            faceIDForYes: flag(Key.faceIDForYes, true),
            lockScreen: read(Key.lockScreen, LockScreen.afterFaceID),
            privateLock: flag(Key.privateLock, false),
            notifications: read(Key.notifications, Notifications.needsYou),
            welcomed: flag(Key.welcomed, false),
            withoutMac: flag(Key.withoutMac, false),
            syncTurnedOff: flag(Key.syncTurnedOff, false),
            autoClearToday: flag(Key.autoClearToday, true),
            macTabs: flag(Key.macTabs, false),
            syncHistory: flag(Key.syncHistory, true),
            swipeAnywhere: flag(Key.swipeAnywhere, true),
            openKeyboardAtLaunch: flag(Key.openKeyboardAtLaunch, true),
            sendCrashReports: flag(Key.sendCrashReports, false),
            shareDailyActivity: flag(Key.shareDailyActivity, true))
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// The person's own defaults, or a test run's suite, emptied at launch
    /// unless the run keeps one by name (LaunchOptions.settingsSuite).
    static func launchDefaults(_ options: LaunchOptions = .current) -> UserDefaults {
        guard options.isTestRun else { return .standard }
        if let kept = options.settingsSuite, let suite = UserDefaults(suiteName: kept) { return suite }
        let name = "dev.serafim.fast.iphone.test-settings"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }

    // MARK: - reading

    /// The color scheme Yab's own screens take: the choice, or the system's.
    func colorScheme(systemIsDark: Bool) -> ColorScheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .system: systemIsDark ? .dark : .light
        }
    }

    /// Whether words typed in a field ask for Settings: three letters or more
    /// of "settings" or "preferences", the way ⌘T on the Mac
    /// finds its settings. The field puts Settings first then, key go.
    nonisolated static func wantsSettings(_ words: String) -> Bool {
        let q = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 3 else { return false }
        return ["settings", "preferences"].contains { $0.hasPrefix(q) }
    }

    /// This build's version, as About Yab says it: 0.0.1.
    nonisolated static func version(_ bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    nonisolated static func build(_ bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// The row the field shows for the word "settings" (settings.2): the field
/// branch draws it, these are its words and glyph.
enum SettingsFieldRow {
    static let title = "Settings"
    static let subtitle = "Yab on this \(DeviceWord.name)"
    static let glyph = GlyphName.settingsGear1
    static let key = "go"
}

extension UIUserInterfaceStyle {
    init(_ appearance: SettingsStore.Appearance) {
        switch appearance {
        case .system: self = .unspecified
        case .light: self = .light
        case .dark: self = .dark
        }
    }
}

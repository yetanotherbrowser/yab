import SwiftUI
import UIKit

/// The pages a Settings row opens.
enum SettingsPageID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mac, agent, aboutPage, everythingElse, defaultBrowser, today
    case faceID, lockScreen, privateTabs, notifications, appearance, appIcon, about
    case general, search, tabs, ai, spaces, sync, passwords, autofill, privacy, feedback
    /// Chrome extensions (Extensions/ExtensionHost): on or off, and more from the store.
    case extensions
    /// History's own screen (History/HistoryPage), not rows.
    case history
    /// Sync's Recovery Key, shown once Face ID says yes (SyncRecovery).
    case recoveryKey

    var id: String { rawValue }
}

/// What Settings needs to know about the app to say its rows: the Mac, the
/// build, the default browser. Plain values, so the words can be checked
/// without an app around them.
struct SettingsContext: Sendable {
    var isPad = false
    var macName: String
    var macAsleep: Bool
    /// What the one Mac is doing, said on its row when it is down (MacWords).
    var macState: MacState?
    /// This iPhone has joined a Mac.
    var hasMac: Bool
    /// Yab on that Mac opens as its person logs in, as the Mac says in sync
    /// (Settings › General, Open at Login there).
    var macOpensAtLogin: Bool
    var version: String
    var build: String
    /// Yab is the browser links from other apps open in.
    /// Nil until iOS or a link has said (DefaultBrowser).
    var yabIsDefaultBrowser: Bool?
    /// This build sends to a site (Reports.site): About has its switches
    /// for crash reports and daily activity.
    var reportsAvailable: Bool
    /// The ad blocker's lists didn't build, and nothing is blocked (Shield).
    var shieldTrouble: String?
    /// This iPhone is in sync: Settings › Sync lists the account's devices,
    /// shows the Recovery Key and can turn sync off here.
    var inSync: Bool
    /// The account's devices, this iPhone first (SyncBridge.devices).
    var devices: [SettingsDevice]
    /// The Recovery Key, once Face ID said yes on its page.
    var recoveryKey: String?

    @MainActor
    init(app: AppModel) {
        self.init(app: app, ui: .shared)
    }

    @MainActor
    init(app: AppModel, ui: SettingsUI) {
        macName = app.macName
        macAsleep = app.browser.macAsleep
        macState = app.sync.macs.first?.state
        hasMac = app.hasMac && !ui.noMac
        macOpensAtLogin = app.macOpensAtLogin
        version = SettingsStore.version()
        build = SettingsStore.build()
        yabIsDefaultBrowser = ui.assumeDefaultBrowser ? true : ui.yabIsDefaultBrowser
        reportsAvailable = ui.assumeReports || Reports.site != nil
        shieldTrouble = app.pages.shield?.trouble
        inSync = app.sync.phase == .on
        devices = SettingsDevice.list(app.sync.devices, own: app.sync.ownDevice, now: Date(), macs: app.sync.macs)
        recoveryKey = ui.recoveryShown
        isPad = UIDevice.current.userInterfaceIdiom == .pad
    }

    init(macName: String = "MacBook Pro", macAsleep: Bool = false, hasMac: Bool = true, macOpensAtLogin: Bool = true,
         version: String = "0.0.1", build: String = "1", yabIsDefaultBrowser: Bool? = true, reportsAvailable: Bool = true,
         shieldTrouble: String? = nil, inSync: Bool = false, devices: [SettingsDevice] = [], recoveryKey: String? = nil) {
        self.macName = macName
        self.macAsleep = macAsleep
        self.hasMac = hasMac
        self.macOpensAtLogin = macOpensAtLogin
        self.version = version
        self.build = build
        self.yabIsDefaultBrowser = yabIsDefaultBrowser
        self.reportsAvailable = reportsAvailable
        self.shieldTrouble = shieldTrouble
        self.inSync = inSync
        self.devices = devices
        self.recoveryKey = recoveryKey
    }

    /// Whether Yab is the default browser, as far as is known (DefaultBrowser).
    @MainActor
    static func checkDefaultBrowser(_ ui: SettingsUI, force: Bool = false) {
        ui.yabIsDefaultBrowser = DefaultBrowser.refresh(force: force)
    }
}

extension AppModel {
    /// This iPhone has a Mac: in sync (M7), else what the world says (test
    /// worlds and named states have no sync).
    var hasMac: Bool { sync.phase == .on || world.mac.joined }
    /// The Mac's name: the account's Mac first up in sync, else the world's.
    var macName: String { sync.macs.first?.name ?? world.mac.name }
    /// Yab opens on that Mac as its person logs in: as the Mac says in sync.
    /// A test world's stand-in Mac always does.
    var macOpensAtLogin: Bool {
        guard sync.phase == .on else { return true }
        guard let engine = sync.engine, let mac = sync.macs.first else { return false }
        return engine.opensAtLogin(mac.id)
    }
}

/// One row: its glyph, words, the value on the right, and what a tap does.
struct SettingsRowModel: Identifiable {
    enum Icon {
        case glyph(GlyphName)
        /// The agent's face.
        case face
        /// Yab's mark, rounded.
        case mark
    }

    enum Kind {
        /// Opens its page (chevron).
        case page(SettingsPageID)
        /// Opens joining a Mac (chevron).
        case join
        /// One of a page's choices (a tick when chosen).
        case choice(selected: Bool, choose: @MainActor () -> Void)
        case toggle(Binding<Bool>)
        /// Says something; no tap.
        case info
        /// Does something now (an action word, no chevron).
        case action(@MainActor () -> Void)
    }

    let id: String
    var icon: Icon?
    var title: String
    var value: String?
    var kind: Kind
    /// Its title in red: an action that ends something (Turn Off Sync).
    var danger = false
    /// Words of several lines, given air above and below (the Recovery Key).
    var spacious = false

    var isSelected: Bool {
        if case let .choice(selected, _) = kind { return selected }
        return false
    }
}

struct SettingsSectionModel: Identifiable {
    let id: String
    var title: String?
    var rows: [SettingsRowModel]
    var footer: String?
}

/// Settings' words, as the prototype writes them (screens-settings.md), and
/// its pages' from the page's "Logic".
@MainActor
struct SettingsContent {
    let store: SettingsStore
    let context: SettingsContext
    /// Default Browser's Open iOS Settings.
    var openSystemSettings: @MainActor () -> Void = {}
    /// Privacy's Clear History and Website Data: its confirmation first.
    var askClearData: @MainActor () -> Void = {}
    /// The ad blocker's Try Again: its lists compiled again (Shield).
    var retryShield: @MainActor () -> Void = { Shield.shared.compile() }
    /// Sync's Turn Off Sync on This iPhone: its question first.
    var askSyncOff: @MainActor () -> Void = {}
    /// The Recovery Key's Show with Face ID, and its Copy.
    var revealRecovery: @MainActor () -> Void = {}
    var copyRecovery: @MainActor () -> Void = {}
    /// General's Show Welcome Again: the first run from its first page.
    var showWelcome: @MainActor () -> Void = {}
    var tabletLayout: TabletLayoutPreferences? = nil

    // MARK: - values

    var macValue: String { context.macState.map { $0.isUp ? "Online" : MacWords.state($0, now: Date()) } ?? (context.macAsleep ? "Asleep" : "Online") }
    /// With no Mac yet, the agent has nowhere to run: it says so, as
    /// Everything else does.
    var agentValue: String { context.hasMac ? "\(store.agent.name) · on your Mac" : "Needs your Mac" }
    var pageAnswersValue: String { store.pageAnswers == .iPhone ? "This \(DeviceWord.name)" : "Your Mac" }
    var everythingElseValue: String { context.hasMac ? store.agent.name : "Needs your Mac" }
    var defaultBrowserValue: String {
        switch context.yabIsDefaultBrowser {
        case true?: "Yab"
        case false?: "Not Yet"
        case nil: ""
        }
    }
    var todayValue: String { "This \(DeviceWord.name)’s own" }
    var faceIDValue: String { store.faceIDForYes ? "On" : "Off" }
    var lockScreenValue: String { Self.words(store.lockScreen) }
    var privateTabsValue: String { "Not kept" }
    var notificationsValue: String { Self.words(store.notifications) }
    var appearanceValue: String { Self.words(store.appearance) }
    /// Under the blocker's switch: whether it is on, or what is wrong (the
    /// Mac's words).
    var shieldFooter: String {
        if let trouble = context.shieldTrouble { return "\(trouble). Nothing is blocked until this clears." }
        return store.blocksAds
            ? "Ads and trackers never load. If a site breaks, turn blocking off for it in its Site Settings."
            : "Off. Every site loads everything it asks for."
    }

    nonisolated static func words(_ lock: SettingsStore.LockScreen) -> String {
        switch lock {
        case .afterFaceID: "After Face ID"
        case .never: "Never"
        }
    }

    nonisolated static func words(_ notifications: SettingsStore.Notifications) -> String {
        switch notifications {
        case .needsYou: "Needs you"
        case .needsYouAndDone: "Needs you and done"
        case .off: "Off"
        }
    }

    nonisolated static func words(_ appearance: SettingsStore.Appearance) -> String {
        switch appearance {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    nonisolated static func title(_ page: SettingsPageID) -> String {
        switch page {
        case .mac: "Your Mac"
        case .agent: "Agent"
        case .aboutPage: "About a page"
        case .everythingElse: "Everything else"
        case .defaultBrowser: "Default Browser"
        case .today: "Today"
        case .faceID: "Face ID for Pay and Post"
        case .lockScreen: "Lock Screen Details"
        case .privateTabs: "Private Tabs"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .appIcon: "App Icon"
        case .about: "About"
        case .general: "General"
        case .search: "Search"
        case .tabs: "Tabs"
        case .ai: "AI"
        case .spaces: "Spaces"
        case .sync: "Sync"
        case .passwords: "Passwords"
        case .autofill: "Autofill"
        case .privacy: "Privacy"
        case .feedback: "Send Feedback"
        case .extensions: "Extensions"
        case .history: "History"
        case .recoveryKey: "Recovery Key"
        }
    }

    // MARK: - the sheet

    /// The earlier detail groups remain the same preference rows. The new
    /// SettingsIndex is the root; these groups supply the pushed pages.
    var root: [SettingsSectionModel] {
        let mac: SettingsRowModel = context.hasMac
            ? row("mac", .glyph(.macbook), context.macName, macValue, .page(.mac))
            : SettingsRowModel(id: "join", icon: .glyph(.macbook), title: "Join Your Mac", value: nil, kind: .join)
        return [
            SettingsSectionModel(id: "mac", title: "Your Mac", rows: [
                mac,
                row("agent", .face, "Agent", agentValue, .page(.agent)),
            ], footer: context.hasMac
                ? "Tasks run in Yab on your Mac, with your sign-ins. The \(DeviceWord.name) sends codes and the yes signed by Face ID."
                : "Join Yab on your Mac and tasks run there, with your sign-ins. The \(DeviceWord.name) sends codes and the yes signed by Face ID."),
            SettingsSectionModel(id: "answers", title: "Answers", rows: [
                row("aboutPage", .glyph(.sparkle), "About a page", pageAnswersValue, .page(.aboutPage)),
                row("everythingElse", .face, "Everything else", everythingElseValue, .page(.everythingElse)),
            ]),
            SettingsSectionModel(id: "tabs", title: "Tabs", rows: [
                row("defaultBrowser", .glyph(.globe), "Default Browser", defaultBrowserValue, .page(.defaultBrowser)),
                row("today", .glyph(.squareBehindSquare1), "Today", todayValue, .page(.today)),
            ], footer: "Spaces, pins and kept tabs are the same on your Mac; Today is this \(DeviceWord.name)’s own. Mail stays in Yab on your Mac."),
            SettingsSectionModel(id: "privacy", title: "Privacy", rows: [
                row("faceID", .glyph(.faceId), "Face ID for Pay and Post", faceIDValue, .page(.faceID)),
                row("lockScreen", .glyph(.lock), "Lock Screen Details", lockScreenValue, .page(.lockScreen)),
                row("privateTabs", .glyph(.incognito), "Private Tabs", privateTabsValue, .page(.privateTabs)),
                row("notifications", .glyph(.bellCheck), "Notifications", notificationsValue, .page(.notifications)),
            ]),
            SettingsSectionModel(id: "yab", title: nil, rows: [
                row("appearance", .glyph(.settingsGear1), "Appearance", appearanceValue, .page(.appearance)),
                row("about", .mark, "About Yab", context.version, .page(.about)),
            ]),
        ]
    }

    // MARK: - the pages

    func sections(_ page: SettingsPageID) -> [SettingsSectionModel] {
        let store = store
        switch page {
        case .general:
            return [SettingsSectionModel(id: "general", title: nil, rows: [
                row("defaultBrowser", .glyph(.globe), "Default Browser", defaultBrowserValue, .page(.defaultBrowser)),
                row("notifications", .glyph(.bellCheck), "Notifications", notificationsValue, .page(.notifications)),
            ]), SettingsSectionModel(id: "general.swipe", title: nil, rows: [
                SettingsRowModel(id: "general.swipeAnywhere", icon: .glyph(.chevronLeft), title: "Swipe from Anywhere", value: nil,
                                 kind: .toggle(Binding(get: { store.swipeAnywhere }, set: { store.swipeAnywhere = $0 }))),
            ], footer: "Swipe right anywhere on a page to go back, left to go forward. Off, only from the screen’s edges."), SettingsSectionModel(id: "general.launch", title: nil, rows: [
                SettingsRowModel(id: "general.openKeyboardAtLaunch", icon: .glyph(.magnifyingGlass), title: "Open Keyboard at Launch", value: nil,
                                 kind: .toggle(Binding(get: { store.openKeyboardAtLaunch }, set: { store.openKeyboardAtLaunch = $0 }))),
            ], footer: "Yab opens ready to type. A page you were just reading stays in front."), SettingsSectionModel(id: "general.welcome", title: nil, rows: [
                SettingsRowModel(id: "general.showWelcome", icon: nil, title: "Show Welcome Again", value: nil, kind: .action(showWelcome)),
            ], footer: "Yab\u{2019}s first pages once more, from the name to the field. Your tabs, spaces and sync stay as they are.")]
        case .search:
            let selection = store.searchSelection
            return [SettingsSectionModel(id: "search", title: "Search Engine", rows: store.searchEngines.map { engine in
                let name = engine == .custom ? store.customSearchSelection.name : engine.title
                return choice("search.engine.\(engine.rawValue)", name, selection.engine == engine) { store.chooseSearchEngine(engine) }
            }, footer: selection.fallbackNote ?? "Type a web address to open a page, or words to search \(selection.name). This choice is kept on this \(DeviceWord.name); your Mac's setting is unchanged."),
            SettingsSectionModel(id: "search.return", title: "Return", rows: [
                SettingsRowModel(id: "search.guessesFromWords", icon: .glyph(.sparkle), title: "Guess from Your Words", value: nil,
                                 kind: .toggle(Binding(get: { store.guessesFromWords }, set: { store.guessesFromWords = $0 }))),
            ], footer: "Detect questions and tasks automatically. When off, Return searches \(selection.name)."),
            SettingsSectionModel(id: "search.under", title: "Under Your Words", rows: [
                SettingsRowModel(id: "search.offersAsk", icon: .glyph(.sparkle), title: "Ask \(store.agent.name)", value: nil,
                                 kind: .toggle(Binding(get: { store.offersAsk }, set: { store.offersAsk = $0 }))),
                SettingsRowModel(id: "search.offersTask", icon: .face, title: "Task for \(store.agent.name)", value: nil,
                                 kind: .toggle(Binding(get: { store.offersTask }, set: { store.offersTask = $0 }))),
            ], footer: "Rows shown under the search as you type. Your Mac's Settings › Field sets them until you change them here.")]
        case .tabs:
            return [SettingsSectionModel(id: "tabs", title: nil, rows: [
                row("today", .glyph(.squareBehindSquare1), "Today", todayValue, .page(.today)),
                row("privateTabs", .glyph(.incognito), "Private Tabs", privateTabsValue, .page(.privateTabs)),
            ], footer: "Pins, kept tabs, folders and Today belong to their space.")]
        case .ai:
            return [SettingsSectionModel(id: "ai.answers", title: "Answers", rows: [
                row("aboutPage", .glyph(.sparkle), "About a page", pageAnswersValue, .page(.aboutPage)),
                row("everythingElse", .face, "Everything else", everythingElseValue, .page(.everythingElse)),
                row("agent", .face, "Agent", agentValue, .page(.agent)),
            ]), SettingsSectionModel(id: "ai.approvals", title: "Approvals", rows: [
                row("faceID", .glyph(.faceId), "Face ID for Pay and Post", faceIDValue, .page(.faceID)),
            ])]
        case .spaces:
            // The actual space list and its live metadata are SettingsSpacesView.
            return [SettingsSectionModel(id: "spaces", title: nil, rows: [
                SettingsRowModel(id: "spaces.state", icon: .glyph(.window), title: "Spaces", value: nil, kind: .info),
            ], footer: "Sets of tabs, each with its pins, its color and whose sign-ins.")]
        case .sync:
            // In sync: every device of the account, this iPhone first, each
            // saying how it is, as the Mac's Settings › Sync does.
            let listed = context.inSync && !context.devices.isEmpty
            let join = SettingsRowModel(id: "sync", icon: .glyph(.arrowRotateClockwise), title: "Join Another Device", value: nil, kind: .join)
            let rows: [SettingsRowModel]
            if listed {
                rows = context.devices.map { device in
                    SettingsRowModel(id: "sync.device.\(device.id)", icon: .glyph(device.isPhone ? .phone : .macbook),
                                     title: device.name, value: device.words, kind: .info)
                } + [join]
            } else if context.hasMac {
                rows = [row("mac", .glyph(.macbook), context.macName, macValue, .page(.mac)), join]
            } else {
                rows = [SettingsRowModel(id: "join", icon: .glyph(.macbook), title: "Join Your Mac", value: nil, kind: .join)]
            }
            let devices = SettingsSectionModel(id: "sync", title: listed ? "Devices" : nil, rows: rows,
                                               footer: "Your spaces, tabs and chats sync end to end encrypted, so only your devices can read them.")
            guard context.hasMac else { return [devices] }
            // The Mac's own switch (Settings › Sync, History) sends its last
            // two weeks; this one sends this iPhone's.
            let history = SettingsSectionModel(id: "sync.history", title: nil, rows: [
                SettingsRowModel(id: "sync.history", icon: .glyph(.history), title: "History", value: nil,
                                 kind: .toggle(Binding(get: { store.syncHistory }, set: { store.syncHistory = $0 }))),
            ], footer: "Pages you open on this \(DeviceWord.name) go to History on your Mac for two weeks. Private tabs never do.")
            // The Recovery Key's page stays reachable (Settings' search finds
            // it); out of sync it says to join first.
            let recovery = SettingsSectionModel(id: "sync.recovery", title: nil, rows: [
                row("recoveryKey", .glyph(.key1), "Recovery Key", nil, .page(.recoveryKey)),
            ], footer: "Face ID shows it. With it, any device can join your sync, even without your Mac.")
            guard context.inSync else { return [devices, history, recovery] }
            return [devices, history, recovery,
                    SettingsSectionModel(id: "sync.off", title: nil, rows: [
                        SettingsRowModel(id: "sync.off", icon: nil, title: "Turn Off Sync on This \(DeviceWord.name)", value: nil,
                                         kind: .action(askSyncOff), danger: true),
                    ], footer: "Your Mac and your other devices go on syncing. What is on this \(DeviceWord.name) stays as it is.")]
        case .recoveryKey:
            guard let key = context.recoveryKey else {
                return [SettingsSectionModel(id: "recovery", title: nil, rows: [
                    SettingsRowModel(id: "recovery.show", icon: .glyph(.faceId), title: "Show with Face ID", value: nil,
                                     kind: .action(revealRecovery)),
                ], footer: context.inSync
                    ? "Face ID or your passcode shows the key. Nobody else can see it, Yab included."
                    : "Join your Mac first: the key is your sync account's.")]
            }
            return [SettingsSectionModel(id: "recovery", title: nil, rows: [
                SettingsRowModel(id: "recovery.key", icon: .glyph(.key1), title: key, value: nil, kind: .info, spacious: true),
                SettingsRowModel(id: "recovery.copy", icon: nil, title: "Copy", value: nil, kind: .action(copyRecovery)),
            ], footer: "Keep it somewhere safe, apart from your devices. With it, any device can join your sync, so never share it.")]
        case .passwords:
            return [SettingsSectionModel(id: "passwords", title: nil, rows: [
                SettingsRowModel(id: "passwords.provider", icon: .glyph(.key1), title: "Passwords and Passkeys", value: "Managed by iOS", kind: .info),
                SettingsRowModel(id: "passwords.settings", icon: nil, title: "Open iOS Settings", value: nil, kind: .action(openSystemSettings)),
            ], footer: "Use your configured iOS AutoFill provider on supported sign-in fields. Passwords are not stored in a Yab vault on this \(DeviceWord.name).")]
        case .autofill:
            return [SettingsSectionModel(id: "autofill", title: nil, rows: [
                SettingsRowModel(id: "autofill.provider", icon: .glyph(.creditCard1), title: "AutoFill", value: "Managed by iOS", kind: .info),
                SettingsRowModel(id: "autofill.settings", icon: nil, title: "Open iOS Settings", value: nil, kind: .action(openSystemSettings)),
            ], footer: "Use the iOS keyboard's offered information on supported fields. A saved profile for filling whole forms is not available on this \(DeviceWord.name) yet.")]
        case .privacy:
            // The blocker first, as on the Mac: one switch; the site that
            // breaks is turned off in its own Site Settings.
            var shield = [SettingsRowModel(id: "privacy.shield", icon: .glyph(.shieldCheck), title: "Block ads and trackers", value: nil,
                                           kind: .toggle(Binding(get: { store.blocksAds }, set: { store.blocksAds = $0 })))]
            if context.shieldTrouble != nil {
                shield.append(SettingsRowModel(id: "privacy.shield.retry", icon: nil, title: "Try Again", value: nil,
                                               kind: .action(retryShield)))
            }
            return [SettingsSectionModel(id: "privacy.shield", title: nil, rows: shield, footer: shieldFooter),
                    SettingsSectionModel(id: "privacy", title: nil, rows: [
                row("history", .glyph(.history), "History", nil, .page(.history)),
                row("privateTabs", .glyph(.incognito), "Private Tabs", privateTabsValue, .page(.privateTabs)),
                row("faceID", .glyph(.faceId), "Face ID for Pay and Post", faceIDValue, .page(.faceID)),
                row("lockScreen", .glyph(.lock), "Lock Screen Details", lockScreenValue, .page(.lockScreen)),
                row("notifications", .glyph(.bellCheck), "Notifications", notificationsValue, .page(.notifications)),
            ], footer: context.reportsAvailable ? Self.sentFooter : nil),
            SettingsSectionModel(id: "privacy.data", title: nil, rows: [
                SettingsRowModel(id: "privacy.clearData", icon: nil, title: "Clear History and Website Data", value: nil,
                                 kind: .action(askClearData)),
            ], footer: "History, cookies and other website data on this \(DeviceWord.name). Your tabs and what syncs with your Mac stay.")]
        case .extensions:
            let host = ExtensionHost.shared
            let rows = host.installed.map { item in
                SettingsRowModel(id: "extensions.\(item.id)", icon: .glyph(.plugin1), title: item.name,
                                 value: host.problems(item.id).first,
                                 kind: .toggle(Binding(get: { host.installed.first { $0.id == item.id }?.enabled ?? false },
                                                       set: { host.setEnabled(item.id, $0) })))
            }
            // No way to the store here (register 617): adding an extension
            // is on the Mac, named as its menus name it (row 2604).
            let get = SettingsSectionModel(id: "extensions.get", title: nil, rows: [],
                                           footer: "Add extensions on your Mac, in Yab › Settings › Extensions › Add Extension. They run on every page except Private tabs.")
            return (rows.isEmpty ? [] : [SettingsSectionModel(id: "extensions", title: nil, rows: rows, footer: nil)]) + [get]
        case .feedback:
            return [SettingsSectionModel(id: "feedback", title: nil, rows: [
                SettingsRowModel(id: "feedback.draft", icon: .glyph(.chatBubble7), title: "Write Feedback", value: nil, kind: .info),
            ], footer: "Describe what happened, then review the draft in Mail before sending it.")]
        case .mac:
            // The Mac and its state, the agent on it (Your Mac › Agent, which
            // Everything else points to), then Sync.
            return [
                SettingsSectionModel(id: "mac", title: nil, rows: [
                    SettingsRowModel(id: "mac.state", icon: .glyph(.macbook), title: context.macName, value: macValue, kind: .info),
                ], footer: context.macOpensAtLogin
                    ? "Your Mac answers while Yab runs there, and Yab opens hidden when you log in. Tasks wait while it sleeps and go on when it wakes."
                    : "Your Mac answers while Yab runs there. To keep it ready, turn on Open at Login in Yab’s Settings › General on your Mac. Tasks wait while it sleeps and go on when it wakes."),
                agentSection(id: "mac.agent", title: "Agent"),
                SettingsSectionModel(id: "sync", title: "Sync", rows: [
                    SettingsRowModel(id: "sync", icon: .glyph(.arrowRotateClockwise), title: "Sync", value: nil, kind: .join),
                ], footer: "Tabs, chats and tasks sync end to end encrypted: Yab can’t read them."),
            ]
        case .agent:
            return [agentSection(id: "agent", title: nil)]
        case .aboutPage:
            return [
                SettingsSectionModel(id: "aboutPage", title: nil, rows: [
                    choice("aboutPage.iPhone", "This \(DeviceWord.name)", store.pageAnswers == .iPhone) { store.pageAnswers = .iPhone },
                    choice("aboutPage.mac", "Your Mac", store.pageAnswers == .mac) { store.pageAnswers = .mac },
                ], footer: "On this \(DeviceWord.name), a question about a page is answered at once, and the page stays here. On your Mac, \(store.agent.name) answers with your sign-ins."),
            ]
        case .everythingElse:
            return [
                SettingsSectionModel(id: "everythingElse", title: nil, rows: [
                    SettingsRowModel(id: "everythingElse.agent", icon: .face, title: store.agent.name, value: "On your Mac", kind: .info),
                ], footer: "Follow-ups, questions without a page and tasks go to \(store.agent.name) on your Mac, with your sign-ins. Your Mac › Agent chooses who."),
            ]
        case .defaultBrowser:
            let now = context.yabIsDefaultBrowser == true
                ? "Links from other apps open in Yab, as a new tab."
                : "Choose Yab in Settings › Apps › Default Apps › Browser App, and links from other apps open here as a new tab."
            return [
                SettingsSectionModel(id: "defaultBrowser", title: nil, rows: [
                    SettingsRowModel(id: "defaultBrowser.state", icon: .glyph(.globe), title: "Default Browser", value: defaultBrowserValue, kind: .info),
                ], footer: now),
                SettingsSectionModel(id: "defaultBrowser.open", title: nil, rows: [
                    SettingsRowModel(id: "defaultBrowser.settings", icon: nil, title: "Open iOS Settings", value: nil, kind: .action {
                        DefaultBrowser.asksOnReturn = true
                        openSystemSettings()
                    }),
                ]),
            ]
        case .today:
            return [
                SettingsSectionModel(id: "today", title: nil, rows: [
                    SettingsRowModel(id: "today.state", icon: .glyph(.squareBehindSquare1), title: "Today", value: todayValue, kind: .info),
                    SettingsRowModel(id: "today.autoClear", icon: .glyph(.broom), title: "Clear after 12 hours", value: nil,
                                     kind: .toggle(Binding(get: { store.autoClearToday }, set: { store.autoClearToday = $0 }))),
                ], footer: "Clear removes only inactive tabs created on this \(DeviceWord.name) with verified safe pages. The page in front, pins, kept tabs, drafts, media, tasks, shared and unverified pages stay. Undo is available for 6 seconds. Automatic Clear checks actual activity after 12 hours when Yab returns or you change spaces; it does not clear unknown Mac tabs."),
                SettingsSectionModel(id: "today.mac", title: nil, rows: [
                    SettingsRowModel(id: "today.macTabs", icon: .glyph(.macbook), title: "Your Mac’s Tabs", value: nil,
                                     kind: .toggle(Binding(get: { store.macTabs }, set: { store.macTabs = $0 }))),
                ], footer: "See what is open on \(context.macName) and open it here. Your Today stays this \(DeviceWord.name)’s own."),
            ]
        case .faceID:
            return [
                SettingsSectionModel(id: "faceID", title: nil, rows: [
                    SettingsRowModel(id: "faceID.toggle", icon: .glyph(.faceId), title: "Face ID for Pay and Post", value: nil,
                                     kind: .toggle(Binding(get: { store.faceIDForYes }, set: { store.faceIDForYes = $0 }))),
                ], footer: "Paying, posting and canceling wait for your yes, signed on this \(DeviceWord.name). Your Mac checks the signature, then presses the site’s own button; Claude can’t press it. Off, the yes takes your passcode."),
            ]
        case .lockScreen:
            return [
                SettingsSectionModel(id: "lockScreen", title: nil, rows: SettingsStore.LockScreen.allCases.map { lock in
                    choice("lockScreen.\(lock.rawValue)", Self.words(lock), store.lockScreen == lock) { store.lockScreen = lock }
                }, footer: Self.footer(store.lockScreen)),
            ]
        case .privateTabs:
            return [
                SettingsSectionModel(id: "privateTabs", title: nil, rows: [
                    SettingsRowModel(id: "privateTabs.state", icon: .glyph(.incognito), title: "Private Tabs", value: privateTabsValue, kind: .info),
                ], footer: "Private tabs stay in memory on this \(DeviceWord.name), with no history or sync."),
            ]
        case .notifications:
            return [
                SettingsSectionModel(id: "notifications", title: nil, rows: SettingsStore.Notifications.allCases.map { level in
                    choice("notifications.\(level.rawValue)", Self.words(level), store.notifications == level) { store.notifications = level }
                }, footer: Self.footer(store.notifications)),
            ]
        case .appearance:
            var sections = [
                SettingsSectionModel(id: "appearance", title: nil, rows: SettingsStore.Appearance.allCases.map { look in
                    choice("appearance.\(look.rawValue)", Self.words(look), store.appearance == look) { store.appearance = look }
                }, footer: "System follows your \(DeviceWord.name), light by day and dark at night if it is set so."),
                SettingsSectionModel(id: "websites", title: "Websites", rows: [
                    SettingsRowModel(id: "appearance.darkenWebsites", icon: .glyph(.moon), title: "Darken Websites", value: nil,
                                     kind: .toggle(Binding(get: { store.darkenWebsites }, set: { store.darkenWebsites = $0 }))),
                ], footer: "Light websites become dark when Yab is dark. Websites with their own dark look keep it."),
            ]
            if context.isPad {
                let layout = tabletLayout ?? store.tablet
                sections.append(SettingsSectionModel(id: "appearance.browser", title: "Browser", rows: [
                    SettingsRowModel(id: "appearance.sidebar", icon: nil, title: "Show Sidebar", value: nil,
                                     kind: .toggle(Binding(get: { layout.sidebarShown }, set: { layout.sidebarShown = $0 }))),
                    SettingsRowModel(id: "appearance.addressBars", icon: nil, title: "Show Address Bars", value: nil,
                                     kind: .toggle(Binding(get: { layout.addressBars }, set: { layout.addressBars = $0 }))),
                    SettingsRowModel(id: "appearance.pageFrame", icon: nil, title: "Frame Page with Sidebar", value: nil,
                                     kind: .toggle(Binding(get: { layout.framed }, set: { layout.framed = $0 }))),
                ]))
            }
            return sections
        case .appIcon, .history:
            // Their own pages (AppIconPickerView, HistoryPage), no rows.
            return []
        case .about:
            let version = SettingsSectionModel(id: "about", title: nil, rows: [
                SettingsRowModel(id: "about.version", icon: .mark, title: "Yab", value: "\(context.version) (\(context.build))", kind: .info),
            ], footer: "yet another browser. Tabs, chats and tasks with Yab on your Mac.")
            guard context.reportsAvailable else { return [version] }
            // As on the Mac's About: crash reports off until said, daily
            // activity on until turned off.
            return [
                version,
                SettingsSectionModel(id: "about.crashes", title: nil, rows: [
                    SettingsRowModel(id: "about.crashes", icon: nil, title: "Automatically send crash reports", value: nil,
                                     kind: .toggle(Binding(get: { store.sendCrashReports }, set: { on in
                                         store.sendCrashReports = on
                                         if on { Reports.offerCrashReports() }
                                     }))),
                ], footer: Self.crashesFooter),
                SettingsSectionModel(id: "about.activity", title: nil, rows: [
                    SettingsRowModel(id: "about.activity", icon: nil, title: "Share daily activity", value: nil,
                                     kind: .toggle(Binding(get: { store.shareDailyActivity }, set: { on in
                                         store.shareDailyActivity = on
                                         if on { DailyActivity.shared.sendIfDue() }
                                     }))),
                ], footer: Self.activityFooter),
            ]
        }
    }

    // MARK: - what Yab sends

    /// The Mac's words for its switches, with iOS and the iPhone in them.
    nonisolated static let crashesFooter = "What crashed and why, where Yab stopped responding, the versions of Yab and iOS and the \(DeviceWord.name) model. Never pages or anything you typed. When off, Yab asks after a new crash."
    nonisolated static let activityFooter = "A random ID for this installation counts the days Yab is active on this \(DeviceWord.name). No pages, searches or browsing history."
    /// Privacy says what goes at all, and where it is turned off.
    nonisolated static let sentFooter = "Yab sends no pages, searches or browsing history. A daily count with a random ID for this installation, and crash reports only if you say yes: both in About."

    // MARK: - words that follow the choice

    /// What the ticked choice means, under the choices.
    nonisolated static func footer(_ lock: SettingsStore.LockScreen) -> String {
        switch lock {
        case .afterFaceID:
            "A locked \(DeviceWord.name) shows a task by its name, never an amount or who it goes to. After Face ID, the Lock Screen and the Dynamic Island show them; its buttons work after Face ID too."
        case .never:
            "The Lock Screen and the Dynamic Island show a task by its name only, never an amount or who it goes to, even after Face ID. Open Yab to see them."
        }
    }

    nonisolated static func footer(_ notifications: SettingsStore.Notifications) -> String {
        switch notifications {
        case .needsYou:
            "Only when a task needs you: a code or a yes. iOS asks to let Yab notify you the first time a task needs you, never before."
        case .needsYouAndDone:
            "When a task needs you, a code or a yes, and when one is done. iOS asks to let Yab notify you the first time, never before."
        case .off:
            "No notifications. A task that needs you waits on the Now line until you open Yab."
        }
    }

    // MARK: - building rows

    /// The agent on the Mac, one to choose: its own page, and a section of
    /// the Mac's.
    private func agentSection(id: String, title: String?) -> SettingsSectionModel {
        let store = store
        return SettingsSectionModel(id: id, title: title, rows: SettingsStore.Agent.allCases.map { agent in
            choice("\(id).\(agent.rawValue)", agent.name, store.agent == agent) { store.agent = agent }
        }, footer: "Tasks, and everything you ask without a page, go to this agent on your Mac, with your plan and your sign-ins.")
    }

    private func row(_ id: String, _ icon: SettingsRowModel.Icon?, _ title: String, _ value: String?,
                     _ kind: SettingsRowModel.Kind) -> SettingsRowModel {
        SettingsRowModel(id: id, icon: icon, title: title, value: value, kind: kind)
    }

    private func choice(_ id: String, _ title: String, _ selected: Bool, _ choose: @escaping @MainActor () -> Void) -> SettingsRowModel {
        SettingsRowModel(id: id, icon: nil, title: title, value: nil, kind: .choice(selected: selected, choose: choose))
    }
}

import AppKit
import SwiftUI
import WebKit
import Combine
import CryptoKit

// Chrome extensions, on WebKit.
//
// The engine is Apple's: WKWebExtension, the same one Safari runs its
// extensions on, reading the same manifest.json a Chrome extension ships.
// What is here is the browser's half of the contract, which tabs exist and
// which one is in front, what a new tab or a popup means in this window, who
// is asked for a permission and how, plus the Chrome Web Store install
// (Crx.swift) and the APIs WebKit doesn't have, filled in natively
// (ExtensionShims.swift, ExtensionNative.swift).
//
// Tab is a Swift class and the protocols are Objective-C ones, so each tab
// is represented to WebKit by a small adapter kept here. A tab can be in the
// row with no web view at all, asleep, or put down, and is reported with
// none; `built` is read, never `web`, which would make one.

/// One installed extension, as the list in Settings shows it.
struct Installed: Codable, Identifiable, Equatable {
    /// The Chrome identity; older folder installs may still have a "local-…" id.
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    /// The permissions it was installed with, so an update that asks for more
    /// is asked about rather than slipped through.
    var permissions: [String]
    var installedAt: Date? = nil
    /// Kept in the row beside the menu rather than only in it. Optional, so
    /// a list written before there was pinning still reads.
    var pinned: Bool? = nil
    /// For one loaded from a folder: where that folder is, so Reload can
    /// bring the author's latest edits in.
    var source: String? = nil
    /// Come from another Mac (sync) at a version that asks for more than
    /// it was allowed there: what more, kept off until it is turned on
    /// here and allowed. Nil for the rest.
    var wants: [String]? = nil
    /// What its Chromium package asks for beyond what was approved, as
    /// `ChromiumExtensionGrants.beyondApproval` writes it, still unanswered:
    /// it comes to Chromium on a yes, and is asked about when it is turned
    /// on. Nil for the rest (ExtensionOneList).
    var chromeAsks: [String]? = nil
    /// Chrome's "Allow User Scripts" (Chrome 138+), as chosen on its
    /// Settings page: what each Chromium profile of the sign-in is set to.
    /// Nil until chosen, off as in Chrome. WebKit's shim has no such gate:
    /// it runs them on the install's grant.
    var userScripts: Bool? = nil
}

@available(macOS 15.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    static let shared = Extensions(signIn: nil)

    /// Every page view built for a tab is handed the controller at birth,
    /// it can't be given one later: the controller of the sign-in its store
    /// is, so a space with sign-ins of its own runs its own extensions, as a
    /// Chrome profile does (ExtensionSignIns.swift).
    static func attach(_ configuration: WKWebViewConfiguration) {
        let owner = of(store: configuration.websiteDataStore)
        if pages != "rules", pages != "0" { configuration.webExtensionController = owner.controller }
        // Ad blockers' rules there before the page's first request: the
        // shared sign-in's, which Yab's ad blocker settings speak for.
        if pages != "controller", pages != "0", owner === shared {
            ExtensionRules.give(configuration.userContentController, contexts: shared.contexts,
                                persistent: configuration.websiteDataStore.isPersistent)
        }
    }
    /// Tests only, for an A/B of what extensions cost a new tab
    /// (docs/evidence/adblock-vs-chrome-2026-10-13.md): YAB_EXT_PAGES=0
    /// gives pages neither the controller nor the held rule lists, `rules`
    /// the lists alone, `controller` the controller alone.
    private static let pages = ProcessInfo.processInfo.environment["YAB_EXT_PAGES"]

    let controller: WKWebExtensionController
    /// Dynamic action choices belong to this extension profile, including
    /// while its background worker/context is asleep.
    var popupPaths: [String: [String: String]] = [:]
    /// Whose extensions these are: nil for the sign-ins the first space
    /// keeps, which every space without its own shares, else the space
    /// with sign-ins of its own. Each is a list, a controller, storage and
    /// pages' data of its own, as each Chrome profile is.
    let signIn: UUID?
    /// Where its extensions' pages keep their data, and whose cookies
    /// their requests carry: the sign-in's store.
    let store: WKWebsiteDataStore
    /// When the controller was made. WebKit calls everything loaded in its
    /// first `startingFor` seconds part of the browser starting up.
    private let made = Date()
    static let startingFor: TimeInterval = 5.5
    @Published private(set) var installed: [Installed] = []
    /// Whether installed.json was read: false when it is there and couldn't
    /// be, and the list is empty for that, not for being empty (sync takes
    /// nothing away for it).
    private(set) var loaded = true
    /// The loaded ones, by id.
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when any extension's button changes, icon, badge, enabled.
    @Published var actionsChanged = 0
    func panelOptionsChanged() { actionsChanged += 1 }
    @Published var busy: String?
    private(set) var installErrors: [String: String] = [:]
    /// Errors an extension's pages and worker ran into, newest last, a few
    /// dozen at most per extension.
    @Published private(set) var errors: [String: [String]] = [:]
    /// Of those, what went wrong between the extension and Yab, WebKit or
    /// an app (a worker restarted, an app that wouldn't talk): what its row
    /// in Settings warns of. What its own code threw is in `errors` only,
    /// as Chrome shows it only with Developer mode on: Read AI's own server
    /// answering 401 before you sign in to it, or 1Password calling its
    /// core a moment before its worker has it up, is nothing you or Yab can
    /// act on, and a store extension's card read "12 warnings" for them
    /// (feedback #140). A folder's extension, someone's own, shows them all.
    @Published private(set) var notes: [String: [String]] = [:]
    /// How many were ever noted, per extension, past the few kept.
    private(set) var errorsNoted: [String: Int] = [:]
    /// What WebKit's own errors on each loaded context say, in words. Read
    /// from the context once at load and once each time WebKit says they
    /// changed (watch), never from a view: crash #60 was Settings ›
    /// Extensions' rows asking `context.errors` at every redraw, on macOS
    /// 15.8, and one of the NSErrors WebKit handed back was already freed.
    @Published private(set) var contextErrors: [String: [String]] = [:]

    /// In a test run, a line among its errors for what Yab did to its
    /// worker, so a run's timeline shows who started it.
    func trace(_ id: String, _ what: String) {
        guard Store.testing else { return }
        keep("console.debug: yab: " + what + " (awake: \(contexts[id].map(Extensions.workerAwake) ?? false))", for: id)
    }

    /// `own`: thrown or rejected in the extension's own pages or worker.
    /// `counted`: false for Yab's own refusals, which aren't the extension's fault.
    func noteError(_ text: String, for id: String, own: Bool = false, counted: Bool = true) {
        if counted { FeedbackDiagnostics.shared.record(.extensionError, extensionID: id) }
        keep(text, for: id)
        if !own { notes[id] = Array(((notes[id] ?? []) + [text]).suffix(40)) }
    }

    private func keep(_ text: String, for id: String) {
        errorsNoted[id, default: 0] += 1
        errors[id] = Array(((errors[id] ?? []) + [text]).suffix(40))
    }

    /// The rule sets each extension wanted on that are kept off, too large
    /// for WebKit to compile with the rest (ExtensionRuleBudget), as kept
    /// beside it; read once per extension.
    private var leftOff: [String: [String]] = [:]

    func rulesLeftOff(_ id: String) -> [String] {
        if let known = leftOff[id] { return known }
        let read = ExtensionRuleBudget.leftOff(in: Extensions.folder(for: id))
        leftOff[id] = read
        return read
    }

    func rulesLeftOff(_ id: String, adding: [String], removing: Set<String>) {
        let now = rulesLeftOff(id)
        let next = Array(Set(now + adding).subtracting(removing)).sorted()
        guard next != now.sorted() else { return }
        objectWillChange.send()
        leftOff[id] = next
        ExtensionRuleBudget.keep(next, in: Extensions.folder(for: id))
    }

    /// What its row warns of, Yab's notes or every line for one loaded from
    /// a folder (`notes`).
    func warnings(_ item: Installed) -> [String] {
        item.fromStore ? notes[item.id] ?? [] : errors[item.id] ?? []
    }

    /// The first window's browser: where an extension's own pages open when
    /// no window is in front, and the one Settings speaks through.
    weak var browser: Browser?
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    /// Each window's tabs as WebKit was last told them, in order, by the
    /// window's id (BrowserWindows.primaryID for the first).
    private var placed: [UUID: [Tab.ID]] = [:]
    /// The window each told tab is in.
    private var home: [Tab.ID: UUID] = [:]
    private var watching: [Tab.ID: [AnyCancellable]] = [:]
    private var bag = Set<AnyCancellable>()
    /// One for each browser window WebKit knows, in the order they opened.
    private var windows: [UUID: ExtensionWindow] = [:]
    private var panelPages: [UUID: [String: ExtensionSidePanelPage]] = [:]
    private var loading: [String: Task<Bool, Never>] = [:]
    private var removingData: [String: (token: UUID, task: Task<Bool, Never>)] = [:]
    private let removeStorageData: @MainActor (WKWebExtensionController, Set<WKWebExtension.DataType>, [WKWebExtension.DataRecord]) async -> [Error]
    private var windowOrder: [UUID] = []
    private var rows: [UUID: [AnyCancellable]] = [:]
    /// Where each extension's button is on screen, for its popup to hang from.
    /// Every sign-in's: the buttons are the window's.
    var anchors: [String: WeakView] {
        get { Extensions.anchorViews }
        set { Extensions.anchorViews = newValue }
    }
    private static var anchorViews: [String: WeakView] = [:]

    static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome, yab uses the same ids. Servers allow
    /// their own extension in by that origin (Raindrop's refuses any other),
    /// and sites look for an extension at it. WebKit's own
    /// webkit-extension:// is what yab used before; addresses kept from
    /// then are read as the new ones.
    static let scheme = "chrome-extension"
    static let formerScheme = "webkit-extension"

    static func current(_ url: URL) -> URL {
        guard url.scheme == formerScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = scheme
        return parts.url ?? url
    }
    private var list: URL { Extensions.list(of: signIn) }
    /// What it keeps in Store.settings under a name of the shared one's: a
    /// space's own under the name and its id.
    private func kept(_ name: String) -> String { signIn.map { name + "." + $0.uuidString } ?? name }
    static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    /// The id Chrome gives `id`'s extension, the one native hosts let in:
    /// a store one's own, and for one loaded from a folder the id its
    /// manifest's "key" makes, as Chrome works it out (Anchor's
    /// host lets in only that). Without a key, the one yab gave it.
    static func chromeID(_ id: String) -> String {
        guard id.hasPrefix("local-"),
              let data = try? Data(contentsOf: folder(for: id).appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (manifest["key"] as? String).flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) })
        else { return id }
        let a = Character("a").asciiValue!
        let letters = SHA256.hash(data: key).prefix(16).flatMap { [$0 >> 4, $0 & 0xF] }.map { Character(UnicodeScalar(a + $0)) }
        return String(letters)
    }

    /// One sign-in's: `shared`, or a space's own, made by `of(signIn:)`.
    init(signIn: UUID?, removeStorageData: @escaping @MainActor (WKWebExtensionController, Set<WKWebExtension.DataType>, [WKWebExtension.DataRecord]) async -> [Error] = { controller, types, records in
        await controller.removeData(ofTypes: types, from: records)
        return records.flatMap { $0.errors }
    }) {
        self.removeStorageData = removeStorageData
        self.signIn = signIn
        store = signIn.map { Spaces.store(for: $0) } ?? Store.websites
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords.
        //
        // Keep this folder where it is. The first extension a controller
        // loads makes WebKit remove the website data (localStorage,
        // IndexedDB, caches, workers) of every extension origin no state
        // file in the controller's folder names, unless the folder holds
        // StaleExtensionOriginsCleared (removeStaleExtensionWebsiteData,
        // 312231@main). Every extension once loaded here has a state file,
        // so one turned off or loaded only on first use keeps its data
        // (evals/extensions/stale_sweep.py); a new folder would have none,
        // and the second extension to load would lose its pages' data.
        //
        // A space's own sign-in has a folder of its own, by its id, copied
        // from the shared one's when the split came (ExtensionSignIns).
        let configuration = Extensions.configuration(for: signIn)
        configuration.defaultWebsiteDataStore = store
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        // One pool for every extension page, alive as long as the app
        // rather than as long as this controller (Web.extensionPool).
        views.processPool = Web.extensionPool
        // Its own configuration starts with WebKit's default store; an
        // extension's pages keep what they store where the browser does,
        // and a test run's apart from the real one's.
        views.websiteDataStore = store
        // The same user agent as the web tabs, to the letter. WebKit gives
        // workers the user agent of the last page that loaded and, when it
        // differs, stops the running workers to apply it, and extension
        // workers it then never starts again: every page that opened killed
        // the extensions. Extensions are told they run in Chrome by the shim
        // instead (navigator.userAgent in their pages and workers).
        views.applicationNameForUserAgent = Web.userAgentName
        // Extension pages send Global Privacy Control as tabs do.
        Web.globalPrivacyControl(views)
        // A test run sits behind other windows, where WebKit slows its views
        // to a crawl and messages between an extension's popup and its
        // worker stop arriving. Not what anyone is testing.
        if Store.testing, !Store.measuring { views.preferences.inactiveSchedulingPolicy = .none }
        Extensions.withoutInstalledFonts(views.preferences)
        // Passkeys asked for from its own pages (Passkeys.extensionPage).
        PasskeyRelay.install(in: views.userContentController)
        // The page's EyeDropper in its pages (EyeDropper.swift).
        EyeDropperRelay.install(in: views.userContentController)
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        // Which pages may talk to which extension, as the list changes.
        // On a later turn: what listens asks which sign-in is on screen,
        // and this one isn't known as its space's until it is made.
        $installed.map { _ in () }.merge(with: $busy.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { MainActor.assumeIsolated { Extensions.listsChanged.send() } }
            .store(in: &bag)
        $installed.receive(on: DispatchQueue.main).sink { [signIn] list in
            MainActor.assumeIsolated {
                // Every sign-in's: a page reaches only its own sign-in's.
                ExtensionExternal.shared.refresh(Extensions.all.flatMap(\.installed))
                // One turned off or removed lets go of the proxy it set: the
                // shared sign-in's, whose proxy is every space's.
                if signIn == nil { ExtensionProxy.refresh(list) }
            }
        }.store(in: &bag)
        // A kept tab opened or put down: one more tab, or one fewer, to
        // WebKit (`offered`), told with the rest of the row's news.
        Tab.unopenedChanged.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.windows.isEmpty else { return }
                self.forgetListings()
                self.news.rowChanged()
                self.tellSoon()
            }
        }.store(in: &bag)
        // Before any sign-in's list is read, whichever is made first.
        Extensions.splitOnce()
        unseen = Set(Store.settings.stringArray(forKey: kept("extensions.unseen")) ?? [])
        dotted = Store.settings.bool(forKey: kept("extensions.dotted"))
        if FileManager.default.fileExists(atPath: list.path) {
            let read = (try? Data(contentsOf: list)).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) }
            installed = read ?? []
            loaded = read != nil
            installedBeforeLaunch = Set(installed.map(\.id))
        }
        let quiet = ApplePasswordExtensionRoute.disabled(installed)
        if quiet != installed { installed = quiet; save() }
        // Written down before yab was yab, what it answers itself was
        // "fast:", and every update then read "yab:" as more than it had.
        if installed.contains(where: { $0.permissions.contains { $0.hasPrefix("fast:") } }) {
            for index in installed.indices {
                installed[index].permissions = installed[index].permissions
                    .map { $0.hasPrefix("fast:") ? "yab:" + $0.dropFirst(5) : $0 }
            }
            save()
        }
        // From the start: the first window registers, and tells its tabs,
        // before the extensions start (`holdingTabs`).
        if signIn == nil, ProcessInfo.processInfo.environment["YAB_FIRST_PAGES_HOLD"] != "0" {
            holdTabs(Set(installed.filter(\.enabled).map(\.id).filter { ExtensionLaunch.actsOnPages(in: Extensions.folder(for: $0)) }))
        }
        holdSignInPages()
    }

    // MARK: - starting

    private var firstPagesReady = true
    private var waitingPages: [() -> Void] = []
    /// The ad blockers the first pages wait for (ExtensionLaunch.blocks).
    private var holdingFirstPages: Set<String> = []

    /// Whether the first pages wait for an ad blocker now.
    var holdsFirstPages: Bool { !firstPagesReady }

    func whenFirstPagesReady(_ open: @escaping () -> Void) {
        if firstPagesReady { return open() }
        waitingPages.append(open)
        // A space's own sign-in's pages waiting: its extensions load next,
        // ahead of the rest of whichever sign-in is loading.
        if signIn != nil { Extensions.promote(self) }
    }

    /// A space's own sign-in, made: its pages wait for its extensions
    /// that act on them, content scripts and ad blockers, as a Chrome
    /// profile's pages open once its extensions are up, five seconds at
    /// most. They started only with the space's first page, after it: a
    /// page open before its extension loaded gets the extension's scripts
    /// but WebKit finds no tab for it, and every message they send says
    /// "Tab not found". A wallet's provider was on the page and never
    /// answered, and dapps saw no wallet, until the page was loaded again
    /// (#356, evals/extensions/wallet_sign_ins.py).
    private func holdSignInPages() {
        guard signIn != nil, ProcessInfo.processInfo.environment["YAB_FIRST_PAGES_HOLD"] != "0" else { return }
        holdingFirstPages = Set(installed.filter(\.enabled).map(\.id).filter { ExtensionLaunch.actsOnPages(in: Extensions.folder(for: $0)) })
        holdTabs(holdingFirstPages)
        firstPagesReady = holdingFirstPages.isEmpty
        guard !firstPagesReady else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.releaseFirstPages()
        }
    }

    /// The extensions that act on pages its tabs are told to WebKit after
    /// (`tell`), five seconds at most: a tab WebKit was told of before an
    /// extension loaded stays unknown to it, and every message from that
    /// extension's scripts in the page says "Tab not found", reloaded or
    /// not, while a tab told after works. Rabby's port from a page open as
    /// Yab started was let go that way, and its "ready" to every tab, sent
    /// once it had started, found none (#356).
    private var holdingTabs: Set<String> = []

    private func holdTabs(_ ids: Set<String>) {
        holdingTabs = ids
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.releaseTabs()
        }
    }

    private func tabsWait(for id: String) {
        guard holdingTabs.remove(id) != nil, holdingTabs.isEmpty else { return }
        tellSoon()
    }

    private func releaseTabs() {
        guard !holdingTabs.isEmpty else { return }
        holdingTabs = []
        tellSoon()
    }

    private func releaseFirstPages() {
        guard !firstPagesReady else { return }
        firstPagesReady = true
        let pages = waitingPages
        waitingPages.removeAll()
        for open in pages { open() }
    }

    func start(for browser: Browser) {
        self.browser = browser
        // Their buttons are there from the first frame, while they load one
        // after another below (see `buttons`).
        starting = Set(installed.filter(\.enabled).map(\.id))
        // The first pages wait only for ad blockers, so no ad slips through
        // on them: three password managers held them 1.9 s for nothing a
        // page shows (evals/stand/launch.py; YAB_FIRST_PAGES_HOLD=0 waits
        // for none, for the A/B).
        if ProcessInfo.processInfo.environment["YAB_FIRST_PAGES_HOLD"] != "0" {
            holdingFirstPages = Set(installed.filter(\.enabled).map(\.id).filter { ExtensionLaunch.blocks(in: Extensions.folder(for: $0)) })
        }
        firstPagesReady = holdingFirstPages.isEmpty
        if Startup.flag("BLOCKER_EARLY") { readEarly(holdingFirstPages) }
        Blockers.start()
        if !firstPagesReady {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.releaseFirstPages()
            }
        }
        watchWindows(browser)
        // Once the window is up: loading one holds the main thread for tens
        // of milliseconds, and the first frame waited behind them all.
        Links.onceShown { [weak self] in
            Extensions.inTurn(first: true) { [weak self] in
                guard let self else { return }
                await launch()
                for browser in BrowserWindows.shared.browsers { browser.rewarmSpare() }
                checkForUpdates()
            }
            Extensions.sharedStarted()
        }
        Extensions.startUnstarted(in: browser)
    }

    /// A space's own sign-in, its extensions started the first time a page
    /// of it is made, or its list is opened: after the shared ones', one
    /// sign-in at a time (`inTurn`).
    func startSignIn(in browser: Browser) {
        self.browser = browser
        starting = Set(installed.filter(\.enabled).map(\.id))
        watchWindows(browser)
        Extensions.inTurn { [weak self] in await self?.launch() }
    }

    /// Every window told, and told of focus and of private tabs from now on.
    private func watchWindows(_ browser: Browser) {
        follow(browser)
        for other in BrowserWindows.shared.browsers where other !== browser { follow(other) }
        BrowserWindows.shared.$focusedID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, let id, let window = windows[id] else { return }
                controller.didFocusWindow(window)
            }
            .store(in: &bag)
        // Allow in private tabs, turned on or off: every extension loaded
        // may reach private tabs, or no longer.
        browser.prefs.changes(\.extensionsInPrivate)
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                for context in contexts.values { Extensions.allowPrivate(context, on) }
            }
            .store(in: &bag)
    }

    /// Once a run: its turn, or sooner for pages waiting (`promote`).
    private var launchBegan = false

    /// The enabled ones loaded, as a launch loads them.
    func launch() async {
        guard !launchBegan else { return }
        // A page of one of its own in a tab needs it there to draw.
        let ownPage = BrowserWindows.shared.browsers.contains { browser in
            (browser.tabs + browser.parkedTabs).contains { ($0.pending ?? $0.address).flatMap(Browser.extensionHost(of:)) != nil }
        }
        if Extensions.restsForChromium, !ownPage {
            // Nothing waits for extensions that aren't coming yet.
            starting = []
            holdingFirstPages = []
            releaseFirstPages()
            releaseTabs()
            Extensions.rest(self)
            return
        }
        let inChromium = Extensions.restingInChromium(store).subtracting(ExtensionOneList.webKitFolders(installed))
        starting = Set(installed.filter(\.enabled).map(\.id)).subtracting(inChromium)
        launchBegan = true
        // Before any of them starts: their workers are registered afresh.
        // A space's own sign-in's went as its store was made (`storeMade`).
        let ids = Set(installed.filter(\.enabled).map(\.id))
        if signIn.map({ !Extensions.sweptWorkers.contains($0) }) ?? true, let root = Extensions.generalStorage(of: store) {
            await Task.detached(priority: .userInitiated) { Extensions.forgetOrigins(of: ids, only: "ServiceWorkers", in: root) }.value
        }
        // What each needs at launch (ExtensionLaunch): those whose
        // scripts and rules act on pages first, then the rest that
        // must run; one only its button wakes sleeps until then.
        let order = plan()
        // One after another, a moment apart: started all at once,
        // WebKit fails some of their workers and never tries them again.
        for item in order {
            if holdingFirstPages.isEmpty { releaseFirstPages() }
            // A sign-in whose pages wait, between two of these, once those
            // this one's first pages wait for are in.
            if holdingFirstPages.isEmpty { await Extensions.launchPromoted() }
            guard installed.contains(where: { $0.id == item.id && $0.enabled }), contexts[item.id] == nil,
                  !inChromium.contains(item.id) else {
                starting.remove(item.id)
                holdingFirstPages.remove(item.id)
                tabsWait(for: item.id)
                continue
            }
            await load(item)
            starting.remove(item.id)
            holdingFirstPages.remove(item.id)
            tabsWait(for: item.id)
            if holdingFirstPages.isEmpty { releaseFirstPages() }
            actionsChanged += 1
            if pressWhenLoaded == item.id {
                pressWhenLoaded = nil
                if contexts[item.id] != nil { press(item.id) }
            }
            if contexts[item.id]?.webExtension.hasBackgroundContent == true {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        releaseFirstPages()
        releaseTabs()
        await Extensions.launchPromoted()
    }

    // MARK: - what a launch starts (ExtensionLaunch)

    /// The enabled extensions in the order a launch loads them, those left
    /// asleep until used taken out (and into `asleep`).
    private func plan() -> [Installed] {
        // A page of its own already in a tab, a window's or a space's
        // parked: it must be there to draw.
        let open = Set(BrowserWindows.shared.browsers.flatMap { $0.tabs + $0.parkedTabs }
            .compactMap { tab in (tab.pending ?? tab.address).flatMap(Browser.extensionHost(of:)) })
        var first: [Installed] = [], later: [Installed] = []
        for item in installed where item.enabled {
            let manifest = (try? Data(contentsOf: Extensions.folder(for: item.id).appendingPathComponent("manifest.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let facts = ExtensionLaunch.facts(manifest)
            refreshTipFacts(item.id)
            let heard = ExtensionLaunch.events(heardEvents, id: item.id, version: facts.version)
            let plan = manifest.isEmpty ? (need: ExtensionLaunch.Need.launch, why: "no manifest read")
                : ExtensionLaunch.need(facts, heard: heard, openPage: open.contains(item.id))
            plans[item.id] = plan
            switch plan.need {
            case .first: first.append(item)
            case .launch: later.append(item)
            case .onUse:
                starting.remove(item.id)
                asleep.insert(item.id)
            }
        }
        // Ad blockers first of all: the first pages wait for them.
        return first.filter { holdingFirstPages.contains($0.id) } + first.filter { !holdingFirstPages.contains($0.id) } + later
    }

    /// An extension left asleep by the launch, loaded now for its first
    /// use, and `then` once it is.
    func wake(_ id: String, then: (() -> Void)? = nil) {
        guard asleep.contains(id), let item = installed.first(where: { $0.id == id }) else { then?(); return }
        asleep.remove(id)
        starting.insert(id)
        lateLoads.insert(id)
        Task { [weak self] in
            guard let self else { return }
            await load(item)
            starting.remove(id)
            actionsChanged += 1
            if pressWhenLoaded == id {
                pressWhenLoaded = nil
                if contexts[id] != nil { press(id) }
            }
            then?()
        }
    }

    /// What its worker said it listens for, at the version kept.
    func listening(_ id: String) -> [String] { heardEvents[id]?.events ?? [] }

    /// Whether WebKit's "install" is said to one woken by its first use.
    func startedLate(_ id: String) -> Bool { lateLoads.contains(id) }

    /// What the worker said it listens for (the shim), kept for its next
    /// launch, and what it was woken for with nobody listening.
    func heard(_ id: String, events: [String], idle: [String: Int]) {
        idleWakes[id] = idle
        guard let version = contexts[id]?.webExtension.version ?? installed.first(where: { $0.id == id })?.version else { return }
        let kept = heardEvents[id]
        // The second report of a start takes in listeners added late; a
        // worker never says less than it did at this version and start.
        let events = kept?.version == version ? Array(Set(events).union(kept?.events ?? [])).sorted() : events.sorted()
        guard kept?.version != version || kept?.events != events else { return }
        heardEvents[id] = ExtensionLaunch.Heard(version: version, events: events, at: Date())
        let all = heardEvents
        let folder = ownFolder
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ExtensionLaunch.write(all, to: folder)
        }
    }

    /// The button's badge and label as they are now, kept for the next
    /// launch's first seconds, written a moment after the last change.
    private func keepFace(of context: WKWebExtensionContext) {
        guard let action = context.action(for: activeAdapter) else { return }
        let face = ["badge": action.badgeText, "label": action.label]
        lastFaces[context.uniqueIdentifier] = face
        facesChanged.insert(context.uniqueIdentifier)
        guard !facesDirty else { return }
        facesDirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            facesDirty = false
            Store.settings.set(lastFaces, forKey: kept("extensions.faces"))
            // And the icon it set, drawn as the button draws it.
            let tab = activeAdapter
            let icons = facesChanged.compactMap { id -> (URL, Data)? in
                guard let image = self.contexts[id]?.action(for: tab)?.icon(for: CGSize(width: 32, height: 32)),
                      let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { return nil }
                return (Extensions.faceIcon(id), png)
            }
            facesChanged = []
            DispatchQueue.global(qos: .utility).async {
                for (file, png) in icons {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? png.write(to: file, options: .atomic)
                }
            }
        }
    }

    private var facesChanged: Set<String> = []
    private var lastIcons: [String: NSImage] = [:]

    /// Removed: its last face and what its worker listened for go with it.
    private func forgetFace(_ id: String) {
        lastFaces[id] = nil
        lastIcons[id] = nil
        Store.settings.set(lastFaces, forKey: kept("extensions.faces"))
        try? FileManager.default.removeItem(at: Extensions.faceIcon(id))
        if heardEvents.removeValue(forKey: id) != nil { ExtensionLaunch.write(heardEvents, to: ownFolder) }
    }

    private func lastIcon(_ id: String) -> NSImage? {
        if let image = lastIcons[id] { return image }
        guard let image = NSImage(contentsOf: Extensions.faceIcon(id)) else { return nil }
        lastIcons[id] = image
        return image
    }

    /// The icon a button last wore, kept beside the extensions' folders,
    /// never in one: WebKit takes a changed folder for an update.
    static func faceIcon(_ id: String) -> URL {
        folder.appendingPathComponent("Faces", isDirectory: true).appendingPathComponent(id + ".png")
    }

    // MARK: - the windows and their rows, as WebKit sees them

    /// The tab that took another's place under the same id (see
    /// Browser.replaceBlank): WebKit keeps knowing it as the tab it was.
    func rehome(_ tab: Tab) {
        adapters[tab.id]?.tab = tab
    }

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    static func key(of browser: Browser) -> UUID { browser.windowID ?? BrowserWindows.primaryID }
    private static func panelKey(_ id: String, tabID: Int?) -> String {
        id + "|" + (tabID.map(String.init) ?? "global")
    }

    func panelWindow(for browser: Browser) -> ExtensionWindow? { windows[Self.key(of: browser)] }

    func panelPage(_ id: String, in browser: Browser) -> ExtensionSidePanelPage? {
        panelPages[Self.key(of: browser)]?[Self.panelKey(id, tabID: browser.panelTabID)]
    }

    func panelPages(in browser: Browser) -> [ExtensionSidePanelPage] {
        (panelPages[Self.key(of: browser)] ?? [:]).values.sorted { $0.contextID < $1.contextID }
    }

    func panelContexts(_ id: String) -> [ExtensionSidePanelPage] {
        panelPages.values.flatMap { $0.values }.filter { $0.id == id && $0.web.url != nil }
    }

    func panelChoices(in browser: Browser) -> [Installed] {
        let shown = Set(panelPages(in: browser).filter {
            ExtensionShims.panelIsEnabled($0.id, tabID: $0.targetTabID)
        }.map(\.id))
        return installed.filter { item in
            guard item.enabled, let context = contexts[item.id] else { return false }
            let global = ExtensionShims.panelIsEnabled(item.id, tabID: nil) &&
                ExtensionShims.pathForPanel(context, tabID: nil) != nil
            return global || shown.contains(item.id)
        }
    }

    func openPanelChoice(_ id: String, in browser: Browser) {
        if let context = contexts[id], ExtensionShims.panelIsEnabled(id, tabID: nil),
           ExtensionShims.pathForPanel(context, tabID: nil) != nil {
            openPanel(id, in: browser)
        } else if let page = panelPages(in: browser).first(where: { $0.id == id }) {
            openPanel(id, in: browser, tabID: page.targetTabID)
        }
    }

    func openPanel(_ id: String, in browser: Browser, tabID: Int? = nil) {
        guard ExtensionShims.panelIsEnabled(id, tabID: tabID),
              let context = contexts[id], let configuration = context.webViewConfiguration,
              let path = ExtensionShims.pathForPanel(context, tabID: tabID),
              let url = ExtensionShims.offscreenURL(path, base: context.baseURL) else { return }
        let key = Self.key(of: browser)
        let pageKey = Self.panelKey(id, tabID: tabID)
        if let page = panelPages[key]?[pageKey] {
            page.load(url, tabID: tabID)
        } else {
            panelPages[key, default: [:]][pageKey] = ExtensionSidePanelPage(id: id, browser: browser, owner: self,
                                                                             configuration: configuration, url: url,
                                                                             tabID: tabID)
            panelOptionsChanged()
        }
        browser.panelTabID = tabID
        browser.panelContextID = panelPages[key]?[pageKey]?.contextID
        browser.panelExtension = id
        // The newest panel request wins even before a queued close has
        // changed chatOpen; repeating an open is already idempotent.
        browser.moveChat(open: true)
    }

    func closePanel(_ id: String, in browser: Browser?, tabID: Int? = nil, contextID: String? = nil) {
        guard let browser,
              let page = panelPages[Self.key(of: browser)]?[Self.panelKey(id, tabID: tabID)],
              contextID == nil || contextID == page.contextID else { return }
        if browser.panelExtension == id && browser.panelTabID == tabID && browser.panelContextID == page.contextID {
            // Removing the content alone leaves ChatRoom reserving its
            // width. Also cancel an open still waiting for its first frame.
            browser.moveChat(open: false)
            browser.panelExtension = nil
            browser.panelContextID = nil
        }
        panelPages[Self.key(of: browser)]?.removeValue(forKey: Self.panelKey(id, tabID: tabID))
        controller.didCloseTab(page, windowIsClosing: false)
        panelOptionsChanged()
    }

    func closePanels(_ id: String, tabID: Int? = nil) {
        for pages in Array(panelPages.values) {
            for page in pages.values where page.id == id && (tabID == nil || page.targetTabID == tabID)
                && !ExtensionShims.panelIsEnabled(id, tabID: page.targetTabID) {
                closePanel(id, in: page.browser, tabID: page.targetTabID)
            }
        }
    }

    /// A browser window, and every page in it, told to WebKit from now on.
    /// Each page runs the extensions' scripts, whatever window it is in,
    /// and one WebKit has no tab for gets "Tab not found" each time a
    /// script asks to talk to its extension. React Developer Tools asks
    /// again at once, for as long as the page lives: a core's worth.
    func follow(_ browser: Browser) {
        let key = Self.key(of: browser)
        if let known = windows[key] {
            if known.browser === browser { return }
            // The same id in a new browser, a window reopened: the old
            // one's tabs are closed first.
            unfollow(key)
        }
        let window = ExtensionWindow(owner: self, browser: browser)
        windows[key] = window
        windowOrder.append(key)
        controller.didOpenWindow(window)
        rows[key] = [
            browser.changes(\.tabs).sink { [weak self] _ in
                self?.forgetListings()
                self?.rowChanged()
            },
            browser.changes(\.activeID)
                .removeDuplicates()
                .scan((nil, nil)) { ($0.1, $1) }
                .sink { [weak self, weak browser] pair in
                    self?.forgetListings()
                    // A put-down kept tab coming to the front is a tab from
                    // now on (`offered`), told as opened before it is told
                    // as active; one going behind is a saved link again.
                    if let browser, [pair.0, pair.1].contains(where: { id in
                        browser.tabs.contains { $0.id == id && $0.unopened && ($0.kept || $0.pin != nil) }
                    }) { self?.news.rowChanged() }
                    self?.turns[key, default: TabNews()].activated(from: pair.0, to: pair.1)
                    self?.tellSoon()
                },
        ]
        rowChanged()
        for link in LinkWindow.all where link.browser === browser { follow(link) }
    }

    /// A window closed, and its tabs with it.
    func unfollow(_ browser: Browser) {
        let key = Self.key(of: browser)
        guard windows[key]?.browser === browser else { return }
        unfollow(key)
    }

    private func unfollow(_ key: UUID) {
        guard let window = windows[key] else { return }
        // A tab may have moved out while the row's news still waits. Tell
        // that move before closing its old window, keeping its native id.
        if news.row { tell() }
        if let pages = panelPages.removeValue(forKey: key) {
            for page in pages.values { controller.didCloseTab(page, windowIsClosing: true) }
        }
        windows[key] = nil
        windowOrder.removeAll { $0 == key }
        rows[key] = nil
        turns[key] = nil
        for id in placed.removeValue(forKey: key) ?? [] {
            home[id] = nil
            watching[id] = nil
            if let adapter = adapters.removeValue(forKey: id) { controller.didCloseTab(adapter, windowIsClosing: true) }
        }
        controller.didCloseWindow(window)
    }

    /// Its sign-in gone (ExtensionSignIns.forget): every extension unloaded
    /// and every window let go of. The stand-in stays, for the pages still
    /// carrying this controller as they close (`keepOneLoaded`).
    func shutDown() {
        for id in Array(contexts.keys) { unload(id) }
        for key in windowOrder { unfollow(key) }
        bag.removeAll()
        installed = []
    }

    /// The window WebKit should know as focused, told as a popout's goes:
    /// the browser's key window, when one is.
    func focusChanged() {
        if let popout = ExtensionPopout.owning(NSApp.keyWindow) {
            if popout.controller === controller { controller.didFocusWindow(popout.frame) }
        } else if let link = LinkWindow.inFront {
            if let own = windows[link.extensionKey] { controller.didFocusWindow(own) }
        } else if let key = NSApp.keyWindow, let known = windows.values.first(where: {
            !$0.isLink && $0.browser.flatMap { BrowserWindows.shared.window(for: $0) } === key
        }) {
            controller.didFocusWindow(known)
        }
    }

    /// A window's row, or the pages it holds outside it, changed.
    func rowChanged() {
        news.rowChanged()
        tellSoon()
        // An extension's own page opened in a tab is told at once, not with
        // the row's news a moment on: it asks tabs.getCurrent as it starts,
        // and WebKit, not yet told of its tab, answered null, so OneTab's
        // list stayed a spinner (feedback #156). After this turn, when the
        // row holds the tab.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.tellOwnPages() }
        }
    }

    private func tellOwnPages() {
        guard telling else { return }
        let fresh = windowOrder.contains { key in
            guard let browser = windows[key]?.browser else { return false }
            return (browser.tabs + browser.outside).contains { home[$0.id] == nil && $0.address?.scheme == Extensions.scheme && offered($0, in: browser) }
        }
        if fresh { tell() }
    }

    /// Private tabs keep nothing and see no extensions, unless Settings ›
    /// Extensions says they may, and then only the ones made since, which
    /// carry the controller: one made before has no page an extension
    /// could reach.
    ///
    /// And only the pages of its own sign-in: a page carries the controller
    /// of the sign-in it was made in (`attach`), and a space with sign-ins
    /// of its own is another profile, whose pages these extensions never
    /// see. One made with no controller at all (YAB_EXT_PAGES) is the
    /// shared one's, as every page was.
    func seen(_ tab: Tab) -> Bool {
        guard let made = tab.madeExtensionController else {
            // A page not made yet, asleep since launch: by the store it
            // will be made in, without starting that sign-in for it.
            return Extensions.signIn(of: tab.pageStore) == signIn
        }
        if let carried = made { return carried === controller }
        return signIn == nil && !tab.shy
    }

    /// Whether an extension may act in private tabs. A private tab made
    /// while Settings allows it carries the controller, but WebKit still
    /// keeps every extension out of a page with a non-persistent store, its
    /// content scripts, its tabs and its cookies, unless the extension's
    /// context has access to private data: with "Allow in private tabs" on,
    /// no extension did anything in a private tab (release QA, 0.0.20).
    static func allowPrivate(_ context: WKWebExtensionContext, _ on: Bool) {
        if context.hasAccessToPrivateData != on { context.hasAccessToPrivateData = on }
    }
    private func seenOnce(_ tabs: [Tab], in browser: Browser) -> [Tab] {
        var ids = Set<Tab.ID>()
        return tabs.filter { offered($0, in: browser) && ids.insert($0.id).inserted }
    }

    /// Whether extensions know this tab as a tab: one of this sign-in's
    /// (`seen`) that is open. A kept tab or a pin brought back from the
    /// last session, or put down with ⌘W, and not opened since is a saved
    /// link in the column (`Tab.unopened`), as Arc's is, unless it is the
    /// one in front. WebKit checks every tab it describes against its
    /// window's whole list, so a window of n tabs costs n² for each
    /// tabs.query, each message from a page and each tab opened: with an
    /// Arc import's 1,436 kept rows, the main thread stayed near 100%
    /// (feedback #1039).
    func offered(_ tab: Tab, in browser: Browser) -> Bool {
        guard seen(tab) else { return false }
        return !(tab.unopened && (tab.kept || tab.pin != nil) && tab.id != browser.activeID)
    }
    /// The first window's tabs.
    var visibleTabs: [Tab] { visibleTabs(in: browser) }
    /// A window's tabs as an extension knows them: Arc's shape, every
    /// space of the window, the one on screen first and then the others'
    /// rows in the spaces' order, as Yab's AppleScript lists them and ⌃Tab
    /// walks them (Scripting.swift). The row on screen keeps its places;
    /// the other spaces' tabs come after it. Only the row once was, and
    /// OneTab's "send all tabs" left a tab of another space open, and
    /// couldn't close one it was handed (feedback #156). With spaces off,
    /// the others' rows are out of reach, as for ⌃Tab.
    func visibleTabs(in browser: Browser?) -> [Tab] {
        guard let browser else { return [] }
        return seenOnce(browser.tabs + otherSpaces(of: browser), in: browser)
    }

    /// A window's tabs as `visibleTabs` lists them, and each one's place,
    /// kept until the main thread's turn ends or the row changes. WebKit
    /// asks a window for its tabs and a tab for its place once for every
    /// tab it describes, so one tabs.query asked for the list n times, and
    /// each time it was made afresh.
    func listing(_ browser: Browser) -> (adapters: [any WKWebExtensionTab], places: [Tab.ID: Int]) {
        let key = Self.key(of: browser)
        if let known = listings[key], known.browser === browser { return (known.adapters, known.places) }
        let tabs = visibleTabs(in: browser)
        var places: [Tab.ID: Int] = [:]
        places.reserveCapacity(tabs.count)
        for (index, tab) in tabs.enumerated() where places[tab.id] == nil { places[tab.id] = index }
        let adapters: [any WKWebExtensionTab] = tabs.map(adapter(for:))
        listings[key] = (browser, adapters, places)
        if !listingsEnd {
            listingsEnd = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.forgetListings() }
            }
        }
        return (adapters, places)
    }
    private var listings: [UUID: (browser: Browser, adapters: [any WKWebExtensionTab], places: [Tab.ID: Int])] = [:]
    private var listingsEnd = false
    private func forgetListings() {
        listings = [:]
        listingsEnd = false
    }

    private func otherSpaces(of browser: Browser) -> [Tab] {
        guard browser.spacesShown else { return [] }
        return browser.spaces.filter { $0.id != browser.spaceID }.flatMap { browser.parked[$0.id]?.tabs ?? [] }
    }

    /// The browser of the window in front, of those WebKit knows: where an
    /// extension's button is pressed, and where what it opens goes.
    var front: Browser? {
        if let browser = LinkWindow.inFront?.browser ?? BrowserWindows.shared.activeBrowser,
           windows[Self.key(of: browser)]?.browser === browser {
            return browser
        }
        return browser
    }

    /// The window a page this sign-in's extensions open goes to: `asked`
    /// or the one in front if it shows a space of this sign-in, else
    /// another window that does, else the one in front, taken to this
    /// sign-in's space first. A page opened anywhere else would be made in
    /// another sign-in, signed out and out of their reach.
    func opening(_ asked: Browser? = nil) -> Browser? {
        let windows = [asked, front].compactMap { $0 } + BrowserWindows.shared.browsers
        if let showing = windows.first(where: { Extensions.of($0) === self }) { return showing }
        guard let browser = asked ?? front else { return nil }
        if let space = browser.spaces.first(where: { Extensions.signIn(of: $0.id) == signIn }) {
            browser.switchSpace(to: space.id)
        }
        return browser
    }

    /// The window in front, as WebKit knows it: a small window's own while it is.
    var window: ExtensionWindow? {
        if let link = LinkWindow.inFront, let own = windows[link.extensionKey] { return own }
        return front.flatMap { windows[Self.key(of: $0)] }
    }

    /// The tab in front in the window in front: what a button acts on.
    var activeAdapter: ExtensionTab? {
        // A small window in front that isn't ours: no tab, rather than the row's hidden one.
        if let link = LinkWindow.inFront { return windows[link.extensionKey]?.activeAdapter }
        return activeAdapter(in: front)
    }

    func activeAdapter(in browser: Browser?) -> ExtensionTab? {
        guard let tab = browser?.active, seen(tab) else { return nil }
        return adapter(for: tab)
    }

    /// A small window's page told as the one tab of a window of its own, as Chrome has a popup window.
    func follow(_ link: LinkWindow) {
        _ = Extensions.keyWatch
        guard windows[link.extensionKey] == nil, let browser = link.browser, seen(link.tab),
              windows[Self.key(of: browser)]?.browser === browser else { return }
        let window = ExtensionWindow(owner: self, browser: browser, link: link)
        windows[link.extensionKey] = window
        windowOrder.append(link.extensionKey)
        controller.didOpenWindow(window)
        rowChanged()
    }

    func unfollow(_ link: LinkWindow) {
        guard windows[link.extensionKey]?.isLink == true else { return }
        unfollow(link.extensionKey)
    }

    /// Focus back on a browser window doesn't change `focusedID`, so every key change is told.
    private static let keyWatch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { Extensions.all.forEach { $0.focusChanged() } } }

    /// The page a small window claims: until it is kept or let go.
    private func linkTabs(_ link: LinkWindow) -> [Tab] {
        guard let browser = link.browser, browser.outside.contains(where: { $0 === link.tab }),
              offered(link.tab, in: browser) else { return [] }
        return [link.tab]
    }

    /// A small window's tabs as last told, so they agree with each tab's window (`home`).
    fileprivate func toldTabs(_ link: LinkWindow) -> [Tab] {
        placed[link.extensionKey]?.contains(link.tab.id) == true ? [link.tab] : []
    }

    /// The window a tab is in: where WebKit was told it is, else the one
    /// whose row has it (a tab just opened for an extension), else the first.
    func window(of tab: Tab) -> ExtensionWindow? {
        if let key = home[tab.id], let window = windows[key] { return window }
        if let window = windows.values.first(where: { !$0.isLink && $0.browser?.tabs.contains { $0 === tab } == true }) { return window }
        return browser.flatMap { windows[Self.key(of: $0)] }
    }

    /// Whether WebKit was told of this tab, and in which window.
    func told(_ tab: Tab) -> UUID? { home[tab.id] }

    /// The tab whose page this is, in any window, in its row or outside it.
    func tab(showing web: WKWebView) -> Tab? {
        for key in windowOrder {
            guard let browser = windows[key]?.browser else { continue }
            if let tab = (browser.tabs + browser.outside).first(where: { $0.webKitOnly("Legacy WebKit extension tab", build: false) === web }) { return tab }
        }
        return nil
    }

    /// What happened to the rows that WebKit hasn't been told yet, and, by
    /// window, the switch from the tab first in front to the one now.
    private var news = TabNews<Tab.ID>()
    private var turns: [UUID: TabNews<Tab.ID>] = [:]
    private var telling = false

    /// WebKit told of the rows a moment after they change, everything that
    /// happened since in one go, in the order an extension expects: tabs
    /// opened and closed, then the one in front, then what changed in them.
    /// Never in the middle of opening a tab: telling WebKit wakes every
    /// sleeping worker that listens, and the tab is drawn first.
    private func tellSoon() {
        guard !telling else { return }
        telling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TabNews<Tab.ID>.delay) { [weak self] in
            MainActor.assumeIsolated { self?.tell() }
        }
    }

    private func tell() {
        telling = false
        // Told once the extensions that act on pages are in (`holdingTabs`).
        guard holdingTabs.isEmpty else { return }
        let told = news, switches = turns
        news = TabNews()
        turns = [:]
        if told.row { place() }
        for key in windowOrder {
            guard let switched = switches[key]?.switched else { continue }
            activated(from: switched.from, to: switched.to, in: key)
        }
        for (id, properties) in told.changes {
            guard let adapter = adapters[id] else { continue }
            controller.didChangeTabProperties(properties, for: adapter)
        }
    }

    /// Every tab WebKit was told of, open for a context that just loaded.
    /// WebKit opens a loading context's tabs from each window's list
    /// (`tabs(for:)`), and leaves out every tab of a window whose tab in
    /// front it can't find in that list: none in front (the field asking
    /// over no page), or a private tab or another sign-in's in front. Tabs
    /// no list has (a parked row, a peek) it never
    /// opens there at all. A tab it hasn't opened for a context is one that
    /// context has no tab for: the extension's content scripts are put in
    /// its page, and every runtime.sendMessage and runtime.connect from
    /// there ends at once with "Tab not found", reloaded or not, until the
    /// tab is told again (row 1119). A tab opened after the context loaded
    /// is told then (`place`), to every context.
    private func openTold(in context: WKWebExtensionContext) {
        var open = Set<ObjectIdentifier>()
        for case let tab as ExtensionTab in context.openTabs { open.insert(ObjectIdentifier(tab)) }
        for key in windowOrder {
            for id in placed[key] ?? [] {
                guard let adapter = adapters[id], !open.contains(ObjectIdentifier(adapter)) else { continue }
                context.didOpenTab(adapter)
            }
        }
    }

    /// Document-start scripts can connect as soon as a navigation starts.
    /// Row/property notifications remain coalesced, but tab identity must be
    /// in WebKit before that document runs, including pages outside the row.
    func willLoad(_ tab: Tab) {
        guard home[tab.id] == nil, seen(tab) else { return }
        place()
    }

    /// Every window's tabs, told: its row, its spaces parked (a switch is
    /// no closing and reopening of every tab), and its pages not in the row
    /// yet, a peek's. Each runs the extensions' scripts, so each is a tab to
    /// WebKit, one outside the row at no place in it, as a parked one is. A
    /// small window's page is the one tab of its own window (`follow(_:)`).
    private func place() {
        // A row and a parked space can carry the same tab while changing
        // spaces, and two rows a tab moving between windows. WebKit knows a
        // tab once, in one window, and its positions must be unique too.
        var claimed = Set<Tab.ID>()
        var now: [UUID: [Tab]] = [:]
        for key in windowOrder where windows[key]?.isLink == true {
            now[key] = windows[key]?.link.map { linkTabs($0).filter { claimed.insert($0.id).inserted } } ?? []
        }
        for key in windowOrder where windows[key]?.isLink == false {
            guard let browser = windows[key]?.browser else { continue }
            // In the order the window lists them (`visibleTabs`), then
            // what it holds at no place: shared pins put aside, a row of a
            // space while spaces are off, pages outside the row.
            now[key] = (visibleTabs(in: browser) + browser.parkedTabs + browser.outside)
                .filter { offered($0, in: browser) && claimed.insert($0.id).inserted }
        }
        let before = placed
        var was: [Tab.ID: (key: UUID, index: Int)] = [:]
        for (key, ids) in before {
            for (index, id) in ids.enumerated() { was[id] = (key, index) }
        }
        // Where everything is now, before WebKit asks a tab for its window.
        placed = now.mapValues { $0.map(\.id) }
        home = [:]
        for (key, tabs) in now {
            for tab in tabs { home[tab.id] = key }
        }
        for id in was.keys where !claimed.contains(id) {
            if let adapter = adapters.removeValue(forKey: id) { controller.didCloseTab(adapter, windowIsClosing: false) }
            watching[id] = nil
        }
        for key in windowOrder {
            let tabs = now[key] ?? []
            for tab in tabs {
                guard let old = was[tab.id] else {
                    controller.didOpenTab(adapter(for: tab))
                    watch(tab)
                    continue
                }
                if old.key != key { controller.didMoveTab(adapter(for: tab), from: old.index, in: windows[old.key]) }
            }
            // Moves: anything whose position changed among the ones that
            // stayed in this window.
            let ids = tabs.map(\.id)
            let idSet = Set(ids)
            let stayed = (before[key] ?? []).filter { idSet.contains($0) }
            let stayedSet = Set(stayed)
            let newOrder = ids.filter { stayedSet.contains($0) }
            let positions = Dictionary(newOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
            for (index, id) in stayed.enumerated() where positions[id] != index {
                if let adapter = adapters[id] { controller.didMoveTab(adapter, from: index, in: windows[key]) }
            }
        }
    }

    private func watch(_ tab: Tab) {
        let id = tab.id
        // Told with the rest of the row's news: a page loading changes its
        // title, address and loading in quick turns, and each told alone
        // wakes the workers that listen for tabs.onUpdated.
        func changed(_ properties: WKWebExtension.TabChangedProperties) {
            news.changed(id, properties)
            tellSoon()
        }
        watching[id] = [
            tab.changes(\.title).dropFirst().removeDuplicates().sink { _ in changed(.title) },
            tab.changes(\.address).dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            tab.changes(\.loading).dropFirst().removeDuplicates().sink { _ in changed(.loading) },
            tab.changes(\.pin).dropFirst().map { $0 != nil }.removeDuplicates().sink { _ in changed(.pinned) },
        ]
        // A tab opened straight onto an address is already loading it here,
        // and the drops above would leave tabs.onUpdated with only its
        // "complete". Chrome says "loading" with the address first, and
        // that is what extensions act on: Toby sends a sign-in's end
        // (gettoby.com/open-toby, opened in a new tab) to its own page.
        if tab.loading, tab.address != nil { changed([.loading, .URL]) }
    }

    private func activated(from old: Tab.ID?, to new: Tab.ID?, in key: UUID) {
        guard let browser = windows[key]?.browser, let new,
              let tab = browser.tabs.first(where: { $0.id == new }), seen(tab) else { return }
        let previous = old.flatMap { id in browser.tabs.first { $0.id == id && seen($0) } }.map(adapter(for:))
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
        actionsChanged += 1
    }

    // MARK: - workers

    /// An extension's worker sleeps when it has nothing to do and wakes for
    /// the next event it listens for, in a web process started for it, as
    /// is each page of its own it opens. A new page is handed the fonts
    /// installed on this Mac first: WebKit issues its just-launched process
    /// sandbox extensions for them on the main thread, and that call took
    /// 6-10 s, the window frozen, on every wake. Every password manager
    /// listens for new tabs, so any tab opened did it. An extension's pages
    /// draw with the fonts it ships and the system's, so they go without.
    static func withoutInstalledFonts(_ preferences: WKPreferences) {
        // Its setter isn't the one key-value coding looks for.
        let setter = NSSelectorFromString("_setShouldAllowUserInstalledFonts:")
        guard preferences.responds(to: setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Set.self)(preferences, setter, false)
    }

    /// Whether pages made with these preferences get the installed fonts.
    static func allowsInstalledFonts(_ preferences: WKPreferences) -> Bool? {
        let getter = NSSelectorFromString("_shouldAllowUserInstalledFonts")
        guard preferences.responds(to: getter) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(preferences.method(for: getter), to: Get.self)(preferences, getter)
    }

    /// Whether the extension's worker is up now, rather than asleep until
    /// an event wakes it. For the bench.
    static func workerAwake(_ context: WKWebExtensionContext) -> Bool {
        let key = "_backgroundWebView"
        guard context.responds(to: NSSelectorFromString(key)) else { return false }
        return context.value(forKey: key) != nil
    }

    static func backgroundViewForTesting(_ context: WKWebExtensionContext) -> WKWebView? {
        guard Store.testing, context.responds(to: NSSelectorFromString("_backgroundWebView")) else { return nil }
        return context.value(forKey: "_backgroundWebView") as? WKWebView
    }

    // MARK: - loading

    @discardableResult
    private func load(_ item: Installed) async -> Bool {
        // At rest for Chromium (`restsForChromium`): an install or a switch
        // turned on writes the list, and the launch that wakes these loads it.
        if Extensions.restsForChromium, !launchBegan { return false }
        if let removal = removingData[item.id], !(await removal.task.value) { return false }
        if contexts[item.id] != nil { return true }
        if let current = loading[item.id] { return await current.value }
        let task = Task { await loadOnce(item) }
        loading[item.id] = task
        let loaded = await task.value
        loading[item.id] = nil
        return loaded
    }

    /// Ad blockers the first pages wait for, read from their folders from
    /// the start of the launch (shims, manifest, WKWebExtension) rather
    /// than once the window is up: only the controller's load waits for
    /// the first frame (YAB_LAUNCH_BLOCKER_EARLY=0 reads them then).
    private var readAhead: [String: Task<WKWebExtension?, Never>] = [:]

    private func readEarly(_ ids: Set<String>) {
        for id in ids where readAhead[id] == nil {
            readAhead[id] = Task { try? await Extensions.readFolder(id) }
        }
    }

    private func read(_ id: String) async throws -> WKWebExtension {
        if let ahead = readAhead.removeValue(forKey: id), let found = await ahead.value { return found }
        return try await Extensions.readFolder(id)
    }

    private static func readFolder(_ id: String) async throws -> WKWebExtension {
        let folder = Extensions.folder(for: id)
        // The shim this build of yab carries, in place of whatever the
        // build that installed it carried, away from the main thread: the
        // first launch after an update reads and rewrites every script and
        // page each extension ships, hundreds of milliseconds for a big one.
        try? await Task.detached(priority: .userInitiated) { try ExtensionShims.prepare(folder) }.value
        try WebKitIPCBoundary.validateExtensions(at: [folder])
        return try await WKWebExtension(resourceBaseURL: folder)
    }

    /// WebKit's page processes tell the controller of each frame's
    /// navigation (started, committed, finished, failed) while they know it
    /// has an extension loaded, and its UI side takes those messages only
    /// while it still has one ([Validator=hasLoadedContexts] in WebKit's
    /// WebExtensionController.messages.in): the last extension unloaded
    /// with one on its way, WebKit calls it invalid and ends that page's
    /// process. Turning off, removing, updating or restarting the only
    /// extension ended every tab loading then (evals/extensions/
    /// last_unload.py: 4 tabs of 4 within a second, "Received an invalid
    /// message 'WebExtensionController_DidCommitLoadForFrame'"). So before
    /// the first one loads, a stand-in with nothing in it, no scripts, no
    /// worker, no permissions, is loaded and stays: the controller goes
    /// from none to one, which WebKit allows, and never back. Kept out of
    /// `contexts`; nothing lists it.
    private var standIn: Task<Void, Never>?
    static let standInID = "yab-stand-in"

    private func keepOneLoaded() async {
        if let standIn { return await standIn.value }
        let task = Task { @MainActor [weak self] in
            let folder = Store.folder.appendingPathComponent("Extension Stand-In", isDirectory: true)
            let manifest = #"{"manifest_version":3,"name":"Yab","version":"1.0"}"#
            let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
                    return true
                } catch { return false }
            }.value
            guard written, let made = try? await WKWebExtension(resourceBaseURL: folder), let self else { return }
            let context = WKWebExtensionContext(for: made)
            context.uniqueIdentifier = Extensions.standInID
            if let base = URL(string: "\(Extensions.scheme)://\(Extensions.standInID)/") { context.baseURL = base }
            do { try self.controller.load(context) } catch { NSLog("Extensions: stand-in didn't load") }
        }
        standIn = task
        await task.value
    }

    private func loadOnce(_ item: Installed) async -> Bool {
        do {
            // Made while the extension is read, not after it.
            let keeping = Task { await keepOneLoaded() }
            let found = try await read(item.id)
            await keeping.value
            guard installed.contains(where: { $0.id == item.id && $0.enabled }) else { return false }
            // Updated for another sign-in while this one's list wasn't read:
            // the version its folder has now.
            if let version = found.version, version != item.version, let index = installed.firstIndex(where: { $0.id == item.id }) {
                installed[index].version = version
                save()
            }
            // Written down before grants took in sites and yab's own APIs:
            // the version installed is the one allowed, so its grants are
            // what was allowed, and its next update isn't asked about again
            // for asking what it always had.
            if !item.permissions.contains(where: { $0.hasPrefix("site:") || $0.hasPrefix("yab:") }),
               let index = installed.firstIndex(where: { $0.id == item.id }) {
                let grants = Extensions.grants(found, in: Extensions.folder(for: item.id))
                if grants != installed[index].permissions {
                    installed[index].permissions = grants
                    save()
                }
            }
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // localStorage, IndexedDB, is filed under its origin.
            if let stable = URL(string: "\(Extensions.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            // What it may ask for later, as chosen when it was added: given
            // now, or kept from it, nativeMessaging included.
            applyChoices(context)
            // The sites it named, unless it was told to wait to be pressed,
            // and never the ones it was kept from.
            applyAccess(context)
            Extensions.allowPrivate(context, Store.settings.bool(forKey: "extensions.private"))
            // After applyAccess: WebKit copies each script once per granted pattern.
            try checkBudget(item.id, WebKitIPCBoundary.Grants(context))
            if signIn == nil { ExtensionRules.prepare(context, storage: storage(of: item.id), owner: controller) }
            let began = CACurrentMediaTime()
            do {
                try controller.load(context)
            } catch {
                if signIn == nil { ExtensionRules.forget(item.id, owner: controller) }
                throw error
            }
            if starting.contains(item.id) { Startup.note("extension " + item.name, ms: (CACurrentMediaTime() - began) * 1000) }
            openTold(in: context)
            applyKeys(context)
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            // The first load of a run is what it was last told of: an
            // install, or nothing at a later launch (ExtensionInstallWord).
            if !loadsThisRun.contains(item.id) { toldVersion[item.id] = found.version ?? item.version }
            loadsThisRun.insert(item.id)
            // Prepared just now: what it keeps off is read again.
            leftOff[item.id] = nil
            contexts[item.id] = context
            if signIn == nil {
                ExtensionRules.activated(item.id)
                Blockers.loaded(item.id)
            }
            shelved[item.id] = nil
            actionsChanged += 1
            return true
        } catch {
            // WebKit can return a dangling NSError here too (crashes #154/#172).
            // Do not bridge it, format it or read even its domain/code.
            NSLog("Extensions: couldn't load %@", item.id)
            return false
        }
    }

    /// The icon an extension ships, read from its folder, for when it isn't
    /// loaded: turned off, it keeps its face in Settings.
    private var shelved: [String: NSImage] = [:]

    func icon(for id: String, side: CGFloat) -> NSImage? {
        if let context = contexts[id] { return ExtensionIconShape.rounded(context.webExtension.icon(for: CGSize(width: side * 2, height: side * 2))) }
        if let image = shelved[id] { return image }
        let folder = Extensions.folder(for: id)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = Chromium.icon(manifest, in: folder),
              let image = NSImage(contentsOf: file)
        else { return nil }
        let shaped = ExtensionIconShape.rounded(image) ?? image
        shelved[id] = shaped
        return shaped
    }

    private func unload(_ id: String) {
        onePasswordAnswered.remove(id)
        guard let context = contexts[id] else {
            if signIn == nil { ExtensionRules.forget(id, owner: controller) }
            return
        }
        ExtensionFetch.cancel(for: context)
        ExtensionDownloads.unloaded(id, owner: self)
        ExtensionNative.stop(owner: context)
        trace(id, "unloaded")
        for key in Array(panelPages.keys) {
            for pageKey in Array(panelPages[key, default: [:]].keys)
                where panelPages[key]?[pageKey]?.id == id {
                guard let page = panelPages[key]?.removeValue(forKey: pageKey) else { continue }
                page.browser?.panelExtension = nil
                controller.didCloseTab(page, windowIsClosing: false)
            }
        }
        // What the shims keep by its id is every sign-in's that runs it:
        // let go of with the last.
        if !Extensions.all.contains(where: { $0 !== self && $0.contexts[id] != nil }) {
            ExtensionShims.panelPath[id] = nil
            ExtensionShims.panelEnabled[id] = nil
            ExtensionShims.panelTabPath[id] = nil
            ExtensionShims.panelTabEnabled[id] = nil
            ExtensionShims.panelOnClick.remove(id)
            ExtensionShims.releasePower(for: id)
        }
        ExtensionPopout.close(extension: id, in: controller)
        ExtensionShims.closeOffscreen(id, in: controller)
        try? controller.unload(context)
        if signIn == nil {
            ExtensionRules.forget(id, owner: controller)
            Blockers.unloaded(id)
        }
        lateLoads.remove(id)
        // Its ports read as gone only once WebKit has had a turn.
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
        contexts[id] = nil
        contextErrors[id] = nil
        actionsChanged += 1
    }

    private func save() {
        try? FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: list, options: .atomic)
    }

    // MARK: - the one list (ExtensionOneList.swift)

    /// The list as the two engines' lists came together, once.
    func joinList(_ merged: [Installed]) {
        guard loaded else { return }
        installed = ApplePasswordExtensionRoute.disabled(merged)
        save()
    }

    /// One Chromium has and this list doesn't. A password manager comes in
    /// pinned the first time, as `admit` pins one.
    func takeNative(id: String, name: String, version: String, enabled: Bool, fromStore: Bool = true,
                    source: URL? = nil, permissions: [String] = []) {
        guard loaded else { return }
        if let index = installed.firstIndex(where: { $0.id == id }) {
            // A concurrent native list read may have adopted this folder
            // while load() was in flight. Keep the explicitly approved source.
            if source != nil || !permissions.isEmpty {
                installed[index].fromStore = fromStore
                installed[index].source = source?.path
                installed[index].permissions = permissions
                save()
            }
            return
        }
        let pins = Extensions.pinsOnArrival(id, pinnedBefore: Extensions.pinnedOnArrival)
        if pins { Extensions.pinnedOnArrival.insert(id) }
        let item = Installed(id: id, name: name, version: version, enabled: enabled && !ApplePasswordExtensionRoute.matches(id), fromStore: fromStore, permissions: permissions, installedAt: Date(), pinned: pins ? true : nil, source: source?.path)
        if pins { installed.insert(item, at: 0) } else { installed.append(item) }
        save()
    }

    /// What Chromium asks for beyond the approval, unanswered. `turnOff`:
    /// a no, which leaves it listed and off until it is turned on.
    func holdForChromium(_ id: String, asks: [String], turnOff: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let next = asks.isEmpty ? nil : asks.sorted()
        guard installed[index].chromeAsks != next || (turnOff && installed[index].enabled) else { return }
        installed[index].chromeAsks = next
        if turnOff, installed[index].enabled {
            installed[index].enabled = false
            unload(id)
        }
        save()
    }

    /// A yes to that question: what it asked for is approved now.
    func allowOnChromium(_ id: String, _ grants: [String]) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].permissions = Array(Set(installed[index].permissions + grants)).sorted()
        installed[index].chromeAsks = nil
        save()
    }

    /// WebKit's copy of one that came in on Chromium: its original package
    /// (`source`) with the shim, as any install has it, and what WebKit
    /// understands of it written down. It is in the list already.
    func fillFolder(_ id: String, from source: URL) async throws {
        let target = Extensions.folder(for: id)
        let files = FileManager.default
        guard !files.fileExists(atPath: target.appendingPathComponent("manifest.json").path) else { return }
        let root = Extensions.folder
        let staged = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try await Task.detached(priority: .utility) {
                let files = FileManager.default
                try? files.removeItem(at: staged)
                try files.createDirectory(at: root, withIntermediateDirectories: true)
                try files.copyItem(at: source, to: staged)
                try ChromiumExtensionPackages.plain(staged)
                try ExtensionShims.prepare(staged, fresh: true)
            }.value
            let found = try await WKWebExtension(resourceBaseURL: staged)
            guard !files.fileExists(atPath: target.appendingPathComponent("manifest.json").path),
                  installed.contains(where: { $0.id == id }) else {
                try? files.removeItem(at: staged)
                return
            }
            try? files.removeItem(at: target)
            try files.moveItem(at: staged, to: target)
            let grants = Extensions.grants(found, in: target)
            if let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].permissions = Array(Set(installed[index].permissions + grants)).sorted()
                save()
                if installed[index].enabled { await load(installed[index]) }
            }
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    /// What was chosen for it changed outside WebKit: put back on its
    /// context, as a load puts it (`applyChoices`, `applyAccess`).
    func choicesChanged(_ id: String) {
        objectWillChange.send()
        guard let context = contexts[id] else { return }
        applyChoices(context)
        applyAccess(context)
        noteIfOverBudget(id)
    }

    // MARK: - installing

    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only, there is no
    /// way to reach it from the real browser.
    func install(from text: String, confirm: Bool = true, giving: Set<String> = []) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription, mark: "exclamationmark.triangle")
            return
        }
        if ApplePasswordExtensionRoute.intercept(id, browser: browser) { return }
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed", mark: "puzzlepiece.extension")
            return
        }
        busy = id
        installErrors[id] = nil
        Task {
            defer { busy = nil }
            do {
                let crx = try await Crx.fetch(id)
                let target = Extensions.folder(for: id)
                let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
                // Checked, unpacked and given the shim away from the main
                // thread, as a synced one is: AdBlock's package held the
                // window still for seconds.
                try await Task.detached(priority: .userInitiated) {
                    try Crx.unpack(try Crx.verifiedZip(crx, id: id), into: staged)
                    try ExtensionShims.prepare(staged, fresh: true)
                }.value
                try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing, giving: giving)
            } catch {
                installErrors[id] = String(describing: error)
                NSLog("Extensions: couldn't install %@: %@", id, String(describing: error))
                // Ours are short; the system's, a network's, aren't.
                let said = (error as? Crx.Refused)?.localizedDescription ?? "Couldn't install that extension"
                browser?.announce(said, mark: "exclamationmark.triangle")
            }
        }
    }

    /// Test-only installation from a frozen, still-verified store package.
    @discardableResult
    func installFrozen(_ id: String, at source: URL, giving: Set<String> = []) -> Bool {
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { return false }
        guard Store.testing, Crx.id(in: id) == id, !installed.contains(where: { $0.id == id }) else { return false }
        busy = id
        installErrors[id] = nil
        Task {
            defer { busy = nil }
            do {
                let target = Extensions.folder(for: id)
                let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try await Task.detached(priority: .userInitiated) {
                    let crx = try Data(contentsOf: source)
                    try self.prepareReview(crx, id: id, into: staged)
                }.value
                try await admit(staged, as: id, fromStore: true, finalFolder: target,
                                confirm: false, giving: giving)
            } catch {
                installErrors[id] = String(describing: error)
                NSLog("Extensions: couldn't install frozen %@: %@", id, String(describing: error))
                browser?.announce("Couldn't install that extension", mark: "exclamationmark.triangle")
            }
        }
        return true
    }

    /// One installed on another Mac, its package fetched here (SyncInstalls):
    /// checked as any from the store is, and put in without asking, since
    /// it was asked for there, on or off and pinned as it is there. One
    /// whose version here asks for more than it was allowed there comes in
    /// off, and asks when it is turned on.
    /// `wanted` is asked again right before it goes in: removed elsewhere
    /// while it was unpacked, it doesn't. True when it went in.
    @discardableResult
    func adoptSynced(_ id: String, crx: Data, enabled: Bool, pinned: Bool, allowed: [String], wanted: @escaping () -> Bool = { true }) async throws -> Bool {
        guard loaded, !installed.contains(where: { $0.id == id }) else { return false }
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        // Checked, unpacked and given the shim away from the main thread, as
        // load() prepares one: a big package takes a second or more.
        try await Task.detached(priority: .utility) {
            do {
                try Crx.unpack(try Crx.verifiedZip(crx, id: id), into: staged)
                try ExtensionShims.prepare(staged, fresh: true)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
        }.value
        // Put in by the person, here, while it was on its way.
        guard !installed.contains(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: staged)
            return false
        }
        try await admit(staged, as: id, fromStore: true, finalFolder: Extensions.folder(for: id), confirm: false, quiet: true,
                        giving: Set(allowed), synced: Synced(enabled: enabled, pinned: pinned, allowed: allowed, wanted: wanted))
        return installed.contains { $0.id == id }
    }

    /// On or off and pinned as another Mac set them. One waiting to be
    /// allowed more stays off.
    func syncState(_ id: String, enabled: Bool, pinned: Bool) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        if (item.pinned ?? false) != pinned { setPinned(id, pinned) }
        let on = enabled && item.wants == nil
        if item.enabled != on { setEnabled(id, on) }
    }

    /// An unpacked extension from disk, a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        installFolder(at: source)
    }

    func installFolder(at source: URL, confirm: Bool = true, giving: Set<String> = []) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json", mark: "exclamationmark.triangle")
            return
        }
        let id: String
        do { id = try ChromiumExtensionPackages.unpackedID(source) }
        catch { browser?.announce("Can’t read the extension manifest", mark: "exclamationmark.triangle"); return }
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { return }
        guard !installed.contains(where: { $0.id == id }) else {
            browser?.announce("That extension is already installed", mark: "puzzlepiece.extension")
            return
        }
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged, fresh: true)
        } catch {
            browser?.announce("Couldn't copy the extension", mark: "exclamationmark.triangle")
            return
        }
        Task { try? await admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id), confirm: confirm || !Store.testing, source: source, giving: giving) }
    }

    /// Takes the extension up again, the way Chrome's reload button does
    /// in developer mode. One loaded from a folder is copied in afresh from
    /// that folder first, so what its author just saved is what runs.
    func reload(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), reloading.insert(id).inserted else { return }
        let target = Extensions.folder(for: id)
        let files = FileManager.default
        // A folder one is copied in beside the one running, and takes its
        // place only once it is read and, if it wants more, allowed.
        var staged: URL?
        if let path = installed[index].source {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                reloading.remove(id)
                browser?.announce("\(installed[index].name)'s folder is gone", mark: "exclamationmark.triangle")
                return
            }
            let copy = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
            do {
                try? files.removeItem(at: copy)
                try files.copyItem(at: source, to: copy)
                try ExtensionShims.prepare(copy, fresh: true)
            } catch {
                try? files.removeItem(at: copy)
                reloading.remove(id)
                browser?.announce("Couldn't reload \(installed[index].name)", mark: "exclamationmark.triangle")
                return
            }
            staged = copy
        }
        Task {
            defer { reloading.remove(id) }
            guard let item = installed.first(where: { $0.id == id }) else { return }
            let found = try? await WKWebExtension(resourceBaseURL: staged ?? target)
            if found == nil, let staged {
                try? files.removeItem(at: staged)
                browser?.announce("Can't read \(item.name)'s manifest", mark: "exclamationmark.triangle")
                return
            }
            // What it asks for now, against what it was allowed: more is
            // asked about, and a no keeps the one already running.
            if let found {
                let wants = Set(Extensions.grants(found, in: staged ?? target))
                let more = wants.subtracting(item.permissions)
                var nativeMore: Set<String> = []
                if let source = item.source,
                   let manifest = try? ChromiumExtensionPackages.manifest(in: URL(fileURLWithPath: source)),
                   let previous = ChromiumExtensionPackages.existingUnpacked(id),
                   let before = try? ChromiumExtensionPackages.manifest(in: previous) {
                    nativeMore = ChromiumExtensionGrants.required(in: manifest).subtracting(ChromiumExtensionGrants.required(in: before))
                }
                if !more.isEmpty || !nativeMore.isEmpty {
                    guard await ask(Question(
                        title: "\(found.displayName ?? item.name) wants more to reload",
                        detail: "Say no and the one running now stays as it is. Reloaded, it could also:",
                        lines: Extensions.describe(found, in: staged ?? target, only: more) + ChromiumInstallWords.lines(nativeMore),
                        icon: ExtensionIconShape.rounded(found.icon(for: CGSize(width: 64, height: 64))),
                        yes: "Reload", no: "Not Now", place: .plain
                    )) else {
                        // Turned down just now, in the question: nothing to say.
                        if let staged { try? files.removeItem(at: staged) }
                        return
                    }
                }
            }
            unload(id)
            ExtensionShims.clearMenus(id)
            errors[id] = nil
            if let staged {
                do {
                    try? files.removeItem(at: target)
                    try files.moveItem(at: staged, to: target)
                } catch {
                    try? files.removeItem(at: staged)
                    browser?.announce("Couldn't reload \(item.name)", mark: "exclamationmark.triangle")
                    return
                }
            }
            if let found, let index = installed.firstIndex(where: { $0.id == id }) {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = Extensions.grants(found, in: target)
                save()
            }
            guard let item = installed.first(where: { $0.id == id }) else { return }
            var nativeStarted = true
            for native in ChromiumExtensions.profiles.values where native.joined.map({ $0.signIn == signIn }) == true {
                do { try await native.reloadUnpacked(item) }
                catch {
                    native.failure = error.localizedDescription
                    native.loadFailures[id] = "Couldn’t run in Chromium: \(error.localizedDescription)"
                    native.compose()
                    nativeStarted = false
                }
            }
            guard item.enabled else { return }
            let started = await load(item) && nativeStarted
            browser?.announce(started ? "\(item.name) reloaded" : "\(item.name) didn't start", mark: started ? "puzzlepiece.extension" : "exclamationmark.triangle", feedback: started ? .success : nil)
        }
    }

    /// Extensions being reloaded, so a second click waits for the first.
    private var reloading: Set<String> = []

    /// An extension whose worker won't start again: unloaded and loaded,
    /// as a relaunch would, at most once a minute, so one that can never
    /// start doesn't go round in circles.
    private var revived: [String: Date] = [:]
    /// Recent failed native messages, per extension and host.
    private var failures: [String: [Date]] = [:]
    /// Its card up, asking 1Password's people to add Yab in the app (appUnreached).
    private var onePasswordAsking = false
    /// 1Password's extensions whose app wouldn't talk to Yab when they last
    /// called it: their row in Settings says so, and how to connect, until
    /// the app answers one of them (appUnreached, appReached).
    @Published private(set) var unconnected: Set<String> = []
    /// A reply from 1Password's native host in this browser session. This
    /// confirms the app link, not its vault state or a successful fill.
    @Published private(set) var onePasswordAnswered: Set<String> = []
    /// Extensions whose app on this Mac macOS killed as Yab started it:
    /// iCloud Passwords' helper, until Apple approves Yab. Their row in
    /// Settings says so (ExtensionDetail.stoppedLine).
    @Published private(set) var stoppedByMacOS: Set<String> = []

    /// Said on its row from now on.
    func macOSStopped(_ id: String) {
        if !stoppedByMacOS.contains(id) { stoppedByMacOS.insert(id) }
    }

    /// Loaded at least once since the browser started, and loaded again.
    private var loadsThisRun: Set<String> = []
    private(set) var loadedBefore: Set<String> = []
    /// Installed before this launch: in the list as it was read from disk.
    /// WebKit tells an extension "install" again as Yab starts (AdBlock
    /// opened its "installed" page on a later launch), where Chrome says
    /// nothing; such an "install" is told as the update it is (see the
    /// shim's onInstalled), so nothing opens a welcome page again.
    private var installedBeforeLaunch: Set<String> = []
    /// Brought in from another browser this run (ExtensionImport): there it
    /// was installed long ago, so its "install" is told as an update. Told
    /// "install", each one opened its welcome or sign-in page in front, one
    /// after another: Claude's OAuth tab bounced to claude.ai's login, among
    /// a dozen others, on a first import from Arc (feedback #135).
    var broughtIn: Set<String> = []
    /// What an "install" WebKit tells this extension really is: "reload",
    /// loaded before in this run, or brought in from another browser, which
    /// Chrome tells as an update; "launch", installed before Yab started,
    /// which Chrome tells nothing of (an update there opened Tampermonkey's
    /// changelog at every launch, feedback #112); nil, a real install.
    /// A load later in the same run is told "update" only when its version
    /// changed since (ExtensionInstallWord): told it on every load, Surfshark
    /// reloaded itself for ever (feedback #283).
    func startedBefore(_ id: String) -> String? {
        let item = installed.first(where: { $0.id == id })
        let now = contexts[id]?.webExtension.version ?? item?.version ?? ""
        defer { toldVersion[id] = now }
        return ExtensionInstallWord.word(loadedBefore: loadedBefore.contains(id), unpacked: item?.source != nil,
                                         broughtIn: broughtIn.contains(id), installedBeforeLaunch: installedBeforeLaunch.contains(id),
                                         told: toldVersion[id], now: now)
    }
    /// The version each was last told of in this run (startedBefore).
    private var toldVersion: [String: String] = [:]
    /// Its runtime.reload() calls, for Chrome's guard against a reload loop.
    private var fastReloads: [String: FastReloads] = [:]

    /// Whether the extension's own runtime.reload() goes ahead (the shim).
    func mayReload(_ id: String) -> Bool {
        let allowed = fastReloads[id, default: FastReloads()].allow()
        if !allowed { noteError("reloaded itself \(FastReloads.limit) times in a few seconds; Yab didn't reload it again", for: id) }
        return allowed
    }
    /// Enabled at launch and not loaded yet: their buttons show already.
    private(set) var starting: Set<String> = []
    /// Left asleep by the launch until their first use (ExtensionLaunch):
    /// their buttons show as the waiting ones do, and a press wakes them.
    @Published private(set) var asleep: Set<String> = []
    /// Woken by their first use after such a launch, until unloaded: what
    /// WebKit says to them on loading is not said (the shim's onInstalled).
    private var lateLoads: Set<String> = []
    /// Why each was loaded at launch or left asleep, for the bench.
    private(set) var plans: [String: (need: ExtensionLaunch.Need, why: String)] = [:]
    /// What each one's manifest says its button is called and its keys,
    /// read by the launch: the tip and keys of one not loaded yet.
    private(set) var tipFacts: [String: ExtensionTip.Facts] = [:]

    /// Its manifest and saved keys read again, after a key set for it.
    func refreshTipFacts(_ id: String) {
        let folder = Extensions.folder(for: id)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let storeKey = "extensions.keys.\(id)"
        var saved = Store.settings.dictionary(forKey: storeKey) ?? [:]
        // A manifest suggestion is not a user's assignment. Refuse a
        // taken key without freeing its owner, and keep that refusal so
        // freeing the browser key later does not silently assign it.
        for key in ExtensionTip.keys(manifest, saved: saved) where saved[key.command] == nil {
            let command = contexts[id]?.commands.first { $0.id == key.command }
            if Keymap.shared.clash(key.hotkey, for: nil, command: command) != nil {
                saved[key.command] = ["key": "", "flags": 0]
            }
        }
        if !saved.isEmpty { Store.settings.set(saved, forKey: storeKey) }
        tipFacts[id] = ExtensionTip.facts(manifest, folder: folder, saved: saved)
    }
    /// What each worker listened for in its last run (listeners.json).
    private lazy var heardEvents: [String: ExtensionLaunch.Heard] = ExtensionLaunch.read(from: ownFolder)
    /// Where its own files beside the list are: the shared one's in the
    /// extensions' folder, a space's own in a folder of its own.
    private var ownFolder: URL { signIn.map { Extensions.signIns.appendingPathComponent($0.uuidString, isDirectory: true) } ?? Extensions.folder }
    /// The events each worker was woken for with no listener of its own,
    /// this run (the shim's stand-ins), by name.
    private(set) var idleWakes: [String: [String: Int]] = [:]
    /// The badge and label each button last showed, for the first seconds
    /// of the next launch, before the extension has set them again.
    private lazy var lastFaces: [String: [String: String]] = (Store.settings.dictionary(forKey: kept("extensions.faces")) as? [String: [String: String]]) ?? [:]
    private var facesDirty = false
    /// One of those pressed before its turn came.
    private var pressWhenLoaded: String?

    func revive(_ id: String, because reason: String) {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return }
        revived[id] = Date()
        noteError("had to restart: \(reason)", for: id)
        // Its popup goes with it; it is opened again once the extension is back.
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        let anchor = anchors[id]?.view?.window != nil ? anchors[id]?.view : anchors[Extensions.menuAnchor]?.view
        unload(id)
        Task {
            guard await load(item), let popup, let context = contexts[id] else { return }
            ExtensionPopup.shared.show(popup, for: context, from: anchor)
        }
    }

    /// Taken up afresh without a word, its worker started again: what
    /// WebKit injects for it (registered content scripts) goes with the old
    /// context. For Move from Tampermonkey.
    func restart(_ id: String) async {
        guard contexts[id] != nil, let item = installed.first(where: { $0.id == id }), item.enabled else { return }
        unload(id)
        guard await load(item), let context = contexts[id] else { return }
        trace(id, "restart woke the worker")
        context.loadBackgroundContent { _ in }
    }

    /// WebKit's error arrays can contain dangling NSErrors, including the
    /// extension's initial manifest warnings (#124-#177). Reading domain/code
    /// crashed too; avoiding localizedDescription alone was insufficient.
    /// Keep this boundary free of both arrays and all error-object access.
    /// Worker failures are detected by checkWorker; Yab's own notes survive.
    static func read(errors context: WKWebExtensionContext) -> [String] {
        []
    }

    /// After WebKit says a context's errors changed: whether its worker
    /// failed to start, asked of the worker itself and not of `errors`
    /// (crash #61 was this read, inside the notification). A worker that
    /// runs answers loadBackgroundContent at once, with no error; one that
    /// failed to start never answers (ExtensionErrorReadTests), and
    /// an answer with an error is only checked for being there, never
    /// asked for its text. `within` is long: a big worker, 1Password's,
    /// takes several seconds to start on a slow Mac.
    static func checkWorker(_ context: WKWebExtensionContext, within: Duration = .seconds(20), failed: @escaping @MainActor @Sendable () -> Void) {
        guard context.webExtension.hasBackgroundContent else { return }
        let check = WorkerCheck()
        context.loadBackgroundContent { error in
            MainActor.assumeIsolated {
                guard !check.done else { return }
                check.done = true
                if error != nil { failed() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: within)
            guard !check.done else { return }
            check.done = true
            failed()
        }
    }
    @MainActor private final class WorkerCheck { var done = false }

    /// WebKit records a worker that failed to start as an error on its
    /// context, and then doesn't try again: the extension would be dead
    /// until someone noticed. It is taken up afresh as soon as that shows.
    private var errorWatchers: [String: NSObjectProtocol] = [:]
    private func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        contextErrors[id] = Self.read(errors: context)
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            // A turn later, out of WebKit's own call that posted it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let context, self.contexts[id] === context else { return }
                    self.trace(id, "WebKit noted an error")
                    Self.checkWorker(context) { [weak self, weak context] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self, let context, self.contexts[id] === context else { return }
                            self.revive(id, because: "its background worker didn't start")
                        }
                    }
                }
            }
        }
        // What it gives back through permissions.remove stays given back:
        // put back on the next launch, it would undo the extension's own
        // wish. Refined GitHub, given every site, hands it back as soon as
        // it is installed. While it waits to be pressed, yab itself takes
        // its sites back, and that isn't the extension's say.
        for old in removalWatchers[id] ?? [] { NotificationCenter.default.removeObserver(old) }
        let names: [Notification.Name] = [WKWebExtensionContext.grantedPermissionsWereRemovedNotification, WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification]
        removalWatchers[id] = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: context, queue: .main) { [weak self, weak context] note in
                let given = (note.userInfo?[WKWebExtensionContext.NotificationUserInfoKey.permissions] as? NSSet)?.compactMap { $0 as? String } ?? []
                let sites = (note.userInfo?[WKWebExtensionContext.NotificationUserInfoKey.matchPatterns] as? NSSet)?.compactMap { ($0 as? WKWebExtension.MatchPattern)?.string } ?? []
                MainActor.assumeIsolated {
                    if ExtensionShims.portTrace { self?.noteError("yab trace: \(name.rawValue) \(given + sites)", for: id) }
                    guard let self, let context, self.contexts[id] === context, self.access(id) == .asked else { return }
                    var choices = Extensions.choices(id)
                    let back = (given + sites).filter { choices[$0] == true && !self.tookBack($0, from: id) }
                    guard !back.isEmpty else { return }
                    for key in back { choices[key] = nil }
                    Extensions.setChoices(choices, for: id)
                    // WebKit takes what a site handed back covers with it,
                    // github.com with every site, though the extension
                    // still names it: given again, as a relaunch would.
                    self.applyAccess(context)
                    self.noteIfOverBudget(id)
                }
            }
        }
    }
    private var removalWatchers: [String: [NSObjectProtocol]] = [:]
    /// What yab itself has just kept from an extension, by key, for a
    /// moment after: WebKit says what went on a later turn of the main
    /// loop, not while yab sets it, and what yab took away, or what a
    /// denial took with it where two sites meet, isn't the extension
    /// handing it back. Only these keys are passed over, so the extension
    /// giving something back in that moment still counts.
    private var taking: [String: (keys: Set<String>, round: Int)] = [:]
    private var takingRound = 0

    /// yab is about to keep `keys` from it.
    private func take(_ keys: [String], from id: String) {
        guard !keys.isEmpty else { return }
        takingRound += 1
        let round = takingRound
        taking[id] = ((taking[id]?.keys ?? []).union(keys), round)
        // Long past the loop's next turn, and the extension's own first
        // word comes from its background worker, which takes longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.taking[id]?.round == round else { return }
            self.taking[id] = nil
        }
    }

    /// Whether WebKit saying `key` went is yab's own doing: a key yab
    /// just kept from it, or a site that meets one it did.
    private func tookBack(_ key: String, from id: String) -> Bool {
        guard let keys = taking[id]?.keys else { return false }
        if keys.contains(key) { return true }
        guard let pattern = try? WKWebExtension.MatchPattern(string: key) else { return false }
        return keys.contains { other in
            guard let taken = try? WKWebExtension.MatchPattern(string: other) else { return false }
            return taken.matches(pattern) || pattern.matches(taken)
        }
    }

    private func stopWatching(_ id: String) {
        taking[id] = nil
        for old in (removalWatchers.removeValue(forKey: id) ?? []) + [errorWatchers.removeValue(forKey: id)].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(old)
        }
    }

    func setUserScripts(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].userScripts != on else { return }
        installed[index].userScripts = on
        save()
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
        actionsChanged += 1
    }

    /// Password managers, by their Chrome Web Store ids. Yab pins one the
    /// first time it comes in: it is pressed to sign in and to fill, and a
    /// button left in the menu, with nothing on screen saying where it went,
    /// read as "it didn't install" (docs/evidence/launch-repro-2026-10-03/
    /// extensions.md).
    nonisolated static let passwordManagers: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // 1Password
        "khgocmkkpikpnmmkgmdnfckapcdkgfaf", // 1Password Beta
        "nngceckbapebfimnlniiiahkandclblb", // Bitwarden
        "eiaeiblijfjekdanodkjadfinkhbfgcd", // NordPass
        "fdjamakpfbbddfjaooikfcpapjohcfmg", // Dashlane
        "ghmbeldphafepmbegfdlkpapadhbakde", // Proton Pass
        "hdokiejnpimakedhajhdlcegeplioahd", // LastPass
        "bfogiafebfohielmmehodmfbbebbbpei", // Keeper
        "pejdijmoenmkgeppbflobdenhhabjlaj", // iCloud Passwords
    ]

    /// Apple's iCloud Passwords extensions: the two origins its helper's
    /// host file lets in (/Library/Google/Chrome/NativeMessagingHosts/
    /// com.apple.passwordmanager.json).
    nonisolated static let iCloudPasswords: Set<String> = [
        "pejdijmoenmkgeppbflobdenhhabjlaj", "mfbcdcnpokpoajjciilocoachedjkima",
    ]

    /// Whether one coming in is pinned by Yab: a password manager Yab has
    /// never pinned before. Once is all: unpinned, or removed and added
    /// again, it stays where the person put it.
    nonisolated static func pinsOnArrival(_ id: String, pinnedBefore: Set<String>) -> Bool {
        passwordManagers.contains(id) && !pinnedBefore.contains(id)
    }

    /// The ones Yab has pinned on arrival, ever, kept past their removal.
    private static var pinnedOnArrival: Set<String> {
        get { Set(Store.settings.stringArray(forKey: "extensions.pinnedOnArrival") ?? []) }
        set { Store.settings.set(newValue.sorted(), forKey: "extensions.pinnedOnArrival") }
    }

    /// A pinned one dragged onto another tile takes that one's place; the
    /// tiles follow the order extensions are kept in.
    func movePinned(_ id: String, to other: String) {
        guard id != other,
              let from = installed.firstIndex(where: { $0.id == id }),
              let to = installed.firstIndex(where: { $0.id == other })
        else { return }
        let item = installed.remove(at: from)
        installed.insert(item, at: to)
        save()
        actionsChanged += 1
    }

    /// One installed on another Mac (`adoptSynced`): on or off and pinned
    /// as it is there, and allowed what it was allowed there.
    struct Synced {
        let enabled: Bool
        let pinned: Bool
        let allowed: [String]
        /// Still wanted, asked after the last wait, right before it goes in.
        var wanted: () -> Bool = { true }
    }

    /// Reads what was unpacked, asks, and, on yes, moves it into place and
    /// loads it. On no, nothing is left behind.
    /// `quiet` is for a batch brought in from another browser, which is
    /// asked about once and announced once. `giving` is what was ticked
    /// of what it may ask for later, given now; the rest is asked about
    /// when the extension asks for it, as Chrome does, and so is all of it
    /// for a batch brought in from another browser. `synced`: from another
    /// Mac, put in as it is there, and loaded only if on.
    @discardableResult
    func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true, source: URL? = nil, quiet: Bool = false, giving: Set<String> = [], synced: Synced? = nil) async throws -> Bool {
        let files = FileManager.default
        if ApplePasswordExtensionRoute.matches(id) {
            // A sync is silent; an explicit install/import opens Connect.
            if synced == nil { ApplePasswordExtensionRoute.intercept(id, browser: browser) }
            try? files.removeItem(at: staged)
            return false
        }
        if let removal = removingData[id], !(await removal.task.value) {
            try? files.removeItem(at: staged)
            throw CocoaError(.fileWriteUnknown)
        }
        let found: WKWebExtension
        do {
            found = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        let name = found.displayName ?? id
        let wants = Extensions.describe(found, in: staged)
        let extras = Extensions.extras(of: found)
        var given = giving
        if confirm {
            let answer = await ask(install: name, wants: wants, extras: extras, icon: ExtensionIconShape.rounded(found.icon(for: CGSize(width: 64, height: 64))))
            guard answer.yes else {
                try? files.removeItem(at: staged)
                return false
            }
            given = answer.given
        }
        if let source, !fromStore, ChromiumExtensions.validID(id),
           ChromiumExtensionPackages.existingUnpacked(id) == nil {
            _ = try ChromiumExtensionPackages.prepareUnpacked(source, id: id)
        }
        // From another Mac, and removed there while this one read it: not put in.
        if let synced, !synced.wanted() {
            try? files.removeItem(at: staged)
            return false
        }
        // Read while its files are where it was read from.
        let picture = ExtensionIconShape.rounded(found.icon(for: CGSize(width: 128, height: 128)))
        // Another sign-in runs it from that folder: it stays, and this one
        // runs the same; updates come to both (`update`).
        if Extensions.installedElsewhere(id, than: signIn), files.fileExists(atPath: finalFolder.appendingPathComponent("manifest.json").path) {
            try? files.removeItem(at: staged)
        } else {
            try? files.removeItem(at: finalFolder)
            try files.moveItem(at: staged, to: finalFolder)
        }
        // A password manager comes in pinned, the first tile, the first time.
        let pins = synced == nil && Extensions.pinsOnArrival(id, pinnedBefore: Extensions.pinnedOnArrival)
        if pins { Extensions.pinnedOnArrival.insert(id) }
        let grants = Extensions.grants(found, in: finalFolder)
        let arrival = synced.map { SyncAddons.arrival(grants: grants, enabled: $0.enabled, allowed: $0.allowed) }
        // An ad blocker comes in turned off, and Yab asks which one should
        // block (Blockers): nothing compiles meanwhile, Shield blocks.
        let heldOff = synced == nil && signIn == nil && Blockers.arrivesOff(id, folder: finalFolder)
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: heldOff ? false : arrival?.enabled ?? true, fromStore: fromStore,
            permissions: arrival?.permissions ?? grants,
            installedAt: installed.first(where: { $0.id == id })?.installedAt ?? Date(),
            pinned: synced.map { $0.pinned ? true : nil } ?? (pins ? true : nil),
            source: source?.path,
            wants: arrival?.wants
        )
        installed.removeAll { $0.id == id }
        Extensions.setChoices([:], for: id)
        // Only what was ticked: one left unticked isn't kept from it, it is
        // asked about when the extension asks, so a runtime
        // permissions.request still reaches a question.
        let picks = extras.filter { given.contains($0.key) }
        if !picks.isEmpty {
            Extensions.choose(Dictionary(picks.map { ($0.key, true) }, uniquingKeysWith: { a, _ in a }), for: id)
        }
        // The first one puts the puzzle in the row, beside the downloads.
        withAnimation(installed.isEmpty ? Motion.room : nil) {
            if pins { installed.insert(item, at: 0) } else { installed.append(item) }
        }
        // One that came from another Mac was asked for there.
        if synced == nil {
            unseen.insert(id)
            keepUnseen()
        }
        save()
        if synced == nil { offerToConnect(id) }
        if heldOff {
            Blockers.arrived(id)
            return true
        }
        guard item.enabled else { return false }
        // From the store's page, its icon flies to the puzzle, and landing
        // is the notice.
        let flying = fromStore && !quiet && (browser?.arrived(id, name: name, icon: picture) ?? false)
        // WebKit takes an extension loaded in the controller's first five
        // seconds for one the browser started with: it hears
        // runtime.onStartup, never onInstalled, and so never opens its
        // welcome page. One added that soon after launch waits them out.
        let early = Extensions.startingFor - Date().timeIntervalSince(made)
        if early > 0 { try? await Task.sleep(for: .seconds(early)) }
        let rests = Extensions.restsForChromium && !launchBegan
        let started = await load(item) || rests
        if !quiet, !(flying && started) {
            browser?.announce(started ? "\(name) installed" : "\(name) didn't start", mark: started ? "puzzlepiece.extension" : "exclamationmark.triangle", feedback: started ? .success : nil)
        }
        return started
    }

    // MARK: - adding, a page at a time

    /// An extension fetched or copied, unpacked and read, waiting on the yes
    /// that Settings asks for on its own page rather than in an alert.
    struct Candidate: Identifiable {
        let id: String
        let fromStore: Bool
        let staged: URL
        let source: URL?
        let name: String
        let version: String
        let about: String
        let icon: NSImage?
        let wants: [String]
        /// What it may ask for later, each ticked unless unticked here.
        let extras: [Extra]
        let shortcuts: Int
        /// Original native package; staged is only the review/WebKit copy.
        var chromiumFolder: URL? = nil
        var packageName: String? = nil
    }

    enum NotAdded: LocalizedError {
        case already(String), noManifest

        var errorDescription: String? {
            switch self {
            case .already(let name): return "\(name) is in Yab already."
            case .noManifest: return "That folder has no manifest.json."
            }
        }
    }

    /// A store link or id, fetched and checked the way any install is.
    func prepare(link text: String, chromium: ChromiumExtensions? = nil) async throws -> Candidate {
        guard let id = Crx.id(in: text) else { throw Crx.Refused.notAnID }
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { throw CancellationError() }
        if let here = installed.first(where: { $0.id == id }) { throw NotAdded.already(here.name) }
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            let data: Data
            if chromium != nil { data = try await ChromiumExtensionPackages.fetch(id) }
            else { data = try await Crx.fetch(id) }
            let native = try chromium.map { _ in try ChromiumExtensionPackages.prepare(data, id: id, root: Store.file("ChromiumPackages")) }
            let zip = try Crx.verifiedZip(data, id: id)
            try? FileManager.default.removeItem(at: staged)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            return try await candidate(id: id, staged: staged, fromStore: true, source: nil, chromium: chromium, native: native)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// A chosen CRX uses the same verified package and review as a store link.
    func prepare(package source: URL, chromium: ChromiumExtensions? = nil) async throws -> Candidate {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        let id = try Crx.id(inPackage: data)
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { throw CancellationError() }
        if let here = installed.first(where: { $0.id == id }) { throw NotAdded.already(here.name) }
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try prepareReview(data, id: id, into: staged)
            let manifest = try ChromiumExtensionPackages.manifest(in: staged)
            let eligible = Self.storeUpdateURL(manifest["update_url"] as? String)
            let fromStore: Bool
            if eligible {
                // A manifest alone cannot claim the store. Ask it for this ID
                // and authenticate its answer with the developer's same key.
                let served = try? await ChromiumExtensionPackages.fetch(id)
                fromStore = served.map { (try? Crx.verifiedPackage($0, id: id)) != nil } ?? false
            } else { fromStore = false }
            // Local packages keep an owned original folder for engine switching
            // and restart, just like approved unpacked extensions.
            let native = try ChromiumExtensionPackages.prepare(data, id: id, root: Store.file("ChromiumPackages"))
            var found = try await candidate(id: id, staged: staged, fromStore: fromStore,
                                            source: fromStore ? nil : native, chromium: chromium, native: native)
            found.packageName = source.lastPathComponent
            return found
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    nonisolated static func storeUpdateURL(_ text: String?) -> Bool {
        guard let text else { return true }
        guard let url = URL(string: text) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.lowercased() == "clients2.google.com"
            && url.path == "/service/update2/crx" && url.user == nil && url.password == nil && url.port == nil
    }

    /// Shared with the fixture-only install entry point; never bypass signatures.
    nonisolated private func prepareReview(_ data: Data, id: String, into staged: URL) throws {
        try Crx.unpack(try Crx.verifiedZip(data, id: id), into: staged)
        try ExtensionShims.prepare(staged, fresh: true)
    }

    /// A folder with a manifest.json, copied in so moving it breaks nothing.
    func prepare(folder source: URL, chromium: ChromiumExtensions? = nil) async throws -> Candidate {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { throw NotAdded.noManifest }
        if let here = installed.first(where: { $0.source == source.path }) { throw NotAdded.already(here.name) }
        let id = try ChromiumExtensionPackages.unpackedID(source)
        guard !ApplePasswordExtensionRoute.intercept(id, browser: browser) else { throw CancellationError() }
        if let here = installed.first(where: { $0.id == id }) { throw NotAdded.already(here.name) }
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try files.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            let native = try chromium.map { _ in try ChromiumExtensionPackages.prepareUnpacked(source, id: id) }
            return try await candidate(id: id, staged: staged, fromStore: false, source: source, chromium: chromium, native: native)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    private func candidate(id: String, staged: URL, fromStore: Bool, source: URL?, chromium: ChromiumExtensions? = nil, native: URL? = nil) async throws -> Candidate {
        let found = try await WKWebExtension(resourceBaseURL: staged)
        let wants: [String]
        if let chromium, let native { wants = try await chromium.installLines(found, folder: native) }
        else { wants = Extensions.describe(found, in: staged) }
        return Candidate(
            id: id, fromStore: fromStore, staged: staged, source: source,
            name: found.displayName ?? id,
            version: found.displayVersion ?? found.version ?? "",
            about: found.displayDescription ?? "",
            icon: ExtensionIconShape.rounded(found.icon(for: CGSize(width: 128, height: 128))),
            wants: wants,
            extras: Extensions.extras(of: found),
            // Its commands are only listed on a context; this one is never loaded.
            shortcuts: WKWebExtensionContext(for: found).commands.count,
            chromiumFolder: native
        )
    }

    /// The yes: moved into place and started. False when WebKit couldn't
    /// start it, it is installed all the same.
    func add(_ candidate: Candidate, giving: Set<String> = []) async -> Bool {
        do {
            return try await admit(candidate.staged, as: candidate.id, fromStore: candidate.fromStore,
                                   finalFolder: Extensions.folder(for: candidate.id), confirm: false,
                                   source: candidate.source, quiet: true, giving: giving)
        } catch {
            return false
        }
    }

    /// The no, or leaving the page: nothing is left behind.
    func discard(_ candidate: Candidate) {
        try? FileManager.default.removeItem(at: candidate.staged)
    }

    func remove(_ id: String) {
        let context = contexts[id]
        starting.remove(id)
        asleep.remove(id)
        forgetFace(id)
        unload(id)
        stopWatching(id)
        errors[id] = nil
        unconnected.remove(id)
        stoppedByMacOS.remove(id)
        // Another sign-in that has it keeps its folder, and what was chosen
        // for it, which is the extension's wherever it runs.
        let elsewhere = Extensions.installedElsewhere(id, than: signIn)
        if !elsewhere {
            Extensions.setSettings([:], for: id)
            Store.settings.removeObject(forKey: "extensions.granted.\(id)")
            ExtensionShims.clearMenus(id)
        }
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        toldVersion[id] = nil
        fastReloads[id] = nil
        installedBeforeLaunch.remove(id)
        broughtIn.remove(id)
        if signIn == nil { Blockers.removed(id) }
        if !elsewhere {
            Store.settings.removeObject(forKey: "extensions.newtab.\(id)")
            for key in ["access", "allowed", "blocked", "keys", "optional"] { Store.settings.removeObject(forKey: "extensions.\(key).\(id)") }
        }
        // The last one takes the puzzle out of the row the way it came.
        withAnimation(installed.count == 1 ? Motion.room : nil) { installed.removeAll { $0.id == id } }
        save()
        if !elsewhere {
            try? FileManager.default.removeItem(at: Extensions.folder(for: id))
            if let native = ChromiumExtensionPackages.existingUnpacked(id) { try? FileManager.default.removeItem(at: native) }
        }
        forgetData(of: id, context: context)
    }

    /// Everything a removed extension kept, gone with it, as its card says
    /// and as in Chrome. WebKit files its storage and the version it last
    /// saw under its id, and its pages' and worker's data under its origin,
    /// and keeps both after it is unloaded: added again, the same extension
    /// came back to the state it was removed in.
    private func forgetData(of id: String, context: WKWebExtensionContext?) {
        let previous = removingData[id]?.task
        let token = UUID()
        let folder = storage(of: id)
        let root = Extensions.generalStorage(of: store)
        // Unload stops the worker, but its queued storage writes can still
        // own SQLite files. Let WebKit delete its stores before removing
        // the remaining state, and keep a reinstall behind that completion.
        removingData[id] = (token, Task {
            // A failed cleanup can refuse its current waiter, but must not
            // keep a later installation or load blocked until relaunch.
            defer { if removingData[id]?.token == token { removingData[id] = nil } }
            if let previous { _ = await previous.value }
            // Session storage is in memory and was discarded by unload.
            let types: Set<WKWebExtension.DataType> = [.local, .synchronized]
            let records: [WKWebExtension.DataRecord]
            if let context {
                records = await controller.dataRecord(ofTypes: types, for: context).map { [$0] } ?? []
            } else {
                records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
            }
            let errors = await removeStorageData(controller, types, records)
            guard errors.isEmpty else {
                NSLog("Extensions: couldn't remove storage for %@: %@", id, errors.description)
                return false
            }
            do {
                if let folder, FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
            } catch {
                NSLog("Extensions: couldn't remove state for %@: %@", id, error.localizedDescription)
                return false
            }
            if let root {
                await Task.detached(priority: .utility) { Extensions.forgetOrigins(of: [id], only: nil, in: root) }.value
            }
            return true
        })
    }

    /// Where WebKit files an extension's storage and state, its compiled
    /// declarativeNetRequest rules among them.
    func storage(of id: String) -> URL? {
        let key = "_storageDirectoryPath"
        let configuration = controller.configuration
        guard configuration.responds(to: NSSelectorFromString(key)), let path = configuration.value(forKey: key) as? String else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent(id, isDirectory: true)
    }

    /// The folders of the website data store an extension's origin has,
    /// `only` one kind of data in each, or all of it.
    ///
    /// "ServiceWorkers" at launch: WebKit keeps an extension's service
    /// worker registered between launches, in its origin's folder, and
    /// takes the next launch's worker up from that registration. On macOS
    /// 26.5 such a worker often never runs: WebKit takes it for started,
    /// reports nothing and queues every event behind it, so the button
    /// does nothing, no page opens, the worker never sleeps, and removing
    /// and adding the extension again doesn't help (NordPass on Gmail).
    /// One registered afresh, as on the day it was installed, runs. So the
    /// registrations go before the extensions load, and WebKit makes them
    /// again as each one starts.
    nonisolated static func forgetOrigins(of ids: Set<String>, only part: String?, in root: URL) {
        guard !ids.isEmpty else { return }
        let files = FileManager.default
        let marker = Data("chrome-extension".utf8)
        let wanted = ids.map { Data($0.utf8) }
        for top in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for origin in (try? files.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)) ?? [] {
                if let part, !files.fileExists(atPath: origin.appendingPathComponent(part).path) { continue }
                // A few bytes saying which origin, under which top origin.
                guard let said = try? Data(contentsOf: origin.appendingPathComponent("origin")),
                      said.range(of: marker) != nil, wanted.contains(where: { said.range(of: $0) != nil }) else { continue }
                try? files.removeItem(at: part.map { origin.appendingPathComponent($0) } ?? origin)
            }
        }
    }

    /// A space's own store, just made (Spaces.store): its sign-in's
    /// extensions' worker registrations go now, before a page of it asks
    /// the store for its service workers. Swept only as its extensions
    /// launched, after the shared ones, the store was in use already by
    /// the space's pages restored at launch, and the worker WebKit then
    /// took up never ran: no answer to any page of the space, a new one
    /// too, until a relaunch (#356, evals/extensions/wallet_sign_ins.py,
    /// adhd). A list not written yet (before the split) is swept at its
    /// launch.
    static func storeMade(_ store: WKWebsiteDataStore, signIn: UUID) {
        guard let list = unread(signIn), let root = generalStorage(of: store) else { return }
        forgetOrigins(of: Set(list.filter(\.enabled).map(\.id)), only: "ServiceWorkers", in: root)
        sweptWorkers.insert(signIn)
    }

    /// The sign-ins whose stores were swept as they were made (`storeMade`).
    static var sweptWorkers: Set<UUID> = []

    /// Where the website data store keeps each origin's data.
    static func generalStorage(of store: WKWebsiteDataStore) -> URL? {
        guard store.responds(to: NSSelectorFromString("_configuration")),
              let configuration = store.value(forKey: "_configuration") as? NSObject,
              configuration.responds(to: NSSelectorFromString("generalStorageDirectory"))
        else { return nil }
        return configuration.value(forKey: "generalStorageDirectory") as? URL
    }

    // MARK: - new tab pages

    /// The page an extension asks to show in new tabs, from the one added
    /// last, once you've said yes to it. Nil while nobody asks, or you
    /// said no.
    var newTabPage: URL? {
        guard let (id, url) = newTabCandidate else { return nil }
        return Store.settings.object(forKey: "extensions.newtab.\(id)") as? Bool == true ? url : nil
    }

    private var newTabCandidate: (String, URL)? {
        for item in installed.reversed() where item.enabled {
            if let url = contexts[item.id]?.overrideNewTabPageURL { return (item.id, url) }
        }
        return nil
    }

    /// Chrome asks the first time an extension's page takes the place of
    /// the new tab, an extension that did it quietly could be anything.
    /// So does yab, and then hands the page to `show`, for ⌘T's field to
    /// give way to it.
    func offerNewTabPage(then show: @escaping (URL) -> Void) {
        guard let (id, url) = newTabCandidate, Store.settings.object(forKey: "extensions.newtab.\(id)") == nil,
              let name = installed.first(where: { $0.id == id })?.name else { return }
        Task {
            let yes = await ask(Question(
                title: "Let “\(name)” draw your new tabs?",
                detail: "Settings › Extensions can turn this off later.",
                icon: ExtensionIconShape.rounded(contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64))),
                yes: "Allow", no: "Don’t Allow"
            ))
            Store.settings.set(yes, forKey: "extensions.newtab.\(id)")
            if yes { show(url) }
        }
    }

    /// What an extension set through chrome.privacy and chrome.proxy.
    static func settings(for id: String) -> [String: Any] {
        Store.settings.dictionary(forKey: "extensions.settings.\(id)") ?? [:]
    }

    static func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { Store.settings.removeObject(forKey: "extensions.settings.\(id)") }
        else { Store.settings.set(values, forKey: "extensions.settings.\(id)") }
    }

    /// The extension, on and running, that asked the browser not to offer to
    /// save passwords, a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        installed.first { $0.enabled && Extensions.settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false }?.name
    }

    func setEnabled(_ id: String, _ on: Bool) {
        if on, ApplePasswordExtensionRoute.intercept(id, browser: browser) { return }
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        if !on { starting.remove(id); asleep.remove(id) }
        if on, installed[index].wants != nil {
            Task { await allow(id) }
            return
        }
        installed[index].enabled = on
        save()
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
        }
        if signIn == nil { Blockers.enabledByHand(id, on) }
    }

    /// One that came from another Mac at a version asking for more than it
    /// was allowed there, turned on: asked about the way an update that
    /// wants more is, and on only after a yes.
    private func allow(_ id: String) async {
        guard let item = installed.first(where: { $0.id == id }), let wants = item.wants else { return }
        let folder = Extensions.folder(for: id)
        guard let found = try? await WKWebExtension(resourceBaseURL: folder) else { return }
        guard await ask(Question(
            title: "\(item.name) wants more",
            detail: "Its version here asks for more than your other Mac allowed. Turned on, it could also:",
            lines: Extensions.describe(found, in: folder, only: Set(wants)),
            icon: ExtensionIconShape.rounded(found.icon(for: CGSize(width: 64, height: 64))),
            yes: "Turn On", no: "Not Now", place: .plain
        )), let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].permissions = Extensions.grants(found, in: folder)
        installed[index].wants = nil
        installed[index].enabled = true
        save()
        await load(installed[index])
    }

    // MARK: - where each may reach, and its keys

    /// Where an extension reads and changes pages: every site its manifest
    /// names, only the sites chosen (Chrome's "On specific sites"), or only
    /// the page it is pressed on, Chrome's "On click". That one leans on
    /// activeTab, so it is only offered to those that ask for it.
    enum SiteAccess: String { case asked, sites, click }

    func access(_ id: String) -> SiteAccess {
        Store.settings.string(forKey: "extensions.access.\(id)").flatMap(SiteAccess.init) ?? .asked
    }

    /// Sites kept from it whatever else it may reach, by host.
    func blocked(_ id: String) -> [String] {
        Store.settings.stringArray(forKey: "extensions.blocked.\(id)") ?? []
    }

    /// The only sites it runs on, while its access is `.sites`, by host.
    func allowed(_ id: String) -> [String] {
        Store.settings.stringArray(forKey: "extensions.allowed.\(id)") ?? []
    }

    /// What `applyAccess` gives an extension, from the settings above.
    struct AccessPlan {
        var access: SiteAccess
        var allowed: [String]
        var blocked: [String]
        var choices: [String: Bool]
    }

    func accessPlan(_ id: String) -> AccessPlan {
        AccessPlan(access: access(id), allowed: allowed(id), blocked: blocked(id), choices: Extensions.choices(id))
    }

    /// Every loaded extension's content scripts within WebKit's IPC budget,
    /// `id`'s counted under `grants`.
    private func checkBudget(_ id: String, _ grants: WebKitIPCBoundary.Grants) throws {
        var catalogs: [(folder: URL, grants: WebKitIPCBoundary.Grants?)] = contexts.filter { $0.key != id }
            .map { (folder: Extensions.folder(for: $0.key), grants: WebKitIPCBoundary.Grants($0.value)) }
        catalogs.append((folder: Extensions.folder(for: id), grants: grants))
        try WebKitIPCBoundary.validateExtensions(catalogs)
    }

    /// An unloaded copy of a loaded context's site grants, to try a change on.
    func trial(of live: WKWebExtensionContext) -> WKWebExtensionContext {
        let trial = WKWebExtensionContext(for: live.webExtension)
        // Denials first: WebKit drops the grants a denial overlaps.
        for (pattern, until) in live.deniedPermissionMatchPatterns {
            trial.setPermissionStatus(.deniedExplicitly, for: pattern, expirationDate: until)
        }
        for (pattern, until) in live.grantedPermissionMatchPatterns {
            trial.setPermissionStatus(.grantedExplicitly, for: pattern, expirationDate: until)
        }
        return trial
    }

    /// Whether `change` to a loaded extension's site grants keeps every
    /// loaded extension's scripts in the budget. Tried on `trial(of:)`, so a
    /// refusal leaves its grants and settings as they were.
    func admits(_ id: String, _ change: (WKWebExtensionContext) -> Void) -> Bool {
        guard let live = contexts[id] else { return true }
        let trial = trial(of: live)
        change(trial)
        let fileAccess = WebKitIPCBoundary.Grants.fileAccess(of: live)
        let proposed = WebKitIPCBoundary.Grants(trial, fileAccess: fileAccess)
        do {
            try checkBudget(id, proposed)
            return true
        } catch {
            // Never refused for taking access away: no more scripts than it has now.
            if let groups = try? WebKitIPCBoundary.catalogGroups(at: Extensions.folder(for: id)),
               WebKitIPCBoundary.injectedScripts(groups, grants: proposed)
                <= WebKitIPCBoundary.injectedScripts(groups, grants: WebKitIPCBoundary.Grants(live, fileAccess: fileAccess)) {
                return true
            }
            noteError("Not given more sites: its content scripts would pass WebKit's limit for all extensions", for: id, counted: false)
            return false
        }
    }

    /// After access was taken away, which is never refused: losing all hosts
    /// can still expand it into more scripts than before, so say so.
    private func noteIfOverBudget(_ id: String) {
        guard let live = contexts[id], (try? checkBudget(id, WebKitIPCBoundary.Grants(live))) == nil else { return }
        NSLog("Extensions: %@ passed WebKit's script budget after access was taken away", id)
        noteError("Its content scripts now pass WebKit's limit for all extensions; it won't load next launch", for: id, counted: false)
    }

    /// Whether choosing `picks` for its extras keeps it in the budget.
    func admits(choices picks: [String: Bool], for id: String) -> Bool {
        var plan = accessPlan(id)
        plan.choices.merge(picks) { _, new in new }
        return admits(id) { _ = Extensions.apply(plan, to: $0) }
    }

    @discardableResult
    func allow(_ host: String, for id: String) -> Bool {
        let list = allowed(id)
        guard !list.contains(host) else { return true }
        var plan = accessPlan(id)
        plan.allowed.append(host)
        guard admits(id, { _ = Extensions.apply(plan, to: $0) }) else { return false }
        Store.settings.set(list + [host], forKey: "extensions.allowed.\(id)")
        objectWillChange.send()
        Extensions.listsChanged.send()
        if let context = contexts[id] { applyAccess(context) }
        return true
    }

    func disallow(_ host: String, for id: String) {
        Store.settings.set(allowed(id).filter { $0 != host }, forKey: "extensions.allowed.\(id)")
        objectWillChange.send()
        Extensions.listsChanged.send()
        guard let context = contexts[id] else { return }
        for pattern in Extensions.patterns(for: host) { context.setPermissionStatus(.unknown, for: pattern) }
        applyAccess(context)
        noteIfOverBudget(id)
    }

    @discardableResult
    func setAccess(_ id: String, _ access: SiteAccess) -> Bool {
        var plan = accessPlan(id)
        plan.access = access
        // The chosen sites go back to what the manifest says of them.
        let reset = { (context: WKWebExtensionContext) in
            for host in plan.allowed {
                for pattern in Extensions.patterns(for: host) { context.setPermissionStatus(.unknown, for: pattern) }
            }
        }
        // Only all its sites can widen past the budget: chosen sites are cut to fit.
        guard access != .asked || self.access(id) == .asked
              || admits(id, { reset($0); _ = Extensions.apply(plan, to: $0) }) else {
            // The picker bound to it goes back to the access it still has.
            objectWillChange.send()
            return false
        }
        if access == .asked { Store.settings.removeObject(forKey: "extensions.access.\(id)") }
        else { Store.settings.set(access.rawValue, forKey: "extensions.access.\(id)") }
        objectWillChange.send()
        Extensions.listsChanged.send()
        guard let context = contexts[id] else { return true }
        reset(context)
        applyAccess(context)
        noteIfOverBudget(id)
        return true
    }

    /// Sites chosen on another engine, kept whole: WebKit is given those that fit.
    func adopt(sites hosts: [String], for id: String) {
        var list = allowed(id)
        for host in hosts where !list.contains(host) { list.append(host) }
        Store.settings.set(list, forKey: "extensions.allowed.\(id)")
        objectWillChange.send()
        Extensions.listsChanged.send()
        if let context = contexts[id] { applyAccess(context) }
    }

    func block(_ host: String, for id: String) {
        let list = blocked(id)
        guard !list.contains(host) else { return }
        Store.settings.set(list + [host], forKey: "extensions.blocked.\(id)")
        objectWillChange.send()
        guard let context = contexts[id] else { return }
        applyAccess(context)
        noteIfOverBudget(id)
    }

    @discardableResult
    func unblock(_ host: String, for id: String) -> Bool {
        var plan = accessPlan(id)
        plan.blocked.removeAll { $0 == host }
        let reset = { (context: WKWebExtensionContext) in
            for pattern in Extensions.patterns(for: host) { context.setPermissionStatus(.unknown, for: pattern) }
        }
        guard admits(id, { reset($0); _ = Extensions.apply(plan, to: $0) }) else { return false }
        Store.settings.set(plan.blocked, forKey: "extensions.blocked.\(id)")
        objectWillChange.send()
        guard let context = contexts[id] else { return true }
        reset(context)
        applyAccess(context)
        return true
    }

    /// A host and everything under it.
    static func patterns(for host: String) -> [WKWebExtension.MatchPattern] {
        ["*://\(host)/*", "*://*.\(host)/*"].compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    /// The host someone typed or pasted, as it is kept: "https://www.bank.com/x"
    /// and "bank.com" are both bank.com.
    static func host(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
        guard var host = url?.host(), host.contains("."), !host.contains(" ") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func applyAccess(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if ExtensionShims.portTrace { noteError("yab trace: applyAccess", for: id) }
        var plan = accessPlan(id)
        let fit = sitesThatFit(plan, on: context)
        let left = Array(plan.allowed.dropFirst(fit))
        plan.allowed = Array(plan.allowed.prefix(fit))
        for host in left {
            for pattern in Extensions.patterns(for: host) { context.setPermissionStatus(.unknown, for: pattern) }
        }
        take(Extensions.apply(plan, to: context), from: id)
        guard !left.isEmpty else { return }
        let note = "Not running on \(left.joined(separator: ", ")): its content scripts would pass WebKit's limit for all extensions"
        guard errors[id]?.contains(note) != true else { return }
        NSLog("Extensions: %@ runs on %d of its chosen sites under WebKit's script budget", id, fit)
        noteError(note, for: id, counted: false)
    }

    /// How many of `plan`'s chosen sites, in the order chosen, fit the
    /// budget beside every other loaded extension. All of them when even
    /// none would fit: that is over for another reason, `noteIfOverBudget`'s.
    private func sitesThatFit(_ plan: AccessPlan, on live: WKWebExtensionContext) -> Int {
        let id = live.uniqueIdentifier
        guard plan.access == .sites, !plan.allowed.isEmpty,
              let groups = try? WebKitIPCBoundary.catalogGroups(at: Extensions.folder(for: id)) else { return plan.allowed.count }
        let others = contexts.filter { $0.key != id }.reduce(0) { total, other in
            let theirs = (try? WebKitIPCBoundary.catalogGroups(at: Extensions.folder(for: other.key))) ?? []
            return total + WebKitIPCBoundary.injectedScripts(theirs, grants: WebKitIPCBoundary.Grants(other.value))
        }
        let fileAccess = WebKitIPCBoundary.Grants.fileAccess(of: live)
        func fits(_ count: Int) -> Bool {
            var some = plan
            some.allowed = Array(plan.allowed.prefix(count))
            let trial = trial(of: live)
            for host in plan.allowed.dropFirst(count) {
                for pattern in Extensions.patterns(for: host) { trial.setPermissionStatus(.unknown, for: pattern) }
            }
            _ = Extensions.apply(some, to: trial)
            let own = WebKitIPCBoundary.injectedScripts(groups, grants: WebKitIPCBoundary.Grants(trial, fileAccess: fileAccess))
            return others + own <= WebKitIPCBoundary.scriptLimit
        }
        if fits(plan.allowed.count) || !fits(0) { return plan.allowed.count }
        // Each site only adds scripts, so the ones that fit are a prefix.
        var low = 0, high = plan.allowed.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// `plan` set on `context`'s site grants; returns the keys it keeps from it.
    static func apply(_ plan: AccessPlan, to context: WKWebExtensionContext) -> [String] {
        var taken: [String] = []
        let status: WKWebExtensionContext.PermissionStatus = plan.access == .asked ? .grantedExplicitly : .unknown
        let named = context.webExtension.allRequestedMatchPatterns
        for pattern in named {
            // Given, a pattern inside another it names is given already:
            // WebKit adds an extension's scripts once for each granted
            // pattern of a page's host, paths aside, so a content script for
            // www.youtube.com/* beside ones for its /embed/*, /live_chat*
            // and /shorts/* ran four times in every page, and Enhancer for
            // YouTube's features with it (feedback #306,
            // evals/feedback-306). Of two that take in each other, one.
            if status == .grantedExplicitly, named.contains(where: { other in
                other != pattern && other.matches(pattern) && (!pattern.matches(other) || other.string < pattern.string)
            }) { continue }
            context.setPermissionStatus(status, for: pattern)
            if status != .grantedExplicitly { taken.append(pattern.string) }
        }
        // The sites it may ask for later, as chosen: given only while it
        // reaches the sites it names at all, kept from it either way.
        // Keys that read as patterns are sites; the rest are permissions.
        // A site kept from it that overlaps one it names, every site over
        // github.com, is only not given: denied, it would take the named
        // one with it, and a denial wins where two meet.
        for (key, on) in plan.choices {
            guard let pattern = try? WKWebExtension.MatchPattern(string: key) else { continue }
            let overlaps = named.contains { $0.matches(pattern) || pattern.matches($0) }
            let kept: WKWebExtensionContext.PermissionStatus = overlaps ? .unknown : .deniedExplicitly
            let set: WKWebExtensionContext.PermissionStatus = !on ? kept : status == .grantedExplicitly ? .grantedExplicitly : .unknown
            context.setPermissionStatus(set, for: pattern)
            if set != .grantedExplicitly { taken.append(key) }
        }
        // Only the sites chosen: given whether or not its manifest names
        // them one by one, as Chrome gives them; an extension that names
        // every site names these too.
        if plan.access == .sites {
            for host in plan.allowed {
                for pattern in Extensions.patterns(for: host) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                    taken.removeAll { $0 == pattern.string }
                }
            }
        }
        for host in plan.blocked {
            for pattern in Extensions.patterns(for: host) {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
                taken.append(pattern.string)
            }
        }
        return taken
    }

    /// A key someone gave one of its commands, or none. WebKit leaves
    /// keeping them to the app: they are put back each time it loads.
    func setKey(_ key: String?, _ flags: NSEvent.ModifierFlags, for command: WKWebExtension.Command) {
        command.activationKey = key
        command.modifierFlags = key == nil ? [] : flags
        guard let id = command.webExtensionContext?.uniqueIdentifier else { return }
        var all = Store.settings.dictionary(forKey: "extensions.keys.\(id)") ?? [:]
        all[command.id] = ["key": key ?? "", "flags": Int(key == nil ? 0 : flags.rawValue)]
        Store.settings.set(all, forKey: "extensions.keys.\(id)")
        objectWillChange.send()
    }

    private func applyKeys(_ context: WKWebExtensionContext) {
        refreshTipFacts(context.uniqueIdentifier)
        let saved = Store.settings.dictionary(forKey: "extensions.keys.\(context.uniqueIdentifier)") ?? [:]
        for command in context.commands {
            if let entry = saved[command.id] as? [String: Any], let key = entry["key"] as? String {
                command.activationKey = key.isEmpty ? nil : key
                command.modifierFlags = key.isEmpty ? [] : NSEvent.ModifierFlags(rawValue: UInt(entry["flags"] as? Int ?? 0))
            } else if let key = command.activationKey.map({ Hotkey($0, command.modifierFlags) }),
                      Keymap.shared.clash(key, for: nil, command: command) != nil {
                setKey(nil, [], for: command)
            }
        }
    }

    func openOptions(_ id: String) {
        if asleep.contains(id) { return wake(id) { [weak self] in self?.openOptions(id) } }
        guard let url = contexts[id]?.optionsPageURL else { return }
        opening()?.open(url, foreground: true)
    }

    // MARK: - updates

    /// Once a day, the store is asked whether anything installed from it has
    /// a newer version; if so it is fetched, checked and swapped in. One that
    /// asks for more than it was installed with is asked about first.
    func checkForUpdates() {
        let key = "extensions.checked"
        let last = Store.settings.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        Store.settings.set(Date(), forKey: key)
        // One from another Mac that waits to be allowed more is updated
        // once it is turned on and allowed. Every sign-in's, once: they
        // run one folder.
        for item in Extensions.everyInstalled() where item.fromStore && item.wants == nil {
            Task { await update(item) }
        }
    }

    /// Chromium's copy is ahead: Chrome's own updater installed a newer
    /// version from the store. This copy takes it now, by the same check and
    /// question as the daily one, so both engines run one version.
    func followChromium(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }), item.fromStore, item.wants == nil else { return }
        Task { await update(item) }
    }

    /// Its folder updated, by this sign-in or another: taken up again at
    /// the version there, with what that version was allowed.
    fileprivate func updated(_ id: String, version: String, grants: [String]) async {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].version = version
        installed[index].permissions = grants
        save()
        if installed[index].enabled { await load(installed[index]) }
    }

    private func update(_ item: Installed) async {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: Crx.chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(item.id)&v=\(item.version)&uc"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              // The answer is the <updatecheck> element alone: status="ok"
              // with a version when there is a newer one, "noupdate" when
              // not. Read across the whole reply, the first version="" is
              // the XML declaration's "1.0", and status="ok" is on <app>
              // either way, which took every reply for an update.
              let check = xml.range(of: #"<updatecheck\b[^>]*>"#, options: .regularExpression)
                .map({ String(xml[$0]) }),
              check.contains("status=\"ok\""),
              let version = check.range(of: #"\bversion="([^"]+)""#, options: .regularExpression)
                .map({ String(check[$0].dropFirst(9).dropLast()) }),
              version != item.version
        else { return }
        do {
            let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
            let staged = Extensions.folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            // Everything it could do, sites included, against what it was
            // allowed when it was added or last asked about.
            let wants = Set(Extensions.grants(found, in: staged))
            let more = wants.subtracting(item.permissions)
            if !more.isEmpty {
                guard await ask(Question(
                    title: "\(item.name)’s update wants more",
                    detail: "Until you say yes, the version you have keeps running. Updated, it could also:",
                    lines: Extensions.describe(found, in: staged, only: more),
                    icon: ExtensionIconShape.rounded(found.icon(for: CGSize(width: 64, height: 64))),
                    yes: "Update", no: "Not Now", place: .plain
                )) else {
                    try? FileManager.default.removeItem(at: staged)
                    return
                }
            }
            for other in Extensions.all { other.unload(item.id) }
            ExtensionShims.clearMenus(item.id)
            let target = Extensions.folder(for: item.id)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staged, to: target)
            let grants = Extensions.grants(found, in: target)
            for other in Extensions.all where other.installed.contains(where: { $0.id == item.id }) {
                await other.updated(item.id, version: found.version ?? version, grants: grants)
            }
            Extensions.updatedUnread(item.id, version: found.version ?? version, grants: grants)
        } catch {
            NSLog("Extensions: update of %@ failed: %@", item.id, error.localizedDescription)
        }
    }

    /// The copy an extension's popup page is loaded from, beside it.
    ///
    /// WebKit takes any page at the path of an extension's popup for its own
    /// popup, and a popup that isn't in WebKit's own view (yab's is its
    /// own, see ExtensionPopup) is sent no events: no storage.onChanged, no
    /// tabs.onUpdated. Bitwarden's popup never heard that its server had
    /// changed to a self-hosted one, and signed in to bitwarden.com, where
    /// that account doesn't exist. Its "pop out" tab had the same trouble.
    /// So the page is loaded from a copy under another name, in the same
    /// folder: the same file, the same files around it, and none of WebKit's
    /// rules for popups. Anything else is loaded as it is.
    static let popupCopy = ".yab-popup"

    static func unpopped(_ url: URL) -> URL {
        guard url.scheme == scheme, let id = url.host, let context = all.lazy.compactMap({ $0.contexts[id] }).first,
              !url.lastPathComponent.contains(popupCopy)
        else { return url }
        // WebKit is told of a stand-in for the popup (ExtensionShims.mendPopup):
        // the page at its own address is an ordinary page, no copy needed.
        let manifest = context.webExtension.manifest
        if let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any],
           (action["default_popup"] as? String)?.contains(ExtensionShims.actionStandIn) == true {
            return url
        }
        let dynamic = all.flatMap { Array(($0.popupPaths[id] ?? [:]).values) }
        let named = [popupURL(for: context)] + dynamic.map { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL }
        guard named.contains(where: { $0?.path == url.path }) else { return url }
        // Only a regular file inside the extension's own folder.
        let folder = Extensions.folder(for: id).standardizedFileURL
        let original = folder.appendingPathComponent(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard original.path.hasPrefix(folder.path + "/"),
              (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: original)
        else { return url }
        let ext = original.pathExtension
        let name = original.deletingPathExtension().lastPathComponent + popupCopy + (ext.isEmpty ? "" : "." + ext)
        let copy = original.deletingLastPathComponent().appendingPathComponent(name)
        if (try? Data(contentsOf: copy)) != data {
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return url }
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.path = (url.path as NSString).deletingLastPathComponent.appending("/" + name).replacingOccurrences(of: "//", with: "/")
        return parts.url ?? url
    }

    /// The address an extension's page was asked for, for a page loaded
    /// from yab's popup copy of it: what Chrome would say it is, and what an
    /// extension looks for it by (Bitwarden's tabs.query for its pop-outs).
    static func popped(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard url.scheme == scheme, let range = name.range(of: popupCopy),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let original = name.replacingCharacters(in: range, with: "")
        parts.path = (url.path as NSString).deletingLastPathComponent.appending("/" + original).replacingOccurrences(of: "//", with: "/")
        return parts.url ?? url
    }

    /// The page the manifest names for the button, when WebKit hasn't said.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let path = action?["default_popup"] as? String, !path.isEmpty else { return nil }
        // Relative to the extension, and keeping a query it may carry; the
        // page itself, not the stand-in WebKit is told of (ExtensionShims.mendPopup).
        return URL(string: ExtensionShims.unStandIn(path), relativeTo: context.baseURL)?.absoluteURL
    }

    // MARK: - asking

    /// What an extension was allowed, as it is written down and compared on
    /// every update and reload: WebKit's permissions, the sites it reaches,
    /// and the APIs yab answers for it (history, bookmarks…). One that adds
    /// any of them is asked about again. What yab itself added is left out.
    static func grants(_ found: WKWebExtension, in folder: URL) -> [String] {
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".yab-added")))) as? [String] ?? [])
        let declared = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? []
        let ours = Set(yabAnswered.map(\.0))
        var out = Set(found.requestedPermissions.map(\.rawValue).filter { !added.contains($0) })
        out.formUnion(found.allRequestedMatchPatterns.map { "site:" + $0.string })
        out.formUnion(declared.filter { ours.contains($0) && !added.contains($0) }.map { "yab:" + $0 })
        return out.sorted()
    }

    /// Chrome's own APIs, which yab answers itself, and what each lets an
    /// extension do.
    static let yabAnswered: [(String, String)] = [
        ("clipboardRead", "Read your clipboard"),
        ("userScripts", "Run scripts you give it on sites"), ("history", "Read and edit your history"),
        ("bookmarks", "Read and edit your bookmarks"), ("downloads", "Start and manage downloads"),
        ("privacy", "Change Yab's privacy settings"), ("browsingData", "Delete your browsing data"),
        ("management", "See which other extensions you have"), ("notifications", "Show notifications"),
        ("sessions", "See your recently closed tabs"), ("topSites", "See the sites you visit most"),
        ("readingList", "Read and edit your reading list"), ("pageCapture", "Save whole pages as files"),
        ("proxy", "Send your traffic through its proxy"), ("geolocation", "See where you are"),
    ]

    /// Those Chrome gives without a word, having nothing to warn of: asked
    /// for alone, no card; with others, no line of their own.
    static let quiet: Set<String> = [
        "tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search", "system.cpu", "system.memory",
        "system.display", "favicon", "clipboardWrite", "alarms", "contextMenus", "menus", "storage", "unlimitedStorage",
        "scripting", "activeTab",
    ]

    /// Sites, in a line: every site, or the first few hosts.
    static func said<S: Sequence>(sites patterns: S) -> String? where S.Element == WKWebExtension.MatchPattern {
        let patterns = Array(patterns)
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) { return "Read and change every site you visit" }
        let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        return "Read and change pages on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) other sites" : "")
    }

    /// What one permissions.request asks for, a line each, in the words of
    /// the sheet it was added with: the sites first, the quiet ones left out.
    static func wants(sites: [WKWebExtension.MatchPattern], permissions: [String]) -> [String] {
        let words = Dictionary(webKitWords + yabAnswered, uniquingKeysWith: { a, _ in a })
        let named = permissions.filter { !quiet.contains($0) }.map { words[$0] ?? "Use its “\($0)” permission" }
        return (said(sites: sites).map { [$0] } ?? []) + named
    }

    /// What an extension wants, in words.
    /// `only`: the grants (as `grants` writes them) to say, for an update or
    /// a reload that asks for more: what it adds, not all it had.
    static func describe(_ found: WKWebExtension, in folder: URL, only: Set<String>? = nil) -> [String] {
        var out: [String] = []
        // Leaving out what yab itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".yab-added")))) as? [String] ?? [])
        var declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        var patterns = found.allRequestedMatchPatterns
        var permissions = Set(found.requestedPermissions.map(\.rawValue))
        if let only {
            patterns = patterns.filter { only.contains("site:" + $0.string) }
            permissions = permissions.filter { only.contains($0) }
            declared = declared.filter { only.contains("yab:" + $0) }
        }
        if let sites = said(sites: patterns) { out.append(sites) }
        for (name, sentence) in webKitWords where permissions.contains(name) && !added.contains(name) {
            out.append(sentence)
        }
        // Chrome's own, which yab answers itself.
        for (name, sentence) in Extensions.yabAnswered where declared.contains(name) { out.append(sentence) }
        return out
    }


    /// The permissions worth a line, WebKit's, in the order they are said.
    private static let webKitWords: [(String, String)] = [
        ("tabs", "See which tabs you have open, and where"),
        ("cookies", "Read and set cookies"),
        ("webNavigation", "Follow where you browse"),
        ("webRequest", "Watch what pages load"),
        ("declarativeNetRequest", "Block or rewrite what pages load"),
        ("clipboardWrite", "Put things on your clipboard"),
        ("nativeMessaging", "Talk to other apps on your Mac"),
        ("scripting", "Run its own code on pages"),
    ]

    // MARK: - what it may ask for later

    /// One thing a manifest lists as optional: a permission, by its name, or
    /// sites, by their pattern. Given at install only if ticked then, which
    /// none is to begin with: least privilege, as in Chrome.
    struct Extra: Hashable {
        let key: String
        let words: String
        let site: Bool
    }

    /// The optional permissions WebKit or yab itself can give, in the
    /// manifest's order, then the optional sites. One neither knows is left
    /// out: there would be nothing to give.
    static func extras(of found: WKWebExtension) -> [Extra] {
        let webKit = Set(found.optionalPermissions.map(\.rawValue))
        let said = Dictionary(webKitWords + yabAnswered, uniquingKeysWith: { a, _ in a })
        let listed = (found.manifest["optional_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        // One it asks for from the start as well is no choice either, as
        // with sites: unticked, it would be denied what it needs.
        var seen = Set(found.requestedPermissions.map(\.rawValue))
            .union((found.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        var out: [Extra] = []
        for name in listed + webKit.sorted() where !seen.contains(name) && (webKit.contains(name) || yabAnswered.contains { $0.0 == name }) {
            seen.insert(name)
            out.append(Extra(key: name, words: said[name] ?? "Use its “\(name)” permission", site: false))
        }
        // A site it names already, as one it may ask for later, is no choice.
        let named = found.allRequestedMatchPatterns
        for pattern in found.optionalPermissionMatchPatterns.sorted(by: { $0.string < $1.string })
            where !seen.contains(pattern.string) && !named.contains(where: { $0.matches(pattern) }) {
            seen.insert(pattern.string)
            let every = pattern.matchesAllHosts || pattern.matchesAllURLs
            let host = pattern.host.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 } ?? pattern.string
            out.append(Extra(key: pattern.string, words: every ? "Read and change every site you visit" : "Read and change pages on \(host)", site: true))
        }
        return out
    }

    /// What was chosen for its extras, by key: true given, false kept from
    /// it. One not in here is asked about when the extension asks for it.
    static func choices(_ id: String) -> [String: Bool] {
        Store.settings.dictionary(forKey: "extensions.optional.\(id)") as? [String: Bool] ?? [:]
    }

    static func setChoices(_ choices: [String: Bool], for id: String) {
        if choices.isEmpty { Store.settings.removeObject(forKey: "extensions.optional.\(id)") }
        else { Store.settings.set(choices, forKey: "extensions.optional.\(id)") }
        listsChanged.send()
    }

    /// Adds to what was chosen. Chrome's own permissions, which WebKit
    /// knows nothing of, are given where the shim looks for them.
    static func choose(_ picks: [String: Bool], for id: String) {
        setChoices(choices(id).merging(picks) { _, new in new }, for: id)
        let ours = Set(yabAnswered.map(\.0))
        let given = picks.filter { $0.value && ours.contains($0.key) }.map(\.key)
        guard !given.isEmpty else { return }
        let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
        Store.settings.set(Array(Set(had + given)).sorted(), forKey: "extensions.granted.\(id)")
    }

    /// Put back each time it loads: WebKit keeps no permission from one
    /// launch to the next.
    private func applyChoices(_ context: WKWebExtensionContext) {
        let choices = Extensions.choices(context.uniqueIdentifier)
        guard !choices.isEmpty else { return }
        // One it asks for from the start as well is not a choice: given
        // with the rest, whatever was kept from before extras() knew that.
        let required = context.webExtension.requestedPermissions
        var taken: [String] = []
        for permission in context.webExtension.optionalPermissions where !required.contains(permission) {
            guard let on = choices[permission.rawValue] else { continue }
            context.setPermissionStatus(on ? .grantedExplicitly : .deniedExplicitly, for: permission)
            if !on { taken.append(permission.rawValue) }
        }
        take(taken, from: context.uniqueIdentifier)
    }

    /// Adding one: the one thing that matters most in a sentence, the rest
    /// folded under "N more", with what it may ask for later. Nothing of
    /// that is given now: it is asked about when it asks, as in Chrome.
    private func ask(install name: String, wants: [String], extras: [Extra] = [], icon: NSImage?) async -> (yes: Bool, given: Set<String>) {
        let yes = await ask(Question(
            title: "Add “\(name)”?",
            detail: wants.first.map { "It will \(Self.lowered($0))." } ?? "It asks for no special access.",
            folded: Array(wants.dropFirst()),
            foldedNote: extras.isEmpty ? "" : "It may ask later to \(Self.listed(extras.map { Self.lowered($0.words) })).",
            icon: icon, yes: "Add"
        ))
        return (yes, [])
    }

    /// A line as it reads inside a sentence: "Read and set cookies", "read
    /// and set cookies".
    static func lowered(_ line: String) -> String {
        line.prefix(1).lowercased() + line.dropFirst()
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// A running extension asking for more, sites and permissions in one
    /// card, a line each (wants(sites:permissions:)): over the page but not
    /// dimming it, since nobody on the page asked it anything.
    func ask(wants lines: [String], context: WKWebExtensionContext) async -> Bool {
        await ask(Question(
            title: "\(context.webExtension.displayName ?? "An extension") wants more access",
            lines: lines, icon: ExtensionIconShape.rounded(context.webExtension.icon(for: CGSize(width: 64, height: 64))),
            yes: "Allow", no: "Don’t Allow", place: .plain
        ))
    }

    /// Sites it was given after asking: kept, so it still has them after a
    /// relaunch, as in Chrome, and given now if it reaches sites at all.
    @discardableResult
    func give(sites patterns: [WKWebExtension.MatchPattern], to context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        let picks = Dictionary(patterns.map { ($0.string, true) }, uniquingKeysWith: { a, _ in a })
        guard admits(choices: picks, for: id) else { return false }
        Extensions.choose(picks, for: id)
        guard access(id) == .asked else { return true }
        applyAccess(context)
        return true
    }

    /// For the bench, in a test run only: answer every question this way
    /// instead of asking. Nil asks.
    var answerForTests: Bool?
    /// What was asked, for the bench.
    private(set) var asked: [String] = []

    /// Asked in yab's own card (Question.swift), one at a time, never the
    /// system's alert: one run modally would stop the whole browser, pages,
    /// downloads, every other extension, for as long as it waits, and an
    /// extension can ask when nobody is looking.
    func ask(_ question: Question) async -> Bool {
        asked.append(question.title)
        if Store.testing, let answer = answerForTests { return answer }
        return await Questions.shared.ask(question)
    }

    // MARK: - the buttons

    struct Button: Identifiable {
        let id: String
        let name: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
        /// The key given its button, "⇧⌘N", for its tip; nil for none.
        var keys: String? = nil
    }

    /// The list behind the puzzle button.
    @Published var menuOpen = false {
        // Opened, the dot has done its job; closed, what was new has been seen.
        didSet {
            guard menuOpen != oldValue else { return }
            if menuOpen { dotted = false } else { unseen = [] }
            keepUnseen()
        }
    }
    /// Counts the icons that have flown into the puzzle; each gives it a hop.
    @Published var arrivals = 0

    /// A hop, in turn with the downloads button's.
    func hop() {
        Hop.take { [weak self] in self?.arrivals += 1 }
    }

    /// Added since the list was last opened: first among its rows until it
    /// has been seen there.
    @Published private(set) var unseen: Set<String> = []
    /// Some came in with nothing flying to say so, from Settings, or a
    /// batch from another browser: a dot on the puzzle until the list opens.
    @Published private(set) var dotted = false

    /// In from somewhere the puzzle can't be flown to: one hop however many
    /// there are, and the dot.
    func arrivedQuietly(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        unseen.formUnion(ids)
        dotted = true
        keepUnseen()
        hop()
    }

    /// Something waits in Site Controls with nothing new among the
    /// extensions (a userscript's update that asks for more): the dot
    /// alone, until the panel opens.
    func dotQuietly() {
        dotted = true
        keepUnseen()
    }

    private func keepUnseen() {
        Store.settings.set(unseen.sorted(), forKey: kept("extensions.unseen"))
        Store.settings.set(dotted, forKey: kept("extensions.dotted"))
    }
    /// Where a popup hangs: the puzzle button.
    static let menuAnchor = "__menu"
    /// Which side of the puzzle button the list opens toward: below it in
    /// the top row, out to the right of it in the sidebar.
    var menuEdge: NSRectEdge {
        get { Extensions.menuSide }
        set { Extensions.menuSide = newValue }
    }
    private static var menuSide: NSRectEdge = .maxY

    /// One per loaded extension that has something to press, in install order.
    var buttons: [Button] {
        _ = actionsChanged
        let tab = activeAdapter
        return installed.compactMap { item in
            if ApplePasswordExtensionRoute.offersButton(item.id) {
                return Button(id: item.id, name: item.name, label: item.name,
                              icon: icon(for: item.id, side: 16), badge: "", enabled: true,
                              pinned: item.pinned ?? false, keys: nil)
            }
            // Still waiting its turn at launch: its button is there already,
            // with the icon it ships, as Chrome shows every button at once.
            // Yab loads them one after another, a moment apart, and the
            // buttons came in one by one over seconds, as if each extension
            // were being installed again (a tester, Oct 10: "on each launch
            // all the chrome extensions load up").
            // So is one asleep until it is used, and both wear the badge and
            // label they last had.
            if contexts[item.id] == nil, starting.contains(item.id) || asleep.contains(item.id) {
                // Its tip as when loaded: the short name and its key, from
                // the manifest, not the store name its action kept.
                let face = lastFaces[item.id] ?? [:]
                let facts = tipFacts[item.id] ?? .init()
                let kept = face["label"] ?? ""
                return Button(id: item.id, name: item.name,
                              label: ExtensionTip.label(action: kept.isEmpty ? facts.title : kept, name: item.name, displayName: nil, shortName: facts.shortName),
                              icon: ExtensionIconShape.rounded(lastIcon(item.id)) ?? icon(for: item.id, side: 16), badge: face["badge"] ?? "", enabled: true, pinned: item.pinned ?? false,
                              keys: ExtensionTip.buttonKey(facts.keys.filter { !ExtensionCommands.off(item.id, $0.command) && ExtensionCommands.routes($0.hotkey) })?.hotkey.text)
            }
            guard let context = contexts[item.id], let action = context.action(for: tab) else { return nil }
            // Its store name is a sentence, "NordPass® Password Manager &
            // Digital Vault": a short name says it (ExtensionTip.label).
            let press = context.commands.first {
                ExtensionTip.pressCommands.contains($0.id) && routedKey($0) != nil
            }
            return Button(
                id: item.id,
                name: item.name,
                label: ExtensionTip.label(action: action.label, name: item.name, displayName: context.webExtension.displayName,
                                          shortName: context.webExtension.displayShortName ?? ""),
                icon: ExtensionIconShape.rounded(action.icon(for: CGSize(width: 32, height: 32))),
                badge: action.badgeText,
                enabled: action.isEnabled,
                pinned: item.pinned ?? false,
                keys: press.flatMap { routedKey($0)?.text }
            )
        }
    }

    /// `panel`: the extensions list's popover, when it was pressed from
    /// there, a popup takes it over; anything else closes it.
    func press(_ id: String, from panel: NSPopover? = nil) {
        if ApplePasswordExtensionRoute.matches(id) {
            panel?.performClose(nil)
            ApplePasswordExtensionRoute.intercept(id, browser: browser)
            return
        }
        guard let context = contexts[id] else {
            panel?.performClose(nil)
            // Pressed while it waits its turn at launch, or asleep until
            // used: pressed again as soon as it is loaded.
            if starting.contains(id) { pressWhenLoaded = id }
            if asleep.contains(id) {
                pressWhenLoaded = id
                wake(id)
            }
            return
        }
        // Its own button again, with its popup up: closed, as in Chrome.
        if panel == nil, ExtensionPopup.shared.closes(id) { return }
        if let tab = activeAdapter { context.userGesturePerformed(in: tab) }
        // The shim records the extension's current setPopup path for this
        // tab. WebKit's presentsPopup can still describe the manifest's
        // default, so it must not gate that authoritative dynamic choice.
        let currentPopup = popupURL(for: context)
        // An extension that asked for its button to open its side panel.
        if ExtensionShims.panelOnClick.contains(id), currentPopup == nil {
            panel?.performClose(nil)
            if let browser = BrowserWindows.shared.activeBrowser ?? self.browser,
               browser.panelExtension == id, browser.chatOpen {
                browser.moveChat(open: false)
            } else {
                ExtensionShims.openPanel(context, owner: self)
            }
            return
        }
        // A popup is opened here, straight away. Left to WebKit, it builds
        // a popup of its own first, and closing that one in favour of
        // yab's lost the new popup's first messages to its worker.
        if let url = currentPopup {
            // Its worker started as the popup opens, as Chrome starts it for
            // the popup's first message. WebKit left an unloaded worker
            // asleep through the messages of Rabby's popup, which gave up
            // after ten seconds ("Rabby failed to start").
            if context.webExtension.hasBackgroundContent, !Extensions.workerAwake(context) {
                trace(id, "its button woke the worker")
                context.loadBackgroundContent { _ in }
            }
            let own = anchors[id]?.view
            ExtensionPopup.shared.show(url, for: context, from: own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view, reusing: panel)
            return
        }
        panel?.performClose(nil)
        context.performAction(for: activeAdapter)
    }

    /// The popup kept back (ExtensionDetail.iCloudWaiting): Yab's own
    /// popover where the popup would hang, from the button, or from the
    /// puzzle with the button unpinned, or over the list it was pressed in.
    private func withheld(_ id: String, reusing panel: NSPopover? = nil) {
        let own = anchors[id]?.view
        ExtensionWithheld.shared.show(id, from: own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view, reusing: panel)
    }

    /// A press the worker held while it started, given back because the
    /// extension chose a popup instead of a listener (NordPass, signed in,
    /// after a relaunch): its popup opens, as the press would have opened
    /// it had the popup been set already. Nothing else is pressed again.
    func pressHeld(_ id: String) {
        guard let context = contexts[id], popupURL(for: context) != nil,
              ExtensionPopup.shared.extensionID != id else { return }
        press(id)
    }

    /// The page the button's popup is now: one the extension set for this
    /// tab or for all of them, else its manifest's.
    private func popupURL(for context: WKWebExtensionContext) -> URL? {
        let set = popupPaths[context.uniqueIdentifier] ?? [:]
        let path = (window?.link?.tab ?? browser?.active).flatMap { set[$0.id.uuidString] } ?? set["*"]
        guard let path else { return Extensions.popupURL(for: context) }
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// A keystroke an extension registered for.
    /// The extension and command the last key heard ran, for the bench.
    static var lastTaken = ""

    func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let pressed = Hotkey.readings(event)
        guard pressed.contains(where: \.commands), Keymap.shared.action(for: event) == nil,
              !pressed.contains(where: { Shortcut.kept($0, from: nil) }) else { return false }
        for item in installed where item.enabled {
            let id = item.id
            guard let context = contexts[id] else { continue }
            // One turned off in Settings › Shortcuts isn't heard.
            guard let command = context.commands.first(where: { command in
                (command.activationKey.map { pressed.contains(Hotkey($0, command.modifierFlags)) } ?? false)
                    && !ExtensionCommands.off(id, command.id)
            }) else { continue }
            // Its button's key: pressed as the button is, so the popup
            // hangs from its own button, pinned beside the address, and
            // the key again closes it, rather than WebKit's popup from the
            // puzzle.
            Self.lastTaken = id + "/" + command.id
            run(id, command: command.id)
            return true
        }
        // One asleep until used answers its keys too, the ones its
        // manifest suggests or someone set: woken, as a press of its
        // button wakes it, and the command run once it is up.
        for id in asleep.sorted() {
            guard installed.contains(where: { $0.id == id && $0.enabled }) else { continue }
            guard let key = tipFacts[id]?.keys.first(where: { pressed.contains($0.hotkey) && !ExtensionCommands.off(id, $0.command) }) else { continue }
            Self.lastTaken = id + "/" + key.command
            run(id, command: key.command)
            return true
        }
        return false
    }

    /// Right-click items an extension added, for the page's menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard seen(tab) else { return [] }
        let adapter = adapter(for: tab)
        return Self.orderedMenuItems(installed: installed, contexts: contexts) { $0.menuItems(for: adapter) }
    }

    /// The saved list keeps pin moves and install order, unlike the loaded
    /// contexts' dictionary. Each extension keeps its own items' order.
    static func orderedMenuItems<Context>(installed: [Installed], contexts: [String: Context],
                                           items: (Context) -> [NSMenuItem]) -> [NSMenuItem] {
        let enabled = installed.filter(\.enabled)
        let ordered = enabled.filter { $0.pinned == true } + enabled.filter { $0.pinned != true }
        return ordered.flatMap { item in
            contexts[item.id].map(items) ?? []
        }
    }
}

// MARK: - the row's news, gathered

/// What happened to the row since WebKit was last told, gathered so it is
/// told once: whether the row changed (it is read whole when told), the
/// switch from the tab first in front to the one in front now, and every
/// property changed in each tab.
@available(macOS 15.4, *)
struct TabNews<ID: Hashable> {
    /// Long enough for the frame a new tab is drawn in to go out first,
    /// and for a page starting to load to change its address, title and
    /// loading together.
    static var delay: DispatchTimeInterval { .milliseconds(60) }

    private(set) var row = false
    private(set) var switched: (from: ID?, to: ID?)?
    private(set) var changes: [ID: WKWebExtension.TabChangedProperties] = [:]

    mutating func rowChanged() { row = true }

    /// A → B then B → C is A → C; A → B then B → A is no switch at all.
    mutating func activated(from old: ID?, to new: ID?) {
        let from = switched.map(\.from) ?? old
        switched = from == new ? nil : (from, new)
    }

    mutating func changed(_ id: ID, _ properties: WKWebExtension.TabChangedProperties) {
        changes[id, default: []].formUnion(properties)
    }
}

// MARK: - WebKit asks, the browser answers

@available(macOS 15.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    /// Every browser window, the one in front first, and every extension's
    /// popout (ExtensionPopout), first when it is the one in front.
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let first = window
        let mine = ExtensionPopout.open.filter { $0.controller === self.controller }
        let key = ExtensionPopout.owning(NSApp.keyWindow).flatMap { popout in mine.contains { $0 === popout } ? popout : nil }
        var all: [any WKWebExtensionWindow] = key.map { [$0.frame as any WKWebExtensionWindow] } ?? []
        all += ((first.map { [$0] } ?? []) + windowOrder.compactMap { windows[$0] }.filter { $0 !== first }).map { $0 as any WKWebExtensionWindow }
        all += mine.filter { $0 !== key }.map { $0.frame as any WKWebExtensionWindow }
        return all
    }

    /// The last focused, as Chrome's: a popout while it is the key window.
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        if let popout = ExtensionPopout.owning(NSApp.keyWindow), popout.controller === controller { return popout.frame }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser = opening((configuration.window as? ExtensionWindow)?.browser) else { return nil }
        var url = configuration.url ?? URL(string: "about:blank")!
        // chrome://extensions/shortcuts and Chrome's other pages Yab has a
        // place for: that place, and no tab (ChromePages).
        if let place = ChromePages.place(of: url, opener: extensionContext.uniqueIdentifier) {
            guard place == .newTab else {
                ChromePages.open(place, in: browser, from: url)
                return nil
            }
            url = ChromePages.blank
        }
        // Opened for an agent: the agent's own tab, behind yours, and put
        // away with its others (AgentTabCleanup). A manager's vault after
        // its unlock and the logins its start page opens stayed in your
        // tabs for good.
        if let owner = Self.agentOpening(from: (configuration.parentTab as? ExtensionTab)?.tab) {
            guard browser.windowPurpose == .normal else { return nil }
            let tab = browser.benchOpen(url)
            tab.agent = owner
            Bench.shared.house(tab)
            Agents.shared.recall()
            return adapter(for: tab)
        }
        // In the row at once: OneTab restoring A, B and C opened A in front,
        // and A, added after its page drew, landed after B and C.
        let tab = browser.open(url, foreground: configuration.shouldBeActive, atEnd: true, rowNow: true)
        if configuration.shouldBePinned { browser.pin(tab) }
        if configuration.index != NSNotFound, !browser.tabs.isEmpty {
            browser.move(tab, to: min(configuration.index, browser.tabs.count - 1))
        }
        return adapter(for: tab)
    }

    /// The agent a tab an extension opens is for: the agent's tab it came
    /// from, or the agent that called last, in its tab or none, with nobody
    /// at the keys since. Nil when it is yours.
    static func agentOpening(from parent: Tab?) -> String? {
        if let parent, parent.bench { return parent.agent }
        let agents = Agents.shared
        let recent = parent?.guest.flatMap(agents.session)
            ?? agents.sessions.filter(\.state.live).max(by: { $0.touched < $1.touched })
        // Work out of sight acts only in its own tabs (caught above): a
        // tab from one of yours is never its, or your manager's page would
        // vanish into its shut folder.
        guard let session = recent, session.state.live, !session.script, !agents.sealed(session.id) else { return nil }
        let since = Date().timeIntervalSince(session.touched)
        guard since < 10 else { return nil }
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return quiet > since ? session.id : nil
    }

    /// No new window, on purpose: its pages become tabs in the one in front.
    /// But a popup of the extension's own page is a window of its own, as in
    /// Chrome (ExtensionPopout says why).
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        if let url = ExtensionPopout.wanted(configuration, for: extensionContext) {
            let parent = front.flatMap { BrowserWindows.shared.window(for: $0) } ?? NSApp.mainWindow
            return ExtensionPopout.present(url, for: extensionContext, configuration: configuration, over: parent)?.frame
        }
        guard let browser = opening() else { return nil }
        for (index, url) in configuration.tabURLs.enumerated() {
            browser.open(url, foreground: index == 0 && configuration.shouldBeFocused, atEnd: true, rowNow: true)
        }
        return windows[Self.key(of: browser)]
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL, let browser = opening() else { return }
        // Chrome keeps one tab of an options page (a singleton tab): asked
        // again, it brings that one forward. Bypass Paywalls Clean asks at
        // every start of its worker until it has kept its sites, and each
        // new tab woke the worker: a new options tab for every one (#322).
        let same = { (tab: Tab) in (tab.address ?? tab.pending).map { Extensions.samePage($0, url) } ?? false }
        if let tab = browser.tabs.first(where: same) ?? browser.parked.values.lazy.flatMap(\.tabs).first(where: same) {
            if !browser.tabs.contains(where: { $0 === tab }), let space = browser.spaceHolding(tab.id) { browser.switchSpace(to: space) }
            browser.select(tab)
            return
        }
        browser.open(url, foreground: true)
    }

    /// One page, whatever its fragment: what Chrome's singleton tab matches.
    nonisolated static func samePage(_ a: URL, _ b: URL) -> Bool {
        var a = URLComponents(url: a, resolvingAgainstBaseURL: false), b = URLComponents(url: b, resolvingAgainstBaseURL: false)
        a?.fragment = nil
        b?.fragment = nil
        return a != nil && a?.url == b?.url
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        // Unticked when it was added, back when a box left unticked kept it
        // from the extension: kept from it without asking again.
        let choices = Extensions.choices(extensionContext.uniqueIdentifier)
        guard !permissions.contains(where: { choices[$0.rawValue] == false }) else { return ([], nil) }
        let names = permissions.map(\.rawValue).sorted()
        if !names.allSatisfy(Extensions.quiet.contains) {
            guard await ask(wants: Extensions.wants(sites: [], permissions: names), context: extensionContext) else { return ([], nil) }
        }
        // Kept, so it still has them after a relaunch, as in Chrome. A no
        // isn't: the extension may ask again another time.
        Extensions.choose(Dictionary(permissions.map { ($0.rawValue, true) }, uniquingKeysWith: { a, _ in a }), for: extensionContext.uniqueIdentifier)
        return (permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        // WebKit asks this whenever an extension reaches
        // for a page it has no host permission for, listing tabs, running a
        // script in one, often with nobody having touched anything. Chrome
        // never asks there: the extension has the sites its manifest named,
        // the page it was clicked on (activeTab), and the ones it asked for
        // through permissions.request. So neither does yab.
        asked.append("(refused) \(extensionContext.webExtension.displayName ?? "?") → \(Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", "))")
        return ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let choices = Extensions.choices(extensionContext.uniqueIdentifier)
        guard !matchPatterns.contains(where: { choices[$0.string] == false }) else { return ([], nil) }
        // What this returns WebKit grants itself, whatever the site access.
        let fits = { self.admits(extensionContext.uniqueIdentifier) { trial in
            for pattern in matchPatterns { trial.setPermissionStatus(.grantedExplicitly, for: pattern) }
        } }
        guard fits() else { return ([], nil) }
        let sites = matchPatterns.sorted { $0.string < $1.string }
        guard await ask(wants: Extensions.wants(sites: sites, permissions: []), context: extensionContext) else { return ([], nil) }
        // Again: another grant may have taken the room while the card waited.
        guard fits() else { return ([], nil) }
        Extensions.choose(Dictionary(matchPatterns.map { ($0.string, true) }, uniquingKeysWith: { a, _ in a }), for: extensionContext.uniqueIdentifier)
        return (matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsChanged += 1
        keepFace(of: context)
    }

    /// The popup page, in a popover of the browser's own (ExtensionPopup
    /// says why): WebKit's view is only asked which page it would show.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let url = action.popupWebView?.url ?? Extensions.popupURL(for: context)
        action.closePopup()
        // Its own action.openPopup(): the same answer as its button's.
        if ExtensionDetail.iCloudWaiting(context.uniqueIdentifier) { return withheld(context.uniqueIdentifier) }
        guard let url else { return }
        let own = anchors[context.uniqueIdentifier]?.view
        let anchor = own?.window != nil ? own : anchors[Extensions.menuAnchor]?.view
        ExtensionPopup.shared.show(url, for: context, from: anchor)
    }

    /// `runtime.sendNativeMessage`. To "yab", the APIs WebKit doesn't
    /// have, answered by this app. To anything else, a Chrome native
    /// messaging host installed on this Mac, spoken to the way Chrome would.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        if applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application {
            let reply = try await ExtensionShims.answer(message, from: extensionContext, owner: self)
            guard WebKitIPCBoundary.allow([reply ?? NSNull()], "extension shim reply") else { throw WebKitIPCBoundary.error }
            return reply
        }
        let id = extensionContext.uniqueIdentifier, host = applicationIdentifier!
        do {
            let reply = try await ExtensionNative.send(message, to: host, from: Extensions.chromeID(id), owner: extensionContext) { [weak self] in
                Task { @MainActor in self?.macOSStopped(id) }
            }
            guard WebKitIPCBoundary.allow([reply ?? NSNull()], "native application reply") else { throw WebKitIPCBoundary.error }
            if Extensions.onePasswordCalling(id, host) {
                if Extensions.refusal(reply) { appUnreached(id, host: host) } else { appReached(id, host: host) }
            }
            return reply
        } catch {
            // Another extension of the same app, after macOS killed it once.
            if ExtensionNative.stoppedByMacOS(host) { macOSStopped(id) }
            // An extension asking an app that isn't there, over and over,
            // a retry loop, is answered slowly once it has asked a dozen
            // times in a second, so it can't swamp the browser.
            let key = id + "→" + host, now = Date()
            failures[key] = (failures[key] ?? []).filter { now.timeIntervalSince($0) < 1 } + [now]
            if (failures[key]?.count ?? 0) > 12 { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        if port.applicationIdentifier == ExtensionGroups.portName {
            // The shared row's folders, told to the shared sign-in's alone.
            if signIn == nil { ExtensionGroups.shared.connect(port, from: extensionContext.uniqueIdentifier) }
            return
        }
        if port.applicationIdentifier == ExtensionReadingList.portName {
            // Only an extension that may read the list hears it change.
            guard ExtensionShims.allowed(extensionContext.uniqueIdentifier, context: extensionContext).contains("readingList") else {
                port.disconnect()
                return
            }
            ExtensionReadingList.connect(port, from: extensionContext.uniqueIdentifier)
            return
        }
        if port.applicationIdentifier == ExtensionOmnibox.portName {
            ExtensionOmnibox.shared.connect(port, from: ExtensionExternal.key(extensionContext.uniqueIdentifier, in: signIn))
            return
        }
        if port.applicationIdentifier == ExtensionDebugger.portName {
            ExtensionDebugger.shared.connect(port, from: ExtensionExternal.key(extensionContext.uniqueIdentifier, in: signIn))
            return
        }
        if port.applicationIdentifier == ExtensionKeep.portName {
            ExtensionKeep.hold(port, from: extensionContext.uniqueIdentifier)
            return
        }
        // The port a worker's shim opens only to find what ports share; it
        // lets go at once.
        if port.applicationIdentifier == ExtensionShims.application { return }
        // What web pages send it (externally_connectable).
        if port.applicationIdentifier == ExtensionExternal.portName {
            ExtensionExternal.shared.attach(port, extension: extensionContext.uniqueIdentifier, signIn: signIn)
            return
        }
        let id = extensionContext.uniqueIdentifier, host = port.applicationIdentifier ?? ""
        // 1Password's app says first thing whether it lets Yab in: that
        // word only is read, not the rest of what goes over the port.
        var first = true
        let heard: ((Any) -> Void)? = Extensions.onePasswordCalling(id, host) ? { [weak self] message in
            guard first else { return }
            first = false
            if Extensions.refusal(message) { self?.appUnreached(id, host: host) } else { self?.appReached(id, host: host) }
        } : nil
        do {
            try ExtensionNative.connect(port, from: Extensions.chromeID(id), owner: extensionContext, heard: heard, killed: { [weak self] in
                Task { @MainActor in self?.macOSStopped(id) }
            }) { [weak self] ending in
                guard let self, Extensions.refused(ending) else { return }
                // 1Password's is said in words on its row in Settings.
                if self.appUnreached(id, host: host) { return }
                let said = ending.last.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                    .map { String(decoding: $0.prefix(240), as: UTF8.self) } ?? "nothing"
                self.noteError("\(host) wouldn't talk to Yab: \(said)", for: id)
            }
        } catch {
            appUnreached(id, host: host)
            if ExtensionNative.stoppedByMacOS(host) { macOSStopped(id) }
            // Chrome tells a missing app through the port's onDisconnect,
            // where the extension reads runtime.lastError. Thrown here,
            // WebKit sets lastError before anything can read it and logs it
            // as unchecked, an error on the extension's card each time
            // Bitwarden looks for its desktop app (every ten seconds). The
            // port is taken and let go of with the reason instead.
            let why = error.localizedDescription
            DispatchQueue.main.async { ExtensionNative.end(port, saying: why) }
        }
    }

    // MARK: - 1Password's app

    /// A host that wouldn't talk to this browser: 1Password's says so,
    /// BrowserVerificationFailed (UnknownBrowser for one not added in the
    /// app), and its extension lets go of it; another may just stop by
    /// itself at once.
    nonisolated static func refused(_ ending: ExtensionNative.Ending) -> Bool {
        refusal(ending.last) || ending.byItself && ending.after < 15
    }

    /// A host's word that it won't talk to this browser.
    nonisolated static func refusal(_ message: Any?) -> Bool {
        guard let message, let data = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return false }
        return String(decoding: data, as: UTF8.self).contains("\"BrowserVerificationFailed\"")
    }

    /// 1Password's extensions, and the host its app leaves for browsers.
    static let onePassword: Set<String> = ["aeblfdkhhhdcdjpifhhbdiojplfjncoa", "khgocmkkpikpnmmkgmdnfckapcdkgfaf"]
    static let onePasswordHost = "com.1password.1password"
    /// 1Password's app wherever it is, nil on a Mac without it.
    static var onePasswordApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password")
    }

    /// One of 1Password's extensions calling its app.
    static func onePasswordCalling(_ id: String, _ host: String) -> Bool {
        onePassword.contains(id) && host == onePasswordHost
    }

    /// 1Password's extension couldn't reach its app, which is on this Mac.
    /// The app leaves its host in Chrome's folder, which Yab reads, but the
    /// host talks only to browsers it knows and to one added in the app by
    /// hand (Settings › Browser › Add Browser, open once signed in). Its row
    /// in Settings says so until the app answers; the card asks once and,
    /// whichever the answer, never again
    /// (docs/evidence/launch-repro-2026-10-03/extensions-followup.md).
    /// True when it was 1Password's, now said on its row.
    @discardableResult
    func appUnreached(_ id: String, host: String) -> Bool {
        let here = Extensions.onePasswordApp != nil
        let next = Extensions.nextUnconnected(unconnected, id, host: host, refused: true, appHere: here)
        if next != unconnected { unconnected = next }
        onePasswordAnswered.remove(id)
        guard Extensions.onePasswordCalling(id, host), here else { return false }
        guard !onePasswordAsking, !Store.settings.bool(forKey: "extensions.onePasswordHinted") else { return true }
        onePasswordAsking = true
        Task {
            let open = await ask(Question(
                title: "Connect 1Password to Yab",
                detail: "In the 1Password app: Settings › Browser › Add Browser, then choose Yab.",
                icon: ExtensionIconShape.rounded(contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64))),
                yes: "Open 1Password", no: "Not Now", place: .plain
            ))
            Store.settings.set(true, forKey: "extensions.onePasswordHinted")
            onePasswordAsking = false
            if open { Extensions.openOnePassword() }
        }
        return true
    }

    /// A password manager's extension come in and not connected: the
    /// corner card asks once whether to connect it, and Connect opens
    /// Settings › Passwords at its Unlock step. Not while the Connect sheet
    /// itself is adding it.
    func offerToConnect(_ id: String) {
        let manager = PasswordManagers.canonical(id)
        let connections = PasswordManagers.Connections.shared
        let key = "passwords.offered." + manager
        guard let provider = PasswordManagers.provider(manager), provider.id != PasswordManagers.apple,
              connections.connection(manager) == nil, !connections.connecting,
              !Store.settings.bool(forKey: key) else { return }
        Store.settings.set(true, forKey: key)
        Task {
            let yes = await ask(Question(
                title: "Connect \(provider.name)?",
                detail: "Then agents can sign in with it too. Once, after \(provider.name) comes into Yab.",
                icon: ExtensionIconShape.rounded(contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64))),
                yes: "Connect", no: "Not Now", place: .plain
            ))
            guard yes else { return }
            // Settings first: its Connect page is opened on its window.
            browser?.openSettings(.passwords)
            connections.opensOn = manager
            connections.connecting = true
        }
    }

    /// The app said something other than no: connected, and the row goes
    /// quiet.
    func appReached(_ id: String, host: String) {
        let next = Extensions.nextUnconnected(unconnected, id, host: host, refused: false, appHere: true)
        if next != unconnected { unconnected = next }
        if Extensions.onePasswordCalling(id, host) { onePasswordAnswered.insert(id) }
    }

    /// `unconnected` once `id` has heard from `host`: 1Password's app
    /// refusing Yab, while it is on this Mac, adds it, and anything else
    /// from the app takes it away. Other hosts leave it as it was.
    static func nextUnconnected(_ now: Set<String>, _ id: String, host: String, refused: Bool, appHere: Bool) -> Set<String> {
        guard onePasswordCalling(id, host) else { return now }
        if !refused { return now.subtracting([id]) }
        return appHere ? now.union([id]) : now
    }

    static func openOnePassword() {
        guard let app = onePasswordApp else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
    }
}

// MARK: - adapters

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    /// The browser of the window it is in.
    private var browser: Browser? { tab.flatMap { owner.window(of: $0)?.browser } ?? owner.browser }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { tab.flatMap(owner.window(of:)) }

    /// The small window it is the one tab of, if it is.
    private var link: LinkWindow? { tab.flatMap { owner.window(of: $0)?.link } }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        if link != nil { return 0 }
        guard let tab, let browser else { return NSNotFound }
        return owner.listing(browser).places[tab.id] ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webKitOnly("Legacy WebKit extension tab", build: false) }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.address.map(Extensions.popped) }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.loading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { link != nil || tab?.id == browser?.activeID }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pin != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.noisy ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.muted ?? false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.webKitOnly("Legacy WebKit extension tab", build: false)?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.webKitOnly("Legacy WebKit extension tab", build: false)?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let tab, let browser else { return }
        if pinned, tab.pin == nil { browser.pin(tab) }
        if !pinned, tab.pin != nil { browser.unpin(tab) }
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext) async throws {
        tab?.mute(muted)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        tab?.magnify(to: CGFloat(zoomFactor))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        // A website's tab sent to one of an extension's own pages: 1Password
        // does, once a sign-in in its tab has added the account. The page
        // can only be served to a view built from that extension's
        // configuration, so the tab is swapped for one that is.
        var url = Extensions.current(url)
        // chrome://extensions/shortcuts, the Great Suspender's "Configure
        // shortcuts": Settings opens there and the tab stays where it is
        // (ChromePages, feedback #163).
        if let place = ChromePages.place(of: url, opener: context.uniqueIdentifier) {
            guard place == .newTab else {
                if let browser { ChromePages.open(place, in: browser, from: url) }
                return
            }
            url = ChromePages.blank
        }
        let here = tab.webKitOnly("Legacy WebKit extension tab", build: false)?.url ?? tab.address
        if url.scheme == Extensions.scheme, here?.scheme != Extensions.scheme || here?.host != url.host, let browser {
            browser.replaceBlank(tab, with: url)
            return
        }
        tab.go(to: url)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { tab?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { tab?.back() }
    func goForward(for context: WKWebExtensionContext) async throws { tab?.forward() }

    func activate(for context: WKWebExtensionContext) async throws {
        if let link { return link.window.makeKeyAndOrderFront(nil) }
        guard let tab, let browser else { return }
        // A tab of a space not on screen: that space first, as a click on
        // it in the tray would (Rabby bringing its welcome tab forward).
        if !browser.tabs.contains(where: { $0.id == tab.id }), let space = browser.spaceHolding(tab.id) {
            browser.switchSpace(to: space)
        }
        browser.select(tab)
    }

    /// A tab of another space is closed there, as ⌃W closes one in the
    /// switcher, without going to it; a pin or a kept tab is put down
    /// rather than taken out of its row, as ⌘W puts it down.
    func close(for context: WKWebExtensionContext) async throws {
        if let link { return link.close() }
        guard let tab, let browser else { return }
        if browser.tabs.contains(where: { $0.id == tab.id }) { return browser.close(tab) }
        guard browser.parked.values.contains(where: { $0.tabs.contains { $0.id == tab.id } }) else { return }
        if tab.pin != nil || tab.kept {
            tab.rest()
            if tab.awayFromHome { tab.sendHome() }
            browser.writeSession(now: true)
        } else {
            browser.closeElsewhere(tab)
        }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = tab?.webKitOnly("Legacy WebKit extension tab", build: false) else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions
    weak var browser: Browser?
    /// The small window this is, rather than a browser window.
    private(set) weak var link: LinkWindow?
    /// Kept apart from `link`, which is weak: this is never taken for a browser window.
    let isLink: Bool

    init(owner: Extensions, browser: Browser, link: LinkWindow? = nil) {
        self.owner = owner
        self.browser = browser
        self.link = link
        isLink = link != nil
    }

    /// Its tab in front: a small window's page, or the row's active tab.
    var activeAdapter: ExtensionTab? {
        guard isLink else { return owner.activeAdapter(in: browser) }
        return link.flatMap { owner.toldTabs($0).first }.flatMap { owner.seen($0) ? owner.adapter(for: $0) : nil }
    }

    private var nsWindow: NSWindow? {
        if let link { return link.window }
        if let browser, let window = BrowserWindows.shared.window(for: browser) { return window }
        guard browser?.windowID == nil else { return nil }
        return NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frameAutosaveName == "yab" }
            ?? NSApp.mainWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        if isLink { return link.map { owner.toldTabs($0).filter(owner.seen).map(owner.adapter(for:)) } ?? [] }
        guard let browser else { return [] }
        return owner.listing(browser).adapters
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeAdapter }
    /// A popup, as Chrome's: tab managers sweeping normal windows leave it be.
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { isLink ? .popup : .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        if let link { return link.tab.shy }
        return browser?.windowPurpose == .privateOnly
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate(ignoringOtherApps: true)
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - where panels and popups hang

/// Where Site Controls is (SiteControls.swift), or an extension pinned in
/// the plate. There can be more than one of it: the plate's, a band's, a
/// small window's. The anchor is the one on screen in the window in front,
/// else the last to get there, never a small window behind; one leaving
/// hands it to the other.
@available(macOS 15.4, *)
final class AnchorView: NSView {
    let id: String
    /// The side the list opens toward from this one.
    var edge: NSRectEdge
    private var arrived: CFTimeInterval = 0
    private static let live = NSHashTable<AnchorView>.weakObjects()

    init(id: String, edge: NSRectEdge) {
        self.id = id
        self.edge = edge
        super.init(frame: .zero)
        AnchorView.live.add(self)
        _ = AnchorView.keyWatch
    }

    private static let keyWatch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { AnchorView.resettle() } }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Top down, as the SwiftUI around it: `.maxY` is the anchor's foot, so
    /// a list hangs below the row it opens from, wherever the window stands.
    /// Bottom up, `.maxY` was its top, and a window with room above it on
    /// the screen had the list open over its own title bar.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        arrived = window == nil ? 0 : CACurrentMediaTime()
        MainActor.assumeIsolated { AnchorView.settle(id) }
    }

    /// The ones for this extension showing in `window` now, for a window
    /// of the extension's own to hang from (ExtensionWindowFrame).
    @MainActor
    static func showing(_ id: String, in window: NSWindow) -> [NSView] {
        live.allObjects.filter { $0.id == id && $0.window === window && ExtensionWindowFrame.shows($0) }
    }

    /// Every one for this extension, said for a test run's log.
    @MainActor
    static func census(_ id: String) -> [String] {
        live.allObjects.filter { $0.id == id }.map { view in
            let alpha = sequence(first: view as NSView, next: \.superview).map(\.alphaValue).min() ?? 1
            return "webkit window=\(view.window?.windowNumber ?? -1) shows=\(ExtensionWindowFrame.shows(view)) size=\(view.bounds.size) alpha=\(alpha) hidden=\(view.isHiddenOrHasHiddenAncestor)"
        }
    }

    /// Every id again, after the window in front changed.
    @MainActor
    static func resettle() {
        Set(live.allObjects.map(\.id)).forEach(settle)
    }

    /// The key window and the windows it hangs from.
    @MainActor
    private static var frontChain: [NSWindow] {
        Array(sequence(first: NSApp.keyWindow, next: { $0?.parent }).prefix { $0 != nil }.compactMap { $0 })
    }

    @MainActor
    static func settle(_ id: String) {
        let here = live.allObjects.filter { $0.id == id && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        // The window in front's own anchors first; a small window's only while it is in front.
        let chain = frontChain
        let inFront = here.filter { view in chain.contains { $0 === view.window } }
        let frontHasDoor = live.allObjects.contains { view in
            view.id == Extensions.menuAnchor && !view.isHiddenOrHasHiddenAncestor && chain.contains { $0 === view.window }
        }
        let pool = !inFront.isEmpty ? inFront : frontHasDoor ? [] : here.filter { LinkWindow.owning($0.window) == nil }
        let pick = pool.max { $0.arrived < $1.arrived }
        let extensions = Extensions.shared
        extensions.anchors[id] = pick.map(WeakView.init)
        if id == Extensions.menuAnchor, let pick { extensions.menuEdge = pick.edge }
    }
}

/// An extension's icon with its badge in the corner. It fills what it is
/// given, `size` only sets its letter, so one traveling between a row
/// and a tile grows or shrinks on the way.
@available(macOS 15.4, *)
struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    // Its initial, rather than a puzzle piece that would
                    // pass for the button the list opens from.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.wash))
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                // A count rolls to its next value in place.
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: button.badge)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

private struct LandedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while a tile or row of the extensions list is on its way in or
    /// out (ExtensionMenu.Landing).
    fileprivate var landed: Bool {
        get { self[LandedKey.self] }
        set { self[LandedKey.self] = newValue }
    }
}

/// What a right-click on an extension offers.
@available(macOS 15.4, *)
struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        let pinned = extensions.installed.first { $0.id == id }?.pinned ?? false
        SwiftUI.Button(pinned ? "Unpin" : "Pin", mark: "pin") {
            ExtensionMenu.pin(id, !pinned, extensions)
        }
        if extensions.contexts[id]?.optionsPageURL != nil {
            SwiftUI.Button("Options…", mark: "gearshape") {
                ExtensionPanel.shared.close()
                extensions.openOptions(id)
            }
        }
        SwiftUI.Button("Reload", mark: "yab.reload") { extensions.reload(id) }
        Divider()
        // Not the name: a long one ("NordPass® Password Manager & Digital
        // Vault") made the menu as wide; the card that asks says it.
        SwiftUI.Button("Remove from Yab…", mark: "trash") { ExtensionActions.confirmRemove(id, name: name, extensions) }
    }

    /// The puzzle's list put away first, so the card isn't under it. What it kept can't come back, so
    /// the yes is red and takes ⌘Return.
    static func confirmRemove(_ id: String, name: String, _ extensions: Extensions) {
        ExtensionPanel.shared.close()
        Task {
            guard await extensions.ask(Extensions.removal(id, name: name, place: .plain)) else { return }
            extensions.remove(id)
        }
    }
}

@available(macOS 15.4, *)
extension Extensions {
    /// Removing one, from the puzzle's list or its page in Settings.
    static func removal(_ id: String, name: String, place: Question.Place) -> Question {
        Question(
            title: "Remove “\(name)”?", detail: "What it kept in Yab goes with it.",
            icon: ExtensionIconShape.rounded(Extensions.all.lazy.compactMap({ $0.contexts[id] }).first?.webExtension.icon(for: CGSize(width: 64, height: 64))),
            yes: "Remove", danger: true, place: place
        )
    }
}

/// The list, drawn off screen, for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@available(macOS 15.4, *)
@MainActor
func extensionMenuPicture(dark: Bool? = nil) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: ExtensionMenu(extensions: .here))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! } ?? NSApp.effectiveAppearance
    window.contentView = WindowHosting.measured(host)
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

/// The list ⌘E and the puzzle open: the pinned as tiles along the top, 1 to
/// 9 on the keyboard; a field that filters as you type; the rest below it;
/// the way to the store and to Settings.
///
/// What is chosen, pressed, pinned or not shows at once, state is never
/// animated. What moves is layout. A filter, done many times a day, changes
/// the list at once and only the popover's edge follows, in 0.13 s. Pinning,
/// the one rare thing here, where the icon itself travels from its row to
/// its tile and back (0.34 s), growing or shrinking on the way, while the
/// rest make room. Around the icon, the one it leaves goes at once and the
/// one it lands in comes in as it gets there. The popover's edge follows
/// the list on the same curve (ExtensionPanel.follow), so the two never
/// part.
@available(macOS 15.4, *)
struct ExtensionMenu: View {
    @ObservedObject var extensions: Extensions
    @State private var query = ""
    /// What Return presses: an index into the tiles, then the rows.
    @State private var chosen = 0
    @FocusState private var typing: Bool
    @Namespace private var icons

    static let pinning = Animation.smooth(duration: 0.34)
    /// Two rows of four; more pinned than that are listed, pin and all.
    static let tileLimit = 8
    /// Rows past this many scroll, 300 points of them.
    static let rowLimit = 9
    /// The popover's own corner (macOS 26), and how far in everything sits
    /// from its edge. Every rounded thing inside is concentric with it:
    /// its radius is the corner less the inset, and a button inside a tile
    /// or row is inset again and loses as much again.
    static let corner: CGFloat = 20
    static let inset: CGFloat = 8
    static var inner: CGFloat { corner - inset }

    /// Pins or unpins, telling the popover the list is about to move so its
    /// edge moves with it.
    static func pin(_ id: String, _ on: Bool, _ extensions: Extensions) {
        ExtensionPanel.shared.expect(.pinning)
        withAnimation(pinning) { extensions.setPinned(id, on) }
    }

    var body: some View {
        let buttons = extensions.buttons
        let needle = query.trimmingCharacters(in: .whitespaces)
        // The tiles stay put while filtering, faded and folded away, so
        // typing never sends an icon flying down to a row.
        let pinned = Array(buttons.filter(\.pinned).prefix(ExtensionMenu.tileLimit))
        let tiles = needle.isEmpty ? pinned : []
        let tiled = Set(pinned.map(\.id))
        // The ones just added lead the rows until the list has been seen.
        let untiled = buttons.filter { !tiled.contains($0.id) }
        let rows = needle.isEmpty
            ? untiled.filter { extensions.unseen.contains($0.id) } + untiled.filter { !extensions.unseen.contains($0.id) }
            : buttons.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.label.localizedCaseInsensitiveContains(needle) }
        let choices = tiles + rows
        let pick = choices.indices.contains(chosen) ? choices[chosen].id : nil

        VStack(alignment: .leading, spacing: 0) {
            if extensions.installed.isEmpty {
                Empty(extensions: extensions)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    TileGrid(folded: !needle.isEmpty) {
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, button in
                            Tile(button: button, key: index + 1, chosen: pick == button.id, icons: icons, extensions: extensions)
                                .transition(Landing())
                        }
                    }
                    .opacity(needle.isEmpty ? 1 : 0)
                    field(tiles: tiles, choices: choices, pick: pick)
                    Group {
                        if !rows.isEmpty {
                            let list = VStack(spacing: 1) {
                                ForEach(rows) { button in
                                    // A pinned one found by a filter is not its
                                    // tile's icon, so nothing flies to it.
                                    Row(button: button, glyph: tiled.contains(button.id) ? "found-" + button.id : button.id,
                                        chosen: pick == button.id, icons: icons, extensions: extensions)
                                        .transition(Landing())
                                }
                            }
                            // Unscrolled while they fit, so nothing clips an
                            // icon on its way to a tile.
                            if rows.count > ExtensionMenu.rowLimit {
                                ThreadScrollView { list }.frame(height: 300)
                            } else {
                                list
                            }
                        } else if !needle.isEmpty {
                            Text("Nothing called “\(needle)”")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        } else if buttons.isEmpty {
                            Text("All your extensions are off")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.top, rows.isEmpty && needle.isEmpty && !buttons.isEmpty ? 0 : 6)
                }
                .padding(ExtensionMenu.inset)
            }
            // Empty, the invitation already says all of this.
            if needle.isEmpty, !extensions.installed.isEmpty {
                Divider().overlay(Palette.hairline)
                VStack(spacing: 1) {
                    Foot("storefront", "Chrome Web Store…") {
                        ExtensionPanel.shared.close()
                        extensions.browser?.open(Browser.webStore, foreground: true)
                    }
                    Foot("folder", "Load Unpacked…") {
                        ExtensionPanel.shared.close()
                        DispatchQueue.main.async { extensions.installFolder() }
                    }
                    Foot("gearshape", "Manage Extensions…") { ExtensionMenu.manage(extensions) }
                }
                .padding(ExtensionMenu.inset)
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        // Its own height, for the popover to follow; held to the top, so
        // while the edge catches up nothing is centered in it.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ExtensionPanel.shared.follow($0, filter: needle) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .onChange(of: needle) { chosen = 0 }
        .onAppear { typing = true }
    }

    static func manage(_ extensions: Extensions) {
        ExtensionPanel.shared.close()
        // From a window of their sign-in, so Settings lists theirs.
        let window = BrowserWindows.shared.activeBrowser.flatMap { Extensions.of($0) === extensions ? $0 : nil }
            ?? BrowserWindows.shared.browsers.first { Extensions.of($0) === extensions } ?? extensions.browser
        window?.openSettings(.extensions)
    }

    /// The field: typing filters; digits press a tile while it is empty;
    /// the arrows move what Return presses; Esc empties it, then closes.
    private func field(tiles: [Extensions.Button], choices: [Extensions.Button], pick: String?) -> some View {
        HStack(spacing: 6) {
            Symbol("magnifyingglass", size: 10.5).foregroundStyle(Palette.muted)
            TextField("", text: $query, prompt: Text("Find an extension").foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($typing)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard !InputMethod.composing(), press.modifiers.isEmpty else { return .ignored }
                    if let pick { ExtensionPanel.shared.press(pick) }
                    return .handled
                }
                .onKeyPress(keys: [.downArrow], phases: .down) { press in
                    guard !InputMethod.composing(), press.modifiers.isEmpty else { return .ignored }
                    chosen = min(chosen + 1, max(choices.count - 1, 0))
                    return .handled
                }
                .onKeyPress(keys: [.upArrow], phases: .down) { press in
                    guard !InputMethod.composing(), press.modifiers.isEmpty else { return .ignored }
                    chosen = max(chosen - 1, 0)
                    return .handled
                }
                .onKeyPress(keys: [.escape], phases: .down) { press in
                    guard !InputMethod.composing(), press.modifiers.isEmpty else { return .ignored }
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .onKeyPress(phases: .down) { _ in
                    guard !InputMethod.composing(), query.isEmpty, let event = NSApp.currentEvent, let key = Hotkey(event), key.flags.isEmpty,
                          let n = Int(key.key), n >= 1, n <= tiles.count else { return .ignored }
                    chosen = n - 1
                    ExtensionPanel.shared.press(tiles[n - 1].id)
                    return .handled
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner, style: .continuous).strokeBorder(Palette.hairline))
    }

    /// A pinned one: its icon, its name, its number.
    private struct Tile: View {
        let button: Extensions.Button
        let key: Int
        let chosen: Bool
        let icons: Namespace.ID
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            VStack(spacing: 4) {
                ExtensionIcon(button: button, size: 22)
                    .matchedGeometryEffect(id: button.id, in: icons)
                    .frame(width: 26, height: 26)
                Text(button.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .modifier(Around())
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner, style: .continuous).fill(chosen || hovering ? Palette.wash : .clear).animation(nil, value: chosen || hovering).modifier(Around()))
            .overlay(alignment: .topLeading) {
                if key <= 9 {
                    Text("\(key)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, 8)
                        .padding(.top, 6)
                        .modifier(Around())
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    // Smaller than a row's, clear of the icon.
                    Tool(symbol: "pin.slash", help: "Unpin", size: 18) {
                        ExtensionMenu.pin(button.id, false, extensions)
                    }
                    .padding(Tool.inset)
                    .modifier(Around())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { ExtensionPanel.shared.press(button.id) }
            .onHover { hovering = $0 }
            .keyTip(button.label, keys: button.keys)
            .steadyMenu(actions: true) { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
            // Dragged onto another tile, it takes that one's place.
            .draggable(button.id)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, id != button.id else { return false }
                withAnimation(ExtensionMenu.pinning) { extensions.movePinned(id, to: button.id) }
                return true
            }
        }
    }

    private struct Row: View {
        let button: Extensions.Button
        /// Which icon it is: the extension's own, or, for a pinned one a
        /// filter found, one of its own, so its tile's doesn't fly to it.
        let glyph: String
        let chosen: Bool
        let icons: Namespace.ID
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ExtensionIcon(button: button, size: 16)
                    .matchedGeometryEffect(id: glyph, in: icons)
                    .frame(width: 20, height: 20)
                HStack(spacing: 9) {
                    Text(button.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering, extensions.installed.first(where: { $0.id == button.id })?.source != nil {
                        Tool(symbol: "arrow.clockwise", help: "Load again from the folder") { extensions.reload(button.id) }
                    }
                    if hovering || chosen || button.pinned {
                        Tool(symbol: button.pinned ? "pin.fill" : "pin", help: button.pinned ? "Unpin" : "Pin to the top", on: button.pinned) {
                            ExtensionMenu.pin(button.id, !button.pinned, extensions)
                        }
                    }
                }
                .modifier(Around())
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 22 + 2 * Tool.inset)
            .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner, style: .continuous).fill(chosen || hovering ? Palette.wash : .clear).animation(nil, value: chosen || hovering).modifier(Around()))
            .contentShape(Rectangle())
            .onTapGesture { ExtensionPanel.shared.press(button.id) }
            .onHover { hovering = $0 }
            .pointerTip(button.label)
            .steadyMenu(actions: true) { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
    }

    /// The tiles, four to a row, in one run, so a tile moving to the next
    /// row moves rather than leaving one row and arriving in another. With
    /// a filter they fold to nothing, and while any are there the gap to
    /// the field below is theirs.
    private struct TileGrid: Layout {
        var folded = false
        static let columns = 4
        static let spacing: CGFloat = 4
        static let gap: CGFloat = 6

        private func cell(_ width: CGFloat) -> CGFloat {
            (width - CGFloat(TileGrid.columns - 1) * TileGrid.spacing) / CGFloat(TileGrid.columns)
        }

        private func rowHeight(_ subviews: Subviews, width: CGFloat) -> CGFloat {
            subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell(width), height: nil)).height }.max() ?? 0
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 264
            guard !subviews.isEmpty, !folded else { return CGSize(width: width, height: 0) }
            let rows = (subviews.count + TileGrid.columns - 1) / TileGrid.columns
            let height = rowHeight(subviews, width: width)
            return CGSize(width: width, height: CGFloat(rows) * (height + TileGrid.spacing) - TileGrid.spacing + TileGrid.gap)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let side = cell(bounds.width)
            let height = rowHeight(subviews, width: bounds.width)
            for (index, subview) in subviews.enumerated() {
                let column = CGFloat(index % TileGrid.columns), row = CGFloat(index / TileGrid.columns)
                subview.place(
                    at: CGPoint(x: bounds.minX + column * (side + TileGrid.spacing), y: bounds.minY + row * (height + TileGrid.spacing)),
                    proposal: ProposedViewSize(width: side, height: height)
                )
            }
        }
    }

    /// A tile or a row coming or going. Its icon is its own business, it
    /// flies, so this only tells the rest of it which way it is headed.
    private struct Landing: Transition {
        func body(content: Content, phase: TransitionPhase) -> some View {
            content.environment(\.landed, phase.isIdentity)
        }
    }

    /// Everything of a tile or row but its icon: gone at once from the one
    /// the icon leaves, in over the second half of its flight at the one it
    /// lands in. Unanimated, a filter, at once both ways.
    private struct Around: ViewModifier {
        @Environment(\.landed) private var landed

        func body(content: Content) -> some View {
            content
                .opacity(landed ? 1 : 0)
                .transaction(value: landed) { transaction in
                    guard transaction.animation != nil else { return }
                    transaction.animation = landed ? .linear(duration: 0.15).delay(0.12) : .linear(duration: 0.08)
                }
        }
    }

    /// Nothing installed: an invitation rather than an apology. Where
    /// extensions come from, as rows like the list's own, the browsers on
    /// this Mac that have some, each brought over in one go with one
    /// question; the store; a folder.
    private struct Empty: View {
        @ObservedObject var extensions: Extensions
        @State private var sources: [(source: Chromium.Source, found: [Chromium.Extension])] = []

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add your extensions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Chrome extensions run in Yab. Bring the ones you use, or find new ones.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 10)
                ForEach(sources, id: \.source.id) { entry in
                    let count = entry.found.count
                    Choice(title: "From \(entry.source.name)",
                           detail: extensions.busy != nil ? "Adding…" : "\(count) extension\(count == 1 ? "" : "s")") {
                        if let icon = entry.source.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                        }
                    } act: {
                        guard extensions.busy == nil else { return }
                        extensions.bringIn(entry.found, from: entry.source.name)
                    }
                }
                Choice(title: "Chrome Web Store", detail: "Find new ones") {
                    Symbol("storefront", size: 12).foregroundStyle(Palette.muted)
                } act: {
                    ExtensionPanel.shared.close()
                    extensions.browser?.open(Browser.webStore, foreground: true)
                }
                Choice(title: "Load Unpacked…", detail: "A folder with a manifest.json") {
                    Symbol("folder", size: 12).foregroundStyle(Palette.muted)
                } act: {
                    ExtensionPanel.shared.close()
                    DispatchQueue.main.async { extensions.installFolder() }
                }
            }
            .padding(ExtensionMenu.inset)
            .onAppear {
                // Reading other browsers' preferences is file work: off the
                // main thread, and the rows for them arrive when it's done.
                DispatchQueue.global(qos: .userInitiated).async {
                    let found = Chromium.installed()
                        .map { (source: $0, found: Chromium.extensions(in: $0).filter(\.enabled)) }
                        .filter { !$0.found.isEmpty }
                    DispatchQueue.main.async { sources = found }
                }
            }
        }

        private struct Choice<Icon: View>: View {
            let title: String
            let detail: String
            @ViewBuilder let icon: () -> Icon
            let act: () -> Void
            @State private var hovering = false

            var body: some View {
                HStack(spacing: 10) {
                    icon().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner, style: .continuous).fill(hovering ? Palette.wash : .clear))
                .contentShape(Rectangle())
                .onTapGesture(perform: act)
                .onHover { hovering = $0 }
            }
        }
    }

    /// A small icon button at the end of a row or the corner of a tile,
    /// inset from their edge and rounded to match them.
    private struct Tool: View {
        static let inset: CGFloat = 4
        let symbol: String
        let help: String
        var on = false
        var size: CGFloat = 22
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: act) {
                Symbol(symbol, size: size * 0.48, weight: .medium)
                    .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner - Tool.inset, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyTip(help)
        }
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Symbol(symbol, size: 11).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: ExtensionMenu.inner, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

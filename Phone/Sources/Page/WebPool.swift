import Network
import UIKit
import WebKit
import os

/// One WKWebView per tab, but only a few alive: the tab in front and the
/// ones just left. A tab left further behind is kept as a picture and its
/// web view let go (iOS keeps far fewer live pages than a Mac), and comes
/// back from its page when it is in front again. Paging and the column draw
/// the pictures.
@MainActor
final class WebPool: NSObject {
    /// Live web views at most, the one in front among them.
    static let liveLimit = 3

    let fixturesEnabled: Bool
    private let configuration: WKWebViewConfiguration
    /// Private tabs' pages: a store kept in memory only, gone with the app,
    /// and renewed once the last private tab has closed.
    private var privateConfiguration: WKWebViewConfiguration
    /// One object per domain keeps native store identity stable within the pool.
    private var spaceConfigurations: [Space.ID: (identity: UUID?, configuration: WKWebViewConfiguration)] = [:]
    /// Configurations copied for pages: one per page made, none for a page
    /// already alive (crash #104 was sampled copying them on every update).
    private(set) var configurationCopies = 0
    private var interactionOrigins: [Tab.ID: ObjectIdentifier] = [:]
    var spaceForTab: ((Tab.ID) -> Space?)?
    var websiteStoreID: ((Space) -> UUID?)?
    private var live: [Tab.ID: WKWebView] = [:]
    private var viewport: PageViewport?
    /// Most recent first.
    private var recent: [Tab.ID] = []
    private var tabsByView: [ObjectIdentifier: Tab.ID] = [:]
    /// Only views created by WebKit may close their own popup tab.
    private var popupOpeners: [Tab.ID: Tab.ID] = [:]
    private var scrollWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var urlWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var loadingWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var progressWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var backWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var forwardWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var underPageWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var pageStates: [Tab.ID: PageState] = [:]
    private var readerResults: [Tab.ID: (available: Bool, enabled: Bool)] = [:]
    private var readerScroll: [Tab.ID: CGFloat] = [:]
    private var readerDocuments: [Tab.ID: String] = [:]
    private var readerGeneration: [Tab.ID: UUID] = [:]
    private var readerProbes: [Tab.ID: Task<Void, Never>] = [:]
    private var readerActions: Set<Tab.ID> = []
    private var titleWatch: [Tab.ID: NSKeyValueObservation] = [:]
    private var privateTabs: Set<Tab.ID> = []
    private var navigation: [Tab.ID: BrowserNavigation] = [:]
    private var interactions: [Tab.ID: Any] = [:]
    private var restoreScroll: [Tab.ID: CGFloat] = [:]
    private var pendingIndex: [Tab.ID: Int] = [:]
    private var actionTypes: [Tab.ID: WKNavigationType] = [:]
    private var modelAddresses: [Tab.ID: String] = [:]
    private var requestedURLs: [Tab.ID: String] = [:]
    private var initialLoads: Set<Tab.ID> = []
    private var recoveries: [Tab.ID: Int] = [:]
    /// Pages whose process iOS ended while Yab was away: reloaded when Yab
    /// is back, never shown as stopped.
    private var stoppedAway: Set<Tab.ID> = []
    private var failures: [Tab.ID: String] = [:]
    private var loadFailures: [Tab.ID: PageLoadFailure] = [:]
    private var activeNavigations: [Tab.ID: WKNavigation] = [:]
    private var documents: [Tab.ID: UUID] = [:]
    private var committedURLs: [Tab.ID: URL] = [:]
    /// Tabs whose navigation has started and neither committed nor failed.
    /// When one fails, WebKit puts the old address back on the view before
    /// it says so; that is no navigation to the old page.
    private var provisional: Set<Tab.ID> = []
    /// Watches for the network to come back while a page failed offline:
    /// its error says it opens by itself then.
    private var network: NWPathMonitor?
    private let retiredNavigations = NSHashTable<WKNavigation>.weakObjects()
    private(set) var javaScriptDialog: PageJavaScriptDialog?
    private(set) var httpAuthentication: PageHTTPAuthentication?
    private struct DownloadOrigin {
        let requestURL: URL
        let frameURL: URL?
        let url: URL?
        let document: UUID?
        let store: ObjectIdentifier
        let privateSession: UUID?
    }
    private var downloadOrigins: [Tab.ID: DownloadOrigin] = [:]
    private struct DownloadConversion {
        let origin: DownloadOrigin
        let document: UUID?
        let navigation: WKNavigation?
    }
    private var downloadConversions: [Tab.ID: DownloadConversion] = [:]
    private struct WindowFile {
        let opener: Tab.ID
        let request: URL
        var navigation: WKNavigation?
    }
    /// Only the first navigation of a window opened at a file URL may send
    /// its download to the opener. A blank window assigned later cannot.
    private var firstWindowLoads: [Tab.ID: WindowFile] = [:]
    private var windowFiles: [Tab.ID: WindowFile] = [:]
    /// Tabs whose main frame was just sent on to an app's link and refused.
    private var appLinks: Set<Tab.ID> = []
    /// When the person last touched each tab's page (uptime), as Yab's own
    /// script world heard it (PageSignals): a link may then leave for an app.
    private var touches: [Tab.ID: TimeInterval] = [:]
    /// The last window each tab opened: on which touch, and when (uptime).
    private var openedWindows: [Tab.ID: (touch: TimeInterval?, at: TimeInterval)] = [:]
    /// Files on their way, by entry. A transfer outlives its page.
    private(set) var transfers: [UUID: PageDownload] = [:]
    /// Everything downloaded (DownloadStore).
    let downloads: DownloadStore
    /// A site wants to send a file: nil lets it (tests of the transfer itself).
    var onDownloadAsk: (@MainActor (DownloadAsk, @escaping @MainActor (Bool) -> Void) -> Void)?
    private var pageInteractionsEnabled = true
    /// Yab is in the background (or inactive on its way there).
    private var appAway = false
    var pageVisibility: (@MainActor (Tab.ID) -> Bool)?
    private weak var pageInteractionHost: UIView?
    private var scrollPublications: [Tab.ID: Task<Void, Never>] = [:]
    private var refreshNavigations: [Tab.ID: WKNavigation] = [:]
    /// Pictures of tabs not in front, for paging and the spaces' holds.
    private(set) var snapshots: [Tab.ID: UIImage] = [:]
    /// Which tabs' pages play media, and the audio session that follows.
    let playback = PagePlayback()
    /// Told when a tab's picture is new (the tab stack draws them).
    var onPicture: ((Tab.ID) -> Void)?
    /// Told when a tab's page has loaded and drawn (Tabs/TabPictures takes
    /// its card's picture once it has settled).
    var onPainted: ((Tab.ID) -> Void)?
    /// Tabs alive only to be pictured for their cards (All Tabs' warm-up,
    /// Tabs/TabWarmup): true for a view made for it, false for one that
    /// was alive already.
    private var borrowed: [Tab.ID: Bool] = [:]
    private struct SnapshotOrigin: Equatable {
        let address: String
        let isPrivate: Bool
        let store: ObjectIdentifier
        let privateSession: UUID?
        let viewport: PageViewport?
        let pageSize: CGSize
        let contentTop: CGFloat
        let layoutSession: UUID
    }
    private var layoutSession = UUID()
    private var privateSession = UUID()
    private var snapshotOrigins: [Tab.ID: SnapshotOrigin] = [:]
    /// Tabs whose page has loaded and painted.
    private(set) var painted: Set<Tab.ID> = []
    private var paintWaiters: [Tab.ID: [(token: UUID, waiter: CheckedContinuation<Void, Never>)]] = [:]
    private(set) var front: Tab.ID?

    /// A tab's page scrolled: how far down it is, in points.
    var onScroll: ((Tab.ID, CGFloat) -> Void)?
    /// A native layout correction, expressed as a delta so an inner DOM
    /// scroller keeps its own direction anchor.
    var onScrollRebase: ((Tab.ID, CGFloat) -> Void)?
    /// An inner scroller moved because our insets did: only its position,
    /// no direction.
    var onScrollSettle: ((Tab.ID, CGFloat) -> Void)?
    /// How often each kind of scroll reached the chrome, for the update-loop
    /// log: a loop shows which of these keeps counting.
    private(set) var scrollSources: [String: Int] = [:]
    /// Trusted foreground activity; no page words or Private data leave the pool.
    var onActivity: ((Tab.ID) -> Void)?
    private var clearActivity: [Tab.ID: UInt64] = [:]
    /// What a page said about itself once loaded: dark or not.
    var onReport: ((Tab.ID, PageReport) -> Void)?
    /// A tab's web view is at another page: a load, Back or Forward (a page
    /// from the back-forward cache too).
    var onCommit: ((Tab.ID, URL) -> Void)?
    var onMetadata: ((Tab.ID, URL, String) -> Void)?
    /// A navigation failed: the tab is at the address it couldn't open, as
    /// its error says, not at the page it started from.
    var onFailure: ((Tab.ID, URL) -> Void)?
    var onNavigation: ((Tab.ID, BrowserNavigation) -> Void)?
    var navigationForTab: ((Tab.ID) -> BrowserNavigation?)?
    var onOpenWindow: ((URL, Bool) -> Tab?)?
    /// What Yab remembers per site (zoom, desktop, permissions) and the host
    /// and privacy a tab's page is kept under (AppModel says).
    var siteSettings: SiteSettings?
    var siteOf: ((Tab.ID, URL?) -> (host: String?, isPrivate: Bool))?
    /// Back and forward from anywhere on a page (Back/SwipeAnywhere).
    weak var swipeHost: SwipeAnywhereHost?
    var onOpenWindowFrom: ((URL, Tab.ID, Bool) -> Tab?)?
    var onCloseWindowFrom: ((Tab.ID, Tab.ID) -> Void)?
    /// What a held image's action came to, for the toast.
    var onImageSaved: (@MainActor (PageImage.Outcome) -> Void)?
    /// Open in New Tab or Open in Background Tab on a held link (PageLinkMenu).
    var onOpenLink: ((URL, Tab.ID, PageLinkMenu.Opening) -> Void)?
    /// The ad blocker: each page's lists, for the site it is heading to.
    var shield: Shield?

    /// Only native page values or an isolated-world Reader result reach chrome.
    struct PageState: Equatable, Sendable {
        var isLoading = false
        var progress: Double = 0
        var canGoBack = false
        var canGoForward = false
        var readerAvailable = false
        var readerEnabled = false
        var failure: PageLoadFailure?
        static let idle = PageState()
    }
    var onState: ((Tab.ID, PageState) -> Void)?

    struct PageReport: Equatable, Sendable {
        var dark: Bool
    }

    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "page")

    /// Safari's own name after WebKit's (see init). Extensions' pages and
    /// workers take the same, to the letter (ExtensionHost).
    static let userAgentName: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
    }()

    init(dataStore: WKWebsiteDataStore, fixturesEnabled: Bool = true, downloads: DownloadStore? = nil) {
        self.fixturesEnabled = fixturesEnabled
        self.downloads = downloads ?? .temporary()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(PageSchemeHandler(), forURLScheme: PageSchemeHandler.scheme)
        configuration.allowsInlineMediaPlayback = true
        // WebKit's player offers Picture in Picture, inline video too, and a
        // playing video goes on in it with Yab away (PagePlayback).
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        // Every page zooms with two fingers, paying no mind to a page's
        // user-scalable=no or maximum-scale: Google Images'
        // viewer says both, so its picture could not be pinched larger.
        configuration.ignoresViewportScaleLimits = true
        // Safari's own name after WebKit's, as Safari sends it: without it a
        // site takes Yab for an app's built-in browser and sends it on to its
        // app (x.com, through redirect.x.com) instead of showing the page.
        configuration.applicationNameForUserAgent = Self.userAgentName
        self.configuration = configuration
        let shy = configuration.copy() as! WKWebViewConfiguration
        shy.websiteDataStore = .nonPersistent()
        privateConfiguration = shy
        // Extensions run in every ordinary page (Extensions/ExtensionHost);
        // not in Private, where they stay out unless allowed.
        if !fixturesEnabled, ExtensionHost.isAvailable { ExtensionHost.shared.attach(configuration, store: dataStore) }
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restyleReaders),
                                               name: ReaderStyle.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(websiteDarkeningChanged),
                                               name: SettingsStore.websiteDarkeningChanged, object: SettingsStore.shared)
        let controller = configuration.userContentController
        controller.add(WeakMessages(self), name: "yabPage")
        controller.addUserScript(WKUserScript(source: Self.reporter, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        PageSignals.install(in: controller, handler: WeakMessages(self))
        // Private pages say the same about themselves.
        privateConfiguration.userContentController = controller
    }

    isolated deinit {
        transfers.values.forEach { $0.cancel() }
        javaScriptDialog?.resolve(nil, animated: false)
        httpAuthentication?.resolve(user: nil, password: nil, animated: false)
        NotificationCenter.default.removeObserver(self)
    }

    /// PageHost supplies actual visibility and the existing Private gate.
    /// Transfers don't mind; what one came to is said once the page is in use.
    func setPageInteractionsEnabled(_ enabled: Bool) {
        pageInteractionsEnabled = enabled
        if !enabled { suspendPageDialogs() }
        else if !appAway { comeBackDownloads() }
    }

    func bindPageInteractions(to host: UIView, enabled: Bool, visibility: @escaping @MainActor (Tab.ID) -> Bool) {
        pageInteractionHost = host
        pageVisibility = visibility
        setPageInteractionsEnabled(enabled)
    }

    func releasePageInteractions(from host: UIView) {
        guard pageInteractionHost === host else { return }
        pageInteractionHost = nil
        pageVisibility = nil
        setPageInteractionsEnabled(false)
    }

    @objc func suspendPageDialogs() {
        let previous = javaScriptDialog
        javaScriptDialog = nil
        previous?.resolve(nil, animated: false)
        let authentication = httpAuthentication
        httpAuthentication = nil
        authentication?.resolve(user: nil, password: nil, animated: false)
    }

    /// Leaving for the background: page dialogs go, a download goes on
    /// (PageDownload.leave) and says where it came to when Yab is back.
    @objc func appWillResignActive() {
        appAway = true
        suspendPageDialogs()
        transfers.values.forEach { $0.leave() }
        downloads.leave()
    }

    @objc func appDidBecomeActive() {
        Links.trace("pagesActive front=\(front ?? "nil") stopped=\(stoppedAway)")
        appAway = false
        if pageInteractionsEnabled { comeBackDownloads() }
        reloadStoppedPages()
    }

    private func comeBackDownloads() {
        transfers.values.forEach { $0.comeBack() }
        downloads.comeBack()
    }

    #if DEBUG
    /// UI tests: ends every live page's web content process, as iOS does to
    /// an app away for a while (-YabTestEndPagesAway, YabPhoneApp).
    func endPageProcessesForTests() {
        let name = NSSelectorFromString("_killWebContentProcess")
        for view in live.values where view.responds(to: name) { _ = view.perform(name) }
    }
    #endif

    /// Back from the background: the page on screen whose process stopped
    /// meanwhile loads again at once, with no error pane between. The others
    /// load when they are shown (view(for:)), so Yab coming
    /// back with memory still short doesn't load them all at once (#350).
    private func reloadStoppedPages() {
        for (id, failure) in loadFailures where failure.kind == .process && !shown(id) {
            loadFailures[id] = nil; failures[id] = nil
            stoppedAway.insert(id)
            publishState(id)
        }
        if !stoppedAway.isEmpty { log.info("\(self.stoppedAway.count) pages stopped while away") }
        let wanted = Set(stoppedAway.filter(shown)).union(loadFailures.filter { $0.value.kind == .process }.keys)
        for id in wanted.filter({ $0 == front }) + wanted.filter({ $0 != front }) { revive(id) }
    }

    /// On screen or about to be: the tab in front, the other of an iPad's
    /// pair, or one being warmed up for the tab stack (waiting for paint).
    private func shown(_ id: Tab.ID) -> Bool {
        id == front || workspaceTabs.contains(id) || paintWaiters[id]?.isEmpty == false
    }

    /// A page whose process stopped, loaded again in its own view and store.
    private func revive(_ id: Tab.ID) {
        Links.trace("revive tab=\(id)")
        stoppedAway.remove(id)
        guard live[id] != nil else { return }
        log.info("reloading the stopped page of \(id, privacy: .public)")
        recoveries[id] = nil
        loadFailures[id] = nil
        failures[id] = nil
        if reload(id) == nil {
            loadFailures[id] = PageLoadFailure(processURL: live[id].flatMap { reloadURL(id, in: $0) })
            failures[id] = "The web content process stopped"
        }
        publishState(id)
    }

    /// `evenAway`: a transfer's source while Yab is in the background, the
    /// page still in front and in its own store, but not in use.
    private func canInteract(_ id: Tab.ID, in view: WKWebView, evenAway: Bool = false) -> Bool {
        let inUse = pageInteractionsEnabled && pageVisibility?(id) != false
            && UIApplication.shared.applicationState == .active
            && view.window?.isKeyWindow == true && view.window?.windowScene?.activationState == .foregroundActive
        guard front == id, live[id] === view, inUse || (evenAway && appAway) else { return false }
        if privateTabs.contains(id) { return view.configuration.websiteDataStore === privateConfiguration.websiteDataStore }
        if let owner = spaceForTab?(id) {
            return view.configuration.websiteDataStore === baseConfiguration(in: owner).websiteDataStore
        }
        return view.configuration.websiteDataStore === configuration.websiteDataStore
    }

    /// The person touched this page, in front and in use, just now.
    private func tapped(_ id: Tab.ID, in view: WKWebView) -> Bool {
        guard canInteract(id, in: view), let touch = touches[id] else { return false }
        return ProcessInfo.processInfo.systemUptime - touch <= PageLinkRoute.tapWindow
    }

    /// This touch already opened a window.
    private func touchSpent(_ id: Tab.ID) -> Bool {
        guard let touch = touches[id], let opened = openedWindows[id] else { return false }
        return opened.touch == touch
    }

    /// The tab opened a window and nothing has touched it since, and the
    /// person is on that window now or it opened a moment ago: the new tab
    /// comes to the front after the page's next line has run.
    private func behindItsWindow(_ id: Tab.ID) -> Bool {
        guard let opened = openedWindows[id], opened.touch == touches[id] else { return false }
        return front != id || ProcessInfo.processInfo.systemUptime - opened.at <= PageLinkRoute.tapWindow
    }

    private func dialogStillBelongs(_ dialog: PageJavaScriptDialog) -> Bool {
        guard let view = dialog.webView, canInteract(dialog.tab, in: view), loadFailures[dialog.tab] == nil else { return false }
        return documents[dialog.tab] == dialog.document && view.url == dialog.url
            && ObjectIdentifier(view.configuration.websiteDataStore) == dialog.store
            && dialog.privateSession == (privateTabs.contains(dialog.tab) ? privateSession : nil)
    }

    private func answerDialog(_ id: UUID, value: String?) {
        guard let dialog = javaScriptDialog, dialog.id == id else { return }
        let accepted = dialogStillBelongs(dialog)
        javaScriptDialog = nil
        dialog.resolve(accepted ? value : nil, animated: accepted && !Motion.disabled)
    }

    private func showJavaScriptDialog(_ view: WKWebView, frame: WKFrameInfo, message: String,
                                     kind: PageJavaScriptDialog.Kind, defaultText: String? = nil,
                                     completion: @escaping @MainActor (String?) -> Void) {
        guard let id = tabsByView[ObjectIdentifier(view)], canInteract(id, in: view),
              let document = documents[id], loadFailures[id] == nil, javaScriptDialog == nil, httpAuthentication == nil,
              let parent = view.window?.rootViewController, parent.presentedViewController == nil else {
            completion(nil); return
        }
        // WebKit supplies this frame's origin; never attribute iframe text to
        // an unrelated top-level site or parse an origin from the message.
        let origin = frame.request.url
        let site = origin?.host.map { $0 + (origin?.port.map { ":\($0)" } ?? "") } ?? "This webpage"
        let dialog = PageJavaScriptDialog(tab: id, webView: view, document: document,
            privateSession: privateTabs.contains(id) ? privateSession : nil,
            site: site, message: message, kind: kind, defaultText: defaultText, completion: completion)
        if kind != .alert {
            dialog.controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak dialog] _ in
                guard let dialog else { return }; self?.answerDialog(dialog.id, value: nil)
            })
        }
        dialog.controller.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak dialog] _ in
            guard let dialog else { return }
            let value = kind == .prompt ? dialog.controller.textFields?.first?.text : "accepted"
            self?.answerDialog(dialog.id, value: value)
        })
        javaScriptDialog = dialog
        parent.present(dialog.controller, animated: !Motion.disabled)
    }

    /// A reply must still belong to the captured document, request and jar.
    func answerHTTPAuthentication(_ token: UUID, user: String?, password: String?) {
        guard let authentication = httpAuthentication, authentication.id == token else { return }
        let view = authentication.webView
        let accepted = view.map {
            canInteract(authentication.tab, in: $0) && documents[authentication.tab] == authentication.document
                && activeNavigations[authentication.tab] === authentication.navigation
                && $0.url == authentication.url && requestedURLs[authentication.tab] == authentication.requestedURL
                && ObjectIdentifier($0.configuration.websiteDataStore) == authentication.store
                && authentication.privateSession == (privateTabs.contains(authentication.tab) ? privateSession : nil)
        } ?? false
        httpAuthentication = nil
        // Only an explicit reply in this still-current pending navigation
        // becomes a visible cancellation. Retired/covered challenges stay silent.
        if accepted, user == nil, password == nil, let view,
           let navigation = authentication.navigation,
           let requested = authentication.requestedURL.flatMap(URL.init(string:)), allows(requested) {
            let id = authentication.tab
            let previous = committedURLs[id] != requested ? committedURLs[id] : nil
            activeNavigations[id] = nil
            retiredNavigations.add(navigation)
            downloadOrigins[id] = nil; downloadConversions[id] = nil
            let failure = PageLoadFailure(authenticationURL: requested, previousURL: previous)
            loadFailures[id] = failure; failures[id] = failure.explanation
            requestedURLs[id] = requested.absoluteString; pendingIndex[id] = nil
            painted.remove(id)
            invalidateReader(id)
            // WebKit can otherwise commit the server's 401 body after Cancel.
            // Retire its exact token before stopping or completing the challenge.
            view.stopLoading(); endRefresh(id, in: view)
            publishState(id); resume(id)
        }
        authentication.resolve(user: accepted ? user : nil, password: accepted ? password : nil,
                               animated: accepted && !Motion.disabled)
    }

    private func showHTTPAuthentication(_ view: WKWebView, challenge: URLAuthenticationChallenge,
            completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let id = tabsByView[ObjectIdentifier(view)], canInteract(id, in: view),
              let document = documents[id], challenge.previousFailureCount < 2,
              javaScriptDialog == nil, httpAuthentication == nil,
              let parent = view.window?.rootViewController, parent.presentedViewController == nil else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        let space = challenge.protectionSpace
        let candidates = [view.url, requestedURLs[id].flatMap(URL.init(string:))].compactMap { $0 }
        // The navigation delegate has no originating frame. Only the actual
        // top-level request/current URL may ask, never a third-party resource.
        guard candidates.contains(where: { PageHTTPAuthentication.matches(space, url: $0) }) else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        let defaultPort = space.protocol?.lowercased() == "https" ? 443 : 80
        let site = space.host + (space.port == defaultPort ? "" : ":\(space.port)")
        let authentication = PageHTTPAuthentication(tab: id, webView: view, navigation: activeNavigations[id],
            document: document, requestedURL: requestedURLs[id],
            privateSession: privateTabs.contains(id) ? privateSession : nil, site: site, completion: completion)
        authentication.controller.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak authentication] _ in
            guard let authentication else { return }
            self?.answerHTTPAuthentication(authentication.id, user: nil, password: nil)
        })
        authentication.controller.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self, weak authentication] _ in
            guard let authentication else { return }
            self?.answerHTTPAuthentication(authentication.id, user: authentication.controller.textFields?.first?.text,
                                          password: authentication.controller.textFields?.last?.text)
        })
        httpAuthentication = authentication
        parent.present(authentication.controller, animated: !Motion.disabled)
    }

    /// Retry only the captured failed navigation, in the selected native jar.
    @discardableResult
    func retryFailure(_ id: Tab.ID, expected: UUID) -> Bool {
        guard let view = live[id], canInteract(id, in: view), let failure = loadFailures[id],
              failure.id == expected, let url = failure.url, allows(url) else { return false }
        load(id, url)
        return true
    }

    private func watchNetwork() {
        guard network == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.networkReturned() }
        }
        network = monitor
        monitor.start(queue: .main)
    }

    /// Back online: every page that failed offline loads again; the watch
    /// ends once none is left.
    private func networkReturned() {
        for (id, failure) in loadFailures where failure.kind == .offline {
            _ = retryFailure(id, expected: failure.id)
        }
        guard !loadFailures.values.contains(where: { $0.kind == .offline }) else { return }
        network?.cancel(); network = nil
    }

    @discardableResult
    func backFailure(_ id: Tab.ID, expected: UUID) async -> Bool {
        guard let view = live[id], canInteract(id, in: view), loadFailures[id]?.id == expected else { return false }
        return await back(id)
    }

    private func navigationStarted(_ id: Tab.ID, in view: WKWebView, navigation: WKNavigation?) {
        Links.trace("loadStart tab=\(id) url=\(String(describing: view.url)) away=\(appAway)")
        downloadConversions[id] = nil
        windowFiles[id] = nil
        if var first = firstWindowLoads[id] {
            if first.navigation == nil {
                first.navigation = navigation
                firstWindowLoads[id] = first
            } else if first.navigation !== navigation { firstWindowLoads[id] = nil }
        }
        if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
        if let previous = activeNavigations[id], previous !== navigation { retiredNavigations.add(previous) }
        activeNavigations[id] = navigation
        provisional.insert(id)
        documents[id] = UUID()
        loadFailures[id] = nil
        failures[id] = nil
        painted.remove(id)
        snapshots[id] = nil; snapshotOrigins[id] = nil
        publishState(id)
    }

    /// Peek and popup pages use the same browsing mode and website store.
    func configurationForPage(isPrivate: Bool = false) -> WKWebViewConfiguration {
        copy(isPrivate ? privateConfiguration : configuration)
    }

    /// Missing durable identity stays transient and isolated, never Shared.
    func configurationForPage(in space: Space) -> WKWebViewConfiguration {
        copy(baseConfiguration(in: space))
    }

    /// The space's own configuration, shared, not to be handed to a page.
    private func baseConfiguration(in space: Space) -> WKWebViewConfiguration {
        if space.isPrivate { return privateConfiguration }
        guard !fixturesEnabled, space.ownSignIns else { return configuration }
        let identity = websiteStoreID?(space)
        if let saved = spaceConfigurations[space.id], saved.identity == identity { return saved.configuration }
        let made = configuration.copy() as! WKWebViewConfiguration
        made.websiteDataStore = identity.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .nonPersistent()
        spaceConfigurations[space.id] = (identity, made)
        return made
    }

    private func copy(_ configuration: WKWebViewConfiguration) -> WKWebViewConfiguration {
        configurationCopies += 1
        return configuration.copy() as! WKWebViewConfiguration
    }

    private func isPrivate(_ tab: Tab) -> Bool {
        tab.isPrivate || spaceForTab?(tab.id)?.isPrivate == true
    }

    func configurationForPage(for tab: Tab) -> WKWebViewConfiguration {
        // An extension's own page is served only to a view made with that
        // extension's configuration (as on the Mac, Browser.extensionConfiguration).
        if !fixturesEnabled, let url = tab.navigationURL, let own = ExtensionHost.shared.configuration(for: url) { return own }
        if isPrivate(tab) { return configurationForPage(isPrivate: true) }
        if let space = spaceForTab?(tab.id) { return configurationForPage(in: space) }
        return configurationForPage()
    }

    /// The store configurationForPage(for:) would give the tab, without
    /// copying a configuration and with one look for its space: PageHost
    /// asks on every SwiftUI update (crash #104).
    private func expectedStore(for tab: Tab) -> WKWebsiteDataStore {
        if !fixturesEnabled, let url = tab.navigationURL, let own = ExtensionHost.shared.configuration(for: url) {
            return own.websiteDataStore
        }
        let space = spaceForTab?(tab.id)
        if tab.isPrivate || space?.isPrivate == true { return privateConfiguration.websiteDataStore }
        if let space { return baseConfiguration(in: space).websiteDataStore }
        return configuration.websiteDataStore
    }

    private func matchesStore(_ view: WKWebView, for tab: Tab) -> Bool {
        view.configuration.websiteDataStore === expectedStore(for: tab)
    }

    /// A flag or move invalidates native session state, not portable history.
    @discardableResult
    func reconcileWebsiteStores(_ tabs: [Tab]) -> Bool {
        var changed = false
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for (id, view) in Array(live) {
            guard let tab = byID[id] else { forget(id); changed = true; continue }
            guard !matchesStore(view, for: tab) else { continue }
            invalidateWebsiteStore(id, for: tab)
            changed = true
        }
        return changed
    }

    private func invalidateWebsiteStore(_ id: Tab.ID, for tab: Tab) {
        let target = expectedStore(for: tab)
        let changedPrivacy = privateTabs.contains(id) != isPrivate(tab)
        release(id)
        interactions[id] = nil
        interactionOrigins[id] = nil
        snapshots[id] = nil
        snapshotOrigins[id] = nil
        restoreScroll[id] = nil
        pendingIndex[id] = nil
        requestedURLs[id] = nil
        actionTypes[id] = nil
        initialLoads.insert(id)
        if changedPrivacy {
            // A Private timeline is not portable into a public profile.
            navigation[id] = nil
        } else if var state = navigation[id] ?? navigationForTab?(id) {
            state.interactionData = nil
            state.websiteStoreID = target.identifier
            navigation[id] = state
            publishNavigation(id, state)
        }
    }

    func loadingURL(for tab: Tab) -> URL {
        fixturesEnabled ? tab.pageURL : (tab.navigationURL ?? URL(string: "about:blank")!)
    }

    /// The web view for a tab, made and restored when it has none.
    func view(for tab: Tab) -> WKWebView {
        Links.trace("view tab=\(tab.id) url=\(tab.address) away=\(appAway) stopped=\(stoppedAway.contains(tab.id))")
        if let view = live[tab.id], !matchesStore(view, for: tab) {
            invalidateWebsiteStore(tab.id, for: tab)
        }
        if let view = live[tab.id], changesKind(view, to: loadingURL(for: tab)) { release(tab.id); interactions[tab.id] = nil }
        if let view = live[tab.id] {
            // Its process stopped while Yab was away or the tab was behind:
            // it loads now it is wanted.
            if stoppedAway.contains(tab.id), !appAway { revive(tab.id) }
            let url = loadingURL(for: tab)
            if modelAddresses[tab.id] != url.absoluteString {
                modelAddresses[tab.id] = url.absoluteString
                // A model change (sync or the field) navigates once. A native
                // link's metadata echo already matches its page or pending load.
                if view.url?.absoluteString != url.absoluteString, requestedURLs[tab.id] != url.absoluteString {
                    load(tab.id, url)
                }
            }
            return view
        }
        let view = makeView(for: tab, configuration: configurationForPage(for: tab))
        let url = loadingURL(for: tab)
        var state = navigation[tab.id] ?? navigationForTab?(tab.id)
        // A sync change to the tab's address wins over an older local session.
        if let old = state, old.entries.indices.contains(old.index), old.entries[old.index].url != url.absoluteString {
            state = nil
            interactions[tab.id] = nil
        }
        let store = view.configuration.websiteDataStore
        let shared = store.isPersistent && store === configuration.websiteDataStore && !isPrivate(tab)
        let nativeOriginMatches = state?.websiteStoreID == store.identifier && store.identifier != nil
        // Legacy native data is valid only in the unchanged public Shared jar.
        if !nativeOriginMatches && !(state?.websiteStoreID == nil && shared) {
            state?.interactionData = nil
        }
        if interactionOrigins[tab.id] != ObjectIdentifier(store) { interactions[tab.id] = nil }
        if state != nil { state?.websiteStoreID = store.identifier }
        navigation[tab.id] = state ?? BrowserNavigation(entries: [.init(url: url.absoluteString, title: tab.title)], index: 0,
                                                        websiteStoreID: store.identifier)
        if state == nil { initialLoads.insert(tab.id) }
        requestedURLs[tab.id] = url.absoluteString
        if let state, state.entries.indices.contains(state.index) {
            restoreScroll[tab.id] = CGFloat(state.entries[state.index].scrollY)
        }
        if let state = interactions[tab.id] ?? state?.interactionData {
            view.interactionState = state
            // A state WebKit can't use still has its URL and scroll as a fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak view] in
                guard let self, let view, self.live[tab.id] === view, !view.isLoading,
                      view.url == nil || view.url?.absoluteString == "about:blank" && url.absoluteString != "about:blank" else { return }
                let token = view.load(URLRequest(url: url))
                self.navigationStarted(tab.id, in: view, navigation: token)
            }
        } else {
            let token = view.load(URLRequest(url: url))
            navigationStarted(tab.id, in: view, navigation: token)
        }
        return view
    }

    private func makeView(for tab: Tab, configuration: WKWebViewConfiguration) -> WKWebView {
        if live[tab.id] != nil { release(tab.id) }
        // A controller of its own, so the blocker's lists go on and off for
        // this page's site alone (Shield), as each tab's do on the Mac. The
        // lists go on once the view is made: given them before, a view's
        // first load sometimes never finished (ShieldStoreTests).
        let controller = pageController()
        configuration.userContentController = controller
        let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
        fitShield(controller, for: tab.id, url: loadingURL(for: tab))
        view.navigationDelegate = self
        view.uiDelegate = self
        // WebKit's own swipe from the screen's edges: its pictures
        // of the pages, their parallax and shadow. At a first page, where it
        // can't start, the left edge is BackGestures' (Back/). The
        // swipe from anywhere on the page plays the same (SwipeAnywhere).
        view.allowsBackForwardNavigationGestures = true
        SwipeAnywhere.attach(to: view, host: swipeHost)
        // Opaque, a document with no background of its own is painted
        // white. The view's own color shows only before the
        // page has drawn: the app's ground, so a new tab in Dark doesn't flash.
        view.isOpaque = true
        view.backgroundColor = AppearanceColors.ui(0xFFFFFF, 0x121214)
        // Under and around the page (pulled past an end, the pull to
        // refresh) is the page's own background as WebKit derives it, so a
        // dark page never shows white there. A scroll view color set here
        // would pin it.
        view.underPageBackgroundColor = nil
        view.scrollView.contentInsetAdjustmentBehavior = .never
        installRefresh(on: view)
        view.accessibilityIdentifier = "page"
        // iOS's own find bar, from the page menu and ⌘F (PageFind).
        view.isFindInteractionEnabled = true
        #if DEBUG
        view.isInspectable = true
        #endif
        live[tab.id] = view
        modelAddresses[tab.id] = loadingURL(for: tab).absoluteString
        if isPrivate(tab) { privateTabs.insert(tab.id) } else { privateTabs.remove(tab.id) }
        tabsByView[ObjectIdentifier(view)] = tab.id
        applyViewport(to: view)
        readerGeneration[tab.id] = UUID()
        documents[tab.id] = UUID()
        watch(view, of: tab.id)
        publishState(tab.id)
        return view
    }

    /// A page's own controller: what pages say about themselves, and room
    /// for the blocker's lists.
    private func pageController() -> WKUserContentController {
        let controller = WKUserContentController()
        controller.add(WeakMessages(self), name: "yabPage")
        WebsiteDarkening.install(in: controller, fixturesEnabled: fixturesEnabled)
        controller.addUserScript(WKUserScript(source: Self.reporter, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        PageSignals.install(in: controller, handler: WeakMessages(self))
        return controller
    }

    @objc private func websiteDarkeningChanged() {
        let source = WebsiteDarkening.update(enabled: SettingsStore.shared.darkenWebsites)
        for view in live.values { view.evaluateJavaScript(source, in: nil, in: WebsiteDarkening.world, completionHandler: nil) }
    }

    /// The blocker's lists on or off for the site a page is heading to.
    private func fitShield(_ controller: WKUserContentController, for id: Tab.ID, url: URL?) {
        guard let shield else { return }
        let site: (host: String?, isPrivate: Bool) = siteOf?(id, url) ?? (url?.host(), privateTabs.contains(id))
        shield.fit(controller, host: site.host, isPrivate: site.isPrivate)
    }

    private func installRefresh(on view: WKWebView) {
        let control = UIRefreshControl()
        // It stands on the page's own color: light ink over a dark page
        // (matchRefresh, as that color changes).
        control.overrideUserInterfaceStyle = view.underPageBackgroundColor.isDarkGround ? .dark : .light
        control.tintColor = .label
        control.accessibilityIdentifier = "page.refresh"
        control.accessibilityLabel = "Reload page"
        control.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        view.scrollView.refreshControl = control
        // Short documents still have a top to pull from.
        view.scrollView.alwaysBounceVertical = true
    }

    @objc private func pulledToRefresh(_ control: UIRefreshControl) {
        guard let (id, view) = live.first(where: { $0.value.scrollView.refreshControl === control }),
              front == id, view.scrollView.contentOffset.y + documentTopInset(in: view) <= 1 else {
            control.endRefreshing()
            return
        }
        Haptics.play(.soft, reason: Haptics.Reason.refresh)
        if state(for: id).readerEnabled {
            Task { @MainActor [weak self, weak control] in
                guard let self, let control else { return }
                let reloaded = await self.reloadSelected(id)
                if !reloaded { control.endRefreshing() }
            }
        } else if reload(id) == nil { control.endRefreshing() }
    }

    /// The pull to refresh's spinner follows the color under the page.
    static func matchRefresh(to view: WKWebView) {
        view.scrollView.refreshControl?.overrideUserInterfaceStyle = view.underPageBackgroundColor.isDarkGround ? .dark : .light
    }

    private func endRefresh(_ id: Tab.ID, in view: WKWebView) {
        refreshNavigations[id] = nil
        view.scrollView.refreshControl?.endRefreshing()
    }

    private func navigationEnded(_ id: Tab.ID, in view: WKWebView, _ navigation: WKNavigation?) {
        Links.trace("loadEnd tab=\(id) url=\(String(describing: view.url))")
        guard let navigation, refreshNavigations[id] === navigation else { return }
        endRefresh(id, in: view)
    }

    /// Reload in the same page and store. Pictures of its old contents no
    /// longer qualify for a hold even when the address stays unchanged.
    @discardableResult
    func reload(_ id: Tab.ID) -> WKNavigation? {
        reload(id, restoring: readerScroll[id])
    }

    /// A stopped process can lose its native URL before the first commit.
    /// Keep the pending destination ahead of the document it was leaving.
    private func reloadURL(_ id: Tab.ID, in view: WKWebView) -> URL? {
        loadFailures[id]?.url ?? requestedURLs[id].flatMap(URL.init(string:)) ?? view.url
            ?? committedURLs[id] ?? modelAddresses[id].flatMap(URL.init(string:))
    }

    private func reload(_ id: Tab.ID, restoring sourceScroll: CGFloat?) -> WKNavigation? {
        guard let view = live[id], let url = reloadURL(id, in: view), allows(url), url.scheme != "about",
              readerResults[id]?.enabled != true else { return nil }
        captureNavigation(id)
        invalidateReader(id)
        painted.remove(id)
        snapshots[id] = nil
        snapshotOrigins[id] = nil
        restoreScroll[id] = sourceScroll
        pendingIndex[id] = nil
        failures[id] = nil
        requestedURLs[id] = url.absoluteString
        actionTypes[id] = .reload
        let refreshing = view.scrollView.refreshControl?.isRefreshing == true
        // Field Return or recovery can replace a pull while it is loading.
        // The old cancellation must not finish its successor's indicator.
        if refreshing { refreshNavigations[id] = nil }
        // Reload has no target when WebKit lost the native page. A fresh
        // request still belongs to this tab and its existing website store.
        let navigation = view.url == url ? (view.reload() ?? view.load(URLRequest(url: url)))
            : view.load(URLRequest(url: url))
        navigationStarted(id, in: view, navigation: navigation)
        if refreshing {
            if let navigation { refreshNavigations[id] = navigation }
            else { endRefresh(id, in: view) }
        }
        return navigation
    }

    /// Neighbors and restored pages receive the same viewport before paint.
    func setViewport(_ viewport: PageViewport, visible view: WKWebView? = nil) {
        guard !fixturesEnabled else { return }
        // A focused companion may have the same size but different chrome
        // insets. Apply them even when the cached shared layout is unchanged.
        if let view { viewport.apply(to: view) }
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        layoutSession = UUID()
        snapshotOrigins.removeAll()
        for (id, view) in live where !workspaceTabs.contains(id) || id == front { applyViewport(to: view) }
    }

    private func applyViewport(to view: WKWebView) {
        guard !fixturesEnabled, let viewport else { return }
        // Mounted pages belong to their own pane. A retiring host can
        // publish its portrait viewport after a replacement mounted this
        // page in landscape; the shared cache only sizes detached pages.
        guard !(view.superview is PageContainer) else { return }
        view.frame.size = viewport.size
        viewport.apply(to: view)
    }

    /// Where a tab's page is (its address) and how far down it is scrolled.
    private func watch(_ view: WKWebView, of id: Tab.ID) {
        urlWatch[id] = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let url = view.url else { return }
                guard let self else { return }
                // A failing navigation's old address coming back (above),
                // before or after WebKit says it failed.
                if url == self.committedURLs[id], self.provisional.contains(id) || self.loadFailures[id] != nil { return }
                if self.fixturesEnabled { self.onCommit?(id, url) }
                else if !view.isLoading, self.downloadConversions[id] == nil, self.loadFailures[id] == nil {
                    if self.finishPendingTraversal(id, in: view) { return }
                    self.noteNavigation(id, in: view, sameDocument: true)
                    self.onMetadata?(id, url, view.title ?? "")
                    self.probeReader(id)
                }
            }
        }
        loadingWatch[id] = view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                // Same-document Back changes URL while loading is still true
                // and has no Commit or Finish callback to apply its target.
                guard let self, self.live[id] === view else { return }
                if view.isLoading { self.invalidateReader(id) }
                _ = self.finishPendingTraversal(id, in: view)
                self.publishState(id)
            }
        }
        progressWatch[id] = view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publishState(id) }
        }
        backWatch[id] = view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publishState(id) }
        }
        forwardWatch[id] = view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publishState(id) }
        }
        underPageWatch[id] = view.observe(\.underPageBackgroundColor, options: [.new]) { view, _ in
            MainActor.assumeIsolated { Self.matchRefresh(to: view) }
        }
        if !fixturesEnabled {
            titleWatch[id] = view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.publishTitle(id, in: view); self?.probeReader(id) }
            }
        }
        var geometry = PageScrollGeometry(view)
        scrollWatch[id] = view.scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self, weak view] scroll, change in
            MainActor.assumeIsolated {
                guard let self, let view, self.live[id] === view, view.scrollView === scroll else { return }
                let currentGeometry = PageScrollGeometry(view)
                let layoutChanged = currentGeometry != geometry || PageViewport.isApplying(to: view)
                let oldGeometry = geometry
                geometry = currentGeometry
                // Where the page is, not where the rubber band pulled it: a
                // bounce back from past either end isn't a scroll up or down.
                let end = max(0, scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                let top = self.documentTopInset(in: view)
                let y = min(max(scroll.contentOffset.y + top, 0), end)
                // isDecelerating stays true during our inset writes. Rebase
                // the direction anchor instead of interpreting their offset
                // correction as a swipe. Geometry can also settle later.
                if layoutChanged {
                    if let old = change.oldValue {
                        let oldEnd = max(0, oldGeometry.contentSize.height + oldGeometry.contentInsets.top
                                         + oldGeometry.contentInsets.bottom - oldGeometry.size.height)
                        let oldTop = self.fixturesEnabled ? 0 : oldGeometry.viewportInsets.top
                        let oldY = min(max(old.y + oldTop, 0), oldEnd)
                        self.onScrollRebase?(id, y - oldY)
                    }
                    self.scrollSources["rebase", default: 0] += 1
                    return
                }
                guard scroll.isTracking || scroll.isDragging || scroll.isDecelerating else { return }
                self.scrollSources["document", default: 0] += 1
                self.noteClearActivity(id)
                self.onScroll?(id, y)
                self.recordScroll(id, y)
            }
        }
    }

    /// The tab now in front: its view, alive; the one before it pictured.
    @discardableResult
    func activate(_ tab: Tab) -> WKWebView {
        if let previous = front, previous != tab.id {
            suspendPageDialogs()
            picture(previous); captureNavigation(previous)
        }
        if front != tab.id { onActivity?(tab.id) }
        front = tab.id
        recent.removeAll { $0 == tab.id }
        recent.insert(tab.id, at: 0)
        let view = view(for: tab)
        trim()
        return view
    }

    /// A neighbor of the tab in front, alive behind it: paging shows its page
    /// as it slides in. It counts as just left, so the limit still holds.
    @discardableResult
    func warm(_ tab: Tab) -> WKWebView {
        let view = view(for: tab)
        if !recent.contains(tab.id) {
            recent.insert(tab.id, at: min(1, recent.count))
            trim()
        }
        return view
    }

    /// Lets go of web views past the limit, oldest first; their pictures stay.
    /// A page playing media stays alive past it: letting it go would stop
    /// what the person listens to, in Picture in Picture or with Yab away.
    /// The workspace pair survives cache pressure, including on its cover.
    var workspaceTabs: Set<Tab.ID> = []

    private func trim() {
        var excess = recent.count - Self.liveLimit
        for id in recent.reversed() where excess > 0 && id != front && !workspaceTabs.contains(id) && !playback.isPlaying(id) {
            recent.removeAll { $0 == id }
            release(id)
            excess -= 1
        }
    }

    /// Private's lock is about to close (Yab going away with Open with Face
    /// ID on): private pages stop playing and leave Picture in Picture, so
    /// nothing private goes on outside the lock.
    func pausePrivateMedia() {
        for (id, view) in live where privateTabs.contains(id) {
            view.closeAllMediaPresentations(completionHandler: nil)
            view.pauseAllMediaPlayback(completionHandler: nil)
            playback.set(id, playing: false)
        }
    }

    private func release(_ id: Tab.ID) {
        guard let view = live[id] else { return }
        // A transition can still retain the view after it leaves the pool.
        view.closeAllMediaPresentations(completionHandler: nil)
        view.pauseAllMediaPlayback(completionHandler: nil)
        popupOpeners[id] = nil; windowFiles[id] = nil; firstWindowLoads[id] = nil
        downloadOrigins[id] = nil; downloadConversions[id] = nil
        if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
        activeNavigations[id] = nil; documents[id] = nil; committedURLs[id] = nil; loadFailures[id] = nil
        provisional.remove(id)
        endRefresh(id, in: view)
        view.scrollView.refreshControl?.removeTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        view.scrollView.refreshControl = nil
        captureNavigation(id)
        interactions[id] = readerScroll[id] == nil ? view.interactionState : nil
        interactionOrigins[id] = ObjectIdentifier(view.configuration.websiteDataStore)
        live[id] = nil
        scrollWatch.removeValue(forKey: id)?.invalidate()
        urlWatch.removeValue(forKey: id)?.invalidate()
        loadingWatch.removeValue(forKey: id)?.invalidate()
        titleWatch.removeValue(forKey: id)?.invalidate()
        progressWatch.removeValue(forKey: id)?.invalidate()
        backWatch.removeValue(forKey: id)?.invalidate()
        forwardWatch.removeValue(forKey: id)?.invalidate()
        underPageWatch.removeValue(forKey: id)?.invalidate()
        readerProbes.removeValue(forKey: id)?.cancel()
        readerResults[id] = nil
        readerDocuments[id] = nil
        readerGeneration[id] = nil
        readerScroll[id] = nil
        readerActions.remove(id)
        playback.forget(id)
        pageStates[id] = nil
        onState?(id, .idle)
        tabsByView.removeValue(forKey: ObjectIdentifier(view))
        painted.remove(id)
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        log.debug("released the web view of \(id, privacy: .public)")
    }

    /// Forgets a closed tab altogether.
    func forget(_ id: Tab.ID) {
        release(id)
        // A card closed while it warmed up: its wait ends now.
        if borrowed.removeValue(forKey: id) != nil { resume(id) }
        recent.removeAll { $0 == id }
        snapshots[id] = nil
        snapshotOrigins[id] = nil
        navigation[id] = nil
        interactions[id] = nil
        interactionOrigins[id] = nil
        restoreScroll[id] = nil
        pendingIndex[id] = nil
        modelAddresses[id] = nil
        requestedURLs[id] = nil
        actionTypes[id] = nil
        initialLoads.remove(id)
        privateTabs.remove(id)
        clearActivity[id] = nil
        touches[id] = nil
        openedWindows[id] = nil
        failures[id] = nil
        recoveries[id] = nil
        stoppedAway.remove(id)
        scrollPublications.removeValue(forKey: id)?.cancel()
    }

    /// Another page in a tab's own web view, so Back returns to the one
    /// before. Nothing when the tab has no live view: it loads its page
    /// when it is in front again.
    /// An extension's page and the web need views of different
    /// configurations: going from one to the other makes a new view.
    private func changesKind(_ view: WKWebView, to url: URL) -> Bool {
        guard !fixturesEnabled, let shown = view.url else { return false }
        return ExtensionHost.isExtensionPage(shown) != ExtensionHost.isExtensionPage(url)
    }

    func load(_ id: Tab.ID, _ url: URL) {
        guard let view = live[id] else { return }
        // The next activate makes the view of the other kind (view(for:)).
        if changesKind(view, to: url) { release(id); interactions[id] = nil; return }
        painted.remove(id)
        snapshots[id] = nil
        snapshotOrigins[id] = nil
        captureNavigation(id)
        invalidateReader(id)
        restoreScroll[id] = nil
        failures[id] = nil
        requestedURLs[id] = url.absoluteString
        openedWindows[id] = nil
        let token = view.load(URLRequest(url: url))
        navigationStarted(id, in: view, navigation: token)
    }

    /// A web view made elsewhere (Peek's) becomes a tab's, page and all: no
    /// reload, the scroll and what was typed stay. It says what pages say
    /// about themselves from now on, and the page takes back its own top.
    @discardableResult
    func adopt(_ view: WKWebView, for tab: Tab) -> Bool {
        // Configuration is fixed at creation. A differently signed-in page
        // must reload in its destination, never be relabeled Public or Private.
        guard matchesStore(view, for: tab) else { return false }
        if let old = live[tab.id], old !== view { release(tab.id) }
        // Peek creates an independent controller before its load. Replacing
        // its scripts here cannot remove scripts from another pooled page.
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: "yabPage")
        controller.add(WeakMessages(self), name: "yabPage")
        controller.addUserScript(WKUserScript(source: Self.reporter, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        PageSignals.install(in: controller, handler: WeakMessages(self))
        fitShield(controller, for: tab.id, url: view.url)
        view.evaluateJavaScript("document.documentElement.style.removeProperty('--top');" + Self.reporter, completionHandler: nil)
        view.evaluateJavaScript(PageSignals.script, in: nil, in: PageSignals.world, completionHandler: nil)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        SwipeAnywhere.attach(to: view, host: swipeHost)
        view.underPageBackgroundColor = nil
        installRefresh(on: view)
        view.accessibilityIdentifier = "page"
        live[tab.id] = view
        modelAddresses[tab.id] = loadingURL(for: tab).absoluteString
        if isPrivate(tab) { privateTabs.insert(tab.id) } else { privateTabs.remove(tab.id) }
        tabsByView[ObjectIdentifier(view)] = tab.id
        applyViewport(to: view)
        if !view.isLoading { painted.insert(tab.id); committedURLs[tab.id] = view.url }
        readerGeneration[tab.id] = UUID()
        documents[tab.id] = UUID()
        watch(view, of: tab.id)
        publishState(tab.id)
        if !view.isLoading { probeReader(tab.id) }
        noteNavigation(tab.id, in: view)
        if !view.isLoading { resume(tab.id) }
        return true
    }

    /// The last private tab closed: the store its pages shared goes with
    /// everything in it, and the next private tab starts on a new one.
    func renewPrivateStore() {
        if javaScriptDialog?.privateSession != nil || httpAuthentication?.privateSession != nil { suspendPageDialogs() }
        // Its files go with it, the ones on their way too.
        downloads.forgetPrivate()
        for (id, origin) in Array(snapshotOrigins) where origin.isPrivate {
            snapshots[id] = nil
            snapshotOrigins[id] = nil
        }
        privateSession = UUID()
        let gone = privateConfiguration.websiteDataStore
        gone.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        let fresh = configuration.copy() as! WKWebViewConfiguration
        fresh.websiteDataStore = .nonPersistent()
        fresh.userContentController = configuration.userContentController
        privateConfiguration = fresh
        log.debug("a new private store")
    }

    /// Clear History: each ordinary tab's Back and Forward, down to the page
    /// it shows. A live page lets its web view go (WebKit keeps a list of
    /// its own) and comes back on that page, with nothing before or after
    /// it. Private tabs are memory only and keep theirs. True when one went.
    @discardableResult
    func clearHistory() -> Bool {
        var released = false
        for id in Array(live.keys) where !privateTabs.contains(id) {
            release(id)
            recent.removeAll { $0 == id }
            released = true
        }
        for (id, var state) in navigation where !privateTabs.contains(id) && state.entries.indices.contains(state.index) {
            state.entries = [state.entries[state.index]]
            state.index = 0
            state.interactionData = nil
            navigation[id] = state
            interactions[id] = nil
            interactionOrigins[id] = nil
            pendingIndex[id] = nil
            publishNavigation(id, state)
        }
        return released
    }

    /// The store private pages use now, for tests.
    var privateStore: WKWebsiteDataStore { privateConfiguration.websiteDataStore }

    /// A picture of a tab's page as it is now, for paging, the spaces' holds
    /// and the tab stack; `done` is told the picture, or nil when there is none.
    func picture(_ id: Tab.ID, then done: ((UIImage?) -> Void)? = nil) {
        guard let view = live[id], view.window != nil, !view.isLoading, painted.contains(id),
              let address = view.url else { done?(nil); return }
        let shy = privateTabs.contains(id)
        let origin = SnapshotOrigin(address: address.absoluteString, isPrivate: shy,
            store: ObjectIdentifier(view.configuration.websiteDataStore), privateSession: shy ? privateSession : nil,
            viewport: viewport, pageSize: view.bounds.size, contentTop: view.obscuredContentInsets.top, layoutSession: layoutSession)
        let document = documents[id]
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        view.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                // A closed tab must never regain a picture from a pending capture.
                guard let self, self.live[id] === view, !view.isLoading, view.url == address, self.documents[id] == document,
                      self.layoutSession == origin.layoutSession, self.viewport == origin.viewport,
                      view.bounds.size == origin.pageSize, view.obscuredContentInsets.top == origin.contentTop,
                      !shy || self.privateSession == origin.privateSession else { done?(nil); return }
                if let image {
                    self.snapshots[id] = image
                    self.snapshotOrigins[id] = origin
                    self.onPicture?(id)
                }
                done?(image)
            }
        }
    }

    /// A card's picture of a tab's page (Tabs/TabPictures): `rect` of its
    /// view drawn `width` points wide, for the caller to keep, not among the
    /// pool's own pictures. `afterScreenUpdates` waits for the next frame on
    /// screen (a page just drawn, or loaded out of sight); without it, what
    /// shows now (a page about to leave the screen, Yab going away).
    /// `unpainted` also takes a page that committed but hasn't said it drew
    /// (the warm-up's slow pages). Nil when there is no such page on a
    /// window, or it changed meanwhile.
    func cardPicture(_ id: Tab.ID, rect: CGRect, width: CGFloat, afterScreenUpdates: Bool, unpainted: Bool = false,
                     then done: @escaping (UIImage?) -> Void) {
        guard let view = live[id], view.window != nil, let address = view.url, address.scheme?.lowercased() != "about",
              loadFailures[id] == nil, painted.contains(id) || (unpainted && committedURLs[id] != nil),
              rect.width > 0, rect.height > 0, width > 0 else { done(nil); return }
        let shy = privateTabs.contains(id)
        let session = privateSession
        let document = documents[id]
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: Double(width))
        config.afterScreenUpdates = afterScreenUpdates
        view.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                // A closed tab, another page or a new private session: no picture.
                guard let self, self.live[id] === view, view.url == address, self.documents[id] == document,
                      !shy || self.privateSession == session else { done(nil); return }
                done(image)
            }
        }
    }

    /// A tab's page alive out of sight, to be pictured for its card (All
    /// Tabs' warm-up): made and restored as any is (its space's store, the
    /// blocker's lists, its saved place), its media held, counted among the
    /// live views. Past the limit the oldest other one goes, never the tab
    /// in front, the one used just before it, a page playing or one shown.
    /// Nil when there is no room, or the tab's live view is shown elsewhere.
    func borrow(_ tab: Tab) -> WKWebView? {
        if let view = live[tab.id] {
            guard front != tab.id, view.superview == nil else { return nil }
            if borrowed[tab.id] == nil { borrowed[tab.id] = false }
            view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            return view
        }
        if live.count >= Self.liveLimit {
            let previous = recent.first { $0 != front }
            if let oldest = recent.reversed().first(where: { id in
                id != front && id != previous && !workspaceTabs.contains(id) && !playback.isPlaying(id) && borrowed[id] == nil && live[id]?.superview == nil
            }) {
                recent.removeAll { $0 == oldest }
                release(oldest)
            }
        }
        guard live.count < Self.liveLimit else { return nil }
        borrowed[tab.id] = true
        let view = view(for: tab)
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        return view
    }

    /// The warm-up is done with a tab's page: one made for it goes, unless
    /// it came in front meanwhile (a card tapped while it warmed up) or was
    /// asked for otherwise; `keep` keeps it alive as the tab just left.
    func giveBack(_ id: Tab.ID, keep: Bool = false) {
        guard let made = borrowed.removeValue(forKey: id) else { return }
        resume(id)
        let stays = !made || keep || front == id || workspaceTabs.contains(id) || recent.contains(id)
        guard stays, let view = live[id] else { release(id); return }
        view.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        if made && !recent.contains(id) {
            recent.insert(id, at: min(1, recent.count))
            trim()
        }
    }

    func isBorrowed(_ id: Tab.ID) -> Bool { borrowed[id] != nil }
    /// How many web views are alive now (tests and the warm-up's measures).
    var liveCount: Int { live.count }

    /// Pictures go: private tabs' as Private locks, or every ordinary tab's
    /// (Clear History and Website Data).
    func forgetPictures(private shy: Bool) {
        for (id, origin) in Array(snapshotOrigins) where origin.isPrivate == shy {
            snapshots[id] = nil
            snapshotOrigins[id] = nil
        }
    }

    func isLive(_ id: Tab.ID) -> Bool { live[id] != nil }
    /// The tab's live web view, if it has one now.
    func liveView(_ id: Tab.ID) -> WKWebView? { live[id] }
    /// The tab a web view shows.
    func tab(of view: WKWebView) -> Tab.ID? { tabsByView[ObjectIdentifier(view)] }

    func represents(_ tab: Tab) -> Bool {
        guard front == tab.id, let view = live[tab.id] else { return false }
        guard matchesStore(view, for: tab) else { return false }
        let address = loadingURL(for: tab).absoluteString
        return view.url?.absoluteString == address || requestedURLs[tab.id] == address
    }

    func state(for id: Tab.ID) -> PageState { live[id] == nil ? .idle : (pageStates[id] ?? .idle) }

    private func publishState(_ id: Tab.ID) {
        guard let view = live[id] else { return }
        let history = navigation[id]
        let reader = readerResults[id]
        let state = PageState(isLoading: view.isLoading, progress: min(1, max(0, view.estimatedProgress)),
            canGoBack: reader?.enabled == true || view.canGoBack || (history?.index ?? 0) > 0
                || loadFailures[id]?.previousURL != nil,
            canGoForward: view.canGoForward || ((history?.index ?? 0) + 1 < (history?.entries.count ?? 0)),
            readerAvailable: !view.isLoading && loadFailures[id] == nil && reader?.available == true,
            readerEnabled: !view.isLoading && loadFailures[id] == nil && reader?.enabled == true,
            failure: loadFailures[id])
        guard pageStates[id] != state else { return }
        pageStates[id] = state
        onState?(id, state)
    }

    private func invalidateReader(_ id: Tab.ID) {
        readerProbes.removeValue(forKey: id)?.cancel()
        readerGeneration[id] = UUID()
        readerDocuments[id] = nil
        readerResults[id] = nil
        publishState(id)
    }

    private func readerScript(_ script: String, arguments: [String: Any] = [:], in view: WKWebView) async throws -> Any {
        // The completion overload returns JS values on both SDKs. An untyped
        // async call can choose the SDK's Void overload instead.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: PageReader.world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func probeReader(_ id: Tab.ID) {
        guard let view = live[id], !view.isLoading, loadFailures[id] == nil, let url = view.url,
              url.scheme != "about", readerActions.contains(id) == false else { return }
        readerProbes.removeValue(forKey: id)?.cancel()
        let generation = readerGeneration[id]
        readerProbes[id] = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            let result = try? await self.readerScript(PageReader.probe, in: view)
            guard !Task.isCancelled, self.live[id] === view, !view.isLoading,
                  view.url == url, self.readerGeneration[id] == generation else { return }
            if let result = result as? [String: Any], let available = result["available"] as? Bool, let enabled = result["enabled"] as? Bool, let document = result["documentID"] as? String {
                self.readerResults[id] = (available, enabled)
                self.readerDocuments[id] = document
                if enabled, self.readerScroll[id] == nil, let y = result["originalY"] as? Double {
                    self.readerScroll[id] = CGFloat(y) * view.scrollView.zoomScale
                } else if !enabled { self.readerScroll[id] = nil }
            } else {
                self.readerResults[id] = nil
                self.readerDocuments[id] = nil
                self.readerScroll[id] = nil
            }
            self.readerProbes[id] = nil
            self.publishState(id)
        }
    }

    /// Reloading Reader first restores its original document and scroll.
    @discardableResult
    func reloadSelected(_ id: Tab.ID) async -> Bool {
        if let failure = loadFailures[id] { return retryFailure(id, expected: failure.id) }
        // A page whose process stopped has lost its native URL: Reload loads
        // the address it showed (#350, Refresh did nothing).
        guard front == id, let view = live[id] else { return false }
        guard let url = view.url else { return reload(id) != nil }
        let generation = readerGeneration[id]
        // Leaving Reader consumes its saved offset. Carry it through the
        // reload so an address fragment cannot replace the source position.
        let sourceScroll = readerScroll[id]
        if state(for: id).readerEnabled {
            guard await setReader(enabled: false, for: id) else { return false }
        }
        guard front == id, live[id] === view, view.url == url, readerGeneration[id] == generation else { return false }
        return reload(id, restoring: sourceScroll) != nil
    }

    /// Stop only the selected page, including the pull-to-refresh indicator.
    func stop(_ id: Tab.ID) {
        guard front == id, let view = live[id], view.isLoading else { return }
        if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
        if let previous = activeNavigations.removeValue(forKey: id) { retiredNavigations.add(previous) }
        view.stopLoading()
        endRefresh(id, in: view)
        requestedURLs[id] = nil
        pendingIndex[id] = nil
        restoreScroll[id] = nil
        publishState(id)
        probeReader(id)
    }

    /// Reading changes the DOM in this same view, never its URL or store.
    @discardableResult
    func setReader(enabled: Bool, for id: Tab.ID) async -> Bool {
        guard front == id, let view = live[id], !view.isLoading, loadFailures[id] == nil, let url = view.url,
              url.scheme != "about", let document = readerDocuments[id], !readerActions.contains(id) else { return false }
        if enabled, readerResults[id]?.enabled == true { return true }
        readerActions.insert(id)
        readerProbes.removeValue(forKey: id)?.cancel()
        let generation = readerGeneration[id]
        let scroll = max(0, view.scrollView.contentOffset.y + documentTopInset(in: view))
        defer { readerActions.remove(id) }
        var arguments: [String: Any] = ["expectedURL": url.absoluteString, "expectedDocument": document]
        if enabled { arguments.merge(PageReader.arguments(ReaderStyle.shared.prefs)) { $1 } }
        let result = try? await readerScript(enabled ? PageReader.enter : PageReader.leave, arguments: arguments, in: view)
        guard live[id] === view, !view.isLoading, view.url == url, readerGeneration[id] == generation else { return false }
        let changed = result as? Bool == true
        if changed {
            if enabled { readerScroll[id] = scroll }
            else {
                if let y = readerScroll[id] {
                    // The JS document is laid out before this callback, and
                    // the source offset is explicit before any checkpoint.
                    view.scrollView.setContentOffset(CGPoint(x: view.scrollView.contentOffset.x,
                        y: y - documentTopInset(in: view)), animated: false)
                }
                readerScroll[id] = nil
            }
            readerResults[id] = (true, enabled)
            snapshots[id] = nil
            snapshotOrigins[id] = nil
            publishState(id)
        } else if enabled {
            readerResults[id] = (false, false)
            publishState(id)
        }
        return changed
    }

    /// A new reading theme on every page being read, at once.
    @objc private func restyleReaders() {
        let arguments = PageReader.arguments(ReaderStyle.shared.prefs)
        for (id, view) in live where readerResults[id]?.enabled == true {
            view.callAsyncJavaScript(PageReader.restyle, arguments: arguments, in: nil, in: PageReader.world) { [weak self, weak view] _ in
                guard let self, let view, self.live[id] === view else { return }
                // The ground under the page follows the article's new one.
                Self.matchRefresh(to: view)
                self.snapshots[id] = nil
                self.snapshotOrigins[id] = nil
            }
        }
    }

    /// The first Back leaves Reader. The next follows native or saved history.
    func back(_ id: Tab.ID) async -> Bool {
        guard front == id else { return false }
        if state(for: id).readerEnabled { return await setReader(enabled: false, for: id) }
        if let failure = loadFailures[id], let view = live[id], let url = failure.previousURL {
            // A provisional failure has not added a Back item. Keep its
            // intact previous document when WebKit still represents it.
            if view.url != url { load(id, url); return true }
            loadFailures[id] = nil; failures[id] = nil
            requestedURLs[id] = url.absoluteString
            onCommit?(id, url)
            // The tab said the address that failed: it says this page again.
            if !fixturesEnabled { onMetadata?(id, url, view.title ?? "") }
            publishState(id); didPaint(id); probeReader(id)
            return true
        }
        return goBack(id)
    }

    /// How a tab's page is, in words, for the named states' notes.
    func describe(_ id: Tab.ID) -> String {
        guard let view = live[id] else { return "no web view" }
        return "url=\(view.url?.absoluteString ?? "none") loading=\(view.isLoading) progress=\(view.estimatedProgress) "
            + "window=\(view.window != nil) painted=\(painted.contains(id)) frame=\(view.frame.size) error=\(failures[id] ?? "none")"
    }

    /// Waits until a tab's page has loaded and drawn its first frames, or
    /// `timeout` has passed, whichever is first.
    func waitUntilPainted(_ id: Tab.ID, timeout: Duration = .seconds(10)) async {
        if painted.contains(id) { return }
        let token = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            paintWaiters[id, default: []].append((token, waiter))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id, only: token)
            }
        }
    }

    /// Lets waiters go: all of a tab's, or the one whose time ran out.
    private func resume(_ id: Tab.ID, only token: UUID? = nil) {
        guard var waiters = paintWaiters[id] else { return }
        let going = waiters.filter { token == nil || $0.token == token }
        waiters.removeAll { token == nil || $0.token == token }
        paintWaiters[id] = waiters.isEmpty ? nil : waiters
        for entry in going { entry.waiter.resume() }
    }

    private func waitForPaint(_ id: Tab.ID, in view: WKWebView) {
        let finishedURL = view.url
        let document = documents[id]
        let savedY = restoreScroll[id]
        let arguments: [String: Any] = ["savedY": savedY.map { Double($0) as Any } ?? NSNull()]
        // A native offset write only schedules WebKit's visible-rect update.
        // Restore in the document after layout, before declaring it painted.
        let script = """
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        if (savedY !== null) {
          const scale = window.visualViewport ? window.visualViewport.scale : 1;
          window.scrollTo({ left: 0, top: savedY / (scale || 1), behavior: 'instant' });
          await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        }
        return 1;
        """
        view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self, weak view] result in
            MainActor.assumeIsolated {
                guard let self, let view, self.live[id] === view,
                      !view.isLoading, view.url == finishedURL, self.documents[id] == document else { return }
                switch result {
                case .success:
                    self.publishTitle(id, in: view)
                    if let y = self.restoreScroll.removeValue(forKey: id) {
                        view.scrollView.setContentOffset(CGPoint(x: 0, y: y - self.documentTopInset(in: view)), animated: false)
                    }
                    self.didPaint(id)
                    self.probeReader(id)
                case let .failure(error):
                    self.failures[id] = error.localizedDescription
                    self.resume(id)
                }
            }
        }
    }

    struct ClearProof {
        let id: Tab.ID
        let view: WKWebView
        let address: URL
        let document: UUID
        let store: ObjectIdentifier
        let activity: UInt64
        let session: UUID
        let observed: TimeInterval
    }
    struct ClearMemory {
        let navigation: BrowserNavigation?
        let interaction: Any?
        let store: ObjectIdentifier
        let session: UUID
        let isPrivate: Bool
    }
    private func noteClearActivity(_ id: Tab.ID) {
        clearActivity[id, default: 0] &+= 1
        if front == id { onActivity?(id) }
    }
    private var clearHasNativeCover: Bool {
        if pageInteractionHost?.window?.rootViewController?.presentedViewController != nil { return true }
        return live.values.contains { $0.window?.rootViewController?.presentedViewController != nil }
    }
    /// Only an existing painted inactive view, with native media/capture and
    /// form state observed. Timeout/failure/cold documents never qualify.
    func clearProof(for tab: Tab) async -> ClearProof? {
        guard !clearHasNativeCover, let view = live[tab.id], front != tab.id, painted.contains(tab.id),
              let address = view.url, address == loadingURL(for: tab),
              let document = documents[tab.id], loadFailures[tab.id] == nil,
              javaScriptDialog?.tab != tab.id, httpAuthentication?.tab != tab.id,
              downloadConversions[tab.id] == nil, matchesStore(view, for: tab) else { return nil }
        let proof = ClearProof(id: tab.id, view: view, address: address, document: document,
                               store: ObjectIdentifier(view.configuration.websiteDataStore),
                               activity: clearActivity[tab.id, default: 0], session: privateSession,
                               observed: ProcessInfo.processInfo.systemUptime)
        guard await PageClearSafety.inspect(view), acceptsClearProof(proof) else { return nil }
        return proof
    }
    func acceptsClearProof(_ proof: ClearProof) -> Bool {
        guard !clearHasNativeCover, live[proof.id] === proof.view, front != proof.id, painted.contains(proof.id),
              documents[proof.id] == proof.document, proof.view.url == proof.address,
              ObjectIdentifier(proof.view.configuration.websiteDataStore) == proof.store,
              privateSession == proof.session, clearActivity[proof.id, default: 0] == proof.activity,
              ProcessInfo.processInfo.systemUptime - proof.observed < 1,
              !proof.view.isLoading, proof.view.cameraCaptureState == .none, proof.view.microphoneCaptureState == .none,
              javaScriptDialog?.tab != proof.id, httpAuthentication?.tab != proof.id,
              downloadConversions[proof.id] == nil, loadFailures[proof.id] == nil else { return false }
        return true
    }
    func clearMemory(for id: Tab.ID) -> ClearMemory? {
        guard let view = live[id] else { return nil }
        captureNavigation(id)
        return ClearMemory(navigation: navigation[id], interaction: view.interactionState,
                           store: ObjectIdentifier(view.configuration.websiteDataStore), session: privateSession,
                           isPrivate: privateTabs.contains(id))
    }
    func restoreClearMemory(_ memory: ClearMemory, for id: Tab.ID) {
        // Store identity and Private session are checked again by view(for:).
        guard !memory.isPrivate || privateSession == memory.session else { return }
        navigation[id] = memory.navigation
        interactions[id] = memory.interaction
        interactionOrigins[id] = memory.store
        if memory.isPrivate { privateTabs.insert(id) }
        else if let navigation = memory.navigation { publishNavigation(id, navigation) }
    }

    /// Checkpoint before backgrounding: ordinary tabs keep navigation and scroll.
    func checkpoint() {
        for id in Array(live.keys) { captureNavigation(id) }
    }

    func navigationState(for id: Tab.ID) -> BrowserNavigation? {
        captureNavigation(id)
        return navigation[id] ?? navigationForTab?(id)
    }

    private func publishNavigation(_ id: Tab.ID, _ state: BrowserNavigation) {
        guard !privateTabs.contains(id) else { return }
        onNavigation?(id, state)
    }

    private func recordScroll(_ id: Tab.ID, _ y: CGFloat) {
        guard readerScroll[id] == nil else { return }
        guard var state = navigation[id], state.entries.indices.contains(state.index) else { return }
        state.entries[state.index].scrollY = Double(max(0, y))
        navigation[id] = state
        scrollPublications[id]?.cancel()
        scrollPublications[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let state = self.navigation[id] else { return }
            self.publishNavigation(id, state)
            self.scrollPublications[id] = nil
        }
    }

    /// Saved scroll is document space, independent of the status bar inset.
    private func documentTopInset(in view: WKWebView?) -> CGFloat {
        fixturesEnabled ? 0 : (view?.obscuredContentInsets.top ?? 0)
    }

    private func captureNavigation(_ id: Tab.ID) {
        guard let view = live[id], var state = navigation[id], state.entries.indices.contains(state.index) else { return }
        scrollPublications.removeValue(forKey: id)?.cancel()
        // A checkpoint during restoration must keep its target, not the
        // new view's temporary top-of-page position.
        state.entries[state.index].scrollY = Double(readerScroll[id] ?? restoreScroll[id] ?? max(0, view.scrollView.contentOffset.y + documentTopInset(in: view)))
        // WebKit returns a serializable data state on supported engines. Any
        // other representation stays in memory; the URL/scroll timeline is portable.
        state.interactionData = readerScroll[id] == nil ? view.interactionState as? Data : nil
        state.websiteStoreID = view.configuration.websiteDataStore.identifier
        navigation[id] = state
        publishNavigation(id, state)
    }

    /// Titles can arrive after Finish or change without a navigation.
    private func publishTitle(_ id: Tab.ID, in view: WKWebView) {
        guard !fixturesEnabled, live[id] === view, !view.isLoading,
              let url = view.url, let title = view.title, !title.isEmpty,
              var state = navigation[id], state.entries.indices.contains(state.index),
              state.entries[state.index].url == url.absoluteString else { return }
        if state.entries[state.index].title != title {
            state.entries[state.index].title = title
            navigation[id] = state
            publishNavigation(id, state)
        }
        onMetadata?(id, url, title)
    }

    @discardableResult
    private func finishPendingTraversal(_ id: Tab.ID, in view: WKWebView) -> Bool {
        guard !fixturesEnabled, live[id] === view, !view.isLoading, let url = view.url,
              let target = pendingIndex[id], let state = navigation[id], state.entries.indices.contains(target),
              state.entries[target].url == url.absoluteString else { return false }
        noteNavigation(id, in: view, sameDocument: true)
        requestedURLs[id] = nil
        actionTypes[id] = nil
        onMetadata?(id, url, view.title ?? "")
        waitForPaint(id, in: view)
        return true
    }

    private func noteNavigation(_ id: Tab.ID, in view: WKWebView, committed: Bool = false, finishing: Bool = false,
                                sameDocument: Bool = false) {
        guard let url = view.url else { return }
        // Fragment and History API changes are already qualified by the native
        // URL/traversal observers. Keep that exact committed source for downloads.
        if sameDocument { committedURLs[id] = url }
        var state = navigation[id] ?? BrowserNavigation(entries: [], index: 0, websiteStoreID: view.configuration.websiteDataStore.identifier)
        let address = url.absoluteString
        let title = view.title ?? ""
        if committed, initialLoads.remove(id) != nil, state.entries.indices.contains(state.index) {
            // A first-load redirect replaces the requested URL. It does not
            // create a phantom page for Back before the tab's first document.
        } else if finishing, state.entries.indices.contains(state.index) {
            // Commit made this entry; Finish only fills its final URL/title.
        } else if let target = pendingIndex.removeValue(forKey: id), state.entries.indices.contains(target) {
            state.index = target
        } else if actionTypes[id] == .backForward, !state.entries.isEmpty {
            let matches = state.entries.indices.filter { state.entries[$0].url == address }
            if let target = matches.min(by: { abs($0 - state.index) < abs($1 - state.index) }) { state.index = target }
        } else if sameDocument, state.entries.indices.contains(state.index),
                  state.entries[state.index].url != address,
                  view.backForwardList.backItem?.url.absoluteString != state.entries[state.index].url {
            // replaceState changes this entry. pushState puts its old URL in
            // WebKit's back item and follows the append path below.
        } else if !state.entries.indices.contains(state.index) || state.entries[state.index].url != address {
            state.entries = Array(state.entries.prefix(state.index + 1))
            state.entries.append(.init(url: address, title: title))
            state.index = state.entries.count - 1
        }
        if state.entries.indices.contains(state.index) {
            state.entries[state.index].url = address
            if !title.isEmpty { state.entries[state.index].title = title }
        }
        navigation[id] = state
        publishNavigation(id, state)
        publishState(id)
    }

    /// Native history retains forms during eviction. The saved timeline
    /// still supports Back and Forward after a launch without a native state.
    func goBack(_ id: Tab.ID) -> Bool { step(id, by: -1) }
    func goForward(_ id: Tab.ID) -> Bool { step(id, by: 1) }

    /// Several pages back or forward at once: a page chosen in ‹'s menu.
    @discardableResult
    func go(_ id: Tab.ID, by delta: Int) -> Bool {
        guard front == id, delta != 0 else { return false }
        return step(id, by: delta)
    }

    /// One page Back passes on the way, `steps` back from the one shown.
    struct BackItem: Equatable, Sendable {
        let steps: Int
        let url: URL
        let title: String
    }

    /// The tab's way back, the nearest page first, from its own timeline
    /// (the one Back follows and the profile keeps).
    func backList(_ id: Tab.ID) -> [BackItem] {
        guard let state = navigation[id] ?? navigationForTab?(id),
              state.entries.indices.contains(state.index) else { return [] }
        return (0..<state.index).reversed().compactMap { i in
            URL(string: state.entries[i].url).map { BackItem(steps: state.index - i, url: $0, title: state.entries[i].title) }
        }
    }

    /// What a closed tab needs to come back as it was (Undo): its timeline,
    /// and the native session WebKit keeps for it, live or let go.
    func closedMemory(for tab: Tab) -> ClearMemory? {
        if let memory = clearMemory(for: tab.id) { return memory }
        guard let state = navigation[tab.id] ?? navigationForTab?(tab.id) else { return nil }
        return ClearMemory(navigation: state, interaction: interactions[tab.id],
                           store: interactionOrigins[tab.id] ?? ObjectIdentifier(expectedStore(for: tab)),
                           session: privateSession, isPrivate: isPrivate(tab))
    }

    private func step(_ id: Tab.ID, by delta: Int) -> Bool {
        guard let view = live[id] else { return false }
        captureNavigation(id)
        guard let state = navigation[id], state.entries.indices.contains(state.index + delta),
              let url = URL(string: state.entries[state.index + delta].url) else {
            if delta < 0, view.canGoBack { navigationStarted(id, in: view, navigation: view.goBack()); return true }
            if delta > 0, view.canGoForward { navigationStarted(id, in: view, navigation: view.goForward()); return true }
            return false
        }
        let target = state.index + delta
        invalidateReader(id)
        painted.remove(id)
        failures[id] = nil
        pendingIndex[id] = target
        requestedURLs[id] = url.absoluteString
        restoreScroll[id] = CGFloat(state.entries[target].scrollY)
        let item = view.backForwardList.item(at: delta)
        let token: WKNavigation?
        if let item, item.url.absoluteString == url.absoluteString { token = view.go(to: item) }
        else { token = view.load(URLRequest(url: url)) }
        navigationStarted(id, in: view, navigation: token)
        return true
    }

    func allows(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if fixturesEnabled { return [PageSchemeHandler.scheme, "about", "data"].contains(scheme) }
        // And an extension's own pages, which its engine serves.
        return ["http", "https", "about", "data"].contains(scheme) || ExtensionHost.isExtensionPage(url)
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard let view = message.webView, let id = tabsByView[ObjectIdentifier(view)],
              let body = message.body as? [String: Any] else { return }
        if message.name == PageSignals.handler {
            // Registered in Yab's own world only: no page script posts here.
            guard message.world.name == PageSignals.world.name else { return }
            if body["tap"] as? Bool == true { touches[id] = ProcessInfo.processInfo.systemUptime }
            if body["swipeHold"] as? Bool == true { SwipeAnywhere.of(view)?.held = true }
            // The store's Add to Yab, pressed: added after the person's yes.
            if !fixturesEnabled, ExtensionHost.isAvailable, body["addExtension"] is String, canInteract(id, in: view),
               let store = ExtensionPackage.storeID(of: view.url) {
                ExtensionHost.shared.offer(store)
            }
            // A page out of sight for its card's picture never plays (its media is held).
            if body["media"] as? Bool == true, borrowed[id] == nil {
                playback.check(id, in: view) { [weak self, weak view] in view != nil && self?.live[id] === view }
            }
            return
        }
        if body["activity"] as? Bool == true { noteClearActivity(id) }
        if let dark = body["dark"] as? Bool { onReport?(id, PageReport(dark: dark)) }
        if let y = body["scroll"] as? Double {
            // A page's inner scroller re-lays itself out when our insets
            // move (a clamped scrollTop): that is not a swipe, and folding
            // on it moves the insets again.
            if PageViewport.recentlyWrote(to: view) {
                scrollSources["innerIgnored", default: 0] += 1
                onScrollSettle?(id, CGFloat(y))
            } else {
                scrollSources["inner", default: 0] += 1
                onScroll?(id, CGFloat(y))
            }
            recordScroll(id, CGFloat(y))
        }
    }

    private func didPaint(_ id: Tab.ID) {
        painted.insert(id)
        resume(id)
        onPainted?(id)
    }

    /// What every page tells the app once it has loaded: whether it is dark
    /// (the prototype's data-dark, else its background), and how far an
    /// inner scroller is down (pages that scroll an element, not the document).
    private static let reporter = """
    (function () {
      if (typeof globalThis.__yabPageThemeReport === 'function') { globalThis.__yabPageThemeReport(); return; }
      function lum(c) {
        var m = /rgba?\\(([^)]+)\\)/.exec(c || ''); if (!m) return null;
        var p = m[1].split(',').map(parseFloat); if (p.length > 3 && p[3] === 0) return null;
        return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255;
      }
      function dark() {
        if (document.querySelector('[data-dark]')) return true;
        var probe = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
        for (var n = probe; n; n = n.parentElement) {
          var l = lum(getComputedStyle(n).backgroundColor);
          if (l !== null) return l < 0.4;
        }
        var b = lum(getComputedStyle(document.body).backgroundColor);
        if (b === null) b = lum(getComputedStyle(document.documentElement).backgroundColor);
        return b !== null && b < 0.4;
      }
      var post = function (m) { try { webkit.messageHandlers.yabPage.postMessage(m); } catch (e) {} };
      var lastDark, pending = false;
      function report() {
        pending = false;
        var value = dark();
        if (value !== lastDark) { lastDark = value; post({ dark: value }); }
      }
      function schedule() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(report);
      }
      globalThis.__yabPageThemeReport = schedule;
      // Styles can arrive after the first paint, including Dark Reader's
      // sheets and a site's own theme switch. Read once per frame, write no DOM.
      new MutationObserver(schedule).observe(document.documentElement, {
        subtree: true, childList: true, characterData: true, attributes: true,
        attributeFilter: ['class', 'style', 'media', 'disabled', 'href', 'data-theme', 'data-color-mode', 'data-dark']
      });
      document.addEventListener('load', schedule, true);
      document.addEventListener('__darkreader__updateSheet', schedule, true);
      document.addEventListener('transitionend', schedule, true);
      matchMedia('(prefers-color-scheme: dark)').addEventListener('change', schedule);
      addEventListener('pageshow', schedule);
      report();
      var lastActivity = 0;
      for (const kind of ['pointerdown', 'input', 'keydown']) {
        document.addEventListener(kind, e => {
          if (!e.isTrusted || performance.now() - lastActivity < 500) return;
          lastActivity = performance.now(); post({ activity: true });
        }, { capture: true, passive: true });
      }
      document.addEventListener('scroll', function (e) {
        var t = e.target; if (!t || t === document || t === document.documentElement || t === document.body) return;
        post({ scroll: t.scrollTop });
      }, { capture: true, passive: true });
    })();
    """
}

extension WebPool: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            showHTTPAuthentication(webView, challenge: challenge, completion: completionHandler)
        default:
            // Platform TLS/client-certificate handling remains authoritative.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = tabsByView[ObjectIdentifier(webView)], live[id] === webView,
              let navigation, !retiredNavigations.contains(navigation) else { return }
        // Explicit pool loads already bind their returned native token. A
        // user's native link supplies its token here.
        if activeNavigations[id] !== navigation { navigationStarted(id, in: webView, navigation: navigation) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = tabsByView[ObjectIdentifier(webView)], live[id] === webView,
              let navigation, !retiredNavigations.contains(navigation) else { return }
        if activeNavigations[id] == nil { navigationStarted(id, in: webView, navigation: navigation) }
        guard activeNavigations[id] === navigation else { return }
        provisional.remove(id)
        firstWindowLoads[id] = nil; windowFiles[id] = nil
        downloadOrigins[id] = nil; downloadConversions[id] = nil
        painted.remove(id)
        failures[id] = nil
        loadFailures[id] = nil
        committedURLs[id] = webView.url
        readerScroll[id] = nil
        readerGeneration[id] = UUID()
        readerDocuments[id] = nil
        readerResults[id] = nil
        publishState(id)
        noteNavigation(id, in: webView, committed: true)
        applyZoom(id, in: webView)
        if let url = webView.url { requestedURLs[id] = url.absoluteString; onCommit?(id, url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = tabsByView[ObjectIdentifier(webView)], live[id] === webView,
              let navigation, !retiredNavigations.contains(navigation) else { return }
        if activeNavigations[id] == nil { navigationStarted(id, in: webView, navigation: navigation) }
        guard activeNavigations[id] === navigation else { return }
        navigationEnded(id, in: webView, navigation)
        recoveries[id] = nil
        requestedURLs[id] = nil
        noteNavigation(id, in: webView, finishing: true)
        actionTypes[id] = nil
        if !fixturesEnabled, let url = webView.url {
            onMetadata?(id, url, webView.title ?? "")
            if !privateTabs.contains(id) { SiteIcons.shared.read(from: webView) }
        }
        log.info("loaded \(id, privacy: .public)")
        publishState(id)
        waitForPaint(id, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, navigation: navigation, provisional: false, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, navigation: navigation, provisional: true, error) }

    private func failed(_ view: WKWebView, navigation: WKNavigation?, provisional: Bool, _ error: Error) {
        guard let id = tabsByView[ObjectIdentifier(view)], live[id] === view else { return }
        navigationEnded(id, in: view, navigation)
        guard let navigation, !retiredNavigations.contains(navigation) else { return }
        if activeNavigations[id] == nil { navigationStarted(id, in: view, navigation: navigation) }
        guard activeNavigations[id] === navigation else { return }
        self.provisional.remove(id)
        let native = error as NSError
        let cancelled = native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled
        // WebKit's response-to-download policy interrupts the provisional page
        // with its legacy policy domain/code (not WKError.Code or URL cancellation).
        let downloadPolicyChange = native.domain == "WebKitErrorDomain" && native.code == 102
        if cancelled || downloadPolicyChange,
           let conversion = downloadConversions[id], conversion.navigation === navigation,
           conversion.document == documents[id],
           conversion.origin.store == ObjectIdentifier(view.configuration.websiteDataStore),
           conversion.origin.privateSession == (privateTabs.contains(id) ? privateSession : nil) {
            // Preserve only this already-approved native conversion. didBecome
            // still validates the original request/frame, exact source and owner.
            return
        }
        // A file's window turned into its download: the window closes, it didn't fail.
        if cancelled || downloadPolicyChange, let file = windowFiles[id], file.navigation === navigation { return }
        windowFiles[id] = nil; firstWindowLoads[id] = nil
        // The main frame interrupted by our own refusal of an app's link.
        let leftForApp = native.domain == "WebKitErrorDomain" && native.code == 102 && appLinks.remove(id) != nil
        if cancelled || leftForApp {
            downloadOrigins[id] = nil; downloadConversions[id] = nil
            return
        }
        downloadOrigins[id] = nil; downloadConversions[id] = nil
        if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
        let reported = native.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (native.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let requested = requestedURLs[id].flatMap(URL.init(string:))
        func withoutFragment(_ url: URL?) -> URL? {
            guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.url
        }
        // A transport error can omit a fragment, which never goes over HTTP.
        // Preserve the captured canonical request only for that same address.
        let failedURL = requested != nil && (reported == nil || withoutFragment(requested) == withoutFragment(reported))
            ? requested : (reported ?? view.url)
        failures[id] = native.localizedDescription
        let previous = provisional && committedURLs[id] != failedURL ? committedURLs[id] : nil
        loadFailures[id] = PageLoadFailure(url: failedURL, previousURL: previous, error: native)
        invalidateReader(id)
        // Keep the actual request represented even if Commit never ran.
        requestedURLs[id] = failedURL?.absoluteString
        pendingIndex[id] = nil
        painted.remove(id)
        log.error("native navigation failed: domain=\(native.domain, privacy: .public) code=\(native.code)")
        if let failedURL { onFailure?(id, failedURL) }
        if loadFailures[id]?.kind == .offline { watchNetwork() }
        publishState(id)
        resume(id)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Links.trace("processTerminated url=\(String(describing: webView.url)) away=\(appAway)")
        guard let id = tabsByView[ObjectIdentifier(webView)] else { return }
        log.error("web content process ended: \(id, privacy: .public) front=\(self.front == id) away=\(self.appAway) state=\(UIApplication.shared.applicationState.rawValue) recoveries=\(self.recoveries[id, default: 0]) url=\(webView.url != nil)")
        downloadOrigins[id] = nil; downloadConversions[id] = nil
        endRefresh(id, in: webView)
        if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
        painted.remove(id)
        guard recoveries[id, default: 0] < 1 else {
            failures[id] = "The web content process stopped"
            loadFailures[id] = PageLoadFailure(processURL: reloadURL(id, in: webView))
            if javaScriptDialog?.tab == id || httpAuthentication?.tab == id { suspendPageDialogs() }
            publishState(id)
            resume(id)
            return
        }
        // iOS ends a page's process while Yab is in the background; a reload
        // now would only be ended again. It loads when Yab is back. A tab not
        // on screen loads once it is shown.
        if appAway || UIApplication.shared.applicationState != .active || !shown(id) {
            stoppedAway.insert(id)
            invalidateReader(id)
            publishState(id)
            return
        }
        recoveries[id, default: 0] += 1
        invalidateReader(id)
        if reload(id) == nil {
            loadFailures[id] = PageLoadFailure(processURL: reloadURL(id, in: webView))
            failures[id] = "The web content process stopped"
            publishState(id); resume(id)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decidePolicy(webView, for: action)
        // Request Desktop Site, remembered per site (SiteSettings).
        if policy == .allow, action.targetFrame?.isMainFrame == true, let id = tabsByView[ObjectIdentifier(webView)] {
            preferences.preferredContentMode = desktop(id, url: action.request.url) ? .desktop : .mobile
            // And the blocker, on or off for where it is going.
            fitShield(webView.configuration.userContentController, for: id, url: action.request.url)
        }
        return (policy, preferences)
    }

    private func decidePolicy(_ webView: WKWebView, for action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // An empty window.open must reach the UI delegate before its URL is assigned.
        let destination = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 }
            ?? (action.targetFrame == nil ? URL(string: "about:blank") : nil)
        guard let url = destination,
              allows(url) || (action.shouldPerformDownload && ["blob", "data"].contains(url.scheme?.lowercased() ?? "")) else {
            // Mail, a call, an app (mailto:, tel:, twitter://): iOS's when
            // the person tapped it; a page sending itself there is not
            // followed. Neither is a failure of the page.
            let id = tabsByView[ObjectIdentifier(webView)]
            if let url = action.request.url, let id, PageLinkRoute.route(url, inPage: false,
                navigation: action.navigationType, tapped: tapped(id, in: webView)) == .outside {
                // One touch, one app: a second link from the same tap stays.
                touches[id] = nil
                OutsideLink.open(url)
            }
            if action.targetFrame?.isMainFrame == true, let id { appLinks.insert(id) }
            return .cancel
        }
        let id = tabsByView[ObjectIdentifier(webView)]
        let mainFrame = action.targetFrame?.isMainFrame == true
        if let id, mainFrame || action.shouldPerformDownload {
            downloadOrigins[id] = canInteract(id, in: webView) ? DownloadOrigin(requestURL: url, frameURL: action.sourceFrame.request.url, url: committedURLs[id] ?? webView.url,
                document: documents[id], store: ObjectIdentifier(webView.configuration.websiteDataStore),
                privateSession: privateTabs.contains(id) ? privateSession : nil) : nil
        }
        if action.shouldPerformDownload {
            guard !fixturesEnabled, let id, canInteract(id, in: webView), action.sourceFrame.isMainFrame,
                  let origin = downloadOrigins[id] else { return .cancel }
            downloadConversions[id] = DownloadConversion(origin: origin, document: documents[id], navigation: activeNavigations[id])
            return .download
        }
        if let id, mainFrame, !PageWindows.follows(navigation: action.navigationType, asker: PageWindows.asker(action),
                                                   page: PageWindows.site(of: webView.url), going: PageWindows.site(of: url),
                                                   behind: behindItsWindow(id)) {
            return .cancel
        }
        // An app's universal link the person tapped opens the app, as in
        // Safari (a wallet's connect link, a store's product page): only to
        // another site, only from a real touch, and only when iOS has an app
        // for it; otherwise it loads here.
        if let id, mainFrame, !fixturesEnabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host()?.lowercased() != webView.url?.host()?.lowercased(), tapped(id, in: webView),
           await OutsideLink.openApp(url) {
            touches[id] = nil
            return .cancel
        }
        if let id, mainFrame {
            appLinks.remove(id)
            actionTypes[id] = action.navigationType
            requestedURLs[id] = url.absoluteString
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("attachment") == true
        guard attachment || !response.canShowMIMEType else { return .allow }
        if !fixturesEnabled, response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)],
           let file = fileWindowOrigin(id, in: webView) {
            windowFiles[id] = file
            return .download
        }
        guard !fixturesEnabled, response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)],
              canInteract(id, in: webView), downloadOrigins[id] != nil else {
            if response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)] { restoreDownloadSource(id, in: webView) }
            return .cancel
        }
        if let origin = downloadOrigins[id] {
            downloadConversions[id] = DownloadConversion(origin: origin, document: documents[id], navigation: activeNavigations[id])
        }
        return .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        becameDownload(download, from: webView)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        becameDownload(download, from: webView)
    }

    /// A file never becomes a phantom page/history entry. WebKit retains the
    /// source document; verify its committed URL/store before restoring its painted state.
    /// During a native conversion, WKWebView.url can still expose an earlier
    /// traversal item. The captured frame, document and navigation bind the
    /// conversion; the pool's qualified committed URL binds its source.
    @discardableResult
    private func restoreDownloadSource(_ id: Tab.ID, in view: WKWebView) -> DownloadOrigin? {
        guard live[id] === view, let origin = downloadOrigins.removeValue(forKey: id),
              origin.store == ObjectIdentifier(view.configuration.websiteDataStore),
              origin.privateSession == (privateTabs.contains(id) ? privateSession : nil),
              let sourceURL = origin.url, committedURLs[id] == sourceURL else { return nil }
        if let active = activeNavigations.removeValue(forKey: id) { retiredNavigations.add(active) }
        documents[id] = origin.document ?? UUID()
        requestedURLs[id] = nil; actionTypes[id] = nil; pendingIndex[id] = nil
        endRefresh(id, in: view)
        publishState(id)
        if origin.url != nil { waitForPaint(id, in: view) }
        return origin
    }

    /// A file on the window's first navigation belongs to its opener.
    private func fileWindowOrigin(_ id: Tab.ID, in view: WKWebView) -> WindowFile? {
        guard live[id] === view, let file = firstWindowLoads[id],
              let navigation = file.navigation, activeNavigations[id] === navigation,
              popupOpeners[id] == file.opener, let source = live[file.opener],
              committedURLs[id] == nil,
              source.configuration.websiteDataStore === view.configuration.websiteDataStore,
              pageInteractionsEnabled, !appAway, UIApplication.shared.applicationState == .active else { return nil }
        return file
    }

    private func becameDownload(_ download: WKDownload, from view: WKWebView) {
        if let id = tabsByView[ObjectIdentifier(view)], let file = windowFiles.removeValue(forKey: id) {
            guard fileWindowOrigin(id, in: view)?.navigation === file.navigation,
                  download.originalRequest?.url == file.request,
                  download.webView === view, download.originatingFrame.isMainFrame,
                  let source = live[file.opener],
                  source.configuration.websiteDataStore === view.configuration.websiteDataStore else {
                download.cancel(nil)
                if live[id] === view, activeNavigations[id] === file.navigation, committedURLs[id] == nil {
                    onCloseWindowFrom?(id, file.opener)
                    forget(id)
                }
                return
            }
            adopt(download, tab: file.opener, page: committedURLs[file.opener] ?? source.url)
            // The empty window goes; the person is back on the page that sent the file.
            onCloseWindowFrom?(id, file.opener)
            forget(id)
            return
        }
        guard let id = tabsByView[ObjectIdentifier(view)], let conversion = downloadConversions[id],
              documents[id] == conversion.document, activeNavigations[id] === conversion.navigation,
              download.originalRequest?.url == conversion.origin.requestURL,
              download.originatingFrame.request.url == conversion.origin.frameURL,
              download.originatingFrame.isMainFrame, download.webView === view,
              let origin = restoreDownloadSource(id, in: view) else { download.cancel(nil); return }
        downloadConversions[id] = nil
        presentDownload(download, tab: id, in: view, origin: origin)
    }

    private func presentDownload(_ download: WKDownload, tab id: Tab.ID, in view: WKWebView, origin: DownloadOrigin) {
        guard canInteract(id, in: view) else { download.cancel(nil); return }
        adopt(download, tab: id, page: origin.url)
    }

    /// The WKDownload is ours from here. Its source goes by the page it came
    /// from, as the page said it then: its tab may be long gone by Retry.
    private func adopt(_ download: WKDownload, tab id: Tab.ID, page: URL?, entry: UUID? = nil) {
        let site = siteOf?(id, page)
        let source = PageDownload.Source(tab: id, host: site?.host ?? page?.host() ?? "",
                                         isPrivate: site?.isPrivate ?? privateTabs.contains(id))
        let job = PageDownload(download: download, source: source, store: downloads, entry: entry,
            ask: { [weak self] question, answer in
                guard let ask = self?.onDownloadAsk else { answer(true); return }
                ask(question, answer)
            },
            retry: { [weak self] entry, store, request in
                self?.retryDownload(entry, store, request, page: page, tab: id) ?? false
            }, ended: { [weak self] token in self?.transfers[token] = nil })
        transfers[job.id] = job
        if appAway { job.leave() }
    }

    /// Download Linked File: the link's bytes through the tab's own store,
    /// the page where it is.
    func downloadLinked(_ url: URL, from id: Tab.ID) {
        guard let view = live[id], canInteract(id, in: view), allowsDownloadOf(url) else { return }
        let page = committedURLs[id] ?? view.url
        view.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.adopt(download, tab: id, page: page)
        }
    }

    func allowsDownloadOf(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// Retry, under its row, in the store it first read: from its tab if it is
    /// still there, else from any page of that store.
    private func retryDownload(_ entry: UUID, _ store: WKWebsiteDataStore?, _ request: URLRequest, page: URL?, tab id: Tab.ID) -> Bool {
        guard let store else { return false }
        let view = live[id].flatMap { $0.configuration.websiteDataStore === store ? $0 : nil }
            ?? live.values.first { $0.configuration.websiteDataStore === store }
        guard let view else { return false }
        view.startDownload(using: request) { [weak self] download in
            self?.adopt(download, tab: id, page: page, entry: entry)
        }
        return true
    }
}

extension WebPool: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        showJavaScriptDialog(webView, frame: frame, message: message, kind: .alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        showJavaScriptDialog(webView, frame: frame, message: message, kind: .confirm) { completionHandler($0 != nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        showJavaScriptDialog(webView, frame: frame, message: prompt, kind: .prompt,
                             defaultText: defaultText, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Sign-in libraries open an empty window before assigning its URL.
        let url = action.request.url.flatMap { $0.absoluteString.isEmpty ? nil : $0 } ?? URL(string: "about:blank")!
        guard action.targetFrame == nil, allows(url),
              let source = tabsByView[ObjectIdentifier(webView)], live[source] === webView,
              PageWindows.opens(link: action.navigationType == .linkActivated, spent: touchSpent(source),
                                asker: PageWindows.asker(action), page: PageWindows.site(of: webView.url),
                                going: PageWindows.site(of: url)) else { return nil }
        let shy = privateTabs.contains(source)
        if let owner = spaceForTab?(source) {
            guard configurationForPage(in: owner).websiteDataStore === webView.configuration.websiteDataStore else { return nil }
        }
        let tab: Tab?
        if let onOpenWindowFrom { tab = onOpenWindowFrom(url, source, shy) }
        else { tab = onOpenWindow?(url, shy) }
        guard let tab, tab.id != source, configuration.websiteDataStore === expectedStore(for: tab),
              webView.configuration.websiteDataStore === expectedStore(for: tab) else { return nil }
        // Use WebKit's opener configuration only after domain validation.
        let popup = makeView(for: tab, configuration: configuration)
        popupOpeners[tab.id] = source
        if allowsDownloadOf(url) { firstWindowLoads[tab.id] = WindowFile(opener: source, request: url) }
        openedWindows[source] = (touches[source], ProcessInfo.processInfo.systemUptime)
        return popup
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let id = tabsByView[ObjectIdentifier(webView)], let siteSettings else { return .prompt }
        let kinds: [SiteSettings.Permission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: []
        }
        guard !kinds.isEmpty else { return .prompt }
        let site = siteOf?(id, webView.url) ?? (origin.host, privateTabs.contains(id))
        return siteSettings.asked(kinds, host: site.host ?? origin.host, isPrivate: site.isPrivate)
    }

    func webViewDidClose(_ webView: WKWebView) {
        // OAuth callbacks close their popup after notifying the opener.
        // A stale view or an ordinary page cannot close a tab this way.
        guard let id = tabsByView[ObjectIdentifier(webView)], live[id] === webView,
              let source = popupOpeners.removeValue(forKey: id) else { return }
        onCloseWindowFrom?(id, source)
        forget(id)
    }

    /// A held web link of the page in front: its own menu (PageLinkMenu),
    /// with an image's rows when the link is around one: iOS's element info
    /// names only the link, so the page says what is under the finger
    /// (PageImage). Anything else (mail, a call) keeps the system's. An image
    /// with no link never comes here: WebKit shows its own menu (Share, Save
    /// to Photos, Copy) without asking this delegate.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, opensAsTab(url), let id = tabsByView[ObjectIdentifier(webView)],
              canInteract(id, in: webView) else { completionHandler(nil); return }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.live[id] === webView else { completionHandler(nil); return }
            let held = await PageImage.held(in: webView)
            let image = held.map { held in
                PageImage.actions(held, in: webView) { [weak self] outcome in self?.onImageSaved?(outcome) }
            } ?? []
            completionHandler(PageLinkMenu.configuration(for: url, from: webView, canDownload: self.allowsDownloadOf(url), image: image,
                open: { [weak self, weak webView] opening in
                    guard let self, let webView, self.live[id] === webView else { return }
                    self.onOpenLink?(url, id, opening)
                },
                download: { [weak self] in self?.downloadLinked(url, from: id) }))
        }
    }

    /// A tap on the link's preview opens it here, in the tab.
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL, opensAsTab(url), let id = tabsByView[ObjectIdentifier(webView)],
              canInteract(id, in: webView) else { return }
        animator.addCompletion { [weak self, weak webView] in
            guard let self, let webView, self.live[id] === webView else { return }
            self.load(id, url)
        }
    }

    /// A link that can be a tab of its own: the web's, never about: or data:.
    func opensAsTab(_ url: URL) -> Bool {
        allows(url) && !["about", "data"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension UIColor {
    /// Dark enough for light ink on it: the page reporter's own measure.
    var isDarkGround: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a), a > 0 else { return false }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.4
    }
}

/// The message handler, held weakly: WebKit keeps its handlers for good.
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var pool: WebPool?
    init(_ pool: WebPool) { self.pool = pool }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { pool?.received(message) }
    }
}

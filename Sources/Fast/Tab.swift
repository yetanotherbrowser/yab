import ImageIO
import Combine
import SwiftUI
import WebKit

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in, the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.
//
// Kept alive, that is, while it is worth what it costs. A tab nobody has
// looked at for four hours gives its view back (see `sleep(picture:)`) and
// keeps what it takes to come back exactly where it was.

enum Web {
    /// One pool for every tab. Deprecated, and still not nothing: a
    /// configuration made fresh gets a pool of its own, and each pool
    /// starts cold, no warm process to hand the next tab, no page cache
    /// to share, and, worst, the list of every font the user has installed
    /// read afresh on the main thread for each page's first process. With
    /// two hundred fonts that was 60–80 ms a tab: opening ten at once held
    /// the window for most of a second. Shared, it is read once.
    ///
    /// A pool must also never die while the app runs. Each one watches the
    /// Mac's sleep and wake (WebCore::PowerObserver); one freed as the Mac
    /// wakes leaves WebKit a wake block for a dead observer, and the app
    /// crashes in PowerObserver::didReceiveSystemPowerNotification
    /// (register 1711). So every web view Yab makes and lets go, its own
    /// pages as much as tabs, takes this pool or `extensionPool`, never a
    /// configuration's fresh one: `WKWebViewConfiguration()` makes a pool
    /// of its own, freed with the last view made from it
    /// (ProcessPoolLifetimeTests). A configuration kept in a static for
    /// the app's life (mail, chat widgets) may keep its own.
    static let pool = WKProcessPool()

    /// Extensions' own pages: their workers, popups and options, which
    /// otherwise share a pool that lives only as long as their sign-in's
    /// controller. Kept apart from the tabs' pool so an extension page is
    /// never related to a tab's warm process.
    static let extensionPool = WKProcessPool()

    /// A hidden page's timers wait longer and longer the longer it stays
    /// hidden, up to twenty seconds a page, rather than every second for as
    /// long as the tab is open: WebKit's `HiddenPageDOMTimerThrottlingAutoIncreases`,
    /// on in Safari and off in a WKWebView unless asked for. Chrome does the
    /// like after five minutes (intensive wake-up throttling: once a
    /// minute). Twenty hidden pages each with a one-second timer woke the
    /// CPU 88 times a second, and twice a second with it, from the second
    /// minute (docs/evidence/night-memory-2026-10-14.md). A page playing
    /// sound or on a call isn't throttled at all, by WebKit; an agent's tab
    /// and a site kept awake (a chat, mail, music) are left as they were
    /// (Tab.paceHiddenTimers), since they are wanted working out of sight.
    /// YAB_TIMER_AUTO=0 turns it off, for the A/B.
    static let slowsHiddenTimers = ProcessInfo.processInfo.environment["YAB_TIMER_AUTO"] != "0"

    static func hiddenTimers(_ preferences: WKPreferences, slowDown: Bool) {
        let selector = NSSelectorFromString("_setHiddenPageDOMTimerThrottlingAutoIncreases:")
        guard preferences.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, slowDown)
    }

    /// ⌫ on a page is WebKit's Back, and ⇧⌫ its Forward, when nothing
    /// editable has the keyboard and the page leaves the key alone: on in a
    /// WKWebView unless the app turns it off, which is WebKit's default
    /// (Chrome and Arc have no such key either). A press with a video's player focused, a
    /// click on it having put the keyboard there, took a YouTube watch page
    /// back to YouTube's home, the video gone with it (#262,
    /// evals/delete-key). Back stays ⌘[ and ⌘←. YAB_BACKSPACE_BACK=1 keeps
    /// WebKit's, for the A/B.
    static let backspaceGoesBack = ProcessInfo.processInfo.environment["YAB_BACKSPACE_BACK"] == "1"

    static func backspaceNavigation(_ preferences: WKPreferences, on: Bool) {
        let selector = NSSelectorFromString("_setBackspaceKeyNavigationEnabled:")
        guard preferences.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, on)
    }

    /// Where yab's own page scripts run, and where their messages come
    /// from: a world of their own beside the page's. They see the same page,
    /// and the page sees none of them, no variable of theirs, and no
    /// `window.webkit`, which Safari never shows a page and which sites read
    /// as an app's embedded web view rather than a browser. Google answered
    /// that with a CAPTCHA every few searches, and refused sign-ins as "not
    /// secure".
    @MainActor static let world = WKContentWorld.world(name: "yab")

    /// Every handler of yab's taken off a controller: in its own world, and
    /// in the page's, where they all were before. A tab opened by a link
    /// inherits its opener's configuration, handlers included, and
    /// registering a name twice is a hard crash.
    @MainActor static func release(_ controller: WKUserContentController) {
        for name in Tab.relays.map(\.name) {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        controller.removeScriptMessageHandler(forName: FrameRelay.name, contentWorld: AgentPage.world)
        controller.removeScriptMessageHandler(forName: DarkRelay.name, contentWorld: DarkPages.world)
    }

    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        // A test world may claim another Safari, for a site that serves
        // older ones other code (evals/docs-zoom/hidden.py: Docs before 26.4).
        if Store.testing, let claimed = Store.settings.string(forKey: "safari.version"),
           !claimed.isEmpty, claimed.allSatisfy({ $0.isNumber || $0 == "." }) { return claimed }
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids. From macOS 26
        // Safari shares its number; before, it was 3 ahead (14 is 17).
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return os >= 26 ? "\(os).0" : "\(os + 3).0"
    }

    /// A call's speaker chosen in the page (#257). WebKit
    /// lists speakers to a page ("audiooutput" in enumerateDevices) and
    /// gives its audio and video elements `setSinkId` under these flags,
    /// on by default in macOS 26's WebKit and set here for any other
    /// (scripts/runs/webkit_speaker_features.swift lists them). The one
    /// flag turned off is the gesture WebKit wants for each `setSinkId`:
    /// a call's page adds an audio element for each new voice, with no
    /// click behind it, and that one would play on the old speaker (Chrome
    /// asks for no gesture either).
    static let speakerFlags = ["ExposeSpeakersEnabled": true, "PerElementSpeakerSelectionEnabled": true,
                               "SpeakerSelectionRequiresUserGesture": false]

    static func speakers(_ preferences: WKPreferences) {
        for (key, on) in speakerFlags { WebFeature.set(key, on, in: preferences) }
    }

    /// macOS's own window and screen picker for a page's getDisplayMedia
    /// (Share.swift's way to it, and a window or a screen that failed). In
    /// macOS 15's WebKit (Safari 18, before 622) it is behind this flag,
    /// whose default is an OS feature flag (WebPreferencesDefaultValuesCocoa,
    /// `Bilby/Newsroom`); off, WebKit asks the old SCContentSharingSession
    /// instead and the page is told no (ScreenCaptureKitSharingSessionManager
    /// ::promptForGetDisplayMedia). WebKit 622 dropped the flag and always
    /// uses the picker where macOS has it, so there this does nothing.
    static func systemSharePicker(_ preferences: WKPreferences) {
        WebFeature.set("UseSCContentSharingPicker", true, in: preferences)
    }

    /// The scrolling keys (arrows, Page Up/Down, Space, Home/End) glide, as
    /// in Chrome and Arc (#302). WebKit's scroll animator is on too, though
    /// a mouse wheel's notch still jumps with it (evals/m1-scroll): notches
    /// glide by WheelGlide. A trackpad's scrolling is the same either way.
    /// YAB_SMOOTH_SCROLL picks for an A/B (evals/smooth-scroll): 0 WebKit as
    /// it comes, wheel or keys one of the two, else both.
    static func smoothScrolling(_ preferences: WKPreferences) {
        let pick = ProcessInfo.processInfo.environment["YAB_SMOOTH_SCROLL"] ?? ""
        guard pick != "0" else { return }
        if pick != "keys" { WebFeature.set("ScrollAnimatorEnabled", true, in: preferences) }
        if pick != "wheel" { WebFeature.set("EventHandlerDrivenSmoothKeyboardScrollingEnabled", true, in: preferences) }
    }

    /// A page draws at the screen's own rate, 120 Hz on a ProMotion screen,
    /// like Arc. WebKit holds a page's rendering updates
    /// (requestAnimationFrame, scrolling a page drives, its painting) near
    /// 60 a second under this flag, on by default: Safari's Feature Flags
    /// call it "Prefer Page Rendering Updates near 60fps", and with it off
    /// testufo.com runs at 120 there. Saving power (Thrift), a new page
    /// keeps WebKit's 60, read once as the page starts like the hidden-page
    /// policy. YAB_PAGE_FPS=60 keeps WebKit's 60 for an A/B.
    static func fullFrameRate(_ preferences: WKPreferences) {
        let keep60 = ProcessInfo.processInfo.environment["YAB_PAGE_FPS"] == "60" || MainActor.assumeIsolated { Thrift.on }
        WebFeature.set("PreferPageRenderingUpdatesNear60FPSEnabled", keep60, in: preferences)
    }

    /// `store`: a private tab's own, for one opened out of it.
    /// `extensions`: false for a page no window shows as a tab (a boost's
    /// quiet trial), which extensions' scripts would ask after in vain.
    static func configuration(shy: Bool = false, store: WKWebsiteDataStore? = nil, extensions: Bool = true) -> WKWebViewConfiguration {
        // Before the first page's process starts: it asks then what sites
        // may show notifications.
        MainActor.assumeIsolated { SiteNotices.install() }
        let config = WKWebViewConfiguration()
        MainActor.assumeIsolated { AppleWritingTools.configure(config) }
        config.processPool = pool
        // ⌫ is no Back on a page, whatever else is cut (Web.backspaceNavigation, #262).
        Web.backspaceNavigation(config.preferences, on: Web.backspaceGoesBack)
        if LinkGap.cut("config") {
            config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: Spaces.current) })
            return config
        }
        if !LinkGap.cut("paint") { PagePaint.configure(config) }
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does, its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces, the sign-ins of the space on screen (Spaces.swift).
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: Spaces.current) })
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions says they may. The controller has to be there when
        // the view is made; it can't be added after.
        if #available(macOS 15.4, *), extensions, !LinkGap.cut("ext"), !shy || Store.settings.bool(forKey: "extensions.private") {
            MainActor.assumeIsolated { Extensions.attach(config) }
        }
        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)",
        // no browser, no version. Google reads that as something it doesn't
        // recognize and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        // yab://task, and the handler only that page can talk to.
        if !LinkGap.cut("diary") { MainActor.assumeIsolated { DiaryPage.attach(config) } }
        // A DRM extension's overlay pages, iframes and assets a WebKit page
        // of the site embeds. Inert everywhere else: only those scripts load
        // that scheme.
        if #available(macOS 15.4, *) {
            config.setURLSchemeHandler(ChromiumDRMResources.shared, forURLScheme: "chrome-extension")
        }
        if !LinkGap.cut("ua") { config.applicationNameForUserAgent = Web.userAgentName }
        if LinkGap.cut("prefs") {
            if !LinkGap.cut("localnet") { MainActor.assumeIsolated { LocalNetwork.protect(config.userContentController) } }
            return config
        }
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        // A site's own Picture-in-Picture button, X's for one: off by default
        // in a WKWebView on macOS too, though the page is told it may ask.
        SitePiP.allow(config.preferences)
        // Every window a page asks for comes to Browser's createWebViewWith,
        // which decides (WindowGate): one asked for a moment after your click
        // or key in that page opens, as a sign-in's does once its button has
        // fetched what it needs; any other is blocked and the plate says so.
        // Off, WebKit dropped those sign-ins without a word.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        // A page out of sight runs on, slowed,
        // where WebKit and Safari stop it: coming back to a stopped page
        // waited 120 ms or more one switch in ten, while a running one is
        // there at once (evals/lowram, policy.sh: 128 to 66 ms at the 90th
        // percentile). It costs CPU with nobody looking, 11% of a core to
        // 35% for 48 open sites, still half of Chrome's 65%. Saving power
        // (Thrift), a new page is stopped when hidden, as before. WebKit
        // reads this once, as the page starts: a tab keeps what it began with.
        config.preferences.inactiveSchedulingPolicy = MainActor.assumeIsolated { Thrift.on } ? .suspend : .none
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        // A test run may ask for another way of holding hidden pages, to
        // measure what it costs and saves (evals/lowram): suspend, throttle
        // or none.
        if Store.testing, let held = Store.settings.string(forKey: "pages.inactive") {
            config.preferences.inactiveSchedulingPolicy = held == "none" ? .none : held == "throttle" ? .throttle : .suspend
        }
        // Websites kept off this Mac's servers and the network's devices,
        // from the first request (LocalNetwork.swift).
        if !LinkGap.cut("localnet") { MainActor.assumeIsolated { LocalNetwork.protect(config.userContentController) } }
        if ProcessInfo.processInfo.environment["YAB_NAVIGATION_API"] == "0" { NavigationAPI.off(config.preferences) }
        Web.speakers(config.preferences)
        Web.systemSharePicker(config.preferences)
        Web.smoothScrolling(config.preferences)
        Web.fullFrameRate(config.preferences)
        if Store.testing { WebFeature.fromEnvironment(config.preferences) }
        // A hidden page's timers wait longer and longer.
        if Web.slowsHiddenTimers { Web.hiddenTimers(config.preferences, slowDown: true) }
        return config
    }
}

@MainActor
@Observable
final class Tab: ObservableObject, Identifiable, Relaying {
    /// Each formerly published property's new values for Combine (`changes(\.name)`), and any of
    /// them about to change (`relay.any`), as @Published told them (Observed.swift).
    @ObservationIgnored let relay = ChangeRelay<Tab>()
    /// ObservableObject's publisher, kept here. With no @Published left
    /// (the state is @Observable), Combine's own `objectWillChange` found
    /// it by walking every stored property through reflection on each
    /// read, and SwiftUI reads it for every @ObservedObject on every
    /// update: about 0.1 ms a read of a Browser or a Tab (bench
    /// willchange), many times over in every pass (feedback #120).
    nonisolated let objectWillChange = ObservableObjectPublisher()
    let id: UUID
    /// Browser-specific observers are replaced when this live tab moves to
    /// another window and end with the tab when it closes.
    @ObservationIgnored var browserWatches: Set<AnyCancellable> = []
    @ObservationIgnored private var appearanceWatch: AnyCancellable?

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is, a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var page: any PageHandle {
        _ = pageRevision
        if let builtPage { return builtPage }
        // Choose before restoring a retained controller or creating a page.
        if !replacingEngine { engineKind = engineFactory.opening(self) }
        if let sleeping = sleepingChromium {
            sleepingChromium = nil
            if sleeping.remoteID != nil, engineKind == .chromium, sleeping.profile == chromiumProfile {
                builtPage = sleeping
                sleeping.events = delegate as? any PageEvents
                sleeping.stateEvents = self
                sleeping.restoreFromSleep()
                return sleeping
            }
            // A helper loss, profile move or engine change cannot reuse the
            // old native controller. Retire it before the ordinary wake path.
            sleeping.retire(call: false, pictureInPicture: false)
        }
        siteEngineProfile = chromiumProfile
        let made = OpenTrace.time("build") { engineFactory.make(self, engineKind) }
        // A factory without the asked engine (no helper, Intel) makes what it has.
        if made.engine != engineKind { engineKind = made.engine }
        builtPage = made
        made.events = delegate as? any PageEvents
        made.stateEvents = self
        if made.engine == .chromium {
            let factor = address?.scheme?.hasPrefix("http") == true
                ? CGFloat(PageAppearance.zoom(host: address?.host(), privatePage: shy)) : 1
            if abs(made.pageZoom - factor) > 0.004 { made.pageZoom = factor }
            zoom = factor
        }
        made.webKit?.watchVideoOpening()
        return made
    }
    /// Compatibility for consumers still awaiting migration. These do not
    /// own a second page and never construct a WebKit page for another engine.
    var built: PageView? { builtPage?.webKit }
    @ObservationIgnored private(set) var builtPage: (any PageHandle)? {
        didSet { ChromiumTabGroups.shared.changed() }
    }
    /// Chromium keeps its browser/controller while the renderer is discarded.
    @ObservationIgnored private var sleepingChromium: ChromiumPage?
    @ObservationIgnored private var sleepAttempt: UUID?
    /// Attach a Chrome-created native document without navigating or applying
    /// the new-navigation DRM fallback. Its live request context already exists.
    func prepareChromiumPageForAdoption(profile: String) -> ChromiumPage? {
        guard !gone, builtPage == nil, engineKind == .chromium else { return nil }
        let page = ChromiumPage(tab: self, profile: profile)
        siteEngineProfile = profile
        builtPage = page
        page.events = delegate as? any PageEvents
        page.stateEvents = self
        return page
    }
    @ObservationIgnored let engineFactory: PageEngineFactory
    @ObservationIgnored var siteEngineTurn = 0
    @ObservationIgnored var engineSwitchDocument: EngineSwitchDocument?
    @ObservationIgnored private(set) var siteEngineProfile: String?
    /// The Chromium profile of the tab a hover card's page was made for,
    /// until a window takes the page over (LinkCardLoad).
    @ObservationIgnored var warmProfile: String?
    @ObservationIgnored private var replacingEngine = false
    @ObservationIgnored var chromiumDRMEnabled: Bool
    /// ⌘K's Open in: this tab's engine whatever the rules say (EngineRules).
    @ObservationIgnored var engineHeld: PageEngineKind?
    /// The site (registrable domain) whose player refused Chromium's missing
    /// Widevine in this tab: WebKit while the tab is on it, the default's
    /// engine again once it goes elsewhere (Tab.routesToChromium).
    @ObservationIgnored var engineProtectedSite: String?
    /// The address Yab itself last sent this tab to (go(to:)): typed, a
    /// bookmark, a link from another app. A person's navigation to routing.
    @ObservationIgnored var engineSent: URL?
    /// Memory was tight when this tab opened, so it is not on the default's
    /// own engine: WebKit under Auto, Chromium under WebKit First.
    @ObservationIgnored var engineMemoryMoved = false
    /// The default engine changed while this tab's page was up. It keeps that
    /// engine and takes this one when it next builds a page (waking).
    @ObservationIgnored var enginePendingDefault: PageEngineKind?
    @ObservationIgnored var chromiumDRMExtensions: ChromiumDRMExtensions?
    private(set) var engineKind: PageEngineKind {
        willSet { relay.send(\.engineKind, newValue) }
    }
    private(set) var pageRevision = 0
    @ObservationIgnored private var engineTitle: String?
    @ObservationIgnored private var retainingEngineTitle = false
    @ObservationIgnored private var carriedEntry: PageHistoryEntry?
    var currentEntry: PageHistoryEntry? { builtPage?.historyEntry ?? carriedEntry }
    @ObservationIgnored private var engineURL: URL?
    @ObservationIgnored private var engineLoading = false
    @ObservationIgnored private var engineBack = false
    @ObservationIgnored private var engineForward = false
    private(set) var pageTheme: PageColor?
    private(set) var pageUnderColor: PageColor?
    /// Replace the document at a navigation boundary. The Tab itself, its
    /// row, window, saved title and current history entry stay in place.
    /// A missing engine is refused before touching the live document.
    @discardableResult
    func replaceEngine(with kind: PageEngineKind, at request: URLRequest) -> Bool {
        guard !gone, kind != engineKind, engineFactory.kinds.contains(kind), request.url != nil else { return false }
        let old = builtPage
        let carriedZoom = old?.url == request.url ? old?.pageZoom : nil
        let entry = currentEntry
        let parent = old?.superview
        let frame = old?.frame
        let mask = old?.autoresizingMask
        let next = old.flatMap { old in
            parent?.subviews.drop(while: { $0 !== old }).dropFirst().first
        }
        let responder = old?.window?.firstResponder as? NSView
        let focused = old.map { responder === $0 || responder?.isDescendant(of: $0) == true } ?? false
        // Invalidate held writes and retries belonging to the old document.
        goSerial &+= 1
        heldWrites = nil
        holdTurn &+= 1
        retoneArrival &+= 1
        toneGate.invalidate()
        discard()
        // WebKit configurations can share a content controller with a popup.
        // Retire the old handlers before constructing the replacement, while
        // keeping this tab's cookie store and configuration preferences.
        engineKind = kind
        engineTitle = nil
        retainingEngineTitle = true
        carriedEntry = entry
        engineURL = address
        engineLoading = false
        engineBack = false
        engineForward = false
        pageTheme = nil
        pageUnderColor = nil
        hasBackHistory = false
        canGoForward = false
        immersed = false
        pending = nil
        memory = nil
        replacingEngine = true
        let made = page
        replacingEngine = false
        if let carriedZoom {
            if abs(made.pageZoom - carriedZoom) > 0.004 { made.pageZoom = carriedZoom }
            zoom = carriedZoom
        }
        if let frame { made.frame = frame }
        if let mask { made.autoresizingMask = mask }
        if let parent { parent.addSubview(made, positioned: .below, relativeTo: next) }
        if focused { made.window?.makeFirstResponder(made) }
        pageRevision &+= 1
        made.navigate(to: request)
        return true
    }

    /// Keep a newly selected site choice lazy; a live page uses the same seam.
    func applySiteEngineChoice(_ kind: PageEngineKind, at request: URLRequest) {
        if builtPage == nil { engineKind = engineFactory.resolved(kind) }
        else { _ = replaceEngine(with: kind, at: request) }
    }

    /// The default engine, on a tab with no page. A tab with a page stays on
    /// its engine and is told for later. Non-web pages keep the engine that
    /// owns them (extension pages, adopted auxiliaries).
    func followDefaultEngine(_ kind: PageEngineKind) {
        guard !gone, engineFactory.kinds.contains(kind) else { return }
        guard builtPage == nil else { enginePendingDefault = kind; return }
        enginePendingDefault = nil
        chromiumDRMEnabled = kind == .chromium
        engineMemoryMoved = false
        guard EngineRules.followsDefault(address) else { return }
        engineKind = engineFactory.resolved(engineFactory.sites.decide(kind, at: address, held: engineHeld, tight: false).kind)
    }

    #if DEBUG
    /// The page gone with the tab left, as sleep leaves it, for the tests of what comes after.
    func unbuildForEngineTest() {
        discard()
    }
    #endif

    /// A navigation that did not go: the tab says the page it still shows.
    func keepShowing(_ page: any PageHandle) {
        guard builtPage === page, let shown = page.url else { return }
        address = shown
    }

    var engineNavigationRevision: Int { goSerial }

    /// The view built and its content process started, for a spare tab
    /// (Browser.keepSpare). A view starts its process only at its first
    /// load: built alone, a spare saved nothing, the 45-50 ms of the
    /// process starting were still on the way to the page's first frame
    /// (docs/evidence/tab-open-2026-10-13.md). WebKit's own call for this,
    /// Safari's; the page that loads then goes in the same process.
    func warm() {
        guard (builtPage?.engine ?? engineFactory.upcoming(self, at: address)) == .webKit else {
            (page as? ChromiumPage)?.warmUp(); return
        }
        guard let web = webKitOnly("WebKit process warm-up") else { return }
        if web.responds(to: Tab.launchSelector) { web.perform(Tab.launchSelector) }
        OpenTrace.mark("warm \(OpenTrace.process(web))")
        // Extensions' content scripts compiled there too, ahead of the page.
        if #available(macOS 15.4, *) { ContentWarm.warm(web) }
    }
    private static let launchSelector = NSSelectorFromString("_launchInitialProcessIfNecessary")
    /// The spare for a Chromium window: its helper is its own process, nothing shares the first frame with it.
    var warmsSoon: Bool { (builtPage?.engine ?? engineFactory.upcoming(self, at: address)) == .chromium }

    /// A view whose process this tab's page is to be made in, when it is
    /// built (Browser.wakeInSpare), and what to do once the page is under
    /// way there.
    @ObservationIgnored private var related: (view: WKWebView, done: () -> Void)?
    /// Which tab this was, for Lingering when it is closed: "the spare"
    /// from the Browser, else its address's host.
    @ObservationIgnored var lingerNote = ""
    private static let relatedSelector = NSSelectorFromString("_setRelatedWebView:")

    func relate(to view: WKWebView, then done: @escaping () -> Void) {
        guard engineKind == .webKit else { WebKitOnly.note("WebKit related process warming", engine: engineKind); return done() }
        guard builtPage == nil, configuration.responds(to: Tab.relatedSelector) else { return done() }
        related = (view, done)
        // Never built (closed asleep): the spare goes all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.letRelatedGo() }
    }

    private func letRelatedGo() {
        guard let related else { return }
        self.related = nil
        related.done()
    }

    /// Closed for good: nothing is to build its page again. A stage still
    /// drawn for it in the frame it closes in (the half of a pair going)
    /// would otherwise build an empty one, and a content process with it.
    @ObservationIgnored private(set) var gone = false
    /// A site's floating HTML document, separate from our video/call window.
    @ObservationIgnored var documentPiP = DocumentPiP()
    /// Its page as a PDF Fill & Sign can take (PDFDesk.swift).
    @ObservationIgnored let paper = PDFPaper()
    /// Made when first needed. A tab brought back asleep has none until
    /// its page is built: a session of two hundred tabs coming back made
    /// two hundred configurations (controller, rule lists, preferences)
    /// before the window's first frame (docs/evidence/night-startup-2026-10-14.md).
    @ObservationIgnored private var madeConfiguration: WKWebViewConfiguration?
    /// The store a configuration not made yet is to have.
    @ObservationIgnored private var laterStore: WKWebsiteDataStore?
    private var configuration: WKWebViewConfiguration {
        if let madeConfiguration { return madeConfiguration }
        let made = Web.configuration(store: laterStore)
        madeConfiguration = made
        paceHiddenTimers()
        return made
    }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { madeConfiguration?.websiteDataStore ?? laterStore ?? configuration.websiteDataStore }
    /// Whether its page was made with the extension controller in it: every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    @available(macOS 15.4, *)
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// The extension controller its page's configuration carries, its
    /// sign-in's (ExtensionSignIns): .some(nil) for one made without, nil
    /// while there is no configuration yet.
    @available(macOS 15.4, *)
    var madeExtensionController: WKWebExtensionController?? { madeConfiguration.map { $0.webExtensionController } }
    /// The store its page is made in, or will be, without making it.
    var pageStore: WKWebsiteDataStore { madeConfiguration?.websiteDataStore ?? laterStore ?? Spaces.store(for: Spaces.current) }
    /// A restored tab may have a configuration before its view is built.
    @available(macOS 15.4, *)
    var extensionRulesController: WKUserContentController? {
        // Not made yet: it gets the rules as they are then.
        guard let madeConfiguration, madeConfiguration.webExtensionController === Extensions.shared.controller else { return nil }
        guard engineKind == .webKit else { WebKitOnly.note("WebKit extension rules context", engine: engineKind); return nil }
        return builtPage?.webKit?.configuration.userContentController ?? madeConfiguration.userContentController
    }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    @ObservationIgnored weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            builtPage?.events = delegate as? any PageEvents
            builtPage?.webKit?.installDelegates(delegate)
        }
    }
    /// The stylesheet a page not yet built is to be armed with.
    @ObservationIgnored private(set) var veils = ""
    /// Whether the next document gets YouTube's ads taken out (see
    /// YouTube), decided with the blocker's lists at each navigation.
    var skipsAds = false

    private(set) var title = "" {
        willSet { relay.send(\.title, newValue) }
    }
    /// How many wait for you on the page, as its own badge or its title
    /// says (Corner.swift); nil with none, or with no page.
    private(set) var count: Int? {
        willSet { relay.send(\.count, newValue) }
    }
    /// A title count may decorate an icon only after this document shows a
    /// count transition without an icon mutation. The Badging API owns its
    /// count explicitly and does not need that evidence.
    private(set) var showsOwnCount = false {
        willSet { relay.send(\.showsOwnCount, newValue) }
    }
    @ObservationIgnored private var countIconProof = CountIconProof()
    @ObservationIgnored private var countIconReady = false
    @ObservationIgnored private var countTitle: String?

    func observedCountIcon(title: String, icon: String) {
        guard !awaitingDocumentMetadata else { return }
        countTitle = title
        // Use the very count selected for drawing, not an ignored title's
        // number (Gmail's folder count differs from its Primary feed).
        let observed = recount()
        countIconProof.observe(count: observed, icon: icon)
        updateCountIconPermission()
    }

    /// DOM evidence cannot authorize a count over the old cached icon
    /// while the page's current icon is still being fetched.
    func countIconFetchStarted() {
        countIconReady = false
        updateCountIconPermission()
    }

    func countIconLoaded() {
        countIconReady = true
        updateCountIconPermission()
    }

    private func updateCountIconPermission() {
        let allowed = badge != nil || (countIconReady && countIconProof.unchanged)
        if showsOwnCount != allowed { showsOwnCount = allowed }
    }

    private func resetCountIconProof() {
        countIconProof = CountIconProof()
        countIconReady = false
        countTitle = nil
        badge = nil
        showsOwnCount = false
    }

    /// What the page last gave the Badging API: once a page uses it, its
    /// title's number is left alone.
    @ObservationIgnored private var badge: Int?
    var appBadgeCount: Int? { badge }
    /// What the site says with no page up, read with its cookies (Gmail's
    /// feed, Notion's inbox): the count of a pin asleep.
    @ObservationIgnored private var sourceCount: Int?

    func sourced(_ n: Int?) {
        sourceCount = n
        let observed = recount()
        // A live feed transition participates in the same icon interval;
        // sleeping tabs have no document that can establish this evidence.
        if builtPage != nil, let icon = countIconProof.icon {
            countIconProof.observe(count: observed, icon: icon)
            updateCountIconPermission()
        }
    }
    // A failed extension callback stays visible to tabs.onUpdated until
    // another navigation starts, even if the engine restores the old URL.
    @ObservationIgnored private var standingAtFailure = false

    private(set) var address: URL? {
        willSet { relay.send(\.address, newValue) }
        didSet {
            if address?.host() != oldValue?.host() { paceHiddenTimers() }
            if address != oldValue { Browser.visitMoved(self) }
            settleAddressFlags()
        }
    }

    /// What the window reads off the address, kept as their own values and
    /// written only when they change: read through `address`, every view
    /// that only asked "blank?" or "mail?" ran again at every link's new
    /// address, in the turn right after its start, the one WebKit's
    /// question about the response waits behind (round 12 of
    /// docs/evidence/clean-gap-2026-10-13.md). Narrow.addressFlags.
    private(set) var blankFlag = true
    private(set) var mailFlag = false
    /// A page on this Mac's own server: that server, as DevSites names it.
    private(set) var devServer: String?
    /// The page's site, lower case: what changes when a link leaves the site.
    private(set) var siteHost: String?

    private func settleAddressFlags() {
        let blank = address == nil
        if blankFlag != blank { blankFlag = blank }
        let mail = MailPage.isMail(pending ?? address)
        if mailFlag != mail { mailFlag = mail }
        let server = DevSites.name(address)
        if devServer != server { devServer = server }
        let host = address?.host()?.lowercased()
        if siteHost != host { siteHost = host }
    }

    /// The tab shows Mail, or is on its way there.
    var showsMail: Bool { Narrow.addressFlags ? mailFlag : MailPage.isMail(pending ?? address) }

    /// Whether this page's timers slow down while it is hidden (Web.hiddenTimers),
    /// as last set; nil before it ever was.
    @ObservationIgnored private var timersSlowed: Bool?

    /// A hidden page's timers slow down, but an agent's
    /// tab and a site kept awake (a chat, mail, music: AwakeSites) keep
    /// WebKit's pace, since they are wanted working out of sight.
    func paceHiddenTimers() {
        // Restoring a sleeping row only records its address. Do not build
        // WebKit controllers and rule lists just to set a preference on a
        // page that does not exist yet. The configuration getter applies
        // the current policy when that page is actually needed.
        guard Web.slowsHiddenTimers, let configuration = madeConfiguration else { return }
        let slow = !bench && !AwakeSites.shared.keeps(address)
        guard slow != timersSlowed else { return }
        timersSlowed = slow
        Web.hiddenTimers(configuration.preferences, slowDown: slow)
    }
    private(set) var loading = false {
        willSet { relay.send(\.loading, newValue) }
        didSet { if loading != oldValue { followLoading() } }
    }
    /// What the window shows of `loading` (the ring, Stop): on once a load
    /// has gone on for a moment, off as soon as it ends. A page from the
    /// back-forward cache, or a quick one from a fast server, is in before
    /// that moment, and nothing in the window is drawn again for it twice
    /// on the page's way to its first frame (docs/evidence/clean-gap-2026-10-13.md).
    private(set) var loadingShown = false
    @ObservationIgnored private var loadingTurn = 0

    private func followLoading() {
        loadingTurn += 1
        guard loading, Narrow.ring else {
            if loadingShown != loading { loadingShown = loading }
            return
        }
        let turn = loadingTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringAfter) { [weak self] in
            guard let self, self.loading, self.loadingTurn == turn, !self.loadingShown else { return }
            self.loadingShown = true
        }
    }

    /// How long a load goes on before the window shows it.
    static let ringAfter: TimeInterval = 0.15
    /// Unit tests: a page that never finishes, without WebKit.
    func pretendLoading(_ on: Bool) { loading = on }
    /// The page has painted its first text or picture: WebKit's first
    /// contentful paint, heard from the page. It still counts as loading,
    /// pictures and scripts still coming, but there is a page to read, and
    /// the ring at the tab's end goes then instead of at the load event,
    /// three seconds sooner on the median page measured.
    private(set) var drawn = false {
        willSet { relay.send(\.drawn, newValue) }
    }
    /// What the tab's end shows a ring for.
    var spinning: Bool { loadingShown && !drawn }
    /// The server has answered the navigation under way, and its page is
    /// coming in: false from its start until it commits (LoadBar).
    @ObservationIgnored private(set) var answered = true
    /// The navigation under way ended before it committed: failed, stopped
    /// or a download, not a page that came.
    @ObservationIgnored private(set) var stoppedEarly = false
    /// A navigation starting, committing or ending early, for LoadBar. Not
    /// published: nothing in SwiftUI is drawn again for it.
    let loadMoved = PassthroughSubject<Void, Never>()
    /// When the navigation under way began.
    var loadStarted: Date { Date(timeIntervalSince1970: navigating / 1000) }
    private(set) var hasBackHistory = false {
        willSet { relay.send(\.canGoBack, newValue || backSourceAvailable) }
    }
    /// Back can also end a tab opened by a link, while its source is open.
    var canGoBack: Bool { hasBackHistory || (backSourceAvailable && pin == nil && !kept && !bench) }
    var backSourceAvailable = false {
        willSet { relay.send(\.canGoBack, hasBackHistory || newValue) }
    }
    /// Only a link establishes this route, never an address or window.open.
    @ObservationIgnored var backLinkSource: Tab.ID?
    @ObservationIgnored var onBackAtStart: ((Tab) -> Bool)?
    /// Go Back from the flagged page in a tab that never showed a page:
    /// the tab closes (SafeBrowsing, Browser.closeUnshown).
    @ObservationIgnored var onCloseUnshown: ((Tab) -> Void)?
    private(set) var canGoForward = false {
        willSet { relay.send(\.canGoForward, newValue) }
    }
    /// What this tab's pages were asked about reaching on this Mac or the
    /// network, by page and kind: one card a page (LocalNetwork.swift).
    @ObservationIgnored var localAsked: Set<String> = []
    /// Set when the page never arrived, no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    var failure: String? {
        willSet {
            // A person's Try Again or a different address ends this stop.
            // Its old task advice must not follow them into the new page.
            if failure == StuckWatch.memoryStopped, newValue != StuckWatch.memoryStopped {
                StuckWatch.notices[id] = nil
            }
            relay.send(\.failure, newValue)
        }
    }
    /// Stopped at a certificate this Mac doesn't trust: a page of its own
    /// in place of the site, until you go back or on.
    var untrusted: Untrusted? {
        willSet { relay.send(\.untrusted, newValue) }
    }
    /// Stopped at an address on the local phishing list (SafeBrowsing,
    /// opt-in): a page of its own in place of the site, until you go back
    /// or on.
    var flagged: Flagged? {
        willSet { relay.send(\.flagged, newValue) }
    }
    /// How far down the page you are, nought to one, in reading mode only.
    /// The tab's own pill fills with it; any other page leaves it at nought.
    var reading: Double = 0 {
        willSet { relay.send(\.reading, newValue) }
    }

    /// True while the page has been stripped back to its article.
    private(set) var reader = false {
        willSet { relay.send(\.reader, newValue) }
        // Its card of themes goes with it (ReaderCard), and dark pages'
        // engine stands aside while it is up (DarkPages).
        didSet {
            if oldValue, !reader { ReaderCard.shared.left(id) }
            if oldValue != reader { darkReading(reader) }
        }
    }
    @ObservationIgnored private var everRead = false
    /// The page has an article worth offering reading mode for (see
    /// Reader.readable): the book among the doors shows while it does.
    private(set) var readable = false {
        willSet { relay.send(\.readable, newValue) }
    }
    @ObservationIgnored var fieldPageFacts = FieldPageFacts()
    @ObservationIgnored private var weighing: DispatchWorkItem?

    /// Asked a moment after the page has loaded, when it has laid itself
    /// out and the question costs a couple of milliseconds, and again after
    /// it changes its address without loading, as an app of a site does
    /// when it shows another article.
    private func weighReadable(after delay: TimeInterval) {
        weighing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let web = self.builtPage, !self.isBlank, !self.loading else { return }
            let address = self.address
            web.call(Reader.readableWhenReady, in: .yab, gesture: false) { [weak self, weak web] result in
                guard let self, self.builtPage === web, self.address == address, !self.loading else { return }
                let yes = (try? result.get()) as? Bool == true
                if self.readable != yes { self.readable = yes }
            }
        }
        weighing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func unreadable() {
        fieldPageFacts = FieldPageFacts()
        weighing?.cancel()
        if readable { readable = false }
    }

    /// The reader is laid over the page rather than put in its place (see
    /// Reader), so leaving it is the page as it was, with no reload. Only a
    /// page whose own script threw the reader away is loaded again.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard !isBlank else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            reading = 0
            page.runInYab(Reader.leave) { [weak self] answer in
                if (answer as? String) != "left" { self?.builtPage?.reload(fromOrigin: false) }
            }
            done(true)
            return
        }
        let web = self.page, address = self.address
        web.call(Reader.configure(.saved) + Reader.enterWhenReady, in: .yab) { [weak self, weak web] result in
            guard let self, self.builtPage === web, self.address == address else { done(false); return }
            let worked = (try? result.get()) as? String == "read"
            if worked {
                self.reader = true
                self.everRead = true
            }
            done(worked)
        }
    }

    static func refreshReaderThemes() {
        let script = Reader.configure(.saved)
        for tab in made.allObjects where tab.reader {
            tab.builtPage?.runInYab(script) { _ in }
        }
    }

    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    enum InstantState { case searching, loading }
    var instantState: InstantState? {
        willSet { relay.send(\.instantState, newValue) }
    }
    @ObservationIgnored var instantTask: Task<Void, Never>?
    @ObservationIgnored var instantOrigin: UUID?
    @ObservationIgnored var instantOriginURL: URL?

    var icon: NSImage? {
        willSet { relay.send(\.icon, newValue) }
        didSet {
            if icon != nil, instantState == .loading {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    if self?.instantState == .loading { self?.instantState = nil }
                }
            }
        }
    }
    var customMark: String? {
        willSet { relay.send(\.customMark, newValue) }
    }
    var displayIcon: NSImage? { CustomMarks.image(customMark) ?? icon }

    /// The page shift-clicked open from this one (LinkPeek), over it while
    /// it is in front and waiting for it while it isn't.
    var peek: Tab? {
        willSet { relay.send(\.peek, newValue) }
        didSet {
            guard peek !== oldValue else { return }
            if peek != nil {
                peekSince = Date()
                peekMarked = true
            } else {
                // Its mark stays long enough to go the way it goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    if self?.peek == nil { self?.peekMarked = false }
                }
            }
        }
    }
    /// Whether the tab's mark wears the peek's: a moment longer than `peek`.
    private(set) var peekMarked = false {
        willSet { relay.send(\.peekMarked, newValue) }
    }
    /// When the peek came: its mark pops in only then, and a mark drawn
    /// again later, the row laid out anew, is simply there.
    @ObservationIgnored private(set) var peekSince = Date.distantPast

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String { Tab.monogram(for: address) }

    /// A pin's letter for an address: its site's first, "•" for none.
    nonisolated static func monogram(for address: URL?) -> String {
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    /// The site's controls choose the bar, not a canvas or a video's glow.
    /// Two agreeing reads settle it; the current document and latest read
    /// alone may write it. Scrolling still updates only lightness (#334).
    func retone(fresh: Bool = false, color: Bool = true, confirming: Bool = false) {
        guard let web = builtPage, !isBlank, web.bounds.width > 0 else { return }
        reshade(web, fresh: fresh)
        guard color else { return }
        let ticket = toneGate.begin()
        web.run(Tone.probe, in: .yab, gesture: false) { [weak self, weak web] result in
            MainActor.assumeIsolated {
                guard let self, let web, self.builtPage === web, self.toneGate.current(ticket),
                      case .success(let answer) = result,
                      let read = PageToneReading(answer, size: web.bounds.size), read.href == web.url?.absoluteString,
                      // Covered for a moment, its full screen or a modal's
                      // veil: the color it was last seen in stays. Its next
                      // change (the veil gone, the screen given back) asks
                      // again (site-tone.js's watch).
                      !read.covered else { return }
                @MainActor func offer(_ color: NSColor?) {
                    guard let color, self.builtPage === web, self.toneGate.current(ticket) else { return }
                    if self.toneGate.offer(color, ticket: ticket, now: CACurrentMediaTime()) {
                        if self.tone != color { self.tone = color }
                    } else if !confirming {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak web] in
                            guard let self, let web, self.builtPage === web, self.toneGate.current(ticket) else { return }
                            self.retone(fresh: true, confirming: true)
                        }
                    }
                }
                if let color = read.color { offer(color); return }
                let shot = PageShot(rect: read.rect, width: 384, afterUpdates: fresh)
                web.snapshot(shot) { [weak self] image, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.builtPage === web, self.toneGate.current(ticket), read.href == web.url?.absoluteString else { return }
                        let row = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                            .map(NSBitmapImageRep.init(cgImage:))
                        offer(row.flatMap(Tone.settle))
                    }
                }
            }
        }
    }

    /// Looks again a few times while a page that just arrived finishes
    /// drawing: one look too early wears the page before it. A page already scrolled
    /// away from its top keeps the color it was given there.
    func retoneAsItSettles() {
        retoneArrival += 1
        let arrival = retoneArrival
        // Each look at a Chromium page is a whole window read back and encoded.
        for delay in builtPage?.engine == .chromium ? [1.0, 3.5] : [0.4, 1.0, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.retoneArrival == arrival else { return }
                self.retone(fresh: true, color: self.tone == nil || self.lastY <= 1)
            }
        }
    }

    /// How light the page is, all of what shows of it, read off a picture
    /// of it a few points across. The top bar is not the page: a dark bar
    /// over a white page is a white page to lay anything over. In between,
    /// a page as dark as it is light, it keeps what it last said, or
    /// says nothing and the window's own look stands.
    private func reshade(_ web: any PageHandle, fresh: Bool) {
        let document = toneGate.document
        // A Chromium page as it is shown, after a scroll: its helper reads it
        // off the page's surface scaled to a few pixels, and says only how
        // light it is (ChromiumPage.lightness). A fresh look, at an arrival,
        // waits for the page's next frame, as the picture below does.
        if !fresh, let page = web as? ChromiumPage, ChromiumPage.surfaceTone {
            page.lightness { [weak self] result in
                switch result {
                case .success(let light):
                    guard let self, self.builtPage === web, self.toneGate.document == document, !self.isBlank, let light else { return }
                    self.reshaded(light)
                case .failure(let error):
                    // A helper without page.tone: the picture, from now on.
                    if error is ChromiumPage.ToneUnavailable, !ChromiumPage.surfaceTone { self?.reshade(web, fresh: fresh) }
                }
            }
            return
        }
        web.snapshot(PageShot(width: 16, afterUpdates: fresh)) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.builtPage === web, self.toneGate.document == document, !self.isBlank,
                      let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let light = Tab.lightness(of: picture)
                else { return }
                self.reshaded(light)
            }
        }
    }

    /// What a look at how light the page is says to the bar over it.
    private func reshaded(_ light: CGFloat) {
        let said: ColorScheme? = light < 0.4 ? .dark : light > 0.6 ? .light : shade
        if shade != said { shade = said }
        let below: ColorScheme = light < 0.5 ? .dark : .light
        if under != below { under = below }
        if let said, !shy, let host = address?.host() { Tab.shades[host] = said }
    }

    /// The perceived brightness of a picture, on average: 0 black, 1 white.
    /// Drawn once into a few bytes of sRGB and summed there: asked of each
    /// pixel as a color, it took some 5 ms of the main thread after every
    /// page, the moment a page gone back to should come.
    /// Nothing for a picture mostly see-through: a page not drawn yet over
    /// no ground of its own (StageView.groundless, a tab just opened to a
    /// slow site) is no color at all, and read as black it turned the whole
    /// window dark for as long as the site took (#408).
    static func lightness(of picture: CGImage) -> CGFloat? {
        let w = min(picture.width, 32), h = min(picture.height, 32)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sum = 0, cover = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += 299 * Int(bytes[i]) + 587 * Int(bytes[i + 1]) + 114 * Int(bytes[i + 2])
            cover += Int(bytes[i + 3])
        }
        // Premultiplied: the colors over the cover they have.
        guard cover * 2 >= w * h * 255 else { return nil }
        return CGFloat(sum) / CGFloat(cover * 1000)
    }

    /// A destination's metadata must not inherit the previous document's
    /// host fallback while its response is pending. Icon requests started
    /// by that document lose ownership at the same boundary.
    private(set) var awaitingDocumentMetadata = false

    func prepareDocumentMetadata(for url: URL?) {
        awaitingDocumentMetadata = true
        resetCountIconProof()
        engineTitle = nil
        retainingEngineTitle = false
        title = ""
        Favicons.shared.navigationStarted(for: self)
        icon = Tab.ownIcon(url) ?? url.flatMap(Favicons.shared.pageIcon)
    }

    /// Both engines commit a new document, even though their history and
    /// script bookkeeping after that boundary are different.
    func documentMetadataCommitted() { awaitingDocumentMetadata = false }

    /// The mark for where it is: Yab's own page's, or the site's kept icon.
    func adoptIcon() {
        if let own = Tab.ownIcon(address) { icon = own; return }
        guard let url = address, Favicons.site(url) != nil else { return }
        icon = Favicons.shared.cached(page: url)
        guard icon == nil else { return }
        // Restored/imported tabs may sleep indefinitely without a bitmap
        // in the cache. Wait until restore has also set their custom mark
        // and privacy, then ask only for the site's public icon, never the
        // sleeping page. A tab woken or moved meanwhile uses its page's
        // normal icon discovery instead.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.address == url, self.pending == url,
                  self.icon == nil, !self.shy, self.customMark == nil,
                  Tab.ownIcon(url) == nil else { return }
            Favicons.shared.fetch(page: url)
        }
    }

    /// Yab's own page's mark, on its tab and on its row in the field; nil
    /// for a site, which wears its kept icon.
    static func ownIcon(_ url: URL?) -> NSImage? {
        // What Yab keeps about you: a notebook.
        if KnowPage.isKnow(url) { return Glyphs.image("notes", side: 16) }
        // The mail page wears its own mark, as a pin and as a tab: the
        // envelope emoji, black on a light ground (MailPage.mark).
        if MailPage.isMail(url) { return MailPage.mark }
        // A page an agent published: its card's tile, the artifact's icon on Claude's color.
        if ArtifactPages.isPage(url) { return ArtifactCard.tile(url?.host().flatMap { ArtifactPages.shared.entry($0.lowercased())?.icon }) }
        return nil
    }

    /// Where a tab is, as its row in the field says it beside the name: a
    /// site's address. Yab's own pages have none worth saying, yab://mail
    /// read "mail mail"; the mail page says the account its column is on.
    static func place(_ url: URL) -> String {
        guard url.scheme == DiaryPage.scheme else { return Address.shown(url) }
        return MailPage.isMail(url) ? MailPage.place : ""
    }

    /// True while the caret is in something on the page that takes typing.
    var typing = false {
        willSet { relay.send(\.typing, newValue) }
    }
    /// Something typed and not yet sent, as the page last said (Forms.swift).
    /// Kept for a page that may stop answering: then it can't be asked.
    var draft = false
    /// Stuck out of sight while holding a draft: asked about on coming back
    /// (Stuck.swift).
    var stuckDraft = false
    /// Since when the page has not answered: WebKit said so
    /// (`_webViewWebProcessDidBecomeUnresponsive`), or the page in front
    /// missed its pings while its process spun. Nil once it answers, ends,
    /// or its view goes. Every way out reads it (Stuck.swift, `goFresh`).
    var deaf: Date?
    /// Not asked again before this, after Wait on "stopped answering".
    @ObservationIgnored var deafQuiet = Date.distantPast
    /// The card on it is the one asked for a page that went deaf in front of
    /// you, not the one for a draft left behind (`stuckDraft`).
    var deafAsked = false
    /// True while the page has taken over the screen.
    var immersed = false {
        willSet { relay.send(\.immersed, newValue) }
    }

    /// True while this tab's page is out in the little window.
    var floating = false {
        willSet { relay.send(\.floating, newValue) }
    }

    /// A sideways swipe in progress, handed straight to the view that
    /// draws it (PullView). Not published: it changes with every event of
    /// the fingers, and published, each one drew the whole page's SwiftUI
    /// over again for a pill.
    @ObservationIgnored var pull: Pull? {
        didSet { if pull != oldValue { pullView?.show(pull, of: self) } }
    }
    /// Where this tab's page is on screen now, the one view that draws its
    /// swipe.
    @ObservationIgnored weak var pullView: PullView?

    /// The color of the site's own top bar, for the strip to wear too.
    /// Nothing until there is a page to ask, or when it won't say.
    private(set) var tone: NSColor? {
        willSet { relay.send(\.tone, newValue) }
    }
    /// Whether the page is a light one or a dark one, as a whole, what ⌘L's
    /// field and the veil under it are drawn in, whatever the window's own
    /// look. Nothing until it has been seen, and nothing on a blank tab.
    private(set) var shade: ColorScheme? {
        willSet { relay.send(\.shade, newValue) }
    }
    /// What stands over the page wears this (HUD.surface(over:)): the same
    /// look as `shade`, only split at the middle, with no in between. A
    /// mid-gray page was neither, and the dark HUD on it was hard to find.
    private(set) var under: ColorScheme? {
        willSet { relay.send(\.under, newValue) }
    }
    /// The last shade seen of each site, for the same site's next page while
    /// it is still coming in: a dark site loading is not a white one.
    private static var shades: [String: ColorScheme] = [:]

    /// A site Dark pages darkens: the shade it was last seen in is a
    /// light page's, and would light the ground under its first frame
    /// (StageView.fill). Learned again from the darkened page.
    static func forgetShade(_ url: URL?) {
        guard let host = url?.host() else { return }
        shades[host] = nil
        shades[host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host] = nil
    }
    /// A look at how light the page is, on its way after a scroll. Its
    /// color stays what it was given as it arrived (feedback #334).
    @ObservationIgnored private var retoning = false
    /// When the page will have been still long enough for that look, and
    /// when the last one was taken.
    @ObservationIgnored private var retoneStill: CFTimeInterval = 0
    @ObservationIgnored private var retonedScrolling: CFTimeInterval = 0
    /// How long a scroll stops before the look, and the longest a scroll
    /// goes on without one.
    static let retoneSettle: CFTimeInterval = 0.15
    static let retoneEvery: CFTimeInterval = 1

    private func retoneWhenStill(in wait: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, wait)) { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let due = min(self.retoneStill, self.retonedScrolling + Tab.retoneEvery)
            if now < due - 0.01 { return self.retoneWhenStill(in: due - now) }
            self.retoning = false
            self.retonedScrolling = now
            self.retone(color: false)
        }
    }
    /// Which arrival the looks after it belong to: a newer page's own
    /// looks take over, an older page's left over say nothing.
    @ObservationIgnored private var retoneArrival = 0
    @ObservationIgnored private var toneGate = PageToneGate()

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        PageAppearance.rememberZoom(Double(zoom), host: host)
    }

    func applyRememberedZoom() {
        let webpage = address?.scheme?.hasPrefix("http") == true
        let handle = page
        let fonts = PageFonts.read()
        if let chromium = handle as? ChromiumPage {
            chromium.minimumFont(webpage ? min(24, max(0, fonts.minimum)) : 0)
            chromium.pageFamilies(PageFamilies.names(fonts))
        } else if let web = WebKitOnly.page(handle, for: "Native minimum font size") {
            web.configuration.preferences.minimumFontSize = webpage
                ? CGFloat(min(24, max(0, fonts.minimum))) : 0
            PageFamilies.apply(fonts, to: web.configuration.preferences)
        }
        let kept = webpage ? PageAppearance.zoom(host: address?.host(), privatePage: shy) : 1
        guard abs(CGFloat(kept) - handle.pageZoom) > 0.004 else { return }
        handle.pageZoom = CGFloat(kept)
        zoom = CGFloat(kept)
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page, the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    private(set) var zoom: CGFloat = 1 {
        willSet { relay.send(\.zoom, newValue) }
    }

    /// Where the page is and which way it just went, for anything that wants
    /// to follow along.
    @ObservationIgnored var onScroll: ((Tab, Double, Double) -> Void)?
    @ObservationIgnored var onZoom: ((Tab, CGFloat) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    /// When it last stopped playing sound: for the minute after, it still
    /// counts as playing (Sleep.swift, `heardGrace`).
    @ObservationIgnored var heardAt: Date?
    var noisy = false {
        willSet { relay.send(\.noisy, newValue) }
        didSet { if noisy != oldValue { onSound?(self) } }
    }
    /// Silenced from the tab's menu. The tab's to keep rather than the
    /// page's: it holds across every page the tab goes to, and across the
    /// view being given back while the tab sleeps and built again.
    private(set) var muted = false {
        willSet { relay.send(\.muted, newValue) }
        didSet { if muted != oldValue { onSound?(self) } }
    }
    /// The noise started or stopped, or was silenced or let back in: for
    /// the notes a tab sings as it starts (Chorus).
    @ObservationIgnored var onSound: ((Tab) -> Void)?

    /// Supersedes a pending saved-credential lookup on a newer submission.
    @ObservationIgnored var passwordOfferCheck = UUID()

    /// A password this tab has just signed in with, waiting to be kept,
    /// asked over the page while you are here, a key on the tab once put
    /// off. See Keep.swift.
    var offer: PasswordOffer? {
        willSet { relay.send(\.offer, newValue) }
    }
    /// A card or an address this tab has just paid or shipped with, waiting
    /// to be kept, the same way. See WalletKeep.swift.
    var payOffer: PayOffer? {
        willSet { relay.send(\.payOffer, newValue) }
    }
    /// A card or an address just kept here: its mark stays on the tab for a
    /// beat after landing, then the site's comes back.
    var payLanded: String? {
        willSet { relay.send(\.payLanded, newValue) }
    }
    /// What the page has said about its cards and addresses (WalletForms).
    let wallet = WalletWatch()

    /// What the page is waiting to be told, an alert, a confirm, the
    /// camera, the first asked over the page. See Asks.swift.
    var asks: [PageAsk] = [] {
        willSet { relay.send(\.asks, newValue) }
    }
    /// The camera and the microphone, as the page has them now: the dot on
    /// the tab's mark.
    private(set) var camera: PageMediaState = .none {
        willSet { relay.send(\.camera, newValue) }
        didSet { if camera != oldValue { onCapture?(self) } }
    }
    private(set) var microphone: PageMediaState = .none {
        willSet { relay.send(\.microphone, newValue) }
        didSet { if microphone != oldValue { onCapture?(self) } }
    }
    /// The screen or a window, shown by the page (`getDisplayMedia`): what
    /// WebKit keeps as `_displayCaptureState`, apart from the other two.
    private(set) var screen: PageMediaState = .none {
        willSet { relay.send(\.screen, newValue) }
        didSet { if screen != oldValue { onCapture?(self) } }
    }
    /// The call's devices and whether its page can share the screen, as
    /// the page's own menus have them (CallStage). Nil before first read.
    var callDevices: CallDevices? {
        willSet { relay.send(\.callDevices, newValue) }
    }
    /// Told when either changes: the browser keeps its calls by it (Calls.swift).
    @ObservationIgnored var onCapture: ((Tab) -> Void)?
    /// The call's own switches, where yab can read them (Meet, Zoom; CallRelay):
    /// true when the page has the microphone, or the camera, off. A page
    /// that mutes itself keeps its track and tells WebKit nothing, so this,
    /// not `microphone`, is what says whether you are heard there.
    var pageMic: Bool? {
        willSet { relay.send(\.pageMic, newValue) }
        didSet { if pageMic != oldValue { onCapture?(self) } }
    }
    var pageCamera: Bool? {
        willSet { relay.send(\.pageCamera, newValue) }
        didSet { if pageCamera != oldValue { onCapture?(self) } }
    }
    private let callRelay = CallRelay()
    /// The page's getDisplayMedia, yab's (Share.swift): what it asks, and
    /// whether this tab's page is shown something, or this tab is shown.
    private let shareRelay = ShareRelay()
    @ObservationIgnored var onShare: ((Tab, [String: Any], PageFrame) -> Void)?
    /// A video of this page in WebKit's own Picture-in-Picture window, the
    /// system's, as the page's own button puts it there (FloatPiP.swift).
    var pictureInPicture = false
    var sharing = false {
        willSet { relay.send(\.sharing, newValue) }
    }
    var seen = false {
        willSet { relay.send(\.seen, newValue) }
    }
    /// Where the page was when its call began: a meeting that moves on to
    /// its "you left" page is still that meeting.
    var callStarted: URL?
    /// The site told to stop asking, until the tab shows another document.
    var hushed: String?
    /// How many alerts, confirms and prompts the document in front has
    /// asked: from the second the card offers to stop them.
    @ObservationIgnored var pageDialogs = 0

    /// A pin or a kept tab is one tab to the person, though every window
    /// holds a tab and a page of its own for it (SharedPins.swift,
    /// KeptEverywhere.swift): silenced in one window, it is silenced in
    /// every one, like a single tab (feedback #2018: the pin muted
    /// in one window pinged from the other's copy, or from the copy left
    /// in its place when its page went over).
    func mute(_ on: Bool) {
        muteHere(on)
        for copy in copies { copy.muteHere(on) }
    }

    private func muteHere(_ on: Bool) {
        guard engineKind == .chromium || AudioWatch.canMute else { return }
        muted = on
        // Chromium discards the document but keeps its controller. A mute
        // changed while asleep must reach that controller too, before its
        // queued restore; otherwise it wakes with the old WebContents mute.
        let audioPage: (any PageHandle)? = builtPage ?? sleepingChromium
        (audioPage as? any PageAudioControl)?.setAudioMuted(on)
    }

    /// A copy made in another window, or this window's taken in under the
    /// list's key, comes in silenced when one already there is. Only ever
    /// silenced this way: two rows joined (Pins turned to In Every Space)
    /// keep the mute either had, and letting it back in is `mute`'s.
    func takeCopiesMute() {
        guard !muted, copies.contains(where: \.muted) else { return }
        muteHere(true)
    }

    /// What the page hands back when you point at something and click it.
    @ObservationIgnored var onPick: ((Tab, String, String, String, CGRect?) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    @ObservationIgnored var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left.
    @ObservationIgnored var onField: ((Tab, CGRect?) -> Void)?
    /// The site the sign-in was sent from, not the one it landed on,
    /// then the name and the password, and whether that page came over
    /// plain http.
    @ObservationIgnored var onCredentials: ((Tab, String, String, String, Bool, PageFrame?) -> Void)?
    /// The caret has entered or left a box a card or an address goes in.
    @ObservationIgnored var onWalletField: ((Tab, WalletField?) -> Void)?
    /// A card, an address or both went through on the page: the host it
    /// was sent from.
    @ObservationIgnored var onPaid: ((Tab, SeenCard?, StreetAddress?, String) -> Void)?
    /// The page was clicked while recent files hung from its file box.
    @ObservationIgnored var onFilesAway: ((Tab) -> Void)?
    @ObservationIgnored var onPickEnd: ((Tab) -> Void)?
    @ObservationIgnored var onPickTrouble: ((Tab, String) -> Void)?
    /// The picture a right-click last landed on, and when: its menu's Copy
    /// Image, Download Image and Open Image are Yab's (ImageMenu.swift).
    @ObservationIgnored var pointedImage: (url: URL, at: CFTimeInterval)?
    @ObservationIgnored var pointedImageFrame: WKFrameInfo?
    @ObservationIgnored var pointedImagePolicy = ""
    /// Where that picture stood in the page's CSS pixels, when it was in the
    /// page's own frame: Capture Image lifts it off from there.
    @ObservationIgnored var pointedImageBox: CGRect?
    /// The video or sound a right-click last landed on, and when: its
    /// menu's Download Video is Yab's (VideoSave.swift).
    @ObservationIgnored var pointedMedia: (media: PointedMedia, at: CFTimeInterval)?
    @ObservationIgnored var onMediaSave: ((Tab, PointedMedia) -> Void)?
    /// The mailto: link a right-click last landed on, and when: its menu
    /// offers Copy Email Address (PageView.emailHere).
    @ObservationIgnored var pointedLink: (url: URL, at: CFTimeInterval)?
    @ObservationIgnored private var lookedAtPictures: CFTimeInterval = -.infinity

    /// The pointer rested on a picture: WebKit reads the page's pictures,
    /// so their words can be selected by hand. Once in a while at most:
    /// WebKit passes over pictures it has read, and new ones come with
    /// scrolling.
    func lookAtPictures() {
        let now = CACurrentMediaTime()
        guard now - lookedAtPictures > 5, let web = webKitOnly("Native image text recognition", build: false) else { return }
        lookedAtPictures = now
        PictureReader.shared.pageReads += 1
        web.lookAtPictures()
    }
    /// One of those rows picked, for the picture.
    @ObservationIgnored var onImageAct: ((Tab, ImageAct, URL, Bool) -> Void)?
    @ObservationIgnored var onCapturePage: ((Tab) -> Void)?
    /// A picture's words put on the pasteboard from its menu.
    @ObservationIgnored var onPictureCopied: ((Tab) -> Void)?
    /// "Add to yab" was pressed on the Chrome Web Store page this tab shows.
    @ObservationIgnored var onStoreAdd: ((Tab) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps a view built for an
    /// extension to that extension's pages, so the tab is swapped for one
    /// built for the address (Browser.replaceBlank).
    /// Search with… in the page's menu, on the words picked there.
    @ObservationIgnored var onSearch: ((Tab, String) -> Void)?
    @ObservationIgnored var onSelectedURL: ((Tab, URL, NSEvent.ModifierFlags) -> Void)?
    /// The engine Search with… names, its space's (EngineChoice).
    @ObservationIgnored var onSearchName: ((Tab) -> String)?
    @ObservationIgnored var onSelectionCommand: ((Tab, String?) -> Void)?
    @ObservationIgnored var onSelectionMenu: ((Tab) -> [SelectionCommand])?
    @ObservationIgnored var onSelectionTouch: ((Tab) -> Void)?
    @ObservationIgnored var onSelectionPause: ((Tab) -> Void)?
    /// A Force Click on the page, where it was in the page's view (LinkPeek).
    @ObservationIgnored var onForceClick: ((Tab, CGPoint) -> Void)?
    /// A press on the page firming up towards a Force Click, 0 to 1, and 0
    /// when it lets go (LinkPeek's press dim).
    @ObservationIgnored var onPress: ((Tab, CGFloat) -> Void)?
    /// Whether a Force Click on a link peeks at it, read as each page is
    /// armed: the Mac's own look at the link is held back then.
    @ObservationIgnored var forcePeeks: (() -> Bool)?
    /// The tab this one was opened from, by a link or a page, for a swipe
    /// back past the start of this one's history, and to return to when this
    /// tab closes. Unlike `opener`, it also covers links opened by hand.
    @ObservationIgnored var from: Tab.ID?
    /// The pin, kept tab or filed one whose page this tab is a copy of,
    /// made to be its half of a pair while it stays where it is
    /// (Browser.carried). The copy goes with the pair, as in Arc, unless
    /// it was taken to another page since (Browser.carriedHome).
    @ObservationIgnored var carriedFrom: Tab.ID?
    /// The page it was made on, for a copy taken to another site since.
    @ObservationIgnored var carriedPage: URL?
    /// The tab whose page opened this one beside it, a ⌘-click, a middle
    /// click, a link to a new tab or window.open: the next such tab from
    /// the same page goes after this one (Placement.swift).
    @ObservationIgnored var linkedFrom: Tab.ID?
    /// That tab's title while it is open, and bringing it to the front, the
    /// browser's to answer.
    @ObservationIgnored var fromTitle: ((Tab) -> String?)?
    @ObservationIgnored var onFrom: ((Tab) -> Void)?
    /// The mouse's side buttons and their swipe, back (false) or forward
    /// (true), the browser's to take the way its toolbar's Back does.
    @ObservationIgnored var onStep: ((Tab, Bool) -> Void)?
    /// Words to look for in the whole history, from the swipe's panel.
    @ObservationIgnored var onSearchHistory: ((Tab, String) -> Void)?
    @ObservationIgnored var onCross: ((Tab, URL) -> Void)?
    /// The history of the tab this one stands in for (Browser.replaceBlank),
    /// put under the first page it opens so Back still goes there.
    @ObservationIgnored var backList: Any?
    /// The extension whose store page has its own "Add to yab" button in
    /// place, so the bar at the bottom of the window doesn't offer it twice.
    var storePlaced: String? {
        willSet { relay.send(\.storePlaced, newValue) }
    }

    private let scrollRelay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    private let walletRelay = WalletRelay()
    private let images = ImageRelay()
    private let shop = StoreRelay()
    private let finds = FindRelay()
    /// What a page on this Mac's own server has logged and requested since
    /// it loaded (DevMode.swift).
    let devLog = DevLog()
    private let devRelay = DevRelay()
    private let recordRelay = RecordRelay()
    private let badgeRelay = BadgeRelay()
    private let windowRelay = WindowRelay()
    private let iconRelay = IconRelay()
    private let watchRelay = WatchRelay()
    private let jsonRelay = JSONRelay()
    /// Heard although it isn't local, while the card is out over it.
    @ObservationIgnored var devListening = false
    /// WebKit's Device Settings overridden on this page while its inspector
    /// is up, and the appearance it is told (DevTools.swift).
    var devOverrides: Set<DevOverride> = [] {
        willSet { relay.send(\.devOverrides, newValue) }
    }
    var devAppearance: String? {
        willSet { relay.send(\.devAppearance, newValue) }
    }
    /// Device mode: the page at a phone's or a tablet's size (DevDevice.swift).
    var device: DeviceMode? {
        willSet { relay.send(\.device, newValue) }
    }
    /// The document in front came as JSON, and how the viewer shows it
    /// (JSONView.swift). Nil for every other page.
    var json: JSONPage? {
        willSet { relay.send(\.json, newValue) }
    }
    /// The main documents' answers lately, by address, for the JSON door's
    /// card: a page brought back from the cache gets no new one.
    @ObservationIgnored private(set) var responses: [URL: PageResponse] = [:]
    @ObservationIgnored private var responseOrder: [URL] = []
    /// When the main document was asked for, to say how long it took.
    @ObservationIgnored var askedAt: CFTimeInterval?
    /// The answer to the document in front.
    var jsonResponse: PageResponse? { address.flatMap { responses[$0] } }

    func heard(_ response: PageResponse) {
        responses[response.url] = response
        responseOrder.removeAll { $0 == response.url }
        responseOrder.append(response.url)
        if responseOrder.count > 8 { responses.removeValue(forKey: responseOrder.removeFirst()) }
    }
    /// The page's steps written down as you take them (DevRecorder.swift).
    let recorder = Recorder()
    /// Rulers, guides and distances drawn over a local page (Measure.swift).
    /// Set through `measure(_:)`, which tells the page.
    var measuring = false {
        willSet { relay.send(\.measuring, newValue) }
    }
    private let measureRelay = MeasureRelay()
    private let itemRelay = ItemRelay()
    /// What Measure's dock shows (MeasureDock.swift), heard from the page.
    let measureModel = MeasureModel()
    /// Copy for Agent in Measure's dock, or ⌘C: the Markdown, to the clipboard.
    @ObservationIgnored var onMeasureCopy: ((Tab, String) -> Void)?
    /// Open in Elements in Measure's dock: the card on WebKit's Elements,
    /// the element picked there, found by a selector only it answers.
    @ObservationIgnored var onMeasureElements: ((Tab, String) -> Void)?
    /// The Developer Tools card is out over this tab (DevTools.swift).
    @ObservationIgnored var toolsOpen: ((Tab) -> Bool)?
    /// Its Developer Tools were out, on this pane, when another tab came
    /// in front: they are this tab's, away while it is, and
    /// back with it (Browser.devFollows).
    @ObservationIgnored var devKept: DevPane?
    /// Chrome's DevTools of this tab, while it has a card (ChromiumDevTools.swift).
    @ObservationIgnored var chromiumDev: ChromiumDevFrontend?
    /// Goes up as they come up, for the card to show them.
    var chromiumDevReady = 0
    /// Documents committed in this tab, counted: its inspector put away
    /// while another tab was in front comes back to the same document only
    /// if this has not moved (DevReturn.swift).
    @ObservationIgnored var devDocument = 0
    /// What its inspector held when another tab in front put it away, to be
    /// given back when it comes up again on the same document.
    @ObservationIgnored var devReturn: DevReturn?
    /// Console's and Network's words and picks as it left them.
    @ObservationIgnored var devPanes: DevPanes?
    /// WebKit's Inspect Element about to run on this page: the card out on
    /// Elements first, so WebKit docks its inspector there.
    @ObservationIgnored var onWebInspectElement: ((Tab, @escaping () -> Void) -> Void)?
    @ObservationIgnored var onTranslationMenu: ((Tab) -> [NSMenuItem])?
    /// What this tab is looking for on its page, and where it has got to.
    /// See Find.swift.
    @ObservationIgnored lazy var finder = Finder(tab: self)
    private let passkeyRelay = PasskeyRelay()
    /// Dark pages (DarkPages.swift): how the page in this tab is now, for
    /// Site Controls' row and the View menu, and what goes with it.
    var dark: DarkShown = .none {
        willSet { relay.send(\.dark, newValue) }
    }
    @ObservationIgnored let darkState = DarkTabState()
    private let ears = AudioWatch()
    /// WebKit's now-playing session for this page, heard (Tune.swift).
    let tuneWatch = TuneWatch()
    /// What the page is playing, named; nil without a session.
    var tune: Tune?
    /// The tune changed: the browser's player hears it.
    @ObservationIgnored var onTune: ((Tab) -> Void)?
    /// The page wanted a passkey this build can't give (PasskeyHint).
    @ObservationIgnored var onPasskeysMissing: ((Tab, PasskeyHint.Ask) -> Void)?
    @ObservationIgnored private(set) var lastY: Double = 0

    /// How the document on show came in, for feedback's diagnostics
    /// (FeedbackDiagnostics.page, #155): woken from sleep, its view in no
    /// window, behind the tab in front. Set as it commits.
    struct Arrival { var woken = false, outOfWindow = false, behind = false }
    @ObservationIgnored private(set) var arrival = Arrival()
    /// Woken from sleep and not yet committed (`wake`).
    @ObservationIgnored private var waking = false

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool
    /// When this tab was opened as the act of going private, from a tab
    /// that kept things, the moment `Stealth` plays once. Nil for every
    /// other private tab, and for every tab that is not one.
    var hushedAt: Date?

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see, but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    @ObservationIgnored private(set) var bench: Bool

    /// A cloud assistant's tab belongs to this space, even when another
    /// space shares its cookies. Local agents' tabs may follow the user.
    @ObservationIgnored var assistantSpace: UUID?

    /// An agent's tab you kept (Folders.keep): yours from here on, in the
    /// session and the history like any other.
    func adopt() {
        bench = false
        assistantSpace = nil
        paceHiddenTimers()
    }

    /// The agent session working in this tab, when an agent opened it: its
    /// mark on the tab, and whose it is to act in. Set once the tab is in
    /// the row, its task's folder takes it at once, in the same turn, not
    /// a turn later after the row has drawn it loose.
    var agent: String? {
        willSet { relay.send(\.agent, newValue) }
        didSet {
            guard agent != oldValue else { return }
            let windows = [Folders.shared.browser].compactMap { $0 } + BrowserWindows.shared.browsers
            guard let owner = (delegate as? Browser) ?? windows.first(where: { $0.everyTab.contains { $0 === self } }) else { return }
            owner.placeAssistantTab(self)
            owner.folderBook.refresh()
        }
    }
    /// What the agent needs you to do here, sign in, pass a captcha, while
    /// it waits for you.
    var handoff: String? {
        willSet { relay.send(\.handoff, newValue) }
        // Every writer, including sign-in windows and folder rechecks, uses
        // the same causal question and the same notice lifecycle.
        didSet { AgentNotices.shared.changed(self) }
    }
    var handoffNotice: AgentNotices.Hand?
    var handoffDisplayCause: AgentNotices.Cause?
    private(set) var handoffSuperseded = false
    private(set) var supersededHandoffNotice: AgentNotices.Hand?
    var nextHandoffCause: AgentNotices.Cause?
    private var inheritedHandoff: AgentNotices.Hand?

    /// A window opened by a waiting page continues that page's question.
    /// Replacing its WebKit configuration keeps that very question too.
    func inheritHandoff(from tab: Tab) {
        inheritedHandoff = tab.handoffNotice
        if id == tab.id {
            // The old object can still be held by an in-flight recheck.
            // It must never reclaim this same tab's notice membership.
            tab.handoffSuperseded = true
            tab.supersededHandoffNotice = tab.handoffNotice
            tab.handoffNotice = nil
        }
        handoff = tab.handoff
    }

    func takeInheritedHandoff() -> AgentNotices.Hand? {
        defer { inheritedHandoff = nil }
        return inheritedHandoff
    }
    /// The rest of what it said, opened upward at the page's foot: the request
    /// itself is kept to a line.
    var handoffDetail: String? {
        willSet { relay.send(\.handoffDetail, newValue) }
    }
    /// What it asks you to pick from, when it does (`ask`), and what you
    /// picked, for it to read back once the question is gone.
    var choices: [String] = [] {
        willSet { relay.send(\.choices, newValue) }
    }
    var chosen: String?
    /// A task's whole answer, left at the foot of the page it worked on
    /// until you put it away: which task, and what it said.
    var answer: (session: String, text: String)? {
        willSet { relay.send(\.answer, newValue) }
    }
    /// Files an agent was allowed to give this page, for the next file
    /// picker the page opens, soon: handed over without the picker.
    var uploading: (files: [URL], until: Date)?
    /// An agent at work in this tab of yours: its face on the tab while it
    /// is, but the tab stays yours, where it is, and isn't tidied away
    /// with the agent's own.
    var guest: String? {
        willSet { relay.send(\.guest, newValue) }
    }
    /// Sent to a space by Move to › Space while an agent was at work in
    /// it: it stays in that space rather than going along into every one
    /// with the agent (Browser.travels).
    @ObservationIgnored var stays = false
    /// The space a tab that goes along with you (an agent at work in it)
    /// came from, while it is in another: its folder and kept place
    /// are that space's, not drawn here (Folders.nests), and it goes back
    /// there once it no longer goes along (Browser.sendHome).
    @ObservationIgnored var homeSpace: UUID?

    /// A call begun or over without a page holding the microphone: for
    /// tests, as WebKit's capture state would say it.
    func pretendCall(_ on: Bool) {
        microphone = on ? .active : .none
    }
    /// A task asking you something here without being let in: a pick
    /// from a chat with no tab of its own. Its card stands at the page's
    /// foot; its face doesn't, nor its end (docs/chat-asks.md).
    var asker: String? {
        willSet { relay.send(\.asker, newValue) }
    }
    /// What a finished task left here that you haven't come to see: the
    /// tick at the tab's end, or its face looking down when it couldn't
    /// finish, until the tab is in front of you (AgentFeed).
    var unread: AgentFeed.Unread? {
        willSet { relay.send(\.unread, newValue) }
    }
    /// An AI chat or a builder at work here, since when and its word
    /// (ChatBusy): a spinner at the mark's bottom corner, a line on the card.
    var chatBusy: ChatBusy.Busy? {
        willSet { relay.send(\.chatBusy, newValue) }
    }
    /// Its answer came while you were elsewhere, and you haven't come to
    /// the tab since: a blue dot where the spinner was, read as `unread` is.
    var chatDone: ChatBusy.Done? {
        willSet { relay.send(\.chatDone, newValue) }
    }
    /// The agent whose end you have seen here, or stopped: the tab's end is
    /// an ordinary tab's again, until an agent works in it once more.
    var settled: String? {
        willSet { relay.send(\.settled, newValue) }
    }
    /// Yab's own page a run answers on (Get to Know's notebook,
    /// KnowPage): in its folder, first, but not the agent's to touch.
    var answering: String?
    /// A task begun from this page of yours, in the chat's column: the tab
    /// stands in that task's folder with the agent's, still yours, and
    /// isn't put away with them.
    var began: String?
    /// A yes the agent is waiting on here: to use this tab at all, or to
    /// press a button that sends, pays or deletes. Asked the way a sign-in
    /// is (`handoff` holds its words meanwhile), answered on its card.
    var permit: AgentPermit? {
        willSet { relay.send(\.permit, newValue) }
    }
    /// Sessions you let into this tab, when agents ask first.
    var allowed: Set<String> = []
    /// Sessions you told "not now" to using this tab.
    var refused: Set<String> = []
    /// Sessions you told "not now" to a press here, for their next try at
    /// one to hear it.
    var declined: Set<String> = []
    /// The one press you said yes to: that session, that ref, once, soon.
    var approved: (session: String, ref: String, at: Date)? {
        // Taken by the call it was for: what it sends has gone.
        didSet { if oldValue != nil, approved == nil { Agents.shared.consumed(self) } }
    }
    /// A yes to something that sends, while it goes: the card stays in the
    /// chat's field saying Sending, then shrinks away, or says why it didn't.
    var sending: AgentSending? {
        willSet { relay.send(\.sending, newValue) }
    }

    /// Whoever is at work in this tab, its own agent or a guest in yours.
    var worker: String? { permit?.isNative == true ? permit?.session : agent ?? guest }
    /// Whoever asks here: the one at work, or one asking without being let in.
    var askedBy: String? { worker ?? permit?.session ?? asker }

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    @ObservationIgnored var opener: Tab.ID?
    /// When the opener's script opened this one, window.open rather than a
    /// link: the two pages can still talk, and a sign-in here hands its
    /// answer back to the opener, which stays awake for it (Sleep.swift).
    @ObservationIgnored var scripted: Date?
    /// The site it first showed, a sign-in's.
    @ObservationIgnored var firstSite: String?
    /// When a link opened it as a tab of its own: shut again soon after, it
    /// was only a look, what Peek is for (Teach.swift).
    @ObservationIgnored var linkBorn: Date?
    /// The server on this Mac yab itself last sent the tab to, typed, a
    /// bookmark, a command's link: its pages are ones you went to, even
    /// from a site elsewhere (DevSites.sentFromAfar).
    @ObservationIgnored var sentLocal: String?

    /// Whether the opener still waits on this page: opened by its script,
    /// awake, less than ten minutes ago, and still on the site it first
    /// showed or back on the opener's, where a sign-in lands to hand its
    /// answer over. Gone anywhere else, it is a tab of its own. A
    /// window.open with noopener can't be told from the outside, and these
    /// bounds are what it costs.
    func waits(for opener: Tab) -> Bool {
        guard let scripted, !asleep, Date().timeIntervalSince(scripted) < 10 * 60 else { return false }
        guard let first = firstSite, let host = address?.host(), !host.isEmpty else { return true }
        let here = Browser.site(host)
        return here == first || here == opener.address?.host().map(Browser.site)
    }

    /// A window a page opened at a size of its own, or without a toolbar: a
    /// pop-up, not a link. It is named by its site, never by its title,
    /// which the page chooses: "Sign in with Google" over somebody else's
    /// address included.
    var popup = false
    /// The windows this page asked for and wasn't let open, until it is
    /// left (WindowGate).
    var windows = PageWindows() {
        willSet { relay.send(\.windows, newValue) }
    }

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter, which
    /// is all you need for the five or six pages you keep open all day.
    var pin: String? {
        willSet { relay.send(\.pin, newValue) }
        didSet {
            guard (oldValue == nil) != (pin == nil) else { return }
            settleHome()
            if unopened { Tab.unopenedChanged.send(self) }
        }
    }
    /// The address it was pinned or kept at, and that page's title: where
    /// Back to it goes, as Arc's pinned tab remembers its pinned URL
    /// (PinnedHome.swift). Nil for a tab that is neither.
    var home: URL? {
        willSet { relay.send(\.home, newValue) }
    }
    var homeTitle: String?
    /// A half of a pinned pair put down by its cross (PinPairs.swift): the
    /// other half has the width, this one's mark dims in the square, and
    /// the next click on the square brings the two back. Not written: a
    /// relaunch brings the pair back whole.
    var pairRest = false
    /// One of the pins every space shares (SharedPins.swift): which one,
    /// the same key in every window, in the shared row's file and in sync.
    /// Nil for every other tab, a pin of a space with its own sign-ins too.
    var everywhere: UUID? {
        didSet { if everywhere != oldValue, everywhere != nil { takeCopiesMute() } }
    }
    /// A kept tab's or a space's own pin's key in the list every window of
    /// its space shares (KeptEverywhere.swift), where that isn't the tab's
    /// own id: this window's tab for an entry made in another window. Nil
    /// for every other tab.
    var keptKey: UUID? {
        didSet { if keptKey != oldValue, keptKey != nil { takeCopiesMute() } }
    }

    /// Kept, above the line in the column (Kept.swift): a row with its title
    /// that tidying up never takes, and ⌘W puts to sleep rather than closes.
    var kept = false {
        willSet { relay.send(\.kept, newValue) }
        didSet {
            if oldValue != kept { settleHome() }
            if oldValue != kept, unopened { Tab.unopenedChanged.send(self) }
        }
    }
    /// The folder of yours it is in, among the kept.
    var nest: Nest? {
        willSet { relay.send(\.nest, newValue) }
    }
    /// Brought by a live folder: what it is and what it says (Live.swift).
    var live: LiveMark? {
        willSet { relay.send(\.live, newValue) }
    }

    /// When While You Browse gave this tab its short name in front of you:
    /// its row brings the name in behind the old one's dust (Rename.swift).
    var tidiedAt: Date?

    /// A name of your own, given with a double-click. It stands in for the
    /// page's title wherever the tab is shown, and stays whatever the page
    /// goes on to call itself.
    var name: String? {
        willSet { relay.send(\.name, newValue) }
    }

    /// When you last looked at it. The address field lists open pages by
    /// this, because what you were just reading is what you are most likely
    /// to want back.
    private(set) var touched = Date()
    /// The same moment on the awake clock, which stands still while the Mac
    /// sleeps: how long the tab has gone unwatched, for putting it to sleep.
    @ObservationIgnored private(set) var touchedAwake = AwakeClock.now

    /// How many times it has been the tab on screen, the first time it was
    /// opened in front included; kept in the session. Every one after the
    /// first is a time you came back to it (Sleep.swift).
    var visits = 0
    /// Come back to more than `Browser.keepRevisited` times: the timer never
    /// puts it to sleep.
    var revisited: Bool { visits - 1 > Browser.keepRevisited }

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it, which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL? {
        didSet {
            if pending != oldValue { settleAddressFlags() }
            if pending == nil { unopened = false }
        }
    }
    /// Brought back from the last session or put down with ⌘W, and not
    /// opened since. A kept tab or a pin like that is a saved link in the
    /// column, not an open tab, as Arc's pinned tab is until it is clicked,
    /// and extensions don't see it (`Extensions.offered`): an Arc import
    /// of 1,400 kept rows made every tabs.query cost the square of them
    /// on the main thread (feedback #1039). A tab put to sleep for not
    /// being looked at (`sleep`) is still an open one, a
    /// discarded tab.
    @ObservationIgnored private(set) var unopened = false {
        didSet { if unopened != oldValue { Tab.unopenedChanged.send(self) } }
    }
    /// A tab put down or opened again, or one put down that became kept
    /// or a pin or stopped being one: what extensions see of it changed.
    static let unopenedChanged = PassthroughSubject<Tab, Never>()
    @ObservationIgnored let videoOpening = VideoOpening()
    @ObservationIgnored var videoOpeningFront: (() -> Bool)?
    @ObservationIgnored private var goSerial = 0

    /// For a tab put to sleep for not being looked at: the page's own history
    /// the back list, the page, where it was scrolled to, handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    @ObservationIgnored private var memory: Any?
    /// Put down on its way to `pending`, before the page there came in: its
    /// history ends on the page before, and waking goes on to the address
    /// after bringing that history back (register row 906).
    @ObservationIgnored private var memoryBehind = false
    /// The page's own history as it stands, its view's or the one kept
    /// while asleep, for a ghost: ⌘⇧T brings the tab back with Back still
    /// going back. Asleep, any view it has holds nothing
    /// of the page yet, a blank one's history.
    var history: Any? { asleep ? memory : webKitOnly("WebKit native page state", build: false)?.interactionState }
    /// Where the page was scrolled when it went down, asleep or its process
    /// gone, to go back to once it is loaded again. WebKit's own history
    /// keeps a place only when you leave a page by a link, and a page that
    /// scrolls itself, GitHub's, says it will put its place back and then
    /// has nothing to put back from: either way the page came back at its
    /// top (feedback #44).
    @ObservationIgnored private(set) var place: (url: URL, y: Double)?
    /// How far down the page it was read, 0 to 1 by hundredths, nil at the
    /// top: written with the row, so a relaunch and another Mac in sync
    /// come back to the same part of it, whatever the window's width.
    @ObservationIgnored private(set) var depth: Double?
    /// A depth to go to once the page has loaded (`arrive(at:)`), and how
    /// long the page's own reports are not taken for it, while it loads at
    /// its top and is then taken there.
    @ObservationIgnored private var depthTo: Double?
    @ObservationIgnored private var depthHeld = Date.distantPast
    /// The last picture of that page, compressed, for the moment it wakes,
    /// kept in a file, not here. Two hundred sleeping tabs held tens of
    /// megabytes of pictures in the app's own memory, for tabs that
    /// otherwise cost a line in the row. Here only until the file is written.
    @ObservationIgnored private var picture: Data?
    /// The file has it.
    @ObservationIgnored private var pictured = false
    /// Which write is the latest, so an older one finishing late cannot
    /// claim a picture that has since been replaced or let go.
    @ObservationIgnored private var picturing = 0
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    private(set) var cover: NSImage? {
        willSet { relay.send(\.cover, newValue) }
    }

    /// When the title last reached the row, and whether a later one is
    /// waiting its turn. See `retitle`.
    @ObservationIgnored private var titled = Date.distantPast
    @ObservationIgnored private var titling = false

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view, built now, warm by the time it's needed.
    var isBlank: Bool { instantState == nil && (Narrow.addressFlags ? blankFlag : address == nil) }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if instantState == .searching { return "Searching the web for you…" }
        if let name { return name }
        if instantState == .loading, title.isEmpty, icon == nil { return "Untitled" }
        // Its page only says so once loaded: asleep, the tab read "mail".
        if Narrow.addressFlags ? mailFlag : MailPage.isMail(address) { return "Mail" }
        if popup, let host = Narrow.addressFlags ? siteHost : address?.host(), !host.isEmpty {
            return IDN.shown(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        if !title.isEmpty { return title }
        // A PDF with no title of its own goes by its file's name, as in
        // Safari: "Acme-MSA signed.pdf" (docs/pdf-sign.md).
        if let address, address.pathExtension.lowercased() == "pdf", !address.lastPathComponent.isEmpty { return address.lastPathComponent }
        // Until the page says it again, what it was called when last here,
        // as Arc does: a link opens on its name, not on its address.
        if let address, !shy, let known = History.profile(Spaces.ownSpace(of: store) ?? Space.firstID).title(of: address) { return known }
        if let address { return Address.shown(address) }
        // As the menu names what made it.
        return shy ? "New Private Tab" : "New Tab"
    }

    /// `id` is given only to a tab that takes another's place (see
    /// Browser.replaceBlank): to agents, the bench and extensions it is
    /// the same tab.
    /// `later`: the store of a tab brought back asleep, whose configuration
    /// is made only when its page is.
    init(id: UUID = UUID(), shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil,
         later: WKWebsiteDataStore? = nil, engine: PageEngineKind? = nil,
         factory: PageEngineFactory? = nil) {
        let requestedEngine = factory == nil ? PageEngineFactory.requestedEngine : nil
        let factory = factory ?? .standard
        self.id = id
        self.engineFactory = factory
        // An explicitly supplied factory owns its engine selection. The dev
        // override belongs to the standard factory, including its DRM bridge.
        let selectedEngine = engine ?? requestedEngine ?? .webKit
        self.chromiumDRMEnabled = factory.kinds.contains(.chromium) && selectedEngine == .chromium
        self.engineKind = factory.resolved(selectedEngine)
        self.shy = shy
        self.bench = bench
        if let later, configuration == nil, !shy, !bench {
            self.laterStore = later
        } else {
            self.madeConfiguration = configuration ?? Web.configuration(shy: shy)
        }
        // An agent's click falls back to script when the element is covered,
        // and a script's click is no gesture to WebKit: its tabs may open
        // windows, which land behind you in its own tabs anyway.
        if bench { self.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true }
        // An agent works in its tab out of sight: its page's timers keep
        // their pace there, as WebKit's default.
        if bench { paceHiddenTimers() }
        Tab.made.add(self)
    }

    /// Every tab still in memory, weakly, so a session coming back can tell
    /// an id that is already some open tab's.
    private static let made = NSHashTable<Tab>.weakObjects()

    /// Whether any tab is playing sound now (a song, a video, a call).
    static var anyNoisy: Bool { made.allObjects.contains { $0.noisy } }

    /// Every tab still in memory, for a setting every page follows at once
    /// (DarkPages.refresh).
    static var every: [Tab] { made.allObjects }

    /// The id a tab written down comes back with: its own, unless another
    /// tab already has it (a file read twice, two files saying the same).
    static func returning(_ written: String?) -> UUID {
        guard let id = written.flatMap(UUID.init(uuidString:)),
              !made.allObjects.contains(where: { $0.id == id && !$0.gone })
        else { return UUID() }
        return id
    }

    /// A message handler of yab's, in its own world.
    enum Relay {
        case plain(any WKScriptMessageHandler)
        case replying(any WKScriptMessageHandlerWithReply)
    }

    /// yab's message handlers in its own world, by name, with each tab's
    /// own: `build` adds every one, `Web.release` takes every one off, so
    /// the two never disagree.
    static let relays: [(name: String, handler: (Tab) -> Relay)] = [
        (ScrollRelay.name, { .plain($0.scrollRelay) }),
        (VeilRelay.name, { .plain($0.veils_) }),
        (ImageRelay.name, { .plain($0.images) }),
        (StoreRelay.name, { .plain($0.shop) }),
        (FormRelay.name, { .plain($0.forms) }),
        (WalletRelay.name, { .plain($0.walletRelay) }),
        (FindRelay.name, { .plain($0.finds) }),
        (CallRelay.name, { .plain($0.callRelay) }),
        (ShareRelay.name, { .plain($0.shareRelay) }),
        (DevRelay.name, { .plain($0.devRelay) }),
        (RecordRelay.name, { .plain($0.recordRelay) }),
        (BadgeRelay.name, { .plain($0.badgeRelay) }),
        (WindowRelay.name, { .plain($0.windowRelay) }),
        (IconRelay.name, { .plain($0.iconRelay) }),
        (WatchRelay.name, { .plain($0.watchRelay) }),
        (JSONRelay.name, { .plain($0.jsonRelay) }),
        (MeasureRelay.name, { .plain($0.measureRelay) }),
        (TopDragRelay.name, { _ in .plain(TopDragRelay.shared) }),
        (ItemRelay.name, { .plain($0.itemRelay) }),
        (PasskeyRelay.name, { .replying($0.passkeyRelay) }),
        (PushRelay.name, { _ in .replying(PushRelay.shared) }),
        (ExternalRelay.name, { _ in .replying(ExternalRelay.shared) }),
        (EyeDropperRelay.name, { _ in .replying(EyeDropperRelay.shared) }),
    ]

    /// The relays whose page waits on an answer.
    func chromiumScriptReplying(_ name: String) -> (any PageScriptReplying)? {
        switch name {
        case PushRelay.name: return PushRelay.shared
        case PasskeyRelay.name:
            passkeyRelay.tab = self
            return passkeyRelay
        default: return nil
        }
    }

    func chromiumScriptReceiver(_ name: String) -> (any PageScriptReceiving)? {
        scrollRelay.tab = self
        veils_.tab = self
        images.tab = self
        shop.tab = self
        forms.tab = self
        walletRelay.tab = self
        finds.tab = self
        callRelay.tab = self
        shareRelay.tab = self
        devRelay.log = devLog
        recordRelay.tab = self
        badgeRelay.tab = self
        windowRelay.tab = self
        iconRelay.tab = self
        watchRelay.tab = self
        jsonRelay.tab = self
        measureRelay.tab = self
        itemRelay.tab = self
        guard let entry = Self.relays.first(where: { $0.name == name }), case .plain(let receiver) = entry.handler(self) else { return nil }
        return receiver as? any PageScriptReceiving
    }

    /// Script-owned document state for the engine-neutral commit path.
    func chromiumScriptsCommitted() {
        // Site switch values belong to the document that reported them.
        // A new site may not install CallRelay at all.
        pageMic = nil
        pageCamera = nil
        automaticFills.reset()
        wallet.declined = nil
        fieldAutomatic = false
        fieldDocument = nil
        fieldIdentity = nil
        fieldFrame = nil
        caretBox = nil
        typing = false
        draft = false
        devDocument += 1
        devLog.reset()
        json = nil
        darkCommitted()
        recorder.committed(builtPage?.url)
        measureAgain()
        unreadable()
        reader = false
        reading = 0
        if everRead {
            builtPage?.run(Reader.showing, in: .yab, gesture: false) { [weak self] result in
                guard (try? result.get()) as? Bool == true else { return }
                self?.reader = true
                self?.builtPage?.run(Reader.configure(.saved), in: .yab, gesture: false)
                self?.builtPage?.run("window.__yabReading && window.__yabReading()", in: .yab, gesture: false)
            }
        }
    }

    func buildWebKitPage() -> PageView {
        if #available(macOS 15.4, *), engineFactory.followsGlobalSelection { Extensions.webKitPageMade() }
        let fonts = PageFonts.read()
        if !LinkGap.cut("prefs") {
            configuration.preferences.minimumFontSize = address?.scheme?.hasPrefix("http") == true
                ? CGFloat(min(24, max(0, fonts.minimum))) : 0
            PageFamilies.apply(fonts, to: configuration.preferences)
        }
        if !LinkGap.cut("bftrace") { BFTrace.prepare(configuration) }
        // Past Chrome's process count, a page on a site another tab is on
        // goes into that tab's process (SiteProcesses); otherwise a waking
        // tab goes into the warmed spare's. WebKit throws when the related
        // view is in another process pool, so only one in this pool.
        // A window a page opened is already related to its opener, and
        // must stay so: WebKit raises when the view returned from
        // createWebViewWith isn't (crash #33, a sign-in window on a Mac past
        // the process count with another tab on the sign-in's site).
        let pool = configuration.processPool
        let opened = SiteProcesses.related(of: configuration) != nil
        let sibling = SiteProcesses.on && !opened
            ? SiteProcesses.sibling(for: address, store: configuration.websiteDataStore)
                .flatMap { $0.configuration.processPool === pool ? $0 : nil } : nil
        let spare = sibling == nil && !opened ? related.flatMap { $0.view.configuration.processPool === pool ? $0.view : nil } : nil
        if let sibling {
            SiteProcesses.relate(configuration, to: sibling)
        } else if let spare {
            configuration.perform(Tab.relatedSelector, with: spare)
        }
        let web = OpenTrace.time("build.webview") { PageView(frame: .zero, configuration: configuration) }
        if engineFactory.kinds.contains(.chromium) {
            let originalProfile = chromiumProfile
            web.navigationEvents.routeSiteEngine = { [weak self] request, byPerson in
                guard let self, !self.gone, self.chromiumProfile == originalProfile else { throw CancellationError() }
                return try await self.routeSiteEngine(request, byPerson: byPerson)
            }
            web.navigationEvents.prepareChromiumCookies = { [weak self, weak web] url in
                guard let self, let web, !self.gone, self.chromiumProfile == originalProfile else { throw CancellationError() }
                // Reading the native profile plan is inert. Constructing its
                // bridges claims that directory, so wait for actual prior
                // Chromium use or an explicit site-engine route.
                guard ChromiumDRMCookies.needsPreparation(self) else { return }
                // What the bridges couldn't do costs a cookie or an extension on
                // this page, never the page: a canceled hop of a sign-in looked
                // like the site refusing it.
                do { try await ChromiumDRMCookies.of(self).prepare(for: url, in: .webKit) }
                catch { NSLog("Cookie bridge: not carried before a WebKit page: %@", String(describing: type(of: error))) }
                guard !self.gone else { throw CancellationError() }
                if !self.shy {
                    do {
                        let extensions = try self.chromiumDRMExtensions ?? ChromiumDRMExtensions(tab: self, web: web)
                        self.chromiumDRMExtensions = extensions
                        try await extensions.prepare(url)
                    } catch { NSLog("Chromium extensions: not ready for a WebKit page: %@", String(describing: type(of: error))) }
                    guard !self.gone else { throw CancellationError() }
                }
            }
        }
        if engineFactory.kinds.contains(.chromium) {
            web.navigationEvents.redirected = { [weak self] url in ChromiumDRMCookies.session(of: self)?.touched(url, by: .webKit) }
            web.navigationEvents.prepareFrame = { [weak self] url in await ChromiumDRMCookies.session(of: self)?.prepareFrame(url) }
        }
        if sibling != nil || spare != nil { configuration.perform(Tab.relatedSelector, with: nil) }
        if let spare {
            OpenTrace.mark("build.related \(OpenTrace.process(spare)) \(OpenTrace.process(web))")
        }
        if related != nil {
            // Its own page started there (or couldn't), the spare can go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.letRelatedGo() }
        }
        if !LinkGap.cut("bftrace") { BFTrace.attach(web) }
        OpenTrace.mark("build.process \(OpenTrace.process(web))")
        web.pageZoom = address?.scheme?.hasPrefix("http") == true
            ? CGFloat(PageAppearance.zoom(host: address?.host(), privatePage: shy)) : 1
        zoom = web.pageZoom
        appearanceWatch = NotificationCenter.default.publisher(for: PageAppearance.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPageAppearance() }
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. So is Smart Zoom, two fingers tapped twice (see
        // PageView). ⌘+ and ⌘- are the other thing, they lay the page out
        // again at a bigger size, and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a pill (PullView).
        web.allowsBackForwardNavigationGestures = false
        web.canBackToSource = { [weak self] in self?.backSourceAvailable == true }
        web.onPull = { [weak self] pull in self?.pull = pull }
        web.fromTitle = { [weak self] in self.flatMap { $0.fromTitle?($0) } }
        web.onFrom = { [weak self] in
            guard let self else { return }
            onFrom?(self)
        }
        web.onStep = { [weak self] forward in
            guard let self else { return }
            if let onStep { onStep(self, forward) } else if forward { self.forward() } else { back() }
        }
        web.onHistory = { [weak self] history in
            guard let self else { return }
            pullView?.panel(history, of: self) { [weak self] words in
                guard let self else { return }
                onSearchHistory?(self, words)
            }
        }
        web.onTouch = { [weak self] in
            guard let self else { return }
            self.uncover()
            self.onSelectionTouch?(self)
        }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.onSelectedURL = { [weak self] url, flags in
            guard let self else { return }
            self.onSelectedURL?(self, url, flags)
        }
        web.searchName = { [weak self] in
            guard let self else { return Engine.name }
            return self.onSearchName?(self) ?? Engine.name
        }
        web.onSelectionCommand = { [weak self] command in
            guard let self else { return }
            self.onSelectionCommand?(self, command)
        }
        web.onMeasure = { [weak self] in
            guard let self, self.isDev, !(self.toolsOpen?(self) ?? false) else { return nil }
            return { [weak self] point in self?.measure(true, pick: point) }
        }
        web.onWebInspect = { [weak self] inspect in
            guard let self else { return }
            self.measure(false)
            if let onWebInspectElement = self.onWebInspectElement { onWebInspectElement(self, inspect) }
            else { inspect() }
        }
        // Only a picture heard from this right-click: an older one would be
        // the wrong picture.
        web.onImage = { [weak self] act, since, foreground in
            guard let self, let pointed = self.pointedImage, pointed.at >= since - 1 else { return false }
            self.onImageAct?(self, act, pointed.url, foreground)
            return true
        }
        // The right-click's video, or the tab's own address where the tab
        // is the video itself (a video opened in its own tab) and its page
        // said nothing.
        web.onMedia = { [weak self] since in
            guard let self, let save = self.onMediaSave else { return false }
            if let pointed = self.pointedMedia, pointed.at >= since - 1 {
                save(self, pointed.media)
                return true
            }
            guard let address = self.address, VideoSave.isMediaFile(address) else { return false }
            save(self, PointedMedia(src: address.absoluteString))
            return true
        }
        web.mediaHeard = { [weak self] since in
            guard let self else { return nil }
            // WebKit's own sound document may not report a contextmenu event.
            if let document = self.built?.audioDocument { return document }
            guard let pointed = self.pointedMedia, pointed.at >= since - 1 else { return nil }
            return pointed.media
        }
        // The picture's words for its menu's Copy Text: the right-click's
        // picture, heard a moment before the menu or just after it.
        web.onPictureWords = { [weak self] since in
            let reader = PictureReader.shared
            let heard = { [weak self] () -> URL? in
                guard let pointed = self?.pointedImage, pointed.at >= since - 1 else { return nil }
                return pointed.url
            }
            let words = { [weak self] (url: URL) async -> PictureWords? in
                if let words = await reader.pending(url.absoluteString), words.whole || words.isEmpty { return words }
                guard let self else { return nil }
                return await reader.text(url, from: self)
            }
            if let url = heard() {
                // Read whole, or without a word in what showed of it: known.
                if let known = reader.words(url.absoluteString), known.whole || known.isEmpty { return (known, nil) }
                return (nil, { await words(url) })
            }
            return (nil, {
                for _ in 0..<20 {
                    if let url = heard() { return await words(url) }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                return nil
            })
        }
        web.picturesAskable = { [weak self] in self?.shy == false && AIUse.offers }
        web.onPictureCopied = { [weak self] in
            guard let self else { return }
            self.onPictureCopied?(self)
        }
        // Only a link heard from this right-click: an older one would be
        // the wrong link.
        web.onMailLink = { [weak self] since in
            guard let pointed = self?.pointedLink, pointed.at >= since - 1 else { return nil }
            return pointed.url
        }
        web.onSplitLink = { [weak self] url in
            guard let self else { return }
            (self.delegate as? Browser)?.splitLink(url, from: self)
        }
        web.onHideAt = { [weak self] point in
            guard let self else { return }
            self.page.runInYab("window.__yabVeil && window.__yabVeil.at(\(point.x), \(point.y))")
        }
        web.onCapture = { [weak self] in
            guard let self else { return }
            self.onCapturePage?(self)
        }
        web.onTranslationMenu = { [weak self] in
            guard let self else { return [] }
            return self.onTranslationMenu?(self) ?? []
        }
        web.onSelectionMenu = { [weak self] in
            guard let self else { return [] }
            return self.onSelectionMenu?(self) ?? []
        }
        web.onAppleCodeContext = { [weak self] in
            guard let self, self.fieldCode, self.address?.scheme?.lowercased() == "https",
                  let host = self.address?.host(), let user = self.account(on: host) else { return nil }
            return (user, AppleCodeHints.has(host: host, user: user))
        }
        web.onAppleCodeOpen = { [weak self] in
            _ = self?.openAppleCode()
        }
        web.onSelectionPause = { [weak self] in
            guard let self else { return }
            self.onSelectionPause?(self)
        }
        web.onForceClick = { [weak self] point in
            guard let self else { return }
            self.onForceClick?(self, point)
        }
        web.onPress = { [weak self] amount in
            guard let self else { return }
            self.onPress?(self, amount)
        }
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance, so a site that honors
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Right-click, Inspect Element. The public way to say so since 13.3,
        // and the private one that puts it in the page's menu.
        if !LinkGap.cut("prefs") {
            if #available(macOS 13.3, *) { web.isInspectable = true }
            Inspector.allow(web.configuration.preferences)
        }
        web.installDelegates(delegate)

        // A tab opened by a link inherits its opener's configuration, handlers
        // included, so each name is cleared before being claimed, registering
        // one twice is a hard crash rather than an error.
        OpenTrace.mark("build.relays")
        let controller = web.configuration.userContentController
        Web.release(controller)
        recordRelay.tab = self
        passkeyRelay.tab = self
        for (name, handler) in Tab.relays where !LinkGap.cut("relays") {
            switch handler(self) {
            case .plain(let relay): controller.add(relay, contentWorld: Web.world, name: name)
            case .replying(let relay): controller.addScriptMessageHandler(relay, contentWorld: Web.world, name: name)
            }
        }
        if !LinkGap.cut("relays") { controller.add(FrameRelay.shared, contentWorld: AgentPage.world, name: FrameRelay.name) }
        // Dark pages' bridge, in its own world only: a page can't reach it.
        if !LinkGap.cut("relays") {
            darkState.relay.tab = self
            controller.addScriptMessageHandler(darkState.relay, contentWorld: DarkPages.world, name: DarkRelay.name)
        }
        if !LinkGap.cut("shield") { Shield.shared.protect(controller, persistent: web.configuration.websiteDataStore.isPersistent) }
        OpenTrace.mark("build.shield")
        builtPage = web
        arm(hiding: veils)

        scrollRelay.tab = self
        veils_.tab = self
        forms.tab = self
        walletRelay.tab = self
        finds.tab = self
        devRelay.log = devLog
        devLog.heardStream = { [weak self] url, events in self?.netLog.heard(stream: url, events: events) }
        badgeRelay.tab = self
        windowRelay.tab = self
        iconRelay.tab = self
        watchRelay.tab = self
        jsonRelay.tab = self
        measureRelay.tab = self
        itemRelay.tab = self
        callRelay.tab = self
        shareRelay.tab = self
        images.tab = self
        shop.tab = self
        ears.watch(web) { [weak self] on in
            guard let self else { return }
            if !on, noisy { heardAt = Date() }
            noisy = on
            tuneWatch.heard(playing: on)
        }
        tuneWatch.watch(web, tab: self)
        if muted { AudioWatch.mute(web, true) }
        return web
    }

    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - page.pageZoom) > 0.004 else { return }
        page.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        if measuring { pushMeasure() }
        onZoom?(self, wanted)
    }

    func stepZoom(increasing: Bool) {
        magnify(to: CGFloat(PageAppearance.steppedZoom(Double(page.pageZoom), increasing: increasing)))
    }

    private func applyPageAppearance() {
        guard let handle = builtPage else { return }
        let fonts = PageFonts.read()
        if let chromium = handle as? ChromiumPage {
            chromium.minimumFont(address?.scheme?.hasPrefix("http") == true ? min(24, max(0, fonts.minimum)) : 0)
            chromium.pageFamilies(PageFamilies.names(fonts))
        } else if let web = WebKitOnly.page(handle, for: "Native page appearance preferences") {
            web.configuration.preferences.minimumFontSize = address?.scheme?.hasPrefix("http") == true
                ? CGFloat(min(24, max(0, fonts.minimum))) : 0
            PageFamilies.apply(fonts, to: web.configuration.preferences)
            PageAppearance.install(fonts, in: web.configuration.userContentController)
        }
        handle.run(PageAppearance.script(fonts), in: .yab) { _ in }
        applyRememberedZoom()
    }

    /// ⌘0 undoes both kinds of zoom at once, whichever one you reached for.
    func resetZoom() {
        if let host = address?.host(), !shy { PageAppearance.rememberZoom(nil, host: host) }
        let wanted = address?.scheme?.hasPrefix("http") == true
            ? CGFloat(PageAppearance.defaultZoom()) : 1
        page.pageZoom = wanted
        zoom = wanted
        onZoom?(self, wanted)
        guard page.magnification != 1 else { return }
        page.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden,
    /// for `host`, where the tab is going (nil: where it is). The stylesheet
    /// goes in before the document has a body, so nothing is ever seen
    /// arriving and then leaving again. The scripts are the same objects
    /// from one page to the next, and sent again only when the list changes
    /// (PageScripts).
    func arm(hiding css: String, on host: String? = nil, to url: URL? = nil) {
        let span = MainBudget.begin("pagescripts.arm"); defer { span?.end() }
        veils = css
        // A new document: what the pointer was on is the last one's.
        if SiteItems.shared.pointed[id] != nil { SiteItems.shared.pointed[id] = nil }
        if let chromium = builtPage as? ChromiumPage {
            chromium.scripts.arm(css: css, host: host ?? PageScripts.host(of: url ?? address), to: url)
            Userscripts.shared.newDocument(self)
            return
        }
        guard let built else { return }
        PageScripts.arming {
            let controller = built.configuration.userContentController
            let arming = PageScripts.Arming(host: host ?? PageScripts.host(of: address), css: css)
            // Dark pages: decided before the request leaves (DarkPages.swift).
            darkArm(url: url, host: arming.host)
            var list = LinkGap.cut("scripts") ? [] : PageScripts.list(for: self, arming)
            if LinkGap.cut("docstart") { list = list.filter { $0.injectionTime != .atDocumentStart } }
            if LinkGap.cut("docend") { list = list.filter { $0.injectionTime != .atDocumentEnd } }
            if !LinkGap.cut("scripts"), let look = BoostEditorLooks.shared.script(for: self, host: BoostEditorLook.host(url ?? address)) { list.append(look) }
            PageScripts.fit(controller, list)
            guard !LinkGap.cut("scripts") else { return }
            Boosts.shared.attach(to: controller, tab: self)
            Userscripts.shared.attach(to: controller, tab: self, host: arming.host)
        }
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        builtPage?.runInYab(Veiling.style(css))
    }

    func startPicking() { page.runInYab("window.__yabVeil && window.__yabVeil.on()") }
    func stopPicking() { page.runInYab("window.__yabVeil && window.__yabVeil.off()") }

    func foundSignIn() { onSignIn?(self) }

    /// The box on the page the caret is in, as the page last said: what the
    /// address field's places put something into (Places.swift).
    struct CaretBox: Equatable {
        var password: Bool
        var lines: Bool
        var label: String
        var signIn: Bool
        /// A box that asks for a code a site sent (MailCodes.swift).
        var code = false
    }
    @ObservationIgnored var caretBox: CaretBox?

    /// What the name box under the caret holds so far, to narrow the list of
    /// accounts by. Empty in a password box.
    @ObservationIgnored var fieldQuery = ""
    /// Whether that box is the password one, and whether it is still empty.
    @ObservationIgnored var fieldSecret = false
    /// That password box takes a new password (a sign-up, a change): the
    /// list offers one made here (ManagerSuggestions.swift).
    @ObservationIgnored var fieldFresh = false
    @ObservationIgnored var fieldEmpty = true
    /// Automatic filling is offered only by an unchanged, empty sign-in
    /// field. Its document and pair stay the same while Touch ID is asked.
    /// The box asks for an email (its type, its autocomplete or its label
    /// says so): with no login for the site, your addresses are offered.
    @ObservationIgnored var fieldEmail = false
    /// The page marked that box for passkey autofill (autocomplete="…
    /// webauthn"): a pending conditional get's passkeys are listed under it
    /// (ChromiumWebAuthn+Conditional.swift).
    @ObservationIgnored var fieldWebAuthn = false
    /// Its form takes passkeys (a box of it marked webauthn): nothing goes
    /// in by itself, as Chromium waits for a pick on such a form.
    @ObservationIgnored var fieldWebAuthnForm = false
    @ObservationIgnored var fieldAutomatic = false
    @ObservationIgnored var fieldDocument: String?
    @ObservationIgnored var fieldIdentity: String?
    @ObservationIgnored private var automaticFills = PasswordAutofillAttempts()

    func beginAutomaticFill() -> Bool {
        guard fieldAutomatic, fieldEmpty else { return false }
        return automaticFills.begin(document: fieldDocument, field: fieldIdentity)
    }
    /// The account a password box is for, as its page says it: a name kept
    /// in the form, Google's chip over the box.
    @ObservationIgnored var fieldAccount: String?
    /// Whether the page is dark under that box (`DropFrame.ground`).
    @ObservationIgnored var fieldDark: Bool?
    /// The box asks for a code a site sent, not for an account.
    struct WaitingCode {
        let document: String
        let field: String
        let request: CodeRequest
        let address: URL
    }
    @ObservationIgnored var waitingCode: WaitingCode?
    @ObservationIgnored var fieldCode = false
    @ObservationIgnored var fieldCodeRequest = CodeRequest()
    /// Where that box last was, in points, for a list that comes up later
    /// than the caret did: a code that arrives while the box waits.
    @ObservationIgnored var fieldSpot: CGRect?
    /// The frame of another site whose sign-in box has the caret, App Store
    /// Connect's Apple frame; nil for a box of the page's own.
    @ObservationIgnored var fieldFrame: PageFrame?

    /// Whose box the caret is in: the page's address, or a frame's origin.
    /// Accounts are listed and filled for this, never across the two.
    var fieldAddress: URL? {
        guard let frame = fieldFrame else { return address }
        return Tab.url(of: frame.origin)
    }

    static func url(of origin: PageOrigin) -> URL? {
        var parts = URLComponents()
        parts.scheme = origin.scheme.lowercased()
        parts.host = origin.host.lowercased()
        if origin.port > 0 { parts.port = origin.port }
        parts.path = "/"
        return parts.url
    }

    static func url(of origin: WKSecurityOrigin) -> URL? {
        var parts = URLComponents()
        parts.scheme = origin.protocol.lowercased()
        parts.host = origin.host.lowercased()
        if origin.port > 0 { parts.port = origin.port }
        parts.path = "/"
        return parts.url
    }

    /// A sign-in box in another site's frame has the caret, or has lost it.
    /// Its place is the frame's, so where the frame sits is asked of the
    /// page (the wallet's `frameAt`) before the list can hang from it.
    func frameCaret(_ body: [String: Any], in frame: PageFrame) {
        let document = body["document"] as? String
        guard let rect = body["rect"] as? [String: Double],
              let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"]
        else {
            // Only the box that has the caret can say it left.
            guard fieldFrame != nil, fieldDocument == document else { return }
            fieldFrame = nil
            (builtPage as? any PageInputContent)?.updateInputContent(nil)
            typing = false
            caretBox = nil
            fieldAutomatic = false
            fieldFocused(nil)
            return
        }
        fieldFrame = frame
        (builtPage as? any PageInputContent)?.updateInputContent(body["content"] as? String)
        typing = true
        caretBox = CaretBox(password: body["password"] as? Bool ?? false, lines: false,
                            label: body["label"] as? String ?? "", signIn: true)
        fieldCode = false
        fieldCodeRequest = CodeRequest()
        fieldQuery = body["typed"] as? String ?? ""
        fieldSecret = body["secret"] as? Bool ?? false
        fieldFresh = body["fresh"] as? Bool ?? false
        fieldEmpty = body["empty"] as? Bool ?? true
        fieldAutomatic = body["automatic"] as? Bool ?? false
        fieldDocument = document
        fieldEmail = Tab.asksEmail(body)
        fieldWebAuthn = body["webauthn"] as? Bool ?? false
        fieldWebAuthnForm = body["webauthnForm"] as? Bool ?? false
        fieldIdentity = body["field"] as? String
        fieldAccount = (body["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let box = CGRect(x: x, y: y, width: w, height: h)
        let dark = body["dark"] as? Bool
        builtPage?.call(
            "return window.__yabWallet ? window.__yabWallet.frameAt(href, w, h) : null",
            arguments: ["href": body["href"] as? String ?? "", "w": body["vw"] as? Double ?? 0, "h": body["vh"] as? Double ?? 0],
            in: .yab, frame: nil
        ) { [weak self] result in
            MainActor.assumeIsolated {
                // Still that box: the caret may have moved on meanwhile.
                guard let self, self.fieldFrame?.token === frame.token, self.fieldDocument == document,
                      case .success(let value) = result, let at = value as? [String: Any],
                      let fx = at["x"] as? Double, let fy = at["y"] as? Double
                else { return }
                self.fieldDark = dark ?? at["dark"] as? Bool
                self.fieldFocused(box.offsetBy(dx: fx, dy: fy))
            }
        }
    }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    func fieldFocused(_ rect: CGRect?) {
        guard let rect else {
            fieldSpot = nil
            onField?(self, nil)
            return
        }
        let zoom = builtPage?.pageZoom ?? 1
        let spot = CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        )
        fieldSpot = spot
        onField?(self, spot)
    }

    /// The account a sign-in that asks for the name first was just given,
    /// picked from the list or typed, so its password step can put that
    /// account at the top. Kept for a few minutes and for that site only.
    @ObservationIgnored private(set) var named: (site: String, user: String, at: Date)?

    /// `host`: the frame's, for a sign-in in another site's frame.
    func namedAccount(_ user: String, on host: String? = nil) {
        guard !user.isEmpty, let host = host ?? address?.host()?.lowercased() else { return }
        named = (Vault.registrable(host), user, Date())
    }

    /// The same, but once: the password step fills itself for the account
    /// the name step was given, and only the first time the caret gets
    /// there, clearing the box and coming back is choosing again.
    func takeAccount(on host: String) -> String? {
        guard let user = account(on: host), let at = named?.at, filledFor != at else { return nil }
        filledFor = at
        return user
    }
    @ObservationIgnored private var filledFor: Date?

    /// Who the password step on this page is for, if the name step said.
    func account(on host: String) -> String? {
        guard let named, Date().timeIntervalSince(named.at) < 300,
              named.site == Vault.registrable(host)
        else { return nil }
        return named.user
    }

    /// Opening Passwords is only a possible source. Remember the account
    /// after a code is actually entered into this site's waiting box.
    @ObservationIgnored private var appleCodePending: (site: String, user: String, at: Date)?

    func openAppleCode() -> Bool {
        guard address?.scheme?.lowercased() == "https",
              let host = address?.host(), let user = account(on: host),
              AppleCodeHints.open() else { return false }
        appleCodePending = (Vault.registrable(host), user, Date())
        return true
    }

    func enteredAppleCode() {
        guard let pending = appleCodePending,
              Date().timeIntervalSince(pending.at) < 300,
              address?.scheme?.lowercased() == "https",
              let host = address?.host(), Vault.registrable(host) == pending.site,
              account(on: host)?.caseInsensitiveCompare(pending.user) == .orderedSame
        else { return }
        appleCodePending = nil
        AppleCodeHints.remember(host: host, user: pending.user)
    }

    /// A name and password the page has just sent, held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering. `back`:
    /// the paths a refused sign-in comes back to, the sign-in page's own
    /// and its form's.
    @ObservationIgnored private var sent: (host: String, user: String, password: String, clear: Bool, at: Date, back: Set<String>, frame: PageFrame?, address: URL?)?

    /// `frame`: a sign-in in another site's frame (App Store Connect's is
    /// Apple's), whose password belongs to the frame's site, not the page's.
    func sentSignIn(user: String, password: String, action: String = "", frame: PageFrame? = nil) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = frame?.origin.host.lowercased() ?? address?.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // The password step of a two-step sign-in has no name box left; the
        // name is the one the step before was given.
        let user = user.isEmpty ? account(on: host) ?? "" : user
        if !user.isEmpty { namedAccount(user, on: host) }
        let back = Set([address?.path, action.isEmpty ? nil : URL(string: action, relativeTo: address)?.path].compactMap { $0 })
        passwordOfferCheck = UUID()
        sent = (bare, user, password, (frame?.origin.scheme ?? address?.scheme)?.lowercased() == "http", Date(), back, frame, address)
    }

    /// The page has moved on, a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// Fields that a page removed by itself are given a moment first: a
    /// sign-in built into the page closes its form the instant you press
    /// the button and puts it back if the server says no, and offering in
    /// between is offering a password that may be wrong. A new document
    /// with no box, back where the sign-in was sent from or to, is looked
    /// at again a moment later (`looked`): a page that draws its form by
    /// script, as single-page apps do, has none yet when it finishes
    /// loading, the one that says the password was wrong too. Anywhere
    /// else, where a sign-in that took goes, it is asked about at once.
    func settleSignIn(navigated: Bool = true, looked: Bool = false, frame: PageFrame? = nil) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45,
              sent.frame == nil || Self.origin(of: sent.address) == Self.origin(of: address) else {
            self.sent = nil
            return
        }
        guard navigated else {
            // A different document's settled form says nothing about this
            // submission. The recheck always uses the sender's engine handle.
            guard (sent.frame == nil) == (frame == nil), sent.frame?.origin == frame?.origin else { return }
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true, looked: true)
            }
            return
        }
        guard let page = builtPage else { return }
        let script = sent.frame == nil
            ? "!!(window.__yabForms && window.__yabForms.hasPassword())"
            : "window.__yabForms ? window.__yabForms.hasPassword() : null"
        page.run(script, in: .yab, frame: sent.frame) { [weak self, weak page] result in
            MainActor.assumeIsolated {
                guard let self, let page, self.builtPage === page, self.sent?.at == sent.at,
                      sent.frame == nil || Self.origin(of: self.address) == Self.origin(of: sent.address),
                      case .success(let value) = result, let still = value as? Bool else { return }
                // The box is still there, on the page the sign-in came back
                // to or put back after a moment: refused. Forgotten, so a
                // page without one opened next, the person giving up on it,
                // is not taken for the wrong password having worked.
                if still {
                    self.sent = nil
                    return
                }
                if !looked, sent.back.contains(self.address?.path ?? "") {
                    let stamp = sent.at
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        guard let self, self.sent?.at == stamp else { return }
                        self.settleSignIn(navigated: true, looked: true)
                    }
                    return
                }
                self.sent = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password, sent.clear, sent.frame)
            }
        }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears how it went: `.gone` is the case worth
    /// saying something about, the sign-in fields that were there a moment
    /// ago, when this was offered, are gone by the time it actually runs.
    ///
    /// With Touch ID asked for in Settings, nothing goes in until it is
    /// given (see `Vault.proveToFill`), and then only if the page is still
    /// on the site it was asked for. `proven`: the password manager that
    /// gave it asked the person for it just now, with its own Touch ID, so
    /// Yab doesn't ask a second time.
    ///
    /// `caret`: into the box the caret is in, a frame's too (`fieldFrame`),
    /// for Yab's own list, which listed that frame's site. Everyone else,
    /// an agent, a place, a manager, fills the page itself.
    func fill(user: String, password: String, agent: Bool = false, automatic: Bool = false, caret: Bool = false,
              proven: Bool = false, done: ((Filled) -> Void)? = nil) {
        guard builtPage != nil else { done?(.gone); return }
        let frame = caret ? fieldFrame : nil
        let target = frame.flatMap { Tab.url(of: $0.origin) } ?? address
        let origin = Tab.origin(of: target)
        let document = automatic ? fieldDocument : nil
        let identity = automatic ? fieldIdentity : nil
        if automatic, document == nil || identity == nil { done?(.gone); return }
        Vault.proveToFill(on: target?.host()?.lowercased() ?? "", agent: agent, already: proven) { [weak self] proven in
            // Closed or put to sleep while it was asked: nothing to fill,
            // and whoever waits (an agent's sign-in) hears so. An agent's
            // sign-in holds the tab while it waits, so `self` being there
            // doesn't mean the tab is still open, and the page filled is
            // only ever the one already built, never a new one made here.
            guard let self, !self.gone, !self.asleep, let web = self.builtPage else { done?(.gone); return }
            switch proven {
            case .yes: break
            case .no: done?(.refused); return
            case .cannot: done?(.unasked); return
            }
            // Only into the page it was asked for: the same scheme, host
            // and port, so never over http when asked on https.
            guard Tab.origin(of: frame == nil ? self.address : self.fieldAddress) == origin,
                  (frame == nil) == (self.fieldFrame == nil)
            else {
                done?(.gone)
                return
            }
            if automatic {
                guard self.fieldDocument == document, self.fieldIdentity == identity,
                      !web.isHiddenOrHasHiddenAncestor, let window = web.window, window.isKeyWindow,
                      let responder = window.firstResponder as? NSView,
                      responder === web || responder.isDescendant(of: web)
                else { done?(.gone); return }
            }
            let script = Tab.fillScript(user: user, password: password, automaticDocument: document, automaticField: identity)
            guard let frame = self.fieldFrame, caret else {
                web.runInYab(script) { result in
                    done?((result as? Bool) == true ? .filled : .gone)
                }
                return
            }
            web.run(script, in: .yab, frame: frame) { result in
                done?((try? result.get()) as? Bool == true ? .filled : .gone)
            }
        }
    }

    /// Scheme, host and port, the page's origin.
    private static func origin(of url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.scheme?.lowercased() ?? "")://\(url.host()?.lowercased() ?? ""):\(url.port ?? -1)"
    }

    /// `.refused` is the person saying no, `.unasked` the Mac unable to put
    /// the question at all.
    enum Filled { case filled, gone, refused, unasked }

    /// The script that fills, with the name and password in it as base64 of
    /// their JSON rather than written into the source: no quote, backtick,
    /// `${`, backslash or line break in a password can end the string and
    /// become code. atob gives bytes, so they are read back as UTF-8.
    static func fillScript(user: String, password: String, automaticDocument: String? = nil,
                           automaticField: String? = nil) -> String {
        let values: [Any] = [user, password, automaticDocument as Any? ?? NSNull(), automaticField as Any? ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[\"\",\"\",null,null]".utf8)
        return """
        (() => {
          const bytes = Uint8Array.from(atob('\(data.base64EncodedString())'), c => c.charCodeAt(0));
          const [user, password, document, field] = JSON.parse(new TextDecoder().decode(bytes));
          if (!window.__yabForms) return false;
          return document
            ? !!window.__yabForms.autoFill(user, password, document, field)
            : !!window.__yabForms.fill(user, password);
        })()
        """
    }

    func picked(selector: String, label: String, note: String, rect: CGRect? = nil) {
        onPick?(self, selector, label, note, rect)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        page.runInYab(
            "window.__yabVeil && window.__yabVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        page.runInYab("window.__yabVeil && window.__yabVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    /// When the navigation now under way began, in the page's own clock
    /// (milliseconds since 1970, as performance.timeOrigin counts).
    @ObservationIgnored private var navigating: Double = 0

    /// The history entry shown at the last commit, and the last frames of
    /// the pages left, by entry (BACK_STILLS).
    @ObservationIgnored private var lastItem: WKBackForwardListItem?
    @ObservationIgnored private var itemStills: [(item: WKBackForwardListItem, owner: UUID)] = []

    /// The last frame kept for the history entry at `url` next to the
    /// page shown (Back or Forward to it), if there is one.
    var historyStillCount: Int { itemStills.count }
    func historyStill(for url: URL?) -> PageStills.Still? {
        guard Narrow.backStills, let url, let list = webKitOnly("WebKit native page state", build: false)?.backForwardList else { return nil }
        for item in [list.backItem, list.forwardItem].compactMap({ $0 }) where item.url == url {
            if let kept = itemStills.first(where: { $0.item === item }), let still = PageStills.shared.kept(kept.owner),
               still.key.url == url {
                return still
            }
        }
        return nil
    }

    // MARK: - the page first, the window after (HOLD_NAV)

    /// What a navigation changes in what the window draws (the address,
    /// loading, Back and Forward, the title, the colors, and Browser's
    /// didFinish), kept from its start until the page's first frame after
    /// it commits, then written in one turn. Each of those writes ran a
    /// pass of the window's SwiftUI graph on the main thread, the thread
    /// the page's frames and WebKit's own questions during a Back wait on
    /// (docs/evidence/clean-gap-2026-10-13.md, round 6). Nil: not holding.
    @ObservationIgnored private var heldWrites: [() -> Void]?
    @ObservationIgnored private var holdTurn = 0
    var holdingNavigation: Bool { heldWrites != nil }

    /// Runs `write` now, or after the navigation's first frame while held.
    /// `kind`: which of WebKit's KVO it is ("url", "loading", "title"...),
    /// for the trace and YAB_LINKGAP's kvo.<kind> (round 11).
    func held(_ kind: String = "", _ write: @escaping () -> Void) {
        if LinkGap.cut("window") || LinkGap.cut("kvo") || (!kind.isEmpty && LinkGap.cut("kvo." + kind)) { return }
        if heldWrites != nil { heldWrites?.append(write) } else { OpenTrace.time("held." + kind, write) }
    }

    /// A navigation of the page on screen starts: hold, 0.15 s at most.
    private func holdNavigation() {
        guard Narrow.holdNav, let web = webKitOnly("WebKit native page state", build: false), web.window != nil else { return }
        if heldWrites == nil { heldWrites = [] }
        holdTurn += 1
        let turn = holdTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if self?.holdTurn == turn { self?.releaseNavigation() }
        }
    }

    /// Committed: let go after the page's next frame.
    func releaseAfterFrame() {
        guard heldWrites != nil, let web = webKitOnly("WebKit native page state", build: false) else { return }
        let turn = holdTurn
        StageView.afterNextDrawing(web) {
            DispatchQueue.main.async { [weak self] in
                if self?.holdTurn == turn { self?.releaseNavigation() }
            }
        }
    }

    /// Everything held, written now, in order.
    func releaseNavigation() {
        guard let writes = heldWrites else { return }
        heldWrites = nil
        quietHold = false
        holdTurn += 1
        writes.forEach { $0() }
    }

    // MARK: - the page's answer first (QUIET_START)

    /// Whether what is held is QUIET_START's: let go once the navigation's
    /// response is answered, not after its frame.
    @ObservationIgnored private var quietHold = false

    /// A navigation of the page on screen is allowed: what it changes in
    /// the window (the address, loading, the load bar, the title) is kept
    /// until its response has been answered, it commits or it fails, and
    /// written then. That turn's writes ran the window's SwiftUI graph for
    /// 12-15 ms on the main thread just after the start, and WebKit's
    /// question about the response, which the page's document waits on,
    /// came in behind it: DOM ready at 18 ms from the click, against 8
    /// with the window told nothing (docs/evidence/clean-gap-2026-10-13.md,
    /// round 11). Asked from the navigation's action, before WebKit's own
    /// KVO of its start. Let go after `quietFor` whatever happens.
    func quietUntilAnswered() {
        guard Narrow.quietStart, !Narrow.holdNav, let web = webKitOnly("WebKit native page state", build: false), web.window != nil else { return }
        if heldWrites == nil { heldWrites = [] }
        quietHold = true
        holdTurn += 1
        let turn = holdTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + Narrow.quietFor) { [weak self] in
            if self?.holdTurn == turn { self?.releaseNavigation() }
        }
    }

    /// The response answered, a commit or a failure: QUIET_START's writes
    /// now. Nothing for a hold of HOLD_NAV's, which waits for the frame.
    /// With YAB_NARROW_QUIET_UNTIL=frame, the commit lets go after the
    /// page's next frame instead, as HOLD_NAV does.
    func releaseQuiet(_ moment: QuietMoment) {
        guard quietHold else { return }
        if Narrow.quietUntilFrame {
            switch moment {
            case .answered: return
            case .committed: releaseAfterFrame()
            case .failed: releaseNavigation()
            }
        } else {
            releaseNavigation()
        }
    }

    enum QuietMoment { case answered, committed, failed }

    /// A navigation has begun: undrawn until its own page says it painted.
    /// Cleared here and again when it commits, since a link followed while
    /// the last page was still loading never takes `loading` down to up.
    func navigationStarted(_ navigation: PageNavigation?) {
        if !awaitingDocumentMetadata { prepareDocumentMetadata(for: nil) }
        standingAtFailure = false
        if videoOpening.navigationStarted() { built?.endVideoOpening() }
        toneGate.invalidate()
        retoneArrival &+= 1
        holdNavigation()
        documentPiP.close()
        webKitOnly("WebKit native page state", build: false)?.cancelSwipe()
        // One started over another not yet committed keeps what stood
        // before the first: that page is still the one showing.
        before = (navigation, before?.navigating ?? navigating, before?.drawn ?? drawn)
        navigating = Date().timeIntervalSince1970 * 1000
        askedAt = CACurrentMediaTime()
        if !LinkGap.cut("drawnflag") { drawn = false }
        answered = false
        stoppedEarly = false
        loadMoved.send()
    }

    func navigationCommitted(_ navigation: PageNavigation?, behind: Bool = false) {
        documentMetadataCommitted()
        toneGate.invalidate()
        stepEnded(committed: true)
        steppedAgain = nil
        arrival = Arrival(woken: waking, outOfWindow: builtPage?.window == nil, behind: behind)
        waking = false
        // The page left keeps its last frame for its place in the history:
        // Back to it shows that at once (BACK_STILLS).
        // Its scroll as last said is still the page left's here.
        if Narrow.backStills, let left = lastItem, let page = webKitOnly("WebKit native page state", build: false), let now = page.backForwardList.currentItem, now !== left,
           let stage = page.superview as? StageView {
            let owner = UUID()
            PageStills.shared.move(id, to: owner, like: PageStills.key(page, on: stage))
            itemStills.removeAll { $0.item === left || $0.item === now }
            itemStills.append((left, owner))
            while itemStills.count > 6 { PageStills.shared.forget(itemStills.removeFirst().owner) }
        }
        lastItem = webKitOnly("WebKit native page state", build: false)?.backForwardList.currentItem
        devDocument += 1
        // Another document: the still of the last one is not this page.
        PageStills.shared.forget(id)
        webKitOnly("WebKit native page state", build: false)?.scrollTop = 0
        webKitOnly("WebKit native page state", build: false)?.cancelSwipe()
        automaticFills.reset()
        // A no to the list was for the document now gone.
        wallet.declined = nil
        fieldAutomatic = false
        fieldDocument = nil
        fieldIdentity = nil
        waitingCode = nil
        devLog.reset()
        // The new document says itself whether it is JSON, once read.
        json = nil
        // Dark pages: a document with no dark scripts never asks.
        darkCommitted()
        hearPage()
        recorder.committed(builtPage?.url)
        measureAgain()
        before = nil
        drawn = false
        answered = true
        loadMoved.send()
        // Which way through the history this went, by where the page now
        // shown stood at the last commit: in the pages ahead, forward; in
        // the pages behind, back; nowhere, a new page, and it just appears.
        // So does the page a key went to.
        guard let web = webKitOnly("Native history bookkeeping", build: false) else {
            keyed = nil
            seenBehind = []
            seenAhead = []
            unreadable()
            return
        }
        let list = web.backForwardList
        if let now = list.currentItem {
            if let keyed, keyed == navigation {
                arriving = nil
            } else if seenAhead.contains(where: { $0 === now }) {
                arriving = (1, Date())
            } else if seenBehind.contains(where: { $0 === now }) {
                arriving = (-1, Date())
            } else {
                arriving = nil
            }
        }
        keyed = nil
        seenBehind = list.backList
        seenAhead = list.forwardList
        unreadable()
        // A new document has no reader. One from the back-forward cache
        // comes back as it was left, reader and all, and says so; only a tab
        // that has ever had one asks.
        guard everRead else { return }
        reader = false
        reading = 0
        web.evaluateQuietly(Reader.showing, in: nil, in: Web.world) { [weak self] result in
            guard (try? result.get()) as? Bool == true else { return }
            self?.reader = true
            self?.builtPage?.run(Reader.configure(.saved), in: .yab, gesture: false)
            self?.builtPage?.run("window.__yabReading && window.__yabReading()", in: .yab, gesture: false)
        }
    }

    /// The navigation under way ended before it committed: it failed, was
    /// stopped, or turned into a download. The page still showing is the
    /// one from before, and it is drawn as it was, so a link that downloads
    /// doesn't bring the ring back over a page that has painted. Only the
    /// latest one's: an earlier one, cancelled by it, says so after it began.
    func navigationFailedEarly(_ navigation: PageNavigation?) {
        if let keyed, keyed == navigation { self.keyed = nil }
        guard let before, before.navigation != nil, before.navigation == navigation else { return }
        self.before = nil
        navigating = before.navigating
        drawn = before.drawn
        answered = true
        stoppedEarly = true
        loadMoved.send()
    }

    // MARK: - a step through the history that hangs

    /// WebKit keeps one back-forward cache for the whole process pool, and
    /// every tab shares Web.pool: other tabs' pages going into it push this
    /// tab's out, and a step back or forward to a page pushed out loads it
    /// again and could hang after its response, the page before still
    /// showing, until the next navigation. Plain WKWebViews sharing a pool
    /// do it too: beside twelve others loading, 4 to 7 steps in 30 hung, the
    /// rest committing 10 to 30 ms after their response, and none in pools
    /// of their own. It hangs as the page left goes into the cache: with
    /// this page kept out of the cache none hung, with the others' none.
    /// So a step that loads its page again (one with a response; a page
    /// from the cache has none) leaves its page out of the cache: 1 step
    /// in 60 hung then. One that still hangs is asked again a second after
    /// its response, up to three times, waiting twice as long each time:
    /// asked again, every hung step went in 10 to 20 ms (43 of 43).
    nonisolated static let stepPatience: TimeInterval = 1
    nonisolated static let stepTries = 3

    /// The step under way, to the address WebKit asked about, and how many
    /// times it has been asked again.
    @ObservationIgnored private var stepping: (url: URL, again: Int)?
    /// A step asked again, until a page commits: a try of it counts on.
    @ObservationIgnored private var steppedAgain: (url: URL, again: Int)?
    @ObservationIgnored private var stepCheck: DispatchWorkItem?
    /// The page's back-forward cache turned off for a step, to turn on again.
    @ObservationIgnored private var cacheOffForStep = false
    /// Steps asked again, and the last steps' turns (tests).
    @ObservationIgnored private(set) var stepsAgain = 0
    @ObservationIgnored private(set) var stepTrace: [String] = []
    private static let usesPageCache = NSSelectorFromString("_usesPageCache")
    private static let setUsesPageCache = NSSelectorFromString("_setUsesPageCache:")

    private func traceStep(_ line: String) {
        stepTrace.append(line)
        if stepTrace.count > 16 { stepTrace.removeFirst(stepTrace.count - 16) }
    }

    /// A main-frame navigation asked about (Browser's decidePolicyFor): a
    /// step back or forward to `url`, or nil for any other.
    func historyStep(to url: URL?) {
        stepCheck?.cancel()
        stepCheck = nil
        stepping = url.map { url in (url, steppedAgain.flatMap { $0.url == url ? $0.again : nil } ?? 0) }
        if let stepping { traceStep("asked \(stepping.again)") }
    }

    /// Its response, about to be allowed: the page commits next, at once.
    /// Before the answer goes, so the page's process has the cache off by
    /// the time it commits.
    func historyStepAnswered() {
        guard let step = stepping, let web = webKitOnly("WebKit native page state", build: false) else { return }
        traceStep("answered \(step.again)")
        let preferences = web.configuration.preferences
        if !cacheOffForStep, preferences.responds(to: Self.usesPageCache), preferences.responds(to: Self.setUsesPageCache),
           preferences.value(forKey: "usesPageCache") as? Bool == true {
            cacheOffForStep = true
            preferences.setValue(false, forKey: "usesPageCache")
        }
        guard step.again < Self.stepTries else { return }
        stepCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.stepHung(step) }
        }
        stepCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stepPatience * pow(2, Double(step.again)), execute: check)
    }

    private func stepHung(_ step: (url: URL, again: Int)) {
        stepCheck = nil
        guard let now = stepping, now.url == step.url, now.again == step.again, let web = webKitOnly("WebKit native page state", build: false) else { return }
        guard web.isLoading else { return traceStep("not loading \(step.again)") }
        let list = web.backForwardList
        let items = [list.currentItem].compactMap { $0 } + list.backList.reversed() + list.forwardList
        guard let item = items.first(where: { $0.url == step.url }) else { return traceStep("no item \(step.again)") }
        steppedAgain = (step.url, step.again + 1)
        stepping = steppedAgain
        stepsAgain += 1
        traceStep("hung \(step.again)")
        Watchdog.note("page \(web.contentProcess ?? 0): a step through the history answered and not committed, asked again (\(step.again + 1))")
        // Not stopped first: in plain views stopped and asked again, 16
        // steps in 30 hung; asked again over the hung one, 4.
        web.go(to: item)
    }

    /// Committed or ended: the cache on again for the pages after.
    private func stepEnded(committed: Bool) {
        stepCheck?.cancel()
        stepCheck = nil
        if stepping != nil, committed { traceStep("committed") }
        stepping = nil
        if cacheOffForStep {
            cacheOffForStep = false
            webKitOnly("WebKit native page state", build: false)?.configuration.preferences.setValue(true, forKey: "usesPageCache")
        }
    }

    /// How things stood when the navigation under way began, until it
    /// commits.
    @ObservationIgnored private var before: (navigation: PageNavigation?, navigating: Double, drawn: Bool)?

    /// The history either side at the last commit, to tell back from forward.
    @ObservationIgnored private var seenBehind: [WKBackForwardListItem] = []
    @ObservationIgnored private var seenAhead: [WKBackForwardListItem] = []
    /// A page gone back (-1) or forward (1) to, not yet on screen.
    @ObservationIgnored private var arriving: (side: CGFloat, at: Date)?
    /// The way ⌘[ or ⌘] went, whose page doesn't come in from the side,
    /// until the next commit. The navigation and not the page: one stopped
    /// or failed leaves the same page behind, for a swipe to go to.
    @ObservationIgnored private var keyed: PageNavigation?

    /// The page gone back or forward to is on screen: it comes the last
    /// few points from the side it lies in the history, the side the swipe's
    /// pill stood, as it comes up from a touch faint, 0.14 s. A flash of
    /// direction, not a page sliding in (family-values-motion P8): nothing
    /// to wait for. Only the web view's layer is moved, by animations laid
    /// over it; WebKit is not resized. A page that took over a second to
    /// come just appears.
    private func arrive() {
        guard let way = arriving else { return }
        arriving = nil
        guard Date().timeIntervalSince(way.at) < 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              page.window != nil, let layer = page.layer else { return }
        let pace = Reshape.Pace.arrive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, from) in [("transform.translation.x", way.side * Tab.arrival), ("opacity", -0.15)] {
            let come = CABasicAnimation(keyPath: key)
            come.fromValue = from
            come.toValue = 0
            come.isAdditive = true
            come.duration = 0.14
            come.timingFunction = pace.timing
            layer.add(come, forKey: "arrive." + key)
        }
        CATransaction.commit()
        Tab.arrivals += 1
    }

    private static let arrival: CGFloat = 14
    /// How many pages have come in from the side, for the bench.
    static var arrivals = 0

    /// A page brought back as it was left, from WebKit's cache: it paints
    /// nothing new, so this says it is on screen.
    func shownAgain() {
        timeArrival()
        arrive()
    }

    /// The page painted its first text or picture. `origin` is its
    /// performance.timeOrigin: a message from the page being left, arriving
    /// late, began before this navigation did, and is not this page's. A
    /// quarter second of slack for the two clocks' order.
    /// `paint`: the first contentful paint's own time, in milliseconds
    /// from the document's start, timed for feedback (Lag) even when the
    /// load has finished before the page said so.
    func firstDrawn(origin: Double, paint: Double? = nil) {
        // Said while the navigation's writes are held (its `loading` among
        // them): after them, or it would find the tab not loading and be
        // lost, and the ring would wait for the load event.
        if holdingNavigation {
            held { [weak self] in self?.firstDrawn(origin: origin, paint: paint) }
            return
        }
        if let paint, !shy, origin >= navigating - 250, origin != paintTimed {
            paintTimed = origin
            Lag.shared.timing(.paint, seconds: paint / 1000)
        }
        if origin >= navigating - 250 { timeArrival() }
        guard loading, !drawn, origin >= navigating - 250 else { return }
        drawn = true
        arrive()
    }

    /// The document whose first paint was timed, by its time origin.
    @ObservationIgnored private var paintTimed: Double = 0
    /// When ⌘[ or ⌘] was asked for, until the page it went to is shown.
    @ObservationIgnored private var steppedAt: TimeInterval?

    /// The page back or forward is on screen: how long it took, for
    /// feedback (Lag). A minute on, it was something else that arrived.
    private func timeArrival() {
        guard let at = steppedAt else { return }
        steppedAt = nil
        let seconds = Lag.uptime() - at
        if !shy, seconds < 60 { Lag.shared.timing(.backForward, seconds: seconds) }
    }

    /// Called from the page, a few dozen times a second at most, the script
    /// already waits for a frame before it says anything.
    func scrolled(to y: Double, of ceiling: Double) {
        // Written only when it moves by what the pill can show, half a
        // point of a row: a write, the same number or not, draws again
        // everything that watches the tab, its row and its mark among
        // them, and outside reading mode it was nought on every frame of
        // every scroll.
        let now = reader && ceiling > 0 ? (min(1, max(0, y / ceiling)) * 400).rounded() / 400 : 0
        if now != reading { reading = now }
        // How light the page is under what floats over it, as it scrolls
        // (the color stays the page's, feedback #334). Looked at once the
        // page has been still a moment, and once a second through a long
        // scroll. Each look is one small picture the page's process
        // paints: asked every 0.15 s with the color's look too, as it
        // was, they took the page's frames on a
        // scrolled YouTube watch page (#243, evals/youtube-scroll).
        if !LinkGap.cut("tone") {
            retoneStill = CACurrentMediaTime() + Tab.retoneSettle
            if !retoning {
                retoning = true
                retoneWhenStill(in: Tab.retoneSettle)
            }
        }
        if depthTo == nil, Date() > depthHeld {
            let now = ceiling > 1 && y > 1 ? (min(1, y / ceiling) * 100).rounded() / 100 : nil
            if now != depth { depth = now == 0 ? nil : now }
        }
        let delta = y - lastY
        lastY = y
        webKitOnly("WebKit native page state", build: false)?.scrollTop = y
        // Pictured again once it is still (StageView.moved).
        (builtPage?.superview as? StageView)?.moved(page: builtPage)
        onScroll?(self, y, delta)
    }

    @ObservationIgnored var onNavigate: ((URL) -> HTTPNavigation)?
    @ObservationIgnored var httpNavigation = HTTPNavigation(input: nil, destination: nil)

    func go(to url: URL, fresh: Bool = false) {
        if videoOpening.going(to: url) { built?.endVideoOpening() }
        // A page chosen by hand takes over a pending Instant Link.
        if instantState == .searching { instantTask?.cancel(); instantTask = nil; instantState = nil }
        else if address != nil { instantState = nil }
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened is built from that extension's
        // configuration too. A tab with no page yet was built for where it
        // is going, and goes. Typed into the field, a bookmark, ⌘⇧V: without
        // this, an address sent from an extension's new tab went nowhere.
        if let onCross, let here = builtPage?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // An agent's published page, in a view of its own kind (ArtifactPages).
        if let onCross, ArtifactPages.isPage(url), store !== ArtifactPages.store {
            onCross(self, url)
            return
        }
        // Explicit recovery to another address can leave a view whose
        // termination callback is pending. Keep the usual route checks
        // above, then detach that old document before loading the new one.
        // A warm spare already owns an about:blank Chromium renderer.
        // WebUI needs a browser created at its URL; only an empty document
        // can be discarded here. Live Chromium pages are preserved by send.
        if ChromePages.needsChromium(url), let builtPage, builtPage.engine == .chromium,
           builtPage.url == nil || builtPage.url?.absoluteString == "about:blank" {
            // rest() has no address to retire on an untouched spare.
            discard()
            return goFresh(to: url)
        }
        httpNavigation = onNavigate?(url) ?? HTTPNavigation(input: nil, destination: url)
        engineSent = url
        if fresh { return goFresh(to: url) }
        // A page that doesn't answer would never read where to go.
        if deaf != nil, builtPage != nil { return goFresh(to: url) }
        sentLocal = DevSites.name(url)
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        // A coalesced title write may still be queued for the preceding
        // document. Until this navigation supplies its own title, that
        // write must read an empty cache rather than rename the new page.
        prepareDocumentMetadata(for: url)
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        unreadable()
        typing = false
        immersed = false
        // Sent somewhere new, a sleeping tab is simply awake again, with
        // nothing of where it was before to bring back.
        pending = nil
        memory = nil
        place = nil
        depth = nil
        depthTo = nil
        forgetPicture()
        cover = nil
        // Destination metadata was selected before the load began.
        goSerial &+= 1
        let serial = goSerial
        if (builtPage?.engine ?? engineFactory.upcoming(self, at: url)) != .webKit {
            page.navigate(to: URLRequest(url: url))
            return
        }
        if #available(macOS 15.4, *), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            // Held for an ad blocker loading: its page and content process
            // made meanwhile, once the window is up, so the load starts on a
            // process already running (YAB_LAUNCH_WARM_HELD=0 waits, as before).
            // Its sign-in's: a space's own waits for its own (ExtensionSignIns).
            let extensions = Extensions.of(store: pageStore)
            if extensions.holdsFirstPages, Startup.flag("WARM_HELD") {
                Links.onceShown { [weak self] in
                    guard let self, self.goSerial == serial, self.pending == nil, self.builtPage == nil else { return }
                    guard let web = self.webKitOnly("WebKit navigation warm-up") else { return }
                    if web.responds(to: Tab.launchSelector) { web.perform(Tab.launchSelector) }
                }
            }
            extensions.whenFirstPagesReady { [weak self] in
                guard let self, self.goSerial == serial, self.address == url, self.pending == nil else { return }
                // A spare's view was built before it knew the site: the
                // site's zoom and smallest font, before its first layout.
                if let built = self.webKitOnly("Authenticated WebKit frame context", build: false), built.url == nil { self.applyRememberedZoom() }
                guard let web = self.webKitOnly("WebKit navigation") else { return }
                extensions.willLoad(self)
                OpenTrace.time("load") { web.open(url) }
            }
        } else {
            guard let web = webKitOnly("Native WebKit navigation") else { page.navigate(to: URLRequest(url: url)); return }
            if #available(macOS 15.4, *) { Extensions.of(store: pageStore).willLoad(self) }
            if let back = backList {
                backList = nil
                web.interactionState = back
            }
            web.open(url)
        }
    }

    /// Brought back from the last session: everything the row needs to draw
    /// it. A missing public icon is queued separately; its page stays asleep.
    func restore(url: URL, title: String, history: Any? = nil) {
        resetCountIconProof()
        cancelVideoOpening()
        goSerial &+= 1
        address = url
        // A retired page's queued title must not replace the restored one.
        engineTitle = nil
        retainingEngineTitle = true
        self.title = title
        pending = url
        unopened = true
        if let history { memory = history }
        adoptIcon()
    }

    /// A closed tab back (⌘⇧T, Recently Closed): its page with its back
    /// and forward lists and its place, as it was left, or the address alone
    /// when it left none.
    func reopen(_ ghost: Browser.Ghost) {
        guard let history = ghost.history else { return go(to: ghost.url) }
        restore(url: ghost.url, title: ghost.title, history: history)
        wake()
    }

    /// True for a tab that has a place and an address but is holding no page,
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    func rest(closing: Bool = false) {
        guard let url = address else { return }
        letGoDeaf()
        pending = url
        unopened = true
        memory = nil
        forgetPicture()
        reading = 0
        lastY = 0
        noisy = false
        stale = false
        pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache, alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
        // A manual close gives back an untouched PDF editor. Redo, a
        // signature sheet and unfinished text can survive changed == false.
        if closing, !paper.starting, let desk = paper.desk, !desk.changed,
           desk.undone.isEmpty, !desk.sheet, desk.writing == nil {
            paper.close()
        }
    }

    /// A page that stopped answering ends here, its process with it: WebKit
    /// hands a closing view's goodbye to a main thread that never reads it,
    /// so the process is ended by name (`killContent`). Every other tab in
    /// that process was held by the same loop, and comes back as after any
    /// crash.
    func letGoDeaf() {
        guard deaf != nil, let web = builtPage else { return }
        Watchdog.note("page \(web.contentProcess ?? 0) not answering for \(Int(Date().timeIntervalSince(deaf ?? Date()))) s: ended as its tab moved on")
        web.killContent()
        deaf = nil
    }

    /// Somewhere else on a fresh view, the one that stopped answering ended:
    /// an address typed, back, forward, a pin's home.
    func goFresh(to url: URL) {
        letGoDeaf()
        rest()
        restore(url: url, title: "")
        _ = wake()
    }

    /// Back to the address it was pinned or kept at (`home`): a page on
    /// screen goes there as a link would, the way back still behind it; a
    /// tab asleep is put there, nothing of where it was kept, to load when
    /// it is next looked at.
    func sendHome() {
        guard let home else { return }
        guard asleep else { return go(to: home) }
        memory = nil
        place = nil
        depth = nil
        depthTo = nil
        forgetPicture()
        restore(url: home, title: homeTitle ?? "")
    }

    /// WebKit's title, but not the address it names a page by while that
    /// page has none yet: "https://www.raycast.com/new" in the row, then
    /// "raycast.com/new", then the name, where Arc shows only the name.
    /// After a navigation that was stopped before it committed (the
    /// flagged page's Go Back): the address and title of the page still
    /// shown, which `go(to:)` had already moved on from. False when the
    /// tab shows no page at all.
    func settleOnShown() -> Bool {
        guard let shown = builtPage?.url, shown.absoluteString != "about:blank" else { return false }
        awaitingDocumentMetadata = false
        address = shown
        title = pageTitle
        adoptIcon()
        return true
    }

    private var pageTitle: String {
        if retainingEngineTitle { return title }
        let said = engineTitle ?? ""
        if said == engineURL?.absoluteString || said == address?.absoluteString { return "" }
        return said
    }

    /// The page's title, into the row, at once, and then no more than
    /// four times a second, the latest one last. Some pages write their
    /// title every frame (a clock, a counter, a progress bar in the tab),
    /// and every write draws the tab again on the main thread.
    private func retitle() {
        let wait = 0.25 - Date().timeIntervalSince(titled)
        guard wait > 0 else {
            titled = Date()
            title = pageTitle
            recount()
            learnHomeTitle()
            return
        }
        guard !titling else { return }
        titling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            titling = false
            titled = Date()
            title = pageTitle
            recount()
            learnHomeTitle()
        }
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?, reason: FeedbackDiagnostics.SleepReason = .other, maySleep: (() -> Bool)? = nil, done: ((Bool) -> Void)? = nil) {
        if let chromium = builtPage as? ChromiumPage {
            guard let url = address, sleepAttempt == nil else { done?(false); return }
            let attempt = UUID(), revision = engineNavigationRevision
            sleepAttempt = attempt
            Task { @MainActor [weak self, weak chromium] in
                guard let self, let chromium else { done?(false); return }
                guard self.sleepAttempt == attempt else { done?(false); return }
                // Revalidate when the queued task starts, before Chromium
                // destroys the document. A visit may have superseded the request.
                guard maySleep?() != false else {
                    self.sleepAttempt = nil
                    done?(false); return
                }
                let accepted = await chromium.discardForSleep()
                guard self.sleepAttempt == attempt else { done?(false); return }
                self.sleepAttempt = nil
                guard accepted else { done?(false); return }
                guard !self.gone, self.builtPage === chromium,
                      self.engineNavigationRevision == revision, maySleep?() != false else {
                    if self.builtPage === chromium { chromium.restoreFromSleep() }
                    done?(false); return
                }
                self.carriedEntry = self.currentEntry
                self.notePlace(); self.keep(picture)
                // Its last frame goes, as a WebKit page's does (discard): it
                // sleeps under its picture, and a still kept for every tab
                // that ever slept filled the stills' budget in the app.
                PageStills.shared.forget(self.id)
                self.pending = url
                self.sleepingChromium = chromium
                self.builtPage = nil
                chromium.events = nil; chromium.stateEvents = nil
                chromium.removeFromSuperview()
                self.loading = false
                self.ears.stop(); self.tuneWatch.stop()
                // The discarded document cannot own a stale Wait/Reload ask.
                // This is retirement, not a fabricated responsiveness pong.
                let dismissDeaf = self.deafAsked && self.asks.first?.kind == .stuck
                self.deaf = nil; self.deafAsked = false; self.deafQuiet = .distantPast
                if dismissDeaf { (self.delegate as? Browser)?.dismissAsk(self) }
                if !self.shy { FeedbackDiagnostics.shared.slept(reason) }
                done?(true)
            }
            return
        }
        let wasAwake = !asleep
        defer {
            if wasAwake, asleep, !shy {
                FeedbackDiagnostics.shared.slept(reason)
                // Every page Yab put down, and so loads again when it is
                // shown, says why in stalls.log; one put down by hand needs
                // no word (#446).
                if reason != .manual { Watchdog.note("tab put to sleep: \(reason.rawValue)") }
            }
        }
        if engineKind != .webKit {
            guard let url = address, builtPage != nil else { return }
            carriedEntry = currentEntry
            notePlace()
            keep(picture)
            pending = url
            discard()
            done?(true)
            return
        }
        guard let url = address, let built = webKitOnly("WebKit sleep history", build: false) else { done?(false); return }
        memory = built.interactionState
        memoryBehind = built.isLoading && built.backForwardList.currentItem?.url != url
        notePlace()
        keep(picture)
        pending = url
        stale = false
        pull = nil
        discard()
        done?(true)
    }

    /// Whether the page holds something typed and not yet sent, a draft, a
    /// half-filled form. A page that can't answer is treated as holding
    /// nothing: a PDF, an image, a page whose process has already gone.
    func unsaved(_ done: @escaping (Bool) -> Void) {
        probeUnsaved { done($0 == true) }
    }

    /// Keep a failed reply distinct from a page that answered "nothing".
    private func probeUnsaved(_ done: @escaping (Bool?) -> Void) {
        guard let builtPage else { return done(false) }
        builtPage.runInYab(
            "!!(window.__yabForms && window.__yabForms.unsaved && window.__yabForms.unsaved())"
        ) { value in
            MainActor.assumeIsolated { done(value as? Bool) }
        }
    }

    /// `unsaved`, or nil when the page hasn't answered within `seconds`.
    func unsaved(within seconds: TimeInterval, _ done: @escaping (Bool?) -> Void) {
        // Nobody has typed or clicked in this Chromium page, so it holds
        // nothing of theirs: with 120 tabs up a hidden page's answer can take
        // 15 s, and asking would keep every untouched tab awake.
        if let page = builtPage, page.engine == .chromium, page.lastInput == nil, !draft { return done(false) }
        var answered = false
        let once = { (typed: Bool?) in
            guard !answered else { return }
            answered = true
            done(typed)
        }
        // A failed probe cannot clear a draft the page already reported.
        // An actual false answer still wins over the cached report.
        probeUnsaved { [weak self] typed in once(typed ?? self?.draft ?? false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { once(nil) } }
    }

    /// `snapshot`, or nil when the page hasn't drawn within `seconds`.
    func snapshot(within seconds: TimeInterval, _ done: @escaping (Data?) -> Void) {
        var answered = false
        let once = { (picture: Data?) in
            guard !answered else { return }
            answered = true
            done(picture)
        }
        snapshot { once($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { once(nil) } }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen, every tab but the one you are
    /// on, can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard let builtPage else { return done(nil) }
        let encode = { (image: NSImage?) in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
        // Chromium draws only what is on screen (as `glance` says). Asked for
        // a page in the back (a tab going to sleep), its screenshot waits for a
        // frame its hidden window never presents, and the capture holds that
        // window's compositor awake meanwhile, so the window kept its last
        // frame in the GPU process for as long as the tab slept (CEF 0117,
        // evals/chromium-memory). The picture of a page in the back is the
        // last frame it showed, as ⌃Tab's is.
        if let native = builtPage as? ChromiumPage, native.window == nil || native.isHiddenOrHasHiddenAncestor {
            let kept = native.lastPicture
            PageStills.shared.picture(of: id, width: .greatestFiniteMagnitude) { encode($0 ?? kept) }
            return
        }
        builtPage.snapshot(PageShot()) { image, _ in encode(image) }
    }

    /// A small picture for the ⌃Tab switcher. A page that is there is drawn
    /// now, at the size it will be shown, which costs a few milliseconds; a
    /// page asleep offers the picture it went to sleep with. A tab brought
    /// back from last session and never opened has none.
    func glance(width: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        let native = builtPage as? ChromiumPage
        let kept = native?.lastPicture ?? cover ?? lookAtPicture()
        guard let builtPage, builtPage.bounds.width > 0 else { return done(kept) }
        // Chromium draws only what is on screen: a page in the back is the
        // last frame it showed, kept when it was left, or the one taken while it was in front.
        if let native, native.window == nil || native.isHiddenOrHasHiddenAncestor {
            PageStills.shared.picture(of: id, width: width) { done($0 ?? kept) }
            return
        }
        builtPage.snapshot(PageShot(width: width, afterUpdates: false)) { image, _ in
            MainActor.assumeIsolated { done(image ?? kept) }
        }
    }

    // MARK: - pictures of sleeping pages, on disk

    /// Where they are kept: in this world's folder, for this run only.
    nonisolated static let pictures = Store.file("pictures")
    /// One queue for every write and removal, so a removal never runs ahead
    /// of the write it is meant to undo.
    nonisolated static let disk = DispatchQueue(label: "pictures", qos: .utility)
    nonisolated private static func pictureFile(_ id: UUID) -> URL {
        pictures.appendingPathComponent(id.uuidString + ".jpg")
    }

    private func keep(_ data: Data?) {
        forgetPicture()
        guard let data else { return }
        picture = data
        picturing += 1
        // A private page's picture never reaches the disk: kept here, a
        // few hundred kilobytes, for as long as the tab sleeps.
        guard !shy else { return }
        let turn = picturing
        let file = Tab.pictureFile(id)
        Tab.disk.async {
            try? FileManager.default.createDirectory(at: Tab.pictures, withIntermediateDirectories: true)
            let written = (try? data.write(to: file)) != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, written, picturing == turn else { return }
                picture = nil
                pictured = true
            }
        }
    }

    /// The picture, whether it is still here or already in its file. Read
    /// whole, not by reference: the file may go a moment later.
    private func lookAtPicture() -> NSImage? {
        if let picture { return NSImage(data: picture) }
        guard pictured, let data = try? Data(contentsOf: Tab.pictureFile(id)) else { return nil }
        return NSImage(data: data)
    }

    private func forgetPicture() {
        let had = pictured || picture != nil
        picturing += 1
        picture = nil
        pictured = false
        guard had else { return }
        let file = Tab.pictureFile(id)
        Tab.disk.async { try? FileManager.default.removeItem(at: file) }
    }

    deinit {
        let file = Tab.pictureFile(id)
        Tab.disk.async { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - what the page costs

    /// What the page's process holds in memory, in bytes, what Activity
    /// Monitor calls its Memory. Zero with no page, or if WebKit will not
    /// say which process is its. A syscall, a few microseconds.
    var weight: UInt64 {
        guard let pid = builtPage?.contentProcess, pid > 0
        else { return 0 }
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : 0
    }
    private static let processSelector = NSSelectorFromString("_webProcessIdentifier")

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built = builtPage,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.runInYab("window.__yabStore && window.__yabStore.state(\(json))")
    }

    /// A closed tab brought back into a window that showed no page: its
    /// last frame over it till its page has drawn (Browser.bringStill).
    func cover(with picture: NSImage) {
        cover = picture
        uncover(after: 4)
    }

    /// The picture comes off the moment there is something better under it
    /// the page, painted, or you reach for the page yourself.
    func uncover(after delay: TimeInterval = 0) {
        guard let shown = cover else { return }
        guard delay > 0 else {
            cover = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cover === shown else { return }
            self.cover = nil
        }
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false
    var staleReason: PageEnd?

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping, asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash(reason: PageEnd? = nil) {
        deaf = nil
        deafQuiet = .distantPast
        guard let address else { return }
        if !shy {
            FeedbackDiagnostics.shared.reloadedAfterTermination(reason: reason)
            Watchdog.note("page loaded again after its process ended: \(reason?.word ?? "unknown")")
        }
        notePlace()
        failure = nil
        if engineKind != .webKit { page.navigate(to: URLRequest(url: address)); return }
        loadAndVerify(address)
    }

    /// The page's process is gone, or the view is about to go: where it was
    /// scrolled, as the page last said, for `returnToPlace`.
    func notePlace() {
        guard let url = address else { return }
        if lastY > 1 { place = (url, lastY) } else if place?.url != url { place = nil }
    }

    /// A Chromium page has no scroll relay yet: its place is read once,
    /// half a second at most, before it goes to sleep. WebKit's is known.
    func readChromiumPlace(then: @escaping () -> Void) {
        guard let page = builtPage, page.engine == .chromium else { return then() }
        let revision = engineNavigationRevision
        var answered = false
        let once = { guard !answered else { return }; answered = true; then() }
        page.run("scrollY", in: .yab, gesture: false) { [weak self, weak page] result in
            guard !answered else { return }
            if let self, let page, !gone, builtPage === page, engineNavigationRevision == revision,
               let y = (try? result.get()) as? Double, y.isFinite, y >= 0 { lastY = y }
            once()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { once() } }
    }

    /// Loaded again after it slept or its process went: back where it was,
    /// once, the way browsers restore a page's place. WebKit keeps a place
    /// only for a page left by a link, so a woken page would come back at its
    /// top. A page drawn by its own script (GitHub's) is still too short when
    /// it loads, so this waits, up to five seconds, until the page is tall
    /// enough, scrolls there once and stops; your own scroll or key first
    /// cancels it, and whatever the page does afterwards is its own.
    /// A depth from the row, at launch or from another Mac: a page not
    /// loaded goes there once it loads, one on screen is left where it is,
    /// one loaded out of sight goes there now.
    func arrive(at depth: Double?, now: Bool = false) {
        guard depth != self.depth else { return }
        self.depth = depth
        guard let depth, depth > 0 else { depthTo = nil; return }
        depthTo = depth
        if now, builtPage?.isLoading == false { returnToPlace() }
    }

    func returnToPlace() {
        if place == nil, let depth = depthTo {
            depthTo = nil
            depthHeld = Date().addingTimeInterval(6)
            guard let built = builtPage else { return }
            // Once the page has its height, or after five seconds; your
            // own scroll or key first cancels it.
            built.runInYab("""
            (function (f) {
              var until = Date.now() + 5000, yours = false, last = -1;
              function own() { yours = true; }
              ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(function (name) {
                window.addEventListener(name, own, { capture: true, passive: true, once: true });
              });
              function go() {
                if (yours) return;
                var root = document.documentElement, ceiling = root.scrollHeight - window.innerHeight;
                if (Date.now() > until || (document.readyState === 'complete' && ceiling === last && ceiling > 0)) {
                  window.scrollTo(0, Math.round(f * Math.max(0, ceiling)));
                  return;
                }
                last = ceiling;
                setTimeout(go, 150);
              }
              go();
            })(\(depth))
            """)
            return
        }
        guard let back = place else { return }
        place = nil
        guard let built = builtPage, built.url?.absoluteString == back.url.absoluteString else { return }
        built.runInYab("""
        (function (y) {
          var until = Date.now() + 5000, yours = false;
          function own() { yours = true; }
          ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(function (name) {
            window.addEventListener(name, own, { capture: true, passive: true, once: true });
          });
          function go() {
            if (yours || Date.now() > until) return;
            if (document.documentElement.scrollHeight - window.innerHeight >= y - 2) {
              window.scrollTo(0, y);
              window.__yabPlace = { y: y, moved: 1 };
              return;
            }
            setTimeout(go, 100);
          }
          window.__yabPlace = { y: y, moved: 0 };
          go();
        })(\(Int(back.y)))
        """)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take, no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil, behind: Bool = false, tries: Int = 0) {
        // This recovery belongs to one view and one request. Waiting for a
        // window, or for WebKit's answer, must never wake a discarded tab or
        // overwrite a newer navigation. Any provisional start means the
        // original load took, so the ignored-load workaround is no longer
        // needed, even if that navigation later stops or changes address.
        let serial = goSerial
        let started = askedAt
        func current(_ tab: Tab, _ view: PageView) -> Bool {
            !tab.gone && tab.pending == nil && tab.webKitOnly("Authenticated WebKit frame context", build: false) === view && tab.goSerial == serial
                && tab.askedAt == started && tab.address == url
        }
        func load(_ tries: Int, owner: Tab?, view: PageView?) {
            guard let owner, let view, current(owner, view) else { return }
            // A selected sleeping page waits for its view to be attached;
            // the fallback still allows recovery without a waiting stage.
            if view.window == nil, tries == 0, Startup.flag("LOAD_ON_WINDOW") {
                var done = false
                let go = { [weak owner, weak view] (tries: Int) in
                    guard !done else { return }
                    done = true
                    guard let owner, let view, current(owner, view) else { return }
                    view.onWindow = nil
                    load(tries, owner: owner, view: view)
                }
                view.onWindow = { DispatchQueue.main.async { go(1) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { go(50) }
                return
            }
            if view.window == nil, tries < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak owner, weak view] in
                    load(tries + 1, owner: owner, view: view)
                }
                return
            }
            // Preserve the page's remembered history when waking it.
            if let state {
                view.interactionState = state
                if behind { view.open(url) }
            } else {
                view.open(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak owner, weak view] in
                guard let owner, let view, current(owner, view) else { return }
                if view.url?.absoluteString == "about:blank" {
                    view.open(url)
                    return
                }
                view.evaluateQuietly("document.readyState") { [weak owner, weak view] _, error in
                    MainActor.assumeIsolated {
                        guard let owner, let view, current(owner, view), let error = error as NSError? else { return }
                        guard error.domain == WKErrorDomain,
                              error.code == WKError.webContentProcessTerminated.rawValue
                        else { return }
                        view.open(url)
                    }
                }
            }
        }
        if let web = webKitOnly("WebKit load verification") { load(tries, owner: self, view: web) }
        else { page.navigate(to: URLRequest(url: url)) }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// memory pressure, a long sleep, comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        // Remote pages report loss through their event stream and recover on
        // explicit navigation/reload. The WebKit readiness probe must not
        // instantiate or cast a second engine when a column row is selected.
        if stale {
            stale = false
            let reason = staleReason
            staleReason = nil
            recoverFromCrash(reason: reason)
            return
        }
        guard engineKind == .webKit else { return }
        guard !isBlank, pending == nil, !loading, failure == nil,
              let web = webKitOnly("WebKit readiness recovery") else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.open(address)
            return
        }
        web.evaluateQuietly("document.readyState") { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake, the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        waking = true
        failure = nil
        reading = 0
        lastY = 0
        reader = false
        unreadable()
        typing = false
        immersed = false
        let state = memory
        let behind = memoryBehind
        memory = nil
        memoryBehind = false
        if let image = lookAtPicture() {
            cover = image
            // Whatever happens to the page, the picture doesn't outstay it.
            uncover(after: 4)
        }
        forgetPicture()
        goSerial &+= 1
        let serial = goSerial
        if let sleeping = sleepingChromium, sleeping.remoteID != nil,
           sleeping.profile == chromiumProfile,
           engineFactory.upcoming(self, at: url) == .chromium {
            _ = page // Restore the same native controller, never replay its URL.
            return true
        }
        if (builtPage?.engine ?? engineFactory.upcoming(self, at: url)) != .webKit {
            page.navigate(to: URLRequest(url: url))
            return true
        }
        if #available(macOS 15.4, *), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            // Held for an ad blocker loading: its page and content process
            // made meanwhile, once the window is up, so the load starts on a
            // process already running (YAB_LAUNCH_WARM_HELD=0 waits, as before).
            let extensions = Extensions.of(store: pageStore)
            if extensions.holdsFirstPages, Startup.flag("WARM_HELD") {
                Links.onceShown { [weak self] in
                    guard let self, self.goSerial == serial, self.pending == nil, self.builtPage == nil else { return }
                    guard let web = self.webKitOnly("WebKit navigation warm-up") else { return }
                    if web.responds(to: Tab.launchSelector) { web.perform(Tab.launchSelector) }
                }
            }
            extensions.whenFirstPagesReady { [weak self] in
                guard let self, self.goSerial == serial, self.address == url, self.pending == nil else { return }
                self.loadAndVerify(url, state: state, behind: behind)
            }
        } else {
            loadAndVerify(url, state: state, behind: behind)
        }
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    /// An address never loaded, said as the tab's own, the page before it
    /// left on screen under `failure`: an extension's OAuth redirect in a
    /// tab it opened itself (ExtensionAuth.intercept), which it reads off
    /// the tab's address as it does in Chrome.
    func stand(at url: URL, failure: String) {
        standingAtFailure = true
        address = url
        self.failure = failure
    }

    func touch(at when: Date = Date()) {
        touched = when
        touchedAwake = AwakeClock.since(when)
    }

    /// How long it has gone unwatched at `now`, on the awake clock.
    func idle(at now: TimeInterval) -> TimeInterval { now - touchedAwake }

    /// True when the web view holds nothing, never loaded, or emptied,
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let builtPage else { return address != nil }
        guard let there = builtPage.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// Again from the network. A view that has lost its document is given
    /// the address back instead: there is nothing else for it to reload.
    func reload() {
        cancelVideoOpening()
        // ⌘R as Chromium does it: revalidated, through the site's service worker, so a
        // page that works offline reloads offline. ⇧⌘R is the one past both.
        if engineKind != .webKit { if !wake() { page.reload(fromOrigin: false) }; return }
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake(), let web = webKitOnly("WebKit reload") else { return }
        if hollow, let address {
            web.open(address)
        } else {
            web.reloadFromOrigin()
        }
    }
    /// ⇧⌘R: the page again from the network, past the cache
    /// (WebKit's reload from origin) and past the site's service worker,
    /// which a reload from origin still asks, so it goes first. Only the
    /// worker is waited for, a quick look. What the site left in the caches
    /// is thrown out beside the reload, not before it: finding that means
    /// the network process walking every entry of the disk cache, every
    /// site's, seconds in a profile used for a while (register row 998).
    func hardReload() {
        if engineKind != .webKit { if !wake() { page.reload(fromOrigin: true) }; return }
        guard !wake() else { return }
        guard let host = address?.host?.lowercased(), !hollow else { return reload() }
        guard let web = webKitOnly("WebKit service-worker reset") else { return }
        let store = web.configuration.websiteDataStore
        // A record is named for the site, "example.com", which covers its
        // subdomains too.
        func theirs(_ records: [WKWebsiteDataRecord]) -> [WKWebsiteDataRecord] {
            records.filter {
                let name = $0.displayName.lowercased()
                return host == name || host.hasSuffix("." + name)
            }
        }
        let caches: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        store.fetchDataRecords(ofTypes: caches) { records in
            store.removeData(ofTypes: caches, for: theirs(records)) {}
        }
        let workers: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations]
        store.fetchDataRecords(ofTypes: workers) { [weak self] records in
            let site = theirs(records)
            guard !site.isEmpty else {
                return MainActor.assumeIsolated { _ = self?.builtPage?.reload(fromOrigin: true) }
            }
            store.removeData(ofTypes: workers, for: site) {
                MainActor.assumeIsolated { _ = self?.builtPage?.reload(fromOrigin: true) }
            }
        }
    }
    /// The site's cookies thrown out, then the page again (Browser's
    /// clearCookiesAndRefresh). A record is named for the site,
    /// "example.com", and holds its subdomains' cookies too.
    func clearCookiesAndReload() {
        guard !wake() else { return }
        guard let host = address?.host?.lowercased(), !hollow else { return reload() }
        let store = pageStore
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        Task { @MainActor [weak self] in
            let records = await store.dataRecords(ofTypes: types)
            let theirs = records.filter {
                let name = $0.displayName.lowercased()
                return host == name || host.hasSuffix("." + name)
            }
            await store.removeData(ofTypes: types, for: theirs)
            // Both engines share the sign-in, whichever shows this page.
            await ChromiumSiteData.clearCookies(site: Browser.site(host), page: self?.builtPage as? ChromiumPage)
            self?.reload()
        }
    }
    func stop() { cancelVideoOpening(); page.stopLoading() }
    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again, nothing is kept behind to make that look otherwise.
    /// By a key the page just appears: coming in
    /// from the side (`arrive`) answers the swipe and the buttons.
    func back(byKey: Bool = false) {
        if !hasBackHistory, builtPage?.canGoBack != true, onBackAtStart?(self) == true { return }
        if engineKind != .webKit { page.navigateBack(); return }
        if deaf != nil, let to = webKitOnly("WebKit native page state", build: false)?.backForwardList.backItem?.url { return goFresh(to: to) }
        guard let web = webKitOnly("Native WebKit history") else { page.navigateBack(); return }
        let going = web.goBack()
        if going != nil { steppedAt = Lag.uptime() }
        keyed = byKey ? going?.pageNavigation : nil
    }
    func forward(byKey: Bool = false) {
        if engineKind != .webKit { page.navigateForward(); return }
        if deaf != nil, let to = webKitOnly("WebKit native page state", build: false)?.backForwardList.forwardItem?.url { return goFresh(to: to) }
        guard let web = webKitOnly("Native WebKit history") else { page.navigateForward(); return }
        let going = web.goForward()
        if going != nil { steppedAt = Lag.uptime() }
        keyed = byKey ? going?.pageNavigation : nil
    }

    /// Called when the tab is thrown away: release its page and callbacks.
    func close() {
        AgentNotices.shared.clear(self)
        handoffNotice = nil
        instantTask?.cancel()
        instantTask = nil
        instantState = nil
        letGoDeaf()
        Boosts.shared.closed(self)
        Userscripts.shared.closed(self)
        if !shy { FeedbackDiagnostics.shared.record(.tabClosed) }
        gone = true
        Browser.visitMoved(self)
        onBackAtStart = nil
        onCloseUnshown = nil
        backSourceAvailable = false
        onScroll = nil
        onZoom = nil
        onPick = nil
        onPickEnd = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        onWalletField = nil
        onPaid = nil
        onFilesAway = nil
        discard()
        ChromiumPrivateProfiles.release(self)
        let which = lingerNote.isEmpty ? address?.host() ?? address?.scheme ?? "" : lingerNote
        Lingering.expectGone(self, "a closed tab", detail: which)
        // An extension's own page shares its extension's controller.
        if address?.scheme?.hasSuffix("-extension") != true {
            // Its view, and the controller with it, is seen off first
            // (Farewell), three and a half seconds at most.
            if let madeConfiguration { Lingering.expectGone(madeConfiguration.userContentController, "a closed tab's scripts", detail: which, after: 5) }
        }
    }

    /// The view and everything listening to it, gone, timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    /// The page's badge, as its Badging API call said.
    func badged(_ n: Int?) {
        badge = n ?? 0
        showsOwnCount = true
        recount()
    }

    /// The count from the badge, else from the title. Published only when
    /// the number changes; which marks show it is theirs to say (MarkCorners).
    @discardableResult
    private func recount() -> Int? {
        // Gmail's title counts the folder being viewed, including Spam.
        // Its existing Primary feed is the pin's unread count in every folder.
        let n: Int?
        let observed: Int?
        if builtPage == nil {
            n = sourceCount
            observed = n
        } else if address?.host()?.lowercased() == "mail.google.com" {
            n = badge ?? sourceCount
            observed = n // Missing feed data is unknown, not an observed zero.
        } else {
            n = badge ?? Counts.fromTitle(countTitle ?? title) ?? sourceCount
            observed = n ?? 0 // A live title without a count represents none.
        }
        if count != n { count = n }
        return observed
    }

    /// A replacement has the same row id but a different owner. Native CEF
    /// browsers require an explicit end; dropping an NSView cannot close one.
    /// WebKit retains its existing in-flight reply lifetime.
    func retireReplacedChromiumPage() {
        guard engineKind == .chromium else { return }
        gone = true
        discard()
    }

    private func discard() {
        sleepAttempt = nil
        if let sleeping = sleepingChromium {
            sleepingChromium = nil
            sleeping.retire(call: false, pictureInPicture: false)
        }
        chromiumDRMExtensions?.detach()
        chromiumDRMExtensions = nil
        cancelVideoOpening()
        // Asleep, put down or closed: the next look builds it afresh, under
        // the picture it slept with, if any (`cover`).
        PageStills.shared.forget(id)
        ChatBusy.left(self)
        deaf = nil
        deafAsked = false
        deafQuiet = .distantPast
        let calling = onCall
        documentPiP.close()
        builtPage?.stateEvents = nil
        // No loading observer remains to clear the row's ring or cancel its
        // delayed appearance once this page is gone.
        loading = false
        camera = .none
        microphone = .none
        screen = .none
        resetCountIconProof()
        if count != nil { count = nil }
        ears.stop()
        tuneWatch.stop()
        guard let page = builtPage else { return }
        builtPage = nil
        page.retire(call: calling, pictureInPicture: pictureInPicture)
        pictureInPicture = false
    }

    private static let closeSelector = NSSelectorFromString("_close")

    /// The page ended now, not when the last hold on its view lets go. An
    /// animation, a closure or a window not yet released kept a tab's page
    /// running after it closed or went to sleep: its timers, its sockets,
    /// and the scripts extensions put in it, which WebKit no longer had a
    /// tab for and which asked for one again and again.
    static func end(_ web: WKWebView) {
        PageFullScreenMove.ended(web)
        if web.responds(to: closeSelector) { web.perform(closeSelector) }
    }
}

/// A page going, seen off before it ends. Ended at once, a tab's page ran
/// its pagehide and unload, but nothing they sent ever left: Meet heard no
/// goodbye and kept you in the call for everyone else after ⌘W, until it
/// gave up on you. Taken to an empty page first, as leaving for another
/// site would, the page says goodbye while it can still be heard, and ends
/// once the empty page is in. A call's own Leave is pressed before that, as
/// the call window's Leave does, its microphone and camera muted at once.
/// Each step has a deadline: a page that never answers still ends.
@MainActor
final class Farewell: NSObject, WKNavigationDelegate {
    private static var going: [ObjectIdentifier: Farewell] = [:]
    private static let pageCache = NSSelectorFromString("_setUsesPageCache:")

    private let web: WKWebView
    private let born = Date()
    private var left = false
    private var ended = false

    /// Where a page says goodbye: a window never shown. Out of every
    /// window, WebKit may suspend the page's process, and its goodbye
    /// with it until the deadline ends the page anyway.
    private static let room: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }()

    private static let tracing = ProcessInfo.processInfo.environment["YAB_FAREWELL_TRACE"] == "1"

    private func trace(_ step: String) {
        guard Self.tracing else { return }
        print("YAB_FAREWELL \(step) +\(String(format: "%.3f", Date().timeIntervalSince(born)))", web.url?.absoluteString ?? "-")
    }

    static func see(_ web: WKWebView, call: Bool) {
        let farewell = Farewell(web)
        going[ObjectIdentifier(farewell)] = farewell
        // The old document can still act while its call leaves or its
        // goodbye loads. Keep policy coverage until the view ends.
        web.navigationDelegate = farewell
        room.contentView?.addSubview(web)
        farewell.trace(call ? "start call" : "start")
        farewell.start(call: call)
    }

    private init(_ web: WKWebView) { self.web = web }

    /// Once every page being seen off has ended and half a second more,
    /// or `seconds` from now: what ⌘Q waits for on a call. The half second
    /// is for what the pages sent on their way out: it leaves through
    /// WebKit's network process, which goes with yab.
    static func whenDone(within seconds: TimeInterval, _ done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func look() {
            if Date() >= deadline { return done() }
            guard going.isEmpty else { return after(0.1) { look() } }
            after(min(0.5, max(deadline.timeIntervalSinceNow, 0))) { done() }
        }
        look()
    }

    /// Later, on the main run loop in every mode, not the main queue: a
    /// quit waiting on pages (terminateLater) turns a modal loop, and when
    /// a block on the main queue set it off, as ⌘Q's question does, the
    /// queue's other blocks wait for it to end.
    private static func after(_ seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { run() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func start(call: Bool) {
        guard call else { return leave() }
        web.setMicrophoneCaptureState(.muted, completionHandler: {})
        web.setCameraCaptureState(.muted, completionHandler: {})
        CallStage.run("leave", on: web) { [weak self] pressed in
            self?.trace("left the call \(pressed ?? "nil")")
            self?.leave()
        }
        // Off screen, a page's timers slow: Meet's question may never come.
        Self.after(2) { [weak self] in self?.leave() }
    }

    private func leave() {
        guard !left, !ended else { return }
        left = true
        // Kept in the back-forward cache, the page would only be put away,
        // its unload never run.
        let preferences = web.configuration.preferences
        if preferences.responds(to: Self.pageCache) { preferences.setValue(false, forKey: "usesPageCache") }
        web.load(URLRequest(url: URL(string: "about:blank")!))
        trace("leave")
        Self.after(1.5) { [weak self] in self?.trace("deadline"); self?.end() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let request = action.nativeRequest else { decisionHandler(.cancel); return }
        // A masked DOM address is an engine sentinel, never another app's
        // link. With no policy WebKit may hand it to Launch Services.
        decisionHandler(request.url?.scheme?.lowercased() == "webkit-masked-url" ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { trace("commit") }
    // Policy begins before a call's Leave answers. An old navigation's
    // terminal callback must not end that document while Leave still waits.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard left else { return }; trace("finish"); end() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard left else { return }; trace("fail \(error)"); end() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard left else { return }; trace("fail early \(error)"); end() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { trace("process gone"); end() }

    private func end() {
        guard !ended else { return }
        ended = true
        trace("end")
        web.navigationDelegate = nil
        web.removeFromSuperview()
        Tab.end(web)
        Self.going[ObjectIdentifier(self)] = nil
        // Its process goes with the last view in it: a view still held a
        // second from now is a page still running under a tab that looks
        // asleep (PageProcesses).
        Lingering.expectGone(web, "a page view let go")
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework, so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }

    // MARK: - silencing it

    /// The same quiet name, for the page's sound as a whole, what Safari's
    /// own mute button uses. Every video and every sound on the page, in
    /// every frame, whatever the page does to its own volume.
    private static let muting = NSSelectorFromString("_setPageMuted:")
    private static let mutedState = NSSelectorFromString("_mediaMutedState")
    /// Audio, alone among what can be muted: the camera and microphone
    /// bits of the same word are left as they are.
    private static let audio: UInt = 1 << 0

    static let canMute = WKWebView.instancesRespond(to: muting) && WKWebView.instancesRespond(to: mutedState)

    static func mute(_ web: WKWebView, _ on: Bool) {
        guard canMute else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> UInt
        typealias Set = @convention(c) (AnyObject, Selector, UInt) -> Void
        let get = unsafeBitCast(web.method(for: mutedState), to: Get.self)
        let set = unsafeBitCast(web.method(for: muting), to: Set.self)
        let now = get(web, mutedState)
        set(web, muting, on ? now | audio : now & ~audio)
    }
}

/// A trackpad's scroll that begins on a page goes on to that page, its moves
/// and its glide, without AppKit looking again for where each one lands. It
/// does look, for every one of them: from the window's frame down through
/// the root hosting view and every hover and gesture SwiftUI keeps over the
/// page, which cost the main thread more than the page's own scrolling did.
/// The first event of each gesture, and a mouse's wheel, which has no
/// gesture, are still looked for as AppKit does, so the page a gesture
/// begins over, the column, the strip or a card's list, keeps it.
@MainActor
enum ScrollLatch {
    private static weak var page: NSView?
    private static var monitor: Any?

    /// A gesture began on `page`.
    static func hold(_ page: NSView) {
        self.page = page
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { route(event) }
        }
    }

    /// A column moved offscreen by its layer keeps its AppKit geometry.
    static func release(in root: NSView) {
        guard let page, page === root || page.isDescendant(of: root) else { return }
        self.page = nil
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        guard let page else { return event }
        // A new gesture, or a wheel, or somewhere else: let go, and let
        // AppKit find its view.
        let gesture = event.phase != [] || event.momentumPhase != []
        guard gesture, event.phase != .began, event.phase != .mayBegin,
              page.window != nil, event.window === page.window,
              // A hidden peek or a fully clipped page no longer owns the
              // gesture, even while its view remains in the same window.
              !page.isHiddenOrHasHiddenAncestor,
              !page.visibleRect.intersection(page.bounds).isEmpty
        else {
            self.page = nil
            return event
        }
        page.scrollWheel(with: event)
        // The glide over, or a gesture that ended with none: the next one
        // is looked for afresh.
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled || event.phase == .cancelled {
            self.page = nil
        }
        return nil
    }
}

/// A mouse's wheel has no gesture for ScrollLatch to hold: each of its
/// lines was looked for from the window's frame down, through SwiftUI's hit
/// test of the window's host, which cost the main thread more than the
/// page's scroll did. A line that comes within 0.15 s of the last, with the
/// pointer where it was, goes to the view the last one went to. Kept by the
/// views that take a wheel's lines themselves: a page, the column's rows.
@MainActor
enum WheelLatch {
    private static weak var view: NSView?
    private static var place: NSPoint = .zero
    private static var last: TimeInterval = 0
    private static var monitor: Any?
    /// The view takes only lines up or down: the column's rows, whose
    /// sideways lines are the row of spaces' (SpaceWheel, #282).
    private static var upDownOnly = false

    /// `event`, a wheel's line, reached `view`.
    static func hold(_ view: NSView, _ event: NSEvent, upDownOnly: Bool = false) {
        guard event.phase == [], event.momentumPhase == [] else { return }
        self.view = view
        self.upDownOnly = upDownOnly
        place = event.locationInWindow
        last = event.timestamp
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { route(event) }
        }
    }

    /// Release only the disappearing column's receiver, not a page beside it.
    static func release(in root: NSView) {
        guard let view, view === root || view.isDescendant(of: root) else { return }
        self.view = nil
    }

    static func route(_ event: NSEvent) -> NSEvent? {
        guard let view else { return event }
        let at = event.locationInWindow
        guard event.phase == [], event.momentumPhase == [], view.window != nil, event.window === view.window,
              // A peek can hide its page without detaching it, and an
              // inactive column page stays in the window parked offscreen.
              // Let AppKit find the current target rather than renewing
              // the old view's latch for every notch.
              !view.isHiddenOrHasHiddenAncestor,
              view.visibleRect.intersection(view.bounds).contains(view.convert(at, from: nil)),
              event.timestamp - last < 0.15, event.timestamp >= last,
              abs(at.x - place.x) < 1, abs(at.y - place.y) < 1,
              // A sideways line over the column's rows goes on to the
              // column's catch, which the latch taking it hid it from: the
              // monitors' order changes, and when this one came first the
              // second notch of a push never reached it.
              !upDownOnly || SpaceWheel.across(SpaceWheel.Move(event)) == nil
        else {
            self.view = nil
            return event
        }
        last = event.timestamp
        view.scrollWheel(with: event)
        return nil
    }
}

/// A page's own tooltips, its title="", on the corner's glass as every tip
/// in yab is (KeyTip), under the pointer. After the rest the system's own
/// wait for, not a button's: a page of titled links (Wikipedia's) would
/// answer every pause of a reader's pointer.
@MainActor
final class PageTip {
    static let wait: TimeInterval = 1
    /// The longest a page's words are shown: a title can be a whole essay.
    static let longest = 500
    static let ask = NSSelectorFromString("view:stringForToolTip:point:userData:")
    /// WebKit answers what its tip says now; without it, the system's tips.
    static let can = WKWebView.instancesRespond(to: ask)

    private weak var page: PageView?
    /// What the tip says, as far as it knows.
    private var words = ""
    private var watch: Timer?

    init(page: PageView) { self.page = page }

    /// The page's tip as WebKit has it now, empty for none.
    private var now: String {
        guard let page, PageTip.can else { return "" }
        typealias Ask = @convention(c) (AnyObject, Selector, NSView, Int, NSPoint, UnsafeMutableRawPointer?) -> Unmanaged<NSString>?
        let ask = unsafeBitCast(class_getMethodImplementation(WKWebView.self, PageTip.ask), to: Ask.self)
        let said = ask(page, PageTip.ask, page, 0, .zero, nil)?.takeUnretainedValue() as String? ?? ""
        return said.count > PageTip.longest ? String(said.prefix(PageTip.longest)) + "\u{2026}" : said
    }

    /// WebKit has a new tip, or none: the old one goes, the new one comes
    /// after the wait. The end of one is said only to the system, so it is
    /// asked for again while there is one.
    func changed() {
        let said = now
        guard said != words else { return }
        if !words.isEmpty { KeyTip.shared.leave(self) }
        words = said
        guard !said.isEmpty else { return stop() }
        KeyTip.shared.hover(self, title: said, shortcut: nil, side: .pointer, wait: PageTip.wait)
        if watch == nil {
            watch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.changed()
                }
            }
        }
    }

    /// Off its window: no tip left over what comes next.
    func end() {
        if !words.isEmpty { KeyTip.shared.leave(self) }
        words = ""
        stop()
    }

    private func stop() {
        watch?.invalidate()
        watch = nil
    }
}

/// Carries the page's scroll position back to its tab.
///
/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself, otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, PageScriptReceiving {
    static let name = "yabScroll"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        // Where the page is and when it painted: the main frame's word only;
        // a frame's on a swipe is weighed below (RelayGuard).
        if body["side"] == nil, !message.frame.isMain { return }
        if body["drawn"] as? Bool == true {
            let origin = body["origin"] as? Double ?? 0
            let paint = body["paint"] as? Double
            MainActor.assumeIsolated { tab?.firstDrawn(origin: origin, paint: paint) }
            return
        }
        if body["shown"] as? Bool == true {
            MainActor.assumeIsolated { tab?.shownAgain() }
            return
        }
        if body["tone"] as? Bool == true {
            MainActor.assumeIsolated {
                guard let tab, tab.builtPage === message.sourceView,
                      let href = body["href"] as? String, href == tab.builtPage?.url?.absoluteString else { return }
                guard tab.lastY <= 1 || body["theme"] as? Bool == true else { return }
                tab.retone(fresh: true)
                tab.retoneAsItSettles()
            }
            return
        }
        if let side = body["side"] as? String {
            // A subframe cannot grant permission on behalf of the document.
            // With no main-frame reply its gesture simply stays on the page.
            guard message.frame.isMain, let gesture = body["gesture"] as? Int else { return }
            MainActor.assumeIsolated {
                if let page = tab?.builtPage as? ChromiumPage {
                    page.swipe.answer(free: side == "free", gesture: gesture, finished: body["finished"] as? Bool == true)
                } else {
                    tab?.webKitOnly("WebKit scroll acknowledgements", build: false)?.answer(free: side == "free", gesture: gesture, finished: body["finished"] as? Bool == true)
                }
            }
            return
        }
        guard let y = body["y"] as? Double,
              let ceiling = body["max"] as? Double
        else { return }
        MainActor.assumeIsolated { tab?.scrolled(to: y, of: ceiling) }
    }

    /// Reports at most ten times a second, and passively, so a page that
    /// scrolls smoothly without us keeps scrolling smoothly with us.
    static let script = """
    (function () {
      var waiting = false;
      function tell() {
        var root = document.documentElement;
        var y = window.scrollY || root.scrollTop || 0;
        var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
        window.webkit.messageHandlers.\(name).postMessage({ y: y, max: ceiling });
      }
      var told = 0;
      function soon() {
        if (waiting) return;
        waiting = true;
        // At most ten times a second, and the last place always told: on
        // every frame of a scroll it was a message to Yab and a pass of
        // its main thread a frame, the tab's reading pill easing over a
        // tenth of a second anyway.
        var wait = Math.max(0, 100 - (performance.now() - told));
        var frame = function () { requestAnimationFrame(function () { waiting = false; told = performance.now(); tell(); }); };
        if (wait > 0) setTimeout(frame, wait); else frame();
      }
      window.addEventListener('scroll', soon, { passive: true });
      // Scrolling isn't the only way the answer changes. A page brought back
      // from the back-forward cache, an address changed without a load, a
      // window resized or a page that grows as it loads all move it without
      // a single scroll, and the gray kept saying where the last page was.
      window.addEventListener('pageshow', soon);
      window.addEventListener('popstate', soon);
      window.addEventListener('resize', soon);
      if (window.ResizeObserver) new ResizeObserver(soon).observe(document.documentElement);
      window.__yabReading = soon;
      // Reading the height lays the page out, which a tab in the back is
      // otherwise spared until it is shown: its layout stays unbuilt, 25 MB
      // a tab in Chromium, and nobody is reading it yet.
      if (!document.hidden) { tell(); return; }
      document.addEventListener('visibilitychange', function shown() {
        if (document.hidden) return;
        document.removeEventListener('visibilitychange', shown);
        tell();
      });
    })();
    """

    /// The first contentful paint, once, from WebKit's own timing: the tab's
    /// ring goes then. At the document's start, since a page often paints
    /// long before its scripts are done and the end would hear it late;
    /// buffered, so one already past still counts.
    static let drawn = """
    (function () {
      window.addEventListener('pageshow', function (event) {
        if (event.persisted) window.webkit.messageHandlers.\(name).postMessage({ shown: true });
      });
      if (!window.PerformanceObserver) return;
      try {
        new PerformanceObserver(function (list, watch) {
          var paint = list.getEntriesByName('first-contentful-paint')[0];
          if (!paint) return;
          watch.disconnect();
          window.webkit.messageHandlers.\(name).postMessage({ drawn: true, origin: performance.timeOrigin, paint: paint.startTime });
        }).observe({ type: 'paint', buffered: true });
      } catch (e) {}
    })();
    """
}

extension WKWebView {
    /// An address, or a file on this Mac. WebKit reads a file only when told
    /// which folder the page may read from, so the stylesheets and pictures
    /// beside it come too; asked with a plain request, it shows nothing.
    /// Whether yab may read that folder is asked off the main thread first
    /// (FileReach).
    func open(_ url: URL) {
        SiteDownloads.open(self)
        if url.isFileURL {
            FileReach.open(url, in: self)
        } else {
            load(URLRequest(url: url))
        }
    }

    /// JavaScript run in yab's own world (see Web.world), where its page
    /// scripts are, answered the way `evaluateJavaScript` answers: the value,
    /// or nil for none or an error.
    func evaluateInYab(_ js: String, then: ((Any?) -> Void)? = nil) {
        evaluateJavaScript(js, in: nil, in: Web.world) { result in
            then?(try? result.get())
        }
    }
}

extension Tab: PageStateEvents {

    /// Values from a retired page, including delayed deliveries, never
    /// update the tab now holding its replacement.
    func page(_ page: any PageHandle, changed state: PageStateChange) {
        guard builtPage === page else { return }
        switch state {
        case .title(let value):
            retainingEngineTitle = false
            engineTitle = value
            // A Chromium document reset must also beat a queued retitle from
            // the old document. Ordinary title changes keep their throttle.
            if page.engine == .chromium, value?.isEmpty != false {
                title = ""
                return
            }
            held("title") { [weak self] in
                guard let self, self.builtPage === page else { return }
                self.retitle()
            }
        case .url(let value):
            if value != engineURL { toneGate.invalidate() }
            // Reset at receipt time, before the new document's title event.
            // A held URL write may run after that title has already arrived.
            if awaitingDocumentMetadata, let fresh = value, fresh.absoluteString != "about:blank",
               fresh != address, !Browser.sameDocument(fresh, address) {
                prepareDocumentMetadata(for: fresh)
            }
            engineURL = value
            held("url") { [weak self] in
                guard let self, self.builtPage === page, let fresh = self.engineURL else { return }
                guard !self.standingAtFailure || self.failure == nil else { return }
                // about:blank is never a destination. Putting a pinned tab
                // to sleep loads it deliberately to make WebKit give the
                // page back, and letting that overwrite the address is how
                // a pinned tab lost the only thing that could bring it
                // back, and vanished from the session altogether.
                guard fresh.absoluteString != "about:blank" else { return }
                let moved = fresh.host() != self.address?.host()
                self.address = fresh
                guard !LinkGap.cut("url.extra") else { return }
                Boosts.shared.moved(self)
                if moved {
                    self.tone = nil
                    self.icon = Tab.ownIcon(fresh) ?? Favicons.shared.pageIcon(fresh)
                    self.shade = fresh.host().flatMap { Tab.shades[$0] }
                    self.under = self.shade
                } else if Tab.ownIcon(fresh) == nil, let mine = Favicons.shared.pageIcon(fresh), mine !== self.icon {
                    // Another page of the site, which wore an icon of its
                    // own when last seen: that one until the page names
                    // its icons, as Chromium finds a page's in its history
                    // at commit (Docs to Slides on docs.google.com).
                    self.icon = mine
                }
                // pushState moves nothing the page's own script can hear.
                self.builtPage?.run("window.__yabReading && window.__yabReading()", in: .yab, gesture: false)
                if !self.loading { self.weighReadable(after: 1) }
                // A page that changes its address without loading another
                // redraws itself when it likes: YouTube still shows the
                // video's glow under its bar for a while after it says
                // it is home.
                self.retoneAsItSettles()
            }
        case .loading(let value):
            engineLoading = value
            if !value, let transfer = engineSwitchDocument, let destination = page.url,
               ["http", "https"].contains(destination.scheme?.lowercased() ?? "") {
                engineSwitchDocument = nil
                // A redirect also consumes the handoff. Going Back later
                // must never replay the source document's stale storage.
                transfer.removeScript(from: page)
            }
            held("loading") { [weak self] in
                guard let self, self.builtPage === page else { return }
                let now = self.engineLoading
                guard now != self.loading else { return }
                self.loading = now
                // A reload starts undrawn too (see navigationStarted);
                // a page kept from before (back and forward) says
                // nothing, and is done soon.
                if self.loading { if !LinkGap.cut("drawnflag") { self.drawn = false } } else { self.weighReadable(after: 0.5) }
            }
        case .back(let value):
            engineBack = value
            held("back") { [weak self] in
                guard let self, self.builtPage === page else { return }
                let now = self.engineBack
                if self.hasBackHistory != now { self.hasBackHistory = now }
            }
        case .forward(let value):
            engineForward = value
            held("forward") { [weak self] in
                guard let self, self.builtPage === page else { return }
                let now = self.engineForward
                if self.canGoForward != now { self.canGoForward = now }
            }
        case .theme(let value):
            pageTheme = value
            held("tone") { [weak self] in
                guard let self, self.builtPage === page else { return }
                self.retone()
            }
        case .underPage(let value):
            pageUnderColor = value
            held("tone") { [weak self] in
                guard let self, self.builtPage === page else { return }
                self.retone()
            }
        case .camera(let value): camera = value
        case .microphone(let value): microphone = value
        case .screen(let value): screen = value
        case .fullscreen(let value):
            guard immersed != value else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { immersed = value }
        }
    }
}

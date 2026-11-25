import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct TabEngineTests {
    /// An NSView with no WebKit inheritance proves ownership and state
    /// delivery do not depend on the compatibility accessors.
    fileprivate final class Page: NSView, PageHandle, PageAudioControl, PageSleepActivity, PageFramePace {
        let engine: PageEngineKind
        var restsFrames = false
        weak var events: (any PageEvents)?
        weak var stateEvents: (any PageStateEvents)?
        var url: URL?
        var committedURL: URL? { historyEntry?.url }
        var historyEntry: PageHistoryEntry?
        var title: String?
        var isLoading = false
        var estimatedProgress = 0.0
        var canGoBack = false
        var canGoForward = false
        var pageZoom: CGFloat = 1
        var magnification: CGFloat = 1
        var themeColor: NSColor?
        var lastInput: TimeInterval?
        var pid: pid_t?
        var contentProcess: pid_t? { pid }
        var gpuProcess: pid_t? { nil }
        var captureStatus = PageCaptureStatus(camera: .none, microphone: .none, screen: .none)
        var sleepActivityUnavailable = true
        var requests: [URLRequest] = []
        var retired = false
        var onRetire: (() -> Void)?
        var reloads = 0
        var backs = 0
        var forwards = 0
        var mutes: [Bool] = []
        var kills = 0
        var shots: [PageShot] = []
        var picture: NSImage?
        var scriptResult: Any?
        var lastScriptFrame: PageFrame?
        var scriptReply: ((@escaping @MainActor (Result<Any?, Error>) -> Void) -> Void)?
        var presses: [NSEvent] = []
        var inserted: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { presses.append(event) }
        override func mouseUp(with event: NSEvent) { presses.append(event) }

        init(_ kind: PageEngineKind) { engine = kind; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func emit(_ state: PageStateChange) { stateEvents?.page(self, changed: state) }
        func navigate(to request: URLRequest) { requests.append(request) }
        func navigate(html: String, base: URL?) { }
        func reload(fromOrigin: Bool) { reloads += 1 }
        func stopLoading() { }
        func navigateBack() { backs += 1 }
        func navigateForward() { forwards += 1 }
        func retire(call: Bool, pictureInPicture: Bool) {
            retired = true
            let closing = onRetire
            onRetire = nil
            closing?()
            stateEvents = nil
            events = nil
            removeFromSuperview()
        }
        func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) { done([]) }
        func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) { shots.append(shot); done(picture, nil) }
        func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) { done(.failure(PageShotFailed())) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) {
            lastScriptFrame = frame
            if let done, let scriptReply { scriptReply(done) }
            else { done?(.success(scriptResult)) }
        }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? { nil }
        func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool { false }
        func agentHover(x: Double, y: Double) -> Bool { false }
        func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func insertAgentText(_ text: String) { inserted.append(text) }
        func sendAgentKeys(_ strokes: [PageKey]) { }
        func setCameraCapture(_ state: PageMediaState) { }
        func setMicrophoneCapture(_ state: PageMediaState) { }
        func stopDisplayCapture() { }
        func killContent() { kills += 1 }
        func setAudioMuted(_ muted: Bool) { mutes.append(muted) }
    }

    @MainActor
    fileprivate final class Factory {
        var choices: [PageEngineKind] = []
        var pages: [Page] = []
        let sites = SiteEngineSettings(store: UserDefaults(suiteName: "site-engine-tests-" + UUID().uuidString)!)
        var factory: PageEngineFactory {
            PageEngineFactory(kinds: [.webKit, .chromium], sites: sites) { [self] _, kind in
                choices.append(kind)
                let page = Page(kind)
                pages.append(page)
                return page
            }
        }
    }

    fileprivate func make(_ factory: Factory, engine: PageEngineKind = .webKit) -> Tab {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return Tab(configuration: config, engine: engine, factory: factory.factory)
    }

    @Test func injectedFactoryKeepsTheExplicitEngine() {
        let factory = Factory(), tab = make(factory, engine: .webKit)
        defer { tab.close() }
        #expect(tab.engineKind == .webKit && factory.choices.isEmpty)
        #expect(tab.page.engine == .webKit && factory.choices == [.webKit])
    }

    @Test(arguments: [PageEngineKind.webKit, .chromium])
    func explicitFactoryKeepsItsRequestedEngineAndBridgePolicy(engine: PageEngineKind) {
        let factory = Factory(), tab = make(factory, engine: engine)
        defer { tab.close() }
        // The parity runner forces the standard factory to Chromium. An
        // injected factory must remain independent of that ambient choice.
        #expect(tab.engineKind == engine && tab.builtPage == nil && factory.choices.isEmpty)
        #expect(tab.chromiumDRMEnabled == (engine == .chromium))
        #expect(tab.page.engine == engine && factory.choices == [engine])
        #expect(tab.built == nil, "The injected NSView must not acquire a shadow WebKit view")
    }

    /// A page built and put to sleep, as memory stood at `level`.
    private func wake(_ tab: Tab, level: Int?) -> PageEngineKind {
        Pressure.forced = level
        defer { Pressure.forced = nil }
        let engine = tab.page.engine
        tab.unbuildForEngineTest()
        return engine
    }

    @Test func webKitFirstMovesAWakingTabAndRemembersWhy() {
        let factory = Factory()
        factory.sites.store.set(EngineDefault.webKitFirst.rawValue, forKey: EngineRules.defaultKey)
        let tab = make(factory, engine: .webKit)
        defer { tab.close() }
        tab.go(to: URL(string: "https://plain.test/")!)
        tab.unbuildForEngineTest()
        #expect(wake(tab, level: 2) == .chromium)
        #expect(tab.engineMemoryMoved && !tab.chromiumDRMEnabled)
        // Still short: it stays.
        #expect(wake(tab, level: 4) == .chromium)
        // Memory back: home to WebKit, and nothing left to remember.
        #expect(wake(tab, level: 1) == .webKit)
        #expect(!tab.engineMemoryMoved)
    }

    @Test func aTabGoingSomewhereUnderPressureNavigatesOnTheEngineItGets() {
        // On the engine told beforehand a WebKit path would load nothing.
        let factory = Factory()
        factory.sites.store.set(EngineDefault.webKitFirst.rawValue, forKey: EngineRules.defaultKey)
        let tab = make(factory, engine: .webKit)
        defer { tab.close() }
        Pressure.forced = 2
        defer { Pressure.forced = nil }
        let url = URL(string: "https://plain.test/")!
        #expect(factory.factory.upcoming(tab, at: url) == .chromium)
        tab.go(to: url)
        #expect(tab.builtPage?.engine == .chromium)
        #expect((tab.builtPage as? Page)?.requests.last?.url == url)
    }

    @Test func webKitFirstLeavesARuledSiteAlone() {
        let factory = Factory()
        factory.sites.store.set(EngineDefault.webKitFirst.rawValue, forKey: EngineRules.defaultKey)
        let tab = make(factory, engine: .webKit)
        defer { tab.close() }
        tab.go(to: URL(string: "https://open.spotify.com/")!)
        tab.unbuildForEngineTest()
        #expect(wake(tab, level: 2) == .webKit)
        #expect(!tab.engineMemoryMoved)
    }

    @Test func autoKeepsChromiumWhenAWakingTabIsUnderPressure() {
        let factory = Factory()
        let tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.go(to: URL(string: "https://plain.test/")!)
        tab.unbuildForEngineTest()
        // Auto stays on Chromium under pressure (owner, 2026-11-02).
        // WebKit First's separate wake/move coverage above remains intact.
        #expect(wake(tab, level: 2) == .chromium)
        #expect(!tab.engineMemoryMoved)
        #expect(wake(tab, level: 1) == .chromium)
        #expect(!tab.engineMemoryMoved)
    }

    @Test func aDefaultChosenAfterAMemoryMoveWinsAtTheNextWake() {
        let factory = Factory()
        factory.sites.store.set(EngineDefault.webKitFirst.rawValue, forKey: EngineRules.defaultKey)
        let tab = make(factory, engine: .webKit)
        defer { tab.close() }
        tab.go(to: URL(string: "https://plain.test/")!)
        tab.unbuildForEngineTest()
        Pressure.forced = 2
        defer { Pressure.forced = nil }
        #expect(tab.page.engine == .chromium)
        // Plain WebKit picked while the page is up: it stays, and is told.
        factory.sites.store.set(EngineDefault.auto.rawValue, forKey: EngineRules.defaultKey)
        tab.followDefaultEngine(.webKit)
        #expect(tab.page.engine == .chromium && tab.enginePendingDefault == .webKit)
        tab.unbuildForEngineTest()
        #expect(tab.page.engine == .webKit)
        #expect(!tab.engineMemoryMoved && tab.enginePendingDefault == nil)
    }

    @Test func standardFactoryStillFollowsTheDevelopmentEngineOverride() {
        let tab = Tab(shy: true)
        defer { tab.close() }
        let expected = PageEngineFactory.requestedEngine ?? .webKit
        #expect(tab.engineKind == expected && tab.builtPage == nil)
        #expect(tab.chromiumDRMEnabled == (expected == .chromium))
    }

    @Test func explicitEngineWinsOverTheGlobalDefaultWithoutBuildingAPage() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: PageEngineSelection.key)
        defaults.set("webKit", forKey: PageEngineSelection.key)
        defer {
            if let old { defaults.set(old, forKey: PageEngineSelection.key) }
            else { defaults.removeObject(forKey: PageEngineSelection.key) }
        }
        let adopted = Tab(shy: true, engine: .chromium)
        defer { adopted.close() }
        #expect(adopted.engineKind == PageEngineFactory.standard.resolved(.chromium))
        #expect(adopted.builtPage == nil)
        let webKit = Tab(shy: true, engine: .webKit)
        defer { webKit.close() }
        #expect(webKit.engineKind == .webKit && webKit.builtPage == nil)
    }

    @Test func remoteUnloadNeverHoldsClosing() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        _ = tab.page
        var allowed: Bool?
        Leaving.each([tab]) { allowed = $0 }
        #expect(allowed == true && !tab.gone && factory.pages.count == 1)
        let untouched = Factory(), blank = make(untouched, engine: .chromium)
        defer { blank.close() }
        Leaving.each([blank]) { allowed = $0 }
        #expect(allowed == true && untouched.pages.isEmpty)
    }

    @Test func unknownRemoteActivityCannotAuthorizeAutomaticAgentCleanup() {
        let factory = Factory(), tab = Tab(bench: true, engine: .chromium, factory: factory.factory)
        let browser = Browser(windowID: UUID())
        let session = Agents.Session(id: UUID().uuidString, cli: "codex", name: "Cleanup", prompt: "", state: .done)
        session.ended = Date()
        tab.agent = session.id
        tab.restore(url: URL(string: "https://example.invalid/cleanup")!, title: "Result")
        browser.lay([tab])
        browser.activeID = nil
        _ = tab.page
        var now: TimeInterval = 100, inspections = 0
        let cleanup = AgentTabCleanup(browsers: { [browser] }, session: { $0 == session.id ? session : nil },
            clock: { now }, choice: { .fifteenMinutes }, inspect: { _, answer in inspections += 1; answer(false) }, automatic: false)
        defer { tab.close(); browser.lay([]) }
        cleanup.schedule(session)
        now += 901
        cleanup.sweep()
        #expect(browser.tabs.contains { $0 === tab } && !tab.gone)
        #expect(inspections == 0 && factory.pages.count == 1)
    }

    @Test func aLateNativeConsumerCannotBuildAClosedTabAgain() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        tab.close()
        #expect(tab.webKitOnly("Late native callback") == nil)
        #expect(tab.gone && tab.builtPage == nil && factory.pages.isEmpty)
    }

    @Test func benchHouseAttachesTheOwnedChromiumView() {
        let factory = Factory()
        let tab = Tab(bench: true, engine: .chromium, factory: factory.factory)
        defer { Bench.shared.rest(tab); tab.close() }
        Bench.shared.house(tab)
        let page = tab.page as! Page
        #expect(page.window?.identifier == Bench.roomID)
        #expect(page.frame.width > 0 && page.frame.height > 0)
        #expect(tab.built == nil && factory.pages.count == 1)
        Bench.shared.house(tab)
        #expect(tab.builtPage === page && factory.pages.count == 1)
        Bench.shared.rest(tab)
        #expect(page.window == nil && tab.builtPage === page)
        Bench.shared.house(tab)
        #expect(page.window?.identifier == Bench.roomID && factory.pages.count == 1)
    }

    @Test func anAgentPageInTheRoomDrawsSlowlyOnlyBetweenItsCalls() throws {
        try #require(Bench.shared.callsInFlight == 0, "a bench call of another test is still waiting for its answer")
        let factory = Factory()
        let tab = Tab(bench: true, engine: .chromium, factory: factory.factory)
        defer { Bench.shared.rest(tab); tab.close() }
        let first = Bench.shared.answerOnce(within: 600) { _ in }
        first.names(tab)
        Bench.shared.house(tab)
        let page = tab.page as! Page
        #expect(page.window?.identifier == Bench.roomID && !page.restsFrames)
        first.answer([:])
        #expect(page.restsFrames, "no call is in flight for it")
        let next = Bench.shared.answerOnce(within: 600) { _ in }
        next.names(tab)
        #expect(!page.restsFrames, "a call that names it wakes it before it is housed")
        Bench.shared.house(tab)
        next.answer([:])
        #expect(page.restsFrames)
        Bench.shared.rest(tab)
        #expect(page.window == nil && !page.restsFrames)
    }

    @Test func aPageAnAgentOpenedDrawsFullyUntilNoCallIsInFlight() throws {
        try #require(Bench.shared.callsInFlight == 0, "a bench call of another test is still waiting for its answer")
        let factory = Factory()
        let tab = Tab(bench: true, engine: .chromium, factory: factory.factory)
        defer { Bench.shared.rest(tab); tab.close() }
        let open = Bench.shared.answerOnce(within: 600) { _ in }
        Bench.shared.house(tab)
        let page = tab.page as! Page
        #expect(!page.restsFrames)
        open.answer([:])
        #expect(page.restsFrames)
    }

    @Test func aNameThatComesAfterItsCallsAnswerWakesNothing() throws {
        try #require(Bench.shared.callsInFlight == 0, "a bench call of another test is still waiting for its answer")
        let factory = Factory()
        let tab = Tab(bench: true, engine: .chromium, factory: factory.factory)
        defer { Bench.shared.rest(tab); tab.close() }
        Bench.shared.house(tab)
        let page = tab.page as! Page
        #expect(page.restsFrames)
        let late = Bench.shared.answerOnce(within: 600) { _ in }
        late.answer([:])
        late.names(tab)
        #expect(page.restsFrames)
    }

    @Test func sleepSafetyKeepsUnknownChromiumActivityAwake() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        let browser = Browser(windowID: UUID())
        defer { tab.close() }
        tab.go(to: URL(string: "https://example.invalid/")!)
        let page = tab.page as! Page
        #expect(browser.awake(because: tab) == "page activity unavailable")
        page.captureStatus = PageCaptureStatus(camera: .active, microphone: .none, screen: .none)
        #expect(browser.awake(because: tab) == "on a call")
        page.captureStatus = PageCaptureStatus(camera: .none, microphone: .none, screen: .muted)
        #expect(browser.awake(because: tab) == "on a call")
        #expect(tab.built == nil)
    }

    @Test func aNativeHangCannotAutomaticallyReloadAnAgentWithUnknownActivity() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        let browser = Browser(windowID: UUID())
        let previous = Store.settings.object(forKey: "stuck.deafAgent")
        defer {
            if let previous { Store.settings.set(previous, forKey: "stuck.deafAgent") }
            else { Store.settings.removeObject(forKey: "stuck.deafAgent") }
            tab.close()
        }
        Store.settings.set(0.05, forKey: "stuck.deafAgent")
        tab.go(to: URL(string: "ownership:/hung-agent")!)
        tab.agent = "native-health-fixture"
        let page = try #require(tab.builtPage as? Page)
        page.pid = getpid()
        try #require(tab.worker != nil)
        browser.heardDeaf(tab, by: "native CEF fixture")
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.kills == 0 && tab.deaf != nil)
        #expect(tab.builtPage === page && !tab.asleep)
        // The person's explicit Reload still owns the decision.
        browser.endDeaf(tab)
        #expect(page.kills == 1 && tab.deaf == nil)
    }

    @Test func lateScrollReplyCannotChangeANewNavigation() throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.go(to: URL(string: "ownership:/before")!)
        let page = try #require(tab.builtPage as? Page)
        var reply: (@MainActor (Result<Any?, Error>) -> Void)?, completions = 0
        page.scriptReply = { reply = $0 }
        tab.readChromiumPlace { completions += 1 }
        let answer = try #require(reply)
        tab.go(to: URL(string: "ownership:/after")!)
        answer(.success(700.0))
        #expect(tab.lastY == 0 && completions == 1)
        #expect(tab.builtPage === page, "same view, different navigation")
    }

    @Test func scrollReplyAfterDeadlineCannotOverwriteTheWakePosition() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.go(to: URL(string: "ownership:/slow-scroll")!)
        let page = try #require(tab.builtPage as? Page)
        var reply: (@MainActor (Result<Any?, Error>) -> Void)?, completions = 0
        page.scriptReply = { reply = $0 }
        tab.scrolled(to: 42, of: 1000)
        tab.readChromiumPlace { completions += 1 }
        let answer = try #require(reply)
        for _ in 0..<100 where completions == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(completions == 1)
        answer(.success(700.0))
        #expect(tab.lastY == 42 && completions == 1)
    }

    @Test func currentScrollReplyIsUsedOnceAndRejectsInvalidPositions() throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.go(to: URL(string: "ownership:/scroll")!)
        let page = try #require(tab.builtPage as? Page)
        for value in [700.0, -1, .infinity, .nan] {
            var reply: (@MainActor (Result<Any?, Error>) -> Void)?, completions = 0
            page.scriptReply = { reply = $0 }
            tab.scrolled(to: 42, of: 1000)
            tab.readChromiumPlace { completions += 1 }
            let answer = try #require(reply)
            answer(.success(value))
            #expect(tab.lastY == (value == 700 ? 700 : 42) && completions == 1)
            answer(.success(900.0))
            #expect(tab.lastY != 900 && completions == 1)
        }
    }

    @Test func oldDraftReplyCannotPutANewDocumentToSleep() throws {
        _ = NSApplication.shared
        let page = Page(.chromium)
        // This explicit unit adapter models known activity. Browser waivers
        // still cannot bypass unknown activity on a real Chromium page.
        page.sleepActivityUnavailable = false
        page.lastInput = 1 // A page nobody touched isn't asked about drafts.
        let factory = PageEngineFactory(kinds: [.chromium]) { _, _ in page }
        let tab = Tab(shy: true, engine: .chromium, factory: factory), browser = Browser(windowID: UUID())
        defer { tab.close() }
        tab.go(to: URL(string: "ownership:/before")!)
        var reply: (@MainActor (Result<Any?, Error>) -> Void)?, reason: String?
        page.scriptReply = { reply = $0 }
        browser.sleep(tab, urgent: true) { reason = $0 }
        let answer = try #require(reply)
        tab.go(to: URL(string: "ownership:/after")!)
        answer(.success(false))
        #expect(reason == "page changed")
        #expect(tab.builtPage === page && !tab.asleep && !page.retired)
    }

    @Test func returningDuringDraftProbeCancelsAutomaticSleep() throws {
        let factory = Factory(), browser = Browser(windowID: UUID())
        let tab = Tab(shy: true, engine: .chromium, factory: factory.factory)
        let front = Tab(shy: true, engine: .chromium, factory: factory.factory)
        defer { for page in browser.tabs { page.close() } }
        tab.go(to: URL(string: "ownership:/sleep-candidate")!)
        front.go(to: URL(string: "ownership:/foreground")!)
        browser.lay([tab, front]); browser.activeID = front.id
        let page = try #require(tab.builtPage as? Page)
        page.sleepActivityUnavailable = false
        page.lastInput = 1
        tab.touch(at: Date().addingTimeInterval(-Browser.seenGrace - 60))
        browser.recent = []
        #expect(browser.relief(now: AwakeClock.now) === tab)

        var reply: (@MainActor (Result<Any?, Error>) -> Void)?, reason: String?
        page.scriptReply = { reply = $0 }
        browser.sleep(tab, urgent: true, reason: .memoryCritical) { reason = $0 }
        let answer = try #require(reply, "the actual draft probe is pending")
        #expect(reason == nil && !tab.asleep)
        browser.activeID = tab.id
        browser.activeID = front.id
        #expect(tab.idle(at: AwakeClock.now) < Browser.seenGrace)
        #expect(browser.recentlyUsed().contains(tab.id))
        answer(.success(false))

        #expect(reason != nil, "the invalidated sleep request reports completion")
        #expect(reason != "asleep", "returning to a tab invalidates the old sleep decision")
        #expect(tab.builtPage === page && !tab.asleep && !page.retired,
                "the document just visited must survive the late draft reply")
    }

    @Test func unknownChromiumActivityCannotBeWaivedBeforeADraftProbe() {
        _ = NSApplication.shared
        let page = Page(.chromium)
        let factory = PageEngineFactory(kinds: [.chromium]) { _, _ in page }
        let tab = Tab(shy: true, engine: .chromium, factory: factory), browser = Browser(windowID: UUID())
        defer { tab.close() }
        tab.go(to: URL(string: "ownership:/unknown-activity")!)
        var probes = 0, reason: String?
        page.scriptReply = { _ in probes += 1 }
        browser.sleep(tab, waiving: ["page activity unavailable"], urgent: true) { reason = $0 }
        #expect(reason == "page activity unavailable" && probes == 0)
        #expect(tab.builtPage === page && !tab.asleep && !page.retired)
    }

    @Test func unsupportedNativeFeaturesDoNotConstructAnotherEngine() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        #expect(tab.webKitOnly("Test native feature", build: false) == nil)
        #expect(factory.pages.isEmpty)
        let page = tab.page
        #expect(tab.webKitOnly("Test native feature") == nil)
        #expect(tab.builtPage === page && factory.pages.count == 1)
    }

    @Test func readerAndZoomUseTheOwnedEngine() {
        let factory = Factory()
        let tab = Tab(shy: true, engine: .chromium, factory: factory.factory)
        defer { tab.close() }
        tab.go(to: URL(string: "https://example.invalid/reader")!)
        let page = tab.page as! Page
        tab.magnify(to: 1.5)
        #expect(page.pageZoom == 1.5 && tab.zoom == 1.5)
        page.scriptResult = "read"
        tab.toggleReader { #expect($0) }
        #expect(tab.reader)
        page.scriptResult = "left"
        tab.toggleReader { #expect($0) }
        #expect(!tab.reader && page.reloads == 0)
        #expect(tab.built == nil && factory.pages.count == 1)
    }

    @Test func spaceMovesCompareTheRemoteProfileRatherThanAShadowWebKitStore() {
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(engine: .chromium, factory: factory)
        let privateTab = Tab(shy: true, engine: .chromium, factory: factory)
        tab.delegate = browser
        privateTab.delegate = browser
        defer { tab.close(); privateTab.close() }
        #expect(!browser.signsInAgain(tab, in: browser.spaceID))
        #expect(browser.signsInAgain(tab, in: UUID()))
        #expect(!browser.signsInAgain(privateTab, in: UUID()))
        #expect(privateTab.builtPage == nil)
        #expect((tab.builtPage as? ChromiumPage)?.remoteID == nil)
    }

    @Test func nativeWebKitConstructionRefusesTheRemoteEngineChoice() {
        let tab = Tab(shy: true, engine: .chromium, factory: .webKitOnly)
        defer { tab.close() }
        #expect(tab.engineKind == .webKit && tab.builtPage == nil)
    }

    @Test func neutralHandoffWaitsForTheReceivingStage() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! Page
        page.picture = NSImage(size: NSSize(width: 4, height: 4))
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil); page.removeFromSuperview() }
        var finished: Bool?
        var attached: StageView?
        StageView.afterHandoff(page, owner: tab.id, window: { window }, cancelled: { false },
                               attached: { attached = $0 }, done: { finished = $0 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(finished == nil && page.shots.isEmpty)
        let stage = StageView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView?.addSubview(stage)
        stage.show(page, of: tab.id)
        for _ in 0..<80 where finished == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(finished == true && attached === stage)
        #expect(page.shots.count == 1 && page.shots.first?.afterUpdates == true)
        #expect(page.shots.first?.width == 1)
        #expect(tab.builtPage === page && tab.built == nil)
    }

    @Test func benchPersonInputUsesTheOwnedNativeView() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! Page
        page.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(!PageBenchInput.click(page, x: 50, y: 60))
        #expect(!PageBenchInput.type("offscreen", into: page))
        let window = NSWindow(contentRect: page.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil); page.removeFromSuperview() }
        window.contentView?.addSubview(page)
        page.pageZoom = 1.5
        #expect(PageBenchInput.click(page, x: 50, y: 60))
        #expect(page.presses.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(page.presses.allSatisfy { $0.locationInWindow == CGPoint(x: 75, y: 310) })
        #expect(PageBenchInput.type("Native Привет", into: page))
        #expect(page.inserted == ["Native Привет"])
        #expect(!PageBenchInput.click(page, x: .nan, y: 0))
        #expect(page.presses.count == 2)
        #expect(tab.built == nil)
    }

    @Test func chromiumMuteDoesNotBuildASleepingPage() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.mute(true)
        #expect(tab.muted && factory.choices.isEmpty)
        let page = tab.page as! Page
        tab.mute(false)
        #expect(!tab.muted && page.mutes == [false] && tab.built == nil)
    }

    @Test func chromiumThumbnailsUseTheOwnedPageAndDoNotWakeIt() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.glance(width: 160) { #expect($0 == nil) }
        #expect(factory.choices.isEmpty)
        let page = tab.page as! Page
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        page.picture = NSImage(size: NSSize(width: 160, height: 120))
        tab.glance(width: 160) { #expect($0 === page.picture) }
        #expect(page.shots.count == 1 && page.shots[0].width == 160 && !page.shots[0].afterUpdates)
        #expect(tab.built == nil)
    }

    @Test func chromiumUnsavedProbeUsesTheOwnedPage() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! Page
        page.scriptResult = true
        tab.unsaved { #expect($0) }
        #expect(tab.built == nil)
    }

    @Test(arguments: [PageEngineKind.webKit, .chromium])
    func memoryReplacementKeepsTheOwnedEngineAndFactory(engine: PageEngineKind) throws {
        let factory = Factory(), tab = make(factory, engine: engine)
        let browser = Browser(windowID: UUID())
        browser.lay([tab]); browser.activeID = tab.id
        let url = URL(string: "https://memory-replacement.test/current")!
        tab.go(to: url)
        let old = try #require(tab.builtPage as? Page)
        defer { tab.close(); for tab in browser.tabs { tab.close() } }
        browser.replaceBlank(tab, with: url)
        let current = try #require(browser.tabs.first { $0.id == tab.id })
        #expect(current !== tab && current.engineKind == engine)
        let page = try #require(current.builtPage as? Page)
        #expect(page !== old)
        #expect(old.retired == (engine == .chromium))
        #expect(tab.gone == (engine == .chromium))
        #expect(factory.choices == [engine, engine])
        #expect(current.address == url)
    }

    @Test func chromiumCrashRecoveryDoesNotConstructWebKit() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let url = URL(string: "ownership:/crash")!
        tab.restore(url: url, title: "Saved")
        _ = tab.wake()
        let page = tab.page as! Page
        tab.failure = "Renderer crashed"
        tab.recoverFromCrash()
        #expect(tab.failure == nil && page.requests.map(\.url) == [url, url])
        #expect(factory.choices == [.chromium] && tab.built == nil)
    }

    @Test func restoredChoiceBuildsOnlyWhenAskedAndOnlyOnce() throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.restore(url: URL(string: "ownership:/first")!, title: "Saved title")
        #expect(tab.builtPage == nil && tab.built == nil && factory.choices.isEmpty)
        #expect(tab.engineKind == .chromium && tab.title == "Saved title")
        let page = tab.page
        #expect(tab.page === page && tab.builtPage === page)
        #expect(tab.built == nil, "There is no hidden WebKit page")
        #expect(factory.choices == [.chromium])
        #expect(page.stateEvents === tab)
        #expect(tab.wake())
        #expect(factory.pages[0].requests.map(\.url) == [tab.address])
        #expect(!tab.wake() && factory.choices.count == 1)
    }

    @Test func anOpenedFolderTabWithNoWebKitViewStaysVisibleAfterLeavingIt() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let folder = Nest(name: "资讯", open: false)
        tab.kept = true
        tab.nest = folder
        tab.restore(url: URL(string: "ownership:/folder-1451")!, title: "Saved folder tab")
        let outside = UUID()
        func visible() -> Bool? {
            Folders.lay(Folders.nests(in: [tab]), isOpen: { $0.nest?.open ?? false },
                        whole: [], folding: [], active: outside,
                        awake: Folders.awake(in: [tab])).places[tab.id]?.shown
        }
        #expect(Folders.awake(in: [tab]).isEmpty && visible() == false)

        // A non-WebKit engine owns an open page while the compatibility
        // accessor remains nil. Folder visibility must use the shared handle.
        #expect(tab.wake())
        #expect(tab.builtPage != nil && tab.built == nil && !tab.asleep && !tab.unopened)
        #expect(Folders.awake(in: [tab]) == [tab.id])
        #expect(visible() == true)
        tab.rest()
        #expect(tab.unopened && Folders.awake(in: [tab]).isEmpty)
        #expect(visible() == false)
    }

    @Test func replacementKeepsTabEntryAndViewPositionAndRejectsOldEvents() throws {
        let factory = Factory(), tab = make(factory)
        let url = URL(string: "ownership:/first")!
        tab.restore(url: url, title: "Saved title")
        let old = tab.page as! Page
        old.historyEntry = PageHistoryEntry(url: url, title: "Saved title")
        let entry = tab.currentEntry
        let id = tab.id
        let rows = [Tab(), tab, Tab()]
        defer { rows.forEach { $0.close() } }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let before = NSView(), after = NSView()
        old.frame = NSRect(x: 12, y: 16, width: 700, height: 500)
        let frame = old.frame
        host.addSubview(before); host.addSubview(old); host.addSubview(after)
        let stale = old.stateEvents
        #expect(tab.replaceEngine(with: .chromium, at: URLRequest(url: url)))
        let made = try #require(tab.builtPage as? Page)
        #expect(tab.id == id && rows[1] === tab && rows.map(\.id)[1] == id)
        #expect(tab.title == "Saved title" && tab.address == url && tab.currentEntry == entry)
        #expect(tab.engineKind == .chromium && factory.choices == [.webKit, .chromium])
        #expect(made !== old && old.retired && old.stateEvents == nil && old.events == nil)
        #expect(host.subviews.count == 3 && host.subviews[0] === before && host.subviews[1] === made && host.subviews[2] === after)
        #expect(made.frame == frame && made.requests.map(\.url) == [url])
        stale?.page(old, changed: .title("Stale"))
        stale?.page(old, changed: .url(URL(string: "ownership:/stale")))
        stale?.page(old, changed: .camera(.active))
        #expect(tab.title == "Saved title" && tab.address == url && tab.camera == .none)
        #expect(!tab.replaceEngine(with: .chromium, at: URLRequest(url: url)))
        #expect(factory.choices.count == 2)
        tab.close()
        #expect(made.retired && tab.builtPage == nil)
        #expect(!tab.replaceEngine(with: .webKit, at: URLRequest(url: url)))
    }

    @Test func repeatingTheCurrentEngineChoiceKeepsThePendingHandoffUntilFinish() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://switch-pending.test/document")!
        tab.restore(url: url, title: "Pending")
        let page = tab.page as! Page
        page.url = url
        let transfer = try EngineSwitchDocument(url: url,
            json: "{\"url\":\"https://switch-pending.test/document\",\"local\":[],\"session\":[],\"fields\":[],\"x\":0,\"y\":0}")
        tab.engineSwitchDocument = transfer
        try await tab.setSiteEngineChoice(.webKit)
        #expect(tab.engineSwitchDocument === transfer)
        page.emit(.loading(false))
        #expect(tab.engineSwitchDocument == nil)
    }

    @Test func aRedirectConsumesTheSwitchSnapshotButTheInitialBlankDocumentDoesNot() throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://switch.test/document")!
        tab.restore(url: url, title: "Source")
        let page = tab.page as! Page
        tab.engineSwitchDocument = try EngineSwitchDocument(url: url,
            json: "{\"url\":\"https://switch.test/document\",\"local\":[],\"session\":[],\"fields\":[],\"x\":0,\"y\":0}")
        page.url = URL(string: "about:blank")
        page.emit(.loading(false))
        #expect(tab.engineSwitchDocument != nil)
        page.url = URL(string: "https://redirect.test/landing")
        page.emit(.loading(false))
        #expect(tab.engineSwitchDocument == nil)
    }

    @Test func chromiumConstructionReadsTheExistingSiteZoom() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        let host = "switch-" + UUID().uuidString.lowercased() + ".test"
        let key = "zoom." + host
        Store.settings.set(1.6, forKey: key)
        defer { tab.close(); Store.settings.removeObject(forKey: key) }
        tab.restore(url: URL(string: "https://\(host)/page")!, title: "Zoom")
        #expect(tab.page.pageZoom == 1.6 && tab.zoom == 1.6)
    }

    @Test func sameDocumentEngineReplacementPreservesUnpersistedZoomBothWays() throws {
        let factory = Factory(), tab = make(factory)
        let url = URL(string: "https://zoom-switch.test/document")!
        tab.restore(url: url, title: "Zoom")
        defer { tab.close() }
        let first = tab.page as! Page
        first.url = url; first.pageZoom = 1.35
        #expect(tab.replaceEngine(with: .chromium, at: URLRequest(url: url)))
        let second = try #require(tab.builtPage as? Page)
        #expect(second.pageZoom == 1.35 && tab.zoom == 1.35)
        second.url = url; second.pageZoom = 1.7
        #expect(tab.replaceEngine(with: .webKit, at: URLRequest(url: url)))
        #expect(tab.page.pageZoom == 1.7 && tab.zoom == 1.7)
    }

    @Test func anUnresponsiveSnapshotTimesOutAndIgnoresItsLateReply() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://snapshot-timeout.test/page")!
        tab.restore(url: url, title: "Slow")
        let page = tab.page as! Page
        page.url = url
        var reply: (@MainActor (Result<Any?, Error>) -> Void)?
        page.scriptReply = { reply = $0 }
        #expect(try await EngineSwitchDocument.capture(from: page, at: url, within: 0.02) == nil)
        #expect(tab.builtPage === page && !page.retired)
        reply?(.success("late"))
    }

    @Test func stateEventsDriveTheTabWithoutReadingThePagesProperties() throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! Page
        let url = URL(string: "ownership:/state")!
        let color = PageColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        page.emit(.url(url)); page.emit(.title("Engine title")); page.emit(.loading(true))
        page.emit(.back(true)); page.emit(.forward(true))
        page.emit(.theme(color)); page.emit(.underPage(color))
        page.emit(.camera(.active)); page.emit(.microphone(.muted)); page.emit(.screen(.active)); page.emit(.fullscreen(true))
        #expect(page.url == nil && page.title == nil && !page.isLoading && !page.canGoBack)
        #expect(tab.address == url && tab.title == "Engine title" && tab.loading)
        #expect(tab.hasBackHistory && tab.canGoForward)
        #expect(tab.pageTheme == color && tab.pageUnderColor == color)
        #expect(tab.camera == .active && tab.microphone == .muted && tab.screen == .active && tab.immersed)
        page.emit(.url(URL(string: "about:blank")))
        #expect(tab.address == url)
        page.emit(.loading(false)); page.emit(.back(false)); page.emit(.forward(false)); page.emit(.fullscreen(false))
        #expect(!tab.loading && !tab.hasBackHistory && !tab.canGoForward && !tab.immersed)
        tab.reload(); tab.back(); tab.forward()
        #expect(page.reloads == 1 && page.backs == 1 && page.forwards == 1)
    }

    @Test func failedOAuthCallbackSurvivesEngineURLRollbackUntilAnotherNavigation() throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let page = tab.page as! Page
        let provider = URL(string: "https://www.figma.com/oauth")!
        let callback = URL(string: "https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/?code=fixture&state=fixture")!
        page.emit(.url(provider))
        tab.stand(at: callback, failure: "Nothing answers at this address")

        // The failed provisional load can restore the provider's engine URL
        // before the batched tabs.onUpdated notification reads tab.address.
        page.emit(.url(provider))
        page.emit(.loading(false))
        #expect(tab.address == callback)
        #expect(tab.failure != nil)

        tab.navigationStarted(nil)
        page.emit(.url(provider))
        #expect(tab.address == provider)
    }

    @Test func unavailableEngineDoesNotRetireTheLivePage() {
        _ = NSApplication.shared
        let tab = Tab(shy: true, engine: .chromium, factory: .webKitOnly)
        defer { tab.close() }
        #expect(tab.engineKind == .webKit && tab.builtPage == nil)
        let page = tab.page
        #expect(page.engine == .webKit && tab.built === page)
        #expect(!tab.replaceEngine(with: .chromium, at: URLRequest(url: URL(string: "ownership:/no-engine")!)))
        #expect(tab.builtPage === page && page.stateEvents === tab)
    }

    @Test(arguments: [false, true])
    func lastPageCloseRemovesByIdentityAfterTeardownClosesAnEarlierTab(trailing: Bool) throws {
        let id = UUID(), factory = Factory()
        let browser = Browser(windowID: id)
        let earlier = make(factory, engine: .chromium), tab = make(factory, engine: .chromium), later = make(factory, engine: .chromium)
        let row = trailing ? [earlier, tab, later] : [earlier, tab]
        defer {
            [earlier, tab, later].forEach { $0.close() }
            Session.settle()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for (index, each) in row.enumerated() {
            each.restore(url: URL(string: "https://close.test/teardown/\(index)")!, title: "Page \(index)")
            browser.prepare(each)
        }
        earlier.kept = true
        later.kept = true
        browser.lay(row)
        browser.activeID = tab.id
        let page = try #require(tab.page as? Page)
        var closes = 0
        page.onRetire = {
            closes += 1
            browser.discard([earlier])
        }

        browser.close(tab)

        #expect(closes == 1 && page.retired && tab.gone && earlier.gone)
        #expect(browser.tabs.map(\.id) == (trailing ? [later.id] : []))
        #expect(!later.gone && browser.activeID == nil && browser.fieldShowing)
        let ghost = try #require(browser.ghosts.first { $0.url == tab.address })
        #expect(ghost.index == 1, "Recently Closed keeps the position recorded before teardown")
        #expect(browser.ghosts.count == 2)
    }

    @Test(arguments: [false, true])
    func closeRemembersTheCurrentIndexAfterAPageReplyClosesAnEarlierTab(trailing: Bool) throws {
        let id = UUID(), factory = Factory()
        let browser = Browser(windowID: id)
        let earlier = make(factory, engine: .chromium), tab = make(factory, engine: .chromium), later = make(factory, engine: .chromium)
        let row = trailing ? [earlier, tab, later] : [earlier, tab]
        defer {
            browser.dropAsks(tab)
            [earlier, tab, later].forEach { $0.close() }
            Session.settle()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for (index, each) in row.enumerated() {
            each.restore(url: URL(string: "https://close.test/reply/\(index)")!, title: "Page \(index)")
            browser.prepare(each)
        }
        browser.lay(row)
        browser.activeID = tab.id
        let page = try #require(tab.page as? Page)
        var replies = 0
        browser.ask(PageAsk(kind: .confirm, host: "close.test"), on: tab) { reply, _ in
            if case .no = reply { replies += 1 }
            else { Issue.record("Closing must reject the page's confirmation") }
            browser.close(earlier)
        }

        browser.close(tab)

        #expect(replies == 1 && earlier.gone && tab.gone && page.retired)
        #expect(browser.tabs.map(\.id) == (trailing ? [later.id] : []))
        #expect(browser.activeID == (trailing ? later.id : nil))
        let ghost = try #require(browser.ghosts.first { $0.url == tab.address })
        #expect(ghost.index == 0, "Answering the page moved this tab before it was recorded")
        #expect(browser.ghosts.count == 2)
    }

    @Test func engineChoiceRoundTripsWithSessionAndOldSessionsDefaultToWebKit() throws {
        let entry = Session.Entry(url: "https://example.test/current", title: "Current", pin: nil, engine: "chromium")
        let shape = Session.Shape(tabs: [entry], active: 0)
        let decoded = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(shape))
        #expect(decoded.tabs[0].engineKind == .chromium)
        let factory = Factory(), tab = make(factory, engine: decoded.tabs[0].engineKind)
        defer { tab.close() }
        tab.restore(url: URL(string: decoded.tabs[0].url)!, title: decoded.tabs[0].title)
        #expect(tab.builtPage == nil && tab.engineKind == .chromium)
        #expect(tab.page.engine == .chromium)
        let old = Data(#"{"url":"https://example.test/old","title":"Old"}"#.utf8)
        #expect(try JSONDecoder().decode(Session.Entry.self, from: old).engineKind == .webKit)
        let future = Data(#"{"url":"https://example.test/future","title":"Future","engine":"future-engine"}"#.utf8)
        #expect(try JSONDecoder().decode(Session.Entry.self, from: future).engineKind == .webKit)
    }

    @Test func productionSessionWriterStoresTheChoiceWithoutWakingTheTab() throws {
        let id = UUID(), factory = Factory()
        let browser = Browser(windowID: id)
        let tab = make(factory, engine: .chromium)
        defer {
            tab.close()
            Session.settle()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        tab.restore(url: URL(string: "https://session-engine.test/current")!, title: "Saved")
        browser.prepare(tab)
        browser.lay([tab])
        let entry = try #require(browser.sessionEntry(tab, id: tab.id))
        #expect(entry.engine == "chromium" && entry.id == tab.id.uuidString)
        #expect(entry.title == "Saved" && entry.url == tab.address?.absoluteString)
        #expect(tab.builtPage == nil && factory.choices.isEmpty)
        let roundTrip = try JSONDecoder().decode(Session.Entry.self, from: JSONEncoder().encode(entry))
        let restored = make(factory, engine: roundTrip.engineKind)
        defer { restored.close() }
        restored.restore(url: URL(string: roundTrip.url)!, title: roundTrip.title)
        #expect(restored.builtPage == nil && restored.engineKind == .chromium && restored.title == "Saved")
    }

    @Test func engineStateEventsAreSerializable() throws {
        let values: [PageStateChange] = [.title("Title"), .url(URL(string: "ownership:/page")), .loading(true),
            .back(true), .forward(false), .theme(PageColor(red: 1, green: 0, blue: 0, alpha: 1)), .underPage(nil),
            .camera(.active), .microphone(.muted), .screen(.none), .fullscreen(true)]
        #expect(try JSONDecoder().decode([PageStateChange].self, from: JSONEncoder().encode(values)) == values)
    }
    @Test func selectingAnEngineNeutralPageNeverUsesTheWebKitRevivalProbe() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let url = URL(string: "https://engine-selection.test/page")!
        tab.go(to: url)
        tab.revive()
        #expect(factory.pages.count == 1)
        #expect(factory.pages[0].requests.map(\.url) == [url])
    }

    @Test func thePageFootNeverConstructsAWebKitViewForAnotherEngine() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        Agents.makeRoom(tab, false)
        Agents.makeRoom(tab, true)
        #expect(tab.builtPage == nil)
        #expect(factory.pages.isEmpty)
    }

    @Test func liveSiteChoiceRequiresNativeAuthorityAndControllerPreservesTheReplacementSeam() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://www.netflix.com/watch/fixture")!
        tab.restore(url: url, title: "Saved title")
        let old = tab.page as! Page
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        old.frame = host.bounds
        host.addSubview(old)
        let id = tab.id
        await #expect(throws: (any Error).self) { try await tab.setSiteEngineChoice(.chromium) }
        #expect(tab.builtPage === old && !old.retired && tab.siteEngineChoice == .recommended)
        // Explicit controller fixture exercises replacement geometry only;
        // it is not native WK/CEF approval or release acceptance.
        let order = SwitchOrder()
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
            authority: order, transfer: order) { factory.sites.set(.chromium, for: url) }
        let chromium = try #require(tab.builtPage as? Page)
        #expect(tab.id == id && old.retired && chromium.engine == .chromium)
        #expect(chromium.superview === host && chromium.frame == host.bounds)
        #expect(chromium.requests.map(\.url) == [url] && tab.siteEngineChoice == .chromium)
        #expect(!tab.wantsWebKit(for: url) && !tab.wantsWebKit(for: url, emeFailure: true))
        await #expect(throws: (any Error).self) { try await tab.setSiteEngineChoice(.recommended) }
        #expect(tab.builtPage === chromium && !chromium.retired && tab.siteEngineChoice == .chromium)
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .webKit, request: URLRequest(url: url))],
            authority: order, transfer: order) { factory.sites.set(.recommended, for: url) }
        #expect(tab.id == id && chromium.retired && tab.page.engine == .webKit)
        #expect(tab.siteEngineChoice == .recommended && tab.wantsWebKit(for: url))
        #expect(factory.choices == [.webKit, .chromium, .webKit])
    }

    @Test func opensInRowAppearsOnlyWhenTheEngineDiffersFromWhatTheWindowWouldUse() async throws {
        // Engine .chromium: the window's own engine is Chromium, so a service
        // on the DRM list recommends WebKit and everything else Chromium.
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://www.netflix.com/title/1")!, title: "Netflix")
        #expect(tab.offersSiteEngine && tab.recommendedSiteEngine == .webKit)
        #expect(tab.siteEngineRowFacts == nil)
        try await tab.setSiteEngineChoice(.chromium)
        let chosen = try #require(tab.siteEngineRowFacts)
        #expect(chosen.title == "Opens in Chromium" && chosen.chosen && chosen.said == "Chosen for netflix.com")
        try await tab.setSiteEngineChoice(.webKit)
        #expect(tab.siteEngineRowFacts == nil)
        try await tab.setSiteEngineChoice(.recommended)
        #expect(tab.siteEngineRowFacts == nil && tab.siteEngineChoice == .recommended)

        let other = make(factory, engine: .chromium)
        defer { other.close() }
        other.restore(url: URL(string: "https://example.com/")!, title: "Example")
        #expect(other.recommendedSiteEngine == .chromium && other.siteEngineRowFacts == nil)
        try await other.setSiteEngineChoice(.webKit)
        let webkit = try #require(other.siteEngineRowFacts)
        #expect(webkit.title == "Opens in WebKit" && webkit.chosen)
        try await other.setSiteEngineChoice(.chromium)
        #expect(other.siteEngineRowFacts == nil)
        try await other.setSiteEngineChoice(.recommended)
        // On WebKit with no move of Yab's behind it (⌘K's Open in, a window
        // a WebKit page opened): no row says protected video (#1605).
        other.applySiteEngineChoice(.webKit, at: URLRequest(url: other.address!))
        #expect(other.siteEngineRowFacts == nil)
        other.applySiteEngineChoice(.chromium, at: URLRequest(url: other.address!))
        // Yab's own move for protected video: not a choice, so no cross.
        // The player's refusal names its site before WebKit's page is built.
        other.engineProtectedSite = Tab.protectedSite(other.address)
        other.applySiteEngineChoice(.webKit, at: URLRequest(url: other.address!))
        let moved = try #require(other.siteEngineRowFacts)
        #expect(moved.title == "Opens in WebKit" && !moved.chosen && moved.said == "For its protected video")
        // Only web pages.
        let blank = make(factory, engine: .chromium)
        defer { blank.close() }
        #expect(!blank.offersSiteEngine && blank.siteEngineRowFacts == nil)
    }

    @Test func siteChoiceDoesNotWakeSleepingTabsAndLazyLoadingUsesTheChoice() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://site-choice.test/page")!
        tab.restore(url: url, title: "Sleeping")
        try await tab.setSiteEngineChoice(.chromium)
        #expect(tab.builtPage == nil && factory.choices.isEmpty)
        #expect(tab.wake())
        #expect(factory.choices == [.chromium] && factory.pages[0].requests.map(\.url) == [url])
        let original = tab.page
        await #expect(throws: (any Error).self) { try await tab.setSiteEngineChoice(.webKit) }
        #expect(tab.builtPage === original && !factory.pages[0].retired && tab.siteEngineChoice == .chromium)
        let order = SwitchOrder()
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .webKit, request: URLRequest(url: url))],
            authority: order, transfer: order) { factory.sites.set(.webKit, for: url) }
        #expect(tab.page.engine == .webKit && tab.wantsWebKit(for: url, emeFailure: false))
        tab.close()
        await #expect(throws: (any Error).self) { try await tab.setSiteEngineChoice(.recommended) }
    }

    @Test func siteChoiceNavigationResolvesBeforeTakingTheConcreteWebKitPath() {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://forced-chromium.test/page")!
        factory.sites.set(.chromium, for: url)
        tab.go(to: url)
        #expect(factory.choices == [.chromium] && tab.built == nil)
        #expect(factory.pages[0].requests.map(\.url) == [url])
    }

    @Test(arguments: [false, true])
    func youtubeRuleSelectsChromiumFromAWebKitTabWhenOpeningOrWaking(waking: Bool) {
        let factory = Factory(), tab = make(factory, engine: .webKit)
        defer { tab.close() }
        factory.sites.setOwn(.chromium, host: "youtube.com")
        let url = URL(string: "https://www.youtube.com/watch?v=engine-rule")!
        if waking {
            tab.restore(url: url, title: "YouTube")
            #expect(tab.wake())
        } else {
            tab.go(to: url)
        }
        #expect(factory.choices == [.chromium])
        #expect(factory.pages.first?.requests.map(\.url) == [url])
        #expect(tab.engineKind == .chromium)
    }

    /// #1605: Auto is Chromium, and a built-in rule moved this tab to WebKit
    /// for Netflix. Every site after it in the tab stayed on WebKit, under
    /// "Auto (Chromium)" and "For its protected video".
    @Test func aTabMovedToWebKitForOneSiteGoesBackToItsDefaultOnTheNextSite() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let netflix = URL(string: "https://www.netflix.com/title/1")!
        tab.restore(url: netflix, title: "Netflix")
        let page = try #require(tab.page as? Page)
        page.url = netflix
        #expect(page.engine == .webKit && tab.chromiumDRMEnabled)
        let elsewhere = URL(string: "https://example.com/")!
        // Netflix's own pages stay on WebKit, untouched.
        #expect(try await tab.routeSiteEngine(URLRequest(url: URL(string: "https://www.netflix.com/browse")!), byPerson: true) == false)
        // A redirect or a script on its own is a hop of a flow under way
        // (a sign-in's way out and back): it stays where it started.
        #expect(try await tab.routeSiteEngine(URLRequest(url: elsewhere), byPerson: false) == false)
        var post = URLRequest(url: elsewhere)
        post.httpMethod = "POST"
        #expect(try await tab.routeSiteEngine(post, byPerson: true) == false)
        // A person's navigation to another site is taken to Chromium
        // (refused here, with no native authority, not let on in WebKit).
        await #expect(throws: (any Error).self) {
            _ = try await tab.routeSiteEngine(URLRequest(url: elsewhere), byPerson: true)
        }
        // So is Yab's own load there (typed, a bookmark, a link from another app).
        tab.engineSent = elsewhere
        await #expect(throws: (any Error).self) {
            _ = try await tab.routeSiteEngine(URLRequest(url: elsewhere), byPerson: false)
        }
        #expect(tab.builtPage === page && !page.retired && tab.engineSent == nil)
    }

    /// A player's refusal of the missing Widevine moves its tab for that site
    /// only: its own pages and subdomains stay on WebKit (no route straight
    /// back on WebKit's first navigation), any other site is Chromium's.
    @Test func aPlayersRefusalKeepsOnlyItsOwnSiteOnWebKit() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let player = URL(string: "https://www.videoplayer.com/watch/1")!
        tab.restore(url: player, title: "Player")
        let page = try #require(tab.page as? Page)
        page.url = player
        #expect(page.engine == .chromium && tab.wantsWebKit(for: player, emeFailure: true) && !tab.wantsWebKit(for: player))
        // What ChromiumPage's switch installs before WebKit's page is built.
        tab.engineProtectedSite = Tab.protectedSite(player)
        tab.applySiteEngineChoice(.webKit, at: URLRequest(url: player))
        let webKit = try #require(tab.builtPage as? Page)
        webKit.url = player
        #expect(webKit.engine == .webKit)
        for raw in ["https://www.videoplayer.com/watch/1", "https://cdn.videoplayer.com/x", "https://videoplayer.com/"] {
            let url = URL(string: raw)!
            #expect(tab.wantsWebKit(for: url) && !tab.routesToChromium(url))
        }
        for raw in ["https://example.com/", "https://videoplayer.com.evil.org/"] {
            #expect(tab.routesToChromium(URL(string: raw)!) && !tab.wantsWebKit(for: URL(string: raw)!))
        }
        // An own WebKit rule elsewhere still keeps that site on WebKit.
        factory.sites.set(.webKit, for: URL(string: "https://kept.test/")!)
        #expect(!tab.routesToChromium(URL(string: "https://kept.test/a")!))
        let row = try #require(tab.siteEngineRowFacts)
        #expect(row.said == "For its protected video" && !row.chosen)
        // Auto chosen again starts the site afresh.
        tab.unbuildForEngineTest()
        try await tab.setSiteEngineChoice(.recommended)
        #expect(tab.engineProtectedSite == nil && !tab.wantsWebKit(for: player))
    }

    /// Chromium picked by name as the default keeps a page whose player
    /// refuses the missing Widevine; Auto moves it. Rules apply to both.
    @Test func chromiumByNameKeepsAPlayersPageAutoMovesIt() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        let player = URL(string: "https://www.videoplayer.com/watch/1")!
        #expect(tab.wantsWebKit(for: player, emeFailure: true))
        factory.sites.store.set(EngineDefault.chromium.rawValue, forKey: EngineRules.defaultKey)
        #expect(!tab.wantsWebKit(for: player, emeFailure: true))
        #expect(tab.wantsWebKit(for: URL(string: "https://www.netflix.com/")!))
        factory.sites.store.set(EngineDefault.auto.rawValue, forKey: EngineRules.defaultKey)
        #expect(tab.wantsWebKit(for: player, emeFailure: true))
    }

    /// A window a WebKit page opened keeps its engine on another site: the
    /// move would cut window.opener and its sign-in would never end.
    @Test func aWindowAnotherPageOpenedStaysOnWebKit() throws {
        let factory = Factory(), opener = make(factory, engine: .chromium), tab = make(factory, engine: .chromium)
        defer { tab.close(); opener.close() }
        tab.opener = opener.id
        let netflix = URL(string: "https://www.netflix.com/login")!
        tab.restore(url: netflix, title: "Netflix")
        let page = try #require(tab.page as? Page)
        page.url = netflix
        #expect(page.engine == .webKit && !tab.routesToChromium(URL(string: "https://accounts.example.com/")!))
    }

    @Test func allowedNavigationPolicyCannotReplaceTheOriginalWithoutNativeAuthority() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let current = URL(string: "https://navigation-source.test/draft")!
        let target = URL(string: "https://navigation-target.test/next")!
        tab.restore(url: current, title: "Original draft")
        let original = tab.page as! Page
        original.url = current
        factory.sites.set(.chromium, for: target)
        await #expect(throws: (any Error).self) {
            _ = try await tab.routeSiteEngine(URLRequest(url: target))
        }
        #expect(tab.builtPage === original && !original.retired && tab.address == current)
        #expect(original.requests.isEmpty && factory.choices == [.webKit])
        #expect(tab.siteEngineChoice == .recommended && factory.sites.choice(for: target) == .chromium)
    }

    @Test func resettingASleepingOverrideRestoresTheFactoryDefault() async throws {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://sleeping-reset.test/page")!, title: "Sleeping")
        try await tab.setSiteEngineChoice(.webKit)
        #expect(tab.builtPage == nil && tab.engineKind == .webKit)
        try await tab.setSiteEngineChoice(.recommended)
        #expect(tab.builtPage == nil && factory.choices.isEmpty && tab.engineKind == .chromium)
        #expect(tab.page.engine == .chromium)
    }

    @Test func siteChoiceRefusesAnUnmigratedLiveProfileBeforeTouchingCookiesOrSettings() async {
        let factory = PageEngineFactory(kinds: [.chromium, .webKit]) { tab, _ in
            ChromiumPage(tab: tab, profile: UUID().uuidString)
        }
        let tab = Tab(engine: .chromium, factory: factory)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://moved-profile.test/page")!, title: "Moved")
        let old = tab.page
        #expect((old as? ChromiumPage)?.profile != tab.chromiumProfile)
        await #expect(throws: SiteEngineError.profileChanged) { try await tab.setSiteEngineChoice(.webKit) }
        #expect(tab.builtPage === old && tab.siteEngineChoice == .recommended)
        #expect((old as? ChromiumPage)?.remoteID == nil)
    }

    @Test func defaultEngineMovesSleepingHandlesAndPreservesHostOverrides() {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://global-engine.test/page")!
        tab.restore(url: url, title: "Sleeping")
        let identity = tab.id
        tab.followDefaultEngine(.chromium)
        #expect(tab.id == identity && tab.engineKind == .chromium && tab.builtPage == nil)
        #expect(tab.chromiumDRMEnabled && factory.choices.isEmpty)
        factory.sites.set(.webKit, for: url)
        tab.followDefaultEngine(.chromium)
        #expect(tab.engineKind == .webKit && tab.builtPage == nil && tab.siteEngineChoice == .webKit)
        factory.sites.set(.chromium, for: url)
        tab.followDefaultEngine(.webKit)
        #expect(tab.engineKind == .chromium && !tab.chromiumDRMEnabled && tab.builtPage == nil)
    }

    @Test func defaultEngineKeepsProtectedServicesInWebKitWithoutWakingThePage() {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://www.netflix.com/title/1")!, title: "Netflix")
        tab.followDefaultEngine(.chromium)
        #expect(tab.engineKind == .webKit && tab.chromiumDRMEnabled && tab.builtPage == nil)
        #expect(factory.choices.isEmpty)
    }

    @Test func defaultEngineLeavesAWorkingPageAloneUntilItWakes() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://live-default.test/page")!
        tab.restore(url: url, title: "Live")
        let live = try #require(tab.page as? Page)
        live.url = url
        tab.followDefaultEngine(.chromium)
        // No reload, no second page, no change of what the tab says it is.
        #expect(tab.builtPage === live && !live.retired && live.reloads == 0 && live.requests.isEmpty)
        #expect(tab.engineKind == .webKit && !tab.chromiumDRMEnabled && tab.effectiveSiteEngine == .webKit)
        #expect(tab.siteEngineRowFacts == nil && tab.recommendedSiteEngine == .webKit)
        // Choosing back and forth while it works leaves the last word.
        tab.followDefaultEngine(.webKit)
        tab.followDefaultEngine(.chromium)
        #expect(tab.enginePendingDefault == .chromium && tab.builtPage === live)
        tab.unbuildForEngineTest()
        #expect(tab.builtPage == nil)
        #expect(tab.page.engine == .chromium)
        #expect(tab.chromiumDRMEnabled && tab.enginePendingDefault == nil)
    }

    @Test func defaultEngineWakesARuleTabByTheRule() async throws {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        let url = URL(string: "https://www.netflix.com/title/1")!
        tab.restore(url: url, title: "Netflix")
        _ = tab.page
        tab.followDefaultEngine(.chromium)
        tab.unbuildForEngineTest()
        #expect(tab.page.engine == .webKit)
        #expect(tab.chromiumDRMEnabled)
    }

    @Test func restoredTabsTakeTheDefaultOfNowButOwnedPagesKeepTheirs() {
        let web = URL(string: "https://example.com/")!
        #expect(EngineRules.restored(saved: .webKit, url: web, standard: .chromium) == .chromium)
        #expect(EngineRules.restored(saved: .chromium, url: web, standard: .webKit) == .webKit)
        #expect(EngineRules.restored(saved: .chromium, url: web, standard: nil) == .chromium)
        let owned = URL(string: "chrome-extension://abc/page.html")!
        #expect(EngineRules.restored(saved: .chromium, url: owned, standard: .webKit) == .chromium)
        #expect(EngineRules.restored(saved: .webKit, url: nil, standard: .chromium) == .chromium)
    }

    @Test func aPageApprovalDecidesTheSwitch() {
        typealias A = EngineSwitchApproval
        #expect(A.next(page: .leave, asked: false, typed: false, agentPage: false) == .go)
        #expect(A.next(page: .leave, asked: true, typed: true, agentPage: false) == .go)
        #expect(A.next(page: .stay, asked: true, typed: false, agentPage: false) == .keep)
        #expect(A.next(page: .stay, asked: false, typed: true, agentPage: false) == .keep)
        // The page said nothing about text that is typed: the person decides.
        #expect(A.next(page: .leave, asked: false, typed: true, agentPage: false) == .askPerson)
        #expect(A.next(page: .unavailable, asked: false, typed: true, agentPage: false) == .askPerson)
        // No preflight in this SDK and nothing typed: it may go.
        #expect(A.next(page: .unavailable, asked: false, typed: false, agentPage: false) == .go)
        #expect(A.next(page: .unavailable, asked: false, typed: true, agentPage: true) == .go)
    }

    @Test func aSwitchFailureSpeaksExceptForStay() {
        #expect(EngineSwitchWords.failure(EngineSwitchTransactionError.declined, to: .chromium) == nil)
        #expect(EngineSwitchWords.failure(CancellationError(), to: .chromium) == nil)
        #expect(EngineSwitchWords.failure(EngineSwitchTransactionError.overlapping, to: .chromium) == nil)
        #expect(EngineSwitchWords.failure(EngineSwitchTransactionError.changed, to: .chromium)?.hasSuffix("in Chromium") == true)
        #expect(EngineSwitchWords.failure(SiteEngineError.profileChanged, to: .webKit)?.hasSuffix("in WebKit") == true)
        #expect(EngineSwitchWords.failure(EngineSwitchTransactionError.typedTextKept, to: .webKit)?.contains("typed") == true)
    }

    @Test func siteEngineBenchReadsSleepingChoiceWithoutBuildingAPage() {
        let factory = Factory(), tab = make(factory)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://bench-choice.test/page")!, title: "Sleeping")
        var response: [String: Any] = [:]
        ChromiumDRMBench.respond(["op": "site-engine"], tab: tab) { response = $0 }
        #expect(response["choice"] as? String == "recommended")
        #expect(response["tab"] as? String == tab.id.uuidString)
        ChromiumDRMBench.respond(["op": "site-engine", "choice": "unknown"], tab: tab) { response = $0 }
        #expect(response["error"] != nil)
        #expect(tab.builtPage == nil && factory.choices.isEmpty && tab.siteEngineChoice == .recommended)
    }

}

/// Submission provenance and asynchronous replies at the native page seam.
/// The full forms eval separately exercises the actual JS and save card.
@Suite(.serialized)
@MainActor
struct FrameSignInTests {
    private func frame() -> PageFrame {
        PageFrame(isMain: false, url: URL(string: "https://accounts.test/login"), token: NSObject(),
                  origin: PageOrigin(scheme: "https", host: "accounts.test", port: 443))
    }

    @Test(arguments: [PageEngineKind.webKit, .chromium])
    func recheckUsesTheSubmittingFrameAndKeepsItsSite(engine: PageEngineKind) {
        let factory = TabEngineTests.Factory(), tab = TabEngineTests().make(factory, engine: engine)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page, source = frame()
        page.emit(.url(URL(string: "https://console.test/login")!))
        page.scriptResult = false
        var offers = 0
        tab.onCredentials = { _, host, user, password, clear, frame in
            offers += 1
            #expect(host == "accounts.test" && user == "fixture" && password == "synthetic")
            #expect(!clear && frame?.token === source.token)
        }
        tab.sentSignIn(user: "fixture", password: "synthetic", frame: source)
        tab.settleSignIn(looked: true)
        #expect(page.lastScriptFrame?.token === source.token && offers == 1)
    }

    @Test func aParentRouteChangeKeepsTheSameFrameSubmission() {
        let factory = TabEngineTests.Factory(), tab = TabEngineTests().make(factory)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        page.emit(.url(URL(string: "https://console.test/login")!))
        page.scriptResult = false
        var offers = 0
        tab.onCredentials = { _, _, _, _, _, _ in offers += 1 }
        tab.sentSignIn(user: "fixture", password: "synthetic", frame: frame())
        page.emit(.url(URL(string: "https://console.test/code#step2")!))
        tab.settleSignIn(looked: true)
        #expect(offers == 1)
    }

    @Test func aRestoredFrameFormVetoesSaving() {
        let factory = TabEngineTests.Factory(), tab = TabEngineTests().make(factory)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        page.scriptResult = true
        var offers = 0
        tab.onCredentials = { _, _, _, _, _, _ in offers += 1 }
        tab.sentSignIn(user: "fixture", password: "synthetic", frame: frame())
        tab.settleSignIn(looked: true)
        page.scriptResult = false
        tab.settleSignIn(looked: true)
        #expect(offers == 0)
    }

    @Test func oldRecheckCannotConsumeANewerSubmission() {
        let factory = TabEngineTests.Factory(), tab = TabEngineTests().make(factory)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        var reply: (@MainActor (Result<Any?, Error>) -> Void)?
        page.scriptReply = { reply = $0 }
        var offered: [String] = []
        tab.onCredentials = { _, _, user, _, _, _ in offered.append(user) }
        let source = frame()
        tab.sentSignIn(user: "old", password: "synthetic", frame: source)
        tab.settleSignIn(looked: true)
        let check = tab.passwordOfferCheck
        tab.sentSignIn(user: "new", password: "synthetic", frame: source)
        #expect(tab.passwordOfferCheck != check)
        reply?(.success(false))
        #expect(offered.isEmpty)
        page.scriptReply = nil
        page.scriptResult = false
        tab.settleSignIn(looked: true)
        #expect(offered == ["new"])
    }

    @Test func parentNavigationAndUnreadableFrameCannotProveSuccess() {
        let factory = TabEngineTests.Factory(), tab = TabEngineTests().make(factory)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        page.emit(.url(URL(string: "https://console.test/login")!))
        var offers = 0
        tab.onCredentials = { _, _, _, _, _, _ in offers += 1 }
        tab.sentSignIn(user: "fixture", password: "synthetic", frame: frame())
        page.scriptReply = { $0(.failure(PageEngineError.foreignFrame)) }
        tab.settleSignIn(looked: true)
        #expect(offers == 0)
        page.scriptReply = nil
        page.scriptResult = false
        page.emit(.url(URL(string: "https://other.test/")!))
        tab.settleSignIn(looked: true)
        #expect(offers == 0)
    }
}


extension TabEngineTests {
    @Test func gmailFolderTitlesDoNotReplacePrimaryCount() {
        for engine in [PageEngineKind.webKit, .chromium] {
            for (folder, title, source) in [
                ("inbox", "Inbox (21) - fixture - Gmail", Optional(7)),
                ("spam", "Spam (21) - fixture - Gmail", Optional(7)),
                ("starred", "Starred (21) - fixture - Gmail", Optional(7)),
                ("label/Work", "Work (21) - fixture - Gmail", Optional(7)),
                ("spam", "Спам (21) - fixture - Gmail", Optional(0)),
                ("spam", "Spam (21) - fixture - Gmail", Optional<Int>.none),
            ] {
                let factory = Factory(), tab = make(factory, engine: engine)
                defer { tab.close() }
                tab.restore(url: URL(string: "https://mail.google.com/mail/u/1/#" + folder)!, title: title)
                _ = tab.page
                tab.sourced(source)
                #expect(tab.count == source, "Gmail folder title must not replace the Primary feed count")
                tab.sourced(3)
                #expect(tab.count == 3, "A new Primary count must update the live pin in every folder")
            }
        }
    }

    @Test func gmailExplicitBadgeStillWinsAndSleepingCountDoesNotWake() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://mail.google.com/mail/u/0/#spam")!, title: "Spam (21) - fixture - Gmail")
        tab.sourced(7)
        #expect(tab.count == 7 && tab.builtPage == nil && factory.pages.isEmpty)
        _ = tab.page
        tab.badged(4)
        tab.sourced(8)
        #expect(tab.count == 4)
        tab.badged(0)
        #expect(tab.count == 0)
    }

    @Test func otherSitesKeepTheirTitleAndBadgePrecedence() {
        let factory = Factory(), tab = make(factory, engine: .chromium)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://app.slack.com/client/fixture")!, title: "(21) Slack")
        _ = tab.page
        tab.sourced(7)
        #expect(tab.count == 21)
        tab.badged(4)
        #expect(tab.count == 4)
        tab.badged(0)
        #expect(tab.count == 0)
    }
}

extension TabEngineTests {
    /// Controller-order fixture only. This does not impersonate WK/CEF native
    /// approval, input sealing or atomic unload; production has no such adapter.
    @MainActor private final class SwitchOrder: EngineSwitchAuthority, EngineSwitchLease, EngineSwitchTransfer {
        var events: [String] = []
        var approved = true
        var committed = EngineSwitchCommit.released
        var cancellation = EngineSwitchCancellation.retained
        var preparationError: (any Error)?
        var onSeal: (() -> Void)?
        var onReserve: (() async -> Void)?
        var onCommit: (() -> Void)?
        var onSynchronize: (() -> Void)?
        var captureError: (any Error)?
        func reserve(_ originals: [EngineSwitchTransaction.Original]) async throws -> any EngineSwitchLease {
            events.append("reserve-\(originals.count)"); await onReserve?(); return self
        }
        func approveAll() async throws -> Bool {
            events.append("approve-all")
            if let preparationError { throw preparationError }
            return approved
        }
        func seal() async throws { events.append("seal"); onSeal?() }
        func validate() async throws -> Bool { events.append("validate"); return true }
        func commit() async -> EngineSwitchCommit { events.append("commit-all"); onCommit?(); return committed }
        func cancel() async -> EngineSwitchCancellation { events.append("cancel"); return cancellation }
        func capture(_ original: EngineSwitchTransaction.Original) async throws -> EngineSwitchDocument {
            events.append("capture")
            if let captureError { throw captureError }
            let url = original.address!
            let state: [String: Any] = ["url": url.absoluteString, "local": [], "session": [], "fields": [], "x": 0, "y": 0]
            return try EngineSwitchDocument(url: url, json: String(decoding: JSONSerialization.data(withJSONObject: state), as: UTF8.self))
        }
        func synchronize(_ original: EngineSwitchTransaction.Original) async throws {
            events.append("synchronize"); onSynchronize?()
        }
    }

    @Test func globalTransactionAppliesEveryLazyHandleBeforePersistingOnce() async throws {
        let factory = Factory(), a = make(factory), b = make(factory)
        defer { a.close(); b.close() }
        let url = URL(string: "https://lazy-transaction.test/page")!
        a.restore(url: url, title: "A"); b.restore(url: url, title: "B")
        var persisted = 0
        try await EngineSwitchTransaction.execute([
            .init(tab: a, engine: .chromium, request: URLRequest(url: url)),
            .init(tab: b, engine: .chromium, request: URLRequest(url: url))
        ]) {
            #expect(a.engineKind == .chromium && b.engineKind == .chromium)
            #expect(a.builtPage == nil && b.builtPage == nil)
            persisted += 1
        }
        #expect(persisted == 1 && factory.choices.isEmpty)
    }

    @MainActor private final class Said: EngineSwitchQuestions {
        var isTyped = false
        var verdict = EngineSwitchApproval.Page.leave
        var asked = false
        var answer: Bool?
        var personAsked = 0
        func typed(_ tab: Tab) async -> Bool { isTyped }
        func page(_ tab: Tab) async -> (verdict: EngineSwitchApproval.Page, asked: Bool) { (verdict, asked) }
        func person(_ tab: Tab) async -> Bool? { personAsked += 1; return answer }
    }

    private func switching(_ said: Said) -> (Factory, Tab, Page, URL, SwitchOrder) {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        let url = URL(string: "https://asked-switch.test/page")!
        tab.restore(url: url, title: "Original")
        let page = tab.page as! Page
        page.url = url
        return (factory, tab, page, url, order)
    }

    @Test func stayKeepsThePageThePreferenceAndTheEngine() async throws {
        let said = Said(); said.verdict = .stay; said.asked = true
        let (factory, tab, page, url, order) = switching(said)
        defer { tab.close() }
        var installed = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([
                .init(tab: tab, engine: .chromium, request: URLRequest(url: url), installing: { installed = true })
            ], authority: EngineSwitchAsking(questions: said), transfer: order)
        }
        #expect(!installed && tab.builtPage === page && !page.retired && tab.engineKind == .webKit)
        #expect(factory.choices.count == 1 && order.events.isEmpty)
    }

    @Test func typedTextWithoutAnApprovalNeverGoesSilently() async throws {
        let said = Said(); said.verdict = .unavailable; said.isTyped = true; said.answer = nil
        let (_, tab, page, url, order) = switching(said)
        defer { tab.close() }
        // Nobody to ask: the tab stays.
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                                                      authority: EngineSwitchAsking(questions: said), transfer: order)
        }
        #expect(tab.builtPage === page && !page.retired && said.personAsked == 1)
        // Asked, and Stay.
        said.answer = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                                                      authority: EngineSwitchAsking(questions: said), transfer: order)
        }
        #expect(tab.builtPage === page && !page.retired)
        // Asked, and Leave.
        said.answer = true
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                                                  authority: EngineSwitchAsking(questions: said), transfer: order)
        #expect(tab.engineKind == .chromium && page.retired)
    }

    @Test func noDocumentToCarryStillSwitchesByLoadingTheAddress() async throws {
        let said = Said()
        let (factory, tab, page, url, order) = switching(said)
        defer { tab.close() }
        order.captureError = EngineSwitchTransactionError.captureUnavailable
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                                                  authority: EngineSwitchAsking(questions: said), transfer: order)
        #expect(tab.engineKind == .chromium && page.retired && tab.engineSwitchDocument == nil)
        #expect(factory.pages.last?.requests.last?.url == url)
    }

    @Test func aRuleAndAHoldAreInPlaceBeforeTheNewPageIsBuilt() async throws {
        let said = Said()
        let (factory, tab, _, url, order) = switching(said)
        defer { tab.close() }
        var pagesAtInstall = -1
        try await EngineSwitchTransaction.execute([
            .init(tab: tab, engine: .chromium, request: URLRequest(url: url), installing: { pagesAtInstall = factory.pages.count })
        ], authority: EngineSwitchAsking(questions: said), transfer: order)
        #expect(pagesAtInstall == 1 && factory.pages.count == 2)
    }

    @Test func switchControllerApprovesAndSealsAllBeforeCaptureAndPersistsAfterCommit() async throws {
        let factory = Factory(), a = make(factory), b = make(factory), order = SwitchOrder()
        defer { a.close(); b.close() }
        let url = URL(string: "https://switch-order.test/page")!
        a.restore(url: url, title: "A"); b.restore(url: url, title: "B")
        let first = a.page, second = b.page
        try await EngineSwitchTransaction.execute([
            .init(tab: a, engine: .chromium, request: URLRequest(url: url)),
            .init(tab: b, engine: .chromium, request: URLRequest(url: url))
        ], authority: order, transfer: order) {
            #expect(a.builtPage !== first && b.builtPage !== second)
            order.events.append("persist")
        }
        #expect(order.events == ["reserve-2", "approve-all", "seal", "capture", "capture", "synchronize", "synchronize", "validate", "commit-all", "persist"])
        #expect(a.engineSwitchDocument != nil && b.engineSwitchDocument != nil)
    }

    @Test func supersededRoutingIntentCancelsTheControllerBeforeNativeCommit() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-routing-intent.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        var intentCurrent = true
        order.onSynchronize = { intentCurrent = false }
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([
                .init(tab: tab, engine: .chromium, request: URLRequest(url: url), isCurrent: { intentCurrent })
            ], authority: order, transfer: order) { persisted = true }
        }
        #expect(order.events == ["reserve-1", "approve-all", "seal", "capture", "synchronize", "cancel"])
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
    }

    @Test func stayCancelsWholeControllerGroupBeforeCaptureOrPreferenceWrites() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-stay.test/page")!
        tab.restore(url: url, title: "Draft")
        let original = tab.page
        order.approved = false
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(order.events == ["reserve-1", "approve-all", "cancel"])
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
    }

    @Test func inputAfterApprovalCancelsWithoutCapturingOrReplacingTheOriginal() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-input-barrier.test/page")!
        tab.restore(url: url, title: "Draft")
        let original = tab.page
        order.onSeal = { original.lastInput = 123 }
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(order.events == ["reserve-1", "approve-all", "seal", "cancel"])
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
    }

    @Test func navigationDuringTransferCancelsBeforeAnyCommit() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-navigation-barrier.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        order.onSynchronize = { tab.restore(url: URL(string: "https://switch-navigation-barrier.test/replaced")!, title: "New") }
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(!order.events.contains("commit-all") && order.events.last == "cancel")
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
    }

    @Test func retainedNativeGroupCannotInstallAnyDestinationOrPersist() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-retained.test/page")!
        tab.restore(url: url, title: "Draft")
        let original = tab.page
        order.committed = .retained
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(order.events.suffix(2) == ["commit-all", "cancel"])
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
    }
}

extension TabEngineTests {
    @Test func cancellationAfterPositiveNativeCommitStillInstallsDestinations() async throws {
        let factory = Factory(), a = make(factory), b = make(factory), order = SwitchOrder()
        defer { a.close(); b.close() }
        let urlA = URL(string: "https://switch-commit-cancellation.test/a")!
        let urlB = URL(string: "https://switch-commit-cancellation.test/b")!
        a.restore(url: urlA, title: "A"); b.restore(url: urlB, title: "B")
        let originalA = a.page, originalB = b.page, idA = a.id, idB = b.id
        var operation: Task<Void, Error>?
        order.onCommit = { operation?.cancel() }
        var persisted = false
        operation = Task { @MainActor in
            try await EngineSwitchTransaction.execute([
                .init(tab: a, engine: .chromium, request: URLRequest(url: urlA)),
                .init(tab: b, engine: .chromium, request: URLRequest(url: urlB))
            ], authority: order, transfer: order) {
                #expect(a.builtPage !== originalA && b.builtPage !== originalB)
                persisted = true
            }
        }
        try await operation?.value
        #expect(persisted && a.engineKind == .chromium && b.engineKind == .chromium)
        #expect(a.id == idA && b.id == idB && factory.pages.count == 4)
        #expect(factory.pages[0].retired && factory.pages[1].retired)
        #expect(factory.pages[2].requests.map(\.url) == [urlA] && factory.pages[3].requests.map(\.url) == [urlB])
        #expect(!order.events.contains("cancel"))
    }
}

extension TabEngineTests {
    @Test func overlappingControllerCannotStealAnExistingSourceReservation() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-overlap.test/page")!
        tab.restore(url: url, title: "Draft")
        _ = tab.page
        var release: CheckedContinuation<Void, Never>?
        order.onReserve = { await withCheckedContinuation { release = $0 } }
        let change = EngineSwitchTransaction.Change(tab: tab, engine: .chromium, request: URLRequest(url: url))
        let first = Task { @MainActor in try await EngineSwitchTransaction.execute([change], authority: order, transfer: order) }
        defer { release?.resume(); release = nil }
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(release != nil)
        var secondPersisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([change], authority: order, transfer: order) { secondPersisted = true }
        }
        #expect(!secondPersisted && order.events == ["reserve-1"])
        release?.resume(); release = nil
        try await first.value
        #expect(tab.engineKind == .chromium)
    }

    @Test func sameURLReplacementDuringTransferKeepsTheNewHandleUntouched() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-same-url.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        var replacement: (any PageHandle)?
        order.onSynchronize = {
            #expect(tab.replaceEngine(with: .chromium, at: URLRequest(url: url)))
            replacement = tab.builtPage
        }
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(!persisted && !order.events.contains("commit-all") && order.events.last == "cancel")
        #expect(tab.builtPage === replacement && tab.builtPage !== original)
        #expect(factory.pages.count == 2 && !factory.pages[1].retired)
    }
}


extension TabEngineTests {
    @Test func thrownPreparationReleasesOnlyAfterRetainedNativeCancellationACK() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-prepare-failure.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        order.preparationError = EngineSwitchTransactionError.captureUnavailable
        var persisted = false
        await #expect(throws: EngineSwitchTransactionError.self) {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
        }
        #expect(order.events == ["reserve-1", "approve-all", "cancel"])
        #expect(!persisted && tab.builtPage === original && !factory.pages[0].retired)
        #expect(EngineSwitchTransaction.recovery(for: tab) == nil)
        order.preparationError = nil
        // A positive retained-release ACK frees the group for a later choice.
        try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
            authority: order, transfer: order) { persisted = true }
        #expect(persisted && tab.engineKind == .chromium)
    }

    @Test func canceledUncertainNativeCommitQuarantinesWholeGroupWithoutCancelOrPersistence() async throws {
        let factory = Factory(), a = make(factory), b = make(factory), order = SwitchOrder()
        defer { a.close(); b.close() }
        let url = URL(string: "https://switch-unknown.test/page")!
        a.restore(url: url, title: "A"); b.restore(url: url, title: "B")
        let pageA = a.page, pageB = b.page
        let changes: [EngineSwitchTransaction.Change] = [
            .init(tab: a, engine: .chromium, request: URLRequest(url: url)),
            .init(tab: b, engine: .chromium, request: URLRequest(url: url))]
        order.committed = .unknown
        var operation: Task<Void, Error>?
        var persisted = false
        order.onCommit = { operation?.cancel() }
        operation = Task { @MainActor in
            try await EngineSwitchTransaction.execute(changes, authority: order, transfer: order) { persisted = true }
        }
        do { try await operation?.value; Issue.record("Uncertain commit must require recovery") }
        catch EngineSwitchTransactionError.recoveryRequired(let record) {
            #expect(record.phase == .commitUncertain && record.tabs == [a.id, b.id])
            #expect(EngineSwitchTransaction.recovery(for: a) == record)
            #expect(EngineSwitchTransaction.recovery(for: b) == record)
        }
        #expect(!persisted && !order.events.contains("cancel"))
        #expect(a.builtPage === pageA && b.builtPage === pageB)
        #expect(!factory.pages[0].retired && !factory.pages[1].retired && factory.choices == [.webKit, .webKit])
        let next = SwitchOrder()
        do {
            try await EngineSwitchTransaction.execute(changes, authority: next, transfer: next)
            Issue.record("Unknown native ownership must fence a new switch")
        } catch EngineSwitchTransactionError.overlapping { }
        #expect(next.events.isEmpty)
    }

    @Test func missingCancellationACKIsNotSafeRollback() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-cancel-unknown.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        order.approved = false; order.cancellation = .unknown
        var persisted = false
        do {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
            Issue.record("A lost cancellation ACK cannot free original ownership")
        } catch EngineSwitchTransactionError.recoveryRequired(let record) {
            #expect(record.phase == .cancellationUncertain && EngineSwitchTransaction.recovery(for: tab) == record)
        }
        #expect(!persisted && order.events == ["reserve-1", "approve-all", "cancel"])
        #expect(tab.builtPage === original && !factory.pages[0].retired)
    }

    @Test func positiveNativeCommitWithReplacementIdentityRequiresRecoveryWithoutSourceCancel() async throws {
        let factory = Factory(), tab = make(factory), order = SwitchOrder()
        defer { tab.close() }
        let url = URL(string: "https://switch-postcommit-identity.test/page")!
        tab.restore(url: url, title: "Original")
        let original = tab.page
        var replacement: (any PageHandle)?
        order.onCommit = {
            #expect(tab.replaceEngine(with: .chromium, at: URLRequest(url: url)))
            replacement = tab.builtPage
        }
        var persisted = false
        do {
            try await EngineSwitchTransaction.execute([.init(tab: tab, engine: .chromium, request: URLRequest(url: url))],
                authority: order, transfer: order) { persisted = true }
            Issue.record("A positive old-source receipt cannot overwrite a replacement")
        } catch EngineSwitchTransactionError.recoveryRequired(let record) {
            #expect(record.phase == .releasedIdentityChanged && EngineSwitchTransaction.recovery(for: tab) == record)
        }
        #expect(!persisted && !order.events.contains("cancel"))
        #expect(tab.builtPage === replacement && tab.builtPage !== original)
        #expect(factory.pages.count == 2 && !factory.pages[1].retired && tab.siteEngineChoice == .recommended)
        #expect(tab.engineSwitchDocument == nil)
    }
}

@Suite(.serialized)
@MainActor
struct NavigationTitleTests {
    @Test func sameDocumentAddressChangeKeepsItsPageIcon() {
        let factory = TabEngineTests.Factory()
        let tab = TabEngineTests().make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        let host = UUID().uuidString.lowercased() + ".test"
        page.emit(.url(URL(string: "https://\(host)/old")!))
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        tab.icon = icon
        page.emit(.url(URL(string: "https://\(host)/new")!))
        #expect(tab.icon === icon)
    }

    @Test func chromiumSameSiteDestinationDoesNotKeepThePreviousPageIcon() {
        let factory = TabEngineTests.Factory()
        let tab = TabEngineTests().make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        let host = UUID().uuidString.lowercased() + ".test"
        page.emit(.url(URL(string: "https://\(host)/old")!))
        tab.icon = NSImage(size: NSSize(width: 16, height: 16))
        // A document navigation starts before its URL arrives. A URL event
        // alone can be pushState in the current document, which keeps its icon.
        tab.navigationStarted(PageNavigation())
        page.emit(.url(URL(string: "https://\(host)/new")!))
        #expect(tab.icon == nil, "An uncached destination uses its site fallback, not the old page's custom icon")
    }

    @Test func chromiumCommitResetBeatsThePreviousDocumentsQueuedTitle() async throws {
        let factory = TabEngineTests.Factory()
        let tab = TabEngineTests().make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        page.emit(.url(URL(string: "https://example.test/old")!))
        page.emit(.title("Previous document"))
        page.emit(.title("Previous document — queued"))
        page.emit(.url(URL(string: "https://example.test/new")!))
        page.emit(.title(""))
        #expect(tab.title.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.title.isEmpty)
        page.emit(.title("New document"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.title == "New document")
    }

    @Test(arguments: [false, true])
    func delayedTitleCannotRenameRestoredOrFreshPage(restored: Bool) async throws {
        let factory = TabEngineTests.Factory()
        let tab = TabEngineTests().make(factory, engine: .chromium)
        defer { tab.close() }
        let oldPage = tab.page as! TabEngineTests.Page
        oldPage.emit(.url(URL(string: "ownership:/old-document")!))
        oldPage.emit(.title("Previous document"))
        oldPage.emit(.title("Previous document — delayed"))
        let next = URL(string: "ownership:/fresh-document")!
        let expected = restored ? "Saved destination" : ""
        if restored {
            tab.unbuildForEngineTest()
            tab.restore(url: next, title: expected)
        } else {
            tab.goFresh(to: next)
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.address == next && tab.title == expected)
        let newPage = tab.page as! TabEngineTests.Page
        newPage.emit(.title("Loaded destination"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.title == "Loaded destination")
    }

    @Test func delayedTitleCannotRenameTheNextNavigation() async throws {
        let factory = TabEngineTests.Factory()
        let tab = TabEngineTests().make(factory, engine: .chromium)
        defer { tab.close() }
        let page = tab.page as! TabEngineTests.Page
        let old = URL(string: "ownership:/hanlons-razor")!
        let next = URL(string: "ownership:/search?q=yab+browser")!
        page.emit(.url(old))
        page.emit(.title("Hanlon’s razor"))
        #expect(tab.title == "Hanlon’s razor")
        // A title update is coalesced for 250 ms. The search starts before
        // that write lands; its response may take seconds on a poor link.
        page.emit(.title("Hanlon’s razor — updated"))
        tab.go(to: next)
        #expect(tab.title.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.address == next)
        #expect(tab.title.isEmpty, "The preceding document's delayed title must not name the search")
        page.emit(.title("yab browser — Search"))
        try await Task.sleep(for: .milliseconds(350))
        #expect(tab.title == "yab browser — Search")
    }

}

/// Isolated from the engine-policy suite so this navigation regression has
/// its own deferred check, independent of memory-pressure policy assertions.
@Suite(.serialized)
@MainActor
struct FieldNavigationTitleTests {
    /// Feedback #1752: a throttled title from the old document must not
    /// repopulate the row after the field has sent it to a new address.
    @Test func navigationClearsAQueuedOldDocumentTitle() async throws {
        for engine in [PageEngineKind.webKit, .chromium] {
            let factory = TabEngineTests.Factory()
            let tab = TabEngineTests().make(factory, engine: engine)
            defer { tab.close() }
            let page = tab.page as! TabEngineTests.Page
            page.emit(.title("Old page"))
            page.emit(.title("Hanlon's razor"))
            let destination = URL(string: "ownership:/search?q=yab-browser")!
            tab.go(to: destination)
            #expect(tab.title.isEmpty)
            try await Task.sleep(for: .milliseconds(350))
            #expect(tab.address == destination)
            #expect(tab.title.isEmpty)
            page.emit(.title("Yab Browser"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(tab.title == "Yab Browser")
        }
    }
}

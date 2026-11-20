import AppKit
import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// The cookie step's pace from a live bridge: quick while a host is open on
/// both engines or someone looks at a Chromium page, slow otherwise, and a
/// slow wait under way cut short as soon as either becomes true.
@MainActor @Suite(.serialized)
struct CookieStepPaceTests {
    private let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }

    private func host(_ name: String) -> URL { URL(string: "https://\(name)-\(UUID().uuidString.prefix(8).lowercased()).test/")! }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A registered window holding a WebKit tab on screen and a Chromium tab behind it.
    private func browser(_ window: NSWindow) -> (browser: Browser, chromium: Tab, page: ChromiumPage)? {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let web = Tab(shy: true)
        web.restore(url: URL(string: "https://shown.test/")!, title: "Shown")
        let chromium = Tab(shy: true, engine: .chromium, factory: factory)
        chromium.restore(url: URL(string: "https://behind.test/")!, title: "Behind")
        browser.prepare(web)
        browser.prepare(chromium)
        browser.lay([web, chromium])
        browser.activeID = web.id
        BrowserWindows.shared.register(window, for: browser)
        guard let page = chromium.page as? ChromiumPage else { return nil }
        return (browser, chromium, page)
    }

    /// A registered window holding a Chromium tab and a WebKit tab on one
    /// private store, as a private window's tabs share one, both built.
    private func pair(_ window: NSWindow) -> (browser: Browser, chromium: Tab, web: Tab) {
        _ = NSApplication.shared
        let configuration = Web.configuration(shy: true)
        let chromium = Tab(shy: true, configuration: configuration, engine: .chromium, factory: factory)
        let web = Tab(shy: true, configuration: configuration)
        let browser = Browser(windowID: UUID())
        browser.prepare(chromium); browser.prepare(web)
        browser.lay([chromium, web])
        BrowserWindows.shared.register(window, for: browser)
        _ = chromium.page; _ = web.page
        return (browser, chromium, web)
    }

    private func letGo(_ browser: Browser, _ window: NSWindow) {
        for tab in browser.pagesHeld { (tab.builtPage as? ChromiumPage)?.retire(call: false, pictureInPicture: false); tab.close() }
        window.close()
        BrowserWindows.shared.forgetForTests(browser)
        browser.letGo()
        browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
    }

    private func sight(active: Bool, windows: Bool) -> () -> Void {
        let (wasActive, wasInSight) = (ChromiumDRMCookies.appActive, ChromiumDRMCookies.windowInSight)
        ChromiumDRMCookies.appActive = { active }
        ChromiumDRMCookies.windowInSight = { _ in windows }
        return { ChromiumDRMCookies.appActive = wasActive; ChromiumDRMCookies.windowInSight = wasInSight }
    }

    /// The step's next wait once it is worked out (a restart works it out in its own turn).
    private func due(_ bridge: ChromiumDRMCookies) async throws -> TimeInterval {
        for _ in 0..<200 where bridge.stepDue == nil { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(bridge.stepDue).timeIntervalSinceNow
    }

    @Test func onlyAChromiumPageOnScreenIsSeen() throws {
        let window = window()
        let made = try #require(browser(window))
        defer { letGo(made.browser, window) }
        let restore = sight(active: true, windows: true)
        defer { restore() }
        let store = made.chromium.pageStore
        func seen() -> Bool { ChromiumDRMCookies.seen(in: [made.browser], holds: { $0 === store }) }
        // Behind the WebKit tab on screen: held, not seen.
        #expect(!seen())
        // Switched to: on the stage, in the window.
        window.contentView?.addSubview(made.page)
        #expect(seen())
        made.page.isHidden = true
        #expect(!seen())
        made.page.isHidden = false
        // In a window nobody can see.
        ChromiumDRMCookies.windowInSight = { _ in false }
        #expect(!seen())
        ChromiumDRMCookies.windowInSight = { _ in true }
        // Taken off the stage again, then shown in a small window of its own.
        made.page.removeFromSuperview()
        #expect(!seen())
        let small = self.window()
        defer { small.close() }
        small.contentView?.addSubview(made.page)
        #expect(seen())
    }

    @Test func aFrameOpeningAHostOnBothEnginesCutsASlowWaitShort() async throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let frame = host("frame")
        bridge.touched(frame, mainFrame: false, by: .chromium, in: made.chromium.id)
        bridge.keepInStep()
        #expect(try await due(bridge) > 20)
        // A WebKit page puts the same site in a frame: now open on both.
        bridge.touched(frame, mainFrame: false, by: .webKit, in: made.web.id)
        #expect(try await due(bridge) <= 3.5)
    }

    @Test func aRedirectLandingOnAHostTheOtherEngineHasCutsASlowWaitShort() async throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let site = host("redirect")
        bridge.touched(site, mainFrame: false, by: .chromium, in: made.chromium.id)
        bridge.keepInStep()
        #expect(try await due(bridge) > 20)
        // A WebKit page's server redirect lands there: its page has no address yet.
        bridge.touched(site, by: .webKit, in: made.web.id)
        #expect(try await due(bridge) <= 3.5)
    }

    @Test func aChromiumTabSwitchedToCutsASlowWaitShort() async throws {
        let window = window()
        let made = try #require(browser(window))
        defer { letGo(made.browser, window) }
        let restore = sight(active: true, windows: true)
        defer { restore() }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        bridge.keepInStep()
        // Yab in front, its window in sight, the Chromium tab behind: slow.
        #expect(try await due(bridge) > 20)
        // The tab switched to: the stage puts its page in the window.
        window.contentView?.addSubview(made.page)
        #expect(try await due(bridge) <= 3.5)
    }
    @Test func framesCountOnlyWhileTheirPageIsOpenOnThatSite() throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let (browser, chromium, web) = pair(window)
        defer { letGo(browser, window) }
        let bridge = try ChromiumDRMCookies.of(chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let frame = host("frame"), site = try #require(frame.host())
        bridge.pageCommitted(host("chromium-page"), by: .chromium, in: chromium.id)
        bridge.touched(frame, mainFrame: false, by: .chromium, in: chromium.id)
        bridge.touched(frame, mainFrame: false, by: .webKit, in: web.id)
        // In a frame on each engine: shared, so quick, and every pass reads it.
        #expect(bridge.paceForTesting.wait == 3)
        #expect(bridge.paceForTesting.shared == [site])
        // The Chromium page goes to another site: its frames went with the document.
        bridge.pageCommitted(host("elsewhere"), by: .chromium, in: chromium.id)
        #expect(bridge.paceForTesting.wait > 20)
        #expect(bridge.paceForTesting.shared.isEmpty)
        // Back in a frame there, then the WebKit tab closed: no longer open on WebKit.
        bridge.touched(frame, mainFrame: false, by: .chromium, in: chromium.id)
        #expect(bridge.paceForTesting.wait == 3)
        web.close()
        #expect(bridge.paceForTesting.wait > 20)
        #expect(bridge.paceForTesting.shared.isEmpty)
    }

    @Test func aRequestOfYabsOwnCountsOnlyForTheNextWait() throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let tab = Tab(shy: true)
        let bridge = try ChromiumDRMCookies.of(tab)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile); tab.close() }
        let site = host("own")
        bridge.touched(site, mainFrame: false, by: .chromium)
        bridge.touched(site, mainFrame: false, by: .webKit)
        // No page holds either: nothing stays open on both.
        #expect(bridge.paceForTesting.wait > 20)
    }
    @Test func bothEnginesLoadingOneNewHostCutsASlowWaitShort() async throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        bridge.keepInStep()
        #expect(try await due(bridge) > 20)
        // Both first requests before either page has the address.
        let site = host("both")
        bridge.touched(site, by: .webKit, in: made.web.id)
        bridge.touched(site, by: .chromium, in: made.chromium.id)
        #expect(try await due(bridge) <= 3.5)
    }

    @Test func aChromiumPageArrivingOnAHostWebKitHasCutsASlowWaitShort() async throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let page = try #require(made.chromium.page as? ChromiumPage)
        let remote = "pace-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { ChromiumProcess.shared.detach(remote) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let site = host("arriving")
        bridge.touched(site, mainFrame: false, by: .webKit, in: made.web.id)
        bridge.keepInStep()
        #expect(try await due(bridge) > 20)
        // Its first request counted at a wait already over: the commit is what says so now.
        page.receive(YabCoreEvent(name: "page.committed", params: ["tab": .string(remote), "url": .string(site.absoluteString)]))
        #expect(try await due(bridge) <= 3.5)
    }
    /// A frame on each engine for one host, read as shared.
    private func sharedFrame(_ bridge: ChromiumDRMCookies, _ made: (browser: Browser, chromium: Tab, web: Tab)) throws -> (url: URL, host: String) {
        let frame = host("frame")
        bridge.touched(frame, mainFrame: false, by: .chromium, in: made.chromium.id)
        bridge.touched(frame, mainFrame: false, by: .webKit, in: made.web.id)
        let site = try #require(frame.host())
        #expect(bridge.paceForTesting.shared == [site])
        return (frame, site)
    }

    @Test func aNavigationThatNeverCommitsKeepsThePagesFrames() throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let frame = try sharedFrame(bridge, made)
        // A click that turns into a download: the document and its frames stay.
        bridge.touched(host("download"), by: .chromium, in: made.chromium.id)
        #expect(bridge.paceForTesting.shared == [frame.host])
        // Another site committed: they went with the old document.
        bridge.pageCommitted(host("elsewhere"), by: .chromium, in: made.chromium.id)
        #expect(bridge.paceForTesting.shared.isEmpty)
    }

    @Test func aTabChangingEngineLeavesItsFramesBehind() throws {
        let restore = sight(active: false, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        let site = host("site")
        bridge.pageCommitted(site, by: .webKit, in: made.web.id)
        _ = try sharedFrame(bridge, made)
        // The WebKit tab's site goes to Chromium in the same tab: its WebKit frames are no Chromium page's.
        bridge.touched(site, by: .chromium, in: made.web.id)
        bridge.pageCommitted(site, by: .chromium, in: made.web.id)
        #expect(bridge.paceForTesting.shared.isEmpty)
    }

    @Test func aSmallWindowComingIntoViewCutsASlowWaitShort() async throws {
        let restore = sight(active: true, windows: false)
        defer { restore() }
        let window = window()
        let made = pair(window)
        defer { letGo(made.browser, window) }
        let page = try #require(made.chromium.page as? ChromiumPage)
        let bridge = try ChromiumDRMCookies.of(made.chromium)
        defer { ChromiumDRMCookies.retirePrivate(bridge.profile) }
        // In a small window of its own, not a browser window, covered.
        let small = self.window()
        defer { small.close() }
        small.contentView?.addSubview(page)
        bridge.keepInStep()
        #expect(try await due(bridge) > 20)
        ChromiumDRMCookies.windowInSight = { _ in true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: small)
        #expect(try await due(bridge) <= 3.5)
    }
}

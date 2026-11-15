import Network
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Real browsing uses native WebKit against an in-process loopback fixture.
/// Nothing in these tests needs an external website or a running dev server.
@MainActor
final class LiveBrowserTests: XCTestCase {
    private var server: LoopbackPages!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var pools: [WebPool] = []
    private var ids: [Tab.ID] = []

    override func setUp() async throws {
        Motion.disabled = true
        SiteIcons.shared.removeAll()
        server = try LoopbackPages()
        try await server.start()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        for pool in pools { for id in ids { pool.forget(id) } }
        pools = []
        ids = []
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
        server?.stop()
        server = nil
        SiteIcons.shared.removeAll()
    }

    func testRefreshReloadsSamePageHistoryAndPublicOrPrivateStore() async throws {
        let pages = pool()
        window.overrideUserInterfaceStyle = .dark
        var publicView: WKWebView?
        for isPrivate in [false, true] {
            let tab = trackedTab(isPrivate ? "refresh.private" : "refresh.public", "/start", isPrivate: isPrivate)
            let view = pages.activate(tab)
            show(view)
            try await painted(pages, tab.id)
            let address = server.url("/refresh-short?q=a%2Bb#part")
            pages.load(tab.id, address)
            try await eventually { view.url == address && !view.isLoading }
            try await painted(pages, tab.id)
            let value = isPrivate ? "private" : "public"
            _ = try await view.evaluateJavaScript("document.cookie='refresh-token=\(value);path=/';localStorage.setItem('refresh-token','\(value)')")
            let store = view.configuration.websiteDataStore
            let before = try XCTUnwrap(pages.navigationState(for: tab.id))
            let refresh = try XCTUnwrap(view.scrollView.refreshControl)
            XCTAssertTrue(view.scrollView.alwaysBounceVertical, "a short page must remain pullable")
            XCTAssertEqual(refresh.traitCollection.userInterfaceStyle, .light)
            var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1
            XCTAssertTrue(refresh.tintColor.resolvedColor(with: refresh.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: nil))
            XCTAssertLessThan(max(red, max(green, blue)), 0.25, "the indicator must stay visible on WebKit's white canvas in Dark")
            XCTAssertEqual(view.scrollView.adjustedContentInset, view.obscuredContentInsets)
            let count = server.count(of: "/refresh-short")
            view.scrollView.setContentOffset(CGPoint(x: 0, y: -view.obscuredContentInsets.top), animated: false)
            refresh.beginRefreshing()
            refresh.sendActions(for: .valueChanged)
            try await eventually { self.server.count(of: "/refresh-short") == count + 1 && !view.isLoading && !refresh.isRefreshing }
            try await painted(pages, tab.id)
            XCTAssertTrue(pages.view(for: PageFixtures.liveTab(for: address, id: tab.id, isPrivate: isPrivate)) === view)
            XCTAssertEqual(pages.front, tab.id)
            XCTAssertEqual(view.url, address)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertEqual(store.isPersistent, false)
            let stored = try await view.evaluateJavaScript("localStorage.getItem('refresh-token')") as? String
            let cookie = try await view.evaluateJavaScript("document.cookie") as? String
            XCTAssertEqual(stored, value)
            XCTAssertTrue(cookie?.contains("refresh-token=\(value)") == true)
            let after = try XCTUnwrap(pages.navigationState(for: tab.id))
            XCTAssertEqual(after.entries.map(\.url), before.entries.map(\.url))
            XCTAssertEqual(after.index, before.index)
            XCTAssertEqual(view.backForwardList.backItem?.url, server.url("/start"))
            if isPrivate {
                let publicCookie = try await publicView!.evaluateJavaScript("document.cookie") as? String
                XCTAssertTrue(publicCookie?.contains("refresh-token=public") == true)
            } else { publicView = view }
        }
    }

    func testRefreshKeepsNativeInsetAndEndsOnCancellationFailureOrRelease() async throws {
        let pages = pool()
        let tab = trackedTab("refresh.slow", "/slow")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        let old = PageViewport(size: view.bounds.size, hardware: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                               chrome: .init(folded: false, hasNow: false, visible: true))
        pages.setViewport(old)
        let refresh = try XCTUnwrap(view.scrollView.refreshControl)
        server.holdSlowResponse()
        view.scrollView.setContentOffset(CGPoint(x: 0, y: -old.current.top), animated: false)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        view.scrollView.setContentOffset(CGPoint(x: 0, y: -old.current.top - 100), animated: false)
        try await eventually { view.isLoading && self.server.count(of: "/slow") == 2 }
        XCTAssertTrue(refresh.isRefreshing)
        try await eventually { view.scrollView.contentInset.top > old.current.top + 1 }
        let ownedTop = view.scrollView.contentInset.top - old.current.top
        let changed = PageViewport(size: view.bounds.size, hardware: UIEdgeInsets(top: 70, left: 0, bottom: 34, right: 0),
                                   chrome: .init(folded: true, hasNow: false, visible: true))
        pages.setViewport(changed)
        XCTAssertEqual(view.scrollView.contentInset.top, changed.current.top + ownedTop, accuracy: 0.5)
        XCTAssertEqual(view.obscuredContentInsets, changed.current)
        XCTAssertNotNil(pages.reload(tab.id))
        try await eventually { self.server.count(of: "/slow") == 3 && view.isLoading }
        _ = try await view.evaluateJavaScript("document.readyState")
        XCTAssertTrue(refresh.isRefreshing, "a manual reload cancelling the older pull must retain the newer control")
        view.stopLoading()
        try await eventually { !refresh.isRefreshing }
        server.releaseSlowResponse()
        server.failResponses()
        view.scrollView.setContentOffset(CGPoint(x: 0, y: -changed.current.top), animated: false)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        try await eventually { self.server.count(of: "/slow") >= 4 && !view.isLoading && !refresh.isRefreshing }
        XCTAssertFalse(pages.describe(tab.id).contains("error=none"), "the aborted responses must exercise the navigation failure path")
        server.allowResponses()
        view.scrollView.setContentOffset(CGPoint(x: 0, y: -changed.current.top), animated: false)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        try await eventually { self.server.count(of: "/slow") >= 5 && !view.isLoading && !refresh.isRefreshing }
        try await painted(pages, tab.id)
        XCTAssertEqual(view.scrollView.contentInset.top, changed.current.top, accuracy: 0.5)
        refresh.beginRefreshing()
        pages.forget(tab.id)
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertNil(view.scrollView.refreshControl)
    }

    func testAdoptedPageCanRefreshButBlankAndScrolledPagesDoNot() async throws {
        let pages = pool()
        let tab = trackedTab("refresh.adopted", "/refresh-short")
        let view = WKWebView(frame: window.bounds, configuration: pages.configurationForPage())
        show(view)
        view.load(URLRequest(url: server.url("/refresh-short")))
        try await eventually { view.url == self.server.url("/refresh-short") && !view.isLoading }
        pages.adopt(view, for: tab)
        pages.activate(tab)
        let refresh = try XCTUnwrap(view.scrollView.refreshControl)
        XCTAssertTrue(view.scrollView.alwaysBounceVertical)
        let count = server.count(of: "/refresh-short")
        view.scrollView.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertEqual(server.count(of: "/refresh-short"), count)
        view.scrollView.setContentOffset(CGPoint(x: 0, y: -view.obscuredContentInsets.top), animated: false)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        try await eventually { self.server.count(of: "/refresh-short") == count + 1 && !view.isLoading && !refresh.isRefreshing }
        let blank = PageFixtures.liveTab(for: URL(string: "about:blank")!, id: "refresh.blank")
        ids.append(blank.id)
        let blankView = pages.activate(blank)
        show(blankView)
        try await eventually { blankView.url?.absoluteString == "about:blank" && !blankView.isLoading }
        let blankRefresh = try XCTUnwrap(blankView.scrollView.refreshControl)
        blankRefresh.beginRefreshing()
        blankRefresh.sendActions(for: .valueChanged)
        XCTAssertFalse(blankRefresh.isRefreshing)
        XCTAssertNil(pages.reload(blank.id))
    }

    func testCanonicalAddressKeepsSchemeEscapesPortAndFragment() throws {
        let url = server.url("/Mixed%2FPath?q=tea%26milk#part%202")
        let tab = PageFixtures.tab(for: url, fixturesEnabled: false)
        XCTAssertEqual(tab.url, url.absoluteString)
        XCTAssertEqual(tab.navigationURL, url)
        XCTAssertEqual(tab.address, "127.0.0.1:\(server.port)/Mixed%2FPath?q=tea%26milk#part%202")
        XCTAssertNil(tab.page)
        XCTAssertEqual(tab.port, String(server.port))
        let app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false)
        XCTAssertEqual(app.link(of: tab), url)
        let known = PageFixtures.tab(for: URL(string: "https://figma.com/design/xK29fLm8/Onboarding-v3")!,
                                     in: app.world, fixturesEnabled: false)
        XCTAssertNil(known.page, "a familiar host must not borrow a demo page")
    }

    func testRealSearchEncodesOneQueryAndKeepsPrivacy() {
        let words = "tea & milk + café"
        let tab = PageFixtures.search(words, isPrivate: true, fixturesEnabled: false)
        let parts = URLComponents(url: tab.navigationURL!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "www.google.com")
        XCTAssertEqual(parts.path, "/search")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "q", value: words)])
        XCTAssertFalse(parts.percentEncodedQuery!.contains("+"), "a literal plus must survive form query decoding")
        XCTAssertTrue(parts.percentEncodedQuery!.contains("%2B"))
        XCTAssertTrue(tab.isPrivate)
        XCTAssertNil(tab.page)
    }

    func testFixtureAndRealPoolsAllowOnlyTheirOwnPages() {
        let fixture = WebPool(dataStore: .nonPersistent())
        let real = pool()
        let tab = PageFixtures.liveTab(for: server.url("/start"))
        XCTAssertEqual(real.loadingURL(for: tab), tab.navigationURL)
        XCTAssertNotEqual(fixture.loadingURL(for: tab), tab.navigationURL)
        XCTAssertTrue(real.allows(server.url("/start")))
        XCTAssertFalse(fixture.allows(server.url("/start")))
        XCTAssertFalse(real.allows(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(real.allows(URL(fileURLWithPath: "/tmp/page.html")))
    }

    func testRealViewportFitsFixedPageEdgesAndPreservesDocumentScroll() async throws {
        let pages = pool()
        let tab = trackedTab("viewport", "/viewport-cover")
        let view = pages.activate(tab)
        let host = window.rootViewController!.view!
        let container = PageContainer(frame: host.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.pool = pages
        container.fixturesEnabled = false
        host.addSubview(container)
        container.show(view)
        window.layoutIfNeeded()
        try await painted(pages, tab.id)
        let top = view.obscuredContentInsets.top
        XCTAssertGreaterThan(top, 0, "the real window's hardware safe area must reach WebKit")
        XCTAssertEqual(view.scrollView.adjustedContentInset, view.obscuredContentInsets,
                       "UIKit must not add the same hardware edges twice")
        try await assertViewport(view, phase: "unfolded")
        _ = try await view.evaluateJavaScript("scrollTo(0, 300)")
        try await eventually { view.scrollView.contentOffset.y + top > 290 }
        var saved = try XCTUnwrap(pages.navigationState(for: tab.id))
        XCTAssertEqual(saved.entries.last?.scrollY ?? -1, 300, accuracy: 2)
        let unfoldedBottom = view.obscuredContentInsets.bottom
        container.chrome.folded = true
        try await assertViewport(view, phase: "folded")
        XCTAssertLessThan(view.obscuredContentInsets.bottom, unfoldedBottom)
        let neighbor = trackedTab("viewport-neighbor", "/viewport-normal")
        let neighborView = pages.warm(neighbor)
        XCTAssertEqual(neighborView.obscuredContentInsets, view.obscuredContentInsets,
                       "a paging neighbor must already fit the current chrome before activation")
        container.chrome.folded = false
        try await assertViewport(view, phase: "unfolded-again")
        XCTAssertEqual(view.obscuredContentInsets.bottom, unfoldedBottom)
        _ = try await view.evaluateJavaScript("scrollTo(0, 0)")
        try await eventually { abs(view.scrollView.contentOffset.y + top) < 2 }
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.last?.scrollY ?? -1, 0, accuracy: 2)
        // A launch without WebKit's native history uses portable document scroll.
        saved.interactionData = nil
        let restored = pool()
        restored.navigationForTab = { id in id == tab.id ? saved : nil }
        let restoredView = restored.activate(tab)
        restored.checkpoint()
        XCTAssertEqual(restored.navigationState(for: tab.id)?.entries.last?.scrollY ?? -1, 300, accuracy: 2,
                       "a checkpoint before paint must preserve the pending restoration")
        container.pool = restored
        container.show(restoredView)
        try await painted(restored, tab.id)
        let restoredScroll = try await restoredView.evaluateJavaScript("scrollY")
        let restoredY = try XCTUnwrap(restoredScroll as? Double)
        XCTAssertEqual(restoredY, 300, accuracy: 2, "restoring must not add the status bar to document scroll")
        XCTAssertEqual(restoredView.scrollView.contentOffset.y + restoredView.obscuredContentInsets.top, 300, accuracy: 2)
        try await assertViewport(restoredView, phase: "restored-after-layout")
        let afterLayout = try await restoredView.evaluateJavaScript("scrollY")
        XCTAssertEqual(try XCTUnwrap(afterLayout as? Double), 300, accuracy: 2,
                       "the next viewport layout must keep restored document scroll")
    }

    func testNormalViewportAndFixtureKeepTheirOwnInsetBehavior() async throws {
        let pages = pool()
        let tab = trackedTab("viewport-normal", "/viewport-normal")
        let view = pages.activate(tab)
        let host = window.rootViewController!.view!
        let container = PageContainer(frame: host.bounds)
        container.pool = pages
        container.fixturesEnabled = false
        host.addSubview(container)
        container.show(view)
        window.layoutIfNeeded()
        try await painted(pages, tab.id)
        try await assertViewport(view, phase: "normal-viewport")
        let fixture = WebPool(dataStore: .nonPersistent())
        pools.append(fixture)
        let world = try World.load(named: "mira")
        let fixtureTab = try XCTUnwrap(world.spaces.first?.today.first)
        ids.append(fixtureTab.id)
        let fixtureView = fixture.activate(fixtureTab)
        container.pool = fixture
        container.fixturesEnabled = true
        container.show(fixtureView)
        window.layoutIfNeeded()
        XCTAssertEqual(fixtureView.obscuredContentInsets, .zero)
        XCTAssertEqual(fixtureView.scrollView.contentInset, .zero)
        XCTAssertEqual(fixtureView.minimumViewportInset, .zero)
        XCTAssertEqual(fixtureView.maximumViewportInset, .zero)
    }

    private func assertViewport(_ view: WKWebView, phase: String) async throws {
        // Wait for WebKit's next layout, not only the native property write.
        _ = try await view.callAsyncJavaScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                                               arguments: [:], in: nil, in: .page)
        let expected = view.bounds.height - view.obscuredContentInsets.top - view.obscuredContentInsets.bottom
        var values: [String: Double] = [:]
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let raw = try await view.evaluateJavaScript("measureViewport()")
            values = try XCTUnwrap(raw as? [String: Double])
            if abs((values["visualHeight"] ?? -1) - Double(expected)) < 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        let note = XCTAttachment(string: "native bounds=\(view.bounds), obscured=\(view.obscuredContentInsets), adjusted=\(view.scrollView.adjustedContentInset), CSS=\(values)")
        note.name = "viewport-\(phase)"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertEqual(try XCTUnwrap(values["visualHeight"]), Double(expected), accuracy: 2,
                       "the visible viewport must exclude each native edge exactly once")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["envTop"]), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["envBottom"]), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["svh"]), try XCTUnwrap(values["dvh"]) + 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["dvh"]), try XCTUnwrap(values["lvh"]) + 2)
    }

    func testNativeLoadsUpdateTitleAndBackForwardWithoutDuplicateEntries() async throws {
        let pages = pool()
        let tab = trackedTab("history", "/start")
        let view = pages.activate(tab)
        show(view)
        var metadata: [(URL, String)] = []
        pages.onMetadata = { _, url, title in metadata.append((url, title)) }
        try await painted(pages, tab.id)
        XCTAssertEqual(view.url, server.url("/start"))
        XCTAssertEqual(view.title, "First page")
        pages.load(tab.id, server.url("/next"))
        try await painted(pages, tab.id)
        XCTAssertEqual(view.title, "Second page")
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url),
                       [server.url("/start").absoluteString, server.url("/next").absoluteString])
        XCTAssertTrue(pages.goBack(tab.id))
        try await painted(pages, tab.id)
        XCTAssertEqual(view.url, server.url("/start"))
        XCTAssertEqual(view.title, "First page")
        XCTAssertTrue(pages.goForward(tab.id))
        try await painted(pages, tab.id)
        XCTAssertEqual(view.url, server.url("/next"))
        XCTAssertEqual(metadata.last?.0, server.url("/next"))
        XCTAssertEqual(metadata.last?.1, "Second page")
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.count, 2)
    }

    func testSPAReplacementAndPushKeepNativeBackForwardSemantics() async throws {
        let pages = pool()
        let tab = trackedTab("spa", "/start")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        defer { recordNavigation("spa-final", pages: pages, id: tab.id, view: view) }
        let renamed = server.url("/renamed?x=1#piece")
        let replaced = try await view.evaluateJavaScript("history.replaceState({}, '', '/renamed?x=1#piece'); JSON.stringify({href:location.href,length:history.length})")
        recordNavigation("spa-replace", pages: pages, id: tab.id, view: view, javascript: replaced)
        try await eventually { pages.navigationState(for: tab.id)?.entries.last?.url == renamed.absoluteString }
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [renamed.absoluteString])
        XCTAssertFalse(view.canGoBack)
        XCTAssertFalse(pages.goBack(tab.id), "replaceState must not fabricate a previous document")
        let pushed = server.url("/pushed")
        let pushedState = try await view.evaluateJavaScript("history.pushState({}, '', '/pushed'); JSON.stringify({href:location.href,length:history.length})")
        recordNavigation("spa-push", pages: pages, id: tab.id, view: view, javascript: pushedState)
        try await eventually { pages.navigationState(for: tab.id)?.entries.count == 2 }
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [renamed.absoluteString, pushed.absoluteString])
        XCTAssertTrue(pages.goBack(tab.id))
        recordNavigation("spa-back", pages: pages, id: tab.id, view: view)
        try await eventually { view.url == renamed && pages.navigationState(for: tab.id)?.index == 0 }
        try await painted(pages, tab.id)
        XCTAssertTrue(pages.goForward(tab.id))
        recordNavigation("spa-forward", pages: pages, id: tab.id, view: view)
        try await eventually { view.url == pushed && pages.navigationState(for: tab.id)?.index == 1 }
        try await painted(pages, tab.id)
        XCTAssertEqual(server.count(of: "/renamed"), 0, "Back stays in the native document")
        XCTAssertEqual(server.count(of: "/pushed"), 0)
    }

    func testCompletedDocumentTitleChangesPersistWithoutAddingVisits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTitle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        pools.append(app.pages)
        let tab = trackedTab("live-title", "/next?q=a%2Bb&order=2%2F3#part")
        let address = try XCTUnwrap(tab.url)
        app.browser.open(tab)
        let view = app.pages.activate(try XCTUnwrap(app.browser.tab(tab.id)))
        show(view)
        try await painted(app.pages, tab.id)
        try await eventually {
            app.browser.tab(tab.id)?.title == "Second page" &&
                profile.navigation[tab.id]?.entries.last?.title == "Second page" &&
                profile.recent.first(where: { $0.url == address })?.title == "Second page"
        }
        let visit = try XCTUnwrap(profile.recent.first { $0.url == address })
        _ = try await view.evaluateJavaScript("document.title = 'Changed after finish'")
        try await eventually {
            app.browser.tab(tab.id)?.title == "Changed after finish" &&
                profile.navigation[tab.id]?.entries.last?.title == "Changed after finish" &&
                profile.recent.first(where: { $0.url == address })?.title == "Changed after finish"
        }
        XCTAssertEqual(view.url, tab.navigationURL)
        XCTAssertEqual(profile.navigation[tab.id]?.entries.map(\.url), [address])
        XCTAssertEqual(profile.recent.first(where: { $0.url == address })?.count, visit.count)
        XCTAssertEqual(profile.recent.first(where: { $0.url == address })?.visitedAt, visit.visitedAt)
        await app.flushProfile()
        let saved = BrowserProfile(folder: directory)
        let savedTab = try XCTUnwrap(BrowserStore(world: saved.world, fixturesEnabled: false).tab(tab.id))
        XCTAssertEqual(savedTab.url, address)
        XCTAssertEqual(savedTab.title, "Changed after finish")
        XCTAssertEqual(saved.navigation[tab.id]?.entries.last?.title, "Changed after finish")
        XCTAssertEqual(saved.recent.first(where: { $0.url == address })?.title, "Changed after finish")
        XCTAssertEqual(saved.recent.first(where: { $0.url == address })?.count, visit.count)
    }

    func testCommittedSlowLinkSurvivesEvictionAndProfileFlushBeforeFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SlowCommit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        pools.append(app.pages)
        let tab = trackedTab("slow-source", "/start")
        app.browser.open(tab)
        app.browser.keep(tab.id)
        let view = app.pages.activate(try XCTUnwrap(app.browser.tab(tab.id)))
        show(view)
        try await painted(app.pages, tab.id)
        let before = try XCTUnwrap(app.browser.tab(tab.id))
        server.holdSlowResponse()
        _ = try await view.evaluateJavaScript("document.getElementById('slow').click()")
        let slowURL = server.url("/slow")
        try await eventually { profile.navigation[tab.id]?.entries.last?.url == slowURL.absoluteString }
        XCTAssertTrue(view.isLoading, "the response must still be unfinished at the checkpoint")
        XCTAssertEqual(app.browser.tab(tab.id)?.navigationURL, slowURL)
        XCTAssertEqual(app.browser.tab(tab.id)?.title, before.title)
        XCTAssertEqual(app.browser.tab(tab.id)?.place, before.place)
        XCTAssertEqual(app.browser.tab(tab.id)?.isPrivate, before.isPrivate)
        XCTAssertFalse(profile.recent.contains { $0.url == slowURL.absoluteString }, "Commit does not count a completed visit")
        for index in 0..<WebPool.liveLimit {
            let neighbor = trackedTab("slow-neighbor-\(index)", "/start?n=\(index)")
            app.browser.open(neighbor)
            let nextView = app.pages.activate(try XCTUnwrap(app.browser.tab(neighbor.id)))
            show(nextView)
            try await painted(app.pages, neighbor.id)
        }
        XCTAssertFalse(app.pages.isLive(tab.id))
        await app.flushProfile()
        let saved = BrowserProfile(folder: directory)
        let savedTab = try XCTUnwrap(BrowserStore(world: saved.world, fixturesEnabled: false).tab(tab.id))
        XCTAssertEqual(savedTab.navigationURL, slowURL)
        var savedState = try XCTUnwrap(saved.navigation[tab.id])
        XCTAssertEqual(savedState.entries.map(\.url), [server.url("/start").absoluteString, slowURL.absoluteString])
        savedState.interactionData = nil
        server.releaseSlowResponse()
        let restored = pool()
        restored.navigationForTab = { id in id == tab.id ? savedState : nil }
        let restoredView = restored.activate(savedTab)
        show(restoredView)
        try await painted(restored, tab.id)
        XCTAssertEqual(restoredView.url, slowURL)
        XCTAssertTrue(restored.goBack(tab.id))
        try await painted(restored, tab.id)
        XCTAssertEqual(restoredView.url, server.url("/start"))
    }

    func testFirstLoadRedirectHasNoPhantomBackPage() async throws {
        let pages = pool()
        let tab = trackedTab("redirect", "/redirect")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        XCTAssertEqual(view.url, server.url("/next"))
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), [server.url("/next").absoluteString])
        XCTAssertFalse(pages.goBack(tab.id))
    }

    func testSameIDSyncNavigationLoadsOnceAndMetadataEchoDoesNotReload() async throws {
        let pages = pool()
        var tab = trackedTab("sync", "/start")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        tab.url = server.url("/next").absoluteString
        XCTAssertTrue(pages.view(for: tab) === view)
        XCTAssertTrue(pages.view(for: tab) === view)
        try await painted(pages, tab.id)
        XCTAssertEqual(view.url, server.url("/next"))
        XCTAssertTrue(pages.view(for: tab) === view)
        XCTAssertEqual(server.count(of: "/next"), 1)
        XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.count, 2)
    }

    func testEvictionRestoresNativeFormAndSavedHistoryHasURLScrollFallback() async throws {
        let pages = pool()
        var tab = trackedTab("evicted", "/start")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        pages.load(tab.id, server.url("/next"))
        try await painted(pages, tab.id)
        _ = try await view.evaluateJavaScript("document.querySelector('input').value='kept words'; scrollTo(0,300)")
        tab.url = server.url("/next").absoluteString
        for index in 0..<WebPool.liveLimit {
            let neighbor = trackedTab("neighbor-\(index)", "/start?n=\(index)")
            let neighborView = pages.activate(neighbor)
            show(neighborView)
            try await painted(pages, neighbor.id)
        }
        XCTAssertFalse(pages.isLive(tab.id))
        let restored = pages.activate(tab)
        show(restored)
        try await painted(pages, tab.id)
        XCTAssertFalse(restored === view)
        XCTAssertEqual(restored.url, server.url("/next"))
        let formValue = try await restored.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(formValue, "kept words")
        XCTAssertTrue(pages.goBack(tab.id))
        try await painted(pages, tab.id)
        XCTAssertEqual(restored.url, server.url("/start"))
        XCTAssertTrue(pages.goForward(tab.id))
        try await painted(pages, tab.id)
        var saved = try XCTUnwrap(pages.navigationState(for: tab.id))
        saved.interactionData = nil
        saved.entries[saved.index].scrollY = 250
        let nextLaunch = pool()
        nextLaunch.navigationForTab = { id in id == tab.id ? saved : nil }
        let fallback = nextLaunch.activate(tab)
        show(fallback)
        try await painted(nextLaunch, tab.id)
        XCTAssertEqual(fallback.url, server.url("/next"))
        XCTAssertEqual(fallback.scrollView.contentOffset.y, 250, accuracy: 2)
        XCTAssertTrue(nextLaunch.goBack(tab.id))
        try await painted(nextLaunch, tab.id)
        XCTAssertEqual(fallback.url, server.url("/start"))
        XCTAssertTrue(nextLaunch.goForward(tab.id))
        try await painted(nextLaunch, tab.id)
        XCTAssertEqual(fallback.url, server.url("/next"))
        XCTAssertEqual(nextLaunch.navigationState(for: tab.id)?.entries.count, 2)
    }

    func testTargetBlankKeepsTheOpenersPrivateStore() async throws {
        let pages = pool()
        let tab = trackedTab("private-source", "/start", isPrivate: true)
        let source = pages.activate(tab)
        show(source)
        try await painted(pages, tab.id)
        let target = trackedTab("private-popup", "/next", isPrivate: true)
        var openedPrivately: Bool?
        pages.onOpenWindow = { url, isPrivate in
            XCTAssertEqual(url, self.server.url("/next"))
            openedPrivately = isPrivate
            return target
        }
        source.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await source.evaluateJavaScript("document.querySelector('a[target=_blank]').click()")
        try await eventually { pages.isLive(target.id) }
        let popup = pages.view(for: target)
        show(popup)
        try await painted(pages, target.id)
        XCTAssertEqual(openedPrivately, true)
        XCTAssertEqual(popup.url, server.url("/next"))
        XCTAssertFalse(popup.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(popup.configuration.websiteDataStore === source.configuration.websiteDataStore)
        XCTAssertNil(SiteIcons.shared.image(for: "127.0.0.1"), "private pages never enter the icon cache")
    }

    func testReaderKeepsTheSamePageStoreFormsAndHistoryAndBackLeavesItFirst() async throws {
        let pages = pool()
        for isPrivate in [false, true] {
            let tab = trackedTab(isPrivate ? "reader.private" : "reader.public", "/start", isPrivate: isPrivate)
            let view = pages.activate(tab)
            show(view)
            try await painted(pages, tab.id)
            let address = server.url("/reader-article?q=a%2Bb#article")
            pages.load(tab.id, address)
            try await painted(pages, tab.id)
            try await eventually { pages.state(for: tab.id).readerAvailable }
            _ = try await view.evaluateJavaScript("document.querySelector('input').value='kept words';localStorage.setItem('reader','kept');document.cookie='reader=kept;path=/';window.scrollTo({top:340,behavior:'instant'})")
            let originalY = try await runPageScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return window.scrollY;", in: view) as? Double
            XCTAssertEqual(originalY ?? -1, 340, accuracy: 2, "the fixture begins away from its URL fragment")
            let before = try XCTUnwrap(pages.navigationState(for: tab.id))
            let store = view.configuration.websiteDataStore
            let parent = view.superview
            let requests = server.count(of: "/reader-article")
            let resources = server.count(of: "/reader-resource")
            let entered = await pages.setReader(enabled: true, for: tab.id)
            XCTAssertTrue(entered)
            let shown = try await runPageScript("return window.__yabPhoneReader.html();", in: view, world: PageReader.world) as? String ?? ""
            XCTAssertTrue(shown.contains("Read the <a href=\"\(server.url("/inline").absoluteString)\">linked words</a> in place"),
                          "a link in a sentence keeps its words and its same-site address (#706)")
            XCTAssertTrue(shown.contains("<a>outside words</a> too"), "another site's link keeps its words, not its address")
            XCTAssertFalse(shown.contains("Teaser card"), "a link holding blocks is still left out")
            XCTAssertTrue(pages.state(for: tab.id).readerEnabled)
            let enteredAgain = await pages.setReader(enabled: true, for: tab.id)
            XCTAssertTrue(enteredAgain, "repeated enter preserves the source scroll")
            XCTAssertTrue(pages.state(for: tab.id).canGoBack, "Back first leaves the reading view")
            XCTAssertEqual(pages.front, tab.id)
            XCTAssertEqual(view.url, address)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertTrue(view.superview === parent)
            let bodyHidden = try await view.evaluateJavaScript("getComputedStyle(document.body).display==='none'") as? Bool
            let pageHasController = try await view.evaluateJavaScript("typeof window.__yabPhoneReader!=='undefined'") as? Bool
            XCTAssertEqual(bodyHidden, true)
            XCTAssertEqual(pageHasController, false, "a website cannot invoke the isolated Reader controller")
            _ = try await view.evaluateJavaScript("window.scrollTo({top:600,behavior:'instant'})")
            pages.checkpoint()
            let reading = try XCTUnwrap(pages.navigationState(for: tab.id))
            XCTAssertEqual(reading.entries.map(\.url), before.entries.map(\.url))
            XCTAssertEqual(reading.index, before.index)
            XCTAssertEqual(reading.entries[reading.index].scrollY, before.entries[before.index].scrollY, accuracy: 2)
            XCTAssertNil(reading.interactionData, "a Reader scroll is not persisted as the source page's interaction")
            XCTAssertEqual(server.count(of: "/reader-article"), requests)
            XCTAssertEqual(server.count(of: "/reader-resource"), resources, "Reader creates no script, image or media requests")
            let leftReader = await pages.back(tab.id)
            XCTAssertTrue(leftReader)
            XCTAssertFalse(pages.state(for: tab.id).readerEnabled)
            XCTAssertEqual(view.url, address)
            let restored = try await runPageScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return {y:scrollY,value:document.querySelector('input').value,style:document.body.getAttribute('style'),storage:localStorage.getItem('reader'),cookie:document.cookie};", in: view) as? [String: Any]
            XCTAssertEqual(restored?["value"] as? String, "kept words")
            XCTAssertEqual(restored?["style"] as? String, "margin:0;min-height:3000px;background:#fff")
            XCTAssertEqual(restored?["storage"] as? String, "kept")
            XCTAssertTrue((restored?["cookie"] as? String)?.contains("reader=kept") == true)
            XCTAssertEqual(restored?["y"] as? Double ?? -1, originalY ?? -2, accuracy: 2)
            let sourceAction = try await view.evaluateJavaScript("document.getElementById('reader-action').click();window.readerActions") as? Int
            XCTAssertEqual(sourceAction, 1, "the original page's event listeners and forms remain alive")
            let readBeforeReload = await pages.setReader(enabled: true, for: tab.id)
            XCTAssertTrue(readBeforeReload)
            let reloaded = await pages.reloadSelected(tab.id)
            XCTAssertTrue(reloaded)
            let immediateReload = try XCTUnwrap(pages.navigationState(for: tab.id))
            XCTAssertEqual(immediateReload.entries[immediateReload.index].scrollY, originalY ?? -1, accuracy: 2,
                "Reader reload checkpoints the original source position before paint")
            try await painted(pages, tab.id)
            try await eventually { pages.state(for: tab.id).readerAvailable }
            let afterReloadY = try await runPageScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return scrollY;", in: view) as? Double
            XCTAssertEqual(afterReloadY ?? -1, originalY ?? -2, accuracy: 2,
                "Reader reload preserves the source position instead of jumping to #article")
            XCTAssertFalse(pages.state(for: tab.id).readerEnabled)
            XCTAssertEqual(server.count(of: "/reader-article"), requests + 1)
            XCTAssertEqual(view.url, address)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertEqual(pages.navigationState(for: tab.id)?.entries.map(\.url), before.entries.map(\.url))
            let sourceAfterReload = try await view.evaluateJavaScript("getComputedStyle(document.body).display!=='none'") as? Bool
            XCTAssertEqual(sourceAfterReload, true)
            let wentBack = await pages.back(tab.id)
            XCTAssertTrue(wentBack)
            try await painted(pages, tab.id)
            XCTAssertEqual(view.url, server.url("/start"))
            XCTAssertFalse(pages.state(for: tab.id).readerAvailable)
        }
    }

    func testReaderRejectsUnsupportedAndStaleTargetsAndAWebsiteCannotSpoofAvailability() async throws {
        let pages = pool()
        let article = trackedTab("reader.source", "/reader-article")
        let view = pages.activate(article)
        show(view)
        try await painted(pages, article.id)
        try await eventually { pages.state(for: article.id).readerAvailable }
        let other = trackedTab("reader.other", "/start")
        let second = pages.activate(other)
        show(second)
        try await painted(pages, other.id)
        let staleResult = await pages.setReader(enabled: true, for: article.id)
        XCTAssertFalse(staleResult, "a stale page menu cannot change a background tab")
        XCTAssertFalse(pages.state(for: article.id).readerEnabled)
        _ = try await second.evaluateJavaScript("window.__yabPhoneReader={readable:()=>true,enter:()=>true,on:()=>true}")
        let unsupportedResult = await pages.setReader(enabled: true, for: other.id)
        XCTAssertFalse(unsupportedResult)
        XCTAssertFalse(pages.state(for: other.id).readerEnabled)
        XCTAssertFalse(pages.state(for: other.id).readerAvailable)
        XCTAssertEqual(second.url, server.url("/start"))
        let bodyVisible = try await second.evaluateJavaScript("getComputedStyle(document.body).display!=='none'") as? Bool
        XCTAssertEqual(bodyVisible, true)
        XCTAssertEqual(pages.front, other.id)
        pages.load(other.id, server.url("/reader-hidden"))
        try await painted(pages, other.id)
        let hiddenProbe = try await runPageScript(PageReader.probe, in: second, world: PageReader.world) as? [String: Any]
        XCTAssertEqual(hiddenProbe?["available"] as? Bool, false, "CSS-hidden prose must neither offer Reader nor be exposed")
        let hiddenResult = await pages.setReader(enabled: true, for: other.id)
        XCTAssertFalse(hiddenResult)
        XCTAssertFalse(pages.state(for: other.id).readerEnabled)
    }

    func testPageChromeTracksRealLoadingStopAndPortableForward() async throws {
        let pages = pool()
        let tab = trackedTab("chrome.loading", "/start")
        let view = pages.activate(tab)
        show(view)
        try await painted(pages, tab.id)
        pages.load(tab.id, server.url("/next"))
        try await painted(pages, tab.id)
        XCTAssertTrue(pages.state(for: tab.id).canGoBack)
        XCTAssertTrue(pages.goBack(tab.id))
        try await painted(pages, tab.id)
        XCTAssertTrue(pages.state(for: tab.id).canGoForward)
        XCTAssertTrue(pages.goForward(tab.id))
        try await painted(pages, tab.id)
        server.holdSlowResponse()
        pages.load(tab.id, server.url("/slow"))
        try await eventually { pages.state(for: tab.id).isLoading && pages.state(for: tab.id).progress > 0 }
        XCTAssertFalse(pages.state(for: tab.id).readerAvailable)
        let another = trackedTab("chrome.other", "/start")
        let second = pages.activate(another)
        show(second)
        try await painted(pages, another.id)
        pages.stop(tab.id)
        XCTAssertTrue(view.isLoading, "a stale control cannot stop a page no longer selected")
        _ = pages.activate(PageFixtures.liveTab(for: server.url("/slow"), id: tab.id))
        show(view)
        pages.stop(tab.id)
        try await eventually { !pages.state(for: tab.id).isLoading }
        XCTAssertFalse(view.scrollView.refreshControl?.isRefreshing == true)
        XCTAssertEqual(pages.front, tab.id)
        server.releaseSlowResponse()
        pages.forget(tab.id)
        XCTAssertEqual(pages.state(for: tab.id), .idle)
    }

    private func runPageScript(_ script: String, in view: WKWebView, world: WKContentWorld? = nil) async throws -> Any {
        let contentWorld = world ?? .page
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func pool() -> WebPool {
        let pages = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pools.append(pages)
        return pages
    }

    private func trackedTab(_ id: Tab.ID, _ path: String, isPrivate: Bool = false) -> Tab {
        ids.append(id)
        return PageFixtures.liveTab(for: server.url(path), id: id, isPrivate: isPrivate)
    }

    private func show(_ view: WKWebView) {
        let host = window.rootViewController!.view!
        for other in host.subviews { other.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        window.layoutIfNeeded()
    }

    private func painted(_ pool: WebPool, _ id: Tab.ID) async throws {
        await pool.waitUntilPainted(id, timeout: .seconds(15))
        guard pool.painted.contains(id) else {
            XCTFail("page did not paint: \(pool.describe(id))")
            throw NSError(domain: "LiveBrowserTests", code: 1)
        }
    }

    private func recordNavigation(_ phase: String, pages: WebPool, id: Tab.ID, view: WKWebView, javascript: Any? = nil) {
        let state = pages.navigationState(for: id)
        let entries = state?.entries.enumerated().map { "\($0.offset): \($0.element.url)" }.joined(separator: "\n") ?? "nil"
        let note = """
        JavaScript: \(javascript.map { String(describing: $0) } ?? "not sampled")
        Native URL: \(view.url?.absoluteString ?? "nil")
        Loading: \(view.isLoading)
        Native current: \(view.backForwardList.currentItem?.url.absoluteString ?? "nil")
        Native back: \(view.backForwardList.backList.map { $0.url.absoluteString })
        Native forward: \(view.backForwardList.forwardList.map { $0.url.absoluteString })
        Portable index: \(state.map { String($0.index) } ?? "nil")
        Portable entries:
        \(entries)
        """
        let attachment = XCTAttachment(string: note)
        attachment.name = phase
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(10)
        while !condition(), Date() < until { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else {
            XCTFail("WebKit did not open the target tab", file: file, line: line)
            throw NSError(domain: "LiveBrowserTests", code: 2)
        }
    }
}

/// Binds only to loopback and exists for one native test's lifetime.
/// Mutable state stays on queue; awaiting start publishes the port once.
private final class LoopbackPages: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yab.tests.pages")
    private let listener: NWListener
    private var counts: [String: Int] = [:]
    private var failsResponses = false
    private var holdsSlow = false
    private var held: [(connection: NWConnection, remainder: Data)] = []
    private var startWaiter: CheckedContinuation<Void, Error>?
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Initialized before the listener starts, then used only on queue.
            startWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let waiter = self.startWaiter else { return }
                switch state {
                case .ready:
                    self.startWaiter = nil
                    self.port = self.listener.port!.rawValue
                    waiter.resume()
                case let .failed(error):
                    self.startWaiter = nil
                    waiter.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let waiter = self.startWaiter else { return }
                self.startWaiter = nil
                self.listener.cancel()
                waiter.resume(throwing: NSError(domain: "LiveBrowserTests.Listener", code: 1))
            }
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { held.forEach { $0.connection.cancel() }; held = [] }
    }
    func failResponses() { queue.sync { failsResponses = true } }
    func allowResponses() { queue.sync { failsResponses = false } }
    func holdSlowResponse() { queue.sync { holdsSlow = true } }
    func releaseSlowResponse() {
        queue.sync {
            holdsSlow = false
            for response in held {
                response.connection.send(content: response.remainder, completion: .contentProcessed { _ in response.connection.cancel() })
            }
            held = []
        }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func count(of path: String) -> Int { queue.sync { counts[path, default: 0] } }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = data
            if let chunk { request.append(chunk) }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.components(separatedBy: " ").dropFirst().first ?? "/start"
                let route = path.components(separatedBy: "?").first ?? path
                self.counts[route, default: 0] += 1
                if self.failsResponses { connection.cancel(); return }
                let response: String
                if route == "/redirect" {
                    response = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let title = route == "/next" ? "Second page" : route == "/slow" ? "Slow page" : "First page"
                    var body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
                    <title>\(title)</title><link rel="icon" href="data:,">
                    <body style="margin:0;min-height:2400px;background:#fff">
                    <h1>\(title)</h1><input value="fresh"><a href="/next" target="_blank">Open second page</a>
                    <a id="slow" href="/slow">Load slow page</a></body>
                    """
                    if route == "/reader-article" {
                        let paragraph = String(repeating: "A long article carries useful prose that can be read locally while the original page keeps its own forms and listeners. ", count: 4)
                        body = "<!doctype html><meta name=viewport content=width=device-width><title>Reader article</title><link rel=icon href=data:,><body style='margin:0;min-height:3000px;background:#fff'><article id=article><h1>Reader article</h1><p>Read the <a href='/inline'>linked words</a> in place and <a href='https://elsewhere.example/x'>outside words</a> too. \(paragraph)</p>" + String(repeating: "<p onclick='window.readerTrap=1'>\(paragraph)</p>", count: 12) + "<a href='/teaser'><div><p>Teaser card text that is a whole block inside one link.</p></div></a><input value=fresh><button id=reader-action>Source action</button><a href='/next'>Second page</a><img src='/reader-resource'><iframe src='/reader-resource'></iframe><script>window.readerActions=0;window.readerTrap=0;document.getElementById('reader-action').addEventListener('click',()=>window.readerActions++);</script></article></body>"
                    }
                    if route == "/reader-hidden" {
                        let words = String(repeating: "These hidden words must never offer or appear in Reader. ", count: 30)
                        body = "<!doctype html><meta name=viewport content=width=device-width><title>Hidden prose</title><link rel=icon href=data:,><h1>Public heading only</h1><section><p style='display:none'>\(words)</p><p style='visibility:hidden'>\(words)</p><p style='opacity:0'>\(words)</p><p>Short visible prose.</p></section>"
                    }
                    if route == "/refresh-short" { body = "<!doctype html><meta name=viewport content=width=device-width><title>Short refresh</title><link rel=icon href=data:,><p id=part>Refresh request \(self.counts[route, default: 0])</p>" }
                    if route.hasPrefix("/viewport-") {
                        let fit = route == "/viewport-cover" ? ",viewport-fit=cover" : ""
                        body = """
                        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1\(fit)">
                        <title>Viewport test</title><link rel="icon" href="data:,">
                        <style>
                        body{margin:0;min-height:2400px;font:20px system-ui}
                        header,footer{position:fixed;left:env(safe-area-inset-left);right:env(safe-area-inset-right);height:40px;background:#cdf}
                        header{top:env(safe-area-inset-top)}footer{bottom:env(safe-area-inset-bottom)}
                        #probe{position:absolute;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom);padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right)}
                        #small{height:100svh}#large{height:100lvh}#dynamic{height:100dvh}
                        .unit{position:absolute;visibility:hidden;width:1px;pointer-events:none}
                        </style><header>Viewport header</header><footer>Viewport footer</footer>
                        <div id="probe"></div><div id="small" class="unit"></div><div id="large" class="unit"></div><div id="dynamic" class="unit"></div>
                        <script>function measureViewport(){const p=getComputedStyle(document.getElementById('probe'));return {
                        envTop:parseFloat(p.paddingTop),envBottom:parseFloat(p.paddingBottom),envLeft:parseFloat(p.paddingLeft),envRight:parseFloat(p.paddingRight),visualHeight:visualViewport.height,
                        innerHeight:innerHeight,scrollY:scrollY,headerTop:document.querySelector('header').getBoundingClientRect().top,
                        footerBottom:document.querySelector('footer').getBoundingClientRect().bottom,
                        svh:document.getElementById('small').getBoundingClientRect().height,lvh:document.getElementById('large').getBoundingClientRect().height,
                        dvh:document.getElementById('dynamic').getBoundingClientRect().height};}</script>
                        """
                    }
                    if route == "/slow" { body += String(repeating: "<!-- pending -->", count: 1_024) }
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                }
                let bytes = Data(response.utf8)
                if route == "/slow", self.holdsSlow {
                    self.held.append((connection, Data(bytes.suffix(1))))
                    connection.send(content: Data(bytes.dropLast()), completion: .contentProcessed { _ in })
                } else {
                    connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if !done, request.count < 32_768 {
                self.receive(connection, data: request)
            } else { connection.cancel() }
        }
    }
}

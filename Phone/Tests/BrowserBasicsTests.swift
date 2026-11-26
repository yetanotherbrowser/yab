import Network
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// The browser basics, a section each. Real WebKit pages come from a
/// loopback site this suite owns, never the internet.
@MainActor
final class BrowserBasicsTests: XCTestCase {
    private var site: BasicsSite!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var pools: [WebPool] = []
    private var tabs: [YabPhone.Tab] = []
    private var opened: [URL] = []
    private var oldDisabled = false

    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        site = try BasicsSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in site.start { done.resume(with: $0) } }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        opened = []
        OutsideLink.record = { [weak self] url in self?.opened.append(url) }
    }

    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled }
        OutsideLink.record = nil
        for pool in pools { pool.suspendPageDialogs(); tabs.forEach { pool.forget($0.id) } }
        pools = []; tabs = []
        window?.rootViewController = nil; window?.isHidden = true; window = nil; previousKey?.makeKey()
        site?.stop(); site = nil
    }

    private func pool() -> WebPool {
        let made = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pools.append(made); return made
    }
    private func tab(_ id: String, _ path: String = "/links", privately: Bool = false) -> YabPhone.Tab {
        let made = PageFixtures.liveTab(for: site.url(path), id: id, isPrivate: privately)
        tabs.append(made); return made
    }
    private func ready(_ pages: WebPool, _ tab: YabPhone.Tab) async throws -> WKWebView {
        let view = pages.activate(tab)
        let host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds; host.addSubview(view); window.layoutIfNeeded()
        try await until { pages.painted.contains(tab.id) && !view.isLoading }
        return view
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        // A farm Mac under load (adhd at a load of 70) can take more than 10 s
        // to paint a loopback page; the state still has to arrive.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The page's state did not arrive", file: file, line: line)
        throw NSError(domain: "BrowserBasicsTests", code: 1)
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private func waitForDarkening(_ expected: Bool, in view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = try? await view.evaluateJavaScript("!!document.getElementById('yab-website-darkening')") as? Bool
            if value == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Website darkening did not become \(expected)")
    }

    // MARK: - links that leave for an app

    func testDarkenWebsitesFollowsAppearanceAndLeavesDarkPagesAlone() async throws {
        let settings = SettingsStore.shared
        let before = settings.darkenWebsites
        defer { settings.darkenWebsites = before }
        settings.darkenWebsites = true
        window.overrideUserInterfaceStyle = .dark
        let pages = pool()
        let white = try await ready(pages, tab("website-dark.white", "/links"))
        try await waitForDarkening(true, in: white)
        settings.darkenWebsites = false
        try await waitForDarkening(false, in: white)
        settings.darkenWebsites = true
        try await waitForDarkening(true, in: white)
        window.overrideUserInterfaceStyle = .light
        try await waitForDarkening(false, in: white)
        window.overrideUserInterfaceStyle = .dark
        let dark = try await ready(pages, tab("website-dark.native", "/dark"))
        try await waitForDarkening(false, in: dark)
    }

    func testATappedAppLinkGoesToIOSAndAnUntouchedOneIsNotFollowed() {
        for address in ["tel:+15551234567", "mailto:anna@example.com", "sms:+15551234567", "facetime:anna@example.com",
                        "facetime-audio:anna@example.com", "maps://?q=Lisbon", "twitter://user?screen_name=yab"] {
            let url = URL(string: address)!
            for kind in [WKNavigationType.linkActivated, .formSubmitted, .other] {
                XCTAssertEqual(PageLinkRoute.route(url, inPage: false, navigation: kind, tapped: true), .outside, address)
                XCTAssertEqual(PageLinkRoute.route(url, inPage: false, navigation: kind, tapped: false), .refused,
                               "\(address): a page sending itself there with no touch is not followed")
            }
            for kind in [WKNavigationType.backForward, .reload, .formResubmitted] {
                XCTAssertEqual(PageLinkRoute.route(url, inPage: false, navigation: kind, tapped: true), .refused, address)
            }
        }
    }

    func testWebLinksStayInYabAndYabsOwnAddressesNeverLeave() {
        let web = URL(string: "https://www.youtube.com/watch?v=owned")!
        XCTAssertEqual(PageLinkRoute.route(web, inPage: true, navigation: .linkActivated, tapped: true), .page)
        XCTAssertEqual(PageLinkRoute.route(web, inPage: false, navigation: .linkActivated, tapped: true), .refused,
                       "a universal link is never handed to iOS, so its app doesn't take it")
        for address in ["yab://task/lisbon/approve", "yab-open://https://example.com", "file:///etc/hosts",
                        "javascript:alert(1)", "itms-services://?action=download-manifest", "blob:https://owned.test/x",
                        "data:text/html,owned", "about:blank", "\(PageSchemeHandler.scheme)://hn", "no-scheme"] {
            let url = URL(string: address)!
            XCTAssertEqual(PageLinkRoute.route(url, inPage: false, navigation: .linkActivated, tapped: true), .refused, address)
        }
    }

    func testOnlyAPersonsTouchSendsAPageToAnAppAndThePageCannotPretendOne() async throws {
        let pages = pool(), page = tab("links.public")
        let view = try await ready(pages, page)
        // A script's click() and a redirect: no touch, nothing leaves.
        let _: Any = try await view.evaluateJavaScript("document.getElementById('call').click(); true")
        let _: Any = try await view.evaluateJavaScript("leave(); true")
        try await settle()
        XCTAssertEqual(opened, [])
        // Yab's own world can't be posted to from the page's.
        let reachable = try await view.evaluateJavaScript("typeof (window.webkit && webkit.messageHandlers.yabSignal)") as? String
        XCTAssertEqual(reachable, "undefined")
        // What a trusted touch makes Yab's own world say, then the link.
        try await touch(view)
        let _: Any = try await view.evaluateJavaScript("document.getElementById('call').click(); true")
        try await until { self.opened.count == 1 }
        XCTAssertEqual(opened, [URL(string: "tel:+15551234567")!])
        // One touch, one app: the next link from it stays.
        let _: Any = try await view.evaluateJavaScript("document.getElementById('mail').click(); true")
        try await settle()
        XCTAssertEqual(opened.count, 1)
        // Neither is a failure of the page, which stays where it was.
        XCTAssertNil(pages.state(for: page.id).failure)
        XCTAssertEqual(view.url, site.url("/links"))
        XCTAssertEqual(pages.navigationState(for: page.id)?.entries.map(\.url), [site.url("/links").absoluteString])
    }

    func testABackgroundPageCannotLeaveEvenRightAfterATouch() async throws {
        let pages = pool(), front = tab("links.front"), behind = tab("links.behind")
        let back = try await ready(pages, behind)
        try await touch(back)
        _ = try await ready(pages, front)
        let _: Any = try await back.evaluateJavaScript("document.getElementById('call').click(); true")
        try await settle()
        XCTAssertEqual(opened, [], "only the page in front, in use, may hand a link to iOS")
    }

    private func touch(_ view: WKWebView) async throws {
        let _: Any? = try await view.evaluateJavaScript("webkit.messageHandlers.yabSignal.postMessage({ tap: true }); true",
                                                        in: nil, contentWorld: PageSignals.world)
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - the held link's menu

    func testOpenInBackgroundTabGoesAfterThePageWhichStaysInFront() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        app.surfaces.toastsStay = true
        let source = try XCTUnwrap(app.browser.tab)
        let space = app.browser.space.id
        let before = app.browser.space.today.map(\.id)
        app.openHeldLink(URL(string: "https://example.com/owned")!, from: source.id, as: .background)
        XCTAssertEqual(app.browser.tab?.id, source.id, "the page stays in front")
        XCTAssertEqual(app.browser.space.id, space)
        let today = app.browser.space.today.map(\.id)
        XCTAssertEqual(today.count, before.count + 1)
        let added = try XCTUnwrap(Set(today).subtracting(before).first)
        let expected = before.firstIndex(of: source.id).map { $0 + 1 } ?? 0
        XCTAssertEqual(today.firstIndex(of: added), expected, "right after the page it came from")
        XCTAssertEqual(app.surfaces.toast?.text, "Opened in Background")
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.backgroundTab)
    }

    func testOpenInNewTabComesInFrontInTheSameSpaceAndPrivateStaysPrivate() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let source = try XCTUnwrap(app.browser.tab)
        let space = app.browser.space.id
        app.openHeldLink(URL(string: "https://example.com/front")!, from: source.id, as: .front)
        XCTAssertNotEqual(app.browser.tab?.id, source.id)
        XCTAssertEqual(app.browser.space.id, space)
        XCTAssertEqual(app.browser.space.today.first?.id, app.browser.tab?.id)
        XCTAssertEqual(app.browser.tab?.isPrivate, false)

        app.openPrivately(PageFixtures.tab(for: URL(string: "https://example.com/private")!, in: app.world))
        let privateSource = try XCTUnwrap(app.browser.tab)
        XCTAssertTrue(app.browser.space.isPrivate)
        app.openHeldLink(URL(string: "https://example.com/next")!, from: privateSource.id, as: .front)
        XCTAssertNotEqual(app.browser.tab?.id, privateSource.id)
        XCTAssertEqual(app.browser.tab?.isPrivate, true, "a private page's link opens a private tab")
        XCTAssertTrue(app.browser.space.isPrivate)
        app.openHeldLink(URL(string: "https://example.com/behind")!, from: privateSource.id, as: .background)
        XCTAssertTrue(app.browser.space.today.allSatisfy(\.isPrivate))
    }

    func testTheMenuPutsItsTwoItemsOverTheSystemsOwn() throws {
        let system = UIAction(title: "Copy Link") { _ in }
        let menu = PageLinkMenu.menu([system]) { _ in }
        let ours = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertTrue(ours.options.contains(.displayInline))
        XCTAssertEqual(ours.children.compactMap { ($0 as? UIAction)?.title }, [PageLinkMenu.newTab, PageLinkMenu.backgroundTab])
        XCTAssertEqual(ours.children.map(\.accessibilityIdentifier), ["link.newTab", "link.backgroundTab"])
        XCTAssertTrue(menu.children.last === system, "the system's actions stay under ours")
    }

    /// The Mac's Open in Split View, offered where a split can stand.
    func testTheMenuOffersSplitViewOnlyWhenAsked() throws {
        let plain = try XCTUnwrap(PageLinkMenu.menu([]) { _ in }.children.first as? UIMenu)
        XCTAssertFalse(plain.children.map(\.accessibilityIdentifier).contains("link.beside"))
        var opened: PageLinkMenu.Opening?
        let wide = try XCTUnwrap(PageLinkMenu.menu([], beside: true) { opened = $0 }.children.first as? UIMenu)
        XCTAssertEqual(wide.children.compactMap { ($0 as? UIAction)?.title }.last, PageLinkMenu.beside)
        XCTAssertEqual(wide.children.last?.accessibilityIdentifier, "link.beside")
        _ = opened
    }

    func testOnlyWebLinksOfThePageInFrontGetTheMenu() async throws {
        let pages = pool(), page = tab("menu.links")
        _ = try await ready(pages, page)
        XCTAssertTrue(pages.opensAsTab(site.url("/second")))
        XCTAssertFalse(pages.opensAsTab(URL(string: "mailto:anna@example.com")!))
        XCTAssertFalse(pages.opensAsTab(URL(string: "about:blank")!))
        XCTAssertFalse(pages.opensAsTab(URL(string: "data:text/html,owned")!))
    }


    // MARK: - under the page

    func testTheColorUnderAPageIsThePagesOwn() async throws {
        let pages = pool()
        let dark = try await ready(pages, tab("under.dark", "/dark"))
        try await until { dark.underPageBackgroundColor.isDarkGround && dark.scrollView.backgroundColor?.isDarkGround == true }
        XCTAssertEqual(dark.scrollView.refreshControl?.overrideUserInterfaceStyle, .dark, "light ink on a dark page")
        let light = try await ready(pages, tab("under.light", "/links"))
        try await until { !light.underPageBackgroundColor.isDarkGround && light.scrollView.backgroundColor?.isDarkGround == false }
        XCTAssertEqual(light.scrollView.refreshControl?.overrideUserInterfaceStyle, .light)
        XCTAssertTrue(UIColor.black.isDarkGround)
        XCTAssertFalse(UIColor.white.isDarkGround)
        XCTAssertFalse(UIColor.clear.isDarkGround)
    }

    // MARK: - media

    func testTheAudioSessionIsPlaybackOnlyWhileSomethingPlays() {
        XCTAssertEqual(PagePlayback.category(playing: true), .playback)
        XCTAssertEqual(PagePlayback.category(playing: false), .soloAmbient)
        var applied: [Bool] = []
        let playback = PagePlayback { applied.append($0) }
        playback.set("a", playing: true)
        playback.set("b", playing: true)
        playback.set("a", playing: false)
        XCTAssertEqual(applied, [true], "still playing while one page does")
        playback.forget("b")
        XCTAssertEqual(applied, [true, false])
        playback.set("b", playing: false)
        XCTAssertEqual(applied, [true, false], "only a change is applied")
    }

    func testAPlayingPageIsNeverLetGoToKeepTheLimit() async throws {
        let pages = pool()
        let first = tab("media.first", "/second")
        _ = try await ready(pages, first)
        pages.playback.set(first.id, playing: true)
        for index in 1...WebPool.liveLimit { _ = try await ready(pages, tab("media.other.\(index)", "/second?\(index)")) }
        XCTAssertTrue(pages.isLive(first.id), "a page playing media stays alive past the limit")
        XCTAssertFalse(pages.isLive("media.other.1"), "the oldest that doesn't play goes instead")
        pages.playback.set(first.id, playing: false)
        _ = try await ready(pages, tab("media.last", "/second?last"))
        XCTAssertFalse(pages.isLive(first.id), "stopped, it goes as any other")
    }

    func testWebKitSaysWhenAPageStartsAndStopsPlayingAndPrivateStopsWithTheLock() async throws {
        let pages = pool()
        for privately in [false, true] {
            let page = tab("media.audio.\(privately)", "/audio", privately: privately)
            let view = try await ready(pages, page)
            // The app's own script runs as a person's gesture, so it may play.
            let _: Any = try await view.evaluateJavaScript("start(); true")
            try await until { pages.playback.isPlaying(page.id) }
            if privately {
                pages.pausePrivateMedia()
                XCTAssertFalse(pages.playback.isPlaying(page.id))
                try await Task.sleep(for: .milliseconds(300))
                let paused = try await view.evaluateJavaScript("document.querySelector('audio').paused") as? Bool
                XCTAssertEqual(paused, true, "a private page stops playing as the lock closes")
            } else {
                let _: Any = try await view.evaluateJavaScript("document.querySelector('audio').pause(); true")
                try await until { !pages.playback.isPlaying(page.id) }
            }
        }
    }

    /// #1757: dismissing a saved tab must end its live page, not its saved entry.
    func testSwipingClosedSavedCardsStopsMediaAndReleasesTheirWebViews() async throws {
        for place in [Tab.Place.pinned, .kept] {
            for inFront in [true, false] {
                var page = tab("media.saved.\(place).\(inFront)", "/audio")
                page.place = place
                let other = tab("media.neighbor.\(place).\(inFront)", "/second")
                let space = Space(id: "media", name: "Media", emoji: "", tint: RGB(1, 2, 3),
                                  pins: place == .pinned ? [page] : [],
                                  kept: place == .kept ? [.tab(page)] : [], today: [other], current: page.id)
                let app = AppModel(world: World(name: "media", space: space.id, spaces: [space]),
                                   fixturesEnabled: false, privateLockEnabled: { false })
                pools.append(app.pages)
                let stack = TabStack.of(app)
                let view = try await ready(app.pages, page)
                _ = try await view.evaluateJavaScript("start(); true")
                try await until { app.pages.playback.isPlaying(page.id) }
                try await settle()
                if !inFront {
                    app.browser.select(other.id)
                    _ = try await ready(app.pages, other)
                    try await settle()
                }
                stack.openGallery()
                XCTAssertTrue(stack.cards(of: try XCTUnwrap(stack.gallery)).contains { $0.id == page.id })
                stack.liftCard(page.id, by: -500)
                stack.releaseCard(page.id, dy: -500, velocity: -1000)
                try await settle()
                XCTAssertFalse(app.pages.isLive(page.id), "a dismissed saved card releases its web view")
                XCTAssertFalse(app.pages.playback.isPlaying(page.id))
                XCTAssertNil(view.superview)
                // Retain the old view deliberately: teardown must stop its native media
                // even while a transition or another owner still holds the view.
                let paused = try await view.evaluateJavaScript("document.querySelector('audio').paused") as? Bool
                XCTAssertEqual(paused, true)
                XCTAssertEqual(app.browser.tab(page.id)?.place, place, "the saved entry stays")
                XCTAssertFalse(stack.order.contains { $0.id == page.id })
                app.browser.select(page.id)
                let reopened = try await ready(app.pages, page)
                XCTAssertFalse(reopened === view, "reopening creates a fresh web view")
                XCTAssertFalse(app.pages.playback.isPlaying(page.id))
                stack.dismissGallery()
            }
        }
    }

    // MARK: - clearing history and website data

    func testClearHistoryForgetsVisitsAndBackForwardButKeepsTheTabs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserBasics-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        let page = PageFixtures.liveTab(for: URL(string: "https://example.com/b")!, id: "history.tab")
        app.browser.open(page)
        profile.capture(app.browser)
        profile.recordVisit(page)
        let entries = ["https://example.com/a", "https://example.com/b", "https://example.com/c"].map { BrowserNavigation.Entry(url: $0, title: $0) }
        profile.navigationChanged(page.id, BrowserNavigation(entries: entries, index: 1, interactionData: Data([1, 2, 3])))
        XCTAssertFalse(profile.recent.isEmpty)

        await app.clearHistoryAndWebsiteData(stores: [])
        XCTAssertTrue(profile.recent.isEmpty)
        XCTAssertTrue(profile.frequent.isEmpty)
        XCTAssertEqual(profile.navigation[page.id]?.entries.map(\.url), ["https://example.com/b"], "only the page it shows")
        XCTAssertEqual(profile.navigation[page.id]?.index, 0)
        XCTAssertNil(profile.navigation[page.id]?.interactionData, "WebKit's own Back list goes too")
        XCTAssertEqual(app.browser.tab?.id, page.id, "the tab stays")
        await profile.flush()
        let again = BrowserProfile(folder: folder)
        XCTAssertTrue(again.recent.isEmpty, "and stays cleared on disk")
        XCTAssertEqual(again.navigation[page.id]?.entries.count, 1)
    }

    func testClearWebsiteDataEmptiesTheStoresOnDiskAndNeverPrivatesInMemory() async throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        app.surfaces.toastsStay = true
        let id = UUID()
        let disk = WKWebsiteDataStore(forIdentifier: id)
        let memory = WKWebsiteDataStore.nonPersistent()
        for store in [disk, memory] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "owned.test", .path: "/", .name: "owned", .value: "1",
                                                               .expires: Date().addingTimeInterval(3600)]))
            await store.httpCookieStore.setCookie(cookie)
        }
        await app.clearHistoryAndWebsiteData(stores: [disk, memory])
        let left = await disk.httpCookieStore.allCookies()
        XCTAssertTrue(left.isEmpty, "cookies on disk are gone")
        let kept = await memory.httpCookieStore.allCookies()
        XCTAssertEqual(kept.map(\.name), ["owned"], "a private store in memory isn't touched")
        XCTAssertEqual(app.surfaces.toast?.text, "History and Data Cleared")
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.historyCleared)
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    func testClearHistoryLetsLivePagesGoAndTheyComeBackOnTheirPageAlone() async throws {
        let pages = pool(), page = tab("history.live"), shy = tab("history.private", privately: true)
        let view = try await ready(pages, page)
        pages.load(page.id, site.url("/second"))
        try await until { view.url == self.site.url("/second") && pages.painted.contains(page.id) && !view.isLoading }
        XCTAssertEqual(pages.navigationState(for: page.id)?.entries.count, 2)
        let shyView = try await ready(pages, shy)
        pages.load(shy.id, site.url("/second"))
        try await until { shyView.url == self.site.url("/second") && pages.painted.contains(shy.id) && !shyView.isLoading }

        XCTAssertTrue(pages.clearHistory())
        XCTAssertFalse(pages.isLive(page.id))
        XCTAssertEqual(pages.navigationState(for: page.id)?.entries.map(\.url), [site.url("/second").absoluteString])
        XCTAssertTrue(pages.isLive(shy.id), "private tabs are memory only and keep theirs")
        XCTAssertEqual(pages.navigationState(for: shy.id)?.entries.count, 2)

        // The tab's own address follows its page (AppModel's commit), as here.
        let moved = PageFixtures.liveTab(for: site.url("/second"), id: page.id)
        let again = try await ready(pages, moved)
        XCTAssertEqual(again.url, site.url("/second"))
        XCTAssertFalse(again.canGoBack)
        XCTAssertFalse(pages.state(for: page.id).canGoBack)
    }
}

/// A loopback site of the suite's own pages, by path.
final class BasicsSite: @unchecked Sendable {
    static let pages: [String: String] = [
        "/links": """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned links</title>
        <style>body{font:18px -apple-system;padding:80px 20px}a{display:block;padding:14px 0}</style>
        <a id="call" href="tel:+15551234567">Call Anna</a>
        <a id="mail" href="mailto:anna@example.com">Mail Anna</a>
        <a id="web" href="/second">Second page</a>
        <script>function leave() { location.href = 'mailto:auto@example.com'; }</script>
        """,
        "/second": "<!doctype html><title>Second</title><p>Second page</p>",
        // A quiet tone made in the page: a second of WAV, looped.
        "/audio": """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned audio</title>
        <audio loop></audio>
        <script>
        function start() {
          var rate = 8000, n = rate, data = new DataView(new ArrayBuffer(44 + n * 2));
          var text = function (o, s) { for (var i = 0; i < s.length; i++) data.setUint8(o + i, s.charCodeAt(i)); };
          text(0, 'RIFF'); data.setUint32(4, 36 + n * 2, true); text(8, 'WAVEfmt ');
          data.setUint32(16, 16, true); data.setUint16(20, 1, true); data.setUint16(22, 1, true);
          data.setUint32(24, rate, true); data.setUint32(28, rate * 2, true); data.setUint16(32, 2, true);
          data.setUint16(34, 16, true); text(36, 'data'); data.setUint32(40, n * 2, true);
          for (var i = 0; i < n; i++) data.setInt16(44 + i * 2, Math.sin(i / rate * 2 * Math.PI * 440) * 600, true);
          var audio = document.querySelector('audio');
          audio.src = URL.createObjectURL(new Blob([data.buffer], { type: 'audio/wav' }));
          audio.volume = 0.05;
          audio.play();
        }
        </script>
        """,
        "/dark": """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned dark page</title>
        <style>html,body{background:#101012;color:#eee;margin:0}p{padding:80px 20px}</style><p>A dark page</p>
        """,
    ]

    private let queue = DispatchQueue(label: "owned-browser-basics-http")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    var port: UInt16 { listener.port!.rawValue }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ completed: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.ready = completed
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; callback(.success(()))
                case let .failed(error): self.ready = nil; callback(.failure(error))
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "BasicsSite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            let callback = ready; ready = nil
            callback?(.failure(NSError(domain: "BasicsSite", code: 2)))
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
    }

    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            let path = target.components(separatedBy: "?").first ?? target
            let body = Self.pages[path] ?? "<!doctype html><title>Owned</title><p>Owned page</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}

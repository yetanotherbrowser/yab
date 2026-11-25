import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// The lists' scriptlets in real pages over HTTP, from the fixtures the Mac
/// runs too (Tests/Fixtures/shield): each says "blocked" or "leaked" in its
/// title. A control run without the script shows the trick works at all.
@MainActor
final class ShieldScriptletTests: XCTestCase {
    private var folder: URL!
    private var site: ShieldTestSite!
    private var window: UIWindow!

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/shield", isDirectory: true)

    private static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name + ".html"), encoding: .utf8)
    }

    private static let plain = "<!doctype html><meta charset=utf-8><title>plain</title><body><p>Nothing here.</p>"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shield-scriptlets-\(UUID().uuidString)", isDirectory: true)
        site = try ShieldTestSite(routes: [
            "/t1": .page(try Self.fixture("t1-inline-aclib")),
            "/t4": .page(try Self.fixture("t4-iframe-open")),
            "/t7": .page(try Self.fixture("t7-link-cover")),
            "/ad-landing.html": .page(try Self.fixture("ad-landing")),
            "/plain": .page(Self.plain),
            "/hop": .redirect(host: "127.0.0.1", path: "/t1"),
        ])
        try await site.start()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.isHidden = false
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func shield(_ list: String) async throws -> Shield {
        // A folder of its own, so a second list in one test is built afresh.
        let own = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lists = Shield.listsFolder(own)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try list.write(to: lists.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        let shield = Shield(folder: own, fetches: false)
        shield.start()
        await shield.settled()
        XCTAssertNotNil(shield.scriptlets, "the list's scriptlets made a script")
        return shield
    }

    private func loaded(_ view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(30)) }
    }

    /// The page's title once the fixture has said, or what it says after 6 s.
    private func verdict(_ view: WKWebView) async throws -> String {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if let title = view.title, title.contains("/") { return title }
            try await Task.sleep(for: .milliseconds(30))
        }
        return view.title ?? ""
    }

    // MARK: - through the app's pages

    private func page(_ pool: WebPool, _ path: String, id: String, host: String = "127.0.0.1") async throws -> WKWebView {
        let tab = Tab(id: id, title: id, site: host, icon: "", url: site.url(path, host: host).absoluteString)
        let view = pool.view(for: tab)
        view.frame = window.bounds
        window.addSubview(view)
        return view
    }

    func testAnInlineAdLibraryNeverRunsWhereTheListsSayAndRunsWhereTheSiteIsOff() async throws {
        let shield = try await shield("127.0.0.1##+js(aopr, aclib)\n")
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.shield = shield
        let blocked = try await page(pool, "/t1", id: "on")
        defer { blocked.removeFromSuperview() }
        let first = try await verdict(blocked)
        XCTAssertEqual(first, "blocked/ok")
        shield.wants = { _, _ in false }
        let control = try await page(pool, "/t1", id: "off")
        defer { control.removeFromSuperview() }
        let second = try await verdict(control)
        XCTAssertEqual(second, "leaked/ok", "with the site off, no script: the trick works")
    }

    /// localhost, a name the lists can't spell (no dot), redirected to
    /// 127.0.0.1, which they do.
    func testARedirectToAnotherSiteRunsThatSitesScriptletsInIt() async throws {
        let shield = try await shield("127.0.0.1##+js(aopr, aclib)\n")
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.shield = shield
        let hopped = try await page(pool, "/hop", id: "hop", host: "localhost")
        defer { hopped.removeFromSuperview() }
        let first = try await verdict(hopped)
        XCTAssertEqual(hopped.url?.host(), "127.0.0.1")
        XCTAssertEqual(first, "blocked/ok")
        let direct = try await page(pool, "/t1", id: "direct", host: "localhost")
        defer { direct.removeFromSuperview() }
        let second = try await verdict(direct)
        XCTAssertEqual(second, "leaked/ok", "localhost has no rules: each frame reads its own host")
    }

    // MARK: - popups allowed

    @MainActor
    private final class Opener: NSObject, WKUIDelegate {
        var opened: [WKWebView] = []
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let view = WKWebView(frame: .zero, configuration: configuration)
            opened.append(view)
            return view
        }
    }

    /// A bare view with the shield fitted for 127.0.0.1, popups allowed, so
    /// a control run shows the trick opening a window.
    private func bare(_ shield: Shield, _ path: String) -> (WKWebView, Opener) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let view = WKWebView(frame: window.bounds, configuration: configuration)
        shield.fit(controller, host: "127.0.0.1", isPrivate: false)
        let opener = Opener()
        view.uiDelegate = opener
        window.addSubview(view)
        view.load(URLRequest(url: site.url(path)))
        return (view, opener)
    }

    func testAHiddenFramesWindowOpenIsStopped() async throws {
        let shield = try await shield("127.0.0.1##+js(nowoif)\n")
        let (blocked, quiet) = bare(shield, "/t4")
        defer { blocked.removeFromSuperview() }
        let first = try await verdict(blocked)
        XCTAssertEqual(first, "blocked/ok")
        XCTAssertTrue(quiet.opened.isEmpty)
        shield.wants = { _, _ in false }
        let (control, opener) = bare(shield, "/t4")
        defer { control.removeFromSuperview() }
        let second = try await verdict(control)
        XCTAssertEqual(second, "leaked/ok", "without the script the frame's open makes a window")
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testAScriptClickOnAnAdLinkIsStopped() async throws {
        let shield = try await shield("127.0.0.1##+js(nowoif)\n")
        let (blocked, quiet) = bare(shield, "/t7")
        defer { blocked.removeFromSuperview() }
        let first = try await verdict(blocked)
        XCTAssertEqual(first, "blocked/ok")
        XCTAssertTrue(quiet.opened.isEmpty)
        shield.wants = { _, _ in false }
        let (control, opener) = bare(shield, "/t7")
        defer { control.removeFromSuperview() }
        let second = try await verdict(control)
        XCTAssertEqual(second, "leaked/ok", "without the script the click opens the ad")
        XCTAssertFalse(opener.opened.isEmpty)
    }

    /// The cover fixture (t8) in a bare view as if served at `base`, so the
    /// page's host is any the lists can name; popups allowed.
    private func cover(_ shield: Shield, at base: String) async throws -> (verdict: String, opened: Int) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let view = WKWebView(frame: window.bounds, configuration: configuration)
        defer { view.removeFromSuperview() }
        let url = try XCTUnwrap(URL(string: base))
        shield.fit(controller, host: url.host(), isPrivate: false)
        let opener = Opener()
        view.uiDelegate = opener
        window.addSubview(view)
        view.loadHTMLString(try Self.fixture("t8-cover-guard"), baseURL: url)
        return (try await verdict(view), opener.opened.count)
    }

    /// The click guard only on a site the lists name for a scriptlet, by its
    /// host, a domain above it or an entity. A list naming other sites, a
    /// `~site`, an exception or Shield off for the site leaves the cover to
    /// open its ad.
    func testACoverIsStoppedOnlyWhereTheListsNameTheSite() async throws {
        let names = "##+js(set, yabFixtureUnused, true)"
        let cases: [(list: String, at: String, blocked: Bool)] = [
            ("news.test" + names, "https://news.test/", true),
            ("news.test" + names, "https://www.news.test/", true),
            ("news.*" + names, "https://news.test/", true),
            ("other.example##+js(nowoif)", "https://news.test/", false),
            ("news.test,~safe.news.test" + names, "https://safe.news.test/", false),
            ("news.test" + names + "\nnews.test#@#+js()", "https://news.test/", false),
        ]
        for one in cases {
            let shield = try await shield(one.list + "\n")
            let (said, opened) = try await cover(shield, at: one.at)
            XCTAssertEqual(said, one.blocked ? "blocked/ok" : "leaked/ok", "\(one.list) at \(one.at)")
            XCTAssertEqual(opened == 0, one.blocked, "\(one.list) at \(one.at): \(opened) opened")
        }
        let shield = try await shield("news.test" + names + "\n")
        shield.wants = { _, _ in false }
        let (said, opened) = try await cover(shield, at: "https://news.test/")
        XCTAssertEqual(said, "leaked/ok", "Shield off for the site: no script, the cover opens the ad")
        XCTAssertGreaterThan(opened, 0)
    }

    // MARK: - no match, no trace

    /// What a page can see of the functions scriptlets wrap, read with a
    /// fresh frame's own toString, and every global's name.
    private static let shape = """
    (() => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      const ts = f.contentWindow.Function.prototype.toString;
      const own = (fn, name) => typeof fn === 'function' && ts.call(fn).includes('function ' + name + '(') && ts.call(fn).includes('[native code]');
      const out = {
        open: own(window.open, 'open'),
        addEventListener: own(EventTarget.prototype.addEventListener, 'addEventListener'),
        setTimeout: own(window.setTimeout, 'setTimeout'),
        appendChild: own(Node.prototype.appendChild, 'appendChild'),
        insertBefore: own(Node.prototype.insertBefore, 'insertBefore'),
        defineProperty: own(Object.defineProperty, 'defineProperty'),
        toString: own(Function.prototype.toString, 'toString'),
      };
      f.remove();
      out.globals = Object.getOwnPropertyNames(window).sort().join(',');
      return JSON.stringify(out);
    })()
    """

    func testAPageNoRuleNamesIsLeftExactlyAsWithoutTheScript() async throws {
        let shield = try await shield("other.example##+js(nowoif)\nother.example##+js(aeld, click)\nother.example##+js(nostif, ad)\nother.example##+js(set, ads, true)\n")
        let script = try XCTUnwrap(shield.scriptlets)
        let (on, _) = bare(shield, "/plain")
        defer { on.removeFromSuperview() }
        XCTAssertTrue(on.configuration.userContentController.userScripts.contains { $0 === script })
        try await loaded(on)
        let with = try await on.evaluateJavaScript(Self.shape) as? String
        shield.wants = { _, _ in false }
        let (off, _) = bare(shield, "/plain")
        defer { off.removeFromSuperview() }
        XCTAssertFalse(off.configuration.userContentController.userScripts.contains { $0 === script })
        try await loaded(off)
        let without = try await off.evaluateJavaScript(Self.shape) as? String
        let shape = try XCTUnwrap(with)
        XCTAssertEqual(shape, without, "no hooks, no globals")
        let flags = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shape.utf8)) as? [String: Any])
        for (name, value) in flags where name != "globals" { XCTAssertEqual(value as? Bool, true, "\(name) is the browser's own") }
    }
}

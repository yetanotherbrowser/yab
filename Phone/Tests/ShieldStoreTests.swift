import Network
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// The blocker's lists on pages of every kind of website store the app
/// makes: the shared one, a space's own (by identifier) and private ones.
/// A page with the lists loads over the network as one without them does.
@MainActor
final class ShieldStoreTests: XCTestCase {
    private var folder: URL!
    private var site: ShieldTestSite!
    private var window: UIWindow!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shield-store-\(UUID().uuidString)", isDirectory: true)
        site = try ShieldTestSite()
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

    @MainActor
    private final class Watcher: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Bool, Never>?
        func finish(_ ok: Bool) { done?.resume(returning: ok); done = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

    /// Loads the site's page in a web view of this store, the lists put on
    /// before or after the view is made; whether it finished in 10 s.
    private func loads(_ store: WKWebsiteDataStore, lists: [WKContentRuleList], after: Bool, _ name: String) async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let controller = WKUserContentController()
        configuration.userContentController = controller
        if !after { for list in lists { controller.add(list) } }
        let view = WKWebView(frame: window.bounds, configuration: configuration)
        if after { for list in lists { controller.add(list) } }
        window.addSubview(view)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let watcher = Watcher()
        view.navigationDelegate = watcher
        return await withCheckedContinuation { done in
            watcher.done = done
            view.load(URLRequest(url: site.url("/page?case=\(name)")))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                watcher.finish(false)
            }
        }
    }

    func testPagesWithTheListsLoadInEveryKindOfStore() async throws {
        let shield = Shield(folder: folder, fetches: false)
        shield.start()
        await shield.settled()
        XCTAssertEqual(shield.lists.count, 2)
        let stores: [(String, @MainActor () -> WKWebsiteDataStore)] = [
            ("nonpersistent", { .nonPersistent() }),
            ("identifier", { WKWebsiteDataStore(forIdentifier: UUID()) }),
        ]
        // As the app does it (WebPool): the lists put on once the view
        // is made. Given them before, a view's first load sometimes never
        // finished; that way is tried too, and only said.
        var after: [String] = [], before: [String] = []
        for round in 0..<3 {
            for (kind, make) in stores {
                let none = await loads(make(), lists: [], after: false, "\(kind)-none-\(round)")
                let made = await loads(make(), lists: shield.lists, after: true, "\(kind)-after-\(round)")
                let early = await loads(make(), lists: shield.lists, after: false, "\(kind)-before-\(round)")
                XCTAssertTrue(none, "\(kind) without the lists, round \(round)")
                after.append("\(kind)=\(made)")
                before.append("\(kind)=\(early)")
            }
        }
        print("SHIELD_STORES after: \(after.joined(separator: " ")) before: \(before.joined(separator: " "))")
        XCTAssertTrue(after.allSatisfy { $0.hasSuffix("=true") }, "after: \(after) before: \(before)")
    }

    func testAColdHeldTabBlocksItsFirstLoadAndReleasesThePreview() async throws {
        // Prove the fixture executes without a blocker before testing it
        // through the cold preview's configuration.
        let control = WKWebView(frame: window.bounds)
        window.addSubview(control)
        control.load(URLRequest(url: site.url("/preview-control")))
        let controlDeadline = Date().addingTimeInterval(10)
        while Date() < controlDeadline && (control.isLoading || control.url == nil) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let unblocked = try await control.evaluateJavaScript("window.previewAdLoaded === true") as? Bool
        XCTAssertEqual(unblocked, true, "the ad script runs without the blocker")
        control.stopLoading()
        control.removeFromSuperview()
        let shield = Shield(folder: folder, fetches: false)
        let texts = Shield.listsFolder(folder)
        try FileManager.default.createDirectory(at: texts, withIntermediateDirectories: true)
        try "/preview-ad.js$script\n".write(to: texts.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        shield.start()
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.shield = shield
        let tab = Tab(id: "held", title: "Held", site: "127.0.0.1", icon: "", url: site.url("/preview").absoluteString)
        let host = UIHostingController(rootView: AnyView(TabHoldPage(tab: tab, pool: pool)))
        window.rootViewController = host
        host.view.frame = window.bounds
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && (pool.liveView(tab.id)?.isLoading != false || pool.liveView(tab.id)?.url == nil) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let page = try XCTUnwrap(pool.liveView(tab.id))
        XCTAssertFalse(page.isLoading)
        let loaded = try await page.evaluateJavaScript("window.previewAdLoaded === true") as? Bool
        XCTAssertEqual(loaded, false, "the preview must not fetch its ad script before the lists arrive")
        XCTAssertEqual(shield.identifiers(on: page.configuration.userContentController).count, 2)
        host.rootView = AnyView(EmptyView())
        let closed = Date().addingTimeInterval(5)
        while pool.isBorrowed(tab.id), Date() < closed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(pool.isBorrowed(tab.id))
        XCTAssertFalse(pool.isLive(tab.id), "a page made only for the preview goes with its menu")
    }
}

import UIKit
import WebKit
import XCTest
@testable import YabPhone

// Real news sites loaded cold with the real lists, with the scriptlets and
// without, in pairs whose order alternates, round after round across the
// sites: load, DOMContentLoaded, first contentful paint, finish, and how late
// the page's main thread and the app's ran. Opt-in: YAB_PERF=1;
// YAB_PERF_REPEATS rounds (10), YAB_PERF_SITES a comma list to replace the
// sites, YAB_PERF_NONE=1 adds loads without the lists.
@MainActor
final class ShieldLoadPerfTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ShieldPerf.enabled, "opt-in: YAB_PERF=1")
    }

    private static let defaultSites = [
        "https://www.theverge.com/",
        "https://edition.cnn.com/",
        "https://www.dailymail.co.uk/home/index.html",
        // A site the scriptlets name (aopw, nowoif): what a match costs.
        "https://yts.gg/",
    ]

    /// Every 50 ms from the page's first script until read: how late the
    /// timer ran, the page's main thread busy elsewhere. The same in every arm.
    private static let probe = WKUserScript(source: """
        (function () { var p = performance, last = p.now(), worst = 0, over50 = 0, over100 = 0, late = 0;
          var id = setInterval(function () { var now = p.now(), d = now - last - 50; last = now;
            if (d > worst) worst = d; if (d > 50) over50++; if (d > 100) over100++; if (d > 0) late += d; }, 50);
          window.__yabLag = function () { clearInterval(id); return [worst, over50, over100, late].join(','); }; })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private static let read = """
        (() => {
          const nav = performance.getEntriesByType('navigation')[0] || {};
          const paint = performance.getEntriesByType('paint').find(e => e.name === 'first-contentful-paint');
          const res = performance.getEntriesByType('resource');
          let bytes = 0; for (const r of res) bytes += (r.transferSize || 0);
          const lag = window.__yabLag ? window.__yabLag() : '-1,-1,-1,-1';
          return [nav.domContentLoadedEventEnd || 0, nav.loadEventEnd || 0, paint ? paint.startTime : -1, res.length, bytes,
                  document.getElementsByTagName('*').length, document.getElementsByTagName('iframe').length, lag].join(',');
        })()
        """

    func testRealSitesLoadAsFastWithTheScriptlets() async throws {
        let shield = try await ShieldPerf.shield(scriptlets: true)
        let scriptlets = try XCTUnwrap(shield.scriptlets)
        let window = try ShieldPerf.window()
        let sites = (ShieldPerf.environment["YAB_PERF_SITES"].map { $0.split(separator: ",").map(String.init) } ?? Self.defaultSites)
            .compactMap(URL.init(string:))
        let repeats = ShieldPerf.int("YAB_PERF_REPEATS", 10)
        var variants = ["lists", "scriptlets"]
        if ShieldPerf.environment["YAB_PERF_NONE"] == "1" { variants.insert("none", at: 0) }
        var pages: [[String: Any]] = []
        let started = Date()
        for round in 0..<repeats {
            for site in sites {
                let order = round.isMultiple(of: 2) ? variants : variants.reversed()
                for (slot, variant) in order.enumerated() {
                    var page = await load(site, lists: variant == "none" ? [] : shield.lists,
                                          scriptlets: variant == "scriptlets" ? scriptlets : nil, in: window)
                    page["site"] = site.host() ?? site.absoluteString
                    page["variant"] = variant
                    page["round"] = round
                    page["slot"] = slot
                    page["t"] = Date().timeIntervalSince(started)
                    pages.append(page)
                }
            }
            print("shield perf loads: round \(round + 1) of \(repeats) after \(Int(Date().timeIntervalSince(started))) s")
        }
        ShieldPerf.emit("loads", ["repeats": repeats, "variants": variants, "script_bytes": shield.scriptletsSourceBytes,
                                  "pages": pages], in: self)
    }

    private func load(_ url: URL, lists: [WKContentRuleList], scriptlets: WKUserScript?, in window: UIWindow) async -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let os = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
        let controller = configuration.userContentController
        if let scriptlets { controller.addUserScript(scriptlets) }
        controller.addUserScript(Self.probe)
        for list in lists { controller.add(list) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
        window.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let lag = ShieldPerf.Lag()
        lag.start()
        let t0 = CFAbsoluteTimeGetCurrent()
        let finished = await ShieldPerf.navigate(view, seconds: 45) { $0.load(URLRequest(url: url)) }
        var result: [String: Any] = ["finished": finished, "finish_ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000]
        try? await Task.sleep(for: .seconds(3))
        lag.stop()
        result["app_lag_worst_ms"] = lag.worst
        result["app_lag_over17"] = lag.over17
        result["app_lag_over50"] = lag.over50
        let numbers = (await ShieldPerf.evaluate(view, Self.read) as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
        let keys = ["dcl", "load", "fcp", "resources", "transfer", "nodes", "iframes",
                    "page_lag_worst_ms", "page_lag_over50", "page_lag_over100", "page_lag_total_ms"]
        if numbers.count == keys.count {
            for (key, value) in zip(keys, numbers) { result[key] = value }
        } else {
            result["js_error"] = true
        }
        if let pid = ShieldPerf.webProcess(view) { result["web_mb"] = ShieldPerf.footprint(pid) ?? -1 }
        return result
    }
}

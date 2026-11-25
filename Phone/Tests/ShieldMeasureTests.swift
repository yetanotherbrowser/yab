import UIKit
import WebKit
import XCTest
@testable import YabPhone

// What the ad blocker costs and saves, measured on the farm's simulator with
// the real lists from the internet and real news sites. Not part of an
// ordinary `remote test` run (Phone/scripts/phone skips it): only by name,
// `Phone/scripts/remote test ShieldMeasureTests`. Writes
// YAB_OUT/shield/measure.json and prints the same. Each site loads without
// the lists, with them, and with them and the scriptlets, interleaved in
// the same build; YAB_SHIELD_SCRIPTLETS=0 leaves the third out.

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

@MainActor
final class ShieldMeasureTests: XCTestCase {
    private var folder: URL!
    private var out: [String: Any] = [:]

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shield-measure-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The sites: heavy news front pages, each loaded cold (a store of its own).
    private let sites = [
        "https://www.theverge.com/",
        "https://edition.cnn.com/",
        "https://www.dailymail.co.uk/home/index.html",
        // A site the scriptlets name (aopw, nowoif): what a match costs.
        "https://yts.gg/",
    ]
    private let repeats = Int(ProcessInfo.processInfo.environment["YAB_MEASURE_REPEATS"] ?? "") ?? 5

    private enum Variant: String, CaseIterable {
        case none, lists, scriptlets
    }

    func testTheFirstLaunchBuildAndPageLoadsWithAndWithoutTheLists() async throws {
        // 1. The first launch: the built-in list, then the week's lists
        //    fetched, converted and compiled, through Shield itself.
        let first = Shield(folder: folder, fetches: false)
        out["app_mb_before"] = appFootprint()?.now
        let t0 = CFAbsoluteTimeGetCurrent()
        first.start()
        await first.settled()
        out["base_build_ms"] = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let t1 = CFAbsoluteTimeGetCurrent()
        first.refresh(now: true)
        await first.settled()
        out["fetch_and_build_ms"] = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
        // What the build holds at its height (the texts, the rules, the JSON):
        // the app's own memory, which iOS watches.
        out["app_mb_after"] = appFootprint()?.now
        out["app_mb_peak"] = appFootprint()?.peak
        out["first_launch"] = first.report
        let rules = first.made?.rules ?? 0
        out["rules"] = rules
        out["lists"] = first.lists.count
        try XCTSkipIf(first.lists.count < 2 || rules < 50_000, "the lists didn't arrive (network?): \(first.report)")
        let compiled = folder.appendingPathComponent("compiled")
        out["compiled_bytes"] = (try? FileManager.default.subpathsOfDirectory(atPath: compiled.path))?.reduce(0) { sum, name in
            sum + ((try? FileManager.default.attributesOfItem(atPath: compiled.appendingPathComponent(name).path)[.size] as? Int) ?? 0)
        } ?? 0

        // 2. Every later launch: found compiled.
        let later = Shield(folder: folder, fetches: false)
        let t2 = CFAbsoluteTimeGetCurrent()
        later.start()
        await later.settled()
        out["later_launch_ms"] = Int((CFAbsoluteTimeGetCurrent() - t2) * 1000)
        out["later_launch"] = later.report
        XCTAssertEqual(later.compiles, 0)
        XCTAssertEqual(later.lookups, 1)

        // 3. Pages, without the lists, with them, and with the scriptlets
        //    too, alternating, each cold.
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first)
        let timed = later.scriptlets.map { Self.timed($0.source) }
        out["scriptlets"] = timed != nil
        out["scriptlet_bytes"] = later.scriptlets?.source.utf8.count ?? 0
        let variants = Variant.allCases.filter { $0 != .scriptlets || timed != nil }
        var pages: [[String: Any]] = []
        for site in sites {
            guard let url = URL(string: site) else { continue }
            for round in 0..<repeats {
                for variant in variants {
                    var load = await self.load(url, lists: variant == .none ? [] : later.lists,
                                               scriptlets: variant == .scriptlets ? timed : nil, in: window)
                    load["site"] = url.host() ?? site
                    load["variant"] = variant.rawValue
                    load["round"] = round
                    pages.append(load)
                }
            }
        }
        out["pages"] = pages
        out["summary"] = summary(pages)
        write()
    }

    // MARK: - one load

    @MainActor
    private final class Watcher: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Bool, Never>?
        func finish(_ ok: Bool) { done?.resume(returning: ok); done = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

    /// The page script, timing itself in the top document: what one frame pays.
    private static func timed(_ source: String) -> WKUserScript {
        let wrapped = "{ const yabT0 = performance.now();\n" + source + "\n;globalThis.__yabScriptletMs = performance.now() - yabT0; }"
        return WKUserScript(source: wrapped, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    private func load(_ url: URL, lists: [WKContentRuleList], scriptlets: WKUserScript?, in window: UIWindow) async -> [String: Any] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let os = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
        for list in lists { configuration.userContentController.add(list) }
        if let scriptlets { configuration.userContentController.addUserScript(scriptlets) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
        let watcher = Watcher()
        view.navigationDelegate = watcher
        // Drawn beneath everything, as a hold's preview is: a page out of a
        // window stops its timers.
        window.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let finished: Bool = await withCheckedContinuation { done in
            watcher.done = done
            view.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(45))
                watcher.finish(false)
            }
        }
        var result: [String: Any] = ["finished": finished, "finish_ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)]
        // Settle a moment for late scripts, then what the page says of itself.
        try? await Task.sleep(for: .seconds(3))
        let script = """
        (() => {
          const nav = performance.getEntriesByType('navigation')[0] || {};
          const res = performance.getEntriesByType('resource');
          let bytes = 0; for (const r of res) bytes += (r.transferSize || 0);
          return [nav.domContentLoadedEventEnd || 0, nav.loadEventEnd || 0, res.length, bytes,
                  document.getElementsByTagName('*').length, document.getElementsByTagName('iframe').length].join(',');
        })()
        """
        let said: (Any?, Error?) = await withCheckedContinuation { done in
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) { outcome in
                switch outcome {
                case let .success(value): done.resume(returning: (value, nil))
                case let .failure(error): done.resume(returning: (nil, error))
                }
            }
        }
        let numbers = (said.0 as? String)?.split(separator: ",").compactMap { Double($0) } ?? []
        if numbers.count == 6 {
            for (key, value) in zip(["dcl", "load", "resources", "transfer", "nodes", "iframes"], numbers) { result[key] = value }
        } else {
            result["js_error"] = said.1.map { String(describing: $0) } ?? "said \(String(describing: said.0))"
        }
        if scriptlets != nil, let cost = try? await view.evaluateJavaScript("globalThis.__yabScriptletMs ?? -1") as? Double {
            result["scriptlet_ms"] = cost
        }
        // The page's web process, by WebKit's own private property: a test
        // may ask what the app never does.
        if view.responds(to: NSSelectorFromString("_webProcessIdentifier")),
           let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 {
            result["web_mb"] = footprint(pid).map { Double($0) / 1_048_576 }
        }
        return result
    }

    /// A process's physical footprint, as Activity Monitor's Memory column
    /// says it (rusage_info_v4.ri_phys_footprint, at byte 72).
    private func footprint(_ pid: Int32) -> UInt64? {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { buffer.deallocate() }
        guard proc_pid_rusage(pid, 4, buffer) == 0 else { return nil }
        return buffer.load(fromByteOffset: 72, as: UInt64.self)
    }

    /// This process's footprint now and at its height, in MB.
    private func appFootprint() -> (now: Double, peak: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    // MARK: - out

    private func summary(_ pages: [[String: Any]]) -> [[String: Any]] {
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        var rows: [[String: Any]] = []
        let hosts = Array(Set(pages.compactMap { $0["site"] as? String })).sorted()
        for host in hosts {
            for variant in Variant.allCases.map(\.rawValue) {
                let some = pages.filter { $0["site"] as? String == host && $0["variant"] as? String == variant && $0["finished"] as? Bool == true }
                guard !some.isEmpty else { continue }
                func values(_ key: String) -> [Double] { some.compactMap { ($0[key] as? NSNumber)?.doubleValue } }
                rows.append(["site": host, "variant": variant, "loads": some.count,
                             "scriptlet_ms": median(values("scriptlet_ms")) ?? -1,
                             "finish_ms": median(values("finish_ms")) ?? -1, "load_ms": median(values("load")) ?? -1,
                             "dcl_ms": median(values("dcl")) ?? -1, "resources": median(values("resources")) ?? -1,
                             "transfer_kb": (median(values("transfer")) ?? 0) / 1024, "web_mb": median(values("web_mb")) ?? -1])
            }
        }
        return rows
    }

    private func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return }
        print("SHIELD_MEASURE " + (String(data: data, encoding: .utf8) ?? ""))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "shield-measure.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = ProcessInfo.processInfo.environment["YAB_OUT"], !path.isEmpty {
            let folder = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("shield", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("measure.json"))
        }
    }
}

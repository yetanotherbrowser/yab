import UIKit
import WebKit
import XCTest
@testable import YabPhone

// What Shield's scriptlet script costs on iPhone and iPad, as the Mac's
// Tests/FastTests/ShieldScriptletsPerfTests measures it, with the real lists
// built by Shield itself (ShieldPerf). Opt-in: YAB_PERF=1. Raw samples go
// out as SHIELD_PERF lines, result attachments and YAB_PERF_OUT.
@MainActor
final class ShieldScriptletsPerfTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ShieldPerf.enabled, "opt-in: YAB_PERF=1")
    }

    // MARK: - one frame

    private static let frames = 50
    private static let warmup = 3
    private static let rounds = ShieldPerf.int("YAB_PERF_ROUNDS", 25)

    private static let page = "<!doctype html><title>frames</title><body>"
        + (0..<frames).map { "<iframe srcdoc='<p>frame \($0)</p>'></iframe>" }.joined()

    // performance.now() is coarse in WebKit. The first timer waits for a tick
    // and counts a busy loop through the next one; the second counts the same
    // loop to the tick after it, which tells how far into that tick it started.
    private static let before = WKUserScript(source: """
        (function () { var p = performance, a = p.now(), b, n = 0;
          while ((b = p.now()) === a) {} a = b;
          while ((b = p.now()) === a) n++;
          window.__yabPerfRate = n / (b - a); window.__yabPerf0 = b; })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    private static let after = WKUserScript(source: """
        (function () { var p = performance, t = p.now(), b, n = 0;
          while ((b = p.now()) === t) n++;
          (window.__yabPerfD = window.__yabPerfD || []).push(b - window.__yabPerf0 - n / window.__yabPerfRate); })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    private static let empty = WKUserScript(source: ";", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    private static let events = WKUserScript(source: """
        addEventListener('DOMContentLoaded', function () { window.__yabDCL = performance.now(); });
        addEventListener('load', function () { window.__yabLoad = performance.now(); });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private enum Arm: String, CaseIterable {
        case off, on, control, timed
        var scriptlets: Bool { self == .on || self == .timed }
        var timers: Bool { self == .control || self == .timed }
    }

    /// The scripts a page gets for an arm, the scriptlets first as
    /// Shield.prepare puts them.
    private func scripts(_ arm: Arm, _ scriptlets: WKUserScript) -> [WKUserScript] {
        let middle = arm.scriptlets ? scriptlets : (arm.timers ? Self.empty : nil)
        var list = [Self.events]
        if arm.timers { list.append(Self.before) }
        if let middle { list.append(middle) }
        if arm.timers { list.append(Self.after) }
        return list
    }

    private func frameCost(site: String, base: String) async throws {
        let shield = try await ShieldPerf.shield(scriptlets: true)
        let scriptlets = try XCTUnwrap(shield.scriptlets)
        let url = try XCTUnwrap(URL(string: base))
        let window = try ShieldPerf.window()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        for list in shield.lists { configuration.userContentController.add(list) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
        window.insertSubview(view, at: 0)
        defer { view.removeFromSuperview() }
        let controller = configuration.userContentController

        var samples: [[String: Any]] = []
        var order = Arm.allCases
        for round in 0..<(Self.warmup + Self.rounds) {
            order.shuffle()
            for arm in order {
                controller.removeAllUserScripts()
                scripts(arm, scriptlets).forEach(controller.addUserScript)
                let finished = await ShieldPerf.navigate(view, seconds: 20) { $0.loadHTMLString(Self.page, baseURL: url) }
                XCTAssertTrue(finished, "\(arm) round \(round) never finished")
                let condition = "window.__yabLoad !== undefined && frames.length === \(Self.frames)"
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, await ShieldPerf.evaluate(view, "!!(\(condition))") as? Bool != true {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let read = """
                    JSON.stringify({ main: (window.__yabPerfD || [null])[0], dcl: window.__yabDCL, load: window.__yabLoad,
                      frames: Array.from({ length: frames.length }, function (_, i) {
                        try { return (frames[i].__yabPerfD || [null])[0]; } catch (e) { return null; } }) })
                    """
                let said = await ShieldPerf.evaluate(view, read)
                let text = try XCTUnwrap(said as? String)
                var sample = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let timed = (sample["frames"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                if arm.timers {
                    XCTAssertEqual(timed.count, Self.frames, "\(arm) round \(round): frames timed")
                } else {
                    XCTAssertTrue(timed.isEmpty, "\(arm) round \(round): timers where none should be")
                }
                sample["frames"] = timed
                sample["arm"] = arm.rawValue
                sample["round"] = round
                samples.append(sample)
            }
        }
        let kept = samples.filter { ($0["round"] as? Int ?? 0) >= Self.warmup }
        func values(_ arm: Arm, _ key: String) -> [Double] {
            kept.filter { $0["arm"] as? String == arm.rawValue }.flatMap { sample -> [Double] in
                if let list = sample[key] as? [Double] { return list }
                return (sample[key] as? NSNumber).map { [$0.doubleValue] } ?? []
            }
        }
        let sub = mean(values(.timed, "frames")) - mean(values(.control, "frames"))
        let main = mean(values(.timed, "main")) - mean(values(.control, "main"))
        print(String(format: "shield perf frames %@: subframe %.3f ms, main %.3f ms; DCL off %.1f on %.1f; load off %.1f on %.1f",
                     site, sub, main, median(values(.off, "dcl")), median(values(.on, "dcl")),
                     median(values(.off, "load")), median(values(.on, "load"))))
        ShieldPerf.emit("frames-\(site)", ["site": site, "base": base, "frames": Self.frames, "warmup": Self.warmup,
                                           "rounds": Self.rounds, "script_bytes": shield.scriptletsSourceBytes,
                                           "sub_cost_ms": sub, "main_cost_ms": main, "samples": samples], in: self)
    }

    /// A site the lists have no scriptlets for: the script finds nothing and returns.
    func testAFramePaysLittleWithNoMatch() async throws {
        try await frameCost(site: "nomatch", base: "https://news.test/")
    }

    /// yts.gg, whose calls run in every frame (nowoif arms each new frame's window).
    func testAFramePaysLittleOnAMatch() async throws {
        try await frameCost(site: "match", base: "https://yts.gg/")
    }

    // MARK: - many tabs

    /// Twenty tabs opened one after another through WebPool, as the app
    /// opens them (three stay live), with the scriptlets on and off; and
    /// twenty bare pages at once, every one live, on a matched site and on
    /// one with no match. Also
    /// whether every page holds the one script object and no navigation
    /// placed it again.
    func testManyTabsMemory() async throws {
        let on = try await ShieldPerf.shield(scriptlets: true)
        let off = try await ShieldPerf.shield(scriptlets: false)
        let framed = "<!doctype html><meta charset=utf-8><title>tab</title><body>"
            + (0..<8).map { "<p>Paragraph \($0) of a page with frames.</p><iframe srcdoc='<p>frame \($0)</p>'></iframe>" }.joined()
        var routes: [String: ShieldTestSite.Route] = [:]
        for index in 0..<20 { routes["/tab\(index)"] = .page(framed) }
        let site = try ShieldTestSite(routes: routes)
        try await site.start()
        defer { site.stop() }
        let window = try ShieldPerf.window()
        let rounds = ShieldPerf.int("YAB_PERF_TAB_ROUNDS", 4)
        var samples: [[String: Any]] = []
        for round in 0..<rounds {
            let arms = round.isMultiple(of: 2) ? [true, false] : [false, true]
            for scriptlets in arms {
                var sample = try await pool(scriptlets ? on : off, site: site, in: window)
                sample["scriptlets"] = scriptlets
                sample["round"] = round
                samples.append(sample)
                for (kind, base) in [("bare-match", "https://yts.gg/"), ("bare-nomatch", "https://news.test/")] {
                    sample = try await bare(scriptlets: scriptlets ? on.scriptlets : nil, lists: on.lists, html: framed, base: base, in: window)
                    sample["scriptlets"] = scriptlets
                    sample["round"] = round
                    sample["kind"] = kind
                    samples.append(sample)
                }
            }
        }
        ShieldPerf.emit("tabs", ["samples": samples], in: self)
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func pool(_ shield: Shield, site: ShieldTestSite, in window: UIWindow) async throws -> [String: Any] {
        try await settle(3)
        let before = ShieldPerf.app()?.now ?? -1
        var pool: WebPool? = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool?.shield = shield
        let placements = shield.placements
        var shared = 0, holders = 0, stuck = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        for index in 0..<20 {
            let tab = Tab(id: "perf-\(index)", title: "Tab \(index)", site: "127.0.0.1", icon: "",
                          url: "http://127.0.0.1:\(site.port)/tab\(index)")
            // Not put in the window: the pool lets go of views past its limit.
            guard let view = pool?.activate(tab) else { break }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(20)) }
            if view.isLoading || view.url == nil { stuck += 1 }
            let scripts = view.configuration.userContentController.userScripts
            if let script = shield.scriptlets {
                holders += scripts.contains { $0 === script } ? 1 : 0
                shared += scripts.filter { $0.source == script.source }.count
            }
        }
        try await settle(5)
        var live: [WKWebView] = []
        for index in 0..<20 { if let view = pool?.liveView("perf-\(index)") { live.append(view) } }
        let pids = Set(live.compactMap(ShieldPerf.webProcess))
        let web = pids.compactMap(ShieldPerf.footprint)
        let after = ShieldPerf.app()?.now ?? -1
        let sample: [String: Any] = ["kind": "pool", "app_before_mb": before, "app_after_mb": after,
                                     "live": live.count, "web_processes": pids.count, "web_mb": web.reduce(0, +),
                                     "web_read": web.count, "holders": holders, "copies": shared,
                                     "placements": shield.placements - placements, "stuck": stuck,
                                     "open_ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000]
        live = []
        pool = nil
        return sample
    }

    private func bare(scriptlets: WKUserScript?, lists: [WKContentRuleList], html: String, base: String, in window: UIWindow) async throws -> [String: Any] {
        try await settle(3)
        let before = ShieldPerf.app()?.now ?? -1
        var views: [WKWebView] = []
        var stuck = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            if let scriptlets { configuration.userContentController.addUserScript(scriptlets) }
            for list in lists { configuration.userContentController.add(list) }
            let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
            window.insertSubview(view, at: 0)
            views.append(view)
            let finished = await ShieldPerf.navigate(view, seconds: 15) { $0.loadHTMLString(html, baseURL: URL(string: base)) }
            if !finished { stuck += 1 }
        }
        try await settle(5)
        let pids = Set(views.compactMap(ShieldPerf.webProcess))
        let web = pids.compactMap(ShieldPerf.footprint)
        let after = ShieldPerf.app()?.now ?? -1
        for view in views { view.removeFromSuperview() }
        views = []
        return ["app_before_mb": before, "app_after_mb": after, "live": 20, "web_processes": pids.count,
                "web_mb": web.reduce(0, +), "web_read": web.count, "stuck": stuck, "open_ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000]
    }

    /// Where a page process's extra memory comes from: pages of 0, 8 and 32
    /// frames with no script, a one-character script, the library over an
    /// empty table, and the real script; read 5 s after the pages load and
    /// again 30 s later.
    func testMemoryByFrames() async throws {
        let on = try await ShieldPerf.shield(scriptlets: true)
        let full = try XCTUnwrap(on.scriptlets)
        let emptySource = try XCTUnwrap(Shield.scriptletSource(#"{"v":2,"calls":"","hosts":" "}"#))
        let empty = WKUserScript(source: emptySource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        let window = try ShieldPerf.window()
        let tiny = WKUserScript(source: ";", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        let arms: [(String, WKUserScript?)] = [("off", nil), ("tiny", tiny), ("library", empty), ("full", full)]
        let counts = (ShieldPerf.environment["YAB_PERF_MEM_FRAMES"] ?? "0,8,32").split(separator: ",").compactMap { Int($0) }
        let views = ShieldPerf.int("YAB_PERF_MEM_VIEWS", 10)
        var samples: [[String: Any]] = []
        for round in 0..<ShieldPerf.int("YAB_PERF_MEM_ROUNDS", 2) {
            for frames in counts {
                let html = "<!doctype html><meta charset=utf-8><title>mem</title><body><p>text</p>"
                    + (0..<frames).map { "<iframe srcdoc='<p>frame \($0)</p>'></iframe>" }.joined()
                for (arm, script) in (round.isMultiple(of: 2) ? arms : arms.reversed()) {
                    for base in ["https://news.test/", "https://yts.gg/"] {
                        try await settle(2)
                        var pages: [WKWebView] = []
                        for _ in 0..<views {
                            let configuration = WKWebViewConfiguration()
                            configuration.websiteDataStore = .nonPersistent()
                            if let script { configuration.userContentController.addUserScript(script) }
                            let view = WKWebView(frame: CGRect(origin: .zero, size: Metrics.screen), configuration: configuration)
                            window.insertSubview(view, at: 0)
                            pages.append(view)
                            _ = await ShieldPerf.navigate(view, seconds: 15) { $0.loadHTMLString(html, baseURL: URL(string: base)) }
                        }
                        try await settle(5)
                        let pids = Set(pages.compactMap(ShieldPerf.webProcess))
                        let early = pids.compactMap(ShieldPerf.footprint).reduce(0, +)
                        try await settle(30)
                        let late = pids.compactMap(ShieldPerf.footprint).reduce(0, +)
                        for view in pages { view.removeFromSuperview() }
                        pages = []
                        samples.append(["round": round, "frames": frames, "arm": arm, "base": base, "processes": pids.count,
                                        "mb_5s": early, "mb_35s": late, "script_bytes": script?.source.utf8.count ?? 0])
                        print("shield perf mem: \(arm) \(base) frames \(frames): \(String(format: "%.1f / %.1f", early / Double(max(pids.count, 1)), late / Double(max(pids.count, 1)))) MB a process")
                    }
                }
            }
        }
        ShieldPerf.emit("memframes", ["views": views, "samples": samples], in: self)
    }

    // MARK: - the build

    /// The lists built from the same texts with the scriptlets on and off,
    /// alternating, each in a folder of its own; and the scriptlets' own
    /// steps timed alone: every ##+js line converted by itself (what the
    /// parse can add at most), the table and the page script made of it.
    func testTheBuildWithAndWithoutScriptlets() async throws {
        let shield = try await ShieldPerf.shield(scriptlets: true)
        let lists = Shield.listsFolder(ShieldPerf.folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: lists.path).filter { $0.hasSuffix(".txt") }
        let rounds = ShieldPerf.int("YAB_PERF_BUILD_ROUNDS", 4)
        var builds: [[String: Any]] = []
        for round in 0..<rounds {
            for scriptlets in round.isMultiple(of: 2) ? [true, false] : [false, true] {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shield-build-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let copy = Shield.listsFolder(folder)
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                for name in names { try FileManager.default.copyItem(at: lists.appendingPathComponent(name), to: copy.appendingPathComponent(name)) }
                let build = Shield(folder: folder, fetches: false)
                build.scriptletsAllowed = scriptlets
                let t0 = CFAbsoluteTimeGetCurrent()
                build.start()
                await build.settled()
                let wall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                var row = build.report.compactMapValues { $0 as? NSNumber }.mapValues { $0.doubleValue } as [String: Any]
                row["wall_ms"] = wall
                row["scriptlets"] = scriptlets
                row["round"] = round
                row["app_mb"] = ShieldPerf.app()?.now ?? -1
                builds.append(row)
                // WebKit's compiled files for this folder's store go with it.
                try await settle(1)
            }
        }

        let texts = names.compactMap { try? String(contentsOf: lists.appendingPathComponent($0), encoding: .utf8) }
        let lines = texts.flatMap { $0.split(separator: "\n").filter { $0.contains("#+js(") } }.joined(separator: "\n")
        var parts: [[String: Any]] = []
        for _ in 0..<5 {
            let m0 = ShieldPerf.app()?.now ?? -1
            let t0 = CFAbsoluteTimeGetCurrent()
            let rules = Filters.convert([lines])
            let t1 = CFAbsoluteTimeGetCurrent()
            let table = rules.scriptlets.table()
            let t2 = CFAbsoluteTimeGetCurrent()
            let source = Shield.scriptletSource(table) ?? ""
            let t3 = CFAbsoluteTimeGetCurrent()
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            let t4 = CFAbsoluteTimeGetCurrent()
            let m1 = ShieldPerf.app()?.now ?? -1
            parts.append(["js_lines": lines.split(separator: "\n").count, "convert_js_lines_ms": (t1 - t0) * 1000,
                          "table_ms": (t2 - t1) * 1000, "source_ms": (t3 - t2) * 1000, "script_ms": (t4 - t3) * 1000,
                          "table_bytes": table.utf8.count, "source_bytes": source.utf8.count, "mb_delta": m1 - m0,
                          "script": script.source.count])
        }
        ShieldPerf.emit("build", ["builds": builds, "parts": parts, "rules": shield.made?.rules ?? 0], in: self)
    }

    private func mean(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count) }
    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return values.sorted()[values.count / 2]
    }
}

extension Shield {
    var scriptletsSourceBytes: Int { scriptlets?.source.utf8.count ?? 0 }
}

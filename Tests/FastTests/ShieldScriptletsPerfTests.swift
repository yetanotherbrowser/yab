import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

// What Shield's scriptlet script costs a frame inside WebKit, in a real tab
// armed the way Yab arms it. Two small scripts sit just before and after it
// (same world, document start, every frame) and time it; the same pair around
// an empty script is the control. Also a 50-frame page's DOMContentLoaded and
// load with the script and without. Opt-in: YAB_PERF=1, with the real table
// from YAB_PERF_TABLE (a Shield/scriptlets.txt), else Yab Dev's own. Raw
// samples, warm-up rounds included, go to YAB_PERF_OUT (a folder), else the
// temporary folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_PERF"] == "1"))
struct ShieldScriptletsPerfTests {
    private static let frames = 50
    private static let warmup = 3
    private static let rounds = Int(ProcessInfo.processInfo.environment["YAB_PERF_ROUNDS"] ?? "") ?? 25

    private static let page = "<!doctype html><title>frames</title><body>"
        + (0..<frames).map { "<iframe srcdoc='<p>frame \($0)</p>'></iframe>" }.joined()

    // performance.now() ticks by the millisecond in WebKit. The first timer
    // waits for a tick and counts a busy loop through the next one; the second
    // counts the same loop to the tick after it, which tells how far into
    // that millisecond it started.
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
        /// Scriptlets off, nothing timed.
        case off
        /// Scriptlets on, nothing timed.
        case on
        /// Off, the timers around an empty script in the scriptlets' place.
        case control
        /// On, the timers around the scriptlets.
        case timed
        var scriptlets: Bool { self == .on || self == .timed }
        var timers: Bool { self == .control || self == .timed }
    }

    private struct Sample: Codable {
        let arm: String
        let round: Int
        let main: Double?
        let frames: [Double]
        let dcl: Double
        let load: Double
    }

    private static func realTable() throws -> ShieldScriptlets.Table {
        let env = ProcessInfo.processInfo.environment["YAB_PERF_TABLE"]
        let path = env ?? NSHomeDirectory() + "/Library/Application Support/Yab Dev/Shield/scriptlets.txt"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try #require(text.hasPrefix(#"{"v":2,"#), "\(path) is not a version 2 table: run Yab Dev once so the lists rebuild, or point YAB_PERF_TABLE at one")
        return try #require(ShieldScriptlets.Table(text), "no table in \(path)")
    }

    @MainActor private final class Opened {
        let browser: Browser
        let id: UUID
        let tab: Tab
        init(_ browser: Browser, _ id: UUID, _ tab: Tab) { self.browser = browser; self.id = id; self.tab = tab }
        func close() {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
    }

    private func open() -> Opened {
        let id = UUID()
        let browser = Browser(windowID: id)
        let tab = Tab(factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#perf")!)
        return Opened(browser, id, tab)
    }

    /// Yab arms the tab for `base` (a first, plain page there), then the
    /// arm's timers go in around the scriptlets' place. The next page at the
    /// same site arms with the same list, which PageScripts.fit leaves as it is.
    private func arm(_ arm: Arm, _ tab: Tab, base: URL, scriptlets: WKUserScript) async throws {
        ShieldScriptlets.on = arm.scriptlets
        tab.page.navigate(html: "<p>arming</p>", base: base)
        try await settle(tab, until: "document.body && document.body.textContent === 'arming' && document.readyState === 'complete'")
        let controller = try #require(tab.built?.configuration.userContentController)
        let ours = [Self.before, Self.after, Self.empty, Self.events]
        var list = controller.userScripts.filter { script in !ours.contains { $0 === script } }
        if let at = list.firstIndex(where: { $0 === scriptlets }) {
            #expect(arm.scriptlets)
            if arm.timers { list.replaceSubrange(at...at, with: [Self.before, scriptlets, Self.after]) }
        } else {
            #expect(!arm.scriptlets)
            // Where Yab puts the scriptlets when they are on: after YouTube's, before the rest.
            let slot = list.firstIndex(where: { $0 === YouTube.user }).map { $0 + 1 } ?? list.count
            if arm.timers { list.insert(contentsOf: [Self.before, Self.empty, Self.after], at: slot) }
        }
        list.insert(Self.events, at: 0)
        controller.removeAllUserScripts()
        list.forEach(controller.addUserScript)
    }

    private func settle(_ tab: Tab, until condition: String, seconds: Double = 10) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(seconds) {
            if let ok = try? await tab.page.fixtureExpression("!!(\(condition))", world: .page) as? Bool, ok { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("page never settled: \(condition)")
    }

    private func measure(_ arm: Arm, round: Int, _ tab: Tab, base: URL) async throws -> Sample {
        tab.page.navigate(html: Self.page, base: base)
        try await settle(tab, until: "window.__yabLoad !== undefined && frames.length === \(Self.frames)")
        let read = """
            JSON.stringify({ main: (window.__yabPerfD || [null])[0], dcl: window.__yabDCL, load: window.__yabLoad,
              frames: Array.from({ length: frames.length }, function (_, i) {
                try { return (frames[i].__yabPerfD || [null])[0]; } catch (e) { return null; } }) })
            """
        let text = try #require(try await tab.page.fixtureExpression(read, world: .page) as? String)
        struct Read: Decodable { let main: Double?; let dcl: Double; let load: Double; let frames: [Double?] }
        let got = try JSONDecoder().decode(Read.self, from: Data(text.utf8))
        let timed = got.frames.compactMap { $0 }
        if arm.timers {
            #expect(got.main != nil && timed.count == Self.frames, "\(arm) round \(round): \(timed.count) frames timed")
        } else {
            #expect(got.main == nil && timed.isEmpty, "\(arm) round \(round): timers where none should be")
        }
        return Sample(arm: arm.rawValue, round: round, main: got.main, frames: timed, dcl: got.dcl, load: got.load)
    }

    private func run(site: String, base: String) async throws {
        let table = try Self.realTable()
        let was = (ShieldScriptlets.table, ShieldScriptlets.on)
        ShieldScriptlets.install(table)
        defer {
            ShieldScriptlets.install(was.0)
            ShieldScriptlets.on = was.1
        }
        let opened = open()
        defer { opened.close() }
        let url = try #require(URL(string: base))
        let host = try #require(url.host)
        ShieldScriptlets.on = true
        let scriptlets = try #require(ShieldScriptlets.webKit(for: opened.tab, host: host), "Shield gives \(host) no scriptlets")

        var samples: [Sample] = []
        var order = Arm.allCases
        for round in 0..<(Self.warmup + Self.rounds) {
            order.shuffle()
            for arm in order {
                try await self.arm(arm, opened.tab, base: url, scriptlets: scriptlets)
                samples.append(try await measure(arm, round: round, opened.tab, base: url))
            }
        }
        report(site, samples, tableBytes: table.text.utf8.count, scriptBytes: table.webKitSource.utf8.count)
    }

    private func report(_ site: String, _ all: [Sample], tableBytes: Int, scriptBytes: Int) {
        let samples = all.filter { $0.round >= Self.warmup }
        func of(_ arm: Arm) -> [Sample] { samples.filter { $0.arm == arm.rawValue } }
        let control = of(.control), timed = of(.timed)
        let controlFrames = control.flatMap(\.frames), timedFrames = timed.flatMap(\.frames)
        let controlMain = control.compactMap(\.main), timedMain = timed.compactMap(\.main)
        let frameCost = mean(timedFrames) - mean(controlFrames)
        let mainCost = mean(timedMain) - mean(controlMain)
        let dcl = (off: of(.off).map(\.dcl), on: of(.on).map(\.dcl))
        let load = (off: of(.off).map(\.load), on: of(.on).map(\.load))
        print("""
            shield perf \(site): script \(scriptBytes) bytes (table \(tableBytes)), \(Self.rounds) rounds x \(Self.frames) frames
              subframe: timed mean \(fmt(mean(timedFrames))) ms, control \(fmt(mean(controlFrames))) ms, cost \(fmt(frameCost)) ms; medians \(fmt(median(timedFrames)))/\(fmt(median(controlFrames))), p95 \(fmt(percentile(timedFrames, 0.95)))/\(fmt(percentile(controlFrames, 0.95)))
              main frame: timed mean \(fmt(mean(timedMain))) ms, control \(fmt(mean(controlMain))) ms, cost \(fmt(mainCost)) ms
              DOMContentLoaded: off median \(fmt(median(dcl.off))) ms, on \(fmt(median(dcl.on))) ms; load: off \(fmt(median(load.off))) ms, on \(fmt(median(load.on))) ms
            """)
        let folder = ProcessInfo.processInfo.environment["YAB_PERF_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("shield-scriptlets-perf-\(site).json")
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file) }
        print("  raw: \(file.path)")
        let budget = site == "match" ? 1.0 : 0.3
        #expect(frameCost <= budget, "\(site): \(fmt(frameCost)) ms a subframe, over \(budget) ms")
        #expect(mainCost <= budget, "\(site): \(fmt(mainCost)) ms the main frame, over \(budget) ms")
    }

    private func mean(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count) }
    private func median(_ values: [Double]) -> Double { percentile(values, 0.5) }
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    private func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

    // MARK: - the pages

    /// A site the lists have no scriptlets for: the script finds nothing and returns.
    @Test func aPageWithNoRulesPaysLittleAFrame() async throws {
        try await run(site: "nomatch", base: "https://news.test/")
    }

    /// yts.gg, whose calls run in every frame (nowoif arms each new frame's window).
    @Test func aMatchedPagePaysLittleAFrame() async throws {
        try await run(site: "match", base: "https://yts.gg/")
    }
}

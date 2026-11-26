import AppKit
import WebKit
import os

// Every page's process, counted, and a check that a page let go of goes.
//
// A tab put to sleep or closed gives its page back by dropping its web view
// (Tab.discard); WebKit ends the page's process when the last view in it
// goes. Nothing used to check that it did. A view something still holds,
// a closure, an observer, a window, keeps its whole process running, a
// hundred megabytes and more, under a tab that says it is asleep. So:
//
// - In development builds and test runs, a view, a closed tab and its
//   scripts' controller are expected gone a second after they are let go,
//   and said loudly if not (DuckDuckGo's ensureObjectDeallocated). Never in
//   the build people use, and never a crash.
// - WebKit's own list of its page processes, with the views each serves,
//   gives the count and the memory, for memory relief and the bench.
//
// Why one ended, when WebKit says, is PageEnds.swift.

@MainActor
enum PageProcesses {
    struct Process {
        let pid: Int32
        /// The views it serves now. Nil when WebKit won't say.
        let views: [NSView]?
        /// Its memory as Activity Monitor's Memory, nil once it has gone.
        let footprint: UInt64?
    }

    /// Lightweight page process pids only: skips per-process footprint syscalls
    /// and webViews KVC on the main thread (MemoryCeiling).
    static func pids() -> [Int32]? {
        dispatchPrecondition(condition: .onQueue(.main))
        let remote = ChromiumProcess.shared.livePages.compactMap(\.contentProcess).filter { $0 > 0 }
        let selector = NSSelectorFromString("_webContentProcessInfo")
        guard WKProcessPool.responds(to: selector) else { return remote.isEmpty ? nil : Array(Set(remote)) }
        return autoreleasepool {
            guard let list = WKProcessPool.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
                return remote.isEmpty ? nil : Array(Set(remote))
            }
            let pid = NSSelectorFromString("pid")
            let webKit = list.compactMap { info -> Int32? in
                guard info.responds(to: pid), let number = (info.value(forKey: "pid") as? NSNumber)?.int32Value, number > 0
                else { return nil }
                return number
            }
            return Array(Set(webKit + remote))
        }
    }

    /// WebKit's list of every page process it runs (the private class
    /// method `+[WKProcessPool _webContentProcessInfo]`). Main thread
    /// only: WebKit frees what it is read from on the main thread, and
    /// DuckDuckGo met a use-after-free reading it from another. Nil on a
    /// WebKit without it.
    static func census() -> [Process]? {
        dispatchPrecondition(condition: .onQueue(.main))
        let remote = Dictionary(grouping: ChromiumProcess.shared.livePages.compactMap { page in
            page.contentProcess.map { ($0, page) }
        }, by: { $0.0 }).map { pid, entries in
            Process(pid: pid, views: entries.map { $0.1 }, footprint: Browser.footprint(pid))
        }
        let selector = NSSelectorFromString("_webContentProcessInfo")
        guard WKProcessPool.responds(to: selector) else { return remote.isEmpty ? nil : remote }
        // The list and what is in it kept for as long as they are read.
        return autoreleasepool {
            guard let list = WKProcessPool.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
            let pid = NSSelectorFromString("pid"), webViews = NSSelectorFromString("webViews")
            return list.compactMap { info -> Process? in
                guard info.responds(to: pid), let number = (info.value(forKey: "pid") as? NSNumber)?.int32Value, number > 0
                else { return nil }
                // A process with no page in it yet (WebKit's spare, warmed
                // for the next tab) answers nil: none, not "won't say".
                let views = info.responds(to: webViews) ? info.value(forKey: "webViews") as? [WKWebView] ?? [] : nil
                return Process(pid: number, views: views, footprint: Browser.footprint(number))
            } + remote
        }
    }

    /// What putting each view's page to sleep would give back: its
    /// process's memory, shared out among the views that process serves.
    /// A tab opened by another's script shares its opener's process, and
    /// sleeping one of the two leaves the process, and most of its memory,
    /// where it was. Nil when WebKit won't say who serves whom.
    static func shares() -> [ObjectIdentifier: UInt64]? {
        guard let all = census(), all.allSatisfy({ $0.views != nil }) else { return nil }
        var out: [ObjectIdentifier: UInt64] = [:]
        for process in all {
            guard let views = process.views, !views.isEmpty, let size = process.footprint else { continue }
            for view in views { out[ObjectIdentifier(view)] = size / UInt64(views.count) }
        }
        return out
    }

    /// For the bench: every page process, its memory and its tabs, what
    /// lingered after it was let go, and why pages ended lately.
    static func report(_ browser: Browser) -> [String: Any] {
        let all = census()
        let tabs = browser.everyTab
        var rows: [[String: Any]] = []
        for process in all ?? [] {
            var row: [String: Any] = ["pid": Int(process.pid), "mb": Int((process.footprint ?? 0) >> 20)]
            if let views = process.views {
                row["views"] = views.count
                row["tabs"] = tabs.filter { tab in views.contains { $0 === tab.builtPage } }.map(Bench.short)
            }
            rows.append(row)
        }
        return [
            "known": all != nil,
            "count": all?.count ?? 0,
            "mb": Int((all ?? []).reduce(UInt64(0)) { $0 + ($1.footprint ?? 0) } >> 20),
            "processes": rows,
            "built": tabs.filter { $0.builtPage != nil }.count,
            "lingering": Lingering.seen,
            "followed": Lingering.timeline,
            "ended": FeedbackDiagnostics.shared.events().filter { $0.kind == .webProcessTerminated }
                .map { ["reason": $0.reason ?? "", "age": $0.ageSeconds] as [String: Any] },
        ]
    }
}

/// Development builds and test runs: what was let go is gone a second
/// later, or it is said, loudly, in the log and to the bench.
@MainActor
enum Lingering {
    /// Never in the build people use.
    static let watching = Store.development || Store.testing
    /// What was still there, for the bench (`processes`).
    private(set) static var seen: [String] = []
    private static let log = Logger(subsystem: "dev.serafim.fast", category: "Lingering")

    /// Each thing let go, followed until it goes: when it did, for the
    /// bench (`processes`' followed), to tell a page held for good from
    /// one a busy Mac ends a little late.
    private struct Followed {
        let what: String
        let detail: String
        let since: CFTimeInterval
        weak var object: AnyObject?
        var goneAfter: Double?
    }
    private static var followed: [Followed] = []
    private static var following: Timer?

    /// The last ones let go: what, which, and how long until it went, or
    /// how long it has stayed.
    static var timeline: [[String: Any]] {
        let now = CACurrentMediaTime()
        return followed.suffix(80).map { item in
            var row: [String: Any] = ["what": item.what, "detail": item.detail]
            if let gone = item.goneAfter { row["gone_after"] = (gone * 100).rounded() / 100 }
            else { row["alive_for"] = ((now - item.since) * 100).rounded() / 100 }
            return row
        }
    }

    /// A quarter of a second at a time while something let go is still
    /// there: when each one went.
    private static func follow() {
        guard following == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                for index in followed.indices where followed[index].goneAfter == nil && followed[index].object == nil {
                    followed[index].goneAfter = now - followed[index].since
                }
                // Followed a minute at most: what is there then is said.
                if !followed.contains(where: { $0.goneAfter == nil && now - $0.since < 60 }) {
                    timer.invalidate()
                    following = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        following = timer
    }

    /// `object` should be gone `after` seconds from now; `what` says what it
    /// was, `detail` which (a tab's address, "the spare").
    static func expectGone(_ object: AnyObject, _ what: String, detail: String = "", after: TimeInterval = 1) {
        guard watching else { return }
        followed.append(Followed(what: what, detail: detail, since: CACurrentMediaTime(), object: object))
        if followed.count > 200 { followed.removeFirst(followed.count - 200) }
        follow()
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak object] in
            guard let object else { return }
            let line = "\(what) (\(type(of: object))) is still alive \(after) s after it was let go: something holds it, and its page's process with it"
            log.fault("\(line, privacy: .public)")
            NSLog("yab: LINGERING %@", line)
            seen.append(what)
            if seen.count > 50 { seen.removeFirst(seen.count - 50) }
        }
    }
}

import AppKit
import WebKit

// What pages left behind, collected while nobody is using the Mac.
//
// JavaScriptCore collects garbage when a page allocates. A page out of
// sight allocates next to nothing, so whatever it dropped stays: what a web
// app let go of before it was hidden, the parts of a document a tab
// navigated away from. With 30 tabs of real sites, each sent on twice, one
// collection gave back 7 to 11% of everything (765 MB of 6875, 634 of 6456,
// 363 of 4923, 446 of 6400), and a second one a moment later nothing more:
// nothing had collected it by itself (docs/evidence/night-memory-2026-10-14.md).
// Busy sites make more as they go, so what it keeps off is less than that
// between two collections. WebKit collects on its
// own only when macOS says memory is short. Chrome's V8 does: its memory
// reducer collects a renderer that has gone quiet, a few times over.
//
// So, at most every fifteen minutes, when pages have navigated since the
// last time, nobody has touched the Mac for a minute or Yab has been in the
// background for one, and no tab is playing sound, every page process
// collects once (`_garbageCollectJavaScriptObjects…`,
// WebKit's collection in every content process of the pool). A minute
// without a key or the mouse is when a pause of a few tens of milliseconds
// in the page on screen goes unseen; someone listening to a film or a call
// isn't away. YAB_COLLECT=0 turns it off, for the A/B; YAB_COLLECT_EVERY and
// YAB_COLLECT_IDLE (seconds) shorten the waits in a test run.
@MainActor
enum Garbage {
    static let on = ProcessInfo.processInfo.environment["YAB_COLLECT"] != "0"
    private static let selector = NSSelectorFromString("_garbageCollectJavaScriptObjectsForTesting")

    /// At most this often.
    static let every: TimeInterval = seconds("YAB_COLLECT_EVERY") ?? 15 * 60
    /// Only after this long without a key, a click or the mouse moving.
    static let idle: TimeInterval = seconds("YAB_COLLECT_IDLE") ?? 60

    private static func seconds(_ name: String) -> TimeInterval? {
        guard Store.testing, let text = ProcessInfo.processInfo.environment[name], let value = Double(text), value > 0
        else { return nil }
        return value
    }

    private static var timer: Timer?
    private static var last = Date()
    private static var lastCachePurge = Date()
    /// Main-frame navigations armed when it last collected (PageScripts).
    private static var navigated = 0
    /// How many times it has collected, for the bench.
    private(set) static var count = 0

    /// Since when Yab hasn't been the active app; nil while it is.
    private static var awaySince: Date?
    private static var watches: [NSObjectProtocol] = []

    static func start() {
        guard on, timer == nil, Web.pool.responds(to: selector) else { return }
        let center = NotificationCenter.default
        awaySince = NSApp.isActive ? nil : Date()
        watches = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Garbage.awaySince = Date() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Garbage.awaySince = nil }
            },
        ]
        let look = min(60, every / 2)
        timer = Timer.scheduledTimer(withTimeInterval: look, repeats: true) { _ in
            MainActor.assumeIsolated { Garbage.consider() }
        }
        timer?.tolerance = look / 2
    }

    private static func consider() {
        guard Date().timeIntervalSince(last) >= every else { return }
        let now = PageScripts.counts.asked
        guard now != navigated else { return }
        // Away: nobody at the Mac for a minute, or working in another app
        // for a minute, where a pause in Yab's pages goes unseen too.
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let elsewhere = awaySince.map { Date().timeIntervalSince($0) } ?? 0
        guard quiet >= idle || elsewhere >= idle else { return }
        guard !Tab.anyNoisy else { return }
        navigated = now
        collect()
    }

    /// Every page process collects its garbage now, and periodically trims
    /// WebKit's in-memory resource cache while idle (cookies and disk cache
    /// stay untouched).
    static func collect() {
        let now = Date()
        if Web.pool.responds(to: selector) {
            last = now
            count += 1
            Web.pool.perform(selector)
        }
        guard now.timeIntervalSince(lastCachePurge) >= 30 * 60 else { return }
        lastCachePurge = now
        var stores: [WKWebsiteDataStore] = [Store.websites]
        for store in Spaces.madeStores.values where !stores.contains(where: { $0 === store }) { stores.append(store) }
        for store in stores {
            store.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {}
        }
    }
}

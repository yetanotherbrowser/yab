import Foundation
import Darwin

/// What "it lags" was, the last five minutes of it, for feedback
/// (FeedbackDiagnostics): the main thread's hitches of 100 ms or more, and
/// how long the things a hand does took, a tab switch, a new tab, a close,
/// back and forward, a page's first paint. Numbers and kinds only.
///
/// Main thread only. The watchdog's observer (Watchdog.step) writes the
/// hitches and settles a pending action as the loop goes to sleep; the
/// browser starts actions and feedback reads, all on the main thread, so
/// nothing here locks. Each kind of entry is a fixed ring: adding one is a
/// few stores, never an allocation, so a hitch costs the loop nothing more.
final class Lag: @unchecked Sendable {
    static let shared = Lag()

    enum Kind: String, CaseIterable {
        /// From the click or key to the end of the main loop's pass that
        /// showed it: the work it cost, SwiftUI's update and Core
        /// Animation's commit included.
        case tabSwitch, newTab, closeTab
        /// From ⌘[ or ⌘] to the page on screen, painted or brought back
        /// from WebKit's cache.
        case backForward
        /// From a navigation's start to its first text or picture painted.
        case paint
    }

    struct Hitch: Equatable { let ageSeconds: Int; let durationMs: Int }
    struct Timing: Equatable { let ageSeconds: Int; let kind: Kind; let ms: Int }

    static let window: TimeInterval = 300
    static let hitchThreshold: TimeInterval = 0.1

    /// A fixed ring: the newest `capacity`, oldest overwritten.
    struct Ring<Element> {
        private var slots: [Element?]
        private var next = 0
        private(set) var count = 0
        init(capacity: Int) { slots = Array(repeating: nil, count: capacity) }
        var capacity: Int { slots.count }
        mutating func add(_ element: Element) {
            slots[next] = element
            next = (next + 1) % slots.count
            count = min(count + 1, slots.count)
        }
        /// Oldest first.
        var elements: [Element] {
            (0..<count).compactMap { slots[(next - count + $0 + slots.count) % slots.count] }
        }
    }

    private var hitchRing = Ring<(at: TimeInterval, seconds: TimeInterval)>(capacity: 128)
    private var timingRing = Ring<(at: TimeInterval, kind: Kind, seconds: TimeInterval)>(capacity: 256)
    private let clock: () -> TimeInterval

    /// Seconds on the mach clock, the watchdog's, which stops while the
    /// Mac sleeps as the main loop does.
    static func uptime() -> TimeInterval { Double(mach_absolute_time()) * Watchdog.ticks }

    init(clock: @escaping () -> TimeInterval = Lag.uptime) { self.clock = clock }

    // MARK: - writing

    /// A gap of `seconds` in the main loop's pass that ended at `at`.
    func hitch(_ seconds: TimeInterval, at: TimeInterval? = nil) {
        hitchRing.add((at ?? clock(), seconds))
    }

    func timing(_ kind: Kind, seconds: TimeInterval, at: TimeInterval? = nil) {
        guard seconds.isFinite, seconds >= 0 else { return }
        timingRing.add((at ?? clock(), kind, seconds))
    }

    /// `kind` began just now; it is timed until the main loop next goes to
    /// sleep (`settle`). One started while another waits leaves the first's
    /// start: the pass that shows both is the first one's wait as well.
    func begin(_ kind: Kind) {
        guard Watchdog.enabled, pending == nil else { return }
        pending = (kind, mach_absolute_time())
    }

    /// The watchdog reads this at every sleep, so it is one word to test.
    private(set) var pending: (kind: Kind, start: UInt64)?

    /// The loop going to sleep at `now`, mach ticks.
    func settle(at now: UInt64) {
        guard let (kind, start) = pending else { return }
        pending = nil
        guard now > start else { return }
        timing(kind, seconds: Double(now - start) * Watchdog.ticks, at: Double(now) * Watchdog.ticks)
    }

    // MARK: - reading

    /// Oldest first, the last five minutes.
    func hitches() -> [Hitch] {
        let now = clock()
        return hitchRing.elements.compactMap { entry in
            let age = max(0, now - entry.at)
            guard age <= Self.window else { return nil }
            return Hitch(ageSeconds: Int(age), durationMs: Self.ms(entry.seconds))
        }
    }

    func timings() -> [Timing] {
        let now = clock()
        return timingRing.elements.compactMap { entry in
            let age = max(0, now - entry.at)
            guard age <= Self.window else { return nil }
            return Timing(ageSeconds: Int(age), kind: entry.kind, ms: Self.ms(entry.seconds))
        }
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int(min(seconds, 86_400) * 1000) }
}

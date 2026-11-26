import Foundation
import Darwin

// What the main thread spends its time on during everyday use
// (docs/main-thread-budget.md, evals/perf/budget.py).
//
// Two views, both off unless a test run asks for them with YAB_BUDGET=1, and
// nothing else:
//
// - Every pass of the main run loop, from waking to going back to sleep,
//   counted by how long it held the thread: over 2, 16, 50, 100 and 250 ms.
//   With the main thread's own time on a core and the wall time since the
//   last read, that is the main thread's cost per minute and its stalls.
// - Named chunks of data and IO work (`MainBudget.chunk`): how often each
//   ran, its total, worst and how many runs took over 2 ms, split by where
//   it ran, so work moved off the main thread shows up as still done, just
//   elsewhere.
//
// When off, a chunk costs one load of a constant and runs its work.

enum MainBudget {
    static let enabled: Bool = {
        guard Store.testing else { return false }
        let env = ProcessInfo.processInfo.environment
        return env["YAB_BUDGET"] == "1"
    }()

    struct Tally {
        var count = 0
        var total: TimeInterval = 0
        var worst: TimeInterval = 0
        var over2 = 0

        mutating func add(_ seconds: TimeInterval) {
            count += 1
            total += seconds
            worst = max(worst, seconds)
            if seconds >= 0.002 { over2 += 1 }
        }

        var json: [String: Any] {
            ["count": count, "total_ms": ms(total), "worst_ms": ms(worst), "over2": over2]
        }
    }

    /// Times `work` under `name`, on whichever thread runs it.
    @discardableResult
    static func chunk<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(name, ProcessInfo.processInfo.systemUptime - start, main: Thread.isMainThread) }
        return try work()
    }

    /// The same for async work: the time from start to end, which for work
    /// off the main thread includes its waits.
    @discardableResult
    static func chunk<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await work() }
        let start = ProcessInfo.processInfo.systemUptime
        let main = pthread_main_np() != 0
        defer { record(name, ProcessInfo.processInfo.systemUptime - start, main: main) }
        return try await work()
    }

    /// A chunk that spans a whole function: `let span = MainBudget.begin("x");
    /// defer { span?.end() }`. Nil, and free, when off.
    struct Span {
        let name: String
        let start: TimeInterval
        let main: Bool
        func end() { MainBudget.record(name, ProcessInfo.processInfo.systemUptime - start, main: main) }
    }

    static func begin(_ name: String) -> Span? {
        guard enabled else { return nil }
        return Span(name: name, start: ProcessInfo.processInfo.systemUptime, main: Thread.isMainThread)
    }

    static func record(_ name: String, _ seconds: TimeInterval, main: Bool) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if main { onMain[name, default: Tally()].add(seconds) } else { offMain[name, default: Tally()].add(seconds) }
    }

    /// Starts watching the main run loop. Called once on the main thread.
    static func start() {
        guard enabled, observer == nil, Thread.isMainThread else { return }
        mainPort = pthread_mach_thread_np(pthread_self())
        lock.lock(); since = ProcessInfo.processInfo.systemUptime; cpuSince = mainCPU(); lock.unlock()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            if activity == .afterWaiting {
                woke = now
            } else if woke > 0 {
                let held = now - woke
                woke = 0
                lock.lock()
                passes.add(held)
                if held >= 0.016 { passBuckets.0 += 1 }
                if held >= 0.05 { passBuckets.1 += 1 }
                if held >= 0.1 { passBuckets.2 += 1 }
                if held >= 0.25 { passBuckets.3 += 1 }
                lock.unlock()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Everything since the last read (or the start), and with `reset`
    /// starts counting again from now.
    static func read(reset: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = mainCPU()
        let wall = now - since
        let out: [String: Any] = [
            "enabled": enabled,
            "wall_s": (wall * 100).rounded() / 100,
            "main_cpu_ms": ms(cpu - cpuSince),
            "passes": passes.json.merging([
                "over16": passBuckets.0, "over50": passBuckets.1, "over100": passBuckets.2, "over250": passBuckets.3,
            ]) { $1 },
            "main": onMain.mapValues(\.json),
            "background": offMain.mapValues(\.json),
        ]
        if reset {
            since = now; cpuSince = cpu
            passes = Tally(); passBuckets = (0, 0, 0, 0)
            onMain = [:]; offMain = [:]
        }
        return out
    }

    // MARK: -

    private static let lock = NSLock()
    private static var observer: CFRunLoopObserver?
    private static var mainPort: thread_act_t = 0
    /// Touched only by the observer, on the main thread.
    nonisolated(unsafe) private static var woke: TimeInterval = 0
    nonisolated(unsafe) private static var since: TimeInterval = 0
    nonisolated(unsafe) private static var cpuSince: TimeInterval = 0
    nonisolated(unsafe) private static var passBuckets = (0, 0, 0, 0)
    nonisolated(unsafe) private static var passes = Tally()
    nonisolated(unsafe) private static var onMain: [String: Tally] = [:]
    nonisolated(unsafe) private static var offMain: [String: Tally] = [:]

    private static func ms(_ seconds: TimeInterval) -> Double { (seconds * 10000).rounded() / 10 }

    /// The main thread's time on a core so far.
    private static func mainCPU() -> TimeInterval {
        guard mainPort != 0 else { return 0 }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard read == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds + info.system_time.seconds)
            + TimeInterval(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
}

import Foundation

// Where the main thread stops answering, and what it was doing then.
//
// A watchdog on a thread of its own asks the main thread for a moment every
// 20 ms. An answer that takes 100 ms or more is a hitch somebody can see,
// the spinner stops, a click waits, and is written down with the phase the
// app said it was in, so "the Mac froze while bringing things over" becomes
// "passwords.save held the main thread for 4.2 s". With it, how much of the
// stall the main thread spent on a core, and how often it was found
// waiting on something. Low CPU can mean a synchronous wait on another
// process or a thread that was not scheduled; inspect stacks and host load
// before attributing the pause to contention.
//
// Off unless asked for: YAB_HANGS=1 on a test run turns it on, and
// ./hangs.sh does the rest, a fresh world, one import, the report. Code
// marks what it is doing with `Hangs.phase`, which costs a word when the
// watchdog is off; Watchdog, the one every build runs, reads it too.

enum Hangs {
    /// A hitch as long as this is written down; in a debug build, a
    /// shorter one too (DebugLog).
    static let threshold: TimeInterval = DebugLog.freezes ? 0.05 : 0.1

    static let enabled: Bool = (Store.testing && ProcessInfo.processInfo.environment["YAB_HANGS"] != nil) || DebugLog.freezes

    struct Stall {
        let at: Date
        let seconds: TimeInterval
        let phase: String
        /// Of it, on a core.
        var working: TimeInterval = 0
    }

    /// What the app is doing now, as the report will name it. Set from
    /// anywhere; the watchdog reads it when the main thread answers.
    /// Kept in every build, a word: the watchdog of every build names it
    /// beside a stall (Watchdog).
    static func phase(_ name: String) {
        lock.lock(); current = name; lock.unlock()
        guard enabled else { return }
        note("phase \(name)")
    }

    /// Resets the phase to idle only when nothing else replaced it since.
    static func clear(if expected: String) {
        lock.lock()
        if current == expected { current = "idle" }
        lock.unlock()
    }

    /// The phase named last.
    static var now: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Times `work` as one phase, on whatever thread it is called from.
    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = ProcessInfo.processInfo.systemUptime
        phase(name)
        defer {
            let took = ProcessInfo.processInfo.systemUptime - start
            note(String(format: "done  %@ %.0f ms%@", name, took * 1000, Thread.isMainThread ? " (main thread)" : ""))
        }
        return try work()
    }

    /// Times work done off the main thread without naming it the phase: a
    /// stall of the main thread meanwhile is the main thread's own, and
    /// would otherwise be put down to whatever a background queue reads
    /// (Settings' first build was "browsers.find", row 1039).
    @discardableResult
    static func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let took = ProcessInfo.processInfo.systemUptime - start
            note(String(format: "done  %@ %.0f ms%@", name, took * 1000, Thread.isMainThread ? " (main thread)" : " (off the main thread)"))
        }
        return try work()
    }

    static func start() {
        guard enabled, watcher == nil else { return }
        // Started on the main thread: its port, for what it does in a stall.
        if Thread.isMainThread { mainPort = pthread_mach_thread_np(pthread_self()) }
        try? FileManager.default.removeItem(at: file)
        note("watching the main thread, stalls of \(Int(threshold * 1000)) ms and more")
        let thread = Thread { watch() }
        thread.name = "hangs"
        thread.qualityOfService = .userInteractive
        watcher = thread
        thread.start()
    }

    /// Everything seen so far, worst first, as ./hangs.sh prints it.
    static func report() -> String {
        lock.lock(); let seen = stalls; lock.unlock()
        guard !seen.isEmpty else { return "no stalls of \(Int(threshold * 1000)) ms or more" }
        var byPhase: [String: (count: Int, total: TimeInterval, worst: TimeInterval, working: TimeInterval)] = [:]
        for stall in seen {
            var entry = byPhase[stall.phase] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.total += stall.seconds
            entry.worst = max(entry.worst, stall.seconds)
            entry.working += stall.working
            byPhase[stall.phase] = entry
        }
        var lines = ["\(seen.count) stalls, \(String(format: "%.1f", seen.map(\.seconds).reduce(0, +))) s of main thread lost, "
                     + "\(String(format: "%.1f", seen.map(\.working).reduce(0, +))) s of it on a core"]
        for (phase, entry) in byPhase.sorted(by: { $0.value.total > $1.value.total }) {
            lines.append(String(format: "  %-28@ %3d × worst %5.0f ms, total %6.0f ms, on a core %6.0f ms", phase as NSString, entry.count,
                                entry.worst * 1000, entry.total * 1000, entry.working * 1000))
        }
        return lines.joined(separator: "\n")
    }

    /// How the main thread has answered since the last time this was asked:
    /// every ping counted, the ones that missed a frame at 60 Hz, the ones a
    /// person feels, the ones written down as stalls, and the worst. For
    /// ./load, which asks between steps.
    static func lag() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let out: [String: Any] = [
            "pings": pings, "over17": over17, "over50": over50, "over100": over100,
            "worst_ms": (worst * 10000).rounded() / 10,
            "observer_over100": observerOver100,
            "observer_worst_ms": (observerWorst * 10000).rounded() / 10,
        ]
        pings = 0; over17 = 0; over50 = 0; over100 = 0; worst = 0
        observerOver100 = 0; observerWorst = 0
        return out
    }

    /// Next to the world's own files, so a run leaves its log where
    /// ./hangs.sh looks for it.
    static var file: URL { Store.file("hangs.log") }

    static func note(_ line: String) {
        guard enabled else { return }
        let stamped = String(format: "%.3f  ", Date().timeIntervalSince(started)) + line + "\n"
        // Diagnostic file I/O must not hold the main thread or the phase lock.
        let destination = file
        logQueue.async {
            let data = Data(stamped.utf8)
            try? FileHandle.standardError.write(contentsOf: data)
            if let handle = try? FileHandle(forWritingTo: destination) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else { try? data.write(to: destination) }
        }
    }

    /// A ping ends when the main callback runs, even if the observing thread
    /// is not scheduled again until much later. The observer delay is separate.
    final class Ping: @unchecked Sendable {
        struct Reply {
            let latency: TimeInterval
            let working: TimeInterval
            let answered: TimeInterval
            let phase: String
        }
        private let lock = NSLock()
        private let began: TimeInterval
        private let cpu: TimeInterval
        private var value: Reply?

        init(at: TimeInterval, cpu: TimeInterval) { began = at; self.cpu = cpu }
        func complete(at: TimeInterval, cpu: TimeInterval, phase: String) {
            lock.lock(); defer { lock.unlock() }
            guard value == nil else { return }
            value = Reply(latency: max(0, at - began), working: max(0, cpu - self.cpu), answered: at, phase: phase)
        }
        var reply: Reply? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: - the watchdog

    private static let logQueue = DispatchQueue(label: "yab.hangs-log", qos: .utility)
    private static let stacks = enabled && (ProcessInfo.processInfo.environment["YAB_HANG_STACKS"] == "1" || DebugLog.freezes)
    private static let lock = NSLock()
    private static var current = "idle"
    private static var stalls: [Stall] = []
    private static var watcher: Thread?
    private static var mainPort: thread_act_t = 0
    private static let started = Date()
    private static var pings = 0, over17 = 0, over50 = 0, over100 = 0
    private static var worst: TimeInterval = 0
    private static var observerOver100 = 0
    private static var observerWorst: TimeInterval = 0

    /// The main thread's time on a core so far, and whether it waits on
    /// something now rather than being ready to run.
    private static func main() -> (cpu: TimeInterval, waiting: Bool)? {
        guard mainPort != 0 else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard read == KERN_SUCCESS else { return nil }
        let cpu = TimeInterval(info.user_time.seconds + info.system_time.seconds)
            + TimeInterval(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        return (cpu, info.run_state == TH_STATE_WAITING)
    }

    private static func watch() {
        while true {
            let asked = Date()
            let began = ProcessInfo.processInfo.systemUptime
            let answered = DispatchSemaphore(value: 0)
            let before = main()?.cpu ?? 0
            let ping = Ping(at: began, cpu: before)
            let requestedPhase = now
            DispatchQueue.main.async {
                let at = ProcessInfo.processInfo.systemUptime
                let cpu = main()?.cpu ?? before
                ping.complete(at: at, cpu: cpu, phase: now)
                answered.signal()
            }
            // Waits as long as it takes: a stall is measured whole, not cut
            // off at some timeout and counted twice. Looked in on every 10 ms
            // meanwhile: waiting on something, or ready to run.
            var looks = 0, waits = 0
            var captured = false
            while answered.wait(timeout: .now() + 0.01) == .timedOut {
                looks += 1
                if main()?.waiting == true { waits += 1 }
                // Opt-in diagnostic only: a sample adds overhead and is never
                // part of a performance baseline. At most one stack per ping.
                if stacks, !captured, ping.reply == nil,
                   ProcessInfo.processInfo.systemUptime - began >= threshold {
                    captured = true
                    let start = ProcessInfo.processInfo.systemUptime
                    let stack = Watchdog.captureMainStack(port: mainPort)
                    let end = ProcessInfo.processInfo.systemUptime
                    let completed = ping.reply?.answered
                    let overlap = completed.map { $0 >= end } ?? true
                    note(String(format: "STACK ping %.6f capture %.6f...%.6f pending-through-capture %@ requested %@\n%@",
                                began, start, end, overlap ? "yes" : "no", requestedPhase, stack))
                    DebugLog.note("freeze-stack", ["ping": began, "phase": requestedPhase, "stack": stack])
                }
            }
            guard let reply = ping.reply else { continue }
            let took = reply.latency
            let working = reply.working
            let observerDelay = max(0, ProcessInfo.processInfo.systemUptime - reply.answered)
            lock.lock()
            pings += 1
            if took >= 0.017 { over17 += 1 }
            if took >= 0.05 { over50 += 1 }
            if took >= 0.1 { over100 += 1 }
            worst = max(worst, took)
            observerWorst = max(observerWorst, observerDelay)
            if observerDelay >= threshold { observerOver100 += 1 }
            lock.unlock()
            if observerDelay >= threshold {
                note(String(format: "OBSERVER delayed %.0f ms after main answered in %.0f ms; ping %.6f",
                            observerDelay * 1000, took * 1000, began))
            }
            if took >= threshold {
                lock.lock()
                let phase = reply.phase
                stalls.append(Stall(at: asked, seconds: took, phase: phase, working: working))
                lock.unlock()
                note(String(format: "STALL %.0f ms in %@, %.0f ms of it on a core, found waiting %d of %d looks; observer delay %.0f ms; ping %.6f; requested %@",
                            took * 1000, phase, working * 1000, waits, looks, observerDelay * 1000, began, requestedPhase))
                DebugLog.note("freeze", ["ms": DebugLog.ms(took), "cpu_ms": DebugLog.ms(working), "phase": phase,
                                         "requested": requestedPhase, "waiting": waits, "looks": looks, "ping": began,
                                         "since": DebugLog.ms(Date().timeIntervalSince(asked))])
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

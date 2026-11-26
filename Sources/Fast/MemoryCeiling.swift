import Darwin
import Foundation

// The last word on a page's memory, said off the main thread.
//
// A page grown heavy is put to sleep or loaded again by the stuck watch
// (Stuck.swift's `lighten`), once a minute, on the main thread. Three
// agents working in Yab at once (2026-10-22) froze the main thread, and a
// page an agent drove grew to 39 GB with nothing left to look. WebKit
// itself ends only pages out of sight past its limit, and an agent's pages
// count as seen. So: every few seconds, from a queue of its own, every page
// process's memory is read, and one past the ceiling is ended. The tab then says what happened, as for
// any page that ended (Dialogs.swift).
//
// The pages are named by the main thread when it can (`publish`); frozen,
// the last ones it named are still watched, and the page that froze it is
// among them.

enum MemoryCeiling {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "memory.ceiling", qos: .utility)
    nonisolated(unsafe) private static var pages: [Int32: UInt64] = [:]
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var naming: DispatchSourceTimer?
    nonisolated(unsafe) private static var override: UInt64 = 0
    nonisolated(unsafe) private static var pageCount: Int?
    nonisolated(unsafe) private static var latest: Sample?
    nonisolated(unsafe) private static var agentsWorking = false
    nonisolated(unsafe) private static var pace: TimeInterval = quick

    /// Every few seconds while an agent works or a page is a quarter of the
    /// way to the ceiling, two gigabytes at the least; every 15 seconds
    /// otherwise. A page grows gigabytes a minute, so one far from the
    /// ceiling can't reach it between two slow looks, and the main thread's
    /// census of page processes ran every five seconds all day for nothing.
    static let quick: TimeInterval = 5
    static let slow: TimeInterval = 15

    static func every(agents: Bool, largest: UInt64, ceiling: UInt64) -> TimeInterval {
        agents || largest >= ceiling / 4 ? quick : slow
    }

    /// Numbers from the existing watch, with no process or page identifiers.
    struct Sample {
        let at: TimeInterval
        let yabFootprintBytes: UInt64?
        let webProcessCount: Int?
        let measuredWebProcessCount: Int
        let largestWebProcessFootprintsBytes: [UInt64]

        init(at: TimeInterval, yabFootprintBytes: UInt64?, webProcessCount: Int?, footprints: [UInt64]) {
            self.at = at
            self.yabFootprintBytes = yabFootprintBytes
            self.webProcessCount = webProcessCount
            measuredWebProcessCount = footprints.count
            largestWebProcessFootprintsBytes = Array(footprints.sorted(by: >).prefix(3))
        }
    }

    static var sample: Sample? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Half the Mac's memory, between 8 and 24 GB, or `memory.ceiling` in
    /// MB for the bench. No page needs more; one that took it took the Mac.
    static var ceiling: UInt64 {
        lock.lock(); defer { lock.unlock() }
        if override > 0 { return override }
        let half = ProcessInfo.processInfo.physicalMemory / 2
        return min(max(half, 8 << 30), 24 << 30)
    }

    /// Started once, at launch.
    static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let set = Store.settings.double(forKey: "memory.ceiling")
        if set > 0 { override = UInt64(set) << 20 }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + quick, repeating: quick, leeway: .seconds(1))
        source.setEventHandler { look() }
        source.resume()
        timer = source
        // WebKit's own list of its page processes, read where it may be.
        let names = DispatchSource.makeTimerSource(queue: .main)
        names.schedule(deadline: .now() + 1, repeating: quick, leeway: .seconds(1))
        names.setEventHandler {
            MainActor.assumeIsolated {
                let agents = BrowserWindows.shared.browsers.contains { $0.everyTab.contains { $0.worker != nil } }
                publish(PageProcesses.pids(), agents: agents)
            }
        }
        names.resume()
        naming = names
    }

    /// The page processes running now, handed off from the main thread so
    /// process birth-time syscalls stay off MainActor.
    static func publish(_ pids: [Int32]?, agents: Bool = false) {
        queue.async {
            var next: [Int32: UInt64] = [:]
            for pid in pids ?? [] { if let born = started(pid) { next[pid] = born } }
            lock.lock()
            pages = next
            pageCount = pids.map { Set($0).count }
            let was = agentsWorking
            agentsWorking = agents
            // An agent seen starting is weighed now, not a slow look on. An
            // agent's page starts small: a slow look to the census is far
            // short of what it takes to grow to a quarter of the ceiling.
            // Under the lock, so a look finishing meanwhile can't put it back.
            if agents, !was {
                pace = quick
                timer?.schedule(deadline: .now(), repeating: quick, leeway: .seconds(1))
                naming?.schedule(deadline: .now() + quick - 1, repeating: quick, leeway: .milliseconds(500))
            }
            lock.unlock()
        }
    }

    private static func look() {
        lock.lock()
        let watched = pages
        let count = pageCount
        lock.unlock()
        let limit = ceiling
        var footprints: [UInt64] = []
        for (pid, born) in watched {
            guard let size = footprint(pid), started(pid) == born else { continue }
            footprints.append(size)
            guard size > limit else { continue }
            let sent = kill(pid, SIGKILL)
            if sent != 0 {
                let failure = errno
                // The main thread may be frozen: no fresh census will put a
                // failed attempt back. Only a process already gone retires.
                guard failure == ESRCH else {
                    Watchdog.note("page \(pid) past its memory ceiling could not be ended (error \(failure)): watching it again")
                    continue
                }
            } else {
                Watchdog.note(String(format: "page %d at %.1f GB, past the ceiling of %.1f GB: ended",
                                     pid, Double(size) / Double(1 << 30), Double(limit) / Double(1 << 30)))
            }
            lock.lock()
            pages[pid] = nil
            lock.unlock()
        }
        let measured = Sample(at: ProcessInfo.processInfo.systemUptime, yabFootprintBytes: footprint(getpid()),
                              webProcessCount: count, footprints: footprints)
        lock.lock()
        latest = measured
        let next = every(agents: agentsWorking, largest: footprints.max() ?? 0, ceiling: limit)
        if next != pace {
            pace = next
            let leeway = DispatchTimeInterval.seconds(next > quick ? 5 : 1)
            // The census just ahead of each look, so a page opened since is weighed at it.
            timer?.schedule(deadline: .now() + next, repeating: next, leeway: leeway)
            naming?.schedule(deadline: .now() + next - 1, repeating: next, leeway: .milliseconds(500))
        }
        lock.unlock()
    }

    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { raw in
            raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : nil
    }

    private static func started(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }
}

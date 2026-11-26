import Foundation
import Darwin

// Where the main thread stopped for a second or more, in every build, kept
// in a short log beside the world's files (stalls.log), and sent along with
// a crash report while those are sent (Crashes, Settings › About).
//
// Nothing here wakes the main thread. The main run loop is watched from
// inside by an observer, which notes the time at each step of its pass: a
// step a second or more after the one before it, with no sleep between
// them, is a stall, measured whole. A timer on a queue of its own is set as
// the loop wakes, if it isn't set already, and fires a second or two later
// (a wide leeway, for the system to fold it into other wakes): if the
// loop has slept since, it is left unset until the next wake; if the loop
// is awake and has moved, it is set again for a second after the last step;
// if it hasn't moved, the stall is still going on and is written down at
// once, with where the main thread is (its stack, read with the thread held
// for a moment), so a stall that ends with the app being forced to quit
// still leaves its line. So the timer fires at most once a second, and only
// in a second the app was awake in. Setting it at every wake and putting it
// off at every sleep instead cost 48 million instructions over a 1.5 s
// scroll, a dispatch timer's every change being a message to its queue.
//
// The same steps keep the last five minutes of hitches, a gap of 100 ms or
// more, for feedback (Lag): a compare at every step and, at a hitch, a few
// stores into a fixed ring on the main thread, no timer, no queue, no
// stack. At every sleep a tab switch or other action still waiting is
// timed (Lag.begin), one load when there is none.
//
// Hangs.swift is the other watchdog, for test runs: every hitch of 100 ms,
// by pinging the main thread fifty times a second, which costs wakes and is
// only for measuring.

enum Watchdog {
    /// A stall this long is written down.
    static let threshold: TimeInterval = 1
    /// YAB_WATCHDOG=0 turns it off, for measuring what it costs.
    static let enabled = ProcessInfo.processInfo.environment["YAB_WATCHDOG"] != "0"

    static var file: URL { Store.file("stalls.log") }

    /// Four words the main thread writes at every step of its loop and the
    /// timer reads: the last step, in mach ticks; 1 while the loop sleeps
    /// after it; the step a stall the timer wrote down began at; 1 while
    /// the timer is set. Plain words, not behind a lock: each is written
    /// whole, a step is a few loads and stores, and a word read a moment
    /// stale costs the timer one more look, never a wrong stall.
    private static let words: UnsafeMutablePointer<UInt64> = {
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 4)
        words.initialize(repeating: 0, count: 4)
        words[1] = 1
        return words
    }()
    private static let (last, asleep, told, armed) = (0, 1, 2, 3)

    private static let queue = DispatchQueue(label: "yab.watchdog", qos: .utility)
    private nonisolated(unsafe) static var timer: DispatchSourceTimer?
    private nonisolated(unsafe) static var observer: CFRunLoopObserver?
    private nonisolated(unsafe) static var main: thread_act_t = 0
    static let ticks: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()
    private static let limit = UInt64(threshold / ticks)
    private static let hitchLimit = UInt64(Lag.hitchThreshold / ticks)

    /// Once, on the main thread, at launch.
    @MainActor
    static func start() {
        guard enabled, observer == nil else { return }
        main = pthread_mach_thread_np(pthread_self())
        let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        timer.setEventHandler { fired() }
        timer.schedule(deadline: .distantFuture, leeway: .seconds(1))
        timer.resume()
        self.timer = timer
        // The steps a pass has between its sleeps, and the sleep itself:
        // entering and leaving a loop inside one adds nothing to measure.
        let steps: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeSources, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, steps.rawValue, true, Int.max) { _, activity in
            step(going: activity == .beforeWaiting)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Each step of the main loop's pass, on the main thread.
    static func step(going: Bool) {
        let now = mach_absolute_time()
        let was = words[last], wasAsleep = words[asleep] == 1
        words[last] = now
        words[asleep] = going ? 1 : 0
        if !wasAsleep, was > 0, now > was, now - was >= hitchLimit {
            let seconds = Double(now - was) * ticks
            Lag.shared.hitch(seconds, at: Double(now) * ticks)
            if now - was >= limit {
                let phase = Hangs.now
                queue.async { ended(seconds, phase: phase, began: was) }
            }
        }
        if going, Lag.shared.pending != nil { Lag.shared.settle(at: now) }
        if !going, words[armed] == 0 {
            words[armed] = 1
            timer?.schedule(deadline: .now() + threshold, leeway: .seconds(1))
        }
    }

    /// On the queue, a second after the loop woke with the timer unset.
    private static func fired() {
        let now = mach_absolute_time()
        let stepped = words[last]
        // Asleep: nothing to watch until it wakes and sets it again.
        guard words[asleep] == 0, stepped > 0 else {
            words[armed] = 0
            return
        }
        let since = now > stepped ? now - stepped : 0
        guard since >= limit else {
            // Busy, but moving: looked at again a second after its last step.
            timer?.schedule(deadline: .now() + threshold - Double(since) * ticks, leeway: .seconds(1))
            return
        }
        // Stuck. Written down once, now, with where it is; the next step,
        // the stall's end, sets the timer again.
        guard words[told] != stepped else { return }
        words[told] = stepped
        words[armed] = 0
        let stack = backtrace()
        write(String(format: "%@  stalling %.1f s so far, phase %@\n", stamp(), Double(since) * ticks, Hangs.now) + stack)
    }

    private static func ended(_ seconds: Double, phase: String, began: UInt64) {
        let seen = words[told] == began
        write(String(format: "%@  stall %.1f s, phase %@%@\n", stamp(), seconds, phase, seen ? "" : " (ended before it was read)"))
    }

    /// A line of the browser's own beside the stalls: something it did
    /// about pages that stopped (Stuck.swift), for the next report.
    static func note(_ line: String) {
        let at = Date()
        NSLog("yab: %@", line)
        queue.async { write("\(stamp(at))  \(line)\n") }
    }

    /// One formatter, used on the queue alone: making one for every line,
    /// its time zone read afresh each time, was most of what writing a stall cost.
    private nonisolated(unsafe) static let stamps = ISO8601DateFormatter()

    private static func stamp(_ at: Date = Date()) -> String {
        stamps.string(from: at)
    }

    /// Appended, the file kept to its last 32 KB once past 64. The throwing
    /// FileHandle calls only: the old write(_:) raises an Objective-C
    /// exception when the disk is full or the file is gone, which nothing
    /// catches (crash #28, 0.0.23).
    private static func write(_ text: String) {
        let data = Data(text.utf8)
        let file = file
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            let size = (try? handle.offset()) ?? 0
            try? handle.close()
            if size > 64 * 1024, let all = try? Data(contentsOf: file) {
                var kept = all.suffix(32 * 1024)
                if let line = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[(line + 1)...] }
                try? Data(kept).write(to: file, options: .atomic)
            }
        } else {
            try? data.write(to: file)
        }
    }

    /// What the log holds, the newest part, for a crash report.
    static func recent(_ most: Int = 16 * 1024) -> String? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return String(decoding: data.suffix(most), as: UTF8.self)
    }

    // MARK: - the main thread's stack

    /// The main thread held for the time it takes to follow its frame
    /// pointers, a few microseconds, then each address named from outside.
    private static func backtrace() -> String { captureMainStack(port: main) }

    /// Also used by the opt-in test watchdog. Each caller owns its storage;
    /// allocate it before suspending a thread that may hold allocator locks.
    static func captureMainStack(port: thread_act_t) -> String {
        #if arch(arm64)
        guard port != 0, port != pthread_mach_thread_np(pthread_self()) else { return "" }
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 64)
        defer { frames.deallocate() }
        var count = 0
        guard thread_suspend(port) == KERN_SUCCESS else { return "" }
        var registers = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &registers) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &size)
            }
        }
        if got == KERN_SUCCESS {
            let strip: UInt = 0x0000_7FFF_FFFF_FFFF
            frames[0] = UInt(registers.__pc) & strip
            frames[1] = UInt(registers.__lr) & strip
            count = 2
            var fp = UInt(registers.__fp)
            var pair: (UInt, UInt) = (0, 0)
            while count < 64, fp != 0, fp & 7 == 0 {
                var read: mach_vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &pair) {
                    mach_vm_read_overwrite(mach_task_self_, mach_vm_address_t(fp), 16, mach_vm_address_t(UInt(bitPattern: $0)), &read)
                }
                guard ok == KERN_SUCCESS, read == 16, pair.1 != 0 else { break }
                frames[count] = pair.1 & strip
                count += 1
                // Frames go up the stack; one that doesn't is the end.
                guard pair.0 > fp else { break }
                fp = pair.0
            }
        }
        thread_resume(port)
        var lines = ""
        for index in 0..<count {
            let address = frames[index]
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let path = info.dli_fname {
                let image = (String(cString: path) as NSString).lastPathComponent
                let offset = address - UInt(bitPattern: info.dli_fbase)
                let name = info.dli_sname.map { String(cString: $0) } ?? ""
                lines += String(format: "    %2d %@ +0x%lx %@\n", index, image, offset, name)
            } else {
                lines += String(format: "    %2d 0x%lx\n", index, address)
            }
        }
        return lines
        #else
        return ""
        #endif
    }
}

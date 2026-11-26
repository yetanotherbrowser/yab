import AppKit
import OSLog

/// A missing clean-quit marker is evidence of an unclean exit, not its cause.
/// No URLs, titles, page content, or native-host messages enter this journal.
final class CrashSessionLedger: @unchecked Sendable {
    struct Extension: Codable, Equatable, Sendable {
        var id: String
        var version: String
        var enabled: Bool
    }
    struct Death: Codable, Equatable, Sendable {
        var at: Date
        var kind: String
        var pid: Int32?
        var reason: String
        var code: Int?
    }
    struct Run: Codable, Equatable, Sendable {
        var id = UUID()
        var started: Date
        var observed: Date
        var version: String
        var build: Int
        var os: String
        var pid: Int32
        var uptime: Double = 0
        var tabs = 0
        var windows = 0
        var asleepTabs = 0
        var extensions: [Extension] = []
        var processIDs: [Int32] = []
        var deaths: [Death] = []
        var memoryBytes: UInt64?
        var memoryPressure: String?
        var memoryPressureAt: Date?
    }

    let folder: URL
    private let queue = DispatchQueue(label: "yab.crash-session", qos: .utility)
    /// The run as last looked at, which a pressure notice or a death writes.
    private var current: Run?
    /// The run as the marker has it, which a look is measured against.
    private var written: Run?
    var marker: URL { folder.appendingPathComponent("active.json") }
    var pendingFolder: URL { folder.appendingPathComponent("pending", isDirectory: true) }

    init(folder: URL) { self.folder = folder }

    /// Called only after OneYab owns the world's lock. Archive before replacing
    /// the marker, so repeated failed launches cannot erase the preceding run.
    func begin(_ run: Run) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: marker.path) {
                let old = try JSONDecoder().decode(Run.self, from: Data(contentsOf: marker))
                try write(old, to: pendingFolder.appendingPathComponent(old.id.uuidString + ".json"))
            }
            try write(run, to: marker)
            current = run; written = run
        }
    }

    func update(_ change: @escaping @Sendable (inout Run) -> Void) {
        queue.async { [self] in
            guard var run = current else { return }
            change(&run)
            do {
                try write(run, to: marker)
                current = run; written = run
            } catch { NSLog("Crashes: session observation could not be saved: %@", String(describing: error)) }
        }
    }

    /// How old the marker's observation may grow before a look writes it
    /// whatever. Under the slowest look's minute, so a look a moment early
    /// still writes; a look just short of it skips, which
    /// CrashExitLogs.unwritten allows for.
    static let beat: TimeInterval = 45

    /// The heartbeat: written when the run reads differently from the marker,
    /// or when what the marker says was last observed is a beat old. Every
    /// observation rewrote the file, four times a minute all day, with the
    /// same numbers. Kept as the latest look either way.
    func observe(at: Date, _ change: @escaping @Sendable (inout Run) -> Void) {
        queue.async { [self] in
            guard var run = current, let was = written else { return }
            change(&run)
            run.observed = at
            current = run
            guard at.timeIntervalSince(was.observed) >= Self.beat || !Self.same(run, was) else { return }
            do {
                try write(run, to: marker)
                written = run
            } catch { NSLog("Crashes: session observation could not be saved: %@", String(describing: error)) }
        }
    }

    /// Memory moving this much is news, for an exit that ran out of it.
    static let memoryNews: UInt64 = 512 << 20

    /// The same run apart from the clock, and memory moving less than `memoryNews`.
    static func same(_ a: Run, _ b: Run) -> Bool {
        let was = a.memoryBytes ?? 0, now = b.memoryBytes ?? 0
        guard (was > now ? was - now : now - was) < memoryNews else { return false }
        var a = a
        a.observed = b.observed; a.uptime = b.uptime; a.memoryBytes = b.memoryBytes
        return a == b
    }

    /// Serialized after every queued observation, so none can recreate the
    /// marker after a clean quit. Used at the end of applicationWillTerminate.
    func finish() throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
            current = nil; written = nil
        }
    }

    func pending() throws -> [Run] {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: pendingFolder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: pendingFolder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(Run.self, from: Data(contentsOf: $0)) }
                .sorted { $0.started < $1.started }
        }
    }

    func acknowledge(_ run: Run) throws {
        try queue.sync {
            try FileManager.default.removeItem(at: pendingFolder.appendingPathComponent(run.id.uuidString + ".json"))
        }
    }

    private func write(_ run: Run, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(run).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum CrashExitLogs {
    struct Evidence: Codable, Equatable {
        var at: Date
        var source: String
        var kind: String
        var signal: Int?
        var status: Int?
        var correlatedPID: Int32?
        // Only fixed vocabulary and numeric fields; never the explanation text.
        var reason: String? = nil
        var namespace: String? = nil
        var code: UInt64? = nil
        var domain: Int? = nil
    }
    struct Result: Codable {
        var availability: String
        var from: Date
        var through: Date
        var entries: [Evidence]
    }

    /// Keep conclusions made from known words and numbers, never raw unified
    /// log text: such text may contain a page title or a native-host payload.
    static func evidence(at: Date, process: String, pid: Int32, message: String,
                         run: CrashSessionLedger.Run) -> Evidence? {
        let system = ["kernel", "launchd", "runningboardd", "watchdogd", "ReportCrash", "memorypressure"]
        let own = run.processIDs.contains(pid) && (process.lowercased() == "yab" || process.hasPrefix("YabCore"))
        let lower = message.lowercased()
        let namedPID = run.processIDs.first { value in
            message.range(of: "(?i)(?:\\b(?:pid|process(?: id)?)\\s*[:=/ ]\\s*\(value)\\b|\\[\(value)\\]|:\(value)\\])", options: .regularExpression) != nil
        }
        let globalPressure = system.contains(process) &&
            (lower.contains("memory pressure") || lower.contains("memorystatus"))
        guard own || (system.contains(process) && namedPID != nil) || globalPressure else { return nil }
        let termination = lower.contains("termination reason") || lower.contains("exit context") ||
            lower.contains("rbsprocessexitcontext") || lower.contains("rbsterminatecontext")
        let signals = ["sigkill": 9, "sigterm": 15, "sigsegv": 11, "sigabrt": 6, "sigtrap": 5, "sigbus": 10]
        let signal = signals.first { lower.contains($0.key) }?.value ?? number(in: lower, pattern: #"\b(?:signal|sig)\s*[:= ]\s*(\d{1,3})\b"#)
        // A Jetsam Boost assertion protects a process; it is not a kill.
        // SignalReady/SIGNAL readiness messages likewise carry no signal number.
        let killing = lower.range(of: #"\b(?:killed|killing|jetsammed)\b"#, options: .regularExpression) != nil
        let kind: String
        if (lower.contains("jetsam") || lower.contains("memorystatus")) && (killing || termination) { kind = "memory-kill" }
        else if lower.contains("watchdog") && (killing || termination || signal != nil) { kind = "watchdog" }
        else if termination { kind = "termination-reason" }
        else if globalPressure { kind = "memory-pressure" }
        else if signal != nil { kind = "signal" }
        else if lower.contains("exit") || lower.contains("terminat") || killing { kind = "exit" }
        else { return nil }
        let status = number(in: lower, pattern: #"\b(?:exit status|exit code|exit_status|status)\s*[:= ]\s*(\d{1,3})\b"#)
        let reason: String?
        if namedPID != nil && (lower.contains("force quit") || lower.contains("forcequit")) { reason = "force-quit" }
        else if namedPID != nil && kind == "memory-kill" {
            reason = lower.range(of: #"\bidle[- ]exit\b"#, options: .regularExpression) != nil ? "idle-exit" : "memory-kill"
        }
        else { reason = nil }
        let namespace = capture(in: lower, pattern: #"\bnamespace\s*[:= ]\s*(signal|jetsam|runningboard|watchdog|resource|dyld|codesigning)\b"#)?.uppercased()
        let codeText = termination ? capture(in: lower, pattern: #"\bcode\s*[:= ]\s*(0x[0-9a-f]+|[0-9]+)\b"#) : nil
        let code = codeText.flatMap { $0.hasPrefix("0x") ? UInt64($0.dropFirst(2), radix: 16) : UInt64($0) }
        return Evidence(at: at, source: own ? (process.lowercased() == "yab" ? "yab" : "YabCore") : process,
                        kind: kind, signal: signal, status: status, correlatedPID: namedPID ?? (own ? pid : nil),
                        reason: reason, namespace: namespace, code: code,
                        domain: termination ? number(in: lower, pattern: #"\bdomain\s*[:= ]\s*(\d+)\b"#) : nil)
    }

    private static func number(in text: String, pattern: String) -> Int? {
        capture(in: text, pattern: pattern).flatMap(Int.init)
    }

    private static func capture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// General pressure chatter must not evict the process's exit reason.
    /// Keep independent bounded histories, preserving chronological order.
    static func retain(_ value: Evidence, in entries: inout [Evidence]) {
        entries.append(value)
        let correlated = value.correlatedPID != nil
        let matching = entries.indices.filter { (entries[$0].correlatedPID != nil) == correlated }
        if matching.count > (correlated ? 32 : 8), let first = matching.first {
            entries.remove(at: first)
        }
    }

    /// The longest the marker goes unwritten while the main thread runs: a
    /// look just short of a beat skips writing, and Yab going behind can put
    /// the next one the slowest look later.
    static let unwritten = CrashSessionLedger.beat + CrashSessions.behind

    /// How long a hang may last before the exit and still be looked at, as
    /// when every 15 s look wrote and the exit was looked for 120 s after it.
    static let hang: TimeInterval = 120 - 15

    static let afterObservation = unwritten + hang

    /// The heartbeat bounds the unknown exit to shortly after the last
    /// observation. This is explicitly an observation window, not exit time.
    static func window(_ run: CrashSessionLedger.Run, now: Date) -> (from: Date, through: Date) {
        (run.observed.addingTimeInterval(-180), min(now, run.observed.addingTimeInterval(afterObservation)))
    }

    static func read(_ run: CrashSessionLedger.Run, now: Date = Date()) -> Result {
        let (from, through) = window(run, now: now)
        do {
            let store = try OSLogStore(scope: .system)
            let predicate = NSPredicate(format: "date >= %@ AND date <= %@ AND (processIdentifier IN %@ OR process IN %@)",
                                        from as NSDate, through as NSDate, run.processIDs.map { NSNumber(value: $0) } as NSArray,
                                        ["kernel", "launchd", "runningboardd", "watchdogd", "ReportCrash", "memorypressure"] as NSArray)
            let entries = try store.getEntries(at: store.position(date: from), matching: predicate)
            var kept: [Evidence] = []
            for case let entry as OSLogEntryLog in entries {
                if let value = evidence(at: entry.date, process: entry.process, pid: entry.processIdentifier,
                                        message: entry.composedMessage, run: run) {
                    retain(value, in: &kept)
                }
            }
            return Result(availability: "available; newest 32 PID-correlated and 8 global events", from: from, through: through, entries: kept)
        } catch {
            return Result(availability: "unavailable (error \((error as NSError).code))", from: from, through: through, entries: [])
        }
    }

    static func report(_ run: CrashSessionLedger.Run, logs: Result) throws -> Crashes.Report {
        let encoder = JSONEncoder()
        let session = try JSONSerialization.jsonObject(with: encoder.encode(run))
        let evidence = try JSONSerialization.jsonObject(with: encoder.encode(logs))
        let attributed = logs.entries.filter {
            $0.correlatedPID == run.pid && ($0.kind == "termination-reason" || $0.reason != nil || $0.signal != nil)
        }
        let indicator = attributed.isEmpty ? "No clean-quit marker; exit cause unknown" :
            "No clean-quit marker; system log contains PID-correlated termination evidence (see systemLog)"
        let head: [String: Any] = ["app_name": "yab", "app_version": run.version, "build_version": String(run.build),
                                   "bug_type": "YabUncleanExit", "incident_id": run.id.uuidString]
        let body: [String: Any] = ["procName": "yab", "exception": ["type": "UNCLEAN_EXIT"],
                                   "termination": ["namespace": "YabSession", "indicator": indicator],
                                   "uncleanExit": ["session": session, "systemLog": evidence,
                                                    "lastObservationIsNotExitTime": true], "threads": [], "usedImages": []]
        let header = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let text = Sanitizer.clean(String(decoding: header, as: UTF8.self) + "\n" + String(decoding: payload, as: UTF8.self))
        return Crashes.Report(text: text, bytes: text.utf8.count)
    }
}

@MainActor
enum CrashSessions {
    static let ledger = CrashSessionLedger(folder: Store.file("crash-sessions"))
    private static var timer: Timer?
    private static var memorySource: DispatchSourceMemoryPressure?
    private static var began: TimeInterval = 0
    private static var watches: [NSObjectProtocol] = []

    nonisolated static let inFront: TimeInterval = 15
    nonisolated static let behind: TimeInterval = 60

    /// How often the run is looked at: every 15 seconds while Yab is in
    /// front, every minute behind other apps.
    static func every(active: Bool) -> TimeInterval { active ? inFront : behind }

    /// The next look, one at a time. Yab coming forward only brings it
    /// sooner: switching apps back and forth never puts it off.
    private static func tick(active: Bool) {
        let at = Date().addingTimeInterval(every(active: active))
        if let timer, timer.isValid, timer.fireDate <= at { return }
        timer?.invalidate()
        let next = Timer(fire: at, interval: 0, repeats: false) { fired in
            // Crash #1010: assumeIsolated faults in executor lookup in a timer.
            AppKitMainThread.sync {
                guard timer === fired else { return }
                timer = nil
                tick(active: NSApp?.isActive == true)
                observe()
            }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    static func start() {
        guard !Store.unitTests, timer == nil else { return }
        let now = Date()
        began = ProcessInfo.processInfo.systemUptime
        let run = CrashSessionLedger.Run(started: now, observed: now, version: Updater.version,
                                         build: Updater.build, os: Updater.system, pid: getpid(), processIDs: [getpid()])
        do { try ledger.begin(run) }
        catch { NSLog("Crashes: session marker could not be created: %@", String(describing: error)) }
        tick(active: NSApp?.isActive == true)
        let center = NotificationCenter.default
        watches = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if timer != nil { tick(active: true) } }
            },
        ]
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard let event = memorySource?.data else { return }
                let pressure = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
                let at = Date()
                ledger.update { run in run.memoryPressure = pressure; run.memoryPressureAt = at }
            }
        }
        source.resume()
        memorySource = source
    }

    static func observe() {
        guard timer != nil else { return }
        let state = FeedbackDiagnostics.State.now()
        let at = Date(), uptime = max(0, ProcessInfo.processInfo.systemUptime - began)
        let ids = Set([getpid()] + [ChromiumProcess.shared.processID].compactMap { $0 } + ChromiumProcess.shared.livePages.compactMap(\.contentProcess))
        let extensions = state.extensions.compactMap { row -> CrashSessionLedger.Extension? in
            guard let id = row["id"] as? String, let version = row["version"] as? String, let enabled = row["enabled"] as? Bool else { return nil }
            return .init(id: id, version: version, enabled: enabled)
        }
        let tabs = state.tabs, windows = state.windows, asleep = state.asleepTabs
        let memory = state.memory.sample?.yabFootprintBytes
        ledger.observe(at: at) { run in
            run.uptime = uptime; run.tabs = tabs; run.windows = windows
            run.asleepTabs = asleep; run.extensions = extensions
            run.processIDs = Array(Set(run.deaths.compactMap(\.pid)).union(ids)).sorted()
            run.memoryBytes = memory
        }
    }

    static func died(kind: String, pid: Int32?, reason: String, code: Int?) {
        guard timer != nil else { return }
        let death = CrashSessionLedger.Death(at: Date(), kind: kind, pid: pid, reason: reason, code: code)
        ledger.update { run in
            run.deaths = Array((run.deaths + [death]).suffix(32))
            if let pid, !run.processIDs.contains(pid) { run.processIDs.append(pid) }
        }
        observe()
    }

    static func finish() {
        timer?.invalidate(); timer = nil
        for watch in watches { NotificationCenter.default.removeObserver(watch) }
        watches = []
        memorySource?.cancel(); memorySource = nil
        do { try ledger.finish() }
        catch { NSLog("Crashes: clean-quit marker could not be cleared: %@", String(describing: error)) }
    }
}

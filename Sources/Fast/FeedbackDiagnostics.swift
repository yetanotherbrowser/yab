import AppKit
import WebKit

/// Only typed events and numbers enter this buffer. Never pass error messages,
/// page URLs, request bodies, headers or console output into feedback.
@MainActor
final class FeedbackDiagnostics {
    static let shared = FeedbackDiagnostics()
    enum Kind: String, Codable {
        case navigationFailed, webProcessTerminated, tabClosed
        case extensionError, offscreenStarted, offscreenReady, offscreenFailed
        case pipDragged, pipGesture
        /// Whether a close reached the chat's model after wake (feedback 505).
        case chatClose, systemWoke
        /// Another browser's tabs couldn't be read; the code says why
        /// (TabImport.Trouble.code).
        case importFailed
        /// The actual runner that failed, with only its HTTP status as code.
        case claudeRequestFailed, codexRequestFailed, cursorRequestFailed, geminiRequestFailed
        /// Chromium's helper (YabCore) went away, and with it every Chromium
        /// page; those on screen load again by themselves (helperExited).
        /// `reason` says how (HelperEnd), `code` its exit status or signal.
        /// Before this, that reload left no trace (feedback #1984).
        case helperLost

        /// Events a site older than this build may not know yet, and
        /// turn the whole of the diagnostics down for (`snapshots`).
        static let newer: Set<Kind> = [.importFailed, .chatClose, .systemWoke, .helperLost,
                                      .claudeRequestFailed, .codexRequestFailed, .cursorRequestFailed, .geminiRequestFailed]
    }
    /// Only phases and two booleans, never a chat, tab, provider or its words.
    enum ChatClosePhase: Int, CaseIterable {
        case intent, skipped, applied, completed, superseded
    }
    struct Event: Encodable {
        let ageSeconds: Int
        let kind: Kind
        let code: Int?
        let domain: String?
        let extensionID: String?
        /// Why a page's process ended, PageEnd's word; its number, WebKit's
        /// own, is the code.
        let reason: String?
    }
    private struct Entry {
        let at: TimeInterval
        let kind: Kind
        let code: Int?
        let domain: String?
        let extensionID: String?
        let reason: String?
    }
    private var entries: [Entry] = []
    enum SleepReason: String, CaseIterable {
        case idle, memoryWarning, memoryCritical, heavyPage, stuckPage, manual, other
    }
    private struct Count {
        var total = 0
        var last: TimeInterval?
        mutating func record(at now: TimeInterval) { total += 1; last = now }
        func fields(at now: TimeInterval) -> [String: Any] {
            var out: [String: Any] = ["count": total]
            if let last { out["lastAgeSeconds"] = max(0, Int(now - last)) }
            return out
        }
    }
    private var sleeps: [SleepReason: Count] = [:]
    private var lastSleep: SleepReason?
    private var reloads = Count()
    private var lastReloadReason: PageEnd?
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// Launch totals outlive the five-minute event buffer.
    func slept(_ reason: SleepReason) {
        sleeps[reason, default: Count()].record(at: clock())
        lastSleep = reason
    }

    /// Chromium's helper went, as an event of the last five minutes.
    func helperLost(_ end: HelperEnd, code: Int?, recovering: Bool) {
        record(.helperLost, code: code, word: end.rawValue + (recovering ? "" : ".stopped"))
    }

    func reloadedAfterTermination(reason: PageEnd?) {
        reloads.record(at: clock())
        lastReloadReason = reason
    }

    struct Memory {
        var sample: MemoryCeiling.Sample?
        var sleepsTabs = false
        var configuredSleepAfterSeconds: TimeInterval = 0
        var sleepAfterSeconds: TimeInterval = 0
        var lowPower = false
        var thrift = false

        @MainActor static func now() -> Memory {
            let set = Store.settings.double(forKey: "sleep.after"), thrift = Thrift.on
            return Memory(sample: MemoryCeiling.sample, sleepsTabs: Store.settings.bool(forKey: "tabs.sleep"),
                          configuredSleepAfterSeconds: Browser.sleepAfter(set: set, thrift: false),
                          sleepAfterSeconds: Browser.sleepAfter(set: set, thrift: thrift),
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thrift: thrift)
        }
    }

    func memoryFields(_ memory: Memory) -> [String: Any] {
        let now = clock()
        var sleeping: [String: Any] = ["count": sleeps.values.reduce(0) { $0 + $1.total },
                                       "reasons": Dictionary(uniqueKeysWithValues: SleepReason.allCases.map {
                                           ($0.rawValue, (sleeps[$0] ?? Count()).fields(at: now))
                                       })]
        if let lastSleep, let last = sleeps[lastSleep]?.last {
            sleeping["lastReason"] = lastSleep.rawValue
            sleeping["lastAgeSeconds"] = max(0, Int(now - last))
        }
        var reloading = reloads.fields(at: now)
        if reloads.total > 0 {
            reloading["kind"] = Kind.webProcessTerminated.rawValue
            reloading["lastReason"] = lastReloadReason?.word ?? "unknown"
        }
        var out: [String: Any] = ["sampled": memory.sample != nil, "sleepsTabs": memory.sleepsTabs,
                                  "configuredSleepAfterSeconds": memory.configuredSleepAfterSeconds,
                                  "sleepAfterSeconds": memory.sleepAfterSeconds,
                                  "lowPower": memory.lowPower, "thrift": memory.thrift,
                                  "sleepsSinceLaunch": sleeping, "reloadsSinceLaunch": reloading]
        if let sample = memory.sample {
            out["sampleAgeSeconds"] = max(0, Int(now - sample.at))
            out["yabFootprintBytes"] = sample.yabFootprintBytes
            out["webProcessCount"] = sample.webProcessCount
            out["measuredWebProcessCount"] = sample.measuredWebProcessCount
            out["largestWebProcessFootprintsBytes"] = sample.largestWebProcessFootprintsBytes
        }
        return out
    }

    /// `code`: a number of our own, when there is no error to take one from.
    /// `reason`: why a page's process ended, as WebKit said, none when it
    /// didn't say. Kept as its word and, as the code, WebKit's number.
    func record(_ kind: Kind, error: Error? = nil, code: Int? = nil, extensionID: String? = nil, reason: PageEnd? = nil, word: String? = nil) {
        let now = clock()
        entries.removeAll { now - $0.at > 300 }
        let error = error as NSError?
        let domain = error.map { [NSURLErrorDomain, "WKErrorDomain"].contains($0.domain) ? $0.domain : "other" }
        entries.append(Entry(at: now, kind: kind, code: error?.code ?? code ?? reason?.rawValue, domain: domain,
                             extensionID: Self.storeID(extensionID), reason: word ?? reason?.word))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    /// Codes 0...19: phase * 4, plus open (1) and moving (2). These show
    /// whether a no-op close was already closed in the model or still moving.
    func chatClose(_ phase: ChatClosePhase, open: Bool, moving: Bool) {
        record(.chatClose, code: phase.rawValue * 4 + (open ? 1 : 0) + (moving ? 2 : 0))
    }

    /// A model label may have handed over to another explicitly connected
    /// plan. Record the runner, never an account, its error or request data.
    func providerFailure(cli: String, status: Int?) {
        let kind: Kind
        switch cli {
        case "claude": kind = .claudeRequestFailed
        case "codex": kind = .codexRequestFailed
        case "cursor": kind = .cursorRequestFailed
        case "gemini": kind = .geminiRequestFailed
        default: return
        }
        record(kind, code: status.flatMap { (400...599).contains($0) ? $0 : nil })
    }

    func events() -> [Event] {
        let now = clock()
        entries.removeAll { now - $0.at > 300 }
        return entries.map { Event(ageSeconds: max(0, Int(now - $0.at)), kind: $0.kind,
                                   code: $0.code, domain: $0.domain, extensionID: $0.extensionID, reason: $0.reason) }
    }

    static func storeID(_ value: String?) -> String? {
        guard let value, value.count == 32, value.utf8.allSatisfy({ (97...112).contains($0) }) else { return nil }
        return value
    }

    /// Keep just timestamp and duration from the existing watchdog journal.
    /// Phase labels and arbitrary stack text cannot carry user data into feedback.
    nonisolated static func stalls(_ text: String, now: Date = Date()) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").suffix(200).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 4, ["stall", "stalling"].contains(String(parts[1])),
                  let at = formatter.date(from: String(parts[0])),
                  (0...300).contains(now.timeIntervalSince(at)),
                  let seconds = Double(parts[2]), seconds.isFinite, (0...86400).contains(seconds),
                  ["s", "s,"].contains(String(parts[3])) else { return nil }
            return ["ageSeconds": Int(now.timeIntervalSince(at)), "durationMs": Int(seconds * 1000)]
        }
    }

    /// What to send, in turn while the site says no to the diagnostics:
    /// all of them, then, when they hold an event of `Kind.newer`, the same
    /// without those, so a site that doesn't know one yet still gets the
    /// stalls and the rest.
    func snapshots(stallLog: String, lag: Lag = .shared, page: [String: Any] = [:], behind: [String: Any] = [:], state: State? = nil) -> [String] {
        let recent = events()
        let known = recent.filter { !Kind.newer.contains($0.kind) }
        var state = state ?? State.now()
        state.page = page
        state.pageBehind = behind
        return ([recent] + (known.count < recent.count ? [known] : [])).compactMap {
            snapshot(of: $0, stalls: Self.stalls(stallLog), lag: lag, state: state)
        }
    }

    static let schemaVersion = 2
    static let most = 65536

    /// The browser and the Mac as they are at the send: counts, the
    /// screens' sizes and refresh rates, the Mac's model and memory, its
    /// power and heat, the extensions installed. No names, no addresses.
    struct State {
        var windows = 0, tabs = 0, asleepTabs = 0, loadedTabs = 0
        var screens: [[String: Any]] = []
        var system: [String: Any] = [:]
        var extensions: [[String: Any]] = []
        var memory = Memory()
        /// The tab in front, as its page sees itself (`pages()`), and
        /// another that draws a canvas when it draws none.
        var page: [String: Any] = [:]
        var pageBehind: [String: Any] = [:]

        @MainActor static func now() -> State {
            var state = State()
            let browsers = BrowserWindows.shared.browsers
            let tabs = browsers.flatMap(\.tabs).filter { !$0.shy }
            state.windows = browsers.count
            state.tabs = tabs.count
            state.asleepTabs = tabs.filter(\.asleep).count
            state.loadedTabs = tabs.filter { $0.builtPage != nil && !$0.asleep }.count
            state.screens = NSScreen.screens.prefix(16).map {
                ["x": Int($0.frame.minX), "y": Int($0.frame.minY),
                 "width": Int($0.frame.width), "height": Int($0.frame.height),
                 "scale": Double($0.backingScaleFactor), "maxFPS": $0.maximumFramesPerSecond]
            }
            let info = ProcessInfo.processInfo
            state.memory = Memory.now()
            state.system = [
                "model": FeedbackDiagnostics.model(), "memoryGB": Int(info.physicalMemory >> 30),
                "cores": info.activeProcessorCount, "lowPower": info.isLowPowerModeEnabled,
                "thermal": FeedbackDiagnostics.thermal(info.thermalState),
            ]
            if #available(macOS 15.4, *) {
                state.extensions = Extensions.shared.installed.compactMap { item in
                    guard let id = FeedbackDiagnostics.storeID(item.id) else { return nil }
                    var entry: [String: Any] = ["id": id, "version": FeedbackDiagnostics.version(item.version), "enabled": item.enabled]
                    let here = Extensions.onePasswordApp != nil
                    if let link = FeedbackDiagnostics.appLink(id, refused: Extensions.shared.unconnected,
                                                              answered: Extensions.shared.onePasswordAnswered, appHere: here) {
                        entry["app"] = link
                    }
                    return entry
                }.prefix(50).map { $0 }
            }
            return state
        }
    }

    /// For 1Password's extensions, what its Mac app said to Yab this run:
    /// "refused" (BrowserVerificationFailed, Yab not added in the app's
    /// Settings › Browser), "answered", "silent" (the app is on this Mac
    /// and nothing was heard yet), "noApp". Feedback #571 and #715 (row
    /// 907) said "it doesn't pick up the unlocked app" and their reports
    /// couldn't tell which. Nil for every other extension.
    @available(macOS 15.4, *)
    nonisolated static func appLink(_ id: String, refused: Set<String>, answered: Set<String>, appHere: Bool) -> String? {
        guard ExtensionNative.onePasswordExtensions.contains(id) else { return nil }
        if refused.contains(id) { return "refused" }
        if answered.contains(id) { return "answered" }
        return appHere ? "silent" : "noApp"
    }

    /// The tab in front as its page sees itself, for words a page draws
    /// blurry (feedback #57, #134, #155: Google Docs' canvas text soft while
    /// its buttons are sharp): the scale the page is told and the window's
    /// own, WebKit's view scale, the zoom, the screen's mode (points,
    /// pixels, and the panel's own pixels when macOS scales it), the
    /// largest canvases' size on the page against the pixels they hold,
    /// and how its document came in (woken from sleep, its view in no
    /// window, behind the tab in front). Always the tab in front, one with
    /// no canvas too. Numbers only, no address.
    ///
    /// `behind`: when the tab in front draws no canvas (a report is often
    /// sent from another tab than the one in trouble), the most recently
    /// used open page that does, of the next four, the same fields with
    /// `front` false. Sent as `pageBehind`, never in the front's place:
    /// #155's report read as if the tab in front were a Docs page in no
    /// window.
    static func pages() async -> (front: [String: Any], behind: [String: Any]) {
        let front = BrowserWindows.shared.activeBrowser?.active
        var seen: [String: Any] = [:]
        if let front { seen = await page(of: front, front: true) }
        guard (seen["canvasCount"] as? Int ?? 0) == 0 else { return (seen, [:]) }
        let others = BrowserWindows.shared.browsers.flatMap(\.tabs)
            .filter { $0 !== front && $0.webKitOnly("WebKit feedback metrics", build: false) != nil && !$0.asleep }
            .sorted { $0.touched > $1.touched }
        for tab in others.prefix(4) {
            let other = await page(of: tab, front: false)
            if (other["canvasCount"] as? Int ?? 0) > 0 { return (seen, other) }
        }
        return (seen, [:])
    }

    static func page(of tab: Tab, front: Bool) async -> [String: Any] {
        var out: [String: Any] = ["front": front, "woken": tab.arrival.woken, "engine": tab.engineKind.rawValue,
                                  "loadedOutOfWindow": tab.arrival.outOfWindow, "loadedBehind": tab.arrival.behind]
        if tab.asleep {
            out["asleep"] = true
            return out
        }
        // A Chromium page is awake all the same; only WebKit's own numbers
        // below are missing (#1927, #1930 came in saying "asleep" while
        // their page was being scrolled).
        guard let web = tab.webKitOnly("WebKit feedback metrics", build: false) else { return out }
        out.merge(await page(of: web)) { first, _ in first }
        return out
    }

    static func page(of web: WKWebView) async -> [String: Any] {
        var out: [String: Any] = ["pageZoom": Double(web.pageZoom), "magnification": Double(web.magnification),
                                  "inWindow": web.window != nil]
        if let scale = DeviceStage.scale(of: web) { out["viewScale"] = Double(scale) }
        if let window = web.window {
            out["backing"] = Double(window.backingScaleFactor)
            if let screen = window.screen { out["screen"] = mode(of: screen) }
        }
        let said: String? = await withCheckedContinuation { done in
            let once = Once(done)
            // A page that doesn't answer (a stuck one, often what the report is about) holds no one up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { once.finish(nil) } }
            web.evaluateJavaScript(pageScript, in: nil, in: pageWorld) { result in once.finish(try? result.get() as? String) }
        }
        out.merge(said.map(pageFields) ?? ["answered": false]) { first, _ in first }
        return out
    }

    private final class Once {
        var done: CheckedContinuation<String?, Never>?
        init(_ done: CheckedContinuation<String?, Never>) { self.done = done }
        func finish(_ value: String?) {
            done?.resume(returning: value)
            done = nil
        }
    }

    /// Its own world, so a page's devicePixelRatio of its own making isn't what is read.
    static let pageWorld = WKContentWorld.world(name: "yab-feedback")
    static let pageScript = """
    (() => {
      const all = document.querySelectorAll('canvas');
      const sized = [...all].slice(0, 400).map(c => { const r = c.getBoundingClientRect(); return [r.width, r.height, c.width, c.height]; })
        .filter(c => c[0] > 0 && c[1] > 0).sort((a, b) => b[0] * b[1] - a[0] * a[1]).slice(0, 4);
      return JSON.stringify({dpr: devicePixelRatio, innerWidth, outerWidth, canvasCount: all.length, canvases: sized});
    })()
    """

    /// What the page said, numbers kept in bounds and nothing else: each
    /// canvas as [CSS width, CSS height, backing width, backing height].
    nonisolated static func pageFields(_ json: String) -> [String: Any] {
        guard json.utf8.count < 8192, let said = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [:] }
        func whole(_ value: Any?) -> Int? {
            guard let number = value as? Double, number.isFinite, (0...1_000_000).contains(number) else { return nil }
            return Int(number.rounded())
        }
        var out: [String: Any] = [:]
        if let dpr = said["dpr"] as? Double, dpr.isFinite, dpr > 0, dpr <= 16 { out["dpr"] = dpr }
        for key in ["innerWidth", "outerWidth", "canvasCount"] { if let value = whole(said[key]) { out[key] = value } }
        out["canvases"] = (said["canvases"] as? [[Any]] ?? []).prefix(4).compactMap { row -> [Int]? in
            let numbers = row.compactMap(whole)
            return numbers.count == 4 ? numbers : nil
        }
        return out
    }

    /// A screen's mode: its size in points and pixels, the scale, and,
    /// when macOS draws it scaled (a MacBook Air's More Space), the panel's
    /// own pixels.
    static func mode(of screen: NSScreen) -> [String: Any] {
        var out: [String: Any] = ["width": Int(screen.frame.width), "height": Int(screen.frame.height),
                                  "scale": Double(screen.backingScaleFactor)]
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let mode = CGDisplayCopyDisplayMode(number) else { return out }
        out["pixelWidth"] = mode.pixelWidth
        out["pixelHeight"] = mode.pixelHeight
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(number, options) as? [CGDisplayMode] ?? []
        // kDisplayModeNativeFlag: the panel's own resolution.
        if let native = modes.first(where: { $0.ioFlags & 0x0200_0000 != 0 }) {
            out["nativeWidth"] = native.pixelWidth
            out["nativeHeight"] = native.pixelHeight
        }
        return out
    }

    /// Chrome manifest versions hold only digits and dots.
    nonisolated static func version(_ value: String) -> String {
        value.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? value : "unknown"
    }

    /// "Mac15,8": letters, digits and commas, nothing else.
    /// Read once: the crash heartbeat asked the kernel for it four times a
    /// minute, up to half a second each on a busy Mac.
    nonisolated static func model() -> String { readModel }

    private nonisolated static let readModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        let model = String(cString: chars)
        let fine = !model.isEmpty && model.count <= 32
            && model.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "," }
        return fine ? model : "unknown"
    }()

    nonisolated static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    func snapshot(of recent: [Event], stalls: [[String: Any]], lag: Lag, state: State) -> String? {
        guard let eventData = try? JSONEncoder().encode(recent),
              var events = (try? JSONSerialization.jsonObject(with: eventData)) as? [Any] else { return nil }
        var hitches: [[String: Any]] = lag.hitches().map { ["ageSeconds": $0.ageSeconds, "durationMs": $0.durationMs] }
        var timings: [[String: Any]] = lag.timings().map { ["ageSeconds": $0.ageSeconds, "kind": $0.kind.rawValue, "ms": $0.ms] }
        let memory = memoryFields(state.memory)
        // Past the site's limit, the oldest of the most numerous lists go
        // first, half at a time, until it fits.
        for _ in 0..<64 {
            let payload: [String: Any] = [
                "schemaVersion": Self.schemaVersion, "windowSeconds": 300, "events": events,
                "state": ["windows": state.windows, "tabs": state.tabs,
                          "asleepTabs": state.asleepTabs, "loadedTabs": state.loadedTabs,
                          "screens": state.screens] as [String: Any],
                "system": state.system, "extensions": state.extensions, "memory": memory,
                "stalls": stalls, "hitches": hitches, "timings": timings,
            ].merging(state.page.isEmpty ? [:] : ["page": state.page]) { first, _ in first }
                .merging(state.pageBehind.isEmpty ? [:] : ["pageBehind": state.pageBehind]) { first, _ in first }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
            if data.count <= Self.most { return String(data: data, encoding: .utf8) }
            let longest = max(events.count, timings.count, hitches.count)
            guard longest > 0 else { return nil }
            if events.count == longest { events.removeFirst((events.count + 1) / 2) }
            else if timings.count == longest { timings.removeFirst((timings.count + 1) / 2) }
            else { hitches.removeFirst((hitches.count + 1) / 2) }
        }
        return nil
    }
}

/// How Chromium's helper went, in a fixed word: never its error's text.
enum HelperEnd: String {
    /// It exited by itself (`code`, its status), or was ended by a signal
    /// (`code`, the signal: a crash or a kill).
    case exited, signal
    /// The connection went while the helper still ran: the client refused
    /// what it sent (a protocol violation), or its socket failed.
    case protocolViolation, transport, disconnected
    /// It never answered its first hello.
    case notStarted
}

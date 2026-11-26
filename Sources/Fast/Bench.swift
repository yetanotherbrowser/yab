import SwiftUI
import AppKit
import OSAKit
import WebKit
import ImageIO
import PDFKit
import SyncKit
import YabCoreClient

// A way for a script on this Mac to drive the browser you already have open,
// in tabs of its own, without ever taking the window from you.
//
// Off unless switched on (Settings › Agents or Developers). On, the app listens on a Unix
// socket in its own folder, readable by this user and nobody else, and the
// other end is checked for the same uid before a word is read, and in a
// shipped Yab for Yab's own code signature (BenchCaller). One JSON
// object per line in, one per line out, one request per connection. The
// tabs it opens sit at the end of your row with the agents' face on them, are never
// selected on your behalf, never enter the session or the history, and go
// when the script says so. `./bench` at the root of the repository speaks
// this protocol from the shell.
//
// Pages a script has opened but you are not looking at live in a window of
// their own, off every screen: WebKit lays out and paints a page only when
// it has a size and a window, and a snapshot of a page that has neither is
// a snapshot of nothing.

@MainActor
final class Bench {
    static let shared = Bench()
    private var awake: NSObjectProtocol?

    weak var browser: Browser?
    /// Tasks from the iPhone: their calls go to it and nowhere else (SyncCenter installs it).
    weak var remoteTaskReader: SyncTaskRead?
    /// The sync verb's Add a Device code (`invite`, `letin`).
    var benchInvite: SyncInvite?
    private var controlOnly = false
    private var socketFile: URL { controlOnly ? Store.file("test-control.sock") : Bench.socket }
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    let agentCapabilities = AgentCapabilityCache()

    /// Where the socket is. Beside the session file, so a test run's bench is
    /// as separate from the real one as everything else it keeps.
    static var socket: URL { Store.file("bench.sock") }

    /// A shipped yab's socket answers only what its own tools send: any
    /// program of this user's can reach it, so the file mode and the
    /// caller's user id say little. An agent's tools (Mcp) with a session,
    /// and with none, only what the command line (Cli, AgentCLI) asks
    /// before it has one: a session of its own, tasks started, followed,
    /// steered and stopped, the memory. Reading and acting in pages is an
    /// agent's, under an agent's rules; the rest is the bench's, for test
    /// runs and yab Dev.
    /// And a caller that isn't Yab's own code (BenchCaller) only whether
    /// Yab is running: nothing of the person's, mail least of all.
    nonisolated static func allowed(_ verb: String, session: Bool, yab: Bool = true, open: Bool = Store.testing || Store.development) -> Bool {
        if testVerbs.contains(verb) { return open }
        if open { return true }
        if !yab { return anyone.contains(verb) }
        if unattended.contains(verb) { return true }
        return session && (verb.hasPrefix("agent-") || agentVerbs.contains(verb))
    }
    /// The verbs agentCommand answers, by their starts and a few names.
    /// app-menu starts like app-status but is the bench's own (the Yab
    /// menu's update line, evals/updates/menu.py): sent to agentCommand, it
    /// was answered "doesn't know".
    nonisolated static func forAgents(_ verb: String) -> Bool {
        if verb == "app-menu" { return false }
        return verb.hasPrefix("agent") || verb.hasPrefix("hints-") || verb.hasPrefix("app-")
            || ["snapshot", "settle", "act", "press", "nav", "handoff", "handoff-wait"].contains(verb)
    }
    nonisolated static let unattended: Set<String> = [
        "agent-attach", "agent-caps", "agents", "agent-run", "agent-wait", "agent-stop", "agent-steer", "agent-queue",
        "agent-reply", "agent-browse", "agent-memory-read", "agent-memory-search", "agent-routines", "agent-routine-add",
        "agent-routine-remove", "agent-routine-run", "app-status", "app-quit", "app-serve", "app-import",
    ]
    /// What a caller that isn't Yab may ask: whether one is running, and which.
    nonisolated static let anyone: Set<String> = ["app-status"]
    /// Driving a page the way a person does, for evals and films: a test
    /// run's and yab Dev's only, though they start with agent-.
    nonisolated static let testVerbs: Set<String> = ["agent-mail-space", "agent-assistants", "agent-artifact-cards"]
    nonisolated static let agentVerbs: Set<String> = [
        "open", "close", "snapshot", "text", "shot", "act", "press", "nav", "settle", "wait", "handoff", "handoff-wait", "spaces",
    ]

    /// True while something is listening.
    private(set) var running = false

    /// Keys held with a press the bench makes: "cmd", "shift", "option",
    /// "control", in a list or one.
    static func flags(_ value: Any?) -> NSEvent.ModifierFlags {
        let names = value as? [String] ?? (value as? String).map { [$0] } ?? []
        let all: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "option": .option, "control": .control]
        return names.reduce(into: []) { $0.formUnion(all[$1] ?? []) }
    }

    /// Controls by name, where each is in the window (benchSpot), on a test
    /// run only.
    static var spots: [String: CGRect] = [:]
    /// How each Settings removal started by `extension-review-removal` ended.
    static var reviewedRemovals: [String: String] = [:]
    static let spotting = Store.testing

    /// The key code of a letter on a US keyboard, which is what WebKit reads
    /// alongside the characters; anything else goes as the space bar's.
    nonisolated static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "\u{1B}": 53,
        ]
        return codes[Character(character.lowercased())] ?? 49
    }

    /// Where the traffic lights are: each one's left edge and its center's
    /// height from the top, in the window's points.
    static func lights(of window: NSWindow) -> [[Int]] {
        Lights.rows(in: window.contentView).first { $0.visibleRect.width > 0 }?.spots ?? []
    }

    // MARK: - starting and stopping

    func startControl(for browser: Browser) {
        guard Store.testing, ProcessInfo.processInfo.environment["YAB_TEST_CONTROL"] == "1" else { return }
        controlOnly = true
        start(for: browser)
    }

    /// Every window's moves into full screen and out, keys, the desktop
    /// changing and the app's activation, in the stage's trace (stagetrace)
    /// beside the film of a page's own full screen (register 1089).
    private static var fullScreenTraced = false
    private static func traceFullScreen() {
        guard !fullScreenTraced else { return }
        fullScreenTraced = true
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: nil) { note in
                MainActor.assumeIsolated {
                    let window = note.object as? NSWindow
                    var more: [String: Any] = [
                        "window": window.map { String(describing: type(of: $0)) } ?? "",
                        "number": window?.windowNumber ?? 0,
                        "visible": window.map { $0.occlusionState.contains(.visible) } ?? false,
                    ]
                    if let window, NSStringFromClass(type(of: window)) == "WebCoreFullScreenWindow" {
                        more["behavior"] = window.collectionBehavior.rawValue
                        more.merge(geometry(of: window)) { a, _ in a }
                        if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
                            followGeometry(of: window)
                        }
                    }
                    StageView.mark("fs." + name.rawValue.replacingOccurrences(of: "Notification", with: ""), more)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { StageView.mark("fs.space") }
        }
    }

    /// WebKit's full-screen window as AppKit lays it out: its style, its
    /// frame, the part under its title bar, and where the page sits in it,
    /// for a strip along the top through the move (register 1089).
    private static func geometry(of window: NSWindow) -> [String: Any] {
        func box(_ r: CGRect) -> [Int] { [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }
        var out: [String: Any] = [
            "mask": window.styleMask.rawValue,
            "frame": box(window.frame),
            "layout": box(window.contentLayoutRect),
            "clearBar": window.titlebarAppearsTransparent,
            "screen": window.screen.map { box($0.frame) } ?? [],
        ]
        if let content = window.contentView {
            out["content"] = box(content.frame)
            out["safeTop"] = Int(content.safeAreaInsets.top)
            out["kids"] = content.subviews.prefix(4).map { "\(type(of: $0)) \(box($0.frame))" }
            if let web = Self.firstWeb(in: content) {
                out["web"] = box(web.convert(web.bounds, to: nil))
                if #available(macOS 26.0, *) { out["webInsetTop"] = Int(web.obscuredContentInsets.top) }
            }
        }
        if let frameView = window.contentView?.superview {
            out["theme"] = "\(type(of: frameView)) \(box(frameView.frame))"
            out["bar"] = frameView.subviews.filter { "\(type(of: $0))".contains("Titlebar") }
                .map { "\(type(of: $0)) \(box($0.frame)) \($0.isHidden ? "hidden" : "shown") a\(String(format: "%.2f", $0.alphaValue))" }
        }
        return out
    }

    private static func firstWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for kid in view.subviews { if let web = firstWeb(in: kid) { return web } }
        return nil
    }

    /// The same every frame for two seconds of a move.
    private static func followGeometry(of window: NSWindow) {
        let start = CACurrentMediaTime()
        var last = ""
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak window] in
                MainActor.assumeIsolated {
                    guard let window, CACurrentMediaTime() - start < 2 else { return }
                    let geo = geometry(of: window)
                    let key = "\(geo)"
                    if key != last { last = key; StageView.mark("fs.geo", geo) }
                    tick()
                }
            }
        }
        tick()
    }

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        if !controlOnly { Agents.shared.browser = browser }
        // Nor App Nap, which a test run behind other windows falls into.
        if Store.testing, !Store.measuring, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bench")
        }
        if Store.testing { Self.traceFullScreen() }
        let path = socketFile.path
        try? FileManager.default.createDirectory(
            at: socketFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        // Room for many callers at once: every tool call of every agent is a
        // connection of its own, and twenty agents at a time filled a queue
        // of eight, the ones past it refused as if the browser were gone.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(socketFile.path)
        clients.values.forEach { $0.drop() }
        clients = [:]
        running = false
        // The tabs a script left open go with it.
        if let browser {
            for tab in browser.tabs where tab.bench { browser.close(tab) }
        }
    }

    /// Every caller waiting, not one per wake: the queue empties at once.
    private func accept() {
        while take() {}
    }

    /// One caller taken in, or false when none is waiting.
    private func take() -> Bool {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return false }
        // Only this user. The file mode already says so; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return true
        }
        // A script that gives up before its answer, an agent stopped in the
        // middle of a long wait, must not take the browser with it: writing
        // to a socket nobody holds would otherwise be SIGPIPE, and the end.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        // Whose code it is, asked of the kernel before a word is read: a
        // test run and yab Dev answer every program, as the bench's scripts
        // speak to them straight.
        let yab = Store.testing || Store.development || BenchCaller.yab(fd)
        let client = Client(fd: fd) { [weak self] request, answer in
            self?.handle(request, yab: yab, answer)
        } gone: { [weak self] client in
            // Only this one: its descriptor's number may be a newer caller's.
            if self?.clients[client.fd] === client { self?.clients[client.fd] = nil }
        }
        clients[fd] = client
        return true
    }

    // MARK: - one connection

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let handle: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
        private let gone: (Client) -> Void
        private var answered = false
        /// Its descriptor is the writer's to close (`say`).
        private var handedOff = false

        init(
            fd: Int32,
            handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
            gone: @escaping (Client) -> Void
        ) {
            self.fd = fd
            self.handle = handle
            self.gone = gone
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request.
            if bytes.count > 4_000_000 {
                say(["error": "request too long"])
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(["error": "not a JSON object"])
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        /// Answers are written off the main thread: a big one (a screenshot,
        /// a page's text) to a caller slow to read held the whole browser
        /// in a loop of waits, and three agents at once froze it.
        private static let writer = DispatchQueue(label: "bench.answers", qos: .userInitiated, attributes: .concurrent)

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            if !source.isCancelled { source.cancel() }
            handedOff = true
            let fd = fd
            Client.writer.async(flags: DispatchWorkItemFlags(rawValue: 0)) { [self] in
                // JSONSerialization raises an Objective-C exception, not a Swift
                // error, on a value it can't write (NaN, infinity, a Date): `try?`
                // never sees it and the app goes, the reply empty (#381). What
                // can't be written is made writable first.
                let writable = JSONSerialization.isValidJSONObject(answer) ? answer : Bench.writable(answer) as? [String: Any] ?? [:]
                var out = (try? JSONSerialization.data(withJSONObject: writable)) ?? Data("{\"error\":\"unwritable answer\"}".utf8)
                out.append(0x0A)
                // A caller that stops reading is let go after half a minute.
                let limit = Date().addingTimeInterval(30)
                out.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                        if n <= 0 {
                            if errno == EAGAIN, Date() < limit { usleep(2000); continue }
                            break
                        }
                        sent += n
                    }
                }
                close(fd)
                DispatchQueue.main.async { self.gone(self) }
            }
        }

        func drop() {
            guard !handedOff else { return }
            handedOff = true
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(self)
        }
    }

    // MARK: - answers that can always be written

    /// A place or length in points as a whole number for an answer. A view
    /// caught mid-layout can be NaN or infinitely far, and `Int(_:)` traps
    /// on either, taking Yab down from inside a bench call (#381): those
    /// are 0 here.
    nonisolated static func whole(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(-1e15, min(1e15, value.rounded())))
    }

    /// `value` with everything JSON can't hold made something it can: a
    /// number that isn't finite is null, anything that isn't a string,
    /// number, list or object is its description.
    nonisolated static func writable(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]: return object.mapValues(writable)
        case let object as NSDictionary:
            var out: [String: Any] = [:]
            for (key, item) in object { out["\(key)"] = writable(item) }
            return out
        case let list as [Any]: return list.map(writable)
        case let list as NSArray: return list.map(writable)
        case is String, is NSString, is NSNull, is Bool: return value
        case let number as Double: return number.isFinite ? number : NSNull()
        case let number as CGFloat: return number.isFinite ? Double(number) : NSNull()
        case let number as Float: return number.isFinite ? Double(number) : NSNull()
        case let number as NSNumber:
            return JSONSerialization.isValidJSONObject([number]) ? number : NSNull()
        default:
            return JSONSerialization.isValidJSONObject([value]) ? value : String(describing: value)
        }
    }

    // MARK: - the commands

    func handle(_ request: [String: Any], yab: Bool, _ given: @escaping ([String: Any]) -> Void) {
        if controlOnly { handleControl(request, given); return }
        // Before anything reads the request: a program that isn't Yab's own
        // learns only whether Yab is running.
        guard yab || Bench.allowed(request["do"] as? String ?? "", session: request["session"] != nil, yab: false) else {
            given(["error": BenchCaller.refusal])
            return
        }
        // An assistant in the cloud's call, narrowed first (AssistantBoundary),
        // in the very window it then runs in: a tab of another is checked there.
        if let browser = target(request), AssistantBoundary.caller(request) != nil {
            switch AssistantBoundary.check(request, bench: self, browser: browser) {
            case .refuse(let why): given(["error": why])
            case .pass(let bound): handleBound(bound, given, in: browser)
            }
            return
        }
        handleBound(request, given)
    }

    /// Whitelisted native UI events and observations only, never agent tools.
    private func handleControl(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, ProcessInfo.processInfo.environment["YAB_TEST_CONTROL"] == "1", let browser else { answer(["error": "unavailable"]); return }
        let action = request["action"] as? String ?? "state"
        switch action {
        case "next": WelcomeStage.shared.pressPrimary()
        case "quiet": WelcomeStage.shared.pressQuiet()
        case "allow-context":
            guard browser.welcoming, WelcomeStage.shared.browser === browser,
                  WelcomeStage.shared.pretend.agents == nil, WelcomeStage.shared.beat == .access,
                  AgentSetupModel.shared.anyConnected else { answer(["error": "context card is not shown or enabled"]); return }
            WelcomeEnd.allowContext(WelcomeStage.shared)
        case "question-yes": Questions.shared.answer(true)
        case "question-no": Questions.shared.answer(false)
        case "ask-fixture-task": _ = Agents.shared.task("Explain this synthetic fixture", context: [], on: nil)
        case "daily-suggestions": AgentSetupModel.shared.turnOnSuggestions(browser.prefs)
        case "recurring-checks":
            guard !browser.welcoming, let hint = Hints.shared.rows.first(where: { $0.id == "setup.watch" }) else { answer(["error": "recurring-checks row is not shown"]); return }
            Hints.shared.take(hint, in: browser)
        case "quit": answer(["ok": true]); NSApp.terminate(nil); return
        case "winshot":
            guard let path = request["path"] as? String, let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"],
                  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: out).resolvingSymlinksInPath().path + "/") else { answer(["error": "media must stay in the job output"]); return }
            handleBound(["do": "winshot", "path": path], answer); return
        case "state": break
        default: answer(["error": "unknown UI action"]); return
        }
        WelcomeStage.shared.bench([:], browser) { state in
            var out = state
            out["pid"] = ProcessInfo.processInfo.processIdentifier
            out["world"] = Store.world ?? ""
            out["bench"] = browser.prefs.bench
            out["welcomed"] = browser.prefs.welcomed
            out["connected"] = AgentSetupModel.clis.filter { ProviderConsent.shared.allows($0) }
            out["counts"] = ConsentAudit.snapshot()
            out["sessions"] = Agents.shared.sessions.count
            out["agentTabs"] = browser.everyTab.filter { $0.agent != nil }.count
            out["question"] = Questions.shared.current?.title ?? ""
            answer(out)
        }
    }

    private func handleBound(_ request: [String: Any], _ given: @escaping ([String: Any]) -> Void, in checked: Browser? = nil) {
        // What agents asked of Yab, for Yab Wrapped; not the probes of a
        // development build.
        if !Store.development, request["woken"] == nil, let verb = request["do"] as? String {
            WrappedLedger.shared.add(.codeCalls)
            WrappedLedger.shared.add("code.tool." + verb)
        }
        // One answer, and always one: a page that never replies to a script
        // would otherwise hold the bench, every later command waits behind it.
        var answered = false
        let usage = UsageProbe.begin(request)
        var answer: ([String: Any]) -> Void = { reply in
            guard !answered else { return }
            answered = true
            UsageProbe.end(usage)
            given(reply)
        }
        // Long polls say how long they will hold; everything else answers
        // well inside the time a tool call is given.
        let polls = ["wait", "handoff-wait", "agent-wait", "import", "settle", "mail-time"].contains(request["do"] as? String ?? "")
        let fixture = request["do"] as? String == "box" && request["act"] as? String == "prepare"
        // Bringing another browser in waits on a person's yes and macOS's key.
        let bringing = request["do"] as? String == "app-import" && request["check"] as? Bool != true
        let osa = request["do"] as? String == "applescript"
        // A jar of tens of thousands poured the old way, on a busy Mac.
        let pour = request["do"] as? String == "cookie-pour"
        let patience = bringing || pour ? 600 : fixture || osa ? 90 : polls ? min(request["seconds"] as? Double ?? 20, 60) + 5 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { answer(["error": "no answer within \(Int(patience)) s"]) }
        // A test can address either browser window without moving focus.
        let windowBrowser: Browser?
        if Store.testing, let number = request["browserWindowNumber"] as? Int {
            // Visible-window indexes omit minimized windows. A probe of
            // their restore must keep addressing the same owned window.
            guard let window = NSApp.windows.first(where: { $0.windowNumber == number }),
                  let found = BrowserWindows.shared.browser(for: window) else {
                answer(["error": "no browser window with that number"])
                return
            }
            windowBrowser = found
        } else {
            windowBrowser = Store.testing ? (request["browserWindow"] as? Int).flatMap { number in
                let windows = BrowserWindows.shared.openWindows()
                return windows.indices.contains(number - 1) ? windows[number - 1].browser : nil
            } : nil
        }
        guard let browser = checked ?? windowBrowser ?? target(request) else {
            answer(["error": "no browser"])
            return
        }
        let verb = request["do"] as? String ?? ""
        if let refusal = ContextConsent.preflight(request) { answer(["error": refusal]); return }
        let contextEpoch = ContextPrivacy.shared.epoch
        // A task's watcher gets its result after the task ends: the end
        // closes the admission this answer would otherwise be held to.
        let admission = ContextConsent.watching.contains(verb) ? nil
            : (request["session"] as? String).flatMap { Agents.shared.session($0)?.admission }
        let allowed = { ContextPrivacy.shared.current(contextEpoch) && (admission?.valid ?? true) }
        let originalAnswer = answer
        answer = { out in
            guard ContextPrivacy.shared.current(contextEpoch), admission?.valid ?? true else { originalAnswer(["error": "This context was cleared."]); return }
            originalAnswer(out)
        }
        if remoteTaskReader?.handle(request, browser: browser, bench: self, answer: answer) == true { return }
        if let refusal = RemoteTaskBoundary.refusal(request) { answer(["error": refusal]); return }
        if let target = find(request, in: browser), Agents.shared.remoteTaskOrigin(target.agent) != nil {
            answer(["error": "An iPhone task owns this read-only page. Ordinary tools cannot use it."])
            return
        }
        // A call keeps a hidden Yab; asking how it is doesn't.
        if verb != "app-status" { Headless.called() }
        guard Bench.allowed(verb, session: request["session"] != nil) else {
            answer(["error": Bench.allowed(verb, session: true)
                ? "\(verb) is an agent's: take a session with agent-attach and send it along"
                : "\(verb) only works on a --test run"])
            return
        }
        // Named in the watchdog's log, so a stall reads as what the script
        // had just asked for, and in stalls.log (Watchdog).
        Hangs.phase("bench " + verb)

        if verb == "boost-probe" { boostProbe(request, browser: browser, answer: answer); return }
        if verb == "action-menu" { answer(ActionMenu.state()); return }
        if verb == "userscript-probe" { userscriptProbe(request, browser: browser, answer: answer); return }
        if verb == "windows" { windowsCommand(request, browser: browser, answer); return }
        if verb == "native-scrollbars" { answer(NativeScrollBench.run(request)); return }

        // An agent's call: never the pages of the person's own that Yab
        // keeps (saved cards, passwords, the notes about them at yab://you),
        // to go to or to read, and never a card number yab filled, in
        // anything it hears back (Wallet.hide).
        if request["session"] != nil {
            let own = ["autofill", "passwords", KnowPage.host]
            let secret: (URL?) -> Bool = { $0?.scheme == DiaryPage.scheme && own.contains($0?.host() ?? "") }
            if let raw = request["url"] as? String, secret(Address.url(from: raw)) || own.contains(where: { raw.lowercased().hasPrefix("yab://" + $0) }) {
                answer(["error": "the saved cards, passwords and notes about the person are theirs alone: an agent can't open them"])
                return
            }
            if let tab = find(request, in: browser), secret(tab.address), verb != "close", verb != "tabs" {
                answer(["error": "that tab shows the person's saved cards, passwords or notes about them: an agent can't read or use it"])
                return
            }
            // Nor a private tab, for anything: to an agent it isn't there.
            if find(request, in: browser)?.shy == true {
                answer(missing(request))
                return
            }
            let plain = answer
            answer = { plain(Wallet.hide($0) as? [String: Any] ?? $0) }
        }

        if ["close", "text", "shot"].contains(verb), let tab = find(request, in: browser),
           let refusal = Agents.shared.stoppedOnTab(tab, session: request["session"] as? String) {
            answer(["error": refusal]); return
        }
        if Bench.forAgents(verb) {
            agentCommand(verb, request, browser: browser, answer)
            return
        }
        if verb == "tearoff" {
            tearOffCommand(request, answer)
            return
        }
        if verb == "files" {
            filesCommand(request, browser: browser, answer)
            return
        }
        if verb == "box" {
            // A second window owns its own field and selected row. The bench
            // follows the key window, as its posted keys do.
            fieldCommand(request, browser: BrowserWindows.shared.activeBrowser ?? browser, answer)
            return
        }
        if verb == "bodies" {
            bodiesCommand(request, browser: browser, answer)
            return
        }
        // A call on an agent's behalf lights its mark; one with no agent
        // behind it, on a tab a script opened or opening one, the Script's.
        let target = find(request, in: browser)
        let scripted = verb == "open" || target?.agent == Agents.script
        // A `close` of a tab of yours is refused below, so it isn't the
        // agent's step there: the foot never says "Closing" over your page.
        let refusedClose = verb == "close" && target.map { !$0.bench } == true
        if let session = request["session"] as? String ?? (scripted ? Agents.shared.scripted().id : nil), verb != "tabs", !refusedClose {
            // Where, when the call doesn't say: the tab's own site.
            let host = request["url"] == nil ? target?.address?.host : nil
            Agents.shared.touch(session, host.map { "\(verb) · \($0)" } ?? Agents.step(verb, request),
                                step: request["followup"] == nil && verb != "settle")
        }

        // A subagent touches only its own tabs; the rest it reads with snapshot.
        if ["eval", "close", "go"].contains(verb), let id = request["session"] as? String,
           Agents.shared.session(id)?.parent != nil, request["id"] as? String == "all" || (target != nil && target?.agent != id) {
            answer(["error": "a subagent acts only in tabs it opened itself: read this one with snapshot, or open your own (open)"])
            return
        }

        switch verb {
        case "tidy-settings":
            guard Store.testing else { answer(["error": "tidy-settings only works in a test world"]); return }
            if let on = request["titles"] as? Bool { browser.prefs.tidyTitles = on }
            if let on = request["folders"] as? Bool { browser.prefs.folderNames = on }
            if let on = request["downloads"] as? Bool { browser.prefs.tidyDownloads = on }
            if let path = request["directory"] as? String { browser.prefs.downloads = URL(fileURLWithPath: path, isDirectory: true) }
            if let on = request["askWhere"] as? Bool { browser.prefs.asksWhereToSave = on }
            answer(["titles": browser.prefs.tidyTitles, "folders": browser.prefs.folderNames, "downloads": browser.prefs.tidyDownloads,
                    "directory": browser.prefs.downloads.path, "page": SettingsWindow.shared.model?.page.rawValue ?? "",
                    "named": DownloadNames.last, "canName": DownloadNames.canName,
                    "files": browser.loot.kept.map { ["name": $0.name, "path": $0.path, "was": $0.was ?? ""] }])
        case "tidy-name":
            guard Store.testing else { answer(["error": "tidy-name only works in a test world"]); return }
            // While You Browse on a test run, the model stood in: `name`
            // given to the kept tab `tab` (its id; the one in front without)
            // as an answer lands, its row's old name to dust (Rename.swift).
            // `warm`: only build the dust's shader, for a later call.
            if request["warm"] as? Bool == true {
                Rename.warm()
                answer(["ok": true, "dust_ready": Dust.shared.ready, "played": Dust.shared.played])
                return
            }
            let tab = (request["tab"] as? String).flatMap { find(["id": $0], in: browser) } ?? target ?? browser.active
            guard let tab,
                  let name = request["name"] as? String else { answer(["ok": false, "error": "no tab or name"]); return }
            let played = Dust.shared.played
            let ok = ShortNames.shared.stand(name, for: tab)
            answer(["ok": ok, "dusted": Dust.shared.played > played, "dust_ready": Dust.shared.ready,
                    "label": tab.rowLabel, "tidied": tab.tidiedAt != nil])
        case "tidy-download":
            guard Store.testing else { answer(["error": "tidy-download only works in a test world"]); return }
            // Tidy Downloads on a test run: the newest download renamed to
            // `name` the way a model's answer does it (Hoard.peek); `undo`:
            // its Undo, the site's name back (`path`: that file's row's).
            if request["undo"] as? Bool == true,
               let keep = (request["path"] as? String).flatMap({ path in browser.loot.kept.first { $0.path == path } }) ?? browser.loot.kept.first {
                browser.hoard.undoName(keep)
                let back = browser.loot.kept.first { $0.date == keep.date && $0.from == keep.from }
                answer(["ok": true, "now": back?.name ?? "", "path": back?.path ?? "", "was": back?.was ?? ""])
                return
            }
            guard let keep = browser.loot.kept.first, let name = request["name"] as? String else { answer(["ok": false, "error": "no download or name"]); return }
            let played = Dust.shared.played
            browser.hoard.peek(rename: keep, to: DownloadNames.fileName(name, like: keep.name))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                answer(["ok": true, "dusted": Dust.shared.played > played, "was": keep.name, "stack": browser.hoard.stackWindow?.isVisible ?? false,
                        "now": browser.loot.kept.first?.name ?? "", "unreadable": DownloadNames.unreadable(keep.name)])
            }
        case "row-agents":
            // Agents in One Row (AgentRow): on or off as Settings ›
            // Experimental turns it, what the row says, who stands behind
            // it, which tabs it holds out of the list, and its panel's lines
            // (narrowed by `query`); `pick` opens a line by its title, as a
            // click would.
            if let on = request["on"] as? Bool { browser.prefs.agentRow = on }
            // `panel` puts the panel up or away, as a click on the row does,
            // its search holding `query`, for a picture of it.
            if let up = request["panel"] as? Bool {
                let panel = AgentRowPanel.Model.shared
                panel.reset()
                if up { panel.query = request["query"] as? String ?? "" }
                panel.up = up ? ObjectIdentifier(browser) : nil
            }
            let lines = AgentRow.lines(in: browser, query: request["query"] as? String ?? "")
            if let pick = request["pick"] as? String, let line = lines.first(where: { $0.title == pick }) {
                AgentRow.open(line, in: browser)
            }
            DispatchQueue.main.async {
                let shown = AgentRow.shown(in: browser)
                answer(["on": AgentRow.on, "shown": shown?.id ?? "", "words": shown.map(AgentRow.words) ?? "",
                        "workers": AgentRow.workers(in: browser).map { ["name": $0.name, "words": $0.words, "busy": $0.busy, "tabs": $0.tabs.map(Bench.short)] as [String: Any] },
                        "held": browser.tabs.filter(AgentRow.holds).map(Bench.short),
                        "lines": lines.map { ["part": $0.part.title, "title": $0.title, "words": $0.words, "count": $0.count,
                                              "unread": $0.tabs.contains { $0.unread != nil }, "tab": $0.tab.map(Bench.short) ?? ""] as [String: Any] }])
            }
        case "site-items":
            // Yab's buttons on sites (SiteItems): what the tab points at, what
            // ⌘J's line would hold, a site's state, and the switches the
            // right-click menu, the View menu and Settings set.
            let items = SiteItems.shared
            let skill = request["skill"] as? String ?? items.skill(for: target?.address) ?? ""
            switch request["act"] as? String {
            case "never": items.set(skill, on: false)
            case "on": items.set(skill, on: true)
            case "everywhere-off": items.everywhere(false, from: nil)
            case "everywhere-on": items.everywhere(true, from: nil)
            case "line": if let target { TaskLine.shared.open(on: target) }
            case "close": TaskLine.shared.close()
            case "ask":
                // Words into the line, then ↩, as typed (evals/no-agent).
                if let target {
                    TaskLine.shared.words = request["words"] as? String ?? ""
                    TaskLine.shared.run(on: target)
                }
            case "skip":
                // The foot's Skip, as PagePill's button does it.
                if let target, let action = Hints.shared.extra[target.id] {
                    Hints.shared.unoffer(target.id)
                    SiteItems.shared.skip(action.skill, from: browser)
                }
            default: break
            }
            let offer = target.flatMap { tab in Hints.shared.offered[tab.id] == nil ? nil : Hints.shared.extra[tab.id]?.title }
            let pointed = target.flatMap { items.pointed[$0.id] }
            answer(["skill": skill, "state": "\(items.state(skill))", "pointed": pointed?.chip ?? "",
                    "about": pointed.map { $0.sentence } ?? "",
                    "actions": target.flatMap { tab in pointed.map { items.actions(for: $0, on: tab).map(\.title) } } ?? [],
                    "line": TaskLine.shared.context.map(\.title), "offer": offer ?? "",
                    // With no agent (Agents.ready): what ⌘J and ⌘T show instead.
                    "ready": Agents.ready, "mac": FormModel.ready, "open": TaskLine.shared.tab != nil,
                    "alone": TaskLine.shared.alone, "here": TaskLine.shared.here,
                    "answer": TaskLine.shared.answer, "needsAgent": TaskLine.shared.needsAgent,
                    "agentRows": browser.agentRows().map(\.key), "script": target.map { items.script(for: $0, host: $0.address?.host()) != nil } ?? false,
                    "corner": browser.toaster.shown ? browser.toaster.words : "",
                    "offerAbout": target.flatMap { tab in SiteItems.shared.item(offeredOn: tab, for: Hints.shared.extra[tab.id] ?? Skills.Action(title: "", pattern: "", prompt: "", skill: ""))?.chip } ?? ""])
        case "wrapped":
            // Yab Wrapped on a demo world ("rich", "light", "new"): each
            // screen through the tube into `dir` as a PNG, the card too, and
            // the arcade up over the window when `open` says so; `year`
            // ("2026") plays the year's, snow and all.
            if request["state"] as? Bool == true {
                let wrapped = Wrapped.shared
                answer(["up": wrapped.model != nil, "index": wrapped.model?.index ?? -1, "due": wrapped.due?.title ?? "",
                        "played": WrappedSound.shared.played.map(\.rawValue), "muted": WrappedSound.muted])
                return
            }
            let counts = WrappedCounts.demo(request["world"] as? String ?? "rich")
            let first = Date().addingTimeInterval(-41 * 86_400)
            let year = request["year"] as? String
            Wrapped.shared.stand = (counts, first, year)
            if let due = request["due"] as? String { Wrapped.shared.pretend(due.isEmpty ? nil : WrappedMoment(id: "bench", title: due)) }
            if request["open"] as? Bool == true { Wrapped.shared.open(counts: counts, first: first, period: year, in: browser) }
            guard let dir = request["dir"] as? String else { answer(["opened": true]); return }
            if let screen = request["film"] as? String {
                answer(WrappedShots.film(counts: counts, first: first, period: year, screen: screen, to: URL(fileURLWithPath: dir)))
                return
            }
            answer(WrappedShots.write(counts: counts, first: first, period: year, to: URL(fileURLWithPath: dir)))
        case "plan-usage":
            guard Store.testing, let binary = request["binary"] as? String,
                  let cli = request["cli"] as? String, ["codex", "claude"].contains(cli)
            else { answer(["error": "plan-usage requires a test run and a CLI"]); return }
            // The native probe uses a controlled CLI, through the same
            // account/usage exchange as the product, without signing in.
            let folder = Store.file("agent/plans")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Task {
                let usage = await PlanAccounts.usage(cli, binary: binary,
                    env: ["PATH": "/usr/bin:/bin"], in: folder)
                answer(usage.map { ["usage": $0] } ?? ["unavailable": true])
            }
        case "usage-position":
            guard Store.testing, let window = Links.window, let screen = NSScreen.screens.first else {
                answer(["error": "usage-position requires a test window and a display"]); return
            }
            let area = screen.visibleFrame
            let width = min(1100.0, area.width - 40), height = min(760.0, area.height - 40)
            window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height), display: true)
            window.makeKeyAndOrderFront(nil)
            answer(["ok": true])

        case "chromium-drm":
            ChromiumDRMBench.respond(request, tab: find(request, in: browser) ?? browser.active, answer: answer)
        case "energy-tab-groups":
            guard Store.testing else { answer(["error": "Tab-group counters require a probe world"]); return }
            answer(["scans": ChromiumTabGroups.shared.scans])
        case "energy-window-poll":
            guard Store.testing, let core = ChromiumProcess.shared.connectedClient else {
                answer(["error": "Window-poll counters require a connected probe world"]); return
            }
            Task { @MainActor in
                do {
                    let value = try await core.request("debug.windowPoll")
                    answer(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:])
                } catch { answer(["error": String(describing: error)]) }
            }
        case "now-playing-artwork":
            answer(nowPlayingArtworkProbe())
        case "keyboard-source":
            guard Store.testing, let tab = find(request, in: browser) ?? browser.active,
                  let window = tab.page.window, window.isKeyWindow,
                  let responder = window.firstResponder as? NSView,
                  responder === tab.page || responder.isDescendant(of: tab.page),
                  let context = responder.inputContext, NSTextInputContext.current === context,
                  let source = request["source"] as? String,
                  context.keyboardInputSources?.contains(source) == true else {
                answer(["error": "Focused page input context and enabled source required"]); return
            }
            // Test setup must select in the active editor, just as its input
            // menu does. Cross-process TIS selection alone is not adoption.
            context.selectedKeyboardInputSource = source
            answer(["inputSource": context.selectedKeyboardInputSource ?? "",
                    "inputContextIsCurrent": NSTextInputContext.current === context,
                    "responderClass": String(describing: type(of: responder))])

        case "page-engine":
            guard Store.testing, let tab = find(request, in: browser) ?? browser.active else {
                answer(["error": "page-engine requires an isolated tab"]); return
            }
            answer(ChromiumParityBench.describe(tab))

        case "chromium":
            guard Store.testing else { answer(["error": "Chromium probe needs an isolated test world"]); return }
            if request["op"] as? String == "original-caller-diagnostic" {
                chromiumOriginalCallerDiagnostic(request, answer: answer); return
            }
            if request["op"] as? String == "crash-helper" {
                ChromiumProcess.shared.crashForTesting(); answer(["ok": true]); return
            }
            guard let tab = find(request, in: browser) ?? browser.active,
                  let page = tab.page as? ChromiumPage else { answer(["error": "No Chromium tab"]); return }
            if request["op"] as? String == "dev-frontend" {
                guard let frontend = tab.chromiumDev else { answer(["frontend": false]); return }
                var state: [String: Any] = ["frontend": true, "ready": frontend.ready, "remote": frontend.page.remoteID ?? "",
                                            "surface": frontend.page.contextID, "selected": frontend.selected, "picking": frontend.picking,
                                            "panels": frontend.panels.map(\.title),
                                            "focused": frontend.page.window?.firstResponder === frontend.page,
                                            "frame": [frontend.page.frame.width, frontend.page.frame.height],
                                            "pageFrame": [page.frame.width, page.frame.height],
                                            "inWindow": frontend.page.window != nil]
                guard let body = request["body"] as? String else { answer(state); return }
                Task { @MainActor in
                    do { state["value"] = try await frontend.page.call(body, gesture: false) ?? NSNull() }
                    catch { state["error"] = String(describing: error) }
                    answer(state)
                }
                return
            }
            if request["op"] as? String == "native-ime" {
                page.probeNativeInputMethod(request, answer: answer); return
            }
            if chromiumNavigationProbe(request, tab: tab, page: page, browser: browser, answer: answer) { return }
            if chromiumMediaProbe(request, tab: tab, page: page, browser: browser, answer: answer) { return }
            switch request["op"] as? String ?? "state" {
            case "script-replay":
                page.scripts.probeReplay(request["action"] as? String ?? "inspect", done: answer)
                return
            case "extension-consent":
                guard Store.testing else { answer(["error": "Consent diagnostics require a test world"]); return }
                if let params = request["reply"] as? [String: Any] {
                    Task { @MainActor in
                        do {
                            let core = try await ChromiumProcess.shared.connection()
                            let fields = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: params))
                            let result = try await core.request("extension.consent.reply", params: fields)
                            answer(["value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed)])
                        } catch { answer(["error": String(describing: error)]) }
                    }
                } else { answer(["requests": ChromiumConsent.benchState]) }
                return
            case "extension-review-removal":
                // Settings' Remove… on a Chromium page (ChromiumExtensionsSettings),
                // started and left to its questions; `read` answers how it
                // ended: asking, removed, kept or the error (test worlds only).
                guard Store.testing, let id = request["extension"] as? String else { answer(["error": "Removal diagnostics require a test world and an extension"]); return }
                if request["read"] as? Bool == true { answer(["state": Self.reviewedRemovals[id] ?? ""]); return }
                let native = page.extensions
                let name = native.items.first { $0.id == id }?.name ?? id
                Self.reviewedRemovals[id] = "asking"
                Task { @MainActor in
                    do { Self.reviewedRemovals[id] = try await native.reviewRemoval(id, name: name, place: .settings) ? "removed" : "kept" }
                    catch { Self.reviewedRemovals[id] = "error: " + String(describing: error) }
                }
                answer(["started": true])
                return
            case "private-extensions":
                // "Allow in private tabs", set as its switch sets it (test
                // worlds only), and whether this page is its space's private side.
                if Store.testing, let allow = request["allow"] as? Bool { browser.prefs.extensionsInPrivate = allow }
                answer(["allow": browser.prefs.extensionsInPrivate, "private": ChromiumColumn.isPrivate(tab),
                        "profile": page.profile, "space": ChromiumPrivateProfiles.space(of: page.profile)?.profile ?? "",
                        "made": ChromiumPrivateProfiles.benchState(page.profile)])
                return
            case "extension-popup":
                if let id = request["extension"] as? String { ChromiumColumn.shared.press(id, tab: tab) }
                answer(ChromiumPopupHost.shared.state)
                return
            case "side-panel":
                // The real panel document in an isolated acceptance world,
                // matching ext-side-panel's WebKit inspection route.
                if let js = request["js"] as? String {
                    guard #available(macOS 15.4, *), let id = request["extension"] as? String,
                          let panel = ChromiumSidePanel.shared.front(in: browser), panel.extensionID == id,
                          let content = panel.tab.builtPage else { answer(["error": "No matching Chromium panel in front"]); return }
                    content.run(js) { result in
                        MainActor.assumeIsolated {
                            switch result {
                            case .success(let value): answer(["value": Bench.plain(value)])
                            case .failure(let error): answer(["error": error.localizedDescription])
                            }
                        }
                    }
                    return
                }
                // The extension's side panel: "press" as its button does,
                // "open" as chrome.sidePanel.open; then every panel's state.
                if let id = request["extension"] as? String, #available(macOS 15.4, *) {
                    let open = request["open"] as? Bool == true
                    Task { @MainActor in
                        let shown = open ? await ChromiumSidePanel.shared.open(id, from: tab)
                                         : await ChromiumSidePanel.shared.press(id, from: tab)
                        answer(["shown": shown, "panels": ChromiumSidePanel.shared.benchState])
                    }
                    return
                }
                answer(["panels": ChromiumSidePanel.shared.benchState])
                return
            case "extension-action-menu":
                // The extension's own rows of its button's menu on this page,
                // as read for it (CEF patch 0124); `run` chooses one by id.
                guard let id = request["extension"] as? String else { answer(["error": "extension-action-menu needs an extension"]); return }
                Task { @MainActor in
                    var out: [String: Any] = ["capable": ChromiumProcess.shared.extensionSurfaces.actionMenu]
                    if let item = request["run"] as? String,
                       let row = ChromiumActionMenu.shared.rows(id, tab: tab).first(where: { $0.id == item }) {
                        out["ran"] = await ChromiumActionMenu.shared.run(id, row: row, tab: tab)
                    }
                    ChromiumActionMenu.shared.refresh(id, tab: tab)
                    try? await Task.sleep(for: .milliseconds(600))
                    func plain(_ rows: [ChromiumActionMenu.Row]) -> [[String: Any]] {
                        rows.map { ["id": $0.id, "title": $0.title, "type": $0.kind.rawValue, "checked": $0.checked,
                                    "enabled": $0.enabled, "items": plain($0.rows)] }
                    }
                    out["items"] = plain(ChromiumActionMenu.shared.rows(id, tab: tab))
                    answer(out)
                }
                return
            case "extension-popup-input":
                guard Store.testing, let input = ChromiumPopupProbeInput(request) else {
                    answer(["error": "native popup input needs an exact original test lease/finite point"]); return
                }
                answer(ChromiumPopupHost.shared.benchPointer(input, owner: page))
                return
            case "extension-document-probe":
                Task { @MainActor in
                    do {
                        let result = try await page.extensionDocumentProbe(request["expression"] as? String ?? "document.readyState")
                        answer(["value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed)])
                    } catch { answer(["error": String(describing: error)]) }
                }
                return
            case "extension-actions", "extension-press":
                let name = request["op"] as? String == "extension-press" ? request["name"] as? String : nil
                Task { @MainActor in
                    do {
                        let result = try await page.extensionActionState(press: name)
                        answer(["value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed)])
                    } catch { answer(["error": String(describing: error)]) }
                }
                return
            case "extension-host-state":
                Task { @MainActor in
                    do {
                        let result = try await page.extensionHostState()
                        answer(["value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed)])
                    } catch { answer(["error": String(describing: error)]) }
                }
                return
            case "one-list":
                if #available(macOS 15.4, *) { page.extensions.benchOneList(request, answer: answer) }
                else { answer(["error": "macOS 15.4 or later"]) }
                return
            case "extension-column":
                answer(ChromiumColumn.benchState(tab: tab, page: page, pin: request["pin"] as? String,
                                                 pinned: request["pinned"] as? Bool ?? true, read: request["read"] as? Bool ?? false))
                return
            case "extensions":
                Task { @MainActor in
                    do {
                        let method = request["method"] as? String ?? "extension.list"
                        if method == "extension.importFixture", Store.testing,
                           let params = request["params"] as? [String: Any],
                           let paths = params["packages"] as? [String: String], let rows = params["entries"] {
                            let entries = try JSONDecoder().decode([Installed].self, from: JSONSerialization.data(withJSONObject: rows))
                            let results = try await page.extensions.importList(entries) { item in
                                guard let path = paths[item.id] else { throw Crx.Refused.unpack }
                                _ = try await page.extensions.install(Data(contentsOf: URL(fileURLWithPath: path)), id: item.id)
                            }
                            answer(["value": ["results": results.map { ["id": $0.id, "state": $0.state.rawValue, "detail": $0.detail ?? ""] },
                                               "pins": page.extensions.pinnedIDs, "pending": Array(page.extensions.pendingImport).sorted()]])
                            return
                        }
                        if method == "extension.installPackage", let params = request["params"] as? [String: Any],
                           let path = params["path"] as? String, let id = params["extension"] as? String {
                            let item = try await page.extensions.install(Data(contentsOf: URL(fileURLWithPath: path)), id: id)
                            answer(["value": ["id": item.id, "name": item.name, "state": item.state]])
                            return
                        }
                        // As Remove in the extensions' lists does: gone from the list at once.
                        if method == "extension.removeListed", Store.testing, let id = (request["params"] as? [String: Any])?["extension"] as? String {
                            try await page.extensions.remove(id, userApproved: true)
                            answer(["value": true])
                            return
                        }
                        if method == "extension.registerNativeHost", let path = (request["params"] as? [String: Any])?["path"] as? String {
                            let host = try await page.extensions.registerNativeHost(manifestAt: URL(fileURLWithPath: path))
                            answer(["value": ["name": host.name, "path": host.path.path]])
                            return
                        }
                        let data = try JSONSerialization.data(withJSONObject: request["params"] as? [String: Any] ?? [:])
                        let params = try JSONDecoder().decode([String: JSONValue].self, from: data)
                        let result = try await page.extensions.request(method, params: params)
                        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed)
                        answer(["value": value])
                    } catch { answer(["error": String(describing: error)]) }
                }
                return
            case "navigate":
                if let value = request["url"] as? String, let url = URL(string: value) { tab.go(to: url) }
            case "back": tab.back()
            case "forward": tab.forward()
            case "reload": tab.reload()
            case "mute": tab.mute(request["muted"] as? Bool ?? true)
            case "kill-renderer": page.killContent()
            case "text": page.insertAgentText(request["text"] as? String ?? "")
            case "click": _ = page.agentClick(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0, flags: [])
            case "resize":
                page.window?.setContentSize(NSSize(width: request["width"] as? Double ?? 1000, height: request["height"] as? Double ?? 700))
            case "script":
                let world = (request["world"] as? String).map(PageWorld.named) ?? .page
                page.call(request["body"] as? String ?? "return document.title", arguments: request["arguments"] as? [String: Any] ?? [:],
                          in: world, gesture: request["gesture"] as? Bool ?? true) { result in
                    switch result {
                    case .success(let value): answer(["value": value ?? NSNull()])
                    case .failure(let error): answer(["error": String(describing: error)])
                    }
                }
                return
            case "scripts": page.scripts.status(answer); return
            case "snapshot":
                page.snapshot(PageShot()) { image, error in
                    guard let image, let path = request["path"] as? String,
                          let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        answer(["error": String(describing: error)]); return
                    }
                    do { try png.write(to: URL(fileURLWithPath: path)); answer(["ok": true]) }
                    catch { answer(["error": String(describing: error)]) }
                }
                return
            default: break
            }
            let rect = page.convert(page.bounds, to: nil)
            answer(["engine": tab.engineKind.rawValue, "tab": tab.id.uuidString, "remote": page.remoteID ?? "",
                    "opener": tab.opener?.uuidString ?? "", "selected": browser.activeID == tab.id,
                    "surface": page.surfaceState, "context": page.contextID, "helperPID": ChromiumProcess.shared.processID ?? 0, "url": page.url?.absoluteString ?? "", "title": page.title ?? "",
                    "loading": page.isLoading, "back": page.canGoBack, "forward": page.canGoForward,
                    "rendererPID": page.contentProcess ?? 0, "audioMuted": page.audioMuted, "tabMuted": tab.muted,
                    "failure": tab.failure ?? "", "lastEngineError": page.diagnosticFailure ?? "", "window": page.window?.windowNumber ?? 0,
                    "frame": [rect.minX, rect.minY, rect.width, rect.height],
                    "windowSize": [page.window?.frame.width ?? 0, page.window?.frame.height ?? 0],
                    "visible": page.window != nil && !page.isHiddenOrHasHiddenAncestor])
        case "cursor-state":
            answer(Self.cursorState(windowNumber: request["window"] as? Int))

        case "spare-state":
            guard Store.testing else { answer(["error": "spare-state requires an isolated test run"]); return }
            answer(browser.spareForBench)

        case "usage-open":
            guard Store.testing, let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "usage-open requires a test run and a URL"]); return
            }
            // Normal tabs have normal sleep/background behavior. Ownership
            // lives in the harness, separate from the agent/bench exemption.
            OpenTrace.mark("ask")
            let tab = OpenTrace.time("open") { browser.open(url, foreground: request["foreground"] as? Bool ?? true, atEnd: true) }
            OpenTrace.turns("open")
            UsageProbe.ownedTabs.insert(tab.id)
            answer(describe(tab))

        case "usage-close":
            guard Store.testing, let tab = find(request, in: browser), UsageProbe.ownedTabs.contains(tab.id) else {
                answer(["error": "usage-close only closes this harness's test tabs"]); return
            }
            UsageProbe.ownedTabs.remove(tab.id)
            StageView.mark("input", ["what": "close"])
            browser.close(tab)
            answer(["closed": 1])

        case "usage-background":
            guard Store.testing else { answer(["error": "usage-background requires a test run"]); return }
            if request["hide"] as? Bool == false {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                Links.window?.makeKeyAndOrderFront(nil)
            } else {
                NSApp.hide(nil)
            }
            answer(["ok": true])

        case "stuck":
            // The watch on the page in front (Stuck.swift, evals/gpu-hang):
            // why it last didn't ask, failed answers in a row, what it watches.
            guard Store.testing else { answer(["error": "stuck only works on a --test run"]); return }
            let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false)
            answer(["skip": browser.stuck.frontSkip ?? "", "strikes": browser.stuck.frontStrikes,
                    "asking": browser.stuck.frontAsking,
                    "page": Browser.process(of: web) ?? 0, "gpu": Browser.gpuProcess(of: web) ?? 0,
                    "visible": BrowserWindows.shared.window(for: browser)?.occlusionState.contains(.visible) == true])

        case "sync":
            // Sync in a test world (evals/sync): turn it on or join with a
            // Recovery Key, open and close tabs of yours, read the row.
            guard Store.testing else { answer(["error": "sync only works on a --test run"]); return }
            let sync = SyncCenter.shared
            func status() -> [String: Any] {
                ["on": sync.on, "state": String(describing: sync.state), "counts": sync.countsNow(),
                 "tabs": browser.tabs.filter { !$0.bench && !$0.shy }.map { ["id": $0.id.uuidString, "url": $0.address?.absoluteString ?? ""] },
                 "pending": sync.journal?.pending().count ?? 0,
                 "urls": browser.tabs.filter { !$0.bench && !$0.shy }.compactMap { $0.address?.absoluteString },
                 "space": browser.spaceID.uuidString, "active": browser.active?.address?.absoluteString ?? ""]
            }
            func joinState() -> [String: Any] {
                ["code": sync.joining?.code ?? "", "invited": sync.joiningInvited, "check": sync.joiningCheck ?? "",
                 "trouble": sync.joinTrouble ?? "", "on": sync.on, "state": String(describing: sync.state),
                 "account": sync.account ?? "", "arrival": String(describing: sync.arrival),
                 "separate": sync.separate?.name ?? "", "keptApart": sync.keptApart?.name ?? "",
                 "joiningAccounts": sync.joiningAccounts, "devices": sync.devices.count,
                 "awaitingConfirmation": sync.awaitingJoinConfirmation]
            }
            switch request["action"] as? String ?? "status" {
            case "category-controls":
                syncCategoryControls(request, answer: answer)
            case "categories":
                if let name = request["category"] as? String, let category = SyncCategory(rawValue: name),
                   let enabled = request["enabled"] as? Bool {
                    sync.setSync(category, enabled: enabled)
                }
                answer(["categories": Dictionary(uniqueKeysWithValues: SyncCategory.allCases.map { ($0.rawValue, sync.syncs($0)) })])
            case "on":
                sync.startSyncing()
                answer(["recovery": sync.recovery ?? ""])
            case "turnon":
                // Turn On Sync's button: the look for the account first.
                sync.turnOn()
                answer(joinState())
            case "first":
                sync.startSyncing()
                answer(joinState())
            case "icloud":
                // Stands in for iCloud Keychain: `key` a Recovery Key, or none.
                SyncKey.testShared((request["key"] as? String).flatMap { Seal(recovery: $0) })
                answer(joinState())
            case "recovery":
                answer(["recovery": sync.accountRecovery ?? ""])
            case "separate":
                sync.lookForSeparate(now: true)
                answer(joinState())
            case "joinseparate":
                sync.joinSeparate()
                answer(joinState())
            case "keepseparate":
                sync.keepSeparate()
                answer(joinState())
            case "agree":
                sync.agreeToJoin()
                answer(joinState())
            case "join":
                answer(["joined": sync.join(recovery: request["key"] as? String ?? "")])
            case "ask":
                // Already syncing on another device?: this Mac's own code,
                // or with `code` the one another Mac's Add a Device shows.
                sync.askToJoin(invite: request["code"] as? String)
                answer(joinState())
            case "joinstate":
                answer(joinState())
            case "phonebeta":
                // Settings › Sync's Yab for your phone row, its code open or
                // shut, and whose: the same `phone` turns ⌘T's code.
                PhoneBetaState.shared.open = request["open"] as? Bool ?? true
                if let phone = request["phone"] as? String { PhoneBetaState.shared.phone = phone == "android" ? .android : .iPhone }
                answer(["open": PhoneBetaState.shared.open, "phone": PhoneBetaState.shared.phone.name, "waiting": PhoneBeta.waiting])
            case "kit":
                // Yab Recovery Key.pdf, as Download… writes it, without the panel.
                guard let key = sync.recovery, let path = request["path"] as? String else { answer(["error": "kit needs a key shown and a path"]); return }
                answer(["written": RecoveryKit.write(key, to: URL(fileURLWithPath: path))])
            case "open":
                guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else { answer(["error": "open needs a url"]); return }
                _ = browser.open(url, foreground: false, atEnd: true)
                browser.writeSession(now: true)
                answer(status())
            case "close":
                // "discard": Close and Don't Keep; a kept tab only closed is put
                // down and stays kept, as Arc's.
                let url = request["url"] as? String ?? ""
                let found = browser.tabs.filter { $0.address?.absoluteString == url && !$0.bench }
                if request["discard"] as? Bool == true { browser.discard(found, rekept: true) } else { found.forEach { browser.close($0) } }
                browser.writeSession(now: true)
                answer(status())
            case "keeptab":
                // Kept, a tab of today's is every device's (docs/sync.md, Today
                // is each device's own).
                let url = request["url"] as? String ?? ""
                browser.keepTabs(browser.tabs.filter { $0.address?.absoluteString == url && !$0.bench && !$0.kept })
                browser.writeSession(now: true)
                answer(status())
            case "send":
                // Words for a Mac, as the iPhone writes them (docs/sync.md).
                guard let journal = sync.journal else { answer(["error": "sync is off"]); return }
                let id = UUID().uuidString.lowercased()
                var fields: [String: SyncKit.Value] = ["device": .string(request["device"] as? String ?? ""), "text": .string(request["text"] as? String ?? ""),
                                               "kind": .string(request["kind"] as? String ?? "agent"), "at": .number(Date().timeIntervalSince1970)]
                if let chat = request["chat"] as? String { fields["chat"] = .string(chat) }
                try? journal.change(.init(collection: SyncChats.send, id: id), fields)
                sync.client?.kick()
                answer(["send": id])
            case "chats":
                // Every chat the account holds, with its last words and the
                // state of each send.
                guard let journal = sync.journal else { answer(["error": "sync is off"]); return }
                let items = journal.living(SyncChats.item)
                answer([
                    "device": SyncCenter.deviceID,
                    "chats": journal.living(SyncChats.chat).map { chat -> [String: Any] in
                        let mine = items.filter { $0["chat"]?.string == chat.id }.sorted { ($0["n"]?.number ?? 0) < ($1["n"]?.number ?? 0) }
                        return ["id": chat.id, "device": chat["device"]?.string ?? "", "title": chat["title"]?.string ?? "",
                                "state": chat["state"]?.string ?? "", "texts": mine.compactMap { $0["text"]?.string },
                                "cli": chat["cli"]?.string ?? "", "pinned": chat["pinned"]?.bool == true,
                                "archived": chat["archived"]?.bool == true, "unread": chat["unread"]?.bool == true]
                    },
                    // This Mac's own chats as it keeps them, past what sync says.
                    "local": Chats.shared.all.map { ["id": SyncChats.id(agent: $0.id), "title": $0.title, "pinned": $0.pinned,
                                                     "archived": $0.archived == true, "unread": $0.unread == true] },
                    "sends": journal.all(SyncChats.send).map { ["id": $0.id, "state": $0["state"]?.string ?? "", "chat": $0["chat"]?.string ?? "", "reason": $0["reason"]?.string ?? ""] },
                    "visits": journal.living(SyncShapes.visit).count,
                ])
            case "record":
                // One record as this Mac's journal holds it (a Mac's
                // commandcap, a send, a task's record).
                guard let journal = sync.journal, let collection = request["collection"] as? String, let id = request["id"] as? String else {
                    answer(["error": "record needs sync on, a collection and an id"]); return
                }
                let record = journal.record(.init(collection: collection, id: id))
                let fields = (try? JSONEncoder().encode(record?.visible ?? [:])).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                // "latest", when it last changed in milliseconds.
                answer(["alive": record?.alive() ?? false, "fields": fields ?? [:], "latest": record?.latest?.wall ?? 0])
            case "approvals":
                // Questions this Mac asked other devices, and other Macs'
                // questions it shows (AssistantApprovals, docs/approvals).
                if let on = request["elsewhere"] as? Bool { browser.prefs.agentsAskElsewhere = on }
                if let mode = (request["asking"] as? String).flatMap(AgentAsking.init) { browser.prefs.agentsAsking = mode }
                // The person at this Mac or away from it (AskPresence), as
                // its keys and screen would say.
                if let present = request["present"] as? Bool { AskPresence.shared.testAway = !present }
                let journal = sync.journal
                answer(["elsewhere": browser.prefs.agentsAskElsewhere, "asking": browser.prefs.agentsAsking.rawValue,
                        "away": AskPresence.shared.away,
                        "payLimit": AgentRules.shared.payLimit,
                        "answerers": sync.assistantAnswerers.map(\.name),
                        "mine": AssistantApprovals.shared.records.values.map { record -> [String: Any] in
                            var out = Bench.approval(record)
                            out["local"] = record.local
                            out["seen"] = record.seen
                            out["published"] = journal?.record(.init(collection: AssistantApprovalRecords.requestCollection, id: record.id))?.alive() == true
                            return out
                        },
                        "choosers": sync.assistantChoosers.map(\.name),
                        // Another Mac's question with its detail as this Mac
                        // reads it, and the pages pictured so far (bytes of each JPEG).
                        "foreign": sync.foreignAssistantApprovals().map { one -> [String: Any] in
                            var out: [String: Any] = ["id": one.id, "title": one.title, "lines": one.lines, "assistant": one.assistant,
                                                      "choices": one.choices ?? [], "seen": one.seen != nil]
                            if let detail = sync.foreignAssistantDetail(one), let body = try? detail.fields()["body"]?.string,
                               let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) {
                                out["detail"] = json
                                out["previews"] = Dictionary(uniqueKeysWithValues: (journal?.all(AssistantApprovalRecords.previewCollection) ?? [])
                                    .filter { $0.id.hasPrefix(one.id.lowercased() + ".") }
                                    .compactMap { record -> (String, Int)? in
                                        let parts = record.id.split(separator: ".").map(String.init)
                                        guard parts.count == 3, let page = Int(parts[2]),
                                              let preview = try? AssistantApprovalRecords.Preview.read(record, request: one, file: parts[1], page: page)
                                        else { return nil }
                                        return (record.id, preview.data?.count ?? 0)
                                    })
                            }
                            return out
                        },
                        // What came of each yes, as its Mac said it.
                        "results": Dictionary((journal?.all(AssistantApprovalRecords.resultCollection) ?? []).compactMap { record -> (String, Any)? in
                            guard record.alive(), let body = record["body"]?.string,
                                  let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return nil }
                            return (record.id, json)
                        }, uniquingKeysWith: { a, _ in a })])
            case "approve":
                // Another Mac's question answered here, as its card does; a
                // payment's yes may pick a card and an address (`added`:
                // ones kept here with `keepcard`, `keepaddress`).
                do {
                    try sync.answerForeignAssistantApproval(request["id"] as? String ?? "", yes: request["yes"] as? Bool ?? true,
                                                            choice: request["choice"] as? String, proved: request["proved"] as? Bool ?? true,
                                                            card: request["card"] as? String, place: request["place"] as? String,
                                                            added: request["added"] as? [String] ?? [])
                    answer(["ok": true])
                } catch { answer(["error": "\(error)"]) }
            case "keepcard", "keepaddress":
                // A card or an address kept as Yab for iPhone keeps one for
                // a payment's yes: a record in SyncWallet's shape, sealed
                // (AssistantWallet), for the asking Mac to take into Wallet.
                guard let journal = sync.journal, let seal = sync.client?.seal else { answer(["error": "sync is off"]); return }
                let id = request["id"] as? String ?? UUID().uuidString
                do {
                    if request["action"] as? String == "keepcard" {
                        try journal.change(.init(collection: SyncCollection.card, id: id), AssistantWallet.card(
                            id: id, number: request["number"] as? String ?? "", csc: request["csc"] as? String ?? "",
                            name: request["name"] as? String ?? "", month: request["month"] as? Int ?? 8,
                            year: request["year"] as? Int ?? 2031, seal: seal))
                    } else {
                        try journal.change(.init(collection: SyncCollection.address, id: id), AssistantWallet.address(
                            id: id, name: request["name"] as? String ?? "", street: request["street"] as? String ?? "",
                            city: request["city"] as? String ?? "", postal: request["postal"] as? String ?? "", seal: seal))
                    }
                } catch { answer(["error": "\(error)"]); return }
                sync.client?.kick()
                answer(["kept": id])
            case "dropwallet":
                // A card or an address kept by `keepcard`/`keepaddress`, gone
                // from the account (and so from every Mac's Wallet).
                guard let journal = sync.journal, let id = request["id"] as? String else { answer(["error": "dropwallet needs sync and an id"]); return }
                for collection in [SyncCollection.card, SyncCollection.address] where journal.record(.init(collection: collection, id: id))?.alive() == true {
                    try? journal.remove(.init(collection: collection, id: id))
                }
                sync.client?.kick()
                answer(["dropped": id])
            case "write":
                // Fields written into a record here, as another device writes
                // them (an Open on Mac, a chat's pin from the phone).
                guard let journal = sync.journal, let collection = request["collection"] as? String, let id = request["id"] as? String,
                      let raw = request["fields"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw),
                      let fields = try? JSONDecoder().decode([String: SyncKit.Value].self, from: data) else {
                    answer(["error": "write needs sync on, a collection, an id and fields"]); return
                }
                do { try journal.change(.init(collection: collection, id: id), fields) } catch { answer(["error": "\(error)"]); return }
                sync.client?.kick()
                answer(["written": id])
            case "tasks":
                // Tasks from the iPhone this Mac holds, and what it told of each.
                guard let journal = sync.journal else { answer(["error": "sync is off"]); return }
                answer(["requests": journal.all(TaskRecords.requestCollection).map(\.id),
                        "tasks": journal.all(TaskRecords.observationCollection).map { ["id": $0.id, "body": $0["body"]?.string ?? ""] },
                        "sessions": Agents.shared.sessions.filter { $0.remoteTask != nil }.map {
                            ["id": $0.id, "state": $0.state.rawValue, "args": Agents.shared.mcpArgs($0)] as [String: Any]
                        }])
            case "phones":
                // The iPhones that take pages (Send to iPhone), and the page
                // From iPhone offers under the empty field now, if any.
                let offer = sync.phoneOffer(now: Date(), in: browser)
                // Read again for the next ask: a device that left or joined.
                sync.refreshDevices()
                answer(["phones": sync.phones.map { ["id": $0.id, "name": $0.name] },
                        "devices": sync.devices.map { ["id": $0.id, "name": $0.name, "model": $0.model] },
                        "offer": offer.map { ["url": $0.url.absoluteString, "title": $0.title, "name": $0.name,
                                              "row": SyncPhones.hint($0).detail] } ?? [:],
                        "rows": Noticing.shared.rows(now: Date()).map { ["id": $0.id, "title": $0.title, "detail": $0.detail] }])
            case "sendphone":
                // Send to iPhone, as a tab's menu does: the tab at `url`
                // (or the one in front) to the iPhone named, else the first.
                let url = request["url"] as? String
                guard let tab = url.map({ want in browser.tabs.first { $0.address?.absoluteString == want } }) ?? browser.active,
                      let phone = sync.phones.first(where: { $0.id == request["phone"] as? String }) ?? sync.phones.first,
                      let page = SyncPhones.page(tab, in: browser),
                      let id = sync.send(page.url, title: page.title, space: page.space.flatMap(UUID.init(uuidString:)), to: phone.id) else {
                    answer(["error": "no iPhone takes pages, or that tab can't go"]); return
                }
                answer(["send": id, "phone": phone.id, "url": page.url.absoluteString, "title": page.title])
            case "takephone":
                // The From iPhone row taken, as a click on it does.
                guard let offer = sync.phoneOffer(now: Date(), in: browser) else { answer(["error": "nothing offered"]); return }
                Noticing.shared.take(SyncPhones.hint(offer), in: browser)
                answer(status())
            case "invite":
                // Add a Device's code for an iPhone to scan: shown, then the
                // digits a device posts under it, then let in on `letin`.
                guard let invite = sync.invite() else { answer(["error": "sync is off"]); return }
                benchInvite?.stop()
                benchInvite = invite
                invite.start { _ in }
                answer(["code": invite.code, "link": invite.link])
            case "addcard":
                // The same page the Add a Device row opens.
                SettingsWindow.shared.show(.sync, for: browser)
                answer(SettingsWindow.shared.bench(sync: SyncPlace.add))
            case "invitestate":
                answer(["phase": String(describing: benchInvite?.phase ?? .failed), "words": benchInvite?.words ?? ""])
            case "letin":
                guard let invite = benchInvite else { answer(["error": "no invite"]); return }
                sync.letIn(invite) {}
                answer(["phase": String(describing: invite.phase)])
            case "visit":
                // A page as if browsed, for history to have something to send.
                if let url = (request["url"] as? String).flatMap(URL.init(string:)) { History.shared.record(url, title: request["title"] as? String ?? "") }
                answer(status())
            case "password":
                // A login (and a two-factor key) kept or forgotten here, as
                // the passwords page would, for sync to carry.
                let host = request["host"] as? String ?? "", user = request["user"] as? String ?? ""
                if let password = request["password"] as? String, let box = request["after"] as? String {
                    // Changed as this Mac's record of the login comes to say
                    // something other than `after` (its sealed password till
                    // now), in the main-thread turn sync wrote it, however
                    // busy the Mac. Says when the record changed, in
                    // milliseconds, and the keychain's date for this change,
                    // which keeps whole seconds (evals/sync/check.py).
                    let key = SyncKit.Record.Key(collection: SyncWallet.login, id: host + "\u{1}" + user)
                    var done = false
                    func change() {
                        guard !done, let record = sync.journal?.record(key), record.alive(),
                              let now = record["secret"]?.string, now != box else { return }
                        done = true
                        sync.walletRead = nil
                        Vault.save(host: host, user: user, password: password)
                        let at = Date().timeIntervalSince1970
                        let modified = Vault.listed()?.first { $0.id == key.id }?.modified
                        answer(["latest": record.latest?.wall ?? 0, "at": at, "modified": modified?.timeIntervalSince1970 ?? 0])
                    }
                    change()
                    if done { return }
                    sync.walletRead = { change() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (request["seconds"] as? Double ?? 15)) {
                        guard !done else { return }
                        done = true
                        sync.walletRead = nil
                        answer(["error": "the record still holds the same password"])
                    }
                    return
                }
                if let password = request["password"] as? String {
                    // `clear`: kept from plain http, as a local page's is.
                    Vault.save(host: host, user: user, password: password, clear: request["clear"] as? Bool ?? false)
                    if let code = request["code"] as? String { OneTime.save(code, host: host, user: user) }
                } else {
                    Vault.forget(host: host, user: user)
                    OneTime.forget(host: host, user: user)
                }
                answer(status())
            case "holdwallet":
                // The keychain's queue held, as on a Mac too busy to write in
                // what came, until `releasewallet` (or `seconds`); records
                // still reach the journal meanwhile.
                sync.holdWallet(seconds: request["seconds"] as? Double ?? 30)
                answer(["held": true])
            case "releasewallet":
                sync.releaseWallet()
                answer(["released": true])
            case "card":
                let digits = request["number"] as? String ?? ""
                if let id = request["forget"] as? String {
                    Wallet.forget(card: id)
                } else {
                    Wallet.save(SavedCard(id: request["id"] as? String ?? UUID().uuidString, number: digits, last4: String(digits.suffix(4)),
                                          brand: "", name: request["name"] as? String ?? "", month: 8, year: 2030, csc: request["csc"] as? String ?? ""))
                }
                answer(status())
            case "answer":
                FormAnswers.keep([(request["question"] as? String ?? "", request["answer"] as? String ?? "")], site: request["site"] as? String ?? "")
                answer(status())
            case "wallet":
                // What this world's keychain and forms hold now, secrets and
                // all: a test world's, never the person's.
                let logins = Vault.all().map { login -> [String: Any] in
                    ["host": login.host, "user": login.user, "password": login.password, "code": OneTime.text(host: login.host, user: login.user) ?? ""]
                }
                let cards = Wallet.cards().map { card -> [String: Any] in
                    ["id": card.id, "name": card.name, "number": Wallet.number(of: card.id) ?? "", "csc": Wallet.securityCode(of: card.id) ?? ""]
                }
                answer(["logins": logins, "cards": cards, "answers": FormAnswers.load().said.map { ["question": $0.question, "answer": $0.answer, "site": $0.site] },
                        "journal": (sync.journal?.living(SyncWallet.login) ?? []).map { $0["secret"]?.string ?? "" }])
            case "addons":
                // Extensions and plugins here and on their way, with "on"
                // the switch in Settings › Sync.
                if let on = request["on"] as? Bool { sync.addons = on }
                answer([
                    "device": SyncCenter.deviceID, "on": sync.addons,
                    "extensions": Extensions.shared.installed.map { item -> [String: Any] in
                        ["id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled, "pinned": item.pinned ?? false,
                         "store": item.fromStore, "wants": item.wants ?? [], "loaded": Extensions.shared.contexts[item.id] != nil]
                    },
                    "plugins": Boosts.shared.records.map { record -> [String: Any] in
                        ["id": record.id, "name": record.name, "rung": record.rung.rawValue, "enabled": record.enabled, "digest": record.digest ?? "",
                         "runsOn": record.runsOn ?? "", "synced": sync.mirror?.ledger.plugins[record.id]?.digest ?? "",
                         "files": (try? Boosts.shared.library.files(record.id)) ?? [:],
                         // Rounds of its service's timer that passed it over for another Mac.
                         "passed": BoostServices.shared.passed[record.id] ?? 0,
                         "state": Store.settings.string(forKey: BoostStorage.key(record.id)) ?? "",
                         // When its service last ticked here, 0 for never.
                         "ticked": Store.settings.double(forKey: "boosts.service." + record.id + ".checked"),
                         // Why its last tick here failed, if it did.
                         "tickError": Store.settings.string(forKey: "boosts.service." + record.id + ".error") ?? "",
                         "tickNext": Store.settings.double(forKey: "boosts.service." + record.id + ".next"),
                         "tickRunning": BoostServices.shared.ticking(record.id), "tickRounds": BoostServices.shared.rounds,
                         "runsHere": record.runsHere, "revision": record.revision,
                         "service": BoostServices.shared.probe(record.id),
                         "store": StoreCatalog.shared.origin(of: record.id)?.revision ?? ""]
                    },
                    "waiting": SyncInstalls.shared.waiting.values.map { ["id": $0.id, "name": $0.name, "words": $0.state.words] },
                    // The plugins' parts as the journal holds them: removed
                    // ones should hold nothing.
                    "parts": (sync.journal?.all(SyncAddons.part) ?? []).map { part -> [String: Any] in
                        ["id": part.id, "alive": part.alive(), "empty": part.fields.values.allSatisfy(\.isNull)]
                    },
                ])
            case "keep":
                // A plugin kept here straight away, as a trial's Keep would
                // keep it: "name", "sites", "files"; "state" its storage.
                do {
                    let package = try BoostPackage.read(id: request["name"] as? String ?? "", files: request["files"] as? [String: String] ?? [:],
                                                        sites: request["sites"] as? [String] ?? [])
                    let record = try Boosts.shared.keepSynced(package, author: "You")
                    if let state = request["state"] as? [String: Any] { _ = try BoostStorage.set(record.id, state) }
                    answer(["kept": record.id, "digest": record.digest ?? "", "rung": record.rung.rawValue])
                } catch { answer(["error": error.localizedDescription]) }
            case "keep-store":
                // A Store release kept as it came, "catalog" and "revision",
                // its package from the stand-ins (SyncInstalls.boost).
                let catalog = request["catalog"] as? String ?? "", revision = request["revision"] as? String ?? ""
                Task {
                    do {
                        let data = try await SyncInstalls.boost(revision)
                        let shared = try BoostShare.read(data, id: catalog, reviewed: revision)
                        let record = try Boosts.shared.keepSynced(shared, author: "Store")
                        StoreCatalog.shared.noteSynced(record.id, catalog: catalog, revision: revision)
                        answer(["kept": record.id, "digest": record.digest ?? ""])
                    } catch { answer(["error": error.localizedDescription]) }
                }
            case "catalog":
                // The Store's catalog from the stand-ins (catalog.json), as if
                // read from the site: a test run never fetches it itself.
                guard let data = try? SyncInstalls.standIn(request["file"] as? String ?? "catalog.json"),
                      StoreCatalog.shared.adoptForTests(data, origin: URL(string: "https://yetanotherbrowser.com/store/catalog.json")!) else {
                    answer(["error": "no catalog.json among the stand-ins"]); return
                }
                answer(["items": StoreCatalog.shared.items.count])
            case "plugin":
                // A kept plugin turned on or off ("enabled"), or deleted.
                let name = request["name"] as? String ?? ""
                Task {
                    if request["delete"] as? Bool == true { await Boosts.shared.delete(name) }
                    else if let on = request["enabled"] as? Bool { await Boosts.shared.setEnabled(name, on) }
                    answer(["ok": true])
                }
            case "flush":
                sync.flushNow { answer(status()) }
            case "off":
                // Off everywhere: the test account goes from the server too.
                sync.turnOff(everywhere: true)
                answer(status())
            case "leave":
                sync.turnOff(handOver: true) { answer(status()) }
            default:
                answer(status())
            }

        case "usage":
            guard Store.testing else { answer(["error": "usage only works on a --test run"]); return }
            answer(UsageProbe.snapshot(browser))

        case "tabs":
            // An agent's list has no private tabs in it.
            var said: [String: Any] = ["tabs": browser.tabs.filter { request["session"] == nil || !$0.shy }.map(describe)]
            // A test's: the corner's "… needs you", and the tabs out of sight.
            if request["session"] == nil {
                said["calling"] = Agents.shared.calling?.name ?? ""
                // Whether this window's corner says it (a private one doesn't).
                said["callingHere"] = Agents.speaks(in: browser) ? Agents.shared.calling?.name ?? "" : ""
                said["corneredHere"] = Agents.shared.corneredAll(in: browser).count
                said["sealed"] = browser.tabs.filter { Agents.shared.sealed($0) }.map(Bench.short)
            }
            answer(said)

        case "applescript":
            // osascript run as this app's child, so macOS counts the app
            // itself as the sender and asks nobody for Automation, which a
            // probe's fresh bundle id would wait on for good on the farm
            // (evals/applescript). A --test run only: it runs a script.
            guard Store.testing else { answer(["error": "applescript only works on a --test run"]); return }
            let source = request["source"] as? String ?? ""
            // "inprocess": run here with NSAppleScript instead, the event
            // sent to this app itself: no second process, no Automation at
            // all, to tell the dictionary's answer from macOS's question.
            // From the run loop, where an event from outside arrives, not
            // inside this block of the main queue: a handler that waits for
            // the window (make new tab) waits on that queue's later blocks.
            if request["inprocess"] as? Bool == true {
                RunLoop.main.perform {
                    var failure: NSDictionary?
                    // JXA through OSAKit, as the Raycast extension reads tabs (evals/raycast).
                    if request["language"] as? String == "JavaScript", let jxa = OSALanguage(forName: "JavaScript") {
                        let result = OSAScript(source: source, language: jxa).executeAndReturnError(&failure)
                        answer(["stdout": result?.stringValue ?? "", "exit": failure == nil ? 0 : 1,
                                "stderr": failure.map { "\($0[OSAScriptErrorMessageKey] ?? "") (\($0[OSAScriptErrorNumberKey] ?? ""))" } ?? ""])
                        return
                    }
                    let result = NSAppleScript(source: source)?.executeAndReturnError(&failure)
                    answer(["stdout": result?.stringValue ?? "", "exit": failure == nil ? 0 : 1,
                            "stderr": failure.map { "\($0[NSAppleScript.errorMessage] ?? "") (\($0[NSAppleScript.errorNumber] ?? ""))" } ?? ""])
                }
                return
            }
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // "language": "JavaScript" for JXA, as the Raycast extension reads tabs (evals/raycast).
            script.arguments = (request["language"] as? String == "JavaScript" ? ["-l", "JavaScript"] : []) + ["-e", source]
            let out = Pipe(), err = Pipe()
            script.standardOutput = out
            script.standardError = err
            script.terminationHandler = { done in
                let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let failed = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let code = Int(done.terminationStatus)
                DispatchQueue.main.async {
                    answer(["stdout": said.trimmingCharacters(in: .whitespacesAndNewlines),
                            "stderr": failed.trimmingCharacters(in: .whitespacesAndNewlines), "exit": code])
                }
            }
            do { try script.runValidated() } catch { answer(["error": "osascript: \(error.localizedDescription)"]); return }
            // A script still waiting at 80 s is stopped, so what it said comes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 80) { if script.isRunning { script.terminate() } }

        case "cookies":
            // A site's cookies in the tab's store, with how long each has
            // left, and whether WebKit's tracking prevention is on there
            // (LastingSignIns). A --test run only: they are sign-ins.
            guard Store.testing else { answer(["error": "cookies only works on a --test run"]); return }
            let store: WKWebsiteDataStore
            if let tab = find(request, in: browser) {
                guard let web = tab.webKitOnly("Bench cookie inspection") else { answer(["error": "Cookie inspection is not available on this engine yet"]); return }
                store = web.configuration.websiteDataStore
            } else { store = Store.websites }
            let host = (request["host"] as? String ?? "").lowercased()
            let tracking = NSSelectorFromString("_resourceLoadStatisticsEnabled")
            let on = store.responds(to: tracking) && store.value(forKey: "_resourceLoadStatisticsEnabled") as? Bool == true
            store.httpCookieStore.getAllCookies { cookies in
                MainActor.assumeIsolated {
                    let theirs = cookies.filter { host.isEmpty || $0.domain.lowercased().trimmingCharacters(in: ["."]).hasSuffix(host) }
                    answer(["tracking": on, "cookies": theirs.map { cookie -> [String: Any] in
                        ["name": cookie.name, "domain": cookie.domain, "httpOnly": cookie.isHTTPOnly,
                         "left": cookie.expiresDate.map { $0.timeIntervalSinceNow } ?? -1]
                    }])
                }
            }

        case "cookie-pour":
            // A big profile's sign-ins brought in, as Browser.takeCookies
            // does past its read: `count` made-up cookies made into
            // WebKit's and poured into the first store, or a space's own
            // (`space`), with a 5 ms heartbeat on the main thread the whole
            // way. The longest gap between beats is the longest the main
            // thread was held (crash #60, evals/cookie-import). Then how
            // many of them the store holds. A --test run only.
            guard Store.testing else { answer(["error": "cookie-pour only works on a --test run"]); return }
            let count = min(request["count"] as? Int ?? 10_000, 100_000)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let store = (request["space"] as? Bool ?? false) ? Spaces.store(for: UUID()) : Store.websites
            var last = ProcessInfo.processInfo.systemUptime, longest: TimeInterval = 0, over100 = 0, over250 = 0
            let beat = Timer(timeInterval: 0.005, repeats: true) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                let gap = now - last
                last = now
                longest = max(longest, gap)
                if gap >= 0.1 { over100 += 1 }
                if gap >= 0.25 { over250 += 1 }
            }
            RunLoop.main.add(beat, forMode: .common)
            let began = ProcessInfo.processInfo.systemUptime
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ["Default": CookiePour.madeUp(count, tag: String(tag))]
                CookiePour.convert(found) { made in
                    Hangs.phase("cookies.set")
                    CookiePour.pour((made["Default"] ?? []).map { (store, $0) }) { poured in
                        let took = ProcessInfo.processInfo.systemUptime - began
                        beat.invalidate()
                        store.httpCookieStore.getAllCookies { all in
                            MainActor.assumeIsolated {
                                let landed = all.filter { $0.domain.hasSuffix("-\(tag).example") }.count
                                answer(["poured": poured, "landed": landed, "seconds": (took * 1000).rounded() / 1000,
                                        "longest_ms": (longest * 1000).rounded(), "over100": over100, "over250": over250,
                                        "way": Narrow.cookiePour ? "new" : "old", "bulk": { if #available(macOS 26.0, *) { return Narrow.cookieBulk } else { return false } }()])
                            }
                        }
                    }
                }
            }

        case "newtab":
            // ⌘T, without a key. A --test run only: it opens a tab of yours.
            guard Store.testing else { answer(["error": "newtab only works on a --test run"]); return }
            browser.newTab()
            answer(["ok": true])

        case "disk-trim":
            // The daily pass of SiteCaches and the shots' limit, now, with
            // `idle` seconds for "not visited lately" and `shots` bytes for
            // the pictures' limit (evals/disk-growth). A --test run only.
            guard Store.testing else { answer(["error": "disk-trim only works on a --test run"]); return }
            let idle = request["idle"] as? Double ?? SiteCaches.idle
            let limit = (request["shots"] as? Double).map { Int($0) } ?? Diary.shotsLimit
            SiteCaches.sweep(idle: idle) { sites in
                Diary.shared.trimShots(limit: limit) { shots in
                    Diary.shared.lastVisits { visits in
                        Store.websites.fetchDataRecords(ofTypes: SiteCaches.types) { records in
                            answer(["sites": sites, "shots": shots, "visited": (visits ?? [:]).keys.sorted(),
                                    "records": records.map(\.displayName).sorted()])
                        }
                    }
                }
            }

        case "adopt":
            // An agent's tab made yours, as a folder's keeps it: its next
            // page loads without the agent's frame script. A --test run only.
            guard Store.testing else { answer(["error": "adopt only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            tab.adopt()
            tab.agent = nil
            answer(describe(tab))

        case "flood":
            // Many tabs of yours at once, behind the one on screen, loading,
            // or asleep. A --test run only: they are your tabs, not the bench's.
            guard Store.testing else { answer(["error": "flood only works on a --test run"]); return }
            let urls = (request["urls"] as? [String] ?? []).compactMap(Address.url(from:))
            browser.flood(urls, asleep: request["asleep"] as? Bool ?? false)
            answer(["tabs": browser.tabs.count])

        case "unflood":
            // Every tab but the one on screen and the bench's, closed.
            guard Store.testing else { answer(["error": "unflood only works on a --test run"]); return }
            let gone = browser.tabs.filter { !$0.bench && $0.id != browser.activeID }
            gone.forEach { browser.close($0) }
            answer(["closed": gone.count])

        case "census":
            // How many tabs, in what state, and how the main thread has kept
            // up since the last census (YAB_HANGS=1 runs).
            let mine = browser.tabs
            var out: [String: Any] = [
                "tabs": mine.count,
                "asleep": mine.filter(\.asleep).count,
                "built": mine.filter { $0.builtPage != nil }.count,
                "loading": mine.filter { $0.builtPage != nil && $0.loading }.count,
                "pid": Int(getpid()),
                "live_seen": LiveSeen.count,
                // Every Tab object still in memory, closed ones a reference
                // keeps included: a live folder's churn must not raise it.
                "tabs_alive": Tab.every.count,
            ]
            if Hangs.enabled { Hangs.start(); out["lag"] = Hangs.lag() }
            out["thrift"] = Thrift.on
            // "collect": what pages dropped, collected now (Garbage).
            if request["collect"] as? Bool == true { Garbage.collect() }
            out["collected"] = Garbage.count
            out["sleep_after"] = Browser.sleepAfter
            if request["weights"] as? Bool == true {
                out["weights_mb"] = Dictionary(uniqueKeysWithValues: mine.map { (Bench.short($0), Int($0.weight >> 20)) })
            }
            if request["doze"] as? Bool == true { browser.sleepIdle(within: 0) }
            answer(out)

        case "processes":
            // Every page process WebKit runs, its memory and tabs, what
            // lingered after it was let go, and why pages ended (PageProcesses).
            answer(PageProcesses.report(browser))

        case "pressure":
            // Memory short, as far as the relief can tell, at this level
            // (2 warning, 4 critical, 0 to go back to what the kernel
            // says), and the relief started. A --test run only.
            guard Store.testing else { answer(["error": "pressure only works on a --test run"]); return }
            let level = request["level"] as? Int ?? 0
            // "age": every hidden tab as if left alone that many seconds,
            // since memory out takes only tabs left alone ten minutes.
            if let age = request["age"] as? Double { browser.ageForTidy(hours: age / 3600) }
            Pressure.forced = level > 0 ? level : nil
            browser.relieve()
            answer(["level": Pressure.level ?? 0])

        case "shield":
            // The ad blocker: its lists, how the last build went and where
            // it ran, and what fitting the lists to pages has cost the main
            // thread. "refresh" fetches the lists now, whatever their age.
            // "enabled" is the switch in Settings, "pause" with "on" the one
            // for a site (a --test run only, both change settings). "cycle"
            // takes every list off the tab named by "id" and puts it back,
            // that many times, and says what each round held the main thread
            // (a --test run only), then gives the tab what it should have.
            if request["refresh"] as? Bool == true { Shield.shared.refresh(now: true) }
            if request["rebuild"] as? Bool == true { Shield.shared.compile() }
            // "add_source": a filter subscription added as Settings adds
            // one, fetched and built at once; "adding" opens Settings' field
            // for one (a --test run only, both change settings).
            if Store.testing, let raw = request["add_source"] as? String {
                var out = Shield.shared.report
                out["added"] = Shield.shared.addSource(raw)
                answer(out)
                return
            }
            if Store.testing, request["adding"] as? Bool == false {
                NotificationCenter.default.post(name: ShieldSourceSettings.benchAdding, object: false)
            }
            if Store.testing, request["adding"] as? Bool == true {
                // "url": that address in the field, checked as if pasted.
                NotificationCenter.default.post(name: ShieldSourceSettings.benchAdding, object: request["url"] as? String)
                // Tall enough for the field under the lists in one picture.
                if let window = SettingsWindow.shared.window, let screen = window.screen?.visibleFrame {
                    let height = min(screen.height, 1000)
                    window.setFrame(NSRect(x: window.frame.minX, y: screen.maxY - height, width: window.frame.width, height: height), display: true)
                }
            }
            if Store.testing, let on = request["enabled"] as? Bool { browser.prefs.shielded = on }
            if Store.testing, let host = request["pause"] as? String { browser.pauseShield(host, request["on"] as? Bool ?? true) }
            // "toggle": the site's switch in Site Controls pressed on the tab
            // named by "id", reload and all (a --test run only).
            if Store.testing, let host = request["toggle"] as? String, let tab = find(request, in: browser) { browser.switchBlocking(host, on: tab) }
            // "blocker": the ad blocker card answered (docs/ad-blocker-source.md):
            // an extension's id, "builtin" or "keep" (a --test run only).
            if Store.testing, let pick = request["blocker"] as? String { Blockers.benchAnswer(pick) }
            // Finding which list costs a page what (a --test run only):
            // "skip" leaves lists off every page by their place, [] puts
            // them all back; "anatomy" counts each list's rules by kind;
            // "trial" puts part of one list on pages in its place, the
            // rules of "kind" from "from" to "to", "others" kept or not,
            // and "trial": -1 takes it off.
            if Store.testing, let skip = request["skip"] as? [Int] { Shield.shared.skipping = Set(skip) }
            // "forget_quiet": every site watched afresh (QuietSites).
            if Store.testing, request["forget_quiet"] as? Bool == true { Shield.shared.forgetQuiet() }
            if Store.testing, request["anatomy"] as? Bool == true {
                Task.detached(priority: .userInitiated) {
                    let anatomy = Shield.anatomy()
                    await MainActor.run { answer(Shield.shared.report.merging(["anatomy": anatomy]) { a, _ in a }) }
                }
                return
            }
            if Store.testing, let index = request["trial"] as? Int {
                if index < 0 { Shield.shared.trial = nil; answer(Shield.shared.report); return }
                let kind = request["kind"] as? String ?? "all", from = request["from"] as? Int ?? 0
                let to = request["to"] as? Int ?? Int.max, others = request["others"] as? Bool ?? true
                Task.detached(priority: .userInitiated) {
                    let (list, made) = await Shield.trial(index, kind: kind, from: from, to: to, others: others)
                    await MainActor.run {
                        if let list { Shield.shared.trial = (index, list) }
                        answer(Shield.shared.report.merging(["made": made]) { a, _ in a })
                    }
                }
                return
            }
            var out = Shield.shared.report
            out["blockers"] = Blockers.report
            if let site = request["said"] as? String {
                out["said"] = SiteControlsView.blockSaid(site: site, paused: Shield.shared.isPaused(on: site), persistent: true)
            }
            // "tally" with "id": what that tab's page had blocked, and
            // whether it had the lists or a quiet site's list.
            if Store.testing, request["tally"] as? Bool == true, let tab = find(request, in: browser), let chromium = tab.builtPage as? ChromiumPage {
                Task { @MainActor in answer(await chromium.shieldStatus()) }
                return
            }
            if Store.testing, request["tally"] as? Bool == true, let tab = find(request, in: browser), let controller = tab.webKitOnly("WebKit-only bench fixtures", build: false)?.configuration.userContentController {
                answer(Shield.shared.tally(controller))
                return
            }
            if Store.testing, let rounds = request["cycle"] as? Int, let tab = find(request, in: browser), let controller = tab.webKitOnly("WebKit-only bench fixtures", build: false)?.configuration.userContentController {
                let lists = Shield.shared.lists
                let one = request["one"] as? Bool == true ? Array(lists.prefix(1)) : lists
                let t0 = CACurrentMediaTime()
                for _ in 0..<rounds {
                    one.forEach { controller.remove($0) }
                    one.forEach { controller.add($0) }
                }
                out["cycle_ms"] = (CACurrentMediaTime() - t0) * 1000 / Double(max(rounds, 1))
                out["cycle_lists"] = one.count
                Shield.shared.refit(controller, after: one)
            }
            answer(out)

        case "thrift":
            // Saving power, whatever the battery says. A --test run only.
            guard Store.testing else { answer(["error": "thrift only works on a --test run"]); return }
            Thrift.forced = request["on"] as? Bool ?? true
            answer(["thrift": Thrift.on, "sleep_after": Browser.sleepAfter])

        case "energy-saver":
            // Settings › Tabs › Energy Saver: the choice, Yab's own saving,
            // and what the Chromium helper last said it holds (evals/energy-saver).
            if let raw = request["set"] as? String {
                guard let choice = EnergySaver(rawValue: raw) else { answer(["error": "set: off, low or unplugged"]); return }
                EnergySaver.current = choice
            }
            let power = Power.now()
            answer(["setting": EnergySaver.current.rawValue, "thrift": Thrift.on, "chromium_state": ChromiumEnergySaver.state,
                    "chromium": ChromiumEnergySaver.answer, "on_battery": power.onBattery, "percent": power.percent ?? -1])

        case "switcher":
            // ⌃Tab's walk without the keys: "step" as a press while ⌃ is
            // down, "land" as ⌃ let go of, "cancel" as Escape; each answers
            // the walk's tiles, their spaces and where it is.
            guard Store.testing else { answer(["error": "switcher only works on a --test run"]); return }
            switch request["act"] as? String ?? "state" {
            case "step": browser.switchStep(request["by"] as? Int ?? 1)
            case "land": browser.landSwitch()
            case "cancel": browser.cancelSwitch()
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.3)) {
                let walk = browser.switcher
                answer(["open": walk.open, "at": walk.at,
                        "pictured": walk.order.filter { walk.pictures[$0.id] != nil }.count,
                        "tiles": walk.order.map { ["title": $0.title, "url": $0.address?.absoluteString ?? "",
                                                   "space": walk.homes[$0.id]?.name ?? browser.space.name] },
                        "space": browser.space.name, "active": browser.active?.address?.absoluteString ?? ""])
            }

        case "spaces":
            var out: [String: Any] = ["spaces": browser.spaces.map { ["name": $0.name, "id": $0.id.uuidString, "current": $0.id == browser.spaceID,
                                                                    "own": $0.ownSignIns, "icon": $0.icon] },
                                      "on": browser.prefs.usesSpaces, "parked": browser.parked.mapValues(\.tabs.count).count,
                                      // What this window shows: none in a private one (register 1015).
                                      "shown": browser.spacesShown, "foot": browser.footShowsSpaces, "named": browser.namesSpaces,
                                      "order": browser.turnOrder.map(\.name)]
            // With a site: each store, and whether it is signed in there.
            guard let raw = request["site"] as? String, !raw.isEmpty else { answer(out); return }
            let host = (Address.url(from: raw)?.host() ?? raw).lowercased()
            SignIns.check(host, in: browser, allowed: allowed) { places in
                out["site"] = SignIns.site(host)
                out["places"] = places.map { place in
                    ["spaces": place.spaces.map(\.name), "seen": place.seen.rawValue, "current": place.holds(browser.spaceID),
                     "own": place.spaces.contains(where: \.ownSignIns)] as [String: Any]
                }
                answer(out)
            }

        case "sidecol":
            // The column of tabs as it stands: its view, its host and their
            // layers, and the window it is in (bug #46: drawn empty after a
            // page's own full screen).
            var out: [String: Any] = ["column": browser.column?.benchState ?? ["none": true],
                                      "immersed": browser.active?.immersed ?? false, "full": browser.fullScreen,
                                      "sidebar": browser.prefs.sidebar, "shut": browser.prefs.sideShut,
                                      "shown": Double(browser.sideShown), "width": Double(browser.prefs.sideWidth),
                                      "peek": browser.sidePeek]
            if let window = Links.window {
                // Every column view in the window, the one the browser
                // knows of or not: one going out may outstay its leaving.
                func columns(in view: NSView) -> [NSView] {
                    view.subviews.flatMap { ($0 is ColumnView) ? [$0] : columns(in: $0) }
                }
                out["columns"] = (window.contentView.map(columns) ?? []).map { view -> [String: Any] in
                    let shown = view.layer?.presentation() ?? view.layer
                    return ["id": "\(ObjectIdentifier(view).hashValue)", "known": view === browser.column,
                            "frame": [Double(view.frame.minX), Double(view.frame.minY), Double(view.frame.width), Double(view.frame.height)],
                            "shown_x": Double(shown?.frame.minX ?? 0), "opacity": Double(shown?.opacity ?? 1),
                            "host_alpha": Double(view.superview?.alphaValue ?? 1),
                            "host_x": Double((view.superview?.layer?.presentation() ?? view.superview?.layer)?.frame.minX ?? 0),
                            "host_opacity": Double((view.superview?.layer?.presentation() ?? view.superview?.layer)?.opacity ?? 1)]
                }
                out["occluded"] = !window.occlusionState.contains(.visible)
                out["key"] = window.isKeyWindow
                out["visible"] = window.isVisible
                func backdrops(in view: NSView) -> [WindowBackdropView] {
                    if let backdrop = view as? WindowBackdropView { return [backdrop] }
                    return view.subviews.flatMap { backdrops(in: $0) }
                }
                out["backdrops"] = (window.contentView.map(backdrops) ?? []).map { view in
                    var report = view.glassReport
                    report["id"] = "\(ObjectIdentifier(view).hashValue)"
                    report["hidden"] = view.isHiddenOrHasHiddenAncestor
                    report["opacity"] = Double(view.layer?.opacity ?? 1)
                    return report
                }
            }
            if let page = browser.active?.builtPage {
                // Either engine: the view the page is drawn by, and WebKit's
                // or Chromium's own full screen state.
                let web: NSView = page
                if let kit = page.webKit {
                    out["page_full"] = kit.fullscreenState != .notInFullscreen
                    out["fullscreen_state"] = kit.fullscreenState.rawValue
                } else if let remote = page as? ChromiumPage {
                    out["page_full"] = remote.media.fullscreen
                    out["fullscreen_state"] = remote.media.fullscreen ? 2 : 0
                }
                out["page_window"] = web.window === Links.window ? "ours" : web.window == nil ? "none" : "other"
                out["page_window_number"] = web.window?.windowNumber ?? -1
                // The page as it is drawn wherever it is, WebKit's window
                // too, through a page's own full screen (register 1089).
                let layer = web.layer?.presentation() ?? web.layer
                out["page_layer"] = [
                    "hidden": web.isHiddenOrHasHiddenAncestor, "alpha": Double(web.alphaValue),
                    "opacity": Double(layer?.opacity ?? -1), "masked": layer?.mask != nil,
                    "transform": layer.map { CATransform3DIsIdentity($0.transform) } ?? true,
                    "frame": [web.frame.minX, web.frame.minY, web.frame.width, web.frame.height].map { Double($0) },
                    "sublayers": web.layer?.sublayers?.count ?? 0,
                    "animations": web.layer?.animationKeys() ?? [],
                    "chain": sequence(first: web as NSView, next: { $0.superview }).dropFirst().prefix(4).map { String(describing: type(of: $0)) },
                    "window": web.window.map { String(describing: type(of: $0)) } ?? "none",
                ] as [String: Any]
            }
            answer(out)

        case "private-folder-check":
            guard Store.testing else { answer(["error": "test session required"]); return }
            answer(privateFolderCheck(request, browser: browser))

        case "rowframes":
            // Where each tab's row of the space on screen is drawn, in the
            // window from its top-left, as `drag` takes points.
            answer(["space_carry": ColumnSpaceCarry.of(browser)?.state ?? [:],
                    "line": browser.keptLine.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [],
                    "rows": browser.tabs.compactMap { tab -> [String: Any]? in
                // A pin says where it is to the key sky only.
                guard let rect = browser.drawnRows[DrawnRows.tab(tab.id)] ?? (tab.pin != nil ? browser.keySky.place(tab.id) : nil) else { return nil }
                return ["id": tab.id.uuidString, "title": tab.title, "pinned": tab.pin != nil,
                        "frame": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }]
            }, "folders": browser.folderBook.folders.compactMap { folder -> [String: Any]? in
                guard let rect = browser.drawnRows[DrawnRows.folder(folder.id)] else { return nil }
                return ["id": folder.id, "name": folder.nest?.name ?? "", "frame": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }]
            }, "spaces": browser.spaces.compactMap { space -> [String: Any]? in
                guard let rect = SpaceSlot.drawn[space.id] else { return nil }
                return ["name": space.name, "frame": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }]
            }, "capsule": SpaceAnchors.dot.flatMap { dot -> [Double]? in
                // The space's capsule a tab is held over to open the tray,
                // in the window from its top-left.
                guard let content = dot.window?.contentView else { return nil }
                let rect = dot.convert(dot.bounds, to: content)
                // SwiftUI's host is flipped: its y already runs down.
                return [rect.minX, content.isFlipped ? rect.minY : content.bounds.height - rect.maxY, rect.width, rect.height].map { Double($0) }
            } ?? []])

        case "droptarget":
            // Which view a link or a file dragged in from outside would be
            // handed to at `at` (the window's points from its top-left): the
            // first, from the view under it outward, registered for what is
            // dragged, as AppKit looks for one.
            guard let content = Links.window?.contentView, let at = request["at"] as? [Double], at.count == 2 else { answer(["error": "droptarget needs at"]); return }
            // The window's own point, from its bottom left: what the frame
            // view, which has no superview, hit-tests in.
            let point = NSPoint(x: at[0], y: content.bounds.height - at[1])
            var chain: [String] = []
            var target = ""
            // Every view up the chain that takes any drag, and what.
            var takes: [String: [String]] = [:]
            var view = content.superview?.hitTest(point) ?? content.hitTest(point)
            while let each = view {
                chain.append(String(describing: type(of: each)).prefix(60).description)
                let types = Set(each.registeredDraggedTypes)
                if !types.isEmpty { takes["\(chain.count - 1) " + chain.last!] = types.map(\.rawValue).sorted().prefix(12).map { $0 } }
                if target.isEmpty, types.contains(.URL) || types.contains(.fileURL) || types.contains(.string) || types.contains(NSPasteboard.PasteboardType("public.url")) {
                    target = String(describing: type(of: each)).prefix(80).description
                }
                view = each.superview
            }
            answer(["target": target, "chain": Array(chain.prefix(12)), "types": takes])

        case "wheelscript":
            // A mouse wheel's notches or a trackpad's flick over the page in
            // front, posted on their own clock (PageWheelBench, evals/m1-scroll).
            // `animator`: whether the page's WebKit animates a notch.
            guard let web = (browser.peeking ?? browser.active)?.page else { answer(["error": "no page"]); return }
            var out = PageWheelBench.post(request, over: web)
            out["animator"] = web.webKit.flatMap { WebFeature.isOn("ScrollAnimatorEnabled", in: $0.configuration.preferences) } ?? "unknown"
            out["animation_default"] = UserDefaults.standard.object(forKey: "NSScrollAnimationEnabled") ?? "unset"
            // Whether notches glide (WheelGlide), and how many it took and sent so far.
            if let page = web as? PageView {
                out["glide"] = ["on": WheelGlide.on, "notches": page.glide.notches, "events": page.glide.events, "passed": page.glide.passed, "offered": page.glide.offered]
            }
            answer(out)

        case "spacewheel":
            // A mouse's wheel over the column (SpaceWheel): `notches` events
            // of `dx`, `dy` lines (`smooth`: points, precise, no phase),
            // `gap` seconds apart, `shift` held, at `y` points down from the
            // window's top (the rows' middle without it). `off`: the wheel
            // let through, as before #282, for a before picture.
            if let off = request["off"] as? Bool { SpaceSwipe.wheelOff = off }
            let point = Spin.columnPoint(y: request["y"] as? Double, x: request["x"] as? Double)
            Spin.wheel(dx: request["dx"] as? Double ?? 0, dy: request["dy"] as? Double ?? 0,
                        count: request["notches"] as? Int ?? 1, gap: request["gap"] as? Double ?? 0.05,
                        smooth: request["smooth"] as? Bool ?? false, shift: request["shift"] as? Bool ?? false, at: point)
            answer(["ok": true, "at": point.map { [Double($0.x), Double($0.y)] } ?? [], "under": Spin.viewChain(at: point)])

        case "colwheel":
            // One scroll over the column's rows, `dy` points (negative
            // down), whichever column draws them.
            Spin.wheelColumn(request["dy"] as? Double ?? -120)
            answer(["ok": true])

        case "willchange":
            // What reading objectWillChange costs, as SwiftUI reads it for
            // every @ObservedObject on every update: µs a read, of the
            // window's Browser, its Preferences and its tab in front.
            func time(_ read: () -> Void) -> Double {
                let start = CACurrentMediaTime()
                for _ in 0..<2000 { read() }
                return ((CACurrentMediaTime() - start) * 1_000_000 / 2000 * 100).rounded() / 100
            }
            var out: [String: Any] = ["browser_us": time { _ = browser.objectWillChange }, "prefs_us": time { _ = browser.prefs.objectWillChange }]
            if let tab = browser.active { out["tab_us"] = time { _ = tab.objectWillChange } }
            answer(out)
        case "coltrack":
            // The rows of the space on screen as drawn, every display frame
            // for `seconds` (the render server's presentation layers), while
            // something else, a drag, moves them: [{t, rows: {id: {y, ...}}}].
            let seconds = request["seconds"] as? Double ?? 2
            let start = CACurrentMediaTime()
            var frames: [[String: Any]] = []
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let pages = ColumnPages.live.allObjects.first { $0.window === browser.column?.window }
                    let t = CACurrentMediaTime() - start
                    // "pages": every page drawn, a row of spaces sliding
                    // included, each one's keyed by its space's name.
                    var rows = pages?.shown?.onScreen ?? [:]
                    if request["pages"] as? Bool == true, let pages {
                        rows = [:]
                        for (id, page) in pages.pages where !page.isHidden {
                            let name = browser.spaces.first { $0.id == id }?.name ?? id.uuidString
                            for (key, row) in page.onScreen { rows[name + ":" + key] = row }
                        }
                    }
                    frames.append(["t": (t * 1000).rounded() / 1000, "rows": rows])
                    if t >= seconds {
                        timer.invalidate()
                        answer(["frames": frames])
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)

        case "bodyaudit":
            // Bodies run inside a setter since the last ask (BodyAudit).
            let seen = BodyAudit.seen
            BodyAudit.seen = [:]
            answer(["seen": seen.map { ["at": $0.key, "n": $0.value] }])

        case "columnkit":
            // The AppKit column (ColumnKit, ColumnPages): on or not, its
            // pages, the cells each has in sight and pooled, how often rows
            // were handed to SwiftUI, how long the last laying took. With
            // "scroll", the page on screen scrolled to that many points.
            var out: [String: Any] = ["on": ColumnKit.on, "pages_made": ColumnPages.made, "cells_made": ColumnPage.cellsMade,
                                      "bound": ColumnCell.bound, "last_sync_ms": (ColumnPages.lastSync * 100).rounded() / 100]
            let pages = ColumnPages.live.allObjects.filter { $0.window === browser.column?.window }
            if let y = request["scroll"] as? Double { pages.first?.shown?.scroll(to: CGFloat(y)) }
            out["row_bodies"] = ColumnKit.rowBodies
            // Layings in all, from AppKit's layout pass, and told by what
            // the last one read (feedback #298).
            out["syncs"] = ColumnPages.syncs
            out["laid_syncs"] = ColumnPages.laidSyncs
            out["told_syncs"] = ColumnPages.toldSyncs
            out["afresh"] = ColumnPage.afresh
            out["readies"] = ColumnPages.readies
            out["hosts_made"] = ColumnPages.hostsMade
            out["scrolls_heard"] = columnScrollsHeard
            out["arrives"] = ColumnPage.arrives
            out["slides"] = ColumnPage.slides
            out["motions"] = ColumnPage.motions
            out["unfolds"] = FaceView.unfolds
            out["turning_skipped"] = ColumnPages.turningSkipped
            out["turning_who"] = ColumnPages.turningWho
            // Browser windows open, for a tab taken out to a new one.
            out["windows"] = NSApp.windows.filter { $0.isVisible && BrowserWindows.shared.browser(for: $0) != nil }.count
            if request["reset"] as? Bool == true { ColumnKit.rowBodies = 0 }
            out["pages"] = pages.flatMap { $0.pages.values.map(\.state) }
            answer(out)

        case "pager":
            // The column's row of spaces (SpacePager): where it is drawn,
            // whether the column's own drawing of its band is masked, and,
            // with "path", the band pictured as a change would picture it,
            // and how long that took the main thread.
            var out = SpacePager.shared.state
            out["refused"] = SpacePager.refusal(browser) ?? ""
            // What the column's two-finger catch and the row made of the
            // last gestures (SpaceSwipe.note).
            out["swipe_trace"] = SpaceSwipe.trace
            if let ink = SpacePager.shared.ink { out["ink"] = ink }
            out["frosts"] = browser.column?.frostCount ?? -1
            // The column's own plate up (sidebar "Search or type a URL").
            out["plated"] = browser.sidePlated
            // While the pages are up: what of the window draws in the band
            // past the mask, to show through the row.
            if SpacePager.shared.active, let column = browser.column {
                out["leaks"] = column.leaks(SpacePager.shared.band)
            }
            if let column = browser.column, let band = column.spaceBand(browser), browser.prefs.sideShut {
                let top = Metrics.floatInset + browser.menuDown
                out["ground_layers"] = column.groundCount(CGRect(x: band.minX, y: top, width: band.width, height: column.bounds.height - top - Metrics.floatInset))
            }
            out["rows_clip"] = browser.rowsClip.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0) } } ?? []
            out["floor"] = browser.spaceFloor.map { Double($0) } ?? -1
            out["pins_top"] = browser.pinsTop.map { Double($0) } ?? -1
            out["name_top"] = browser.nameTop.map { Double($0) } ?? -1
            if let column = browser.column {
                out.merge(column.spaceMasked) { a, _ in a }
                if let band = column.spaceBand(browser) {
                    out["band"] = [band.minX, band.minY, band.width, band.height].map { Double($0) }
                    if let path = request["path"] as? String {
                        let t0 = Bench.mainCPU()
                        let picture = column.picture(band)
                        out["picture_cpu_ms"] = ((Bench.mainCPU() - t0) * 100).rounded() / 100
                        if let picture, let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, picture, nil)
                            out["written"] = CGImageDestinationFinalize(destination)
                        }
                    }
                }
            }
            answer(out)

        case "reach":
            // A click that should take you to a tab wherever it is (another
            // space, another window): "agent", the Mac's notification of an
            // agent's question; "pip", the system picture's button back to
            // its page. The tab by the start of its id. A --test run only.
            guard Store.testing else { answer(["error": "reach only works on a --test run"]); return }
            let prefix = (request["id"] as? String ?? "").lowercased()
            let owner = BrowserWindows.shared.browsers.lazy.compactMap { owner in
                owner.everyTab.first { $0.id.uuidString.lowercased().hasPrefix(prefix) }.map { (owner, $0) }
            }.first
            guard !prefix.isEmpty, let (owner, tab) = owner else { answer(["error": "no tab \(prefix)"]); return }
            switch request["how"] as? String ?? "" {
            case "agent":
                AgentNotices.shared.browser = owner
                AgentNotices.shared.open(tab.id.uuidString)
            case "pip":
                guard let web = tab.webKitOnly("Native picture-in-picture return") else { answer(["error": "Native picture-in-picture is not available on this engine yet"]); return }
                owner.webViewFullscreenMayReturnToInline(web)
            default: answer(["error": "how: agent or pip"]); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                answer(["space": browser.space.name, "front": browser.active.map(Bench.short) ?? "",
                        "reached": browser.activeID == tab.id])
            }

        case "fieldsections":
            // A --test run's hand on Settings › Search's Before You Type: the
            // parts turned off, one moved first, where Frequent comes from.
            guard Store.testing else { answer(["error": "fieldsections only works on a --test run"]); return }
            let sections = FieldSections.shared
            if let off = request["off"] as? [String] {
                for section in FieldSection.allCases { sections.set(section, on: !off.contains(section.rawValue)) }
            }
            if let first = (request["first"] as? String).flatMap(FieldSection.init) { sections.move(first, before: sections.order.first) }
            if let reach = request["reach"] as? String { Store.settings.set(reach, forKey: FrequentReach.key) }
            if request["open"] as? Bool == true { SettingsWindow.shared.show(.search, for: browser) }
            answer(["order": sections.order.map(\.rawValue), "off": sections.off.map(\.rawValue).sorted()])
        case "space-profile-open":
            guard Store.testing, let text = request["url"] as? String, let url = URL(string: text) else {
                answer(["error": "test session and URL required"]); return
            }
            // The ordinary user route: agent/bench pages intentionally do not
            // record history and cannot prove profile history or pin retention.
            answer(describe(browser.open(url, foreground: true)))
        case "space-profile-state":
            guard Store.testing else { answer(["error": "test session required"]); return }
            answer(["settings": SettingsWindow.shared.benchWhere,
                    "history": browser.history.everything().map { $0.url.absoluteString },
                    "profiles": browser.spaces.map { ["id": $0.id.uuidString, "name": $0.name, "profile": $0.profileID.uuidString] }])
        case "space":
            // A --test run's hand on the spaces: switch to one by name or
            // index, make one, or delete one, without their menu.
            guard Store.testing else { answer(["error": "space only works on a --test run"]); return }
            if let on = request["on"] as? Bool { browser.prefs.usesSpaces = on }
            if let path = request["downloadDirectory"] as? String {
                DownloadFolder.set(path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true), for: browser.spaceID)
            }
            // Pins: "every" or "each", as Settings › Spaces sets it (SharedPins.swift).
            if let pins = request["pins"] as? String { browser.prefs.pinsEverySpace = pins == "every" }
            // Settings › Tabs' "Today's tabs in every window" (KeptEverywhere.swift).
            if let today = request["today"] as? Bool { browser.prefs.todayEveryWindow = today }
            if let name = request["new"] as? String { browser.addSpace(named: name, ownSignIns: request["own"] as? Bool ?? false) }
            if let own = request["signins"] as? Bool { browser.setSpaceSignIns(browser.spaceID, own: own) }
            if let profile = request["profile"] as? String {
                let peer = browser.spaces.first { $0.name == profile || $0.id.uuidString == profile }
                if profile == "own" || peer != nil { browser.setSpaceProfile(browser.spaceID, with: peer?.id) }
            }
            if let name = request["to"] as? String, let space = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                browser.switchSpace(to: space.id)
            }
            // The space on screen's emoji or symbol (SpaceSymbols).
            if let icon = request["icon"] as? String { browser.setSpaceIcon(browser.spaceID, to: icon) }
            // The space on screen's own engine, as its page in Settings sets
            // it: an Engine's raw value, "default" for Settings › Search's.
            if let search = request["search"] as? String {
                browser.setSpaceSearch(browser.spaceID, to: search == "default" ? nil : search, custom: request["searchCustom"] as? String)
            }
            // The space on screen's own look, as Settings › Spaces or the
            // look card keeps it: its swatch, transparency and Liquid Glass.
            if request["transparency"] != nil || request["glass"] != nil || request["swatch"] != nil {
                var paint = browser.space.paint ?? SpacePaint(browser.prefs)
                if let amount = request["transparency"] as? Double { paint.transparency = BackdropTransparency.clamp(amount) }
                if let on = request["glass"] as? Bool { paint.glass = on }
                if let swatch = request["swatch"] as? String { paint.swatch = swatch }
                browser.setSpacePaint(browser.spaceID, to: paint)
            }
            if let step = request["step"] as? Int {
                StageView.mark("input", ["what": "space-step"])
                browser.stepSpace(step)
            }
            if let name = request["delete"] as? String, let space = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                browser.deleteSpace(space.id)
            }
            // A row dragged in Settings › Spaces: that space to that place.
            if let name = request["move"] as? String, let place = request["place"] as? Int,
               let space = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                browser.moveSpace(space.id, to: place)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["current": browser.space.name, "tabs": browser.tabs.map(Bench.short), "spaces": browser.spaces.map(\.name),
                        "parked": Dictionary(browser.parked.map { key, row in (key == Space.pinsID ? "shared pins" : browser.spaces.first { $0.id == key }?.name ?? key.uuidString, row.tabs.count) },
                                             uniquingKeysWith: +),
                        // Each parked space's addresses, and the corner's words (evals/link-routes-pages).
                        "rows": Dictionary(browser.parked.compactMap { key, row in
                            browser.spaces.first { $0.id == key }.map { ($0.name, row.tabs.map { ($0.pending ?? $0.address)?.absoluteString ?? "" }) }
                        }, uniquingKeysWith: +),
                        "urls": browser.tabs.map { ($0.pending ?? $0.address)?.absoluteString ?? "" },
                        "corner": browser.toaster.shown ? browser.toaster.words : "",
                        "pinsShared": browser.pinsShared, "shared": (browser.sharedPins ?? []).map(Bench.short),
                        "search": browser.space.search ?? "", "engine": browser.searchEngine.name,
                        "look": ["transparency": browser.space.paint?.transparency ?? -1, "glass": browser.space.paint?.glass ?? false,
                                 "worn": browser.prefs.backdropTransparency, "wornGlass": browser.prefs.lookGlass]])
            }

        case "strip-turn":
            // Parts of the strip's turn left out ("cut": leaving, arrival,
            // carousel, slide), for `pace` to weigh each (evals/dia-top-spaces).
            if let cut = request["cut"] as? [String] { StripTurn.cut = Set(cut) }
            answer(["cut": StripTurn.cut.sorted()])
        case "spacetray":
            // A --test run's hand on the new space's tray: open it, fill it
            // in, move it along, and read back where it stands.
            guard Store.testing else { answer(["error": "spacetray only works on a --test run"]); return }
            let act = request["act"] as? String ?? "state"
            let tray = SpaceTray.shown
            let value = request["value"] as? String ?? ""
            switch act {
            case "open": SpaceTray.open(browser)
            case "spaces": SpaceTray.openSpaces(browser)
            case "pick": if let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }) { tray?.pick(space.id) }
            case "new": tray?.startNew()
            // Where a space's row of the tray stands, in the window from its
            // top-left ("value": its name, or "new"), for a drag to go to.
            case "rowpoint":
                guard let tray, let content = tray.window?.contentView else { answer(["error": "no tray"]); return }
                let index = value == "new" ? -1 : browser.spaces.firstIndex { $0.name.lowercased() == value.lowercased() } ?? 0
                let at = tray.rowPoint(index)
                answer(["point": [Double(at.x), Double(content.bounds.height - at.y)]])
                return
            // A tab carried to the capsule, held, over a space's row (value:
            // its name, or "new"), and let go, as SpaceDrop sees a drag;
            // "tab": the tab's title, the one in front otherwise. "hold":
            // stop over the row without letting go.
            case "carry":
                let carried = (request["tab"] as? String).flatMap { title in browser.tabs.first { $0.title.localizedCaseInsensitiveContains(title) } } ?? browser.active
                guard let carried, let dot = SpaceAnchors.dot, let window = dot.window else { break }
                let capsule = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
                _ = SpaceDrop.shared.track([carried], browser: browser, at: capsule)
                let hold = request["hold"] as? Bool ?? false
                DispatchQueue.main.asyncAfter(deadline: .now() + SpaceDrop.wait + 0.45) {
                    guard let tray = SpaceTray.shown else { return }
                    let index = value == "new" ? -1 : browser.spaces.firstIndex { $0.name.lowercased() == value.lowercased() } ?? 0
                    _ = SpaceDrop.shared.track([carried], browser: browser, at: tray.rowPoint(index))
                    _ = window
                    if !hold { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = SpaceDrop.shared.finish(browser) } }
                }
            // A folder of yours ("folder": its name) carried whole onto a
            // space ("value": its name) in the foot's row and let go, as the
            // column's drag hands it to SpaceDrop; "hold": stop over it.
            case "carryfolder":
                guard let name = request["folder"] as? String, let nest = browser.nests.first(where: { $0.name == name }),
                      let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }),
                      let at = SpaceAnchors.slotPoint(space.id)
                else { answer(["error": "carryfolder needs a folder and a space in the foot's row"]); return }
                let held = SpaceDrop.shared.track(browser.tabs(in: nest), browser: browser, folder: nest, at: at)
                if !(request["hold"] as? Bool ?? false) { _ = SpaceDrop.shared.finish(browser) }
                answer(["held": held, "slot": SpaceDrop.shared.slot?.uuidString ?? ""])
                return
            // Two fingers sideways over the column's foot, as a trackpad's
            // scroll with its phases: "value" is how far, in points,
            // negative to the left, over "over" seconds (0.3).
            // "lift": false sends no end, as when a swipe of three fingers to
            // another desktop takes it to a window there.
            case "swipe":
                Bench.swipe(by: Double(value) ?? -120, over: request["over"] as? Double ?? 0.3, hold: request["hold"] as? Double ?? 0,
                            lift: request["lift"] as? Bool ?? true)
            // One scroll event of a trackpad's alone, "value" its phase:
            // maybegin, began, ended or cancelled; "over" the column's foot
            // or the page, "window" none for no window of Yab's.
            case "touch":
                Bench.touch(value, page: request["over"] as? String == "page", windowless: request["window"] as? String == "none")
            // A click on the page, down and up.
            case "click":
                Bench.click()
            // The desktop changed, as macOS says when a swipe or Mission
            // Control takes you to another.
            case "desktop":
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            // The tab in front sent to a space, as ⌃⇧N does; "undo" puts it back.
            case "send": if let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }) { lastMove = browser.moveTabs(browser.chosen, to: space.id) }
            case "undo": if let move = lastMove { browser.undoMove(move) }
            case "askdelete": if let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }) { tray?.askDelete(space) }
            case "reemoji": if let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }) { tray?.changeEmoji(of: space) }
            case "focus": tray?.draft.focus = Int(value)
            case "name": tray?.draft.name = value
            case "step": if let step = ["spaces": SpaceDraft.Step.spaces, "start": .start, "name": .name, "emoji": .emoji, "color": .color, "signins": .signIns][value] { tray?.go(step) }
            case "swatch": if let swatch = Swatch(rawValue: value) { tray?.draft.pick(swatch: swatch) }
            case "custom": if let color = NSColor(hex: value) { tray?.draft.pick(swatch: .custom); tray?.draft.custom = color }
            case "grain": tray?.draft.grain = Double(value) ?? (value == "off" ? 0 : Grain.standard)
            case "own": tray?.draft.own = value != "off"
            case "emoji": tray?.draft.pick(icon: value)
            // Words typed into the field that has the keys, the icon step's search.
            case "type": (tray?.window?.firstResponder as? NSTextView)?.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            case "take": tray?.take(value != "off")
            case "forward": tray?.forward()
            case "leave": tray?.leave()
            case "visit": if let url = URL(string: value) { browser.active?.go(to: url) }
            // Everything under the window's frame at this speed, to film.
            case "speed":
                Links.window?.contentView?.superview?.layer?.speed = Float(value) ?? 1
            // The tray opened and where it is drawn every 16 ms after.
            case "sample":
                SpaceTray.openSpaces(browser)
                var seen: [[Double]] = []
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        seen.append(SpaceTray.shown?.drawn ?? [])
                        if seen.count >= 24 { timer.invalidate(); answer(["drawn": seen]) }
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                return
            // Where the tray's layer hangs, up to the window's root.
            case "layers":
                var chain: [String] = []
                var view: NSView? = tray
                while let v = view {
                    chain.append("\(type(of: v)) wants=\(v.wantsLayer) layer=\(v.layer.map { "\(type(of: $0))" } ?? "nil") super=\(v.layer?.superlayer.map { "\(type(of: $0))" } ?? "nil")")
                    view = v.superview
                }
                var layer = tray?.layer
                var up: [String] = []
                while let l = layer { up.append("\(type(of: l)) anims=\(l.animationKeys() ?? [])"); layer = l.superlayer }
                answer(["views": chain, "layers": up]); return
            case "rename":
                // Its menu's Rename…, for the space on screen: the card, its
                // line of text in the keys.
                SpaceAsk.name(browser.space, browser: browser) { browser.renameSpace(browser.space.id, to: $0) }
                answer(["ok": true]); return
            case "hit":
                // What a click on a row of the list would reach, a space's
                // place or -1 for New Space: the view AppKit hands it to.
                guard let tray = SpaceTray.shown, let content = Links.window?.contentView else { answer(["error": "no tray"]); return }
                let point = tray.rowPoint(Int(value) ?? -1)
                let hit = content.hitTest(content.convert(point, from: nil))
                answer(["hit": hit.map { "\(type(of: $0))" } ?? "nothing"]); return
            case "pin":
                // Kept in view over everything, on every desktop, so the
                // window server draws it while it is watched.
                if let window = Links.window {
                    window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
                    window.level = .floating
                    // "x,y": its top left there, clear of whatever else is up.
                    let at = value.split(separator: ",").compactMap { Double($0) }
                    if at.count == 2, let screen = window.screen {
                        window.setFrameTopLeftPoint(NSPoint(x: at[0], y: screen.frame.maxY - at[1]))
                    }
                    window.orderFrontRegardless()
                }
            default: break
            }
            // When the act was done, on the host's clock, for a film's frames
            // to be timed against.
            let done = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.45)) {
                let now = SpaceTray.shown
                var state: [String: Any] = ["at": done, "pull": Bench.swipeLog, "progress": Double(SpacePull.shared.progress), "open": now != nil, "visible": Links.window?.occlusionState.contains(.visible) == true, "space": browser.space.name, "icon": browser.space.icon,
                                            "spaces": browser.spaces.map(\.name), "swatch": browser.prefs.swatch.rawValue,
                                            "grain": browser.prefs.grain, "color": browser.prefs.backdropColor.hex,
                                            "tabs": browser.tabs.count]
                // The capsule, and each row of the tray, in the window's
                // points from its top left, for a drag to aim at.
                if let dot = SpaceAnchors.dot, let content = Links.window?.contentView {
                    let r = dot.convert(dot.bounds, to: nil)
                    state["capsule"] = [r.midX, content.bounds.height - r.midY]
                    if let now, let content = Links.window?.contentView {
                        state["rows"] = (-1..<browser.spaces.count).map { index -> [Double] in
                            let p = now.rowPoint(index)
                            return [Double(p.x), Double(content.bounds.height - p.y)]
                        }
                    }
                }
                if let now {
                    let f = now.panelFrame
                    state["step"] = String(describing: now.draft.step)
                    state["frame"] = [f.minX, f.minY, f.width, f.height]
                    state["name"] = now.draft.name
                    state["draft"] = ["icon": now.draft.icon, "swatch": now.draft.swatch.rawValue, "grain": now.draft.grain, "own": now.draft.own]
                }
                answer(state)
            }

        case "taskstate":
            // A bench task's session to another state ("done"). Test runs only.
            guard Store.testing, let id = request["session"] as? String,
                  let state = (request["state"] as? String).flatMap(Agents.State.init(rawValue:)) else {
                answer(["error": "taskstate needs session and state"])
                return
            }
            Agents.shared.benchTask(id, state: state)
            answer(["ok": true])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            if Bench.mailLeaves(url, session: request["session"] as? String, browser: browser, answer: answer) { return }
            // "shy": in a private tab. Test runs only.
            let shy = Store.testing && request["shy"] as? Bool == true
            func open(in space: UUID?, note: String?) {
                guard allowed() else { answer(["error": "This task's permission expired."]); return }
                // `open` never borrows a user's tab, even for the exact URL.
                // Work explicitly requested in an existing tab uses its id.
                let session = request["session"] as? String
                // Left on this page by an agent that is done: taken over.
                if !shy, request["fresh"] as? Bool != true, let session,
                   let tab = leftover(url, space: space, session: session, in: browser) {
                    tab.agent = session
                    tab.settled = nil
                    tab.go(to: url)
                    Agents.shared.wentElsewhere(session)
                    house(tab)
                    var out = describe(tab)
                    if let note { out["space_note"] = note }
                    answer(out)
                    return
                }
                let tab = browser.benchOpen(url, space: space, shy: shy)
                tab.agent = request["session"] as? String ?? Agents.script
                browser.keepAgentPagesFew(opened: tab)
                // "task": the session a task asked for in words, in this
                // state (running, done). Test runs only.
                if let state = (request["task"] as? String).flatMap(Agents.State.init(rawValue:)), let id = request["session"] as? String {
                    Agents.shared.benchTask(id, state: state)
                }
                // A task asked for on a page that opens a tab of its own
                // went elsewhere: followed in the chat column from here.
                Agents.shared.wentElsewhere(request["session"] as? String)
                // "plain": a tab as yours would be, with no face at its end, so
                // what the end shows otherwise can be seen. Test runs only.
                if Store.testing, request["plain"] as? Bool == true { tab.agent = nil }
                house(tab)
                var out = describe(tab)
                if let note { out["space_note"] = note }
                answer(out)
            }
            // Signed in where a space of the user's is, when the agent names
            // one; when it doesn't, where the site is signed in (SignIns).
            if let name = request["space"] as? String, !name.isEmpty {
                guard let found = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                    answer(["error": "no space named \(name): \(browser.spaces.map(\.name).joined(separator: ", "))"])
                    return
                }
                open(in: found.id, note: nil)
            } else if let host = url.host(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                SignIns.pick(host, in: browser, allowed: allowed) { open(in: $0, note: $1) }
            } else {
                open(in: nil, note: nil)
            }

        case "mute":
            guard Store.testing else { answer(["error": "mute only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            tab.mute(request["on"] as? Bool ?? true)
            answer(["muted": tab.muted, "noisy": tab.noisy])

        case "sound":
            // The page starting or stopping its noise, as WebKit would say
            // it, for the notes a tab sings (Chorus). fresh: never heard.
            guard Store.testing else { answer(["error": "sound only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if request["fresh"] as? Bool == true { browser.chorus.forget(tab.id) }
            if let on = request["on"] as? Bool { tab.noisy = on }
            answer(["noisy": tab.noisy, "muted": tab.muted, "sung": browser.chorus.sung,
                    "flying": browser.chorus.sky?.inFlight ?? 0, "unsung": browser.chorus.unsung])

        case "idle":
            // What the app costs while nobody touches it: the main thread's
            // own CPU time, how often its run loop woke, and the whole
            // process's CPU, over SECONDS. Taken on the main thread, so the
            // measuring itself is two readings and a counter.
            let seconds = min(request["seconds"] as? Double ?? 10, 20)
            func thread() -> Double {
                var t = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
                return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
            }
            func process() -> Double {
                var r = rusage()
                getrusage(RUSAGE_SELF, &r)
                return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1000 + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1000
            }
            var wakes = 0
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { _, _ in wakes += 1 }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            let main0 = thread(), all0 = process(), t0 = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let main1 = thread(), all1 = process(), elapsed = CACurrentMediaTime() - t0
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                answer([
                    "seconds": (elapsed * 100).rounded() / 100,
                    "main_cpu_ms": ((main1 - main0) * 10).rounded() / 10,
                    "main_cpu_pct": ((main1 - main0) / (elapsed * 10) * 100).rounded() / 100,
                    "process_cpu_pct": ((all1 - all0) / (elapsed * 10) * 100).rounded() / 100,
                    "main_wakes_per_s": (Double(wakes) / elapsed * 10).rounded() / 10,
                    "noisy": browser.tabs.filter(\.noisy).count,
                ])
            }

        case "runloop":
            // The main run loop as CoreFoundation describes it: every
            // mode's timers (callout, interval, next fire) and sources, so
            // an idle wake can be named (evals/release-smoke/perf.py).
            answer(["runloop": CFCopyDescription(CFRunLoopGetMain()) as String? ?? ""])

        case "go":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "go needs a url"])
                return
            }
            tab.go(to: url)
            answer(describe(tab))

        case "close":
            if (request["id"] as? String) == "all" {
                let mine = browser.tabs.filter { $0.bench }
                mine.forEach { browser.close($0) }
                answer(["closed": mine.count])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // A tab of yours an agent that came on its own (an assistant in
            // the cloud, Claude Code through `yab mcp`) worked in: it is done
            // there, so the tab is handed back, open as it is. Its foot
            // goes, as a task's does when it ends; such an agent never ends.
            if !tab.bench, let session = request["session"] as? String,
               let known = Agents.shared.session(session), known.state == .attached,
               tab.guest == session || tab.allowed.contains(session) {
                if tab.guest == session {
                    rest(tab)
                    tab.guest = nil
                }
                tab.allowed.remove(session)
                AgentFeed.shared.answered(tab)
                answer(["closed": 0, "handedBack": true, "id": Bench.short(tab)])
                return
            }
            // An extension's own window (windows.create on a Chromium tab),
            // closed as its red light closes it. A --test run only.
            if Store.testing, let made = ChromiumExtensionWindow.showing(tab) {
                made.close()
                answer(["closed": 1, "extensionWindow": true])
                return
            }
            guard tab.bench else {
                answer(["error": "not a bench tab, only tabs the bench opened can be closed from here"])
                return
            }
            browser.close(tab)
            answer(["closed": 1])

        case "wait":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
            if let words = request["text"] as? String, !words.isEmpty {
                house(tab)
                look(for: words, in: tab, until: limit, answer)
            } else {
                wait(for: tab, until: limit, answer)
            }

        case "clear-data":
            // What Settings and Site Controls clear, past their questions. A --test run only.
            guard Store.testing else { answer(["error": "clear-data only works on a --test run"]); return }
            let tab = find(request, in: browser) ?? browser.active
            switch request["what"] as? String ?? "" {
            case "sites": browser.clearSites()
            case "cache": browser.clearCache()
            case "history": browser.clearHistory()
            case "cookies": tab?.clearCookiesAndReload()
            case "fail-chromium":
                // Chromium's side of Clear Data and Sign Out answers that it failed.
                ChromiumSiteData.failsForTesting = request["on"] as? Bool ?? false
            case "owed":
                answer(["owed": ChromiumClearingDebt.owed]); return
            case "site":
                guard let tab, let site = request["site"] as? String else { answer(["error": "tab and site required"]); return }
                Task { @MainActor in await browser.forgetSite(site, tab: tab); answer(["ok": true]) }
                return
            default: answer(["error": "what?"]); return
            }
            answer(["ok": true])

        case "untrusted":
            // The Untrusted page in a tab, and with go, its Continue.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let shown = tab.untrusted
            if request["go"] as? Bool == true { tab.continuePastUntrusted() }
            answer(["untrusted": shown?.host ?? "", "url": shown?.url.absoluteString ?? "", "excusable": shown?.exception != nil])

        case "capture":
            // What the camera and microphone question would find remembered
            // for a page at scheme, host and port, asked the way WebKit asks,
            // without WebKit, which puts the question off while the window
            // isn't the one in use. A --test run only: it can move a key.
            guard Store.testing else { answer(["error": "capture only works on a --test run"]); return }
            let site = Browser.origin(scheme: request["scheme"] as? String ?? "https",
                                      host: request["host"] as? String ?? "", port: request["port"] as? Int ?? 0)
            let type = PageCapture(rawValue: request["type"] as? Int ?? 0) ?? .camera
            let key = Browser.captureKey(site, type)
            let said = Browser.remembered(key, host: request["host"] as? String ?? "", type)
            answer(["key": key, "said": said.map { $0 ? "allow" : "deny" } ?? "ask"])

        case "share":
            // Sharing a screen (Share.swift), driven and read. "ask": the
            // page's window.startShare(), run as a click would; "door"
            // (tabs, windows, screens), "type", "pick", "arrow" and
            // "answer" (yes, no, system): the box, as it is turned, typed
            // in and pressed; "stop": what the tab shares; "state": the
            // box's open door and its tiles, and every share with its
            // place and frames in flight.
            // A --test run only.
            guard Store.testing else { answer(["error": "share only works on a --test run"]); return }
            let tab = find(request, in: browser) ?? browser.active
            func picker() -> SharePicker? {
                guard let question = tab?.asks.first, case .share(let picker) = question.kind else { return nil }
                return picker
            }
            func state() -> [String: Any] {
                var out: [String: Any] = ["sessions": Share.shared.sessions.values.map { session -> [String: Any] in
                    [
                        "id": session.id, "caller": session.caller.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
                        "shown": session.shown.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
                        "system": session.source == nil, "native": session.native, "hearing": session.hearing, "open": session.feed?.open ?? false, "sending": session.sending,
                        "recorder": session.recorder ?? "",
                        "sent": session.sent, "dropped": session.dropped,
                        "rect": [session.rect.minX, session.rect.minY, session.rect.width, session.rect.height],
                    ]
                }]
                if let picker = picker() {
                    out["picker"] = [
                        "typed": picker.typed, "allowed": picker.allowed, "sees": picker.sees, "chosen": picker.chosen?.title ?? "",
                        "door": picker.door.rawValue, "doors": picker.doors.map(\.rawValue), "onDoors": picker.onDoors,
                        "sections": picker.sections.map { section in
                            ["title": section.title, "items": section.items.map { ["title": $0.title, "picture": $0.picture != nil] }] as [String: Any]
                        },
                    ] as [String: Any]
                }
                out["words"] = browser.everyTab.filter { $0.sharing || $0.seen }.map { ($0.sharing ? "Presenting " : "Shown ") + $0.rowLabel }
                out["active"] = browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""
                out["spot"] = "\(browser.shareSpot)"
                out["status"] = Share.shared.status(in: browser, over: browser.active)?.words ?? ""
                out["paused"] = Share.shared.sessions.values.contains { $0.paused }
                out["outlines"] = Share.shared.sessions.values.compactMap { $0.outline?.report }
                out["open"] = Share.shared.sessions.values.contains { $0.fold?.open == true }
                out["window"] = BrowserWindows.shared.window(for: browser).map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? []
                out["boxes"] = AskView.all.allObjects.compactMap(\.probe)
                out["keyWindow"] = NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"
                out["systemAsked"] = Share.shared.systemAsked
                out["trail"] = Share.shared.trail
                return out
            }
            let settle = request["settle"] as? Double ?? 0.4
            func later() { DispatchQueue.main.asyncAfter(deadline: .now() + settle) { answer(state()) } }
            switch request["action"] as? String ?? "state" {
            case "ask":
                guard let tab else { answer(missing(request)); return }
                let web = tab.page
                RelayGuard.vouch(web)
                web.call("window.startShare && window.startShare(); return true", arguments: [:], in: .page) { _ in }
                later()
            case "door":
                if let picker = picker(), let door = (request["door"] as? String).flatMap(SharePicker.Kind.init(rawValue:)),
                   picker.doors.contains(door) { picker.door = door }
                later()
            case "type":
                picker()?.typed = request["text"] as? String ?? ""
                later()
            case "pick":
                if let picker = picker() {
                    let items = picker.sections.flatMap(\.items), index = request["index"] as? Int ?? 0
                    if items.indices.contains(index) { picker.chosenID = items[index].id }
                }
                later()
            case "keys":
                // Keys as macOS hands them to the app: each a key event sent
                // through NSApp to the key window, wherever its first
                // responder is, as a person's keyboard reaches the box.
                // "left" "right" "up" "down" "tab" "backtab" "return"
                // "escape", or a letter to type.
                let named: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
                    "left": (123, "\u{F702}", [.function, .numericPad]), "right": (124, "\u{F703}", [.function, .numericPad]),
                    "down": (125, "\u{F701}", [.function, .numericPad]), "up": (126, "\u{F700}", [.function, .numericPad]),
                    "tab": (48, "\t", []), "backtab": (48, "\u{19}", [.shift]), "return": (36, "\r", []), "escape": (53, "\u{1B}", []),
                ]
                for key in request["keys"] as? [String] ?? [] {
                    let (code, chars, flags) = named[key] ?? (key.first.map { Bench.keyCode(for: $0) } ?? 0, key, [])
                    let target = NSApp.keyWindow ?? BrowserWindows.shared.window(for: browser)
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: target?.windowNumber ?? 0, context: nil,
                                                           characters: chars, charactersIgnoringModifiers: key == "backtab" ? "\t" : chars,
                                                           isARepeat: false, keyCode: code) else { continue }
                        NSApp.sendEvent(event)
                    }
                }
                later()
            case "arrow":
                let way = request["way"] as? String
                picker()?.move(way == "up" ? .up : way == "down" ? .down : way == "left" ? .left : .right)
                later()
            case "answer":
                guard let tab else { answer(missing(request)); return }
                let said = request["said"] as? String ?? "yes"
                browser.answer(tab, said == "no" ? .no : .yes(said == "system" ? "system" : nil))
                later()
            case "stop":
                guard let tab else { answer(missing(request)); return }
                Share.shared.stop(caller: tab)
                later()
            case "engine":
                // ⌘K's Open in: this tab on the engine named, for a share
                // between a WebKit tab and a Chromium one.
                guard let tab else { answer(missing(request)); return }
                tab.openHere(in: request["engine"] as? String == "webkit" ? .webKit : .chromium)
                later()
            case "instead":
                // Share Instead on ID's row, as the pointer would press it.
                guard let tab else { answer(missing(request)); return }
                guard let session = Share.shared.switchable(to: tab) else { answer(["error": "nothing to share instead"]); return }
                Share.shared.switchShown(session, to: tab)
                later()
            default:
                answer(state())
            }

        case "call":
            // Calls (Calls.swift, FloatCall.swift, Meetings.swift), driven and
            // read. "mock": WebKit's made-up camera and microphone for the
            // tab's pages, and the site allowed both, so a local page can be
            // on a call with no device and no question; "state": every call,
            // its dot, the window; "mic"/"camera": as the dot's click;
            // "shut": ⌘W; "leave", "tuck", "untuck", "press": the window's;
            // "sweep": the minute after a call ends, gone by; "meetings":
            // made-up meetings, [{title, in, for, link}] in minutes, then
            // what the pin and the call's tab say. A --test run only.
            guard Store.testing else { answer(["error": "call only works on a --test run"]); return }
            let tab = find(request, in: browser)
            func state() -> [String: Any] {
                let calls = browser.everyTab.filter(\.onCall).map { tab -> [String: Any] in
                    let look = CaptureDot.look(tab.cam, tab.mic)
                    return [
                        "id": String(tab.id.uuidString.prefix(8)).lowercased(),
                        "mic": "\(tab.mic.rawValue)", "camera": "\(tab.cam.rawValue)",
                        "page_mic": tab.pageMic.map { $0 ? "off" : "on" } ?? "-",
                        "dot": look.filled ? "filled" : "ring", "red": look.red,
                        "help": CaptureDot.help(tab.cam, tab.mic),
                        "key": CallLink.key(tab.callStarted ?? tab.address) ?? "",
                        "left": Meetings.shared.minutesLeft(for: CallLink.key(tab.callStarted ?? tab.address)) ?? 0,
                        "screen": "\(tab.screen.rawValue)",
                        "screen_now": "\(tab.webKitOnly("WebKit-only bench fixtures", build: false).map(Tab.screenState(of:))?.rawValue ?? 0)",
                        "devices": tab.callDevices.map { d -> [String: Any] in
                            let each = { (list: [CallDevices.Device]) in list.map { ($0.on ? "✓ " : "") + $0.title } }
                            return ["mics": each(d.mics), "speakers": each(d.speakers), "cameras": each(d.cameras), "sharable": d.sharable]
                        } ?? [:],
                    ]
                }
                var badge = "none"
                switch Meetings.shared.badge(inCall: { browser.inCall($0) }) {
                case .minutes(let n): badge = "\(n)m"
                case .join: badge = "join"
                case nil: break
                }
                let pids = browser.everyTab.filter(\.onCall).compactMap { tab -> Int? in
                    (tab.webKitOnly("WebKit-only bench fixtures", build: false)?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue
                }
                let gpu = browser.everyTab.lazy.compactMap { ($0.webKitOnly("WebKit-only bench fixtures", build: false)?.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.intValue }.first { $0 > 0 }
                return [
                    "pids": pids, "gpu": gpu ?? 0,
                    "calls": calls, "live": browser.calls.live.count, "over": browser.calls.over.count,
                    "floating": browser.floating.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "kind": browser.floater.kind == .call ? "call" : "video", "showing": browser.floater.showing,
                    "toast": browser.toaster.shown ? browser.toaster.words : "", "tabs": browser.tabs.count,
                    "badge": badge, "active": browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    // The corner's meeting card, and the page light it stands against.
                    "reminder": Meetings.shared.reminder?.title ?? "",
                    "reminder_float": MeetingFloat.shared.state,
                    "shade": browser.active?.shade.map { $0 == .dark ? "dark" : "light" } ?? "",
                ]
            }
            let settle = request["settle"] as? Double ?? 0.6
            func later() { DispatchQueue.main.asyncAfter(deadline: .now() + settle) { answer(state()) } }
            switch request["action"] as? String ?? "state" {
            case "relay-state":
                guard let tab else { answer(missing(request)); return }
                answer(["mic": tab.pageMic as Any? ?? NSNull(), "camera": tab.pageCamera as Any? ?? NSNull(),
                        "engine": tab.engineKind.rawValue, "onCall": tab.onCall])
            case "mock":
                guard let tab else { answer(missing(request)); return }
                guard let web = tab.webKitOnly("WebKit mock capture devices") else { answer(["error": "WebKit mock capture is not available on this engine"]); return }
                let preferences = web.configuration.preferences
                for name in ["_setMockCaptureDevicesEnabled:", "_setMediaCaptureRequiresSecureConnection:"] {
                    let selector = NSSelectorFromString(name)
                    guard preferences.responds(to: selector) else { continue }
                    typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(preferences.method(for: selector), to: Set.self)(preferences, selector, name.contains("Mock"))
                }
                if let site = Browser.origin(of: tab.address ?? URL(string: request["url"] as? String ?? "")) {
                    for type in [PageCapture.camera, .microphone, .cameraAndMicrophone] {
                        Store.settings.set(true, forKey: Browser.captureKey(site, type))
                    }
                }
                later()
            case "corner":
                // The probe's window kept over everything, small, in the
                // screen's corner and deaf to the pointer: a covered window
                // is a hidden page to WebKit, and a hidden page gets no camera.
                guard let window = Links.window, let screen = window.screen ?? NSScreen.main else { answer(["error": "no window"]); return }
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.level = .floating
                window.ignoresMouseEvents = true
                let area = screen.visibleFrame
                window.setFrame(NSRect(x: area.minX + 8, y: area.minY + 8, width: 900, height: 560), display: true)
                later()
            // The screen: Share as the window's button has it (the page's own
            // pressed, or a share stopped); "stopshare" as the dot's menu.
            case "share":
                if browser.floatingCall != nil { browser.floater.pressCall("share") } else { browser.call.map { browser.shareScreen($0) } }
                later()
            case "stopshare": browser.call?.stopSharing(); later()
            // The call's devices read from its page, and the window's menus
            // as they would open; "pick" chooses one (kind, label) in the
            // page's menu; "plug" is a device come (or gone, came 0) as the
            // Mac would say it; "use" presses the word's Use.
            case "devices":
                guard let call = browser.call else { answer(missing(request)); return }
                call.readCallDevices {
                    answer(state().merging([
                        "mic_menu": browser.floater.callMenuItems(.mic), "camera_menu": browser.floater.callMenuItems(.camera),
                    ]) { a, _ in a })
                }
            case "pick":
                let kind = CallDeviceKind(rawValue: request["kind"] as? String ?? "") ?? .mic
                let label = request["label"] as? String ?? ""
                // By title first: the Mac's own choice has its device's label too.
                let list = browser.call?.callDevices?.list(kind) ?? []
                guard let call = browser.call, let device = list.first(where: { $0.title == label }) ?? list.first(where: { $0.label == label })
                else { answer(["error": "no such device"]); return }
                call.pickCallDevice(kind, device)
                later()
            case "plug":
                browser.callDeviceChanged(request["label"] as? String, CallDeviceKind(rawValue: request["kind"] as? String ?? "") ?? .mic,
                                          came: request["came"] as? Bool ?? true)
                later()
            case "use": browser.floater.pressCall("use"); later()
            // The microphone's menu ("kind": "camera", the camera's) open
            // on the screen, as its arrow's click opens it, for "seconds"
            // (4), for a picture with the menu in it (#257). Answered
            // first: the open menu holds the run loop until it closes.
            case "open-menu":
                let which: CallControls.Devices = request["kind"] as? String == "camera" ? .camera : .mic
                let seconds = request["seconds"] as? Double ?? 4
                guard browser.floatingCall != nil else { answer(["error": "no floating call"]); return }
                answer(state().merging(["pid": Int(ProcessInfo.processInfo.processIdentifier)]) { a, _ in a })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        NSApp.activate(ignoringOtherApps: true)
                        _ = browser.floater.openCallMenu(which, seconds: seconds)
                    }
                }
            case "mic": browser.call.map { $0.muteMicrophone($0.heard) }; later()
            case "camera": browser.call.map { $0.turnCamera($0.cam == .muted) }; later()
            case "menu": browser.toggleCallMic(); later()
            case "shut":
                guard let tab else { answer(missing(request)); return }
                browser.shut([tab], byKey: true)
                later()
            case "lift":
                guard let tab else { answer(missing(request)); return }
                browser.liftCall(tab)
                later()
            // A page of HTML in the tab as if it came from "url" (WebKit's
            // simulated request): a call site's own origin, https and so a
            // secure context, for a local fixture, nothing from the network.
            case "simulate":
                guard let tab, let url = URL(string: request["url"] as? String ?? ""), let html = request["html"] as? String
                else { answer(missing(request)); return }
                if tab.engineKind == .chromium {
                    tab.page.navigate(html: html, base: url)
                    later()
                    return
                }
                guard let web = tab.webKitOnly("WebKit simulated request") else { answer(["error": "Simulated requests are not available on this engine yet"]); return }
                // Apply the ordinary host policy before the simulated load.
                // Otherwise Slack's agent change cancels it for a network reload.
                _ = SiteAgent.apply(web, for: url)
                web.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
                later()
            case "leave", "tuck", "untuck", "press", "shareable", "width", "flick", "near", "away", "tap", "reply",
                 "tray-enter", "tray-exit", "tray-admit", "tray-deny", "tray-reply", "shape":
                let action = request["action"] as? String ?? ""
                if action == "leave" {
                    browser.floater.pressCall("leave")
                    later()
                } else {
                    browser.floater.bench(["action": action, "button": request["button"] as? String ?? "",
                                           "x": request["x"] as? Double ?? 0, "y": request["y"] as? Double ?? 0]) { window in
                        answer(state().merging(["window": window]) { a, _ in a })
                    }
                }
            case "window": browser.floater.bench(["action": "state"]) { answer($0) }
            case "news":
                // What the call says beyond its people, as the window reads it.
                guard let web = (tab ?? browser.call)?.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); return }
                CallStage.run("news", on: web) { news in answer(["news": news ?? NSNull()]) }
            case "who":
                // Who the window shows, read and not drawn (CallStage's who).
                guard let web = (tab ?? browser.call)?.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); return }
                CallStage.run("who", on: web) { who in answer(["who": who ?? NSNull()]) }
            case "cost":
                // One look of the call's layout in its page, in ms.
                guard let web = (tab ?? browser.call)?.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); return }
                CallStage.run("cost", on: web) { ms in answer(["scan_ms": ms ?? NSNull()]) }
            case "sweep":
                browser.sweepEndedCalls(now: Date().addingTimeInterval(request["after"] as? Double ?? 61))
                later()
            case "meetings":
                let made = (request["list"] as? [[String: Any]])?.enumerated().map { n, m -> Meeting in
                    let start = Date().addingTimeInterval((m["in"] as? Double ?? 0) * 60)
                    // `people`: addresses, for what is open with them on the card.
                    return Meeting(id: "bench\(n)", title: m["title"] as? String ?? "Meeting \(n)", start: start,
                                   end: start.addingTimeInterval((m["for"] as? Double ?? 30) * 60),
                                   link: (m["link"] as? String).flatMap(URL.init(string:)),
                                   people: (m["people"] as? [String] ?? []).map { $0.lowercased() })
                }
                Meetings.shared.pretend(made)
                later()
            case "join": browser.joinNextMeeting(); later()
            case "churn":
                // What a meeting's minute and a call's mute cost the window:
                // each is told N times, a frame apart, and the main thread's
                // own CPU over the run is the answer, less an idle run as long.
                let n = request["n"] as? Int ?? 40
                let which = request["which"] as? String ?? "meetings"
                func run(_ poke: Bool, _ done: @escaping (Double) -> Void) {
                    let cpu0 = Bench.mainCPU()
                    func step(_ i: Int) {
                        if i == n {
                            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(Bench.mainCPU() - cpu0) }
                        }
                        if poke {
                            if which == "calls" { browser.calls.objectWillChange.send() } else { Meetings.shared.objectWillChange.send() }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.017) { step(i + 1) }
                    }
                    step(0)
                }
                run(false) { idle in
                    run(true) { busy in
                        answer(["which": which, "n": n, "tabs": browser.tabs.count,
                                "idle_ms": (idle * 100).rounded() / 100, "busy_ms": (busy * 100).rounded() / 100,
                                "per_change_ms": (((busy - idle) / Double(n)) * 1000).rounded() / 1000])
                    }
                }
            case "meeting":
                // A local page counted as a meeting's, so a made-up meeting
                // with its link is this call.
                guard let tab, let host = tab.address?.host() else { answer(missing(request)); return }
                CallLink.benchHosts.insert(host.lowercased())
                tab.callStarted = tab.address
                later()
            case "calendar":
                // A local page counted as a calendar, pinned.
                guard let tab else { answer(missing(request)); return }
                if let host = tab.address?.host() { Meetings.benchCalendars.insert(host.lowercased()) }
                if tab.pin == nil { browser.pin(tab) }
                later()
            case "over":
                // A call over on this tab, as if it were a meeting's.
                guard let tab else { answer(missing(request)); return }
                browser.calls.over[tab.id] = Date()
                browser.sweepEndedCalls()
                later()
            default: later()
            }

        case "dark":
            // Dark pages (DarkPages.swift): the mode set ("withTheme",
            // "always", "off"), a site toggled as ⌥⇧D does, and what each
            // tab's page is now (evals/dark-pages).
            if let raw = request["mode"] as? String, let mode = DarkMode(rawValue: raw) { browser.prefs.darkPages = mode }
            // The engine once the document is parsed, for the eval's A/B.
            if let deferred = request["defer"] as? Bool { Store.settings.set(deferred, forKey: "pages.dark.defer") }
            // Site Controls over the page in front, for a look at its row.
            if request["controls"] as? Bool == true { browser.toggleExtensions() }
            // The Dark Pages sheet in a window of its own, for a picture
            // of it (a --test run only); answers its window number.
            // The sheet behind Customize…, over Settings › Appearance as a
            // click opens it; answers the sheet's window number.
            if Store.testing, request["sheet"] as? Bool == true {
                SettingsModel.ask(.websites)
                SettingsWindow.shared.show(for: browser)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NotificationCenter.default.post(name: DarkPagesSettings.open, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        answer(["window": SettingsWindow.shared.window?.attachedSheet?.windowNumber ?? 0])
                    }
                }
                return
            }
            if let toggle = request["toggle"] as? String {
                let tab = toggle == "front" ? browser.active : find(["id": toggle], in: browser)
                answer(["toggled": browser.toggleDarkPage(tab)])
                return
            }
            if request["forget"] as? Bool == true {
                for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("dark.") || key.hasPrefix("darkLearned.") {
                    Store.settings.removeObject(forKey: key)
                }
            }
            let tabs: [[String: Any]] = browser.tabs.map { tab in
                ["id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "dark": "\(tab.dark)",
                 "armed": tab.darkState.armed.rawValue, "page": tab.darkState.page.rawValue,
                 "learned": DarkPages.learned(PageScripts.host(of: tab.address))?.value.rawValue ?? "",
                 "appearance": tab.builtPage?.appearance?.name.rawValue ?? "", "engine": tab.engineKind.rawValue]
            }
            answer(["mode": DarkPages.active(windowDark: DarkPages.windowDark) ? DarkMode.read().rawValue : "inactive",
                    "windowDark": DarkPages.windowDark, "tabs": tabs, "arm": PageScripts.report, "version": DarkPages.version])

        case "sleep":
            // Now rather than after four hours, but past every other check
            // a tab has to clear, the answer says which one kept it awake.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.sleep(tab) { said in answer(["said": said, "asleep": tab.asleep]) }

        case "select":
            // Picking a tab takes the window over, which the bench never does
            // to someone using it: only on a YAB_PROBE run.
            guard Store.testing else {
                answer(["error": "select only works on a --test run, it would take your window over"])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // When the hand picked, for what the stage did after (stagetrace).
            StageView.mark("input", ["what": "select"])
            SwitchMarks.start(tab.id)
            // As a hand picks it: a page another window has comes over.
            let was = Browser.pretendHand
            Browser.pretendHand = true
            browser.select(tab)
            Browser.pretendHand = was
            // Taken over by the page that came, the tab now in its place.
            let came = tab.gone ? browser.tabs.first { other in
                tab.everywhere.map { other.everywhere == $0 } ?? (other.everywhere == nil && KeptEverywhere.key(other) == KeptEverywhere.key(tab))
            } : nil
            // A switch to a Chromium page lands on that page's frame: answered
            // then, for whoever reads the tab in front after this.
            func landed(_ tries: Int) {
                guard browser.switchPending != nil, tries > 0 else { answer(describe(came ?? tab)); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { MainActor.assumeIsolated { landed(tries - 1) } }
            }
            landed(200)

        case "chord":
            // Keys pressed the way the keyboard presses them, through the
            // app, its key monitor and menus first, then the page: "cmd+a",
            // "m", "escape", "return". Only on a YAB_PROBE run: it takes the window
            // over. Answers with what ⌘A's offer is doing (PageCopy.swift).
            guard Store.testing else { answer(["error": "chord only works on a --test run, it would press keys in your window"]); return }
            guard let tab = find(request, in: browser), let keys = request["keys"] as? String else { answer(missing(request)); return }
            let view = tab.page
            // "focus": false leaves the keys to whatever has them now, a
            // tab's name being written in its row, say.
            if request["focus"] as? Bool != false {
                browser.select(tab)
                view.window?.makeFirstResponder(view)
            }
            // "cmd+t@е": ⌘T as a non-Latin layout sends it, the key under T
            // typing е (see Keymap). "typed" and "code" say the same for a
            // request: what the key types and which key it is (AZERTY's &
            // on the 1 key).
            guard let (flags, name, typed) = Bench.chord(keys), name.count <= 1 || KeyLayout.names.contains(name) || request["code"] != nil
            else { answer(["error": "no key named \(keys): a letter, escape or return"]); return }
            // "post": queued for the window as the keyboard's keys are, for a
            // probe that isn't the active app (Bench.send).
            Bench.send(flags, name, request["typed"] as? String ?? typed, to: view.window ?? Links.window, code: (request["code"] as? Int).map(UInt16.init),
                       queued: request["post"] as? Bool ?? false, native: request["native"] as? Bool ?? false,
                       layout: request["layout"] as? Bool ?? false)
            DispatchQueue.main.asyncAfter(deadline: .now() + ((request["wait"] as? Double) ?? 0.6)) {
                let copier = browser.pageCopy
                let stage: String
                switch copier.stage {
                case nil: stage = "none"
                case .offering: stage = "offering"
                case .done(let pick): stage = "done:\(pick)"
                }
                let board = PageCopy.board.string(forType: .string) ?? ""
                answer([
                    "stage": stage, "words": copier.words, "canSave": copier.canSave,
                    "saved": copier.saved?.path ?? "",
                    "fileURL": PageCopy.board.string(forType: .fileURL) ?? "",
                    "clipboard": String(board.prefix(Int((request["chars"] as? Double) ?? 600))),
                    "clipboardLength": board.count,
                    // What the keys did to the window, for a shortcut's test.
                    "front": browser.active?.address?.absoluteString ?? "", "tabs": browser.tabs.count,
                    "settings": browser.tuning,
                ])
            }

        case "welcome":
            // The welcome put in any state of final-spec §4, as a person
            // would leave it, then pressed: a beat, a phase of it, every
            // branch pretended (WelcomeStage.bench).
            WelcomeStage.shared.bench(request, browser, answer: answer)

        case "teach":
            // The hints of Teach.swift: what was used and said, the waits
            // off, forgotten, or a trigger pulled as the page would. A
            // --test run only: it says things in the corner of yours.
            guard Store.testing else { answer(["error": "teach only works on a --test run"]); return }
            let teach = Teach.shared
            switch request["action"] as? String ?? "state" {
            case "reset": teach.reset()
            case "hurry": teach.hurried = request["on"] as? Bool ?? true
            case "shut": teach.shutSoon(in: browser)
            case "signin":
                guard let tab = browser.active else { answer(["error": "no tab"]); return }
                teach.signedIn(tab, host: request["host"] as? String ?? "example.com", user: request["user"] as? String ?? "one", in: browser)
            case "copy": browser.copyAddress()
            case "markdown": browser.copyMarkdownLink()
            case "bookmark": browser.bookmarkCurrent()
            case "act": browser.toaster.undone()
            case "folders":
                // The corner's Move To, as its menu would list them for the
                // newest bookmark, and with "into", picked.
                guard let last = browser.bookmarks.roots.last(where: { !$0.isFolder }) else { answer(["error": "no bookmark"]); return }
                // The menu Move To pops, read and, with "into", its line run
                // as a click on it would: the menu itself shuts the bench out.
                let menu = browser.folderMenu(for: last.id)
                if let name = request["into"] as? String {
                    guard let at = menu.items.firstIndex(where: { $0.title == name }) else { answer(["error": "no folder \(name)"]); return }
                    menu.performActionForItem(at: at)
                }
                answer(["folders": menu.items.map { ["title": $0.title, "depth": $0.indentationLevel] as [String: Any] },
                        "roots": browser.bookmarks.roots.map(\.title)])
                return
            case "state": break
            default: answer(["error": "teach: state, reset, hurry, shut, signin, copy, markdown, bookmark, act, folders"]); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.1)) {
                var out = teach.state
                let toaster = browser.toaster
                out["toast"] = toaster.shown ? ["words": toaster.words, "keys": toaster.keys, "act": toaster.act ?? ""] as [String: Any] : [:]
                out["spaces"] = browser.prefs.usesSpaces
                out["pairs"] = browser.pairs.count
                answer(out)
            }

        case "selection":
            // Commands for selected text, driven for screenshots: a page of
            // words and a field put in the tab in front, text selected in
            // one or the other, the list opened, or a result shown as the
            // model would leave it. A --test run only.
            guard Store.testing, let tab = browser.active, let web = tab.builtPage else { answer(["error": "selection needs a --test run and a tab"]); return }
            let commands = browser.selectionCommands
            let act = request["action"] as? String ?? "state"
            func done() {
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.4)) {
                    answer(["stage": "\(commands.stage)", "rows": commands.available.map(\.name),
                            "command": commands.command?.name ?? "", "output": commands.output,
                            // The answer in the field (FieldAnswer): its state, what ↩ and ⌘K do.
                            "answering": commands.answering, "fieldAnswering": browser.query.answering,
                            "turns": commands.turns.map { ["asked": $0.asked ?? "", "answer": $0.answer] },
                            "asked": commands.asked ?? "", "error": commands.error, "noChange": commands.noChange,
                            "replacing": commands.replacing, "original": commands.showOriginal,
                            "commandDock": commands.showsDock, "commandPreview": commands.showsDockResult,
                            "commandApplying": commands.applying, "commandReceipt": commands.receipt?.rawValue ?? "",
                            "executor": commands.command?.executor ?? "", "model": commands.command?.model ?? "",
                            "rewrite": browser.answerIsRewrite, "actions": browser.fieldActions.map(\.title),
                            "editing": browser.editing, "typed": browser.typed,
                            // The words ⌘J read, in a frame or a shadow root too.
                            "selected": browser.fieldSelection?.text ?? commands.snapshot?.text ?? "",
                            "sessions": Agents.shared.sessions.map { "\($0.cli) \($0.state) \($0.textOnly ? "text" : "task") \($0.result.prefix(120))" }])
                }
            }
            switch act {
            case "page":
                let html = """
                <style>body{font:17px/1.55 -apple-system,system-ui;margin:48px auto;max-width:640px;color:#1d1d1f}h1{font-size:30px}textarea{width:100%;height:120px;font:15px/1.5 -apple-system,system-ui;padding:12px;border:1px solid #d2d2d7;border-radius:10px}</style>
                <h1>Checkout, the new flow</h1>
                <p id=p>We moved the plan picker ahead of the card form, so people choose what they pay for before they are asked how to pay. Early numbers show fewer abandoned carts.</p>
                <p>Reply to Alex:</p>
                <textarea id=t>hi alex, thanks for the call tuesday. we can do the pilot in Q4 but 40k is to much for us, can we talk about 36k if we start in november?</textarea>
                """
                web.run("document.body.innerHTML = \(String(data: try! JSONSerialization.data(withJSONObject: [html]), encoding: .utf8)!)[0]; 1")
                done()
            case "text":
                web.run("(function(){const p=document.getElementById('p');const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,\(request["length"] as? Int ?? 104));const s=getSelection();s.removeAllRanges();s.addRange(r);return 1})()")
                done()
            case "field":
                web.run("(function(){const t=document.getElementById('t');t.focus();t.setSelectionRange(0,t.value.length);return 1})()")
                done()
            case "open":
                commands.open(on: tab)
                done()
            case "models":
                // The answer's model list, as ⇧⌘R opens it.
                browser.chooseAnswerModel()
                done()
            case "editor":
                SettingsWindow.shared.show(.commands, for: browser)
                NotificationCenter.default.post(name: CommandSettingsPage.benchEdit, object: nil, userInfo: ["id": ""])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: CommandSettingsPage.benchEdit, object: nil,
                        userInfo: ["id": request["command"] as? String ?? "improve", "advanced": request["advanced"] as? Bool ?? false])
                    done()
                }
            case "answer":
                // A command picked in the ⌘J field's list, answered there, as a click on its row.
                if let id = request["command"] as? String, let snap = browser.fieldSelection,
                   let command = commands.commands.first(where: { $0.id == id }) {
                    browser.answer(command, on: tab, snapshot: snap)
                }
                done()
            case "run":
                // A command run on the selection, as its key would: its answer over the page.
                if let id = request["command"] as? String { commands.open(on: tab, command: id) }
                done()
            case "result":
                // As the model would leave it: the command picked, its words
                // in. "stage" running (words still coming) or failed with an
                // "error"; "original" as if ⌥ were held. With nothing run yet,
                // the selection on the page is read first.
                let stage: SelectionCommands.Stage = switch request["stage"] as? String {
                case "running": .running
                case "failed": .failed
                default: .preview
                }
                let text = request["text"] as? String ?? ""
                let error = request["error"] as? String ?? ""
                func put(_ snap: SelectionSnapshot) {
                    guard let id = request["command"] as? String,
                          let command = commands.offered(for: snap, actions: []).first(where: { $0.id == id })
                            ?? commands.commands.first(where: { $0.id == id }) else { return }
                    commands.show(command, on: tab, snapshot: snap, stage: stage, output: text, error: error)
                    commands.showOriginal = request["original"] as? Bool ?? false
                }
                if let snap = commands.snapshot, commands.activeTab === tab { put(snap); done() }
                else { commands.peek(on: tab) { snap in if let snap { put(snap) }; done() } }
            case "replace":
                // Replace pressed, or Return: the words into the page.
                commands.apply()
                done()
            case "complete":
                // A deterministic model completion through the real receiver.
                // Test runs only (the whole selection bench is gated above).
                commands.receive(request["text"] as? String ?? "")
                done()
            case "cancel-command":
                commands.cancelCommand()
                done()
            case "undo-command":
                commands.undoReplacement()
                done()
            case "close":
                commands.close()
                done()
            case "hint":
                // The chip by a selection in a field, "Improve", as a pause
                // after selecting brings it up the first time.
                Store.settings.set(false, forKey: "selection.hint.shown")
                commands.maybeHint(on: tab)
                done()
            case "patience":
                // How long an answer may take, in seconds: short, for the
                // case of an agent that never answers.
                SelectionCommands.patience = request["seconds"] as? Int ?? 60
                done()
            case "again-with":
                // The model menu's pick, as ⇧⌘R's list would make it.
                commands.again(with: ModelChoice(cli: request["cli"] as? String, model: request["model"] as? String))
                done()
            case "html":
                // A page of the case's own: #p page text, #t a field.
                let html = request["html"] as? String ?? ""
                web.run("document.body.innerHTML = \(String(data: try! JSONSerialization.data(withJSONObject: [html]), encoding: .utf8)!)[0]; 1")
                done()
            case "select":
                // Part of #p or all of #t, by characters, as a hand would.
                let what = request["in"] as? String ?? "p"
                let from = request["from"] as? Int ?? 0
                let length = request["length"] as? Int ?? -1
                let js = what == "t"
                    ? "(function(){const t=document.getElementById('t');t.focus();t.setSelectionRange(\(from), \(length) < 0 ? t.value.length : \(from + max(0, length)));return 1})()"
                    : "(function(){const p=document.getElementById('p');const n=p.firstChild;const r=document.createRange();r.setStart(n,\(from));r.setEnd(n,\(length) < 0 ? n.length : Math.min(n.length, \(from + max(0, length))));const s=getSelection();s.removeAllRanges();s.addRange(r);return 1})()"
                web.run(js)
                done()
            case "value":
                // What #t holds now, after a Replace.
                web.run("document.getElementById('t') ? document.getElementById('t').value : null") { result in
                    answer(["value": (try? result.get()) as? String ?? NSNull()])
                }
            case "js":
                // A look into the world the commands' scripts run in.
                web.run(request["js"] as? String ?? "null", in: .client) { result in
                    answer(["result": (try? result.get()).map { "\($0)" } ?? "error: \(result)"])
                }
            default:
                done()
            }

        case "tidy":
            // Every tab of yours but the one on screen made as old as asked
            // thirteen hours unless said, and the tidy-up let loose on
            // them. A --test run only: it closes tabs of yours.
            guard Store.testing else { answer(["error": "tidy only works on a --test run"]); return }
            let before = browser.tabs.count
            browser.ageForTidy(hours: request["hours"] as? Double ?? 13)
            browser.tidy()
            answer(["before": before, "after": browser.tabs.count, "tabs": browser.tabs.map(describe)])

        case "live":
            // Live folders (LiveFolders.swift), driven and read: "make" one
            // (host: github.com, or a stand-in's "http://127.0.0.1:PORT"),
            // "items" as if its site listed them, [{n, title, words, repo}]
            // (a Linear folder's: [{id, list, words, quote, person}]),
            // "read" its site now, "hide" a tab (id), "stop"; then the
            // folder: its state and each tab's key, words and whether it
            // is out from under the folder. A --test run only.
            guard Store.testing else { answer(["error": "live only works on a --test run"]); return }
            if let enabled = request["enabled"] as? Bool { browser.prefs.usesLiveFolders = enabled }
            var nest = browser.nests.first { $0.live != nil }
            switch request["action"] as? String ?? "state" {
            case "follow": nest = LiveFolders.shared.followRepo(request["repo"] as? String ?? "", in: browser)
            case "make": nest = LiveFolders.shared.make(request["source"] as? String ?? "github.pulls", in: browser, host: request["host"] as? String)
            case "items":
                guard let nest else { answer(["error": "no live folder"]); return }
                let host = nest.live.map { LiveGitHub.base($0.host) } ?? "https://github.com"
                let source = nest.live.flatMap { LiveSource.of($0.source) }
                // A Linear folder's: [{id: "YAB-1", list, words, quote, person}].
                let linear = (request["items"] as? [[String: Any]] ?? []).compactMap { item -> LiveItem? in
                    guard source?.id == "linear", let id = item["id"] as? String,
                          let url = URL(string: "https://linear.app/acme/issue/\(id)/item") else { return nil }
                    return LiveItem(key: "linear/" + id, url: url, title: "\(id) \(item["title"] as? String ?? "Issue")", group: "YAB",
                                    words: (item["words"] as? String).flatMap(LiveWords.init(rawValue:)), updated: Date(),
                                    list: item["list"] as? String ?? "assigned", quote: item["quote"] as? String, person: item["person"] as? String)
                }
                if source?.id == "linear" {
                    LiveFolders.shared.apply(linear, to: nest, source: source, in: browser)
                    break
                }
                let items = (request["items"] as? [[String: Any]] ?? []).compactMap { item -> LiveItem? in
                    let repo = item["repo"] as? String ?? "acme/yab"
                    guard let n = item["n"] as? Int, let url = URL(string: "\(host)/\(repo)/pull/\(n)"), let key = LiveFolder.key(url) else { return nil }
                    return LiveItem(key: key, url: url, title: item["title"] as? String ?? "Pull request \(n)", group: repo,
                                    words: (item["words"] as? String).flatMap(LiveWords.init(rawValue:)), updated: nil)
                }
                LiveFolders.shared.apply(items, to: nest, in: browser)
            case "read": if let nest { LiveFolders.shared.read(nest, in: browser) }
            case "hide":
                if let tab = find(request, in: browser) { LiveFolders.shared.hide(tab, in: browser) }
            case "stop": if let nest { LiveFolders.shared.stop(nest, in: browser) }
            // "pretend": the folder read "age" minutes ago, "signed_out",
            // or "reading" now, for the preview's foot.
            case "pretend":
                if let nest {
                    LiveFolders.shared.pretend(nest, age: request["age"] as? Double ?? 0,
                                               signedOut: request["signed_out"] as? Bool ?? false, reading: request["reading"] as? Bool ?? false)
                }
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.3)) {
                let found = browser.nests.first { $0.live != nil } ?? nest
                if request["settings"] as? Bool == true, let found, found.live != nil {
                    SettingsWindow.shared.showLiveFolder(found, for: browser)
                }
                let state = found.flatMap { LiveFolders.shared.states[$0.id] }
                answer([
                    "enabled": browser.prefs.usesLiveFolders,
                    "reading": found.map { LiveFolders.shared.reading.contains($0.id) } ?? false,
                    "catalog": LiveFolderSummary.all(in: browser).map { entry -> [String: Any] in
                        ["name": entry.name, "space": browser.spaces.first { $0.id == entry.space }?.name ?? "", "count": entry.count]
                    },
                    "folder": found?.name ?? "", "open": found?.open ?? false, "live": found?.live?.host ?? "",
                    "read": state?.read != nil, "signed_out": state?.signedOut ?? false, "failures": state?.failures ?? 0,
                    "waiting": found.map { LiveFolders.waiting($0, in: browser) } ?? 0,
                    "tabs": browser.tabs.filter { $0.nest === found && found != nil }.map { tab -> [String: Any] in
                        ["id": Bench.short(tab), "title": tab.title, "key": tab.live?.key ?? "", "words": tab.live?.words?.rawValue ?? "",
                         "out": Folders.shared.place(of: tab)?.shown ?? true, "asleep": tab.asleep, "brought": tab.live != nil,
                         "news": tab.live?.news == true]
                    },
                ])
            }
            return

        case "numbers":
            // ⌘ held, as far as the column and the strip can tell: each tab's
            // number shown ("on": false lets go), and what each tab wears.
            if let on = request["on"] as? Bool { KeyNumbers.shared.hold(on) }
            answer(["shown": KeyNumbers.shared.shown,
                    "tabs": browser.tabs.map { tab -> [String: Any] in
                        ["id": tab.id.uuidString, "pinned": tab.pin != nil, "kept": tab.kept,
                         "number": KeyNumbers.number(of: tab, in: browser) ?? 0]
                    }])
            return
        case "kept":
            // The tabs kept above the line (Kept.swift), driven as their
            // menus would, and the column's rows as the drag counts them:
            // each tab's slot, each folder's and the line's. A --test run
            // only: it keeps, files and closes tabs of yours.
            guard Store.testing else { answer(["error": "kept only works on a --test run"]); return }
            let refs = (request["ids"] as? [String] ?? []).map { $0.lowercased() }
            let group = browser.tabs.filter { tab in refs.contains { tab.id.uuidString.lowercased().hasPrefix($0) } }
            let nest = (request["folder"] as? String).flatMap { name in browser.nests.first { $0.name == name } }
            switch request["action"] as? String ?? "state" {
            case "keep": browser.keepTabs(group, in: nest)
            case "release": browser.releaseTabs(group)
            // Pinned, and a pin's or a kept tab's home (PinnedHome.swift):
            // Back to, and Replace … Address with Current, as their menus do.
            case "pin": browser.pin(group)
            case "home": group.forEach { browser.goHome($0) }
            case "make-home": group.forEach { browser.makeHome($0) }
            // Edit…: the field up with the home in it; "typed" put in it and
            // Return pressed, as a person would (a refusal leaves it up).
            case "edit-home":
                // As the menu's Edit… does: the tab in front, then its field.
                if let tab = group.first {
                    browser.select(tab)
                    browser.beginHomeEdit(tab)
                }
            case "type-home":
                if let typed = request["typed"] as? String { browser.tabDraft = typed }
                browser.commitTabEdit()
            case "cancel-home": browser.cancelTabEdit()
            case "folder":
                browser.newFolder(with: group, today: request["today"] as? Bool ?? false)
                if let name = request["name"] as? String, let made = group.first?.nest {
                    made.name = name
                    browser.folderBook.naming = nil
                }
            case "file": if let nest { browser.file(group, in: nest) }
            case "unfile": group.forEach { browser.unfile($0) }
            case "ungroup": if let nest { browser.ungroup(nest) }
            case "discard": browser.discard(group, rekept: true)
            case "remove":
                // Remove Folder and N Tabs, as its menu does: the empty folders
                // in it, then every tab under it.
                if let nest {
                    browser.folderBook.removeEmpty(nest)
                    browser.discard(browser.tabs(in: nest))
                }
            // Remove Folder and N Tabs from the folder's own menu, which ⌘Z,
            // ⌘⇧T and Recently Closed bring back kept, in the folder.
            case "remove-folder": if let nest { browser.removeFolder(nest, with: browser.tabs(in: nest)) }
            case "toggle": if let nest { browser.folderBook.toggle(nest.key, deep: request["deep"] as? Bool ?? false) }
            case "open-all": if let nest { browser.folderBook.openAll(nest, request["open"] as? Bool ?? true) }
            case "nest":
                // A folder into another of yours ("into", by name), or out
                // one step without one.
                if let nest {
                    let into = (request["into"] as? String).flatMap { name in browser.nests.first { $0.name == name } }
                    browser.file(nest, in: into ?? nest.parent?.parent)
                }
            case "tospace":
                // Move to Space on a folder ("space": the other's name), as
                // by hand: a step for ⌘Z ("undo" below). "ask": false skips
                // the sign-ins card.
                if let nest, let name = request["space"] as? String,
                   let space = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                    browser.moveFolder(nest, to: space.id, ask: request["ask"] as? Bool ?? true, hand: true)
                }
            case "undo":
                // ⌘Z in the window.
                _ = browser.undoWindow()
            case "inside":
                // New Folder Inside, named at once.
                if let nest {
                    browser.newFolder(inside: nest)
                    if let name = request["name"] as? String, let made = browser.folderBook.empties.last {
                        made.name = name
                        browser.folderBook.naming = nil
                        browser.folderBook.emptyChanged(made)
                    }
                }
            case "name-folder": if let nest { LinkFolders.name(nest, in: browser) }
            case "tidy": browser.tidyNow()
            // A click on the space's name in the column (SpaceName).
            case "fold": browser.folderBook.toggleSpace()
            case "empty":
                // New Folder from the line's menu or ⌘T, named at once.
                browser.newEmptyFolder()
                if let name = request["name"] as? String, let made = browser.folderBook.empties.last {
                    made.name = name
                    browser.folderBook.naming = nil
                    browser.folderBook.emptyChanged(made)
                }
            case "remove-empty": if let nest { browser.folderBook.removeEmpty(nest) }
            case "pick":
                // The first picked, then a ⇧-click's run to the last.
                if let first = group.first, let last = group.last {
                    browser.select(first)
                    browser.extend(to: last)
                }
            case "close": browser.close(group)
            // The first of them to place "at" in the row, as a drag would
            // put it, or to the space named "space", as Move to Space.
            case "to-place": if let tab = group.first, let at = request["at"] as? Int { browser.move(tab, to: at) }
            case "tab-tospace":
                if let name = request["space"] as? String,
                   let space = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                    _ = browser.moveTabs(group, to: space.id, say: false)
                }
            // The first of them to window "to" (from 1), as Move Tab Here
            // or a drag onto that window moves it (BrowserWindows.move).
            case "to-window":
                let windows = BrowserWindows.shared.openWindows()
                let destination: Browser?
                if let number = request["toWindowNumber"] as? Int {
                    destination = NSApp.windows.first(where: { $0.windowNumber == number })
                        .flatMap { BrowserWindows.shared.browser(for: $0) }
                    guard destination != nil else { answer(["error": "no destination browser window with that number"]); return }
                } else {
                    destination = (request["to"] as? Int).flatMap { windows.indices.contains($0 - 1) ? windows[$0 - 1].browser : nil }
                }
                if let tab = group.first, let destination {
                    _ = BrowserWindows.shared.move(tab, from: browser, to: destination, announce: false)
                }
            case "aim":
                // Where the first of `ids` would land with the hand `want`
                // slots down, and the rows as they would then be drawn.
                guard let held = group.first else { answer(["error": "aim needs an id"]); return }
                let loose = browser.tabs.filter { $0.pin == nil }
                // "wants": the hand's way down the list, each landing handed
                // the one before it, as a drag does.
                if let wants = request["wants"] as? [Double] {
                    var current: Folders.Landing?
                    var seen: [[String: Any]] = []
                    for want in wants {
                        let next = browser.folderBook.landing(held, want: want, among: loose, current: current)
                        current = next
                        seen.append(["want": want, "index": next.index, "slot": next.slot, "kept": next.kept, "into": next.into != nil, "nest": next.nest != nil])
                    }
                    answer(["path": seen])
                    return
                }
                let landing = browser.folderBook.landing(held, want: request["want"] as? Double ?? 0, deep: request["deep"] as? Int, among: loose)
                var order = loose.filter { $0.id != held.id }
                order.insert(held, at: min(landing.index, order.count))
                let then = browser.folderBook.slots(order, out: landing.out ? held.id : nil, held: held.id, as: landing.guise)
                let now = browser.folderBook.slots(loose)
                answer(["index": landing.index, "slot": landing.slot, "kept": landing.kept, "nest": landing.nest?.uuidString ?? "",
                        "into": landing.into?.uuidString ?? "", "now": now.folders, "then": then.folders,
                        "tabs": order.map { ["id": Bench.short($0), "now": now.tabs[$0.id] ?? -1, "then": then.tabs[$0.id] ?? -1] as [String: Any] }])
                return
            default: break
            }
            DispatchQueue.main.async {
                let loose = browser.tabs.filter { $0.pin == nil }
                let slots = browser.folderBook.slots(loose, joined: !browser.pairs.isEmpty)
                answer([
                    "tabs": browser.tabs.map(self.describe),
                    "slots": loose.map { tab -> [String: Any] in
                        ["id": Bench.short(tab), "slot": slots.tabs[tab.id] ?? -1, "shown": browser.folderBook.place(of: tab)?.shown ?? true,
                         "depth": browser.folderBook.place(of: tab)?.depth ?? 0,
                         "heads": (browser.folderBook.place(of: tab)?.heads ?? []).compactMap { key in browser.nests.first { $0.key == key }?.name }]
                    },
                    "rows": slots.folders.mapValues { $0 },
                    "lined": browser.folderBook.lined,
                    "line_reported": browser.keptLine != nil,
                    "dust_ready": Dust.shared.ready,
                    "dust_played": Dust.shared.played,
                    "naming": browser.folderBook.naming.flatMap { id in browser.nests.first { $0.id == id }?.name } ?? "",
                    "empties": browser.folderBook.empties.map(\.name),
                    "picked": browser.chosen.map(Bench.short),
                    // Edit…'s field (PinnedHome.swift): which tab, and what is in it.
                    "editing_home": browser.editingHome ? browser.editingTab.map { String($0.uuidString.prefix(8)).lowercased() } ?? "" : "",
                    "draft": browser.tabDraft,
                    // A name being typed (Browser.editingTab), a pin's
                    // letter, and who has the keys (evals/tab-rename/long.py).
                    "editing_tab": browser.editingTab.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "editing_pin": browser.editingPin.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                    "responder": (NSApp.keyWindow?.firstResponder).map { "\(type(of: $0))" } ?? "none",
                    "field_arrived_s": TabAddressField.arrived ?? -1,
                    "field_keyed_s": TabAddressField.keyed ?? -1,
                    "refusals": browser.refusals,
                    "extra": browser.folderBook.extra,
                    // The space folded under its name, and where the name
                    // is on the screen, top-left, for a hand to go to.
                    "shut": browser.folderBook.shut,
                    "away": browser.folderBook.away.count,
                    "keeps": browser.folderBook.keeps,
                    "head": self.spaceHead(browser),
                    "folders": browser.nests.map { nest in ["name": nest.name, "open": nest.open, "tabs": browser.tabs.filter { $0.nest === nest }.count, "key": nest.key,
                                                            "parent": nest.parent?.name ?? "", "depth": nest.depth, "today": nest.today] as [String: Any] },
                ])
            }

        case "untidy":
            // ⌘⇧T, without a key.
            guard Store.testing else { answer(["error": "untidy only works on a --test run"]); return }
            browser.reopen()
            answer(["tabs": browser.tabs.map(describe)])

        case "eyedropper":
            // The page's EyeDropper (EyeDropper.swift): `standIn` keeps the
            // Mac's sampler from showing, `pick` answers it with a color
            // ("#rrggbb", or "" for Escape). Test runs only.
            guard Store.testing else { answer(["error": "eyedropper only works on a --test run"]); return }
            if let on = request["standIn"] as? Bool { EyeDropperSampler.standIn = on }
            var reply: [String: Any] = ["open": EyeDropperSampler.isOpen, "standIn": EyeDropperSampler.standIn]
            if let hex = request["pick"] as? String { reply["answered"] = EyeDropperSampler.answer(hex.isEmpty ? nil : hex) }
            answer(reply)

        case "pointer":
            // The mouse on the page in front, as a person's would be: moved,
            // dragged, right-clicked (BenchPointer).
            // A Chromium page named by `id`, a Small Window's too: a press
            // and let-go through its window, as AppKit hands a person's, so
            // the page feels it (RelayGuard.felt) as it would yours.
            if request["op"] as? String == "click", request["id"] != nil, let target = find(request, in: browser),
               let chromium = target.builtPage as? ChromiumPage {
                answer(BenchPointer.click(chromium, at: request["at"] as? [Double])); return
            }
            guard let front = browser.active, let pointed = front.builtPage else { answer(["error": "no page"]); return }
            // ⌘F's page: a peek's while one is up (Browser.findPage).
            let tab = request["find"] != nil || request["findStep"] != nil || request["findClose"] != nil || request["found"] != nil
                ? browser.findPage ?? front : front
            let page = tab.builtPage ?? pointed
            // ⌘F with these words typed, and where it stands.
            if let needle = request["find"] as? String {
                browser.openFind()
                tab.finder.needle = needle
            }
            // ⌘G / ⌘⇧G, and Escape on the bar.
            if let forward = request["findStep"] as? Bool { browser.look(forward: forward) }
            if request["findClose"] as? Bool == true { tab === front ? browser.closeFind() : tab.finder.close() }
            if request["found"] as? Bool == true {
                answer(["index": tab.finder.index, "total": tab.finder.total, "missed": tab.finder.missed,
                        "asked": tab.finder.asked, "shown": tab.finder.shown, "capped": tab.finder.capped,
                        "webKit": tab.finder.webKitFinds, "pdf": page.webKit?.webKitShowsPDF ?? false])
                return
            }
            if request["findClose"] != nil || request["findStep"] != nil { answer([:]); return }
            guard let web = page.webKit else { answer(["error": "Use Chromium native input for pointer actions"]); return }
            answer(BenchPointer.run(request, on: web))

        case "text":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // Asleep, or emptied, it holds no page: built now, it read as
            // empty, and the agent answered about nothing. It loads first,
            // as snapshot's does (handleSnapshot).
            if request["woken"] == nil, tab.wake() || tab.hollow {
                if tab.hollow { tab.reload() }
                let limit = Date().addingTimeInterval(12)
                func ready() {
                    if (!tab.loading && !tab.hollow) || Date() > limit { self.handleBound(request.merging(["woken": true]) { $1 }, answer, in: browser) }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ready() } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ready() }
                return
            }
            house(tab)
            // What a person can read: words a pixel high or the color of
            // the page are left out and counted (AgentPage.readable).
            Task { @MainActor in
                do {
                    if try await AgentPDF.isDocument(tab.page) { AgentPDF.read(tab, snapshot: false, done: answer); return }
                } catch { answer(["error": error.localizedDescription]); return }
                AgentPage.run(tab, AgentPage.readable) { result in
                    guard case .success(let value) = result, let got = value as? [String: Any] else {
                        if case .failure(let error) = result { answer(["error": error.localizedDescription]) } else { answer(["error": "no answer"]) }
                        return
                    }
                    var text = got["text"] as? String ?? ""
                    var cut = false
                    if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                    answer(["text": text, "truncated": cut, "hidden": got["hidden"] as? Int ?? 0, "url": tab.address?.absoluteString ?? "", "title": tab.title])
                }

            }

        case "eval":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
            // When the hand acted, for what the stage did after (stagetrace).
            StageView.mark("input", ["what": "eval"])
            OpenTrace.mark("eval")
            house(tab)
            // An agent's script, whichever way it comes: in the agent's
            // guarded world, never yab's own or the page's. Only a call with
            // no agent behind it, the bench's or an eval harness's playing
            // the person, runs anywhere else.
            let agent = request["session"] != nil
            if agent, request["world"] != nil {
                answer(["error": "an agent's script runs in its own world only"])
                return
            }
            // yab's own world is where its page scripts live (see Web.world);
            // dark pages' engine has a world of its own (DarkPages.world).
            if request["world"] as? String == "yab" || request["world"] as? String == "dark" {
                let world: PageWorld = request["world"] as? String == "dark" ? .named("yab-dark") : .yab
                tab.page.run(js, in: world) { result in
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let value): answer(["value": Bench.plain(value)])
                        case .failure(let error): answer(["error": error.localizedDescription])
                        }
                    }
                }
                return
            }
            // An agent's script runs in the agent's world, and only in its tabs.
            if request["isolated"] as? Bool == true || agent {
                agentCommand("agent-eval", request, browser: browser, answer)
                return
            }
            tab.page.run(js) { result in
                switch result {
                case .success(let value): answer(["value": Bench.plain(value)])
                case .failure(let error): answer(["error": error.localizedDescription])
                }
            }

        case "forms":
            formsCommand(request, browser: browser, answer)

        case "picks":
            picksCommand(request, browser: browser, answer)

        case "threads":
            threadsCommand(request, browser: browser, answer)

        case "pdf":
            pdfCommand(request, browser: browser, answer)

        case "wallet":
            // Cards and addresses, test runs only: "prove" answers Touch ID
            // itself (yes, no, or ask for a real one), "seed" keeps a test
            // card and address ("csc" gives the card a security code,
            // "amex" adds a second card), "clear" forgets every one, "pick" takes a
            // row of the list under the box, "keep", "park" and "unpark"
            // answer the offer on the tab in front. The answer says what
            // is kept, what the list shows and what the offer asks.
            guard Store.testing else { answer(["error": "wallet only works on a --test run"]); return }
            if let prove = request["prove"] as? String {
                Wallet.benchAnswer = prove == "yes" ? .yes : prove == "no" ? .no : nil
                Wallet.benchDelay = request["proveAfter"] as? Double ?? 0
            }
            // Where Safari's export is watched for, in place of Downloads.
            if let folder = request["downloads"] as? String { SafariImport.testFolder = URL(fileURLWithPath: folder) }
            // A host whose frames count as a payment company's, a local
            // stand-in for Stripe's; "" for none.
            if let host = request["processor"] as? String { WalletWatch.testProcessors = host.isEmpty ? [] : [host.lowercased()] }
            if request["clear"] as? Bool == true {
                Wallet.cards().forEach { Wallet.forget(card: $0.id) }
                Wallet.addresses().forEach { Wallet.forget(address: $0.id) }
            }
            if request["seed"] as? Bool == true {
                var visa = SavedCard(id: UUID().uuidString, number: "4242424242424242", last4: "4242", brand: "Visa", name: "Jane Appleseed",
                                     month: 8, year: 2030, used: Date(), saved: nil)
                // With a security code only when asked: the agent evals hand
                // the code to the person.
                visa.csc = request["csc"] as? String ?? ""
                visa.usedOn = "northwind.shop"
                Wallet.save(visa)
                if request["amex"] as? Bool == true {
                    Wallet.save(SavedCard(id: UUID().uuidString, number: "378282246310005", last4: "0005", brand: "American Express", name: "Jane Appleseed",
                                          month: 3, year: 2029, used: nil, saved: Date()))
                }
                var home = StreetAddress(id: UUID().uuidString)
                home.name = "Jane Appleseed"
                home.street = "221 Mission St\nApt 4"
                home.city = "San Francisco"
                home.region = "CA"
                home.postal = "94105"
                home.country = "United States"
                home.phone = "+1 415 555 0100"
                home.email = "jane@example.com"
                Wallet.save(home)
            }
            // Over everything and on every space, so its pages keep drawing
            // while the test films them (a covered window's don't).
            if request["float"] as? Bool == true, let window = Links.window {
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.level = .floating
                window.orderFrontRegardless()
            }
            if let pick = request["pick"] as? Int { browser.chooseWallet(pick) }
            // A Chromium Web Data file brought in as a browser's would be,
            // its numbers wrapped with the key `passphrase` stretches to.
            if let file = request["webData"] as? String {
                let passphrase = request["passphrase"] as? String ?? "peanuts"
                do {
                    let found = try Chromium.wallet(file: URL(fileURLWithPath: file), key: Chromium.stretch(passphrase), from: request["from"] as? String ?? "Chrome")
                    let kept = Wallet.take(cards: found.cards, addresses: found.addresses)
                    answer(["read": ["cards": found.cards.count, "addresses": found.addresses.count],
                            "kept": ["cards": kept.cards, "addresses": kept.addresses],
                            "cards": Wallet.cards().map { "\($0.title) \($0.expiry) \($0.name) \($0.from) \($0.source) \($0.nickname)" },
                            "codes": Dictionary(Wallet.cards().map { ($0.last4, Wallet.securityCode(of: $0.id) ?? "") }) { a, _ in a },
                            "addresses": Wallet.addresses().map { "\($0.title) \($0.place) \($0.source ?? "")" }])
                } catch {
                    answer(["error": "\(error)"])
                }
                return
            }
            // More cards to look at: one running out next month, an Amex.
            if request["seedMore"] as? Bool == true {
                let now = Calendar.current.dateComponents([.year, .month], from: Date())
                let next = (now.month ?? 1) % 12 + 1
                let year = (now.year ?? 2026) + ((now.month ?? 1) == 12 ? 1 : 0)
                Wallet.save(SavedCard(id: UUID().uuidString, number: "5178051234567897", last4: "7897", brand: "Mastercard", name: "Jane Appleseed",
                                      month: next, year: year, used: Date().addingTimeInterval(-86400 * 40), saved: nil, nickname: "Groceries", usedOn: "instacart.com"))
                Wallet.save(SavedCard(id: UUID().uuidString, number: "371449635398431", last4: "8431", brand: "American Express", name: "Jane Appleseed",
                                      month: 4, year: 2029, used: nil, saved: nil, source: "Chrome"))
            }
            // A card or an address put into the page as if typed ("put":
            // {"card": {...}} or {"address": {...}}), for the saving to see.
            if let put = request["put"] as? [String: Any], let tab = browser.active {
                let what: WalletField.Group = put["card"] != nil ? .card : .address
                tab.walletFill(put["card"] as? [String: Any] ?? put["address"] as? [String: Any] ?? [:], what: what,
                               origin: Tab.originOf(tab.address)) { filled in answer(["filled": filled]) }
                return
            }
            // What the frames that said they hold a card's boxes have in
            // them now ("peek"), or the caret put in one of those frames'
            // first box ("focus": its index).
            if let tab = browser.active, let web = tab.builtPage, request["peek"] as? Bool == true || request["focus"] != nil {
                let frames = tab.wallet.frames
                if let at = request["focus"] as? Int, frames.indices.contains(at) {
                    web.call("const b = document.querySelector('input'); if (b) b.focus(); return !!b",
                                            arguments: [:], in: .yab, frame: frames[at]) { _ in }
                    answer(["ok": true])
                    return
                }
                var seen: [String] = []
                var left = frames.count
                guard left > 0 else { answer(["frames": []]); return }
                for frame in frames {
                    web.call("return [...document.querySelectorAll('input,select')].map(i => (i.getAttribute('autocomplete') || i.name) + '=' + i.value).join(' ')",
                                            arguments: [:], in: .yab, frame: frame) { result in
                        MainActor.assumeIsolated {
                            seen.append((try? result.get()) as? String ?? "gone")
                            left -= 1
                            if left == 0 { answer(["frames": seen]) }
                        }
                    }
                }
                return
            }
            if let tab = browser.active {
                if request["keep"] as? Bool == true { browser.keepPay(tab) }
                if request["park"] as? Bool == true { browser.parkPay(tab) }
                if request["unpark"] as? Bool == true { browser.unparkPay(tab) }
            }
            var out: [String: Any] = [
                "cards": Wallet.cards().map { "\($0.title) \($0.expiry) \($0.name)" },
                "addresses": Wallet.addresses().map(\.title),
                "frames": browser.active?.wallet.frames.count ?? 0,
                // Whether anything drawn now reaches a screen: a covered or
                // locked window's pages stop drawing, and a fill's tint with them.
                "visible": Links.window?.occlusionState.contains(.visible) ?? false,
                "locked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false,
                "seen": browser.active.map { "\($0.wallet.seen.number.suffix(4)) \($0.wallet.seen.month)/\($0.wallet.seen.year) \($0.wallet.seen.name)" } ?? "",
                "sent": browser.active?.wallet.sent.map { "\($0.card?.number.suffix(4) ?? "-") \($0.address?.title ?? "-")" } ?? "",
            ]
            if let list = browser.walletList {
                out["list"] = ["group": list.group.rawValue, "count": list.count, "x": list.spot.minX, "y": list.spot.maxY,
                               "dark": list.dark.map { $0 ? "dark" : "light" } ?? "", "phones": list.phones.map(\.number)]
            }
            if let offer = browser.active?.payOffer {
                out["offer"] = ["card": offer.card?.title ?? "", "was": offer.was ?? "", "address": offer.address?.title ?? "",
                                "parked": offer.parked, "refused": offer.refused]
            }
            answer(out)

        case "proof":
            // Settings' "Ask before filling", test runs only: "prove" turns
            // it (forgetting the last yes), "forget" forgets the yes,
            // "cancel" takes a question that is up down unanswered. Says how
            // many questions Yab has put this launch and whether one is up.
            guard Store.testing else { answer(["error": "proof only works on a --test run"]); return }
            if let prove = request["prove"] as? Bool { browser.prefs.provesToFill = prove }
            if request["forget"] as? Bool == true { Vault.forgetProof(cancelling: false) }
            let up = Vault.asking != nil
            if request["cancel"] as? Bool == true, up { Vault.forgetProof(cancelling: true) }
            answer(["asked": Vault.questions, "up": up, "proves": browser.prefs.provesToFill])

        case "fill":
            // A kept password put into the page as a pick from the list
            // would, test runs only. "tricky" fills a run of passwords that
            // would break a script they were written into and reads each
            // back; "prove" sets Settings' Touch ID switch first, and
            // "cancel" takes the question down after that many seconds.
            guard Store.testing else { answer(["error": "fill only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if let prove = request["prove"] as? Bool {
                browser.prefs.provesToFill = prove
                Vault.forgetProof(cancelling: false)
            }
            let read = "JSON.stringify(Array.from(document.querySelectorAll('input')).map(i => i.value))"
            if request["tricky"] as? Bool == true {
                fillTricky(tab, Bench.trickyPasswords, read: read, results: [], answer)
                return
            }
            let user = request["user"] as? String ?? "someone@example.com"
            let password = request["password"] as? String ?? "hunter2"
            if let cancel = request["cancel"] as? Double {
                DispatchQueue.main.asyncAfter(deadline: .now() + cancel) {
                    Bench.sawQuestion = Vault.asking != nil
                    Vault.forgetProof(cancelling: true)
                }
            }
            // "close" closes the tab that long in, while the question is up,
            // as an agent's sign-in holding it would see: the answer says
            // whether a page was built for it again.
            if let close = request["close"] as? Double {
                DispatchQueue.main.asyncAfter(deadline: .now() + close) { [weak browser] in browser?.close(tab) }
            }
            Bench.sawQuestion = false
            let started = Date()
            tab.fill(user: user, password: password) { filled in
                let asked = Bench.sawQuestion || Vault.asking != nil
                guard let web = tab.builtPage else {
                    answer(["filled": "\(filled)", "asked": asked, "ms": Int(Date().timeIntervalSince(started) * 1000), "rebuilt": false])
                    return
                }
                web.run(read) { result in
                    let value = try? result.get()
                    MainActor.assumeIsolated {
                        answer(["filled": "\(filled)", "asked": asked, "ms": Int(Date().timeIntervalSince(started) * 1000), "values": value as? String ?? ""])
                    }
                }
            }

        case "click", "type", "submit":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let selector = request["selector"] as? String else {
                answer(["error": "\(verb) needs a selector"])
                return
            }
            house(tab)
            let text = request["text"] as? String ?? ""
            tab.page.run(Bench.act(verb, selector: selector, text: text)) { result in
                switch result {
                case .success(let value):
                    let said = (value as? String) ?? "?"
                    answer(said == "ok" ? ["ok": true] : ["error": said])
                case .failure(let error): answer(["error": error.localizedDescription])
                }
            }

        case "grab":
            // ⇧⌘2, driven and timed (Capture.swift): start, hover x y (the
            // page's CSS pixels, up = how many boxes out), take mode
            // (box, visible, whole, area x y w h in window points), edit,
            // back, save, close, style (backdrop, shape, hue, private),
            // paste (reads the clipboard's PNG as an app would), state.
            let capture = browser.capture
            let settle = request["wait"] as? Double ?? 0.6
            switch request["act"] as? String ?? "state" {
            case "start": capture.start()
            case "image":
                // Capture Image, without the menu.
                if let tab = browser.active, let url = (request["src"] as? String).flatMap(URL.init(string:)) { capture.image(url, on: tab) }
            case "hover":
                let point = CGPoint(x: request["x"] as? Double ?? 200, y: request["y"] as? Double ?? 200)
                capture.benchHover(css: point) {
                    for _ in 0..<(request["up"] as? Int ?? 0) { capture.step(out: true) }
                    answer(capture.report)
                }
                return
            case "take":
                switch request["mode"] as? String ?? "box" {
                case "visible": capture.take(.visible)
                case "whole": capture.take(.whole)
                case "area":
                    let r = CGRect(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0,
                                   width: request["w"] as? Double ?? 200, height: request["h"] as? Double ?? 120)
                    capture.take(.area(r))
                default: capture.take(.box)
                }
                if request["hold"] as? Bool == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { capture.hold() }
                }
            case "edit": capture.edit()
            case "back": capture.back()
            case "save": capture.save()
            case "close": capture.close()
            case "hold": capture.hold()
            case "style":
                capture.benchStyle { style in
                    if let b = (request["backdrop"] as? String).flatMap(CaptureStyle.Backdrop.init) { style.backdrop = b }
                    if let s = (request["shape"] as? String).flatMap(CaptureStyle.Shape.init) { style.shape = s }
                    if let h = request["hue"] as? Double { style.hue = h }
                    if let p = request["private"] as? Bool { style.hidePrivate = p }
                }
            case "paste":
                // What a paste finds, and how long the finding takes.
                DispatchQueue.global(qos: .userInitiated).async {
                    let t0 = CACurrentMediaTime()
                    let data = NSPasteboard.general.data(forType: .png)
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    let image = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                    let props = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
                    let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                    DispatchQueue.main.async {
                        answer(["paste_ms": (ms * 10).rounded() / 10, "bytes": data?.count ?? 0,
                                "width": image?.width ?? 0, "height": image?.height ?? 0,
                                "dpi": props?[kCGImagePropertyDPIWidth] ?? 0,
                                "from": png?[kCGImagePropertyPNGDescription] ?? ""])
                    }
                }
                return
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { answer(capture.report) }

        case "shot":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if request["session"] != nil && tab.wallet.agentScreenshotBlocked {
                answer(["error": "this tab has held card details; a screenshot could reveal them. Read it with snapshot instead"])
                return
            }
            let capture = { [self] in
                house(tab)
                let path = (request["path"] as? String)
                    ?? NSTemporaryDirectory() + "yab-bench-\(Bench.short(tab)).png"
                let width = request["width"] as? Double
                if request["inline"] as? Bool == true {
                    picture(tab.page, width: width, png: request["png"] as? Bool == true, answer)
                    return
                }
                shoot(tab, to: URL(fileURLWithPath: path), width: width, answer)
            }
            // An agent's picture of a Chromium page is read like its text:
            // not of a page holding protected material.
            guard request["session"] != nil, tab.engineKind == .chromium else { capture(); return }
            house(tab)
            Task { @MainActor in
                do {
                    let width = request["width"] as? Double
                    let image = try await AgentScreenshot.capture(tab, width: width)
                    if request["inline"] as? Bool == true {
                        picture(image, error: nil, width: width, png: request["png"] as? Bool == true, answer)
                    } else {
                        let path = (request["path"] as? String)
                            ?? NSTemporaryDirectory() + "yab-bench-\(Bench.short(tab)).png"
                        saveShot(image, error: nil, to: URL(fileURLWithPath: path), answer)
                    }
                } catch { answer(["error": error.localizedDescription]) }
            }

        case "devshot":
            guard Store.testing else { answer(["error": "devshot only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "devshot needs a path"]); return }
            browser.withInspector { [weak self] inspector in
                guard let self, let web = DevTools.page(inspector) else { answer(["error": "no inspector page"]); return }
                self.shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
            }

        case "dev-protocol":
            guard Store.testing else { answer(["error": "dev-protocol only works on a --test run"]); return }
            guard browser.toolsFront != nil,
                  let method = request["method"] as? String,
                  ["Runtime.evaluate", "Page.getResourceTree", "Page.captureScreenshot",
                   "Input.dispatchMouseEvent", "Input.dispatchKeyEvent", "Network.enable",
                   "Target.getTargets"].contains(method)
            else { answer(["error": "unsupported probe method or no page in front"]); return }
            let params = request["params"] as? [String: Any] ?? [:]
            browser.withInspector { _ in
                var error: String?
                browser.wire(method, params, failed: { error = $0 }) { value in
                    answer(["method": method, "value": Bench.plain(value), "error": error ?? ""])
                }
            }

        case "popovers":
            // The popovers up, Change Icon's among them, and the window they
            // hang from, on the screen with its top left at 0, 0, for a
            // capture of the screen there.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            func place(_ window: NSWindow) -> [String: Any] {
                ["number": window.windowNumber, "x": window.frame.minX, "y": top - window.frame.maxY,
                 "w": window.frame.width, "h": window.frame.height]
            }
            let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            let imagePanels = NSApp.windows.compactMap { $0 as? NSOpenPanel }.filter(\.isVisible)
            if Store.testing, request["cancelImage"] as? Bool == true {
                imagePanels.forEach { $0.cancel(nil) }
            }
            // Typed into the one up, and a key pressed there ("return",
            // "down", "up", "left", "right", "esc"), as the keyboard would.
            // A --test run only.
            let keyWindow = request["tray"] as? Bool == true ? SpaceTray.shown?.window : popovers.last
            if Store.testing, let window = keyWindow {
                let keys: [String: (UInt16, String)] = ["return": (36, "\r"), "esc": (53, "\u{1b}"),
                                                        "down": (125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))), "up": (126, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
                                                        "left": (123, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))), "right": (124, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))]
                var presses = (request["type"] as? String ?? "").map { (UInt16(0), String($0)) }
                if let key = (request["key"] as? String).flatMap({ keys[$0] }) { presses.append(key) }
                if let x = request["x"] as? Double, let y = request["y"] as? Double, let content = window.contentView {
                    let point = content.convert(NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                if !presses.isEmpty, !window.isKeyWindow { window.makeKey() }
                for (code, characters) in presses {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
                        window.sendEvent(event)
                    }
                }
            }
            // The space's tray, a view over the window (SpaceTray): its panel.
            var trays: [[String: Any]] = []
            if let tray = SpaceTray.shown, let window = tray.window {
                let panel = window.convertToScreen(tray.convert(tray.panelFrame, to: nil))
                trays.append(["x": panel.minX, "y": top - panel.maxY, "w": panel.width, "h": panel.height])
            }
            answer(["popovers": popovers.map(place), "imagePanels": imagePanels.map(place), "trays": trays, "window": Links.window.map(place) ?? [:]])
        case "drop":
            // A menu in Settings (DropMenu): hovered, opened, keys sent.
            answer(DropPopup.bench(request))
        case "hitches":
            // The main thread's hitches of 100 ms or more, the last five
            // minutes, as a feedback report sends them (Lag).
            answer(["hitches": Lag.shared.hitches().map { ["ageSeconds": $0.ageSeconds, "durationMs": $0.durationMs] }])
        case "feedback-page":
            // The tab in front as a feedback report sends it, and under
            // "behind" the other page it sends beside it, if any.
            Task { @MainActor in
                let pages = await FeedbackDiagnostics.pages()
                answer(pages.front.merging(["behind": pages.behind]) { first, _ in first })
            }
        case "winshot":
            // The window's own chrome, drawn from its layers, the lights,
            // the column, the strip, for a look at the frame around the
            // page when the window is off on another space and no screen
            // capture can reach it. The page itself comes out blank: WebKit
            // paints it in a process of its own. "settings": Settings' own
            // window instead.
            let probeWindow = Store.testing ? (request["window"] as? Int).flatMap { number in
                NSApp.windows.first { $0.windowNumber == number }
            } : nil
            if Store.testing, request["window"] != nil, probeWindow == nil {
                answer(["error": "Requested original window is no longer available"]); return
            }
            // `browserWindow`: that browser window, though another is in front.
            let named = request["browserWindow"] != nil ? BrowserWindows.shared.window(for: browser) : nil
            // "popover": the popover up now, Look's over Settings (#459).
            let popover = request["popover"] as? Bool == true
                ? NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } : nil
            if request["popover"] as? Bool == true, popover == nil { answer(["error": "no popover"]); return }
            let which = popover ?? probeWindow ?? named ?? (request["settings"] as? Bool == true ? SettingsWindow.shared.window : Links.window)
            if Store.testing, request["native"] as? Bool == true, let window = which,
               let path = request["path"] as? String {
                Self.captureOwnWindow(window, path: path, cursor: request["cursor"] as? Bool == true, answer: answer)
                return
            }
            // Settings is AppKit's own split view, whose source list a layer
            // render leaves blank: it is drawn the way AppKit prints it.
            // "print": the browser's window drawn the same way, AppKit's own
            // drawing, for SwiftUI over the page that a layer render leaves out.
            if request["settings"] as? Bool == true || request["print"] as? Bool == true || popover != nil, let window = which, let content = window.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                let path = (request["path"] as? String) ?? NSTemporaryDirectory() + "yab-bench-settings.png"
                if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                    answer(["path": path])
                } else {
                    answer(["error": "no png"])
                }
                return
            }
            guard let window = which, let content = window.contentView,
                  let layer = content.superview?.layer ?? content.layer
            else { answer(["error": "no window"]); return }
            // "page": the page in front drawn in too, from WebKit's own
            // snapshot, under whatever lies over it (a --test run only).
            if Store.testing, request["page"] as? Bool == true, request["paged"] == nil,
               let web = browser.active?.builtPage, web.window === window, let host = web.layer {
                web.snapshot(PageShot()) { image, _ in
                    MainActor.assumeIsolated {
                        let sheet = CALayer()
                        sheet.frame = host.bounds
                        sheet.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        sheet.contentsGravity = .resize
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        host.insertSublayer(sheet, at: 0)
                        CATransaction.commit()
                        var again = request
                        again["paged"] = true
                        self.handle(again, yab: true) { reply in
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            sheet.removeFromSuperlayer()
                            CATransaction.commit()
                            answer(reply)
                        }
                    }
                }
                return
            }
            // `scale`: drawn at that many pixels a point instead of the
            // screen's, for measuring corners on a 1x test screen.
            let scale = (Store.testing ? (request["scale"] as? Double).map { CGFloat($0) } : nil) ?? window.backingScaleFactor
            let size = layer.bounds.size
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep) else { answer(["error": "no bitmap"]); return }
            context.cgContext.scaleBy(x: scale, y: scale)
            Bench.render(layer, in: context.cgContext)
            // A sheet on the window is a window of its own; it is drawn in
            // where it hangs, under the title bar.
            if let sheet = window.attachedSheet, let sheetLayer = sheet.contentView?.superview?.layer ?? sheet.contentView?.layer {
                let origin = CGPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
                context.cgContext.saveGState()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.25).cgColor)
                context.cgContext.addPath(CGPath.rounded(CGRect(origin: origin, size: sheet.frame.size), corner: 12))
                context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.cgContext.fillPath()
                context.cgContext.restoreGState()
                context.cgContext.saveGState()
                context.cgContext.addPath(CGPath.rounded(CGRect(origin: origin, size: sheet.frame.size), corner: 12))
                context.cgContext.clip()
                context.cgContext.translateBy(x: origin.x, y: origin.y)
                Bench.render(sheetLayer, in: context.cgContext)
                context.cgContext.restoreGState()
            }
            let path = (request["path"] as? String) ?? NSTemporaryDirectory() + "yab-bench-window.png"
            guard let png = rep.representation(using: .png, properties: [:]) else { answer(["error": "no png"]); return }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                answer(["path": path])
            } catch {
                answer(["error": error.localizedDescription])
            }

        case "drag":
            // A press, a path and a let-go, handed to the window as the mouse
            // would hand them, the pointer on the screen never moves. Points
            // are the window's, from its top-left, each with the time in ms
            // after the press it arrives at; `clicks` 2 presses as a double
            // click's second. A --test run only: it moves tabs.
            guard Store.testing else { answer(["error": "drag only works on a --test run"]); return }
            // "settings": Settings' window instead, a space's row by its grip.
            let probeWindow = (request["window"] as? Int).flatMap { number in NSApp.windows.first { $0.windowNumber == number } }
            guard let window = probeWindow ?? (request["settings"] as? Bool == true ? SettingsWindow.shared.window : Links.window),
                  let content = window.contentView,
                  let path = request["path"] as? [[Double]], let first = path.first, first.count >= 2
            else { answer(["error": "drag needs a path of [x, y, ms] points"]); return }
            let height = content.bounds.height
            let direct = window === SettingsWindow.shared.window || probeWindow != nil || request["direct"] as? Bool == true
            let clicks = request["clicks"] as? Int ?? 1
            let flags = Bench.flags(request["flags"])
            func post(_ type: NSEvent.EventType, _ point: [Double]) {
                let at = NSPoint(x: point[0], y: height - point[1])
                guard let event = NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { return }
                // Settings: straight to its window, past the app, which
                // would take a press in a window of an app not in front as
                // a click to come forward and take the keyboard from
                // whatever app someone is typing in.
                // Made its app's key window first, without the app coming
                // forward, since SwiftUI takes no first click in a window
                // that isn't.
                // "direct": the browser's window the same way, for a run on a
                // Mac whose screen someone else's windows are in front on.
                if direct {
                    if !window.isKeyWindow { window.makeKey() }
                    window.sendEvent(event)
                    return
                }
                // Into the queue, the way the mouse's own come: a loop that
                // tracks the mouse in the title bar reads the queue, and one
                // handed its events past it would wait for ever.
                NSApp.postEvent(event, atStart: false)
            }
            // Who the press goes to, and up from it: a drag that moves
            // nothing usually went to a view over the one meant.
            var hit: [String] = []
            var under = content.hitTest(NSPoint(x: first[0], y: height - first[1]))
            while let view = under, hit.count < 8, view !== content {
                hit.append(String(describing: type(of: view)))
                under = view.superview
            }
            // "down": false goes on from a drag before that wasn't let go
            // ("up": false), for a hand that stops where something opens
            // and then goes on to it.
            // A click handed straight to a window: its let-go goes into the
            // app's queue first. A press that begins a loop of its own
            // reading the mouse (a switch's, a slider's) stays inside
            // sendEvent until that loop finds a let-go in the queue, and the
            // bench's timers don't run meanwhile: handed to the window after,
            // the let-go never came and the bench never answered (Settings ›
            // Appearance's switches, shelf-settings; a real hand's press
            // there is answered at once).
            let still = path.allSatisfy { $0.count >= 2 && $0[0] == first[0] && $0[1] == first[1] }
            if direct, still, request["down"] as? Bool != false, request["up"] as? Bool != false,
               let letGo = NSEvent.mouseEvent(
                   with: .leftMouseUp, location: NSPoint(x: first[0], y: height - first[1]), modifierFlags: flags,
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                   eventNumber: 0, clickCount: clicks, pressure: 0) {
                NSApp.postEvent(letGo, atStart: false)
                post(.leftMouseDown, first)
                answer(["ok": true, "hit": hit])
                return
            }
            if request["down"] as? Bool != false { post(.leftMouseDown, first) }
            for point in path.dropFirst() {
                let delay = (point.count > 2 ? point[2] : 0) / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { post(.leftMouseDragged, point) }
            }
            let end = ((path.last?.count ?? 0) > 2 ? path.last![2] : 0) / 1000 + 0.03
            let up = request["up"] as? Bool != false
            DispatchQueue.main.asyncAfter(deadline: .now() + end) {
                if up { post(.leftMouseUp, path.last!) }
                answer(["ok": true, "hit": hit])
            }

        case "peek-depth":
            answer(browser.peekView?.depth.state ?? ["bound": false])

        case "corners":
            // Who cuts each page card's rounded edge, every stage in the
            // window (PageCorners, docs/page-corners.md): one owner, the
            // stage's mask, and the paper clear of the edge. "during" looks
            // a moment into a change as well: "hold" (the page held, as
            // while the tabs change sides), "preview" (room made beside it,
            // half its width) or "turn" (the tab "id" picked, its page
            // turning in), and answers once the change is let go.
            let window = Links.window
            func frontStage() -> StageView? {
                var queue: [NSView] = window?.contentView.map { [$0] } ?? []
                while let view = queue.popLast() {
                    if let stage = view as? StageView, stage.shows == browser.activeID, stage.window != nil { return stage }
                    if view is WKWebView { continue }
                    queue.append(contentsOf: view.subviews)
                }
                return nil
            }
            // "keep": left held, or the room left made, for a picture of it;
            // "during": "release" lets go. "control": the paper's ground put
            // back on the edge, as it was before, so the pixel check can show
            // it catches that (a test world only).
            if let on = request["control"] as? Bool, Store.testing, on != PaperView.groundOnEdge {
                PaperView.groundOnEdge = on
                var queue: [NSView] = window?.contentView.map { [$0] } ?? []
                while let view = queue.popLast() {
                    if let paper = view as? PaperView { paper.needsLayout = true; continue }
                    if view is WKWebView { continue }
                    queue.append(contentsOf: view.subviews)
                }
            }
            let keep = request["keep"] as? Bool == true
            let linear = CAMediaTimingFunction(name: .linear)
            switch request["during"] as? String {
            case "hold":
                guard let stage = frontStage() else { answer(["error": "no stage"]); return }
                stage.hold(true)
                var report = PageCorners.report(in: window)
                if !keep { stage.hold(false) }
                report["during"] = "hold"
                answer(report)
            case "preview":
                guard let stage = frontStage() else { answer(["error": "no stage"]); return }
                let frame = stage.convert(stage.bounds, to: nil)
                let half = (frame.width / 2).rounded()
                // The page and its card, as SplitRule makes the room.
                let paper = PageCorners.paper(for: stage)
                stage.preview(CGRect(x: frame.minX, y: frame.minY, width: half, height: frame.height), duration: 0.2, timing: linear)
                if let paper {
                    let card = paper.convert(paper.bounds, to: nil).insetBy(dx: 1, dy: 1)
                    paper.preview(CGRect(x: card.minX, y: card.minY, width: half, height: card.height), duration: 0.2, timing: linear)
                }
                var report = PageCorners.report(in: window)
                if !keep {
                    stage.preview(nil, duration: 0, timing: linear)
                    paper?.preview(nil, duration: 0, timing: linear)
                }
                report["during"] = "preview"
                answer(report)
            case "release":
                guard let stage = frontStage() else { answer(["error": "no stage"]); return }
                if stage.previewing != nil { stage.preview(nil, duration: 0, timing: linear) }
                PageCorners.paper(for: stage)?.preview(nil, duration: 0, timing: linear)
                stage.hold(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { answer(PageCorners.report(in: window)) }
            case "turn":
                guard Store.testing, let tab = find(request, in: browser) else { answer(missing(request)); return }
                browser.select(tab)
                // A pass for SwiftUI to hand the stage its new page, then
                // the layers as they are while it turns in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    var report = PageCorners.report(in: window)
                    report["during"] = "turn"
                    answer(report)
                }
            default:
                answer(PageCorners.report(in: window))
            }

        case "peek":
            // A link looked at over the tab in front, as ⇧-click does, then
            // kept or put away: "open" with a url, "keep", "close", or only
            // "status". Answers what is up, and which tabs hold one waiting. A --test run only: it opens a page over yours.
            guard Store.testing else { answer(["error": "peek only works on a --test run"]); return }
            switch request["act"] as? String {
            case "keep": browser.keepPeek()
            case "close": browser.closePeek()
            case "split": browser.splitPeek()
            case "status": break
            // Fingers on the peek: "by" in the trackpad's magnification,
            // out above 0, in below, lifted at the end. Answers once the
            // peek has gone where it goes, with the scale it was held at.
            case "pinch":
                guard let view = browser.peekView else {
                    answer(["error": "peek pinch needs a peek up"])
                    return
                }
                view.benchPinch(CGFloat((request["by"] as? NSNumber)?.doubleValue ?? 0),
                                steps: (request["steps"] as? Int) ?? 12) { took, held in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        answer(["took": took, "held": Double(held), "peeking": browser.peeking.map(Bench.short) ?? "",
                                "outside": browser.outside.count, "front": browser.active?.address?.absoluteString ?? "",
                                "tabs": browser.tabs.count])
                    }
                }
                return
            // A press on the page firming up, "amount" 0 to 1 of the way to
            // a Force Click, as PageView hands it on; answers the dim.
            case "press":
                guard let tab = browser.active else {
                    answer(["error": "peek press needs a tab in front"])
                    return
                }
                browser.pressPeek(on: tab, CGFloat((request["amount"] as? NSNumber)?.doubleValue ?? 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    answer(["dim": Double(browser.peekView?.dimShown ?? -1), "link": browser.peekView?.pressLink.map { $0 ? "yes" : "no" } ?? "unasked"])
                }
                return
            // A Force Click on SELECTOR's element, at its middle, as the
            // trackpad's press past the click hands it to the page.
            case "force":
                guard let tab = browser.active, let web = tab.builtPage, let from = request["from"] as? String else {
                    answer(["error": "peek force needs a selector and a tab in front"])
                    return
                }
                let quoted = (try? JSONSerialization.data(withJSONObject: [from])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                let js = "(() => { const b = document.querySelector(\(quoted)[0]).getBoundingClientRect(); const u = \(web.bounds.width) / innerWidth; return [(b.left + b.width / 2) * u, (b.top + b.height / 2) * u]; })()"
                web.run(js, in: .yab) { result in
                    guard case .success(let value) = result, let at = value as? [NSNumber], at.count == 2 else { return }
                    browser.forcePeek(on: tab, at: CGPoint(x: at[0].doubleValue, y: at[1].doubleValue))
                }
            default:
                guard let url = (request["url"] as? String).flatMap(Address.url(from:)), let tab = browser.active else {
                    answer(["error": "peek needs a url and a tab in front"])
                    return
                }
                // "from": a selector on the page, taken as the link clicked.
                if let from = request["from"] as? String, let web = tab.builtPage {
                    PeekOrigin.mark(from, in: web) { browser.peek(url, from: tab) }
                } else {
                    browser.peek(url, from: tab)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(["peeking": browser.peeking.map(Bench.short) ?? "", "url": browser.peeking?.address?.absoluteString ?? "",
                        "from": browser.peekFrom.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                        "outside": browser.outside.count,
                        // Whether a pair has room, which Open in Split View asks first.
                        "splitFits": browser.splitFits, "splitPlace": Double(browser.splitBook.place.width),
                        "pairs": browser.pairs.count,
                        "depth": browser.peekView?.depth.state ?? [:],
                        "placement": browser.peekView?.placement ?? [:],
                        // ⌘F over the peek: its page's bar, and the tab's under it.
                        "find": ["peek": browser.peeking?.finder.shown ?? false, "bar": browser.peekView?.findShown ?? false,
                                 "needle": browser.peeking?.finder.needle ?? "", "total": browser.peeking?.finder.total ?? 0,
                                 "index": browser.peeking?.finder.index ?? -1, "tab": browser.active?.finder.shown ?? false,
                                 "stage": browser.finding] as [String: Any],
                        "marks": PeekMarkView.all.allObjects.map(\.state),
                        // Every tab holding a peek, shown or waiting, and whether its mark is on.
                        "waiting": Dictionary(browser.tabs.compactMap { tab in
                            tab.peek.map { (Bench.short(tab), "\($0.address?.absoluteString ?? "") \(tab.peekMarked ? "marked" : "unmarked") \($0.asleep ? "asleep" : "awake")") }
                        }, uniquingKeysWith: { a, _ in a })])
            }

        case "loadbar":
            // Every page's bar for a page taking its time (LoadBar), the
            // peek's too: its phase, size and where it stands.
            answer(["bars": LoadBar.all.allObjects.filter { $0.window != nil }.map(\.state)])

        case "hovered":
            // The tab whose row SwiftUI says the pointer is on (its onHover),
            // and the rows' kept moves not told yet (ColumnQuiet).
            answer(["heard": browser.glance.heard.map { $0.uuidString } ?? "", "moves_kept": ColumnQuiet.movesKept,
                     "moves_told": ColumnQuiet.movesTold])

        case "chat-busy":
            // A chat at work (ChatBusy), a --test run only. "as": the site a
            // page on this Mac's own server stands in for, from its next
            // load. Answers every tab's state, and the page's own
            // visibility, so a test can tell a hidden page heard.
            guard Store.testing else { answer(["error": "chat-busy only works on a --test run"]); return }
            if let site = request["as"] as? String { ChatBusy.pretend = site.isEmpty ? nil : site }
            let now = Date()
            answer(["as": ChatBusy.pretend ?? "", "tabs": Dictionary(browser.tabs.map { tab in
                (Bench.short(tab), [
                    "busy": tab.chatBusy.map { $0.word } ?? "",
                    "busy_for": tab.chatBusy.map { now.timeIntervalSince($0.since) } ?? -1,
                    "done": tab.chatDone.map { $0.word } ?? "",
                    "front": AgentFeed.shared.inFront(tab),
                    "frontWhy": ["owned": BrowserWindows.shared.owner(of: tab.id) != nil, "active": browser.activeID == tab.id,
                                 "onScreen": BrowserWindows.shared.owner(of: tab.id)?.browser.onScreen(tab.id) ?? false,
                                 "pretend": AgentFeed.pretend.map { $0 ? "here" : "away" } ?? "real",
                                 "appActive": NSApp.isActive, "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "",
                                 "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""],
                    "now": TabGist.of(tab).now.map { [$0.word, $0.text].compactMap { $0 }.joined(separator: " ") } ?? "",
                ] as [String: Any])
            }, uniquingKeysWith: { a, _ in a })])

        case "linkcard":
            guard Store.testing else { answer(["error": "linkcard only works on a --test run"]); return }
            let card = browser.linkCard
            if let enabled = request["enabled"] as? Bool { browser.prefs.linkPreviews = enabled }
            if let host = request["as"] as? String { card.pretendHost = host.isEmpty ? nil : host }
            if request["act"] as? String == "close" { card.dismiss() }
            // Share's picker put away from outside, as a click elsewhere
            // or Escape does; the card must notice on its own.
            if request["act"] as? String == "unshare" {
                for window in NSApp.windows where String(describing: type(of: window)).contains("Popover") { window.orderOut(nil) }
            }
            if let shift = request["stationary_shift"] as? Bool,
               let window = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false)?.window,
               let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                    modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 56) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.postEvent(event, atStart: false)
            }
            if let coordinates = request["on_card"] as? [Double], coordinates.count == 2,
               let panel = card.filmWindow {
                let at = CGPoint(x: panel.frame.width * coordinates[0], y: panel.frame.height * coordinates[1])
                let screen = panel.convertPoint(toScreen: at)
                CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                let types: [NSEvent.EventType] = request["click"] as? Bool == true ? [.leftMouseDown, .leftMouseUp] : [.mouseMoved]
                // After this answer: a press on Share opens a menu, whose
                // own tracking would hold the answer until it closes.
                DispatchQueue.main.async {
                    for type in types {
                        if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 0) {
                            NSApp.sendEvent(event)
                        }
                    }
                }
            }
            if let coordinates = request["point"] as? [Double], coordinates.count == 2,
               let tab = browser.active, let web = tab.webKitOnly("WebKit-only bench fixtures", build: false), let window = web.window {
                // The real pointer's position and the same mouse event
                // WebKit receives from AppKit. Only in a test world's own
                // window, never on the user's browser.
                let local = CGPoint(x: coordinates[0] * web.pageZoom,
                    y: web.isFlipped ? coordinates[1] * web.pageZoom : web.bounds.height - coordinates[1] * web.pageZoom)
                let at = web.convert(local, to: nil), screen = window.convertPoint(toScreen: at)
                CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                let flags: NSEvent.ModifierFlags = request["shift"] as? Bool == true ? .shift : []
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    window.acceptsMouseMovedEvents = true
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.postEvent(event, atStart: false)
                }
            }
            var report = card.report
            report["windows_up"] = NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }
            if let url = (request["remembered"] as? String).flatMap(URL.init(string:)) {
                report["remembered"] = browser.history.remembers(History.key(for: url))
            }
            answer(report)

        case "glance":
            // The card a tab shows when the pointer rests on it, as if it
            // had, "on": false to put it away. A --test run only.
            guard Store.testing else { answer(["error": "glance only works on a --test run"]); return }
            if request["action"] != nil { folderPreviewCommand(request, browser: browser, answer); return }
            if let name = request["folder"] as? String,
               let nest = browser.nests.first(where: { $0.name == name }) {
                browser.glance.pretendFolder(nest.key, request["on"] as? Bool ?? true)
                // "at": a folder in it gone into, as a click on its row does.
                if let at = request["at"] as? String, let inner = browser.nests.first(where: { $0.name == at }) { browser.glance.enter(inner) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let items = browser.glance.items(nest.key).map { item -> String in
                        switch item {
                        case .tab(let tab): return "tab:" + tab.label
                        case .folder(let inner, let count): return "folder:\(inner.name):\(count)"
                        }
                    }
                    answer(["folder": browser.glance.shownFolder ?? "", "at": browser.glance.at ?? "", "items": items])
                }
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // A pin's card is its list (PinCards.swift): opened as a
            // folder's preview is, its lines in the answer.
            if PinList.wanted(tab) {
                if let frame = browser.keySky.place(tab.id) { browser.glance.folderFrames[TabGlance.pinKey(tab.id)] = frame }
                browser.glance.pretendFolder(TabGlance.pinKey(tab.id), request["on"] as? Bool ?? true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    answer(["pin": browser.glance.shownFolder ?? "", "heading": PinList.heading(tab, in: browser),
                            "items": browser.glance.pinItems.map { ["title": $0.title, "detail": $0.detail, "strong": $0.strong] as [String: Any] }])
                }
                return
            }
            // "words": what a live folder would say of the thing the tab
            // shows (LiveSeen), for its card's line without a folder.
            if let said = request["words"] as? String, let key = LiveText.thing(tab.address), let url = tab.address {
                LiveSeen.note([LiveItem(key: key, url: url, title: tab.label, group: request["group"] as? String ?? "",
                                        words: LiveWords(rawValue: said), updated: nil,
                                        due: (request["due_days_ago"] as? Double).map { Date().addingTimeInterval(-$0 * 86_400) })])
            }
            browser.glance.pretend(tab.id, request["on"] as? Bool ?? true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // Where the tab is said to be, which the card hangs from.
                let place = browser.keySky.place(tab.id) ?? .zero
                let gist = TabGist.of(tab)
                let card = browser.glance.previewFrame ?? .zero
                // "press": the card's button pressed, as a click on it does.
                if request["press"] as? Bool == true, let action = gist.action {
                    browser.glance.act(action, on: tab)
                }
                answer(["shown": browser.glance.shown.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                        "place": [place.minX, place.minY, place.width, place.height].map(Double.init),
                        "card": [card.minX, card.minY, card.width, card.height].map(Double.init),
                        "title": gist.title ?? tab.label, "facts": gist.facts ?? "",
                        "now": gist.now.map { [$0.word, $0.text].compactMap { $0 }.joined(separator: " ") } ?? "",
                        "button": gist.action?.label ?? "", "holds": browser.glance.holds,
                        // Where a pressed Connect went.
                        "settings": SettingsWindow.shared.window?.isVisible == true ? SettingsWindow.shared.page.rawValue : ""])
            }

        case "know":
            // yab://you in a test world (KnowPage): a report as a run leaves
            // one, the run's end arriving, the page's state as it draws it.
            // A --test run only.
            guard Store.testing else { answer(["error": "know only works on a --test run"]); return }
            switch request["action"] as? String ?? "state" {
            case "report":
                var report = KnowReport.given(request["report"] as? [String: Any] ?? [:])
                report.minutes = request["minutes"] as? Int ?? 9
                report.sites = request["sites"] as? Int ?? 14
                KnowReport.save(report)
                answer(["ok": true])
            case "arrive":
                KnowPage.arrive(in: browser)
                answer(["tabs": browser.tabs.map { ["id": String($0.id.uuidString.prefix(8)).lowercased(), "url": $0.address?.absoluteString ?? "", "title": $0.title] }])
            case "show":
                // As Settings' Notes About You, or a link in the run's chat (`section`).
                KnowPage.show(in: browser, section: request["section"] as? String)
                answer(["ok": true])
            case "address":
                // An address in the Wallet as a run or another browser left
                // it: `used` in seconds from now.
                var address = StreetAddress(id: request["id"] as? String ?? UUID().uuidString)
                address.name = request["name"] as? String ?? ""
                address.organization = request["organization"] as? String ?? ""
                address.street = request["street"] as? String ?? ""
                address.city = request["city"] as? String ?? ""
                address.postal = request["postal"] as? String ?? ""
                address.country = request["country"] as? String ?? ""
                address.source = request["source"] as? String
                address.found = request["found"] as? String
                address.used = (request["used"] as? Double).map { Date().addingTimeInterval($0) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = Wallet.save(address)
                    DispatchQueue.main.async { answer(["ok": ok]) }
                }
            case "addresses":
                DispatchQueue.global(qos: .userInitiated).async {
                    let all = Wallet.addresses()
                    let phones = Dictionary(all.map { ($0.id, $0.phone) }, uniquingKeysWith: { a, _ in a })
                    DispatchQueue.main.async { answer(["ids": all.map(\.id), "phones": phones]) }
                }
            default:
                let met = request["met"] as? Bool ?? false
                DispatchQueue.global(qos: .userInitiated).async {
                    let state = KnowNotes.state(met: met)
                    DispatchQueue.main.async { answer(state) }
                }
            }

        case "band":
            // The row over the column's foot for what plays elsewhere
            // (PlayerBand.swift): its state after ACTION (BandView.bench)
            // and SECONDS, with the main thread's CPU and the process's
            // instructions over that time.
            guard Store.testing else { answer(["error": "band only works on a --test run"]); return }
            let view = BandView.last
            let seconds = min(request["seconds"] as? Double ?? 0.6, 20)
            let cpu0 = Bench.mainCPU(), ins0 = Bench.instructions(), t0 = CACurrentMediaTime()
            Player.cost = 0
            if let action = request["action"] as? String { view?.bench(action) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                var report = view?.report ?? [:]
                report["main_cpu_ms"] = ((Bench.mainCPU() - cpu0) * 100).rounded() / 100
                report["instructions_m"] = ((Bench.instructions() - ins0) * 10).rounded() / 10
                report["seconds"] = ((CACurrentMediaTime() - t0) * 100).rounded() / 100
                answer(report)
            }

        case "keytip":
            // A shortcut as it is now (Hotkeys), and its tooltip drawn to a
            // PNG: the tip is a window of its own, which winshot doesn't see.
            let title = request["title"] as? String ?? "Open as Tab"
            let shortcut = request["shortcut"] as? String
            let keys = shortcut.map { Hotkeys.shared.keys($0) }
            let host = NSHostingView(rootView: KeyTipView(title: title, keys: keys))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.title == shortcut { return item }
                    if let deeper = find(item.submenu) { return deeper }
                }
                return nil
            }
            let item = find(NSApp.mainMenu)
            var out: [String: Any] = ["menu": item.map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" } ?? "", "keys": keys ?? "", "tipShown": KeyTip.shared.showing, "heard": KeyTip.shared.heard,
                                      "tipTitle": KeyTip.shared.lastTitle, "rect": "\(KeyTip.shared.lastRect)", "tip": "\(KeyTip.shared.lastFrame)",
                                      "window": "\(Links.window?.frame ?? .zero)"]
            if let path = request["path"] as? String, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                out["path"] = path
            }
            // "show": the tip put up over the window as a pointer resting
            // on a button puts it, and what that cost the main thread: its
            // longest pass and all of them, and where it landed.
            if request["show"] as? Bool == true, let window = Links.window {
                let owner = NSObject()
                let meter = Busy()
                let rect = NSRect(x: window.frame.midX - 30, y: window.frame.midY, width: 60, height: 28)
                let longest = Longest()
                KeyTip.shared.hover(owner, title: title, shortcut: shortcut, keys: request["keys"] as? String, at: rect, side: .below)
                DispatchQueue.main.asyncAfter(deadline: .now() + KeyTip.dwell + 0.4) {
                    out["busy_ms"] = (meter.stop() * 10).rounded() / 10
                    out["longest_ms"] = (longest.stop() * 10).rounded() / 10
                    out["tip"] = "\(KeyTip.shared.lastFrame)"
                    out["fits"] = "\(host.fittingSize)"
                    KeyTip.shared.leave(owner)
                    answer(out)
                }
                return
            }
            answer(out)

        case "bookmark-menu":
            // The menu bar's Bookmarks menu, updated as opening it would:
            // its items' titles, the bookmarks' marked, and how long the
            // update took.
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu else {
                answer(["error": "no Bookmarks menu"])
                return
            }
            // Asked as for a key's equivalent first, which must add nothing,
            // then as the menu bar opening it.
            menu.delegate?.menuNeedsUpdate?(menu)
            let quiet = BookmarkMenu.shared.count
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
            let start = CACurrentMediaTime()
            menu.delegate?.menuNeedsUpdate?(menu)
            let took = (CACurrentMediaTime() - start) * 1000
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu)
            answer(["wrapped": String(describing: type(of: menu.delegate as AnyObject)), "items": menu.items.map(\.title),
                    // Each item's mark, averaged, "" for none (evals/bookmark-icons).
                    "images": menu.items.map { $0.image.flatMap { Scope.average(of: $0)?.hex } ?? "" },
                    "ours": BookmarkMenu.shared.count, "ms": took, "unopened": quiet])

        case "menu-pop":
            // One of the menu bar's menus open over the window, as from its
            // title, for "seconds", so an outside capture can see it; the
            // window's frame, top-left based, and the app's pid, to find
            // the menu's own window by.
            guard Store.testing else { answer(["error": "menu-pop only works on a --test run"]); return }
            let title = request["menu"] as? String ?? "History"
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu,
                  let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let content = window.contentView else {
                answer(["error": "no \(title) menu or window"])
                return
            }
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu)
            // A copy: the menu bar's own menu stays its submenu.
            let shown = menu.copy() as! NSMenu
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = window.frame
            answer(["frame": [frame.minX, top - frame.maxY, frame.width, frame.height].map { Double($0) }, "items": shown.items.map(\.title),
                    "pid": Int(ProcessInfo.processInfo.processIdentifier)])
            let seconds = request["seconds"] as? Double ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let close = Timer(timeInterval: seconds, repeats: false) { _ in shown.cancelTracking() }
                RunLoop.main.add(close, forMode: .common)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                // Under the toolbar, whichever way the content view counts.
                shown.popUp(positioning: nil, at: NSPoint(x: 240, y: content.isFlipped ? 12 : content.bounds.maxY - 12), in: content)
            }
        case "app-menu":
            // The Yab menu as opening it shows it (UpdateMenu's line under
            // About), and "press": one of its items by title, as a click.
            // SwiftUI brings a commands menu's items up to date when the
            // menu opens (its delegate's menuNeedsUpdate); read without
            // that, the items can still be the ones from before the
            // Updater's stage changed, as they were on adhd for 0.0.20's
            // QA. "unopened": the items as they stand, the menu not opened.
            // "menu": another of the menu bar's by title, such as History.
            let title = request["menu"] as? String
            guard let menu = (title.map { title in NSApp.mainMenu?.items.first { $0.title == title } } ?? NSApp.mainMenu?.items.first)?.submenu else {
                answer(["error": "no \(title ?? "app") menu"])
                return
            }
            var out: [String: Any] = [:]
            out["unopened"] = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            if request["open"] as? Bool != false {
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu)
            }
            if let title = request["press"] as? String {
                let index = menu.items.firstIndex { $0.title == title && $0.isEnabled }
                if let index { menu.performActionForItem(at: index) }
                out["pressed"] = index != nil
            }
            // A nested command, for the same action checks as a top-level
            // press (Appearance, numbered tabs and Move Tab to Space).
            if let path = request["path"] as? [String], !path.isEmpty {
                var found: NSMenu? = menu
                var pressed = false
                for (offset, title) in path.enumerated() {
                    guard let current = found else { break }
                    current.delegate?.menuNeedsUpdate?(current)
                    current.update()
                    guard let index = current.items.firstIndex(where: { $0.title == title && $0.isEnabled }) else { break }
                    if offset == path.count - 1 {
                        current.performActionForItem(at: index)
                        pressed = true
                    } else {
                        found = current.items[index].submenu
                    }
                }
                out["pressed"] = pressed
            }
            // Each item's key as the menu shows it (⌃⌥⇧⌘ and the key), and
            // a submenu's items one level down, for evals/menus.
            func key(_ item: NSMenuItem) -> String {
                guard !item.keyEquivalent.isEmpty else { return "" }
                var flags = item.keyEquivalentModifierMask
                // A capital letter is the key with ⇧, as AppKit reads it.
                if item.keyEquivalent != item.keyEquivalent.lowercased() { flags.insert(.shift) }
                let marks = [(NSEvent.ModifierFlags.function, "fn"), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                    .filter { flags.contains($0.0) }.map(\.1).joined()
                return marks + item.keyEquivalent.uppercased()
            }
            out["items"] = menu.items.filter { !$0.isSeparatorItem }.map { item -> [String: Any] in
                var row: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "key": key(item), "hidden": item.isHidden]
                if let sub = item.submenu {
                    row["items"] = sub.items.filter { !$0.isSeparatorItem }.map { ["title": $0.title, "enabled": $0.isEnabled, "key": key($0), "hidden": $0.isHidden] }
                }
                return row
            }
            // Each item's key as AppKit holds it once the menu has opened, fn included (View's full screen).
            out["keys"] = menu.items.filter { !$0.isSeparatorItem }.map {
                ["title": $0.title, "key": $0.keyEquivalent, "mask": Int($0.keyEquivalentModifierMask.rawValue),
                 "action": $0.action.map(NSStringFromSelector) ?? "", "enabled": $0.isEnabled, "hidden": $0.isHidden] as [String: Any]
            }
            out["menus"] = NSApp.mainMenu?.items.map(\.title) ?? []
            out["stage"] = String(describing: Updater.shared.stage)
            answer(out)

        case "hoard":
            // The downloads button's state: whether it has a place, and
            // what keeps it there (Hoard.shown).
            let hoard = browser.hoard
            // For a picture of the column's stack (HoardStack.swift), in a
            // test world: files remembered as downloaded, minutes ago; a
            // download that isn't one, part way; the stack up or down.
            if Store.testing {
                for file in request["keep"] as? [[String: Any]] ?? [] {
                    guard let path = file["path"] as? String else { continue }
                    let ago = (file["minutes"] as? Double ?? 0) * 60
                    browser.loot.add(Keep(name: (path as NSString).lastPathComponent, from: file["from"] as? String ?? "",
                                          path: path, date: Date().addingTimeInterval(-ago)))
                }
                if let fetch = request["pretend"] as? [String: Any], let name = fetch["name"] as? String {
                    hoard.pretend(name: name, from: fetch["from"] as? String ?? "",
                                  got: (fetch["got"] as? NSNumber)?.int64Value ?? 0, total: (fetch["total"] as? NSNumber)?.int64Value ?? 0)
                }
                if let on = request["ticking"] as? Bool { hoard.pretendTicking(on) }
                // A file thrown from here at the next download, as a click would.
                if let at = request["pressAt"] as? [Double], at.count == 2 { hoard.notePress(at: CGPoint(x: at[0], y: at[1])) }
                if request["failPretended"] as? Bool == true { hoard.pretendFailed() }
                if let name = request["landPretended"] as? String { hoard.pretendLanded(name) }
                if request["forget"] as? Bool == true { hoard.forgetPretended() }
                // Stop under way, dismiss when failed: as the row's own button.
                if request["stop"] as? Bool == true { for fetch in hoard.fetches { hoard.stop(fetch.id) } }
                if request["count"] as? Bool == true { HoardStack.bodies = 0; HoardStack.cards = 0; HoardStack.hushes = 0 }
                // Nothing over the page: a fresh world opens on the field.
                if request["calm"] as? Bool == true { browser.editing = false }
                if let on = request["stack"] as? Bool { hoard.holdStack(on) }
                if let name = request["list"] as? String,
                   let place = ["side": Hoard.Place.side, "strip": .strip, "chip": .chip][name] { hoard.toggle(place) }
                if let inside = request["hover"] as? Bool { hoard.hover(.side, inside) }
                if let name = request["hoverAt"] as? String,
                   let place = ["side": Hoard.Place.side, "strip": .strip, "chip": .chip][name] { hoard.hover(place, true) }
                if request["close"] as? Bool == true { hoard.openAt = nil }
                // A badge on the Dock icon, as Mail's, to see it outlast the bar.
                if let badge = request["dockBadge"] as? String { NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge }
            }
            // The Dock tile as it is drawn now (DockProgress): the bar's
            // view while downloads are under way, the plain icon otherwise.
            var dock: [String: Any] = ["fraction": DockProgress.shared.shown ?? -1,
                                       "bar": NSApp.dockTile.contentView is DockProgressView,
                                       "badge": NSApp.dockTile.badgeLabel ?? ""]
            if let path = request["dockShot"] as? String {
                if let png = DockProgress.shared.picture()?.representation(using: .png, properties: [:]),
                   (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                    dock["shot"] = path
                } else {
                    dock["shot"] = ""
                }
            }
            // Actual mounted button layouts, rather than the model's shown
            // flag or an unavailable accessibility tree. Track each
            // instance so even duplicated buttons at one place fail UI probes.
            func buttons(_ window: NSWindow?) -> [[String: CGFloat]] {
                guard let bounds = window?.contentView?.bounds else { return [] }
                return hoard.buttonFrames.values.compactMap { observed in
                    let frame = observed.frame
                    guard frame.width > 0, frame.height > 0, bounds.intersects(frame) else { return nil }
                    return ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
                }
            }
            answer(["shown": hoard.shown, "fetches": hoard.fetches.count, "failed": hoard.fetches.filter(\.failed).count, "dock": dock,
                    "airborne": hoard.airborne, "landed": hoard.landed, "settled": hoard.settled,
                    "chipOut": hoard.away && hoard.calling, "landing": hoard.landing.map { [$0.x, $0.y] } ?? [], "stackOut": hoard.stackOut, "peek": browser.sidePeek, "staying": hoard.staying, "unseen": hoard.unseen,
                    "open": hoard.openAt != nil, "kept": browser.loot.kept.count,
                    "toast": browser.toaster.shown ? browser.toaster.words : "",
                    "files": browser.loot.kept.prefix(20).map { ["name": $0.name, "path": $0.path] },
                    "bodies": ["stack": HoardStack.bodies, "cards": HoardStack.cards, "hush": HoardStack.hushes],
                    "home": hoard.frames[.side].map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? [:],
                    "away": hoard.away,
                    "chip": hoard.frames[.chip].map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? [:],
                    "strip": hoard.frames[.strip].map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } ?? [:],
                    "buttons": request["buttons"] as? Bool == true ? buttons(Links.window) : [],
                    "mounted": request["buttons"] as? Bool == true ? hoard.buttonFrames.map { id, observed -> [String: Any] in
                        let frame = observed.frame
                        return ["id": id.uuidString, "place": String(describing: observed.place),
                                "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
                    } : [],
                    "list": hoard.listWindow.map { ["number": $0.windowNumber, "x": $0.frame.minX, "y": $0.frame.minY,
                                                    "w": $0.frame.width, "h": $0.frame.height, "visible": $0.isVisible,
                                                    "parent": $0.parent?.windowNumber ?? 0] } ?? [:],
                    "stack": hoard.stackWindow.map { ["number": $0.windowNumber, "x": $0.frame.minX, "y": $0.frame.minY,
                                                      "w": $0.frame.width, "h": $0.frame.height, "visible": $0.isVisible,
                                                      "parent": $0.parent?.windowNumber ?? 0] } ?? [:],
                    "window": Links.window.map { ["number": $0.windowNumber, "x": $0.frame.minX, "y": $0.frame.minY,
                                                    "w": $0.frame.width, "h": $0.frame.height, "visible": $0.isVisible,
                                                    "occluded": !$0.occlusionState.contains(.visible), "key": $0.isKeyWindow] } ?? [:]])

        case "pointer-move":
            // The pointer brought to a point of the window's, from its
            // top-left, through the app's queue as the mouse's own moves
            // come, so the app's monitors hear it too: the column's edge
            // puts up its cursor and its tip from one (SideEdge).
            guard let window = Links.window, let content = window.contentView,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(["error": "pointer-move needs x and y"]); return }
            if !window.isKeyWindow { window.makeKey() }
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: content.bounds.height - y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(moved, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.3)) {
                var out: [String: Any] = ["ok": true, "tipShown": KeyTip.shared.showing, "tipTitle": KeyTip.shared.lastTitle,
                                          "tip": "\(KeyTip.shared.lastFrame)", "window": "\(window.frame)",
                                          "cursor": NSCursor.current == NSCursor.resizeLeftRight ? "resizeLeftRight" : "other"]
                // The tip drawn to `path` while it shows: a window of its
                // own, which winshot doesn't see.
                if let path = request["path"] as? String { out["drawn"] = KeyTip.shared.snapshot(to: URL(fileURLWithPath: path)) }
                answer(out)
            }

        case "mouse-swipe":
            guard Store.testing else { answer(["error": "mouse-swipe requires --test"]); return }
            guard let window = Links.window, let content = window.contentView,
                  let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let dx = request["dx"] as? Double else {
                answer(["error": "mouse-swipe needs x, y and dx"]); return
            }
            let at = NSPoint(x: x, y: content.bounds.height - y)
            guard let event = Self.mouseSwipe(dx, phase: .began, at: at, in: window),
                  let end = Self.mouseSwipe(0, phase: .ended, at: at, in: window),
                  event.type == .swipe, event.window === window,
                  event.deltaX == CGFloat(dx) else {
                answer(["error": "could not create a window-stamped mouse swipe"]); return
            }
            let sidebar = SpaceSwipe.claims(event)
            NSApp.postEvent(event, atStart: false)
            NSApp.postEvent(end, atStart: false)
            answer(["ok": true, "sidebar": sidebar, "dx": event.deltaX])

        case "middle":
            // A press and let-go of the middle button at a point of the
            // window's, from its top-left, handed over as the mouse hands
            // it; "button" 3 or 4 a side button, back or forward, instead.
            // A --test run only: it closes tabs.
            guard Store.testing else { answer(["error": "middle only works on a --test run"]); return }
            guard let window = Links.window, let content = window.contentView,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(["error": "middle needs x and y"]); return }
            let at = NSPoint(x: x, y: content.bounds.height - y)
            // The pointer brought there first, as a hand brings it, so what
            // is under it knows.
            if request["move"] as? Bool != false,
               let moved = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(moved)
            }
            var buttons: [Int] = []
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                // A separated press/release probes cancellation and a
                // repeated release without moving hover to the next row.
                if request["phase"] as? String == "down", type != .otherMouseDown { continue }
                if request["phase"] as? String == "up", type != .otherMouseUp { continue }
                // Made as a left click's is, then told which button it is:
                // AppKit has no way to say so when making one.
                guard let made = NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: Bench.flags(request["flags"]), timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .otherMouseUp ? 0 : 1
                )?.cgEvent else { continue }
                made.setIntegerValueField(.mouseEventButtonNumber, value: Int64(request["button"] as? Int ?? 2))
                guard let event = NSEvent(cgEvent: made) else { continue }
                buttons.append(event.buttonNumber)
                NSApp.postEvent(event, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(["ok": true, "buttons": buttons]) }

        case "pdf-hud":
            // WebKit's own bar along a PDF's foot (WKPDFHUDView): shown, and
            // its buttons' frames from the window's top left, in order:
            // Zoom Out, Zoom In, Open in Preview, Download. "press", a
            // button's index (-1 the last, Download), clicks it as the mouse
            // does, through the window. A --test run only: it saves files.
            guard Store.testing else { answer(["error": "pdf-hud only works on a --test run"]); return }
            guard let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false), let window = web.window, let content = window.contentView
            else { answer(["error": "pdf-hud needs a page in front"]); return }
            func hud(in view: NSView) -> NSView? {
                for sub in view.subviews {
                    if String(describing: type(of: sub)).contains("PDFHUD") { return sub }
                    if let found = hud(in: sub) { return found }
                }
                return nil
            }
            guard let bar = hud(in: web) else { answer(["error": "no bar", "pdf": web.webKitShowsPDF]); return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // Shown, as a pointer over the page shows it.
            guard PDFHUDProbe.show(bar) else {
                answer(["error": "PDF bar has no visibility interface"])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let (buttons, shown) = PDFHUDProbe.controls(in: bar)
                let frames = buttons.map { [Double($0.minX), Double(content.bounds.height - $0.maxY), Double($0.width), Double($0.height)] }
                guard let index = request["press"] as? Int else {
                    answer(["buttons": frames, "opacity": shown])
                    return
                }
                guard !buttons.isEmpty else { answer(["error": "no buttons", "opacity": shown]); return }
                let button = buttons[index < 0 ? buttons.count + index : min(index, buttons.count - 1)]
                let at = NSPoint(x: button.midX, y: button.midY)
                for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                                         pressure: type == .leftMouseDown ? 1 : 0)
                    else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(["buttons": frames, "opacity": shown, "pressed": index]) }
            }

        case "modellist":
            // The model list (ModelField) as it opens, to a PNG: "cli" and
            // "model" what is chosen, "mac" a command's list with this Mac's,
            // "work" a default's list (tasks, commands, drafts).
            guard Store.testing else { answer(["error": "modellist only works on a --test run"]); return }
            let path = (request["path"] as? String) ?? NSTemporaryDirectory() + "yab-bench-models.png"
            let drawn = ModelField.listPicture(choice: ModelChoice(cli: request["cli"] as? String, model: request["model"] as? String),
                                               offersMac: request["mac"] as? Bool ?? false,
                                               work: (request["work"] as? String).flatMap(ModelDefaults.Work.init(rawValue:)),
                                               plans: request["plans"] as? [String], to: path)
            answer(drawn ? ["path": path] : ["error": "not drawn"])

        case "gemini":
            // Gemini's state as Settings and the lists show it, for
            // pictures: "binary", "signedIn", and `agy models` lines; "picker"
            // opens the chat's model picker, on "query".
            guard Store.testing else { answer(["error": "gemini only works on a --test run"]); return }
            let account = GeminiAccount.shared
            if request["binary"] != nil || request["signedIn"] != nil || request["models"] != nil {
                account.pretend(binary: request["binary"] as? String, signedIn: request["signedIn"] as? Bool,
                                models: request["models"] as? String ?? "",
                                waiting: request["waiting"] as? Bool == true ? .signingIn : nil,
                                identity: (request["email"] as? String).map { GeminiIdentity(email: $0, plan: request["plan"] as? String) },
                                quota: (request["usage"] as? String).flatMap { GeminiQuota.read($0) })
            }
            if let google = request["google"] as? [String] {
                MailFound.fake = google.map { MailFound.Account(email: $0, name: "", photo: nil, space: browser.spaceID) }
            }
            if let switching = request["switching"] as? Bool { GeminiChoices.shared.switching = switching }
            if let source = request["source"] as? String {
                account.choice = source == "space" ? GeminiChoice(source: .space(browser.spaceID), email: request["chosenEmail"] as? String,
                    place: request["place"] as? String) : source == "mac" ? GeminiChoice(source: .mac, email: account.identity?.email) : .another
            }
            if let showing = request["choosing"] as? Bool { GeminiChoices.shared.showing = showing }
            if request["picker"] as? Bool == true {
                ChatModelLine.choose(browser: browser, chat: nil, query: request["query"] as? String ?? "")
            }
            if let code = request["code"] as? String { _ = account.submitCode(code) }
            answer(["awaitingCode": account.awaitingCode, "submittingCode": account.submittingCode,
                    "codeError": account.codeError ?? "", "binary": account.binary ?? "", "signedIn": account.signedIn.map { $0 ? "yes" : "no" } ?? "unknown",
                    "ready": account.ready, "models": account.models.map(\.model),
                    "email": account.identity?.email ?? "", "choiceRows": GeminiChoices.shared.rows.map { $0.email ?? "another" },
                    "trouble": account.trouble ?? "", "pageOpen": account.pageOpen, "looking": GeminiChoices.shared.looking])

        case "settingsclick":
            // An isolated probe's native click, in Settings content points
            // from the top left. AppKit routes it to the actual control.
            guard Store.testing, let window = SettingsWindow.shared.window,
                  let content = window.contentView, let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(["error": "settingsclick needs a test Settings window and x, y"]); return }
            let at = NSPoint(x: x, y: content.bounds.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["sheet": window.attachedSheet?.windowNumber ?? 0, "enabled": browser.prefs.usesLiveFolders])
            }
            return

        case "nightlyoff":
            // Nightly builds turned off on Settings › General, as its switch
            // does, and the question that may follow: its words and buttons;
            // "press", a button's title, as a click on it.
            guard Store.testing else { answer(["error": "nightlyoff only works on a --test run"]); return }
            SettingsModel.ask(.general)
            SettingsWindow.shared.show(for: browser)
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func sheet() -> [NSView] { SettingsWindow.shared.window?.attachedSheet?.contentView.map(views) ?? [] }
            if let title = request["press"] as? String {
                let button = sheet().compactMap { $0 as? NSButton }.first { $0.title == title }
                button?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    answer(["pressed": button != nil, "tabs": browser.tabs.compactMap { $0.address?.absoluteString }])
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if request["on"] as? Bool == true {
                    Store.settings.set(true, forKey: Updater.nightlyKey)
                } else if request["look"] as? Bool != true {
                    Store.settings.set(false, forKey: Updater.nightlyKey)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 1.2)) {
                    answer(["sheet": SettingsWindow.shared.window?.attachedSheet?.windowNumber ?? 0,
                            "words": sheet().compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty },
                            "buttons": sheet().compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty },
                            "nightly": Store.settings.bool(forKey: Updater.nightlyKey)])
                }
            }
            return

        case "apple-extension-scene":
            guard Store.testing else { answer(["error": "test session required"]); return }
            let connected = request["connected"] as? Bool ?? false
            ApplePasswordExtensionRoute.isConnected = { connected }
            ApplePasswordExtensionRoute.pair = {
                await Questions.shared.ask(ApplePasswordsPairing.connectQuestion(model: ApplePasswordsPairing.CodeModel()))
            }
            let id = PasswordManagers.apple
            if request["inspect"] as? Bool != true {
                if request["press"] as? Bool == true { Extensions.here.press(id) }
                else { Extensions.here.install(from: id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(["installed": Extensions.here.installed.contains { $0.id == id },
                        "connected": connected, "question": Questions.shared.current?.title ?? "",
                        "notice": browser.toaster.shown ? browser.toaster.words : ""])
            }

        case "settingsnotice":
            // A notice said by the browser or by Settings, and where each
            // corner stands after it: Settings shows only its own.
            if request["from"] as? String == "settings" {
                browser.announce("Yab is up to date", mark: "checkmark.circle", on: SettingsWindow.shared.toaster)
            } else if request["from"] as? String == "browser" {
                browser.announce("Link copied", mark: "link")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.4)) {
                let settings = SettingsWindow.shared.toaster
                let pointed = LinkStatus.shared.pointed
                answer(["browser": browser.toaster.shown ? browser.toaster.words : "",
                        "settings": settings.shown ? settings.words : "",
                        // The link under the pointer, and its words.
                        "pointed": pointed?.url.absoluteString ?? "", "pointedLabel": pointed?.label ?? ""])
            }
            return

        case "settingspace":
            // Settings' frames for a while, timed, with the main thread's
            // CPU and busy time: to be started just before something is
            // done there, a row dragged, a popover opened.
            settingsPace(request, answer)
        case "smartzoom":
            // Two fingers tapped twice over the page in front (Smart Zoom),
            // as the trackpad hands it over: a gesture event at "x", "y",
            // points of the page's from its top left, posted to the app so
            // whatever is under the fingers takes it. Then "seconds" of
            // display frames, each with when it came, the page's
            // magnification, the largest scale Core Animation shows in the
            // page's layers right then (WebKit's own zoom moves a layer and
            // lands the magnification at the end), and whether anything
            // there is animating. "where" answers the window and where the
            // page is in it instead, for filming. A --test run only.
            guard Store.testing else { answer(["error": "smartzoom only works on a --test run"]); return }
            guard let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false), let window = web.window, let content = window.contentView
            else { answer(["error": "no page in a window"]); return }
            let frame = web.convert(web.bounds, to: nil)
            let place: [String: Any] = [
                "window": window.windowNumber, "scale": Double(window.backingScaleFactor),
                "page": [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height].map(Double.init),
                "magnification": Double(web.magnification), "pageZoom": Double(web.pageZoom),
            ]
            if request["where"] as? Bool == true { answer(place); return }
            let x = request["x"] as? Double ?? Double(frame.width / 2), y = request["y"] as? Double ?? Double(frame.height / 2)
            let at = NSPoint(x: frame.minX + x, y: frame.maxY - y)
            guard let event = Bench.smartMagnify(at: at, in: window) else { answer(["error": "no gesture event"]); return }
            let watch = ZoomWatch(web)
            let link = content.displayLink(target: watch, selector: #selector(ZoomWatch.tick(_:)))
            link.add(to: .main, forMode: .common)
            let cpu0 = Bench.mainCPU()
            let start = CACurrentMediaTime()
            NSApp.postEvent(event, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["seconds"] as? Double ?? 1.2)) {
                link.invalidate()
                var out = place
                out["eventType"] = Int(event.type.rawValue)
                out["start"] = start
                out["mainCPU"] = Bench.mainCPU() - cpu0
                out["before"] = place["magnification"]
                out["magnification"] = Double(web.magnification)
                out["frames"] = watch.rows
                answer(out)
            }

        case "pull":
            // Two fingers sideways over the page in front, as a trackpad's
            // scroll with its phases: "by" points, positive to the right
            // (back), over "over" seconds. "hold" leaves the fingers down,
            // for a look mid-gesture; "end" lifts them. Answers with the
            // pull as drawn and where the tab is. "peek": the page in the
            // peek over it instead; "drawn" says whether the tab's pill is
            // in a window and shown.
            guard Store.testing else { answer(["error": "pull only works on a --test run"]); return }
            let peek = request["peek"] as? Bool == true
            guard let tab = peek ? browser.peeking : browser.active, let web = tab.webKitOnly("WebKit-only bench fixtures", build: false) else {
                answer(["error": peek ? "no peek up" : "no page in front"])
                return
            }
            let hold = request["hold"] as? Bool ?? false
            let lift = request["end"] as? Bool ?? false
            let by = request["by"] as? Double ?? 0
            let over = request["over"] as? Double ?? 0.3
            let wait = lift ? 0.05 : over + 0.1
            Bench.pull(web, by: by, over: over, begin: !lift && !(request["more"] as? Bool ?? false), end: lift || !hold,
                       down: request["down"] as? Double ?? 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) {
                let pull = tab.pull
                answer([
                    "steps": pull?.steps ?? 0, "stop": pull?.stop.map { "\($0.kind)" } ?? "", "armed": pull?.armed ?? false,
                    "listed": pull?.listed ?? false,
                    "going": pull?.going ?? false, "travel": Double(pull?.travel ?? 0),
                    "stops": pull?.stops.map(\.title) ?? [], "url": tab.builtPage?.url?.absoluteString ?? "",
                    "drawn": tab.pullView.map { $0.owner === tab && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false,
                ])
            }

        case "stills":
            // The pages' last frames kept for switching (PageStills): how
            // many, how big, hits and misses by reason. "on" false shows
            // pages as before stills (an A/B in one build, a --test run
            // only); "forget" drops them all; "pressure" 2 or 4 acts as
            // memory short or out; "reset" zeroes the counts.
            if let on = request["on"] as? Bool {
                guard Store.testing else { answer(["error": "stills on/off only works on a --test run"]); return }
                PageStills.on = on
                if !on { PageStills.shared.forgetAll() }
            }
            if request["forget"] as? Bool == true { PageStills.shared.forgetAll() }
            if let level = request["pressure"] as? Int { PageStills.shared.relieve(critical: level >= 4) }
            if request["reset"] as? Bool == true { PageStills.shared.resetCounts() }
            answer(PageStills.shared.report)

        case "switchwatch":
            // A tab picked, and where its page is on screen every frame
            // after (the render server's, `presentation`), its stage's
            // frame and the page's, top edges in window points, y down:
            // a page that slides into place after a switch shows here
            // (evals/devmode/leave_dev.py).
            guard Store.testing else { answer(["error": "switchwatch only works on a --test run"]); return }
            guard let target = find(request, in: browser), let web = target.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); return }
            let seconds = request["seconds"] as? Double ?? 0.7
            var samples: [[Double]] = []
            let start = CACurrentMediaTime()
            func top(_ view: NSView?) -> [Double] {
                guard let view, let window = view.window else { return [-1, -1] }
                let rect = view.convert(view.bounds, to: nil)
                return [Double(window.contentLayoutRect.maxY - rect.maxY), Double(rect.height)]
            }
            // How far the page is drawn from where it is laid out: each
            // layer from the page up, its presentation against its model
            // (position and translation), summed; and every animation on
            // the way, by layer depth and key.
            var seen = Set<String>()
            func sample() {
                var dy = 0.0
                var at = web.layer
                var depth = 0
                while let layer = at, depth < 12 {
                    let p = layer.presentation() ?? layer
                    dy += Double(p.position.y - layer.position.y) + Double(p.transform.m42 - layer.transform.m42)
                    let kind = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
                    for key in layer.animationKeys() ?? [] { seen.insert("\(depth):\(kind):\(key)") }
                    at = layer.superlayer
                    depth += 1
                }
                samples.append([(CACurrentMediaTime() - start) * 1000] + top(web.superview) + top(web) + [dy])
            }
            sample()
            browser.select(target)
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                timer.invalidate()
                answer(["samples": samples, "fields": ["ms", "stageTop", "stageHeight", "pageTop", "pageHeight", "drawnOffY"], "animations": seen.sorted()])
            }

        case "stagetrace":
            // What the stage did since the last asking: each layout, hold
            // and carry, and ⌘S's and the chat column's changes and slides
            // (StageView.trace, evals/sidebar-motion/trace.py).
            let made = StageView.trace
            StageView.trace = []
            answer(["trace": made, "now": CACurrentMediaTime()])

        case "devframes":
            // The Developer Tools card and the page beside it this moment,
            // light enough to ask every frame: the card as laid out and as
            // drawn (its layer's presentation), the page's stage and page.
            // A --test run only.
            guard Store.testing, let window = BrowserWindows.shared.window(for: browser), let content = window.contentView else {
                answer(["error": "devframes only works on a --test run"]); return
            }
            let card = browser.devCard
            var out: [String: Any] = ["t": CACurrentMediaTime(), "open": browser.devOpen, "moving": browser.devMoving, "side": browser.devSide.rawValue,
                                      "card": [card.minX, card.minY, card.width, card.height].map(Double.init), "pane": DevKeyClaim.pane(in: window)]
            // The card's host as drawn now: how far its layer is from where
            // it is laid out (its layer's own units), and how opaque, up its
            // ancestry to the window, as a fade or a move on any of them shows.
            if let host = DevKeyClaim.shownHost(in: window) {
                var dx: CGFloat = 0, dy: CGFloat = 0, alpha: Float = 1
                var view: NSView? = host
                while let v = view, v !== content {
                    if let model = v.layer, let shown = model.presentation() {
                        dx += shown.position.x - model.position.x
                        dy += shown.position.y - model.position.y
                        alpha *= shown.opacity
                    }
                    view = v.superview
                }
                out["paneMoved"] = [Double(dx), Double(dy)]
                out["paneOpacity"] = Double(alpha)
            }
            if let stage = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false)?.superview as? StageView { out["stage"] = stage.benchGeometry() }
            answer(out)

        case "front":
            // The window made the key window of the active app, the way it
            // is when someone is using it, focus, the field's cursor and
            // everything else that only happens then. A --test run only: it
            // takes the screen's focus.
            guard Store.testing else { answer(["error": "front only works on a --test run"]); return }
            NSApp.activate(ignoringOtherApps: true)
            Links.window?.makeKeyAndOrderFront(nil)
            answer(["key": NSApp.keyWindow != nil])

        case "link":
            // An address as another app hands it over, Mail's click, to the
            // small window or the row as Settings has it. A --test run
            // only: the small window takes the screen's focus.
            guard Store.testing else { answer(["error": "link only works on a --test run"]); return }
            guard let text = request["url"] as? String else { answer(["error": "no url"]); return }
            // No address: ⌥⌘N's empty one, its field ready.
            if text.isEmpty {
                LinkWindow.blank()
            } else if let url = URL(string: text) {
                Links.take(url)
            }
            answer(["small": LinkWindow.all.count])

        case "settings-link":
            // A page Settings links to, Community's (#372), opened as
            // Settings opens it now ("yab": a tab of Yab's own), or as
            // 0.35.10 did ("workspace": Launch Services asked, on the main
            // thread and waited for, to open it with this app, the Mac's
            // browser when it is Yab). Answers how long the main thread
            // was held. A --test run only: it opens a page.
            guard Store.testing else { answer(["error": "settings-link only works on a --test run"]); return }
            let url = (request["url"] as? String).flatMap(URL.init(string:)) ?? Links.community
            let start = CACurrentMediaTime()
            if request["via"] as? String == "workspace" {
                // Held for the call: the spec carries them unretained.
                let app = Bundle.main.bundleURL as CFURL
                let items = [url as CFURL] as CFArray
                var spec = LSLaunchURLSpec(appURL: Unmanaged.passUnretained(app), itemURLs: Unmanaged.passUnretained(items),
                                           passThruParams: nil, launchFlags: [], asyncRefCon: nil)
                let status = withExtendedLifetime((app, items)) { LSOpenFromURLSpec(&spec, nil) }
                answer(["held_ms": (CACurrentMediaTime() - start) * 1000, "status": Int(status), "small": LinkWindow.all.count])
            } else {
                Links.openFromSettings(url)
                answer(["held_ms": (CACurrentMediaTime() - start) * 1000, "tabs": browser.tabs.count, "small": LinkWindow.all.count])
            }

        case "link-routes", "tab-menu":
            depWishesCommand(verb, request, browser: browser, answer)

        case "page-menu":
            pageMenuCommand(request, browser: browser, answer)

        case "anchor-menu":
            anchorMenuCommand(request, answer)

        case "folder-menu":
            folderMenuCommand(request, browser: browser, answer)

        case "shelf-menu":
            shelfMenuCommand(request, browser: browser, answer)

        case "link-find":
            // ⌘F's bar on a small window's page with these words in it, as
            // `pointer`'s find does for a tab: typed keys need the app in front.
            guard Store.testing else { answer(["error": "link-find only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let link = LinkWindow.all.first(where: { $0.tab === tab }) else { answer(missing(request)); return }
            if !tab.finder.shown { tab.finder.open() }
            tab.finder.needle = request["needle"] as? String ?? ""
            answer(["responder": link.window.firstResponder.map { String(describing: type(of: $0)) } ?? "", "key": link.window.isKeyWindow, "active": NSApp.isActive])

        case "links", "link-keep", "link-close":
            // The small windows up for links, newest last, with the page
            // each shows; keep or close the newest. link-keep's "space",
            // an index into the spaces, keeps it there as its menu does.
            if verb != "links" {
                guard Store.testing else { answer(["error": "\(verb) only works on a --test run"]); return }
                guard let last = LinkWindow.all.last else { answer(["error": "no small window"]); return }
                if verb == "link-keep" {
                    if let index = request["space"] as? Int {
                        guard browser.spaces.indices.contains(index) else { answer(["error": "no space \(index)"]); return }
                        last.keep(into: browser.spaces[index].id)
                    } else if let via = request["via"] as? String {
                        // Full screen asked of it, which keeps it (#1099):
                        // its green light pressed, the View menu's action,
                        // or ⌃⌘F as its window hears it.
                        last.window.makeKeyAndOrderFront(nil)
                        switch via {
                        case "button":
                            guard let green = LightsRow.zoomButton(in: last.window) else { answer(["error": "no green light"]); return }
                            green.performClick(nil)
                        case "menu":
                            NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: last.window, from: nil)
                        case "key":
                            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: last.window.windowNumber,
                                                             context: nil, characters: "\u{6}", charactersIgnoringModifiers: "f",
                                                             isARepeat: false, keyCode: 3) else { answer(["error": "no key"]); return }
                            _ = last.take(key)
                        default: answer(["error": "via is button, menu or key"]); return
                        }
                    } else {
                        last.keep()
                    }
                } else {
                    last.close()
                }
            }
            answer(["windows": LinkWindow.all.map { link -> [String: Any] in
                let frame = link.window.frame
                return [
                    "id": link.tab.id.uuidString, "url": link.tab.address?.absoluteString ?? "", "number": link.window.windowNumber,
                    "key": link.window.isKeyWindow, "visible": link.window.isVisible, "space": link.window.isOnActiveSpace, "alpha": link.window.alphaValue, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    // ⌘F's bar on its page, and ⌘P's sheet over it.
                    "find": ["shown": link.tab.finder.shown, "needle": link.tab.finder.needle, "total": link.tab.finder.total, "index": link.tab.finder.index],
                    "sheet": link.window.attachedSheet != nil,
                    // The browser's field raised over it, its corner saying
                    // a copy, and its list of spaces up (with the list's
                    // own window, for a picture).
                    "field": browser.fieldGuest === link.tab, "typed": browser.fieldGuest === link.tab ? browser.typed : "",
                    "notice": link.noticeShown,
                    "list": NSApp.windows.first { $0 is DropPanel && $0.isVisible && $0.parent === link.window }?.windowNumber ?? 0,
                ]
            }, "extensionWindows": ChromiumExtensionWindow.open.map { made -> [String: Any] in
                // An extension's own window on a Chromium tab (windows.create).
                let frame = made.window.frame
                return ["id": made.tab.id.uuidString, "url": made.tab.address?.absoluteString ?? "", "number": made.window.windowNumber,
                        "key": made.window.isKeyWindow, "visible": made.window.isVisible, "title": made.window.title,
                        "frame": [frame.minX, frame.minY, frame.width, frame.height],
                        // Under its pin (ExtensionWindowFrame).
                        "extension": made.shown.owner.id, "hung": made.shown.underPin != nil,
                        "pin": made.shown.underPin.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                        "header": made.shown.owner.name,
                        "lit": ExtensionWindowFrame.Hung.shared.ids.contains(made.shown.owner.id),
                        // The pins for it now, wherever they are, and what the tab in front pins.
                        "census": AnchorView.census(made.shown.owner.id) + ChromiumPopupAnchor.View.census(made.shown.owner.id),
                        "pinnedHere": browser.active.map { ChromiumColumn.shared.pinnedIDs(for: $0) } ?? [],
                        "pinNow": (BrowserWindows.shared.window(for: browser).flatMap { ExtensionWindowFrame.pin(made.shown.owner.id, in: $0) })
                            .map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []]
            }, "row": browser.tabs.count, "active": browser.active?.address?.absoluteString ?? "",
               "browserWindow": Links.window?.isVisible ?? false, "browserKey": Links.window?.isKeyWindow ?? false,
               "fullScreen": NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }, "browserSheet": Links.window?.attachedSheet != nil, "spaceName": browser.space.name,
               // Whether its key is heard from every app: heard, off, taken.
               "hotkey": "\(LinkWindow.globalKey.state)", "smallKey": browser.prefs.smallKey])

        case "startup":
            // This launch's moments, in ms from the process starting: main,
            // launched, window (the first frame sent to the window server),
            // shown (the window server saying it is on screen), page (the
            // first page loaded).
            answer(Startup.report)

        case "icons":
            // The sites' icons held in memory and kept on disk; "touch":
            // that many kept ones asked for and drawn first.
            answer(Favicons.shared.census(touch: request["touch"] as? Int ?? 0))

        case "stall":
            // The main thread held on purpose, for the watchdog to see
            // (Watchdog, stalls.log). A --test run only.
            guard Store.testing else { answer(["error": "stall only works on a --test run"]); return }
            let seconds = min(request["seconds"] as? Double ?? 1.5, 10)
            Hangs.phase("bench stall")
            Thread.sleep(forTimeInterval: seconds)
            answer(["held_s": seconds, "log": Watchdog.recent(2048) ?? ""])

        case "budget":
            // The main thread's run loop passes and named data and IO chunks
            // since the last read (MainBudget, evals/perf/budget.py); "reset"
            // starts counting again. A run launched with YAB_BUDGET=1 only.
            guard MainBudget.enabled else { answer(["error": "budget needs a --test run launched with YAB_BUDGET=1"]); return }
            MainBudget.start()
            answer(MainBudget.read(reset: request["reset"] as? Bool ?? false))

        case "cputhreads":
            // Seconds on a core so far of each live thread of this process,
            // summed by thread name ("main" for the main thread): where an
            // eval's CPU went where `sample` cannot attach (evals/scroll-ram).
            // A thread that ended took its time with it. A --test run only.
            guard Store.testing else { answer(["error": "cputhreads only works on a --test run"]); return }
            answer(["threads": Bench.threadTimes()])

        case "mainsample":
            // The main thread's stacks every 2 ms while it is on a core,
            // counted by frame: "start" begins again, a plain ask stops and
            // answers. What `sample` would say where it cannot attach
            // (evals/scroll-ram). A --test run only.
            guard Store.testing else { answer(["error": "mainsample only works on a --test run"]); return }
            if request["start"] as? Bool == true {
                MainSampler.shared.start()
                answer(["started": true])
            } else {
                answer(MainSampler.shared.stop())
            }

        case "hangs":
            // The main-thread watchdog, started if it is not already, and what
            // it has seen so far. Only on a run launched with YAB_HANGS=1.
            guard Hangs.enabled else { answer(["error": "hangs needs a --test run launched with YAB_HANGS=1"]); return }
            Hangs.start()
            answer(["report": Hangs.report()])

        case "layout-census":
            // Which views are told they need layout, or an update of their
            // constraints, and how often, between "on" and the next ask:
            // what makes the window lay itself out on a frame where nothing
            // of it should change. A --test run only.
            guard Store.testing else { answer(["error": "layout-census only works on a --test run"]); return }
            if request["on"] as? Bool == true {
                LayoutCensus.start()
                answer(["on": true])
            } else {
                answer(LayoutCensus.stop())
            }

        case "layer-audit":
            // What the window's layers cost to draw: masks and filters are
            // an offscreen pass each, a shadow without a path one per frame
            // it moves. Counted over the window's whole tree, with the
            // classes of the layers that carry them.
            guard let root = Links.window?.contentView?.layer else { answer(["error": "no window"]); return }
            var count = 0, masks: [String: Int] = [:], filters: [String: Int] = [:], shadows: [String: Int] = [:], animating = 0, shadowKinds: [String: Int] = [:]
            var drawn: [String: [String: Int]] = [:], big: [String] = [], moving: [String] = []
            func walk(_ layer: CALayer) {
                count += 1
                let name = "\(type(of: layer))"
                if layer.mask != nil { masks[name, default: 0] += 1 }
                if let f = layer.filters, !f.isEmpty { filters["\(name):\(f.map { "\($0)" }.joined(separator: ","))".prefix(120).description, default: 0] += 1 }
                if layer.backgroundFilters?.isEmpty == false { filters["\(name):background", default: 0] += 1 }
                if layer.shadowOpacity > 0, layer.shadowPath == nil {
                    shadows[name, default: 0] += 1
                    // What kind of shadow: one of no radius in a clear
                    // color draws nothing, but may still be worked out.
                    let alpha = layer.shadowColor?.alpha ?? 0
                    let kind = "\(name) r\(Int(layer.shadowRadius)) o\((Double(layer.shadowOpacity) * 100).rounded() / 100) a\((Double(alpha) * 100).rounded() / 100) v\(layer.delegate.map { "\(type(of: $0))" } ?? "-") in \(layer.superlayer?.delegate.map { "\(type(of: $0))" } ?? "-")"
                    shadowKinds[kind, default: 0] += 1
                }
                if let keys = layer.animationKeys(), !keys.isEmpty {
                    animating += 1
                    // Which: whose layer, how big, what moves on it. The
                    // page's own animations run here too, in the layers
                    // WebKit hosts for it.
                    if moving.count < 40 {
                        let size = layer.bounds.size
                        let owner = layer.delegate.map { "\(type(of: $0))" } ?? layer.superlayer?.delegate.map { "in \(type(of: $0))" } ?? "-"
                        moving.append("\(name) \(owner) \(Int(size.width))x\(Int(size.height)) \(keys.joined(separator: ",").prefix(80))")
                    }
                }
                // What the CPU paints: SwiftUI's CGDrawingLayers are drawn
                // on the main thread, again on every frame their content
                // animates, and wait for the render server to hand back a
                // buffer first.
                if name.contains("Drawing") {
                    let size = layer.bounds.size
                    drawn[name, default: [:]]["count", default: 0] += 1
                    drawn[name, default: [:]]["points", default: 0] += Int(size.width * size.height)
                    if size.width * size.height > 20_000 { big.append("\(name) \(Int(size.width))x\(Int(size.height)) @\(Int(layer.convert(CGPoint.zero, to: root).x)),\(Int(layer.convert(CGPoint.zero, to: root).y))") }
                }
                layer.sublayers?.forEach(walk)
                if let m = layer.mask { walk(m) }
            }
            walk(root)
            answer(["layers": count, "masks": masks, "filters": filters, "shadows_without_path": shadows, "shadow_kinds": shadowKinds, "animating": animating, "moving": moving, "drawn": drawn, "drawn_big": big]); return

        case "pace":
            // ⇧⌘S, timed frame by frame: a display link on the main thread
            // notes when each frame came, so a stall shows up as a gap, and
            // the stage counts how often the page was made another size,
            // each one a layout of the whole page in WebKit. A --test run
            // only: it changes where the tabs are.
            guard Store.testing else { answer(["error": "pace only works on a --test run"]); return }
            guard let view = Links.window?.contentView else { answer(["error": "no window"]); return }
            let seconds = request["seconds"] as? Double ?? 0.8
            guard seconds.isFinite, seconds > 0, seconds <= 60 else {
                answer(["error": "pace seconds must be finite and in (0, 60]"]); return
            }
            let pacer = Pacer()
            // "screen": the display's own link, which ticks for a window
            // kept off every screen, where the window's never does.
            // A probe in the background has no key window, and so no main screen: the first one.
            let link = (request["screen"] as? Bool == true ? (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: pacer, selector: #selector(Pacer.tick(_:))) : nil)
                ?? view.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
            link.add(to: .main, forMode: .common)
            // Start the action on an established display clock. Creating a
            // display link can itself take a frame; that is measurement
            // setup, not time spent opening the field.
            pacer.ready = { [self] in
            StageView.resizes = 0
            StageView.steps = []
            StageView.layouts = 0
            Reshape.runs = 0
            ChatFeed.bodies = 0
            SwitchMeter.on = true
            ChatColumnView.layouts = 0
            ChatColumnView.built = 0
            ColumnPages.syncs = 0
            ColumnPages.laidSyncs = 0
            ColumnCell.resized = 0
            SplitDeck.Meter.reset()
            // The page of the tab in front, or the one out in the floating
            // window: each new size it is given is a layout of the whole
            // page, wherever it is, the stage or the window.
            let paged = (browser.floating.flatMap { id in browser.everyTab.first { $0.id == id } } ?? browser.active)?.webKitOnly("WebKit-only bench fixtures", build: false)
            var pageSizes = 0
            var pageSize = paged?.frame.size
            paged?.postsFrameChangedNotifications = true
            let sizing = paged.map { page in
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: page, queue: nil) { _ in
                    if page.frame.size != pageSize { pageSizes += 1; pageSize = page.frame.size }
                }
            }
            let instructions0 = Bench.instructions()
            let cpu0 = Bench.mainCPU()
            let process0 = Bench.processCPU()
            let t0 = CACurrentMediaTime()
            StripRenderMeter.reset()
            let latency = PaceLatency()
            latency.start()
            var spun: Spin?
            let fieldCreations = AddressField.creations
            let fieldPresentations = Omnibox.presentations
            var typedAt: [Double] = []
            var keyCost: [Double] = []
            var typedHeights: [CGFloat] = []
            var typingCount = 0
            var typingTimer: Timer?
            // ⇧⌘S, or ⇧⌘B with "shelf", or ⌘S with "column".
            switch request["action"] as? String {
            case "idle": break
            case "glyph-toggle": browser.prefs.glyph = browser.prefs.glyph == .icons ? .letters : .icons
            case "glass-offer":
                guard let tab = browser.active, tab.address != nil else {
                    answer(["error": "glass-offer needs an active page"]); link.invalidate(); return
                }
                Hints.shared.extra[tab.id] = Hints.cancelling
                Hints.shared.offered[tab.id] = tab.address!.absoluteString
            case "glass-unoffer":
                guard let tab = browser.active else {
                    answer(["error": "glass-unoffer needs an active page"]); link.invalidate(); return
                }
                Hints.shared.unoffer(tab.id)
            case "box-open":
                guard !browser.fieldShowing else { answer(["error": "box is already showing"]); link.invalidate(); return }
                browser.edit()
            case "file-open":
                guard !browser.fieldShowing, let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false),
                      let selector = request["selector"] as? String,
                      let data = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed),
                      let quoted = String(data: data, encoding: .utf8) else {
                    answer(["error": "file-open needs a page and a button selector"]); link.invalidate(); return
                }
                web.evaluateJavaScript("document.querySelector(\(quoted))?.click()") { _, _ in }
            case "box-fresh":
                guard !browser.fieldShowing else { answer(["error": "box is already showing"]); link.invalidate(); return }
                browser.newTab()
            case "box-history":
                guard !browser.fieldShowing else { answer(["error": "box is already showing"]); link.invalidate(); return }
                browser.openPlace(.history)
            case "box-clipboard":
                guard !browser.fieldShowing else { answer(["error": "box is already showing"]); link.invalidate(); return }
                browser.openPlace(.clipboard)
            case "box-close": browser.close()
            case "box-type":
                guard let editor = Links.window?.firstResponder as? NSTextView,
                      editor.isFieldEditor else {
                    answer(["error": "box-type needs a focused omnibox field"])
                    link.invalidate()
                    return
                }
                let letters = Array((request["text"] as? String ?? "").prefix(80))
                let interval = max(0.005, min(request["interval"] as? Double ?? 0.016, 0.1))
                if !letters.isEmpty {
                    let timer = Timer(timeInterval: interval, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            guard typingCount < letters.count else { timer.invalidate(); return }
                            let started = CACurrentMediaTime()
                            let letter = letters[typingCount]
                            if letter == "\u{7f}" { editor.deleteBackward(nil) }
                            else { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
                            keyCost.append((CACurrentMediaTime() - started) * 1000)
                            typedAt.append((started - t0) * 1000)
                            typedHeights.append(Omnibox.card.height)
                            typingCount += 1
                            if typingCount == letters.count { timer.invalidate() }
                        }
                    }
                    typingTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
            // The same letters as key events put in the app's queue, the
            // way the keyboard's come: through the window's key monitor, the
            // main menu's key equivalents and the field editor's keyDown.
            // Each key's cost is from its posting to the field's text
            // changing (NSText.didChangeNotification) for it.
            case "box-post":
                guard let editor = Links.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                      let window = editor.window else {
                    answer(["error": "box-post needs a focused omnibox field"])
                    link.invalidate()
                    return
                }
                let letters = Array((request["text"] as? String ?? "").prefix(80))
                let interval = max(0.005, min(request["interval"] as? Double ?? 0.016, 0.5))
                var posted: [CFTimeInterval] = []
                var changes = 0
                let changing = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: editor, queue: nil) { _ in
                    MainActor.assumeIsolated {
                        guard changes < posted.count else { return }
                        keyCost.append((CACurrentMediaTime() - posted[changes]) * 1000)
                        typedHeights.append(Omnibox.card.height)
                        changes += 1
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NotificationCenter.default.removeObserver(changing) }
                if !letters.isEmpty {
                    let timer = Timer(timeInterval: interval, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            guard typingCount < letters.count else { timer.invalidate(); return }
                            let started = CACurrentMediaTime()
                            let chars = String(letters[typingCount])
                            for type in [NSEvent.EventType.keyDown, .keyUp] {
                                guard let event = NSEvent.keyEvent(
                                    with: type, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: Bench.keyCode(for: letters[typingCount])
                                ) else { continue }
                                NSApp.postEvent(event, atStart: false)
                            }
                            posted.append(started)
                            typedAt.append((started - t0) * 1000)
                            typingCount += 1
                            if typingCount == letters.count { timer.invalidate() }
                        }
                    }
                    typingTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
            // Letters typed into the page in front, as key events handed to
            // its view one every `interval` seconds, the way a hand types
            // into a site's composer (the page focuses its box first, by an
            // eval). What the window and the page do for each key.
            case "page-type":
                guard let page = browser.active?.page, let window = page.window else {
                    answer(["error": "page-type needs a page in front"])
                    link.invalidate()
                    return
                }
                window.makeFirstResponder(page)
                let letters = Array((request["text"] as? String ?? "").prefix(200))
                let interval = max(0.02, min(request["interval"] as? Double ?? 0.08, 0.5))
                if !letters.isEmpty {
                    let timer = Timer(timeInterval: interval, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            guard typingCount < letters.count else { timer.invalidate(); return }
                            let started = CACurrentMediaTime()
                            let chars = String(letters[typingCount])
                            for type in [NSEvent.EventType.keyDown, .keyUp] {
                                guard let event = NSEvent.keyEvent(
                                    with: type, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: Bench.keyCode(for: letters[typingCount])
                                ) else { continue }
                                if type == .keyDown { page.keyDown(with: event) } else { page.keyUp(with: event) }
                            }
                            keyCost.append((CACurrentMediaTime() - started) * 1000)
                            typedAt.append((started - t0) * 1000)
                            typingCount += 1
                            if typingCount == letters.count { timer.invalidate() }
                        }
                    }
                    typingTimer = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
            // Two tabs side by side (Split.swift): the tab in front and the
            // one named coming together, the pair coming apart, the divider
            // dragged by posted mouse events, double-clicked, a click from
            // one half to the other, one half closed.
            case "split-enter":
                guard let other = target, let current = browser.active else { answer(missing(request)); link.invalidate(); return }
                browser.split(other, with: current)
            case "split-separate": browser.separate()
            case "split-equal": browser.equalizeSplit()
            case "split-focus":
                if let pair = browser.stagePair, let id = browser.activeID,
                   let other = browser.tabs.first(where: { $0.id == pair.other(than: id) }) { browser.focus(other) }
            // ⌘⇧C's "Link copied", the corner's notice in and out.
            case "copy": browser.copyAddress()
            // The playing video out into Yab's floating window, or back.
            case "float": browser.toggleFloat(own: true)
            // A tab picked, the most frequent thing the window does.
            case "select":
                guard let tab = target else { answer(missing(request)); link.invalidate(); return }
                SwitchMarks.start(tab.id)
                browser.select(tab)
            case "split-close":
                if let tab = browser.active { browser.close(tab) }
            // ⌘W on the tab in front (Browser.CloseMarks says when the
            // next page was on screen).
            case "close":
                if let tab = browser.active { browser.close(tab) }
            // The chat column's edge dragged as its grip drags it
            // (ChatColumn): its width set every frame while sizing.
            case "chat-drag":
                guard browser.chatOpen else { answer(["error": "chat-drag needs the chat column out"]); link.invalidate(); return }
                let by = request["by"] as? Double ?? -200, over = request["over"] as? Double ?? 0.8
                let start = browser.chatWidth, steps = max(1, Int(over * 60))
                browser.chatSizing = true
                for step in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) {
                        browser.chatWidth = ChatLook.fit(min(ChatLook.most, (start + by * Double(step) / Double(steps)).rounded()))
                        if step == steps { browser.settleChatWidth() }
                    }
                }
            case "split-drag":
                guard !Bench.dragDivider(browser, by: request["by"] as? Double ?? -240, over: request["over"] as? Double ?? 0.8, hold: request["hold"] as? Bool ?? false) else { break }
                answer(["error": "no divider on screen"]); link.invalidate(); return
            // A tab carried out over the pages (SplitDeck), as the column's
            // or the row's drag drives it: taken out at the top of the
            // pages, carried to `to` of the way across a frame at a time, and
            // let go, or Esc'd, or with `hold` kept in the hand until
            // split-deck-end. No gesture: posted events never reach
            // SwiftUI's. `deck_move_ms` is the main thread's time a move.
            case "split-deck":
                guard let tab = target else { answer(missing(request)); link.invalidate(); return }
                let room = browser.splitBook.place
                let share = request["to"] as? Double ?? 0.85
                let over = request["over"] as? Double ?? 0.8
                let esc = request["esc"] as? Bool ?? false
                let hold = request["hold"] as? Bool ?? false
                // From the tab's own row, just past its end, as a hand
                // takes it out.
                let row = browser.keySky.place(tab.id)
                let start = row.map { CGPoint(x: min($0.maxX + 12, room.minX + 20), y: $0.midY) } ?? CGPoint(x: room.midX, y: room.minY + 10)
                let end = CGPoint(x: room.minX + room.width * share, y: room.midY)
                guard SplitDeck.shared.begin(tab, in: browser, at: start) else {
                    answer(["error": "nowhere to drop"]); link.invalidate(); return
                }
                // The page in front's own width as it lays itself out, from
                // inside it, every 40 ms for two seconds: room made beside
                // it reaches the page before the tab is let go.
                Bench.deckWidths = []
                Bench.deckPage = browser.active?.builtPage.map(ObjectIdentifier.init)
                let page = browser.active?.builtPage
                let begun = CACurrentMediaTime()
                let sampler = Timer(timeInterval: 0.04, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let ms = ((CACurrentMediaTime() - begun) * 1000).rounded()
                        guard ms < 2000, let page else { timer.invalidate(); return }
                        page.run("innerWidth") { result in
                            let value = try? result.get()
                            MainActor.assumeIsolated {
                                Bench.deckWidths.append([ms, (value as? Double) ?? -1, SplitDeck.shared.active ? 1 : 0])
                            }
                        }
                    }
                }
                RunLoop.main.add(sampler, forMode: .common)
                // The way the hand goes: through each fraction of the room's
                // width in `path` (or straight to `to`), `over` seconds a
                // leg; then, with `jitter`, trembling that many points either
                // side of where it stopped for half a second; then let go,
                // Esc'd, brought back over the list (`leave`) or held.
                let marks = (request["path"] as? [Double]) ?? [share]
                let points = [start] + marks.map { CGPoint(x: room.minX + room.width * $0, y: room.midY) }
                let leg = max(2, Int(over * 60))
                var moves: [CGPoint] = []
                for index in 1..<points.count {
                    let a = points[index - 1], b = points[index]
                    for step in 1...leg {
                        let t = Double(step) / Double(leg)
                        moves.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    }
                }
                if let jitter = request["jitter"] as? Double, let last = moves.last {
                    for step in 0..<30 { moves.append(CGPoint(x: last.x + (step % 2 == 0 ? jitter : -jitter), y: last.y)) }
                }
                let leave = request["leave"] as? Bool ?? false
                Bench.roomMoves = browser.splitRoomMoves
                var spent = 0.0
                for (index, point) in moves.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index + 1) / 60) {
                        let c0 = Bench.mainCPU()
                        SplitDeck.shared.move(to: point)
                        spent += Bench.mainCPU() - c0
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(moves.count + 1) / 60) {
                    Bench.deckMoves = (spent / Double(max(1, moves.count)) * 1000).rounded() / 1000
                    Bench.roomMoves = browser.splitRoomMoves - Bench.roomMoves
                    guard !hold else { return }
                    if leave { SplitDeck.shared.leave(); return }
                    if esc { SplitDeck.shared.cancelNow() }
                    if let drop = SplitDeck.shared.end() { browser.dropSplit(tab, drop) }
                }
            case "split-release":
                Bench.release?()
                Bench.release = nil
            case "split-deck-end":
                if let tab = SplitDeck.shared.tab, let drop = SplitDeck.shared.end() { browser.dropSplit(tab, drop) }
            // The next space, as ⌃N or a swipe does; "still" without the
            // turn's motion, to weigh what it costs.
            case "space-step":
                SpaceTurn.still = request["still"] as? Bool ?? false
                Bench.trackPager(for: seconds)
                browser.stepSpace(request["by"] as? Int ?? 1)
                // A second key while the first still lands ("then" spaces
                // "after" seconds later), as a person pressing twice.
                if let then = request["then"] as? Int {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (request["after"] as? Double ?? 0.1)) {
                        MainActor.assumeIsolated { browser.stepSpace(then) }
                    }
                }
            // A space by its name ("name"), as its dot in the foot does.
            case "space-to":
                SpaceTurn.still = request["still"] as? Bool ?? false
                Bench.trackPager(for: seconds)
                if let space = browser.spaces.first(where: { $0.name.lowercased() == (request["name"] as? String ?? "").lowercased() }) {
                    browser.switchSpace(to: space.id)
                }
            // Two fingers sideways over the column's foot (Bench.swipe);
            // "rows" over its rows, "pane" over the page or mail's pane.
            case "space-swipe":
                SpaceTurn.still = request["still"] as? Bool ?? false
                Bench.trackPager(for: seconds)
                Bench.swipe(by: request["by"] as? Double ?? -160, over: request["over"] as? Double ?? 0.35, hold: request["hold"] as? Double ?? 0,
                            rows: request["rows"] as? Bool ?? false, pane: request["pane"] as? Bool ?? false)
            // The spaces' tray: "tray" with "act" spaces (open or away),
            // leave, new, forward, pick (and "value", a space's name), or
            // a step's name to go to.
            case "tray":
                let value = request["value"] as? String ?? ""
                SpaceTray.focusing = request["focus"] as? Bool ?? true
                switch request["act"] as? String ?? "spaces" {
                case "spaces": SpaceTray.openSpaces(browser)
                case "open": SpaceTray.open(browser)
                case "leave": SpaceTray.shown?.leave()
                case "new": SpaceTray.shown?.startNew()
                case "forward": SpaceTray.shown?.forward()
                case "pick":
                    if let space = browser.spaces.first(where: { $0.name.lowercased() == value.lowercased() }) { SpaceTray.shown?.pick(space.id) }
                case let step:
                    if let step = ["spaces": SpaceDraft.Step.spaces, "start": .start, "name": .name, "emoji": .emoji, "color": .color, "signins": .signIns][step] {
                        SpaceTray.shown?.go(step)
                    }
                }
            // Two fingers sideways over the page in front and let go: "by"
            // points (300, positive back), over "over" seconds (0.5).
            case "pull":
                guard let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); link.invalidate(); return }
                Bench.pull(web, by: request["by"] as? Double ?? 300, over: request["over"] as? Double ?? 0.5, begin: true,
                           end: !(request["hold"] as? Bool ?? false))
            // ⌘J (AgentTask.swift, ChatColumn.swift): the line coming up
            // on the page, what it holds carried into a chat in the column,
            // a chat about the page opened straight there, the column put
            // away, and a field's answer flown into it (Open in Chat).
            case "chat-line":
                guard let tab = browser.active else { answer(missing(request)); link.invalidate(); return }
                browser.prefs.askOpens = .line
                TaskLine.shared.open(on: tab)
            case "chat-carry":
                guard let tab = browser.active else { answer(missing(request)); link.invalidate(); return }
                TaskLine.shared.toChat(on: tab)
            case "chat-ask":
                guard let tab = browser.active else { answer(missing(request)); link.invalidate(); return }
                browser.askInChat(about: tab)
            // What goes with the words, as + and a paste put it there: a
            // file ("path"), words off the page ("quote"), every other tab
            // ("tabs"); "words" in the field, "type" to key them in, "clear" for none of it, "open" the column first, "send".
            case "chat-attach":
                let attach = browser.chatAttach
                if request["open"] as? Bool == true { browser.moveChat(open: true) }
                if request["clear"] as? Bool == true { attach.clear(for: browser.chatID) }
                if let path = request["path"] as? String { attach.add(.file(URL(fileURLWithPath: path)), chat: nil, browser: browser) }
                if let quote = request["quote"] as? String { attach.add(.quote(quote), chat: nil, browser: browser) }
                if request["tabs"] as? Bool == true {
                    for tab in browser.tabs where tab.id != browser.active?.id { attach.add(.tab(tab.id), chat: nil, browser: browser) }
                }
                if let words = request["words"] as? String { browser.chatDraft = words }
                // Typed where the cursor is, as keys are, not set whole.
                if let typed = request["type"] as? String {
                    (Links.window?.firstResponder as? NSTextView)?.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                // What is there goes as a new chat, with no words.
                if request["send"] as? Bool == true {
                    let items = attach.current(chat: nil, browser: browser)
                    attach.clear(for: nil)
                    ChatComposer.begin("", with: items, in: browser)
                }
            case "chat-hide": browser.moveChat(open: false)
            case "chat-expand": browser.expandAnswer()
            // The chat column's list and a chat out of its card
            // (ChatZoom): to the list, a card picked ("id"), as a click
            // with no press first does.
            case "chat-list": browser.chatHistory = true
            case "chat-pick":
                guard let id = request["id"] as? String else { answer(missing(request)); link.invalidate(); return }
                browser.keepChat(id)
            // A card held "hold" seconds and let go of, as a click on it is.
            case "chat-press":
                guard let id = request["id"] as? String else { answer(missing(request)); link.invalidate(); return }
                ChatZoom.press(id, down: true, in: browser)
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["hold"] as? Double ?? 0.12)) {
                    browser.keepChat(id)
                    ChatZoom.press(id, down: false, in: browser)
                }
            // Mail's screens changing (MailMorph): the row opened into its
            // letter, back into it, the next, one done, a reply sent, a new
            // mail out of the pen and back, another list.
            // Into mail's space and out, as ⇧⌘I goes (MailSpace).
            case "mail-enter": browser.enterMail()
            case "mail-leave": browser.leaveMail()
            case "mail-open": if let row = MailDesk.shared.chosen { MailDesk.shared.show(row) }
            case "mail-back": MailDesk.shared.back()
            case "mail-next": MailDesk.shared.step(request["by"] as? Int ?? 1)
            case "mail-done": MailDesk.shared.done()
            case "mail-send": MailDesk.shared.send()
            case "mail-compose": MailDesk.shared.compose()
            case "mail-close": MailDesk.shared.closeDraft()
            case "mail-list": MailList.shared.split = request["value"] as? String ?? "waiting"
            case "mail-undo": MailDesk.shared.undoLast()
            case "mail-scroll":
                // Two fingers down the list and back, as a trackpad sends them.
                if let web = browser.mailPageTab?.page {
                    Bench.pull(web, by: 0, over: request["over"] as? Double ?? 0.7, begin: true, end: true, down: request["down"] as? Double ?? -600)
                }
            case "shelf": browser.toggleBookmarkBar()
            case "column": browser.toggleColumn()
            // ⌘, and the window closed again (feedback #120: "going to
            // settings ... quite slow").
            case "settings-open": browser.tuning = true
            case "settings-close": browser.tuning = false
            // Every menu of the menu bar brought up to date as opening it
            // does, one after another, as a pointer run along the bar.
            case "menus":
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
                for item in NSApp.mainMenu?.items ?? [] {
                    guard let menu = item.submenu else { continue }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.delegate?.menuWillOpen?(menu)
                    menu.update()
                    menu.delegate?.menuDidClose?(menu)
                }
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu)
            // The band with the lights beside a column on the right
            // (HeadBand), out and back in as the window's top edge has it.
            case "head-out": browser.moveHead(out: true)
            case "head-in": browser.moveHead(out: false)
            // The put-away strip out over the page, as the pointer at the
            // window's top edge brings it, and back up past it.
            case "strip-out", "strip-in":
                guard browser.stripAway else {
                    answer(["error": "the strip is not put away"]); link.invalidate(); return
                }
                Brim.bringStrip(browser, out: request["action"] as? String == "strip-out")
            // The put-away column out over the page as a card, as the
            // pointer at the window's edge brings it, and back past it.
            case "side-out", "side-in":
                guard browser.prefs.sidebar, browser.prefs.sideShut else {
                    answer(["error": "the column is not put away"]); link.invalidate(); return
                }
                ColumnView.slid = nil
                Brim.bring(browser, out: request["action"] as? String == "side-out")
            // Clear on the line: today's tabs to dust, or gone as they
            // were when there is no dust to be had (Dust.swift).
            case "tidy": browser.tidyNow()
            // A local page's sheet in or away, or over to its other side.
            case "dev-open": browser.toggleDevSheet()
            // ⇧⌘2 (Capture.swift): each beat of it, timed like any other.
            case "capture-start": browser.capture.start()
            case "capture-box": browser.capture.take(.box)
            case "capture-visible": browser.capture.take(.visible)
            case "capture-whole": browser.capture.take(.whole)
            case "capture-edit": browser.capture.edit()
            case "capture-back": browser.capture.back()
            case "capture-shape": browser.capture.benchStyle { $0.shape = $0.shape == .auto ? .wide : .auto }
            case "capture-save": browser.capture.save()
            case "capture-close": browser.capture.close()
            case "dev-side": browser.setDevSide(browser.prefs.devSide == .bottom ? .right : browser.prefs.devSide == .right ? .left : .bottom)
            // The card away from any pane, WebKit's too, as its × does.
            case "dev-close": browser.closeDevTools()
            // A link peeked from the tab in front (LinkPeek), its tab's mark
            // coming with it, and put away again.
            case "peek":
                guard let tab = browser.active, let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                    answer(missing(request)); link.invalidate(); return
                }
                if let from = request["from"] as? String, let web = tab.builtPage {
                    PeekOrigin.mark(from, in: web) { browser.peek(url, from: tab) }
                } else {
                    browser.peek(url, from: tab)
                }
            case "peek-close": browser.closePeek()
            case "peek-reverse":
                guard let tab = browser.active, let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                    answer(missing(request)); link.invalidate(); return
                }
                browser.peek(url, from: tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { browser.closePeek() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { browser.peek(url, from: tab) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { browser.closePeek() }
            // Only what picking another tab does to the peek, and back.
            case "peek-hide": browser.hidePeek()
            case "peek-show": browser.followPeek()
            // An agent's task folder opened or shut.
            case "folder":
                if let name = request["folder"] as? String,
                   let nest = browser.nests.first(where: { $0.name == name }) {
                    Folders.shared.toggle(nest.key)
                } else if let id = request["folder"] as? String,
                          let folder = Folders.shared.folders.first(where: { $0.id == id }) {
                    Folders.shared.toggle(folder.id)
                } else if let folder = Folders.shared.folders.first {
                    Folders.shared.toggle(folder.id)
                }
            // A tab out of sight starting to play, as WebKit would say it,
            // never heard before: its notes, 0.6 s on (Chorus).
            case "sing":
                guard let tab = target else { answer(missing(request)); link.invalidate(); return }
                browser.chorus.forget(tab.id)
                tab.noisy = false
                tab.noisy = true
            // A tab's page loaded again: the ring comes on the tab and goes
            // at the first paint, as with any link followed.
            case "reload":
                guard let tab = target else { answer(missing(request)); link.invalidate(); return }
                tab.reload()
            // Nothing: what the window costs at rest.
            // Cards and addresses (WalletKeep): the list dropping under a
            // box, the question coming over the page, Save's flight to the
            // tab, Not now's, back from the tab, and a fill's tint fading
            // on the page (the page's own animation, in WebKit).
            case "wallet-list":
                if let tab = browser.active {
                    browser.walletList = Browser.WalletChoices(tab: tab.id, spot: CGRect(x: 40, y: 160, width: 320, height: 34), group: .card,
                                                               cards: Wallet.cards(), addresses: [], origin: Tab.originOf(tab.address))
                }
            case "wallet-list-off": browser.walletList = nil
            // The accounts hanging from a sign-in box (AccountList), coming
            // and going, made up so no keychain is read.
            case "login-list":
                if let tab = browser.active, let spaced = request["spaces"] as? String {
                    // Logins of two Spaces (#260b): "after" tags them with
                    // this Space and another, "before" leaves them untagged.
                    let here = browser.loginSpace(tab) ?? browser.spaceID
                    var names = browser.loginSpaceNames
                    let other = browser.spaces.first { $0.id != here }?.id ?? UUID()
                    if names[other] == nil { names[other] = "💼 Work" }
                    let rows: [(String, UUID?)] = [("anna@home.example", here), ("shared@example.com", nil), ("family@home.example", here),
                                                   ("anna@work.example", other), ("ops@work.example", other)]
                    let logins = rows.enumerated().map {
                        Login(host: "example.com", user: $0.element.0, password: "", used: Date().addingTimeInterval(Double(-$0.offset) * 3600),
                              space: spaced == "after" ? $0.element.1 : nil)
                    }
                    browser.suggesting = Browser.Suggesting(tab: tab.id, spot: CGRect(x: 40, y: 160, width: 320, height: 34),
                                                            logins: logins, site: "example.com", here: here, spaces: names)
                } else if let tab = browser.active {
                    let logins = ["jane@example.com", "jane.work@example.com", "j.appleseed@example.com"].enumerated().map {
                        Login(host: "example.com", user: $0.element, password: "", used: Date().addingTimeInterval(Double(-$0.offset) * 3600))
                    }
                    browser.suggesting = Browser.Suggesting(tab: tab.id, spot: CGRect(x: 40, y: 160, width: 320, height: 34),
                                                            logins: logins, site: "example.com")
                }
            case "login-list-off": browser.suggesting = nil
            // The password's card, the same moments, to hold the card's against.
            case "keep-offer":
                if let tab = browser.active {
                    browser.offer(Login(host: tab.address?.host() ?? "localhost", user: "jane@example.com", password: "hunter2hunter2"), changed: false, on: tab)
                }
            case "keep-park": if let tab = browser.active { browser.parkOffer(tab) }
            case "keep-dismiss": if let tab = browser.active { browser.dismissOffer(tab) }
            case "wallet-offer", "wallet-keep", "wallet-park", "wallet-unpark", "wallet-fill":
                if let tab = browser.active {
                    switch request["action"] as? String {
                    case "wallet-offer":
                        let card = SavedCard(id: UUID().uuidString, number: "5555555555554444", last4: "4444", brand: "Mastercard",
                                             name: "Jane Appleseed", month: 11, year: 2031, used: Date(), saved: nil)
                        withAnimation(Motion.reshape) { tab.payOffer = PayOffer(card: card, sites: [Browser.site(tab.address?.host() ?? "")]) }
                    case "wallet-keep": browser.keepPay(tab)
                    case "wallet-park": browser.parkPay(tab)
                    case "wallet-unpark": browser.unparkPay(tab)
                    default:
                        tab.walletFill(["number": "4242424242424242", "name": "Jane Appleseed", "month": 8, "year": 2030, "postal": "94105"],
                                       what: .card, origin: Tab.originOf(tab.address)) { _ in }
                    }
                }
            // The address field's places: ⌘K's list coming or going over
            // the pill; ↓ held down a place's list, a row every 70 ms, its
            // preview and pictures following; a place opened from its key.
            // The column's downloads coming up out of the button, and going.
            case "stack-open": if browser.hoard.openAt != .side { browser.hoard.toggle(.side) }
            case "stack-close": browser.hoard.openAt = nil
            case "box-k": browser.showActions()
            case "box-walk":
                var left = Int(seconds / 0.07)
                Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        left -= 1
                        if left <= 0 { timer.invalidate() }
                        browser.walk(request["up"] as? Bool == true ? -1 : 1)
                    }
                }
            case "box-place":
                if let place = FieldPlace(rawValue: request["place"] as? String ?? "") { browser.openPlace(place) }
            // The welcome coming up over the window, as Welcome… does, the
            // light before it, and then a press of Return in it
            // (browser.welcomeReturn): the next beat, or the next chapter.
            case "welcome-show":
                browser.welcoming = true
                LaunchArrival.shared.replay(browser)
            case "welcome-next":
                browser.welcomeReturn?()
            case "welcome-back":
                browser.welcomeBack?()
            // Any beat of the welcome, played from the one before it, or
            // any branch flipped, as the bench's welcome verb takes them, so
            // every move can be timed without asking macOS or installing.
            case "welcome-go":
                var go = request
                if go["step"] != nil, go["play"] == nil { go["play"] = "1" }
                WelcomeStage.shared.bench(go, browser) { _ in }
            // ⌥⌘R on the tab in front, in or out. A fifth of a second on,
            // mid-flight, the page's layers in this process (WebKit's remote
            // layer tree) are read for animations: there, Core Animation runs
            // them and neither the page nor this thread draws a frame.
            case "reader":
                browser.toggleReader()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    var keys: [String] = []
                    func walk(_ layer: CALayer) {
                        keys += layer.animationKeys() ?? []
                        layer.sublayers?.forEach(walk)
                    }
                    if let layer = browser.active?.builtPage?.layer { walk(layer) }
                    Bench.flying = keys
                }
            // A mouse's wheel over the row of tabs, a line every 50 ms, down
            // for the first half and up for the second, as events the app
            // takes from its queue like the wheel's own; "scroll", a
            // trackpad's over the page, and "across", sideways over the
            // row, the same way.
            case "wheel": spun = Spin(seconds: seconds, kind: .wheel)
            case "scroll": spun = Spin(seconds: seconds, kind: .page)
            // Two fingers down a page as a trackpad sends them, a sixtieth
            // apart: a beginning, the moves, the end, and the glide after,
            // twice over, the way the page scrolls when it's read.
            case "fingers": spun = Spin(seconds: seconds, kind: .fingers)
            // Two fingers down the column's rows and back, a trackpad's
            // moves a sixtieth apart: the rows' scroll (ColumnKit's cells
            // used again, or SwiftUI's lazy list).
            case "column-scroll": spun = Spin(seconds: seconds, kind: .column, by: request["by"] as? Double ?? 14)
            case "across": spun = Spin(seconds: seconds, kind: .across)
            // Two fingers over the chat column's turns, "by" points over
            // "over" seconds (negative: down), as a trackpad sends them.
            case "chat-scroll":
                let middle = view.convert(NSPoint(x: view.bounds.maxX - ChatLook.width / 2 - 12, y: view.bounds.midY), to: nil)
                Bench.swipe(by: request["by"] as? Double ?? -500, over: request["over"] as? Double ?? 0.3, at: middle, vertical: true)
            case "sides": browser.toggleSidebar()
            default:
                _ = latency.stop()
                link.invalidate()
                if let sizing { NotificationCenter.default.removeObserver(sizing) }
                SwitchMeter.on = false
                answer(["error": "unknown pace action"])
                return
            }
            let toggle = (CACurrentMediaTime() - t0) * 1000
            // How long each pass of the main run loop keeps it from going
            // idle, the drawing committed included: the first ones build
            // the side the tabs are going to.
            var passes: [Double] = []
            // And when each started, from the change, to tell whose it was.
            var busyAt: [Double] = []
            var worstPass = 0.0
            // Every pass over 4 ms the whole time, [when it began, how long],
            // for what comes long after the change: a swipe's landing.
            var long: [[Double]] = []
            var woke = CACurrentMediaTime()
            var stayedActive = NSApp.isActive && view.window?.isKeyWindow == true
            let focusObservers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name,
                    object: name == NSApplication.didResignActiveNotification ? NSApp : view.window,
                    queue: .main) { _ in stayedActive = false }
            }
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { woke = now; return }
                worstPass = max(worstPass, (now - woke) * 1000)
                if now - woke > 0.004, long.count < 400 { long.append([((woke - t0) * 1000).rounded(), ((now - woke) * 10000).rounded() / 10]) }
                if passes.count < 40 { passes.append((now - woke) * 1000); if (now - woke) > 0.002 { busyAt.append(((woke - t0) * 1000).rounded()) } }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                typingTimer?.invalidate()
                let callbackWindow = Pacer.callbackWindow(start: t0, end: CACurrentMediaTime(), delivered: pacer.delivered)
                let mainLatency = latency.stop()
                focusObservers.forEach(NotificationCenter.default.removeObserver)
                link.invalidate()
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                if let sizing { NotificationCenter.default.removeObserver(sizing) }
                let gaps = zip(pacer.times.dropFirst(), pacer.times).map { ($0 - $1) * 1000 }
                let callbackGaps = zip(pacer.delivered.dropFirst(), pacer.delivered).map { ($0 - $1) * 1000 }
                let frame = pacer.frame * 1000
                let cpu = Bench.mainCPU() - cpu0
                var out: [String: Any] = spun?.report ?? [:]
                out["main_cpu_ms"] = (cpu * 10).rounded() / 10
                out["strip_renders"] = StripRenderMeter.report
                answer(out.merging([
                    "frames": gaps.count,
                    "refresh_ms": (frame * 10).rounded() / 10,
                    "worst_ms": ((gaps.max() ?? 0) * 10).rounded() / 10,
                    "first_frame_ms": (max(0, (pacer.times.first ?? t0) - t0) * 10000).rounded() / 10,
                    "field_creations_before": fieldCreations,
                    "field_creations_after": AddressField.creations,
                    "field_presentations_before": fieldPresentations,
                    "field_presentations_after": Omnibox.presentations,
                    "app_active": NSApp.isActive,
                    "stayed_active": stayedActive,
                    "window_key": view.window?.isKeyWindow == true,
                    "window_visible": view.window?.occlusionState.contains(.visible) == true,
                    "first_callback_ms": (max(0, (pacer.delivered.first ?? t0) - t0) * 10000).rounded() / 10,
                    "worst_callback_ms": ((callbackGaps.max() ?? 0) * 10).rounded() / 10,
                    "measurement_ms": callbackWindow.duration * 1000,
                    "callback_leading_ms": callbackWindow.leading * 1000,
                    "callback_trailing_ms": callbackWindow.trailing * 1000,
                    "worst_callback_window_ms": callbackWindow.worst * 1000,
                    "callback_gaps_ms": callbackGaps.map { ($0 * 10).rounded() / 10 },
                    "main_latency_ms": (mainLatency * 10000).rounded() / 10,
                    "close_marks": Browser.CloseMarks.last,
                    "main_runloop_ms": (worstPass * 10).rounded() / 10,
                    "dropped": gaps.filter { $0 > frame * 1.5 }.count,
                    "gaps_ms": gaps.map { ($0 * 10).rounded() / 10 },
                    "page_resizes": StageView.resizes,
                    "page_steps": StageView.steps,
                    "stage_layouts": StageView.layouts,
                    "reshape_runs": Reshape.runs,
                    "chat_bodies": ChatFeed.bodies,
                    "switch_marks": SwitchMeter.report,
                    "chat_layouts": ChatColumnView.layouts,
                    "chat_built_ms": (ChatColumnView.built * 10).rounded() / 10,
                    "page_sizes": pageSizes,
                    "column_syncs": ColumnPages.syncs,
                    "column_laid_syncs": ColumnPages.laidSyncs,
                    "rows_resized": ColumnCell.resized,
                    "deck_move_ms": Bench.deckMoves,
                    "room_moves": Bench.roomMoves,
                    // [ms from the tab coming out, the page's innerWidth,
                    // 1 while still in the hand], and whether the page in
                    // front is still the same web view.
                    "deck_widths": Bench.deckWidths,
                    "deck_same_page": Bench.deckPage.map { id in browser.tabs.contains { $0.webKitOnly("WebKit-only bench fixtures", build: false).map(ObjectIdentifier.init) == id } } ?? false,
                    "deck_parts": SplitDeck.Meter.report,
                    // [ms, where the column's row of spaces is drawn, the
                    // fingers' rows' slide] while a space changes.
                    "pager_track": Bench.pagerTrack,
                    "instructions_m": ((Bench.instructions() - instructions0) * 10).rounded() / 10,
                    "toggle_ms": (toggle * 10).rounded() / 10,
                    // When the column's slide was handed to Core Animation.
                    "slide_ms": ColumnView.slid.map { (($0 - t0) * 10000).rounded() / 10 } ?? -1,
                    "busy_ms": passes.filter { $0 > 2 }.map { ($0 * 10).rounded() / 10 },
                    "main_cpu_ms": ((Bench.mainCPU() - cpu0) * 10).rounded() / 10,
                    // Every thread's, the dust's drawing thread among them.
                    "process_cpu_ms": ((Bench.processCPU() - process0) * 10).rounded() / 10,
                    "dust_played": Dust.shared.played,
                    "sidebar": browser.prefs.sidebar,
                    "glyph": browser.prefs.glyph.rawValue,
                    "sing_ms": (browser.chorus.cost.ms * 1000).rounded() / 1000,
                    "sing_minstr": (browser.chorus.cost.instructions * 1000).rounded() / 1000,
                    "busy_at": busyAt,
                    "page_animations": Bench.flying,
                    "long": long,
                    "frames_at": pacer.times.map { (($0 - t0) * 1000).rounded() },
                    "box_showing": browser.fieldShowing,
                    "box_place": browser.query.place?.rawValue ?? "",
                    "box_acting": browser.query.acting ?? -1,
                    "box_history_rows": browser.query.stock.visits.count,
                    "box_history_asked": browser.query.stock.asked,
                    "box_history_first_title": browser.query.stock.visits.first?.title ?? "",
                    "box_offer_titles": browser.query.offers.prefix(10).map(\.title),
                    "box_offers": browser.query.offers.count,
                    "box_text": browser.typed,
                    "typing_count": typingCount,
                    "typing_at_ms": typedAt.map { ($0 * 10).rounded() / 10 },
                    "typing_key_cost_ms": keyCost.map { ($0 * 10).rounded() / 10 },
                    "typing_card_heights": typedHeights,
                    "box_height": Omnibox.card.height,
                    "box_actions": browser.query.acting == nil ? 0 : browser.shownActions.count,
                ] as [String: Any]) { mine, _ in mine })
                Bench.flying = []
            }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard pacer.ready != nil else { return }
                pacer.ready = nil
                link.invalidate()
                answer(["error": "no display callback; keep the test window visible"])
            }

        case "split":
            // Two tabs side by side, driven the way the menu, ⌘T's command
            // and a click would, and what the window holds of them. A --test
            // run only: it rearranges your tabs.
            guard Store.testing else { answer(["error": "split only works on a --test run"]); return }
            switch request["act"] as? String ?? "state" {
            case "with":
                guard let other = target, let current = browser.active else { answer(missing(request)); return }
                browser.split(other, with: current)
            case "view": browser.splitView()
            case "click":
                // A click on the tab's row with `mods` held ("option",
                // "shift", "command"), posted to the window as the mouse
                // would, the row's own tap reading the keys off the event.
                guard let tab = target, let window = Links.window, let content = window.contentView,
                      let row = browser.keySky.place(tab.id), row.width > 0 else { answer(missing(request)); return }
                let named = (request["mods"] as? String ?? "").lowercased()
                var flags: NSEvent.ModifierFlags = []
                if named.contains("option") || named.contains("alt") { flags.insert(.option) }
                if named.contains("shift") { flags.insert(.shift) }
                if named.contains("command") || named.contains("cmd") { flags.insert(.command) }
                let at = NSPoint(x: row.midX, y: content.bounds.height - row.midY)
                if !window.isKeyWindow { window.makeKey() }
                Bench.rowClick = [
                    "at": "\(Int(at.x)) \(Int(at.y))", "row": "\(row.integral)",
                    "hit": content.hitTest(at).map { String(describing: type(of: $0)) } ?? "nothing",
                    "key": "\(window.isKeyWindow)", "active": "\(NSApp.isActive)",
                ]
                for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1
                    ) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
            case "pin":
                // A half pinned: out of its pair, as the tab's menu does it.
                guard let tab = target else { answer(missing(request)); return }
                browser.pin(tab)
            case "separate": browser.separate()
            // How far down the tab in front is, as its page would say, for
            // what the tab and its chip draw of it.
            case "reading": browser.active?.reading = request["value"] as? Double ?? 0.5
            // The divider moved by layers (SplitRule) or by SwiftUI, "off",
            // to measure one against the other.
            case "rule":
                Store.settings.set(request["mode"] as? String, forKey: "split.rule")
                SplitRule.enabled = request["mode"] as? String != "off"
            // ⌘F's bar over the half in front, as the menu opens it.
            case "find": browser.openFind()
            // The cross on a half's band.
            case "leave":
                // The pointer on the cross first, as a hand gets there: its
                // picture taken, then the click.
                guard let tab = target else { answer(missing(request)); return }
                browser.splitHint.leave(tab.id, true)
                SplitDeck.shared.ready(tab.id, in: browser)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { browser.leaveSplit(tab.id) }
            case "equal": browser.equalizeSplit()
            case "focus":
                guard let tab = target else { answer(missing(request)); return }
                browser.focus(tab)
            case "live":
                // How the divider moves the pages: "live" makes them their new
                // width on every move, anything else holds them (the default).
                Store.settings.set(request["mode"] as? String, forKey: "split.drag")
                Browser.splitLive = request["mode"] as? String == "live"
            case "slow":
                // SplitDeck's beats drawn slower, to look at their frames.
                SplitDeck.slow = request["by"] as? Double ?? 1
            case "cover":
                StageView.covering = request["mode"] as? String != "off"
            // The divider taken and let go at this share, as the hand would.
            case "share":
                browser.beginSplitDrag()
                browser.dragSplit(to: CGFloat(request["value"] as? Double ?? 0.5))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { browser.endSplitDrag() }
            // The veils taken away since the last ask: by WebKit's drawing or
            // by the second running out, and after how long.
            // A pair pinned as one (PinPairs.swift), driven as its menus and
            // its square do it.
            case "pinpair":
                guard let pair = browser.pair(of: target?.id ?? browser.activeID) else { answer(missing(request)); return }
                browser.pinPair(pair)
            case "unpinpair":
                guard let pair = browser.pinPair(of: target?.id ?? browser.activeID) else { answer(missing(request)); return }
                browser.unpinPair(pair)
            case "separatepin":
                guard let pair = browser.pinPair(of: target?.id ?? browser.activeID) else { answer(missing(request)); return }
                browser.separatePinPair(pair)
            case "openpin":
                guard let tab = target, let pair = browser.pinPair(of: tab.id) else { answer(missing(request)); return }
                browser.openPinPair(pair)
            case "closepair":
                guard let pair = browser.pinPair(of: target?.id ?? browser.activeID) else { answer(missing(request)); return }
                browser.closePinPair(pair)
            case "lifts":
                let lifts = StageView.lifts
                StageView.lifts = []
                answer(["lifts": lifts.map { ["drawn": $0.drawn, "ms": ($0.ms * 10).rounded() / 10] }])
                return
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["act"] == nil ? 0 : 0.6)) {
                let short = { (id: Tab.ID?) in id.map { String($0.uuidString.prefix(8)).lowercased() } ?? "" }
                answer([
                    "pairs": browser.pairs.map { ["first": short($0.first), "second": short($0.second), "share": Double($0.share)] },
                    "shown": browser.stagePair.map { [short($0.first), short($0.second)] } ?? [],
                    "stages": browser.stages.map(short),
                    "active": short(browser.activeID),
                    "wide": short(browser.wide),
                    "room": browser.splitRoom.map { "\($0)" } ?? "",
                    "room_asked": browser.splitRoomAsked.map { "\($0)" } ?? "",
                    "rooming": browser.splitRooming,
                    "splitting": browser.splitting || browser.splitHeld,
                    "bar": browser.barShown,
                    "frames": Dictionary(uniqueKeysWithValues: browser.splitBook.frames.map { (short($0.key), [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height].map { Double($0) }) }),
                    "row": browser.tabs.map { short($0.id) },
                    "awake": browser.tabs.filter { $0.builtPage != nil && !$0.asleep }.map { short($0.id) },
                    "live": Browser.splitLive,
                    "responder": Links.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
                    "moved_ms": ((browser.splitBook.moved - browser.splitBook.asked) * 10000).rounded() / 10,
                    "deck": SplitDeck.shared.report,
                    "bands": Dictionary(uniqueKeysWithValues: BandLayout.parts.map { (short($0.key), $0.value.map { "\($0.key): \($0.value.site)" }) }),
                    "rule": SplitRule.shared.report + ["ruled \(browser.splitDrag.ruled) armed \(browser.splitDrag.armed) held \(browser.splitHeld) share \(String(describing: browser.splitDrag.share))"],
                    "band": [Double(browser.splitBook.bar), Double(browser.splitBook.corner)],
                    "tabframes": Dictionary(uniqueKeysWithValues: browser.keySky.places.map { (short($0.key), [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height].map { Double($0) }) }),
                    "fits": browser.splitFits,
                    "pinned": browser.tabs.filter { $0.pin != nil }.map { short($0.id) },
                    "grid": browser.gridPins.map { short($0.id) },
                    "pinpairs": browser.pairs.filter { browser.pinPair(of: $0.first) != nil }.map { [short($0.first), short($0.second)] },
                    "rested": browser.tabs.filter(\.pairRest).map { short($0.id) },
                    // What ⌃⌘\ said or opened: the corner's words, the field asking.
                    "toast": browser.toaster.shown ? browser.toaster.words : "",
                    "asked": browser.asked.map { "\($0)" } ?? "",
                    "clicked": Bench.rowClick,
                    "side": [Double(browser.sideShown), browser.prefs.sideShut ? 1 : 0, browser.sidePeek ? 1 : 0],
                    "floor": Double(Links.window?.contentMinSize.width ?? 0),
                    // This browser's own window, which `browserWindow` may name.
                    "window_floor": Double(browser.windowFloor),
                    "window_width": Double(BrowserWindows.shared.window(for: browser)?.frame.width ?? 0),
                    "window_in_front": BrowserWindows.shared.activeWindow === BrowserWindows.shared.window(for: browser),
                    "window": Double(Links.window?.frame.width ?? 0),
                    "place": [browser.splitBook.place.minX, browser.splitBook.place.minY, browser.splitBook.place.width, browser.splitBook.place.height].map { Double($0) },
                ])
            }

        case "film":
            // The left of the window drawn about sixty times a second while
            // one thing happens, a new tab, a pick, a close, to see which
            // changes move and which land at once. A --test run only: it
            // opens, picks and closes tabs.
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            // `browserWindow`: that window filmed, though another is in front
            // (what another window's change does to this one's column).
            let askedWindow = (request["window"] as? Int).flatMap { number in NSApp.windows.first { $0.windowNumber == number } }
            let filmed = askedWindow ?? (request["browserWindow"] != nil ? BrowserWindows.shared.window(for: browser) : nil)
            guard let window = filmed ?? Links.window, let content = window.contentView,
                  let layer = content.superview?.layer ?? content.layer
            else { answer(["error": "no window"]); return }
            let target = find(request, in: browser)
            let act: () -> Void
            switch request["action"] as? String ?? "" {
            case "newtab": act = { browser.newTab() }
            case "shy": act = { browser.newShyTab() }
            // Nothing: just the frames, while something else, a hand, a
            // script posting events, does the moving.
            case "watch": act = {}
            case "peek":
                guard let tab = browser.active, let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                    answer(missing(request)); return
                }
                act = { browser.peek(url, from: tab) }
            case "peek-close": act = { browser.closePeek() }
            // Fingers on the peek ("by", out above 0), as `peek` act pinch.
            case "peek-pinch":
                let by = CGFloat((request["by"] as? NSNumber)?.doubleValue ?? -0.4)
                act = { browser.peekView?.benchPinch(by) { _, _ in } }
            // The next space, as ⌃N does; two fingers sideways ("by",
            // "over", "hold"). Drawn as the render server has it now
            // ("presentation" true): the row of spaces lands there.
            case "space-step": act = { browser.stepSpace(request["by"] as? Int ?? 1) }
            case "space-swipe": act = {
                Bench.swipe(by: request["by"] as? Double ?? -160, over: request["over"] as? Double ?? 0.35, hold: request["hold"] as? Double ?? 0,
                            rows: request["rows"] as? Bool ?? false, pane: request["pane"] as? Bool ?? false)
            }
            // A mouse's wheel over the column, as `spacewheel` posts it.
            case "space-wheel":
                if let off = request["off"] as? Bool { SpaceSwipe.wheelOff = off }
                let point = Spin.columnPoint(y: request["y"] as? Double, x: request["x"] as? Double)
                act = {
                    Spin.wheel(dx: request["dx"] as? Double ?? 0, dy: request["dy"] as? Double ?? 0,
                               count: request["notches"] as? Int ?? 1, gap: request["gap"] as? Double ?? 0.05,
                               smooth: request["smooth"] as? Bool ?? false, shift: request["shift"] as? Bool ?? false, at: point)
                }
            // The + clicked with the pointer left where it was.
            case "plus": act = { browser.newTab() }
            // ⇧⌘S, the tabs changing sides.
            case "sides": act = { browser.toggleSidebar() }
            // Settings › Appearance › Window picked ("mode": none, color, site).
            case "backdrop":
                guard let mode = (request["mode"] as? String).flatMap(Backdrop.init(rawValue:)) else { answer(missing(request)); return }
                act = { WindowMenu.pick(mode, in: browser.prefs) }
            // ⇧⌘B, the bookmarks coming up over the page or going.
            case "shelf": act = { browser.toggleBookmarkBar() }
            // ⌘S, the column put away or brought back.
            case "column": act = { browser.toggleColumn() }
            // The band with the lights beside a column on the right, out
            // over the page's top and back in (HeadBand).
            case "head-out": act = { browser.moveHead(out: true) }
            case "head-in": act = { browser.moveHead(out: false) }
            // An agent's task folder opened or shut.
            case "folder": act = { if let folder = Folders.shared.folders.first { Folders.shared.toggle(folder.id) } }
            // The space's name clicked: its kept fold away under it, or back.
            case "space-fold": act = { Folders.shared.toggleSpace() }
            // Hide Space Name or Show Space Name, as the space's menu does.
            case "space-names": act = { withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { browser.prefs.spaceNames.toggle() } }
            // A folder ("folder": its name) to another space ("space"), as its
            // menu sends it: a beat after the line is picked, on Arc's clock.
            case "folder-space":
                guard let nest = browser.nests.first(where: { $0.name == request["folder"] as? String }),
                      let space = browser.spaces.first(where: { $0.name.lowercased() == (request["space"] as? String ?? "").lowercased() })
                else { answer(missing(request)); return }
                act = {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Browser.folderLeavesAfter) {
                        browser.moveFolder(nest, to: space.id, ask: false, hand: true)
                    }
                }
            // The same folder let go over that space in the foot's row.
            case "folder-drop":
                guard let nest = browser.nests.first(where: { $0.name == request["folder"] as? String }),
                      let space = browser.spaces.first(where: { $0.name.lowercased() == (request["space"] as? String ?? "").lowercased() }),
                      let at = SpaceAnchors.slotPoint(space.id)
                else { answer(missing(request)); return }
                act = {
                    _ = SpaceDrop.shared.track(browser.tabs(in: nest), browser: browser, folder: nest, at: at)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { _ = SpaceDrop.shared.finish(browser) }
                }
            // The tab on screen to another space ("space"), as its menu
            // sends it: the window follows, on the space's slide.
            case "tab-space":
                guard let tab = browser.active,
                      let space = browser.spaces.first(where: { $0.name.lowercased() == (request["space"] as? String ?? "").lowercased() })
                else { answer(missing(request)); return }
                act = {
                    SpaceSend(browser: browser, tabs: [tab]).send(to: space.id)
                }
            // The chat column's own screens: its chats kept coming in over a
            // chat, and one of them picked ("id"), as its row does.
            case "chat-list": act = { browser.chatHistory = true }
            case "chat-pick":
                guard let id = request["id"] as? String else { answer(missing(request)); return }
                act = { browser.keepChat(id) }
            // New Chat's row on the chats kept.
            case "chat-new": act = { browser.newChat() }
            // The chats kept scrolled "by" points with two fingers, as a
            // trackpad sends them (negative: down the list).
            case "chat-scroll":
                guard let content = Links.window?.contentView else { answer(["error": "no window"]); return }
                let middle = content.convert(NSPoint(x: content.bounds.maxX - 150, y: content.bounds.midY), to: nil)
                act = { Bench.swipe(by: request["by"] as? Double ?? -500, over: request["over"] as? Double ?? 0.3, at: middle, vertical: true) }
            // A card ("id", or New Chat's row with none) held for "hold"
            // seconds, its chat built under the list meanwhile
            // (ChatZoom.press), and let go of, as a click on it is.
            case "chat-press":
                let id = request["id"] as? String ?? ChatCards.newChat
                let hold = request["hold"] as? Double ?? 0.12
                // Back to the list this long after the click, the flight turned mid-way.
                let back = request["back"] as? Double
                act = {
                    ChatZoom.press(id, down: true, in: browser)
                    DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                        MainActor.assumeIsolated {
                            if id == ChatCards.newChat { browser.newChat() } else { browser.keepChat(id) }
                            ChatZoom.press(id, down: false, in: browser)
                        }
                    }
                    if let back {
                        DispatchQueue.main.asyncAfter(deadline: .now() + hold + back) {
                            MainActor.assumeIsolated { browser.chatHistory = true }
                        }
                    }
                }
            // Two fingers sideways over the chat ("by" points over "over"
            // seconds): far enough, it goes back into its card.
            case "chat-swipe":
                guard let stage = ChatZoom.of(browser)?.stage else { answer(["error": "no chat"]); return }
                let middle = stage.convert(NSPoint(x: stage.bounds.midX, y: stage.bounds.midY), to: nil)
                act = { Bench.swipe(by: request["by"] as? Double ?? -260, over: request["over"] as? Double ?? 0.25, at: middle) }
            // ⌘⇧C, filmed from the right, where "Link copied" comes in.
            case "copy": act = { browser.copyAddress() }
            // ⌘A's offer on the tab in front, and M a moment later: the pill
            // coming in, the part picked taking the others in, and going.
            case "pagecopy":
                guard let tab = browser.active, let web = tab.builtPage else { answer(["error": "no page"]); return }
                act = {
                    browser.pageCopy.offer(tab: tab.id, web: web, words: 1200, canSave: !tab.shy, transcript: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { browser.copyPageMarkdown() } }
                }
            // The tidy-up and its notice, from the right like "Link copied".
            case "tidy": act = { browser.ageForTidy(hours: 13); browser.tidy() }
            // Every way the corner changes, one after another: a copy, the
            // same copy again, a different one, a tidy-up over it (three
            // tabs, none of them put away), and back.
            case "notices": act = {
                browser.copyAddress()
                let later: [(Double, () -> Void)] = [
                    (0.6, { browser.copyAddress() }),
                    (1.1, { browser.toaster.pop("Password copied", mark: "key") }),
                    (1.7, { browser.tidier.show(3, batch: UUID()) }),
                    (2.6, { browser.copyAddress() }),
                ]
                for (at, step) in later {
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated(step) }
                }
            }
            case "select":
                guard let target else { answer(missing(request)); return }
                act = { browser.select(target) }
            case "close":
                guard let target else { answer(missing(request)); return }
                act = { browser.close(target) }
            case "reopen": act = { browser.reopen() }
            // The page's sound starting or stopping (as WebKit says it) and
            // the tab muted or heard: the speaker beside the mark (SideSpeaker).
            case "sound", "mute":
                guard let target else { answer(missing(request)); return }
                let on = request["on"] as? Bool ?? true
                act = request["action"] as? String == "sound" ? { target.noisy = on } : { target.mute(on) }
            // The address field: raised over the page, put away, a Return,
            // and words typed into it, the whole window, so its middle.
            case "edit": act = { browser.edit() }
            // The field's own place, Clipboard History, gone into; ⌘K's list.
            case "place": act = { browser.enterPlace(.clipboard) }
            case "emoji": act = { browser.enterPlace(.emoji) }
            case "actions": act = { browser.showActions() }
            case "dismiss": act = { browser.dismiss() }
            case "submit": act = { browser.submit() }
            case "type":
                guard let text = request["text"] as? String else { answer(missing(request)); return }
                act = { browser.typed = text }
            // The password pill on the tab in front, answered: Save, Not now,
            // Never here and its Undo, the name clicked, the key clicked.
            case "keep", "park", "never", "undo", "name", "unpark":
                guard let tab = browser.active else { answer(["error": "no tab"]); return }
                switch request["action"] as? String {
                case "keep": act = { browser.keepOffer(tab) }
                case "park": act = { browser.parkOffer(tab) }
                case "never": act = { browser.neverOffer(tab) }
                case "undo": act = { browser.undoNever(tab) }
                case "name": act = { browser.nameOffer(tab) }
                default: act = { browser.unparkOffer(tab) }
                }
            // A card's or an address's offer answered the same ways (WalletKeep).
            case "pay-keep", "pay-park", "pay-unpark":
                guard let tab = browser.active else { answer(["error": "no tab"]); return }
                switch request["action"] as? String {
                case "pay-keep": act = { browser.keepPay(tab) }
                case "pay-park": act = { browser.parkPay(tab) }
                default: act = { browser.unparkPay(tab) }
                }
            // A rewrite drawn in the text's place (SelectionInk), from the
            // chip to the bar: the words coming in a dozen letters a tenth
            // of a second, as an agent's do, done, then Replace or Esc
            // ("end" replace or close). Text selected first.
            case "ink":
                guard let tab = browser.active else { answer(["error": "no tab"]); return }
                let commands = browser.selectionCommands
                let words = request["text"] as? String ?? "We moved the plan picker ahead of the card form, so people choose what they pay for before they are asked how to pay."
                let ending = request["end"] as? String ?? "replace"
                act = {
                    commands.peek(on: tab) { snap in
                        guard let snap, let command = commands.commands.first(where: { $0.id == (request["command"] as? String ?? "improve") }) else { return }
                        commands.show(command, on: tab, snapshot: snap, stage: .running, output: "")
                        let counts = Array(stride(from: 12, to: words.count, by: 12)) + [words.count]
                        for (index, count) in counts.enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + 0.1 * Double(index)) {
                                MainActor.assumeIsolated { commands.output = String(words.prefix(count)) }
                            }
                        }
                        let finished = 0.45 + 0.1 * Double(counts.count)
                        DispatchQueue.main.asyncAfter(deadline: .now() + finished) {
                            MainActor.assumeIsolated { commands.stage = .preview }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + finished + 0.9) {
                            MainActor.assumeIsolated { if ending == "replace" { commands.apply() } else { commands.close() } }
                        }
                    }
                }
            // While You Browse's rename, the model stood in (`name`): a kept
            // tab's (`id`, the one in front without) or the newest download's.
            case "tidy-name":
                guard Store.testing else { answer(["error": "tidy-name only works in a test world"]); return }
                guard let tab = target ?? browser.active,
                      let name = request["name"] as? String else { answer(missing(request)); return }
                act = { _ = ShortNames.shared.stand(name, for: tab) }
            case "tidy-download":
                guard Store.testing else { answer(["error": "tidy-download only works in a test world"]); return }
                guard let keep = browser.loot.kept.first, let name = request["name"] as? String else { answer(missing(request)); return }
                act = { browser.hoard.peek(rename: keep, to: DownloadNames.fileName(name, like: keep.name)) }
            default: answer(["error": "film needs an action: newtab, sides, copy, edit, dismiss, submit, type, select, close, or keep, park, never, undo, name, unpark, pay-keep, pay-park, pay-unpark"]); return
            }
            let whole = ["shy", "sides", "shelf", "edit", "dismiss", "submit", "type", "keep", "park", "never", "undo", "name", "unpark", "pay-keep", "pay-park", "pay-unpark"].contains(request["action"] as? String ?? "")
            let width = request["width"] as? Double ?? (whole ? Double(layer.bounds.width) : 300)
            let seconds = request["seconds"] as? Double ?? 0.6
            let folder = URL(fileURLWithPath: (request["path"] as? String) ?? NSTemporaryDirectory() + "yab-bench-film")
            // Drawn smaller when asked, so a whole window keeps up with sixty a second.
            let scale = (request["scale"] as? Double).map { CGFloat($0) } ?? window.backingScaleFactor
            let size = CGSize(width: min(width, layer.bounds.width), height: layer.bounds.height)
            // The strip taken from the window's right edge rather than its left.
            let right = (request["side"] as? String) == "right" || ["copy", "tidy", "notices", "pagecopy"].contains(request["action"] as? String ?? "")
            let shift = (request["x"] as? Double).map { CGFloat($0) } ?? (right ? layer.bounds.width - size.width : 0)
            let drawn = request["presentation"] as? Bool ?? false
            func frame() -> CGImage? {
                guard let context = CGContext(
                    data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -shift, y: 0)
                Bench.render(drawn ? layer.presentation() ?? layer : layer, in: context)
                // The panels over the window too: the downloads' list, the
                // stack, what rides between them.
                if request["children"] as? Bool == true {
                    for child in window.childWindows ?? [] where child.isVisible {
                        guard let top = child.contentView?.superview?.layer ?? child.contentView?.layer else { continue }
                        context.saveGState()
                        context.translateBy(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
                        Bench.render(drawn ? top.presentation() ?? top : top, in: context)
                        context.restoreGState()
                    }
                }
                if request["linkcards"] as? Bool == true,
                   let card = browser.linkCard.filmWindow,
                   let cardLayer = card.contentView?.superview?.layer ?? card.contentView?.layer {
                    context.saveGState()
                    context.translateBy(x: card.frame.minX - window.frame.minX, y: card.frame.minY - window.frame.minY)
                    Bench.render(drawn ? cardLayer.presentation() ?? cardLayer : cardLayer, in: context)
                    context.restoreGState()
                }
                return context.makeImage()
            }
            // "probe" [x, y], window points from its top left: every frame,
            // the layers over that point that are see-through or moving.
            let probe = (request["probe"] as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: layer.bounds.height - $0[1]) : nil }
            var traces: [[String]] = []
            func trace() { if let probe { traces.append(Bench.layersOver(probe, in: layer)) } }
            var frames: [(Double, CGImage)] = []
            // Where the column's row of spaces is drawn at each frame, in
            // pages from the space it set off from: the color is judged
            // against it (wash_matrix.py).
            var rows: [Double?] = []
            if let first = frame() { frames.append((0, first)); rows.append(SpacePager.shared.drawnPages); trace() }
            let start = CACurrentMediaTime()
            act()
            // In every run-loop mode, so a drag's tracking doesn't stop the film.
            let filming = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let at = CACurrentMediaTime() - start
                    if let image = frame() { frames.append((at, image)); rows.append(SpacePager.shared.drawnPages); trace() }
                    guard at >= seconds else { return }
                    timer.invalidate()
                    try? FileManager.default.removeItem(at: folder)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var written: [[String: Any]] = []
                    for (index, (time, image)) in frames.enumerated() {
                        let file = folder.appendingPathComponent(String(format: "%03d.png", index))
                        let rep = NSBitmapImageRep(cgImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: file)
                        var made: [String: Any] = ["file": file.path, "ms": Int(time * 1000)]
                        if let row = rows[index] { made["row"] = row }
                        written.append(made)
                    }
                    answer(probe == nil ? ["frames": written] : ["frames": written, "traces": traces])
                }
            }
            RunLoop.main.add(filming, forMode: .common)

        case "float":
            // The little video window: lifted as ⇧⌘P lifts it, read, and
            // handed pointer and keys as made-up events. "idle" is what the
            // main thread spends meanwhile: its own CPU time, and how often
            // its run loop woke. A --test run only: it floats a video over
            // everything on the screen.
            guard Store.testing else { answer(["error": "float only works on a --test run"]); return }
            switch request["action"] as? String ?? "state" {
            case "return-before-pip":
                guard let sibling = find(["id": request["other"] ?? ""], in: browser) else { answer(["error": "sibling required"]); return }
                // Same native event turn: the person returns before the
                // asynchronous native request can present its video.
                answer(browser.benchReturnBeforePiP(sibling))
            case "pending-pip":
                answer(["pending": browser.pendingVideoRequestsForBench, "showing": browser.floater.showing,
                        "active": browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""])
            case "toggle":
                // ⇧⌘P into Yab's window: away, or, tucked behind an edge, back out.
                browser.toggleFloat(own: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if browser.floater.showing { browser.floater.bench(["action": "state"], answer) } else { answer(["showing": false]) }
                }
            case "on":
                // Up already, it stays up: ⇧⌘P again would put it away.
                if !browser.floater.showing { browser.toggleFloat(own: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    browser.floater.bench(["action": "state"], answer)
                }
            case "pip":
                // ⇧⌘P itself (Float Video): the video alone out of the page
                // when it can be, as people press it (evals/pip-sites).
                // "native": WebKit's own video in Yab's window; "page": the
                // page lifted around it. `off` puts whatever is out back.
                if request["off"] as? Bool == true {
                    browser.land()
                } else if !browser.floater.showing {
                    browser.toggleFloat(own: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 2.5)) {
                    let mode = !browser.floater.showing ? "none" : browser.picturing != nil ? "native" : "page"
                    answer(["showing": browser.floater.showing, "mode": mode,
                            "pictureInPicture": browser.active?.pictureInPicture ?? false])
                }
            case "home":
                // The window's own way back to the tab, as its button.
                browser.floater.onReturn?()
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 0.6)) {
                    answer(["showing": browser.floater.showing, "active": NSApp.isActive])
                }
            case "app":
                // The app as someone working elsewhere leaves it: "hide" (⌘H),
                // "unhide", "away" (another app in front), "front", the
                // browser's window "mini" (in the Dock) or "unmini".
                let main = BrowserWindows.shared.window(for: browser)
                switch request["how"] as? String ?? "" {
                case "hide": NSApp.hide(nil)
                case "unhide": NSApp.unhide(nil)
                // Finder brought to the front, as ⌘Tab to it: deactivate()
                // alone leaves Yab active when no app takes its place, and
                // posts no didResignActive.
                case "away":
                    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                        NSApp.yieldActivation(to: finder)
                        finder.activate()
                    } else {
                        NSApp.deactivate()
                    }
                // As ⌘Tab brings an app: activated, no window asked for.
                case "activate": NSApp.activate(ignoringOtherApps: true)
                case "front":
                    main?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                case "mini": main?.miniaturize(nil)
                case "unmini": main?.deminiaturize(nil)
                // Onto the screen whose name holds `screen`, `size` points
                // big (width, height), in its middle: a screen of another
                // scale than the test screen's (evals/docs-zoom).
                case "screen":
                    if let name = request["screen"] as? String, let main,
                       let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
                        let area = screen.visibleFrame
                        let size = request["size"] as? [Double] ?? [Double(area.width), Double(area.height)]
                        let width = min(CGFloat(size.first ?? 0), area.width), height = min(CGFloat(size.last ?? 0), area.height)
                        main.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height), display: true)
                    }
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 0.6)) {
                    answer([
                        "active": NSApp.isActive, "hidden": NSApp.isHidden,
                        "visible": main.map { $0.occlusionState.contains(.visible) } ?? false,
                        "mini": main?.isMiniaturized ?? false,
                        "screens": NSScreen.screens.map { s -> [Double] in
                            [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height, s.backingScaleFactor].map { Double($0) }
                        },
                        "screenNames": NSScreen.screens.map(\.localizedName),
                        "windowScreen": main?.screen.map { FeedbackDiagnostics.mode(of: $0) } ?? [:],
                        "window": main.map { w -> [Double] in
                            [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height, w.backingScaleFactor].map { Double($0) }
                        } ?? [],
                    ])
                }
            case "away-pref":
                // Leaving Yab alone, on or off, whatever Settings › Tabs'
                // Picture in Picture automatically says (Browser.benchAway).
                Browser.benchAway = request["on"] as? Bool ?? true
                answer(["floatsAway": Browser.benchAway ?? true])
            case "page":
                // Where a tab's page is, as AppKit and Core Animation have
                // it: its window, its holder, its frame, and anything left
                // on its layer by the little window.
                guard let tab = find(request, in: browser), let web = tab.webKitOnly("WebKit-only bench fixtures", build: false) else { answer(missing(request)); return }
                let layer = web.layer
                let main = BrowserWindows.shared.window(for: browser)
                // The picture's own layers, where Core Animation draws them,
                // in the page's points from its top left: a video layer the
                // page moved and the window never followed is a picture out
                // of its player whatever the page's own boxes say.
                var videoLayers: [[String: Any]] = []
                var seen = 0
                func walk(_ node: CALayer, depth: Int) {
                    seen += 1
                    guard depth < 40, seen < 4000, let root = layer else { return }
                    let kind = String(describing: type(of: node))
                    if kind.range(of: "video|avplayer|playerlayer|hostinglayer|layerhost|samplebuffer|displaylayer", options: [.regularExpression, .caseInsensitive]) != nil {
                        let r = node.convert(node.bounds, to: root)
                        let top = root.isGeometryFlipped ? r.minY : root.bounds.height - r.maxY
                        videoLayers.append([
                            "class": kind, "depth": depth, "hidden": node.isHidden,
                            "rect": [r.minX, top, r.width, r.height].map { (Double($0) * 10).rounded() / 10 },
                            "identity": CATransform3DIsIdentity(node.transform),
                        ])
                    }
                    for child in node.sublayers ?? [] { walk(child, depth: depth + 1) }
                }
                if let layer { walk(layer, depth: 0) }
                answer([
                    "floating": tab.floating, "showing": browser.floater.showing, "homing": browser.floater.homing,
                    "holder": web.superview.map { String(describing: type(of: $0)) } ?? "",
                    "inMain": web.window != nil && web.window === main,
                    "frame": [web.frame.minX, web.frame.minY, web.frame.width, web.frame.height].map { Double($0) },
                    "holderBounds": web.superview.map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height].map(Double.init) } ?? [],
                    "transform": layer.map { CATransform3DIsIdentity($0.transform) && CATransform3DIsIdentity($0.sublayerTransform) } ?? true,
                    "filters": layer?.filters?.count ?? 0,
                    "opacity": Double(layer?.opacity ?? 1), "alpha": Double(web.alphaValue), "hidden": web.isHidden,
                    "active": NSApp.isActive,
                    "mainVisible": main.map { $0.occlusionState.contains(.visible) } ?? false,
                    "mainKey": main?.isKeyWindow ?? false,
                    "videoLayers": videoLayers, "layers": seen,
                ])
            case "idle":
                let seconds = request["seconds"] as? Double ?? 5
                var wakes = 0
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { _, _ in
                    wakes += 1
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                let resized = browser.floater.resizes
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    let spent = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                    answer([
                        "seconds": seconds,
                        "main_cpu_ms": (spent * 10).rounded() / 10,
                        "main_cpu_pct": (spent / seconds / 10 * 100).rounded() / 100,
                        "wakes_per_s": (Double(wakes) / seconds * 10).rounded() / 10,
                        "page_resizes": browser.floater.resizes - resized,
                    ])
                }
            default:
                browser.floater.bench(request, answer)
            }

        case "columnmore":
            // A narrow column's "⋯" (HelmMore): its rows as they would be
            // now, whether it is up with its menu's window, or let go.
            if request["dismiss"] as? Bool == true { HelmMore.shown?.cancelTracking(); ActionMenu.close() }
            answer(["rows": HelmMore.make(browser, tab: browser.active, own: false).items.map(\.title),
                    "up": HelmMore.shown != nil, "windows": WindowBench.menuWindows()])

        case "spots":
            // Where each control marked for it is (benchSpot), in the window's
            // points from its top left, as last laid out: pressed with drag
            // as the mouse would press it.
            // A held door's list's rows too ("history row 0", nearest first),
            // and the doors that list or open beside ("door arrow.left", by symbol).
            let spots = Bench.spots.merging(DoorList.shared.benchRows()) { $1 }.merging(DoorHold.shared.benchDoors()) { $1 }
            answer(["spots": spots.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }])

        case "frames":
            // Where each tab and each tab's mark is, in the window's points
            // from its top left, as they were last laid out: for checking a
            // picture of the window by measurement rather than by eye.
            func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            let sky = browser.keySky
            answer(["tabs": browser.tabs.compactMap { tab -> [String: Any]? in
                // A half of a pair is drawn as a chip in the pair's row and
                // has only its mark's frame.
                if let place = Folders.shared.place(of: tab), !place.shown { return nil }
                guard sky.place(tab.id) != nil || sky.marks[tab.id] != nil else { return nil }
                var out: [String: Any] = ["id": String(tab.id.uuidString.prefix(8)).lowercased(),
                                          "pinned": tab.pin != nil, "title": tab.label, "paired": browser.pair(of: tab.id) != nil]
                if let whole = sky.place(tab.id) { out["tab"] = rect(whole) }
                if let mark = sky.marks[tab.id] { out["mark"] = rect(mark) }
                return out
            }])

        case "snippets":
            // Snippets everywhere (Snippets.swift, evals/snippets): kept,
            // cleared, their switches, and the paste offer answered. A
            // --test run only: it writes the list.
            guard Store.testing else { answer(["error": "snippets only works on a --test run, it changes your snippets"]); return }
            let snippets = MailSnippets.shared
            switch request["action"] as? String ?? "state" {
            case "add":
                let key = (request["hotkey"] as? String).flatMap(Bench.chord).map { Hotkey($0.1, $0.0) }
                snippets.add(name: request["name"] as? String ?? "", body: request["body"] as? String ?? "",
                             mailOnly: request["mailOnly"] as? Bool ?? false, hotkey: key?.stored ?? "")
            case "clear":
                for one in snippets.all { snippets.remove(one.id) }
            case "settings":
                if let on = request["semicolon"] as? Bool { SnippetSettings.semicolon = on }
                if let on = request["offers"] as? Bool { SnippetSettings.offers = on }
            // Settings › Snippets' New Snippet…, as a click on it.
            case "new":
                Bench.snippetAsked = CACurrentMediaTime()
                Bench.snippetShown = nil
                var draft = MailSnippet(name: "", body: "")
                draft.mailOnly = request["mail"] as? Bool ?? false
                SnippetEditing.shared.open(nil, draft: draft)
            case "shut": SnippetEditing.shared.close()
            // Bring In: a file read onto the card, as one chosen in the
            // open panel; a source of this Mac's, as its menu row; the
            // card's Bring In pressed.
            case "bring":
                if let path = request["path"] as? String { SnippetBringIn.open(URL(fileURLWithPath: path)) }
                if let source = (request["source"] as? String).flatMap(SnippetSource.init(rawValue:)) {
                    if source == .superhuman { SnippetSuperhuman.start() } else { SnippetBringIn.fromThisMac(source) }
                }
            case "take":
                if let bring = SnippetEditing.shared.bring { SnippetEditing.shared.brought(MailSnippets.shared.bringIn(bring.found)) }
            // The open editor's Hotkey clicked: keys then go in with
            // `keys act=press`, and `keys` says what the recorder said.
            case "record": SnippetEditing.shared.listen = true
            case "keep": SnippetOffers.shared.keep()
            case "park": SnippetOffers.shared.notNow()
            // The card's name written over, as its field does.
            case "rename": SnippetOffers.shared.written = SnippetOffers.command(request["text"] as? String ?? "")
            // Words typed into the field while its Snippets place is open.
            case "find": if browser.fieldShowing { browser.typed = request["text"] as? String ?? "" }
            default: break
            }
            let call = PageSnippets.shared.call
            let offer = SnippetOffers.shared.offer
            answer(["snippets": snippets.ordered.map { ["name": $0.name, "body": $0.body, "uses": $0.uses, "mailOnly": $0.mailOnly, "hotkey": $0.hotkey] },
                    "list": call?.rows.map(\.name) ?? [], "lit": call?.lit ?? -1, "words": call?.words ?? "",
                    "heard": PageSnippets.shared.heardLast,
                    "editorMs": Bench.snippetShown ?? -1,
                    "editorUp": SnippetEditing.shared.card != nil,
                    "settingsWindow": SettingsWindow.shared.window?.windowNumber ?? 0,
                    "reading": SnippetEditing.shared.reading.map { [$0.state.rawValue, SnippetEditing.shared.readingNow] } ?? [],
                    "superhumanOffered": SnippetSuperhuman.offered,
                    "superhumanLast": SnippetSuperhuman.last.map { [$0.state, String($0.answer.prefix(2000))] } ?? [],
                    "toast": SettingsWindow.shared.toaster.shown ? SettingsWindow.shared.toaster.words : "",
                    "bring": SnippetEditing.shared.bring.map { bring -> [String: Any] in
                        ["source": bring.source.rawValue,
                         "rows": bring.found.map { ["name": $0.name, "body": $0.body, "note": $0.note ?? "", "take": $0.take, "to": $0.to, "subject": $0.subject] as [String: Any] }]
                    } ?? [String: Any](),
                    "sources": SnippetSource.found().map { ["source": $0.source.rawValue, "count": $0.count] as [String: Any] },
                    "recording": Keymap.shared.recording, "said": Keymap.shared.said,
                    // The recorder's popover, up over the card, and its window for a picture.
                    "popover": NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }?.windowNumber ?? 0,
                    "spot": call.map { ["x": $0.spot.minX, "y": $0.spot.minY, "w": $0.spot.width, "h": $0.spot.height] } ?? [:],
                    "offer": offer.map { ["text": $0.text, "name": $0.name, "count": $0.count] } ?? [:],
                    "place": browser.fieldShowing ? browser.query.place?.rawValue ?? "" : "",
                    "placeRows": browser.fieldShowing && browser.query.place == .snippets ? browser.placeItems.map(\.title) : []])

        case "probe":
            // The state of the window itself, for the bug that is not in a
            // page: which panels are up, whether something modal has the
            // app, and every window the app owns.
            let devLog = browser.active?.devLog
            var out: [String: Any] = [
                // A local page's sheet and what it has heard (DevMode.swift).
                "dev": [
                    "front": browser.devFront != nil, "open": browser.devOpen, "moving": browser.devMoving,
                    "side": browser.devSide.rawValue, "fitsBeside": DevLook.fitsBeside(browser.devRoomWidth), "bar": browser.barShown,
                    "errors": devLog?.errors ?? 0, "warnings": devLog?.warnings ?? 0,
                    "count": devLog?.entries.reduce(0) { $0 + $1.count } ?? 0,
                    "kinds": devLog?.entries.count ?? 0, "dropped": devLog?.dropped ?? 0,
                    "entries": devLog?.entries.map { "\($0.text) ×\($0.count)" } ?? [],
                    "issueFilter": "\(browser.issueFilter)",
                    "mono": DevMono.current,
                    "copied": String(Browser.benchCopied.prefix(4000)),
                    // A long copy's end, where its last line and that line's
                    // objects are, and how long the whole is.
                    "copiedEnd": String(Browser.benchCopied.suffix(4000)), "copiedCount": Browser.benchCopied.count,
                    "requests": devLog?.requests.count ?? 0,
                    // Each, oldest first: its row's spot is "request <id>" (spots).
                    "requestList": devLog?.requests.map { ["id": $0.id, "method": $0.method, "url": $0.url, "kind": $0.kind,
                                                           "sent": $0.sent ?? 0, "headers": $0.headers] as [String: Any] } ?? [],
                    "failed": devLog?.requests.filter(\.failed).count ?? 0,
                    // Network as the card's inspector heard it (DevNetBench.swift).
                    "net": browser.netProbe(),
                    // Console and the card's shell (DevConsoleBench.swift).
                    "console": browser.consoleProbe(),
                    "workbench": browser.workbenchProbe(),
                    "measure": browser.active?.measuring ?? false,
                    // Capture's stage (idle, picking, plate, editing).
                    "capture": browser.capture.stage.rawValue,
                    // A page that came as JSON, its door and card (JSONView.swift).
                    "json": browser.jsonProbe(),
                    // Measure's dock (MeasureDock.swift): what the page told
                    // it, and the sheet, the note field and Copied.
                    "measureDock": browser.active.map { tab -> [String: Any] in
                        let model = tab.measureModel
                        return ["details": model.details, "noting": model.noting, "copied": model.copiedNow,
                                "sel": model.info.sel.map { $0.name as Any } ?? NSNull(), "issues": model.info.issues,
                                "rows": model.info.rows.count, "rules": model.info.rules.count,
                                "motion": model.info.motion.count, "pins": model.info.pins.count, "notes": model.info.notes.count]
                    } ?? [:],
                    // The card's pane, and WebKit's inspector docked in it.
                    "pane": { switch browser.devPane {
                        case .errors: return "errors"
                        case .warnings: return "warnings"
                        case .network: return "network"
                        case .console: return "console"
                        case .elements: return "elements"
                        case .sources: return "sources"
                        case .performance: return "performance"
                        case .application: return "application"
                        case .memory: return "memory"
                        case .audit: return "audit"
                        case .layers: return "layers"
                        case .security: return "security"
                        case .recorder: return "recorder"
                        case .webkit(let web): return web.rawValue.lowercased()
                        case .panel(let title): return "panel:" + title
                    } }(),
                    "docked": browser.inspectorDock.docked != nil,
                    "inspected": browser.inspected != nil,
                    "inspectorInWindow": browser.inspectorDock.docked.flatMap { web -> [Double]? in
                        guard let content = web.window?.contentView else { return nil }
                        let r = web.convert(web.bounds, to: nil)
                        return [r.minX, content.bounds.height - r.maxY, r.width, r.height].map(Double.init)
                    } ?? [],
                    // WebKit's pane: its own Network is "network" too.
                    "webkit": browser.devPane.isWebKit,
                    "panels": browser.devPanels.map(\.title),
                    "device": browser.active?.device.map { ["name": $0.name, "width": $0.width, "height": $0.height, "ua": $0.userAgent ?? ""] as [String: Any] } ?? [:],
                    "overrides": browser.active?.devOverrides.map(\.rawValue).sorted() ?? [],
                    "pageFrame": browser.active?.webKitOnly("WebKit-only bench fixtures", build: false).map { web in [web.frame.minX, web.frame.minY, web.frame.width, web.frame.height, web.superview?.bounds.width ?? 0, web.superview?.bounds.height ?? 0] } ?? [],
                    "pageInWindow": browser.active?.webKitOnly("WebKit-only bench fixtures", build: false).flatMap { web -> [Double]? in
                        guard let content = web.window?.contentView else { return nil }
                        let r = web.convert(web.bounds, to: nil)
                        return [r.minX, content.bounds.height - r.maxY, r.width, r.height].map(Double.init)
                    } ?? [],
                    // The card in the window from its top left, where its
                    // edge was dragged to, and whether it is held now.
                    "card": [browser.devCard.minX, browser.devCard.minY, browser.devCard.width, browser.devCard.height].map(Double.init),
                    // A Chromium page in the window from its top left.
                    "chromiumPage": (browser.active?.builtPage as? ChromiumPage).flatMap { page -> [Double]? in
                        guard let content = page.window?.contentView else { return nil }
                        let r = page.convert(page.bounds, to: nil)
                        return [r.minX, content.bounds.height - r.maxY, r.width, r.height].map(Double.init)
                    } ?? [],
                    // The panel under the card's head, as AppKit has it now.
                    "paneInWindow": DevKeyClaim.pane(in: BrowserWindows.shared.window(for: browser)),
                    "dragged": ["height": DevSize.shared.height.map(Double.init) ?? 0, "width": DevSize.shared.width.map(Double.init) ?? 0],
                    "sizing": browser.devSizing,
                    // The chat's column beside it: as dragged, and as shown in
                    // this room (ChatLook.fit).
                    "chat": ["open": browser.chatOpen, "dragged": Double(browser.chatWidth), "shown": Double(ChatLook.width)],
                    "appearance": browser.active?.devAppearance ?? "",
                    "drawer": browser.devDrawer,
                    "recorder": browser.active.map { tab in ["recording": tab.recorder.recording, "stopping": tab.recorder.stopping, "playing": tab.recorder.playing ?? -1,
                                                             "failed": tab.recorder.failed?.why ?? "",
                                                             "steps": tab.recorder.steps.map { Recorder.words($0) + " | " + ($0.kind == .navigate ? $0.url : $0.selector) }] as [String: Any] } ?? [:],
                    "picking": browser.devPicking || browser.active?.webPicking == true,
                    "detached": browser.devDetached,
                    "detachedWindow": browser.devFloating.window?.windowNumber ?? 0,
                    "detachedFrame": browser.devFloating.window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map(Double.init) } ?? [],
                    "listening": browser.active?.devListening ?? false,
                ] as [String: Any],
                "settings": browser.tuning,
                "welcome": browser.welcoming,
                "passwords": browser.fieldShowing && browser.query.place == .passwords,
                "history": browser.fieldShowing && browser.query.place == .history,
                "downloads": browser.fieldShowing && browser.query.place == .downloads,
                "bookmarks": browser.fieldShowing && browser.query.place == .bookmarks,
                "field": browser.editing,
                // Asking where to go next, as ⌘T's field, not about the page.
                "asking": browser.fieldShowing && browser.askingNew,
                // The page standing under the field with no tab in front.
                "under": browser.underTab?.address?.absoluteString ?? "",
                // The field's place and its rows (Mail's commands, its times).
                "place": browser.fieldShowing ? browser.query.place?.rawValue ?? "" : "",
                "placeRows": !browser.fieldShowing ? [] : browser.query.place == .mail ? browser.query.offers.map(\.key) : browser.placeItems.map(\.title),
                "mailMode": browser.query.stock.mail.map { "\($0.mode)" } ?? "",
                // Each Mail row's end, its keys or its time, as drawn.
                "placeEnds": !browser.fieldShowing || browser.query.place != .mail ? [] : browser.query.offers.map { offer -> String in
                    if case .page(let what) = offer.kind, what.hasPrefix("mail:") { return Browser.mailRows[String(what.dropFirst(5))]?.end ?? "" }
                    return ""
                },
                // The page's own light or dark, as ⌘L's field wears it.
                "shade": browser.active?.shade.map { $0 == .dark ? "dark" : "light" } ?? "",
                "typed": browser.typed,
                "finding": browser.finding,
                // The tab under the pointer, as hovering tells it.
                "pointed": browser.glance.pointed.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                // The tab whose own hovering last said the pointer is on it,
                // and the tab whose card is up.
                "heard": browser.glance.heard.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                "glanced": browser.glance.shown.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                // Passkeys: whether this Mac lets yab use them, and what
                // pages have asked (a test run rehearses, see Passkeys).
                "passkeyAccess": { switch Passkeys.access {
                    case .authorized: return "authorized"
                    case .denied: return "denied"
                    default: return "notDetermined"
                } }(),
                "passkeyAsks": Passkeys.asked,
                "passkeyLast": Passkeys.last,
                "passkeyTrail": Passkeys.trail,
                // Chromium's WebAuthn requests as they came, and the
                // conditional gets pending (CEF 0127), without credentials.
                "chromiumWebAuthn": ChromiumWebAuthn.heard,
                "passkeyConditional": ChromiumWebAuthn.conditionalReport,
                "fieldWebAuthn": browser.active?.fieldWebAuthn ?? false,
                // The page's Web Inspector: up, and docked beside the page.
                "inspector": browser.active?.webKitOnly("WebKit-only bench fixtures", build: false).flatMap(Inspector.of).map { Inspector.asks($0, "isVisible") } ?? false,
                "inspectorDocked": browser.active?.webKitOnly("WebKit-only bench fixtures", build: false)?.superview?.subviews.contains { String(describing: type(of: $0)).hasPrefix("WKInspector") } ?? false,
                "suggesting": browser.suggesting != nil,
                // Whose accounts hang from the sign-in box, and the lit one.
                "suggestUsers": browser.suggesting?.logins.map(\.user) ?? [],
                // Every row of the list, any source (ManagerSuggestions.swift).
                "suggestRows": browser.suggesting?.list.map { ["id": $0.id, "title": $0.title, "detail": $0.detail,
                                                               "quick": $0.quick, "group": $0.group, "pickable": $0.pickable,
                                                               "away": $0.away ?? ""] } ?? [],
                "suggestWidth": browser.suggesting?.spot.width ?? 0,
                "suggestInsecure": browser.suggesting?.insecure ?? false,
                "plate": browser.fieldPlate.map { ["badge": $0.badge ?? "", "x": $0.frame.minX, "y": $0.frame.minY] } ?? [:],
                "agentFilling": browser.agentFilling?.title ?? "",
                "offer": browser.active?.offer?.login.host ?? "",
                // The sign-in box under the caret: whose, a frame's too, and where.
                "fieldOwner": browser.active?.fieldAddress?.host() ?? "",
                "fieldFramed": browser.active?.fieldFrame != nil,
                "fieldSpot": browser.active?.fieldSpot.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "keyWindow": browser.active?.builtPage?.window?.isKeyWindow ?? false,
                "pageCopy": browser.pageCopy.scriptsBenchState,
                // Why a box's list does or doesn't hang: offered here, and what the lookup holds.
                "autofillOffered": browser.active.map { browser.offersAutofill($0) } ?? false,
                "fieldAddressFull": browser.active?.fieldAddress?.absoluteString ?? "",
                "fillsPasswords": browser.prefs.fillsPasswords, "usesYabPasswords": browser.prefs.usesYabPasswords,
                "passwordSavingTakenBy": Extensions.shared.passwordSavingTakenBy ?? "",
                // Who has sign-in, card and address boxes, and what each
                // extension asked through chrome.privacy
                // (docs/password-manager-fields.md).
                "boxOwner": PasswordManagers.fieldOwner?.name ?? "",
                "cardOwner": PasswordManagers.walletOwner(cards: true)?.name ?? "",
                "addressOwner": PasswordManagers.walletOwner(cards: false)?.name ?? "",
                "privacy": Dictionary(Extensions.shared.installed.map { item in
                    (item.name, Extensions.settings(for: item.id).filter { $0.key.hasPrefix("privacy.") }.mapValues { "\($0)" })
                }, uniquingKeysWith: { a, _ in a }),
                "walletRows": browser.walletList.map { list in list.cards.count + list.addresses.count } ?? 0,
                "walletUp": browser.walletList != nil,
                "suggestLit": browser.lit ?? -1,
                // The codes hanging from a box that asks for one (MailCodes).
                "codes": browser.codeList?.codes.map { ["code": $0.code, "from": $0.from, "source": "\($0.source)", "mine": $0.mine] } ?? [],
                "codeLit": browser.codeLit ?? -1,
                "codeTexts": browser.codeList?.texts ?? false,
                "codeTextsShown": MailCodes.TextsRow.shown,
                "textsReadable": MailCodes.textsReadable,
                "offering": browser.active?.offer.map { $0.parked ? "parked" : "\($0.stage)" } ?? "",
                // Whose password the card asks about, and whether as an Update.
                "offerUser": browser.active?.offer?.login.user ?? "",
                "offerChanged": browser.active?.offer?.changed ?? false,
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                "backdrop": browser.prefs.backdrop.rawValue,
                "swatch": browser.prefs.swatch.rawValue,
                "custom": browser.prefs.backdropColor.hex,
                "sidebar": browser.prefs.sidebar,
                "flank": browser.prefs.sideFlank.rawValue,
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                // What the app is drawn in once the Mac's has been taken in.
                "effectiveAppearance": NSApp.effectiveAppearance.name.rawValue,
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
            ]
            if Store.testing {
                out["loginLookupPending"] = browser.loginLookupPending
                out["fillsPasswords"] = browser.prefs.fillsPasswords
                // What decides whether the box in front fills by itself.
                if let tab = browser.active {
                    out["fieldAutomatic"] = tab.fieldAutomatic
                    out["fieldEmpty"] = tab.fieldEmpty
                    out["fieldSecret"] = tab.fieldSecret
                    out["fieldAccount"] = tab.fieldAccount ?? ""
                    out["namedAccount"] = tab.address?.host().flatMap { tab.account(on: $0) } ?? ""
                }
            }
            out["windows"] = NSApp.windows.map { window -> [String: Any] in
                [
                    "kind": "\(type(of: window))",
                    "number": window.windowNumber,
                    "title": window.title,
                    "visible": window.isVisible,
                    "key": window.isKeyWindow,
                    "appearance": window.effectiveAppearance.name.rawValue,
                    "level": window.level.rawValue,
                    "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map(Bench.whole),
                ]
            }
            if let window = Links.window {
                out["lights"] = Bench.lights(of: window)
                // Where the page lies, from the window's top left, in points:
                // the biggest stage showing, the atlas reads the colors on
                // either side of its edge from a picture of the window.
                if let content = window.contentView {
                    func stages(in view: NSView) -> [StageView] {
                        view.subviews.flatMap { sub -> [StageView] in
                            (sub as? StageView).map { [$0] } ?? stages(in: sub)
                        }
                    }
                    let shown = stages(in: content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 }
                    if let stage = shown.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                        let r = stage.convert(stage.bounds, to: nil)
                        let height = window.frame.height
                        out["page"] = [r.minX, height - r.maxY, r.width, r.height].map { Double($0) }
                    }
                    out["size"] = [Double(content.bounds.width), Double(content.bounds.height)]
                }
                out["scale"] = Double(window.backingScaleFactor)
                out["window"] = window.windowNumber
                out["occluded"] = !window.occlusionState.contains(.visible)
            }
            out["keysQuieted"] = PageView.quieted
            // Who the keys go to now, in the key window.
            out["responder"] = (NSApp.keyWindow?.firstResponder).map { "\(type(of: $0))" } ?? "none"
            // What a sheet on the window holds, a name, a password's length: a test run only.
            if Store.testing, let sheet = Links.window?.attachedSheet { out["sheet"] = Bench.fields(of: sheet) }
            if Store.testing, let ask = browser.active?.asks.first, ask.signingIn {
                out["signIn"] = ["name": ask.text, "failed": ask.failed, "password": ask.secret.count]
            }
            answer(out)

        case "sheet":
            // A site's name and password asked for, in the card on the tab in
            // front or the sheet on the window: the name box given `name`,
            // the password `password`, and Sign In pressed, or `button`. A
            // --test run only: it answers for you.
            guard Store.testing else { answer(["error": "sheet only works on a --test run"]); return }
            if let tab = browser.active, let ask = tab.asks.first, ask.signingIn {
                let before: [String: Any] = ["name": ask.text, "failed": ask.failed, "password": ask.secret.count]
                if let name = request["name"] as? String { browser.typeAsk(tab, name) }
                if let password = request["password"] as? String { browser.typeSecret(tab, password) }
                let yes = (request["button"] as? String ?? "Sign In") == "Sign In"
                browser.answer(tab, yes ? .yes(tab.asks.first?.text) : .no)
                answer(["before": before, "pressed": yes ? "Sign In" : "Cancel"])
                return
            }
            guard let sheet = Links.window?.attachedSheet else { answer(["error": "no sheet"]); return }
            let before = Bench.fields(of: sheet)
            if let name = request["name"] as? String,
               let box = Bench.boxes(in: sheet.contentView).first(where: { !($0 is NSSecureTextField) }) {
                box.stringValue = name
            }
            if let password = request["password"] as? String,
               let box = Bench.boxes(in: sheet.contentView).first(where: { $0 is NSSecureTextField }) {
                box.stringValue = password
            }
            let buttons = Bench.buttons(in: sheet.contentView)
            let named = request["button"] as? String ?? "Sign In"
            let press = buttons.first { $0.title == named } ?? buttons.first { $0.keyEquivalent == "\r" }
            press?.performClick(nil)
            answer(["before": before, "pressed": press?.title ?? "", "buttons": buttons.map(\.title)])

        case "question":
            // The card up now answered as a hand would, and what it asked.
            // Only on a YAB_PROBE run.
            guard Store.testing else { answer(["error": "question only works on a --test run"]); return }
            guard let up = Questions.shared.current else { answer(["error": "no question up"]); return }
            Questions.shared.ticked = request["ticked"] as? Bool ?? false
            Questions.shared.answer(request["yes"] as? Bool ?? true)
            answer(["title": up.title, "yes": up.yes, "detail": up.detail, "lines": up.lines, "other": up.other ?? ""])

        case "question-up":
            // A question raised and left up, for a picture of where it
            // stands: `place` page (dimmed, the default) or plain. Answer it
            // with "question". Only on a YAB_PROBE run.
            guard Store.testing else { answer(["error": "question-up only works on a --test run"]); return }
            // `sample` "install": adding an extension, as RoboForm asks;
            // `unfolded` opens its "N more". "extension-more": Figma's
            // permissions.request, every site with its capture permissions.
            let place: Question.Place = request["place"] as? String == "plain" ? .plain : .page
            // "apple-pairing": Passwords' code card, `code` typed so far and
            // `wrong` after a refused one. With `pid`, the pairing's own
            // question beside that process's window, in its own panel, as
            // Settings' Connect raises it (R2564: "pairing-state" says what
            // holds its keys).
            let pairing = ApplePasswordsPairing.CodeModel()
            pairing.code = request["code"] as? String ?? ""
            pairing.wrong = request["wrong"] as? Bool ?? false
            Bench.pairing = pairing
            let helper = (request["pid"] as? Int).map { Int32($0) }
            let asked = request["sample"] as? String == "apple-pairing"
                ? helper != nil
                ? ApplePasswordsPairing.connectQuestion(model: pairing, anchor: QuestionAnchor(processIdentifier: helper))
                : Question(title: "Connect Apple Passwords", detail: "Enter the code Passwords shows.",
                           icon: PasswordManagers.icon(PasswordManagers.apple), ownIcon: true,
                           yes: "", no: "Not Now", place: .plain,
                           accessory: AnyView(ApplePasswordsPairing.PairingField(model: pairing)))
                : request["sample"] as? String == "password-import"
                ? PasswordsToApple.question(count: 1164)
                : request["sample"] as? String == "extension-more"
                ? Question(title: "Figma wants more access",
                           lines: Extensions.wants(sites: [try? WKWebExtension.MatchPattern(string: "<all_urls>")].compactMap { $0 },
                                                   permissions: ["pageCapture", "scripting", "clipboardWrite"]),
                           glyph: "puzzlepiece.extension", yes: "Allow", no: "Don’t Allow", place: .plain)
                : request["sample"] as? String == "install"
                ? Question(title: "Add “RoboForm Password Manager”?", detail: "It will read and change every site you visit.",
                           folded: ["See which tabs you have open, and where", "Read and set cookies", "Follow where you browse",
                                    "Watch what pages load", "Talk to other apps on your Mac", "Run its own code on pages",
                                    "Change Yab's privacy settings"],
                           foldedNote: "It may ask later to " + Extensions.listed(["read and edit your bookmarks", "see the sites you visit most",
                                                                                   "put things on your clipboard"]) + ".",
                           yes: "Add", place: place)
                : Question(title: request["title"] as? String ?? "Delete New?",
                           detail: "Its tab closes; ⇧⌘T brings it back.", glyph: "trash",
                           yes: "Delete", danger: true, place: place)
            // `windows` N: browser windows opened until there are N, and
            // `front` the index of the one put in front to ask from; the
            // answer says which windows show the card (#1097).
            let windows = BrowserWindows.shared
            if let count = request["windows"] as? Int {
                while windows.normalBrowsers.count < count {
                    _ = windows.newWindow(from: windows.activeBrowser)
                }
            }
            let browserWindows = { windows.normalBrowsers.compactMap { windows.window(for: $0) }.filter(\.isVisible) }
            if let front = request["front"] as? Int, browserWindows().indices.contains(front) {
                NSApp.activate(ignoringOtherApps: true)
                browserWindows()[front].makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["windows"] == nil ? 0 : 0.6)) {
                Task { _ = await Questions.shared.ask(asked) }
                if request["unfolded"] as? Bool == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Questions.shared.unfolded = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    answer(["up": Questions.shared.current?.title ?? "",
                            "asked": Questions.shared.current?.window ?? 0,
                            "key": NSApp.keyWindow?.windowNumber ?? 0,
                            "windows": browserWindows().map(\.windowNumber),
                            "shownIn": Questions.shared.shownIn.sorted()])
                }
            }

        case "pairing-state":
            // The pairing card up beside its helper (question-up `pid`): the
            // code its strip holds, whether Yab and the card have the keys,
            // and which view of the card takes them. Only on a YAB_PROBE run.
            guard Store.testing else { answer(["error": "pairing-state only works on a --test run"]); return }
            let panel = Questions.shared.current?.anchor?.panel
            let responder = panel?.firstResponder
            var holder = responder.map { String(describing: type(of: $0)) } ?? "none"
            if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate {
                holder = "field editor of " + String(describing: type(of: owner))
            }
            func fields(_ view: NSView?) -> [String] {
                guard let view else { return [] }
                return (view is NSTextField ? [String(describing: type(of: view))] : []) + view.subviews.flatMap(fields)
            }
            answer(["code": Bench.pairing?.code ?? "", "active": NSApp.isActive,
                    "panel": panel?.windowNumber ?? 0, "panelVisible": panel?.isVisible ?? false,
                    "panelKey": panel?.isKeyWindow ?? false, "keyWindow": NSApp.keyWindow?.windowNumber ?? 0,
                    "responder": holder, "fields": fields(panel?.contentView),
                    "fullKeyboardAccess": NSApp.isFullKeyboardAccessEnabled,
                    "front": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
                    "pid": Int(ProcessInfo.processInfo.processIdentifier)])

        case "restart":
            // Quit and come back the way an update restarts Yab
            // (Updater.relaunch). Only on a YAB_PROBE run: it quits.
            guard Store.testing else { answer(["error": "restart only works on a --test run"]); return }
            answer(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Updater.shared.relaunch(behind: request["behind"] as? Bool ?? false) }

        case "quit-ask":
            // ⌘Q's way, its question and the answer given as a hand would:
            // Quit (or Quit When Done), the box ticked (or Stop and Quit),
            // or Cancel.
            // Only on a YAB_PROBE run: it quits.
            guard Store.testing else { answer(["error": "quit-ask only works on a --test run"]); return }
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let asked = Questions.shared.current.map { ["title": $0.title, "detail": $0.detail, "yes": $0.yes, "box": $0.box ?? "", "other": $0.other ?? ""] } ?? [:]
                Questions.shared.ticked = request["ticked"] as? Bool ?? false
                Questions.shared.answer(request["yes"] as? Bool ?? true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    answer(["asked": asked, "status": Headless.status])
                }
            }

        case "leave":
            // A page's "Leave this page?" (LeavePage.swift), as a hand
            // sets it off: `act` "close" (⌘W on the tab in front), "window"
            // (the window's red button), "reload" (⌘R), or nothing; then
            // what is being asked and what waits on an answer. Test runs only.
            guard Store.testing else { answer(["error": "leave only works on a --test run"]); return }
            switch request["act"] as? String ?? "" {
            case "close": browser.shut(browser.chosen, byKey: true)
            case "window": BrowserWindows.shared.window(for: browser)?.performClose(nil)
            case "reload": browser.reload()
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 0.6)) {
                let leaving = BrowserWindows.shared.browsers.flatMap(\.pagesHeld).filter { $0.asks.contains { $0.kind == .leave } }
                answer(["asking": leaving.map { String($0.id.uuidString.prefix(8)).lowercased() },
                        "waits": Leaving.waits.count, "shown": Leaving.shown,
                        "windows": BrowserWindows.shared.openWindows().count])
            }

        case "front-keys":
            // Keys as the keyboard sends them to the window in front, the
            // small window's or the browser's, menus and monitors and all:
            // "cmd-q", "esc", "return". Answers the question up, the window
            // in front, and the windows a picture of each needs. Nothing
            // answers ⌘Q's question here: a --test run only, it can quit.
            guard Store.testing else { answer(["error": "front-keys only works on a --test run"]); return }
            NSApp.activate(ignoringOtherApps: true)
            if let small = LinkWindow.all.last, request["small"] as? Bool == true { small.window.makeKeyAndOrderFront(nil) }
            // `window`: that one put in front first, by number.
            if let number = request["window"] as? Int, let window = NSApp.window(withWindowNumber: number) { window.makeKeyAndOrderFront(nil) }
            // The small window's own too: ⌘L's field, ⇧⌘C's copy, ⌥⌘O's
            // spaces, the arrows in a list, ⌘O's keep; a single letter is
            // typed as itself.
            let presses: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
                "cmd-q": (12, "q", [.command]), "esc": (53, "\u{1b}", []), "return": (36, "\r", []),
                "cmd-w": (13, "w", [.command]), "cmd-r": (15, "r", [.command]), "shift-cmd-w": (13, "w", [.shift, .command]),
                "cmd-l": (37, "l", [.command]), "shift-cmd-c": (8, "c", [.shift, .command]),
                "opt-cmd-o": (31, "o", [.option, .command]), "cmd-o": (31, "o", [.command]),
                "down": (125, String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!), [.function, .numericPad]),
                "up": (126, String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), [.function, .numericPad]),
            ]
            for name in request["keys"] as? [String] ?? [] {
                let typed = name.count == 1 ? (Bench.keyCode(for: Character(name)), name, NSEvent.ModifierFlags()) : nil
                guard let (code, chars, flags) = presses[name] ?? typed, let window = NSApp.keyWindow else {
                    answer(["error": "no key named \(name) or no window in front"])
                    return
                }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: chars,
                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
                    ) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.8)) {
                let key = NSApp.keyWindow
                answer([
                    "question": Questions.shared.current?.title ?? "",
                    "front": key.map { LinkWindow.owning($0) != nil ? "small" : $0 === Links.window ? "browser" : "\(type(of: $0))" } ?? "none",
                    "browserWindow": Links.window?.windowNumber ?? 0,
                    "small": LinkWindow.all.map(\.window.windowNumber),
                    // Whether each small window shows the question.
                    "smallAsks": LinkWindow.all.map(\.asking),
                    "key": key?.windowNumber ?? 0,
                    "shownIn": Questions.shared.shownIn.sorted(),
                    "peeking": browser.peeking != nil,
                ])
            }

        case "print":
            // The print sheet: "menu" as ⌘P and File › Print do, "page" as
            // a site's own window.print() from the tab in front (`peek`:
            // from the peek's page), "pdf" the sheet's Save as PDF to
            // `path`, "cancel" the sheet put away; with each, whether a
            // sheet is up and the page it prints. A --test run only.
            guard Store.testing else { answer(["error": "print only works on a --test run"]); return }
            let web = (request["peek"] as? Bool == true ? browser.peeking : browser.active)?.webKitOnly("WebKit-only bench fixtures", build: false)
            let window = BrowserWindows.shared.window(for: browser)
            switch request["act"] as? String ?? "status" {
            case "menu": browser.printPage()
            // `js`: another print() of the page's, as an iframe's.
            case "page": web?.evaluateJavaScript(request["js"] as? String ?? "window.print(); 1", in: nil, in: .page) { _ in }
            case "cancel": if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            case "pdf":
                guard let web, let path = request["path"] as? String else { answer(missing(request)); return }
                let file = URL(fileURLWithPath: path)
                PageSave.pdf(web, to: file) { result in
                    let document = PDFDocument(url: file)
                    switch result {
                    case .success: answer(["saved": path, "pages": document?.pageCount ?? 0, "readable": PageSave.readable(file),
                                           "text": String((document?.string ?? "").prefix(2000))])
                    case .failure(let error): answer(["error": error.localizedDescription])
                    }
                }
                return
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 1.5)) {
                let sheet = window?.attachedSheet
                answer(["sheet": sheet != nil, "sheetClass": sheet.map { "\(type(of: $0))" } ?? "",
                        "sheetFrame": sheet.map { NSStringFromRect($0.frame) } ?? "", "sheetWindow": sheet?.windowNumber ?? 0,
                        "window": window?.windowNumber ?? 0, "printed": Browser.printed?.absoluteString ?? "",
                        "peeking": browser.peeking != nil])
            }

        case "page-keys":
            // Keys on the tab in front as the keyboard sends them, flags and
            // all, queued for its window the way a hand's arrive, and how
            // many reached the end of the window's responder chain unused,
            // each one a beep (Beeps). `url`: that page opened in front
            // first, its tab's id in the answer. `popup`: on the extension
            // popup that is open instead. A --test run only: it types
            // into the page.
            guard Store.testing else { answer(["error": "page-keys only works on a --test run, it would type into your page"]); return }
            Beeps.watch()
            if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
                let tab = browser.open(url, foreground: true)
                answer(["id": tab.id.uuidString])
                return
            }
            let popup = request["popup"] as? Bool == true
            let view: NSView? = popup ? ExtensionPopup.shared.view : browser.active?.page
            guard let view, let window = view.window else { answer(["error": popup ? "no popup open" : "no page in front"]); return }
            NSApp.activate(ignoringOtherApps: true)
            if popup { window.makeKey() } else { window.makeKeyAndOrderFront(nil) }
            if request["focus"] as? Bool ?? true { window.makeFirstResponder(view) }
            let names = request["keys"] as? [String] ?? []
            let beeps = Beeps.count, quieted = PageView.quieted, before = browser.active?.id
            for name in names {
                guard let key = Beeps.key(name) else { answer(["error": "no key named \(name)"]); return }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: key.flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: key.chars, charactersIgnoringModifiers: key.chars == "}" ? "]" : key.chars,
                        isARepeat: false, keyCode: key.code
                    ) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 1.0)) {
                answer(["beeps": Beeps.count - beeps, "quieted": PageView.quieted - quieted,
                        "tabChanged": browser.active?.id != before, "key": window.isKeyWindow,
                        "responder": (window.firstResponder).map { "\(type(of: $0))" } ?? "none",
                        "window": "\(type(of: window))"])
            }

        case "key":
            // Keys pressed on a tab, as real key events handed to its view,
            // for what the page does with them, and what comes back unused.
            // Only on a YAB_PROBE run: it types into a page.
            guard Store.testing else { answer(["error": "key only works on a --test run, it would type into your page"]); return }
            guard let tab = find(request, in: browser), let text = request["text"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.page
            view.window?.makeFirstResponder(view)
            let before = PageView.quieted
            // What WebKit sends back through the app because the page didn't
            // use it: a key press seen here again after it was handed over.
            var pressed: [NSEvent] = []
            var resent = 0
            let watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if pressed.contains(where: { PageView.same($0, event) }) { resent += 1 }
                return event
            }
            for character in text {
                let chars = String(character)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: view.window?.windowNumber ?? 0, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: Bench.keyCode(for: character)
                    ) else { continue }
                    if type == .keyDown { pressed.append(event); view.keyDown(with: event) } else { view.keyUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let watch { NSEvent.removeMonitor(watch) }
                answer(["typed": text, "sentBackUnused": resent, "quieted": PageView.quieted - before])
            }

        case "resize":
            // The window taken to another size in steps, a frame apart, the
            // way a hand drags its corner, for what that does to the title
            // bar. It moves the window, so only on a YAB_PROBE run.
            guard Store.testing else {
                answer(["error": "resize only works on a --test run, it would move your window"])
                return
            }
            // `browserWindow`: that window, though another is in front.
            let named = request["browserWindow"] != nil ? BrowserWindows.shared.window(for: browser) : nil
            guard let window = named ?? Links.window,
                  let width = request["width"] as? Double, let height = request["height"] as? Double
            else { answer(["error": "resize needs a width and a height"]); return }
            let steps = max(1, request["steps"] as? Int ?? 12)
            let from = window.frame
            func step(_ n: Int) {
                let t = CGFloat(n) / CGFloat(steps)
                var frame = from
                frame.size.width = from.width + (CGFloat(width) - from.width) * t
                frame.size.height = from.height + (CGFloat(height) - from.height) * t
                frame.origin.y = from.maxY - frame.height
                window.setFrame(frame, display: true)
                if n < steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        answer(["size": [Int(window.frame.width), Int(window.frame.height)], "lights": Bench.lights(of: window)])
                    }
                }
            }
            step(1)

        case "window":
            // The window as macOS moves it (WindowDrag): its frame and its
            // screen's in the window server's points, from the top left of
            // the first screen, whether it may be moved and the band AppKit
            // would drag it by, and the Window menu's items as validation
            // leaves them. `menu`, an item's title (a submenu's as "Move &
            // Resize/Left"), chooses it as the menu would; `frame`, [x, y,
            // width, height] the same way, puts the window there first;
            // `small` asks about the newest small window for a link; `hit`,
            // points from the window's top left, says which view a press
            // there lands on. Both moves only on a YAB_PROBE run.
            let small = request["small"] as? Bool == true
            guard let window = small ? LinkWindow.all.last?.window : Links.window else { answer(["error": "no window"]); return }
            // `heard`: from now on, what of the pointer reaches the window,
            // its moves and the areas it comes into and leaves, and what
            // the green button's cell is told (WindowHeard).
            if request["heard"] as? Bool == true { WindowHeard.start(window) }
            // `moves`: from now on, every change of its size and of the
            // sizes it is held to, with who made it (WindowMoves).
            if request["moves"] as? Bool == true { WindowMoves.start(window) }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            func flip(_ r: NSRect) -> [Double] { [r.minX, top - r.maxY, r.width, r.height].map { Double($0) } }
            if request["frame"] != nil || request["menu"] != nil {
                guard Store.testing else { answer(["error": "window only moves on a --test run"]); return }
            }
            if let frame = request["frame"] as? [Double], frame.count == 4 {
                window.setFrame(NSRect(x: frame[0], y: top - frame[1] - frame[3], width: frame[2], height: frame[3]), display: true)
            }
            func items(_ menu: NSMenu?) -> [[String: Any]] {
                guard let menu else { return [] }
                menu.update()
                return menu.items.filter { !$0.isSeparatorItem }.map { item in
                    var out: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "hidden": item.isHidden,
                                              "action": item.action.map(NSStringFromSelector) ?? ""]
                    if let sub = item.submenu { out["items"] = items(sub) }
                    return out
                }
            }
            var chose = ""
            if let path = (request["menu"] as? String)?.split(separator: "/").map(String.init), !path.isEmpty {
                window.makeKeyAndOrderFront(nil)
                var menu = NSApp.windowsMenu
                for (n, title) in path.enumerated() {
                    guard let found = menu, let index = found.items.firstIndex(where: { $0.title == title }) else { chose = "no \(title)"; break }
                    found.update()
                    if n == path.count - 1 {
                        chose = found.items[index].isEnabled ? "chose" : "disabled"
                        if found.items[index].isEnabled { found.performActionForItem(at: index) }
                    } else {
                        menu = found.items[index].submenu
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.1)) {
                let screen = window.screen
                let hits = (request["hit"] as? [[Double]] ?? []).map { at -> String in
                    guard at.count == 2, let content = window.contentView,
                          let view = content.hitTest(NSPoint(x: at[0], y: content.bounds.height - at[1])) else { return "" }
                    return "\(type(of: view))"
                }
                answer([
                    "hit": hits,
                    "number": window.windowNumber, "class": "\(type(of: window))",
                    "frame": flip(window.frame),
                    "visible": screen.map { flip($0.visibleFrame) } ?? [],
                    "screen": screen.map { flip($0.frame) } ?? [],
                    "movable": window.isMovable, "background": window.isMovableByWindowBackground,
                    "taught": WindowDrag.taught(window),
                    "band": WindowDrag.shape(of: window).map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [],
                    "zoomed": window.isZoomed, "mini": window.isMiniaturized, "full": window.styleMask.contains(.fullScreen),
                    "doubleClick": String(describing: StripPress.now),
                    "nativeDoubleClick": StripPress.titleBar.map { String(describing: $0) } ?? "unavailable",
                    "modal": NSApp.modalWindow?.windowNumber ?? 0,
                    "sheet": window.attachedSheet?.windowNumber ?? 0,
                    "key": window.isKeyWindow, "active": NSApp.isActive,
                    "lights": Bench.lights(of: window),
                    "green": Lights.rows(in: window.contentView).first { $0.visibleRect.width > 0 }?.green ?? [:],
                    "rows": Lights.rows(in: window.contentView).map(\.green),
                    "heard": WindowHeard.log,
                    "moves": WindowMoves.log,
                    "menu": items(NSApp.windowsMenu), "chose": chose,
                ])
            }

        case "fullscreenchrome":
            guard let window = BrowserWindows.shared.window(for: browser), let content = window.contentView else {
                answer(["error": "no window"]); return
            }
            func rect(_ view: NSView) -> [Double] {
                let r = (view.window ?? window).convertToScreen(view.convert(view.bounds, to: nil))
                return [r.minX, r.minY, r.width, r.height].map(Double.init)
            }
            func visible(_ view: NSView) -> CGFloat {
                guard !view.isHiddenOrHasHiddenAncestor, let owner = view.window, owner.isVisible,
                      let screen = owner.screen else { return 0 }
                let r = owner.convertToScreen(view.convert(view.visibleRect, to: nil)).intersection(screen.frame)
                return r.isNull ? 0 : r.height
            }
            let strip = StripView.of(browser)
            let title = Lights.titleBar(of: window)
            answer([
                "content": rect(content), "strip": strip.map(rect) ?? [],
                "stripVisible": strip.map { visible($0) > 1 } ?? false,
                "stripVisibleHeight": Double(strip.map(visible) ?? 0),
                "stripWindow": strip?.window?.windowNumber ?? 0,
                "title": title.map(rect) ?? [],
                "titleVisible": title.map { visible($0) > 1 } ?? false,
                "titleVisibleHeight": Double(title.map(visible) ?? 0),
                "titleWindow": title?.window?.windowNumber ?? 0,
                "menuOut": browser.menuOut, "menuDown": Double(browser.menuDown),
                "stripPeek": browser.stripPeek, "full": browser.fullScreen,
                "accessories": window.titlebarAccessoryViewControllers.map { rect($0.view) },
            ])

        case "edge":
            // The pointer, as Brim sees it, put somewhere against the window
            // without moving the real one, for a put-away column coming out
            // from the left edge and going back, or a put-away strip from
            // the top edge ("stripShut"). `at` is from the window's
            // top left, x in from its left edge (less than 0 is past it),
            // y down from its top; `let` gives the real pointer back. `hand`
            // says the page shows its pointing hand there, over a link or a
            // button, and `press` presses there, for the lights' corner.
            // `front` takes the window as the one in front, the way it is
            // under a hand, where another app keeps the focus from a probe.
            // `menu` takes a menu as open, a tab's, say, or closed again.
            // The answer says what a click at the pointer would reach
            // (`hit`) and whether something hanging from the strip keeps it
            // out (`held`), or from the column (`columnHeld`).
            // With `frame`, [left, top, width, height] on the screen from
            // its visible area's top left, the window is put there first.
            // Then, after `wait`, where the column is. It moves the window,
            // so only on a YAB_PROBE run.
            guard Store.testing else { answer(["error": "edge only works on a --test run, it would move your window"]); return }
            guard let window = Links.window else { answer(["error": "no window"]); return }
            if let frame = request["frame"] as? [Double], frame.count == 4, let area = window.screen?.visibleFrame {
                window.setFrame(NSRect(x: area.minX + frame[0], y: area.maxY - frame[1] - frame[3], width: frame[2], height: frame[3]), display: true)
            }
            if let shut = request["shut"] as? Bool { browser.prefs.sidebar = true; browser.prefs.sideShut = shut }
            // The same for the strip, with the tabs across the top: put away
            // or in its place, and not out over the page (Browser.putStrip).
            if let shut = request["stripShut"] as? Bool { browser.prefs.sidebar = false; browser.putStrip(away: shut) }
            if request["let"] as? Bool == true { Brim.benchPointer = nil; Brim.benchHand = false; Brim.benchFront = false; Brim.benchMenu = false }
            if let front = request["front"] as? Bool { Brim.benchFront = front }
            if let menu = request["menu"] as? Bool { Brim.benchMenu = menu }
            if let at = request["at"] as? [Double], at.count == 2 {
                Brim.benchPointer = NSPoint(x: window.frame.minX + at[0], y: window.frame.maxY - at[1])
            }
            if let hand = request["hand"] as? Bool { Brim.benchHand = hand }
            if request["press"] as? Bool == true { Brim.benchPress(in: window) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0)) {
                let frame = window.frame
                let area = window.screen?.visibleFrame ?? .zero
                // What AppKit hands a click at the bench's pointer.
                var hit = "nothing"
                if let pointer = Brim.benchPointer, let content = window.contentView, let frameView = content.superview {
                    let at = frameView.convert(window.convertPoint(fromScreen: pointer), from: nil)
                    hit = content.hitTest(at).map { String(describing: type(of: $0)) } ?? "nothing"
                }
                // ⌘S's item in the menu bar, with `menuItem`: what it says,
                // whether it can be picked and its key, its menu brought up
                // to date first as the menu bar opening it would have it.
                // Not on every ask: a menu opening puts a tab's card away.
                func columnItem(in menu: NSMenu?) -> NSMenuItem? {
                    for entry in menu?.items ?? [] {
                        if ["Hide Sidebar", "Show Sidebar", "Hide Tab Bar", "Show Tab Bar"].contains(entry.title) { return entry }
                        if let deeper = columnItem(in: entry.submenu) { return deeper }
                    }
                    return nil
                }
                var column: NSMenuItem?
                if request["menuItem"] as? Bool == true {
                    if let menu = columnItem(in: NSApp.mainMenu)?.menu {
                        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
                        menu.delegate?.menuNeedsUpdate?(menu)
                        menu.update()
                        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu)
                    }
                    column = columnItem(in: NSApp.mainMenu)
                }
                answer([
                    "peek": browser.sidePeek, "shut": browser.prefs.sideShut, "sidebar": browser.prefs.sidebar,
                    "strip": browser.stripPeek, "stripShut": browser.prefs.stripShut, "stripCard": browser.stripCard,
                    "stripMoving": browser.stripMoving, "held": Brim.benchHeld(in: window, browser),
                    "menuOut": browser.menuOut, "menuDown": Double(browser.menuDown),
                    "columnHeld": Brim.benchColumnHeld(in: window, browser), "hit": hit,
                    "menu": column.map { [$0.title, $0.isEnabled ? "enabled" : "disabled", $0.keyEquivalentModifierMask == .command ? "⌘" + $0.keyEquivalent : $0.keyEquivalent] } ?? [],
                    "key": window.isKeyWindow, "main": window.isMainWindow, "full": browser.fullScreen,
                    "frame": [frame.minX - area.minX, area.maxY - frame.maxY, frame.width, frame.height].map { Double($0) },
                ])
            }

        case "ui":
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            // Settings as it was before #202, a window macOS keeps on the
            // desktop's Space, for the eval's control case.
            if request["settingsOldSpace"] as? Bool == true {
                SettingsWindow.shared.window?.collectionBehavior.subtract([.fullScreenAuxiliary, .moveToActiveSpace])
            }
            // Each of our windows shown: on the Space in front or not, in
            // full screen or not (evals/settings-space).
            if request["spaces"] as? Bool == true {
                answer(["active": NSApp.isActive, "windows": NSApp.windows.filter { $0.isVisible }.map { window in [
                    "title": window.title, "kind": String(describing: type(of: window)),
                    "onActiveSpace": window.isOnActiveSpace, "full": window.styleMask.contains(.fullScreen),
                    "key": window.isKeyWindow, "auxiliary": window.collectionBehavior.contains(.fullScreenAuxiliary),
                    "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { Double($0) },
                ] as [String: Any] }])
                return
            }
            // The column's density, as Appearance sets it (Density).
            if let density = (request["density"] as? String).flatMap(Density.init) { browser.prefs.density = density }
            // ⌘S giving the page its width on the way, or once at the end
            // as before, to weigh what it costs (StageView.following).
            if let on = request["fold"] as? Bool { StageView.follows = on }
            // A local page's sheet, in or away, and which side (DevMode.swift).
            if request["devdetach"] as? Bool == true { browser.detachDevTools() }
            if let on = request["devsheet"] as? Bool, on != browser.devOpen { browser.toggleDevSheet() }
            // The chat's column beside the page, as its menu command puts
            // it out or away (ChatColumn.swift).
            if let on = request["chat"] as? Bool, on != browser.chatOpen { browser.toggleChat() }
            if let side = (request["devside"] as? String).flatMap(DevSide.init) { browser.setDevSide(side) }
            // The Fixed-width font, as Appearance > Fonts > Customize sets it;
            // DevTools sets its code in it too (DevMono.swift).
            if let fixed = request["fixedfont"] as? String { browser.prefs.pageFonts.fixed = fixed }
            // Rulers over the local page in front (Measure.swift); drive them
            // with `eval` in the yab world: window.__yabMeasure.bench({...}).
            // Developer Mode for the server of the page in front, as its card
            // or the View menu would turn it (DevMode.swift).
            if let on = request["devmode"] as? Bool, let tab = browser.active { browser.setDevMode(tab, on) }
            // Automatic Picture in Picture for the site in front, as its
            // This site row turns it (a --test run only, it is a setting).
            if Store.testing, let on = request["autoPiP"] as? Bool { AutomaticPiPSites.shared.setAllowed(on, for: browser.active?.address) }
            if let on = request["measure"] as? Bool { browser.active?.measure(on) }
            // JSON shown as a tree (JSONView.swift): the setting, the card,
            // Tree or Text, Copy, Save, Expand All, the band's error word.
            if let asked = request["json"] as? [String: Any] { browser.jsonBench(asked) }
            // Measure's dock: its sheet out or in, as Space would, and its
            // buttons by what they ask of the page (MeasureDock.swift).
            if let on = request["measuredetails"] as? Bool, let model = browser.active?.measureModel, model.details != on { model.toggleDetails() }
            if let asked = request["measureact"] as? [String: Any] { browser.active?.measureAct(asked) }
            // The band's </>: WebKit's inspector, asked for by name.
            if request["webinspector"] as? Bool == true { browser.showInInspector(console: false) }
            // The card, on a pane: errors, warnings, network, or one of
            // WebKit's by its name (elements, console, sources...).
            if let name = request["devpane"] as? String {
                let pane: DevPane? = ["errors": .errors, "warnings": .warnings, "network": .network, "security": .security, "recorder": .recorder,
                                      "console": .console, "elements": .elements, "sources": .sources, "performance": .performance,
                                      "memory": .memory, "application": .application, "audit": .audit, "layers": .layers][name]
                    ?? WebPane.allCases.first { $0.rawValue.lowercased() == name || "webkit:" + $0.rawValue.lowercased() == name }.map { .webkit($0) }
                    // An extension's panel by the start of its title: "panel:Components".
                    ?? (name.hasPrefix("panel:") ? browser.devPanels.first { $0.title.hasPrefix(String(name.dropFirst(6))) }.map { .panel($0.title) } : nil)
                if let pane { browser.devOpen ? browser.pickDevPane(pane) : browser.openDevTools(pane) }
            }
            if request["devtools"] as? Bool == false { browser.closeDevTools() }
            // The undocked window moved and sized, as a hand would: x, y, width, height.
            if let frame = request["devwindow"] as? [Double], frame.count == 4, let window = browser.devFloating.window {
                window.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: true)
            }
            // The head's menus and buttons, by what they do (DevHead.swift).
            if let name = request["device"] as? String, let tab = browser.active {
                if name == "off" { tab.setDevice(nil) }
                else if name == "toggle" { browser.toggleDevice() }
                else if let preset = DeviceMode.presets.first(where: { $0.name == name }) {
                    tab.setDevice(DeviceMode(name: preset.name, width: preset.width, height: preset.height, userAgent: preset.userAgent))
                }
            }
            if let raw = request["devoverride"] as? String, let setting = DevOverride(rawValue: raw) { browser.toggleDevOverride(setting) }
            if let look = request["devappearance"] as? String { browser.setDevAppearance(look.isEmpty ? nil : look) }
            if request["devdrawer"] as? Bool == true { browser.toggleDevDrawer() }
            if request["devdetach"] as? Bool == true { browser.detachDevTools() }
            if request["askdev"] as? Bool == true { browser.askAboutDev() }
            // The list of what went wrong (DevIssues.swift): its filter, and
            // Copy for Agent as its button and its menu do it.
            if let name = request["issuefilter"] as? String {
                let filter: IssueFilter = ["all": .all, "errors": .errors, "warnings": .warnings, "requests": .requests][name] ?? .errors
                browser.issueFilter = filter
                browser.devPane = filter == .warnings ? .warnings : .errors
            }
            if let what = request["copyissues"] as? String, let tab = browser.active {
                switch what {
                case "everything": browser.copyEverything(tab)
                case "errors": browser.copyIssues(tab.devLog.issues(.errors), on: tab)
                default: browser.copyIssues(tab.devLog.issues(browser.issueFilter), on: tab)
                }
            }
            // A real press and release on the page in front, at CSS pixels,
            // as a hand's: for what the Recorder writes down. Test runs only.
            // "pageclickkeys": "cmd" or "cmd+shift", for a link opened
            // beside the page.
            // The pointer brought over the page in front and left there.
            if Store.testing, let at = request["pagehover"] as? [Double], at.count == 2, let tab = browser.active {
                _ = AgentPage.hover(tab.page, x: at[0], y: at[1])
            }
            if Store.testing, let at = request["pageclick"] as? [Double], at.count == 2, let tab = browser.active {
                let keys = request["pageclickkeys"] as? String ?? ""
                let flags: NSEvent.ModifierFlags = keys.isEmpty ? [] : Bench.chord(keys)?.0 ?? []
                _ = AgentPage.hover(tab.page, x: at[0], y: at[1])
                _ = AgentPage.click(tab.page, x: at[0], y: at[1], flags: flags)
            }
            if let what = request["record"] as? String, let tab = browser.active {
                switch what {
                case "start": tab.recorder.start(tab)
                case "stop": tab.recorder.stop()
                case "play": tab.recorder.play(tab)
                case "clear": tab.recorder.clear()
                case "json": answer(["json": tab.recorder.chromeJSON(title: "bench"), "agent": tab.recorder.forAgent(page: tab.address)]); return
                default: break
                }
            }
            // Console and the card's shell, driven as a hand would.
            if let workbench = request["workbench"] as? [String: Any] {
                browser.workbenchBench(workbench) { answer($0) }
                return
            }
            if let console = request["console"] as? [String: Any] {
                browser.consoleBench(console) { answer($0) }
                return
            }
            // Network's panel, driven as a hand would (DevNetBench.swift).
            if let net = request["net"] as? [String: Any] {
                browser.netBench(net) { answer($0) }
                return
            }
            // JavaScript in WebKit's inspector's own page, docked in the card.
            if let js = request["inspectorjs"] as? String {
                guard let web = browser.inspectorDock.docked else { answer(["error": "not docked"]); return }
                web.evaluateJavaScript(js) { value, error in
                    answer(["value": value.map { "\($0)" } ?? "", "error": error.map { "\($0)" } ?? ""])
                }
                return
            }
            // Inspect Element from the page's right-click menu, right-clicked
            // at a point in the page's CSS pixels (Inspector.swift).
            if let at = request["inspect"] as? [Double], at.count == 2, let web = browser.active?.webKitOnly("WebKit-only bench fixtures", build: false) {
                answer(["inspected": BenchInspect.fire(web, at: CGPoint(x: at[0], y: at[1]))])
                return
            }
            // The page in front's zoom, as ⌘+ and ⌘- set it.
            if let zoom = request["zoom"] as? Double { browser.active?.magnify(to: zoom) }
            if request["passwords"] as? Bool == true { browser.openPlace(.passwords) }
            // Send Feedback's sheet, on the window in front.
            if let on = request["feedback"] as? Bool { on ? FeedbackSheet.show() : FeedbackSheet.dismiss() }
            // A file put on the draft, as if dropped on the sheet.
            if let path = request["attach"] as? String { FeedbackSheet.attach([URL(fileURLWithPath: path)]) }
            // Words written on it and sent, as ⌘↩ does. Test runs only.
            if let words = request["sendFeedback"] as? String, Store.testing {
                FeedbackSheet.send(writing: words, email: request["feedbackEmail"] as? String)
            }
            // What the card's fields hold now, as it would show them.
            if request["feedbackDraft"] as? Bool == true {
                let draft = FeedbackModel.shared.draft
                answer(["message": draft.message, "email": draft.email, "remembered": FeedbackSheet.rememberedEmail,
                        "files": draft.files.map { ["name": $0.name, "size": $0.size] },
                        "note": FeedbackModel.shared.unreadNote ?? ""])
                return
            }
            // ⌘[ and ⌘] on the tab in front.
            if request["back"] as? Bool == true {
                StageView.mark("input", ["what": "back"])
                browser.back(byKey: true)
            }
            if request["forward"] as? Bool == true {
                StageView.mark("input", ["what": "forward"])
                browser.forward(byKey: true)
            }
            // ⌘W on the tab in front, as a hand closes it. Test runs only.
            if request["closeFront"] as? Bool == true, Store.testing, let tab = browser.active { browser.close(tab) }
            if let on = request["welcome"] as? Bool { browser.welcoming = on }
            if request["history"] as? Bool == true { browser.openPlace(.history) }
            // Words typed into the field and Return pressed, the way a person
            // goes somewhere new. "newTab": ⌘T's field first, a new tab's.
            // "edit": ⌘L's, the tab in front's.
            if request["newTab"] as? Bool == true, Store.testing { browser.newTab() }
            if request["edit"] as? Bool == true, Store.testing { browser.edit() }
            if let text = request["field"] as? String, Store.testing {
                browser.editing = true
                browser.typed = text
                browser.submit()
            }
            // Return on what the field holds, plain, ⌘ ("behind") or ⌘⇧
            // ("ahead"), or a click on one of its rows, by index: an
            // extension's keyword answered (evals/extensions/omnibox.py).
            if let way = request["submit"] as? String, Store.testing {
                browser.submit(way == "behind" ? .behind : way == "ahead" ? .ahead : .here)
            }
            if let row = request["takeRow"] as? Int, Store.testing, browser.offers.indices.contains(row) {
                browser.take(browser.offers[row])
            }
            if request["bookmarks"] as? Bool == true { browser.showBookmarks() }
            if request["downloads"] as? Bool == true { browser.openPlace(.downloads) }
            // Any place of the field by its name ("store"), words typed into
            // it without Return, and ⌘K's list for the chosen row.
            if let place = (request["place"] as? String).flatMap(FieldPlace.init(rawValue:)) { browser.openPlace(place) }
            if let words = request["typed"] as? String, Store.testing { browser.typed = words }
            // ⌘K's panel on the first open tab's row, as a right-click on it opens it.
            if request["pickOpen"] as? Bool == true, Store.testing,
               let row = browser.offers.firstIndex(where: { $0.tab != nil }) { browser.showActions(forRow: row) }
            if request["actions"] as? Bool == true { browser.showActions() }
            if request["closeField"] as? Bool == true { browser.close() }
            // The place's way back, its chevron or ⌫ in its empty field.
            if request["leave"] as? Bool == true { browser.leavePlace() }
            // What was hidden here, under its row in Site Controls.
            if let on = request["hidden"] as? Bool {
                SiteControlsState.shared.hiddenOpen = on
                if on { browser.toggleExtensions() }
            }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let on = request["glass"] as? Bool { browser.prefs.lookGlass = on }
            if let on = request["sidebar"] as? Bool { browser.prefs.sidebar = on }
            // Change Icon's picker on a tab, by the start of its id, as the
            // menu's Change Icon… opens it; "" shuts it.
            if let id = (request["iconPicker"] as? String)?.lowercased() {
                IconPicking.shared.target = id.isEmpty ? nil : browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(id) }.map { .tab($0.id) }
            }
            if let name = request["folderIconPicker"] as? String {
                IconPicking.shared.target = browser.nests.first { $0.name == name }.map { .nest($0.id) }
            }
            if let flank = (request["flank"] as? String).flatMap(Flank.init) { browser.prefs.sideFlank = flank }
            if let width = request["sideWidth"] as? Double { browser.prefs.sideWidth = CGFloat(width) }
            if let dots = request["spaceDots"] as? Bool { browser.prefs.spaceDots = dots }
            if let names = request["spaceNames"] as? Bool { browser.prefs.spaceNames = names }
            if let compact = request["compactField"] as? Bool { browser.prefs.compactField = compact }
            // The column out over the page as a card, as the edge brings it.
            if let on = request["sidepeek"] as? Bool, browser.prefs.sidebar, browser.prefs.sideShut {
                Brim.bring(browser, out: on)
            }
            // Back held: its list, from the door in sight; "window", a
            // window's number, a small window's (`links`) instead.
            if let on = request["backheld"] as? Bool {
                let held = (request["window"] as? Int).flatMap { number in NSApp.windows.first { $0.windowNumber == number } } ?? Links.window
                if on, let window = held { _ = DoorHold.shared.benchOpen(in: window) } else if !on { DoorList.shared.close() }
            }
            // The pointer over a small window's field, for its doors: a
            // made-up mouse never reaches SwiftUI's hover.
            if let on = request["fieldhover"] as? Bool {
                let held = (request["window"] as? Int).flatMap { number in NSApp.windows.first { $0.windowNumber == number } } ?? Links.window
                LinkWindow.owning(held)?.point(on)
            }
            if let on = request["bar"] as? Bool { browser.prefs.addressBar = on }
            // Settings › Appearance › Tab icons: "icons" or "letters".
            if let glyph = (request["glyph"] as? String).flatMap(Glyph.init) { browser.prefs.glyph = glyph }
            // The bookmarks' row: a mode, or "toggle" for ⇧⌘B.
            if let mode = (request["shelf"] as? String).flatMap(BookmarkBarMode.init) { browser.prefs.bookmarkBar = mode }
            if let style = (request["bookmarkStyle"] as? String).flatMap(BookmarkStyle.init) { browser.prefs.bookmarkStyle = style }
            if request["shelf"] as? String == "toggle" { browser.toggleBookmarkBar() }
            // Add This Page, and the empty row's offer of another browser's bookmarks.
            if request["keep"] as? Bool == true { browser.bookmarkCurrent() }
            if request["bring"] as? Bool == true, let found = Elsewhere.shared.found {
                browser.takeBookmarks(from: found.source)
            }
            // ⇧⌘C, as the menu does it: the bar's link answers, or the corner.
            if request["copy"] as? Bool == true { browser.copyAddress() }
            if let mode = (request["backdrop"] as? String).flatMap(Backdrop.init) { browser.prefs.backdrop = mode }
            if let swatch = (request["swatch"] as? String).flatMap(Swatch.init) { browser.prefs.swatch = swatch }
            if let hex = (request["custom"] as? String).flatMap(NSColor.init(hex:)) { browser.prefs.backdropColor = hex }
            if let amount = request["grain"] as? Double { browser.prefs.grain = min(1, max(0, amount)) }
            // AI in Yab and its field rows, as Settings › AI and ⌘T set them
            // (AIUse); in a test world, an agent there or none, and the
            // Mac's model put aside, for the states the switch is drawn in.
            // Only a test world's: the switch is the person's, never an agent's.
            if Store.testing, let level = (request["aiUse"] as? String).flatMap(AIUse.Level.init) { browser.prefs.aiUse = level }
            if Store.testing, let rows = request["aiRows"] as? Bool { browser.prefs.aiRowsHidden = !rows }
            if Store.testing, let agent = request["agent"] as? Bool {
                Agents.assumedInTests = agent
                Agents.connectedInTests = agent
            }
            if Store.testing, let mac = request["macModel"] as? Bool { AppleModelControl.shared.setEnabled(mac) }
            // Which page Settings opens on, before it is opened.
            if let page = (request["page"] as? String).flatMap(SettingsPage.init) {
                SettingsModel.ask(page)
            }
            // And opened there.
            if request["settings"] as? Bool == true { SettingsWindow.shared.show(for: browser) }
            // And closed, for a picture of the browser window after it.
            if request["settings"] as? Bool == false, Store.testing { SettingsWindow.shared.window?.close() }
            // A thing on that page opened, as a click on its row does:
            // a skill, a space, a site's prompts.
            if let item = request["item"] as? String, let page = (request["page"] as? String).flatMap(SettingsPage.init) {
                SettingsWindow.shared.model?.open(page, item: item)
            }
            // Settings' window set to a size, to draw a tall page whole.
            if Store.testing, let size = request["settingsSize"] as? [Double], size.count == 2 {
                SettingsWindow.shared.window?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            // Boosts' list under Select, rows picked by name, and Delete…
            // asked: {"select": true, "pick": ["Wide diffs"], "ask": true}.
            if Store.testing, let hand = request["boosts"] as? [String: Any] {
                if hand["list"] as? Bool == true { SettingsWindow.shared.model?.go(.boosts) }
                NotificationCenter.default.post(name: BoostsBench.hand, object: nil, userInfo: hand)
            }
            // A searchable row of Settings scrolled to and washed, as
            // Return on its search result does: "spot": "awake-sites".
            if let id = request["spot"] as? String, let item = SettingsItem.all.first(where: { $0.id == id }) {
                SettingsWindow.shared.model?.take(.item(item))
            }
            if Store.testing, request["windows"] as? Bool == true {
                answer(["windows": NSApp.windows.filter(\.isVisible).map {
                    ["id": $0.windowNumber, "kind": String(describing: type(of: $0)), "title": $0.title,
                     "width": $0.contentView?.bounds.width ?? 0, "height": $0.contentView?.bounds.height ?? 0]
                }])
                return
            }
            // Appearance's From row, read from a browser named, installed or not.
            if let name = request["lookFrom"] as? String {
                BrowserLookFinder.shared.load(among: Chromium.known.filter { $0.name == name })
            }
            // A browser's folder standing in for the one on this Mac, its
            // data read from "standInPath" ("" puts the real ones back);
            // "bringTabs": Settings' Bring In pressed for it, on its page.
            if Store.testing, let name = request["standIn"] as? String {
                let path = request["standInPath"] as? String ?? ""
                let standing: [Chromium.Source] = path.isEmpty ? [] : Chromium.known.filter { $0.name == name }.map {
                    var source = $0
                    source.dataRoot = URL(fileURLWithPath: path)
                    return source
                }
                Chromium.standIns.withLock { $0 = standing }
                // Its Safe Storage passphrase, so its tabs.db and cookies
                // read with no keychain asked.
                if let key = request["standInKey"] as? String, !path.isEmpty {
                    Chromium.standInKeys.withLock { $0[path] = key.isEmpty ? nil : key }
                }
                // Zen and Firefox stand in the same way, for their row:
                // "Zen+Firefox" has both, from zen/ and Firefox/ under the path.
                Firefox.standIns = path.isEmpty ? [] : Firefox.known.filter { $0.name == name || name == "Zen+Firefox" }.map {
                    var source = $0
                    source.dataRoot = name == "Zen+Firefox" ? URL(fileURLWithPath: path).appendingPathComponent($0.folder) : URL(fileURLWithPath: path)
                    return source
                }
            }
            // Settings › Bring In's switch for a browser's history (OtherHistory).
            if Store.testing, let name = request["otherHistory"] as? String {
                OtherHistory.set(name, reading: request["reading"] as? Bool ?? false)
            }
            if Store.testing, let name = request["bringTabs"] as? String,
               let source = Chromium.installed().first(where: { $0.name == name }) {
                NotificationCenter.default.post(name: TabBringer.benchBring, object: nil, userInfo: ["source": source])
            }
            if let on = request["shut"] as? Bool, browser.prefs.sidebar, on != browser.prefs.sideShut { browser.toggleColumn() }
            // A column put away, brought out over the page as a card, as the
            // pointer at the window's left edge brings it (Lights.bringOut).
            if let on = request["peekColumn"] as? Bool, browser.prefs.sidebar, browser.prefs.sideShut, on != browser.sidePeek {
                Brim.bring(browser, out: on)
            }
            // A strip put away, brought out over the page and back, as the
            // pointer at the window's top edge does it (Brim.bringStrip).
            if let on = request["peekStrip"] as? Bool, browser.stripAway {
                Brim.bringStrip(browser, out: on)
            }
            if let amount = request["transparency"] as? Double { browser.prefs.backdropTransparency = BackdropTransparency.clamp(amount) }
            // ⇧⌘S and ⌘S as the menu does them, pair or no pair.
            if request["turn"] as? Bool == true { browser.toggleSidebar() }
            if request["fold"] as? Bool == true { browser.toggleColumn() }
            if let on = request["fullscreen"] as? Bool, let window = Links.window,
               on != window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            if #available(macOS 15.4, *), let on = request["extensions"] as? Bool, on != ExtensionPanel.shared.isShown { ExtensionPanel.shared.toggle() }
            // Settings › Spaces: a space's page by its place in the list, or
            // "new" for Add Space's; "list" back to the list.
            if let space = request["space"] as? String { SettingsWindow.shared.bench(space: space, browser: browser) }
            // Words in Settings' search, as if typed, and what answered.
            if let text = request["search"] as? String {
                answer(SettingsWindow.shared.bench(search: text))
                return
            }
            if let phase = request["update"] as? String {
                // What would hold a quiet restart now, and whether the
                // column says anything about the update.
                if phase == "held" {
                    answer(["held": Updater.Away.holding ?? "", "says": UpdateSlot.says(.shared, calls: browser.calls),
                            "stage": "\(Updater.shared.stage)", "automatic": Updater.Away.automatic])
                    return
                }
                // A test run's build in place, without a swap, and its tick
                // in seconds (evals/updates/away.py).
                if phase == "ready" {
                    Updater.shared.benchReady(critical: request["critical"] as? Bool ?? false,
                                              tick: request["tick"] as? Double ?? 60)
                    answer(["stage": "\(Updater.shared.stage)"])
                    return
                }
                // As if nobody had touched the Mac for `idle` seconds, and it
                // was locked `locked` seconds ago (absent: unlocked).
                if phase == "away" {
                    Updater.Away.bench(idle: request["idle"] as? Double, lockedFor: request["locked"] as? Double)
                    // Settings › General's Update automatically, as switched there.
                    if Store.testing, let on = request["automatic"] as? Bool { Store.settings.set(on, forKey: Updater.Away.automaticKey) }
                    answer(["held": Updater.Away.holding ?? ""])
                    return
                }
                UpdateNews.shared.bench(phase)
            }
            // Site notifications (SiteNotices.bench).
            if let command = request["notify"] as? String {
                answer(SiteNotices.bench(command, browser: browser))
                return
            }
            // A real press on the page in front, by selector: what WebKit
            // counts as the person's click. A --test run only.
            if Store.testing, let selector = request["press"] as? String, let tab = browser.active {
                SiteNotices.press(selector, in: tab, done: answer)
                return
            }
            // The page's question on the tab in front, answered: yes, no,
            // tick (the box), open, and what the tabs are asking.
            if let command = request["ask"] as? String {
                if let tab = browser.active {
                    switch command {
                    case "yes": browser.answer(tab, .yes(tab.asks.first?.text))
                    case "no": browser.answer(tab, .no)
                    case "tick": browser.tickAsk(tab, true)
                    case "open": browser.openAsk(tab)
                    default: break
                    }
                }
                answer(["asks": browser.tabs.filter { !$0.asks.isEmpty }.map { tab -> [String: Any] in
                    ["tab": String(tab.id.uuidString.prefix(8)).lowercased(), "front": tab.id == browser.activeID,
                     "asks": tab.asks.map { "\($0.kind) \($0.stage) \($0.host) parked=\($0.parked) persistent=\($0.persistent) \($0.message)" }]
                }, "cards_shown": AskView.all.allObjects.filter(\.showing).count,
                   // Where the corner's notice takes the card to stand (AskRoom).
                   "card_room": browser.askRoom.card.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? NSNull()])
                return
            }
            // yab's own question up now: tick:KEY or untick:KEY one of its
            // boxes, then yes or no. Test runs only.
            if Store.testing, let command = request["question"] as? String {
                let questions = Questions.shared
                if command.hasPrefix("tick:") { questions.current?.ticks?.on.insert(String(command.dropFirst(5))) }
                else if command.hasPrefix("untick:") { questions.current?.ticks?.on.remove(String(command.dropFirst(7))) }
                else if command == "yes" || command == "no" { questions.answer(command == "yes") }
                answer(["title": questions.current?.title ?? "", "boxes": questions.current?.boxes.map(\.key) ?? [],
                        "on": Array(questions.current?.ticks?.on ?? [])])
                return
            }
            if let command = request["adding"] as? String {
                answer(SettingsWindow.shared.bench(adding: command))
                return
            }
            // Settings › Agents' way in: connect, connect:CLI, install:CLI, cancel, ask
            // (How to Ask), used:CLI (an agent opening a tab), finish (on to the
            // offer to get to know you), know, suggest, stopknow, disconnect,
            // show-signin, close-signin (the sign-in's tab closed as a person
            // would); and where it stands, its page, trouble, renewing, slow
            // and knowing among it (AgentSetupModel.bench). Test runs only.
            if Store.testing, let command = request["agents"] as? String {
                answer(AgentSetupModel.shared.bench(command, browser: browser))
                return
            }
            // The task line (AgentTask): open, select:WORDS (as the
            // selection's Ask about this… opens it), words:WORDS, add (the
            // last tab looked at), run, close; field:WORDS
            // types into ⌘T's field and says its rows, swap is its ⇥, take
            // its Return. Test runs only.
            if Store.testing, let command = request["task"] as? String {
                answer(TaskLine.bench(command, in: browser))
                return
            }
            // Settings › Agents › Memory ("list" or a note's path) and
            // Skills ("list", "new:NAME" or a skill's name).
            if let memory = request["memory"] as? String {
                answer(SettingsWindow.shared.bench(memory: memory))
                return
            }
            if let command = request["syncDevice"] as? String {
                answer(SettingsWindow.shared.bench(syncDevice: command))
                return
            }
            // Settings › Sync: "home", "add", "what" or "off".
            if let place = request["syncPage"] as? String {
                answer(SettingsWindow.shared.bench(sync: place))
                return
            }
            if let skill = request["skill"] as? String {
                answer(SettingsWindow.shared.bench(skill: skill))
                return
            }
            // An extension's own page in Settings, by its id.
            if let id = request["extension"] as? String {
                answer(SettingsWindow.shared.bench(extension: id))
                return
            }
            if let key = request["pick"] as? String {
                answer(SettingsWindow.shared.bench(pick: key))
                return
            }
            // Words in the address field, as if typed, and what it offered.
            if let text = request["typed"] as? String {
                if !browser.fieldShowing { browser.edit() }
                browser.typed = text
                answer([
                    "offers": browser.offers.map { $0.id },
                    "rows": browser.offers.map { $0.key },
                    // Each row's address and the color of the icon it wears,
                    // "" for a letter (evals/favicons/per_page.py).
                    "urls": browser.offers.map { $0.url?.absoluteString ?? "" },
                    "icons": browser.offers.map { Scope.average(of: Omnibox.favicon(for: $0))?.hex ?? "" },
                    "ending": browser.ending ?? "",
                    "lead": browser.query.lead ?? -1,
                    "tab": browser.query.offering?.name ?? "",
                    "site": browser.query.scope?.name ?? "",
                    // Where Return's search goes, and what its row calls the
                    // engine: the space on screen's (EngineChoice).
                    "search": browser.offers.first { $0.kind == .search }?.url?.absoluteString ?? "",
                    "engine": browser.offers.first { $0.kind == .search }?.title ?? "",
                ])
                return
            }
            // Settings › Search's card: add a site, change one by host, or put it away.
            if let card = request["sitecard"] as? String {
                switch card {
                case "add": SiteEditing.shared.open(nil)
                case "close": SiteEditing.shared.close()
                default: SiteEditing.shared.open(Scopes.all.first { $0.id == card } ?? Scopes.all.first { $0.host == card })
                }
                answer(["open": SiteEditing.shared.draft != nil])
                return
            }
            // Settings › AI › Routines: the editor on a new one or one by id,
            // Run Regularly…'s card on a command ("command:summarize"), or
            // both put away; and the month's visits its suggestions go by.
            if let card = request["routinecard"] as? String {
                let editing = RoutineEditing.shared
                switch card {
                // Settings brought up on Routines first, as the app's own ways in do.
                case "new": SettingsWindow.shared.showRoutine(nil, for: browser)
                case "close": editing.sheet = nil; editing.closeCard()
                // Its Save: the editor's copy as it was opened, a new when if given.
                case "save":
                    if var draft = editing.sheet?.routine {
                        if let when = request["when"] as? String { draft.when = when }
                        if case .failure(let trouble) = Routines.shared.put(draft) { answer(["error": trouble.said]); return }
                        editing.sheet = nil
                    }
                case let named where named.hasPrefix("command:"):
                    if let command = browser.selectionCommands.commands.first(where: { $0.id == named.dropFirst(8) }) { editing.runRegularly(command) }
                default: SettingsWindow.shared.showRoutine(Routines.shared.all.first { $0.id == card }, for: browser)
                }
                answer(["sheet": editing.sheet != nil, "card": editing.card != nil])
                return
            }
            // A place of the field's, opened as its name and Tab would, and
            // its rows.
            if Store.testing, let name = request["fieldplace"] as? String, let place = FieldPlace(rawValue: name) {
                if !browser.fieldShowing { browser.edit() }
                browser.openPlace(place)
                answer(["rows": browser.placeItems.map { $0.title + " | " + $0.source + ($0.tag.map { " | " + $0 } ?? "") }])
                return
            }
            // A row of the place up, by its title, and one of its actions
            // by id, as ⌘K runs it (none: the first, as Return does).
            if Store.testing, let title = request["placeRun"] as? String {
                let items = browser.placeItems
                guard let item = items.first(where: { $0.title == title }) else { answer(["error": "no row " + title, "rows": items.map(\.title)]); return }
                let actions = browser.placeActions(item)
                let wanted = request["action"] as? String ?? ""
                guard let action = wanted.isEmpty ? actions.first : actions.first(where: { $0.id == wanted }) else {
                    answer(["error": "no action " + wanted, "actions": actions.map(\.id)]); return
                }
                action.run()
                answer(["ran": action.id, "row": item.title])
                return
            }
            if Store.testing, let counts = request["routinevisits"] as? [String: Int] {
                RoutineIdeas.shared.given(counts)
                answer(["offered": RoutineIdeas.shared.offered(Routines.shared.all).map(\.id)])
                return
            }
            if Store.testing, let command = request["quick"] as? String {
                let actions = QuickActions.shared
                if command == "card:new" {
                    QuickActionEditing.shared.open(QuickAction(id: UUID().uuidString, name: "", url: "https://", alias: "", custom: true))
                } else if command == "card:close" {
                    QuickActionEditing.shared.close()
                } else if command.hasPrefix("card:") {
                    if let action = actions.action(String(command.dropFirst(5))) { QuickActionEditing.shared.open(action) }
                } else if command == "fixture" {
                    let now = Date()
                    let visits = [
                        Visit(url: "https://notion.so/home", key: "notion.so/home", title: "Notion", count: 18, last: now, typed: 3),
                        Visit(url: "https://meet.google.com/", key: "meet.google.com", title: "Google Meet", count: 14, last: now, typed: 2),
                        Visit(url: "https://sheets.google.com/", key: "sheets.google.com", title: "Google Sheets", count: 8, last: now, typed: 1),
                        Visit(url: "https://slides.google.com/", key: "slides.google.com", title: "Google Slides", count: 6, last: now, typed: 1),
                    ]
                    actions.refresh(from: History(visits))
                } else if command.hasPrefix("shortcut:") {
                    let words = command.split(separator: ":", maxSplits: 2).map(String.init)
                    if words.count == 3, var action = actions.action(words[1]) {
                        action.shortcut = words[2]
                        _ = actions.put(action)
                    }
                }
                answer(["actions": actions.actions.map { ["id": $0.id, "name": $0.name, "url": $0.url, "alias": $0.alias, "shortcut": $0.shortcut, "enabled": $0.enabled] },
                        "suggestions": actions.suggestions.map(\.id), "card": QuickActionEditing.shared.action?.id ?? ""])
                return
            }
            // The field searching a site: Tab into the one the words name,
            // Escape out keeping the words, ⌫ out giving them back.
            if let step = request["scope"] as? String {
                switch step {
                case "tab": browser.enterScope()
                case "escape": browser.leaveScope()
                default: browser.leaveScope(restoring: true)
                }
                answer([
                    "site": browser.query.scope?.name ?? "", "typed": browser.typed,
                    "offers": browser.offers.map { "\($0.key)|\($0.title)" }, "tab": browser.query.offering?.name ?? "",
                ])
                return
            }
            let glassWindow = BrowserWindows.shared.window(for: browser) ?? Links.window
            let dark = (glassWindow?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let worn = browser.prefs.swatch.color(dark: dark, custom: browser.prefs.backdropColor)
            func glassBackdrop(in view: NSView) -> WindowBackdropView? {
                if let found = view as? WindowBackdropView { return found }
                return view.subviews.lazy.compactMap { glassBackdrop(in: $0) }.first
            }
            let native = glassWindow?.contentView.flatMap { glassBackdrop(in: $0) }
            let supported: Bool
            if #available(macOS 26.0, *) { supported = true } else { supported = false }
            answer(["ok": true, "windowGlass": [
                "requested": browser.prefs.lookGlass,
                "style": WindowGlassPolicy.current(enabled: browser.prefs.wearsGlass, dark: BackdropVeil.dark(worn)).rawValue,
                "dark": dark, "colorDark": BackdropVeil.dark(worn), "supportsLiquid": supported,
                "tint": browser.prefs.wornTransparency(dark: dark),
                "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                "layers": native?.glassReport ?? [:],
            ]])

        case "import":
            importCommand(request, browser: browser, answer)

        case "extensions", "ext-add", "ext-add-frozen", "ext-diagnostics", "ext-background", "ext-folder", "ext-press", "ext-withheld", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-popout", "ext-side-panel", "ext-menu", "site-shot", "site-facts", "ext-pin", "ext-tip", "ext-commands", "ext-shot", "ext-answer", "ext-enable", "ext-scan", "ext-bring", "debugger", "ext-search-engines", "answer-links":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionCommand(verb, request, browser: browser, answer)

        case "ext-context", "ext-options", "ext-everywhere", "ext-sign-ins", "ext-offscreen":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionUserCommand(verb, request, browser: browser, answer)

        case "keys":
            keysCommand(request, browser: browser, answer)

        case "reader-card":
            readerCardCommand(request, browser: browser, answer)

        case "mail-time":
            // Mail's speed stand (MailTime): a key timed to the frame where
            // what it does reads, a generated mailbox loaded whole.
            MailTime.command(request, browser: browser, answer)

        case "scroll":
            settingsScroll(request, answer)

        case "research":
            // A search's folders (Research.swift). "go": a tab of yours to
            // `url`, in front, as the field takes you there; "click": `url`
            // ⌘-clicked on the tab whose address or title holds `from` (the
            // one in front otherwise); "fold": the folders as twenty-one
            // minutes on; "ungroup"/"toggle": the folder named `name`;
            // "close": the tab whose title holds `from`; "links": ⌘-clicking
            // links makes folders, `on` or not. Every one answers
            // the row: each tab, its folder, and what its row says.
            guard Store.testing else { answer(["error": "research only works on a --test run"]); return }
            let find: (String?) -> Tab? = { key in
                guard let key else { return browser.active }
                return browser.tabs.first { ($0.address?.absoluteString ?? "").localizedCaseInsensitiveContains(key) || $0.title.localizedCaseInsensitiveContains(key) }
            }
            let nest = (request["name"] as? String).flatMap { name in browser.nests.first { $0.name.localizedCaseInsensitiveContains(name) } }
            switch request["verb"] as? String ?? "state" {
            case "go":
                guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { break }
                browser.open(url, foreground: true)
            case "click":
                guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { break }
                browser.openBeside(url, from: find(request["from"] as? String), foreground: request["shift"] as? Bool ?? false)
            case "select":
                if let tab = find(request["from"] as? String) { browser.select(tab) }
            case "nav":
                if let tab = find(request["from"] as? String), let url = (request["url"] as? String).flatMap(URL.init(string:)) { tab.go(to: url) }
            case "tidy":
                // Every tab but `keep` seen `hours` ago, and tidied as at
                // launch.
                let keep = find(request["keep"] as? String)
                let then = Date().addingTimeInterval(-(request["hours"] as? Double ?? 48) * 3600)
                for tab in browser.tabs where tab !== keep && tab.id != browser.activeID && !tab.bench { tab.touch(at: then) }
                browser.tidy()
            case "close":
                if let tab = find(request["from"] as? String) { browser.close(tab) }
            // Tidy on the kept line (TidyTabs.swift), and ⌘Z in the window.
            case "tidytabs":
                // `answer`: the model's stand-in, tabs counted from 0.
                if let said = request["answer"] as? String { TidyTabs.benchAnswer = said.isEmpty ? nil : said }
                browser.tidyTabs()
            case "undo": _ = browser.undoWindow()
            case "fold":
                Folders.shared.fold(now: Date().addingTimeInterval(Folders.idle + 60))
            case "links":
                // Settings › Tabs' "⌘-clicking links makes folders", `on`;
                // with `emoji` or `optShift`, those switches.
                if let on = request["emoji"] as? Bool { browser.prefs.folderEmoji = on }
                if let on = request["optShift"] as? Bool { browser.prefs.optShiftFolders = on }
                if request["emoji"] == nil, request["optShift"] == nil { browser.prefs.linkFolders = request["on"] as? Bool ?? true }
            case "meeting":
                // Join on a meeting made up here: `title`, its call at
                // `url`, `minutes` long from now (MeetingFolders).
                if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
                    let minutes = request["minutes"] as? Double ?? 20
                    browser.joinMeeting(Meeting(id: "bench-" + url.absoluteString, title: request["title"] as? String ?? "",
                                                start: Date(), end: Date().addingTimeInterval(minutes * 60), link: url))
                }
            case "groupclick":
                // ⌥⇧-click on the row of the tab whose address or title
                // holds `from`, as the row reads the keys (Browser.pick).
                if let tab = find(request["from"] as? String) {
                    switch Browser.rowClick([.option, .shift], groups: browser.prefs.optShiftFolders) {
                    case .group: if !browser.groupClick(tab) { browser.select(tab) }
                    default: browser.extend(to: tab)
                    }
                }
            case "ungroup":
                if let nest { browser.ungroupSearch(nest) }
            case "toggle":
                if let nest { Folders.shared.toggle(nest.key) }
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.3)) {
                let folders = Folders.shared
                answer([
                    "tabs": browser.tabs.filter { $0.pin == nil && !$0.bench }.map { tab -> [String: Any] in
                        var out: [String: Any] = ["title": tab.title, "row": tab.rowLabel, "asleep": tab.asleep, "front": tab.id == browser.activeID]
                        if let nest = tab.nest {
                            out["folder"] = nest.name
                            out["search"] = nest.search ?? ""
                            out["open"] = nest.open
                            out["today"] = nest.today
                            out["mark"] = LinkFolders.mark(nest, in: browser).map { $0.emoji == nil ? "site" : "emoji" } ?? (nest.customMark == nil ? "folder" : "custom")
                            out["emoji"] = nest.customMark ?? ""
                            if let end = nest.meetingEnd { out["left"] = MeetingLeftWords.words(until: end, now: Date()) ?? "" }
                        }
                        out["kept"] = tab.kept
                        out["picked"] = browser.isPicked(tab)
                        if let place = folders.place(of: tab) { out["shown"] = place.shown }
                        return out
                    },
                    "folders": folders.folders.compactMap { $0.nest.map { nest -> [String: Any] in
                        var out: [String: Any] = ["name": nest.name, "search": nest.search ?? "", "open": nest.open]
                        // How long the model's name took after the folder was made.
                        if let named = nest.named, let born = nest.born { out["namedMs"] = Int(named.timeIntervalSince(born) * 1000) }
                        return out
                    } },
                    "namer": ["said": LinkFolders.namer.said, "running": LinkFolders.namer.running],
                    "tidy": ["can": browser.canTidyTabs, "clear": browser.canTidyNow, "tidying": browser.tabsTidying,
                             "ms": TidyTabs.lastMs ?? -1, "said": TidyTabs.lastSaid, "by": TidyTabs.lastBy],
                ])
            }

        case "switchmarks":
            // The last `select` timed (SwitchMarks): its own pass committed,
            // then the site's color after it.
            answer(SwitchMarks.last)

        case "look":
            // The look card (LookCard): open or close it, set what its
            // controls set, turn a step, read it and the window's layer back.
            guard Store.testing else { answer(["error": "look only works on a --test run"]); return }
            answer(LookCard.shared.bench(request, browser))

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "tabs", "open", "go", "close", "wait", "sleep", "select", "text", "eval", "click", "type", "submit", "shot", "probe", "ui",
            ]])
        }
    }

    /// Bringing things in from the shell, into a --test run's world only. A
    /// browser is looked for among every one yab knows, whether or not the
    /// app is still on this Mac, so a browser's files can be read where only
    /// its folder is left. While it runs the main thread is timed the way
    /// `pace` times it, frame by frame, and by its own CPU time.
    private func importCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "import is for --test runs"]); return }
        let what = request["what"] as? String ?? ""
        var source = (request["browser"] as? String).flatMap { name in
            Chromium.known.first { $0.name.lowercased() == name.lowercased() }
        }
        let path = (request["path"] as? String).map { URL(fileURLWithPath: $0) }
        // A controlled browser-data fixture in an isolated test world.
        // The same disk reader and bringing path as a person's import.
        if let path { source?.dataRoot = path }
        source = source?.authorizingImport()
        // The fixture's Safe Storage passphrase: its tabs.db read with no
        // keychain asked.
        if let path, let key = request["key"] as? String {
            Chromium.standInKeys.withLock { $0[path.path] = key.isEmpty ? nil : key }
        }
        // Zen or Firefox by name: their places.sqlite read as Settings' row
        // reads it (FirefoxBringer), from the fixture folder when given.
        var firefox = (request["browser"] as? String).flatMap { name in
            Firefox.known.first { $0.name.lowercased() == name.lowercased() }
        }
        if let path { firefox?.dataRoot = path }
        if ["profiles", "tabs", "bookmarks", "history"].contains(what), source == nil,
           !(firefox != nil && ["bookmarks", "history"].contains(what)) {
            answer(["error": "import \(what) needs a browser: " + Chromium.known.map(\.name).joined(separator: ", ")])
            return
        }
        if what.hasSuffix("-file") || what == "places-db" || what == "bookmarks-out", path == nil {
            answer(["error": "import \(what) needs a path"])
            return
        }

        let pacer = Pacer()
        let link = Links.window?.contentView?.displayLink(target: pacer, selector: #selector(Pacer.tick(_:)))
        link?.add(to: .main, forMode: .common)
        let t0 = CACurrentMediaTime()
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        // Until the import is in, and then for two seconds more: what came
        // in is drawn after the call returns, and that is the main thread's
        // too.
        func done(_ fields: [String: Any]) {
            var out = fields
            out["wall_ms"] = ((CACurrentMediaTime() - t0) * 1000).rounded()
            let cpu1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            out["main_cpu_ms"] = (Double(cpu1 - cpu0) / 1e5).rounded() / 10
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                link?.invalidate()
                let gaps = zip(pacer.times.dropFirst(), pacer.times).map { ($0 - $1) * 1000 }
                out["after_cpu_ms"] = (Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu1) / 1e5).rounded() / 10
                out["frames"] = gaps.count
                out["worst_frame_ms"] = ((gaps.max() ?? 0) * 10).rounded() / 10
                out["dropped"] = gaps.filter { $0 > pacer.frame * 1000 * 1.5 }.count
                answer(out)
            }
        }

        switch what {
        case "profiles", "tabs":
            // "profiles": the browser's places, each with where it would go;
            // "tabs": brought in, all but those named in "skip".
            // "ask": as Settings' Bring In asks, Dia through its scripting too.
            TabImport.load(source!, ask: request["ask"] as? Bool ?? false) { outcome in
                guard case .success(let places) = outcome else {
                    done(["error": "unreadable: \(outcome)"])
                    return
                }
                let skip = Set(request["skip"] as? [String] ?? [])
                let picked = places.filter { !skip.contains($0.name) }
                let asSpaces = request["spaces"] as? Bool ?? true
                guard what == "tabs" else {
                    done(["places": places.map { place -> [String: Any] in
                        ["id": place.id, "name": place.name, "emoji": place.emoji ?? "", "color": place.color ?? "", "grain": place.grain ?? false,
                         "profile": place.profile, "shared": place.shared, "pinned": place.pinned.count, "kept": place.kept.count, "open": place.open.count,
                         "to": browser.landingWords(of: place, among: picked, asSpaces: asSpaces)]
                    }])
                    return
                }
                let took = browser.bring(picked, withOpen: request["open"] as? Bool ?? false, asSpaces: asSpaces,
                                         signIns: request["signins"] as? Bool ?? false, from: source!)
                done(["made": took.spaces, "pinned": took.pinned, "open": took.open,
                      "spaces": browser.spaces.map { ["name": $0.name, "icon": $0.icon, "own": $0.ownSignIns, "origin": $0.origin ?? "",
                                                       "swatch": $0.paint?.swatch ?? "", "color": $0.paint?.color ?? "", "grain": $0.paint?.grain ?? false,
                                                       "brought": $0.brought?.count ?? 0] },
                      "row": browser.tabs.count, "pinned_in_row": browser.pinnedCount])
            }
        case "bookmarks":
            if source == nil, let firefox {
                browser.takeBookmarks(from: firefox, quiet: true) { added in done(["added": added, "kept": browser.bookmarks.count]) }
            } else {
                browser.takeBookmarks(from: source!) { added in done(["added": added, "kept": browser.bookmarks.count]) }
            }
        case "history":
            if source == nil, let firefox {
                browser.takePlaces(from: firefox) { count in done(["places": count]) }
            } else {
                browser.takePlaces(from: source!) { count in done(["places": count]) }
            }
        case "bookmarks-file":
            browser.takeBookmarks(file: path!) { added in done(["added": added ?? -1, "kept": browser.bookmarks.count]) }
        case "bookmarks-out":
            // Settings' Export bookmarks, into `path` with no panel.
            done(["written": browser.writeBookmarks(to: path!, quiet: true) ?? -1, "kept": browser.bookmarks.count])
        case "history-file":
            browser.takePlaces(file: path!) { added in done(["added": added ?? -1]) }
        case "passwords-file":
            // A passwords CSV read as Bring passwords in reads it, nothing
            // written: which sign-ins it would take and how many rows not.
            let found = HistoryFile.text(of: path!).map(Vault.logins(csv:))
            done(["logins": found?.logins.map { ["host": $0.host, "user": $0.user, "clear": $0.clear] as [String: Any] } ?? [],
                  "skipped": found?.skipped ?? -1])
        case "places-db":
            // One History file read the way an import reads it, log and all.
            DispatchQueue.global(qos: .userInitiated).async {
                let rows = (try? Chromium.placeRows(in: path!, limit: 10_000_000))?.count ?? -1
                DispatchQueue.main.async { done(["rows": rows]) }
            }
        default:
            done(["error": "import profiles|tabs|bookmarks|history BROWSER, or bookmarks-file|history-file|places-db PATH"])
        }
    }

    /// Extensions, from the shell. Installing asks as it always does, except
    /// in a test run given `yes`, a real browser can't be made to skip it.
    @available(macOS 15.4, *)
    private func extensionCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        // The space on screen's sign-in's (ExtensionSignIns).
        let extensions = Extensions.of(browser)
        let skip = Store.testing && (request["yes"] as? Bool ?? false)
        switch verb {
        case "extensions":
            let hung = ExtensionPopup.shared.frames
            let popupView = ExtensionPopup.shared.view
            let popupRect = popupView.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } } ?? .zero
            answer(["popupWindow": popupView?.window?.windowNumber ?? 0,
                    "popupKey": popupView?.window?.isKeyWindow ?? false,
                    "popupContentOnScreen": [popupRect.minX, (NSScreen.screens.first?.frame.maxY ?? 0) - popupRect.maxY, popupRect.width, popupRect.height],
                    "busy": extensions.busy ?? "", "panel": ExtensionPanel.shared.isShown, "menuOpen": extensions.menuOpen,
                    "popupLayoutState": ExtensionPopup.shared.layoutState,
                    // The panel's window, for `film` with "window".
                    "panelWindow": ExtensionPanel.shared.windowNumber ?? 0,
                    "signIn": extensions.signIn?.uuidString ?? "shared",
                    // The popup's window and what it hangs from, on screen: x, y, width, height.
                    "popupFrame": hung.map { [$0.popup.minX, $0.popup.minY, $0.popup.width, $0.popup.height] } ?? [],
                    "popupFrom": hung.map { [$0.from.minX, $0.from.minY, $0.from.width, $0.from.height] } ?? [],
                    // The buttons the toolbar shows now, loaded or still waiting their turn.
                    "buttons": extensions.buttons.map(\.id), "starting": Array(extensions.starting), "asleep": Array(extensions.asleep),
                    "extensions": extensions.installed.map { item -> [String: Any] in
                let context = extensions.contexts[item.id]
                let action = context?.action(for: extensions.activeAdapter)
                return [
                    "id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled,
                    "loaded": context != nil, "permissions": item.permissions,
                    // Whether its worker is up now, or asleep until an event wakes it.
                    "awake": context.map(Extensions.workerAwake) ?? false,
                    // Its worker's last word that it is at work (ExtensionKeep): seconds ago, and how many.
                    "keepWordAgo": ExtensionKeep.lastWord[item.id].map { Date().timeIntervalSince($0) } ?? -1,
                    "keepWords": ExtensionKeep.words[item.id] ?? 0,
                    // When the launch loaded it and why (ExtensionLaunch), what
                    // its worker said it listens for, and the events it was
                    // woken for with no listener of its own, this run.
                    "plan": extensions.plans[item.id].map { "\($0.need.rawValue): \($0.why)" } ?? "",
                    "listens": extensions.listening(item.id),
                    "idleWakes": extensions.idleWakes[item.id] ?? [:],
                    "base": context?.baseURL.absoluteString ?? "",
                    // Rule sets kept off as too large for WebKit, and the
                    // line its row says for them (ExtensionRuleBudget).
                    "rulesLeftOff": extensions.rulesLeftOff(item.id),
                    "rulesLine": ExtensionRuleBudget.line(extensions.rulesLeftOff(item.id).count) ?? "",
                    // Where WebKit keeps its state and compiled rules.
                    "storage": extensions.storage(of: item.id)?.path ?? "",
                    // Its compiled declarativeNetRequest list, as new pages get it.
                    "rules": ExtensionRules.report(item.id),
                    "errors": (context?.errors ?? []).map { error in
                        let e = error as NSError
                        let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.localizedDescription) \($0.userInfo)" } ?? ""
                        return e.localizedDescription + under + (e.userInfo.isEmpty ? "" : " \(e.userInfo.filter { $0.key != NSLocalizedDescriptionKey && $0.key != NSUnderlyingErrorKey })")
                    },
                    "reported": extensions.errors[item.id] ?? [],
                    "reportedTotal": extensions.errorsNoted[item.id] ?? 0,
                    // What its row in Settings warns of, beside WebKit's `errors`.
                    "warnings": extensions.warnings(item),
                    // "unconnected" while 1Password's app won't talk to Yab,
                    // "stopped" once macOS killed its app as Yab started it.
                    "app": extensions.unconnected.contains(item.id) ? "unconnected"
                        : extensions.stoppedByMacOS.contains(item.id) ? "stopped" : "",
                    "line": ExtensionDetail.stoppedByMacOS(item, context, extensions) ? ExtensionDetail.stoppedLine(item.id) : "",
                    "action": action?.label ?? "", "badge": action?.badgeText ?? "",
                    "popup": action?.presentsPopup ?? false,
                    // The icon drawn now, as a Chromium tab's is read (ExtensionOneList.tint).
                    "iconTint": ExtensionOneList.tint(action?.icon(for: CGSize(width: 32, height: 32))),
                    "pinned": item.pinned ?? false, "source": item.source ?? "",
                    // Whether it reaches example.com and each site kept from it.
                    "reaches": Dictionary((["example.com", "github.com"] + extensions.blocked(item.id)).map { host in
                        (host, URL(string: "https://\(host)/").map { context?.hasAccess(to: $0, in: extensions.activeAdapter) ?? false } ?? false)
                    }, uniquingKeysWith: { first, _ in first }),
                    "keys": (context?.commands ?? []).map { "\($0.id)=\(Hotkey.caps($0.activationKey?.lowercased(), $0.modifierFlags).joined())" },
                    // What it may ask for later: what was chosen, and what WebKit holds now.
                    "choices": Extensions.choices(item.id),
                    "sites": (context?.webExtension.allRequestedMatchPatterns ?? []).map(\.string).sorted(),
                    "optional": context.map { c -> [String: String] in
                        var out: [String: String] = [:]
                        for p in c.webExtension.optionalPermissions { out[p.rawValue] = Bench.status(c.permissionStatus(for: p)) }
                        for m in c.webExtension.optionalPermissionMatchPatterns { out[m.string] = Bench.status(c.permissionStatus(for: m)) }
                        return out
                    } ?? [:],
                ]
            }])
        case "ext-add":
            guard let text = request["id"] as? String else { answer(["error": "ext-add needs an id or link"]); return }
            extensions.install(from: text, confirm: !skip, giving: Set(request["give"] as? [String] ?? []))
            answer(["started": true])
        case "ext-add-frozen":
            guard Store.testing, let id = request["id"] as? String, let path = request["path"] as? String else {
                answer(["error": "ext-add-frozen needs a test session, id and path"]); return
            }
            let started = extensions.installFrozen(id, at: URL(fileURLWithPath: path), giving: Set(request["give"] as? [String] ?? []))
            answer(["started": started])
        case "ext-diagnostics":
            guard Store.testing, let id = request["id"] as? String else {
                answer(["error": "ext-diagnostics needs a test session and id"]); return
            }
            let background = extensions.contexts[id].flatMap(Extensions.backgroundViewForTesting)
            answer(["busy": extensions.busy == id,
                    "install_error": extensions.installErrors[id] ?? "",
                    "installed": extensions.installed.contains(where: { $0.id == id }),
                    "loaded": extensions.contexts[id] != nil,
                    "shim_popups": extensions.popupPaths[id] ?? [:],
                    "background_url": background?.url?.absoluteString ?? "",
                    "background_loading": background?.isLoading ?? false,
                    // WebKit's own words: a worker that failed to start says why.
                    "errors": extensions.contexts[id]?.errors.map { error in
                        let e = error as NSError
                        return "\(e.domain) \(e.code): \(e.localizedDescription) \(e.userInfo[NSUnderlyingErrorKey].map { "\($0)" } ?? "")"
                    } ?? []])
        case "ext-background":
            guard Store.testing, let id = request["id"] as? String,
                  let script = request["js"] as? String,
                  let context = extensions.contexts[id],
                  let background = Extensions.backgroundViewForTesting(context) else {
                answer(["error": "No native background view in this test context"]); return
            }
            background.evaluateJavaScript(script) { value, error in
                if let error { answer(["error": error.localizedDescription]) }
                else { answer(["value": value ?? NSNull()]) }
            }
        case "ext-folder":
            guard let path = request["path"] as? String else { answer(["error": "ext-folder needs a path"]); return }
            extensions.installFolder(at: URL(fileURLWithPath: path), confirm: !skip, giving: Set(request["give"] as? [String] ?? []))
            answer(["started": true])
        case "ext-press":
            guard let id = request["id"] as? String else { answer(["error": "ext-press needs an id"]); return }
            // Pressed where it is: in the list, while the list is up.
            if ExtensionPanel.shared.isShown { ExtensionPanel.shared.press(id) } else { extensions.press(id) }
            answer(["pressed": true])
        case "ext-withheld":
            // The popover in a popup's place while iCloud Passwords waits
            // on Apple (ExtensionWithheld), and its window, for a picture.
            answer(ExtensionWithheld.shared.state)
        case "ext-enable":
            guard let id = request["id"] as? String else { answer(["error": "ext-enable needs an id"]); return }
            extensions.setEnabled(id, request["on"] as? Bool ?? true)
            answer(["enabled": request["on"] as? Bool ?? true])
        case "ext-answer":
            // In a test run: answer every extension's question yes or no
            // without asking, or go back to asking.
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            switch request["answer"] as? String {
            case "yes": extensions.answerForTests = true
            case "no": extensions.answerForTests = false
            default: extensions.answerForTests = nil
            }
            answer(["answer": request["answer"] as? String ?? "ask", "asked": extensions.asked])
        case "ext-shot":
            // A picture of the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view, let path = request["path"] as? String
            else { answer(["error": "no popup open for that extension"]); return }
            shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
        case "ext-menu":
            // The list behind the puzzle button, as a picture; "dark" as
            // site-shot's.
            guard let path = request["path"] as? String, let data = extensionMenuPicture(dark: request["dark"] as? Bool)?.representation(using: .png, properties: [:]) else {
                answer(["error": "ext-menu needs a path"])
                return
            }
            do { try data.write(to: URL(fileURLWithPath: path)); answer(["saved": path]) }
            catch { answer(["error": error.localizedDescription]) }
        case "site-facts":
            // What Site Controls says of the tab in front: its site, its zoom,
            // the camera and microphone in use, and each thing the site was
            // allowed or refused and remembered (`forget`: that row's title
            // let go, as its Forget does).
            guard let tab = browser.active else { answer(["error": "no tab in front"]); return }
            let facts = SiteFacts(tab: tab)
            if let title = request["forget"] as? String { facts.allowed.first { $0.title == title }?.forget() }
            answer(["site": facts.site, "secure": facts.secure, "zoom": Double(tab.zoom), "connection": facts.connection.title, "certificate": facts.trust != nil,
                    "camera": tab.camera == .active, "microphone": tab.microphone == .active,
                    "allowed": facts.allowed.map { ["title": $0.title, "said": $0.said ? "Allowed" : "Blocked"] }])
        case "site-shot":
            // Site Controls for the tab in front, drawn off screen: "main" or
            // "connection".
            guard let path = request["path"] as? String else { answer(["error": "site-shot needs a path"]); return }
            let page: SitePage = request["page"] as? String == "connection" ? .connection : .main
            // "hidden": true draws it with what was hidden here listed;
            // "dark": true or false, dark or light whatever Yab is in.
            let hidden = request["hidden"] as? Bool ?? false
            guard let data = siteControlsPicture(browser, page: page, hidden: hidden, dark: request["dark"] as? Bool)?.representation(using: .png, properties: [:]) else {
                answer(["error": "no tab in front"])
                return
            }
            do { try data.write(to: URL(fileURLWithPath: path)); answer(["saved": path, "plated": browser.sidePlated]) }
            catch { answer(["error": error.localizedDescription]) }
        case "answer-links":
            // The links in answers on screen (AnswerLinks), where each is from
            // the top left of the first screen for a real pointer to rest on,
            // and the tip up now: its words, and drawn to `path` while it shows.
            let live = AnswerLinks.shared.live.allObjects
            var out: [String: Any] = ["links": live.flatMap { $0.onScreen() },
                                      "words": live.map { ["spots": $0.spots.count, "view": $0.view != nil, "window": $0.view?.window != nil] },
                                      "tipShown": KeyTip.shared.showing, "tipTitle": KeyTip.shared.lastTitle,
                                      "tip": "\(KeyTip.shared.lastFrame)"]
            if let path = request["path"] as? String { out["drawn"] = KeyTip.shared.snapshot(to: URL(fileURLWithPath: path)) }
            answer(out)
        case "ext-tip":
            // A button's tip as the column's pin says it (ExtensionTip), where
            // its pin is on screen for a real pointer to rest on, and the tip
            // up now: its words, and drawn to `path` while it shows.
            guard let id = request["id"] as? String else { answer(["error": "ext-tip needs an id"]); return }
            let button = extensions.buttons.first { $0.id == id }
            var out: [String: Any] = ["label": button?.label ?? "", "keys": button?.keys ?? "",
                                      "asleep": extensions.asleep.contains(id), "starting": extensions.starting.contains(id),
                                      "loaded": extensions.contexts[id] != nil,
                                      // What the rule was given (ExtensionTip.label).
                                      "action": extensions.contexts[id]?.action(for: extensions.activeAdapter)?.label ?? "",
                                      "displayName": extensions.contexts[id]?.webExtension.displayName ?? "",
                                      "shortName": extensions.contexts[id]?.webExtension.displayShortName ?? "",
                                      "name": extensions.installed.first { $0.id == id }?.name ?? "",
                                      "tipShown": KeyTip.shared.showing, "tipTitle": KeyTip.shared.lastTitle, "tipKeys": KeyTip.shared.lastKeys ?? ""]
            if let view = extensions.anchors[id]?.view, let window = view.window {
                let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
                out["pin"] = [rect.minX, rect.minY, rect.width, rect.height]
                out["screenHeight"] = NSScreen.screens.first?.frame.height ?? 0
            }
            if let path = request["path"] as? String { out["drawn"] = KeyTip.shared.snapshot(to: URL(fileURLWithPath: path)) }
            // "take": its key, "k" with ⌥⇧ ("flags", raw), handed to the
            // extensions' key handling as a press of it is.
            if let key = request["take"] as? String, let character = key.first,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(request["flags"] as? Int ?? 0)),
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Links.window?.windowNumber ?? 0,
                                            context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                            keyCode: Bench.keyCode(for: character)) {
                out["taken"] = ChromiumExtensionCommands.take(event, in: browser) || extensions.take(event)
            }
            answer(out)
        case "ext-commands":
            // Settings › Shortcuts' extension groups: one command's alias,
            // on switch and key set as its row sets them, run as ⌘T runs
            // it, and the groups drawn to `path` off screen. Where Settings
            // is, and the chrome:// page last answered (ChromePages).
            var recorded: [String: Any] = [:]
            if let id = request["id"] as? String, let command = request["command"] as? String {
                var kept = ExtensionCommands.kept(id, command)
                if let alias = request["alias"] as? String {
                    if let problem = ExtensionCommands.aliasProblem(alias, for: id, command, ids: extensions.installed.map(\.id)) {
                        answer(["refused": problem]); return
                    }
                    kept.alias = ExtensionCommands.clean(alias)
                }
                if let on = request["on"] as? Bool { kept.off = !on }
                extensions.setCommand(kept, extension: id, command: command)
                if let key = request["key"] as? String {
                    extensions.setKey(key.isEmpty ? nil : Hotkey(key, NSEvent.ModifierFlags(rawValue: UInt(request["flags"] as? Int ?? 0))),
                                      extension: id, command: command)
                }
                // "record": keys pressed into its row's recorder, "cmd+shift+w":
                // what the recorder says of whoever has them, and with
                // "again" the second press that takes them, as the row does.
                if let keys = request["record"] as? String, let (flags, name, _) = Bench.chord(keys), !name.isEmpty {
                    let hotkey = Hotkey(name, flags)
                    let own = extensions.contexts[id]?.commands.first { $0.id == command }
                    let entry = extensions.commandGroups().first { $0.item.id == id }?.commands.first { $0.command == command }
                    switch entry.map({ ExtensionCommandRow.clash(hotkey, entry: $0, command: own) }) ?? Keymap.shared.clash(hotkey, for: nil, command: own) {
                    case nil:
                        extensions.setKey(hotkey, extension: id, command: command)
                        recorded = ["said": "", "taken": true]
                    case .taken(let words, let free):
                        recorded = ["said": words, "taken": request["again"] as? Bool == true]
                        if request["again"] as? Bool == true {
                            free()
                            extensions.setKey(hotkey, extension: id, command: command)
                        }
                    case .refused(let words):
                        recorded = ["said": words, "taken": false, "refused": true]
                    }
                }
                if request["run"] as? Bool == true { extensions.run(id, command: command) }
            }
            var out: [String: Any] = ["groups": extensions.commandGroups().map { group -> [String: Any] in
                ["id": group.item.id, "short": group.short, "commands": group.commands.map { entry -> [String: Any] in
                    ["command": entry.command, "title": entry.title, "keys": entry.keys?.text ?? "",
                     "alias": entry.kept.alias, "on": !entry.kept.off, "chromium": entry.chromium]
                }]
            }, "recorded": recorded, "settings": SettingsWindow.shared.benchWhere, "routed": ChromePages.last,
               "closeWindow": Keymap.shared.text(.closeWindow), "taken": Extensions.lastTaken,
               // The helper runs named commands in Chromium (CEF patch 0116).
               "chromiumRunsNamed": ChromiumExtensionCommands.runsNamed,
               "windows": BrowserWindows.shared.browsers.filter { BrowserWindows.shared.window(for: $0)?.isVisible == true }.count]
            if let path = request["path"] as? String {
                let dark = request["dark"] as? Bool ?? false
                out["shot"] = Bench.userscriptOffscreen(
                    ThreadForm { ExtensionCommandSections(filter: request["filter"] as? String ?? "") }
                        .formStyle(.grouped)
                        .frame(width: 640, height: request["height"] as? CGFloat ?? 620)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .background(dark ? Color(white: 0.12) : Color(white: 0.96)),
                    to: path)
            }
            answer(out)
        case "ext-pin":
            guard let id = request["id"] as? String else { answer(["error": "ext-pin needs an id"]); return }
            extensions.setPinned(id, request["on"] as? Bool ?? true)
            answer(["pinned": request["on"] as? Bool ?? true])
        case "ext-reload":
            guard let id = request["id"] as? String else { answer(["error": "ext-reload needs an id"]); return }
            extensions.reload(id)
            answer(["reloading": true])
        case "ext-scan", "ext-bring":
            guard let name = request["browser"] as? String,
                  var source = Chromium.known.first(where: { $0.name.lowercased() == name.lowercased() })
            else { answer(["error": "\(verb) needs a browser: " + Chromium.known.map(\.name).joined(separator: ", ")]); return }
            // A made-up browser folder, in a test run (evals/extensions/import_signin_storm.py).
            if Store.testing, let path = request["path"] as? String { source.dataRoot = URL(fileURLWithPath: path) }
            let found = Chromium.extensions(in: source)
            if verb == "ext-scan" {
                answer(["extensions": found.map { ["id": $0.id, "name": $0.name, "store": $0.fromStore, "enabled": $0.enabled, "folder": $0.folder.path] }])
                return
            }
            // Only in a test run: a real browser's extensions are brought in
            // from Settings.
            guard Store.testing else { answer(["error": "ext-bring is for --test runs"]); return }
            let ids = request["ids"] as? [String] ?? []
            let picked = found.filter { ids.isEmpty ? $0.enabled : ids.contains($0.id) }
            // "profiles": as the welcome brings them, each profile's into
            // the sign-in of its space (evals/extensions/wallet_sign_ins.py).
            if request["profiles"] as? Bool == true {
                browser.profileSpaces(from: source)
                Extensions.bringIn(byProfile: picked, from: source, spaces: browser.spaces)
            } else {
                extensions.bringIn(picked, from: source.name)
            }
            answer(["started": picked.map(\.id), "profiles": picked.map(\.profiles)])
        case "ext-remove":
            guard let id = request["id"] as? String else { answer(["error": "ext-remove needs an id"]); return }
            extensions.remove(id)
            answer(["removed": true])
        case "ext-popup":
            // JavaScript in the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view
            else { answer(["error": "no popup open for that extension"]); return }
            web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }
        case "ext-side-panel":
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            if request["select"] as? String == "chat" { browser.panelExtension = nil }
            if let id = request["open"] as? String {
                extensions.openPanel(id, in: browser, tabID: request["tabId"] as? Int)
            }
            if let id = request["choose"] as? String { extensions.openPanelChoice(id, in: browser) }
            let selected = browser.panelExtension ?? ""
            let choices = extensions.panelChoices(in: browser).map { ["id": $0.id, "name": $0.name] }
            let native = BrowserWindows.shared.window(for: browser)
            func columnHosts(_ view: NSView?) -> Int {
                guard let view else { return 0 }
                return (view is ChatColumnView ? 1 : 0) + view.subviews.reduce(0) { $0 + columnHosts($1) }
            }
            let hostCount = columnHosts(native?.contentView)
            guard let page = extensions.panelPage(selected, in: browser) else {
                answer(["selected": selected, "tabs": browser.tabs.count, "open": browser.chatOpen,
                        "nativeWindow": native?.windowNumber ?? -1, "hostCount": hostCount,
                        "choices": choices]); return
            }
            if let path = request["shot"] as? String {
                shoot(page.web, to: URL(fileURLWithPath: path), width: nil, answer)
            } else if let js = request["js"] as? String {
                page.web.evaluateJavaScript(js) { value, error in
                    MainActor.assumeIsolated {
                        if let error { answer(["error": error.localizedDescription]); return }
                        answer(["value": Bench.plain(value)])
                    }
                }
            } else {
                let rect = page.web.window.map { $0.convertToScreen(page.web.convert(page.web.bounds, to: nil)) } ?? .zero
                answer(["contentOnScreen": [rect.minX, (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, rect.width, rect.height],
                        "selected": selected, "url": page.web.url?.absoluteString ?? "",
                        "tabs": browser.tabs.count, "open": browser.chatOpen,
                        "attached": page.web.window != nil,
                        "hasSuperview": page.web.superview != nil,
                        "nativeWindow": native?.windowNumber ?? -1, "hostCount": hostCount,
                        "choices": choices])
            }
        case "ext-popout":
            // Extensions' popout windows (ExtensionPopout), listed, with the
            // browser window in front for where they stand; given a
            // `window`, `js` run in its page, `shot` its page's picture to
            // that path, or `close` closed by its close button.
            let popouts = ExtensionPopout.open
            guard let number = request["window"] as? Int else {
                let box = { (f: NSRect) in [f.minX, f.minY, f.width, f.height].map(Double.init) }
                answer(["popouts": popouts.map { popout -> [String: Any] in
                    ["window": popout.window.windowNumber, "extension": popout.extensionID, "title": popout.window.title,
                     "url": popout.web.url.map(Extensions.popped)?.absoluteString ?? "",
                     "view": popout.web.url?.absoluteString ?? "", "frame": box(popout.window.frame),
                     "key": popout.window.isKeyWindow, "visible": popout.window.isVisible,
                     // Under its pin (ExtensionWindowFrame).
                     "hung": popout.shown.underPin != nil, "pin": popout.shown.underPin.map(box) ?? [], "page": box(popout.web.frame),
                     "header": popout.shown.owner.name,
                     "lit": ExtensionWindowFrame.Hung.shared.ids.contains(popout.extensionID)]
                }, "browser": BrowserWindows.shared.window(for: browser).map { box($0.frame) } ?? []])
                return
            }
            guard let popout = popouts.first(where: { $0.window.windowNumber == number }) else {
                answer(["error": "no popout in window \(number)"])
                return
            }
            if request["close"] as? Bool == true {
                popout.window.performClose(nil)
                answer(["closed": number])
            } else if let path = request["shot"] as? String {
                shoot(popout.web, to: URL(fileURLWithPath: path), width: nil, answer)
            } else {
                popout.web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                    MainActor.assumeIsolated {
                        if let error { answer(["error": error.localizedDescription]); return }
                        answer(["value": Bench.plain(value)])
                    }
                }
            }
        case "debugger":
            // Which tabs an extension holds with chrome.debugger, by tab
            // id, as the dock at their foot says; `stop` (a tab id) presses
            // that dock's Stop (evals/extensions/debugger.py).
            let debugger = ExtensionDebugger.shared
            if let ref = (request["stop"] as? String)?.lowercased(),
               let tab = BrowserWindows.shared.browsers.flatMap(\.tabs).first(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }) {
                debugger.stop(tab)
            }
            answer(["missed": debugger.missed, "holders": debugger.holders.map { id, holders in
                ["tab": id.uuidString, "names": holders.map(\.name), "extensions": holders.map(\.extensionID),
                 "asks": BrowserWindows.shared.browsers.flatMap { $0.tabs + $0.outside }.first { $0.id == id }.map { $0.asks.map { "\($0.kind)" } } ?? []]
            }])
        case "ext-search-engines":
            // The engines installed extensions bring, as Settings › Search ›
            // Search with lists them; `pick` (an extension id) chooses one
            // there, `yab` goes back to one of Yab's own by its raw name.
            if let id = request["pick"] as? String, let provider = ExtensionSearchProviders.all.first(where: { $0.extensionID == id }) {
                ExtensionSearchProviders.pick(provider, in: browser.prefs)
            }
            if let raw = request["yab"] as? String, let engine = Engine(rawValue: raw) {
                ExtensionSearchProviders.forget()
                browser.prefs.engine = engine
            }
            answer(["engines": ExtensionSearchProviders.all.map { ["id": $0.extensionID, "name": $0.name, "template": $0.template] },
                    "picked": ExtensionSearchProviders.picked ?? "", "name": Engine.name, "engine": browser.prefs.engine.rawValue])
        case "ext-page":
            // One of the extension's own pages in a bench tab, where `eval`
            // runs with the extension's APIs.
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "no such extension loaded"])
                return
            }
            let path = (request["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let tab = browser.benchOpen(context.baseURL.appendingPathComponent(path))
            house(tab)
            answer(describe(tab))
        default:
            answer(Bench.unknown(verb))
        }
    }

    /// A verb this build has no word for, said with the build, so whoever
    /// sent it can tell it came from another (Wire.stranger says the rest).
    nonisolated static func unknown(_ verb: String) -> [String: Any] {
        ["error": "this Yab (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")) doesn't know “\(verb)”", "unknown": verb]
    }

    func find(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        // A small window's page too, by the id `links` gives.
        // And one parked in another space, as a video out across spaces.
        return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
            ?? browser.parkedTabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
            ?? browser.outside.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    /// The window a call works in: `browser`, or the one holding the tab it
    /// names when that is another. A task's own tabs stay in the first
    /// window when it closes, while its calls go to the one in front (#819),
    /// and what a verb does to a tab's window must be done to its own.
    func holder(of request: [String: Any], in browser: Browser) -> Browser {
        guard find(request, in: browser) == nil else { return browser }
        return BrowserWindows.shared.browsers.first { find(request, in: $0) != nil } ?? browser
    }

    /// The window a call runs in when the call doesn't pick one.
    private func target(_ request: [String: Any]) -> Browser? {
        browser.map { holder(of: request, in: BrowserWindows.shared.live($0)) }
    }

    @available(macOS 15.4, *)
    static func status(_ status: WKWebExtensionContext.PermissionStatus) -> String {
        switch status {
        case .grantedExplicitly: return "granted"
        case .grantedImplicitly: return "granted-implicitly"
        case .requestedExplicitly: return "requested"
        case .requestedImplicitly: return "requested-implicitly"
        case .deniedExplicitly: return "denied"
        case .deniedImplicitly: return "denied-implicitly"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    /// Whether the Touch ID question was up when `fill` took it down.
    static var sawQuestion = false

    /// The code card question-up raised last, read by "pairing-state".
    static var pairing: ApplePasswordsPairing.CodeModel?

    /// Passwords that would end a string they were written into, or run
    /// as code inside one: quotes of every kind, a template's `${}`, a
    /// backslash before each, line breaks, a script's end tag, and
    /// characters past ASCII, joined and emoji included.
    static let trickyPasswords: [(user: String, password: String)] = [
        ("plain@example.com", "hunter2"),
        ("o'brien@example.com", "it's \"quoted\" 'twice'"),
        ("back`tick", "`${alert(1)}` and ${window.x = 1}"),
        ("slash\\user", "C:\\new\\table\\$HOME\\`"),
        ("lines", "one\ntwo\r\nthree\u{2028}four\u{2029}five\tsix"),
        ("tags", "</script><script>alert(1)</script>"),
        ("üñï©ødé", "κωδικός-密码-🔑👨‍👩‍👧-e\u{301}"),
        ("json", "\"]); alert(1); (["),
        ("nul", "a\u{0}b"),
        ("", "   spaces   "),
    ]

    /// One after another: the boxes emptied, filled, read back. Read in
    /// yab's own world, where the fill runs: what the page script was
    /// handed, what the boxes hold (a box drops line breaks, as any does),
    /// and whether anything in the password ran as code.
    private func fillTricky(_ tab: Tab, _ left: [(user: String, password: String)], read: String, results: [[String: Any]], _ answer: @escaping ([String: Any]) -> Void) {
        guard let next = left.first else {
            answer(["cases": results, "passed": results.filter { $0["ok"] as? Bool == true }.count, "of": results.count])
            return
        }
        let reset = """
        (() => {
          document.querySelectorAll('input').forEach(i => i.value = '');
          window.x = 0; window.__benchSeen = null;
          const f = window.__yabForms && window.__yabForms.fill;
          if (f && !f.__bench) {
            window.__yabForms.fill = function (u, p) { window.__benchSeen = [u, p]; return f.apply(this, arguments); };
            window.__yabForms.fill.__bench = true;
          }
          return !!f;
        })()
        """
        tab.page.runInYab(reset) { _ in
            tab.fill(user: next.user, password: next.password) { filled in
                tab.page.runInYab("JSON.stringify({seen: window.__benchSeen, boxes: \(read), x: window.x})") { value in
                    let got = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
                    let seen = got["seen"] as? [String] ?? []
                    let boxes = (got["boxes"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String] ?? []
                    let flat = next.password.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    let ok = filled == .filled && seen == [next.user, next.password]
                        && boxes.count >= 2 && boxes[0] == next.user && boxes[1] == flat
                        && (got["x"] as? Int) == 0
                    var row: [String: Any] = ["user": next.user, "ok": ok, "filled": "\(filled)"]
                    if !ok { row["seen"] = seen; row["boxes"] = boxes; row["x"] = got["x"] ?? "?" }
                    self.fillTricky(tab, Array(left.dropFirst()), read: read, results: results + [row], answer)
                }
            }
        }
    }

    func missing(_ request: [String: Any]) -> [String: Any] {
        let ref = request["id"] as? String ?? ""
        return ["error": AgentTabCleanup.shared.closedNote(ref) ?? "no tab “\(ref)”, see tabs"]
    }

    /// The space's name over the column's rows (SpaceName), on the screen
    /// from its top left as a CGEvent counts, and in the window: x, y, width
    /// and height. Empty while no name is drawn.
    func spaceHead(_ browser: Browser) -> [String: [Double]] {
        guard let top = browser.nameTop, let window = Links.window, let screen = NSScreen.screens.first else { return [:] }
        let column = browser.flank == .left ? 0 : window.frame.width - browser.prefs.sideWidth
        let local = CGRect(x: column + SideBar.margin, y: top, width: browser.prefs.sideWidth - 2 * SideBar.margin, height: SideBar.row)
        let onScreen = local.offsetBy(dx: window.frame.minX, dy: screen.frame.maxY - window.frame.maxY)
        func values(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        return ["window": values(local), "screen": values(onScreen)]
    }

    func describe(_ tab: Tab) -> [String: Any] {
        // The window the tab is in: a second window's tab in front is its own.
        let owner = BrowserWindows.shared.browsers.first { $0.tabs.contains { $0 === tab } } ?? browser
        return [
            "id": Bench.short(tab),
            "url": tab.address?.absoluteString ?? "",
            // What its row says (a short name, a search's part), not the page's title.
            "row": tab.rowLabel,
            "title": tab.title,
            "count": tab.count ?? -1,
            "countCorner": tab.countCorner?.words ?? "",
            "unadornedCountCorner": tab.unadornedCountCorner?.words ?? "",
            "showsOwnCount": tab.showsOwnCount,
            "loading": tab.loading,
            "drawn": tab.drawn,
            // What WebKit says of the load, and what the tab's end shows of it.
            "progress": tab.builtPage?.estimatedProgress ?? 0,
            "spinning": tab.spinning,
            "hollow": tab.hollow,
            "view": tab.builtPage?.url?.absoluteString ?? "",
            "bench": tab.bench,
            "active": tab.id == owner?.activeID,
            "asleep": tab.asleep,
            "muted": tab.muted,
            "agent": tab.agent ?? "",
            // A task at work in this tab of yours, and a question waiting in it.
            "guest": tab.guest ?? "",
            "question": tab.permit != nil,
            "handoff": tab.handoff ?? "",
            "shy": tab.shy,
            "label": tab.label,
            "rowLabel": tab.rowLabel,
            "pinned": tab.pin != nil,
            "kept": tab.kept,
            "customMark": tab.customMark ?? "",
            // The mark it wears: "picture", "blank" (one that draws nothing,
            // feedback #368) or "letter".
            "mark": tab.displayIcon.map { Favicons.blank($0) ? "blank" : "picture" } ?? "letter",
            // Where it was pinned or kept, and gone on from there.
            "home": tab.home?.absoluteString ?? "",
            "away": tab.awayFromHome,
            "folder": tab.nest?.name ?? "",
            // Its folder and the folders it is in, from the top down.
            "folderPath": tab.nest?.chain.map(\.name) ?? [],
            "folderToday": tab.nest?.today ?? false,
            "reader": tab.reader,
            "readable": tab.readable,
            "reading": (tab.reading * 100).rounded() / 100,
            "store": tab.shy ? String(UInt(bitPattern: ObjectIdentifier(tab.store).hashValue), radix: 16) : "",
            // Its page's process, 0 with none: a number that changes is a
            // page loaded again in a new one.
            "pid": Int(tab.builtPage?.contentProcess ?? 0),
            // Where the page last said it was scrolled, and where it goes
            // back to once loaded again after sleep or its process going.
            "y": Int(tab.lastY),
            "place": Int(tab.place?.y ?? 0),
            // The color the strip wears for this page, "" for none.
            "tone": tab.tone?.hex ?? "",
            // The color of the icon it wears, "" for a letter.
            "icon": Scope.average(of: tab.icon)?.hex ?? "",
            // What the page says instead of itself, "This page keeps crashing".
            "failure": tab.failure ?? "",
            // The host of the Untrusted page standing in for the site, "" for none.
            "untrusted": tab.untrusted?.host ?? "",
            // Known not to answer (Deaf.swift), and asked about it now.
            "deaf": tab.deaf != nil,
            "deafAsked": tab.deafAsked,
            "sleeping": tab.asleep,
            // What the toolbar's Back and Forward say, and the page's own
            // lists behind and ahead of it.
            "canBack": tab.canGoBack,
            "canForward": tab.canGoForward,
            "backList": tab.webKitOnly("WebKit-only bench fixtures", build: false)?.backForwardList.backList.count ?? 0,
            "forwardList": tab.webKitOnly("WebKit-only bench fixtures", build: false)?.backForwardList.forwardList.count ?? 0,
            // Its page's zoom, 1 at Actual Size.
            "zoom": Double(tab.zoom),
        ]
    }

    /// A sheet's boxes as `probe` reports them: what each holds, a password
    /// as its length only, and which has the caret.
    static func fields(of sheet: NSWindow) -> [String: Any] {
        let editor = sheet.firstResponder as? NSText
        let boxes = boxes(in: sheet.contentView).map { box -> [String: Any] in
            [
                "secure": box is NSSecureTextField,
                "value": box is NSSecureTextField ? String(repeating: "•", count: box.stringValue.count) : box.stringValue,
                "placeholder": box.placeholderString ?? "",
                "caret": sheet.firstResponder === box || (editor?.delegate as? NSTextField) === box,
            ]
        }
        return ["title": (sheet.contentView.flatMap { texts(in: $0) } ?? []).first ?? "", "boxes": boxes]
    }

    static func boxes(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let here = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return here + view.subviews.flatMap { boxes(in: $0) }
    }

    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private static func texts(in view: NSView) -> [String] {
        let here = (view as? NSTextField).map { !$0.isEditable && !$0.stringValue.isEmpty ? [$0.stringValue] : [] } ?? []
        return here + view.subviews.flatMap { texts(in: $0) }
    }

    static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// Each live thread's time on a core, in seconds, summed by name; the
    /// first thread of the task is the main one (bench cputhreads).
    static func threadTimes() -> [String: Double] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var by: [String: Double] = [:]
        for i in 0..<Int(count) {
            var info = thread_extended_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
            let read = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size) }
            }
            guard read == KERN_SUCCESS else { continue }
            let name = withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let key = i == 0 ? "main" : name.isEmpty ? "unnamed" : name
            by[key, default: 0] += Double(info.pth_user_time + info.pth_system_time) / 1e9
        }
        return by
    }

    /// Once the page has stopped loading, or the time is up.
    func wait(for tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        if !tab.loading, tab.address != nil, tab.failure == nil || true {
            // A beat for the document's own scripts to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var out = describe(tab)
                if let failure = tab.failure { out["failure"] = failure }
                answer(out)
            }
            return
        }
        guard Date() < limit else {
            var out = describe(tab)
            out["timeout"] = true
            answer(out)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: tab, until: limit, answer)
        }
    }

    // MARK: - the room off screen

    private var room: NSWindow?

    /// A page nobody is looking at has to be somewhere to be laid out at all.
    /// The stage takes it back the moment you pick its tab, and it comes
    /// here again when the bench next needs it.
    func house(_ tab: Tab) {
        guard tab.bench || tab.guest != nil else { return }
        if tab.bench { tab.touch() }
        let page = tab.page
        if let room { park(room) }
        if page.window == nil {
            let window = room ?? makeRoom()
            page.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            page.autoresizingMask = [.width, .height]
            // WebKit needs an offscreen visibility override. Chromium's
            // producer follows the owned view's attachment to this window.
            page.webKit?.seenOffscreen = true
            window.contentView?.addSubview(page)
        } else if page.window?.identifier == Bench.roomID, let web = page.webKit, !web.seenOffscreen {
            let window = web.window
            web.removeFromSuperview()
            web.seenOffscreen = true
            window?.contentView?.addSubview(web)
        }
        if page.webKit?.seenOffscreen == true || page.window?.identifier == Bench.roomID { worked(tab) }
    }

    /// A page seen where it is, in a window on no screen (Headless.linger),
    /// and judged by its window again (`unsee`): in and out of it, for
    /// WebKit to weigh it anew.
    func see(_ web: PageView) {
        guard !web.seenOffscreen, let host = web.superview else { return }
        web.removeFromSuperview()
        web.seenOffscreen = true
        web.keepSeen = true
        host.addSubview(web)
    }

    func unsee(_ web: PageView) {
        guard let host = web.superview else { return }
        web.keepSeen = false
        web.removeFromSuperview()
        web.seenOffscreen = false
        host.addSubview(web)
    }

    /// A call that shares a tab or a window Yab takes itself draws every
    /// picture into a canvas of its page, and a hidden page draws nothing:
    /// once the shown tab came forward the call's page left its window, no
    /// frame reached Meet and it said "Presentation is starting" forever.
    /// So while it shares, a call out of sight waits here, seen.
    func keepSharing(_ web: PageView) {
        guard web.window == nil || (web.window?.identifier == Bench.roomID && !web.seenOffscreen) else { return }
        let window = room ?? makeRoom()
        park(window)
        web.removeFromSuperview()
        if web.frame.width < 2 || web.frame.height < 2 {
            web.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        web.seenOffscreen = true
        window.contentView?.addSubview(web)
    }

    /// The share over: a call still here is a hidden tab again.
    func doneSharing(_ web: PageView, of tab: Tab?) {
        guard web.window?.identifier == Bench.roomID, web.seenOffscreen else { return }
        if let tab, working[ObjectIdentifier(tab)] != nil { return }
        web.removeFromSuperview()
        web.seenOffscreen = false
        if let tab, tab.bench || tab.guest != nil, let room { room.contentView?.addSubview(web) }
    }

    /// A task over: its pages in the room are hidden pages again, as any
    /// tab behind another is, until an agent next works in them.
    func rest(_ tab: Tab) {
        working.removeValue(forKey: ObjectIdentifier(tab))
        if let page = tab.builtPage, page.engine != .webKit {
            // A remote producer follows attachment. Leaving a rested page
            // in the room would keep it painting until the next command.
            if page.window?.identifier == Bench.roomID { page.removeFromSuperview() }
            return
        }
        tab.webKitOnly("WebKit-only bench fixtures", build: false)?.keepSeen = false
        guard let web = tab.webKitOnly("WebKit-only bench fixtures", build: false), web.seenOffscreen else { return }
        guard let window = web.window, window.identifier == Bench.roomID else { web.seenOffscreen = false; return }
        web.removeFromSuperview()
        web.seenOffscreen = false
        window.contentView?.addSubview(web)
    }

    // A seen page that moves costs the browser about 7% of a core and
    // its page's process 3% more (an animated canvas, measured 2026-09-28),
    // and an agent that came through `yab mcp` can stay attached for hours
    // between its calls. So a page is seen only near the work: one left
    // alone two minutes rests until the next call in it.
    private struct Working { weak var tab: Tab?; var at: Date }
    private var working: [ObjectIdentifier: Working] = [:]
    private var resting: Timer?
    private static let seenFor: TimeInterval = 120

    private func worked(_ tab: Tab) {
        working[ObjectIdentifier(tab)] = Working(tab: tab, at: Date())
        guard resting == nil else { return }
        resting = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restIdle() }
        }
    }

    private func restIdle() {
        let now = Date()
        for (key, work) in working where work.tab == nil || now.timeIntervalSince(work.at) > Bench.seenFor {
            if let tab = work.tab { rest(tab) } else { working.removeValue(forKey: key) }
        }
        if working.isEmpty {
            resting?.invalidate()
            resting = nil
        }
    }

    static let roomID = NSUserInterfaceItemIdentifier("bench.room")

    private func makeRoom() -> NSWindow {
        // Off every screen, and never key or main: it exists so that a web
        // view has a window, and for nothing else.
        let window = NSWindow(
            contentRect: NSRect(origin: Bench.away, size: NSSize(width: 1280, height: 800)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = Bench.roomID
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        // A screen plugged in or out, and the window server brings a window
        // that lies on no screen onto one: the room came down over the top
        // of the BenQ, under every window but over the desktop (seen
        // 2026-09-29). Sent back each time, and again a moment later, when
        // the window server has settled.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let room = self.room else { return }
                self.park(room)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { if let room = self?.room { self?.park(room) } }
                }
            }
        }
        return window
    }

    private static let away = NSPoint(x: -20000, y: -20000)

    private func park(_ window: NSWindow) {
        guard window.frame.origin != Bench.away else { return }
        window.setFrameOrigin(Bench.away)
    }

    private func shoot(_ tab: Tab, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        tab.page.snapshot(PageShot(width: width.map { CGFloat($0) })) { image, error in
            self.saveShot(image, error: error, to: file, answer)
        }
    }

    // Inspector and extension surfaces are separate WebKit pages, not tabs.
    private func shoot(_ web: WKWebView, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                self.saveShot(image, error: error, to: file, answer)
            }
        }
    }

    private func saveShot(_ image: NSImage?, error: Error?, to file: URL, _ answer: ([String: Any]) -> Void) {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            answer(["error": error?.localizedDescription ?? "no picture"])
            return
        }
        do {
            try png.write(to: file)
            answer(["path": file.path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
        } catch {
            answer(["error": error.localizedDescription])
        }
    }

    /// A layer tree drawn in-process, as near as that gets to what is on
    /// screen. A glass plate cuts its shape out of what it holds with a
    /// layer composited "destIn" (keep only what lies under me): on screen
    /// that stays inside the plate, but a render applies it to everything
    /// drawn before it, so with an agent's step or a notice up, the page and
    /// the backdrop came out clear, and the tabs drawn after on nothing (a
    /// light tab on a black strip, 2026-10-01). Such layers are left out
    /// while drawing and put back before anything is committed: the plate
    /// comes out a see-through gray, as glass always has here, and the
    /// window never changes.
    /// The layers over `point` (in `root`'s space) that are see-through or
    /// animating, as the render server has them now: the view each belongs
    /// to, its opacity and its animations, outermost first.
    static func layersOver(_ point: CGPoint, in root: CALayer) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer, _ at: CGPoint, _ depth: Int) {
            guard !layer.isHidden, depth < 60, found.count < 80 else { return }
            let shown = layer.presentation() ?? layer
            let keys = layer.animationKeys() ?? []
            if layer.bounds.contains(at), shown.opacity < 0.999 || !keys.isEmpty {
                let owner = layer.delegate.map { "\(type(of: $0))" } ?? "-"
                found.append("\(depth) \(owner) \(type(of: layer)) op=\(String(format: "%.3f", shown.opacity)) \(keys.joined(separator: ","))")
            }
            for sub in layer.sublayers ?? [] {
                let p = sub.convert(at, from: layer)
                if sub.bounds.contains(p) || !sub.masksToBounds { walk(sub, p, depth + 1) }
            }
        }
        walk(root, point, 0)
        return found
    }

    static func render(_ root: CALayer, in context: CGContext) {
        // The ways of compositing that reach past the layer's own edges.
        let reaching: Set<String> = ["destIn", "destAtop", "sourceIn", "sourceOut", "copy", "clear"]
        var cutters: [CALayer] = []
        func walk(_ layer: CALayer) {
            guard !layer.isHidden else { return }
            if let filter = layer.compositingFilter.map({ "\($0)" }), reaching.contains(filter) {
                cutters.append(layer)
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutters.forEach { $0.isHidden = true }
        root.render(in: context)
        cutters.forEach { $0.isHidden = false }
        CATransaction.commit()
    }

    // MARK: - page-side helpers

    /// A JavaScript value the way JSON can carry it.
    static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    /// What an agent's script gave back, at most `limit` bytes of JSON: a
    /// value bigger than that is its start, said cut. A whole page's
    /// markup or a long list came back whole, held the browser while it
    /// was written, and was cut by the client anyway (Claude Code keeps
    /// about 25,000 tokens of a tool's answer).
    nonisolated static func capped(_ value: Any, limit: Int = 400_000) -> Any {
        if let text = value as? String {
            guard text.utf8.count > limit else { return text }
            return String(decoding: text.utf8.prefix(limit), as: UTF8.self)
                + "\n… cut: the value was \(text.utf8.count / 1000) KB; return less (a count, a slice, the fields you need)"
        }
        guard value is [Any] || value is [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              data.count > limit else { return value }
        return String(decoding: data.prefix(limit), as: UTF8.self)
            + "\n… cut: the value was \(data.count / 1000) KB of JSON; return less (a count, a slice, the fields you need)"
    }

    /// Click, type into, or submit the element a selector names. Typing goes
    /// through the field's own setter and fires the events a keystroke
    /// would, the same as the password filler, so frameworks notice.
    private static func act(_ verb: String, selector: String, text: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let txt = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var el = document.querySelector(\(sel));
          if (!el) return 'nothing matches ' + \(sel);
          if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var verb = '\(verb)';
          if (verb === 'click') { el.focus && el.focus(); el.click(); return 'ok'; }
          if (verb === 'submit') {
            var form = el.tagName === 'FORM' ? el : el.form || el.closest('form');
            if (!form) return 'no form around ' + \(sel);
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
            return 'ok';
          }
          el.focus && el.focus();
          var value = \(txt);
          if (el.isContentEditable) {
            el.textContent = value;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
            return 'ok';
          }
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
    }
}

/// A mouse's wheel over the row of tabs, for `pace wheel`: a line every
/// 50 ms, down for the first half, up for the second, posted to the app's
/// queue as the wheel's own events are, at the middle of the row, and where
/// the run has scrolled to after each. `page`: a trackpad's scroll over the
/// middle of the page instead, 40 points at a time, for what every other
/// scroll pays for the row listening. `across`: a trackpad's sideways over
/// the row, 40 points at a time, the row's own scrolling, for what a wheel's
/// line costs beside it.
@MainActor
final class Spin {
    enum Kind: String { case wheel, page, across, fingers, column }
    private(set) var offsets: [Double] = []
    private var sent = 0
    private var timer: Timer?
    private let kind: Kind

    init(seconds: Double, kind: Kind, by: Double = 14) {
        self.kind = kind
        if kind == .column {
            // Down for half the time and back up, the fingers on the pad
            // throughout (no glide), `by` points a frame.
            let beat = 1.0 / 60
            let half = max(4, Int(seconds / beat / 2) - 2)
            var script: [(dy: Int32, phase: Int64)] = []
            for way: Int32 in [-1, 1] {
                script.append((0, 1))
                script += Array(repeating: (Int32(by) * way, 2), count: half)
                script.append((0, 4))
            }
            let start = DispatchTime.now().uptimeNanoseconds
            var at = 0
            let timer = Timer(timeInterval: beat, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, at < script.count else { return timer.invalidate() }
                    let move = script[at]
                    // Where the rows stand, each beat, to show they moved.
                    if at % 6 == 0 { self.note() }
                    self.post(move.dy, phase: move.phase, momentum: 0, time: start + UInt64(at) * 1_000_000_000 / 60)
                    at += 1
                    self.sent = at
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return
        }
        if kind == .fingers {
            // Half the time each: 20 moves with the fingers down, then 30 of
            // glide, down the first time and back up the second.
            let beat = 1.0 / 60
            var script: [(dy: Int32, phase: Int64, momentum: Int64)] = []
            for way: Int32 in [-1, 1] {
                script.append((0, 1, 0))
                script += Array(repeating: (6 * way, 2, 0), count: 20)
                script.append((0, 4, 0))
                script.append((4 * way, 0, 1))
                script += Array(repeating: (3 * way, 0, 2), count: 28)
                script.append((0, 0, 3))
            }
            let start = DispatchTime.now().uptimeNanoseconds
            var at = 0
            let timer = Timer(timeInterval: beat, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, at < script.count else { return timer.invalidate() }
                    let move = script[at]
                    self.post(move.dy, phase: move.phase, momentum: move.momentum,
                              time: start + UInt64(at) * 1_000_000_000 / 60)
                    at += 1
                    self.sent = at
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return
        }
        let lines = max(2, Int(seconds / 0.05) - 2)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.sent < lines else { return timer.invalidate() }
                self.note()
                self.post(self.sent < lines / 2 ? -1 : 1)
                self.sent += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var report: [String: Any] {
        note()
        timer?.invalidate()
        return ["lines": sent, "offsets": offsets, "row": scroll != nil]
    }

    /// Over the column's rows, in the window's own space: a third of its
    /// width in from its edge, the middle of its height.
    static func overColumn(_ window: NSWindow) -> NSPoint {
        guard let content = window.contentView else { return .zero }
        let browser = BrowserWindows.shared.browser(for: window)
        let width = browser?.prefs.sideWidth ?? 240
        let left = browser?.flank != .right
        return content.convert(NSPoint(x: left ? width / 3 : content.bounds.width - width / 3, y: content.bounds.midY), to: nil)
    }

    /// A point over the column, in the window: `y` points down from the
    /// content's top (up from its bottom if negative; the middle without
    /// it), `x` in from the column's
    /// edge (a third of its width without it).
    static func columnPoint(y: Double?, x: Double?) -> NSPoint? {
        guard let window = Links.window, let content = window.contentView else { return nil }
        var point = overColumn(window)
        // Negative: up from the bottom.
        if let y { point.y = content.convert(NSPoint(x: 0, y: y < 0 ? -y : content.bounds.height - y), to: nil).y }
        if let x {
            let browser = BrowserWindows.shared.browser(for: window)
            let left = browser?.flank != .right
            point.x = content.convert(NSPoint(x: left ? x : content.bounds.width - x, y: 0), to: nil).x
        }
        return point
    }

    /// The views under a point of the window, innermost first, for the
    /// bench to say what a wheel went over.
    static func viewChain(at point: NSPoint?) -> [String] {
        guard let point, let frame = Links.window?.contentView?.superview else { return [] }
        var chain: [String] = []
        var view = frame.hitTest(frame.convert(point, from: nil))
        while let each = view, chain.count < 8 {
            chain.append(String(describing: type(of: each)).prefix(60).description)
            view = each.superview
        }
        return chain
    }

    /// A mouse's wheel at `point` of the window: `count` events of `dx`
    /// and `dy`, lines of a clicking wheel, or with `smooth` points of a
    /// precise one with no phase, `gap` seconds apart; stamped for the
    /// window as the window server stamps a real one (see Spin.post).
    static func wheel(dx: Double, dy: Double, count: Int, gap: Double, smooth: Bool, shift: Bool, at point: NSPoint?) {
        guard let point else { return }
        // Each stamped when it was due, as a wheel stamps its own: posted late
        // behind a busy frame (a film), they still read as one push.
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<max(1, count) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * gap) {
                MainActor.assumeIsolated {
                    guard let window = Links.window, let content = window.contentView,
                          let event = CGEvent(scrollWheelEvent2Source: nil, units: smooth ? .pixel : .line, wheelCount: 2,
                                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
                    if smooth { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
                    event.flags = shift ? .maskShift : []
                    event.timestamp = CGEventTimestamp(start + UInt64(Double(index) * gap * 1e9))
                    let screen = window.convertPoint(toScreen: point)
                    event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                    event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                    typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
                    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
                    unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: point.x, y: content.bounds.height - point.y))
                    guard let wheel = NSEvent(cgEvent: event) else { return }
                    NSApp.postEvent(wheel, atStart: false)
                }
            }
        }
    }

    /// One scroll of `dy` points over the column's rows, as a mouse's
    /// smooth wheel sends it, for the bench.
    static func wheelColumn(_ dy: Double) {
        Spin(kind: .column).post(Int32(dy), phase: -1)
    }

    private init(kind: Kind) { self.kind = kind }

    /// The run of tabs' scroll view: the one along the window's top.
    private lazy var scroll: NSScrollView? = {
        guard let content = Links.window?.contentView else { return nil }
        return Spin.row(in: content.superview ?? content, top: content.bounds.height - 60)
    }()

    private static func row(in view: NSView, top: CGFloat) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            let frame = scroll.convert(scroll.bounds, to: nil)
            if frame.maxY > top, frame.width > frame.height * 3 { return scroll }
        }
        for sub in view.subviews {
            if let found = row(in: sub, top: top) { return found }
        }
        return nil
    }

    private func note() {
        if kind == .column {
            offsets.append(Double(columnScroll?.contentView.bounds.origin.y ?? -1).rounded())
            return
        }
        offsets.append(Double(scroll?.contentView.bounds.origin.x ?? -1).rounded())
    }

    /// The column's rows' scroll view, whichever column draws them: the one
    /// the view under the column's middle stands in.
    private lazy var columnScroll: NSScrollView? = {
        guard let window = Links.window, let frame = window.contentView?.superview else { return nil }
        var view = frame.hitTest(frame.convert(Spin.overColumn(window), from: nil))
        while let each = view {
            if let scroll = each as? NSScrollView { return scroll }
            view = each.superview
        }
        return nil
    }()

    private func post(_ lines: Int32, phase: Int64 = -1, momentum: Int64 = 0, time: UInt64? = nil) {
        guard let window = Links.window, let content = window.contentView,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: kind == .wheel ? .line : .pixel, wheelCount: 2,
                                  wheel1: kind == .wheel ? lines : kind == .page ? lines * 40 : kind == .fingers || kind == .column ? lines : 0,
                                  wheel2: kind == .across ? lines * 40 : 0, wheel3: 0)
        else { return }
        event.flags = []
        if phase >= 0 {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        }
        if let time { event.timestamp = CGEventTimestamp(time) }
        let middle: NSPoint
        if kind == .page || kind == .fingers {
            middle = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        } else if kind == .column {
            middle = Spin.overColumn(window)
        } else if let scroll {
            middle = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        } else {
            return
        }
        let screen = window.convertPoint(toScreen: middle)
        // Quartz counts down from the top of the main screen.
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        // Which window it is for, and where in it, as the window server
        // stamps a real one: without them AppKit makes an event for no
        // window, which nothing takes. Both are private, and only a test
        // run gets here.
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
        unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: middle.x, y: content.bounds.height - middle.y))
        guard let wheel = NSEvent(cgEvent: event) else { return }
        NSApp.postEvent(wheel, atStart: false)
    }
}

/// Settings › Snippets' New Snippet… pressed by the bench, and how long its
/// editor took to be drawn.
extension Bench {
    @MainActor static var snippetAsked: Double?
    @MainActor static var snippetShown: Double?

    @MainActor static func snippetEditorShown() {
        guard let asked = snippetAsked, snippetShown == nil else { return }
        snippetShown = (CACurrentMediaTime() - asked) * 1000
    }
}

/// Notes when each frame arrives, for `pace`.
extension Bench {
    /// The main thread's own CPU time so far, in ms: the watchdog's gaps say
    /// when the thread was late, this says how much work it did.
    static func mainCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }

    /// CPU time of every thread of the process, in ms.
    static func processCPU() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1000 + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1000
    }

    /// Instructions the whole process has retired, in millions. Unlike CPU
    /// time, the same work counts the same on a fast core or a slow one, at
    /// any clock, and whatever else the Mac is doing, so two builds can be
    /// told apart on a busy Mac.
    static func instructions() -> Double {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Double(info.ri_instructions) / 1e6 : 0
    }

    /// The divider let go, after a `split-drag` held.
    @MainActor static var release: (() -> Void)?

    /// The main thread's time for one move of the deck, in the last
    /// `split-deck`.
    @MainActor static var deckMoves = 0.0
    /// The page's width from inside it through the last `split-deck`, and
    /// which web view it was.
    /// Where the last `split act=click` was posted, and what the window
    /// would hand it to there.
    @MainActor static var rowClick: [String: String] = [:]
    @MainActor static var deckWidths: [[Double]] = []
    @MainActor static var deckPage: ObjectIdentifier?
    /// How many times the room was asked for or given back in the last
    /// `split-deck`, the hand's trembling included.
    @MainActor static var roomMoves = 0
    /// The page's layer animations caught mid-flight by `pace reader`.
    @MainActor static var flying: [String] = []

    /// The divider between two halves pressed, dragged `by` points over
    /// `over` seconds a frame at a time, and let go, as posted mouse events
    /// the window hit-tests like the mouse's own. False with no divider.
    @MainActor
    static func dragDivider(_ browser: Browser, by: Double, over: Double, hold: Bool = false) -> Bool {
        guard browser.splitShown, let pair = browser.stagePair, let window = Links.window,
              let content = window.contentView, let left = browser.splitBook.frames[pair.first] else { return false }
        let height = content.bounds.height
        let x0 = left.maxX + Pair.gap / 2
        let y = left.midY
        func post(_ type: NSEvent.EventType, _ x: Double, clicks: Int = 1) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: height - y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
            ) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        post(.leftMouseDown, x0)
        let steps = max(1, Int(over * 60))
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) {
                post(.leftMouseDragged, x0 + by * Double(step) / Double(steps))
            }
        }
        guard !hold else {
            Bench.release = { post(.leftMouseUp, x0 + by) }
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 1) / 60) { post(.leftMouseUp, x0 + by) }
        return true
    }
}

extension Bench {
    /// The pull under the fingers after each move of the last swipe.
    @MainActor static var swipeLog: [Double] = []

    /// Where the column's row of spaces was drawn, [ms, points], and the
    /// fingers' slide of the strip's rows, sampled at 120 a second.
    @MainActor static var pagerTrack: [[Double]] = []

    @MainActor static func trackPager(for seconds: Double) {
        pagerTrack = []
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let at = CACurrentMediaTime() - start
                // [ms, row drawn at, strip slide, pager mode, space index].
                let browser = Links.browser
                let index = browser.flatMap { b in b.turnOrder.firstIndex { $0.id == b.spaceID } } ?? -1
                pagerTrack.append([(at * 10000).rounded() / 10, Double(SpacePager.shared.drawn), Double(SpacePull.shared.x),
                                   Double(SpacePager.shared.mode), Double(index)])
                if at >= seconds { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A trackpad's two-finger scroll over the space's capsule: began, a
    /// move a frame, ended, each stamped for the window as the window
    /// server stamps a real one (see Spin.post). `hold`: the fingers rest
    /// that long before they lift, so the swipe ends with no speed.
    /// `rows`: over the column's rows, a third of its width in, where a
    /// hand mostly is, not its foot. `pane`: over the page, or mail's pane,
    /// 200 points in from the window's right edge.
    @MainActor static func swipe(by distance: Double, over seconds: Double, hold: Double = 0, lift: Bool = true, rows: Bool = false,
                                 pane: Bool = false, at point: NSPoint? = nil, vertical: Bool = false) {
        guard let window = Links.window, let content = window.contentView else { return }
        let middle: NSPoint
        if let point {
            middle = point
        } else if pane {
            middle = content.convert(NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY), to: nil)
        } else if rows {
            middle = Spin.overColumn(window)
        } else {
            guard let dot = SpaceAnchors.dot else { return }
            middle = dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
        }
        let steps = max(2, Int(seconds * 60))
        let start = DispatchTime.now().uptimeNanoseconds
        func post(_ dx: Int32, phase: Int64, step: Int) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical ? dx : 0, wheel2: vertical ? 0 : dx, wheel3: 0) else { return }
            event.flags = []
            let screen = window.convertPoint(toScreen: middle)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            // Its own time, as a trackpad's move has, a sixtieth apart
            // however late the main thread posts it: the swipe reads its
            // speed from it (SpaceSwipe).
            event.timestamp = CGEventTimestamp(start + UInt64(step) * 1_000_000_000 / 60)
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: middle.x, y: content.bounds.height - middle.y))
            guard let wheel = NSEvent(cgEvent: event) else { return }
            NSApp.postEvent(wheel, atStart: false)
        }
        swipeLog = []
        post(0, phase: 1, step: 0)
        for step in 1...steps {
            // Whole points a move, the rounding carried over, so the moves
            // add up to the distance asked for.
            let each = Int32((distance * Double(step) / Double(steps)).rounded() - (distance * Double(step - 1) / Double(steps)).rounded())
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) {
                post(each, phase: 2, step: step)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                    swipeLog.append(SpacePager.shared.active ? Double(SpacePager.shared.drawn) : Double(SpacePull.shared.x))
                }
            }
        }
        guard lift else { return }
        let held = Int((hold * 60).rounded())
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 1 + held) / 60) { post(0, phase: 4, step: steps + 1 + held) }
    }

    /// One scroll event of a trackpad's: `phase` maybegin, began, ended or
    /// cancelled, over the column's foot or the page, stamped for the
    /// window or, `windowless`, for none of Yab's, as the end of a swipe
    /// that went to another desktop would come if it came at all.
    @MainActor static func touch(_ phase: String, page: Bool, windowless: Bool) {
        guard let window = Links.window, let content = window.contentView, let dot = SpaceAnchors.dot,
              let value = ["maybegin": Int64(128), "began": 1, "ended": 4, "cancelled": 8][phase],
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        event.flags = []
        let at = page ? NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY)
            : dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: at)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: value)
        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: windowless ? 0 : Int64(window.windowNumber))
        if !windowless {
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: at.x, y: content.bounds.height - at.y))
        }
        guard let wheel = NSEvent(cgEvent: event) else { return }
        NSApp.postEvent(wheel, atStart: false)
    }

    /// A click on the page, down and up, as a hand that left the trackpad
    /// and came back to the window would make.
    @MainActor static func click() {
        guard let window = Links.window, let content = window.contentView else { return }
        let at = NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}

extension Bench {
    /// A trackpad's two-finger scroll over a page: began, a move a frame,
    /// ended, stamped for the window as the window server stamps a real one.
    @MainActor static func pull(_ web: NSView, by distance: Double, over seconds: Double, begin: Bool, end: Bool, down: Double = 0) {
        guard let window = web.window, let content = window.contentView else { return }
        let middle = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        func post(_ dx: Int32, _ dy: Int32 = 0, phase: Int64) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            event.flags = []
            let screen = window.convertPoint(toScreen: middle)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
            typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
            unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: middle.x, y: content.bounds.height - middle.y))
            // When it happened, as a real one carries: how fast the fingers
            // went is read from these.
            event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9)
            guard let wheel = NSEvent(cgEvent: event) else { return }
            NSApp.postEvent(wheel, atStart: false)
        }
        if begin { post(0, phase: 1) }
        guard distance != 0 || down != 0 else {
            if end { post(0, phase: 4) }
            return
        }
        let steps = max(2, Int(seconds * 60))
        // Whole points a move, as a trackpad sends them, the rounding carried
        // over so that the moves add up to the distance asked for.
        var sent = 0.0, fell = 0.0
        for step in 1...steps {
            let due = (distance * Double(step) / Double(steps)).rounded()
            let move = Int32(due - sent)
            sent = due
            // "down" is how far the fingers go up or down, as wheel1 has it.
            let deep = (down * Double(step) / Double(steps)).rounded()
            let drop = Int32(deep - fell)
            fell = deep
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) { post(move, drop, phase: 2) }
        }
        if end { DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps + 1) / 60) { post(0, phase: 4) } }
    }
}

/// Each display frame of a smart zoom, for `smartzoom`: when it came
/// (CACurrentMediaTime), the page's magnification, the largest scale Core
/// Animation shows anywhere in the page's layers, and 1 if anything there
/// is animating.
final class ZoomWatch: NSObject {
    private weak var web: WKWebView?
    var rows: [[Double]] = []

    init(_ web: WKWebView) { self.web = web }

    @objc func tick(_ link: CADisplayLink) {
        guard let web else { return }
        var best = 1.0, moving = false, seen = 0
        func walk(_ layer: CALayer, _ depth: Int, _ product: Double) {
            seen += 1
            guard depth < 24, seen < 4000 else { return }
            if !(layer.animationKeys() ?? []).isEmpty { moving = true }
            let t = (layer.presentation() ?? layer).transform
            let scale = product * Double((t.m11 * t.m11 + t.m12 * t.m12).squareRoot())
            if abs(scale - 1) > abs(best - 1) { best = scale }
            for child in layer.sublayers ?? [] { walk(child, depth + 1, scale) }
        }
        if let layer = web.layer { walk(layer, 0, 1) }
        rows.append([CACurrentMediaTime(), Double(web.magnification), best, moving ? 1 : 0])
    }
}

extension Bench {
    /// A smart magnify gesture (two fingers tapped twice) as the trackpad
    /// hands it over: a gesture event whose HID type is the zoom toggle,
    /// stamped with the window and the point in it, as the window server
    /// stamps a real one. Private Quartz calls; only a test run gets here.
    static func smartMagnify(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        gesture(hidType: 22, at: point, in: window)
    }

    /// One event of a pinch as the trackpad hands it over: a gesture event
    /// whose HID type is zoom, with its phase and how far the fingers moved.
    static func magnify(_ amount: Double, phase: NSEvent.Phase, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        gesture(hidType: 8, at: point, in: window) { made in
            // IOHID's phase bits, which are not NSEvent.Phase's.
            made.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(ChromiumWheelPhase.gesture(phase)))
            made.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
        }
    }

    /// Discrete navigation swipe, as a mouse driver emits it. Use a real
    /// Quartz gesture so AppKit can enqueue it (an NSEvent subclass has no
    /// backing event). HID type/masks match WebKit's IOKit SPI and
    /// LinearMouse's GestureKit navigation swipe producer.
    /// https://github.com/linearmouse/linearmouse/blob/main/Modules/GestureKit/Sources/GestureKit/GestureEvent%2BNavigationSwipe.swift
    static func mouseSwipe(_ horizontal: Double, phase: NSEvent.Phase, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        // NSEvent deltaX is +1 for left, -1 for right (NSEvent.h).
        gesture(hidType: 16, at: point, in: window) { made in
            made.setIntegerValueField(CGEventField(rawValue: 115)!, value: horizontal > 0 ? 4 : horizontal < 0 ? 8 : 0)
            made.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(ChromiumWheelPhase.gesture(phase)))
        }
    }

    private static func gesture(hidType: Int64, at point: NSPoint, in window: NSWindow, fields: (CGEvent) -> Void = { _ in }) -> NSEvent? {
        guard let made = CGEvent(source: nil) else { return nil }
        made.flags = []
        typealias SetType = @convention(c) (CGEvent, UInt32) -> Void
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        guard let setType = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetType"),
              let place = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        // kCGSEventGesture, with kCGEventGestureHIDType what the fingers did.
        unsafeBitCast(setType, to: SetType.self)(made, 29)
        made.setIntegerValueField(CGEventField(rawValue: 110)!, value: hidType)
        fields(made)
        made.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        let screen = window.convertPoint(toScreen: point)
        made.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        made.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        let height = window.contentView?.bounds.height ?? 0
        unsafeBitCast(place, to: Place.self)(made, CGPoint(x: point.x, y: height - point.y))
        return NSEvent(cgEvent: made)
    }
}

/// The bench's last tab sent to a space, for its Undo.
@MainActor var lastMove: SpaceMove?

final class Pacer: NSObject {
    struct CallbackWindow {
        let duration: CFTimeInterval
        let leading: CFTimeInterval
        let trailing: CFTimeInterval
        let worst: CFTimeInterval
    }

    /// Include both boundaries: when main resumes after a long pause, the
    /// end timer may run before the next display callback. Adjacent callback
    /// gaps alone would report smooth frames while missing that entire pause.
    static func callbackWindow(start: CFTimeInterval, end: CFTimeInterval, delivered: [CFTimeInterval]) -> CallbackWindow {
        let end = max(start, end)
        let samples = delivered.filter { $0 >= start && $0 <= end }
        let leading = (samples.first ?? end) - start
        let trailing = end - (samples.last ?? start)
        let gaps = zip(samples.dropFirst(), samples).map { $0 - $1 }
        return CallbackWindow(duration: end - start, leading: leading, trailing: trailing,
                              worst: max(max(leading, trailing), gaps.max() ?? 0))
    }

    var ready: (() -> Void)?
    var times: [CFTimeInterval] = []
    var delivered: [CFTimeInterval] = []
    var frame: CFTimeInterval = 1.0 / 60

    @objc func tick(_ link: CADisplayLink) {
        if let ready {
            self.ready = nil
            ready()
            return
        }
        times.append(link.timestamp)
        delivered.append(CACurrentMediaTime())
        frame = link.targetTimestamp - link.timestamp
    }
}

/// One outstanding main-queue probe at a time. Unlike a run-loop pass,
/// this measures how long work actually waits while the UI is busy, even
/// when AppKit nests a run loop or delivers several frames in one pass.
private final class PaceLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CFTimeInterval?
    private var worst: CFTimeInterval = 0
    private var stopped = false
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "yab.pace-latency", qos: .userInteractive))

    deinit { timer.cancel() }

    func start() {
        ping()
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.resume()
    }

    private func ping() {
        lock.lock()
        guard !stopped, pending == nil else { lock.unlock(); return }
        let start = CACurrentMediaTime()
        pending = start
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.worst = max(self.worst, CACurrentMediaTime() - start)
            self.pending = nil
            self.lock.unlock()
        }
    }

    func stop() -> CFTimeInterval {
        timer.cancel()
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if let pending { worst = max(worst, CACurrentMediaTime() - pending) }
        return worst
    }
}

/// The mouse on a page, at points in the page's CSS pixels: `move`,
/// `drag` from one point to another, `menu` right-clicks and keeps the
/// rows the menu opened with and those it had a moment later (WebKit adds
/// some once it has looked at a picture), then shuts it; `rows` gives them;
/// `copy` is ⌘C, answering with what went on the pasteboard.
@MainActor enum BenchPointer {
    private static var rows: [String: Any] = [:]

    /// A click on a Chromium page at `at` in its points from the top left,
    /// its middle without: down and up sent to its window.
    static func click(_ page: ChromiumPage, at: [Double]?) -> [String: Any] {
        guard let window = page.window else { return ["error": "the page has no window"] }
        let x = at?.first ?? page.bounds.width / 2, y = at.flatMap { $0.count == 2 ? $0[1] : nil } ?? page.bounds.height / 2
        let local = CGPoint(x: x, y: page.isFlipped ? y : page.bounds.height - y)
        let point = page.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return ["error": "no event"] }
        let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
        window.sendEvent(down)
        window.sendEvent(up)
        return ["clicked": true, "hitPage": hit === page || hit?.isDescendant(of: page) == true, "window": window.windowNumber]
    }

    static func run(_ request: [String: Any], on web: PageView) -> [String: Any] {
        let point = { (key: String) -> CGPoint? in
            guard let at = request[key] as? [Double], at.count == 2 else { return nil }
            let zoom = web.pageZoom * web.magnification
            let local = CGPoint(x: at[0] * zoom, y: web.isFlipped ? at[1] * zoom : web.bounds.height - at[1] * zoom)
            return web.convert(local, to: nil)
        }
        // "flags": keys held with it, "cmd" for a ⌘-click (evals/link-routes-pages).
        let held = Bench.flags(request["flags"])
        let event = { (type: NSEvent.EventType, at: CGPoint) in
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: web.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .mouseMoved ? 0 : 1)
        }
        switch request["op"] as? String {
        case "move":
            guard let at = point("at"), let moved = event(.mouseMoved, at) else { return ["error": "move needs at"] }
            // WebKit follows the pointer only in the window in front.
            NSApp.activate()
            web.window?.makeKeyAndOrderFront(nil)
            web.window?.acceptsMouseMovedEvents = true
            // Handed to the page, not through the app's queue: the link
            // pill's rule is told of it here (LinkStatus.Rule).
            LinkStatus.shared.pointerMoved()
            web.mouseMoved(with: moved)
            return ["moved": true]
        case "click":
            guard let at = point("at"), let window = web.window,
                  let down = event(.leftMouseDown, at), let up = event(.leftMouseUp, at)
            else { return ["error": "click needs a page window and at"] }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.sendEvent(down)
            // Where typing goes after it: a page's document.hasFocus() is
            // its window key and the page the first responder.
            let first = (window.firstResponder as? NSView)?.isDescendant(of: web) == true
            let said: [String: Any] = ["clicked": true, "key": window.isKeyWindow, "first": first, "active": NSApp.isActive]
            // "hold": seconds between the press and the release, as a hand
            // leaves them; "between": a script run in the page meanwhile,
            // with a gesture, as WebKit runs an extension's, or "after"
            // seconds past the release (evals/clipboard/sitecopy.py).
            // Answered at once; the release comes after.
            if let after = request["after"] as? Double, let script = request["between"] as? String {
                window.sendEvent(up)
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { MainActor.assumeIsolated { web.evaluateJavaScript(script) { _, _ in } } }
                return said
            }
            guard let hold = request["hold"] as? Double, hold > 0 else { window.sendEvent(up); return said }
            if let script = request["between"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + hold / 3) { MainActor.assumeIsolated { web.evaluateJavaScript(script) { _, _ in } } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                MainActor.assumeIsolated { if let up = event(.leftMouseUp, at) { window.sendEvent(up) } }
            }
            return said
        case "drag":
            guard let from = point("from"), let to = point("to"), let down = event(.leftMouseDown, from) else { return ["error": "drag needs from and to"] }
            // Through the window, as the Mac hands a press to the view under it.
            NSApp.activate()
            web.window?.makeKeyAndOrderFront(nil)
            let send = { (e: NSEvent) in if let window = web.window { window.sendEvent(e) } else { web.mouseDown(with: e) } }
            send(down)
            let steps = 12
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                if let dragged = event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) {
                    send(dragged)
                }
            }
            if let up = event(.leftMouseUp, to) { send(up) }
            return ["dragged": true]
        case "menu":
            guard let at = point("at"), let down = event(.rightMouseDown, at) else { return ["error": "menu needs at"] }
            rows = [:]
            let wait = request["wait"] as? Double ?? 1.5
            let pick = request["pick"] as? String
            PageView.menuWatch = { menu in
                PageView.menuWatch = nil
                rows["open"] = describe(menu)
                let timer = Timer(timeInterval: wait, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        rows["later"] = describe(menu)
                        // A row picked by its id, as a click on it would,
                        // and what it put on the pasteboard, if anything.
                        let picked = pick.flatMap { id in menu.items.first { $0.identifier?.rawValue == id } }
                        menu.cancelTracking()
                        if let pick {
                            guard let picked, let action = picked.action else { rows["picked"] = "no row \(pick)"; return }
                            let before = NSPasteboard.general.changeCount
                            NSApp.sendAction(action, to: picked.target, from: picked)
                            rows["picked"] = NSPasteboard.general.changeCount != before ? NSPasteboard.general.string(forType: .string) ?? "" : "nothing copied"
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
            web.rightMouseDown(with: down)
            return ["sent": true]
        case "rows":
            return rows
        case "analyze":
            return ["started": web.lookAtPictures()]
        case "pictures":
            return PictureReader.shared.counts.merging(["linkTold": LinkStatus.shared.told, "linkChanged": LinkStatus.shared.changed,
                                                         "linkShown": LinkStatus.shared.pointed?.url.absoluteString ?? ""]) { a, _ in a }
        case "copy":
            // What this copy put there, never what the Mac had before.
            let before = NSPasteboard.general.changeCount
            web.window?.makeFirstResponder(web)
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            let changed = NSPasteboard.general.changeCount != before
            return ["changed": changed, "text": changed ? NSPasteboard.general.string(forType: .string) ?? "" : ""]
        default:
            return ["error": "pointer op: move, drag, menu, rows, copy"]
        }
    }

    private static func describe(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.map { item in
            item.isSeparatorItem ? ["separator": true]
                : ["id": item.identifier?.rawValue ?? "", "title": item.title, "enabled": item.isEnabled, "image": item.image != nil]
        }
    }
}

/// Inspect Element as WebKit puts it in a page's right-click menu, fired
/// the way a pick of it would be: "webkit" when the original action ran,
/// "yab" if it was not forwarded.
@MainActor final class BenchInspect: NSObject {
    private var fired = false
    @objc private func webkit(_ item: NSMenuItem) { fired = true }

    static func fire(_ web: PageView, at point: CGPoint) -> String {
        let zoom = web.pageZoom * web.magnification
        let local = CGPoint(x: point.x * zoom, y: web.isFlipped ? point.y * zoom : web.bounds.height - point.y * zoom)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: web.convert(local, to: nil), modifierFlags: [],
                                             timestamp: 0, windowNumber: web.window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return "" }
        let hand = BenchInspect()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Inspect Element", action: #selector(webkit(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierInspectElement")
        item.target = hand
        menu.addItem(item)
        web.inspectHere(menu, event)
        menu.performActionForItem(at: 0)
        return hand.fired ? "webkit" : "yab"
    }
}

extension View {
    /// Where this control is in the window, kept by name for the bench to
    /// press it as the mouse would (`{"do":"spots"}`); nothing outside a
    /// test run.
    @ViewBuilder func benchSpot(_ name: String) -> some View {
        if Bench.spotting { modifier(BenchSpot(name: name)) } else { self }
    }
}

/// Gone, a control takes its spot with it, unless one come in its place
/// has already put its own there.
private struct BenchSpot: ViewModifier {
    let name: String
    @State private var mine: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                mine = $0
                Bench.spots[name] = $0
            }
            .onDisappear { if Bench.spots[name] == mine { Bench.spots[name] = nil } }
    }
}

/// What of the pointer reaches a window, for the bench's "window" verb on a
/// --test run: the moves, the comings into and goings out of tracking areas
/// with the class of whoever owns each, and what the green button's cell
/// is told of the pointer resting on it.
@MainActor
enum WindowHeard {
    private(set) static var log: [String] = []
    private static var watching: Any?
    private static var spied = false

    static func note(_ line: String) {
        log.append(String(format: "%.2f ", CACurrentMediaTime()) + line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    static func start(_ window: NSWindow) {
        guard Store.testing else { return }
        log = []
        if watching == nil {
            let kinds: NSEvent.EventTypeMask = [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp]
            watching = NSEvent.addLocalMonitorForEvents(matching: kinds) { event in
                MainActor.assumeIsolated {
                    let at = event.locationInWindow
                    var said = ""
                    switch event.type {
                    case .mouseEntered, .mouseExited:
                        said = event.trackingArea.map { " \(type(of: $0.owner as AnyObject))" } ?? ""
                    case .leftMouseDown:
                        let hit = event.window?.contentView?.superview?.hitTest(at)
                        said = " on " + (hit.map { "\(type(of: $0))" } ?? "nil")
                    default: break
                    }
                    let whose = event.window.map { "\(type(of: $0))" } ?? "nil"
                    note("\(event.type.rawValue) \(whose) \(Int(at.x)),\(Int(at.y))\(said)")
                }
                return event
            }
        }
        guard !spied, let cell = NSClassFromString("_NSThemeZoomWidgetCell") else { return }
        spied = true
        for name in ["mouseEntered:", "startTrackingHover", "_hoverTriggeredShowMenuForView:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cell, selector) else { note("no \(name)"); continue }
            let old = method_getImplementation(method)
            if name.hasSuffix(":") {
                typealias Pass = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                let pass = unsafeBitCast(old, to: Pass.self)
                let heard: @convention(block) (AnyObject, AnyObject?) -> Void = { cell, value in
                    MainActor.assumeIsolated { note("cell \(name)") }
                    pass(cell, selector, value)
                }
                method_setImplementation(method, imp_implementationWithBlock(heard))
            } else {
                typealias Pass = @convention(c) (AnyObject, Selector) -> Void
                let pass = unsafeBitCast(old, to: Pass.self)
                let heard: @convention(block) (AnyObject) -> Void = { cell in
                    MainActor.assumeIsolated { note("cell \(name)") }
                    pass(cell, selector)
                }
                method_setImplementation(method, imp_implementationWithBlock(heard))
            }
        }
    }
}

/// Every change of a window's size, for the bench's "window" verb with
/// `moves` on a --test run: when, the frame, the least and most sizes
/// AppKit holds it to, and who called (#390: a window kept at two thirds of
/// its screen grew to fill it with nobody touching it). The sizes are also
/// looked at every second, so a least size that grew shows before the
/// window does.
@MainActor
enum WindowMoves {
    private(set) static var log: [[String: Any]] = []
    private static var watching: [NSObjectProtocol] = []
    private static var timer: Timer?
    private static var last = ""

    private static func sizes(_ window: NSWindow) -> [String: Any] {
        func r(_ s: NSSize) -> [Int] { [Int(min(s.width, 1e6)), Int(min(s.height, 1e6))] }
        let f = window.frame
        return ["frame": [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)],
                "min": r(window.minSize), "contentMin": r(window.contentMinSize),
                "max": r(window.maxSize),
                "zoomed": window.isZoomed]
    }

    private static func note(_ window: NSWindow, _ why: String, stack: Bool) {
        var row = sizes(window)
        let key = "\(row["frame"] ?? "") \(row["min"] ?? "") \(row["contentMin"] ?? "") \(row["max"] ?? "")"
        guard why != "poll" || key != last else { return }
        last = key
        row["at"] = Date().timeIntervalSince1970
        row["why"] = why
        if stack { row["stack"] = Array(Thread.callStackSymbols.dropFirst(2).prefix(40)) }
        log.append(row)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    static func start(_ window: NSWindow) {
        guard Store.testing else { return }
        log = []
        last = ""
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    note(window, name == NSWindow.didResizeNotification ? "resize" : "live end", stack: true)
                }
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                note(window, "poll", stack: false)
            }
        }
        note(window, "start", stack: false)
    }
}

/// Counts of views told `needsLayout = true` or `needsUpdateConstraints =
/// true`, by class and their superview's class, while on (bench
/// layout-census). NSView's setters are swapped for counting ones the first
/// time it is turned on, in a test run only.
@MainActor
enum LayoutCensus {
    private static var layout: [String: Int] = [:]
    private static var constraints: [String: Int] = [:]
    private static var on = false
    private static var installed = false
    private static var stacks: [String] = []
    private static var asked: Set<String> = []

    private static var quiet: [Int] = []
    private static var quietNow: [Int] {
        [ColumnQuiet.movesKept, ColumnQuiet.movesTold, ColumnQuiet.asksKept, ColumnQuiet.asksAnswered]
    }

    static func start() {
        layout = [:]
        constraints = [:]
        stacks = []
        asked = []
        quiet = quietNow
        on = true
        guard !installed else { return }
        installed = true
        count(#selector(setter: NSView.needsLayout)) { layout[$0, default: 0] += 1 }
        count(#selector(setter: NSView.needsUpdateConstraints)) { constraints[$0, default: 0] += 1 }
    }

    static func stop() -> [String: Any] {
        on = false
        func top(_ counts: [String: Int]) -> [String] {
            counts.sorted { $0.value > $1.value }.prefix(30).map { "\($0.value) \($0.key)" }
        }
        // How many views the window holds, and how many of them hidden or
        // in a hidden branch: what AppKit's layout pass may walk.
        var views = 0, hidden = 0
        func walk(_ view: NSView, _ under: Bool) {
            views += 1
            let gone = under || view.isHidden
            if gone { hidden += 1 }
            view.subviews.forEach { walk($0, gone) }
        }
        if let frame = Links.window?.contentView?.superview { walk(frame, false) }
        let q = zip(quietNow, quiet).map { $0 - $1 }
        return ["layout": top(layout), "constraints": top(constraints), "stacks": stacks, "views": views, "hidden_views": hidden,
                "moves_kept": q[0], "moves_told": q[1], "asks_kept": q[2], "asks_answered": q[3]]
    }

    private static func count(_ selector: Selector, _ note: @escaping @MainActor (String) -> Void) {
        guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
        typealias Setter = @convention(c) (NSView, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: @convention(block) (NSView, Bool) -> Void = { view, flag in
            if flag, Thread.isMainThread {
                MainActor.assumeIsolated {
                    if on {
                        var name = "\(type(of: view)) in \(view.superview.map { "\(type(of: $0))" } ?? "-")"
                        if let cell = view as? ColumnCell { name += " \(cell.kind) \(cell.itemID?.prefix(12) ?? "-")" }
                        note(name)
                        // Who asked: the first stack for each kind of view
                        // asking, past this, up to 40 kinds.
                        if !asked.contains(name), stacks.count < 40 {
                            asked.insert(name)
                            // A cell's own ask is short; a host's, told by
                            // something under it, is followed far down.
                            let depth = view is ColumnCell ? 16 : 48
                            stacks.append(name + " <- " + Thread.callStackSymbols.dropFirst(2).prefix(depth).map { line in
                                String(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ").prefix(140))
                            }.joined(separator: " | "))
                        }
                    }
                }
            }
            original(view, selector, flag)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// The main thread's stacks while it works, from a thread of its own
/// (bench mainsample).
nonisolated final class MainSampler: @unchecked Sendable {
    static let shared = MainSampler()
    private let lock = NSLock()
    private var on = false
    private var samples = 0, busy = 0
    private var inclusive: [String: Int] = [:], leaf: [String: Int] = [:]

    func start() {
        lock.lock()
        let was = on
        on = true
        samples = 0; busy = 0; inclusive = [:]; leaf = [:]
        lock.unlock()
        guard !was else { return }
        let port: thread_act_t = Thread.isMainThread ? pthread_mach_thread_np(pthread_self())
            : DispatchQueue.main.sync { pthread_mach_thread_np(pthread_self()) }
        Thread.detachNewThread { [self] in
            Thread.current.name = "Yab main sampler"
            while true {
                lock.lock(); let going = on; lock.unlock()
                guard going else { return }
                var info = thread_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let read = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
                }
                var names: [String] = []
                if read == KERN_SUCCESS, info.run_state == TH_STATE_RUNNING {
                    names = Watchdog.captureMainStack(port: port).split(separator: "\n").map { line in
                        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3).map(String.init)
                        // "  n image +0xoffset name": the name, or the image and offset.
                        return parts.count == 4 ? parts[1] + " " + parts[3] : parts.dropFirst().joined(separator: " ")
                    }
                }
                lock.lock()
                samples += 1
                if !names.isEmpty {
                    busy += 1
                    leaf[names[0], default: 0] += 1
                    for name in Set(names) { inclusive[name, default: 0] += 1 }
                }
                lock.unlock()
                usleep(2000)
            }
        }
    }

    func stop() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        on = false
        let top = { (counts: [String: Int], n: Int) in counts.sorted { $0.value > $1.value }.prefix(n).map { [$0.key, $0.value] as [Any] } }
        return ["samples": samples, "busy": busy, "inclusive": top(inclusive, 80), "leaf": top(leaf, 40)]
    }
}

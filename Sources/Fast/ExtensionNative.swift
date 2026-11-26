import Foundation
import Darwin
import WebKit

// Chrome's native messaging, for the extensions that talk to an app on this
// Mac, a password manager unlocking with its desktop app, a clipper handing
// a page to a notes app.
//
// Those apps register with Chrome by leaving a small JSON file in Chrome's
// NativeMessagingHosts folder: a name, the program to run, and which
// extensions may run it. yab reads the same files, runs the same program
// with the same argument, and speaks the same protocol, each message a
// four-byte length and a line of JSON, over the program's stdin and stdout.
// A host that lists the extension's id among its allowed origins is run;
// any other is not. Some hosts also check which browser is calling and may
// refuse one they don't know; that is theirs to decide. macOS may decide
// first: Apple's iCloud Passwords helper carries a parent launch constraint
// (only a browser with Apple's web browser entitlement, or one on Apple's
// list of signatures, may start it), and the kernel kills it as it starts
// from any other (docs/evidence/icloud-passwords-2026-10-08.md). A host
// killed like that isn't started again until Yab is: each try was one more
// crash report, and the answer can't change while Yab runs.

@available(macOS 15.4, *)
enum ExtensionNative {
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac.
    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            // Where an app that knows only another Chromium leaves its file:
            // 1Password writes Chrome's channels, Edge's and Vivaldi's.
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts"),
            support.appendingPathComponent("Google/Chrome Beta/NativeMessagingHosts"),
            support.appendingPathComponent("Google/Chrome Dev/NativeMessagingHosts"),
            support.appendingPathComponent("Google/Chrome Canary/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge Beta/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge Dev/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge Canary/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser-Beta/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/System/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
        ]
    }

    static let onePasswordHost = "com.1password.1password"
    static let onePasswordExtensions: Set<String> = ["aeblfdkhhhdcdjpifhhbdiojplfjncoa", "khgocmkkpikpnmmkgmdnfckapcdkgfaf"]
    static let onePasswordHelper = URL(fileURLWithPath: "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport")

    /// The program for `name`, if one is registered and lets this extension in.
    /// Every folder is looked in: another browser's file may name other
    /// extensions, or a program since removed, where a later one is right.
    static func host(_ name: String, for extensionID: String, in folders: [URL] = folders,
                     helper: URL = onePasswordHelper) throws -> URL {
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw Refused(why: "Invalid native messaging host name")
        }
        // What the extension heard the first time, without the second try.
        guard !stoppedByMacOS(name) else { throw Refused(why: "Native host has exited.") }
        let origin = "chrome-extension://\(extensionID)/"
        var forbidden = false
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String
            else { continue }
            let allowed = manifest["allowed_origins"] as? [String] ?? []
            guard allowed.contains(origin) else { forbidden = true; continue }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else { continue }
            return program
        }
        // 1Password's app is there but left no file Yab reads (no other
        // Chromium on this Mac): its helper, which lets in its own
        // extensions, is where every copy of the app keeps it. Never in
        // place of a file that refused this extension.
        if !forbidden, name == onePasswordHost, onePasswordExtensions.contains(extensionID),
           FileManager.default.isExecutableFile(atPath: helper.path) {
            return helper
        }
        throw Refused(why: forbidden ? "Access to the specified native messaging host is forbidden."
                                     : "Specified native messaging host not found.")
    }

    /// Hosts macOS killed as they started, by name, for as long as Yab runs.
    private static let barredLock = NSLock()
    nonisolated(unsafe) private static var barred: Set<String> = []

    /// macOS killed `name` as Yab started it (HostPipe.killedAtLaunch).
    static func stoppedByMacOS(_ name: String) -> Bool {
        barredLock.withLock { barred.contains(name) }
    }

    static func bar(_ name: String) {
        _ = barredLock.withLock { barred.insert(name) }
    }

    /// For tests: as Yab starts.
    static func unbarAll() {
        barredLock.withLock { barred.removeAll() }
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    /// `killed` hears that macOS killed the host as it started.
    @MainActor
    static func send(_ message: Any, to name: String, from extensionID: String,
                     owner: WKWebExtensionContext? = nil,
                     killed: (@Sendable () -> Void)? = nil) async throws -> Any? {
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/", buffersReplies: true)
        pipe.killedAtLaunch = { bar(name); killed?() }
        return try await send(message, using: pipe, owner: owner.map(ObjectIdentifier.init))
    }

    /// A one-shot call owns its host until reply, context unload, cancellation,
    /// or its 30-second response budget. This is not an idle port timeout:
    /// connectNative sessions can remain open for user authentication.
    @MainActor
    static func send(_ message: Any, using pipe: HostPipe, owner: ObjectIdentifier? = nil,
                     timeout: Duration = .seconds(30)) async throws -> Any? {
        try pipe.start()
        let id = ObjectIdentifier(pipe)
        Live.requests[id] = (pipe, owner)
        defer { Live.requests[id] = nil; pipe.stop(); Live.unwatchIfEmpty() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try pipe.write(message)
            return try await pipe.readOne(until: .now.advanced(by: timeout),
                                          otherwise: Refused(why: "Native host has exited."))
        } onCancel: { pipe.stop() }
    }

    @MainActor
    static func stop(owner: WKWebExtensionContext) {
        stop(owner: ObjectIdentifier(owner))
    }

    @MainActor
    static func stop(owner: ObjectIdentifier) {
        for entry in Array(Live.requests.values) where entry.owner == owner { entry.pipe.stop() }
        for entry in Array(Live.pipes.values) where entry.owner == owner { entry.pipe.stop() }
        Live.unwatchIfEmpty()
    }

    /// What a host said last before it stopped.
    private final class Heard: @unchecked Sendable {
        var last: Any?
        /// The host said it won't talk to this browser: what it says after
        /// that goes nowhere (`connect`).
        var refused = false
    }

    /// How a host's run ended: what it said last, after how long, and
    /// whether it stopped by itself or was stopped, the extension having let
    /// go of it (as 1Password's does once its host says it won't talk to
    /// this browser) or Yab putting away an orphan.
    struct Ending {
        let last: Any?
        let after: TimeInterval
        let byItself: Bool
    }

    /// Lets go of an app's port with Chrome's words for why, which the
    /// worker's shim hands the extension's onDisconnect as the port's error.
    /// WebKit carries no reason across a port's disconnect, so it goes just
    /// before, as a message the shim keeps from the extension's listeners.
    @MainActor
    static func end(_ port: WKWebExtension.MessagePort, saying why: String) {
        port.sendMessage(["__yabNative": "gone", "why": why], completionHandler: nil)
        port.disconnect()
    }

    /// `runtime.connectNative`: run, and keep the two talking until either
    /// end lets go. `heard` hears each thing the host says, `ended` how it
    /// ended, `killed` that macOS killed it as it started.
    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String,
                        owner: WKWebExtensionContext? = nil,
                        heard said: ((Any) -> Void)? = nil, killed: (@Sendable () -> Void)? = nil,
                        ended: ((Ending) -> Void)? = nil) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No host named") }
        let program = try host(name, for: extensionID)
        // A new port is often a worker starting over; the one before may
        // have left its host behind.
        stopOrphans()
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        pipe.killedAtLaunch = { bar(name); killed?() }
        try pipe.start()
        let started = Date(), heard = Heard()
        // Nothing goes on a port its extension has let go of, and after a
        // host's refusal nothing more at all: the extension has its answer
        // and is closing the port (1Password's host answers again for every
        // request). On macOS 26.4.1 and 26.5 WebKit's web process is fragile
        // around a port going while a message is on its way to it
        // (WebExtensionContextProxy::dispatchPortMessageEvent, SIGSEGV at
        // 0x18): its own case, a port let go of inside onMessage, is mended
        // in the shim; this keeps Yab from sending into the gap.
        pipe.onMessage = { message in
            DispatchQueue.main.async {
                heard.last = message
                said?(message)
                guard !heard.refused, !port.isDisconnected else { return }
                port.sendMessage(message, completionHandler: nil)
                if Extensions.refusal(message) { heard.refused = true }
            }
        }
        var beating: Timer?
        // Held until it has ended (onExit is let go of then).
        pipe.onExit = {
            DispatchQueue.main.async {
                beating?.invalidate()
                beating = nil
                port.messageHandler = nil
                port.disconnectHandler = nil
                if !port.isDisconnected { port.disconnect() }
            }
            // How the process ended, read once it surely has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ended?(Ending(last: heard.last, after: Date().timeIntervalSince(started), byItself: pipe.exitedByItself))
            }
        }
        var lastHeard = SuspendingClock.now
        port.messageHandler = { message, _ in
            guard let message else { return }
            lastHeard = SuspendingClock.now
            // A worker's shim asking whether the port has arrived (see the
            // shim, after its WebSocket): answered here, never passed on.
            if let asked = message as? [String: Any], let word = asked["__yabNative"] {
                // The shim's answer to "alive" (below) is only the worker
                // keeping itself: nothing to say back.
                guard (word as? String) == "here?", !port.isDisconnected else { return }
                port.sendMessage(["__yabNative": "here"], completionHandler: nil)
                // Asked, it is a worker's port, and WebKit unloads a worker
                // that hasn't posted on a port for two minutes: iCloud
                // Passwords then forgets it was paired and asks for a code
                // again. Chrome keeps a worker with a port to an app alive;
                // here a word on the port now and then, heard only by the
                // shim, has the worker answer on it, which is what WebKit
                // counts.
                if beating == nil {
                    beating = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak pipe] timer in
                        // A port gone without a word: its host, and the
                        // host's pipes, go with it now, not at the next
                        // connectNative.
                        guard !port.isDisconnected else { timer.invalidate(); pipe?.stop(); return }
                        // A worker WebKit unloaded or started over leaves
                        // its port reading as connected for good, and no
                        // later connectNative finds it gone (stopOrphans):
                        // iCloud Passwords left 29 helpers running in one
                        // afternoon. A live worker's shim answers each
                        // "alive" with "beat"; three missed, it has gone.
                        guard nativeHostAlive(since: lastHeard) else {
                            timer.invalidate()
                            pipe?.stop()
                            port.disconnect()
                            return
                        }
                        port.sendMessage(["__yabNative": "alive"], completionHandler: nil)
                    }
                }
                return
            }
            try? pipe.write(message)
        }
        port.disconnectHandler = { _ in beating?.invalidate(); pipe.stop() }
        Live.keep(pipe, for: port, owner: owner.map(ObjectIdentifier.init))
    }

    /// Sleeping does not count as a worker missing its heartbeat.
    static func nativeHostAlive(since lastHeard: SuspendingClock.Instant,
                                now: SuspendingClock.Instant = .now) -> Bool {
        lastHeard.duration(to: now) < .seconds(80)
    }

    /// WebKit doesn't always say when a port goes: an extension unloaded,
    /// taken up afresh, turned off or removed, leaves its worker's ports
    /// disconnected without calling their disconnect handlers. Each host
    /// would run on, with any code prompt it had open, until the browser
    /// quit: iCloud Passwords left a helper behind at every restart. So the
    /// hosts of ports that have gone are stopped here; a port still
    /// connected keeps its own.
    @MainActor
    static func stopOrphans() {
        for entry in Array(Live.pipes.values) where entry.port.isDisconnected { entry.pipe.stop() }
        Live.unwatchIfEmpty()
    }

    /// Hosts that are connected, held until they end.
    @MainActor private enum Live {
        static var pipes: [ObjectIdentifier: (pipe: HostPipe, port: WKWebExtension.MessagePort, owner: ObjectIdentifier?)] = [:]
        static var requests: [ObjectIdentifier: (pipe: HostPipe, owner: ObjectIdentifier?)] = [:]
        static var watcher: Timer?
        static func watch() {
            guard watcher == nil else { return }
            // WebKit sometimes updates isDisconnected without delivering
            // disconnectHandler. Observe that state even if no new host opens.
            watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in stopOrphans() }
            }
        }
        static func unwatchIfEmpty() {
            if pipes.isEmpty && requests.isEmpty {
                watcher?.invalidate(); watcher = nil
            }
        }
        static func keep(_ pipe: HostPipe, for port: WKWebExtension.MessagePort, owner: ObjectIdentifier?) {
            pipes[ObjectIdentifier(pipe)] = (pipe, port, owner)
            watch()
            let previous = pipe.onExit
            pipe.onExit = {
                previous?()
                DispatchQueue.main.async { pipes[ObjectIdentifier(pipe)] = nil; unwatchIfEmpty() }
            }
        }
    }
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    private let process = Process()
    /// Identifies this helper's windows without their titles or contents.
    var processIdentifier: Int32 { process.processIdentifier }
    /// The host's stdin and stdout. nil when pipe(2) failed: a process
    /// out of descriptors (crashes #853, #1501). Foundation's Pipe() then
    /// hands back nil although Swift sees it as non-optional, and the first
    /// write went to a nil handle: _NSFileHandleIsClosed read 0x64.
    private let input: HostChannel?
    private let output: HostChannel?
    /// Why the pipes couldn't be made, said by start.
    private let openFailure: String?
    private var buffer = Data()
    private let lock = NSLock()
    /// Serialize reading with closing. Neither callback waits on the host:
    /// the read descriptor is nonblocking.
    private let outputLock = NSLock()
    private var waiters: [(id: UUID, reader: CheckedContinuation<Any?, Error>)] = []
    private var replies: [Any] = []
    private let buffersReplies: Bool
    private var heard: ((Any) -> Void)?
    private var exited: (() -> Void)?
    private var finished = false
    private var stoppedByYab = false
    private var started = Date()

    /// Called, set before start, when macOS kills the host as it starts:
    /// a launch constraint it doesn't meet (iCloud Passwords' helper,
    /// started by a browser Apple hasn't approved).
    var killedAtLaunch: (@Sendable () -> Void)?

    /// Set on the main thread, called on the pipe's: under the lock, as
    /// both ends of the host's end (its output closing and the process
    /// exiting) come on threads of their own at once. Without it the two
    /// let go of the same onExit together, and the browser crashed there.
    var onMessage: ((Any) -> Void)? {
        get { lock.withLock { heard } }
        set { lock.withLock { heard = newValue } }
    }

    /// Called once, when the host has ended. Given after that (a host that
    /// ended as it started, before connect set it), it is called at once.
    var onExit: (() -> Void)? {
        get { lock.withLock { exited } }
        set {
            let now: (() -> Void)? = lock.withLock {
                guard !finished else { return newValue }
                exited = newValue
                return nil
            }
            now?()
        }
    }

    /// `open` makes each pipe; tests hand in one that fails.
    init(program: URL, origin: String, buffersReplies: Bool = false, input: Pipe? = nil, output: Pipe? = nil,
         open: () throws -> HostChannel = HostChannel.open) {
        self.buffersReplies = buffersReplies
        var failure: String?
        func channel(_ given: Pipe?) -> HostChannel? {
            if let given { return HostChannel(given) }
            do { return try open() } catch { failure = failure ?? error.localizedDescription; return nil }
        }
        let input = channel(input), output = channel(output)
        self.input = input
        self.output = output
        openFailure = failure
        process.executableURL = program
        process.arguments = [origin]
        process.standardError = FileHandle.nullDevice
        guard let input, let output else { return }
        process.standardInput = input.forReading
        process.standardOutput = output.forWriting
        // A host that is already gone, refused to run or killed as it
        // started, would take the browser with it: writing to its closed
        // pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(input.forWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        guard let input, let output else {
            finish()
            throw ExtensionNative.Refused(why: "Couldn't open a pipe to the native host: \(openFailure ?? "no descriptors left").")
        }
        let fd = output.forReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        output.forReading.readabilityHandler = { [weak self] _ in self?.drain() }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let (stopped, began) = self.lock.withLock { (self.stoppedByYab, self.started) }
            if Self.killedByMacOS(reason: process.terminationReason, status: process.terminationStatus,
                                  after: Date().timeIntervalSince(began), stoppedByYab: stopped) {
                self.killedAtLaunch?()
            }
            // A final reply can be waiting on stdout when termination is
            // delivered before the readability callback. Drain it first.
            self.drain()
            self.finish()
        }
        lock.withLock { started = Date() }
        do {
            try process.runValidated()
            // Only the child reads stdin and writes stdout. Keeping copies
            // here prevents EOF when either side of the connection goes.
            try? input.forReading.close()
            try? output.forWriting.close()
        } catch {
            finish()
            throw error
        }
    }

    /// It ended by itself, rather than by Yab's terminate: its exit, not a
    /// signal. Still running, it hasn't.
    var exitedByItself: Bool {
        !lock.withLock({ stoppedByYab }) && !process.isRunning && process.terminationReason == .exit
    }

    /// How a host macOS wouldn't let run ends: SIGKILL, before it has done
    /// anything (a launch constraint violation, "Code Signature Invalid" in
    /// its crash report), and not from Yab, whose stop is SIGTERM anyway.
    static func killedByMacOS(reason: Process.TerminationReason, status: Int32,
                              after: TimeInterval, stoppedByYab: Bool) -> Bool {
        reason == .uncaughtSignal && status == SIGKILL && after < 2 && !stoppedByYab
    }

    /// Yab asked it to stop, rather than it ending on its own.
    var stoppedByUs: Bool { lock.withLock { stoppedByYab } }

    func stop() {
        lock.withLock { stoppedByYab = true }
        finish()
        // EOF is the native messaging host's normal way out. Foundation
        // reaps the child; a host that ignores EOF gets a bounded grace.
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { process.terminate() }
        }
        // A native host can ignore EOF and SIGTERM. Chromium bounds its
        // process shutdown with SIGKILL too; a closed connection must not
        // leave an unowned child behind.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= 1 << 20 else { throw ExtensionNative.Refused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        guard let input, !lock.withLock({ finished }) else { throw ExtensionNative.Refused(why: "Native host has exited.") }
        try input.forWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await read(until: nil, otherwise: nil)
    }

    /// One message, or `late` at `deadline` with the host left running: what
    /// it says afterwards waits for the next read. Sleep doesn't count.
    func readOne(until deadline: SuspendingClock.Instant, otherwise late: Error) async throws -> Any? {
        try await read(until: deadline, otherwise: late)
    }

    private func read(until deadline: SuspendingClock.Instant?, otherwise late: Error?) async throws -> Any? {
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !replies.isEmpty {
                let reply = replies.removeFirst()
                lock.unlock()
                continuation.resume(returning: reply)
                return
            }
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: ExtensionNative.Refused(why: "Native host has exited."))
                return
            }
            let id = UUID()
            waiters.append((id, continuation))
            lock.unlock()
            // After the waiter is in, so a deadline already past still finds it.
            if let deadline, let late {
                timer = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .suspending)
                    guard !Task.isCancelled else { return }
                    self?.giveUp(id, late)
                }
            }
        }
    }

    private func giveUp(_ id: UUID, _ late: Error) {
        lock.lock()
        let index = waiters.firstIndex { $0.id == id }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.reader.resume(throwing: late)
    }

    private func drain() {
        var ended = false
        outputLock.lock()
        if let output, !lock.withLock({ finished }) {
            let fd = output.forReading.fileDescriptor
            let capacity = 64 * 1024
            var bytes = [UInt8](repeating: 0, count: capacity)
            while true {
                let count = Darwin.read(fd, &bytes, capacity)
                if count > 0 { take(Data(bytes.prefix(count))); continue }
                if count == 0 { ended = true; break }
                if errno == EINTR { continue }
                ended = errno != EAGAIN && errno != EWOULDBLOCK
                break
            }
        }
        outputLock.unlock()
        if ended { finish() }
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(chunk)
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages {
            if !waiters.isEmpty {
                handed.append((waiters.removeFirst().reader, message))
            } else if buffersReplies {
                // A request's reply can arrive before readOne installs its
                // waiter, or beside another reply in the same pipe read.
                replies.append(message)
            }
        }
        let rest = messages.dropFirst(handed.count)
        let heard = self.heard
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        // Buffered clients also hear pushes while a read is waiting.
        (buffersReplies ? messages : Array(rest)).forEach { heard?($0) }
    }

    /// Comes twice, once from each end, often at the same moment.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = waiters
        waiters = []
        buffer = Data()
        heard = nil
        let exit = exited
        exited = nil
        lock.unlock()
        output?.forReading.readabilityHandler = nil
        outputLock.lock()
        try? input?.forWriting.close()
        try? output?.forReading.close()
        try? input?.forReading.close()
        try? output?.forWriting.close()
        outputLock.unlock()
        pending.forEach { $0.reader.resume(throwing: ExtensionNative.Refused(why: "Native host has exited.")) }
        exit?()
    }
}

/// Both ends of one pipe(2), opened so that a failure is an error. Pipe()
/// can't say it failed: -[NSPipe init] answers nil when pipe(2) does, and
/// Swift takes that nil as a Pipe.
struct HostChannel {
    let forReading: FileHandle
    let forWriting: FileHandle

    init(_ pipe: Pipe) {
        forReading = pipe.fileHandleForReading
        forWriting = pipe.fileHandleForWriting
    }

    private init(reading: Int32, writing: Int32) {
        forReading = FileHandle(fileDescriptor: reading, closeOnDealloc: true)
        forWriting = FileHandle(fileDescriptor: writing, closeOnDealloc: true)
    }

    static func open() throws -> HostChannel {
        var ends: [Int32] = [-1, -1]
        guard Darwin.pipe(&ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        // Other programs Yab starts don't inherit the host's pipes; the
        // host gets its ends as stdin and stdout, which exec keeps.
        for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return HostChannel(reading: ends[0], writing: ends[1])
    }
}

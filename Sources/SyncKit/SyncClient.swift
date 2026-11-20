import Foundation

// The line to the sync server (docs/sync.md, "Protocol v1"): a socket that
// brings what other devices changed the moment they change it, and takes
// what changed here. Everything that crosses it is sealed. When the line is
// down, changes wait in the journal; when it comes back, a hello with the
// cursor brings what was missed.

public final class SyncClient: @unchecked Sendable {
    public struct Device: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var model: String
        public var platform: String?
        public var formFactor: String?
        public var androidSync: Int?
        public init(id: String, name: String, model: String, platform: String? = nil, formFactor: String? = nil,
                    androidSync: Int = AndroidSyncCompatibility.version) {
            self.id = id; self.name = name; self.model = model
            let inferred = SyncDevicePlatform.read(nil, model: model)
            let resolved = platform ?? (inferred == .unknown ? SyncDevicePlatform.local : inferred).rawValue
            self.platform = resolved
            self.formFactor = formFactor ?? (model.hasPrefix("iPad") ? "tablet" : ["ios", "android"].contains(resolved) ? "phone" : "desktop")
            self.androidSync = androidSync
        }
    }

    public enum State: Equatable, Sendable {
        case off
        case connecting
        /// Caught up and listening.
        case live
        /// Down for now; it tries again by itself.
        case waiting(String)
        /// The server won't take this device: removed from the account, or
        /// the key is not the account's any more. Nothing more is tried.
        case refused(String)
    }

    public let base: URL
    public let journal: Journal
    public let seal: Seal
    public let device: Device
    /// Called on the client's queue with records that changed here because
    /// of another device; the app writes them into its own files.
    public var received: ([Record]) -> Void = { _ in }
    /// Instead of the two steps above, one: the app merges what came into
    /// the journal and writes it into its files in the same breath, so
    /// nothing reads its files back in between and takes the new records
    /// for ones it removed. Called on the client's queue; returns when done.
    public var deliver: (([(record: Record, version: Int64)]) -> Void)?
    public var stateChanged: (State) -> Void = { _ in }
    public private(set) var state: State = .off { didSet { if state != oldValue { stateChanged(state) } } }

    /// Kept between launches by whoever owns the client (the keychain).
    /// Written on `queue`, read on main too (SyncCenter, devices): locked.
    public var token: String? {
        get { tokenLock.withLock { storedToken } }
        set { tokenLock.withLock { storedToken = newValue } }
    }
    private let tokenLock = NSLock()
    private var storedToken: String?
    /// What this device says of itself to the others about once a minute
    /// while live (which tab is in front, say), sealed; it is also what
    /// keeps its `lastSeen` fresh on the server. Nil sends nothing.
    public var presence: (() -> Record?)?
    /// Another device's presence, opened: on the client's queue.
    public var heardPresence: (String, Record) -> Void = { _, _ in }
    private var presenceTimer: DispatchSourceTimer?

    let queue = DispatchQueue(label: "sync.client")
    private let transport: Transport
    private var line: Line?
    /// Counts the lines dialed, so an old one's words and goodbye are known.
    private var lineNumber = 0
    private var inFlight: [String: (record: Record, version: Int64)] = [:]
    /// Names of records whose push asks the server for an alert (kick(alerting:)).
    /// Name to record id: the id, a UUID, also names the alert, so the
    /// phone's own notification of the same question replaces it.
    private var alerting: [String: (id: String, withdraw: Bool)] = [:]
    private var pushID = 0
    private var caughtUp = false
    private var excludedCollections = Set<String>()
    private var registeredThisRun = false
    private var registrationNumber = 0
    private var retry = 0
    private var retryWork: DispatchWorkItem?
    /// Names the server turned away (too big): not sent again this run.
    private var stuck = Set<String>()
    /// Names the server turned away because the account was full: tried
    /// again once something else went up (a removal frees room), so one
    /// full answer no longer stops this device's words from going at all.
    private var full = Set<String>()
    private var freed = false
    static let fullWords = "Sync is full."

    public init(base: URL, journal: Journal, seal: Seal, device: Device, token: String? = nil, transport: Transport? = nil) {
        self.base = base
        self.journal = journal
        self.seal = seal
        self.device = device
        self.storedToken = token
        self.transport = transport ?? WebTransport()
    }

    // MARK: Running

    public func start() {
        queue.async { [self] in
            // Up, or on its way up (registering): a second start would dial
            // a second line beside the first.
            guard line == nil, state != .connecting, !isRefused else { return }
            retryWork?.cancel()
            state = .connecting
            // Refresh persisted platform/capability even when the keychain has a token.
            // A token issued to older software must not claim this build's semantics.
            registeredThisRun = false
            register()
        }
    }

    /// The line closes and stays closed until `start`: the closing socket's
    /// own goodbye, heard after, is an old line's and dials nothing.
    public func stop() {
        queue.async { [self] in
            retryWork?.cancel()
            presenceTimer?.cancel()
            registrationNumber += 1
            line?.close()
            line = nil
            inFlight = [:]
            state = .off
        }
    }

    /// Something changed in the journal: send it if the line is up.
    public func kick() {
        queue.async { [self] in push() }
    }

    /// Disabled records stay pending, and incoming records do not enter the
    /// journal. Enabling replays from the server because the shared cursor
    /// may have advanced past records of a disabled collection.
    public func setExcludedCollections(_ collections: Set<String>) {
        queue.async { [self] in
            let enabled = excludedCollections.subtracting(collections)
            excludedCollections = collections
            if !enabled.isEmpty {
                journal.cursor = 0
                if line != nil {
                    presenceTimer?.cancel()
                    state = .connecting
                    connect()
                    return
                }
            }
            push()
        }
    }

    /// This record asks a person something (an agent's question): the push
    /// that carries it names it, so the server alerts the person's phone at
    /// once instead of waking it silently within the minute.
    public func kick(alerting key: Record.Key, withdraw: Bool = false) {
        queue.async { [self] in
            alerting[seal.name(key)] = (key.id, withdraw)
            push()
        }
    }

    private var isRefused: Bool { if case .refused = state { return true }; return false }

    private func register() {
        registrationNumber += 1
        let number = registrationNumber
        var request = URLRequest(url: base.appendingPathComponent("v1/accounts/\(seal.account)/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": seal.secret,
            "device": ["id": device.id, "name": device.name, "model": device.model,
                       "platform": device.platform ?? SyncDevicePlatform.local.rawValue,
                       "formFactor": device.formFactor ?? (SyncDevicePlatform.local == .iOS ? "phone" : "desktop"),
                       "androidSync": device.androidSync ?? AndroidSyncCompatibility.version] as [String: Any],
        ])
        transport.request(request) { [self] status, data in
            queue.async { [self] in
                // Stopped while asking, or a line already dialed: the answer
                // opens nothing.
                guard number == registrationNumber, state == .connecting, line == nil else { return }
                switch status {
                case 200:
                    guard let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = body["token"] as? String else {
                        return wait("The sync server answered strangely.")
                    }
                    self.token = token
                    self.registeredThisRun = true
                    connect()
                case 409:
                    wait("Update Yab on every device before syncing with Android.")
                case 403:
                    let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    state = .refused(body?["error"] as? String == "revoked" ? "This Mac was removed from Sync." : "This key is not the account's key.")
                case nil:
                    wait("No connection.")
                default:
                    wait("The sync server said \(status ?? 0).")
                }
            }
        }
    }

    private func connect() {
        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue(String(AndroidSyncCompatibility.version), forHTTPHeaderField: "X-Yab-Android-Sync")
        caughtUp = false
        inFlight = [:]
        full = []
        freed = false
        // One line at a time: one still open is closed, not left unheard.
        line?.close()
        // Each line speaks only for itself: what an old one still says after
        // a stop, or after a new one was dialed, is not heard.
        lineNumber += 1
        let number = lineNumber
        line = transport.open(request, received: { [weak self] text in
            self?.queue.async {
                guard let self, self.isCurrent(number) else { return }
                self.heard(text)
            }
        }, closed: { [weak self] code in
            self?.queue.async {
                guard let self, self.isCurrent(number) else { return }
                self.lost(code)
            }
        })
        send(["t": "hello", "cursor": journal.cursor, "v": 1])
    }

    /// The line numbered `number` is the one up now.
    private func isCurrent(_ number: Int) -> Bool { line != nil && lineNumber == number }

    private var socketURL: URL {
        var parts = URLComponents(url: base.appendingPathComponent("v1/accounts/\(seal.account)/socket"), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        return parts.url!
    }

    private func lost(_ code: Int?) {
        guard state != .off else { return }
        presenceTimer?.cancel()
        line = nil
        inFlight = [:]
        switch code {
        case 4001, 4003, 4004, 401:
            // Our token is no good. Registering again with the key says
            // whether this device was removed (refused) or just forgotten.
            if code == 4003 {
                state = .refused("This Mac was removed from Sync.")
            } else {
                token = nil
                registeredThisRun = false
                wait("Signing in again.", soon: true)
            }
        default:
            wait("No connection.")
        }
    }

    private func wait(_ why: String, soon: Bool = false) {
        guard !isRefused else { return }
        line?.close()
        line = nil
        state = .waiting(why)
        let delay = soon ? 0.5 : min(60, pow(2, Double(retry)))
        retry += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.line == nil, !self.isRefused, self.state != .off else { return }
            self.state = .connecting
            if self.token == nil || !self.registeredThisRun { self.register() } else { self.connect() }
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Messages

    private func heard(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["t"] as? String
        else { return }
        switch type {
        case "changes":
            let items = message["items"] as? [[String: Any]] ?? []
            take(items.compactMap(opened))
            if let cursor = (message["cursor"] as? NSNumber)?.int64Value, cursor > journal.cursor { journal.cursor = cursor }
            if message["more"] as? Bool != true, !caughtUp {
                caughtUp = true
                retry = 0
                state = .live
                push()
                sayPresence()
                startPresence()
            }
        case "pushed":
            let accepted = message["accepted"] as? [[String: Any]] ?? []
            var sent: [(Record, Int64)] = []
            var top = journal.cursor
            for item in accepted {
                guard let name = item["name"] as? String, let flight = inFlight.removeValue(forKey: name),
                      let version = (item["version"] as? NSNumber)?.int64Value else { continue }
                sent.append((flight.record, version))
                if journal.record(flight.record.key) == flight.record { alerting.removeValue(forKey: name) }
                if let seq = (item["seq"] as? NSNumber)?.int64Value { top = max(top, seq) }
            }
            try? journal.sent(sent)
            // Nothing of anyone else's comes after ours unseen: the server
            // sent it down this same socket first.
            if top > journal.cursor { journal.cursor = top }
            var conflicts: [(Record, Int64)] = []
            for item in message["conflicts"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, let flight = inFlight.removeValue(forKey: name) else { continue }
                if let theirs = opened(item) {
                    conflicts.append(theirs)
                } else {
                    // The server has no such record (an account made again):
                    // send ours as new.
                    try? journal.rebase(flight.record.key, version: (item["version"] as? NSNumber)?.int64Value ?? 0)
                }
            }
            take(conflicts)
            if !sent.isEmpty, !full.isEmpty { freed = true }
            for item in message["rejected"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                if item["code"] as? String == "full" { full.insert(name) } else { stuck.insert(name) }
                inFlight[name] = nil
            }
            if inFlight.isEmpty { push() }
        case "presence":
            if let device = message["device"] as? String, let blob = (message["blob"] as? String).flatMap({ Data(base64Encoded: $0) }),
               let record = try? seal.open(blob, name: seal.name(.init(collection: "presence", id: device))) {
                heardPresence(device, record)
            }
        case "error":
            if message["code"] as? String == "full" { state = .waiting(Self.fullWords) }
        default:
            break
        }
    }

    private func opened(_ item: [String: Any]) -> (Record, Int64)? {
        guard let name = item["name"] as? String, let blob = item["blob"] as? String,
              let data = Data(base64Encoded: blob), let record = try? seal.open(data, name: name)
        else { return nil }
        return (record, (item["version"] as? NSNumber)?.int64Value ?? 0)
    }

    private func take(_ items: [(Record, Int64)]) {
        let items = items.filter { !excludedCollections.contains($0.0.collection) }
        guard !items.isEmpty else { return }
        if let deliver { return deliver(items.map { ($0.0, $0.1) }) }
        guard let changed = try? journal.receive(items.map { ($0.0, $0.1) }), !changed.isEmpty else { return }
        received(changed)
    }

    /// The most one push carries, in base64 of sealed records. The server
    /// hands what it takes on to the other devices in one message, and a
    /// socket message is safest kept under a megabyte, the receive limit of
    /// a socket that hasn't raised it and of Cloudflare's: 200 small records
    /// go at once, a plugin's parts (85 KB each) eight or so at a time.
    public static let pushBytes = 768 * 1024

    private func push() {
        // Full, the line stays up and what fits still goes: a removal
        // makes room for what was turned away.
        guard state == .live || state == .waiting(Self.fullWords), caughtUp, line != nil, inFlight.isEmpty else { return }
        let pending = journal.pending(limit: 200 + stuck.count + full.count, excluding: excludedCollections).filter {
            let name = seal.name($0.record.key)
            return !stuck.contains(name) && !full.contains(name)
        }.prefix(200)
        guard !pending.isEmpty else {
            if !full.isEmpty, freed {
                full = []
                freed = false
                return push()
            }
            if full.isEmpty, state != .live { state = .live }
            return
        }
        var changes: [[String: Any]] = []
        var bytes = 0
        var hasAlert = false
        for (record, version) in pending {
            guard let blob = try? seal.seal(record) else { continue }
            let text = blob.base64EncodedString()
            // The rest go with the next push, once this one is taken.
            if !changes.isEmpty, bytes + text.utf8.count > Self.pushBytes { break }
            bytes += text.utf8.count
            let name = seal.name(record.key)
            if alerting[name] != nil {
                if hasAlert { break }
                hasAlert = true
            }
            inFlight[name] = (record, version)
            changes.append(["name": name, "base": version, "blob": text])
        }
        pushID += 1
        var message: [String: Any] = ["t": "push", "id": "p\(pushID)", "changes": changes]
        if let asked = changes.lazy.compactMap({ $0["name"] as? String }).first(where: { alerting[$0] != nil }) {
            message["alert"] = asked
            if let hint = alerting[asked], UUID(uuidString: hint.id) != nil {
                message["alertID"] = hint.id
                if hint.withdraw { message["withdraw"] = true }
            }
        }
        send(message)
    }

    /// Now, and then every minute until the line goes.
    public func sayPresence() {
        queue.async { [self] in
            guard state == .live, let record = presence?(), let blob = try? seal.seal(record) else { return }
            send(["t": "presence", "blob": blob.base64EncodedString()])
        }
    }

    private func startPresence() {
        presenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 55, repeating: 55)
        timer.setEventHandler { [weak self] in self?.sayPresence() }
        timer.resume()
        presenceTimer = timer
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        line?.send(text)
    }

    // MARK: Account

    public struct Listed: Sendable, Equatable {
        public var id: String
        public var name: String
        public var model: String
        public var platform: String?
        public var formFactor: String?
        public var androidSync: Int
        public var lastSeen: Date?
        public var revoked: Bool
        public var devicePlatform: SyncDevicePlatform { SyncDevicePlatform.read(platform, model: model) }
        public var isMobile: Bool { devicePlatform.isMobile }
        public var isMac: Bool { devicePlatform == .macOS }

        public init(id: String, name: String, model: String, lastSeen: Date?, revoked: Bool,
                    platform: String? = nil, formFactor: String? = nil, androidSync: Int = 0) {
            self.id = id; self.name = name; self.model = model; self.lastSeen = lastSeen; self.revoked = revoked
            self.platform = platform; self.formFactor = formFactor; self.androidSync = androidSync
        }
    }

    public func devices(_ done: @escaping ([Listed]?) -> Void) {
        call("GET", "v1/accounts/\(seal.account)/devices") { status, data in
            guard status == 200, let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = body["devices"] as? [[String: Any]] else { return done(nil) }
            done(list.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let seen = (item["lastSeen"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                return Listed(id: id, name: item["name"] as? String ?? "", model: item["model"] as? String ?? "",
                              lastSeen: seen, revoked: (item["revoked"] as? Bool) ?? ((item["revoked"] as? NSNumber)?.boolValue ?? false),
                              platform: item["platform"] as? String, formFactor: item["formFactor"] as? String,
                              androidSync: (item["androidSync"] as? NSNumber)?.intValue ?? 0)
            })
        }
    }

    /// Signs in and no more: no line, nothing sent. For AccountMove.peek.
    func signIn(_ done: @escaping @Sendable (Bool) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("v1/accounts/\(seal.account)/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": seal.secret,
            "device": ["id": device.id, "name": device.name, "model": device.model,
                       "platform": device.platform ?? SyncDevicePlatform.local.rawValue,
                       "formFactor": device.formFactor ?? "desktop",
                       "androidSync": device.androidSync ?? AndroidSyncCompatibility.version] as [String: Any],
        ])
        transport.request(request) { [self] status, data in
            guard status == 200, let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = body["token"] as? String else { return done(false) }
            queue.async { [self] in
                self.token = token
                done(true)
            }
        }
    }

    public func remove(device id: String, _ done: @escaping (Bool) -> Void) {
        call("DELETE", "v1/accounts/\(seal.account)/devices/\(id)") { status, _ in done(status == 204 || status == 200) }
    }

    public func deleteAccount(_ done: @escaping (Bool) -> Void) {
        call("DELETE", "v1/accounts/\(seal.account)") { status, _ in done(status == 204 || status == 200) }
    }

    private func call(_ method: String, _ path: String, body: Any? = nil, _ done: @escaping (Int?, Data?) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        transport.request(request, done)
    }
}

// MARK: - Two accounts of one person

/// Two accounts become one (docs/sync.md, "Two accounts"). A device holding
/// both keys looks at the other account's devices, and leaves a record in
/// the account that ends with the key of the one that stays: its devices,
/// a phone included, go on by themselves, whenever they next come up.
public enum AccountMove {
    public static let id = "key"

    /// The key an `accountmove` record sends this device to.
    public static func destination(_ records: [Record], from seal: Seal) -> Seal? {
        for record in records where record.collection == SyncCollection.moved && record.id == id && record.deleted == nil {
            guard case let .string(text)? = record.fields["seal"], let raw = Data(base64Encoded: text), raw != seal.raw,
                  let there = Seal(raw: raw) else { continue }
            return there
        }
        return nil
    }

    public static func fields(to seal: Seal) -> [String: Value] { ["seal": .string(seal.raw.base64EncodedString())] }

    /// The devices in an account, without staying in it: signs in under a
    /// name of its own for the moment, reads the list and leaves. Nil with
    /// no answer or a key the account no longer takes.
    public static func peek(_ seal: Seal, device: SyncClient.Device, base: URL, transport: Transport = WebTransport(),
                            _ done: @escaping @Sendable ([SyncClient.Listed]?) -> Void) {
        let id = "look-" + UUID().uuidString
        let look = SyncClient.Device(id: id, name: device.name, model: device.model)
        DispatchQueue.global(qos: .utility).async {
            guard let journal = try? Journal(path: nil, device: id) else { return done(nil) }
            let client = SyncClient(base: base, journal: journal, seal: seal, device: look, transport: transport)
            client.signIn { signedIn in
                guard signedIn else { return done(nil) }
                client.devices { list in
                    client.remove(device: id) { _ in done(list?.filter { !$0.revoked && $0.id != id }) }
                }
            }
        }
    }

    /// Leaves the record in an account this device isn't running in, from
    /// a journal of its own for the moment.
    public static func leave(in seal: Seal, to destination: Seal, device: SyncClient.Device, folder: URL, base: URL,
                             transport: Transport = WebTransport(), timeout: TimeInterval = 90,
                             _ done: @escaping @Sendable (Bool) -> Void) {
        let id = "move-" + UUID().uuidString
        let path = folder.appendingPathComponent("sync-\(id).sqlite").path
        DispatchQueue.global(qos: .utility).async {
            func clear() { for tail in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + tail) } }
            guard let journal = try? Journal(path: path, device: id) else { return done(false) }
            let look = SyncClient.Device(id: id, name: device.name, model: device.model)
            let client = SyncClient(base: base, journal: journal, seal: seal, device: look, transport: transport)
            let until = Date().addingTimeInterval(timeout)
            let key = Record.Key(collection: SyncCollection.moved, id: self.id)
            guard (try? journal.change(key, fields(to: destination))) != nil else { clear(); return done(false) }
            client.start()
            func wait() {
                let sent = journal.pending().isEmpty
                if sent || Date() > until {
                    client.remove(device: id) { _ in
                        client.stop()
                        clear()
                        done(sent)
                    }
                    return
                }
                client.kick()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: wait)
            }
            wait()
        }
    }
}

// MARK: - Joining by a code, over the server's pairing box

public enum Pairing {
    /// A wait under a code, stopped by `cancel()`: nothing more is read or
    /// sent and nothing more is said. A wait left running kept the box read
    /// every two seconds for its ten minutes, and a few of them from one
    /// house could be enough for the server's door to turn that address away,
    /// every other device's pairing with it (register 1628).
    public final class Asking: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        public init() {}
        public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    }

    /// Why a wait ended without the key.
    public enum Failure: Error, Equatable, Sendable {
        /// Another device's key was under the code first (a code a Mac
        /// shows, used already).
        case taken
        /// Ten minutes and nobody let it in.
        case expired
        /// An answer this device can't open: not sealed to it.
        case unreadable
        /// The server won't take the box at all.
        case refused(Int?)
    }

    /// The new device: posts its public key under the code and waits up to
    /// `timeout` for a device in the account to seal the key to it.
    @discardableResult
    public static func ask(_ joining: Joining, base: URL, transport: Transport = WebTransport(), timeout: TimeInterval = 600,
                           every: TimeInterval = 2, _ done: @escaping (Seal?) -> Void) -> Asking {
        wait(joining, base: base, transport: transport, timeout: timeout, every: every) { done(try? $0.get()) }
    }

    /// The same, saying why it ended without the key. A moment without
    /// network, or the server busy, is waited out: before, one failed read
    /// in ten minutes ended the wait and took the code off the screen, so a
    /// code typed on the other device found nobody waiting.
    @discardableResult
    public static func wait(_ joining: Joining, base: URL, transport: Transport = WebTransport(), timeout: TimeInterval = 600,
                            every: TimeInterval = 2, ended: @escaping (Result<Seal, Failure>) -> Void) -> Asking {
        let asking = Asking()
        // The box and the tag come from the stretched code, a fifth of a
        // second of work: never on the caller's thread, the main one.
        DispatchQueue.global(qos: .userInitiated).async {
            run(joining, base: base, transport: transport, timeout: timeout, every: every, asking: asking, ended)
        }
        return asking
    }

    private static func run(_ joining: Joining, base: URL, transport: Transport, timeout: TimeInterval, every: TimeInterval,
                            asking: Asking, _ ended: @escaping (Result<Seal, Failure>) -> Void) {
        let until = Date().addingTimeInterval(timeout)
        func later(_ delay: TimeInterval, _ step: @escaping () -> Void) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { step() }
        }
        func post(first: Bool) {
            guard !asking.isCancelled else { return }
            guard Date() < until else { return ended(.failure(.expired)) }
            var request = URLRequest(url: base.appendingPathComponent("v1/pair"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": joining.box, "pub": joining.posted])
            transport.request(request) { status, _ in
                guard !asking.isCancelled else { return }
                switch status {
                case 200?, 204?: poll()
                // Taken: by another device on the first post; by this one's
                // own earlier post when putting the box back.
                case 409?: first ? ended(.failure(.taken)) : poll()
                case 400?, 410?: ended(.failure(.refused(status)))
                // No network for a moment, or too many asks from this
                // address (429): again a little later, the same code.
                default: later(every * 2) { post(first: first) }
                }
            }
        }
        func poll() {
            guard !asking.isCancelled else { return }
            guard Date() < until else { return ended(.failure(.expired)) }
            transport.request(URLRequest(url: base.appendingPathComponent("v1/pair/\(joining.box)"))) { status, data in
                guard !asking.isCancelled else { return }
                switch status {
                case 200?:
                    guard let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return later(every) { poll() }
                    }
                    if let envelope = (body["envelope"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                        if let seal = try? joining.open(envelope) { return ended(.success(seal)) }
                        return ended(.failure(.unreadable))
                    }
                    later(every) { poll() }
                // Swept or read out: the same key under the same code again.
                case 404?: post(first: false)
                case 400?, 410?: ended(.failure(.refused(status)))
                default: later(every * 2) { poll() }
                }
            }
        }
        post(first: true)
    }

    /// The device already in: the code someone typed, answered with the key.
    /// False when no device waits under the code (or its key wasn't posted
    /// by one that knows the code); a moment without network is tried again.
    public static func answer(code: String, seal: Seal, base: URL, transport: Transport = WebTransport(), retry: TimeInterval = 2,
                              _ done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            answering(code: code, seal: seal, base: base, transport: transport, tries: 3, retry: retry, done)
        }
    }

    /// Worth asking again: no answer, the door busy, the server failing.
    static func passing(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status == 429 || status >= 500
    }

    private static func answering(code: String, seal: Seal, base: URL, transport: Transport, tries: Int, retry: TimeInterval,
                                  _ done: @escaping (Bool) -> Void) {
        let box = Joining.box(code)
        func again() -> Bool {
            guard tries > 1 else { return false }
            DispatchQueue.global().asyncAfter(deadline: .now() + retry) {
                answering(code: code, seal: seal, base: base, transport: transport, tries: tries - 1, retry: retry, done)
            }
            return true
        }
        transport.request(URLRequest(url: base.appendingPathComponent("v1/pair/\(box)"))) { status, data in
            if passing(status), again() { return }
            guard status == 200, let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  // Only a key posted by a device that knows the code.
                  let pub = Joining.verified(body["pub"] as? String, code: code),
                  let envelope = try? Joining.seal(seal, to: pub, code: code)
            else { return done(false) }
            var put = URLRequest(url: base.appendingPathComponent("v1/pair/\(box)"))
            put.httpMethod = "PUT"
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.httpBody = try? JSONSerialization.data(withJSONObject: ["envelope": envelope.base64EncodedString()])
            transport.request(put) { status, _ in
                if passing(status), again() { return }
                done(status == 204 || status == 200)
            }
        }
    }
}

// MARK: - Transport

/// An open socket.
public protocol Line: AnyObject {
    func send(_ text: String)
    func close()
}

/// How the client reaches the server: the web for real, a server in
/// memory for tests.
public protocol Transport: Sendable {
    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void)
    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line
}

public final class WebTransport: NSObject, Transport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var closers: [Int: (Int?) -> Void] = [:]
    private let lock = NSLock()

    public override init() { super.init() }

    public func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        var request = request
        request.timeoutInterval = 30
        session.dataTask(with: request) { data, response, _ in
            done((response as? HTTPURLResponse)?.statusCode, data)
        }.resume()
    }

    /// What one message from the server may be: its catch-up batches go up
    /// to 4 MB, and URLSession's own limit, a megabyte, would end the line
    /// on the first batch past it and dial again forever.
    public static let largestMessage = 16 * 1024 * 1024

    /// A socket for `request` that takes the server's largest messages.
    static func socket(_ session: URLSession, _ request: URLRequest) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = largestMessage
        return task
    }

    public func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
        let task = Self.socket(session, request)
        let line = WebLine(task: task)
        lock.lock(); closers[task.taskIdentifier] = closed; lock.unlock()
        func listen() {
            task.receive { [weak self] result in
                switch result {
                case .success(.string(let text)): received(text); listen()
                case .success(.data(let data)): received(String(decoding: data, as: UTF8.self)); listen()
                case .success: listen()
                case .failure:
                    let code = task.closeCode == .invalid ? (task.response as? HTTPURLResponse)?.statusCode : task.closeCode.rawValue
                    self?.finish(task, code)
                }
            }
        }
        task.resume()
        listen()
        line.ping()
        return line
    }

    private func finish(_ task: URLSessionTask, _ code: Int?) {
        lock.lock(); let closed = closers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        closed?(code)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(webSocketTask, closeCode.rawValue)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        finish(task, status == 101 ? nil : status)
    }
}

final class WebLine: Line, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private var timer: DispatchSourceTimer?
    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) { task.send(.string(text)) { _ in } }

    func close() {
        timer?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// A ping every 30 s, so a line that died quietly (a Mac waking from
    /// sleep on another network) is noticed and dialed again.
    func ping() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.task.sendPing { error in if error != nil { self?.task.cancel(with: .goingAway, reason: nil) } }
        }
        timer.resume()
        self.timer = timer
    }
}

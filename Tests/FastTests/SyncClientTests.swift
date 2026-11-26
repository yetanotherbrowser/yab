import Foundation
import Testing
@testable import SyncKit
@testable import Fast

/// The client against a server in memory that speaks protocol v1
/// (docs/sync.md) the way sync-server does: two devices of one account
/// see each other's changes live, a change made while apart comes in on the
/// next hello, a conflict is merged and sent again, and a removed device
/// stops. The Worker itself is tested in sync-server/.
struct SyncClientTests {
    init() { Kind.register(Kind("c.mark", groups: [Kind.place])) }

    private func client(_ server: MemoryServer, _ seal: Seal, _ device: String) throws -> SyncClient {
        let journal = try Journal(path: nil, device: device)
        return SyncClient(base: URL(string: "https://sync.test")!, journal: journal, seal: seal,
                          device: .init(id: device, name: device, model: "test"), transport: server)
    }

    /// Waits on the client's queue until `done` holds, up to two seconds.
    private func until(_ client: SyncClient, _ done: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if client.queue.sync(execute: done) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test func twoDevicesSeeEachOthersChanges() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        a.start(); b.start()
        #expect(await until(a) { a.state == .live })
        #expect(await until(b) { b.state == .live })
        try a.journal.change(.init(collection: "c.mark", id: "1"), ["title": "From A"])
        a.kick()
        #expect(await until(b) { b.journal.record(.init(collection: "c.mark", id: "1"))?["title"] == "From A" })
        #expect(await until(a) { a.journal.pending().isEmpty })
        // Nothing the server holds can be read without the key.
        #expect(!server.everything.contains("From A"))
    }

    @Test func aQuestionsPushAsksForAnAlertOnce() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a")
        a.start()
        #expect(await until(a) { a.state == .live })
        let key = SyncKit.Record.Key(collection: "c.mark", id: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10")
        try a.journal.change(key, ["title": "Pay?"])
        a.kick(alerting: key)
        #expect(await until(a) { a.journal.pending().isEmpty })
        try a.journal.change(.init(collection: "c.mark", id: "plain"), ["title": "Plain"])
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        server.lock.lock(); let alerts = server.alerts, ids = server.alertIDs; server.lock.unlock()
        #expect(alerts == [seal.name(key)])
        #expect(ids == [key.id])
    }

    @Test func aBatchKeepsEachQuestionsWakeAndWithdrawsWithoutRinging() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a")
        defer { a.stop() }
        let keys = (0..<3).map { _ in SyncKit.Record.Key(collection: "c.mark", id: UUID().uuidString.lowercased()) }
        // All three are waiting before the line opens. Each needs its hint.
        for key in keys {
            try a.journal.change(key, ["title": "Question"])
            a.kick(alerting: key)
        }
        a.start()
        #expect(await until(a) { a.state == .live && a.journal.pending().isEmpty })
        server.lock.lock(); let asked = server.alertIDs; server.lock.unlock()
        #expect(Set(asked) == Set(keys.map(\.id)))
        #expect(asked.count == 3)
        try a.journal.remove(keys[0])
        a.kick(alerting: keys[0], withdraw: true)
        #expect(await until(a) { a.journal.pending().isEmpty })
        server.lock.lock(); let withdrawn = server.withdrawals; server.lock.unlock()
        #expect(withdrawn == [keys[0].id])
    }

    @Test func aChangeMadeApartComesInOnTheNextHello() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a")
        a.start()
        #expect(await until(a) { a.state == .live })
        try a.journal.change(.init(collection: "c.mark", id: "1"), ["title": "Early"])
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        let b = try client(server, seal, "b")
        b.start()
        #expect(await until(b) { b.journal.record(.init(collection: "c.mark", id: "1"))?["title"] == "Early" })
        #expect(b.journal.cursor > 0)
    }

    @Test func aConflictIsMergedAndSentAgain() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        a.start()
        #expect(await until(a) { a.state == .live })
        try a.journal.change(.init(collection: "c.mark", id: "1"), ["title": "T", "url": "https://a.test"])
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        b.start()
        #expect(await until(b) { b.journal.record(.init(collection: "c.mark", id: "1")) != nil })
        // Both change different fields of the same record, b while its
        // socket is held so its push lands on an older version.
        server.hold = true
        try b.journal.change(.init(collection: "c.mark", id: "1"), ["url": "https://b.test"])
        b.kick()
        try a.journal.change(.init(collection: "c.mark", id: "1"), ["title": "Renamed"])
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        server.hold = false
        server.release()
        let key = Record.Key(collection: "c.mark", id: "1")
        #expect(await until(b) { b.journal.pending().isEmpty && b.journal.record(key)?["title"] == "Renamed" })
        #expect(await until(a) { a.journal.record(key)?["url"] == "https://b.test" })
        #expect(b.journal.record(key)?["url"] == "https://b.test")
    }

    /// A server behind this device's journal (sync set up again over an
    /// old sync.sqlite, #1088) once answered the merge with the same
    /// conflict twice a second for good: it goes again on the version given.
    @Test func aConflictWithAServerBehindIsSentOnTheVersionGiven() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let key = Record.Key(collection: "c.mark", id: "1")
        let b = try client(server, seal, "b")
        b.start()
        #expect(await until(b) { b.state == .live })
        try b.journal.change(key, ["url": "https://b.test"])
        b.kick()
        #expect(await until(b) { b.journal.pending().isEmpty })
        let a = try client(server, seal, "a")
        try a.journal.change(key, ["title": "Mac"])
        try a.journal.rebase(key, version: 5)
        a.start()
        #expect(await until(a) { a.journal.pending().isEmpty })
        server.lock.lock(); let pushes = server.pushes["a"] ?? 0; server.lock.unlock()
        #expect(pushes == 2)
        #expect(a.journal.record(key)?["url"] == "https://b.test")
        #expect(await until(b) { b.journal.record(key)?["title"] == "Mac" })
    }

    /// A conflict whose merge didn't happen (a failed write, or the app's
    /// deliver turning it away) is not sent on the server's version: that
    /// would replace the fields only the server has.
    @Test func aConflictLeftUnmergedKeepsTheServersFields() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let key = Record.Key(collection: "c.mark", id: "1")
        let b = try client(server, seal, "b")
        b.start()
        #expect(await until(b) { b.state == .live })
        try b.journal.change(key, ["url": "https://b.test"])
        b.kick()
        #expect(await until(b) { b.journal.pending().isEmpty })
        let a = try client(server, seal, "a")
        a.deliver = { _ in }
        try a.journal.change(key, ["title": "Mac"])
        a.start()
        #expect(await until(a) {
            server.lock.lock(); defer { server.lock.unlock() }
            return a.journal.pending().isEmpty || (server.pushes["a"] ?? 0) >= 3
        })
        a.stop()
        server.lock.lock(); let blob = server.records.values.first?[seal.name(key)]?.blob; server.lock.unlock()
        let kept = try blob.flatMap { Data(base64Encoded: $0) }.map { try seal.open($0, name: seal.name(key)) }
        #expect(kept?["url"] == "https://b.test")
    }

    /// A full account once stopped a device's every change for good, the
    /// iPhone's words to the Mac among them: now what fits still goes, and
    /// a removal that frees room lets what was turned away go after it.
    @Test func aFullAccountTakesWhatFitsAndWhatARemovalFrees() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a")
        a.start()
        #expect(await until(a) { a.state == .live })
        let words = String(repeating: "w", count: 4000)
        try a.journal.change(.init(collection: "c.mark", id: "old"), ["title": .string(words)])
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        server.lock.lock(); server.capacity = server.records.values.flatMap(\.values).reduce(0) { $0 + $1.blob.utf8.count } + 1500; server.lock.unlock()
        // Too big while the old one holds its words.
        try a.journal.change(.init(collection: "c.mark", id: "new"), ["title": .string(words)])
        a.kick()
        #expect(await until(a) { a.state == .waiting("Sync is full.") })
        // Still on the line: a small one goes, full or not.
        try a.journal.change(.init(collection: "c.mark", id: "small"), ["title": "S"])
        a.kick()
        #expect(await until(a) { a.journal.pending().map(\.record.id) == ["new"] })
        // The old one removed with its words cleared makes room.
        try a.journal.reconcile("c.mark", ["new": ["title": .string(words)], "small": ["title": "S"]], blank: true)
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty && a.state == .live })
    }

    @Test func removedStepsLoseTheirWords() throws {
        let journal = try Journal(path: nil, device: "a")
        try journal.reconcile("c.mark", ["1": ["title": "Long words"], "2": ["title": "Kept"]])
        try journal.reconcile("c.mark", ["2": ["title": "Kept"]])
        let raw = { journal.all("c.mark") }
        #expect(raw().first { $0.id == "1" }?.fields["title"]?.isNull == false)
        #expect(try journal.blankRemoved("c.mark") == 1)
        #expect(raw().first { $0.id == "1" }?.fields.values.allSatisfy(\.isNull) == true)
        #expect(raw().first { $0.id == "1" }?.alive() == false)
        #expect(journal.record(.init(collection: "c.mark", id: "2"))?["title"] == "Kept")
        #expect(try journal.blankRemoved("c.mark") == 0)
    }

    @Test func aRemovedDeviceStops() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a")
        a.start()
        #expect(await until(a) { a.state == .live })
        server.revoke("a")
        #expect(await until(a) { if case .refused = a.state { return true }; return false })
    }

    @Test func aRemovedMacCanRejoinTheSameAccount() async throws {
        let suite = "dev.serafim.fast.rejoin-tests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let identity = SyncDeviceIdentity(settings: settings)
        settings.set("dark", forKey: "look")
        let originalID = identity.id
        let server = MemoryServer(), seal = Seal.make()
        let original = try client(server, seal, originalID)
        defer { original.stop() }
        original.start()
        #expect(await until(original) { original.state == .live })
        let key = Record.Key(collection: "c.mark", id: "kept-before-removal")
        try original.journal.change(key, ["title": "Kept in this account"])
        original.kick()
        #expect(await until(original) { original.journal.pending().isEmpty })

        server.revoke(originalID)
        #expect(await until(original) { if case .refused = original.state { return true }; return false })
        let refused = original.queue.sync { original.state }
        original.stop()
        #expect(await until(original) { original.state == .off })

        // Turning off can't only forget the token: protocol v1 refuses
        // this device id for good, even with the right account key.
        let rejected = try client(server, seal, originalID)
        defer { rejected.stop() }
        rejected.start()
        #expect(await until(rejected) { if case .refused = rejected.state { return true }; return false })

        // SyncCenter.turnOff reads the refusal before stop turns the
        // client off; applied after, as there.
        identity.turnOff(after: refused, device: originalID)
        let replacementID = identity.id
        #expect(replacementID != originalID)
        #expect(settings.string(forKey: "look") == "dark")
        let rejoined = try client(server, seal, replacementID)
        defer { rejoined.stop() }
        rejoined.start()
        #expect(await until(rejoined) { rejoined.state == .live && rejoined.journal.record(key)?["title"] == "Kept in this account" })

        // A late finish of the refused client can't retire the id the
        // new join already registered.
        identity.turnOff(after: refused, device: originalID)
        #expect(settings.string(forKey: "sync.device") == replacementID)
    }

    @Test func anOrdinaryOffAndOnKeepsTheMacsID() async throws {
        let suite = "dev.serafim.fast.off-on-tests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let identity = SyncDeviceIdentity(settings: settings)
        let originalID = identity.id
        let server = MemoryServer(), seal = Seal.make()
        let original = try client(server, seal, originalID)
        defer { original.stop() }
        original.start()
        #expect(await until(original) { original.state == .live })
        let previousState = original.queue.sync { original.state }
        let previousToken = original.queue.sync { original.token }
        original.stop()
        #expect(await until(original) { original.state == .off })
        identity.turnOff(after: previousState, device: originalID)
        let keptID = identity.id
        #expect(keptID == originalID)

        // A fresh client has no token, as after sync off and on, and
        // registers the same id again rather than a second Mac.
        let restarted = try client(server, seal, keptID)
        defer { restarted.stop() }
        restarted.start()
        #expect(await until(restarted) { restarted.state == .live })
        #expect(restarted.queue.sync { restarted.token } != previousToken)
    }

    @Test func aWrongKeyIsRefused() async throws {
        let server = MemoryServer()
        let seal = Seal.make()
        let a = try client(server, seal, "a")
        a.start()
        #expect(await until(a) { a.state == .live })
        server.verifier[seal.account] = "something else"
        let b = try client(server, seal, "b")
        b.start()
        #expect(await until(b) { if case .refused = b.state { return true }; return false })
    }

    /// A real socket says goodbye after it is closed; a stopped client must
    /// not take that for a dropped line and dial again (sync-ios.md, R6).
    @Test func aStoppedClientStaysStopped() async throws {
        let server = MemoryServer(), seal = Seal.make()
        server.goodbyes = true
        let a = try client(server, seal, "a")
        var states: [SyncClient.State] = []
        a.stateChanged = { states.append($0) }
        a.start()
        #expect(await until(a) { a.state == .live })
        a.stop()
        #expect(await until(a) { a.state == .off })
        // Longer than the first retry's pause (1 s).
        try await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(a.queue.sync { a.state } == .off)
        #expect(a.queue.sync { states.last } == .off)
        #expect(!a.queue.sync { states.contains { if case .waiting = $0 { return true }; return false } })
        #expect(server.socketCount("a") == 0)
    }

    /// Started again at once: the old line's goodbye arrives after the new
    /// line is up and must not drop it.
    @Test func startRightAfterStopKeepsTheNewLine() async throws {
        let server = MemoryServer(), seal = Seal.make()
        server.goodbyes = true
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        a.start(); b.start()
        #expect(await until(a) { a.state == .live })
        #expect(await until(b) { b.state == .live })
        a.stop()
        a.start()
        #expect(await until(a) { a.state == .live })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(a.queue.sync { a.state } == .live)
        #expect(server.socketCount("a") == 1)
        try b.journal.change(.init(collection: "c.mark", id: "2"), ["title": "After the restart"])
        b.kick()
        #expect(await until(a) { a.journal.record(.init(collection: "c.mark", id: "2"))?["title"] == "After the restart" })
    }

    /// Started twice while it registers (an iPhone's launch, then its
    /// coming to the front): one line, never a second left open unheard.
    @Test func aSecondStartWhileRegisteringDialsNothing() async throws {
        let server = MemoryServer(), seal = Seal.make()
        server.goodbyes = true
        let a = try client(server, seal, "a")
        a.start()
        a.start()
        #expect(await until(a) { a.state == .live })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.socketCount("a") == 1)
        #expect(a.queue.sync { a.state } == .live)
    }

    /// A plugin's parts (85 KB each sealed) pushed in one go would be one
    /// message past a socket's megabyte, there and in the server's handing
    /// on: the Mac pushing and every other one would lose the line for
    /// good. Each push stays under it, and a socket here takes the
    /// server's largest catch-up batch.
    @Test func aPushOfManyLargeRecordsStaysUnderASocketsLimit() async throws {
        let server = MemoryServer(), seal = Seal.make()
        server.limit = 1_048_576
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        a.start(); b.start()
        #expect(await until(a) { a.state == .live })
        #expect(await until(b) { b.state == .live })
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789_-")
        for n in 0..<13 {
            let text = String((0..<64_000).map { _ in letters.randomElement()! })
            try a.journal.change(.init(collection: "c.big", id: "\(n)"), ["data": .string(text)])
        }
        a.kick()
        #expect(await until(a) { a.journal.pending().isEmpty })
        #expect(await until(b) { (0..<13).allSatisfy { b.journal.record(.init(collection: "c.big", id: "\($0)")) != nil } })
        #expect(server.tooBig == 0 && server.largest <= SyncClient.pushBytes + 100_000)
        let task = WebTransport.socket(URLSession.shared, URLRequest(url: URL(string: "wss://sync.test/v1/socket")!))
        defer { task.cancel() }
        #expect(task.maximumMessageSize >= 4 * 1024 * 1024 + 1024 * 1024)
    }

    @Test func recoveryKeysAndCodesCarryTheKey() throws {
        let seal = Seal.make()
        let typed = seal.recovery.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(Seal(recovery: typed)?.raw == seal.raw)
        var wrong = Array(seal.recovery)
        wrong[0] = wrong[0] == "A" ? "B" : "A"
        #expect(Seal(recovery: String(wrong)) == nil)
        let joining = Joining()
        let envelope = try Joining.seal(seal, to: joining.publicKey, code: joining.code.lowercased())
        #expect(try joining.open(envelope).raw == seal.raw)
        #expect(throws: (any Error).self) { try Joining(code: "ZZZZ-ZZZZ").open(envelope) }
        #expect(seal.account != Seal.make().account && seal.account.count >= 16)
    }
}

/// Protocol v1 in memory, one account per seal account id.
final class MemoryServer: Transport, @unchecked Sendable {
    struct Item { var version: Int64; var seq: Int64; var blob: String }
    /// The record names pushes asked the server to alert for, in order.
    var alerts: [String] = []
    var alertIDs: [String] = []
    var withdrawals: [String] = []
    /// Pushes taken in, by device.
    var pushes: [String: Int] = [:]
    final class Socket: Line {
        let server: MemoryServer, account: String, device: String
        let received: (String) -> Void, closed: (Int?) -> Void
        var helloed = false
        init(_ server: MemoryServer, _ account: String, _ device: String, _ received: @escaping (String) -> Void, _ closed: @escaping (Int?) -> Void) {
            self.server = server; self.account = account; self.device = device; self.received = received; self.closed = closed
        }
        func send(_ text: String) { server.message(self, text) }
        func close() {
            server.lock.lock(); server.sockets.removeAll { $0 === self }; let goodbye = server.goodbyes; server.lock.unlock()
            // As URLSession does: the close comes back as the socket's end.
            if goodbye { DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { self.closed(1000) } }
        }
    }

    let lock = NSRecursiveLock()
    var records: [String: [String: Item]] = [:]
    var seq: [String: Int64] = [:]
    var verifier: [String: String] = [:]
    var tokens: [String: (account: String, device: String)] = [:]
    var revoked = Set<String>()
    var sockets: [Socket] = []
    var hold = false
    /// Closed sockets call back as real ones do.
    var goodbyes = false
    private var held: [(Socket, String)] = []
    /// A socket's largest message, as URLSession and Cloudflare have one:
    /// a message past it ends the line. How many did, and the largest seen.
    var limit: Int?
    var tooBig = 0
    /// An account's room in base64 bytes, as the Worker's MAX_ACCOUNT:
    /// a change that would grow past it is rejected `full`.
    var capacity: Int?
    var largest = 0

    func socketCount(_ device: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sockets.filter { $0.device == device }.count
    }

    var everything: String {
        lock.lock(); defer { lock.unlock() }
        return records.values.flatMap(\.values).map(\.blob).compactMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }.joined()
    }

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        lock.lock()
        let parts = request.url!.path.split(separator: "/").map(String.init)
        var status = 404, body: [String: Any] = [:]
        if request.httpMethod == "POST", parts.count == 4, parts[3] == "devices",
           let json = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           let secret = json["secret"] as? String, let device = (json["device"] as? [String: Any])?["id"] as? String {
            let account = parts[2]
            if revoked.contains(device) { status = 403; body = ["error": "revoked"] }
            else if let known = verifier[account], known != secret { status = 403; body = ["error": "secret"] }
            else {
                verifier[account] = secret
                let token = UUID().uuidString
                tokens[token] = (account, device)
                status = 200; body = ["token": token]
            }
        }
        lock.unlock()
        DispatchQueue.global().async { done(status, try? JSONSerialization.data(withJSONObject: body)) }
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
        lock.lock(); defer { lock.unlock() }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let account = request.url!.path.split(separator: "/").map(String.init)[2]
        guard let who = tokens[token], who.account == account, !revoked.contains(who.device) else {
            let dead = Socket(self, account, "", received, closed)
            DispatchQueue.global().async { closed(401) }
            return dead
        }
        let socket = Socket(self, account, who.device, received, closed)
        sockets.append(socket)
        return socket
    }

    func revoke(_ device: String) {
        lock.lock()
        revoked.insert(device)
        let going = sockets.filter { $0.device == device }
        sockets.removeAll { $0.device == device }
        lock.unlock()
        for socket in going { DispatchQueue.global().async { socket.closed(4003) } }
    }

    func release() {
        lock.lock(); let waiting = held; held = []; lock.unlock()
        for (socket, text) in waiting { message(socket, text) }
    }

    /// Ended for a message past the limit, as a socket ends.
    private func tooLarge(_ text: String, _ socket: Socket) -> Bool {
        largest = max(largest, text.utf8.count)
        guard let limit, text.utf8.count > limit else { return false }
        tooBig += 1
        sockets.removeAll { $0 === socket }
        DispatchQueue.global().async { socket.closed(1009) }
        return true
    }

    fileprivate func message(_ socket: Socket, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        if tooLarge(text, socket) { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = json["t"] as? String else { return }
        if hold, socket.device == "b", type == "push" { held.append((socket, text)); return }
        let account = socket.account
        switch type {
        case "hello":
            socket.helloed = true
            let after = (json["cursor"] as? NSNumber)?.int64Value ?? 0
            let items = (records[account] ?? [:]).filter { $0.value.seq > after }.sorted { $0.value.seq < $1.value.seq }
                .map { ["name": $0.key, "version": $0.value.version, "seq": $0.value.seq, "blob": $0.value.blob] as [String: Any] }
            reply(socket, ["t": "changes", "items": items, "cursor": seq[account] ?? 0, "more": false])
        case "push":
            pushes[socket.device, default: 0] += 1
            if let alert = json["alert"] as? String { alerts.append(alert) }
            if let id = json["alertID"] as? String {
                if json["withdraw"] as? Bool == true { withdrawals.append(id) } else { alertIDs.append(id) }
            }
            var accepted: [[String: Any]] = [], conflicts: [[String: Any]] = [], broadcast: [[String: Any]] = []
            var rejected: [[String: Any]] = []
            for change in json["changes"] as? [[String: Any]] ?? [] {
                guard let name = change["name"] as? String, let blob = change["blob"] as? String else { continue }
                let base = (change["base"] as? NSNumber)?.int64Value ?? 0
                let have = records[account]?[name]
                let bytes = (records[account] ?? [:]).values.reduce(0) { $0 + $1.blob.utf8.count }
                if (have?.version ?? 0) == base, let capacity,
                   bytes - (have?.blob.utf8.count ?? 0) + blob.utf8.count > capacity {
                    rejected.append(["name": name, "code": "full"])
                } else if (have?.version ?? 0) == base {
                    let next = (seq[account] ?? 0) + 1
                    seq[account] = next
                    let item = Item(version: base + 1, seq: next, blob: blob)
                    records[account, default: [:]][name] = item
                    accepted.append(["name": name, "version": item.version, "seq": next])
                    broadcast.append(["name": name, "version": item.version, "seq": next, "blob": blob])
                } else {
                    conflicts.append(["name": name, "version": have?.version ?? 0, "blob": have?.blob ?? NSNull()])
                }
            }
            if !broadcast.isEmpty {
                for other in sockets where other !== socket && other.account == account && other.helloed {
                    reply(other, ["t": "changes", "items": broadcast, "cursor": seq[account] ?? 0, "more": false])
                }
            }
            if !rejected.isEmpty { reply(socket, ["t": "error", "code": "full", "message": "full", "id": json["id"] ?? ""]) }
            var pushed: [String: Any] = ["t": "pushed", "id": json["id"] ?? "", "accepted": accepted, "conflicts": conflicts]
            if !rejected.isEmpty { pushed["rejected"] = rejected }
            reply(socket, pushed)
        default:
            break
        }
    }

    private func reply(_ socket: Socket, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        if tooLarge(text, socket) { return }
        // In order, off the caller's lock, as a socket would.
        serial.async { socket.received(text) }
    }

    private let serial = DispatchQueue(label: "memory.server")
}

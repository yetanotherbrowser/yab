import Foundation
import SyncKit
@testable import YabPhone

/// Protocol v1 in memory, the way sync-server speaks it (docs/sync.md):
/// accounts by their address, devices with tokens and `lastSeen`, a socket
/// per device with hello, push, changes and presence relayed. The Worker
/// itself is tested in sync-server/; the real thing end to end in
/// Phone/tools/sync-e2e.
final class SyncMemoryServer: Transport, @unchecked Sendable {
    struct Item { var version: Int64; var seq: Int64; var blob: String }
    struct Device { var id: String; var name: String; var model: String; var lastSeen: Double?; var revoked = false }

    final class Socket: Line, @unchecked Sendable {
        let server: SyncMemoryServer, account: String, device: String
        let received: (String) -> Void, closed: (Int?) -> Void
        var helloed = false
        init(_ server: SyncMemoryServer, _ account: String, _ device: String, _ received: @escaping (String) -> Void, _ closed: @escaping (Int?) -> Void) {
            self.server = server; self.account = account; self.device = device; self.received = received; self.closed = closed
        }
        func send(_ text: String) { server.message(self, text) }
        func close() {
            server.lock.lock(); server.sockets.removeAll { $0 === self }; server.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { self.closed(1000) }
        }
    }

    let lock = NSRecursiveLock()
    var records: [String: [String: Item]] = [:]
    var seq: [String: Int64] = [:]
    var verifier: [String: String] = [:]
    var tokens: [String: (account: String, device: String)] = [:]
    var devices: [String: [String: Device]] = [:]
    var sockets: [Socket] = []
    /// Each device's last presence, as the Worker keeps it (R9).
    var presence: [String: [String: String]] = [:]
    /// Where each device's silent pushes go (R2): its APNs token.
    var pushTokens: [String: String] = [:]
    /// Held: "pushed" answers wait until let go (a change in flight).
    var holdsPushes = false
    private var held: [() -> Void] = []
    /// Off: every request and socket fails, as with no network.
    var down = false
    private let serial = DispatchQueue(label: "phone.memory.server")

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        lock.lock()
        let parts = request.url!.path.split(separator: "/").map(String.init)
        var status: Int? = 404, body: [String: Any] = [:]
        if down {
            status = nil
        } else if request.httpMethod == "POST", parts.count == 4, parts[3] == "devices",
                  let json = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let secret = json["secret"] as? String, let device = json["device"] as? [String: Any], let id = device["id"] as? String {
            let account = parts[2]
            if devices[account]?[id]?.revoked == true { status = 403; body = ["error": "revoked"] }
            else if let known = verifier[account], known != secret { status = 403; body = ["error": "secret"] }
            else {
                verifier[account] = secret
                let token = UUID().uuidString
                tokens[token] = (account, id)
                devices[account, default: [:]][id] = Device(id: id, name: device["name"] as? String ?? "", model: device["model"] as? String ?? "",
                                                            lastSeen: Date().timeIntervalSince1970 * 1000)
                status = 200; body = ["token": token]
            }
        } else if request.httpMethod == "GET", parts.count == 4, parts[3] == "devices" {
            let list = (devices[parts[2]] ?? [:]).values.sorted { $0.id < $1.id }.map { d -> [String: Any] in
                var item: [String: Any] = ["id": d.id, "name": d.name, "model": d.model, "revoked": d.revoked]
                if let seen = d.lastSeen { item["lastSeen"] = seen }
                return item
            }
            status = 200; body = ["devices": list]
        } else if request.httpMethod == "PUT", parts.count == 6, parts[3] == "devices", parts[5] == "push",
                  let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: ""),
                  let who = tokens[token], who.account == parts[2], who.device == parts[4],
                  let json = request.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let push = json["token"] as? String {
            pushTokens[who.device] = push
            status = 204
        }
        lock.unlock()
        DispatchQueue.global().async { done(status, try? JSONSerialization.data(withJSONObject: body)) }
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
        lock.lock(); defer { lock.unlock() }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let account = request.url!.path.split(separator: "/").map(String.init)[2]
        guard !down, let who = tokens[token], who.account == account, devices[account]?[who.device]?.revoked != true else {
            let dead = Socket(self, account, "", received, closed)
            DispatchQueue.global().async { closed(self.down ? nil : 401) }
            return dead
        }
        let socket = Socket(self, account, who.device, received, closed)
        sockets.append(socket)
        return socket
    }

    /// The network goes: every socket drops.
    func cut() {
        lock.lock()
        down = true
        let going = sockets
        sockets = []
        lock.unlock()
        for socket in going { DispatchQueue.global().async { socket.closed(nil) } }
    }

    func revoke(_ device: String) {
        lock.lock()
        for account in devices.keys where devices[account]?[device] != nil { devices[account]?[device]?.revoked = true }
        let going = sockets.filter { $0.device == device }
        sockets.removeAll { $0.device == device }
        lock.unlock()
        for socket in going { DispatchQueue.global().async { socket.closed(4003) } }
    }

    fileprivate func message(_ socket: Socket, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        // A refused upgrade cannot deliver a frame. Match the real server
        // even when the sender queues a push before the close callback.
        guard !down, sockets.contains(where: { $0 === socket }),
              devices[socket.account]?[socket.device]?.revoked != true else { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = json["t"] as? String else { return }
        let account = socket.account
        devices[account]?[socket.device]?.lastSeen = Date().timeIntervalSince1970 * 1000
        switch type {
        case "hello":
            socket.helloed = true
            let after = (json["cursor"] as? NSNumber)?.int64Value ?? 0
            let items = (records[account] ?? [:]).filter { $0.value.seq > after }.sorted { $0.value.seq < $1.value.seq }
                .map { ["name": $0.key, "version": $0.value.version, "seq": $0.value.seq, "blob": $0.value.blob] as [String: Any] }
            // In batches of 500, as the Worker sends a catch-up.
            var start = 0
            repeat {
                let batch = Array(items[start..<min(items.count, start + 500)])
                start += 500
                let more = start < items.count
                let cursor = more ? (batch.last?["seq"] as? Int64 ?? 0) : (seq[account] ?? 0)
                reply(socket, ["t": "changes", "items": batch, "cursor": cursor, "more": more])
            } while start < items.count
            // The others' last presence, right after the catch-up (R9).
            for (device, blob) in (presence[account] ?? [:]).sorted(by: { $0.key < $1.key }) where device != socket.device {
                reply(socket, ["t": "presence", "device": device, "blob": blob])
            }
        case "push":
            var accepted: [[String: Any]] = [], conflicts: [[String: Any]] = [], broadcast: [[String: Any]] = []
            for change in json["changes"] as? [[String: Any]] ?? [] {
                guard let name = change["name"] as? String, let blob = change["blob"] as? String else { continue }
                let base = (change["base"] as? NSNumber)?.int64Value ?? 0
                let have = records[account]?[name]
                if (have?.version ?? 0) == base {
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
            let answer: [String: Any] = ["t": "pushed", "id": json["id"] ?? "", "accepted": accepted, "conflicts": conflicts]
            if holdsPushes { held.append { [weak self] in self?.reply(socket, answer) } } else { reply(socket, answer) }
        case "presence":
            guard let blob = json["blob"] as? String else { return }
            presence[account, default: [:]][socket.device] = blob
            for other in sockets where other !== socket && other.account == account && other.helloed {
                reply(other, ["t": "presence", "device": socket.device, "blob": blob])
            }
        default:
            break
        }
    }

    /// The held "pushed" answers go out.
    func letPushesGo() {
        lock.lock()
        holdsPushes = false
        let going = held
        held = []
        lock.unlock()
        for answer in going { answer() }
    }

    private func reply(_ socket: Socket, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        serial.async { socket.received(text) }
    }
}

/// A Mac of the account for the tests: SyncKit's client and journal, writing
/// rows the way SyncShapes does (the records' fields as SyncRecords.swift
/// ports them, checked byte for byte by Phone/SyncCheck).
final class TestMac: @unchecked Sendable {
    let client: SyncClient
    let journal: Journal
    var front: (url: String, title: String, tab: String)?
    var asleep = false

    init(server: SyncMemoryServer, seal: Seal, id: String = "mac-a", agentSelection: Bool = true) throws {
        SyncCollection.register()
        journal = try Journal(path: nil, device: id)
        if agentSelection {
            try journal.change(.init(collection: OpenOnMac.capability, id: id),
                               ["device": .string(id), "chatAgent": .number(Double(ChatAgent.version))])
        }
        client = SyncClient(base: URL(string: "https://sync.test")!, journal: journal, seal: seal,
                            device: .init(id: id, name: "MacBook Pro", model: "Mac16,1"), transport: server)
        client.presence = { [weak self] in
            var fields: [String: Value] = ["name": "MacBook Pro", "at": .number(Date().timeIntervalSince1970)]
            if let front = self?.front { fields["url"] = .string(front.url); fields["title"] = .string(front.title); fields["tab"] = .string(front.tab) }
            if self?.asleep == true { fields["asleep"] = true }
            return Record(collection: "presence", id: id, fields: fields)
        }
    }

    func write(_ collection: String, _ id: String, _ fields: SyncFields) throws {
        try journal.change(.init(collection: collection, id: id), fields)
        client.kick()
    }

    func remove(_ id: String) throws {
        try journal.remove(.init(collection: SyncCollection.tab, id: id))
        client.kick()
    }

    /// The Mac's row of a space, as its SyncShapes.row would read it.
    func row(_ space: String) -> SyncRow {
        SyncRow(space: space, tabs: journal.living(SyncCollection.tab), folders: journal.living(SyncCollection.folder),
                pairs: journal.living(SyncCollection.pair))
    }

    var pending: Int { journal.pending(limit: 10_000).count }
}

import Foundation
import SyncKit

/// A single sign-in's authority in the extension's private Keychain group.
/// The phone's Sync and iCloud groups are never granted to the extension.
struct SharedLinkSyncAccess: Sendable {
    struct Session: Codable, Equatable, Sendable {
        var id = UUID()
        var key: Data
        var token: String
        var device: String
        var seal: Seal? { Seal(raw: key) }
    }

    let secrets: SharedLinkSecrets

    static var standard: Self {
        Self(secrets: .standard)
    }

    var session: Session? {
        secrets.read("sync-session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    @discardableResult
    func grant(seal: Seal, token: String, device: String) -> Session? {
        guard !token.isEmpty, !device.isEmpty else { return nil }
        if let old = session, old.key == seal.raw, old.token == token, old.device == device { return old }
        let next = Session(key: seal.raw, token: token, device: device)
        guard let data = try? JSONEncoder().encode(next), secrets.write(data, "sync-session") else { return nil }
        return next
    }

    func revoke() {
        secrets.remove("sync-session")
    }

    /// Read immediately before each open or send, including conflict replies.
    /// An upload already sent cannot be recalled; a cached session grants no
    /// authority for a new attempt after sign-out or a later sign-in.
    func whileAuthorized(_ session: Session, perform action: () -> Void) -> Bool {
        guard self.session == session else { return false }
        action()
        return true
    }
}

/// A small snapshot of the last ordinary space. Credentials stay in the
/// keychain; the extension never opens the app's live journal.
struct SharedLinkSyncContext: Codable {
    var account: String
    var device: String
    var base: URL
    var space: String
    var tabs: [Record]
    var lastOrder: String?

    static func file(for queue: SharedLinkQueue) -> URL? {
        queue.folder?.deletingLastPathComponent().appendingPathComponent("share-sync.json")
    }

    static func read(for queue: SharedLinkQueue) -> Self? {
        guard let file = file(for: queue), let data = try? Data(contentsOf: file) else { return nil }
        // Discard the unencrypted snapshot from earlier development builds.
        guard SharedLinkProtection.isSealed(data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return queue.protection?.open(data, purpose: "yab.shared.context.v1")
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(for queue: SharedLinkQueue) throws {
        guard let file = Self.file(for: queue) else { throw CocoaError(.fileWriteNoPermission) }
        if let old = try? Data(contentsOf: file), !SharedLinkProtection.isSealed(old) {
            try FileManager.default.removeItem(at: file)
        }
        guard let protection = queue.protection else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try protection.seal(JSONEncoder().encode(self), purpose: "yab.shared.context.v1")
        try data.write(to: file, options: .atomic)
    }

    /// Kept links use the same URL rules as SharedItems. Text-only shares
    /// still open the app, where the chosen search engine resolves them.
    func prepare(_ link: SharedLink, pending: [SharedLink]) throws -> SharedLink {
        guard link.action == .keep, !link.search,
              let url = URL(string: link.address.contains("://") ? link.address : "https://" + link.address),
              SharedItems.isWeb(url), url.host != nil else { return link }
        SyncCollection.register()
        let waiting = pending.compactMap(SharedLinkSyncRecord.read).filter { $0.account == account }.map(\.record)
        let existing = (Array(waiting.reversed()) + tabs).first {
            $0.alive() && $0["parent"]?.string == space && $0["url"]?.string == url.absoluteString
        }
        let journal = try Journal(path: nil, device: device)
        var record: Record
        if let existing, let tab = SyncTab(existing) {
            _ = try journal.receive([(existing, 0)])
            // A pin or a kept tab stays where it already is.
            record = tab.list == .today
                ? try journal.change(existing.key, ["kept": true, "device": .null, "folder": .null,
                                                   "order": .string(Order.between(lastOrder, nil))])
                : existing
        } else {
            let end = ([lastOrder].compactMap { $0 } + waiting.filter { $0["parent"]?.string == space }.compactMap { $0["order"]?.string }).max()
            let tab = SyncTab(space: space, order: Order.between(end, nil), url: url.absoluteString,
                              title: link.title ?? url.host ?? link.address,
                              seen: SyncTab.round(seen: link.date.timeIntervalSince1970), kept: true)
            record = try journal.change(.init(collection: SyncCollection.tab, id: tab.id), tab.fields)
        }
        var prepared = link
        prepared.sync = try JSONEncoder().encode(SharedLinkSyncRecord(account: account, record: record))
        return prepared
    }
}

struct SharedLinkSyncRecord: Codable {
    var account: String
    var record: Record

    static func read(_ link: SharedLink) -> Self? {
        guard link.action == .keep, let data = link.sync,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.record.collection == SyncCollection.tab, UUID(uuidString: value.record.id) != nil else { return nil }
        return value
    }
}

/// Upload one saved record over the existing sync protocol. No hello is
/// needed for a push, so sharing does not download the account's history.
/// The sheet stays alive until acknowledgment or a short timeout. The
/// queue remains the durable fallback in either case.
final class SharedLinkUpload: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phone.share-sync")
    private let transport: any Transport
    private let seal: Seal
    private let access: SharedLinkSyncAccess
    private let session: SharedLinkSyncAccess.Session
    private var record: Record
    private var line: (any Line)?
    private var completion: ((Bool) -> Void)?
    private var timeout: DispatchWorkItem?
    private var requestID = 0

    init?(record: Record, access: SharedLinkSyncAccess, session: SharedLinkSyncAccess.Session, transport: any Transport = WebTransport()) {
        guard let seal = session.seal else { return nil }
        self.record = record
        self.seal = seal
        self.access = access
        self.session = session
        self.transport = transport
    }

    deinit {
        timeout?.cancel()
        line?.close()
    }

    func start(base: URL, within seconds: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            self.completion = completion
            var parts = URLComponents(url: base.appendingPathComponent("v1/accounts/\(seal.account)/socket"), resolvingAgainstBaseURL: false)
            parts?.scheme = base.scheme == "http" ? "ws" : "wss"
            guard let url = parts?.url else { return finish(false) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            request.setValue(String(AndroidSyncCompatibility.version), forHTTPHeaderField: "X-Yab-Android-Sync")
            guard access.whileAuthorized(session, perform: {
                line = transport.open(request, received: { [weak self] text in
                    self?.queue.async { self?.received(text) }
                }, closed: { [weak self] _ in
                    self?.queue.async { self?.finish(false) }
                })
            }) else { return finish(false) }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(false) }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
            send(version: 0)
        }
    }

    func cancel() { queue.async { [self] in finish(false) } }

    private func send(version: Int64) {
        do {
            requestID += 1
            let change: [String: Any] = ["name": seal.name(record.key), "base": version,
                                         "blob": try seal.seal(record).base64EncodedString()]
            let data = try JSONSerialization.data(withJSONObject: ["t": "push", "id": "share-\(requestID)", "changes": [change]])
            guard access.whileAuthorized(session, perform: {
                line?.send(String(decoding: data, as: UTF8.self))
            }) else { return finish(false) }
        } catch { finish(false) }
    }

    private func received(_ text: String) {
        guard completion != nil, let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["t"] as? String == "error" { return finish(false) }
        guard message["t"] as? String == "pushed", message["id"] as? String == "share-\(requestID)" else { return }
        let name = seal.name(record.key)
        if (message["accepted"] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == name }) {
            return finish(true)
        }
        if let conflict = (message["conflicts"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
           let version = (conflict["version"] as? NSNumber)?.int64Value,
           let blob = conflict["blob"] as? String, let data = Data(base64Encoded: blob),
           let remote = try? seal.open(data, name: name) {
            record = record.merged(with: remote)
            if record == remote { return finish(true) }
            return send(version: version)
        }
        finish(false)
    }

    private func finish(_ success: Bool) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        line?.close()
        line = nil
        completion(success)
    }
}

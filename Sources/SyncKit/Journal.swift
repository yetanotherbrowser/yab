import CryptoKit
import Foundation
import SQLite3

// This device's copy of everything that syncs, in `sync.sqlite`: each record
// as it stands, whether it has changes the server hasn't taken yet, the
// server's version of it, and how far into the server's changes this device
// has read. Yab's own files stay what they are; a mirror tells the journal
// what they say now (`reconcile`) and hears back what came from elsewhere
// (`receive`).

public final class Journal: @unchecked Sendable {
    public let clock: Clock
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "sync.journal")

    public enum Failure: Error { case open(String), sql(String) }

    /// `path` nil keeps it in memory, for tests.
    public init(path: String?, device: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path ?? ":memory:", &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close(db)
            throw Failure.open(message)
        }
        self.db = db
        // A second journal on the same file (an iPhone woken in the back by
        // a push still writing as the app's own opens) waits its turn
        // instead of failing.
        sqlite3_busy_timeout(db, 5000)
        for sql in [
            "PRAGMA journal_mode = WAL",
            "PRAGMA synchronous = NORMAL",
            """
            CREATE TABLE IF NOT EXISTS records (
              collection TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL,
              dirty INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (collection, id))
            """,
            "CREATE INDEX IF NOT EXISTS records_dirty ON records(dirty) WHERE dirty = 1",
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            // What this device's own files last said of a record, for the
            // collections reconciled with `shown` (reconcile): the base a
            // difference is measured from, so a file that hasn't taken in
            // what came from elsewhere yet is no edit made here.
            """
            CREATE TABLE IF NOT EXISTS shown (
              collection TEXT NOT NULL, id TEXT NOT NULL, fields BLOB NOT NULL,
              PRIMARY KEY (collection, id))
            """,
        ] {
            try Journal.exec(db, sql)
        }
        var last: Stamp?
        if let text = Journal.meta(db, "clock"), let data = text.data(using: .utf8) {
            last = try? JSONDecoder().decode(Stamp.self, from: data)
        }
        clock = Clock(device: device, last: last)
    }

    deinit { sqlite3_close(db) }

    // MARK: Reading

    public func record(_ key: Record.Key) -> Record? {
        queue.sync { load(key)?.record }
    }

    /// Every record of a collection, removed ones included.
    public func all(_ collection: String) -> [Record] {
        queue.sync {
            rows("SELECT body FROM records WHERE collection = ? ORDER BY id", [collection]).compactMap { decode($0[0]) }
        }
    }

    /// The records of a collection that are there.
    public func living(_ collection: String) -> [Record] {
        let kind = Kind.of(collection)
        return all(collection).filter { $0.alive(kind) }
    }

    /// Changes made here that the server hasn't taken, with the version of
    /// each that this device last had from it.
    public func pending(limit: Int = 500, excluding collections: Set<String> = []) -> [(record: Record, version: Int64)] {
        queue.sync {
            let excluded = collections.sorted()
            let clause = excluded.isEmpty ? "" : " AND collection NOT IN (" + excluded.map { _ in "?" }.joined(separator: ",") + ")"
            let values: [Any] = excluded.map { $0 as Any } + [Int64(limit)]
            return rows("SELECT body, version FROM records WHERE dirty = 1\(clause) ORDER BY collection, id LIMIT ?", values).compactMap { row in
                decode(row[0]).map { ($0, (row[1] as? Int64) ?? 0) }
            }
        }
    }

    /// How many changes made here the server hasn't taken: counted, no
    /// record read (an iPhone shows the number while they go up).
    public var pendingCount: Int {
        queue.sync {
            (rows("SELECT COUNT(*) FROM records WHERE dirty = 1", []).first?.first as? Int64).map(Int.init) ?? 0
        }
    }

    public var cursor: Int64 {
        get { queue.sync { Journal.meta(db, "cursor").flatMap(Int64.init) ?? 0 } }
        set { queue.sync { setMeta("cursor", String(newValue)) } }
    }

    // MARK: Local changes

    /// Makes the journal's `collection` say `now`, by id: records whose
    /// fields differ get new stamps, ids missing from `now` are removed.
    /// Returns the keys that changed. A mirror calls this after its own
    /// file was written; what came from elsewhere was already applied and
    /// changes nothing, so nothing echoes back.
    ///
    /// `within`: only records it holds can be removed for missing, so a
    /// collection can be told about in parts (one chat's items).
    /// `blank`: a removal also empties every field, under the removal's
    /// stamp, so the record kept for good on the server carries nothing
    /// of what it held (a plugin's parts, its state).
    /// `under`: only records whose ids begin with one of these are read,
    /// and only they can be removed for missing; the rest of the collection
    /// isn't even decoded (one chat's steps, `chat/…`, among every chat's).
    /// An id in `now` outside them is read on its own.
    ///
    /// `shown`: a three-way reconcile, as Chromium's sync takes only what the
    /// person did as a local change, never a difference from the merged
    /// state. Each record's fields as these files last said them are kept
    /// (`shown` table); a field goes up only when the files changed it since,
    /// and a record missing from them is removed only when they had it.
    /// Files that haven't taken in what came from elsewhere (a catch-up
    /// page whose rows aren't drawn yet, a relaunch between a page and its
    /// rows, a Mac back after weeks) are then no edit, and their old values
    /// can't win by a stamp of now (register 2589). Until a collection was
    /// once reconciled this way, the journal stands in for what was shown.
    /// `orphaned`: records missing from `now` removed though the files never
    /// held them.
    /// `revive`: with `shown`, a record removed elsewhere that the files
    /// still hold unchanged comes back when this says so (given the record
    /// and what the files say); otherwise it stays removed.
    @discardableResult
    public func reconcile(_ collection: String, _ now: [String: [String: Value]], within: ((Record) -> Bool)? = nil,
                          under: Set<String>? = nil, blank: Bool = false, shown: Bool = false,
                          orphaned: ((Record) -> Bool)? = nil,
                          revive: ((Record, [String: Value]) -> Bool)? = nil) throws -> [Record.Key] {
        try queue.sync {
            let kind = Kind.of(collection)
            var changed: [Record.Key] = []
            let startedKey = "shown." + collection
            let started = shown && Journal.meta(db, startedKey) != nil
            let base = started ? loadShown(collection) : [:]
            try transaction {
                var have: [String: (Record, Int64)] = [:]
                func read(_ sql: String, _ values: [Any]) {
                    for row in rows(sql, values) {
                        if let record = decode(row[0]) { have[record.id] = (record, (row[1] as? Int64) ?? 0) }
                    }
                }
                if let under {
                    // Every id that begins with the prefix sorts between it
                    // and it followed by the last character there is.
                    for prefix in under.sorted() {
                        read("SELECT body, version FROM records WHERE collection = ? AND id >= ? AND id < ?",
                             [collection, prefix, prefix + "\u{10FFFF}"])
                    }
                    for id in now.keys where have[id] == nil && !under.contains(where: { id.hasPrefix($0) }) {
                        read("SELECT body, version FROM records WHERE collection = ? AND id = ?", [collection, id])
                    }
                } else {
                    read("SELECT body, version FROM records WHERE collection = ?", [collection])
                }
                for (id, fields) in now {
                    var record = have[id]?.0 ?? Record(collection: collection, id: id)
                    var want = fields
                    if started, let had = have[id]?.0, let was = base[id] {
                        // Only what the files changed since they last said
                        // `was`, over the record as it stands. One removed
                        // elsewhere comes back with all the files say: its
                        // fields went with the removal.
                        let edits = Journal.edits(fields, since: was)
                        if edits.isEmpty, had.alive(kind) || !(revive?(had, fields) ?? false) { continue }
                        if had.alive(kind) {
                            want = had.visible
                            for (name, value) in edits { want[name] = value }
                        }
                    }
                    if record.update(to: want, clock: clock, kind: kind) {
                        try save(record, dirty: true, version: have[id]?.1)
                        changed.append(record.key)
                    }
                }
                for (id, (record, version)) in have where now[id] == nil && record.alive(kind) && (within?(record) ?? true) {
                    // Never in these files: nothing here took it out.
                    // Unless what it was in is gone (`orphaned`: its space
                    // removed), which takes it whoever held it.
                    if started && base[id] == nil && !(orphaned?(record) ?? false) { continue }
                    var gone = record
                    let stamp = clock.tick()
                    if blank {
                        for name in gone.fields.keys where !(gone.fields[name]?.isNull ?? true) { gone.set(name, .null, at: stamp) }
                    }
                    gone.remove(at: stamp)
                    try save(gone, dirty: true, version: version)
                    changed.append(gone.key)
                }
                if shown {
                    // What the files say now is the next base. One they no
                    // longer hold leaves it, but not one kept out of their
                    // reach (`within`): another device's, a space not come.
                    for (id, fields) in now where base[id] != fields {
                        try run("INSERT INTO shown (collection, id, fields) VALUES (?, ?, ?) ON CONFLICT (collection, id) DO UPDATE SET fields = excluded.fields",
                                [collection, id, try JSONEncoder().encode(fields)])
                    }
                    for id in base.keys where now[id] == nil && (have[id].map { within?($0.0) ?? true } ?? true) {
                        try run("DELETE FROM shown WHERE collection = ? AND id = ?", [collection, id])
                    }
                    if !started { setMeta(startedKey, "1") }
                }
                // The clock moves only with a change: a reconcile that
                // changed nothing writes nothing.
                if !changed.isEmpty { persistClock() }
            }
            return changed.sorted()
        }
    }

    /// The fields the files changed since they said `was`: a new value, or
    /// null for one they no longer have.
    static func edits(_ now: [String: Value], since was: [String: Value]) -> [String: Value] {
        var out: [String: Value] = [:]
        for name in Set(now.keys).union(was.keys) {
            let a = now[name] ?? .null, b = was[name] ?? .null
            if a != b { out[name] = a }
        }
        return out
    }

    /// Each record of `collection` as this device's files last said it
    /// (reconcile's `shown`), by id.
    public func shown(_ collection: String) -> [String: [String: Value]] {
        queue.sync { loadShown(collection) }
    }

    private func loadShown(_ collection: String) -> [String: [String: Value]] {
        var out: [String: [String: Value]] = [:]
        for row in rows("SELECT id, fields FROM shown WHERE collection = ?", [collection]) {
            guard let id = row[0] as? String, let data = row[1] as? Data,
                  let fields = try? JSONDecoder().decode([String: Value].self, from: data) else { continue }
            out[id] = fields
        }
        return out
    }

    /// Records the files haven't drawn as the journal has them: one there
    /// they never held, one removed they still hold, or one whose place or
    /// pin moved since. Empty until the collection is reconciled with
    /// `shown`. A relaunch between a page and its rows leaves such records,
    /// and no delivery names them again (the server's copy is the same).
    public func unshown(_ collection: String) -> [Record] {
        queue.sync {
            guard Journal.meta(db, "shown." + collection) != nil else { return [] }
            let kind = Kind.of(collection)
            let base = loadShown(collection)
            let watched = Set(kind.groups.joined()).union(["pin", "folder"])
            return rows("SELECT body FROM records WHERE collection = ? ORDER BY id", [collection]).compactMap { decode($0[0]) }.filter { record in
                guard let was = base[record.id] else { return record.alive(kind) }
                guard record.alive(kind) else { return true }
                let visible = record.visible
                return watched.contains { (visible[$0] ?? .null) != (was[$0] ?? .null) }
            }
        }
    }

    /// Removed records of `collection` that still carry their words get
    /// them cleared, so the server stops counting them against the
    /// account (a chat's steps, removed as new ones push them out, held
    /// 35 MB of a full account's 50). Returns how many were cleared.
    @discardableResult
    public func blankRemoved(_ collection: String) throws -> Int {
        try queue.sync {
            let kind = Kind.of(collection)
            var count = 0
            try transaction {
                for row in rows("SELECT body, version FROM records WHERE collection = ?", [collection]) {
                    guard var record = decode(row[0]), record.deleted != nil, !record.alive(kind),
                          record.fields.values.contains(where: { !$0.isNull }) else { continue }
                    let stamp = clock.tick()
                    for name in record.fields.keys where !(record.fields[name]?.isNull ?? true) { record.set(name, .null, at: stamp) }
                    record.remove(at: stamp)
                    try save(record, dirty: true, version: (row[1] as? Int64) ?? 0)
                    count += 1
                }
                if count > 0 { persistClock() }
            }
            return count
        }
    }

    /// Changes one record here: `fields` merged over what it has.
    @discardableResult
    public func change(_ key: Record.Key, _ fields: [String: Value]) throws -> Record {
        try queue.sync {
            let kind = Kind.of(key.collection)
            let had = load(key)
            var record = had?.record ?? Record(collection: key.collection, id: key.id)
            var want = record.visible
            for (name, value) in fields { want[name] = value }
            if record.update(to: want, clock: clock, kind: kind) {
                try save(record, dirty: true, version: had?.version)
                persistClock()
            }
            return record
        }
    }

    /// Claims one command before its external effect. The receipt stays local
    /// in this account's journal, so a replay or a restart cannot run it twice.
    /// A crash after claiming is reported as interrupted, never retried silently.
    @discardableResult
    public func claimCommand(_ command: Record, fields: [String: Value]) throws -> Bool {
        try queue.sync {
            let key = command.key
            let receipt = "command/" + (try JSONEncoder().encode([key.collection, key.id])).base64EncodedString()
            var claimed = false
            try transaction {
                guard Journal.meta(db, receipt) == nil, let had = load(key),
                      had.record.alive(), had.record["state"] == nil, had.record.visible == command.visible else { return }
                var record = had.record
                var want = record.visible
                for (name, value) in fields { want[name] = value }
                _ = record.update(to: want, clock: clock, kind: Kind.of(key.collection))
                try save(record, dirty: true, version: had.version)
                try run("INSERT INTO meta (key, value) VALUES (?, ?)", [receipt, "claimed"])
                persistClock()
                claimed = true
            }
            return claimed
        }
    }

    // MARK: Local chat command receipts

    public enum ChatClaim: Equatable { case claimed(Record), alreadyClaimed, stale }
    public enum ChatRefusal: Error { case missingReceipt }

    /// Shares the command ID namespace with Open on Mac, without changing its
    /// consumer. A rewrite cannot turn an attempted chat into another effect.
    public func claimChatCommand(_ command: Record, account: String, device: String) throws -> ChatClaim {
        try queue.sync {
            try chatContext(account: account, device: device)
            guard command.collection == "send", command["device"]?.string == device,
                  !command.id.isEmpty, command.id.utf8.count <= 4096 else { throw Failure.sql("Chat request scope unavailable") }
            var result = ChatClaim.stale
            try chatTransaction {
                try bindChatAccount(account, device: device)
                let receipt = try commandReceipt(command.key)
                if try chatMeta(receipt) != nil { result = .alreadyClaimed; return }
                guard let had = try chatLoad(command.key), had.record.alive(), had.record["state"] == nil,
                      had.record.visible == command.visible else { return }
                var claimed = had.record
                var fields = claimed.visible
                fields["state"] = "processing"
                _ = claimed.update(to: fields, clock: clock, kind: Kind.of(command.collection))
                try chatSave(claimed, version: had.version)
                guard try chatRun("INSERT INTO meta (key, value) VALUES (?, ?)", [receipt, "chat-claimed/v1"]) == 1,
                      try chatMeta(receipt) == "chat-claimed/v1" else { throw Failure.sql("Chat receipt not saved") }
                try chatClock()
                result = .claimed(claimed)
            }
            return result
        }
    }

    /// A checked final write cannot remove the receipt or overwrite a newer
    /// payload/terminal outcome. Failure leaves the attempt consumed.
    public func finishChatCommand(_ expected: Record, account: String, device: String, fields: [String: Value]) throws {
        try queue.sync {
            try chatContext(account: account, device: device)
            guard expected.collection == "send", expected["device"]?.string == device else { throw Failure.sql("Chat result scope unavailable") }
            try chatTransaction {
                try bindChatAccount(account, device: device)
                guard try chatMeta(commandReceipt(expected.key)) != nil else { throw ChatRefusal.missingReceipt }
                guard let had = try chatLoad(expected.key), had.record.alive(), had.record.visible == expected.visible,
                      had.record["state"] == nil || had.record["state"]?.string == "processing" else {
                    throw Failure.sql("Chat request changed before final receipt")
                }
                var record = had.record
                var want = record.visible
                for (name, value) in fields { want[name] = value }
                _ = record.update(to: want, clock: clock, kind: Kind.of(record.collection))
                try chatSave(record, version: had.version)
                try chatClock()
            }
        }
    }

    private func commandReceipt(_ key: Record.Key) throws -> String {
        "command/" + (try JSONEncoder().encode([key.collection, key.id])).base64EncodedString()
    }

    private func chatContext(account: String, device: String) throws {
        guard !account.isEmpty, account.utf8.count <= 200, !device.isEmpty, device == clock.device,
              let filename = sqlite3_db_filename(db, "main"), !String(cString: filename).isEmpty else {
            throw Failure.sql("Persistent active-account chat journal required")
        }
    }

    private func bindChatAccount(_ account: String, device: String) throws {
        let key = "chat-command-scope/v1"
        let scope = String(decoding: try JSONEncoder().encode([account, device]), as: UTF8.self)
        if let bound = try chatMeta(key) {
            guard bound == scope else { throw Failure.sql("Chat journal account or device changed") }
        } else {
            guard try chatRun("INSERT INTO meta (key, value) VALUES (?, ?)", [key, scope]) == 1,
                  try chatMeta(key) == scope else { throw Failure.sql("Chat journal scope not saved") }
        }
    }

    /// Kept separate so Open and task approvals retain their existing policy.
    /// Restore the connection after COMMIT/ROLLBACK, including ambiguous failure.
    private func chatTransaction(_ body: () throws -> Void) throws {
        guard depth == 0, let synchronous = try chatInteger("PRAGMA synchronous"),
              let fullfsync = try chatInteger("PRAGMA fullfsync"),
              (0...3).contains(synchronous), (0...1).contains(fullfsync),
              try chatString("PRAGMA journal_mode") == "wal" else { throw Failure.sql("Chat durability settings unavailable") }
        var restorationError: Error?
        let result = Result<Void, Error> {
            defer {
                do {
                    try Journal.exec(db, "PRAGMA synchronous = \(synchronous)")
                    try Journal.exec(db, "PRAGMA fullfsync = \(fullfsync)")
                    guard try chatInteger("PRAGMA synchronous") == synchronous,
                          try chatInteger("PRAGMA fullfsync") == fullfsync else { throw Failure.sql("Chat durability settings not restored") }
                } catch { restorationError = error }
            }
            try Journal.exec(db, "PRAGMA synchronous = FULL")
            try Journal.exec(db, "PRAGMA fullfsync = ON")
            guard try chatInteger("PRAGMA synchronous") == 2, try chatInteger("PRAGMA fullfsync") == 1 else {
                throw Failure.sql("Chat durability settings not applied")
            }
            try transaction(body)
        }
        if let restorationError { throw restorationError }
        try result.get()
    }

    private func chatStatement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            sqlite3_finalize(statement)
            throw Failure.sql("Chat journal statement unavailable")
        }
        do {
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                let result: Int32
                switch value {
                case let string as String: result = sqlite3_bind_text(prepared, index, string, -1, Journal.transient)
                case let number as Int64: result = sqlite3_bind_int64(prepared, index, number)
                case let data as Data:
                    guard data.count <= Int(Int32.max) else { throw Failure.sql("Chat journal field too large") }
                    result = data.withUnsafeBytes { sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32(data.count), Journal.transient) }
                default: throw Failure.sql("Chat journal bind type unavailable")
                }
                guard result == SQLITE_OK else { throw Failure.sql("Chat journal field not bound") }
            }
            return prepared
        } catch { sqlite3_finalize(prepared); throw error }
    }

    private func chatRun(_ sql: String, _ values: [Any]) throws -> Int32 {
        let statement = try chatStatement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sql("Chat journal write failed") }
        return sqlite3_changes(db)
    }

    private func chatMeta(_ key: String) throws -> String? {
        let statement = try chatStatement("SELECT value FROM meta WHERE key = ?", [key])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.sql("Chat receipt read failed") }
        return String(cString: text)
    }

    private func chatInteger(_ sql: String) throws -> Int64? {
        let statement = try chatStatement(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw Failure.sql("Chat durability value unavailable")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func chatString(_ sql: String) throws -> String? {
        let statement = try chatStatement(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.sql("Chat durability mode unavailable") }
        return String(cString: text)
    }

    private func chatLoad(_ key: Record.Key) throws -> Row? {
        let statement = try chatStatement("SELECT body, dirty, version FROM records WHERE collection = ? AND id = ?", [key.collection, key.id])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Failure.sql("Chat request read failed") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.key == key else { throw Failure.sql("Chat request identity changed") }
        return Row(record: record, dirty: sqlite3_column_int64(statement, 1) == 1, version: sqlite3_column_int64(statement, 2))
    }

    private func chatSave(_ record: Record, version: Int64) throws {
        let body = try JSONEncoder().encode(record)
        guard try chatRun("""
            INSERT INTO records (collection, id, body, dirty, version) VALUES (?, ?, ?, 1, ?)
            ON CONFLICT (collection, id) DO UPDATE SET body = excluded.body, dirty = 1, version = excluded.version
            """, [record.collection, record.id, body, version]) == 1,
              let saved = try chatLoad(record.key), saved.record == record, saved.dirty, saved.version == version else {
            throw Failure.sql("Chat request checkpoint not saved")
        }
    }

    private func chatClock() throws {
        let data = try JSONEncoder().encode(clock.latest)
        let text = String(decoding: data, as: UTF8.self)
        guard try chatRun("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", ["clock", text]) == 1,
              try chatMeta("clock") == text else { throw Failure.sql("Chat clock checkpoint not saved") }
    }

    // MARK: Local iPhone task launch reservations

    /// No callback or effect. This ID stays consumed even if a later launch's
    /// outcome is unknown. A normal sync rewrite cannot remove the local receipt.
    public func reserveTaskCommand(_ original: Record, account: String, device: String, phone: String,
                                   publicSpace: String, cli: String) throws -> TaskLaunch.Reservation {
        try queue.sync {
            try chatContext(account: account, device: device)
            let request = try TaskRecords.Request.read(original, account: account, phone: phone, mac: device)
            guard request.space == publicSpace, ChatAgent(rawValue: cli) != nil else { throw TaskLaunch.Failure.context }
            let key = "task-launch/v1/" + request.id
            var result = TaskLaunch.Reservation.consumed
            try chatTransaction {
                try bindChatAccount(account, device: device)
                if let text = try chatMeta(key) {
                    let mapping = try JSONDecoder().decode(TaskLaunch.Mapping.self, from: Data(text.utf8))
                    try mapping.validate()
                    guard mapping.account == account, mapping.mac == device else { throw TaskLaunch.Failure.context }
                    return
                }
                guard let held = try chatLoad(original.key), held.record == original else { throw TaskLaunch.Failure.stale }
                _ = try TaskRecords.Request.read(held.record, account: account, phone: phone, mac: device)
                let mapping = try TaskLaunch.Mapping(request: request, session: UUID().uuidString.lowercased(), cli: cli)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let text = String(decoding: try encoder.encode(mapping), as: UTF8.self)
                guard try chatRun("INSERT INTO meta (key, value) VALUES (?, ?)", [key, text]) == 1,
                      try chatMeta(key) == text else { throw Failure.sql("Task launch reservation not saved") }
                result = .reserved(mapping)
            }
            return result
        }
    }

    /// Reopening never claims/reissues. The exact retained request must still
    /// match before any future adapter may interpret this local reservation.
    public func taskMapping(request id: String, account: String, device: String) throws -> TaskLaunch.Mapping? {
        try queue.sync {
            try chatContext(account: account, device: device)
            guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw TaskLaunch.Failure.context }
            guard let text = try chatMeta("task-launch/v1/" + id) else { return nil }
            let mapping = try JSONDecoder().decode(TaskLaunch.Mapping.self, from: Data(text.utf8))
            try mapping.validate()
            guard mapping.account == account, mapping.mac == device,
                  let held = try chatLoad(.init(collection: TaskRecords.requestCollection, id: id)) else { throw TaskLaunch.Failure.stale }
            let original = try TaskRecords.Request.read(held.record, account: account, phone: mapping.phone, mac: device)
            guard try mapping.matches(original) else { throw TaskLaunch.Failure.stale }
            return mapping
        }
    }

    // MARK: Checked local task observations

    /// The real engine's latest checkpoint and outbound record commit together.
    /// Missing local provenance, a stale request or any SQL failure refuses it.
    @discardableResult
    public func checkpointTaskObservation(_ observation: TaskRecords.Observation, mapping: TaskLaunch.Mapping,
                                          account: String, device: String) throws -> Record {
        try queue.sync {
            try chatContext(account: account, device: device)
            var saved: Record?
            try chatTransaction {
                try bindChatAccount(account, device: device)
                let request = try heldTaskRequest(mapping, account: account, device: device)
                try observation.validate(request: request)
                guard observation.session == mapping.session else { throw TaskObservation.Failure.context }
                let checkpoint = "task-observation/v1/" + mapping.request
                let key = Record.Key(collection: TaskRecords.observationCollection, id: mapping.request)
                let current = try chatLoad(key)
                if let text = try chatMeta(checkpoint) {
                    let old = try JSONDecoder().decode(TaskRecords.Observation.self, from: Data(text.utf8))
                    try old.validate(request: request)
                    guard old.session == mapping.session, let current,
                          try TaskRecords.Observation.read(current.record, request: request) == old else {
                        throw TaskObservation.Failure.corrupt
                    }
                    if observation == old { saved = current.record; return }
                    guard TaskObservation.mayAdvance(from: old, to: observation) else { throw TaskObservation.Failure.terminal }
                } else {
                    // A replicated body is not a locally observed engine checkpoint.
                    guard current?.record == nil, observation.revision == 1 else { throw TaskObservation.Failure.stale }
                }
                let fields = try observation.fields()
                var record = current?.record ?? Record(collection: key.collection, id: key.id)
                guard record.update(to: fields, clock: clock, kind: Kind.of(key.collection)) else { throw TaskObservation.Failure.stale }
                guard let text = fields["body"]?.string else { throw TaskObservation.Failure.corrupt }
                guard try chatRun("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                                  [checkpoint, text]) == 1,
                      try chatMeta(checkpoint) == text else { throw Failure.sql("Task observation checkpoint not saved") }
                try chatSave(record, version: current?.version ?? 0)
                try chatClock()
                guard try TaskRecords.Observation.read(record, request: request) == observation else { throw TaskObservation.Failure.corrupt }
                saved = record
            }
            guard let saved else { throw TaskObservation.Failure.corrupt }
            return saved
        }
    }

    /// Reads checked local provenance only. Reopening never reconstructs a
    /// completed result from an arbitrary remotely published observation.
    public func taskObservation(mapping: TaskLaunch.Mapping, account: String, device: String) throws -> TaskRecords.Observation? {
        try queue.sync {
            try chatContext(account: account, device: device)
            let request = try heldTaskRequest(mapping, account: account, device: device)
            guard let text = try chatMeta("task-observation/v1/" + mapping.request) else { return nil }
            let observation = try JSONDecoder().decode(TaskRecords.Observation.self, from: Data(text.utf8))
            try observation.validate(request: request)
            guard observation.session == mapping.session,
                  let current = try chatLoad(.init(collection: TaskRecords.observationCollection, id: mapping.request)),
                  try TaskRecords.Observation.read(current.record, request: request) == observation else { throw TaskObservation.Failure.corrupt }
            return observation
        }
    }

    private func heldTaskRequest(_ mapping: TaskLaunch.Mapping, account: String, device: String) throws -> TaskRecords.Request {
        try mapping.validate()
        guard mapping.account == account, mapping.mac == device,
              let text = try chatMeta("task-launch/v1/" + mapping.request),
              try JSONDecoder().decode(TaskLaunch.Mapping.self, from: Data(text.utf8)) == mapping,
              let held = try chatLoad(.init(collection: TaskRecords.requestCollection, id: mapping.request)) else {
            throw TaskObservation.Failure.context
        }
        let request = try TaskRecords.Request.read(held.record, account: account, phone: mapping.phone, mac: device)
        guard try mapping.matches(request) else { throw TaskObservation.Failure.stale }
        return request
    }

    // MARK: Local task approvals

    public enum ApprovalFailure: Error, Equatable { case context, missing, consumed }

    private struct ApprovalEntry: Codable {
        let request: TaskApproval
        var consumed: Bool
    }

    /// Called only when this Mac issues its own challenge for a live permit.
    /// The active account and enrolled key come from local trust, never a reply.
    /// A nonce cannot replace either an issued request or its consumed tombstone.
    @discardableResult
    public func issueApproval(_ request: TaskApproval, account: String,
                              trustedKey: P256.Signing.PublicKey, at now: Int64) throws -> Bool {
        try request.validate(at: now)
        guard request.action.account == account, request.action.mac == clock.device else { throw ApprovalFailure.context }
        guard request.keyID == TaskApproval.keyID(trustedKey) else { throw TaskApproval.Failure.untrustedKey }
        let key = try approvalKey(nonce: request.nonce, account: account)
        let entry = String(decoding: try JSONEncoder().encode(ApprovalEntry(request: request, consumed: false)), as: UTF8.self)
        return try queue.sync {
            var issued = false
            try approvalTransaction {
                guard Journal.meta(db, key) == nil else { return }
                try run("INSERT INTO meta (key, value) VALUES (?, ?)", [key, entry])
                guard sqlite3_changes(db) == 1 else { throw Failure.sql("Task approval original not saved") }
                issued = true
            }
            return issued
        }
    }

    /// Verifies the original locally issued challenge and consumes it in one
    /// transaction. `current` is independently read from the live Mac action;
    /// the caller must still revalidate that same action at its execution point.
    /// This returns the original request, and grants no permission or effect.
    public func consumeApproval(nonce: String, digest: Data, signature: Data, account: String,
                                trustedKey: P256.Signing.PublicKey, current: TaskApproval.Action,
                                at now: Int64) throws -> TaskApproval {
        guard current.account == account, current.mac == clock.device else { throw ApprovalFailure.context }
        let key = try approvalKey(nonce: nonce, account: account)
        return try queue.sync {
            var original: TaskApproval?
            try approvalTransaction {
                guard let text = Journal.meta(db, key) else { throw ApprovalFailure.missing }
                var entry = try JSONDecoder().decode(ApprovalEntry.self, from: Data(text.utf8))
                guard !entry.consumed else { throw ApprovalFailure.consumed }
                try entry.request.verify(digest: digest, signature: signature, trustedKey: trustedKey, current: current, at: now)
                entry.consumed = true
                let used = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
                try run("UPDATE meta SET value = ? WHERE key = ?", [used, key])
                guard sqlite3_changes(db) == 1 else { throw Failure.sql("Task approval consumption not saved") }
                original = entry.request
            }
            guard let original else { throw ApprovalFailure.missing }
            return original
        }
    }

    private func approvalKey(nonce: String, account: String) throws -> String {
        guard !account.isEmpty, account.utf8.count <= 200, let uuid = UUID(uuidString: nonce) else { throw TaskApproval.Failure.invalid }
        let scope = [account, clock.device, uuid.uuidString.lowercased()]
        return "task-approval/v2/" + (try JSONEncoder().encode(scope)).base64EncodedString()
    }

    /// Normal sync writes keep their existing policy. Approval transactions
    /// sync the WAL before returning and restore this connection's settings.
    /// Any transaction, commit or restoration failure throws before a grant.
    private func approvalTransaction(_ body: () throws -> Void) throws {
        guard depth == 0,
              let synchronous = rows("PRAGMA synchronous", []).first?.first as? Int64,
              let fullfsync = rows("PRAGMA fullfsync", []).first?.first as? Int64,
              (0...3).contains(synchronous), (0...1).contains(fullfsync),
              let mode = rows("PRAGMA journal_mode", []).first?.first as? String,
              mode == "wal" || mode == "memory" else { throw Failure.sql("Task approval durability settings unavailable") }
        var restorationError: Error?
        let result = Result<Void, Error> {
            // transaction rolls back before this defer runs on failure.
            defer {
                do {
                    try Journal.exec(db, "PRAGMA synchronous = \(synchronous)")
                    try Journal.exec(db, "PRAGMA fullfsync = \(fullfsync)")
                    guard rows("PRAGMA synchronous", []).first?.first as? Int64 == synchronous,
                          rows("PRAGMA fullfsync", []).first?.first as? Int64 == fullfsync else {
                        throw Failure.sql("Task approval durability settings not restored")
                    }
                } catch { restorationError = error }
            }
            try Journal.exec(db, "PRAGMA synchronous = FULL")
            try Journal.exec(db, "PRAGMA fullfsync = ON")
            guard rows("PRAGMA synchronous", []).first?.first as? Int64 == 2,
                  rows("PRAGMA fullfsync", []).first?.first as? Int64 == 1 else {
                throw Failure.sql("Task approval durability settings not applied")
            }
            try transaction(body)
        }
        try result.get()
        if let restorationError { throw restorationError }
    }

    /// A stamp for a change made outside the journal, written down at
    /// once: the next launch's clock starts after it.
    public func tick() -> Stamp {
        queue.sync {
            let stamp = clock.tick()
            persistClock()
            return stamp
        }
    }

    public func remove(_ key: Record.Key) throws {
        try queue.sync {
            guard let had = load(key), had.record.alive() else { return }
            var record = had.record
            record.remove(at: clock.tick())
            try save(record, dirty: true, version: had.version)
            persistClock()
        }
    }

    // MARK: From the server

    /// Records from elsewhere, merged in. Returns the merged records whose
    /// fields or life changed here, for the mirrors to write into Yab's
    /// own files. A record still dirty here stays dirty: the merge holds
    /// this device's change, and it still has to reach the server.
    public func receive(_ incoming: [(record: Record, version: Int64)]) throws -> [Record] {
        try queue.sync {
            var changed: [Record] = []
            let was = clock.latest
            try transaction {
                for (theirs, version) in incoming {
                    for stamp in theirs.stamps.values { clock.observe(stamp) }
                    if let d = theirs.deleted { clock.observe(d) }
                    let had = load(theirs.key)
                    let kind = Kind.of(theirs.collection)
                    let merged = had.map { $0.record.merged(with: theirs, kind: kind) } ?? theirs
                    let dirty = had.map { $0.dirty && merged != theirs } ?? false
                    try save(merged, dirty: dirty, version: max(version, had?.version ?? 0))
                    if let had {
                        // A record removed already that was changed after
                        // that removal and removed again (a visit's cut) is
                        // news too: its mirror reads why it went. A closed
                        // tab seen since stays closed: no news.
                        let said = !merged.alive(kind) && merged.deleted != had.record.deleted && had.record.deleted.map { gone in
                            merged.stamps.contains { $0.value > gone && !(merged.fields[$0.key]?.isNull ?? true) }
                        } ?? false
                        if had.record.visible != merged.visible || had.record.alive(kind) != merged.alive(kind) || said {
                            changed.append(merged)
                        }
                    } else if merged.alive(kind) {
                        changed.append(merged)
                    }
                }
                if clock.latest != was { persistClock() }
            }
            return changed
        }
    }

    /// The server took these at these versions. A record changed again here
    /// since it was sent stays dirty.
    public func sent(_ taken: [(record: Record, version: Int64)]) throws {
        try queue.sync {
            try transaction {
                for (record, version) in taken {
                    guard let had = load(record.key) else { continue }
                    try save(had.record, dirty: had.record != record, version: version)
                }
            }
        }
    }

    /// The server's version of a record is not what this device thought:
    /// it stays dirty and goes again on top of `version`.
    public func rebase(_ key: Record.Key, version: Int64) throws {
        try queue.sync {
            guard let had = load(key) else { return }
            try save(had.record, dirty: true, version: version)
        }
    }

    // MARK: SQLite

    private struct Row { var record: Record; var dirty: Bool; var version: Int64 }

    private func load(_ key: Record.Key) -> Row? {
        rows("SELECT body, dirty, version FROM records WHERE collection = ? AND id = ?", [key.collection, key.id]).first.flatMap { row in
            decode(row[0]).map { Row(record: $0, dirty: (row[1] as? Int64) == 1, version: (row[2] as? Int64) ?? 0) }
        }
    }

    private func save(_ record: Record, dirty: Bool, version: Int64?) throws {
        let body = try JSONEncoder().encode(record)
        try run("""
            INSERT INTO records (collection, id, body, dirty, version) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (collection, id) DO UPDATE SET body = excluded.body, dirty = excluded.dirty, version = excluded.version
            """, [record.collection, record.id, body, Int64(dirty ? 1 : 0), version ?? 0])
    }

    private func decode(_ value: Any?) -> Record? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func persistClock() {
        if let data = try? JSONEncoder().encode(clock.latest), let text = String(data: data, encoding: .utf8) {
            setMeta("clock", text)
        }
    }

    private func setMeta(_ key: String, _ value: String) {
        try? run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [key, value])
    }

    private var depth = 0
    private func transaction(_ body: () throws -> Void) throws {
        depth += 1
        defer { depth -= 1 }
        guard depth == 1 else { return try body() }
        try Journal.exec(db, "BEGIN IMMEDIATE")
        do {
            try body()
            try Journal.exec(db, "COMMIT")
        } catch {
            try? Journal.exec(db, "ROLLBACK")
            throw error
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw Failure.sql("\(message): \(sql)")
        }
    }

    private static func meta(_ db: OpaquePointer?, _ key: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer?, _ values: [Any]) {
        for (i, value) in values.enumerated() {
            let at = Int32(i + 1)
            switch value {
            case let s as String: sqlite3_bind_text(statement, at, s, -1, Journal.transient)
            case let n as Int64: sqlite3_bind_int64(statement, at, n)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(d.count), Journal.transient) }
            default: sqlite3_bind_null(statement, at)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func rows(_ sql: String, _ values: [Any]) -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var out: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { column -> Any? in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                    return Data(bytes: bytes, count: count)
                case SQLITE_TEXT: return sqlite3_column_text(statement, column).map { String(cString: $0) }
                default: return nil
                }
            })
        }
        return out
    }
}

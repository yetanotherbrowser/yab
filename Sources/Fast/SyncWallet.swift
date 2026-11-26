import Foundation
import SyncKit

// Passwords, two-factor keys, cards and addresses in sync (docs/sync.md,
// "Passwords and cards"). They live in the keychain, not in Yab's files, so
// they have a mirror of their own: what the keychain holds is read off the
// main thread and told to the journal, what came from elsewhere is written
// into the keychain on the same queue.
//
// A secret never sits in the journal as it is: a password, a card's number
// and code, an address, go in a field sealed with a key of its own derived
// from the account's (Seal.hide), so `sync.sqlite` on disk says which sites
// have a login and nothing more. What the keychain itself keeps in the clear
// (a login's site and name, a card's brand and last four) rides in the clear.
//
// Which side is newer: the keychain knows when each item last changed, the
// journal when each record did. An item changed here after the record was
// written goes up, and so does one whose record this Mac wrote last; a
// record written elsewhere after the item changed here comes down into the
// keychain (recordIsNewer). An item still as sync wrote it in from a record
// is as old as that record, whatever its date says: the date is when this
// Mac got round to writing it (keychainIsNewer). An item gone from the
// keychain is a removal only if this mirror saw it there before; one it
// never saw is a record not yet written in, and is written.

enum SyncWallet {
    static let login = SyncCollection.login, code = SyncCollection.code, card = SyncCollection.card, address = SyncCollection.address
    static let collections = [login, code, card, address]

    static func contextAddress(_ data: Data, id: String) -> StreetAddress? {
        guard let address = Wallet.address(of: data), address.id == id else { return nil }
        return address
    }

    /// Settings › Sync, Passwords and cards: on unless turned off. Off, this
    /// Mac neither sends nor takes them; what the account has stays.
    static var on: Bool {
        get { Store.settings.object(forKey: "sync.passwords") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "sync.passwords") }
    }

    typealias Collection = SyncShapes.Collection

    /// What a read of the keychain found: the records it should be, and
    /// what the journal has that the keychain should take.
    struct Read {
        var now: [String: Collection] = [:]
        var writes: [SyncKit.Record] = []
        var stamps: [String: String] = [:]
        var seen: Set<String> = []
        /// Items Yab wrote since the read before, read again whatever
        /// their date; handed back if this read is thrown away.
        var touched: Set<String> = []
        var published: [String: Int] = [:]
        /// The collections whose records `now` changes: only they are
        /// told to the journal, which otherwise decodes every record of all
        /// four again on the main thread to find nothing changed.
        var differs: Set<String> = []
    }

    /// One pass over the keychain. `stamps` is when each item was last read
    /// (so an item that hasn't changed isn't read again), `seen` every item
    /// this mirror has found in the keychain. Nil when the keychain couldn't
    /// be asked: then nothing is reconciled, or everything would go.
    static func read(journal: Journal, seal: Seal, stamps: [String: String], seen: Set<String>) -> Read? {
        guard let logins = Vault.listed(), let cards = Wallet.listed(cards: true), let places = Wallet.listed(cards: false) else { return nil }
        var out = Read(stamps: stamps, seen: seen)
        let touched = Vault.changedItems()
        out.touched = touched
        let codes = OneTime.modified()
        let local = Vault.localChanges()

        func settle(_ collection: String, _ id: String, modified: Date?, stamp: String, fields make: () -> [String: Value]?) {
            let key = SyncKit.Record.Key(collection: collection, id: id)
            let have = journal.record(key).flatMap { $0.alive() ? $0 : nil }
            out.seen.insert(key.description)
            if let have, stamps[key.description] == stamp, !touched.contains(key.description) {
                out.now[collection, default: [:]][id] = have.visible
                return
            }
            guard let fields = make() else {
                if let have { out.now[collection, default: [:]][id] = have.visible }
                return
            }
            out.published[key.description] = local[key.description]
            out.stamps[key.description] = stamp
            guard let have else {
                out.now[collection, default: [:]][id] = sealed(fields, key, seal)
                return
            }
            if same(fields, have, key, seal) {
                out.now[collection, default: [:]][id] = have.visible
            } else if local[key.description] == nil,
                      recordIsNewer(have, than: Vault.modified(key.description, fallback: modified), here: journal.clock.device, synced: Vault.synced(key.description)) {
                // Changed elsewhere since it changed here: the keychain takes it.
                out.now[collection, default: [:]][id] = have.visible
                out.writes.append(have)
                out.stamps[key.description] = nil
            } else {
                out.now[collection, default: [:]][id] = merge(sealed(fields, key, seal), over: have, key, seal)
            }
        }

        for login in logins {
            settle(Self.login, login.id, modified: login.modified, stamp: "\(login.modified?.timeIntervalSince1970 ?? 0)") {
                Vault.password(host: login.host, user: login.user).map { fields(login, password: $0) }
            }
        }
        // A two-factor key is a record of its own, beside its login's: a
        // device without one never takes it from the others.
        for (id, modified) in codes {
            let names = id.components(separatedBy: "\u{1}")
            guard names.count == 2 else { continue }
            settle(code, id, modified: modified, stamp: "\(modified.timeIntervalSince1970)") {
                OneTime.text(host: names[0], user: names[1]).map { ["secret": .string($0)] }
            }
        }
        for (list, collection) in [(cards, card), (places, address)] {
            for item in list {
                settle(collection, item.id, modified: item.modified, stamp: "\(item.modified?.timeIntervalSince1970 ?? 0)") {
                    guard let kept = Wallet.kept(card: collection == card, item.id),
                          let secret = String(data: kept.secret, encoding: .utf8) else { return nil }
                    var fields: [String: Value] = ["secret": .string(secret)]
                    if let facts = kept.facts, let value = try? JSONDecoder().decode(Value.self, from: facts) { fields["facts"] = value }
                    return fields
                }
            }
        }

        // In the journal and not in the keychain: gone here if it was seen
        // here, else not written in yet.
        let listed = Set(logins.map { "\(login)/\($0.id)" } + codes.keys.map { "\(code)/\($0)" } + cards.map { "\(card)/\($0.id)" } + places.map { "\(address)/\($0.id)" })
        for collection in collections {
            let living = journal.living(collection)
            var differs = !Set(out.now[collection, default: [:]].keys).isSubset(of: living.map(\.id))
            for record in living {
                guard !listed.contains(record.key.description) else {
                    if !holds(out.now[collection]?[record.id], record) { differs = true }
                    continue
                }
                if seen.contains(record.key.description) || local[record.key.description] != nil {
                    out.published[record.key.description] = local[record.key.description]
                    out.seen.remove(record.key.description)
                    out.stamps[record.key.description] = nil
                    differs = true
                } else {
                    out.now[collection, default: [:]][record.id] = record.visible
                    out.writes.append(record)
                }
            }
            if differs { out.differs.insert(collection) }
        }
        // A removed item must leave no stale "seen" entry. Otherwise a later
        // password saved under the same names is mistaken for another removal.
        for key in seen.subtracting(listed) {
            out.seen.remove(key)
            out.stamps[key] = nil
        }
        for (key, generation) in local where !listed.contains(key) {
            out.published[key] = generation
        }
        return out
    }

    /// Whether a record already says `fields`, so telling the journal them
    /// changes nothing (Record.update).
    static func holds(_ fields: [String: Value]?, _ record: SyncKit.Record) -> Bool {
        fields.map { $0.filter { !$0.value.isNull } == record.visible } ?? false
    }

    /// A login's record fields, its password still plain (`sealed` hides it).
    static func fields(_ login: Vault.Listed, password: String) -> [String: Value] {
        [
            "host": .string(login.host), "user": .string(login.user),
            "used": Value(login.used.map { $0.timeIntervalSince1970.rounded(.down) }),
            "clear": login.clear ? .bool(true) : .null,
            "secret": .string(password),
            // The Space it was saved in, in the clear like its site: a Mac
            // from before reads past it.
            "space": login.space.map { .string($0.uuidString) } ?? .null,
        ]
    }

    /// The Space a login's record says it was saved in.
    static func space(of record: SyncKit.Record) -> UUID? {
        record["space"]?.string.flatMap(UUID.init(uuidString:))
    }

    /// Records from elsewhere, into the keychain: each written only if it
    /// says something the keychain doesn't, each removal deleted. Whether
    /// the keychain is to be read again: something was written, or an item
    /// here is newer than its record and goes up.
    @discardableResult
    static func write(_ records: [SyncKit.Record], seal: Seal, contextEpoch: String = ContextPrivacy.shared.epoch) -> Bool {
        var again = false
        // When each item here last changed, read once for the lot.
        lazy var logins = Dictionary((Vault.listed() ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lazy var codes = OneTime.modified()
        lazy var cards = Dictionary((Wallet.listed(cards: true) ?? []).map { ($0.id, $0.modified) }, uniquingKeysWith: { a, _ in a })
        lazy var places = Dictionary((Wallet.listed(cards: false) ?? []).map { ($0.id, $0.modified) }, uniquingKeysWith: { a, _ in a })
        for record in records {
            let key = record.key
            // Changed here after the record was: this side goes up instead.
            func newerHere(_ modified: Date??) -> Bool {
                let newer = Vault.localChanges()[key.description] != nil ||
                    keychainIsNewer(than: record, modified: Vault.modified(key.description, fallback: modified ?? nil), synced: Vault.synced(key.description))
                if newer { again = true }
                return newer
            }
            switch record.collection {
            case login:
                let listed = logins[record.id]
                if newerHere(listed?.modified) { continue }
                guard record.alive() else {
                    let names = record.id.components(separatedBy: "\u{1}")
                    if names.count == 2, listed != nil { Vault.forget(host: names[0], user: names[1], from: record.latest?.wall); again = true }
                    continue
                }
                guard let host = record["host"]?.string, let user = record["user"]?.string,
                      let password = record["secret"]?.string.flatMap({ seal.reveal($0, in: key) }).flatMap({ String(data: $0, encoding: .utf8) })
                else { continue }
                let used = record["used"]?.number.map(Date.init(timeIntervalSince1970:))
                let clear = record["clear"]?.bool == true
                // A record without a Space, from a Mac before them or of
                // a shared login, leaves the one here as it is.
                let tagged = Self.space(of: record)
                if listed == nil || listed?.clear != clear
                    || listed?.used.map({ $0.timeIntervalSince1970.rounded(.down) }) != used?.timeIntervalSince1970
                    || (tagged != nil && listed?.space != tagged)
                    || Vault.password(host: host, user: user) != password {
                    if Vault.save(host: host, user: user, password: password, used: used, clear: clear, space: tagged, from: record.latest?.wall) { again = true }
                }
            case code:
                let names = record.id.components(separatedBy: "\u{1}")
                guard names.count == 2, !newerHere(codes[record.id]) else { continue }
                guard record.alive() else {
                    if codes[record.id] != nil { OneTime.forget(host: names[0], user: names[1], from: record.latest?.wall); again = true }
                    continue
                }
                guard let text = record["secret"]?.string.flatMap({ seal.reveal($0, in: key) }).flatMap({ String(data: $0, encoding: .utf8) }),
                      text != OneTime.text(host: names[0], user: names[1]) else { continue }
                if OneTime.save(text, host: names[0], user: names[1], from: record.latest?.wall) { again = true }
            case card, address:
                if record.collection == address, !ContextPrivacy.shared.current(contextEpoch) { continue }
                let isCard = record.collection == card
                let modified = isCard ? cards[record.id] : places[record.id]
                if newerHere(modified) { continue }
                guard record.alive() else {
                    if modified != nil { Wallet.remove(card: isCard, record.id, from: record.latest?.wall); again = true }
                    continue
                }
                guard let secret = record["secret"]?.string.flatMap({ seal.reveal($0, in: key) }) else { continue }
                let facts = record["facts"].flatMap { try? JSONEncoder().encode($0) }
                if unchanged(Wallet.kept(card: isCard, record.id), secret: secret, facts: facts, card: isCard) { continue }
                if !isCard {
                    guard let incoming = contextAddress(secret, id: record.id) else { continue }
                    if ContextPrivacy.shared.mergeSyncedAddress(incoming, epoch: contextEpoch, stamp: record.latest, image: ContextSyncReplay.image(record), write: { merged in
                        guard let data = Wallet.addressData(merged) else { return false }
                        return Wallet.put(card: false, record.id, secret: data, facts: facts, from: record.latest?.wall)
                    }) { again = true }
                } else {
                    if Wallet.put(card: isCard, record.id, secret: secret, facts: facts, from: record.latest?.wall) { again = true }
                }
            default: continue
            }
        }
        return again
    }

    /// Whether a record that says something other than the keychain's item
    /// was changed after it, so the keychain takes the record instead of
    /// the item going up. A record this Mac changed last was written from
    /// what its keychain held then, and an item is read again only once its
    /// date moved or Yab wrote it: the item changed since, so it is the
    /// newer one, whatever the dates say. They can't tell: the keychain
    /// keeps whole seconds, so a password changed in the second its record
    /// was written read as older than the record and was put back (the
    /// keychain took the record, and the other Macs never heard of the
    /// change), and the record is stamped when the read reached the
    /// journal, after the keychain was read. A record another device
    /// changed last is newer when that change came after the item's.
    ///
    /// `synced`: the wall stamp of the record sync last wrote the item in
    /// from, when nothing here changed it since (Vault.synced). Then the
    /// record is newer once changed after that one: the item's date is
    /// when this Mac wrote it in. A Mac that wrote in a change late, after
    /// the next one was made elsewhere, read its own late write as the
    /// newer change, kept the older password and sent it back to the
    /// others (evals/sync/check.py, "a change B writes in late").
    static func recordIsNewer(_ record: SyncKit.Record, than modified: Date?, here device: String, synced: Int64? = nil) -> Bool {
        guard let latest = record.latest else { return false }
        if let synced { return latest.wall > synced }
        guard latest.device != device else { return false }
        return Double(latest.wall) / 1000 > (modified ?? .distantPast).timeIntervalSince1970
    }

    /// Whether the keychain's item changed after a record from elsewhere
    /// did, so the record isn't written in and the item goes up instead.
    /// One still as sync wrote it in from a record (`synced`, that
    /// record's wall stamp) is as old as that record: its date is when
    /// this Mac got round to writing it, a second after the next change
    /// was stamped elsewhere on a busy Mac, and the next record was
    /// passed over for it.
    static func keychainIsNewer(than record: SyncKit.Record, modified: Date?, synced: Int64?) -> Bool {
        guard let modified, let latest = record.latest else { return false }
        if let synced { return synced >= latest.wall }
        return modified.timeIntervalSince1970 > Double(latest.wall) / 1000
    }

    // MARK: -

    /// The secret fields sealed for the journal.
    static func sealed(_ fields: [String: Value], _ key: SyncKit.Record.Key, _ seal: Seal) -> [String: Value] {
        var out = fields
        for name in ["secret"] {
            if let plain = fields[name]?.string, let hidden = try? seal.hide(Data(plain.utf8), in: key) { out[name] = .string(hidden) }
        }
        return out
    }

    /// Whether the keychain's fields say what the record says, its sealed
    /// fields opened to compare.
    static func same(_ plain: [String: Value], _ record: SyncKit.Record, _ key: SyncKit.Record.Key, _ seal: Seal) -> Bool {
        var opened = record.visible
        for name in ["secret"] {
            if let hidden = opened[name]?.string {
                opened[name] = seal.reveal(hidden, in: key).flatMap { String(data: $0, encoding: .utf8) }.map(Value.string) ?? .null
            }
        }
        // A record a Mac from before Spaces wrote again has none: the
        // Space kept here goes up with the next change, not on its own,
        // or the two would take each other's turn every pass.
        var plain = plain
        if opened["space"]?.isNull ?? true { plain["space"] = nil }
        if let mine = plain["secret"]?.string, let theirs = opened["secret"]?.string, mine != theirs,
           sameSecret(Data(mine.utf8), Data(theirs.utf8), in: key.collection) {
            opened["secret"] = plain["secret"]
        }
        return opened.filter { !$0.value.isNull } == plain.filter { !$0.value.isNull }
    }

    /// New fields over a record, keeping the sealed box of a secret that
    /// didn't change, so it isn't sent again for a new nonce alone.
    static func merge(_ fresh: [String: Value], over record: SyncKit.Record, _ key: SyncKit.Record.Key, _ seal: Seal) -> [String: Value] {
        var out = fresh
        for name in ["secret"] {
            guard let old = record[name]?.string, let new = fresh[name]?.string,
                  let a = seal.reveal(old, in: key), let b = seal.reveal(new, in: key), sameSecret(a, b, in: key.collection) else { continue }
            out[name] = .string(old)
        }
        return out
    }

    /// Whether a card or an address kept here already says what a record
    /// from elsewhere does, so it isn't written in again.
    static func unchanged(_ kept: (secret: Data, facts: Data?)?, secret: Data, facts: Data?, card: Bool) -> Bool {
        guard let kept else { return false }
        return card ? kept.secret == secret && same(kept.facts, facts) : sameSecret(kept.secret, secret, in: address)
    }

    /// Whether two secrets say the same: an address by what it says, as a
    /// Mac from before kept its keys in any order; the rest as they are.
    static func sameSecret(_ a: Data, _ b: Data, in collection: String) -> Bool {
        if a == b { return true }
        guard collection == address, let mine = Wallet.address(of: a) else { return false }
        return mine == Wallet.address(of: b)
    }

    private static func same(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return a == b }
        return (try? JSONDecoder().decode(Value.self, from: a)) == (try? JSONDecoder().decode(Value.self, from: b))
    }
}

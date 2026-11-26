import Foundation
import Testing
import SyncKit
@testable import Fast

/// Macs of one account trading what they hold until there is nothing more
/// to say: each round every Mac tells its journal what its own files and
/// keychain hold, sends what changed, and takes in what the others sent.
/// A record nobody changed must stop going round (docs/sync.md).
@MainActor
struct SyncQuietTests {
    init() { SyncShapes.register() }

    /// One server's worth of trading: every Mac's changes up, then down to
    /// the others. `adopt` writes what came into that Mac's own files.
    final class Account {
        let journals: [Journal]
        private var version: Int64 = 0

        init(_ count: Int) throws {
            journals = try (0..<count).map { try Journal(path: nil, device: "mac-\($0)") }
        }

        /// How many records went up.
        func trade(adopt: (Int, [SyncKit.Record]) throws -> Void) throws -> Int {
            var up = 0
            for (index, journal) in journals.enumerated() {
                let pending = journal.pending()
                guard !pending.isEmpty else { continue }
                up += pending.count
                version += 1
                let taken = pending.map { ($0.record, version) }
                try journal.sent(taken)
                for (other, there) in journals.enumerated() where other != index {
                    try adopt(other, try there.receive(taken))
                }
            }
            return up
        }

        /// Records sent each round, `rounds` times.
        func run(_ rounds: Int, flush: (Int, Journal) throws -> Void, adopt: (Int, [SyncKit.Record]) throws -> Void) throws -> [Int] {
            try (0..<rounds).map { _ in
                for (index, journal) in journals.enumerated() { try flush(index, journal) }
                return try trade(adopt: adopt)
            }
        }
    }

    // MARK: an address (the wallet's)

    /// SyncWallet.read's verdict on one keychain item: the record as it
    /// stands when they say the same, else the item over it.
    private static func read(_ secret: Data, _ have: SyncKit.Record?, _ key: SyncKit.Record.Key, _ seal: Seal) -> [String: Value] {
        let fields: [String: Value] = ["secret": .string(String(decoding: secret, as: UTF8.self))]
        guard let have else { return SyncWallet.sealed(fields, key, seal) }
        if SyncWallet.same(fields, have, key, seal) { return have.visible }
        return SyncWallet.merge(SyncWallet.sealed(fields, key, seal), over: have, key, seal)
    }

    /// JSON's top-level keys in the order they are written.
    static func keys(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).matches(of: #/[{,]"([a-zA-Z]+)":/#).map { String($0.output.1) }
    }

    /// The same object with its keys in reverse order: as a Mac from
    /// before kept it. The test process hashes the same way each run, so
    /// an encoder gives it one order; two Macs are two processes.
    static func reordered(_ data: Data) throws -> Data {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try object.keys.sorted(by: >).map { name in
            let one = try JSONSerialization.data(withJSONObject: [name: object[name]!])
            return String(decoding: one.dropFirst().dropLast(), as: UTF8.self)
        }
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }

    @Test func anAddressGoesQuietAcrossThreeMacs() throws {
        let seal = Seal.make()
        var home = StreetAddress(id: "address-quiet", name: "Sam Rivera", organization: "Tern", street: "221 Mission St\nApt 4",
                                 city: "San Francisco", region: "CA", postal: "94105", country: "US", phone: "+1 555 0100",
                                 email: "sam@example.test", source: "Contacts", found: "a contact card")
        home.used = Date(timeIntervalSince1970: 1_790_000_000.25)
        let key = SyncKit.Record.Key(collection: SyncWallet.address, id: home.id)
        // The first Mac kept it in an order of its own.
        var keychains: [[String: Data]] = [[home.id: try Self.reordered(try #require(Wallet.addressData(home)))], [:], [:]]
        let account = try Account(3)
        let sent = try account.run(8, flush: { mac, journal in
            guard let secret = keychains[mac][home.id] else { return }
            let have = journal.record(key).flatMap { $0.alive() ? $0 : nil }
            try journal.reconcile(SyncWallet.address, [home.id: Self.read(secret, have, key, seal)])
        }, adopt: { mac, records in
            // SyncWallet.write's address branch, the merge given back as is.
            for record in records where record.collection == SyncWallet.address && record.alive() {
                let secret = try #require(record["secret"]?.string.flatMap { seal.reveal($0, in: key) })
                let kept = keychains[mac][record.id].map { (secret: $0, facts: Data?.none) }
                if SyncWallet.unchanged(kept, secret: secret, facts: nil, card: false) { continue }
                let incoming = try #require(SyncWallet.contextAddress(secret, id: record.id))
                keychains[mac][record.id] = Wallet.addressData(incoming)
            }
        })
        #expect(sent.first == 1)
        #expect(sent.dropFirst().allSatisfy { $0 == 0 }, "sent per round: \(sent)")
        for keychain in keychains { #expect(keychain[home.id].flatMap(Wallet.address(of:)) == home) }
    }

    @Test func anAddressKeptInAnotherOrderIsTheSameAddress() throws {
        let seal = Seal.make()
        let home = StreetAddress(id: "address-order", name: "Sam Rivera", street: "221 Mission St", city: "San Francisco", postal: "94105")
        let key = SyncKit.Record.Key(collection: SyncWallet.address, id: home.id)
        let written = try #require(Wallet.addressData(home))
        let other = try Self.reordered(written)
        #expect(other != written)
        #expect(Wallet.address(of: other) == home)
        #expect(SyncWallet.unchanged((other, nil), secret: written, facts: nil, card: false))
        let record = SyncKit.Record(collection: SyncWallet.address, id: home.id,
                                    fields: ["secret": .string(try seal.hide(written, in: key))], stamps: ["secret": Stamp(wall: 1, device: "b")])
        #expect(SyncWallet.same(["secret": .string(String(decoding: other, as: UTF8.self))], record, key, seal))
        // One encoding, whatever the process: its keys sorted.
        #expect(Self.keys(written).count >= 5)
        #expect(Self.keys(written) == Self.keys(written).sorted())
        // A card's number is compared as it is.
        #expect(!SyncWallet.unchanged((Data("4242 ".utf8), nil), secret: Data("4242".utf8), facts: nil, card: true))
    }

    @Test func aWalletCollectionIsReconciledOnlyWhenItsRecordsWouldChange() throws {
        let journal = try Journal(path: nil, device: "mac-0")
        let fields: [String: Value] = ["host": .string("pw.test"), "user": .string("me"), "secret": .string("box"), "clear": .null]
        try journal.reconcile(SyncWallet.login, ["one": fields])
        let record = try #require(journal.record(.init(collection: SyncWallet.login, id: "one")))
        // What the read hands back for an item it didn't open, empty fields and all.
        #expect(SyncWallet.holds(record.visible, record))
        #expect(SyncWallet.holds(fields, record))
        #expect(try journal.reconcile(SyncWallet.login, ["one": fields]).isEmpty)
        var changed = fields
        changed["secret"] = .string("another box")
        #expect(!SyncWallet.holds(changed, record))
        // Gone from the read: a removal.
        #expect(!SyncWallet.holds(nil, record))
    }

    // MARK: the profile (file/profile.json)

    @Test func theProfileGoesQuietAcrossThreeMacs() throws {
        let folders = (0..<3).map { _ in FileManager.default.temporaryDirectory.appendingPathComponent("profile-quiet-" + UUID().uuidString) }
        defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let files = folders.map { $0.appendingPathComponent("profile.json") }
        var mine = Profile()
        mine.name = "Sam Rivera"; mine.company = "Tern"; mine.role = "Founding designer"; mine.github = "samr"
        mine.bio = "Designs browsers."; mine.about = "A paragraph."; mine.x = "samr"; mine.headline = "Designer at Tern"
        mine.edited = ["name", "company", "role", "github", "bio", "about", "x", "headline"]
        mine.sources = ["name": "you", "company": "LinkedIn"]
        mine.source = "you"
        mine.updated = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Profile.save(mine, origin: .usage, stamp: false, to: files[0]))
        let domain = "profile-quiet-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let privacies = files.map { file in
            var stores = ContextPrivacy.Stores()
            stores.profile = { Profile.load(from: file) }
            stores.saveProfile = { Profile.save($0, origin: .usage, to: file) }
            stores.saveSyncedProfile = { Profile.saveSynced($0, to: file) }
            return ContextPrivacy(root: file.deletingLastPathComponent(), settings: settings, storage: MemoryContextJournal(), stores: stores)
        }
        let account = try Account(3)
        let sent = try account.run(6, flush: { mac, journal in
            try journal.reconcile(SyncShapes.file, SyncShapes.files(in: folders[mac]))
        }, adopt: { mac, records in
            // SyncCenter's profile.json branch.
            for record in records where record.id == "profile.json" && record.alive() {
                let incoming = try #require(SyncShapes.profile(from: record))
                _ = privacies[mac].mergeSyncedProfile(incoming, epoch: privacies[mac].epoch, stamp: record.latest, image: ContextSyncReplay.image(record))
            }
        })
        #expect(sent.first == 1)
        #expect(sent.dropFirst().allSatisfy { $0 == 0 }, "sent per round: \(sent)")
        let first = Profile.load(from: files[0])
        for file in files { #expect(Profile.load(from: file) == first) }
    }

    @Test func aProfileWrittenFromARecordSaysWhatTheRecordSays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-echo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("profile.json")
        var theirs = Profile()
        theirs.name = "Sam Rivera"
        theirs.updated = Date(timeIntervalSince1970: 1_790_000_000)
        // A set grown another way lists its members in another order.
        var edited = Set<String>(minimumCapacity: 97)
        for key in Profile.keys.reversed() { edited.insert(key) }
        theirs.edited = edited
        #expect(Profile.saveSynced(theirs, to: file))
        let written = try #require(SyncShapes.files(in: folder)["profile.json"]?["json"])
        #expect(written.object?["updated"]?.string == "2026-09-21T14:13:20Z")
        #expect(written.object?["edited"]?.array?.compactMap(\.string) == Profile.keys.sorted())
        #expect(Profile.load(from: file) == theirs)
        // One written before `edited` was sorted reads the same.
        var old = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        old["edited"] = Array(Profile.keys.reversed())
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        #expect(SyncShapes.files(in: folder)["profile.json"]?["json"] == written)
    }

    // MARK: settings kept as JSON

    @Test func theSameStampIsTheSameSetting() {
        // `stamp.info` syncs as its bytes: two Macs holding the same stamp
        // must hold the same bytes, or a refresh sends it round again.
        let info = MemberStamp.Info(number: 9863, kind: "self", from: "Yab", note: "Glad you came.",
                                    at: Date(timeIntervalSince1970: 1_790_000_000.5), owner: "install-a")
        let written = MemberStamp.data(info)
        let keys = written.map(Self.keys) ?? []
        #expect(keys.count == 6)
        #expect(keys == keys.sorted())
        #expect(written.flatMap { try? JSONDecoder().decode(MemberStamp.Info.self, from: $0) } == info)
    }

    @Test func quickActionsWriteTheirSetsSorted() throws {
        var personalized = Set<String>(minimumCapacity: 97), dismissed = Set<String>(minimumCapacity: 3)
        for id in ["mail", "calendar", "drive", "maps", "news", "photos", "translate"] { personalized.insert(id); dismissed.insert(id + ".off") }
        let saved = QuickActions.Saved(actions: [], personalized: personalized, dismissed: dismissed, made: nil, hinted: ["mail": 2])
        let json = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(saved))
        #expect(json.object?["personalized"]?.array?.compactMap(\.string) == personalized.sorted())
        #expect(json.object?["dismissed"]?.array?.compactMap(\.string) == dismissed.sorted())
        let back = try JSONDecoder().decode(QuickActions.Saved.self, from: JSONEncoder().encode(saved))
        #expect(back.personalized == personalized && back.dismissed == dismissed && back.hinted == ["mail": 2])
    }

    @Test func aFieldTakenInReviewIsAChangeMadeHere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("profile.json")
        var mine = Profile()
        mine.headline = "Before"
        mine.updated = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Profile.saveSynced(mine, to: file))
        let domain = "profile-review-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        var stores = ContextPrivacy.Stores()
        stores.profile = { Profile.load(from: file) }
        stores.saveProfile = { Profile.save($0, origin: .usage, to: file) }
        stores.saveSyncedProfile = { Profile.saveSynced($0, to: file) }
        let privacy = ContextPrivacy(root: folder, settings: settings, storage: MemoryContextJournal(), stores: stores)
        let before = Date()
        #expect(privacy.applyReviewedProfile("headline", value: .init(value: "After"), expected: Profile.cells(mine)["headline"], epoch: privacy.epoch))
        let now = Profile.load(from: file)
        #expect(now.headline == "After")
        #expect((now.updated ?? .distantPast) >= before.addingTimeInterval(-1))
    }

    // MARK: visits

    @Test func oneSearchPlaceGoesQuietWhenEachMacSearchedSomethingElse() throws {
        let key = "google.com/search"
        func visit(_ query: String, at seconds: Double) -> Visit {
            Visit(url: "https://www.google.com/search?q=" + query, key: key, title: query + " - Google Search", count: 1,
                  last: Date(timeIntervalSince1970: seconds), typed: nil)
        }
        let histories = [History([visit("a", at: 1_000)]), History([visit("b", at: 2_000)]), History([visit("c", at: 1_500)])]
        let account = try Account(3)
        let sent = try account.run(8, flush: { mac, journal in
            try SyncShapes.reconcileVisits(journal, SyncShapes.visits(histories[mac].visits(since: .distantPast)), cuts: histories[mac].takeCuts())
        }, adopt: { mac, records in
            histories[mac].adoptSynced(SyncShapes.visits(from: records))
            histories[mac].dropSynced(SyncShapes.cutVisits(from: records))
        })
        #expect(sent.suffix(5).allSatisfy { $0 == 0 }, "sent per round: \(sent)")
        // Every Mac ends on the latest visit, its address with its title.
        for history in histories {
            let place = try #require(history.visits(since: .distantPast).first)
            #expect(place.last == Date(timeIntervalSince1970: 2_000))
            let query = try #require(URLComponents(string: place.url)?.queryItems?.first?.value)
            #expect(place.title == query + " - Google Search")
        }
        for journal in account.journals { #expect(journal.pendingCount == 0) }
    }
}

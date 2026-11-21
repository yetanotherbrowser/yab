import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import SyncKit

/// The core of sync (PLAN-sync.md): stamps, records and their merge, keys
/// for order, trees put right, the journal and the seal. No network: devices
/// here are journals handing records to each other in random orders.
struct SyncKitTests {
    // MARK: Stamps

    @Test func stampsOrderByWallThenCountThenDevice() {
        let a = Stamp(wall: 1, count: 5, device: "b")
        let b = Stamp(wall: 2, count: 0, device: "a")
        let c = Stamp(wall: 2, count: 0, device: "b")
        #expect(a < b && b < c)
    }

    @Test func clockRunsAheadOfEverythingItSaw() {
        var wall: Int64 = 1000
        let clock = Clock(device: "m", now: { wall })
        let first = clock.tick()
        let second = clock.tick()
        #expect(second > first && second.wall == 1000 && second.count == 1)
        #expect(clock.observe(Stamp(wall: 5000, count: 3, device: "x")))
        let third = clock.tick()
        #expect(third > Stamp(wall: 5000, count: 3, device: "x"))
        wall = 9000
        #expect(clock.tick().wall == 9000)
    }

    @Test func clockDoesNotFollowAStampFromNextYear() {
        let clock = Clock(device: "m", now: { 1000 })
        #expect(!clock.observe(Stamp(wall: 1000 + Clock.drift + 1, device: "x")))
        #expect(clock.tick().wall == 1000)
    }

    // MARK: Records

    private func kinds() {
        Kind.register(Kind("test.tab", removalWins: true, rules: ["seen": .most, "visits": .perDevice], groups: [Kind.place]))
        Kind.register(Kind("test.mark", groups: [Kind.place]))
    }

    @Test func latestChangeToAFieldWins() {
        kinds()
        let a = Clock(device: "a", now: { 1 }), b = Clock(device: "b", now: { 2 })
        var x = Record(collection: "test.mark", id: "1")
        x.update(to: ["title": "Old"], clock: a)
        var y = x
        y.update(to: ["title": "New"], clock: b)
        #expect(x.merged(with: y)["title"] == "New")
        #expect(y.merged(with: x)["title"] == "New")
    }

    @Test func differentFieldsChangedApartBothStay() {
        kinds()
        let a = Clock(device: "a", now: { 5 }), b = Clock(device: "b", now: { 5 })
        var base = Record(collection: "test.mark", id: "1")
        base.update(to: ["title": "T", "url": "https://a.test"], clock: a)
        var x = base, y = base
        x.update(to: ["title": "Renamed", "url": "https://a.test"], clock: a)
        y.update(to: ["title": "T", "url": "https://b.test"], clock: b)
        let m = x.merged(with: y)
        #expect(m["title"] == "Renamed" && m["url"] == "https://b.test")
    }

    @Test func aPlaceMovesAsOne() {
        kinds()
        let a = Clock(device: "a", now: { 1 }), b = Clock(device: "b", now: { 2 })
        var base = Record(collection: "test.mark", id: "1")
        base.update(to: ["parent": "f1", "order": "V"], clock: a)
        var x = base, y = base
        x.update(to: ["parent": "f2", "order": "k"], clock: a)   // moved to another folder
        y.update(to: ["parent": "f1", "order": "a"], clock: b)   // moved within the first, later
        let m = x.merged(with: y)
        #expect(m["parent"] == "f1" && m["order"] == "a")
    }

    @Test func aClosedTabStaysClosedThoughMovedLater() {
        kinds()
        let a = Clock(device: "a", now: { 1 }), b = Clock(device: "b", now: { 9 })
        var base = Record(collection: "test.tab", id: "t")
        base.update(to: ["url": "https://a.test"], clock: a)
        var closed = base, moved = base
        closed.remove(at: a.tick())
        moved.update(to: ["url": "https://b.test"], clock: b)
        #expect(!closed.merged(with: moved).alive())
        #expect(!moved.merged(with: closed).alive())
        var again = closed
        let revived = again.update(to: ["url": "https://c.test"], clock: b)
        #expect(!revived)
    }

    @Test func aRemovedBookmarkComesBackOnlyByALaterChange() {
        kinds()
        let a = Clock(device: "a", now: { 5 }), b = Clock(device: "b", now: { 1 }), c = Clock(device: "c", now: { 9 })
        var base = Record(collection: "test.mark", id: "1")
        base.update(to: ["title": "T"], clock: b)
        var removed = base
        removed.remove(at: a.tick())
        var earlier = base
        earlier.update(to: ["title": "Earlier"], clock: b)
        #expect(!removed.merged(with: earlier).alive())
        var later = base
        later.update(to: ["title": "Later"], clock: c)
        let m = removed.merged(with: later)
        #expect(m.alive() && m["title"] == "Later")
    }

    @Test func seenIsTheLatestAndVisitsAddUp() {
        kinds()
        let a = Clock(device: "a", now: { 9 }), b = Clock(device: "b", now: { 1 })
        var base = Record(collection: "test.tab", id: "t")
        base.update(to: ["seen": 100, "visits": 2], clock: a)
        var x = base, y = base
        x.update(to: ["seen": 300, "visits": 3], clock: a)
        y.update(to: ["seen": 200, "visits": 4], clock: b)  // later seen on b, but b's clock is behind
        let m = x.merged(with: y)
        #expect(m["seen"] == 300)
        #expect(m.total("visits") == 7)
    }

    @Test func fieldsFromANewerYabPassThrough() {
        kinds()
        let a = Clock(device: "a", now: { 1 }), b = Clock(device: "b", now: { 2 })
        var newer = Record(collection: "test.mark", id: "1", schema: 3)
        newer.update(to: ["title": "T", "glow": .object(["hue": 3])], clock: b)
        var older = Record(collection: "test.mark", id: "1")
        older.update(to: ["title": "T"], clock: a)
        let m = older.merged(with: newer)
        #expect(m["glow"] == .object(["hue": 3]) && m.schema == 3)
    }

    // MARK: Order

    @Test func keysFallBetweenTheirNeighbors() {
        var keys = [Order.between(nil, nil)]
        var rng = Seeded(7)
        for _ in 0..<2000 {
            let i = Int.random(in: 0...keys.count, using: &rng)
            let key = Order.between(i > 0 ? keys[i - 1] : nil, i < keys.count ? keys[i] : nil)
            #expect(Order.valid(key))
            if i > 0 { #expect(keys[i - 1] < key) }
            if i < keys.count { #expect(key < keys[i]) }
            keys.insert(key, at: i)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }

    @Test func appendingAndPrependingStayShort() {
        var last: String?
        for _ in 0..<1000 { last = Order.between(last, nil) }
        #expect((last?.count ?? 0) < 40)
        var first: String?
        for _ in 0..<1000 {
            let key = Order.between(nil, first)
            #expect(Order.valid(key) && first.map { key < $0 } ?? true)
            first = key
        }
        #expect((first?.count ?? 0) < 40)
    }

    @Test func aSpreadIsInOrderAndShort() {
        let keys = Order.spread(300)
        #expect(keys.count == 300 && keys == keys.sorted() && Set(keys).count == 300)
        #expect(keys.allSatisfy { $0.count <= 3 })
        let inside = Order.spread(5, after: keys[10], before: keys[11])
        #expect(inside.allSatisfy { keys[10] < $0 && $0 < keys[11] })
    }

    @Test func assigningKeepsTheKeysOfWhatDidNotMove() {
        let ids = (0..<100).map { "t\($0)" }
        let first = Order.assign(ids, previous: [:])
        #expect(ids.map { first[$0]! } == ids.map { first[$0]! }.sorted())
        var moved = ids
        moved.insert(moved.remove(at: 70), at: 0)       // dragged to the top
        moved.insert("new", at: 50)                      // one opened in the middle
        let second = Order.assign(moved, previous: first)
        #expect(moved.map { second[$0]! } == moved.map { second[$0]! }.sorted())
        #expect(Set(moved.map { second[$0]! }).count == moved.count)
        let changed = moved.filter { second[$0] != first[$0] }
        #expect(Set(changed) == ["t70", "new"])
    }

    @Test func assigningRandomOrdersStaysSorted() {
        var rng = Seeded(3)
        var ids = (0..<40).map { "t\($0)" }
        var keys = Order.assign(ids, previous: [:])
        for round in 0..<200 {
            ids.shuffle(using: &rng)
            if round % 3 == 0 { ids.append("n\(round)") }
            if round % 5 == 0 { ids.removeFirst() }
            keys = Order.assign(ids, previous: keys)
            #expect(ids.map { keys[$0]! } == ids.map { keys[$0]! }.sorted())
            #expect(Set(ids.map { keys[$0]! }).count == ids.count)
        }
    }

    @Test func keysOutOfOrderStillGiveAKey() {
        let key = Order.between("k", "a")
        #expect(key > "k")
        #expect(Order.valid(Order.between("bad key!", nil)))
    }

    // MARK: Trees

    @Test func anOrphanGoesToTheFallback() {
        let nodes = [
            Tree.Node(id: "bar", parent: nil, order: "V"),
            Tree.Node(id: "a", parent: "bar", order: "V"),
            Tree.Node(id: "lost", parent: "gone", order: "V"),
        ]
        let fixes = Tree.repair(nodes, fallback: "bar")
        #expect(fixes.count == 1 && fixes[0].id == "lost" && fixes[0].parent == "bar" && fixes[0].order > "V")
    }

    @Test func aLoopIsCutAtTheOlderMove() {
        let nodes = [
            Tree.Node(id: "x", parent: "y", order: "V", moved: Stamp(wall: 5, device: "a")),
            Tree.Node(id: "y", parent: "x", order: "V", moved: Stamp(wall: 9, device: "b")),
        ]
        let fixes = Tree.repair(nodes)
        #expect(fixes.map(\.id) == ["x"] && fixes[0].parent == nil)
    }

    @Test func twinsGetKeysOfTheirOwn() {
        let nodes = ["a", "b", "c"].map { Tree.Node(id: $0, parent: nil, order: "V") } + [Tree.Node(id: "d", parent: nil, order: "k")]
        let fixes = Tree.repair(nodes)
        var by = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.order) })
        for fix in fixes { by[fix.id] = fix.order }
        #expect(Set(by.values).count == 4)
        #expect(["a", "b", "c", "d"].map { by[$0]! } == ["a", "b", "c", "d"].map { by[$0]! }.sorted())
    }

    // MARK: Journal

    @Test func reconcileStampsOnlyWhatChangedAndRemovesWhatIsGone() throws {
        kinds()
        let j = try Journal(path: nil, device: "a")
        let first = try j.reconcile("test.mark", ["1": ["title": "One"], "2": ["title": "Two"]])
        #expect(first.count == 2 && j.pending().count == 2)
        try j.sent(j.pending().map { ($0.record, 1) })
        #expect(j.pending().isEmpty)
        #expect(try j.reconcile("test.mark", ["1": ["title": "One"], "2": ["title": "Two"]]).isEmpty)
        let second = try j.reconcile("test.mark", ["1": ["title": "Uno"]])
        #expect(second.map(\.id) == ["1", "2"])
        #expect(j.living("test.mark").map(\.id) == ["1"])
        #expect(j.pending().allSatisfy { $0.version == 1 })
    }

    /// One chat's steps told to the journal, every chat's steps in it: only
    /// those under the chat's prefix are read and can go, a chat whose id
    /// only starts the same isn't touched, and a step given from outside the
    /// prefixes is read on its own, so it keeps its stamps.
    @Test func reconcileUnderPrefixesReadsAndRemovesOnlyThere() throws {
        kinds()
        let j = try Journal(path: nil, device: "a")
        try j.reconcile("test.mark", [
            "a/1": ["title": "A1"], "a/2": ["title": "A2"],
            "ab/1": ["title": "AB1"], "b/1": ["title": "B1"], "c/1": ["title": "C1"],
        ])
        try j.sent(j.pending().map { ($0.record, 1) })
        let c1 = j.record(Record.Key(collection: "test.mark", id: "c/1"))

        let changed = try j.reconcile("test.mark", ["a/1": ["title": "A1"], "c/1": ["title": "C1"]], under: ["a/"])
        #expect(changed.map(\.id) == ["a/2"])
        #expect(j.living("test.mark").map(\.id) == ["a/1", "ab/1", "b/1", "c/1"])
        #expect(j.record(Record.Key(collection: "test.mark", id: "c/1")) == c1)

        let renamed = try j.reconcile("test.mark", ["b/1": ["title": "Bee"]], under: ["b/"])
        #expect(renamed.map(\.id) == ["b/1"])
        #expect(j.living("test.mark").map(\.id) == ["a/1", "ab/1", "b/1", "c/1"])
    }

    @Test func whatCameFromElsewhereDoesNotEchoBack() throws {
        kinds()
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b")
        try a.reconcile("test.mark", ["1": ["title": "One"]])
        let changed = try b.receive(a.pending().map { ($0.record, 1) })
        #expect(changed.count == 1 && b.pending().isEmpty)
        // b's mirror writes it into its file and reports the file back.
        #expect(try b.reconcile("test.mark", ["1": ["title": "One"]]).isEmpty)
    }

    @Test func journalKeepsItsClockAcrossLaunches() throws {
        kinds()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var stamp: Stamp?
        do {
            let j = try Journal(path: path, device: "a")
            try j.change(Record.Key(collection: "test.mark", id: "1"), ["title": "T"])
            stamp = j.clock.latest
            j.cursor = 42
        }
        let again = try Journal(path: path, device: "a")
        #expect(again.clock.latest == stamp && again.cursor == 42)
        #expect(again.record(Record.Key(collection: "test.mark", id: "1"))?["title"] == "T")
    }

    @Test func aChangeHereBringsARecordRemovedElsewhereBackWhole() throws {
        kinds()
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b")
        let fields: [String: Value] = ["title": "One", "url": "https://one.test/"]
        try a.reconcile("test.mark", ["1": fields], shown: true)
        _ = try b.receive(a.pending().map { ($0.record, 1) })
        try b.reconcile("test.mark", ["1": fields], shown: true)
        // Removed on b; a's files still hold it, unchanged: no edit.
        try b.reconcile("test.mark", [:], shown: true)
        _ = try a.receive(b.pending().map { ($0.record, 2) })
        #expect(try a.reconcile("test.mark", ["1": fields], shown: true).isEmpty)
        // Then a changes one field: it comes back with all of them.
        var changed = fields
        changed["title"] = "One again"
        #expect(try a.reconcile("test.mark", ["1": changed], shown: true).count == 1)
        let back = try #require(a.record(Record.Key(collection: "test.mark", id: "1")))
        #expect(back.alive())
        #expect(back["url"] == "https://one.test/" && back["title"] == "One again")
    }

    @Test func aRemovalThatNowSaysWhyReachesTheMirrorAndAnEmptiedOneDoesNot() throws {
        kinds()
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b")
        try a.reconcile("test.mark", ["1": ["title": "One"]])
        _ = try b.receive(a.pending().map { ($0.record, 1) })
        try a.reconcile("test.mark", [:])
        _ = try b.receive(a.pending().map { ($0.record, 2) })
        // Marked, then removed again, as a visit deleted by hand is.
        try a.reconcile("test.mark", ["1": ["title": "One", "cut": 5]])
        try a.reconcile("test.mark", [:])
        let told = try b.receive(a.pending().map { ($0.record, 3) })
        #expect(told.map(\.id) == ["1"] && told.first?.alive() == false && told.first?.fields["cut"] == 5)
        // A change from before the removal, arriving late: nothing for it either.
        let c = try Journal(path: nil, device: "c")
        _ = try c.receive(b.all("test.mark").map { ($0, 3) })
        var late = try #require(c.all("test.mark").first)
        let was = try #require(late.stamps["title"])
        late.fields["title"] = "Older"
        late.stamps["title"] = Stamp(wall: was.wall, count: was.count, device: "d")
        #expect(try #require(late.stamps["title"]) < (try #require(late.deleted)))
        #expect(try c.receive([(late, 4)]).isEmpty)
        // Emptied after its removal: nothing for the mirror.
        #expect(try a.blankRemoved("test.mark") == 1)
        #expect(try b.receive(a.pending().map { ($0.record, 4) }).isEmpty)
    }

    @Test func aClosedTabSeenElsewhereSinceIsNoNews() throws {
        kinds()
        let a = try Journal(path: nil, device: "a"), b = try Journal(path: nil, device: "b"), c = try Journal(path: nil, device: "c")
        try a.reconcile("test.tab", ["1": ["title": "One", "seen": 1]])
        let first = a.pending().map { ($0.record, Int64(1)) }
        _ = try b.receive(first); _ = try c.receive(first)
        // Closed on a, then seen on b before b heard of it.
        try a.remove(Record.Key(collection: "test.tab", id: "1"))
        try b.change(Record.Key(collection: "test.tab", id: "1"), ["seen": 9])
        #expect(try c.receive(a.pending().map { ($0.record, 2) }).count == 1)
        let seen = b.pending().map { ($0.record, Int64(3)) }
        _ = try c.receive(seen)
        // Delivered again, as a catch-up does: nothing new.
        #expect(try c.receive(seen).isEmpty)
    }

    @Test func aStampTakenForAChangeOutsideTheJournalSurvivesARelaunch() throws {
        kinds()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID()).sqlite").path
        defer { for end in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + end) } }
        var stamp: Stamp?
        do {
            let j = try Journal(path: path, device: "a")
            try j.change(Record.Key(collection: "test.mark", id: "1"), ["title": "T"])
            // A clear's fence (ContextPrivacy), with no record changed after it.
            stamp = j.tick()
        }
        let again = try Journal(path: path, device: "a")
        #expect(again.clock.latest == stamp)
        #expect(again.clock.tick() > stamp!)
    }

    @Test func aReconcileThatChangesNothingWritesNothing() throws {
        kinds()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID()).sqlite").path
        defer { for end in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + end) } }
        let journal = try Journal(path: path, device: "a")
        try journal.reconcile("test.mark", ["1": ["title": "One"]])
        try journal.reconcile("test.mark", ["1": ["title": "One"]], shown: true)
        // A second connection sees the file's data version move only when
        // another one commits a change to it.
        var other: OpaquePointer?
        #expect(sqlite3_open(path, &other) == SQLITE_OK)
        defer { sqlite3_close(other) }
        func version() -> Int64 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(other, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int64(statement, 0)
        }
        func wal() -> Int { ((try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? Int) ?? -1 }
        let before = version(), written = wal()
        #expect(try journal.reconcile("test.mark", ["1": ["title": "One"]]).isEmpty)
        #expect(try journal.reconcile("test.mark", ["1": ["title": "One"]], shown: true).isEmpty)
        #expect(version() == before)
        #expect(wal() == written)
        try journal.reconcile("test.mark", ["1": ["title": "Two"]])
        #expect(version() != before)
        #expect(wal() > written)
    }

    // MARK: Convergence

    /// Three devices edit, move and remove the same handful of records
    /// while apart, then hand each other everything in random orders, some
    /// twice. Each run must end with all three holding the same records.
    @Test(arguments: 0..<300)
    func devicesApartAgreeOnceTheyMeet(seed: UInt64) throws {
        kinds()
        var rng = Seeded(seed)
        let devices = try ["a", "b", "c"].map { try Journal(path: nil, device: $0) }
        let ids = (0..<6).map { "r\($0)" }
        let collections = ["test.tab", "test.mark"]
        var server: [Record.Key: Record] = [:]

        func push(_ j: Journal) throws {
            let sent = j.pending()
            for (record, _) in sent {
                server[record.key] = server[record.key].map { $0.merged(with: record) } ?? record
            }
            try j.sent(sent.map { ($0.record, 1) })
        }
        func pull(_ j: Journal) throws {
            var all = Array(server.values)
            all.shuffle(using: &rng)
            if let one = all.first { all.append(one) }   // a duplicate delivery
            _ = try j.receive(all.map { ($0, 1) })
        }

        for _ in 0..<40 {
            let j = devices.randomElement(using: &rng)!
            let key = Record.Key(collection: collections.randomElement(using: &rng)!, id: ids.randomElement(using: &rng)!)
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                try j.change(key, ["title": .string("t\(Int.random(in: 0..<5, using: &rng))")])
            case 4...5:
                try j.change(key, ["parent": .string("p\(Int.random(in: 0..<2, using: &rng))"), "order": .string(Order.between(nil, nil))])
            case 6:
                try j.change(key, ["seen": .number(Double(Int.random(in: 0..<100, using: &rng))), "visits": .number(Double(Int.random(in: 1..<5, using: &rng)))])
            case 7:
                try j.remove(key)
            case 8:
                try push(j)
            default:
                try pull(j)
            }
        }
        for j in devices { try push(j) }
        for j in devices { try pull(j) }
        for j in devices { try push(j) }
        for j in devices { try pull(j) }

        for collection in collections {
            let views = devices.map { j in j.all(collection).map { [$0.id: $0.visible as AnyHashable, "alive": $0.alive()] as [String: AnyHashable] } }
            #expect(views[0] == views[1] && views[1] == views[2], "seed \(seed) \(collection)")
        }
        #expect(devices.allSatisfy { $0.pending().isEmpty })
    }

    // MARK: Seal

    @Test func aSecretOpensOnlyInItsOwnRecordWithTheKey() throws {
        let seal = Seal.make()
        let key = Record.Key(collection: "login", id: "site.test\u{1}me")
        let hidden = try seal.hide(Data("hunter2".utf8), in: key)
        #expect(!hidden.contains("hunter2"))
        #expect(seal.reveal(hidden, in: key) == Data("hunter2".utf8))
        // A new box each time, the same secret inside.
        #expect(try seal.hide(Data("hunter2".utf8), in: key) != hidden)
        #expect(seal.reveal(hidden, in: Record.Key(collection: "login", id: "other.test\u{1}me")) == nil)
        #expect(Seal.make().reveal(hidden, in: key) == nil)
        #expect(seal.reveal("not a box", in: key) == nil)
    }

    @Test func aSealedRecordOpensOnlyUnderItsName() throws {
        let seal = Seal.make()
        var record = Record(collection: "bookmark", id: "1")
        record.update(to: ["url": "https://secret.test/path"], clock: Clock(device: "a"))
        let box = try seal.seal(record)
        #expect(!String(decoding: box, as: UTF8.self).contains("secret"))
        let name = seal.name(record.key)
        #expect(!name.contains("bookmark"))
        #expect(try seal.open(box, name: name) == record)
        #expect(throws: (any Error).self) { try seal.open(box, name: seal.name(Record.Key(collection: "bookmark", id: "2"))) }
        let other = Seal.make()
        #expect(throws: (any Error).self) { try other.open(box, name: name) }
        #expect(Seal(raw: seal.raw)?.name(record.key) == name)
    }
}

/// A random number generator that gives the same numbers for the same seed,
/// so a failing run can be run again.
struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

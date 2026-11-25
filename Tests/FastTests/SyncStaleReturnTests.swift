import Foundation
import Testing
import SyncKit
@testable import Fast

/// Register 2589 (feedback #2032): a Mac away for two weeks comes back and
/// its old pins must not undo what the other Mac did meanwhile. A is only a
/// journal; B is this test's Store (its spaces and session files), taking
/// the catch-up page by page as SyncCenter's delivery does: its rows told to
/// the journal first, the page merged, the page written into its files.
@MainActor
@Suite(.serialized, .spacesListAlone)
struct SyncStaleReturnTests {
    init() { SyncShapes.register() }

    /// Each test's own B: the first space alone, its row and the shared
    /// pins' row empty, and what the test world held before put back byte
    /// for byte after. The first space's row is session.json, the session
    /// there always was, which `Session.erase` never removes; a test that
    /// only erased its spaces' rows left its pins there, and the next test
    /// took them for B's own (register 2589's card, retired from 0.46.34).
    @MainActor private final class World {
        static let first = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)
        private static var files: [URL] {
            ["spaces.json", "session.json", "session-\(Space.pinsID.uuidString).json"].map(Store.file)
        }
        private let kept: [URL: Data]
        private let settings: (spaces: Any?, every: Any?)

        init(sharedPins: Bool) {
            Session.settle()
            kept = Dictionary(uniqueKeysWithValues: World.files.compactMap { url in (try? Data(contentsOf: url)).map { (url, $0) } })
            settings = (Store.settings.object(forKey: "spaces"), Store.settings.object(forKey: SharedPins.key))
            Store.settings.set(true, forKey: "spaces")
            Store.settings.set(sharedPins, forKey: SharedPins.key)
            Spaces.write([World.first])
            Session.write(now: true, space: Space.firstID, .init(tabs: [], front: nil))
            Session.erase(space: Space.pinsID)
            Session.settle()
        }

        /// The rows of the spaces the test was given, then the files and
        /// settings as they were.
        func close() {
            Session.settle()
            for space in Spaces.read() where space.id != Space.firstID { Session.erase(space: space.id) }
            for url in World.files {
                if let data = kept[url] { try? data.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            }
            if let value = settings.spaces { Store.settings.set(value, forKey: "spaces") } else { Store.settings.removeObject(forKey: "spaces") }
            if let value = settings.every { Store.settings.set(value, forKey: SharedPins.key) } else { Store.settings.removeObject(forKey: SharedPins.key) }
        }
    }

    /// The server as sync-server keeps it: the latest of each record, a
    /// version per record and one sequence per account.
    final class Wire {
        var items: [Record.Key: (record: Record, version: Int64, seq: Int64)] = [:]
        var seq: Int64 = 0

        /// What a device has made and not sent, taken when its base is the
        /// server's version; the others come back as conflicts.
        func push(_ journal: Journal) throws -> [(record: Record, version: Int64)] {
            var taken: [(record: Record, version: Int64)] = [], conflicts: [(record: Record, version: Int64)] = []
            for (record, base) in journal.pending(limit: 100_000) {
                let have = items[record.key]
                if (have?.version ?? 0) == base {
                    seq += 1
                    items[record.key] = (record, base + 1, seq)
                    taken.append((record, base + 1))
                } else if let have {
                    conflicts.append((have.record, have.version))
                }
            }
            try journal.sent(taken)
            return conflicts
        }

        /// The catch-up after `cursor`, in pages of `page`, by sequence.
        func pages(after cursor: Int64, page: Int = 500) -> [[(record: Record, version: Int64)]] {
            let after = items.values.filter { $0.seq > cursor }.sorted { $0.seq < $1.seq }
            return stride(from: 0, to: after.count, by: page).map { at in
                after[at..<min(at + page, after.count)].map { ($0.record, $0.version) }
            }
        }
    }

    /// B's rows as SyncCenter reads them: each space's file, the first
    /// space's with the shared pins folded in while they head it.
    private func localRows() -> [UUID: Session.Shape] {
        SyncCenter.rows(Spaces.read().map(\.id), pinsShown: SharedPins.sentAsFirst)
    }

    private func orders(_ collection: String, in journal: Journal) -> [String: String] {
        Dictionary(journal.living(collection).compactMap { record in record["order"]?.string.map { (record.id, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// A's files told to its journal, as A's flush does.
    private func tell(_ a: Journal, spaces: [Space], rows: [UUID: Session.Shape]) throws {
        try a.reconcile(SyncShapes.space, SyncShapes.spaces(spaces, orders: orders(SyncShapes.space, in: a)))
        let out = SyncShapes.rows(rows, orders: orders(SyncShapes.tab, in: a), device: "mac-a")
        try a.reconcile(SyncShapes.tab, out.tabs)
        try a.reconcile(SyncShapes.folder, out.folders)
        try a.reconcile(SyncShapes.pair, out.pairs)
    }

    /// B's line: what B's files say told to its journal before the hello,
    /// the catch-up page by page, then what B made goes up, its conflicts
    /// merged on B as the client's are (they come through the same delivery).
    private func comeBack(_ b: Journal, cursor: inout Int64, wire: Wire, center: SyncCenter) throws {
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        for page in wire.pages(after: cursor) {
            let changed = try SyncCenter.receive(page, into: b, localRows: localRows(), device: "mac-b")
            center.adopt(changed, from: b)
        }
        cursor = wire.seq
        for _ in 0..<4 {
            let conflicts = try wire.push(b)
            if conflicts.isEmpty { break }
            let changed = try SyncCenter.receive(conflicts, into: b, localRows: localRows(), device: "mac-b")
            center.adopt(changed, from: b)
        }
        // A save of B's rows after it all: nothing more of A's may go.
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        _ = try wire.push(b)
    }

    private func pins(_ journal: Journal) -> [String] {
        journal.living(SyncShapes.tab).filter { $0["pin"] != nil }
            .sorted { ($0["parent"]?.string ?? "", $0["order"]?.string ?? "", $0.id) < ($1["parent"]?.string ?? "", $1["order"]?.string ?? "", $1.id) }
            .compactMap { $0["url"]?.string }
    }

    private func scenario(shared: Bool) throws {
        #expect(Store.testing)
        let world = World(sharedPins: shared)
        defer { world.close() }
        let home = [World.first]
        let work = Space(id: UUID(), name: "Work", icon: "W", ownSignIns: false)
        let first = Space.firstID
        func pin(_ name: String, _ id: String) -> Session.Entry {
            .init(url: "https://\(name).stale.test/", title: name, pin: String(name.prefix(1)).uppercased(), id: id)
        }
        let ids = (0..<12).map { _ in UUID().uuidString }
        let wire = Wire()
        let a = try Journal(path: nil, device: "mac-a")
        let b = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()

        // Both Macs have three pins in the first space.
        var aSpaces = home
        var aRows: [UUID: Session.Shape] = [first: .init(tabs: [pin("mail", ids[0]), pin("cal", ids[1]), pin("music", ids[2])], active: 0)]
        try tell(a, spaces: aSpaces, rows: aRows)
        _ = try wire.push(a)
        var cursor: Int64 = 0
        try comeBack(b, cursor: &cursor, wire: wire, center: center)
        _ = try a.receive(wire.pages(after: 0).flatMap { $0 })
        var aCursor = wire.seq
        #expect(pins(b) == pins(a))
        #expect(localRows()[first]?.tabs.compactMap(\.id).filter { ids.contains($0) } == [ids[0], ids[1], ids[2]])

        // B goes away. Over two weeks A adds pins, moves them about and
        // takes one away, makes a space with pins of its own and renames it
        // later, and browses (history, so the catch-up runs to pages).
        aRows[first] = .init(tabs: [pin("cal", ids[1]), pin("mail", ids[0]), pin("docs", ids[3]), pin("figma", ids[4])], active: 0)
        try tell(a, spaces: aSpaces, rows: aRows)
        _ = try wire.push(a)
        aSpaces = home + [work]
        aRows[work.id] = .init(tabs: [pin("jira", ids[5]), pin("slack", ids[6])], active: 0)
        try tell(a, spaces: aSpaces, rows: aRows)
        _ = try wire.push(a)
        for n in 0..<700 {
            try a.change(.init(collection: SyncShapes.visit, id: "page-\(n).stale.test"),
                         ["url": .string("https://page-\(n).stale.test/"), "title": .string("Page \(n)"), "last": .number(Date().timeIntervalSince1970)])
        }
        _ = try wire.push(a)
        aRows[first] = .init(tabs: [pin("cal", ids[1]), pin("mail", ids[0]), pin("docs", ids[3]), pin("figma", ids[4]), pin("linear", ids[7])], active: 0)
        try tell(a, spaces: aSpaces, rows: aRows)
        _ = try wire.push(a)
        var renamed = work
        renamed.name = "Work and clients"
        aSpaces = home + [renamed]
        try tell(a, spaces: aSpaces, rows: aRows)
        _ = try wire.push(a)
        let want = pins(a)
        #expect(want.count == 7)

        // B, with its two-week-old files and journal, comes back.
        try comeBack(b, cursor: &cursor, wire: wire, center: center)
        _ = try a.receive(wire.pages(after: aCursor).flatMap { $0 })
        aCursor = wire.seq
        #expect(pins(a) == want, "A's pins after B came back")
        #expect(pins(b) == want, "B's pins after it came back")
        let shown = Set(Spaces.read().flatMap { SharedPins.syncRow($0.id, pinsShown: SharedPins.on).tabs.filter { $0.pin != nil }.map(\.url) })
        #expect(shown == Set(want), "B's files show A's pins")
    }

    /// The catch-up of two weeks runs for a while, and an idle Mac relaunches
    /// for the update it just downloaded (Updater.restartWhenAway): a page
    /// is in the journal, its rows not yet in the files. At the relaunch the
    /// files are older than the journal, and must not be taken for edits.
    @Test func aRelaunchBetweenThePageAndItsRowsKeepsTheOtherMacsPins() throws {
        #expect(Store.testing)
        let world = World(sharedPins: false)
        defer { world.close() }
        let home = [World.first]
        let first = Space.firstID
        func pin(_ name: String, _ id: String) -> Session.Entry {
            .init(url: "https://\(name).stale.test/", title: name, pin: String(name.prefix(1)).uppercased(), id: id)
        }
        let ids = (0..<6).map { _ in UUID().uuidString }
        let wire = Wire()
        let a = try Journal(path: nil, device: "mac-a")
        let b = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()
        try tell(a, spaces: home, rows: [first: .init(tabs: [pin("mail", ids[0]), pin("cal", ids[1])], active: 0)])
        _ = try wire.push(a)
        var cursor: Int64 = 0
        try comeBack(b, cursor: &cursor, wire: wire, center: center)
        _ = try a.receive(wire.pages(after: 0).flatMap { $0 })
        let aCursor = wire.seq

        // Away: A sets up three more pins and moves one.
        try tell(a, spaces: home, rows: [first: .init(tabs: [pin("cal", ids[1]), pin("docs", ids[2]), pin("mail", ids[0]),
                                                                 pin("figma", ids[3]), pin("jira", ids[4])], active: 0)])
        _ = try wire.push(a)
        let want = pins(a)

        // Back: the page goes into the journal, and Yab quits before its rows
        // are written (no adopt).
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        for page in wire.pages(after: cursor) {
            _ = try SyncCenter.receive(page, into: b, localRows: localRows(), device: "mac-b")
        }
        // The relaunch: its files told to the journal before the hello, the
        // catch-up again from the cursor it had (it never moved), then up.
        // What the journal holds and the files never drew is drawn
        // (SyncCenter.drawUnshown, after begin's flush).
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        center.adopt([SyncShapes.tab, SyncShapes.folder, SyncShapes.pair].flatMap { b.unshown($0) }, from: b)
        for page in wire.pages(after: cursor) {
            let changed = try SyncCenter.receive(page, into: b, localRows: localRows(), device: "mac-b")
            center.adopt(changed, from: b)
        }
        cursor = wire.seq
        for _ in 0..<4 {
            let conflicts = try wire.push(b)
            if conflicts.isEmpty { break }
            center.adopt(try SyncCenter.receive(conflicts, into: b, localRows: localRows(), device: "mac-b"), from: b)
        }
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        _ = try wire.push(b)
        _ = try a.receive(wire.pages(after: aCursor).flatMap { $0 })
        #expect(pins(a) == want, "A's pins after B's relaunch")
        #expect(pins(b) == want, "B's pins after its relaunch")
        #expect(localRows()[first]?.tabs.filter { $0.pin != nil }.map(\.url) == want, "B's files show them after its relaunch")
    }

    /// What the person does here still goes: a pin that just came, closed
    /// once its row is drawn (the flush right after adopt reads it back),
    /// a pin renamed, and one moved.
    @Test func editsMadeHereStillGoUp() throws {
        #expect(Store.testing)
        let world = World(sharedPins: false)
        defer { world.close() }
        let home = [World.first]
        let first = Space.firstID
        func pin(_ name: String, _ id: String) -> Session.Entry {
            .init(url: "https://\(name).stale.test/", title: name, pin: String(name.prefix(1)).uppercased(), id: id)
        }
        let ids = (0..<4).map { _ in UUID().uuidString }
        let wire = Wire()
        let a = try Journal(path: nil, device: "mac-a")
        let b = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()
        try tell(a, spaces: home, rows: [first: .init(tabs: [pin("mail", ids[0]), pin("cal", ids[1]), pin("docs", ids[2])], active: 0)])
        _ = try wire.push(a)
        var cursor: Int64 = 0
        try comeBack(b, cursor: &cursor, wire: wire, center: center)
        // A new pin from A, drawn here, then read back as the app does.
        try tell(a, spaces: home, rows: [first: .init(tabs: [pin("mail", ids[0]), pin("cal", ids[1]), pin("docs", ids[2]), pin("jira", ids[3])], active: 0)])
        _ = try wire.push(a)
        try comeBack(b, cursor: &cursor, wire: wire, center: center)
        #expect(Session.read(space: first).tabs.compactMap(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        // Here: jira closed, mail renamed, docs moved to the front.
        var row = Session.read(space: first)
        row.tabs.removeAll { $0.id == ids[3] }
        if let at = row.tabs.firstIndex(where: { $0.id == ids[0] }) { row.tabs[at].name = "Inbox" }
        if let at = row.tabs.firstIndex(where: { $0.id == ids[2] }) { row.tabs.insert(row.tabs.remove(at: at), at: 0) }
        Session.write(now: true, space: first, row)
        _ = try SyncCenter.receive([], into: b, localRows: localRows(), device: "mac-b")
        #expect(b.record(.init(collection: SyncShapes.tab, id: ids[3]))?.alive() == false, "a pin closed here is removed")
        #expect(b.record(.init(collection: SyncShapes.tab, id: ids[0]))?["name"]?.string == "Inbox", "a name given here goes")
        #expect(pins(b) == ["https://docs.stale.test/", "https://mail.stale.test/", "https://cal.stale.test/"], "a move made here goes")
    }

    // MARK: #909, pins gone from Personal on the Mac, still on the iPhone

    /// The spaces as this Mac's flush tells them to its journal.
    private func tellSpaces(_ journal: Journal) throws {
        try journal.reconcile(SyncShapes.space, SyncShapes.spaces(Spaces.read(), orders: orders(SyncShapes.space, in: journal)))
    }

    /// The pins this Mac shows in Personal: its own, and the shared ones
    /// while a window shows them there (Browser.showsShared), read by a
    /// window made now.
    private func macShows() -> Set<String> {
        let shared = macShowsShared() ? Session.read(space: Space.pinsID).tabs.map(\.url) : []
        return Set(shared + Session.read(space: Space.firstID).tabs.filter { $0.pin != nil }.map(\.url))
    }

    /// Whether a window made now shows the shared pins in Personal.
    private func macShowsShared() -> Bool {
        let id = UUID()
        let window = Browser(windowID: id)
        defer {
            window.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        return window.showsShared(Space.firstID)
    }

    /// #909: Settings › Spaces › Personal › Sign-ins › Its own on the iPhone,
    /// with Pins In Every Space on the Mac. The Mac stopped showing the
    /// shared pins in Personal and went on sending them as its pins, so the
    /// iPhone kept them; one pinned again in Personal was taken out of it
    /// at the next change of Personal's from the iPhone.
    @Test func personalGivenItsOwnSignInsOnThePhoneKeepsItsPinsOnTheMac() throws {
        #expect(Store.testing)
        let world = World(sharedPins: true)
        defer { world.close() }
        let first = Space.firstID
        func pin(_ name: String, _ id: String) -> Session.Entry {
            .init(url: "https://\(name).909.test/", title: name, pin: String(name.prefix(1)).uppercased(), id: id)
        }
        let ids = (0..<3).map { _ in UUID().uuidString }
        Session.write(now: true, space: Space.pinsID, .init(tabs: [pin("mail", ids[0]), pin("cal", ids[1])], active: 0))
        let wire = Wire()
        let mac = try Journal(path: nil, device: "mac-b")
        let phone = try Journal(path: nil, device: "phone")
        let center = SyncCenter()
        var cursor: Int64 = 0
        try tellSpaces(mac)
        try comeBack(mac, cursor: &cursor, wire: wire, center: center)
        _ = try phone.receive(wire.pages(after: 0).flatMap { $0 })
        var phoneCursor = wire.seq
        #expect(Set(pins(phone)) == ["https://mail.909.test/", "https://cal.909.test/"])
        #expect(macShows() == Set(pins(phone)))

        // The iPhone gives Personal its own sign-ins (PhoneSync.setSpaceSignIns).
        try phone.change(.init(collection: SyncShapes.space, id: first.uuidString), ["ownSignIns": .bool(true), "signInWith": .null])
        _ = try wire.push(phone)
        try comeBack(mac, cursor: &cursor, wire: wire, center: center)
        try tellSpaces(mac)
        _ = try wire.push(mac)
        _ = try phone.receive(wire.pages(after: phoneCursor).flatMap { $0 })
        phoneCursor = wire.seq
        #expect(macShows() == Set(pins(phone)), "the Mac shows in Personal the pins the iPhone lists there")
        #expect(Spaces.read().first(where: \.isFirst)?.ownSignIns == false, "Personal shares sign-ins on the Mac")
        #expect(phone.record(.init(collection: SyncShapes.space, id: first.uuidString))?["ownSignIns"]?.bool == false,
                "the account hears that Personal shares")

        // Pinned again in Personal on the Mac: a shared pin while Personal
        // shows them (Browser.settleShared), Personal's own otherwise.
        let docs = pin("docs", ids[2])
        if macShowsShared() {
            var shared = Session.read(space: Space.pinsID)
            shared.tabs.append(docs)
            Session.write(now: true, space: Space.pinsID, shared)
        } else {
            var row = Session.read(space: first)
            row.tabs.insert(docs, at: 0)
            Session.write(now: true, space: first, row)
        }
        try comeBack(mac, cursor: &cursor, wire: wire, center: center)
        _ = try phone.receive(wire.pages(after: phoneCursor).flatMap { $0 })
        phoneCursor = wire.seq
        // Then the iPhone opens a page in Personal.
        let page = UUID().uuidString
        try phone.change(.init(collection: SyncShapes.tab, id: page),
                         SyncTab(id: page, space: first.uuidString, order: "Z", url: "https://news.909.test/", title: "News").fields)
        _ = try wire.push(phone)
        try comeBack(mac, cursor: &cursor, wire: wire, center: center)
        _ = try phone.receive(wire.pages(after: phoneCursor).flatMap { $0 })
        let all: Set<String> = ["https://mail.909.test/", "https://cal.909.test/", "https://docs.909.test/"]
        #expect(Set(pins(phone)) == all)
        #expect(macShows() == all, "a pin made again in Personal stays there on the Mac")
    }

    /// Shared pins left in their file with Pins In Each Space (turned off by
    /// sync while no window was open): hidden on the Mac but sent as
    /// Personal's, so only the iPhone showed them. They are Personal's now,
    /// shown where they are sent, none lost.
    @Test func sharedPinsLeftBehindWithPinsOffGoToPersonalOnTheMacToo() throws {
        #expect(Store.testing)
        let world = World(sharedPins: false)
        defer { world.close() }
        let first = Space.firstID
        func pin(_ name: String) -> Session.Entry {
            .init(url: "https://\(name).909.test/", title: name, pin: String(name.prefix(1)).uppercased(), id: UUID().uuidString)
        }
        Session.write(now: true, space: Space.pinsID, .init(tabs: [pin("mail")], active: 0))
        Session.write(now: true, space: first, .init(tabs: [pin("docs")], active: 0))
        let wire = Wire()
        let mac = try Journal(path: nil, device: "mac-b")
        let phone = try Journal(path: nil, device: "phone")
        var cursor: Int64 = 0
        try tellSpaces(mac)
        try comeBack(mac, cursor: &cursor, wire: wire, center: SyncCenter())
        _ = try phone.receive(wire.pages(after: 0).flatMap { $0 })
        #expect(Set(pins(phone)) == ["https://mail.909.test/", "https://docs.909.test/"], "none lost")
        #expect(macShows() == Set(pins(phone)), "the Mac shows in Personal the pins the iPhone lists there")
    }

    @Test func aMacBackFromTwoWeeksKeepsTheOtherMacsPinsEachSpace() throws {
        try scenario(shared: false)
    }

    @Test func aMacBackFromTwoWeeksKeepsTheOtherMacsPinsEverySpace() throws {
        try scenario(shared: true)
    }
}

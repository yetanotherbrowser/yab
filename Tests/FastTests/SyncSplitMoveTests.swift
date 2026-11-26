import Foundation
import Testing
import SyncKit
@testable import Fast

/// A split view moved to another space by an iPhone comes one record at a
/// time: its first tab, its second, then the pair (PhoneSync.move). A live
/// Mac takes each in its own delivery, draws its rows in between and tells
/// the journal what they show before the next (SyncCenter.receive).
@MainActor
@Suite(.serialized, .spacesListAlone)
struct SyncSplitMoveTests {
    init() { SyncShapes.register() }

    @Test func aSplitViewMovedARecordAtATimeStaysASplitView() throws {
        #expect(Store.testing)
        let original = Spaces.read()
        let copy = Space(id: UUID(), name: "Copy", icon: "C", ownSignIns: false)
        let home = Space(id: UUID(), name: "Home", icon: "H", ownSignIns: false)
        defer {
            Spaces.write(original)
            for space in [copy, home] { Session.erase(space: space.id) }
        }
        Spaces.write(original + [copy, home])
        for space in [copy, home] { Session.write(now: true, space: space.id, .init(tabs: [], front: nil)) }
        let phone = try Journal(path: nil, device: "phone")
        let mac = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()
        var version: Int64 = 0
        func rows() -> [UUID: Session.Shape] {
            [copy.id: SharedPins.syncRow(copy.id), home.id: SharedPins.syncRow(home.id)]
        }
        func deliver(_ keys: [Record.Key]) throws {
            version += 1
            let items = try keys.map { (record: try #require(phone.record($0)), version: version) }
            center.adopt(try SyncCenter.receive(items, into: mac, localRows: rows(), device: "mac-b"), from: mac)
        }
        func save() throws { _ = try SyncCenter.receive([], into: mac, localRows: rows(), device: "mac-b") }

        let one = UUID().uuidString, two = UUID().uuidString
        let row = Session.Shape(tabs: [
            .init(url: "https://split.test/one", title: "One", kept: true, id: one),
            .init(url: "https://split.test/two", title: "Two", kept: true, id: two),
        ], active: 0, pairs: [.init(first: 0, second: 1, share: 0.4)])
        let out = SyncShapes.rows([copy.id: row], orders: [:], device: "phone")
        try phone.reconcile(SyncShapes.tab, out.tabs)
        try phone.reconcile(SyncShapes.pair, out.pairs)
        let tabOne = Record.Key(collection: SyncShapes.tab, id: one), tabTwo = Record.Key(collection: SyncShapes.tab, id: two)
        let pair = Record.Key(collection: SyncShapes.pair, id: "\(one)|\(two)")
        try save()
        try deliver([tabOne, tabTwo, pair])
        try save()
        #expect(Session.read(space: copy.id).pairs?.first?.share == 0.4, "the Mac shows the split view")

        func move(to space: Space, order: [Record.Key]) throws {
            for key in [tabOne, tabTwo, pair] { try phone.change(key, ["parent": .string(space.id.uuidString)]) }
            for key in order { try deliver([key]) }
            try save()
            let mine = try #require(mac.record(pair))
            #expect(mine.alive(), "the split view is not removed on the way")
            #expect(mine["parent"]?.string == space.id.uuidString)
            let shown = Session.read(space: space.id)
            #expect(Set(shown.tabs.compactMap(\.id)) == [one, two])
            #expect(shown.pairs?.first?.share == 0.4, "the Mac shows it in \(space.name)")
            version += 1
            _ = try phone.receive(mac.pending().map { ($0.record, version) })
            #expect(phone.record(pair)?.alive() == true, "nor on the iPhone")
        }
        // As the iPhone writes them, then the repair run again the other way
        // with the pair first, as no order on the wire is promised.
        try move(to: home, order: [tabOne, tabTwo, pair])
        try move(to: copy, order: [pair, tabOne, tabTwo])

        // Closed on the Mac, the split view still goes.
        var closed = Session.read(space: copy.id)
        closed.pairs = nil
        Session.write(now: true, space: copy.id, closed)
        try save()
        #expect(mac.record(pair)?.alive() == false)
    }
}

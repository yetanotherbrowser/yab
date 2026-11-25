import Foundation
import Testing
@testable import Fast

/// The recovery migration that hands shared pins left in their file back to
/// a space (#909, #916): the pins' file is cleared only after the space's
/// row with them is saved, and a pin the space already has is not doubled.
@Suite struct PinsHandBackTests {
    struct Failed: Error {}

    /// Rows in memory, a save to `failing` refused.
    final class Rows {
        var shapes: [UUID: Session.Shape]
        var failing: UUID?
        init(_ shapes: [UUID: Session.Shape], failing: UUID? = nil) {
            self.shapes = shapes
            self.failing = failing
        }
        var rows: PinsHandBack.Rows {
            PinsHandBack.Rows(
                read: { [unowned self] in shapes[$0] ?? Session.Shape(tabs: [], front: nil) },
                save: { [unowned self] space, shape in
                    if space == failing { throw Failed() }
                    shapes[space] = shape
                })
        }
    }

    static let home = UUID()

    static func pin(_ id: String, _ letter: String = "a") -> Session.Entry {
        Session.Entry(url: "https://\(id).example/", title: id, pin: letter, id: id)
    }

    static func tab(_ id: String) -> Session.Entry {
        Session.Entry(url: "https://\(id).example/", title: id, id: id)
    }

    @Test func overlappingIDsMergeWithoutDoublingOrDropping() {
        // A run that saved home and stopped before clearing the pins' file:
        // "b" is in both.
        let pins = Session.Shape(tabs: [Self.pin("a"), Self.pin("b"), Self.pin("c")], front: nil,
                                 pairs: [Session.Pair(first: 0, second: 2, share: 0.5)])
        let home = Session.Shape(tabs: [Self.pin("b"), Self.tab("x")], front: 1)
        let rows = Rows([Space.pinsID: pins, Self.home: home])

        #expect(PinsHandBack.run(to: Self.home, rows: rows.rows))

        let row = rows.shapes[Self.home]!
        #expect(row.tabs.compactMap(\.id) == ["a", "c", "b", "x"])
        #expect(row.tabs.map(\.pin) == ["a", "a", "a", nil])
        // The pair between "a" and "c" follows them past the dropped copy.
        #expect(row.pairs?.map { [$0.first, $0.second] } == [[0, 1]])
        // Still on "x".
        #expect(row.front == 3)
        #expect(rows.shapes[Space.pinsID]!.tabs.isEmpty)
    }

    @Test func pinsWithoutIDsAreAllKept() {
        var loose = Self.pin("a"); loose.id = nil
        let rows = Rows([Space.pinsID: .init(tabs: [loose], front: nil),
                         Self.home: .init(tabs: [Self.tab("x")], front: 0)])
        #expect(PinsHandBack.run(to: Self.home, rows: rows.rows))
        #expect(rows.shapes[Self.home]!.tabs.map(\.url) == ["https://a.example/", "https://x.example/"])
    }

    @Test func failedHomeSaveKeepsThePins() {
        let pins = Session.Shape(tabs: [Self.pin("a"), Self.pin("b")], front: nil)
        let home = Session.Shape(tabs: [Self.tab("x")], front: 0)
        let rows = Rows([Space.pinsID: pins, Self.home: home], failing: Self.home)

        #expect(!PinsHandBack.run(to: Self.home, rows: rows.rows))

        #expect(rows.shapes[Space.pinsID]!.tabs.compactMap(\.id) == ["a", "b"])
        #expect(rows.shapes[Self.home]!.tabs.compactMap(\.id) == ["x"])

        // Saved on the next run: once, and the pins' file cleared.
        rows.failing = nil
        #expect(PinsHandBack.run(to: Self.home, rows: rows.rows))
        #expect(rows.shapes[Self.home]!.tabs.compactMap(\.id) == ["a", "b", "x"])
        #expect(rows.shapes[Space.pinsID]!.tabs.isEmpty)
    }

    @Test func failedClearLeavesNoDoubleOnTheNextRun() {
        let pins = Session.Shape(tabs: [Self.pin("a")], front: nil)
        let rows = Rows([Space.pinsID: pins, Self.home: .init(tabs: [Self.tab("x")], front: 0)],
                        failing: Space.pinsID)
        #expect(!PinsHandBack.run(to: Self.home, rows: rows.rows))
        #expect(rows.shapes[Space.pinsID]!.tabs.count == 1)

        rows.failing = nil
        #expect(PinsHandBack.run(to: Self.home, rows: rows.rows))
        #expect(rows.shapes[Self.home]!.tabs.compactMap(\.id) == ["a", "x"])
        #expect(rows.shapes[Space.pinsID]!.tabs.isEmpty)
    }
}

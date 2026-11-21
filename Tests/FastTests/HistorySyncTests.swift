import Foundation
import Testing
import SyncKit
@testable import Fast

@MainActor
struct HistorySyncTests {
    init() { SyncShapes.register() }

    @Test func aKnownPlaceTakesTheNewerTitleAndTypedWithoutEchoingItsOldFields() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        let old = Visit(url: "https://history.test/page", key: "history.test/page", title: "Before", count: 9,
                        last: Date(timeIntervalSince1970: 1_000.5), typed: nil)
        try JSONEncoder().encode([old]).write(to: file)
        let history = History(file: file)
        var remote = old
        remote.title = "From iPhone"
        remote.last = Date(timeIntervalSince1970: 2_000)
        remote.typed = 3

        let mac = try Journal(path: nil, device: "history-mac")
        try mac.reconcile(SyncShapes.visit, SyncShapes.visits([old]))
        try mac.sent(mac.pending().map { ($0.record, Int64(1)) })
        let phone = try Journal(path: nil, device: "history-phone")
        _ = try phone.receive(mac.all(SyncShapes.visit).map { ($0, Int64(1)) })
        try phone.reconcile(SyncShapes.visit, SyncShapes.visits([remote]))
        let received = try mac.receive(phone.pending().map { ($0.record, Int64(2)) })
        history.adoptSynced(SyncShapes.visits(from: received))
        history.adoptSynced(SyncShapes.visits(from: mac.all(SyncShapes.visit)))

        let adopted = try #require(history.visits(since: .distantPast).first)
        #expect(adopted.title == remote.title)
        #expect(adopted.last == remote.last)
        #expect(adopted.count == old.count)
        #expect(adopted.typed == 1)
        let echoed = try mac.reconcile(SyncShapes.visit, SyncShapes.visits(history.visits(since: .distantPast)))
        #expect(echoed.isEmpty)
        #expect(mac.pendingCount == 0)

        await history.flush()
        let reopened = try #require(History(file: file).visits(since: .distantPast).first)
        #expect(reopened.title == remote.title)
        #expect(reopened.last == remote.last)
        #expect(reopened.count == old.count)
        #expect(reopened.typed == 1)
    }

    @Test func typedArrivesEvenWhenTheKnownPlaceHasANewerLocalVisit() throws {
        let url = URL(string: "https://history.test/typed")!
        let local = Visit(url: url.absoluteString, key: "history.test/typed", title: "Local", count: 4,
                          last: Date(timeIntervalSince1970: 2_000), typed: nil)
        let history = History([local])
        history.adoptSynced([(url, "Older", Date(timeIntervalSince1970: 1_000), true)])
        history.adoptSynced([(url, "Equal", local.last, true)])
        history.adoptSynced([(url, "Older", Date(timeIntervalSince1970: 1_000), false)])
        let adopted = try #require(history.visits(since: .distantPast).first)
        #expect(adopted.title == local.title)
        #expect(adopted.last == local.last)
        #expect(adopted.count == local.count)
        #expect(adopted.typed == 1)
    }

    @Test func syncPreservesLocalTypedCountsAndDoesNotEraseAUsefulTitle() throws {
        let url = URL(string: "https://history.test/kept")!
        let local = Visit(url: url.absoluteString, key: "history.test/kept", title: "Useful", count: 8,
                          last: Date(timeIntervalSince1970: 1_000), typed: 7)
        let history = History([local])
        let newer = Date(timeIntervalSince1970: 2_000)
        history.adoptSynced([(url, "", newer, false)])
        history.adoptSynced([(url, "", newer, true)])
        let adopted = try #require(history.visits(since: .distantPast).first)
        #expect(adopted.title == local.title)
        #expect(adopted.last == newer)
        #expect(adopted.count == local.count)
        #expect(adopted.typed == local.typed)
    }

    @Test func aNewRemotePlaceIsOneVisitEvenAfterRepeatedReceives() throws {
        let url = URL(string: "https://history.test/new")!
        let history = History([])
        let place = (url: url, title: "New", last: Date(timeIntervalSince1970: 1_000), typed: true)
        history.adoptSynced([place])
        history.adoptSynced([place])
        let adopted = try #require(history.visits(since: .distantPast).first)
        #expect(history.visits(since: .distantPast).count == 1)
        #expect(adopted.count == 1)
        #expect(adopted.typed == 1)
        #expect(adopted.title == place.title)
    }

    // MARK: deleted by hand (request 1104)

    static let gone = Visit(url: "https://history.test/gone", key: "history.test/gone", title: "Gone", count: 2,
                            last: Date(timeIntervalSince1970: 1_000), typed: nil)
    static let kept = Visit(url: "https://history.test/kept", key: "history.test/kept", title: "Kept", count: 1,
                            last: Date(timeIntervalSince1970: 1_000), typed: nil)

    /// Two Macs holding the same two places, synced once.
    static func twoMacs() throws -> (a: History, macA: Journal, b: History, macB: Journal) {
        let a = History([gone, kept])
        let b = History([gone, kept])
        let macA = try Journal(path: nil, device: "history-a")
        try macA.reconcile(SyncShapes.visit, SyncShapes.visits([gone, kept]))
        let first = macA.pending().map { ($0.record, Int64(1)) }
        try macA.sent(first)
        let macB = try Journal(path: nil, device: "history-b")
        _ = try macB.receive(first)
        try macB.reconcile(SyncShapes.visit, SyncShapes.visits(b.visits(since: .distantPast)))
        return (a, macA, b, macB)
    }

    /// What SyncCenter's flush does with Mac A's history and its cuts.
    static func flush(_ history: History, into journal: Journal) throws {
        try SyncShapes.tellVisits(history.visits(since: .distantPast), cuts: history.takeCuts(), into: journal)
    }

    @Test func aPageDeletedOnOneMacGoesFromTheOtherAndDoesNotComeBack() throws {
        let (a, macA, b, macB) = try Self.twoMacs()
        a.forget(Self.gone.key)
        #expect(a.cuts.keys.sorted() == [Self.gone.key])
        try Self.flush(a, into: macA)
        #expect(a.cuts.isEmpty)
        let received = try macB.receive(macA.pending().map { ($0.record, Int64(2)) })
        #expect(SyncShapes.visits(from: received).isEmpty)
        let dropped = b.dropSynced(SyncShapes.cutVisits(from: received))
        #expect(dropped.map(\.absoluteString) == [Self.gone.url])
        #expect(b.visits(since: .distantPast).map(\.key) == [Self.kept.key])
        // Mac B's next flush has nothing to send back.
        let echoed = try macB.reconcile(SyncShapes.visit, SyncShapes.visits(b.visits(since: .distantPast)))
        #expect(echoed.isEmpty)
    }

    @Test func pagesPickedAndDeletedTogetherAreCutAndUndoTakesTheCutBack() throws {
        let history = History([Self.gone, Self.kept])
        let taken = history.take([Self.gone.key, Self.kept.key])
        #expect(Set(history.cuts.keys) == [Self.gone.key, Self.kept.key])
        history.putBack(taken)
        #expect(history.cuts.isEmpty)
        #expect(history.visits(since: .distantPast).count == 2)
        // Forgetting what was never there cuts nothing.
        history.forget("history.test/never")
        #expect(history.cuts.isEmpty)
    }

    @Test func aPlaceThatOnlyLeftTheTwoWeeksOrStoppedSyncingStaysOnTheOtherMac() throws {
        let (_, macA, b, macB) = try Self.twoMacs()
        // Mac A's flush without the places, nothing deleted by hand: as when
        // they leave the two weeks or history sync is turned off there.
        try macA.reconcile(SyncShapes.visit, [:])
        let received = try macB.receive(macA.pending().map { ($0.record, Int64(2)) })
        #expect(received.count == 2)
        #expect(SyncShapes.cutVisits(from: received).isEmpty)
        #expect(b.dropSynced(SyncShapes.cutVisits(from: received)).isEmpty)
        #expect(b.visits(since: .distantPast).count == 2)
    }

    @Test func aPageVisitedAgainSinceTheDeleteStays() throws {
        let (a, macA, b, macB) = try Self.twoMacs()
        a.forget(Self.gone.key)
        try Self.flush(a, into: macA)
        let received = try macB.receive(macA.pending().map { ($0.record, Int64(2)) })
        let cuts = SyncShapes.cutVisits(from: received)
        #expect(cuts.map(\.key) == [Self.gone.key])
        let later = cuts[0].at.addingTimeInterval(60)
        b.adoptSynced([(URL(string: Self.gone.url)!, "Again", later, false)])
        #expect(b.dropSynced(cuts).isEmpty)
        #expect(b.visits(since: .distantPast).count == 2)
    }

    @Test func anOldCutIsNotReadAgainOnceThePlaceCameBack() throws {
        let (a, macA, _, _) = try Self.twoMacs()
        a.forget(Self.gone.key)
        try Self.flush(a, into: macA)
        // Visited again on Mac A: the record lives again, its old cut kept.
        var again = Self.gone
        again.last = Date().addingTimeInterval(10)
        a.adoptSynced([(URL(string: again.url)!, again.title, again.last, false)])
        try Self.flush(a, into: macA)
        // Then gone from the two weeks: a removal, no new cut.
        try macA.reconcile(SyncShapes.visit, [:])
        let records = macA.all(SyncShapes.visit)
        #expect(records.allSatisfy { !$0.alive() })
        #expect(SyncShapes.cutVisits(from: records).isEmpty)
    }
}

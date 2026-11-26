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

    @Test func aNewerVisitElsewhereBringsItsAddressWithItsTitle() throws {
        let local = Visit(url: "https://www.google.com/search?q=a", key: "google.com/search", title: "a - Google Search", count: 3,
                          last: Date(timeIntervalSince1970: 1_000), typed: nil)
        let history = History([local])
        let newer = URL(string: "https://www.google.com/search?q=b")!
        history.adoptSynced([(URL(string: "https://www.google.com/search?q=c")!, "c - Google Search", Date(timeIntervalSince1970: 500), false)])
        #expect(history.visits(since: .distantPast).first?.url == local.url)
        history.adoptSynced([(newer, "b - Google Search", Date(timeIntervalSince1970: 2_000), false)])
        let adopted = try #require(history.visits(since: .distantPast).first)
        #expect(adopted.url == newer.absoluteString)
        #expect(adopted.title == "b - Google Search")
        #expect(adopted.count == local.count)
        // A newer one with no title yet keeps the address its title is for.
        history.adoptSynced([(URL(string: "https://www.google.com/search?q=d")!, "", Date(timeIntervalSince1970: 3_000), false)])
        let untitled = try #require(history.visits(since: .distantPast).first)
        #expect(untitled.url == newer.absoluteString)
        #expect(untitled.title == "b - Google Search")
        #expect(untitled.last == Date(timeIntervalSince1970: 3_000))
        // An older visit's title doesn't go on a newer, untitled address.
        let blank = Visit(url: "https://www.google.com/search?q=e", key: "google.com/search", title: "", count: 1,
                          last: Date(timeIntervalSince1970: 5_000), typed: nil)
        let other = History([blank])
        other.adoptSynced([(newer, "b - Google Search", Date(timeIntervalSince1970: 4_000), false)])
        #expect(other.visits(since: .distantPast).first?.title == "")
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
        try SyncShapes.reconcileVisits(macA, SyncShapes.visits([gone, kept]), cuts: [:])
        let first = macA.pending().map { ($0.record, Int64(1)) }
        try macA.sent(first)
        let macB = try Journal(path: nil, device: "history-b")
        _ = try macB.receive(first)
        try flush(b, into: macB)
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
        try SyncShapes.reconcileVisits(macA, [:], cuts: [:])
        let received = try macB.receive(macA.pending().map { ($0.record, Int64(2)) })
        #expect(received.count == 2)
        #expect(SyncShapes.cutVisits(from: received).isEmpty)
        #expect(b.dropSynced(SyncShapes.cutVisits(from: received)).isEmpty)
        #expect(b.visits(since: .distantPast).count == 2)
    }

    /// Three Macs holding the same two places; Mac A then turns history
    /// sync off, which takes them out of the account. B and C have taken
    /// the removal in and kept theirs, and haven't flushed since.
    static func threeMacsAfterOneStopped() throws -> (a: Journal, b: History, macB: Journal, c: History, macC: Journal) {
        let (_, macA, b, macB) = try twoMacs()
        let c = History([gone, kept])
        let macC = try Journal(path: nil, device: "history-c")
        _ = try macC.receive(macA.all(SyncShapes.visit).map { ($0, Int64(1)) })
        try flush(c, into: macC)
        try SyncShapes.reconcileVisits(macA, [:], cuts: [:])
        let removal = macA.pending().map { ($0.record, Int64(3)) }
        try macA.sent(removal)
        for (history, journal) in [(b, macB), (c, macC)] {
            let received = try journal.receive(removal)
            history.adoptSynced(SyncShapes.visits(from: received))
            history.dropSynced(SyncShapes.cutVisits(from: received))
            #expect(history.visits(since: .distantPast).count == 2)
        }
        return (macA, b, macB, c, macC)
    }

    @Test func placesAMacStoppedSyncingComeBackWholeFromTheOthersOnce() throws {
        let (macA, b, macB, c, macC) = try Self.threeMacsAfterOneStopped()
        try Self.flush(b, into: macB)
        let back = macB.pending().map { ($0.record, Int64(4)) }
        #expect(back.count == 2)
        for (record, _) in back {
            let visit = try #require(SyncVisit(record))
            #expect([Self.gone.url, Self.kept.url].contains(visit.url))
        }
        try macB.sent(back)
        _ = try macC.receive(back)
        _ = try macA.receive(back)
        // C says the same, and A, with history sync off, removes nothing more.
        try Self.flush(c, into: macC)
        try SyncShapes.reconcileVisits(macA, [:], cuts: [:])
        #expect(macC.pendingCount == 0 && macA.pendingCount == 0)
        try Self.flush(b, into: macB)
        #expect(macB.pendingCount == 0)
    }

    @Test func aPlaceVisitedAgainAfterAnotherMacStoppedGoesUpWhole() throws {
        let (_, b, macB, _, _) = try Self.threeMacsAfterOneStopped()
        b.record(URL(string: Self.kept.url)!, title: Self.kept.title)
        try Self.flush(b, into: macB)
        let record = try #require(macB.record(.init(collection: SyncShapes.visit, id: Self.kept.key)))
        #expect(record.alive())
        let visit = try #require(SyncVisit(record))
        #expect(visit.url == Self.kept.url)
        #expect(visit.title == Self.kept.title)
    }

    @Test func aPageDeletedRightAfterAnotherMacStoppedStillGoesFromTheThird() throws {
        let (_, b, macB, c, macC) = try Self.threeMacsAfterOneStopped()
        b.forget(Self.gone.key)
        try Self.flush(b, into: macB)
        let gone = try #require(macB.record(.init(collection: SyncShapes.visit, id: Self.gone.key)))
        #expect(!gone.alive() && gone.fields["url"]?.string == Self.gone.url)
        let received = try macC.receive(macB.pending().map { ($0.record, Int64(4)) })
        let dropped = c.dropSynced(SyncShapes.cutVisits(from: received))
        #expect(dropped.map(\.absoluteString) == [Self.gone.url])
        #expect(c.visits(since: .distantPast).map(\.key) == [Self.kept.key])
    }

    @Test func aDeletionAFlushCouldNotTellWaitsForTheNext() {
        let history = History([Self.gone, Self.kept])
        history.forget(Self.gone.key)
        let untold = history.takeCuts()
        history.keepCuts(untold)
        #expect(history.takeCuts() == untold)
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
        try SyncShapes.reconcileVisits(macA, [:], cuts: [:])
        let records = macA.all(SyncShapes.visit)
        #expect(records.allSatisfy { !$0.alive() })
        #expect(SyncShapes.cutVisits(from: records).isEmpty)
    }
}

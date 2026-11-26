import Foundation
import Testing
@testable import Fast

/// A space's kept tabs and its own pins in every window of it
/// (KeptEverywhere.swift, feedback #157): a window's own file joined with
/// the list, the first window's file with a list in its kept's place, the
/// marks every window agrees on, and a second window following the first's
/// real tabs.
@Suite(.serialized)
struct KeptEverywhereTests {
    private func entry(_ url: String, kept: Bool = false, pin: String? = nil, id: String = UUID().uuidString, shared: Bool? = nil) -> Session.Entry {
        var entry = Session.Entry(url: url, title: url, pin: pin, name: nil, seen: nil, kept: kept ? true : nil, id: id)
        entry.shared = shared
        return entry
    }

    // MARK: the rules

    @Test func aWindowsFileTakesTheListInPlaceOfItsKept() {
        let pin = entry("https://a.test/pin", pin: "A"), kept = entry("https://a.test/kept", kept: true)
        let list = [pin, kept]
        // What this window wrote last time: the list's two (marked), a kept
        // tab gone from the list since, and its own today's.
        let own = Session.Shape(tabs: [
            entry("https://a.test/pin", pin: "A", id: pin.id!, shared: true),
            entry("https://a.test/kept", kept: true, id: kept.id!, shared: true),
            entry("https://a.test/gone", kept: true, shared: true),
            entry("https://a.test/today"),
            entry("https://a.test/later"),
        ], active: 4, pairs: [Session.Pair(first: 1, second: 3, share: 0.5)])
        let joined = KeptEverywhere.joined(own, list: list)
        #expect(joined.shape.tabs.map(\.url) == ["https://a.test/pin", "https://a.test/kept", "https://a.test/today", "https://a.test/later"])
        #expect(joined.keyed == 2 && joined.strays == 0 && !joined.fresh)
        // The tab in front and the pair follow their entries.
        #expect(joined.shape.active == 3)
        #expect(joined.shape.pairs?.first.map { [$0.first, $0.second] } == [1, 2])
    }

    @Test func keptHereAloneBeforeJoinsTheListOnce() {
        let list = [entry("https://a.test/kept", kept: true)]
        // A Yab from before: this window's own kept, unmarked, one of them
        // the same place as the list's.
        let own = Session.Shape(tabs: [
            entry("https://a.test/kept", kept: true),
            entry("https://a.test/mine", kept: true),
            entry("https://a.test/mine", kept: true),
            entry("https://a.test/today"),
        ], active: 1)
        let joined = KeptEverywhere.joined(own, list: list)
        #expect(joined.shape.tabs.map(\.url) == ["https://a.test/kept", "https://a.test/mine", "https://a.test/today"])
        #expect(joined.keyed == 2 && joined.strays == 1)
        #expect(joined.shape.active == 1)
    }

    @Test func aNewWindowHasOnlyTheListNoneInFront() {
        let list = [entry("https://a.test/kept", kept: true)]
        let joined = KeptEverywhere.joined(Session.Shape(tabs: [], active: 0), list: list)
        #expect(joined.fresh && joined.keyed == 1)
        #expect(joined.shape.tabs.map(\.url) == ["https://a.test/kept"])
    }

    @Test(arguments: [false, true])
    func relaunchKeepsEachWindowsPagesUnderTheSharedKeys(today: Bool) throws {
        // Both tabs can share a home address. Identity, never the URL or
        // position in the list, says which saved page belongs to each tab.
        var first = entry("https://a.test/home", kept: !today)
        var second = entry("https://a.test/home", kept: !today)
        first.name = "Shared name"
        second.folder = UUID().uuidString
        second.folderName = "Shared folder"
        var localFirst = first
        localFirst.url = "https://a.test/second-window/first"
        localFirst.title = "First page in second window"
        localFirst.name = "Old name"
        localFirst.seen = 123
        localFirst.visits = 7
        localFirst.depth = 0.6
        localFirst.shared = true
        var localSecond = second
        localSecond.url = "https://a.test/second-window/second"
        localSecond.title = "Second page in second window"
        localSecond.folderName = "Old folder"
        localSecond.shared = true
        let saved = Session.Shape(tabs: [localFirst, localSecond], active: 0,
                                  pairs: [.init(first: 0, second: 1, share: 0.4)])
        let disk = try JSONEncoder().encode(saved)
        let own = try JSONDecoder().decode(Session.Shape.self, from: disk)

        // Another window reordered the common list before quitting.
        let joined = KeptEverywhere.joined(own, list: [second, first], today: today)
        #expect(joined.shape.tabs.map(\.id) == [second.id, first.id])
        #expect(joined.shape.tabs.map(\.url) == [localSecond.url, localFirst.url])
        #expect(joined.shape.tabs.map(\.title) == [localSecond.title, localFirst.title])
        #expect(joined.shape.tabs[1].seen == 123)
        #expect(joined.shape.tabs[1].visits == 7)
        #expect(joined.shape.tabs[1].depth == 0.6)
        #expect(joined.shape.tabs[1].name == first.name)
        #expect(joined.shape.tabs[0].folderName == second.folderName)
        #expect(joined.shape.front == 1)
        #expect(joined.shape.pairs?.first.map { [$0.first, $0.second] } == [1, 0])
        #expect(joined.shape.pairs?.first?.share == 0.4)
        #expect(joined.keyed == 2 && joined.strays == 0 && !joined.fresh)
    }

    @Test func aSharedTabNewToThisWindowUsesTheListsPage() {
        let existing = entry("https://a.test/first-window", kept: true)
        var local = existing
        local.url = "https://a.test/second-window"
        local.shared = true
        let added = entry("https://a.test/new", kept: true)
        let own = Session.Shape(tabs: [local], active: 0)

        let joined = KeptEverywhere.joined(own, list: [added, existing], today: false)

        #expect(joined.shape.tabs.map(\.url) == [added.url, local.url])
        #expect(joined.shape.front == 1)
    }

    @Test func aRowLeftOnASharedPinStaysSo() {
        let joined = KeptEverywhere.joined(Session.Shape(tabs: [entry("https://a.test/today")], active: -2), list: [])
        #expect(joined.shape.active == -2)
    }

    /// Left with none in front, or on a kept tab gone from the list since:
    /// none in front, never the first of the list or of today's instead.
    @Test func aRowLeftWithNoneInFrontStaysSo() {
        let kept = entry("https://a.test/kept", kept: true)
        let today = [entry("https://a.test/today")]
        let bare = KeptEverywhere.joined(Session.Shape(tabs: [entry("https://a.test/kept", kept: true, id: kept.id!, shared: true)] + today, front: nil), list: [kept])
        #expect(bare.shape.front == nil)
        let gone = KeptEverywhere.joined(Session.Shape(tabs: [entry("https://a.test/gone", kept: true, shared: true)] + today, active: 0), list: [kept])
        #expect(gone.shape.front == nil)
        #expect(KeptEverywhere.replaced(Session.Shape(tabs: [kept] + today, front: nil), with: [kept]).front == nil)
        #expect(KeptEverywhere.replaced(Session.Shape(tabs: [entry("https://a.test/old", kept: true)] + today, active: 0), with: [kept]).front == nil)
    }

    @Test func theFirstWindowsFileKeepsItsTodaysUnderANewList() {
        let old = entry("https://a.test/old", kept: true), stays = entry("https://a.test/stays", kept: true)
        let file = Session.Shape(tabs: [old, stays, entry("https://a.test/today")], active: 2,
                                 pairs: [Session.Pair(first: 1, second: 2, share: 0.4)])
        let added = entry("https://a.test/added", kept: true)
        let shape = KeptEverywhere.replaced(file, with: [added, stays])
        #expect(shape.tabs.map(\.url) == ["https://a.test/added", "https://a.test/stays", "https://a.test/today"])
        #expect(shape.active == 2)
        #expect(shape.pairs?.first.map { [$0.first, $0.second] } == [1, 2])
    }

    @Test func marksSayWhatEveryWindowAgreesOn() {
        var a = entry("https://a.test/x", kept: true)
        var b = a
        b.url = "https://a.test/elsewhere"
        b.seen = 12
        b.visits = 3
        b.shared = true
        #expect(KeptEverywhere.mark(a) == KeptEverywhere.mark(b))
        // A folder opened or shut is every window's.
        b.folderOpen = false
        #expect(KeptEverywhere.mark(a) != KeptEverywhere.mark(b))
        b.folderOpen = nil
        a.name = "Mine"
        #expect(KeptEverywhere.mark(a) != KeptEverywhere.mark(b))
        b = a
        b.folder = UUID().uuidString
        #expect(KeptEverywhere.mark(a) != KeptEverywhere.mark(b))
    }

    // MARK: two windows

    @MainActor @Test func anotherWindowFollowsTheKeptAndThePins() throws {
        let one = UUID(), two = UUID()
        defer {
            for id in [one, two] { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        let a = Browser(windowID: one), b = Browser(windowID: two)
        defer { a.letGo(); b.letGo() }
        func page(_ name: String) -> Tab {
            let tab = Tab()
            tab.restore(url: URL(string: "https://kept.test/\(name)")!, title: name)
            a.prepare(tab)
            return tab
        }
        let pinned = page("pinned"), alpha = page("alpha"), bravo = page("bravo"), today = page("today")
        a.lay([pinned, alpha, bravo, today])
        a.pin(pinned)
        a.keepTabs([alpha, bravo])
        a.newFolder(with: [bravo])
        bravo.nest?.name = "Trip"

        b.followKept(a.keptList(a.tabs), in: b.spaceID)
        #expect(b.tabs.map { $0.address?.lastPathComponent } == ["pinned", "alpha", "bravo"])
        let copies = b.tabs
        #expect(copies.allSatisfy { $0.asleep })
        let originals: [Tab] = [pinned, alpha, bravo]
        for (copy, tab) in zip(copies, originals) {
            #expect(copy !== tab && copy.id != tab.id && copy.keptKey == tab.id)
        }
        #expect(copies[0].pin != nil && copies[1].kept && copies[2].kept)
        #expect(copies[2].nest?.name == "Trip" && copies[2].nest?.id == bravo.nest?.id && copies[2].nest !== bravo.nest)

        // Kept there, in b: its own tab, under a key of its own.
        let mine = Tab()
        mine.restore(url: URL(string: "https://kept.test/mine")!, title: "mine")
        b.prepare(mine)
        b.lay(b.tabs + [mine])
        b.keepTabs([mine])
        let fromB = b.keptList(b.tabs)
        #expect(fromB.count == 4)
        a.followKept(fromB, in: a.spaceID)
        #expect(a.tabs.filter(\.kept).map { $0.address?.lastPathComponent } == ["alpha", "bravo", "mine"])
        #expect(a.tabs.contains { $0 === today && !$0.kept })

        // Let go in a: b's copy, asleep, goes; one in front stays, today's.
        b.select(copies[2])
        a.releaseTabs([alpha, bravo])
        b.followKept(a.keptList(a.tabs), in: b.spaceID)
        #expect(!b.tabs.contains { $0 === copies[1] })
        #expect(b.tabs.contains { $0 === copies[2] } && !copies[2].kept && copies[2].nest == nil)
        #expect(b.tabs.filter(\.kept).map { $0.address?.lastPathComponent } == ["mine"])
        #expect(b.tabs.first?.pin != nil)

        // The same list again changes nothing.
        let before = b.tabs
        b.followKept(a.keptList(a.tabs), in: b.spaceID)
        #expect(b.tabs.elementsEqual(before, by: ===))
    }

    /// With today's in every window, one pane of a split closed in another
    /// window: the split parked here keeps its other panes.
    @MainActor @Test func aPaneClosedElsewhereLeavesTheRestOfAParkedSplit() {
        let was = KeptEverywhere.today
        KeptEverywhere.today = true
        let id = UUID(), space = UUID()
        let b = Browser(windowID: id)
        defer {
            KeptEverywhere.today = was
            b.letGo()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: Store.folder.path)) ?? [] where name.contains(id.uuidString) {
                try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name))
            }
        }
        let tabs = (0..<4).map { at -> Tab in
            let tab = Tab()
            tab.restore(url: URL(string: "https://kept.test/split-\(at)")!, title: "split \(at)")
            b.prepare(tab)
            return tab
        }
        b.parked[space] = Parked(tabs: tabs, active: tabs[3].id,
                                 pairs: [Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id], arrangement: .grid)])
        let list = b.keptList(tabs).filter { $0.id != KeptEverywhere.key(tabs[2]).uuidString }
        b.followKept(list, in: space)
        #expect(!(b.parked[space]?.tabs.contains { $0 === tabs[2] } ?? true))
        #expect(b.parked[space]?.pairs.map(\.ids) == [[tabs[0].id, tabs[1].id]])
    }
}

import Foundation
import Testing
@testable import Fast

// Two tabs side by side or stacked, three as one beside two stacked, four as
// a 2x2 grid (#71, #522, #1054): the model, the frames each lays, the
// dividers in the hand, and a session written by a Yab that knew only pairs.
struct SplitPanesTests {
    static let ids = (0..<8).map { _ in UUID() }
    static var made: [Int: UUID] { Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.offset, $0.element) }) }
    static let room = CGRect(x: 20, y: 40, width: 1400, height: 900)

    @Test func addsUpToFourAndRemovesDownToNone() {
        let id = Self.ids
        let pair = Pair(first: id[0], second: id[1], share: 0.3)
        #expect(pair.halves && pair.count == 2)
        let three = pair.adding(id[2])!
        #expect(three.ids == [id[0], id[1], id[2]] && three.arrangement == .grid && !three.halves)
        #expect(three.allCuts == [0.5, 0.5])
        let four = three.adding(id[3])!
        #expect(four.arrangement == .grid && four.allCuts == [0.5, 0.5])
        #expect(four.adding(id[4]) == nil)
        #expect(three.adding(id[1]) == nil)
        // A pane out: the rest, evenly; two left, side by side as a pair.
        let back = four.removing(id[1])!
        #expect(back.ids == [id[0], id[2], id[3]] && back.arrangement == .grid)
        let two = back.removing(id[2])!
        #expect(two.ids == [id[0], id[3]] && two.halves && two.share == 0.5)
        #expect(two.removing(id[0]) == nil)
        // Two stacked take a third into the grid, and are side by side again
        // when it leaves: stacked is a choice for two.
        let stacked = pair.with(pair.ids, .stacked)!
        #expect(stacked.arrangement == .stacked && stacked.adding(id[2])?.arrangement == .grid)
        #expect(stacked.adding(id[2])?.removing(id[2])?.halves == true)
    }

    // Three: the first on the left, the second at upper right, the third
    // below it, in that order whatever was in front; one layout only.
    @Test func threeStandOneBesideTwoStacked() {
        let id = Self.ids, room = Self.room
        let three = Pair(first: id[0], second: id[1]).adding(id[2])!
        #expect(three.arrangement == .grid && three.ids == [id[0], id[1], id[2]])
        let laid = SplitLayout.panes(3, three.arrangement, cuts: three.allCuts, in: room)
        let (left, upper, lower) = (laid.panes[0], laid.panes[1], laid.panes[2])
        #expect(left.minX == room.minX && left.minY == room.minY && left.height == room.height)
        #expect(upper.minX > left.maxX && upper.minY == room.minY && upper.maxX == room.maxX)
        #expect(lower.minX == upper.minX && lower.width == upper.width && lower.minY > upper.maxY && lower.maxY == room.maxY)
        // The divider between the columns runs the whole height; the one
        // between the two on the right runs across the right column only.
        #expect(laid.cuts.count == 2)
        #expect(laid.cuts[0].height == room.height && laid.cuts[0].minX == left.maxX)
        #expect(laid.cuts[1].minX == upper.minX && laid.cuts[1].maxX == room.maxX && laid.cuts[1].minY == upper.maxY)
        // Asked for side by side or stacked, three are still the grid.
        #expect(Pair(first: id[0], second: id[1]).with([id[0], id[1], id[2]], .across)?.arrangement == .grid)
        #expect(Pair(first: id[0], second: id[1]).with([id[0], id[1], id[2]], .stacked)?.arrangement == .grid)
    }

    // Four: always the 2x2, however wide the room; the fourth below the
    // first, so the third stays at lower right as it came in.
    @Test(arguments: [1200.0, 1600, 2400, 3200])
    func fourAreAlwaysTwoByTwo(width: Double) {
        let id = Self.ids
        let room = CGRect(x: 0, y: 0, width: width, height: 900)
        let four = Pair(first: id[0], second: id[1]).adding(id[2])!.adding(id[3])!
        #expect(four.arrangement == .grid)
        let laid = SplitLayout.panes(4, four.arrangement, cuts: four.allCuts, in: room).panes
        let three = SplitLayout.panes(3, .grid, cuts: [0.5, 0.5], in: room).panes
        #expect(laid[0].minX == room.minX && laid[0].minY == room.minY && laid[0].maxY < laid[3].minY)
        #expect(laid[1].minY == room.minY && laid[1].maxX == room.maxX)
        #expect(laid[2] == three[2])
        #expect(laid[3].minX == room.minX && laid[3].maxY == room.maxY)
        #expect(Set(laid.map { "\($0.width)x\($0.height)" }).count <= 2)
    }

    @Test func otherThanGoesRoundThePanes() {
        let id = Self.ids
        let pair = Pair(first: id[0], second: id[1])
        #expect(pair.other(than: id[0]) == id[1] && pair.other(than: id[1]) == id[0])
        let four = Pair(first: id[0], second: id[1], more: [id[2], id[3]])
        #expect([id[0], id[1], id[2], id[3]].map(four.other) == [id[1], id[2], id[3], id[0]])
        #expect(four.contains(id[3]) && !four.contains(id[4]) && !four.contains(nil))
        #expect([id[0], id[1], id[2], id[3]].map { Joint(four, $0) } == [.first, .middle, .middle, .second])
        #expect(Joint(pair, id[1]) == .second)
    }

    @Test func mapsEveryPane() {
        let id = Self.ids
        let three = Pair(first: id[0], second: id[1], share: 0.2, more: [id[2]], arrangement: .grid, cuts: [0.7])
        let moved = three.mapped { id.firstIndex(of: $0).map { Self.ids[$0 + 4] } }!
        #expect(moved.ids == [id[4], id[5], id[6]] && moved.arrangement == .grid && moved.allCuts == [0.2, 0.7])
        // A pane past the first two gone: the rest, evenly, a pair.
        let lost = three.mapped { $0 == id[2] ? nil : $0 }!
        #expect(lost.ids == [id[0], id[1]] && lost.share == 0.5 && lost.halves)
        #expect(three.mapped { $0 == id[0] ? nil : $0 } == nil)
    }

    // A session written by any Yab: pairs as they always were, and the panes
    // past them written beside, where a Yab from before never looks.
    @Test func restoresThreeAndFour() {
        let pairs = Pair.restore([
            .init(first: 0, second: 1, share: 0.4),
            Session.Pair(first: 2, second: 3, share: 0.3, more: [4, 5], arrangement: "grid", cuts: [0.6]),
        ], made: Self.made)
        #expect(pairs.count == 2)
        #expect(pairs[0].halves && abs(pairs[0].share - 0.4) < 0.0001)
        #expect(pairs[1].ids == [Self.ids[2], Self.ids[3], Self.ids[4], Self.ids[5]])
        #expect(pairs[1].arrangement == .grid && pairs[1].allCuts == [0.3, 0.6])
    }

    @Test func restoreDropsBadPanesNotThePair() {
        let pairs = Pair.restore([
            Session.Pair(first: 0, second: 1, share: 0.5, more: [1, 9, 2, 3, 4], arrangement: "stacked", cuts: [0.9, 0.1, 0.5]),
            Session.Pair(first: 5, second: 6, share: 0.5, more: [2], arrangement: "sideways", cuts: nil),
        ], made: Self.made)
        // The first's own tab again, one not there, then two past the most:
        // two panes kept, laid as the grid four always are, evenly, as the
        // cuts didn't fit.
        #expect(pairs[0].ids == [Self.ids[0], Self.ids[1], Self.ids[2], Self.ids[3]])
        #expect(pairs[0].arrangement == .grid && pairs[0].allCuts == [0.5, 0.5])
        // A pane another split took, and an arrangement unknown: a pair.
        #expect(pairs[1].halves && pairs[1].ids == [Self.ids[5], Self.ids[6]])
    }

    @Test func writesWhatAnOldReaderReadsAsAPair() throws {
        let id = Self.ids
        let place = { (tab: UUID) in id.firstIndex(of: tab) }
        let two = Session.Pair(Pair(first: id[0], second: id[1], share: 0.4), at: place)!
        #expect(two.more == nil && two.arrangement == nil && two.cuts == nil)
        let four = Session.Pair(Pair(first: id[0], second: id[1], share: 0.3, more: [id[2], id[3]], arrangement: .grid, cuts: [0.6]), at: place)!
        let data = try JSONEncoder().encode(Session.Shape(tabs: [], active: 0, pairs: [two, four]))
        // An older Yab's own shape of a pair: first, second and share only.
        struct OldPair: Decodable { var first: Int; var second: Int; var share: Double }
        struct OldShape: Decodable { var pairs: [OldPair]? }
        let old = try JSONDecoder().decode(OldShape.self, from: data)
        #expect(old.pairs?.map(\.first) == [0, 0] && old.pairs?.map(\.second) == [1, 1])
        let back = try JSONDecoder().decode(Session.Shape.self, from: data)
        #expect(back.pairs?[1].more == [2, 3] && back.pairs?[1].arrangement == "grid" && back.pairs?[1].cuts == [0.6])
        // A pane's tab not written: the pane is left out.
        #expect(Session.Pair(Pair(first: id[0], second: id[1], more: [id[7]]), at: { $0 == id[7] ? nil : place($0) })?.more == nil)
        // Moved: every place moves, a pane gone takes the dividers with it.
        let moved = four.moved { $0 == 3 ? nil : $0 + 10 }!
        #expect(moved.first == 10 && moved.second == 11 && moved.more == [12] && moved.cuts == nil)
    }

    // Two side by side are laid exactly as a pair always was.
    @Test(arguments: [0.0, 300, 648, 1080, 1400])
    func twoAcrossMatchesThePair(width: Double) {
        let room = CGRect(x: 31, y: 17, width: width, height: 420)
        for share: CGFloat in [0.1, 0.25, 0.4, 0.5, 0.75, 0.9] {
            let pair = SplitLayout(share: share)
            let laid = SplitLayout.panes(2, .across, cuts: [share], in: room)
            #expect(laid.panes == [pair.frame(for: .left, in: room), pair.frame(for: .right, in: room)])
            #expect(laid.cuts == [pair.frame(for: .gap, in: room)])
        }
    }

    @Test(arguments: [(2, Pair.Arrangement.stacked), (3, .grid), (4, .grid)])
    func framesTileTheRoom(count: Int, arrangement: Pair.Arrangement) {
        let room = Self.room
        let laid = SplitLayout.panes(count, arrangement, cuts: Pair.even(count, arrangement), in: room)
        #expect(laid.panes.count == count)
        #expect(laid.cuts.count == (arrangement == .grid ? 2 : count - 1))
        let area = laid.panes.reduce(0) { $0 + $1.width * $1.height }
        let gaps = laid.cuts.reduce(0) { $0 + $1.width * $1.height } - (count == 4 ? Pair.gap * Pair.gap : 0)
        #expect(abs(area + gaps - room.width * room.height) < 0.5)
        for pane in laid.panes { #expect(room.contains(pane)) }
        for (a, pane) in laid.panes.enumerated() {
            for other in laid.panes.dropFirst(a + 1) { #expect(!pane.intersects(other)) }
        }
        // Even: the panes alike, but three's tall one on the left.
        #expect(Set(laid.panes.map { "\($0.width)x\($0.height)" }).count <= (count == 3 ? 3 : 2))
        switch arrangement {
        case .across:
            #expect(laid.panes.map(\.minX) == laid.panes.map(\.minX).sorted() && laid.panes.allSatisfy { $0.height == room.height })
        case .stacked:
            #expect(laid.panes.map(\.minY) == laid.panes.map(\.minY).sorted() && laid.panes.allSatisfy { $0.width == room.width })
        case .grid:
            #expect(laid.panes[0].minY == laid.panes[1].minY && laid.panes[1].maxX == room.maxX && laid.panes[2].maxY == room.maxY)
            if count == 4 { #expect(laid.panes[3].minX == laid.panes[0].minX && laid.panes[2].minY == laid.panes[3].minY) }
        }
    }

    @Test func dividersKeepEveryPaneItsLeast() {
        let room = Self.room
        // Three, the column divider far right and the right column's far up:
        // every pane keeps the narrowest a pane may be, and the lowest.
        let pushed = SplitLayout.panes(3, .grid, cuts: [0.95, 0.02], in: room).panes
        #expect(pushed.allSatisfy { $0.width >= Pair.narrowest && $0.height >= Pair.lowest })
        // Two stacked, dragged to the top: the top pane keeps a quarter, as
        // two halves do, and never less than the lowest.
        let top = SplitLayout.panes(2, .stacked, cuts: [0.0], in: room).panes
        #expect(top[0].height == max(Pair.lowest, ((room.height - Pair.gap) * Pair.least).rounded()))
        // A room short of three, laid evenly, never a negative size.
        for width: CGFloat in [0, 5, 400] {
            let tight = SplitLayout.panes(3, .grid, cuts: [0.1, 0.2], in: CGRect(x: 0, y: 0, width: width, height: 300))
            #expect(tight.panes.allSatisfy { $0.width >= 0 } && tight.cuts.allSatisfy { $0.width >= 0 })
        }
    }

    @Test func heldCutsAreWhereTheDividersWereDrawn() {
        let size = Self.room.size
        let held = SplitLayout.held([0.95, 0.96], 3, .grid, in: size)
        let again = SplitLayout.panes(3, .grid, cuts: held, in: CGRect(origin: .zero, size: size)).panes
        let first = SplitLayout.panes(3, .grid, cuts: [0.95, 0.96], in: CGRect(origin: .zero, size: size)).panes
        #expect(zip(again, first).allSatisfy { abs($0.width - $1.width) <= 1 && abs($0.height - $1.height) <= 1 })
        #expect(held.allSatisfy { $0 > 0 && $0 < 1 })
        let grid = SplitLayout.held([0.2, 0.9], 4, .grid, in: size)
        #expect(grid.count == 2 && grid.allSatisfy { $0 > 0 && $0 < 1 })
    }

    @Test func topPanes() {
        let id = Self.ids
        let three = Pair(first: id[0], second: id[1], more: [id[2]], arrangement: .grid)
        #expect(three.topPane(right: true) == id[1] && three.topPane(right: false) == id[0])
        let stacked = Pair(first: id[0], second: id[1], arrangement: .stacked)
        #expect(stacked.topPane(right: true) == id[0])
        let grid = Pair(first: id[0], second: id[1], more: [id[2], id[3]], arrangement: .grid)
        #expect(grid.topPane(right: true) == id[1] && grid.topPane(right: false) == id[0])
    }

    @MainActor @Test func movingCarriesEveryPane() {
        let row = (0..<6).map { _ in Tab() }
        func names(_ tabs: [Tab]) -> [Int] { tabs.map { tab in row.firstIndex { $0 === tab }! } }
        #expect(names(Browser.moving(row, row[1].id, to: 4, with: [row[2].id, row[3].id])) == [0, 4, 1, 2, 3, 5])
        #expect(names(Browser.moving(row, row[3].id, to: 0, with: [row[1].id, row[2].id])) == [1, 2, 3, 0, 4, 5])
    }
}

/// The browser making, growing, shrinking and closing a split of three or
/// four, as the column's drop and a pane's cross do.
@MainActor
struct SplitPanesBrowserTests {
    private func window() -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        return (browser, id)
    }

    private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private func settle(_ browser: Browser) async throws {
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(30))
            browser.settleNow()
        }
    }

    /// Opened and laid in this order, the row's order being the split's.
    private func open(_ browser: Browser, _ count: Int) -> [Tab] {
        let tabs = (0..<count).map { browser.open(URL(string: "https://example.test/\($0)")!, foreground: $0 == 0) }
        browser.lay(tabs)
        return tabs
    }

    @Test func dropOntoASplitAddsAPaneUpToFour() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let tabs = open(browser, 6)
        browser.pairs.append(Pair(first: tabs[0].id, second: tabs[1].id))
        #expect(browser.canSplit(tabs[2], onto: tabs[1]))
        browser.split(tabs[2], onto: tabs[1])
        try await settle(browser)
        #expect(browser.pair(of: tabs[0].id)?.ids == [tabs[0].id, tabs[1].id, tabs[2].id])
        #expect(browser.active === tabs[2])
        #expect(browser.pairs.count == 1)
        browser.split(tabs[3], onto: tabs[0])
        try await settle(browser)
        let four = try #require(browser.pair(of: tabs[3].id))
        #expect(four.count == 4)
        // Four panes, then nothing more.
        #expect(!browser.canSplit(tabs[4], onto: tabs[0]))
        // The panes stand together in the row, in the split's order.
        let row = browser.tabs.map(\.id)
        let at = try #require(row.firstIndex(of: four.first))
        #expect(Array(row[at..<at + 4]) == four.ids)
        // A tab let go on a lone tab still makes a pair.
        #expect(browser.canSplit(tabs[4], onto: tabs[5]))
    }

    @Test func aPaneOutOrClosedLeavesTheRest() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let tabs = open(browser, 5)
        browser.pairs.append(Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id, tabs[3].id]))
        browser.select(tabs[2])
        try await settle(browser)
        #expect(browser.stagePair?.count == 4)
        // The cross on a pane's band: out, and just after the split.
        browser.leaveSplit(tabs[2].id)
        try await settle(browser)
        let three = try #require(browser.pair(of: tabs[0].id))
        #expect(three.ids == [tabs[0].id, tabs[1].id, tabs[3].id])
        #expect(browser.pair(of: tabs[2].id) == nil && browser.tabs.contains { $0 === tabs[2] })
        #expect(browser.active === tabs[1])
        let row = browser.tabs.map(\.id)
        #expect(row.firstIndex(of: tabs[2].id) == row.firstIndex(of: tabs[3].id)! + 1)
        // Closed: two left, a pair.
        browser.close(tabs[3])
        try await settle(browser)
        #expect(browser.pair(of: tabs[0].id)?.halves == true)
        #expect(!browser.tabs.contains { $0 === tabs[3] })
        // One left: no split.
        browser.close(tabs[1])
        try await settle(browser)
        #expect(browser.pairs.isEmpty && browser.stagePair == nil)
    }

    @Test func arrangesAndKeepsTheRowTogether() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let tabs = open(browser, 5)
        let two = Pair(first: tabs[0].id, second: tabs[1].id)
        browser.pairs.append(two)
        #expect(browser.canArrange(two, .stacked) && !browser.canArrange(two, .grid) && !browser.canArrange(two, .across))
        browser.arrange(two, .stacked)
        #expect(browser.pair(of: tabs[0].id)?.arrangement == .stacked)
        // A third comes in as the grid; three and four offer no other layout.
        browser.addPane(tabs[2], to: try #require(browser.pair(of: tabs[0].id)))
        let three = try #require(browser.pair(of: tabs[0].id))
        #expect(three.arrangement == .grid && three.count == 3)
        for way in [Pair.Arrangement.across, .stacked, .grid] { #expect(!browser.canArrange(three, way)) }
        // A tab put between two panes: the panes come back together.
        var row = browser.tabs
        row.swapAt(2, 4)
        browser.lay(row)
        let ids = browser.tabs.map(\.id)
        let pair = try #require(browser.pair(of: tabs[0].id))
        let at = try #require(ids.firstIndex(of: pair.first))
        #expect(Array(ids[at..<at + 3]) == pair.ids)
        // Moved along the row: every pane goes with it.
        browser.move(tabs[0], to: browser.tabs.count - 1)
        let moved = browser.tabs.map(\.id)
        #expect(Array(moved.suffix(3)) == browser.pair(of: tabs[0].id)?.ids)
    }

    @Test func pinnedPairsStayTwoSideBySide() {
        let (browser, id) = window()
        defer { forget(id) }
        let tabs = open(browser, 3)
        let three = Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id])
        browser.pairs.append(three)
        #expect(!browser.canPinPair(three))
    }

    /// Duplicate on two stacked: the copies stacked too.
    @Test func duplicateKeepsTheLayoutOfTwo() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let tabs = open(browser, 2)
        let stacked = Pair(first: tabs[0].id, second: tabs[1].id, share: 0.4, arrangement: .stacked)
        browser.pairs = [stacked]
        browser.duplicateSplit(stacked)
        let copy = try #require(browser.pairs.first { !$0.contains(tabs[0].id) })
        #expect(copy.arrangement == .stacked && copy.share == 0.4 && browser.pairs.count == 2)
    }
}

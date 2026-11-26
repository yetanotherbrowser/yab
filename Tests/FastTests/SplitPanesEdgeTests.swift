import AppKit
import Foundation
import Testing
@testable import Fast

/// Three or four panes at their edges: the grid's dividers keeping every pane
/// its least, the window and column keeping every pane its width, a third chip
/// under the pointer, a split parked in a space sliding in, what floats over
/// the pane in front, and four's two rows in the column.
@MainActor @Suite(.serialized)
struct SplitPanesEdgeTests {
    private func window(_ count: Int) -> (Browser, UUID, [Tab]) {
        _ = NSApplication.shared
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let tabs = (0..<count).map { browser.open(URL(string: "https://example.test/\($0)")!, foreground: $0 == 0) }
        browser.lay(tabs)
        return (browser, id, tabs)
    }

    private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private func show(_ browser: Browser, _ pair: Pair, front: Tab) async throws {
        browser.pairs.append(pair)
        browser.select(front)
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(30))
            browser.settleNow()
        }
    }

    @Test func theGridsDividersKeepEveryPaneItsLeast() async throws {
        let (browser, id, tabs) = window(3)
        defer { forget(id) }
        try await show(browser, Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id], arrangement: .grid, cuts: [0.5]), front: tabs[0])
        browser.splitDrag.armed = true
        browser.splitDrag.grabbedCuts = [0.5, 0.5]
        // The column divider far right, the right column's far up: each stops
        // where its panes keep their least, and neither moves the other.
        browser.dragCuts(to: [0.98, 0.01])
        let cuts = try #require(browser.splitDrag.cuts)
        let panes = SplitLayout.panes(3, .grid, cuts: cuts, in: browser.splitBook.place).panes
        #expect(panes.allSatisfy { $0.width >= Pair.narrowest && $0.height >= Pair.lowest })
        browser.dragCuts(to: [0.98, 0.5])
        #expect(abs((browser.splitDrag.cuts?[1] ?? 0) - 0.5) < 0.01)
    }

    @Test func theColumnLeavesEveryPaneItsWidth() async throws {
        let (browser, id, tabs) = window(3)
        defer { forget(id) }
        try await show(browser, Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id], arrangement: .grid), front: tabs[0])
        // Three: the left pane and the right column, each its least.
        #expect(browser.columnMost == browser.splitBook.place.width + browser.sideShown - Pair.room)
        // Two side by side: as before.
        browser.leaveSplit(tabs[2].id)
        #expect(browser.stagePair?.halves == true)
        #expect(browser.columnMost == browser.splitBook.place.width + browser.sideShown - Pair.room)
    }

    @Test func aThirdChipIsTheTabUnderThePointer() {
        let (browser, id, tabs) = window(4)
        defer { forget(id); browser.letGo() }
        browser.pairs.append(Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id]))
        let cell = ColumnCell(kind: .pair)
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        cell.bind(ColumnItem(id: tabs[0].id.uuidString, kind: .pair(tabs[0], tabs[1]), indent: 0, y: 0, height: 34),
                  .init(browser: browser, look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0), liveID: nil), force: true)
        #expect(cell.tabUnderPointer(hovered: tabs[2]) == tabs[2].id)
        #expect(cell.tabUnderPointer(hovered: tabs[1]) == tabs[1].id)
        // A tab of no split, or of another row: nothing.
        #expect(cell.tabUnderPointer(hovered: tabs[3]) == nil)
    }

    @Test func aParkedSplitKeepsItsPanes() {
        let (browser, id, _) = window(1)
        defer { forget(id) }
        let away = (0..<3).map { _ in Tab() }
        browser.parked[UUID()] = Parked(tabs: away, active: away[0].id,
                                        pairs: [Pair(first: away[0].id, second: away[1].id, more: [away[2].id])])
        #expect(browser.morePanes(of: away[0].id).map(\.id) == [away[2].id])
        #expect(browser.morePanes(of: away[1].id).isEmpty)
    }

    @Test func whatFloatsOverThePageStaysOverThePaneInFront() async throws {
        let (browser, id, tabs) = window(4)
        defer { forget(id) }
        try await show(browser, Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id, tabs[3].id], arrangement: .grid, cuts: [0.5]), front: tabs[3])
        let room = browser.splitBook.place
        let grid = SplitLayout.panes(4, .grid, cuts: [0.5, 0.5], in: room).panes
        // Bottom left: down by the top row and the gap, the right column
        // to its right.
        let inset = try #require(browser.frontPaneInset())
        #expect(inset.top == grid[3].minY - room.minY && inset.top > 0)
        #expect(inset.bottom == 0 && inset.trailing == room.maxX - grid[3].maxX)
        browser.focus(tabs[0])
        let topLeft = try #require(browser.frontPaneInset())
        #expect(topLeft.top == 0 && topLeft.bottom == room.maxY - grid[0].maxY && topLeft.trailing == room.maxX - grid[0].maxX)
        // Two halves keep their own way (frontTrail).
        browser.removePane(tabs[3].id, from: try #require(browser.stagePair))
        browser.removePane(tabs[2].id, from: try #require(browser.stagePair))
        #expect(browser.stagePair?.halves == true && browser.frontPaneInset() == nil)
    }

    // Four's chips stand in two rows, in a row of the column as tall as two
    // rows; three's and two's rows, and every other row, keep one row's
    // height, and every row under it stays where its slot says.
    @Test func fourTakeTwoRowsInTheColumnAndNothingElseGrows() {
        let (browser, id, tabs) = window(9)
        let folders = Folders(emptiesFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        folders.browser = browser
        defer { folders.browser = nil; forget(id) }
        browser.pairs = [Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id, tabs[3].id], arrangement: .grid),
                         Pair(first: tabs[4].id, second: tabs[5].id, more: [tabs[6].id], arrangement: .grid)]
        let items = ColumnLayout.live(browser, folders: folders).filter { $0.height > 0 }
        let row = { (tab: Tab) in items.first { $0.id == tab.id.uuidString } }
        let four = row(tabs[0]), three = row(tabs[4]), loose = row(tabs[7]), last = row(tabs[8])
        #expect(four?.height == 2 * SideBar.row + SideBar.gap)
        #expect(three?.height == SideBar.row && loose?.height == SideBar.row && last?.height == SideBar.row)
        #expect(three.map(\.y) == four.map { $0.y + 2 * ColumnLayout.step })
        #expect(loose.map(\.y) == three.map { $0.y + ColumnLayout.step })
        for pane in [tabs[1], tabs[2], tabs[3], tabs[5], tabs[6]] { #expect(row(pane) == nil) }
        // The drag's and folders' slots agree with what is drawn.
        let slots = folders.slots(browser.tabs, joined: true)
        #expect(slots.tabs[tabs[4].id] == slots.tabs[tabs[0].id].map { $0 + 2 })
        for item in items {
            guard let tab = item.tab, let slot = slots.tabs[tab.id] else { continue }
            #expect(item.y == ColumnLayout.y(Double(slot), line: slots.folders[Folders.line]))
        }
        // The chips as the panes stand: the first and second above, the
        // fourth below the first and the third below the second.
        #expect(PairRow.chipRows(Array(tabs.prefix(4))).map { $0.map(\.id) } == [[tabs[0].id, tabs[1].id], [tabs[3].id, tabs[2].id]])
        #expect(PairRow.chipRows(Array(tabs.prefix(3))).map { $0.map(\.id) } == [tabs.prefix(3).map(\.id)])
    }

}

import AppKit
import Testing
@testable import Fast

/// A split of four in the column: its row is two rows tall, so what lands just
/// below it lands before the next row, and a press on any of its four chips
/// takes that chip's tab. The geometry is shared by both columns (ColumnKit's
/// AppKit one and the SwiftUI SideBar); the drags below are real local events
/// through ColumnGrip and ColumnHand.
@MainActor
@Suite(.serialized)
struct SplitFourColumnTests {
    /// Each chip's middle, from the row's top left, as PairRow draws them:
    /// worked out here from the row's sizes, not from PairRow's own chooser.
    private static func middles(width: CGFloat) -> [(line: Int, column: Int, point: CGPoint)] {
        let height = 2 * SideBar.row + SideBar.gap
        let chip = SideBar.row - 2 * PairRow.inset
        let half = (width - 2 * PairRow.inset - SideBar.gap) / 2
        let top = (height - (2 * chip + SideBar.gap)) / 2
        return [(0, 0), (0, 1), (1, 0), (1, 1)].map { line, column in
            (line, column, CGPoint(x: PairRow.inset + CGFloat(column) * (half + SideBar.gap) + half / 2,
                                   y: top + CGFloat(line) * (chip + SideBar.gap) + chip / 2))
        }
    }

    /// The tab each chip shows: the first and second above, the fourth below
    /// the first, the third below the second.
    private static func shown(_ tabs: [Tab], line: Int, column: Int) -> Tab {
        [[tabs[0], tabs[1]], [tabs[3], tabs[2]]][line][column]
    }

    @Test(arguments: Density.allCases)
    func everyChipOfFourIsTheTabItShows(_ density: Density) {
        let old = Density.current
        Density.current = density
        defer { Density.current = old }
        let tabs = (0..<4).map { _ in Tab() }
        for width: CGFloat in [200, 224, 320] {
            for chip in Self.middles(width: width) {
                #expect(PairRow.chip(tabs, at: chip.point, width: width) === Self.shown(tabs, line: chip.line, column: chip.column),
                        "\(density) \(width) \(chip.line),\(chip.column)")
            }
        }
        // Two and three: one row, chosen across it as before.
        #expect(PairRow.chip(Array(tabs.prefix(3)), at: CGPoint(x: 199, y: 20), width: 210) === tabs[2])
        #expect(PairRow.chip(Array(tabs.prefix(2)), at: CGPoint(x: 10, y: 30), width: 210) === tabs[0])
    }

    @Test(arguments: Density.allCases)
    func fourCountAsTwoRowsWhereAGapGoes(_ density: Density) async throws {
        try await world(density) { f in
            let tabs = f.split(), after = f.tab("After")
            f.sync()
            let cells = ColumnLayout.cells(f.browser)
            let group = try #require(cells.firstIndex { ColumnLayout.tab($0)?.id == tabs[0].id })
            #expect(ColumnLayout.rows(cells[group], folders: f.folders) == 2)
            // Two rows below the group's top: before the tab after it.
            let rows = ColumnLayout.rows(Array(cells[..<group]), folders: f.folders)
            let at = ColumnLayout.position(rows + 2, in: cells, folders: f.folders)
            #expect(cells.indices.contains(at) ? ColumnLayout.tab(cells[at])?.id == after.id : false, "gap at \(at) of \(cells.count)")
        }
    }

    @Test(arguments: Density.allCases)
    func aPinLetGoJustBelowFourLandsBeforeTheNextRow(_ density: Density) async throws {
        try await world(density) { f in
            let pin = f.tab("Pin"), tabs = f.split(), after = f.tab("After")
            f.browser.pin(pin)
            f.sync()
            let start = f.pinMiddle(0)
            // Into the after row's top quarter, where the gap opens before it.
            let below = try #require(f.page.rowMiddle(after.id.uuidString)) - SideBar.row / 4
            try f.send(.leftMouseDown, start)
            for step in 1...8 {
                try f.send(.leftMouseDragged, CGPoint(x: start.x, y: start.y + (below - start.y) * CGFloat(step) / 8))
            }
            try f.send(.leftMouseUp, CGPoint(x: start.x, y: below))
            f.sync()
            let row = f.browser.tabs.filter { $0.pin == nil }.map(\.id)
            #expect(pin.pin == nil)
            #expect(row == tabs.map(\.id) + [pin.id, after.id])
        }
    }

    @Test(arguments: Density.allCases)
    func eachChipOfFourIsTheOneTheHandTakes(_ density: Density) async throws {
        try await world(density) { f in
            let tabs = f.split(), other = f.tab("Other")
            f.browser.activeID = other.id
            f.sync()
            let item = try #require(f.page.items.first { $0.id == tabs[0].id.uuidString })
            #expect(item.height == 2 * SideBar.row + SideBar.gap)
            let top = try #require(f.page.rowMiddle(item.id)) - item.height / 2
            for chip in Self.middles(width: f.browser.prefs.sideWidth - 2 * SideBar.margin) {
                f.browser.activeID = other.id
                let start = CGPoint(x: SideBar.margin + chip.point.x, y: top + chip.point.y)
                try f.send(.leftMouseDown, start)
                for step in 1...3 { try f.send(.leftMouseDragged, CGPoint(x: start.x + CGFloat(step) * 4, y: start.y)) }
                #expect(f.page.hand.decking(tabs[0]) === Self.shown(tabs, line: chip.line, column: chip.column),
                        "\(density) chip \(chip.line),\(chip.column)")
                try f.send(.leftMouseUp, CGPoint(x: start.x + 12, y: start.y))
                f.sync()
            }
            #expect(f.browser.pair(of: tabs[0].id)?.ids == tabs.map(\.id))
        }
    }

    // MARK: - the column, as EmptyFolderDragTests sets it up

    private func world(_ density: Density, _ check: (Fixture) async throws -> Void) async throws {
        try #require(Store.testing && Store.unitTests && Store.world != nil && Store.settings !== UserDefaults.standard,
                     "isolated serial unit-test host required")
        let world = try #require(Store.world)
        _ = NSApplication.shared
        Session.settle()
        let domain = world == "test" ? "dev.serafim.fast.test" : "dev.serafim.fast.test.\(world)"
        let settings = Store.settings.persistentDomain(forName: domain)
        let oldDensity = Density.current
        let folderOwner = Folders.shared.browser
        Store.settings.set(false, forKey: "mail")
        Store.settings.set(false, forKey: "search.suggest")
        let browser = Browser(windowID: UUID())
        browser.lookForMailSignInLink = {}
        browser.dropSpare()
        browser.tabs.forEach { $0.close() }
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.usesSpaces)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240; prefs.usesSpaces = false
        Density.current = density
        let space = Space(id: UUID(), name: "Split column fixture", icon: "S", ownSignIns: false)
        browser.spaces = [space]
        browser.spaceID = space.id
        browser.lay([])
        browser.activeID = nil
        browser.takeOwnFolders()
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 240, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = ColumnPage(browser: browser, space: space.id)
        page.frame = CGRect(x: 0, y: 0, width: 240, height: 650)
        window.contentView = page
        let f = Fixture(browser: browser, page: page, window: window)
        defer {
            page.hand.grip.watch(false)
            window.close()
            browser.letGoArranging()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.letGo()
            browser.dropSpare()
            browser.folderBook.browser = nil
            Folders.shared.browser = folderOwner
            Session.settle()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Store.folder.path)) ?? []
            for name in files where name.contains(space.id.uuidString) || browser.windowID.map({ name.contains($0.uuidString) }) == true {
                try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name))
            }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2; prefs.usesSpaces = old.3
            if let settings { Store.settings.setPersistentDomain(settings, forName: domain) }
            else { Store.settings.removePersistentDomain(forName: domain) }
            Density.current = oldDensity
            Spaces.pageCounts[space.id] = nil
        }
        f.sync()
        let surface = EventSurface(frame: page.bounds)
        page.addSubview(surface, positioned: .above, relativeTo: nil)
        try await check(f)
    }

    private final class EventSurface: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    @MainActor
    private final class Fixture {
        let browser: Browser
        let page: ColumnPage
        let window: NSWindow
        var folders: Folders { browser.folderBook }

        init(browser: Browser, page: ColumnPage, window: NSWindow) {
            self.browser = browser; self.page = page; self.window = window
        }

        func tab(_ name: String) -> Tab {
            let tab = Tab()
            tab.restore(url: URL(string: "https://split-column.invalid/" + UUID().uuidString)!, title: name)
            browser.prepare(tab)
            browser.lay(browser.tabs + [tab])
            folders.refresh()
            return tab
        }

        /// Four tabs of today's in one split, the 2x2.
        func split() -> [Tab] {
            let tabs = ["A", "B", "C", "D"].map(tab)
            browser.pairs.append(Pair(first: tabs[0].id, second: tabs[1].id, more: [tabs[2].id, tabs[3].id], arrangement: .grid))
            return tabs
        }

        func sync() {
            folders.refresh()
            page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                      frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount),
                                               footRoom: 0, top: 36, foot: false),
                      look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
        }

        func pinMiddle(_ index: Int) -> CGPoint {
            let middle = ColumnLayout.pinCenter(index, count: browser.pinCellCount, width: browser.prefs.sideWidth,
                                                top: ColumnLayout.pinsTop(browser))
            return CGPoint(x: SideBar.margin + middle.x, y: middle.y)
        }

        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                location: page.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
    }
}

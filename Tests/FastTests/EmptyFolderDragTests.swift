import AppKit
import Testing
@testable import Fast

/// Actual local NSEvents through ColumnGrip -> ColumnHand. Fixture validity
/// must pass before a drag assertion can count as regression evidence.
@MainActor
@Suite(.serialized)
struct EmptyFolderDragTests {
    @Test(arguments: Density.allCases, [false, true])
    func anEmptySiblingMovesBeforeTheFirst(_ density: Density, _ open: Bool) async throws {
        try await world(density) { f in
            let a = try f.empty("A", open: open), b = try f.empty("B", open: open)
            try f.render([a, b])
            let drag = try f.begin(b, want: -0.49)
            #expect(!f.drawn(a).hold.aimed)
            #expect(abs(f.drawn(a).shift.height - ColumnLayout.step) < 0.01, "preview opens the same before-A gap")
            try f.end(drag)
            f.expectOrder([b, a])
            #expect(a.parent == nil && b.parent == nil && a.stand == nil && b.stand == nil)
            #expect(a.open == open && b.open == open)
        }
    }

    @Test(arguments: Density.allCases, [false, true])
    func leavingIntoUsesTheRetainedBandBeforeReordering(_ density: Density, _ open: Bool) async throws {
        try await world(density) { f in
            let a = try f.empty("A", open: open), b = try f.empty("B", open: open)
            try f.render([a, b])
            var drag = try f.begin(b, want: 0)
            #expect(f.drawn(a).hold.aimed)
            try f.move(&drag, want: -0.49)
            #expect(f.drawn(a).hold.aimed, "the retained 0.6 band still means into A")
            try f.move(&drag, want: -0.65)
            #expect(!f.drawn(a).hold.aimed)
            #expect(abs(f.drawn(a).shift.height - ColumnLayout.step) < 0.01)
            try f.end(drag)
            f.expectOrder([b, a])
            #expect(b.parent == nil)
        }
    }

    @Test(arguments: Density.allCases, [false, true])
    func threeSiblingsKeepTheirMiddleGapInBothDirections(_ density: Density, _ down: Bool) async throws {
        try await world(density) { f in
            let a = try f.empty("A"), b = try f.empty("B"), c = try f.empty("C")
            try f.render([a, b, c])
            let drag = try f.begin(down ? a : c, want: down ? 1.5 : 0.5)
            if down {
                #expect(abs(f.drawn(b).shift.height + ColumnLayout.step) < 0.01)
                #expect(abs(f.drawn(c).shift.height) < 0.01)
            } else {
                #expect(abs(f.drawn(a).shift.height) < 0.01)
                #expect(abs(f.drawn(b).shift.height - ColumnLayout.step) < 0.01)
            }
            try f.end(drag)
            f.expectOrder(down ? [b, a, c] : [a, c, b])
        }
    }

    @Test(arguments: Density.allCases)
    func downwardEndAndCancelRetainTheirExistingMeaning(_ density: Density) async throws {
        try await world(density) { f in
            let a = try f.empty("A"), b = try f.empty("B"), c = try f.empty("C")
            try f.render([a, b, c])
            let cancelled = try f.begin(c, want: 0.5)
            #expect(abs(f.drawn(b).shift.height - ColumnLayout.step) < 0.01)
            f.page.hand.grip.state = .cancelled
            try f.send(.leftMouseUp, cancelled.last)
            f.expectOrder([a, b, c])
            let down = try f.begin(a, want: 2.49)
            try f.end(down)
            f.expectOrder([b, c, a])
        }
    }

    @Test(arguments: Density.allCases, [false, true])
    func aStaleAnchorNeverFallsThroughToAppend(_ density: Density, _ removed: Bool) async throws {
        try await world(density) { f in
            let a = try f.empty("A"), b = try f.empty("B"), c = try f.empty("C")
            try f.render([a, b, c])
            let drag = try f.begin(b, want: -0.49)
            if removed { f.folders.removeEmpty(a) }
            else { a.parent = c; f.folders.emptyChanged(a); f.folders.refresh() }
            // No second move refreshes the destination after the concurrent change.
            try f.end(drag)
            f.expectOrder([b, c], persisted: removed ? [b, c] : [a, b, c])
            #expect(b.parent == nil && b.stand == nil)
        }
    }

    @Test(arguments: Density.allCases)
    func theInitialIntoBandStillFilesAnEmptyFolder(_ density: Density) async throws {
        try await world(density) { f in
            let a = try f.empty("A"), b = try f.empty("B")
            try f.render([a, b])
            let drag = try f.begin(b, want: 0.39)
            #expect(f.drawn(a).hold.aimed)
            try f.end(drag)
            #expect(b.parent === a)
            f.expectOrder([a], persisted: [a, b])
        }
    }

    @Test(arguments: Density.allCases)
    func requestingDepthDoesNotSelectAFlatSiblingGap(_ density: Density) async throws {
        try await world(density) { f in
            let a = try f.empty("A"), b = try f.empty("B")
            try f.render([a, b])
            let drag = try f.begin(b, want: -0.49, sideways: 15)
            #expect(!f.drawn(a).hold.aimed)
            try f.end(drag)
            f.expectOrder([a, b])
        }
    }

    @Test(arguments: Density.allCases)
    func aTabAnchoredEmptyKeepsItsTabHeadRoute(_ density: Density) async throws {
        try await world(density) { f in
            let tab = f.tab("Kept", kept: true)
            let a = try f.empty("Anchored"), b = try f.empty("Held")
            f.folders.stand(a, before: tab.id)
            try f.render([a, b])
            let drag = try f.begin(b, want: -0.49)
            try f.end(drag)
            #expect(b.stand?.before == tab.id && a.stand?.before == tab.id)
            #expect(b.parent == nil && tab.kept && tab.nest == nil)
            #expect(f.browser.tabs.map(\.id) == [tab.id])
            f.expectOrder([b, a], persisted: [b, a], block: [])
        }
    }

    @Test(arguments: Density.allCases)
    func aNestedEmptyRetainsTheExistingIntoRoute(_ density: Density) async throws {
        try await world(density) { f in
            let p = try f.empty("Parent", open: true)
            let child = try f.empty("Child", parent: p)
            let other = try f.empty("Other")
            try f.render([p, child, other])
            let otherSlot = try #require(f.folders.slots(f.browser.tabs, joined: false).folders[other.key])
            let drag = try f.begin(child, want: Double(otherSlot))
            #expect(f.drawn(other).hold.aimed)
            try f.end(drag)
            #expect(child.parent === other && p.parent == nil && other.parent == nil)
            #expect(f.browser.tabs.isEmpty)
            f.expectOrder([p, other], persisted: [p, child, other])
        }
    }

    @Test(arguments: Density.allCases)
    func nonemptyFoldersStillMoveTheirActualKeptTabs(_ density: Density) async throws {
        try await world(density) { f in
            let a = Nest(name: "A", open: false), b = Nest(name: "B", open: false)
            let one = f.tab("One", kept: true, nest: a), two = f.tab("Two", kept: true, nest: b)
            try f.render([a, b])
            let drag = try f.begin(b, want: -0.49)
            try f.end(drag)
            #expect(f.browser.tabs.map(\.id) == [two.id, one.id])
            #expect(one.nest === a && two.nest === b && a.parent == nil && b.parent == nil)
            #expect(f.page.items.filter { $0.folderKey != nil }.map(\.id) == [b.key, a.key])
            f.expectReleased()
        }
    }

    @Test(arguments: Density.allCases)
    func todaysFolderStillMovesWholeIntoKept(_ density: Density) async throws {
        try await world(density) { f in
            let kept = Nest(name: "Kept", open: false), today = Nest(name: "Today", open: false)
            today.fleeting = true
            // Two of today's, filed together: a folder of today's with one
            // tab dissolves (Folders.settle, cd22054b9), so it would leave
            // no row, and `tab` refreshes the folders after each tab.
            let one = f.tab("One", kept: true, nest: kept), two = f.tab("Two", kept: false), three = f.tab("Three", kept: false)
            two.nest = today; three.nest = today
            f.folders.refresh()
            try f.render([kept, today])
            let drag = try f.begin(today, want: -0.49)
            try f.end(drag)
            #expect(two.kept && three.kept && !today.today && two.nest === today && three.nest === today)
            #expect(f.browser.tabs.map(\.id) == [two.id, three.id, one.id])
            #expect(one.kept && one.nest === kept)
            #expect(f.page.items.filter { $0.folderKey != nil }.map(\.id) == [today.key, kept.key])
            f.expectReleased()
        }
    }

    /// Feedback #1981 (R2535): a new folder, empty, carried up step by step
    /// as a hand does and let go on the line between two shut folders with
    /// tabs stands between them; it went into one of them, every time.
    @Test(arguments: Density.allCases)
    func aNewEmptyFolderGoesBetweenTwoShutFolders(_ density: Density) async throws {
        try await world(density) { f in
            let a = Nest(name: "A", open: false), b = Nest(name: "B", open: false)
            let one = f.tab("One", kept: true, nest: a), two = f.tab("Two", kept: true, nest: b)
            let fresh = try f.empty("Fresh", open: true)
            try f.render([a, b, fresh])
            var drag = try f.begin(fresh, want: 1.7)
            for step in stride(from: 1.6, through: 0.5, by: -0.1) { try f.move(&drag, want: step) }
            #expect(!f.drawn(a).hold.aimed && !f.drawn(b).hold.aimed, "between, not into either")
            try f.end(drag)
            #expect(fresh.parent == nil && one.nest === a && two.nest === b)
            #expect(f.page.items.filter { $0.folderKey != nil }.map(\.id) == [a.key, fresh.key, b.key])
            f.expectReleased()
        }
    }

    /// The same hand stopping on a shut folder's middle still files it there.
    @Test(arguments: Density.allCases)
    func aNewEmptyFolderHeldOnAShutFoldersMiddleGoesIn(_ density: Density) async throws {
        try await world(density) { f in
            let a = Nest(name: "A", open: false), b = Nest(name: "B", open: false)
            _ = f.tab("One", kept: true, nest: a)
            _ = f.tab("Two", kept: true, nest: b)
            let fresh = try f.empty("Fresh", open: true)
            try f.render([a, b, fresh])
            var drag = try f.begin(fresh, want: 1.7)
            for step in stride(from: 1.6, through: 1.0, by: -0.1) { try f.move(&drag, want: step) }
            #expect(f.drawn(b).hold.aimed)
            try f.end(drag)
            #expect(fresh.parent === b)
        }
    }

    /// A folder with tabs between two shut ones, from below and from above.
    @Test(arguments: Density.allCases, [false, true])
    func aShutFolderGoesBetweenTwoShutFolders(_ density: Density, _ down: Bool) async throws {
        try await world(density) { f in
            let a = Nest(name: "A", open: false), b = Nest(name: "B", open: false), c = Nest(name: "C", open: false)
            let one = f.tab("One", kept: true, nest: a), two = f.tab("Two", kept: true, nest: b), three = f.tab("Three", kept: true, nest: c)
            try f.render([a, b, c])
            let held = down ? a : c
            var drag = try f.begin(held, want: down ? 0.3 : 1.7)
            for step in stride(from: 0.4, through: 1.4, by: 0.1) { try f.move(&drag, want: down ? step : 2 - step) }
            try f.move(&drag, want: down ? 1.5 : 0.5)
            #expect(![a, b, c].contains { $0 !== held && f.drawn($0).hold.aimed }, "between, not into either")
            try f.end(drag)
            #expect(held.parent == nil && one.nest === a && two.nest === b && three.nest === c)
            let order: [Tab.ID] = down ? [two.id, one.id, three.id] : [one.id, three.id, two.id]
            #expect(f.browser.tabs.map(\.id) == order)
            f.expectReleased()
        }
    }

    /// evals/space-switching/drags.py's into-folder take, without the
    /// window server: a loose row of today's carried onto a shut folder of
    /// yours' own row, held there or not, then let go: it goes in.
    @Test(arguments: [false, true])
    func aLooseTabLetGoOverAShutFolderRowGoesIn(_ hold: Bool) async throws {
        try await world(.comfortable) { f in
            let box = Nest(name: "Box", open: false)
            let a = f.tab("A", kept: true, nest: box), b = f.tab("B", kept: true, nest: box)
            let loose = f.tab("Loose", kept: false)
            try f.render([box])
            let from = try #require(f.page.rowMiddle(loose.id.uuidString))
            let to = try #require(f.page.rowMiddle(box.key))
            try f.send(.leftMouseDown, CGPoint(x: 120, y: from))
            for step in 1...14 {
                try f.send(.leftMouseDragged, CGPoint(x: 120, y: from + (to - from) * CGFloat(step) / 14))
            }
            if hold {
                for step in 1...5 {
                    try await Task.sleep(for: .milliseconds(200))
                    try f.send(.leftMouseDragged, CGPoint(x: 120, y: to + CGFloat(step % 2) * 0.5))
                }
            }
            try f.send(.leftMouseUp, CGPoint(x: 120, y: to))
            // The row sinks into the folder for 0.16 s before it is filed.
            try await Task.sleep(for: .milliseconds(800))
            f.sync()
            #expect(loose.nest === box, "hold=\(hold): \(loose.nest?.name ?? "loose")")
            #expect(loose.kept && a.nest === box && b.nest === box)
        }
    }

    /// #1037: split view pairs among the kept, each drawn as one row, and a
    /// folder of today's carried up and let go just above Clear, under an
    /// open folder of yours: it stays a folder of its own there. Measured
    /// with every tab of a pair as a row, the place was a row low for each
    /// pair above, among the open folder's tabs, and it went into it.
    @Test(arguments: Density.allCases, [0.1, 0.3])
    func anUnpinnedFolderDroppedUnderPairsStaysOnItsOwn(_ density: Density, _ above: Double) async throws {
        try await world(density) { f in
            let pairs = (0..<3).map { _ in (f.tab("Left", kept: true), f.tab("Right", kept: true)) }
            f.browser.pairs = pairs.map { Pair(first: $0.0.id, second: $0.1.id) }
            let open = Nest(name: "Open", open: true)
            let inside = (0..<4).map { f.tab("In \($0)", kept: true, nest: open) }
            let today = Nest(name: "Today", open: false)
            today.fleeting = true
            let four = f.tab("Four", kept: false), five = f.tab("Five", kept: false)
            _ = f.tab("Loose", kept: false)
            four.nest = today; five.nest = today
            f.sync()
            let slots = f.folders.slots(f.browser.tabs, joined: true).folders
            let line = try #require(slots[Folders.line]), from = try #require(slots[today.key])
            try #require(slots[open.key] == 3, "the three pairs are three rows")
            // The fixture's `begin` counts a pair as two rows; start from the
            // row as drawn.
            let start = CGPoint(x: 120, y: try #require(f.page.rowMiddle(today.key)))
            var drag = Fixture.Drag(start: start, from: from, last: start)
            try f.send(.leftMouseDown, start)
            for step in stride(from: Double(from) - 0.5, through: Double(line) - above, by: -0.05) { try f.move(&drag, want: step) }
            try f.move(&drag, want: Double(line) - above)
            try #require(f.folders.carried == today.key, "a real carry")
            try f.end(drag)
            #expect(today.parent == nil, "went into \(today.parent?.name ?? "none")")
            #expect(!today.today && four.kept && five.kept && four.nest === today && five.nest === today)
            #expect(inside.allSatisfy { $0.nest === open })
            let kept = f.browser.tabs.filter(\.kept).map(\.id)
            #expect(Array(kept.suffix(2)) == [four.id, five.id], "at the end of the kept, under Open's run; kept: \(f.browser.tabs.filter(\.kept).map { "\($0.title)/\($0.nest?.name ?? "-")" })")
            f.expectReleased()
        }
    }

    @Test(arguments: Density.allCases)
    func aKeptFolderCrossesClearInBothDirections(_ density: Density) async throws {
        try await world(density) { f in
            let folder = Nest(name: "Keep me", open: false)
            let inside = f.tab("Inside", kept: true, nest: folder)
            let outside = f.tab("Outside", kept: false)
            try f.render([folder])
            let line = try #require(f.folders.slots(f.browser.tabs, joined: false).folders[Folders.line])
            let down = try f.begin(folder, want: Double(line + Folders.lineRows + 2))
            try f.end(down)
            #expect(folder.ordinaryToday && !inside.kept && inside.nest === folder)
            #expect(f.browser.tabs.map(\.id) == [outside.id, inside.id])
            let up = try f.begin(folder, want: -0.49)
            try f.end(up)
            #expect(!folder.today && inside.kept && inside.nest === folder)
            #expect(f.browser.tabs.map(\.id) == [inside.id, outside.id])
            f.expectReleased()
        }
    }

    @Test(arguments: Density.allCases)
    func anEmptyTodayFolderClearsAndComesBackWithUndo(_ density: Density) async throws {
        try await world(density) { f in
            let folder = try f.empty("Empty")
            _ = f.tab("Outside", kept: false)
            try f.render([folder])
            let line = try #require(f.folders.slots(f.browser.tabs, joined: false).folders[Folders.line])
            let down = try f.begin(folder, want: Double(line + Folders.lineRows + 2))
            try f.end(down)
            #expect(folder.ordinaryToday)
            #expect(!f.folders.keeps)
            #expect(f.folders.todayBlock.contains { $0 === folder })
            let saved = Folders.readEmpties(from: Store.file("empty-folders.json"))[f.browser.spaceID]
            #expect(saved?.first(where: { $0.id == folder.id })?.ordinaryToday == true)
            f.browser.tidyNow()
            // The native dust animation completes asynchronously when a column exists.
            try await Task.sleep(for: .milliseconds(900))
            #expect(!f.folders.empties.contains { $0 === folder })
            f.browser.untidy()
            f.sync()
            #expect(f.folders.empties.contains { $0 === folder })
            #expect(folder.ordinaryToday)
            let up = try f.begin(folder, want: -0.49)
            try f.end(up)
            #expect(!folder.today && f.folders.block.contains { $0 === folder })
        }
    }

    @Test(arguments: Density.allCases)
    func theFirstTodayFolderBringsTheDividerWithItsPreview(_ density: Density) async throws {
        try await world(density) { f in
            let folder = Nest(name: "First Today", open: false)
            let inside = f.tab("Inside", kept: true, nest: folder)
            try f.render([folder])
            let newTab = try #require(f.folders.slots(f.browser.tabs, joined: false).folders[Folders.newTab])
            let down = try f.begin(folder, want: Double(newTab + 3))
            #expect(f.page.hand.shape.lineComes)
            try f.end(down)
            #expect(folder.today && !inside.kept && inside.nest === folder)
            #expect(f.folders.lined)
        }
    }

    private func world(_ density: Density, _ check: (Fixture) async throws -> Void) async throws {
        try #require(Store.testing && Store.unitTests && Store.world != nil && Store.settings !== UserDefaults.standard,
                     "EMPTY_DRAG_FIXTURE_INVALID: isolated serial unit-test host required")
        let world = try #require(Store.world)
        _ = NSApplication.shared
        Session.settle()
        let domain = world == "test" ? "dev.serafim.fast.test" : "dev.serafim.fast.test.\(world)"
        let settings = Store.settings.persistentDomain(forName: domain)
        let oldDensity = Density.current
        let emptyFile = Store.file("empty-folders.json")
        let emptyData = FileManager.default.fileExists(atPath: emptyFile.path) ? try Data(contentsOf: emptyFile) : nil
        let folderOwner = Folders.shared.browser
        let sharing = Spaces.sharing
        let offeredPasskeys = FormRelay.passkeysOffered
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
        let space = Space(id: UUID(), name: "Empty drag fixture", icon: "F", ownSignIns: false)
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
            browser.folderBook.putEmpties([])
            browser.folderBook.browser = nil
            Folders.shared.browser = folderOwner
            Spaces.sharing = sharing
            FormRelay.passkeysOffered = offeredPasskeys
            Session.settle()
            let files: [String]
            do { files = try FileManager.default.contentsOfDirectory(atPath: Store.folder.path) }
            catch { Issue.record(error); files = [] }
            for name in files where name.contains(space.id.uuidString) || browser.windowID.map({ name.contains($0.uuidString) }) == true {
                do { try FileManager.default.removeItem(at: Store.folder.appendingPathComponent(name)) }
                catch { Issue.record(error) }
            }
            do {
                if let emptyData { try emptyData.write(to: emptyFile, options: .atomic) }
                else if FileManager.default.fileExists(atPath: emptyFile.path) { try FileManager.default.removeItem(at: emptyFile) }
            } catch { Issue.record(error) }
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

        func empty(_ name: String, open: Bool = false, parent: Nest? = nil) throws -> Nest {
            let nest = try #require(folders.makeEmpty(named: name, in: parent))
            nest.open = open
            folders.emptyChanged(nest)
            return nest
        }

        func tab(_ name: String, kept: Bool, nest: Nest? = nil) -> Tab {
            let tab = Tab()
            tab.restore(url: URL(string: "https://empty-folder.invalid/" + UUID().uuidString)!, title: name)
            tab.kept = kept; tab.nest = nest
            browser.prepare(tab)
            browser.lay(browser.tabs + [tab])
            folders.refresh()
            return tab
        }

        func sync() {
            folders.refresh()
            page.live(ColumnLayout.live(browser), head: ColumnLayout.head(browser),
                      frame: ColumnPages.Frame(lead: ColumnLayout.lead(browser, pins: browser.pinCellCount),
                                               footRoom: 0, top: 36, foot: false),
                      look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
            page.layoutSubtreeIfNeeded()
        }

        func render(_ nests: [Nest]) throws {
            sync()
            let rows = page.items.filter { $0.folderKey != nil }
            let visible = page.scrollView.documentView?.subviews.compactMap { $0 as? ColumnCell }
                .filter { !$0.isHidden && $0.kind == .nest && $0.current != nil } ?? []
            let valid = rows.map(\.id) == nests.map(\.key)
                && nests.allSatisfy { nest in visible.contains { $0.itemID == nest.key } }
                && browser.tabs.allSatisfy { !$0.bench && $0.built == nil }
            print("EMPTY_DRAG_FIXTURE density=\(Density.current.rawValue) valid=\(valid) rows=\(rows.map(\.id)) cells=\(visible.map(\.itemID))")
            if !valid {
                print("EMPTY_DRAG_FIXTURE want=\(nests.map { "\($0.name)=\($0.key) today=\($0.today)" }) items=\(page.items.map(\.id))")
                print("EMPTY_DRAG_FIXTURE tabs=\(browser.tabs.map { "\($0.title) kept=\($0.kept) nest=\($0.nest?.name ?? "-") pin=\($0.pin != nil) bench=\($0.bench) built=\($0.built != nil) gone=\($0.gone)" }) folders=\(folders.folders.map { "\($0.id) n=\($0.members.count)" })")
            }
            try #require(valid, "EMPTY_DRAG_FIXTURE_INVALID: actual ordered native nest rows and bound visible cells required")
        }

        func drawn(_ nest: Nest) -> ColumnHand.Drawn {
            let item = page.items.first { $0.id == nest.key }!
            return page.hand.drawn(item)
        }

        struct Drag { let start: CGPoint; let from: Int; var last: CGPoint }

        func begin(_ nest: Nest, want: Double, sideways: CGFloat = 0) throws -> Drag {
            let from = try #require(folders.slots(browser.tabs.filter { $0.pin == nil }, joined: false).folders[nest.key])
            let start = CGPoint(x: 120, y: try #require(page.rowMiddle(nest.key)))
            let before = page.hand.grip.heard["began", default: 0]
            try send(.leftMouseDown, start)
            var drag = Drag(start: start, from: from, last: start)
            try move(&drag, want: want, sideways: sideways)
            try #require(page.hand.grip.heard["began", default: 0] == before + 1,
                         "EMPTY_DRAG_FIXTURE_INVALID: the real local monitor must begin exactly one drag")
            try #require(folders.carried == nest.key, "EMPTY_DRAG_FIXTURE_INVALID: actual .nest carry required")
            return drag
        }

        func move(_ drag: inout Drag, want: Double, sideways: CGFloat = 0) throws {
            let line = ColumnLayout.lineSlot(in: ColumnLayout.cells(browser), folders: folders)
            drag.last = CGPoint(x: drag.start.x + sideways,
                y: drag.start.y + ColumnLayout.y(want, line: line) - ColumnLayout.y(Double(drag.from), line: line))
            try send(.leftMouseDragged, drag.last)
        }

        func end(_ drag: Drag) throws {
            try send(.leftMouseUp, drag.last)
            sync()
        }

        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                location: page.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }

        func expectOrder(_ nests: [Nest], persisted: [Nest]? = nil, block: [Nest]? = nil) {
            sync()
            #expect(folders.block.map(\.id) == (block ?? nests).map(\.id))
            #expect(page.items.filter { $0.folderKey != nil }.map(\.id) == nests.map(\.key))
            Session.settle()
            #expect(Folders.readEmpties(from: Store.file("empty-folders.json"))[browser.spaceID]?.map(\.id) == (persisted ?? nests).map(\.id))
            expectReleased()
        }

        func expectReleased() {
            #expect(page.hand.grip.state == .idle)
            #expect((page.hand.state["nest"] as? String) == "")
            #expect(folders.carried == nil && page.hand.dragging == nil)
            #expect(browser.tabs.allSatisfy { $0.built == nil })
        }
    }
}

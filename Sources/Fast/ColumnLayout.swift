import AppKit

/// One row of the AppKit column (ColumnPages) as the SwiftUI column draws
/// it: what it shows, how far in, where it stands. Laid by `ColumnLayout`.
@MainActor
struct ColumnItem {
    enum Kind {
        case tab(Tab)
        /// Two tabs side by side, one row (PairRow).
        case pair(Tab, Tab)
        /// A folder of yours over its first tab, or an empty one.
        case nest(Nest, count: Int, over: FacePose?)
        /// A task's folder (FolderRow).
        case task(Folders.Folder, open: Bool)
        /// An open task folder holding some back: "3 more".
        case more(String, Int)
        /// The line under the kept tabs, its row's room only while shown.
        case line
        case newTab
        /// Where what is carried would land: a pin brought down, a stack.
        case gap
        /// Over the rows, not scrolling with them: a pin, the cell a row
        /// carried up would take, a pin's home typed in, the space's name.
        case pin(Tab)
        case pinGap
        case home(Tab)
        case name(Space)
        case privateName
        /// The line on its way in under a row being kept, the first.
        case lineComing

        var isPinCell: Bool {
            switch self {
            case .pin, .pinGap: return true
            default: return false
            }
        }

        var isHome: Bool {
            if case .home = self { return true }
            return false
        }
    }

    /// Stable across layouts: a tab's id, a folder's key, "line"...
    let id: String
    let kind: Kind
    /// How far in from the rows' own edge it is drawn, a folder's steps.
    let indent: CGFloat
    /// From the top of the rows, and how tall: a row, or nothing.
    var y: CGFloat
    let height: CGFloat
    /// Where a pin or the name stands across, in from the column's margin,
    /// and how wide: rows take the column's width less their indent.
    var x: CGFloat? = nil
    var width: CGFloat? = nil

    /// A pin, or the cell one takes.
    var isPin: Bool { kind.isPinCell }
    private var unusedIsPin: Bool {
        switch kind {
        case .pin, .pinGap: return true
        default: return false
        }
    }

    /// The tab the row is, or the first of a pair.
    var tab: Tab? {
        switch kind {
        case .tab(let tab), .pair(let tab, _), .pin(let tab): return tab
        default: return nil
        }
    }

    /// The folder whose row this is, by its key.
    var folderKey: String? {
        switch kind {
        case .nest(let nest, _, _): return nest.key
        case .task(let folder, _): return folder.id
        default: return nil
        }
    }

    /// The same thing drawn the same way, its place aside.
    func same(_ other: ColumnItem) -> Bool {
        guard id == other.id, indent == other.indent, height == other.height else { return false }
        switch (kind, other.kind) {
        case (.tab(let a), .tab(let b)): return a === b
        case (.pair(let a, let b), .pair(let c, let d)): return a === c && b === d
        case (.nest(let a, let n, let o), .nest(let b, let m, let p)): return a === b && n == m && o == p
        case (.task(let a, let o), .task(let b, let p)): return a == b && o == p
        case (.more(let a, let n), .more(let b, let m)): return a == b && n == m
        case (.line, .line), (.newTab, .newTab), (.gap, .gap), (.pinGap, .pinGap), (.lineComing, .lineComing), (.privateName, .privateName): return true
        case (.pin(let a), .pin(let b)), (.home(let a), .home(let b)): return a === b && x == other.x && width == other.width
        case (.name(let a), .name(let b)): return a == b
        default: return false
        }
    }
}

/// The rows of the space on screen as SideBar lays them (`baseSlots` and
/// `loose(_:)` in Side.swift): the kept, each folder of yours a row before
/// its first tab and its tabs stepped in under it while it is open, empty
/// folders at the end of the kept or of the folder they are in, the line
/// and New tab heading today's, a task's folders and their "N more". Only
/// rows that take room: a tab tucked away in a shut folder is none.
@MainActor
enum ColumnLayout {
    /// The step from one row to the next: a row and the gap under it.
    static var step: CGFloat { SideBar.row + SideBar.gap }
    /// The line's strip and the gap under it: less than a row, as Arc's.
    static var lineStep: CGFloat { SideBar.line + SideBar.gap }

    /// Where a slot (a row as Folders.slots counts them) starts, from the
    /// top of the rows: every slot a step, but those past the line, which
    /// counts as one and takes less (`line`, its slot, nil with none).
    static func y(_ slot: Double, line: Int?) -> CGFloat {
        let y = CGFloat(slot) * step
        guard let line, slot > Double(line) else { return y }
        return y - SideBar.lineShort * min(1, CGFloat(slot - Double(line)))
    }

    /// The slot standing at `y` down the rows, fractional: `y(_:line:)`
    /// undone.
    static func slot(_ y: CGFloat, line: Int?) -> Double {
        guard let line else { return Double(y / step) }
        let top = CGFloat(line) * step
        if y <= top { return Double(y / step) }
        if y < top + lineStep { return Double(line) + Double((y - top) / lineStep) }
        return Double((y + SideBar.lineShort) / step)
    }

    /// What a hand on the rows changes in how they are laid
    /// (SideBar.looseSlots): rows gone from the list but for the gap under
    /// them, a row in the hand folded to nothing as SideBar folds it, and a
    /// gap where what is carried would land.
    struct FolderFormation: Equatable {
        let target: Tab.ID
        let held: Tab.ID
        let nest: Nest
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target && lhs.held == rhs.held && lhs.nest === rhs.nest
        }
    }

    struct Shape: Equatable {
        var forming: FolderFormation?
        /// Folded to nothing, their gap kept: the row carried up into the
        /// pins, the held one of a stack.
        var folded: Set<Tab.ID> = []
        /// Out of the list: the rest of a stack in the hand.
        var out: Set<Tab.ID> = []
        /// A gap this many rows down, as drawn, where a pin brought down or
        /// a stack would land; `skip`, a row not counted on the way.
        var gap: Int?
        var skip: Tab.ID?
        /// On their way out of the rows, up into the pins or out of the
        /// window: the line over New tab stands for today's left without them.
        var pinning: Set<Tab.ID> = []
        /// A pin brought down under New tab with nothing of today's there
        /// yet: the line comes in over it at once.
        var lineComes = false
    }

    /// A place among the rows as baseSlots has them.
    enum Cell {
        case tab(Tab)
        case empty(Nest)
        case line
        case gap
    }

    /// The rows' cells as SideBar's baseSlots lays them: no pane of a split
    /// but its first,
    /// no tab tucked away (but a folder's first, whose cell its folder's row
    /// is in), empty folders at the end of their folder's run or of the
    /// kept, the line heading today's.
    static func cells(_ browser: Browser, folders given: Folders? = nil) -> [Cell] {
        let folders = given ?? browser.folderBook
        let loose = browser.tabs.filter { $0.pin == nil }
        let joined = !browser.pairs.isEmpty
        var cells: [Cell] = loose.compactMap { tab in
            if joined, let pair = browser.pair(of: tab.id), pair.first != tab.id { return nil }
            if let place = folders.place(of: tab), !place.shown, !place.listed, !place.head { return nil }
            return .tab(tab)
        }
        // Empty folders standing among the kept, just above the run each
        // stands over (Nest.stand).
        if !folders.ahead.isEmpty {
            var begun: Set<String> = []
            cells = cells.flatMap { cell -> [Cell] in
                guard let tab = tab(cell), tab.kept, begun.insert(folders.run(tab)).inserted,
                      let nests = folders.ahead[folders.run(tab)] else { return [cell] }
                return nests.map { Cell.empty($0) } + [cell]
            }
        }
        // Empty folders in a folder of yours with tabs, at the end of its
        // run while it is open and its row drawn, the deepest first where
        // two runs end together.
        let ends = folders.trail.compactMap { key, nests -> (at: Int, depth: Int, nests: [Nest])? in
            guard let folder = folders.folder(key), let nest = folder.nest, nest.open, key != folders.carried, folders.drawn(key),
                  let last = cells.lastIndex(where: { cell in tab(cell).map { folder.members.contains($0.id) } ?? false }) else { return nil }
            return (last + 1, nest.depth, nests)
        }
        for end in ends.sorted(by: { $0.at != $1.at ? $0.at > $1.at : $0.depth < $1.depth }) {
            cells.insert(contentsOf: end.nests.map { Cell.empty($0) }, at: end.at)
        }
        let at = cells.firstIndex { tab($0)?.kept == false } ?? cells.count
        cells.insert(contentsOf: folders.block.map { Cell.empty($0) } + [.line], at: at)
        let todayAhead = folders.todayAhead
        cells = cells.flatMap { cell -> [Cell] in
            guard let tab = tab(cell), let empty = todayAhead[tab.id] else { return [cell] }
            return empty.map { Cell.empty($0) } + [cell]
        }
        cells += folders.todayBlock.map { Cell.empty($0) }
        return cells
    }

    static func tab(_ cell: Cell) -> Tab? { if case .tab(let tab) = cell { return tab } else { return nil } }

    /// How many rows a cell draws (SideBar.drawnRows): a folder's own row
    /// in its first tab's, and the tab's unless it is tucked away.
    static func rows(_ cell: Cell, folders given: Folders? = nil) -> Int {
        let folders = given ?? .shared
        switch cell {
        case .empty: return 1
        case .line: return folders.lined ? Folders.lineRows : 1
        case .gap: return 1
        case .tab(let tab):
            // A split of four's own row is two rows (Folders.rows).
            let place = folders.place(of: tab)
            return (place?.heads.count ?? 0) + (place?.shown == false ? 0 : folders.rows(tab)) + ((place?.more ?? 0) > 0 ? 1 : 0)
        }
    }

    static func rows(_ cells: [Cell], folders given: Folders? = nil) -> Int { cells.reduce(0) { $0 + rows($1, folders: given) } }

    /// The line's slot among `cells`, nil while there is none: for
    /// `y(_:line:)` and `slot(_:line:)`.
    static func lineSlot(in cells: [Cell], folders given: Folders? = nil) -> Int? {
        let folders = given ?? .shared
        guard folders.lined, let at = cells.firstIndex(where: { if case .line = $0 { true } else { false } }) else { return nil }
        return rows(Array(cells[..<at]), folders: folders)
    }

    /// Where among `cells` a gap goes for `rows` rows down as drawn: before
    /// the first cell that starts there or further down (SideBar.position).
    static func position(_ rows: Int, in cells: [Cell], skip: Tab.ID? = nil, folders given: Folders? = nil) -> Int {
        let folders = given ?? .shared
        var at = 0
        for (index, cell) in cells.enumerated() {
            if let skip, tab(cell)?.id == skip { continue }
            if at >= rows { return index }
            at += self.rows(cell, folders: folders)
        }
        return cells.count
    }

    /// A gap `at` among the cells: the tab it stands before, whether above
    /// the line, and in which of your folders (SideBar.placing).
    static func placing(_ at: Int, in cells: [Cell]) -> (before: Tab?, kept: Bool, nest: Nest?) {
        let above = cells.prefix(at).compactMap(tab).last
        let below = cells.dropFirst(at).compactMap(tab).first
        guard let line = cells.firstIndex(where: { if case .line = $0 { return true } else { return false } }), at <= line else {
            if let nest = above?.nest, nest.today, nest === below?.nest { return (below, false, nest) }
            return (below, false, nil)
        }
        let up = above?.nest?.chain ?? [], down = below?.nest?.chain ?? []
        let shared = zip(up, down).prefix(while: { $0 === $1 }).map { $0.0 }
        return (below, true, shared.last)
    }

    static func live(_ browser: Browser, folders given: Folders? = nil, shape: Shape = Shape()) -> [ColumnItem] {
        let folders = given ?? browser.folderBook
        let loose = browser.tabs.filter { $0.pin == nil }
        let joined = !browser.pairs.isEmpty
        var cells = Self.cells(browser, folders: folders)
        if !shape.out.isEmpty { cells.removeAll { tab($0).map { shape.out.contains($0.id) } ?? false } }
        if let gap = shape.gap { cells.insert(.gap, at: position(gap, in: cells, skip: shape.skip, folders: folders)) }

        // The last of today's carried up into the pins takes the line with
        // it at once, not at its let-go (2026-10-14).
        let lineShown = Folders.showsLine(loose, folded: browser.dustFolded.union(shape.pinning)) || shape.lineComes || !folders.todayBlock.isEmpty
        // Gone to dust in Clear's wave: their room given up, the rows under
        // them riding up behind the dust (SideBar, Tidy.swift).
        let dusted = browser.dustFolded, dustedRows = browser.dustFoldedRows
        var items: [ColumnItem] = []
        var y: CGFloat = 0
        // `rows`: a split of four's row is two of the column's rows tall.
        func add(_ id: String, _ kind: ColumnItem.Kind, indent: CGFloat, shown: Bool = true, folded: Bool = false, rows: Int = 1) {
            let lined = if case .line = kind { true } else { false }
            let height = shown && !folded ? (lined ? SideBar.line : PairRow.height(rows: rows)) : 0
            items.append(ColumnItem(id: id, kind: kind, indent: indent, y: y, height: height))
            if folded { y += SideBar.gap } else if shown { y += lined ? lineStep : step * CGFloat(rows) }
        }
        for cell in cells {
            switch cell {
            case .tab(let tab):
                if let forming = shape.forming {
                    if tab.id == forming.held { continue }
                    if tab.id == forming.target, let held = browser.tab(id: forming.held) {
                        let indent = CGFloat(folders.place(of: tab)?.depth ?? 0) * Folders.indent
                        let targetMate = browser.partner(of: tab)
                        let heldMate = browser.partner(of: held)
                        add(tab.id.uuidString, .nest(forming.nest, count: 2 + (targetMate == nil ? 0 : 1) + (heldMate == nil ? 0 : 1), over: nil), indent: indent)
                        add("choice child " + tab.id.uuidString, targetMate.map { .pair(tab, $0) } ?? .tab(tab), indent: indent + Folders.indent)
                        add("choice child " + held.id.uuidString, heldMate.map { .pair(held, $0) } ?? .tab(held), indent: indent + Folders.indent)
                        continue
                    }
                }
                let place = folders.place(of: tab)
                for key in place?.heads ?? [] {
                    guard let folder = folders.folder(key) else { continue }
                    let shown = !dustedRows.contains(DrawnRows.folder(folder.id))
                    if let nest = folder.nest {
                        add(folder.id, .nest(nest, count: folder.members.count, over: folder.over), indent: CGFloat(max(0, nest.depth - 1)) * Folders.indent,
                            shown: shown)
                    } else {
                        add(folder.id, .task(folder, open: folders.isOpen(folder.id)), indent: 0, shown: shown)
                    }
                }
                if (place?.shown ?? true), !dusted.contains(tab.id) {
                    let indent = place == nil ? 0 : CGFloat(place?.depth ?? 0) * Folders.indent
                    let folded = shape.folded.contains(tab.id)
                    if joined, let other = browser.partner(of: tab), browser.pair(of: tab.id)?.first == tab.id {
                        add(tab.id.uuidString, .pair(tab, other), indent: indent, folded: folded, rows: browser.rowsTaken(by: tab.id))
                    } else {
                        add(tab.id.uuidString, .tab(tab), indent: indent, folded: folded)
                    }
                }
                if let place, place.more > 0 {
                    add("more " + place.folder, .more(place.folder, place.more), indent: Folders.indent,
                        shown: !dustedRows.contains(DrawnRows.more(place.folder)))
                }
            case .empty(let nest):
                let indent = CGFloat(max(0, nest.depth - 1)) * Folders.indent
                add(nest.key, .nest(nest, count: 0, over: nil), indent: indent)
            case .line:
                add("line", .line, indent: 0, shown: lineShown)
                add("new-tab", .newTab, indent: 0)
            case .gap:
                add("gap", .gap, indent: 0)
            }
        }
        return items
    }

    /// How tall the rows stand, the last one's gap left out as SideBar's
    /// list leaves it.
    static func height(_ items: [ColumnItem]) -> CGFloat {
        guard let last = items.last(where: { $0.height > 0 }) else { return 0 }
        return last.y + last.height
    }

    // MARK: - the pins and the name

    /// The pins' grid as SideBar lays it (pinGeometry): as many columns as
    /// the width fits and keeps the rows even, each cell the row's share of
    /// the width, never taller than a pin.
    static func grid(count: Int, width: CGFloat) -> (cols: Int, width: CGFloat, height: CGFloat) {
        let cols = SideBar.pinColumns(count, width: width)
        let available = width - 2 * SideBar.margin - CGFloat(cols - 1) * SideBar.pinGap
        let cell = max(20, available / CGFloat(cols))
        return (cols, cell, min(SideBar.square, cell))
    }

    /// How tall the grid stands with this many pins, its gap below included.
    static func pinBlock(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let grid = grid(count: count, width: width)
        let rows = (count + grid.cols - 1) / grid.cols
        return CGFloat(rows) * grid.height + CGFloat(rows - 1) * SideBar.pinGap + SideBar.margin
    }

    /// The middle of a cell, in from the column's margin and down from the
    /// column's top (SideBar.pinCenter).
    static func pinCenter(_ index: Int, count: Int, width: CGFloat, top: CGFloat) -> CGPoint {
        let grid = grid(count: count, width: width)
        return CGPoint(x: CGFloat(index % grid.cols) * (grid.width + SideBar.pinGap) + grid.width / 2,
                       y: top + CGFloat(index / grid.cols) * (grid.height + SideBar.pinGap) + grid.height / 2)
    }

    /// Where the pins start: under the lights, or the plate.
    static func pinsTop(_ browser: Browser) -> CGFloat {
        browser.inMail ? Metrics.strip : SideBar.pinsTop(plated: browser.sidePlated, extensions: SidePlate.pinsHeight(in: browser))
    }

    /// The pins and the space's name over the rows, where SideBar draws
    /// them: the grid's cells, gaps at `gaps` for what is carried in (each
    /// `count` cells), a pin's home typed in over its row of the grid, the
    /// name under it all. Each item's `y` is from the column's top.
    static func head(_ browser: Browser, gaps: (at: Int, count: Int)? = nil) -> [ColumnItem] {
        let width = browser.prefs.sideWidth
        // A pinned pair is one cell (PinPairs.swift).
        let pins = browser.gridPins
        var cells: [Tab?] = pins
        if let gaps, gaps.count > 0 { cells.insert(contentsOf: Array(repeating: nil, count: gaps.count), at: min(gaps.at, cells.count)) }
        let top = pinsTop(browser)
        let grid = grid(count: cells.count, width: width)
        var items: [ColumnItem] = []
        var gap = 0
        for (index, tab) in cells.enumerated() {
            let x = CGFloat(index % grid.cols) * (grid.width + SideBar.pinGap)
            let y = top + CGFloat(index / grid.cols) * (grid.height + SideBar.pinGap)
            if let tab {
                // A pinned pair's id names both: the cell is drawn anew when
                // the pair comes or goes.
                let mate = browser.pinMate(of: tab).map { "+" + $0.id.uuidString } ?? ""
                items.append(ColumnItem(id: "pin " + tab.id.uuidString + mate, kind: .pin(tab), indent: 0, y: y, height: grid.height, x: x, width: grid.width))
            } else {
                items.append(ColumnItem(id: "pin gap \(gap)", kind: .pinGap, indent: 0, y: y, height: grid.height, x: x, width: grid.width))
                gap += 1
            }
        }
        // A pin's home typed into Edit…: its row of the grid is its field.
        if browser.editingHome, let id = browser.editingTab, let at = pins.firstIndex(where: { $0.id == id }) {
            items.append(ColumnItem(id: "home " + id.uuidString, kind: .home(pins[at]), indent: 0,
                                    y: top + CGFloat(at / grid.cols) * (grid.height + SideBar.pinGap), height: grid.height,
                                    x: 0, width: width - 2 * SideBar.margin))
        }
        if browser.windowPurpose == .privateOnly {
            let y = top + pinBlock(count: cells.count, width: width)
            items.append(ColumnItem(id: "private name", kind: .privateName, indent: 0, y: y,
                                    height: SideBar.row, x: 0, width: width - 2 * SideBar.margin))
        } else if browser.namesSpaces, !browser.inMail {
            let y = top + pinBlock(count: cells.count, width: width)
            items.append(ColumnItem(id: "name " + browser.spaceID.uuidString, kind: .name(browser.space), indent: 0, y: y,
                                    height: SideBar.row, x: 0, width: width - 2 * SideBar.margin))
        }
        return items
    }

    // MARK: - a space not on screen

    /// A space's rows and pins as the column will lay them once it comes,
    /// from its row as it was parked (PagedSpace.Coming): the page beside
    /// the one on screen while the row of spaces slides.
    static func parked(_ browser: Browser, row: Parked, travelling: [Tab], space: Space) -> (items: [ColumnItem], head: [ColumnItem]) {
        let folders = browser.folderBook
        let all = row.tabs + travelling
        // A pinned pair is one cell (PinPairs.swift).
        let tucked = Set(row.pairs.filter { pair in all.contains { $0.id == pair.first && $0.pin != nil } && all.contains { $0.id == pair.second && $0.pin != nil } }.map(\.second))
        let pins = all.filter { $0.pin != nil && !tucked.contains($0.id) }
        let loose = all.filter { $0.pin == nil }
        let empty = folders.empties(in: space.id)
        let shut = folders.isShut(space.id, in: browser)
        let partner = { (id: Tab.ID) in row.pairs.first { $0.first == id }?.second ?? row.pairs.first { $0.second == id }?.first }
        let coming = PagedSpace.Coming.items(loose, active: row.active, open: folders.open, whole: folders.whole, empty: empty, shut: shut, partner: partner)
        var items: [ColumnItem] = []
        var y: CGFloat = 0
        func add(_ id: String, _ kind: ColumnItem.Kind, indent: CGFloat, rows: Int = 1) {
            let lined = if case .line = kind { true } else { false }
            items.append(ColumnItem(id: id, kind: kind, indent: indent, y: y, height: lined ? SideBar.line : PairRow.height(rows: rows)))
            y += lined ? lineStep : step * CGFloat(rows)
        }
        for item in coming {
            switch item {
            case .tab(let tab, let depth):
                if let pair = row.pairs.first(where: { $0.first == tab.id }), let other = row.tabs.first(where: { $0.id == pair.second }) {
                    add(tab.id.uuidString, .pair(tab, other), indent: CGFloat(depth) * Folders.indent, rows: Pair.rows(pair.count))
                } else if !row.pairs.contains(where: { $0.contains(tab.id) && $0.first != tab.id }) {
                    add(tab.id.uuidString, .tab(tab), indent: CGFloat(depth) * Folders.indent)
                }
            case .line:
                add("line", .line, indent: 0)
                add("new-tab", .newTab, indent: 0)
            case .newTab:
                add("new-tab", .newTab, indent: 0)
            case .folder(let folder):
                if let nest = folder.nest {
                    let indent = CGFloat(max(0, nest.depth - 1)) * Folders.indent
                    add(folder.id, .nest(nest, count: folder.members.count, over: folder.over), indent: indent)
                } else {
                    add(folder.id, .task(folder, open: Folders.isOpen(folder, among: folders.open)), indent: 0)
                }
            case .more(let folder, let count):
                add("more " + folder, .more(folder, count), indent: Folders.indent)
            }
        }
        let width = browser.prefs.sideWidth
        let plated = browser.sidePlated(row)
        let top = SideBar.pinsTop(plated: plated, extensions: SidePlate.pinsHeight(in: browser, space: space.id, tab: all.first { $0.id == row.active }))
        let grid = grid(count: pins.count, width: width)
        var head: [ColumnItem] = pins.enumerated().map { index, tab in
            ColumnItem(id: "pin " + tab.id.uuidString, kind: .pin(tab), indent: 0,
                       y: top + CGFloat(index / grid.cols) * (grid.height + SideBar.pinGap), height: grid.height,
                       x: CGFloat(index % grid.cols) * (grid.width + SideBar.pinGap), width: grid.width)
        }
        if browser.namesSpaces {
            head.append(ColumnItem(id: "name " + space.id.uuidString, kind: .name(space), indent: 0, y: top + pinBlock(count: pins.count, width: width),
                                   height: SideBar.row, x: 0, width: width - 2 * SideBar.margin))
        }
        return (items, head)
    }

    /// How far down a space's rows rest under its pins and name: SideBar's
    /// `lead` for that space.
    static func lead(_ browser: Browser, pins: Int, row: Parked? = nil, space: Space? = nil, travelling: [Tab] = []) -> CGFloat {
        let named = browser.namesSpaces || browser.windowPurpose == .privateOnly
        let nameBlock = named ? SideBar.row + SideBar.gap : SideBar.unnamedGap(pins: pins > 0, named: named)
        let top: CGFloat
        if let row, let space {
            let plated = browser.sidePlated(row)
            let tab = (row.tabs + travelling).first { $0.id == row.active }
            top = SideBar.pinsTop(plated: plated, extensions: SidePlate.pinsHeight(in: browser, space: space.id, tab: tab))
        } else {
            top = pinsTop(browser)
        }
        return top + pinBlock(count: pins, width: browser.prefs.sideWidth) + nameBlock
    }
}

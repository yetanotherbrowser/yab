import AppKit
import QuartzCore

/// The hand belongs to the window, not to a page in the sliding row.
/// A visit is only a preview. Tabs remain at home until the mouse lifts.
@MainActor
final class ColumnSpaceCarry {
    private static let live = NSHashTable<ColumnSpaceCarry>.weakObjects()
    static func of(_ browser: Browser) -> ColumnSpaceCarry? { live.allObjects.first { $0.browser === browser } }

    weak var browser: Browser?
    private weak var pages: ColumnPages?
    private weak var source: ColumnHand?
    let home: UUID
    let tabs: [Tab]
    let folder: Nest?
    private var ids: Set<Tab.ID> { Set(tabs.map(\.id)) }
    private let item: ColumnItem
    private let liveID: Tab.ID?
    private let gripY: CGFloat
    private var point: CGPoint
    private var overlay: CarryView?
    private var cell: ColumnCell?
    private var spring: DispatchWorkItem?
    private var springID: UUID?
    private(set) var overlaying = false
    var drawing: Bool { overlay != nil && overlay?.isHidden == false }
    private(set) var landing: SpaceLanding = .todayTop
    private(set) var gap: Int?
    private(set) var pinAt: Int?
    var pinCount: Int { if case .pair = item.kind { return 1 }; return tabs.count }
    private var ending = false
    /// Escape while another space is on screen (ColumnHand.breakSpaceCarry).
    private var keys: Any?

    init?(browser: Browser, page: ColumnPage, hand: ColumnHand, item: ColumnItem, start: CGPoint) {
        guard let pages = page.superview as? ColumnPages else { return nil }
        self.browser = browser
        self.pages = pages
        source = hand
        home = browser.spaceID
        liveID = browser.activeID
        self.item = item
        point = start
        folder = if case .nest(let nest, _, _) = item.kind { nest } else { nil }
        if let folder { tabs = browser.tabs(in: folder) }
        else if let tab = item.tab {
            if browser.isPicked(tab) { tabs = browser.tabs.filter { browser.isPicked($0) } }
            else { tabs = [tab] + browser.mates(of: tab.id).compactMap { browser.tab(id: $0) } }
        } else { return nil }
        let y = item.isPin ? item.y : page.rowsTop + item.y
        gripY = start.y - y
        Self.live.add(self)
    }

    /// Called before the pager takes the home page away, including a swipe.
    func willPage() {
        guard !ending, !overlaying else { return }
        overlaying = true
        browser?.carryHome = home
        if keys == nil {
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated {
                    guard let self, !self.ending else { return }
                    if let source = self.source { source.breakSpaceCarry() } else { self.cancel() }
                }
                return nil
            }
        }
        source?.prepareSpaceCarry()
        ensureOverlay()
        overlay?.isHidden = false
        draw()
        pages?.shown?.redraw(nil)
    }

    private func ensureOverlay() {
        guard overlay == nil, let pages, let parent = (browser?.column as NSView?) ?? pages.superview else { return }
        let view = CarryView(frame: pages.convert(pages.bounds, to: parent))
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        parent.addSubview(view, positioned: .above, relativeTo: nil)
        overlay = view
        let cell = ColumnCell(kind: ColumnCell.kind(of: item))
        view.addSubview(cell)
        self.cell = cell
    }

    func switched() {
        guard overlaying, !ending else { return }
        gap = nil
        pinAt = nil
        spring?.cancel()
        springID = nil
        // sync has to see the final row, after switchSpace's transaction.
        pages?.sync()
        move(point)
    }

    /// Points are always in the stationary ColumnPages bounds, never in a
    /// translated page. Its sibling overlay is outside the pager transform.
    func move(_ at: CGPoint) {
        point = at
        guard !ending, let browser, let pages else { return }
        if !overlaying {
            if tabs.count == 1 || folder != nil, source?.spaceRowVisible == true {
                ensureOverlay()
                overlay?.isHidden = false
                draw()
                pages.shown?.redraw(nil)
            } else { overlay?.isHidden = true }
            return
        }
        guard let page = pages.shown else { return }

        let windowPoint = pages.convert(at, to: nil)
        if SpaceDrop.shared.track(tabs, browser: browser, folder: folder, at: windowPoint) {
            gap = nil
            pinAt = nil
            spring?.cancel()
            springID = nil
            page.refresh(ColumnMotion.settle)
            draw()
            return
        }
        let width = browser.prefs.sideWidth
        let top = ColumnLayout.pinsTop(browser)
        let pinsBottom = top + ColumnLayout.pinBlock(count: browser.pinCellCount, width: width)
        if folder == nil, tabs.allSatisfy({ !$0.isBlank }), at.y < pinsBottom - 6 {
            let grid = ColumnLayout.grid(count: browser.pinCellCount + pinCount, width: width)
            let col = min(max(0, Int((at.x - SideBar.margin) / (grid.width + SideBar.pinGap))), grid.cols - 1)
            let row = max(0, Int((at.y - top) / (grid.height + SideBar.pinGap)))
            let index = min(row * grid.cols + col, browser.pinCellCount)
            pinAt = index
            landing = .pin(index)
            gap = nil
        } else {
            pinAt = nil
            let cells = baseCells(browser)
            let line = ColumnLayout.lineSlot(in: cells, folders: browser.folderBook)
            let want = ColumnLayout.slot(at.y - gripY - page.rowsTop, line: line)
            let slot = min(max(0, Int(want.rounded())), ColumnLayout.rows(cells, folders: browser.folderBook))
            let place = ColumnLayout.placing(ColumnLayout.position(slot, in: cells, folders: browser.folderBook), in: cells)
            let loose = browser.tabs.filter { $0.pin == nil && !ids.contains($0.id) }
            let index = place.before.flatMap { before in loose.firstIndex { $0.id == before.id } } ?? loose.count
            landing = .row(index: index, kept: place.kept, nest: place.nest?.id)
            gap = slot
            // Hit the unshifted folder head so that its gap cannot push the
            // target away. After spring-opening, its members accept a gap.
            let heads = ColumnLayout.live(browser).filter { if case .nest = $0.kind { true } else { false } }
            if let head = heads.first(where: { abs((page.rowsTop + $0.y) - (at.y - gripY)) < SideBar.row / 2 }),
               case .nest(let nest, _, _) = head.kind, nest !== folder, folder.map({ !nest.within($0) }) ?? true,
               !nest.open || !browser.tabs.contains(where: { $0.nest?.within(nest) == true }) {
                landing = .folder(nest.id)
                gap = nil
                springOpen(nest)
            } else {
                spring?.cancel()
                springID = nil
            }
        }
        page.refresh(ColumnMotion.settle)
        draw()
    }

    private func baseCells(_ browser: Browser) -> [ColumnLayout.Cell] {
        ColumnLayout.cells(browser).filter { cell in
            if let tab = ColumnLayout.tab(cell) { return !ids.contains(tab.id) }
            if case .empty(let nest) = cell, let folder { return !nest.within(folder) }
            return true
        }
    }

    func shape(in space: UUID) -> ColumnLayout.Shape? {
        guard overlaying, !ending, let browser, space == browser.spaceID else { return nil }
        var shape = ColumnLayout.Shape()
        shape.out = Set(tabs.map(\.id))
        shape.gap = gap
        return shape
    }

    func hides(_ item: ColumnItem) -> Bool {
        guard drawing else { return false }
        if !overlaying { return item.id == self.item.id }
        if let tab = item.tab { return ids.contains(tab.id) }
        if case .nest(let nest, _, _) = item.kind, let folder { return nest.within(folder) }
        return false
    }

    private func springOpen(_ nest: Nest) {
        guard !nest.open, springID != nest.id else { return }
        spring?.cancel()
        springID = nest.id
        let work = DispatchWorkItem { [weak self, weak nest] in
            guard let self, let nest, landing == .folder(nest.id), let browser else { return }
            browser.folderBook.toggle(nest.key) {}
            move(point)
        }
        spring = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Dwell timers can change the hand without another pointer event.
    func refreshHand() {
        guard !overlaying, drawing else { return }
        draw()
    }

    private func draw() {
        guard let browser, let pages, let overlay, let cell else { return }
        if let parent = overlay.superview { overlay.frame = pages.convert(pages.bounds, to: parent) }
        let indent = overlaying ? 0 : item.indent
        let width = max(20, pages.bounds.width - 2 * SideBar.margin - indent)
        let row = ColumnItem(id: item.id, kind: item.kind, indent: indent, y: 0, height: SideBar.row, x: 0, width: width)
        cell.frame = CGRect(x: SideBar.margin + indent, y: point.y - gripY, width: width, height: SideBar.row)
        let hold = overlaying ? ColumnCell.Hold(lifted: true) : (source?.drawn(item).hold ?? ColumnCell.Hold(lifted: true))
        cell.bind(row, ColumnCell.Context(browser: browser, look: pages.carryLook, liveID: liveID),
                  hold: hold, force: true)
        var lean = overlaying ? ColumnCell.Lean() : (source?.drawn(item).lean ?? ColumnCell.Lean())
        if SpaceDrop.shared.slot != nil { lean.scale = 0.94 }
        cell.lean(lean, ColumnMotion.follow)
    }

    @discardableResult
    func finish(dot: UUID? = nil) -> Bool {
        guard let browser, !ending else { return false }
        guard overlaying || dot != nil else { dispose(); return false }
        ending = true
        browser.carryHome = nil
        let target = dot ?? browser.spaceID
        let place: SpaceLanding = dot == nil ? landing : .todayTop
        let wasOverlaying = overlaying
        SpaceDrop.shared.cancel()
        let arrived: [Tab]
        if target != home {
            arrived = browser.landTabs(tabs, from: home, to: target, at: place, folder: folder, showing: wasOverlaying)
        } else {
            // Swiped out and back: finish in the original space, with the
            // same arrangement undo already held by ColumnHand. Let go on
            // home's dot while another space is only visited: home first.
            if browser.spaceID != home { browser.switchSpace(to: home) }
            arrived = tabs
            browser.placeCarried(tabs, at: place, folder: folder)
        }
        dispose()
        pages?.sync()
        // ColumnHand clears the home page's old aim before this landing.
        settleRow(arrived.first, folder: folder)
        return true
    }

    func cancel() {
        guard !ending else { return }
        ending = true
        browser?.carryHome = nil
        SpaceDrop.shared.cancel()
        if let browser, browser.spaceID != home { browser.switchSpace(to: home) }
        dispose()
        settleRow(tabs.first, folder: folder)
    }

    private func settleRow(_ tab: Tab?, folder: Nest?) {
        let fromY = point.y - gripY + SideBar.row / 2
        DispatchQueue.main.async { [weak pages] in
            guard let page = pages?.shown else { return }
            let id = folder?.key ?? tab.map { $0.pin == nil ? $0.id.uuidString : "pin " + $0.id.uuidString }
            guard let id else { return }
            let y = page.rowMiddle(id) ?? page.headItems.first(where: { $0.id == id }).map { $0.y + $0.height / 2 }
            if let y { page.settle(id, from: CGSize(width: 0, height: fromY - y)) }
        }
    }

    var state: [String: Any] {
        var out: [String: Any] = ["home": home.uuidString, "paging": overlaying, "drawing": drawing,
                                  "compact": cell?.current?.hold.compact ?? false,
                                  "tabs": tabs.map { $0.id.uuidString }, "gap": gap ?? -1,
                                  "slot": SpaceDrop.shared.slot?.uuidString ?? ""]
        if let overlay, let cell, let window = overlay.window, let content = window.contentView {
            let rect = cell.convert(cell.bounds, to: nil)
            out["frame"] = [rect.minX, content.bounds.height - rect.maxY, rect.width, rect.height].map { Double($0) }
        }
        return out
    }

    func dispose() {
        browser?.carryHome = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        spring?.cancel()
        spring = nil
        overlay?.removeFromSuperview()
        overlay = nil
        overlaying = false
        Self.live.remove(self)
    }

    private final class CarryView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

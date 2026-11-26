import AppKit
import QuartzCore
import SwiftUI

// A hand on the AppKit column's rows and pins (docs/column-appkit.md): the
// same drags SideBar's gestures make, worked out by the same arithmetic
// (Folders.landing, nestLanding, slots, SideBar.deep), the rows stepping
// aside on Core Animation's springs rather than SwiftUI passes. Each part
// says which of SideBar's it is.

/// Takes a press on a row or a pin that moves five points as a drag, and
/// leaves every other press to the row (its click, its menu, its cross).
/// Not a gesture recognizer: the rows' hosts are SwiftUI's, whose own
/// handling of the press kept a recognizer on the page from ever beginning
/// (the press heard, the drags heard, never a state past possible). A local
/// monitor of the page's window hears the mouse before any view does; the
/// press and the moves still go on to the row, and once a drag has begun its
/// let-go goes to the row far from it, so the row's click doesn't fire.
@MainActor
final class ColumnGrip {
    enum State: Int { case possible, began, changed, ended, cancelled, failed, idle }

    private(set) var start: NSPoint = .zero
    private var now: NSPoint = .zero
    /// The event being handled by the local monitor. `currentEvent` can
    /// still be the previous event until this monitor returns.
    private(set) var event: NSEvent?
    weak var view: NSView?
    weak var coordinateView: NSView?
    /// Whether a press there may become a drag.
    var attempt: ((NSEvent) -> Bool)?
    var pressed: ((NSPoint) -> Void)?
    var released: (() -> Void)?
    var changed: ((ColumnGrip) -> Void)?
    private var monitor: Any?
    /// What it heard, for the bench.
    var heard: [String: Int] = [:]

    var state: State = .idle {
        didSet {
            // Called off by whoever drives it: the drag is broken off.
            if state == .cancelled, oldValue != .cancelled, oldValue != .idle {
                changed?(self)
                state = .idle
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func location(in view: NSView?) -> NSPoint { now }

    /// Listening while the page is in a window.
    func watch(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                AppKitMainThread.sync { self?.heard(event) ?? event }
            }
        } else if !on, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            if state == .began || state == .changed { state = .cancelled }
            state = .idle
        }
    }

    private func heard(_ event: NSEvent) -> NSEvent? {
        guard let view, let window = view.window, event.window === window else { return event }
        self.event = event
        defer { self.event = nil }
        let point = (coordinateView ?? view).convert(event.locationInWindow, from: nil)
        switch event.type {
        case .keyDown:
            if event.keyCode == 53, state == .began || state == .changed {
                state = .cancelled
                return nil
            }
            return event
        case .leftMouseDown:
            state = .idle
            guard !view.isHiddenOrHasHiddenAncestor, view.bounds.contains(point),
                  let hit = window.contentView?.superview?.hitTest(event.locationInWindow) ?? window.contentView?.hitTest(event.locationInWindow),
                  hit === view || hit.isDescendant(of: view), attempt?(event) == true else { return event }
            heard["down", default: 0] += 1
            start = point
            now = point
            state = .possible
            pressed?(start)
            return event
        case .leftMouseDragged:
            switch state {
            case .possible:
                heard["dragged", default: 0] += 1
                now = point
                if hypot(now.x - start.x, now.y - start.y) >= 5 {
                    heard["began", default: 0] += 1
                    state = .began
                    changed?(self)
                    if state == .began { state = .changed }
                }
                return event
            case .began, .changed:
                now = point
                changed?(self)
                // On to the row and every other watch too (TearOff's): the
                // row has no drag of its own to make of it.
                return event
            default:
                return event
            }
        case .leftMouseUp:
            let was = state
            guard was != .idle else { return event }
            now = point
            released?()
            if was == .began || was == .changed {
                state = .ended
                changed?(self)
                state = .idle
                // The row's own handling of the press ends far from it.
                return NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: event.modifierFlags,
                                          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                          eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0) ?? event
            }
            state = .idle
            return event
        default:
            return event
        }
    }
}

@MainActor
final class ColumnHand: NSObject {
    unowned let page: ColumnPage
    private weak var browser: Browser?
    private var folders: Folders { browser?.folderBook ?? .shared }
    let grip = ColumnGrip()
    private var spaceCarry: ColumnSpaceCarry?
    var spaceRowVisible: Bool { (dragging != nil || carrying != nil) && carry == nil && herd == nil && torn == nil && decked == nil }

    /// Escape heard by the carry once the home page has slid away: its
    /// grip no longer hears keys, so the drag is broken off from here.
    func breakSpaceCarry() {
        if grip.state == .began || grip.state == .changed { grip.state = .cancelled } else { brokenOff() }
    }

    /// Retire drawings that belong to the page before it slides away.
    func prepareSpaceCarry() {
        stopTimers()
        page.stackGone()
        page.carriedGone()
    }

    private func clearSpaceCarry() {
        spaceCarry?.dispose()
        spaceCarry = nil
        grip.coordinateView = nil
    }

    private func finishSpaceCarry() {
        stopTimers()
        carry = nil
        herd = nil
        carrying = nil
        folders.carry(nil)
        dragging = nil
        pinDragging = nil
        aim = nil
        travel = 0
        nestTravel = 0
        pinTravel = .zero
        page.stackGone()
        page.carriedGone()
        clearSpaceCarry()
        page.refresh(ColumnMotion.settle)
    }

    // MARK: SideBar's drag state

    private(set) var dragging: Tab.ID?
    private var from = 0
    private var travel: CGFloat = 0
    private var target = 0
    private var aim: Folders.Landing?
    private var landedFor = 0
    private var fromSlot = 0
    private var sinking: Tab.ID?
    private(set) var pinDragging: Tab.ID?
    private var pinFrom = 0
    private var pinTravel: CGSize = .zero
    private var pinGoal = 0
    private var resting: Tab.ID?
    private var carry: Carry?
    private var settling: Tab.ID?
    private var herd: Herd?
    private var decked: Tab.ID?
    private var torn: Tab.ID?
    private var herdKept = false
    private var sprung: UUID?
    /// Held over the name of a space folded under it: let go, it is kept
    /// there, at the end of its kept, as Arc takes a tab let go on a
    /// folded space's name.
    private var onName = false
    private var bias: CGFloat = 0
    /// Where the row in the hand was laid when it was picked up.
    private var heldLaid: CGFloat?

    /// How far up the held row's laid place has moved since it was picked
    /// up, which its drawing adds to the travel to stay under the pointer:
    /// the line under the kept coming or going moved it while held, and it
    /// was drawn that far from the hand (62 pt in follow.py's today-to-kept).
    private func laidSince(_ tab: Tab) -> CGFloat {
        guard dragging == tab.id, let was = heldLaid, let now = page.laidTop(tab.id.uuidString) else { return 0 }
        return was - now
    }

    /// How far the row in the hand is drawn from where it is laid: the
    /// pointer's travel from where it was picked up, whatever the list did
    /// around it. `travel` counts in slots, and a folder sprung open under
    /// the hand moved its slot by `bias`; laidSince already counts that
    /// move of its place, so `travel` alone drew it the folder's rows away
    /// from the pointer, above it.
    private func heldShift(_ tab: Tab) -> CGFloat { travel - bias + laidSince(tab) }

    private var refolding: ColumnMotion.Curve?
    private var combine: Tab.ID?
    private var folding: Tab.ID?
    private var fold: CGFloat = 0
    private var choice: TabDropChoice?
    private var choiceWork: DispatchWorkItem?
    private var formingNest: Nest?
    private var formingPointerY: CGFloat?
    private var choicePreviousActive: Tab.ID?
    private var carrying: NestCarry?
    private var nestTravel: CGFloat = 0
    private var pressedPin: Tab.ID?
    /// Where the press began and where the hand is, in the column's space
    /// (SideBar's "column": in from the margin, down from the top).
    private var startAt: CGPoint = .zero
    private var at: CGPoint = .zero
    private var scrollAtStart: CGFloat = 0
    private var scrollTimer: Timer?
    private var scrollTick: CFTimeInterval = 0
    private var dwellWork: DispatchWorkItem?
    private var springWork: DispatchWorkItem?
    private var springFor: UUID?
    private var drawn: [Tab.ID: Int] = [:]

    private struct Carry: Equatable {
        let tab: Tab.ID
        let toPins: Bool
        var index: Int
    }

    private struct Herd: Equatable {
        let ids: [Tab.ID]
        let members: Set<Tab.ID>
        let held: Tab.ID
        let pinnable: Int
        var pinAt: Int?
        let home: Int
        var index: Int?
        var into: UUID?
        let grip: CGFloat
        var landed = false
    }

    private struct EmptyBlockLanding: Equatable {
        enum Anchor: Equatable { case before(UUID), end }
        let anchor: Anchor
        let order: [UUID]
        let slot: Int
    }

    private struct NestCarry {
        let nest: Nest
        let fromSlot: Int
        var index: Int
        var slot: Int
        var parent: UUID?
        var into: UUID?
        /// A native empty-only block has sibling gaps without tab indexes.
        var emptyBlock: EmptyBlockLanding?
        /// An empty folder of yours, with no tabs to carry: it moves as a
        /// row of its own does (feedback #384).
        var empty = false
        /// A folder of today's (#440): it goes up among the kept whole when
        /// let go above the line (`up`), and to `gap` among today's below it.
        var today = false
        var up = false
        var gap: Folders.TodayLanding?
        var landing: Folders.NestLanding { Folders.NestLanding(index: index, slot: slot, parent: parent, into: into) }
    }

    init(page: ColumnPage, browser: Browser) {
        self.page = page
        self.browser = browser
        super.init()
        grip.view = page
        grip.attempt = { [weak self] event in self?.attempt(event) ?? false }
        grip.changed = { [weak self] grip in self?.moved(grip) }
        grip.pressed = { [weak self] point in self?.press(point) }
        grip.released = { [weak self] in self?.unpress() }
    }

    deinit { scrollTimer?.invalidate() }

    /// Nothing in the hand, on its way or going to dust: `drawn` is the
    /// row as laid for every row.
    var still: Bool {
        dragging == nil && pinDragging == nil && resting == nil && carry == nil && settling == nil && herd == nil
            && decked == nil && torn == nil && sinking == nil && folding == nil && carrying == nil && pressedPin == nil
            && browser?.dusting.isEmpty != false && browser?.dustingRows.isEmpty != false
    }

    /// Anything held: the rows laid with what the hand has done to them.
    var holding: Bool { dragging != nil || pinDragging != nil || carrying != nil || herd != nil || settling != nil }

    /// The source cell whose translated drawing belongs to the hand.
    /// Its resting slot may scroll out of sight; an overlay stack or a pin
    /// has its own drawing and does not need that source cell kept alive.
    var heldRowID: String? {
        if let carried = carrying { return carried.nest.key }
        guard carry == nil, herd == nil, torn == nil, decked == nil else { return nil }
        return dragging?.uuidString
    }

    // MARK: - what the layout takes from the hand

    /// The rows as the hand has them (SideBar.looseSlots): a row carried up
    /// into the pins folded to nothing, a stack's rows out and a gap where
    /// they would go, a gap where a pin brought down would land.
    var shape: ColumnLayout.Shape {
        if let browser, let shape = ColumnSpaceCarry.of(browser)?.shape(in: page.space) { return shape }
        var shape = ColumnLayout.Shape()
        if let choice, choice.ready, let held = dragging, let nest = formingNest {
            shape.forming = .init(target: choice.target, held: held, nest: nest)
            if !nest.today {
                shape.pinning.insert(held)
                if let tab = browser?.tab(id: held), let mate = browser?.partner(of: tab) { shape.pinning.insert(mate.id) }
            }
        }
        if let carry {
            if carry.toPins {
                shape.folded.insert(carry.tab)
                shape.pinning.insert(carry.tab)
            } else {
                shape.gap = carry.index
                shape.lineComes = pinComesToday
            }
        }
        // Out past the window's edge, leaving for a window of its own: out
        // of the list as it goes, and the line with it if it was the last
        // of today's. Held there, its row stood half seen at home and the
        // line over it, and both went at the let-go (2026-10-14 17:31).
        if let torn {
            shape.folded.insert(torn)
            shape.pinning.insert(torn)
        }
        if let herd, !herd.landed {
            shape.out = herd.members.subtracting([herd.held])
            shape.folded.insert(herd.held)
            if herd.pinAt != nil { shape.pinning = herd.members }
            if let index = herd.index {
                shape.gap = index
                shape.skip = herd.held
            }
            // Where it would land says whether the line over New tab stands:
            // among today's with none there yet, it comes in now; into the
            // kept or a folder with the last of today's, it goes now.
            if herd.pinAt == nil {
                if herd.into != nil {
                    shape.pinning.formUnion(herd.members)
                } else if let index = herd.index {
                    let others = baseCells.filter { cell in ColumnLayout.tab(cell).map { !herd.members.contains($0.id) } ?? true }
                    if ColumnLayout.placing(ColumnLayout.position(index, in: others, folders: folders), in: others).kept {
                        shape.pinning.formUnion(herd.members)
                    } else if !folders.lined {
                        shape.lineComes = true
                    }
                }
            }
        }
        if let carried = carrying {
            if carried.up, carried.today {
                shape.pinning.formUnion(browser?.tabs(in: carried.nest).map(\.id) ?? [])
            } else if carried.gap != nil, !folders.lined {
                shape.lineComes = true
            }
        }
        return shape
    }

    /// A pin carried down to land among today's with none there yet: the
    /// line over New tab comes with it, before the let-go.
    private var pinComesToday: Bool {
        guard let carry, !carry.toPins, !folders.lined else { return false }
        let base = baseCells
        return !ColumnLayout.placing(ColumnLayout.position(carry.index, in: base, folders: folders), in: base).kept
    }

    /// The gaps the pins open for what is carried up (SideBar.pinned).
    var pinGaps: (at: Int, count: Int)? {
        if let browser, let bridge = ColumnSpaceCarry.of(browser), bridge.overlaying,
           page.space == browser.spaceID {
            return bridge.pinAt.map { ($0, bridge.pinCount) }
        }
        if let carry, carry.toPins { return (carry.index, 1) }
        if let herd, let at = herd.pinAt { return (at, herd.pinnable) }
        return nil
    }

    /// The line on its way in under a row being kept, the first, in rows
    /// (SideBar.lineComing).
    var lineComing: Int? {
        if let browser, ColumnSpaceCarry.of(browser)?.overlaying == true { return nil }
        guard let browser, !folders.lined, let aim, let id = dragging, carry == nil, herd == nil,
              let held = looseTabs.first(where: { $0.id == id }) else { return nil }
        var order = alone(held).filter { $0.id != id }
        order.insert(held, at: min(aim.index, order.count))
        return folders.slots(order, joined: !browser.pairs.isEmpty, held: id, as: aim.guise).folders[Folders.line]
    }

    /// How each row in sight is drawn while the hand is on the rows: its
    /// hold for SwiftUI, and where it is moved, stepped in and scaled.
    struct Drawn {
        var hold = ColumnCell.Hold()
        var shift: CGSize = .zero
        var lean = ColumnCell.Lean()
        var opacity: CGFloat = 1
        var front = false
    }

    func drawn(_ item: ColumnItem) -> Drawn {
        var out = Drawn()
        if item.id.hasPrefix("choice child ") { return out }
        let step = ColumnLayout.step
        let moving = carrying != nil ? nestShifts : folderShifts
        switch item.kind {
        case .tab(let tab), .pair(let tab, _):
            let held = dragging == tab.id
            out.hold.lifted = held || resting == tab.id
            out.hold.compact = held && choice?.revealed == true
            if folding == tab.id {
                out.hold.turn = choice?.revealed == true ? fold : nil
                out.hold.made = combine == tab.id
                out.hold.choice = choice?.revealed == true ? choice : nil
            }
            out.front = held || resting == tab.id
            let place = folders.place(of: tab)
            // Where a row is in the list is a walk over every tab, and only a
            // row moving under a held one needs it: asked for every row in
            // sight on every frame of a scroll, it was most of the column's
            // time with 200 tabs.
            out.shift.height = rowShift(tab, index: index(of: tab), step: step, moving: moving)
            if held {
                let into = aim?.into != nil || onName
                out.lean.x = indent(of: place) + (into ? 16 : 32 * tuck)
                out.lean.y = into ? 14 : 0
                out.lean.scale = into ? 0.88 : 1 - 0.12 * tuck
                if choice?.revealed == true {
                    out.lean.x = at.x + 10
                    out.lean.y = SideBar.row / 2 + 12
                    out.lean.scale = 1
                }
            }
            if sinking == tab.id {
                out.lean.scale = 0.6
                out.lean.centered = true
            }
            let away = carry?.tab == tab.id || (herd?.held == tab.id && herd?.landed == false)
            let landedHerd = herd?.landed == true && herd?.members.contains(tab.id) == true
            if away || settling == tab.id || sinking == tab.id || browser?.dusting.contains(tab.id) == true || landedHerd {
                out.opacity = 0
            } else if (decked != nil && (decked == tab.id || browser?.partner(of: tab)?.id == decked)) || torn == tab.id {
                out.opacity = 0.5
            }
        case .more(let key, _):
            // Only a held row or folder can move this row. Finding its tab
            // otherwise walks every loose tab on each frame of a scroll.
            if dragging != nil || carrying != nil,
               let tab = looseTabs.first(where: { folders.place(of: $0)?.folder == key && (folders.place(of: $0)?.more ?? 0) > 0 }) {
                out.shift.height = rowShift(tab, index: index(of: tab), step: step, moving: moving)
            }
        case .nest(let nest, _, _):
            if nest === formingNest { out.hold.choice = choice; return out }
            let lifted = carrying?.nest === nest
            out.hold.aimed = (aim?.into == nest.id && dragging != nil) || (herd?.into == nest.id && herd?.landed == false) || carrying?.into == nest.id
            out.hold.lifted = lifted
            out.front = lifted
            out.shift.height = lifted ? nestTravel : moving?.folders[nest.key] ?? 0
            if lifted { out.lean.x = CGFloat(carriedDepth - max(0, nest.depth - 1)) * Folders.indent }
            if let moving, moving.folders[nest.key] == nil, !lifted { out.opacity = 0 }
        case .task(let folder, _):
            out.shift.height = moving?.folders[folder.id] ?? 0
            if let moving, moving.folders[folder.id] == nil { out.opacity = 0 }
        case .line:
            out.shift.height = moving?.folders[Folders.newTab] ?? 0
            if let moving, moving.folders[Folders.line] == nil { out.opacity = 0 }
        case .newTab:
            out.shift.height = moving?.folders[Folders.newTab] ?? 0
        case .name:
            out.hold.aimed = onName && dragging != nil
        case .pin(let tab):
            let held = pinDragging == tab.id
            out.hold.lifted = (held || resting == tab.id) && carry == nil
            out.hold.pressed = pressedPin == tab.id && !held
            out.front = held || resting == tab.id
            out.shift = pinShift(tab, index: pinnedTabs.firstIndex { $0 === tab } ?? 0)
            if carry?.tab == tab.id || settling == tab.id { out.opacity = 0 }
            if decked == tab.id { out.opacity = 0.5 }
        default:
            break
        }
        // A folder's row, or its "N more", gone to dust in Clear's wave.
        let key: String? = item.folderKey.map(DrawnRows.folder) ?? { if case .more(let folder, _) = item.kind { return DrawnRows.more(folder) } else { return nil } }()
        if let key, browser?.dustingRows.contains(key) == true { out.opacity = 0 }
        if let browser, let bridge = ColumnSpaceCarry.of(browser) {
            if bridge.hides(item) { out.opacity = 0 }
            if bridge.overlaying {
                // The destination's layout already includes the gap.
                out.shift = .zero
                out.front = false
                if case .nest(let nest, _, _) = item.kind { out.hold.aimed = bridge.landing == .folder(nest.id) }
            }
        }
        if let dragging, dragging == item.tab?.id, SpaceDrop.shared.slot != nil { out.lean.scale = 0.94 }
        return out
    }

    /// The stored hand point is also valid between mouse events, while
    /// edge scrolling or a spring-load timer is running (and on the bench).
    private func spacePoint(_ point: CGPoint) -> NSPoint? {
        guard let pages = page.superview as? ColumnPages else { return nil }
        return pages.convert(CGPoint(x: point.x + SideBar.margin, y: point.y), to: nil)
    }

    // MARK: - the press

    private func attempt(_ event: NSEvent) -> Bool {
        // A row being renamed keeps its own presses, to place the caret.
        guard let browser, event.type == .leftMouseDown else { return false }
        if browser.editingTab != nil, let cell = page.cellAt(event), cell.kind == .tab, cell.current?.editing == true { return false }
        return page.item(at: page.convert(event.locationInWindow, from: nil)) != nil
    }

    private func press(_ point: NSPoint) {
        guard case .pin(let tab)? = page.item(at: point)?.kind else { return }
        pressedPin = tab.id
        page.redraw(nil)
    }

    private func unpress() {
        guard pressedPin != nil else { return }
        pressedPin = nil
        page.redraw(nil)
    }

    private func moved(_ grip: ColumnGrip) {
        guard let browser else { return }
        let point = column(grip.location(in: page))
        switch grip.state {
        case .began:
            // The whole drag one step for ⌘Z, whatever it changed on the
            // way (WindowUndo.swift).
            browser.holdArranging()
            startAt = column(grip.start)
            scrollAtStart = page.offset
            at = point
            guard let item = page.item(at: grip.start) else { return grip.state = .cancelled }
            spaceCarry = ColumnSpaceCarry(browser: browser, page: page, hand: self, item: item, start: grip.start)
            // The stationary pager's points only when the page sits in one;
            // a page hosted alone keeps its own (flipped) coordinates.
            grip.coordinateView = spaceCarry == nil ? nil : page.superview
            switch item.kind {
            case .tab(let tab), .pair(let tab, _):
                rowChanged(tab, index: index(of: tab), at: point)
            case .pin(let tab):
                pinChanged(tab, index: pinnedTabs.firstIndex { $0 === tab } ?? 0, at: point)
            case .nest(let nest, _, _):
                // Today's too, up to the kept whole, as in Arc (#440).
                nestChanged(nest, at: point)
            default:
                grip.state = .cancelled
            }
            spaceCarry?.move(CGPoint(x: point.x + SideBar.margin, y: point.y))
            if grip.state == .began { startScrolling() }
        case .changed:
            at = point
            continueDrag(at: point)
            spaceCarry?.move(CGPoint(x: point.x + SideBar.margin, y: point.y))
        case .ended:
            stopScrolling()
            at = point
            if spaceCarry?.overlaying == true { spaceCarry?.move(CGPoint(x: point.x + SideBar.margin, y: point.y)) }
            if let bridge = spaceCarry, bridge.finish(dot: SpaceDrop.shared.slot) {
                finishSpaceCarry()
            } else if let id = dragging, let tab = browser.tabs.first(where: { $0.id == id }) {
                rowEnded(tab, at: point)
            } else if let id = pinDragging, let tab = browser.tabs.first(where: { $0.id == id }) {
                pinEnded(tab)
            } else if carrying != nil {
                endCarry(cancelled: false)
            }
            clearSpaceCarry()
            // After the row settles: a sink and a landing change it late.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak browser] in browser?.letGoArranging() }
        case .cancelled, .failed:
            stopScrolling()
            brokenOff()
            browser.letGoArranging()
        default:
            break
        }
    }

    private func startScrolling() {
        stopScrolling()
        scrollTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            AppKitMainThread.sync { self?.scrollHeldRow() }
        }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func scrollHeldRow() {
        if let browser, let bridge = spaceCarry, bridge.overlaying, let shown = ColumnPages.of(browser)?.shown {
            let now = CACurrentMediaTime()
            let dt = min(0.05, now - scrollTick)
            scrollTick = now
            if SpaceDrop.shared.slot == nil {
                let velocity = ColumnDragScroll.velocity(at: CGPoint(x: at.x + SideBar.margin, y: at.y), in: shown.dragScrollRoom)
                if velocity != 0, shown.scrollHeldRows(by: velocity * dt) != 0 { bridge.move(CGPoint(x: at.x + SideBar.margin, y: at.y)) }
            }
            return
        }
        guard page.window != nil, !page.away, grip.state == .began || grip.state == .changed else {
            stopScrolling()
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - scrollTick)
        scrollTick = now
        guard dragging != nil || carrying != nil,
              torn == nil, decked == nil, carry == nil,
              herd?.pinAt == nil else { return }
        let point = CGPoint(x: at.x + SideBar.margin, y: at.y)
        let velocity = ColumnDragScroll.velocity(at: point, in: page.dragScrollRoom)
        guard velocity != 0, page.scrollHeldRows(by: velocity * dt) != 0 else { return }
        // Resting at an edge needs no next mouse-move. Only update the
        // held item's destination, never begin the native gesture again.
        continueDrag(at: at)
    }

    private func continueDrag(at point: CGPoint) {
        guard let browser else { return }
        if let bridge = spaceCarry, bridge.overlaying {
            // Leave the preview before tear-off asks for the original tab.
            if let event = grip.event, let window = page.window, let content = window.contentView,
               !content.bounds.contains(content.convert(event.locationInWindow, from: nil)) {
                bridge.cancel()
                let coordinates = grip.coordinateView
                clearSpaceCarry()
                grip.coordinateView = coordinates
            } else {
                bridge.move(CGPoint(x: point.x + SideBar.margin, y: point.y))
                return
            }
        }
        if let id = dragging, let tab = browser.tabs.first(where: { $0.id == id }) {
            rowChanged(tab, index: from, at: point)
        } else if let id = pinDragging, let tab = browser.tabs.first(where: { $0.id == id }) {
            pinChanged(tab, index: pinFrom, at: point)
        } else if let carried = carrying {
            nestChanged(carried.nest, at: point)
        }
    }

    private func scrolledTravel(_ hand: CGFloat) -> CGFloat {
        ColumnDragScroll.travel(hand: hand, offset: page.offset, beganAt: scrollAtStart)
    }

    /// From the page's own space to SideBar's "column".
    private func column(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x - SideBar.margin, y: point.y)
    }

    /// A drag the system broke off: everything back as it was (SideBar's
    /// `holding` going false with one still held).
    private func brokenOff() {
        // The carry first: a page left behind may have let its row go.
        spaceCarry?.cancel()
        clearSpaceCarry()
        guard dragging != nil || pinDragging != nil || carrying != nil else { return }
        SpaceDrop.shared.cancel()
        TearOff.shared.cancel()
        torn = nil
        if decked != nil {
            SplitDeck.shared.leave()
            decked = nil
        }
        unfold()
        stopTimers()
        if carrying != nil { endCarry(cancelled: true) }
        // A pin held over the spaces goes nowhere.
        if pinDragging != nil { SpaceDrop.shared.cancel() }
        carry = nil
        dragging = nil
        travel = 0
        bias = 0
        sprung = nil
        combine = nil
        folding = nil
        fold = 0
        pinDragging = nil
        pinTravel = .zero
        resting = nil
        herd = nil
        page.refresh(ColumnMotion.settle)
    }

    // MARK: - the lists

    private var looseTabs: [Tab] { browser?.tabs.filter { $0.pin == nil } ?? [] }
    /// The grid's cells: a pinned pair is one (PinPairs.swift).
    private var pinnedTabs: [Tab] { browser?.gridPins ?? [] }
    private var width: CGFloat { browser?.prefs.sideWidth ?? 240 }
    private var columnWidth: CGFloat { width - 2 * SideBar.margin }
    private var top: CGFloat { browser.map(ColumnLayout.pinsTop) ?? 0 }
    private var pinsLine: CGFloat { top + ColumnLayout.pinBlock(count: browser?.pinCellCount ?? 0, width: width) }
    private var rowsTop: CGFloat { page.rowsTop }

    private func index(of tab: Tab) -> Int { looseTabs.firstIndex { $0 === tab } ?? 0 }

    private func pinGeometry(count: Int) -> (cols: Int, width: CGFloat, height: CGFloat) { ColumnLayout.grid(count: count, width: width) }
    private func pinBlock(count: Int) -> CGFloat { ColumnLayout.pinBlock(count: count, width: width) }
    private func pinCenter(_ index: Int, count: Int) -> CGPoint { ColumnLayout.pinCenter(index, count: count, width: width, top: top) }

    private var baseCells: [ColumnLayout.Cell] { browser.map { ColumnLayout.cells($0) } ?? [] }

    /// The line's slot among the rows at rest, nil with none: past it the
    /// rows stand higher by as much as it is shorter than a row.
    private var lineSlot: Int? { ColumnLayout.lineSlot(in: baseCells, folders: folders) }
    /// Where a slot of the rows at rest starts, and the slot at a height.
    private func slotY(_ slot: Int) -> CGFloat { ColumnLayout.y(Double(slot), line: lineSlot) }
    private func slot(at y: CGFloat) -> Double { ColumnLayout.slot(y, line: lineSlot) }

    private func drawnRow(_ tab: Tab, index: Int) -> Int {
        guard let browser else { return index }
        return folders.folders.isEmpty && !folders.lined ? index : folders.slots(looseTabs, joined: !browser.pairs.isEmpty).tabs[tab.id] ?? index
    }

    private func still(_ tab: Tab, at index: Int) -> Folders.Landing {
        Folders.Landing(index: index, slot: drawnRow(tab, index: index), kept: tab.kept, nest: tab.nest?.id)
    }

    private func alone(_ held: Tab) -> [Tab] {
        guard let browser, let pair = browser.pair(of: held.id), pair.first == held.id else { return looseTabs }
        return looseTabs.filter { $0.id != pair.second }
    }

    private var pairRows: [Int]? {
        guard let browser, !browser.pairs.isEmpty else { return nil }
        var row = -1
        return looseTabs.map { tab in
            if browser.pair(of: tab.id)?.second != tab.id { row += 1 }
            return max(0, row)
        }
    }

    private func tabIndex(ofRow row: Int, in rows: [Int], down: Bool) -> Int {
        let at = down ? rows.lastIndex { $0 <= row } : rows.firstIndex { $0 >= row }
        return at ?? (down ? rows.count - 1 : 0)
    }

    // MARK: - the shifts (SideBar.rowShift, folderShifts, shiftsFor)

    private var shiftsKey: (aim: Folders.Landing, held: Tab.ID, count: Int, version: Int)?
    private var shiftsValue: Shifts?

    /// How far each row and folder's row moves for the hand, in points:
    /// from where it is laid at rest to where it would be, the line
    /// counted at its own height on both sides.
    typealias Shifts = (tabs: [Tab.ID: CGFloat], folders: [String: CGFloat])

    private static func shifts(now: (tabs: [Tab.ID: Int], folders: [String: Int]), then: (tabs: [Tab.ID: Int], folders: [String: Int])) -> Shifts {
        let was = now.folders[Folders.line], will = then.folders[Folders.line]
        func move(_ from: Int, _ to: Int) -> CGFloat { ColumnLayout.y(Double(to), line: will) - ColumnLayout.y(Double(from), line: was) }
        var tabs: [Tab.ID: CGFloat] = [:]
        for (key, slot) in now.tabs { tabs[key] = move(slot, then.tabs[key] ?? slot) }
        var made: [String: CGFloat] = [:]
        for (key, slot) in now.folders { if let there = then.folders[key] { made[key] = move(slot, there) } }
        return (tabs, made)
    }

    private var folderShifts: Shifts? {
        guard let browser, let aim, let id = dragging, carry == nil, herd == nil else { return nil }
        if let key = shiftsKey, key.aim == aim, key.held == id, key.count == browser.tabs.count, key.version == folders.version, let value = shiftsValue {
            return value
        }
        guard let held = looseTabs.first(where: { $0.id == id }) else { return nil }
        let value = shiftsFor(aim: aim, held: held, loose: alone(held))
        shiftsKey = (aim, id, browser.tabs.count, folders.version)
        shiftsValue = value
        return value
    }

    private func shiftsFor(aim: Folders.Landing, held: Tab, loose: [Tab]) -> Shifts {
        let joined = !(browser?.pairs.isEmpty ?? true)
        let id = held.id
        let now = folders.slots(loose, joined: joined)
        var order = loose.filter { $0.id != id }
        order.insert(held, at: min(aim.index, order.count))
        // The last of today's held up among the kept takes the line with it
        // at once, its room too: the rows close up over it, as they will
        // once it is let go, and it is back as the row comes down again.
        let then = folders.slots(order, out: aim.out ? id : nil, joined: joined, held: id, as: aim.guise)
        drawn = then.tabs
        return Self.shifts(now: now, then: then)
    }

    private func rowShift(_ tab: Tab, index: @autoclosure () -> Int, step: CGFloat, moving: Shifts?) -> CGFloat {
        if formingNest != nil { return 0 }
        if dragging == tab.id { return sinking == tab.id ? travel : heldShift(tab) }
        if carrying != nil { return moving?.tabs[tab.id] ?? 0 }
        guard dragging != nil, carry == nil, herd == nil else { return 0 }
        if let moving { return moving.tabs[tab.id] ?? 0 }
        return Self.shift(index(), from: from, to: target, rows: pairRows, step: step)
    }

    /// How far the row at `index` moves for a row held from `from` to `to`:
    /// a step up past it going down, a step down going up. With pairs the
    /// indices are counted in rows (`rows`, the row of each loose tab). The
    /// list can be shorter than the drag's indices, a tab closed or put away
    /// while one is held, and is read only where it has a row (crash #45).
    nonisolated static func shift(_ index: Int, from: Int, to: Int, rows: [Int]?, step: CGFloat) -> CGFloat {
        var (here, start, end) = (index, from, to)
        if let rows {
            guard let last = rows.indices.last else { return 0 }
            (here, start, end) = (rows[min(index, last)], rows[min(from, last)], rows[min(to, last)])
        }
        if start < end, here > start, here <= end { return -step }
        if end < start, here >= end, here < start { return step }
        return 0
    }

    private func pinShift(_ tab: Tab, index: @autoclosure () -> Int) -> CGSize {
        if pinDragging == tab.id { return pinTravel }
        guard pinDragging != nil, carry == nil else { return .zero }
        let index = index()
        var goal = index
        if pinFrom < pinGoal, index > pinFrom, index <= pinGoal { goal = index - 1 }
        if pinGoal < pinFrom, index >= pinGoal, index < pinFrom { goal = index + 1 }
        guard goal != index, let browser else { return .zero }
        let count = browser.pinCellCount
        let here = pinCenter(index, count: count)
        let there = pinCenter(goal, count: count)
        return CGSize(width: there.x - here.x, height: there.y - here.y)
    }

    private func indent(of place: Folders.Place?) -> CGFloat {
        guard let aim, aim.into == nil else { return 0 }
        let task = place.map { !Nest.isKey($0.folder) } ?? false
        let then = aim.nest.map { folders.nest($0)?.depth ?? 1 } ?? (task && !aim.out ? 1 : 0)
        return CGFloat(then - (place?.depth ?? 0)) * Folders.indent
    }

    private var carriedDepth: Int {
        guard let carried = carrying else { return 0 }
        if let into = carried.into { return folders.nest(into)?.depth ?? 0 }
        return carried.parent.flatMap { folders.nest($0)?.depth } ?? 0
    }

    private var tuck: CGFloat { combine != nil ? 1 : folding != nil ? fold : 0 }

    private func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func level() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func stopTimers() {
        choiceWork?.cancel()
        choiceWork = nil
        springWork?.cancel()
        springWork = nil
        springFor = nil
        dwellWork?.cancel()
        dwellWork = nil
    }

    // MARK: - a row in the hand (SideBar.reorder)

    private func rowChanged(_ tab: Tab, index: Int, at point: CGPoint) {
        guard let browser else { return }
        let step = ColumnLayout.step
        let translation = CGSize(width: point.x - startAt.x, height: point.y - startAt.y)
        if dragging != tab.id {
            dragging = tab.id
            from = index
            target = index
            aim = still(tab, at: index)
            fromSlot = aim?.slot ?? index
            shiftsKey = nil
            unfold()
            stopTimers()
            bias = 0
            sprung = nil
            onName = false
            combine = nil
            folding = nil
            fold = 0
            landedFor = 0
            resting = nil
            browser.glance.drop()
            page.raise(tab.id.uuidString)
            heldLaid = page.laidTop(tab.id.uuidString)
            let picked = browser.isPicked(tab) ? looseTabs.filter { browser.isPicked($0) }.map(\.id) : []
            if picked.count > 1 {
                gather(picked, held: tab, index: index, at: point)
            }
        }
        // Out past the window's edge: the tab is leaving the window.
        if herd == nil, TearOff.shared.track(tab, browser: browser, moved: translation, event: grip.event) {
            SpaceDrop.shared.cancel()
            if torn != tab.id {
                if decked != nil {
                    SplitDeck.shared.leave()
                    decked = nil
                }
                if carry != nil { drop() }
                unfold()
                stopTimers()
                sprung = nil
                bias = 0
                torn = tab.id
                combine = nil
                folding = nil
                fold = 0
                target = from
                travel = 0
                aim = still(tab, at: from)
                landedFor = 0
                page.refresh(ColumnMotion.settle)
            }
            return
        }
        if torn == tab.id {
            torn = nil
            page.refresh(ColumnMotion.settle)
        }
        // Over the space's capsule, or the tray it opens.
        let held = herd.map { herd in browser.tabs.filter { herd.members.contains($0.id) } } ?? [tab]
        if SpaceDrop.shared.track(held, browser: browser, at: spacePoint(point)) {
            unfold()
            if let herd, !herd.landed {
                page.hand(CGPoint(x: columnWidth / 2, y: point.y - herd.grip), ColumnMotion.follow)
            } else if herd == nil {
                travel = scrolledTravel(translation.height) + bias
                if carry != nil { drop() }
                if target != from { target = from }
                page.redraw(ColumnMotion.settle, held: dragging)
            }
            return
        }
        let out = browser.flank == .left ? point.x > width - SideBar.margin + 8 : point.x < -SideBar.margin - 8
        if out { unfold() }
        if out, decked == nil, carry == nil, let herd, herd.ids.count == 1, !herd.landed,
           let deck = decking(tab, at: startAt.x), SplitDeck.shared.begin(deck, in: browser) {
            unfold()
            decked = deck.id
            self.herd = nil
            target = from
            travel = 0
            aim = still(tab, at: from)
            landedFor = 0
            page.refresh(ColumnMotion.settle)
            return
        }
        if herd != nil {
            herdMove(to: point)
            return
        }
        if decked != nil {
            if out { SplitDeck.shared.move(); return }
            SplitDeck.shared.leave()
            decked = nil
        } else if out, carry == nil, let deck = decking(tab, at: startAt.x), SplitDeck.shared.begin(deck, in: browser) {
            unfold()
            decked = deck.id
            target = from
            travel = 0
            aim = still(tab, at: from)
            landedFor = 0
            page.redraw(ColumnMotion.settle)
            return
        }
        // In slots, where the landing and the folder are decided: the line
        // and New tab are slots there too, so a laying around the held row
        // moves nothing of it. Only the drawing counts that (laidSince).
        travel = scrolledTravel(translation.height) + bias
        // Down past the list, toward the space's capsule at the foot.
        // A pair row goes as the pair: alone, its first half left the
        // second behind and, let go under it, came back as the right half,
        // the two swapped (#259).
        if browser.spacesShown, withMate(tab).count > 1, belowRows(point.y) {
            target = from
            gather(withMate(tab), held: tab, index: index, at: point)
            herdMove(to: point)
            return
        }
        // Above the rows, in the pins: the row is being pinned. The
        // space's name over the rows counts from its middle up, so the pins
        // open as the row comes up onto the name and the rows don't first
        // make way for it at their top (2026-10-14); but a folded space's
        // name, which keeps what is let go on it.
        let name = page.headItems.first { if case .name = $0.kind { true } else { false } }
        var line = carry == nil ? pinsLine - 6 : top + pinBlock(count: browser.pinCellCount + 1) + 4
        if let name, !(folders.shut && tab.keepable) { line = max(line, name.y + name.height / 2 + (carry == nil ? 0 : 4)) }
        if point.y < line {
            onName = false
            let mate = pinnablePair(tab).flatMap { browser.tab(id: $0.second) }
            let goal = pinPlace(pinTarget(at: point), shared: Browser.sharable(tab) && (mate.map(Browser.sharable) ?? true))
            let cell = pinGeometry(count: browser.pinCellCount + 1)
            if carry == nil {
                lift(tab, toPins: true, index: goal,
                     from: CGPoint(x: columnWidth / 2, y: rowsTop + (page.laidTop(tab.id.uuidString) ?? slotY(drawnRow(tab, index: from))) + heldShift(tab) + SideBar.row / 2),
                     size: CGSize(width: columnWidth, height: SideBar.row),
                     to: point, becoming: CGSize(width: cell.width, height: cell.height))
            } else {
                follow(to: point, index: goal)
            }
            return
        }
        if carry != nil { drop() }
        // Over the name of the space folded under it: kept there.
        if let name = page.headItems.first(where: { if case .name = $0.kind { true } else { false } }), folders.shut, tab.keepable,
           point.y >= name.y - 2, point.y < name.y + name.height + 2 {
            if !onName {
                // The rows as they were, as over a shut folder: nothing
                // makes way for a row going into the name.
                onName = true
                stopTimers()
                unfold()
                level()
                target = from
                aim = still(tab, at: from)
                landedFor = .min
                page.redraw(ColumnMotion.settle, held: dragging)
                page.lineComingChanged()
            } else {
                page.redraw(nil, held: dragging)
            }
            return
        }
        if onName {
            onName = false
            landedFor = .min
            page.redraw(ColumnMotion.settle, held: dragging)
        }
        let moved = Int((travel / step).rounded())
        if let current = aim {
            let want = slot(at: slotY(fromSlot) + travel)
            dwell(tab)
            if choice != nil {
                page.redraw(nil, held: dragging)
                return
            }
            let deep = SideBar.deep(from: tab.nest?.depth ?? 0, sideways: translation.width)
            let key = Int((want * 4).rounded()) * 16 + (deep.map { $0 + 1 } ?? 0)
            guard key != landedFor else {
                page.redraw(nil, held: dragging)
                return
            }
            landedFor = key
            let next = intoSprung(tab, want: want, current: current)
                ?? folders.landing(tab, want: want, deep: deep, among: alone(tab), joined: !browser.pairs.isEmpty, current: current, drawn: fromSlot)
            spring(tab, next: next, want: want)
            // The choice hit test above owns the row's middle. At its edge,
            // let the normal landing reorder: the former centre-only gate
            // left no place to swap once the choice claimed that middle.
            if next != current {
                let crossed = next.kept != current.kept || (next.into != nil) != (current.into != nil)
                NSHapticFeedbackManager.defaultPerformer.perform(crossed ? .levelChange : .alignment, performanceTime: .now)
                target = next.index
                aim = next
                page.redraw(ColumnMotion.settle, held: dragging)
                page.lineComingChanged()
                return
            }
            page.redraw(nil, held: dragging)
            return
        }
        var goal = min(max(0, from + moved), looseTabs.count - 1)
        if let rows = pairRows, let last = rows.indices.last {
            let row = min(max(0, rows[min(from, last)] + moved), rows[last])
            goal = tabIndex(ofRow: row, in: rows, down: moved > 0)
            if browser.pair(of: tab.id) != nil, moved == 0 { goal = from }
        }
        if goal != target {
            tick()
            target = goal
            page.redraw(ColumnMotion.settle, held: dragging)
        } else {
            page.redraw(nil, held: dragging)
        }
    }

    private func rowEnded(_ tab: Tab, at point: CGPoint) {
        guard let browser else { return }
        let keptOnName = onName
        onName = false
        if TearOff.shared.finish(browser, event: grip.event) {
            unfold()
            stopTimers()
            sprung = nil
            bias = 0
            dragging = nil
            torn = nil
            travel = 0
            target = from
            aim = nil
            combine = nil
            folding = nil
            fold = 0
            page.refresh(nil)
            return
        }
        torn = nil
        if SpaceDrop.shared.finish(browser) {
            unfold()
            dragging = nil
            travel = 0
            target = from
            aim = nil
            herd = nil
            // The stack has a host of its own, kept with this space's page.
            page.stackGone()
            page.refresh(nil)
            return
        }
        if herd != nil {
            herdEnd()
            return
        }
        if let id = decked {
            let drop = SplitDeck.shared.end()
            decked = nil
            dragging = nil
            aim = nil
            travel = 0
            if let drop, let held = browser.tabs.first(where: { $0.id == id }) {
                browser.dropSplit(held, drop)
            }
            page.refresh(nil)
            return
        }
        if let carry, carry.toPins {
            // Up in the pins: it lands as a square, where the gap was.
            let count = browser.pinCellCount + 1
            let cell = pinGeometry(count: count)
            // Out of the hand before the rows are laid again: held, the
            // rows were laid one frame with the shifts of a landing among
            // them, a row up, and glided back (2026-10-14).
            dragging = nil
            travel = 0
            aim = nil
            target = from
            let pair = pinnablePair(tab)
            land(tab, at: pinCenter(carry.index, count: count), size: CGSize(width: cell.width, height: cell.height)) {
                // A pair row: the pair pinned as one, its square where the
                // gap was, as the menu's Pin Pair makes it (PinPairs.swift).
                if let pair {
                    browser.pinPair(pair, cell: carry.index)
                    return
                }
                // A half of a pair leaves a square on its page (`pin`).
                let pinned = browser.pin(tab) ?? tab
                browser.move(pinned, to: carry.index)
            }
            return
        }
        stopTimers()
        sprung = nil
        bias = 0
        guard dragging == tab.id else { return }
        if choice != nil, (point.x < 0 || point.x > columnWidth || choiceTarget(held: tab) != choice?.target) { unfold() }
        // Let go out over the pages with nothing there to take it: back.
        if point.x > width - SideBar.margin + 8 {
            combine = nil
            folding = nil
            fold = 0
            aim = nil
            target = from
        }
        if let choice, choice.revealed, choice.side == .split,
           let other = browser.tab(id: choice.target), browser.canCarry(tab, beside: other) {
            self.choicePreviousActive = nil
            self.choice = nil
            combine = nil
            folding = nil
            fold = 0
            dragging = nil
            aim = nil
            travel = 0
            browser.split(tab, with: other)
            page.refresh(ColumnMotion.settle)
            return
        }
        if let id = combine, let other = browser.tabs.first(where: { $0.id == id }) {
            glide(tab) {
                self.formingNest = nil
                self.choice = nil
                self.combine = nil
                self.folding = nil
                self.fold = 0
                browser.newFolder(with: [other, tab], today: !other.kept, around: other)
            }
            return
        }
        unfold()
        if keptOnName {
            sinkKept(tab)
            return
        }
        if let into = aim?.into, let nest = browser.nests.first(where: { $0.id == into }) {
            sink(tab, into: nest)
            return
        }
        let rows = aim.map { $0.slot - fromSlot } ?? pairRows.flatMap { rows in rows.indices.last.map { rows[min(target, $0)] - rows[min(from, $0)] } } ?? target - from
        let leaving = aim?.out == true
        let guise = aim?.guise
        let left = travel - (slotY(fromSlot + rows) - slotY(fromSlot))
        put(tab, left: CGSize(width: 0, height: left)) {
            // Out of its task first: adopted, it may be kept.
            if leaving { self.folders.keep(tab) }
            let changed = guise.map { $0.kept != tab.kept || $0.nest != tab.nest?.id } ?? false
            if let guise, changed {
                tab.kept = guise.kept && tab.keepable
                tab.nest = guise.nest.flatMap { id in browser.nests.first { $0.id == id } }
            }
            let past = self.aim != nil && self.target > self.from && browser.partner(of: tab) != nil && browser.pair(of: tab.id)?.first == tab.id
            if self.target != self.from { browser.move(tab, to: self.target + (past ? 1 : 0) + browser.pinnedCount) }
            if changed {
                self.folders.refresh()
                browser.writeSession(now: true)
            }
            self.dragging = nil
            self.aim = nil
            self.travel = 0
        }
    }

    /// Let go inside its own list: the list changes at once, the one let go
    /// glides the last of the way from where the hand left it (SideBar.put).
    private func put(_ tab: Tab, left: CGSize, change: () -> Void) {
        // Where it is drawn now, from the rows' top: the glide starts there
        // whatever the list does around it.
        let drawnAt = page.laidTop(tab.id.uuidString).map { $0 + heldShift(tab) }
        change()
        resting = tab.id
        page.refresh(nil)
        var left = left
        if let drawnAt, let now = page.laidTop(tab.id.uuidString) { left.height = drawnAt - now }
        page.settle(tab.id.uuidString, from: left)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.resting == tab.id, self.dragging == nil, self.pinDragging == nil else { return }
            self.resting = nil
            self.page.redraw(nil)
        }
    }

    /// The list changed under a held row, at once, and it glides the last
    /// of the way from the hand to where it now stands (SideBar.glide).
    private func glide(_ tab: Tab, change: () -> Void) {
        let hand = slotY(fromSlot) + heldShift(tab)
        change()
        dragging = nil
        aim = nil
        travel = 0
        let now = looseTabs.firstIndex { $0.id == tab.id } ?? 0
        resting = tab.id
        page.refresh(nil)
        page.settle(tab.id.uuidString, from: CGSize(width: 0, height: hand - slotY(drawnRow(tab, index: now))))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.resting == tab.id, self.dragging == nil else { return }
            self.resting = nil
            self.page.redraw(nil)
        }
    }

    /// Let go over a shut folder of yours: it goes in, smaller (SideBar.sink).
    private func sink(_ tab: Tab, into nest: Nest) {
        guard let browser else { return }
        if tab.id == browser.activeID {
            glide(tab) { browser.file([tab], in: nest) }
            return
        }
        let head = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[nest.key] ?? fromSlot
        travel = slotY(head) - slotY(fromSlot)
        sinking = tab.id
        page.redraw(.timing(0.2, 0.8, 0.2, 1, duration: 0.16), held: dragging)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            browser.file([tab], in: nest)
            self.dragging = nil
            self.aim = nil
            self.travel = 0
            self.page.refresh(ColumnMotion.settle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.sinking == tab.id {
                    self?.sinking = nil
                    self?.page.redraw(nil)
                }
            }
        }
    }

    /// Let go over the name of a space folded under it: up into the name,
    /// smaller, as into a shut folder, and kept at the end of its kept.
    private func sinkKept(_ tab: Tab) {
        guard let browser else { return }
        let name = page.headItems.first { if case .name = $0.kind { true } else { false } }
        if let name, let laid = page.laidTop(tab.id.uuidString) {
            travel = name.y - rowsTop - laid
        }
        sinking = tab.id
        page.redraw(.timing(0.2, 0.8, 0.2, 1, duration: 0.16), held: dragging)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            browser.keepTabs([tab])
            self.dragging = nil
            self.aim = nil
            self.travel = 0
            self.page.refresh(ColumnMotion.settle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.sinking == tab.id {
                    self?.sinking = nil
                    self?.page.redraw(nil)
                }
            }
        }
    }

    // MARK: - folders under the hand (SideBar.spring, refold, dwell)

    private func spring(_ tab: Tab, next: Folders.Landing, want: Double) {
        guard let browser else { return }
        if let into = next.into, let nest = browser.nests.first(where: { $0.id == into }), !nest.open,
           browser.tabs.contains(where: { $0.nest?.within(nest) == true }) {
            guard springFor != into else { return }
            springWork?.cancel()
            springFor = into
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.dragging == tab.id, self.aim?.into == into, !nest.open else { return }
                self.level()
                self.sprung = into
                self.refold(tab, nest: nest)
            }
            springWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        springWork?.cancel()
        springFor = nil
        guard let open = sprung, let nest = browser.nests.first(where: { $0.id == open }), nest.open,
              next.nest.flatMap({ folders.nest($0) })?.within(nest) != true,
              next.into.flatMap({ folders.nest($0) })?.within(nest) != true else { return }
        let loose = alone(tab)
        let drawn = folders.slots(loose, joined: !browser.pairs.isEmpty)
        let head = drawn.folders[nest.key] ?? 0
        let last = loose.filter { $0.nest?.within(nest) == true }.compactMap { drawn.tabs[$0.id] }.max() ?? head
        guard want < Double(head) - 0.8 || want > Double(last) + 1.5 else { return }
        sprung = nil
        refold(tab, nest: nest)
    }

    private func refold(_ tab: Tab, nest: Nest) {
        guard let browser else { return }
        let index = looseTabs.firstIndex { $0.id == tab.id } ?? from
        let before = fromSlot
        let opening = !nest.open
        refolding = opening ? ColumnMotion.opening : ColumnMotion.shutting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refolding = nil }
        folders.toggle(nest.key) { [weak self] in
            guard let self else { return }
            // Its slot moved as far as its place did: the landing stays
            // where the pointer is, as the drawing does. It was pushed
            // past the folder's head too, and let go a little under the
            // head it landed a row under the pointer, out of the folder.
            let after = self.drawnRow(tab, index: index)
            let moved = self.slotY(after) - self.slotY(before)
            self.bias -= moved
            self.travel -= moved
            self.fromSlot = after
            self.landedFor = .min
            self.aim?.into = nil
            guard let current = self.aim else { return }
            let want = self.slot(at: self.slotY(self.fromSlot) + self.travel)
            let next = self.intoSprung(tab, want: want, current: current)
                ?? self.folders.landing(tab, want: want, among: self.alone(tab), joined: !browser.pairs.isEmpty, current: current, drawn: self.fromSlot)
            self.target = next.index
            self.aim = next
            self.page.refresh(self.refolding)
        }
    }

    /// Over the head of the folder sprung open under the hand: into it, as
    /// over it shut, so a let-go there puts the tab in. The landing used to
    /// push the held row's slot past the head instead, and the row landed
    /// a row under the pointer.
    private func intoSprung(_ tab: Tab, want: Double, current: Folders.Landing) -> Folders.Landing? {
        guard let browser, let open = sprung, let nest = browser.nests.first(where: { $0.id == open }), nest.open,
              let head = folders.slots(alone(tab), joined: !browser.pairs.isEmpty).folders[nest.key] else { return nil }
        let reach = current.into == nest.id ? 0.6 : 0.5
        guard want >= Double(head) - reach, want <= Double(head) + reach else { return nil }
        var into = current
        into.into = nest.id
        return into
    }

    private func dwell(_ tab: Tab) {
        guard let browser else { return }
        guard tab.keepable, herd == nil, carry == nil, aim?.into == nil,
              at.x >= 0, at.x <= columnWidth,
              let under = choiceTarget(held: tab),
              let other = browser.tab(id: under) else { return unfold() }
        let canSplit = browser.canCarry(tab, beside: other)
        let side: TabDropChoice.Side = canSplit && at.x >= columnWidth / 2 ? .split : .folder
        if choice?.target == under {
            if choice?.side != side {
                if formingNest != nil { formingNest = nil; page.refresh(ColumnMotion.settle) }
                choice?.side = side
                choice?.fill = 0
                choice?.ready = false
                combine = nil
                choiceWork?.cancel()
                if choice?.revealed == true { choose(tab, other: other) }
            }
            return
        }
        unfold()
        folding = under
        fold = 0
        choice = TabDropChoice(target: under, side: side, canSplit: canSplit)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragging == tab.id, self.choice?.target == under else { return }
            self.dwellWork = nil
            self.choice?.revealed = true
            self.fold = 1
            self.tick()
            self.choose(tab, other: other)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TabDropChoice.revealDelay, execute: work)
    }

    /// Hit the row actually drawn under the pointer, leaving its edge for
    /// reordering. Folder headers, pins and agent rows are not choices.
    private func choiceTarget(held: Tab) -> Tab.ID? {
        guard let browser else { return nil }
        if let choice, choice.ready, let middle = formingPointerY,
           abs(at.y - middle) < SideBar.row / 2 { return choice.target }
        let partner = browser.partner(of: held)?.id
        let moving = folderShifts
        for item in page.items {
            if item.id.hasPrefix("choice child ") { continue }
            let tab: Tab
            switch item.kind {
            case .tab(let value), .pair(let value, _): tab = value
            default: continue
            }
            guard tab.id != held.id, tab.id != partner, tab.keepable,
                  !folders.theirs(tab), let middle = page.rowMiddle(item.id) else { continue }
            let shift = rowShift(tab, index: index(of: tab), step: ColumnLayout.step, moving: moving)
            if abs(at.y - middle - shift) < SideBar.row / 2 - 3 { return tab.id }
        }
        return nil
    }

    private func choose(_ tab: Tab, other: Tab) {
        guard let choice else { return }
        if choice.side == .split {
            if choicePreviousActive == nil { choicePreviousActive = browser?.activeID }
            browser?.select(other)
            browser?.previewSplit(.right)
        } else {
            restoreChoicePreview()
            self.choice?.fill = 0
            page.redraw(nil, held: dragging)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.choice?.target == other.id, self.choice?.side == .folder else { return }
                self.choice?.fill = 1
                self.page.redraw(nil, held: self.dragging)
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.dragging == tab.id, self.choice?.target == other.id,
                      self.choice?.side == .folder else { return }
                let nest = Nest(name: "New Folder")
                nest.fleeting = !other.kept
                self.formingNest = nest
                self.formingPointerY = self.at.y
                self.choice?.count = (self.browser?.partner(of: other) == nil ? 1 : 2) + (self.browser?.partner(of: tab) == nil ? 1 : 2)
                self.choice?.ready = true
                self.combine = other.id
                self.level()
                self.page.refresh(ColumnMotion.choiceFolder)
            }
            choiceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TabDropChoice.folderHold, execute: work)
        }
        page.redraw(ColumnMotion.choiceReveal, held: dragging, turning: ColumnMotion.choiceReveal.animation)
        spaceCarry?.refreshHand()
    }

    private func restoreChoicePreview() {
        guard choice?.side == .split || choicePreviousActive != nil else { return }
        browser?.previewSplit(nil)
        if let id = choicePreviousActive, let previous = browser?.tab(id: id) { browser?.select(previous) }
        choicePreviousActive = nil
    }

    private func unfold() {
        dwellWork?.cancel()
        dwellWork = nil
        choiceWork?.cancel()
        choiceWork = nil
        restoreChoicePreview()
        let formed = formingNest != nil
        formingNest = nil
        formingPointerY = nil
        choice = nil
        combine = nil
        fold = 0
        folding = nil
        if formed { page.refresh(ColumnMotion.settle) }
        page.redraw(ColumnMotion.quick, held: dragging, turning: Motion.quick)
        spaceCarry?.refreshHand()
    }

    private func decking(_ tab: Tab, at x: CGFloat) -> Tab? {
        guard let browser, let other = browser.partner(of: tab), browser.pair(of: tab.id)?.first == tab.id else { return tab }
        return x > columnWidth / 2 ? other : tab
    }

    // MARK: - a folder of yours in the hand (SideBar.nestReorder)

    private func nestChanged(_ nest: Nest, at point: CGPoint) {
        guard let browser else { return }
        if carrying?.nest !== nest {
            // One with no tabs yet drags as any row, as in Arc: it was taken
            // as nothing to carry and the drag was dropped (feedback #384).
            let empty = !browser.tabs.contains(where: { $0.nest?.within(nest) == true })
            guard !empty || folders.empties.contains(where: { $0 === nest }) else { return grip.state = .cancelled }
            folders.carry(nest.key)
            let from = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[nest.key] ?? 0
            let kept = browser.tabs.filter(\.kept)
            let index: Int
            if empty {
                // Where it stands now: over a run, at the end of the folder
                // it is in, or at the kept's end.
                let row = looseTabs.filter(\.kept)
                if let parent = nest.parent {
                    index = row.lastIndex { $0.nest?.within(parent) == true }.map { $0 + 1 } ?? row.count
                } else {
                    index = nest.stand.flatMap { stand in row.firstIndex { $0.id == stand.before } } ?? row.count
                }
            } else if nest.today {
                // Below the line: at the kept's end until it is over them.
                index = kept.count
            } else {
                let first = kept.firstIndex { $0.nest?.within(nest) == true } ?? 0
                index = kept.prefix(first).filter { $0.nest?.within(nest) != true }.count
            }
            carrying = NestCarry(nest: nest, fromSlot: from, index: index, slot: from, parent: nest.parent?.id, empty: empty, today: nest.today)
            level()
            browser.glance.drop()
            page.raise(nest.key)
            page.refresh(ColumnMotion.settle)
        }
        nestTravel = scrolledTravel(point.y - startAt.y)
        guard let carried = carrying else { return }
        // Over a space in the foot, the capsule or the tray: the folder goes
        // there whole when let go (SpaceDrop), and the rows wait as they are.
        if SpaceDrop.shared.track(browser.tabs(in: nest), browser: browser, folder: nest, at: spacePoint(point)) {
            page.redraw(nil, held: nil, nest: nest.key)
            return
        }
        let want = slot(at: slotY(carried.fromSlot) + nestTravel)
        // Over the kept, above the line as drawn now, or among today's,
        // in another order.
        let slots = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders
        let line = slots[Folders.line] ?? slots[Folders.newTab] ?? 0
        let up = Double(want) < Double(line)
        if up != carried.up {
            carrying?.up = up
            tick()
            if !up {
                carrying?.index = browser.tabs.filter(\.kept).count
                carrying?.slot = carried.fromSlot
                carrying?.parent = nil
                carrying?.into = nil
            }
        }
        if !up {
            let next = folders.todayLanding(nest, want: want, among: looseTabs, joined: !browser.pairs.isEmpty)
            let moved = next != carrying?.gap
            if moved, carrying?.gap != nil { tick() }
            carrying?.gap = next
            page.redraw(moved ? ColumnMotion.settle : nil, held: nil, nest: nest.key)
            return
        }
        carrying?.gap = nil
        let deep = SideBar.deep(from: nest.depth - 1, sideways: point.x - startAt.x)
        var next = folders.nestLanding(nest, want: want, deep: deep, among: looseTabs, joined: !browser.pairs.isEmpty, current: carrying?.landing,
                                       drawn: carried.empty ? emptyDrawn?.then.folders : nil)
        let emptyBlock = emptyBlockLanding(carried, want: want, deep: deep, into: next.into)
        if let emptyBlock { next.slot = emptyBlock.slot; next.parent = nil }
        if next != carried.landing || emptyBlock != carried.emptyBlock {
            if next.index != carried.index || (next.into != nil) != (carried.into != nil) { tick() }
            carrying?.index = next.index
            carrying?.slot = next.slot
            carrying?.parent = next.parent
            carrying?.into = next.into
            carrying?.emptyBlock = emptyBlock
            page.redraw(ColumnMotion.settle, held: nil, nest: nest.key)
        } else {
            page.redraw(nil, held: nil, nest: nest.key)
        }
    }

    /// Only the flat unanchored empty block with no kept tab rows. Keep
    /// nestLanding's into/depth decision, including its retained 0.6 band.
    private func emptyBlockLanding(_ carried: NestCarry, want: Double, deep: Int?, into: UUID?) -> EmptyBlockLanding? {
        guard carried.empty, !carried.today, into == nil, deep == nil || deep == 0,
              !folders.shut, !looseTabs.contains(where: \.kept) else { return nil }
        let block = folders.block
        guard block.count > 1, block.contains(where: { $0 === carried.nest }),
              block.count == folders.empties.count,
              block.allSatisfy({ $0.parent == nil && $0.stand == nil && !$0.today }),
              !looseTabs.contains(where: { tab in block.contains { tab.nest?.within($0) == true } }) else { return nil }
        let heads = folders.slots(looseTabs, joined: browser?.pairs.isEmpty == false).folders
        let rest = block.filter { $0 !== carried.nest }
        let gaps = rest.enumerated().compactMap { index, nest -> (EmptyBlockLanding.Anchor, Int, Double)? in
            heads[nest.key].map { (.before(nest.id), index, Double($0) - 0.5) }
        }
        guard gaps.count == rest.count, let last = rest.last, let lastSlot = heads[last.key] else { return nil }
        let choices = gaps + [(.end, rest.count, Double(lastSlot) + 0.5)]
        guard let best = choices.min(by: { abs($0.2 - want) < abs($1.2 - want) }) else { return nil }
        return EmptyBlockLanding(anchor: best.0, order: block.map(\.id), slot: best.1)
    }

    private func endCarry(cancelled: Bool) {
        guard let browser, let carried = carrying else { return }
        let hand = slotY(carried.fromSlot) + nestTravel
        if cancelled {
            SpaceDrop.shared.cancel()
        } else if SpaceDrop.shared.finish(browser) {
            // Gone to another space, or left where it was.
            carrying = nil
            nestTravel = 0
            folders.carry(nil)
            page.refresh(nil)
            return
        }
        if !cancelled, carried.empty, carried.gap == nil {
            if carried.today { browser.keep(carried.nest, at: carried.index, in: nil) }
            putEmpty(carried)
        } else if !cancelled, carried.today || carried.gap != nil {
            // Let go above the line: kept whole, where it was shown going.
            if carried.up {
                browser.arranging {
                    if let into = carried.into, let there = folders.nest(into) {
                        browser.keep(carried.nest, at: browser.tabs.filter(\.kept).count, in: nil)
                        browser.file(carried.nest, in: there)
                    } else {
                        browser.keep(carried.nest, at: carried.index, in: carried.parent.flatMap { folders.nest($0) })
                    }
                }
            } else if let gap = carried.gap {
                browser.move(carried.nest, before: gap.before)
            }
        } else if !cancelled {
            if let into = carried.into, let there = folders.nest(into) {
                browser.file(carried.nest, in: there)
            } else {
                browser.move(carried.nest, to: carried.index, in: carried.parent.flatMap { folders.nest($0) })
            }
        }
        carrying = nil
        nestTravel = 0
        folders.carry(nil)
        page.refresh(ColumnMotion.settle)
        let head = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[carried.nest.key] ?? carried.fromSlot
        page.settle(carried.nest.key, from: CGSize(width: 0, height: hand - slotY(head)))
    }

    /// An empty folder let go: into the folder under it, into the one it
    /// was let go in, or at the top of the kept, standing over the run
    /// below where it was let go (Nest.stand).
    private func putEmpty(_ carried: NestCarry) {
        guard let browser else { return }
        let nest = carried.nest
        if let destination = carried.emptyBlock {
            let before: UUID?
            switch destination.anchor { case .before(let id): before = id; case .end: before = nil }
            browser.arranging {
                if folders.reorderEmptyBlock(nest, before: before, expected: destination.order) {
                    browser.writeSession(now: true)
                }
            }
            // A stale sibling/block must not fall through to stand(nil).
            return
        }
        if let into = carried.into, let there = folders.nest(into) {
            browser.arranging { browser.file(nest, in: there) }
            return
        }
        let parent = carried.parent.flatMap { folders.nest($0) }
        if let parent {
            if parent !== nest.parent { browser.arranging { browser.file(nest, in: parent) } }
            return
        }
        browser.arranging {
            if nest.parent != nil {
                nest.parent = nil
                folders.emptyChanged(nest)
            }
            let kept = looseTabs.filter(\.kept)
            var head = carried.index < kept.count ? kept[carried.index] : nil
            // Never over the second of a pair: over the pair's row.
            if let tab = head, let pair = browser.pair(of: tab.id), pair.second == tab.id, carried.index > 0,
               kept[carried.index - 1].id == pair.first { head = kept[carried.index - 1] }
            folders.stand(nest, before: head?.id)
            browser.writeSession(now: true)
        }
    }

    /// Where the rows go for an empty folder in the hand: out of its slot
    /// and into the one it would be let go in, each row between a step.
    private var emptyShifts: Shifts? {
        emptyDrawn.map { Self.shifts(now: $0.now, then: $0.then) }
    }

    /// The rows now and as drawn for an empty folder in the hand, which
    /// nestLanding measures the hand against.
    private var emptyDrawn: (now: (tabs: [Tab.ID: Int], folders: [String: Int]), then: (tabs: [Tab.ID: Int], folders: [String: Int]))? {
        guard let browser, let carried = carrying, carried.empty else { return nil }
        let base = folders.slots(looseTabs, joined: !browser.pairs.isEmpty)
        guard let from = base.folders[carried.nest.key] else { return nil }
        let rows = 1
        // Its slot in the rows without it.
        var to = carried.slot
        // Over a shut folder, going in: the rows stay as drawn for where it
        // was going, as for a held tab, so the folder stays under the hand
        // (Folders.nestLanding measures them so). Put back where it came
        // from, the row it was going into stepped away from under the hand
        // and the next one along took it (#1981).
        if let gap = carried.gap {
            to = gap.slot > from ? gap.slot - rows : gap.slot
        } else if let id = carried.parent, let parent = folders.nest(id) {
            // At the end of that folder's run, where an empty one stands.
            let ends = base.tabs.filter { tab, _ in looseTabs.first { $0.id == tab }?.nest?.within(parent) == true }.map(\.value)
                + base.folders.filter { key, _ in key != carried.nest.key && folders.folder(key)?.nest?.within(parent) == true }.map(\.value)
            guard let last = ends.max() else { return nil }
            to = last + 1 - (last + 1 > from ? rows : 0)
        } else if carried.emptyBlock == nil, carried.index >= looseTabs.prefix(while: \.kept).count {
            // At the kept's end, after the empty ones already there.
            to = carried.slot + folders.block.filter { $0 !== carried.nest }.count
        }
        func moved(_ slot: Int) -> Int {
            let out = slot > from ? slot - rows : slot
            return out >= to ? out + rows : out
        }
        var then: (tabs: [Tab.ID: Int], folders: [String: Int]) = (base.tabs.mapValues(moved), [:])
        for (key, slot) in base.folders { then.folders[key] = key == carried.nest.key ? to : moved(slot) }
        return (base, then)
    }

    private var nestShifts: Shifts? {
        guard let browser, let carried = carrying else { return nil }
        if carried.empty { return emptyShifts }
        let joined = !browser.pairs.isEmpty
        let loose = looseTabs
        let now = folders.slots(loose, joined: joined)
        // A folder of today's still under the line: the rows make way there.
        if carried.gap != nil, !carried.up {
            guard let gap = carried.gap else { return Self.shifts(now: now, then: now) }
            return Self.shifts(now: now, then: folders.slots(browser.order(carried.nest, before: gap.before).filter { $0.pin == nil }, joined: joined, today: Set(browser.tabs(in: carried.nest).map(\.id))))
        }
        let members = loose.filter { $0.nest?.within(carried.nest) == true }
        var order = loose.filter { $0.nest?.within(carried.nest) != true }
        let kept = order.prefix(while: \.kept).count
        order.insert(contentsOf: members, at: min(carried.index, kept))
        let then = folders.slots(order, joined: joined, kept: carried.today ? Set(members.map(\.id)) : [])
        return Self.shifts(now: now, then: then)
    }

    // MARK: - a pin in the hand (SideBar.pinReorder)

    private func pinChanged(_ tab: Tab, index: Int, at point: CGPoint) {
        guard let browser else { return }
        if pinDragging != tab.id {
            pinDragging = tab.id
            pinFrom = index
            pinGoal = index
            pressedPin = nil
            browser.glance.drop()
            page.raise("pin " + tab.id.uuidString)
        }
        // Out over the pages, as a row goes (`rowChanged`): the pin stays in
        // the grid and a copy of its page makes the pair (SplitDeck,
        // Browser.dropSplit).
        let out = browser.flank == .left ? point.x > self.width - SideBar.margin + 8 : point.x < -SideBar.margin - 8
        if decked != nil {
            if out { SplitDeck.shared.move(); return }
            SplitDeck.shared.leave()
            decked = nil
        } else if out, SplitDeck.shared.begin(tab, in: browser) {
            if carry != nil { drop() }
            decked = tab.id
            pinGoal = pinFrom
            pinTravel = .zero
            page.redraw(ColumnMotion.settle, held: nil, pin: tab.id)
            return
        }
        pinTravel = CGSize(width: point.x - startAt.x, height: point.y - startAt.y)
        // Over the space's capsule, the tray it opens or a space in the
        // foot, as a row is (`rowChanged`): the pin is going to another
        // space, and the grid keeps its place. A pinned pair's square stays
        // the grid's (PinPairs.swift).
        if browser.pinPair(of: tab.id) == nil, SpaceDrop.shared.track([tab], browser: browser, at: spacePoint(point)) {
            if carry != nil { drop() }
            if pinGoal != pinFrom { pinGoal = pinFrom }
            page.redraw(ColumnMotion.settle, held: nil, pin: tab.id)
            return
        }
        let width = pinGeometry(count: browser.pinCellCount).width, height = pinGeometry(count: browser.pinCellCount).height
        // Below the grid, among the rows: the pin is being let go of.
        let below = point.y > pinsLine + (carry == nil ? 6 : -6)
        if below {
            let goal = min(max(0, Int(slot(at: point.y - rowsTop).rounded(.down))), ColumnLayout.rows(baseCells, folders: folders))
            let spot = CGPoint(x: columnWidth / 2, y: point.y)
            if carry == nil {
                let start = pinCenter(pinFrom, count: browser.pinCellCount)
                lift(tab, toPins: false, index: goal,
                     from: CGPoint(x: start.x + pinTravel.width, y: start.y + pinTravel.height),
                     size: CGSize(width: width, height: height),
                     to: spot, becoming: CGSize(width: columnWidth, height: SideBar.row))
            } else {
                follow(to: spot, index: goal)
            }
            return
        }
        if carry != nil { drop() }
        let cols = pinGeometry(count: browser.pinCellCount).cols
        let stepX = width + SideBar.pinGap, stepY = height + SideBar.pinGap
        let moved = Int((pinTravel.height / stepY).rounded()) * cols + Int((pinTravel.width / stepX).rounded())
        let goal = pinPlace(min(max(0, pinFrom + moved), max(0, pinnedTabs.count - 1)), shared: tab.everywhere != nil, moving: true)
        if goal != pinGoal {
            tick()
            pinGoal = goal
            page.redraw(ColumnMotion.settle, held: nil, pin: tab.id)
        } else {
            page.redraw(nil, held: nil, pin: tab.id)
        }
    }

    private func pinEnded(_ tab: Tab) {
        guard let browser else { return }
        if let id = decked {
            let drop = SplitDeck.shared.end()
            decked = nil
            pinDragging = nil
            pinTravel = .zero
            if let drop, let held = browser.tabs.first(where: { $0.id == id }) {
                browser.dropSplit(held, drop)
            }
            page.refresh(nil)
            return
        }
        // Let go over another space: it went there (Browser.moveTabs).
        if SpaceDrop.shared.finish(browser) {
            if carry != nil { drop() }
            pinDragging = nil
            pinTravel = .zero
            page.refresh(nil)
            return
        }
        if let carry, !carry.toPins {
            // Down among the rows: it lands as one, where the gap was.
            let base = baseCells
            let rowsTop = top + pinBlock(count: browser.pinCellCount - 1) + page.nameBlock - page.offset
            let spot = ColumnLayout.placing(ColumnLayout.position(carry.index, in: base, folders: folders), in: base)
            // The line come in over it stands a row above where it lands.
            let lined = pinComesToday ? ColumnLayout.lineStep : 0
            land(tab, at: CGPoint(x: columnWidth / 2, y: rowsTop + slotY(carry.index) + lined + SideBar.row / 2),
                 size: CGSize(width: columnWidth, height: SideBar.row)) {
                // A pinned pair's square comes down a pair row (`unpin`),
                // both halves where it lands.
                let halves = [tab] + [browser.pinMate(of: tab)].compactMap { $0 }
                browser.unpin(tab)
                if spot.kept, halves.allSatisfy(\.keepable) {
                    for half in halves {
                        half.kept = true
                        half.nest = spot.nest
                    }
                } else if let nest = spot.nest, nest.today {
                    for half in halves { half.nest = nest }
                }
                let rest = browser.tabs.filter { $0.pin == nil && $0.id != tab.id }
                let index = spot.before.flatMap { before in rest.firstIndex { $0.id == before.id } } ?? rest.count
                browser.move(tab, to: browser.pinnedCount + index)
                self.folders.refresh()
            }
            pinDragging = nil
            pinTravel = .zero
            return
        }
        guard pinDragging == tab.id else { return }
        let count = browser.pinCellCount
        let start = pinCenter(pinFrom, count: count)
        let end = pinCenter(pinGoal, count: count)
        let left = CGSize(width: start.x + pinTravel.width - end.x, height: start.y + pinTravel.height - end.y)
        if pinGoal != pinFrom { browser.move(tab, to: browser.pinRow(forCell: pinGoal, moving: tab, from: pinFrom)) }
        pinDragging = nil
        pinTravel = .zero
        resting = tab.id
        page.refresh(nil)
        page.settle("pin " + tab.id.uuidString, from: left)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.resting == tab.id, self.dragging == nil, self.pinDragging == nil else { return }
            self.resting = nil
            self.page.redraw(nil)
        }
    }

    private func pinPlace(_ index: Int, shared: Bool, moving: Bool = false) -> Int {
        guard let browser, browser.showsShared(browser.spaceID) else { return index }
        let count = browser.tabs.prefix { $0.everywhere != nil }.count
        return shared ? min(index, max(0, count - (moving ? 1 : 0))) : max(index, count)
    }

    private func pinTarget(at point: CGPoint, adding: Int = 1) -> Int {
        guard let browser else { return 0 }
        let grid = pinGeometry(count: browser.pinCellCount + adding)
        let col = min(max(0, Int(point.x / (grid.width + SideBar.pinGap))), grid.cols - 1)
        let row = max(0, Int((point.y - top) / (grid.height + SideBar.pinGap)))
        return min(row * grid.cols + col, browser.pinCellCount)
    }

    private func belowRows(_ y: CGFloat) -> Bool {
        let end = rowsTop + ColumnLayout.height(page.items) + SideBar.gap + 8
        return y > min(end, page.bounds.height - SideBar.footHeight - 24)
    }

    // MARK: - a tab carried across (SideBar.lift, follow, drop, land)

    /// The pair whose row `tab` heads, when it can be pinned as one: let go
    /// in the pins, it becomes a pinned pair's square (PinPairs.swift).
    private func pinnablePair(_ tab: Tab) -> Pair? {
        guard let browser, tab.pin == nil, let pair = browser.pair(of: tab.id), pair.first == tab.id, browser.canPinPair(pair) else { return nil }
        return pair
    }

    private func lift(_ tab: Tab, toPins: Bool, index: Int, from: CGPoint, size: CGSize, to point: CGPoint, becoming shape: CGSize) {
        unfold()
        level()
        carry = Carry(tab: tab.id, toPins: toPins, index: index)
        // A pair row going up folds into the square it will be, both marks;
        // a pinned pair's square coming down wears both till it unfolds.
        let mate = toPins ? pinnablePair(tab).flatMap { browser?.tab(id: $0.second) } : browser?.pinMate(of: tab)
        page.carried(tab, mate: mate, folded: !toPins, at: from, size: size, landing: false, curve: nil)
        page.refresh(ColumnMotion.settle)
        DispatchQueue.main.async { [weak self] in
            self?.page.carried(tab, mate: mate, folded: toPins, at: point, size: shape, landing: false, curve: ColumnMotion.settle)
        }
    }

    private func follow(to point: CGPoint, index: Int) {
        page.carriedMove(to: point, ColumnMotion.follow)
        if carry?.index != index {
            carry?.index = index
            page.refresh(ColumnMotion.settle)
        }
    }

    private func drop() {
        level()
        carry = nil
        page.carriedGone()
        page.refresh(ColumnMotion.settle)
    }

    private func land(_ tab: Tab, at point: CGPoint, size: CGSize, change: @escaping () -> Void) {
        settling = tab.id
        page.carriedLand(at: point, size: size)
        change()
        carry = nil
        page.refresh(ColumnMotion.settle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.settling == tab.id else { return }
            self.settling = nil
            self.page.carriedGone()
            self.page.redraw(nil)
        }
    }

    // MARK: - carrying several (SideBar.gather, herdMove, herdEnd)

    /// The row's tabs: a pair row's two, first and second, or the one.
    private func withMate(_ tab: Tab) -> [Tab.ID] {
        guard let browser, let pair = browser.pair(of: tab.id), pair.first == tab.id, browser.tab(id: pair.second) != nil else { return [tab.id] }
        return [pair.first, pair.second]
    }

    private func gather(_ ids: [Tab.ID], held tab: Tab, index: Int, at point: CGPoint) {
        guard let browser else { return }
        let middle = rowsTop + slotY(drawnRow(tab, index: index)) + SideBar.row / 2
        let home = looseTabs.prefix(index).filter { !ids.contains($0.id) }.count + (folders.lined && !tab.kept ? Folders.lineRows : 0)
        herdKept = false
        if ids.count > 1 { level() }
        let blank = browser.tabs.filter { ids.contains($0.id) && $0.isBlank }.count
        // A pair row in the hand is drawn as the pair row, not a stack of
        // two, and goes up into the pins as one square (PinPairs.swift).
        let pair = browser.pair(of: tab.id).flatMap { pair in ids == [pair.first, pair.second] ? pair : nil }
        let mate = pair.flatMap { browser.tab(id: $0.second) }
        let pinnable = pair.map { browser.canPinPair($0) ? 1 : 0 } ?? ids.count - blank
        herd = Herd(ids: ids, members: Set(ids), held: tab.id, pinnable: pinnable, home: home, index: home, grip: startAt.y - middle)
        page.stack(tab, mate: mate, count: ids.count, at: CGPoint(x: columnWidth / 2, y: point.y - (startAt.y - middle)))
        page.refresh(ColumnMotion.settle)
    }

    private func herdMove(to point: CGPoint) {
        guard let browser, let herd, !herd.landed else { return }
        page.hand(CGPoint(x: columnWidth / 2, y: point.y - herd.grip), ColumnMotion.follow)
        let line = herd.pinAt == nil ? pinsLine - 6 : top + pinBlock(count: browser.pinCellCount + herd.pinnable) + 4
        if herd.pinnable > 0, point.y < line {
            let held = browser.tabs.first { $0.id == herd.held }
            let at = pinPlace(pinTarget(at: point, adding: herd.pinnable), shared: held.map(Browser.sharable) ?? false)
            if herd.pinAt == nil { level() }
            if at != herd.pinAt {
                if herd.pinAt != nil { tick() }
                self.herd?.pinAt = at
                self.herd?.index = nil
                page.refresh(ColumnMotion.settle)
            }
            return
        }
        if herd.pinAt != nil {
            level()
            self.herd?.pinAt = nil
            page.refresh(ColumnMotion.settle)
        }
        let base = baseCells.filter { cell in ColumnLayout.tab(cell).map { !herd.members.contains($0.id) } ?? true }
        let left = ColumnLayout.rows(base, folders: folders)
        let topY = point.y - herd.grip - SideBar.row / 2
        let row = ColumnLayout.slot(topY - rowsTop, line: ColumnLayout.lineSlot(in: base, folders: folders))
        if let nest = herdFolder(at: row, staying: herd.into) {
            if herd.into != nest.id {
                level()
                self.herd?.into = nest.id
                page.refresh(ColumnMotion.settle)
            }
            return
        }
        if herd.into != nil {
            self.herd?.into = nil
            page.refresh(ColumnMotion.settle)
        }
        let index = min(max(0, Int(row.rounded())), left)
        if index != herd.index {
            tick()
            self.herd?.index = index
            page.refresh(ColumnMotion.settle)
        }
    }

    private func herdFolder(at row: Double, staying: UUID?) -> Nest? {
        guard let browser, let herd else { return nil }
        var at = 0
        var cells = ColumnLayout.cells(browser)
        cells.removeAll { ColumnLayout.tab($0).map { herd.members.contains($0.id) && $0.id != herd.held } ?? false }
        if let index = herd.index { cells.insert(.gap, at: ColumnLayout.position(index, in: cells, skip: herd.held, folders: folders)) }
        for cell in cells {
            if case .empty(let nest) = cell {
                if abs(row - Double(at)) <= (staying == nest.id ? 0.6 : 0.45) { return nest }
            } else if let tab = ColumnLayout.tab(cell), let place = folders.place(of: tab), place.head, !herd.members.contains(tab.id) {
                for (step, key) in place.heads.enumerated() {
                    guard let nest = folders.folder(key)?.nest, !nest.open else { continue }
                    if abs(row - Double(at + step)) <= (staying == nest.id ? 0.6 : 0.45) { return nest }
                }
            }
            if ColumnLayout.tab(cell)?.id == herd.held { continue }
            at += ColumnLayout.rows(cell, folders: folders)
        }
        return nil
    }

    private func herdEnd() {
        guard let browser, let herd else { return }
        dragging = nil
        travel = 0
        target = from
        let group = browser.tabs.filter { herd.members.contains($0.id) }
        if let into = herd.into, let nest = browser.nests.first(where: { $0.id == into }) {
            herdKept = true
            page.stackGoes(into: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                browser.file(group.filter(\.keepable), in: nest)
                self?.herd = nil
                self?.page.stackGone()
                self?.page.refresh(nil)
            }
            return
        }
        if let at = herd.pinAt {
            let spot = pinCenter(at, count: browser.pinCellCount + herd.pinnable)
            herdKept = true
            page.hand(spot, ColumnMotion.settle)
            page.stackGoes(into: false)
            self.herd?.pinAt = nil
            if let pair = browser.pair(of: herd.held), herd.ids == [pair.first, pair.second] {
                browser.pinPair(pair, cell: at)
            } else {
                browser.pin(group, at: at)
            }
            page.refresh(ColumnMotion.settle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.herd = nil
                self?.page.stackGone()
                self?.page.refresh(nil)
            }
            return
        }
        let index = herd.index ?? herd.home
        let others = baseCells.filter { cell in ColumnLayout.tab(cell).map { !herd.members.contains($0.id) } ?? true }
        let spot = ColumnLayout.placing(ColumnLayout.position(index, in: others, folders: folders), in: others)
        var order = looseTabs.filter { !herd.members.contains($0.id) }.map(\.id)
        let at = spot.before.flatMap { before in order.firstIndex(of: before.id) } ?? order.count
        order.insert(contentsOf: herd.ids, at: at)
        self.herd?.landed = true
        for tab in group {
            tab.kept = spot.kept && tab.keepable
            tab.nest = tab.kept ? spot.nest : nil
        }
        browser.arrange(loose: order)
        folders.refresh()
        page.refresh(ColumnMotion.settle)
        // Onto the held row's place as now laid, its line and New tab
        // counted: from the slots alone it landed a row high, over New tab,
        // while the row itself came in under it, two copies for a moment
        // (alpha 2026-10-13, 11.39.15).
        let lands = page.rowMiddle(herd.held.uuidString) ?? rowsTop + ColumnLayout.y(Double(index), line: lineSlot) + SideBar.row / 2
        page.hand(CGPoint(x: columnWidth / 2, y: lands), ColumnMotion.settle)
        page.stackLands()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, self.herd?.landed == true else { return }
            self.herd = nil
            self.page.refresh(nil)
            // The rows fade back in under the stack (0.14 s), then it goes:
            // gone first, the place was dim for a few frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, self.herd == nil else { return }
                self.page.stackGone()
            }
        }
    }

    // MARK: - the bench

    var state: [String: Any] {
        ["dragging": dragging?.uuidString ?? "", "pin": pinDragging?.uuidString ?? "", "target": target, "from": from,
         "travel": Double(travel), "carry": carry.map { "\($0.toPins ? "up" : "down") \($0.index)" } ?? "",
         "herd": herd.map { "\($0.ids.count) at \($0.index ?? -1) pins \($0.pinAt ?? -1)" } ?? "",
         "nest": carrying.map { "\($0.nest.name) \($0.index)" } ?? "", "into": aim?.into?.uuidString ?? "",
         "choice": choice.map { "\($0.side) \($0.revealed) \($0.ready)" } ?? "", "folding": folding?.uuidString ?? "", "combine": combine?.uuidString ?? "", "grip": grip.heard,
         "grip_state": grip.state.rawValue]
    }
}

extension ColumnMotion {
    /// The carried tab and the stack after the hand: a short spring.
    static let follow = Curve.spring(response: 0.16, damping: 0.9)
    static let choiceReveal = Curve.timing(0.33, 1, 0.68, 1, duration: 0.18)
    static let choiceFolder = Curve.timing(0.33, 1, 0.68, 1, duration: 0.24)
}

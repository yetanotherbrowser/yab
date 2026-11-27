import AppKit
import QuartzCore
import SwiftUI

/// One space's part of the AppKit column (ColumnPages): its pins and its
/// name over its rows, the rows in a scroll view of its own, cells only for
/// what is in sight, and a hand on them (ColumnHand).
final class ColumnPage: NSView {
    private weak var browser: Browser?
    /// The rows' width the head's cells were last fitted to (stretchHead).
    private var headWidth: CGFloat = 0
    /// The rows themselves, without the empty room after the last one.
    private var rowsHeight: CGFloat = 1
    let space: UUID
    /// The rows' scroll view in a box of its own, which wears the ends'
    /// mask: AppKit keeps a scroll view's own layer.
    private let box = RowsBox()
    private let scroll = RowsScroll()
    private let document = RowsDocument()
    /// The pins, over the rows, not scrolling with them; the
    /// grid in a view of its own, to stand still while the row of spaces
    /// slides when every space it goes past shows them.
    private let head = HeadView()
    private let pinsView = HeadView()
    /// Separate from the pins so a held row can pass over the name while
    /// the pins keep standing over the scrolling list.
    private let nameView = HeadView()
    private var nameBehindRows = false
    /// What is carried over the rows and pins: a tab between the two lists,
    /// a stack of picked rows (SideBar's `carried`, `herded`).
    private let overlay = ColumnOverlay()
    private(set) var items: [ColumnItem] = []
    private var byID: [String: Int] = [:]
    private(set) var headItems: [ColumnItem] = []
    /// The cells in sight, by their item's id, and those waiting to be
    /// used again, by the kind of row they draw.
    private var cells: [String: ColumnCell] = [:]
    private var heads: [String: ColumnCell] = [:]
    private var pool: [ColumnCell.Kind: [ColumnCell]] = [:]
    private var frame_ = ColumnPages.Frame(lead: 0, footRoom: 0, top: 0, foot: true)
    private var look: ColumnPages.Look?
    private let ends = ColumnEndsLayers()
    private(set) var hand: ColumnHand!
    /// Said where its rows are (DrawnRows), in its own name.
    private let by = UUID()
    /// What was folded open when the rows were last laid, to tell a folder
    /// opening from a tab coming.
    private var openLast: Set<String> = []
    private var countLast = 0
    /// What it last told DrawnRows.
    private var reported: Set<String> = []
    /// The tab in front when the rows were last laid, to bring a new one
    /// into sight.
    private var activeLast: Tab.ID?
    private var started = false

    override var isFlipped: Bool { true }

    /// Out of sight: hidden, or parked far out of the column, drawn and
    /// kept up to date there so that showing it costs nothing.
    var away: Bool { isHidden || frame.minX <= ColumnPages.parked / 2 }

    init(browser: Browser, space: UUID) {
        self.browser = browser
        self.space = space
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        // Its scrolls tell the rows' hosts they moved only once the rows
        // rest (ColumnQuiet).
        scroll.contentView = RowsClip()
        // A new clip view paints controlBackgroundColor until told not to:
        // set after it, or the column is white under the space's color (#133).
        scroll.drawsBackground = false
        ColumnQuiet.install()
        // The rows move together while the foot changes its native inset.
        document.wantsLayer = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        ThreadScroller.put(on: scroll)
        box.wantsLayer = true
        box.addSubview(scroll)
        addSubview(box)
        ends.install(in: self, over: box)
        nameView.wantsLayer = true
        addSubview(nameView)
        head.wantsLayer = true
        pinsView.wantsLayer = true
        head.addSubview(pinsView)
        addSubview(head)
        overlay.wantsLayer = true
        addSubview(overlay)
        hand = ColumnHand(page: self, browser: browser)
        hand.grip.view = self
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        pointerWatch.heard = { [weak self] event in self?.point(event) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: pointerWatch, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - the row the pointer is on

    /// The row the pointer is on, by its item's id: the column's to say, as
    /// Chrome's tab strip says which tab is hot. Each row heard the pointer
    /// for itself, and AppKit tells a view the pointer came or went only as
    /// the pointer moves: a row that slid under a still pointer (the next
    /// tab, after one was closed from its cross) stayed dark with no cross,
    /// and after a wheel's step the row lit was the one the pointer had
    /// been on (register 1239, 6 people). One tracking area over the page,
    /// and the row worked out again from where the pointer is whenever the
    /// pointer moves or the rows are laid, a scroll's step included.
    private(set) var pointedID: String?
    private let pointerWatch = PointerWatch()
    /// Where the pointer was last heard over the page, in the window; nil
    /// once it left. Where it still is after the rows move under it.
    private var pointer: NSPoint?

    /// The pointer heard (`event`), or the rows laid again under it (nil).
    func point(_ event: NSEvent? = nil) {
        // Sliding the column moves its layers, not these native frames or
        // tracking areas. Only an on-screen column can own a row's hover.
        let visible = browser.map { browser in
            browser.prefs.sidebar && browser.column.map { $0.shown && isDescendant(of: $0) } == true
        } == true && !isHiddenOrHasHiddenAncestor
        if !visible { pointer = nil }
        else if let event { pointer = event.type == .mouseExited ? nil : event.locationInWindow }
        var next: String?
        if let window, let browser, let at = pointer, window.isVisible, !away, !hand.holding {
            let inRows = document.convert(at, from: nil)
            if bounds.contains(convert(at, from: nil)), shownRows.contains(inRows),
               let moved = event ?? NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0),
               // Under a pin's or a folder's preview hanging over the rows,
               // none of them is lit (TabGlance.covers).
               !browser.glance.covers(moved) {
                next = cells.first { id, cell in
                    !cell.isHidden && cell.frame.contains(inRows) && byID[id].map { ColumnCell.pointable(items[$0]) } == true
                }?.key
            }
        }
        guard next != pointedID else { return }
        let was = pointedID
        pointedID = next
        // The card of the row left, even one gone from the rows (a tab
        // closed from its cross), put away first.
        if let told = toldGlance {
            toldGlance = nil
            switch told {
            case .tab(let id): browser?.glance.hover(id, false)
            case .folder(let key): browser?.glance.hoverFolder(key, false)
            }
        }
        tellPointed(was, false)
        tellPointed(next, true)
    }

    /// A column put away ends its hover even without a mouse-exit event.
    /// Forget the position too: input over the hidden rows cannot replay
    /// when the column is revealed or its rows are laid again.
    func stopPointing() {
        pointer = nil
        point()
    }

    private enum Told { case tab(Tab.ID), folder(String) }
    /// The row whose card or preview the pointer was last said to be on.
    private var toldGlance: Told?

    /// A row the pointer came to or left: drawn so, and, come to, the tab's
    /// card or the folder's preview told, as the row's own hover told them.
    private func tellPointed(_ id: String?, _ on: Bool) {
        guard let id, let browser, let index = byID[id], let context else { return }
        let item = items[index]
        let hold = hand.drawn(item).hold
        cells[id]?.bind(item, context, hold: hold, force: false)
        guard on else { return }
        switch item.kind {
        case .tab(let tab):
            browser.glance.hover(tab.id, true)
            toldGlance = .tab(tab.id)
        case .nest(let nest, _, _):
            browser.glance.hoverFolder(nest.key, browser.folderBook.naming != nest.id && !hold.lifted)
            toldGlance = .folder(nest.key)
        default: break
        }
    }

    /// Laid as the column stands now: the rows moved, made, rebound or let
    /// go as what they show changed.
    func live(_ next: [ColumnItem], head nextHead: [ColumnItem], frame: ColumnPages.Frame, look: ColumnPages.Look) {
        let afresh = afreshNext
        if afreshNext {
            afreshNext = false
            started = false
            // A page coming or going changes the column's paint, not where
            // the reader left its rows (#1143). A full rebuild still starts
            // at the top; follow() keeps an explicitly chosen row in sight.
            if !keepScrollOnRefresh {
                activeLast = nil
                scroll.contentView.scroll(to: CGPoint(x: 0, y: -frame.lead))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        guard let browser else { return }
        restingActive = browser.newTabLit ? nil : browser.activeID
        // Every cell bound again too, as a new page's are.
        let lookChanged = look != self.look || afresh
        let frameChanged = frame != frame_
        let leadWas = frame_.lead
        // The rows at their end, the last one resting over the foot, as
        // the room under them grows (the player's island coming, #598).
        let clip = scroll.contentView
        let footWas = frame_.footRoom
        let bottomWas = scroll.contentInsets.bottom
        let footChanged = abs(frame.footRoom - footWas) > 0.5
        let offsetWas = clip.bounds.minY
        let drawnFoot: CGFloat
        if footChanged, let layer = document.layer,
           let own = layer.animation(forKey: "column.foot") as? CABasicAnimation {
            if let shown = layer.presentation(), let shownClip = clip.layer?.presentation() {
                // The inset can change twice before CA commits. The
                // document's transform alone then describes the old clip
                // origin, while AppKit already has the hidden end limit.
                // A selected tab's follow() may be moving this clip on its
                // own clock. Its lag belongs to that scroll, not the foot.
                let scrolling = (clip.layer?.animationKeys() ?? []).contains { key in
                    let path = (clip.layer?.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? key
                    return path == "bounds" || path.hasPrefix("bounds.")
                }
                let pending = scrolling ? 0 : clip.bounds.minY - shownClip.bounds.minY
                drawnFoot = shown.transform.m42 - layer.transform.m42 + pending * ColumnCell.down(layer)
            } else {
                // No drawing has committed yet: retain our pending start
                // when a second change replaces it in this transaction.
                drawnFoot = own.fromValue as? CGFloat ?? 0
            }
        } else {
            drawnFoot = 0
        }
        // The space's name going or coming (Hide Space Name), the rows at
        // their top: they glide into its place or under it.
        let named = { (items: [ColumnItem]) in items.contains { if case .name = $0.kind { true } else { false } } }
        let naming = started && !afresh && !hand.holding && named(headItems) != named(nextHead)
        let atTop = clip.bounds.minY <= -leadWas + 0.5
        let endWas = started && frame.footRoom > footWas + 0.5
            && document.frame.height > clip.bounds.height - frame_.lead - bottomWas
            && clip.bounds.maxY - bottomWas >= document.frame.height - 1
        self.look = look
        frame_ = frame
        fit()
        if frameChanged {
            // AppKit excludes its bottom content inset from native hover,
            // even when hitTest forwards clicks to a row drawn there. Keep
            // the scrollable tail in the document, so only the actual foot
            // is outside the rows' interactive viewport.
            scroll.contentInsets = NSEdgeInsets(top: frame.lead, left: 0, bottom: frame.footRoom, right: 0)
            // They stay at it, going up with the foot: the space icons were
            // left over the last tab, under the island (#598).
            if endWas { keepEnd(rising: frame.footRoom - footWas) }
            // AppKit clamps the scroll origin as soon as its bottom inset
            // shrinks. The foot is still descending, so that native snap
            // put the last row through the space icons for a frame (#598).
            // Draw from its old position on the foot's clock instead.
            if started, footChanged {
                followFoot(from: offsetWas, drawn: drawnFoot, rising: frame.footRoom > footWas)
            }
            ends.lay(in: bounds, frame: frame)
            // The rows' lead changed under the hand (the pins opening a
            // row for what it carries up, the last pin brought down): the
            // rows go with the name on its spring, rather than at once
            // while the name glides over them (2026-10-14).
            if hand.holding, started, window != nil, !away, abs(frame.lead - leadWas) > 0.5, let layer = document.layer {
                ColumnMotion.slide(layer, by: (frame.lead - leadWas) * ColumnCell.down(layer), ColumnMotion.settle)
            }
            // The name gone or come: the rows that stood under it stay
            // under the pins, from where they were drawn.
            if naming, atTop, abs(frame.lead - leadWas) > 0.5 {
                clip.scroll(to: CGPoint(x: 0, y: -frame.lead))
                scroll.reflectScrolledClipView(clip)
                if window != nil, !away, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = document.layer {
                    ColumnMotion.slide(layer, by: (frame.lead - leadWas) * ColumnCell.down(layer), ColumnMotion.opening)
                }
            }
        }
        rowsHeight = max(ColumnLayout.height(next), 1)
        let size = CGSize(width: bounds.width, height: rowsHeight + SideBar.rowsTail)
        if document.frame.size != size { document.frame.size = size }

        // How the rows move: a folder opening or shutting on its clock, a
        // tab coming or going on the room's, the rest on the kept's.
        let open = Set(next.compactMap { item -> String? in
            if case .nest(let nest, _, _) = item.kind, nest.open { return nest.key }
            if case .task(let folder, true) = item.kind { return folder.id }
            return nil
        })
        var curve: ColumnMotion.Curve
        let opening = !open.subtracting(openLast).isEmpty, shutting = !openLast.subtracting(open).isEmpty
        let count = browser.tabs.count
        if opening { curve = ColumnMotion.opening } else if shutting { curve = ColumnMotion.shutting } else if count > countLast {
            curve = ColumnMotion.room
        } else if count < countLast { curve = ColumnMotion.leave } else { curve = ColumnMotion.keptShift }
        // Clear's wave: the rows close up behind the dust on its own clock.
        if !browser.dustFolded.isEmpty { curve = .timing(0.65, 0, 0.35, 1, duration: Dust.foldTime) }
        // A folder a ⌘-click made or joined, a tab closed in one: Dia's
        // springs; down to one tab and ungrouped: at once, as Dia's.
        var still = false
        folding = false
        switch ColumnMotion.hinted {
        case .curve(let said)?: curve = said
        case .folder?:
            // A folder made or joined: its new rows fade in where they
            // stand while the rest slide, as Dia's header and link row do.
            curve = ColumnMotion.linkFolder
            folding = true
        case .still?: still = true
        case nil: break
        }
        // An act's own curve: a folder leaving for another space, on Arc's spring.
        if let asked = browser.columnCurve {
            curve = asked
            browser.columnCurve = nil
        }
        let handCurve = pendingCurve
        if let handCurve { curve = handCurve }
        pendingCurve = nil
        // Resizing a column is direct manipulation. Reflowing its pin grid
        // must not add another spring at every width crossed by the hand.
        let animate = started && window != nil && !away && !still && !browser.sideSizing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        started = true
        let openWas = openLast
        openLast = open
        countLast = count
        openingNow = opening
        // Where each row stood, for a row crossing the edge of sight as the
        // rows move (place).
        laidBefore = animate ? Dictionary(items.compactMap { $0.height > 0 ? ($0.id, $0.y) : nil }, uniquingKeysWith: { a, _ in a }) : [:]

        items = next
        byID = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        headItems = nextHead
        // Rows gone: faded and shrunk a little as they leave, as SideRow's
        // removal does, then let go.
        for (id, cell) in cells where byID[id] == nil {
            cells[id] = nil
            if animate, case .tab = cell.kind, !hand.holding {
                cell.leave { [weak self] in
                    cell.removeFromSuperview()
                    self?.recycle(cell)
                }
            } else {
                recycle(cell)
            }
        }
        let arrivesBefore = ColumnPage.arrives, slidesBefore = ColumnPage.slides
        place(animate: animate, curve: curve, rebind: lookChanged)
        nameFades = naming && animate
        placeHead(animate: animate, curve: curve, rebind: lookChanged)
        nameFades = false
        if Store.testing, animate, opening || shutting || ColumnPage.arrives != arrivesBefore || ColumnPage.slides != slidesBefore {
            // What a laying set moving, for the bench: a change of space
            // should set none of it (feedback #249).
            ColumnPage.motions.append("\(space.uuidString.prefix(6)) opening=\(opening) shutting=\(shutting) arrived=\(ColumnPage.arrives - arrivesBefore) slid=\(ColumnPage.slides - slidesBefore) gained=\(open.subtracting(openWas).sorted().map { $0.prefix(12) })")
            if ColumnPage.motions.count > 60 { ColumnPage.motions.removeFirst() }
        }
        // What the hand moved without moving a row's place (the rows making
        // room under pins grown a row) goes on the hand's curve too.
        redraw(animate ? handCurve : nil, held: hand.dragging, pin: hand.pinDragging)
        follow(browser)
        report()
    }

    /// The curve the hand asked the next laying to move on.
    private var pendingCurve: ColumnMotion.Curve?
    /// This laying makes or fills a folder by a ⌘-click (ColumnMotion.linkFolder).
    private var folding = false
    /// This laying opens a folder: its rows come in in turn.
    private var openingNow = false
    /// This laying hides or shows the space's name (`naming` in live).
    private var nameFades = false
    /// Each row's y before this laying, while the rows move.
    private var laidBefore: [String: CGFloat] = [:]
    /// The rows drawn on their way out of sight, let go once they are there.
    private var edgeTurn = 0

    /// The tab you go to is the tab you see: ⌘1 to ⌘9, ⇧⌘], a link opening
    /// beside the one on screen. Come back to with the space, it is there at
    /// once; a held key walks the rows without a glide chasing every step.
    private func follow(_ browser: Browser) {
        reveal(browser)
        let id = browser.activeID
        defer { activeLast = id }
        guard id != activeLast, let id, let index = byID[id.uuidString], !hand.holding else { return }
        // Landed on by closing the tab in front (Browser.close): not a tab
        // you went to, so the rows stay where you are in them. Closing a
        // page opened from the middle of a long folder took the column to
        // its foot, the tab ⌘W goes back to, and the place in the folder
        // was lost (feedback #1916).
        if activeLast != nil, browser.closedOnto == id { return }
        let item = items[index]
        let shown = shownRows
        guard item.y < shown.minY || item.y + item.height > shown.maxY else { return }
        let first = activeLast == nil
        // To the nearer end of what shows, as ScrollViewReader's scrollTo;
        // the first time, in the middle, as SideBar's onAppear has it.
        var y = item.y < shown.minY ? item.y : item.y + item.height - shown.height
        if first { y = item.y + item.height / 2 - shown.height / 2 }
        y = max(0, min(y, rowsHeight - shown.height))
        let origin = CGPoint(x: 0, y: y - frame_.lead)
        let repeated = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        if first || repeated || away || window == nil {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(origin)
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// What of the rows shows clear of the pins and the foot.
    private var shownRows: CGRect {
        let visible = scroll.contentView.bounds
        return CGRect(x: 0, y: visible.minY + frame_.lead, width: visible.width, height: visible.height - frame_.lead - frame_.footRoom)
    }

    /// A tab a link opened behind the one on screen: its row scrolled just
    /// into sight, at the nearer end, at once, as Arc's sidebar is there
    /// within 150 ms (evals/background-tab-scroll/arc.py). Not while your
    /// own scroll is going: the rows stay where you are taking them.
    private func reveal(_ browser: Browser) {
        guard !away, window != nil, let id = browser.revealAsked else { return }
        browser.revealAsked = nil
        guard let index = byID[id.uuidString], !hand.holding, !scroll.ownScrollGoing else { return }
        let item = items[index]
        let shown = shownRows
        guard item.y < shown.minY || item.y + item.height > shown.maxY else { return }
        var y = item.y < shown.minY ? item.y : item.y + item.height - shown.height
        y = max(0, min(y, rowsHeight - shown.height))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y - frame_.lead))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private var context: ColumnCell.Context? {
        guard let browser, let look else { return nil }
        // A space not on screen lights the tab it was left on, as its page
        // beside the one on screen shows it (PagedSpace's `row.active`).
        let onScreen = space == browser.spaceID
        let live = onScreen ? (browser.newTabLit ? nil : browser.activeID) : restingActive
        return ColumnCell.Context(browser: browser, look: look, liveID: live, newTabLit: onScreen ? browser.newTabLit : restingActive == nil,
                                  pointedID: pointedID)
    }

    /// The tab in front in this space's row as it was parked.
    private var restingActive: Tab.ID?

    /// The cells for what is in sight, each where its row stands.
    private func place(animate: Bool, curve: ColumnMotion.Curve, rebind: Bool) {
        guard let context else { return }
        let visible = scroll.contentView.bounds
        // A row's worth past either end, so a scroll of a few points finds
        // its next row made.
        let lo = visible.minY - ColumnLayout.step, hi = visible.maxY + ColumnLayout.step
        let width = rowWidth()
        let heldID = hand.heldRowID
        var wanted = Set<String>()
        var arrived = 0
        func sighted(_ y: CGFloat, _ height: CGFloat) -> Bool { y + height >= lo && y <= hi }
        // A folder's rows coming in all at once take the spread six do, so
        // a folder of thirty opens on the clock of a folder of six (row 1060).
        let arriving = animate && openingNow
            ? items.filter { item in
                guard item.height > 0, item.indent > 0, cells[item.id] == nil, sighted(item.y, item.height), case .tab = item.kind else { return false }
                return true
            }.count
            : 0
        // A row crossing the edge of sight as the rows move is drawn on its
        // way, as in a small folder: one leaving goes out past the edge and
        // is let go there, one coming in comes from past it. At most a
        // sight's height of the way, so the rows a folder of a hundred
        // pushes out or lets in move as those of a small one, not 3,000
        // points in a frame or two (row 1060).
        let edges = animate && !hand.holding
        let span = hi - lo
        var crossing = false
        for item in items where item.height > 0 {
            let frame = CGRect(x: SideBar.margin + item.indent, y: item.y, width: width - item.indent, height: item.height)
            let shows = sighted(item.y, item.height)
            let had = cells[item.id]
            let leaving = edges && !shows && had.map { sighted($0.frame.minY, $0.frame.height) } == true
            // A scroll virtualizes resting slots. The held row is drawn
            // elsewhere, under the pointer: keep its existing owner through
            // the scroll callback, before the hand updates its translation.
            // If it needs a cell afresh, use that translated position too.
            let held = item.id == heldID
            let follows = held && (had != nil || sighted(item.y + hand.drawn(item).shift.height, item.height))
            guard shows || leaving || follows else { continue }
            wanted.insert(item.id)
            if let cell = had {
                let moved = cell.frame.origin != frame.origin
                let before = cell.layer?.position ?? .zero
                var frame = frame
                if leaving {
                    frame.origin.y = cell.frame.minY + max(-span, min(span, item.y - cell.frame.minY))
                    crossing = true
                }
                if cell.frame != frame { cell.frame = frame }
                let drawn = hand.drawn(item)
                cell.bind(item, context, hold: drawn.hold, force: rebind)
                if browser?.sideSizing == true, let layer = cell.layer {
                    for key in layer.animationKeys() ?? [] where key.hasPrefix("column.slide.") {
                        layer.removeAnimation(forKey: key)
                    }
                }
                if moved, animate, let layer = cell.layer {
                    let after = layer.position
                    let (dx, dy) = travelled(cell, layer, from: before, to: after, shift: drawn.shift)
                    ColumnMotion.slide(layer, by: dy, dx: dx, curve)
                    ColumnPage.slides += 1
                }
            } else {
                // The cell that last drew this row, if it's still put by:
                // nothing to make again (a scroll back up).
                let cell = dequeue(ColumnCell.kind(of: item), id: item.id, in: document)
                let again = cell.itemID == item.id
                cell.frame = frame
                cell.bind(item, context, hold: hand.drawn(item).hold, force: !again && !scrolling, scrolled: scrolling)
                cells[item.id] = cell
                if edges, let was = laidBefore[item.id], abs(was - item.y) > 0.5, let layer = cell.layer {
                    // Coming into sight from where it stood past the edge.
                    let from = item.y + max(-span, min(span, was - item.y))
                    ColumnMotion.slide(layer, by: (item.y - from) * ColumnCell.down(layer), curve)
                    ColumnPage.slides += 1
                } else if animate, openingNow {
                    cell.arrive(item, order: arrived, of: arriving)
                    ColumnPage.arrives += 1
                } else if animate, folding {
                    if case .nest = item.kind { cell.fadeIn(late: true) } else { cell.fadeIn(late: false) }
                }
                // The line coming in under the hand: in once the rows have
                // made its room.
                if animate, hand.holding, case .line = item.kind {
                    cell.alphaValue = 0
                    fadeLine(cell, to: 1, true)
                }
                if case .tab = item.kind, item.indent > 0 { arrived += 1 }
            }
        }
        for (id, cell) in cells where !wanted.contains(id) {
            cells[id] = nil
            recycle(cell)
        }
        // The rows moved, came or went under the pointer.
        point()
        if crossing {
            edgeTurn += 1
            let turn = edgeTurn
            DispatchQueue.main.asyncAfter(deadline: .now() + ColumnMotion.duration(curve) + 0.05) { [weak self] in
                guard let self, edgeTurn == turn else { return }
                place(animate: false, curve: ColumnMotion.keptShift, rebind: false)
            }
        }
        if let line = hand.lineComing {
            // The line coming in under a row being kept, the first.
            let item = ColumnItem(id: "line coming", kind: .lineComing, indent: 0, y: CGFloat(line) * ColumnLayout.step, height: SideBar.line)
            let cell = cells[item.id] ?? dequeue(.lineComing, in: document)
            cells[item.id] = cell
            cell.frame = CGRect(x: SideBar.margin, y: item.y, width: width, height: item.height)
            cell.bind(item, context, force: false)
        }
    }

    /// How far a cell moved on screen when the list changed under it: its
    /// place, and the shift the hand had it drawn at, which goes at once
    /// with it (a drop: the rows stepped aside are where they now stand,
    /// the one let go is under the pointer). The shift is put to what it
    /// becomes here, so the glide starts where the row was drawn, not where
    /// its old place was: from there, a row let go jumped back a row and
    /// glided over again (alpha report 2026-10-13, after the first fix).
    private func travelled(_ cell: ColumnCell, _ layer: CALayer, from before: CGPoint, to after: CGPoint, shift: CGSize) -> (CGFloat, CGFloat) {
        let down = ColumnCell.down(layer)
        let was = cell.shift
        cell.move(to: shift, nil)
        return (after.x - before.x + shift.width - was.width, after.y - before.y + (shift.height - was.height) * down)
    }

    /// The pins and the name, where they stand over the rows.
    private func placeHead(animate: Bool, curve: ColumnMotion.Curve, rebind: Bool) {
        guard let context else { return }
        if head.frame != bounds { head.frame = bounds }
        var wanted = Set<String>()
        for item in headItems {
            wanted.insert(item.id)
            let frame = headFrame(item)
            if let cell = heads[item.id] {
                let moved = cell.frame.origin != frame.origin
                let before = cell.layer?.position ?? .zero
                if cell.frame != frame { cell.frame = frame }
                let drawn = hand.drawn(item)
                cell.bind(item, context, hold: drawn.hold, force: rebind)
                if browser?.sideSizing == true, let layer = cell.layer {
                    for key in layer.animationKeys() ?? [] where key.hasPrefix("column.slide.") {
                        layer.removeAnimation(forKey: key)
                    }
                }
                if moved, animate, let layer = cell.layer {
                    let after = layer.position
                    let (dx, dy) = travelled(cell, layer, from: before, to: after, shift: drawn.shift)
                    ColumnMotion.slide(layer, by: dy, dx: dx, ColumnMotion.settle)
                }
            } else {
                let parent: NSView
                switch item.kind {
                case .name, .privateName: parent = nameView
                default: parent = item.isPin || item.kind.isHome ? pinsView : head
                }
                let cell = dequeue(ColumnCell.kind(of: item), in: parent)
                cell.frame = frame
                cell.bind(item, context, hold: hand.drawn(item).hold, force: true)
                heads[item.id] = cell
                // Coming: once the rows under it have made its room, or it
                // shows over the first of them.
                if nameFades, case .name = item.kind, let layer = cell.layer {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = Float(0)
                    fade.toValue = Float(1)
                    fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.08
                    fade.duration = 0.16
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    fade.fillMode = .backwards
                    layer.add(fade, forKey: "column.name.fade")
                }
            }
        }
        for (id, cell) in heads where !wanted.contains(id) {
            heads[id] = nil
            // The name leaving stays where it is: it fades and gives a
            // little toward its mark, quicker than the rows rise into its
            // place, so they never pass over it.
            if nameFades, id.hasPrefix("name "), let layer = cell.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                CATransaction.setCompletionBlock { [weak self] in self?.recycle(cell) }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = Float(1)
                fade.toValue = Float(0)
                // About its left middle (a view's layer hangs from its corner).
                let height = layer.bounds.height
                let smaller = CATransform3DConcat(CATransform3DMakeScale(0.9, 0.9, 1), CATransform3DMakeTranslation(0, height * 0.05, 0))
                let give = CABasicAnimation(keyPath: "transform")
                give.fromValue = NSValue(caTransform3D: layer.transform)
                give.toValue = NSValue(caTransform3D: CATransform3DConcat(smaller, layer.transform))
                for each in [fade, give] {
                    each.duration = 0.09
                    each.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    each.fillMode = .forwards
                    each.isRemovedOnCompletion = false
                }
                layer.add(fade, forKey: "column.name.fade")
                layer.add(give, forKey: "column.name.give")
                CATransaction.commit()
            } else {
                recycle(cell)
            }
        }
        // A pin's home field over its row of the grid.
        for (id, cell) in heads where id.hasPrefix("home ") { pinsView.addSubview(cell, positioned: .above, relativeTo: nil) }
    }

    /// Where a head item stands. The pins' grid is laid out for the width
    /// the column is set to; while the column is still on its way there
    /// (let go past its widest, a double click putting it back) its cells
    /// keep to the width on screen, as the rows do, rather than jumping.
    private func headFrame(_ item: ColumnItem) -> CGRect {
        let set = (browser?.prefs.sideWidth ?? bounds.width) - 2 * SideBar.margin
        let wide = rowWidth()
        // Wider than set only while stretched past its widest and back.
        let scale = item.x != nil && set > 0 && browser?.sideStretching == true ? wide / set : 1
        return CGRect(x: SideBar.margin + (item.x ?? 0) * scale, y: item.y,
                      width: item.width.map { $0 * scale } ?? wide, height: item.height)
    }

    /// The rows' width. While the column's width runs on a curve past its
    /// widest (Browser.sideStretching), the rows take each new width every
    /// other frame: laying out every row at every step was half of what a
    /// frame of the let-go cost, and a frame behind does not show against
    /// an edge moving that quick. Exact again once the curve is over.
    private var rowsWidth: (width: CGFloat, at: CFTimeInterval)?

    private func rowWidth() -> CGFloat {
        let width = bounds.width - 2 * SideBar.margin
        let now = CACurrentMediaTime()
        if let browser, browser.sideStretching, let held = rowsWidth, held.width != width,
           now - max(held.at, browser.sideLetGo) < 0.025 {
            return held.width
        }
        rowsWidth = (width, now)
        return width
    }

    /// The head's cells refit to a width changed under them, with no new
    /// items: only frames, no binding, nothing laid out anew.
    private func stretchHead() {
        guard browser?.sideStretching == true else { headWidth = 0; return }
        let wide = rowWidth()
        guard headWidth != wide else { return }
        headWidth = wide
        for item in headItems {
            guard let cell = heads[item.id] else { continue }
            let frame = headFrame(item)
            if cell.frame != frame { cell.frame = frame }
        }
    }

    private func dequeue(_ kind: ColumnCell.Kind, id: String? = nil, in parent: NSView) -> ColumnCell {
        // The one that drew this row last, else the one put by longest ago:
        // the rows just scrolled out are the likeliest to come back.
        let index = id.flatMap { id in pool[kind]?.lastIndex { $0.itemID == id } } ?? (pool[kind]?.isEmpty == false ? 0 : nil)
        if let index, let cell = pool[kind]?.remove(at: index) {
            cell.isHidden = false
            if cell.superview !== parent { parent.addSubview(cell) }
            return cell
        }
        let cell = ColumnCell(kind: kind)
        parent.addSubview(cell)
        ColumnPage.cellsMade += 1
        return cell
    }

    private func recycle(_ cell: ColumnCell) {
        cell.isHidden = true
        cell.layer?.removeAllAnimations()
        cell.alphaValue = 1
        cell.layer?.opacity = 1
        cell.move(to: .zero, nil)
        cell.lean(ColumnCell.Lean(), nil)
        pool[cell.kind, default: []].append(cell)
    }

    /// Laying rows for a scroll: a row coming into sight takes the cell of
    /// one gone out as it is, its SwiftUI graph updated rather than made.
    private var scrolling = false
    /// The rows were drawn with nothing in the hand on the last scroll.
    private var drewStill = false
    /// Nothing in the hand, for tests.
    var handIsStill: Bool { hand.still }

    @objc private func scrolled() {
        guard let browser, look != nil else { return }
        scrolling = true
        place(animate: false, curve: ColumnMotion.keptShift, rebind: false)
        scrolling = false
        // Nothing in the hand: every row is drawn as laid already, once
        // drawn so after the hand let go (2% of the main thread under the
        // column's scroll at 200 tabs).
        let still = ColumnQuiet.stillHand && hand.still
        if !(still && drewStill) { redraw(nil) }
        drewStill = still
        report()
        // A card over a row is put away as the rows move under the pointer.
        if !away, browser.glance.shown != nil { browser.glance.drop() }
    }

    /// The rows taken up by `rising`, to their end again. Their native
    /// endpoint is set now; followFoot carries the drawing on the foot's
    /// curve, including a reversal while that drawing is still moving.
    private func keepEnd(rising: CGFloat) {
        let clip = scroll.contentView
        var to = clip.bounds
        to.origin.y += rising
        let end = clip.constrainBoundsRect(to).origin
        guard abs(end.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: end)
        scroll.reflectScrolledClipView(clip)
    }

    /// Only the rows' footer compensation owns this key. A new foot
    /// endpoint starts from their actual presentation offset, so a player
    /// returning during its hide neither adds a second motion nor jumps.
    /// The document's position animations (a changing lead) are untouched.
    private func followFoot(from offset: CGFloat, drawn: CGFloat, rising: Bool) {
        guard let layer = document.layer else { return }
        let key = "column.foot"
        let from = drawn + (scroll.contentView.bounds.minY - offset) * ColumnCell.down(layer)
        guard window != nil, !away, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(from) > 0.25 else {
            layer.removeAnimation(forKey: key)
            return
        }
        let curve: ColumnMotion.Curve = rising
            ? .timing(0.2, 0.8, 0.2, 1, duration: 0.3)
            : .timing(0.45, 0, 0.25, 1, duration: Band.sink)
        layer.add(ColumnMotion.animation("transform.translation.y", curve, from: from, to: CGFloat.zero, additive: true),
                  forKey: key)
    }

    private func fit() {
        if box.frame != bounds { box.frame = bounds }
        if scroll.frame != box.bounds { scroll.frame = box.bounds }
        if head.frame != bounds { head.frame = bounds }
        if nameView.frame != bounds { nameView.frame = bounds }
        if pinsView.frame != head.bounds { pinsView.frame = head.bounds }
        if overlay.frame != bounds { overlay.frame = bounds }
    }

    override func layout() {
        super.layout()
        fit()
        ends.lay(in: bounds, frame: frame_)
        stretchHead()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hand.grip.watch(window != nil)
    }

    // MARK: - the rows' asks for the constraints pass

    /// AppKit's carrying of a view's ask for the constraints pass up to the
    /// view over it: a row's stops here (ColumnQuiet.keepsAsks), and the
    /// row answers it in its own layout (ColumnCell). Climbing, every ask
    /// laid out the column's SwiftUI host and the window's (bench
    /// layout-census, 200 tabs, 3.2 s of scrolling: 869 asks of the
    /// window's host, 661 of the column's, job 069bdec1).
    @objc(_informContainerThatSubviewsNeedUpdateConstraints)
    func subviewsAsked() {
        guard ColumnQuiet.keepsAsks, !(ColumnQuiet.climbsWhileScrolling && ColumnQuiet.rowsScrolling) else {
            return ColumnQuiet.climb(self)
        }
        ColumnQuiet.asksKept += 1
        keptAsks = true
    }

    /// An ask was kept since the window's pass last came down here: the
    /// views under the page keep their flags set until it does, and stop
    /// later asks on their way up.
    private var keptAsks = false

    /// The rows begin to scroll (YAB_SMOOTH_ASKS=swipe): the asks kept go
    /// on up once, so the window's pass comes down and clears the way, and
    /// the scroll's own asks climb as AppKit has them.
    func letAsksClimb() {
        guard keptAsks else { return }
        keptAsks = false
        ColumnQuiet.climb(self)
    }

    /// Shown again: a row that asked while put away is laid out to answer.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard ColumnQuiet.keepsAsks else { return }
        func walk(_ view: NSView) {
            if let cell = view as? ColumnCell, cell.needsUpdateConstraints { cell.needsLayout = true }
            view.subviews.forEach(walk)
        }
        walk(self)
    }

    /// To VoiceOver as SideBar reads: the pins, the name, then the rows.
    override func accessibilityChildren() -> [Any]? { [head, nameView, box] }

    /// How far the rows are scrolled under the ends, a fall's worth at most
    /// and in tenths (ColumnScrolled).
    private var depth: ColumnEnds.Depth {
        let visible = scroll.contentView.bounds
        let above = visible.minY + frame_.lead
        let below = rowsHeight + frame_.footRoom - visible.maxY
        func share(_ by: CGFloat, _ fall: CGFloat) -> CGFloat { (min(1, max(0, by / fall)) * 10).rounded() / 10 }
        return ColumnEnds.Depth(above: share(above, ColumnEnds.fall), below: share(below, ColumnEnds.footFall))
    }

    // MARK: - for the hand

    /// How far down the rows are scrolled, from where they rest.
    var offset: CGFloat { scroll.contentView.bounds.minY + frame_.lead }
    /// Where the rows start, the first of them, as far as it is scrolled.
    var rowsTop: CGFloat { frame_.lead - offset }
    /// The space's name over the rows and the gap under it, or the room
    /// that keeps the rows from reading as the grid's next row.
    var nameBlock: CGFloat {
        guard let browser else { return 0 }
        let named = (browser.namesSpaces || browser.windowPurpose == .privateOnly) && !browser.inMail
        return named ? SideBar.row + SideBar.gap : SideBar.unnamedGap(pins: browser.pinnedCount > 0, named: named || browser.inMail)
    }

    /// The row or pin at `point`, in the page's own space.
    func item(at point: NSPoint) -> ColumnItem? {
        // A tall pin grid can reach under the foot. Its reserved room
        // belongs to the footer before any head cell is considered.
        guard point.y < bounds.height - frame_.footRoom else { return nil }
        for item in headItems.reversed() {
            let frame = CGRect(x: SideBar.margin + (item.x ?? 0), y: item.y, width: item.width ?? 0, height: item.height)
            if frame.contains(point) { return item }
        }
        guard point.y >= frame_.lead else { return nil }
        let at = document.convert(point, from: self)
        return items.first { $0.height > 0 && at.y >= $0.y && at.y < $0.y + $0.height + SideBar.gap }
    }

    func cellAt(_ event: NSEvent) -> ColumnCell? {
        let point = convert(event.locationInWindow, from: nil)
        return (Array(heads.values) + Array(cells.values)).first { !$0.isHidden && $0.convert($0.bounds, to: self).contains(point) }
    }

    /// The rows laid again with what the hand has done to them, moving on
    /// `curve`.
    func refresh(_ curve: ColumnMotion.Curve?) {
        pendingCurve = curve
        if let pages = superview as? ColumnPages { pages.sync() }
        pendingCurve = nil
    }

    /// Each row in sight drawn as the hand has it: moved, stepped in,
    /// faded, lifted. `held`, `nest` and `pin`: what follows the hand at
    /// once while the rest move on `curve`; `turning`, SwiftUI's own
    /// animation for a row turning into a folder.
    func redraw(_ curve: ColumnMotion.Curve?, held: Tab.ID? = nil, nest: String? = nil, pin: Tab.ID? = nil, turning: Animation? = nil) {
        guard let context else { return }
        let live = !away && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var rowInFront = false
        for (id, cell) in cells {
            guard let index = byID[id] else { continue }
            let item = items[index]
            let drawn = hand.drawn(item)
            rowInFront = rowInFront || (drawn.front && drawn.opacity > 0)
            let follows = (held.map { item.tab?.id == $0 } ?? false) || (nest.map { item.folderKey == $0 } ?? false)
            cell.bind(item, context, hold: drawn.hold, force: false, animation: turning ?? Motion.settle)
            cell.move(to: drawn.shift, follows || !live ? nil : curve)
            cell.lean(drawn.lean, live ? (curve ?? (follows ? ColumnMotion.settle : nil)) : nil)
            // The window-level hand is the sole drawing. A source fading
            // out for 0.14 s would leave a second row behind the pointer.
            let fading = live && !(ColumnSpaceCarry.of(context.browser)?.hides(item) ?? false)
            if case .line = item.kind { fadeLine(cell, to: drawn.opacity, fading) } else { fade(cell, to: drawn.opacity, fading) }
            if drawn.front { document.addSubview(cell, positioned: .above, relativeTo: nil) }
        }
        // Raising a cell inside its document cannot cross the name's
        // sibling container. Put only the name behind the rows for the
        // drag and its settling motion; its hit target stays in place.
        if nameBehindRows != rowInFront {
            nameBehindRows = rowInFront
            // The blurs also stand above box. Restoring just above box
            // leaves the name behind them after the first drag (#1602).
            addSubview(nameView, positioned: .below, relativeTo: rowInFront ? box : head)
        }
        for (id, cell) in heads {
            guard let item = headItems.first(where: { $0.id == id }) else { continue }
            let drawn = hand.drawn(item)
            let follows = pin.map { item.tab?.id == $0 } ?? false
            cell.bind(item, context, hold: drawn.hold, force: false)
            cell.move(to: drawn.shift, follows || !live ? nil : curve)
            fade(cell, to: drawn.opacity, live && !(ColumnSpaceCarry.of(context.browser)?.hides(item) ?? false))
            if drawn.front { cell.superview?.addSubview(cell, positioned: .above, relativeTo: nil) }
        }
    }

    /// The line over New tab going with the last of today's held up, or
    /// back as it comes down: out before the row stepping into its room
    /// gets there, in once the row leaving its room is out of it, so a row
    /// never passes over the line (the rows take 0.2 s, ColumnMotion.settle).
    private func fadeLine(_ cell: ColumnCell, to opacity: CGFloat, _ live: Bool) {
        guard abs(cell.alphaValue - opacity) > 0.001, let layer = cell.layer else { return }
        guard live else { cell.alphaValue = opacity; return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cell.alphaValue = opacity
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = Float(opacity)
        fade.duration = opacity < 0.5 ? 0.06 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: opacity < 0.5 ? .easeIn : .easeOut)
        if opacity >= 0.5 { fade.beginTime = CACurrentMediaTime() + 0.1 }
        fade.fillMode = .backwards
        layer.add(fade, forKey: "column.line.fade")
    }

    private func fade(_ cell: ColumnCell, to opacity: CGFloat, _ live: Bool) {
        guard abs(cell.alphaValue - opacity) > 0.001 else { return }
        if live {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.animator().alphaValue = opacity
            }
        } else {
            cell.alphaValue = opacity
        }
    }

    /// Where a row stands as laid now, its middle, in the page as the hand
    /// counts (rowsTop and down).
    func rowMiddle(_ id: String) -> CGFloat? {
        guard let index = byID[id] else { return nil }
        return rowsTop + items[index].y + items[index].height / 2
    }

    /// Where a row is laid now, from the top of the rows.
    func laidTop(_ id: String) -> CGFloat? {
        byID[id].map { items[$0].y }
    }

    /// The cell of `id` drawn over the others: the one in the hand.
    func raise(_ id: String) {
        if let cell = cells[id] { document.addSubview(cell, positioned: .above, relativeTo: nil) }
        if let cell = heads[id] { cell.superview?.addSubview(cell, positioned: .above, relativeTo: nil) }
    }

    /// The one let go of glides the last of the way from where the hand
    /// left it, `from` off its place.
    func settle(_ id: String, from: CGSize) {
        guard let cell = cells[id] ?? heads[id], let layer = cell.layer, !away else { return }
        // One glide, from the hand: whatever the laying just set it moving
        // on goes, or the two would add up.
        for key in layer.animationKeys() ?? [] where key.hasPrefix("column.slide.") { layer.removeAnimation(forKey: key) }
        ColumnMotion.slide(layer, by: -from.height * ColumnCell.down(layer), dx: -from.width, ColumnMotion.settle)
    }

    /// The line under the kept on its way in or out under a held row.
    func lineComingChanged() {
        if hand.lineComing == nil, let cell = cells.removeValue(forKey: "line coming") { recycle(cell) }
        place(animate: false, curve: ColumnMotion.keptShift, rebind: false)
    }

    // The carried tab and the stack, drawn over everything (ColumnOverlay).

    func carried(_ tab: Tab, mate: Tab? = nil, folded: Bool, at point: CGPoint, size: CGSize, landing: Bool, curve: ColumnMotion.Curve?) {
        guard let browser, let look else { return }
        overlay.carry(tab, mate: mate, browser: browser, look: look, folded: folded, at: CGPoint(x: point.x + SideBar.margin, y: point.y), size: size,
                      landing: landing, live: tab.id == browser.activeID, curve: curve)
    }

    func carriedMove(to point: CGPoint, _ curve: ColumnMotion.Curve?) {
        overlay.carryMove(to: CGPoint(x: point.x + SideBar.margin, y: point.y), curve)
    }

    func carriedLand(at point: CGPoint, size: CGSize) {
        overlay.carryLand(at: CGPoint(x: point.x + SideBar.margin, y: point.y), size: size)
    }

    func carriedGone() { overlay.carryGone() }

    func stack(_ tab: Tab, mate: Tab? = nil, count: Int, at point: CGPoint) {
        guard let browser, let look else { return }
        overlay.stack(tab, mate: mate, browser: browser, look: look, count: count, width: bounds.width - 2 * SideBar.margin,
                      at: CGPoint(x: point.x + SideBar.margin, y: point.y), live: tab.id == browser.activeID)
    }

    func hand(_ point: CGPoint, _ curve: ColumnMotion.Curve?) {
        overlay.stackMove(to: CGPoint(x: point.x + SideBar.margin, y: point.y), curve)
    }

    func stackGoes(into: Bool) { overlay.stackGoes(into: into) }
    func stackLands() { overlay.stackLands() }
    func stackGone() { overlay.stackGone() }

    // MARK: - where the rows say they are

    /// Where each row in sight stands, in the window's SwiftUI space, for
    /// what hangs from a tab or a folder, Clear's dust and the bench: said
    /// by the rows themselves in SwiftUI (DrawnRow, SideRow's `lay`), by the
    /// page here, from its layout, whenever it lays out or scrolls.
    /// The column moved in the window with nothing in it laid again: out
    /// over the page from past the edge, or back. Its rows are said where
    /// they stand now; said from past the edge, a row's card hung off the
    /// window's left edge, over the rows (0.0.23).
    func moved() { report() }

    /// What of the rows is in sight, between the head and the foot, in the
    /// page's own space.
    var rowsClip: CGRect {
        CGRect(x: 0, y: frame_.lead, width: bounds.width, height: max(0, bounds.height - frame_.lead - frame_.footRoom))
    }

    private func report() {
        guard let browser, !away, window != nil, let ground = browser.keySky.groundView else {
            ends.depth(depth, grain: look?.grain ?? 0, tone: look?.tone != nil)
            return
        }
        let sky = browser.keySky
        let origin = sky.ground
        var said = Set<String>()
        func put(_ key: String, _ rect: CGRect) {
            browser.drawnRows.put(key, rect, by: by)
            said.insert(key)
        }
        for (id, cell) in cells where !cell.isHidden {
            guard let index = byID[id] else { continue }
            let item = items[index]
            let rect = KeySky.carry(cell.bounds, from: cell, to: ground, ground: origin)
            switch item.kind {
            case .tab(let tab):
                sky.lay(tab.id, rect)
                put(DrawnRows.tab(tab.id), rect)
                let mark = CGRect(x: SideBar.inner, y: (cell.bounds.height - SideBar.mark) / 2, width: SideBar.mark, height: SideBar.mark)
                sky.marks[tab.id] = KeySky.carry(mark, from: cell, to: ground, ground: origin)
                sky.markers[tab.id] = by
            case .pair(let first, let second):
                // The resting chips' frames, concentric with PairRow.
                let inset = PairRow.inset
                let half = (cell.bounds.width - 2 * inset - SideBar.gap) / 2
                let left = CGRect(x: inset, y: inset, width: half, height: cell.bounds.height - 2 * inset)
                sky.lay(first.id, KeySky.carry(left, from: cell, to: ground, ground: origin))
                sky.lay(second.id, KeySky.carry(left.offsetBy(dx: half + SideBar.gap, dy: 0), from: cell, to: ground, ground: origin))
                put(DrawnRows.tab(first.id), rect)
                put(DrawnRows.tab(second.id), rect)
            case .nest(let nest, _, _):
                if !sky.across() { browser.glance.folderFrames[nest.key] = rect }
                put(DrawnRows.folder(nest.key), rect)
            case .task(let folder, _):
                if !sky.across() { browser.glance.folderFrames[folder.id] = rect }
                put(DrawnRows.folder(folder.id), rect)
            case .more(let folder, _):
                put(DrawnRows.more(folder), rect)
            case .line:
                browser.keptLine = rect
            default:
                break
            }
        }
        for (_, cell) in heads where !cell.isHidden {
            guard let item = headItems.first(where: { $0.id == cell.itemID }), case .pin(let tab) = item.kind else { continue }
            let rect = KeySky.carry(cell.bounds, from: cell, to: ground, ground: origin)
            sky.lay(tab.id, rect)
            let side = min(16, min(rect.width, rect.height) * 16 / 34)
            sky.marks[tab.id] = KeySky.carry(CGRect(x: (cell.bounds.width - side) / 2, y: (cell.bounds.height - side) / 2, width: side, height: side),
                                             from: cell, to: ground, ground: origin)
            sky.markers[tab.id] = by
        }
        // Rows gone out of sight take back their word, as DrawnRow's do.
        for key in reported.subtracting(said) { browser.drawnRows.take(key, by: by) }
        reported = said
        if !items.contains(where: { if case .line = $0.kind { return $0.height > 0 } else { return false } }) { browser.keptLine = nil }
        // What of the rows is in sight, for Clear's dust.
        browser.rowsClip = KeySky.carry(rowsClip, from: self, to: ground, ground: origin)
        ends.depth(depth, grain: look?.grain ?? 0, tone: look?.tone != nil)
    }

    // MARK: - beside the one on screen

    /// Laid from a space's parked row, for the row of spaces to slide past:
    /// nothing animated, nothing said to the window about where its rows
    /// are, scrolled to the top.
    /// What it was last laid from while away (ColumnPages.laidKey).
    var laidKey: String?

    func still(_ next: [ColumnItem], head nextHead: [ColumnItem], frame: ColumnPages.Frame, look: ColumnPages.Look, top: Bool = true,
               active: Tab.ID? = nil) {
        restingActive = active
        self.look = look
        frame_ = frame
        fit()
        scroll.contentInsets = NSEdgeInsets(top: frame.lead, left: 0, bottom: frame.footRoom, right: 0)
        ends.lay(in: bounds, frame: frame)
        rowsHeight = max(ColumnLayout.height(next), 1)
        let size = CGSize(width: bounds.width, height: rowsHeight + SideBar.rowsTail)
        if document.frame.size != size { document.frame.size = size }
        items = next
        byID = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        headItems = nextHead
        for (id, cell) in cells where byID[id] == nil {
            cells[id] = nil
            recycle(cell)
        }
        if top {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: -frame.lead))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // A page laid again from its row, as each one beside the space on
        // screen is after every change of space, hands SwiftUI only the
        // cells whose look changed: each cell's row watches its own tab.
        // Every cell handed over again was 60 to 95 ms of the main thread
        // laying out its host 0.4 s after a switch landed (feedback #120).
        place(animate: false, curve: ColumnMotion.keptShift, rebind: top)
        placeHead(animate: false, curve: ColumnMotion.keptShift, rebind: top)
        ends.depth(depth, grain: look.grain, tone: look.tone != nil)
        layoutSubtreeIfNeeded()
    }

    /// Whether a page laid before no longer shows what `next` would.
    func stale(_ next: [ColumnItem], head nextHead: [ColumnItem]) -> Bool {
        guard next.count == items.count, nextHead.count == headItems.count else { return true }
        return zip(next, items).contains { !$0.same($1) || $0.y != $1.y } || zip(nextHead, headItems).contains { !$0.same($1) || $0.y != $1.y }
    }

    var topDepth: CGFloat { max(0, depth.above) }

    func holdTop(_ strength: CGFloat?, eased: Bool = false) {
        ends.hold(strength, eased: eased)
    }

    /// The pins hidden, or carried `offset` across: standing still while
    /// the row of spaces moves the page under them. `from`: where the row
    /// was, to land the pins against it on the same spring.
    /// The pins' landing springs stopped where they are drawn.
    func stopPins() {
        guard let layer = pinsView.layer else { return }
        let drawn = layer.presentation()?.transform ?? layer.transform
        for key in layer.animationKeys() ?? [] where key.hasPrefix("pager.") { layer.removeAnimation(forKey: key) }
        layer.transform = drawn
    }

    func headPins(hidden: Bool, offset: CGFloat, from: CGFloat?, velocity: CGFloat) {
        guard let layer = pinsView.layer else { return }
        if pinsView.isHidden != hidden { pinsView.isHidden = hidden }
        layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        if let from, abs(from - offset) > 0.25 {
            let delta = from - offset
            let spring = SpacePaging.animation(keyPath: "transform.translation.x", from: delta, to: 0, velocity: -velocity / delta)
            spring.isAdditive = true
            layer.add(spring, forKey: "pager.\(UUID().uuidString)")
        }
        if offset == 0, from == nil {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("pager.") { layer.removeAnimation(forKey: key) }
        }
    }

    // MARK: - the bench

    static var cellsMade = 0
    /// Rows a laying brought in in turn (ColumnCell.arrive) or slid, and
    /// the layings that moved anything, for the bench.
    static var arrives = 0
    static var slides = 0
    static var motions: [String] = []
    /// Times a page was shown afresh (showAfresh), for the bench.
    static var afresh = 0

    /// What the page shows and how, for the bench.
    var state: [String: Any] {
        let order = subviews
        return ["space": space.uuidString, "items": items.count, "lead": Double(frame_.lead),
         "laid": items.prefix(8).map { [$0.id, Double($0.y), Double($0.indent)] as [Any] }, "headLaid": headItems.map { [$0.id, Double($0.y), Double($0.x ?? 0), Double($0.width ?? 0)] as [Any] }, "cells": cells.count, "heads": heads.count,
         "pooled": pool.values.map(\.count).reduce(0, +), "offset": Double(offset), "height": Double(rowsHeight),
         "hidden": away, "lit": (Array(cells) + Array(heads)).filter { $0.value.current?.live == true }.map(\.key).sorted(), "binds": (Array(cells.values) + Array(heads.values)).map(\.binds).reduce(0, +), "hand": hand.state,
         "held": heldDrawn.map(Self.values) ?? [], "lifted": lifted, "overlay": overlay.inHand.mapValues(Self.values),
         "tops": onScreen.compactMapValues { $0["y"] },
         "newTab": cells.first { byID[$0.key].map { if case .newTab = items[$0].kind { true } else { false } } ?? false }
            .flatMap { drawnRect($0.value) }.map(Self.values) ?? [],
         "name": headItems.first { if case .name = $0.kind { true } else { false } }.flatMap { heads[$0.id] }.flatMap(drawnRect).map(Self.values) ?? [],
         "nameAboveBlur": order.firstIndex(where: { $0 === nameView }).map { name in
             order.enumerated().allSatisfy { index, view in type(of: view) != EdgeBlurView.self || index < name }
         } ?? false,
         "geometry": geometry]
    }

    /// The rows' views as AppKit lays them, for the bench: a press reaches
    /// a row only inside every one of these frames.
    private var geometry: [String: [Double]] {
        let clip = scroll.contentView
        return ["page": Self.values(frame), "box": Self.values(box.frame), "scroll": Self.values(scroll.frame),
                "clip": Self.values(clip.frame), "clipBounds": Self.values(clip.bounds), "document": Self.values(document.frame),
                "scroller": Self.values(scroll.verticalScroller?.frame ?? .zero),
                "insets": [scroll.contentInsets.top, scroll.contentInsets.bottom, clip.contentInsets.top, clip.contentInsets.bottom].map(Double.init)]
    }

    private static func values(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    /// Where the row in the hand is drawn, its shift included, in the
    /// window from its top-left as `drag` takes points: the layers' own
    /// say, so a shift drawn the wrong way shows.
    private var heldDrawn: CGRect? {
        guard let id = hand.dragging?.uuidString, let cell = cells[id] else { return nil }
        return drawnRect(cell)
    }

    /// Each row, folder or pin the hand holds up over the others, where
    /// it is drawn: a pin in the hand, a folder carried whole.
    private var lifted: [[String: Any]] {
        let all = cells.map { ($0.key, $0.value, false) } + heads.map { ($0.key, $0.value, true) }
        return all.compactMap { id, cell, head -> [String: Any]? in
            guard let item = head ? headItems.first(where: { $0.id == id }) : byID[id].map({ items[$0] }) else { return nil }
            let drawn = hand.drawn(item)
            guard drawn.front, drawn.opacity > 0, let rect = drawnRect(cell) else { return nil }
            return ["id": id, "pin": head, "frame": Self.values(rect)]
        }
    }

    /// Where each tab's row is on screen this moment, as the render server
    /// has it mid-glide (presentation layers), in the window from its
    /// top-left: its top, and its title. For the bench, many times a
    /// second through a drag and its let-go.
    var onScreen: [String: [String: Any]] {
        guard window != nil else { return [:] }
        var out: [String: [String: Any]] = [:]
        // The pins, the name and New tab too, by their own ids ("pin …",
        // "name …", "new-tab"), with where they start across and how wide.
        let all = cells.compactMap { id, cell in byID[id].map { (id, cell, items[$0]) } }
            + heads.compactMap { id, cell in headItems.first { $0.id == id }.map { (id, cell, $0) } }
        for (id, cell, item) in all {
            guard let layer = cell.layer else { continue }
            var root = layer
            while let above = root.superlayer { root = above }
            // Each layer up the chain as it is drawn now.
            func now(_ l: CALayer) -> CALayer { l.presentation() ?? l }
            var rect = now(layer).bounds
            var at: CALayer? = layer
            while let each = at, let parent = each.superlayer {
                rect = now(each).convert(rect, to: now(parent))
                at = parent
            }
            out[item.tab.map { item.isPin ? id : $0.id.uuidString } ?? id] = [
                "title": item.tab?.label ?? id, "y": Double(root.bounds.height - rect.maxY), "h": Double(rect.height),
                "x": Double(rect.minX), "w": Double(rect.width), "alpha": Double(now(layer).opacity), "held": item.tab.map { hand.dragging == $0.id } ?? false]
        }
        // What the overlay carries, where its middle is drawn.
        for (key, at) in overlay.inHand {
            out["overlay " + key] = ["title": "overlay " + key, "y": Double(at.minY), "h": 0.0, "x": Double(at.minX), "w": 0.0, "alpha": 1.0, "held": false]
        }
        return out
    }

    /// A cell as its layers draw it, in the window from its top-left.
    private func drawnRect(_ cell: NSView) -> CGRect? {
        guard let layer = cell.layer, window != nil else { return nil }
        // The topmost layer, the window's whole, whose own space nothing
        // above turns over: y up.
        var root = layer
        while let above = root.superlayer { root = above }
        let r = layer.convert(layer.bounds, to: root)
        return CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// Laid next as a page made now is: from the top, the tab in front
    /// brought into sight as the first time, nothing animated. When the tab
    /// in front comes or goes (a pair staged or parted, a new space), Worn
    /// made the whole column anew and its pages with it; the column now
    /// stays (SteadyWorn), and shows what a new one would have. A paint-only
    /// refresh retains the viewport and normal selected-row following.
    func showAfresh(preservingScroll: Bool = false) {
        ColumnPage.afresh += 1
        // Several model changes may share a laying. An explicit full reset
        // in that turn must still win over a paint-only refresh.
        keepScrollOnRefresh = afreshNext ? keepScrollOnRefresh && preservingScroll : preservingScroll
        afreshNext = true
    }
    /// The next laying is as a new page's (showAfresh).
    private var afreshNext = false
    private var keepScrollOnRefresh = false

    /// Scrolled to `y` points down the rows, at once.
    func scroll(to y: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y - frame_.lead))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The clear rows, in the page's coordinates, where a held row scrolls.
    var dragScrollRoom: CGRect {
        CGRect(x: SideBar.margin, y: frame_.lead, width: max(0, bounds.width - 2 * SideBar.margin),
               height: max(0, bounds.height - frame_.lead - frame_.footRoom))
    }

    /// Let AppKit constrain either end; never bounce while holding a row.
    @discardableResult
    func scrollHeldRows(by delta: CGFloat) -> CGFloat {
        let clip = scroll.contentView
        let before = clip.bounds.minY
        var next = clip.bounds
        next.origin.y += delta
        let origin = clip.constrainBoundsRect(next).origin
        guard abs(origin.y - before) > 0.001 else { return 0 }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return clip.bounds.minY - before
    }

    /// The scroll view, for the bench to drive.
    var scrollView: NSScrollView { scroll }

    /// Whether a scroll at `point` (the page's own) is the rows': anywhere
    /// from the top down to the foot's room, the empty tail under the last
    /// row of a list scrolled to its end included (registers 1444, 1453).
    func holdsScroll(_ point: CGPoint) -> Bool {
        point.y >= 0 && point.y < bounds.height - frame_.footRoom
    }

    /// Whether `point` (the page's own) is over a pin, the name or a row,
    /// rather than the room under the last row the window is dragged by.
    func holds(_ point: CGPoint) -> Bool {
        guard point.y < bounds.height - frame_.footRoom else { return false }
        // The scroller runs the rows' whole height, over the tail under the
        // last row too, where a scrolled list's knob stands: that is the
        // scroller's to take, not the room the window is dragged by.
        if let scroller = scroll.verticalScroller, !scroller.isHidden, scroller.alphaValue > 0.01,
           convert(scroller.bounds, from: scroller).contains(point) {
            return true
        }
        if headItems.contains(where: { CGRect(x: SideBar.margin + ($0.x ?? 0), y: $0.y, width: $0.width ?? 0, height: $0.height).contains(point) }) {
            return true
        }
        guard point.y >= frame_.lead else { return false }
        return document.convert(point, from: self).y <= rowsHeight + SideBar.gap
    }

    /// The blank room actually visible after the rows, including the tail
    /// revealed by scrolling. It is the Space menu's, not a row, scroller,
    /// header or the foot. The unscrolled row count cannot locate it.
    func spaceMenuTail(_ point: CGPoint) -> Bool {
        guard bounds.contains(point), point.y >= frame_.lead,
              point.y < bounds.height - frame_.footRoom, !holds(point) else { return false }
        return document.convert(point, from: self).y > rowsHeight + SideBar.gap
    }
}

/// The rows' document: flipped, the rows from its top.
private final class RowsDocument: NSView {
    override var isFlipped: Bool { true }
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    /// To VoiceOver the rows in their order down the column, the cells kept
    /// for later and the one in the hand's way left out: cells are used
    /// again, so their order among the subviews is no order at all.
    override func accessibilityChildren() -> [Any]? {
        subviews.filter { !$0.isHidden && $0.alphaValue > 0.01 }.sorted { $0.frame.minY < $1.frame.minY }
    }

}

/// The rows' scroll view, on the main thread: AppKit's responsive
/// scrolling takes a trackpad's phased scroll off the main thread for a
/// scroll view that allows it, and the rows of 500 tabs never moved under the
/// bench's two fingers while a mouse's wheel moved them; SwiftUI's own
/// scroll view, SideBar's, doesn't allow it either. The rows are cells laid
/// as they come into sight, which needs the main thread anyway.
private final class RowsScroll: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    /// Scrolls heard, by phase, for the bench.
    static var heard: [String: Int] = [:]

    /// When your own scroll last moved the rows, its glide too.
    private var wheeled: TimeInterval = -.infinity

    /// Your own scroll of the rows going on, or just let go of.
    var ownScrollGoing: Bool { ProcessInfo.processInfo.systemUptime - wheeled < 0.5 }

    /// A press on a row drawn over the bottom inset (the foot's room and
    /// the tail under the last row, 178 points over the window's bottom)
    /// reaches the row. AppKit's own hit test kept that band to the scroll
    /// view itself, so the Today rows a folder opening pushed down into it
    /// lit and dragged but took no click (register #1066). The column's
    /// pages already keep the foot's own room from the rows (holds).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let document = documentView else { return hit }
        let clip = contentView
        guard clip.frame.contains(convert(point, from: superview)) else { return hit }
        guard let row = document.hitTest(clip.convert(point, from: superview)), row !== document else { return hit }
        return row
    }

    override func scrollWheel(with event: NSEvent) {
        RowsScroll.heard["\(event.phase.rawValue)/\(event.momentumPhase.rawValue)", default: 0] += 1
        // A wheel's line sideways is the row of spaces' (SpaceWheel): the
        // column's catch has it, and every local monitor hears an event
        // whether another took it or not, so it comes here too. Taken, it
        // held the wheel's latch on the rows and the next notch went
        // straight to them (#282).
        if event.phase == [], event.momentumPhase == [], SpaceWheel.across(SpaceWheel.Move(event)) != nil { return }
        wheeled = ProcessInfo.processInfo.systemUptime
        ColumnQuiet.heard(event)
        // Two fingers going up or down the rows: the rest of the gesture,
        // its glide too, comes straight here (ScrollLatch). Each of its
        // moves was otherwise looked for from the window's frame down,
        // through SwiftUI's hit test of the window's host and of the row
        // under the pointer, about a sixth of the main thread's time while
        // the rows scrolled. Only once it is plainly up or down: a sideways
        // one is the row of spaces' (Spaces.heard), which decides on its
        // first moves too.
        if event.phase == .changed, event.momentumPhase == [],
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            ScrollLatch.hold(self)
        }
        WheelLatch.hold(self, event, upDownOnly: true)
        super.scrollWheel(with: event)
    }
}

/// The scrolls the rows' scroll views heard, for the bench.
var columnScrollsHeard: [String: Int] { RowsScroll.heard }

/// What the rows' scroll view stands in.
private final class RowsBox: NSView {
    override var isFlipped: Bool { true }
}

/// The pins and the name: only their cells take the pointer.
final class HeadView: NSView {
    private var testingHit = false
    override var isFlipped: Bool { true }

    /// The pins row by row, then the name, as they stand.
    override func accessibilityChildren() -> [Any]? {
        subviews.flatMap { $0 is HeadView ? $0.subviews : [$0] }
            .filter { !$0.isHidden && $0.alphaValue > 0.01 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI's responder-based hit test can route back through this
        // container (macOS 27.2, #960/#961). End that synchronous cycle;
        // later independent hit tests must still reach the cells.
        guard !testingHit else { return nil }
        testingHit = true
        defer { testingHit = false }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// What is carried over the rows and pins: SideBar's `carried` (a tab
/// changing shape between a row and a pin) and `herded` (picked rows as one
/// stack), each in a SwiftUI host of its own, moved by SwiftUI's springs as
/// SideBar moved them. Takes no clicks.
final class ColumnOverlay: NSView {
    private var carryHost: NSHostingView<AnyView>?
    private var stackHost: NSHostingView<AnyView>?
    private var carry: (tab: Tab, mate: Tab?, browser: Browser, look: ColumnPages.Look, folded: Bool, at: CGPoint, size: CGSize, landing: Bool, live: Bool)?
    private var stack: (tab: Tab, mate: Tab?, browser: Browser, look: ColumnPages.Look, count: Int, width: CGFloat, at: CGPoint, live: Bool, landing: Bool, kept: Bool)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func host() -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        return host
    }

    private func toned<V: View>(_ view: V, _ look: ColumnPages.Look) -> AnyView {
        AnyView(view
            .environment(\.columnHosted, true)
            .environment(\.tabTitleSize, look.titleSize)
            .environment(\.colorScheme, look.scheme)
            .toned(look.tone)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    private func drawCarry(_ animation: Animation?) {
        guard let carry else {
            carryHost?.rootView = AnyView(EmptyView())
            return
        }
        let host = carryHost ?? host()
        carryHost = host
        let view = toned(Carried(tab: carry.tab, mate: carry.mate, prefs: carry.browser.prefs, folded: carry.folded, size: carry.size, landing: carry.landing,
                                 live: carry.live).position(carry.at), carry.look)
        if let animation { withAnimation(animation) { host.rootView = view } } else { host.rootView = view }
    }

    func carry(_ tab: Tab, mate: Tab? = nil, browser: Browser, look: ColumnPages.Look, folded: Bool, at: CGPoint, size: CGSize, landing: Bool, live: Bool, curve: ColumnMotion.Curve?) {
        carry = (tab, mate, browser, look, folded, at, size, landing, live)
        drawCarry(curve?.animation)
    }

    func carryMove(to point: CGPoint, _ curve: ColumnMotion.Curve?) {
        carry?.at = point
        drawCarry(curve?.animation)
    }

    func carryLand(at point: CGPoint, size: CGSize) {
        carry?.at = point
        carry?.size = size
        carry?.landing = true
        drawCarry(Motion.settle)
    }

    func carryGone() {
        carry = nil
        drawCarry(nil)
    }

    private func drawStack(_ animation: Animation?) {
        guard let stack else {
            stackHost?.rootView = AnyView(EmptyView())
            return
        }
        let host = stackHost ?? host()
        stackHost = host
        let view = toned(Stack(tab: stack.tab, mate: stack.mate, browser: stack.browser, prefs: stack.browser.prefs, count: stack.count, width: stack.width, landing: stack.landing || stack.kept,
                               live: stack.live)
            .scaleEffect(stack.kept ? 0.6 : 1)
            .opacity(stack.kept ? 0 : 1)
            .position(stack.at), stack.look)
        if let animation { withAnimation(animation) { host.rootView = view } } else { host.rootView = view }
    }

    func stack(_ tab: Tab, mate: Tab? = nil, browser: Browser, look: ColumnPages.Look, count: Int, width: CGFloat, at: CGPoint, live: Bool) {
        stack = (tab, mate, browser, look, count, width, at, live, false, false)
        drawStack(nil)
    }

    func stackMove(to point: CGPoint, _ curve: ColumnMotion.Curve?) {
        stack?.at = point
        drawStack(curve?.animation)
    }

    func stackGoes(into: Bool) {
        stack?.kept = into
        stack?.landing = true
        drawStack(Motion.settle)
    }

    func stackLands() {
        stack?.landing = true
        drawStack(Motion.settle)
    }

    func stackGone() {
        stack = nil
        drawStack(nil)
    }

    /// Where the carried tab and the stack of several stand, for the
    /// bench: in the window from its top-left, a point's empty rect.
    var inHand: [String: CGRect] {
        guard let window, let content = window.contentView else { return [:] }
        func place(_ at: CGPoint) -> CGRect {
            let p = convert(at, to: nil)
            return CGRect(x: p.x, y: content.bounds.height - p.y, width: 0, height: 0)
        }
        var out: [String: CGRect] = [:]
        if let carry, !carry.landing { out["carried"] = place(carry.at) }
        if let stack, !stack.landing { out["stack"] = place(stack.at) }
        return out
    }
}

extension ColumnMotion.Curve {
    /// The same in SwiftUI's words.
    var animation: Animation {
        switch self {
        case .spring(let response, let damping): return .spring(response: response, dampingFraction: damping)
        case .timing(let a, let b, let c, let d, let duration): return .timingCurve(Double(a), Double(b), Double(c), Double(d), duration: duration)
        }
    }
}

/// The column page's pointer, heard through its own tracking area rather
/// than the responder chain the rows' hosts pass their moves up
/// (ColumnPage.point).
private final class PointerWatch: NSResponder {
    var heard: (NSEvent) -> Void = { _ in }
    override func mouseMoved(with event: NSEvent) { heard(event) }
    override func mouseEntered(with event: NSEvent) { heard(event) }
    override func mouseExited(with event: NSEvent) { heard(event) }
}

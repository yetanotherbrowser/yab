import AppKit
import SwiftUI
import WebKit

// A tab carried out of the column or the row over the pages, to be put
// beside the page there, or in place of one half of a pair, or, one of the
// pair itself, in the other half's place.
//
// One object the whole way (papers/family-values-motion, P3 and P4): the
// row under the hand is lifted as itself, and over the pages it becomes a
// card of its own page, which is what lands as the half. The page it is
// carried over makes room for it rather than a tint coming over it: held,
// cut to the half it will keep and carried there. Where it would land is
// outlined at once, and that outline is the one the half in front wears
// once it has landed. A half the tab takes the place of is dimmed while the
// hand is over it and, let go, flies back into its own row, where it now
// lives, a tab again; let go over nothing, the card goes back into its row
// the way it came. Only geometry moves, never for more than 0.3 s, exits
// quicker than entrances.
//
// And none of it is SwiftUI's. The hand moves the mouse a hundred times a
// second: each move sets one layer's position in a transaction without
// actions and tests the pointer against rectangles taken when the tab came
// out. Everything else is started when the part of the pages under the hand
// changes, a few times a drag, and runs in the render server: the card's
// shape, the zone, the page's mask and carry (StageView.preview), the
// paper's outline (PaperView.preview). Room made beside a lone page is
// the one exception: the window is laid out there at once, the page in
// front in the half it keeps with the band it will have, drawn there by
// Core Animation and given its width on the way (Browser.previewSplit),
// so the page reads at its new width before the tab is let go, and
// letting go only puts the tab in the room already shown. The card's picture is the one
// TabGlance keeps of a tab left behind, cut off the main thread; the
// picture of a half going back to its row is taken as the hand reaches it,
// WebKit painting it in the page's process.

@MainActor
final class SplitDeck {
    static let shared = SplitDeck()

    /// What letting go over a part of the pages does.
    enum Drop: Equatable {
        /// Beside the page on screen, on this side of it.
        case beside(Side)
        /// In place of this half of the pair on screen.
        case instead(Tab.ID)
        /// The two halves change places: the tab is one of them.
        case swap
        /// Over the middle of a lone page: the tab opens in its place.
        case open
        /// Over the chat's column: the tab is given to the chat.
        case chat
    }

    /// One part of the pages the tab can be let go over: where the hand has
    /// to be, the card it would make there, and where the page on screen
    /// goes to make that room.
    private struct Target {
        let over: CGRect
        let card: CGRect
        let drop: Drop
        /// Beside a lone page: the half that page keeps.
        var keeps: CGRect?
    }

    /// The curves (Motion's, for Core Animation): room made and a card
    /// shaped on the arrive curve; given back quicker; a landing, a flight
    /// and a change of places on the reshape curve.
    @MainActor private enum Beat {
        static let arrive = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        static var lift: CFTimeInterval { 0.22 * slow }
        /// The page's own curves for the room (Reshape.Pace.room, unroom),
        /// so the empty half opens as the page's edge leaves it.
        static var room: CFTimeInterval { Reshape.Pace.room.duration * slow }
        static var back: CFTimeInterval { Reshape.Pace.unroom.duration * slow }
        static var home: CFTimeInterval { 0.18 * slow }
        static var land: CFTimeInterval { 0.30 * slow }
        static var fly: CFTimeInterval { 0.30 * slow }
        static var dim: CFTimeInterval { 0.12 * slow }
        /// A state shown, not moved: the outline and the dimming (P6).
        static var state: CFTimeInterval { 0.04 * slow }
    }

    /// Every beat drawn this many times slower, for looking at the frames
    /// in a test world (`bench split act=slow`).
    static var slow: CFTimeInterval = 1

    /// The card over the pages: its size, the band its title sits in, and
    /// where the hand holds it.
    private enum Card {
        static let size = CGSize(width: 160, height: 106)
        static let band: CGFloat = 26
        static let grip = CGPoint(x: 26, y: 13)
    }

    private(set) var tab: Tab?
    private weak var browser: Browser?
    private var sky: Sky?
    private var targets: [Target] = []
    private var aim: Int?
    /// Where the tab stood in its list, in the window from its top left.
    private var home: CGRect = .zero
    /// The row's title type, as the row wrote it.
    private var titleFont = NSFont.systemFont(ofSize: 12.5)
    private var titleLine: CGFloat { ceil(titleFont.ascender - titleFont.descender) }
    /// Where the pill is held, from the pointer.
    private var grip: CGPoint = .zero
    private var overPages = false
    /// The room and the tab in front when the tab came out: either
    /// changing under the hand, a room made is taken back, safely.
    private var place: CGRect = .zero
    private var front: Tab.ID?
    private var keys: Any?
    /// Counts decks taken out, so a late check on one is not taken for the next.
    private var turns = 0
    /// Esc pressed: nothing more until the hand lets go.
    private var cancelled = false
    /// The pages on screen, found once when the tab comes out.
    private var stages: [Tab.ID: StageView] = [:]
    private var papers: [PaperView] = []
    /// Pictures of the halves on screen, taken as the hand reaches them or
    /// the pointer the cross on one.
    private var shots: [Tab.ID: CGImage] = [:]
    /// Where the halves' pages are drawn, from the window's top left, as the
    /// hand reached the other half.
    private var pageFrames: [Tab.ID: CGRect] = [:]

    /// Whether a change of places can be drawn by the deck: both pictures
    /// in hand. The browser then lays the halves out at once (swapHalves).
    var canCarrySwap: Bool {
        guard let pair = browser?.stagePair else { return false }
        return [pair.first, pair.second].allSatisfy { shots[$0] != nil && pageFrames[$0] != nil }
    }

    // The layers: the hand, at the pointer; the card hanging from it; in the
    // card, a clip with the title band and the picture; the zone; a veil
    // over the tab's own half.
    private let hand = CALayer()
    private let card = CALayer()
    private let clip = CALayer()
    private let band = CALayer()
    private let mark = CALayer()
    private let title = CATextLayer()
    private let mini = CALayer()
    private let sheet = CALayer()
    private let zone = CALayer()
    private let tint = CALayer()
    private let badge = CALayer()
    private let veil = CALayer()

    var active: Bool { tab != nil }

    /// The hand is over a side of the pages where letting go makes or
    /// changes a pair: a screen's edge there is Split View's, not the
    /// tear-off's (TearOff.hear, #245a).
    var pairing: Bool {
        guard active, let aim else { return false }
        switch targets[aim].drop {
        case .beside, .instead, .swap: return true
        case .open, .chat: return false
        }
    }

    // MARK: - taking it out

    /// The tab has left its list over the pages. False, and nothing shown,
    /// when there is nowhere it could go.
    @discardableResult
    /// `home`: what the hand took it by, when that is not its row, a
    /// half's band: the card lifts from there and goes back there.
    func begin(_ tab: Tab, in browser: Browser, at: CGPoint? = nil, home given: CGRect? = nil) -> Bool {
        let started = Meter.start()
        defer { Meter.note(.begin, since: started) }
        guard self.tab == nil, landing == nil, let window = Links.window, let content = window.contentView else { return false }
        // The chat's column first: the tab in front, which has nowhere to
        // go among the pages, can still be given to the chat.
        let targets = (Self.chat(for: tab, in: browser, content: content).map { [$0] } ?? []) + Self.targets(for: tab, in: browser)
        guard !targets.isEmpty else { return false }
        turns += 1
        self.tab = tab
        self.browser = browser
        self.targets = targets
        aim = nil
        cancelled = false
        overPages = false
        place = browser.splitBook.place
        front = browser.activeID
        // No band is built ahead: a page with none is carried by Core
        // Animation alone (`slide`), one with one has it already.
        wanted = nil
        speed = 0
        lastMove = nil
        find(in: content)
        sky = Sky.over(content)
        sky?.take()
        guard let sky else { return false }
        let point = at ?? sky.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // The row as it stood, and the hand on it where it is now: out past
        // its end, it is held by its end.
        titleFont = .systemFont(ofSize: SidebarTypography.current)
        home = given ?? browser.keySky.place(tab.id) ?? CGRect(x: point.x - 90, y: point.y - 14, width: 180, height: 28)
        grip = CGPoint(x: min(max(8, point.x - home.minX), home.width - 8), y: min(max(4, point.y - home.minY), home.height - 4))
        dress(tab, in: sky)
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            guard let self, self.active else { return event }
            if event.type == .leftMouseUp {
                // The drag that holds the deck ends it on this same release;
                // one that never will, its view gone from the window under
                // the hand (the tabs changing sides), leaves it up and every
                // later drag refused. A beat later, whatever is still up is
                // put away.
                let turn = self.turns
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { if self.turns == turn, self.active { self.leave() } }
                }
                return event
            }
            guard let sky = self.sky, event.window === sky.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            MainActor.assumeIsolated { self.cancel() }
            return nil
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        move(to: point)
        return true
    }

    /// The hand moved: the card follows it; the card's shape, the zone and
    /// the room made change only when what is under the hand does.
    func move(to given: CGPoint? = nil) {
        let started = Meter.start()
        defer { Meter.note(.move, since: started) }
        guard active, !cancelled, let sky, let window = sky.window else { return }
        // The event being handled, the move that brought the drag here;
        // between events, where the pointer is. `given`, in the window's
        // space from its top left, for the bench.
        let event = NSApp.currentEvent
        let inWindow = event.flatMap { [.leftMouseDragged, .leftMouseDown, .leftMouseUp].contains($0.type) && $0.window === window ? $0.locationInWindow : nil }
            ?? window.mouseLocationOutsideOfEventStream
        let point = given ?? sky.convert(inWindow, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hand.position = point
        CATransaction.commit()
        pace(at: point)
        let over = browser.map { $0.flank == .left ? point.x > $0.splitBook.place.minX - 4 : point.x < $0.splitBook.place.maxX + 4 } ?? true
        if over != overPages {
            overPages = over
            shape(over ? .card : .pill)
        }
        // The window or the page in front changed under the hand: the room
        // goes back and the tab with it, as for Esc.
        if let browser, browser.splitBook.place != place || browser.activeID != front {
            cancel()
            return
        }
        // A little past a part's edge is still that part: a hand trembling
        // on the line doesn't send the page back and forth.
        var next = targets.firstIndex { $0.over.contains(point) }
        if let aim, next == nil || next != aim, targets[aim].over.insetBy(dx: -Self.hold, dy: -Self.hold).contains(point) { next = aim }
        guard next != aim else { return intend() }
        let was = aim
        aim = next
        aimed(from: was.map { targets[$0] }, to: next.map { targets[$0] })
    }

    /// Let go: what it was over, if anything. Over something, the card
    /// lands as that half (`land`, once the browser has made it); over
    /// nothing, it goes back into its row.
    func end() -> Drop? {
        guard active else { return nil }
        let drop = cancelled ? nil : aim.map { targets[$0].drop }
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        browser?.chatTabOver = false
        if let drop, let aim {
            landing = Landing(tab: tab, drop: drop, card: targets[aim].card)
            // Never left waiting on a drop the browser didn't take.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Self.slow) { [weak self] in
                if self?.landing != nil { self?.land() }
            }
        } else if !cancelled {
            goHome()
        }
        tab = nil
        targets = []
        aim = nil
        return drop
    }

    /// How far past a part's edge the hand still counts as over it.
    private static let hold: CGFloat = 14

    /// Brought back over the list: the deck goes, the drag goes on there,
    /// the page takes its width back.
    func leave() {
        guard active else { return }
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        giveRoomBack()
        tab = nil
        targets = []
        aim = nil
        browser?.chatTabOver = false
        fadeOut(after: 0)
    }

    /// Esc, for the bench.
    func cancelNow() { cancel() }

    private func cancel() {
        guard active, !cancelled else { return }
        cancelled = true
        aim = nil
        browser?.chatTabOver = false
        goHome()
    }

    // MARK: - where it can go

    private static func targets(for tab: Tab, in browser: Browser) -> [Target] {
        // Three or four panes, or two stacked: over a pane, the tab in its
        // place, as over a half.
        if let pair = browser.stagePair, !pair.halves {
            guard !pair.contains(tab.id), browser.canPlace(tab) || browser.canHost(tab) else { return [] }
            let frames = browser.paneFrames()
            return pair.ids.compactMap { id in frames[id].map { Target(over: $0, card: $0, drop: .instead(id)) } }
        }
        if let pair = browser.stagePair, let (left, right) = browser.halves() {
            let halves = [(pair.first, left), (pair.second, right)]
            if pair.contains(tab.id) {
                // One of the two: over the other, they change places.
                return halves.filter { $0.0 != tab.id }.map { Target(over: $0.1, card: $0.1, drop: .swap) }
            }
            // A pin stays in the grid: a copy of its page takes the half
            // (Browser.dropSplit).
            guard browser.canPlace(tab) || browser.canHost(tab) else { return [] }
            return halves.map { Target(over: $0.1, card: $0.1, drop: .instead($0.0)) }
        }
        let page = browser.splitBook.place
        guard let active = browser.active, active.id != tab.id, page.width > 0 else { return [] }
        // No room to be had, a pin, a task's folder: the whole page opens
        // the tab, as a click on its row would.
        guard browser.canCarry(tab, beside: active) else { return [Target(over: page, card: page, drop: .open)] }
        // A third of the page from either edge; the middle is nowhere, so
        // there is a place to let go that does nothing. The halves as
        // SplitLayout will lay them out.
        let third = page.width / 3
        let first = ((page.width - Pair.gap) * 0.5).rounded()
        let left = CGRect(x: page.minX, y: page.minY, width: first, height: page.height)
        let right = CGRect(x: page.minX + first + Pair.gap, y: page.minY, width: page.width - first - Pair.gap, height: page.height)
        return [
            Target(over: CGRect(x: page.minX, y: page.minY, width: third, height: page.height),
                   card: left, drop: .beside(.left), keeps: right),
            Target(over: CGRect(x: page.maxX - third, y: page.minY, width: third, height: page.height),
                   card: right, drop: .beside(.right), keeps: left),
            // The middle: let go there, the tab opens over the page, nothing
            // made room for.
            Target(over: CGRect(x: page.minX + third, y: page.minY, width: page.width - 2 * third, height: page.height),
                   card: page, drop: .open),
        ]
    }

    /// The chat's column, out and still, as a place to let a tab go: it
    /// becomes one of the things the next message carries. Not a private
    /// tab, which gives the chat nothing of its own (ChatComposer.page).
    private static func chat(for tab: Tab, in browser: Browser, content: NSView) -> Target? {
        guard browser.chatOpen, !browser.chatMoving, !tab.shy else { return nil }
        var queue = [content]
        while let view = queue.popLast() {
            if let column = view as? ChatColumnView, column.window != nil {
                let rect = flipped(column.convert(column.bounds, to: nil), in: content)
                return rect.width > 0 ? Target(over: rect, card: rect, drop: .chat) : nil
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The pages on screen and their paper, looked for once.
    private func find(in content: NSView) {
        stages = [:]
        papers = []
        var queue = [content]
        while let view = queue.popLast() {
            if let stage = view as? StageView, let id = stage.shows { stages[id] = stage }
            if let paper = view as? PaperView { papers.append(paper) }
            queue.append(contentsOf: view.subviews)
        }
    }

    private func paper(around rect: CGRect) -> PaperView? {
        papers.first { paper in
            guard paper.window != nil else { return false }
            let frame = paper.convert(paper.bounds, to: nil)
            return frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: frame.midY))
                && abs(frame.width - rect.width - 2) < 3
        }
    }

    // MARK: - over the pages

    /// What is under the hand changed.
    private func aimed(from old: Target?, to new: Target?) {
        let started = Meter.start()
        defer { Meter.note(.aim, since: started) }
        guard let browser, let tab else { return }
        // Room made beside the page closes with its own zone (closeRoom).
        let roomShut = roomed != nil
        // Whatever the last place asked of the pages, taken back first; the
        // next one asks again from wherever that has got to.
        if case .instead(let id) = old?.drop, new?.drop != old?.drop { dim(nil, of: id) }
        if case .swap = old?.drop, new?.drop != .swap { ownVeil(false) }
        if old?.drop == .chat, new?.drop != .chat { browser.chatTabOver = false }
        // Room taken back only when no other side asks for it: from one
        // side to the other, the page goes straight there.
        if old?.keeps != nil, new?.keeps == nil { giveRoomBack() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.state)
        card.borderWidth = new == nil ? 0 : 1.5
        CATransaction.commit()
        guard let new else {
            // An empty half closes with the room (giveRoomBack).
            if old?.keeps == nil { showZone(nil) }
            return
        }
        // Felt in the trackpad: a half to take over or trade, at once; room
        // beside the page once it opens (`makeRoom`), not as the hand
        // crosses a side on its way to the other.
        if new.keeps == nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        switch new.drop {
        case .beside(let side):
            // The page on screen goes to the half it keeps, laid out there:
            // at once from the other side's room, otherwise once the hand
            // means it (`intend`).
            wanted = (side, new.card, new.keeps ?? new.card)
            if roomed != nil { makeRoom() } else { intend() }
        case .open:
            // The page outlined, as Arc does: this is where it opens.
            outlinePage(new.card)
        case .chat:
            // The column's own drop zone, as for a file dragged there; none
            // of the deck's, which a page passed over may have left up.
            if !roomShut { showZone(nil) }
            browser.chatTabOver = true
        case .instead(let id):
            showZone(new.card, opaque: false)
            dim(new.card, of: id)
            picture(of: id)
        case .swap:
            showZone(new.card, opaque: false)
            ownVeil(true)
            // Both halves' pictures, for the change of places to be drawn
            // by the deck alone.
            if let pair = browser.stagePair {
                for id in [pair.first, pair.second] {
                    picture(of: id)
                    if let stage = stages[id], stage.window != nil { pageFrames[id] = Self.flipped(stage.convert(stage.bounds, to: nil), in: stage.window?.contentView) }
                }
            }
            _ = tab
        }
    }

    // MARK: - meaning it

    /// Room a side asks for, not made yet: the hand may only be passing
    /// over it, as it does over the left third on its way to the right from
    /// the column. Made once the hand slows or stops there; a page laid out
    /// at half its width and back for a side crossed on the way cost three
    /// motions and some twenty-five layouts in WebKit for one drag.
    private var wanted: (side: Side, card: CGRect, keeps: CGRect)?
    /// The hand's speed, in points a second, smoothed over the last moves.
    private var speed: CGFloat = 0
    private var lastMove: (point: CGPoint, at: CFTimeInterval)?
    private var moves = 0
    /// Slower than this, the hand is there to stay.
    private static let steady: CGFloat = 450
    /// Still for this long, it is too.
    private static let still: CFTimeInterval = 0.09

    private func pace(at point: CGPoint) {
        let now = CACurrentMediaTime()
        if let last = lastMove, now > last.at {
            let quick = hypot(point.x - last.point.x, point.y - last.point.y) / CGFloat(now - last.at)
            speed = speed * 0.5 + quick * 0.5
        }
        lastMove = (point, now)
        moves += 1
    }

    /// The room asked for, made if the hand has slowed; otherwise looked
    /// at again once it has been still a moment.
    private func intend() {
        guard wanted != nil else { return }
        if speed < Self.steady { return makeRoom() }
        let move = moves, turn = turns
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.still) { [weak self] in
            guard let self, self.turns == turn, self.moves == move, self.active, !self.cancelled else { return }
            self.makeRoom()
        }
    }

    private func makeRoom() {
        guard let room = wanted, let browser, aim.map({ targets[$0].drop }) == .beside(room.side) else { return }
        wanted = nil
        // A page with no band over it is carried to its half by Core
        // Animation alone, as Arc does: no band to bring, nothing in the
        // window laid out until the tab is let go. A page with one has it
        // moved with it, laid out there (Browser.previewSplit).
        if !browser.barShown, let id = browser.activeID, slide(id, keeping: room.keeps) {
            slid = id
        } else {
            browser.previewSplit(room.side)
        }
        roomed = room.side
        openRoom(room.card, side: room.side)
        // The room opening is felt, firmly, as Arc's is.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// The page given back its whole width, if room was made, and the
    /// empty half closing as it does.
    private func giveRoomBack() {
        wanted = nil
        guard let side = roomed else { return }
        roomed = nil
        if let id = slid {
            slid = nil
            stages[id]?.preview(nil, duration: Beat.back, timing: Beat.arrive)
            for paper in papers where paper.previewing != nil { paper.preview(nil, duration: Beat.back, timing: Beat.arrive) }
        } else {
            browser?.previewSplit(nil)
        }
        closeRoom(side)
    }

    /// The page carried by Core Animation, held at its width and cut to its
    /// half, and its paper with it; laid out at the half's width once it is
    /// there (StageView.preview). False where the page isn't on screen.
    private func slide(_ id: Tab.ID, keeping rect: CGRect) -> Bool {
        guard let browser, let stage = stages[id], stage.window != nil, let content = Links.window?.contentView else { return false }
        let frame = stage.convert(stage.bounds, to: nil)
        stage.preview(CGRect(x: rect.minX, y: frame.minY, width: rect.width, height: frame.height), duration: Beat.room, timing: Beat.arrive)
        // The room is kept from the window's top left, as SwiftUI has it;
        // the paper's frame runs up from the window's bottom.
        let room = content.convert(browser.splitBook.place, to: nil)
        let whole = CGRect(x: frame.minX, y: room.minY, width: frame.width, height: room.height)
        if let paper = paper(around: whole) {
            paper.preview(CGRect(x: rect.minX, y: whole.minY, width: rect.width, height: whole.height), duration: Beat.room, timing: Beat.arrive)
        }
        return true
    }

    /// The page carried by Core Animation, while it is.
    private var slid: Tab.ID?

    /// The side room was made on, beside the page in front.
    private var roomed: Side?

    /// The empty half, as the page's edge leaves it: an empty page's card,
    /// filled in the ground a blank page has, with the card's corners and a
    /// hairline, as Arc draws it. Nothing in it says what it is for: the
    /// card in the hand does. Opened from the room's outer edge on the
    /// page's own curve, a frame behind the page, so it is never drawn over
    /// the page still on its way.
    private func openRoom(_ rect: CGRect, side: Side) {
        let edge = Self.edge(of: rect, side: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zone.removeAllAnimations()
        zone.backgroundColor = blank
        zone.borderColor = quiet
        zone.borderWidth = 1
        tint.isHidden = true
        badge.isHidden = true
        zone.frame = edge
        zone.opacity = 1
        CATransaction.commit()
        // Drawn from the edge explicitly: the edge was set in this same
        // pass, and an implicit animation starts from what was last on
        // screen, the window's top left, the outline sweeping in across
        // the page from there.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.room)
        CATransaction.setAnimationTimingFunction(Beat.arrive)
        zone.frame = rect
        Self.from(edge, on: zone)
        CATransaction.commit()
        // A frame behind the page, which starts its curve a frame after
        // it is asked to (Browser.previewSplit).
        let later = CACurrentMediaTime() + 1.0 / 60
        for key in ["position", "bounds"] {
            guard let move = zone.animation(forKey: key)?.copy() as? CABasicAnimation else { continue }
            move.beginTime = later
            move.fillMode = .backwards
            zone.add(move, forKey: key)
        }
    }

    /// The empty half closing into its edge as the page takes it back.
    private func closeRoom(_ side: Side) {
        let edge = Self.edge(of: zone.frame, side: side)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.back)
        CATransaction.setAnimationTimingFunction(Beat.arrive)
        zone.frame = edge
        zone.opacity = 0
        CATransaction.commit()
    }

    /// The page the tab would open in, outlined in the accent: nothing
    /// over it, nothing moved.
    private func outlinePage(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zone.removeAllAnimations()
        zone.frame = rect
        zone.backgroundColor = nil
        zone.borderColor = NSColor.controlAccentColor.cgColor
        zone.borderWidth = 2
        tint.isHidden = true
        badge.isHidden = true
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.state)
        zone.opacity = 1
        CATransaction.commit()
    }

    /// A zone's outer edge, as a line: where the empty half opens from.
    private static func edge(of rect: CGRect, side: Side) -> CGRect {
        CGRect(x: side == .left ? rect.minX : rect.maxX, y: rect.minY, width: 0, height: rect.height)
    }

    /// The zone: outlined in the accent at once, on the ground of an empty
    /// half when room is made for it, over the half when it takes a half's
    /// place. The tab's mark in its middle, faint.
    private func showZone(_ rect: CGRect?, opaque: Bool = false) {
        guard let rect else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Beat.state * 2)
            zone.opacity = 0
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zone.removeAllAnimations()
        zone.frame = rect
        tint.frame = zone.bounds
        tint.isHidden = false
        badge.isHidden = false
        badge.position = CGPoint(x: zone.bounds.midX, y: zone.bounds.midY)
        zone.backgroundColor = opaque ? ground : nil
        zone.borderColor = NSColor.controlAccentColor.cgColor
        zone.borderWidth = 1.5
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.state)
        zone.opacity = 1
        CATransaction.commit()
    }

    /// A half to be replaced, dimmed while the hand is over it: the ground
    /// laid over it, band and page, so that it reads a step back.
    private func dim(_ rect: CGRect?, of id: Tab.ID) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.dim)
        if let rect {
            CATransaction.setDisableActions(true)
            veil.frame = rect
            CATransaction.setDisableActions(false)
            veil.opacity = 0.65
        } else {
            veil.opacity = 0
        }
        CATransaction.commit()
    }

    /// The tab's own half, one of the pair, dimmed while it is in the hand
    /// over the other.
    private func ownVeil(_ on: Bool) {
        guard let browser, let tab, let (left, right) = browser.halves(), let pair = browser.stagePair else { return }
        dim(on ? (pair.first == tab.id ? left : right) : nil, of: tab.id)
    }

    // MARK: - the card

    private enum Form { case pill, card }

    /// The row the hand holds, or the card of its page over the pages: the
    /// same layers, drawn from one to the other.
    private func shape(_ form: Form) {
        let started = Meter.start()
        defer { Meter.note(.shape, since: started) }
        let pill = form == .pill
        let size = pill ? home.size : Card.size
        let at = pill ? grip : Card.grip
        let top = pill ? home.height : Card.band
        let corner = pill ? Radius.control : Radius.surface
        CATransaction.begin()
        CATransaction.setAnimationDuration(pill ? Beat.back : Beat.lift)
        CATransaction.setAnimationTimingFunction(Beat.arrive)
        card.frame = CGRect(x: -at.x, y: -at.y, width: size.width, height: size.height)
        card.cornerRadius = corner
        card.shadowPath = CGPath.rounded(CGRect(origin: .zero, size: size), corner: corner)
        clip.frame = CGRect(origin: .zero, size: size)
        clip.cornerRadius = corner
        band.frame = CGRect(x: 0, y: 0, width: size.width, height: top)
        mark.frame = CGRect(x: 8, y: (top - 16) / 2, width: 16, height: 16)
        title.frame = CGRect(x: 30, y: (top - titleLine) / 2, width: size.width - 38, height: titleLine)
        mini.frame = CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        mini.opacity = pill ? 0 : 1
        sheet.frame = CGRect(x: 0, y: 0, width: size.width, height: size.width * TabGlance.still / TabGlance.width)
        CATransaction.commit()
    }

    /// The layers made up once for this tab, in the window's light or dark.
    private func dress(_ tab: Tab, in sky: Sky) {
        guard let layer = sky.layer else { return }
        let scale = sky.window?.backingScaleFactor ?? 2
        sky.effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accent = NSColor.controlAccentColor
            ground = Palette.NS.ground.cgColor
            quiet = Palette.NS.ink.withAlphaComponent(0.1).cgColor
            // A blank page's ground, a shade off the window's, as Arc's
            // empty half is.
            blank = Palette.NS.ground.withAlphaComponent(0.55).cgColor

            zone.frame = .zero
            zone.opacity = 0
            zone.cornerRadius = Backdrop.corner
            zone.cornerCurve = .continuous
            zone.borderColor = accent.cgColor
            zone.borderWidth = 1.5
            zone.masksToBounds = true
            tint.backgroundColor = accent.withAlphaComponent(0.08).cgColor
            zone.addSublayer(tint)
            // The tab's mark, large and faint, in the middle of where it goes.
            badge.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            badge.cornerRadius = 7
            badge.masksToBounds = true
            badge.contentsGravity = .resizeAspect
            badge.contentsScale = scale
            let icon = tab.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            badge.contents = icon
            badge.backgroundColor = tab.icon == nil ? Palette.NS.ink.withAlphaComponent(0.08).cgColor : nil
            badge.opacity = 0.45
            zone.addSublayer(badge)

            veil.backgroundColor = ground
            veil.opacity = 0
            veil.cornerRadius = Backdrop.corner
            veil.cornerCurve = .continuous
            layer.addSublayer(veil)
            layer.addSublayer(zone)

            card.backgroundColor = ground
            card.cornerCurve = .continuous
            card.borderColor = accent.cgColor
            card.borderWidth = 0
            card.shadowColor = NSColor.black.cgColor
            card.shadowOpacity = 0.2
            card.shadowRadius = 11
            card.shadowOffset = CGSize(width: 0, height: 8)
            card.opacity = 1
            clip.masksToBounds = true
            clip.cornerCurve = .continuous
            band.backgroundColor = nil
            mark.contentsGravity = .resizeAspect
            mark.contentsScale = scale
            mark.cornerRadius = 4
            mark.masksToBounds = true
            mark.contents = icon
            mark.backgroundColor = tab.icon == nil ? Palette.NS.ink.withAlphaComponent(0.06).cgColor : nil
            title.contentsScale = scale
            title.font = titleFont
            title.fontSize = titleFont.pointSize
            title.foregroundColor = Palette.NS.ink.cgColor
            title.truncationMode = .end
            title.string = tab.label
            band.opacity = 1
            // Its page: the picture TabGlance keeps of the tab's top, on the
            // page's own ground below it.
            mini.masksToBounds = true
            mini.backgroundColor = StageView.fill(under: nil, shade: tab.shade, tone: nil).cgColor
            mini.borderWidth = 0
            sheet.contentsGravity = .resize
            sheet.contentsScale = scale
            sheet.contents = browser?.glance.stills[tab.id]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            for sub in [band, mini] where sub.superlayer !== clip { clip.addSublayer(sub) }
            for sub in [mark, title] where sub.superlayer !== band { band.addSublayer(sub) }
            if sheet.superlayer !== mini { mini.addSublayer(sheet) }
            sheet.opacity = 1
            if clip.superlayer !== card { card.addSublayer(clip) }
            if card.superlayer !== hand { hand.addSublayer(card) }
            hand.frame = .zero
            layer.addSublayer(hand)
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The pill as the row stood, under the hand, before anything moves.
        shape(.pill)
        card.removeAllAnimations()
        for sub in [clip, band, mark, title, mini, sheet] { sub.removeAllAnimations() }
        CATransaction.commit()
    }

    private var ground: CGColor = NSColor.white.cgColor
    /// The empty half's hairline, and its ground.
    private var quiet: CGColor = NSColor.black.withAlphaComponent(0.1).cgColor
    private var blank: CGColor = NSColor.black.withAlphaComponent(0.06).cgColor

    // MARK: - letting go

    private struct Landing {
        let tab: Tab?
        let drop: Drop
        let card: CGRect
    }

    private var landing: Landing?

    /// The browser has made the pair: the card grows into its half, a half
    /// it took the place of flies back into its row, and once the page
    /// under the card has drawn at its size, the card and the zone fade.
    func land() {
        let started = Meter.start()
        defer { Meter.note(.land, since: started) }
        guard let landing, let sky, let browser else { self.landing = nil; fadeOut(after: 0); return }
        self.landing = nil
        // The browser didn't make the pair: the card goes home, the page
        // takes its width back.
        let made: Bool = {
            guard let id = landing.tab?.id else { return false }
            if case .swap = landing.drop { return true }
            if case .open = landing.drop { return browser.activeID == id }
            if case .chat = landing.drop { return true }
            // Beside: a pin or a kept tab is paired as a copy of itself.
            if case .beside = landing.drop { return browser.stagePair != nil }
            // In place of a half: a pin's copy took it, the half gone.
            if case .instead(let half) = landing.drop, landing.tab?.pin != nil {
                return browser.stagePair.map { !$0.contains(half) } ?? false
            }
            return browser.pair(of: id) != nil
        }()
        guard made else {
            tab = landing.tab
            goHome()
            tab = nil
            return
        }
        roomed = nil
        slid = nil
        switch landing.drop {
        case .open, .chat:
            // Opened, or given to the chat: the card fades where it is.
            showZone(nil)
            CATransaction.begin()
            CATransaction.setAnimationDuration(Beat.dim)
            card.opacity = 0
            CATransaction.commit()
            fadeOut(after: Beat.dim)
            return
        case .swap:
            // The card and the zone step aside, and the two pictures travel
            // from where each half was to where it is now, over pages laid
            // out there at once; they go once both have drawn.
            dim(nil, of: landing.tab?.id ?? UUID())
            showZone(nil)
            CATransaction.begin()
            CATransaction.setAnimationDuration(Beat.dim)
            card.opacity = 0
            CATransaction.commit()
            carrySwap(in: sky)
            return
        case .instead(let id):
            fly(id, from: landing.card, in: sky)
        case .beside:
            break
        }
        // The zone stays, solid, until the page under it has drawn.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zone.backgroundColor = ground
        veil.opacity = 0
        // The card taken off the hand where it is.
        let now = card.convert(card.bounds, to: sky.layer)
        card.removeFromSuperlayer()
        card.frame = now
        sky.layer?.addSublayer(card)
        CATransaction.commit()
        let to = landing.card
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.land)
        CATransaction.setAnimationTimingFunction(Reshape.Pace.reshape.timing)
        card.frame = to
        Self.from(now, on: card)
        card.cornerRadius = Backdrop.corner
        card.borderWidth = 0
        card.shadowOpacity = 0
        card.shadowPath = CGPath.rounded(CGRect(origin: .zero, size: to.size), corner: Backdrop.corner)
        clip.frame = CGRect(origin: .zero, size: to.size)
        clip.cornerRadius = Backdrop.corner
        band.frame = CGRect(x: 0, y: 0, width: to.width, height: 0)
        mini.frame = CGRect(origin: .zero, size: to.size)
        sheet.frame = CGRect(x: 0, y: 0, width: to.width, height: to.width * TabGlance.still / TabGlance.width)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.dim)
        band.opacity = 0
        CATransaction.commit()
        // The picture was taken at another width: over the second half of
        // the way it gives way to the page's own ground, which the page then
        // comes up on, rather than a small copy of it lingering.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Beat.land * 0.5
        fade.duration = Beat.land * 0.5
        fade.fillMode = .backwards
        sheet.add(fade, forKey: "fade")
        sheet.opacity = 0
        // Gone once the landing is over, the pair has settled and WebKit has
        // put the page on screen at its size; in any case after a second.
        let tab = landing.tab
        let begun = CACurrentMediaTime()
        func check() {
            let done = !browser.splitting && CACurrentMediaTime() - begun >= Beat.land
            guard done || CACurrentMediaTime() - begun > 1.2 * Self.slow else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { check() }
                return
            }
            if let web = tab?.webKitOnly("WebKit split-transition snapshots", build: false) {
                StageView.afterNextDrawing(web) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { self.fadeOut(after: 0) } }
            } else {
                fadeOut(after: 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Beat.land) { check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 * Self.slow) { [weak self] in self?.fadeOut(after: 0) }
    }

    /// A layer just moved to another parent, drawn to its new frame from
    /// `rect`, in the new parent's space. Left to itself, Core Animation
    /// draws it from where it was shown last, which is where it stood in
    /// its old parent's space: the card went up to the window's top left,
    /// over the row of tabs, and grew into its half from there. Within the
    /// transaction under way, on its curve.
    private static func from(_ rect: CGRect, on layer: CALayer) {
        let duration = CATransaction.animationDuration()
        let timing = CATransaction.animationTimingFunction()
        for (key, value) in [("position", NSValue(point: CGPoint(x: rect.midX, y: rect.midY))),
                             ("bounds", NSValue(rect: CGRect(origin: .zero, size: rect.size)))] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = value
            move.duration = duration
            move.timingFunction = timing
            layer.add(move, forKey: key)
        }
    }

    /// The card goes back into its row the way it came, and fades there.
    private func goHome() {
        if roomed != nil { giveRoomBack() } else { showZone(nil) }
        dim(nil, of: tab?.id ?? UUID())
        guard let sky else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = card.convert(card.bounds, to: sky.layer)
        card.removeFromSuperlayer()
        card.frame = now
        sky.layer?.addSublayer(card)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Beat.home)
        CATransaction.setAnimationTimingFunction(Beat.arrive)
        card.frame = home
        Self.from(now, on: card)
        card.cornerRadius = Radius.control
        card.borderWidth = 0
        card.shadowOpacity = 0
        card.shadowPath = CGPath.rounded(CGRect(origin: .zero, size: home.size), corner: Radius.control)
        clip.frame = CGRect(origin: .zero, size: home.size)
        clip.cornerRadius = Radius.control
        band.frame = CGRect(origin: .zero, size: home.size)
        mark.frame = CGRect(x: 8, y: (home.height - 16) / 2, width: 16, height: 16)
        title.frame = CGRect(x: 30, y: (home.height - titleLine) / 2, width: home.width - 38, height: titleLine)
        mini.frame = CGRect(x: 0, y: home.height, width: home.width, height: 0)
        mini.opacity = 0
        CATransaction.commit()
        fadeOut(after: Beat.home * 0.6)
    }

    /// Everything the deck shows faded, and the deck taken down.
    private func fadeOut(after delay: CFTimeInterval) {
        guard let sky else { return }
        let go = { [weak self] in
            guard let self, self.sky === sky, self.landing == nil, self.tab == nil else { return }
            self.sky = nil
            sky.fade(Beat.dim)
            // Room the browser never took over (no pair made): given back.
            if let browser = self.browser, browser.splitRoomAsked != nil { browser.previewSplit(nil) }
            if let preview = self.browser?.splitPreview, preview.warm {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { preview.warm = false }
            }
            // A slide the layout never took over: given back.
            for stage in self.stages.values where stage.previewing != nil { stage.preview(nil, duration: Beat.back, timing: Beat.arrive) }
            for paper in self.papers where paper.previewing != nil { paper.preview(nil, duration: Beat.back, timing: Beat.arrive) }
            self.stages = [:]
            self.papers = []
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go) } else { go() }
    }

    /// The two halves' pictures carried from their old places to their
    /// new ones, the pages already laid out there underneath.
    private func carrySwap(in sky: Sky) {
        guard let browser, let layer = sky.layer, let pair = browser.stagePair else { fadeOut(after: 0); return }
        let ids = [pair.first, pair.second]
        var flyers: [CALayer] = []
        // The pages are laid out in their new places at once, under the
        // pictures on their way there: where a picture doesn't cover yet,
        // the page it is bringing showed through already there, the same
        // page twice. Both places are covered in the ground until the
        // pictures have landed and gone.
        for page in ids.compactMap({ pageFrames[$0] }) {
            let cover = CALayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cover.frame = page
            cover.backgroundColor = ground
            cover.cornerRadius = Backdrop.corner
            cover.cornerCurve = .continuous
            cover.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer.addSublayer(cover)
            CATransaction.commit()
        }
        for id in ids {
            guard let from = pageFrames[id], let other = pageFrames[ids.first { $0 != id }!], let picture = shots[id] else { continue }
            // Its new place: where the other half's page was, at its own
            // width, the halves' widths having changed places too.
            let to = CGRect(x: from.minX < other.minX ? other.maxX - from.width : other.minX, y: from.minY, width: from.width, height: from.height)
            let flyer = CALayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flyer.frame = from
            flyer.contents = picture
            flyer.contentsGravity = .resizeAspectFill
            flyer.masksToBounds = true
            flyer.cornerRadius = Backdrop.corner
            flyer.cornerCurve = .continuous
            flyer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            layer.addSublayer(flyer)
            CATransaction.commit()
            // Drawn explicitly: a layer put in in this same pass has nothing
            // on screen yet for an implicit animation to start from.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flyer.frame = to
            CATransaction.commit()
            for (key, from, to) in [("position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: CGPoint(x: to.midX, y: to.midY))),
                                    ("bounds.size", NSValue(size: from.size), NSValue(size: to.size))] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = Beat.land
                animation.timingFunction = Reshape.Pace.reshape.timing
                flyer.add(animation, forKey: key)
            }
            flyers.append(flyer)
        }
        shots = [:]
        pageFrames = [:]
        let webs = ids.compactMap { id in browser.tabs.first { $0.id == id }?.webKitOnly("WebKit split-transition snapshots", build: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Beat.land) { [weak self] in
            var left = webs.count
            let done = { self?.fadeOut(after: 0) }
            guard left > 0 else { done(); return }
            for web in webs {
                StageView.afterNextDrawing(web) {
                    left -= 1
                    if left == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { done() } }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Beat.land + 1) { [weak self] in self?.fadeOut(after: 0) }
    }

    private static func flipped(_ rect: CGRect, in content: NSView?) -> CGRect {
        guard let content else { return rect }
        return rect.flippedIn(content)
    }

    // MARK: - a half going back to its row

    /// A picture of a half on screen, kept for its flight home.
    private func picture(of id: Tab.ID) {
        // Chromium's page is a picture of its own compositor frame, whichever
        // engine draws it (PageHandle.snapshot).
        if shots[id] == nil, let page = browser?.tabs.first(where: { $0.id == id })?.builtPage, page.engine == .chromium,
           page.window != nil, page.bounds.width > 0 {
            page.snapshot(PageShot(width: page.bounds.width, afterUpdates: false)) { [weak self] image, _ in
                guard let self, let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.shots[id] = picture
            }
            return
        }
        guard shots[id] == nil, let web = browser?.tabs.first(where: { $0.id == id })?.webKitOnly("WebKit split-transition snapshots", build: false), web.window != nil, web.bounds.width > 0 else { return }
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = false
        shot.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: shot) { [weak self] image, _ in
            guard let self, let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.shots[id] = picture
        }
    }

    /// A half on screen about to leave its pair by its cross: its picture
    /// taken now, while the pointer is on the cross, for the flight.
    func ready(_ id: Tab.ID, in browser: Browser) {
        self.browser = browser
        picture(of: id)
    }

    /// The half `id`, from where it is drawn, flown into its row and faded
    /// there, over whatever takes its place.
    private func fly(_ id: Tab.ID, from rect: CGRect, in sky: Sky) {
        guard let browser, let layer = sky.layer else { return }
        let flyer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flyer.frame = rect
        flyer.cornerRadius = Backdrop.corner
        flyer.cornerCurve = .continuous
        flyer.masksToBounds = true
        flyer.backgroundColor = ground
        flyer.contentsGravity = .resizeAspectFill
        flyer.contents = shots[id]
        shots[id] = nil
        if flyer.contents == nil, let tab = browser.tabs.first(where: { $0.id == id }) {
            flyer.contents = tab.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            flyer.contentsGravity = .center
        }
        // Under the card landing in its place, over the zone.
        layer.insertSublayer(flyer, above: zone)
        CATransaction.commit()
        // Its row as the list now draws it, a frame on, once laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30 * Self.slow) { [weak self] in
            let to = browser.keySky.place(id) ?? CGRect(x: rect.midX, y: rect.minY, width: 1, height: 1)
            Self.send(flyer, to: to, duration: Beat.fly) { flyer.removeFromSuperlayer() }
            _ = self
        }
    }

    /// `layer` drawn into `to`, fading over the last third of the way.
    private static func send(_ layer: CALayer, to: CGRect, duration: CFTimeInterval, done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Reshape.Pace.reshape.timing)
        CATransaction.setCompletionBlock(done)
        layer.frame = to
        layer.cornerRadius = Radius.control
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.66, 1]
        fade.duration = duration
        layer.add(fade, forKey: "fade")
        layer.opacity = 0
        CATransaction.commit()
    }

    /// Where a tab's page is drawn in the window, from its top left.
    static func pageFrame(of id: Tab.ID) -> CGRect? {
        guard let content = Links.window?.contentView else { return nil }
        var queue = [content]
        while let view = queue.popLast() {
            if let stage = view as? StageView, stage.shows == id, stage.window != nil {
                return stage.convert(stage.bounds, to: nil).offsetBy(dx: 0, dy: 0).flippedIn(content)
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// A half leaving its pair by its cross: its picture flown into its row
    /// while the other takes the width (Browser.leaveSplit).
    func flyHome(_ id: Tab.ID, from rect: CGRect, in browser: Browser) {
        guard let content = Links.window?.contentView else { return }
        self.browser = browser
        let own = sky == nil
        let sky = self.sky ?? Sky.over(content)
        if own { self.sky = sky; sky.take(); dressGround(sky) }
        fly(id, from: rect, in: sky)
        if own {
            let turn = sky.turn
            DispatchQueue.main.asyncAfter(deadline: .now() + Beat.fly + 0.1) { [weak self] in
                guard let self, self.tab == nil, self.landing == nil, self.sky === sky, sky.turn == turn else { return }
                self.sky = nil
                sky.clear()
            }
        }
    }

    private func dressGround(_ sky: Sky) {
        sky.effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.NS.ground.cgColor }
        zone.opacity = 0
        sky.layer?.addSublayer(zone)
    }

    /// The window's layer for the deck put there ahead, when the window
    /// has settled, so the first drag doesn't pay for it.
    static func warm() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let content = Links.window?.contentView else { return }
            _ = Sky.over(content)
        }
    }

    // MARK: - measured, for the bench

    /// The main thread's time in each part of a drag, in a test world.
    @MainActor enum Meter {
        enum Part: String, CaseIterable { case begin, move, aim, shape, land }
        static var on = Store.testing
        private(set) static var spent: [Part: (count: Int, ms: Double, most: Double)] = [:]

        static func start() -> Double { on ? Bench.mainCPU() : 0 }

        static func note(_ part: Part, since: Double) {
            guard on else { return }
            let ms = Bench.mainCPU() - since
            let was = spent[part] ?? (0, 0, 0)
            spent[part] = (was.count + 1, was.ms + ms, max(was.most, ms))
        }

        static func reset() { spent = [:] }

        static var report: [String: Any] {
            Dictionary(uniqueKeysWithValues: spent.map { part, value in
                (part.rawValue, ["count": value.count, "mean_ms": (value.ms / Double(max(1, value.count)) * 1000).rounded() / 1000, "most_ms": (value.most * 1000).rounded() / 1000])
            })
        }
    }

    /// What the deck has on screen, for the bench.
    var report: [String: Any] {
        [
            "active": active,
            "landing": landing != nil,
            "sky": sky != nil,
            "card": "\(card.frame)",
            "zone": "\(zone.frame) \(zone.opacity)",
            "aim": aim ?? -1,
            "over": overPages,
            "shots": shots.count,
            "pageFrames": pageFrames.count,
            "canCarrySwap": canCarrySwap,
            "stages": stages.count,
            "roomed": roomed.map { "\($0)" } ?? "",
            // Where the page carried by Core Animation is held, in the
            // window's points from its left: x, width.
            "slid": slid.flatMap { stages[$0]?.previewing }.map { [Double($0.minX), Double($0.width)] } ?? [],
        ]
    }

    /// The deck's own view, over the whole window, in the same space as
    /// SwiftUI's frames, from the top left; the hand passes through it.
    final class Sky: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Over the SwiftUI window, beside it rather than in it: a view
        /// added into the hosting view is drawn under what SwiftUI draws.
        /// One for the window, kept: put there the first time, it cost the
        /// main thread some 6 ms; at rest it is an empty layer, drawn by
        /// nobody (`warm`).
        static func over(_ content: NSView) -> Sky {
            var top: NSView = content
            while let up = top.superview { top = up }
            if let kept, kept.superview === top { return kept }
            let sky = Sky(frame: top.convert(content.bounds, from: content))
            sky.autoresizingMask = [.width, .height]
            top.addSubview(sky, positioned: .above, relativeTo: nil)
            kept = sky
            return sky
        }

        private static weak var kept: Sky?

        /// Counts who has it: a fade finishing clears only its own turn.
        private(set) var turn = 0

        /// Taken for a drag or a flight: whatever an earlier one left, gone.
        func take() {
            turn += 1
            clear()
        }

        func clear() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeAnimation(forKey: "fade")
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer?.opacity = 1
            CATransaction.commit()
        }

        func fade(_ duration: CFTimeInterval) {
            let turn = self.turn
            // A view's own layer takes no implicit animation: the fade is
            // spelled out.
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.turn == turn else { return }
                self.clear()
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            layer?.opacity = 0
            layer?.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }
}

private extension CGRect {
    /// A rectangle in the window's coordinates, which run up, as it is
    /// from the top left of `content`, as SwiftUI's frames are.
    func flippedIn(_ content: NSView) -> CGRect {
        let local = content.convert(self, from: nil)
        return content.isFlipped ? local : CGRect(x: local.minX, y: content.bounds.height - local.maxY, width: width, height: height)
    }
}

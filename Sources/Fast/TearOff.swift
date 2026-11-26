import AppKit
import SwiftUI
import WebKit

// A tab dragged out of its window, the row's or the strip's, past the
// window's edge, leaves it: a small picture of its page follows the
// pointer. Let go over nothing of Yab's, a new window opens there with the
// tab in it, the grabbed point still under the pointer.
// Let go over another window's column or strip, the tab goes in there,
// where the line between two rows shows. Brought back inside its own
// window before letting go, the picture goes and the drag carries on as a
// reorder. The page is the same page all along: the same web view moves,
// nothing loads again (BrowserWindows.move, as Move to New Window does).
//
// The drag stays the column's or the strip's own gesture, as with
// SpaceDrop and SplitDeck: it asks here as the hand moves, and here when it
// lets go, and does nothing of its own while this answers yes.
//
// What Chrome does (TabDragController, read 2026-10-07): a tab held 15 pt
// past the strip comes away (kVerticalDetachMagnetism), the window opens
// where the hand is, at the size of the one it left, with the tab under the
// hand; over another window's strip it goes in at the pointer, and back
// over its own it goes back. Here the edge is the window's: down over the
// page the tab is for a split (SplitDeck), as in Arc. A window that fills
// its screen has no room past its edge for the pointer, so there the hand
// pushed on against the screen's edge counts (TearRules.push), and the new
// window is a new one's size rather than the whole screen again.

/// The rules, apart from any window, for the tests.
enum TearRules {
    /// How far past the window's edge the hand takes the tab before it
    /// comes away: Chrome's 15. Coming back, the edge itself.
    static let reach: CGFloat = 15

    /// Whether a drag at `point` has the tab out of the window `frame`.
    /// Out already, it stays out until the hand is back inside the frame.
    static func outside(_ point: CGPoint, of frame: CGRect, torn: Bool) -> Bool {
        torn ? !frame.contains(point) : !frame.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    /// The edges of the screens the pointer stands at with no screen past
    /// them, where it stops while the hand goes on (screen space, y up).
    struct Walls: Equatable {
        var left = false, right = false, bottom = false, top = false
    }

    static func walls(at point: CGPoint, screens: [CGRect]) -> Walls {
        guard let screen = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return Walls() }
        func open(_ x: CGFloat, _ y: CGFloat) -> Bool { screens.contains { $0.contains(CGPoint(x: x, y: y)) } }
        // The pointer stops a point short of a far edge, on a near one.
        let slack: CGFloat = 1.5
        return Walls(left: point.x <= screen.minX + slack && !open(screen.minX - 1, point.y),
                     right: point.x >= screen.maxX - slack && !open(screen.maxX + 1, point.y),
                     bottom: point.y <= screen.minY + slack && !open(point.x, screen.minY - 1),
                     top: point.y >= screen.maxY - slack && !open(point.x, screen.maxY + 1))
    }

    /// How far the hand is past the pointer: a window that fills its
    /// screen has nothing past its edge for the pointer to reach, and a tab
    /// in it came away from no drag at all (Oct 9, over a whole 4K screen).
    /// The pointer stops at the screen's edge, but each move still says
    /// how far the hand went (its event's delta), so what it missed there
    /// is the hand's alone: `offset` so far, the pointer `from` and `to`,
    /// the move `delta`, y up. The hand taken `reach` past the window's
    /// edge that way comes away as anywhere else, and back in by as much it
    /// goes back. Until then, off a wall it follows the pointer again.
    static func push(_ offset: CGVector, from: CGPoint, to: CGPoint, delta: CGVector,
                     screens: [CGRect], torn: Bool) -> CGVector {
        let wall = walls(at: to, screens: screens)
        let missed = CGVector(dx: from.x + delta.dx - to.x, dy: from.y + delta.dy - to.y)
        var next = offset
        if wall.right, missed.dx > 0 {
            next.dx += missed.dx
        } else if wall.left, missed.dx < 0 {
            next.dx += missed.dx
        } else if !torn, !wall.left, !wall.right {
            next.dx = 0
        }
        if wall.top, missed.dy > 0 {
            next.dy += missed.dy
        } else if wall.bottom, missed.dy < 0 {
            next.dy += missed.dy
        } else if !torn, !wall.top, !wall.bottom {
            next.dy = 0
        }
        return next
    }

    /// Another app's window over everything that takes no clicks: a
    /// curtain over a test Mac (~/bin/blackout), Notification Center's.
    /// Any other, at any level, a dialog asking for a password among them,
    /// is what a hand's press there lands on.
    static func seeThrough(executable: String?, bundle: String?) -> Bool {
        executable == "blackout" || bundle == "com.apple.notificationcenterui"
    }

    /// The Dock's own window over a whole screen, above every app's (seen
    /// on a Mac mini, at the Dock's level): it takes no press, and a tab
    /// let go over another window under it found no window there. The
    /// Dock's row itself stays what it is.
    static func seeThrough(bundle: String?, frame: CGRect, screens: [CGRect]) -> Bool {
        bundle == "com.apple.dock" && screens.contains { abs($0.width - frame.width) < 1 && abs($0.height - frame.height) < 1 && abs($0.minX - frame.minX) < 1 }
    }

    /// A row of the window the tab is let go over, in that window's space
    /// from its top-left: where it is drawn, which tabs of the row it
    /// stands for (a split's pair is one row), and its tab.
    struct Row: Equatable {
        var id: UUID
        var frame: CGRect
        var index: Int
        var through: Int
    }

    enum Axis { case column, strip }

    /// Where it would land: the index in the row once it has arrived at
    /// the row's end, the row whose kind (kept, in a folder) it takes on,
    /// and the line that shows it.
    struct Landing: Equatable {
        var index: Int
        var like: UUID?
        var line: CGRect?
    }

    /// Before the first row it is over the first half of, or after the
    /// last. `count` is how many tabs the window has before this one comes
    /// in at the end; `floor`/`ceiling` keep a pin among the pins and a tab
    /// among the tabs; `keptEnd` is where today's start, below which a tab
    /// that can't be kept never lands.
    static func landing(at point: CGPoint, rows: [Row], axis: Axis, count: Int,
                        floor: Int, ceiling: Int, keepable: Bool = true, keptEnd: Int = 0) -> Landing {
        let rows = rows.sorted { $0.index < $1.index }
        func along(_ rect: CGRect) -> (start: CGFloat, mid: CGFloat, end: CGFloat) {
            axis == .column ? (rect.minY, rect.midY, rect.maxY) : (rect.minX, rect.midX, rect.maxX)
        }
        let at = axis == .column ? point.y : point.x
        var index: Int
        var like: UUID?
        var line: CGRect?
        if let next = rows.firstIndex(where: { at < along($0.frame).mid }) {
            let row = rows[next]
            index = row.index
            like = row.id
            let before = next > 0 ? along(rows[next - 1].frame).end : nil
            let edge = before.map { ($0 + along(row.frame).start) / 2 } ?? along(row.frame).start - 1
            line = mark(at: edge, across: row.frame, axis: axis)
        } else if let last = rows.last {
            index = last.through + 1
            like = last.id
            line = mark(at: along(last.frame).end + 1, across: last.frame, axis: axis)
        } else {
            index = count
        }
        if !keepable, index < keptEnd {
            index = keptEnd
            like = nil
            line = nil
        }
        let clamped = min(max(index, floor), ceiling)
        if clamped != index { line = nil }
        return Landing(index: clamped, like: like, line: line)
    }

    /// A line two points thick, across the row, centered on `edge`.
    private static func mark(at edge: CGFloat, across row: CGRect, axis: Axis) -> CGRect {
        axis == .column
            ? CGRect(x: row.minX, y: edge - 1, width: row.width, height: 2)
            : CGRect(x: edge - 1, y: row.minY, width: 2, height: row.height)
    }

    /// The new window's frame, in the screen's space (y up): as big as the
    /// one the tab left, the point it was taken by under the pointer
    /// (`grab`, from the old window's top-left, y down), on the screen.
    static func newWindow(pointer: CGPoint, grab: CGPoint, size: CGSize, visible: CGRect) -> CGRect {
        var frame = CGRect(x: pointer.x - grab.x, y: pointer.y + grab.y - size.height,
                           width: min(size.width, visible.width), height: min(size.height, visible.height))
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        return frame
    }

    /// How big the new window is: as the one it left, but for one that
    /// fills its screen, the new window over all of it would hide the old
    /// one behind and look like nothing happened: then a new window's own
    /// size, as Move to New Window opens it (`fresh`).
    static func size(leaving size: CGSize, visible: CGRect, fresh: CGSize) -> CGSize {
        guard size.width >= visible.width - 8, size.height >= visible.height - 8 else { return size }
        return CGSize(width: min(fresh.width, visible.width), height: min(fresh.height, visible.height))
    }

    /// How small the picture is: the window at a third, never narrower
    /// than 240 nor wider than 360.
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0 else { return 0.3 }
        return min(max(size.width * 0.3, 240), 360) / size.width
    }
}

@MainActor
final class TearOff {
    static let shared = TearOff()

    /// The picture's room around the card, for its shadow.
    private static let margin: CGFloat = 40

    /// The drag the hand is on: its tab, and where it took hold, on the
    /// screen. Set by the first move of every drag.
    private var held: (tab: Tab, start: CGPoint)?
    private weak var source: Browser?
    /// Where the window was taken, from its top-left, and how big it was.
    private var grab: CGPoint = .zero
    private var size: CGSize = .zero
    private var panel: NSPanel?
    private var line: NSPanel?
    private let card = TearCardModel()
    private var target: (browser: Browser, landing: TearRules.Landing)?
    private var refresh: Timer?
    /// How far the hand is past the pointer (TearRules.push), from where
    /// the pointer was at the last move, and that move's time, so a move
    /// heard twice counts once.
    private var push = CGVector.zero
    private var last: CGPoint?
    private var heard: TimeInterval = -1
    /// Every move of the drag, a hand pushed against a screen's edge
    /// that moves no pointer among them.
    private var listening: Any?

    /// The tab out of its window right now.
    var tab: Tab? { panel == nil ? nil : held?.tab }
    var torn: Bool { panel != nil }
    var targetWindow: NSWindow? { target.flatMap { BrowserWindows.shared.window(for: $0.browser) } }
    var targetIndex: Int? { target?.landing.index }
    var cardFrame: CGRect? { panel?.frame }
    var linePanel: NSWindow? { line?.alphaValue == 0 ? nil : line }
    var cardPanel: NSWindow? { panel ?? leaving }
    /// The card going away, as it grows into a new window or fades: the
    /// bench's film keeps drawing it until it is gone.
    private var leaving: NSPanel?
    /// How far the hand is past the pointer, for the bench.
    var handPast: CGVector { push }

    /// Whether this tab can leave its window: as Move to New Window asks.
    static func tearable(_ tab: Tab, in browser: Browser) -> Bool {
        browser.tabs.contains { $0 === tab } && !tab.shy && !tab.onCall && browser.partner(of: tab) == nil
    }

    /// The hand moved, carrying `tab` in `browser`'s window, `moved` from
    /// where it pressed (the drag's translation, y down). Yes while the tab
    /// is out of the window: the row leaves it alone.
    func track(_ tab: Tab, browser: Browser, moved: CGSize, event: NSEvent? = nil) -> Bool {
        guard let window = BrowserWindows.shared.window(for: browser) else { return false }
        let event = event ?? NSApp.currentEvent
        let point = Self.pointer(in: window, event: event)
        if held?.tab !== tab {
            if torn { put(away: true) }
            held = (tab, CGPoint(x: point.x - moved.width, y: point.y + moved.height))
            source = browser
            push = .zero
            last = point
            // The move that started it is where the pointer already is.
            heard = event?.timestamp ?? -1
            listen()
        }
        // A move the watch hasn't heard (the bench hands the window its
        // own) still moves the hand.
        hear(event, at: point)
        let hand = CGPoint(x: point.x + push.dx, y: point.y + push.dy)
        guard Self.tearable(tab, in: browser) else {
            if torn { put(away: true) }
            return false
        }
        guard TearRules.outside(hand, of: window.frame, torn: torn) else {
            // Back inside: the reorder goes on.
            if torn { put(away: true) }
            return false
        }
        if !torn { begin(tab, window: window) }
        move(to: point)
        return true
    }

    /// A move of the drag's, once: what of it the pointer didn't follow,
    /// held at a screen's edge, goes to the hand's push.
    private func hear(_ event: NSEvent?, at point: CGPoint) {
        var delta = CGVector(dx: point.x - (last?.x ?? point.x), dy: point.y - (last?.y ?? point.y))
        if let event, event.type == .leftMouseDragged {
            guard event.timestamp != heard else { return }
            heard = event.timestamp
            // The event's y grows down the screen.
            delta = CGVector(dx: event.deltaX, dy: -event.deltaY)
        }
        push = TearRules.push(push, from: last ?? point, to: point, delta: delta,
                              screens: NSScreen.screens.map(\.frame), torn: torn)
        // Over the page's side, the screen's left or right edge is where
        // Split View makes room: a mouse thrown at it goes on past it, and
        // the tab left for a window of its own instead (#245a, row 342).
        if !torn, SplitDeck.shared.pairing { push.dx = 0 }
        last = point
    }

    /// The drag's moves as they come in, before the row's drag hears
    /// them, if it hears them at all: one against a screen's edge moves
    /// no pointer.
    private func listen() {
        guard listening == nil else { return }
        listening = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let source = self.source, self.held != nil,
                      let window = BrowserWindows.shared.window(for: source) else { return }
                let point = event.window === window ? window.convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
                self.hear(event, at: point)
            }
            return event
        }
    }

    private func forget() {
        held = nil
        push = .zero
        last = nil
        if let listening { NSEvent.removeMonitor(listening) }
        listening = nil
    }

    /// Let go. Yes when the tab was out of its window: it has gone where
    /// it was let go, and the row forgets the drag.
    func finish(_ browser: Browser, event: NSEvent? = nil) -> Bool {
        defer { forget() }
        guard torn, let tab = held?.tab, let source, source === browser,
              let window = BrowserWindows.shared.window(for: source) else {
            if torn { put(away: true) }
            return false
        }
        let point = Self.pointer(in: window, event: event)
        move(to: point)
        if let target, BrowserWindows.shared.move(tab, from: source, to: target.browser, announce: false) {
            place(tab, in: target.browser, at: target.landing)
            land(in: target.browser, at: target.landing)
            return true
        }
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? window.frame
        // Out of a window that fills its screen, a window of a new one's
        // size, taken by the same point of it, in proportion.
        let room = TearRules.size(leaving: size, visible: window.screen?.visibleFrame ?? visible, fresh: BrowserWindows.freshSize)
        let taken = CGPoint(x: grab.x * room.width / max(size.width, 1), y: grab.y * room.height / max(size.height, 1))
        let frame = TearRules.newWindow(pointer: point, grab: taken, size: room, visible: visible)
        guard let opened = BrowserWindows.shared.moveToNewWindow(tab, from: source, frame: frame, announce: false),
              let made = BrowserWindows.shared.window(for: opened) else {
            put(away: true)
            return true
        }
        grow(into: made)
        return true
    }

    /// The drag broken off: the picture goes, nothing moves.
    func cancel() {
        if torn { put(away: true) }
        forget()
    }

    // MARK: - the picture

    private func begin(_ tab: Tab, window: NSWindow) {
        size = window.frame.size
        if let start = held?.start {
            grab = CGPoint(x: start.x - window.frame.minX, y: window.frame.maxY - start.y)
        }
        let scale = TearRules.scale(for: size)
        card.title = tab.label
        card.icon = tab.displayIcon
        card.monogram = tab.monogram
        card.image = nil
        card.grip = UnitPoint(x: min(max(grab.x / size.width, 0), 1), y: min(max(grab.y / size.height, 0), 1))
        card.shown = false
        card.over = false
        card.fill = false
        let picture = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        card.picture = picture
        card.row = Self.row(picture: picture, grip: card.grip, grab: grab)
        let room = CGSize(width: picture.width + 2 * (CardFrame.inset + Self.margin),
                          height: picture.height + 2 * (CardFrame.inset + Self.margin))
        let panel = Self.panel(size: room)
        // Light or dark as the window it came from is.
        panel.appearance = window.effectiveAppearance
        panel.contentView = WindowHosting.content(TearCard(model: card).padding(Self.margin))
        panel.contentView?.wantsLayer = true
        let line = Self.panel(size: CGSize(width: 2, height: 2))
        let mark = NSView()
        mark.wantsLayer = true
        mark.layer?.backgroundColor = Palette.NS.ink.cgColor
        mark.layer?.cornerRadius = 1
        line.contentView = mark
        line.alphaValue = 0
        self.panel = panel
        self.line = line
        panel.orderFrontRegardless()
        // The line over the card: where it goes in is what matters then.
        line.order(.above, relativeTo: panel.windowNumber)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if still {
            card.shown = true
        } else {
            // The row first, under the hand where the column's was, then
            // the same thing grows into the card, as Arc's does.
            withAnimation(TearCard.morph) { card.shown = true }
        }
        snap(tab, width: picture.width)
        // The picture is the page as it is now: a video goes on playing in it.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                guard let self, let tab, self.torn else { return }
                self.snap(tab, width: picture.width)
            }
        }
        // In the drag's own run loop mode too.
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    private func snap(_ tab: Tab, width: CGFloat) {
        // A page not drawn anywhere, asleep or behind the one in front, has
        // no picture to take: the card says its name instead.
        guard let page = tab.builtPage, page.window != nil else { return }
        page.snapshot(PageShot(width: width, afterUpdates: false)) { [weak self] image, _ in
            guard let self, let image, self.torn, self.held?.tab === tab else { return }
            self.card.image = image
        }
    }

    /// The card under the pointer, held by the point the tab was taken by;
    /// and over another window's tabs, the line where it would go in.
    private func move(to point: CGPoint) {
        guard let panel else { return }
        let inner = CGSize(width: panel.frame.width - 2 * Self.margin, height: panel.frame.height - 2 * Self.margin)
        let picture = CGSize(width: inner.width - 2 * CardFrame.inset, height: inner.height - 2 * CardFrame.inset)
        let x = point.x - Self.margin - CardFrame.inset - card.grip.x * picture.width
        let top = point.y + Self.margin + CardFrame.inset + card.grip.y * picture.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (top - panel.frame.height).rounded()))
        aim(at: point)
    }

    private func aim(at point: CGPoint) {
        guard let source, let tab = held?.tab else { return }
        defer {
            let over = target != nil
            if card.over != over {
                if still { card.over = over } else { withAnimation(TearCard.morph) { card.over = over } }
            }
        }
        guard let number = Self.window(at: point),
              let window = NSApp.windows.first(where: { $0.windowNumber == number }),
              let browser = BrowserWindows.shared.browser(for: window), browser !== source,
              browser.spaceID == source.spaceID,
              let landing = Self.landing(of: tab, at: point, in: browser, window: window) else {
            if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            target = nil
            line?.alphaValue = 0
            return
        }
        if target?.browser !== browser || target?.landing.index != landing.index {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        target = (browser, landing)
        if let mark = landing.line, let line {
            // The ink of the window it goes into.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                line.contentView?.layer?.backgroundColor = Palette.NS.ink.cgColor
            }
            line.setFrame(Self.screen(mark, in: browser), display: true)
            line.alphaValue = 1
        } else {
            line?.alphaValue = 0
        }
    }

    /// The window under `point` (the screen's), any app's at any level,
    /// front first: one of another app's in front of a Yab window takes
    /// nothing, a dialog above every window too. Only what takes no clicks
    /// is see-through to the hand (TearRules.seeThrough), and this card.
    static func window(at point: CGPoint) -> Int? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        // The list's space is the first screen's, from its top-left.
        let at = CGPoint(x: point.x, y: top - point.y)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var through: [Int: Bool] = [:]
        for row in rows {
            guard (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(at), let number = row[kCGWindowNumber as String] as? Int else { continue }
            let owner = row[kCGWindowOwnerPID as String] as? Int ?? 0
            if owner != me, TearRules.seeThrough(bundle: NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier, frame: rect,
                                                 screens: NSScreen.screens.map(\.frame)) { continue }
            guard owner == me else {
                let clear = through[owner] ?? {
                    let app = NSRunningApplication(processIdentifier: pid_t(owner))
                    return TearRules.seeThrough(executable: app?.executableURL?.lastPathComponent, bundle: app?.bundleIdentifier)
                }()
                through[owner] = clear
                if clear { continue }
                return number
            }
            // One of Yab's own over a window, a band or a panel hung on it:
            // the window it hangs on; one hung on nothing is see-through.
            var window = NSApp.windows.first { $0.windowNumber == number }
            while let each = window, BrowserWindows.shared.browser(for: each) == nil { window = each.parent }
            if let window { return window.windowNumber }
        }
        return nil
    }

    /// Where in `browser`'s row the tab would go in, let go at `point`
    /// (the screen's), if the point is over its column or strip.
    static func landing(of tab: Tab, at point: CGPoint, in browser: Browser, window: NSWindow) -> TearRules.Landing? {
        // In the space the rows are measured in (TearGround).
        guard let anchor = browser.keySky.groundView, anchor.window === window else { return nil }
        let ground = browser.keySky.ground
        let corner = anchor.convert(window.convertPoint(fromScreen: point), from: nil)
        let at = CGPoint(x: corner.x + ground.x, y: corner.y + ground.y)
        let width = anchor.bounds.width + ground.x
        // A column put away shows no tabs to go in among.
        if browser.prefs.sidebar, browser.sideShown <= 0 { return nil }
        let column = browser.prefs.sidebar
        let pinned = tab.pin != nil
        let pins = browser.pinnedCount
        var rows: [TearRules.Row] = []
        for (index, other) in browser.tabs.enumerated() where (other.pin != nil) == pinned {
            if let pair = browser.pair(of: other.id), pair.second == other.id { continue }
            let frame: CGRect?
            if column, !pinned {
                frame = browser.drawnRows[DrawnRows.tab(other.id)]
            } else {
                frame = (browser.folderBook.place(of: other)?.shown ?? true) ? browser.keySky.place(other.id) : nil
            }
            guard let frame, frame.width > 0, frame.height > 0 else { continue }
            let through = browser.partner(of: other).flatMap { partner in browser.tabs.firstIndex { $0 === partner } }
            rows.append(TearRules.Row(id: other.id, frame: frame, index: index, through: max(index, through ?? index)))
        }
        if column {
            let side = browser.sideShown + 8
            let over = browser.flank == .left ? at.x - ground.x <= side : at.x >= width - side
            guard over else { return nil }
        } else {
            // The window's top band, at least: a strip tucked up above the
            // window (put away, or yet to come down) still says by its
            // pills' places where each tab stands along it.
            let bottom = max(rows.map(\.frame.maxY).max() ?? 0, ground.y + 36) + 8
            guard at.y <= bottom else { return nil }
        }
        // The pins are a grid in the column: a pin goes in after the last.
        let axis: TearRules.Axis = column && !pinned ? .column : .strip
        let point = column && pinned ? CGPoint(x: .greatestFiniteMagnitude, y: at.y) : at
        var landing = TearRules.landing(at: point, rows: rows, axis: axis, count: browser.tabs.count,
                                        floor: pinned ? 0 : pins, ceiling: pinned ? pins : browser.tabs.count,
                                        keepable: tab.keepable, keptEnd: browser.keptEnd)
        // The line where it can be seen, inside the window.
        if let line = landing.line, line.minY < ground.y + 4 {
            landing.line = line.offsetBy(dx: 0, dy: ground.y + 4 - line.minY)
        }
        return landing
    }

    /// In: the kind of the row it went in beside, kept or today's, in that
    /// folder or none, and its place.
    private func place(_ tab: Tab, in browser: Browser, at landing: TearRules.Landing) {
        var changed = false
        if tab.pin == nil {
            let like = landing.like.flatMap { id in browser.tabs.first { $0.id == id } }
            let kept = (like?.kept ?? false) && tab.keepable
            let nest = kept ? like?.nest : nil
            changed = tab.kept != kept || tab.nest !== nest
            tab.kept = kept
            tab.nest = nest
        }
        browser.move(tab, to: min(landing.index, browser.tabs.count - 1))
        if changed { browser.folderBook.refresh() }
        browser.writeSession(now: true)
    }

    // MARK: - going

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Into another window: over its tabs the card was a row again, and
    /// the row goes where the line is.
    private func land(in browser: Browser, at landing: TearRules.Landing) {
        retire(to: nil)
    }

    /// A new window: the card grows into it as it comes in.
    private func grow(into window: NSWindow) {
        guard panel != nil, !still else { put(away: false); return }
        let end = window.frame.insetBy(dx: -(Self.margin + CardFrame.inset), dy: -(Self.margin + CardFrame.inset))
        // The card fills the panel as the panel grows.
        card.fill = true
        window.alphaValue = 0
        // On the next turn, once the new window is up: making it holds the
        // main thread some 200 ms (Oct 16, macOS 27), and an animation
        // begun in this turn counts from the let-go, so it was over before
        // its first frame and the card jumped into the window.
        DispatchQueue.main.async { [self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                window.animator().alphaValue = 1
            }
            retire(to: end)
        }
    }

    /// The card fading as it goes to `end`, or where it is; the line at once.
    private func retire(to end: CGRect?) {
        guard let panel else { return }
        refresh?.invalidate()
        refresh = nil
        target = nil
        line?.orderOut(nil)
        line = nil
        self.panel = nil
        guard !still else { panel.orderOut(nil); return }
        leaving = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = end == nil ? 0.16 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            if let end { panel.animator().setFrame(end, display: true) }
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                if self.leaving === panel { self.leaving = nil }
            }
        }
    }

    /// Back inside the window, or let go of for nothing: the card goes
    /// back into a row as it fades, the column's own row taking over.
    private func put(away fading: Bool) {
        if fading {
            if !still, panel != nil { withAnimation(TearCard.morph) { card.shown = false } }
            retire(to: nil)
        } else {
            refresh?.invalidate()
            refresh = nil
            target = nil
            line?.orderOut(nil)
            line = nil
            panel?.orderOut(nil)
            panel = nil
        }
    }

    /// The row the card grows out of, in the card's space: a column row's
    /// size, under the hand at about where the hand took it, never so far
    /// past the card that the panel's room cuts it.
    static func row(picture: CGSize, grip: UnitPoint, grab: CGPoint) -> CGRect {
        let full = CGSize(width: picture.width + 2 * CardFrame.inset, height: picture.height + 2 * CardFrame.inset)
        let size = CGSize(width: min(TearCard.rowWidth, full.width), height: TearCard.rowHeight)
        let hand = CGPoint(x: CardFrame.inset + grip.x * picture.width, y: CardFrame.inset + grip.y * picture.height)
        let along = min(max((grab.x - CardFrame.inset) / size.width, 0.1), 0.9)
        let room = margin - 4
        let x = min(max(hand.x - along * size.width, -room), full.width + room - size.width)
        let y = min(max(hand.y - size.height / 2, -room), full.height + room - size.height)
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    // MARK: - pieces

    private static func panel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    /// A rect in a window's SwiftUI global space, the rows', on the screen.
    static func screen(_ rect: CGRect, in browser: Browser) -> CGRect {
        guard let anchor = browser.keySky.groundView, let window = anchor.window else { return rect }
        let ground = browser.keySky.ground
        return window.convertToScreen(anchor.convert(rect.offsetBy(dx: -ground.x, dy: -ground.y), to: nil))
    }

    /// Where the hand is, on the screen: the drag's own event's, so a
    /// drag the bench hands the window counts as the mouse's would.
    static func pointer(in window: NSWindow, event: NSEvent? = nil) -> CGPoint {
        if let event = event ?? NSApp.currentEvent, event.window === window,
           [.leftMouseDragged, .leftMouseUp, .leftMouseDown].contains(event.type) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }
}

@MainActor
final class TearCardModel: ObservableObject {
    @Published var image: NSImage?
    @Published var title = ""
    @Published var icon: NSImage?
    @Published var monogram = ""
    /// Grown from the row into the card.
    @Published var shown = false
    /// Over another window's tabs: a row again, for the line.
    @Published var over = false
    /// Growing into the new window: the card fills the panel.
    @Published var fill = false
    /// Where in the window it was taken, from its top-left, as a fraction.
    var grip = UnitPoint(x: 0.5, y: 0)
    /// The picture's size, and the row it grows out of, in the card's space.
    var picture = CGSize(width: 240, height: 160)
    var row = CGRect(x: 0, y: 0, width: 220, height: 32)
}

/// The page in small, on a card, as the window it is about to be. It
/// starts as the tab's row under the hand and grows into the card, one
/// thing all along, as Arc's does (recorded 2026-10-13: the card's shape
/// in 0.1 s, settled by 0.18, no give); the row's words blur away as the
/// page comes up out of a blur. Over another window's tabs it is a row
/// again, and back inside its own window it goes back into one as it fades.
struct TearCard: View {
    @ObservedObject var model: TearCardModel

    static let morph = Animation.spring(response: 0.2, dampingFraction: 1)
    static let rowWidth: CGFloat = 220
    static let rowHeight: CGFloat = 32

    private var grown: Bool { model.fill || (model.shown && !model.over) }

    private var full: CGSize {
        CGSize(width: model.picture.width + 2 * CardFrame.inset, height: model.picture.height + 2 * CardFrame.inset)
    }

    var body: some View {
        let rect = grown ? CGRect(origin: .zero, size: full) : model.row
        let corner = grown ? Radius.card : Radius.control + 2
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: model.fill ? nil : model.picture.width, height: model.fill ? nil : model.picture.height)
                .padding(CardFrame.inset)
                .opacity(grown ? 1 : 0)
                .blur(radius: grown ? 0 : 6)
            face
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .opacity(grown ? 0 : 1)
                .blur(radius: grown ? 4 : 0)
        }
        .frame(width: model.fill ? nil : rect.width, height: model.fill ? nil : rect.height, alignment: .topLeading)
        .frame(maxWidth: model.fill ? .infinity : nil, maxHeight: model.fill ? .infinity : nil, alignment: .topLeading)
        .clipShape(shape)
        .shapeFrame(corner)
        .offset(x: model.fill ? 0 : rect.minX, y: model.fill ? 0 : rect.minY)
        .frame(width: model.fill ? nil : full.width, height: model.fill ? nil : full.height, alignment: .topLeading)
        .frame(maxWidth: model.fill ? .infinity : nil, maxHeight: model.fill ? .infinity : nil, alignment: .topLeading)
    }

    private var picture: some View {
        ZStack {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text(model.title)
                    .font(CardFrame.title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(CardFrame.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// The row as the column draws it: the site's mark and the title.
    private var face: some View {
        HStack(spacing: 8) {
            Mark(icon: model.icon, letter: model.monogram, size: 14)
            Text(model.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
    }
}

/// Where the window's top-left is in SwiftUI's global space, which the
/// rows are measured in, and an AppKit view laid over the same room: from
/// the two, a row's place on the screen, and the pointer's in the rows'
/// space, whatever the hosting view's own geometry is.
struct TearGround: View {
    let sky: KeySky

    var body: some View {
        Anchor(sky: sky)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { [sky] in sky.ground = $0 }
    }

    private struct Anchor: NSViewRepresentable {
        let sky: KeySky

        func makeNSView(context: Context) -> NSView {
            let view = Flipped()
            sky.groundView = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            if sky.groundView !== view { sky.groundView = view }
        }
    }

    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

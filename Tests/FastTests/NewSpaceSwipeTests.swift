import AppKit
import Testing
@testable import Fast

// Two fingers past the last space, through the column's own catch: only a
// lift with the ring held full, in the window and on the space that filled
// it, opens New Space (NewSpacePlus).
@MainActor @Suite(.serialized)
struct NewSpaceSwipeTests {
    private final class Fingers: NSEvent {
        var target: NSWindow!
        var point = NSPoint.zero
        var dx: CGFloat = 0
        var at: TimeInterval = 0
        var gesture: NSEvent.Phase = []
        var glide: NSEvent.Phase = []
        override var type: NSEvent.EventType { .scrollWheel }
        override var phase: NSEvent.Phase { gesture }
        override var momentumPhase: NSEvent.Phase { glide }
        override var scrollingDeltaX: CGFloat { dx }
        override var scrollingDeltaY: CGFloat { 0 }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var window: NSWindow? { target }
        override var locationInWindow: NSPoint { point }
        override var timestamp: TimeInterval { at }
    }

    /// A window that says when it is asked to take the keys, without
    /// coming onto the screen to do it.
    private final class KeyWindow: NSWindow {
        var keyed = 0
        override var canBecomeKey: Bool { true }
        override func makeKeyAndOrderFront(_ sender: Any?) { keyed += 1 }
    }

    @MainActor private struct World {
        let browser: Browser
        let catcher: SpaceSwipe.Catch
        let window: NSWindow
        let ids: [UUID]
        var clock: TimeInterval = 1000

        /// One event of the fingers over the column.
        mutating func send(_ phase: NSEvent.Phase, dx: CGFloat = 0, glide: NSEvent.Phase = [], after: TimeInterval = 1.0 / 60) {
            clock += after
            let event = Fingers()
            event.target = window
            event.point = NSPoint(x: catcher.frame.midX, y: 300)
            event.dx = dx
            event.at = clock
            event.gesture = phase
            event.glide = glide
            _ = catcher.heard(event)
        }

        /// Fingers down and `travel` points toward the next space, not lifted.
        mutating func pull(_ travel: CGFloat) {
            send(.began)
            let steps = 20
            for _ in 0..<steps { send(.changed, dx: travel / CGFloat(steps)) }
        }
    }

    private func world(on place: Int, still: Bool, _ body: (inout World) throws -> Void) throws {
        _ = NSApplication.shared
        let saved = Spaces.read()
        let browser = Browser(windowID: UUID())
        let old = (browser.prefs.sidebar, browser.prefs.sideShut, browser.prefs.usesSpaces, SpaceTurn.still)
        let ids = [UUID(), UUID()]
        browser.prefs.sidebar = true; browser.prefs.sideShut = false; browser.prefs.usesSpaces = true
        browser.spaces = ids.enumerated().map { Space(id: $0.element, name: "Plus \($0.offset)", icon: "", ownSignIns: false) }
        browser.spaceID = ids[place]
        // Unpaged, the way Reduce Motion goes; paged where the row can be raised.
        SpaceTurn.still = still
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        root.wantsLayer = true
        window.contentView = root
        let column = ColumnView(browser: browser)
        column.frame = root.bounds
        root.addSubview(column)
        let catcher = SpaceSwipe.Catch(frame: NSRect(x: 0, y: 0, width: 240, height: 650))
        catcher.browser = browser; catcher.column = true
        root.addSubview(catcher)
        // The space's dot in the foot, where the tray grows from.
        let dot = SpaceAnchor.Mark(.dot)
        dot.frame = NSRect(x: 110, y: 12, width: 20, height: 20)
        root.addSubview(dot)
        column.slide(out: true, animated: false)
        // Where the space's part of the column is, as SwiftUI reports it.
        browser.rowsClip = CGRect(x: 0, y: 120, width: 240, height: 420)
        browser.spaceFloor = 560
        defer {
            SpaceTray.shown?.leave()
            NewSpacePlus.shared.begin()
            catcher.removeFromSuperview(); window.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.sidebar = old.0; browser.prefs.sideShut = old.1; browser.prefs.usesSpaces = old.2
            SpaceTurn.still = old.3
            Spaces.write(saved)
        }
        try #require(catcher.acceptsInput)
        var world = World(browser: browser, catcher: catcher, window: window, ids: ids)
        try body(&world)
    }

    @Test(arguments: [true, false])
    func aRingHeldFullOpensTheTrayOnce(still: Bool) throws {
        try world(on: 1, still: still) { w in
            try #require(SpaceTray.shown == nil)
            w.pull(-340)
            #expect(NewSpacePlus.shared.armed)
            #expect(SpaceSwipe.trace.last { $0.hasPrefix("grab") }?.hasPrefix("grab \(!still)") == true, "\(SpaceSwipe.trace)")
            w.send(.ended, after: 0.3)
            let tray = try #require(SpaceTray.shown, "no tray came up")
            #expect(tray.window === w.window)
            #expect(tray.draft.step == .name)
            #expect(!NewSpacePlus.shared.armed)
            // The glide after the lift makes nothing more.
            w.send([], dx: -30, glide: .began)
            w.send([], dx: -20, glide: .changed)
            w.send([], glide: .ended)
            #expect(SpaceTray.shown === tray)
        }
    }

    @Test(arguments: [true, false])
    func theTrayOpensInTheWindowSwipedOverNotTheKeyOne(still: Bool) throws {
        try world(on: 1, still: still) { front in
            let saved = Links.window
            defer { Links.window = saved }
            try world(on: 1, still: still) { behind in
                // The other window is the one in front; the fingers are over
                // this one, which scrolls without coming forward.
                Links.window = front.window
                behind.pull(-340)
                behind.send(.ended, after: 0.3)
                let tray = try #require(SpaceTray.shown, "no tray came up")
                #expect(tray.window === behind.window)
                #expect(tray.window !== front.window)
                // And the keys go there, for its name.
                #expect((behind.window as? KeyWindow)?.keyed == 1)
                #expect((front.window as? KeyWindow)?.keyed == 0)
            }
        }
    }

    @Test(arguments: [true, false])
    func shortOrQuickOrCancelledOpensNothing(still: Bool) throws {
        try world(on: 1, still: still) { w in
            // Short of full, held a long while.
            w.pull(-200)
            #expect(!NewSpacePlus.shared.armed)
            w.send(.ended, after: 1)
            // Full, lifted the moment it filled.
            w.pull(-340)
            w.send(.ended, after: 1.0 / 60)
            // Full and held, then cancelled rather than lifted.
            w.pull(-340)
            w.send(.cancelled, after: 0.3)
            #expect(!NewSpacePlus.shared.armed)
            // Full, then pulled back short of it before the lift.
            w.pull(-340)
            for _ in 0..<6 { w.send(.changed, dx: 10) }
            w.send(.ended, after: 0.3)
            #expect(SpaceTray.shown == nil)
        }
    }

    @Test(arguments: [true, false])
    func aLostGestureIsNotTakenByAnotherWindow(still: Bool) throws {
        try world(on: 1, still: still) { a in
            // Filled in one window, its end gone to another desktop.
            a.pull(-340)
            #expect(NewSpacePlus.shared.armed)
            a.send([], dx: -30, glide: .began, after: 0.3)
            try world(on: 0, still: still) { b in
                // A short swipe from the first space of another window.
                b.pull(-40)
                #expect(!NewSpacePlus.shared.armed)
                b.send(.ended, after: 0.3)
                #expect(SpaceTray.shown == nil)
            }
        }
    }

    @Test(arguments: [true, false])
    func aSpaceChangedUnderTheFingersOpensNothing(still: Bool) throws {
        try world(on: 1, still: still) { w in
            w.pull(-340)
            #expect(NewSpacePlus.shared.armed)
            // ⌃1 while the fingers hold.
            w.browser.switchSpace(to: w.ids[0])
            #expect(!NewSpacePlus.shared.armed)
            w.send(.ended, after: 0.3)
            // ⌃1 and ⌃2 while they hold, then a little further and held:
            // the same fingers fill nothing again.
            w.pull(-340)
            w.browser.switchSpace(to: w.ids[0])
            w.browser.switchSpace(to: w.ids[1])
            w.send(.changed, dx: -5)
            #expect(!NewSpacePlus.shared.armed)
            w.send(.ended, after: 0.3)
            // Spaces turned off while they hold.
            w.pull(-340)
            w.browser.prefs.usesSpaces = false
            w.send(.ended, after: 0.3)
            #expect(SpaceTray.shown == nil)
        }
    }

    @Test func nothingArmsWithoutAColumnToShowItIn() throws {
        try world(on: 1, still: true) { w in
            w.browser.rowsClip = nil
            w.pull(-340)
            #expect(!NewSpacePlus.shared.armed)
            w.send(.ended, after: 0.3)
            #expect(SpaceTray.shown == nil)
        }
    }
}

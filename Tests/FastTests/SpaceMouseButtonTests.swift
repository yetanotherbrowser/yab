import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct SpaceMouseButtonTests {
    private final class MouseSwipe: NSEvent {
        var target: NSWindow!
        var point = NSPoint.zero
        var horizontal: CGFloat = 0
        override var type: NSEvent.EventType { .swipe }
        override var phase: NSEvent.Phase { [] }
        override var momentumPhase: NSEvent.Phase { [] }
        override var scrollingDeltaX: CGFloat { 0 }
        override var scrollingDeltaY: CGFloat { 0 }
        override var hasPreciseScrollingDeltas: Bool { false }
        override var window: NSWindow? { target }
        override var locationInWindow: NSPoint { point }
        override var deltaX: CGFloat { horizontal }
        override var deltaY: CGFloat { 0 }
    }

    private final class TrackpadMove: NSEvent {
        var target: NSWindow!
        var point = NSPoint.zero
        var move = CGVector.zero
        var fingers: NSEvent.Phase = []
        var glide: NSEvent.Phase = []
        var time: TimeInterval = 0
        override var type: NSEvent.EventType { .scrollWheel }
        override var phase: NSEvent.Phase { fingers }
        override var momentumPhase: NSEvent.Phase { glide }
        override var scrollingDeltaX: CGFloat { move.dx }
        override var scrollingDeltaY: CGFloat { move.dy }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var window: NSWindow? { target }
        override var locationInWindow: NSPoint { point }
        override var timestamp: TimeInterval { time }
    }

    @Test func aSidewaysSwipesGlideNeverScrollsTheRows() throws {
        try world(.left) { _, _, catcher, window, _ in
            let move = TrackpadMove()
            move.target = window
            move.point = NSPoint(x: catcher.frame.midX, y: 300)
            func hear(_ fingers: NSEvent.Phase, _ glide: NSEvent.Phase = [], dx: CGFloat = 0, dy: CGFloat = 0) -> Bool {
                move.fingers = fingers; move.glide = glide; move.move = CGVector(dx: dx, dy: dy); move.time += 0.016
                return catcher.heard(move) == nil
            }
            #expect(!hear(.began))
            #expect(hear(.changed, dx: -3))
            #expect(hear(.ended))
            for glide: NSEvent.Phase in [.began, .changed, .changed, .ended] {
                #expect(hear([], glide, dx: -8, dy: 2), "the glide after a sideways swipe is the row of spaces'")
            }
            // The rows' own scroll and its glide still reach them.
            #expect(!hear(.began))
            #expect(!hear(.changed, dy: 20))
            #expect(!hear(.ended))
            #expect(!hear([], .began, dy: 20))
            #expect(!hear([], .changed, dy: 20))
        }
    }

    @Test(arguments: [Flank.left, .right])
    func mouseSwipesUseSidebarSpaceActions(_ flank: Flank) throws {
        try world(flank) { browser, column, catcher, window, ids in
            let swipe = MouseSwipe()
            swipe.target = window
            swipe.point = NSPoint(x: catcher.frame.midX, y: 300)
            swipe.horizontal = 1
            #expect(catcher.heard(swipe) == nil)
            #expect(browser.spaceID == ids[0])
            swipe.horizontal = -1
            #expect(catcher.heard(swipe) == nil)
            #expect(browser.spaceID == ids[1])
            swipe.point.x = 450
            #expect(catcher.heard(swipe) === swipe)
            #expect(browser.spaceID == ids[1])
            swipe.point.x = catcher.frame.midX
            column.slide(out: false, animated: false)
            #expect(catcher.heard(swipe) === swipe)
            column.slide(out: true, animated: false)
            swipe.horizontal = 0
            #expect(catcher.heard(swipe) === swipe, "vertical swipes are not space navigation")
            swipe.horizontal = 1
            browser.prefs.usesSpaces = false
            #expect(catcher.heard(swipe) === swipe)
            browser.prefs.usesSpaces = true
            catcher.column = false
            #expect(catcher.heard(swipe) === swipe)
        }
    }

    private func event(_ type: NSEvent.EventType, button: Int, window: NSWindow, at point: NSPoint) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil,
            mouseType: type == .otherMouseDown ? .otherMouseDown : .otherMouseUp,
            mouseCursorPosition: .zero, mouseButton: .center))
        cg.flags = []
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        unsafeBitCast(symbol, to: Place.self)(cg, CGPoint(x: point.x, y: window.contentView!.bounds.height - point.y))
        let event = try #require(NSEvent(cgEvent: cg))
        try #require(event.window === window && event.buttonNumber == button)
        return event
    }

    private func world(_ flank: Flank, _ body: (Browser, ColumnView, SpaceSwipe.Catch, NSWindow, [UUID]) throws -> Void) throws {
        _ = NSApplication.shared
        let saved = Spaces.read()
        let browser = Browser(windowID: UUID())
        let old = (browser.prefs.sidebar, browser.prefs.sideShut, browser.prefs.usesSpaces, browser.prefs.sideFlank)
        let ids = [UUID(), UUID(), UUID()]
        browser.prefs.sidebar = true; browser.prefs.sideShut = false
        browser.prefs.usesSpaces = true; browser.prefs.sideFlank = flank
        browser.spaces = ids.enumerated().map { Space(id: $0.element, name: "Mouse \($0.offset)", icon: "", ownSignIns: false) }
        browser.spaceID = ids[1]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        root.wantsLayer = true
        window.contentView = root
        let column = ColumnView(browser: browser)
        column.frame = root.bounds
        root.addSubview(column)
        let catcher = SpaceSwipe.Catch(frame: NSRect(x: flank == .left ? 0 : 660, y: 0, width: 240, height: 650))
        catcher.browser = browser; catcher.column = true
        root.addSubview(catcher)
        column.slide(out: true, animated: false)
        defer {
            catcher.removeFromSuperview(); window.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.sidebar = old.0; browser.prefs.sideShut = old.1
            browser.prefs.usesSpaces = old.2; browser.prefs.sideFlank = old.3
            Spaces.write(saved)
        }
        try #require(catcher.acceptsInput)
        try body(browser, column, catcher, window, ids)
    }

    @Test(arguments: [Flank.left, .right])
    func sidebarButtonsUseTheExistingSpaceActions(_ flank: Flank) throws {
        try world(flank) { browser, _, catcher, window, ids in
            let inside = NSPoint(x: catcher.frame.midX, y: 300)
            let backDown = try event(.otherMouseDown, button: 3, window: window, at: inside)
            #expect(catcher.heard(backDown) == nil)
            #expect(browser.spaceID == ids[0])
            // Release belongs to the sidebar even after crossing onto the page.
            let backUp = try event(.otherMouseUp, button: 3, window: window, at: NSPoint(x: 450, y: 300))
            #expect(catcher.heard(backUp) == nil)
            let forwardDown = try event(.otherMouseDown, button: 4, window: window, at: inside)
            #expect(catcher.heard(forwardDown) == nil)
            #expect(browser.spaceID == ids[1])
            let forwardUp = try event(.otherMouseUp, button: 4, window: window, at: inside)
            #expect(catcher.heard(forwardUp) == nil)
            #expect(browser.spaceID == ids[1], "a release never switches twice")
        }
    }

    @Test(arguments: [Flank.left, .right])
    func pageAndUnavailableSidebarKeepTheirEvents(_ flank: Flank) throws {
        try world(flank) { browser, column, catcher, window, ids in
            let inside = NSPoint(x: catcher.frame.midX, y: 300)
            let outside = try event(.otherMouseDown, button: 3, window: window, at: NSPoint(x: 450, y: 300))
            #expect(catcher.heard(outside) === outside)
            let middle = try event(.otherMouseDown, button: 2, window: window, at: inside)
            #expect(catcher.heard(middle) === middle)
            column.slide(out: false, animated: false)
            let hidden = try event(.otherMouseDown, button: 3, window: window, at: inside)
            #expect(catcher.heard(hidden) === hidden)
            column.slide(out: true, animated: false)
            browser.prefs.usesSpaces = false
            #expect(catcher.heard(hidden) === hidden)
            browser.prefs.usesSpaces = true
            catcher.column = false
            #expect(catcher.heard(hidden) === hidden, "the top tab strip does not take page navigation buttons")
            #expect(browser.spaceID == ids[1])
        }
    }
}

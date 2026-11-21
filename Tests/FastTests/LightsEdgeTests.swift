import AppKit
import CoreGraphics
import Testing
@testable import Fast

// A put-away column brought out from the window's left edge (bug #37): a
// window inset from the screen's edge lets the pointer run past it, and
// Brim, looking thirty times a second, saw it only before the edge or after.
// Its rest there and its going are Dia's (evals/side-peek/hover.py).
struct LightsEdgeTests {
    static let height: CGFloat = 780

    static func wall(_ x: CGFloat, _ y: CGFloat, last: CGPoint? = nil) -> Bool {
        EdgeReach.wall(CGPoint(x: x, y: y), last: last, height: height)
    }

    @Test func theVeryEdgeIsAWall() {
        #expect(Self.wall(0, 300))
        #expect(Self.wall(Metrics.edgeWall, 300))
        #expect(!Self.wall(Metrics.edgeWall + 1, 300))
        #expect(!Self.wall(400, 300, last: CGPoint(x: 600, y: 300)))
    }

    private struct Pointer {
        var now: CFTimeInterval = 100
        var point = CGPoint(x: 300, y: 300)
        var dwell = EdgeReach.Dwell()

        mutating func look() -> Bool {
            let edge = EdgeReach.at(point, past: false, height: LightsEdgeTests.height)
            let rest = EdgeReach.rest(edge: edge)
            return dwell.remaining(rest: rest, now: now) == 0
        }

        mutating func move(to point: CGPoint) -> Bool {
            self.point = point
            return look()
        }

        mutating func advance(_ seconds: CFTimeInterval) -> Bool {
            now += seconds
            return look()
        }
    }

    @Test func restingAtTheEdgeForPointThreeFiveSecondsOpens() {
        var pointer = Pointer()
        let onPage = pointer.look()
        #expect(!onPage)
        #expect(pointer.dwell.until == nil)
        let entered = pointer.move(to: CGPoint(x: 3, y: 300))
        #expect(!entered)
        let beforeDeadline = pointer.advance(0.29)
        #expect(!beforeDeadline)
        let rested = pointer.advance(0.06)
        #expect(rested)
    }

    @Test func passingThroughTheEdgeForPointOneSecondsDoesNotOpen() {
        var pointer = Pointer()
        let entered = pointer.move(to: CGPoint(x: 3, y: 300))
        #expect(!entered)
        let passing = pointer.advance(0.1)
        #expect(!passing)
        let left = pointer.move(to: CGPoint(x: 300, y: 300))
        #expect(!left)
        #expect(pointer.dwell.until == nil)
        let onPage = pointer.advance(0.35)
        #expect(!onPage)
        #expect(pointer.dwell.until == nil)
        // Coming back starts a full rest, without credit for the first pass.
        let returned = pointer.move(to: CGPoint(x: 3, y: 300))
        #expect(!returned)
        let beforeDeadline = pointer.advance(0.1)
        #expect(!beforeDeadline)
        let rested = pointer.advance(0.25)
        #expect(rested)
    }

    @Test func comingInFromOutsideThenRestingOpens() {
        for outside in [CGPoint(x: -40, y: 300), CGPoint(x: 3, y: -40), CGPoint(x: 3, y: Self.height + 40)] {
            var pointer = Pointer()
            let left = pointer.move(to: outside)
            #expect(!left)
            let waitedOutside = pointer.advance(0.35)
            #expect(!waitedOutside)
            #expect(pointer.dwell.until == nil)
            let entered = pointer.move(to: CGPoint(x: 3, y: 300))
            #expect(!entered)
            let beforeDeadline = pointer.advance(0.1)
            #expect(!beforeDeadline)
            let rested = pointer.advance(0.25)
            #expect(rested)
        }
    }

    @Test func leavingTheEdgeForOutsideCancelsTheRest() {
        var pointer = Pointer()
        let entered = pointer.move(to: CGPoint(x: 3, y: 300))
        #expect(!entered)
        let passing = pointer.advance(0.1)
        #expect(!passing)
        let left = pointer.move(to: CGPoint(x: 3, y: -40))
        #expect(!left)
        #expect(pointer.dwell.until == nil)
        let waitedOutside = pointer.advance(0.35)
        #expect(!waitedOutside)
    }

    @Test func movingFromTheCornerToTheEdgeStartsTheEdgesRest() {
        var dwell = EdgeReach.Dwell()
        var now: CFTimeInterval = 100
        let corner = dwell.remaining(rest: EdgeReach.cornerRest, now: now)
        #expect(corner != 0)
        now += 0.25
        let enteredEdge = dwell.remaining(rest: EdgeReach.edgeRest, now: now)
        #expect(enteredEdge != 0)
        now += 0.1
        let beforeDeadline = dwell.remaining(rest: EdgeReach.edgeRest, now: now)
        #expect(beforeDeadline != 0)
        now += 0.25
        let rested = dwell.remaining(rest: EdgeReach.edgeRest, now: now)
        #expect(rested == 0)
    }

    @Test func runningOutPastTheEdgeReachesIt() {
        // Just past it, from a look on the page.
        #expect(Self.wall(-30, 300, last: CGPoint(x: 300, y: 300)))
        // One flick from the middle of the page, out in one look.
        #expect(Self.wall(-200, 300, last: CGPoint(x: 600, y: 320)))
        // From the strip, slowly.
        #expect(Self.wall(-2, 300, last: CGPoint(x: 6, y: 300)))
    }

    @Test func otherWaysOutAndInDoNot() {
        // Outside with nothing to say where it came from.
        #expect(!Self.wall(-30, 300))
        // Out over the top, or the bottom, the line crossed above the window.
        #expect(!Self.wall(300, -60, last: CGPoint(x: 300, y: 300)))
        #expect(!Self.wall(-10, -40, last: CGPoint(x: 30, y: 5)))
        #expect(!Self.wall(-10, Self.height + 30, last: CGPoint(x: 20, y: Self.height - 5)))
        // Still outside, or coming in from there.
        #expect(!Self.wall(-50, 300, last: CGPoint(x: -60, y: 300)))
        #expect(!Self.wall(400, 300, last: CGPoint(x: -60, y: 300)))
    }

    // Out past the edge beside the window, having gone through it, is at
    // the edge, as Dia has it; out there with nothing to say how is not.
    @Test func pastTheEdgeBesideTheWindowIsAtIt() {
        func at(_ x: CGFloat, _ y: CGFloat, past: Bool) -> Bool {
            EdgeReach.at(CGPoint(x: x, y: y), past: past, height: Self.height)
        }
        #expect(at(0, 300, past: false))
        #expect(at(Metrics.edgeWall, 300, past: false))
        #expect(!at(8, 300, past: false))
        #expect(!at(12, 300, past: false))
        #expect(!at(13, 300, past: false))
        #expect(!at(13, 300, past: true))
        #expect(!at(8, -1, past: false))
        #expect(!at(8, Self.height + 1, past: false))
        #expect(at(-20, 300, past: true))
        #expect(at(-200, 300, past: true))
        #expect(!at(-20, 300, past: false))
        #expect(!at(-20, -10, past: true))
        #expect(!at(-20, Self.height + 10, past: true))
    }

    @Test func aHandPastTheEdgeKeepsTheCard() {
        let reach: CGFloat = 400
        func keeps(_ x: CGFloat, _ y: CGFloat, full: Bool = false) -> Bool {
            EdgeReach.keeps(CGPoint(x: x, y: y), reach: reach, height: Self.height, full: full)
        }
        #expect(keeps(200, 300))
        #expect(keeps(reach, 300))
        #expect(!keeps(reach + 1, 300))
        #expect(keeps(-20, 300))
        // Dia's card stayed with the pointer 200 points out past the edge.
        #expect(keeps(-200, 300))
        #expect(!keeps(-20, -10))
        #expect(!keeps(200, Self.height + 10))
        // In full screen, as before: anywhere left of reach.
        #expect(keeps(-500, -10, full: true))
        #expect(!keeps(reach + 1, 300, full: true))
    }

    // A tester's report (2026-10-13): a display arranged to the left of the
    // Mac's, the window flush with the Mac's left edge. Going over to that
    // display went out past the edge, which brought the column out, and
    // kept it out while the pointer was over there.
    @Test func anotherDisplayBesideTheEdgeIsNotTheEdge() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let flush = CGRect(x: 0, y: 100, width: 1200, height: Self.height)
        // Over on the display to the left, beside the window or not.
        #expect(EdgeReach.away(CGPoint(x: -1, y: 400), window: flush, screen: laptop))
        #expect(EdgeReach.away(CGPoint(x: -600, y: 400), window: flush, screen: laptop))
        // On the window's own screen: in it, at its edge, or beside it.
        #expect(!EdgeReach.away(CGPoint(x: 0, y: 400), window: flush, screen: laptop))
        #expect(!EdgeReach.away(CGPoint(x: 600, y: 400), window: flush, screen: laptop))
        #expect(!EdgeReach.away(CGPoint(x: 1400, y: 400), window: flush, screen: laptop))
        // A window inset from the screen's edge: past it is still this screen.
        let inset = CGRect(x: 200, y: 100, width: 1000, height: Self.height)
        #expect(!EdgeReach.away(CGPoint(x: 50, y: 400), window: inset, screen: laptop))
        #expect(EdgeReach.away(CGPoint(x: -50, y: 400), window: inset, screen: laptop))
        // A window hanging over onto the display to the left: in it is in it.
        let spanning = CGRect(x: -300, y: 100, width: 1200, height: Self.height)
        #expect(!EdgeReach.away(CGPoint(x: -100, y: 400), window: spanning, screen: laptop))
        #expect(EdgeReach.away(CGPoint(x: -400, y: 400), window: spanning, screen: laptop))
        // No screen known: nothing is away.
        #expect(!EdgeReach.away(CGPoint(x: -600, y: 400), window: flush, screen: nil))
    }

    /// #1024: a window tiled beside this one, out past its edge, is not the
    /// edge: a rest over it brings nothing. Empty desktop out there still is.
    @Test func aWindowBesideTheEdgeIsNotTheEdge() {
        // 9 is another app's window, 12 another of Yab's, 5 the desktop's.
        let ordinary: Set<Int> = [9, 12]
        func covered(top: Int, own: Set<Int> = [7, 8]) -> Bool {
            EdgeReach.covered(top: top, own: own, ordinary: { ordinary.contains($0) })
        }
        #expect(covered(top: 9))
        #expect(covered(top: 12))
        // Nothing under the pointer, or the desktop's own window.
        #expect(!covered(top: 0))
        #expect(!covered(top: 5))
        // The window itself, or a child window of its own.
        #expect(!covered(top: 7))
        #expect(!covered(top: 8))
    }

    /// #786: a window behind another app's is watched while the pointer is
    /// over it and nothing covers it there, so a rest at its edge brings
    /// its column out with no click first.
    @Test func aWindowBehindIsWatchedOnlyUnderThePointer() {
        let frame = CGRect(x: 300, y: 200, width: 1100, height: 700)
        let edge = CGPoint(x: 301, y: 500), beside = CGPoint(x: 250, y: 500)
        func watches(front: Bool = false, onScreen: Bool = true, at pointer: CGPoint = edge,
                     top: Int = 7, own: Set<Int> = [7]) -> Bool {
            EdgeReach.watches(front: front, onScreen: onScreen, frame: frame, pointer: pointer, top: top, own: own)
        }
        // In front, wherever the pointer is: past the edge beside it too.
        #expect(watches(front: true, at: beside, top: 9))
        // Behind, the pointer over it and nothing over it there.
        #expect(watches())
        // A child window of its own under the pointer is the window's.
        #expect(watches(top: 8, own: [7, 8]))
        // Another app's window over it there.
        #expect(!watches(top: 9))
        // The pointer beside it, on another window.
        #expect(!watches(at: beside))
        // Minimized, hidden or on another desktop.
        #expect(!watches(onScreen: false))
    }

    /// The window server is asked what is under the pointer only once the
    /// pointer is inside a window behind: thirty looks a second ask it
    /// nothing while the pointer is elsewhere, or the window is in front.
    @Test func theWindowServerIsAskedOnlyForAPointerInsideAWindowBehind() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var asked = 0
        func top() -> Int { asked += 1; return 1 }
        let elsewhere = EdgeReach.watches(front: false, onScreen: true, frame: frame, pointer: CGPoint(x: 500, y: 500), top: top(), own: [1])
        let inFront = EdgeReach.watches(front: true, onScreen: true, frame: frame, pointer: CGPoint(x: 50, y: 50), top: top(), own: [1])
        #expect(!elsewhere && inFront && asked == 0)
        let inside = EdgeReach.watches(front: false, onScreen: true, frame: frame, pointer: CGPoint(x: 50, y: 50), top: top(), own: [1])
        #expect(inside && asked == 1)
    }

    @Test func pageControlsInTheCornerNeverRevealTheColumn() {
        for x in [CGFloat(4), 8, 12, 20, 38, 60] {
            for y in [CGFloat(8), 24, 40, 300] {
                let edge = EdgeReach.at(CGPoint(x: x, y: y), past: false, height: Self.height)
                #expect(!edge)
                #expect(EdgeReach.rest(edge: edge) == nil)
            }
        }
        #expect(EdgeReach.rest(edge: true) == EdgeReach.edgeRest)
    }

    @Test func theColumnWaitsWithoutChangingTheStripOrMotion() {
        #expect(EdgeReach.edgeRest == 0.3)
        #expect(TopReach.edgeRest == 0.15)
        #expect(EdgeReach.letGo < 0.13)
        #expect(Metrics.edgeWall == 3)
        #expect(CardMotion.arriving().duration < 0.4)
        #expect(CardMotion.leaving().duration < 0.15)
    }

    // Bug #64: the lights' hover area was taken from the buttons' frames
    // before the first layout had moved them into place, and hovering them
    // showed no marks, or only the zoom button's.
    @MainActor @Test func theLightsShowTheirMarksWhereverLayoutPutsThem() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        let row = LightsRow(frame: NSRect(x: 20, y: 20, width: Lights.run, height: Metrics.strip))
        window.contentView?.addSubview(row)
        row.updateTrackingAreas()
        row.layoutSubtreeIfNeeded()
        let buttons = row.subviews.compactMap { $0 as? NSButton }
        try #require(buttons.count == 3)
        // Laid out across the row, not where they were made.
        #expect(buttons[1].frame.minX > buttons[0].frame.maxX)
        #expect(buttons[0].frame.minY > 0)

        // One area over the whole row, whatever its size or the buttons'.
        let area = try #require(row.trackingAreas.first)
        #expect(area.options.contains(.inVisibleRect))
        #expect(area.options.contains(.mouseMoved))

        func move(to view: NSView, at point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )!
            row.mouseMoved(with: event)
        }
        // Over the minimize button, all three show their marks: each one is
        // told to look again and asks, as the title bar has its own do
        // (feedback #64), not only drawn again with the look it had.
        let before = row.asked
        move(to: buttons[1], at: NSPoint(x: buttons[1].bounds.midX, y: buttons[1].bounds.midY))
        #expect(row.asked - before >= 3)
        #expect(buttons.allSatisfy { row._mouseInGroup($0) })
        // Leaving them, they ask again, and put the marks away.
        let over = row.asked
        move(to: row, at: NSPoint(x: buttons[1].frame.midX, y: 1))
        #expect(row.asked - over >= 3)
        move(to: buttons[1], at: NSPoint(x: buttons[1].bounds.midX, y: buttons[1].bounds.midY))
        // In the row's air above them, none.
        move(to: row, at: NSPoint(x: buttons[1].frame.midX, y: 1))
        #expect(!row._mouseInGroup(buttons[1]))
        // Back over the close button, then out of the row.
        move(to: buttons[0], at: NSPoint(x: buttons[0].bounds.midX, y: buttons[0].bounds.midY))
        #expect(row._mouseInGroup(buttons[2]))
        row.mouseExited(with: NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!)
        #expect(!row._mouseInGroup(buttons[0]))
        row.removeFromSuperview()
    }
    // Window after window, opened and closed, each has the title bar's own
    // three put away (feedback #168): they were kept by the window's address,
    // and a window at a closed one's address, or whose title bar AppKit had
    // built again, was answered with buttons gone by then.
    @MainActor @Test func everyNewWindowPutsItsOwnLightsAway() {
        _ = NSApplication.shared
        var shown: [Int] = []
        for turn in 0..<40 {
            autoreleasepool {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
                )
                window.isReleasedWhenClosed = false
                Lights.hideOwn(of: window)
                let own = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                    .compactMap { window.standardWindowButton($0) }
                if own.count != 3 || own.contains(where: { !$0.isHidden }) { shown.append(turn) }
                window.close()
            }
        }
        #expect(shown.isEmpty, "the title bar's own three still showing in windows \(shown)")
    }
}

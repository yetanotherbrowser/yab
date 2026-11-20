import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// #711: a finger swiped up a paragraph of a Chromium page selected its text
/// instead of scrolling. AppKit makes a one-finger drag a mouse drag for a
/// view without a gesture recognizer; the page now has a pan of its own.
@Suite(.serialized)
@MainActor
struct ChromiumTouchTests {
    @Test func aFingerOnThePageIsItsOwnTouchPanAndTheMouseIsLeftAlone() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let pans = page.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }
            .filter { $0.allowedTouchTypes.contains(.direct) }
        #expect(pans.count == 1)
        let pan = try #require(pans.first)
        // The page's own pan, which counts the fingers: one finger only.
        #expect(pan is ChromiumTouchPan)
        // Touches only: no mouse button starts it.
        #expect(pan.allowedTouchTypes == .direct)
        #expect(pan.buttonMask == 0)
        #expect(pan.target === page)
        // The mouse events AppKit makes from the finger are to wait until the
        // pan fails (NSGestureRecognizer.h), so a pan is never also a selecting drag.
        #expect(pan.delaysPrimaryMouseButtonEvents)
        // The page decides which event streams the pan may take. That a
        // mouse's press and drag still reach the page at once is
        // aMousePressAndDragStillReachThePageAtOnce.
        #expect(pan.delegate === page)
        // Told of no touch yet: the pan counts no finger, and takes the one
        // it pans (ChromiumTouchInputTests).
        #expect((pan as? ChromiumTouchPan)?.fingers == 0)
    }

    /// A finger down when the page is hidden (a tab switch) or leaves its
    /// window is cancelled then, once, and the rest of its pan is ignored.
    @Test func hidingThePageOrTakingItOutOfItsWindowLetsGoOfTheFinger() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); page.retire(call: false, pictureInPicture: false); tab.close() }
        window.contentView = page
        func fingerDown() {
            _ = page.touch.step(.began, fingers: 1, turn: page.documentTurn, at: CGPoint(x: 300, y: 280), moved: CGPoint(x: 0, y: -20))
            #expect(page.touch.held == .down(turn: page.documentTurn))
        }

        fingerDown()
        page.isHidden = true
        #expect(page.touch.held == .dropped)
        #expect(page.touch.interruptedThrough == 1)
        _ = page.touch.step(.cancelled, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)
        page.isHidden = false

        fingerDown()
        window.contentView = nil
        #expect(page.touch.held == .dropped)
        #expect(page.touch.interruptedThrough == 2)
    }

    @Test func reparentingAVisiblePageRetiresAnAlreadyLiftedGesture() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let first = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { page.removeFromSuperview(); first.close(); second.close(); page.retire(call: false, pictureInPicture: false); tab.close() }
        first.contentView?.addSubview(page)
        _ = page.touch.step(.began, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)
        let lift = page.touch.step(.ended, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)
        #expect(lift.events.map(\.kind) == ["touchEnd"])
        #expect(page.touch.held == .up)
        #expect(page.touch.interruptedThrough == 0)

        second.contentView?.addSubview(page)
        #expect(page.window === second)
        #expect(!page.isHiddenOrHasHiddenAncestor)
        #expect(page.touch.interruptedThrough == 1)
    }

    @Test func retiringAnAttachedPageRetiresItsTouchBeforeDetaching() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        page.adoptRemote("touch-retire-" + UUID().uuidString)
        defer { tab.close() }
        _ = page.touch.step(.began, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)

        page.retire(call: false, pictureInPicture: false)

        #expect(page.remoteID == nil)
        #expect(page.touch.interruptedThrough == 1)
        #expect(page.touch.held == .dropped)
    }

    @Test func committingNativeCloseRetiresAnAlreadyLiftedGesture() throws {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        let page = try #require(tab.page as? ChromiumPage)
        let remote = "touch-native-close-" + UUID().uuidString
        page.adoptRemote(remote)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let entry = ChromiumCloseBatch.Entry(tab: tab, page: page, remote: remote)
        try #require(entry.live)
        _ = page.touch.step(.began, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)
        _ = page.touch.step(.ended, fingers: 1, turn: page.documentTurn, at: .zero, moved: .zero)

        entry.beginCommit()

        #expect(entry.committing)
        #expect(page.touch.interruptedThrough == 1)
    }

    /// The pan holds back only the finger's mouse events. A synthetic mouse
    /// press and drag, sent through the window as AppKit sends a mouse's,
    /// still reach the page in the same turn, so a click-drag selects as before.
    @Test(.enabled("no test screen; the built-in one is off-limits") { await TestScreen.available })
    func aMousePressAndDragStillReachThePageAtOnce() async throws {
        _ = NSApplication.shared
        let screen = try #require(TestScreen.screen)
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        // A floating page's panel: the page takes its first press there
        // (acceptsFirstMouse), so the press arrives while this test process
        // is in the background and its window is not key.
        let window = DocumentPiPPanel(contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 600, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer { window.close(); page.retire(call: false, pictureInPicture: false); tab.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            let event = try #require(NSEvent.mouseEvent(with: type, location: page.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: type == .leftMouseDragged ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.sendEvent(event)
            return event
        }
        let down = try send(.leftMouseDown, CGPoint(x: 300, y: 300))
        #expect(page.dragState.pressed === down)
        let drag = try send(.leftMouseDragged, CGPoint(x: 300, y: 200))
        #expect(page.dragState.pressed === drag)
        _ = try send(.leftMouseUp, CGPoint(x: 300, y: 200))
    }
}

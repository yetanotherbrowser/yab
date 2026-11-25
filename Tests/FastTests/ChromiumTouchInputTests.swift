import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// What a finger's pan says to a Chromium page (ChromiumPage+Touch.swift):
/// touches, never a pressed mouse moving across the text, one finger at a
/// time, and only to the document it went down on.
@Suite
struct ChromiumTouchInputTests {
    private func point(_ fields: [String: JSONValue]) -> CGPoint? {
        guard let x = fields["x"]?.number, let y = fields["y"]?.number else { return nil }
        return CGPoint(x: x, y: y)
    }
    private func step(_ touch: inout ChromiumTouchSequence, _ state: NSGestureRecognizer.State, fingers: Int = 1, turn: Int = 0,
                      at point: CGPoint = .zero, moved: CGPoint = .zero) -> (kinds: [String], letGo: Bool) {
        let step = touch.step(state, fingers: fingers, turn: turn, at: point, moved: moved)
        return (step.events.map(\.kind), step.letGo)
    }

    @Test func aPanPutsTheFingerDownWhereItLandedThenMovesIt() {
        var touch = ChromiumTouchSequence()
        let began = touch.step(.began, fingers: 1, turn: 0, at: CGPoint(x: 300, y: 488), moved: CGPoint(x: 0, y: -12))
        #expect(began.events.map(\.kind) == ["touchStart", "touchMove"])
        #expect(point(began.events[0].fields) == CGPoint(x: 300, y: 500))
        #expect(point(began.events[1].fields) == CGPoint(x: 300, y: 488))
        #expect(!began.letGo)
        #expect(touch.held == .down(turn: 0))

        let changed = touch.step(.changed, fingers: 1, turn: 0, at: CGPoint(x: 302, y: 260), moved: CGPoint(x: 2, y: -240))
        #expect(changed.events.map(\.kind) == ["touchMove"])
        #expect(point(changed.events[0].fields) == CGPoint(x: 302, y: 260))
    }

    @Test func liftingOrLosingTheFingerEndsTheTouchWithoutAPoint() {
        for (state, kind) in [(NSGestureRecognizer.State.ended, "touchEnd"), (.cancelled, "touchCancel")] {
            var touch = ChromiumTouchSequence()
            _ = step(&touch, .began)
            let last = touch.step(state, fingers: 1, turn: 0, at: CGPoint(x: 10, y: 10), moved: .zero)
            #expect(last.events.map(\.kind) == [kind])
            #expect(point(last.events[0].fields) == nil)
            #expect(touch.held == .up)
        }
    }

    @Test func aPanThatNeverBeganSaysNothing() {
        // A tap fails the pan: the page hears it as a click instead.
        for state in [NSGestureRecognizer.State.possible, .failed, .changed, .ended, .cancelled] {
            var touch = ChromiumTouchSequence()
            #expect(step(&touch, state).kinds.isEmpty)
        }
    }

    @Test func noStepOfAPanIsAMouseKind() {
        var kinds: [String] = []
        for last in [NSGestureRecognizer.State.ended, .cancelled] {
            var touch = ChromiumTouchSequence()
            for state in [NSGestureRecognizer.State.began, .changed, last] { kinds += step(&touch, state).kinds }
        }
        #expect(Set(kinds) == ChromiumTouchInput.kinds)
        #expect(!kinds.contains { $0.hasPrefix("mouse") })
    }

    /// A navigation under the finger: the new document never hears the old
    /// finger move or lift. The touch is cancelled once, and the rest of
    /// that pan is ignored.
    @Test func aFingerStaysWithTheDocumentItWentDownOn() {
        var touch = ChromiumTouchSequence()
        _ = step(&touch, .began, turn: 4)
        #expect(step(&touch, .changed, turn: 5).kinds == ["touchCancel"])
        #expect(touch.held == .dropped)
        #expect(step(&touch, .changed, turn: 5).kinds.isEmpty)
        #expect(step(&touch, .ended, turn: 5).kinds.isEmpty)
        #expect(touch.held == .up)

        // Lifted on the new document before it moved there: no end, which
        // could tap it, only the cancel.
        var lifted = ChromiumTouchSequence()
        _ = step(&lifted, .began, turn: 4)
        #expect(step(&lifted, .ended, turn: 5).kinds == ["touchCancel"])
    }

    /// The page hidden, or out of its window, with a finger down.
    @Test func anInterruptedTouchRetiresItsNumberAndIgnoresTheRestOfItsPan() {
        var touch = ChromiumTouchSequence()
        #expect(touch.interrupt() == nil)
        #expect(touch.interruptedThrough == 0)
        _ = step(&touch, .began)
        #expect(touch.interrupt() == 1)
        #expect(touch.interruptedThrough == 1)
        #expect(step(&touch, .changed).kinds.isEmpty)
        #expect(step(&touch, .cancelled).kinds.isEmpty)
        // The next finger is a new touch.
        #expect(step(&touch, .began).kinds == ["touchStart", "touchMove"])
    }

    @Test func repeatedInterruptionsRequestOnlyOneResetPerGesture() {
        var touch = ChromiumTouchSequence()
        for gesture in 1...2 {
            _ = step(&touch, .began)
            _ = step(&touch, .ended)
            #expect(touch.interrupt() == gesture)
            for _ in 0..<128 { #expect(touch.interrupt() == nil) }
        }
    }

    /// One finger only: a second one cancels the page's touch and lets go
    /// of the pan, so it never moves the first finger's touch.
    @Test func aSecondFingerCancelsTheTouchAndLetsGoOfThePan() {
        var touch = ChromiumTouchSequence()
        _ = step(&touch, .began)
        let joined = step(&touch, .changed, fingers: 2)
        #expect(joined.kinds == ["touchCancel"])
        #expect(joined.letGo)
        // `fingers` is the most down during the pan: the first finger lifting
        // leaves the second one, which still never moves the touch.
        #expect(step(&touch, .changed, fingers: 2).kinds.isEmpty)
        #expect(step(&touch, .cancelled, fingers: 2).kinds.isEmpty)

        var both = ChromiumTouchSequence()
        let began = step(&both, .began, fingers: 2)
        #expect(began.kinds.isEmpty)
        #expect(began.letGo)
        #expect(step(&both, .changed, fingers: 2).kinds.isEmpty)
    }

    /// A second finger that lands and the pan ends before any move reports
    /// it: the lift is a cancel, never an end the page could take as a tap.
    @Test func aLiftAfterASecondFingerCancelsTheTouch() {
        for last in [NSGestureRecognizer.State.ended, .cancelled, .failed] {
            var touch = ChromiumTouchSequence()
            _ = step(&touch, .began)
            let lift = step(&touch, last, fingers: 2)
            #expect(lift.kinds == ["touchCancel"])
            #expect(!lift.letGo)
            #expect(touch.held == .up)
        }
    }

    @Test func aPanBeganOverAnUnfinishedTouchCancelsItFirst() {
        var touch = ChromiumTouchSequence()
        _ = step(&touch, .began)
        #expect(step(&touch, .began).kinds == ["touchCancel", "touchStart", "touchMove"])
    }

    /// Each pan is a gesture of its own number, and every event of it names
    /// it, so the helper never applies one gesture's event to another.
    @Test func everyEventNamesItsGesture() {
        func gestures(_ events: [ChromiumTouchSequence.Event]) -> [Double?] { events.map { $0.fields["gesture"]?.number } }
        var touch = ChromiumTouchSequence()
        #expect(gestures(touch.step(.began, fingers: 1, turn: 0, at: .zero, moved: .zero).events) == [1, 1])
        #expect(gestures(touch.step(.changed, fingers: 1, turn: 0, at: .zero, moved: .zero).events) == [1])
        // A pan begun over the unfinished one: the cancel is the old gesture's.
        #expect(gestures(touch.step(.began, fingers: 1, turn: 0, at: .zero, moved: .zero).events) == [1, 2, 2])
        #expect(gestures(touch.step(.ended, fingers: 1, turn: 0, at: .zero, moved: .zero).events) == [2])
        // A pan that sends nothing still takes a number: the next is its own.
        _ = touch.step(.began, fingers: 2, turn: 0, at: .zero, moved: .zero)
        _ = touch.step(.cancelled, fingers: 2, turn: 0, at: .zero, moved: .zero)
        #expect(gestures(touch.step(.began, fingers: 1, turn: 0, at: .zero, moved: .zero).events) == [4, 4])
        #expect(touch.interrupt() == 4)
        #expect(touch.interruptedThrough == 4)
    }

    /// The pan was told of no touch (`fingers` 0: AppKit called no
    /// `touchesBegan(with:)` on it, or reported no touch there): it still
    /// takes the finger, from where its translation began, so a swipe scrolls.
    @Test func aPanToldOfNoTouchTakesTheFingerFromWhereItsTranslationBegan() throws {
        var touch = ChromiumTouchSequence()
        let began = touch.step(.began, fingers: 0, turn: 0, at: CGPoint(x: 310, y: 470), moved: CGPoint(x: 10, y: -30))
        try #require(began.events.map(\.kind) == ["touchStart", "touchMove"])
        #expect(point(began.events[0].fields) == CGPoint(x: 300, y: 500))
        #expect(point(began.events[1].fields) == CGPoint(x: 310, y: 470))
        #expect(!began.letGo)
        #expect(step(&touch, .changed, fingers: 0).kinds == ["touchMove"])
        #expect(step(&touch, .ended, fingers: 0).kinds == ["touchEnd"])
    }

    /// A second finger the pan is told of, after none were, still cancels.
    @Test func aSecondFingerReportedAfterNoneStillCancels() {
        var touch = ChromiumTouchSequence()
        #expect(step(&touch, .began, fingers: 0).kinds == ["touchStart", "touchMove"])
        let joined = step(&touch, .changed, fingers: 2)
        #expect(joined.kinds == ["touchCancel"])
        #expect(joined.letGo)
        #expect(step(&touch, .ended, fingers: 2).kinds.isEmpty)
    }
}

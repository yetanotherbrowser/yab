import AppKit
import Testing
@testable import Fast

// The trackpad's glide after a sideways swipe over the column (SwipeGlide):
// lifted while drifting down, it scrolled the rows of the space being left.
struct SwipeGlideTests {
    /// Whether each event, a (phase, momentum) pair, is held back.
    static func play(_ glide: inout SwipeGlide, _ events: [(NSEvent.Phase, NSEvent.Phase)]) -> [Bool] {
        events.map { glide.takes(phase: $0.0, momentum: $0.1) }
    }

    @Test func theGlideAfterASidewaysSwipeIsHeldBack() {
        var glide = SwipeGlide()
        glide.lifted(sideways: true)
        let held = Self.play(&glide, [([], .began), ([], .changed), ([], .changed), ([], .ended)])
        #expect(held == [true, true, true, true])
        // Over with its end: the next glide is someone else's.
        #expect(!glide.held)
        #expect(Self.play(&glide, [([], .began)]) == [false])
    }

    @Test func theRowsOwnGlideGoesOn() {
        // An up-and-down scroll of the rows, or a swipe begun elsewhere.
        var glide = SwipeGlide()
        glide.lifted(sideways: false)
        #expect(Self.play(&glide, [([], .began), ([], .changed)]) == [false, false])
    }

    @Test func fingersDownAgainLetItGo() {
        // Fingers back on the trackpad stop a glide; the new gesture is
        // judged afresh, and so is whatever glide comes after it.
        var glide = SwipeGlide()
        glide.lifted(sideways: true)
        #expect(Self.play(&glide, [([], .began), (.mayBegin, []), ([], .changed)]) == [true, false, false])
        #expect(!glide.held)

        glide.lifted(sideways: true)
        #expect(Self.play(&glide, [(.began, []), (.changed, [])]) == [false, false])
    }

    @Test func movesWithFingersOnAreNeverTheGlides() {
        // Only momentum is held back: the catch judges the fingers' own moves.
        var glide = SwipeGlide()
        glide.lifted(sideways: true)
        #expect(Self.play(&glide, [(.changed, [])]) == [false])
        #expect(glide.held)
    }

    @Test func aCancelledGlideEndsTheHold() {
        var glide = SwipeGlide()
        glide.lifted(sideways: true)
        #expect(Self.play(&glide, [([], .cancelled)]) == [true])
        #expect(!glide.held)
    }
}

struct SwipeEndTests {
    @Test func aBeganHandedOnGetsItsEndOnce() {
        var end = SwipeEnd()
        end.began(passed: true)
        let first = end.ended()
        // A second end with no began between must not pass again.
        let second = end.ended()
        #expect(first)
        #expect(!second)
    }

    @Test func aBeganTakenAfterAllKeepsItsEnd() {
        // The catch marks a began handed on, then taken once it reads sideways.
        var end = SwipeEnd()
        end.began(passed: true)
        end.began(passed: false)
        let passes = end.ended()
        #expect(!passes)
    }
}

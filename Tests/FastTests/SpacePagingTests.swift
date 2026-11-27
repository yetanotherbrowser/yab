import AppKit
import Foundation
import Testing
@testable import Fast

// The column's spaces under two fingers and on their spring, against what
// Arc was measured doing (docs/space-switching.md).
struct SpacePagingTests {
    static let page = 226.0

    @Test func followsHalfTheFingers() {
        // Arc: 40, 80, 120, 160 points of fingers moved the row 19.5, 39.5, 59.5, 79.5.
        for travel in [-40.0, -80, -120, -160] {
            #expect(SpacePaging.offset(travel: travel, page: Self.page, back: true, forward: true) == travel / 2)
        }
        #expect(SpacePaging.offset(travel: 160, page: Self.page, back: true, forward: true) == 80)
    }

    @Test func givesALittlePastTheLastSpace() {
        // Arc: 200 points toward a next space that isn't there moved it 14.
        let moved = SpacePaging.offset(travel: -200, page: Self.page, back: true, forward: false)
        #expect(moved < 0 && moved > -16 && moved < -12)
        // And never a whole page, however far.
        #expect(SpacePaging.offset(travel: -100_000, page: Self.page, back: true, forward: false) > -Self.page)
        // Nothing before the first space either.
        let before = SpacePaging.offset(travel: 200, page: Self.page, back: false, forward: true)
        #expect(before > 12 && before < 16)
    }

    @Test func oneSpaceAGestureAtMost() {
        let far = SpacePaging.offset(travel: -600, page: Self.page, back: true, forward: true)
        #expect(far < -Self.page && far > -Self.page - 40)
    }

    @Test func heldStillGoesWhereMoreShows() {
        // Arc: held at 44, 48 and 50.4 percent went back; 52 and 55 percent went on.
        for share in [0.44, 0.48, 0.5] {
            #expect(SpacePaging.landing(offset: -share * Self.page, speed: 0, page: Self.page, back: true, forward: true) == 0)
        }
        for share in [0.52, 0.55, 0.66] {
            #expect(SpacePaging.landing(offset: -share * Self.page, speed: 0, page: Self.page, back: true, forward: true) == 1)
        }
        #expect(SpacePaging.landing(offset: 0.6 * Self.page, speed: 0, page: Self.page, back: true, forward: true) == -1)
    }

    @Test func movingGoesOnTheWayItWent() {
        // Arc: 2 percent of the way, drifting on at 7 points a second, went
        // to the next space; past halfway but coming back, it went back.
        #expect(SpacePaging.landing(offset: -0.02 * Self.page, speed: -7, page: Self.page, back: true, forward: true) == 1)
        #expect(SpacePaging.landing(offset: -0.57 * Self.page, speed: 100, page: Self.page, back: true, forward: true) == 0)
        #expect(SpacePaging.landing(offset: -0.17 * Self.page, speed: 400, page: Self.page, back: true, forward: true) == 0)
        // No next space: it comes back however hard the flick.
        #expect(SpacePaging.landing(offset: -10, speed: -2000, page: Self.page, back: true, forward: false) == 0)
        // Slower than a few points a second is still.
        #expect(SpacePaging.landing(offset: -0.3 * Self.page, speed: -2, page: Self.page, back: true, forward: true) == 0)
    }

    @Test func speedFromTheLastMoves() {
        // 2 points every 8 ms, lifted at once: 250 points a second.
        let moves = (0..<10).map { (Double($0) * 0.008, -2.0) }
        #expect(abs(SpacePaging.speed(moves, liftedAt: 0.08) + 250) < 1)
        // Rested 0.3 s before lifting: none.
        #expect(SpacePaging.speed(moves, liftedAt: 0.38) == 0)
        #expect(SpacePaging.speed([], liftedAt: 1) == 0)
    }

    @Test func springLandsLikeArcs() {
        // Measured: half the way in about 50 ms, nine tenths by 120, all of
        // it (99 percent) by about 200, and never past.
        func done(_ share: Double) -> Double {
            var t = 0.0
            while SpacePaging.spring(t) > 1 - share { t += 0.001 }
            return t
        }
        #expect(abs(done(0.5) - 0.054) < 0.01)
        #expect(abs(done(0.9) - 0.124) < 0.012)
        #expect(abs(done(0.99) - 0.212) < 0.02)
        let lowest = stride(from: 0.0, through: 1.5, by: 0.001).map { SpacePaging.spring($0) }.min() ?? 0
        #expect(lowest >= -1e-6)
        #expect(abs(SpacePaging.stiffness - 986.96) < 0.1)
        #expect(abs(SpacePaging.friction - 62.83) < 0.01)
    }

    @Test func caughtFingersHoldTheRowWhereItIs() {
        for (offset, back, forward) in [(-100.0, true, true), (60.0, true, true), (-12.0, true, false), (9.0, false, true), (-226.0, true, true)] {
            let travel = SpacePaging.travel(for: offset, page: Self.page, back: back, forward: forward)
            #expect(abs(SpacePaging.offset(travel: travel, page: Self.page, back: back, forward: forward) - offset) < 0.01)
        }
    }

    @Test func theSpringTakesTheFingersSpeedOnlyTowardWhereItLands() {
        #expect(SpacePaging.handOff(-800, from: -50, to: -226) == -800)
        #expect(SpacePaging.handOff(800, from: -50, to: 0) == 800)
        // Flung past the last space, it comes back still rather than further out first.
        #expect(SpacePaging.handOff(-800, from: -14, to: 0) == 0)
        #expect(SpacePaging.handOff(300, from: -150, to: -226) == 0)
    }

    @Test func slidesOverTheCardToo() {
        // 0.0.8: the column put away and brought out by the edge didn't
        // slide, and its rows faded with nothing coming under them.
        #expect(SpacePaging.slides(.card, spaces: true, reduceMotion: false))
        #expect(SpacePaging.slides(.docked, spaces: true, reduceMotion: false))
        #expect(!SpacePaging.slides(.away, spaces: true, reduceMotion: false))
        #expect(!SpacePaging.slides(.card, spaces: true, reduceMotion: true))
        #expect(!SpacePaging.slides(.docked, spaces: false, reduceMotion: false))
    }

    // #98, #100: a trackpad's began carries the first move, and the column
    // takes the row with it. Every local monitor hears every event in an
    // order AppKit changes as monitors come and go; heard after the take,
    // that same began read as fingers down anew and let the row go, so
    // every swipe did nothing until the order turned again.
    @Test func theBeganThatTookTheRowIsTheSameFingers() {
        let held = 100.0
        #expect(SpacePager.parting(scroll: true, phase: .began, momentum: [], at: held, heldSince: held) == .no)
        #expect(SpacePager.parting(scroll: true, phase: .mayBegin, momentum: [], at: held - 0.01, heldSince: held) == .no)
        #expect(SpacePager.parting(scroll: true, phase: .changed, momentum: [], at: held, heldSince: held) == .no)
    }

    @Test func fingersDownAnewOrAClickStillLetTheRowGo() {
        let held = 100.0
        #expect(SpacePager.parting(scroll: true, phase: .began, momentum: [], at: held + 0.5, heldSince: held) == .now)
        #expect(SpacePager.parting(scroll: true, phase: .mayBegin, momentum: [], at: held + 0.5, heldSince: held) == .now)
        #expect(SpacePager.parting(scroll: false, phase: [], momentum: [], at: held + 0.5, heldSince: held) == .now)
        #expect(SpacePager.parting(scroll: true, phase: .changed, momentum: [], at: held + 0.5, heldSince: held) == .no)
        #expect(SpacePager.parting(scroll: true, phase: .ended, momentum: [], at: held + 0.5, heldSince: held) == .afterSwipe)
        #expect(SpacePager.parting(scroll: true, phase: [], momentum: .began, at: held + 0.5, heldSince: held) == .afterSwipe)
    }

    /// Plays `events` from idle, failing on any the phase refuses.
    static func play(_ events: [SpacePaging.Event], from start: SpacePaging.Phase = .idle) -> SpacePaging.Phase? {
        events.reduce(Optional(start)) { phase, event in phase.flatMap { SpacePaging.next($0, event) } }
    }

    @Test func aKeyLandsAndComesToRest() {
        #expect(Self.play([.turn(target: 2), .send]) == .landing(springs: 1))
        #expect(Self.play([.turn(target: 2), .send, .landed]) == .idle)
    }

    @Test func aSecondKeyWaitsForItsOwnSpring() {
        // The first spring landing while the second key's switch runs must not take the pages down.
        let turned = Self.play([.turn(target: 1), .send, .turn(target: 2)])
        #expect(turned == .turning(target: 2, springs: 1))
        #expect(Self.play([.landed], from: turned!) == .turning(target: 2, springs: 0))
        #expect(Self.play([.landed, .send, .landed], from: turned!) == .idle)
        #expect(Self.play([.send, .landed], from: turned!) == .landing(springs: 1))
    }

    @Test func aLetGoBackLandsWhereItBegan() {
        #expect(Self.play([.grab(at: 1), .lift(switching: false), .send, .landed]) == .idle)
    }

    @Test func aLetGoOnwardIgnoresTheSwitchItMakes() {
        let releasing = Self.play([.grab(at: 1), .lift(switching: true), .send])
        #expect(releasing == .releasing(springs: 1))
        // The switch's own turn and a grab inside it change nothing.
        #expect(SpacePaging.next(releasing!, .turn(target: 3)) == nil)
        #expect(SpacePaging.next(releasing!, .grab(at: 2)) == nil)
        #expect(Self.play([.switched, .landed], from: releasing!) == .idle)
        // A spring that landed before the switch was done still ends it.
        #expect(Self.play([.landed, .switched], from: releasing!) == .idle)
    }

    @Test func fingersOrAKeyInterruptALanding() {
        let landing = Self.play([.turn(target: 1), .send])!
        #expect(SpacePaging.next(landing, .grab(at: 5)) == .held(since: 5))
        #expect(SpacePaging.next(landing, .turn(target: 0)) == .turning(target: 0, springs: 1))
        // A key while fingers hold starts a turn of its own.
        #expect(SpacePaging.next(.held(since: 1), .turn(target: 2)) == .turning(target: 2, springs: 0))
    }

    @Test func staleEventsChangeNothing() {
        #expect(SpacePaging.next(.idle, .landed) == nil)
        #expect(SpacePaging.next(.idle, .send) == nil)
        #expect(SpacePaging.next(.idle, .lift(switching: true)) == nil)
        #expect(SpacePaging.next(.held(since: 1), .landed) == nil)
        #expect(SpacePaging.next(.held(since: 1), .send) == nil)
        #expect(SpacePaging.next(.landing(springs: 1), .lift(switching: false)) == nil)
        for phase: SpacePaging.Phase in [.idle, .held(since: 1), .turning(target: 1, springs: 2), .releasing(springs: 1), .landing(springs: 3)] {
            #expect(SpacePaging.next(phase, .finish) == .idle)
        }
    }

    // A lift lost with nothing else happening left the row held halfway while the pointer moved on.
    @Test func thePointerMovingAfterTheFingersLetsTheRowGo() {
        #expect(SpacePaging.liftedUnseen(sincePointer: 0.1, sinceScroll: 0.8, heldFor: 2))
        // Still scrolling: a Magic Mouse nudged mid-swipe keeps the row.
        #expect(!SpacePaging.liftedUnseen(sincePointer: 0.05, sinceScroll: 0.1, heldFor: 2))
        // The pointer last moved before the grab: fingers resting still.
        #expect(!SpacePaging.liftedUnseen(sincePointer: 5, sinceScroll: 3, heldFor: 2))
        // Moved before the last scroll.
        #expect(!SpacePaging.liftedUnseen(sincePointer: 1, sinceScroll: 0.5, heldFor: 2))
    }

    // Who paints the column's ground while its spaces slide: one ground
    // under the whole row wherever the column has its own, so the color
    // turns as far as the row has gone. Edge to edge docked, each page
    // carried its own and came in a rectangle of the next space's color,
    // the head left in the old one (c768dcbb to ba764a3d).
    @Test func theColumnsOwnGroundIsOneUnderTheRow() {
        for backdrop in Backdrop.allCases {
            #expect(SpacePaging.ground(backdrop: backdrop, place: .card) == .row)
            #expect(SpacePaging.ground(backdrop: backdrop, place: .away) == .window)
        }
        // Edge to edge docked the column stands on the window's backdrop,
        // as on a color (#256).
        #expect(SpacePaging.ground(backdrop: .none, place: .docked) == .window)
        #expect(SpacePaging.ground(backdrop: .color, place: .docked) == .window)
        #expect(SpacePaging.ground(backdrop: .site, place: .docked) == .window)
    }
}

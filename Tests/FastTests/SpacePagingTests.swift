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

    @Test func thePlusPastTheLastSpaceFillsWithTheRowsGive() {
        // Arc's: in at 15 points of give, its ring full at 22.5.
        #expect(SpacePaging.plus(0) == (0, 0))
        #expect(SpacePaging.plus(7.5) == (0.5, 1.0 / 3))
        #expect(SpacePaging.plus(15) == (1, 15 / 22.5))
        #expect(SpacePaging.plus(22.5) == (1, 1))
        #expect(SpacePaging.plus(80) == (1, 1))
        // On the row's own rubber band, not a looser one: full takes about
        // 330 points of fingers on a 226 point column, as in Arc, and 200,
        // Arc's measured 14 points, is short of it.
        let short = -SpacePaging.offset(travel: -200, page: Self.page, back: true, forward: false)
        #expect(SpacePaging.plus(short).ring < 1)
        let full = -SpacePaging.offset(travel: -340, page: Self.page, back: true, forward: false)
        #expect(SpacePaging.plus(full).ring == 1)
        #expect(SpacePaging.plus(-SpacePaging.offset(travel: -320, page: Self.page, back: true, forward: false)).ring < 1)
    }

    @Test func onlyARingHeldFullMakesASpace() {
        // Short of full: nothing, however long it is held.
        var since = SpacePaging.fullSince(nil, past: 22, at: 0)
        #expect(since == nil)
        #expect(!SpacePaging.makesSpace(fullSince: since, liftedAt: 5))
        // Full at 1.0, still full after: the first time is kept.
        since = SpacePaging.fullSince(since, past: 23, at: 1.0)
        since = SpacePaging.fullSince(since, past: 30, at: 1.05)
        #expect(since == 1.0)
        // Lifted the moment it filled: no space; after a tenth: New Space.
        #expect(!SpacePaging.makesSpace(fullSince: since, liftedAt: 1.08))
        #expect(SpacePaging.makesSpace(fullSince: since, liftedAt: 1.11))
        // Pulled back short of full cancels, and pulling on again starts
        // the tenth over.
        since = SpacePaging.fullSince(since, past: 20, at: 1.2)
        #expect(since == nil)
        #expect(!SpacePaging.makesSpace(fullSince: since, liftedAt: 1.5))
        since = SpacePaging.fullSince(since, past: 25, at: 1.3)
        #expect(since == 1.3)
        #expect(!SpacePaging.makesSpace(fullSince: since, liftedAt: 1.35))
        // The row still goes back to the last space, as it always did.
        #expect(SpacePaging.landing(offset: -30, speed: 0, page: Self.page, back: true, forward: false) == 0)
        #expect(SpacePaging.landing(offset: -30, speed: -400, page: Self.page, back: true, forward: false) == 0)
    }

    @MainActor @Test func canSwipeNewSpaceTracksWindowAndSpacesSetting() {
        let browser = Browser(windowID: UUID())
        let oldSpaces = browser.prefs.usesSpaces
        defer {
            browser.prefs.usesSpaces = oldSpaces
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        browser.prefs.usesSpaces = false
        #expect(!browser.canSwipeNewSpace)

        browser.prefs.usesSpaces = true
        #expect(browser.canSwipeNewSpace)
        #expect(browser.swipesSpaces)
    }
}

import CoreGraphics
import XCTest
@testable import YabPhone

/// The capsule of spaces as the approved capsule.js moves it: the current
/// name always in the middle, the pair hugged, soft edges only where names
/// run past the capsule, taps that leave the buttons, drags that send them out.
final class CapsuleModelTests: XCTestCase {
    private let mid: CGFloat = 201
    private let rest: CGFloat = 246
    private let wide: CGFloat = 362

    /// Five names, each 14 + words + 14, as the prototype measures them.
    private let many = CapsuleTrack(widths: [88, 98, 72, 82, 96])
    private let pair = CapsuleTrack(widths: [88, 98])

    private func model(_ track: CapsuleTrack, _ current: Int, pair: Bool = false) -> CapsuleModel {
        CapsuleModel(track: track, current: current, mid: mid, restWidth: rest, wideWidth: wide, pair: pair)
    }

    private func run(_ m: inout CapsuleModel, seconds: CGFloat) {
        for _ in 0..<Int(seconds * 60) { m.step(1 / 60) }
    }

    private func settle(_ m: inout CapsuleModel) {
        for _ in 0..<1200 where !m.isSettled { m.step(1 / 60) }
        XCTAssertTrue(m.isSettled)
    }

    func testTheCurrentNameIsCenteredAtRestBetweenTheEnds() {
        for i in 1..<many.widths.count - 1 {
            let m = model(many, i)
            XCTAssertEqual(m.capW.v, rest)
            XCTAssertEqual(m.lens.center, mid, accuracy: 0.001, "space \(i) under the lens in the middle")
            XCTAssertEqual(m.lens.width, many.widths[i] - 12, accuracy: 0.001, "the lens is the name + 16")
            XCTAssertEqual(m.trackX.v, mid - many.centers[i], accuracy: 0.001)
        }
    }

    func testAnEndHugsItsNeighborWithTheLensThreeInFromTheEnd() {
        let pad = CapsuleModel.lensLess / 2 - CapsuleModel.inset
        let first = model(many, 0)
        XCTAssertEqual(first.mode, .hug)
        XCTAssertEqual(first.capW.v, 88 + 98 - 2 * pad, accuracy: 0.001, "the first two names, no empty end")
        XCTAssertEqual(first.lens.center - first.lens.width / 2 - first.capLeft, CapsuleModel.inset, accuracy: 0.001,
                       "the lens 3 in from the left end, as from the top")
        let last = model(many, 4)
        XCTAssertEqual(last.mode, .hug)
        XCTAssertEqual(last.capW.v, 82 + 96 - 2 * pad, accuracy: 0.001)
        XCTAssertEqual(last.capLeft + last.capW.v - (last.lens.center + last.lens.width / 2), CapsuleModel.inset, accuracy: 0.001,
                       "the lens 3 in from the right end")
    }

    func testADragBringsAnEndToTheMiddleAndItHugsOnlyOnceLetGo() {
        var m = model(many, 3)
        m.down(250, now: 0)
        var t: CGFloat = 0
        var x: CGFloat = 250
        for _ in 1...40 { t += 1 / 60; x -= 3; m.move(x, now: t); m.step(1 / 60) }
        XCTAssertEqual(m.mode, .drag)
        XCTAssertGreaterThan(m.capW.v, 340, "wide while the finger is on it")
        guard case let .release(k)? = m.up(x) else { return XCTFail("a drag ends in a release") }
        XCTAssertEqual(k, 4, "the last name")
        for _ in 0..<600 where !(abs(m.trackX.v - m.trackX.t) < 0.6 && abs(m.trackX.vel) < 8) { m.step(1 / 60) }
        XCTAssertEqual(m.mode, .center, "first in the middle, as every name")
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.6)
        settle(&m)
        XCTAssertEqual(m.mode, .hug, "then the end hugs its neighbor")
        XCTAssertEqual(m.capW.v, 82 + 96 - 2 * (CapsuleModel.lensLess / 2 - CapsuleModel.inset), accuracy: 0.01)
    }

    func testEdgesFadeOnlyWhereNamesRunPastTheCapsule() {
        let first = model(many, 0)
        XCTAssertFalse(first.fades.left, "the first space hugs: nothing runs past the left end")
        XCTAssertTrue(first.fades.right)
        let middle = model(many, 2)
        XCTAssertTrue(middle.fades.left)
        XCTAssertTrue(middle.fades.right)
        let last = model(many, 4)
        XCTAssertTrue(last.fades.left)
        XCTAssertFalse(last.fades.right, "the last space hugs: nothing runs past the right end")
    }

    func testThePairHugsBothWordsAndATapMovesOnlyTheLens() {
        var m = model(pair, 1, pair: true)
        XCTAssertEqual(m.mode, .hug)
        XCTAssertEqual(m.capW.v, 88 + 98 - 6, accuracy: 0.001, "both words, the lens's end 3 in")
        XCTAssertFalse(m.fades.left)
        XCTAssertFalse(m.fades.right)
        let track = m.trackX.v
        let width = m.capW.v
        XCTAssertEqual(m.capLeft - (CapsuleModel.lensLess / 2 - CapsuleModel.inset), track, accuracy: 0.001,
                       "the first name's lens starts 3 inside")
        let x = m.trackX.v + pair.centers[0]
        m.down(x, now: 0)
        XCTAssertEqual(m.up(x), .tap(0))
        settle(&m)
        XCTAssertEqual(m.trackX.v, track, accuracy: 0.01, "the names stay")
        XCTAssertEqual(m.capW.v, width, accuracy: 0.01, "the capsule stays")
        XCTAssertEqual(m.side.v, 0)
        XCTAssertEqual(m.lens.center, track + pair.centers[0], accuracy: 0.01, "the lens went to Private")
    }

    func testThePhoneFootKeepsBothNamesInPlaceWhileFollowingAPageSwipe() {
        var m = CapsuleModel(track: pair, current: 1, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: true, fixedWidth: true)
        let width = m.capW.v
        let left = m.capLeft
        let track = m.trackX.v
        XCTAssertEqual(width, 180, accuracy: 0.001)
        for (position, index) in [(0.0, 0), (0.25, 0), (0.75, 1), (1.0, 1)] {
            m.follow(CGFloat(position), index: index, followingPageDrag: true)
            run(&m, seconds: 0.15)
            XCTAssertEqual(m.capW.v, width)
            XCTAssertEqual(m.capLeft, left)
            XCTAssertEqual(m.trackX.v, track)
            XCTAssertEqual(m.lens.center, track + pair.at(CGFloat(position)).center, accuracy: 0.001)
        }
        settle(&m)
    }

    func testTheCompactPhoneFootKeepsAnimatingTheLensWhenATapCommits() {
        var m = CapsuleModel(track: pair, current: 1, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: true, fixedWidth: true)
        let track = m.trackX.v
        let left = m.capLeft
        XCTAssertEqual(m.select(0), .tap(0))
        m.step(1 / 60)
        let beforeCommit = m.lens.center
        m.follow(0, index: 0)
        XCTAssertEqual(m.lens.center, beforeCommit)
        m.step(1 / 60)
        XCTAssertLessThan(m.lens.center, beforeCommit)
        settle(&m)
        XCTAssertEqual(m.lens.center, track + pair.centers[0], accuracy: 0.001)
        XCTAssertEqual(m.trackX.v, track)
        XCTAssertEqual(m.capLeft, left)
    }

    func testThePhoneFootWithMoreSpacesStaysFullWidthAtEitherEnd() {
        var m = CapsuleModel(track: many, current: 1, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: false, fixedWidth: true)
        for index in [0, 1, 4, 3] {
            XCTAssertEqual(m.select(index), .tap(index))
            for _ in 0..<60 {
                m.step(1 / 60)
                XCTAssertEqual(m.capW.v, wide)
                XCTAssertEqual(m.capLeft, mid - wide / 2)
            }
            settle(&m)
        }
    }

    func testThePhoneFootWithMoreSpacesStaysFullWidthDuringAPageSwipe() {
        var m = CapsuleModel(track: many, current: 1, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: false, fixedWidth: true)
        m.follow(0.5, index: 1, followingPageDrag: true)
        run(&m, seconds: 0.5)
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.001)
        XCTAssertEqual(m.capW.v, wide)
        XCTAssertEqual(m.capLeft, mid - wide / 2)

        m.follow(0, index: 0, followingPageDrag: true)
        settle(&m)
        XCTAssertEqual(m.capW.v, wide)
        XCTAssertEqual(m.capLeft, mid - wide / 2)
    }

    func testDraggingTheCompactPhoneFootMovesTheLensBetweenFixedNames() {
        var m = CapsuleModel(track: pair, current: 1, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: true, fixedWidth: true)
        let track = m.trackX.v
        let left = m.capLeft
        let chats = track + pair.centers[0]
        let personal = track + pair.centers[1]

        m.down(personal, now: m.time)
        m.move(mid, now: m.time + 0.1)
        run(&m, seconds: 0.1)
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.001)
        m.move(left - 60, now: m.time)
        run(&m, seconds: 0.1)
        XCTAssertEqual(m.lens.center, chats, accuracy: 0.001)
        XCTAssertEqual(m.trackX.v, track)
        XCTAssertEqual(m.capLeft, left)
        XCTAssertFalse(m.fades.left)
        XCTAssertFalse(m.fades.right)
        XCTAssertEqual(m.up(left - 60), .release(0))
        settle(&m)

        m.down(chats, now: m.time)
        m.move(personal + 60, now: m.time + 0.2)
        run(&m, seconds: 0.2)
        XCTAssertEqual(m.lens.center, personal, accuracy: 0.001)
        XCTAssertEqual(m.trackX.v, track)
        XCTAssertEqual(m.capLeft, left)
        m.cancel()
        settle(&m)
        XCTAssertEqual(m.lens.center, chats, accuracy: 0.001)
        XCTAssertEqual(m.trackX.v, track)
    }

    func testTheCompactPhoneFootSettlesFromTheReleasePointWhileThePageCatchesUp() {
        var m = CapsuleModel(track: pair, current: 0, mid: mid, restWidth: wide, wideWidth: wide,
                             pair: true, fixedWidth: true)
        let start = m.lens.center
        let end = m.trackX.v + pair.centers[1]
        let release = start + 0.75 * (end - start)
        m.down(start, now: m.time)
        m.move(release, now: m.time + 0.2)
        run(&m, seconds: 0.2)
        XCTAssertEqual(m.lens.center, release, accuracy: 0.001)
        XCTAssertEqual(m.up(release), .release(1))

        for pagePosition in [0.05, 0.25, 0.75, 1.0] {
            let previous = m.lens.center
            m.follow(CGFloat(pagePosition), index: 1)
            XCTAssertEqual(m.lens.center, previous)
            m.step(1 / 60)
            XCTAssertGreaterThanOrEqual(m.lens.center, previous)
            XCTAssertLessThanOrEqual(m.lens.center, end)
        }
        settle(&m)
        XCTAssertEqual(m.lens.center, end, accuracy: 0.001)
    }

    func testATapOnANeighborMovesLensAndNamesTogetherAndKeepsTheButtons() {
        var m = model(many, 1)
        let x = m.trackX.v + many.centers[2]
        m.down(x, now: 0)
        XCTAssertEqual(m.up(x), .tap(2))
        XCTAssertEqual(m.ticks, 1, "one selection tick")
        var maxSide: CGFloat = 0
        var drift: CGFloat = 0
        for _ in 0..<60 {
            m.step(1 / 60)
            maxSide = max(maxSide, m.side.v)
            drift = max(drift, abs(m.lens.center - mid))
        }
        XCTAssertEqual(maxSide, 0, "a tap never sends the buttons out")
        XCTAssertLessThan(drift, 0.5, "lens and names move together: the lens stays in the middle")
        settle(&m)
        XCTAssertEqual(m.trackX.v, mid - many.centers[2], accuracy: 0.01)
        XCTAssertEqual(m.ticks, 1)
    }

    func testATapOnTheCurrentNameOnlyPressesTheLens() {
        var m = model(many, 1)
        let track = m.trackX.v
        m.down(mid, now: 0)
        XCTAssertEqual(m.up(mid), .pressCurrent)
        var peak: CGFloat = 0
        for _ in 0..<30 { m.step(1 / 60); peak = max(peak, m.press.v) }
        XCTAssertGreaterThan(peak, 0.5, "the lens swells toward 1.08")
        settle(&m)
        XCTAssertEqual(m.press.v, 0)
        XCTAssertEqual(m.trackX.v, track)
        XCTAssertEqual(m.ticks, 0)
    }

    func testASwipeSendsTheButtonsOutKeepsWordsUnderTheFingerAndSettlesCentered() {
        var m = model(many, 1)
        m.down(250, now: 0)
        m.move(254, now: 0.016)
        XCTAssertFalse(m.isDragging, "within 6 points it is still a tap")
        m.move(260, now: 0.032)
        XCTAssertTrue(m.isDragging)
        let anchor = m.trackX.v
        var t: CGFloat = 0.032
        for k in 1...30 {
            t += 1 / 60
            m.move(260 - CGFloat(k) * 3, now: t)
            m.step(1 / 60)
        }
        XCTAssertEqual(m.trackX.v, anchor - 90, accuracy: 0.001, "the words stay under the finger")
        XCTAssertGreaterThan(m.side.v, 0.8, "the buttons step out")
        XCTAssertGreaterThan(m.capW.v, 340, "the capsule takes the width")
        guard case let .release(k)? = m.up(170) else { return XCTFail("a drag ends in a release") }
        XCTAssertGreaterThan(k, 1, "it rolls on toward later names")
        // Rests, then 0.28 s later the buttons come back.
        for _ in 0..<600 where !(abs(m.trackX.v - m.trackX.t) < 0.6 && abs(m.trackX.vel) < 8) { m.step(1 / 60) }
        XCTAssertGreaterThan(m.side.t, 0.5, "still out right as the names stop")
        run(&m, seconds: 0.3)
        XCTAssertEqual(m.side.t, 0, "back 0.28 s after the names rest")
        settle(&m)
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.01, "the chosen name in the middle")
        XCTAssertEqual(m.capW.v, rest, accuracy: 0.01)
        XCTAssertEqual(m.side.v, 0)
        XCTAssertGreaterThanOrEqual(m.ticks, k - 1, "a tick for each name passing under the lens")
    }

    func testAThrowProjectsByVelocityTimesPointSixteen() {
        var slow = model(many, 0), fast = model(many, 0)
        for (i, speed) in [(0, CGFloat(60)), (1, CGFloat(1500))] {
            var m = i == 0 ? slow : fast
            m.down(300, now: 0)
            var t: CGFloat = 0
            var x: CGFloat = 300
            for _ in 0..<12 { t += 1 / 60; x -= speed / 60; m.move(x, now: t) }
            _ = m.up(x)
            settle(&m)
            if i == 0 { slow = m } else { fast = m }
        }
        XCTAssertGreaterThan(fast.cur, slow.cur, "a flick goes further than a slow drag of the same start")
    }

    func testThePairUnhugsForADragAndHugsAgainAfterTheButtonsReturn() {
        var m = model(pair, 1, pair: true)
        m.down(240, now: 0)
        var t: CGFloat = 0
        for k in 1...20 { t += 1 / 60; m.move(240 + CGFloat(k) * 4, now: t); m.step(1 / 60) }
        XCTAssertEqual(m.mode, .drag)
        XCTAssertGreaterThan(m.capW.v, 300)
        _ = m.up(320)
        for _ in 0..<600 where m.side.t != 0 { m.step(1 / 60) }
        XCTAssertEqual(m.mode, .center, "first the buttons come back, centered")
        run(&m, seconds: 0.35)
        XCTAssertEqual(m.mode, .hug, "0.3 s later it hugs the pair again")
        settle(&m)
        XCTAssertEqual(m.capW.v, 88 + 98 - 6, accuracy: 0.01)
    }

    func testFollowingThePagesCentersTheLensAndSendsTheButtonsOutWhileBetween() {
        var m = model(many, 1)
        m.follow(1.45, index: 1)
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.001)
        run(&m, seconds: 0.5)
        XCTAssertGreaterThan(m.side.v, 0.9, "between two spaces the buttons stay out")
        m.follow(2, index: 2)
        run(&m, seconds: 0.2)
        XCTAssertEqual(m.side.t, 1, "not before 0.28 s of rest")
        settle(&m)
        XCTAssertEqual(m.side.v, 0)
        XCTAssertEqual(m.lens.center, mid, accuracy: 0.001)
        XCTAssertEqual(m.ticks, 0, "the pages' own swipe ticks once, in goSpace")
    }

    func testHitsOnlyNamesInsideTheCapsule() {
        let m = model(many, 2)
        XCTAssertEqual(m.hit(mid), 2)
        XCTAssertNil(m.hit(m.capLeft - 1), "outside the capsule nothing is hit")
        XCTAssertEqual(m.hit(m.capLeft + 4), 1)
    }
}

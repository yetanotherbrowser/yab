import CoreGraphics
import Testing
@testable import Fast

/// An agent's screenshot of the whole view is drawn after the scroll it
/// follows: Yab hearing of that scroll while it is drawn is no reason to
/// refuse it. Every other picture, and a part of the page, still is.
struct PageShotScrollTests {
    @Test func anAgentsWholeViewKeepsAScrollThatLandsWhileDrawn() {
        var agent = PageShot(width: 1024)
        agent.scrollMayMove = true
        #expect(agent.keeps(scroll: 0, 1150))
        #expect(agent.keeps(scroll: 300, 300))
        #expect(agent.keeps(scroll: nil, 0))
    }

    @Test func everyOtherShotStillNeedsTheScrollItAskedAt() {
        #expect(!PageShot().keeps(scroll: 0, 1150))
        #expect(!PageShot(afterUpdates: false, brief: true).keeps(scroll: 40, 0))
        #expect(PageShot().keeps(scroll: 40, 40))
        // A part of the page moves under a scroll: not the part asked for.
        var part = PageShot(rect: CGRect(x: 0, y: 0, width: 200, height: 100))
        part.scrollMayMove = true
        #expect(!part.keeps(scroll: 0, 1150))
    }
}

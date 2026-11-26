import Foundation
import Testing
@testable import Fast

struct SwitchHoldTests {
    let a = UUID(), b = UUID()

    @Test func aFinisherFromAnEarlierHoldOfTheSameTabIsStale() {
        var hold = SwitchHold()
        let first = hold.hold(b)
        hold.release()               // back to A before B drew
        let second = hold.hold(b)    // and to B again
        #expect(!hold.holds(b, attempt: first))
        #expect(hold.holds(b, attempt: second))
    }

    @Test func aReleasedOrRetargetedHoldFinishesNothing() {
        var hold = SwitchHold()
        let toB = hold.hold(b)
        hold.release()
        #expect(!hold.holds(b, attempt: toB))
        let toA = hold.hold(a)
        #expect(hold.tab == a && hold.holds(a, attempt: toA) && !hold.holds(b, attempt: toB))
    }
}

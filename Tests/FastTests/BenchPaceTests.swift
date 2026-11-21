import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct BenchPaceTests {
    // Held for the whole suite: a released object's address, and so its
    // identifier, can come back for the next one.
    private static let keys = (0..<4).map { _ in Key() }
    private final class Key {}
    private func key(_ index: Int) -> ObjectIdentifier { ObjectIdentifier(Self.keys[index]) }

    @Test func aPageNamedByACallDrawsFullyUntilTheCallEnds() {
        var pace = BenchPace()
        let page = key(0)
        pace.began(for: "a"); pace.names(page); pace.woke(page, for: "a")
        #expect(pace.awake(page))
        pace.ended(for: "a", naming: page)
        #expect(!pace.awake(page))
    }

    @Test func aPageNamedByTwoCallsRestsOnlyAfterBoth() {
        var pace = BenchPace()
        let page = key(0)
        pace.began(for: "a"); pace.names(page)
        pace.began(for: "a"); pace.names(page)
        pace.ended(for: "a", naming: page)
        #expect(pace.awake(page))
        pace.ended(for: "a", naming: page)
        #expect(!pace.awake(page) && pace.calls == 0)
    }

    @Test func aPageOpenedByACallThatNamedNoneDrawsFullyUntilNoCallIsInFlight() {
        var pace = BenchPace()
        let opened = key(0), other = key(1)
        pace.began(for: "a")
        pace.woke(opened, for: "a")
        pace.began(for: "a"); pace.names(other)
        #expect(pace.awake(opened) && pace.awake(other))
        pace.ended(for: "a", naming: nil)
        #expect(pace.awake(opened), "another call is still in flight")
        pace.ended(for: "a", naming: other)
        #expect(!pace.awake(opened) && !pace.awake(other))
        pace.began(for: "a"); pace.names(other)
        #expect(!pace.awake(opened), "a later call about another page does not wake it")
    }

    @Test func anotherAgentsCallsDoNotKeepAnOpenedPageAwake() {
        var pace = BenchPace()
        let opened = key(0), theirs = key(1)
        pace.began(for: "a")
        pace.woke(opened, for: "a")
        pace.began(for: "b"); pace.names(theirs)
        pace.ended(for: "a", naming: nil)
        #expect(!pace.awake(opened), "only b's poll is in flight")
        pace.began(for: "b")
        #expect(!pace.awake(opened))
        pace.began(for: "a")
        #expect(!pace.awake(opened), "a's next call wakes it only by naming it")
    }

    @Test func aPageWokenWithNoCallInFlightRestsAtOnce() {
        var pace = BenchPace()
        let page = key(0)
        pace.woke(page, for: "a")
        #expect(!pace.awake(page))
        pace.began(for: "a")
        #expect(!pace.awake(page))
    }

    @Test func aCallAboutOnePageLeavesTheOthersResting() {
        var pace = BenchPace()
        let a = key(0), b = key(1)
        pace.woke(b, for: "a")
        pace.began(for: "a"); pace.names(a); pace.woke(a, for: "a")
        #expect(pace.awake(a) && !pace.awake(b))
    }

    @Test func aRestedPageIsForgotten() {
        var pace = BenchPace()
        let page = key(0)
        pace.began(for: "a"); pace.woke(page, for: "a")
        pace.forget(page)
        #expect(!pace.awake(page))
    }

    @Test func aCallThatIsNeverAnsweredEndsAtItsPatience() async throws {
        let bench = Bench()
        var replies: [[String: Any]] = []
        _ = bench.answerOnce(within: 0.05) { replies.append($0) }
        #expect(bench.callsInFlight == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(bench.callsInFlight == 0)
        #expect(replies.count == 1 && (replies.first?["error"] as? String)?.hasPrefix("no answer within") == true)
    }

    @Test func aCallAnsweredTwiceAndTimedOutIsCountedOnce() async throws {
        let bench = Bench()
        var replies = 0
        let other = bench.answerOnce(within: 600) { _ in }
        let call = bench.answerOnce(within: 0.05) { _ in replies += 1 }
        call.answer(["ok": true])
        call.answer(["ok": true])
        try await Task.sleep(for: .milliseconds(400))
        #expect(replies == 1 && bench.callsInFlight == 1, "only the other call is still in flight")
        other.answer([:])
        #expect(bench.callsInFlight == 0)
    }

    @Test func aTimeOutGoesThroughTheCallersWrappers() async throws {
        let bench = Bench()
        var wrapped: [String: Any]?
        var answer: ([String: Any]) -> Void = { _ in }
        let call = bench.answerOnce(within: 0.05, timingOut: { answer($0) }) { wrapped = $0 }
        answer = { reply in var out = reply; out["wrapped"] = true; call.answer(out) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(wrapped?["wrapped"] as? Bool == true && bench.callsInFlight == 0)
    }

    @Test func aHelperWithoutThePatchIsSentNothing() {
        let helper = UUID()
        for interval in [0, ChromiumPage.restingInterval] {
            #expect(ChromiumFrames.next(interval: interval, capable: false, remote: "tab-1", helper: helper, sent: nil) == nil)
        }
    }

    @Test func aPageIsToldOnlyWhatChanges() {
        let helper = UUID(), slow = ChromiumPage.restingInterval
        #expect(ChromiumFrames.next(interval: 0, capable: true, remote: "tab-1", helper: helper, sent: nil) == nil,
                "a new page draws at the display's rate already")
        let rested = ChromiumFrames.next(interval: slow, capable: true, remote: "tab-1", helper: helper, sent: nil)
        #expect(rested?.interval == slow)
        #expect(ChromiumFrames.next(interval: slow, capable: true, remote: "tab-1", helper: helper, sent: rested) == nil)
        #expect(ChromiumFrames.next(interval: 0, capable: true, remote: "tab-1", helper: helper, sent: rested)?.interval == 0)
    }

    @Test func aRestartedHelpersPageWithTheSameNameIsToldAgain() {
        let slow = ChromiumPage.restingInterval
        let old = ChromiumFrames.Sent(remote: "tab-1", helper: UUID(), interval: slow)
        #expect(ChromiumFrames.next(interval: slow, capable: true, remote: "tab-1", helper: UUID(), sent: old)?.interval == slow)
    }

    @Test func onlyARestingPageInTheRoomIsPaced() {
        #expect(ChromiumPage.frameInterval(resting: true, inRoom: true) == ChromiumPage.restingInterval)
        #expect(ChromiumPage.frameInterval(resting: true, inRoom: false) == 0)
        #expect(ChromiumPage.frameInterval(resting: false, inRoom: true) == 0)
        #expect(ChromiumPage.frameInterval(resting: true, inRoom: true, pictureInPicture: true) == 0)
        #expect(ChromiumPage.restingInterval > 0 && ChromiumPage.restingInterval <= 1000)
    }
}

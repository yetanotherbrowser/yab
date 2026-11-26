import AppKit
import MailCore
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct MailCodeTimerTests {
    private func item(at: Date, lifetime: TimeInterval = 600) -> MailCodeItem {
        MailCodeItem(account: "codes@test", message: "m-\(UUID())", thread: "t", address: "bank@test", at: at,
                     read: MailCodeRead(code: "481902", shown: "481 902", expires: at.addingTimeInterval(lifetime)))
    }

    @Test func noClockRunsWhileNoCodeIsLive() {
        let state = MailCodeState()
        #expect(state.timer == nil)
        let now = Date()
        _ = state.state(item(at: now.addingTimeInterval(-700)), now: now)
        #expect(state.timer == nil)
    }

    @Test func aLiveCodeWakesItsReadersAtItsNextMinuteOnly() throws {
        let state = MailCodeState(), now = Date()
        #expect(state.state(item(at: now.addingTimeInterval(-30)), now: now) == .fresh)
        let timer = try #require(state.timer)
        #expect(abs(timer.fireDate.timeIntervalSince(now) - 30) < 0.5)
        let before = state.revision
        // Foundation's own callback, as in crash #1010: synchronous on main.
        timer.fire()
        #expect(state.revision == before &+ 1)
        // Nobody read a code again: no clock.
        #expect(state.timer == nil)
    }

    @Test func aCodeReadsDifferentlyAtEachMinuteAndAtItsEnd() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let live = item(at: at, lifetime: 150)
        #expect(MailCodeState.nextChange(live, state: .fresh, now: at) == at.addingTimeInterval(30))
        #expect(MailCodeState.nextChange(live, state: .fresh, now: at.addingTimeInterval(30)) == at.addingTimeInterval(90))
        #expect(MailCodeState.nextChange(live, state: .fresh, now: at.addingTimeInterval(100)) == at.addingTimeInterval(150))
        #expect(MailCodeState.nextChange(live, state: .expired, now: at.addingTimeInterval(151)) == nil)
        #expect(MailCodeState.nextChange(live, state: .used, now: at) == nil)
        // Dated ahead of this Mac's clock: it counts once within half a minute.
        #expect(MailCodeState.nextChange(live, state: .expired, now: at.addingTimeInterval(-100)) == at.addingTimeInterval(-30))
    }

    @Test func scheduledTimerDoesNotRetainItsState() throws {
        var state: MailCodeState? = MailCodeState()
        weak var weakState = state
        _ = state?.state(item(at: Date()))
        let timer = try #require(state?.timer)
        defer { timer.invalidate() }
        state = nil
        #expect(weakState == nil)
        timer.fire()
    }

    @Test func aNewerCodeDatedAheadWakesItsElderWhenItComesDue() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let old = item(at: at, lifetime: 600)
        // A newer code from the same sender, dated two minutes ahead of this Mac.
        let due = MailCodeState.nextChange(old, state: .fresh, now: at, replacedAt: at.addingTimeInterval(120))
        #expect(due == at.addingTimeInterval(60))
        let later = MailCodeState.nextChange(old, state: .fresh, now: at.addingTimeInterval(20), replacedAt: at.addingTimeInterval(70))
        #expect(later == at.addingTimeInterval(40))
    }

    @Test func aPageStartingOrStoppingToWaitForACodeRedrawsTheCards() async {
        // A card's "Fill on site" button reads the tab's waiting field, which isn't observed.
        let state = MailCodeState(), tab = Tab(shy: true)
        defer { tab.close() }
        let before = state.revision
        tab.waitingCode = Tab.WaitingCode(document: "d", field: "f", request: CodeRequest(), address: URL(string: "https://bank.test/")!)
        await turn()
        // At least once: other suites' tabs share the signal.
        #expect(state.revision != before)
        let waited = state.revision
        tab.waitingCode = nil
        await turn()
        #expect(state.revision != waited)
    }

    @Test func aTabThatWasntWaitingStillIsntMovesNothing() {
        let box = Tab.WaitingCode(document: "d", field: "f", request: CodeRequest(), address: URL(string: "https://bank.test/")!)
        #expect(!Tab.codeBoxMoves(from: nil, to: nil))
        #expect(Tab.codeBoxMoves(from: nil, to: box))
        #expect(Tab.codeBoxMoves(from: box, to: nil))
        // Forms sets the same box again on every field message: nothing moved.
        #expect(!Tab.codeBoxMoves(from: box, to: box))
        let elsewhere = Tab.WaitingCode(document: "d", field: "g", request: CodeRequest(), address: URL(string: "https://bank.test/")!)
        #expect(Tab.codeBoxMoves(from: box, to: elsewhere))
    }

    /// A turn of the main loop, for what is told on the next one.
    private func turn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }
}

import AppKit
import Testing
@testable import Fast

/// The last few tabs you were on stay awake (feedback #44): going back and
/// forth between a list and a page from it never finds either loaded again.
struct RecentTabsSleepTests {
    /// A window with `count` hidden pages behind the one on screen, none of
    /// them looked at yet.
    @MainActor private func world(_ count: Int) async throws -> (Browser, [Tab], Tab, () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let hidden = (0..<count).map { browser.open(URL(string: "about:blank#hidden\($0)")!, foreground: true) }
        let front = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        for tab in hidden {
            for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(!tab.loading)
        }
        browser.recent = []
        let done = {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        return (browser, hidden, front, done)
    }

    /// Each tab in turn on screen, then the front one again.
    @MainActor private func visit(_ some: [Tab], then front: Tab, in browser: Browser) {
        for tab in some { browser.activeID = tab.id }
        browser.activeID = front.id
    }

    @MainActor @Test func theTabJustLeftComesFirst() async throws {
        let (browser, hidden, front, done) = try await world(3)
        defer { done() }
        visit([hidden[0], hidden[1]], then: front, in: browser)
        #expect(browser.recentlyUsed() == [hidden[1].id, hidden[0].id])
        // Back to one already in the list: it moves to the front, and the
        // one on screen is never in it.
        browser.activeID = hidden[0].id
        #expect(browser.recentlyUsed() == [front.id, hidden[1].id])
        browser.activeID = front.id
        #expect(browser.recentlyUsed() == [hidden[0].id, hidden[1].id])
        // A closed tab is no longer among them.
        browser.close(hidden[0])
        #expect(!browser.recentlyUsed().contains(hidden[0].id))
    }

    @MainActor @Test func theTimerNeverTakesTheLastFew() async throws {
        let (browser, hidden, front, done) = try await world(7)
        defer { done() }
        visit(hidden, then: front, in: browser)
        let used = browser.recentlyUsed()
        #expect(used.count == Browser.keepRecent)
        #expect(used == hidden.reversed().prefix(Browser.keepRecent).map(\.id))
        // Every one left long ago: only those not among the last five go,
        // the one left longest first.
        let idle = browser.idleTabs(within: Browser.usualSleepAfter, now: AwakeClock.now + Browser.usualSleepAfter + 60).map(\.id)
        #expect(idle == [hidden[0].id, hidden[1].id])
    }

    @MainActor @Test func memoryOutTakesTheLastFewLast() async throws {
        let (browser, hidden, front, done) = try await world(3)
        defer { done() }
        // Back and forth between two, the third never looked at.
        visit([hidden[0], hidden[1], hidden[0], hidden[1]], then: front, in: browser)
        // Seen under ten minutes, every one of them: nothing goes.
        #expect(browser.relief(now: AwakeClock.now + 60) == nil)
        // Left alone longer: the other tab first, whatever it weighs.
        let now = AwakeClock.now + 11 * 60
        #expect(browser.relief(now: now)?.id == hidden[2].id)
        // Nothing else left: the one of the two left longest ago, then the other.
        browser.passedOver = [hidden[2].id]
        #expect(browser.relief(now: now)?.id == hidden[0].id)
        browser.passedOver = [hidden[2].id, hidden[0].id]
        #expect(browser.relief(now: now)?.id == hidden[1].id)
    }

    /// A pin is never memory's to take: nothing older left, nothing goes.
    @MainActor @Test func aPinNeverGoes() async throws {
        let (browser, hidden, front, done) = try await world(2)
        defer { done() }
        visit([hidden[0]], then: front, in: browser)
        hidden[0].pin = "P"
        defer { hidden[0].pin = nil }
        let now = AwakeClock.now + 11 * 60
        #expect(browser.relief(now: now)?.id == hidden[1].id)
        browser.passedOver = [hidden[1].id]
        #expect(browser.relief(now: now) == nil)
        #expect(browser.relief(now: now + 24 * 3600) == nil)
    }

    /// #399: the half beside the tab in front is on screen for as long as
    /// the pair is. Its time unwatched was counted from when the pair came
    /// up, so a page read beside another for hours went to sleep within a
    /// minute of the pair being left.
    @MainActor @Test func aSplitHalfIsSeenUntilThePairLeavesTheScreen() async throws {
        let (browser, hidden, front, done) = try await world(2)
        defer { done() }
        let beside = hidden[0], elsewhere = hidden[1]
        browser.pairs = [Pair(first: beside.id, second: front.id)]
        browser.restage()
        try #require(browser.stagePair?.contains(beside.id) == true && browser.activeID == front.id)
        // Five hours beside the tab in front, never in front itself.
        beside.touch(at: Date(timeIntervalSinceNow: -5 * 3600))
        browser.activeID = elsewhere.id
        try #require(browser.stagePair == nil)
        let now = AwakeClock.now
        #expect(beside.idle(at: now) < 60)
        #expect(!browser.idleTabs(within: Browser.usualSleepAfter, now: now).contains { $0 === beside })
        // Memory out leaves it its ten minutes, as it does the half that
        // was in front.
        browser.recent = []
        #expect(browser.relief(now: now) == nil)
    }
}

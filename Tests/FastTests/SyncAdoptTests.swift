import AppKit
import Testing
@testable import Fast

/// A row from another Mac, into a live window (Browser.adopt): opened there
/// comes in asleep and in its place, closed there goes, and the page on
/// screen here keeps its address and stays in front.
@MainActor
@Suite(.serialized)
struct SyncAdoptTests {
    private func world(_ body: (Browser) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try body(browser)
    }

    private func page(_ browser: Browser, _ n: Int, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy)
        browser.prepare(tab)
        tab.restore(url: URL(string: "https://adopt.test/\(n)")!, title: "T\(n)")
        return tab
    }

    private func entry(_ tab: Tab, url: String? = nil, pin: String? = nil, kept: Bool? = nil) -> Session.Entry {
        Session.Entry(url: url ?? tab.address!.absoluteString, title: tab.title, pin: pin, kept: kept, id: tab.id.uuidString)
    }

    @Test func openedElsewhereComesInAndClosedElsewhereGoes() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2), c = page(browser, 3)
            browser.lay([a, b, c])
            browser.activeID = a.id
            let new = UUID()
            let shape = Session.Shape(tabs: [
                entry(a),
                Session.Entry(url: "https://adopt.test/9", title: "From the other Mac", id: new.uuidString),
                entry(c),
            ], active: 0)
            browser.adopt(shape, in: browser.spaceID)
            #expect(browser.tabs.map(\.id) == [a.id, new, c.id])
            #expect(browser.tabs[1].asleep && browser.tabs[1].title == "From the other Mac")
            #expect(browser.activeID == a.id)
            #expect(!browser.tabs.contains { $0.id == b.id })
        }
    }

    /// Feedback #1877: a tab just opened here, which sync's journal has not
    /// had yet (opened after a delivery read the rows, or a link's tab with
    /// no address yet), is not "closed elsewhere". It stays in front, where
    /// it is in the row; one the journal had and lost still goes.
    @Test func aTabSyncNeverHadStaysWhereItIs() {
        world { browser in
            let a = page(browser, 1), fresh = page(browser, 2), c = page(browser, 3)
            let blank = Tab()
            browser.prepare(blank)
            browser.lay([a, fresh, c, blank])
            browser.activeID = fresh.id
            let held: Set<String> = [a.id.uuidString, c.id.uuidString]
            browser.adopt(.init(tabs: [entry(a), entry(c, url: "https://adopt.test/c-moved")], active: 0), in: browser.spaceID, held: held)
            #expect(browser.tabs.map(\.id) == [a.id, fresh.id, c.id, blank.id])
            #expect(!fresh.gone && !blank.gone)
            #expect(browser.activeID == fresh.id)
            #expect(c.address?.absoluteString == "https://adopt.test/c-moved")
        }
    }

    @Test func aTabTheJournalHadAndLostStillGoes() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            browser.lay([a, b])
            browser.activeID = b.id
            let held: Set<String> = [a.id.uuidString, b.id.uuidString]
            browser.adopt(.init(tabs: [entry(a)], active: 0), in: browser.spaceID, held: held)
            #expect(browser.tabs.map(\.id) == [a.id])
            #expect(b.gone)
            #expect(browser.activeID == a.id)
        }
    }

    @Test func thePageInFrontKeepsItsAddress() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            browser.lay([a, b])
            browser.activeID = a.id
            browser.adopt(.init(tabs: [entry(a, url: "https://adopt.test/moved"), entry(b, url: "https://adopt.test/b-moved")], active: 0), in: browser.spaceID)
            #expect(a.address?.absoluteString == "https://adopt.test/1")
            #expect(b.address?.absoluteString == "https://adopt.test/b-moved")
        }
    }

    @Test func closingTheTabInFrontLandsOnAnother() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            browser.lay([a, b])
            browser.activeID = b.id
            browser.adopt(.init(tabs: [entry(a)], active: 0), in: browser.spaceID)
            #expect(browser.tabs.map(\.id) == [a.id])
            #expect(browser.activeID == a.id)
        }
    }

    @Test func pinsAndKeptComeAcross() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            browser.lay([a, b])
            browser.activeID = a.id
            browser.adopt(.init(tabs: [entry(b, pin: "B"), entry(a, kept: true)], active: 0), in: browser.spaceID)
            #expect(browser.tabs.map(\.id) == [b.id, a.id])
            #expect(b.pin == "B" && a.kept)
        }
    }

    // A tab that doesn't sync here (an agent working in it) but is ordinary
    // on the other Mac: once in the row, never twice, which the tab bar
    // trapped on. Nor an entry the other Mac listed twice.
    @Test func aTabThatDoesNotSyncHereStaysOnce() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            b.guest = "agent"
            browser.lay([a, b])
            browser.activeID = a.id
            browser.adopt(.init(tabs: [entry(b), entry(a), entry(a)], active: 0), in: browser.spaceID)
            #expect(browser.tabs.map(\.id) == [a.id, b.id])
        }
    }

    // Private tabs have no entries or pairs in sync. An update to another
    // tab in the same space keeps both their pages and their local pair.
    @Test func aPrivatePairSurvivesAnUnrelatedSyncUpdate() {
        world { browser in
            let a = page(browser, 1, shy: true), b = page(browser, 2, shy: true), c = page(browser, 3)
            let pair = Pair(first: a.id, second: b.id, share: 0.4)
            browser.lay([a, b, c])
            browser.pairs = [pair]
            browser.activeID = a.id

            browser.adopt(.init(tabs: [entry(c, url: "https://adopt.test/changed")], active: 0), in: browser.spaceID)

            #expect(Set(browser.tabs.map(\.id)) == Set([a.id, b.id, c.id]))
            #expect(browser.pairs == [pair])
            #expect(browser.stagePair == pair && browser.activeID == a.id)
            #expect(c.address?.absoluteString == "https://adopt.test/changed")
        }
    }

    @Test func aParkedPrivatePairSurvivesAnUnrelatedSyncUpdate() {
        world { browser in
            let space = UUID()
            defer {
                if let window = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString)-\(space.uuidString).json"))
                }
            }
            let a = page(browser, 1, shy: true), b = page(browser, 2, shy: true), c = page(browser, 3)
            let pair = Pair(first: a.id, second: b.id, share: 0.6)
            browser.parked[space] = Parked(tabs: [a, b, c], active: a.id, pairs: [pair])

            browser.adopt(.init(tabs: [entry(c, url: "https://adopt.test/changed")], active: 0), in: space)

            #expect(Set(browser.parked[space]?.tabs.map(\.id) ?? []) == Set([a.id, b.id, c.id]))
            #expect(browser.parked[space]?.pairs == [pair])
            #expect(browser.parked[space]?.active == a.id)
        }
    }

    @Test func aMixedPrivatePairStaysUntilItsSyncedHalfCloses() {
        world { browser in
            let a = page(browser, 1, shy: true), b = page(browser, 2), c = page(browser, 3)
            let pair = Pair(first: a.id, second: b.id, share: 0.4)
            browser.lay([a, b, c])
            browser.pairs = [pair]
            browser.activeID = a.id

            browser.adopt(.init(tabs: [entry(b), entry(c)], active: 0), in: browser.spaceID)
            // Sync's row places its tabs before the private ones. The row
            // sets left/right order, preserving each page's width share.
            let reordered = Pair(first: b.id, second: a.id, share: 0.6)
            #expect(browser.pairs == [reordered] && browser.stagePair == reordered)

            browser.adopt(.init(tabs: [entry(c)], active: 0), in: browser.spaceID)
            #expect(browser.pairs.isEmpty && browser.stagePair == nil)
            #expect(browser.tabs.contains { $0 === a })
            #expect(!browser.tabs.contains { $0 === b })
        }
    }

    @Test func anOrdinarySyncedPairCanStillBeSeparatedElsewhere() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2)
            browser.lay([a, b])
            browser.pairs = [Pair(first: a.id, second: b.id, share: 0.4)]
            browser.activeID = a.id

            browser.adopt(.init(tabs: [entry(a), entry(b)], active: 0), in: browser.spaceID)

            #expect(browser.pairs.isEmpty && browser.stagePair == nil)
            #expect(browser.tabs.map(\.id) == [a.id, b.id])
        }
    }

    @Test func anIncomingPairWinsAConflictWithALocalMixedPair() {
        world { browser in
            let a = page(browser, 1, shy: true), b = page(browser, 2), c = page(browser, 3)
            browser.lay([a, b, c])
            browser.pairs = [Pair(first: a.id, second: b.id, share: 0.4)]
            browser.activeID = b.id

            browser.adopt(.init(tabs: [entry(b), entry(c)], active: 0,
                                pairs: [.init(first: 0, second: 1, share: 0.6)]), in: browser.spaceID)

            let incoming = Pair(first: b.id, second: c.id, share: 0.6)
            #expect(browser.pairs == [incoming] && browser.stagePair == incoming)
            #expect(browser.tabs.contains { $0 === a })
        }
    }

    @Test func invalidIncomingPairsDoNotTakeTabsFromAValidPair() {
        world { browser in
            let a = page(browser, 1), b = page(browser, 2), c = page(browser, 3)
            browser.lay([a, b, c])
            browser.activeID = a.id

            browser.adopt(.init(tabs: [entry(a), entry(b), entry(c)], active: 0, pairs: [
                .init(first: 0, second: 0, share: 0.5),
                .init(first: 0, second: 1, share: .nan),
                .init(first: 0, second: 3, share: 0.5),
                .init(first: 0, second: 1, share: 0.4),
                .init(first: 0, second: 1, share: 0.4),
                .init(first: 1, second: 2, share: 0.5),
            ]), in: browser.spaceID)

            #expect(browser.pairs == [Pair(first: a.id, second: b.id, share: 0.4)])
        }
    }

    /// A local split kept because its first is private (it never syncs):
    /// a pane past its first two that another Mac has paired elsewhere is
    /// that pair's alone, never in two splits.
    @Test func aKeptLocalSplitGivesUpAPaneAnIncomingPairTook() {
        world { browser in
            let a = page(browser, 1, shy: true), b = page(browser, 2), c = page(browser, 3), d = page(browser, 4)
            browser.lay([a, b, c, d])
            browser.pairs = [Pair(first: a.id, second: b.id, more: [c.id], arrangement: .grid)]
            browser.activeID = a.id

            browser.adopt(.init(tabs: [entry(b), entry(c), entry(d)], active: 0,
                                pairs: [.init(first: 1, second: 2, share: 0.5)]), in: browser.spaceID)

            let all = browser.pairs.flatMap(\.ids)
            #expect(Set(all).count == all.count, "a tab in two splits: \(browser.pairs)")
            #expect(browser.pairs.contains { $0.first == c.id && $0.second == d.id })
            #expect(browser.pairs.contains { $0.ids == [a.id, b.id] || $0.ids == [b.id, a.id] })
        }
    }
}

import AppKit
import Combine
import Testing
@testable import Fast

/// With a big history, every page load and every tab's title change made
/// the index again, and until it was back (850 ms for 25,000 places in a
/// debug build) the field had no places: "local" offered the search on top
/// and no localhost under it, and the rows jumped once the index came. The
/// last index answers meanwhile.
@MainActor @Suite(.serialized)
struct FieldHistoryWhileIndexingTests {
    private func big() -> History {
        let now = Date()
        var visits = (0..<5_000).map { index in
            Visit(url: "https://bulk\(index % 300).example/page-\(index)", key: "bulk\(index % 300).example/page-\(index)",
                  title: "Bulk page \(index)", count: 1 + index % 5, last: now.addingTimeInterval(-Double(index) * 60), typed: nil)
        }
        visits.append(Visit(url: "http://localhost:3000/", key: "localhost", title: "Dev", count: 300, last: now, typed: 10))
        return History(visits)
    }

    private func ready(_ history: History) async {
        var waits: AnyCancellable?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            waits = history.indexReady.first().sink { _ in done.resume() }
        }
        waits?.cancel()
    }

    @Test func aPageLoadLeavesThePlacesAndReturnsRow() async throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(later: .nonPersistent())
        tab.restore(url: URL(string: "https://fixture.example/")!, title: "Fixture")
        browser.lay([tab])
        browser.activeID = nil
        let suggest = browser.prefs.searchSuggest
        browser.prefs.searchSuggest = false
        let history = big()
        browser.history = history
        browser.openFresh()
        defer {
            tab.close(); browser.dismiss(); browser.letGo()
            browser.prefs.searchSuggest = suggest
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        browser.replaceTyped("loc")
        #expect(browser.offers.first?.key == "localhost")
        // A page loads, and a tab elsewhere renames itself.
        history.record(URL(string: "https://example.org/news")!, title: "News")
        history.retitle(URL(string: "https://bulk3.example/page-3")!, title: "Bulk page 3 (1)")
        browser.replaceTyped("loca")
        #expect(browser.offers.first?.key == "localhost")
        #expect(browser.offers.first?.url == URL(string: "http://localhost:3000/"))
        #expect(browser.query.lead == 0)
        #expect(browser.ending == "lhost")
        await ready(history)
        browser.replaceTyped("local")
        #expect(browser.offers.first?.key == "localhost")
    }
}

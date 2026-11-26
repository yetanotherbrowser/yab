import SyncKit
import XCTest
@testable import YabPhone

/// History's rules (History/HistoryList, HistoryModel): days, search, what a
/// Clear and a Delete take, the Mac's pages beside this iPhone's, and the
/// places the field offers for typed words, ranked as the Mac ranks them and
/// never twice.
@MainActor
final class HistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")
    /// Friday, October 9, 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_558_000)

    private func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!.addingTimeInterval(Double(hour * 3_600 + minute * 60))
    }

    private func visit(_ url: String, _ title: String, _ date: Date, count: Int = 1) -> BrowserVisit {
        let host = URL(string: url)!.host()!.lowercased()
        return BrowserVisit(url: url, title: title, site: host, icon: host, host: host, visitedAt: date, count: count)
    }

    private func place(_ url: String, _ title: String, _ date: Date, device: String? = "mac-a") -> SyncedPlace {
        SyncedPlace(key: HistoryList.key(url), url: url, title: title, last: date.timeIntervalSince1970, typed: false, device: device)
    }

    private func entry(_ url: String, _ title: String, _ date: Date, count: Int = 1) -> HistoryEntry {
        HistoryList.entries(local: [visit(url, title, date, count: count)], synced: [])[0]
    }

    // MARK: - days

    func testInvalidLocalAndSyncedDatesNeverReachSortingOrCalendar() {
        let bad: [Double] = [.nan, .infinity, -.infinity, 1e100, -1e100]
        let locals = bad.map { visit("https://invalid.test", "Invalid", Date(timeIntervalSince1970: $0)) }
        let synced = bad.map { SyncedPlace(key: "invalid", url: "https://invalid.test", title: "Invalid", last: $0, typed: false) }
        let entries = HistoryList.entries(local: locals + [visit("https://valid.test", "Valid", now)], synced: synced)
        XCTAssertEqual(entries.map(\.title), ["Valid"])
        XCTAssertEqual(HistoryList.days(entries, now: now, calendar: calendar).count, 1)
    }

    func testPagesFallIntoTodayYesterdayAndDates() {
        XCTAssertEqual(calendar.component(.weekday, from: now), 6, "a Friday")
        let entries = HistoryList.entries(local: [
            visit("https://a.test/1", "One", at(0, 14)),
            visit("https://a.test/2", "Two", at(0, 9)),
            visit("https://a.test/3", "Three", at(1, 22)),
            visit("https://a.test/4", "Four", at(2, 8)),
            visit("https://a.test/5", "Five", at(300, 8)),
        ], synced: [])
        let days = HistoryList.days(entries, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday", "Wednesday, October 7", "Saturday, December 13, 2025"])
        XCTAssertEqual(days.map { $0.entries.map(\.title) }, [["One", "Two"], ["Three"], ["Four"], ["Five"]])
        // A Mac's clock running ahead still lands today, at the top.
        let ahead = HistoryList.entries(local: [visit("https://a.test/6", "Ahead", now.addingTimeInterval(7_200))], synced: [])
        XCTAssertEqual(HistoryList.days(ahead + entries, now: now, calendar: calendar, locale: locale).first?.entries.first?.title, "Ahead")
        XCTAssertEqual(HistoryList.days(ahead + entries, now: now, calendar: calendar, locale: locale).first?.title, "Today")
    }

    // MARK: - search

    func testSearchFindsTitleAndAddressInAnyCase() {
        let entries = HistoryList.entries(local: [
            visit("https://en.wikipedia.org/wiki/Lisbon", "Lisbon · Wikipedia", at(0, 10)),
            visit("https://www.timeout.com/lisbon", "The best things to do", at(0, 9)),
            visit("https://café.test/menu", "Café Menu", at(0, 8)),
            visit("https://news.ycombinator.com/", "Hacker News", at(0, 7)),
        ], synced: [])
        XCTAssertEqual(HistoryList.matching(entries, "LISBON").map(\.title), ["Lisbon · Wikipedia", "The best things to do"],
                       "the title, and the address of a page whose title doesn't say it")
        XCTAssertEqual(HistoryList.matching(entries, "wiki lisbon").map(\.title), ["Lisbon · Wikipedia"], "every word")
        XCTAssertEqual(HistoryList.matching(entries, "cafe").map(\.title), ["Café Menu"], "accents aside")
        XCTAssertEqual(HistoryList.matching(entries, "ycombinator").map(\.title), ["Hacker News"])
        XCTAssertEqual(HistoryList.matching(entries, "  ").count, 4, "no words, every page")
        XCTAssertTrue(HistoryList.matching(entries, "nothing like it").isEmpty)
    }

    // MARK: - the Mac's pages

    func testTheMacsPagesStandBesideThisIPhonesOnce() {
        let local = [visit("https://a.test/read", "Read here", at(0, 12)), visit("https://b.test/", "B here", at(0, 9))]
        let synced = [
            place("https://a.test/read", "Read on the Mac earlier", at(0, 8)),
            place("https://b.test/", "B on the Mac later", at(0, 13)),
            place("https://c.test/page", "Only on the Mac", at(1, 10)),
            place("https://d.test/", "Sent from this iPhone", at(0, 11), device: "iphone"),
            place("ftp://e.test/file", "Not a web page", at(0, 10)),
        ]
        let entries = HistoryList.entries(local: local, synced: synced, ownDevice: "iphone", name: { $0 == "mac-a" ? "MacBook Pro" : nil })
        XCTAssertEqual(entries.map(\.title), ["B on the Mac later", "Read here", "B here", "Only on the Mac"])
        XCTAssertEqual(entries.map(\.device), ["MacBook Pro", nil, nil, "MacBook Pro"])
        XCTAssertEqual(entries.filter(\.isSynced).map(\.key), ["b.test", "c.test/page"])
    }

    // MARK: - Delete and Clear

    func testClearRangesStartWhereTheySay() {
        XCTAssertEqual(HistoryRange.lastHour.start(now: now, calendar: calendar), now.addingTimeInterval(-3_600))
        XCTAssertEqual(HistoryRange.today.start(now: now, calendar: calendar), at(0, 0))
        XCTAssertEqual(HistoryRange.todayAndYesterday.start(now: now, calendar: calendar), at(1, 0))
        XCTAssertNil(HistoryRange.allTime.start(now: now, calendar: calendar))
        XCTAssertEqual(HistoryRange.allCases.map(\.title), ["Last Hour", "Today", "Today and Yesterday", "All Time"])
    }

    func testClearTakesItsRangeHereAndHidesTheMacsPagesInIt() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.history.fixtureVisits = [
            visit("https://a.test/now", "Now", now.addingTimeInterval(-600)),
            visit("https://a.test/morning", "Morning", at(0, 8)),
            visit("https://a.test/yesterday", "Yesterday", at(1, 20)),
            visit("https://a.test/week", "Last week", at(6, 20)),
        ]
        app.history.adoptSynced([
            place("https://mac.test/now", "Mac now", now.addingTimeInterval(-300)),
            place("https://mac.test/yesterday", "Mac yesterday", at(1, 9)),
        ], own: "iphone")
        app.history.clear(.lastHour, now: now, calendar: calendar)
        XCTAssertEqual(app.history.entries.map(\.title), ["Morning", "Yesterday", "Mac yesterday", "Last week"])
        app.history.clear(.todayAndYesterday, now: now, calendar: calendar)
        XCTAssertEqual(app.history.entries.map(\.title), ["Last week"])
        // The Mac goes there again: it is back.
        app.history.syncedChanged([place("https://mac.test/now", "Mac now", now.addingTimeInterval(120))])
        XCTAssertEqual(app.history.entries.map(\.title), ["Mac now", "Last week"])
        app.history.clear(.allTime, now: now.addingTimeInterval(180), calendar: calendar)
        XCTAssertTrue(app.history.entries.isEmpty)
    }

    func testDeleteTakesOnePageAndTheMacsComesBackOnlyWhenVisitedAgain() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.history.fixtureVisits = [visit("https://a.test/1", "One", at(0, 9)), visit("https://a.test/2", "Two", at(0, 8))]
        app.history.adoptSynced([place("https://mac.test/", "Mac page", at(0, 10))], own: "iphone")
        let mac = try XCTUnwrap(app.history.entries.first)
        XCTAssertTrue(mac.isSynced)
        app.history.delete(mac)
        app.history.delete(try XCTUnwrap(app.history.entries.first { $0.title == "Two" }))
        XCTAssertEqual(app.history.entries.map(\.title), ["One"])
        app.history.syncedChanged([place("https://mac.test/", "Mac page", at(0, 10))])
        XCTAssertEqual(app.history.entries.map(\.title), ["One"], "the same visit stays out")
        app.history.syncedChanged([place("https://mac.test/", "Mac page", at(0, 11))])
        XCTAssertEqual(app.history.entries.map(\.title), ["Mac page", "One"], "a new one is History again")
    }

    /// A Mac on an older Yab keys a server's page without its port; a newer
    /// one with it. Both records are one row, the newer visit's, whichever
    /// comes last.
    func testAnOlderMacsRecordDoesNotReplaceTheNewerRow() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.history.fixtureVisits = []
        app.history.adoptSynced([], own: "iphone")
        let newer = SyncVisit(url: "http://localhost:3000/blog", title: "Blog", last: at(0, 11).timeIntervalSince1970)
        let older = SyncVisit(id: "localhost/blog", url: "http://localhost:3000/blog", title: "Blog (older)",
                              last: at(0, 9).timeIntervalSince1970)
        XCTAssertEqual(SyncBridge.place((older, "mac-old")).key, "localhost:3000/blog")
        app.history.syncedChanged([SyncBridge.place((newer, "mac-new"))])
        app.history.syncedChanged([SyncBridge.place((older, "mac-old"))])
        XCTAssertEqual(app.history.entries.map(\.title), ["Blog"])
        XCTAssertEqual(app.history.entries.first?.visitedAt, at(0, 11))
    }

    /// A page taken out before ports were part of the key was saved without
    /// the port, and stays out under its key now until visited again.
    func testAPageTakenOutBeforePortsStaysOut() {
        var forgetting = HistoryForgetting()
        forgetting.forget("localhost/blog", last: at(0, 10).timeIntervalSince1970)
        XCTAssertTrue(forgetting.hides(place("http://localhost:3000/blog", "Blog", at(0, 10))))
        XCTAssertFalse(forgetting.hides(place("http://localhost:3000/blog", "Blog", at(0, 12))), "visited again")
        XCTAssertFalse(forgetting.hides(place("http://localhost:3000/other", "Other", at(0, 9))))
        let entries = HistoryList.entries(local: [], synced: [place("http://localhost:3000/blog", "Blog", at(0, 10))], forgetting: forgetting)
        XCTAssertTrue(entries.isEmpty)
    }

    func testForgettingIsKeptInTheProfileAndPrunedPastTwoWeeks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder)
        let page = PageFixtures.liveTab(for: URL(string: "https://example.com/a")!, id: "a")
        profile.recordVisit(page, now: now)
        profile.recordVisit(PageFixtures.liveTab(for: URL(string: "https://example.com/b")!, id: "b"), now: now)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        XCTAssertEqual(app.history.entries.count, 2, "the profile's visits")
        app.history.delete(try XCTUnwrap(app.history.entries.first { $0.url == "https://example.com/a" }))
        var forgetting = HistoryForgetting()
        forgetting.forget("mac.test/old", last: now.timeIntervalSince1970 - 20 * 86_400)
        forgetting.forget("mac.test/new", last: now.timeIntervalSince1970 - 86_400)
        forgetting.clear(from: 10, to: 20)
        forgetting.clear(from: 15, to: 30)
        XCTAssertEqual(forgetting.spans, [HistoryForgetting.Span(from: 10, to: 30)], "overlapping spans are one")
        forgetting.prune(now: now)
        XCTAssertEqual(Array(forgetting.places.keys), ["mac.test/new"])
        XCTAssertTrue(forgetting.spans.isEmpty)
        profile.setHistoryForgetting(forgetting)
        await profile.flush()
        let restored = BrowserProfile(folder: folder)
        XCTAssertEqual(restored.snapshot.visits.map(\.url), ["https://example.com/b"])
        XCTAssertEqual(restored.snapshot.historyForgetting, forgetting)
    }

    // MARK: - what goes to the Mac

    func testOnlyWebPagesOfTheLastTwoWeeksGoToTheMac() {
        let url = URL(string: "https://example.com/page?q=1")!
        XCTAssertTrue(HistoryList.syncs(url, at: now, now: now))
        XCTAssertFalse(HistoryList.syncs(url, at: now.addingTimeInterval(-15 * 86_400), now: now), "older than the Mac's two weeks")
        XCTAssertFalse(HistoryList.syncs(URL(string: "about:blank")!, at: now, now: now))
        XCTAssertFalse(HistoryList.syncs(URL(string: "https://user:secret@example.com/")!, at: now, now: now))
        XCTAssertFalse(HistoryList.syncs(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=x&redirect_uri=y")!, at: now, now: now))
        XCTAssertFalse(HistoryList.syncs(URL(string: "https://app.test/callback?code=1&state=2")!, at: now, now: now))
        XCTAssertFalse(HistoryList.syncs(URL(string: "https://login.test/?login_hint=me@example.com")!, at: now, now: now))
    }

    func testPrivateTabsAreNeverRecordedForTheMac() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let secret = PageFixtures.liveTab(for: URL(string: "https://example.com/secret")!, isPrivate: true)
        profile.recordVisit(secret)
        app.history.recorded(secret)
        XCTAssertTrue(app.history.entries.isEmpty, "Private tabs never appear")
        XCTAssertTrue(app.history.recentForSync.isEmpty)
    }

    // MARK: - places for typed words

    private func candidates(_ entries: [HistoryEntry], bookmarks: [SyncedBookmark] = []) -> [PlaceCandidate] {
        Places.candidates(history: entries, bookmarks: bookmarks)
    }

    func testAPlaceWhoseAddressTheWordsBeginComesFirstThenOftenAndLately() {
        let places = candidates([
            entry("https://github.com/excalidraw/excalidraw", "Excalidraw", at(0, 9), count: 2),
            entry("https://github.com/", "GitHub", at(5, 9), count: 20),
            entry("https://gist.github.com/me", "My gists", at(0, 9), count: 1),
            entry("https://swift.org/blog/concurrency", "Swift Concurrency explained", at(0, 9), count: 1),
            entry("https://old.test/github-tips", "Tips about GitHub", at(60, 9), count: 40),
        ])
        let ranked = Places.ranked("git", places, now: now)
        XCTAssertEqual(ranked.map(\.place.key), ["github.com", "github.com/excalidraw/excalidraw", "old.test/github-tips", "gist.github.com/me"],
                       "the front page visited often beats a page inside it; a title's match visited often comes before letters after a host's first dot")
        XCTAssertEqual(ranked.map(\.strong), [true, true, false, true])
        XCTAssertEqual(Places.ranked("hub", places, now: now).map(\.place.key).first, "github.com", "inside the host: weaker")
        XCTAssertFalse(Places.ranked("hub", places, now: now).first!.strong)
        // By the title once three letters say enough: every word begins one of its words.
        XCTAssertEqual(Places.ranked("swift conc", places, now: now).map(\.place.key), ["swift.org/blog/concurrency"])
        XCTAssertEqual(Places.ranked("tips", places, now: now).map(\.place.key), ["old.test/github-tips"])
        XCTAssertTrue(Places.ranked("oncurr", places, now: now).isEmpty, "the middle of a title's word finds nothing")
        XCTAssertTrue(Places.ranked("g", places, now: now).isEmpty, "two letters or more")
        XCTAssertEqual(Places.ranked("https://www.github.com", places, now: now).first?.place.key, "github.com", "typed with its scheme")
    }

    func testFrecencyFadesWithTimeAndCountsTypedAndBookmarks() {
        let fresh = PlaceCandidate(key: "a.test", url: "https://a.test/", title: "", host: "a.test", icon: "a.test", count: 3, typed: false,
                                   last: now, bookmarked: false)
        var month = fresh
        month.last = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(Places.frecency(fresh, now: now), 3, accuracy: 0.001)
        XCTAssertEqual(Places.frecency(month, now: now), 3 / M_E, accuracy: 0.001, "a month-old visit is about a third")
        var typed = fresh
        typed.typed = true
        XCTAssertEqual(Places.frecency(typed, now: now), 5, accuracy: 0.001)
        var mark = fresh
        mark.count = 0
        mark.last = nil
        mark.bookmarked = true
        XCTAssertEqual(Places.frecency(mark, now: now), 2, accuracy: 0.001)
    }

    func testPlacesAreOncePerPageAndSearchPagesAreTheSearchRows() {
        let synced = HistoryList.entries(local: [visit("https://a.test/page", "Here", at(0, 9), count: 2)],
                                         synced: [place("https://a.test/page", "On the Mac", at(0, 11))], ownDevice: "iphone")
        XCTAssertEqual(synced.count, 2, "two rows in History: here, then the Mac later")
        let places = candidates(synced + [
            entry("https://www.google.com/search?q=lisbon+weather", "lisbon weather · Google Search", at(0, 10)),
            entry("https://duckduckgo.com/?q=lisbon", "lisbon at DuckDuckGo", at(0, 10)),
            entry("https://www.bing.com/search?q=lisbon", "lisbon · Bing", at(0, 10)),
        ], bookmarks: [
            SyncedBookmark(title: "A page", url: "https://a.test/page"),
            SyncedBookmark(title: "Lisbon guide", url: "https://guide.test/lisbon"),
        ])
        XCTAssertEqual(places.map(\.key), ["a.test/page", "guide.test/lisbon"], "one place a page; no results pages")
        XCTAssertEqual(places[0].count, 3)
        XCTAssertEqual(places[0].title, "On the Mac", "the newest title")
        XCTAssertTrue(places[0].bookmarked)
    }

    // MARK: - the field's rows

    private func rows(_ typed: String, _ place: WordsPlace = .newTab, tabs: [TabCandidate] = [], sites: [SiteCandidate] = [],
                      places: [PlaceCandidate], except: String? = nil) -> [WordRow] {
        Words.rows(for: typed, in: place, tabs: tabs, sites: sites, places: places, except: except, now: now)
    }

    func testTheTopHitComesBeforeTheSearchAndATitlesMatchAfterAsk() {
        let places = candidates([
            entry("https://paulgraham.com/greatwork.html", "How to Do Great Work", at(0, 9), count: 3),
            entry("https://www.nngroup.com/articles/jakobs-law/", "Jakob's Law of Internet User Experience", at(1, 9)),
        ], bookmarks: [SyncedBookmark(title: "Paul Graham: Essays", url: "https://paulgraham.com/articles.html")])
        let paul = rows("paul", places: places)
        XCTAssertEqual(paul.map(\.action), [.place(url: "https://paulgraham.com/greatwork.html"),
                                            .place(url: "https://paulgraham.com/articles.html"), .search, .ask])
        XCTAssertEqual(paul.map(\.subtitle).prefix(2), ["paulgraham.com · History", "paulgraham.com · Bookmark"])
        XCTAssertEqual(paul.first?.key, .go, "Return opens the top hit")
        XCTAssertEqual(Words.grouped(paul).map(\.group), [.sites, .web, .claude])
        let jakob = rows("jakob", places: places)
        XCTAssertEqual(jakob.map(\.action), [.search, .ask, .place(url: "https://www.nngroup.com/articles/jakobs-law/")],
                       "a title's match never takes Return from the search")
        XCTAssertEqual(rows("jakob", .page, places: places).last?.action, .place(url: "https://www.nngroup.com/articles/jakobs-law/"),
                       "the plate's field offers it too")
    }

    func testAPlaceOpenAsATabIsThatTabAndTheTabInFrontIsNone() {
        let places = candidates([
            entry("https://news.ycombinator.com/", "Hacker News", at(0, 9), count: 9),
            entry("https://news.ycombinator.com/item?id=1", "A thread", at(0, 8)),
        ])
        let tab = TabCandidate(id: "work-hn", title: "Hacker News", site: "Hacker News", icon: "hn", space: "Work",
                               url: "https://news.ycombinator.com/")
        let found = rows("news", tabs: [tab], places: places)
        XCTAssertEqual(found.map(\.action), [.tab(id: "work-hn"), .place(url: "https://news.ycombinator.com/item?id=1"), .search, .ask],
                       "the open page is its tab's row, once")
        let front = rows("news", .page, tabs: [tab], places: places, except: "work-hn")
        XCTAssertFalse(front.contains { $0.action == .tab(id: "work-hn") }, "never the page in front")
        XCTAssertFalse(front.contains { $0.action == .place(url: "https://news.ycombinator.com/") })
    }

    func testAFrequentSitesRowIsNotRepeatedAndFourRowsAtMost() {
        let places = candidates([
            entry("https://lumen.events/", "Lumen", at(0, 9), count: 5),
            entry("https://lumen.events/e/design-systems-night", "Design Systems Night", at(0, 8), count: 2),
            entry("https://lumen.events/e/type-night", "Type Night", at(0, 7), count: 1),
        ])
        let found = rows("lum", sites: [SiteCandidate(key: "lumen", name: "Lumen", host: "lumen.events")], places: places)
        XCTAssertEqual(found.map(\.action), [.site(key: "lumen"), .place(url: "https://lumen.events/e/design-systems-night"),
                                             .place(url: "https://lumen.events/e/type-night"), .search])
        XCTAssertLessThanOrEqual(found.count, 4)
    }

    func testIncognitoAndSentencesGetNoPlaces() {
        let places = candidates([entry("https://book.test/", "Book a table", at(0, 9), count: 4)])
        XCTAssertEqual(rows("book", .privateTab, places: places).map(\.action), [.search])
        XCTAssertFalse(rows("book a table for two", places: places).contains { if case .place = $0.action { true } else { false } },
                       "a task reads as one: the Mac's, not a page")
        XCTAssertEqual(rows("book.test", places: places).map(\.action), [.open, .search], "an address opens as typed")
    }

    func testTheFieldOffersHistoryInAWorldAndOpensItInANewTab() throws {
        Motion.disabled = true
        let app = AppModel(world: try World.load(named: "mira"))
        StateCatalog.seedHistory(app, now: Date())
        app.surfaces.openField(.newTab)
        // Mira keeps that essay: its tab, not History's page again; then the Mac's bookmark.
        app.field.typed("paul")
        XCTAssertEqual(Array(app.fieldRows.map(\.action).prefix(2)), [.tab(id: "personal-paul"), .place(url: "https://paulgraham.com/articles.html")])
        XCTAssertFalse(app.fieldRows.contains { $0.action == .place(url: "https://paulgraham.com/greatwork.html") })
        app.field.typed("flyt")
        XCTAssertEqual(app.fieldRows.map(\.action), [.place(url: "https://www.flytap.com/en-se/flights/lisbon"),
                                                     .place(url: "https://www.flytap.com/en-se/miles-and-go"), .search, .ask])
        let top = try XCTUnwrap(app.fieldRows.first)
        XCTAssertEqual(top.title, "Flights to Lisbon · TAP Air Portugal")
        let before = app.browser.allTabs.count
        app.choose(top)
        XCTAssertEqual(app.browser.allTabs.count, before + 1)
        XCTAssertEqual(app.browser.tab?.address, "flytap.com/en-se/flights/lisbon")
        // With the eyes shut, no history at all.
        app.surfaces.openField(.newTab)
        app.field.openNewTab(privately: true)
        app.field.typed("paul")
        XCTAssertFalse(app.fieldRows.contains { if case .place = $0.action { true } else { false } })
    }

    // MARK: - opening from History

    func testAPageOpensInAnEmptyNewTabElseANewOne() throws {
        Motion.disabled = true
        let app = AppModel(world: try World.load(named: "mira"))
        StateCatalog.seedHistory(app, now: Date())
        let alfama = try XCTUnwrap(app.history.entries.first { $0.title == "Alfama · Wikipedia" })
        let hn = try XCTUnwrap(app.history.entries.first { $0.title == "Hacker News" })
        let verge = try XCTUnwrap(app.history.entries.first { $0.title == "The Verge" })
        app.browser.showSpace("personal")
        let count = app.browser.space.today.count
        app.openFromHistory(alfama)
        XCTAssertEqual(app.browser.space.today.count, count + 1, "a page in front stays: a new tab")
        XCTAssertEqual(app.browser.tab?.address, "en.wikipedia.org/wiki/Alfama")
        app.browser.open(Tab(id: "blank-1", title: "New Tab", site: "New Tab", icon: "globe", page: "blank"))
        let withBlank = app.browser.space.today.count
        app.openFromHistory(hn)
        XCTAssertEqual(app.browser.space.today.count, withBlank, "the empty New Tab takes it")
        XCTAssertEqual(app.browser.tab?.id, "blank-1")
        XCTAssertEqual(app.browser.tab?.address, "news.ycombinator.com")
        app.openFromHistory(verge)
        XCTAssertEqual(app.browser.space.today.count, withBlank, "already open in this space: brought up")
        XCTAssertEqual(app.browser.tab?.id, "personal-verge")
    }

    func testShowHistoryOpensItsOwnSheetAndSettingsPushesIt() {
        let ui = SettingsUI.shared
        defer { ui.settingsGone() }
        let app = AppModel(world: World(name: "test", space: "s", spaces: [Space(id: "s", name: "S", emoji: "🏠", tint: RGB(1, 1, 1))]))
        app.showHistory()
        XCTAssertTrue(app.surfaces.settings)
        XCTAssertEqual(ui.navigation, [.page(.history)])
        XCTAssertTrue(ui.standsAsRoot, "× closes; no ‹ to a Settings it wasn't opened from")
        ui.closePage()
        XCTAssertEqual(ui.navigation, [.page(.history)], "nothing under it to go back to")
        app.surfaces.closeSettings()
        ui.settingsGone()
        XCTAssertNil(ui.openedAt)
        Motion.disabled = true
        app.surfaces.openSettings()
        app.showHistory()
        XCTAssertFalse(ui.standsAsRoot, "from Settings it is a page: ‹ goes back")
        XCTAssertEqual(ui.navigation.last, .page(.history))
    }

    func testSettingsSaysWhereHistoryIs() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)")!)
        let content = SettingsContent(store: store, context: SettingsContext())
        XCTAssertTrue(SettingsIndex.groups(alternateIcons: false).flatMap { $0 }.contains(.history))
        // As on the Mac, under Privacy too: after the ad blocker's switch.
        XCTAssertEqual(content.sections(.privacy).first { $0.id == "privacy" }?.rows.first?.id, "history", "as on the Mac, under Privacy too")
        XCTAssertEqual(SettingsIndex.matches("history", content: content).first?.page, .history)
    }

    func testSyncHasAHistorySwitchOnByDefault() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "history-\(UUID().uuidString)")!)
        XCTAssertTrue(store.syncHistory, "on by default, as the Mac's")
        let content = SettingsContent(store: store, context: SettingsContext())
        let toggle = content.sections(.sync).flatMap(\.rows).first { $0.id == "sync.history" }
        guard case let .toggle(binding)? = toggle?.kind else { return XCTFail("no History switch in Sync") }
        binding.wrappedValue = false
        XCTAssertFalse(store.syncHistory)
        XCTAssertNil(SettingsContent(store: store, context: SettingsContext(hasMac: false)).sections(.sync).flatMap(\.rows).first { $0.id == "sync.history" },
                     "no Mac, nothing to send to")
    }
}

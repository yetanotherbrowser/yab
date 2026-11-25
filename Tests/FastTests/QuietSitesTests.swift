import XCTest
@testable import Fast

// What the blocker learns of a site, page by page, and the list a quiet
// site gets.

final class QuietSitesTests: XCTestCase {
    func testThreeWatchedPagesWithNothingNewMakeASiteQuiet() {
        var sites = QuietSites()
        XCTAssertNil(sites.visit("app.example", now: 1))
        sites.saw("t.example/collect", on: "app.example")
        XCTAssertNil(sites.visit("app.example", now: 2))
        sites.saw("t.example/collect", on: "app.example")
        XCTAssertNil(sites.visit("app.example", now: 3))
        // The fourth page has only what the lists blocked before.
        XCTAssertEqual(sites.visit("app.example", now: 4), ["t.example/collect"])
        XCTAssertEqual(sites.sites["app.example"]?.quiet, true)
    }

    func testASiteTheListsBlockNothingOnGetsNoList() {
        var sites = QuietSites()
        for now in 1...3 { XCTAssertNil(sites.visit("plain.example", now: Double(now))) }
        XCTAssertEqual(sites.visit("plain.example", now: 4), [])
    }

    func testSomethingNewStartsTheCountAgain() {
        var sites = QuietSites()
        _ = sites.visit("app.example", now: 1)
        _ = sites.visit("app.example", now: 2)
        sites.saw("ads.example/slot", on: "app.example")
        XCTAssertNil(sites.visit("app.example", now: 3))
        XCTAssertNil(sites.visit("app.example", now: 4))
        XCTAssertEqual(sites.visit("app.example", now: 5), ["ads.example/slot"])
    }

    func testEveryTenthQuietPageHasTheListsAndCanEndTheQuiet() {
        var sites = QuietSites()
        for now in 1...3 { _ = sites.visit("app.example", now: Double(now)) }
        for now in 4...12 { XCTAssertNotNil(sites.visit("app.example", now: Double(now)), "page \(now)") }
        // The tenth quiet page is watched.
        XCTAssertNil(sites.visit("app.example", now: 13))
        sites.saw("new.example/pixel", on: "app.example")
        XCTAssertEqual(sites.sites["app.example"]?.quiet, false)
        XCTAssertNil(sites.visit("app.example", now: 14))
    }

    func testMoreThanAHandfulIsNeverQuiet() {
        var sites = QuietSites()
        _ = sites.visit("news.example", now: 1)
        for n in 0...QuietSites.most { sites.saw("ads\(n).example/x", on: "news.example") }
        XCTAssertEqual(sites.sites["news.example"]?.never, true)
        XCTAssertEqual(sites.sites["news.example"]?.keys, [])
        for now in 2...20 { XCTAssertNil(sites.visit("news.example", now: Double(now))) }
        // Nothing more is noted of it.
        XCTAssertFalse(sites.saw("one.example/more", on: "news.example"))
    }

    func testAnAddressThatCantBeAKeyIsNeverQuiet() {
        var sites = QuietSites()
        _ = sites.visit("app.example", now: 1)
        sites.refuse("app.example")
        for now in 2...6 { XCTAssertNil(sites.visit("app.example", now: Double(now))) }
    }

    func testOnlyWatchedSitesLearn() {
        var sites = QuietSites()
        XCTAssertFalse(sites.saw("t.example/x", on: "never.example"))
        XCTAssertNil(sites.sites["never.example"])
    }

    func testTheLeastRecentlyVisitedSiteIsForgotten() {
        var sites = QuietSites()
        for n in 0...QuietSites.kept { _ = sites.visit("s\(n).example", now: Double(n)) }
        XCTAssertEqual(sites.sites.count, QuietSites.kept)
        XCTAssertNil(sites.sites["s0.example"])
        XCTAssertNotNil(sites.sites["s\(QuietSites.kept).example"])
    }

    func testKeyIsHostAndPath() {
        XCTAssertEqual(QuietSites.key(URL(string: "https://WWW.Google-Analytics.com/g/collect?v=2&tid=G-1#x")!), "www.google-analytics.com/g/collect")
        XCTAssertEqual(QuietSites.key(URL(string: "https://t.example")!), "t.example")
        XCTAssertNil(QuietSites.key(URL(string: "data:text/plain,hi")!))
        XCTAssertNil(QuietSites.key(URL(string: "https://t.example/" + String(repeating: "a", count: 500))!))
    }

    func testTheListBlocksTheAddressWhateverItsQuery() throws {
        let list = QuietSites.list(["t.example/g/collect"])
        XCTAssertEqual(list, #"[{"trigger":{"url-filter":"^[a-z-]+://t\\.example/g/collect([?#].*)?$"},"action":{"type":"block"}}]"#)
        let filter = "^[a-z-]+://t\\.example/g/collect([?#].*)?$"
        let regex = try NSRegularExpression(pattern: filter)
        func matches(_ url: String) -> Bool { regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        XCTAssertTrue(matches("https://t.example/g/collect"))
        XCTAssertTrue(matches("https://t.example/g/collect?v=2"))
        XCTAssertFalse(matches("https://t.example/g/collected"))
        XCTAssertFalse(matches("https://evil.example/t.example/g/collect"))
        XCTAssertFalse(matches("https://sub.t.example/g/collect"))
    }

    func testHidingSitesReachTheirSubdomains() {
        let sites: Set<String> = ["news.example", "shop.other.example"]
        XCTAssertTrue(QuietSites.hides("news.example", in: sites))
        XCTAssertTrue(QuietSites.hides("www.news.example", in: sites))
        XCTAssertFalse(QuietSites.hides("other.example", in: sites))
        XCTAssertFalse(QuietSites.hides("mobbin.com", in: sites))
    }

    // An entity's hiding (yts.*###dontfoid) reaches name.<one label> and its
    // subdomains, as Filters.onEntity matches it: those sites are never quiet.
    func testHidingEntitiesReachTheirSites() {
        let sites: Set<String> = ["yts.*", "web.popups.*"]
        XCTAssertTrue(QuietSites.hides("yts.mx", in: sites))
        XCTAssertTrue(QuietSites.hides("www.yts.mx", in: sites))
        XCTAssertTrue(QuietSites.hides("web.popups.net", in: sites))
        XCTAssertFalse(QuietSites.hides("popups.net", in: sites))
        XCTAssertFalse(QuietSites.hides("yts.example.com", in: sites))
        XCTAssertFalse(QuietSites.hides("notyts.mx", in: sites))
        XCTAssertFalse(QuietSites.hides("mx", in: sites))
    }

    func testTheListsSayWhichHoldOnlyTheGenericHiding() throws {
        // What a quiet site keeps: the lists at the end, generic hiding and
        // the exceptions that reach it, nothing that blocks.
        // Third-party, one rule a site: 6 blocks fill one list of 8.
        let lines = (0..<6).map { "||ads\($0).example^$3p" } + (0..<12).map { "##.slot\($0)" } + ["@@||news.example^$ghide"]
        let split = try XCTUnwrap(Filters.lists(Filters.convert(lines), perList: 8))
        XCTAssertEqual(split.lists.count, 3)
        XCTAssertEqual(split.hiding, 2)
        for list in split.lists.suffix(split.hiding) {
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
            let actions = Set(rules.map { ($0["action"] as? [String: Any])?["type"] as? String ?? "" })
            XCTAssertEqual(actions, ["css-display-none", "ignore-previous-rules"])
        }
        XCTAssertEqual(try XCTUnwrap(Filters.lists(Filters.convert(["||ads.example^"]))).hiding, 0)
    }

    func testFiltersNameTheSitesWithHidingOfTheirOwn() {
        let rules = Filters.convert(["news.example,shop.example##.promo", "##.ad", "~x.example##.banner"])
        XCTAssertEqual(rules.hidingSites, ["news.example", "shop.example"])
    }
}

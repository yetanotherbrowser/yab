import Network
import WebKit
import XCTest
@testable import Fast

// The filter conversion, rule by rule: what each kind of line becomes, the
// lines left out, and, with WebKit itself, that what comes out compiles and
// that an exception reaches block rules in every list.

final class FiltersTests: XCTestCase {
    func testBuiltInSelectionPreservesDefaultsOrderAndUnknownNames() {
        let all = Shield.sources
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(Shield.selectedSources(disabling: []).map(\.name), all.map(\.name))
        XCTAssertEqual(Shield.selectedSources(disabling: ["unknown-list"]).map(\.name), all.map(\.name))
        let selected = Shield.selectedSources(disabling: ["easyprivacy", "ublock-privacy"])
        XCTAssertEqual(selected.map(\.name), all.filter { !["easyprivacy", "ublock-privacy"].contains($0.name) }.map(\.name))
        XCTAssertEqual(selected.map(\.url), all.filter { !["easyprivacy", "ublock-privacy"].contains($0.name) }.map(\.url))
        XCTAssertTrue(Shield.selectedSources(disabling: Set(all.map(\.name))).isEmpty)
    }

    func testCompiledSelectionIdentityDistinguishesDisabledAndLegacyInputs() {
        let all = Shield.sources.map(\.name)
        let selected = Shield.selectedSources(disabling: ["easyprivacy"]).map(\.name)
        XCTAssertTrue(Shield.selectionMatches(nil, current: all))
        XCTAssertFalse(Shield.selectionMatches(nil, current: selected))
        XCTAssertFalse(Shield.selectionMatches(all, current: selected))
        XCTAssertTrue(Shield.selectionMatches(selected, current: selected))
        XCTAssertFalse(Shield.selectionMatches(selected, current: all))
    }

    /// The one rule a line becomes, as WebKit reads it.
    private func one(_ line: String, file: StaticString = #filePath, line number: UInt = #line) -> String? {
        let rules = Filters.convert([line])
        let all = rules.blocks + rules.exceptions + rules.important + rules.generic + rules.unhide
        XCTAssertLessThanOrEqual(all.count, 1, "\(line) made \(all.count) rules", file: file, line: number)
        return all.first?.json
    }

    private func skipped(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        let rules = Filters.convert([line])
        XCTAssertEqual(rules.count, 0, "\(line) should be left out, made \((rules.blocks + rules.generic).map(\.json))", file: file, line: number)
    }

    private let host = "^[a-z-]+://([^/]*\\\\.)?"
    /// What a rule that names no kind of load is said of: all a page
    /// loads, pop-ups included, the page itself not.
    private let loads = #","resource-type":["fetch","font","image","media","other","ping","popup","script","style-sheet","svg-document","websocket"]"#

    /// A line that names no kind of load: two rules, one for what a page
    /// loads and one for pages in frames, the page itself left alone. The
    /// first is returned, the second checked against it.
    private func split(_ line: String, file: StaticString = #filePath, line number: UInt = #line) -> String? {
        let rules = Filters.convert([line])
        let all = rules.blocks + rules.exceptions + rules.important
        XCTAssertEqual(all.count, 2, "\(line) made \(all.map(\.json))", file: file, line: number)
        guard all.count == 2 else { return nil }
        var framed = all[0]
        framed.types = ["document"]
        framed.context = "child-frame"
        XCTAssertEqual(all[1], framed, file: file, line: number)
        return all[0].json
    }

    // MARK: network

    func testDomainAnchor() {
        // A whole site's loads and frames, never a page you go to through
        // it: a mail's link through its click tracker opens.
        XCTAssertEqual(split("||ads.example.com^"), #"{"trigger":{"url-filter":"\#(host)ads\\.example\\.com[/:]"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testDomainAnchorWithPath() {
        XCTAssertEqual(split("||example.com/ads/*.js"), #"{"trigger":{"url-filter":"\#(host)example\\.com/ads/.*\\.js"\#(loads)},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("||example.com^ads^"), #"{"trigger":{"url-filter":"\#(host)example\\.com[/:]ads([^a-zA-Z0-9_.%-].*)?$"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testDomainAnchorWithoutSeparatorIsAPrefix() {
        XCTAssertEqual(split("||adserver."), #"{"trigger":{"url-filter":"\#(host)adserver\\."\#(loads)},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("||ads.example"), #"{"trigger":{"url-filter":"\#(host)ads\\.example"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testStartAndEndAnchors() {
        XCTAssertEqual(split("|http://example.com/ad.js|"), #"{"trigger":{"url-filter":"^http://example\\.com/ad\\.js$"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testPlainSubstringAndWildcards() {
        XCTAssertEqual(split("/banner/*/img"), #"{"trigger":{"url-filter":"/banner/.*/img"\#(loads)},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("*-ad-unit-*"), #"{"trigger":{"url-filter":"-ad-unit-"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testSeparatorInTheMiddle() {
        XCTAssertEqual(split("/ads^banner"), #"{"trigger":{"url-filter":"/ads[^a-zA-Z0-9_.%-]banner"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testSpecialCharactersAreEscaped() {
        XCTAssertEqual(split("/ad.php?id=(1)+[x]{y}"), #"{"trigger":{"url-filter":"/ad\\.php\\?id=\\(1\\)\\+\\[x\\]\\{y\\}"\#(loads)},"action":{"type":"block"}}"#)
    }

    func testThirdPartyAndFirstParty() {
        XCTAssertEqual(one("||tracker.net^$third-party"), #"{"trigger":{"url-filter":"\#(host)tracker\\.net[/:]","load-type":["third-party"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(one("||tracker.net^$3p"), one("||tracker.net^$third-party"))
        // First-party takes in the page you open: its loads and frames only.
        XCTAssertEqual(split("||tracker.net^$~third-party"), #"{"trigger":{"url-filter":"\#(host)tracker\\.net[/:]"\#(loads),"load-type":["first-party"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("||tracker.net^$1p"), split("||tracker.net^$~third-party"))
        skipped("||tracker.net^$3p,1p")
    }

    func testResourceTypes() {
        XCTAssertEqual(one("||cdn.net/ad.js$script,xhr"), #"{"trigger":{"url-filter":"\#(host)cdn\\.net/ad\\.js","resource-type":["fetch","script"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(one("/pixel.$image"), #"{"trigger":{"url-filter":"/pixel\\.","resource-type":["image","svg-document"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(one("||ws.example.com^$websocket,ping,beacon,other,css,font,media"),
                       #"{"trigger":{"url-filter":"\#(host)ws\\.example\\.com[/:]","resource-type":["font","media","other","ping","style-sheet","websocket"]},"action":{"type":"block"}}"#)
    }

    func testNegatedTypesAreTheRest() {
        XCTAssertEqual(one("||example.com/x$~image"),
                       #"{"trigger":{"url-filter":"\#(host)example\\.com/x","resource-type":["fetch","font","media","other","ping","script","style-sheet","websocket"]},"action":{"type":"block"}}"#)
        skipped("||example.com/x$script,~image")
    }

    func testFramesAreChildFramesOnly() {
        // Blocking a site in frames must not stop you opening it.
        XCTAssertEqual(one("||ads.example.com^$subdocument"), #"{"trigger":{"url-filter":"\#(host)ads\\.example\\.com[/:]","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(one("||evil.example^$doc"), #"{"trigger":{"url-filter":"\#(host)evil\\.example[/:]","resource-type":["document"],"load-context":["top-frame"]},"action":{"type":"block"}}"#)
    }

    func testFramesBesideOtherTypesAreTwoRules() {
        let rules = Filters.convert(["||ads.example.com^$script,subdocument"]).blocks.map(\.json)
        XCTAssertEqual(rules, [
            #"{"trigger":{"url-filter":"\#(host)ads\\.example\\.com[/:]","resource-type":["script"]},"action":{"type":"block"}}"#,
            #"{"trigger":{"url-filter":"\#(host)ads\\.example\\.com[/:]","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}}"#,
        ])
    }

    func testPopup() {
        XCTAssertEqual(one("||popads.net^$popup"), #"{"trigger":{"url-filter":"\#(host)popads\\.net[/:]","resource-type":["popup"]},"action":{"type":"block"}}"#)
    }

    func testAllIsEverything() {
        XCTAssertEqual(one("||malware.example^$all"), #"{"trigger":{"url-filter":"\#(host)malware\\.example[/:]"},"action":{"type":"block"}}"#)
    }

    func testDomainOption() {
        XCTAssertEqual(split("/ads.js$domain=b.com|a.com"), #"{"trigger":{"url-filter":"/ads\\.js"\#(loads),"if-domain":["*a.com","*b.com"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("/ads.js$domain=~a.com"), #"{"trigger":{"url-filter":"/ads\\.js"\#(loads),"unless-domain":["*a.com"]},"action":{"type":"block"}}"#)
        XCTAssertEqual(split("/ads.js$domain=A.com"), #"{"trigger":{"url-filter":"/ads\\.js"\#(loads),"if-domain":["*a.com"]},"action":{"type":"block"}}"#)
        // WebKit takes one or the other, never both.
        skipped("/ads.js$domain=a.com|~b.a.com")
        // uBO's "every top-level domain" and non-ASCII names fail a whole list.
        skipped("/ads.js$domain=example.*")
        skipped("/ads.js$domain=bücher.example")
    }

    func testEverythingOnASite() {
        XCTAssertEqual(one("*$script,domain=site.com"), #"{"trigger":{"url-filter":".*","resource-type":["script"],"if-domain":["*site.com"]},"action":{"type":"block"}}"#)
        // Everything everywhere is not a rule, it is the web switched off,
        // however it is spelled.
        skipped("*$third-party")
        skipped("$script")
        skipped("|$third-party")
        skipped("|http$script")
        skipped("|https://$script,third-party")
        skipped("|http://*$image")
        skipped("://$script,third-party")
        skipped("@@|https://$image")
        XCTAssertEqual(one("|https://$script,third-party,domain=site.com"),
                       #"{"trigger":{"url-filter":"^https://","resource-type":["script"],"load-type":["third-party"],"if-domain":["*site.com"]},"action":{"type":"block"}}"#)
        XCTAssertNotNil(one("|https://ads.example/$script"))
    }

    func testMatchCase() {
        XCTAssertEqual(split("/BannerAd.$match-case"), #"{"trigger":{"url-filter":"/BannerAd\\.","url-filter-is-case-sensitive":true\#(loads)},"action":{"type":"block"}}"#)
    }

    func testReasonIsANote() {
        XCTAssertEqual(split("||bad.example^$reason=phishing"), split("||bad.example^"))
    }

    func testException() {
        XCTAssertEqual(one("@@||cdn.example.com/ads.js$script"), #"{"trigger":{"url-filter":"\#(host)cdn\\.example\\.com/ads\\.js","resource-type":["script"]},"action":{"type":"ignore-previous-rules"}}"#)
        // Without kinds, for what a page loads and pages in frames, never
        // the page itself: its hiding stays.
        XCTAssertEqual(split("@@/ok^"), #"{"trigger":{"url-filter":"/ok([^a-zA-Z0-9_.%-].*)?$"\#(loads)},"action":{"type":"ignore-previous-rules"}}"#)
        XCTAssertEqual(split("@@||cdn.example.com^"), #"{"trigger":{"url-filter":"\#(host)cdn\\.example\\.com[/:]"\#(loads)},"action":{"type":"ignore-previous-rules"}}"#)
    }

    func testAmazonMetricsExceptionsAreScopedToAmazonPages() throws {
        let domains = ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it",
                       "amazon.es", "amazon.ca", "amazon.co.jp", "amazon.in", "amazon.com.au"].sorted()
        let rules = Filters.convert([ShieldLists.base]).exceptions
        XCTAssertEqual(rules.count, 4)
        for name in ["unagi-eu.amazon.com", "unagi.amazon.com"] {
            let filter = "^[a-z-]+://([^/]*\\.)?" + name.replacingOccurrences(of: ".", with: "\\.") + "[/:]"
            let matching = rules.filter { $0.filter == filter }
            // Each exception covers resources and child frames separately.
            XCTAssertEqual(matching.count, 2, name)
            for rule in matching {
                XCTAssertEqual(rule.action, .allow)
                XCTAssertEqual(rule.ifDomain, domains)
                XCTAssertTrue(rule.unlessDomain.isEmpty)
                let json = try XCTUnwrap(rule.json.data(using: .utf8))
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
                let trigger = try XCTUnwrap(object["trigger"] as? [String: Any])
                XCTAssertEqual(trigger["if-domain"] as? [String], domains.map { "*" + $0 })
            }
        }
    }

    func testDocumentExceptionSparesTheWholeSite() {
        XCTAssertEqual(one("@@||bank.example^$document"), #"{"trigger":{"url-filter":".*","if-domain":["*bank.example"]},"action":{"type":"ignore-previous-rules"}}"#)
        skipped("@@||bank.example/path$document")
    }

    func testGenericHideExceptionsEndTheHidingList() {
        let rules = Filters.convert(["@@||news.example^$ghide", "@@||shop.example^$generichide", "@@*$ghide,domain=a.example|b.*",
                                     "@@||bing.com/search?$generichide", "@@||mail.example^$elemhide"])
        XCTAssertEqual(rules.exceptions.count, 0)
        XCTAssertEqual(rules.unhide.map(\.json), [
            #"{"trigger":{"url-filter":".*","if-domain":["*news.example"]},"action":{"type":"ignore-previous-rules"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*shop.example"]},"action":{"type":"ignore-previous-rules"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*a.example"]},"action":{"type":"ignore-previous-rules"}}"#,
            #"{"trigger":{"url-filter":"\#(host)bing\\.com/search\\?"},"action":{"type":"ignore-previous-rules"}}"#,
            #"{"trigger":{"url-filter":".*","if-domain":["*mail.example"]},"action":{"type":"ignore-previous-rules"}}"#,
        ])
        // Only on a block it means nothing; beside other options, or for
        // every page, it is left out.
        skipped("||news.example^$ghide")
        skipped("@@||news.example^$ghide,xhr")
        skipped("@@$ghide")
        skipped("@@|https://$ghide")
        // $elemhide takes a site's own hiding off too.
        XCTAssertEqual(Filters.convert(["mail.example##.promo", "other.example##.promo", "@@||mail.example^$elemhide"]).blocks.map(\.json),
                       [#"{"trigger":{"url-filter":"^[a-z-]+://([^/]*\\.)?other\\.example[/:]"},"action":{"type":"css-display-none","selector":".promo"}}"#])
    }

    func testImportantGoesAfterExceptions() {
        let rules = Filters.convert(["||ads.example^$important", "@@||ads.example^"])
        XCTAssertEqual(rules.important.count, 2)
        XCTAssertEqual(rules.exceptions.count, 2)
        XCTAssertEqual(rules.blocks.count, 0)
    }

    func testBadfilterTakesItsRuleBack() {
        let rules = Filters.convert(["||example.com/ad.js$script", "||other.com^$3p", "||example.com/ad.js$script,badfilter"])
        XCTAssertEqual(rules.blocks.map(\.json), [#"{"trigger":{"url-filter":"\#(host)other\\.com[/:]","load-type":["third-party"]},"action":{"type":"block"}}"#])
    }

    func testWhatWebKitCannotSayIsLeftOut() {
        skipped("||example.com^$redirect=noop.js")
        skipped("||example.com^$redirect-rule=noop.js")
        skipped("||example.com^$csp=script-src 'none'")
        skipped("||example.com^$removeparam=utm_source")
        skipped("||example.com^$to=a.com")
        skipped("||example.com^$empty")
        skipped("||example.com^$denyallow=a.com")
        skipped("||example.com^$webrtc")
        skipped("/banner\\d+/")
        skipped("/ads/$image")
        skipped("||exämple.com^")
        skipped("ad")
    }

    func testWebrtcBesideOthersIsDropped() {
        XCTAssertEqual(one("||example.com^$script,webrtc"), one("||example.com^$script"))
    }

    func testDuplicatesCountOnce() {
        XCTAssertEqual(Filters.convert(["||a.example^", "||a.example^", "0.0.0.0 a.example"]).blocks.count, 2)
    }

    // MARK: hosts files

    func testHostsLines() {
        XCTAssertEqual(split("127.0.0.1 ads.example.com"), split("||ads.example.com^"))
        XCTAssertEqual(split("0.0.0.0\tADS.example.com"), split("127.0.0.1 ads.example.com"))
        skipped("127.0.0.1 localhost")
        XCTAssertEqual(Filters.convert(["# a comment in a hosts file"]).count, 0)
    }

    func testBadfilterCancelsHostsRuleAcrossLists() {
        for lists in [
            ["127.0.0.1 t.co\n127.0.0.1 ads.example.com", "||t.co^$badfilter"],
            ["||t.co^$badfilter", "127.0.0.1 t.co\n127.0.0.1 ads.example.com"],
        ] {
            let rules = Filters.convert(lists)
            XCTAssertEqual(rules.blocks.count, 2)
            XCTAssertEqual(Set(rules.blocks.map(\.filter)), [Filters.onSite("ads.example.com")])
        }
    }

    // MARK: cosmetic

    func testGenericHide() {
        XCTAssertEqual(Filters.convert(["##.ad-banner"]).generic.count, 1)
        XCTAssertEqual(one("##.ad-banner"), #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad-banner"}}"#)
    }

    func testSiteHide() {
        // One rule a site, matched by the page's address: a ".*" rule with
        // the sites as a condition is given to every load of every page.
        XCTAssertEqual(Filters.convert(["b.com,a.com##div[id^=\"ad-\"]"]).blocks.map(\.json), [
            #"{"trigger":{"url-filter":"^[a-z-]+://([^/]*\\.)?a\\.com[/:]"},"action":{"type":"css-display-none","selector":"div[id^=\"ad-\"]"}}"#,
            #"{"trigger":{"url-filter":"^[a-z-]+://([^/]*\\.)?b\\.com[/:]"},"action":{"type":"css-display-none","selector":"div[id^=\"ad-\"]"}}"#,
        ])
        XCTAssertEqual(one("~a.com##.promo"), #"{"trigger":{"url-filter":".*","unless-domain":["*a.com"]},"action":{"type":"css-display-none","selector":".promo"}}"#)
        skipped("a.com,~b.a.com##.promo")
    }

    func testHideExceptionSparesItsSite() {
        // A generic rule excepted somewhere is matched per page, with the
        // excepted site left out, instead of leaving it everywhere.
        let rules = Filters.convert(["##.sponsor", "news.com#@#.sponsor"]).generic.map(\.json)
        XCTAssertEqual(rules, [#"{"trigger":{"url-filter":".*","unless-domain":["*news.com"]},"action":{"type":"css-display-none","selector":".sponsor"}}"#])
        // And a site's own rule, excepted on that site, is gone.
        XCTAssertEqual(Filters.convert(["shop.news.com##.sponsor", "news.com#@#.sponsor"]).blocks.count, 0)
        // Excepted on a part of the site, it can't be kept for the rest:
        // "*news.com" would reach the part.
        XCTAssertEqual(Filters.convert(["news.com,other.com##.sponsor", "shop.news.com#@#.sponsor"]).blocks.map(\.json),
                       [#"{"trigger":{"url-filter":"^[a-z-]+://([^/]*\\.)?other\\.com[/:]"},"action":{"type":"css-display-none","selector":".sponsor"}}"#])
        XCTAssertEqual(Filters.convert(["news.com##.sponsor", "shop.news.com#@#.sponsor"]).blocks.count, 0)
        // An exception with no site takes the selector away altogether.
        XCTAssertEqual(Filters.convert(["##.sponsor", "#@#.sponsor"]).count, 0)
    }

    func testProceduralCosmeticsAreLeftOut() {
        skipped("example.com##div:has-text(Sponsored)")
        skipped("example.com##.x:upward(2)")
        skipped("example.com##.x:style(display: none !important)")
        skipped("example.com#?#.x:-abp-has(.ad)")
        skipped("example.com#$#.x { display: none }")
        skipped("example.com##^script:has-text(ads)")
        // Standard CSS is kept, :has() included.
        XCTAssertNotNil(one("example.com##article:has(> .ad)"))
    }

    func testSelectorIsQuotedForJSON() {
        XCTAssertEqual(one(#"##a[href^="http://ad\x"]"#), #"{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"a[href^=\"http://ad\\x\"]"}}"#)
    }

    // MARK: lists

    private func parsed(_ list: String) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]] ?? []
    }

    private func actions(_ list: String) -> [String] {
        parsed(list).map { ($0["action"] as? [String: Any])?["type"] as? String ?? "" }
    }

    func testConditionalUniversalBoundaryPreservesEveryRule() throws {
        for (count, expectedParts) in [(65_534, 1), (65_535, 2)] {
            var rules = Filters.Rules()
            rules.generic = (0..<count).map { Filters.Rule(action: .hide(".ad\($0)"), filter: ".*", unlessDomain: ["safe.example"]) }
            let plan = try XCTUnwrap(Filters.plan(rules))
            XCTAssertEqual(plan.parts.count, expectedParts)
            XCTAssertEqual(plan.hiding, expectedParts)
            XCTAssertEqual(plan.left, 0)
            XCTAssertEqual(plan.parts.flatMap { Array($0.body) }, rules.generic)
            for part in plan.parts { XCTAssertLessThanOrEqual(part.body.count, 65_534) }
        }
    }

    func testUniversalBudgetReservesLargeTailAndKeepsOrder() throws {
        var rules = Filters.Rules()
        rules.blocks = (0..<40_000).map { Filters.Rule(action: .block, filter: ".*", ifDomain: ["b\($0).example"]) }
        rules.exceptions = (0..<37_000).map { Filters.Rule(action: .allow, filter: Filters.onSite("a\($0).example")) }
        rules.important = (0..<250).map { Filters.Rule(action: .block, filter: ".*", ifDomain: ["i\($0).example"]) }
        rules.generic = [Filters.Rule(action: .hide(".generic"), filter: ".*")]
        let plan = try XCTUnwrap(Filters.plan(rules))
        XCTAssertEqual(plan.parts.count, 3)
        XCTAssertEqual(plan.hiding, 1)
        XCTAssertEqual(plan.left, 0)
        XCTAssertEqual(plan.parts.dropLast().flatMap { Array($0.body) }, rules.blocks)
        XCTAssertEqual(plan.parts[0].body.count, 65_534 - 37_250)
        for part in plan.parts.dropLast() {
            XCTAssertEqual(part.tail, rules.exceptions + rules.important)
            XCTAssertLessThanOrEqual(part.body.count + part.tail.count, 65_534)
        }
        XCTAssertEqual(Array(plan.parts.last!.body), rules.generic)
    }

    func testUniversalBudgetKeepsFlagsAndConditionsDistinct() throws {
        var rules = Filters.Rules()
        rules.blocks = (0..<65_535).map { n in
            var rule = Filters.Rule(action: .block, filter: ".*", ifDomain: ["safe.example"])
            rule.types = n.isMultiple(of: 2) ? ["image"] : ["script"]
            rule.party = n.isMultiple(of: 3) ? "third-party" : nil
            rule.context = n.isMultiple(of: 5) ? "child-frame" : nil
            return rule
        }
        let plan = try XCTUnwrap(Filters.plan(rules))
        XCTAssertEqual(plan.parts.map { $0.body.count }, [65_534, 1])
        XCTAssertEqual(plan.parts.flatMap { Array($0.body) }, rules.blocks)
        XCTAssertEqual(plan.left, 0)
    }

    func testUniversalBudgetAccountsForAllowResets() throws {
        var rules = Filters.Rules()
        let block = Filters.Rule(action: .block, filter: ".*")
        let allow = Filters.Rule(action: .allow, filter: ".*")
        // Two blocks combine into one action, but the allow resets that map.
        // Each triple costs two actions. The first part holds 32,767 triples.
        rules.blocks = (0..<40_000).flatMap { _ in [block, block, allow] }
        let plan = try XCTUnwrap(Filters.plan(rules))
        XCTAssertEqual(plan.parts.map { $0.body.count }, [98_301, 21_699])
        XCTAssertEqual(plan.parts.flatMap { Array($0.body) }, rules.blocks)
        XCTAssertEqual(plan.left, 0)
    }

    func testOrdinaryLargeNetworkAndGenericListsStayLarge() throws {
        var rules = Filters.Rules()
        rules.blocks = (0..<149_000).map { Filters.Rule(action: .block, filter: Filters.onSite("b\($0).example")) }
        rules.generic = (0..<149_000).map { Filters.Rule(action: .hide(".ad\($0)"), filter: ".*") }
        let plan = try XCTUnwrap(Filters.plan(rules))
        XCTAssertEqual(plan.parts.count, 2)
        XCTAssertEqual(plan.hiding, 1)
        XCTAssertEqual(plan.left, 0)
        XCTAssertEqual(plan.parts.map { $0.body.count }, [149_000, 149_000])
    }

    func testEveryListEndsWithEveryExceptionThenImportant() throws {
        var lines = (0..<10).map { "||block\($0).example^$3p" }
        lines += ["@@||block1.example^$script", "@@||block7.example^$image", "||must.example^$important,3p"]
        let rules = Filters.convert(lines)
        let lists = try XCTUnwrap(Filters.lists(rules, perList: 12)).lists
        // 10 blocks, 3 rules in the tail: 9 blocks a list.
        XCTAssertEqual(lists.count, 2)
        for list in lists {
            XCTAssertLessThanOrEqual(parsed(list).count, 12)
            XCTAssertEqual(Array(actions(list).suffix(3)), ["ignore-previous-rules", "ignore-previous-rules", "block"])
            let last = (parsed(list).last?["trigger"] as? [String: Any])?["url-filter"] as? String
            XCTAssertEqual(last, "^[a-z-]+://([^/]*\\.)?must\\.example[/:]")
        }
        XCTAssertEqual(lists.flatMap { parsed($0).dropLast(3) }.count, 10)
    }

    func testGenericHidingIsAListOfItsOwn() throws {
        let rules = Filters.convert(["||a.example^$3p", "##.ad", "~x.example##.promo", "a.example##.own", "@@||bank.example^$document",
                                     "@@||news.example^$ghide", "@@||cdn.example^$script"])
        let lists = try XCTUnwrap(Filters.lists(rules)).lists
        XCTAssertEqual(lists.count, 2)
        // Blocks and the sites' own hiding, then every exception.
        XCTAssertEqual(actions(lists[0]), ["block", "css-display-none", "ignore-previous-rules", "ignore-previous-rules"])
        // The generic hiding, then what turns a page's hiding off: a whole
        // site's exception and $generichide, and no other exception.
        XCTAssertEqual(actions(lists[1]), ["css-display-none", "css-display-none", "ignore-previous-rules", "ignore-previous-rules"])
        let domains = parsed(lists[1]).suffix(2).map { (($0["trigger"] as? [String: Any])?["if-domain"] as? [String]) ?? [] }
        XCTAssertEqual(domains, [["*bank.example"], ["*news.example"]])
    }

    func testFewLargeLists() throws {
        // Every list costs every load a run over its address and a copy of
        // every exception, so the lists are as large as WebKit takes.
        XCTAssertLessThanOrEqual(Filters.perList, 150_000)
        XCTAssertGreaterThanOrEqual(Filters.perList, 100_000)
        // Blocking that outgrows one list spills into a second, and the
        // hiding for every site still has a list of its own: 12 blocks and
        // 2 exceptions, 8 blocks a list, then the generic hiding.
        var lines = (0..<12).map { "||b\($0).example^$3p" } + ["@@||b1.example^$script", "@@||b2.example^$image"]
        lines += (0..<3).map { "##.ad\($0)" }
        let split = try XCTUnwrap(Filters.lists(Filters.convert(lines), perList: 10, cap: 30))
        XCTAssertEqual(split.lists.count, 3)
        XCTAssertEqual(split.left, 0)
        XCTAssertEqual(actions(split.lists[2]), ["css-display-none", "css-display-none", "css-display-none"])
        // The exceptions end each list of blocks once, and no more.
        let tails = split.lists.prefix(2).map { actions($0).filter { $0 == "ignore-previous-rules" }.count }
        XCTAssertEqual(tails, [2, 2])
    }

    func testCapLeavesTheLastOut() throws {
        // At most cap / perList lists, blocking first: 40 blocks with 2
        // exceptions, 8 a list, fill the 3 lists there are and leave 16,
        // and the generic hiding finds no list left.
        var lines = (0..<40).map { "||b\($0).example^$3p" } + ["@@||b1.example^$script", "@@||b2.example^$image"]
        lines += (0..<5).map { "##.ad\($0)" }
        let split = try XCTUnwrap(Filters.lists(Filters.convert(lines), perList: 10, cap: 30))
        XCTAssertEqual(split.lists.count, 3)
        XCTAssertEqual(split.left, 16 + 5)
        let blocks = split.lists.flatMap { parsed($0).dropLast(2) }
        XCTAssertEqual((blocks.last?["trigger"] as? [String: Any])?["url-filter"] as? String, "^[a-z-]+://([^/]*\\.)?b23\\.example[/:]")
    }

    func testTheTailIsCapped() throws {
        // A quarter of a list: past it, $important rules are left out, and
        // exceptions past it are a list gone wrong, not built at all.
        let two = ["@@||a.example^$script", "@@||b.example^$script"]
        let split = try XCTUnwrap(Filters.lists(Filters.convert(["||x.example^$3p", "||y.example^$important,3p"] + two), perList: 8))
        XCTAssertEqual(split.left, 1)
        XCTAssertEqual(actions(split.lists[0]), ["block", "ignore-previous-rules", "ignore-previous-rules"])
        XCTAssertNil(Filters.lists(Filters.convert(["||x.example^$3p", "@@||c.example^$script"] + two), perList: 8))
    }

    /// The iPhone's split test input (Phone/Tests/ShieldTests.swift), on
    /// the Mac: a whole site with no kinds is two rules (loads, and pages in
    /// frames), so 2 500 sites fill the cap with blocking and the generic
    /// hiding is what is left out; a cap with room keeps it, lists of its own.
    func testManySitesFillTheCapBeforeGenericHiding() throws {
        let texts = [(0..<2_500).map { "||ad\($0).example.com^" }.joined(separator: "\n"),
                     (0..<10).map { "@@||ok\($0).example.com^$script" }.joined(separator: "\n"),
                     (0..<1_500).map { "##.promo-\($0)" }.joined(separator: "\n")]
        let rules = Filters.convert([ShieldLists.base] + texts)
        XCTAssertEqual(rules.skipped, 0)
        XCTAssertEqual(rules.generic.count, 1_509)
        let full = try XCTUnwrap(Filters.lists(rules, perList: 1_000, cap: 6_000))
        XCTAssertEqual(full.lists.count, 6)
        XCTAssertEqual(full.hiding, 0)
        XCTAssertEqual(full.left, 1_509)
        let room = try XCTUnwrap(Filters.lists(rules, perList: 1_000, cap: 12_000))
        XCTAssertEqual(room.lists.map { parsed($0).count }, [1_000, 1_000, 1_000, 1_000, 1_000, 153, 1_000, 509])
        XCTAssertEqual(room.hiding, 2)
        XCTAssertEqual(room.left, 0)
        for list in room.lists.prefix(6) {
            XCTAssertEqual(Array(actions(list).suffix(rules.exceptions.count)), Array(repeating: "ignore-previous-rules", count: rules.exceptions.count))
        }
        for list in room.lists.suffix(2) { XCTAssertEqual(Set(actions(list)), ["css-display-none"]) }
    }

    // MARK: WebKit

    /// Every shape above, compiled: one url-filter WebKit can't read, or
    /// one capital in a domain, and a whole list would fail.
    @MainActor
    func testEveryShapeCompiles() throws {
        let lines = [
            "||ads.example.com^", "||example.com/ads/*.js", "||example.com^ads^", "||ads.example", "|http://example.com/ad.js|",
            "/banner/*/img", "*-ad-unit-*", "/ads^banner", "/ad.php?id=(1)+[x]{y}", "||tracker.net^$third-party",
            "||tracker.net^$~third-party", "||cdn.net/ad.js$script,xhr", "/pixel.$image", "||ws.example.com^$websocket,ping,other,css,font,media",
            "||example.com/x$~image", "||ads.example.com^$subdocument", "||evil.example^$doc", "||ads2.example.com^$script,subdocument",
            "||popads.net^$popup", "||malware.example^$all", "/ads.js$domain=b.com|a.com", "/ads.js$domain=~a.com",
            "*$script,domain=site.com", "/BannerAd.$match-case", "@@||cdn.example.com/ads.js$script", "@@||bank.example^$document",
            "||ads.example^$important", "127.0.0.1 hosts.example.com", "##.ad-banner", "b.com,a.com##div[id^=\"ad-\"]",
            "~a.com##.promo", "##.sponsor", "news.com#@#.sponsor", "example.com##article:has(> .ad)", "/x^|",
            "@@/ok^", "@@||news.example^$ghide", "@@||bing.com/search?$generichide", "|https://$script,domain=site.com",
            "@@||mail.example^$elemhide",
        ]
        let lists = try XCTUnwrap(Filters.lists(Filters.convert(lines + [Shield.base]))).lists
        XCTAssertEqual(lists.count, 2)
        for list in lists { try compile(list) }
    }

    /// The real lists, when a run of yab has fetched them into this
    /// folder (SHIELD_LISTS=path): every list they make compiles.
    @MainActor
    func testRealListsCompile() throws {
        guard let folder = ProcessInfo.processInfo.environment["SHIELD_LISTS"] else { throw XCTSkip("SHIELD_LISTS not set") }
        let texts = Shield.sources.compactMap { try? String(contentsOfFile: "\(folder)/\($0.name).txt", encoding: .utf8) }
        XCTAssertEqual(texts.count, Shield.sources.count)
        let t0 = CFAbsoluteTimeGetCurrent()
        let rules = Filters.convert([Shield.base] + texts)
        let split = try XCTUnwrap(Filters.lists(rules))
        let badfilteredHosts = Set(texts.flatMap { text in
            text.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("||"), line.hasSuffix("^$badfilter") else { return nil }
                return Filters.plainDomain(line.dropFirst(2).dropLast("^$badfilter".count))
            }
        })
        let blockedHosts = Set(rules.blocks.filter {
            $0.action == .block && $0.types.contains("popup") && $0.context == nil && $0.party == nil
                && $0.ifDomain.isEmpty && $0.unlessDomain.isEmpty
        }.map(\.filter))
        for host in badfilteredHosts {
            XCTAssertFalse(blockedHosts.contains(Filters.onSite(host)), "\(host) was blocked despite $badfilter")
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        XCTAssertGreaterThan(rules.count, 50_000)
        XCTAssertLessThanOrEqual(split.lists.count, Filters.cap / Filters.perList)
        for list in split.lists { try compile(list) }
        print("real lists: \(rules.count) rules (\(rules.blocks.count) blocks, \(rules.exceptions.count) exceptions, "
              + "\(rules.important.count) important, \(rules.generic.count) generic hiding, \(rules.unhide.count) unhide), "
              + "\(rules.skipped) lines skipped, \(split.left) left over the cap, \(split.lists.count) lists, "
              + "converted in \(Int((t1 - t0) * 1000)) ms, compiled in \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)) ms")
        print("dropped, most first: " + rules.dropped.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("scriptlets: \(rules.scriptlets.calls.count) calls, \(rules.scriptlets.hosts.count) keys, table \(rules.scriptlets.table().utf8.count) bytes")
    }

    @MainActor
    @discardableResult
    private func compile(_ json: String) throws -> WKContentRuleList {
        let store = try XCTUnwrap(WKContentRuleListStore(url: scratch()))
        var made: WKContentRuleList?
        var failure: Error?
        let done = expectation(description: "compiled")
        store.compileContentRuleList(forIdentifier: "test-\(UUID().uuidString)", encodedContentRuleList: json) { list, error in
            made = list
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        if let failure { throw failure }
        return try XCTUnwrap(made)
    }

    @MainActor
    private func compile(_ lines: [String]) throws -> [WKContentRuleList] {
        try XCTUnwrap(Filters.lists(Filters.convert(lines))).lists.map { try compile($0) }
    }

    private var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yab-tests-\(getpid())", isDirectory: true)
    }

    private func scratch() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// WebKit's own behavior, the reason every list carries every exception:
    /// an exception in one list doesn't reach a block in another. Split the
    /// way Filters splits, the exception holds whichever list the block is in.
    @MainActor
    func testExceptionsReachEveryList() throws {
        let server = try Server()
        defer { server.stop() }
        let images = ["/ads/banner.png", "/ads/allowed.png", "/plain.png"]
        server.pages["/page"] = images.map { "<img src=\"\($0)\">" }.joined()

        // Split naively, block and exception in different lists.
        let naive = [
            try compile(#"[{"trigger":{"url-filter":"/ads/"},"action":{"type":"block"}}]"#),
            try compile(#"[{"trigger":{"url-filter":"/filler/"},"action":{"type":"block"}},{"trigger":{"url-filter":"/ads/allowed"},"action":{"type":"ignore-previous-rules"}}]"#),
        ]
        _ = try open(server, "/page", with: naive)
        XCTAssertTrue(server.paths.contains("/plain.png"))
        XCTAssertFalse(server.paths.contains("/ads/banner.png"))
        XCTAssertFalse(server.paths.contains("/ads/allowed.png"), "WebKit changed: an exception now reaches other lists")

        // Split by Filters, the block in the first list of several.
        let rules = Filters.convert(["/ads/*", "/filler1/*", "/filler2/*", "/filler3/*", "@@/ads/allowed"])
        let lists = try XCTUnwrap(Filters.lists(rules, perList: 8)).lists
        XCTAssertGreaterThan(lists.count, 1)
        _ = try open(server, "/page", with: try lists.map { try compile($0) })
        XCTAssertTrue(server.paths.contains("/plain.png"))
        XCTAssertFalse(server.paths.contains("/ads/banner.png"))
        XCTAssertTrue(server.paths.contains("/ads/allowed.png"), "the exception didn't reach the block in another list")
    }

    /// A rule that names no kind of load blocks what a page loads and
    /// pages in frames, never the page you open: in WebKit, the same rule
    /// with no kinds at all refuses to open it.
    @MainActor
    func testAPageUnderABlockedPathOpens() throws {
        let server = try Server()
        defer { server.stop() }
        server.pages["/adv/page.html"] = #"<img src="/adv/banner.png"><img src="/plain.png"><iframe src="/adv/frame.html"></iframe>"#
        server.pages["/adv/frame.html"] = "a frame"

        _ = try open(server, "/adv/page.html", with: try compile(["/adv/*"]))
        XCTAssertTrue(server.paths.contains("/adv/page.html"), "the page itself was blocked")
        XCTAssertTrue(server.paths.contains("/plain.png"))
        XCTAssertFalse(server.paths.contains("/adv/banner.png"))
        XCTAssertFalse(server.paths.contains("/adv/frame.html"))

        let bare = try compile(#"[{"trigger":{"url-filter":"/adv/"},"action":{"type":"block"}}]"#)
        _ = try open(server, "/adv/page.html", with: [bare], settle: 2)
        XCTAssertFalse(server.paths.contains("/adv/page.html"), "WebKit changed: a rule without kinds no longer blocks the page")
    }

    /// A whole site in the lists ("||klclick.com^", Peter Lowe's hosts
    /// line) blocks what pages load from it, never a page you go to on it:
    /// a mail's link through its click tracker opens. $doc still stops it.
    @MainActor
    func testAPageOfABlockedSiteOpens() throws {
        let server = try Server()
        defer { server.stop() }
        server.pages["/click"] = #"<img src="/pixel.png"><iframe src="/frame.html"></iframe>"#
        server.pages["/frame.html"] = "a frame"

        for lines in [["||127.0.0.1^"], ["127.0.0.1 127.0.0.1"]] {
            _ = try open(server, "/click", with: try compile(lines))
            XCTAssertTrue(server.paths.contains("/click"), "\(lines): the page itself was blocked")
            XCTAssertFalse(server.paths.contains("/pixel.png"), "\(lines)")
            XCTAssertFalse(server.paths.contains("/frame.html"), "\(lines)")
        }

        _ = try open(server, "/click", with: try compile(["||127.0.0.1^$doc"]), settle: 2)
        XCTAssertFalse(server.paths.contains("/click"), "$doc no longer stops the page")
    }

    /// WebKit takes if-top-url beside if-domain in one list, and each still
    /// acts: an entity's network rules ($domain=name.*) could be said by
    /// the page's address this way.
    @MainActor
    func testTopURLBesideDomainsInOneList() throws {
        let server = try Server()
        defer { server.stop() }
        server.pages["/page"] = #"<img src="/a.png"><img src="/b.png"><img src="/c.png"><img src="/plain.png">"#
        let list = "[" + [
            #"{"trigger":{"url-filter":"/a\\.png","if-domain":["*127.0.0.1"]},"action":{"type":"block"}}"#,
            #"{"trigger":{"url-filter":"/b\\.png","if-top-url":["^http://127\\.0\\.0\\.1:[0-9]+/page"]},"action":{"type":"block"}}"#,
            #"{"trigger":{"url-filter":"/c\\.png","if-top-url":["^https://elsewhere\\.example/"]},"action":{"type":"block"}}"#,
        ].joined(separator: ",") + "]"
        _ = try open(server, "/page", with: [try compile(list)])
        XCTAssertFalse(server.paths.contains("/a.png"), "if-domain stopped acting beside if-top-url")
        XCTAssertFalse(server.paths.contains("/b.png"), "if-top-url stopped acting beside if-domain")
        XCTAssertTrue(server.paths.contains("/c.png"))
        XCTAssertTrue(server.paths.contains("/plain.png"))
    }

    /// What is hidden on a page at 127.0.0.1 under these lines.
    @MainActor
    private func hidden(_ lines: [String]) throws -> [String] {
        let server = try Server()
        defer { server.stop() }
        server.pages["/page"] = #"<div class="ad">a</div><div class="own">b</div><div class="promo">c</div>"#
        let web = try open(server, "/page", with: try compile(lines))
        let done = expectation(description: "styles")
        var out: [String] = []
        let js = "['ad','own','promo'].filter(c => getComputedStyle(document.querySelector('.' + c)).display === 'none')"
        web.evaluateJavaScript(js) { value, _ in
            out = value as? [String] ?? ["?"]
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return out
    }

    @MainActor
    func testHidingAndItsExceptions() throws {
        let hides = ["##.ad", "~other.example##.promo", "127.0.0.1##.own"]
        XCTAssertEqual(try hidden(hides), ["ad", "own", "promo"])
        // $generichide: the generic rules off, the site's own kept.
        XCTAssertEqual(try hidden(hides + ["@@||127.0.0.1^$ghide"]), ["own"])
        // $elemhide: all of it off.
        XCTAssertEqual(try hidden(hides + ["@@||127.0.0.1^$elemhide"]), [])
        // An exception with no kinds for the page's own address leaves its
        // hiding alone; one for the whole site takes everything off.
        XCTAssertEqual(try hidden(hides + ["@@||127.0.0.1^"]), ["ad", "own", "promo"])
        XCTAssertEqual(try hidden(hides + ["@@||127.0.0.1^$document"]), [])
    }

    /// A list is taken whole, from a 200, only up to its size limit, and
    /// never by way of a redirect to plain http.
    func testDownloadLimits() async throws {
        let server = try Server()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        server.pages["/list"] = "||ads.example^\n"
        server.redirects["/moved"] = "\(base)/list"
        server.sizes["/big"] = 2 << 20
        let list = await Shield.Download(URL(string: base + "/list")!, most: 1 << 20).data
        XCTAssertEqual(list, Data("<!doctype html><body>||ads.example^\n</body>".utf8))
        server.reset()
        let moved = await Shield.Download(URL(string: base + "/moved")!, most: 1 << 20).data
        XCTAssertNil(moved)
        XCTAssertFalse(server.paths.contains("/list"), "followed a redirect to http")
        let big = await Shield.Download(URL(string: base + "/big")!, most: 1 << 20).data
        XCTAssertNil(big, "took more than the limit")
        let allowed = await Shield.Download(URL(string: base + "/big")!, most: 4 << 20).data
        XCTAssertEqual(allowed?.count, 2 << 20)
    }

    /// A page of this server opened under these lists, settled when its
    /// images and frames are done, loaded or refused (or after `settle`
    /// seconds, for a page that is never let in); the server then knows
    /// what was asked for.
    @MainActor
    private func open(_ server: Server, _ path: String, with lists: [WKContentRuleList], settle: TimeInterval? = nil) throws -> WKWebView {
        server.reset()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for list in lists { config.userContentController.add(list) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!))
        let done = expectation(description: "loaded")
        if let settle {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { done.fulfill() }
        } else {
            // Not before the page itself is in: an empty document has no
            // images, and none of them is still loading.
            func poll() {
                let check = "location.pathname === '\(path)' && document.readyState === 'complete' && [...document.images].every(i => i.complete)"
                web.evaluateJavaScript(check) { value, _ in
                    if value as? Bool == true { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
        }
        wait(for: [done], timeout: 30)
        return web
    }
}

/// An HTTP server on 127.0.0.1 that answers with the page set for a path,
/// or a 1x1 GIF, and remembers what was asked for.
private final class Server: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var asked = Set<String>()
    private var shown: [String: String] = [:]
    /// Paths answered with a redirect to an address, and with a body of
    /// that many bytes, sent without a length the way a stream is.
    var redirects: [String: String] = [:]
    var sizes: [String: Int] = [:]
    private(set) var port: UInt16 = 0

    var paths: Set<String> { lock.lock(); defer { lock.unlock() }; return asked }
    func reset() { lock.lock(); asked = []; lock.unlock() }
    var pages: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return shown }
        set { lock.lock(); shown = newValue; lock.unlock() }
    }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = String(target.split(separator: "?").first ?? "")
            self?.lock.lock()
            self?.asked.insert(path)
            let page = self?.shown[path]
            let moved = self?.redirects[path]
            let size = self?.sizes[path]
            self?.lock.unlock()
            if let moved {
                let reply = Data("HTTP/1.1 302 Found\r\nLocation: \(moved)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if let size {
                var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n".utf8)
                reply.append(Data(repeating: UInt8(ascii: "a"), count: size))
                connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let body: Data
            let type: String
            if let page {
                body = Data("<!doctype html><body>\(page)</body>".utf8)
                type = "text/html"
            } else {
                body = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
                type = "image/gif"
            }
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            reply.append(body)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

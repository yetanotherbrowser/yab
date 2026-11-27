import Foundation
import Testing
@testable import Fast

// uBlock Origin's $urlskip (Filters.Skip): a click tracker in a mail or an
// affiliate link, which the lists stop as a whole site (Peter Lowe's hosts,
// EasyPrivacy's ||host^), is skipped to the destination inside its address.
// The rules are the lists' own lines (uBlock filters – Privacy, 2026-10-31);
// the addresses are each tracker's real shape. Before this, every one of
// them ended on "The page couldn't load" (PageLoadFailure/chromium/-20,
// PageLoadFailure/webKit/104).

@Suite struct ShieldSkipTests {
    /// The lists' rules for the trackers people reported, as written.
    static let privacy = """
    ||awstrack.me/L0/http$doc,urlskip=/\\/L0\\/(http[^\\/?#]+)/ -uricomponent
    ||pstmrk.it/*/$doc,to=click.pstmrk.it|track.pstmrk.it,urlskip=/\\.pstmrk\\.it\\/[23][mst]{0,2}\\/([^\\/?#]+)/ -uricomponent +https
    ||t.cfjump.com/*^Url=http$doc,urlskip=?Url
    /^https?:\\/\\/(?:www\\.anrdoezrs\\.net|cj\\.dotomi\\.com)\\/links(?:-t)?\\/\\d+\\/sid\\/[^\\/]+\\/http/$doc,to=cj.dotomi.com|www.anrdoezrs.net,urlskip=/\\/sid\\/[^\\/]+\\/(http[^?]+)/
    ||anrdoezrs.net/links/*/type/dlg/http$doc,urlskip=/\\/dlg\\/(http[^?]+)/
    ||s.click.aliexpress.com/deep_link.*^dl_target_url=http$doc,urlskip=?dl_target_url
    /r.cfm*^urllink=$document,urlskip=?urllink +https,to=shareasale-analytics.com|shareasale.com
    /^https?:\\/\\/(?:[^.]+\\.){2}(?:com|io|net)\\/c(?:\\/\\d+){3}\\/?\\?.*?&?URL=http/$doc,to=com|io|net,match-case,urlskip=?URL
    """

    /// What blocks the same trackers' pages, from Peter Lowe's hosts,
    /// EasyPrivacy and EasyList.
    static let blocking = """
    127.0.0.1 awstrack.me
    127.0.0.1 klclick.com
    127.0.0.1 mlsend.com
    127.0.0.1 pstmrk.it
    127.0.0.1 anrdoezrs.net
    127.0.0.1 click.aliexpress.com
    127.0.0.1 s.click.aliexpress.com
    ||t.cfjump.com^
    ||linksprf.com^$document
    ||pemsrv.com^$document
    """

    static let skipper: Filters.Skipper = {
        let rules = Filters.convert([blocking, privacy], trusted: [1])
        return Filters.Skipper(rules.skips)
    }()

    private func skip(_ url: String) -> String? { Self.skipper.destination(url) }

    @Test func everyRuleOfTheListsIsTaken() {
        let rules = Filters.convert([Self.blocking, Self.privacy], trusted: [1])
        #expect(rules.skips.count == 8)
        #expect(Self.skipper.count == 8)
        // None of them is a block of its own.
        #expect(!rules.blocks.contains { $0.filter.contains("L0") || $0.filter.contains("deep_link") })
    }

    @Test func amazonSESClickTracking() {
        // SES's link: the destination escaped after /L0/, then the message id.
        #expect(skip("https://yvlf73bg.r.us-west-2.awstrack.me/L0/https:%2F%2Fwww.example.com%2Forders%2F1234%3Futm_source=ses%26utm_medium=email/1/0101019a2b3c4d5e-6f708192-a3b4-4c5d-8e9f-0a1b2c3d4e5f-000000/u8hQXc3Ie9a1M2lDbmTq4O7DQ1M=394")
                == "https://www.example.com/orders/1234?utm_source=ses&utm_medium=email")
        #expect(skip("https://abc123.r.eu-west-1.awstrack.me/L0/http:%2F%2Fexample.org%2F/2/01020191ff-000000/x=1")
                == "http://example.org/")
        // SES's open pixel and an unescaped destination: no destination to read.
        #expect(skip("https://yvlf73bg.r.us-west-2.awstrack.me/I0/0101019a2b3c4d5e/abc=123") == nil)
        #expect(skip("https://yvlf73bg.r.us-west-2.awstrack.me/L0/https://www.example.com/1/abc") == nil)
    }

    @Test func postmarkClickTracking() {
        #expect(skip("https://click.pstmrk.it/3s/www.example.com%2Faccount%2Fsettings%3Ftab=billing/Ab12/Cd34EfGh/Ij56")
                == "https://www.example.com/account/settings?tab=billing")
        #expect(skip("https://track.pstmrk.it/2ts/example.com%2Fwelcome/Zz9/QW1/aa") == "https://example.com/welcome")
        // $to: Postmark's own subscription pages are not a tracker hop.
        #expect(skip("https://subscriptions.pstmrk.it/unsubscribe?m=1.abc.def&s=xyz") == nil)
    }

    @Test func commissionJunctionLinks() {
        #expect(skip("https://www.anrdoezrs.net/links/9123456/type/dlg/https://www.example-shop.com/product/42-blue?size=m")
                == "https://www.example-shop.com/product/42-blue")
        #expect(skip("https://www.anrdoezrs.net/links/9123456/sid/newsletter-1105/https://www.example-shop.com/sale")
                == "https://www.example-shop.com/sale")
        // CJ's classic click id: nothing inside to go to.
        #expect(skip("https://www.anrdoezrs.net/click-9123456-15432100") == nil)
    }

    @Test func aliExpressAndCommissionFactory() {
        #expect(skip("https://s.click.aliexpress.com/deep_link.htm?aff_short_key=_dTlbXyz&dl_target_url=https%3A%2F%2Fwww.aliexpress.com%2Fitem%2F1005001234567890.html%3Fsrc%3Daff")
                == "https://www.aliexpress.com/item/1005001234567890.html?src=aff")
        // A short affiliate link holds no destination: blocked as uBlock Origin blocks it.
        #expect(skip("https://s.click.aliexpress.com/e/_DlXyZ12") == nil)
        #expect(skip("https://t.cfjump.com/37419/t/51823?Url=https%3A%2F%2Fwww.example.com.au%2Fdeals%2Fsummer")
                == "https://www.example.com.au/deals/summer")
    }

    @Test func trackersWithoutARuleStayStopped() {
        for url in ["https://ctrk.klclick.com/ls/click?upn=u001.abcDEF&_kx=abc.XyZ",
                    "https://click.mlsend.com/link/c/YT0xMjM0NTY3ODk=",
                    "https://r.linksprf.com/v1/redirect?url=https%3A%2F%2Fexample.com",
                    "https://a.pemsrv.com/video-slider.php?idzone=123",
                    "https://www.example.com/path"] {
            #expect(skip(url) == nil, "\(url)")
        }
    }

    @Test func optionsSplitAsUBlockOriginSplitsThem() throws {
        // A comma in a value stays in it; one before another option ends it.
        let postmark = try #require(Filters.skipRule(#"||pstmrk.it/*/$doc,to=click.pstmrk.it|track.pstmrk.it,urlskip=/\.pstmrk\.it\/[23][mst]{0,2}\/([^\/?#]+)/ -uricomponent +https"#))
        #expect(postmark.steps == #"/\.pstmrk\.it\/[23][mst]{0,2}\/([^\/?#]+)/ -uricomponent +https"#)
        #expect(postmark.to == ["click.pstmrk.it", "track.pstmrk.it"])
        let share = try #require(Filters.skipRule("/r.cfm*^urllink=$document,urlskip=?urllink +https,to=shareasale-analytics.com|shareasale.com"))
        #expect(share.steps == "?urllink +https")
        #expect(share.to == ["shareasale-analytics.com", "shareasale.com"])
        #expect(skip("https://www.shareasale.com/r.cfm?b=123&u=456&m=789&urllink=www.example.com%2Fshoes") == "https://www.example.com/shoes")
        // A "$" inside the steps' expression is not where options start.
        let anchored = try #require(Filters.skipRule(#"||example.com/out$doc,urlskip=/to=(http.+)$/"#))
        #expect(anchored.steps == "/to=(http.+)$/")
        // match-case: "URL=" only, not "url=".
        #expect(skip("https://go.example.com/c/1/2/3?x=1&URL=https%3A%2F%2Fexample.net%2Fa") == "https://example.net/a")
        #expect(skip("https://go.example.com/c/1/2/3?x=1&url=https%3A%2F%2Fexample.net%2Fa") == nil)
    }

    @Test func onlyRulesItCanKeepExactly() {
        // Other kinds of load, sites named, entities in $to, unknown steps.
        #expect(Filters.skipRule("||example.com/r?$image,urlskip=?u") == nil)
        #expect(Filters.skipRule("||example.com/r?$doc,3p,urlskip=?u") == nil)
        #expect(Filters.skipRule("||www.google.*/url?sa=*&source=*&cd=&ved=*&url=$urlskip=?url,doc,1p") != nil)
        #expect(Filters.skipRule("||example.com/r?$doc,domain=a.com,urlskip=?u") == nil)
        #expect(Filters.skipRule("*$doc,to=example.*,urlskip=?u") == nil)
        #expect(Filters.skipRule("||example.com/r?$doc,urlskip=?u -rot13") == nil)
        #expect(Filters.skipRule("||example.com/r?$doc,urlskip=") == nil)
        // Every address with nothing to narrow it.
        #expect(Filters.skipRule("*$doc,urlskip=?u") == nil)
        #expect(Filters.skipRule("*$doc,to=example.com,urlskip=?u") != nil)
    }

    @Test func onlyFromListsUBlockOriginTrusts() {
        #expect(Filters.convert([Self.privacy]).skips.isEmpty)
        #expect(Filters.convert([Self.privacy], trusted: [0]).skips.count == 8)
        let names = Shield.sources.map(\.name).filter { Shield.trusts($0) }
        #expect(names == ["ublock-filters", "ublock-badware", "ublock-privacy", "ublock-unbreak", "ublock-quick-fixes"])
        #expect(!Shield.trusts("easyprivacy") && !Shield.trusts("peter-lowe") && !Shield.trusts("custom-1234"))
        #expect(Shield.convert([("easyprivacy", Self.privacy)]).skips.isEmpty)
        #expect(Shield.convert([("ublock-privacy", Self.privacy)]).skips.count == 8)
    }

    @Test func badfilterAndExceptionsTakeSkipsBack() {
        let line = "||t.cfjump.com/*^Url=http$doc,urlskip=?Url"
        #expect(Filters.convert([line, line + ",badfilter"], trusted: [0]).skips.isEmpty)
        let skipper = Filters.Skipper(Filters.convert([line + "\n@@||t.cfjump.com/37419/$urlskip=?Url"], trusted: [0]).skips)
        #expect(skipper.destination("https://t.cfjump.com/37419/t/1?Url=https%3A%2F%2Fexample.com") == nil)
        #expect(skipper.destination("https://t.cfjump.com/50000/t/1?Url=https%3A%2F%2Fexample.com") == "https://example.com")
    }

    @Test func stepsAsUBlockOriginRunsThem() throws {
        func run(_ url: String, _ steps: String) throws -> String? {
            Filters.Skipper.run(url, try #require(Filters.Skipper.steps(steps)))
        }
        #expect(try run("https://t.example/r?url=https%3A%2F%2Fexample.org%2Fpath%2Fto%2Ftracker%3Fto%3Dhttps%253A%252F%252Fgithub.com%252F", "?url ?to") == "https://github.com/")
        // A step that can't be fulfilled: no skip.
        #expect(try run("https://t.example/r?url=https%3A%2F%2Fexample.org%2Fpath", "?url ?to") == nil)
        #expect(try run("https://shrinkearn.com/full?api=3dd1&url=aHR0cHM6Ly9rcmFrZW5maWxlcy5jb20vdmlldy9zamJ1RmpQVTF2L2ZpbGUuaHRtbA==&type=2", "?url -base64")
                == "https://krakenfiles.com/view/sjbuFjPU1v/file.html")
        #expect(try run("https://t.example/r?u=aHR0cHM6Ly9leGFtcGxlLmNvbS8_YT0-Yg", "?u -safebase64") == "https://example.com/?a=>b")
        #expect(try run("https://www.pixiv.net/jump.php?https%3A%2F%2Fx.com%2FExample_Username", "&1") == "https://x.com/Example_Username")
        #expect(try run("https://t.example/r#https://example.com/x", "#") == "https://example.com/x")
        #expect(try run("https://t.example/r?aff_sub3=hepsiburada.com/p-HBCV&x=1", "?aff_sub3 +https") == "https://hepsiburada.com/p-HBCV")
        #expect(try run("https://t.example/r?u=http://example.com/a", "?u +https") == "https://example.com/a")
        #expect(try run("https://t.example/r?u=a%20b", "?u") == nil)
        // A space in a parameter's value comes out as %20.
        #expect(try run("https://t.example/r?u=https://example.com/a+b", "?u") == "https://example.com/a%20b")
        // -blocked changes nothing here: Yab skips a stopped page too.
        #expect(try run("https://t.example/r?u=https://example.com/", "-blocked ?u") == "https://example.com/")
        // Only http and https, and a bad escape ends it.
        #expect(try run("https://t.example/r?u=javascript:alert(1)", "?u") == nil)
        #expect(try run("https://t.example/r?u=file:///etc/hosts", "?u") == nil)
        #expect(try run("https://t.example/L0/https:%E0%A4%A/x", #"/\/L0\/(http[^\/?#]+)/ -uricomponent"#) == nil)
        #expect(Filters.Skipper.steps("?u -rot13") == nil)
        #expect(Filters.Skipper.steps("&0") == nil)
    }

    @Test func badfilterOfAHostIsThatHostOnly() {
        // uBlock Origin takes back the line it repeats, compiled, and no
        // other: click.aliexpress.com's $badfilter leaves Peter Lowe's
        // s.click.aliexpress.com blocking, as it does there.
        let rules = Filters.convert([Self.blocking, "||click.aliexpress.com^$badfilter"])
        #expect(!rules.blocks.contains { $0.filter == Filters.onSite("click.aliexpress.com") })
        #expect(rules.blocks.contains { $0.filter == Filters.onSite("s.click.aliexpress.com") })
    }

    @MainActor @Test func onlyWhereShieldBlocks() throws {
        try #require(Store.testing)
        let shield = Shield.shared
        let enabled = shield.enabled, skipper = shield.skipper
        let host = "yvlf73bg.r.us-west-2.awstrack.me", paused = shield.isPaused(on: host)
        defer { shield.enabled = enabled; shield.skipper = skipper; shield.pause(host, paused) }
        let url = try #require(URL(string: "https://\(host)/L0/https:%2F%2Fexample.com%2Fa/1/x=1"))
        shield.skipper = Self.skipper
        shield.enabled = true
        shield.pause(host, false)
        #expect(shield.redirect(url, persistent: nil, cleaning: true)?.absoluteString == "https://example.com/a")
        #expect(shield.redirect(url, persistent: true, cleaning: true)?.absoluteString == "https://example.com/a")
        shield.pause(host, true)
        #expect(shield.redirect(url, persistent: nil, cleaning: true) == nil)
        shield.pause(host, false)
        shield.enabled = false
        #expect(shield.redirect(url, persistent: nil, cleaning: true) == nil)
    }

    /// Opening a link drops what a copy drops (Diary.withoutSharing) and nothing else.
    @MainActor @Test func openingDropsTheNamesACopyDrops() throws {
        try #require(Store.testing)
        let shield = Shield.shared
        let enabled = shield.enabled, skipper = shield.skipper
        let host = "httpbin.org", paused = shield.isPaused(on: host)
        defer { shield.enabled = enabled; shield.skipper = skipper; shield.pause(host, paused) }
        shield.skipper = nil
        shield.enabled = true
        shield.pause(host, false)
        func open(_ address: String, cleaning: Bool = true) -> String? {
            shield.redirect(URL(string: address)!, persistent: nil, cleaning: cleaning)?.absoluteString
        }
        #expect(open("https://httpbin.org/get?id=7&utm_source=x&fbclid=y") == "https://httpbin.org/get?id=7")
        #expect(open("https://example.com/a?UTM_Medium=m&gclid=1&msclkid=2") == "https://example.com/a")
        // Affiliate and page parameters stay.
        #expect(open("https://www.amazon.com/dp/B0CX23V2ZK?tag=shop-20&ascsubtag=a1&utm_source=x&th=1")
                == "https://www.amazon.com/dp/B0CX23V2ZK?tag=shop-20&ascsubtag=a1&th=1")
        #expect(open("https://shop.example.com/p?aff_id=9&affiliate=x&ref=main&source=hp&feature=t&gbraid=0A") == nil)
        // Fragment and encoding as written.
        #expect(open("https://example.com/a%2Fb?q=%E2%9C%93&utm%5Fsource=x&v=a%2Bb#Part%202") == "https://example.com/a%2Fb?q=%E2%9C%93&v=a%2Bb#Part%202")
        // Nothing to strip, back or forward, a paused site, Shield off: as it is.
        #expect(open("https://example.com/a?id=7#utm_source=x") == nil)
        #expect(open("https://httpbin.org/get?utm_source=x", cleaning: false) == nil)
        shield.pause(host, true)
        #expect(open("https://httpbin.org/get?utm_source=x") == nil)
        shield.pause(host, false)
        shield.enabled = false
        #expect(open("https://httpbin.org/get?utm_source=x") == nil)
    }
}

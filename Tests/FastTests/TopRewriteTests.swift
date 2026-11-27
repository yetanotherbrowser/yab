import Foundation
import Testing
@testable import Fast

// What both engines decide of a top document before it loads: whether the
// tracking names a copy drops may go, and how many rewrites in a row.
@MainActor @Suite struct TopRewriteTests {
    typealias Navigation = TopRewrite.Navigation

    static func url(_ text: String) -> URL { URL(string: text)! }

    /// Shield.redirect without the lists: only the names a copy drops.
    static func clean(_ url: URL, _ cleaning: Bool) -> URL? { cleaning ? Diary.withoutSharing(url) : nil }

    static let tracked = url("https://shop.example/p?id=1&utm_source=x")

    @Test func backForwardReloadAndResubmitNeverClean() {
        for kind in [PageAction.Kind.backForward, .reload, .formResubmitted] {
            #expect(!TopRewrite.cleans(Navigation(url: Self.tracked, kind: kind, byYab: true)))
            #expect(!TopRewrite.cleans(Navigation(url: Self.tracked, kind: kind, inPlace: true)))
        }
    }

    @Test func webKitCleansLinksFormsRedirectsAndYabsOwnLoadsOnly() {
        let page = Self.url("https://shop.example/list")
        #expect(TopRewrite.cleans(Navigation(url: Self.tracked, kind: .linkActivated, source: page)))
        #expect(TopRewrite.cleans(Navigation(url: Self.tracked, kind: .formSubmitted, source: page)))
        #expect(TopRewrite.cleans(Navigation(url: Self.tracked, redirect: true, source: page)))
        #expect(TopRewrite.cleans(Navigation(url: Self.tracked, byYab: true)))
        // location.replace or a meta refresh: a load anew would add an entry.
        #expect(!TopRewrite.cleans(Navigation(url: Self.tracked, source: page)))
        // Chromium rewrites the held request, so the entry stays as the page made it.
        #expect(TopRewrite.cleans(Navigation(url: Self.tracked, inPlace: true)))
    }

    @Test func aWindowOpenWindowAndTheSameDocumentStay() {
        #expect(!TopRewrite.cleans(Navigation(url: Self.tracked, kind: .linkActivated, keepsOpener: true)))
        let shown = Self.url("https://shop.example/p?id=1&utm_source=x")
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://shop.example/p?id=1&utm_source=x#reviews"),
                                              kind: .linkActivated, shown: shown, source: shown)))
        #expect(TopRewrite.cleans(Navigation(url: Self.url("https://shop.example/q?utm_source=x#reviews"),
                                             kind: .linkActivated, shown: shown, source: shown)))
    }

    @Test func aCrossSiteLinkKeepsItsAddressInWebKit() {
        let other = Self.url("https://news.example/story")
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/act?x=1&utm_source=a"), kind: .linkActivated, source: other)))
        // Every parameter a tracking name: still another site's request, so it may reach an action.
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/account/delete?utm_source=a"), kind: .linkActivated, source: other)))
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/?utm_source=a"), kind: .formSubmitted, source: other)))
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/?utm_source=a"), redirect: true, source: other)))
        // The source frame still naming the page before, on bank.example: the page shown decides.
        #expect(!TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/account/delete?utm_source=a"), kind: .linkActivated,
                                              shown: other, source: Self.url("https://bank.example"))))
        #expect(TopRewrite.cleans(Navigation(url: Self.url("https://www.bank.example/act?x=1&utm_source=a"), kind: .linkActivated,
                                             source: Self.url("https://bank.example"))))
        // In place, the request stays the page's (Sec-Fetch-Site as sent).
        #expect(TopRewrite.cleans(Navigation(url: Self.url("https://bank.example/act?x=1&utm_source=a"), kind: .linkActivated,
                                             inPlace: true, source: other)))
    }

    /// A site that 302s /p to /p?utm_source=x until it has it: after `cap`
    /// rewrites the address loads as it is, where every hop reset the count.
    @Test func aRedirectBackForTheTrackingNameStopsAtTheCap() {
        var rewrites = TopRewrite()
        let bare = Self.url("https://site.example/p"), back = Self.url("https://site.example/p?utm_source=x")
        #expect(rewrites.next(Navigation(url: bare, byYab: true), Self.clean).instead == nil)
        var cleaned = 0
        for _ in 0..<20 {
            guard let instead = rewrites.next(Navigation(url: back, redirect: true), Self.clean).instead else { break }
            #expect(instead == bare)
            cleaned += 1
            #expect(rewrites.next(Navigation(url: instead, byYab: true), Self.clean).instead == nil)
        }
        #expect(cleaned == TopRewrite.cap)
        // A new navigation starts again.
        #expect(rewrites.next(Navigation(url: back, kind: .linkActivated), Self.clean).instead == bare)
    }

    @Test func aTrackersDestinationIsCleanedOnTheNextPass() {
        var rewrites = TopRewrite()
        let tracker = Self.url("https://click.example/r?u=1"), destination = Self.url("https://shop.example/a?id=1&utm_source=mail")
        let redirect: (URL, Bool) -> URL? = { url, cleaning in url.host() == "click.example" ? destination : Self.clean(url, cleaning) }
        let first = rewrites.next(Navigation(url: tracker, kind: .linkActivated, byPerson: true), redirect)
        #expect(first == TopRewrite.Step(instead: destination, byPerson: true))
        let second = rewrites.next(Navigation(url: destination, byYab: true), redirect)
        #expect(second == TopRewrite.Step(instead: Self.url("https://shop.example/a?id=1"), byPerson: true))
        let third = rewrites.next(Navigation(url: Self.url("https://shop.example/a?id=1"), byYab: true), redirect)
        #expect(third == TopRewrite.Step(instead: nil, byPerson: true))
        #expect(rewrites.count == 2)
    }

    /// The load of a person's cleaned link is still a person's, for the
    /// engine routing; a redirect hop's is not.
    @Test func aCleanedLinkStaysAPersonsOnce() {
        var rewrites = TopRewrite()
        let clean = Self.url("https://shop.example/p?id=1")
        #expect(rewrites.next(Navigation(url: Self.tracked, kind: .linkActivated, byPerson: true), Self.clean).instead == clean)
        #expect(rewrites.next(Navigation(url: clean, byYab: true), Self.clean).byPerson)
        #expect(!rewrites.next(Navigation(url: clean, byYab: true), Self.clean).byPerson)
        #expect(rewrites.next(Navigation(url: Self.tracked, redirect: true), Self.clean).instead == clean)
        #expect(!rewrites.next(Navigation(url: clean, byYab: true), Self.clean).byPerson)
    }

    /// A typed address asked for by a blank tab's frame (an opaque origin),
    /// and its server's redirect: Yab's own, cleaned.
    @Test func yabsOwnLoadAndItsRedirectsAreCleanedWhateverFrameAsks() {
        var rewrites = TopRewrite()
        let blank = Self.url("about:blank")
        let typed = Self.url("https://site.example/r?to=1&utm_source=x"), hop = Self.url("https://other.example/get?id=2&utm_medium=m")
        #expect(rewrites.next(Navigation(url: typed, byYab: true, source: blank), Self.clean).instead == Self.url("https://site.example/r?to=1"))
        #expect(rewrites.next(Navigation(url: Self.url("https://site.example/r?to=1"), source: blank), Self.clean).instead == nil)
        #expect(rewrites.next(Navigation(url: hop, redirect: true, source: blank), Self.clean).instead == Self.url("https://other.example/get?id=2"))
        // The same hop after a page's cross-site link keeps the page's request.
        var linked = TopRewrite()
        let page = Self.url("https://news.example/story")
        #expect(linked.next(Navigation(url: Self.url("https://site.example/r?to=1"), kind: .linkActivated, source: page), Self.clean).instead == nil)
        #expect(linked.next(Navigation(url: hop, redirect: true, source: page), Self.clean).instead == nil)
    }

    @Test func theAddressYabSentAsTheEngineAsksForIt() {
        #expect(TopRewrite.sameAddress(Self.url("https://a.example/?q=1"), Self.url("https://A.example?q=1")))
        #expect(TopRewrite.sameAddress(Self.url("https://a.example/p?q=1"), Self.url("https://a.example/p?q=1")))
        #expect(!TopRewrite.sameAddress(Self.url("https://a.example/p?q=1"), Self.url("https://a.example/p?q=2")))
        #expect(!TopRewrite.sameAddress(Self.url("https://a.example/"), nil))
    }

    @Test func onlyGetIsRewritten() {
        var rewrites = TopRewrite()
        #expect(rewrites.next(Navigation(url: Self.tracked, method: "POST", kind: .formSubmitted), Self.clean).instead == nil)
    }

    /// Escapes URLComponents' setters trap on, raw characters, "==" in a value.
    @Test func badlyWrittenAddressesDoNotTrap() throws {
        let inputs = [
            "https://example.com/a?q=%zz&utm_source=x",
            "https://example.com/a?%zz=1&utm_source=x&v=a==b",
            "https://example.com/a?q=[x]&r=^|&utm_source=x",
            "https://example.com/a?utm_source=x&",
            "https://example.com/a?&&utm_source=x&&#f?utm_medium=y",
        ]
        for input in inputs {
            let url = try #require(URL(string: input, encodingInvalidCharacters: false) ?? URL(string: input))
            let cleaned = try #require(Diary.withoutSharing(url))
            #expect(!cleaned.absoluteString.contains("utm_source"), "\(input)")
        }
        #expect(Diary.withoutSharing(Self.url("https://example.com/a?v=a==b&utm_source=x"))?.absoluteString == "https://example.com/a?v=a==b")
        #expect(Diary.withoutSharing(Self.url("https://example.com/a?utm_source=x&"))?.absoluteString == "https://example.com/a")
        #expect(Diary.withoutSharing(Self.url("https://example.com/a?&&utm_source=x&&#f?utm_medium=y"))?.absoluteString
                == "https://example.com/a#f?utm_medium=y")
        #expect(Diary.withoutSharing(Self.url("https://example.com/a#f?utm_medium=y")) == nil)
        #expect(Diary.withoutSharing(Self.url("https://example.com/a?b=1&")) == nil)
    }
}

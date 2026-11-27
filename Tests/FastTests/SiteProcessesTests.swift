import Foundation
import Testing
import WebKit
@testable import Fast

// Same-site pages sharing a process past Chrome's renderer count
// (SiteProcesses).
@MainActor
@Suite(.serialized)
struct SiteProcessesTests {
    @Test func theLimitIsChromesForTheMacsMemory() {
        #expect(SiteProcesses.limit(memory: 8 << 30) == 48)
        #expect(SiteProcesses.limit(memory: 16 << 30) == 82)
        #expect(SiteProcesses.limit(memory: 64 << 30) == 82)
        #expect(SiteProcesses.limit(memory: 256 << 20) == 3)
    }

    @Test func aSiteIsSchemeAndRegistrableDomain() {
        #expect(SiteProcesses.site(of: URL(string: "https://mail.google.com/x")) == "https://google.com")
        #expect(SiteProcesses.site(of: URL(string: "https://docs.google.com/y")) == "https://google.com")
        #expect(SiteProcesses.site(of: URL(string: "http://google.com/")) == "http://google.com")
        #expect(SiteProcesses.site(of: URL(string: "https://a.github.io/")) != SiteProcesses.site(of: URL(string: "https://b.github.io/")))
        #expect(SiteProcesses.site(of: URL(string: "https://www.bbc.co.uk/news")) == "https://bbc.co.uk")
        #expect(SiteProcesses.site(of: URL(string: "about:blank")) == nil)
        #expect(SiteProcesses.site(of: URL(string: "yab://settings")) == nil)
        #expect(SiteProcesses.site(of: nil) == nil)
    }

    @Test func belowTheLimitEveryPageHasItsOwn() {
        // A test run has a handful of page processes, far below any limit.
        #expect(SiteProcesses.sibling(for: URL(string: "https://example.com/"), store: .default()) == nil)
        #expect(SiteProcesses.sibling(for: URL(string: "about:blank"), store: .default()) == nil)
    }

    /// Crash #33: a window a page opened, on a Mac past the process count
    /// with another tab on the window's site. The new tab's page was put
    /// in that tab's process instead of its opener's, and WebKit raised
    /// "Returned WKWebView was not created with the given configuration".
    /// It has to stay its opener's, and window.open has to answer.
    @Test func aWindowAPageOpensStaysWithItsOpenerPastTheLimit() async throws {
        let before = SiteProcesses.limit
        SiteProcesses.limit = 1
        defer { SiteProcesses.limit = before }
        let browser = Browser(windowID: UUID())
        defer { for tab in browser.tabs { tab.close() } }
        let page = "<!doctype html><title>t</title><p>site</p>"
        // Native related-view/opener fixture; ordinary tabs keep the selected engine.
        let opener = Tab(bench: true, factory: .webKitOnly)
        browser.prepare(opener)
        browser.lay(browser.tabs + [opener])
        opener.go(to: URL(string: "about:blank")!)
        // Native related-view/opener fixture; ordinary tabs keep the selected engine.
        let other = Tab(bench: true, factory: .webKitOnly)
        browser.prepare(other)
        browser.lay(browser.tabs + [other])
        other.go(to: URL(string: "about:blank")!)
        requireNativeWebKitFixture(opener, "SiteProcessesTests").loadHTMLString(page, baseURL: URL(string: "https://example.test/opener"))
        requireNativeWebKitFixture(other, "SiteProcessesTests").loadHTMLString(page, baseURL: URL(string: "https://example.test/other"))
        // A second page in the opener's process, so the other tab's, with
        // one, is the sibling SiteProcesses would pick.
        let configuration = requireNativeWebKitFixture(opener, "SiteProcessesTests").configuration
        SiteProcesses.relate(configuration, to: requireNativeWebKitFixture(opener, "SiteProcessesTests"))
        let second = WKWebView(frame: .zero, configuration: configuration)
        second.loadHTMLString(page, baseURL: URL(string: "https://example.test/second"))
        try await until("three pages on the site") { requireNativeWebKitFixture(opener, "SiteProcessesTests").url?.host == "example.test" && requireNativeWebKitFixture(other, "SiteProcessesTests").url?.host == "example.test"
            && second.url?.host == "example.test" }
        // WebKit lists a page's process a moment after it loads.
        try await until("the other tab as the sibling") { SiteProcesses.sibling(for: URL(string: "https://example.test/popup"),
                                                store: requireNativeWebKitFixture(opener, "SiteProcessesTests").configuration.websiteDataStore) === requireNativeWebKitFixture(other, "SiteProcessesTests") }
        let count = browser.tabs.count
        let opened = try await requireNativeWebKitFixture(opener, "SiteProcessesTests").evaluateJavaScript(
            "window.w = window.open('https://example.test/popup', '_blank'); !!window.w") as? Bool
        #expect(opened == true)
        #expect(browser.tabs.count == count + 1)
        let popup = try #require(browser.tabs.last)
        #expect(SiteProcesses.related(of: requireNativeWebKitFixture(popup, "SiteProcessesTests").configuration) === requireNativeWebKitFixture(opener, "SiteProcessesTests"))
        second.stopLoading()
    }

    /// A site with media never shares: WebKit keeps one media session
    /// manager for a whole page process and goes over every page's media
    /// each time one of them changes, so tabs of a video site in one
    /// process held its main thread nearly all the time while one scrolled.
    @Test func aSiteWithMediaKeepsItsPagesApartPastTheLimit() async throws {
        let before = SiteProcesses.limit
        SiteProcesses.limit = 1
        defer { SiteProcesses.limit = before }
        let browser = Browser(windowID: UUID())
        defer { for tab in browser.tabs { tab.close() } }
        // Native WebKit fixture: the media state asked for is WebKit's.
        let tab = Tab(bench: true, factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay(browser.tabs + [tab])
        tab.go(to: URL(string: "about:blank")!)
        let web = requireNativeWebKitFixture(tab, "SiteProcessesTests")
        let store = web.configuration.websiteDataStore
        web.loadHTMLString("<!doctype html><title>t</title><p>words</p>", baseURL: URL(string: "https://videos.test/a"))
        try await until("the page without media") { web.url?.host == "videos.test" }
        // Until one of its pages has media, the site shares past the limit.
        try await until("its page as the sibling") { SiteProcesses.sibling(for: URL(string: "https://videos.test/c"), store: store) === web }
        // WebKit counts media once an element has something to load.
        web.loadHTMLString("<!doctype html><title>t</title><audio preload=auto src='\(silence)'></audio>",
                           baseURL: URL(string: "https://videos.test/b"))
        // The tab's own page load asks once it finishes; asked again here
        // until the audio is in.
        try await until("the site known to have media") {
            SiteProcesses.learn(from: web)
            return SiteProcesses.mediaSites.contains("https://videos.test")
        }
        #expect(SiteProcesses.sibling(for: URL(string: "https://videos.test/c"), store: store) == nil)
    }

    /// Media heard for a page counts for the site it was on when asked,
    /// not for the site the view went to before WebKit answered.
    @Test func mediaCountsForTheSiteThePageWasOnWhenAsked() {
        let web = Asked(frame: .zero, configuration: WKWebViewConfiguration())
        web.shown = URL(string: "https://left.test/a")
        SiteProcesses.ask(web)
        web.shown = URL(string: "https://arrived.test/a")
        web.reply?(.paused)
        #expect(SiteProcesses.mediaSites.contains("https://left.test"))
        #expect(!SiteProcesses.mediaSites.contains("https://arrived.test"))
    }

    /// A view whose address the test moves and whose media state it sends.
    private final class Asked: WKWebView {
        var shown: URL?
        var reply: (@MainActor (WKMediaPlaybackState) -> Void)?
        override var url: URL? { shown }
        override func requestMediaPlaybackState(completionHandler: @escaping @MainActor (WKMediaPlaybackState) -> Void) {
            reply = completionHandler
        }
    }

    /// A tenth of a second of silence, a WAV file as a data address.
    private var silence: String {
        func le(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        let samples = 800
        var wav = Data("RIFF".utf8) + le(36 + samples, 4) + Data("WAVEfmt ".utf8)
        wav += le(16, 4) + le(1, 2) + le(1, 2) + le(8000, 4) + le(8000, 4) + le(1, 2) + le(8, 2)
        wav += Data("data".utf8) + le(samples, 4) + Data(repeating: 128, count: samples)
        return "data:audio/wav;base64," + wav.base64EncodedString()
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(Bool(false), "timed out waiting for \(what)")
    }
}

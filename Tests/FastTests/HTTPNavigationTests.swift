import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct HTTPNavigationTests {
    @Test func onlyAnAutomaticSchemeMayFallBackOnce() {
        let url = URL(string: "https://internal.example/first?x=1#part")!
        var automatic = HTTPNavigation(input: "internal.example/first?x=1#part", destination: url)
        #expect(automatic.claim(url, code: NSURLErrorCannotConnectToHost)?.absoluteString
                == "http://internal.example/first?x=1#part")
        #expect(automatic.claim(url, code: NSURLErrorServerCertificateUntrusted) == nil)
        for input in [Optional("https://internal.example/first?x=1#part"), nil] {
            var explicit = HTTPNavigation(input: input, destination: url)
            #expect(explicit.claim(url, code: NSURLErrorServerCertificateHasBadDate) == nil)
        }
    }

    @Test func certificateRefusalsNeverDowngradeToHttp() {
        let url = URL(string: "https://account.example/verify?token=private")!
        for code in [NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired] {
            var navigation = HTTPNavigation(input: "account.example/verify?token=private", destination: url)
            #expect(navigation.claim(url, code: code) == nil)
        }
    }

    @Test func fallbackNeverReplaysURLCredentialsOverHttp() {
        for address in ["https://user:secret@internal.example/", "https://user@internal.example/"] {
            let url = URL(string: address)!
            var navigation = HTTPNavigation(input: "internal.example/", destination: url)
            #expect(navigation.claim(url, code: NSURLErrorServerCertificateHasBadDate) == nil)
        }
    }

    @Test func fallbackMatchesTheOriginalRequestAndStopsAtCommit() {
        let url = URL(string: "https://internal.example:8443/a?x=1")!
        var navigation = HTTPNavigation(input: "internal.example:8443/a?x=1", destination: url)
        #expect(navigation.claim(URL(string: "https://elsewhere.example:8443/a?x=1")!, code: NSURLErrorSecureConnectionFailed) == nil)
        #expect(navigation.claim(URL(string: "https://internal.example:8443/b?x=1")!, code: NSURLErrorSecureConnectionFailed) == nil)
        #expect(navigation.claim(url, code: NSURLErrorCancelled) == nil)
        #expect(navigation.claim(url, code: NSURLErrorNotConnectedToInternet) == nil)
        #expect(navigation.claim(url, code: NSURLErrorCannotConnectToHost)?.absoluteString == "http://internal.example:8443/a?x=1")
        navigation = HTTPNavigation(input: "internal.example:8443/a?x=1", destination: url)
        navigation.clearFallback()
        #expect(navigation.claim(url, code: NSURLErrorServerCertificateUntrusted) == nil)
    }

    @Test func rememberedRootsKeepTheVisitedSchemeAndPort() throws {
        let history = History([])
        let page = URL(string: "http://internal.example:3000/first")!
        history.record(page, title: "First")
        let root = try #require(history.suggestions(for: "internal.example", limit: 5).first { $0.key == "internal.example:3000" })
        #expect(root.url?.absoluteString == "http://internal.example:3000/")
    }

    @Test func localAndExplicitHttpAddressesStayHttp() {
        for input in ["localhost:3000", "router.local", "nas:5000", "10.0.0.1", "[::1]:3000", "http://internal.example"] {
            let url = Address.url(from: input)!
            #expect(url.scheme == "http")
            var navigation = HTTPNavigation(input: input, destination: url)
            #expect(navigation.keepsHTTP)
            #expect(navigation.claim(url, code: NSURLErrorServerCertificateUntrusted) == nil)
        }
    }

    @Test(arguments: ["http://internal.example", "http://localhost:3000"])
    func explicitHttpBeatsHttpsHistoryAndOpenTabs(input: String) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        let https = URL(string: input.replacingOccurrences(of: "http://", with: "https://"))!
        browser.history = History([Visit(url: https.absoluteString, key: Address.pretty(https).lowercased(),
                                         title: "Internal", count: 10, last: Date(), typed: 10)])
        let tab = Tab(later: .nonPersistent())
        tab.restore(url: https, title: "Internal")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        browser.openFresh()
        browser.replaceTyped(input, completing: true)
        let lead = try #require(browser.query.lead)
        #expect(browser.offers[lead].url?.scheme == "http")
        #expect(browser.offers[lead].kind == .address)
        #expect(browser.ending == nil)
    }
}

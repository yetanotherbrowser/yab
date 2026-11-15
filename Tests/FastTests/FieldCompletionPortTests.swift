import AppKit
import Foundation
import Testing
@testable import Fast

/// History keys leave the port off (Address.pretty). Return on the gray
/// ending must open the address that was kept, port and all (#761).
@MainActor
@Suite(.serialized)
struct FieldCompletionPortTests {
    private static let kept = [("http://nas:5000/", "na", "s"),
                               ("http://localhost:3000/", "local", "host"),
                               ("https://example.com/", "examp", "le.com")]

    @Test func theFinishedRowKeepsItsPort() throws {
        for (kept, typed, ending) in Self.kept {
            let url = try #require(URL(string: kept))
            let row = Suggestion(key: Address.pretty(url), title: "Fixture", url: url, kind: .visited)
            let target = try #require(Browser.completionTarget(typed + ending, among: [row]), "\(kept)")
            #expect(target.scheme == url.scheme, "\(kept)")
            #expect(target.host() == url.host(), "\(kept)")
            #expect(target.port == url.port, "\(kept)")
        }
        // No row behind the words: they are read as typed, as before.
        #expect(Browser.completionTarget("localhost", among: []) == Address.url(from: "localhost"))
        #expect(Browser.completionTarget("example.com", among: [])?.host() == "example.com")
    }

    @Test func returnOnTheEndingOpensTheVisitedPort() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest, requests = browser.prefs.fieldRequests
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        defer {
            browser.dismiss()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        for (kept, typed, ending) in Self.kept {
            let url = try #require(URL(string: kept))
            browser.history = History([Visit(url: url.absoluteString, key: Address.pretty(url),
                                             title: "Fixture", count: 100, last: Date(), typed: 100)])
            browser.openFresh()
            browser.replaceTyped(typed)
            try #require(browser.ending == ending, "\(typed) should finish \(kept)")
            let refusals = browser.refusals
            browser.submit()
            #expect(browser.refusals == refusals, "\(typed)")
            let address = browser.active?.address
            #expect(address?.scheme == url.scheme, "\(typed)")
            #expect(address?.host() == url.host(), "\(typed)")
            #expect(address?.port == url.port, "\(typed)")
        }
    }
}

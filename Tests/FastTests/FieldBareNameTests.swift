import AppKit
import Foundation
import Testing
@testable import Fast

/// #761: a machine known by one word (http://nas/) is in history under that
/// word. The field finished it, and Return then read "nas" back as an
/// address, found none, and shook, though a click on the same row opened it.
@MainActor
@Suite(.serialized)
struct FieldBareNameTests {
    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let suggest = browser.prefs.searchSuggest
        let requests = browser.prefs.fieldRequests
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
        try body(browser)
    }

    /// A bare name, with and without a port, and a server whose name is an
    /// address by itself but whose scheme the words leave out.
    @Test(arguments: [("http://yabnas/", "yabn", "yabnas"), ("http://yabnas:5000/", "yabn", "yabnas:5000"),
                      ("http://yabdev761.test:3000/", "yabd", "yabdev761.test:3000"), ("https://yabdev761.test:8443/", "yabd", "yabdev761.test:8443")])
    func returnGoesWhereTheRowTheFieldFinishedGoes(address: String, typed: String, whole: String) throws {
        try withBrowser { browser in
            let place = try #require(URL(string: address))
            browser.history = History([Visit(url: address, key: History.key(for: place), title: "Home server", count: 9, last: Date(), typed: 9)])
            browser.openFresh()
            browser.replaceTyped(typed)
            #expect(browser.completed == whole)
            let lead = try #require(browser.query.lead)
            #expect(browser.offers[lead].url == place)
            let refused = browser.refusals
            browser.submit()
            #expect(browser.refusals == refused)
            let went = browser.active?.address
            #expect(went?.scheme == place.scheme)
            #expect(went?.host() == place.host())
            #expect(went?.port == place.port)
        }
    }

    @Test func finishedWordsKeepTheirMeaningWithoutAPlace() {
        #expect(Address.finished("example.com", place: nil) == URL(string: "https://example.com"))
        #expect(Address.finished("yabnas", place: nil) == nil)
        // A place on the web's own port adds nothing, and its query is not brought along.
        #expect(Address.finished("example.com/docs", place: URL(string: "https://example.com/docs?page=2")) == URL(string: "https://example.com/docs"))
        // Another machine's port, or another port typed, is not this one's.
        #expect(Address.finished("example.com", place: URL(string: "http://other.test:8080/")) == URL(string: "https://example.com"))
        #expect(Address.finished("example.com:3000", place: URL(string: "http://example.com:4000/")) == URL(string: "https://example.com:3000"))
        #expect(Address.finished("example.com/docs", place: URL(string: "http://www.example.com:8080/docs")) == URL(string: "http://www.example.com:8080/docs"))
    }
}

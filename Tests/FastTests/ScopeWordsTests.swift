import Foundation
import Testing
@testable import Fast

/// The words a site's results page was asked, read back from its address
/// for the field's recent searches of that site (Scopes.landed).
struct ScopeWordsTests {
    private let youtube = Scope(id: "youtube.com", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s")
    private let wikipedia = Scope(id: "en.wikipedia.org", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/%s")

    /// What the field sent comes back as it was typed, a plus included.
    @Test(arguments: ["c++ tutorial", "c++", "a+b=c", "rock & roll", "50% off", "swift ui"])
    func wordsTheFieldSentComeBackAsTyped(words: String) throws {
        let asked = try #require(youtube.url(for: words))
        #expect(youtube.words(in: asked) == words)
    }

    /// A plus written in the address is a space, as a site's own form sends one.
    @Test func aPlusInTheAddressIsASpace() throws {
        let page = try #require(URL(string: "https://www.youtube.com/results?search_query=swift+ui&sp=1"))
        #expect(youtube.words(in: page) == "swift ui")
    }

    @Test func wordsInAPathKeepTheirPlusToo() throws {
        let page = try #require(URL(string: "https://en.wikipedia.org/wiki/C%2B%2B"))
        #expect(wikipedia.words(in: page) == "C++")
        let spaced = try #require(URL(string: "https://en.wikipedia.org/wiki/Swift%20UI"))
        #expect(wikipedia.words(in: spaced) == "Swift UI")
    }

    @Test func anotherSitesPageHasNoWords() throws {
        let page = try #require(URL(string: "https://example.com/results?search_query=c%2B%2B"))
        #expect(youtube.words(in: page) == nil)
    }
}

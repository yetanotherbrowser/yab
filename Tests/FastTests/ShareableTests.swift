import Foundation
import Testing
@testable import Fast

// What ⇧⌘C puts on the clipboard: the page, without who shared it.
struct ShareableTests {
    static func copy(_ address: String) -> String { Diary.shareable(URL(string: address)!).absoluteString }

    @Test func trackersGo() {
        #expect(Self.copy("https://example.com/a?utm_source=x&utm_medium=y") == "https://example.com/a")
        #expect(Self.copy("https://example.com/a?id=4&fbclid=abc#top") == "https://example.com/a?id=4#top")
        #expect(Self.copy("https://youtu.be/dQw4w9WgXcQ?si=Ab12") == "https://youtu.be/dQw4w9WgXcQ")
        #expect(Self.copy("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42&si=Ab12") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42")
        #expect(Self.copy("https://x.com/a/status/1?ref_src=twsrc%5Etfw") == "https://x.com/a/status/1")
    }

    @Test func thePageStays() {
        #expect(Self.copy("https://github.com/o/r/blob/main/f.swift?ref=dev") == "https://github.com/o/r/blob/main/f.swift?ref=dev")
        #expect(Self.copy("https://example.com/search?q=a%20b&source=hp") == "https://example.com/search?q=a%20b&source=hp")
        #expect(Self.copy("https://example.com/a?q=%E2%9C%93&gclid=1") == "https://example.com/a?q=%E2%9C%93")
        #expect(Self.copy("https://www.amazon.com/dp/B0CX23V2ZK?tag=shop-20&utm_source=x") == "https://www.amazon.com/dp/B0CX23V2ZK?tag=shop-20")
        #expect(Self.copy("https://example.com/") == "https://example.com/")
        #expect(Self.copy("https://example.com/?") == "https://example.com/?")
    }
}

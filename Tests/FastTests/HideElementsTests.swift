import AppKit
import Testing
@testable import Fast

/// Hide Elements (⇧⌘H) points at one page, and the window has one bar for
/// it. Leaving that tab left the bar up over a page nothing pointed at;
/// Esc there turned the pointing off on the wrong page, and the page left
/// went on hiding whatever was clicked, with no bar and no Esc to stop it.
@MainActor @Suite(.serialized)
struct HideElementsTests {
    /// The crosshair the pointing puts on the page while it is live.
    private func cursor(_ tab: Tab) async throws -> String {
        let web = try #require(tab.built)
        return try await web.evaluateJavaScript("document.documentElement.style.cursor") as? String ?? ""
    }

    private func wait(for tab: Tab, cursor wanted: String) async throws -> Bool {
        for _ in 0..<150 {
            if try await cursor(tab) == wanted { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func leavingTheTabEndsThePointing() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let other = browser.open(URL(string: "about:blank#hide-elements-other")!, foreground: true)
        let page = browser.open(URL(string: "about:blank#hide-elements-page")!, foreground: true)
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for tab in [other, page] {
            for _ in 0..<100 where tab.loading { try await Task.sleep(for: .milliseconds(20)) }
        }

        browser.toggleHiding()
        try #require(browser.veiling)
        try #require(try await wait(for: page, cursor: "crosshair"))

        browser.activeID = other.id
        #expect(!browser.veiling)
        #expect(try await wait(for: page, cursor: ""))
        // Esc is the next key's again, not a second toggle on this page.
        #expect(try await cursor(other) == "")
    }
}

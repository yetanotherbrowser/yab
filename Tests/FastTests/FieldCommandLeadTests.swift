import AppKit
import Testing
@testable import Fast

/// Three letters of a command's other words ("ins" of "install extension")
/// put Add Extension above an open Instagram tab and the search. Over a
/// page the list shows, open or visited, a command leads only called by its
/// whole name; with no such page, as before.
@MainActor @Suite(.serialized)
struct FieldCommandLeadTests {
    private func withBrowser(_ body: (Browser, Tab) throws -> Void) rethrows {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(later: .nonPersistent())
        tab.restore(url: URL(string: "https://www.instagram.com/")!, title: "Instagram")
        let front = Tab(later: .nonPersistent())
        front.restore(url: URL(string: "https://fixture.example/")!, title: "Fixture")
        browser.lay([front, tab])
        browser.activeID = front.id
        let suggest = browser.prefs.searchSuggest, requests = browser.prefs.fieldRequests, menu = browser.prefs.menuCommands
        let under = FieldUnder.shared
        let matches = (under.tabs, under.pages, under.commands)
        browser.prefs.searchSuggest = false
        browser.prefs.fieldRequests = false
        browser.prefs.menuCommands = true
        under.tabs = true; under.pages = true; under.commands = true
        browser.history = History([])
        browser.openFresh()
        defer {
            tab.close(); front.close(); browser.dismiss(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.searchSuggest = suggest
            browser.prefs.fieldRequests = requests
            browser.prefs.menuCommands = menu
            under.tabs = matches.0; under.pages = matches.1; under.commands = matches.2
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        try body(browser, tab)
    }

    private func isAddExtension(_ row: Suggestion?) -> Bool {
        guard let row else { return false }
        if case .command(.addExtension) = row.kind { return true }
        return row.key == "Add Extension"
    }

    private func isCommand(_ row: Suggestion?) -> Bool {
        guard let row else { return false }
        if case .command = row.kind { return true }
        return row.menuTargetID != nil
    }

    /// "ins" and "inst" took the top row for Inspect Element and Add
    /// Extension over an open Instagram tab; Return did them.
    @Test(arguments: ["ins", "inst", "insta"])
    func fewLettersDontPutACommandOverAnOpenTab(words: String) throws {
        try withBrowser { browser, tab in
            browser.replaceTyped(words)
            let offers = browser.offers
            #expect(!isCommand(offers[browser.query.lead ?? 0]), "\(words): \(offers.map(\.key))")
            #expect(!isCommand(offers.first), "\(words): \(offers.map(\.key))")
            let opened = try #require(offers.firstIndex { $0.tab == tab.id })
            for (i, row) in offers.enumerated() where isCommand(row) { #expect(opened < i, "\(words): \(offers.map(\.key))") }
        }
    }

    /// No open or visited page is named by these words: the command leads.
    @Test(arguments: ["add ext", "add extension", "install ext"])
    func withNoPageNamedTheCommandStillLeads(words: String) {
        guard #available(macOS 15.4, *) else { return }
        withBrowser { browser, _ in
            browser.replaceTyped(words)
            #expect(isAddExtension(browser.offers.first), "\(words): \(browser.offers.map(\.key))")
        }
    }

    /// With Open Tabs off in Settings › Field the Instagram tab isn't
    /// shown, so it doesn't hold the command back. ("ins" still shows a
    /// site, siteinspire.com, and that one does.)
    @Test(arguments: ["inst"])
    func aHiddenTabDoesntHoldACommandBack(words: String) throws {
        try withBrowser { browser, tab in
            FieldUnder.shared.tabs = false
            browser.replaceTyped(words)
            let offers = browser.offers
            #expect(!offers.contains { $0.tab == tab.id }, "\(words): \(offers.map(\.key))")
            #expect(isCommand(offers[browser.query.lead ?? 0]), "\(words): \(offers.map(\.key))")
        }
    }
}

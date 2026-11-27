import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct NativeTextSearchTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    @Test func rewritesSwiftUISelectableTextMenuAndSearchesInYab() throws {
        let search = NativeTextSearch.shared
        var captured: (words: String, window: NSWindow?)?
        search.onSearch = { words, window in captured = (words, window) }
        defer { search.onSearch = nil }

        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: Text("hello world from answer").textSelection(.enabled))
        window.contentView = host
        window.layoutIfNeeded()
        let interactionView = try #require(host.subviews.first)
        try #require(window.makeFirstResponder(interactionView))
        interactionView.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: interactionView.frame.midX, y: interactionView.frame.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(interactionView.menu(for: event))
        let original = try #require(menu.items.first { $0.action == NativeTextSearch.systemAction })
        #expect(original.target !== search)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)

        #expect(original.target === search)
        #expect(original.action == #selector(NativeTextSearch.searchSelection(_:)))
        #expect(original.title == "Search with \(Engine.name)")
        #expect(search.validateMenuItem(original))

        search.searchSelection(original)
        #expect(captured?.words == "hello world from answer")
        #expect(captured?.window === window)
    }

    @Test func rewritesNSTextViewMenuAndRefreshesOnReuse() throws {
        let search = NativeTextSearch.shared
        var captured: [String] = []
        search.onSearch = { words, _ in captured.append(words) }
        defer { search.onSearch = nil }

        let window = makeWindow()
        defer { window.close() }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "alpha beta gamma"
        window.contentView = textView
        try #require(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        let menu = NSMenu()
        let item = NSMenuItem(title: "Search With Google", action: NativeTextSearch.systemAction, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(NativeTextSearch.systemIdentifier)
        menu.addItem(item)

        search.rewrite(menu, fallbackWindow: window)
        #expect(item.target === search)
        #expect(item.action == #selector(NativeTextSearch.searchSelection(_:)))
        search.searchSelection(item)
        #expect(captured == ["alpha"])

        textView.setSelectedRange(NSRange(location: 6, length: 4))
        search.rewrite(menu, fallbackWindow: window)
        search.searchSelection(item)
        #expect(captured == ["alpha", "beta"])
    }

    @Test func openSearchClosesFieldAnswerAndOpensTabWithSpaceEngine() throws {
        let browser = Browser(windowID: UUID())
        let window = makeWindow()
        BrowserWindows.shared.register(window, for: browser)
        defer { window.close() }

        let space = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: false, search: "kagi")
        browser.spaces.append(space)
        browser.spaceID = space.id
        browser.editing = true
        browser.query.answering = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "swift macros"
        window.contentView = textView
        try #require(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 12))

        let menu = NSMenu()
        let item = NSMenuItem(title: "Search With Google", action: NativeTextSearch.systemAction, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(NativeTextSearch.systemIdentifier)
        menu.addItem(item)

        NativeTextSearch.shared.rewrite(menu, fallbackWindow: window)
        #expect(item.title == "Search with Kagi")

        let initialCount = browser.tabs.count
        NativeTextSearch.shared.searchSelection(item)

        #expect(!browser.editing)
        #expect(!browser.query.answering)
        #expect(browser.tabs.count == initialCount + 1)
        let opened = try #require(browser.active)
        #expect(opened.address == URL(string: "https://kagi.com/search?q=swift%20macros"))
    }

    @Test func openSearchPreservesPrivateTab() throws {
        let browser = Browser(windowID: UUID())
        let window = makeWindow()
        BrowserWindows.shared.register(window, for: browser)
        defer { window.close() }

        let privateTab = browser.open(URL(string: "https://example.com")!, foreground: true, shy: true)
        #expect(privateTab.shy)
        browser.editing = true

        NativeTextSearch.shared.openSearch("private query", from: window)

        let opened = try #require(browser.active)
        #expect(opened !== privateTab)
        #expect(opened.shy)
        #expect(opened.address == browser.searchEngine.url(for: "private query"))
    }

    @Test func leavesWebKitAndOtherMenuItemsUntouched() {
        let menu = NSMenu()
        let webAction = NSSelectorFromString("_contextMenuItemSelected:")
        let webKitSearch = NSMenuItem(title: "Search with Google", action: webAction, keyEquivalent: "")
        webKitSearch.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(webKitSearch)
        menu.addItem(copy)

        NativeTextSearch.shared.rewrite(menu)

        #expect(webKitSearch.target == nil)
        #expect(webKitSearch.action == webAction)
        #expect(copy.target == nil)
        #expect(copy.action == #selector(NSText.copy(_:)))
    }

    @Test func fallsBackToBrowserWindowFromAuxiliaryWindow() throws {
        let browser = Browser(windowID: UUID())
        let browserWindow = makeWindow()
        let auxiliaryWindow = makeWindow()
        BrowserWindows.shared.register(browserWindow, for: browser)
        defer {
            auxiliaryWindow.close()
            browserWindow.close()
        }

        let initialCount = browser.tabs.count
        NativeTextSearch.shared.openSearch("settings query", from: auxiliaryWindow)

        #expect(browser.tabs.count == initialCount + 1)
        #expect(browser.active?.address == browser.searchEngine.url(for: "settings query"))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}

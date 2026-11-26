import AppKit
import Testing
import WebKit
@testable import Fast

/// A small window's page is the one tab of an extension window of its own,
/// active there, so an extension pressed in it acts on that page. In the
/// handoff suite, serialized with it: each opens a real small window.
extension LinkWindowHandoffTests {
    private static func extensionPage(_ name: String) -> URL {
        URL(string: "data:text/html,%3Ctitle%3E\(name)%3C/title%3E")!
    }

    private static func blankExtension() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-link-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version": 3, "name": "Blank", "version": "1.0"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
    }

    @Test func aSmallWindowIsAnExtensionWindowOfItsOwn() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        let owner = Extensions.shared
        let browser = Browser(windowID: UUID())
        owner.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            owner.unfollow(browser)
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        let front = browser.open(Self.extensionPage("Front"), foreground: true)
        let tab = browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        tab.go(to: Self.extensionPage("Small"))
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        mini = link
        link.window.setFrameOrigin(NSPoint(x: -30000, y: 0))
        try await Task.sleep(for: .milliseconds(250))

        #expect(owner.told(tab) == link.extensionKey)
        #expect(owner.told(front) == browser.windowID)
        let context = try await Self.blankExtension()
        let own = try #require(owner.window(of: tab))
        #expect(own.link === link)
        #expect(own.windowType(for: context) == .popup)
        #expect(own.tabs(for: context).count == 1)
        #expect((own.activeTab(for: context) as? ExtensionTab)?.tab === tab)
        #expect(owner.adapter(for: tab).isSelected(for: context))
        #expect(owner.adapter(for: tab).indexInWindow(for: context) == 0)
        // The browser's window keeps its own tab in front, and doesn't list the small window's page.
        let row = try #require(owner.window(of: front))
        #expect((row.activeTab(for: context) as? ExtensionTab)?.tab === front)
        #expect(!row.tabs(for: context).contains { ($0 as? ExtensionTab)?.tab === tab })

        // Closed: its page and its window are gone to WebKit.
        link.window.close()
        link.window.contentView = nil
        mini = nil
        try await Task.sleep(for: .milliseconds(250))
        #expect(owner.told(tab) == nil)
        #expect(!owner.webExtensionController(owner.controller, openWindowsFor: context)
            .contains { ($0 as? ExtensionWindow)?.isLink == true })
    }
}

/// Keep hands a small window's page to the browser window: the same tab,
/// moved once from the small window's extension window to the row's.
extension LinkWindowHandoffTests {
    /// A browser whose window is a shell with a stage, as the keep fixtures above.
    @MainActor
    private struct Shell {
        let browser: Browser
        let window: NSWindow
        let stage: StageView
        let previous: NSWindow?

        init() {
            browser = Browser(windowID: UUID())
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            stage = StageView(frame: content.bounds)
            content.addSubview(stage)
            window.orderFront(nil)
            previous = Links.window
            Links.window = window
        }

        func dispose() {
            Extensions.all.forEach { $0.unfollow(browser) }
            browser.letGo()
            window.close()
            window.contentView = nil
            Links.window = previous
            for space in browser.spaces {
                let suffix = space.id == Space.firstID ? "" : "-\(space.id.uuidString)"
                try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString)\(suffix).json"))
            }
        }
    }

    /// `tab` in a small window of `browser`'s, followed as the app follows one.
    private static func small(_ tab: Tab, in browser: Browser) async throws -> LinkWindow {
        browser.prepare(tab)
        browser.outside.append(tab)
        tab.go(to: extensionPage("Small"))
        let page = tab.page
        LinkWindow.present(tab, for: browser)
        let link = try #require(LinkWindow.owning(page: page))
        link.window.setFrameOrigin(NSPoint(x: -30000, y: 0))
        try await Task.sleep(for: .milliseconds(250))
        return link
    }

    private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func keepMovesTheSameTabToTheBrowserWindowOnce() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        try #require(BrowserWindows.shared.activeWindow == nil)
        let owner = Extensions.shared
        let shell = Shell()
        let browser = shell.browser
        owner.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            shell.dispose()
        }
        let front = browser.open(Self.extensionPage("Front"), foreground: true)
        let tab = browser.blankTab()
        let link = try await Self.small(tab, in: browser)
        mini = link
        try #require(owner.told(tab) == link.extensionKey)
        let adapter = owner.adapter(for: tab)

        link.keep()
        // Every look until the stage has the page: in one window or the other, never none.
        var seen: [UUID?] = [owner.told(tab)]
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(10))
            seen.append(owner.told(tab))
        }
        #expect(!seen.contains(nil))
        #expect(owner.told(tab) == browser.windowID)
        #expect(LinkWindow.owning(page: tab.page) === link)

        shell.stage.show(tab.page, of: tab.id)
        try await Self.until { LinkWindow.owning(link.window) == nil }
        try #require(LinkWindow.owning(link.window) == nil)
        mini = nil
        try await Task.sleep(for: .milliseconds(250))

        let context = try await Self.blankExtension()
        #expect(owner.told(tab) == browser.windowID)
        // Moved, not closed and opened again: WebKit's tab is the same one.
        #expect(owner.adapter(for: tab) === adapter)
        #expect(browser.tabs.filter { $0 === tab }.count == 1)
        #expect(browser.outside.isEmpty)
        let row = try #require(owner.window(of: tab))
        #expect(!row.isLink)
        #expect(row.tabs(for: context).filter { ($0 as? ExtensionTab)?.tab === tab }.count == 1)
        // The button acts on the kept page, not the tab that was in front.
        #expect((row.activeTab(for: context) as? ExtensionTab)?.tab === tab)
        #expect(owner.activeAdapter(in: browser)?.tab === tab)
        #expect(owner.activeAdapter?.tab !== front)
        #expect(owner.adapter(for: tab).isSelected(for: context))
        #expect(!owner.webExtensionController(owner.controller, openWindowsFor: context)
            .contains { ($0 as? ExtensionWindow)?.isLink == true })
    }

    /// Kept into a space with sign-ins of its own: that sign-in's extensions
    /// get the page opened afresh, and the first sign-in's let its page go.
    @Test func keepIntoAnotherSignInTellsEachSignInItsOwnTab() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        try #require(BrowserWindows.shared.activeWindow == nil)
        let first = Extensions.shared
        let shell = Shell()
        let browser = shell.browser
        first.follow(browser)
        let spacesWere = Store.settings.object(forKey: "spaces")
        browser.prefs.usesSpaces = true
        let work = browser.addSpace(named: "Handoff " + UUID().uuidString, ownSignIns: true, show: false)
        let other = Extensions.of(space: work)
        try #require(other !== first)
        other.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            other.unfollow(browser)
            browser.deleteSpace(work)
            shell.dispose()
            Store.settings.set(spacesWere, forKey: "spaces")
        }
        let tab = browser.blankTab()
        let link = try await Self.small(tab, in: browser)
        mini = link
        try #require(first.told(tab) == link.extensionKey)
        try #require(other.told(tab) == nil)
        try #require(browser.signsInAgain(tab, in: work))

        link.keep(into: work)
        let fresh = try #require(browser.active)
        try #require(fresh !== tab)
        try await Task.sleep(for: .milliseconds(250))
        #expect(other.told(fresh) == browser.windowID)
        #expect(first.told(fresh) == nil)
        #expect(other.told(tab) == nil)

        shell.stage.show(fresh.page, of: fresh.id)
        try await Self.until { LinkWindow.owning(link.window) == nil }
        try #require(LinkWindow.owning(link.window) == nil)
        mini = nil
        try await Task.sleep(for: .milliseconds(250))

        let context = try await Self.blankExtension()
        #expect(tab.gone)
        #expect(first.told(tab) == nil)
        #expect(!first.webExtensionController(first.controller, openWindowsFor: context)
            .contains { ($0 as? ExtensionWindow)?.isLink == true })
        #expect(other.told(fresh) == browser.windowID)
        #expect(first.told(fresh) == nil)
        #expect(browser.tabs.filter { $0 === fresh }.count == 1)
    }

    /// A private page is kept as the same tab, seen by the extensions it was
    /// made with, if any, and by no other sign-in's, before and after.
    @Test(arguments: [false, true])
    func keepLeavesAPrivatePageWithItsOwnExtensions(allowed: Bool) async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        try #require(BrowserWindows.shared.activeWindow == nil)
        let was = Store.settings.object(forKey: "extensions.private")
        Store.settings.set(allowed, forKey: "extensions.private")
        let first = Extensions.shared
        let shell = Shell()
        let browser = shell.browser
        first.follow(browser)
        let spacesWere = Store.settings.object(forKey: "spaces")
        browser.prefs.usesSpaces = true
        let work = browser.addSpace(named: "Handoff " + UUID().uuidString, ownSignIns: true, show: false)
        let other = Extensions.of(space: work)
        other.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            other.unfollow(browser)
            browser.deleteSpace(work)
            shell.dispose()
            Store.settings.set(spacesWere, forKey: "spaces")
            Store.settings.set(was, forKey: "extensions.private")
        }
        let tab = Tab(shy: true, configuration: Web.configuration(shy: true))
        try #require(tab.shy)
        let link = try await Self.small(tab, in: browser)
        mini = link
        let context = try await Self.blankExtension()
        #expect(first.told(tab) == (allowed ? link.extensionKey : nil))
        #expect(other.told(tab) == nil)
        if allowed { #expect(first.window(of: tab)?.isPrivate(for: context) == true) }

        link.keep(into: work)
        #expect(browser.active === tab)
        shell.stage.show(tab.page, of: tab.id)
        try await Self.until { LinkWindow.owning(link.window) == nil }
        mini = nil
        try await Task.sleep(for: .milliseconds(250))

        #expect(!tab.gone)
        #expect(first.told(tab) == (allowed ? browser.windowID : nil))
        #expect(other.told(tab) == nil)
        #expect(Extensions.all.filter { $0.told(tab) != nil }.count == (allowed ? 1 : 0))
    }

    /// With no browser window to take the key, the hidden window keeps it
    /// until the stage has the page: it is no small window in front then.
    @Test func aKeptSmallWindowIsNotInFrontWhileItHandsOver() async throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)
        try #require(BrowserWindows.shared.activeWindow == nil)
        let owner = Extensions.shared
        let shell = Shell()
        let browser = shell.browser
        Links.window = nil
        owner.follow(browser)
        var mini: LinkWindow?
        defer {
            mini?.window.close()
            mini?.window.contentView = nil
            shell.dispose()
        }
        let tab = browser.blankTab()
        let link = try await Self.small(tab, in: browser)
        mini = link
        try #require(LinkWindow.inFront(key: link.window) === link)

        link.keep()
        try #require(LinkWindow.owning(link.window) === link)
        #expect(LinkWindow.inFront(key: link.window) == nil)
    }
}

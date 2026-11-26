import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumAdoptedPeekTests {
    @MainActor private final class Scene {
        // Without a factory a test process has no Chromium runtime and the
        // tabs fall back to WebKit pages; the adopted route is Chromium's.
        let browser = Browser(windowID: UUID())
        let source: Tab, child: Tab, front: Tab
        let window: NSWindow
        let view = PeekView()
        init(background: Bool = false) {
            _ = NSApplication.shared
            let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
            source = Tab(shy: true, engine: .chromium, factory: factory)
            child = Tab(shy: true, engine: .chromium, factory: factory)
            front = Tab(shy: true, engine: .chromium, factory: factory)
            source.restore(url: URL(string: "https://feedly.com/")!, title: "Feedly")
            child.restore(url: URL(string: "https://article.test/story")!, title: "Article")
            source.pin = "F"
            for tab in [source, child, front] { browser.prepare(tab) }
            browser.lay([source, child, front])
            browser.activeID = background ? front.id : child.id
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.browser = browser
            browser.peekView = view
        }
        func end() {
            browser.hidePeek()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            window.close()
            window.contentView = nil
        }
    }

    @Test(arguments: [false, true])
    func firstNativeLinkActionKeepsThePageAndRestoresItsSource(background: Bool) throws {
        let scene = Scene(background: background)
        defer { scene.end() }
        let browser = scene.browser, child = scene.child, source = scene.source
        let page = try #require(child.page as? ChromiumPage)
        page.events = browser
        page.popupBackSource = source
        page.receiveAction(["request": .string("original-request"), "url": .string("https://article.test/story"),
                            "transition": .number(0), "gesture": .bool(true)])
        #expect(child.page === page, "The native document and opener must survive placement")
        #expect(!browser.tabs.contains { $0 === child })
        #expect(browser.outside.filter { $0 === child }.count == 1)
        #expect(source.peek === child)
        #expect(browser.activeID == (background ? scene.front.id : source.id))
        #expect(browser.peeking === (background ? nil : child))
        #expect(child.backSourceAvailable)
        #expect(page.popupBackSource == nil)
    }

    @Test(arguments: [false, true], ["https://t.co/article", "about:blank", ""])
    func adoptionPlacesBeforePublishingAnyRow(scripted: Bool, address: String) throws {
        // The test executable has no bundled Chromium runtime. Advertise
        // the same engine as the shipped app before install creates its tab.
        let oldEngine = Store.settings.object(forKey: PageEngineSelection.key)
        Store.settings.set("chromium", forKey: PageEngineSelection.key)
        defer {
            if let oldEngine { Store.settings.set(oldEngine, forKey: PageEngineSelection.key) }
            else { Store.settings.removeObject(forKey: PageEngineSelection.key) }
        }
        #expect(PageEngineFactory.chromiumAvailable)
        let scene = Scene()
        defer { scene.end() }
        let browser = scene.browser, source = scene.source
        browser.lay([source, scene.front])
        browser.activeID = source.id
        _ = source.page // A native popup receipt comes from an already-built opener.
        let profile = source.chromiumProfile
        let event = YabCoreEvent(name: "tab.created", params: [
            "tab": .string("placement-child"), "profile": .string(profile), "private": .bool(true),
            "creationPurpose": .string("popup"), "opener": .string("source"), "foreground": .bool(true),
            "url": .string(address),
            "source": .object(["url": .string("https://feedly.com/"), "main": .bool(true), "gesture": .bool(true)])
        ])
        let child = try #require(ChromiumTabAdoption.install(event, opener: source))
        #expect(browser.activeID == source.id, "A native popup must never take the full stage")
        #expect(!browser.tabs.contains { $0 === child }, "Placement precedes row publication")
        #expect(source.peek === child)
        let page = try #require(child.builtPage as? ChromiumPage)
        page.receiveAction(["request": .string("placement"), "url": .string("https://article.test/story"),
                            "transition": .number(scripted ? 1 : 0), "gesture": .bool(!scripted)])
        #expect(browser.activeID == source.id)
        #expect(source.peek === child)
        #expect(page.popupForegroundFrom == nil)
    }

    @Test func nativeBackgroundDispositionCannotBecomeAPeekWithoutPressMetadata() throws {
        let scene = Scene()
        defer { scene.end() }
        let page = try #require(scene.child.page as? ChromiumPage)
        scene.browser.activeID = scene.source.id
        page.events = scene.browser
        page.popupBackSource = scene.source
        page.popupRequestedForeground = false
        page.lastPress = nil
        page.receiveAction(["request": .string("background"), "url": .string("https://article.test/story"),
                            "transition": .number(0), "gesture": .bool(true)])
        #expect(scene.browser.tabs.contains { $0 === scene.child })
        #expect(scene.source.peek == nil)
        #expect(scene.browser.activeID == scene.source.id)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, [.command, .shift], []])
    func adoptedModifiedLinkNavigatesItsExistingTabExactlyOnce(flags: NSEvent.ModifierFlags) throws {
        let scene = Scene()
        defer { scene.end() }
        let browser = scene.browser, child = scene.child, source = scene.source
        let page = try #require(child.page as? ChromiumPage)
        let foreground = flags.contains(.shift)
        browser.activeID = source.id
        page.events = browser
        page.popupBackSource = source
        page.popupRequestedForeground = foreground
        if foreground { page.popupForegroundFrom = source.id }
        // Empty flags represents a middle-click, whose native button is 4.
        page.lastPress = (flags, flags.isEmpty ? 4 : 0, ProcessInfo.processInfo.systemUptime)
        let before = browser.tabs.map(\.id)
        page.receiveAction(["request": .string("modified-native-child"), "url": .string("http://127.0.0.1/story"),
                            "transition": .number(0), "gesture": .bool(true)])
        #expect(browser.tabs.map(\.id) == before, "The adopted destination must not open a second tab")
        #expect(child.page === page)
        #expect(browser.activeID == (foreground ? child.id : source.id))
        #expect(source.peek == nil)
        #expect(child.backSourceAvailable)
        #expect(page.lastPress == nil, "Inherited input is consumed by placement, not reused by later navigations")
    }

    @Test func delayedPlacementDoesNotStealANewerSelection() throws {
        let scene = Scene()
        defer { scene.end() }
        let page = try #require(scene.child.page as? ChromiumPage)
        scene.browser.activeID = scene.source.id
        page.popupForegroundFrom = scene.source.id
        scene.browser.activeID = scene.front.id
        page.resolvePopupForeground()
        #expect(scene.browser.activeID == scene.front.id)
        #expect(page.popupForegroundFrom == nil)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, [.command, .shift], .control])
    func explicitNewTabsStayInTheRow(flags: NSEvent.ModifierFlags) {
        let scene = Scene()
        defer { scene.end() }
        let action = PageAction(request: URLRequest(url: URL(string: "https://article.test/story")!),
            kind: .linkActivated, targetIsMainFrame: true, source: nil,
            modifierFlags: flags, buttonNumber: 0, shouldPerformDownload: false, userInitiated: true)
        #expect(!scene.browser.peekAdoptedLink(scene.child, from: scene.source, action: action))
        #expect(scene.browser.tabs.contains { $0 === scene.child })
        #expect(scene.source.peek == nil)
    }

    @Test func aMeetingKeepsItsNativeTab() {
        let scene = Scene()
        defer { scene.end() }
        let action = PageAction(request: URLRequest(url: URL(string: "https://meet.google.com/abc-defg-hij")!),
            kind: .linkActivated, targetIsMainFrame: true, source: nil,
            modifierFlags: [], buttonNumber: 0, shouldPerformDownload: false, userInitiated: true)
        #expect(!scene.browser.peekAdoptedLink(scene.child, from: scene.source, action: action))
        #expect(scene.browser.tabs.contains { $0 === scene.child })
    }

    @Test func closingAdoptedPeekTabDismissesPeek() throws {
        let scene = Scene()
        defer { scene.end() }
        let browser = scene.browser, child = scene.child, source = scene.source
        let page = try #require(child.page as? ChromiumPage)
        page.events = browser
        page.popupBackSource = source
        page.receiveAction(["request": .string("oauth-peek"), "url": .string("https://accounts.google.com/o/oauth2/auth"),
                            "transition": .number(0), "gesture": .bool(true)])
        #expect(browser.peeking === child)
        #expect(source.peek === child)

        page.receive(YabCoreEvent(name: "tab.closed", params: [:]))
        #expect(browser.peeking == nil)
        #expect(browser.peekFrom == nil)
        #expect(source.peek == nil)
    }
}

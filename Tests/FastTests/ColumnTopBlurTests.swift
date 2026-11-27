import AppKit
import Testing
import WebKit
@testable import Fast

/// While the row of spaces slides, the top's blur keeps the row's strongest
/// strength on every page, whatever a page's own scroll says, and gives it
/// back at the landing.
@MainActor @Suite(.serialized)
struct ColumnTopBlurTests {
    private func withColumn(_ check: (ColumnPages, ColumnPage, EdgeBlurView) throws -> Void) throws {
        try #require(Thread.isMainThread && Store.testing && Store.world != nil)
        try #require(Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        browser.lookForMailSignInLink = {}
        browser.dropSpare()
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut, prefs.sideWidth, prefs.usesSpaces)
        prefs.sidebar = true; prefs.sideShut = false; prefs.sideWidth = 240; prefs.usesSpaces = false
        let tabs = (0..<40).map { number in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(configuration: configuration)
            tab.restore(url: URL(string: "https://top-blur.invalid/\(number)")!, title: "Row \(number)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs.first?.id
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            prefs.sidebar = old.0; prefs.sideShut = old.1; prefs.sideWidth = old.2; prefs.usesSpaces = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            browser.dropSpare()
        }
        let pages = ColumnPages(browser: browser)
        pages.frame = CGRect(x: 0, y: 0, width: 240, height: 600)
        pages.given(.init(lead: 44, footRoom: SideBar.footHeight, top: 36, foot: true),
                    look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        pages.sync()
        defer { pages.stop(); pages.pages.values.forEach { $0.hand.grip.watch(false) } }
        let page = try #require(pages.shown)
        let blur = try #require(page.subviews.compactMap { $0 as? EdgeBlurView }.first { $0.edge == .top })
        try check(pages, page, blur)
    }

    @Test func aScrolledPageKeepsItsBlurThroughTheSlideAndGetsItsOwnBack() throws {
        try withColumn { pages, page, blur in
            page.scroll(to: 200)
            pages.sync()
            #expect(page.topDepth == 1)
            #expect(blur.alphaValue == 1)
            let space = try #require(pages.browser?.spaceID)
            #expect(pages.beginSlide(order: [space], home: 0))
            // Its rows back at the top mid-slide: the row's strength stays.
            page.scroll(to: 0)
            pages.sync()
            #expect(page.topDepth == 0)
            #expect(blur.alphaValue == 1)
            pages.endSlide()
            #expect(blur.alphaValue == 0)
        }
    }
}

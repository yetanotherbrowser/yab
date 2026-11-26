import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct NavigationMetadataTests {
    private func keptIcon() async throws -> String {
        let site = "metadata-" + UUID().uuidString.lowercased() + ".test"
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill(); NSBezierPath(rect: rect).fill(); return true
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        await Favicons.shared.adopt(png, for: site)
        return site
    }

    @Test func aNewPageDoesNotBorrowThePreviousPagesHostIcon() async throws {
        let site = try await keptIcon()
        let old = URL(string: "https://\(site)/a")!
        let next = URL(string: "https://\(site)/b")!
        let tab = Tab(shy: true, factory: .webKitOnly)
        defer { tab.close() }
        tab.restore(url: old, title: "Alpha")
        #expect(tab.icon != nil)
        tab.go(to: next)
        #expect(tab.title.isEmpty)
        #expect(tab.icon == nil, "The host fallback belongs to Alpha, not the pending Beta document")
        #expect(Favicons.shared.cached(site) != nil, "Navigation must not erase the site's icon cache")
    }

    @Test func aReloadOrAWokenTabKeepsTheIconItWears() async throws {
        let site = try await keptIcon()
        let tab = Tab(shy: true, factory: .webKitOnly)
        defer { tab.close() }
        tab.restore(url: URL(string: "https://\(site)/a")!, title: "Alpha")
        let worn = try #require(tab.icon)
        tab.navigationStarted(nil)
        #expect(tab.awaitingDocumentMetadata)
        #expect(tab.icon === worn, "The same page loading again keeps its icon, not its letter (#735)")
    }
    @Test(arguments: [PageEngineKind.webKit, .chromium])
    func theRealCommitRouteReleasesIconDiscoveryOnBothEngines(engine: PageEngineKind) {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let factory = engine == .chromium
            ? PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
            : .webKitOnly
        let tab = Tab(shy: true, engine: engine, factory: factory)
        browser.prepare(tab); browser.lay([tab]); browser.activeID = tab.id
        defer {
            browser.letGo(); browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        let page = tab.page
        tab.prepareDocumentMetadata(for: URL(string: "https://1.1.1.1/next")!)
        #expect(tab.awaitingDocumentMetadata)
        browser.page(page, navigation: .committed(nil))
        #expect(!tab.awaitingDocumentMetadata, "Icon discovery must not depend on WebKit-only commit bookkeeping")
    }

}

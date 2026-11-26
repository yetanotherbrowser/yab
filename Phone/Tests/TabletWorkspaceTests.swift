import XCTest
import UIKit
import WebKit
@testable import YabPhone

@MainActor
final class TabletWorkspaceTests: XCTestCase {
    func testTabletToolbarNeverChangesPhoneOrDuoLayouts() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402),
                     CGSize(width: 669, height: 951), CGSize(width: 951, height: 669),
                     CGSize(width: 500, height: 900)] {
            XCTAssertFalse(TabletWorkspaceGeometry.usesToolbar(size: size, regular: true, idiom: .pad))
            XCTAssertFalse(TabletWorkspaceGeometry.usesToolbar(size: size, regular: true, idiom: .phone))
        }
        for size in [CGSize(width: 768, height: 1024), CGSize(width: 1376, height: 1032)] {
            XCTAssertTrue(TabletWorkspaceGeometry.usesToolbar(size: size, regular: true, idiom: .pad))
            XCTAssertFalse(TabletWorkspaceGeometry.usesToolbar(size: size, regular: false, idiom: .pad))
            XCTAssertFalse(TabletWorkspaceGeometry.usesToolbar(size: size, regular: true, idiom: .pad, verticalBar: true))
        }
    }

    func testSearchAndFrameRespectKeyboardAndSidebarBounds() {
        let size = CGSize(width: 1024, height: 768)
        let open = TabletWorkspaceGeometry(size: size, statusBar: 24, sidebar: true, framed: true)
        XCTAssertEqual(open.page, CGRect(x: 272, y: 76, width: 744, height: 684))
        XCTAssertLessThanOrEqual(open.top + 24 + open.searchHeight(keyboard: 350), size.height - 350)
        let closed = TabletWorkspaceGeometry(size: size, statusBar: 24, sidebar: false, framed: true)
        XCTAssertEqual(closed.rim, 0)
        XCTAssertEqual(closed.page.width, size.width)
    }

    func testTabletSearchClosesWithoutLandingInThePhonePlate() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.workspace.tabletControls = true
        app.workspace.windowSize = CGSize(width: 1024, height: 768)
        app.workspace.paneFrame = CGRect(x: 328, y: 88, width: 688, height: 672)
        app.field.openNewTab(privately: false)
        app.field.rest()
        XCTAssertEqual(app.screenSize, app.workspace.windowSize)
        app.field.close()
        try await until { !app.field.shown }
        XCTAssertNil(app.surfaces.field)
        XCTAssertFalse(app.surfaces.fieldLanding)
        XCTAssertNil(app.field.mode)
    }

    /// The iPad's tree draws its own chrome: the phone's plate, back button
    /// and stack circle (ChromeLayer) are never mounted under it, with All
    /// Tabs shut, opening, open or closing into a card. The same window cut
    /// to an iPhone's width mounts it, so the probe sees it when it is there.
    func testTheTabletTreeNeverMountsThePhoneChrome() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the tablet tree is an iPad's")
        let disabled = Motion.disabled
        let forced = SettingsUI.shared.welcomeForced
        Motion.disabled = true
        SettingsUI.shared.welcomeForced = false
        defer { Motion.disabled = disabled; SettingsUI.shared.welcomeForced = forced }
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = RootController(app: app)
        root.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func resize(_ size: CGSize) {
            window.frame = CGRect(origin: .zero, size: size)
            root.view.frame = window.bounds
            root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        }
        func chromeMounted() -> Bool {
            func all(_ controller: UIViewController) -> [UIViewController] { [controller] + controller.children.flatMap(all) }
            return all(root).contains { $0 is ChromeHostController }
        }
        func settle() async throws {
            for _ in 0..<6 { root.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(17)) }
        }
        resize(CGSize(width: 1376, height: 1032))
        try await until { app.workspace.tabletControls }
        try await settle()
        XCTAssertFalse(chromeMounted(), "a page in front")

        let stack = TabStack.of(app)
        stack.openGallery()
        try await until { stack.gallery != nil }
        stack.holdOpening(at: TabGalleryTiming.openDuration / 2)
        try await settle()
        XCTAssertFalse(chromeMounted(), "All Tabs opening")
        let gallery = try XCTUnwrap(stack.gallery)
        let chosen = try XCTUnwrap(stack.cards(of: gallery).first?.id)
        stack.choose(chosen, heldAt: TabGalleryTiming.closeDuration / 2)
        try await settle()
        XCTAssertEqual(stack.gallery?.phase, .closing)
        XCTAssertFalse(chromeMounted(), "All Tabs closing into its card")
        stack.dismissGallery()
        try await settle()
        XCTAssertFalse(chromeMounted(), "All Tabs gone")

        resize(CGSize(width: 402, height: 874))
        try await until { !app.workspace.tabletControls }
        try await settle()
        XCTAssertTrue(chromeMounted(), "an iPhone's width draws the phone's chrome")
    }

    /// Real pooled web views, resized through the same RootController as the app.
    /// These are representative Duo bounds on iOS, not an actual Duo runtime.
    func testDuoKeepsDraftsAndHistoryAndRecordsBothOrientations() async throws {
        let disabled = Motion.disabled
        let forced = SettingsUI.shared.welcomeForced
        Motion.disabled = true
        SettingsUI.shared.welcomeForced = false
        defer { Motion.disabled = disabled; SettingsUI.shared.welcomeForced = forced }
        let app = AppModel(world: try World.load(named: "mira"))
        let first = Tab(id: "duo-first", title: "First document", site: "First document", icon: "globe", page: "workspace")
        let second = Tab(id: "duo-second", title: "Second document", site: "Second document", icon: "globe", page: "workspace")
        app.browser.open(first, deduplicate: false)
        app.workspace.openBeside(current: first.id, other: second.id)
        app.browser.open(second, deduplicate: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = RootController(app: app)
        root.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        root.view.frame = window.bounds
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        try await until { app.workspace.expanded && app.pages.painted.contains(second.id) && app.pages.painted.contains(first.id) }
        let page = try XCTUnwrap(app.pages.liveView(second.id))
        let firstPage = try XCTUnwrap(app.pages.liveView(first.id))
        _ = try await firstPage.evaluateJavaScript("document.querySelector('input').value='First kept draft'; true;")
        _ = try await page.evaluateJavaScript("document.querySelector('input').value='Duo kept draft'; history.pushState({},'', '#duo-kept'); true;")
        for (name, size) in [("duo-landscape", CGSize(width: 951, height: 669)), ("duo-portrait", CGSize(width: 669, height: 951)), ("duo-restored-landscape", CGSize(width: 951, height: 669))] {
            window.frame.size = size
            root.view.frame = window.bounds
            root.view.setNeedsLayout(); root.view.layoutIfNeeded()
            let layout = BrowserWorkspaceLayout(size: size, regular: true, paired: true)
            try await until { abs(app.workspace.paneFrame.width - layout.pane(true).width) < 1 }
            XCTAssertFalse(app.workspace.tabletControls)
            XCTAssertTrue(app.workspace.unfolded)
            XCTAssertEqual(app.workspace.canSplit, size.width > size.height)
            XCTAssertEqual(layout.split, size.width > size.height)
            XCTAssertTrue(app.workspace.paired)
            XCTAssertTrue(page === app.pages.liveView(second.id))
            XCTAssertTrue(firstPage === app.pages.liveView(first.id))
            let draft = try await page.evaluateJavaScript("document.querySelector('input').value") as? String
            XCTAssertEqual(draft, "Duo kept draft")
            let hash = try await page.evaluateJavaScript("location.hash") as? String
            XCTAssertEqual(hash, "#duo-kept")
            let firstDraft = try await firstPage.evaluateJavaScript("document.querySelector('input').value") as? String
            XCTAssertEqual(firstDraft, "First kept draft")
            if size.width < size.height {
                let tabs = Set(app.browser.space.allTabs.map(\.id))
                app.newTabBeside()
                XCTAssertEqual(Set(app.browser.space.allTabs.map(\.id)), tabs)
                XCTAssertNil(app.workspace.newPage)
            }
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    /// The unfolded screens, in the size of the real inner display, each by
    /// the route a person takes. The pictures are kept with the run.
    func testUnfoldedDuoAtlas() async throws {
        let disabled = Motion.disabled
        let forced = SettingsUI.shared.welcomeForced
        Motion.disabled = true
        SettingsUI.shared.welcomeForced = false
        FieldModel.sheetInTests = true
        defer { Motion.disabled = disabled; SettingsUI.shared.welcomeForced = forced; FieldModel.sheetInTests = false }
        let app = AppModel(world: try World.load(named: "mira"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = RootController(app: app)
        root.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        root.view.frame = window.bounds
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        try await until { app.workspace.unfolded }
        func snap(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(1200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let tabs = app.browser.space.allTabs.filter { $0.page != nil && !$0.isMail }
        for tab in tabs.prefix(5) { app.browser.select(tab.id); _ = app.pages.activate(tab); try await Task.sleep(for: .milliseconds(500)) }
        let hn = try XCTUnwrap(app.browser.space.allTabs.first { $0.title.contains("Hacker News") })
        app.browser.select(hn.id)
        _ = app.pages.activate(hn)
        try await snap("unfolded-page")
        app.field.openSpaces()
        try await until { app.field.spacesResting }
        try await until { app.surfaces.fieldBeside }
        XCTAssertFalse(app.surfaces.coversChrome, "The page beside the spaces keeps its chrome")
        XCTAssertNil(app.field.spacesVeil, "Nothing fades the plate beside the spaces")
        try await snap("unfolded-panel")
        app.field.askFromSpaces()
        try await until { !app.field.spacesResting && app.field.shown }
        try await snap("unfolded-search")
        app.field.close()
        try await until { !app.field.shown }
        app.openPageMenu(); app.pageMenu.shown = true; app.pageMenu.page = .site
        try await snap("unfolded-site")
        app.surfaces.closeMenu(); app.pageMenu.reset()
        try await Task.sleep(for: .milliseconds(400))
        app.surfaces.openSettings()
        try await snap("unfolded-settings")
        app.surfaces.closeSettings()
        try await Task.sleep(for: .milliseconds(400))
        TabStack.of(app).openGallery()
        try await Task.sleep(for: .milliseconds(1500))
        try await snap("unfolded-stack")
    }

    func testThreeCardsStandWholeAcrossAnUnfoldedDuo() {
        let layout = TabGalleryLayout(screen: CGSize(width: 951, height: 669), count: 5, across: true)
        let cards = (2...4).map { layout.card($0, focus: 3) }
        XCTAssertGreaterThanOrEqual(cards[0].minX, 0)
        XCTAssertLessThanOrEqual(cards[2].maxX, 951)
        XCTAssertFalse(cards[0].intersects(cards[1]))
        XCTAssertFalse(cards[1].intersects(cards[2]))
        XCTAssertEqual(layout.step, cards[1].minX - cards[0].minX)
    }

    private func until(_ check: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !check(), Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(check())
    }
}

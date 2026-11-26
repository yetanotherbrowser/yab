import XCTest
import UIKit
import WebKit
@testable import YabPhone

@MainActor
final class TabletLayoutTests: XCTestCase {
    func testClosingEitherPanePreservesItsNeighborBeforeSelectionReconciliation() throws {
        for close in ["first", "second"] {
            for focused in ["first", "second"] {
                let app = AppModel(world: try World.load(named: "mira"))
                let first = Tab(id: "first", title: "First", site: "First", icon: "globe", page: "workspace")
                let second = Tab(id: "second", title: "Second", site: "Second", icon: "globe", page: "workspace")
                app.browser.open(first, deduplicate: false)
                app.browser.open(second, deduplicate: false)
                app.workspace.openBeside(current: first.id, other: second.id)
                // Deliberately leave secondFocused stale, as in a same-turn
                // interaction before the root's onChange reconciles selection.
                app.browser.select(focused)
                app.closeWorkspacePage(close)
                let survivor = close == "first" ? "second" : "first"
                XCTAssertNil(app.browser.tab(close))
                XCTAssertEqual(app.browser.tab?.id, survivor)
                XCTAssertNotNil(app.browser.tab(survivor))
                XCTAssertFalse(app.workspace.paired)
                XCTAssertNil(app.workspace.savedPair)
            }
        }
    }

    func testTabletStatusBarFollowsTheNativeChromeEvenAboveALightPage() throws {
        let old = SettingsStore.shared.appearance
        defer { SettingsStore.shared.appearance = old }
        let app = AppModel(world: try World.load(named: "mira"))
        let root = RootController(app: app)
        app.workspace.tabletControls = true
        SettingsStore.shared.appearance = .dark
        XCTAssertEqual(root.preferredStatusBarStyle, .lightContent)
        SettingsStore.shared.appearance = .light
        XCTAssertEqual(root.preferredStatusBarStyle, .darkContent)
    }

    func testLocalWidthsAndVisibilityPersistOnlyAfterTheDragFinishes() throws {
        let name = "tablet-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let layout = TabletLayoutPreferences(defaults: defaults)
        layout.resizeSidebar(to: 334, save: false)
        XCTAssertNil(defaults.object(forKey: "ipadSidebarWidth"))
        layout.resizeSidebar(to: 334)
        layout.resizeSplit(to: 0.64)
        layout.addressBars = false
        layout.sidebarShown = false
        layout.framed = false
        let restored = TabletLayoutPreferences(defaults: defaults)
        XCTAssertEqual(restored.sidebarWidth, 334)
        XCTAssertEqual(restored.splitFraction, 0.64, accuracy: 0.001)
        XCTAssertFalse(restored.addressBars)
        XCTAssertFalse(restored.sidebarShown)
        XCTAssertFalse(restored.framed)
        layout.resizeSidebar(to: .nan)
        layout.resizeSplit(to: .infinity)
        XCTAssertEqual(layout.sidebarWidth, Metrics.Tablet.sidebar)
        XCTAssertEqual(layout.splitFraction, 0.5)
    }

    func testSplitMinimumsAndNarrowWindowNeverOverwriteThePreferredWidths() {
        let preferences = TabletLayoutPreferences()
        preferences.resizeSidebar(to: 340)
        preferences.resizeSplit(to: 0.7)
        let narrow = TabletWorkspaceGeometry(size: CGSize(width: 900, height: 700), statusBar: 24,
                                            sidebar: true, framed: true, sidebarExtent: preferences.sidebarWidth, paired: true)
        XCTAssertEqual(narrow.sidebarWidth, 0)
        XCTAssertEqual(preferences.sidebarWidth, 340)
        let plan = BrowserWorkspaceLayout(size: narrow.page.size, regular: true, paired: true,
                                          fraction: preferences.splitFraction, gap: Metrics.Tablet.splitGap)
        XCTAssertTrue(plan.split)
        XCTAssertGreaterThanOrEqual(plan.pane(false).width, Metrics.Workspace.minimumPane - 0.001)
        XCTAssertGreaterThanOrEqual(plan.pane(true).width, Metrics.Workspace.minimumPane - 0.001)
        XCTAssertEqual(plan.pane(true).maxX, narrow.page.width, accuracy: 0.001)
        XCTAssertEqual(preferences.splitFraction, 0.7)
        let wideSidebar = TabletWorkspaceGeometry(size: CGSize(width: 1024, height: 768), statusBar: 24,
                                                  sidebar: true, framed: true, sidebarExtent: 360, paired: true)
        let fitting = BrowserWorkspaceLayout(size: wideSidebar.page.size, regular: true, paired: true,
                                             gap: Metrics.Tablet.splitGap, horizontal: true)
        XCTAssertEqual(wideSidebar.sidebarWidth, 360)
        XCTAssertTrue(fitting.split, "the window remains landscape when its sidebar makes the page area taller than wide")
        XCTAssertEqual(fitting.pane(false).width, 320, accuracy: 0.001)
        XCTAssertEqual(fitting.pane(true).width, 320, accuracy: 0.001)
    }

    func testLeavingThePairForAnotherCardAndReturningRestoresBothDocuments() {
        let workspace = BrowserWorkspace()
        workspace.resize(expanded: true)
        workspace.openBeside(current: "a", other: "b")
        workspace.leaveSplit()
        workspace.selected("c", valid: ["a", "b", "c"])
        XCTAssertFalse(workspace.paired)
        XCTAssertEqual(workspace.savedPair?.ids, ["a", "b"])
        workspace.selected("b", valid: ["a", "b", "c"])
        XCTAssertEqual(workspace.first, "a")
        XCTAssertEqual(workspace.second, "b")
        XCTAssertTrue(workspace.secondFocused)
        workspace.fullSpread()
        workspace.selected("b", valid: ["a", "b", "c"])
        XCTAssertFalse(workspace.paired, "Separate Split forgets the grouping")
    }

    func testAppearanceAddsOnlyTabletRowsAndUsesTheActiveWorkspaceChoices() throws {
        let name = "tablet-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let layout = TabletLayoutPreferences()
        var context = SettingsContext()
        var content = SettingsContent(store: store, context: context, tabletLayout: layout)
        XCTAssertFalse(content.sections(.appearance).contains { $0.id == "appearance.browser" })
        context.isPad = true
        content = SettingsContent(store: store, context: context, tabletLayout: layout)
        let group = try XCTUnwrap(content.sections(.appearance).first { $0.id == "appearance.browser" })
        XCTAssertEqual(group.rows.map(\.id), ["appearance.sidebar", "appearance.tabsInSidebar", "appearance.addressBars", "appearance.pageFrame"])
        let row = try XCTUnwrap(group.rows.first { $0.id == "appearance.addressBars" })
        guard case let .toggle(binding) = row.kind else { return XCTFail("an ordinary Settings switch") }
        XCTAssertFalse(layout.addressBars, "off, as the Mac's Show Address Bar")
        binding.wrappedValue = true
        XCTAssertTrue(layout.addressBars)
        XCTAssertFalse(store.tablet.addressBars, "a fixture's choices never touch the live preference store")
        XCTAssertEqual(content.sections(.appearance).prefix(2).map(\.id), ["appearance", "websites"])
    }

    func testGalleryGroupsTwoPagesOnlyWhenTheTabletCapturedAPair() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        let tabs = Array(app.browser.space.today.prefix(3))
        XCTAssertEqual(tabs.count, 3)
        let stack = TabStack.of(app)
        var gallery = TabStack.Gallery(space: app.browser.spaceID, order: tabs.map(\.id))
        XCTAssertEqual(stack.cards(of: gallery).map(\.id), tabs.map(\.id))
        gallery.pair = BrowserWorkspace.Pair(first: tabs[0].id, second: tabs[1].id, focused: tabs[1].id)
        XCTAssertEqual(stack.cards(of: gallery).map(\.id), [tabs[1].id, tabs[2].id])
        XCTAssertEqual(stack.pairTabs(in: gallery).map(\.id), [tabs[0].id, tabs[1].id])
        gallery.dropped.insert(tabs[0].id)
        XCTAssertTrue(stack.pairTabs(in: gallery).isEmpty)
        XCTAssertEqual(stack.cards(of: gallery).map(\.id), [tabs[1].id, tabs[2].id])
    }

    func testNativeTabletKeepsBothWebViewsAndDraftsWhileResizingAndRotating() async throws {
        let disabled = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = disabled }
        let app = AppModel(world: try World.load(named: "mira"))
        let first = Tab(id: "tablet-first", title: "First document", site: "First document", icon: "globe", page: "workspace")
        let second = Tab(id: "tablet-second", title: "Second document", site: "Second document", icon: "globe", page: "workspace")
        app.browser.open(first, deduplicate: false)
        app.workspace.openBeside(current: first.id, other: second.id)
        app.browser.open(second, deduplicate: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = RootController(app: app)
        root.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        try await until { app.workspace.tabletControls && app.pages.painted.contains(first.id) && app.pages.painted.contains(second.id) }
        let a = try XCTUnwrap(app.pages.liveView(first.id))
        let b = try XCTUnwrap(app.pages.liveView(second.id))
        _ = try await a.evaluateJavaScript("document.querySelector('input').value='first draft';scrollTo(0,200);true")
        _ = try await b.evaluateJavaScript("document.querySelector('input').value='second draft';history.pushState({},'', '#saved');scrollTo(0,200);true")
        let prior = app.workspace.paneFrame
        app.workspace.preferences.resizeSidebar(to: 340)
        app.workspace.preferences.resizeSplit(to: 0.65)
        try await until { app.workspace.paneFrame != prior && a.bounds.width > b.bounds.width }
        // Each page of a split keeps its band either way; the address setting
        // leaves the panes as they are, the tab bar takes height from them.
        let withBars = app.workspace.paneFrame.height
        app.workspace.preferences.addressBars = false
        try await until { app.workspace.paneFrame.height == withBars }
        app.workspace.preferences.tabsInSidebar = false
        try await until { app.workspace.paneFrame.height < withBars - 40 }
        app.workspace.preferences.tabsInSidebar = true
        try await until { app.workspace.paneFrame.height == withBars }
        app.browser.select(first.id)
        app.reconcileWorkspace()
        app.workspace.preferences.resizeSidebar(to: 360)
        for size in [CGSize(width: 1024, height: 768), CGSize(width: 834, height: 1194),
                     CGSize(width: 500, height: 900), CGSize(width: 1194, height: 834)] {
            window.frame.size = size; root.view.frame = window.bounds
            root.view.setNeedsLayout(); root.view.layoutIfNeeded()
            try await until { app.workspace.windowSize == size }
            XCTAssertTrue(a === app.pages.liveView(first.id))
            XCTAssertTrue(b === app.pages.liveView(second.id))
            try await until(details: "Focused page visible at \(size)") { a.window === window }
            if size.width > size.height {
                try await until(details: "Both panes at \(size): a=\(a.window === window), b=\(b.window === window), paired=\(app.workspace.paired)") {
                    a.window === window && b.window === window
                }
                let g = TabletWorkspaceGeometry(size: size, statusBar: window.safeAreaInsets.top, sidebar: true,
                                                framed: true, sidebarExtent: 360, paired: true)
                let plan = BrowserWorkspaceLayout(size: g.page.size, regular: true, paired: true,
                                                  fraction: app.workspace.preferences.splitFraction,
                                                  gap: Metrics.Tablet.splitGap, horizontal: true)
                try await until(details: "Panes at \(size): expected \(plan.pane(false).width), \(plan.pane(true).width); actual \(a.bounds), \(b.bounds); sidebar=\(app.workspace.preferences.sidebarWidth)") {
                    abs(a.bounds.width - plan.pane(false).width) < 1 && abs(b.bounds.width - plan.pane(true).width) < 1
                }
                let aRect = a.convert(a.bounds, to: window), bRect = b.convert(b.bounds, to: window)
                XCTAssertLessThanOrEqual(aRect.maxX, bRect.minX)
            }
            let aDraft = try await a.evaluateJavaScript("document.querySelector('input').value") as? String
            let bDraft = try await b.evaluateJavaScript("document.querySelector('input').value") as? String
            XCTAssertEqual(aDraft, "first draft")
            XCTAssertEqual(bDraft, "second draft")
            let hash = try await b.evaluateJavaScript("location.hash") as? String
            XCTAssertEqual(hash, "#saved")
            let aScroll = try await a.evaluateJavaScript("scrollY") as? Double
            let bScroll = try await b.evaluateJavaScript("scrollY") as? Double
            XCTAssertEqual(aScroll ?? -1, 200, accuracy: 5)
            XCTAssertEqual(bScroll ?? -1, 200, accuracy: 5)
            XCTAssertEqual(app.workspace.tabletControls, size.width > 500)
        }
    }

    private func until(details: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ check: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !check(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(check(), details(), file: file, line: line)
    }
}

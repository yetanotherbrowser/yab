import XCTest
import UIKit
@testable import YabPhone

/// Row 1029: the browser's hardware keys, through the real responder chain
/// of a browser window this test owns.
@MainActor
final class BrowserKeysTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var root: RootController!
    private var app: AppModel!
    private var oldMotion = false

    override func setUpWithError() throws {
        oldMotion = Motion.disabled
        Motion.disabled = true
        let tabs = ["first", "second", "third"].map {
            Tab(id: $0, title: $0.capitalized, site: $0.capitalized, icon: "globe", url: "about:blank")
        }
        let world = World(name: "browser-keys", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226),
                  today: tabs, current: "second")
        ], mac: World.Mac(joined: false))
        app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.keyWindow
        window = UIWindow(windowScene: scene)
        root = RootController(app: app)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        root = nil
        app = nil
        Motion.disabled = oldMotion
    }

    private var action: Selector { #selector(RootController.browserKey(_:)) }

    /// The key as the menu bar sends it: from the browser's view up its chain.
    @discardableResult
    private func press(_ key: BrowserKey) throws -> Bool {
        let command = key.command
        guard root.canPerformAction(action, withSender: command) else { return false }
        let target = try XCTUnwrap(root.view.target(forAction: action, withSender: command))
        XCTAssertTrue((target as AnyObject) === root, "the browser's root takes \(key.title)")
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: target, from: command, for: nil))
        return true
    }

    private var ids: [Tab.ID] { app.browser.space.allTabs.map(\.id) }

    func testEveryKeyHasItsOwnChordAndTitle() {
        let chords = BrowserKey.all.map { "\($0.modifiers.rawValue):\($0.input)" }
        XCTAssertEqual(Set(chords).count, chords.count)
        XCTAssertEqual(Set(BrowserKey.all.map(\.title)).count, BrowserKey.all.count)
        for key in BrowserKey.all {
            XCTAssertEqual(BrowserKey(token: key.command.propertyList), key)
            XCTAssertTrue(key.command.wantsPriorityOverSystemBehavior)
        }
        XCTAssertEqual(BrowserKey.closeTab.input, "w")
        XCTAssertEqual(BrowserKey.closeTab.modifiers, .command)
        XCTAssertEqual(BrowserKey.reopenTab.modifiers, [.command, .shift])
        XCTAssertEqual(BrowserKey.nextTab.modifiers, .control)
    }

    func testCommandTOpensTheNewTabFieldWithoutAnEmptyTab() throws {
        let before = ids
        XCTAssertTrue(try press(.newTab))
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertEqual(app.browser.tab?.id, "second")
        XCTAssertEqual(ids, before)
    }

    func testSidebarKeyUsesTheDesktopChordOnlyInTheTabletWorkspace() throws {
        XCTAssertEqual(BrowserKey.toggleSidebar.input, "s")
        XCTAssertEqual(BrowserKey.toggleSidebar.modifiers, .command)
        app.workspace.tabletControls = true
        app.workspace.sidebarShown = true
        let selected = app.browser.tab?.id
        XCTAssertTrue(try press(.toggleSidebar))
        XCTAssertFalse(app.workspace.sidebarShown)
        XCTAssertTrue(try press(.toggleSidebar))
        XCTAssertTrue(app.workspace.sidebarShown)
        XCTAssertEqual(app.browser.tab?.id, selected)
        app.surfaces.openField(.newTab)
        XCTAssertFalse(try press(.toggleSidebar), "the field keeps the keys while it is up")
        app.field.close()
        app.workspace.tabletControls = false
        XCTAssertFalse(try press(.toggleSidebar), "compact phone and Duo retain their keys")
    }

    func testCommandCommaOpensSettingsAsOnTheMac() throws {
        XCTAssertEqual(BrowserKey.settings.input, ",")
        XCTAssertEqual(BrowserKey.settings.modifiers, .command)
        XCTAssertTrue(try press(.settings))
        XCTAssertTrue(app.surfaces.settings)
        XCTAssertTrue(try press(.settings), "still ours with Settings up, never the system's Settings app")
        XCTAssertTrue(app.surfaces.settings, "and Settings stays as it is")
    }

    func testShiftCommandNOpensAPrivateNewTab() throws {
        XCTAssertEqual(BrowserKey.newPrivateTab.input, "n")
        XCTAssertEqual(BrowserKey.newPrivateTab.modifiers, [.command, .shift])
        XCTAssertTrue(try press(.newPrivateTab))
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertTrue(app.field.isPrivate)
    }

    func testPageKeysFollowTheMacsViewMenu() throws {
        XCTAssertEqual(BrowserKey.zoomIn.input, "=")
        XCTAssertEqual(BrowserKey.reader.modifiers, [.command, .shift])
        XCTAssertEqual(app.mayUse(.stop), app.currentPageState.isLoading, "Stop only while the page loads")
        XCTAssertFalse(app.mayUse(.reader), "no reader for this page")
        XCTAssertTrue(try press(.zoomIn))
        XCTAssertEqual(app.pageZoom, 1.1, accuracy: 0.001)
        XCTAssertTrue(try press(.actualSize))
        XCTAssertEqual(app.pageZoom, 1, accuracy: 0.001)
        XCTAssertTrue(try press(.zoomOut))
        XCTAssertEqual(app.pageZoom, 0.9, accuracy: 0.001)
        app.pageMenuZoom(0)
    }

    func testOpenInSplitViewPairsTheLinkBesideItsPage() throws {
        app.workspace.resize(expanded: true)
        app.workspace.windowSize = CGSize(width: 1376, height: 1032)
        let source = try XCTUnwrap(app.browser.tab?.id)
        XCTAssertTrue(app.canOpenLinkBeside(source))
        app.openHeldLink(URL(string: "https://example.com/beside")!, from: source, as: .beside)
        XCTAssertTrue(app.workspace.paired)
        XCTAssertEqual(app.workspace.first, source)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, "https://example.com/beside")
        app.workspace.windowSize = CGSize(width: 800, height: 1100)
        XCTAssertFalse(app.canOpenLinkBeside(source), "no split in a narrow window")
    }

    func testDuplicateTabOpensTheSamePageInFront() throws {
        let tab = Tab(id: "web", title: "Example", site: "Example", icon: "globe", url: "https://example.com/a")
        app.browser.open(tab, deduplicate: false)
        let before = app.browser.space.allTabs.count
        app.duplicate(tab)
        XCTAssertEqual(app.browser.space.allTabs.count, before + 1)
        XCTAssertNotEqual(app.browser.tab?.id, "web")
        XCTAssertEqual(app.browser.tab?.navigationURL, tab.navigationURL)
    }

    func testCommandLOpensTheAddress() throws {
        XCTAssertTrue(try press(.openLocation))
        XCTAssertEqual(app.surfaces.field, .address)
    }

    func testCommandWClosesTheTabKeepsTheWindowAndShiftCommandTBringsItBack() throws {
        XCTAssertTrue(try press(.closeTab))
        XCTAssertNil(app.browser.space.tab("second"))
        XCTAssertNotNil(app.browser.tab)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.rootViewController === root)
        XCTAssertTrue(try press(.reopenTab))
        XCTAssertEqual(app.browser.tab?.id, "second")
        XCTAssertEqual(ids, ["first", "second", "third"])
        XCTAssertFalse(try press(.reopenTab), "one close, one reopen")
    }

    func testCommandWClosesTheFocusedSplitPaneAndSelectsItsCompanion() throws {
        app.workspace.resize(expanded: true)
        app.workspace.openBeside(current: "first", other: "second")
        XCTAssertTrue(try press(.closeTab))
        XCTAssertFalse(app.workspace.paired)
        XCTAssertEqual(app.browser.tab?.id, "first")
        XCTAssertNil(app.browser.space.tab("second"))
    }

    func testCommandWWithTheFieldUpPutsTheFieldAway() throws {
        try press(.newTab)
        XCTAssertTrue(try press(.closeTab))
        XCTAssertNil(app.surfaces.field)
        XCTAssertEqual(ids, ["first", "second", "third"])
    }

    func testTheLastTabClosesAndCommandWThenDoesNothing() throws {
        app.browser.close("first")
        app.browser.close("third")
        XCTAssertTrue(try press(.closeTab))
        XCTAssertNil(app.browser.tab)
        XCTAssertFalse(try press(.closeTab), "no tab: ⌘W is off, never the window's")
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(try press(.newTab))
        XCTAssertEqual(app.surfaces.field, .newTab)
    }

    func testControlTabAndCommandNumbersSwitchTabs() throws {
        let order = app.browser.pagingOrder.map(\.id)
        XCTAssertEqual(order.count, 3)
        XCTAssertTrue(try press(.tab(1)))
        XCTAssertTrue(try press(.nextTab))
        XCTAssertEqual(app.browser.tab?.id, order[1])
        XCTAssertTrue(try press(.nextTab))
        XCTAssertEqual(app.browser.tab?.id, order[2])
        XCTAssertTrue(try press(.previousTab))
        XCTAssertEqual(app.browser.tab?.id, order[1])
        XCTAssertTrue(try press(.tab(1)))
        XCTAssertEqual(app.browser.tab?.id, app.browser.pagingOrder.first?.id)
        XCTAssertTrue(try press(.tab(9)))
        XCTAssertEqual(app.browser.tab?.id, app.browser.pagingOrder.last?.id)
        XCTAssertTrue(try press(.tab(3)))
        XCTAssertEqual(app.browser.tab?.id, app.browser.pagingOrder[2].id)
        XCTAssertFalse(try press(.tab(4)), "no fourth tab")
        XCTAssertEqual(ids, ["first", "second", "third"])
    }

    func testPageKeysNeedAPage() throws {
        XCTAssertTrue(app.mayUse(.reload))
        XCTAssertTrue(app.mayUse(.find))
        XCTAssertFalse(app.mayUse(.forward), "no page ahead")
        for id in ids { app.browser.close(id) }
        for key in [BrowserKey.reload, .find, .back, .forward, .openLocation, .nextTab] {
            XCTAssertFalse(app.mayUse(key), key.title)
        }
    }

    func testCoveredBrowserTakesNoKeys() throws {
        let cover: [() -> Void] = [
            { self.app.surfaces.settings = true },
            { self.app.surfaces.join = true },
            { self.app.surfaces.chat = .newChat }
        ]
        for show in cover {
            show()
            // ⌘, alone is still taken, so the system's Settings item never gets it, and does nothing.
            for key in BrowserKey.all where key != .settings { XCTAssertFalse(try press(key), key.title) }
            let settingsWereUp = app.surfaces.settings
            XCTAssertTrue(try press(.settings))
            XCTAssertEqual(app.surfaces.settings, settingsWereUp)
            XCTAssertNil(app.surfaces.field)
            XCTAssertEqual(app.browser.tab?.id, "second")
            XCTAssertEqual(ids.count, 3)
            app.surfaces.settings = false
            app.surfaces.join = false
            app.surfaces.chat = nil
        }
    }

    func testAWindowNotInFrontIgnoresKeys() throws {
        previousKey?.makeKey()
        XCTAssertFalse(window.isKeyWindow)
        for key in [BrowserKey.newTab, .closeTab] {
            XCTAssertFalse(root.canPerformAction(action, withSender: key.command))
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: root, from: key.command, for: nil))
        }
        XCTAssertNil(app.surfaces.field)
        XCTAssertEqual(ids.count, 3)
    }
}

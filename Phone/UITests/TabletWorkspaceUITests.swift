import XCTest

final class TabletWorkspaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ready: URL!
    override func setUp() {
        continueAfterFailure = false
        ready = Atlas.readyFolder()
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        try? FileManager.default.removeItem(at: ready)
    }
    private func launch(_ state: String) {
        app?.terminate()
        app = XCUIApplication()
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready))
    }
    private func picture(_ name: String) throws {
        let image = XCUIScreen.main.screenshot()
        let folder = Atlas.out.appendingPathComponent("tablet-chrome-\(Atlas.model)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func wait(_ check: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check() }, object: nil)], timeout: 15) == .completed
    }
    private func focusCompanion(address: String) {
        let button = app.buttons[address.contains("first") ? "tablet.split.tab.workspace-primary" : "tablet.split.tab.workspace-secondary"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        // WebKit's remote AX union can retain its old extent after a turn.
        // Touch the visible control, then prove that its action selected the page.
        let frame = button.frame
        XCTAssertTrue(app.frame.contains(frame))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(wait { (self.app.buttons["tablet.address"].value as? String)?.contains(address) == true })
    }

    func testTabletCompactOmniboxUsesDesktopPresentation() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("field.1")
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertLessThan(element("tablet.omnibox").frame.height, 60)
        XCTAssertEqual(element("tablet.omnibox").frame.width, 540, accuracy: 1)
        XCTAssertFalse(app.buttons["tablet.search.recent.0"].exists)
        try picture("ipad-compact-address")
        input.typeText("Linear")
        XCTAssertTrue(app.buttons["tablet.search.row.0"].waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(element("tablet.omnibox").frame.height, 266)
        try picture("ipad-compact-results")
        element("field.eyes").tap()
        XCTAssertEqual(element("field.eyes").value as? String, "on")
        try picture("ipad-compact-private")
        element("field.eyes").tap()
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        try picture("ipad-compact-keyboard-dismissed")
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !input.exists })
        app.buttons["tablet.newTab"].tap()
        XCTAssertTrue(app.buttons["tablet.search.recent.0"].waitForExistence(timeout: 10))
        try picture("ipad-compact-new-tab")
        app.buttons["tablet.search.recent.0"].tap()
        XCTAssertTrue(wait { !self.app.textFields["field.input"].exists && self.app.buttons["tablet.address"].isHittable })
        launch("field.answer.sum")
        XCTAssertTrue(app.buttons["tablet.search.answer"].waitForExistence(timeout: 10))
        try picture("ipad-compact-calculator")
    }

    func testTabletSiteControlsStatesAndCertificate() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("site.1")
        XCTAssertTrue(element("site.settings").waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(element("site.settings").frame.width, 300)
        try picture("ipad-site-consistent")
        let blocker = app.buttons["site.blocksAds.toggle"]
        XCTAssertEqual(blocker.value as? String, "On")
        blocker.tap()
        XCTAssertTrue(wait { (blocker.value as? String) == "Off" })
        try picture("ipad-site-blocker-off")
        blocker.tap()
        XCTAssertTrue(wait { (blocker.value as? String) == "On" })
        let desktop = app.buttons["site.desktop.toggle"]
        desktop.tap()
        XCTAssertTrue(wait { (desktop.value as? String) == "On" })
        try picture("ipad-site-desktop-on")
        app.buttons["site.zoom.in"].tap()
        XCTAssertTrue(wait { (self.app.buttons["site.zoom.reset"].value as? String) == "110%" })
        app.buttons["site.zoom.reset"].tap()
        XCTAssertTrue(wait { (self.app.buttons["site.zoom.reset"].value as? String) == "100%" })
        app.buttons["site.zoom.out"].tap()
        XCTAssertTrue(wait { (self.app.buttons["site.zoom.reset"].value as? String) == "90%" })
        app.buttons["site.zoom.reset"].tap()
        app.buttons["site.connection"].tap()
        XCTAssertTrue(element("site.certificate").waitForExistence(timeout: 10))
        XCTAssertLessThan(element("site.settings").frame.height, 400)
        try picture("ipad-site-certificate")
        app.buttons["site.certificate.back"].tap()
        XCTAssertTrue(blocker.waitForExistence(timeout: 10))
        app.buttons["site.more"].tap()
        XCTAssertTrue(app.buttons["Yab Settings…"].waitForExistence(timeout: 5))
        try picture("ipad-site-more")
    }

    /// Print… in Site Controls shows the system's print panel on iPad:
    /// present(animated:) is valid there, from the window.
    func testTabletPrintShowsThePrintPanel() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("page.1")
        XCTAssertTrue(app.buttons["tablet.siteControls"].waitForExistence(timeout: 15))
        app.buttons["tablet.siteControls"].tap()
        XCTAssertTrue(element("site.more").waitForExistence(timeout: 10))
        element("site.more").tap()
        let print = app.buttons["Print…"]
        XCTAssertTrue(print.waitForExistence(timeout: 10))
        XCTAssertTrue(print.isEnabled, "a drawn page can print")
        print.tap()
        let panel = app.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Print Options', 'Printer', 'Print'} OR identifier == 'Printer'")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "no print panel")
        try picture("ipad-print-panel")
    }

    func testTabletToolbarSearchSiteControlsAndStack() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("page.1")
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["chrome.plate"].exists)
        XCTAssertFalse(app.buttons["field.close"].exists)
        try picture("ipad-portrait-sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { self.app.frame.width > self.app.frame.height })
        try picture("ipad-landscape-sidebar")
        app.buttons["tablet.sidebar"].tap()
        try picture("ipad-sidebar-closed")
        app.buttons["tablet.address"].tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("tablet.omnibox").exists)
        XCTAssertLessThan(element("tablet.omnibox").frame.width, 550)
        XCTAssertLessThan(element("tablet.omnibox").frame.height, 220)
        try picture("ipad-address-search")
        app.textFields["field.input"].typeText("Linear")
        XCTAssertTrue(app.buttons["tablet.search.row.0"].waitForExistence(timeout: 10))
        try picture("ipad-search-results")
        element("field.eyes").tap()
        XCTAssertEqual(element("field.eyes").value as? String, "on")
        try picture("ipad-search-incognito")
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !self.app.textFields["field.input"].exists })
        app.buttons["tablet.siteControls"].tap()
        XCTAssertTrue(element("site.settings").waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(element("site.settings").frame.width, 300)
        try picture("ipad-site-controls")
        let zoom = app.buttons["site.zoom.in"]
        XCTAssertTrue(zoom.exists); zoom.tap()
        XCTAssertTrue(wait { (self.app.buttons["site.zoom.reset"].value as? String) == "110%" })
        try picture("ipad-site-zoom")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        app.buttons["tablet.tabs"].tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 10))
        XCTAssertEqual(element("tabs.gallery").frame.width, app.frame.width, accuracy: 2)
        try picture("ipad-tab-stack")
        let card = element("tabs.card.work-figma-onb")
        XCTAssertTrue(card.exists); card.tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists })
        try picture("ipad-tab-stack-closed")
        app.buttons["tablet.newTab"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.typeText("Linear")
        let result = app.buttons["tablet.search.row.0"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(wait { !input.exists && self.app.buttons["tablet.address"].isHittable })
        try picture("ipad-search-submitted")
    }

    func testTabletSplitKeepsFormAcrossRotationAndFocus() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("workspace.form")
        XCUIDevice.shared.orientation = .landscapeLeft
        var draft = element("tablet.pane.workspace-secondary").textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 20))
        draft.tap(); draft.typeText("Second document stays")
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        try picture("ipad-split-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait { (draft.value as? String) == "Second document stays" && self.app.frame.height > self.app.frame.width })
        XCTAssertFalse(element("tablet.addressBar.workspace-primary").exists)
        XCTAssertFalse(app.buttons["workspace.menu"].exists)
        try picture("ipad-split-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        try picture("ipad-split-restoring-landscape")
        XCTAssertTrue(wait { self.element("tablet.addressBar.workspace-primary").exists && self.app.buttons["workspace.menu"].isHittable })
        XCTAssertEqual(draft.value as? String, "Second document stays")
        try picture("ipad-split-restored-landscape")
        focusCompanion(address: "firstdocument.com")
        draft = element("tablet.pane.workspace-primary").textFields["Draft"]
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) != "Second document stays" })
        draft.tap(); draft.typeText("First document stays")
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        element("tablet.pane.workspace-primary").links["Next document"].tap()
        XCTAssertTrue(app.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
        app.buttons["tablet.back"].tap()
        XCTAssertTrue(wait { (draft.value as? String) == "First document stays" })
        try picture("ipad-split-history")
        focusCompanion(address: "seconddocument.com")
        draft = element("tablet.pane.workspace-secondary").textFields["Draft"]
        XCTAssertTrue(wait { (draft.value as? String) == "Second document stays" })
        app.buttons["workspace.menu"].tap()
        app.buttons["Separate Split"].tap()
        XCTAssertTrue(wait { !self.element("tablet.addressBar.workspace-primary").exists })
        XCTAssertEqual(draft.value as? String, "Second document stays")
        try picture("ipad-full-spread")
    }

    func testTabletFrameAndKeyboardDismissal() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("page.1")
        let sidebar = app.buttons["tablet.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.press(forDuration: 1)
        let frame = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Frame Page with Sidebar")).firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 5)); frame.tap()
        try picture("ipad-frame-off")
        sidebar.press(forDuration: 1)
        XCTAssertTrue(frame.waitForExistence(timeout: 5)); frame.tap()
        try picture("ipad-frame-on")
        app.buttons["tablet.address"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.typeText("Linear")
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        XCTAssertTrue(element("tablet.omnibox").exists)
        XCTAssertTrue(app.buttons["field.close"].isHittable)
        try picture("ipad-search-keyboard-dismissed")
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !input.exists && self.app.buttons["tablet.address"].isHittable })
        try picture("ipad-search-closed")
        app.buttons["tablet.address"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        app.buttons["field.close"].tap()
        launch("settings.1")
        let search = app.textFields["settings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("appearance")
        try picture("ipad-settings-keyboard")
        XCTAssertTrue(search.isHittable)
    }

    func testTabletOnboardingGuideFinishesAtSidebar() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        launch("welcome.15")
        let skip = app.buttons["welcome.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        try picture("ipad-onboarding-private")
        skip.tap()
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("welcome").exists)
        try picture("ipad-onboarding-finished")
    }

    func testTabletOnboardingPageStaysOneColumn() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        for state in ["welcome.8", "welcome.10"] {
            launch(state)
            let title = app.staticTexts["welcome.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["welcome.recovery"].exists)
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let words = app.staticTexts["welcome.words"]
                XCTAssertTrue(wait { title.isHittable && words.frame.minY >= title.frame.maxY })
                XCTAssertLessThanOrEqual(words.frame.width, 525)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(words.frame))
                try picture("ipad-\(state)-\(orientation == .portrait ? "portrait" : "landscape")")
            }
            XCUIDevice.shared.orientation = .portrait
        }
        launch("welcome.14")
        let make = app.buttons["welcome.makeDefault"]
        XCTAssertTrue(make.waitForExistence(timeout: 10))
        XCTAssertTrue(make.isHittable)
        app.buttons["welcome.skip"].tap()
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        try picture("ipad-joined-onboarding-finished")
    }

    func testPhoneAndTabletSheetsAndOnboarding() throws {
        for state in ["page.1", "field.1", "site.1", "site.3", "settings.1", "welcome.5", "welcome.11", "stack.gallery"] {
            launch(state)
            if Atlas.model != "ipad" { XCTAssertFalse(app.buttons["tablet.address"].exists) }
            if state.hasPrefix("welcome") { XCTAssertFalse(app.buttons["workspace.menu"].exists) }
            if Atlas.model == "ipad", state.hasPrefix("welcome"), element("welcome.words").exists {
                XCTAssertLessThanOrEqual(element("welcome.words").frame.width, 525)
            }
            try picture("\(Atlas.model)-\(state)")
        }
    }
}

private extension XCUIElement {
    func tapIfPresent() { if exists && isHittable { tap() } }
}

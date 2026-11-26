import XCTest

/// The approved iPad workspace, exercised with real drags, touches and keys.
final class TabletLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ready: URL!
    override func setUpWithError() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        continueAfterFailure = false
        ready = Atlas.readyFolder()
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }
    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
        if let ready { try? FileManager.default.removeItem(at: ready) }
    }
    private func launch(_ state: String) {
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready))
        XCTAssertTrue(wait { self.app.frame.width > self.app.frame.height })
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 20))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pane(_ id: String) -> XCUIElement { element("tablet.pane.workspace-" + id) }
    private func wait(_ check: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check() }, object: nil)], timeout: 15) == .completed
    }
    private func picture(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("tablet-layout")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = XCUIScreen.main.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func drag(_ element: XCUIElement, by dx: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func dismissKeyboard() {
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.exists && hide.isHittable { hide.tap() }
    }

    func testResizeBothDividersAndRotatePreserveIndependentDrafts() throws {
        launch("workspace.form")
        let first = pane("primary"), second = pane("secondary")
        XCTAssertTrue(first.textFields["Draft"].waitForExistence(timeout: 20))
        XCTAssertTrue(second.textFields["Draft"].waitForExistence(timeout: 20))
        XCTAssertTrue(element("tablet.addressBar.workspace-primary").exists)
        XCTAssertTrue(element("tablet.addressBar.workspace-secondary").exists)
        second.textFields["Draft"].tap(); second.textFields["Draft"].typeText("Second draft")
        dismissKeyboard()
        first.textFields["Draft"].tap(); first.textFields["Draft"].typeText("First draft")
        dismissKeyboard()
        XCTAssertTrue(first.buttons["tablet.address"].exists, "touching the other page focuses it")
        try picture("01-split-before-resize")
        let sidebar = element("tablet.sidebar.resize"), split = element("tablet.split.resize")
        let oldSidebar = sidebar.frame.midX
        drag(sidebar, by: 48)
        XCTAssertTrue(wait { sidebar.frame.midX > oldSidebar + 30 })
        let oldSplit = split.frame.midX
        drag(split, by: 70)
        XCTAssertTrue(wait { split.frame.midX > oldSplit + 40 })
        XCTAssertEqual(first.textFields["Draft"].value as? String, "First draft")
        XCTAssertEqual(second.textFields["Draft"].value as? String, "Second draft")
        try picture("02-split-after-resize")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait { self.app.frame.height > self.app.frame.width })
        XCTAssertEqual(first.textFields["Draft"].value as? String, "First draft")
        try picture("03-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(wait { second.textFields["Draft"].exists })
        XCTAssertEqual(first.textFields["Draft"].value as? String, "First draft")
        XCTAssertEqual(second.textFields["Draft"].value as? String, "Second draft")
        try picture("04-split-restored")
    }

    func testSplitIsOneDeckCardAndReturnsToBothDocuments() throws {
        launch("workspace.form")
        XCTAssertTrue(pane("secondary").textFields["Draft"].waitForExistence(timeout: 20))
        app.buttons["tablet.tabs"].tap()
        let card = element("tabs.card.workspace-secondary")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertFalse(element("tabs.card.workspace-primary").exists)
        XCTAssertTrue(card.label.contains("Split View"))
        element("tabs.gallery").swipeLeft(velocity: .slow)
        XCTAssertTrue(wait { abs(card.frame.midX - self.app.frame.midX) < 100 })
        try picture("05-split-card")
        card.tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists })
        XCTAssertTrue(pane("primary").textFields["Draft"].exists)
        XCTAssertTrue(pane("secondary").textFields["Draft"].exists)
        try picture("06-pair-from-deck")
    }

    func testExistingAppearanceCanHideAddressBarsAndSearchRemainsAvailable() throws {
        launch("page.1")
        element("tablet.settings").tap()
        let appearance = app.buttons["settings.row.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 15)); appearance.tap()
        let bars = app.switches["settings.row.appearance.addressBars"]
        if !bars.isHittable { app.swipeUp() }
        XCTAssertTrue(bars.waitForExistence(timeout: 10))
        try picture("07-current-settings-with-tablet-rows")
        XCTAssertEqual(bars.value as? String, "1"); bars.tap()
        app.buttons["settings.back"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 10))
        app.buttons["settings.close"].tap()
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { !self.element("tablet.addressBar.work-figma-onb").exists })
        try picture("08-address-bars-hidden")
        app.buttons["tablet.address"].tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10))
        app.buttons["field.close"].tap()
        // The same hardware-keyboard entry works when the bars are hidden.
        for _ in 0..<8 {
            app.typeKey("l", modifierFlags: .command)
            if app.textFields["field.input"].waitForExistence(timeout: 1) { break }
        }
        XCTAssertTrue(app.textFields["field.input"].exists)
        try picture("09-hidden-bars-command-L")
    }

    /// All Tabs: a tap on any card takes that tab, the gallery goes, the workspace returns.
    func testAllTabsCardsOpenTheirTab() throws {
        launch("page.1")
        app.buttons["tablet.tabs"].tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 10))
        try picture("14-all-tabs")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        let card = (0..<cards.count).map { cards.element(boundBy: $0) }.first { $0.isHittable }
        let chosen = try XCTUnwrap(card, "no card can be tapped")
        let id = String(chosen.identifier.dropFirst("tabs.card.".count))
        chosen.tap()
        let gone = wait { !self.element("tabs.gallery").exists }
        if !gone { try picture("15-all-tabs-stuck") }
        XCTAssertTrue(gone, "the gallery stayed after a tap on \(id)")
        // The cards overlap, so the tab taken is whichever lies on top there: the workspace is back.
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        try picture("15-all-tabs-chosen")
    }

    func testNewTabStaysInTheSpaceChosenInTheFooterAfterBrowsingSpaces() throws {
        launch("page.1")
        element("tablet.settings").press(forDuration: 1)
        let browse = app.buttons["Spaces and Chats"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        XCTAssertTrue(element("newtab.spaces").waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        let personal = app.buttons["tablet.space.personal"]
        XCTAssertTrue(personal.waitForExistence(timeout: 10)); personal.tap()
        XCTAssertTrue(wait { personal.isSelected })
        app.buttons["tablet.newTab"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.typeText("example.com\n")
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(personal.isSelected, "the new tab must stay in Personal rather than adopting the previous Work pager")
        XCTAssertFalse(app.buttons["tablet.space.work"].isSelected)
        try picture("11-new-tab-in-selected-space")
    }

    func testBackSwipeInEitherPaneUsesThatPanesHistory() throws {
        launch("workspace.form")
        for id in ["primary", "secondary"] {
            let page = pane(id)
            let draft = page.textFields["Draft"]
            XCTAssertTrue(draft.waitForExistence(timeout: 20))
            draft.tap(); draft.typeText(id + " saved")
            dismissKeyboard()
            page.links["Next document"].tap()
            XCTAssertTrue(page.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
            let from = page.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.4))
            let to = page.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.4))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
            XCTAssertTrue(wait { draft.exists && draft.value as? String == id + " saved" }, "back swipe completes in " + id)
            try picture("10-back-swipe-" + id)
        }
    }
}

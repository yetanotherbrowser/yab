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

    /// The Mac's Show Address Bar: off, the address is the sidebar's plate;
    /// on, a band over the page. Search is a tap or ⌘L away in both.
    func testShowAddressBarMovesTheAddressAndSearchRemainsAvailable() throws {
        launch("page.1")
        let plate = element("tablet.addressPlate").waitForExistence(timeout: 10)
        if !plate { try picture("07-before-settings") }
        XCTAssertTrue(plate, "off, as the Mac: the address is the sidebar's plate")
        // By touch: the simulator builds the menu on a first key, which can
        // reach the system's own Settings item instead (⌘, has unit tests).
        let appearance = app.buttons["settings.row.appearance"]
        app.buttons["tablet.siteControls"].tap()
        XCTAssertTrue(element("site.more").waitForExistence(timeout: 10)); element("site.more").tap()
        app.buttons["Yab Settings…"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 15)); appearance.tap()
        // The iPad's rows stand at the page's foot: scrolled to, they load.
        let bars = app.switches["settings.row.appearance.addressBars"]
        // Dragged by the page's margin: a drag started on a row could press it,
        // and one of them opens the iOS Settings app.
        let corner = app.buttons["settings.back"].coordinate(withNormalizedOffset: .zero)
        for _ in 0..<4 where !(bars.waitForExistence(timeout: 2) && bars.isHittable) {
            corner.withOffset(CGVector(dx: -6, dy: 520)).press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -6, dy: 140)))
        }
        if !bars.isHittable { try picture("07-settings-no-switch") }
        XCTAssertTrue(bars.isHittable)
        try picture("07-current-settings-with-tablet-rows")
        XCTAssertEqual(bars.value as? String, "0"); bars.tap()
        app.buttons["settings.back"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 10))
        app.buttons["settings.close"].tap()
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.element("tablet.addressBar.work-figma-onb").exists && !self.element("tablet.addressPlate").exists })
        try picture("08-address-bar-shown")
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

    /// A site's first file asks from the sidebar's downloads button, and is answerable.
    func testFirstDownloadAsksFromTheDownloadsButton() throws {
        launch("downloads.ask")
        XCTAssertEqual(app.buttons["tablet.downloads.sidebar"].value as? String, "Asking")
        let download = app.buttons["download.ask.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        XCTAssertTrue(download.isHittable)
        try picture("12-download-ask")
        download.tap()
        XCTAssertTrue(wait { !download.exists })
    }

    func testDownloadsButtonListsFiles() throws {
        launch("downloads.now")
        app.buttons["tablet.downloads.sidebar"].tap()
        XCTAssertTrue(element("downloads.page").waitForExistence(timeout: 10))
        try picture("13-downloads-list")
    }

    /// A popover goes with a tap on the dimmed ground beside it.
    private func closePopover() {
        let ground = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(ground.waitForExistence(timeout: 10)); ground.tap()
        XCTAssertTrue(wait { !self.app.popovers.firstMatch.exists && !ground.exists }, "the popover stayed")
    }

    /// The question dismissed, the sidebar hidden, the toolbar's question
    /// dismissed and the sidebar shown again: its button brings the waiting
    /// question back, and that popover goes with the answer too.
    func testAQuestionTheSidebarBringsBackGoesWithItsAnswer() throws {
        launch("downloads.ask")
        let download = app.buttons["download.ask.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        closePopover()
        app.buttons["tablet.sidebar"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 15), "the toolbar's button asks in turn")
        closePopover()
        app.buttons["tablet.sidebar"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 15), "the sidebar's button asks again")
        download.tap()
        let ground = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(wait { !self.app.popovers.firstMatch.exists && !ground.exists }, "the list stayed open after the answer")
    }

    /// A question the person opened the popover for leaves the list open
    /// once answered.
    func testAQuestionThePersonOpenedLeavesTheList() throws {
        launch("downloads.ask")
        let download = app.buttons["download.ask.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        closePopover()
        app.buttons["tablet.downloads.sidebar"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()
        XCTAssertTrue(wait { !download.exists })
        XCTAssertTrue(app.popovers.firstMatch.exists, "the person's list stays")
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
        element("tablet.sidebar.newTab").press(forDuration: 1)
        let browse = app.buttons["Spaces and Chats"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
        XCTAssertTrue(element("newtab.spaces").waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()
        let personal = app.buttons["tablet.space.personal"]
        XCTAssertTrue(personal.waitForExistence(timeout: 10)); personal.tap()
        XCTAssertTrue(wait { personal.isSelected })
        app.buttons["tablet.sidebar.newTab"].tap()
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

    /// The narrowest split pane, the sidebar away: the address keeps its
    /// room, and New Tab stays a tap away in the band's one menu.
    func testNarrowSplitPaneKeepsItsAddressAndControls() throws {
        launch("tablet.split.narrow")
        let address = app.buttons["tablet.address"]
        let newTab = app.buttons["tablet.newTab"]
        let site = app.buttons["tablet.siteControls"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        try picture("16-narrow-split")
        XCTAssertGreaterThanOrEqual(address.frame.width, 90, "the address keeps room in a 320-point pane")
        XCTAssertTrue(address.isHittable)
        XCTAssertTrue(newTab.isHittable)
        XCTAssertTrue(site.isHittable)
        XCTAssertFalse(address.frame.intersects(newTab.frame))
        XCTAssertFalse(address.frame.intersects(site.frame))
        XCTAssertTrue(app.frame.contains(newTab.frame))
        XCTAssertTrue(app.buttons["tablet.sidebar"].isHittable, "the first pane keeps the sidebar's door")
        newTab.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10))
    }

    /// A space with no tab and the sidebar away still offers New Tab and
    /// the sidebar's door.
    func testEmptySpaceKeepsNewTabAndTheSidebarDoor() throws {
        XCTAssertTrue(Atlas.launch(app, state: "tablet.empty", ready: ready))
        let door = app.buttons["tablet.sidebar"]
        let newTab = app.buttons["tablet.newTab"]
        let shown = door.waitForExistence(timeout: 15) && newTab.waitForExistence(timeout: 5)
        try picture("17-empty-space")
        XCTAssertTrue(shown)
        XCTAssertTrue(door.isHittable)
        XCTAssertTrue(newTab.isHittable)
        newTab.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10))
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !self.app.textFields["field.input"].exists })
        door.tap()
        XCTAssertTrue(wait { door.value as? String == "shown" })
        try picture("18-empty-space-sidebar")
    }
}

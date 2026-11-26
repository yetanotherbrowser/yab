import XCTest

/// The approved split layout, exercised against live independent documents.
final class TabletArcSplitUITests: XCTestCase {
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
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func pane(_ side: String) -> XCUIElement { element("tablet.pane.workspace-" + side) }
    private func chip(_ side: String) -> XCUIElement { app.buttons["tablet.split.tab.workspace-" + side] }
    private func wait(_ check: @escaping () -> Bool) -> Bool { TransitionCatalog.wait(15, check) }
    private func launch(_ state: String = "workspace.form") {
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready, still: false))
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 20))
        if state == "workspace.form" {
            XCTAssertTrue(pane("primary").textFields["Draft"].waitForExistence(timeout: 20))
            XCTAssertTrue(pane("secondary").textFields["Draft"].waitForExistence(timeout: 20))
        }
    }
    private func picture(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("arc-split")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }
    private func dismissKeyboard() {
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.exists && hide.isHittable { hide.tap() }
    }

    /// The same touches record both the previous app and the candidate.
    func testRecordBothFocusedPanesForVisualComparison() throws {
        launch()
        try picture("01-right-focused")
        pane("primary").textFields["Draft"].tap()
        dismissKeyboard()
        XCTAssertTrue(wait { (self.app.buttons["tablet.address"].value as? String)?.contains("firstdocument.com") == true })
        try picture("02-left-focused")
    }

    func testEachSidebarHalfSelectsItsPageAndOwnControls() throws {
        launch()
        let left = chip("primary"), right = chip("secondary")
        XCTAssertTrue(left.exists && right.exists)
        XCTAssertLessThan(left.frame.maxX, right.frame.midX)
        XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(left.frame.height, 44)
        for side in ["primary", "secondary", "primary"] {
            chip(side).tap()
            XCTAssertTrue(wait { self.pane(side).buttons["tablet.address"].exists })
            XCTAssertTrue(chip(side).isSelected)
            let other = side == "primary" ? "secondary" : "primary"
            XCTAssertFalse(pane(other).buttons["tablet.siteControls"].exists)
            XCTAssertTrue(pane(side).buttons["tablet.reload"].exists)
            XCTAssertTrue(pane(side).buttons["tablet.paneMenu"].exists)
            XCTAssertTrue(pane(side).buttons["tablet.close.workspace-" + side].exists)
            XCTAssertTrue(pane(other).buttons["tablet.close.workspace-" + other].exists)
        }
        app.buttons["tablet.siteControls"].tap()
        XCTAssertTrue(element("site.settings").waitForExistence(timeout: 10))
        try picture("03-active-site-controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
        pane("secondary").buttons["tablet.address.workspace-secondary"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue((input.value as? String)?.contains("seconddocument.com") == true)
        try picture("04-inactive-address-opens-own-page")
        app.buttons["field.close"].tap()
        XCTAssertTrue(pane("secondary").buttons["tablet.address"].exists)
        app.buttons["tablet.paneMenu"].tap()
        app.buttons["Separate Split View"].tap()
        XCTAssertTrue(wait { self.element("tablet.addressPlate").exists })
    }

    func testInactiveNavigationActsOnItsOwnHistory() throws {
        launch()
        let first = pane("primary")
        let draft = first.textFields["Draft"]
        draft.tap(); draft.typeText("First history")
        dismissKeyboard()
        first.links["Next document"].tap()
        XCTAssertTrue(app.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
        chip("secondary").tap()
        app.buttons["tablet.back.workspace-primary"].tap()
        XCTAssertTrue(wait { (draft.value as? String) == "First history" })
        XCTAssertTrue(first.buttons["tablet.address"].exists)
        chip("secondary").tap()
        app.buttons["tablet.forward.workspace-primary"].tap()
        XCTAssertTrue(app.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
        XCTAssertTrue(first.buttons["tablet.address"].exists)
        XCTAssertTrue(pane("secondary").textFields["Draft"].exists)
        try picture("07-inactive-navigation")
    }

    func testClosingTheInactivePaneKeepsTheSurvivorDraftAndHistory() throws {
        for survivor in ["primary", "secondary"] {
            launch()
            let draft = pane(survivor).textFields["Draft"]
            draft.tap(); draft.typeText("Keep " + survivor)
            dismissKeyboard()
            pane(survivor).links["Next document"].tap()
            XCTAssertTrue(app.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
            let closed = survivor == "primary" ? "secondary" : "primary"
            app.buttons["tablet.close.workspace-" + closed].tap()
            XCTAssertTrue(wait { self.element("tablet.addressPlate").exists })
            XCTAssertFalse(element("tablet.split.row").exists)
            XCTAssertFalse(pane(closed).exists)
            app.buttons["tablet.back"].tap()
            let survivingDraft = app.textFields["Draft"]
            XCTAssertTrue(wait { (survivingDraft.value as? String) == "Keep " + survivor })
            try picture("05-closed-inactive-kept-" + survivor)
            app.terminate()
        }
    }

    func testClosingTheActivePaneKeepsTheOtherDraft() throws {
        launch()
        let draft = pane("primary").textFields["Draft"]
        draft.tap(); draft.typeText("Left survives")
        dismissKeyboard()
        chip("secondary").tap()
        app.buttons["tablet.close.workspace-secondary"].tap()
        XCTAssertTrue(wait { self.element("tablet.addressPlate").exists })
        XCTAssertEqual(app.textFields["Draft"].value as? String, "Left survives")
        try picture("06-closed-active")
    }
}

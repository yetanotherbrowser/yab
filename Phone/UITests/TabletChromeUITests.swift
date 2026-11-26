import XCTest

/// Real controls with normal animation, recorded by the farm for frame review.
final class TabletChromeUITests: XCTestCase {
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
    private func launch(_ state: String) {
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready, still: false))
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 20))
    }
    private func picture(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("tablet-chrome")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }
    private func wait(_ check: @escaping () -> Bool) -> Bool { TransitionCatalog.wait(15, check) }

    /// The Mac's column: the address a plate in the sidebar under its
    /// header, no band over the page.
    func testSinglePageKeepsTheAddressInTheSidebarAsTheMacDoes() throws {
        launch("page.1")
        try picture("single-page")
        let plate = element("tablet.addressPlate")
        XCTAssertTrue(plate.exists, "the address is the sidebar's plate")
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tablet.pane.")).firstMatch
        XCTAssertLessThanOrEqual(plate.frame.maxX, pane.frame.minX)
        XCTAssertTrue(element("tablet.sidebar.header").exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tablet.addressBar.")).firstMatch.exists)
        app.buttons["tablet.siteControls"].tap()
        XCTAssertTrue(element("site.settings").waitForExistence(timeout: 10))
        try picture("single-site-controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
        app.buttons["tablet.address"].tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10))
    }

    func testSeparatingTheSplitRestoresTheSidebarAddressWithoutLosingTheDraft() throws {
        launch("workspace.form")
        let secondary = element("tablet.pane.workspace-secondary")
        let draft = secondary.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 20))
        XCTAssertTrue(element("tablet.split.row").exists)
        try picture("split-sidebar")
        draft.tap(); draft.typeText("Preserved draft")
        if app.keyboards.buttons["Hide keyboard"].firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
        app.buttons["tablet.paneMenu"].tap()
        app.buttons["Separate Split View"].tap()
        XCTAssertTrue(wait { self.element("tablet.addressPlate").exists })
        XCTAssertFalse(element("tablet.addressBar.workspace-secondary").exists)
        XCTAssertFalse(element("tablet.split.row").exists)
        XCTAssertEqual(app.textFields["Draft"].value as? String, "Preserved draft")
        try picture("split-separated")
    }

    /// Both the old and candidate app run this same touch sequence. The movie
    /// must show intermediate page positions in each direction, not a jump.
    func testRecordSidebarOpeningAndClosingWithNormalMotion() throws {
        for state in ["page.1", "workspace.form"] {
            launch(state)
            let toggle = app.buttons["tablet.sidebar"]
            let address = app.buttons["tablet.address"].value as? String
            try picture(state + "-sidebar-shown")
            var marks: [[String: Any]] = []
            for index in 0..<4 {
                let start = Date().timeIntervalSince1970
                toggle.tap()
                let end = Date().timeIntervalSince1970
                let shown = index % 2 == 1
                XCTAssertEqual(toggle.value as? String, shown ? "shown" : "hidden")
                // The address moves between the sidebar's plate and the band as it goes.
                XCTAssertTrue(wait { self.app.buttons.matching(identifier: "tablet.address").count == 1 })
                XCTAssertEqual(app.buttons["tablet.address"].value as? String, address)
                marks.append(["start": start, "end": end, "shown": shown])
            }
            let folder = Atlas.out.appendingPathComponent("tablet-chrome")
            try Atlas.json(["state": state, "marks": marks]).write(to: folder.appendingPathComponent(state + "-motion.json"))
            try picture(state + "-sidebar-restored")
            app.terminate()
        }
    }
}

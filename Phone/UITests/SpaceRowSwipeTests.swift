import XCTest

final class SpaceRowSwipeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { app?.terminate() }

    private func node(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var row: XCUIElement { node("newtab.tab.work-launch-notes") }
    private var current: String {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == 'current'")).firstMatch.label
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "newtab.1"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(node("newtab.capsule").waitForExistence(timeout: 20))
        node("newtab.capsule").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.isHittable)
        XCTAssertEqual(current, "Work")
    }

    private func drag(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat = 0) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func save(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("space-row-swipes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Scope to this row: the field also has buttons named Close.
    private func action(_ title: String, tab: String = "work-launch-notes") -> XCUIElement {
        let key = title == "Close" ? "close" : title == "Pin" ? "pin" : "keep"
        return app.buttons["newtab.swipe.\(key).\(tab)"].firstMatch
    }

    /// #1423: typed results must leave the selector and paging available.
    func testTypedSearchCanChangeSpacesWithKeyboardUpAndDown() throws {
        launch()
        let input = app.textFields["field.input"]
        input.tap()
        input.typeText("project")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(node("newtab.capsule").exists)
        try save("search-keyboard-up")
        // The typed rows stand above the field, below the capsule.
        drag(x: app.frame.midX + 80, y: app.frame.height * 0.3, dx: -220)
        XCTAssertTrue(wait { current == "Lisbon" })
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        try save("search-keyboard-down")
        drag(x: app.frame.midX - 80, y: app.frame.height * 0.3, dx: 220)
        XCTAssertTrue(wait { current == "Work" })
        let personal = app.buttons["Personal"].firstMatch
        XCTAssertTrue(personal.exists)
        personal.tap()
        XCTAssertTrue(wait { current == "Personal" })
        XCTAssertTrue(input.exists, "changing spaces must keep the field open")
        try save("search-selected-space")
    }

    func testEmptyAreaBelowTheListPagesFromTheCenter() throws {
        launch()
        drag(x: app.frame.width - 14, y: row.frame.midY, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" })
        let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.tab.lisbon-'")).allElementsBoundByIndex
        let bottom = tabs.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? 0
        XCTAssertGreaterThan(bottom, 0)
        let y = bottom + 35
        // Clear of the field at the foot; "newtab.capsule" also matches one at the top.
        XCTAssertLessThan(y, app.frame.height - 140, "the swipe must begin in empty space below the list")
        try save("empty-before")
        drag(x: app.frame.midX - 80, y: y, dx: 220)
        XCTAssertTrue(wait { current == "Work" }, "empty space must page from the center")
        try save("empty-after")
    }

    func testChatsPagePagesFromTheCenter() throws {
        launch()
        for _ in 0..<3 {
            if current == "Chats" { break }
            let before = current
            drag(x: 14, y: app.frame.height * 0.5, dx: 260)
            XCTAssertTrue(wait { current != before })
        }
        XCTAssertEqual(current, "Chats")
        XCTAssertTrue(node("newtab.chats").waitForExistence(timeout: 5))
        try save("chats-before")
        drag(x: app.frame.midX + 80, y: app.frame.height * 0.5, dx: -220)
        XCTAssertTrue(wait { current == "Personal" }, "Chats must page from the center")
        try save("chats-after")
    }

    func testCenterRowSwipeOpensCloseWithoutChangingSpace() throws {
        launch()
        let neighborBefore = node("newtab.tab.work-ledger").frame
        let rowBefore = row.frame
        try save("center-before")
        // The finger reaches the edge, but its center start still owns this row.
        drag(x: row.frame.midX, y: row.frame.midY, dx: -120)
        try save("center-after")
        XCTAssertEqual(current, "Work", "center row swipe must keep its Space")
        XCTAssertTrue(action("Close").waitForExistence(timeout: 3), "center row swipe must open the system's row actions")
        XCTAssertEqual(row.frame.minY, rowBefore.minY, accuracy: 0.5, "swiping must not move the row vertically")
        XCTAssertEqual(node("newtab.tab.work-ledger").frame.minY, neighborBefore.minY, accuracy: 0.5, "actions must not push neighboring rows")
        action("Close").tap()
        XCTAssertTrue(wait { !row.exists })
        XCTAssertEqual(current, "Work")
        try save("closed-row")
    }

    func testRightRowSwipeUnkeepsThenKeepsTheTab() throws {
        launch()
        drag(x: row.frame.midX, y: row.frame.midY, dx: 90)
        XCTAssertTrue(action("Unkeep").waitForExistence(timeout: 3))
        XCTAssertTrue(action("Pin").exists)
        try save("unkeep-open")
        action("Unkeep").tap()
        XCTAssertTrue(wait { row.isHittable })
        drag(x: row.frame.midX, y: row.frame.midY, dx: 90)
        XCTAssertTrue(action("Keep").waitForExistence(timeout: 3))
        action("Keep").tap()
        XCTAssertEqual(current, "Work")
        try save("kept-again")
    }

    func testRightRowSwipePinsAndTheHoldUnpins() throws {
        launch()
        drag(x: row.frame.midX, y: row.frame.midY, dx: 90)
        try save("pin-open")
        XCTAssertTrue(action("Pin").waitForExistence(timeout: 3), "row swipe must offer Pin")
        action("Pin").tap()
        // A pin is a square of the grid, held for its menu.
        let pin = node("newtab.pin.work-launch-notes")
        XCTAssertTrue(pin.waitForExistence(timeout: 4))
        XCTAssertTrue(wait { !self.row.exists })
        try save("pinned")
        pin.press(forDuration: 1)
        try save("pin-hold")
        XCTAssertTrue(app.buttons["Unpin Tab"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Launch notes'")).firstMatch.exists,
                      "the held pin must own its menu")
        app.buttons["Unpin Tab"].tap()
        try save("after-unpin")
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        XCTAssertFalse(pin.exists)
        XCTAssertTrue(node("newtab.pin.work-pin-daybook").exists)
        XCTAssertEqual(current, "Work")
        try save("unpinned")
    }

    func testBothEdgesPageEvenWhenTouchBeginsOverARow() throws {
        launch()
        let y = row.frame.midY
        drag(x: row.frame.midX, y: y, dx: -120)
        XCTAssertTrue(action("Close").waitForExistence(timeout: 3))
        try save("edges-before")
        drag(x: app.frame.width - 14, y: y, dx: -260)
        XCTAssertTrue(wait { current == "Lisbon" }, "a swipe from the right edge must page")
        try save("right-edge-next")
        drag(x: 14, y: y, dx: 260)
        XCTAssertTrue(wait { current == "Work" }, "a swipe from the left edge must page back")
        try save("left-edge-back")
        drag(x: app.frame.width - 14, y: y, dx: -8)
        XCTAssertEqual(current, "Work", "a short edge swipe returns to the same Space")
    }

    func testVerticalScrollingAndTabHoldKeepTheirBehavior() throws {
        launch()
        drag(x: row.frame.midX, y: row.frame.midY, dx: 0, dy: -120)
        XCTAssertEqual(current, "Work")
        XCTAssertFalse(action("Close").exists)
        XCTAssertFalse(action("Keep").exists)
        try save("vertical-scroll")
        // A fresh launch puts the row in its original place for the hold.
        app.terminate(); launch()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy Link"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pin Tab"].exists)
        try save("tab-hold")
    }

    func testNestedFolderRowsUseTheirOwnSwipe() throws {
        launch()
        node("newtab.folder.work-onboarding").tap()
        let nested = node("newtab.tab.work-onb-spec")
        XCTAssertTrue(nested.waitForExistence(timeout: 4))
        drag(x: nested.frame.midX, y: nested.frame.midY, dx: -120)
        XCTAssertTrue(action("Close", tab: "work-onb-spec").waitForExistence(timeout: 3))
        XCTAssertEqual(current, "Work")
        try save("nested-row")
    }
}

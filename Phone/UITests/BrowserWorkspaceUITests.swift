import XCTest

final class BrowserWorkspaceUITests: XCTestCase {
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
        app = XCUIApplication()
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready))
    }

    private func picture(_ name: String) throws {
        // app.screenshot() crops using landscape AX bounds against a portrait
        // backing image on some SDK/runtime combinations, leaving black bars.
        let image = XCUIScreen.main.screenshot()
        let folder = Atlas.out.appendingPathComponent("workspace-\(Atlas.model)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 12) == .completed
    }

    /// This exact test also runs against the unmodified shared BASE app.
    func testTabletLandscapeFillsTheWindow() throws {
        launch("page.1")
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = wait { self.app.frame.width > self.app.frame.height }
        try picture("landscape")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "the app remains in phone portrait compatibility mode")
        let page = app.webViews.firstMatch.frame
        XCTAssertGreaterThan(page.width, page.height, "the page must fill the landscape window")
        let plate = app.buttons["chrome.plate"].frame
        XCTAssertGreaterThan(plate.width, plate.height, "the address must remain horizontal")
        XCTAssertTrue(app.buttons["chrome.plus"].exists)
    }

    func testPairKeepsDraftsAndNavigationAcrossRotation() throws {
        launch("workspace.form")
        XCUIDevice.shared.orientation = .landscapeLeft
        let draft = app.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 20))
        try picture("pair-initial")
        XCTAssertEqual(app.textFields.matching(identifier: "Draft").count, 1, "only the focused document exposes form controls")
        draft.tap(); draft.typeText("Second page draft")
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        try picture("pair-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) == "Second page draft" && self.app.frame.height > self.app.frame.width })
        try picture("pair-portrait")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) == "Second page draft" && self.app.frame.width > self.app.frame.height })
        app.buttons["workspace.companion"].tap()
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) != "Second page draft" })
        draft.tap(); draft.typeText("First page draft")
        app.keyboards.buttons["Hide keyboard"].firstMatch.tapIfPresent()
        app.links["Next document"].tap()
        XCTAssertTrue(app.staticTexts["Next workspace document"].waitForExistence(timeout: 10))
        let back = app.buttons["chrome.back"]
        XCTAssertTrue(wait { back.isEnabled })
        back.tap()
        let returned = draft.waitForExistence(timeout: 10)
        try picture("pair-after-back")
        XCTAssertTrue(returned)
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) == "First page draft" })
        let stack = app.buttons["chrome.plus"]
        XCTAssertLessThan(stack.frame.maxX, app.frame.width / 2)
        let stackFrame = stack.frame
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 10))
        XCTAssertEqual(element("tabs.gallery").frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(app.buttons["tabs.settings"].frame.minX, stackFrame.minX, accuracy: 1)
        try picture("pair-left-gallery")
        app.buttons["tabs.card.workspace-primary"].tap()
        XCTAssertTrue(wait { !self.element("tabs.gallery").exists })
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "First page draft")
        app.buttons["workspace.companion"].tap()
        XCTAssertTrue(wait { draft.exists && (draft.value as? String) == "Second page draft" })
        try picture("pair-history-restored")
        app.buttons["workspace.menu"].tap()
        app.buttons["Separate Split View"].tap()
        XCTAssertTrue(wait { !self.app.buttons["workspace.companion"].exists })
        XCTAssertEqual(draft.value as? String, "Second page draft")
        try picture("full-spread")
    }

    func testSpacesSidebarAndOrdinaryPhone() throws {
        launch("page.1")
        if Atlas.model == "ipad" {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.buttons["workspace.menu"].waitForExistence(timeout: 10))
            app.buttons["workspace.menu"].tap()
            app.buttons["Show Tabs"].tap()
            XCTAssertTrue(app.buttons["field.close"].waitForExistence(timeout: 10))
            try picture("spaces-sidebar")
            let close = app.buttons["field.close"].frame
            XCTAssertLessThan(close.maxX, app.frame.width / 2)
        } else {
            XCTAssertFalse(app.buttons["workspace.menu"].exists)
            XCTAssertFalse(app.buttons["workspace.companion"].exists)
            XCTAssertTrue(app.buttons["chrome.plus"].exists)
            try picture("phone-portrait")
        }
    }

    /// The BASE contract distinguishes a committed pull's crossing tick from
    /// the button's landing tick. Exercise both with real tabs and history.
    func testOrdinaryPhoneOpenerPullAndBackButtonKeepTheirContracts() throws {
        guard Atlas.model != "ipad" else { throw XCTSkip("Ordinary iPhone regression") }
        let site = try GoingBackSite()
        let started = expectation(description: "workspace opener site ready")
        site.ready = { started.fulfill() }
        site.start()
        let profileFolder = ready.appendingPathComponent("opener-profile")
        let journal = ready.appendingPathComponent("opener-haptics.log")
        defer { site.stop() }
        wait(for: [started], timeout: 10)

        func profile() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: profileFolder.appendingPathComponent("profile.json"))) as? [String: Any])
        }
        func savedTab() -> [String: Any]? {
            guard let state = try? profile(), let spaces = state["spaces"] as? [[String: Any]] else { return nil }
            for space in spaces where state["spaceID"] == nil || space["id"] as? String == state["spaceID"] as? String {
                guard let tabs = space["today"] as? [[String: Any]], let current = space["current"] as? String else { continue }
                if let tab = tabs.first(where: { $0["id"] as? String == current }) { return tab }
            }
            return nil
        }
        func todayIDs() -> Set<String> {
            guard let state = try? profile(), let spaces = state["spaces"] as? [[String: Any]] else { return [] }
            return Set(spaces.flatMap { ($0["today"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } })
        }
        func navigation(_ id: String) -> [String]? {
            guard let stored = try? profile(), let all = stored["navigation"] as? [String: Any],
                  let state = all[id] as? [String: Any], let entries = state["entries"] as? [[String: Any]],
                  let index = state["index"] as? Int else { return nil }
            return entries.compactMap { $0["url"] as? String } + ["index=\(index)"]
        }
        func haptics() -> [String] {
            guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).dropFirst().joined() }
        }
        func follow(_ link: XCUIElement) {
            XCTAssertTrue(link.waitForExistence(timeout: 10))
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        func assertQuietClose() {
            XCTAssertFalse(app.buttons["chrome.toast.undo"].waitForExistence(timeout: 1), "a close says nothing")
            XCTAssertFalse(app.staticTexts["Closed 127.0.0.1"].exists)
        }

        let one = site.url("/one").absoluteString
        let child = site.url("/child").absoluteString
        let next = site.url("/child-next").absoluteString
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", profileFolder.path, "-YabURL", one, "-YabNoAnim", "NO"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1", "YAB_HAPTICS_JOURNAL": journal.path]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 15))
        app.passWelcome()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 6, dy: app.windows.firstMatch.frame.height * 0.2)).tap()
        XCTAssertTrue(wait { !input.exists && !self.app.alerts["welcome"].exists })
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { savedTab()?["url"] as? String == one })
        XCTAssertGreaterThan(app.frame.height, app.frame.width)
        XCTAssertFalse(app.buttons["workspace.menu"].exists)
        XCTAssertFalse(app.buttons["workspace.companion"].exists)
        let openerID = try XCTUnwrap(savedTab()?["id"] as? String)
        let originalTabs = todayIDs()
        try picture("phone-opener-portrait")

        follow(page.links["Open the child in a new tab"])
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { savedTab()?["url"] as? String == child })
        let childID = try XCTUnwrap(savedTab()?["id"] as? String)
        XCTAssertNotEqual(childID, openerID)
        XCTAssertEqual(todayIDs(), originalTabs.union([childID]))
        let back = app.buttons["chrome.back"]
        XCTAssertTrue(wait { back.isEnabled })
        follow(page.links["Next child page"])
        XCTAssertTrue(page.staticTexts["Child next"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { savedTab()?["url"] as? String == next })
        back.tap()
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { savedTab()?["id"] as? String == childID && savedTab()?["url"] as? String == child })
        XCTAssertTrue(wait { navigation(childID) == [child, next, "index=0"] })
        try picture("phone-child-history-returned")

        let beforePull = haptics().count
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: window.frame.height * 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 280, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait { savedTab()?["id"] as? String == openerID && savedTab()?["url"] as? String == one })
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { todayIDs() == originalTabs }, "only the child closes")
        XCTAssertTrue(wait { Array(haptics().dropFirst(beforePull)).contains("selection back cross") })
        let pullHaptics = Array(haptics().dropFirst(beforePull))
        XCTAssertEqual(pullHaptics, ["selection back cross"], "BASE feels the pull at its crossing, not twice")
        assertQuietClose()
        try picture("phone-opener-after-pull")

        follow(page.links["Open the child in a new tab"])
        XCTAssertTrue(page.staticTexts["Child page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { savedTab()?["url"] as? String == child })
        let again = try XCTUnwrap(savedTab()?["id"] as? String)
        XCTAssertNotEqual(again, openerID)
        XCTAssertNotEqual(again, childID)
        XCTAssertEqual(todayIDs(), originalTabs.union([again]))
        XCTAssertTrue(wait { back.isEnabled && back.isHittable })
        let beforeButton = haptics().count
        back.tap()
        XCTAssertTrue(wait { savedTab()?["id"] as? String == openerID && savedTab()?["url"] as? String == one && todayIDs() == originalTabs })
        XCTAssertTrue(page.staticTexts["Page one"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { Array(haptics().dropFirst(beforeButton)).contains("soft back to opener") })
        let buttonHaptics = Array(haptics().dropFirst(beforeButton))
        XCTAssertEqual(buttonHaptics, ["soft back to opener"], "the button has no finger crossing or extra close effect")
        assertQuietClose()
        XCTAssertFalse(back.isEnabled, "the original page has no history or opener")
        try picture("phone-opener-after-button")
        let proof: [String: Any] = ["opener": openerID, "pulledChild": childID, "buttonChild": again,
                                  "childHistory": [child, next, "index=0"], "finalTabs": Array(todayIDs()).sorted(),
                                  "pullHaptics": pullHaptics, "buttonHaptics": buttonHaptics]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
            .write(to: Atlas.out.appendingPathComponent("phone-opener-proof.json"))
        try Data(contentsOf: journal).write(to: Atlas.out.appendingPathComponent("phone-opener-haptics.log"))
    }

    func testFoldedLandscapeRailOpensTheStack() throws {
        launch("workspace.stack")
        XCUIDevice.shared.orientation = .landscapeLeft
        let stack = app.buttons["chrome.plus"]
        XCTAssertTrue(wait { self.app.frame.width > self.app.frame.height && stack.exists && stack.isHittable })
        try picture("folded-rail")
        stack.tap()
        XCTAssertTrue(element("tabs.gallery").waitForExistence(timeout: 10))
        try picture("folded-stack")
    }

    func testOpenBesideUsesTheExistingSpacesScreen() throws {
        launch("page.1")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["workspace.menu"].waitForExistence(timeout: 10))
        app.buttons["workspace.menu"].tap()
        app.buttons["Split View"].tap()
        let close = app.buttons["field.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        try picture("beside-new-tab")
        let row = element("newtab.tab.work-hn")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(wait { !close.exists && self.app.buttons["workspace.companion"].exists })
        try picture("beside-selected")
        app.buttons["workspace.menu"].tap()
        app.buttons["Close Split"].tap()
        XCTAssertTrue(wait { !self.app.buttons["workspace.companion"].exists })
        XCTAssertTrue(app.buttons["chrome.plate"].exists)
    }

    func testAnswerUsesABoundedTrailingColumn() throws {
        launch("chat.1")
        XCUIDevice.shared.orientation = .landscapeLeft
        let sheet = element("chat.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        print("answer AX frame=\(sheet.frame), window=\(app.frame)")
        try picture("answer-column")
        XCTAssertLessThanOrEqual(sheet.frame.width, 360)
        XCTAssertGreaterThan(sheet.frame.minX, app.frame.width / 2)
        XCTAssertLessThan(element("chat.answerHead").frame.minY, app.frame.height / 2)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
}

private extension XCUIElement {
    func tapIfPresent() { if exists && isHittable { tap() } }
}

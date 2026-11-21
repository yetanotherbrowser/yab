import XCTest

/// Joining sync on the iPhone, with the finger: no key anywhere, so the
/// sheet shows a code for the Mac; "Use the Recovery Key" swaps in the one
/// field; a wrong key is said under it (and felt); the right one lets the
/// iPhone in and the sheet goes (felt as done). Turned away, "Join Again"
/// brings a code back. ✕, the dimmed page and a pull on its head put the
/// sheet away, and it comes back with Yab while this iPhone isn't in.
///
/// The server is out of reach on purpose (port 9): joining by the Recovery
/// Key needs none, and nothing here may reach a real account.
final class SyncTests: XCTestCase {
    /// A key made for the tests, nobody's: bytes 1...32 and its check group.
    private let recoveryKey = "AEBA-GBAF-AYDQ-QCIK-BMGA-2DQP-CAIR-EEYU-CULB-OGAZ-DINR-YHI6-D4QK-4II"
    private var journal: URL!

    override func setUp() {
        continueAfterFailure = false
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("yab-haptics-\(UUID().uuidString.prefix(8)).log")
    }

    private func launch(_ extra: [String] = [], world: String = "mira") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", world, "-YabSync", "http://127.0.0.1:9", "-YabSyncFresh", "1"] + extra
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launch()
        return app
    }

    /// The haptics played since launch: "<kind> <reason>" each.
    private func haptics() -> [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in line.split(separator: " ", maxSplits: 1).dropFirst().joined() }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    func testJoiningWithTheRecoveryKey() {
        let app = launch()
        let sheet = element(app, "join.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "no key: the join sheet comes up")
        let code = element(app, "join.code")
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertTrue(code.label.range(of: #"^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$"#, options: .regularExpression) != nil,
                      "a code of the Mac's alphabet: \(code.label)")
        XCTAssertTrue(app.staticTexts["On your Mac, open Settings › Sync and choose Add a Device, then type this code there."].exists)

        // The other way in: the one field.
        element(app, "join.recovery").tap()
        let field = element(app, "join.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(gone(code), "the code makes room for the field")
        field.tap()
        field.typeText("ABCD-EFGH-JKMN")
        element(app, "join.go").tap()
        let wrong = app.staticTexts["That isn't a Recovery Key. Check each group of four."]
        XCTAssertTrue(wrong.waitForExistence(timeout: 5), "a wrong key is said under the field")
        XCTAssertEqual(haptics().last, "error wrong key")

        // The right one: in, the sheet goes, and it is felt.
        field.tap()
        field.clearAndType(recoveryKey)
        element(app, "join.go").tap()
        XCTAssertTrue(gone(sheet), "joined: the sheet goes")
        XCTAssertEqual(haptics().suffix(2), ["error wrong key", "success joined"])
    }

    func testBackToTheCodeAndAway() {
        let app = launch()
        let sheet = element(app, "join.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let code = element(app, "join.code").label
        element(app, "join.recovery").tap()
        XCTAssertTrue(element(app, "join.field").waitForExistence(timeout: 5))
        element(app, "join.back").tap()
        let again = element(app, "join.code")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.label, code, "the same code: it works for ten minutes")
        let close = element(app, "join.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "✕ in the sheet's head: \(app.debugDescription)")
        close.tap()
        XCTAssertTrue(gone(sheet), "✕ puts the sheet away")
        XCTAssertTrue(element(app, "chrome.plate").exists, "the page and its plate are there")
        XCTAssertTrue(haptics().isEmpty, "nothing to feel on the way: \(haptics())")

        // Joining waits, it isn't gone: back in Yab, the sheet is there again.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the sheet comes back with Yab")
        XCTAssertEqual(element(app, "join.code").label, code, "with the same code")
    }

    func testPulledDownTheSheetGoes() {
        let app = launch()
        let sheet = element(app, "join.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        // A short pull springs back.
        let top = sheet.frame.minY
        let head = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        // Slowly, and held at the end: no flick.
        head.press(forDuration: 0.05, thenDragTo: head.withOffset(CGVector(dx: 0, dy: 60)), withVelocity: .slow, thenHoldForDuration: 0.3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(sheet.exists, "a short pull springs back")
        XCTAssertEqual(sheet.frame.minY, top, accuracy: 2, "back in place")
        // A long one puts it away.
        head.press(forDuration: 0.05, thenDragTo: head.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertTrue(gone(sheet), "pulled down past 120 pt, the sheet goes")
    }

    func testTheRecoveryKeyIsSeenWholeAndTypedAtOnce() {
        let app = launch()
        XCTAssertTrue(element(app, "join.sheet").waitForExistence(timeout: 15))
        element(app, "join.recovery").tap()
        let field = element(app, "join.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The keyboard is the field's the moment it is there: typing needs no tap.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5) || field.hasFocus, "the field takes the keyboard")
        field.typeText(recoveryKey)
        let height = field.frame.height
        XCTAssertGreaterThan(height, 60, "the field grows to show the whole key: \(field.frame)")
        XCTAssertEqual(field.value as? String, recoveryKey)
    }

    /// No key and no Mac: the first run asks, not Settings' sheet, and after
    /// No Mac yet › Use Without a Mac nothing asks to join on its own.
    func testWithoutAMacNothingAsksToJoin() {
        let app = launch(world: "empty")
        XCTAssertTrue(element(app, "welcome").waitForExistence(timeout: 15), "no first run")
        XCTAssertFalse(element(app, "join.sheet").exists, "Settings' sheet over the first run")
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "no New Tab after Use Without a Mac")
        XCTAssertFalse(element(app, "join.sheet").waitForExistence(timeout: 4), "the join sheet came up by itself")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertFalse(element(app, "join.sheet").waitForExistence(timeout: 4), "the join sheet came back with Yab")
    }

    func testTurnedAwayJoinsAgain() {
        let app = launch(["-YabState", "join.5", "-YabNoAnim", "YES"])
        let words = element(app, "join.words")
        XCTAssertTrue(words.waitForExistence(timeout: 15))
        XCTAssertEqual(words.label, "This \(Atlas.deviceWord) was removed from Sync.")
        element(app, "join.again").tap()
        XCTAssertTrue(element(app, "join.code").waitForExistence(timeout: 5), "joining again starts with a new code")
    }
}

private extension XCUIElement {
    /// Replaces what a text field holds.
    func clearAndType(_ text: String) {
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}

import XCTest

final class DuoRotationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ready: URL!
    private var site: GoingBackSite!

    override func setUpWithError() throws {
        continueAfterFailure = false
        ready = Atlas.readyFolder()
        XCUIDevice.shared.orientation = .portrait
        site = try GoingBackSite()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "duo-ruler", withExtension: "html"))
        let html = try String(contentsOf: fixture, encoding: .utf8)
        site.responseBody = { _ in html }
        let started = expectation(description: "local Duo ruler ready")
        site.ready = { started.fulfill() }
        site.start()
        wait(for: [started], timeout: 10)
    }

    override func tearDown() {
        app?.terminate()
        site?.stop()
        XCUIDevice.shared.orientation = .portrait
        try? FileManager.default.removeItem(at: ready)
    }

    private func wait(_ predicate: @escaping () -> Bool) -> Bool {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [e], timeout: 15) == .completed
    }

    private func launch(_ side: String) {
        let marker = ready.appendingPathComponent("duo-retirement.json")
        try? FileManager.default.removeItem(at: marker)
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", ready.appendingPathComponent("profile-" + side).path,
                               "-YabState", "duo.rotation." + side, "-YabLiveState", "YES",
                               "-YabURL", site.url("/duo-ruler").absoluteString,
                               "-YabNoAnim", "YES", "-YabPrivateLockTestAuthentication", "off"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1", "YAB_READY_DIR": ready.path]
        app.launch()
        app.passWelcome(timeout: 15)
        if app.textFields["field.input"].waitForExistence(timeout: 2) { app.closeField() }
        XCTAssertTrue(app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Layout width '")).firstMatch.waitForExistence(timeout: 45))
        XCTAssertTrue(Atlas.waitForFile(marker, timeout: 30))
    }

    private func retirement() -> [String: Any] {
        guard let data = try? Data(contentsOf: ready.appendingPathComponent("duo-retirement.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return record
    }

    private func record(_ name: String) {
        Atlas.write(XCUIScreen.main.screenshot().pngRepresentation, to: "duo-rotation/\(name).png")
        Atlas.write(Data(app.debugDescription.utf8), to: "duo-rotation/\(name).txt")
        if let data = try? Data(contentsOf: ready.appendingPathComponent("duo-retirement.json")) {
            Atlas.write(data, to: "duo-rotation/\(name).retirement.json")
        }
    }

    func testLoadedPageFillsTheWindowAcrossRotation() {
        for side in ["right", "left"] {
            launch(side)
            var previous = UIDeviceOrientation.portrait
            for (step, orientation) in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait, .landscapeRight].enumerated() {
                let page = app.webViews.firstMatch
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
                XCTAssertTrue(wait { self.app.buttons["chrome.plate"].value as? String == "folded" })
                let sequence = retirement()["sequence"] as? Int ?? 0
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation.isLandscape
                XCTAssertTrue(wait { (self.app.frame.width > self.app.frame.height) == landscape })
                if orientation != previous {
                    XCTAssertTrue(wait { (self.retirement()["sequence"] as? Int ?? 0) > sequence })
                }
                previous = orientation
                let phase = "\(side)-\(step)-\(orientation.rawValue)"
                record(phase)
                let measured = retirement()
                XCTAssertEqual(measured["viewWidth"] as? Double ?? 0, Double(app.frame.width), accuracy: 1,
                               "the retiring portrait host resized the mounted landscape page")
                XCTAssertEqual(measured["viewHeight"] as? Double ?? 0, Double(app.frame.height), accuracy: 1)
                XCTAssertEqual(measured["viewX"] as? Double ?? -1, 0, accuracy: 1)
                XCTAssertTrue(measured["liveProfile"] as? Bool == true)
                let left = measured["columnLeft"] as? Bool == true
                // The page lays out beside the column (#989); the scroll bar
                // stands beside it too, counted once (#1945).
                XCTAssertEqual(measured["leftInset"] as? Double ?? -1, left ? 84 : 0, accuracy: 1)
                XCTAssertEqual(measured["rightInset"] as? Double ?? -1, left ? 0 : 84, accuracy: 1)
                XCTAssertEqual(measured["leftIndicator"] as? Double ?? -1, left ? 84 : 0, accuracy: 1)
                XCTAssertEqual(measured["rightIndicator"] as? Double ?? -1, left ? 0 : 84, accuracy: 1)
                XCTAssertTrue(measured["indicatorsAdjusted"] as? Bool == false)
                let web = app.webViews.firstMatch
                let report = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Layout width '")).firstMatch
                let expected = app.frame.width - 84
                XCTAssertTrue(wait {
                    let width = CGFloat(Double(report.label.replacingOccurrences(of: "Layout width ", with: "")) ?? 0)
                    return abs(width - expected) <= 1
                }, "WebKit layout width must equal the window's width beside the column: \(report.label), expected \(expected)")
                record(phase)
                if landscape {
                    app.buttons["chrome.plus"].tap()
                    let card = app.buttons["tabs.card.duo-ruler"]
                    XCTAssertTrue(card.waitForExistence(timeout: 10))
                    card.tap()
                    XCTAssertTrue(wait { !card.exists && self.app.webViews.firstMatch.exists })
                    XCTAssertTrue(wait {
                        let value = self.app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Layout width '")).firstMatch.label
                        return abs((Double(value.replacingOccurrences(of: "Layout width ", with: "")) ?? 0) - Double(expected)) <= 1
                    })
                    record(phase + "-stack-return")
                }
            }
            app.terminate()
        }
    }

    func testBottomEdgeUnfoldsAcrossTheSafeWidth() {
        for side in ["right", "left"] {
            launch(side)
            let plate = app.buttons["chrome.plate"]
            for orientation in [UIDeviceOrientation.portrait, .landscapeRight, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                XCTAssertTrue(wait { (self.app.frame.width > self.app.frame.height) == orientation.isLandscape })
                // Device and interface landscape orientations use opposite
                // names. Read the actual column from its retained rail.
                let left = app.buttons["chrome.back"].frame.midX < app.frame.midX
                for fraction in [0.15, 0.5, 0.85] {
                    let window = app.windows.firstMatch
                    let origin = window.coordinate(withNormalizedOffset: .zero)
                    let width = window.frame.width - 84
                    let x = (left ? 84 : 0) + width * fraction
                    let middle = width / 2 + (left ? 84 : 0)
                    origin.withOffset(CGVector(dx: middle, dy: window.frame.height * 0.7))
                        .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: middle, dy: window.frame.height * 0.3)))
                    XCTAssertTrue(wait { plate.value as? String == "folded" })
                    let start = origin.withOffset(CGVector(dx: x, dy: window.frame.height - 40))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
                    record("\(side)-\(orientation.rawValue)-bottom-\(fraction)")
                    XCTAssertTrue(wait { plate.value as? String == "open" }, "bottom edge at \(fraction) must unfold the plate")
                }
            }
            app.terminate()
        }
    }
}

import Network
import UIKit
import XCTest

/// Real browser and animations, with an explicit isolated DEBUG auth seam.
/// These prove the gate and its content boundaries, not Face ID hardware.
final class PrivateLockUITests: XCTestCase {
    private var site: PrivateLockSite!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-private-lock-\(UUID().uuidString)")
        site = try PrivateLockSite()
        let ready = expectation(description: "owned private-lock site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testBackgroundRelocksTheCurrentPrivateTabAndCancelNeverRevealsItsKeyboardOrPage() throws {
        let app = launch(results: "allow,cancel,allow")
        openSecret(app)
        openAddress(app)
        let input = app.textFields["field.input"]
        input.typeText("private draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        save(app, "Private field before background")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["private.unlock"].waitForExistence(timeout: 10))
        assertNoSecret(app)
        XCTAssertFalse(input.exists, "a retained private draft must not appear before authentication")
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists }, "the system keyboard must resign on background")
        save(app, "Returned Private is locked without page or keyboard")
        app.buttons["private.unlock"].tap()
        XCTAssertTrue(wait { app.staticTexts["Private is still locked."].exists })
        assertNoSecret(app)
        XCTAssertFalse(input.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["private.unlock"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "private draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        save(app, "Authenticated return restores only the retained Private draft")
        closeField(app)
        XCTAssertTrue(app.webViews.staticTexts["Secret fixture document"].waitForExistence(timeout: 5))
        XCTAssertEqual(site.secretLoads, 1)
        try assertPrivateNeverPersisted()
    }

    /// iPad: Save as PDF from Site Controls on a private page, then Yab
    /// goes Home with Open with Face ID. Back, Private is locked, and no
    /// share sheet with the private PDF stands over the lock.
    func testAPrivatePagesPDFSheetGoesWhenPrivateLocksOnHome() throws {
        let app = launch(results: "allow,allow")
        guard app.buttons["tablet.siteControls"].exists else { throw XCTSkip("Save as PDF is in the iPad's Site Controls") }
        openSecretOnTablet(app)
        app.buttons["tablet.siteControls"].tap()
        let more = element(app, "site.more")
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        let saveAsPDF = app.buttons["Save as PDF"]
        XCTAssertTrue(saveAsPDF.waitForExistence(timeout: 8))
        saveAsPDF.tap()
        let sheet = app.otherElements["ActivityListView"]
        let shown = { sheet.exists || app.collectionViews["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists }
        XCTAssertTrue(wait(shown), "the share sheet with the private PDF")
        save(app, "Private PDF in the share sheet")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["private.unlock"].waitForExistence(timeout: 10))
        save(app, "Back: Private is locked, no share sheet")
        XCTAssertFalse(shown(), "the share sheet stood over the lock")
        assertNoSecret(app)
        app.buttons["private.unlock"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Secret fixture document"].waitForExistence(timeout: 10))
        XCTAssertFalse(shown(), "unlocked, the sheet doesn't come back")
    }

    private func openSecretOnTablet(_ app: XCUIApplication) {
        let newTab = app.buttons["tablet.newTab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.tap()
        let eyes = element(app, "field.eyes")
        XCTAssertTrue(eyes.waitForExistence(timeout: 5))
        eyes.tap()
        XCTAssertEqual(eyes.value as? String, "on")
        if app.buttons["private.unlock"].waitForExistence(timeout: 3) { app.buttons["private.unlock"].tap() }
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(site.url.appendingPathComponent("secret").absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Secret fixture document"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { !input.exists })
    }

    private func launch(results: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url.appendingPathComponent("public").absoluteString,
                               "-YabPrivateLockTestAuthentication", results]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.skip"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        closeField(app)
        XCTAssertTrue(app.webViews.staticTexts["Public fixture page"].waitForExistence(timeout: 15))
        return app
    }

    private func openSecret(_ app: XCUIApplication) {
        let plus = app.buttons["chrome.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        let eyes = element(app, "field.eyes")
        XCTAssertTrue(eyes.waitForExistence(timeout: 5))
        eyes.tap()
        // The eyes open Private at once (efa361a2): the field stays, and the
        // private tabs wait under the lock in its room until Unlock.
        XCTAssertTrue(app.buttons["private.unlock"].waitForExistence(timeout: 5))
        XCTAssertEqual(eyes.value as? String, "on")
        app.buttons["private.unlock"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(site.url.appendingPathComponent("secret").absoluteString)
        let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@", "go")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        go.tap()
        XCTAssertTrue(app.webViews.staticTexts["Secret fixture document"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { !input.exists })
    }

    private func openAddress(_ app: XCUIApplication) {
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        let frame = plate.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
    }

    private func closeField(_ app: XCUIApplication) {
        XCTAssertTrue(app.closeField(), "the field stayed over the page")
    }

    private func assertNoSecret(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.webViews.staticTexts["Secret fixture document"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Secret fixture document"].exists, file: file, line: line)
        XCTAssertFalse(app.webViews.buttons["Private page action"].exists, file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "/secret")).firstMatch.exists,
                       "no private URL in the foreground AX tree", file: file, line: line)
    }

    private func assertPrivateNeverPersisted() throws {
        XCTAssertTrue(wait { FileManager.default.fileExists(atPath: folder.appendingPathComponent("profile.json").path) })
        let profile = try String(contentsOf: folder.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(profile.contains("/secret"))
        XCTAssertFalse(profile.contains("Secret fixture document"))
        XCTAssertFalse(profile.contains("private draft"))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        TransitionCatalog.wait(10, condition)
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + " AX"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
    }
}

private final class PrivateLockSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.private-lock-test-site")
    private var loads = 0
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    var secretLoads: Int { queue.sync { loads } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var requestData = data
            if let chunk { requestData.append(chunk) }
            guard requestData.count <= 65_536 else { connection.cancel(); return }
            guard requestData.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() }
                else { self.receive(connection, data: requestData) }
                return
            }
            let request = String(decoding: requestData, as: UTF8.self)
            let secret = request.hasPrefix("GET /secret ")
            if secret { self.loads += 1 }
            let title = secret ? "Secret fixture document" : "Public fixture page"
            let action = secret ? "<button onclick=\"document.getElementById('receipt').textContent='Private action '+(++window.actions)\">Private page action</button><p id=receipt></p><script>window.actions=0</script>" : ""
            let html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><link rel=icon href=data:,><title>\(title)</title><style>body{font:20px system-ui;padding:80px 20px}button{font:18px system-ui;padding:14px}</style><h1>\(title)</h1>\(action)"
            let bytes = Data(html.utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + bytes, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in if error != nil { connection.cancel() } })
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            for connection in connections { connection.cancel() }
            connections = []
        }
    }
}

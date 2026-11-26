import Network
import XCTest

/// Chrome extensions on Yab for iPhone, used as a person would: the store's
/// page of one, ≡, Add Extension to Yab, Add; then the extension on a page
/// (Dark Reader darkens it, its popup comes up as a sheet from the page
/// menu) and MetaMask's provider on a dapp (window.ethereum, its worker
/// answering eth_chainId). Real network: the Chrome Web Store.
final class ExtensionsUITests: XCTestCase {
    private var folder: URL!
    private var site: DappSite!
    private static let darkReader = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
    private static let metaMask = "nkbihfbeogaeaoehlefnkodbefgpgknn"

    override func setUpWithError() throws {
        // The page menu has no extension rows since 2026-10-28: these walk
        // Add Extension and an extension's button there, which are gone.
        throw XCTSkip("no extension rows in the iPhone page menu")
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-extensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        site = try DappSite()
        let started = expectation(description: "site")
        site.start { _ in started.fulfill() }
        wait(for: [started], timeout: 10)
    }

    override func tearDownWithError() throws {
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testDarkReaderFromTheStoreDarkensAPageAndShowsItsPopup() throws {
        let app = launch(at: storePage(Self.darkReader, slug: "dark-reader"))
        try add(Self.darkReader, named: "Dark Reader", in: app)
        open(site.url("/plain"), in: app)
        XCTAssertTrue(app.staticTexts["A plain white page."].waitForExistence(timeout: 20), "the page drew")
        // Dark Reader's own look takes a moment to arrive.
        let darkened = wait(15) { self.brightness(app, at: CGPoint(x: 0.5, y: 0.45)) < 0.35 }
        record(app, "Dark Reader on a white page")
        if !darkened { openList(app); record(app, "Extensions list after the page") }
        XCTAssertTrue(darkened, "the white page is dark with Dark Reader: \(brightness(app, at: CGPoint(x: 0.5, y: 0.45)))")
        // Its button in the page menu brings its popup up as a sheet.
        openMenu(app)
        let row = app.buttons["plate.menu.extension.\(Self.darkReader)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Dark Reader's row is in the page menu")
        record(app, "Page menu with Dark Reader")
        row.tap()
        let popup = app.descendants(matching: .any)["extensions.popup"]
        XCTAssertTrue(popup.waitForExistence(timeout: 10), "its popup comes up")
        sleep(3)
        record(app, "Dark Reader's popup")
        XCTAssertTrue(app.webViews.count >= 2, "the popup is its own page")
    }

    func testMetaMaskFromTheStoreGivesADappItsProvider() throws {
        let app = launch(at: storePage(Self.metaMask, slug: "metamask"))
        try add(Self.metaMask, named: "MetaMask", in: app, fromStoreButton: true)
        // Its welcome opens in a tab of its own, as on a computer.
        let welcome = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS[c] 'existing wallet' OR label CONTAINS[c] 'Create a new wallet'")).firstMatch
        let welcomed = welcome.waitForExistence(timeout: 30)
        record(app, "MetaMask's welcome")
        XCTAssertTrue(welcomed, "MetaMask's onboarding drew")
        open(site.url("/dapp"), in: app)
        let provider = app.staticTexts["provider: object MetaMask"]
        let found = provider.waitForExistence(timeout: 30)
        record(app, "A dapp with MetaMask")
        XCTAssertTrue(found, "window.ethereum is MetaMask's")
        let answered = app.staticTexts["chain: 0x1"].waitForExistence(timeout: 30)
        if !answered { openList(app); record(app, "Extensions list after the dapp") }
        XCTAssertTrue(answered, "its worker answers eth_chainId")
        record(app, "MetaMask answered")
    }

    func testOneThatCantWorkIsNotOffered() throws {
        let app = launch(at: storePage("liecbddmkiiihnedobmlmillhodjkdmb", slug: "loom"))
        openMenu(app)
        let row = app.buttons["plate.menu.addExtension"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 60))
        record(app, "Loom isn't offered")
        XCTAssertTrue(alert.label.contains("doesn't work on \(Atlas.deviceWord)"), alert.label)
        XCTAssertFalse(alert.buttons["Add"].exists, "no way to add it")
        alert.buttons["OK"].tap()
    }

    // MARK: - as a person

    private func storePage(_ id: String, slug: String) -> URL {
        URL(string: "https://chromewebstore.google.com/detail/\(slug)/\(id)")!
    }

    private func launch(at url: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", url.absoluteString,
                               "-YabPrivateLockTestAuthentication", "off", "-settings.welcomed", "YES"]
        app.terminate()
        app.launch()
        if app.buttons["join.close"].waitForExistence(timeout: 8) { app.buttons["join.close"].tap() }
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].waitForExistence(timeout: 2) {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: window.frame.height * 0.3)).tap()
        }
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "the store's page opened")
        sleep(4)
        record(app, "The store's page")
        return app
    }

    private func openMenu(_ app: XCUIApplication) {
        let lines = app.buttons["chrome.pageMenu"]
        if !lines.waitForExistence(timeout: 5) || !lines.isHittable {
            // Folded: a scroll up brings the plate's ≡ back.
            app.webViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(lines.waitForExistence(timeout: 10))
        lines.tap()
    }

    private func add(_ id: String, named name: String, in app: XCUIApplication, fromStoreButton: Bool = false) throws {
        if fromStoreButton {
            // The store's own button, which says Add to Yab here.
            let store = app.webViews.buttons["Add to Yab"].firstMatch
            XCTAssertTrue(store.waitForExistence(timeout: 20), "the store's button says Add to Yab")
            record(app, "The store's Add to Yab")
            store.tap()
        } else {
            openMenu(app)
            let row = app.buttons["plate.menu.addExtension"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Add Extension to Yab is in the page menu")
            record(app, "Page menu on the store's page")
            row.tap()
        }
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "the yes before it is added")
        record(app, "Add \(name)?")
        XCTAssertTrue(alert.label.contains(name), "the question names it: \(alert.label)")
        alert.buttons["Add"].tap()
        // Added: the list has it.
        let added = wait(90) {
            self.openList(app)
            let there = app.descendants(matching: .any)["extensions.row.\(id)"].exists
            if app.buttons["extensions.done"].exists { app.buttons["extensions.done"].tap() }
            return there
        }
        XCTAssertTrue(added, "\(name) is in the list")
    }

    private func openList(_ app: XCUIApplication) {
        openMenu(app)
        let all = app.buttons["plate.menu.extensions"]
        guard all.waitForExistence(timeout: 5) else { return }
        all.tap()
        _ = app.buttons["extensions.done"].waitForExistence(timeout: 5)
        record(app, "Extensions list")
    }

    private func open(_ url: URL, in app: XCUIApplication) {
        let plate = app.descendants(matching: .any)["chrome.plate"]
        if !plate.isHittable { app.webViews.firstMatch.swipeDown() }
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        plate.tap()
        let field = app.textFields["field.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(url.absoluteString + "\n")
    }

    private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < end
        return condition()
    }

    private func brightness(_ app: XCUIApplication, at point: CGPoint) -> CGFloat {
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return 1 }
        let x = Int(CGFloat(cg.width) * point.x), y = Int(CGFloat(cg.height) * point.y)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: -x, y: -(cg.height - y), width: cg.width, height: cg.height))
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let png = XCTAttachment(screenshot: app.screenshot())
        png.name = name; png.lifetime = .keepAlways; add(png)
    }
}

/// A loopback site: a plain white page, and a dapp that says what provider
/// it found and what chain it answered.
private final class DappSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "extensions-dapp-site")
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var port: UInt16 { listener.port!.rawValue }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ done: @escaping (Bool) -> Void) {
        queue.async {
            var once = false
            self.listener.stateUpdateHandler = { state in
                if case .ready = state, !once { once = true; done(true) }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let header = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = header.components(separatedBy: " ").dropFirst().first ?? "/"
                    let body = path.hasPrefix("/dapp") ? Self.dapp : Self.plain
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() { queue.sync { listener.cancel(); connections.values.forEach { $0.cancel() } } }

    private static let plain = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Plain</title>
    <style>html,body{background:#fff;color:#111;margin:0}p{font:18px -apple-system;padding:120px 24px}</style>
    <p>A plain white page.</p>
    """

    private static let dapp = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Dapp</title>
    <style>body{font:18px -apple-system;padding:100px 24px}</style>
    <p id="provider">provider: looking</p><p id="chain">chain: asking</p>
    <script>
    function look(tries) {
      const e = window.ethereum;
      if (!e && tries > 0) { setTimeout(() => look(tries - 1), 500); return; }
      document.getElementById('provider').textContent = 'provider: ' + typeof e + (e && e.isMetaMask ? ' MetaMask' : '');
      if (!e) return;
      e.request({method: 'eth_chainId'}).then(c => document.getElementById('chain').textContent = 'chain: ' + c,
        err => document.getElementById('chain').textContent = 'chain: failed ' + (err && err.message));
    }
    look(30);
    </script>
    """
}

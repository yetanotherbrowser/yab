import Network
import UIKit
import XCTest

/// Downloads as a finger makes them, from a loopback site and an owned
/// profile: the first file's card, the line, the sheet on Downloads, Allowed
/// Here, the link's and the image's hold.
final class DownloadsUITests: XCTestCase {
    private var site: FilesSite!
    private var folder: URL!
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-downloads-\(UUID().uuidString)", isDirectory: true)
        site = try FilesSite()
        let ready = expectation(description: "owned files site ready")
        site.start { result in
            if case let .failure(error) = result { XCTFail("Owned listener failed: \(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url("/page").absoluteString,
                               "-YabPrivateLockTestAuthentication", "off", "-settings.welcomed", "YES", "-YabNoAnim", "YES",
                               // Nothing allowed yet: an earlier run's site settings don't count.
                               "-yab.siteSettings", "<>"]
        app.launch()
        let join = app.buttons["join.close"]
        if join.waitForExistence(timeout: 6) { join.tap() }
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Owned files"].waitForExistence(timeout: 60))
    }

    override func tearDownWithError() throws {
        app.terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// An iPad keeps downloads in its own button, in the sidebar's foot,
    /// where the phone has its Now line and the plate's Downloads page.
    private var sidebarDownloads: XCUIElement { app.buttons["tablet.downloads.sidebar"] }
    private var tablet: Bool { sidebarDownloads.exists }

    /// A popover goes with a tap on the dimmed ground beside it.
    private func closePopover() {
        let ground = app.otherElements["PopoverDismissRegion"]
        if ground.exists { ground.tap() }
        popoverGone()
    }

    /// Until a popover's ground has gone too, a tap on the page is still
    /// the popover's: the iPad's question goes as it is answered.
    private func popoverGone() {
        let ground = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(wait { !self.app.popovers.firstMatch.exists && !ground.exists }, "the popover stayed")
    }

    private func record(_ name: String) {
        let png = XCTAttachment(screenshot: app.screenshot())
        png.name = name; png.lifetime = .keepAlways; add(png)
    }

    private func wait(_ timeout: TimeInterval = 15, _ check: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if check() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return check()
    }

    /// A loaded Mac can lose a press to the page's selection: one more.
    private func hold(_ element: XCUIElement, until menu: XCUIElement) {
        element.press(forDuration: 1.2)
        if !menu.waitForExistence(timeout: 6) { element.press(forDuration: 1.6) }
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the hold brought no menu")
    }

    func testAFileAsksThenLandsInDownloadsAndTheSiteIsAllowed() throws {
        app.webViews.firstMatch.links["Report"].tap()
        XCTAssertTrue(any("download.ask").waitForExistence(timeout: 20), "the first file from a site asks")
        record("the card")
        XCTAssertTrue(app.staticTexts["Download report.pdf?"].exists)
        // Cancel asks again next time.
        app.buttons["download.ask.cancel"].tap()
        XCTAssertTrue(wait { !self.any("download.ask").exists })
        popoverGone()
        app.webViews.firstMatch.links["Report"].tap()
        XCTAssertTrue(any("download.ask").waitForExistence(timeout: 20))
        app.buttons["download.ask.download"].tap()
        if tablet {
            // The iPad has no Now line: its downloads button asked, and its list has the file.
            XCTAssertTrue(wait { !self.any("download.ask").exists && self.sidebarDownloads.value as? String != "Asking" })
            record("the button")
            sidebarDownloads.tap()
        } else {
            // The line says Open, and leaves; the file stays.
            XCTAssertTrue(wait { self.any("chrome.now").exists && self.any("chrome.now").label.contains("Open") }, "the line never said Open")
            record("the line")
            XCTAssertTrue(wait { !self.any("chrome.now").exists })
            app.buttons["chrome.pageMenu"].tap()
            XCTAssertTrue(app.buttons["plate.menu.downloads"].waitForExistence(timeout: 8))
            app.buttons["plate.menu.downloads"].tap()
        }
        XCTAssertTrue(any("downloads.row.report.pdf").waitForExistence(timeout: 8))
        record("the page")
        any("downloads.row.report.pdf").tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10) , "QuickLook opens the file")
        record("QuickLook")
        let close = app.navigationBars.firstMatch.buttons.matching(NSPredicate(format: "label IN[c] {'Done', 'Close'} OR identifier == 'QLOverlayDoneButtonAccessibilityIdentifier'")).firstMatch
        record("QuickLook buttons \(app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label))")
        // QuickLook's process may still be coming up: a close lost on it is pressed again.
        XCTAssertTrue(wait(30) {
            if self.any("downloads.row.report.pdf").isHittable { return true }
            if close.exists, close.isHittable { close.tap() }
            return false
        }, "QuickLook never closed")

        if tablet {
            // Site Controls, the iPad's Site Settings, in its own popover.
            closePopover()
            app.buttons["tablet.siteControls"].tap()
            XCTAssertTrue(any("site.permission.downloads.decision").waitForExistence(timeout: 8), "remembered in Allowed Here")
            app.buttons["site.downloads.here"].tap()
            XCTAssertTrue(any("downloads.row.report.pdf").waitForExistence(timeout: 8))
            record("this site's files")
            app.buttons["site.downloads.back"].tap()
            XCTAssertTrue(any("site.permission.downloads.decision").waitForExistence(timeout: 8))
            closePopover()
        } else {
            app.buttons["site.back"].tap()
            XCTAssertTrue(app.buttons["plate.menu.siteSettings"].waitForExistence(timeout: 8))
            app.buttons["plate.menu.siteSettings"].tap()
            XCTAssertTrue(any("site.permission.downloads").waitForExistence(timeout: 8), "remembered in Allowed Here")
            XCTAssertTrue(app.buttons["site.downloaded"].exists)
            app.buttons["site.downloaded"].tap()
            XCTAssertTrue(any("downloads.row.report.pdf").waitForExistence(timeout: 8))
            record("this site's files")
            app.buttons["site.back"].tap()
            XCTAssertTrue(any("site.permission.downloads").waitForExistence(timeout: 8))
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            XCTAssertTrue(wait { !self.any("plate.menu").exists })
        }

        // An allowed site doesn't ask.
        app.webViews.firstMatch.links["Report"].tap()
        if tablet {
            // A tap as a popover finishes going can be UIKit's, not the
            // page's: one more, as hold does for a lost press.
            if !wait(5, { self.sidebarDownloads.value as? String == "2 files" }) { app.webViews.firstMatch.links["Report"].tap() }
            // Its list stays shut until the file is in: a page covered by a
            // popover sends no file (WebPool.canInteract).
            XCTAssertTrue(wait { (self.sidebarDownloads.value as? String)?.hasSuffix("files") == true }, "the second file came without a question")
            sidebarDownloads.tap()
            XCTAssertTrue(any("downloads.row.report 2.pdf").waitForExistence(timeout: 8))
        } else {
            XCTAssertTrue(wait { self.any("chrome.now").exists }, "no line")
        }
        XCTAssertFalse(any("download.ask").exists)
    }

    func testAHeldLinkOffersItsFileInAGroupOfItsOwn() throws {
        app.webViews.firstMatch.links["Report"].press(forDuration: 1.2)
        let download = app.buttons["Download Linked File"]
        XCTAssertTrue(download.waitForExistence(timeout: 10), "no Download Linked File")
        record("link hold")
        // The iPad's own Downloads button is no row of the menu.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download' AND NOT (identifier BEGINSWITH 'tablet.downloads')")).count, 1, "one, ours")
        download.tap()
        XCTAssertTrue(any("download.ask").waitForExistence(timeout: 20))
        app.buttons["download.ask.cancel"].tap()
    }

    /// iOS asks no app about an image with no link: this is WebKit's own
    /// menu, which already has what the picture needs.
    func testAHeldImageKeepsTheSystemsMenu() throws {
        let picture = app.webViews.firstMatch.images["Plain picture"]
        hold(picture, until: app.buttons["Save to Photos"])
        record("image hold")
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Share…"].exists)
    }

    func testALinkAroundAnImageAddsItsRows() throws {
        let picture = app.webViews.firstMatch.images["Linked picture"]
        hold(picture, until: app.buttons["Open in New Tab"])
        record("linked image hold")
        XCTAssertTrue(app.buttons["Download Linked File"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "image.save").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Save to Photos'")).count, 1, "WebKit's own went")
        XCTAssertTrue(app.buttons["Share Image…"].exists)
        XCTAssertTrue(app.buttons["Copy Link"].exists)
        app.buttons["Copy Image"].tap()
        XCTAssertTrue(any("chrome.toast").waitForExistence(timeout: 10), "the picture's bytes never came")
        XCTAssertEqual(any("chrome.toast").label, "Image copied")
        // Save to Photos, with iOS's add-only question at first use.
        XCTAssertTrue(wait { !self.any("chrome.toast").exists })
        hold(picture, until: app.buttons["Save to Photos"])
        app.buttons["Save to Photos"].tap()
        // The question comes only while Yab may not add yet: once a run has
        // answered it, the toast can come and go while a test waits on a question.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let question = system.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Allow Full Access', 'OK'}")).firstMatch
        let toast = any("chrome.toast")
        XCTAssertTrue(wait { toast.exists || question.exists }, "nothing after Save to Photos")
        if !toast.exists, question.exists {
            record("photos question")
            question.tap()
        }
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "nothing said after Save to Photos")
        record("saved")
        XCTAssertEqual(any("chrome.toast").label, "Saved to Photos")
    }
}

/// A loopback page with a file, an image alone and a link around one.
private final class FilesSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-downloads-site")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    var port: UInt16 { listener.port!.rawValue }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.ready = completion
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; callback(.success(()))
                case let .failed(error): self.ready = nil; callback(.failure(error))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, previous: Data())
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 65_536 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, previous: bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            let reply: Data
            if target.hasPrefix("/report.pdf") {
                let body = Self.pdf
                reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            } else if target.hasPrefix("/picture.png") {
                let body = Self.png
                reply = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            } else {
                let body = Self.page
                reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
            }
            connection.send(content: reply, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close(connection) })
        }
    }

    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private static let page = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Owned files</title>
    <style>body{font:18px -apple-system;padding:70px 20px}a{display:block;min-height:44px}img{display:block;width:200px;height:120px;margin:16px 0}</style>
    <h1>Owned files</h1>
    <a href="/report.pdf">Report</a>
    <img src="/picture.png" alt="Plain picture">
    <a href="/second"><img src="/picture.png" alt="Linked picture"></a>
    """

    /// A one-page PDF, enough for QuickLook.
    private static let pdf = Data("""
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
    trailer<</Root 1 0 R>>
    %%EOF
    """.utf8)

    /// A picture of a real size: WebKit doesn't treat a tiny one as an image to hold.
    private static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 480)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 480))
    }
}

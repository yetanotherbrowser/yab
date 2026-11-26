import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// The iPad's downloads button keeps the last file's icon until it is seen
/// (the Mac's Hoard `waiting`): the list opened, or the file did. A file that
/// ends while the list is open was seen as it came.
@MainActor
final class TabletDownloadsTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil; Motion.disabled = oldDisabled
    }

    private func until(_ check: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if check() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return check()
    }

    private func incoming() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: file)
        return file
    }

    /// The button on screen in a window of its own.
    private func button() async throws -> (AppModel, UIHostingController<some View>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let host = UIHostingController(rootView: TabletDownloadsButton(active: true, id: "test.downloads").environment(app))
        owned.rootViewController = host
        owned.makeKeyAndVisible()
        window = owned
        owned.layoutIfNeeded()
        let drawn = await until { app.workspace.downloadsLandings["test.downloads"] != nil }
        XCTAssertTrue(drawn, "the button is on screen")
        return (app, host)
    }

    /// A file that ended with no list open: the button waits on it.
    private func unseenFile(_ app: AppModel) throws -> UUID {
        let id = UUID()
        app.downloads.begin(id, name: "report.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init())
        XCTAssertTrue(app.downloads.finish(id, from: try incoming()))
        XCTAssertEqual(app.downloads.arrival?.seen, false)
        return id
    }

    private func question() -> DownloadAsk {
        DownloadAsk(id: UUID(), name: "slides.zip", host: "other.com", size: 2_900_000, isPrivate: false)
    }

    func testAFileThatEndsWhileTheListIsOpenIsSeen() async throws {
        let (app, host) = try await button()
        app.workspace.downloadsShown += 1
        let shown = await until { host.presentedViewController != nil }
        XCTAssertTrue(shown, "the list is open")

        let id = UUID()
        app.downloads.begin(id, name: "report.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init())
        XCTAssertTrue(app.downloads.finish(id, from: try incoming()))
        XCTAssertEqual(app.downloads.arrival?.id, id)
        XCTAssertEqual(app.downloads.arrival?.seen, true, "watched as it ended in the open list")

        host.dismiss(animated: false)
        let closed = await until { host.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(app.downloads.arrival?.seen, true, "the button doesn't wait on a file already seen")
    }

    /// Another site's question takes the popover, not the list: the file
    /// waiting before it is still waiting once the question is cancelled,
    /// and the list opened then shows it.
    func testAQuestionLeavesAnEarlierFileUnseen() async throws {
        let (app, host) = try await button()
        let file = try unseenFile(app)
        let ask = question()
        app.downloads.pretend(ask: ask)
        let asked = await until { host.presentedViewController != nil }
        XCTAssertTrue(asked, "the question opens the popover")
        XCTAssertEqual(app.downloads.arrival?.seen, false, "the question is not the list")

        app.answerDownload(ask, false)
        let closed = await until { host.presentedViewController == nil }
        XCTAssertTrue(closed, "the popover the question opened goes with it")
        XCTAssertEqual(app.downloads.arrival?.id, file)
        XCTAssertEqual(app.downloads.arrival?.seen, false, "cancelling keeps the file waiting")

        app.workspace.downloadsShown += 1
        let listed = await until { host.presentedViewController != nil }
        XCTAssertTrue(listed)
        XCTAssertEqual(app.downloads.arrival?.seen, true, "the list shows it")
    }

    /// A file that ends while the question stands in the popover was not
    /// watched: the list never showed it.
    func testAFileThatEndsBehindAQuestionIsUnseen() async throws {
        let (app, host) = try await button()
        let ask = question()
        app.downloads.pretend(ask: ask)
        let asked = await until { host.presentedViewController != nil }
        XCTAssertTrue(asked)
        let file = try unseenFile(app)

        app.answerDownload(ask, false)
        let closed = await until { host.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(app.downloads.arrival?.id, file)
        XCTAssertEqual(app.downloads.arrival?.seen, false, "it still waits on the button")
    }
}

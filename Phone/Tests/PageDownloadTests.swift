import Network
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Real WKDownload delegates write only disposable bytes from an owned HTTP listener.
@MainActor
final class PageDownloadTests: XCTestCase {
    private var site: DownloadSite!
    private var pages: WebPool!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var ids: [Tab.ID] = []
    private var directories: [URL] = []
    private var oldDisabled = false
    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        site = try DownloadSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in site.start { done.resume(with: $0) } }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        pages = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
    }
    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled }
        pages?.suspendPageDialogs(); ids.forEach { pages?.forget($0) }
        window?.rootViewController?.dismiss(animated: false)
        window?.rootViewController = nil; window?.isHidden = true; window = nil; previousKey?.makeKey()
        pages = nil; site?.stop(); site = nil
        try await require({ self.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }, "Owned download directories remain after transfer cancellation/system share cleanup")
        directories = []; ids = []
    }
    private func require(_ check: () -> Bool, _ message: String = "Actual WebKit download state did not arrive", file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(10)
        while Date() < end { if check() { return }; try await Task.sleep(for: .milliseconds(20)) }
        guard check() else {
            if let pages, let id = pages.front {
                let state = pages.state(for: id)
                let actual = "Owned source: \(pages.describe(id)); page failure=\(String(describing: state.failure)); transfers=\(pages.transfers.count); entries=\(pages.downloads.entries.map(\.state)); actual HTTP targets=\(site?.requests.map(\.target) ?? [])"
                let diagnostic = XCTAttachment(string: actual); diagnostic.name = "Owned native download failure state"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                if window != nil { shot("Owned native download state at the unchanged deadline") }
            }
            XCTFail(message, file: file, line: line); throw NSError(domain: "PageDownloadTests", code: 1)
        }
    }
    private func tab(_ id: String, _ path: String = "/page", privateMode: Bool = false) -> YabPhone.Tab {
        ids.append(id); return PageFixtures.liveTab(for: site.url(path), id: id, isPrivate: privateMode)
    }
    private func show(_ view: WKWebView) {
        let host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }; view.frame = host.bounds; view.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        host.addSubview(view); window.layoutIfNeeded()
    }
    private func ready(_ tab: YabPhone.Tab) async throws -> WKWebView {
        let view = pages.activate(tab); show(view)
        try await require { self.pages.painted.contains(tab.id) && !view.isLoading }
        return view
    }
    private func click(_ view: WKWebView, _ id: String = "file") async throws {
        let _: Any = try await view.evaluateJavaScript("document.getElementById('\(id)').click(); true")
    }
    private var store: DownloadStore { pages.downloads }
    private var job: PageDownload? { pages.transfers.values.first }
    /// A transfer is on its way: its bytes still come while the test holds them.
    private func started() async throws -> PageDownload {
        try await require { self.job?.destination != nil }
        let job = try XCTUnwrap(self.job); directories.append(job.directory)
        return job
    }
    /// The newest file, whole, in the store's folder.
    private func completed() async throws -> DownloadEntry {
        try await require { self.store.entries.first?.isDone == true }
        XCTAssertTrue(pages.transfers.isEmpty, "a finished file holds no transfer")
        if let front = pages.front { XCTAssertNil(pages.state(for: front).failure, "the approved download policy must not replace its source with a navigation failure") }
        XCTAssertNil(window.rootViewController?.presentedViewController, "nothing covers the page: no alert, no share sheet")
        return try XCTUnwrap(store.entries.first)
    }
    /// WKWebView.url can still name the file for a moment after it is whole,
    /// then reads the source again with no navigation: wait that moment out.
    private func settles(_ view: WKWebView, at url: URL) async throws {
        try await require({ view.url == url }, "the source's address did not come back")
    }
    private func bytes(_ entry: DownloadEntry) throws -> Data { try Data(contentsOf: try XCTUnwrap(store.url(of: entry))) }
    private func failed() async throws -> DownloadEntry {
        try await require { self.store.entries.first?.state == .failed && self.pages.transfers.isEmpty }
        XCTAssertNil(window.rootViewController?.presentedViewController, "a failure shows in its row")
        return try XCTUnwrap(store.entries.first)
    }
    private func shot(_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let value = XCTAttachment(image: image); value.name = name; value.lifetime = .keepAlways; add(value)
    }

    func testSuggestedNamesCannotEscapeTheOwnedDirectory() {
        XCTAssertEqual(PageDownload.filename("../../Owned.txt"), "Owned.txt")
        XCTAssertEqual(PageDownload.filename(".."), "Download")
        XCTAssertEqual(PageDownload.filename("\n\r"), "Download")
        XCTAssertEqual(PageDownload.filename("a:b\u{0000}.txt"), "ab.txt")
        XCTAssertEqual(PageDownload.filename(String(repeating: "é", count: 500)).count, 120)
    }

    /// A long name is cut before its extension, not through it: 100 Chinese
    /// characters are 300 bytes, and the name stays a .pdf within 255.
    func testALongNameKeepsItsExtension() {
        let wide = PageDownload.filename(String(repeating: "報", count: 100) + ".pdf")
        XCTAssertTrue(wide.hasSuffix(".pdf"), wide)
        XCTAssertLessThanOrEqual(wide.utf8.count, 255)
        let long = PageDownload.filename(String(repeating: "a", count: 200) + ".tar.gz")
        XCTAssertTrue(long.hasSuffix(".gz"), long)
        XCTAssertEqual(long.count, 120)
        XCTAssertEqual(PageDownload.filename("report.pdf"), "report.pdf")
    }

    /// An extension is one character but 600 bytes: it goes, and the name
    /// still fits the filesystem's 255 bytes.
    func testAnExtensionOfOneHugeCharacterStillFitsTheByteLimit() throws {
        let combined = "e" + String(repeating: "\u{0301}", count: 300)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owned-download-ending-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for suggested in ["a." + combined, combined + "." + combined, "report." + String(repeating: "報", count: 10)] {
            let name = PageDownload.filename(suggested)
            XCTAssertLessThanOrEqual(name.utf8.count, 255, name)
            XCTAssertLessThanOrEqual(name.count, 120)
            let target = folder.appendingPathComponent(name)
            try DownloadSite.bytes.write(to: target, options: .withoutOverwriting)
            XCTAssertEqual(try Data(contentsOf: target), DownloadSite.bytes)
        }
        XCTAssertEqual(PageDownload.filename("report." + String(repeating: "報", count: 10)), "report." + String(repeating: "報", count: 10), "a short wide extension stays")
    }

    func testUnicodeNamesFitTheActualOwnedFilesystemWithoutBreakingGraphemes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owned-download-name-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let emoji = PageDownload.filename(String(repeating: "😀", count: 120))
        XCTAssertEqual(emoji, String(repeating: "😀", count: 63))
        XCTAssertLessThanOrEqual(emoji.utf8.count, 255)
        let combined = "e" + String(repeating: "\u{0301}", count: 300)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(PageDownload.filename(combined), "Download")
        for suggested in [String(repeating: "é", count: 500), String(repeating: "👩‍💻", count: 120), combined] {
            let name = PageDownload.filename(suggested)
            XCTAssertFalse(name.isEmpty); XCTAssertLessThanOrEqual(name.count, 120); XCTAssertLessThanOrEqual(name.utf8.count, 255)
            let target = folder.appendingPathComponent(name)
            try DownloadSite.bytes.write(to: target, options: .withoutOverwriting)
            XCTAssertEqual(try Data(contentsOf: target), DownloadSite.bytes)
            XCTAssertEqual(target.deletingLastPathComponent(), folder)
        }
    }

    func testActualAttachmentBytesKeepTheSourceAndHistoryAndStayInTheFolder() async throws {
        let source = tab("download.public"), view = try await ready(source)
        let store = view.configuration.websiteDataStore
        pages.load(source.id, site.url("/second"))
        try await require { self.pages.painted.contains(source.id) && view.url == self.site.url("/second") && !view.isLoading }
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        let _: Any = try await view.evaluateJavaScript("document.cookie='public-only=owned;path=/'; true")
        try await click(view)
        let file = try await completed()
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
        XCTAssertEqual(file.name, "Owned.txt")
        XCTAssertEqual(file.host, "127.0.0.1")
        XCTAssertEqual(file.size, Int64(DownloadSite.bytes.count))
        try await settles(view, at: site.url("/second")); XCTAssertTrue(view.configuration.websiteDataStore === store)
        XCTAssertEqual(pages.front, source.id)
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
        XCTAssertEqual(pages.navigationState(for: source.id)?.index, before.index)
        XCTAssertTrue(try XCTUnwrap(site.requests.last { $0.target == "/file" }).header.contains("public-only=owned"))
        shot("Actual HTTP download finished under the unchanged source")
    }

    func testTheNextFileOfTheSameNameKeepsBoth() async throws {
        let source = tab("download.twice"), view = try await ready(source)
        try await click(view)
        let first = try await completed()
        try await click(view)
        try await require { self.store.entries.filter(\.isDone).count == 2 }
        XCTAssertEqual(store.entries.first?.name, "Owned 2.txt")
        XCTAssertEqual(try bytes(first), DownloadSite.bytes)
        XCTAssertEqual(try bytes(try XCTUnwrap(store.entries.first)), DownloadSite.bytes)
    }

    func testTheQuestionComesBeforeAnyByteAndCancelLeavesNothing() async throws {
        var asked: [(DownloadAsk, @MainActor (Bool) -> Void)] = []
        pages.onDownloadAsk = { asked.append(($0, $1)) }
        let source = tab("download.ask"), view = try await ready(source)
        try await click(view)
        try await require { asked.count == 1 }
        XCTAssertEqual(asked[0].0.name, "Owned.txt")
        XCTAssertEqual(asked[0].0.host, "127.0.0.1")
        XCTAssertEqual(asked[0].0.size, Int64(DownloadSite.bytes.count))
        XCTAssertFalse(asked[0].0.isPrivate)
        let job = try XCTUnwrap(self.job)
        XCTAssertNil(job.destination, "nothing is written before the answer")
        XCTAssertTrue(store.entries.isEmpty)
        asked[0].1(false)
        try await require { self.pages.transfers.isEmpty }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(job.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.directory.path))
        // The page is live, and the same file may be sent after a yes.
        try await click(view, "touch")
        try await click(view)
        try await require { asked.count == 2 }
        asked[1].1(true)
        let file = try await completed()
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
    }

    func testSeveralFilesGoAtOnceAndTheLineSaysSo() async throws {
        site.holdFiles()
        let source = tab("download.several"), view = try await ready(source)
        try await click(view)
        try await require { self.pages.transfers.count == 1 && self.job?.destination != nil }
        try await click(view)
        try await require { self.pages.transfers.count == 2 && self.pages.transfers.values.allSatisfy { $0.destination != nil } }
        directories += pages.transfers.values.map(\.directory)
        try await require { self.store.nowItem(isPrivate: false)?.title.hasPrefix("2 files") == true }
        site.releaseFiles()
        try await require { self.store.entries.filter(\.isDone).count == 2 }
    }

    func testBackTraversalDownloadsFromItsCommittedDocumentWithoutChangingHistory() async throws {
        let source = tab("download.back"), view = try await ready(source)
        let store = view.configuration.websiteDataStore
        pages.load(source.id, site.url("/second"))
        try await require { self.pages.painted.contains(source.id) && view.url == self.site.url("/second") && !view.isLoading }
        let backed = await pages.back(source.id)
        XCTAssertTrue(backed)
        try await require {
            guard self.pages.painted.contains(source.id), !view.isLoading,
                  let history = self.pages.navigationState(for: source.id), history.entries.indices.contains(history.index) else { return false }
            return history.index == 0 && history.entries[history.index].url == self.site.url("/page").absoluteString
        }
        let actualDocument = try await view.evaluateJavaScript("document.URL") as? String
        XCTAssertEqual(actualDocument, site.url("/page").absoluteString)
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        XCTAssertEqual(before.entries.map(\.url), [site.url("/page").absoluteString, site.url("/second").absoluteString])
        XCTAssertEqual(before.index, 0)
        try await click(view)
        let file = try await completed()
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
        let sourceDocumentAfterConversion = try await view.evaluateJavaScript("document.URL") as? String
        XCTAssertEqual(sourceDocumentAfterConversion, site.url("/page").absoluteString)
        XCTAssertEqual(pages.front, source.id)
        XCTAssertTrue(view.configuration.websiteDataStore === store)
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
        XCTAssertEqual(pages.navigationState(for: source.id)?.index, before.index)
        let _: Any = try await view.evaluateJavaScript("document.getElementById('touch').click();true")
        let action = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
        XCTAssertEqual(action, "Page action 1")
    }

    func testPrivateAttachmentUsesItsNativeJarAndStaysOutOfTheList() async throws {
        let publicTab = tab("download.cookie.public"), publicView = try await ready(publicTab)
        let _: Any = try await publicView.evaluateJavaScript("document.cookie='public-only=owned;path=/'; true")
        let privateTab = tab("download.cookie.private", privateMode: true), view = try await ready(privateTab)
        let store = view.configuration.websiteDataStore
        let _: Any = try await view.evaluateJavaScript("document.cookie='private-only=owned;path=/'; true")
        var exported: [BrowserNavigation] = []
        pages.onNavigation = { _, navigation in exported.append(navigation) }
        try await click(view)
        let file = try await completed()
        XCTAssertTrue(file.isPrivate)
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
        XCTAssertTrue(self.store.list(isPrivate: false).isEmpty, "out of the shared list")
        XCTAssertEqual(self.store.list(isPrivate: true).map(\.id), [file.id])
        let request = try XCTUnwrap(site.requests.last { $0.target == "/file" })
        XCTAssertTrue(request.header.contains("private-only=owned")); XCTAssertFalse(request.header.contains("public-only=owned"))
        XCTAssertTrue(view.configuration.websiteDataStore === store); XCTAssertFalse(store.isPersistent)
        XCTAssertFalse(store === publicView.configuration.websiteDataStore)
        try await settles(view, at: site.url("/page")); XCTAssertEqual(pages.front, privateTab.id); XCTAssertTrue(exported.isEmpty)
        // The private tabs close: their file goes.
        let url = try XCTUnwrap(self.store.url(of: file))
        pages.setPageInteractionsEnabled(false); pages.renewPrivateStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(self.store.list(isPrivate: true).isEmpty)
        pages.setPageInteractionsEnabled(true)
        let cookie = try await publicView.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(cookie?.contains("public-only=owned") == true); XCTAssertFalse(cookie?.contains("private-only=owned") == true)
    }

    func testARealFragmentKeepsItsExactHistoryBeforeAndAfterTheDownload() async throws {
        let source = tab("download.fragment"), view = try await ready(source)
        let destination = site.url("/page#part")
        var metadata: [URL] = []
        pages.onMetadata = { _, url, _ in metadata.append(url) }
        try await click(view, "fragment")
        try await require { view.url == destination && metadata.contains(destination) }
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        XCTAssertEqual(before.entries.map(\.url), [site.url("/page").absoluteString, destination.absoluteString])
        try await click(view)
        _ = try await completed()
        try await settles(view, at: destination)
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
        XCTAssertEqual(pages.navigationState(for: source.id)?.index, before.index)
    }

    func testBlobDownloadWritesActualDocumentBytesWithoutChangingHistory() async throws {
        let source = tab("download.blob"), view = try await ready(source)
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        let _: Any = try await view.evaluateJavaScript("const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['Owned blob café+tea'],{type:'text/plain'}));a.download='Blob.txt';document.body.appendChild(a);a.click();true")
        let file = try await completed()
        XCTAssertEqual(String(data: try bytes(file), encoding: .utf8), "Owned blob café+tea")
        try await settles(view, at: site.url("/page")); XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
    }

    func testATransferOutlivesItsPageItsTabAndAViewGone() async throws {
        for route in 0...2 {
            site.holdFiles()
            let source = tab("download.outlives.\(route)"), view = try await ready(source)
            let done = store.entries.filter(\.isDone).count
            try await click(view)
            _ = try await started()
            switch route {
            case 0: let next = tab("download.outlives.next"); _ = try await ready(next)
            case 1: pages.load(source.id, site.url("/second")); try await require { view.url == self.site.url("/second") && !view.isLoading }
            default: pages.forget(source.id)
            }
            XCTAssertEqual(pages.transfers.count, 1, "the transfer goes on")
            site.releaseFiles()
            try await require { self.store.entries.filter(\.isDone).count == done + 1 }
            XCTAssertEqual(try bytes(try XCTUnwrap(store.entries.first)), DownloadSite.bytes)
            site.allowFiles()
        }
    }

    func testStopAndTheEndOfPrivateCancelTheNativeWriterBeforeCleanup() async throws {
        for route in 0...1 {
            site.holdFiles()
            let source = tab("download.cancel.\(route)", privateMode: route == 1), view = try await ready(source)
            try await click(view)
            let job = try await started()
            XCTAssertTrue(store.canStop(job.id))
            if route == 0 { store.stop(job.id) }
            else { pages.setPageInteractionsEnabled(false); pages.renewPrivateStore() }
            try await require { self.pages.transfers.isEmpty }
            XCTAssertEqual(job.phase, .cancelled)
            XCTAssertNil(store.entry(job.id), "a stopped file leaves no row")
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.directory.path))
            site.releaseFiles(); pages.setPageInteractionsEnabled(true)
        }
    }

    func testTruncatedNativeTransferShowsInItsRowAndExplicitRetryWritesRealBytes() async throws {
        let source = tab("download.retry"), view = try await ready(source)
        site.failFiles()
        try await click(view)
        let broken = try await failed()
        XCTAssertEqual(store.arrival?.id, broken.id, "the line says Failed for a moment")
        XCTAssertEqual(store.nowItem(isPrivate: false)?.subtitle, "Failed")
        try await settles(view, at: site.url("/page"))
        XCTAssertNil(broken.file)
        XCTAssertTrue(store.canRetry(broken.id))
        site.allowFiles(); store.retry(broken.id)
        let file = try await completed()
        XCTAssertEqual(file.id, broken.id, "Retry works under the same row")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(site.requests.filter { $0.target == "/file" }.count, 2)
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
        try await settles(view, at: site.url("/page")); XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), [site.url("/page").absoluteString])
        let _: Any = try await view.evaluateJavaScript("document.getElementById('touch').click();true")
        let action = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
        XCTAssertEqual(action, "Page action 1")
    }

    func testPrivateExplicitRetryUsesTheSameNativeJar() async throws {
        let publicTab = tab("download.retry.jar.public"), publicView = try await ready(publicTab)
        let _: Any = try await publicView.evaluateJavaScript("document.cookie='public-only=owned;path=/'; true")
        let source = tab("download.retry.jar.private", privateMode: true), view = try await ready(source)
        let store = view.configuration.websiteDataStore
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        let _: Any = try await view.evaluateJavaScript("document.cookie='private-only=owned;path=/'; true")
        var exported: [BrowserNavigation] = []
        pages.onNavigation = { _, value in exported.append(value) }
        site.failFiles(); try await click(view)
        let broken = try await failed()
        site.allowFiles(); self.store.retry(broken.id)
        let retried = try await completed(); XCTAssertEqual(retried.id, broken.id)
        XCTAssertEqual(try bytes(retried), DownloadSite.bytes)
        let requests = site.requests.filter { $0.target == "/file" }
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertTrue(request.header.contains("private-only=owned"))
            XCTAssertFalse(request.header.contains("public-only=owned"))
        }
        XCTAssertTrue(view.configuration.websiteDataStore === store); XCTAssertFalse(store.isPersistent)
        XCTAssertFalse(store === publicView.configuration.websiteDataStore); XCTAssertTrue(exported.isEmpty)
        XCTAssertEqual(pages.front, source.id)
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
        XCTAssertEqual(pages.navigationState(for: source.id)?.index, before.index)
        let document = try await view.evaluateJavaScript("document.URL") as? String
        XCTAssertEqual(document, site.url("/page").absoluteString)
        let cookie = try await publicView.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(cookie?.contains("public-only=owned") == true); XCTAssertFalse(cookie?.contains("private-only=owned") == true)
    }

    /// A private page's new window that was only a PDF has gone when its
    /// transfer fails. Retry, from the private opener still there, keeps the
    /// row private and lands the file in private storage.
    func testAPrivateWindowsFailedPDFRetriedFromItsOpenerStaysPrivate() async throws {
        let source = tab("download.retry.window.opener", privateMode: true), view = try await ready(source)
        var opened: YabPhone.Tab?, closed: [Tab.ID] = []
        pages.onCloseWindowFrom = { id, _ in closed.append(id) }
        pages.onOpenWindowFrom = { [unowned self] url, _, shy in
            XCTAssertTrue(shy)
            let window = self.tab("download.retry.window", url.path(), privateMode: true)
            opened = window
            DispatchQueue.main.async { self.show(self.pages.activate(window)) }
            return window
        }
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        site.failFiles()
        try await click(view, "pdfwindow")
        let broken = try await failed()
        XCTAssertTrue(broken.isPrivate)
        let window = try XCTUnwrap(opened)
        XCTAssertEqual(closed, [window.id], "the window that was only the file is gone")
        XCTAssertFalse(pages.isLive(window.id))
        show(view)
        site.allowFiles(); store.retry(broken.id)
        let file = try await completed()
        XCTAssertEqual(file.id, broken.id, "Retry works under the same row")
        XCTAssertTrue(file.isPrivate, "a gone private window's file stays private")
        XCTAssertEqual(try bytes(file), DownloadSite.pdf)
        XCTAssertTrue(store.list(isPrivate: false).isEmpty, "nothing in the ordinary Downloads")
        XCTAssertEqual(store.list(isPrivate: true).map(\.id), [file.id])
        let saved = try XCTUnwrap(store.url(of: file))
        XCTAssertEqual(saved.deletingLastPathComponent().lastPathComponent, "private")
        XCTAssertEqual(site.requests.filter { $0.target == "/doc.pdf" }.count, 2)
        store.forgetPrivate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path), "it was in private storage, gone with Private")
    }

    func testDownloadLinkedFileGoesThroughTheSameFlowFromTheTabsStore() async throws {
        var asked = 0
        pages.onDownloadAsk = { _, answer in asked += 1; answer(true) }
        let source = tab("download.linked"), view = try await ready(source)
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        let _: Any = try await view.evaluateJavaScript("document.cookie='linked=owned;path=/'; true")
        pages.downloadLinked(site.url("/file"), from: source.id)
        let file = try await completed()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(file.host, "127.0.0.1", "the site is the page's")
        XCTAssertEqual(try bytes(file), DownloadSite.bytes)
        XCTAssertTrue(try XCTUnwrap(site.requests.last { $0.target == "/file" }).header.contains("linked=owned"))
        try await settles(view, at: site.url("/page"))
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
    }

    /// A picture, a sound, a video or a text file shown as the page is kept as it
    /// came: the same address again, through the tab's own cookies, and its
    /// history stays as it was.
    func testDownloadKeepsAPictureSoundOrTextPageWithTheTabsCookie() async throws {
        for (path, body, cookie) in [("/pic.png", DownloadSite.png, "pic"), ("/clip.mp3", DownloadSite.mp3, "clip"), ("/clip.mp4", DownloadSite.mp4, "film"),
                                    ("/note.txt", DownloadSite.note, "note")] {
            let source = tab("download.document\(cookie)"), view = try await ready(source)
            XCTAssertFalse(pages.state(for: source.id).downloadable, "an HTML page has no Download")
            let _: Any = try await view.evaluateJavaScript("document.cookie='\(cookie)=owned;path=/'; true")
            pages.load(source.id, site.url(path))
            // A sound is WebKit's player's load: the page is there, not a failure.
            try await require { view.url == self.site.url(path) && !view.isLoading && self.pages.painted.contains(source.id) && self.pages.state(for: source.id).downloadable }
            XCTAssertNil(pages.state(for: source.id).failure, "\(path) shows as a page")
            let before = try XCTUnwrap(pages.navigationState(for: source.id))
            let asked = site.requests.count
            pages.downloadDocument(of: source.id)
            let file = try await completed()
            XCTAssertEqual(file.name, String(path.dropFirst()))
            XCTAssertEqual(try bytes(file), body, path)
            // A player may ask again for its sound: every request since, the file's own among them, carries the tab's cookie.
            let since = site.requests.dropFirst(asked)
            XCTAssertFalse(since.isEmpty)
            XCTAssertTrue(since.allSatisfy { $0.target == path && $0.header.contains("\(cookie)=owned") }, path)
            try await settles(view, at: site.url(path))
            XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
            XCTAssertEqual(pages.navigationState(for: source.id)?.index, before.index)
            XCTAssertEqual(pages.front, source.id)
            store.delete(file.id)
        }
    }

    /// A text page a form's POST answered offers no Download: asking its
    /// address again is a GET, with another answer than the one on screen.
    /// The same address asked for with a GET still offers it, and keeps
    /// that answer, and so does an ordinary file page after it. Back to the
    /// POST's page, from WebKit's cache or sent again, it still offers none.
    func testAPostedTextPageOffersNoDownloadButAFetchedOneKeepsItsOwnAnswer() async throws {
        let source = tab("download.document.posted"), view = try await ready(source)
        let answer = site.url("/answer.txt")
        let shown = { () async throws -> String in
            let text: Any = try await view.evaluateJavaScript("document.body.textContent")
            return (text as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        pages.load(source.id, answer)
        try await require { view.url == answer && !view.isLoading && self.pages.state(for: source.id).downloadable }
        let first = try await shown(); XCTAssertEqual(first, "Fetched answer B")
        pages.downloadDocument(of: source.id)
        let fetched = try await completed()
        XCTAssertEqual(try bytes(fetched), DownloadSite.fetched, "a GET's page keeps the GET's answer")
        store.delete(fetched.id)

        view.goBack()
        try await require { view.url == self.site.url("/page") && !view.isLoading && self.pages.painted.contains(source.id) }
        let _: Any = try await view.evaluateJavaScript("document.getElementById('post').submit(); true")
        try await require { view.url == answer && !view.isLoading && self.pages.painted.contains(source.id) }
        let posted = try await shown(); XCTAssertEqual(posted, "Posted answer A")
        XCTAssertEqual(site.requests.last?.header.hasPrefix("POST /answer.txt"), true)
        XCTAssertFalse(pages.state(for: source.id).downloadable, "a POST's page has no Download")
        let asked = site.requests.count
        pages.downloadDocument(of: source.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(site.requests.count, asked, "nothing is asked again")
        XCTAssertTrue(pages.transfers.isEmpty && store.entries.isEmpty, "nothing is kept")

        pages.load(source.id, site.url("/note.txt"))
        try await require { view.url == self.site.url("/note.txt") && !view.isLoading && self.pages.state(for: source.id).downloadable }
        view.goBack()
        try await require { view.url == answer && !view.isLoading && self.pages.painted.contains(source.id) }
        let back = try await shown(); XCTAssertEqual(back, "Posted answer A")
        XCTAssertFalse(pages.state(for: source.id).downloadable, "back on the POST's page, still no Download")
    }

    /// A page that is a page, not a file, offers no Download, and asking
    /// anyway fetches nothing.
    func testAnHTMLPageOffersNoDownload() async throws {
        let source = tab("download.document.html"), view = try await ready(source)
        XCTAssertFalse(pages.state(for: source.id).downloadable)
        let asked = site.requests.count
        pages.downloadDocument(of: source.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(site.requests.count, asked)
        XCTAssertTrue(pages.transfers.isEmpty && store.entries.isEmpty)
        try await settles(view, at: site.url("/page"))
    }

    /// Download of the page is not Download Linked File: a link held a
    /// moment ago on the same page neither throws the disc nor is used up.
    func testDownloadOfThePageLeavesAHeldLinkAlone() async throws {
        store.flies = true
        let source = tab("download.document.held"), view = try await ready(source)
        pages.load(source.id, site.url("/pic.png"))
        try await require { view.url == self.site.url("/pic.png") && !view.isLoading && self.pages.state(for: source.id).downloadable }
        pages.heldLink = (source.id, CGPoint(x: 40, y: 40), ProcessInfo.processInfo.systemUptime)
        let bumps = store.bumps
        pages.downloadDocument(of: source.id)
        try await require { !self.store.entries.isEmpty }
        XCTAssertTrue(store.flights.isEmpty, "no flight from an old link hold")
        XCTAssertEqual(store.bumps, bumps + 1, "the button gives instead")
        XCTAssertEqual(pages.heldLink?.tab, source.id, "the hold is still its link's")
        let file = try await completed()
        try await settles(view, at: site.url("/pic.png"))
        store.delete(file.id)
    }

    /// The app over the pool, as it runs: a public page and another in a
    /// public space, a private one in Private. The viewer's open is seen.
    private func documentApp(locks: @escaping @MainActor () -> Bool = { false },
                             authentication: (any PrivateAuthenticating)? = nil) -> (AppModel, viewed: () -> [Tab.ID]) {
        let page = { (id: String, isPrivate: Bool) in
            YabPhone.Tab(id: id, title: id, site: "127.0.0.1", icon: "globe", url: self.site.url("/page").absoluteString, isPrivate: isPrivate)
        }
        let world = World(name: "download.viewer.\(UUID().uuidString)", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226),
                  today: [page("viewer.page", false), page("viewer.other", false)], current: "viewer.other"),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(31, 31, 34),
                  today: [page("viewer.secret", true)], current: "viewer.secret", isPrivate: true)
        ], mac: World.Mac(joined: false))
        // Its files in a folder of the test's own, not the app's Downloads.
        let app = AppModel(world: world, fixturesEnabled: false, privateAuthentication: authentication,
                           privateLockEnabled: locks, downloads: .temporary())
        pages = app.pages
        ids += ["viewer.page", "viewer.other", "viewer.secret"]
        var viewed: [Tab.ID] = []
        let shows = app.pages.onViewDownload
        app.pages.onViewDownload = { tab, entry in viewed.append(tab); shows?(tab, entry) }
        return (app, { viewed })
    }

    /// The tab in front, of the page's privacy: its PDF opens, the same
    /// way the two below must not.
    func testThePageInFrontsPDFOpens() async throws {
        let (app, viewed) = documentApp()
        let source = try XCTUnwrap(app.browser.tab)
        let view = try await ready(source)
        try await click(view, "pdf")
        try await require { app.downloads.entries.first?.isDone == true }
        try await require { viewed() == [source.id] }
        try await require({ app.downloads.arrival?.seen == true }, "the viewer opened the file")
    }

    /// A private tab's PDF, whole while an ordinary page is in front, only
    /// lands in Downloads: the viewer never opens over the public page.
    func testAPrivateTabsPDFBehindAPublicPageLandsWithoutOpening() async throws {
        let (app, viewed) = documentApp()
        XCTAssertEqual(app.browser.tab?.id, "viewer.other")
        let secret = try XCTUnwrap(app.browser.tab("viewer.secret"))
        let view = try await ready(secret)
        try await click(view, "pdf")
        let file = try await completed()
        XCTAssertTrue(file.isPrivate)
        try await require { viewed() == [secret.id] }
        XCTAssertEqual(app.browser.tab?.id, "viewer.other")
        XCTAssertNil(window.rootViewController?.presentedViewController, "no viewer over the public page")
        XCTAssertEqual(app.downloads.arrival?.seen, false, "the file waits in Downloads, not opened")
    }

    /// Yab left and back with Open with Face ID while a private PDF comes:
    /// Private is locked over the same tab, and the viewer never opens over the lock.
    func testAPrivatePDFWholeWhilePrivateIsLockedLandsWithoutOpening() async throws {
        var locks = false
        let (app, viewed) = documentApp(locks: { locks })
        let secret = try XCTUnwrap(app.browser.tab("viewer.secret"))
        app.browser.select(secret.id)
        let view = try await ready(secret)
        site.holdFiles()
        try await click(view, "pdf")
        _ = try await started()
        locks = true
        app.privateLock.didEnterBackground()
        app.privateLock.didBecomeActive()
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.tab?.id, secret.id)
        site.releaseFiles()
        let file = try await completed()
        XCTAssertTrue(file.isPrivate)
        try await require { viewed() == [secret.id] }
        XCTAssertNil(window.rootViewController?.presentedViewController, "no viewer over the lock")
        XCTAssertEqual(app.downloads.arrival?.seen, false, "the file waits in Downloads, not opened")
    }

    /// Yab's folders of Save as PDF in the temporary folder.
    private func pdfFolders() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("yab-pdf-") } ?? [])
    }

    /// Save as PDF on a private page, then Private left, or locked, before
    /// the PDF is made: nothing shows over what is in front, and no file stays.
    func testAPrivatePagesPDFMadeAfterPrivateIsLeftOrLockedIsDropped() async throws {
        for leaving in ["left", "locked"] {
            var locks = false
            let (app, _) = documentApp(locks: { locks })
            let secret = try XCTUnwrap(app.browser.tab("viewer.secret"))
            app.browser.select(secret.id)
            let view = try await ready(secret)
            XCTAssertTrue(app.pageIsPrivate)
            let before = madePDFs(app)
            app.savePageAsPDF()
            if leaving == "left" {
                app.browser.select("viewer.other")
                XCTAssertFalse(app.pageIsPrivate)
            } else {
                locks = true
                app.privateLock.didEnterBackground()
                app.privateLock.didBecomeActive()
                XCTAssertFalse(app.privateLock.mayReveal)
            }
            // WebKit makes a view's PDFs in turn: the app's is made by now.
            _ = try await view.pdf()
            await Task.yield()
            XCTAssertNil(window.rootViewController?.presentedViewController, "\(leaving): no share sheet of the private page")
            XCTAssertEqual(madePDFs(app), before, "\(leaving): no file of it")
            XCTAssertNotEqual(app.surfaces.toast?.text, "Couldn’t save this page", leaving)
            window.rootViewController?.dismiss(animated: false)
        }
    }

    /// The device says yes at once: Open with Face ID, unlocked.
    private final class Allow: PrivateAuthenticating {
        func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) { completion(.unlocked) }
        func invalidate() {}
    }

    /// A private page in front, Private unlocked with Open with Face ID on.
    private func unlockedSecret() async throws -> (AppModel, WKWebView) {
        let (app, _) = documentApp(locks: { true }, authentication: Allow())
        app.privateLock.unlock()
        XCTAssertEqual(app.privateLock.phase, .unlocked)
        let secret = try XCTUnwrap(app.browser.tab("viewer.secret"))
        app.browser.select(secret.id)
        XCTAssertTrue(app.privateLock.mayReveal)
        return (app, try await ready(secret))
    }

    /// Every PDF of a page Yab made and still keeps, in any of its folders.
    private func madePDFs(_ app: AppModel) -> [String] {
        let manager = FileManager.default
        let temporary = pdfFolders().map { manager.temporaryDirectory.appendingPathComponent($0, isDirectory: true) }
        return (temporary + [app.downloads.privateFolder]).flatMap { root in
            (manager.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "pdf" && $0.path.contains("yab-pdf-") }.map(\.path)
        }
    }

    /// Save as PDF's share sheet over a private page, then Private locks as
    /// Yab goes (Open with Face ID): the sheet goes before the system's
    /// snapshot, and its file with it. Back in Yab, the lock, and no sheet.
    func testAPrivatePagesPDFSheetGoesWithItsFileWhenPrivateLocks() async throws {
        for away in ["inactive", "background"] {
            let (app, view) = try await unlockedSecret()
            let before = Set(madePDFs(app))
            app.savePageAsPDF()
            _ = try await view.pdf()
            try await require({ self.window.rootViewController?.presentedViewController is UIActivityViewController }, "\(away): the share sheet")
            XCTAssertEqual(Set(madePDFs(app)).subtracting(before).count, 1, away)
            app.privateLock.willResignActive()
            if away == "background" { app.privateLock.didEnterBackground() }
            try await require({ self.window.rootViewController?.presentedViewController == nil }, "\(away): the sheet stayed over locked Private")
            XCTAssertEqual(Set(madePDFs(app)), before, "\(away): the private PDF stayed")
            app.privateLock.didBecomeActive()
            XCTAssertTrue(app.privateContentBlocked, "\(away): back, Private is locked")
            XCTAssertNil(window.rootViewController?.presentedViewController, "\(away): and nothing over the lock")
        }
    }

    /// Without Open with Face ID, Private doesn't lock as Yab goes: the
    /// sheet stays with its page, under the curtain while Yab is away.
    func testAPrivatePagesPDFSheetStaysWithItsPageWithoutTheLock() async throws {
        let (app, _) = documentApp()
        let secret = try XCTUnwrap(app.browser.tab("viewer.secret"))
        app.browser.select(secret.id)
        let view = try await ready(secret)
        let before = Set(madePDFs(app))
        app.savePageAsPDF()
        _ = try await view.pdf()
        try await require({ self.window.rootViewController?.presentedViewController is UIActivityViewController }, "the share sheet")
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        app.privateLock.didBecomeActive()
        await Task.yield()
        XCTAssertTrue(window.rootViewController?.presentedViewController is UIActivityViewController)
        let made = Set(madePDFs(app)).subtracting(before)
        XCTAssertEqual(made.count, 1)
        window.rootViewController?.dismiss(animated: false)
        made.forEach { try? FileManager.default.removeItem(atPath: ($0 as NSString).deletingLastPathComponent) }
    }

    /// Yab ended with a private page's PDF in its share sheet (the sheet's
    /// own end never came): the next launch finds no file of it.
    func testAPrivatePagesPDFIsGoneAtTheNextLaunch() async throws {
        let (app, view) = try await unlockedSecret()
        let before = Set(madePDFs(app))
        app.savePageAsPDF()
        _ = try await view.pdf()
        try await require({ self.window.rootViewController?.presentedViewController is UIActivityViewController }, "the share sheet")
        let made = Set(madePDFs(app)).subtracting(before)
        XCTAssertEqual(made.count, 1)
        let sheet = window.rootViewController?.presentedViewController as? UIActivityViewController
        sheet?.completionWithItemsHandler = nil
        window.rootViewController?.dismiss(animated: false)
        // The next launch: a store over the same folders.
        _ = DownloadStore(folder: app.downloads.privateFolder.deletingLastPathComponent().appendingPathComponent("Downloads"),
                          privateFolder: app.downloads.privateFolder, index: nil)
        XCTAssertTrue(made.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "the private PDF outlived Yab")
        made.forEach { try? FileManager.default.removeItem(atPath: ($0 as NSString).deletingLastPathComponent) }
    }

    /// The system's viewer with a private file, then Private locks: the
    /// viewer goes; the file stays in Private's Downloads.
    func testAPrivateDocumentsViewerGoesWhenPrivateLocks() async throws {
        let (app, _) = try await unlockedSecret()
        let file = DownloadEntry(id: UUID(), name: "secret.pdf", host: "127.0.0.1", size: 3, date: Date(), state: .done,
                                 isPrivate: true, file: "secret.pdf")
        app.downloads.pretend([file])
        app.openDownload(file)
        try await require({ self.window.rootViewController?.presentedViewController != nil }, "the viewer")
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        try await require({ self.window.rootViewController?.presentedViewController == nil }, "the viewer stayed over locked Private")
        app.privateLock.didBecomeActive()
        XCTAssertTrue(app.privateContentBlocked)
    }

    /// The print panel over a private page, then Private locks: the panel goes.
    func testAPrivatePagesPrintPanelGoesWhenPrivateLocks() async throws {
        let (app, _) = try await unlockedSecret()
        app.printPage()
        try await require({ self.window.rootViewController?.presentedViewController != nil }, "the print panel")
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        try await require({ self.window.rootViewController?.presentedViewController == nil }, "the print panel stayed over locked Private")
    }

    /// A title of 85 Chinese characters is 255 bytes: the PDF of its page
    /// still has a name that fits with .pdf, and goes to the share sheet.
    func testALongTitlesPageSavesAsPDF() async throws {
        let (app, _) = documentApp()
        let source = try XCTUnwrap(app.browser.tab)
        let view = try await ready(source)
        var titled = try XCTUnwrap(app.browser.tab(source.id))
        titled.title = String(repeating: "報", count: 85)
        app.browser.replace(source.id, with: titled)
        let before = pdfFolders()
        app.savePageAsPDF()
        _ = try await view.pdf()
        try await require({ self.window.rootViewController?.presentedViewController is UIActivityViewController }, "the share sheet with the page's PDF")
        XCTAssertNotEqual(app.surfaces.toast?.text, "Couldn’t save this page")
        let made = pdfFolders().subtracting(before)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(try XCTUnwrap(made.first), isDirectory: true)
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder.path).first)
        XCTAssertTrue(name.hasSuffix(".pdf"), name)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        window.rootViewController?.dismiss(animated: false)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A picture or text page back from WebKit's back-forward cache comes
    /// with no response: it still offers Download, as before it was left.
    func testAFilePageBackFromTheCacheStillOffersDownload() async throws {
        for path in ["/pic.png", "/note.txt"] {
            let source = tab("download.back\(path.hashValue)"), view = try await ready(source)
            pages.load(source.id, site.url(path))
            try await require { view.url == self.site.url(path) && !view.isLoading && self.pages.state(for: source.id).downloadable }
            pages.load(source.id, site.url("/second"))
            try await require { view.url == self.site.url("/second") && !view.isLoading }
            XCTAssertFalse(pages.state(for: source.id).downloadable, "an HTML page has no Download")
            let asked = site.requests.count
            XCTAssertTrue(pages.goBack(source.id))
            try await require { view.url == self.site.url(path) && !view.isLoading && self.pages.painted.contains(source.id) }
            XCTAssertEqual(site.requests.count, asked, "\(path) came back from the cache, with no response")
            try await require({ self.pages.state(for: source.id).downloadable }, "\(path) offers Download again")
            pages.downloadDocument(of: source.id)
            let file = try await completed()
            XCTAssertEqual(file.name, String(path.dropFirst()))
            store.delete(file.id)
        }
    }

    /// A PDF whose tab was closed before it was whole only lands in
    /// Downloads: the viewer doesn't open over the page in front now.
    func testAClosedSourceTabsPDFLandsWithoutOpening() async throws {
        let (app, viewed) = documentApp()
        let source = try XCTUnwrap(app.browser.tab)
        let view = try await ready(source)
        site.holdFiles()
        try await click(view, "pdf")
        _ = try await started()
        app.browser.close(source.id)
        XCTAssertNil(app.browser.tab(source.id))
        XCTAssertNotNil(app.browser.tab)
        site.releaseFiles()
        let file = try await completed()
        XCTAssertEqual(file.name, "doc.pdf")
        XCTAssertEqual(try bytes(file), DownloadSite.pdf)
        try await require { viewed() == [source.id] }
        XCTAssertNil(window.rootViewController?.presentedViewController, "no viewer over the page in front")
        XCTAssertEqual(app.downloads.arrival?.seen, false, "the file waits in Downloads, not opened")
    }

    /// A PDF the page opens inline is a file for the system's viewer: kept
    /// in Downloads without asking, handed to the viewer once whole, and the
    /// page it came from stays as it was.
    func testAPDFOpensAsAFileForTheViewerAndKeepsTheSource() async throws {
        var asked = 0, viewed: [(Tab.ID, UUID)] = []
        pages.onDownloadAsk = { _, answer in asked += 1; answer(true) }
        pages.onViewDownload = { viewed.append(($0, $1)) }
        let source = tab("download.pdf"), view = try await ready(source)
        let before = try XCTUnwrap(pages.navigationState(for: source.id))
        try await click(view, "pdf")
        let file = try await completed()
        XCTAssertEqual(asked, 0, "viewing a document is not the site sending a file")
        XCTAssertEqual(file.name, "doc.pdf")
        XCTAssertEqual(try bytes(file), DownloadSite.pdf)
        try await require { viewed.count == 1 }
        XCTAssertEqual(viewed.first?.0, source.id)
        XCTAssertEqual(viewed.first?.1, file.id)
        try await settles(view, at: site.url("/page"))
        XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), before.entries.map(\.url))
    }

    /// A site told no to downloads sends no file: its PDF shows in the tab,
    /// as WebKit shows it, and nothing lands in Downloads.
    func testASiteWithDownloadsOffShowsItsPDFInThePage() async throws {
        let settings = SiteSettings(defaults: nil)
        settings.setDecision(.off, .downloads, for: site.url("/page").host(), isPrivate: false)
        pages.siteSettings = settings
        var asked = 0
        pages.onDownloadAsk = { _, answer in asked += 1; answer(false) }
        let source = tab("download.pdf.off"), view = try await ready(source)
        try await click(view, "pdf")
        try await require({ view.url?.path() == "/doc.pdf" && !view.isLoading }, "the PDF did not show in its tab")
        XCTAssertTrue(store.entries.isEmpty, "no file for a site with downloads off")
        XCTAssertTrue(pages.transfers.isEmpty)
        XCTAssertEqual(asked, 0)
    }

    /// A tab whose first load is a PDF had no page to put back: the file
    /// still opens, rather than being dropped.
    func testAPDFAsATabsFirstLoadStillOpens() async throws {
        var viewed: [UUID] = []
        pages.onViewDownload = { viewed.append($1) }
        let fresh = tab("download.pdf.fresh", "/doc.pdf")
        show(pages.activate(fresh))
        let file = try await completed()
        XCTAssertEqual(file.name, "doc.pdf")
        XCTAssertEqual(file.host, "127.0.0.1", "the site is the file's own")
        try await require { viewed == [file.id] }
        try await require { !self.pages.state(for: fresh.id).isLoading }
    }

    /// A window the page opened that was only ever the PDF closes back to its
    /// opener: the viewer is the opener's, not the gone window's.
    func testAPDFInAWindowThePageOpenedIsForItsOpener() async throws {
        var viewed: [(Tab.ID, UUID)] = [], closed: [(Tab.ID, Tab.ID)] = []
        pages.onViewDownload = { viewed.append(($0, $1)) }
        pages.onCloseWindowFrom = { closed.append(($0, $1)) }
        let source = tab("download.pdf.opener"), view = try await ready(source)
        var window: YabPhone.Tab?
        pages.onOpenWindowFrom = { [unowned self] url, opener, _ in
            XCTAssertEqual(opener, source.id)
            let opened = self.tab("download.pdf.window", url.path())
            window = opened
            // As the app does: the new window comes to the front.
            DispatchQueue.main.async { self.show(self.pages.activate(opened)) }
            return opened
        }
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        try await click(view, "pdfwindow")
        let file = try await completed()
        XCTAssertEqual(file.name, "doc.pdf")
        let opened = try XCTUnwrap(window)
        try await require { viewed.count == 1 }
        XCTAssertEqual(closed.map(\.0), [opened.id], "the window that was only the file goes")
        XCTAssertEqual(viewed.first?.0, source.id, "the viewer is for the page that opened the window")
        XCTAssertEqual(viewed.first?.1, file.id)
    }

    func testNativeRequestDownloadReportsItsAPIFrameWithoutNavigatingTheActualDocument() async throws {
        var publicStore: WKWebsiteDataStore?
        for privately in [false, true] {
            let source = tab("download.api-frame.\(privately)", privateMode: privately)
            let view = try await ready(source)
            let store = view.configuration.websiteDataStore
            let history = try XCTUnwrap(pages.navigationState(for: source.id))
            if !privately { publicStore = store }
            let cookieName = privately ? "api-frame-private" : "api-frame-public"
            let foreignCookie = privately ? "api-frame-public" : "api-frame-private"
            let _: Any = try await view.evaluateJavaScript("document.cookie='\(cookieName)=owned;path=/'; true")
            site.holdFiles()
            var received: WKDownload?
            view.startDownload(using: URLRequest(url: site.url("/file"))) { received = $0 }
            try await require { received != nil }
            let download = try XCTUnwrap(received)
            download.cancel(nil)
            XCTAssertTrue(download.webView === view)
            XCTAssertEqual(download.originalRequest?.url, site.url("/file"))
            XCTAssertTrue(download.originatingFrame.isMainFrame)
            XCTAssertEqual(download.originatingFrame.request.url, URL(string: "about:blank"))
            XCTAssertTrue(pages.transfers.isEmpty)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            // Public inherits this suite's nonPersistent store; Private
            // must use a distinct native jar, rather than a persistence assumption.
            XCTAssertFalse(store.isPersistent)
            let inheritedPublicStore = try XCTUnwrap(publicStore)
            if privately { XCTAssertFalse(store === inheritedPublicStore) }
            else { XCTAssertTrue(store === inheritedPublicStore) }
            XCTAssertEqual(pages.front, source.id)
            XCTAssertEqual(pages.navigationState(for: source.id)?.entries.map(\.url), history.entries.map(\.url))
            XCTAssertEqual(pages.navigationState(for: source.id)?.index, history.index)
            let document = try await view.evaluateJavaScript("document.URL") as? String
            XCTAssertEqual(document, site.url("/page").absoluteString)
            let actualRequest = try XCTUnwrap(site.requests.last { $0.target == "/file" })
            XCTAssertTrue(actualRequest.header.contains("\(cookieName)=owned"))
            XCTAssertFalse(actualRequest.header.contains("\(foreignCookie)=owned"))
            let _: Any = try await view.evaluateJavaScript("document.getElementById('touch').click();true")
            let action = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
            XCTAssertEqual(action, "Page action 1")
            pages.forget(source.id)
        }
    }

    func testBackgroundWarmAndChildFrameCannotStartAFile() async throws {
        let selected = tab("download.front"), view = try await ready(selected)
        let background = tab("download.background", "/file")
        _ = pages.warm(background)
        try await require { self.site.requests.filter { $0.target == "/file" }.count == 1 }
        XCTAssertTrue(pages.transfers.isEmpty)
        let _: Any = try await view.evaluateJavaScript("const frame=document.createElement('iframe');frame.src='/file';document.body.appendChild(frame);true")
        try await require { self.site.requests.filter { $0.target == "/file" }.count == 2 }
        XCTAssertTrue(pages.transfers.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
        try await settles(view, at: site.url("/page")); XCTAssertEqual(pages.front, selected.id)
    }

    // MARK: - with Yab in the background

    private func away(_ name: String, privateMode: Bool = false) async throws -> (PageDownload, WKWebView) {
        site.holdFiles()
        let source = tab(name, privateMode: privateMode), view = try await ready(source)
        try await click(view)
        let job = try await started()
        pages.appWillResignActive()
        try await require { job.away }
        XCTAssertEqual(job.phase, .transferring, "leaving Yab doesn't stop the transfer")
        return (job, view)
    }

    func testADownloadFinishedWhileYabWasAwayIsSaidOnReturn() async throws {
        let (job, view) = try await away("download.away.finish")
        site.releaseFiles()
        try await require { job.phase == .ready }
        XCTAssertNil(store.nowItem(isPrivate: false), "nothing is said while Yab is away")
        XCTAssertEqual(try bytes(try XCTUnwrap(store.entry(job.id))), DownloadSite.bytes)
        pages.appDidBecomeActive()
        try await require { self.store.nowItem(isPrivate: false)?.subtitle == "Open" }
        XCTAssertEqual(store.arrival?.id, job.id)
        XCTAssertEqual(store.nowItem(isPrivate: false)?.subtitle, "Open")
        try await settles(view, at: site.url("/page"))
    }

    func testComingBackWhileItStillGoesKeepsTheLine() async throws {
        let (job, _) = try await away("download.away.going")
        pages.appDidBecomeActive()
        try await require { !job.away }
        XCTAssertNotNil(store.nowItem(isPrivate: false))
        site.releaseFiles()
        let file = try await completed()
        XCTAssertEqual(file.id, job.id)
    }

    func testAPageCoveredWhileAwayKeepsItsDownloadAndSaysItOnceInUse() async throws {
        let (job, _) = try await away("download.away.covered", privateMode: true)
        // Private's cover and lock as Yab goes: the page isn't in use.
        pages.setPageInteractionsEnabled(false)
        XCTAssertEqual(job.phase, .transferring)
        site.releaseFiles()
        try await require { job.phase == .ready }
        pages.appDidBecomeActive()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.nowItem(isPrivate: true), "still locked: nothing private shows")
        pages.setPageInteractionsEnabled(true)
        try await require { self.store.nowItem(isPrivate: true)?.subtitle == "Open" }
    }
}

private final class DownloadSite: @unchecked Sendable {
    struct Request { let target: String; let header: String }
    static let bytes = Data("Owned actual download café+tea\n".utf8)
    /// A PDF the page shows inline, no attachment: one empty page.
    static let pdf = Data("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8)
    /// Files a tab shows as its page: a picture, a sound, plain text.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    static let mp3 = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFB, 0x90, 0x00])
    static let note = Data("An owned note, kept as it came.\n".utf8)
    /// An MP4's first box alone: WebKit's player takes the page, with nothing to play.
    static let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D,
                           0x00, 0x00, 0x02, 0x00, 0x69, 0x73, 0x6F, 0x6D, 0x6D, 0x70, 0x34, 0x31])
    /// One address, two answers: what a form's POST gets, and what a GET gets.
    static let posted = Data("Posted answer A\n".utf8), fetched = Data("Fetched answer B\n".utf8)
    static let documents = ["/pic.png": ("image/png", png), "/clip.mp3": ("audio/mpeg", mp3), "/clip.mp4": ("video/mp4", mp4),
                            "/note.txt": ("text/plain; charset=utf-8", note)]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned.download.site")
    private var connections: [ObjectIdentifier:NWConnection] = [:]
    private var ready: ((Result<Void,Error>) -> Void)?
    private var stopped = false
    private var received: [Request] = []
    private var held: [(NWConnection,Data)] = []
    private var holds = false, fails = false
    var requests: [Request] { queue.sync { received } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    init() throws {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ callback: @escaping (Result<Void,Error>) -> Void) {
        queue.async {
            self.ready = callback
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let done = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; done(.success(()))
                case let .failed(error): self.ready = nil; done(.failure(error))
                case .cancelled: self.ready = nil; done(.failure(NSError(domain: "OwnedDownloadSite", code: 1)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection; connection.start(queue: self.queue); self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now()+5) { [weak self] in
                guard let self, let done = self.ready else { return }; self.ready = nil; self.listener.cancel(); done(.failure(NSError(domain: "OwnedDownloadSite", code: 2)))
            }
        }
    }
    func stop() { queue.sync { stopped = true; listener.cancel(); connections.values.forEach { $0.cancel() }; connections = [:]; held = [] } }
    func holdFiles() { queue.sync { holds = true; fails = false } }
    func failFiles() { queue.sync { fails = true; holds = false } }
    func allowFiles() { queue.sync { fails = false; holds = false } }
    func releaseFiles() { queue.sync { holds = false; let pending = held; held = []; for (connection, bytes) in pending { send(bytes, connection) } } }
    private func close(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel() }
    private func send(_ bytes: Data, _ connection: NWConnection) {
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let chunk { bytes.append(chunk) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended { self.close(connection) } else { self.receive(connection, bytes) }; return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            self.received.append(Request(target: target, header: header))
            if target == "/answer.txt" {
                let body = header.hasPrefix("POST ") ? Self.posted : Self.fetched
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                self.send(headers + body, connection)
                return
            }
            if let (type, body) = Self.documents[target] {
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                self.send(headers + body, connection)
                return
            }
            if target == "/doc.pdf" {
                let body = Self.pdf
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                if self.holds {
                    connection.send(content: headers + body.prefix(2), completion: .contentProcessed { _ in })
                    self.held.append((connection, Data(body.dropFirst(2))))
                } else { self.send(headers + (self.fails ? Data(body.prefix(2)) : body), connection) }
                return
            }
            if target == "/file" {
                let body = Self.bytes
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"Owned.txt\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                if self.holds {
                    connection.send(content: headers + body.prefix(2), completion: .contentProcessed { _ in })
                    self.held.append((connection, Data(body.dropFirst(2))))
                } else { self.send(headers + (self.fails ? Data(body.prefix(2)) : body), connection) }
                return
            }
            let body = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><link rel=icon href=data:,><title>Owned download source</title><style>body{font:20px system-ui;padding:70px 20px;background:#ddf4ff}a,button{display:block;padding:16px;margin:16px 0}</style><h1 id=part>Owned actual source</h1><a id=fragment href=#part>Actual fragment</a><a id=file href=/file>Download actual file</a><a id=pdf href=/doc.pdf>Actual PDF</a><a id=pdfwindow href=/doc.pdf target=_blank>Actual PDF window</a><button id=touch onclick=\"window.actions=(window.actions||0)+1;document.getElementById('result').textContent='Page action '+window.actions\">Page action</button><output id=result>Ready</output><form id=post method=post action=/answer.txt><input type=hidden name=q value=1></form>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.send(Data(response.utf8), connection)
        }
    }
}

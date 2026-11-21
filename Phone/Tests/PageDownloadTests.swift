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
        XCTAssertEqual(store.flash, broken.id, "the line says Failed for a moment")
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
        XCTAssertNil(store.flash, "nothing is said while Yab is away")
        XCTAssertEqual(try bytes(try XCTUnwrap(store.entry(job.id))), DownloadSite.bytes)
        pages.appDidBecomeActive()
        try await require { self.store.flash == job.id }
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
        XCTAssertNil(store.flash, "still locked: nothing private shows")
        pages.setPageInteractionsEnabled(true)
        try await require { self.store.flash == job.id }
    }
}

private final class DownloadSite: @unchecked Sendable {
    struct Request { let target: String; let header: String }
    static let bytes = Data("Owned actual download café+tea\n".utf8)
    /// A PDF the page shows inline, no attachment: one empty page.
    static let pdf = Data("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8)
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
            if target == "/doc.pdf" {
                let body = Self.pdf
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                self.send(headers + body, connection)
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
            let body = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><link rel=icon href=data:,><title>Owned download source</title><style>body{font:20px system-ui;padding:70px 20px;background:#ddf4ff}a,button{display:block;padding:16px;margin:16px 0}</style><h1 id=part>Owned actual source</h1><a id=fragment href=#part>Actual fragment</a><a id=file href=/file>Download actual file</a><a id=pdf href=/doc.pdf>Actual PDF</a><button id=touch onclick=\"window.actions=(window.actions||0)+1;document.getElementById('result').textContent='Page action '+window.actions\">Page action</button><output id=result>Ready</output>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.send(Data(response.utf8), connection)
        }
    }
}

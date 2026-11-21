import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Exercises the native inset API that threw in the physical swipe crash.
@MainActor
final class PageViewportTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?

    override func setUp() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        previousKey?.makeKey()
    }

    func testEmptyHostPreparesNewPagesBeforeActivation() throws {
        for isPrivate in [false, true] {
            let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
            let host = try XCTUnwrap(window.rootViewController?.view)
            let container = PageContainer(frame: host.bounds)
            container.pool = pool
            container.fixturesEnabled = false
            host.addSubview(container)
            defer { container.removeFromSuperview() }
            for folded in [false, true] {
                container.chrome = .init(folded: folded, hasNow: true, visible: true)
                // PageHost prepares the pool before asking it for the next page.
                container.updateViewport()
                let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")),
                                               id: "viewport.new.\(isPrivate).\(folded)", isPrivate: isPrivate)
                let view = pool.activate(tab)
                defer { pool.forget(tab.id) }
                let expected = PageViewport(size: container.bounds.size, hardware: window.safeAreaInsets,
                                            chrome: container.chrome)
                XCTAssertNil(view.superview)
                XCTAssertEqual(view.frame.size, expected.size)
                assertInsets(view, expected: expected)
            }
        }
    }

    /// A real page's own width beside a Duo's status column: under it, the
    /// site's top-right controls stood beneath the camera (#989).
    func testPageLaysOutBesideAStatusColumn() async throws {
        let host = try XCTUnwrap(window.rootViewController?.view)
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")), id: "viewport.width", isPrivate: false)
        defer { pool.forget(tab.id) }
        let view = pool.activate(tab)
        view.frame = host.bounds
        host.addSubview(view)
        defer { view.removeFromSuperview() }
        PageViewport(size: view.bounds.size, hardware: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84),
                     chrome: .init(folded: false, hasNow: false, visible: true)).apply(to: view)
        XCTAssertEqual(view.obscuredContentInsets.right, 84)
        XCTAssertEqual(view.scrollView.contentInset.right, 84)
        XCTAssertEqual(view.scrollView.verticalScrollIndicatorInsets.right, 84)
        XCTAssertFalse(view.scrollView.automaticallyAdjustsScrollIndicatorInsets)
        view.loadHTMLString("<!doctype html><title>ready</title><meta name=viewport content='width=device-width'><body>", baseURL: nil)
        var width: CGFloat = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let title = try? await view.evaluateJavaScript("document.title") as? String
            if title == "ready", let inner = try? await view.evaluateJavaScript("innerWidth") as? CGFloat { width = inner; break }
        }
        XCTAssertEqual(width, host.bounds.width - 84)
    }

    /// The scroll bar on a Duo's cover stood a third of the way in (#1945):
    /// UIKit added the window's column to indicator insets that had it
    /// already. A real safe area at the right, as the cover's column is,
    /// and the bar measured where UIKit draws it.
    func testScrollIndicatorStandsBesideTheStatusColumnOnce() async throws {
        let controller = UIViewController()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)
        window.rootViewController = controller
        window.layoutIfNeeded()
        let host = try XCTUnwrap(controller.view)
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")), id: "viewport.indicator", isPrivate: false)
        defer { pool.forget(tab.id) }
        let view = pool.activate(tab)
        view.frame = host.bounds
        host.addSubview(view)
        defer { view.removeFromSuperview() }
        view.layoutIfNeeded()
        let column = window.safeAreaInsets.right + 84
        XCTAssertEqual(view.safeAreaInsets.right, column, "the column must be a real safe area for UIKit to add it")
        let viewport = PageViewport(size: view.bounds.size,
                                    hardware: UIEdgeInsets(top: window.safeAreaInsets.top, left: window.safeAreaInsets.left,
                                                           bottom: window.safeAreaInsets.bottom, right: column),
                                    chrome: .init(folded: false, hasNow: false, visible: true))
        viewport.apply(to: view)
        view.loadHTMLString("""
            <!doctype html><meta name=viewport content='width=device-width,viewport-fit=cover'><title>tall</title>
            <style>body{margin:0;height:6000px}#probe{position:fixed;top:0;left:0;padding-right:env(safe-area-inset-right)}</style>
            <div id=probe></div>
            """, baseURL: nil)
        var tall = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let title = try? await view.evaluateJavaScript("document.title") as? String
            if title == "tall", view.scrollView.contentSize.height > view.bounds.height * 2 { tall = true; break }
        }
        XCTAssertTrue(tall, "a page tall enough to scroll")
        // The site lays out beside the column, so it has no column left to
        // pad for: a site reading env() is not inset twice.
        let inner = try await view.evaluateJavaScript("innerWidth") as? CGFloat
        XCTAssertEqual(inner, view.bounds.width - column)
        let env = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('probe')).paddingRight") as? String
        XCTAssertEqual(env, "0px")
        view.scrollView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        view.scrollView.flashScrollIndicators()
        view.scrollView.layoutIfNeeded()
        func indicators(in root: UIView) -> [UIView] {
            root.subviews.flatMap { sub in
                (String(describing: type(of: sub)).contains("ScrollIndicator") ? [sub] : []) + indicators(in: sub)
            }
        }
        let found = indicators(in: view.scrollView)
        let bar = try XCTUnwrap(found.first { $0.bounds.height > $0.bounds.width },
                                "no vertical indicator among \(view.scrollView.subviews.map { String(describing: type(of: $0)) })")
        let frame = bar.convert(bar.bounds, to: view)
        let gap = view.bounds.maxX - frame.maxX
        // UIKit keeps a few points between the bar and its inset edge.
        XCTAssertGreaterThanOrEqual(gap, column - 0.5, "the bar stands under the column: \(frame)")
        XCTAssertLessThan(gap, column + 12, "the column counted twice: the bar \(gap) points from the edge")
    }

    func testRetiringPortraitHostCannotResizeTheMountedLandscapePage() async throws {
        let saved = ChromeGeometry.extraSides
        ChromeGeometry.extraSides = .zero
        defer { ChromeGeometry.extraSides = saved }
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")), id: "viewport.rotation", isPrivate: false)
        defer { pool.forget(tab.id) }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let retiring = PageContainer(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        let visible = PageContainer(frame: CGRect(x: 0, y: 0, width: 678, height: 466))
        for host in [retiring, visible] {
            host.fixturesEnabled = false
            host.pool = pool
            root.addSubview(host)
        }
        defer { retiring.removeFromSuperview(); visible.removeFromSuperview() }
        ChromeGeometry.extraSides = .init(left: 0, right: 84)
        let web = pool.activate(tab)
        retiring.show(web)
        web.loadHTMLString("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>rotation ready</title><body>", baseURL: nil)
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await web.evaluateJavaScript("document.title") as? String) == "rotation ready" {
                loaded = true
                break
            }
        }
        XCTAssertTrue(loaded, "rotate an already loaded document")
        visible.show(web)
        for folded in [false, true] {
            for left in [false, true, false] {
                ChromeGeometry.extraSides = .init(left: left ? 84 : 0, right: left ? 0 : 84)
                visible.chrome = .init(folded: folded, hasNow: false, visible: true)
                visible.updateViewport()
                // A retiring SwiftUI host can publish after its replacement
                // mounted the retained page, without getting another layout.
                retiring.updateViewport()
                XCTAssertEqual(web.frame, visible.bounds)
                let expected = visible.bounds.width - web.obscuredContentInsets.left - web.obscuredContentInsets.right
                var width: CGFloat = 0
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(50))
                    if let value = try? await web.evaluateJavaScript("innerWidth") as? CGFloat { width = value }
                    if abs(width - expected) < 1 { break }
                }
                XCTAssertEqual(width, expected, accuracy: 1)
            }
        }
    }

    private final class StatusColumnWindow: UIWindow {
        var reportedInsets = UIEdgeInsets.zero
        override var safeAreaInsets: UIEdgeInsets { reportedInsets }
    }

    func testFixtureCapturesApplyStatusColumnInsets() throws {
        let saved = ChromeGeometry.extraSides
        ChromeGeometry.extraSides = .zero
        defer { ChromeGeometry.extraSides = saved }
        let columnWindow = window.windowScene.map { StatusColumnWindow(windowScene: $0) }
            ?? StatusColumnWindow(frame: window.bounds)
        columnWindow.frame = window.bounds
        columnWindow.rootViewController = UIViewController()
        columnWindow.makeKeyAndVisible()
        defer { columnWindow.isHidden = true; window.makeKeyAndVisible() }
        let host = try XCTUnwrap(columnWindow.rootViewController?.view)
        for left in [false, true] {
            columnWindow.reportedInsets = UIEdgeInsets(top: 0, left: left ? 84 : 0,
                                                       bottom: 34, right: left ? 0 : 84)
            let container = PageContainer(frame: host.bounds)
            container.fixturesEnabled = true
            host.addSubview(container)
            defer { container.removeFromSuperview() }
            let web = WKWebView(frame: container.bounds)
            container.show(web)
            container.updateViewport()
            // The page and its indicators stand beside the column.
            XCTAssertEqual(web.obscuredContentInsets.left, left ? 84 : 0)
            XCTAssertEqual(web.obscuredContentInsets.right, left ? 0 : 84)
            XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets.left, left ? 84 : 0)
            XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets.right, left ? 0 : 84)
            XCTAssertEqual(web.scrollView.verticalScrollIndicatorInsets.bottom, web.obscuredContentInsets.bottom)
        }
    }

    func testBothSplitPanesTakeOnlyTheirOwnColumnDuringPageSwipes() throws {
        let saved = ChromeGeometry.extraSides
        defer { ChromeGeometry.extraSides = saved }
        let host = try XCTUnwrap(window.rootViewController?.view)
        let half = host.bounds.width / 2
        // A Duo's column on either side, then a notch's two sides.
        for (columnLeft, columnRight) in [(CGFloat(0), CGFloat(84)), (84, 0), (62, 62)] {
            ChromeGeometry.extraSides = .init(left: columnLeft - window.safeAreaInsets.left,
                                              right: columnRight - window.safeAreaInsets.right)
            for second in [false, true] {
                let pane = CGRect(x: second ? half : 0, y: 0, width: half, height: host.bounds.height)
                let container = PageContainer(frame: pane)
                container.windowPane = pane
                container.fixturesEnabled = false
                let web = WKWebView(frame: container.bounds)
                host.addSubview(container)
                defer { container.removeFromSuperview() }
                container.show(web)
                let left = second ? 0 : columnLeft, right = second ? columnRight : 0
                for offset: CGFloat in [0, 60, -60, 416, -416, 0] {
                    container.transform = CGAffineTransform(translationX: offset, y: 0)
                    container.updateViewport()
                    let insets = web.obscuredContentInsets
                    // The page stays inside a column as inside a notch.
                    XCTAssertEqual(insets.left, left, accuracy: 0.01)
                    XCTAssertEqual(insets.right, right, accuracy: 0.01)
                    let indicators = web.scrollView.verticalScrollIndicatorInsets
                    XCTAssertEqual(indicators.left, left, accuracy: 0.01)
                    XCTAssertEqual(indicators.right, right, accuracy: 0.01)
                }
            }
        }
    }

    func testSwitchingTabsAppliesCurrentInsetsBeforeAttachment() throws {
        for isPrivate in [false, true] {
            let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let previous = PageFixtures.liveTab(for: url, id: "viewport.previous", isPrivate: isPrivate)
            let next = PageFixtures.liveTab(for: url, id: "viewport.next", isPrivate: isPrivate)
            defer { pool.forget(previous.id); pool.forget(next.id) }
            let host = try XCTUnwrap(window.rootViewController?.view)
            let container = PageContainer(frame: host.bounds)
            container.pool = pool
            container.fixturesEnabled = false
            host.addSubview(container)
            defer { container.removeFromSuperview() }
            let view = ViewportAttachmentView(frame: host.bounds, configuration: pool.configurationForPage(for: next))
            view.scrollView.contentInsetAdjustmentBehavior = .never
            XCTAssertTrue(pool.adopt(view, for: next))
            let store = view.configuration.websiteDataStore
            var attachments = 0
            for folded in [false, true, false] {
                container.show(pool.activate(previous))
                container.chrome = .init(folded: folded, hasNow: true, visible: true)
                container.updateViewport()
                let expected = PageViewport(size: container.bounds.size, hardware: window.safeAreaInsets,
                                            chrome: container.chrome)
                // A companion can overwrite this page while the pool's cached
                // viewport still matches the selected host exactly.
                PageViewport(size: expected.size, hardware: .zero,
                             chrome: .init(folded: false, hasNow: false, visible: false)).apply(to: view)
                view.frame.size = CGSize(width: 30, height: 40)
                view.onAttach = { page in
                    attachments += 1
                    XCTAssertEqual(page.frame, container.bounds)
                    self.assertInsets(page, expected: expected)
                }
                container.show(pool.activate(next))
                view.onAttach = nil
                assertInsets(view, expected: expected)
                container.layoutIfNeeded()
                container.updateViewport()
                assertInsets(view, expected: expected)
                XCTAssertEqual(pool.front, next.id)
                XCTAssertTrue(view.configuration.websiteDataStore === store)
            }
            XCTAssertEqual(attachments, 3, "each switch must be checked before the web view joins its host")
        }
    }

    func testPublicAndPrivatePageTranslationDoesNotBecomeAHardwareInset() throws {
        for isPrivate in [false, true] {
            let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
            let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: "about:blank")),
                                           id: isPrivate ? "paging.private" : "paging.public", isPrivate: isPrivate)
            let view = pool.activate(tab)
            defer { pool.forget(tab.id) }
            let store = view.configuration.websiteDataStore
            let host = try XCTUnwrap(window.rootViewController?.view)
            let container = PageContainer(frame: host.bounds)
            container.pool = pool
            container.fixturesEnabled = false
            host.addSubview(container)
            defer { container.removeFromSuperview() }
            container.show(view)
            window.layoutIfNeeded()
            let left = view.obscuredContentInsets.left, right = view.obscuredContentInsets.right
            // A committed swipe travels 416 points across a 402-point window.
            // Short, reversed and interrupted positions must also stay usable.
            for folded in [false, true, false] {
                container.chrome.folded = folded
                for x in [CGFloat(60), -60, 416, -416, 600, -600, 0] {
                    container.transform = CGAffineTransform(translationX: x, y: 0)
                    // What PageHost does once per update.
                    container.updateViewport()
                    container.layoutIfNeeded()
                    XCTAssertEqual(view.obscuredContentInsets.left, left, accuracy: 0.01)
                    XCTAssertEqual(view.obscuredContentInsets.right, right, accuracy: 0.01)
                    assertUsable(view)
                    XCTAssertEqual(pool.front, tab.id)
                    XCTAssertTrue(view.configuration.websiteDataStore === store)
                    XCTAssertTrue(view.superview === container)
                }
            }
        }
    }

    func testLateNeighborUpdatesCannotTakeTheSelectedPageFromItsHost() throws {
        for isPrivate in [false, true] {
            let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
            let url = try XCTUnwrap(URL(string: "about:blank"))
            let current = PageFixtures.liveTab(for: url, id: "owner.current", isPrivate: isPrivate)
            let next = PageFixtures.liveTab(for: url, id: "owner.next", isPrivate: isPrivate)
            defer { pool.forget(current.id); pool.forget(next.id) }
            let host = try XCTUnwrap(window.rootViewController?.view)
            let container = PageContainer(frame: host.bounds)
            container.pool = pool
            container.fixturesEnabled = false
            host.addSubview(container)
            defer { container.removeFromSuperview() }
            container.show(pool.activate(current))
            let neighbor = NeighborSlot(frame: host.bounds)
            host.addSubview(neighbor)
            defer { neighbor.removeFromSuperview() }
            let nextView = pool.warm(next)
            let store = nextView.configuration.websiteDataStore
            neighbor.show(next, pool: pool)
            XCTAssertTrue(nextView.superview === neighbor)
            container.show(pool.activate(next))
            XCTAssertTrue(nextView.superview === container)
            // UIViewRepresentable may update the outgoing neighbor once more
            // after the selected page has moved into its primary host.
            neighbor.show(next, pool: pool)
            neighbor.layoutIfNeeded()
            neighbor.letGo()
            XCTAssertTrue(nextView.superview === container)
            XCTAssertEqual(nextView.frame, container.bounds)
            XCTAssertEqual(pool.front, next.id)
            XCTAssertTrue(nextView.configuration.websiteDataStore === store)
        }
    }

    func testPageHostReattachesTheSameSelectedViewIfItWasMoved() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: window.bounds, configuration: configuration)
        let container = PageContainer(frame: window.bounds)
        let temporary = UIView(frame: window.bounds)
        let host = try XCTUnwrap(window.rootViewController?.view)
        host.addSubview(container)
        host.addSubview(temporary)
        defer { container.removeFromSuperview(); temporary.removeFromSuperview() }
        container.show(view)
        temporary.addSubview(view)
        XCTAssertTrue(view.superview === temporary)
        container.show(view)
        XCTAssertTrue(view.superview === container)
        XCTAssertEqual(view.frame, container.bounds)
    }

    func testInsetApplicationFitsSmallFramesAndRetainsOrdinaryValues() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), configuration: configuration)
        let ordinary = PageViewport(size: view.frame.size, hardware: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                                    chrome: .init(folded: false, hasNow: true, visible: true))
        ordinary.apply(to: view)
        XCTAssertEqual(view.minimumViewportInset, ordinary.minimum)
        XCTAssertEqual(view.maximumViewportInset, ordinary.maximum)
        XCTAssertEqual(view.obscuredContentInsets, ordinary.current)
        view.frame.size = CGSize(width: 30, height: 40)
        ordinary.apply(to: view)
        assertUsable(view)
        XCTAssertEqual(view.scrollView.contentInset, view.obscuredContentInsets)
        view.frame.size = ordinary.size
        ordinary.apply(to: view)
        XCTAssertEqual(view.obscuredContentInsets, ordinary.current)
        assertUsable(view)
    }

    func testEmptyFrameDefersInsetsUntilThereIsARealViewport() {
        let view = WKWebView(frame: .zero)
        let viewport = PageViewport(size: CGSize(width: 402, height: 874),
                                    hardware: UIEdgeInsets(top: 62, left: 1000, bottom: 34, right: 1000),
                                    chrome: .init(folded: true, hasNow: false, visible: true))
        viewport.apply(to: view)
        XCTAssertEqual(view.maximumViewportInset, .zero)
        view.frame.size = viewport.size
        viewport.apply(to: view)
        assertUsable(view)
    }

    private func assertInsets(_ view: WKWebView, expected: PageViewport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(view.minimumViewportInset, expected.minimum, file: file, line: line)
        XCTAssertEqual(view.maximumViewportInset, expected.maximum, file: file, line: line)
        XCTAssertEqual(view.obscuredContentInsets, expected.current, file: file, line: line)
        XCTAssertEqual(view.scrollView.contentInset, expected.current, file: file, line: line)
        XCTAssertEqual(view.scrollView.verticalScrollIndicatorInsets, expected.current, file: file, line: line)
    }

    private func assertUsable(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        for inset in [view.minimumViewportInset, view.maximumViewportInset, view.obscuredContentInsets] {
            XCTAssertLessThan(inset.left + inset.right, view.frame.width, file: file, line: line)
            XCTAssertLessThan(inset.top + inset.bottom, view.frame.height, file: file, line: line)
            XCTAssertGreaterThanOrEqual(min(inset.top, min(inset.left, min(inset.bottom, inset.right))), 0, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(view.minimumViewportInset.top + view.minimumViewportInset.bottom,
                                 view.maximumViewportInset.top + view.maximumViewportInset.bottom, file: file, line: line)
        XCTAssertLessThanOrEqual(view.minimumViewportInset.left + view.minimumViewportInset.right,
                                 view.maximumViewportInset.left + view.maximumViewportInset.right, file: file, line: line)
    }
}

@MainActor
private final class ViewportAttachmentView: WKWebView {
    var onAttach: ((WKWebView) -> Void)?

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview is PageContainer { onAttach?(self) }
        super.willMove(toSuperview: newSuperview)
    }
}

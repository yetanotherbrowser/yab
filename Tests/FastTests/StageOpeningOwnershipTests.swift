import AppKit
import Testing
import WebKit
@testable import Fast

/// Actual Stage.show transitions, with two independent native windows and
/// nonpersistent WK views. No Browser, sign-in store, extensions, provider,
/// external URL, clipboard or user input is needed.
@MainActor
@Suite(.serialized)
struct StageOpeningOwnershipTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    @MainActor
    private final class Surface {
        let stage: StageView
        let window: NSWindow
        let previous: NSView
        let previousID = UUID()

        init() {
            let frame = NSRect(x: 0, y: 0, width: 420, height: 300)
            stage = StageView(frame: frame)
            stage.wantsLayer = true
            previous = NSView(frame: frame)
            previous.wantsLayer = true
            window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 420, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = stage
            // Attachment, not a visible/key window, is enough to exercise
            // Stage.show's real mounting and previous-surface ownership.
            stage.show(previous, of: previousID)
        }

        func close() {
            stage.show(nil)
            window.contentView = nil
            window.close()
        }
    }

    private static var kept: [WKWebView] = []

    private func web() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The app's pool, as every Yab web view has (Web.pool): a fresh
        // configuration's own pool dies with these views.
        configuration.processPool = Web.pool
        // Match the app's nonblocking mount configuration without creating
        // Browser, extension or sign-in state. Ownership does not depend
        // on this private configuration being supported.
        PagePaint.configure(configuration)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 300), configuration: configuration)
        web.wantsLayer = true
        // Kept for the rest of the run. These pages were shown in a window
        // and let go at once; WebKit then tore their process down while
        // its display link still called it, and the test process crashed
        // a suite later on the display link's thread (EXC_BAD_ACCESS in
        // DisplayLink::notifyObserversDisplayDidRefresh, or a trap in
        // ~DisplayLink with a fresh pool): SteadyMenuTests on macOS 26,
        // 0.43.2's QA batch, 500 tests after it never ran.
        Self.kept.append(web)
        return web
    }

    /// Every mutation of the production static markers is synchronous, with
    /// no await while this snapshot is installed. All owned stage cleanup
    /// happens before restoring the original set.
    private func isolated(_ body: () throws -> Void) rethrows {
        let saved = StageView.benchOpenings
        StageView.benchOpenings = [:]
        defer { StageView.benchOpenings = saved }
        try body()
    }

    private func expectImmediate(_ surface: Surface, _ web: WKWebView, owner: UUID) {
        surface.stage.show(web, of: owner)
        #expect(web.superview === surface.stage)
        #expect(web.window === surface.window)
        #expect(surface.previous.superview == nil)
        #expect(web.layer?.opacity == 1)
        #expect(surface.stage.benchGeometry()["awaiting"] as? Bool == false)
    }

    @Test(arguments: [false, true])
    func twoWindowsKeepTheirOwnOpeningInEitherShowOrder(reverse: Bool) throws {
        try isolated {
            let first = Surface(), second = Surface(), firstWeb = web(), secondWeb = web()
            defer { first.close(); second.close(); firstWeb.stopLoading(); secondWeb.stopLoading() }
            try #require(first.stage.window === first.window && second.stage.window === second.window)
            let firstID = UUID(), secondID = UUID()
            StageView.willOpen(firstID)
            StageView.willOpen(secondID)
            #expect(StageView.opensAtOnce(firstID))
            #expect(StageView.opensAtOnce(secondID))
            if reverse {
                expectImmediate(second, secondWeb, owner: secondID)
                #expect(StageView.opensAtOnce(firstID))
                expectImmediate(first, firstWeb, owner: firstID)
            } else {
                expectImmediate(first, firstWeb, owner: firstID)
                #expect(StageView.opensAtOnce(secondID))
                expectImmediate(second, secondWeb, owner: secondID)
            }
            #expect(StageView.benchOpenings.isEmpty)
        }
    }

    @Test func nilAndUnrelatedOwnersCannotConsumeAnotherTabsOpening() {
        isolated {
            let unrelated = Surface(), actual = Surface(), unrelatedWeb = web(), actualWeb = web()
            defer { unrelated.close(); actual.close(); unrelatedWeb.stopLoading(); actualWeb.stopLoading() }
            let owner = UUID()
            StageView.willOpen(owner)
            unrelated.stage.show(NSView(frame: unrelated.stage.bounds), of: nil)
            #expect(StageView.opensAtOnce(owner))
            unrelated.stage.show(unrelatedWeb, of: UUID())
            #expect(StageView.opensAtOnce(owner))
            expectImmediate(actual, actualWeb, owner: owner)
            #expect(!StageView.opensAtOnce(owner))
        }
    }

    @Test func matchingNonWebPageConsumesOnlyItsOwnMarker() {
        isolated {
            let invalid = Surface(), actual = Surface(), actualWeb = web()
            defer { invalid.close(); actual.close(); actualWeb.stopLoading() }
            let invalidID = UUID(), owner = UUID()
            StageView.willOpen(invalidID)
            StageView.willOpen(owner)
            invalid.stage.show(NSView(frame: invalid.stage.bounds), of: invalidID)
            #expect(!StageView.opensAtOnce(invalidID))
            #expect(StageView.opensAtOnce(owner))
            expectImmediate(actual, actualWeb, owner: owner)
        }
    }

    @Test func aConsumedOpeningCannotTreatTheNextShowAsANewTab() {
        isolated {
            let surface = Surface(), firstWeb = web(), laterWeb = web(), owner = UUID()
            defer { surface.close(); firstWeb.stopLoading(); laterWeb.stopLoading() }
            StageView.willOpen(owner)
            expectImmediate(surface, firstWeb, owner: owner)
            #expect(!StageView.opensAtOnce(owner))
            surface.stage.show(surface.previous, of: surface.previousID)
            surface.stage.show(laterWeb, of: owner)
            // An ordinary switch retains the existing prior-surface policy;
            // a one-shot marker must not force future visits into a new path.
            #expect(surface.previous.superview === surface.stage)
            #expect(laterWeb.layer?.opacity == 0)
            #expect(surface.stage.benchGeometry()["awaiting"] as? Bool == true)
        }
    }

    @Test func expiredMarkersArePrunedWithoutRemovingOtherLiveOwners() {
        isolated {
            let expiredSurface = Surface(), liveSurface = Surface(), expiredWeb = web(), liveWeb = web()
            defer { expiredSurface.close(); liveSurface.close(); expiredWeb.stopLoading(); liveWeb.stopLoading() }
            let expired = UUID(), live = UUID(), now = CACurrentMediaTime()
            StageView.benchOpenings = [expired: now - 2, live: now]
            expiredSurface.stage.show(expiredWeb, of: expired)
            #expect(!StageView.opensAtOnce(expired))
            #expect(StageView.opensAtOnce(live))
            #expect(expiredSurface.previous.superview === expiredSurface.stage)
            #expect(expiredWeb.layer?.opacity == 0)
            expectImmediate(liveSurface, liveWeb, owner: live)
            #expect(StageView.benchOpenings.isEmpty)
        }
    }

    @Test func insertionPrunesOldStorageAndRefreshesOnlyTheSameOwner() {
        isolated {
            let now = CACurrentMediaTime(), owner = UUID(), other = UUID()
            StageView.benchOpenings = Dictionary(uniqueKeysWithValues: (0..<256).map { _ in (UUID(), now - 10) })
            StageView.willOpen(owner)
            #expect(Set(StageView.benchOpenings.keys) == Set([owner]))
            StageView.willOpen(other)
            StageView.willOpen(owner)
            #expect(Set(StageView.benchOpenings.keys) == Set([owner, other]))
            #expect(StageView.opensAtOnce(owner) && StageView.opensAtOnce(other))
        }
    }

    @Test func anExistingDocumentConsumesItsMarkerWithoutTakingTheNewTabPath() async throws {
        let existing = web()
        defer { existing.stopLoading() }
        existing.load(URLRequest(url: URL(string: "about:blank")!))
        // No static opening state is captured/changed across this await.
        let loaded = try await Loaded.until(5) { existing.backForwardList.currentItem != nil }
        try #require(loaded)
        isolated {
            let surface = Surface(), other = UUID(), owner = UUID()
            defer { surface.close() }
            StageView.willOpen(owner)
            StageView.willOpen(other)
            surface.stage.show(existing, of: owner)
            #expect(!StageView.opensAtOnce(owner))
            #expect(StageView.opensAtOnce(other))
            #expect(surface.previous.superview === surface.stage)
            #expect(existing.layer?.opacity == 0)
        }
    }

    /// A page whose video fills the screen, lent to WebKit's own window.
    private final class FillingScreen: WKWebView {
        override var fullscreenState: WKWebView.FullscreenState { .inFullscreen }
    }

    /// Back on the tab whose video is in its own full-screen Space, from
    /// another tab: the other tab's page goes, not left showing under this
    /// tab's name (#937).
    @Test func pickingATabWhoseVideoFillsTheScreenTakesTheOtherPageOff() {
        let surface = Surface(), other = web()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let filling = FillingScreen(frame: surface.stage.bounds, configuration: configuration)
        defer { surface.close(); other.stopLoading() }
        surface.stage.show(other, of: UUID())
        #expect(other.superview === surface.stage)
        surface.stage.show(filling, of: UUID())
        surface.stage.layout()
        #expect(other.superview == nil)
        #expect(filling.superview == nil)
    }
}

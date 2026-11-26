import AppKit
import IOSurface
import Testing
import WebKit
@testable import Fast

/// A page's last frame standing in for it while WebKit draws it again
/// (PageStills, StageView's still): when one is shown, when it is not,
/// what drops it, and what the budget keeps.
@Suite(.serialized)
@MainActor
struct PageStillsTests {
    private func key(url: String = "https://a.example/", w: CGFloat = 640, h: CGFloat = 480, scale: CGFloat = 2,
                     zoom: CGFloat = 1, dark: Bool = false, y: Double = 0) -> PageStills.Key {
        PageStills.Key(url: URL(string: url), size: CGSize(width: w, height: h), scale: scale, zoom: zoom,
                       magnification: 1, dark: dark, y: y)
    }

    // MARK: - when a still is the page

    @Test func aStillIsShownOnlyForExactlyWhatItWasDrawnFor() {
        let drawn = key()
        #expect(drawn.refusal(for: key()) == nil)
        #expect(drawn.refusal(for: key(y: 0.6)) == nil)
        #expect(drawn.refusal(for: key(url: "https://a.example/next")) == "address")
        #expect(drawn.refusal(for: key(url: "https://a.example/#part")) == "address")
        #expect(drawn.refusal(for: key(w: 600)) == "size")
        #expect(drawn.refusal(for: key(h: 481)) == "size")
        #expect(drawn.refusal(for: key(scale: 1)) == "scale")
        #expect(drawn.refusal(for: key(zoom: 1.1)) == "zoom")
        #expect(drawn.refusal(for: key(dark: true)) == "appearance")
        #expect(drawn.refusal(for: key(y: 40)) == "scroll")
    }

    // MARK: - the budget

    private func entry(_ n: Int, used: Double, mb: Int = 16, reduced: Bool = false, near: Bool = false, showing: Bool = false) -> PageStills.Entry {
        PageStills.Entry(owner: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, used: used,
                         bytes: mb << 20, reduced: reduced, near: near, showing: showing)
    }

    @Test func theMostRecentAndTheNearStayWholeTheRestAreHalved() {
        let entries = (0..<6).map { entry($0, used: Double($0)) } + [entry(9, used: -5, near: true)]
        let plan = PageStills.plan(entries, budget: 1 << 30, whole: 3)
        // 5, 4, 3 most recent, 9 near: whole. 2, 1, 0 halved.
        #expect(Set(plan.reduce) == Set([2, 1, 0].map { entries[$0].owner }))
        #expect(plan.drop.isEmpty)
    }

    @Test func overTheBudgetTheOldestGoButNeverOneOnAStage() {
        let entries = [entry(0, used: 0, showing: true), entry(1, used: 1), entry(2, used: 2), entry(3, used: 3)]
        // Whole: 3, 2 (16 MB each); 1 halved to 4 MB; 0 on a stage, 16 MB.
        let plan = PageStills.plan(entries, budget: 48 << 20, whole: 2)
        #expect(plan.drop == [entries[1].owner])
        #expect(!plan.drop.contains(entries[0].owner))
        #expect(plan.reduce.isEmpty)
    }

    @Test func aHalvedStillIsNotHalvedAgain() {
        let entries = [entry(0, used: 9), entry(1, used: 0, mb: 4, reduced: true)]
        let plan = PageStills.plan(entries, budget: 1 << 30, whole: 1)
        #expect(plan.reduce.isEmpty)
    }

    @Test func theBudgetIsAShareOfMemoryBetweenBounds() {
        #expect(PageStills.budget(memory: 4 << 30) == 48 << 20)
        #expect(PageStills.budget(memory: 16 << 30) == (16 << 30) / 96)
        #expect(PageStills.budget(memory: 64 << 30) == 256 << 20)
    }

    // MARK: - surfaces

    @Test func aStillIsDrawnUprightInEightBitsAndHalvedToAQuarter() throws {
        // Top half red, bottom half blue, in extended range half floats, as
        // WebKit hands its pictures back.
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        let picture = try #require(context.makeImage())
        let surface = try #require(PageStills.surface(from: picture, pixels: CGSize(width: 64, height: 64)))
        #expect(surface.width == 64 && surface.height == 64)
        // Row 0 of the surface is the top of the page: red. BGRA in memory.
        func pixel(_ s: IOSurface, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            _ = s.lock(options: .readOnly, seed: nil)
            defer { _ = s.unlock(options: .readOnly, seed: nil) }
            let p = s.baseAddress.advanced(by: y * s.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            return (p[2], p[1], p[0])
        }
        let top = pixel(surface, x: 32, y: 4), bottom = pixel(surface, x: 32, y: 60)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
        let half = try #require(PageStills.halve(surface, to: CGSize(width: 32, height: 32)))
        #expect(half.width == 32 && half.height == 32)
        #expect(half.allocationSize <= surface.allocationSize / 3)
        let halfTop = pixel(half, x: 16, y: 2)
        #expect(halfTop.r > 200 && halfTop.b < 60)
    }

    // MARK: - on the stage

    private final class Busy: NSObject, WKScriptMessageHandler {
        var started = false
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { started = true }
    }

    @MainActor
    private final class Scene {
        let window: NSWindow
        let stage: StageView
        let busy = Busy()
        private var pages: [PageView] = []

        /// Pages ended as a tab ends them (`Tab.end`), out of the window,
        /// before it closes: web views let go with the window while
        /// WebKit's display link still had them crashed the test process
        /// in WebKit's DisplayLink (twice on adhd, once on renderer-2).
        func end() {
            for page in pages {
                page.stopLoading()
                page.removeFromSuperview()
                Tab.end(page)
            }
            pages = []
            window.orderOut(nil)
            window.close()
        }

        init() {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            stage = StageView(frame: frame)
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = stage
            // Layer-backed now, as WebStage's update makes it (`round`)
            // before its first show. Left to AppKit, the stage has no layer
            // until the window's next display, which a main thread kept
            // busy by the other suites put off past the show: no still went
            // up for want of a layer to put it on (m4 and adhd, N-Z shard).
            stage.wantsLayer = true
            window.orderFront(nil)
        }

        func page(_ color: String) -> PageView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(busy, name: "stillBusy")
            _ = PagePaint.configure(configuration)
            let web = PageView(frame: stage.bounds, configuration: configuration)
            web.loadHTMLString("<body style='margin:0;background:\(color);height:3000px'><script>window.token='kept'</script></body>",
                               baseURL: URL(string: "https://\(color.replacingOccurrences(of: "#", with: "")).example/"))
            pages.append(web)
            return web
        }
    }

    /// Generous deadlines: these run beside builds and other suites, where
    /// a page's first load or its picture can take seconds.
    private func loaded(_ web: WKWebView) async throws {
        if try await Loaded.until(30, every: .milliseconds(25), {
            (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!window.token")) as? Bool == true
        }) { return }
        Issue.record("the page did not load")
    }

    private func until(_ seconds: Double = 20, _ condition: () -> Bool) async throws {
        _ = try await Loaded.until(seconds) { condition() }
    }

    private func held(_ owner: UUID, _ web: WKWebView, on stage: StageView) -> Bool {
        PageStills.shared.has(owner, matching: PageStills.key(web, on: stage))
    }

    /// A busy page comes back as its own last frame at once, not as the
    /// page left, and is itself the moment WebKit has drawn it. The click
    /// meanwhile is the stage's, never the still's.
    @Test func aBusyPageComesBackAsItsLastFrameThenLive() async throws {
        PageStills.on = true
        PageStills.shared.forgetAll()
        let scene = Scene()
        defer { scene.end() }
        let a = scene.page("#20b060"), b = scene.page("#2040c0")
        let ida = UUID(), idb = UUID()
        scene.stage.show(a, of: ida)
        try await loaded(a)
        scene.stage.show(b, of: idb)
        try await loaded(b)
        // Leaving a pictured it.
        try await until { held(ida, a, on: scene.stage) }
        #expect(held(ida, a, on: scene.stage))
        try await until { a.window == nil }
        #expect(a.window == nil)

        let blocked = Task {
            try await a.evaluateJavaScript("window.webkit.messageHandlers.stillBusy.postMessage(1); const end=performance.now()+900; while(performance.now()<end){}; true") as? Bool
        }
        try await until { scene.busy.started }
        #expect(scene.busy.started)
        let shown = CACurrentMediaTime(), punctual = Punctuality()
        defer { punctual.stop() }
        // Said when it fails: whether the still was there just before, and
        // why the stage was given none (PageStills' misses).
        let stood = held(ida, a, on: scene.stage), asked = CACurrentMediaTime()
        scene.stage.show(a, of: ida)
        let still = scene.stage.showsStill
        let staged = StageView.trace.filter { ($0["t"] as? Double ?? 0) >= asked }
        #expect(still, "held just before: \(stood); the stage: \(staged), its layer \(scene.stage.layer != nil), in its window \(scene.stage.window === scene.window), the window visible \(scene.window.isVisible); \(PageStills.shared.report)")
        #expect(a.layer?.opacity == 0)
        let center = scene.stage.convert(NSPoint(x: 320, y: 240), to: scene.stage.superview)
        #expect(scene.stage.hitTest(center) === scene.stage)
        #expect(try await blocked.value == true)
        // Drawn (or past the paint wait, on a loaded Mac): a itself, the
        // still gone, b stepped off.
        try await until { !scene.stage.showsStill && a.layer?.opacity == 1 && b.superview == nil }
        #expect(!scene.stage.showsStill)
        #expect(a.layer?.opacity == 1)
        #expect(b.superview == nil)
        // How soon, only where the Mac kept time meanwhile.
        if punctual.held(0.5) { #expect(CACurrentMediaTime() - shown < StageView.paintWait + 3) }
        let hit = try #require(scene.stage.hitTest(center))
        #expect(hit === a || hit.isDescendant(of: a))
        #expect(try await a.evaluateJavaScript("window.token") as? String == "kept")
    }

    /// Gone somewhere else, made another size, scrolled or turned dark:
    /// no still, the page comes in as before.
    @Test(arguments: ["navigate", "resize", "scroll", "dark", "light", "forget", "pressure"])
    func aStillThatIsNoLongerThePageIsNotShown(_ change: String) async throws {
        PageStills.on = true
        PageStills.shared.forgetAll()
        let scene = Scene()
        defer { scene.end() }
        // Both appearance transitions must change the captured key, regardless
        // of the worker's system appearance when this fixture starts.
        if change == "dark" { scene.window.appearance = NSAppearance(named: .aqua) }
        if change == "light" { scene.window.appearance = NSAppearance(named: .darkAqua) }
        let a = scene.page("#20b060"), b = scene.page("#2040c0")
        let ida = UUID(), idb = UUID()
        scene.stage.show(a, of: ida)
        try await loaded(a)
        scene.stage.show(b, of: idb)
        try await loaded(b)
        try await until { held(ida, a, on: scene.stage) }
        try #require(held(ida, a, on: scene.stage))
        switch change {
        case "navigate":
            // What Tab.navigationCommitted does for a page's new document.
            a.loadHTMLString("<body style='background:#c02020'><script>window.token='kept'</script></body>", baseURL: URL(string: "https://20b060.example/next"))
            try await loaded(a)
            PageStills.shared.forget(ida)
        case "resize":
            scene.window.setContentSize(NSSize(width: 600, height: 480))
            scene.stage.frame = NSRect(x: 0, y: 0, width: 600, height: 480)
        case "scroll":
            a.scrollTop = 400
        case "dark":
            scene.window.appearance = NSAppearance(named: .darkAqua)
        case "light":
            scene.window.appearance = NSAppearance(named: .aqua)
        case "forget":
            PageStills.shared.forget(ida)
        default:
            PageStills.shared.relieve(critical: true)
        }
        scene.stage.show(a, of: ida)
        #expect(!scene.stage.showsStill)
    }

    /// A page left for another keeps its last frame for Back (BACK_STILLS),
    /// under its history entry's owner, only if that frame is the page as
    /// it was left: one drawn before a scroll it missed is not kept.
    @Test(arguments: [false, true])
    func aPageLeftKeepsItsLastFrameForBackOnlyAsItWasLeft(_ scrolled: Bool) async throws {
        PageStills.on = true
        PageStills.shared.forgetAll()
        let scene = Scene()
        defer { scene.end() }
        let a = scene.page("#20b060"), b = scene.page("#2040c0")
        let ida = UUID(), idb = UUID()
        scene.stage.show(a, of: ida)
        try await loaded(a)
        scene.stage.show(b, of: idb)
        try await loaded(b)
        try await until { held(ida, a, on: scene.stage) }
        try #require(held(ida, a, on: scene.stage))
        var left = PageStills.key(a, on: scene.stage)
        left.url = URL(string: "https://elsewhere.example/")
        if scrolled { left.y += 400 }
        let entry = UUID()
        PageStills.shared.move(ida, to: entry, like: left)
        if scrolled {
            #expect(PageStills.shared.kept(entry) == nil)
            #expect(held(ida, a, on: scene.stage))
        } else {
            let kept = try #require(PageStills.shared.kept(entry))
            #expect(kept.key.url == a.url)
            #expect(!held(ida, a, on: scene.stage))
        }
        PageStills.shared.forgetAll()
    }

    /// A picture asked for before its page went elsewhere is dropped when
    /// it comes back, never kept for the new document.
    @Test func aPictureOnItsWayWhenThePageGoesIsDropped() async throws {
        PageStills.on = true
        PageStills.shared.forgetAll()
        let scene = Scene()
        defer { scene.end() }
        let a = scene.page("#20b060")
        let ida = UUID()
        scene.stage.show(a, of: ida)
        try await loaded(a)
        PageStills.shared.take(a, owner: ida, key: PageStills.key(a, on: scene.stage), shy: true)
        PageStills.shared.forget(ida)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!held(ida, a, on: scene.stage))
    }

    /// Stills off (the bench's A/B): the page left stands in, as before.
    @Test func withStillsOffThePageLeftStandsIn() async throws {
        PageStills.on = false
        defer { PageStills.on = true }
        let scene = Scene()
        defer { scene.end() }
        let a = scene.page("#20b060"), b = scene.page("#2040c0")
        let ida = UUID(), idb = UUID()
        scene.stage.show(a, of: ida)
        try await loaded(a)
        scene.stage.show(b, of: idb)
        try await loaded(b)
        try await Task.sleep(for: .milliseconds(400))
        scene.stage.show(a, of: ida)
        #expect(!scene.stage.showsStill)
        #expect(b.superview === scene.stage)
    }

    @Test func stillsNearScopesLargeSpaceToActiveNeighborsAndRecent() {
        let browser = Browser(windowID: UUID(), purpose: .privateOnly)
        defer { browser.letGo() }
        for i in 0..<20 {
            _ = browser.open(URL(string: "https://example.test/\(i)")!, foreground: false)
        }
        #expect(browser.tabs.count == 20)
        let target = browser.tabs[10].id
        let near = browser.stillsNear(focusing: target)
        #expect(near.contains(target))
        #expect(near.contains(browser.tabs[8].id))
        #expect(near.contains(browser.tabs[9].id))
        #expect(near.contains(browser.tabs[11].id))
        #expect(near.contains(browser.tabs[12].id))
        #expect(!near.contains(browser.tabs[0].id))
        #expect(!near.contains(browser.tabs[19].id))
    }
}

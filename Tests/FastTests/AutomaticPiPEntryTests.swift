import AppKit
import Testing
import WebKit
@testable import Fast

/// Real Browser automatic entrypoints and Isolate.run callbacks on local
/// HTML. Controlled script answers test policy/ownership, not playback,
/// DRM, occlusion detection, media capture, or native system-PiP support.
@MainActor
@Suite(.serialized)
struct AutomaticPiPEntryTests {
    /// Exposes the native style-mask seam without entering an OS Space.
    @MainActor private final class FullscreenWindow: NSWindow {
        var reportsFullscreen = false
        override var styleMask: NSWindow.StyleMask {
            get { reportsFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
    }

    @MainActor private final class Fixture {
        let id = UUID()
        let browser: Browser
        let sites = AutomaticPiPSites.shared
        let savedMaster = Store.settings.object(forKey: "float.leave")
        let initialMaster: Bool
        let wasAllowed = AutomaticPiPSites.shared.allows(URL(string: "https://youtube.com/"))
        var nativeWindow: NSWindow?
        /// A picture holds its controller weakly: the fixture keeps them.
        var controllers: [NSViewController] = []

        init() {
            _ = NSApplication.shared
            let made = Browser(windowID: id)
            made.lookForMailSignInLink = {}
            initialMaster = made.prefs.floatsOnLeave
            browser = made
            browser.prefs.floatsOnLeave = true
            sites.setAllowed(true, for: URL(string: "https://youtube.com/"))
        }

        func close() {
            browser.land()
            nativeWindow?.contentView = nil
            nativeWindow?.close()
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            sites.setAllowed(wasAllowed, for: URL(string: "https://youtube.com/"))
            browser.prefs.floatsOnLeave = initialMaster
            if let savedMaster { Store.settings.set(savedMaster, forKey: "float.leave") }
            else { Store.settings.removeObject(forKey: "float.leave") }
            for prefix in ["session", "spaces"] {
                try? FileManager.default.removeItem(at: Store.file("\(prefix)-window-\(id.uuidString).json"))
            }
        }

        func page(_ token: String, host: String = "www.youtube.com") async throws -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(bench: true, configuration: configuration, factory: .webKitOnly)
            let url = URL(string: "https://\(host)/watch?v=\(token)")!
            requireNativeWebKitFixture(tab, "AutomaticPiPEntryTests").loadHTMLString("<!doctype html><title>\(token)</title><p>Local PiP policy fixture</p>", baseURL: url)
            let loaded = try await Loaded.until(12) {
                (try? await requireNativeWebKitFixture(tab, "AutomaticPiPEntryTests").evaluateJavaScript("document.title")) as? String == token && !requireNativeWebKitFixture(tab, "AutomaticPiPEntryTests").isLoading
            }
            try #require(loaded, "Local document must load before policy assertions")
            tab.setAddressOptimistically(url)
            tab.noisy = true
            browser.moveIn(tab)
            try #require(!tab.asleep)
            try await js(tab, """
                window.__policy = { on: 0, pip: 0, off: 0, automaticOn: 0, automaticPiP: 0, onPolicy: 0, pipPolicy: 0, hold: '', resolve: null };
                window.__yabFloat = {
                  on: async function(automatic) {
                    __policy.on++;
                    __policy.onPolicy = automatic;
                    if (automatic) __policy.automaticOn++;
                    if (__policy.hold === 'on') return await new Promise(r => __policy.resolve = r);
                    return ['floating', 640, 360];
                  },
                  pip: async function(automatic) {
                    __policy.pip++;
                    __policy.pipPolicy = automatic;
                    if (automatic) __policy.automaticPiP++;
                    if (__policy.hold === 'pip') return await new Promise(r => __policy.resolve = r);
                    return 'pip';
                  },
                  off: async function() { __policy.off++; return 'off'; }
                };
                """)
            return tab
        }

        @discardableResult func js(_ tab: Tab, _ script: String) async throws -> Any? {
            let web = try #require(tab.built, "No view may be materialized by observation")
            return try await web.evaluateJavaScript(script + "; true;", in: nil, contentWorld: Isolate.world)
        }

        func count(_ tab: Tab, _ verb: String) async throws -> Int {
            let web = try #require(tab.built)
            return try #require(try await web.evaluateJavaScript("window.__policy.\(verb)", in: nil, contentWorld: Isolate.world) as? Int)
        }

        func settled() async throws { try await Task.sleep(for: .milliseconds(250)) }
        func deny(_ tab: Tab) { sites.setAllowed(false, for: tab.address) }

        /// Inject only the native handoff, after the real request. This suite
        /// proves policy and ownership; FloatPiPTests proves actual playback.
        func picture(_ tab: Tab) throws -> SitePiP.Picture {
            let web = try #require(tab.built)
            nativeWindow?.contentView = nil
            nativeWindow?.close()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            nativeWindow = window
            let rect = web.convert(web.bounds, to: nil)
            let controller = NSViewController()
            controllers.append(controller)
            let picture = try #require(SitePiP.benchPicture(view: NSView(frame: rect), window: window, rect: rect, controller: controller))
            #expect(picture.controller === controller)
            return picture
        }

        func present(_ tab: Tab) throws {
            let picture = try picture(tab)
            let web = try #require(tab.built)
            browser.webView(web, hasVideoInPictureInPictureDidChange: true)
            try #require(browser.take(picture))
        }
    }

    /// Guard before any Fixture property initializer can touch Store or
    /// Browser. These tests must only run in the native runner's own world.
    private func requireWorld() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard,
                     "Use the existing native AppKit runner in a disposable world, never a user profile")
    }

    @Test func returningBeforeTheNativeHandoffRejectsItButAllowsANewManualRequest() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("return-before-pip")
        let sibling = try await f.page("return-before-pip-sibling", host: "quiet.example")
        sibling.noisy = false
        f.browser.activeID = source.id
        try await f.js(source, "__policy.hold='pip'")
        f.browser.select(sibling)
        try #require(try await Loaded.until(8) { try await f.count(source, "pip") == 1 })
        f.browser.select(source)
        let late = try f.picture(source)
        #expect(!f.browser.take(late))
        #expect(late.rejectedAutomaticDeparture)
        #expect(f.browser.floating == nil && !f.browser.floater.showing && !source.floating)
        try await f.js(source, "__policy.resolve('pip');__policy.hold=''")
        try #require(try await Loaded.until(8) { f.browser.pendingVideoRequestsForBench == 0 })
        f.browser.toggleFloat()
        try #require(try await Loaded.until(8) { try await f.count(source, "pip") == 2 })
        try f.present(source)
        #expect(f.browser.floating == source.id && !source.floating)
    }

    @Test(arguments: ["tab", "app"])
    func unlistedSitesPassTheUserStartPolicyToTheRealEntrypoint(_ departure: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("unlisted-\(departure)", host: "studio.example")
        let sibling = try await f.page("unlisted-sibling")
        try #require(!Players.knows(source.address))
        f.browser.activeID = source.id
        let verb: String
        if departure == "tab" {
            verb = "pip"
            f.browser.leavingSpace()
            f.browser.activeID = sibling.id
        } else {
            verb = "pip"
            f.browser.leftNow()
        }
        let asked = try await Loaded.until(8) { try await f.count(source, verb) == 1 }
        try #require(asked)
        #expect(try await f.count(source, verb + "Policy") == 2)
    }

    @Test(arguments: ["tab", "app"])
    func aFullscreenWindowLeftBringsItsFilmAlongAsAnyOther(_ departure: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("fullscreen-\(departure)")
        f.browser.activeID = source.id
        f.browser.fullScreen = true
        defer { f.browser.fullScreen = false }
        if departure == "tab" { f.browser.leavingSpace() }
        else { f.browser.leftNow() }
        try await f.settled()
        #expect(try await f.count(source, "pip") == 1)
        #expect(try await f.count(source, "on") == 0)
    }

    /// The desktop changes with Yab still the app in front (a three-finger
    /// swipe to an empty desktop, another Yab window going full screen):
    /// macOS posts no didResignActive, so only the desktop change can bring
    /// the film along. Back on its desktop, it goes home (feedback #1837).
    @Test func aDesktopLeftWithYabInFrontBringsTheFilmAlongAndHome() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("desktop-left")
        f.browser.activeID = source.id
        // Yab really in front, as on the swipe: the page's answer is read
        // against NSApp.isActive, which an inactive test host never showed.
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.deactivate() }
        // A change that leaves the window on screen asks nothing.
        f.browser.sightChanged(active: true, shown: true)
        // Yab behind: appLeft's own watch has it, not this.
        f.browser.sightChanged(active: false, shown: false)
        try await f.settled()
        #expect(try await f.count(source, "pip") == 0)
        f.browser.sightChanged(active: true, shown: false)
        try #require(try await Loaded.until(8) { try await f.count(source, "pip") == 1 })
        try f.present(source)
        let out = try await Loaded.until(8) { f.browser.floating == source.id && f.browser.floater.showing }
        #expect(out)
        #expect(try await f.count(source, "automaticPiP") == 1)
        // Heard again, or Yab then leaving too: still the one request.
        f.browser.sightChanged(active: true, shown: false)
        f.browser.appLeft()
        try await Task.sleep(for: .milliseconds(900))
        #expect(try await f.count(source, "pip") == 1)
        f.browser.sightChanged(active: true, shown: true)
        let home = try await Loaded.until(8) { f.browser.floating == nil && !f.browser.floater.showing }
        #expect(home && !source.floating)
    }

    @Test func anExceptionStopsRealTabAndSpaceDepartureBeforeThePageIsAsked() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("blocked-source")
        let sibling = try await f.page("blocked-sibling")
        f.deny(source)
        f.browser.activeID = source.id
        f.browser.leavingSpace()
        f.browser.select(sibling)
        try await f.settled()
        #expect(f.browser.activeID == sibling.id)
        #expect(try await f.count(source, "on") == 0)
        #expect(try await f.count(source, "pip") == 0)
        #expect(f.browser.floating == nil && !source.floating)
    }

    @Test func appDepartureStopsBeforeTheSystemPiPRequestButManualPiPStillWorks() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("app-source")
        f.browser.activeID = source.id
        f.deny(source)
        // Real final app-away entry; foreground/occlusion setup is outside
        // this policy test. Its caller retains the existing master guard.
        f.browser.leftNow()
        try await f.settled()
        #expect(try await f.count(source, "pip") == 0)
        #expect(try await f.count(source, "on") == 0)
        f.browser.prefs.floatsOnLeave = false
        f.browser.toggleFloat()
        try #require(try await Loaded.until(8) { try await f.count(source, "pip") == 1 })
        try f.present(source)
        let manual = try await Loaded.until(8) { f.browser.floating == source.id && f.browser.floater.showing }
        #expect(manual && !source.floating)
        #expect(try await f.count(source, "pip") == 1)
        #expect(try await f.count(source, "on") == 0)
        #expect(try await f.count(source, "automaticPiP") == 0)
        #expect(try await f.count(source, "automaticOn") == 0)
    }

    @Test(arguments: ["global-off", "silent", "muted"])
    func coveredAppDepartureRequiresEnabledAudiblePlayback(_ denial: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("covered-\(denial)")
        f.browser.activeID = source.id
        switch denial {
        case "global-off": f.browser.prefs.floatsOnLeave = false
        case "silent": source.noisy = false
        default:
            try #require(AudioWatch.canMute)
            source.mute(true)
        }
        f.browser.leftNow()
        try await f.settled()
        #expect(try await f.count(source, "pip") == 0)
        #expect(try await f.count(source, "on") == 0)
    }

    @Test func globalOffDominatesAndRestoringInheritanceAllowsTheRealLift() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("master-source")
        let sibling = try await f.page("master-sibling")
        f.browser.activeID = source.id
        f.browser.prefs.floatsOnLeave = false
        f.browser.leavingSpace()
        try await f.settled()
        #expect(try await f.count(source, "on") == 0)
        f.deny(source)
        f.browser.prefs.floatsOnLeave = true
        f.browser.leavingSpace()
        try await f.settled()
        #expect(try await f.count(source, "on") == 0)
        f.sites.setAllowed(true, for: source.address)
        f.browser.leavingSpace()
        f.browser.activeID = sibling.id
        try #require(try await Loaded.until(8) { try await f.count(source, "pip") == 1 })
        try f.present(source)
        let lifted = try await Loaded.until(8) { f.browser.floating == source.id && f.browser.floater.showing }
        #expect(lifted && !source.floating)
        #expect(try await f.count(source, "on") == 0)
        #expect(try await f.count(source, "automaticPiP") == 1)
    }

    @Test func denyingDuringTheRealIsolateAnswerCleansTheOwnedPageWithoutInstallingAWindow() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("pending-native-source")
        let sibling = try await f.page("pending-native-sibling")
        try await f.js(source, "__policy.hold = 'pip'")
        f.browser.activeID = source.id
        f.browser.leavingSpace()
        f.browser.activeID = sibling.id
        let pending = try await Loaded.until(8) { try await f.count(source, "pip") == 1 }
        try #require(pending, "The real automatic request must be in flight before changing the site")
        f.deny(source)
        try await f.js(source, "__policy.resolve('refused:NotSupportedError')")
        try await f.settled()
        #expect(try await f.count(source, "on") == 0)
        #expect(try await f.count(source, "off") == 0, "A refusal never isolated the document")
        #expect(!source.floating && f.browser.floating == nil && !f.browser.floater.showing)
        #expect(try await f.count(sibling, "off") == 0)
    }

    @Test func denyingWhileSystemPiPAnswersDoesNotStartTheNativeFallback() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("pending-pip-source")
        try await f.js(source, "__policy.hold = 'pip'")
        f.browser.activeID = source.id
        f.browser.leftNow()
        let pending = try await Loaded.until(8) { try await f.count(source, "pip") == 1 }
        try #require(pending)
        #expect(try await f.count(source, "automaticPiP") == 1)
        f.deny(source)
        try await f.js(source, "__policy.resolve('fallback')")
        try await f.settled()
        #expect(try await f.count(source, "on") == 0)
        #expect(try await f.count(source, "off") == 0)
        #expect(f.browser.floating == nil && !f.browser.floater.showing)
    }

    @Test(arguments: ["browser-flag", "native-window"])
    func aFullscreenWindowWhileTheAutomaticLiftAnswersStillFloats(_ kind: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let source = try await f.page("pending-fullscreen-source")
        let sibling = try await f.page("pending-fullscreen-sibling")
        let window = FullscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                      styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = requireNativeWebKitFixture(source, "AutomaticPiPEntryTests")
        defer {
            f.browser.fullScreen = false
            window.reportsFullscreen = false
            window.contentView = nil
            window.close()
        }
        try await f.js(source, "__policy.hold = 'pip'")
        f.browser.activeID = source.id
        f.browser.leavingSpace()
        f.browser.activeID = sibling.id
        let pending = try await Loaded.until(8) { try await f.count(source, "pip") == 1 }
        try #require(pending)
        if kind == "browser-flag" { f.browser.fullScreen = true }
        else {
            window.reportsFullscreen = true
            #expect(requireNativeWebKitFixture(source, "AutomaticPiPEntryTests").window === window && window.styleMask.contains(.fullScreen))
            #expect(!f.browser.fullScreen, "Exercise the NSWindow guard independently of the browser flag")
        }
        try f.present(source)
        try await f.js(source, "__policy.resolve('pip')")
        // Only the player's own full screen turns the answer down.
        let out = try await Loaded.until(8) { f.browser.floating == source.id && f.browser.floater.showing }
        #expect(out && !source.floating)
        #expect(try await f.count(sibling, "off") == 0)
    }
}

import AppKit
import Testing
import WebKit
@testable import Fast

/// Real Browser pictureOut/Isolate/lift callbacks on nonpersistent local
/// HTML. Native window/Space facts and the stable-check scheduler are
/// injected: these tests do NOT prove real macOS Space membership, native
/// fullscreen exit, system PiP, or two-display behavior.
@MainActor
@Suite(.serialized)
struct FullscreenPiPDepartureTests {
    private func requireWorld() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
    }

    @MainActor private final class Fixture {
        let id = UUID()
        // Async suites share the permission owner, so each fixture needs
        // its own exact site key while retaining the known-player policy.
        let site = URL(string: "https://departure-\(UUID().uuidString.lowercased()).youtube.com/")!
        let browser: Browser
        let source: NSWindow
        let playerHost: NSWindow
        var frame: FullscreenPiPDeparture.Frame?
        var pending: [@MainActor @Sendable () -> Void] = []
        /// A picture holds its controller weakly: the fixture keeps them.
        var controllers: [NSViewController] = []
        var originalPlayerOnSpace = false
        var originalPlayerUsable = true
        var sourceFocused = false
        let oldMaster = Store.settings.object(forKey: "float.leave")
        let oldMail = Dictionary(uniqueKeysWithValues: ["mail", "experimental.mail"].compactMap { key in
            Store.settings.object(forKey: key).map { (key, $0) }
        })
        private weak var previousFoldersBrowser = Folders.shared.browser
        let initialMaster: Bool
        let oldAway = Browser.benchAway

        init() {
            _ = NSApplication.shared
            Store.settings.set(false, forKey: "mail")
            Store.settings.set(false, forKey: "experimental.mail")
            browser = Browser(windowID: id)
            browser.lookForMailSignInLink = {}
            browser.dropSpare()
            browser.history = History([])
            initialMaster = browser.prefs.floatsOnLeave
            browser.prefs.floatsOnLeave = true
            Browser.benchAway = nil
            let rect = NSRect(x: -9000, y: -9000, width: 640, height: 360)
            source = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            playerHost = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false; playerHost.isReleasedWhenClosed = false
            browser.fullscreenDeparture.stop()
            browser.fullscreenDeparture = FullscreenPiPDeparture(
                capture: { [weak self] _ in self?.frame },
                later: { [weak self] action in self?.pending.append(action) },
                onSpace: { [weak self] window in
                    guard let self else { return nil }
                    if window === self.playerHost { return self.originalPlayerUsable ? self.originalPlayerOnSpace : nil }
                    return self.frame?.sourceOnSpace
                }, sourceFocused: { [weak self] _ in self?.sourceFocused ?? false })
            browser.fullscreenDeparture.start(for: browser)
        }

        func close() {
            browser.land()
            browser.floater.drop()
            browser.letGo()
            browser.dropSpare()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            frame = nil; pending = []
            source.contentView = nil; playerHost.contentView = nil
            source.close(); playerHost.close()
            AutomaticPiPSites.shared.setAllowed(true, for: site)
            for key in ["mail", "experimental.mail"] {
                if let value = oldMail[key] { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
            if Folders.shared.browser === browser { Folders.shared.browser = previousFoldersBrowser }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            Browser.benchAway = oldAway
            browser.prefs.floatsOnLeave = initialMaster
            if let oldMaster { Store.settings.set(oldMaster, forKey: "float.leave") }
            else { Store.settings.removeObject(forKey: "float.leave") }
            for prefix in ["session", "spaces"] {
                try? FileManager.default.removeItem(at: Store.file("\(prefix)-window-\(id.uuidString).json"))
            }
        }

        func page(_ name: String) async throws -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            PagePaint.configure(configuration)
            let tab = Tab(bench: true, configuration: configuration, factory: .webKitOnly)
            let url = URL(string: "\(site.absoluteString)watch?v=\(name)")!
            requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests").loadHTMLString("<!doctype html><title>\(name)</title><p>Owned departure-policy fixture</p>", baseURL: url)
            let loaded = try await Loaded.until(12) {
                (try? await requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests").evaluateJavaScript("document.title")) as? String == name && !requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests").isLoading
            }
            try #require(loaded)
            tab.setAddressOptimistically(url)
            browser.moveIn(tab)
            tab.noisy = true
            try await js(tab, """
                window.__policy={pip:0,on:0,off:0,hold:'',resolve:null,answer:'none'};
                window.__yabFloat={
                  pip:async function(){__policy.pip++;if(__policy.hold==='pip')return await new Promise(r=>__policy.resolve=r);return __policy.answer;},
                  on:async function(){__policy.on++;if(__policy.hold==='on')return await new Promise(r=>__policy.resolve=r);return ['floating',640,360];},
                  picture:async function(){return ['floating',640,360];},
                  off:async function(){__policy.off++;return 'off';}
                };
                """)
            return tab
        }

        func set(_ tab: Tab, mode: FullscreenPiPDeparture.Mode = .ordinary, onSpace: Bool? = false,
                 sourceOnSpace: Bool = false, usable: Bool = true, host: NSWindow? = nil,
                 sourceHidden: Bool? = nil, sourceMinimized: Bool = false) throws {
            let web = try #require(tab.built)
            frame = .init(tab: tab, web: web, source: source,
                          host: host ?? (mode == .player || mode == .moving ? playerHost : source),
                          mode: mode, hostOnSpace: onSpace, sourceOnSpace: sourceOnSpace, usable: usable,
                          sourceHidden: sourceHidden ?? !sourceOnSpace, sourceMinimized: sourceMinimized)
        }

        func picture(_ tab: Tab) throws -> SitePiP.Picture {
            let web = try #require(tab.built)
            source.contentView = web
            let rect = web.convert(web.bounds, to: nil)
            let controller = NSViewController()
            controllers.append(controller)
            let picture = try #require(SitePiP.benchPicture(view: NSView(frame: rect), window: source, rect: rect, controller: controller))
            #expect(picture.controller === controller)
            return picture
        }

        func fire() throws { try #require(!pending.isEmpty); pending.removeFirst()() }
        func changed() { browser.fullscreenDeparture.changed() }
        @discardableResult func js(_ tab: Tab, _ code: String) async throws -> Any? {
            let web = try #require(tab.built)
            return try await web.evaluateJavaScript(code + ";true", in: nil, contentWorld: Isolate.world)
        }
        func count(_ tab: Tab, _ key: String) async throws -> Int {
            let web = try #require(tab.built)
            return try #require(try await web.evaluateJavaScript("__policy.\(key)", in: nil, contentWorld: Isolate.world) as? Int)
        }
        func wait(_ tab: Tab, _ key: String, _ n: Int) async throws -> Bool {
            try await Loaded.until(8) { try await self.count(tab, key) == n }
        }
    }

    @Test func overlappingFixturesKeepTheirSitePermissionsIndependent() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("isolated-denied")
        f.browser.activeID = tab.id
        tab.noisy = true
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false, sourceHidden: true)
        AutomaticPiPSites.shared.setAllowed(false, for: tab.address)
        do {
            let other = Fixture(); defer { other.close() }
            let allowed = try await other.page("isolated-allowed")
            other.browser.activeID = allowed.id
            allowed.noisy = true
            try other.set(allowed, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false, sourceHidden: true)
            #expect(Players.knows(allowed.address))
            f.changed(); other.changed()
            #expect(f.pending.isEmpty)
            #expect(other.pending.count == 1)
            #expect(!AutomaticPiPSites.shared.allows(tab.address))
        }
        #expect(!AutomaticPiPSites.shared.allows(tab.address), "Closing another fixture must preserve this exception")
    }

    @Test(arguments: [FullscreenPiPDeparture.Mode.window, .player, .moving])
    func fullscreenNeverStartsAutomaticPiP(_ mode: FullscreenPiPDeparture.Mode) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("fullscreen-stays")
        f.browser.activeID = tab.id
        tab.noisy = true
        for hidden in [false, true] {
            try f.set(tab, mode: mode, sourceHidden: hidden)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
            #expect(f.pending.isEmpty)
            #expect(f.browser.fullscreenDeparture.benchIssued == nil)
            #expect(try await f.count(tab, "pip") == 0)
        }
    }

    @Test func spaceNotificationRechecksAnExplicitInlineDeparture() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("space-notification")
        f.browser.activeID = tab.id
        try f.set(tab)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(f.pending.count == 1)
        try f.fire()
        #expect(try await f.wait(tab, "pip", 1))
        #expect(try await f.count(tab, "on") == 0)
    }

    @Test(arguments: ["hidden", "minimized"])
    func explicitDepartureStartsOnceAndReturnsToItsSource(_ state: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("app-\(state)")
        f.browser.activeID = tab.id
        tab.noisy = true
        try await f.js(tab, "__policy.hold='pip'")
        let picture = try f.picture(tab)
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false,
                  sourceHidden: state == "hidden", sourceMinimized: state == "minimized")
        let leave = state == "hidden" ? NSApplication.didHideNotification : NSWindow.didMiniaturizeNotification
        let object: AnyObject = state == "hidden" ? NSApplication.shared : f.source
        NotificationCenter.default.post(name: leave, object: object)
        NotificationCenter.default.post(name: leave, object: object)
        #expect(f.pending.count == 1)
        try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        f.browser.webView(requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        try #require(f.browser.take(picture))
        try await f.js(tab, "__policy.resolve('pip')")
        let installed = try await Loaded.until(8) { f.browser.floating == tab.id && f.browser.floater.showing }
        try #require(installed)
        #expect(try await f.count(tab, "pip") == 1)
        #expect(try await f.count(tab, "on") == 0)
        // Activation of another Yab window, or pausing the floated video,
        // does not return to the still hidden/minimized source.
        tab.noisy = false
        f.browser.appBack()
        #expect(f.browser.floating == tab.id)
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true)
        let back = state == "hidden" ? NSApplication.didUnhideNotification : NSWindow.didDeminiaturizeNotification
        NotificationCenter.default.post(name: back, object: object)
        f.browser.appBack()
        #expect(f.browser.floating == nil)
    }

    @Test(arguments: ["global-off", "site-off", "silent", "muted", "hold", "other-pip"])
    func hiddenSourceRequiresTheExistingPolicyAndAudiblePlayback(_ denial: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("app-denied-\(denial)")
        f.browser.activeID = tab.id
        tab.noisy = true
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false, sourceHidden: true)
        switch denial {
        case "global-off": f.browser.prefs.floatsOnLeave = false
        case "site-off": AutomaticPiPSites.shared.setAllowed(false, for: tab.address)
        case "silent": tab.noisy = false
        case "muted":
            try #require(AudioWatch.canMute)
            tab.mute(true)
        case "hold": f.browser.minimizeHold.minimized(tab.id)
        default:
            let other = try await f.page("other-pip")
            other.pictureInPicture = true
            f.browser.activeID = tab.id
        }
        f.changed()
        #expect(f.pending.isEmpty)
        #expect(try await f.count(tab, "pip") == 0)
    }

    @Test(arguments: ["visible", "other-window", "transition", "closed"])
    func appNotificationsDoNotMistakeAnUnprovenSourceForADeparture(_ state: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("app-unproven-\(state)")
        f.browser.activeID = tab.id
        tab.noisy = true
        try f.set(tab, mode: state == "transition" ? .moving : .ordinary,
                  onSpace: true, sourceOnSpace: true, usable: state == "visible",
                  sourceHidden: state == "transition" || state == "closed", sourceMinimized: state == "other-window")
        if state == "closed" {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: f.source)
        }
        if state == "other-window" {
            NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: f.playerHost)
        } else {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        }
        #expect(f.pending.isEmpty)
        #expect(try await f.count(tab, "pip") == 0)
    }

    @Test(arguments: ["return", "silent", "global-off", "site-off"])
    func minimizedSourceIsRecheckedBeforeTheRequest(_ change: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("app-stable-\(change)")
        f.browser.activeID = tab.id
        tab.noisy = true
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false, sourceMinimized: true)
        f.changed()
        switch change {
        case "return": try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true)
        case "silent": tab.noisy = false
        case "global-off": f.browser.prefs.floatsOnLeave = false
        default: AutomaticPiPSites.shared.setAllowed(false, for: tab.address)
        }
        try f.fire()
        #expect(try await f.count(tab, "pip") == 0)
    }

    @Test(arguments: ["pip"])
    func returningWhileHiddenSourceAnswersCannotReopenPiP(_ held: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("app-late-\(held)")
        f.browser.activeID = tab.id
        tab.noisy = true
        try await f.js(tab, "__policy.answer='fallback';__policy.hold='\(held)'")
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true, usable: false, sourceHidden: true)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, held, 1))
        try f.set(tab, mode: .ordinary, onSpace: true, sourceOnSpace: true)
        f.browser.appBack()
        try await f.js(tab, held == "pip" ? "__policy.resolve('fallback')" : "__policy.resolve(['floating',640,360])")
        if held == "on" { #expect(try await f.wait(tab, "off", 1)) }
        else {
            let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
            #expect(finished)
            #expect(try await f.count(tab, "on") == 0)
        }
        #expect(f.browser.floating == nil && !f.browser.floater.showing)
    }

    @Test(arguments: ["visible", "unknown-space", "missing-host", "transition", "ordinary"])
    func visibleOrUnprovenWindowDoesNotStartAnAttempt(_ state: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("no-attempt-\(state)")
        f.browser.activeID = tab.id
        try f.set(tab, mode: state == "transition" ? .moving : state == "ordinary" ? .ordinary : .player,
                  onSpace: state == "visible" ? true : state == "unknown-space" ? nil : false,
                  usable: state != "missing-host", sourceHidden: false)
        f.changed()
        #expect(f.pending.isEmpty)
        #expect(try await f.count(tab, "pip") == 0)
    }

    @Test(arguments: [FullscreenPiPDeparture.Mode.window, .player, .moving])
    func enteringFullscreenCancelsAPendingInlineDeparture(_ mode: FullscreenPiPDeparture.Mode) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("inline-to-fullscreen")
        f.browser.activeID = tab.id
        try f.set(tab)
        f.changed()
        #expect(f.pending.count == 1)
        try f.set(tab, mode: mode)
        try f.fire()
        #expect(try await f.count(tab, "pip") == 0)
        #expect(try await f.count(tab, "on") == 0)
    }

    @Test(arguments: ["return", "other-host", "other-tab", "navigate", "global-off", "site-off", "minimize", "closed"])
    func stableCheckRejectsChangedOwnershipOrPermission(_ change: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("stable-\(change)")
        let sibling = try await f.page("sibling-\(change)")
        f.browser.activeID = tab.id
        try f.set(tab)
        f.changed()
        switch change {
        case "return": try f.set(tab, onSpace: true, sourceOnSpace: true)
        case "other-host": try f.set(tab, host: f.playerHost)
        case "other-tab": f.browser.activeID = sibling.id
        case "navigate": tab.askedAt = (tab.askedAt ?? 0) + 1
        case "global-off": f.browser.prefs.floatsOnLeave = false
        case "site-off": AutomaticPiPSites.shared.setAllowed(false, for: tab.address)
        case "minimize": f.browser.minimizeHold.minimized(tab.id)
        default: tab.close()
        }
        try f.fire()
        #expect(try await f.count(sibling, "pip") == 0)
        if change != "closed" { #expect(try await f.count(tab, "pip") == 0) }
    }

    @Test func closingAndReopeningTheSameSourceRetainsItsSpaceObserver() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("closed-source")
        f.browser.activeID = tab.id
        try f.set(tab)
        f.changed()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: f.source)
        try f.set(tab, usable: false)
        try f.fire()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(f.pending.isEmpty)
        #expect(try await f.count(tab, "pip") == 0)
        // The primary Browser/window is retained at close. Reopening that
        // same source must not require Browser.init/start a second time.
        try f.set(tab)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(f.pending.count == 1)
        try f.fire()
        #expect(try await f.wait(tab, "pip", 1))
    }

    @Test(arguments: ["return", "land", "global-off", "site-off"])
    func lateSystemAnswerCannotStartFallbackAfterTheDepartureEnded(_ change: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("late-pip-\(change)")
        f.browser.activeID = tab.id
        try await f.js(tab, "__policy.hold='pip'")
        try f.set(tab)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        switch change {
        case "return": try f.set(tab, onSpace: true, sourceOnSpace: true); f.browser.appBack()
        case "land": f.browser.land()
        case "global-off": f.browser.prefs.floatsOnLeave = false
        default: AutomaticPiPSites.shared.setAllowed(false, for: tab.address)
        }
        try await f.js(tab, "__policy.resolve('fallback')")
        #expect(try await f.count(tab, "on") == 0)
        #expect(f.browser.floating == nil)
    }

    @Test func refusedNativeRequestNeverExtractsTheDocument() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("late-extraction")
        f.browser.activeID = tab.id
        try await f.js(tab, "__policy.hold='pip'")
        try f.set(tab)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        try f.set(tab, onSpace: true, sourceOnSpace: true)
        f.browser.appBack()
        try await f.js(tab, "__policy.resolve('refused:NotSupportedError')")
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        #expect(finished)
        #expect(try await f.count(tab, "on") == 0)
        #expect(try await f.count(tab, "off") == 0)
        #expect(f.browser.floating == nil && !f.browser.floater.showing)
    }

    @Test func actualNativeTakeKeepsItsOwnedContextThroughTheSuccessCallback() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("native-take")
        f.browser.activeID = tab.id
        try await f.js(tab, "__policy.hold='pip'")
        let picture = try f.picture(tab)
        try f.set(tab)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        f.browser.webView(requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        #expect(f.browser.take(picture))
        #expect(f.browser.floating == tab.id && f.browser.floater.showing)
        #expect(f.browser.fullscreenDeparture.benchPhase == .installed)
        try await f.js(tab, "__policy.resolve('pip')")
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        #expect(finished && f.browser.floating == tab.id)
        f.browser.appBack()
        #expect(f.browser.floating == tab.id, "Another active Yab window does not return to a hidden source")
        try f.set(tab, onSpace: true, sourceOnSpace: true)
        f.browser.appBack()
        #expect(f.browser.floating == nil)
    }

    @Test func staleNativeTakeAndHasVideoCannotReplaceANewerManualPage() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let old = try await f.page("old-auto"), manual = try await f.page("new-manual")
        f.browser.activeID = old.id
        let picture = try f.picture(old)
        try await f.js(old, "__policy.hold='pip'")
        try f.set(old)
        f.changed(); try f.fire()
        try #require(try await f.wait(old, "pip", 1))
        f.browser.benchLiftPage(manual, quietly: false)
        let shown = try await Loaded.until(8) { f.browser.floating == manual.id && f.browser.floater.showing }
        try #require(shown)
        f.browser.webView(requireNativeWebKitFixture(old, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        #expect(f.browser.floating == manual.id)
        #expect(!f.browser.take(picture))
        var cancelled = 0, system = 0
        SitePiP.declined(picture, cancel: { cancelled += 1 }, system: { system += 1 })
        #expect(cancelled == 1 && system == 0)
        #expect(f.browser.floating == manual.id && !old.pictureInPicture)
        try await f.js(old, "__policy.resolve('pip')")
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        #expect(finished && f.browser.floating == manual.id)
    }

    @Test(arguments: ["held", "held-changed", "settled-changed"])
    func aSiteNativeRequestOwnsItsReturnPolicyBeforeItLandsAutomaticVideo(state: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let automatic = try await f.page("automatic-held"), manual = try await f.page("site-native-manual")
        f.browser.activeID = automatic.id
        let firstPicture = try f.picture(automatic)
        try await f.js(automatic, "__policy.hold='pip'")
        try f.set(automatic)
        f.changed(); try f.fire()
        try #require(try await f.wait(automatic, "pip", 1))
        // Native take/hasVideo precede the JS promise settling. A really
        // installed automatic floater still has a held old promise here.
        f.browser.webView(requireNativeWebKitFixture(automatic, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        try #require(f.browser.take(firstPicture))
        #expect(f.browser.floating == automatic.id)
        if state == "settled-changed" {
            try await f.js(automatic, "__policy.resolve('pip')")
            let settled = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
            try #require(settled)
        }
        let secondPicture = try f.picture(manual)
        f.browser.activeID = manual.id
        if state != "held" { f.changed() }
        // A site's button bypasses Browser.pictureOut/float entirely.
        // It must supersede while A's context still exists, before land
        // clears that context and before B's later native take.
        f.browser.webView(requireNativeWebKitFixture(manual, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        try #require(f.browser.take(secondPicture))
        f.browser.appBack()
        #expect(f.browser.floating == manual.id && f.browser.floater.showing,
                "A manual site PiP must not inherit A's automatic-return flag")
        try await f.js(automatic, "__policy.resolve('pip')")
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        #expect(finished && f.browser.floating == manual.id)
    }

    @Test func manualCloseOnTheSamePageSupersedesAHeldAutomaticRequest() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("manual-close")
        f.browser.activeID = tab.id
        try await f.js(tab, "__policy.hold='pip'")
        try f.set(tab)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        let context = try #require(f.browser.fullscreenDeparture.benchIssued)
        tab.pictureInPicture = true
        f.browser.toggleFloat()
        #expect(!f.browser.fullscreenDeparture.mayUndoSystemAnswer(context, in: f.browser))
        #expect(f.browser.fullscreenDeparture.benchPhase == nil)
        tab.pictureInPicture = false
        try await f.js(tab, "__policy.resolve('fallback')")
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        #expect(finished && f.browser.floating == nil)
        #expect(try await f.count(tab, "on") == 0)
    }

    @Test(arguments: ["pip", "none"])
    func settledNativeReceiptDoesNotBlockALaterOrdinarySiteRequest(_ answer: String) async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("settled-\(answer)")
        f.browser.activeID = tab.id
        let picture = try f.picture(tab)
        try await f.js(tab, "__policy.answer='\(answer)'")
        try f.set(tab)
        f.changed(); try f.fire()
        try #require(try await f.wait(tab, "pip", 1))
        let finished = try await Loaded.until(8) { f.browser.fullscreenDeparture.benchIssued == nil }
        try #require(finished)
        // No request receipt remains. This is the actual ordinary native
        // delegate/taker path, not another Browser pictureOut call.
        f.browser.webView(requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        #expect(tab.pictureInPicture)
        #expect(f.browser.take(picture))
        #expect(!picture.rejectedAutomaticDeparture && f.browser.floating == tab.id)
    }

    @Test func cancellingBeforeTheStableCheckDoesNotPoisonTheSiteButton() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("cancel-before-request")
        f.browser.activeID = tab.id
        let picture = try f.picture(tab)
        try f.set(tab)
        f.changed()
        #expect(f.pending.count == 1 && f.browser.fullscreenDeparture.benchIssued == nil)
        try f.set(tab, onSpace: true, sourceOnSpace: true)
        f.browser.appBack()
        try f.fire()
        #expect(try await f.count(tab, "pip") == 0)
        f.browser.webView(requireNativeWebKitFixture(tab, "FullscreenPiPDepartureTests"), hasVideoInPictureInPictureDidChange: true)
        #expect(f.browser.take(picture))
        #expect(!picture.rejectedAutomaticDeparture)
    }

    @Test func aPictureOutEarlyGuardLeavesNoNativeReceipt() async throws {
        try requireWorld()
        let f = Fixture(); defer { f.close() }
        let tab = try await f.page("early-request-guard"), other = try await f.page("existing-pip")
        f.browser.activeID = tab.id
        try f.set(tab)
        f.changed()
        // It became unavailable after scheduling, before pictureOut's
        // existing another-PiP guard. No native request was made.
        other.pictureInPicture = true
        try f.fire()
        #expect(f.browser.fullscreenDeparture.benchIssued == nil)
        #expect(try await f.count(tab, "pip") == 0)
        other.pictureInPicture = false
        let picture = try f.picture(tab)
        #expect(f.browser.take(picture))
        #expect(!picture.rejectedAutomaticDeparture)
    }

    @Test func theScopedContextOwnsTheActiveAppDecisionOnly() {
        #expect(!FullscreenPiPDeparture.back(quietly: true, appActive: true, selected: true, departure: true))
        #expect(FullscreenPiPDeparture.back(quietly: true, appActive: true, selected: true, departure: nil))
        #expect(FullscreenPiPDeparture.back(quietly: true, appActive: true, selected: true, departure: false))
        #expect(!FullscreenPiPDeparture.back(quietly: false, appActive: true, selected: true, departure: nil))
    }
}

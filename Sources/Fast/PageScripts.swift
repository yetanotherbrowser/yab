import QuartzCore
import WebKit

// What a tab's next document is given, and how little that costs.
//
// Every main-frame navigation arms its tab (Browser's decidePolicyFor). It
// used to take every script off and put about two dozen back, some 190 KB
// sent to the page's process each time, for the same scripts nine times in
// ten. Now each script is one object, made once, or once for each thing it
// depends on (a site's hidden things, the fonts, passkeys on or off); the
// list is put together from those objects, and when it is the very list the
// controller already holds, nothing is sent at all. DuckDuckGo arms the same
// way: its scripts go in once and again only when what they are made of
// changes (BrowserServicesKit, UserContentController.swift).
//
// Adding a script: put it in `list` as an object that stays the same while
// what it depends on does, a `static let`, or `made(_:_:_:)` keyed by its
// input. Anything that depends on the site the tab is going to reads
// `Arming.host`. A script made afresh each time still works, but arms every
// navigation again.

@MainActor
enum PageScripts {
    /// Where the next document is going, and what is hidden there.
    struct Arming {
        /// The site, as Curtain names it: lower case, without "www.".
        let host: String?
        /// That site's stylesheet of hidden things, or "".
        let css: String
    }

    /// Curtain's name for a site, for a tab arming for where it already is.
    static func host(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Foundation's stored host and the DOM hostname can differ in IPv6
    /// URL delimiters. Compare the address itself, leaving www significant
    /// for saved looks (Curtain drops it separately).
    nonisolated static func scriptHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    nonisolated static let documentHost = #"location.hostname.toLowerCase().replace(/^\[|\]$/g, '')"#

    /// Every script the tab's next document gets, in the order they run.
    /// Boosts come after, from Boosts.attach.
    static func list(for tab: Tab, _ arming: Arming, chosenFonts: PageFonts? = nil) -> [WKUserScript] {
        // Fonts of one's own only when there are some: no script in every
        // frame for nothing (#1889).
        let chosenFonts = chosenFonts ?? PageFonts.read()
        var list = (chosenFonts.css.isEmpty ? [] : [fonts(chosenFonts)]) + [
            // A page's own Document Picture-in-Picture (DocumentPiP.swift).
            pip,
            // A page leaving for another site isn't taken back by a reload
            // of itself nobody asked for, OpenAI's sign-in (navigation-hold.js).
            navigationHold,
            scroll, drawn, picker,
            // The link a shift-click or a Force Click was on, for a peek to grow out of.
            peekOrigin(force: tab.forcePeeks?() ?? false),
            linkCards,
            // The empty room at the top of a page moves the window (TopDrag).
            TopDragRelay.script,
            forms, formFrames, call,
            // The whole wallet in the page itself; in its frames only a look
            // for boxes, which sends for the rest where there are any.
            wallet, walletSoon,
        ]
        if tab.videoOpening.armed { list.append(VideoOpening.script) }
        if !tab.shy { list.append(sent) }
        // An AI chat or a builder at work, on those sites alone (ChatBusy).
        if let site = ChatBusy.site(arming.host) { list.append(busy(site)) }
        // Yab's own site told it is open in Yab, and what Yab wears (Dress).
        if Dress.ours(arming.host) { list.append(Dress.script(Links.browser)) }
        // Dark pages, while they can be dark here and the site isn't kept
        // light: the engine's proxy in the page's world, the engine and the
        // start script in their own (DarkPages.swift). The same three for
        // every site, so going between sites sends nothing.
        if !omits("dark") { list += DarkPages.scripts(for: tab.darkState.armed) }
        list += [
            // Every frame: a swipe over an embedded map is the map's, and only
            // the map's own document can say so.
            swipe, images,
            // Every frame, in a world of its own: the film on a page is as often
            // as not someone else's player in a frame (see `Isolate`).
            isolate,
        ]
        // Add to yab on the Web Store only where an extension can be added:
        // before macOS 15.4 the button would promise what can't be done.
        if #available(macOS 15.4, *) { list.append(store) }
        // Passkeys stand in the page's own world, since they replace the
        // page's functions, and reach yab through a bridge in yab's, off or
        // on: an extension's page script can carry the patch either way (see
        // Passkeys.swift and ExtensionShims.passkeys).
        list.append(FormRelay.passkeysOffered ? passkeys : withoutPasskeys)
        list += [
            passkeyBridge,
            // Sharing a screen: the page's getDisplayMedia is yab's, in every
            // frame, since a call is as often in another site's frame, with
            // the bridge to yab beside it (Share.swift).
            share, shareBridge,
            // A page on this Mac's own server, heard in its own world and handed
            // over to yab's (DevMode.swift). Every other page leaves the first at
            // its first line.
            dev, devBridge,
            // A web app's own count, as it tells the Dock (Corner.swift).
            badge, badgeBridge, windowBridge,
            // The page's icons as its script changes them after load (Icons.swift).
            icons,
            // The page's EyeDropper, the Mac's color sampler, with its bridge
            // (EyeDropper.swift), in every frame.
            eyeDropper, eyeDropperBridge,
        ]
        // A document that came as JSON, as a tree or as text (JSONView.swift);
        // every other page leaves at its first lines. Not while a JSON
        // extension the person chose shows these pages its own way.
        if JSONView.yieldsTo(for: tab) == nil { list.append(json(JSONShow.current, keeps: !tab.shy)) }
        // Web Push: the page's pushManager is yab's, with its bridge
        // (WebPush.swift). Never in a private window, which keeps nothing.
        if !tab.shy { list += [push, pushBridge] }
        // Video played and how much faster, for Yab Wrapped (WrappedWatch);
        // never in a private window.
        if !tab.shy { list.append(watched) }
        // A site that hands out its Chrome extension only to Chrome, told it
        // is in Chrome (SiteAgent.extensionHosts). Before the next one, which
        // puts chrome.runtime on the same window.chrome.
        if SiteAgent.chromeLike(arming.host) { list.append(chromeLike) }
        // Superhuman checks this real storage API before it will use its
        // installed extension. Share the OPFS implementation with extension
        // pages; leave installation detection to the extension itself.
        if SiteAgent.extensionAppHosts.contains(arming.host ?? "") { list.append(legacyFileSystem) }
        // chrome.runtime for pages an extension's externally_connectable
        // lets in (ExtensionExternal.swift); the script leaves every other
        // page at its first lines.
        if #available(macOS 15.4, *), !tab.shy { list += ExtensionExternal.shared.scripts }
        if tab.skipsAds { list.append(YouTube.user) }
        // An extension asked that WebRTC go nowhere outside its proxy
        // (ExtensionProxy, Proton VPN's "WebRTC leak protection").
        if ExtensionProxy.relayOnly { list.append(webrtcRelay) }
        // An agent's tab: its frames say they are there, so another site's
        // frame, a payment form, can be read and acted in (AgentPage).
        if tab.bench { list.append(agentFrames) }
        // A skill's things on this site, each with Yab's button in the
        // site's own row (SiteItems).
        if let source = SiteItems.shared.script(for: tab, host: arming.host) {
            list.append(made("items", source) { script(source, .atDocumentEnd, mainOnly: true) })
        }
        // The stylesheet goes in before the document has a body, so nothing
        // is ever seen arriving and then leaving again.
        if !arming.css.isEmpty { list.append(veils(arming.css)) }
        if !left.isEmpty { list.removeAll(where: leftOut) }
        if let transfer = tab.engineSwitchDocument { list.insert(transfer.script, at: 0) }
        return list
    }

    /// YAB_PAGE_SCRIPTS_OFF=forms,wallet (a diagnosis, evals/feedback-283):
    /// those of Yab's scripts left out of every page, "all" for every one,
    /// to tell which of them a page's trouble comes with.
    nonisolated static let left: Set<String> = Set((ProcessInfo.processInfo.environment["YAB_PAGE_SCRIPTS_OFF"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    nonisolated static func omits(_ group: String) -> Bool {
        left.contains("all") || left.contains(group)
    }
    private static func leftOut(_ script: WKUserScript) -> Bool {
        if left.contains("all") { return true }
        let named: [(String, [WKUserScript])] = [
            ("forms", [forms, formFrames, passkeys, withoutPasskeys, passkeyBridge]), ("wallet", [wallet, walletSoon]),
            ("sent", [sent]), ("call", [call]), ("scroll", [scroll, drawn]), ("picker", [picker]), ("links", [linkCards] + peekOrigins),
            ("swipe", [swipe]), ("images", [images]), ("isolate", [isolate]), ("store", [store]),
            ("share", [share, shareBridge]), ("dev", [dev, devBridge]), ("badge", [badge, badgeBridge]), ("icons", [icons]),
            ("push", [push, pushBridge]), ("watched", [watched]), ("pip", [pip]), ("hold", [navigationHold]), ("topdrag", [TopDragRelay.script]), ("chromelike", [chromeLike, legacyFileSystem]),
        ]
        return named.contains { left.contains($0.0) && $0.1.contains { $0 === script } }
    }

    /// Puts `list` on the controller, unless it is already what is there:
    /// the same objects in the same order, all still in place. Answers
    /// whether anything was sent.
    @discardableResult
    static func fit(_ controller: WKUserContentController, _ list: [WKUserScript]) -> Bool {
        let ids = list.map(ObjectIdentifier.init)
        if let armed = objc_getAssociatedObject(controller, &armedKey) as? Armed, armed.ids == ids {
            // Something else may have taken them off since (a tab put to
            // sleep clears its controller): only what is there counts.
            let have = Set(controller.userScripts.map(ObjectIdentifier.init))
            if ids.allSatisfy(have.contains) { return false }
        }
        counts.changed += 1
        // A Cocoa-backed getter result can mutate when the controller is
        // cleared. Keep the requested application scripts in an owned array.
        let snapshot = list.map { $0 }
        controller.removeAllUserScripts()
        // WebKit keeps extensions' scripts through that (PageAppearance.install).
        var kept = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in snapshot where kept.insert(ObjectIdentifier(script)).inserted { controller.addUserScript(script) }
        let before = (objc_getAssociatedObject(controller, &armedKey) as? Armed)?.sends ?? 0
        objc_setAssociatedObject(controller, &armedKey, Armed(ids, sends: before + 1), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    /// The controller holds nothing of ours any more (Tab.discard).
    static func forget(_ controller: WKUserContentController) {
        objc_setAssociatedObject(controller, &armedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// A tab armed (Tab.arm), all of it, the list made and boosts too,
    /// counted and timed for the bench.
    static func arming(_ work: () -> Void) {
        let t0 = CACurrentMediaTime()
        work()
        counts.asked += 1
        counts.seconds += CACurrentMediaTime() - t0
    }

    /// For the bench: how often a tab was armed, how often that sent
    /// anything, and the main thread's time spent arming.
    private(set) static var counts = (asked: 0, changed: 0, seconds: 0.0)

    static var report: [String: Any] {
        ["asked": counts.asked, "changed": counts.changed, "ms": (counts.seconds * 10_000).rounded() / 10]
    }

    /// How many times this controller was sent a list since it was last
    /// forgotten: `counts` is the whole app's, and moves with every other
    /// tab arming meanwhile.
    static func sends(to controller: WKUserContentController) -> Int {
        (objc_getAssociatedObject(controller, &armedKey) as? Armed)?.sends ?? 0
    }

    private final class Armed: NSObject {
        let ids: [ObjectIdentifier]
        let sends: Int
        init(_ ids: [ObjectIdentifier], sends: Int) { self.ids = ids; self.sends = sends }
    }
    private nonisolated(unsafe) static var armedKey: UInt8 = 0

    // MARK: - the scripts, each one object

    private static func script(_ source: String, _ time: WKUserScriptInjectionTime, mainOnly: Bool, in world: WKContentWorld = Web.world) -> WKUserScript {
        WKUserScript(source: source, injectionTime: time, forMainFrameOnly: mainOnly, in: world)
    }

    private static let pip = script(DocumentPiPScript.source, .atDocumentStart, mainOnly: true, in: .page)
    private static let navigationHold = script(PageScript.load("navigation-hold"), .atDocumentStart, mainOnly: false, in: .page)
    private static let scroll = script(ScrollRelay.script, .atDocumentEnd, mainOnly: true)
    private static let drawn = script(ScrollRelay.drawn, .atDocumentStart, mainOnly: true)
    private static let picker = script(Veiling.picker, .atDocumentStart, mainOnly: true)
    private static let forms = script(FormRelay.script, .atDocumentEnd, mainOnly: true)
    private static let formFrames = script(FormRelay.frameScript, .atDocumentEnd, mainOnly: false)
    /// Promises in what you send (Promises.sent): never in a private tab.
    private static let sent = script(PageScript.load("sent"), .atDocumentEnd, mainOnly: true)
    private static let call = script(CallRelay.script, .atDocumentEnd, mainOnly: true)
    private static let wallet = script(WalletRelay.script, .atDocumentEnd, mainOnly: true)
    private static let walletSoon = script(WalletRelay.soon, .atDocumentEnd, mainOnly: false)
    private static let swipe = script(Swipe.watch, .atDocumentStart, mainOnly: false)
    private static let images = script(ImageRelay.watch, .atDocumentStart, mainOnly: false)
    private static let isolate = Isolate.script
    private static let store = script(StoreRelay.script, .atDocumentEnd, mainOnly: true)
    /// Made once a launch: Chrome's version moves every four weeks.
    private static let chromeLike = script(PageScript.load("chrome-like", vars: ["MAJOR": String(SiteAgent.version())]), .atDocumentStart, mainOnly: true, in: .page)
    private static let legacyFileSystem = script(PageScript.load("legacy-file-system"), .atDocumentStart, mainOnly: true, in: .page)
    private static let passkeys = script(PasskeyRelay.page, .atDocumentStart, mainOnly: false, in: .page)
    private static let withoutPasskeys = script(FormRelay.withoutPasskeys, .atDocumentStart, mainOnly: false, in: .page)
    private static let passkeyBridge = script(PasskeyRelay.bridge, .atDocumentStart, mainOnly: false)
    private static let share = script(ShareScript.page, .atDocumentStart, mainOnly: false, in: .page)
    /// RTCPeerConnection relay-only and without STUN servers: no address of
    /// this Mac reaches a site past the proxy (Chromium's
    /// disable_non_proxied_udp policy).
    private static let webrtcRelay = script(#"""
    (function () {
      var Own = window.RTCPeerConnection;
      if (!Own || Own.__yabRelay) return;
      function strip(config) {
        var c = Object.assign({}, config || {});
        c.iceTransportPolicy = 'relay';
        c.iceServers = (c.iceServers || []).map(function (s) {
          var urls = [].concat(s.urls || s.url || []).filter(function (u) { return /^turns?:/i.test(u); });
          return urls.length ? Object.assign({}, s, { urls: urls }) : null;
        }).filter(Boolean);
        return c;
      }
      function Relay(config, more) { return new Own(strip(config), more); }
      Relay.prototype = Own.prototype;
      Object.defineProperty(Relay, '__yabRelay', { value: true });
      try { Relay.generateCertificate = Own.generateCertificate; } catch (e) {}
      var set = Own.prototype.setConfiguration;
      if (set) Own.prototype.setConfiguration = function (config) { return set.call(this, strip(config)); };
      window.RTCPeerConnection = Relay;
      if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = Relay;
    })();
    """#, .atDocumentStart, mainOnly: false, in: .page)
    private static let shareBridge = script(ShareScript.bridge, .atDocumentStart, mainOnly: false)
    private static let dev = script(DevRelay.page, .atDocumentStart, mainOnly: true, in: .page)
    private static let devBridge = script(DevRelay.bridge, .atDocumentStart, mainOnly: true)
    private static let badge = script(BadgeRelay.page, .atDocumentStart, mainOnly: true, in: .page)
    private static let badgeBridge = script(BadgeRelay.bridge, .atDocumentStart, mainOnly: true)
    private static let windowBridge = script(WindowRelay.bridge, .atDocumentStart, mainOnly: true)
    private static let icons = script(IconRelay.script, .atDocumentEnd, mainOnly: true)
    private static let eyeDropper = script(EyeDropperRelay.page, .atDocumentStart, mainOnly: false, in: .page)
    private static let eyeDropperBridge = script(EyeDropperRelay.bridge, .atDocumentStart, mainOnly: false)
    private static let watched = script(WatchRelay.script, .atDocumentStart, mainOnly: false)
    private static let push = script(PushRelay.page, .atDocumentStart, mainOnly: false, in: .page)
    private static let pushBridge = script(PushRelay.bridge, .atDocumentStart, mainOnly: false)
    private static let agentFrames = script(AgentPage.frameScript, .atDocumentEnd, mainOnly: false, in: AgentPage.world)

    private static let peekOrigins = [false, true].map { script(PeekOrigin.script(force: $0), .atDocumentStart, mainOnly: true) }
    private static let linkCards = script(LinkCardRules.script, .atDocumentStart, mainOnly: true)
    private static func peekOrigin(force: Bool) -> WKUserScript { peekOrigins[force ? 1 : 0] }

    /// The fonts, as Settings › Appearance last set them (PageAppearance).
    /// Keyed by the fonts as sorted JSON: JSONEncoder's own key order can
    /// differ from one call to the next, and an unsorted key made the script
    /// again, and armed the tab again, on every navigation.
    static func fonts(_ fonts: PageFonts) -> WKUserScript {
        made("fonts", String(decoding: (try? fontsKey.encode(fonts)) ?? Data(), as: UTF8.self)) {
            script(PageAppearance.script(fonts), .atDocumentStart, mainOnly: false)
        }
    }

    private static let fontsKey: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// The JSON viewer, as Settings › Developers last set it, and whether
    /// it may keep what was folded for the tab (never a private one's).
    static func json(_ show: JSONShow, keeps: Bool) -> WKUserScript {
        made("json", show.rawValue + (keeps ? "+" : "-")) {
            script(PageScript.load("json-view", vars: ["MODE": show.rawValue, "KEEPS": keeps ? "true" : "false", "COLORS": JSONView.colors]),
                   .atDocumentEnd, mainOnly: true)
        }
    }

    /// A chat's or a builder's Stop control watched (ChatBusy), one object
    /// for each site's list.
    static func busy(_ site: ChatBusy.Site) -> WKUserScript {
        made("busy", site.json) { script(PageScript.load("chat-busy", vars: ["SITE": site.json]), .atDocumentEnd, mainOnly: true) }
    }

    /// A site's hidden things.
    static func veils(_ css: String) -> WKUserScript {
        made("veils", css) { script(Veiling.style(css), .atDocumentStart, mainOnly: true) }
    }

    /// One object for each input a script is made from: the same input, the
    /// same object, so a list made of them compares equal. A few dozen are
    /// kept for each kind; past that they are made again.
    static func made(_ kind: String, _ input: String, _ make: () -> WKUserScript) -> WKUserScript {
        if let script = memo[kind]?[input] { return script }
        let script = make()
        if memo[kind, default: [:]].count >= 32 { memo[kind] = [:] }
        memo[kind, default: [:]][input] = script
        return script
    }
    private static var memo: [String: [String: WKUserScript]] = [:]
}

// Chromium adopts feature families only after their native receiver and
// page consumers use PageHandle. Keep the order of the shared list.
extension PageScripts {
    /// `WKUserScript.source` makes its string anew each time, and a Chromium
    /// tab keeps what it was given: 1.4 MB a tab of the same words. One script,
    /// one string; the few made for a site's own CSS fall out at a clear.
    private static var texts: [ObjectIdentifier: (script: WKUserScript, text: String)] = [:]
    private static func text(of script: WKUserScript) -> String {
        if let known = texts[ObjectIdentifier(script)] { return known.text }
        if texts.count >= 512 { texts.removeAll() }
        let text = script.source
        texts[ObjectIdentifier(script)] = (script, text)
        return text
    }

    private static let chromiumTips = PageScriptRegistration(source: PageScript.load("chromium-tips"), world: .yab, atEnd: false, mainOnly: false)

    static func chromium(for tab: Tab, _ arming: Arming, hiddenCSS: [String: String]? = nil) -> [PageScriptRegistration] {
        let chosenFonts = PageFonts.read()
        let list = list(for: tab, arming, chosenFonts: chosenFonts)
        // call: Meet's, Zoom's and Slack's own switches, read from the DOM.
        // linkCards and the peek origin: scripts the hover card and the peek
        // ask through PageHandle.run, with no message handler of their own.
        var selected = [TopDragRelay.script, navigationHold, scroll, drawn, picker, peekOrigin(force: tab.forcePeeks?() ?? false), linkCards,
                        icons, forms, formFrames, call, wallet, walletSoon, agentFrames,
                        swipe, images, sent, watched, badge, badgeBridge, windowBridge, share, shareBridge, pushBridge, withoutPasskeys, passkeyBridge, isolate, dev, devBridge, eyeDropper, eyeDropperBridge,
                        json(JSONShow.current, keeps: !tab.shy)]
        if !chosenFonts.css.isEmpty { selected.append(fonts(chosenFonts)) }
        if let site = ChatBusy.site(arming.host) { selected.append(busy(site)) }
        if tab.skipsAds { selected.append(YouTube.user) }
        if let items = memo["items"] { selected += items.values }
        // Dark pages: the proxy in the page's world, the engine and start
        // script in theirs, as armed for this document (Tab.darkArm).
        let dark = DarkPages.scripts(for: tab.darkState.armed)
        let darkWorld = Set(dark.filter { $0 !== DarkPages.proxy }.map(ObjectIdentifier.init))
        selected += dark
        let ids = Set(selected.map(ObjectIdentifier.init))
        // Yab's own site is told it is open in Yab (Dress), a mark in the DOM, made afresh each time.
        let dressed = Dress.ours(arming.host) ? Dress.script(Links.browser).source : nil
        let chosen: [PageScriptRegistration] = list.filter {
            ids.contains(ObjectIdentifier($0)) || (dressed != nil && $0.source == dressed) || $0 === tab.engineSwitchDocument?.script
        }.map {
            let world: PageWorld = $0 === agentFrames ? .agent
                : $0 === tab.engineSwitchDocument?.script ? .client
                : ($0 === badge || $0 === navigationHold || $0 === DarkPages.proxy || $0 === share || $0 === YouTube.user
                   || $0 === withoutPasskeys || $0 === dev || $0 === eyeDropper) ? .page
                : $0 === isolate ? .named("float")
                : darkWorld.contains(ObjectIdentifier($0)) ? DarkPages.pageWorld : .yab
            // No passkey script: Chromium's own WebAuthn checks a request,
            // then hands it to Yab (ChromiumWebAuthn).
            return PageScriptRegistration(source: text(of: $0), world: world,
                                          atEnd: $0.injectionTime == .atDocumentEnd, mainOnly: $0.isForMainFrameOnly)
        }
        // Yab's pushManager takes the place of Chromium's own (WebPush.swift).
        let windows = PageScriptRegistration(source: WindowRelay.page, world: .page, atEnd: false, mainOnly: true)
        let hidden = hiddenCSS ?? Curtain.shared.styles
        let veils = left.contains("all") || hidden.isEmpty ? [] : [PageScriptRegistration(
            source: Veiling.styles(hidden), world: .yab, atEnd: false, mainOnly: true)]
        return (omits("chromium-tips") ? [] : [chromiumTips]) + chosen
            + veils
            + (omits("window") ? [] : [windows])
            + (tab.shy || omits("chromium-push") ? [] : [PageScriptRegistration(source: PushRelay.chromiumPage, world: .page, atEnd: false, mainOnly: false)])
    }
}

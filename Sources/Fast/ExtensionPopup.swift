import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions, but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate, WKScriptMessageHandler {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    private var staging: NSViewController?
    private weak var anchor: NSView?
    private var layoutToken: String?
    private var layoutNavigation: WKNavigation?
    private var layoutDeadline: DispatchWorkItem?
    private(set) var layoutState = "closed"
    private var pendingEvents: Any?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window, Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private(set) var extensionID: String?
    /// The sign-in's extensions it is of (ExtensionSignIns): their
    /// controller is told of it, and its links open where they run.
    private(set) weak var owner: Extensions?
    private var controller: WKWebExtensionController { (owner ?? .shared).controller }
    static let closeHandler = "yabExtensionPopupClose"
    static let layoutHandler = "yabExtensionPopupLayout"
    static let layoutWorld = WKContentWorld.world(name: "yab-extension-popup-layout")
    private var closeController: WKUserContentController?
    /// The popup whose handler the shared controller holds now.
    private static weak var handlerOwner: ExtensionPopup?
    private var closeOrigin: URL?
    private var closeFor: String?
    private var closeToken: String?
    /// The extension's own button, when the popup hangs from it.
    private weak var button: NSView?
    /// The sliders the popup hangs from instead: an unpinned extension's,
    /// pressed in the list, or a pin's with no pin on screen to hang from.
    private weak var door: NSView?
    /// The popup a click on its own button just closed: the popover goes on
    /// that click's mouse-down, and the button's press comes after, on its
    /// mouse-up, which would open it again.
    private var closedByButton: (id: String, at: Date)?

    /// The popup's web view, while one is up, for the bench.
    var view: WKWebView? { web }
    /// A popup is up: the column it hangs from stays out (Lights.hanging).
    var isShown: Bool { staging != nil || popover?.isShown == true }
    /// A popup is up from the sliders: they stay on screen under it, as a
    /// pin does under its own (SidePlate, SiteControlsDoor).
    var fromDoor: Bool { isShown && door != nil }
    /// The popup is up from these sliders, one door's of several.
    func hangs(from view: NSView?) -> Bool { fromDoor && view != nil && door === view }
    /// Where the popup stands on screen and what it hangs from, for the bench.
    var frames: (popup: NSRect, from: NSRect)? {
        guard shown, popover?.isShown == true, let window = popover?.contentViewController?.view.window,
              let from = button ?? door, let home = from.window else { return nil }
        return (window.frame, home.convertToScreen(from.convert(from.bounds, to: nil)))
    }

    /// `taken`: the extensions list's popover, already up, which the popup
    /// takes over in place of opening one of its own (ExtensionPanel).
    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?, reusing taken: NSPopover? = nil) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        let initialSize = ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)
        // Start at the popover's usable viewport while measuring unseen.
        // A tiny temporary viewport lets a popup's scripts retain wrapped
        // content heights before its eventual width is known (Bitwarden's
        // carousel measures its tallest slide only once).
        // It has to be in the window meanwhile: WebKit suspends a page
        // that is in none.
        AppleWritingTools.configure(configuration)
        let web = QuietWebView(frame: NSRect(origin: .zero, size: initialSize), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        // WebKit lets script close a page it didn't open only while the
        // page has a single history entry (DOMWindow::close), and a popup
        // routed by its hash (Bitwarden's #/tabs/vault) has several by the
        // time it fills, so window.close() was refused and webViewDidClose
        // never came. Chrome closes a popup either way: window.close() is
        // carried here instead. Only this popup's own main document may ask.
        closeController = configuration.userContentController
        PasskeyRelay.install(in: configuration.userContentController)
        // The page's EyeDropper in its pages (EyeDropper.swift).
        EyeDropperRelay.install(in: configuration.userContentController)
        // Extension pages share this controller: a name already taken
        // would raise, so a stale handler goes first.
        closeController?.removeScriptMessageHandler(forName: Self.closeHandler)
        closeController?.add(self, name: Self.closeHandler)
        closeController?.removeScriptMessageHandler(forName: Self.layoutHandler, contentWorld: Self.layoutWorld)
        closeController?.add(self, contentWorld: Self.layoutWorld, name: Self.layoutHandler)
        Self.handlerOwner = self
        closeOrigin = context.baseURL
        closeFor = context.uniqueIdentifier
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over the popover's dark
        // material would vanish.
        web.alphaValue = 0
        let request = URLRequest(url: Extensions.unpopped(url))

        let stage = NSView(frame: NSRect(origin: .zero, size: initialSize))
        stage.alphaValue = 0
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        // The popover takes its size from its view controller: left at
        // zero, it came in as a sliver and grew to the size it was given,
        // rather than standing at it from the start.
        host.preferredContentSize = stage.frame.size
        let popover = taken ?? NSPopover()
        if taken == nil {
            popover.contentSize = stage.frame.size
            popover.behavior = .transient
            popover.animates = true
        }
        popover.delegate = self

        self.web = web
        self.popover = popover
        staging = host
        self.anchor = anchor
        extensionID = context.uniqueIdentifier
        let owner = Extensions.owner(of: context)
        self.owner = owner
        button = anchor != nil && anchor === owner.anchors[context.uniqueIdentifier]?.view ? anchor : nil
        door = anchor != nil && anchor === owner.anchors[Extensions.menuAnchor]?.view ? anchor : nil
        let page = PopupPage(web: web, owner: owner)
        self.page = page
        controller.didOpenTab(page)

        shown = false
        // Keep WebKit in an awake window for its first layout, without
        // putting a guessed-size popover on screen. The list, if this came
        // from it, stays in place until the page has its own size.
        let content = anchor?.window?.contentView ?? (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView
        content?.addSubview(stage)
        // Until there is a transient popover to dismiss, a click or Escape
        // cancels the pending opening just as it would close that popover.
        pendingEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.staging != nil else { return event }
                if event.type == .keyDown && event.keyCode != 53 { return event }
                if let id = self.extensionID, let button = self.button, event.window === button.window,
                   button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                    self.closedByButton = (id, Date())
                }
                self.close()
                return event
            }
        }
        layoutNavigation = web.load(request)
        // What it hangs from stays out under it, the pin or the sliders
        // (SidePlate, SiteControlsDoor), which read this popup but don't
        // watch it: told once it is up, as on close. The list handing its
        // popover over had told them first, before there was a popup, and
        // the sliders went with the list.
        DispatchQueue.main.async {
            owner.objectWillChange.send()
            SiteControlsState.shared.objectWillChange.send()
        }
        // A manager Yab unlocks, showing its lock screen: unlocked in place.
        ManagerKeep.inPlace(web, url: url)
        layoutState = "loading"
        // A failure deadline cancels the owned opening. It never declares a
        // guessed layout ready or reveals an unmeasured page.
        let deadline = DispatchWorkItem { [weak self, weak web] in
            guard let self, let web, self.web === web, !self.shown else { return }
            self.failLayout("layout readiness deadline")
        }
        layoutDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let popover, let host = staging else { return }
        stopPendingEvents()
        let stage = host.view
        stage.removeFromSuperview()
        stage.alphaValue = 1
        if popover.isShown {
            ExtensionPanel.replace(in: popover, with: host)
            popover.contentSize = host.preferredContentSize
        } else {
            popover.contentViewController = host
            popover.contentSize = host.preferredContentSize
            if let anchor, anchor.window != nil {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
                let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
                popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
            }
        }
        if let id = extensionID { Self.lastSize[id] = popover.contentSize }
        staging = nil
        shown = true
        web.frame = NSRect(origin: .zero, size: popover.contentSize)
        web.autoresizingMask = [.width, .height]
        web.window?.makeKey()
        web.window?.makeFirstResponder(web)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
        owner?.objectWillChange.send()
        SiteControlsState.shared.objectWillChange.send()
    }

    /// `lingering`: closed by its own page's window.close(). The popover
    /// goes at once; the page, and WebKit's tab for it, a moment later, so
    /// what it asked for just before still gets done. MetaMask's popup opens
    /// its onboarding with tabs.create and closes in the same breath, as
    /// Chrome lets it, and a popup let go at once lost that tab now and then
    /// (evals/extensions/wallet_tabs.py, relaunched).
    func close(lingering: Bool = false) {
        let closing = popover
        let lingers = lingering ? page.map { ($0, web) } : nil
        if lingers != nil { page = nil }
        forget()
        closing?.performClose(nil)
        if let (page, web) = lingers {
            let controller = controller
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                controller.didCloseTab(page, windowIsClosing: false)
                withExtendedLifetime(web) {}
            }
        }
    }

    /// Gives the popover up to the extensions list, which puts itself in
    /// the page's place (⌘E on an open popup). The page is closed; its view
    /// stays in the popover only while it fades. Nil when no popup is up.
    func handOver() -> NSPopover? {
        if staging != nil { close(); return nil }
        guard let popover, popover.isShown else { return nil }
        forget()
        return popover
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        stopPendingEvents()
        staging?.view.removeFromSuperview()
        staging = nil
        anchor = nil
        layoutDeadline?.cancel(); layoutDeadline = nil
        layoutToken = nil
        layoutNavigation = nil
        layoutState = "closed"
        shown = false
        held = 0
        closeToken = nil
        closeFor = nil
        closeOrigin = nil
        // Only while the shared controller's handler is still this popup's:
        // one pressed open as this one closes has put its own there.
        if Self.handlerOwner === self {
            closeController?.removeScriptMessageHandler(forName: Self.closeHandler)
            closeController?.removeScriptMessageHandler(forName: Self.layoutHandler, contentWorld: Self.layoutWorld)
            Self.handlerOwner = nil
        }
        closeController = nil
        if let page { controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
        door = nil
    }

    private func stopPendingEvents() {
        if let pendingEvents { NSEvent.removeMonitor(pendingEvents) }
        pendingEvents = nil
    }

    /// A press on the button of an extension whose popup is up closes it, as
    /// in Chrome: whether the popover is still there (a click on the view it
    /// hangs from doesn't close it) or went on this click's mouse-down.
    /// Closed, it is not opened again.
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }


    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still unseen. An absolutely positioned root shrink-wraps an auto
    /// width while preserving the page's declared width and height, even
    /// when those happen to equal the cached viewport on a second opening.
    /// Then lay it out at the bounded width to read its actual height.
    /// Nothing of the temporary constraints is left on the page.
    /// The constraints go in a constructed sheet of our own, adopted for
    /// the measurement only: the page's style attribute is never touched
    /// (WebKit left an empty style="" after restoring it), and the page's
    /// own observers see no mutation of its root.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const sheet = new CSSStyleSheet();
      const rule = extra => ":root:root:root{position:absolute!important;left:0!important;right:auto!important" + extra + "}";
      sheet.replaceSync(rule(""));
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      try {
        const w = Math.min(800, Math.max(25, Math.ceil(d.getBoundingClientRect().width)));
        const style = getComputedStyle(d);
        const inset = style.boxSizing === 'border-box' ? 0 :
          ['paddingLeft','paddingRight','borderLeftWidth','borderRightWidth']
            .reduce((sum, key) => sum + (parseFloat(style[key]) || 0), 0);
        sheet.replaceSync(rule(";width:" + Math.max(0, w - inset) + "px!important"));
        const h = d.getBoundingClientRect().height;
        return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
      } finally {
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter(item => item !== sheet);
      }
    }
    """

    /// The document is built, DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Proton
    /// Pass takes whatever size it finds then for good). WebKit tells a
    /// navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web, navigation === layoutNavigation else { return }
        installClose(in: webView)
        installLayout(in: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === web else { return }
        layoutNavigation = navigation
        layoutToken = nil
        layoutState = "loading"
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web, navigation === layoutNavigation else { return }
        closeToken = nil
        layoutToken = nil
    }

    private func owns(_ url: URL?) -> Bool {
        guard let url, let closeOrigin, extensionID == closeFor else { return false }
        return url.scheme == closeOrigin.scheme && url.host == closeOrigin.host
    }

    private func installClose(in webView: WKWebView) {
        guard owns(webView.url), let scheme = closeOrigin?.scheme, let host = closeOrigin?.host else { return }
        let token = UUID().uuidString
        guard let source = Self.closeBridge(scheme: scheme, host: host, token: token) else { return }
        closeToken = token
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    /// The page's window.close(), carried to the native side with this
    /// document's token. Any other window, origin or frame keeps WebKit's
    /// own close.
    static func closeBridge(scheme: String, host: String, token: String, handler: String = closeHandler) -> String? {
        // Scheme/host come from WebKit's extension base URL; serialize
        // them rather than interpolating an extension-provided string.
        guard let data = try? JSONSerialization.data(withJSONObject: [scheme + ":", host, token, handler]),
              let values = String(data: data, encoding: .utf8) else { return nil }
        return """
        (() => {
          const [scheme, host, token, handler] = \(values);
          if (window.top !== window || location.protocol !== scheme || location.host !== host) return;
          // The extension's shim made close before the page's scripts ran,
          // ahead of a sandbox that takes globals away (MetaMask's
          // LavaMoat): it is only told where to carry the call.
          const made = Object.getOwnPropertyDescriptor(window, "__yabPopupClose");
          if (made && typeof made.set === "function") { made.set.call(window, [handler, token]); return; }
          const original = window.close;
          window.close = function(...args) {
            if (this !== window || window.top !== window || location.protocol !== scheme || location.host !== host)
              return Reflect.apply(original, this, args);
            // The handler gone (a popup closing as this one came up takes
            // the shared controller's handler with it): WebKit's own close,
            // rather than a throw that left AdBlock's popup up after
            // "Pause on this site" and blank at the next press.
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler];
            if (!bridge) return Reflect.apply(original, this, args);
            bridge.postMessage(token);
          };
        })();
        """
    }

    /// Whether a close request is the popup's own: its document's current
    /// token, from its main frame, on the extension's origin.
    nonisolated static func acceptsClose(body: Any, token: String?, mainFrame: Bool,
                                         scheme: String, host: String, base: URL?) -> Bool {
        guard let token, (body as? String) == token, mainFrame, let base else { return false }
        return scheme == base.scheme && host == base.host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.layoutHandler {
            receiveLayout(message, controller: userContentController)
            return
        }
        guard message.name == Self.closeHandler, userContentController === closeController,
              let current = web, message.webView === current,
              Self.acceptsClose(body: message.body, token: closeToken, mainFrame: message.frameInfo.isMainFrame,
                                scheme: message.frameInfo.securityOrigin.protocol,
                                host: message.frameInfo.securityOrigin.host, base: closeOrigin),
              let token = closeToken, let id = extensionID, id == closeFor, owns(current.url) else { return }
        // Leave WebKit's message callback before notifying it that its tab
        // closed. A replaced popup or document invalidates this request.
        DispatchQueue.main.async { [weak self, weak current] in
            guard let self, let current, self.web === current, self.closeToken == token,
                  self.extensionID == id, self.owns(current.url) else { return }
            if Store.testing {
                FileHandle.standardError.write(Data("YAB_POPUP_SCRIPT_CLOSE window=\(current.window?.windowNumber ?? -1)\n".utf8))
            }
            self.close(lingering: true)
        }
    }

    private func failLayout(_ reason: String) {
        popupTrace("WebKit popup layout failed: \(reason)")
        close()
        layoutState = "failed"
    }

    private func installLayout(in web: WKWebView) {
        guard web === self.web, owns(web.url), layoutToken == nil else { return }
        let token = UUID().uuidString
        layoutToken = token
        let source = Self.layoutBridge(token: token)
        web.evaluateJavaScript(source, in: nil, in: Self.layoutWorld) { [weak self, weak web] result in
            guard let self, let web, self.web === web, self.layoutToken == token else { return }
            if case .failure(let error) = result { self.failLayout(String(describing: error)) }
        }
    }

    /// Only this popup's main document can publish its intrinsic size. A
    /// reused shared content controller or an obsolete document cannot reveal it.
    private func receiveLayout(_ message: WKScriptMessage, controller: WKUserContentController) {
        guard controller === closeController, let web, message.webView === web,
              message.frameInfo.isMainFrame, owns(web.url),
              message.frameInfo.securityOrigin.protocol == closeOrigin?.scheme,
              message.frameInfo.securityOrigin.host == closeOrigin?.host,
              let body = message.body as? [String: Any],
              let token = layoutToken, body["token"] as? String == token else { return }
        guard body["state"] as? String == "ready" else {
            if body["state"] as? String == "failed" { failLayout("document could not measure its layout") }
            return
        }
        guard let size = Self.layoutSize(body) else { failLayout("invalid document layout size"); return }
        layoutDeadline?.cancel(); layoutDeadline = nil
        layoutState = "ready"
        apply(size)
        if !shown { reveal() }
    }

    static func layoutSize(_ body: [String: Any]) -> NSSize? {
        guard let width = body["width"] as? Double, let height = body["height"] as? Double,
              width.isFinite, height.isFinite, (25...800).contains(width), (25...600).contains(height) else { return nil }
        return NSSize(width: width, height: height)
    }

    /// Load, fonts and actual DOM/layout changes drive measurement. The
    /// observer lives in our isolated world, without modifying extension APIs.
    static func layoutBridge(token: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [token, layoutHandler])
        let values = String(data: data, encoding: .utf8)!
        return """
        (() => {
          const [token, handler] = \(values);
          const key = '__yabPopupLayout';
          window[key]?.stop();
          let frame = 0, stopped = false, loaded = document.readyState === 'complete', last = '';
          const post = value => window.webkit.messageHandlers[handler].postMessage({token, ...value});
          const options = {subtree:true, childList:true, characterData:true, attributes:true};
          const mutations = new MutationObserver(() => schedule());
          const resize = new ResizeObserver(() => schedule());
          const observe = () => {
            mutations.observe(document.documentElement, options);
            resize.observe(document.documentElement);
            if (document.body) resize.observe(document.body);
          };
          const measure = (\(preferred));
          // A visible page measures once per frame. A hidden one (no
          // window yet, an occluded or minimized window) gets no frames:
          // WebKit suspends requestAnimationFrame and ResizeObserver there,
          // and the popup would never learn its size. It measures in a
          // microtask after the change instead; layout reads are synchronous.
          function schedule() {
            if (stopped || frame || !loaded || document.fonts?.status === 'loading') return;
            if (document.visibilityState === 'hidden') {
              frame = -1;
              queueMicrotask(run);
            } else {
              frame = requestAnimationFrame(run);
            }
          }
          function run() {
            frame = 0;
            if (stopped) return;
            mutations.disconnect();
            try {
              const size = measure();
              if (!size || !size.every(Number.isFinite)) throw Error('Invalid popup layout');
              // Reading layout can itself start a font request. Its
              // completion event will measure again with the real metrics.
              if (document.fonts?.status === 'loading') return;
              const stamp = JSON.stringify(size);
              if (stamp !== last) { last = stamp; post({state:'ready', width:size[0], height:size[1]}); }
            } catch (_) { post({state:'failed'}); }
            finally { if (!stopped) observe(); }
          }
          const onLoad = () => { loaded = true; schedule(); };
          const fonts = document.fonts;
          addEventListener('load', onLoad, {once:true});
          document.addEventListener('load', schedule, true);
          document.addEventListener('error', schedule, true);
          fonts?.addEventListener('loadingdone', schedule);
          fonts?.addEventListener('loadingerror', schedule);
          // A frame asked for just before the page went hidden never comes.
          const shown = () => {
            if (frame > 0) { cancelAnimationFrame(frame); frame = 0; }
            schedule();
          };
          document.addEventListener('visibilitychange', shown);
          const stop = () => {
            stopped = true; if (frame > 0) cancelAnimationFrame(frame); mutations.disconnect(); resize.disconnect();
            document.removeEventListener('visibilitychange', shown);
            removeEventListener('load', onLoad);
            document.removeEventListener('load', schedule, true);
            document.removeEventListener('error', schedule, true);
            fonts?.removeEventListener('loadingdone', schedule);
            fonts?.removeEventListener('loadingerror', schedule);
          };
          window[key] = {stop};
          addEventListener('pagehide', stop, {once:true});
          observe();
          schedule();
          return true;
        })();
        """
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if let staging {
            staging.preferredContentSize = size
            staging.view.setFrameSize(size)
            web?.setFrameSize(size)
            return
        }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID { ExtensionPopup.lastSize[id] = size }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === web else { return }
        close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, navigation === layoutNavigation else { return }
        installClose(in: webView)
        installLayout(in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === web, navigation === layoutNavigation else { return }
        failLayout(String(describing: error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web, navigation === layoutNavigation else { return }
        failLayout(String(describing: error))
    }

    /// A link that asks for a new window becomes a tab, and the popup goes,
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { (owner ?? .shared).opening()?.open(url, foreground: true) }
        close()
        return nil
    }

    /// Passkey requests from this popup still waiting on the Mac's sheet.
    private var held = 0

    /// Kept up while its page waits on the Mac's passkey sheet, which takes
    /// the focus a transient popover closes on (Bitwarden's unlock with a
    /// passkey). What comes back lets it go again; nil for any other page.
    static func hold(_ page: WKWebView) -> (() -> Void)? {
        let popup = shared
        guard popup.web === page, let popover = popup.popover else { return nil }
        popup.held += 1
        return { [weak popup, weak popover] in
            guard let popup, popover === popup.popover else { return }
            popup.held = max(0, popup.held - 1)
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover !== self.popover || held == 0
    }

    /// Closing on a mouse-down over the popup's own button.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let spot = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        forget()
        // The pin it kept out beside the address may go now, and the
        // sliders it hung from (the tab's door reads SiteControlsState).
        (owner ?? .shared).objectWillChange.send()
        SiteControlsState.shared.objectWillChange.send()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs, which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    unowned let owner: Extensions

    init(web: WKWebView, owner: Extensions) {
        self.web = web
        self.owner = owner
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    /// Said at the stand-in's address WebKit knows the popup by
    /// (ExtensionShims.mendPopup), not the page's own, as it was said at the
    /// copy's before: Chrome lists no tab for a popup, and an extension
    /// that looks for its page among the tabs, as Bitwarden does for its
    /// pop-outs, finds none. At the page's own address, Bitwarden's popup
    /// didn't open a second time (scripts/runs/bitwarden_feedback_check.sh).
    func url(for context: WKWebExtensionContext) -> URL? {
        guard let url = web?.url, !url.path.contains(Extensions.popupCopy),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return web?.url }
        parts.path = ExtensionShims.standIn(url.path)
        return parts.url ?? url
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

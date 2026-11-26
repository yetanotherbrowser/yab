import WebKit

/// WebKit alone owns a pending popup's configuration and related page.
/// The neutral event refers to it by id, and answers with a registered tab.
@MainActor
final class WebKitPopup {
    let configuration: WKWebViewConfiguration
    weak var tab: Tab?
    init(_ configuration: WKWebViewConfiguration) { self.configuration = configuration }
}

extension PageHandle {
    /// Temporary construction capability until Tab owns an engine factory.
    func webKitPopupTab(_ id: UUID, shy: Bool = false, bench: Bool = false) -> Tab? {
        guard let context = webKit?.navigationEvents.popups[id], context.tab == nil else { return nil }
        let tab = Tab(shy: shy, bench: bench, configuration: context.configuration, factory: .webKitOnly)
        context.tab = tab
        return tab
    }

    var webKitLinkWindow: LinkWindow? { webKit.flatMap { LinkWindow.owning(page: $0) } }
}

extension WKNavigationAction {
    /// Keep the Objective-C getter nullable until its result is checked.
    /// The Swift request getter force-bridges WebKit's nonnull contract;
    /// callers can reject an absent native request without trapping the app.
    @MainActor var nativeRequest: URLRequest? {
        guard let native = perform(#selector(getter: WKNavigationAction.request))?
            .takeUnretainedValue() as? NSURLRequest else { return nil }
        return native as URLRequest
    }
}

extension WebKitPageEvents {
    // WebKit's async creation callback keeps window.opener even when the
    // listener answers later. Never emulate it by loading an unrelated view.
    @objc(_webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:completionHandler:)
    func createPopup(_ webView: WKWebView, configuration: WKWebViewConfiguration,
                     action: WKNavigationAction, features: WKWindowFeatures,
                     completionHandler: @escaping (WKWebView?) -> Void) {
        guard let navigationRequest = action.nativeRequest else { completionHandler(nil); return }
        let menu = (webView as? PageView)?.takeMenuOpen(for: navigationRequest.url)
        if Store.testing, ProcessInfo.processInfo.environment["YAB_LINK_MENU_TRACE"] == "1" {
            print("LINK_MENU create type=\(action.navigationType.rawValue) flags=\(action.modifierFlags.rawValue) button=\(action.buttonNumber) matched=\(menu != nil)")
        }
        if #available(macOS 15.4, *), ContentWarm.holds(webView) { completionHandler(nil); return }
        if DocumentPiP.isRequest(navigationRequest.url) {
            let browser = listener as? Browser
            completionHandler(browser?.webKitDocumentPopup(webView, configuration: configuration, action: action, request: navigationRequest, features: features))
            return
        }
        guard let page = webView as? PageView, let listener else { completionHandler(nil); return }
        // Inherited handlers belong to the opener. A child gets its own
        // controller while preserving the supplied store and related view.
        configuration.userContentController = WKUserContentController()
        let id = UUID(), context = WebKitPopup(configuration)
        popups[id] = context
        let request = PagePopup(id: id, action: PageAction(action, request: navigationRequest), width: features.width?.doubleValue,
                                height: features.height?.doubleValue, toolbarsVisible: features.toolbarsVisibility?.boolValue,
                                menuForeground: menu)
        var answered = false
        listener.page(page, open: request) { [weak self, weak webView] target in
            guard !answered else { return }
            answered = true
            self?.popups[id] = nil
            guard let target, let tab = context.tab, target == tab.id, let webView else { completionHandler(nil); return }
            guard let child = tab.webKitOnly("Related WebKit popup") else { completionHandler(nil); return }
            guard SiteProcesses.related(of: child.configuration) === webView else {
                DebugLog.note("popup-unrelated", ["host": request.action.request.url?.host ?? ""])
                if request.action.request.url != nil { child.load(request.action.request) }
                completionHandler(nil)
                return
            }
            completionHandler(child)
        }
    }
}

extension Browser {
    /// Compatibility for separate WebKit surfaces and direct legacy tests.
    /// Tab pages install the asynchronous adapter callback above.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let page = webView as? PageView else {
            return webKitSurfacePopup(webView, createWebViewWith: configuration, for: action, windowFeatures: windowFeatures)
        }
        let adapter = page.navigationEvents
        let previous = adapter.listener
        adapter.listener = self
        defer { adapter.listener = previous }
        var child: WKWebView?
        adapter.createPopup(webView, configuration: configuration, action: action, features: windowFeatures) { child = $0 }
        return child
    }

    func webKitDocumentPopup(_ webView: WKWebView, configuration: WKWebViewConfiguration,
                            action: WKNavigationAction, request: URLRequest, features windowFeatures: WKWindowFeatures) -> WKWebView? {
        if ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1" {
            print("DOCUMENT_PIP popup request=\(request.url?.absoluteString ?? "nil") source=\(webView.url?.absoluteString ?? "nil") main=\(action.sourceFrame.isMainFrame) automatic=\(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)")
        }
        // A site's document PiP gets its own HTML window, never a new tab.
        if DocumentPiP.isRequest(request.url) {
            guard DocumentPiP.owning(page: webView) == nil,
                  action.sourceFrame.isMainFrame, let parent = tab(for: webView),
                  parent.webKitOnly("WebKit popup callbacks", build: false) === webView else { return nil }
            // Agent tabs allow automatic OAuth popups. That preference is
            // not permission to put a document panel on the user's screen.
            guard !parent.bench || Store.testing || RelayGuard.take(webView) == .page else { return nil }
            let origin = action.sourceFrame.securityOrigin
            let host = origin.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard origin.protocol == "https" || origin.protocol == "file" || (origin.protocol == "http" &&
                  (host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"))
            else { return nil }
            // Keep the old document alive until WebKit delivers pagehide.
            // Its close callback can arrive after the replacement opens.
            if parent.documentPiP.web != nil {
                parent.documentPiP.close()
                parent.documentPiP = DocumentPiP()
            }
            return parent.documentPiP.open(configuration: configuration, action: action, request: request,
                                           features: windowFeatures, source: parent, browser: self)
        }
        return nil
    }
}

// Separate WebKit surfaces, including a site's DocumentPiP child, remain
// outside the tab seam. Preserve their original synchronous popup path and
// raw frame/configuration behavior until those surfaces migrate as a unit.
extension Browser {
    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webKitSurfacePopup(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let menuForeground = (webView as? PageView)?.takeMenuOpen(for: action.request.url)
        // WebKit can send a modified link straight to this new-window path.
        // Use that action's click, as the navigation policy does; a plain
        // link or scripted window keeps its existing foreground behavior.
        let modifiedForeground: Bool? = action.modifierFlags.contains(.command) || Self.middleClick(action.buttonNumber)
            ? action.modifierFlags.contains(.shift) : nil
        if Store.testing, ProcessInfo.processInfo.environment["YAB_LINK_MENU_TRACE"] == "1" {
            print("LINK_MENU create type=\(action.navigationType.rawValue) flags=\(action.modifierFlags.rawValue) button=\(action.buttonNumber) matched=\(menuForeground != nil)")
        }
        if #available(macOS 15.4, *), ContentWarm.holds(webView) { return nil }
        if ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1" {
            print("DOCUMENT_PIP popup request=\(action.request.url?.absoluteString ?? "nil") source=\(webView.url?.absoluteString ?? "nil") main=\(action.sourceFrame.isMainFrame) automatic=\(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)")
        }
        // A site's document PiP gets its own HTML window, never a new tab.
        if DocumentPiP.isRequest(action.request.url) {
            guard DocumentPiP.owning(page: webView) == nil,
                  action.sourceFrame.isMainFrame, let parent = tab(for: webView),
                  parent.webKitOnly("WebKit popup callbacks", build: false) === webView else { return nil }
            // Agent tabs allow automatic OAuth popups. That preference is
            // not permission to put a document panel on the user's screen.
            guard !parent.bench || Store.testing || RelayGuard.take(webView) == .page else { return nil }
            let origin = action.sourceFrame.securityOrigin
            let host = origin.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard origin.protocol == "https" || origin.protocol == "file" || (origin.protocol == "http" &&
                  (host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"))
            else { return nil }
            // Keep the old document alive until WebKit delivers pagehide.
            // Its close callback can arrive after the replacement opens.
            if parent.documentPiP.web != nil {
                parent.documentPiP.close()
                parent.documentPiP = DocumentPiP()
            }
            return parent.documentPiP.open(configuration: configuration, action: action,
                                           features: windowFeatures, source: parent, browser: self)
        }
        let parent = tab(for: webView)
        let from = parent?.id ?? activeID
        // WebKit's copy of the opener's configuration still holds the
        // opener's content controller, its scripts and handlers. Shared, the
        // new tab took the handlers as its own, and sleeping or closing it
        // took them off the opener's page: the picture menu, forms and the
        // shield all went quiet there. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        // Asked for with no click of yours nearby: kept back, and the plate
        // says so (WindowGate).
        guard letsWebKitSurfaceWindow(from: webView, for: action, parent: parent) else { return nil }
        let popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        // window.open, not a link: the opener waits on this one's answer.
        let scripted = action.navigationType == .other ? Date() : nil
        // A plain target=_blank link stays in Small Window, as Little
        // Arc does, so Back uses that window's own history. Explicit new
        // tabs still go to the row; any other window the page opens, a
        // script's with or without a size, is a small window of its own
        // (smallWindowOpensBeside).
        if let parent, outside.contains(where: { $0.id == parent.id }) {
            if action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
               !popup, modifiedForeground == nil, menuForeground == nil,
               LinkWindow.owning(page: webView) != nil, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                _ = webView.load(action.request)
                return nil
            }
            let tab = Tab(shy: parent.shy, configuration: configuration, factory: .webKitOnly)
            tab.popup = popup
            tab.opener = from
            tab.from = from
            if action.navigationType == .linkActivated { linkBack(tab, to: parent) }
            tab.scripted = scripted
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            let size = windowFeatures.width.flatMap { width in
                windowFeatures.height.map { NSSize(width: width.doubleValue, height: $0.doubleValue) }
            }
            if Self.smallWindowOpensBeside(sized: size != nil, modified: modifiedForeground, menu: menuForeground) {
                prepare(tab)
                outside.append(tab)
                LinkWindow.present(tab, for: self, size: size)
            } else {
                adoptPagePopup(tab)
            }
            return webKitOpened(tab, by: webView, for: action)
        }
        // A window an agent's page opens, a sign-in with Google, most often,
        // is the agent's too: beside yours, behind what you are looking at,
        // and handed to you only if the agent asks.
        if let parent, parent.bench {
            let tab = Tab(bench: true, configuration: configuration, factory: .webKitOnly)
            tab.popup = popup
            prepare(tab)
            appendPagePopup(tab)
            tab.opener = from
            tab.from = from
            if action.navigationType == .linkActivated { linkBack(tab, to: parent) }
            tab.scripted = scripted
            tab.assistantSpace = parent.assistantSpace
            tab.agent = parent.agent
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            // Opened while you have the tab, you are the one signing in,
            // it comes to you, as any window you opened would.
            // What the agent needed of you there, it needs here now: the
            // sign-in goes on in this window.
            tab.inheritHandoff(from: parent)
            if Agents.optional.contains(parent.id) { Agents.optional.insert(tab.id) }
            defer { Agents.shared.recall() }
            if parent.id == activeID {
                activeID = tab.id
                editing = false
            } else {
                Bench.shared.house(tab)
            }
            return webKitOpened(tab, by: webView, for: action)
        }
        if popup {
            let tab = Tab(shy: parent?.shy ?? false, configuration: configuration, factory: .webKitOnly)
            tab.popup = true; tab.opener = from; tab.from = from; tab.scripted = scripted
            if let url = action.request.url { tab.setAddressOptimistically(url) }
            prepare(tab)
            outside.append(tab)
            let size = windowFeatures.width.flatMap { width in
                windowFeatures.height.map { NSSize(width: width.doubleValue, height: $0.doubleValue) }
            }
            LinkWindow.present(tab, for: self, size: size)
            return webKitOpened(tab, by: webView, for: action)
        }
        // A web page sending you on to an extension's own page in a new tab,
        // Nord Account handing NordPass back its sign-in (app.html?verify_token=):
        // WebKit's copy of the web page's configuration can't serve
        // chrome-extension://, and the tab came up blank or "couldn't load".
        // It is built for the extension instead, as a typed address is; the
        // web page that opened it gives up its hold on it.
        if let parent, !parent.shy, tabs.contains(where: { $0 === parent }),
           let url = action.request.url, let target = Self.extensionHost(of: url),
           target != webView.url.flatMap(Self.extensionHost(of:)) {
            _ = open(url, foreground: parent.id == activeID, from: parent, linked: true, backToSource: action.navigationType == .linkActivated)
            return nil
        }
        // A link to a site a rule keeps in another space: opened there, in
        // that space's sign-ins, as Arc's Air Traffic Control sends it
        // (LinkRoutes). Only a link you clicked, or Open Link in New Tab: a
        // script's window, a sign-in, talks to its page and stays by it.
        if action.navigationType == .linkActivated || menuForeground != nil, !popup, let parent,
           tabs.contains(where: { $0 === parent }), let url = action.request.url,
           routePageLink(url, from: parent, foreground: menuForeground ?? modifiedForeground ?? true) {
            return nil
        }
        // A link to a new tab from a pin or a kept tab: a peek over it, no
        // row, as Arc opens one from a pinned tab. A script's window, a
        // sign-in, still gets its tab: it talks to the page that opened it.
        if action.navigationType == .linkActivated, !popup, modifiedForeground == nil, let parent, parent.pin != nil || parent.kept,
           tabs.contains(where: { $0 === parent }), let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           !Self.isOAuthOrSignIn(url) {
            peek(url, from: parent)
            return nil
        }
        let tab = Tab(shy: parent?.shy ?? false, configuration: configuration, factory: .webKitOnly)
        tab.popup = popup
        if !popup, parent?.bench == false, (menuForeground ?? modifiedForeground ?? true) == false,
           menuForeground != nil || (WindowGate.gesture(action) && action.navigationType == .linkActivated) {
            tab.prepareVideoOpening(action.request.url)
        }
        if let parent, tabs.contains(where: { $0 === parent }) {
            // After the page that opened it and what that page already
            // opened, as Arc puts a link that opens a new tab.
            prepare(tab)
            insertPagePopup(tab, at: linkLanding(from: parent))
            tab.linkedFrom = parent.id
        } else {
            adoptPagePopup(tab)
        }
        tab.opener = from
        tab.from = from
        if action.navigationType == .linkActivated, let parent { linkBack(tab, to: parent) }
        tab.scripted = scripted
        // A link that opens in a new tab, from a page a search gathered: in
        // the folder too. Not a window a script asked for, a sign-in. With
        // ⌘-clicking links making folders, from a page in any folder of
        // today's: in it, right after the page, as Dia puts it.
        if action.navigationType == .linkActivated, !popup, let parent, let nest = parent.nest {
            if nest.research {
                gatherSearch(tab, from: parent)
            } else if nest.today, !nest.byExtension, prefs.linkFolders {
                tab.nest = nest
                if let at = tabs.firstIndex(where: { $0 === parent }), let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
                    move(tab, to: here > at ? at + 1 : at)
                }
                ColumnMotion.next(.folder)
                folderBook.refresh()
            }
        }
        // Shut again within seconds, it was a look: Peek's hint (Teach.swift).
        if action.navigationType == .linkActivated, !popup { tab.linkBorn = Date() }
        if menuForeground ?? modifiedForeground ?? true {
            activeID = tab.id
            editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return webKitOpened(tab, by: webView, for: action)
    }

    /// The new tab's view, for WebKit to make the opened window. It has to
    /// be related to the page that opened it, or WebKit raises and the app
    /// ends (crash #33). If ever not, the window loads on its own instead:
    /// a sign-in that can't talk back to its page, rather than a crash.
    private func webKitOpened(_ tab: Tab, by opener: WKWebView, for action: WKNavigationAction) -> WKWebView? {
        guard let web = tab.webKitOnly("Related WebKit popup") else { return nil }
        if SiteProcesses.related(of: web.configuration) === opener { return web }
        DebugLog.note("popup-unrelated", ["host": action.request.url?.host ?? ""])
        if action.request.url != nil { web.load(action.request) }
        return nil
    }


}

extension Browser {
    private func letsWebKitSurfaceWindow(from webView: WKWebView, for action: WKNavigationAction, parent: Tab?) -> Bool {
        let gesture = WindowGate.gesture(action)
        let view = webView as? PageView
        // A view no tab here holds, one let go when its tab went to sleep:
        // only what WebKit itself would have let through.
        guard let page = parent ?? peeking.flatMap({ $0.webKitOnly("WebKit popup callbacks", build: false) === webView ? $0 : nil }), !page.asleep else { return gesture }
        // An agent's tabs as they were: what their pages open lands behind
        // you, in tabs of their own.
        if page.bench { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let site = WindowGate.site(of: webView.url)
        var own = true
        if let frame = WindowGate.source(action), !frame.isMainFrame {
            let host = frame.securityOrigin.host
            own = !host.isEmpty && Browser.site(host) == webView.url?.host().map(Browser.site)
        }
        let ask = WindowGate.Ask(
            gesture: gesture,
            sinceInput: view?.lastInput.map { now - $0 },
            allowed: page.windows.visit || site.map(WindowGate.allows) == true,
            onScreen: onScreen(page.id),
            own: own
        )
        switch WindowGate.decide(ask, unasked: page.windows.unasked, now: now) {
        case .open(let input):
            if input {
                view?.lastInput = nil
            } else {
                page.windows.unasked = WindowGate.recent(page.windows.unasked, now: now) + [now]
            }
            return true
        case .block(let said):
            if said, let site { page.windows.block(BlockedWindow(url: action.request.url, site: site)) }
            return false
        }
    }

}

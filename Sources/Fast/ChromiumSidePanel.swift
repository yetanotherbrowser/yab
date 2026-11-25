import AppKit
import Combine
import SwiftUI
import WebKit
import YabCoreClient

/// An extension's side panel for a Chromium page, in the column where the
/// WebKit stack shows its panels (ExtensionSidePanelColumn). Chrome would
/// draw the panel in its own browser window, which Yab never shows, so Yab
/// hosts the extension's panel page itself, in the clicked tab's profile:
/// the page has the same origin, storage and chrome.* APIs as in Chromium.
///
/// Chrome keeps two kinds of panel per extension and window, and Yab the
/// same: the window's, from the extension's global options (the manifest's
/// `side_panel.default_path`, `setOptions({path})`), and a tab's own, from
/// `setOptions({tabId, path})`. Which one is in front follows the tab in
/// front, as Chromium's SidePanelUIBase::GetNewActiveKeyOnTabChanged chooses
/// (`switched`): a tab's own panel left open there comes back with it, its
/// own panel or else the window's is shown for a tab switched to, and with
/// neither the column closes. A panel switched away from is kept, its page
/// alive, as Chromium caches the view, until the column is closed.
@MainActor
final class ChromiumSidePanel: ObservableObject {
    static let shared = ChromiumSidePanel()

    final class Panel: Identifiable {
        let extensionID: String
        let contextID = UUID().uuidString
        let name: String
        let button: Extensions.Button?
        let tab: Tab
        let events: Events
        weak var browser: Browser?
        var id: String { contextID }
        /// The window's panel, or a tab's own (Chrome's id of that tab).
        var scope: Scope = .window
        /// The Yab tab a tab's own panel is for.
        weak var owner: Tab?
        /// A tab's own panel that was in front when its tab was left: in
        /// front again with its tab (its registry's active entry in Chrome).
        var leftOpen = false

        init(extensionID: String, name: String, button: Extensions.Button?, tab: Tab, events: Events, browser: Browser) {
            self.extensionID = extensionID
            self.name = name
            self.button = button
            self.tab = tab
            self.events = events
            self.browser = browser
        }
    }

    /// The panel page's own engine events: links it opens go to an ordinary
    /// tab of the window; nothing else from it is offered.
    final class Events: NSObject, WKNavigationDelegate, WKUIDelegate, PageEvents {
        weak var browser: Browser?
        var finished = false
        var failed = false

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            switch event {
            case .started: finished = false
            case .finished: finished = true
            case .failed(_, let error, _):
                if (error as NSError).code != NSURLErrorCancelled { failed = true }
            case .redirected, .committed: break
            }
        }

        func page(_ page: any PageHandle, ended reason: PageEnd?) { failed = true }

        func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) {
            if let url = popup.action.request.url, url.scheme == "https" || url.scheme == "http", let browser {
                _ = browser.open(url, foreground: true, atEnd: true)
            }
            reply(nil)
        }

        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) {
            reply(PageResponsePolicy.decide(response.response, canShowMIMEType: response.canShowMIMEType))
        }

        func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool) {
            // A panel is not one of Browser.tabs, but its downloads still
            // need the window's destination and lifetime owner. Without this
            // listener ChromiumPage cancels the native transfer. Keep the
            // panel itself out of the transient download-tab closing path.
            browser?.page(page, became: download, isMainFrame: false)
        }
    }

    /// Which of an extension's two panels: the window's or one tab's own.
    enum Scope: Equatable {
        case window
        case tab(Int)
    }

    /// What the extension said of its panel for one tab, read in its own
    /// origin, as Chromium's SidePanelService keeps it.
    struct Options: Equatable {
        /// getOptions({tabId}): the tab's own options, else the global ones.
        var path: String
        var enabled: Bool
        var openOnClick: Bool
        /// The tab's own panel page, "" when the tab has none (Chrome's
        /// contextual entry: its own options, enabled, with a path).
        var tabPath = ""
        /// The window's panel page, "" with the global options off.
        var globalPath = ""
        /// Chrome's id of the tab these are for, nil for the global ones.
        var tabID: Int?
    }

    /// What Chrome shows in the column when the tab in front changes, for
    /// the panel in front of one extension (`showing`) or none.
    enum Switched: Equatable {
        /// Nothing to change.
        case keep
        /// The new tab's own panel, left open when it was last in front.
        case leftOpen(String)
        /// The new tab's own panel, at this page.
        case tab(String)
        /// The window's panel, at this page.
        case window(String)
        /// No panel for the new tab: the column closes.
        case close
    }

    /// SidePanelUIBase::GetNewActiveKeyOnTabChanged and
    /// MaybeShowEntryOnTabStripModelChanged for one extension: with a panel
    /// showing, the new tab's left-open panel, else, when the extension has
    /// a window's panel, the tab's own one or that, else none. With none
    /// showing, only a left-open panel comes back. Chrome showed exactly
    /// this (panel_parity_chrome.py, Chrome 157): a tab with its own
    /// options off still shows the window's panel, and a tab's own panel
    /// never shown there doesn't open when the extension has no window's.
    nonisolated static func switched(showing: Bool, leftOpen: String?, options: Options?) -> Switched {
        if let leftOpen { return .leftOpen(leftOpen) }
        guard showing else { return .keep }
        guard let options, !options.globalPath.isEmpty else { return .close }
        return options.tabPath.isEmpty ? .window(options.globalPath) : .tab(options.tabPath)
    }

    @Published private(set) var panels: [Panel] = []
    private var following: [ObjectIdentifier: AnyCancellable] = [:]
    private var switching: [ObjectIdentifier: Task<Void, Never>] = [:]

    func panels(in browser: Browser) -> [Panel] { panels.filter { $0.browser === browser } }

    /// The window's panel pages Chrome has built, for the window Chrome's
    /// extensions see (ChromiumTabGroups): each one's remote id and profile.
    func pages(in browser: Browser) -> [(id: String, profile: String?)] {
        panels(in: browser).compactMap { panel in
            guard !panel.tab.shy, let page = panel.tab.builtPage as? ChromiumPage, let remote = page.remoteID else { return nil }
            return (remote, page.profile)
        }
    }

    /// The panel in the window's column now, if one is.
    func front(in browser: Browser) -> Panel? {
        guard browser.chatOpen, let context = browser.panelContextID, browser.panelExtension != nil else { return nil }
        return panels(in: browser).first { $0.contextID == context }
    }

    /// The button press for an extension without a popup on this page: its
    /// panel, when it has one it wants opened from its button. False hands
    /// the press back to Chrome's own action click.
    @available(macOS 15.4, *)
    func press(_ id: String, from tab: Tab) async -> Bool {
        guard let browser = (tab.delegate as? Browser) ?? BrowserWindows.shared.activeBrowser else { return false }
        if let open = front(in: browser), open.extensionID == id {
            close(open)
            return true
        }
        let panel = make(id, from: tab, browser: browser)
        guard let options = await read(panel, nativeTab: await nativeTab(of: tab, extension: id)),
              options.enabled, options.openOnClick, !options.path.isEmpty,
              let url = Self.url(id, options.path) else {
            panel.tab.close()
            return false
        }
        place(panel, options: options, url: url, for: tab)
        show(panel, url: url)
        return true
    }

    /// chrome.sidePanel.open() and Yab's own menu: the panel, whatever its
    /// button does.
    @available(macOS 15.4, *)
    func open(_ id: String, from tab: Tab) async -> Bool {
        guard let browser = (tab.delegate as? Browser) ?? BrowserWindows.shared.activeBrowser else { return false }
        let panel = make(id, from: tab, browser: browser)
        guard let options = await read(panel, nativeTab: await nativeTab(of: tab, extension: id)),
              options.enabled, !options.path.isEmpty,
              let url = Self.url(id, options.path) else {
            panel.tab.close()
            return false
        }
        place(panel, options: options, url: url, for: tab)
        show(panel, url: url)
        return true
    }

    /// chrome.sidePanel.open() from the extension itself (CEF patch 0095,
    /// `extension.sidePanelOpen`): Chrome resolved the panel page for this
    /// tab (its own options, else the global ones) and showed nothing, since
    /// its panel lives in a window Yab hides. Show exactly that page; whose
    /// it is, the tab's or the window's, is read once it is up.
    @available(macOS 15.4, *)
    @discardableResult
    func show(_ id: String, url: URL, from tab: Tab) -> Bool {
        guard url.scheme == "chrome-extension", url.host == id,
              let browser = (tab.delegate as? Browser) ?? BrowserWindows.shared.activeBrowser else { return false }
        // Already in front with this very page: open() keeps it, as in Chromium.
        if let open = front(in: browser), open.extensionID == id,
           (open.tab.builtPage as? ChromiumPage)?.url == url {
            return true
        }
        let panel = make(id, from: tab, browser: browser)
        show(panel, url: url)
        Task { @MainActor [weak self, weak panel, weak tab] in
            guard let self, let panel, let tab else { return }
            let native = await self.nativeTab(of: tab, extension: id)
            guard let options = await self.options(id, nativeTab: native, in: panel) else { return }
            self.place(panel, options: options, url: url, for: tab)
        }
        return true
    }

    /// The extension and panel page of an `extension.sidePanelOpen` event,
    /// or nil: a Chrome extension id (32 letters a to p) and a page of that
    /// extension's own origin, nothing else.
    nonisolated static func requested(_ params: [String: JSONValue]) -> (extensionID: String, url: URL)? {
        guard let id = params["extensionId"]?.string, validExtensionID(id),
              let spec = params["url"]?.string, !spec.isEmpty, spec.utf8.count <= 8192,
              let parts = URLComponents(string: spec), parts.scheme == "chrome-extension", parts.host == id,
              parts.user == nil, parts.password == nil, parts.port == nil,
              let url = parts.url else { return nil }
        return (id, url)
    }

    nonisolated static func validExtensionID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }
    }

    /// The person closed it (its cross, Hide Chat), or the extension's
    /// options took it away: the column closes and, as Chromium clears its
    /// cached panel views when the panel closes, every panel the window kept.
    func close(_ panel: Panel) {
        guard let browser = panel.browser else {
            drop(panel)
            return
        }
        if browser.panelContextID == panel.contextID {
            browser.moveChat(open: false)
            browser.panelExtension = nil
            browser.panelContextID = nil
            for kept in panels(in: browser) where kept !== panel { drop(kept) }
        }
        drop(panel)
    }

    /// The column went away with this panel in front (Browser.hideChat).
    func closePanel(contextID: String?) {
        guard let contextID, let panel = panels.first(where: { $0.contextID == contextID }) else { return }
        close(panel)
    }

    private func drop(_ panel: Panel) {
        panels.removeAll { $0 === panel }
        panel.tab.close()
        ChromiumTabGroups.shared.changed()
        if let browser = panel.browser, panels(in: browser).isEmpty {
            following[ObjectIdentifier(browser)] = nil
        }
    }

    // MARK: - the tab in front

    /// The tab in front changed: the panel Chrome would show for it.
    private func follow(_ browser: Browser) {
        let key = ObjectIdentifier(browser)
        guard following[key] == nil else { return }
        following[key] = browser.changes(\.activeID).removeDuplicates().dropFirst()
            .sink { [weak self, weak browser] _ in
                DispatchQueue.main.async {
                    guard let self, let browser else { return }
                    self.switching[key]?.cancel()
                    self.switching[key] = Task { @MainActor [weak self, weak browser] in
                        guard let self, let browser else { return }
                        await self.switched(in: browser)
                    }
                }
            }
    }

    private func switched(in browser: Browser) async {
        guard let tab = browser.active, tab.engineKind == .chromium else { return }
        let front = front(in: browser)
        // A tab's left-open panel takes the column back as in Chromium, but
        // never from a chat the person has there.
        let chatting = browser.chatOpen && front == nil && browser.panelExtension == nil
        let left = chatting ? nil : panels(in: browser).first { $0.leftOpen && $0.owner === tab }
        var options: Options?
        if left == nil, let front {
            let native = await nativeTab(of: tab, extension: front.extensionID)
            guard !Task.isCancelled, browser.active === tab else { return }
            options = await self.options(front.extensionID, nativeTab: native, in: front)
            guard !Task.isCancelled, browser.active === tab, self.front(in: browser) === front else { return }
        }
        switch Self.switched(showing: front != nil, leftOpen: left?.contextID, options: options) {
        case .keep:
            return
        case .leftOpen:
            guard let left else { return }
            leave(front, for: tab)
            left.leftOpen = false
            raise(left)
        case .tab(let path):
            guard let front, let url = Self.url(front.extensionID, path) else { return }
            leave(front, for: tab)
            if let kept = panels(in: browser).first(where: { $0.extensionID == front.extensionID && $0.owner === tab && $0.scope != .window }) {
                if (kept.tab.builtPage as? ChromiumPage)?.url != url { kept.tab.go(to: url) }
                raise(kept)
            } else if let native = options?.tabID {
                let panel = make(front.extensionID, from: tab, browser: browser)
                panel.scope = .tab(native)
                panel.owner = tab
                show(panel, url: url)
            }
        case .window(let path):
            guard let front, let url = Self.url(front.extensionID, path) else { return }
            if front.scope == .window { return }
            leave(front, for: tab)
            if let kept = panels(in: browser).first(where: { $0.extensionID == front.extensionID && $0.scope == .window }) {
                if (kept.tab.builtPage as? ChromiumPage)?.url != url { kept.tab.go(to: url) }
                raise(kept)
            } else {
                let panel = make(front.extensionID, from: tab, browser: browser)
                show(panel, url: url)
            }
        case .close:
            guard let front else { return }
            leave(front, for: tab)
            browser.moveChat(open: false)
            browser.panelExtension = nil
            browser.panelContextID = nil
        }
    }

    /// The panel in front goes behind for a switch to `tab`: a tab's own,
    /// for another tab, is kept to come back with its tab.
    private func leave(_ front: Panel?, for tab: Tab) {
        guard let front, front.scope != .window, front.owner !== tab else { return }
        front.leftOpen = true
    }

    /// A kept panel into the column's front.
    private func raise(_ panel: Panel) {
        guard let browser = panel.browser else { return }
        browser.panelTabID = nil
        browser.panelContextID = panel.contextID
        browser.panelExtension = panel.extensionID
        browser.moveChat(open: true)
    }

    // MARK: - the extension changing its options (CEF patch 0124)

    /// chrome.sidePanel.setOptions, as Chromium's ExtensionSidePanelCoordinator
    /// hears it (OnPanelOptionsChanged): for one tab's own panel (`tab`,
    /// Chrome's id) or the window's (nil), the options as now kept. Turned
    /// off, that panel goes, and in front it closes the column; a new path
    /// is loaded where it is, in front or kept.
    func optionsChanged(_ id: String, tab native: Int?, path: String?, enabled: Bool?) {
        let scope: Scope = native.map { .tab($0) } ?? .window
        for panel in panels where panel.extensionID == id && panel.scope == scope {
            if enabled == false {
                close(panel)
            } else if let path, let url = Self.url(id, path),
                      (panel.tab.builtPage as? ChromiumPage)?.url != url {
                if let browser = panel.browser, front(in: browser) === panel { panel.tab.go(to: url) } else { drop(panel) }
            }
        }
    }

    /// The fields of an `extension.sidePanelOptions` event (patch 0124).
    nonisolated static func changed(_ params: [String: JSONValue]) -> (extensionID: String, tab: Int?, path: String?, enabled: Bool?)? {
        guard let id = params["extensionId"]?.string, validExtensionID(id) else { return nil }
        let tab = params["tabId"]?.number.map { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
        let path = params["path"]?.string.flatMap { $0.utf8.count <= 8192 ? $0 : nil }
        let enabled: Bool? = params["enabled"].flatMap { if case .bool(let value) = $0 { return value } else { return nil } }
        return (id, tab, path, enabled)
    }

    // MARK: -

    /// The extension's panel page for a path its options name: only a page
    /// of its own origin (Chrome would load a web page there too; Yab
    /// doesn't host one in the column).
    nonisolated static func url(_ id: String, _ path: String) -> URL? {
        guard !path.isEmpty, let url = URL(string: "chrome-extension://\(id)/" + path.drop(while: { $0 == "/" })),
              url.host == id else { return nil }
        return url
    }

    /// Whose panel a new one is: the tab's own when the tab has one at this
    /// page, else the window's.
    private func place(_ panel: Panel, options: Options, url: URL, for tab: Tab) {
        if !options.tabPath.isEmpty, Self.url(panel.extensionID, options.tabPath) == url,
           let native = options.tabID {
            panel.scope = .tab(native)
            panel.owner = tab
        } else {
            panel.scope = .window
            panel.owner = nil
        }
    }

    @available(macOS 15.4, *)
    private func make(_ id: String, from source: Tab, browser: Browser) -> Panel {
        let page = (source.builtPage as? ChromiumPage)?.extensions.items.first { $0.id == id }
        let button = ChromiumColumn.shared.buttons(for: source, all: true).first { $0.id == id }
        let config = Web.configuration(shy: source.shy, store: source.store)
        let tab = Tab(shy: source.shy, configuration: config, engine: .chromium)
        let events = Events()
        events.browser = browser
        // The source's profile: the extension and its storage live there.
        tab.warmProfile = source.chromiumProfile
        tab.delegate = events
        tab.page.frame = CGRect(x: 0, y: 0, width: ChatLook.normal, height: 700)
        return Panel(extensionID: id, name: page?.name ?? button?.name ?? id, button: button, tab: tab, events: events, browser: browser)
    }

    /// Chrome's tab id for the page, from its extensions' action state
    /// (ChromiumColumn; one id per page, whichever extension read it), else
    /// read now for this extension, pinned or not: the column reads only
    /// pinned buttons' state, so an unpinned extension's panel was opened
    /// with the global options whatever the tab's own said. Nil until the
    /// page has its native tab, and then the options are the global ones.
    private func nativeTab(of source: Tab, extension id: String) async -> Int? {
        guard let page = source.builtPage as? ChromiumPage, let remote = page.remoteID else { return nil }
        if let states = ChromiumColumn.shared.states[remote] {
            if let own = states[id]?.nativeTab, own >= 0 { return own }
            if let any = states.values.compactMap(\.nativeTab).first(where: { $0 >= 0 }) { return any }
        }
        guard let core = ChromiumProcess.shared.connectedClient,
              let result = try? await ChromiumDRMExtensionSession.actions(of: source)
                .request("ext.actions.state", ["page": remote, "extensions": [id]], connectedTo: core),
              case .array(let rows) = result["actions"] else { return nil }
        // The page's id, from this extension's row (it has no button of its
        // own, maybe: a panel-only extension), else from any row.
        let ids = (rows.filter { $0["id"].string == id } + rows).compactMap { $0["tabId"].number.map { Int($0) } }
        return ids.first { $0 >= 0 }
    }

    /// Reads chrome.sidePanel's options from a document of the extension's
    /// own origin (its manifest, which every extension has), the only place
    /// the API answers. With Chrome's tab id, the tab's own options first,
    /// then the global ones, as Chromium resolves them for that tab.
    private func read(_ panel: Panel, nativeTab: Int?) async -> Options? {
        guard let manifest = URL(string: "chrome-extension://\(panel.extensionID)/manifest.json") else { return nil }
        panel.tab.go(to: manifest)
        for _ in 0..<60 {
            if panel.events.failed { return nil }
            if panel.events.finished, !panel.tab.page.isLoading,
               panel.tab.page.url?.host == panel.extensionID { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await options(panel.extensionID, nativeTab: nativeTab, in: panel)
    }

    /// The options for one tab, read in `document`, a page of the
    /// extension's own origin already up (a panel of its, or its manifest).
    private func options(_ id: String, nativeTab: Int?, in document: Panel) async -> Options? {
        guard document.extensionID == id else { return nil }
        let body = Self.optionsScript(tabID: nativeTab)
        guard let value = try? await document.tab.page.call(body, gesture: false) as? [String: Any] else { return nil }
        var options = Options(path: value["path"] as? String ?? "", enabled: value["enabled"] as? Bool ?? false,
                              // Only as the extension asked (setPanelBehavior), as in Chromium.
                              openOnClick: value["click"] as? Bool == true)
        options.tabPath = value["tab"] as? String ?? ""
        options.globalPath = value["global"] as? String ?? ""
        options.tabID = nativeTab
        return options
    }

    /// getOptions as Chromium answers it: for a tab, its own options (they
    /// carry its tabId) or else the global ones; an entry is one enabled
    /// with a path (IsSidePanelEnabled).
    nonisolated static func optionsScript(tabID: Int?) -> String {
        let tab = tabID.map(String.init) ?? "null"
        return """
        const tabId = \(tab);
        const m = chrome.runtime.getManifest();
        const fallback = (m.side_panel && m.side_panel.default_path) || '';
        if (!chrome.sidePanel) return {path: fallback, enabled: false, click: false, tab: '', global: ''};
        const o = await chrome.sidePanel.getOptions(tabId === null ? {} : {tabId}).catch(() => ({}));
        const g = tabId === null ? o : await chrome.sidePanel.getOptions({}).catch(() => ({}));
        const b = await chrome.sidePanel.getPanelBehavior().catch(() => ({}));
        const entry = x => x && x.enabled === true && x.path ? x.path : '';
        return {path: o.path || fallback, enabled: o.enabled === true, click: !!b.openPanelOnActionClick,
                tab: tabId !== null && o.tabId === tabId ? entry(o) : '', global: entry(g)};
        """
    }

    private func show(_ panel: Panel, url: URL) {
        guard let browser = panel.browser else { return }
        // The one in front goes behind: a tab's own is kept for its tab, and
        // comes back with it when it was left for another; the window's is
        // kept for the next tab without one of its own. One of the same
        // extension in the same place, the window or that tab, is replaced.
        if let old = front(in: browser), old !== panel, old.scope != .window {
            old.leftOpen = old.owner !== browser.active
        }
        for old in panels(in: browser) where old !== panel && old.extensionID == panel.extensionID
            && (old.scope == .window) == (panel.scope == .window) && (old.scope == .window || old.owner === panel.owner) {
            drop(old)
        }
        panels.append(panel)
        ChromiumTabGroups.shared.changed()
        panel.tab.go(to: url)
        browser.panelTabID = nil
        browser.panelContextID = panel.contextID
        browser.panelExtension = panel.extensionID
        browser.moveChat(open: true)
        follow(browser)
    }

    var benchState: [[String: Any]] {
        panels.map { panel in
            let page = panel.tab.builtPage as? ChromiumPage
            let rect = page.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } } ?? .zero
            return ["contentOnScreen": [rect.minX, (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, rect.width, rect.height],"extension": panel.extensionID, "context": panel.contextID, "url": page?.url?.absoluteString ?? "",
                    "title": page?.title ?? "", "loading": page?.isLoading ?? false,
                    "front": panel.browser?.panelContextID == panel.contextID && panel.browser?.chatOpen == true,
                    "scope": { if case .tab(let id) = panel.scope { return id } else { return -1 } }(),
                    "owner": panel.owner.map { $0.id.uuidString } ?? "", "leftOpen": panel.leftOpen,
                    "remote": page?.remoteID ?? "", "surface": page?.contextID ?? 0,
                    "visible": page.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false]
        }
    }
}

private struct ChromiumSidePanelPage: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = tab.builtPage as? NSView, view.superview !== container else { return }
        view.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// ExtensionSidePanelColumn's look, round a Chromium panel page.
@available(macOS 15.4, *)
struct ChromiumSidePanelColumn: View {
    let browser: Browser
    let panel: ChromiumSidePanel.Panel
    let width: CGFloat
    @Environment(\.tabTitleSize) private var titleSize
    private static let inset: CGFloat = 4
    private static var cross: ButtonSize { SideBar.row >= ButtonSize.regular.height + 8 ? .regular : .small }
    private static var pageCorner: CGFloat { Radius.surface - inset } // design: concentric with the column's own corner, the inset in

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SideBar.markGap) {
                if let button = panel.button {
                    ExtensionIcon(button: button, size: SideBar.mark)
                        .frame(width: SideBar.mark, height: SideBar.mark)
                }
                Text(panel.name)
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    ChromiumSidePanel.shared.close(panel)
                } label: { Symbol("xmark", size: 13) }
                    .buttonStyle(.yab(.quiet, Self.cross, tint: Palette.ink, icon: .square))
                    .focusable(false)
                    .keyTip("Close", shortcut: "Hide Chat")
            }
            .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
            .padding(.trailing, (SideBar.row - Self.cross.height) / 2) // design: the cross's middle half a row in
            .frame(height: SideBar.row)
            .padding([.horizontal, .top], Self.inset)
            ChromiumSidePanelPage(tab: panel.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.pageCorner, style: .continuous))
                .padding([.horizontal, .bottom], Self.inset)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { HUD.plate(Radius.surface, surface: .page) }
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
    }
}

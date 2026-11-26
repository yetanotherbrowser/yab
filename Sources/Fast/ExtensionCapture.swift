import AppKit
import WebKit

// chrome.desktopCapture and chrome.tabCapture, through Yab's own share.
//
// Chrome hands an extension a stream id: for a tab, screen or window picked
// in its picker (desktopCapture.chooseDesktopMedia), or for a tab the
// extension was invoked on (tabCapture.getMediaStreamId). The extension's
// page then asks getUserMedia for it with {chromeMediaSource,
// chromeMediaSourceId} and gets a MediaStream. Loom, Screenity and Awesome
// Screenshot record that way.
//
// Here the id is a token for a Share.Source, picked in the box a page's
// getDisplayMedia gets (SharePicker), one use, for a minute, for the
// extension it was given to only. The shim's getUserMedia in the
// extension's page sends it with the share's own question (share-page.js
// `stream`), and the share goes on as a page's would: Yab captures and
// encodes, the page decodes into a track (docs/screen-share.md). A tab
// recorded says "Recorded by" the extension, with Stop, and its page
// "Recording". The same id asked for with audio gives a tab's sound too
// (ExtensionTabAudio): each of the picture and the sound once.

@MainActor
enum ExtensionCapture {
    struct Grant {
        let source: Share.Source
        let label: String
        let extensionID: String
        let extensionName: String
        /// The extension's pages' origin host: only those may use it.
        let host: String
        let made: Date
        /// What it was taken for already: "picture", "sound".
        var taken: Set<String> = []
    }

    private static var grants: [String: Grant] = [:]
    /// Pickers up for an extension, by the request id chooseDesktopMedia
    /// returned, so cancelChooseDesktopMedia can take one away.
    private static var picking: [Int: (tab: Tab, browser: Browser)] = [:]

    static func mint(_ source: Share.Source, label: String, context: WKWebExtensionContext) -> String {
        let now = Date()
        grants = grants.filter { now.timeIntervalSince($0.value.made) < 60 }
        let token = UUID().uuidString.lowercased()
        grants[token] = Grant(source: source, label: label, extensionID: context.uniqueIdentifier,
                              extensionName: context.webExtension.displayName ?? "An extension",
                              host: context.baseURL.host() ?? "", made: now)
        return token
    }

    /// The share a page's getUserMedia names, once: only from the
    /// extension's own page, within a minute of being given.
    /// `kind`: "picture" or "sound", each taken once.
    static func redeem(_ token: String, from frame: WKFrameInfo, for kind: String = "picture") -> Grant? {
        guard var grant = grants[token], Date().timeIntervalSince(grant.made) < 60, !grant.taken.contains(kind),
              frame.securityOrigin.protocol == Extensions.scheme, frame.securityOrigin.host == grant.host
        else { return nil }
        grant.taken.insert(kind)
        grants[token] = grant.taken.count >= 2 ? nil : grant
        return grant
    }

    // MARK: - the API

    /// desktopCapture.chooseDesktopMedia: the box over the tab named or the
    /// one in front, with the kinds asked for. "" when told no.
    static func choose(_ sources: [String], tabIndex: Int?, request: Int, context: WKWebExtensionContext,
                       owner: Extensions, browser: Browser) async -> [String: Any] {
        var kinds: Set<SharePicker.Kind> = []
        if sources.contains("tab") { kinds.insert(.tabs) }
        if sources.contains("window") { kinds.insert(.windows) }
        if sources.contains("screen") { kinds.insert(.screens) }
        let visible = owner.visibleTabs
        let anchor = tabIndex.flatMap { visible.indices.contains($0) ? visible[$0] : nil } ?? browser.active
        guard !kinds.isEmpty, let anchor else { return ["id": ""] }
        let name = context.webExtension.displayName ?? "An extension"
        return await withCheckedContinuation { continuation in
            picking[request] = (anchor, browser)
            browser.pickShare(for: name, kinds: kinds, on: anchor) { source, label in
                picking[request] = nil
                guard let source else { return continuation.resume(returning: ["id": ""]) }
                // A tab's sound can come with it (ExtensionTabAudio); a
                // window's or a screen's can't.
                var tab = false
                if case .tab = source { tab = true }
                continuation.resume(returning: ["id": mint(source, label: label, context: context),
                                                "canRequestAudioTrack": tab && sources.contains("audio")])
            }
        }
    }

    static func cancel(_ request: Int) {
        guard let (tab, browser) = picking.removeValue(forKey: request) else { return }
        browser.answer(tab, .no)
    }

    static func forget(_ browser: Browser) {
        let requests = picking.filter { $0.value.browser === browser }.map(\.key)
        for request in requests { cancel(request) }
    }

    /// tabCapture.getMediaStreamId: a tab the extension was invoked on, its
    /// button or menu pressed there (activeTab), as Chromium asks.
    static func tabStream(tabIndex: Int, context: WKWebExtensionContext, owner: Extensions) throws -> String {
        let visible = owner.visibleTabs
        guard visible.indices.contains(tabIndex) else { throw ExtensionShims.Unsupported(what: "No tab with that id") }
        let tab = visible[tabIndex]
        guard context.hasActiveUserGesture(in: owner.adapter(for: tab)) else {
            throw ExtensionShims.Unsupported(what: "Extension has not been invoked for the current page (see activeTab permission). Chrome pages cannot be captured.")
        }
        return mint(.tab(tab.id), label: tab.rowLabel, context: context)
    }

    // MARK: - offscreen documents

    /// An extension that may capture gets Yab's share in its offscreen
    /// document, the page MV3 recorders record in (Awesome Screenshot,
    /// Screenity): the page's side and the bridge, and a relay of its own.
    /// Its own controller, since extension pages share one and a relay
    /// there would answer whichever page asked last. Others are left as
    /// they were.
    static func arm(_ configuration: WKWebViewConfiguration, for context: WKWebExtensionContext) -> Relay? {
        let asked = Set((context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        guard !asked.isDisjoint(with: ["tabCapture", "desktopCapture"]) else { return nil }
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: ShareScript.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: ShareScript.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        let relay = Relay()
        controller.add(relay, contentWorld: Web.world, name: ShareScript.name)
        configuration.userContentController = controller
        return relay
    }

    /// A recorder's offscreen document in a window of its own, off every
    /// screen, never shown: WebKit lets no page that is in no window start
    /// media (an AudioContext stays suspended), and a recorder's page plays
    /// what it hears or listens to it (Volume Master, the tab's sound).
    /// Only such pages, one window for all of them.
    private static var seats: NSWindow?

    static func seat(_ page: WKWebView) {
        let window = seats ?? {
            let made = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
                                styleMask: [.borderless], backing: .buffered, defer: true)
            made.isReleasedWhenClosed = false
            made.isExcludedFromWindowsMenu = true
            made.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            made.ignoresMouseEvents = true
            made.alphaValue = 0
            made.orderBack(nil)
            seats = made
            return made
        }()
        page.frame = window.contentView?.bounds ?? page.frame
        window.contentView?.addSubview(page)
    }

    /// An offscreen document's questions (share-bridge.js), to the browser.
    final class Relay: NSObject, WKScriptMessageHandler {
        weak var page: WKWebView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let page, message.webView === page, let body = message.body as? [String: Any],
                      let browser = Extensions.shared.browser else { return }
                browser.shareAsked(page: page, body, message.frameInfo)
            }
        }
    }
}

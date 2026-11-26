import Foundation
import WebKit

// Chrome's externally_connectable, for web pages.
//
// An extension's manifest can name sites whose pages may talk to it:
// chrome.runtime.sendMessage(extensionID, message) or connect(extensionID)
// from the page, heard in the extension's worker as
// runtime.onMessageExternal or onConnectExternal. Claude for Chrome signs in
// this way (claude.ai hands its worker the OAuth redirect), as do 1Password's
// Add Browser, Bitwarden's desktop handoff and clippers' sign-ins. WebKit
// has none of it: such a page found no chrome.runtime at all.
//
// So a page some installed extension's matches name gets those two
// functions (extension-external-page.js, in its own world), which reach Yab
// through a bridge in Yab's world. Yab checks the frame's origin against
// that extension's matches itself, wakes the extension and its worker if
// they sleep, and hands the message over a port the worker's shim opens to
// Yab ("yab.external", see extension-shims.js); the answer comes back the
// same way. An unknown id, or a page the extension doesn't let in, is told
// what Chrome tells it.

/// Yab's side of the page's chrome.runtime, in Yab's own world. Not tied
/// to a macOS version, as the tab's other relays aren't; before 15.4 there
/// are no extensions, and every request is answered as one to nobody.
final class ExternalRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "yabExternal"
    static let shared = ExternalRelay()
    static let asked = "yab-external-ask"
    static let answered = "yab-external-answer"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            if #available(macOS 15.4, *) {
                ExtensionExternal.shared.take(message, reply: { replyHandler($0, nil) })
            } else {
                replyHandler(["error": ExtensionExternal.noReceiver], nil)
            }
        }
    }

    /// In Yab's world: the page's request handed over as it is, the answer
    /// dispatched back.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabExternalBridged) return;
      window.__yabExternalBridged = true;
      window.addEventListener('\(asked)', function (event) {
        var message;
        try { message = JSON.parse(event.detail); } catch (e) { return; }
        if (!message || typeof message !== 'object' || typeof message.kind !== 'string') return;
        function answer(reply) {
          if (typeof message.token !== 'string') return;
          window.dispatchEvent(new CustomEvent('\(answered)', { detail: JSON.stringify({ token: message.token, reply: reply || {} }) }));
        }
        handler.postMessage(message).then(answer, function () { answer({ error: 'Could not establish connection. Receiving end does not exist.' }); });
      });
    })();
    """
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionExternal {
    static let shared = ExtensionExternal()

    /// The port a worker's shim opens to Yab for what pages send it.
    nonisolated static let portName = "yab.external"
    nonisolated static let noReceiver = "Could not establish connection. Receiving end does not exist."

    /// Each enabled extension's externally_connectable matches, by id.
    private(set) var table: [String: [String]] = [:]
    /// The page's script and its bridge for that table, one pair of objects
    /// for as long as the table stays the same (PageScripts.fit compares
    /// them by identity); none when no extension lets any page in.
    private(set) var scripts: [WKUserScript] = []
    private var read: [String: (version: String, matches: [String])] = [:]

    /// How an extension is found and woken, by its key (`key(_:in:)`):
    /// Extensions by default; a test gives its own.
    var context: (String) -> WKWebExtensionContext? = { key in
        let (signIn, id) = ExtensionExternal.parts(key)
        return Extensions.instance(signIn).contexts[id]
    }
    var wake: (String, @escaping () -> Void) -> Void = { key, then in
        let (signIn, id) = ExtensionExternal.parts(key)
        Extensions.instance(signIn).wake(id, then: then)
    }
    /// The sign-in a page is made in: its message goes to that sign-in's
    /// extension, never another's (ExtensionSignIns).
    var signIn: (WKWebView) -> UUID? = { Extensions.signIn(of: $0.configuration.websiteDataStore) }

    /// What links, ports and answers are kept by: the extension's id, and
    /// for a space's own sign-in that sign-in before it.
    nonisolated static func key(_ id: String, in signIn: UUID?) -> String {
        signIn.map { $0.uuidString.lowercased() + "." + id } ?? id
    }

    /// A key's sign-in and extension id. A dot never is in either, and a
    /// key can stand as an address's host (ExtensionOmnibox).
    nonisolated static func parts(_ key: String) -> (signIn: UUID?, id: String) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let signIn = UUID(uuidString: parts[0]) else { return (nil, key) }
        return (signIn, parts[1])
    }
    /// How long a woken worker has to open its port.
    var patience: Duration = .seconds(10)

    private var links: [String: WKWebExtension.MessagePort] = [:]
    private var waiting: [String: [UUID: CheckedContinuation<WKWebExtension.MessagePort?, Never>]] = [:]
    /// Answers owed to pages, by number, with the extension they wait on.
    private var owed: [Int: (id: String, reply: (Any?) -> Void)] = [:]
    private var counter = 0
    private struct PagePort {
        let id: String
        weak var web: WKWebView?
        let frame: WKFrameInfo
    }
    private var pagePorts: [String: PagePort] = [:]

    // MARK: - which pages

    /// Read again from each enabled extension's prepared manifest whenever
    /// the list of extensions changes; a manifest is read once per version.
    func refresh(_ installed: [Installed]) {
        var next: [String: [String]] = [:]
        for item in installed where item.enabled {
            if let kept = read[item.id], kept.version == item.version {
                if !kept.matches.isEmpty { next[item.id] = kept.matches }
                continue
            }
            let url = Extensions.folder(for: item.id).appendingPathComponent("manifest.json")
            let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
            let matches = ExtensionShims.externalPages(of: manifest)
            read[item.id] = (item.version, matches)
            if !matches.isEmpty { next[item.id] = matches }
        }
        set(next)
    }

    func set(_ next: [String: [String]]) {
        guard next != table || (scripts.isEmpty && !next.isEmpty) else { return }
        table = next
        scripts = next.isEmpty ? [] : Self.scripts(for: next)
    }

    static func scripts(for table: [String: [String]]) -> [WKUserScript] {
        let json = (try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let page = PageScript.load("extension-external-page", vars: ["TABLE": json, "ASKED": ExternalRelay.asked, "ANSWERED": ExternalRelay.answered])
        return [WKUserScript(source: page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
                WKUserScript(source: ExternalRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)]
    }

    /// The address a frame is judged by: its own, or for a frame whose
    /// document came from elsewhere (about:blank, srcdoc) its origin's.
    /// WebKit's word, never the page's.
    static func address(of frame: WKFrameInfo) -> URL? {
        let origin = frame.securityOrigin
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        let root = origin.protocol + "://" + origin.host + (origin.port != 0 ? ":\(origin.port)" : "")
        if let url = frame.request.url, url.scheme == origin.protocol, url.host() == origin.host,
           (url.port ?? 0) == origin.port || (url.port == nil && origin.port == 0) {
            return url
        }
        return URL(string: root + "/")
    }

    static func allows(_ matches: [String], _ url: URL) -> Bool {
        matches.contains { pattern in
            (try? WKWebExtension.MatchPattern(string: pattern))?.matches(url) ?? false
        }
    }

    // MARK: - the page asks

    func take(_ message: WKScriptMessage, reply: @escaping (Any?) -> Void) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let id = body["id"] as? String, let web = message.webView
        else { return reply(["error": Self.noReceiver]) }
        let frame = message.frameInfo
        guard let url = Self.address(of: frame), let matches = table[id], Self.allows(matches, url) else {
            return reply(["error": Self.noReceiver])
        }
        let key = body["port"] as? String ?? ""
        // Its sign-in's extension, by that key from here on.
        let keyed = Self.key(id, in: signIn(web))
        switch kind {
        case "send":
            let sender = self.sender(url: url, frame: frame, web: web)
            Task {
                guard let link = await self.link(for: keyed) else { return reply(["error": Self.noReceiver]) }
                self.counter += 1
                let n = self.counter
                self.owed[n] = (keyed, reply)
                link.sendMessage(["__yabExternal": "message", "n": n, "message": body["message"] ?? NSNull(), "sender": sender]) { [weak self] error in
                    guard error != nil else { return }
                    Task { @MainActor in
                        guard let owed = self?.owed.removeValue(forKey: n) else { return }
                        owed.reply(["error": Self.noReceiver])
                    }
                }
            }
        case "connect":
            guard !key.isEmpty, pagePorts[key] == nil else { return reply(["error": Self.noReceiver]) }
            let sender = self.sender(url: url, frame: frame, web: web)
            pagePorts[key] = PagePort(id: keyed, web: web, frame: frame)
            Task {
                guard let link = await self.link(for: keyed), self.pagePorts[key] != nil else {
                    self.pagePorts[key] = nil
                    return reply(["error": Self.noReceiver])
                }
                link.sendMessage(["__yabExternal": "connect", "port": key, "name": body["name"] as? String ?? "", "sender": sender], completionHandler: nil)
                reply(["ok": true])
            }
        case "post", "disconnect":
            guard let open = pagePorts[key], open.id == keyed, open.web === web else { return reply(nil) }
            if kind == "disconnect" { pagePorts[key] = nil }
            if let link = live(keyed) {
                var said: [String: Any] = ["__yabExternal": kind, "port": key]
                if kind == "post" { said["message"] = body["message"] ?? NSNull() }
                link.sendMessage(said, completionHandler: nil)
            } else if kind == "post" {
                pagePorts[key] = nil
                tell(open, port: key, ["disconnect": true, "error": Self.noReceiver])
            }
            reply(nil)
        default:
            reply(["error": Self.noReceiver])
        }
    }

    /// Chrome's MessageSender for a web page: its origin and address, the
    /// frame, and the tab, by its place in the window (the worker's shim
    /// finds the tab WebKit knows there).
    private func sender(url: URL, frame: WKFrameInfo, web: WKWebView) -> [String: Any] {
        let origin = frame.securityOrigin
        let place = self.place(web)
        return [
            "origin": origin.protocol + "://" + origin.host + (origin.port != 0 ? ":\(origin.port)" : ""),
            "url": frame.request.url?.absoluteString ?? url.absoluteString,
            "frameId": frame.isMainFrame ? 0 : 1,
            "tab": ["index": place?.index ?? -1, "url": place?.url ?? web.url?.absoluteString ?? url.absoluteString],
        ]
    }

    /// Where a page's tab is: its place among its window's tabs, and its
    /// address.
    var place: (WKWebView) -> (index: Int, url: String?)? = { web in
        let owner = Extensions.of(store: web.configuration.websiteDataStore)
        guard let tab = owner.tab(showing: web) else { return nil }
        let browser = owner.window(of: tab)?.browser ?? owner.browser
        return (owner.visibleTabs(in: browser).firstIndex { $0.id == tab.id } ?? -1, tab.address.map { Extensions.popped($0).absoluteString })
    }

    // MARK: - the worker

    /// The worker's port, opened as it starts; the extension and its
    /// worker woken first if they sleep.
    private func link(for id: String) async -> WKWebExtension.MessagePort? {
        if let link = live(id) { return link }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in wake(id) { done.resume() } }
        if let link = live(id) { return link }
        guard let context = self.context(id), context.webExtension.hasBackgroundContent else { return nil }
        let ticket = UUID()
        let patience = patience
        return await withCheckedContinuation { (done: CheckedContinuation<WKWebExtension.MessagePort?, Never>) in
            waiting[id, default: [:]][ticket] = done
            Extensions.instance(Self.parts(id).signIn).trace(Self.parts(id).id, "a web page's message woke the worker")
            context.loadBackgroundContent { _ in }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: patience)
                self?.waiting[id]?.removeValue(forKey: ticket)?.resume(returning: nil)
            }
        }
    }

    /// The worker's port while the worker is up. WebKit doesn't always say
    /// a port has gone when it lets the worker go: since the worker-keep
    /// port (ExtensionKeep), closed after 30 s idle, a worker let go kept
    /// its port here looking open, and a page's next message went into it
    /// and was never answered, the worker never woken.
    private func live(_ id: String) -> WKWebExtension.MessagePort? {
        guard let link = links[id], !link.isDisconnected else { return nil }
        let key = "_backgroundWebView"
        if let context = self.context(id), context.webExtension.hasBackgroundContent,
           context.responds(to: NSSelectorFromString(key)), context.value(forKey: key) == nil {
            lost(id)
            return nil
        }
        return link
    }

    /// A worker's shim opened its port (Extensions' connectUsing), its
    /// sign-in's (`signIn`).
    func attach(_ port: WKWebExtension.MessagePort, extension id: String, signIn: UUID? = nil) {
        let id = Self.key(id, in: signIn)
        if let old = links[id], old !== port, !old.isDisconnected { old.disconnect() }
        links[id] = port
        port.messageHandler = { [weak self, weak port] message, _ in
            MainActor.assumeIsolated {
                guard let self, let port else { return }
                self.heard(message, from: id, on: port)
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            MainActor.assumeIsolated {
                guard let self, let port, self.links[id] === port else { return }
                self.lost(id)
            }
        }
        for (_, done) in waiting.removeValue(forKey: id) ?? [:] { done.resume(returning: port) }
    }

    private func heard(_ message: Any?, from id: String, on port: WKWebExtension.MessagePort) {
        guard let body = message as? [String: Any], let word = body["__yabExternal"] as? String else { return }
        switch word {
        case "reply":
            guard let n = body["n"] as? Int, let owed = owed[n], owed.id == id else { return }
            self.owed[n] = nil
            if body["none"] as? Bool == true { owed.reply(["none": true]) } else { owed.reply(["value": body["value"] ?? NSNull()]) }
        case "post", "disconnect":
            guard let key = body["port"] as? String, let open = pagePorts[key], open.id == id else { return }
            if word == "disconnect" {
                pagePorts[key] = nil
                tell(open, port: key, ["disconnect": true])
            } else {
                tell(open, port: key, ["message": body["message"] ?? NSNull()])
            }
        default:
            break
        }
    }

    /// The worker went: what it still owed is answered as Chromium does, and
    /// every page's port to it closes.
    private func lost(_ id: String) {
        links[id] = nil
        for (n, owed) in owed where owed.id == id {
            self.owed[n] = nil
            owed.reply(["error": "The message port closed before a response was received."])
        }
        for (key, open) in pagePorts where open.id == id {
            pagePorts[key] = nil
            tell(open, port: key, ["disconnect": true])
        }
    }

    /// Said to the page's side of a port, in the frame that opened it.
    private func tell(_ open: PagePort, port key: String, _ fields: [String: Any]) {
        guard let web = open.web else { return }
        var detail = fields
        detail["port"] = key
        guard let data = try? JSONSerialization.data(withJSONObject: detail, options: [.fragmentsAllowed]),
              let quoted = try? JSONSerialization.data(withJSONObject: [String(decoding: data, as: UTF8.self)], options: [])
        else { return }
        let argument = String(decoding: quoted, as: UTF8.self)
        let js = "window.dispatchEvent(new CustomEvent('\(ExternalRelay.answered)', { detail: \(argument)[0] }))"
        web.evaluateJavaScript(js, in: open.frame, in: Web.world, completionHandler: nil)
    }

    /// For the bench and tests: the extensions whose worker port is open.
    var linked: [String] { links.filter { !$0.value.isDisconnected }.map(\.key).sorted() }
}

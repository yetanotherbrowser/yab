import AppKit
import CryptoKit
import WebKit
import YabCoreClient

@MainActor
final class ChromiumDRMExtensionSession {
    static var all: [String: ChromiumDRMExtensionSession] = [:]
    let profile: String
    let privateMode: Bool
    let store: WKWebsiteDataStore
    private var core: YabCoreClient?
    private var control: String?
    private var opening: Task<(YabCoreClient, String), Error>?
    private var retired = false
    private var resourceHosts: [String: Task<String?, Error>] = [:]
    private var identityPages: [String: ChromiumExtensionPage] = [:]
    var entries: [[String: Any]] = []
    var pages: [UUID: WeakBridge] = [:]
    struct WeakBridge { weak var value: ChromiumDRMExtensions? }
    init(profile: String, privateMode: Bool, store: WKWebsiteDataStore) { self.profile = profile; self.privateMode = privateMode; self.store = store }
    static func of(_ tab: Tab) throws -> ChromiumDRMExtensionSession {
        try ChromiumPrivateProfiles.authorize(tab.chromiumProfile, store: tab.pageStore, privateMode: tab.shy || !tab.pageStore.isPersistent)
        if let session = all[tab.chromiumProfile] { return session }
        let made = ChromiumDRMExtensionSession(profile: tab.chromiumProfile, privateMode: tab.shy || !tab.pageStore.isPersistent, store: tab.pageStore)
        all[tab.chromiumProfile] = made
        return made
    }
    /// The session whose control tab reads and presses a tab's extension
    /// actions: its own profile's, or, for a private tab made as its
    /// space's off-the-record side, that space's (YabCore lets a space's
    /// control tab serve its private side's pages).
    static func actions(of tab: Tab) throws -> ChromiumDRMExtensionSession {
        guard ChromiumColumn.isPrivate(tab), let page = tab.builtPage as? ChromiumPage,
              let space = ChromiumPrivateProfiles.space(of: page.profile) else { return try of(tab) }
        try ChromiumPersistentProfiles.authorize(space.profile, store: space.store)
        if let session = all[space.profile] { return session }
        let made = ChromiumDRMExtensionSession(profile: space.profile, privateMode: false, store: space.store)
        all[space.profile] = made
        return made
    }
    static func retirePrivate(_ profile: String) {
        guard let value = all[profile], value.privateMode else { return }
        retire(profile, value)
    }
    static func retireStore(_ identifier: UUID) {
        for (profile, value) in all where value.store.identifier == identifier { retire(profile, value) }
    }
    private static func retire(_ profile: String, _ value: ChromiumDRMExtensionSession) {
        value.retired = true
        value.opening?.cancel(); value.opening = nil
        for lookup in value.resourceHosts.values { lookup.cancel() }
        value.clearIdentityPages()
        if let core = value.core, let id = value.control, ChromiumProcess.shared.isCurrent(core) {
            Task { try? await core.closeTab(id) }
        }
        value.control = nil; value.core = nil; value.pages = [:]
        all[profile] = nil
    }

    func endpoint(connectedTo expected: YabCoreClient? = nil) async throws -> (YabCoreClient, String) {
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        try ChromiumPrivateProfiles.authorize(profile, store: store, privateMode: privateMode)
        let current: YabCoreClient
        if let expected {
            guard ChromiumProcess.shared.isCurrent(expected) else { throw YabCoreError.disconnected }
            current = expected
        } else { current = try await ChromiumProcess.shared.connection() }
        if let core, core === current, let control { return (core, control) }
        if let opening { return try await opening.value }
        if core != nil {
            // Wire tab/virtual IDs restart from zero in a replacement helper.
            // Existing WebKit worlds must reload before they regain a bridge.
            entries = []
            clearIdentityPages()
            for page in pages.values { page.value?.helperReplaced() }
        }
        let task = Task { @MainActor in
            try await ChromiumPrivateProfiles.open(profile, privateMode: privateMode, core: current)
            guard !retired, !Task.isCancelled else { throw CancellationError() }
            let id = try await current.createTab(profile: profile, url: "chrome://extensions/")
            do {
                guard !retired, !Task.isCancelled else { throw CancellationError() }
                _ = try await current.request("tab.visible", params: ["tab": .string(id), "visible": .bool(false)])
                // Chrome WebUI can have a live main-world document while CEF's
                // HasDocument remains false. Use the core's document proof.
                _ = try await current.waitForDocument(tab: id, profile: profile, url: "chrome://extensions/")
                guard !retired, !Task.isCancelled else { throw CancellationError() }
                core = current; control = id
                return (current, id)
            } catch {
                try? await current.closeTab(id)
                throw error
            }
        }
        opening = task
        defer { opening = nil }
        return try await task.value
    }
    func request(_ method: String, _ params: [String: Any] = [:], connectedTo expected: YabCoreClient? = nil) async throws -> JSONValue {
        var params = try JSONDecoder().decode([String: JSONValue].self, from: Self.json(params))
        let (core, id) = try await endpoint(connectedTo: expected)
        params["tab"] = .string(id)
        return try await core.request(method, params: params)
    }
    /// Values a WebKit page handed over (a message's arguments, an answer) as
    /// JSON for the helper, or a Swift error. WebKit passes what JSON has no
    /// form for, a Date, NaN, Infinity, and JSONSerialization raises an
    /// Objective-C exception on those, which Swift's `try` does not catch. In
    /// 0.46.18 one unwound through the task running this and left the main
    /// actor's executor record pointing into a dead stack: the next isolation
    /// check anywhere (SwiftUI hit testing, WebKit, the cookie observer)
    /// crashed Yab, a minute after every launch.
    nonisolated static func json(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw YabCoreError.remote("Extension message is not JSON-serializable")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func catalog() async throws -> [[String: Any]] {
        let result = try await request("ext.bridge.catalog")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        entries = object?["extensions"] as? [[String: Any]] ?? []
        let enabled = Set(entries.compactMap { $0["id"] as? String })
        for id in identityPages.keys where !enabled.contains(id) { identityPages.removeValue(forKey: id)?.close() }
        return entries
    }
    private func clearIdentityPages() {
        for page in identityPages.values { page.close() }
        identityPages.removeAll()
    }
    func dynamicResourceHost(_ id: String, prepare: Bool = false) async throws -> String? {
        guard !retired, ChromiumExtensions.validID(id) else { return nil }
        if let lookup = resourceHosts[id] { return try await lookup.value }
        let lookup = Task<String?, Error> { @MainActor in
            let (core, _) = try await endpoint()
            if prepare, identityPages[id] == nil {
                let page = try await ChromiumExtensionStorage.open(id, profile: profile, store: store)
                guard !retired, self.core === core, ChromiumProcess.shared.isCurrent(core) else {
                    page.close()
                    return nil
                }
                identityPages[id] = page
            }
            guard let page = identityPages[id] else { return nil }
            // The native runtime of the browser's inert manifest document
            // identifies its extension without running the extension's code
            // or opening and closing a native tab for each resource read.
            let result = try? await page.run("""
                const runtime = globalThis.chrome?.runtime;
                if (location.pathname !== '/manifest.json' || document.contentType !== 'application/json'
                    || document.scripts.length !== 0 || !runtime) return null;
                return {id: runtime.id, host: runtime.dynamicId};
                """) as? [String: String]
            guard !retired, !Task.isCancelled, self.core === core, ChromiumProcess.shared.isCurrent(core),
                  result?["id"] == id, let host = result?["host"],
                  UUID(uuidString: host)?.uuidString.lowercased() == host else {
                if identityPages[id] === page { identityPages.removeValue(forKey: id)?.close() }
                return nil
            }
            return host
        }
        resourceHosts[id] = lookup
        defer { resourceHosts[id] = nil }
        return try await lookup.value
    }
    static func owns(control: String?, core: AnyObject?, eventTab: String, activeCore: AnyObject?) -> Bool {
        guard let core, let activeCore else { return false }
        return control == eventTab && core === activeCore
    }
    private func activeVirtualTab(_ extensionID: String) -> Any {
        guard let browser = BrowserWindows.shared.activeBrowser, browser.windowPurpose == .normal,
              let tab = browser.active, !tab.gone, tab.engineKind == .webKit else { return NSNull() }
        // Zero means the browser selected a WebKit tab, but this worker can't address it.
        guard tab.chromiumProfile == profile, let bridge = pages[tab.id]?.value else { return 0 }
        return bridge.activeNumber(for: extensionID) ?? 0
    }
    static func receive(_ event: YabCoreEvent, from activeCore: YabCoreClient?) -> Bool {
        guard event.name == "ext.bridge.call" else { return false }
        guard let activeCore, let id = event.tab,
              let session = all.values.first(where: { owns(control: $0.control, core: $0.core, eventTab: id, activeCore: activeCore) }) else { return true }
        Task { @MainActor in
            guard session.core === activeCore else { return }
            guard let data = try? JSONEncoder().encode(JSONValue.object(event.params)),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let call = payload["call"] as? [String: Any], let extensionID = payload["extension"] as? String else { return }
            let bridges = session.pages.values.compactMap(\.value)
            if call["op"] as? String == "storage.changed" {
                for bridge in bridges { await bridge.broadcast(extensionID, call) }
                return
            }
            if call["op"] as? String == "dnr.changed" {
                for bridge in bridges { try? await bridge.refreshRules(extensionID) }
                return
            }
            var value: Any = NSNull(), error: String?
            if call["op"] as? String == "tabs.active" {
                value = session.activeVirtualTab(extensionID)
            } else {
                do {
                    guard let number = call["tab"] as? Int,
                          let bridge = bridges.first(where: { $0.number == number }) else { throw YabCoreError.remote("Virtual tab is closed") }
                    value = try await bridge.reverse(extensionID, call)
                } catch let failure { error = String(describing: failure) }
            }
            var reply: [String: Any] = ["extension": extensionID, "session": payload["session"] ?? "", "call": call["id"] ?? "", "value": value]
            if let error { reply["error"] = error }
            // A page's answer JSON has no form for (a Date, NaN) fails the
            // call, as an unserializable result does in Chrome, rather than
            // raising out of this task (json(_:)).
            if !JSONSerialization.isValidJSONObject(reply) {
                reply["value"] = NSNull()
                reply["error"] = "Extension answer is not JSON-serializable"
            }
            // A reply belongs to the originating transport even if a helper
            // replacement happens while WebKit is executing the operation.
            guard let data = try? ChromiumDRMExtensionSession.json(reply),
                  var params = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }
            params["tab"] = .string(id)
            _ = try? await activeCore.request("ext.bridge.reply", params: params)
        }
        return true
    }
}

/// One isolated content world and handler per extension. WKFrameInfo authenticates
/// URL/origin and the native navigation epoch rejects replies from old documents.
@MainActor
final class ChromiumDRMExtensions {
    weak var tab: Tab?
    weak var web: WKWebView?
    let session: ChromiumDRMExtensionSession
    private(set) var epoch = UUID().uuidString
    private var scripts: [WKUserScript] = []
    private var handlers: [String: Handler] = [:]
    private(set) var entries: [String: [String: Any]] = [:]
    private var documents: [String: Document] = [:]
    private var resourceNavigations = ResourceNavigations()
    private var nextFrame = 0
    private var rules: [String: WKContentRuleList] = [:]
    private(set) var number: Int?
    /// The catalog these scripts were made from: the same one serves the next
    /// document as it is. Remade every navigation, megabytes of extension
    /// scripts crossed to every web process on each hop of a sign-in.
    private var installed: String?
    /// The most one answer or one change carries into a WebKit page.
    static let answerLimit = 8 * 1024 * 1024
    static let changeLimit = 256 * 1024
    private struct Document { let id: String; let nonce: String; let frame: Int; let info: WKFrameInfo; let url: URL; let epoch: String }
    func recordResourceNavigation(frame: UInt64, url: URL, source: URL?) {
        resourceNavigations.record(frame: frame, url: url, source: source)
    }
    func clearResourceNavigation(frame: UInt64, redirectingTo url: URL) -> Bool {
        resourceNavigations.clear(frame: frame, redirectingTo: url)
    }
    func takeResourceNavigation(frame: UInt64, url: URL) -> ResourceNavigations.Answer {
        resourceNavigations.take(frame: frame, url: url)
    }
    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        weak var owner: ChromiumDRMExtensions?
        let extensionID: String
        init(_ owner: ChromiumDRMExtensions, _ extensionID: String) { self.owner = owner; self.extensionID = extensionID }
        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            Task { @MainActor in
                do {
                    guard let owner else { throw YabCoreError.remote("WebKit tab closed") }
                    replyHandler(try await owner.message(extensionID, message), nil)
                } catch { replyHandler(nil, String(describing: error)) }
            }
        }
    }
    /// The bootstrap injected into an extension page the resource handler
    /// serves: the page's own scripts reach the bridge through the world
    /// Yab already keeps on that page, over the document they share.
    func pageBootstrap(for id: String) -> String? {
        guard let entry = entries[id], let manifest = entry["manifest"] as? [String: Any] else { return nil }
        let config = scriptConfig(id, entry: entry, manifest: manifest)
        return try? "(()=>{try{\(try ChromiumDRMExtensionScripts.bootstrap(config, page: true))}catch(error){}})();"
    }
    private func scriptConfig(_ id: String, entry: [String: Any], manifest: [String: Any]) -> [String: Any] {
        var config: [String: Any] = ["id": id, "epoch": epoch, "manifest": manifest, "messages": entry["messages"] ?? [:], "language": Locale.current.identifier.replacingOccurrences(of: "_", with: "-")]
        if let host = entry["resourceHost"] as? String {
            config["resourceHost"] = host
            config["dynamicResources"] = ChromiumDRMExtensionScripts.dynamicResources(manifest)
        }
        return config
    }
    init(tab: Tab, web: WKWebView) throws {
        self.tab = tab; self.web = web; session = try .of(tab)
        session.pages[tab.id] = .init(value: self)
    }
    func prepare(_ url: URL) async throws {
        guard let tab, let web, tab.chromiumProfile == session.profile else { throw CancellationError() }
        var catalog = try await session.catalog()
        if #available(macOS 15.4, *) {
            let folders = ExtensionOneList.webKitFolders(Extensions.of(store: tab.pageStore).installed)
            catalog.removeAll { ($0["id"] as? String).map(folders.contains) == true }
        }
        for index in catalog.indices {
            guard let id = catalog[index]["id"] as? String, let manifest = catalog[index]["manifest"] as? [String: Any],
                  !ChromiumDRMExtensionScripts.dynamicResources(manifest).isEmpty else { continue }
            do { catalog[index]["resourceHost"] = try await session.dynamicResourceHost(id, prepare: true) }
            catch { NSLog("DRM extension resource origin %@ unavailable: %@", id, String(describing: error)) }
        }
        guard !tab.gone, tab.chromiumProfile == session.profile else { throw CancellationError() }
        _ = try await session.request("ext.bridge.unregister", ["virtual": tab.id.uuidString])
        documents = [:]; nextFrame = 0
        resourceNavigations.removeAll()
        let controller = web.configuration.userContentController
        let revision = Self.revision(catalog)
        if revision == installed, scripts.allSatisfy({ mine in controller.userScripts.contains { $0 === mine } }) {
            // Rules come once per extension a site is granted to, then by dnr.changed.
            for (id, entry) in entries where rules[id] == nil
                && (entry["grants"] as? [String] ?? []).contains(where: { ChromiumDRMExtensionScripts.matches($0, url: url) }) {
                do { try await refreshRules(id) }
                catch { NSLog("DRM extension DNR %@ unavailable: %@", id, String(describing: error)) }
            }
            return
        }
        installed = nil
        epoch = UUID().uuidString
        // A previous navigation's grant or enabled-rule snapshot cannot keep
        // filtering after this catalog revokes it or conversion is refused.
        for rule in rules.values { controller.remove(rule) }
        rules = [:]
        Self.removeScripts(scripts, from: controller, removingMarked: true)
        scripts = []
        for id in handlers.keys { controller.removeScriptMessageHandler(forName: "yabChromiumExtension", contentWorld: world(id)) }
        handlers = [:]; entries = [:]
        for var entry in catalog {
            guard let id = entry["id"] as? String, let manifest = entry["manifest"] as? [String: Any],
                  var files = entry["files"] as? [String: String] else { continue }
            var paths: [String] = []
            for script in manifest["content_scripts"] as? [[String: Any]] ?? [] { paths += (script["js"] as? [String] ?? []) + (script["css"] as? [String] ?? []) }
            for resource in (manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]] ?? [] { if let path = resource["path"] as? String { paths.append(path) } }
            for path in Set(paths) {
                let response = try await session.request("ext.bridge.files", ["extension": id, "files": [path]])
                if let source = response[path].string { files[path] = source }
            }
            entry["files"] = files
            entries[id] = entry
            controller.removeScriptMessageHandler(forName: "yabChromiumExtension", contentWorld: world(id))
            let handler = Handler(self, id); handlers[id] = handler
            controller.addScriptMessageHandler(handler, contentWorld: world(id), name: "yabChromiumExtension")
            let grants = entry["grants"] as? [String] ?? []
            let config = scriptConfig(id, entry: entry, manifest: manifest)
            let bootstrap = "(()=>{\(try ChromiumDRMExtensionScripts.pageGuard(id: id, grants: grants))\(try ChromiumDRMExtensionScripts.bootstrap(config))})();"
            add(bootstrap, time: .atDocumentStart, main: false, world: world(id), controller: controller)
            for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
                let matches = script["matches"] as? [String] ?? [], excludes = script["exclude_matches"] as? [String] ?? []
                let guardSource = try ChromiumDRMExtensionScripts.guardSource(matches: matches, excludes: excludes, globs: script["include_globs"] as? [String] ?? [], excludeGlobs: script["exclude_globs"] as? [String] ?? [])
                let grantSource = try ChromiumDRMExtensionScripts.guardSource(matches: grants, excludes: [], globs: [], excludeGlobs: [])
                let target: WKContentWorld = script["world"] as? String == "MAIN" ? .page : world(id)
                let main = script["all_frames"] as? Bool != true
                let runAt = script["run_at"] as? String ?? "document_idle"
                let body = (script["js"] as? [String] ?? []).compactMap { files[$0] }.joined(separator: "\n;\n")
                let execute = runAt == "document_idle" ? "setTimeout(()=>{\n\(body)\n},0);" : "\n\(body)\n"
                if !body.isEmpty { add("(()=>{\(guardSource)\(grantSource)\(execute)})();", time: runAt == "document_start" ? .atDocumentStart : .atDocumentEnd, main: main, world: target, controller: controller) }
                let css = (script["css"] as? [String] ?? []).compactMap { files[$0] }.joined(separator: "\n")
                if !css.isEmpty {
                    let source = "(()=>{\(guardSource)\(grantSource)const put=()=>{if(!document.documentElement)return false;const s=document.createElement('style');s.textContent=\(try ChromiumDRMExtensionScripts.json(css));document.documentElement.append(s);return true};if(!put()){const o=new MutationObserver(()=>{if(put())o.disconnect()});o.observe(document,{childList:true,subtree:true})}})();"
                    add(source, time: .atDocumentStart, main: main, world: world(id), controller: controller)
                }
            }
            // Rule compilation is permission-scoped and refuses unsupported DNR.
            if grants.contains(where: { ChromiumDRMExtensionScripts.matches($0, url: url) }) {
                do { try await refreshRules(id) }
                catch { NSLog("DRM extension DNR %@ unavailable: %@", id, String(describing: error)) }
            }
        }
        for (id, rule) in rules where entries[id] == nil { controller.remove(rule); rules[id] = nil }
        installed = revision
    }
    /// Retain an application-script snapshot across a clear. The release line
    /// also uses this helper to verify WebKit's sticky native registrations.
    static func restore(_ retained: [WKUserScript], on controller: WKUserContentController) {
        let snapshot = retained.map { $0 }
        controller.removeAllUserScripts()
        var kept = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in snapshot where kept.insert(ObjectIdentifier(script)).inserted {
            controller.addUserScript(script)
        }
    }

    /// Clear only this bridge's application scripts. WebKit's extension scripts
    /// survive removeAllUserScripts; re-adding that retained list doubles them
    /// on each catalog rebuild (and detach), eventually overflowing Mach IPC.
    /// Native sources are never read: only application scripts removed by the
    /// clear need the legacy marker check during a catalog rebuild.
    static func removeScripts(_ scripts: [WKUserScript], from controller: WKUserContentController, removingMarked: Bool = false) {
        let owned = Set(scripts.map(ObjectIdentifier.init))
        let retained = controller.userScripts.filter { !owned.contains(ObjectIdentifier($0)) }.map { $0 }
        controller.removeAllUserScripts()
        var surviving = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in retained where surviving.insert(ObjectIdentifier(script)).inserted {
            if removingMarked && script.source.hasPrefix("/*yab-chromium-extension*/") { continue }
            controller.addUserScript(script)
        }
    }

    private static func revision(_ catalog: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])) ?? Data(UUID().uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func add(_ source: String, time: WKUserScriptInjectionTime, main: Bool, world: WKContentWorld, controller: WKUserContentController) {
        let script = WKUserScript(source: "/*yab-chromium-extension*/" + source, injectionTime: time, forMainFrameOnly: main, in: world)
        scripts.append(script); controller.addUserScript(script)
    }
    private func world(_ id: String) -> WKContentWorld { .world(name: "yab-chromium-extension-" + id) }
    private func allowed(_ id: String, _ url: URL) -> Bool {
        // An extension's own pages are its own trust domain, as in Chrome;
        // every other address needs a site grant.
        url.scheme == "chrome-extension" && url.host == id
            || (entries[id]?["grants"] as? [String] ?? []).contains { ChromiumDRMExtensionScripts.matches($0, url: url) }
    }
    func activeNumber(for id: String) -> Int? {
        guard let url = web?.url, entries[id] != nil, allowed(id, url),
              documents.contains(where: { key, document in
                  key.hasPrefix(id + ":") && document.frame == 0 && document.epoch == epoch
              }) else { return nil }
        return number
    }
    /// An extension's own page registers under its real chrome-extension
    /// URL, the way Chrome reports sender.url. Cores from before the registry
    /// took those URLs reject them, and the page embedding the frame stands
    /// in for the sender there.
    private func register(_ id: String, _ url: URL, document: Document, frame: Int, topURL: URL) async throws -> JSONValue {
        func params(_ sender: URL) -> [String: Any] {
            ["virtual": tab?.id.uuidString ?? "", "document": document.id, "frame": frame,
             "url": sender.absoluteString, "topURL": topURL.absoluteString, "extension": id]
        }
        do { return try await session.request("ext.bridge.register", params(url)) }
        catch YabCoreError.remote("Invalid virtual frame") where url.scheme == "chrome-extension" {
            return try await session.request("ext.bridge.register", params(topURL))
        }
    }
    /// A message's claimed address has to be the frame's own. WebKit tells
    /// the frame either through its request or its security origin; a page
    /// can name an extension's page, but it cannot make WebKit say its frame
    /// is one.
    private func identityHolds(_ id: String, _ url: URL, _ message: WKScriptMessage) -> Bool {
        let frame = message.frameInfo, origin = frame.securityOrigin
        if url.scheme == "chrome-extension" {
            guard #available(macOS 15.4, *), let requestURL = frame.request.url,
                  requestURL.scheme == "chrome-extension", requestURL.host == id, requestURL.port == nil,
                  let manifest = entries[id]?["manifest"] as? [String: Any],
                  !ChromiumDRMResources.sandboxed(String(requestURL.path.dropFirst()), manifest: manifest)
            else { return false }
            return !frame.isMainFrame && url.host == id && origin.protocol == "chrome-extension"
                && origin.host == id && origin.port == 0
        }
        guard frame.request.url != nil else { return false }
        return url.scheme == origin.protocol && url.host == origin.host
            && (url.port ?? (url.scheme == "https" ? 443 : 80)) == (origin.port == 0 ? (url.scheme == "https" ? 443 : 80) : origin.port)
    }
    private func message(_ id: String, _ message: WKScriptMessage) async throws -> Any {
        guard let tab, !tab.gone, tab.chromiumProfile == session.profile, message.webView === web,
              let body = message.body as? [String: Any], body["epoch"] as? String == epoch,
              let nonce = body["nonce"] as? String, let requestURL = message.frameInfo.request.url,
              let url = (body["url"] as? String).flatMap(URL.init(string:)) ?? Optional(requestURL), allowed(id, url),
              identityHolds(id, url, message)
        else { throw YabCoreError.remote("Extension document permission or identity expired") }
        let key = id + ":" + nonce
        if body["op"] as? String == "hello" {
            // WebKit says nothing when a frame goes, so a page open all day
            // with frames coming and going passed a fixed 2048 and its new
            // frames lost their extensions. The oldest subframe makes way, as
            // the helper does for the same tab (ext_bridge.inc).
            if documents.count >= 2048,
               let oldest = documents.filter({ $0.value.frame > 0 }).min(by: { $0.value.frame < $1.value.frame })?.key {
                documents[oldest] = nil
            }
            let frame: Int
            if message.frameInfo.isMainFrame { frame = 0 } else { nextFrame += 1; frame = nextFrame }
            let document = Document(id: message.frameInfo.isMainFrame ? epoch : UUID().uuidString, nonce: nonce, frame: frame, info: message.frameInfo, url: url, epoch: epoch)
            let result = try await register(id, url, document: document, frame: frame,
                topURL: message.frameInfo.isMainFrame ? url : web?.url ?? url)
            guard body["epoch"] as? String == epoch else { throw CancellationError() }
            number = result["tabId"].number.map(Int.init); documents[key] = document
            return true
        }
        guard var document = documents[key], document.epoch == epoch else { throw YabCoreError.remote("Stale extension frame") }
        // pushState/hash changes retain the isolated-world nonce and document ID.
        // URL text from that world may update only within WKFrameInfo's native origin.
        if document.url != url {
            document = Document(id: document.id, nonce: nonce, frame: document.frame, info: message.frameInfo, url: url, epoch: epoch)
            _ = try await register(id, url, document: document, frame: document.frame,
                topURL: message.frameInfo.isMainFrame ? url : web?.url ?? url)
            guard document.epoch == epoch else { throw CancellationError() }
            documents[key] = document
        }
        let op = body["op"] as? String ?? ""
        guard op.hasPrefix("runtime.") || op.hasPrefix("storage.") || op.hasPrefix("i18n.") || op.hasPrefix("port.") else { throw YabCoreError.remote("Unsupported extension API") }
        let result = try await session.request("ext.bridge.invoke", ["virtual": tab.id.uuidString, "document": document.id, "frame": document.frame, "extension": id, "op": op, "args": body["args"] ?? []])
        guard document.epoch == epoch else { throw CancellationError() }
        let encoded = try JSONEncoder().encode(result)
        // A whole storage.get(null) of a password manager goes into the page in one IPC message.
        guard encoded.count <= Self.answerLimit else { throw YabCoreError.remote("Extension answer too large for a WebKit page") }
        return try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed)
    }
    func reverse(_ id: String, _ call: [String: Any]) async throws -> Any {
        guard let web, let tab, !tab.gone, tab.chromiumProfile == session.profile,
              let op = call["op"] as? String, let args = call["args"] as? [String: Any] else { throw CancellationError() }
        let target = args["target"] as? [String: Any] ?? args["options"] as? [String: Any] ?? [:]
        let frameIDs = target["frameIds"] as? [Int] ?? (target["frameId"].map { [$0 as? Int ?? 0] })
        let documentIDs = target["documentIds"] as? [String] ?? (target["documentId"].map { [$0 as? String ?? ""] })
        var targets = documents.filter { key, doc in key.hasPrefix(id + ":") && doc.epoch == epoch && allowed(id, doc.url) && (frameIDs == nil || frameIDs!.contains(doc.frame)) && (documentIDs == nil || documentIDs!.contains(doc.id)) }
        if op.hasPrefix("scripting."), target["allFrames"] as? Bool != true, frameIDs == nil, documentIDs == nil { targets = targets.filter { $0.value.frame == 0 } }
        guard !targets.isEmpty else { throw YabCoreError.remote("No permitted WebKit target frame") }
        var fileSources: [String: String] = [:]
        if op.hasPrefix("scripting."), let files = args["files"] as? [String] {
            let response = try await session.request("ext.bridge.files", ["extension": id, "files": files])
            fileSources = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: String] ?? [:]
        }
        var results: [[String: Any]] = []
        for (_, doc) in targets.sorted(by: { $0.value.frame < $1.value.frame }) {
            let value: Any
            let guardValue: [String: Any] = ["url": doc.url.absoluteString, "epoch": doc.epoch, "nonce": doc.nonce]
            let pageWorld = op == "scripting.executeScript" && args["world"] as? String == "MAIN"
            let guardBody = "if(location.href!==__yabDRMGuard.url)throw Error('Extension frame navigated');" + (pageWorld ? "" : "if(!globalThis.__yabWK||__yabWK.epoch!==__yabDRMGuard.epoch||__yabWK.nonce!==__yabDRMGuard.nonce)throw Error('Extension document expired');")
            if op == "scripting.executeScript" {
                let source: String
                if let function = args["function"] as? String { source = "return await (\(function))(...args)" }
                else if let files = args["files"] as? [String], files.allSatisfy({ fileSources[$0] != nil }) { source = files.compactMap { fileSources[$0] }.joined(separator: "\n;\n") }
                else { throw YabCoreError.remote("Scripting file is not in this extension catalog") }
                value = try await javascript(guardBody + source, arguments: ["args": args["args"] ?? [], "__yabDRMGuard": guardValue], in: doc.info, in: args["world"] as? String == "MAIN" ? .page : world(id))
            } else if op == "scripting.insertCSS" || op == "scripting.removeCSS" {
                let css: String
                if let inline = args["css"] as? String { css = inline }
                else if let files = args["files"] as? [String], files.allSatisfy({ fileSources[$0] != nil }) { css = files.compactMap { fileSources[$0] }.joined(separator: "\n") }
                else { throw YabCoreError.remote("CSS file is not in this extension catalog") }
                value = try await javascript(guardBody + "const key=css;globalThis.__yabCSS??=new Map();if(remove){globalThis.__yabCSS.get(key)?.remove();globalThis.__yabCSS.delete(key)}else{const s=document.createElement('style');s.textContent=css;document.documentElement.append(s);globalThis.__yabCSS.set(key,s)}return null", arguments: ["css": css, "remove": op == "scripting.removeCSS", "__yabDRMGuard": guardValue], in: doc.info, in: world(id))
            } else {
                value = try await javascript(guardBody + "return await globalThis.__yabWK.receive(op,args)", arguments: ["op": op, "args": args, "__yabDRMGuard": guardValue], in: doc.info, in: world(id))
            }
            guard doc.epoch == epoch else { throw CancellationError() }
            if !op.hasPrefix("scripting.") { return value }
            results.append(["frameId": doc.frame, "documentId": doc.id, "result": value])
        }
        if op == "scripting.executeScript" { return results }
        return NSNull()
    }
    func broadcast(_ id: String, _ call: [String: Any]) async {
        guard web != nil else { return }
        var call = call
        // Every frame of every tab gets this: a large change says which keys
        // changed, and the listener reads what it needs.
        if let size = try? JSONSerialization.data(withJSONObject: call).count, size > Self.changeLimit,
           let changes = call["changes"] as? [String: Any] {
            call["changes"] = changes.mapValues { _ in [String: Any]() }
        }
        for (key, doc) in documents where key.hasPrefix(id + ":") && doc.epoch == epoch && allowed(id, doc.url) {
            _ = try? await javascript("return await globalThis.__yabWK.receive('storage.changed',args)", arguments: ["args": call], in: doc.info, in: world(id))
        }
    }
    private func javascript(_ body: String, arguments: [String: Any], in frame: WKFrameInfo?, in world: WKContentWorld) async throws -> Any {
        guard let web else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }
    func refreshRules(_ id: String) async throws {
        guard let web, let entry = entries[id], let manifest = entry["manifest"] as? [String: Any], manifest["declarative_net_request"] != nil else { return }
        let snapshot = try await session.request("ext.bridge.invoke", ["extension": id, "op": "dnr.snapshot", "args": []])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
        let converted = try ChromiumDRMExtensionRules.rules(entry: entry, snapshot: object)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "chromium-drm-" + session.profile + "-" + id, encodedContentRuleList: ChromiumDRMExtensionScripts.json(converted))
        if let old = rules[id] { web.configuration.userContentController.remove(old) }
        if let list { rules[id] = list; web.configuration.userContentController.add(list) }
    }
    func helperReplaced() {
        // The scripts in place carry the old epoch: the next document makes them again.
        installed = nil
        epoch = UUID().uuidString
        documents = [:]
        resourceNavigations.removeAll()
        number = nil
    }
    func detach() {
        installed = nil
        epoch = UUID().uuidString; documents = [:]
        resourceNavigations.removeAll()
        if let tab {
            session.pages[tab.id] = nil
            let identity = tab.id.uuidString
            if number != nil { Task { @MainActor [session] in _ = try? await session.request("ext.bridge.unregister", ["virtual": identity, "close": true]) } }
        }
        guard let web else { return }
        let controller = web.configuration.userContentController
        for id in handlers.keys { controller.removeScriptMessageHandler(forName: "yabChromiumExtension", contentWorld: world(id)) }
        Self.removeScripts(scripts, from: controller)
        for rule in rules.values { controller.remove(rule) }
        handlers = [:]; rules = [:]; scripts = []
    }
    func scriptStateForTesting() throws -> [String: Any] {
        guard Store.testing, let web else { throw CancellationError() }
        let all = web.configuration.userContentController.userScripts.map { ObjectIdentifier($0) }
        return ["scripts": all.count, "duplicateIdentities": all.count - Set(all).count,
                "prepared": installed != nil, "extensions": entries.count, "bridgeScripts": scripts.count]
    }
    func installForTesting(path: String) async throws -> Any {
        guard Store.testing else { throw CancellationError() }
        let (core, control) = try await session.endpoint()
        _ = try await core.request("extension.load", params: ["tab": .string(control), "path": .string(path)])
        return try await session.catalog().map { ["id": $0["id"] ?? "", "grants": $0["grants"] ?? []] }
    }
    func inspectForTesting(_ id: String, frame: Int = 0, body: String) async throws -> Any {
        guard Store.testing, let web else { throw CancellationError() }
        let target = documents.first { $0.key.hasPrefix(id + ":") && $0.value.frame == frame }?.value.info
        if frame != 0 && target == nil { return NSNull() }
        return try await javascript(body, arguments: [:], in: target, in: world(id))
    }
}

/// What a scheme task's frame last asked to load. WebKit drops the fragment
/// from the task's URL but keeps it in the navigation action, and a frame
/// already showing an extension page must not become its own asker, so a
/// record that no longer matches is an answer, not a miss. The map is bounded
/// per tab; the oldest record goes first, never the whole map at once.
struct ResourceNavigations {
    enum Answer: Equatable { case source(URL), stale, none }
    private var records: [UInt64: (url: URL, source: URL?)] = [:]
    private var order: [UInt64] = []
    static func fragmentless(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }
    mutating func removeAll() { records.removeAll(); order.removeAll() }
    mutating func record(frame: UInt64, url: URL, source: URL?) {
        if records[frame] == nil { order.append(frame) }
        records[frame] = (Self.fragmentless(url), source)
        while records.count > 128, let oldest = order.first {
            order.removeFirst()
            records[oldest] = nil
        }
    }
    mutating func clear(frame: UInt64, redirectingTo url: URL) -> Bool {
        guard let pending = records.removeValue(forKey: frame) else { return false }
        order.removeAll { $0 == frame }
        return pending.source == nil && pending.url == Self.fragmentless(url)
    }
    mutating func take(frame: UInt64, url: URL) -> Answer {
        guard let pending = records.removeValue(forKey: frame) else { return .none }
        order.removeAll { $0 == frame }
        guard let source = pending.source, pending.url == Self.fragmentless(url) else { return .stale }
        return .source(source)
    }
}

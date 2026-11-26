import Foundation
import WebKit
import YabCoreClient

/// A Chromium extension's pages, served into a WebKit tab's frames. The DRM
/// bridge replays an extension's content scripts on a WebKit page, and their
/// overlays (Bitwarden's inline menu, 1Password's) are iframes and fetches
/// pointing at chrome-extension:// addresses, a scheme WebKit serves nothing
/// for: the frames mounted empty and the menu never rendered. The bytes come
/// from the same native read the content scripts use (ext.bridge.files: the
/// profile's catalog, an extension enabled there, a file under its own root,
/// size capped; binary files arrive base64-wrapped), and only what the
/// extension declared web-accessible reaches the frame asking for it, and
/// only from the origins it listed. An extension's own pages can chain
/// freely; a page can never take a frame or a file it was not offered.
@available(macOS 15.4, *)
@MainActor
final class ChromiumDRMResources: NSObject, WKURLSchemeHandler {
    static let shared = ChromiumDRMResources()
    static let bootstrapPath = "__yab/page-bootstrap.js"
    private var stopped: Set<ObjectIdentifier> = []

    nonisolated func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        Task { @MainActor in await serve(webView, task) }
    }
    nonisolated func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        Task { @MainActor in stopped.insert(ObjectIdentifier(task)) }
    }
    private func live(_ task: WKURLSchemeTask) -> Bool { !stopped.contains(ObjectIdentifier(task)) }

    private func serve(_ webView: WKWebView, _ task: WKURLSchemeTask) async {
        // A stopped or finished request leaves nothing behind: the set only
        // holds requests still being answered.
        defer { stopped.remove(ObjectIdentifier(task)) }
        guard let url = task.request.url, url.scheme?.lowercased() == "chrome-extension", let id = url.host, !id.isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.count > 1, !url.path.contains(".."),
              let tab = Extensions.shared.tab(showing: webView), let bridge = tab.chromiumDRMExtensions,
              let owner = Self.owner(for: id, entries: bridge.entries),
              let manifest = bridge.entries[owner]?["manifest"] as? [String: Any],
              let frame = Self.frame(task) else { return fail(task) }
        let path = String(url.path.dropFirst())
        let frameID = Self.frameID(frame)
        // A navigation the delegate recorded answers for itself; a record
        // that no longer matches fails closed rather than letting the frame's
        // current extension page answer for a load it never asked for.
        let navigation = frameID.map { bridge.takeResourceNavigation(frame: $0, url: url) } ?? .none
        let asker: URL?
        var navigated = false
        switch navigation {
        case .source(let source): asker = source; navigated = true
        case .stale: return fail(task)
        case .none:
            asker = Self.committedURL(frame)
            if asker?.scheme == "chrome-extension", Self.mime(path).hasPrefix("text/html") {
                guard asker?.host == owner, id == owner, task.request.httpMethod == "GET",
                      task.request.value(forHTTPHeaderField: ChromiumDRMExtensionScripts.templateFetchHeader) == "1"
                else { return fail(task) }
            }
        }
        let dynamic = id != owner
        if navigated, path == Self.bootstrapPath { return fail(task) }
        let sandboxAsset = !navigated && !dynamic && Self.sandboxAsset(path, owner: owner, frame: frame, manifest: manifest)
        guard sandboxAsset || (asker.map {
            $0 != url && Self.permits(path, dynamic: dynamic, owner: owner, asker: $0, manifest: manifest)
        } ?? false) else { return fail(task) }
        let session = bridge.session
        let epoch = bridge.epoch
        // A reload can retire a dynamic ID even when the manifest and extension ID stay the same.
        if dynamic, (try? await session.dynamicResourceHost(owner)) != id { return fail(task) }
        let bootstrap = path == Self.bootstrapPath ? bridge.pageBootstrap(for: owner) : nil
        let sourced: String
        if path == Self.bootstrapPath {
            guard let bootstrap else { return fail(task) }
            sourced = bootstrap
        } else {
            guard let reply = try? await session.request("ext.bridge.files", ["extension": owner, "files": [path]]),
                  let source = reply[path].string, bridge.epoch == epoch, live(task) else { return fail(task) }
            sourced = source
        }
        var servedURL = url
        if dynamic {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return fail(task) }
            components.host = owner
            guard let canonical = components.url else { return fail(task) }
            if navigated, let frameID {
                bridge.recordResourceNavigation(frame: frameID, url: canonical, source: nil)
            }
            guard Self.redirect(task, from: url, to: canonical) else { return fail(task) }
            servedURL = canonical
        }
        // Text arrives as it is; anything the native read could not decode
        // (an image, a font) arrives base64-wrapped.
        let body = Self.bytes(from: sourced) ?? Data(sourced.utf8)
        // An extension page's own scripts run in its frame's page world, where
        // the isolated-world API never exists. Serving the page installs the
        // API there directly, the way Chrome gives an extension page its own
        // runtime; the bridge then holds every message to WebKit's own word
        // for which frame sent it.
        var document = body
        let type = Self.mime(path)
        var headers = ["Content-Type": type, "Access-Control-Allow-Origin": "*"]
        // Keep fetched HTML out of the cache for future document navigations.
        if dynamic || sandboxAsset || (!navigated && type.hasPrefix("text/html")) {
            headers["Cache-Control"] = "no-store"
        }
        if sandboxAsset {
            // Fonts load in CORS mode from the sandbox's opaque origin.
            headers["Access-Control-Allow-Origin"] = type.hasPrefix("font/") ? "null" : nil
        }
        if path == Self.bootstrapPath { headers["Cache-Control"] = "no-store" }
        if let policy = Self.sandboxPolicy(path, owner: owner, manifest: manifest) {
            headers["Content-Security-Policy"] = policy
        } else if type.hasPrefix("text/html") {
            // Chrome applies the extension's own page policy to its pages, or
            // its default when the manifest names none. The bootstrap is a
            // same-origin script, so 'self' admits it without loosening the
            // page's other restrictions, and a page that never declares a
            // policy keeps the protections Chrome would give it.
            headers["Content-Security-Policy"] = Self.pagePolicy(manifest)
            if navigated, bridge.pageBootstrap(for: owner) != nil { document = Self.inject(into: body) ?? body }
        }
        guard let response = HTTPURLResponse(url: servedURL, statusCode: 200, httpVersion: nil, headerFields: headers),
              live(task) else { return fail(task) }
        task.didReceive(response)
        guard live(task) else { return }
        task.didReceive(document)
        if live(task) { task.didFinish() }
    }
    private func fail(_ task: WKURLSchemeTask) {
        guard live(task) else { return }
        task.didFailWithError(YabCoreError.remote("Extension resource is unavailable to this page"))
        stopped.insert(ObjectIdentifier(task))
    }
    static func owner(for host: String, entries: [String: [String: Any]]) -> String? {
        if entries[host] != nil { return host }
        let owners = entries.keys.filter { entries[$0]?["resourceHost"] as? String == host }
        return owners.count == 1 ? owners.first : nil
    }
    static func permits(_ path: String, dynamic: Bool, owner: String, asker: URL, manifest: [String: Any]) -> Bool {
        // A manifest wildcard cannot expose the generated bridge script.
        if path == bootstrapPath {
            return !dynamic && asker.scheme == "chrome-extension" && asker.host == owner && asker.port == nil
        }
        if asker.scheme == "chrome-extension" {
            return asker.host == owner && asker.port == nil
                && (!dynamic || ChromiumDRMExtensionScripts.dynamicResources(manifest).contains { pattern($0, covers: path) })
        }
        let groups = manifest["web_accessible_resources"] as? [[String: Any]] ?? []
        return groups.contains { group in
            (group["use_dynamic_url"] as? Bool == true) == dynamic
                && (group["matches"] as? [String] ?? []).contains { ChromiumDRMExtensionScripts.matches($0, url: asker) }
                && (group["resources"] as? [String] ?? []).contains {
                    pattern($0.hasPrefix("/") ? String($0.dropFirst()) : $0, covers: path)
                }
        }
    }
    static func sandboxed(_ path: String, manifest: [String: Any]) -> Bool {
        let pages = (manifest["sandbox"] as? [String: Any])?["pages"] as? [String] ?? []
        return pages.contains { pattern($0.hasPrefix("/") ? String($0.dropFirst()) : $0, covers: path) }
    }
    /// Chrome's policy for an extension's own pages: the manifest's
    /// extension_pages policy (a string in older manifests), or the default
    /// Chrome enforces when a manifest names none.
    static func pagePolicy(_ manifest: [String: Any]) -> String {
        let declared = manifest["content_security_policy"]
        if let object = declared as? [String: Any], let policy = object["extension_pages"] as? String, !policy.isEmpty { return policy }
        if let policy = declared as? String, !policy.isEmpty { return policy }
        return "script-src 'self'; object-src 'self'"
    }
    static func sandboxPolicy(_ path: String, owner: String, manifest: [String: Any]) -> String? {
        guard sandboxed(path, manifest: manifest) else { return nil }
        let policy = (manifest["content_security_policy"] as? [String: String])?["sandbox"] ?? "script-src 'self'; object-src 'none'"
        // WebKit matches 'self' against the sandbox's opaque origin. Chromium
        // uses the owning extension for resource policies, while keeping the
        // sandbox opaque for script and messaging.
        return "sandbox allow-scripts, " + policy.replacingOccurrences(
            of: #"(?<!\S)'self'(?=\s|;|$)"#, with: "chrome-extension://" + owner, options: .regularExpression)
    }
    private static func frame(_ task: WKURLSchemeTask) -> WKFrameInfo? {
        let selector = NSSelectorFromString("_frame")
        guard let object = task as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? WKFrameInfo
    }
    // Navigation policy supplies the native source for a new child frame.
    // The scheme task identifies its target, which may still be opaque.
    static func recordNavigation(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard let bridge = Extensions.shared.tab(showing: webView)?.chromiumDRMExtensions,
              let url = action.request.url, let target = action.targetFrame else { return true }
        let frame = frameID(target)
        let redirected = frame.map { bridge.clearResourceNavigation(frame: $0, redirectingTo: url) } ?? false
        guard url.scheme == "chrome-extension", let host = url.host,
              let owner = owner(for: host, entries: bridge.entries) else { return true }
        guard !target.isMainFrame else { return false }
        // The same scheme task sends the canonical redirect and the response.
        if redirected { return true }
        guard let frame, let sourceFrame = WindowGate.source(action),
              let source = committedURL(sourceFrame),
              let manifest = bridge.entries[owner]?["manifest"] as? [String: Any],
              url.path.count > 1 else { return false }
        let path = String(url.path.dropFirst())
        guard path != bootstrapPath, permits(path, dynamic: host != owner, owner: owner, asker: source, manifest: manifest)
        else { return false }
        bridge.recordResourceNavigation(frame: frame, url: url, source: source)
        return true
    }
    private static func frameID(_ frame: WKFrameInfo) -> UInt64? {
        let selector = NSSelectorFromString("_handle")
        guard frame.responds(to: selector),
              let handle = frame.perform(selector)?.takeUnretainedValue() as? NSObject,
              handle.responds(to: NSSelectorFromString("frameID")) else { return nil }
        return (handle.value(forKey: "frameID") as? NSNumber)?.uint64Value
    }
    private static func committedURL(_ frame: WKFrameInfo) -> URL? {
        guard let url = frame.request.url, let host = url.host, let scheme = url.scheme,
              ["http", "https", "chrome-extension"].contains(scheme),
              frame.securityOrigin.protocol == scheme, frame.securityOrigin.host == host else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : 0
        let port = frame.securityOrigin.port
        guard (url.port ?? defaultPort) == (port == 0 ? defaultPort : port) else { return nil }
        return url
    }
    private static func sandboxAsset(_ path: String, owner: String, frame: WKFrameInfo?, manifest: [String: Any]) -> Bool {
        // Only WebKit's committed sandbox document proves who requested a
        // subresource. There is no Referer from an opaque origin.
        guard let frame, !frame.isMainFrame, frame.securityOrigin.protocol.isEmpty,
              let url = frame.request.url, url.scheme == "chrome-extension", url.host == owner,
              url.port == nil, sandboxed(String(url.path.dropFirst()), manifest: manifest) else { return false }
        let type = mime(path)
        return type.hasPrefix("text/javascript") || type.hasPrefix("text/css")
            || type.hasPrefix("image/") || type.hasPrefix("font/")
    }
    // Sending a response with a different URL leaves WebKit's document at the
    // alias. Report the redirect so the extension keeps its canonical origin.
    private static func redirect(_ task: WKURLSchemeTask, from alias: URL, to canonical: URL) -> Bool {
        let selector = NSSelectorFromString("_didPerformRedirection:newRequest:")
        guard let object = task as? NSObject, object.responds(to: selector),
              let response = HTTPURLResponse(url: alias, statusCode: 307, httpVersion: nil,
                                             headerFields: ["Location": canonical.absoluteString, "Cache-Control": "no-store"]) else { return false }
        object.perform(selector, with: response, with: NSURLRequest(url: canonical))
        return true
    }
    /// A web-accessible entry's pattern: every `*` stands for any run of
    /// characters, including none.
    static func pattern(_ value: String, covers path: String) -> Bool {
        guard value.contains("*") else { return value == path }
        let expression = NSRegularExpression.escapedPattern(for: value).replacingOccurrences(of: "\\*", with: ".*")
        return path.range(of: "^" + expression + "$", options: .regularExpression) != nil
    }
    /// Text as it is; a native base64 wrap as bytes.
    static func bytes(from source: String) -> Data? {
        guard source.hasPrefix("{\"b64\":"), let data = source.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encoded = object["b64"] as? String else { return nil }
        return Data(base64Encoded: encoded)
    }
    /// The bootstrap goes where the page's own scripts first see it, without
    /// pushing the document out of standards mode: after the head, or, in a
    /// page without one, right after the doctype.
    static func inject(into body: Data) -> Data? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let script = "<script src=\"/" + bootstrapPath + "\"></script>"
        if let head = text.range(of: #"<head[^>]*>"#, options: .regularExpression) {
            var injected = String(text[..<head.upperBound]); injected += script; injected += String(text[head.upperBound...])
            return Data(injected.utf8)
        }
        if let doctype = text.range(of: #"<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            var injected = String(text[..<doctype.upperBound]); injected += script; injected += String(text[doctype.upperBound...])
            return Data(injected.utf8)
        }
        return Data((script + text).utf8)
    }
    private static func mime(_ path: String) -> String {
        let kind = (path as NSString).pathExtension.lowercased()
        let known = [
            "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
            "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon", "json": "application/json",
            "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf", "txt": "text/plain",
        ]
        let type = known[kind] ?? "application/octet-stream"
        return type.hasPrefix("text/") || type == "application/json" ? type + "; charset=utf-8" : type
    }
}

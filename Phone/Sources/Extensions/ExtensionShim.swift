import Foundation
import UIKit
import WebKit

/// The Chrome APIs WebKit doesn't have, filled in as Yab for Mac fills them
/// (Sources/Fast/ExtensionShims.swift, the same script,
/// Resources/PageScripts/extension-shims.js): put at the front of an
/// extension's background, content scripts and pages once its signature has
/// been checked; each call becomes a native message to "yab", answered here.
/// The iPhone answers what a phone can (offscreen documents, a page with a
/// DOM for a worker that has none); the rest says it isn't here, and the
/// script makes that an ordinary rejected promise rather than a dead worker.
@MainActor
enum ExtensionShim {
    nonisolated static let application = "yab"
    nonisolated static let file = "yab-shim.js"
    nonisolated static let content = "yab-content.js"
    nonisolated static let passkeys = "yab-passkeys.js"
    nonisolated static let marker = "/* yab: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* yab: end of shim */"

    nonisolated static let script: String = {
        guard let url = Bundle.main.url(forResource: "extension-shims", withExtension: "js"),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }()

    // MARK: - at install

    /// Adds the shim to a freshly unpacked package (only by adding).
    nonisolated static func prepare(_ folder: URL) throws {
        guard !script.isEmpty else { return }
        let files = FileManager.default
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw ExtensionPackage.Refused.unpack }
        let shim = shim(for: folder)
        try shim.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try contentPart(of: shim).write(to: folder.appendingPathComponent(content), atomically: true, encoding: .utf8)
        // The Mac's passkey patch, named by the shim for scripts it registers
        // in a page's own world; nothing to patch on an iPhone, but it must be there.
        try "".write(to: folder.appendingPathComponent(passkeys), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches the browser. What is
        // added is written down: the extension is still described by what it asked for.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added: [String] = []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        if let data = try? JSONSerialization.data(withJSONObject: added) { try? data.write(to: folder.appendingPathComponent(".yab-added")) }
        manifest["permissions"] = permissions

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, let path = inside(worker, of: folder),
               let source = try? String(contentsOf: path, encoding: .utf8), !source.hasPrefix(marker) {
                let module = background["type"] as? String == "module"
                let first = "import \"/\(file)\";\n"
                try (marker + "\n" + shim + "\n" + ender + "\n" + (module ? first : "") + source).write(to: path, atomically: true, encoding: .utf8)
            }
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String], !js.contains(content) {
                    js.insert(content, at: 0)
                    entry["js"] = js
                }
                return entry
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships: popup, options, background page.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8), !html.contains(file) else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        return path
    }

    /// The shim as far as a content script goes in it (the Mac's contentPart).
    nonisolated static func contentPart(of script: String) -> String {
        guard let end = script.range(of: "if (inContent) return;") else { return script }
        let whole = String(script[..<end.lowerBound]) + "})();\n"
        var kept: [Substring] = []
        var skipping: String?
        for line in script[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if let close = skipping {
                if line == close { skipping = nil }
                else if line.hasPrefix(close + " else") { return whole }
                continue
            }
            let bare = line.drop { $0 == " " }
            if bare.hasPrefix("if (worker") || bare.hasPrefix("if (!inContent"), bare.hasSuffix("{"), !bare.contains("}") {
                skipping = String(repeating: " ", count: line.count - bare.count) + "}"
                continue
            }
            kept.append(line)
        }
        return skipping == nil ? kept.joined(separator: "\n") + "})();\n" : whole
    }

    /// What an iPhone's WebKit lacks that a Mac's has, first: MediaSource,
    /// which iOS calls ManagedMediaSource. MetaMask's sandbox (LavaMoat's
    /// Snow) wraps the global and stopped its whole interface where there
    /// was none ("Prototype value can only be an object or null").
    nonisolated static let iPhonePrelude = """
    if (typeof globalThis.MediaSource === "undefined" && typeof EventTarget === "function") {
      globalThis.MediaSource = globalThis.ManagedMediaSource || class MediaSource extends EventTarget { static isTypeSupported() { return false; } };
    }

    """

    /// The shim with this extension's events and shipped scripts filled in.
    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        var scripts: [String] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file, url.lastPathComponent != content,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        func json(_ value: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: value.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return iPhonePrelude + script.replacingOccurrences(of: "__YAB_EVENTS__", with: json(Array(found)))
            .replacingOccurrences(of: "__YAB_SCRIPTS__", with: json(scripts))
            .replacingOccurrences(of: "__YAB_CHROME__", with: ExtensionPackage.chromeVersion)
            .replacingOccurrences(of: "__YAB_VERBOSE__", with: "false")
            .replacingOccurrences(of: "__YAB_KEEP__", with: "false")
            .replacingOccurrences(of: "__YAB_PORT_TRACE__", with: "false")
            .replacingOccurrences(of: "__YAB_PORT_SLOW__", with: "true")
            // The Mac's later switches (Sources/Fast/ExtensionShims.swift).
            // One left in is a bare name the worker can't find: its first
            // line threw and no extension's background started on an
            // iPhone (uBlock Origin Lite, AdGuard, Dark Reader; request 1034).
            .replacingOccurrences(of: "__YAB_IDLE__", with: "[]")
            .replacingOccurrences(of: "__YAB_AUDIO__", with: "[]")
            .replacingOccurrences(of: "__YAB_WARM__", with: "false")
            .replacingOccurrences(of: "__YAB_DCL_LATE__", with: "false")
            .replacingOccurrences(of: "__YAB_LOCKS__", with: ownLocks ? "true" : "false")
    }

    /// Yab's own navigator.locks in an extension's pages and worker where
    /// WebKit ends the process that asks for a Web Lock, before 26.7, as
    /// on the Mac (ExtensionShims.ownLocks, 1Password, feedback #140).
    nonisolated static let ownLocks: Bool = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return os.majorVersion == 26 && os.minorVersion < 7
    }()

    // MARK: - answering

    /// Offscreen documents, one per extension, as Chrome allows: kept alive
    /// in a window of their own, never seen.
    static var offscreen: [String: WKWebView] = [:]
    /// A popup an extension set itself (action.setPopup), by extension.
    static var popups: [String: String] = [:]

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    static func answer(_ message: Any, from context: WKWebExtensionContext) async -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else { return ["error": "Not a Yab message"] }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext) async throws -> Any? {
        let id = context.uniqueIdentifier
        ExtensionHost.shared.note("api \(api)")
        ExtensionHost.shared.log(id, "api " + api)
        switch api {
        case "offscreen.createDocument":
            guard offscreen[id] == nil else { throw Unsupported(what: "Only a single offscreen document may be created.") }
            guard let path = (args.first as? [String: Any])?["url"] as? String, let configuration = context.webViewConfiguration,
                  let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
                  url.scheme == context.baseURL.scheme, url.host == context.baseURL.host
            else { throw Unsupported(what: "The offscreen document must belong to this extension") }
            let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
            // Kept in the key window, out of sight, so WebKit keeps it running.
            page.alpha = 0.01
            page.isUserInteractionEnabled = false
            page.accessibilityElementsHidden = true
            Self.keeper()?.insertSubview(page, at: 0)
            page.load(URLRequest(url: url))
            offscreen[id] = page
            for _ in 0..<250 {
                if !page.isLoading, page.url == url,
                   (try? await page.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true { return nil }
                try await Task.sleep(for: .milliseconds(20))
            }
            page.removeFromSuperview()
            offscreen[id] = nil
            throw Unsupported(what: "The offscreen document could not load")
        case "offscreen.closeDocument":
            offscreen.removeValue(forKey: id)?.removeFromSuperview()
            return nil
        case "offscreen.hasDocument":
            return offscreen[id] != nil
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "runtime.getContexts":
            // Its worker and its offscreen document, as Chrome lists them.
            let filter = args.first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String], urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append(["contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                              "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                              "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "", "incognito": false])
            }
            if context.webExtension.hasBackgroundContent {
                let manifest = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = manifest["service_worker"] as? String ?? manifest["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appendingPathComponent($0) })
            }
            if let page = offscreen[id] { add("OFFSCREEN_DOCUMENT", page.url) }
            return found
        case "background.loadedBefore":
            return ExtensionHost.shared.loadedBefore(id)
        case "background.revive":
            return nil
        case "debug.error":
            ExtensionHost.shared.note("error: " + String((args.first as? String ?? "?").prefix(300)))
            ExtensionHost.shared.log(id, "error " + String((args.first as? String ?? "?").prefix(300)))
            return nil
        case "permissions.granted":
            return UserDefaults.standard.stringArray(forKey: "extensions.granted.\(id)") ?? []
        case "permissions.request":
            // As in Chrome: only what its manifest named, granted with the yes at install.
            let wanted = (args.first as? [String]) ?? []
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else { throw Unsupported(what: "Only permissions specified in the manifest may be requested.") }
            let had = UserDefaults.standard.stringArray(forKey: "extensions.granted.\(id)") ?? []
            UserDefaults.standard.set(Array(Set(had + wanted)).sorted(), forKey: "extensions.granted.\(id)")
            return true
        case "permissions.origins":
            return true
        case "permissions.remove":
            let gone = Set((args.first as? [String]) ?? [])
            let had = UserDefaults.standard.stringArray(forKey: "extensions.granted.\(id)") ?? []
            UserDefaults.standard.set(had.filter { !gone.contains($0) }, forKey: "extensions.granted.\(id)")
            return true
        case "tabs.describe":
            let visible = ExtensionHost.shared.visibleTabs()
            return ((args.first as? [Int]) ?? []).map { index -> Any in
                guard visible.indices.contains(index) else { return NSNull() }
                return ["url": visible[index].url, "title": visible[index].title]
            }
        case "action.popup":
            // A popup set for every tab or one: shown by the page menu's row when WebKit has none.
            let path = args.first as? String ?? ""
            popups[id] = path.isEmpty ? nil : path
            return nil
        case "fontSettings.getFontList":
            return UIFont.familyNames.sorted().map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "idle.queryState":
            return "active"
        case "idle.getAutoLockDelay":
            return 0
        case "notifications.getPermissionLevel":
            return "denied"
        case "notifications.create", "notifications.clear", "notifications.update":
            return api == "notifications.create" ? ((args.first as? String) ?? UUID().uuidString) : false
        case _ where api.hasPrefix("setting.get:"):
            // A browser setting (chrome.privacy…): an iPhone's aren't an extension's to change.
            return ["value": false, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("setting."):
            return nil
        case "sidePanel.setOptions", "sidePanel.setPanelBehavior":
            // No side panel on a phone: kept quiet, as a setting that does nothing here.
            return nil
        case "sidePanel.getOptions":
            return ["enabled": false]
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": false]
        default:
            ExtensionHost.shared.log(id, "missing " + api)
            throw Unsupported(what: "\(api) is not available on \(DeviceWord.name)")
        }
    }

    private static func keeper() -> UIView? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }
}

import AppKit
import WebKit

/// Last UI-process boundary, including ordinary WKWebViews (mail, tools,
/// extension popups) and QuietScript's private entry point. Checking just the
/// Chromium bridge misses those callers. Limits are deliberately well below
/// Mach's limits; shared-memory retry does NOT reduce attached port count.
/// Refuse rather than truncate executable code or silently corrupt a reply.
enum WebKitIPCBoundary {
    static let byteLimit = 8 * 1024 * 1024
    static let scriptLimit = 256
    static let nodeLimit = 32_768
    static let error = NSError(domain: "Yab.WebKitIPC", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "WebKit payload exceeds Yab's IPC safety limit"])
    private static var installed = false
    typealias Done = @convention(block) (AnyObject?, NSError?) -> Void

    /// A JavaScript function making a value plain data where it is one of
    /// the page's that WebKit would hand Yab whole: a DOMRect (an element's
    /// getBoundingClientRect()), DOMPoint, DOMQuad or DOMMatrix becomes its
    /// toJSON(), inside arrays and objects too. WebKit of macOS 15 made the
    /// DOMRect itself in Yab's own JavaScript context, which has no DOM,
    /// and crashed there (JSDOMRect::subspaceForImpl, crashes #822, #823,
    /// #1553). Elements and other values are left as they were.
    static let plainScript = """
    ((v) => { const seen = new Map(); const walk = (x) => {
      if (x === null || typeof x !== 'object') return x;
      if (seen.has(x)) return seen.get(x);
      if (Array.isArray(x)) { const out = []; seen.set(x, out); for (const i of x) out.push(walk(i)); return out; }
      const proto = Object.getPrototypeOf(x);
      if (proto === Object.prototype || proto === null) { const out = {}; seen.set(x, out); for (const k of Object.keys(x)) out[k] = walk(x[k]); return out; }
      if (typeof x.toJSON === 'function' && !(x instanceof Date)) { try { return walk(x.toJSON()); } catch (e) { return null; } }
      return x; }; return walk(v); })
    """

    /// Stay on the caller's thread. In particular, never bridge an unknown
    /// Swift value to Foundation merely to discover its type. WebKit owns
    /// validation of unsupported values; this is only a best-effort size guard.
    static func fits(_ values: [Any]) -> Bool {
        var bytes = byteLimit, nodes = nodeLimit
        func visit(_ value: Any, _ depth: Int) -> Bool {
            nodes -= 1
            guard nodes >= 0, depth < 32 else { return false }
            bytes -= 64
            guard bytes >= 0 else { return false }
            let kind = type(of: value)
            if kind == String.self {
                let count = (value as! String).utf16.count
                guard count <= bytes / 2 else { return false }
                bytes -= count * 2
            } else if kind == Data.self {
                let count = (value as! Data).count
                guard count <= bytes else { return false }
                bytes -= count
            } else if let container = value as? IPCValueContainer {
                return container.ipcVisit(remaining: nodes) { visit($0, depth + 1) }
            } else if kind is NSString.Type {
                guard Thread.isMainThread else { return true }
                let text = value as! NSString
                guard text.length <= bytes / 2 else { return false }
                bytes -= text.length * 2
            } else if kind is NSData.Type {
                guard Thread.isMainThread else { return true }
                let data = value as! NSData
                guard data.length <= bytes else { return false }
                bytes -= data.length
            } else if kind is NSDictionary.Type {
                guard Thread.isMainThread else { return true }
                let dictionary = value as! NSDictionary
                guard dictionary.count <= nodes / 2 else { return false }
                let snapshot = dictionary.copy() as! NSDictionary
                for (key, item) in snapshot {
                    guard visit(key, depth + 1), visit(item, depth + 1) else { return false }
                }
            } else if kind is NSArray.Type {
                guard Thread.isMainThread else { return true }
                let array = value as! NSArray
                guard array.count <= nodes else { return false }
                let snapshot = array.copy() as! NSArray
                for item in snapshot { if !visit(item, depth + 1) { return false } }
            } else if kind == URL.self {
                return visit((value as! URL).absoluteString, depth + 1)
            } else if kind is NSURL.Type {
                guard Thread.isMainThread else { return true }
                return visit((value as! NSURL).absoluteString ?? "", depth + 1)
            }
            return true
        }
        return values.allSatisfy { visit($0, 0) }
    }

    @discardableResult static func allow(_ values: [Any], _ operation: String) -> Bool {
        guard fits(values) else {
            NSLog("WebKit IPC refused %@: payload budget exceeded", operation)
            return false
        }
        return true
    }

    /// Native WKWebExtension content scripts bypass addUserScript. Validate
    /// their file-backed catalog before loading a context, including the
    /// registered catalog remembered for warm-up. Native user-script sources
    /// cross as TransferString/shared-memory attachments, not inline UTF-16
    /// in the catalog. Bound the metadata and attachment expansion here;
    /// applying the inline payload budget to source bytes rejects otherwise
    /// small catalogs such as BetterCampus before WebKit can load them.
    static func validateExtensions(at folders: [URL]) throws {
        try validateExtensions(folders.map { ($0, nil) })
    }

    /// The host access a loaded context has, which decides how many times
    /// WebKit copies each content script (`injectedScripts`).
    struct Grants {
        var patterns: [WKWebExtension.MatchPattern]
        var allHosts: Bool
        /// WebKit's file URL access, which adds a `file://` pass to all hosts.
        var fileAccess: Bool

        /// `fileAccess`: when nil, read from `context`.
        @MainActor init(_ context: WKWebExtensionContext, fileAccess: Bool? = nil) {
            patterns = Array(context.grantedPermissionMatchPatterns.keys)
            allHosts = context.hasAccessToAllHosts
            self.fileAccess = fileAccess ?? Grants.fileAccess(of: context)
        }

        init(patterns: [WKWebExtension.MatchPattern], allHosts: Bool, fileAccess: Bool = false) {
            self.patterns = patterns
            self.allHosts = allHosts
            self.fileAccess = fileAccess
        }

        /// WebKit has no public getter for it; a WebKit without the SPI has no `file://` pass.
        @MainActor static func fileAccess(of context: WKWebExtensionContext) -> Bool {
            let get = NSSelectorFromString("_hasAccessToFileURLs")
            guard context.responds(to: get) else { return false }
            typealias Get = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(context.method(for: get), to: Get.self)(context, get)
        }
    }

    /// How many user scripts and style sheets WebKit makes of `groups` under
    /// `grants`: each file once per granted pattern its group overlaps, or
    /// once for all hosts and once more for `file://` when file access is on
    /// (WebExtensionContext::addInjectedContent).
    /// Never less than each file once, which grants given later can reach.
    static func injectedScripts(_ groups: [[String: Any]], grants: Grants?) -> Int {
        let files = groups.map { (($0["js"] as? [String])?.count ?? 0) + (($0["css"] as? [String])?.count ?? 0) }
        let once = files.reduce(0, +)
        guard let grants else { return once }
        if grants.allHosts { return grants.fileAccess ? once * 2 : once }
        var total = 0
        for granted in grants.patterns {
            for (group, count) in zip(groups, files) where count > 0 {
                let matches = group["matches"] as? [String] ?? []
                let overlaps = matches.contains { string in
                    guard let include = try? WKWebExtension.MatchPattern(string: string) else { return true }
                    return include.matchesAllHosts || include.matches(granted, options: [.ignorePaths, .matchBidirectionally])
                }
                if overlaps { total += count }
            }
        }
        return max(total, once)
    }

    /// `validateExtensions(at:)` with each folder's grants, so the script
    /// budget counts what WebKit will inject rather than every file once.
    /// A folder's content script groups: its manifest's and those registered at run time.
    static func catalogGroups(at folder: URL) throws -> [[String: Any]] {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? byteLimit
        guard size < byteLimit / 2 else { throw error }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        guard allow([manifest], "extension manifest") else { throw error }
        var groups = manifest["content_scripts"] as? [[String: Any]] ?? []
        let registered = folder.appendingPathComponent("_yab/registered.json")
        if FileManager.default.fileExists(atPath: registered.path) {
            let size = try registered.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? byteLimit
            guard size < byteLimit / 2 else { throw error }
            let list = try JSONSerialization.jsonObject(with: Data(contentsOf: registered))
            guard allow([list], "registered extension catalog") else { throw error }
            groups += list as? [[String: Any]] ?? []
        }
        return groups
    }

    static func validateExtensions(_ catalogs: [(folder: URL, grants: Grants?)]) throws {
        var count = 0
        for (folder, grants) in catalogs {
            let groups = try catalogGroups(at: folder)
            let injected = injectedScripts(groups, grants: grants)
            guard injected <= scriptLimit - count else {
                NSLog("WebKit IPC refused extension catalog: pattern expansion exceeds script budget")
                throw error
            }
            count += injected
            for group in groups {
                for name in (group["js"] as? [String] ?? []) + (group["css"] as? [String] ?? []) {
                    let file = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    // Check that the resource exists without reading its code
                    // into the UI process. WebKit owns source serialization.
                    guard try file.checkResourceIsReachable() else { throw error }
                }
            }
        }
    }

    /// Must run before the first view or controller is constructed. Idempotent
    /// so native regression tests can install exactly the production boundary.
    static func install() {
        guard !installed else { return }
        installed = true
        swap(WKWebView.self, "evaluateJavaScript:completionHandler:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, Done?) -> Void = { web, script, done in
                guard allow([script], "evaluateJavaScript") else { done?(nil, error); return }
                call(web, sel, script, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, WKFrameInfo?, WKContentWorld, Done?) -> Void = { web, script, frame, world, done in
                guard allow([script], "evaluateJavaScript in world") else { done?(nil, error); return }
                call(web, sel, script, frame, world, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Done?) -> Void = { web, script, args, frame, world, done in
                guard allow([script, args ?? [:]], "callAsyncJavaScript") else { done?(nil, error); return }
                call(web, sel, script, args, frame, world, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, Done?) -> Void = {
                web, script, async, source, args, gesture, frame, world, done in
                guard allow([script, args ?? [:], source?.absoluteString ?? ""], "private JavaScript") else { done?(nil, error); return }
                call(web, sel, script, async, source, args, gesture, frame, world, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "loadHTMLString:baseURL:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, NSURL?) -> AnyObject?
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, NSURL?) -> AnyObject? = { web, html, base in
                guard allow([html, base?.absoluteString ?? ""], "loadHTMLString") else { return nil }
                return call(web, sel, html, base)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "loadData:MIMEType:characterEncodingName:baseURL:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSData?, NSString?, NSString?, NSURL?) -> AnyObject?
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSData?, NSString?, NSString?, NSURL?) -> AnyObject? = { web, data, mime, encoding, base in
                // WebKit can pass nil here from loadHTMLString,
                // despite the public API's nonnull annotations (crashes #1051/1052).
                guard allow([data ?? NSData(), mime ?? "", encoding ?? "", base?.absoluteString ?? ""], "loadData") else { return nil }
                return call(web, sel, data, mime, encoding, base)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "loadRequest:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, NSURLRequest) -> AnyObject?
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSURLRequest) -> AnyObject? = { web, request in
                guard allow([request.url?.absoluteString ?? "", request.httpBody ?? Data(), request.allHTTPHeaderFields ?? [:]], "loadRequest") else { return nil }
                return call(web, sel, request)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebView.self, "takeSnapshotWithConfiguration:completionHandler:") { old, sel in
            typealias ImageDone = @convention(block) (NSImage?, NSError?) -> Void
            typealias Call = @convention(c) (WKWebView, Selector, WKSnapshotConfiguration?, ImageDone) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (WKWebView, WKSnapshotConfiguration?, ImageDone) -> Void = { web, configuration, done in
                let rect = configuration?.rect ?? .null
                let size = rect.isNull ? web.bounds.size : rect.size
                let width = configuration?.snapshotWidth?.doubleValue ?? Double(size.width)
                let height = size.width > 0 ? width * Double(size.height / size.width) : 0
                let scale = Double(web.window?.backingScaleFactor ?? 2)
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width * scale <= 16_384, height * scale <= 16_384,
                      width * height * scale * scale <= 16_777_216 else {
                    NSLog("WebKit IPC refused snapshot: pixel budget exceeded")
                    done(nil, error); return
                }
                call(web, sel, configuration, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKWebExtension.MessagePort.self, "sendMessage:completionHandler:") { old, sel in
            typealias PortDone = @convention(block) (NSError?) -> Void
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, PortDone?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, AnyObject?, PortDone?) -> Void = { port, value, done in
                guard allow([value ?? NSNull()], "extension port message") else { done?(error); return }
                call(port, sel, value, done)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKUserContentController.self, "addUserScript:") { old, sel in
            typealias Call = @convention(c) (WKUserContentController, Selector, WKUserScript) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (WKUserContentController, WKUserScript) -> Void = { controller, script in
                let existing = controller.userScripts
                // Also stops every clear/re-add survivor loop, even a future
                // caller that forgets that extension scripts survive a clear.
                guard !existing.contains(where: { $0 === script }) else { return }
                guard existing.count < scriptLimit,
                      allow(existing.map { $0.source } + [script.source], "addUserScript aggregate") else {
                    NSLog("WebKit IPC refused addUserScript: script count/aggregate budget exceeded")
                    return
                }
                call(controller, sel, script)
            }
            return imp_implementationWithBlock(block)
        }
        swap(WKUserContentController.self, "addScriptMessageHandlerWithReply:contentWorld:name:") { old, sel in
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject, WKContentWorld, NSString) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, AnyObject, WKContentWorld, NSString) -> Void = { controller, handler, world, name in
                guard let handler = handler as? WKScriptMessageHandlerWithReply,
                      allow([name, world.name ?? ""], "reply handler") else { return }
                // WKUserContentController retains the proxy, which retains the
                // original handler exactly as the unwrapped registration did.
                call(controller, sel, Reply(handler), world, name)
            }
            return imp_implementationWithBlock(block)
        }
    }

    private final class Reply: NSObject, WKScriptMessageHandlerWithReply {
        let handler: WKScriptMessageHandlerWithReply
        init(_ handler: WKScriptMessageHandlerWithReply) { self.handler = handler }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            handler.userContentController(userContentController, didReceive: message) { value, failure in
                guard allow([value ?? NSNull(), failure ?? ""], "script message reply") else {
                    replyHandler(nil, error.localizedDescription); return
                }
                replyHandler(value, failure)
            }
        }
    }

    private static func swap(_ type: AnyClass, _ name: String, _ make: (IMP, Selector) -> IMP) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type, selector) else {
            NSLog("WebKit IPC boundary unavailable: %@", name)
            return
        }
        method_setImplementation(method, make(method_getImplementation(method), selector))
    }
}

/// Native generic containers must be walked without first bridging every
/// element/key to Objective-C (including opaque Swift keys and values).
private protocol IPCValueContainer {
    func ipcVisit(remaining: Int, _ visit: (Any) -> Bool) -> Bool
}
extension Array: IPCValueContainer {
    fileprivate func ipcVisit(remaining: Int, _ visit: (Any) -> Bool) -> Bool {
        guard count <= remaining else { return false }
        return allSatisfy { visit($0) }
    }
}
extension Dictionary: IPCValueContainer {
    fileprivate func ipcVisit(remaining: Int, _ visit: (Any) -> Bool) -> Bool {
        guard count <= remaining / 2 else { return false }
        return allSatisfy { visit($0.key) && visit($0.value) }
    }
}

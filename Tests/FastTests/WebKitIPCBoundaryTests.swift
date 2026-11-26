import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct WebKitIPCBoundaryTests {
    @Test func budgetIncludesUTF16ContainersKeysAndDepth() {
        #expect(WebKitIPCBoundary.fits(["return 42", ["value": [1, true, NSNull()]]]))
        #expect(!WebKitIPCBoundary.fits([String(repeating: "x", count: WebKitIPCBoundary.byteLimit / 2)]))
        #expect(!WebKitIPCBoundary.fits([Data(count: WebKitIPCBoundary.byteLimit)]))
        #expect(!WebKitIPCBoundary.fits([Array(repeating: NSNull(), count: WebKitIPCBoundary.nodeLimit)]))
        #expect(!WebKitIPCBoundary.fits([[String(repeating: "k", count: WebKitIPCBoundary.byteLimit / 2): 1]]))
        var deep: Any = "leaf"
        for _ in 0..<40 { deep = [deep] }
        #expect(!WebKitIPCBoundary.fits([deep]))
    }

    @Test func unknownSwiftValuesAndFoundationSnapshots() {
        struct Opaque: Hashable { let number: Int }
        let optional: NSString? = nil
        #expect(WebKitIPCBoundary.fits([optional as Any, Opaque(number: 1),
                                      [Opaque(number: 2): Opaque(number: 3)]]))
        let array = NSMutableArray(array: ["small", NSNull()])
        let dictionary = NSMutableDictionary(dictionary: ["array": array])
        #expect(WebKitIPCBoundary.fits([dictionary]))
        array.add(String(repeating: "x", count: WebKitIPCBoundary.byteLimit / 2))
        #expect(!WebKitIPCBoundary.fits([dictionary]))
        #expect(WebKitIPCBoundary.fits([URL(string: "https://example.test")!]))
    }

    @Test func htmlWarmupAcceptsWebKitsNullableLoadDataArguments() async throws {
        WebKitIPCBoundary.install()
        let web = WKWebView(frame: .zero)
        // The exact MailBodyView.warm path from reports #1051 and #1052:
        // WebKit internally invokes the swizzled loadData with nil arguments.
        web.loadHTMLString("<html><body>Warm</body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while web.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!web.isLoading)
        #expect((try await web.evaluateJavaScript("document.body.textContent") as? String) == "Warm")
    }

    @Test func oversizedPublicAndQuietEvaluationsReturnErrorsWithoutSending() async throws {
        WebKitIPCBoundary.install()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let huge = String(repeating: " ", count: WebKitIPCBoundary.byteLimit / 2)
        let plain: NSError? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(huge) { _, error in continuation.resume(returning: error as NSError?) }
        }
        #expect(plain?.domain == "Yab.WebKitIPC")
        let world: NSError? = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(huge, in: nil, in: .defaultClient) { result in
                if case .failure(let error) = result { continuation.resume(returning: error as NSError) }
                else { continuation.resume(returning: nil) }
            }
        }
        #expect(world?.domain == "Yab.WebKitIPC")
        let async: NSError? = await withCheckedContinuation { continuation in
            web.callAsyncJavaScript("return text.length", arguments: ["text": huge], in: nil, in: .page) { result in
                if case .failure(let error) = result { continuation.resume(returning: error as NSError) }
                else { continuation.resume(returning: nil) }
            }
        }
        #expect(async?.domain == "Yab.WebKitIPC")
        let quiet: NSError? = await withCheckedContinuation { continuation in
            web.callAsyncQuietly("return text.length", arguments: ["text": huge]) { result in
                if case .failure(let error) = result { continuation.resume(returning: error as NSError) }
                else { continuation.resume(returning: nil) }
            }
        }
        #expect(quiet?.domain == "Yab.WebKitIPC")
        #expect(web.loadHTMLString(huge, baseURL: nil) == nil)
        // A small page with no base URL goes through to loadData with a nil
        // base, as mail's warm-up does; 0.46.11 crashed here.
        #expect(web.loadHTMLString("<p>mail</p>", baseURL: nil) != nil)
        #expect(web.load(Data("<p>x</p>".utf8), mimeType: "text/html", characterEncodingName: "", baseURL: URL(string: "about:blank")!) != nil)
        #expect(web.load(Data(count: WebKitIPCBoundary.byteLimit), mimeType: "text/html", characterEncodingName: "utf-8", baseURL: URL(string: "https://example.test")!) == nil)
        #expect(web.load(URLRequest(url: URL(string: "https://example.test/" + huge.replacingOccurrences(of: " ", with: "x"))!)) == nil)
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
        let snapshot: NSError? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: shot) { _, error in continuation.resume(returning: error as NSError?) }
        }
        #expect(snapshot?.domain == "Yab.WebKitIPC")
        // Still usable after every refusal; these are real WebKit evaluations.
        let answer = try await web.evaluateJavaScript("6 * 7")
        #expect((answer as? NSNumber)?.intValue == 42)
        let quietAnswer: Int? = await withCheckedContinuation { continuation in
            web.callAsyncQuietly("return n + 1", arguments: ["n": 41]) { result in
                continuation.resume(returning: (try? result.get() as? NSNumber)?.intValue)
            }
        }
        #expect(quietAnswer == 42)
    }

    @Test func aggregateScriptsAreBoundedAndDuplicateObjectsAreNotSent() {
        WebKitIPCBoundary.install()
        let controller = WKUserContentController()
        let script = WKUserScript(source: "void 0", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        for _ in 0..<1000 { controller.addUserScript(script) }
        #expect(controller.userScripts.count == 1)
        for n in 0..<(WebKitIPCBoundary.scriptLimit + 1) {
            controller.addUserScript(WKUserScript(source: "void \(n)", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        #expect(controller.userScripts.count == WebKitIPCBoundary.scriptLimit)
        controller.removeAllUserScripts()
        let source = String(repeating: " ", count: 512 * 1024)
        for n in 0..<20 {
            controller.addUserScript(WKUserScript(source: source + ";void \(n)", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        #expect(controller.userScripts.count > 0)
        #expect(controller.userScripts.count < 8)
        #expect(WebKitIPCBoundary.fits(controller.userScripts.map { $0.source }))
    }

    @Test func nativeExtensionCatalogIsBoundedBeforeLoading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("content.js")
        try Data("void 0".utf8).write(to: file)
        func manifest(_ groups: [[String: Any]]) throws {
            let data = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "IPC", "version": "1", "content_scripts": groups])
            try data.write(to: folder.appendingPathComponent("manifest.json"))
        }
        let group: [String: Any] = ["matches": ["https://example.test/*"], "js": ["content.js"]]
        try manifest([group])
        try WebKitIPCBoundary.validateExtensions(at: [folder])
        try manifest(Array(repeating: group, count: 257))
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions(at: [folder]) }
        try manifest([group])
        try FileManager.default.removeItem(at: file)
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions(at: [folder]) }
        try Data("void 0".utf8).write(to: file)
        let oversizedMetadata = ["manifest_version": 3, "name": String(repeating: "x", count: WebKitIPCBoundary.byteLimit / 2),
                                 "version": "1", "content_scripts": [group]] as [String: Any]
        try JSONSerialization.data(withJSONObject: oversizedMetadata).write(to: folder.appendingPathComponent("manifest.json"))
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions(at: [folder]) }
    }

    @Test func scriptBudgetCountsWhatWebKitInjectsForTheGrants() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.js", "b.js", "c.css"] { try Data("void 0".utf8).write(to: folder.appendingPathComponent(name)) }
        func pattern(_ string: String) throws -> WKWebExtension.MatchPattern { try WKWebExtension.MatchPattern(string: string) }
        let hosts = (0..<300).map { "https://*.site\($0).test/*" }
        // Grammarly 14.1348.0's shape: hundreds of named sites, few files.
        let groups: [[String: Any]] = [
            ["matches": hosts, "js": ["a.js"]],
            ["matches": hosts, "js": ["b.js"], "css": ["c.css"]],
            ["matches": ["https://other.test/*"], "js": ["a.js"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Sites", "version": "1", "content_scripts": groups])
        try data.write(to: folder.appendingPathComponent("manifest.json"))

        // All hosts is one pass, and a file:// one more only with file access.
        let everywhere = WebKitIPCBoundary.Grants(patterns: [try pattern("https://*/*")], allHosts: true)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: everywhere) == 4)
        try WebKitIPCBoundary.validateExtensions([(folder, everywhere)])
        let withFiles = WebKitIPCBoundary.Grants(patterns: [try pattern("https://*/*")], allHosts: true, fileAccess: true)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: withFiles) == 8)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: nil) == 4)
        try WebKitIPCBoundary.validateExtensions(at: [folder])

        // Each granted site copies only the groups that name it: 2 × 3.
        let two = WebKitIPCBoundary.Grants(patterns: [try pattern("*://site7.test/*"), try pattern("https://site8.test/*")], allHosts: false)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: two) == 6)
        // Fewer than each file once still counts each file once: grants can come later.
        let other = WebKitIPCBoundary.Grants(patterns: [try pattern("https://other.test/*")], allHosts: false)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: other) == 4)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: .init(patterns: [], allHosts: false)) == 4)

        // Each site granted on its own: 300 × 3 copies, past the budget.
        let each = WebKitIPCBoundary.Grants(patterns: try hosts.map(pattern), allHosts: false)
        #expect(WebKitIPCBoundary.injectedScripts(groups, grants: each) == 900)
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions([(folder, each)]) }

        // The budget is shared by every loaded extension.
        let many = Array(repeating: (folder: folder, grants: Optional(withFiles)), count: WebKitIPCBoundary.scriptLimit / 8 + 1)
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions(many) }
    }

    @Test func allHostsBudgetDoublesOnlyWithFileAccess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("void 0".utf8).write(to: folder.appendingPathComponent("a.js"))
        func catalog(files: Int) throws {
            let group: [String: Any] = ["matches": ["<all_urls>"], "js": Array(repeating: "a.js", count: files)]
            let data = try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "All", "version": "1", "content_scripts": [group]])
            try data.write(to: folder.appendingPathComponent("manifest.json"))
        }
        let all = try WKWebExtension.MatchPattern(string: "<all_urls>")
        let off = WebKitIPCBoundary.Grants(patterns: [all], allHosts: true, fileAccess: false)
        let on = WebKitIPCBoundary.Grants(patterns: [all], allHosts: true, fileAccess: true)

        try catalog(files: 128)
        try WebKitIPCBoundary.validateExtensions([(folder, on)])
        try catalog(files: 129)
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions([(folder, on)]) }
        try WebKitIPCBoundary.validateExtensions([(folder, off)])
        try catalog(files: 256)
        try WebKitIPCBoundary.validateExtensions([(folder, off)])
        try catalog(files: 257)
        #expect(throws: NSError.self) { try WebKitIPCBoundary.validateExtensions([(folder, off)]) }
    }

    @MainActor @Test func fileAccessIsReadFromTheContext() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version": 3, "name": "Files", "version": "1"}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        #expect(!WebKitIPCBoundary.Grants(context).fileAccess)
        let set = NSSelectorFromString("_setHasAccessToFileURLs:")
        // The SPI is what the probe reads; without it there is nothing to turn on.
        guard context.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(context.method(for: set), to: Setter.self)(context, set, true)
        #expect(WebKitIPCBoundary.Grants(context).fileAccess)
    }

    @Test func nativeExtensionSourceBytesAreNotAnInlineCatalogPayload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A single attachment, like BetterCampus's all.js, can carry more
        // source than the inline message budget. The byte/count constants
        // and the generic evaluateJavaScript boundary remain unchanged.
        let source = Data(repeating: 32, count: WebKitIPCBoundary.byteLimit + 1)
        try source.write(to: folder.appendingPathComponent("content.js"))
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Native source", "version": "1",
            "content_scripts": [["matches": ["https://example.test/*"], "js": ["content.js"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try WebKitIPCBoundary.validateExtensions(at: [folder])
        #expect(!WebKitIPCBoundary.fits([String(repeating: "x", count: WebKitIPCBoundary.byteLimit)]))
    }

    private final class StickyController: WKUserContentController {
        var kept: [WKUserScript] = []
        var application: [WKUserScript] = []
        override var userScripts: [WKUserScript] { kept + application }
        override func removeAllUserScripts() { application = [] }
        override func addUserScript(_ script: WKUserScript) { application.append(script) }
    }

    @Test func catalogDetachAndPageArmingRetainStickyScriptsOnce() {
        let controller = StickyController()
        let script = WKUserScript(source: "/* native extension */", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.kept = [script]
        for _ in 0..<100 {
            ChromiumDRMExtensions.restore(controller.userScripts, on: controller)
            #expect(controller.userScripts.count == 1)
            PageScripts.forget(controller)
            PageScripts.fit(controller, [script])
            #expect(controller.userScripts.count == 1)
        }
    }

    @Test func realWebKitExtensionSurvivesRepeatedBridgeCatalogReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-ipc-extension-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"IPC regression","version":"1.0","content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("globalThis.ipcRegression = true;".utf8).write(to: folder.appendingPathComponent("content.js"))
        let extensionConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        extensionConfiguration.defaultWebsiteDataStore = .nonPersistent()
        let extensions = WKWebExtensionController(configuration: extensionConfiguration)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.hasAccessToPrivateData = true
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://example.test/*"))
        try extensions.load(context)
        defer { try? extensions.unload(context) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionConfiguration.defaultWebsiteDataStore
        configuration.webExtensionController = extensions
        let web = WKWebView(frame: .zero, configuration: configuration)
        let controller = web.configuration.userContentController
        for _ in 0..<100 {
            if !controller.userScripts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // The getter can bridge WebKit's live mutable NSArray. This must
        // remain the original extension inventory after app scripts change.
        let injected = controller.userScripts.map { $0 }
        try #require(!injected.isEmpty, "A real extension must have injected scripts")
        let app = WKUserScript(source: "/* app retained by the DRM bridge */", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(app)
        // Rebuild using the production path with real native survivors.
        ChromiumDRMExtensions.restore([app], on: controller)
        for _ in 0..<20 {
            ChromiumDRMExtensions.restore(controller.userScripts, on: controller)
            #expect(controller.userScripts.count == injected.count + 1)
            #expect(controller.userScripts.filter { $0 === app }.count == 1)
            PageScripts.forget(controller)
            PageScripts.fit(controller, controller.userScripts)
            #expect(controller.userScripts.count == injected.count + 1)
            #expect(controller.userScripts.filter { $0 === app }.count == 1)
            for script in injected { #expect(controller.userScripts.filter { $0 === script }.count == 1) }
        }
        ChromiumDRMExtensions.restore(injected, on: controller)
        #expect(controller.userScripts.count == injected.count)
        withExtendedLifetime(web) {}
    }

    private final class LargeReply: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            replyHandler(String(repeating: "x", count: WebKitIPCBoundary.byteLimit / 2), nil)
        }
    }

    @Test func oversizedReplyRejectsPromiseAndWebViewRemainsUsable() async throws {
        WebKitIPCBoundary.install()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(LargeReply(), contentWorld: .page, name: "large")
        let web = WKWebView(frame: .zero, configuration: configuration)
        let result = try await web.callAsyncJavaScript("try { await webkit.messageHandlers.large.postMessage(null); return false } catch(e) { return String(e).includes('IPC safety limit') }", arguments: [:], in: nil, contentWorld: .page)
        #expect((result as? NSNumber)?.boolValue == true)
        #expect((try await web.evaluateJavaScript("21 * 2") as? NSNumber)?.intValue == 42)
    }
}

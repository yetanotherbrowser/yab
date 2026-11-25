import AppKit
import Testing
import WebKit
@testable import Fast

/// A real extension's frame, put on a page by the extension's own content
/// script, the way a password manager opens its suggestions under a field.
@MainActor
@Suite(.serialized)
struct AgentSecretsExtensionFrameTests {
    private static let secret = "VAULT_TEXT_ONLY_THE_EXTENSION_SEES"

    private struct World {
        let folder: URL
        let extensions: WKWebExtensionController
        let context: WKWebExtensionContext
        let web: PageView
        let loaded: AgentKeysTests.Loaded

        func close() {
            try? extensions.unload(context)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func world(frameStyle: String = "") async throws -> World {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-extension-frame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"""
        {"manifest_version":3,"name":"Vault fixture","version":"1.0",
         "content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"],"run_at":"document_idle"}],
         "web_accessible_resources":[{"resources":["frame.html"],"matches":["https://example.test/*"]}]}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        // Opens the extension's window under the field, as a password
        // manager does when the field gets focus.
        let content = """
        const frame = document.createElement('iframe');
        frame.id = 'vault';
        frame.src = browser.runtime.getURL('frame.html');
        frame.style.cssText = '\(frameStyle)';
        document.body.append(frame);
        """
        try Data(content.utf8).write(to: folder.appendingPathComponent("content.js"))
        try Data("<p>\(secret)</p><input id=pick value=\(secret)>".utf8).write(to: folder.appendingPathComponent("frame.html"))

        let extensionConfiguration = WKWebExtensionController.Configuration.nonPersistent()
        extensionConfiguration.defaultWebsiteDataStore = .nonPersistent()
        let extensions = WKWebExtensionController(configuration: extensionConfiguration)
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        context.hasAccessToPrivateData = true // The fixture's website store is ephemeral.
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://example.test/*"))
        try extensions.load(context)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = extensionConfiguration.defaultWebsiteDataStore
        configuration.webExtensionController = extensions
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loaded = AgentKeysTests.Loaded()
        web.navigationDelegate = loaded
        return World(folder: folder, extensions: extensions, context: context, web: web, loaded: loaded)
    }

    private static func load(_ world: World, _ html: String = "<h1>Sign in</h1><input id=user><button id=go>Go</button>") async {
        await withCheckedContinuation { go in
            world.loaded.done = go
            world.web.loadHTMLString(html, baseURL: URL(string: "https://example.test/login"))
        }
    }

    private static func frames(_ web: PageView) async -> [PageFrame] {
        await withCheckedContinuation { go in web.childFrames { go.resume(returning: $0) } }
    }

    /// Waits until the page has the extension's frame open.
    private static func vault(_ web: PageView) async -> PageFrame? {
        for _ in 0..<200 {
            if let found = await frames(web).first(where: AgentSecrets.walledOff) { return found }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// Waits until the extension's frame has closed.
    private static func closed(_ web: PageView) async -> Bool {
        for _ in 0..<200 {
            if await !frames(web).contains(where: AgentSecrets.walledOff) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @Test func aRealExtensionFrameIsLeftOutByRefsAndRefusedAtSight() async throws {
        let world = try await Self.world()
        defer { world.close() }
        await Self.load(world)
        let vault = try #require(await Self.vault(world.web),
                                 "The fixture's content script must open a real extension frame")
        #expect(vault.url?.scheme == "webkit-extension")

        // Reading and acting by refs go on; pixels, scripts and unaimed
        // input wait, and the refusal says to work by refs.
        #expect(await AgentSecrets.check(world.web, reach: .document))
        #expect(await AgentSecrets.check(world.web, reach: .sight) == false)
        #expect(AgentSecrets.refusal(for: world.web).contains("by refs"))
        #expect(!AgentSecrets.refusal(for: world.web).contains(Self.secret))

        // Discovery never asks the extension's frame where it is.
        AgentPage.frames[ObjectIdentifier(world.web)] = nil
        await withCheckedContinuation { go in AgentPage.discover(world.web) { go.resume() } }
        #expect(!(AgentPage.frames[ObjectIdentifier(world.web)] ?? []).contains { $0.href.contains("frame.html") })

        // The window closes: sight works again, with no stale refusal.
        _ = try await world.web.call("document.getElementById('vault').remove(); return true;", in: .agent)
        try #require(await Self.closed(world.web))
        #expect(await AgentSecrets.check(world.web, reach: .sight))

        // A navigation opens it again: refused again, not remembered as closed.
        await Self.load(world)
        _ = try #require(await Self.vault(world.web))
        #expect(await AgentSecrets.check(world.web, reach: .sight) == false)
        #expect(await AgentSecrets.check(world.web, reach: .document))
    }

    @Test func aRefIntoTheRealExtensionFrameIsNeverRunIn() async throws {
        _ = NSApplication.shared
        let world = try await Self.world()
        defer { world.close() }
        await Self.load(world)
        let vault = try #require(await Self.vault(world.web))
        let tab = Tab(bench: true, engine: .webKit)
        defer { tab.close() }
        // The frame as WebKit reports it, handed to the runner as a ref's
        // frame would be: refused before any script runs in it.
        let refused: String? = await withCheckedContinuation { go in
            AgentPage.run(tab, "return document.body.innerText", frame: vault) { result in
                if case .failure(let error) = result { go.resume(returning: error.localizedDescription) }
                else { go.resume(returning: nil) }
            }
        }
        #expect(refused == AgentSecrets.walledOffFrame)
    }

    @Test func aRealClickByRefNeverLandsInTheExtensionsWindowOverAPagesFrame() async throws {
        // The extension's list drawn over a frame of the page's own, the
        // way a password manager's suggestions open under a field.
        let world = try await Self.world(frameStyle: "position:fixed;left:0;top:0;width:400px;height:300px;border:0;z-index:2147483647")
        defer { world.close() }
        await Self.load(world, """
        <iframe id=inner style="position:absolute;left:0;top:0;width:300px;height:200px;border:0"
          srcdoc="<style>body{margin:0}</style><button id=pay style='width:200px;height:100px'>Pay</button>"></iframe>
        """)
        _ = try #require(await Self.vault(world.web))
        // The ref, as a snapshot keeps it: the button in the page's frame.
        let held = try await world.web.call("""
        const inner = document.getElementById('inner');
        for (let i = 0; i < 100 && !(inner.contentDocument && inner.contentDocument.getElementById('pay')); i++) await new Promise(r => setTimeout(r, 25));
        const pay = inner.contentDocument.getElementById('pay');
        globalThis.__yab ||= {};
        globalThis.__yab.refs = new Map([['e1', pay]]);
        // The frame's own hit test can't see the list over it.
        return pay.ownerDocument.elementFromPoint(50, 50) === pay;
        """, in: .agent) as? Bool
        try #require(held == true, "In its own frame the button looks uncovered")
        func lands() async throws -> Bool? {
            try await world.web.call(AgentPage.landing, arguments: ["ref": "e1", "k": -1, "x": 50.0, "y": 50.0], in: .agent) as? Bool
        }
        // The top page sees the extension's window there: no real click.
        #expect(await AgentSecrets.extensionFrameOpen(world.web) == true)
        #expect(try await lands() == false)
        // Once the window closes, the point lands on the page's frame again.
        _ = try await world.web.call("document.getElementById('vault').remove(); return true;", in: .agent)
        try #require(await Self.closed(world.web))
        #expect(await AgentSecrets.extensionFrameOpen(world.web) == false)
        #expect(try await lands() == true)
    }

    /// The same frame and button with something of the page's own over it
    /// (a banner), and no extension's window: the real click of before.
    @Test func aCoveredClickByRefWithNoExtensionFrameStaysReal() async throws {
        _ = NSApplication.shared
        let tab = Tab(bench: true, engine: .webKit)
        defer { tab.close() }
        let web = try #require(tab.page.webKit)
        web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        web.loadHTMLString("""
        <iframe id=inner style="position:absolute;left:0;top:0;width:300px;height:200px;border:0"
          srcdoc="<style>body{margin:0}</style><button id=pay style='width:200px;height:100px'>Pay</button>"></iframe>
        <div id=banner style="position:absolute;left:0;top:0;width:400px;height:300px;z-index:2"></div>
        """, baseURL: URL(string: "https://example.test/login"))
        var held: Bool?
        for _ in 0..<200 where held != true {
            held = try? await web.call("""
            const inner = document.getElementById('inner');
            const pay = inner && inner.contentDocument && inner.contentDocument.getElementById('pay');
            if (!pay) return false;
            globalThis.__yab ||= {};
            globalThis.__yab.refs = new Map([['e1', pay]]);
            return pay.ownerDocument.elementFromPoint(50, 50) === pay;
            """, in: .agent) as? Bool
            if held != true { try await Task.sleep(for: .milliseconds(25)) }
        }
        try #require(held == true, "In its own frame the button looks uncovered")
        // The top page's own test sees the banner: without the gate this
        // would be a click by script.
        let covered = try await web.call(AgentPage.landing, arguments: ["ref": "e1", "k": -1, "x": 50.0, "y": 50.0], in: .agent) as? Bool
        try #require(covered == false, "The banner covers the frame from the top page")
        #expect(await AgentSecrets.extensionFrameOpen(tab.page) == false)
        let landing = await withCheckedContinuation { go in
            AgentPage.lands(tab, ref: "e1", at: CGPoint(x: 50, y: 50)) { go.resume(returning: $0) }
        }
        guard case .clear = landing else { Issue.record("expected a real click, got \(landing)"); return }
    }

    /// A ref taken while the extension's window is open, used after it
    /// closes and after a navigation that opens it again.
    @Test func aRefTakenWithTheExtensionFrameOpenGoesStaleAcrossANavigation() async throws {
        let world = try await Self.world()
        defer { world.close() }
        await Self.load(world)
        _ = try #require(await Self.vault(world.web))
        _ = try await world.web.call("""
        globalThis.__yab ||= {};
        globalThis.__yab.refs = new Map([['e1', document.getElementById('go')]]);
        return true;
        """, in: .agent)
        func click() async throws -> [String: Any]? {
            try await world.web.call(AgentPage.act, arguments: ["action": "click", "ref": "e1", "text": "", "value": "", "dy": 0], in: .agent) as? [String: Any]
        }
        // The window closes: the same ref still names the page's button.
        _ = try await world.web.call("document.getElementById('vault').remove(); return true;", in: .agent)
        try #require(await Self.closed(world.web))
        let after = try #require(try await click())
        #expect(after["error"] == nil && after["x"] != nil, "\(after)")
        #expect(await AgentSecrets.extensionFrameOpen(world.web) == false)
        // A navigation opens it again: the ref is stale, nothing is pressed,
        // and the answer carries none of the window's words.
        await Self.load(world)
        _ = try #require(await Self.vault(world.web))
        let stale = try #require(try await click())
        #expect(stale["error"] as? String == "stale ref e1, take a new snapshot")
        #expect(!"\(stale)".contains(Self.secret))
        #expect(await AgentSecrets.extensionFrameOpen(world.web) == true)
    }
}

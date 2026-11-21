import Foundation
import JavaScriptCore
import Testing
import WebKit
import YabCoreClient
@testable import Fast

@Suite @MainActor
struct ChromiumDRMExtensionTests {
    @Test func contentScriptsCanResolveExtensionURLsThroughBrowserRuntime() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.location = {href: 'https://example.test/login'};
            globalThis.crypto = {randomUUID: () => 'nonce'};
            globalThis.webkit = {messageHandlers: {yabChromiumExtension: {
                postMessage: () => Promise.resolve()
            }}};
            """)
        let id = "nngceckbapebfimnlniiiahkandclblb"
        context.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap(["id": id, "epoch": "test"]))
        let result = context.evaluateScript("""
            typeof browser !== 'undefined' && browser.runtime === chrome.runtime
                && browser.runtime.getURL('overlay/menu.html')
            """)
        #expect(context.exception == nil)
        #expect(result?.toString() == "chrome-extension://\(id)/overlay/menu.html")
        let surface = context.evaluateScript("""
            browser.storage === chrome.storage && browser.i18n === chrome.i18n
                && browser.tabs === undefined
            """)
        #expect(surface?.toBool() == true)
    }
    @Test func runtimeUsesTheDynamicHostOnlyForDeclaredPaths() throws {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        let host = "b717ee02-dd48-4113-9625-eb266617c65a"
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.location = {href: 'https://example.test/login'};
            globalThis.crypto = {randomUUID: () => 'nonce'};
            globalThis.webkit = {messageHandlers: {yabChromiumExtension: {postMessage: async () => true}}};
            globalThis.URL = class {
                constructor(url) { this.pathname = url.slice(url.indexOf('/', 19)).split(/[?#]/)[0]; }
            };
            """)
        context.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap([
            "id": id, "epoch": "test", "resourceHost": host, "dynamicResources": ["overlay/*.html"],
        ]))
        #expect(context.exception == nil)
        #expect(context.evaluateScript("browser.runtime.getURL('/overlay/menu.html?x#y')")?.toString()
                == "chrome-extension://\(host)/overlay/menu.html?x#y")
        #expect(context.evaluateScript("browser.runtime.getURL('background.js')")?.toString()
                == "chrome-extension://\(id)/background.js")
        #expect(context.evaluateScript("browser.runtime.getURL('')")?.toString() == "chrome-extension://\(id)/")
    }
    @Test func contentBridgeDeliversNotificationsWithoutRequiringAReply() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.location = {href: 'https://example.test/login'};
            globalThis.crypto = {randomUUID: () => 'nonce'};
            globalThis.clearTimeout = () => {};
            globalThis.webkit = {messageHandlers: {yabChromiumExtension: {
                postMessage: () => Promise.resolve()
            }}};
            """)
        context.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap(["id": "test", "epoch": "test"]))
        context.evaluateScript("""
            globalThis.result = {};
            const send = message => __yabWK.receive('tabs.sendMessage', {message});
            (async () => {
              try { await send('missing'); } catch (error) { result.missing = error.message; }
              browser.runtime.onMessage.addListener((message, _, reply) => {
                if (message === 'notify') result.delivered = true;
                else reply('answer');
              });
              result.notification = await send('notify');
              result.reply = await send('request');
            })();
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("result.missing")?.toString() == "Receiving end does not exist")
        #expect(context.evaluateScript("result.delivered && result.notification === null")?.toBool() == true)
        #expect(context.evaluateScript("result.reply")?.toString() == "answer")
    }

    @Test func resourceNavigationRecordsMatchWithoutFragmentsAndBoundTheMap() {
        var records = ResourceNavigations()
        let page = URL(string: "http://example.test/login")!
        let target = URL(string: "chrome-extension://id/popup.html")!
        records.record(frame: 7, url: URL(string: "chrome-extension://id/popup.html#x")!, source: page)
        #expect(records.take(frame: 7, url: target) == .source(page))
        // A record that no longer matches fails closed instead of answering.
        records.record(frame: 8, url: URL(string: "chrome-extension://id/a.html#y")!, source: page)
        #expect(records.take(frame: 8, url: URL(string: "chrome-extension://id/b.html")!) == .stale)
        #expect(records.take(frame: 9, url: target) == .none)
        // The oldest record goes first, never the whole map at once.
        for frame in 0..<129 {
            records.record(frame: UInt64(100 + frame), url: URL(string: "chrome-extension://id/p\(frame).html")!, source: page)
        }
        #expect(records.take(frame: 100, url: URL(string: "chrome-extension://id/p0.html")!) == .none)
        #expect(records.take(frame: 228, url: URL(string: "chrome-extension://id/p128.html")!) == .source(page))
    }

    /// The bridge's inbound messages reach the served page and its answer
    /// reaches the sender, including a port's disconnection error.
    @Test func inboundRelayAnswersReachTheSender() throws {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.CustomEvent = class { constructor(type, options) { this.type = type; this.detail = options && options.detail; } };
            globalThis.document = { listeners: {},
              addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); },
              dispatchEvent(event) { for (const fn of this.listeners[event.type] || []) fn(event); return true; } };
            globalThis.location = {href: 'chrome-extension://\(id)/overlay/menu.html', protocol: 'chrome-extension:'};
            globalThis.crypto = {randomUUID: () => 'nonce', getRandomValues: bytes => bytes.fill(1)};
            globalThis.setTimeout = () => 1;
            globalThis.clearTimeout = () => {};
            globalThis.webkit = {messageHandlers: {yabChromiumExtension: {postMessage: () => Promise.resolve()}}};
            """)
        context.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap(["id": id, "epoch": "test"]))
        let bootstrap = try ChromiumDRMExtensionScripts.bootstrap(["id": id, "epoch": "test"], page: true)
        context.evaluateScript("""
            globalThis.outcome = {};
            globalThis.pageWorld = {};
            ((globalThis) => { \(bootstrap) })(pageWorld);
            pageWorld.browser.runtime.onMessage.addListener((message, _, reply) => reply({answered: message}));
            __yabWK.receive('tabs.sendMessage', {message: 'tabs.sendMessage'}).then(value => outcome.answer = value, error => outcome.answerError = String(error));
            __yabWK.receive('port.message', {port: 'gone'}).then(value => outcome.port = value, error => outcome.portError = String(error));
            """)
        context.evaluateScript("1")
        #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
        #expect(context.evaluateScript("outcome.answer && outcome.answer.answered === 'tabs.sendMessage'")?.toBool() == true)
        #expect(context.evaluateScript("outcome.portError === 'Error: Port is disconnected'")?.toBool() == true)
    }

    @available(macOS 15.4, *)
    @Test func generatedBootstrapIsPrivateEvenUnderAWildcard() {
        let path = ChromiumDRMResources.bootstrapPath
        let manifest = ["web_accessible_resources": [["resources": ["*"], "matches": ["<all_urls>"]]]]
        let page = URL(string: "https://example.test/")!
        let owner = URL(string: "chrome-extension://owner/menu.html")!
        let other = URL(string: "chrome-extension://other/menu.html")!
        #expect(!ChromiumDRMResources.permits(path, dynamic: false, owner: "owner", asker: page, manifest: manifest))
        #expect(!ChromiumDRMResources.permits(path, dynamic: false, owner: "owner", asker: other, manifest: manifest))
        #expect(ChromiumDRMResources.permits(path, dynamic: false, owner: "owner", asker: owner, manifest: manifest))
    }

    @Test func pageGuardAdmitsOnlyTheExtensionsOwnPagesAndGrantedSites() throws {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        let guardSource = try ChromiumDRMExtensionScripts.pageGuard(id: id, grants: ["http://127.0.0.1/*"])
        func witness(_ href: String, opaque: Bool = false) throws -> Bool? {
            let context = try #require(JSContext())
            context.evaluateScript("""
                globalThis.URL = class { constructor(href) {
                    const match = /^([a-z][a-z0-9+.-]*):\\/\\/([^\\/?#]*)([^?#]*)/.exec(href) || [];
                    this.protocol = match[1] ? match[1] + ':' : '';
                    this.host = match[2] || ''; this.hostname = (match[2] || '').split(':')[0];
                    this.pathname = match[3] || ''; this.search = '';
                } };
                globalThis.location = (() => { const parsed = new URL(\(try ChromiumDRMExtensionScripts.json(href)));
                    return {href: \(try ChromiumDRMExtensionScripts.json(href)), protocol: parsed.protocol, host: parsed.host}; })();
                globalThis.window = {origin: \(opaque) ? 'null' : location.protocol + '//' + location.host};
                """)
            _ = context.evaluateScript("(()=>{\(guardSource)globalThis.witness=true;})()")
            #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
            return context.evaluateScript("witness === true")?.toBool()
        }
        #expect(try witness("chrome-extension://\(id)/overlay/menu.html") == true)
        #expect(try witness("chrome-extension://\(id)/overlay/menu.html", opaque: true) == false)
        #expect(try witness("chrome-extension://otherextension/overlay/menu.html") == false)
        #expect(try witness("http://127.0.0.1:18205/login") == true)
        #expect(try witness("https://github.com/login") == false)
    }

    @Test func dynamicResourceAccessRequiresTheCurrentOwnerAndDeclaredURLForm() throws {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        let other = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let host = "b717ee02-dd48-4113-9625-eb266617c65a"
        let entries = [id: ["resourceHost": host], other: ["resourceHost": "191eb7cd-93e5-4680-b81d-72d1fa868022"]]
        let manifest: [String: Any] = [
            "web_accessible_resources": [
                ["resources": ["/overlay/menu*.html"], "matches": ["https://example.test/*"], "use_dynamic_url": true],
                ["resources": ["overlay/icon.png"], "matches": ["https://example.test/*"]],
            ],
            "sandbox": ["pages": ["overlay/menu*.html"]],
        ]
        let site = try #require(URL(string: "https://example.test/login"))
        let excluded = try #require(URL(string: "https://excluded.test/login"))
        let extensionPage = try #require(URL(string: "chrome-extension://\(id)/frame.html"))
        let foreignPage = try #require(URL(string: "chrome-extension://\(other)/frame.html"))
        #expect(ChromiumDRMResources.owner(for: host, entries: entries) == id)
        #expect(ChromiumDRMResources.owner(for: host, entries: [other: entries[other]!]) == nil)
        #expect(ChromiumDRMResources.owner(for: host, entries: [id: entries[id]!, other: entries[id]!]) == nil)
        #expect(ChromiumDRMResources.permits("overlay/menu-list.html", dynamic: true, owner: id, asker: site, manifest: manifest))
        #expect(!ChromiumDRMResources.permits("overlay/menu-list.html", dynamic: false, owner: id, asker: site, manifest: manifest))
        #expect(!ChromiumDRMResources.permits("overlay/menu-list.html", dynamic: true, owner: id, asker: excluded, manifest: manifest))
        #expect(!ChromiumDRMResources.permits("overlay/menu-list.html", dynamic: true, owner: id, asker: foreignPage, manifest: manifest))
        #expect(!ChromiumDRMResources.permits("background.js", dynamic: true, owner: id, asker: extensionPage, manifest: manifest))
        #expect(ChromiumDRMResources.permits("background.js", dynamic: false, owner: id, asker: extensionPage, manifest: manifest))
        #expect(ChromiumDRMResources.permits("overlay/icon.png", dynamic: false, owner: id, asker: site, manifest: manifest))
        let policy = ChromiumDRMResources.sandboxPolicy("overlay/menu-list.html", owner: id, manifest: manifest)
        #expect(policy?.hasPrefix("sandbox allow-scripts") == true)
        #expect(policy?.contains("script-src chrome-extension://\(id)") == true)
        #expect(ChromiumDRMResources.sandboxPolicy("overlay/frame.html", owner: id, manifest: manifest) == nil)
    }

    @Test func accessibleResourcePatternsCoverOnlyWhatTheExtensionDeclared() {
        #expect(ChromiumDRMResources.pattern("overlay/menu.html", covers: "overlay/menu.html"))
        #expect(ChromiumDRMResources.pattern("fonts/*.ttf", covers: "fonts/inter.ttf"))
        #expect(ChromiumDRMResources.pattern("popup/fonts/*", covers: "popup/fonts/inter.woff2"))
        #expect(ChromiumDRMResources.pattern("overlay/*/menu*.html", covers: "overlay/x/menuy.html"))
        #expect(ChromiumDRMResources.pattern("popup/fonts/*", covers: "popup/fonts/"))
        #expect(!ChromiumDRMResources.pattern("overlay/*/menu*.html", covers: "overlay/menu.html"))
        #expect(!ChromiumDRMResources.pattern("overlay/menu.html", covers: "background.js"))
        #expect(!ChromiumDRMResources.pattern("popup/fonts/*", covers: "popup/fonts.js"))
        #expect(!ChromiumDRMResources.pattern("fonts/*.ttf", covers: "fonts/inter.woff2"))
        #expect(!ChromiumDRMResources.pattern("overlay/menu.html", covers: "overlay/menu.html.js"))
    }

    @Test func base64WrappedAssetsServeAsBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let wrapped = "{\"b64\":\"\(png.base64EncodedString())\"}"
        #expect(ChromiumDRMResources.bytes(from: wrapped) == png)
        #expect(ChromiumDRMResources.bytes(from: "plain text file") == nil)
        #expect(ChromiumDRMResources.bytes(from: "{\"b64\":\"not base64!\"}") == nil)
    }

    @Test func theInjectedBootstrapLandsInsideTheHead() {
        let page = "<!doctype html><html><head><title>x</title></head><body></body></html>"
        let served = String(decoding: ChromiumDRMResources.inject(into: Data(page.utf8))!, as: UTF8.self)
        #expect(served.contains("<head><script src=\"/__yab/page-bootstrap.js\"></script><title>x</title>"))
        let headless = "<!doctype html><html><body><p>hi</p></body></html>"
        let servedHeadless = String(decoding: ChromiumDRMResources.inject(into: Data(headless.utf8))!, as: UTF8.self)
        #expect(servedHeadless.hasPrefix("<!doctype html><script src=\"/__yab/page-bootstrap.js\"></script><html>"))
        let bare = "just text"
        let servedBare = String(decoding: ChromiumDRMResources.inject(into: Data(bare.utf8))!, as: UTF8.self)
        #expect(servedBare.hasPrefix("<script src=\"/__yab/page-bootstrap.js\"></script>"))
    }

    /// Chrome serves an extension page under the extension's own policy, or
    /// its default when the manifest names none; the injected bootstrap is a
    /// same-origin script so that policy admits it.
    @Test func pagePoliciesFollowTheManifestOrDefault() {
        #expect(ChromiumDRMResources.pagePolicy([:]) == "script-src 'self'; object-src 'self'")
        #expect(ChromiumDRMResources.pagePolicy(["content_security_policy": ["extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"]]) == "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'")
        #expect(ChromiumDRMResources.pagePolicy(["content_security_policy": "script-src 'self'; object-src 'self'"]) == "script-src 'self'; object-src 'self'")
    }

    /// An extension's served page talks to its own isolated world over the
    /// document they share: the world answers the page's calls and brings
    /// the calls the background sends back.
    @Test func servedPagesGetTheirAPIThroughTheDocumentRelay() throws {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        let document = """
            globalThis.CustomEvent = class { constructor(type, options) { this.type = type; this.detail = options && options.detail; } };
            globalThis.document = { listeners: {},
              addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); },
              dispatchEvent(event) { for (const fn of this.listeners[event.type] || []) fn(event); return true; } };
            """
        var world = try #require(JSContext())
        world.evaluateScript(document + """
            globalThis.location = {href: 'chrome-extension://\(id)/overlay/menu.html', protocol: 'chrome-extension:'};
            globalThis.crypto = {randomUUID: () => 'nonce'};
            globalThis.replies = [];
            globalThis.webkit = {messageHandlers: {yabChromiumExtension: {
                postMessage: body => new Promise(resolve => { replies.push(body); resolve('en-US'); })
            }}};
            """)
        world.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap(["id": id, "epoch": "test"]))
        world.evaluateScript("""
            globalThis.answer = null;
            document.addEventListener('yab-page-result', event => { answer = JSON.parse(event.detail); });
            document.dispatchEvent(new CustomEvent('yab-page-call', {detail: JSON.stringify({callId: 'x', op: 'i18n.getUILanguage', args: []})}));
            """)
        world.evaluateScript("1")
        #expect(world.exception == nil, Comment(rawValue: world.exception?.toString() ?? ""))
        #expect(world.evaluateScript("answer.callId === 'x' && answer.value === 'en-US'")?.toBool() == true)

        var page = try #require(JSContext())
        page.evaluateScript(document + """
            globalThis.location = {href: 'chrome-extension://\(id)/overlay/menu.html', protocol: 'chrome-extension:'};
            globalThis.crypto = {getRandomValues: values => values.fill(1)};
            globalThis.calls = [];
            document.addEventListener('yab-page-call', event => {
              const request = JSON.parse(event.detail); calls.push(request.op);
              document.dispatchEvent(new CustomEvent('yab-page-result', {detail: JSON.stringify({callId: request.callId, value: 'witness-answer'})}));
            });
            """)
        page.evaluateScript(try ChromiumDRMExtensionScripts.bootstrap(["id": id, "epoch": "test"], page: true))
        page.evaluateScript("""
            globalThis.outcome = {};
            browser.runtime.sendMessage('witness').then(value => outcome = {value}, error => outcome = {error: String(error)});
            """)
        page.evaluateScript("1")
        #expect(page.exception == nil, Comment(rawValue: page.exception?.toString() ?? ""))
        #expect(page.evaluateScript("outcome.value === 'witness-answer' && calls[0] === 'runtime.sendMessage'")?.toBool() == true)
    }

    @Test func servedPagesUseDistinctWorkerPortIDs() throws {
        let bootstrap = try ChromiumDRMExtensionScripts.bootstrap(["id": "test", "epoch": "test"], page: true)
        func firstPort(in page: Int) throws -> String {
            let context = try #require(JSContext())
            context.evaluateScript("""
                globalThis.crypto = {getRandomValues: values => values.fill(\(page))};
                globalThis.CustomEvent = class { constructor(type, options) { this.detail = options.detail; } };
                globalThis.document = {
                  addEventListener() {},
                  dispatchEvent(event) { globalThis.request = JSON.parse(event.detail); }
                };
                globalThis.setTimeout = () => {};
                """)
            context.evaluateScript(bootstrap)
            context.evaluateScript("browser.runtime.connect({name:'inline menu'});")
            #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
            #expect(context.evaluateScript("request.op === 'runtime.connect'")?.toBool() == true)
            return try #require(context.evaluateScript("request.args.port")?.toString())
        }
        let first = try firstPort(in: 1)
        let second = try firstPort(in: 2)
        #expect(first != second)
    }

    /// The bridge shim YabCore injects into an extension's Chromium worker.
    /// Its runtime.sendMessage mirrors Chrome: no listener rejects, a listener
    /// that answers settles the reply, one that only handles the message
    /// resolves null, and one that returns true keeps the channel open until
    /// it replies, with the wait timer cleared on every settlement.
    @Test func workerBridgeSettlesMessagesAndQueriesTheSelectedTab() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("YabCore/src/ext_bridge_worker.inc"), encoding: .utf8)
        let start = try #require(source.range(of: #"@R"JS("#)?.upperBound)
        let end = try #require(source.range(of: #")JS""#, range: start..<source.endIndex)?.lowerBound)
        let context = try #require(JSContext())
        context.evaluateScript("""
            globalThis.selectedTab = null;
            globalThis.__yabExtensionBridge = raw => {
                const call = JSON.parse(raw);
                if (call.op === 'tabs.active') __yabWKBridge.reply(call.id, selectedTab);
            };
            globalThis.timers = new Map();
            globalThis.setTimeout = fn => { timers.set(timers.size + 1, fn); return timers.size; };
            globalThis.clearTimeout = id => { timers.delete(id); };
            let handler = null, notified = 0, updates = [];
            globalThis.chrome = {
              tabs: {sendMessage() {}, connect() {}, get() {}, query: async () => [{id: 1}],
                onUpdated: {dispatch(id, change) { updates.push([id, change.url]); }}},
              windows: {WINDOW_ID_CURRENT: -2},
              runtime: {onMessage: {
                hasListeners: () => handler !== null,
                dispatch(message, sender, reply) {
                  const result = handler?.(message, reply);
                  return result === undefined ? undefined : {results: [result]};
                }
              }}
            };
            """)
        context.evaluateScript(String(source[start..<end]))
        context.evaluateScript("""
            globalThis.outcome = {};
            const send = message => __yabWKBridge.invoke('runtime.sendMessage', [message], null)
              .then(value => ({value}), error => ({error: String(error.message)}));
            (async () => {
              outcome.missing = await send('missing');
              handler = (message, reply) => {
                if (message === 'notify') { notified += 1; return; }
                reply({notified});
              };
              outcome.notification = await send('notify');
              outcome.witness = await send('witness');
              outcome.done = true;
            })();
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(outcome.missing)")?.toString() == #"{"error":"Receiving end does not exist"}"#)
        #expect(context.evaluateScript("JSON.stringify(outcome.notification)")?.toString() == #"{"value":null}"#)
        #expect(context.evaluateScript("JSON.stringify(outcome.witness)")?.toString() == #"{"value":{"notified":1}}"#)
        #expect(context.evaluateScript("outcome.done === true && notified === 1")?.toBool() == true)
        // A listener that returns true holds the reply open: nothing settles
        // before it answers, and answering clears the armed wait timer.
        context.evaluateScript("""
            let lateReply = null, lateSettled = null;
            handler = (message, reply) => { lateReply = reply; return true; };
            __yabWKBridge.invoke('runtime.sendMessage', ['late'], null)
              .then(value => lateSettled = {value}, error => lateSettled = {error: String(error.message)});
            globalThis.late = {reply: () => lateReply('answered'), settled: () => lateSettled};
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("timers.size === 1 && late.settled() === null")?.toBool() == true)
        context.evaluateScript("late.reply()")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(late.settled())")?.toString() == #"{"value":"answered"}"#)
        #expect(context.evaluateScript("timers.size === 0")?.toBool() == true)

        context.evaluateScript("""
            (async () => {
              handler = () => {};
              const post = (id, frameId, documentId) =>
                __yabWKBridge.invoke('runtime.sendMessage', ['notify'], {
                  frameId, documentId, tab: {id, active: true, url: 'https://example.test/login', windowId: 1}
                });
              selectedTab = 100;
              for (const [id, frame, doc] of [
                [100, 1, 'child'], [100, 0, 'main'], [100, 0, 'main'], [101, 0, 'other']
              ]) {
                await post(id, frame, doc);
              }
              const query = filter => chrome.tabs.query({active: true, ...filter}).then(rows => rows.map(row => row.id));
              outcome.currentWindow = await query({currentWindow: true});
              outcome.currentWindowID = await query({windowId: -2});
              outcome.excluded = await query({currentWindow: true, url: 'https://elsewhere.test/*'});
              await __yabWKBridge.invoke('forget', 100, null);
              await post(100, 0, 'next');
              selectedTab = 0;
              outcome.unaddressable = await query({currentWindow: true});
              selectedTab = null;
              outcome.native = await query({currentWindow: true});
            })();
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(outcome.currentWindow)")?.toString() == "[100]")
        #expect(context.evaluateScript("JSON.stringify(outcome.currentWindowID)")?.toString() == "[100]")
        #expect(context.evaluateScript("JSON.stringify(outcome.excluded)")?.toString() == "[]")
        #expect(context.evaluateScript("JSON.stringify(outcome.unaddressable)")?.toString() == "[]")
        #expect(context.evaluateScript("JSON.stringify(outcome.native)")?.toString() == "[1]")
        #expect(context.evaluateScript("JSON.stringify(updates)")?.toString() == #"[[100,"https://example.test/login"],[100,"https://example.test/login"]]"#)
    }

    @Test func grantAndManifestGuardsComposeWithoutLexicalRedeclarations() throws {
        let grant = try ChromiumDRMExtensionScripts.guardSource(matches: ["http://127.0.0.1/*"], excludes: [], globs: [], excludeGlobs: [])
        let manifest = try ChromiumDRMExtensionScripts.guardSource(matches: ["<all_urls>"], excludes: ["https://private.test/*"], globs: [], excludeGlobs: [])
        let context = try #require(JSContext())
        // Parse the exact composition used by declarative JS and CSS injection.
        // Browser globals are deliberately not evaluated by this parser check.
        _ = context.evaluateScript("new Function(" + (try ChromiumDRMExtensionScripts.json(grant + manifest + "globalThis.witness=true;")) + ")")
        #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
    }
    /// What a page's content script passes can hold what JSON can't (a Date,
    /// NaN, Infinity). The call fails with a Swift error. On 0.46.18
    /// JSONSerialization raised an Objective-C exception out of the task
    /// instead, which left the main actor's executor record dangling (and
    /// would abort this test process).
    @Test func pageValuesJSONCannotHoldFailTheCallWithoutRaising() async throws {
        let session = ChromiumDRMExtensionSession(profile: "json-test", privateMode: true, store: .nonPersistent())
        let unserializable: [Any] = [[Date()], [Double.nan], ["deep": [Double.infinity]]]
        for args in unserializable {
            await #expect(throws: YabCoreError.self) {
                _ = try await session.request("ext.bridge.invoke", ["op": "runtime.sendMessage", "args": args])
            }
        }
        let plain = try ChromiumDRMExtensionSession.json(["args": ["text", 1, true, NSNull()]])
        #expect(String(decoding: plain, as: UTF8.self).contains("text"))
    }
    @Test func matchPatternsKeepDNSBoundariesSchemeAndPath() {
        for url in ["https://spotify.com/play", "https://open.spotify.com/play?x=1"] {
            #expect(ChromiumDRMExtensionScripts.matches("https://*.spotify.com/play*", url: URL(string: url)!))
        }
        for url in ["https://evilspotify.com/play", "https://spotify.com.evil.test/play", "http://spotify.com/play", "https://spotify.com/account", "file:///play"] {
            #expect(!ChromiumDRMExtensionScripts.matches("https://*.spotify.com/play*", url: URL(string: url)!))
        }
        #expect(ChromiumDRMExtensionScripts.matches("http://127.0.0.1/*", url: URL(string: "http://127.0.0.1:1234/")!))
    }
    @Test func dnrUsesOnlyEnabledRuleSetsAndRejectsUnsupportedSemantics() throws {
        let rule: [String: Any] = ["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "/blocked.js", "resourceTypes": ["script"]]]
        let source = try ChromiumDRMExtensionScripts.json([rule])
        let entry: [String: Any] = ["manifest": ["declarative_net_request": ["rule_resources": [["id": "on", "path": "on.json"], ["id": "off", "path": "off.json"]]]], "files": ["on.json": source, "off.json": source], "grants": ["http://127.0.0.1/*"]]
        let result = try ChromiumDRMExtensionRules.rules(entry: entry, snapshot: ["enabled": ["on"]])
        #expect(result.count == 1)
        let trigger = try #require(result.first?["trigger"] as? [String: Any])
        #expect(trigger["resource-type"] as? [String] == ["script"])
        #expect((trigger["if-top-url"] as? [String])?.count == 1)
        let unsupported: [String: Any] = ["id": 2, "action": ["type": "modifyHeaders"], "condition": [:]]
        #expect(throws: (any Error).self) { try ChromiumDRMExtensionRules.rules(entry: entry, snapshot: ["dynamic": [unsupported]]) }
    }
    @Test func dnrAnchorsAndSeparatorsRemainDistinct() {
        let pattern = ChromiumDRMExtensionRules.urlFilter("||ads.example^")
        #expect("https://ads.example/script.js".range(of: pattern, options: .regularExpression) != nil)
        #expect("https://ads.example.evil/script.js".range(of: pattern, options: .regularExpression) == nil)
        #expect("https://evilads.example/script.js".range(of: pattern, options: .regularExpression) == nil)
    }
    @Test func reusedWireTabIDCannotRouteIntoThePreviousHelpersProfile() {
        let oldHelper = NSObject(), activeHelper = NSObject()
        let endpoints: [(profile: String, control: String, core: AnyObject)] = [
            ("old-profile", "tab-1", oldHelper), ("active-profile", "tab-1", activeHelper)
        ]
        let owner = endpoints.first {
            ChromiumDRMExtensionSession.owns(control: $0.control, core: $0.core,
                eventTab: "tab-1", activeCore: activeHelper)
        }
        #expect(owner?.profile == "active-profile")
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: oldHelper,
            eventTab: "tab-1", activeCore: activeHelper))
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: activeHelper,
            eventTab: "tab-2", activeCore: activeHelper))
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: nil,
            eventTab: "tab-1", activeCore: activeHelper))
    }

}

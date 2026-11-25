import AppKit
import PDFKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentSecretsTests {
    @Test nonisolated func extensionOriginsStayProtectedThroughWrappers() {
        for value in ["chrome-extension://vault/page.html", "webkit-extension://vault/page.html",
                      "moz-extension://vault/page.html", "safari-web-extension://vault/page.html",
                      "blob:chrome-extension://vault/id", "filesystem:chrome-extension://vault/temporary/a",
                      "blob:blob:blob:blob:blob:https://example.test/id"] {
            #expect(AgentSecrets.protected(URL(string: value)), "\(value) must be protected")
        }
        for value in ["https://example.test/chrome-extension://text", "http://127.0.0.1/page",
                      "about:blank", "blob:https://example.test/id"] {
            #expect(!AgentSecrets.protected(URL(string: value)), "\(value) is an ordinary origin")
        }
        #expect(!AgentSecrets.protected(nil))
    }

    @Test nonisolated func pdfViewerIsAnExactBrowserOrigin() {
        #expect(AgentSecrets.builtInPDFViewer(URL(string: "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html")))
        for value in ["chrome-extension://vault/page.html", "https://mhjfbmdgcfjbbpaeojofohoefgiehjai/",
                      "blob:chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/id",
                      "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai.evil/index.html"] {
            #expect(!AgentSecrets.builtInPDFViewer(URL(string: value)))
        }
        // Other consumers still treat extension URLs (including wrappers) as
        // protected. Only the native frame classifier recognizes the viewer.
        #expect(AgentSecrets.protected(URL(string: "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html")))
    }

    @Test nonisolated func onlyPixelsAndUnaimedInputNeedSight() {
        for (verb, request) in [("press", [:]), ("agent-pdf", [:]),
                                // A script can reach the frame element and
                                // postMessage to it, whatever it reads.
                                ("agent-eval", [:]), ("agent-eval-held", [:]),
                                ("act", ["action": "click", "x": 10.0, "y": 10.0]), ("act", ["action": "drag"]),
                                ("act", ["action": "type", "text": "x"]), ("act", [:]),
                                // Real pointer moves at a point, and Enter
                                // to whatever has focus, even by ref.
                                ("act", ["action": "drag", "ref": "e4", "to": "e9"]), ("act", ["action": "hover", "ref": "e4"]),
                                ("act", ["action": "type", "ref": "e4", "text": "x", "submit": true])] as [(String, [String: Any])] {
            #expect(AgentSecrets.reach(verb, request) == .sight, "\(verb) \(request)")
        }
        for (verb, request) in [("snapshot", [:]), ("settle", [:]),
                                ("act", ["action": "click", "ref": "e4"]), ("act", ["action": "type", "ref": "f2e7"]),
                                ("act", ["action": "scroll"])] as [(String, [String: Any])] {
            #expect(AgentSecrets.reach(verb, request) == .document, "\(verb) \(request)")
        }
    }

    @Test nonisolated func extensionFramesAreWalledOffByAddressOrOrigin() {
        let token = NSObject()
        func frame(_ url: String?, _ scheme: String = "", _ host: String = "") -> PageFrame {
            PageFrame(isMain: false, url: url.flatMap(URL.init(string:)), token: token, origin: PageOrigin(scheme: scheme, host: host, port: 0))
        }
        #expect(AgentSecrets.walledOff(frame("chrome-extension://vault/dropdown.html")))
        #expect(AgentSecrets.walledOff(frame("webkit-extension://vault/dropdown.html")))
        // An ordinary address the extension's origin stands behind.
        #expect(AgentSecrets.walledOff(frame("about:blank", "chrome-extension", "vault")))
        #expect(!AgentSecrets.walledOff(frame("https://pay.example.test/card", "https", "pay.example.test")))
        #expect(!AgentSecrets.walledOff(frame(nil)))
        let viewer = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html"
        #expect(!AgentSecrets.walledOff(frame(viewer, "chrome-extension", "mhjfbmdgcfjbbpaeojofohoefgiehjai")))
        #expect(AgentSecrets.walledOff(frame(viewer, "chrome-extension", "vault")))
    }

    @Test func anExtensionsFrameIsNeverRunInNorHeard() async {
        _ = NSApplication.shared
        let tab = Tab(bench: true, engine: .webKit)
        defer { tab.close() }
        let address = "chrome-extension://vault/dropdown.html"
        let frame = PageFrame(isMain: false, url: URL(string: address), token: NSObject())
        let refused: String? = await withCheckedContinuation { go in
            AgentPage.run(tab, "return 1", frame: frame) { result in
                if case .failure(let error) = result { go.resume(returning: error.localizedDescription) }
                else { go.resume(returning: nil) }
            }
        }
        // nil would mean the body ran in the extension's frame.
        #expect(refused == AgentSecrets.walledOffFrame)
        AgentPage.heard(tab.page, AgentPage.Frame(info: frame, href: address, w: 320, h: 240))
        AgentPage.heard(tab.page, AgentPage.Frame(info: PageFrame(isMain: false, url: nil, token: NSObject()), href: address, w: 320, h: 240))
        #expect(AgentPage.frames[ObjectIdentifier(tab.page)] == nil)
    }

    @Test func originalPDFTextIsNumberedByPage() throws {
        let document = PDFSignTests.contract(form: false)
        let second = PDFSignTests.contract(form: false)
        document.insert(try #require(second.page(at: 0)), at: 1)
        let text = try AgentPDF.extract(#require(document.dataRepresentation()))
        #expect(text.contains("Page 1\n"))
        #expect(text.contains("Page 2\n"))
        #expect(text.components(separatedBy: "Master Services Agreement").count == 3)
        #expect(throws: (any Error).self) { try AgentPDF.extract(Data("not a PDF".utf8)) }
    }

    static let hex = String(repeating: "a", count: 64)

    /// Pages the shipped 0.47.18 guard refused, read with its own probe
    /// (evals/golden/fixtures/agent_guard_0.47.18.js) and with this one.
    @Test func ordinaryPagesThe04718GuardRefusedAreReadable() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../evals/golden/fixtures/agent_guard_0.47.18.js").standardizedFileURL
        let shipped = try String(contentsOf: fixture, encoding: .utf8)
        for html in [
            // Apple Developer, Certificates, Identifiers & Profiles.
            "<title>Certificates, Identifiers & Profiles</title><nav>Certificates Identifiers Devices Profiles Keys</nav><h1>Register a new identifier</h1><p>Keys let you sign requests. Download the private key once; Apple doesn't keep a copy.</p><label>Description<input name=description></label><label>Identifier<input name=identifier placeholder='group.com.example.app'></label>",
            "<h1>Docs</h1><p>Generate a private key with openssl, then keep your recovery codes and recovery phrase somewhere safe.</p>",
            "<h1>Sample</h1><pre>-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg...\n-----END PRIVATE KEY-----</pre>",
            "<h1>Wallet</h1><p>Address</p><input name=address value=0x" + Self.hex + "><input name=secret_key value=" + Self.hex + ">",
            "<h1>Account security</h1><input name=backup_codes value=SYNTHETIC>",
        ] {
            let page = await AgentKeysTests.page(html)
            let old = try await page.call("return Boolean(" + shipped + ")", in: .agent, gesture: false)
            let current = try await page.call("return " + AgentSecrets.reasonProbe, in: .agent, gesture: false)
            #expect(old as? Bool == true, "0.47.18 refused this page")
            #expect(current as? Bool == false, "an ordinary page: \(html.prefix(60))")
        }
    }

    @Test func onlyRecoveryPhraseAndPrivateKeyFieldsAreRefused() async throws {
        let cases: [(String, String?)] = [
            ("<title>Checkout</title><input type=password value=synthetic-password>", nil),
            ("<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>", nil),
            ("<h1>Mnemonic devices</h1><input name=title>", nil),
            ("<input name=recovery_code>", nil),
            ("<input aria-label='Recovery email'>", nil),
            ("<input type=hidden name=seed_phrase value=x>", nil),
            ("<label>Seed phrase<input></label>", "recovery phrase field"),
            ("<input name=recovery_phrase value=SYNTHETIC_WORDS_ONLY>", "recovery phrase field"),
            ("<input id=seedPhraseWord3>", "recovery phrase field"),
            ("<textarea placeholder='Enter your 12 recovery words'></textarea>", "recovery phrase field"),
            ("<input autocomplete=off name=mnemonic>", "recovery phrase field"),
            ("<span id=l>Backup phrase</span><textarea aria-labelledby=l></textarea>", "recovery phrase field"),
            ("<fieldset><legend>Secret Recovery Phrase</legend><input aria-label='Word 1'><input aria-label='Word 2'></fieldset>", "recovery phrase field"),
            ("<div contenteditable aria-label='Seed words'></div>", "recovery phrase field"),
            ("<textarea>-----BEGIN PRIVATE KEY----- SYNTHETIC</textarea>", "private key field"),
            ("<input value='-----BEGIN RSA PRIVATE KEY----- SYNTHETIC'>", "private key field"),
        ]
        for (html, expected) in cases {
            let page = await AgentKeysTests.page(html)
            let result = try await page.call("return " + AgentSecrets.reasonProbe, in: .agent, gesture: false)
            if let expected { #expect(result as? String == expected, "\(html)") }
            else { #expect(result as? Bool == false, "\(html)") }
            #expect(!String(describing: result).contains("SYNTHETIC"))
        }
    }

    @Test func openShadowRootsHaveTheSameSecretBoundary() async throws {
        let page = await AgentKeysTests.page("<title>Account</title><div id=host></div>")
        _ = try await page.call("""
        const root = document.getElementById('host').attachShadow({mode:'open'});
        root.innerHTML = '<div id=nested></div>';
        root.getElementById('nested').attachShadow({mode:'open'});
        return true;
        """, in: .agent)
        for (html, expected) in [
            ("<input aria-label='Full name' value=Ada>", false),
            ("<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>", false),
            ("<input name=recovery_phrase value=SYNTHETIC_WORDS_ONLY>", true),
            ("<textarea>-----BEGIN PRIVATE KEY----- SYNTHETIC</textarea>", true),
            ("<input name=secret_key value='" + Self.hex + "'>", false),
            ("<button>Save draft</button>", false),
        ] {
            _ = try await page.call("document.getElementById('host').shadowRoot.getElementById('nested').shadowRoot.innerHTML = html; return true;",
                                    arguments: ["html": html], in: .agent)
            let result = try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)
            #expect(result as? Bool == expected)
        }
    }

    @Test func webKitChecksCurrentFramesAndNamesWhatItFound() async throws {
        let page = await AgentKeysTests.page("<h1>Ordinary account</h1>")
        _ = try await page.call("""
        const frame = document.createElement('iframe');
        frame.srcdoc = '<h1>Import a wallet</h1><input name=seed_phrase value=SYNTHETIC_WORDS_ONLY>';
        await new Promise(resolve => { frame.onload = resolve; document.body.append(frame); });
        return true;
        """, in: .agent)
        #expect(await AgentSecrets.check(page) == false)
        let said = AgentSecrets.refusal(for: page)
        #expect(said.contains("recovery-phrase field"))
        #expect(!said.contains("SYNTHETIC_WORDS_ONLY"))
        #expect(!said.lowercased().contains("password"))
        _ = try await page.call("document.querySelector('iframe').remove(); return true;", in: .agent)
        #expect(await AgentSecrets.check(page))
    }

    @Test func refusalsSayWhatWasFound() {
        #expect(AgentSecrets.message("extension page").contains("extension's own page"))
        // An extension's window over a field leaves the page to read and
        // act on by refs, and says so.
        #expect(AgentSecrets.message("extension frame").contains("by refs"))
        #expect(!AgentSecrets.message("extension frame").contains("The person must handle it"))
        #expect(AgentSecrets.message("recovery phrase field").contains("recovery-phrase field"))
        #expect(AgentSecrets.message("private key field").contains("private key"))
        for reason in AgentSecrets.reasons.keys {
            #expect(!AgentSecrets.message(reason).contains("keys or passwords"))
        }
    }

    @Test func largeAndDeepOrdinaryDocumentsStayReadable() async throws {
        for html in [
            "<h1>Dashboard</h1>" + String(repeating: "<span>cell</span>", count: 120000),
            "<h1>Feed</h1><p>" + String(repeating: "update ", count: 200000) + "</p>",
            "<h1>Commits</h1><pre>" + Self.hex + "</pre><input name=commit value=" + Self.hex + ">",
        ] {
            let page = await AgentKeysTests.page(html)
            let result = try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)
            #expect(result as? Bool == false)
        }
        let page = await AgentKeysTests.page("<title>Account</title><div id=host></div>")
        _ = try await page.call("""
        let host = document.getElementById('host');
        for (let n = 0; n < 40; n++) {
          const root = host.attachShadow({mode:'open'});
          host = document.createElement('div');
          root.appendChild(host);
        }
        for (let n = 0; n < 300; n++) document.body.appendChild(document.createElement('div')).attachShadow({mode:'open'}).innerHTML = '<span>item</span>';
        return true;
        """, in: .agent)
        #expect(try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false) as? Bool == false)
        // A seed field at the bottom of that deep tree is still found.
        _ = try await page.call("""
        let host = document.getElementById('host');
        while (host.shadowRoot) host = host.shadowRoot.firstElementChild || host.shadowRoot.firstChild;
        host.innerHTML = '<input name=recovery_phrase>';
        return true;
        """, in: .agent)
        #expect(try await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false) as? Bool == true)
    }
}


@Suite(.serialized)
@MainActor
struct AgentSecretsTestsNativeModal {
    @Test func heldNativeQuestionReturnsOnlyStaticStatus() {
        _ = NSApplication.shared
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(bench: true, engine: .chromium, factory: factory)
        let other = Tab(bench: true, engine: .webKit)
        defer { tab.close(); other.close() }
        #expect(AgentSecrets.nativeQuestionReply([tab]) == nil)
        tab.asks = [PageAsk(kind: .confirm, host: "private.test", message: "PRIVATE_MODAL_CANARY")]
        let reply = AgentSecrets.nativeQuestionReply([tab])
        #expect(reply?["code"] as? String == "NATIVE_PAGE_QUESTION")
        #expect(reply?["needs_user"] as? Bool == true)
        #expect(reply?["asking"] == nil, "A native question must not replay the click through permit handoff-wait")
        #expect(!String(describing: reply).contains("PRIVATE_MODAL_CANARY"))
        #expect(!String(describing: reply).contains("private.test"))
        // The real reply wrapper must not append a queued page notice to
        // this deliberately data-free status.
        let browser = Browser(windowID: UUID())
        let bench = Bench()
        browser.lay([tab])
        defer { browser.lay([]); browser.letGo() }
        StuckWatch.notices[tab.id] = "PRIVATE_NOTICE_CANARY"
        defer { StuckWatch.notices[tab.id] = nil }
        var delivered: [String: Any] = [:]
        bench.agentCommand("snapshot", ["id": tab.id.uuidString], browser: browser) { delivered = $0 }
        #expect(delivered["code"] as? String == "NATIVE_PAGE_QUESTION")
        #expect(!String(describing: delivered).contains("PRIVATE_NOTICE_CANARY"))
        #expect(!String(describing: delivered).contains("PRIVATE_MODAL_CANARY"))
        other.asks = tab.asks
        #expect(AgentSecrets.nativeQuestionReply([other]) == nil)
        tab.asks = []
        #expect(AgentSecrets.nativeQuestionReply([tab]) == nil)
    }
}

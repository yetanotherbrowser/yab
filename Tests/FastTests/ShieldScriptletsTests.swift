import AppKit
import Testing
import WebKit
@testable import Fast

// Shield's scriptlets on WebKit pages (ShieldScriptlets): an inline ad
// library stopped on a site its rules name, in its frames too, none where Shield
// is off or an extension blocks, and on a site with no rules nothing of the
// page's own touched.
@MainActor
@Suite(.serialized)
struct ShieldScriptletsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/shield")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name + ".html"), encoding: .utf8)
    }

    private func table(_ rules: String...) -> ShieldScriptlets.Table? {
        ShieldScriptlets.Table(Filters.convert([rules.joined(separator: "\n")]).scriptlets.table())
    }

    /// This table and switch in place; what it answers puts back the ones before.
    private func use(_ table: ShieldScriptlets.Table?, on: Bool = true) -> @MainActor () -> Void {
        let before = (ShieldScriptlets.table, ShieldScriptlets.on)
        ShieldScriptlets.install(table)
        ShieldScriptlets.on = on
        return {
            ShieldScriptlets.install(before.0)
            ShieldScriptlets.on = before.1
        }
    }

    @MainActor private final class Opened {
        let browser: Browser
        let id: UUID
        let tab: Tab
        init(_ browser: Browser, _ id: UUID, _ tab: Tab) { self.browser = browser; self.id = id; self.tab = tab }
        func close() {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
    }

    private func tab(bench: Bool = false) -> Opened {
        let id = UUID()
        let browser = Browser(windowID: id)
        let tab = Tab(bench: bench, factory: .webKitOnly)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        tab.go(to: URL(string: "about:blank#shield")!)
        return Opened(browser, id, tab)
    }

    private func load(_ html: String, at base: String) -> Opened {
        let opened = tab()
        opened.tab.page.navigate(html: html, base: URL(string: base)!)
        return opened
    }

    /// The fixture's verdict, "blocked/ok" when the trick was stopped and the page kept working.
    private func verdict(_ tab: Tab, wait: Duration = .seconds(4)) async throws -> String {
        let ask = "window.__yabFixture && window.__yabFixture.state !== 'pending' ? window.__yabFixture.state + '/' + window.__yabFixture.collateral : ''"
        let start = ContinuousClock.now
        while ContinuousClock.now - start < wait {
            if let said = try? await tab.page.fixtureExpression(ask, world: .page) as? String, !said.isEmpty { return said }
            try await Task.sleep(for: .milliseconds(50))
        }
        return "pending"
    }

    private func scriptlets(in list: [WKUserScript]) -> [WKUserScript] {
        list.filter { $0.source.contains("var SCRIPTLETS = {") }
    }

    // MARK: - stopping the trick

    @Test func anInlineAdLibraryIsStopped() async throws {
        let html = try fixture("t1-inline-aclib")
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)"))
            defer { restore() }
            let opened = load(html, at: "https://popups.example/")
            defer { opened.close() }
            #expect(try await verdict(opened.tab) == "blocked/ok")
        }
        // Without the script the same page runs its library.
        do {
            let restore = use(nil)
            defer { restore() }
            let opened = load(html, at: "https://popups.example/")
            defer { opened.close() }
            #expect(try await verdict(opened.tab) == "leaked/ok")
        }
    }

    // Rules whose paths share a link (YouTube's three on ytInitialPlayerResponse,
    // an aopr and aopw under one object) each take effect, not only the first.
    @Test func rulesSharingAPathAllTakeEffect() async throws {
        let html = try fixture("s8-shared-chain")
        let rules = html.components(separatedBy: "<!-- rule: ").dropFirst().compactMap { $0.components(separatedBy: " -->").first }
        #expect(rules.count == 5)
        for rule in [true, false] {
            let restore = use(rule ? table(rules.joined(separator: "\n")) : nil)
            defer { restore() }
            let opened = load(html, at: "https://fixture.test/")
            defer { opened.close() }
            #expect(try await verdict(opened.tab) == (rule ? "blocked/ok" : "leaked/ok"), "rule \(rule)")
        }
    }

    // nowoif in the page's frames: a hidden frame's window.open, frames
    // made by script, a frame that redefines open, a srcdoc frame. Each
    // opens its window without the script, in a tab that lets pages open
    // windows on their own.
    @Test(arguments: ["t4-iframe-open", "t4b-iframe-frames", "t4c-iframe-redefine", "t4d-iframe-srcdoc"])
    func aFramesWindowOpenIsStopped(_ name: String) async throws {
        let html = try fixture(name)
        for rule in [true, false] {
            let restore = use(rule ? table("popups.*##+js(nowoif)") : nil)
            defer { restore() }
            let opened = tab(bench: true)
            defer { opened.close() }
            opened.tab.page.navigate(html: html, base: URL(string: "https://popups.example/")!)
            #expect(try await verdict(opened.tab) == (rule ? "blocked/ok" : "leaked/ok"), "\(name), rule \(rule)")
        }
    }

    // nowoif on a phone-style ad: a script click on a clear new-tab link
    // over the page, and on a link never put in the page.
    @Test func aScriptClickOnAnAdLinkIsStopped() async throws {
        let html = try fixture("t7-link-cover")
        for rule in [true, false] {
            let restore = use(rule ? table("popups.*##+js(nowoif)") : nil)
            defer { restore() }
            let opened = tab(bench: true)
            defer { opened.close() }
            opened.tab.page.navigate(html: html, base: URL(string: "https://popups.example/")!)
            #expect(try await verdict(opened.tab) == (rule ? "blocked/ok" : "leaked/ok"), "rule \(rule)")
            if rule {
                try await Task.sleep(for: .milliseconds(500))
                #expect(opened.browser.tabs.count == 1)
            } else {
                // The ad's tab opens late on a Mac busy with other suites.
                #expect(try await Loaded.until(4) { opened.browser.tabs.count > 1 })
            }
        }
    }

    /// A scriptlet that touches nothing the cover fixtures use: what names a
    /// site for the click guard without stopping the cover itself, as nowoif would.
    private static let names = "##+js(set, yabFixtureUnused, true)"

    /// The cover fixture (t8) at `address`, with this table in place.
    private func cover(at address: String, _ table: ShieldScriptlets.Table?) async throws -> String {
        let restore = use(table)
        defer { restore() }
        // A cover is measured against the viewport, so the page needs one.
        let opened = tab()
        defer { opened.close() }
        opened.tab.page.setFrameSize(NSSize(width: 800, height: 600))
        opened.tab.page.navigate(html: try fixture("t8-cover-guard"), base: URL(string: address)!)
        return try await verdict(opened.tab)
    }

    // The click guard, only on a site the lists name for a scriptlet, by
    // its host, a domain above it or an entity: a clear cover over the
    // page leading to another site is stopped there, a card's link or the
    // site's own is not. A table naming other sites, a `~site` or an
    // exception leaves the page as it would be without the script.
    @Test func aCoverIsStoppedOnlyWhereTheListsNameTheSite() async throws {
        let cases: [(rules: [String], at: String, verdict: String)] = [
            (["news.test" + Self.names], "https://news.test/", "blocked/ok"),
            (["news.test" + Self.names], "https://www.news.test/", "blocked/ok"),
            (["news.*" + Self.names], "https://news.test/", "blocked/ok"),
            (["other.example##+js(nowoif)"], "https://news.test/", "leaked/ok"),
            (["news.test,~safe.news.test" + Self.names], "https://safe.news.test/", "leaked/ok"),
            (["news.test" + Self.names, "news.test#@#+js()"], "https://news.test/", "leaked/ok"),
            (["news.test" + Self.names, "news.test#@#+js(set, yabFixtureUnused, true)"], "https://news.test/", "leaked/ok"),
            ([], "https://news.test/", "leaked/ok"),
        ]
        for one in cases {
            let made = one.rules.isEmpty ? nil : ShieldScriptlets.Table(Filters.convert([one.rules.joined(separator: "\n")]).scriptlets.table())
            #expect(try await cover(at: one.at, made) == one.verdict, "\(one.rules) at \(one.at)")
        }
    }

    @Test func aCoverIsLeftWhereShieldIsOffForTheSite() async throws {
        let wasPaused = Shield.shared.isPaused(on: "news.test")
        Shield.shared.pause("news.test", true)
        defer { Shield.shared.pause("news.test", wasPaused) }
        #expect(try await cover(at: "https://news.test/", table("news.test" + Self.names)) == "leaked/ok")
    }

    // Chromium registers one script for every site and carries where Shield
    // is off in it, so the page decides. Its exact text, run here by
    // WebKit: the same page script, not Yab's Chromium.
    @Test func chromiumsCopyLeavesACoverWhereShieldIsOffForTheSite() async throws {
        let restore = use(table("news.test" + Self.names))
        defer { restore() }
        let opened = tab()
        defer { opened.close() }
        let wasPaused = Shield.shared.isPaused(on: "news.test")
        defer { Shield.shared.pause("news.test", wasPaused) }
        for paused in [false, true] {
            Shield.shared.pause("news.test", paused)
            let policy = try #require(ShieldScriptlets.chromiumPolicy(for: opened.tab, host: "news.test"))
            let source = try #require(ShieldScriptlets.chromium(policy)).source
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.loadHTMLString(try fixture("t8-cover-guard"), baseURL: URL(string: "https://news.test/"))
            #expect(try await Loaded.until(4) { view.title?.contains("/") == true }, "paused \(paused)")
            #expect(view.title == (paused ? "leaked/ok" : "blocked/ok"), "paused \(paused)")
        }
    }

    // A person's click on a clear cover whose handler opens twice: the
    // first open takes the cover away, and the second, in the same click,
    // must not get through either.
    @Test func aCoverThatOpensTwiceOpensNothing() async throws {
        let html = try fixture("t9-cover-opens-twice")
        for script in [true, false] {
            let restore = use(script ? table("news.test" + Self.names) : nil)
            defer { restore() }
            let opened = tab(bench: true)
            defer { opened.close() }
            let view = requireNativeWebKitFixture(opened.tab, "ShieldScriptletsTests")
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            opened.tab.page.navigate(html: html, base: URL(string: "https://news.test/")!)
            #expect(try await Loaded.until(4) {
                (try? await opened.tab.page.fixtureExpression("!!window.__yabFixture && document.readyState === 'complete'", world: .page)) as? Bool == true
            })
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(PageBenchInput.click(opened.tab.page, x: 400, y: 300))
            #expect(try await verdict(opened.tab) == "clicked/ok", "script \(script)")
            if script {
                try await Task.sleep(for: .milliseconds(500))
                #expect(opened.browser.tabs.count == 1)
            } else {
                #expect(try await Loaded.until(4) { opened.browser.tabs.count > 2 })
            }
        }
    }

    // uBO: a `~site` spares that site from its own line only. Another line
    // making the same call still runs there, on the site or a part of it;
    // a #@# takes it back from every line.
    @Test func anExclusionSparesOnlyItsOwnLine() async throws {
        let html = try fixture("s7a-nowoif-all")
        let spares = "popups.example,~safe.popups.example##+js(nowoif)"
        let cases: [(rules: [String], at: String, verdict: String)] = [
            ([spares], "https://safe.popups.example/", "leaked/ok"),
            ([spares, "popups.example##+js(nowoif)"], "https://safe.popups.example/", "blocked/ok"),
            ([spares, "popups.*##+js(nowoif)"], "https://safe.popups.example/", "blocked/ok"),
            ([spares, "a.safe.popups.example##+js(nowoif)"], "https://a.safe.popups.example/", "blocked/ok"),
            ([spares, "popups.example##+js(nowoif)", "safe.popups.example#@#+js(nowoif)"], "https://safe.popups.example/", "leaked/ok"),
            ([spares, "popups.example##+js(nowoif)"], "https://popups.example/", "blocked/ok"),
        ]
        for one in cases {
            let restore = use(ShieldScriptlets.Table(Filters.convert([one.rules.joined(separator: "\n")]).scriptlets.table()))
            defer { restore() }
            // A tab that lets pages open windows on their own, so only the
            // script returns null.
            let opened = tab(bench: true)
            defer { opened.close() }
            opened.tab.page.navigate(html: html, base: URL(string: one.at)!)
            #expect(try await verdict(opened.tab) == one.verdict, "\(one.rules) at \(one.at)")
        }
    }

    // MARK: - when there is none

    @Test func aSitePausedGetsNoScript() async throws {
        let html = try fixture("t1-inline-aclib")
        let wasPaused = Shield.shared.isPaused(on: "popups.example")
        Shield.shared.pause("popups.example", true)
        defer { Shield.shared.pause("popups.example", wasPaused) }
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)"))
            defer { restore() }
            let opened = load(html, at: "https://popups.example/")
            defer { opened.close() }
            #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "popups.example", css: ""))).isEmpty)
            #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "news.test", css: ""))).count == 1)
            #expect(try await verdict(opened.tab) == "leaked/ok")
        }
    }

    @Test func anExtensionBlockingGetsNoScript() async throws {
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)"))
            defer { restore() }
            let opened = tab()
            defer { opened.close() }
            let chosen = Shield.shared.chosen, source = Shield.shared.source
            Shield.shared.choose("blocker.test")
            Shield.shared.landed("blocker.test")
            defer {
                Shield.shared.choose(chosen)
                if case .extension(let id) = source { Shield.shared.landed(id) }
            }
            #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "popups.example", css: ""))).isEmpty)
            Shield.shared.choose(nil)
            #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "popups.example", css: ""))).count == 1)
        }
    }

    @Test func switchedOffForMeasuringGetsNoScript() async throws {
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)"), on: false)
            defer { restore() }
            let opened = tab()
            defer { opened.close() }
            #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "popups.example", css: ""))).isEmpty)
            #expect(ShieldScriptlets.chromiumPolicy(for: opened.tab, host: "popups.example") == nil)
        }
    }

    // MARK: - what it costs

    @Test func everyTabSharesOneScript() async throws {
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)", "example.org##+js(nowoif)"))
            defer { restore() }
            let one = tab(), two = tab()
            defer { one.close(); two.close() }
            let a = scriptlets(in: PageScripts.list(for: one.tab, .init(host: "popups.example", css: "")))
            let b = scriptlets(in: PageScripts.list(for: two.tab, .init(host: "news.test", css: "")))
            try #require(a.count == 1 && b.count == 1)
            #expect(a[0] === b[0])
            #expect(a[0].injectionTime == .atDocumentStart && !a[0].isForMainFrameOnly)
            // On the controllers WebKit was given, the same object.
            for opened in [one, two] {
                opened.tab.arm(hiding: "", on: "popups.example")
                let controller = requireNativeWebKitFixture(opened.tab, "ShieldScriptletsTests").configuration.userContentController
                #expect(controller.userScripts.contains { $0 === a[0] })
            }
        }
    }

    // A window the page opens is a tab of its own, with a controller of its
    // own (WebKitPopups): it is armed with the same script when it is built.
    @Test func aWindowThePageOpensGetsTheScript() async throws {
        let restore = use(table("popups.example##+js(aopr, aclib)"))
        defer { restore() }
        let opened = tab(bench: true)
        defer { opened.close() }
        opened.tab.page.navigate(html: "<script>setTimeout(() => window.open('about:blank#child'), 50)</script>", base: URL(string: "https://news.test/")!)
        var child: Tab?
        for _ in 0..<100 where child == nil {
            try await Task.sleep(for: .milliseconds(50))
            child = opened.browser.tabs.first { $0 !== opened.tab && $0.built != nil }
        }
        let popup = try #require(child)
        let shared = scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "news.test", css: "")))
        try #require(shared.count == 1)
        let controller = requireNativeWebKitFixture(popup, "ShieldScriptletsTests").configuration.userContentController
        #expect(controller !== requireNativeWebKitFixture(opened.tab, "ShieldScriptletsTests").configuration.userContentController)
        #expect(controller.userScripts.contains { $0 === shared[0] })
    }

    @Test func aBuildWritesTheTableAndEveryPageGetsIt() async throws {
        let restore = use(nil)
        defer { restore() }
        let file = Store.folder.appendingPathComponent("Shield/scriptlets.txt")
        let kept = try? Data(contentsOf: file)
        defer { if let kept { try? kept.write(to: file) } else { try? FileManager.default.removeItem(at: file) } }
        let rules = Filters.convert(["popups.example##+js(aopr, aclib)\nexample.org##+js(nowoif)"])
        ShieldScriptlets.write(rules)
        for _ in 0..<100 where ShieldScriptlets.table == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ShieldScriptlets.table?.text == rules.scriptlets.table())
        #expect(ShieldScriptlets.table?.webKitSource.contains("__YAB_") == false)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == rules.scriptlets.table())
    }

    // No ##+js in the lists names no site, so no page gets the script, the
    // click guard with it.
    @Test func aBuildWithNoScriptletsPutsNoScriptOnPages() async throws {
        let restore = use(table("popups.example##+js(nowoif)"))
        defer { restore() }
        let file = Store.folder.appendingPathComponent("Shield/scriptlets.txt")
        let kept = try? Data(contentsOf: file)
        defer { if let kept { try? kept.write(to: file) } else { try? FileManager.default.removeItem(at: file) } }
        ShieldScriptlets.write(Filters.convert(["||ads.example^\nexample.org##.ad"]))
        #expect(try await Loaded.until(2) { ShieldScriptlets.table == nil })
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
        let opened = tab()
        defer { opened.close() }
        #expect(scriptlets(in: PageScripts.list(for: opened.tab, .init(host: "news.test", css: ""))).isEmpty)
    }

    /// What a page can tell of its own functions: their names, lengths,
    /// descriptors and text, the stack a bad call throws (a wrapper's own
    /// frame shows there), and every global.
    private static let fingerprint = """
    (() => {
      const describe = (owner, key, bad) => {
        const f = owner[key], d = Object.getOwnPropertyDescriptor(owner, key);
        let stack = '';
        try { bad(f) } catch (e) { stack = String(e && e.stack || e).replace(/:\\d+:\\d+/g, '') }
        return [typeof f, f && f.name, f && f.length, d && [d.writable, d.enumerable, d.configurable, typeof d.get].join(), String(f), stack].join('|');
      };
      return JSON.stringify({
        open: describe(window, 'open', f => f.call(document)),
        listen: describe(EventTarget.prototype, 'addEventListener', f => f.call(null, 'x', null)),
        timeout: describe(window, 'setTimeout', f => f.call(document, '')),
        append: describe(Node.prototype, 'appendChild', f => f.call(null)),
        define: describe(Object, 'defineProperty', f => f(1)),
        text: describe(Function.prototype, 'toString', f => f.call(1)),
        globals: Object.getOwnPropertyNames(window).sort().join(','),
      });
    })()
    """

    private func fingerprint(at base: String, table: ShieldScriptlets.Table?) async throws -> [String: String] {
        let restore = use(table)
        defer { restore() }
        let opened = load("<!doctype html><title>plain</title><p>news</p>", at: base)
        defer { opened.close() }
        let present = !scriptlets(in: PageScripts.list(for: opened.tab, .init(host: PageScripts.host(of: URL(string: base)), css: ""))).isEmpty
        #expect(present == (table != nil))
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await opened.tab.page.fixtureExpression("document.title", world: .page)) as? String == "plain" { break }
        }
        let said = try await opened.tab.page.fixtureExpression(Self.fingerprint, world: .page) as? String ?? ""
        return (try? JSONDecoder().decode([String: String].self, from: Data(said.utf8))) ?? [:]
    }

    // A site with no rules: the script is there and leaves the page as it
    // would be without it. The same look on a site with rules tells the
    // wrappers, so it would see one here.
    @Test func aSiteWithNoRulesIsUntouched() async throws {
        let rules = table("popups.example##+js(nowoif)", "popups.example##+js(aeld, click)", "popups.example##+js(nostif, ads)")
        let absent = try await fingerprint(at: "https://news.test/", table: nil)
        let present = try await fingerprint(at: "https://news.test/", table: rules)
        try #require(absent.count == 7)
        #expect(present == absent)
        let hooked = try await fingerprint(at: "https://popups.example/", table: rules)
        let unhooked = try await fingerprint(at: "https://popups.example/", table: nil)
        #expect(hooked["open"] != unhooked["open"] || hooked["listen"] != unhooked["listen"] || hooked["timeout"] != unhooked["timeout"],
                "the look can't tell a wrapped function from the page's own")
    }

    // MARK: - Chromium's copy

    @Test func chromiumCarriesWhereShieldIsOff() async throws {
        do {
            let restore = use(table("popups.example##+js(aopr, aclib)"))
            defer { restore() }
            let opened = tab()
            defer { opened.close() }
            let wasPaused = Shield.shared.isPaused(on: "paused.test")
            Shield.shared.pause("paused.test", true)
            defer { Shield.shared.pause("paused.test", wasPaused) }
            let policy = try #require(ShieldScriptlets.chromiumPolicy(for: opened.tab, host: "popups.example"))
            #expect(policy.off.contains("paused.test"))
            #expect(ShieldScriptlets.chromiumPolicy(for: opened.tab, host: "localhost")?.off.contains("localhost") == true)
            let registration = try #require(ShieldScriptlets.chromium(policy))
            #expect(registration.world == .page && !registration.atEnd && !registration.mainOnly)
            #expect(registration.source.contains(#"var OFF = {"enabled":true,"off":["#))
            #expect(!registration.source.contains("__YAB_"))
            // The same policy, the same text: comparing registrations stays cheap.
            #expect(ShieldScriptlets.chromium(policy)?.source == registration.source)
        }
    }

    @Test func theLibraryIsServedCompacted() {
        let source = ShieldScriptlets.source("{\"v\":2,\"calls\":\"\",\"hosts\":\" \"}", off: "null")
        #expect(!source.contains("__YAB_"))
        #expect(source.contains(#"{"v":2,"calls":"","hosts":" "}"#))
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && !$0.hasPrefix("//") })
    }

    @Test func theLogSaysWhyRulesWereLeftOut() {
        let line = ShieldScriptlets.droppedSummary(["regex": 3, "entity-domain": 9, "scriptlet-unsupported": 9, "badfilter": 1], top: 3)
        #expect(line == "dropped 22: entity-domain 9, scriptlet-unsupported 9, regex 3")
        #expect(ShieldScriptlets.droppedSummary([:]) == "dropped 0")
    }
}

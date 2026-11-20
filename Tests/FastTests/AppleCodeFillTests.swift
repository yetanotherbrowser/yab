import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct AppleCodeFillTests {
    private func waitForKeyWindow(_ window: NSWindow) async throws {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if NSApp.isActive, window.isKeyWindow { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NSApp.isActive)
        try #require(window.isKeyWindow)
    }

    private func makeKeyWindow(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitForKeyWindow(window)
    }

    @MainActor
    private struct Fixture {
        let browser: Browser
        let tab: Tab
        let window: NSWindow
        let host: PageSuggestionsHost
        let spot: CGRect
        let windowID: UUID

        func close() {
            window.orderOut(nil)
            browser.letGo(outside: tab)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
    }

    private func fixture() async throws -> Fixture {
        try #require(NSApp.isRunning)
        let id = UUID(), browser = Browser(windowID: id)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(bench: true, configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://autofill.test/")!)
        browser.outside.append(tab)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let holder = PageHolder(tab: tab)
        holder.frame = NSRect(x: 19, y: 23, width: 580, height: 420)
        content.addSubview(holder)
        let host = PageSuggestionsHost(browser: browser, tab: tab)
        host.frame = holder.frame
        content.addSubview(host)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 620, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        let spot = CGRect(x: 35, y: 41, width: 280, height: 36)
        let codes = [
            SentCode(id: "fixture-first", code: "135790", from: "Autofill fixture", at: nil, source: .text, mine: true),
            SentCode(id: "fixture-second", code: "246801", from: "Autofill fixture", at: nil, source: .text, mine: true),
        ]
        browser.codeList = Browser.CodeChoices(tab: tab.id, spot: spot, codes: codes,
                                               site: "autofill.test", appleAccount: nil, dark: false)
        let fixture = Fixture(browser: browser, tab: tab, window: window, host: host, spot: spot, windowID: id)
        do {
            try await makeKeyWindow(window)
            try #require(window.makeFirstResponder(tab.page))
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    /// A window whose key status the test sets, so the case runs in plain
    /// `swift test` too, where the process never becomes active.
    private final class KeyStandIn: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    /// #898: Apple's Touch ID sheet is key while it is up, and still is when
    /// the helper's cmd 17 reply comes. The code goes into the field that
    /// was picked from, on the page still shown, not lost for want of key.
    @Test(arguments: [false, true])
    func aCodePickedBeforeTouchIDFillsWhileTheSheetIsKey(sheetIsKey: Bool) async throws {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(bench: true, configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://autofill.test/")!)
        browser.outside.append(tab)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let holder = PageHolder(tab: tab)
        holder.frame = NSRect(x: 19, y: 23, width: 580, height: 420)
        content.addSubview(holder)
        let window = KeyStandIn(contentRect: NSRect(x: -30000, y: 0, width: 620, height: 480),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            browser.letGo(outside: tab)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let web = tab.page
        #expect(window.makeFirstResponder(web))
        web.navigate(html: """
        <!doctype html><title>Authenticator fixture</title>
        <p>Enter your authenticator code.</p><input id="code" autocomplete="one-time-code" maxlength="6">
        """, base: URL(string: "https://autofill.test/"))
        for _ in 0..<200 {
            if (try? await web.fixtureExpression("!!document.getElementById('code')")) as? Bool == true,
               !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await web.fixtureExpression("document.getElementById('code').focus(); true")
        for _ in 0..<200 {
            if tab.fieldCode, tab.fieldIdentity != nil, tab.fieldDocument != nil, tab.waitingCode != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(tab.fieldCode)
        let document = try #require(tab.fieldDocument), field = try #require(tab.fieldIdentity)
        tab.fieldCodeRequest = CodeRequest(source: .key, digits: 6)
        browser.codeWatch.document = document
        browser.codeWatch.field = field
        browser.codeWatch.request = tab.fieldCodeRequest
        let code = SentCode(id: "apple:fixture", code: "", from: "fixture@example.test", at: nil, source: .apple, mine: true)
        browser.codeList = Browser.CodeChoices(tab: tab.id, spot: CGRect(x: 35, y: 41, width: 280, height: 36), codes: [code],
                                               site: "autofill.test", appleAccount: nil, dark: false)
        let task = try #require(browser.pickCode(code, appleCode: { _, _ in
            // Touch ID: the sheet takes key, and the reply comes before it gives it back.
            if sheetIsKey { window.key = false }
            return "246801"
        }))
        await task.value
        var value = ""
        for _ in 0..<100 {
            value = (try? await web.fixtureExpression("document.getElementById('code').value")) as? String ?? ""
            if !value.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(value == "246801")
    }

    @Test(arguments: ["same", "blur", "cancel", "field", "typed", "document", "http", "request", "length"])
    func anAppleCodeWaitsForItsOriginalChallenge(change: String) async throws {
        let f = try await fixture()
        defer { f.close() }
        let web = f.tab.page
        web.navigate(html: """
        <!doctype html><title>Authenticator fixture</title>
        <section><p>Enter your authenticator code.</p><input id="first" autocomplete="one-time-code" maxlength="6"></section>
        <section><p>Enter your authenticator code.</p><input id="second" autocomplete="one-time-code" maxlength="6"></section>
        """, base: URL(string: "https://autofill.test/"))
        for _ in 0..<200 {
            if (try? await web.fixtureExpression("!!document.getElementById('second')")) as? Bool == true,
               !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await web.fixtureExpression("document.getElementById('first').focus(); true")
        for _ in 0..<200 {
            if f.tab.fieldCode, f.tab.fieldIdentity != nil, f.tab.fieldDocument != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(f.tab.fieldCode)
        let document = try #require(f.tab.fieldDocument), field = try #require(f.tab.fieldIdentity)
        f.tab.fieldCodeRequest = CodeRequest(source: .key, digits: 6)
        f.browser.codeWatch.document = document
        f.browser.codeWatch.field = field
        f.browser.codeWatch.request = f.tab.fieldCodeRequest
        let code = SentCode(id: "apple:fixture", code: "", from: "fixture@example.test", at: nil, source: .apple, mine: true)
        f.browser.codeList = Browser.CodeChoices(tab: f.tab.id, spot: f.spot, codes: [code],
                                                site: "autofill.test", appleAccount: nil, dark: false)
        var asked = false
        let task = try #require(f.browser.pickCode(code, appleCode: { page, user in
            asked = true
            #expect(page == "https://autofill.test/")
            #expect(user == "fixture@example.test")
            // The helper suspends for authentication while the page can change.
            await Task.yield()
            switch change {
            case "blur":
                _ = try? await web.fixtureExpression("document.getElementById('first').blur(); true")
                for _ in 0..<200 {
                    if !f.tab.typing { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(!f.tab.typing)
                #expect(!f.tab.fieldCode)
            case "typed":
                _ = try? await web.fixtureExpression("document.getElementById('first').value = '9'; true")
            case "field":
                _ = try? await web.fixtureExpression("document.getElementById('second').focus(); true")
                for _ in 0..<200 {
                    if f.tab.fieldIdentity != field { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(f.tab.fieldIdentity != field)
            case "document": f.tab.fieldDocument = document + "-next"
            case "http": f.tab.setAddressOptimistically(URL(string: "http://autofill.test/")!)
            case "request": f.tab.fieldCodeRequest = CodeRequest(source: .text, digits: 6)
            default: break
            }
            return change == "cancel" ? nil : change == "length" ? "1234" : "246801"
        }))
        await task.value
        #expect(asked)
        var filled = false
        for _ in 0..<100 {
            filled = (try? await web.fixtureExpression("Array.from(document.querySelectorAll('input')).some(n => n.value !== '')")) as? Bool == true
            if filled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(filled == (change == "same" || change == "blur" || change == "typed"))
        if change == "same" || change == "blur" {
            #expect(try await web.fixtureExpression("document.getElementById('first').value") as? String == "246801")
            #expect(try await web.fixtureExpression("document.getElementById('second').value") as? String == "")
        }
        if change == "typed" {
            #expect(try await web.fixtureExpression("document.getElementById('first').value") as? String == "9")
            #expect(try await web.fixtureExpression("document.getElementById('second').value") as? String == "")
        }
    }

}

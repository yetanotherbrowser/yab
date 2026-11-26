import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct NavigationHoldTests {
    // Chromium fires location.reload()'s navigate event at once, before the
    // navigatesuccess of the change just before it; WebKit fires it a task
    // later, after. A stand-in navigation gives the script Chromium's order.
    @Test(arguments: [("replace", true, false), ("push", true, false), ("push", false, true)])
    func aReloadRightAfterAChangeOfURLIsHeldOnlyWhenThePageIsLeaving(_ type: String, _ sameDocument: Bool, _ held: Bool) async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let address = "https://page.example.test/page"
        web.loadHTMLString("<!doctype html><title>Page</title>", baseURL: URL(string: address)!)
        let loaded = try await Loaded.until(30, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("location.href + ' ' + document.readyState")) as? String == address + " complete"
        }
        try #require(loaded)
        try #require(try await web.evaluateJavaScript("typeof NavigateEvent === 'function'") as? Bool == true)
        _ = try await web.evaluateJavaScript("""
        window.stand = new EventTarget();
        Object.defineProperty(window, 'navigation', { value: stand });
        window.fire = (type, url, sameDocument) => {
          const e = new Event('navigate', { cancelable: true });
          Object.assign(e, { navigationType: type, userInitiated: false, hashChange: false, downloadRequest: null, destination: { url, sameDocument } });
          stand.dispatchEvent(e);
          return e.defaultPrevented;
        };
        true;
        """)
        _ = try await web.evaluateJavaScript(PageScript.load("navigation-hold") + "; true")
        let destination = sameDocument ? address + "?marker=1" : "https://elsewhere.example.test/"
        let prevented = try await web.evaluateJavaScript("""
        fire('\(type)', '\(destination)', \(sameDocument));
        \(sameDocument ? "history.replaceState(null, '', '\(destination)');" : "")
        fire('reload', location.href, false);
        """) as? Bool
        #expect(prevented == held)
    }
}

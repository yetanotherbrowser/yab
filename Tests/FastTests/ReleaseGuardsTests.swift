import WebKit
import XCTest
@testable import Fast

// What a shipped yab keeps to itself: the socket's verbs for a caller with
// no agent behind it, what of a crash report leaves the Mac, the presses
// that wait for a yes in any of the languages and on a card's form.

final class ReleaseGuardsTests: XCTestCase {
    // MARK: - the socket

    func testWithoutASessionOnlyTasksAndASessionAreAnswered() {
        for verb in ["agent-attach", "agent-caps", "agents", "agent-run", "agent-wait", "agent-stop", "agent-reply", "agent-routines", "agent-memory-search"] {
            XCTAssertTrue(Bench.allowed(verb, session: false, open: false), verb)
        }
        for verb in ["eval", "snapshot", "text", "shot", "open", "act", "agent-eval", "agent-tabs", "agent-autofill", "tabs", "cookies", "wallet", "fill"] {
            XCTAssertFalse(Bench.allowed(verb, session: false, open: false), verb)
        }
    }

    func testWithASessionOnlyAnAgentsVerbs() {
        for verb in ["snapshot", "text", "shot", "open", "close", "act", "press", "nav", "wait", "spaces", "agent-eval", "agent-tabs", "agent-go"] {
            XCTAssertTrue(Bench.allowed(verb, session: true, open: false), verb)
        }
        // The bench's own: page-world scripts, the wallet, keys, settings.
        // Nor test driving, though it starts with agent-.
        for verb in ["eval", "tabs", "wallet", "forms", "key", "settings", "box", "newtab", "flood", "", "agent-mail-space"] {
            XCTAssertFalse(Bench.allowed(verb, session: true, open: false), verb)
        }
    }

    func testATestRunAnswersEverything() {
        XCTAssertTrue(Bench.allowed("eval", session: false, open: true))
        XCTAssertTrue(Bench.allowed("wallet", session: false, open: true))
        XCTAssertTrue(Bench.allowed("agent-mail-space", session: true, open: true))
    }

    // MARK: - crash reports

    func testACrashReportLeavesOnlyWhatFindsTheCrash() throws {
        let home = "/Users/someone"
        let head = #"{"app_name":"yab","bundleID":"com.yab.app","app_version":"1.0"}"#
        let body: [String: Any] = [
            "procPath": "\(home)/Applications/yab.app/Contents/MacOS/yab",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": 0,
            "threads": [["id": 1, "triggered": true, "frames": [["imageOffset": 42, "imageIndex": 0]],
                         "threadState": ["x": [["value": 12345]]]]],
            "usedImages": [["name": "yab", "path": "\(home)/Applications/yab.app/Contents/MacOS/yab"]],
            "asi": ["libswiftCore.dylib": ["Fatal error: https://bank.example/account?token=secret"]],
            "vmSummary": "mapped file \(home)/Documents/taxes.pdf",
            "crashReporterKey": "device-key",
            "sleepWakeUUID": "wake",
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let report = head + "\n" + json
        guard case let .send(prepared) = Crashes.prepared(report, home: home, bytes: report.utf8.count, age: 60) else {
            return XCTFail("not sent")
        }
        XCTAssertNil(prepared.parse)
        let sent = prepared.text

        let lines = sent.split(separator: "\n", maxSplits: 1)
        XCTAssertEqual(String(lines[0]), head)
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(Set(kept.keys), ["procPath", "exception", "faultingThread", "threads", "usedImages", "asi"])
        XCTAssertEqual(kept["procPath"] as? String, "~/Applications/yab.app/Contents/MacOS/yab")
        // Why it crashed goes, cleaned.
        XCTAssertEqual(kept["asi"] as? [String: [String]], ["libswiftCore.dylib": ["Fatal error: <url>"]])
        let thread = try XCTUnwrap((kept["threads"] as? [[String: Any]])?.first)
        XCTAssertNil(thread["threadState"])
        XCTAssertNotNil(thread["frames"])
        for secret in ["someone", "bank.example", "taxes.pdf", "device-key", "wake"] {
            XCTAssertFalse(sent.contains(secret), secret)
        }
    }

    /// An exception AppKit caught in a view's layout ends the run in
    /// +[NSApplication _crashOnException:], whose frames name nothing of
    /// Yab's; where it was thrown is only in asiBacktraces, which goes with
    /// its frames' addresses and the rest cleaned (crash #50).
    func testACrashReportKeepsWhereACaughtExceptionWasThrown() throws {
        let home = "/Users/someone"
        let head = #"{"app_name":"yab","app_version":"0.35.5","build_version":"202610221716"}"#
        let trace = """
        0   CoreFoundation                      0x0000000181e8e8c0 __exceptionPreprocess + 176
        1   libobjc.A.dylib                     0x00000001818ec60c objc_exception_throw + 88
        3   WebKit                              0x00000001af8b481c -[WKUserContentController _addScriptMessageHandler:] + 160
        5   yab                                 0x000000010116aa6c Fast_main + 11795492
        reason: \(home)/Library/x at https://bank.example/?token=secret
        """
        let body: [String: Any] = [
            "exception": ["type": "EXC_BAD_INSTRUCTION", "signal": "SIGILL"],
            "threads": [["id": 1, "triggered": true, "frames": [["imageOffset": 9127028, "imageIndex": 9]]]],
            "asiBacktraces": [trace],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let report = head + "\n" + json
        guard case let .send(prepared) = Crashes.prepared(report, home: home, bytes: report.utf8.count, age: 60) else {
            return XCTFail("not sent")
        }
        let lines = prepared.text.split(separator: "\n", maxSplits: 1)
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let sent = try XCTUnwrap((kept["asiBacktraces"] as? [String])?.first)
        XCTAssertTrue(sent.contains("5   yab                                 0x000000010116aa6c Fast_main + 11795492"))
        XCTAssertTrue(sent.contains("0x00000001af8b481c -[WKUserContentController _addScriptMessageHandler:] + 160"))
        XCTAssertTrue(sent.hasSuffix("reason: ~/Library/x at <url>"))
        for secret in ["someone", "bank.example"] { XCTAssertFalse(prepared.text.contains(secret), secret) }
    }

    /// A body that isn't JSON goes raw, saying so, never the first line
    /// alone, and still without what stays on this Mac.
    func testABodyThatIsntJSONGoesRawAndScrubbed() throws {
        let head = #"{"app_name":"yab"}"#
        let body = """
        Process: yab at /Users/someone/x
        {"asi" : {"libswiftCore.dylib" : ["Fatal error: https://bank.example/?token=secret"]}, "crashReporterKey" : "device-key",
          "threads" : [{"frames" : [1], "threadState" : {"x" : [{"value" : 12345}]}}], "vmSummary" : "mapped \\/Users\\/someone\\/taxes.pdf"}
        """
        let report = head + "\n" + body
        guard case let .send(prepared) = Crashes.prepared(report, home: "/Users/someone", bytes: report.utf8.count, age: 60) else {
            return XCTFail("not sent")
        }
        XCTAssertTrue(prepared.text.hasPrefix(head + "\nProcess: yab at ~/x"))
        XCTAssertTrue(try XCTUnwrap(prepared.parse).hasPrefix("raw"))
        XCTAssertEqual(prepared.bytes, report.utf8.count)
        XCTAssertTrue(prepared.text.contains(#""frames" : [1]"#))
        XCTAssertTrue(prepared.text.contains(#""asi" : {"libswiftCore.dylib" : ["Fatal error: <url>"]}"#))
        for secret in ["someone", "bank.example", "taxes.pdf", "device-key", "12345"] {
            XCTAssertFalse(prepared.text.contains(secret), secret)
        }
    }

    /// macOS 27.2 can follow the body with a plain-text "System Profile:"
    /// appendix. The JSON before it is trimmed as any report's is, the
    /// appendix stays on the Mac, and the body that goes is one document
    /// the site can read (#758, #978, #1134, #1455, #1545 went raw).
    func testAReportWithASystemProfileAfterItsBodyIsTrimmed() throws {
        let home = "/Users/someone"
        let head = #"{"app_name":"yab","app_version":"0.46.5","build_version":"202611022048"}"#
        let body: [String: Any] = [
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGKILL"],
            "faultingThread": 0,
            "threads": [["id": 1, "triggered": true, "frames": [["imageOffset": 42, "imageIndex": 0]]]],
            "usedImages": [["name": "yab"]],
            "vmSummary": "mapped file \(home)/Documents/taxes.pdf",
            "note": "a } and a { in a string",
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]), as: UTF8.self)
        let appendix = """

        System Profile:
        Network Service: Wi-Fi, AirPort, en0
        Model: Mac15,12, BootROM 20457.41.3, proc 8:0:4:4 processors, 16 GB, SMC
        Bluetooth: Version (null), 0 services, 0 devices, 0 incoming serial ports

        """
        let report = head + "\n" + json + appendix
        guard case let .send(prepared) = Crashes.prepared(report, home: home, bytes: report.utf8.count, age: 60) else {
            return XCTFail("not sent")
        }
        XCTAssertNil(prepared.parse)
        let lines = prepared.text.split(separator: "\n", maxSplits: 1)
        XCTAssertEqual(String(lines[0]), head)
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual((kept["exception"] as? [String: Any])?["type"] as? String, "EXC_BREAKPOINT")
        XCTAssertNil(kept["vmSummary"])
        for secret in ["System Profile", "Mac15,12", "taxes.pdf", "someone"] {
            XCTAssertFalse(prepared.text.contains(secret), secret)
        }
        // A body cut short is still left whole, to wait or go raw.
        XCTAssertEqual(Crashes.document("{\"a\": [1, 2"), "{\"a\": [1, 2")
        XCTAssertEqual(Crashes.document("Process: yab\n{}"), "Process: yab\n{}")
        XCTAssertEqual(Crashes.document("  {\"a\": \"}\"}\nSystem Profile:"), "  {\"a\": \"}\"}")
    }

    /// The first line alone never goes: a report with no body waits, and
    /// after a day is left behind.
    func testAReportWithoutABodyIsNeverSent() {
        let head = #"{"app_name":"yab","bundleID":"com.yab.app","bug_type":"309"}"#
        for report in [head, head + "\n", head + "\n  \n"] {
            XCTAssertEqual(Crashes.prepared(report, home: "/Users/someone", bytes: 390, age: 60), .wait)
            XCTAssertEqual(Crashes.prepared(report, home: "/Users/someone", bytes: 390, age: Crashes.patience + 1), .skip)
        }
    }

    private let crashHead = #"{"app_name":"yab","bundleID":"com.yab.app","bug_type":"309"}"#

    private func crashBody(name: String) throws -> String {
        let body: [String: Any] = [
            "procName": "yab",
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
            "threads": [["id": 1, "triggered": true, "name": name, "frames": [["imageOffset": 42, "imageIndex": 0]]]],
            "vmSummary": "mapped file",
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]), as: UTF8.self)
    }

    /// A report written `age` seconds ago in a folder of its own.
    private func reportFile(_ text: String, age: TimeInterval) throws -> (URL, Date) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("yab-2026-10-03-101621.ips")
        try Data(text.utf8).write(to: file)
        let written = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - age).rounded())
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        return (file, written)
    }

    func testATruncatedReportIsntSentAndDoesntMoveSince() async throws {
        let body = try crashBody(name: "main")
        let since = Date(timeIntervalSinceNow: -3600)
        for share in [0.05, 0.5, 0.95] {
            let cut = String(body.prefix(Int(Double(body.count) * share)))
            let (file, written) = try reportFile(crashHead + "\n" + cut, age: 60)
            var posted: [Crashes.Report] = []
            let moved = await Crashes.send([(file, written)], after: since, home: "/Users/someone",
                                           settle: .zero) { posted.append($0); return true }
            XCTAssertTrue(posted.isEmpty, "\(share)")
            XCTAssertEqual(moved, since, "\(share)")
        }
    }

    func testAReportStillBeingWrittenWaits() async throws {
        let (file, written) = try reportFile(crashHead + "\n" + (try crashBody(name: "main")), age: 1)
        let since = Date(timeIntervalSinceNow: -3600)
        var posted = 0
        let moved = await Crashes.send([(file, written)], after: since, home: "/Users/someone", settle: .zero) { _ in
            posted += 1
            return true
        }
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(moved, since)
    }

    func testAReportWithALoneSurrogateIsSentWithItsBody() async throws {
        // A thread name cut in the middle of 😀 and a raw tab, which
        // JSONSerialization turns down.
        let body = try crashBody(name: "PLACEHOLDER").replacingOccurrences(of: "PLACEHOLDER", with: "cut \\ud83d\there")
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(body.utf8)))
        let (file, written) = try reportFile(crashHead + "\n" + body, age: 60)
        let since = Date(timeIntervalSinceNow: -3600)
        var posted: [Crashes.Report] = []
        let moved = await Crashes.send([(file, written)], after: since, home: "/Users/someone", settle: .zero) {
            posted.append($0)
            return true
        }
        XCTAssertEqual(moved, written)
        let report = try XCTUnwrap(posted.first)
        XCTAssertEqual(report.parse, "mended")
        let lines = report.text.split(separator: "\n", maxSplits: 1)
        XCTAssertEqual(String(lines[0]), crashHead)
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let thread = try XCTUnwrap((kept["threads"] as? [[String: Any]])?.first)
        XCTAssertEqual(thread["name"] as? String, "cut \u{FFFD}\there")
        XCTAssertNil(kept["vmSummary"])
    }

    func testASiteThatDoesntTakeItDoesntMoveSince() async throws {
        let (file, written) = try reportFile(crashHead + "\n" + (try crashBody(name: "main")), age: 60)
        let since = Date(timeIntervalSinceNow: -3600)
        let moved = await Crashes.send([(file, written)], after: since, home: "/Users/someone", settle: .zero) { _ in false }
        XCTAssertEqual(moved, since)
    }

    // MARK: - paying

    /// The limit an agent pays under without asking is in US dollars. Other
    /// dollars and pesos aren't US dollars, and a decimal comma is read as
    /// one: R$ 1.234,56, about 220 US dollars, counted as $1.23.
    func testOnlyUSDollarsCountTowardTheLimitAsWritten() {
        XCTAssertEqual(AgentRules.dollars("$42.10"), 42.10)
        XCTAssertEqual(AgentRules.dollars("US$42.10"), 42.10)
        XCTAssertEqual(AgentRules.dollars("$1,234.56"), 1234.56)
        XCTAssertEqual(AgentRules.dollars("$1.234,56"), 1234.56)
        for amount in ["R$1.234,56", "HK$780.00", "MX$1,000.00", "Mex$19.99", "CAD$5.00", "AR$19.99", "A$50.00", "CA$20", "€1.299,00", "$"] {
            XCTAssertNil(AgentRules.dollars(amount), amount)
        }
    }

    func testPaymentsInOtherLanguagesAreNeverExceptions() {
        for label in ["Pay now", "Jetzt kaufen", "Zahlungspflichtig bestellen", "Payer", "Comprar", "Acquista"] {
            XCTAssertTrue(AgentRules.paying(label), label)
        }
        for label in ["Payment details", "Send", "Continue", "Pagina successiva", "Commentaires"] {
            XCTAssertFalse(AgentRules.paying(label), label)
        }
    }

    /// Register 1762: an Airtable table called Purchase orders brought the
    /// pay sheet up for every press near it; a purchase still pays.
    func testAPurchaseOrderIsARecordNotAPayment() {
        for label in ["Purchase orders", "Purchase order", "Purchase Requisitions", "Purchase history", "purchase invoice"] {
            XCTAssertFalse(AgentRules.paying(label), label)
        }
        for label in ["Purchase", "Purchase now", "Purchase tickets", "Purchase subscription", "Buy now", "Place order"] {
            XCTAssertTrue(AgentRules.paying(label), label)
        }
    }

    func testACardFormsPressIsNeverAnException() {
        let permit = AgentPermit(kind: .press(label: "Continue", ref: "e1"), session: "s", detail: "", pays: true)
        XCTAssertNil(permit.ruleLabel)
        XCTAssertEqual(AgentPermit(kind: .press(label: "Continue", ref: "e1"), session: "s", detail: "").ruleLabel, "Continue")
    }
}

// The same weighing an agent's click gets (AgentPage.weigh), in a real page.
@MainActor
final class CommitWordsTests: XCTestCase {
    private let page = """
    <title>Checkout</title>
    <form id="it"><button id="it-send">Invia</button><button type="button" id="it-sent">Inviato</button></form>
    <form id="de"><button id="de-buy">Jetzt kaufen</button></form>
    <form id="fr"><button id="fr-delete">Supprimer</button></form>
    <form id="card">
      <input autocomplete="cc-number" id="number">
      <button id="card-go">Continue</button>
      <button type="button" id="card-back">Back</button>
    </form>
    <form id="address"><input autocomplete="street-address"><button id="address-go">Continue</button></form>
    """

    private var web: WKWebView!

    override func setUp() async throws {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString(page, baseURL: URL(string: "https://shop.example.test/"))
        for _ in 0..<100 {
            if try await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#address')") as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func weigh(_ id: String, _ action: String = "click") async throws -> [String: Any]? {
        let at = try await web.evaluateJavaScript("(() => { const r = document.querySelector('#\(id)').getBoundingClientRect(); return { x: r.x + 4, y: r.y + 4 }; })()") as? [String: Any]
        return try await web.callAsyncJavaScript(AgentPage.weigh, arguments: ["action": action, "ref": "", "approved": false, "at": at ?? [:]],
                                                 in: nil, contentWorld: AgentPage.world) as? [String: Any]
    }

    func testOtherLanguagesLastStepsAsk() async throws {
        let send = try await weigh("it-send")
        XCTAssertEqual(send?["commit"] as? String, "Invia")
        let buy = try await weigh("de-buy")
        XCTAssertEqual(buy?["commit"] as? String, "Jetzt kaufen")
        let delete = try await weigh("fr-delete")
        XCTAssertEqual(delete?["commit"] as? String, "Supprimer")
        let sent = try await weigh("it-sent")
        XCTAssertNil(sent?["commit"])
    }

    func testWhatSendsACardPays() async throws {
        let go = try await weigh("card-go")
        XCTAssertEqual(go?["commit"] as? String, "Continue")
        XCTAssertEqual(go?["pays"] as? Bool, true)
        let enter = try await weigh("number", "key")
        XCTAssertEqual(enter?["commit"] as? String, "Continue")
        let back = try await weigh("card-back")
        XCTAssertNil(back?["commit"])
        let address = try await weigh("address-go")
        XCTAssertNil(address?["commit"])
    }
}

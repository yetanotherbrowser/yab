import WebKit
import XCTest
@testable import Fast

// An agent's own script (eval) under the guard: a press that sends, pays or
// deletes, however the script makes it, is held until yab says, and every
// other press goes through. In a real page, with WebKit.

@MainActor
final class AgentHoldTests: XCTestCase {
    private let page = """
    <title>Compose</title>
    <form id="mail" onsubmit="event.preventDefault(); window.sent = (window.sent || 0) + 1">
      <textarea id="body">Hi Bob</textarea>
      <button type="button" id="options" onclick="window.tuned = 1">Sending options</button>
      <button id="send">Send</button>
    </form>
    <div id="chat">
      <div contenteditable="true" id="line" onkeydown="if (event.key === 'Enter') window.talked = 1">Hey</div>
      <div role="button" id="post" onclick="window.talked = 2"><span id="inner">Send</span></div>
    </div>
    <form id="ten" onsubmit="event.preventDefault(); window.tenPaid = 1"><button id="pay-ten">Pay<span>$10</span></button></form>
    <form id="cad" onsubmit="event.preventDefault()"><p>Total CAD$5.00</p><button>Pay now</button></form>
    <form id="ars" onsubmit="event.preventDefault()"><p>Total AR$19.99</p><button>Pay now</button></form>
    <form id="mex" onsubmit="event.preventDefault()"><p>Order total Mex$19.99</p><button>Pay now</button></form>
    <form id="usd" onsubmit="event.preventDefault()"><p>Total<b>$12.00</b></p><button>Pay now</button></form>
    <form id="tax" onsubmit="event.preventDefault()"><div>$150.00 order total</div><div>Includes $5.00 tax</div><button>Pay now</button></form>
    <form id="under" onsubmit="event.preventDefault()"><p>Order total</p><p>$9.00</p><button>Pay now</button></form>
    <form id="vague" onsubmit="event.preventDefault()"><p>Order total</p><p>Includes $5.00 tax</p><button>Pay now</button></form>
    <form id="loja" onsubmit="event.preventDefault(); window.pago = 1">
      <p>Total R$ 1.234,56</p>
      <button id="pagar">Pay now</button>
    </form>
    <form id="shop" onsubmit="event.preventDefault(); window.paid = 1">
      <p>Order total $42.10</p>
      <button id="pay">Pay now</button>
    </form>
    <label id="trash-label" for="trash">Bin</label><button id="trash" onclick="window.gone = 1">Delete forever</button>
    <iframe srcdoc="<button id=x onclick='parent.framed = 1'>Send</button><button id=y>Donate</button>"></iframe>
    """

    private var web: PageView!

    override func setUp() async throws {
        web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString(page, baseURL: URL(string: "https://mail.example.test/"))
        for _ in 0..<100 {
            let ready = try? await web.evaluateJavaScript("document.readyState === 'complete' && !!frames[0] && frames[0].document.readyState === 'complete'")
            if ready as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Runs the agent's script under the guard, then says what is held.
    private func agent(_ js: String, on: Bool = true) async throws -> [String: Any]? {
        let armed = await withCheckedContinuation { go in AgentPage.arm(web, on: on) { go.resume(returning: $0) } }
        XCTAssertTrue(armed)
        _ = try? await web.evaluateJavaScript(js + "; true", in: nil, contentWorld: AgentPage.evalWorld)
        return await control("take") as? [String: Any]
    }

    private func control(_ command: String) async -> Any? {
        await withCheckedContinuation { go in AgentPage.held(web, command) { go.resume(returning: $0) } }
    }

    /// What the page itself saw, in its own world.
    private func page(_ name: String) async throws -> Int {
        (try await web.evaluateJavaScript("window.\(name) || 0") as? Int) ?? 0
    }

    private func saw(_ name: String, _ count: Int, line: UInt = #line) async throws {
        let seen = try await page(name)
        XCTAssertEqual(seen, count, name, line: line)
    }

    private func settle(_ how: String) async throws -> Bool {
        await control(how) as? Bool == true
    }

    func testCoordinateApprovalLabelDoesNotHideForeignFrame() async throws {
        _ = try await web.evaluateJavaScript("""
        const frame = document.createElement('iframe');
        frame.id = 'opaque'; frame.sandbox = '';
        frame.srcdoc = '<button>Send</button>';
        frame.style = 'position:fixed;left:0;top:0;width:300px;height:150px;border:0;z-index:9999';
        document.body.appendChild(frame); true;
        """)
        var ready = false
        for _ in 0..<50 {
            if (try? await web.evaluateJavaScript("document.elementFromPoint(70,75)?.id === 'opaque' && document.getElementById('opaque').contentDocument === null")) as? Bool == true {
                ready = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ready, "The synthetic sandbox must have its opaque document before weighing")
        guard ready else { return }
        let result = try await web.callAsyncJavaScript(AgentPage.weigh,
            arguments: ["action": "click", "ref": "@70,75", "approved": false,
                        "frames": true, "at": ["x": 70, "y": 75]],
            in: nil, contentWorld: AgentPage.world) as? [String: Any]
        XCTAssertEqual(result?["frame"] as? Bool, true)
        XCTAssertNil(result?["commit"])
    }

    func testCoordinateSendInsideOpenShadowRootIsWeighed() async throws {
        _ = try await web.evaluateJavaScript("""
        const host = document.createElement('div');
        host.style = 'position:fixed;left:0;top:0;width:300px;height:150px;z-index:9999';
        host.attachShadow({mode:'open'}).innerHTML = '<button style="position:absolute;left:0;top:0;width:200px;height:100px">Send</button>';
        document.body.appendChild(host); true;
        """)
        let result = try await web.callAsyncJavaScript(AgentPage.weigh,
            arguments: ["action": "click", "ref": "@70,75", "approved": false,
                        "frames": true, "at": ["x": 70, "y": 75]],
            in: nil, contentWorld: AgentPage.world) as? [String: Any]
        XCTAssertEqual(result?["commit"] as? String, "Send")
    }

    func testClickOnSendIsHeldUntilPerformed() async throws {
        let held = try await agent("document.querySelector('#send').click()")
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("sent", 0)
        let made = try await settle("perform")
        XCTAssertTrue(made)
        try await saw("sent", 1)
    }

    func testDroppedPressIsNeverMade() async throws {
        _ = try await agent("document.querySelector('#send').click()")
        _ = try await settle("drop")
        try await saw("sent", 0)
    }

    func testOtherButtonsGoThrough() async throws {
        let held = try await agent("document.querySelector('#options').click()")
        XCTAssertNil(held)
        try await saw("tuned", 1)
    }

    func testEventsOnAButtonsInsideAreHeldInOrder() async throws {
        let held = try await agent("""
        const s = document.querySelector('#inner');
        for (const t of ['mousedown', 'mouseup', 'click']) s.dispatchEvent(new MouseEvent(t, { bubbles: true }));
        """)
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("talked", 0)
        _ = try await settle("perform")
        try await saw("talked", 2)
    }

    func testEnterInAComposerIsHeld() async throws {
        let held = try await agent("document.querySelector('#line').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))")
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("talked", 0)
    }

    func testFormsSentBySubmitAreHeldWithTheAmount() async throws {
        let held = try await agent("document.querySelector('#shop').requestSubmit()")
        XCTAssertEqual(held?["commit"] as? String, "Pay now")
        XCTAssertEqual(held?["amount"] as? String, "$42.10")
        try await saw("paid", 0)
        _ = try await settle("drop")
        let again = try await agent("document.querySelector('#mail').dispatchEvent(new Event('submit', { cancelable: true }))")
        XCTAssertEqual(again?["commit"] as? String, "Send")
        try await saw("sent", 0)
    }

    /// The amount is held as the page writes it, with its currency's
    /// letters and its decimal comma: "R$ 1.234,56" was held as "$1.23".
    func testAnAmountIsHeldWholeWithItsCurrency() async throws {
        let held = try await agent("document.querySelector('#loja').requestSubmit()")
        XCTAssertEqual(held?["commit"] as? String, "Pay now")
        XCTAssertEqual(held?["amount"] as? String, "R$1.234,56")
        try await saw("pago", 0)
    }

    /// The button's own word beside the sign is no currency: "Pay" and
    /// "$10" drawn apart read "Pay$10", and the amount is "$10".
    /// From the page to the decision: an agent pays without asking only an
    /// amount in US dollars under the limit. A currency the script doesn't
    /// know keeps its letters (CAD$5.00 was $5.00) and asks, and the word of
    /// a button or a total drawn against the sign is no currency. A total
    /// written before its label is the total, not the tax on the next line
    /// ($150.00 order total was $5.00), and a line that is more than the
    /// amount is no total: it asks.
    func testOnlyUSDollarsUnderTheLimitArePaidWithoutAsking() async throws {
        let rules = AgentRules.shared
        let limit = rules.payLimit
        rules.payLimit = 20
        defer { rules.payLimit = limit }
        let cases: [(form: String, amount: String, pays: Bool)] = [
            ("ten", "$10", true), ("usd", "$12.00", true), ("under", "$9.00", true), ("shop", "$42.10", false),
            ("tax", "$150.00", false), ("vague", "", false),
            ("cad", "CAD$5.00", false), ("ars", "AR$19.99", false), ("mex", "Mex$19.99", false), ("loja", "R$1.234,56", false),
        ]
        for (form, amount, pays) in cases {
            let held = try await agent("document.querySelector('#\(form)').requestSubmit()")
            let said = held?["amount"] as? String ?? ""
            XCTAssertEqual(said, amount, form)
            XCTAssertEqual(rules.mayPay(said), pays, form)
            _ = try await settle("drop")
        }
    }

    func testAButtonsWordBesideTheSignIsNoCurrency() async throws {
        let held = try await agent("document.querySelector('#ten').requestSubmit()")
        XCTAssertEqual(held?["amount"] as? String, "$10")
        try await saw("tenPaid", 0)
    }

    func testALabelsClickIsItsControls() async throws {
        let held = try await agent("document.querySelector('#trash-label').click()")
        XCTAssertEqual(held?["commit"] as? String, "Delete forever")
        try await saw("gone", 0)
    }

    func testAnotherFramesClickIsGuardedToo() async throws {
        let held = try await agent("""
        const w = document.querySelector('iframe').contentWindow;
        w.HTMLElement.prototype.click.call(document.querySelector('#send'));
        """)
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("sent", 0)
        _ = try await settle("drop")
        let inside = try await agent("frames[0].document.querySelector('#x').click()")
        XCTAssertEqual(inside?["commit"] as? String, "Send")
        try await saw("framed", 0)
    }

    /// The agent's click is weighed with the same words: Send asks,
    /// Sending options doesn't.
    func testWeighSharesTheWords() async throws {
        func weigh(_ id: String, _ action: String = "click") async throws -> [String: Any]? {
            let at = try await web.evaluateJavaScript("(() => { const r = document.querySelector('#\(id)').getBoundingClientRect(); return { x: r.x + 4, y: r.y + 4 }; })()") as? [String: Any]
            return try await web.callAsyncJavaScript(AgentPage.weigh, arguments: ["action": action, "ref": "", "approved": false, "at": at ?? [:]],
                                                     in: nil, contentWorld: AgentPage.world) as? [String: Any]
        }
        let send = try await weigh("send")
        XCTAssertEqual(send?["commit"] as? String, "Send")
        let options = try await weigh("options")
        XCTAssertNil(options?["commit"])
        let enter = try await weigh("body", "key")
        XCTAssertEqual(enter?["commit"] as? String, "Send")
    }

    /// Ordinary pages that asked "Delete?" or "Send?" for nothing
    /// (2026-11-14): a docs link, a filter box beside a key's Delete. A
    /// chat box's Enter beside its Send still asks.
    func testLinksAndFilterBoxesDontCommit() async throws {
        _ = try await web.evaluateJavaScript("""
        document.body.insertAdjacentHTML('beforeend', `
          <nav><a id=doclink href="/docs/delete-key">Delete an API key</a><a id=feedback href="/feedback">Send feedback</a></nav>
          <div><input id=filter placeholder="Filter keys"><button id=delkey>Delete</button></div>
          <form id=find onsubmit="event.preventDefault()"><input id=findq><button>Search</button><button type=button>Delete</button></form>
          <div><input id=chatline><button id=chatsend>Send</button></div>`);
        true
        """)
        func weigh(_ id: String, _ action: String) async throws -> [String: Any]? {
            let at = try await web.evaluateJavaScript("(() => { const r = document.querySelector('#\(id)').getBoundingClientRect(); return { x: r.x + 4, y: r.y + 4 }; })()") as? [String: Any]
            return try await web.callAsyncJavaScript(AgentPage.weigh, arguments: ["action": action, "ref": "", "approved": false, "at": at ?? [:]],
                                                     in: nil, contentWorld: AgentPage.world) as? [String: Any]
        }
        for (id, action) in [("doclink", "click"), ("feedback", "click"), ("filter", "key"), ("findq", "key")] {
            let got = try await weigh(id, action)
            XCTAssertNil(got?["commit"], id)
        }
        let chat = try await weigh("chatline", "key")
        XCTAssertEqual(chat?["commit"] as? String, "Send")
        let delete = try await weigh("delkey", "click")
        XCTAssertEqual(delete?["commit"] as? String, "Delete")
    }

    func testTransferAndWithdrawAreNotPayments() {
        for label in ["Transfer", "Transfer ownership", "Withdraw invitation", "Withdraw"] {
            XCTAssertFalse(AgentRules.paying(label), label)
        }
        for label in ["Transfer money", "Withdraw funds", "Confirm transfer", "Send money"] {
            XCTAssertTrue(AgentRules.paying(label), label)
        }
    }

    // The script can't reach the guard's controls or undo it.

    func testTheScriptCantTurnTheGuardOffOrEmptyIt() async throws {
        let held = try await agent("""
        try { __yabHold.on = false; } catch (e) {}
        try { globalThis.__yabHold = null; } catch (e) {}
        try { __yabHold('', 'arm', false); __yabHold(undefined, 'drop'); } catch (e) {}
        document.querySelector('#send').click();
        try { __yabHold('', 'perform'); __yabHold('', 'drop'); } catch (e) {}
        """)
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("sent", 0)
    }

    func testTheScriptCantReadTheKey() async throws {
        _ = try await agent("true")
        let text = try await web.evaluateJavaScript(
            "String(__yabHold) + [HTMLElement.prototype.click, Node.prototype.appendChild].map(String).join('') + Object.getOwnPropertyNames(globalThis).join(',')",
            in: nil, contentWorld: AgentPage.evalWorld) as? String ?? ""
        let key = AgentPage.holdKeys[ObjectIdentifier(web!)] ?? "none"
        XCTAssertFalse(text.contains(key))
    }

    func testTheScriptCantPutTheOldClickBackOrBlindTheGuard() async throws {
        let held = try await agent("""
        try { HTMLElement.prototype.click = function () {}; } catch (e) {}
        try { delete HTMLElement.prototype.click; } catch (e) {}
        try { Object.defineProperty(HTMLElement.prototype, 'click', { value() {} }); } catch (e) {}
        const b = document.querySelector('#send');
        Object.defineProperty(b, 'innerText', { get() { return 'Sending options'; } });
        Object.defineProperty(b, 'closest', { value() { return null; } });
        b.getAttribute = () => 'Sending options';
        try { String.prototype.trim = () => 'x'; RegExp.prototype.test = () => false; Array.prototype.some = () => false; } catch (e) {}
        b.click();
        """)
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("sent", 0)
    }

    func testAnEventOnTheButtonsTextIsHeld() async throws {
        let held = try await agent("document.querySelector('#inner').firstChild.dispatchEvent(new MouseEvent('click', { bubbles: true }))")
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("talked", 0)
    }

    // A new frame's own click is guarded as the frame is put in.

    func testANewFramesClickReachedByIndexIsGuarded() async throws {
        for insert in ["document.body.appendChild(f)", "document.body.append(f)", "document.body.insertAdjacentElement('beforeend', f)",
                       "document.body.attachShadow ? document.querySelector('#chat').attachShadow({ mode: 'closed' }).appendChild(f) : 0"] {
            _ = await control("drop")
            let held = try await agent("""
            {
              const f = document.createElement('iframe');
              \(insert);
              const w = window[window.length - 1];
              w.HTMLElement.prototype.click.call(document.querySelector('#send'));
            }
            """)
            XCTAssertEqual(held?["commit"] as? String, "Send", insert)
            try await saw("sent", 0)
        }
    }

    func testAFrameWrittenAsHTMLIsGuarded() async throws {
        let held = try await agent("""
        document.querySelector('#chat').insertAdjacentHTML('beforeend', '<iframe></iframe>');
        frames[frames.length - 1].HTMLFormElement.prototype.requestSubmit.call(document.querySelector('#mail'));
        """)
        XCTAssertEqual(held?["commit"] as? String, "Send")
        _ = await control("drop")
        let again = try await agent("""
        const box = document.createElement('div');
        document.body.appendChild(box);
        box.innerHTML = '<iframe></iframe>';
        window[window.length - 1].EventTarget.prototype.dispatchEvent.call(document.querySelector('#pay'), new MouseEvent('click', { bubbles: true }));
        """)
        XCTAssertEqual(again?["commit"] as? String, "Pay now")
        try await saw("sent", 0)
        try await saw("paid", 0)
    }

    func testAFrameThatLoadsAnewIsGuardedAsItLoads() async throws {
        _ = try await agent("""
        const f = document.createElement('iframe');
        f.id = 'late';
        document.body.appendChild(f);
        f.srcdoc = '<p>hi</p>';
        """)
        for _ in 0..<40 {
            let ready = try await web.evaluateJavaScript("document.getElementById('late').contentDocument.body.innerText === 'hi'") as? Bool
            if ready == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let held = try await agent("window[window.length - 1].HTMLElement.prototype.click.call(document.querySelector('#send'))")
        XCTAssertEqual(held?["commit"] as? String, "Send")
        try await saw("sent", 0)
    }

    /// A script that watches a frame load a page anew and uses the new
    /// page's click the moment it is there, before the frame's load event.
    func testAFrameWatchedWhileItLoadsAnew() async throws {
        _ = try await agent("""
        {
          const f = document.createElement('iframe');
          document.body.appendChild(f);
          const n = window.length - 1;
          f.srcdoc = '<p>hi</p>' + '<div>x</div>'.repeat(300000);
          const t = setInterval(() => {
            let w = null;
            try { w = window[n]; if (w.location.href !== 'about:srcdoc') return; } catch (e) { return; }
            clearInterval(t);
            window.raced = true;
            w.HTMLElement.prototype.click.call(document.querySelector('#send'));
          }, 0);
        }
        """)
        var raced = false
        for _ in 0..<200 {
            raced = try await web.evaluateJavaScript("window.raced === true", in: nil, contentWorld: AgentPage.evalWorld) as? Bool == true
            if raced { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let sent = try await page("sent")
        let took = await control("take") as? [String: Any]
        XCTAssertTrue(raced)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(took?["commit"] as? String, "Send")
    }

    /// A key is weighed on what has the focus, into a shadow root and a
    /// frame of the same site, as the keys themselves find it.
    func testAKeyIsWeighedWhereTheFocusIsDeep() async throws {
        func weighKey() async throws -> [String: Any]? {
            try await web.callAsyncJavaScript(AgentPage.weigh, arguments: ["action": "press", "ref": "", "approved": false, "at": NSNull()],
                                              in: nil, contentWorld: AgentPage.world) as? [String: Any]
        }
        _ = try await web.evaluateJavaScript("""
        {
          const host = document.createElement('div');
          document.body.appendChild(host);
          host.attachShadow({ mode: 'open' }).innerHTML = '<button id=deep>Delete forever</button>';
          host.shadowRoot.getElementById('deep').focus();
        }
        true
        """)
        let deep = try await weighKey()
        XCTAssertEqual(deep?["commit"] as? String, "Delete forever")
        _ = try await web.evaluateJavaScript("document.querySelector('iframe').focus(); frames[0].document.getElementById('y').focus(); true")
        let framed = try await weighKey()
        XCTAssertEqual(framed?["commit"] as? String, "Donate")
    }

    func testBypassHoldsNothing() async throws {
        let held = try await agent("document.querySelector('#send').click()", on: false)
        XCTAssertNil(held)
        try await saw("sent", 1)
    }
}

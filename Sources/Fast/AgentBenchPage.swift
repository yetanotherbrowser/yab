import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Pages: reading, acting, moving
// between pages, files in and out, a tab's own script.

extension Bench {
    static let pageVerbs: [String: AgentHandler] = [
        "agent-chromium-input-probe": { $0.handleChromiumAgentProbe($1) },
        "agent-devtools": { $0.handleAgentDevtools($1) },
        "snapshot": { $0.handleSnapshot($1) },
        "settle": { $0.handleSettle($1) },
        "agent-dialog": { $0.handleAgentDialog($1) },
        "act": { $0.handleAct($1) },
        "press": { $0.handlePress($1) },
        "agent-show": { $0.handleAgentShow($1) },
        "agent-go": { $0.handleAgentGo($1) },
        "nav": { $0.handleNav($1) },
        "agent-upload": { $0.handleAgentUpload($1) },
        "agent-download": { $0.handleAgentDownload($1) },
        "agent-downloads": { $0.handleAgentDownloads($1) },
        "agent-pdf": { $0.handleAgentPdf($1) },
        "agent-fetch": { $0.handleAgentFetch($1) },
        "agent-read": { $0.handleAgentRead($1) },
        "agent-act": { $0.handleAgentAct($1) },
        "agent-cookies": { $0.handleAgentCookies($1) },
        "agent-look": { $0.handleAgentLook($1) },
        "agent-tabs": { $0.handleAgentTabs($1) },
        "agent-go-to-tab": { $0.handleAgentGoToTab($1) },
        "agent-browse": { $0.handleAgentBrowse($1) },
        "agent-eval": { $0.handleAgentEval($1) },
        "agent-eval-held": { $0.handleAgentEvalHeld($1) },
    ]

    func handleAgentDevtools(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let tab = find(request, in: browser), !tab.shy else { answer(["error": "No accessible non-private tab"]); return }
        if let session, let known = agents.session(session), !known.state.live { answer(["error": "This task has ended"]); return }
        guard tab.webInspecting || tab.chromiumDev != nil else { answer(["error": "Open Developer Tools for this tab before reading its recorded data"]); return }
        let limit = min(200, max(1, request["limit"] as? Int ?? 100))
        answer(tab.devtoolsRead(request["kind"] as? String ?? "", limit: limit))
        return
    }

    func handleSnapshot(_ c: AgentCall) {
        let verb = c.verb
        let admission = c.agents.session(c.session)?.admission
        let allowed = { admission?.valid ?? true }
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        // A tab of yours not looked at since yab opened, or put to
        // sleep, holds no page yet: it loads now, behind, and is read
        // once it has. An agent's own, once memory running out put it
        // down, too.
        if !tab.bench || tab.asleep, request["woken"] == nil, tab.wake() || tab.hollow {
            if tab.hollow { tab.reload() }
            let limit = Date().addingTimeInterval(12)
            func ready() {
                guard allowed() else { answer(["error": "This task's permission expired."]); return }
                if (!tab.loading && !tab.hollow) || Date() > limit { agentCommand(verb, request.merging(["woken": true]) { $1 }, browser: browser, answer) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ready() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ready() }
            return
        }
        house(tab)
        // The read a tool makes after its own act isn't a step of its own.
        agents.touch(session, "read · \(tab.address?.host ?? tab.title)", step: request["followup"] == nil)
        if tab.agent != nil { AgentFeed.shared.did(tab, .read) }
        let ref = request["ref"] as? String
        guard allowed() else { answer(["error": "This task's permission expired."]); return }
        AgentPage.read(tab, interactive: request["interactive"] as? Bool ?? true, ref: ref, since: request["since"] as? Bool ?? false,
                       takeMemoryNotice: {
                           guard self.find(["id": tab.id.uuidString], in: browser) === tab else { return nil }
                           return StuckWatch.notices.removeValue(forKey: tab.id)
                       }) { got in
            guard allowed() else { answer(["error": "This task's permission expired."]); return }
            var out = got
            if out["error"] == nil { out["loading"] = tab.loading }
            // The first time this task is on a site yab has a skill for.
            if out["error"] == nil, let hint = Skills.hint(for: tab.address, session: session) { out["skill"] = hint }
            // A code the site mailed, surfaced in the snapshot the way it
            // is offered under the field for a person (MailSettings), so a
            // task fills it without a separate mail_code call. The same
            // opt-in and the same site-only reach; never on a protected
            // site. mail_code stays for a code that has yet to arrive.
            if out["error"] == nil, out["needs"] as? String == "a one-time code",
               browser.prefs.mailCodes, !AgentSecrets.protected(tab.address) {
                self.mailedCodes(for: tab) { codes in
                    if !codes.isEmpty { out["codes"] = codes }
                    answer(out)
                }
                return
            }
            // A page asking for a sign-in the user has in another space.
            let offered = out["sso"] as? [String] ?? []
            out["sso"] = nil
            let asking = out["needs"] as? String == "a password" || tab.address.map(SignIns.loginPage) == true || !offered.isEmpty
            guard out["error"] == nil, asking, !tab.shy else { answer(out); return }
            guard let store = tab.webKitStore("WebKit sign-in discovery") else { answer(out); return }
            SignIns.elsewhere(tab.address, from: store, in: browser, allowed: allowed) { line in
                if let line { out["elsewhere"] = line }
                // Or signed in to a way in it offers: Google, GitHub.
                SignIns.ways(offered, store: store, allowed: allowed) { ways in
                    Agents.ways[tab.id] = ways
                    if let ways { out["ways"] = ways }
                    answer(out)
                }
            }
        }
    }

    func handleSettle(_ c: AgentCall) {
        let admission = c.agents.session(c.session)?.admission
        let allowed = { admission?.valid ?? true }
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // After an act: until a load it started has finished and the
        // page has been still a moment. Nothing moving, nothing waited.
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        let started = Date()
        let limit = started.addingTimeInterval(request["seconds"] as? Double ?? 10)
        func still() {
            guard allowed() else { answer(["error": "This task's permission expired."]); return }
            if AgentPage.asked[ObjectIdentifier(tab)] != nil { answer(["ok": true, "dialog": true]); return }
            if tab.loading && Date() < limit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { still() }; return }
            AgentPage.run(tab, AgentPage.quiet) { _ in
                guard allowed() else { answer(["error": "This task's permission expired."]); return }
                // A click's load can start after the page went quiet:
                // one more look.
                if tab.loading && Date() < limit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { still() }; return }
                answer(["ok": true, "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
        }
        // A navigation a click sets going reaches the tab a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { still() }
    }

    func handleAgentDialog(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard let tab = own() else { return }
        let accept = request["accept"] as? Bool ?? true
        if AgentPage.answer(tab, accept: accept, text: request["text"] as? String) {
            agents.touch(session, "answered the page · \(accept ? "OK" : "Cancel")")
            answer(["ok": true])
        } else {
            answer(["error": "the page isn't asking anything"])
        }
    }

    func handleAct(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        func weighed(_ tab: Tab, action: String, ref: String, at: CGPoint? = nil, then go: @escaping () -> Void) {
            c.weighed(tab, action: action, ref: ref, at: at, then: go)
        }
        guard let tab = own() else { return }
        let action = request["action"] as? String ?? "click"
        let ref = request["ref"] as? String ?? ""
        let zoom = tab.page.pageZoom * tab.page.magnification
        if AgentPage.asked[ObjectIdentifier(tab)] != nil {
            answer(["error": AgentPage.asked[ObjectIdentifier(tab)]!.said])
            return
        }
        // You took the page in the meantime: nothing is done.
        func taken() -> Bool {
            if AgentFeed.shared.driving.contains(tab.id) || (browser.activeID == tab.id && AgentFeed.shared.touchedLately(tab)) {
                answer(["error": "the person started using this tab just now, it wasn't done; try again in a few seconds"])
                return true
            }
            return false
        }
        // A click at a point of the screenshot, for what the tree can't
        // name: a canvas, a map, a drawing.
        if action == "click", ref.isEmpty, let px = request["x"] as? Double, let py = request["y"] as? Double {
            guard let at = AgentCoordinates.point(x: px, y: py, size: tab.page.bounds.size, zoom: Double(zoom)) else {
                answer(["error": "That point is outside the screenshot; take a fresh screenshot."]); return
            }
            weighed(tab, action: "click", ref: "@\(Int(px)),\(Int(py))", at: at) {
                agents.touch(session, "click · \(tab.address?.host ?? "")")
                AgentFeed.shared.did(tab, .click)
                let seen = browser.activeID == tab.id && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                AgentFeed.shared.pointed(tab.page, at: CGPoint(x: at.x * zoom, y: at.y * zoom))
                DispatchQueue.main.asyncAfter(deadline: .now() + (seen ? 0.45 : 0)) {
                    if taken() { return }
                    answer(AgentPage.click(tab.page, x: at.x, y: at.y) ? ["done": "mouse"] : ["error": "couldn't click there"])
                }
            }
            return
        }
        // A drag between points of the screenshot, for what the tree can't
        // name: a canvas, a map, a drawing's handle. The same ownership and
        // press checks as coordinate clicks, never outside the viewport.
        if action == "drag", ref.isEmpty {
            guard let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let toX = request["toX"] as? Double, let toY = request["toY"] as? Double,
                  let from = AgentCoordinates.point(x: x, y: y, size: tab.page.bounds.size, zoom: Double(zoom)),
                  let to = AgentCoordinates.point(x: toX, y: toY, size: tab.page.bounds.size, zoom: Double(zoom)) else {
                answer(["error": "drag needs a ref or x, y, toX, toY inside a fresh screenshot."]); return
            }
            weighed(tab, action: "click", ref: "@\(Int(x)),\(Int(y))", at: from) {
                if taken() { return }
                agents.touch(session, "drag · \(tab.address?.host ?? "")")
                AgentFeed.shared.did(tab, .click)
                AgentFeed.shared.pointed(tab.page, at: CGPoint(x: to.x * zoom, y: to.y * zoom))
                AgentPage.drag(tab.page, from: from, to: to) { ok in
                    answer(ok ? ["done": "dragged"] : ["error": "couldn't drag in this tab"])
                }
            }
            return
        }
        // Words into whatever has focus: after a click into a field the
        // tree can't reach, or to add to what is there.
        if action == "type", ref.isEmpty {
            let words = request["text"] as? String ?? ""
            weighed(tab, action: request["submit"] as? Bool == true ? "type" : "none", ref: "") {
                if taken() { return }
                agents.touch(session, "type · \(tab.address?.host ?? "")")
                AgentFeed.shared.did(tab, .type)
                AgentPage.insert(tab.page, words)
                if request["submit"] as? Bool == true { _ = AgentPage.press(tab.page, "Enter") }
                answer(["done": "typed"])
            }
            return
        }
        if action == "scroll", ref.isEmpty {
            agents.touch(session, "scroll · \(tab.address?.host ?? "")")
            tab.page.run("window.scrollBy(0, \(request["dy"] as? Double ?? 600))", in: .named("yab-agent")) { _ in
                MainActor.assumeIsolated { answer(["ok": true]) }
            }
            return
        }
        // Where a ref lives: the page, or another site's frame in it,
        // whose points are the frame's own and need its place added.
        let (frame, marker) = AgentPage.locate(tab, ref)
        if ref.hasPrefix("f"), marker != nil, frame == nil {
            answer(["error": "that frame isn't known any more, take a new snapshot"])
            return
        }
        // A frame's refs are kept whole in that frame's own document.
        let local = ref
        func offset(_ then: @escaping @MainActor (CGPoint?) -> Void) {
            guard let marker else { then(.zero); return }
            AgentPage.run(tab, AgentPage.frameBox, ["k": marker]) { result in
                guard case .success(let value) = result, let box = value as? [String: Any], let x = box["x"] as? Double, let y = box["y"] as? Double else { then(nil); return }
                then(CGPoint(x: x, y: y))
            }
        }
        func act(_ arguments: [String: Any], _ then: @escaping @MainActor ([String: Any]) -> Void) {
            var arguments = arguments
            if arguments["ref"] == nil { arguments["ref"] = local }
            for (key, value) in ["text": "", "value": "", "dy": 600 as Any] where arguments[key] == nil { arguments[key] = value }
            AgentPage.run(tab, AgentPage.act, arguments, frame: frame) { result in
                guard case .success(let value) = result, let out = value as? [String: Any] else {
                    if case .failure(let error) = result { then(["error": error.localizedDescription]) } else { then(["error": "no answer"]) }
                    return
                }
                then(out)
            }
        }
        // A point of an element, in the web view's CSS pixels.
        func point(_ of: String, _ then: @escaping @MainActor (CGPoint?, [String: Any]) -> Void) {
            act(["action": "point", "ref": of]) { out in
                guard let x = out["x"] as? Double, let y = out["y"] as? Double else { then(nil, out); return }
                offset { base in
                    guard let base else { then(nil, ["error": "that frame is gone, take a new snapshot"]); return }
                    then(CGPoint(x: x + base.x, y: y + base.y), out)
                }
            }
        }
        // What it is about to press, by its words, for its step in the
        // chat: “Mark as read”, not the tab it was in.
        if !ref.isEmpty, ["click", "hover", "drag"].contains(action) {
            act(["action": "label"]) { out in
                if let label = out["label"] as? String, !label.isEmpty { agents.label(session, action, label) }
            }
        }
        if action == "hover" {
            agents.touch(session, "hover · \(tab.address?.host ?? "")")
            // Made in the page, and as a real move, which WebKit takes
            // when the window is in front.
            act(["action": "hover"]) { out in
                guard let x = out["x"] as? Double, let y = out["y"] as? Double else { answer(out); return }
                offset { base in
                    if taken() { return }
                    let at = CGPoint(x: x + (base?.x ?? 0), y: y + (base?.y ?? 0))
                    AgentFeed.shared.pointed(tab.page, at: CGPoint(x: at.x * zoom, y: at.y * zoom))
                    _ = AgentPage.hover(tab.page, x: at.x, y: at.y)
                    answer(["done": "hovered"])
                }
            }
            return
        }
        if action == "drag" {
            let to = request["to"] as? String ?? ""
            let dx = request["dx"] as? Double, dy = request["dy"] as? Double
            agents.touch(session, "drag · \(tab.address?.host ?? "")")
            AgentFeed.shared.did(tab, .click)
            point(ref) { from, out in
                guard let from else { answer(out); return }
                @MainActor func go(_ end: CGPoint) {
                    if taken() { return }
                    AgentFeed.shared.pointed(tab.page, at: CGPoint(x: end.x * zoom, y: end.y * zoom))
                    AgentPage.drag(tab.page, from: from, to: end) { ok in answer(ok ? ["done": "dragged"] : ["error": "couldn't drag in this tab"]) }
                }
                if !to.isEmpty {
                    // Onto another element: its top edge, so a list takes
                    // the dragged row before it.
                    act(["action": "point", "ref": to]) { target in
                        guard let x = target["x"] as? Double, let y = target["y"] as? Double else { answer(target); return }
                        offset { base in
                            guard let base else { answer(["error": "that frame is gone"]); return }
                            let h = target["h"] as? Double ?? 0
                            go(CGPoint(x: x + base.x, y: y + base.y - max(0, h / 2 - 3)))
                        }
                    }
                } else {
                    go(CGPoint(x: from.x + (dx ?? 0), y: from.y + (dy ?? 0)))
                }
            }
            return
        }
        let pressing = action == "click" || (action == "type" && request["submit"] as? Bool == true)
        weighed(tab, action: pressing ? action : "none", ref: pressing ? ref : "") {
        agents.touch(session, "\(action) · \(tab.address?.host ?? "")")
        AgentFeed.shared.did(tab, AgentFeed.pose(for: action))
        act([
            "action": action,
            "text": request["text"] as? String ?? "",
            "value": request["value"] as? String ?? "",
            "dy": request["dy"] as? Double ?? 600,
        ]) { out in
            if out["error"] != nil { answer(out); return }
            if action == "type", request["submit"] as? Bool == true {
                _ = AgentPage.press(tab.page, "Enter")
            }
            guard action == "click", let x = out["x"] as? Double, let y = out["y"] as? Double else { answer(out); return }
            offset { base in
            guard let base else { answer(["error": "that frame is gone, take a new snapshot"]); return }
            let x = x + base.x, y = y + base.y
            // On the page in front of you its pointer goes there first,
            // and the click lands once it has, under something you can
            // see. Behind, it simply clicks.
            let seen = browser.activeID == tab.id && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            AgentFeed.shared.pointed(tab.page, at: CGPoint(x: x * zoom, y: y * zoom))
            DispatchQueue.main.asyncAfter(deadline: .now() + (seen ? 0.45 : 0)) {
            if taken() { return }
            AgentPage.lands(tab, ref: ref, at: CGPoint(x: x, y: y)) { clear in
            if taken() { return }
            // Something of the top page's over it: by script, on the
            // element itself (AgentPage.landing).
            guard clear else {
                act(["action": "script"]) { said in answer(said) }
                return
            }
            // A real click, then a look to see it landed. A page that
            // asks something (confirm) holds its script, and the look
            // with it: the question is the answer then.
            let sent = AgentPage.click(tab.page, x: x, y: y)
            var answered = false
            @MainActor func once(_ out: [String: Any]) { if !answered { answered = true; answer(out) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + (sent ? 0.12 : 0)) {
                if let waiting = AgentSecrets.nativeQuestionReply([tab]) { once(waiting); return }
                if let question = AgentPage.asked[ObjectIdentifier(tab)] { once(["done": "mouse", "dialog": question.said]); return }
                @MainActor func watch(_ n: Int) {
                    guard !answered else { return }
                    if let waiting = AgentSecrets.nativeQuestionReply([tab]) { once(waiting); return }
                    if let question = AgentPage.asked[ObjectIdentifier(tab)] { once(["done": "mouse", "dialog": question.said]); return }
                    if n < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { watch(n + 1) } }
                }
                watch(0)
                act(["action": "confirm"]) { said in
                    // The click took the page elsewhere: it landed.
                    once(said["error"] == nil ? said : ["done": "mouse"])
                }
            }
            }
            }
            }
        }
        }
    }

    func handlePress(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        func weighed(_ tab: Tab, action: String, ref: String, at: CGPoint? = nil, then go: @escaping () -> Void) {
            c.weighed(tab, action: action, ref: ref, at: at, then: go)
        }
        guard let tab = own() else { return }
        let keys = request["keys"] as? String ?? ""
        let strokes: [AgentPage.Stroke]
        switch AgentPage.strokes(keys) {
        case .success(let read): strokes = read
        case .failure(let trouble): answer(["error": trouble.said]); return
        }
        agents.touch(session, "press \(keys)")
        AgentFeed.shared.did(tab, .type)
        // The same keys again after the person's yes go on from the key
        // that asked; after a no, or anything else, from the start.
        let id = ObjectIdentifier(tab)
        var start = 0
        if let left = AgentPage.keysLeft[id], left.session == (session ?? ""), left.keys == keys,
           let yes = tab.approved, yes.session == session, yes.ref.isEmpty, Date().timeIntervalSince(yes.at) < 120 {
            start = left.at
        }
        AgentPage.keysLeft[id] = nil
        AgentPage.keysSeen(tab.page) { base in
            var sent = 0
            // Enter or Space on a composer or a button is its Send: each
            // is weighed on what has the focus once the keys before it
            // have landed, as Tab moves the focus onto a Send.
            @MainActor func from(_ at: Int) {
                guard at < strokes.count else { answer(["ok": true]); return }
                let stroke = strokes[at]
                guard stroke.presses else {
                    AgentPage.send(tab.page, [stroke])
                    sent += 1
                    from(at + 1)
                    return
                }
                AgentPage.keysLanded(tab.page, count: base + sent) {
                    AgentPage.keysLeft[id] = (session ?? "", keys, at)
                    weighed(tab, action: "press", ref: "") {
                        AgentPage.keysLeft[id] = nil
                        AgentPage.send(tab.page, [stroke])
                        sent += 1
                        from(at + 1)
                    }
                }
            }
            from(start)
        }
    }

    func handleAgentShow(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // The page the person asked to see, in front of them and theirs
        // (Folders.show). Never from work nobody watches, nor a
        // subagent's: what it found goes to its parent.
        if let known = agents.session(session) {
            if known.unattended || Headless.nobody {
                answer(["error": "nobody is watching this task: give the page's address in your answer instead"])
                return
            }
            if known.parent != nil {
                answer(["error": "a subagent can't put a tab in front of the user; report it to the parent"])
                return
            }
            if !known.state.live {
                answer(["error": "this task has ended or was stopped by the user: stop now"])
                return
            }
        }
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        if tab.bench, let owner = tab.agent, owner != Agents.script, agents.root(of: owner) != agents.root(of: session) {
            answer(["error": "that is another task's tab: open the page in one of yours (open) and show that"])
            return
        }
        if tab.bench, tab.assistantSpace != nil, let home = browser.spaceHolding(tab.id) { browser.switchSpace(to: home) }
        guard browser.tabs.contains(where: { $0 === tab }) else { answer(missing(request)); return }
        if Headless.hidden { Headless.show(.request) }
        agents.touch(session, "show · \(tab.address?.host ?? tab.title)")
        Folders.shared.show(tab, in: browser)
        answer(describe(tab))
    }

    func handleAgentGo(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard let tab = own(going: true) else { return }
        guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else { answer(["error": "go needs a url"]); return }
        if Bench.mailLeaves(url, session: c.session, browser: c.browser, answer: answer) { return }
        AgentFeed.shared.did(tab, .load)
        // The killed document's callback may still be on its way. A new
        // address uses a fresh view, after Tab.go's normal route checks.
        let pendingStop = c.browser.stuck.outgrown.contains(tab.id)
        let escaping = url != tab.address && (pendingStop || tab.failure == StuckWatch.memoryStopped)
        let oldPage = tab.builtPage
        tab.go(to: url, fresh: escaping && pendingStop)
        // A special route can replace the Tab object while preserving its
        // id. Clear old advice only if the actual tab accepted this address
        // and no longer holds the old document. A refused route keeps it.
        let current = find(["id": tab.id.uuidString], in: c.browser)
        let detached = oldPage.map { old in
            let owner = old.webKit.flatMap { c.browser.tab(for: $0) }
                ?? (c.browser.tabs + c.browser.outside + c.browser.parkedTabs).first { $0.builtPage === old }
            return owner?.id != tab.id
        } ?? true
        if escaping, let current, current.address == Browser.page(url), detached {
            c.browser.stuck.outgrown.remove(tab.id)
            StuckWatch.notices[tab.id] = nil
            answer(describe(current))
            return
        }
        answer(describe(tab))
    }

    func handleNav(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard let tab = own(going: true) else { return }
        AgentFeed.shared.did(tab, .load)
        switch request["how"] as? String {
        case "back": tab.page.navigateBack()
        case "forward": tab.page.navigateForward()
        default: tab.page.reload(fromOrigin: false)
        }
        answer(describe(tab))
    }

    func handleAgentUpload(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard let tab = own(), let session else { return }
        let ref = request["ref"] as? String ?? ""
        let files = (request["files"] as? [String] ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard !files.isEmpty else { answer(["error": "upload needs files: paths on this Mac"]); return }
        let full = agents.session(session)?.full ?? true
        let told = agents.session(session)?.told ?? []
        if let trouble = files.lazy.compactMap({ AgentFiles.shared.refuse($0, session: session, full: full, told: told) }).first {
            answer(["error": trouble])
            return
        }
        let key = "upload:" + ref
        let yes = tab.approved.flatMap { $0.session == session && $0.ref == key && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
        let rule = AgentRules.shared.verdict(site: AgentRules.site(tab.address), label: "Upload")
        if rule == .never, browser.prefs.asking(session) != .bypass {
            answer(["error": "the person never allows uploads on \(AgentRules.site(tab.address)): don't try another way; say so in your answer"])
            return
        }
        guard yes != nil || rule == .always || browser.prefs.asking(session) == .bypass else {
            if tab.declined.remove(session) != nil {
                answer(["error": "the person said not now to uploading those files: don't try another way; say so in your answer"])
                return
            }
            let host = tab.address?.host ?? "this page"
            agents.ask(tab, AgentPermit(kind: .upload(files: files, ref: ref), session: session, detail: "\(AgentFiles.size(files)) · \(host)"))
            answer(["error": "uploading waits for the person's yes; asking them now", "asking": true])
            return
        }
        // Where the ref lives: the page, or another site's frame in it.
        let (frame, marker) = AgentPage.locate(tab, ref)
        if ref.hasPrefix("f"), marker != nil, frame == nil {
            answer(["error": "that frame isn't known any more, take a new snapshot"])
            return
        }
        tab.approved = nil
        agents.touch(session, "upload · \(tab.address?.host ?? "")")
        AgentFeed.shared.did(tab, .click)
        FileShelf.shared.gave(files, to: tab.address?.host ?? "")
        let names = files.map(\.lastPathComponent)
        // One answer: a press that fails is answered, and its offer then lapses unheard.
        var answered = false
        func reply(_ out: [String: Any]) { guard !answered else { return }; answered = true; answer(out) }
        // Into the page's field in script, for a page that never opens its
        // picker (a drop zone takes them as a drag from Finder would).
        func intoField() {
            let total = files.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
            guard total <= 25 << 20 else { reply(["error": "the page didn't open its file picker from \(ref); click what attaches a file and upload again"]); return }
            let given: [[String: Any]] = files.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? nil
                return ["name": url.lastPathComponent, "data": data.base64EncodedString(), "type": type ?? ""]
            }
            AgentPage.run(tab, AgentFiles.intoField, ["ref": ref, "files": given], frame: frame) { result in
                guard case .success(let value) = result, let out = value as? [String: Any] else { reply(["error": "couldn't give the page the files"]); return }
                reply(out["error"] == nil ? ["ok": true, "how": out["done"] as? String ?? "field", "files": names] : out)
            }
        }
        // What ref names pressed for real, as a person's click: the page's
        // own handler opens its picker.
        func press(_ then: @escaping @MainActor () -> Void) {
            AgentPage.run(tab, AgentFiles.opener, ["ref": ref], frame: frame) { result in
                guard case .success(let value) = result, let out = value as? [String: Any], out["error"] == nil else {
                    tab.uploading = nil
                    if case .success(let value) = result, let out = value as? [String: Any] { reply(out) } else { reply(["error": "couldn't click \(ref)"]) }
                    return
                }
                guard let x = out["x"] as? Double, let y = out["y"] as? Double else { then(); return }
                // A real click where it lands on the ref; by script when
                // something of the top page is over it (AgentPage.landing).
                @MainActor func click(_ at: CGPoint) {
                    AgentPage.lands(tab, ref: ref, at: at) { clear in
                        if clear { _ = AgentPage.click(tab.page, x: at.x, y: at.y); then(); return }
                        AgentPage.run(tab, AgentPage.act, ["action": "script", "ref": ref, "text": "", "value": "", "dy": 0], frame: frame) { _ in then() }
                    }
                }
                // A ref in another site's frame: its point is the frame's own.
                guard let marker else { click(CGPoint(x: x, y: y)); return }
                AgentPage.run(tab, AgentPage.frameBox, ["k": marker]) { box in
                    if case .success(let value) = box, let at = value as? [String: Any], let bx = at["x"] as? Double, let by = at["y"] as? Double {
                        click(CGPoint(x: x + bx, y: y + by))
                    } else { then() }
                }
            }
        }
        // Chromium: by path, the way browser automation uploads (Puppeteer's
        // uploadFile, Playwright's setInputFiles), never through the person's
        // chooser, which Chromium opens for no hidden or inactive tab: an
        // agent's tab out of sight is both (feedback #1963).
        if let chromium = tab.page as? ChromiumPage {
            let paths = files.map(\.path)
            Task { @MainActor in
                guard await AgentSecrets.check(chromium) else { reply(["error": AgentSecrets.Refused(chromium).localizedDescription]); return }
                do {
                    if try await chromium.agentSetFiles(AgentFiles.field, arguments: ["ref": ref], frame: frame, paths: paths) {
                        reply(["ok": true, "how": "field", "files": names]); return
                    }
                } catch {
                    reply(["error": "couldn't give the page the files: \(AgentPage.Said(error).localizedDescription)"]); return
                }
                guard !ref.isEmpty else { reply(["error": "no file field on this page: give upload the ref of what attaches a file (a button, a drop zone)"]); return }
                // A picker the press opens itself: its field takes the files.
                chromium.agentOfferFiles(paths, seconds: 4, opened: { press {} }) { taken, error in
                    if taken { reply(["ok": true, "how": "picker", "files": names]); return }
                    if let error { reply(["error": "couldn't give the page the files: \(error)"]); return }
                    intoField()
                }
            }
            return
        }
        tab.uploading = (files, Date().addingTimeInterval(20))
        // The page's picker, answered with the files; or, when it never
        // asks, the files put in its field.
        func settle() {
            let limit = Date().addingTimeInterval(4)
            func check() {
                if tab.uploading == nil { reply(["ok": true, "how": "picker", "files": names]); return }
                if Date() < limit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }; return }
                tab.uploading = nil
                intoField()
            }
            check()
        }
        guard !ref.isEmpty else { settle(); return }
        press { settle() }
    }

    func handleAgentDownload(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        guard let tab = own(), let session else { return }
        agents.touch(session, "download · \(tab.address?.host ?? "")")
        let before = AgentFiles.shared.got[session]?.count ?? 0
        let previousExpectation = AgentFiles.shared.expecting[tab.id]
        AgentFiles.shared.expecting[tab.id] = (session, Date().addingTimeInterval(30))
        if let raw = request["url"] as? String, !raw.isEmpty {
            guard let url = URL(string: raw, relativeTo: tab.address)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
                AgentFiles.shared.expecting[tab.id] = previousExpectation
                answer(["error": "download needs an http(s) url"]); return
            }
            if let chromium = tab.page as? ChromiumPage {
                let reservation = AgentFiles.shared.expecting[tab.id]
                let epoch = ContextPrivacy.shared.epoch
                let admission = agents.session(session)?.admission
                chromium.agentStartDownload(url, allowed: {
                    ContextPrivacy.shared.current(epoch) && admission?.valid == true
                        && tab.builtPage === chromium && tab.chromiumProfile == chromium.profile
                }) { error in
                    if let error {
                        // A later operation may already own this slot.
                        let current = AgentFiles.shared.expecting[tab.id]
                        if current?.session == reservation?.session && current?.until == reservation?.until {
                            AgentFiles.shared.expecting[tab.id] = previousExpectation
                        }
                        answer(["error": error.localizedDescription])
                    } else {
                        answer(["ok": true, "before": before])
                    }
                }
                return
            }
            guard let web = tab.page.webKit else {
                // Rejecting an unsupported route must not claim the person's
                // next download or overwrite an earlier pending request.
                AgentFiles.shared.expecting[tab.id] = previousExpectation
                answer(["error": "URL downloads are not available on this page engine yet"])
                return
            }
            web.startDownload(using: DownloadRequest.resource(url, from: tab.address)) { download in
                MainActor.assumeIsolated { browser.keep(download) }
            }
            answer(["ok": true, "before": before])
            return
        }
        let ref = request["ref"] as? String ?? ""
        guard !ref.isEmpty else {
            AgentFiles.shared.expecting[tab.id] = previousExpectation
            answer(["error": "download needs a ref to click or a url"]); return
        }
        AgentPage.run(tab, AgentPage.act, ["action": "click", "ref": ref, "text": "", "value": "", "dy": 0]) { result in
            guard case .success(let value) = result, let out = value as? [String: Any], out["error"] == nil else {
                if case .success(let value) = result, let out = value as? [String: Any] { answer(out) } else { answer(["error": "couldn't click \(ref)"]) }
                return
            }
            guard let x = out["x"] as? Double, let y = out["y"] as? Double else { answer(["ok": true, "before": before]); return }
            // A real click where it lands on the ref; by script when
            // something of the top page is over it (AgentPage.landing).
            AgentPage.lands(tab, ref: ref, at: CGPoint(x: x, y: y)) { clear in
                if clear { _ = AgentPage.click(tab.page, x: x, y: y); answer(["ok": true, "before": before]); return }
                AgentPage.run(tab, AgentPage.act, ["action": "script", "ref": ref, "text": "", "value": "", "dy": 0]) { _ in
                    answer(["ok": true, "before": before])
                }
            }
        }
    }

    func handleAgentDownloads(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let session = c.session
        // What this task has downloaded, from the `after`th on.
        let after = request["after"] as? Int ?? 0
        let list = AgentFiles.shared.got[session ?? ""] ?? []
        answer(["files": list.dropFirst(after).map { ["path": $0.path, "done": $0.done, "failed": $0.failed ?? ""] }])
    }

    /// save_page, and pdf as save_page's PDF: the page as a file in the
    /// task's folder (PageSave).
    func handleAgentPdf(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // One tab, or several (`tabs`) joined into one file.
        let ids = (request["tabs"] as? [String] ?? []).filter { !$0.isEmpty }
        let tabs = ids.isEmpty ? [find(request, in: browser)].compactMap { $0 } : ids.compactMap { find(["id": $0], in: browser) }
        guard let tab = tabs.first, tabs.count == max(ids.count, 1), let session else { answer(missing(request)); return }
        guard let format = PageSave.format(request["format"] as? String) else {
            answer(["error": "save_page makes \(PageSave.formats.joined(separator: ", ")), not \(request["format"] ?? "that")"])
            return
        }
        let reader = request["reader"] as? Bool ?? false
        if tabs.count > 1 || reader, !["pdf", "md", "txt"].contains(format) {
            answer(["error": "Several tabs, or reader, make a pdf, md or txt; \(format) is one tab at a time"])
            return
        }
        agents.touch(session, "save · \(tab.address?.host ?? "")")
        let folder = AgentFiles.shared.folder(for: session)
        let saved: @MainActor (Result<URL, Error>) -> Void = { result in
            switch result {
            case .success(let file):
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                answer(["path": file.path, "size": size])
            case .failure(let error):
                answer(["error": error.localizedDescription])
            }
        }
        switch format {
        case "csv", "xlsx":
            PageSave.sheets(tab, as: format, table: (request["table"] as? String) ?? (request["table"] as? Int).map(String.init), in: folder, done: saved) { found in
                answer(["tables": PageSave.listing(found), "count": found.count])
            }
        case "pdf" where tabs.count > 1 || reader:
            PageSave.book(tabs, reader: reader, title: request["title"] as? String, in: folder, done: saved)
        case "md", "txt" where tabs.count > 1:
            PageSave.joined(tabs, as: format, title: request["title"] as? String, in: folder, done: saved)
        default:
            PageSave.save(tab, as: format, in: folder, done: saved)
        }
    }

    func handleAgentFetch(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // A GET with the page's own cookies, on its own site only.
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        guard let raw = request["url"] as? String, let url = URL(string: raw, relativeTo: tab.address)?.absoluteURL,
              let host = url.host(), let here = tab.address?.host(), Vault.registrable(host) == Vault.registrable(here) else {
            answer(["error": "fetch reads only the tab's own site (\(tab.address?.host() ?? "?")); open a tab there first"])
            return
        }
        agents.touch(session, "fetch · \(host)")
        let body = """
        const r = await fetch(url, { credentials: 'include', redirect: 'follow' });
        const t = await r.text();
        return { status: r.status, type: r.headers.get('content-type') || '', text: t.slice(0, 1048576), cut: t.length > 1048576, url: r.url };
        """
        AgentPage.run(tab, body, ["url": url.absoluteString]) { result in
            switch result {
            case .success(let value): answer(value as? [String: Any] ?? ["error": "no answer"])
            case .failure(let error): answer(["error": error.localizedDescription])
            }
        }
    }

    func handleAgentRead(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // A site's data with no tab: its cookies, from here (AgentRead).
        guard let raw = request["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host() else {
            answer(["error": "fetch without a tab needs a whole http(s) address"])
            return
        }
        if Bench.mailLeaves(url, session: session, browser: browser, answer: answer) { return }
        let method = (request["method"] as? String ?? "GET").uppercased()
        guard method == "GET" || (method == "POST" && Skills.reads(method, url)) else {
            answer(["error": "a POST without a tab goes only to an address a skill lists as a read (its read: lines); anything else, do in the page"])
            return
        }
        agents.touch(session, "read · \(host)")
        let epoch = ContextPrivacy.shared.epoch
        let admission = agents.session(session)?.admission
        let allowed: @Sendable () -> Bool = { ContextPrivacy.shared.current(epoch) && (admission?.valid ?? true) }
        func read(in space: UUID, note: String?) {
            guard allowed() else { answer(["error": "This context was cleared."]); return }
            let store = Spaces.store(for: space)
            AgentRead.run(url, method: method, body: request["body"] as? String, type: request["type"] as? String,
                          keepHTML: request["html"] as? Bool ?? false, store: store, allowed: allowed) { got in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard allowed() else { answer(["error": "This context was cleared."]); return }
                        var out = got
                        if let note { out["space_note"] = note }
                        // Refused, or sent to a sign-in: somewhere else may be signed in.
                        let status = got["status"] as? Int ?? 0
                        let landed = (got["url"] as? String).flatMap(URL.init(string:))
                        guard got["error"] == nil, [401, 403].contains(status) || landed.map(SignIns.loginPage) == true else { answer(out); return }
                        SignIns.elsewhere(url, from: store, in: browser, allowed: allowed) { line in
                            if let line { out["elsewhere"] = line }
                            answer(out)
                        }
                    }
                }
            }
        }
        // Signed in where the space named is; with none, where the site is.
        if let name = request["space"] as? String, !name.isEmpty {
            guard let found = browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                answer(["error": "no space named \(name): \(browser.spaces.map(\.name).joined(separator: ", "))"])
                return
            }
            read(in: found.id, note: nil)
        } else {
            SignIns.pick(host, in: browser, allowed: allowed) { read(in: $0 ?? Spaces.current, note: $1) }
        }
    }

    func handleAgentAct(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        // ⌘J on a tab, without a hand, a --test run only.
        guard Store.testing else { answer(["error": "agent-act only works on a --test run"]); return }
        guard let tab = find(request, in: browser), let action = Hints.shared.actions(on: tab).first else { answer(["error": "no action for that tab"]); return }
        answer(["session": agents.act(action, on: tab).id, "action": action.title])
    }

    func handleAgentCookies(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        // Another browser's sign-ins into a test world, so a live run can
        // see what you see, a --test run only.
        guard Store.testing else { answer(["error": "agent-cookies only works on a --test run"]); return }
        guard let source = Chromium.installed().first(where: { $0.name == (request["source"] as? String ?? "") }) else {
            answer(["error": "no browser \(request["source"] as? String ?? ""), there are: \(Chromium.installed().map(\.name).joined(separator: ", "))"])
            return
        }
        browser.takeCookies(from: source.authorizingImport()) { count in answer(["cookies": count]) }
    }

    func handleAgentLook(_ c: AgentCall) {
        let answer = c.answer
        let agents = c.agents
        // The morning's look, now, a --test run only.
        guard Store.testing else { answer(["error": "agent-look only works on a --test run"]); return }
        Hints.shared.watching = true
        answer(agents.look(force: true).map { ["session": $0.id] } ?? ["error": "not started"])
    }

    func handleAgentTabs(_ c: AgentCall) {
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Whose each tab is, as this session sees it.
        let me = agents.session(session)
        let shared = browser.sharedPins ?? []
        // An assistant in the cloud knows the user's tabs as any agent does,
        // and its own and its tasks' wherever they are: never another
        // agent's, nor one on a site it may not open.
        let assistant = me?.assistantID
        let grant = agents.assistant(of: session)
        if let grant {
            // A space not visited since launch still has the user's tabs.
            // Load its saved row asleep, without changing the space on screen.
            let allowed = grant.allSpaces == true ? browser.spaces : browser.spaces.filter { $0.id == grant.selectedSpace(in: browser.spaces) }
            for space in allowed where space.id != browser.spaceID && browser.parked[space.id] == nil {
                browser.parked[space.id] = browser.loadRow(space.id)
            }
        }
        let userTabs = grant == nil ? browser.tabs : browser.everyTab
        let users = userTabs + shared.filter { pin in !userTabs.contains { $0 === pin } }
        // A local task's tabs in their own space while another is on
        // screen (#448) are still its own to see.
        // And a tab of yours it is at work in, sent to another space
        // while it worked (Tab.stays).
        let home = browser.parkedTabs.filter { $0.bench && $0.assistantSpace != nil && session != nil && agents.root(of: $0.agent) == agents.root(of: session) }
            + browser.parkedTabs.filter { $0.stays && session != nil && $0.guest == session }
        let listed = assistant == nil ? users + home
            : users.filter { !$0.bench } + browser.everyTab.filter { $0.bench && agents.session($0.agent)?.assistantID == assistant }
        var seen: Set<Tab.ID> = []
        let rows = listed.compactMap { tab -> [String: Any]? in
            guard seen.insert(tab.id).inserted else { return nil }
            // A private tab isn't an agent's to know of.
            guard !tab.shy else { return nil }
            if let grant, !grant.permits(tab, in: browser) { return nil }
            if let grant, !tab.bench, Assistants.shared.refusal(grant, url: tab.address ?? tab.pending) != nil { return nil }
            var row = describe(tab)
            let whose: String
            if tab.agent == session, session != nil { whose = "yours" }
            else if let parent = me?.parent, tab.agent == parent { whose = "parent's, read only" }
            else if me?.parent != nil { return nil }
            else if let owner = agents.session(tab.agent), owner.parent == session, session != nil { whose = "your subagent's" }
            else { whose = tab.bench ? "agent" : "user" }
            row["whose"] = whose
            row["inEverySpace"] = tab.everywhere != nil
            row["visible"] = browser.tabs.contains { $0 === tab }
            if grant?.allSpaces == true {
                let space = browser.tabs.contains { $0 === tab } ? browser.spaceID : browser.spaceHolding(tab.id)
                row["space"] = browser.spaces.first { $0.id == space }?.name ?? ""
            }
            return row
        }
        answer(["tabs": rows])
    }

    func handleAgentGoToTab(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        guard Store.testing, let tab = find(request, in: browser) else {
            answer(["error": "agent-go-to-tab needs a test tab"]); return
        }
        agents.bringForward(tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            answer(["active": browser.activeID == tab.id, "focused": tab.page.window?.firstResponder === tab.page,
                    "visible": tab.page.window?.occlusionState.contains(.visible) == true])
        }
    }

    func handleAgentBrowse(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let url = (request["url"] as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else {
            answer(["error": "agent-browse needs an http(s) url"])
            return
        }
        guard let tab = agents.browse(url, for: session) else { answer(["error": "no browser"]); return }
        answer(describe(tab))
    }

    func handleAgentEval(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // The agent's own script, in its own tabs only, in a world of
        // its own. A press in it that sends, posts, pays or deletes is
        // held (AgentPage.hold) and weighed as a click is: made after
        // the script, refused, or asked of the person.
        guard let tab = find(request, in: browser) else { answer(missing(request)); return }
        guard tab.bench else { answer(["error": "not an agent tab, read it with snapshot, act only in tabs you opened"]); return }
        guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
        guard own() != nil else { return }
        agents.touch(session, "eval · \(tab.address?.host ?? "")")
        let web = tab.page
        AgentPage.arm(web, on: browser.prefs.asking(session) != .bypass) { armed in
            guard armed else {
                answer(["error": "Yab couldn't set up its guard on this page, so the script wasn't run; reload the tab (nav) and try again"])
                return
            }
            AgentPage.eval(web, js) { result in
                MainActor.assumeIsolated {
                    AgentPage.held(web, "take") { held in
                        let out = held as? [String: Any]
                        let value: Any
                        switch result {
                        case .success(let got): value = Bench.capped(Bench.plain(got))
                        // A script ending in undefined, `button.click()`, gave nothing back.
                        case .failure(let error as NSError) where error.domain == WKErrorDomain && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue:
                            value = NSNull()
                        case .failure(let error):
                            // A script that failed presses nothing it held.
                            AgentPage.held(web, "drop")
                            let held = (out?["commit"] as? String).map { " (“\($0)” in it wasn't pressed)" } ?? ""
                            answer(["error": AgentPage.Said(error).localizedDescription + held])
                            return
                        }
                        guard let out, let label = out["commit"] as? String else { answer(["value": value]); return }
                        // A script with no agent behind it, the bench's: as its press is.
                        guard let session else { Bench.performHeld(web) { answer(["value": value, "pressed": label]) }; return }
                        let others = (out["others"] as? Int ?? 0) > 0 ? " Other such presses in the script weren't made." : ""
                        // The draft you pressed Send on: that press is yours already.
                        if let task = agents.session(session), let once = task.sendOnce, Date().timeIntervalSince(once) < 180 {
                            task.sendOnce = nil
                            Bench.performHeld(web) { answer(["value": value, "pressed": label]) }
                            return
                        }
                        Bench.decide(label, out, ref: "eval", in: tab, session: session,
                                     go: { Bench.performHeld(web) { answer(["value": value, "pressed": label]) } },
                                     refuse: { AgentPage.held(web, "drop"); answer(["error": $0 + " The rest of the script ran." + others]) },
                                     asking: { answer(["error": $0 + others, "asking": true, "value": value]) })
                    }
                }
            }
        }
    }

    func handleAgentEvalHeld(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let session = c.session
        // After the person answered the press an agent's script held:
        // made on a yes, dropped otherwise.
        guard let tab = find(request, in: browser), let session else { answer(missing(request)); return }
        let web = tab.page
        if let permit = tab.permit {
            answer(permit.session == session ? ["error": "waiting for the person's yes", "asking": true] : ["error": "waiting for the person to answer in this tab"])
            return
        }
        if let yes = tab.approved, yes.session == session, yes.ref == "eval", Date().timeIntervalSince(yes.at) < 120 {
            tab.approved = nil
            AgentPage.held(web, "perform") { made in
                answer(made as? Bool == true ? ["pressed": true] : ["error": "the page changed before the person's yes: nothing was pressed; take a new snapshot"])
            }
            return
        }
        AgentPage.held(web, "drop")
        tab.declined.remove(session)
        answer(["error": "the person said not now to that press: it wasn't made; say so in your answer, or ask them what to do instead"])
    }
}

import AppKit
import WebKit

// The bench's words for agents: reading a page as a tree, acting on what it
// names, keys, handing a tab to you and back, and the sessions themselves.
// `yab mcp` and `yab agent` speak these; so can `./bench`.
//
// Reading goes for any tab, yours included, an agent asked about the page
// you are on has to see it. Acting goes only for tabs an agent opened: yours
// are never clicked, typed into or sent anywhere from here.

extension Bench {
    func agentCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        if let refusal = RemoteTaskBoundary.refusal(request) { answer(["error": refusal]); return }
        Agents.shared.used(request["session"] as? String)

        if verb.hasPrefix("agent-native-"),
           let target = request["target"] as? [String: Any], target["kind"] as? String == "tab",
           let id = target["id"] as? String, let tab = find(["id": id], in: browser),
           let refusal = Agents.shared.stoppedOnTab(tab, session: request["session"] as? String) {
            answer(["error": refusal]); return
        }
        if verb.hasPrefix("agent-native-") {
            NativeControl.shared.handle(verb, request: request, browser: browser, answer: answer)
            return
        }
        guard let handle = Bench.agentHandlers[verb] else { answer(Bench.unknown(verb)); return }
        // save_page's explicit tabs list takes precedence over id, just as
        // its handler does. Check all of it before it starts any document.
        let ids = verb == "agent-pdf" ? (request["tabs"] as? [String] ?? []).filter { !$0.isEmpty } : []
        let pages = !ids.isEmpty ? ids.compactMap { find(["id": $0], in: browser) }
            : Bench.pageVerbs[verb] == nil && Bench.personVerbs[verb] == nil ? [] : [find(request, in: browser)].compactMap { $0 }
        for page in pages where verb != "agent-foot-preview" {
            if let refusal = Agents.shared.stoppedOnTab(page, session: request["session"] as? String) {
                answer(["error": refusal]); return
            }
        }
        // Whether go would reopen the stopped address is decided before
        // its handler can change that address to its destination.
        let goingTo = (request["url"] as? String).flatMap(Address.url(from:))
        let reopens = Set(pages.filter { verb == "agent-go" && goingTo == $0.address }.map(\.id))
        // A stopped page must not be woken just to explain why it stopped.
        // Check again at the reply: the watcher can end WebKit while eval or
        // fetch is still in flight, before its callback reports the failure.
        let reply = answer
        let answer: ([String: Any]) -> Void = { out in
            for page in pages {
                if verb != "agent-foot-preview", let refusal = Agents.shared.stoppedOnTab(page, session: request["session"] as? String) {
                    reply(["error": refusal]); return
                }
                if let stopped = Self.agentMemoryStop(verb, page, browser, reopens: reopens.contains(page.id)) {
                    if self.find(["id": page.id.uuidString], in: browser) === page {
                        StuckWatch.notices[page.id] = nil
                    }
                    reply(stopped)
                    return
                }
            }
            var out = out
            // Failed replies are rendered as the error alone by MCP. A
            // successful non-snapshot tool does not render alerts, so leave
            // its notice queued for AgentPage.read's next snapshot.
            if out["code"] as? String != "NATIVE_PAGE_QUESTION", var error = out["error"] as? String {
                for page in pages {
                    if self.find(["id": page.id.uuidString], in: browser) === page,
                       let notice = StuckWatch.notices.removeValue(forKey: page.id) { error += "\n" + notice }
                }
                out["error"] = error
            }
            reply(out)
        }
        for page in pages {
            if let stopped = Self.agentMemoryStop(verb, page, browser, reopens: reopens.contains(page.id)) {
                answer(stopped)
                return
            }
            if let failed = Self.agentLoadFailure(verb, page) {
                answer(failed)
                return
            }
        }
        // While an agent sets up mail, the password it made is hidden from it.
        let guarded = MailSetup.shared.guarded(verb, session: request["session"] as? String, answer)
        let protectedPages = pages
        // Navigation, showing, answering a dialog and handing the tab to the
        // person must remain available on a protected document: they are how
        // it is left, and they release none of its contents. Reading follows
        // separately. On 2026-11-14 a refused handoff left the agent no way
        // to give the person Apple's Identifiers page.
        if protectedPages.isEmpty || Self.escapeVerbs.contains(verb) {
            handle(self, AgentCall(bench: self, verb: verb, request: request, browser: browser, answer: guarded))
            return
        }
        if let waiting = AgentSecrets.nativeQuestionReply(protectedPages) { guarded(waiting); return }
        Task { @MainActor in
            for tab in protectedPages {
                guard await AgentSecrets.check(tab.page) else { guarded(["error": AgentSecrets.refusal(for: tab.page)]); return }
            }
            let checked: ([String: Any]) -> Void = { out in
                Task { @MainActor in
                    if let waiting = AgentSecrets.nativeQuestionReply(protectedPages) { guarded(waiting); return }
                    for tab in protectedPages {
                        guard await AgentSecrets.check(tab.page) else { guarded(["error": AgentSecrets.refusal(for: tab.page)]); return }
                    }
                    guarded(out)
                }
            }
            handle(self, AgentCall(bench: self, verb: verb, request: request, browser: browser, answer: checked))
        }
    }

    /// What stays open on a page the guard refuses: none of these answer
    /// with page contents.
    static let escapeVerbs: Set<String> = ["agent-go", "agent-show", "nav", "agent-dialog",
                                           "handoff", "handoff-wait", "agent-handback", "agent-ask", "agent-reply", "agent-chat-ask"]

    private static func agentMemoryStop(_ verb: String, _ tab: Tab, _ browser: Browser, reopens: Bool) -> [String: Any]? {
        guard tab.failure == StuckWatch.memoryStopped || browser.stuck.outgrown.contains(tab.id) else { return nil }
        // Show/handoff/close and navigation to a different address remain
        // available. The person's own Try Again clears failure normally.
        let readsStoppedPage = ["snapshot", "settle", "act", "press", "nav", "agent-fetch", "agent-eval", "agent-eval-held",
                                "agent-upload", "agent-download", "agent-pdf"].contains(verb)
        guard readsStoppedPage || reopens else { return nil }
        return ["error": StuckWatch.memoryStopped + ". Don't reload or reopen this page in this task. Tell the user the page used too much memory; they can choose Try Again themselves, or you can work at another address.",
                "code": "PAGE_STOPPED_FOR_MEMORY", "url": tab.address?.absoluteString ?? ""]
    }

    /// A page that never arrived (no such host, a refused connection,
    /// offline) has no document to read or act in: a script sent there
    /// never answered, and the call waited out its 25 s as if Yab were
    /// slow. Said at once instead, with the address, so a wrong address
    /// reads as one. Going elsewhere, back or again stays open.
    static func agentLoadFailure(_ verb: String, _ tab: Tab) -> [String: Any]? {
        guard let failure = tab.failure, failure != StuckWatch.memoryStopped, !tab.loading,
              loadFailureReaders.contains(verb) else { return nil }
        let address = tab.address?.absoluteString ?? "this address"
        return ["error": "\(address) didn't load: \(failure). Check the address; navigate this tab (\(Bench.short(tab))) somewhere else or reload it.",
                "code": "PAGE_LOAD_FAILED", "url": address]
    }

    /// What needs the page's document: refused on a page that never arrived.
    static let loadFailureReaders: Set<String> = ["snapshot", "settle", "act", "press", "agent-act", "agent-read", "agent-fetch",
                                                  "agent-eval", "agent-eval-held", "agent-upload", "agent-download", "agent-pdf"]

    /// Every verb agentCommand knows, by area, each in its own file.
    static let agentHandlers: [String: AgentHandler] = {
        var all: [String: AgentHandler] = [:]
        for area in [pageVerbs, personVerbs, payVerbs, routinesVerbs, messagesVerbs, mailVerbs, otherMailVerbs, mailSpaceVerbs, hintsVerbs, keptVerbs,
                     boostsVerbs, memoryVerbs, sessionsVerbs, assistantVerbs, artifactVerbs, watchVerbs, madeVerbs, shelfVerbs] {
            all.merge(area) { first, _ in first }
        }
        return all
    }()
}

/// One verb's call: what was asked, of which window, where the answer goes.
typealias AgentHandler = @MainActor (Bench, AgentCall) -> Void

@MainActor
struct AgentCall {
    let bench: Bench
    let verb: String
    let request: [String: Any]
    let browser: Browser
    let answer: ([String: Any]) -> Void
    var agents: Agents { Agents.shared }
    var session: String? { request["session"] as? String }

    /// The tab asked for, when it is one an agent may act in: its own,
    /// or yours as Settings › Agents allows. `going` is for sending it
    /// somewhere else, which the tab in front of you never is. `asking`
    /// is for asking the person in it, which a tab they are driving
    /// takes too: they are already there.
    func own(going: Bool = false, asking: Bool = false) -> Tab? {
        guard let tab = bench.find(request, in: browser) else { answer(bench.missing(request)); return nil }
        if let refusal = agents.stoppedOnTab(tab, session: session) {
            answer(["error": refusal]); return nil
        }
        // A task that has been stopped, or has ended, touches nothing more.
        if let session, session != Agents.script, let known = agents.session(session), !known.state.live {
            answer(["error": "this task has ended or was stopped by the user: stop now"])
            return nil
        }
        // You took the wheel here: it waits until you hand it back.
        if !asking, AgentFeed.shared.driving.contains(tab.id) {
            answer(["error": "the person is using this tab right now, wait until they hand it back (try again in a few seconds), or work in another tab"])
            return nil
        }
        // One question at a time, in any tab: a second can't take the
        // place of the one on the card.
        if tab.permit != nil {
            answer(["error": "waiting for the person to answer in this tab", "asking": true])
            return nil
        }
        // A subagent works in its own tabs only; the rest it may read.
        if let known = agents.session(session), known.parent != nil, tab.agent != known.id {
            answer(["error": "a subagent acts only in tabs it opened itself: read this one with snapshot, or open your own (open)"])
            return nil
        }
        // So does work out of sight: nobody would see it in yours.
        if let known = agents.session(session), known.sealed, tab.agent != known.id {
            answer(["error": "this task acts only in tabs it opened itself: read this one with snapshot, or open your own (open)"])
            return nil
        }
        if tab.bench {
            // A tab opened by one agent and used by another is the second's too.
            if tab.agent == nil || tab.agent == Agents.script, let session { tab.agent = session }
            bench.house(tab)
            return tab
        }
        // Yours.
        let mode = browser.prefs.asking(session)
        guard let session else {
            answer(["error": "that is the user's tab, read it with snapshot, but act only in tabs you opened (open)"])
            return nil
        }
        let front = browser.activeID == tab.id
        if front, AgentFeed.shared.touchedLately(tab) {
            answer(["error": "the person is using this tab right now, try again in a few seconds, or work in another tab"])
            return nil
        }
        // Taking the tab the person is looking at somewhere else asks them
        // first, in every mode, unless the task is about this tab (asked on
        // it or pointed at it): an outside agent told "work in my tab" gets
        // its yes with one click instead of a refusal.
        if mode == .ask || (going && front), !tab.allowed.contains(session) {
            if tab.refused.contains(session) {
                answer(["error": "the person said not now to this tab: leave it, and open a tab of your own (open) instead"])
                return nil
            }
            let prompt = agents.session(session)?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = prompt.isEmpty
                ? "It works here as in its own tabs; a click of yours takes over."
                : "For “\(prompt.count > 90 ? String(prompt.prefix(88)) + "…" : prompt)”"
            agents.ask(tab, AgentPermit(kind: .use, session: session, detail: detail))
            answer(["error": "asking the person to let you use this tab", "asking": true])
            return nil
        }
        if tab.guest != session { tab.guest = session }
        bench.house(tab)
        return tab
    }

    /// Before a press that sends, posts, pays or deletes: nothing to
    /// say, and on it goes; or the question hung from the tab, and the
    /// agent told to wait for it.
    func weighed(_ tab: Tab, action: String, ref: String, at: CGPoint? = nil, then go: @escaping () -> Void) {
        guard browser.prefs.asking(session) != .bypass, action != "none", let session else { go(); return }
        // The draft you pressed Send on: that press is yours already.
        if let task = agents.session(session), let once = task.sendOnce, Date().timeIntervalSince(once) < 180 {
            task.sendOnce = nil
            go()
            return
        }
        // A yes is for that press, that element, for two minutes: not a
        // pass for whatever the same ref names later.
        let yes = tab.approved.flatMap { $0.session == session && $0.ref == ref && Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
        // A press inside another site's frame is weighed in that frame.
        let (located, _) = AgentPage.locate(tab, ref)
        let chromium = tab.engineKind == .chromium
        let weigh: (PageFrame?) -> Void = { frame in
            AgentPage.run(tab, AgentPage.weigh, ["action": action, "ref": ref, "approved": yes != nil, "frames": chromium,
                                                 "at": at.map { ["x": $0.x, "y": $0.y] } ?? NSNull()], frame: frame) { result in
                // Couldn't tell what the press would do: it isn't made.
                guard case .success(let value) = result, let out = value as? [String: Any] else {
                    answer(["error": "couldn't check what that press does; take a new snapshot and try again"])
                    return
                }
                if out["frame"] as? Bool == true {
                    answer(["error": "that point is inside another site's frame; take a new snapshot and press the element by its ref"])
                    return
                }
                guard let label = out["commit"] as? String else { go(); return }
                if out["approved"] as? Bool == true, yes != nil {
                    tab.approved = nil
                    go()
                    return
                }
                Bench.decide(label, out, ref: ref, in: tab, session: session, go: go,
                             refuse: { answer(["error": $0]) }, asking: { answer(["error": $0, "asking": true]) })
            }
        }
        // A key goes where the focus is. On Chromium another site's frame
        // is its own process, so its focused document is found and weighed.
        guard chromium, ref.isEmpty, at == nil, let page = tab.page as? ChromiumPage else { weigh(located); return }
        Task { @MainActor in
            switch await page.agentFocus() {
            case .main: weigh(nil)
            case .frame(let frame): weigh(frame)
            case .unknown: answer(["error": "couldn't tell which field has the focus; click the field by its ref first, then press again"])
            }
        }
    }
}

extension Bench {
    /// A press that sends, posts, pays or deletes, once weighed and not yet
    /// allowed: made now (go) under a rule or the spending limit, refused
    /// with the words for the agent, or asked of the person.
    static func decide(_ label: String, _ out: [String: Any], ref: String, in tab: Tab, session: String,
                       go: () -> Void, refuse: (String) -> Void, asking: (String) -> Void) {
        let agents = Agents.shared
        let rules = AgentRules.shared
        let pays = AgentRules.paying(label) || out["pays"] as? Bool == true
        let amount = pays ? out["amount"] as? String ?? "" : ""
        // A payment is never an exception kept for the site.
        let verdict = pays ? nil : rules.verdict(site: AgentRules.site(tab.address), label: label)
        if verdict == .always {
            // You said so once, on this site: the page is told nothing new.
            go()
        } else if verdict == .never {
            refuse("the person never allows “\(label)” on \(AgentRules.site(tab.address)): don't press it; say so in your answer")
        } else if !amount.isEmpty, rules.mayPay(amount) {
            rules.spend(amount)
            if let task = agents.session(session) { agents.note(task, "Paid \(amount), under the limit") }
            go()
        } else if agents.session(session)?.parent != nil {
            // Nobody to ask on a subagent's behalf: it says so in its report.
            refuse("“\(label)” needs the user's yes, and a subagent can't ask the user; don't press it, report it to the parent")
        } else if tab.declined.remove(session) != nil {
            refuse("the person said not now to “\(label)”: don't press it; say so in your answer, or ask them what to do instead")
        } else {
            agents.ask(tab, AgentPermit(kind: .press(label: label, ref: ref), session: session, detail: out["detail"] as? String ?? "",
                                        draft: out["draft"] as? String ?? "", amount: amount, pays: pays))
            asking("“\(label)” waits for the person's yes; asking them now")
        }
    }

    /// Makes the press an agent's script held, then goes on.
    static func performHeld(_ web: any PageHandle, then: @escaping @MainActor () -> Void) {
        AgentPage.held(web, "perform") { _ in then() }
    }

    /// Until the page's text has the words, or the time is up.
    func look(for words: String, in tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        tab.page.run("document.body ? document.body.innerText : ''", in: .named("yab-agent")) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .success(let value) = result, (value as? String)?.localizedCaseInsensitiveContains(words) == true {
                    answer(self.describe(tab))
                    return
                }
                guard Date() < limit else {
                    var out = self.describe(tab)
                    out["timeout"] = true
                    answer(out)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.look(for: words, in: tab, until: limit, answer) }
            }
        }
    }

    /// A tab's picture as JPEG in base64, to go back in the answer itself;
    /// PNG at the screen's own pixels when asked for (`retina`).
    func picture(_ web: any PageHandle, width: Double?, png: Bool = false, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = PageShot(width: width.map { CGFloat($0) })
        web.snapshot(shot) { image, error in
            MainActor.assumeIsolated {
                self.picture(image, error: error, width: width, png: png, answer)
            }
        }
    }

    /// Encode only after a guarded caller has admitted the captured pixels.
    func picture(_ image: NSImage?, error: Error?, width: Double?, png: Bool = false, _ answer: @escaping ([String: Any]) -> Void) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            answer(["error": error?.localizedDescription ?? "no picture"])
            return
        }
        guard let encoded = Self.encode(cg, width: width, png: png) else {
            answer(["error": png ? "no retina picture fits 2560 pixels and 3.75 MB; take it without retina" : "no picture"])
            return
        }
        answer(["data": encoded.0.base64EncodedString(), "width": encoded.1, "height": encoded.2, "format": png ? "png" : "jpeg"])
    }

    /// A retina PNG's longest side, in pixels.
    nonisolated static let retinaSide = 2560
    /// A retina PNG's most bytes: 5 MB once in base64, the most an image
    /// the model reads may be.
    nonisolated static let retinaBytes = 3_750_000

    /// The picture's bytes and pixel size: JPEG drawn at the width asked
    /// for, or PNG at the screen's own pixels, for reading small type or
    /// checking a design (the screenshot tool's `retina`).
    nonisolated static func encode(_ cg: CGImage, width: Double?, png: Bool) -> (Data, Int, Int)? {
        if png { return retina(cg) }
        // Drawn at the width asked for in pixels, not in points: a
        // Retina picture is four times the tokens for no more to read.
        var rep = NSBitmapImageRep(cgImage: cg)
        if let width, rep.pixelsWide > Int(width) {
            rep = drawn(cg, wide: Int(width), high: Int(Double(rep.pixelsHigh) * width / Double(rep.pixelsWide))) ?? rep
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]).map { ($0, rep.pixelsWide, rep.pixelsHigh) }
    }

    /// The retina PNG, only ever within both caps: a 5K tab's every pixel
    /// is an image a client refuses. The long side at most `side`, and
    /// smaller again until the bytes fit, down to the `least` the default
    /// picture has. Nil when it can't be drawn smaller, or still doesn't
    /// fit at `least`: never a PNG past either cap.
    nonisolated static func retina(_ cg: CGImage, side: Int = retinaSide, bytes: Int = retinaBytes, least: Int = 1024,
                                   draw: (CGImage, Int, Int) -> NSBitmapImageRep? = drawn) -> (Data, Int, Int)? {
        var long = min(max(cg.width, cg.height), side)
        while true {
            guard let rep = scaled(cg, longSide: long, draw: draw),
                  max(rep.pixelsWide, rep.pixelsHigh) <= long,
                  let data = rep.representation(using: .png, properties: [:]) else { return nil }
            if data.count <= bytes { return (data, rep.pixelsWide, rep.pixelsHigh) }
            guard long > least else { return nil }
            long = max(least, long * 3 / 4)
        }
    }

    /// The picture with its longer side at most `longSide` pixels; nil when
    /// it had to be drawn smaller and couldn't be.
    nonisolated private static func scaled(_ cg: CGImage, longSide: Int, draw: (CGImage, Int, Int) -> NSBitmapImageRep?) -> NSBitmapImageRep? {
        let long = max(cg.width, cg.height)
        guard long > longSide else { return NSBitmapImageRep(cgImage: cg) }
        let scale = Double(longSide) / Double(long)
        return draw(cg, max(1, Int((Double(cg.width) * scale).rounded())), max(1, Int((Double(cg.height) * scale).rounded())))
    }

    nonisolated static func drawn(_ cg: CGImage, wide: Int, high: Int) -> NSBitmapImageRep? {
        guard let small = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: small) else { return nil }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: wide, height: high))
        return small
    }
}

/// The keys of the last `seq` (agent-mail-space), what stood as each came,
/// and the screen a moment after the last.
@MainActor
enum MailSeq {
    static var log: [[String: Any]] = []
    static var after: [String: Any] = [:]

    static func press(_ keys: [String], at n: Int, gap: Double, aloft waits: Bool, after: Double) {
        guard let window = Links.window, keys.indices.contains(n), let (flags, name, typed) = Bench.chord(keys[n]) else { return }
        let desk = MailDesk.shared
        log.append(["key": keys[n], "aloft": MailMorph.shared.aloft, "open": desk.open?.thread ?? "", "view": "\(desk.screen)"])
        Bench.send(flags, name, typed, to: window)
        guard n + 1 < keys.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { MainActor.assumeIsolated { MailSeq.settled() } }
            return
        }
        next(keys, at: n + 1, gap: gap, aloft: waits, after: after, until: CACurrentMediaTime() + gap, first: true)
    }

    /// The next key: `gap` on, or with `aloft` once a flight is up.
    static func next(_ keys: [String], at n: Int, gap: Double, aloft waits: Bool, after: Double, until: CFTimeInterval, first: Bool = false) {
        if !first, !waits || MailMorph.shared.aloft || CACurrentMediaTime() >= until {
            return press(keys, at: n, gap: gap, aloft: waits, after: after)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits ? 0.005 : gap)) {
            MainActor.assumeIsolated { MailSeq.next(keys, at: n, gap: gap, aloft: waits, after: after, until: until) }
        }
    }

    /// The screen a moment after the last key.
    static func settled() {
        let desk = MailDesk.shared
        after = ["view": "\(desk.screen)", "subject": desk.open?.subject ?? "", "drafting": desk.draft != nil,
                 "aloft": MailMorph.shared.aloft, "hidden": Array(desk.flying)]
    }
}

/// What `agent-row-watch` sees: each turn of the main run loop, as it goes
/// to wait, which is when the column is drawn, the agents' tabs that belong
/// in a folder (their task has two, or is a task asked in words) yet have no
/// place in one. Each is a frame with a loose row that then jumps in.
@MainActor
enum RowWatch {
    private(set) static var turns = 0
    private(set) static var loose: [String] = []
    private static var observer: CFRunLoopObserver?

    static func start(_ browser: Browser) {
        stop()
        turns = 0
        loose = []
        let made = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak browser] _, _ in
            MainActor.assumeIsolated {
                guard let browser else { return }
                turns += 1
                let agents = Agents.shared
                var byRoot: [String: [Tab]] = [:]
                for tab in browser.tabs where tab.pin == nil {
                    guard let agent = tab.agent, agent != Agents.script, let root = agents.root(of: agent) else { continue }
                    byRoot[root, default: []].append(tab)
                }
                for (root, tabs) in byRoot where tabs.count >= 2 || agents.session(root)?.task == true {
                    for tab in tabs where Folders.shared.place(of: tab) == nil {
                        loose.append("turn \(turns): \(Bench.short(tab)) \(tab.address?.lastPathComponent ?? "")")
                    }
                }
            }
        }
        observer = made
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
    }

    static func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}

extension Bench {
    /// Why a task may not send something in the person's name: only a chat
    /// they are in sends (mail_send, send_message), never a subagent or a
    /// task nobody watches, whatever the asking mode. Nil when it may.
    static func sendRefusal(_ asker: Agents.Session?, what: String) -> String? {
        guard let asker else { return "no task to send for" }
        guard asker.parent == nil, !asker.unattended else {
            return "\(what) goes only from a chat the person is in: say what you would send in your answer"
        }
        return nil
    }
}

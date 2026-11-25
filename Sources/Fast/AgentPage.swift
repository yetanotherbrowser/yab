import AppKit

// What an agent sees of a page and how it touches it.
//
// Everything runs in a JavaScript world of its own: the page's scripts share
// the DOM with it but not its variables, so a page can neither read which
// element is e12 nor put something else under that name. A ref stays with its
// element from one snapshot to the next, and only an element gone from the
// page is forgotten: so after an act the agent is told what changed (+ came,
// - gone, ~ changed, new words) and acts on those refs without reading the
// page again. PLAN-agent-hands.md has the numbers this was held to.
//
// A snapshot is an accessibility tree in a line per node: role, name, the
// state that matters, and a ref for what can be acted on, hovered or
// scrolled. It is what a model reads best for what it costs, a tenth of the
// page's HTML, and every button named the way a screen reader would name it.
// Another site's frame, a payment form, is read in its own document and put
// where it sits, its refs named for it (f1e3). Words a person can't see are
// left out and counted.
//
// Clicks are real: the element is scrolled into view, a point of it checked
// to be the element and not something over it, and a mouse down and up
// handed to the web view there, trusted events, the ones a page can't tell
// from a hand. What a dialog or a banner covers isn't clicked at all: the
// agent is told what is in the way, with its buttons. Something small over
// it, or a view with no window, a click in script, and the answer says so.
// alert, confirm and prompt in an agent's own tab are the agent's to answer.

@MainActor
enum AgentPage {
    /// Runs a function body in the agent's world, with arguments, awaiting
    /// what it returns: in the page, or in one of its frames.
    static func run(_ tab: Tab, _ body: String, _ arguments: [String: Any] = [:], frame: PageFrame? = nil, _ done: @escaping @MainActor (Result<Any?, Error>) -> Void) {
        let page = tab.page
        // An extension's own window is left out of the page, never run in.
        if let frame, AgentSecrets.walledOff(frame) { done(.failure(AgentSecrets.Refused(said: AgentSecrets.walledOffFrame))); return }
        let execute = {
            page.call(AgentSecrets.guardBody + body, arguments: arguments, in: .agent, frame: frame) { result in
                MainActor.assumeIsolated {
                    _ = Task<Void, Never> { @MainActor in
                        guard await AgentSecrets.check(page) else { done(.failure(AgentSecrets.Refused(page))); return }
                        finish(result)
                    }
                }
            }
        }
        func finish(_ result: Result<Any?, Error>) {
            switch result {
            case .success(let value): done(.success(value))
            case .failure(let error): done(.failure(Said(error)))
            }
        }
        Task { @MainActor in
            guard await AgentSecrets.check(page) else { done(.failure(AgentSecrets.Refused(page))); return }
            execute()
        }
    }

    /// WebKit's error with the script's own words in it, when it has them:
    /// "A JavaScript exception occurred" tells nobody anything.
    struct Said: LocalizedError {
        let error: Error
        init(_ error: Error) { self.error = error }
        var errorDescription: String? {
            let info = (error as NSError).userInfo
            if let message = info["WKJavaScriptExceptionMessage"] as? String {
                // Line 0: WebKit doesn't know, as for a promise's rejection.
                let line = (info["WKJavaScriptExceptionLineNumber"] as? Int).flatMap { $0 > 0 ? " (line \($0))" : nil } ?? ""
                return "the page's script failed: \(message)\(line)"
            }
            return error.localizedDescription
        }
    }

    // MARK: - other sites' frames

    /// A frame's document says it is there, from the agent's world, and
    /// WebKit hands over who it is: the only way to run script in a frame
    /// of another origin. Only in agents' own tabs (Tab.arm).
    static let frameScript = """
    if (window !== window.top) window.webkit.messageHandlers.\(FrameRelay.name).postMessage({ href: location.href, w: innerWidth, h: innerHeight });
    """

    struct Frame {
        let info: PageFrame
        let href: String
        let w: Double
        let h: Double
    }
    /// The frames each web view's documents have announced, newest last.
    static var frames: [ObjectIdentifier: [Frame]] = [:]
    /// Which frame each marker of the latest snapshot was: "f2" → frame.
    static var framed: [ObjectIdentifier: [String: PageFrame]] = [:]

    static func heard(_ web: any PageHandle, _ frame: Frame) {
        guard !AgentSecrets.walledOff(frame.info), !AgentSecrets.protected(URL(string: frame.href)) else { return }
        var list = frames[ObjectIdentifier(web), default: []]
        list.removeAll { $0.href == frame.href && $0.w == frame.w && $0.h == frame.h }
        list.append(frame)
        frames[ObjectIdentifier(web)] = Array(list.suffix(40))
    }

    /// The announced frame an iframe element most likely is: the same
    /// address (up to the fragment), then the same size.
    static func frame(in web: any PageHandle, src: String, w: Double, h: Double) -> PageFrame? {
        let list = frames[ObjectIdentifier(web)] ?? []
        // A card's boxes are often one address apart only by the fragment
        // (VGS: the field's name and id after #), and of the same size.
        if let exact = list.last(where: { $0.href == src }) { return exact.info }
        func bare(_ s: String) -> String { s.components(separatedBy: "#")[0] }
        let near: (Frame) -> Bool = { abs($0.w - w) < 3 && abs($0.h - h) < 3 }
        let same = list.filter { bare($0.href) == bare(src) }
        if let hit = same.last(where: near) ?? same.last { return hit.info }
        let origin = URL(string: src).flatMap { u in u.host.map { "\(u.scheme ?? "https")://\($0)" } } ?? ""
        let kin = list.filter { !origin.isEmpty && $0.href.hasPrefix(origin) }
        return (kin.last(where: near) ?? kin.last ?? list.last(where: near))?.info
    }

    /// Every frame of the page asked of WebKit itself (a name outside its
    /// public framework), each then telling where it is from the agent's
    /// world. A tab of yours an agent was given never had frameScript: its
    /// frames, a payment form's boxes, were nowhere to be read, and the
    /// agent typed a card into them blind.
    static func discover(_ web: any PageHandle, _ done: @escaping @MainActor () -> Void) {
        web.childFrames { infos in
            let group = DispatchGroup()
            for info in infos where !AgentSecrets.walledOff(info) {
                group.enter()
                web.call("return { href: location.href, w: innerWidth, h: innerHeight }", in: .agent, frame: info) { result in
                    MainActor.assumeIsolated {
                        if case .success(let value) = result, let at = value as? [String: Any] {
                            heard(web, Frame(info: info, href: at["href"] as? String ?? "",
                                             w: at["w"] as? Double ?? 0, h: at["h"] as? Double ?? 0))
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { MainActor.assumeIsolated { done() } }
        }
    }

    /// Where a ref lives: "f2e7" is e7 in the frame the latest snapshot
    /// called f2; anything else is the page's own.
    static func locate(_ tab: Tab, _ ref: String) -> (frame: PageFrame?, marker: Int?) {
        guard ref.hasPrefix("f"), let e = ref.firstIndex(of: "e"), let k = Int(ref[ref.index(after: ref.startIndex)..<e]) else { return (nil, nil) }
        return (framed[ObjectIdentifier(tab)]?["f\(k)"], k)
    }

    /// Where the frame the latest snapshot called f`k` sits in the page's
    /// viewport, brought into view first.
    static let frameBox = """
    const f = globalThis.__yab && globalThis.__yab.frames && globalThis.__yab.frames.get(k);
    if (!f || !f.isConnected) return { error: 'that frame is gone, take a new snapshot' };
    f.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
    const r = f.getBoundingClientRect(), s = getComputedStyle(f);
    let x = r.left + f.clientLeft + (parseFloat(s.paddingLeft) || 0), y = r.top + f.clientTop + (parseFloat(s.paddingTop) || 0);
    let w = f.ownerDocument.defaultView;
    while (w.frameElement) { const b = w.frameElement.getBoundingClientRect(); x += b.left; y += b.top; w = w.parent; }
    return { x, y };
    """

    /// Whether a real click at a point of the top page lands on what a ref
    /// names, or on the frame that holds it. A frame's own hit test can't
    /// see what the top page draws over it: an extension's window (a
    /// password manager's list) over a page's frame took a click by ref
    /// that way. Anything else in the way is clicked by script instead.
    static let landing = """
    const S = globalThis.__yab;
    let want = k >= 0 ? S && S.frames && S.frames.get(k) : S && S.refs && S.refs.get(ref);
    if (!want || !want.isConnected) return false;
    for (let w = want.ownerDocument.defaultView; w && w.frameElement; w = w.parent) want = w.frameElement;
    let h = document.elementFromPoint(x, y);
    while (h && h.shadowRoot) { const inner = h.shadowRoot.elementFromPoint(x, y); if (!inner || inner === h) break; h = inner; }
    for (let n = h; n; n = n.parentNode || n.host) if (n === want) return true;
    // A label over its own input, the way custom checkboxes are drawn.
    const l = h && h.closest && h.closest('label');
    return !!(l && (l.control === want || l.contains(want)));
    """

    /// How a real click by ref at its point would go.
    enum Landing {
        /// On the ref, or on the frame that holds it: the real click goes.
        case clear
        /// On something of the top page's over it: clicked by script instead.
        case covered
        /// The page asked something meanwhile, which holds its scripts: the
        /// question is the answer, and nothing is clicked.
        case asked([String: Any])
    }

    /// Whether a real click by `ref` at `point`, in the top page's CSS
    /// pixels, lands where it should. Only an extension's window can be
    /// over it unseen, so with none open the real click goes as before,
    /// with no look at the top page; when the frames can't be listed, or
    /// the point can't be told, it doesn't land.
    static func lands(_ tab: Tab, ref: String, at point: CGPoint, _ done: @escaping @MainActor (Landing) -> Void) {
        var settled = false
        @MainActor func finish(_ landing: Landing) { if !settled { settled = true; done(landing) } }
        // Both steps call into the page, which a question (confirm) holds.
        @MainActor func watch(_ n: Int) {
            guard !settled else { return }
            if let waiting = AgentSecrets.nativeQuestionReply([tab]) { finish(.asked(waiting)); return }
            // Nothing was clicked: the question as a read answers it.
            if let question = asked[ObjectIdentifier(tab)] { finish(.asked(["dialog": question.said, "url": tab.address?.absoluteString ?? "", "title": tab.title])); return }
            if n < 300 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { watch(n + 1) } }
        }
        watch(0)
        Task { @MainActor in
            if await AgentSecrets.extensionFrameOpen(tab.page) == false { finish(.clear); return }
            guard !settled else { return }
            let k = locate(tab, ref).marker ?? -1
            run(tab, landing, ["ref": ref, "k": k, "x": Double(point.x), "y": Double(point.y)]) { result in
                if case .success(let value) = result, value as? Bool == true { finish(.clear) } else { finish(.covered) }
            }
        }
    }

    // MARK: - what the page asked

    /// alert, confirm and prompt in an agent's own tab: the agent answers
    /// them (`dialog`), the way a person would the sheet. Nobody is looking
    /// at that tab, and a card there would hold the page, and the agent's
    /// click with it, until someone happened by.
    struct Asked {
        let kind: String
        let message: String
        let text: String
        let reply: (Bool, String?) -> Void
        var said: String {
            kind == "prompt"
                ? "The page asks (prompt): “\(message)”\(text.isEmpty ? "" : " (filled in: “\(text)”)"). Answer with dialog(tab, accept, text)."
                : "The page asks (\(kind)): “\(message)”. Answer with dialog(tab, accept: true for OK, false for Cancel)."
        }
    }
    static var asked: [ObjectIdentifier: Asked] = [:]
    private static var askedAt: [ObjectIdentifier: UUID] = [:]

    /// Holds a page's question for the agent. Unanswered in two minutes,
    /// it goes to the person as any tab's question does (`fallback`):
    /// WebKit's answer must come some day, or the page waits for ever.
    static func hold(_ tab: Tab, _ question: Asked, fallback: @escaping () -> Void) {
        let key = ObjectIdentifier(tab)
        let token = UUID()
        asked[key] = question
        askedAt[key] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            guard askedAt[key] == token, asked[key] != nil else { return }
            asked[key] = nil
            askedAt[key] = nil
            fallback()
        }
    }

    /// The agent's answer to what the page asked.
    static func answer(_ tab: Tab, accept: Bool, text: String?) -> Bool {
        let key = ObjectIdentifier(tab)
        guard let question = asked.removeValue(forKey: key) else { return false }
        askedAt[key] = nil
        question.reply(accept, text)
        return true
    }

    /// A tab going away: its question answered Cancel, and what was kept
    /// about it let go.
    static func forget(_ tab: Tab) {
        _ = answer(tab, accept: false, text: nil)
        ExtensionDebugger.shared.closed(tab)
        let key = ObjectIdentifier(tab)
        alerts[key] = nil
        seen[key] = nil
        framed[key] = nil
        frames[ObjectIdentifier(tab.page)] = nil
    }
    /// What alerts said since the agent last looked: they are accepted at
    /// once, and told.
    static var alerts: [ObjectIdentifier: [String]] = [:]
    /// Said when a page in an agent's tab opened its file picker on a click.
    static let pickerClosed = "The page opened a file picker, which Yab closed: nobody sees it. To give the page a file, call upload with this tab, the ref you just clicked and the file's full path; Yab presses it and answers the picker itself. Don't ask the person to pick the file."

    /// Whether a page's question in this tab is the agent's to answer.
    static func answers(_ tab: Tab) -> Bool {
        tab.bench && !AgentFeed.shared.driving.contains(tab.id)
    }

    /// Chromium holds the renderer while a native JS continuation is open.
    /// Its fresh secret guard cannot run until the person answers AskCard.
    /// Keep WebKit's existing agent-dialog path; never admit Chromium output
    /// using a pre-modal scan or a cached frame inventory.
    static func answersDialog(_ tab: Tab) -> Bool {
        tab.engineKind != .chromium && answers(tab)
    }

    // MARK: - what changed

    struct Seen {
        let url: String
        let tree: String
        let said: [String]
        let interactive: Bool
    }
    static var seen: [ObjectIdentifier: Seen] = [:]

    /// The page as an agent reads it: the tree, other sites' frames read in
    /// their own documents and put where they sit, and, with `since`, only
    /// what changed from the last look.
    static func read(_ tab: Tab, interactive: Bool, ref: String?, since: Bool,
                     takeMemoryNotice: @escaping @MainActor () -> String?, _ done: @escaping @MainActor ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                if try await AgentPDF.isDocument(tab.page) { AgentPDF.read(tab, snapshot: true, done: done) }
                else { readHTML(tab, interactive: interactive, ref: ref, since: since, takeMemoryNotice: takeMemoryNotice, done) }
            } catch { done(["error": error.localizedDescription]) }
        }
    }

    private static func readHTML(_ tab: Tab, interactive: Bool, ref: String?, since: Bool,
                                 takeMemoryNotice: @escaping @MainActor () -> String?,
                                 _ done: @escaping @MainActor ([String: Any]) -> Void) {
        let key = ObjectIdentifier(tab)
        if let question = asked[key] { done(["dialog": question.said, "url": tab.address?.absoluteString ?? "", "title": tab.title]); return }
        // A ref inside a frame reads that frame.
        if let ref, !ref.isEmpty, case let (frame?, k?) = locate(tab, ref) {
            run(tab, snapshot, ["interactive": interactive, "ref": ref, "prefix": "f\(k)"], frame: frame) { result in
                guard case .success(let value) = result, let out = value as? [String: Any] else { done(["error": "couldn't read that frame, take a new snapshot"]); return }
                done(out)
            }
            return
        }
        run(tab, snapshot, ["interactive": interactive, "ref": ref.map { $0.isEmpty ? NSNull() : $0 as Any } ?? NSNull(), "prefix": ""]) { result in
            switch result {
            case .failure(let error):
                done(["error": error.localizedDescription, "url": tab.address?.absoluteString ?? ""])
            case .success(let value):
                guard var out = value as? [String: Any] else { done(["error": "no answer"]); return }
                if out["error"] != nil { done(out); return }
                let markers = out["frames"] as? [[String: Any]] ?? []
                weave(tab, &out, markers) { out in
                    var out = out
                    if let heard = alerts.removeValue(forKey: key), !heard.isEmpty {
                        out["alerts"] = heard.map { $0 == pickerClosed ? $0 : "The page said (alert, accepted): “\($0)”" }.joined(separator: "\n")
                    }
                    // The browser loaded it again under the agent (Stuck.swift).
                    if let notice = takeMemoryNotice() {
                        out["alerts"] = [out["alerts"] as? String, notice].compactMap { $0 }.joined(separator: "\n")
                    }
                    guard ref == nil || ref == "" else { done(out); return }
                    // The tree is compared with the last one read the same
                    // way; the words with the last look of any kind, so a
                    // full read in between loses nothing.
                    let before = seen[key]
                    let said = out["said"] as? [String] ?? []
                    let url = out["url"] as? String ?? ""
                    let tree = out["tree"] as? String ?? ""
                    let sameWay = before?.interactive == interactive
                    let now = Seen(url: url, tree: sameWay || before == nil || interactive ? tree : before!.tree, said: said,
                                   interactive: sameWay || before == nil || interactive ? interactive : before!.interactive)
                    seen[key] = now
                    if since, let before, before.url == url {
                        if sameWay, let change = diff(before, now) {
                            out["diff"] = change
                        } else {
                            let old = Set(before.said)
                            let fresh = said.filter { !old.contains($0) }
                            if !fresh.isEmpty { out["fresh"] = fresh.prefix(12).map { "“\($0)”" }.joined(separator: " · ") }
                        }
                    }
                    out["said"] = nil
                    out["frames"] = nil
                    done(out)
                }
            }
        }
    }

    /// Each marker of another site's frame replaced by that frame's own
    /// tree, its refs named for it: f2e7.
    /// A frame that hasn't said it is there is looked for first; in a tab
    /// of yours, where frames never say so, every time.
    private static func weave(_ tab: Tab, _ out: inout [String: Any], _ markers: [[String: Any]], _ done: @escaping @MainActor ([String: Any]) -> Void) {
        // An extension's own window is never heard, so it can't make the
        // others unknown (weaveKnown leaves it out).
        let unknown = markers.contains { marker in
            !AgentSecrets.protected(URL(string: marker["src"] as? String ?? "")) && frame(in: tab.page, src: marker["src"] as? String ?? "", w: marker["w"] as? Double ?? 0, h: marker["h"] as? Double ?? 0) == nil
        }
        guard unknown || !tab.bench else { weaveKnown(tab, &out, markers, done); return }
        let held = out
        discover(tab.page) {
            var out = held
            weaveKnown(tab, &out, markers, done)
        }
    }

    private static func weaveKnown(_ tab: Tab, _ out: inout [String: Any], _ markers: [[String: Any]], _ done: @escaping @MainActor ([String: Any]) -> Void) {
        let key = ObjectIdentifier(tab)
        framed[key] = [:]
        guard !markers.isEmpty else { done(out); return }
        let interactive = true
        var trees: [Int: String] = [:]
        var said = out["said"] as? [String] ?? []
        var frameNeeds: String?
        let group = DispatchGroup()
        for marker in markers {
            guard let k = marker["k"] as? Int else { continue }
            let src = marker["src"] as? String ?? ""
            if AgentSecrets.protected(URL(string: src)) {
                trees[k] = "(an extension's own window, a password manager's or wallet's: left out)"
                continue
            }
            guard let info = frame(in: tab.page, src: src, w: marker["w"] as? Double ?? 0, h: marker["h"] as? Double ?? 0) else {
                trees[k] = "(a frame from \(URL(string: src)?.host ?? "another site") that hasn't said it is there yet; take a new snapshot)"
                continue
            }
            framed[key, default: [:]]["f\(k)"] = info
            group.enter()
            run(tab, snapshot, ["interactive": interactive, "ref": NSNull(), "prefix": "f\(k)"], frame: info) { result in
                if case .success(let value) = result, let inner = value as? [String: Any], inner["error"] == nil {
                    trees[k] = inner["tree"] as? String ?? ""
                    said += inner["said"] as? [String] ?? []
                    // A sign-in form in another site's frame: the page needs it.
                    if let needs = inner["needs"] as? String, !needs.isEmpty, frameNeeds == nil || needs == "captcha" { frameNeeds = needs }
                } else {
                    trees[k] = "(a frame from \(URL(string: src)?.host ?? "another site") that couldn't be read)"
                }
                group.leave()
            }
        }
        var result = out
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let lines = (result["tree"] as? String ?? "").components(separatedBy: "\n").flatMap { line -> [String] in
                    guard let at = line.range(of: "\u{0}frame:") else { return [line] }
                    let parts = line[at.upperBound...].split(separator: ":", maxSplits: 2).map(String.init)
                    guard parts.count >= 2, let k = Int(parts[0]), let depth = Int(parts[1]) else { return [line] }
                    let pad = String(repeating: "  ", count: depth)
                    let host = parts.count > 2 ? (URL(string: parts[2])?.host ?? parts[2]) : ""
                    let inner = (trees[k] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }.map { pad + "  " + $0 }
                    return [pad + "frame f\(k) (\(host))"] + inner
                }
                result["tree"] = lines.joined(separator: "\n")
                result["said"] = said
                if let frameNeeds, (result["needs"] as? String ?? "").isEmpty || frameNeeds == "captcha" { result["needs"] = frameNeeds }
                done(result)
            }
        }
    }

    /// What differs between two looks at the same page, as a model reads
    /// it: elements come (+), gone (-) or changed (~), keyed by their refs,
    /// which stay the same while the element does; and new words on the
    /// page. Nil when the change is most of the page: then the page itself.
    static func diff(_ a: Seen, _ b: Seen) -> String? {
        func keyed(_ tree: String) -> [(String, String)] {
            tree.components(separatedBy: "\n").map { line in
                let bare = line.trimmingCharacters(in: .whitespaces)
                let first = bare.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let isRef = first.range(of: #"^(f\d+)?e\d+$"#, options: .regularExpression) != nil
                return (isRef ? first : bare, bare)
            }.filter { !$0.1.isEmpty }
        }
        let old = keyed(a.tree), new = keyed(b.tree)
        var was: [String: String] = [:]
        for (k, line) in old { was[k] = line }
        var now: Set<String> = []
        var lines: [String] = []
        for (k, line) in new {
            now.insert(k)
            if let before = was[k] { if before != line { lines.append("~ " + line) } } else { lines.append("+ " + line) }
        }
        for (k, line) in old where !now.contains(k) { lines.append("- " + line) }
        let oldSaid = Set(a.said)
        let fresh = b.said.filter { !oldSaid.contains($0) }
        let newSaid = Set(b.said)
        let gone = a.said.filter { !newSaid.contains($0) }.count
        if lines.count > 60 || lines.count > max(12, new.count * 2 / 3) { return nil }
        var out: [String] = []
        if lines.isEmpty && fresh.isEmpty && gone == 0 { return "Nothing on the page changed." }
        if !lines.isEmpty { out.append("changed:"); out += lines }
        if !fresh.isEmpty {
            out.append("new text: " + fresh.prefix(12).map { "“\($0)”" }.joined(separator: " · ") + (fresh.count > 12 ? " … (\(fresh.count - 12) more)" : ""))
        }
        if gone > 0 && lines.isEmpty { out.append("\(gone) line\(gone == 1 ? "" : "s") of text gone") }
        let text = out.joined(separator: "\n")
        return text.count > 4000 ? nil : text
    }

    /// Until the page has been still for a moment: nothing added, removed
    /// or changed for 150 ms, at most 2.5 s. What a click set going has
    /// then mostly landed, without a fixed wait when nothing moves.
    static let quiet = """
    return await new Promise(done => {
      let last = performance.now();
      const seen = new MutationObserver(() => { last = performance.now(); });
      seen.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      const start = performance.now();
      (function tick() {
        const now = performance.now();
        if (now - last >= 150 || now - start > 2500) { seen.disconnect(); done(now - start); return; }
        setTimeout(tick, 30);
      })();
    });
    """

    // MARK: - reading

    static let snapshot = """
    const S = (globalThis.__yab ||= { n: 0, refs: new Map() });
    S.ids ||= new WeakMap();
    S.frames ||= new Map();
    const P = prefix || '';
    const interactiveOnly = interactive !== false;
    let root = document.body || document.documentElement;
    if (ref) {
      const el = S.refs.get(ref);
      if (!el || !el.isConnected) return { error: 'stale ref ' + ref + ', take a new snapshot' };
      root = el;
    } else {
      // Refs stay with their elements from one snapshot to the next: what
      // hasn't changed keeps its name, so a model can act on what a diff
      // said without reading the page again. Only the gone are forgotten.
      for (const [k, el] of S.refs) if (!el.isConnected) S.refs.delete(k);
      S.frames = new Map();
    }
    function refFor(el) {
      let id = S.ids.get(el);
      if (!id || S.refs.get(id) !== el) { id = P + 'e' + (++S.n); S.ids.set(el, id); }
      S.refs.set(id, el);
      // What it was, for finding it again if the page redraws it (act).
      (S.marks ||= new Map()).set(id, { tag: el.tagName, words: (el.getAttribute('aria-label') || el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 120) });
      return id;
    }
    const lines = [];
    let size = 0, cut = false;
    const LIMIT = 40000;
    const TAGS = { A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', IMG: 'img',
      H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
      NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form',
      DIALOG: 'dialog', UL: 'list', OL: 'list', LI: 'listitem', TABLE: 'table', TR: 'row',
      TD: 'cell', TH: 'columnheader', SUMMARY: 'button', LABEL: 'label', P: 'paragraph', ARTICLE: 'article',
      SECTION: 'region', ASIDE: 'complementary', IFRAME: 'iframe', VIDEO: 'video', OPTION: 'option' };
    const INPUTS = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
      image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'button' };
    const ACTING = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox',
      'menuitemradio', 'option', 'switch', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem']);
    // What opens on hover: the part of every `…:hover …` rule before the
    // hover, the element a pointer has to rest on. Menus built this way
    // have nothing else that says they are there.
    const HOVER = new Set();
    try {
      const sels = [];
      const take = rules => { for (const r of rules) { if (sels.length > 300) return; if (r.cssRules && !r.selectorText) take(r.cssRules); else if (r.selectorText && r.selectorText.includes(':hover')) sels.push(r.selectorText); } };
      for (const sh of document.styleSheets) { try { take(sh.cssRules); } catch (e) {} }
      for (const sel of sels) for (const part of sel.split(',')) {
        const at = part.indexOf(':hover');
        if (at < 0) continue;
        const rest = part.slice(at + 6).trim();
        if (!rest || /^[:\\[]/.test(rest)) continue;  // hover restyles itself only: nothing appears
        const before = part.slice(0, at).trim();
        if (!before) continue;
        try { for (const el of document.querySelectorAll(before)) HOVER.add(el); } catch (e) {}
      }
    } catch (e) {}
    function role(el) {
      const given = el.getAttribute('role');
      if (given) return given.split(' ')[0];
      if (el.tagName === 'INPUT') return INPUTS[(el.type || 'text').toLowerCase()] || 'textbox';
      if (el.tagName === 'A') return el.hasAttribute('href') ? 'link' : null;
      if (el.isContentEditable && (el.parentElement ? !el.parentElement.isContentEditable : true)) return 'textbox';
      return TAGS[el.tagName] || null;
    }
    function clean(s, n) { s = (s || '').replace(/\\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
    function name(el, r, acting) {
      const label = el.getAttribute('aria-label');
      if (label) return clean(label, 100);
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const t = by.split(' ').map(id => el.ownerDocument.getElementById(id)).filter(Boolean).map(e => e.innerText || e.textContent).join(' ');
        if (t.trim()) return clean(t, 100);
      }
      if (el.tagName === 'IMG') return clean(el.alt || el.title, 100);
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
        if (el.id) { const l = el.ownerDocument.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l) return clean(l.innerText, 100); }
        const wrap = el.closest('label'); if (wrap) return clean(wrap.innerText, 100);
        if (['button', 'submit', 'reset'].includes(el.type)) return clean(el.value, 100);
        return clean(el.placeholder || el.title || el.name, 100);
      }
      if (!r || acting || ACTING.has(r) || r === 'heading' || r === 'dialog') {
        // A box that holds other things to act on is named by its own
        // words, not theirs: "Account", not the whole menu under it.
        let own = '';
        if (!ACTING.has(r) && el.querySelector('a[href],button,[role=button],[role=menuitem],input')) {
          for (const c of el.childNodes) if (c.nodeType === 3) own += c.textContent + ' ';
        }
        const t = clean(own.trim() || el.innerText || el.textContent || el.title, r ? 100 : 80);
        if (t) return t;
        // An icon of a button: its picture's words, or its svg's title.
        const img = el.querySelector('img[alt]:not([alt=""]),[aria-label],svg title');
        if (img) return clean(img.getAttribute('alt') || img.getAttribute('aria-label') || img.textContent, 100);
        return clean(el.title, 100);
      }
      return clean(el.title, 100);
    }
    function shown(el) {
      if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    }
    function scrolls(el) {
      if (el === document.body || el === document.documentElement) return false;
      if (el.scrollHeight <= el.clientHeight + 20 || el.clientHeight < 40) return false;
      return /(auto|scroll)/.test(getComputedStyle(el).overflowY);
    }
    function acts(el, r) {
      if (r && ACTING.has(r)) return true;
      if (el.tagName === 'SUMMARY' || el.hasAttribute('onclick') || el.getAttribute('draggable') === 'true') return true;
      if (HOVER.has(el)) return true;
      const tab = el.getAttribute('tabindex');
      if (tab !== null && +tab >= 0 && el.childElementCount < 6) return true;
      if (el.tagName === 'DIV' || el.tagName === 'SPAN' || el.tagName === 'LI' || el.tagName === 'SVG' || el.tagName === 'TD') {
        const c = getComputedStyle(el).cursor;
        const handy = c === 'pointer' || c === 'grab' || c === 'move';
        if (handy && (!el.parentElement || getComputedStyle(el.parentElement).cursor !== c)) return true;
      }
      return false;
    }
    // A card's number and code are never read back to an agent: yab fills
    // them (autofill), and the snapshot says only that they are filled.
    function luhn(d) {
      if (d.length < 12 || d.length > 19) return false;
      let sum = 0;
      for (let i = 0; i < d.length; i++) { let n = +d[d.length - 1 - i]; if (i % 2) { n *= 2; if (n > 9) n -= 9; } sum += n; }
      return sum % 10 === 0;
    }
    // Everything a box says it is: its autocomplete, name, id, placeholder,
    // aria-label and the words of its labels.
    function called(el) {
      const labels = el.labels ? [...el.labels].map(l => l.innerText || '').join(' ') : '';
      return [el.getAttribute('autocomplete'), el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), labels]
        .filter(Boolean).join(' ').toLowerCase();
    }
    function cardNumber(el) {
      const said = called(el);
      if (/cc-number|card.?num|cc.?num|cardnumber/.test(said) && !/name|holder|exp/.test(said)) return true;
      // A Luhn-valid number in a box named for something else (a Cloud
      // project number, an account or order id) is not a card.
      if (/account|project|order|phone|tracking|invoice|customer|\\bid\\b|routing|iban/.test(said)) return false;
      const d = (el.value || '').replace(/[\\s-]/g, '');
      return /^\\d+$/.test(d) && luhn(d);
    }
    function cardCode(el) {
      const said = called(el);
      return /cc-csc|\\bcvc|\\bcvv|\\bcsc\\b|\\bcid\\b|security.?code|card.?verification/.test(said);
    }
    function state(el, r) {
      const out = [];
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
        if (el.type === 'checkbox' || el.type === 'radio') { if (el.checked) out.push('checked'); }
        else if (el.type === 'password') out.push('password', el.value ? 'filled' : 'empty');
        else if (cardNumber(el)) out.push('card number', el.value ? 'filled="•••• ' + el.value.replace(/\\D/g, '').slice(-4) + '"' : 'empty');
        else if (cardCode(el)) out.push('security code', el.value ? 'filled' : 'empty');
        else if (el.type === 'file') out.push('file', el.files && el.files.length ? 'chosen="' + clean([...el.files].map(f => f.name).join(', '), 80) + '"' : 'nothing chosen');
        else out.push('value="' + clean(el.value, 80) + '"');
        if (el.validationMessage && el.value) out.push('invalid="' + clean(el.validationMessage, 60) + '"');
      }
      if (el.tagName === 'SELECT') out.push('value="' + clean(el.selectedOptions[0] ? el.selectedOptions[0].text : '', 60) + '"');
      if (el.isContentEditable && r === 'textbox') out.push('value="' + clean(el.innerText, 80) + '"');
      for (const a of ['aria-checked', 'aria-selected', 'aria-expanded', 'aria-pressed']) {
        const v = el.getAttribute(a); if (v === 'true') out.push(a.slice(5));
      }
      if (el.getAttribute('aria-invalid') === 'true') out.push('invalid');
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.push('disabled');
      if (el.readOnly && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) out.push('readonly');
      if (el === el.ownerDocument.activeElement) out.push('focused');
      if (r === 'heading') out.push('level=' + (el.getAttribute('aria-level') || el.tagName.slice(1)));
      if (r === 'link') { const h = el.getAttribute('href'); if (h && !h.startsWith('javascript') && h !== '#') out.push('href=' + clean(h, 80)); }
      if (HOVER.has(el)) out.push('opens-on-hover');
      if (el.getAttribute('draggable') === 'true' || getComputedStyle(el).cursor === 'grab') out.push('draggable');
      return out;
    }
    function emit(text) {
      if (cut) return;
      if (size + text.length > LIMIT) { cut = true; return; }
      lines.push(text); size += text.length + 1;
    }
    const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'PATH', 'META', 'LINK', 'HEAD']);
    // Words a person can't see: a pixel high, the page's own color, or put
    // off the screen. Pages hide instructions for agents this way.
    function faint(el) {
      const s = getComputedStyle(el);
      if (parseFloat(s.fontSize) < 4) return true;
      if (s.color === 'rgba(0, 0, 0, 0)' || s.color === 'transparent') return true;
      const r = el.getBoundingClientRect();
      if (r.right < -100 || r.bottom < -100 && window.scrollY === 0) return true;
      const bg = (() => { for (let e = el; e; e = e.parentElement) { const b = getComputedStyle(e).backgroundColor; if (b && b !== 'rgba(0, 0, 0, 0)' && b !== 'transparent') return b; } return 'rgb(255, 255, 255)'; })();
      return bg === s.color;
    }
    let hidden = 0;
    const frames = [];
    function walk(node, depth) {
      if (cut) return;
      if (node.nodeType === 3) {
        if (interactiveOnly) return;
        const t = clean(node.textContent, 200);
        if (!t) return;
        if (node.parentElement && faint(node.parentElement)) { hidden++; return; }
        emit('  '.repeat(depth) + 'text "' + t + '"');
        return;
      }
      if (node.nodeType !== 1 || SKIP.has(node.tagName.toUpperCase())) return;
      const el = node;
      // What is on screen, not what aria-hidden says: a modal hides the rest
      // of the page from screen readers, Google's sign-in prompt hid all of
      // claude.ai's login this way, but an agent has to see behind it.
      // Hidden by style prunes the branch; no size only keeps the element
      // itself out, a wrapper of no height can hold the whole page.
      // `display: contents` has no box of its own, so checkVisibility calls
      // it hidden; its children are what show.
      if (el.checkVisibility && !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
          && el.tagName !== 'DETAILS' && getComputedStyle(el).display !== 'contents') return;
      // A box set there to catch what the browser fills, not for anyone to
      // type in: no tab stop and hidden from readers, or a speck. A card's
      // frame (VGS) holds three beside its one real box, and an agent
      // typed into them.
      if ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') && ((el.getAttribute('aria-hidden') === 'true' && el.tabIndex < 0)
          || (!/^(checkbox|radio|file|hidden)$/i.test(el.type) && (() => { const b = el.getBoundingClientRect(); return b.width < 4 && b.height < 4; })()))) return;
      const sized = shown(el);
      const r = role(el);
      const acting = acts(el, r);
      const scroller = sized && !acting && scrolls(el);
      const heading = r === 'heading';
      const status = r === 'alert' || r === 'status' || (el.hasAttribute('aria-live') && el.getAttribute('aria-live') !== 'off');
      const structural = !interactiveOnly && r && !['paragraph', 'label', 'cell', 'listitem'].includes(r);
      let next = depth;
      if (sized && (acting || heading || scroller || r === 'dialog' || structural || (r === 'img' && !interactiveOnly))) {
        let line = '  '.repeat(depth);
        if (acting || scroller) line += refFor(el) + ' ';
        line += (r || (scroller ? 'scrollable' : 'clickable'));
        const n = name(el, r, acting); if (n && !scroller) line += ' "' + n.replace(/"/g, "'") + '"';
        else if (scroller && (el.getAttribute('aria-label') || el.title)) line += ' "' + clean(el.getAttribute('aria-label') || el.title, 60) + '"';
        const st = state(el, r); if (scroller) st.push('scrolls'); if (st.length) line += ' ' + st.join(' ');
        emit(line);
        next = depth + 1;
        // Buttons and links are named by their text: don't say it twice.
        if (acting && r !== 'combobox' && r !== 'textbox' && el.tagName !== 'SELECT' && !el.querySelector('input,textarea,select,button,a[href],[role=button],[contenteditable],iframe')) return;
      } else if (status && interactiveOnly && sized) {
        // What a page says back, "Saved", "Card declined", is what an
        // action is checked by: always in the tree.
        const t = clean(el.innerText, 160);
        if (t) emit('  '.repeat(depth) + (r || 'status') + ' "' + t.replace(/"/g, "'") + '"');
        return;
      }
      if (el.tagName === 'SELECT') return;
      if (el.tagName === 'IFRAME') {
        let doc = null; try { doc = el.contentDocument; } catch (e) {}
        if (doc && doc.body) walk(doc.body, next);
        else if (sized) {
          // Another site's frame: read in its own document, by yab, and
          // put here. The marker is replaced by what it holds.
          const k = frames.length + 1;
          S.frames.set(k, el);
          const b = el.getBoundingClientRect();
          frames.push({ k, src: el.src, w: b.width, h: b.height });
          emit('  '.repeat(next) + '\\u0000frame:' + k + ':' + next + ':' + clean(el.src, 80));
        }
        return;
      }
      if (el.shadowRoot) for (const c of el.shadowRoot.childNodes) walk(c, next);
      for (const c of el.childNodes) walk(c, next);
    }
    walk(root, 0);
    // What a person has to do rather than an agent.
    let needs = '';
    // The page's own frames of its site count too: a sign-in form in an
    // iframe asks for a password all the same. Another site's frame says
    // so in its own read (weave).
    const docs = [document];
    for (let i = 0; i < docs.length && docs.length < 20; i++) {
      for (const f of docs[i].querySelectorAll('iframe')) { let d = null; try { d = f.contentDocument; } catch (e) {} if (d) docs.push(d); }
    }
    const q = s => docs.some(d => [...d.querySelectorAll(s)].some(shown));
    // reCAPTCHA v3's invisible badge sits on ordinary forms and asks nothing.
    if (q('iframe[src*="recaptcha"]:not([src*="size=invisible"]),iframe[src*="hcaptcha"],iframe[src*="challenges.cloudflare"],iframe[src*="arkoselabs"],iframe[title*="captcha" i],#cf-challenge-running'))
      needs = 'captcha';
    else if (q('input[autocomplete="one-time-code"],input[name*="otp" i],input[id*="totp" i],input[name*="code" i][inputmode="numeric"]'))
      needs = 'a one-time code';
    // One password box is a sign-in (or a confirm-access step). A page with
    // several is changing a password in settings: the agent's to fill.
    else if (docs.reduce((n, d) => n + [...d.querySelectorAll('input[type="password"]:not([autocomplete="new-password"])')].filter(shown).length, 0) === 1)
      needs = 'a password';
    // The other ways in it offers: Continue with Google, GitHub and the like.
    // A bare provider's name counts only beside a sign-in form, not in a footer.
    const sso = [];
    const form = q('input[type="password"],input[type="email"],input[autocomplete="username"],input[name*="email" i]');
    const providers = { google: 'Google', github: 'GitHub', apple: 'Apple', microsoft: 'Microsoft', gitlab: 'GitLab', slack: 'Slack' };
    for (const el of document.querySelectorAll('button,a,[role="button"]')) {
      if (!shown(el)) continue;
      const t = ((el.innerText || '') + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase().replace(/\\s+/g, ' ').trim();
      if (t.length > 60) continue;
      const way = /(continue|log ?in|sign ?in|sign ?up)\\b.*\\b(with|using|via|through)\\b/.test(t);
      if (!way && !(form && /^(google|github|apple|microsoft|gitlab|slack)$/.test(t))) continue;
      for (const k in providers) if (t.includes(k) && !sso.includes(providers[k])) sso.push(providers[k]);
    }
    // The page's words, a line each, for telling what an action changed.
    const said = [];
    if (!ref && document.body) {
      const seen = new Set();
      for (const l of (document.body.innerText || '').split('\\n')) {
        const t = clean(l, 160);
        if (t && !seen.has(t)) { seen.add(t); said.push(t); if (said.length > 600) break; }
      }
    }
    // A text file, or JSON shown as text: no tree to speak of, so the text.
    // JSON shown as a tree (json-view.js) keeps WebKit's own body, hidden:
    // its innerText is the JSON as sent, never the tree.
    if (!ref && /^(text\\/plain|application\\/json|text\\/json|text\\/csv|application\\/[\\w.+-]*\\+json|application\\/x-ndjson)/.test(document.contentType || '')) {
      const all = (document.body ? document.body.innerText : '') || '';
      return { tree: 'document (' + document.contentType + ')\\n' + all.slice(0, LIMIT), truncated: all.length > LIMIT, needs, url: location.href, title: document.title, said, frames: [] };
    }
    return { tree: lines.join('\\n'), truncated: cut, needs, sso, url: location.href, title: document.title, said, frames, hidden };
    """

    /// The page's text as a person sees it: innerText less the words
    /// nobody can see, a pixel high, the page's own color, or off the
    /// screen, where pages hide instructions meant for agents.
    static let readable = """
    const all = document.body ? document.body.innerText : '';
    if (!document.body) return { text: '', hidden: 0 };
    const cache = new WeakMap();
    function bg(el) { for (let e = el; e; e = e.parentElement) { const b = getComputedStyle(e).backgroundColor; if (b && b !== 'rgba(0, 0, 0, 0)' && b !== 'transparent') return b; } return 'rgb(255, 255, 255)'; }
    function faint(el) {
      if (cache.has(el)) return cache.get(el);
      const s = getComputedStyle(el), r = el.getBoundingClientRect();
      const f = parseFloat(s.fontSize) < 4 || s.color === 'rgba(0, 0, 0, 0)' || r.right < -100 || s.color === bg(el);
      cache.set(el, f); return f;
    }
    let text = all, hidden = 0;
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(), i = 0; n && i < 20000; n = walk.nextNode(), i++) {
      const t = n.textContent.replace(/\\s+/g, ' ').trim();
      if (t.length < 4 || !n.parentElement || !faint(n.parentElement)) continue;
      const at = text.indexOf(t);
      if (at >= 0) { text = text.slice(0, at) + text.slice(at + t.length); hidden++; }
    }
    return { text, hidden };
    """

    // MARK: - acting

    /// Finds the element, brings it into view, and says where its middle is
    /// in the web view's points, or does the whole thing in script, for
    /// what has no middle to click.
    static let act = """
    const S = globalThis.__yab;
    let el = S && S.refs.get(ref);
    if (!el || !el.isConnected) {
      // A list the page redraws every few seconds took the element and put
      // back its twin. The one element with these same words is that twin;
      // short words ("Delete") could be another row's, so those are left.
      const mark = S && S.marks && S.marks.get(ref);
      const same = mark && mark.words.length >= 12 ? [...document.querySelectorAll(mark.tag)].filter(e => (e.getAttribute('aria-label') || e.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 120) === mark.words) : [];
      if (same.length !== 1) return { error: 'stale ref ' + ref + ', take a new snapshot' };
      el = same[0];
      S.refs.set(ref, el);
      S.ids.set(el, ref);
    }
    const win = el.ownerDocument.defaultView;
    // The element a point lands on, down through open shadow roots: a
    // button inside a web component is itself, not the component.
    function deepHit(doc, x, y) {
      let h = doc.elementFromPoint(x, y);
      while (h && h.shadowRoot) { const inner = h.shadowRoot.elementFromPoint(x, y); if (!inner || inner === h) break; h = inner; }
      return h;
    }
    function within(h) {
      for (let n = h; n; n = n.parentNode || n.host) if (n === el) return true;
      // A label over its own input, the way custom checkboxes are drawn.
      const l = h && h.closest && h.closest('label');
      return !!(l && (l.control === el || l.contains(el)));
    }
    function clean(s, n) { s = (s || '').replace(/\\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
    // What covers a point: a dialog, a banner, a sheet: something fixed or
    // modal, not an ancestor of the element.
    function overlay(h) {
      for (let n = h; n && n !== el.ownerDocument.body; n = n.parentElement || (n.getRootNode && n.getRootNode().host)) {
        if (n.contains && n.contains(el)) return null;
        const r = n.getAttribute && n.getAttribute('role');
        const pos = getComputedStyle(n).position;
        if (n.tagName === 'DIALOG' || r === 'dialog' || r === 'alertdialog' || n.getAttribute && n.getAttribute('aria-modal') === 'true' || pos === 'fixed' || pos === 'sticky') return n;
      }
      return null;
    }
    function point() {
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      let x = r.left + r.width / 2, y = r.top + r.height / 2;
      let hit = deepHit(el.ownerDocument, x, y);
      // A link over two lines has nothing of itself at its box's middle:
      // the middle of a line of it, then.
      if (!(hit && within(hit))) {
        for (const q of [...el.getClientRects()].slice(0, 4)) {
          const qx = q.left + q.width / 2, qy = q.top + q.height / 2;
          const h = deepHit(el.ownerDocument, qx, qy);
          if (h && within(h)) { x = qx; y = qy; hit = h; break; }
        }
      }
      const covered = !(hit && within(hit));
      const over = covered && hit ? overlay(hit) : null;
      // Up through same-origin frames to the top page's viewport.
      let w = win;
      while (w.frameElement) { const f = w.frameElement.getBoundingClientRect(); x += f.left; y += f.top; w = w.parent; }
      return { x, y, covered, over, w: r.width, h: r.height };
    }
    function describe(over) {
      const words = clean(over.getAttribute('aria-label') || (over.querySelector('h1,h2,h3,[role=heading]') || over).innerText, 70);
      const buttons = [...over.querySelectorAll('button,[role=button],a[href],input[type=submit],input[type=button]')].filter(b => b.getBoundingClientRect().width > 0).slice(0, 6);
      S.ids ||= new WeakMap();
      const named = buttons.map(b => {
        let id = S.ids.get(b);
        if (!id || S.refs.get(id) !== b) { id = (ref.match(/^f\\d+/) || [''])[0] + 'e' + (++S.n); S.ids.set(b, id); }
        S.refs.set(id, b);
        return id + ' "' + clean(b.getAttribute('aria-label') || b.innerText || b.value, 40) + '"';
      });
      return ref + ' is covered by “' + words + '”' + (named.length ? ': deal with it first (' + named.join(', ') + ')' : ': close it first');
    }
    function scriptClick() {
      // A primary mouse button's press, as a person's is: some pages act
      // only on that (a picker opened on pointerdown).
      for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
        const down = t.endsWith('down');
        el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, cancelable: true, composed: true, view: win,
          button: 0, buttons: down ? 1 : 0, pointerId: 1, pointerType: 'mouse', isPrimary: true }));
      }
      if (el.focus) el.focus();
      el.click();
    }
    if (action === 'label') {
      // Its words, for the step that presses it: a button's, a link's, a
      // field's label.
      const words = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || '';
      return { label: clean(words, 48) };
    }
    if (action === 'click') {
      const p = point();
      // What a person couldn't press, an agent doesn't either: it hears
      // what is in the way.
      if (p.over) return { error: describe(p.over), covered: true };
      if (p.covered || p.w === 0) { scriptClick(); return { done: 'script', covered: p.covered }; }
      // Watch for the real click to arrive, so a lost one is noticed.
      S.clicked = false;
      el.addEventListener('click', e => { if (e.isTrusted) S.clicked = true; }, { once: true, capture: true });
      return { x: p.x, y: p.y };
    }
    if (action === 'hover') {
      const p = point();
      if (p.w === 0) return { error: ref + ' has no size on the page' };
      // A page behind, or in a window that isn't in front, gets no pointer
      // moves from WebKit: the hover is made here as well. Every :hover
      // rule mirrored on an attribute put on the element and the ones
      // around it, and the events a resting pointer sends.
      const doc = el.ownerDocument;
      if (!doc.getElementById('__yab_hover')) {
        const out = [];
        const take = rules => { for (const r of rules) { if (r.cssRules && !r.selectorText) { if (r.media) { const inner = []; const keep = out.length; take(r.cssRules); const got = out.splice(keep); if (got.length) out.push('@media ' + r.media.mediaText + '{' + got.join('') + '}'); } else take(r.cssRules); } else if (r.selectorText && r.selectorText.includes(':hover')) out.push(r.selectorText.replace(/:hover/g, '[data-yab-hover]') + '{' + r.style.cssText + '}'); } };
        for (const sh of doc.styleSheets) { try { take(sh.cssRules); } catch (e) {} }
        const st = doc.createElement('style'); st.id = '__yab_hover'; st.textContent = out.join('\\n');
        (doc.head || doc.documentElement).appendChild(st);
      }
      const chain = []; for (let n = el; n && n.nodeType === 1; n = n.parentElement || (n.getRootNode && n.getRootNode().host)) chain.push(n);
      const before = S.hovered || [];
      const leaving = before.filter(n => !chain.includes(n));
      for (const n of leaving) { n.removeAttribute('data-yab-hover'); }
      if (before[0] && before[0] !== el && before[0].isConnected) for (const t of ['pointerout', 'mouseout']) before[0].dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, composed: true, view: win }));
      for (const n of leaving) for (const t of ['pointerleave', 'mouseleave']) n.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: false, view: win }));
      for (const n of chain) n.setAttribute('data-yab-hover', '');
      const box = el.getBoundingClientRect(), at = { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
      for (const t of ['pointerover', 'mouseover']) el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, composed: true, view: win, ...at }));
      for (const n of chain.filter(n => !before.includes(n)).reverse()) for (const t of ['pointerenter', 'mouseenter']) n.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: false, view: win, ...at }));
      for (const t of ['pointermove', 'mousemove']) el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, composed: true, view: win, ...at }));
      S.hovered = chain;
      return { x: p.x, y: p.y };
    }
    if (action === 'point') {
      const p = point();
      if (p.w === 0) return { error: ref + ' has no size on the page' };
      return { x: p.x, y: p.y, w: p.w, h: p.h };
    }
    // A click on the element itself, when a real one would land on
    // something over it (AgentPage.landing).
    if (action === 'script') { scriptClick(); return { done: 'script', covered: true }; }
    if (action === 'confirm') {
      if (S.clicked) return { done: 'mouse' };
      scriptClick(); return { done: 'script', lost: true };
    }
    if (action === 'type') {
      const kinds = /^(text|search|email|url|tel|password|number|date|time|datetime-local|month|week)$/;
      const fieldOf = e => (e.tagName === 'INPUT' && kinds.test(e.type || 'text')) || e.tagName === 'TEXTAREA';
      if (!fieldOf(el) && !el.isContentEditable) {
        // A wrapper around the one field it holds, a combobox's box.
        const inner = el.querySelector('input,textarea,[contenteditable=""],[contenteditable="true"]');
        if (inner && (fieldOf(inner) || inner.isContentEditable)) el = inner;
        else return { error: ref + ' takes no text: it is a ' + (el.getAttribute('role') || el.tagName.toLowerCase()) + '. Click it and pick from what opens, or use choose for a select' };
      }
      if (el.disabled || el.readOnly) return { error: ref + ' is ' + (el.disabled ? 'disabled' : 'read-only') };
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      el.focus();
      const field = fieldOf(el);
      if (field) { try { el.select(); } catch (e) { el.setSelectionRange && el.setSelectionRange(0, el.value.length); } }
      else { const range = el.ownerDocument.createRange(); range.selectNodeContents(el); const sel = win.getSelection(); sel.removeAllRanges(); sel.addRange(range); }
      // Through the editing machinery, the way a keyboard's text arrives:
      // React, ProseMirror and their kind all hear it.
      const doc = el.ownerDocument;
      if (!field && text) {
        // Draft (X's reply box) takes a keyboard's text from textInput,
        // which execCommand never sends: it let the browser's insertion
        // stand and drew its own copy beside it, the words twice and the
        // box past editing. Told the way a keyboard tells it, the editor
        // puts the words in itself, once it has seen the new selection;
        // where no editor takes it, WebKit inserts them.
        await new Promise(r => setTimeout(r, 30));
        const was = el.textContent;
        const said = doc.createEvent('TextEvent');
        said.initTextEvent('textInput', true, true, win, text);
        el.dispatchEvent(said);
        if (said.defaultPrevented || el.textContent !== was) {
          await new Promise(r => setTimeout(r, 30));
          return { done: 'typed' };
        }
      }
      const ok = text ? doc.execCommand('insertText', false, text) : doc.execCommand('delete');
      const now = field ? el.value : el.innerText.trim();
      if (!ok || (field && now !== text && now.replace(/\\s/g, '') !== text.replace(/\\s/g, ''))) {
        if (field) {
          const proto = el.tagName === 'TEXTAREA' ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { done: 'setter', value: el.value };
        }
        return { error: 'the text didn\\'t take in ' + ref + '; click it and type with press' };
      }
      return field && el.value !== text ? { done: 'typed', value: el.value } : { done: 'typed' };
    }
    if (action === 'choose') {
      if (el.tagName !== 'SELECT') return { error: ref + ' is not a select, click it and pick from what opens' };
      const opt = [...el.options].find(o => o.value === value || o.text.trim() === value) || [...el.options].find(o => o.text.toLowerCase().includes(String(value).toLowerCase()));
      if (!opt) return { error: 'no option ' + value + ', there are: ' + [...el.options].map(o => o.text.trim()).slice(0, 30).join(', ') };
      el.value = opt.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { done: opt.text.trim() };
    }
    if (action === 'scroll') {
      let box = el;
      while (box && box !== el.ownerDocument.documentElement) {
        const s = getComputedStyle(box);
        if (/(auto|scroll)/.test(s.overflowY) && box.scrollHeight > box.clientHeight) break;
        box = box.parentElement;
      }
      const target = box && box !== el.ownerDocument.documentElement ? box : win;
      const before = target === win ? win.scrollY : target.scrollTop;
      target.scrollBy(0, dy);
      const after = target === win ? win.scrollY : target.scrollTop;
      return { done: after === before ? 'at the end, nothing moved' : 'scrolled' };
    }
    if (action === 'focus') { el.focus(); return { done: 'focused' }; }
    return { error: 'no action ' + action };
    """

    /// Chromium owns a native producer even when its host view has no window.
    /// Only WebKit needs the legacy script fallback for a detached view.
    static func click(_ web: any PageHandle, x: Double, y: Double, flags: NSEvent.ModifierFlags = []) -> Bool {
        web.agentClick(x: x, y: y, flags: flags)
    }

    static func hover(_ web: any PageHandle, x: Double, y: Double) -> Bool {
        web.agentHover(x: x, y: y)
    }

    static func drag(_ web: any PageHandle, from: CGPoint, to: CGPoint, _ done: @escaping @MainActor (Bool) -> Void) {
        web.agentDrag(from: from, to: to, done: done)
    }

    static func insert(_ web: any PageHandle, _ text: String) {
        guard web.engine == .chromium || web.window != nil else { insertInScript(web, text); return }
        web.insertAgentText(text)
    }

    /// Nil when all keys were sent, otherwise what could not be read.
    static func press(_ web: any PageHandle, _ keys: String) -> String? {
        let strokes: [Stroke]
        switch AgentPage.strokes(keys) {
        case .success(let read): strokes = read
        case .failure(let trouble): return trouble.said
        }
        send(web, strokes)
        return nil
    }

    static func send(_ web: any PageHandle, _ strokes: [Stroke]) {
        guard web.engine == .chromium || web.window != nil else { pressInScript(web, strokes); return }
        web.sendAgentKeys(strokes)
    }
}

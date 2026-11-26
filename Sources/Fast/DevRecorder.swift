import AppKit
import SwiftUI
import WebKit

// Recorder, Chrome's panel of that name: what you do on the page written
// down as steps while it records, a click, a value typed, Return pressed,
// a page gone to; played back on the page, step by step; and copied as
// Chrome's own recording (its JSON, which Chrome's Recorder and Puppeteer
// replay) or as a list an agent can follow.
//
// It listens in yab's own world, where the page can't see it, and only
// while it records. A password is written down as typed, never what was
// typed: the recording can go anywhere, and whoever plays it types it.

@MainActor
final class Recorder: ObservableObject {
    struct Step: Identifiable, Equatable {
        enum Kind: String, CaseIterable { case navigate, click, doubleClick, hover, change, key, scroll, waitForElement, waitForExpression, setViewport }
        let id = UUID()
        var kind: Kind
        var selector = ""
        var value = ""
        /// What the page calls it: a link's words, a field's label.
        var label = ""
        var url = ""
        /// A password, a card's number or code, a one-time code: typed, but
        /// not kept.
        var secret = false
        /// It took the page elsewhere when it was recorded: played back,
        /// that navigation is waited for.
        var navigates = false
        var at = Date()
        var timeout = 5_000
        var width = 1200
        var height = 800
        var x = 0.0
        var y = 0.0
        var breakpoint = false
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var recording = false
    /// Stop drains the page's already-posted events before sealing the recording.
    @Published private(set) var stopping = false
    private var recordingSession = UUID().uuidString
    /// The step being played now.
    @Published private(set) var playing: Int?
    /// The step that couldn't be played, and why.
    @Published private(set) var failed: (step: UUID, why: String)?
    weak var tab: Tab?
    @Published var speed = 250
    @Published var paused = false
    @Published var importError = ""
    @Published var recordingTitle = "Recording"
    private var singleStep = false
    private var plays = 0
    var onFinish: (() -> Void)?

    func update(_ step: Step) { if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i] = step } }
    func insert(_ step: Step, after id: UUID? = nil) {
        let index = id.flatMap { id in steps.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? steps.count
        steps.insert(step, at: index)
    }
    func proceed(single: Bool = false) { singleStep = single; paused = false }


    // MARK: writing it down

    func start(_ tab: Tab) {
        recordingSession = UUID().uuidString
        stopping = false
        self.tab = tab
        stopPlaying()
        steps = []
        failed = nil
        recording = true
        if let url = tab.address { steps.append(Step(kind: .navigate, url: url.absoluteString)) }
        listen()
    }

    func stop(drain: Bool = true) {
        guard recording || stopping else { return }
        recording = false
        stopping = drain && tab?.webKitOnly("WebKit recorder runtime", build: false) != nil
        let session = recordingSession
        let script = "window.__yabRecording = false; window.webkit?.messageHandlers.\(RecordRelay.name)?.postMessage({k:'stopped',session:'\(session)'})"
        tab?.webKitOnly("WebKit recorder runtime", build: false)?.evaluateJavaScript(script, in: nil, in: Web.world) { [weak self] result in
            if case .failure = result, self?.recordingSession == session { self?.stopping = false }
        }
    }

    /// The page's script, in every new document while it records.
    func listen() {
        guard recording, let web = tab?.webKitOnly("WebKit recorder runtime", build: false) else { return }
        web.evaluateJavaScript("window.__yabRecordSession = '\(recordingSession)';" + Self.script, in: nil, in: Web.world) { _ in }
    }

    /// A new document: gone to by hand when nothing was done on the page
    /// just before, which a click or Return that led here would be.
    func committed(_ url: URL?) {
        guard recording, let url else { return }
        listen()
        if let last = steps.last {
            if last.kind == .navigate, last.url == url.absoluteString { return }
            // A click or a key just before led here; a value typed doesn't
            // take a page anywhere, so after one it was gone to by hand.
            if last.kind == .click || last.kind == .key, Date().timeIntervalSince(last.at) < 3 {
                steps[steps.count - 1].navigates = true
                steps[steps.count - 1].url = url.absoluteString
                return
            }
        }
        steps.append(Step(kind: .navigate, url: url.absoluteString))
    }

    /// A step the page's script heard.
    func heard(_ body: [String: Any]) {
        guard body["session"] as? String == recordingSession else { return }
        if body["k"] as? String == "stopped" { stopping = false; return }
        guard recording || stopping, let kind = (body["k"] as? String).flatMap(Step.Kind.init) else { return }
        var step = Step(kind: kind, selector: body["s"] as? String ?? "", value: body["v"] as? String ?? "",
                        label: body["t"] as? String ?? "", secret: body["secret"] as? Bool ?? false)
        if step.secret { step.value = "" }
        if kind == .change {
            // A value typed again in the same field, one step: its last value.
            if let last = steps.last, last.kind == .change, last.selector == step.selector {
                steps[steps.count - 1] = step
                return
            }
            // The same value said again as the field lets go of it, after
            // Return: written down already.
            if let before = steps.last(where: { $0.kind == .change && $0.selector == step.selector }), before.value == step.value,
               steps.suffix(3).contains(where: { $0.id == before.id }) { return }
        }
        steps.append(step)
    }

    func remove(_ id: UUID) {
        guard !recording, playing == nil else { return }
        steps.removeAll { $0.id == id }
    }

    func clear() {
        stop(drain: false)
        stopPlaying()
        steps = []
        failed = nil
    }

    // MARK: playing it back

    func play(_ tab: Tab) {
        guard !steps.isEmpty, playing == nil else { return }
        stop(drain: false)
        self.tab = tab
        failed = nil
        plays += 1
        let turn = plays
        Task { [weak self] in
            guard let self else { return }
            for (index, step) in self.steps.enumerated() {
                guard self.plays == turn else { return }
                self.playing = index
                if step.breakpoint { self.paused = true }
                while self.paused, self.plays == turn { try? await Task.sleep(for: .milliseconds(50)) }
                guard self.plays == turn else { return }
                let pauseAfter = self.singleStep; self.singleStep = false
                if let why = await self.run(step, on: tab) {
                    self.failed = (step.id, why)
                    break
                }
                if pauseAfter { self.paused = true }
            }
            if self.plays == turn { self.playing = nil; self.paused = false; self.onFinish?(); self.onFinish = nil }
        }
    }

    func stopPlaying() {
        plays += 1
        playing = nil
        paused = false
        onFinish?(); onFinish = nil
    }

    /// One step: nil when done, else what went wrong.
    private func run(_ step: Step, on tab: Tab) async -> String? {
        guard let web = tab.webKitOnly("WebKit recorder runtime", build: false) else { return "The page is gone" }
        switch step.kind {
        case .navigate:
            guard let url = URL(string: step.url) else { return "Not an address" }
            if web.url?.absoluteString == step.url { tab.reload() } else { tab.go(to: url) }
            return await settled(tab, started: true)
        case .setViewport:
            guard step.width > 0, step.height > 0 else { return "Viewport must be positive" }
            tab.setDevice(DeviceMode(name: DeviceMode.responsive, width: CGFloat(step.width), height: CGFloat(step.height), userAgent: nil, zoom: nil), remember: false)
            return nil
        case .click, .doubleClick, .hover, .change, .key, .scroll, .waitForElement, .waitForExpression:
            if step.secret { return "Enter this hidden value manually, then remove its change step before replay" }
            let js = "return await window.__yabPlay(\(Self.json(["k": step.kind.rawValue, "s": step.selector, "v": step.value, "timeout": String(step.timeout), "x": String(step.x), "y": String(step.y)])))"
            let was = web.url
            let result = try? await web.callAsyncJavaScript(Self.player + js, arguments: [:], in: nil, contentWorld: Web.world)
            let answer = result as? String ?? "The page didn’t answer"
            if !answer.isEmpty { return answer }
            // It took the page elsewhere when recorded: that is waited for,
            // however late the page starts it; else a moment for what the
            // page does with it.
            if step.navigates {
                let deadline = Date().addingTimeInterval(10)
                while !web.isLoading, web.url == was {
                    if Date() > deadline { return "The page didn’t go anywhere this time" }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(self.speed))
            }
            return await settled(tab, started: false)
        }
    }

    /// Until the page has loaded, for a navigation under way.
    private func settled(_ tab: Tab, started: Bool) async -> String? {
        let deadline = Date().addingTimeInterval(20)
        if started { try? await Task.sleep(for: .milliseconds(150)) }
        while tab.webKitOnly("WebKit recorder runtime", build: false)?.isLoading == true {
            if Date() > deadline { return "The page took too long to load" }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: copied

    /// Import data only; execution starts with an explicit Replay action.
    func importJSON(_ text: String) throws {
        guard let data = text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["steps"] as? [[String: Any]] else { throw ImportFailure("Expected a recording with a steps array") }
        var imported: [Step] = []
        for (index, row) in rows.enumerated() {
            let type = row["type"] as? String ?? ""
            if type == "keyUp" { continue }
            let kind = type == "keyDown" ? Step.Kind.key : Step.Kind(rawValue: type)
            guard let kind else { throw ImportFailure("Step \(index + 1): unsupported type \(type)") }
            if let frames = row["frame"] as? [Int], !frames.isEmpty { throw ImportFailure("Step \(index + 1): frame replay is not available") }
            let alternatives = row["selectors"] as? [[String]] ?? []
            guard alternatives.allSatisfy({ $0.count <= 1 }) else { throw ImportFailure("Step \(index + 1): multipart selectors are not available") }
            let selector = alternatives.compactMap(\.first).first(where: { !$0.hasPrefix("xpath/") }) ?? ""
            if [.click, .doubleClick, .hover, .change, .waitForElement].contains(kind), selector.isEmpty { throw ImportFailure("Step \(index + 1): no supported selector") }
            var step = Step(kind: kind, selector: selector, value: row["value"] as? String ?? row["key"] as? String ?? row["expression"] as? String ?? "", url: row["url"] as? String ?? "")
            step.timeout = min(60_000, max(100, row["timeout"] as? Int ?? 5_000))
            step.width = row["width"] as? Int ?? 1200; step.height = row["height"] as? Int ?? 800
            step.x = row["x"] as? Double ?? 0; step.y = row["y"] as? Double ?? 0
            step.navigates = !(row["assertedEvents"] as? [Any] ?? []).isEmpty && kind != .navigate
            if step.navigates { step.url = (row["assertedEvents"] as? [[String: Any]])?.first?["url"] as? String ?? "" }
            if selector.range(of: "password|cc-number|cc-csc|one-time-code", options: .regularExpression) != nil, kind == .change { step.secret = true; step.value = "" }
            imported.append(step)
        }
        guard imported.count <= 10_000 else { throw ImportFailure("Recording exceeds 10,000 steps") }
        clear(); recordingTitle = json["title"] as? String ?? "Imported recording"; steps = imported
    }

    struct ImportFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    func replayScript() -> String {
        "import {createRunner} from '@puppeteer/replay';\nconst recording = " + chromeJSON(title: recordingTitle) + ";\nconst runner = await createRunner(recording);\nawait runner.run();\n"
    }

    func puppeteerScript() -> String {
        var code = "import puppeteer from 'puppeteer';\nconst browser = await puppeteer.launch({headless: false});\nconst page = await browser.newPage();\n"
        func quoted(_ value: String) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), encoding: .utf8) ?? "\"\"" }
        for step in steps {
            let selector = quoted(step.selector), value = quoted(step.value)
            switch step.kind {
            case .navigate: code += "await page.goto(\(quoted(step.url)));\n"
            case .setViewport: code += "await page.setViewport({width: \(step.width), height: \(step.height)});\n"
            case .click: code += "await page.locator(\(selector)).click();\n"
            case .doubleClick: code += "await page.locator(\(selector)).click({clickCount: 2});\n"
            case .hover: code += "await page.locator(\(selector)).hover();\n"
            case .change: code += step.secret ? "// Fill the hidden field manually: \(selector)\n" : "await page.locator(\(selector)).fill(\(value));\n"
            case .key:
                if !step.selector.isEmpty { code += "await (await page.waitForSelector(\(selector), {timeout: \(step.timeout)})).focus();\n" }
                code += "await page.keyboard.press(\(value));\n"
            case .waitForElement: code += "await page.waitForSelector(\(selector), {timeout: \(step.timeout)});\n"
            case .waitForExpression: code += "await page.waitForFunction(\(value), {timeout: \(step.timeout)});\n"
            case .scroll: code += "await page.evaluate((s,x,y) => (s ? document.querySelector(s) : window).scrollTo(x,y), \(selector), \(step.x), \(step.y));\n"
            }
        }
        return code + "await browser.close();\n"
    }

    /// Chrome's own recording, which its Recorder and Puppeteer replay.
    func chromeJSON(title: String) -> String {
        var out: [[String: Any]] = []
        for step in steps {
            switch step.kind {
            case .navigate:
                out.append(["type": "navigate", "url": step.url, "assertedEvents": [["type": "navigation", "url": step.url]]])
            case .click:
                var row: [String: Any] = ["type": "click", "selectors": [[step.selector]], "offsetX": 1, "offsetY": 1]
                if step.navigates { row["assertedEvents"] = [["type": "navigation", "url": step.url]] }
                out.append(row)
            case .change:
                out.append(["type": "change", "value": step.secret ? "" : step.value, "selectors": [[step.selector]]])
            case .doubleClick: out.append(["type": "doubleClick", "selectors": [[step.selector]]])
            case .hover: out.append(["type": "hover", "selectors": [[step.selector]]])
            case .scroll: out.append(["type": "scroll", "x": step.x, "y": step.y, "selectors": step.selector.isEmpty ? [] : [[step.selector]]])
            case .waitForElement: out.append(["type": "waitForElement", "selectors": [[step.selector]], "timeout": step.timeout])
            case .waitForExpression: out.append(["type": "waitForExpression", "expression": step.value, "timeout": step.timeout])
            case .setViewport: out.append(["type": "setViewport", "width": step.width, "height": step.height, "deviceScaleFactor": 1, "isMobile": false, "hasTouch": false, "isLandscape": step.width > step.height])
            case .key:
                var row: [String: Any] = ["type": "keyDown", "key": step.value, "selectors": step.selector.isEmpty ? [] : [[step.selector]]]
                if step.navigates { row["assertedEvents"] = [["type": "navigation", "url": step.url]] }
                out.append(row)
                out.append(["type": "keyUp", "key": step.value])
            }
        }
        let whole: [String: Any] = ["title": title, "steps": out]
        guard let data = try? JSONSerialization.data(withJSONObject: whole, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The steps in words, for an agent to follow.
    func forAgent(page: URL?) -> String {
        var out = "## Steps recorded on \(DevCopy.where_(page))\n\n"
        for (index, step) in steps.enumerated() {
            out += "\(index + 1). \(Self.words(step))"
            if !step.selector.isEmpty { out += " (`\(step.selector)`)" }
            out += "\n"
        }
        return DevCopy.clean(out)
    }

    /// A step as the list says it.
    static func words(_ step: Step) -> String {
        let named = step.label.isEmpty ? "" : "“\(step.label)”"
        switch step.kind {
        case .navigate: return "Go to " + (URL(string: step.url).map { DevCopy.where_($0) } ?? step.url)
        case .click: return named.isEmpty ? "Click" : "Click \(named)"
        case .change:
            if step.secret { return "Type a hidden value" + (named.isEmpty ? "" : " in \(named)") }
            return "Type “\(step.value)”" + (named.isEmpty ? "" : " in \(named)")
        case .doubleClick: return "Double click " + named
        case .hover: return "Hover " + named
        case .scroll: return "Scroll to \(Int(step.x)), \(Int(step.y))"
        case .waitForElement: return "Wait for element " + step.selector
        case .waitForExpression: return "Wait for " + step.value
        case .setViewport: return "Set viewport to \(step.width) × \(step.height)"
        case .key: return "Press \(step.value == "Enter" ? "Return" : step.value)"
        }
    }

    private static func json(_ value: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: the page's side

    /// Listening in yab's world: a click on what can be clicked, a value
    /// committed, Return, Escape and Tab. Each with a selector that finds
    /// that one element: its test id, id, name or label, else its path.
    static let script = """
    (function () {
      window.__yabRecording = true;
      if (window.__yabRec) return;
      window.__yabRec = true;
      var h = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(RecordRelay.name);
      if (!h) return;
      function post(m) { if (window.__yabRecording) { m.session = window.__yabRecordSession; try { h.postMessage(m); } catch (e) {} } }
      function one(sel) { try { var roots=[document],count=0;for(var i=0;i<roots.length;i++){count+=roots[i].querySelectorAll(sel).length;for(var e of roots[i].querySelectorAll('*'))if(e.shadowRoot)roots.push(e.shadowRoot)}return count===1; } catch (e) { return false; } }
      function quote(v) { return '"' + String(v).replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"'; }
      function selector(el) {
        if (!(el instanceof Element)) return '';
        var tag = el.tagName.toLowerCase();
        var attrs = ['data-testid', 'data-test', 'data-qa', 'id', 'name', 'aria-label', 'placeholder', 'title', 'alt'];
        for (var i = 0; i < attrs.length; i++) {
          var v = el.getAttribute(attrs[i]);
          if (!v) continue;
          var sel = attrs[i] === 'id' ? '#' + CSS.escape(v) : tag + '[' + attrs[i] + '=' + quote(v) + ']';
          if (one(sel)) return sel;
        }
        var parts = [];
        for (var e = el; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
          if (e !== el && e.id && one('#' + CSS.escape(e.id))) { parts.unshift('#' + CSS.escape(e.id)); if (one(parts.join(' > '))) return parts.join(' > '); break; }
          var t = e.tagName.toLowerCase(), n = 1, s = e;
          while ((s = s.previousElementSibling)) if (s.tagName === e.tagName) n++;
          var same = e.parentElement ? Array.prototype.filter.call(e.parentElement.children, function (c) { return c.tagName === e.tagName; }).length : 1;
          parts.unshift(same > 1 ? t + ':nth-of-type(' + n + ')' : t);
          if (one(parts.join(' > '))) return parts.join(' > ');
        }
        return parts.join(' > ');
      }
      function recordedSelector(el) { return (el.getRootNode() instanceof ShadowRoot ? 'pierce/' : '') + selector(el); }
      function label(el) {
        var t = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || el.innerText || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || '';
        t = String(t).trim().replace(/\\s+/g, ' ');
        return t.length > 60 ? t.slice(0, 59) + '…' : t;
      }
      function field(el) { return el && /^(input|textarea|select)$/i.test(el.tagName) && !/^(checkbox|radio|submit|button|reset|file|image)$/i.test(el.type || ''); }
      // What is never written down: passwords, a card's number, code and
      // date, one-time codes, and what is named like them.
      function secretOf(el) {
        if ((el.type || '') === 'password') return true;
        var auto = String(el.getAttribute('autocomplete') || '');
        if (/cc-|one-time-code|current-password|new-password/.test(auto)) return true;
        var named = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].join(' ');
        return /card.?number|cardnum|cvc|cvv|csc|security.?code|otp|one.?time|passcode|pin\\b|ssn|iban/i.test(named);
      }
      function change(el) {
        if (!field(el)) return;
        var secret = secretOf(el);
        post({ k: 'change', s: recordedSelector(el), v: secret ? '' : String(el.value || '').slice(0, 2000), t: label(el), secret: secret });
      }
      var entered = 0;
      document.addEventListener('click', function (e) {
        if (!e.isTrusted) return;
        // The click a form gives its button when Return sends it: Return
        // is written down already.
        if (e.detail === 0 && Date.now() - entered < 1000) return;
        var t = e.composedPath ? e.composedPath()[0] : e.target;
        var el = t instanceof Element ? t : t && t.parentElement;
        if (!el) return;
        el = el.closest('a,button,input,select,textarea,label,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[onclick]') || el;
        if (field(el)) return;
        post({ k: 'click', s: recordedSelector(el), t: label(el) });
      }, true);
      document.addEventListener('change', function (e) { if (e.isTrusted) change(e.target); }, true);
      document.addEventListener('keydown', function (e) {
        if (!e.isTrusted || !/^(Enter|Escape|Tab)$/.test(e.key)) return;
        var el = e.target instanceof Element ? e.target : document.activeElement;
        // The value first: the field lets go of it only after the key.
        if (e.key !== 'Escape') change(el);
        if (e.key === 'Enter') entered = Date.now();
        post({ k: 'key', v: e.key, s: el ? recordedSelector(el) : '' });
      }, true);
    })();
    """

    /// Playing a step in yab's world: the element waited for, brought
    /// into view, and clicked, filled or pressed as a hand would.
    static let player = """
    if (!window.__yabPlay) window.__yabPlay = async function (step) {
      function wait(sel) {
        return new Promise(function (done) {
          var t0 = Date.now();
          (function look() {
            var el = null;
            try { if(sel?.startsWith('aria/'))el=Array.from(document.querySelectorAll('[aria-label],button,a,input')).find(e=>(e.getAttribute('aria-label')||e.innerText||'').trim()===sel.slice(5));else if(sel?.startsWith('text/'))el=Array.from(document.querySelectorAll('*')).find(e=>e.textContent.trim()===sel.slice(5)&&!Array.from(e.children).some(c=>c.textContent.trim()===sel.slice(5)));else if(sel?.startsWith('pierce/')){const roots=[document];for(let i=0;i<roots.length;i++)for(const e of roots[i].querySelectorAll('*'))if(e.shadowRoot)roots.push(e.shadowRoot);el=roots.map(r=>r.querySelector(sel.slice(7))).find(Boolean)}else el = sel ? document.querySelector(sel) : document.activeElement; } catch (e) { return done(null); }
            if (el) return done(el);
            if (Date.now() - t0 > (+step.timeout || 5000)) return done(null);
            setTimeout(look, 100);
          })();
        });
      }
      if (step.k === 'waitForExpression') {
        var end = Date.now() + (+step.timeout || 5000);
        do { try { if (Boolean((0, eval)(step.v))) return ''; } catch (e) { return e.message; } await new Promise(r => setTimeout(r, 100)); } while (Date.now() < end);
        return 'Expression did not become true';
      }
      if (step.k === 'scroll' && !step.s) { window.scrollTo(+step.x, +step.y); return ''; }
      var el = await wait(step.s);
      if (!el) return step.s ? 'Nothing on the page matches ' + step.s : 'Nothing has the keys';
      try { el.scrollIntoView({ block: 'center', inline: 'center' }); } catch (e) {}
      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      function mouse(type) { el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, view: window })); }
      function pointer(type) { try { el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, pointerType: 'mouse', isPrimary: true })); } catch (e) {} }
      if (step.k === 'waitForElement') return '';
      if (step.k === 'hover') { pointer('pointerover'); mouse('mouseover'); mouse('mouseenter'); return ''; }
      if (step.k === 'scroll') { el.scrollTo(+step.x, +step.y); return ''; }
      if (step.k === 'doubleClick') { el.click(); el.click(); mouse('dblclick'); return ''; }
      if (step.k === 'click') {
        pointer('pointerdown'); mouse('mousedown');
        if (el.focus) el.focus();
        pointer('pointerup'); mouse('mouseup');
        el.click();
        return '';
      }
      if (step.k === 'change') {
        if (el.focus) el.focus();
        var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        var set = Object.getOwnPropertyDescriptor(proto, 'value');
        if (set && set.set) set.set.call(el, step.v); else el.value = step.v;
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return '';
      }
      if (step.k === 'key') {
        var opts = { key: step.v, code: step.v, bubbles: true, cancelable: true, composed: true };
        var go = el.dispatchEvent(new KeyboardEvent('keydown', opts));
        el.dispatchEvent(new KeyboardEvent('keyup', opts));
        if (go && step.v === 'Enter' && el.form && /^(input)$/i.test(el.tagName)) {
          if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
        }
        return '';
      }
      return 'Not a step yab can play';
    };
    """
}

/// The recording script's messages, heard.
final class RecordRelay: NSObject, PageScriptReceiving {
    static let name = "yabRecord"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { tab?.recorder.heard(body) }
    }
}

/// The panel: record, play, copy, and the steps.
struct DevRecorder: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var recorder: Recorder
    @State private var editing: Recorder.Step?
    @State private var code = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if recorder.recording {
                    Button { recorder.stop() } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(DevLook.red).frame(width: 8, height: 8)
                            Text("Stop")
                        }
                    }
                    .buttonStyle(.yab(.secondary, .small))
                } else {
                    Button { recorder.start(tab) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(DevLook.red).frame(width: 8, height: 8)
                            Text(recorder.steps.isEmpty ? "Record" : "Record Again")
                        }
                    }
                    .buttonStyle(.yab(.secondary, .small))
                }
                if recorder.playing != nil {
                    if recorder.paused {
                        Button("Continue") { recorder.proceed() }.buttonStyle(.yab(.quiet, .small))
                        Button("Step") { recorder.proceed(single: true) }.buttonStyle(.yab(.quiet, .small))
                    }
                    Button("Stop Playing") { recorder.stopPlaying() }
                        .buttonStyle(.yab(.quiet, .small))
                } else {
                    Button { recorder.play(tab) } label: {
                        HStack(spacing: 6) {
                            Symbol("play.fill", size: 9)
                            Text("Replay")
                        }
                    }
                    .buttonStyle(.yab(.quiet, .small))
                    .disabled(recorder.steps.isEmpty || recorder.recording)
                }
                Spacer(minLength: 8)
                Menu("Recording") {
                    Button("Import JSON…") { importFile() }
                    Button("Save JSON…") { exportFile(recorder.chromeJSON(title: recorder.recordingTitle), extension: "json") }
                    Button("Copy JSON") { browser.copyForAgent(recorder.chromeJSON(title: recorder.recordingTitle), "Recording copied") }
                    Button("Export Puppeteer…") { exportFile(recorder.puppeteerScript(), extension: "mjs") }
                    Button("Export @puppeteer/replay…") { exportFile(recorder.replayScript(), extension: "mjs") }
                    Button("Copy for Agent") { browser.copyForAgent(recorder.forAgent(page: tab.address), "Copied for your agent") }
                    Divider()
                    Button(code ? "Hide code" : "Show code") { code.toggle() }
                    Button("Add assertion") { recorder.insert(.init(kind: .waitForElement, selector: "body")) }
                    Button("Add step") { recorder.insert(.init(kind: .click, selector: "button")) }
                    Button("Measure performance") {
                        browser.performanceRecord(true)
                        recorder.onFinish = { browser.performanceRecord(false); browser.pickDevPane(.performance) }
                        recorder.play(tab)
                    }.disabled(recorder.steps.isEmpty || recorder.recording || recorder.playing != nil)
                }.menuStyle(.borderlessButton).fixedSize()
                Menu("Speed") {
                    Button("Normal") { recorder.speed = 250 }
                    Button("Slow") { recorder.speed = 500 }
                    Button("Very slow") { recorder.speed = 1000 }
                    Button("Extremely slow") { recorder.speed = 2000 }
                }.menuStyle(.borderlessButton).fixedSize()
                Button { recorder.clear() } label: { Symbol("trash", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .disabled(recorder.steps.isEmpty)
                    .keyTip("Clear")
            }
            .font(.system(size: 11.5, weight: .medium))
            .focusable(false)
            .padding(.horizontal, DevLook.padding)
            .padding(.vertical, 3) // design: 24-point controls in a 30-point row, as Network's toolbar
            Rectangle().fill(Palette.ink.opacity(0.05)).frame(height: 1)
            if !recorder.steps.isEmpty {
                HStack(spacing: 8) {
                    Text("Name").foregroundStyle(Palette.muted)
                    TextField("Recording name", text: $recorder.recordingTitle).textFieldStyle(.plain)
                }.font(.system(size: 11.5)).padding(8)
                Divider()
            }
            if !recorder.importError.isEmpty { Text(recorder.importError).foregroundStyle(DevLook.red).font(.system(size: 12)).padding(8) }
            if code {
                ThreadScrollView { Text(recorder.chromeJSON(title: recorder.recordingTitle)).font(DevMono.font(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            } else if recorder.steps.isEmpty {
                DevQuiet(words: "Record, then use the page: each click, value typed and Return is written down here")
            } else {
                ScrollViewReader { reader in
                    ThreadScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(recorder.steps.enumerated()), id: \.element.id) { index, step in
                                row(step, index: index).id(step.id)
                            }
                        }
                    }
                    .onChange(of: recorder.steps.count) { _, _ in
                        if recorder.recording, let last = recorder.steps.last { reader.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .sheet(item: $editing) { step in DevRecorderStepEditor(step: step) { recorder.update($0); editing = nil } }
    }

    private func importFile() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.json]; picker.allowsMultipleSelection = false
        picker.begin { response in
            guard response == .OK, let url = picker.url else { return }
            do { try recorder.importJSON(String(contentsOf: url, encoding: .utf8)); recorder.importError = "" }
            catch { recorder.importError = error.localizedDescription }
        }
    }
    private func exportFile(_ text: String, extension suffix: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = recorder.recordingTitle + "." + suffix
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { recorder.importError = error.localizedDescription }
        }
    }
    private var title: String {
        "Recording on \(DevCopy.where_(tab.address)), " + Date().englishFormatted(date: .abbreviated, time: .shortened)
    }

    private func row(_ step: Recorder.Step, index: Int) -> some View {
        let now = recorder.playing == index
        let failed = recorder.failed?.step == step.id
        return HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(now ? Color.accentColor : failed ? DevLook.red : Palette.muted)
                .frame(width: 20, alignment: .trailing)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(Recorder.words(step))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                let detail = step.kind == .navigate ? step.url : step.selector
                if !detail.isEmpty {
                    Text(detail)
                        .font(DevMono.font(11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if failed, let why = recorder.failed?.why {
                    Text(why)
                        .font(.system(size: 11))
                        .foregroundStyle(DevLook.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !recorder.recording, recorder.playing == nil {
                Button { var changed = step; changed.breakpoint.toggle(); recorder.update(changed) } label: { Symbol(step.breakpoint ? "stop.circle.fill" : "stop.circle", size: 11) }.buttonStyle(.yab(.quiet, .small)).keyTip("Breakpoint")
                Button("Edit") { editing = step }.buttonStyle(.yab(.quiet, .small))
                Button { recorder.remove(step.id) } label: { Symbol("xmark", size: 11) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .focusable(false)
                    .keyTip("Remove Step")
            }
        }
        .padding(DevLook.padding)
        .background(now ? Color.accentColor.opacity(0.08) : failed ? DevLook.red.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink.opacity(0.05)).frame(height: 1) }
    }
}

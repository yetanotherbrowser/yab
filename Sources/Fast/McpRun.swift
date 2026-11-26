import Foundation
import JavaScriptCore

// `run`: a few steps in one call, written as code. The model writes a loop
// over pages, a form filled field by field, a list read until the row turns
// up, and gets back what it printed, instead of a round trip a step.
//
// The code runs here, in `yab mcp`, not in the page: every method is the
// tool of the same name, the same call into the browser, so everything a
// tool goes through a method goes through too. Send and Pay wait for the
// person, a tab they took is left alone, the agent's pointer shows. What
// the code can do beyond the tools is arithmetic.
//
// Deliberately small, and named for what it does rather than to pass for
// Playwright: a method that isn't there says which ones are.

enum McpRun {
    /// One context for the whole session: `keep` carries values from one
    /// run to the next.
    private static var context: JSContext?
    private static var printed = ""
    private static var outputLimit = 8000
    private static var truncated = false
    private static var calls = 0
    /// A native change this run left waiting for the person, whose session must outlive the run.
    private static var waiting: String?
    private static let budget = 200
    private static var tool: ((String, [String: Any]) -> [String: Any])!

    static let description = """
    Run JavaScript that drives tabs with the same tools, several steps in one call: loops over \
    pages, forms filled in a go, a list scrolled until a row shows. Each method is the tool of the \
    same name and goes through the same checks (Send, Pay and the like still wait for the user). \
    Synchronous (await is fine and does nothing). Print with console.log; the value you return is \
    printed too. A failed step throws with the tool's message.
      const t = open(url)            // or tab(id), tabs()
      t.snapshot({interactive})      // text; t.refs(/Invite/) → [{ref, line}], t.find('Save') → ref or null
      t.locate(['Email', 'Save'])    // one look, every name at once: {Email: 'e4', Save: null}
      t.eval(js) t.upload(ref, paths) t.download(ref)
      open(url).opened is the page's first snapshot; tab() with no id is the tab last opened
      t.click(ref) t.click({x, y}) t.type(ref, text, {submit}) t.type(text) t.choose(ref, value)
      t.press(keys) t.hover(ref) t.drag(ref, toRef) t.drag(ref, {dx, dy}) t.drag({x, y}, {x, y}) t.scroll(ref|null, dy)
      t.dialog(accept, text) t.text() t.wait(forText) t.navigate(url) t.fetch(url) t.show() t.close()
      sleep(ms), keep (an object that lasts between runs)
      native_context(query|{…}) native_actions(query) native_apply({action, target, arguments, requestId})
      native_operation(id) native_undo(changeId): Yab's own settings, as parsed JSON
      native_apply waits up to 30 seconds for the user's yes, then throws "status: needs_user" with its operationId
    Each action returns what changed on the page, as the tool does. At most \(200) steps a run.
    outputLimit bounds printed text (8000 characters by default, 256–32000); print only the result you need.
    A promise that remains pending is an error; there are no background JavaScript tasks here.
    """

    static func run(_ code: String, outputLimit: Int = 8000, tool: @escaping (String, [String: Any]) -> [String: Any]) -> [String: Any] {
        guard (256...32000).contains(outputLimit) else {
            return ["content": [["type": "text", "text": "outputLimit must be 256 to 32000 characters."]], "isError": true]
        }
        self.tool = tool
        self.outputLimit = outputLimit
        printed = ""
        truncated = false
        calls = 0
        waiting = nil
        let js = context ?? make()
        context = js
        defer { self.tool = nil; js.exceptionHandler = nil }
        var failed: String?
        var completed = false
        js.exceptionHandler = { _, value in failed = value?.toString() }
        js.setObject(unsafeBitCast({ (message: String) in failed = message } as @convention(block) (String) -> Void, to: AnyObject.self),
                     forKeyedSubscript: "__fail" as NSString)
        js.setObject(unsafeBitCast({ completed = true } as @convention(block) () -> Void, to: AnyObject.self),
                     forKeyedSubscript: "__completed" as NSString)
        let wrapped = """
        (async () => {
        \(code)
        })().then(v => { if (v !== undefined) console.log(typeof v === 'string' ? v : JSON.stringify(v, null, 1)); })
            .catch(e => __fail(e && e.message ? e.message : String(e)))
            .finally(() => __completed());
        """
        js.evaluateScript(wrapped)
        if !completed, failed == nil {
            failed = "The script left an unresolved promise. No background JavaScript runs between calls; keep was reset."
            context = nil
        }
        js.setObject(nil, forKeyedSubscript: "__fail" as NSString)
        js.setObject(nil, forKeyedSubscript: "__completed" as NSString)
        var out = printed
        if let failed {
            let error = "Error: " + failed
            let message = String(error.prefix(outputLimit))
            let room = max(0, outputLimit - message.count - 1)
            if error.count > outputLimit || printed.count > room { truncated = true }
            let prior = String(printed.prefix(room))
            out = (prior.isEmpty ? "" : prior + "\n") + message
        }
        let characters = out.count
        if truncated { out += "\n… (cut at \(outputLimit) characters: print less, or pick what you need)" }
        let footer = "(\(calls) step\(calls == 1 ? "" : "s"))"
        var metadata: [String: Any] = ["steps": calls, "outputCharacters": characters, "truncated": truncated]
        if let waiting { metadata["waitingOperation"] = waiting }
        if failed != nil {
            return ["content": [["type": "text", "text": out + "\n" + footer]], "isError": true, "structuredContent": metadata]
        }
        return ["content": [["type": "text", "text": (out.isEmpty ? "Done, nothing printed." : out) + "\n" + footer]], "isError": false, "structuredContent": metadata]
    }

    private static func make() -> JSContext {
        let js = JSContext()!
        let call: @convention(block) (String, String) -> String = { name, json in
            calls += 1
            if calls > budget { return #"{"error":"more than \#(budget) steps in one run; stop here, and run again for the rest"}"# }
            let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            let got = tool(name, input)
            let text = (got["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            let answer: [String: Any] = got["isError"] as? Bool == true ? ["error": text] : ["text": text]
            return (try? JSONSerialization.data(withJSONObject: answer)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        let log: @convention(block) (String) -> Void = { message in
            let separator = printed.isEmpty ? "" : "\n"
            let room = max(0, outputLimit - printed.count)
            let line = separator + message
            if line.count > room { truncated = true }
            printed += line.prefix(room)
        }
        let nap: @convention(block) (Double) -> Void = { usleep(useconds_t(max(0, min($0, 20000)) * 1000)) }
        let wait: @convention(block) (String) -> Void = { waiting = $0 }
        js.setObject(unsafeBitCast(wait, to: AnyObject.self), forKeyedSubscript: "__waiting" as NSString)
        js.setObject(unsafeBitCast(call, to: AnyObject.self), forKeyedSubscript: "__call" as NSString)
        js.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)
        js.setObject(unsafeBitCast(nap, to: AnyObject.self), forKeyedSubscript: "sleep" as NSString)
        js.evaluateScript(prelude)
        return js
    }

    private static let prelude = #"""
    var keep = {};
    var console = { log: (...a) => __log(a.map(x => typeof x === 'string' ? x : JSON.stringify(x, null, 1)).join(' ')) };
    console.error = console.warn = console.info = console.log;
    function __tool(name, input) {
      const got = JSON.parse(__call(name, JSON.stringify(input)));
      if (got.error !== undefined) throw new Error(got.error);
      return got.text;
    }
    const METHODS = ['id', 'snapshot', 'refs', 'find', 'opened', 'locate', 'eval', 'upload', 'download', 'click', 'type', 'choose', 'press', 'hover', 'drag', 'scroll', 'dialog', 'text', 'wait', 'navigate', 'fetch', 'show', 'close'];
    function tab(id = keep.__last) {
      if (!id) throw new Error('no tab yet: const t = open(url)');
      const t = {
        id,
        opened: '',
        snapshot(o = {}) { return __tool('snapshot', { tab: id, ...o }); },
        refs(pattern, o = {}) {
          const re = pattern instanceof RegExp ? pattern : new RegExp(String(pattern).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
          return this.snapshot(o).split('\n').map(l => l.trim()).filter(l => re.test(l))
            .map(l => { const m = l.match(/^((?:f\d+)?e\d+) /); return m ? { ref: m[1], line: l } : null; }).filter(Boolean);
        },
        find(pattern, o = {}) { const r = this.refs(pattern, o); return r.length ? r[0].ref : null; },
        locate(names, o = {}) {
          const lines = this.snapshot(o).split('\n').map(l => l.trim());
          return Object.fromEntries(names.map(name => {
            const word = String(name).toLowerCase();
            const line = lines.find(l => /^(?:f\d+)?e\d+ /.test(l) && l.toLowerCase().includes(word));
            return [name, line ? line.split(' ')[0] : null];
          }));
        },
        eval(js) { return __tool('eval', { tab: id, js }); },
        upload(ref, paths) { return __tool('upload', { tab: id, ref, files: [].concat(paths) }); },
        download(ref) { return __tool('download', { tab: id, ref }); },
        click(ref) { return typeof ref === 'object' && ref ? __tool('click', { tab: id, x: ref.x, y: ref.y }) : __tool('click', { tab: id, ref }); },
        type(ref, text, o = {}) { return text === undefined || typeof text === 'object' ? __tool('type', { tab: id, text: ref, ...(text || {}) }) : __tool('type', { tab: id, ref, text, ...o }); },
        choose(ref, value) { return __tool('choose', { tab: id, ref, value: String(value) }); },
        press(keys) { return __tool('press', { tab: id, keys }); },
        hover(ref) { return __tool('hover', { tab: id, ref }); },
        drag(ref, to) {
          if (ref && typeof ref === 'object' && to && typeof to === 'object') return __tool('drag', { tab: id, x: ref.x, y: ref.y, toX: to.x, toY: to.y });
          return to && typeof to === 'object' ? __tool('drag', { tab: id, ref, dx: to.dx || 0, dy: to.dy || 0 }) : __tool('drag', { tab: id, ref, to });
        },
        scroll(ref, dy = 600) { return ref ? __tool('scroll', { tab: id, ref, dy }) : __tool('scroll', { tab: id, dy }); },
        dialog(accept = true, text) { return __tool('dialog', { tab: id, accept, text }); },
        text() { return __tool('text', { tab: id }); },
        wait(words, seconds) { return __tool('wait', { tab: id, for: words, seconds }); },
        navigate(url) { return __tool('navigate', { tab: id, url }); },
        fetch(url) { return __tool('fetch', { tab: id, url }); },
        show() { return __tool('show', { tab: id }); },
        close() { return __tool('close', { tab: id }); },
      };
      return new Proxy(t, { get(o, k) {
        if (k in o || typeof k === 'symbol' || k === 'then' || k === 'toJSON') return o[k];
        throw new Error('a tab has no ' + String(k) + '; it has: ' + METHODS.join(', '));
      } });
    }
    function open(url) {
      const said = __tool('open', { url });
      const m = said.match(/tab: (\w+)/);
      if (!m) throw new Error(said);
      keep.__last = m[1];
      const t = tab(m[1]);
      t.opened = said;
      return t;
    }
    function tabs() {
      return __tool('tabs', {}).split('\n').map(l => { const m = l.match(/^(\w+) \[(\w+)\]/); return m ? { id: m[1], whose: m[2], line: l } : null; }).filter(Boolean);
    }
    function __native(name, input) {
      const said = __tool(name, input);
      try { return JSON.parse(said); } catch (e) { return said; }
    }
    function native_context(o = {}) { return __native('native_context', typeof o === 'string' ? { query: o } : o); }
    function native_actions(query) { return __native('native_actions', query ? { query: String(query) } : {}); }
    function native_apply(o) {
      const waits = r => r && ['needs_user', 'running', 'prepared'].includes(r.status) && r.operationId;
      let r = __native('native_apply', o);
      for (let i = 0; i < 3 && waits(r); i++) r = __native('native_operation', { operationId: r.operationId, seconds: 10 });
      if (!waits(r)) return r;
      __waiting(r.operationId);
      throw new Error('status: needs_user, operationId: ' + r.operationId + '. The change still waits for the user in Yab.');
    }
    function native_operation(o) { return __native('native_operation', typeof o === 'string' ? { operationId: o } : o); }
    function native_undo(changeId) { return __native('native_undo', changeId ? { changeId: String(changeId) } : {}); }
    var page = new Proxy({}, { get(o, k) { throw new Error('there is no page here: const t = open(url), or tab(id), then t.' + String(k) + '(…)'); } });
    """#
}

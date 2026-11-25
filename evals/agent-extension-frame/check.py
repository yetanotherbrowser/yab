#!/usr/bin/env python3
"""An agent keeps a Chromium page while a password manager's frame is on it.

A real extension (./extension) opens its own frame on a local page, in the two
shapes password managers use: at height 0 as soon as a login page loads
(1Password's sign-in frame), and as a visible list under a field once one is
focused. The frame holds text only it should see and reports the focus,
key, input, pointer, click and message events it gets to this script's server.

An agent session, through the bench socket as `yab mcp` speaks it, then reads
and acts on the page. It checks that:

- reading, and clicking, typing and downloading by ref, go on, and nothing
  from the frame is in any answer;
- a click by ref on an element under the list, on the page or in a
  same-site or cross-site frame, a download by ref on the page or in a
  same-site frame, and an upload by ref on the page, never reach the list;
- eval, screenshots, saving the page, keys, a click at a point, typing
  with no ref, and hover, drag and type with submit even by ref are refused
  while the frame is open; eval, screenshots, keys and a click at a point work
  again once it closes, and so does saving the page;
- a navigation that opens the frame again is refused again, and a ref taken
  before it never reaches the frame;
- the frame never hears from the agent, though it does hear a real click,
  typing, a page script's message and its own page being marked, all sent by
  this script, so its silence counts;
- the extension's own page stays refused for reading, typing, keys, eval,
  screenshots and a click at a point;
- a click or download by ref whose page asks a question (confirm) is
  answered at once, and a click whose page asks before it goes out is never
  sent.

    python3 evals/agent-extension-frame/check.py --app "build/yab Dev.app" --out OUT

Needs a Yab Dev built with CEF (CONTRIBUTING.md, Chromium tabs). It opens its
own probe world, so it never touches your Yab Dev profile. Keep the pointer
off its window while it runs: the frame logs real pointer moves.
"""
import argparse
import http.server
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import yab_socket

SECRETS = ("VAULT_TEXT_ONLY_THE_EXTENSION_SEES", "VAULT_FIELD_ONLY_THE_EXTENSION_SEES")
HEARD = []
# The only words that leave the app when the guard says no (AgentSecrets.swift).
FRAME_REFUSAL = ("Yab won't take a picture of this page, run a script on it, click at a point or press keys outside a ref "
                 "while an extension's own window is open on it (a password manager's or wallet's). Read the page and act "
                 "on it by refs meanwhile; the rest works again once that window closes.")
PAGE_REFUSAL = ("Yab keeps agents off this page because it is an extension's own page (a password manager, wallet or other "
                "extension). The person must handle it; continue after they leave this page.")
# A page's own frame, under where the list opens (left 20, top 140, 320 by 160).
INNER = """<!doctype html><meta charset="utf-8"><body style="margin:0">
<button id="inner" type="button" style="position:absolute;left:10px;top:40px;width:200px;height:60px"
        onclick="this.textContent='Pressed'">Inside the frame</button>
<a id="get" href="/file.txt" download style="position:absolute;left:10px;top:110px;width:120px;height:30px;display:block">Get the file</a>"""
LEFT_OUT = "(an extension's own window, a password manager's or wallet's: left out)"

LOGIN = """<!doctype html><meta charset="utf-8"><title>Sign in</title>
<h1>Sign in</h1>
<form action="/done" onsubmit="return false">
  <label>Email <input id="email" type="email" autocomplete="username"></label>
  <label>Password <input id="password" type="password" autocomplete="current-password"></label>
  <button id="go" type="button" onclick="this.textContent='Clicked'">Continue</button>
  <button id="ask" type="button" onclick="fetch('/log', { method: 'POST', body: JSON.stringify({ kind: 'asking', trusted: event.isTrusted }) });
                this.textContent = confirm('Keep going?') ? 'Kept' : 'Stopped'">Ask first</button>
</form>
<button id="under" type="button" style="position:absolute;left:60px;top:200px"
        onclick="this.textContent='Pressed'">Under the list</button>
<a href="/list.txt" download style="position:absolute;left:60px;top:250px">Save the list</a>
<button id="attach" type="button" style="position:absolute;left:200px;top:250px"
        onpointerdown="if (!event.isPrimary || event.buttons !== 1) return;
                       const f = document.createElement('input'); f.type = 'file';
                 f.onchange = () => this.textContent = 'Attached ' + f.files[0].name; f.click()">Attach a file</button>
<a href="/asked.txt" download onclick="fetch('/log', { method: 'POST', body: JSON.stringify({ kind: 'saving', trusted: event.isTrusted }) });
   return confirm('Save it?')">Save after asking</a>"""


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body, kind = LOGIN, "text/html"
        if self.path.split("?")[0].endswith(".txt"):
            body, kind = "a file to download\n", "text/plain"
        elif self.path.startswith("/inner"):
            body = INNER
        elif self.path.startswith("/late"):
            # Asks while the pointer is on its way (0.45 s in a tab in
            # front): the scroll that brings the button into view starts it.
            body = LOGIN + ("<button id=\"late\" type=\"button\" style=\"position:absolute;left:60px;top:2400px\" "
                            "onclick=\"this.textContent='Pressed'\">Ask on the way</button>"
                            "<script>addEventListener('scroll', () => setTimeout(() => confirm('Stay?'), 250), { once: true })</script>")
        elif self.path.startswith("/sandboxed"):
            body = LOGIN + ('<iframe sandbox srcdoc="<p>no scripts here</p>"></iframe>'
                            '<iframe loading="lazy" src="/inner" style="margin-top:3000px"></iframe>')
        elif self.path.startswith("/framed"):
            # ?inner=URL: the page's own frame, same site or another.
            inner = dict(p.split("=", 1) for p in self.path.split("?", 1)[-1].split("&") if "=" in p).get("inner", "/inner")
            body = LOGIN + ('<iframe src="' + urllib.parse.unquote(inner) + '" style="position:absolute;left:20px;top:140px;'
                            'width:320px;height:160px;border:0"></iframe>')
        body = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        if self.path.startswith("/log"):
            try:
                HEARD.append(json.loads(self.rfile.read(size)))
            except ValueError:
                pass
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def log_message(self, *_):
        pass


def leaks(reply):
    text = json.dumps(reply)
    return [s for s in SECRETS if s in text]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    app = Path(args.app)
    binary = app / "Contents/MacOS/yab"

    server = yab_socket.serve(Pages)
    site = f"http://127.0.0.1:{server.server_address[1]}"
    world = "agent-extension-frame-" + uuid.uuid4().hex[:8]
    domain = "dev.serafim.fast.test." + world
    defaults = out / "defaults.plist"
    # agents.asking bypass: an upload goes on without a person's yes.
    defaults.write_bytes(plistlib.dumps({"bench": True, "welcomed": True, "mail": False, "agents.asking": "bypass",
                                         "hints.noticing": False, "searchSuggest": False}))
    subprocess.run(["defaults", "import", domain, str(defaults)], check=True)
    log = (out / "app.log").open("w")
    proc = subprocess.Popen([str(binary)], stdout=log, stderr=subprocess.STDOUT,
                            env=dict(os.environ, YAB_PROBE=world, YAB_HISTORY="own", YAB_ENGINE="chromium",
                                     YAB_AGENT_CLAUDE="/usr/bin/true", YAB_AGENT_CODEX="/nonexistent"))
    sock = yab_socket.socket_path(world)
    raw = yab_socket.kwasker(sock, timeout=45, takes_timeout=True)
    calls = []
    checks = {}
    report = {"app": str(app), "world": world, "checks": checks, "calls": calls, "heard": HEARD}

    def ask(**request):
        started = time.time()
        reply = raw(**request)
        calls.append({"request": request, "reply": reply, "seconds": round(time.time() - started, 2)})
        print(f"  {request.get('do')} {time.time() - started:.1f}s {json.dumps(reply)[:160]}", flush=True)
        (out / "report.json").write_text(json.dumps(report, indent=2, default=str))
        return reply


    def check(name, ok, detail=None):
        checks[name] = bool(ok)
        print(("PASS " if ok else "FAIL ") + name + ("" if ok or detail is None else f"  {json.dumps(detail)[:300]}"))

    def refused(reply, words=FRAME_REFUSAL):
        # The fixed reason and nothing else: no page words ride along.
        return reply == {"error": words}

    def settled(mark, seconds=1.0):
        # A frame's report is a fetch: give one that was sent time to land.
        time.sleep(seconds)
        return heard_since(mark)

    quiet_windows = []

    def quiet(mark):
        # A silence check. Its window is kept: a report that lands later is
        # still caught by its own time (`at`) at the end.
        heard = settled(mark)
        if not heard:
            quiet_windows.append((mark.at, time.time()))
        return not heard

    class Mark(int):
        pass

    def mark_now():
        m = Mark(len(HEARD))
        m.at = time.time()
        return m

    try:
        yab_socket.wait_for(lambda: sock.exists() if proc.poll() is None else True, 90)
        if proc.poll() is not None:
            raise RuntimeError("Yab Dev quit at launch, see app.log")
        yab_socket.wait_for(lambda: "error" not in raw(do="tabs"), 30)
        ask(do="ui", welcome=False)

        # The extension, loaded unpacked into the Chromium profile.
        host = ask(do="usage-open", url=site + "/plain")["id"]
        yab_socket.wait_for(lambda: ask(do="page-engine", id=host).get("engine") == "chromium", 60)
        loaded = ask(do="chromium", id=host, op="extensions", method="extension.load",
                     params={"path": str(HERE / "extension")})
        listed = ask(do="chromium", id=host, op="extensions", method="extension.list")
        report["extension"] = {"loaded": loaded, "listed": listed}
        rows = listed.get("value") or []
        ext = next((r.get("id") for r in rows if isinstance(r, dict) and r.get("name") == "Vault frame fixture"), None)
        check("extension_loaded", ext, listed)
        if not ext:
            raise RuntimeError("the fixture extension did not load: " + json.dumps(report["extension"])[:500])

        session = ask(do="agent-attach", name="extension-frame-check")["session"]

        def agent(verb, **fields):
            return ask(do=verb, session=session, **fields)

        def heard_since(mark):
            # By arrival: a report that lands late is never dropped (at worst a
            # slow control's report fails the next window, never passes it).
            return [e for e in HEARD[mark:] if e.get("kind") not in ("loaded", "ready")]

        def opened(url, name):
            # An agent tab on a fixture page, once the extension's script is in it.
            mark = mark_now()
            tab = agent("open", url=url)["id"]
            check(f"{name}_page_ready", yab_socket.wait_for(lambda: any(e.get("kind") == "ready" and e.get("href") == url for e in HEARD[mark:]), 20), url)
            return tab

        def frame_loaded(mark):
            return yab_socket.wait_for(lambda: any(e.get("kind") == "loaded" for e in HEARD[mark:]), 20)

        def downloaded(got, name):
            # `ok` means the click went out; the file landing is the proof
            # (as the MCP download tool waits for it, McpToolsPage).
            if got.get("ok") is not True:
                return None
            # Polled raw (not logged); the last answer goes in the report.
            request = {"do": "agent-downloads", "session": session, "after": got.get("before", 0)}
            seen = {}

            def poll():
                seen["reply"] = raw(**request)
                if leaks(seen["reply"]):
                    calls.append({"request": request, "reply": seen["reply"]})
                return [f for f in seen["reply"].get("files", []) if f.get("done")]
            files = yab_socket.wait_for(poll, 20)
            calls.append({"request": request, "reply": seen["reply"]})
            return files and Path(files[0]["path"]).name == name and not files[0]["failed"]

        def pdfs():
            return {str(f) for f in yab_socket.support(world).rglob("*.pdf")}

        def page(tab, js):
            # The harness's own script, not the agent's: sets the scene and reads back.
            return ask(do="eval", id=tab, js=js)

        def ref_of(snapshot, label):
            # A tree line reads `e1 textbox "Email" ...`: the ref comes first.
            for line in (snapshot.get("tree") or "").splitlines():
                if f'"{label}"' in line:
                    return line.split()[0]
            return None

        def screen(tab, x, y):
            # An agent's point is in a 1024-wide screenshot's pixels (AgentCoordinates).
            scale = 1024 / page(tab, "innerWidth")["value"]
            return {"x": x * scale, "y": y * scale}

        # What an agent's eval tries: mark the page and write to every frame
        # it can find. Refused, neither happens.
        TRY = ("(() => { document.body.dataset.agentRan = '1';"
               " for (const f of document.querySelectorAll('iframe')) f.contentWindow.postMessage('from-agent', '*');"
               " return document.title; })()")

        def ran(tab):
            return page(tab, "document.body.dataset.agentRan || ''").get("value") == "1"

        def never_ran(tab):
            # A clean read that finds no mark, not a failed read.
            return page(tab, "document.body.dataset.agentRan || ''") == {"value": ""}

        # 1. Hidden frame on load, as 1Password does on a login page.
        mark = mark_now()
        tab = opened(site + "/login?vault=hidden", "hidden")
        check("hidden_frame_loaded", frame_loaded(mark))
        mark = mark_now()
        snap = agent("snapshot", id=tab, interactive=True)
        check("hidden_snapshot_allowed", "error" not in snap, snap)
        email = ref_of(snap, "Email")
        go = ref_of(snap, "Continue")
        typed = agent("act", id=tab, ref=email, action="type", text="agent@example.test")
        check("hidden_type_by_ref", "error" not in typed and page(tab, "document.querySelector('#email').value").get("value") == "agent@example.test", typed)
        clicked = agent("act", id=tab, ref=go, action="click")
        # Nothing over it, though the hidden frame is on the page: a real
        # click (the frame hearing nothing is checked below).
        check("hidden_click_by_ref", clicked == {"done": "mouse"} and page(tab, "document.querySelector('#go').textContent").get("value") == "Clicked", clicked)
        # The step that finishes a click in script isn't an action an agent
        # can send: it would skip the click's approval.
        got = agent("act", id=tab, ref=ref_of(snap, "Under the list"), action="script")
        check("hidden_act_script_refused", got == {"error": "no action script"}
              and page(tab, "document.querySelector('#under').textContent").get("value") == "Under the list", got)
        text = agent("text", id=tab)
        check("hidden_text_allowed", "Sign in" in str(text.get("text", "")), text)
        waited = agent("wait", id=tab, text="Sign in", seconds=5)
        check("hidden_wait_for_text_allowed", "error" not in waited and not waited.get("timeout") and waited.get("title") == "Sign in", waited)
        for name, verb, fields in [("eval", "agent-eval", {"js": TRY}), ("shot", "shot", {"width": 800, "inline": True}),
                                   ("press", "press", {"keys": "Tab"}), ("point_click", "act", {"action": "click", **screen(tab, 100, 10)})]:
            got = agent(verb, id=tab, **fields)
            check(f"hidden_{name}_refused", refused(got), got)
        check("hidden_eval_never_ran", never_ran(tab))
        check("hidden_frame_heard_nothing", quiet(mark), heard_since(mark))

        # Closed by the extension: everything works again. Opened again: refused again.
        page(tab, "document.dispatchEvent(new Event('vault-fixture-close'))")
        closed = yab_socket.wait_for(lambda: agent("agent-eval", id=tab, js=TRY).get("value") == "Sign in", 10)
        # The same script that was refused runs now, and leaves its mark.
        check("closed_eval_allowed", closed and ran(tab))
        picture = agent("shot", id=tab, width=400, inline=True)
        check("closed_shot_allowed", str(picture.get("data", "")).startswith("/9j/") and len(picture["data"]) > 1000, picture)
        page(tab, "document.querySelector('#email').focus()")
        pressed = agent("press", id=tab, keys="Tab")
        check("closed_press_allowed", "error" not in pressed and
              page(tab, "document.activeElement.id").get("value") == "password", pressed)
        box = page(tab, "(r => [r.left + r.width / 2, r.top + r.height / 2])(document.querySelector('#under').getBoundingClientRect())")["value"]
        hit = agent("act", id=tab, action="click", **screen(tab, *box))
        before = pdfs()
        printed = agent("agent-pdf", id=tab)
        check("closed_pdf_allowed", "error" not in printed and yab_socket.wait_for(lambda: pdfs() - before, 15), printed)
        check("closed_point_click_allowed", "error" not in hit and
              page(tab, "document.querySelector('#under').textContent").get("value") == "Pressed", hit)
        mark = mark_now()
        page(tab, "document.dispatchEvent(new Event('vault-fixture-open'))")
        check("reopened_frame_loaded", frame_loaded(mark))
        page(tab, "delete document.body.dataset.agentRan")
        mark = mark_now()
        check("reopened_eval_refused", refused(agent("agent-eval", id=tab, js=TRY)))
        check("reopened_eval_never_ran", never_ran(tab))
        check("reopened_frame_heard_nothing", quiet(mark), heard_since(mark))

        # A ref taken before going to a page that opens the frame again.
        page(tab, "document.dispatchEvent(new Event('vault-fixture-close'))")
        stale = agent("snapshot", id=tab, interactive=True)
        old = ref_of(stale, "Email")
        mark = mark_now()
        went = agent("agent-go", id=tab, url=site + "/login?vault=hidden&again=1")
        check("went_frame_loaded", "error" not in went and frame_loaded(mark), went)
        mark = mark_now()
        after = agent("act", id=tab, ref=old, action="type", text="stale")
        report["stale_after_navigation"] = after
        check("stale_ref_refused", old is not None and after == {"error": f"stale ref {old}, take a new snapshot"}, after)
        check("stale_ref_typed_nothing", page(tab, "document.querySelector('#email').value").get("value") == "")
        check("went_eval_refused", refused(agent("agent-eval", id=tab, js=TRY)))
        check("went_eval_never_ran", never_ran(tab))
        check("stale_ref_never_reaches_frame", quiet(mark), heard_since(mark))

        # 2. A visible list under a focused field, as Proton Pass and others do.
        tab = opened(site + "/login?vault=focus", "focus")
        snap = agent("snapshot", id=tab, interactive=True)
        mark = mark_now()
        first = agent("act", id=tab, ref=ref_of(snap, "Email"), action="click")
        # No extension frame yet: a click by ref is still a real click.
        check("focus_first_click_real", first == {"done": "mouse"}, first)
        check("focus_frame_loaded", frame_loaded(mark))
        snap = agent("snapshot", id=tab, interactive=True)
        check("focus_snapshot_allowed", "error" not in snap, snap)
        on_top = page(tab, "['#under', 'a[download]', '#attach'].map(s => (r => document.elementFromPoint(r.left + r.width / 2, "
                           "r.top + r.height / 2)?.localName)(document.querySelector(s).getBoundingClientRect()))")
        check("focus_list_covers_button_and_link", on_top == {"value": ["vault-fixture"] * 3}, on_top)
        typed = agent("act", id=tab, ref=ref_of(snap, "Password"), action="type", text="not-a-secret")
        check("focus_type_by_ref", "error" not in typed and page(tab, "document.querySelector('#password').value").get("value") == "not-a-secret", typed)
        # A button under the list (left 60, top 200): a click by its ref must
        # never become a real click at its point, which would land in the frame.
        under = agent("act", id=tab, ref=ref_of(snap, "Under the list"), action="click")
        report["click_under_frame"] = under
        pressed = page(tab, "document.querySelector('#under').textContent").get("value") == "Pressed"
        check("focus_click_under_frame_pressed", "error" not in under and pressed, under)
        saved = agent("agent-download", id=tab, ref=ref_of(snap, "Save the list"))
        check("focus_download_under_list_saved", downloaded(saved, "list.txt"), saved)
        # An upload's button under the list: its press opens the page's
        # picker, and a real click at its point would land in the frame.
        # In /tmp, outside home: Yab never uploads from a hidden folder in
        # home, and --out or $TMPDIR could be one.
        given = Path(tempfile.mkdtemp(prefix="yab-extension-frame-", dir="/tmp")) / "upload.txt"
        given.write_text("a file to upload\n")
        sent = agent("agent-upload", id=tab, ref=ref_of(snap, "Attach a file"), files=[str(given)])
        report["upload_under_list"] = sent
        attached = page(tab, "document.querySelector('#attach').textContent").get("value")
        check("focus_upload_under_list_attached", sent.get("ok") is True and attached == "Attached upload.txt", {"reply": sent, "button": attached})
        shutil.rmtree(given.parent, ignore_errors=True)
        # Nothing so far, from the first click on Email on, reached the list.
        check("focus_by_ref_heard_nothing", quiet(mark), heard_since(mark))
        # The list's field takes focus from a real click (the harness's, as a
        # person's would be), so keys and typing with no ref would go there.
        mark = mark_now()
        ask(do="chromium", id=tab, op="click", x=100.0, y=200.0)
        check("focus_frame_hears_a_real_click",
              yab_socket.wait_for(lambda: {"pointerover", "pointermove", "pointerdown", "focus", "click"} <= {e.get("kind") for e in HEARD[mark:]}, 10), HEARD[mark:])
        settled(mark)
        # Points inside the visible frame (left 20, top 140, 320 by 160), and
        # the moves and keys that need sight even by ref.
        mark = mark_now()
        email = ref_of(snap, "Email")
        under = ref_of(snap, "Under the list")
        pdfs_at_start = pdfs()
        for name, verb, fields in [("press", "press", {"keys": "a"}), ("type_no_ref", "act", {"action": "type", "text": "x"}),
                                   ("point_click", "act", {"action": "click", **screen(tab, 100, 200)}),
                                   # Under the list: a real pointer there is in the frame.
                                   ("hover_by_ref", "act", {"ref": under, "action": "hover"}),
                                   ("drag_by_ref", "act", {"ref": email, "action": "drag", "to": under}),
                                   ("type_submit", "act", {"ref": email, "action": "type", "text": "x", "submit": True}),
                                   ("eval", "agent-eval", {"js": TRY}), ("eval_held", "agent-eval-held", {}),
                                   ("shot", "shot", {"width": 800, "inline": True}),
                                   ("pdf", "agent-pdf", {})]:
            got = agent(verb, id=tab, **fields)
            check(f"focus_{name}_refused", refused(got), got)
        check("focus_eval_never_ran", never_ran(tab))
        check("focus_frame_heard_nothing", quiet(mark), heard_since(mark))
        check("focus_pdf_wrote_nothing", not (pdfs() - pdfs_at_start), sorted(pdfs() - pdfs_at_start))
        # And typing there is heard, so the silence above means something.
        mark = mark_now()
        ask(do="chromium", id=tab, op="text", text="k")
        check("focus_frame_hears_typing",
              yab_socket.wait_for(lambda: any(e.get("kind") == "input" for e in HEARD[mark:]), 10), HEARD[mark:])
        settled(mark)
        # Typing by ref while the frame still has focus goes to the page's field only.
        mark = mark_now()
        typed = agent("act", id=tab, ref=email, action="type", text="by-ref")
        check("focus_type_by_ref_from_frame_focus", "error" not in typed and page(tab, "document.querySelector('#email').value").get("value") == "by-ref", typed)
        check("focus_type_by_ref_from_frame_focus_heard_nothing", quiet(mark), heard_since(mark))

        # The same list with its frame in the page's own tree: the snapshot
        # meets the iframe and leaves it out by name, and an eval could find it.
        tab = opened(site + "/login?vault=focus&host=light", "light")
        snap = agent("snapshot", id=tab, interactive=True)
        mark = mark_now()
        agent("act", id=tab, ref=ref_of(snap, "Email"), action="click")
        check("light_frame_loaded", frame_loaded(mark))
        mark = mark_now()
        for interactive in (True, False):
            snap = agent("snapshot", id=tab, interactive=interactive)
            check(f"light_snapshot_leaves_frame_out_{'refs' if interactive else 'all'}",
                  "error" not in snap and LEFT_OUT in snap.get("tree", ""), snap)
        check("light_eval_refused", refused(agent("agent-eval", id=tab, js=TRY)))
        check("light_eval_never_ran", never_ran(tab))
        check("light_frame_heard_nothing", quiet(mark), heard_since(mark))
        # The same script from the harness does reach the frame.
        mark = mark_now()
        page(tab, TRY)
        check("light_frame_hears_a_message",
              yab_socket.wait_for(lambda: any(e.get("kind") == "message" for e in HEARD[mark:]), 10), HEARD[mark:])

        # A button in the page's own frame, under the list. Its frame can't
        # see the list over it, so a real click at its point would land in
        # the list; the click must stay out of it.
        for name, inner in [("same_site", "/inner"), ("other_site", site.replace("127.0.0.1", "localhost") + "/inner")]:
            tab = opened(site + "/framed?vault=focus&inner=" + urllib.parse.quote(inner, safe=""), name)
            snap = agent("snapshot", id=tab, interactive=True)
            mark = mark_now()
            first = agent("act", id=tab, ref=ref_of(snap, "Email"), action="click")
            check(f"{name}_first_click_real", first == {"done": "mouse"}, first)
            check(f"{name}_frame_list_loaded", frame_loaded(mark))
            mark = mark_now()
            snap = yab_socket.wait_for(lambda: (lambda got: got if ref_of(got, "Inside the frame") else None)(
                agent("snapshot", id=tab, interactive=True)), 15) or {}
            button = ref_of(snap, "Inside the frame")
            got = agent("act", id=tab, ref=button, action="click")
            report[f"{name}_click_under_list"] = {"ref": button, "reply": got}
            check(f"{name}_click_under_list_heard_nothing", bool(button) and quiet(mark), {"ref": button, "reply": got, "heard": heard_since(mark)})
            mark = mark_now()
            # The button itself was pressed (read through the agent's
            # own snapshot, which reaches into the other site's frame).
            after = agent("snapshot", id=tab, interactive=True)
            check(f"{name}_click_under_list_pressed", "error" not in got and ref_of(after, "Pressed") == button, {"reply": got, "tree": after.get("tree")})
            # A download by ref from under the list stays out of it too (the
            # window holds the snapshot above as well).
            link = ref_of(after, "Get the file")
            got = agent("agent-download", id=tab, ref=link)
            report[f"{name}_download_under_list"] = got
            if name == "same_site":
                check("same_site_download_under_list_saved", link and downloaded(got, "file.txt"), got)
            else:
                # Download by ref can't reach another site's frame yet (its act
                # runs in the top page). When it can, this fails and the
                # silence check below starts to mean something.
                check("other_site_download_by_frame_ref_stale", link and got == {"error": f"stale ref {link}, take a new snapshot"}, got)
            check(f"{name}_download_under_list_heard_nothing", bool(link) and quiet(mark), {"reply": got, "heard": heard_since(mark)})
            # The list does cover the frame's link (centre 90, 265) and button:
            # the top page's hit test finds the extension's element at both,
            # and a real click on the button is heard, all of it.
            on_top = page(tab, "[[90, 265], [130, 210]].map(([x, y]) => document.elementFromPoint(x, y)?.localName)")
            check(f"{name}_list_covers_link_and_button", on_top == {"value": ["vault-fixture", "vault-fixture"]}, on_top)
            mark = mark_now()
            ask(do="chromium", id=tab, op="click", x=130.0, y=210.0)
            check(f"{name}_list_covers_the_button",
                  yab_socket.wait_for(lambda: {"pointerdown", "click"} <= {e.get("kind") for e in HEARD[mark:]}, 10), HEARD[mark:])
            settled(mark)

        # A page's own sandboxed and lazy frames are not an extension's:
        # clicks there stay real.
        tab = opened(site + "/sandboxed", "sandboxed")
        snap = agent("snapshot", id=tab, interactive=True)
        clicked = agent("act", id=tab, ref=ref_of(snap, "Continue"), action="click")
        check("sandboxed_click_real", clicked == {"done": "mouse"}, clicked)

        # 3. The extension's own page: nothing at all.
        own_url = f"chrome-extension://{ext}/frame.html?log=" + site + "/log"
        own = agent("open", url=own_url)
        report["extension_page_open"] = own
        # `open` takes Yab's own schemes only (Address.url): never this one.
        check("extension_page_url_rejected", own == {"error": "open needs a url"}, own)
        # The page sends the agent's own tab there (frame.html is web accessible).
        mark = mark_now()
        page(tab, f"location.href = {json.dumps(own_url)}")
        arrived = yab_socket.wait_for(lambda: any(t.get("id") == tab and t.get("url", "").startswith("chrome-extension:")
                                                  for t in raw(do="tabs").get("tabs", [])), 15)
        check("extension_page_reached", arrived and frame_loaded(mark), raw(do="tabs"))
        page(tab, "document.querySelector('#pick').focus()")
        check("extension_page_field_focused", page(tab, "document.activeElement.id") == {"value": "pick"})
        pick = page(tab, "(r => [r.left + r.width / 2, r.top + r.height / 2])(document.querySelector('#pick').getBoundingClientRect())")["value"]
        settled(mark_now())
        mark = mark_now()
        for verb, fields in [("snapshot", {"interactive": True}), ("text", {}), ("agent-eval", {"js": "document.body.dataset.agentRan = '1'; fetch(new URLSearchParams(location.search).get('log'), {method: 'POST', "
                                                    "body: JSON.stringify({kind: 'agent-ran', at: Date.now()})}); document.body.innerText"}),
                             ("shot", {"width": 400, "inline": True}), ("act", {"ref": "e1", "action": "type", "text": "x"}),
                             ("press", {"keys": "a"}), ("act_no_ref", {"action": "type", "text": "x"}),
                             ("act_point", {"action": "click", **screen(tab, *pick)})]:
            got = agent(verb.split("_")[0], id=tab, **fields)
            check(f"extension_page_{verb}_refused", refused(got, PAGE_REFUSAL), got)
        check("extension_page_field_untouched", page(tab, "document.querySelector('#pick').value") == {"value": SECRETS[1]})
        check("extension_page_eval_never_ran", never_ran(tab))
        check("extension_page_heard_nothing", quiet(mark), heard_since(mark))
        # The frame does report its own page being marked, so that silence counts.
        mark = mark_now()
        page(tab, "document.body.dataset.agentRan = '1'")
        check("extension_page_hears_a_mark",
              yab_socket.wait_for(lambda: any(e.get("kind") == "marked" for e in HEARD[mark:]), 10), HEARD[mark:])
        settled(mark)

        # Last, as its question holds the page: a click or a download by
        # ref whose page then opens confirm() is answered at once, with the
        # question, and pressed once.
        mark = mark_now()
        tab = opened(site + "/login?vault=hidden&ask=2", "ask_download")
        check("ask_download_frame_loaded", frame_loaded(mark))
        snap = agent("snapshot", id=tab, interactive=True)
        mark = mark_now()
        started = time.time()
        saving = agent("agent-download", id=tab, ref=ref_of(snap, "Save after asking"))
        check("download_dialog_answered", time.time() - started < 10
              and (saving.get("ok") is True or saving.get("code") == "NATIVE_PAGE_QUESTION"), saving)
        yab_socket.wait_for(lambda: any(e.get("kind") == "saving" for e in HEARD[mark:]), 10)
        # The page holds its question, for the agent (dialog answers it) or
        # for the person (answered here through the tab in front).
        held = agent("agent-dialog", id=tab, accept=False)
        asked_ok = held.get("ok") is True
        if not asked_ok:
            held = agent("snapshot", id=tab, interactive=True)
            asked_ok = held.get("code") == "NATIVE_PAGE_QUESTION"
            if asked_ok:
                ask(do="select", id=tab)
                ask(do="ui", ask="no")
        check("download_dialog_asked", asked_ok, held)
        # Counted once the question is gone and the page runs again, so a
        # second press queued behind it would show.
        time.sleep(2)
        resumed = agent("snapshot", id=tab, interactive=True)
        heard = [e for e in HEARD[mark:] if e.get("kind") == "saving"]
        check("download_dialog_pressed_once", len(heard) == 1 and "error" not in resumed, {"heard": heard, "after": resumed})
        mark = mark_now()
        tab = opened(site + "/login?vault=hidden&ask=1", "ask")
        check("ask_frame_loaded", frame_loaded(mark))
        snap = agent("snapshot", id=tab, interactive=True)
        mark = mark_now()
        started = time.time()
        asked = agent("act", id=tab, ref=ref_of(snap, "Ask first"), action="click")
        check("click_dialog_answered", time.time() - started < 10 and ("Keep going?" in str(asked.get("dialog"))
              or asked.get("code") == "NATIVE_PAGE_QUESTION"), asked)
        yab_socket.wait_for(lambda: any(e.get("kind") == "asking" for e in HEARD[mark:]), 10)
        if asked.get("code") == "NATIVE_PAGE_QUESTION":
            ask(do="select", id=tab)
            ask(do="ui", ask="no")
        else:
            agent("agent-dialog", id=tab, accept=False)
        time.sleep(2)
        resumed = agent("snapshot", id=tab, interactive=True)
        heard = [e for e in HEARD[mark:] if e.get("kind") == "asking"]
        check("click_dialog_pressed_once", len(heard) == 1 and "error" not in resumed, {"heard": heard, "after": resumed})
        # A page that asks before the click goes out: the question is the
        # answer, at once, and nothing is clicked.
        # The question comes during the pointer's 0.45 s move, which Reduce
        # Motion skips: then there is no window to ask in.
        motion = subprocess.run(["defaults", "read", "com.apple.universalaccess", "reduceMotion"], capture_output=True, text=True)
        if motion.stdout.strip() == "1":
            report["skipped"] = ["question_before_click: Reduce Motion is on"]
            print("SKIP question_before_click: Reduce Motion is on")
        else:
            tab = opened(site + "/late", "late")
            ask(do="select", id=tab)
            snap = agent("snapshot", id=tab, interactive=True)
            started = time.time()
            late = agent("act", id=tab, ref=ref_of(snap, "Ask on the way"), action="click")
            # Well under the page's 15 s readiness wait. The check below
            # shows the question came before the click.
            took = time.time() - started
            check("question_before_click_answered", took < 3 and late.get("code") == "NATIVE_PAGE_QUESTION", {"seconds": took, **late})
            # Answered (the tab is in front), the page goes on, and the
            # click that was never sent stays unsent.
            ask(do="ui", ask="no")
            time.sleep(2)
            after = page(tab, "document.querySelector('#late').textContent")
            check("question_before_click_not_clicked", after.get("value") == "Ask on the way", after)

        time.sleep(2)
        late = [e for e in HEARD if e.get("kind") not in ("loaded", "ready")
                and any(start * 1000 <= e.get("at", 0) <= end * 1000 for start, end in quiet_windows)]
        check("no_report_from_a_silent_window", quiet_windows and not late, late)

        # Nothing only the extension sees, in any answer an agent got.
        told = [c for c in calls if c["request"].get("session") and leaks(c["reply"])]
        check("no_answer_leaks_frame_text", not told, told)
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2, default=str))
        try:
            raw(do="app-quit")
        except Exception:
            pass
        try:
            proc.wait(15)
        except subprocess.TimeoutExpired:
            proc.terminate()
        server.shutdown()
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        # `defaults delete` leaves an empty plist behind.
        (Path.home() / "Library/Preferences" / (domain + ".plist")).unlink(missing_ok=True)
        shutil.rmtree(yab_socket.support(world), ignore_errors=True)
    failed = [k for k, v in checks.items() if not v]
    print(f"{len(checks) - len(failed)} of {len(checks)} passed" + (": " + ", ".join(failed) if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

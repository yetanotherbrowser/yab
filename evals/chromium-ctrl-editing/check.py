#!/usr/bin/env python3
"""Cocoa's Control editing keys in a page's fields, on Chromium and WebKit tabs.

    python3 evals/chromium-ctrl-editing/check.py [--app "build/yab Dev.app"] [--out DIR]

The app must have Chromium tabs: Yab Dev built as CONTRIBUTING.md's "Chromium
tabs" says, or a released Yab, whose Chromium has Yab's own patches (a stock
CEF build may not open pages at all). Each engine runs in a disposable world
of its own (YAB_PROBE, YAB_ENGINE), started with `open` so that it has the
screen, and the world is deleted afterwards.
An input, a textarea and a contenteditable hold "hello world" with the caret
after "hello"; each key is pressed once and the field's text and caret are
read back from the page.

The keys go through the app as a keyboard's do: `chord` with `native` builds
a CGEvent, makes it an NSEvent and hands it to NSApp.sendEvent, so menus,
performKeyEquivalent, keyDown and the input context all see it. It does not
need the system's permission to post events, which CGEventPost does.

Every key must reach the field as a trusted keydown and do in both engines
what it does in a Mac text field, but ⌃O, which must change nothing on
Chromium tabs (see KEYS); the script exits 1 when one does not. result.json keeps every reading, the
page's keydown and beforeinput events and, on Chromium, the page view's
own key routes (ChromiumPage.keyRoutes).
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid

EVALS = Path(__file__).resolve().parents[1]
ROOT = EVALS.parent
sys.path.insert(0, str(EVALS))
from yab_socket import exchange, serve, socket_path, support, url  # noqa: E402

TEXT = "hello world"
CARET = 5  # after "hello"
# Key, its commands, then what a Mac field shows after it: (text, caret), or
# that per engine and field where they differ.
KEYS = [
    ("ctrl+a", "moveToBeginningOfParagraph", (TEXT, 0)),
    ("ctrl+e", "moveToEndOfParagraph", (TEXT, 11)),
    ("ctrl+b", "moveBackward", (TEXT, 4)),
    ("ctrl+f", "moveForward", (TEXT, 6)),
    ("ctrl+h", "deleteBackward", ("hell world", 4)),
    ("ctrl+d", "deleteForward", ("helloworld", 5)),
    ("ctrl+k", "deleteToEndOfParagraph", ("hello", 5)),
    # ⌃O opens a line on WebKit, as in a Mac field (a single-line field only
    # moves back). Chromium drops its insert command and would run the move
    # alone, so on Chromium tabs it stays a key with no command: nothing.
    # WebKit's editable keeps the new line's leading space as a no-break space.
    ("ctrl+o", "insertNewlineIgnoringFieldEditor moveBackward", {
        "webKit": {"input": (TEXT, 4), "textarea": ("hello\n world", 5), "editable": ("hello\n\xa0world", 5)},
        "chromium": (TEXT, CARET)}),
]
FIELDS = ["input", "textarea", "editable"]


def expected(want, engine, field):
    if isinstance(want, dict):
        want = want[engine]
    return want[field] if isinstance(want, dict) else want

PAGE = b"""<!doctype html><meta charset=utf-8><title>Control keys</title>
<style>body{font:20px system-ui;margin:24px}input,textarea,div{display:block;width:420px;font:inherit;margin:0 0 24px}
textarea{height:60px}#editable{border:1px solid #888;min-height:30px}</style>
<input id=input value="hello world">
<textarea id=textarea>hello world</textarea>
<div id=editable contenteditable>hello world</div>
<script>
window.events = [];
for (const type of ['keydown', 'beforeinput'])
  addEventListener(type, e => events.push({type, key: e.key, ctrl: e.ctrlKey, trusted: e.isTrusted,
    inputType: e.inputType || null, target: e.target.id}), true);
window.read = id => {
  const el = document.getElementById(id);
  if (!el.isContentEditable)
    return {text: el.value, start: el.selectionStart, end: el.selectionEnd, active: document.activeElement.id};
  const s = getSelection();
  if (!s.rangeCount) return {text: el.innerText, start: null, end: null, active: document.activeElement.id};
  const r = s.getRangeAt(0), offset = (node, at) => {
    const pre = document.createRange(); pre.selectNodeContents(el); pre.setEnd(node, at); return pre.toString().length;
  };
  return {text: el.innerText, start: offset(r.startContainer, r.startOffset), end: offset(r.endContainer, r.endOffset),
          active: document.activeElement.id};
};
window.place = (id, text, at) => {
  const el = document.getElementById(id);
  el.focus();
  if (el.isContentEditable) {
    el.textContent = text;
    const r = document.createRange(); r.setStart(el.firstChild, at); r.collapse(true);
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
  } else { el.value = text; el.setSelectionRange(at, at); }
  events.length = 0;
  return read(id);
};
window.box = id => { const r = document.getElementById(id).getBoundingClientRect();
  return {x: r.left + Math.min(r.width - 8, 40), y: r.top + r.height / 2}; };
</script>"""


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def probe(app, world):
    """The app's process started for this world: its environment names the
    world, which no other copy of the app (someone's own Yab) has."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = str(app / "Contents/MacOS" / info["CFBundleExecutable"])
    rows = subprocess.run(["ps", "-axwwE", "-o", "pid=,command="], capture_output=True, text=True).stdout.splitlines()
    for row in rows:
        pid, _, command = row.strip().partition(" ")
        if command.startswith(executable + " ") and f" YAB_PROBE={world} " in command + " ":
            return int(pid)
    return None


def stop(pid):
    try:
        os.kill(pid, signal.SIGTERM)
        for _ in range(60):
            os.kill(pid, 0)
            time.sleep(.25)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run(app, engine, page_url, out):
    world = "ctrl-editing-" + engine.lower() + "-" + uuid.uuid4().hex[:6]
    domain = "dev.serafim.fast.test." + world
    sock = socket_path(world)
    data = dict(engine=engine, world=world, transport="chord native (CGEvent -> NSApp.sendEvent)", checks=[])
    log = out / f"{engine}-app.log"
    pid = None

    def ask(verb, timeout=30, **fields):
        answer = exchange(sock, dict(do=verb, **fields), timeout)
        if answer.get("error"):
            raise RuntimeError(f"{verb}: {answer['error']}")
        return answer

    def js(tab, code):
        return ask("eval", id=tab, js=code).get("value")

    try:
        for key in ("bench", "welcomed"):
            subprocess.run(["defaults", "write", domain, key, "-bool", "true"], check=True)
        # LaunchServices starts it in the person's login session, which has the
        # screen; a shell from ssh or a terminal multiplexer's daemon has none.
        subprocess.run(["open", "-n", "-a", str(app), "--stdout", str(log), "--stderr", str(log),
                        "--env", f"YAB_PROBE={world}", "--env", f"YAB_ENGINE={engine}", "--env", "YAB_HISTORY=own"],
                       check=True)
        deadline = time.monotonic() + 90
        while not pid:
            pid = probe(app, world)
            if not pid and time.monotonic() > deadline:
                raise RuntimeError("app did not start")
            time.sleep(.1)
        while True:
            try:
                if ask("census").get("pid") == pid:
                    break
            except (OSError, ValueError, RuntimeError):
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("app did not answer on its socket")
            time.sleep(.25)
        tab = ask("open", url=page_url, plain=True)["id"]
        ask("select", id=tab)
        deadline = time.monotonic() + 60
        while True:
            try:
                if js(tab, "document.readyState==='complete' && typeof place==='function'"):
                    break
            except RuntimeError:
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("page did not load")
            time.sleep(.2)
        data["front"] = ask("front")
        data["page_engine"] = ask("page-engine", id=tab)
        built = data["page_engine"].get("builtEngine")
        if built != engine:
            raise RuntimeError(f"tab runs {built}, not {engine}")
        for field in FIELDS:
            for keys, command, want in KEYS:
                text, caret = expected(want, engine, field)
                if engine == "chromium":
                    at = js(tab, f"box('{field}')")
                    ask("chromium", id=tab, op="click", x=at["x"], y=at["y"])
                    time.sleep(.15)
                before = js(tab, f"place('{field}', '{TEXT}', {CARET})")
                ask("chord", id=tab, keys=keys, native=True, wait=.35)
                after = js(tab, f"read('{field}')")
                row = dict(field=field, keys=keys, command=command, before=before, after=after,
                           events=js(tab, "events"), expected=dict(text=text, caret=caret))
                if engine == "chromium":
                    state = ask("chromium", id=tab, op="native-ime")
                    row["keyRoutes"] = state.get("keyRoutes", [])[-2:]
                    row["inputSource"] = state.get("inputSource")
                    row["responderClass"] = state.get("responderClass")
                # The key itself reached the field: a key that went nowhere
                # would also leave ⌃O's field as it was.
                letter = keys.split("+")[-1]
                reached = any(e.get("type") == "keydown" and e.get("key") == letter and e.get("ctrl")
                              and e.get("trusted") and e.get("target") == field for e in row["events"])
                row["passed"] = (reached and after.get("text") == text and after.get("start") == caret
                                 and after.get("end") == caret and after.get("active") == field)
                data["checks"].append(row)
                print(f"{'PASS' if row['passed'] else 'FAIL'} {engine:8} {field:8} {keys:6} {command:28} "
                      f"got {after.get('text')!r} @{after.get('start')}  want {text!r} @{caret}", flush=True)
        try:
            exchange(sock, dict(do="winshot", path=str(out / f"{engine}.png")), 30)
        except OSError:
            pass
    except Exception as error:
        data["error"] = repr(error)
        print(f"FAIL {engine}: probe did not finish: {error!r}", flush=True)
    finally:
        pid = pid or probe(app, world)
        if pid:
            stop(pid)
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        shutil.rmtree(support(world), ignore_errors=True)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path, default=ROOT / "build/yab Dev.app")
    parser.add_argument("--out", type=Path, default=ROOT / ".build/chromium-ctrl-editing")
    parser.add_argument("--engine", choices=("chromium", "webKit"), action="append",
                        help="one engine only (default: both)")
    args = parser.parse_args()
    if not (args.app / "Contents/Frameworks/Chromium Embedded Framework.framework").exists():
        parser.error(f"{args.app} has no Chromium: build it as CONTRIBUTING.md's Chromium tabs says")
    args.out.mkdir(parents=True, exist_ok=True)
    server = serve(Page)
    try:
        runs = [run(args.app.resolve(), engine, url(server, "/"), args.out)
                for engine in (args.engine or ["chromium", "webKit"])]
    finally:
        server.shutdown()
    (args.out / "result.json").write_text(json.dumps(runs, indent=2) + "\n")
    passed = all("error" not in r and r["checks"] and all(c["passed"] for c in r["checks"]) for r in runs)
    for r in runs:
        good = sum(c["passed"] for c in r["checks"])
        print(f"{r['engine']}: {good}/{len(r['checks'])} keys as in a Mac field" + (f", {r['error']}" if "error" in r else ""))
    print("result:", args.out / "result.json")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

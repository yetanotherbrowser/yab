#!/usr/bin/env python3
"""Settings search reaches rows the lazy page hasn't built: from the top of a
long page, and on a page the pick has just switched to. For each case the row's
anchor must be missing from SettingsAnchorsShown before the pick and shown
after it. Exits 1 when a case misses.

    python3 evals/settings-search-reach.py --app "build/yab Dev.app" [--runs 2]
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import yab_socket  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=1)
OPTS = parser.parse_args()
OUT = os.environ.get("YAB_FARM_OUT") or tempfile.mkdtemp(prefix="yab-search-reach-")
WORLD = "searchreach"
SOCK = os.path.expanduser(f"~/Library/Application Support/Yab ({WORLD})/bench.sock")
SUITE = f"dev.serafim.fast.test.{WORLD}"
ask = yab_socket.asker(SOCK, timeout=None)

# (case, page it starts on, words, row title, its anchor, page the row is on)
CASES = [("far-down", "search", "Sites", "Sites", "site-search", "Field"),
         ("far-down-2", "search", "Keyboard shortcut", "Keyboard shortcut", "site-search-space", "Field"),
         ("switched", "general", "Sites", "Sites", "site-search", "Field"),
         ("switched-2", "general", "Keyboard shortcut", "Keyboard shortcut", "site-search-space", "Field"),
         ("switched-3", "general", "Filter lists", "Filter lists", "shield-lists", "Privacy")]


def census():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5); s.connect(SOCK); s.sendall(b'{"do": "census"}\n')
            return json.loads(s.recv(1 << 16).split(b"\n", 1)[0] or b"{}").get("pid")
    except (OSError, ValueError):
        return None


def run_cases(run):
    missed = 0
    ask({"do": "ui", "settings": True}); time.sleep(1)
    for case, start, words, title, anchor, page in CASES:
        ask({"do": "ui", "search": ""}); time.sleep(0.3)
        ask({"do": "scroll", "go": start}); time.sleep(0.8)
        ask({"do": "scroll", "to": 0}); time.sleep(0.5)
        state = ask({"do": "ui", "search": words})
        before = anchor in state.get("anchors", [])
        for _ in range(3): state = ask({"do": "ui", "pick": "up"})
        for _ in range(25):
            if state.get("spot") == title and state.get("page") == page: break
            state = ask({"do": "ui", "pick": "down"})
        time.sleep(1.0)
        where = ask({"do": "scroll", "where": True})
        after = ask({"do": "ui", "pick": "return"})
        shown = anchor in after.get("anchors", [])
        ok = not before and state.get("spot") == title and after.get("page") == page and shown
        missed += not ok
        yab_socket.shot(SOCK, os.path.join(OUT, f"{run}-{case}.png"), settings=True)
        print(f"run {run} {case}: {'ok' if ok else 'MISSED'}  built before {before}, after {shown}  "
              f"y {where.get('y')} of {where.get('height')}", flush=True)
        time.sleep(2)
    return missed


left = census()
if left:
    os.kill(left, 15); yab_socket.wait_for(lambda: census() is None, 10)
missed = 0
for run in range(1, OPTS.runs + 1):
    subprocess.run(["defaults", "delete", SUITE], stderr=subprocess.DEVNULL)
    for key in ("bench", "welcomed"):
        subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"])
    subprocess.run(["open", "-g", "-n", "--env", f"YAB_PROBE={WORLD}", "-a", os.path.abspath(OPTS.app)], check=True)
    ask({"do": "probe"})
    pid = census()
    try:
        missed += run_cases(run)
    finally:
        if pid:
            os.kill(pid, 15); yab_socket.wait_for(lambda: census() is None, 10)
print("out:", OUT)
sys.exit(1 if missed else 0)
